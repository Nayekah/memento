#!/usr/bin/env bash
# Checks backup.sh and restore.sh against a throwaway PostgreSQL cluster. Needs
# the PostgreSQL server binaries, gpg, and Go; skips when one is missing.
#
#   bash backend/scripts/backup-test.sh
set -uo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
backend_dir=$(cd "$script_dir/.." && pwd)
for tool in initdb pg_ctl psql pg_dump pg_restore gpg gpgconf go; do
    command -v "$tool" >/dev/null 2>&1 || { echo "$tool is needed for this test; skipping."; exit 0; }
done
port=${BACKUP_TEST_PORT:-15433}
if (exec 3<>"/dev/tcp/127.0.0.1/$port") 2>/dev/null; then
    echo "Port $port is in use; set BACKUP_TEST_PORT to a free port." >&2
    exit 2
fi

work=$(mktemp -d)
mkdir -m 700 "$work/gnupg-test"
export GNUPGHOME="$work/gnupg-test"
cleanup() {
    pg_ctl -D "$work/pg" -m fast stop >/dev/null 2>&1
    gpgconf --kill gpg-agent >/dev/null 2>&1
    rm -rf "$work"
}
trap cleanup EXIT

passed=0
failed=0
ok() { passed=$((passed + 1)); echo "PASS  $1"; }
bad() {
    failed=$((failed + 1))
    echo "FAIL  $1"
    [ -z "${output:-}" ] || printf '%s\n' "$output" | head -8 | sed 's/^/        | /'
}
expect() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (expected [$2], got [$3])"; fi; }
fails() { if [ "$2" -ne 0 ]; then ok "$1"; else bad "$1 (command succeeded)"; fi; }

initdb -D "$work/pg" -A trust -U memento >/dev/null
pg_ctl -D "$work/pg" -o "-p $port -k '' -c listen_addresses=127.0.0.1" -l "$work/pg.log" -w start >/dev/null
export PGHOST=127.0.0.1 PGPORT=$port PGUSER=memento
psql -d postgres -qc 'CREATE DATABASE memento'
export DATABASE_URL="postgresql://memento@127.0.0.1:$port/memento?sslmode=disable"
(cd "$backend_dir" && go build -o "$work/memento" ./cmd/memento) || { echo "go build failed" >&2; exit 1; }
for n in 1 2 3 4 5; do "$work/memento" student "1822500$n" "Student $n"; done
marker="BACKUPMARKER-$$-$(date +%s)"
sql() { psql -d memento -At -c "$1"; }
sql "INSERT INTO submissions (id, student_id, source, source_sha256, status) VALUES
  ('aaaaaaaaaaaaaaaaaaaaaaa1', '18225001', convert_to('int x; /* $marker */', 'UTF8'), repeat('0', 64), 'queued'),
  ('aaaaaaaaaaaaaaaaaaaaaaa2', '18225002', convert_to('int y;', 'UTF8'), repeat('1', 64), 'queued'),
  ('aaaaaaaaaaaaaaaaaaaaaaa3', '18225003', convert_to('int z;', 'UTF8'), repeat('2', 64), 'queued')" >/dev/null
sql "INSERT INTO vm_activations (student_id, device_id) VALUES ('18225001', repeat('a', 32))" >/dev/null

umask 077
head -c 24 /dev/urandom | base64 >"$work/pass"
head -c 24 /dev/urandom | base64 >"$work/wrong"
out="$work/backups"
bk() { bash "$script_dir/backup.sh" --direct --passphrase-file "$work/pass" --output-dir "$out" "$@" 2>&1; }
rs() { bash "$script_dir/restore.sh" --direct --passphrase-file "${TEST_PASSFILE:-$work/pass}" "$@" 2>&1; }
leftover_databases() { sql "SELECT count(*) FROM pg_database WHERE datname LIKE 'memento_restore_check%'"; }

