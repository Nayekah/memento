#!/usr/bin/env bash
# Exercises peer-log.sh in three passes.
#
#   stub    A stubbed `wg` supplies handshakes, endpoints, and byte counts, so
#           every event and its timestamp are exact.
#   live    A real wg0 in a private network namespace supplies the real output
#           of `wg show`.
#   tunnel  A real handshake between two private network namespaces, including
#           the server following a client that changes its source address.
#
# The live and tunnel passes need unprivileged user namespaces and are skipped
# with a message when the machine does not allow them.
#
#   bash wireguard/test/log.test.sh
set -uo pipefail
umask 077

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
    tunnel_status=0
    if unshare -Urn sh -c 'ip link add wgprobe0 type wireguard' >/dev/null 2>&1; then
        unshare -Urn bash "$0" run-live || live_status=$?
        if command -v nsenter >/dev/null 2>&1 && command -v ping >/dev/null 2>&1; then
            unshare -Urn bash "$0" run-tunnel || tunnel_status=$?
        else
            echo '== tunnel pass skipped: nsenter and ping are needed'
        fi
    else
        echo '== live and tunnel passes skipped: this machine cannot create a WireGuard interface in a user namespace'
    fi
    [ "${stub_status:-0}" -eq 0 ] && [ "$live_status" -eq 0 ] && [ "$tunnel_status" -eq 0 ]
    exit $?
fi
mode=${mode#run-}

work=$(mktemp -d)
cleanup() {
    [ -z "${client_pid:-}" ] || kill "$client_pid" 2>/dev/null
    rm -rf "$work"
}
trap cleanup EXIT
export REAL_WG="$real_wg" STUB_DIR="$work"
"$real_wg" genkey >"$work/server.key"
"$real_wg" pubkey <"$work/server.key" >"$work/server.pub"

passed=0
failed=0
ok() { passed=$((passed + 1)); echo "PASS  $1"; }
bad() { failed=$((failed + 1)); echo "FAIL  $1"; [ -z "${output:-}" ] || printf '%s\n' "$output" | head -8 | sed 's/^/        | /'; }
expect() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (expected [$2], got [$3])"; fi; }
matches() { if printf '%s\n' "$2" | grep -Eq -- "$3"; then ok "$1"; else bad "$1 (no match for $3)"; fi; }

conf="$work/wg0.conf"
log="$work/events.log"
state="$work/state"
iso() { date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ; }
key_of() { sed -n 's/^PrivateKey = //p' "$work/profile-$1.conf" | "$real_wg" pubkey; }
run_log() { LOGGER_CALLS=1 sh "$wg_dir/peer-log.sh" --server-conf "$conf" --log-file "$log" --state-dir "$state" "$@"; }
mark=0
# step NOW takes one sample at NOW and leaves the lines it wrote in $new.
step() {
    run_log --once --now "$1" 2>"$work/stderr"
    rc=$?
    new=$(tail -n +$((mark + 1)) "$log")
    mark=$(wc -l <"$log")
}
provision() { # N: provisions student 1822500N at 10.66.0.(9+N)
    sh "$wg_dir/provision-peer.sh" --student "1822500$1" --address "10.66.0.$((9 + $1))" --endpoint vpn.example.edu:51820 \
        --output "$work/profile-$1.conf" --server-conf "$conf" >/dev/null 2>&1
}
# drop_block STUDENT removes the student's block from the server configuration.
drop_block() {
    awk -v id="$1" '
        $0 == "# student: " id { skipping = 1; next }
        skipping && /^[[:space:]]*$/ { skipping = 0; next }
        !skipping { print }
    ' "$conf" >"$conf.new" && mv "$conf.new" "$conf"
}
# The query the guide gives for the total time each student was silent.
gap_query='awk '"'"'/ event=recovered / { for (i = 1; i <= NF; i++) { split($i, kv, "="); v[kv[1]] = kv[2] } gaps[v["student"]]++; secs[v["student"]] += v["gap_seconds"] } END { for (s in gaps) printf "%s\t%d gaps\t%d s\n", s, gaps[s], secs[s] }'"'"' /var/log/memento-vpn-events.log'
changes_query="grep ' event=endpoint_changed ' /var/log/memento-vpn-events.log | awk '{ print \$3 }' | sort | uniq -c | sort -rn"
connected_query="grep -o ' event=connected student=[^ ]*' /var/log/memento-vpn-events.log | sed 's/.*student=//' | sort -u > connected.txt"
roster_query="sort -u roster.txt | comm -23 - connected.txt"
# doc_query runs one of the guide's queries on the test log, from the work directory.
doc_query() { (cd "$work" && sh -c "${1//\/var\/log\/memento-vpn-events.log/$log}"); }

printf '[Interface]\nAddress = 10.66.0.1/24\nListenPort = 51820\nPrivateKey = %s\n' "$(cat "$work/server.key")" >"$conf"

if [ "$mode" = stub ]; then
    mkdir -p "$work/bin"
    cat >"$work/bin/wg" <<'STUB'
#!/usr/bin/env bash
[ -z "${LOGGER_CALLS:-}" ] || echo "$*" >>"$STUB_DIR/calls"
case "${1:-}" in
    genkey|pubkey|genpsk) exec "$REAL_WG" "$@" ;;
    show)
        [ ! -e "$STUB_DIR/down" ] || exit 1
        case "${3:-}" in
            public-key) cat "$STUB_DIR/server.pub" ;;
            latest-handshakes|endpoints|transfer) cat "$STUB_DIR/$3" 2>/dev/null ;;
            *) echo "$*" >>"$STUB_DIR/unexpected"; cat "$STUB_DIR/server.key" ;;
        esac
        exit 0 ;;
    set) exit 0 ;;
