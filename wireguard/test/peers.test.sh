#!/usr/bin/env bash
# Exercises revoke-peer.sh and replace-peer.sh. The first pass stubs `wg set`
# and `wg show`, so it needs no interface and no root access. When a user
# namespace can host a WireGuard interface, the same scenarios then run
# against a real wg0 inside a private network namespace.
#
#   bash wireguard/test/peers.test.sh
set -uo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
wg_dir=$(cd "$script_dir/.." && pwd)
mode=${1:-stub}

if ! real_wg=$(command -v wg); then
    echo 'wg is needed for this test; skipping.'
    exit 0
fi

if [ "$mode" = stub ]; then
    # The first pass runs here; the live pass re-runs this file in a namespace.
    bash "$0" run-stub || stub_status=$?
    live_status=0
    if unshare -Urn sh -c 'ip link add wgprobe0 type wireguard' >/dev/null 2>&1; then
        unshare -Urn bash "$0" run-live || live_status=$?
    else
        echo '== live pass skipped: this machine cannot create a WireGuard interface in a user namespace'
    fi
    [ "${stub_status:-0}" -eq 0 ] && [ "$live_status" -eq 0 ]
    exit $?
fi
mode=${mode#run-}

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
export REAL_WG="$real_wg" STUB_DIR="$work"
"$real_wg" genkey >"$work/server.key"
"$real_wg" pubkey <"$work/server.key" >"$work/server.pub"

if [ "$mode" = stub ]; then
    mkdir -p "$work/bin"
    cat >"$work/bin/wg" <<'STUB'
#!/usr/bin/env bash
live="$STUB_DIR/live-peers"
case "${1:-}" in
    genkey|pubkey|genpsk) exec "$REAL_WG" "$@" ;;
    show)
        [ ! -e "$STUB_DIR/down" ] || exit 1
        [ "${3:-}" = public-key ] && cat "$STUB_DIR/server.pub"
        [ "${3:-}" = peers ] && cat "$live" 2>/dev/null
        exit 0 ;;
    set)
        [ ! -e "$STUB_DIR/down" ] || exit 1
        # wg set wg0 peer KEY [remove | preshared-key FILE allowed-ips IPS]
        if [ "${5:-}" = remove ]; then
            grep -vxF "$4" "$live" >"$live.new" 2>/dev/null
            mv "$live.new" "$live"
        else
            grep -qxF "$4" "$live" 2>/dev/null || printf '%s\n' "$4" >>"$live"
        fi
        exit 0 ;;
esac
STUB
    chmod +x "$work/bin/wg"
    export PATH="$work/bin:$PATH"
else
    ip link add wg0 type wireguard
    "$real_wg" set wg0 private-key "$work/server.key" listen-port 51820
fi

passed=0
failed=0
ok() { passed=$((passed + 1)); echo "PASS  $1"; }
bad() { failed=$((failed + 1)); echo "FAIL  $1"; [ -z "${output:-}" ] || printf '%s\n' "$output" | head -6 | sed 's/^/        | /'; }
expect() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (expected [$2], got [$3])"; fi; }
yes_if() { if "${@:2}"; then ok "$1"; else bad "$1"; fi; }
checksum() { sha256sum "$1" | cut -d' ' -f1; }
live_peers() { if [ "$mode" = live ]; then "$real_wg" show wg0 peers; else cat "$work/live-peers" 2>/dev/null; fi; }
live_count() { live_peers | grep -c . || true; }
has_live() { live_peers | grep -qxF "$1"; }
key_of() { sed -n 's/^PrivateKey = //p' "$work/profile-$1.conf" | "$real_wg" pubkey; }
interface_down() { if [ "$mode" = live ]; then ip link del wg0; else touch "$work/down"; fi; }
revoke() { sh "$wg_dir/revoke-peer.sh" "$@" 2>&1; }
replace() { sh "$wg_dir/replace-peer.sh" "$@" 2>&1; }
count_lines() { grep -c -- "$2" "$1" || true; }