echo "== backup.sh"
output=$(bk); rc=$?
expect "backup exit status" 0 "$rc"
db_file=$(ls "$out"/memento-db-*.dump.gpg 2>/dev/null | head -1)
if [ -f "$db_file" ]; then ok "database backup written"; else bad "database backup written"; db_file=/nonexistent; fi
expect "  file mode" 600 "$(stat -c %a "$db_file" 2>/dev/null)"
expect "  directory mode" 700 "$(stat -c %a "$out")"
if (cd "$out" && sha256sum --status -c "$(basename "$db_file").sha256"); then ok "  checksum file verifies"; else bad "  checksum file verifies"; fi
pg_restore --list "$db_file" >/dev/null 2>&1; fails "  is not a readable dump without decrypting it" "$([ $? -ne 0 ] && echo 1 || echo 0)"
packets=$(timeout 30 gpg --batch --pinentry-mode cancel --list-packets "$db_file" </dev/null 2>/dev/null)
if printf '%s\n' "$packets" | grep -q 'cipher 9'; then ok "  is encrypted with AES-256"; else bad "  is encrypted with AES-256"; fi
if printf '%s\n' "$packets" | grep -q 'mdc_method: 2'; then ok "  is integrity protected"; else bad "  is integrity protected"; fi

echo "== restore drill"
output=$(rs --db-backup "$db_file" --verify); rc=$?
expect "drill exit status" 0 "$rc"
for line in 'students 5' 'submissions 3' 'vm_activations 1'; do
    if printf '%s\n' "$output" | grep -qx "$line"; then ok "  restored count: $line"; else bad "  restored count: $line"; fi
done
if printf '%s\n' "$output" | grep -Eq '^schema_migrations [1-9]'; then ok "  schema migrations restored"; else bad "  schema migrations restored"; fi
expect "  no temporary database is left behind" 0 "$(leftover_databases)"

output=$(TEST_PASSFILE="$work/wrong" rs --db-backup "$db_file" --verify); rc=$?
fails "drill with the wrong passphrase fails" "$rc"
expect "  no temporary database is created" 0 "$(leftover_databases)"
cp "$work/pass" "$work/loose"
chmod 644 "$work/loose"
output=$(TEST_PASSFILE="$work/loose" rs --db-backup "$db_file" --verify); rc=$?
expect "passphrase file readable by others is refused: exit status" 2 "$rc"

