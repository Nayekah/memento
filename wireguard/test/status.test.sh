#!/usr/bin/env bash
# Exercises peer-status.sh. The first pass feeds it handshake times through a
# stubbed `wg`, so the ages are exact. When a user namespace can host a
# WireGuard interface, a second pass reads the real
# `wg show wg0 latest-handshakes` output from a live wg0.
#
#   bash wireguard/test/status.test.sh
set -uo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
wg_dir=$(cd "$script_dir/.." && pwd)
mode=${1:-stub}

if ! real_wg=$(command -v wg); then
    echo 'wg is needed for this test; skipping.'
    exit 0
fi

if [ "$mode" = stub ]; then
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
case "${1:-}" in
    genkey|pubkey|genpsk) exec "$REAL_WG" "$@" ;;
    show)
        [ ! -e "$STUB_DIR/down" ] || exit 1
        case "${3:-}" in
            public-key) cat "$STUB_DIR/server.pub" ;;
            latest-handshakes) cat "$STUB_DIR/handshakes" 2>/dev/null ;;
        esac
        exit 0 ;;
    set) exit 0 ;;
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
bad() { failed=$((failed + 1)); echo "FAIL  $1"; [ -z "${output:-}" ] || printf '%s\n' "$output" | head -8 | sed 's/^/        | /'; }
expect() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (expected [$2], got [$3])"; fi; }
matches() { if printf '%s\n' "$2" | grep -Eq -- "$3"; then ok "$1"; else bad "$1"; fi; }
status_script() { sh "$wg_dir/peer-status.sh" --server-conf "$conf" "$@" 2>"$work/stderr"; }
key_of() { sed -n 's/^PrivateKey = //p' "$work/profile-$1.conf" | "$real_wg" pubkey; }

conf="$work/wg0.conf"
printf '[Interface]\nAddress = 10.66.0.1/24\nListenPort = 51820\nPrivateKey = unused\n' >"$conf"
count=${PEER_COUNT:-4}
[ "$mode" = live ] && count=3
for n in $(seq 1 "$count"); do
    sh "$wg_dir/provision-peer.sh" --student "1822500$n" --address "10.66.0.$((9 + n))" --endpoint vpn.example.edu:51820 \
        --output "$work/profile-$n.conf" --server-conf "$conf" >/dev/null 2>&1
done

now=1000000
tab=$(printf '\t')

