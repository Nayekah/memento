#!/usr/bin/env bash
# Builds a lab ISO from a minimal generated base image and checks the checksum
# handling of build-iso.sh. Needs 7z, cpio, gzip, xorriso (used in place of
# mkisofs), and sha256sum; skips when one is missing.
#
#   bash sandbox/scripts/build-iso-test.sh
set -uo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
for tool in 7z cpio gzip xorriso sha256sum; do
    command -v "$tool" >/dev/null 2>&1 || { echo "$tool is needed for this test; skipping."; exit 0; }
done

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/bin"
cat >"$work/bin/mkisofs" <<'STUB'
#!/usr/bin/env bash
exec xorriso -as mkisofs "$@"
STUB
chmod +x "$work/bin/mkisofs"
export PATH="$work/bin:$PATH"

# A base image with the files the build script expects to find in it.
mkdir -p "$work/base/boot/isolinux"
head -c 4096 /dev/zero >"$work/base/boot/isolinux/isolinux.bin"
printf 'base kernel\n' >"$work/base/boot/vmlinuz"
printf 'original initrd\n' >"$work/base/boot/sisterd.gz"
xorriso -as mkisofs -r -J -o "$work/base.iso" "$work/base" >/dev/null 2>&1 || { echo "could not create the base image" >&2; exit 1; }
printf 'test certificate bundle\n' >"$work/ca.crt"
export SSL_CERT_FILE="$work/ca.crt"

passed=0
failed=0
ok() { passed=$((passed + 1)); echo "PASS  $1"; }
bad() { failed=$((failed + 1)); echo "FAIL  $1"; [ -z "${output:-}" ] || printf '%s\n' "$output" | head -6 | sed 's/^/        | /'; }
expect() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (expected [$2], got [$3])"; fi; }
matches() { if printf '%s\n' "$2" | grep -Eq -- "$3"; then ok "$1"; else bad "$1"; fi; }

out_dir="$work/out"
out="$out_dir/memento-lab.iso"
build() { bash "$script_dir/build-iso.sh" --source-iso "${SOURCE_ISO:-$work/base.iso}" --backend-url https://grader.example.edu --output "$out" "$@" 2>&1; }
fresh() { rm -rf "$out_dir"; }
base_hash=$(sha256sum "$work/base.iso" | cut -d' ' -f1)

echo "== a build without a checksum"
fresh
output=$(build); rc=$?
expect "exit status" 0 "$rc"
matches "  prints the source ISO's SHA-256" "$output" "^Source ISO SHA-256: $base_hash\$"
if [ -f "$out" ]; then ok "  writes the ISO"; else bad "  writes the ISO"; fi
expect "  writes a checksum file in sha256sum format" 1 "$(grep -c -E '^[0-9a-f]{64}  memento-lab\.iso$' "$out.sha256" 2>/dev/null || true)"
if (cd "$out_dir" && sha256sum --status -c memento-lab.iso.sha256); then ok "  the checksum file verifies the ISO"; else bad "  the checksum file verifies the ISO"; fi
matches "  reports the new ISO's SHA-256" "$output" "^SHA-256: $(sha256sum "$out" | cut -d' ' -f1) "
listing=$(7z l "$out" 2>/dev/null)
matches "  keeps the base image's files" "$listing" 'boot/vmlinuz'
mkdir -p "$work/initrd"
7z e -so "$out" boot/sisterd.gz 2>/dev/null | gzip -dc | (cd "$work/initrd" && cpio -idm >/dev/null 2>&1)
if [ -x "$work/initrd/usr/local/bin/submit" ]; then ok "  puts the student commands in the initrd, executable"; else bad "  puts the student commands in the initrd, executable"; fi
expect "  leaves no backend URL placeholder behind" 0 "$(grep -rl '__BACKEND_URL__' "$work/initrd" | wc -l | tr -d ' ')"
if grep -q 'https://grader.example.edu' "$work/initrd/sbin/memento-login"; then ok "  writes the backend URL into the login script"; else bad "  writes the backend URL into the login script"; fi

echo "== --source-sha256"
fresh
output=$(build --source-sha256 "$base_hash"); rc=$?
expect "matching checksum: exit status" 0 "$rc"
matches "  says it verified the image" "$output" '^Source ISO checksum verified\.$'
fresh
output=$(build --source-sha256 "$(printf '%s' "$base_hash" | tr 'a-f' 'A-F')"); rc=$?
expect "upper-case checksum: exit status" 0 "$rc"

fresh
wrong="0${base_hash:1}"
[ "$wrong" != "$base_hash" ] || wrong="1${base_hash:1}"
output=$(build --source-sha256 "$wrong"); rc=$?
expect "wrong checksum: exit status" 1 "$rc"
matches "  shows the expected value" "$output" "expected: $wrong"
matches "  shows the actual value" "$output" "actual: +$base_hash"
if [ -e "$out" ] || [ -e "$out.sha256" ]; then bad "  builds nothing"; else ok "  builds nothing"; fi

for malformed in 'abc' "${base_hash:0:63}" "${base_hash:0:63}g"; do
    fresh
    output=$(build --source-sha256 "$malformed"); rc=$?
    expect "malformed checksum [${malformed:0:12}...]: exit status" 2 "$rc"
done
if [ -e "$out" ]; then bad "  builds nothing"; else ok "  builds nothing"; fi

cp "$work/base.iso" "$work/changed.iso"
printf 'x' >>"$work/changed.iso"
fresh
output=$(SOURCE_ISO="$work/changed.iso" build --source-sha256 "$base_hash"); rc=$?
expect "base image changed after its checksum was recorded: exit status" 1 "$rc"

echo "== the checksum file against a damaged copy"
fresh
build >/dev/null
printf 'x' >>"$out"
if (cd "$out_dir" && sha256sum --status -c memento-lab.iso.sha256); then bad "a modified ISO fails verification"; else ok "a modified ISO fails verification"; fi

echo "== result: $passed passed, $failed failed"
[ "$failed" -eq 0 ]