esac
STUB
    chmod +x "$work/bin/wg"
    export PATH="$work/bin:$PATH"

    for n in 1 2 3 4; do provision "$n"; done
    # world N HANDSHAKE RX ENDPOINT adds one peer to what the stub reports.
    world_reset() { : >"$work/latest-handshakes"; : >"$work/endpoints"; : >"$work/transfer"; }
    world_extra() {
        printf '%s\t%s\n' "$stranger" "$1" >>"$work/latest-handshakes"
        printf '%s\t%s\n' "$stranger" "$2" >>"$work/endpoints"
        printf '%s\t100\t50\n' "$stranger" >>"$work/transfer"
    }
    world() {
        printf '%s\t%s\n' "$(key_of "$1")" "$2" >>"$work/latest-handshakes"
        printf '%s\t%s\n' "$(key_of "$1")" "$4" >>"$work/endpoints"
        printf '%s\t%s\t%s\n' "$(key_of "$1")" "$3" "$(($3 / 2))" >>"$work/transfer"
    }
    # peers_at T1 RX1 EP1 T2 RX2 EP2: peers 1 and 2 as given, 3 and 4 never connected.
    peers_at() {
        world_reset
        world 1 "$1" "$2" "$3"
        world 2 "$4" "$5" "$6"
        [ -n "${revoked3:-}" ] || world 3 0 0 '(none)'
        world 4 0 0 '(none)'
        [ -z "${have5:-}" ] || world 5 0 0 '(none)'
        [ -z "${stranger_at:-}" ] || world_extra "$stranger_at" 192.0.2.9:5000
    }
    stranger=$("$real_wg" genkey | "$real_wg" pubkey)
    t0=1000000
    ep1=203.0.113.7:51820
    ep2=198.51.100.4:40000
    : >"$work/calls"

    echo "== [stub] a timeline, one sample at a time"
    peers_at 0 0 '(none)' 0 0 '(none)'
    step "$t0"
    expect "first sample: exit status" 0 "$rc"
    expect "  nobody has connected, so only a summary is written" "$(iso "$t0") event=summary peers=4 up=0 silent=0 never=4 missing=0 unknown=0" "$new"
    expect "  the log is private" 600 "$(stat -c %a "$log")"
    expect "  so is the state directory" 700 "$(stat -c %a "$state")"

    peers_at $((t0 + 8)) 148 "$ep1" 0 0 '(none)'
    step $((t0 + 10))
    expect "a first handshake is a connection" "$(iso $((t0 + 10))) event=connected student=18225001 address=10.66.0.10 endpoint=$ep1" "$new"

    peers_at $((t0 + 8)) 148 "$ep1" $((t0 + 18)) 148 "$ep2"
    step $((t0 + 20))
    expect "the second student connects" "$(iso $((t0 + 20))) event=connected student=18225002 address=10.66.0.11 endpoint=$ep2" "$new"

    step $((t0 + 30))
    expect "nothing changed, nothing written" "" "$new"

    peers_at $((t0 + 8)) 300 "$ep1" $((t0 + 18)) 148 "$ep2"
    step $((t0 + 60))
    expect "the summary comes once a minute" "$(iso $((t0 + 60))) event=summary peers=4 up=2 silent=0 never=2 missing=0 unknown=0" "$new"

    step $((t0 + 70))
    expect "fifty seconds of quiet is not silence yet" "" "$new"
    step $((t0 + 80))
    expect "sixty seconds exactly is still not silence" "" "$new"
    step $((t0 + 81))
    expect "sixty-one seconds without a sign of life is silence" "$(iso $((t0 + 81))) event=silent student=18225002 address=10.66.0.11 idle_seconds=61 endpoint=$ep2" "$new"
    step $((t0 + 90))
    expect "silence is reported once" "" "$new"

    peers_at $((t0 + 8)) 300 "$ep1" $((t0 + 18)) 300 "$ep2"
    step $((t0 + 100))
    expect "traffic after silence is a recovery, with the length of the gap" "$(iso $((t0 + 100))) event=recovered student=18225002 address=10.66.0.11 gap_seconds=80 endpoint=$ep2" "$new"

    peers_at $((t0 + 8)) 300 "$ep1" $((t0 + 18)) 400 203.0.113.99:40000
    step $((t0 + 110))
    expect "a new public address is recorded with both addresses" "$(iso $((t0 + 110))) event=endpoint_changed student=18225002 address=10.66.0.11 from=$ep2 to=203.0.113.99:40000" "$new"

    peers_at $((t0 + 8)) 400 "$ep1" $((t0 + 18)) 500 203.0.113.99:41234
    step $((t0 + 120))
    expect "a new port on the same address is not a change" "$(iso $((t0 + 120))) event=summary peers=4 up=2 silent=0 never=2 missing=0 unknown=0" "$new"

    echo "== [stub] provisioning, revocation, and strangers"
    drop_block 18225003
    revoked3=1
    peers_at $((t0 + 8)) 500 "$ep1" $((t0 + 18)) 600 203.0.113.99:41234
    step $((t0 + 130))
    expect "a peer that leaves the configuration is recorded" "$(iso $((t0 + 130))) event=peer_removed student=18225003 address=10.66.0.12 reason=not_in_config" "$new"

    provision 5
    have5=1
    peers_at $((t0 + 8)) 500 "$ep1" $((t0 + 18)) 600 203.0.113.99:41234
    step $((t0 + 140))
    expect "a newly provisioned peer is recorded" "$(iso $((t0 + 140))) event=peer_added student=18225005 address=10.66.0.14" "$new"

    stranger_at=$((t0 + 145))
    peers_at $((t0 + 8)) 500 "$ep1" $((t0 + 18)) 600 203.0.113.99:41234
    step $((t0 + 150))
    expect "a peer the configuration does not name is reported with its key" "$(iso $((t0 + 150))) event=unknown_peer key=$stranger endpoint=192.0.2.9:5000" "$new"
    step $((t0 + 160))
    expect "  and only once" "" "$new"

    echo "== [stub] the interface goes away and comes back"
    touch "$work/down"
    step $((t0 + 170))
    expect "an unreadable interface is reported" "$(iso $((t0 + 170))) event=interface_down interface=wg0" "$new"
    step $((t0 + 180))
    expect "  once, and the summary says why it has no counts" "$(iso $((t0 + 180))) event=summary peers=4 interface=down" "$new"
    rm -f "$work/down"
    peers_at $((t0 + 8)) 700 "$ep1" $((t0 + 18)) 800 203.0.113.99:41234
    step $((t0 + 190))
    expect "the interface returning is reported, and nobody is called new" "$(iso $((t0 + 190))) event=interface_up interface=wg0" "$new"

    echo "== [stub] state and names"
    peers_at $((t0 + 195)) 900 "$ep1" $((t0 + 100)) 900 203.0.113.99:41234
    rm -rf "$state"
    step $((t0 + 200))
    expected=$(printf '%s\n' \
        "$(iso $((t0 + 200))) event=connected student=18225001 address=10.66.0.10 endpoint=$ep1 baseline=1" \
        "$(iso $((t0 + 200))) event=silent student=18225002 address=10.66.0.11 idle_seconds=100 endpoint=203.0.113.99:41234 baseline=1" \
        "$(iso $((t0 + 200))) event=unknown_peer key=$stranger endpoint=192.0.2.9:5000" \
        "$(iso $((t0 + 200))) event=summary peers=4 up=1 silent=1 never=2 missing=0 unknown=1")
    expect "with no state, what the logger finds is marked as already there, and nobody is announced as added" "$expected" "$new"

    weird=$("$real_wg" genkey | "$real_wg" pubkey)
    printf '\n# student: we ird;x\n[Peer]\nPublicKey = %s\nAllowedIPs = 10.66.0.77/32\n' "$weird" >>"$conf"
    printf '%s\t0\n' "$weird" >>"$work/latest-handshakes"
    printf '%s\t(none)\n' "$weird" >>"$work/endpoints"
    printf '%s\t0\t0\n' "$weird" >>"$work/transfer"
    step $((t0 + 210))
    expect "a student name is made safe for the log" "$(iso $((t0 + 210))) event=peer_added student=we_ird_x address=10.66.0.77" "$new"

    echo "== [stub] a handshake alone is a sign of life"
    solo="$work/solo.conf"
    printf '[Interface]\nPrivateKey = unused\n' >"$solo"
    awk '/^# student: 18225001$/ { found = 1 } found { print } found && /^[[:space:]]*$/ { exit }' "$conf" >>"$solo"
    solo_run() { LOGGER_CALLS=1 sh "$wg_dir/peer-log.sh" --once --now "$1" --server-conf "$solo" --log-file "$work/solo.log" --state-dir "$work/solo-state"; }
    base=2000000
    world_reset; world 1 $((base - 5)) 100 "$ep1"
    solo_run "$base"
    solo_run $((base + 100))
    world_reset; world 1 $((base + 105)) 100 "$ep1"
    solo_run $((base + 110))
    expected=$(printf '%s\n' \
        "$(iso "$base") event=connected student=18225001 address=10.66.0.10 endpoint=$ep1 baseline=1" \
        "$(iso $((base + 100))) event=silent student=18225001 address=10.66.0.10 idle_seconds=105 endpoint=$ep1" \
        "$(iso $((base + 110))) event=recovered student=18225001 address=10.66.0.10 gap_seconds=115 endpoint=$ep1")
    expect "a newer handshake with no new bytes ends the silence" "$expected" "$(grep -v 'event=summary' "$work/solo.log")"

    echo "== [stub] what the log must never hold"
    expect "no call asked wg for more than the three per-peer fields" 0 "$(grep -c -v -E '^show wg0 (latest-handshakes|endpoints|transfer)$' "$work/calls" || true)"
    expect "  the stub saw at least the three it expects" 1 "$([ "$(grep -c -E '^show wg0 (latest-handshakes|endpoints|transfer)$' "$work/calls")" -ge 3 ] && echo 1 || echo 0)"
    expect "  nothing asked for the private key" "no" "$([ -e "$work/unexpected" ] && echo yes || echo no)"
    leaked=0
    for secret in "$(cat "$work/server.key")" $(sed -n 's/^PresharedKey = //p' "$conf"); do
        if grep -rqF -- "$secret" "$log" "$state"; then leaked=$((leaked + 1)); fi
    done
    expect "no private key or preshared key reached the log or the state" 0 "$leaked"

    echo "== [stub] the guide's queries"
    expect "total gap for the student who recovered" "$(printf '18225002\t1 gaps\t80 s')" "$(doc_query "$gap_query")"
    expect "addresses changed, most changes first" "1 student=18225002" "$(doc_query "$changes_query" | sed 's/^ *//')"
    printf '18225001\n18225002\n18225003\n18225004\n18225005\n' >"$work/roster.txt"
    doc_query "$connected_query"
    expect "who never connected" "$(printf '18225003\n18225004\n18225005')" "$(doc_query "$roster_query")"
    if [ -f "$wg_dir/INCIDENT-LOGS.md" ]; then
        for query in "$gap_query" "$changes_query" "$connected_query" "$roster_query"; do
            if grep -qF -- "$query" "$wg_dir/INCIDENT-LOGS.md"; then ok "  the guide gives this query: ${query:0:48}"; else bad "  the guide does not give this query: ${query:0:48}"; fi
        done
    fi

    echo "== [stub] running as a service"
    loop_log="$work/loop.log"
    loop_state="$work/loop-state"
    printf '[Interface]\nPrivateKey = unused\n' >"$work/empty.conf"
    : >"$work/latest-handshakes"; : >"$work/endpoints"; : >"$work/transfer"
    sh "$wg_dir/peer-log.sh" --server-conf "$work/empty.conf" --log-file "$loop_log" --state-dir "$loop_state" --interval 1 >/dev/null 2>&1 &
    pid=$!
    sleep 2.5
    kill -TERM "$pid"
    wait "$pid"; rc=$?
    expect "stopping it is a clean exit" 0 "$rc"
    matches "  the first line says it started, with its settings" "$(head -1 "$loop_log")" 'event=start interface=wg0 interval=1 silent_after=60 summary_every=60$'
    matches "  a summary follows" "$(sed -n 2p "$loop_log")" 'event=summary peers=[0-9]+ '
    matches "  the last line says it stopped" "$(tail -1 "$loop_log")" 'event=stop$'
    sh "$wg_dir/peer-log.sh" --server-conf "$work/empty.conf" --log-file "$loop_log" --state-dir "$loop_state" --interval 1 >/dev/null 2>&1 &
    pid=$!
    sleep 1.5
    kill -TERM "$pid"
    wait "$pid" || true
    matches "  a restart records how long the logger was away" "$(grep 'event=start' "$loop_log" | tail -1)" 'previous_sample_age=[0-9]+$'

    echo "== [stub] arguments"
    for args in '--interval 0' '--interval abc' '--silent-seconds 0' '--summary-seconds 0' '--summary-seconds -5' '--interface a/b' '--now abc' '--nonsense' '--help'; do
        # shellcheck disable=SC2086
        output=$(run_log --once $args 2>&1); rc=$?
        expect "$args: exit status" 2 "$rc"
    done
    # Without --once the logger would run forever, so a regression must fail here, not hang.
    output=$(LOGGER_CALLS=1 timeout 5 sh "$wg_dir/peer-log.sh" --server-conf "$conf" --log-file "$log" --state-dir "$state" --now 5 2>&1); rc=$?
    expect "--now without --once: exit status" 2 "$rc"
    output=$(sh "$wg_dir/peer-log.sh" --once --server-conf "$work/missing.conf" --log-file "$log" --state-dir "$state" 2>&1); rc=$?
    expect "missing server config: exit status" 1 "$rc"
    output=$(sh "$wg_dir/peer-log.sh" --once --now 5000 --server-conf "$work/empty.conf" --log-file "$work/empty.log" --state-dir "$work/empty-state" 2>&1); rc=$?
    expect "a configuration without students: exit status" 0 "$rc"
    expect "  the summary counts zero peers" "$(iso 5000) event=summary peers=0 up=0 silent=0 never=0 missing=0 unknown=0" "$(cat "$work/empty.log")"