if [ "$mode" = stub ]; then
    echo "== [stub] ages and statuses"
    stranger=$("$real_wg" genkey | "$real_wg" pubkey)
    {
        printf '%s\t%d\n' "$(key_of 1)" $((now - 50))
        printf '%s\t%d\n' "$(key_of 2)" $((now - 300))
        printf '%s\t%d\n' "$(key_of 3)" 0
        printf '%s\t%d\n' "$stranger" $((now - 10))
    } >"$work/handshakes"
    output=$(status_script --now "$now"); rc=$?
    expect "default run: exit status" 1 "$rc"
    matches "  header" "$output" '^STUDENT +ADDRESS +LAST HANDSHAKE +STATUS$'
    matches "  fresh handshake is OK" "$output" '^18225001 +10\.66\.0\.10 +50s ago +OK$'
    matches "  five minutes old is STALE" "$output" '^18225002 +10\.66\.0\.11 +5m ago +STALE$'
    matches "  a zero timestamp is NEVER" "$output" '^18225003 +10\.66\.0\.12 +never +NEVER$'
    matches "  a peer absent from the interface is MISSING" "$output" '^18225004 +10\.66\.0\.13 +- +MISSING$'
    matches "  summary" "$output" '^4 peers: 1 ok, 1 stale, 1 never, 1 missing$'
    matches "  a peer that is not in the config is reported" "$(cat "$work/stderr")" '1 peer\(s\) on wg0 are not in the server configuration'

    output=$(status_script --now "$now" --only-problems); rc=$?
    expect "--only-problems: exit status" 1 "$rc"
    expect "  hides the healthy peer" 0 "$(printf '%s\n' "$output" | grep -c '^18225001')"
    expect "  shows the three problems" 3 "$(printf '%s\n' "$output" | grep -c -E '^1822500[234]')"

    output=$(status_script --now "$now" --format tsv)
    expected=$(printf '18225001\t10.66.0.10\t50\tOK\n18225002\t10.66.0.11\t300\tSTALE\n18225003\t10.66.0.12\t-\tNEVER\n18225004\t10.66.0.13\t-\tMISSING')
    expect "--format tsv" "$expected" "$output"

    output=$(status_script --now "$now" --stale-seconds 400); rc=$?
    matches "--stale-seconds 400 makes the five-minute peer OK" "$output" '^18225002 +10\.66\.0\.11 +5m ago +OK$'

    printf '%s\t%d\n' "$(key_of 1)" $((now + 30)) >"$work/handshakes"
    matches "a timestamp slightly in the future counts as zero seconds" "$(status_script --now "$now" --format tsv)" "^18225001${tab}10\.66\.0\.10${tab}0${tab}OK\$"
    printf '%s\t%d\n' "$(key_of 1)" $((now - 180)) >"$work/handshakes"
    matches "a handshake exactly at the limit is still OK" "$(status_script --now "$now" --format tsv)" "^18225001${tab}10\.66\.0\.10${tab}180${tab}OK\$"
    printf '%s\t%d\n' "$(key_of 1)" $((now - 181)) >"$work/handshakes"
    matches "one second past the limit is STALE" "$(status_script --now "$now" --format tsv)" "^18225001${tab}10\.66\.0\.10${tab}181${tab}STALE\$"

    {
        for n in 1 2 3 4; do printf '%s\t%d\n' "$(key_of "$n")" $((now - 5)); done
    } >"$work/handshakes"
    output=$(status_script --now "$now"); rc=$?
    expect "everyone connected: exit status" 0 "$rc"
    matches "  summary" "$output" '^4 peers: 4 ok$'
    expect "  nothing on stderr" "" "$(cat "$work/stderr")"
    printf '%s\t%d\n' "$stranger" $((now - 5)) >>"$work/handshakes"
    output=$(status_script --now "$now"); rc=$?
    expect "everyone connected plus an unknown peer: exit status" 1 "$rc"

    touch "$work/down"
    output=$(status_script --now "$now"); rc=$?
    expect "interface down: exit status" 1 "$rc"
    expect "  every peer is UNKNOWN" 4 "$(printf '%s\n' "$output" | grep -c 'UNKNOWN$')"
    matches "  says why" "$(cat "$work/stderr")" 'wg0 is not up'
    rm -f "$work/down"

    echo "== [stub] arguments and edge cases"
    for args in '--stale-seconds 0' '--stale-seconds abc' '--format xml' '--now abc' '--nonsense'; do
        # shellcheck disable=SC2086
        output=$(status_script $args); rc=$?
        expect "$args: exit status" 2 "$rc"
    done
    output=$(status_script --server-conf "$work/missing.conf"); rc=$?
    expect "missing server config: exit status" 1 "$rc"
    printf '[Interface]\nPrivateKey = unused\n' >"$work/empty.conf"
    : >"$work/handshakes"
    output=$(status_script --server-conf "$work/empty.conf" --now "$now"); rc=$?
    expect "no student peers: exit status" 0 "$rc"
    matches "  summary" "$output" '^0 peers$'
else
    echo "== [live] the real wg output"
    output=$(status_script); rc=$?
    expect "no handshakes yet: exit status" 1 "$rc"
    expect "  every peer is NEVER" 3 "$(printf '%s\n' "$output" | grep -c 'never  *NEVER$')"
    matches "  summary" "$output" '^3 peers: 3 never$'
    expect "  nothing unexpected on stderr" "" "$(cat "$work/stderr")"

    rogue=$("$real_wg" genkey | "$real_wg" pubkey)
    "$real_wg" set wg0 peer "$rogue" allowed-ips 10.66.0.200/32
    output=$(status_script); rc=$?
    matches "a peer added to the interface but not the config is reported" "$(cat "$work/stderr")" '1 peer\(s\) on wg0 are not in the server configuration'

    sh "$wg_dir/provision-peer.sh" --student 18225099 --address 10.66.0.99 --endpoint vpn.example.edu:51820 \
        --output "$work/profile-99.conf" --server-conf "$conf" >/dev/null 2>&1
    "$real_wg" set wg0 peer "$(sed -n 's/^PrivateKey = //p' "$work/profile-99.conf" | "$real_wg" pubkey)" remove
    output=$(status_script); rc=$?
    matches "a configured peer that is not on the interface is MISSING" "$output" '^18225099 +10\.66\.0\.99 +- +MISSING$'

    ip link del wg0
    output=$(status_script); rc=$?
    expect "interface down: exit status" 1 "$rc"
    expect "  every peer is UNKNOWN" 4 "$(printf '%s\n' "$output" | grep -c 'UNKNOWN$')"
fi

echo "== [$mode] result: $passed passed, $failed failed"
[ "$failed" -eq 0 ]
