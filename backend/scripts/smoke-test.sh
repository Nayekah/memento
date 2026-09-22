#!/usr/bin/env bash
set -euo pipefail

project_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
source_file="$project_root/sandbox/src/bits.c"
check_dir=$(mktemp -d /tmp/memento-postgres-check.XXXXXX)
network="memento-check-$RANDOM"
postgres_name="memento-postgres-check-$RANDOM"
api_name="memento-api-check-$RANDOM"
worker_name="memento-worker-check-$RANDOM"
secret="test-secret-for-wsl-docker-smoke-check-12345"
password="test-postgres-password-12345"
database_url="postgresql://memento:${password}@postgres:5432/memento?sslmode=disable"

cleanup() {
    status=$?
    if [ "$status" -ne 0 ]; then
        echo "Smoke test failed; container diagnostics follow." >&2
        docker logs "$postgres_name" >&2 || true
        docker logs "$api_name" >&2 || true
        docker logs "$worker_name" >&2 || true
    fi
    docker rm -f "$worker_name" "$api_name" "$postgres_name" >/dev/null 2>&1 || true
    docker network rm "$network" >/dev/null 2>&1 || true
    docker run --rm --entrypoint sh -v "$check_dir:/cleanup" memento-worker:local \
        -c 'rm -rf /cleanup/*' >/dev/null 2>&1 || true
    rmdir "$check_dir" 2>/dev/null || true
}
trap cleanup EXIT

mkdir -p "$check_dir/work"
chmod 777 "$check_dir/work"
docker network create "$network" >/dev/null
docker run -d --rm --name "$postgres_name" --network "$network" --network-alias postgres \
    -e POSTGRES_DB=memento -e POSTGRES_USER=memento -e POSTGRES_PASSWORD="$password" \
    postgres:17-alpine >/dev/null

for _ in $(seq 1 30); do
    docker exec "$postgres_name" pg_isready -U memento -d memento >/dev/null 2>&1 && break
    sleep 1
done
docker exec "$postgres_name" pg_isready -U memento -d memento >/dev/null

token=$(docker run --rm --network "$network" -e DATABASE_URL="$database_url" -e TOKEN_SECRET="$secret" memento-api:local token student-001)
docker run --rm --network "$network" -e DATABASE_URL="$database_url" memento-api:local student student-001 "Student One" >/dev/null

docker run -d --rm --name "$api_name" --network "$network" \
    -e DATABASE_URL="$database_url" -e TOKEN_SECRET="$secret" \
    -p 127.0.0.1:18080:8067 memento-api:local api >/dev/null
for _ in $(seq 1 20); do curl --fail --silent http://127.0.0.1:18080/health >/dev/null && break; sleep 1; done
curl --fail --silent http://127.0.0.1:18080/health >/dev/null
echo "API and PostgreSQL health check passed"

activation=$(curl --fail --silent --show-error \
    -H "X-Memento-Student: student-001" -H "X-Memento-Token: $token" \
    -H 'Content-Type: application/json' --data '{"device_id":"0123456789abcdef0123456789abcdef"}' \
    http://127.0.0.1:18080/api/v1/vm-activation)
printf '%s' "$activation" | grep -q '"status":"activated"'
conflict_status=$(curl --silent --output /dev/null --write-out '%{http_code}' \
    -H "X-Memento-Student: student-001" -H "X-Memento-Token: $token" \
    -H 'Content-Type: application/json' --data '{"device_id":"fedcba9876543210fedcba9876543210"}' \
    http://127.0.0.1:18080/api/v1/vm-activation)
test "$conflict_status" = 409
echo "First-boot VM activation endpoint passed"

submission=$(curl --fail --silent --show-error -H "X-Memento-Student: student-001" -H "X-Memento-Token: $token" -F "source=@${source_file};filename=bits.c;type=text/x-c" http://127.0.0.1:18080/api/v1/submissions)
submission_id=$(printf '%s\n' "$submission" | sed -n 's/.*"id":"\([^"]*\)".*/\1/p')
test -n "$submission_id"
echo "Submission queued: $submission_id"

docker run -d --rm --name "$worker_name" --network "$network" \
    -e DATABASE_URL="$database_url" -e WORK_DIR=/worker-work -e DOCKER_WORK_DIR="$check_dir/work" -e GRADER_IMAGE=memento-datalab-grader:local \
    -v "$check_dir/work:/worker-work" -v /var/run/docker.sock:/var/run/docker.sock \
    memento-worker:local worker >/dev/null

for _ in $(seq 1 10); do
    queue_status=$(curl --fail --silent http://127.0.0.1:18080/api/v1/system/status)
    printf '%s' "$queue_status" | grep -q '"active_workers":1' && break
    sleep 1
done
printf '%s' "$queue_status" | grep -q '"active_workers":1'

for _ in $(seq 1 75); do
    result=$(curl --fail --silent --show-error -H "X-Memento-Student: student-001" -H "X-Memento-Token: $token" "http://127.0.0.1:18080/api/v1/submissions/$submission_id")
    if printf '%s' "$result" | grep -q '"status":"completed"'; then
        printf '%s\n' "$result"
        report=$(curl --fail --silent -H "X-Memento-Student: student-001" -H "X-Memento-Token: $token" "http://127.0.0.1:18080/api/v1/submissions/$submission_id/report")
        printf '%s' "$report" | grep -q '^Verdict: GRADED$'
        printf '%s' "$report" | grep -q '^Score: 0/71$'
        leaderboard=$(curl --fail --silent "http://127.0.0.1:18080/api/v1/leaderboard")
        printf '%s' "$leaderboard" | grep -q '"name":"Student One"'
        docker run --rm --network "$network" -e DATABASE_URL="$database_url" memento-api:local regrade "$submission_id" >/dev/null
        echo "Queue status, worker heartbeat, and regrade command passed"
        echo "PostgreSQL submission, worker, and leaderboard smoke test passed"
        exit 0
    fi
    if printf '%s' "$result" | grep -q '"status":"failed"'; then printf '%s\n' "$result" >&2; exit 1; fi
    sleep 1
done
echo "Timed out waiting for grading" >&2
exit 1