conf="$work/wg0.conf"
log="$work/revocations.log"
printf '[Interface]\nAddress = 10.66.0.1/24\nListenPort = 51820\nPrivateKey = unused\n' >"$conf"
chmod 600 "$conf"
for n in 1 2 3; do
    printf 'ABCD-EFGH-IJK%d\n' $((n + 1)) >"$work/token-$n"
    sh "$wg_dir/provision-peer.sh" --student "1822500$n" --address "10.66.0.$((9 + n))" --endpoint vpn.example.edu:51820 \
        --output "$work/profile-$n.conf" --server-conf "$conf" --token-file "$work/token-$n" >/dev/null 2>&1
done
key1=$(key_of 1)
key2=$(key_of 2)
key3=$(key_of 3)

echo "== [$mode] revoke-peer.sh"
expect "three peers are live before the test" 3 "$(live_count)"
cp "$conf" "$work/conf.before"
output=$(revoke --student 18225002 --server-conf "$conf" --log "$log" --reason 'lost laptop' --dry-run); rc=$?
expect "dry run: exit status" 0 "$rc"
expect "  the server config is unchanged" "$(checksum "$work/conf.before")" "$(checksum "$conf")"
expect "  all three peers are still live" 3 "$(live_count)"
yes_if "  nothing is logged" test ! -e "$log"

output=$(revoke --student 18225002 --server-conf "$conf" --log "$log" --reason 'lost "laptop"'); rc=$?
expect "revoke: exit status" 0 "$rc"
if has_live "$key2"; then bad "  the peer is gone from the interface"; else ok "  the peer is gone from the interface"; fi
expect "  the other two peers stay live" 2 "$(live_count)"
if has_live "$key1" && has_live "$(key_of 3)"; then ok "  and they are the right two"; else bad "  and they are the right two"; fi
expect "  the block is gone from the server config" 0 "$(count_lines "$conf" '# student: 18225002$')"
if grep -qF "$key2" "$conf"; then bad "  the key is gone from the server config"; else ok "  the key is gone from the server config"; fi
expect "  the other two blocks are intact" 2 "$(count_lines "$conf" '^# student: ')"
expect "  with their peer sections" 2 "$(count_lines "$conf" '^\[Peer\]')"
expect "  and their addresses" "AllowedIPs = 10.66.0.10/32|AllowedIPs = 10.66.0.12/32" "$(grep '^AllowedIPs' "$conf" | paste -sd'|')"
expect "  the interface section is intact" 1 "$(count_lines "$conf" '^PrivateKey = unused$')"
expect "  the server config keeps its mode" 600 "$(stat -c %a "$conf")"
expect "  the log has one entry" 1 "$(wc -l <"$log" | tr -d ' ')"
expect "  naming the student and address" 1 "$(count_lines "$log" ' revoked student=18225002 address=10.66.0.11/32 ')"
expect "  with the reason, quotes softened" 1 "$(count_lines "$log" "reason=\"lost 'laptop'\"\$")"
if grep -qF "$key2" "$log"; then bad "  the log holds only a key fingerprint"; else ok "  the log holds only a key fingerprint"; fi
expect "  the log is private" 600 "$(stat -c %a "$log")"

output=$(revoke --student 18225002 --server-conf "$conf" --log "$log"); rc=$?
expect "revoking the same student again: exit status" 1 "$rc"
expect "  nothing more is logged" 1 "$(wc -l <"$log" | tr -d ' ')"
output=$(revoke --student 'bad id' --server-conf "$conf" --log "$log"); rc=$?
expect "student ID with unsupported characters: exit status" 2 "$rc"
output=$(revoke --student 18225001 --server-conf "$conf" --log "$log" --reason "$(printf 'two\nlines')"); rc=$?
expect "multi-line reason: exit status" 2 "$rc"
expect "  the student is still live" 1 "$(has_live "$key1" && echo 1 || echo 0)"

