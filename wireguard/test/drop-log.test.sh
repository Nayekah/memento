#!/usr/bin/env bash
# Exercises the logging rules in memento-vpn.nft inside private user and
# network namespaces, so no root is needed.
#
#   rules    The file loads, every wg0 drop is preceded by a rate-limited log,
#            and the accept rules are the ones the deny-by-default policy needs.
#   traffic  Three clients with real WireGuard tunnels send real packets at the
#            real rules. The rule counters show how many packets reached the
#            log statement and how many were dropped.
#
# The kernel writes the log lines themselves to the host's kernel log, which a
# private namespace does not do, so the counters on the log rules are what is
# checked here.
#
#   bash wireguard/test/drop-log.test.sh
set -uo pipefail
umask 077

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
wg_dir=$(cd "$script_dir/.." && pwd)
rules_file="$wg_dir/memento-vpn.nft"
mode=${1:-all}

for tool in wg nft ip unshare nsenter ping; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo "$tool is needed for this test; skipping."
        exit 0
    fi
done
real_wg=$(command -v wg)

if [ "$mode" = all ]; then
    if ! unshare -Urn nft -c -f "$rules_file" >/dev/null 2>&1; then
        echo '== skipped: this machine cannot load nftables rules in a user namespace'
        exit 0
    fi
    rules_status=0
    traffic_status=0
    unshare -Urn bash "$0" run-rules || rules_status=$?
    if unshare -Urn sh -c 'ip link add wgprobe0 type wireguard' >/dev/null 2>&1; then
        unshare -Urn bash "$0" run-traffic || traffic_status=$?
    else
        echo '== traffic pass skipped: this machine cannot create a WireGuard interface in a user namespace'
    fi
    [ "$rules_status" -eq 0 ] && [ "$traffic_status" -eq 0 ]
    exit $?
