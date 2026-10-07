#!/usr/bin/env bash
# Checks peer binding end to end: a throwaway PostgreSQL, the real API, and
# real Caddy in front of it. Students connect from different loopback
# addresses (127.0.0.2 and 127.0.0.3) that stand in for VPN peers. Needs the
# PostgreSQL server binaries, caddy, curl, and Go; skips when one is missing.
#
#   bash backend/scripts/peer-binding-test.sh
set -uo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
backend_dir=$(cd "$script_dir/.." && pwd)
for tool in initdb pg_ctl psql go caddy curl; do
    command -v "$tool" >/dev/null 2>&1 || { echo "$tool is needed for this test; skipping."; exit 0; }
done
pg_port=${PEER_TEST_PG_PORT:-15437}
proxy_port=${PEER_TEST_PROXY_PORT:-18083}
api_port=8067 # fixed in the API
for port in "$pg_port" "$proxy_port" "$api_port"; do
    if (exec 3<>"/dev/tcp/127.0.0.1/$port") 2>/dev/null; then
        echo "Port $port is in use; free it or set PEER_TEST_PG_PORT or PEER_TEST_PROXY_PORT." >&2
        exit 2
    fi
done

work=$(mktemp -d)
api_pid=""
caddy_pid=""
stop_api() { [ -z "$api_pid" ] || { kill "$api_pid" 2>/dev/null; wait "$api_pid" 2>/dev/null; api_pid=""; }; }
cleanup() {
    stop_api
    [ -z "$caddy_pid" ] || kill "$caddy_pid" 2>/dev/null
    pg_ctl -D "$work/pg" -m fast stop >/dev/null 2>&1
    rm -rf "$work"
}
trap cleanup EXIT

passed=0
failed=0
check() { if [ "$2" = "$3" ]; then passed=$((passed + 1)); echo "PASS  $1 ($3)"; else failed=$((failed + 1)); echo "FAIL  $1: expected [$2], got [$3]"; fi; }

initdb -D "$work/pg" -A trust -U memento >/dev/null
pg_ctl -D "$work/pg" -o "-p $pg_port -k '' -c listen_addresses=127.0.0.1" -l "$work/pg.log" -w start >/dev/null
psql -h 127.0.0.1 -p "$pg_port" -U memento -d postgres -qc 'CREATE DATABASE memento'
export DATABASE_URL="postgresql://memento@127.0.0.1:$pg_port/memento?sslmode=disable"
TOKEN_SECRET=$(head -c 24 /dev/urandom | base64)
export TOKEN_SECRET
(cd "$backend_dir" && go build -o "$work/memento" ./cmd/memento) || { echo "go build failed" >&2; exit 1; }
memento() { "$work/memento" "$@"; }
for student in alice bob carol; do memento student "$student" "$student"; done
printf 'nim\tvpn_ip\tconfig_file\ttoken_file\nalice\t127.0.0.2\t/x.conf\t/x.token\nbob\t127.0.0.3\t/y.conf\t/y.token\n' | memento peers import >/dev/null
alice=$(memento token alice)
bob=$(memento token bob)
carol=$(memento token carol)

cat >"$work/Caddyfile" <<CADDY
{
    admin off
}
http://127.0.0.1:$proxy_port {
    reverse_proxy 127.0.0.1:$api_port
}
CADDY
XDG_DATA_HOME="$work/caddy" XDG_CONFIG_HOME="$work/caddy" caddy run --adapter caddyfile --config "$work/Caddyfile" >"$work/caddy.log" 2>&1 &
caddy_pid=$!

start_api() {
    stop_api
    PEER_BINDING=$1 TRUSTED_PROXY=127.0.0.1 "$work/memento" api >"$work/api.log" 2>&1 &
    api_pid=$!
    for _ in $(seq 50); do curl -s -o /dev/null "http://127.0.0.1:$api_port/health" && break; sleep 0.2; done
}

