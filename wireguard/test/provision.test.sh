#!/usr/bin/env bash
# Exercises provision-peer.sh and provision-cohort.sh without a live WireGuard
# interface or Docker. Key generation uses the real `wg`; `wg set`, `wg show`
# and `docker compose run` are replaced by stubs on PATH.
#
#   bash wireguard/test/provision.test.sh
set -uo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
wg_dir=$(cd "$script_dir/.." && pwd)

if ! real_wg=$(command -v wg); then
    echo 'wg is needed to generate test keys; skipping.'
    exit 0
fi

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/bin"
export REAL_WG="$real_wg" STUB_DIR="$work"
"$real_wg" genkey | "$real_wg" pubkey >"$work/server.pub"

cat >"$work/bin/wg" <<'STUB'
#!/usr/bin/env bash
case "${1:-}" in
    genkey|pubkey|genpsk) exec "$REAL_WG" "$@" ;;
    show) [ "${3:-}" = public-key ] && cat "$STUB_DIR/server.pub" ;;
    set) printf '%s\n' "$*" >>"$STUB_DIR/wg-set.log" ;;
esac
exit 0
STUB

# docker compose [-f FILE] [--env-file FILE] run --rm -T api (student NIM NAME | token NIM)
cat >"$work/bin/docker" <<'STUB'
#!/usr/bin/env bash
args=("$@")
i=0
while [ "$i" -lt "${#args[@]}" ] && [ "${args[$i]}" != api ]; do i=$((i + 1)); done
case "${args[$((i + 1))]:-}" in
    student) printf 'student %s\n' "${args[$((i + 2))]}" >>"$STUB_DIR/docker.log" ;;
    token) printf '%s\n' "${args[$((i + 2))]}" | sha256sum | tr 'a-f0-9' 'A-P' | cut -c1-12 | sed -E 's/(....)(....)(....)/\1-\2-\3/' ;;
esac
exit 0
STUB
chmod +x "$work/bin/wg" "$work/bin/docker"
export PATH="$work/bin:$PATH"

pass=0
fail=0
ok() { pass=$((pass + 1)); echo "PASS  $1"; }
bad() { fail=$((fail + 1)); echo "FAIL  $1"; }
expect() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (expected [$2], got [$3])"; fi; }
has() { if grep -Eq -- "$3" "$2"; then ok "$1"; else bad "$1"; fi; }
# Whole-line, literal match: base64 keys can contain '+', which is special in a regex.
has_line() { if grep -Fxq -- "$3" "$2"; then ok "$1"; else bad "$1"; fi; }
lacks() { if grep -Eq -- "$3" "$2"; then bad "$1"; else ok "$1"; fi; }
count() { grep -c -- "$2" "$1" || true; }

new_conf() { printf '[Interface]\nAddress = 10.66.0.1/24\nListenPort = 51820\nPrivateKey = unused\n' >"$1"; : >"$work/wg-set.log"; }
peer() { "$wg_dir/provision-peer.sh" "$@" 2>&1; }
checksum() { sha256sum "$1" | cut -d' ' -f1; }

echo "== provision-peer.sh"
conf="$work/wg0.conf"
new_conf "$conf"
out=$(peer --student 2200012345 --address 10.66.0.10 --endpoint vpn.example.edu:51820 --output "$work/plain.conf" --server-conf "$conf"); rc=$?
expect "profile without a token: exit status" 0 "$rc"
has "  has the interface section" "$work/plain.conf" '^\[Interface\]$'
has "  has the peer address" "$work/plain.conf" '^Address = 10\.66\.0\.10/32$'
has "  routes everything through the tunnel" "$work/plain.conf" '^AllowedIPs = 0\.0\.0\.0/0, ::/0$'
lacks "  has no token comment" "$work/plain.conf" '^# Token:'
expect "  profile mode" 600 "$(stat -c %a "$work/plain.conf")"
expect "  server config records the student once" 1 "$(count "$conf" '# student: 2200012345$')"
expect "  the live interface was updated once" 1 "$(wc -l <"$work/wg-set.log" | tr -d ' ')"
client_pub=$(sed -n 's/^PrivateKey = //p' "$work/plain.conf" | "$real_wg" pubkey)
has_line "  server peer entry matches the profile's key" "$conf" "PublicKey = $client_pub"
expect "  both sides share one preshared key" "$(sed -n 's/^PresharedKey = //p' "$conf" | tail -1)" "$(sed -n 's/^PresharedKey = //p' "$work/plain.conf" | head -1)"

printf 'ABCD-EFGH-IJKL\n' >"$work/ok.token"
out=$(peer --student 2200012346 --address 10.66.0.11 --endpoint vpn.example.edu:51820 --output "$work/token.conf" --server-conf "$conf" --token-file "$work/ok.token"); rc=$?
expect "profile with a token: exit status" 0 "$rc"
expect "  first line is the comment header" "# Memento lab VM login" "$(sed -n 1p "$work/token.conf")"
has "  carries the student ID" "$work/token.conf" '^# Student ID: 2200012346$'
has "  carries the token" "$work/token.conf" '^# Token: ABCD-EFGH-IJKL$'
expect "  first non-comment line is [Interface]" "[Interface]" "$(grep -v -e '^#' -e '^$' "$work/token.conf" | head -1)"
printf '  ABCD-EFGH-IJKM  \n' >"$work/space.token"
out=$(peer --student 2200012347 --address 10.66.0.12 --endpoint vpn.example.edu:51820 --output "$work/space.conf" --server-conf "$conf" --token-file "$work/space.token"); rc=$?
expect "token with surrounding whitespace: exit status" 0 "$rc"
has "  whitespace is trimmed" "$work/space.conf" '^# Token: ABCD-EFGH-IJKM$'