elif [ "$mode" = live ]; then
    ip link add wg0 type wireguard
    "$real_wg" set wg0 private-key "$work/server.key" listen-port 51820
    for n in 1 2 3; do provision "$n"; done
    now=$(date +%s)

    echo "== [live] the real wg output"
    step "$now"
    expect "first sample: exit status" 0 "$rc"
    expect "  three peers that have not connected" "$(iso "$now") event=summary peers=3 up=0 silent=0 never=3 missing=0 unknown=0" "$new"
    expect "  nothing unexpected on stderr" "" "$(cat "$work/stderr")"

    rogue=$("$real_wg" genkey | "$real_wg" pubkey)
    "$real_wg" set wg0 peer "$rogue" allowed-ips 10.66.0.200/32
    step $((now + 10))
    expect "a peer added to the interface but not the configuration" "$(iso $((now + 10))) event=unknown_peer key=$rogue endpoint=-" "$new"

    "$real_wg" set wg0 peer "$(key_of 2)" remove
    step $((now + 20))
    expect "a configured peer taken off the interface" "$(iso $((now + 20))) event=peer_removed student=18225002 address=10.66.0.11 reason=not_on_interface" "$new"

    expect "the private key is not in the log or the state" "no" "$(grep -rqF -- "$(cat "$work/server.key")" "$log" "$state" && echo yes || echo no)"

    ip link del wg0
    step $((now + 30))
    expect "the interface disappearing" "$(iso $((now + 30))) event=interface_down interface=wg0" "$new"