fi
mode=${mode#run-}

work=$(mktemp -d)
cleanup() {
    for pid in "${client_pids[@]:-}"; do [ -z "$pid" ] || kill "$pid" 2>/dev/null; done
    rm -rf "$work"
}
client_pids=()
trap cleanup EXIT

passed=0
failed=0
ok() { passed=$((passed + 1)); echo "PASS  $1"; }
bad() { failed=$((failed + 1)); echo "FAIL  $1"; [ -z "${output:-}" ] || printf '%s\n' "$output" | head -8 | sed 's/^/        | /'; }
expect() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (expected [$2], got [$3])"; fi; }
# between LABEL VALUE MIN MAX
between() { if [ "$2" -ge "$3" ] && [ "$2" -le "$4" ]; then ok "$1"; else bad "$1 (expected $3 to $4, got $2)"; fi; }
# line_of CHAIN PATTERN prints the line number of the first rule that matches.
line_of() { nft list chain inet memento_vpn "$1" | grep -n -E -- "$2" | head -1 | cut -d: -f1; }
# counter CHAIN KIND prints the packet counter of the log rule or of the drop rule.
counter() {
    nft list chain inet memento_vpn "$1" | awk -v kind="$2" '
        kind == "log" && /log prefix/ || kind == "drop" && / drop$/ {
            for (i = 1; i < NF; i++) if ($i == "counter" && $(i + 1) == "packets") { print $(i + 2); exit }
        }'
}

if [ "$mode" = rules ]; then
    echo "== [rules] the file"
    output=$(nft -c -f "$rules_file" 2>&1); rc=$?
    expect "the file passes a syntax check" 0 "$rc"
    output=$(nft -f "$rules_file" 2>&1); rc=$?
    expect "it loads" 0 "$rc"
    output=$(nft delete table inet memento_vpn 2>&1 && nft -f "$rules_file" 2>&1); rc=$?
    expect "it reloads the way wg0.conf does (delete the table, then load)" 0 "$rc"

    echo "== [rules] the policy"
    expect "input: the three services students may use" 3 "$(nft list chain inet memento_vpn input | grep -c -E 'iifname "wg0" ip saddr 10\.66\.0\.0/24 (udp dport 53|tcp dport 53|tcp dport 443) accept$')"
    expect "forward: HTTPS to the proxy only" 1 "$(nft list chain inet memento_vpn forward | grep -c -E 'iifname "wg0" oifname "br-\*" ip daddr 172\.30\.0\.4 tcp dport 443 accept$')"
    for chain in input forward; do
        expect "$chain: exactly one drop for wg0" 1 "$(nft list chain inet memento_vpn "$chain" | grep -c -E 'iifname "wg0" counter packets [0-9]+ bytes [0-9]+ drop$')"
        log_line=$(line_of "$chain" 'log prefix "memento-vpn-drop: "')
        drop_line=$(line_of "$chain" ' drop$')
        expect "$chain: a log rule exists" 1 "$([ -n "$log_line" ] && echo 1 || echo 0)"
        expect "$chain: the log comes before the drop" 1 "$([ -n "$log_line" ] && [ "$log_line" -lt "$drop_line" ] && echo 1 || echo 0)"
        expect "$chain: the log is limited per source address" 1 "$(nft list chain inet memento_vpn "$chain" | grep -c -E 'add @drop_log \{ ip saddr limit rate 6/minute burst 3 packets \}')"
        expect "$chain: nothing is logged or dropped before the accepts" 0 "$(nft list chain inet memento_vpn "$chain" | sed -n "1,$((log_line - 1))p" | grep -c -E 'log|drop')"
    done
    expect "the allowance set is dynamic, so addresses are added as they appear" 1 "$(nft list set inet memento_vpn drop_log | grep -c 'flags dynamic')"
else
    # traffic: three clients, each with a real tunnel to the server.
    ip link set lo up
    "$real_wg" genkey >"$work/server.key"
    "$real_wg" pubkey <"$work/server.key" >"$work/server.pub"
    conf="$work/wg0.conf"
    printf '[Interface]\nAddress = 10.66.0.1/24\nListenPort = 51820\nPrivateKey = unused\n' >"$conf"
    ip link add wg0 type wireguard
    "$real_wg" set wg0 private-key "$work/server.key" listen-port 51820
    ip addr add 10.66.0.1/24 dev wg0
    ip link set wg0 up
    # An upstream the server could forward to, so the forward chain sees traffic.
    ip link add up0 type veth peer name up1
    ip link set up0 up
    ip link set up1 up
    ip addr add 198.51.100.1/24 dev up0
    sysctl -qw net.ipv4.ip_forward=1 2>/dev/null || echo 'note: could not enable forwarding; the forward chain is not exercised'

    client_netns() { nsenter -t "${client_pids[$1]}" -n "${@:2}"; }
    # make_client N creates client N: a namespace, a veth pair, and a tunnel that sends everything to the server.
    make_client() {
        local n=$1 underlay_server=192.0.2.$((4 * $1 - 3)) underlay_client=192.0.2.$((4 * $1 - 2)) own
        own=$(readlink /proc/self/ns/net)
        unshare -n sleep 300 &
        client_pids[n]=$!
        for _ in $(seq 1 50); do
            [ "$(readlink "/proc/${client_pids[$n]}/ns/net" 2>/dev/null)" != "$own" ] && break
            sleep 0.1
        done
        ip link add "vs$n" type veth peer name "vc$n"
        ip link set "vc$n" netns "${client_pids[$n]}"
        ip addr add "$underlay_server/30" dev "vs$n"
        ip link set "vs$n" up
        client_netns "$n" ip link set lo up
        client_netns "$n" ip addr add "$underlay_client/30" dev "vc$n"
        client_netns "$n" ip link set "vc$n" up
        sh "$wg_dir/provision-peer.sh" --student "1822500$n" --address "10.66.0.$((9 + n))" --endpoint "$underlay_server:51820" \
            --output "$work/profile-$n.conf" --server-conf "$conf" >/dev/null 2>&1
        sed -n 's/^PrivateKey = //p' "$work/profile-$n.conf" >"$work/client-$n.key"
        sed -n 's/^PresharedKey = //p' "$work/profile-$n.conf" >"$work/client-$n.psk"
        client_netns "$n" ip link add wg0 type wireguard
        client_netns "$n" "$real_wg" set wg0 private-key "$work/client-$n.key" \
            peer "$(cat "$work/server.pub")" preshared-key "$work/client-$n.psk" \
            endpoint "$underlay_server:51820" allowed-ips 0.0.0.0/0 persistent-keepalive 1
        client_netns "$n" ip addr add "10.66.0.$((9 + n))/32" dev wg0
        client_netns "$n" ip link set wg0 up
        client_netns "$n" ip route replace default dev wg0
    }
    # connected N waits until the server has completed a handshake with client N.
    connected() {
        local key
        key=$(client_netns "$1" "$real_wg" show wg0 public-key)
        for _ in $(seq 1 100); do
            [ "$("$real_wg" show wg0 latest-handshakes | awk -v k="$key" '$1 == k { print $2 }')" != 0 ] && return 0
            sleep 0.1
        done
        return 1
    }
    # flood N TARGET COUNT sends COUNT quick pings from client N.
    flood() { client_netns "$1" ping -q -c "$3" -i 0.05 -W 1 "$2" >/dev/null 2>&1; }

    for n in 1 2 3; do make_client "$n"; done
    for n in 1 2 3; do
        if connected "$n"; then ok "client $n has a tunnel"; else bad "client $n never completed a handshake"; fi
    done
    nft -f "$rules_file"

    echo "== [traffic] a source gets its own allowance"
    log_before=$(counter input log); drop_before=$(counter input drop)
    flood 1 10.66.0.1 20
    log_after=$(counter input log); drop_after=$(counter input drop)
    expect "client 1 sent 20 packets the server does not allow, and all were dropped" 20 $((drop_after - drop_before))
    between "  only its allowance reached the log" $((log_after - log_before)) 3 4

    log_before=$log_after; drop_before=$drop_after
    flood 2 10.66.0.1 20
    log_after=$(counter input log); drop_after=$(counter input drop)
    expect "client 2 is dropped just the same" 20 $((drop_after - drop_before))
    between "  and has an allowance of its own" $((log_after - log_before)) 3 4

    log_before=$log_after; drop_before=$drop_after
    flood 1 10.66.0.1 10
    log_after=$(counter input log); drop_after=$(counter input drop)
    expect "client 1 again: still dropped" 10 $((drop_after - drop_before))
    between "  but its allowance is used up, so the log stays quiet" $((log_after - log_before)) 0 1

    echo "== [traffic] what students may use is not logged or dropped"
    log_before=$log_after; drop_before=$drop_after
    client_netns 3 bash -c 'exec 3<>/dev/tcp/10.66.0.1/443' 2>/dev/null
    client_netns 3 bash -c 'echo hello >/dev/udp/10.66.0.1/53' 2>/dev/null
    expect "an HTTPS connection and a DNS query reach the host untouched" 0 $(($(counter input drop) - drop_before))
    expect "  and are not logged" 0 $(($(counter input log) - log_before))

    echo "== [traffic] the forward chain"
    if [ "$(cat /proc/sys/net/ipv4/ip_forward)" = 1 ]; then
        log_before=$(counter forward log); drop_before=$(counter forward drop)
        flood 3 198.51.100.50 5
        log_after=$(counter forward log); drop_after=$(counter forward drop)
        expect "client 3 reaching for an outside address is dropped" 5 $((drop_after - drop_before))
        between "  and its first packets are logged" $((log_after - log_before)) 3 4
    else
        echo "SKIP  forwarding is off in this namespace"
    fi

    echo "== [traffic] one entry per student address"
    set_listing=$(nft list set inet memento_vpn drop_log)
    for address in 10.66.0.10 10.66.0.11 10.66.0.12; do
        expect "the set has $address" 1 "$(printf '%s\n' "$set_listing" | grep -c -F "$address")"
    done
    expect "  and nothing else" 3 "$(printf '%s\n' "$set_listing" | grep -o -E '10\.66\.0\.[0-9]+' | sort -u | wc -l)"
fi

echo "== [$mode] result: $passed passed, $failed failed"
[ "$failed" -eq 0 ]