before=$(checksum "$conf"); sets=$(wc -l <"$work/wg-set.log" | tr -d ' ')
for bad_token in 'abcd-efgh-ijkl' 'ABCD-EFGH-IJK' 'ABCD-EFGH-IJK1' 'ABCDEFGHIJKL' ''; do
    printf '%s\n' "$bad_token" >"$work/bad.token"
    out=$(peer --student 2200012348 --address 10.66.0.13 --endpoint vpn.example.edu:51820 --output "$work/bad.conf" --server-conf "$conf" --token-file "$work/bad.token"); rc=$?
    expect "invalid token [$bad_token]: exit status" 2 "$rc"
done
out=$(peer --student 2200012348 --address 10.66.0.13 --endpoint vpn.example.edu:51820 --output "$work/bad.conf" --server-conf "$conf" --token-file "$work/missing.token"); rc=$?
expect "missing token file: exit status" 2 "$rc"
expect "rejected tokens leave the server config untouched" "$before" "$(checksum "$conf")"
expect "rejected tokens never touch the live interface" "$sets" "$(wc -l <"$work/wg-set.log" | tr -d ' ')"
[ ! -e "$work/bad.conf" ] && ok "rejected tokens write no profile" || bad "rejected tokens write no profile"

out=$(peer --student 2200012345 --address 10.66.0.20 --endpoint vpn.example.edu:51820 --output "$work/dup.conf" --server-conf "$conf"); rc=$?
expect "second profile for the same student: exit status" 1 "$rc"
expect "  server config still lists the student once" 1 "$(count "$conf" '# student: 2200012345$')"
out=$(peer --student 2200012349 --address 10.66.0.10 --endpoint vpn.example.edu:51820 --output "$work/clash.conf" --server-conf "$conf"); rc=$?
expect "address already allocated: exit status" 1 "$rc"
out=$(peer --student 2200012349 --address 10.67.0.10 --endpoint vpn.example.edu:51820 --output "$work/outside.conf" --server-conf "$conf"); rc=$?
expect "address outside the VPN subnet: exit status" 2 "$rc"
out=$(peer --student 'bad id' --address 10.66.0.30 --endpoint vpn.example.edu:51820 --output "$work/id.conf" --server-conf "$conf"); rc=$?
expect "student ID with unsupported characters: exit status" 2 "$rc"

echo "== provision-cohort.sh"
cconf="$work/cohort-wg0.conf"
new_conf "$cconf"
: >"$work/compose.yaml"
cohort() { "$wg_dir/provision-cohort.sh" --start-nim 18225001 --count 3 --first-ip 10 --endpoint vpn.example.edu:51820 --output-dir "$work/cohort" --server-conf "$cconf" --compose-file "$work/compose.yaml" "$@" 2>&1; }
out=$(cohort); rc=$?
expect "first run: exit status" 0 "$rc"
for nim in 18225001 18225002 18225003; do
    token=$(cat "$work/cohort/$nim.token")
    has "  $nim profile carries its own token" "$work/cohort/$nim.conf" "^# Token: $token\$"
    has "  $nim profile carries its student ID" "$work/cohort/$nim.conf" "^# Student ID: $nim\$"
done
expect "  one peer per student in the server config" 3 "$(count "$cconf" '^# student: ')"
has "  addresses are assigned in order" "$work/cohort/18225003.conf" '^Address = 10\.66\.0\.12/32$'
expect "  manifest has a header and three rows" 4 "$(wc -l <"$work/cohort/students.tsv" | tr -d ' ')"
lacks "  manifest holds no token values" "$work/cohort/students.tsv" '[A-Z2-7]{4}-[A-Z2-7]{4}-[A-Z2-7]{4}'
expect "  token file mode" 600 "$(stat -c %a "$work/cohort/18225001.token")"
expect "  output directory mode" 700 "$(stat -c %a "$work/cohort")"

before=$(checksum "$work/cohort/18225002.conf")
out=$(cohort); rc=$?
expect "second run: exit status" 0 "$rc"
expect "  no peer is added twice" 3 "$(count "$cconf" '^# student: ')"
expect "  existing profiles are kept" "$before" "$(checksum "$work/cohort/18225002.conf")"
expect "  manifest rows are not duplicated" 4 "$(wc -l <"$work/cohort/students.tsv" | tr -d ' ')"

sed -i '/^# /d' "$work/cohort/18225002.conf"
out=$(cohort); rc=$?
expect "profile from an earlier run without a token: exit status" 0 "$rc"
printf '%s\n' "$out" | grep -q 'has no token comment' && ok "  warns about the missing token comment" || bad "  warns about the missing token comment"

out=$(cohort --count 250); rc=$?
expect "cohort that does not fit the subnet: exit status" 2 "$rc"

echo "== result: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