else
    # tunnel: a real handshake between two network namespaces.
    ip link set lo up
    unshare -n sleep 300 &
    client_pid=$!
    sleep 0.5
    ip link add vs type veth peer name vc
    ip link set vc netns "$client_pid"
    ip addr add 192.0.2.1/29 dev vs
    ip link set vs up
    client() { nsenter -t "$client_pid" -n "$@"; }
    client ip link set lo up
    client ip addr add 192.0.2.2/29 dev vc
    client ip link set vc up

    ip link add wg0 type wireguard
    "$real_wg" set wg0 private-key "$work/server.key" listen-port 51820
    ip addr add 10.66.0.1/24 dev wg0
    ip link set wg0 up
    provision 1
    profile="$work/profile-1.conf"
    sed -n 's/^PrivateKey = //p' "$profile" >"$work/client.key"
    sed -n 's/^PresharedKey = //p' "$profile" >"$work/client.psk"
    client ip link add wg0 type wireguard
    client "$real_wg" set wg0 listen-port 40000 private-key "$work/client.key" \
        peer "$(cat "$work/server.pub")" preshared-key "$work/client.psk" \
        endpoint 192.0.2.1:51820 allowed-ips 10.66.0.0/24 persistent-keepalive 1
    client ip addr add 10.66.0.10/32 dev wg0
    # client_up brings the tunnel up and restores the route, which goes away with the link.
    client_up() { client ip link set wg0 up && client ip route replace 10.66.0.0/24 dev wg0; }

    handshakes() { "$real_wg" show wg0 latest-handshakes | cut -f2; }
    received() { "$real_wg" show wg0 transfer | cut -f2; }
    # wait_for_traffic waits until the server has received more than $1 bytes.
    wait_for_traffic() {
        for _ in $(seq 1 100); do
            [ "$(received)" -gt "$1" ] && return 0
            sleep 0.1
        done
        return 1
    }

    echo "== [tunnel] a real handshake"
    now=$(date +%s)
    step "$now"
    expect "before the client is up, the peer has never connected" "$(iso "$now") event=summary peers=1 up=0 silent=0 never=1 missing=0 unknown=0" "$new"

    client_up
    client ping -c 1 -W 2 10.66.0.1 >/dev/null 2>&1
    wait_for_traffic 0
    expect "the server saw a handshake" 1 "$([ "$(handshakes)" -gt 0 ] && echo 1 || echo 0)"
    now=$(date +%s)
    step "$now"
    matches "the log records the connection with the client's public address" "$new" "event=connected student=18225001 address=10.66.0.10 endpoint=192\.0\.2\.2:[0-9]+$"
    endpoint=$(printf '%s\n' "$new" | sed -n 's/.*endpoint=//p')
    port=${endpoint##*:}
    expect "  from the port the client was given" 40000 "$port"

    echo "== [tunnel] silence and recovery"
    # A packet after the last sample guarantees the next sample sees a sign of
    # life, whatever the keepalive timing, so the silence below starts at $settled.
    client ping -c 1 -W 2 10.66.0.1 >/dev/null 2>&1
    client ip link set wg0 down
    sleep 2
    settled=$(date +%s)
    step "$settled"
    expect "a sample after the last packet arrived writes nothing" "" "$new"
    step $((settled + 100))
    expect "no traffic for a while is silence" "$(iso $((settled + 100))) event=silent student=18225001 address=10.66.0.10 idle_seconds=100 endpoint=$endpoint" "$(printf '%s\n' "$new" | grep -v 'event=summary')"
    before=$(received)
    client_up
    client ping -c 1 -W 2 10.66.0.1 >/dev/null 2>&1
    wait_for_traffic "$before"
    step $((settled + 110))
    expect "traffic again is a recovery" "$(iso $((settled + 110))) event=recovered student=18225001 address=10.66.0.10 gap_seconds=110 endpoint=$endpoint" "$new"

    echo "== [tunnel] the client changes its source address"
    before=$(received)
    client ip addr add 192.0.2.3/29 dev vc
    client ip addr del 192.0.2.2/29 dev vc
    sleep 1
    client ping -c 1 -W 2 10.66.0.1 >/dev/null 2>&1
    wait_for_traffic "$before"
    step $((settled + 120))
    expect "the server follows the client and the log shows both addresses" "$(iso $((settled + 120))) event=endpoint_changed student=18225001 address=10.66.0.10 from=$endpoint to=192.0.2.3:$port" "$new"

    echo "== [tunnel] revocation"
    "$real_wg" set wg0 peer "$(key_of 1)" remove
    drop_block 18225001
    step $((settled + 130))
    expect "a revoked peer is recorded" "$(iso $((settled + 130))) event=peer_removed student=18225001 address=10.66.0.10 reason=not_in_config" "$new"
    expect "no key material reached the log or the state" "no" "$(grep -rqF -e "$(cat "$work/server.key")" -e "$(cat "$work/client.key")" -e "$(cat "$work/client.psk")" "$log" "$state" && echo yes || echo no)"
fi

echo "== [$mode] result: $passed passed, $failed failed"
[ "$failed" -eq 0 ]