cp "$db_file" "$work/tampered.dump.gpg"
python3 - "$work/tampered.dump.gpg" <<'PY'
import sys
path = sys.argv[1]
data = bytearray(open(path, "rb").read())
data[len(data) // 2] ^= 0xFF
open(path, "wb").write(data)
PY
output=$(rs --db-backup "$work/tampered.dump.gpg" --verify); rc=$?
fails "tampered backup is rejected by the drill" "$rc"
expect "  no temporary database is created" 0 "$(leftover_databases)"

echo "== live restore"
sql "UPDATE students SET display_name = 'changed' WHERE id = '18225001'" >/dev/null
sql "DELETE FROM vm_activations" >/dev/null
output=$(rs --db-backup "$db_file" --restore-into memento); rc=$?
expect "restore without confirmation is refused: exit status" 2 "$rc"
expect "  nothing was changed" changed "$(sql "SELECT display_name FROM students WHERE id = '18225001'")"
output=$(rs --db-backup "$work/tampered.dump.gpg" --restore-into memento --yes-overwrite memento); rc=$?
fails "restore from a tampered backup fails" "$rc"
expect "  the database was left untouched" changed "$(sql "SELECT display_name FROM students WHERE id = '18225001'")"
output=$(rs --db-backup "$db_file" --restore-into memento --yes-overwrite memento); rc=$?
expect "confirmed restore: exit status" 0 "$rc"
expect "  edited row is back to its backed-up value" "Student 1" "$(sql "SELECT display_name FROM students WHERE id = '18225001'")"
expect "  deleted rows are back" 1 "$(sql "SELECT count(*) FROM vm_activations")"
expect "  submission source is intact" 1 "$(sql "SELECT count(*) FROM submissions WHERE convert_from(source, 'UTF8') LIKE '%$marker%'")"

echo "== retention and failure"
rm -rf "$out"
for _ in 1 2 3 4; do bk --keep 2 >/dev/null; sleep 1; done
expect "newest two database backups are kept" 2 "$(ls "$out"/memento-db-*.dump.gpg | wc -l | tr -d ' ')"
expect "  with their checksum files" 2 "$(ls "$out"/memento-db-*.sha256 | wc -l | tr -d ' ')"
before=$(ls "$out" | wc -l)
output=$(bk --database no_such_database); rc=$?
fails "backup of a missing database fails" "$rc"
expect "  leaves no partial or new file" "$before" "$(ls "$out" | wc -l)"

echo "== configuration archive"
mkdir -p "$work/cfg/scoreboard"
printf 'TOKEN_SECRET=%s\n' "$marker" >"$work/cfg/app.env"
printf 'hello\n' >"$work/cfg/scoreboard/config.json"
rm -rf "$out"
output=$(bk --config "$work/cfg/app.env" --config "$work/cfg/scoreboard/"); rc=$?
expect "backup with configuration: exit status" 0 "$rc"
cfg_file=$(ls "$out"/memento-config-*.tar.gz.gpg 2>/dev/null | head -1)
if [ -f "$cfg_file" ]; then ok "  configuration archive written"; else bad "  configuration archive written"; cfg_file=/nonexistent; fi
if grep -q "$marker" "$cfg_file" 2>/dev/null; then bad "  archive holds no plaintext"; else ok "  archive holds no plaintext"; fi
output=$(rs --config-backup "$cfg_file" --extract-to "$work/restored"); rc=$?
expect "extract: exit status" 0 "$rc"
expect "  secret file is restored" "TOKEN_SECRET=$marker" "$(cat "$work/restored/app.env" 2>/dev/null)"
expect "  directory is restored" hello "$(cat "$work/restored/scoreboard/config.json" 2>/dev/null)"
output=$(rs --config-backup "$cfg_file" --extract-to "$work/restored"); rc=$?
expect "extracting into a non-empty directory is refused: exit status" 2 "$rc"

echo "== Compose path (stub docker)"
mkdir -p "$work/bin"
: >"$work/compose.yaml"
cat >"$work/bin/docker" <<'STUB'
#!/usr/bin/env bash
# docker compose -f FILE exec -T postgres COMMAND...: run COMMAND against the local cluster.
printf '%s\n' "$*" >>"$STUB_DIR/docker.log"
args=("$@")
i=0
while [ "$i" -lt "${#args[@]}" ] && [ "${args[$i]}" != postgres ]; do i=$((i + 1)); done
exec "${args[@]:$((i + 1))}"
STUB
chmod +x "$work/bin/docker"
rm -rf "$out"
output=$(PATH="$work/bin:$PATH" STUB_DIR="$work" bash "$script_dir/backup.sh" --compose "$work/compose.yaml" --passphrase-file "$work/pass" --output-dir "$out" 2>&1); rc=$?
expect "backup through Compose: exit status" 0 "$rc"
if grep -q 'exec -T postgres pg_dump' "$work/docker.log"; then ok "  the dump ran inside the postgres service"; else bad "  the dump ran inside the postgres service"; fi
compose_backup=$(ls "$out"/memento-db-*.dump.gpg | head -1)
output=$(PATH="$work/bin:$PATH" STUB_DIR="$work" bash "$script_dir/restore.sh" --compose "$work/compose.yaml" --passphrase-file "$work/pass" --db-backup "$compose_backup" --verify 2>&1); rc=$?
expect "drill through Compose: exit status" 0 "$rc"
if printf '%s\n' "$output" | grep -qx 'students 5'; then ok "  restored counts match"; else bad "  restored counts match"; fi
if grep -q 'exec -T postgres pg_restore' "$work/docker.log"; then ok "  the restore ran inside the postgres service"; else bad "  the restore ran inside the postgres service"; fi

echo "== result: $passed passed, $failed failed"
[ "$failed" -eq 0 ]