# An authenticated request for a submission that does not exist: 404 means the
# student was accepted, 401 means they were refused.
probe() { # source student token host:port [curl args...]
    local source=$1 student=$2 token=$3 target=$4
    shift 4
    curl -s --interface "$source" -o "$work/out" -w '%{http_code}' \
        -H "X-Memento-Student: $student" -H "X-Memento-Token: $token" "$@" \
        "http://$target/api/v1/submissions/aaaaaaaaaaaaaaaaaaaaaaaa"
}
via_proxy() { local source=$1 student=$2 token=$3; shift 3; probe "$source" "$student" "$token" "127.0.0.1:$proxy_port" "$@"; }
direct() { local source=$1 student=$2 token=$3; shift 3; probe "$source" "$student" "$token" "127.0.0.1:$api_port" "$@"; }
message() { sed -n 's/.*"error":"\([^"]*\)".*/\1/p' "$work/out"; }

for _ in $(seq 50); do curl -s -o /dev/null "http://127.0.0.1:$proxy_port/" && break; sleep 0.2; done

echo "== PEER_BINDING=enforce, through the proxy"
start_api enforce
check "alice from her own address" 404 "$(via_proxy 127.0.0.2 alice "$alice")"
check "bob from his own address" 404 "$(via_proxy 127.0.0.3 bob "$bob")"
check "alice's token from bob's address" 401 "$(via_proxy 127.0.0.3 alice "$alice")"
check "  the answer says the address is wrong" "this token is not valid from this address" "$(message)"
check "  with a forged X-Forwarded-For naming alice's address" 401 "$(via_proxy 127.0.0.3 alice "$alice" -H 'X-Forwarded-For: 127.0.0.2')"
check "  with two forged header lines" 401 "$(via_proxy 127.0.0.3 alice "$alice" -H 'X-Forwarded-For: 127.0.0.2' -H 'X-Forwarded-For: 127.0.0.2')"
check "  with a forged list" 401 "$(via_proxy 127.0.0.3 alice "$alice" -H 'X-Forwarded-For: 127.0.0.2, 127.0.0.2')"
check "carol has no registered address" 401 "$(via_proxy 127.0.0.2 carol "$carol")"
check "  the answer says so" "no VPN address is registered for this student" "$(message)"
check "a wrong token is refused before the address is looked at" 401 "$(via_proxy 127.0.0.2 alice AAAA-AAAA-AAAA)"
check "  the answer is about the token" "invalid submission token" "$(message)"

echo "== PEER_BINDING=enforce, straight to the API"
check "alice from her own address" 404 "$(direct 127.0.0.2 alice "$alice")"
check "bob cannot borrow alice's address with a forged header" 401 "$(direct 127.0.0.3 alice "$alice" -H 'X-Forwarded-For: 127.0.0.2')"

echo "== PEER_BINDING=log"
start_api log
check "alice's token from bob's address is allowed" 404 "$(via_proxy 127.0.0.3 alice "$alice")"
check "  and the mismatch is logged" 1 "$(grep -c 'peer binding: student=alice client=127.0.0.3' "$work/api.log")"

echo "== PEER_BINDING=off"
start_api off
check "alice's token from bob's address is allowed" 404 "$(via_proxy 127.0.0.3 alice "$alice")"
check "  and nothing is logged" 0 "$(grep -c 'peer binding' "$work/api.log")"

echo "== registration commands"
check "peer shows the registered address" 127.0.0.2 "$(memento peer alice)"
memento peer alice 127.0.0.3 >/dev/null 2>&1
check "an address held by another student is refused" 1 "$([ $? -ne 0 ] && echo 1 || echo 0)"
check "  and alice keeps hers" 127.0.0.2 "$(memento peer alice)"
memento peer alice --clear
check "peer --clear removes it" none "$(memento peer alice)"
start_api enforce
check "a student whose address was cleared is refused" 401 "$(via_proxy 127.0.0.2 alice "$alice")"
memento peer alice 127.0.0.2
check "registering the address again restores access" 404 "$(via_proxy 127.0.0.2 alice "$alice")"
printf 'alice\t127.0.0.2\nbob\t127.0.0.2\n' | memento peers import >/dev/null 2>&1
check "a manifest with a duplicate address is refused" 1 "$([ ${PIPESTATUS[1]} -ne 0 ] && echo 1 || echo 0)"
check "  and registers nothing from it" 127.0.0.3 "$(memento peer bob)"

echo "== result: $passed passed, $failed failed"
[ "$failed" -eq 0 ]