# Hand-edited configs may omit the blank line between blocks.
adjacent="$work/adjacent.conf"
first_key=$("$real_wg" genkey | "$real_wg" pubkey)
second_key=$("$real_wg" genkey | "$real_wg" pubkey)
printf '[Interface]\nPrivateKey = unused\n# student: first\n[Peer]\nPublicKey = %s\nAllowedIPs = 10.66.0.50/32\n# student: second\n[Peer]\nPublicKey = %s\nAllowedIPs = 10.66.0.51/32\n' \
    "$first_key" "$second_key" >"$adjacent"
output=$(revoke --student first --server-conf "$adjacent" --log "$log"); rc=$?
expect "blocks with no blank line between them: exit status" 0 "$rc"
expect "  only the first block is removed" "# student: second" "$(grep '^# student:' "$adjacent")"
expect "  and the second keeps its key" 1 "$(grep -cxF "PublicKey = $second_key" "$adjacent" || true)"

echo "== [$mode] replace-peer.sh"
old_private=$(sed -n 's/^PrivateKey = //p' "$work/profile-3.conf")
output=$(replace --student 18225003 --endpoint vpn.example.edu:51820 --output "$work/profile-3.conf" --token-file "$work/token-3" \
    --server-conf "$conf" --log "$log"); rc=$?
expect "replace: exit status" 0 "$rc"
new_private=$(sed -n 's/^PrivateKey = //p' "$work/profile-3.conf")
new_public=$(printf '%s\n' "$new_private" | "$real_wg" pubkey)
if [ -n "$new_private" ] && [ "$new_private" != "$old_private" ]; then ok "  the profile has a new private key"; else bad "  the profile has a new private key"; fi
if has_live "$key3"; then bad "  the old key is gone from the interface"; else ok "  the old key is gone from the interface"; fi
if has_live "$new_public"; then ok "  the new key is live"; else bad "  the new key is live"; fi
expect "  the first student and the replaced student are live" 2 "$(live_count)"
expect "  the address is unchanged" "Address = 10.66.0.12/32" "$(grep '^Address' "$work/profile-3.conf")"
expect "  the token comment is kept" 1 "$(count_lines "$work/profile-3.conf" '^# Token: ABCD-EFGH-IJK4$')"
expect "  the server config lists the student once" 1 "$(count_lines "$conf" '^# student: 18225003$')"
if grep -qxF "PublicKey = $new_public" "$conf"; then ok "  with the new public key"; else bad "  with the new public key"; fi
if grep -qF "$key3" "$conf"; then bad "  and without the old one"; else ok "  and without the old one"; fi
expect "  the revocation is logged with the default reason" 1 "$(count_lines "$log" 'student=18225003 .*reason="keys replaced"$')"

before=$(checksum "$conf")
count_before=$(live_count)
printf 'not-a-token\n' >"$work/bad.token"
output=$(replace --student 18225001 --endpoint vpn.example.edu:51820 --output "$work/new-1.conf" --token-file "$work/bad.token" --server-conf "$conf" --log "$log"); rc=$?
expect "invalid token file: exit status" 2 "$rc"
output=$(replace --student 18225001 --endpoint vpn.example.edu:51820 --output "$work/missing-dir/new-1.conf" --server-conf "$conf" --log "$log"); rc=$?
expect "unwritable output directory: exit status" 2 "$rc"
output=$(replace --student 99999999 --endpoint vpn.example.edu:51820 --output "$work/new-x.conf" --server-conf "$conf" --log "$log"); rc=$?
expect "unknown student: exit status" 1 "$rc"
expect "failed replacements leave the server config untouched" "$before" "$(checksum "$conf")"
expect "failed replacements leave every peer live" "$count_before" "$(live_count)"

echo "== [$mode] interface down"
interface_down
output=$(revoke --student 18225001 --server-conf "$conf" --log "$log" --reason 'interface down'); rc=$?
expect "revoke while wg0 is down: exit status" 0 "$rc"
if printf '%s\n' "$output" | grep -q 'wg0 is not up'; then ok "  says that only the configuration changed"; else bad "  says that only the configuration changed"; fi
expect "  the block is gone from the server config" 0 "$(count_lines "$conf" '# student: 18225001$')"

echo "== [$mode] result: $passed passed, $failed failed"
[ "$failed" -eq 0 ]
