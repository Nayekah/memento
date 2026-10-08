#!/usr/bin/env bash
# Checks token rotation and disabling through the real commands and the real
# API, against a throwaway PostgreSQL cluster. Needs the PostgreSQL server
# binaries, curl, and Go; skips when one is missing.
#
#   bash backend/scripts/token-state-test.sh
set -uo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
backend_dir=$(cd "$script_dir/.." && pwd)
for tool in initdb pg_ctl psql go curl; do
    command -v "$tool" >/dev/null 2>&1 || { echo "$tool is needed for this test; skipping."; exit 0; }
done
pg_port=${TOKEN_TEST_PG_PORT:-15441}
api_port=8067 # fixed in the API
for port in "$pg_port" "$api_port"; do
    if (exec 3<>"/dev/tcp/127.0.0.1/$port") 2>/dev/null; then
        echo "Port $port is in use; free it or set TOKEN_TEST_PG_PORT." >&2
        exit 2
    fi
done

work=$(mktemp -d)
api_pid=""
cleanup() {
    [ -z "$api_pid" ] || kill "$api_pid" 2>/dev/null
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
"$work/memento" api >"$work/api.log" 2>&1 &
api_pid=$!
for _ in $(seq 50); do curl -s -o /dev/null "http://127.0.0.1:$api_port/health" && break; sleep 0.2; done
memento student alice alice
memento student bob bob

# An authenticated request for a submission that does not exist: 404 means the
# student was accepted, 401 means they were refused.
probe() {
    curl -s -o "$work/out" -w '%{http_code}' -H "X-Memento-Student: $1" -H "X-Memento-Token: $2" \
        "http://127.0.0.1:$api_port/api/v1/submissions/aaaaaaaaaaaaaaaaaaaaaaaa"
}
message() { sed -n 's/.*"error":"\([^"]*\)".*/\1/p' "$work/out"; }
fails() { "$@" >/dev/null 2>&1; [ $? -ne 0 ] && echo refused || echo accepted; }

echo "== tokens before any rotation"
alice0=$(memento token alice)
bob0=$(memento token bob)
check "alice's original token is accepted" 404 "$(probe alice "$alice0")"
check "bob's original token is accepted" 404 "$(probe bob "$bob0")"
check "the token command prints the same token twice" "$alice0" "$(memento token alice)"

echo "== rotation"
alice1=$(memento rotate-token alice)
check "rotate-token prints a different token" different "$([ -n "$alice1" ] && [ "$alice1" != "$alice0" ] && echo different || echo same)"
check "the token command now prints the new token" "$alice1" "$(memento token alice)"
check "the old token is refused" 401 "$(probe alice "$alice0")"
check "  with the invalid token message" "invalid submission token" "$(message)"
check "the new token is accepted" 404 "$(probe alice "$alice1")"
check "bob's token is unaffected" 404 "$(probe bob "$bob0")"
check "rotating an unregistered student" refused "$(fails memento rotate-token ghost)"
check "rotate-token without a student ID" refused "$(fails memento rotate-token)"

echo "== disabling"
memento disable alice
check "a valid token for a disabled student is refused" 401 "$(probe alice "$alice1")"
check "  and says the account is disabled" "this student account is disabled" "$(message)"
probe alice AAAA-AAAA-AAAA >/dev/null
check "a wrong token for a disabled student gets the ordinary message" "invalid submission token" "$(message)"
check "bob is unaffected" 404 "$(probe bob "$bob0")"
memento enable alice
check "enabling restores access" 404 "$(probe alice "$alice1")"
check "disabling an unregistered student" refused "$(fails memento disable ghost)"

echo "== a student who is not registered"
activation=$(curl -s -o /dev/null -w '%{http_code}' -X POST -H "X-Memento-Student: ghost" -H "X-Memento-Token: $(memento token ghost)" \
    -H 'Content-Type: application/json' --data '{"device_id":"0123456789abcdef0123456789abcdef"}' "http://127.0.0.1:$api_port/api/v1/vm-activation")
check "the derived token still reaches the handler, which answers 403" 403 "$activation"

echo "== result: $passed passed, $failed failed"
[ "$failed" -eq 0 ]
