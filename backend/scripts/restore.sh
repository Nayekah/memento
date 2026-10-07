#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=backup-common.sh
. "$script_dir/backup-common.sh"

usage() {
    cat >&2 <<'USAGE'
Usage:
  restore.sh --passphrase-file FILE --db-backup FILE --verify [options]
  restore.sh --passphrase-file FILE --db-backup FILE --restore-into NAME --yes-overwrite NAME [options]
  restore.sh --passphrase-file FILE --config-backup FILE --extract-to DIR [options]

--verify is the restore drill. It restores the backup into a temporary
database, prints row counts, and drops the database again, so nothing that
exists is touched.

--restore-into replaces the contents of an existing database with the backup.
Stop the API and the worker first. --yes-overwrite must repeat the name.

--extract-to unpacks the configuration archive into a new or empty directory.

Every backup is decrypted and authenticated in full before any database is
changed.

Options:
  --compose FILE   Run the PostgreSQL clients inside the postgres service of this
                   Compose file (default: backend/compose.yaml next to this script)
  --direct         Run the PostgreSQL clients from PATH; connection settings come
                   from the PG* variables
  --user NAME      Database user (default: memento)
USAGE
    exit 2
}

passphrase_file=""
db_backup=""
config_backup=""
action=""
target=""
confirm=""
extract_to=""
mode=compose
compose_file="$script_dir/../compose.yaml"
db_user=memento

set_action() {
    [ -z "$action" ] || [ "$action" = "$1" ] || { echo 'Choose only one of --verify, --restore-into, and --extract-to.' >&2; usage; }
    action=$1
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --passphrase-file) passphrase_file=${2:?missing passphrase file}; shift 2 ;;
        --db-backup) db_backup=${2:?missing backup file}; shift 2 ;;
        --config-backup) config_backup=${2:?missing backup file}; shift 2 ;;
        --verify) set_action verify; shift ;;
        --restore-into) set_action restore; target=${2:?missing database name}; shift 2 ;;
        --yes-overwrite) confirm=${2:?missing database name}; shift 2 ;;
        --extract-to) set_action extract; extract_to=${2:?missing directory}; shift 2 ;;
        --compose) mode=compose; compose_file=${2:?missing Compose file}; shift 2 ;;
        --direct) mode=direct; shift ;;
        --user) db_user=${2:?missing user name}; shift 2 ;;
        -h|--help) usage ;;
        *) echo "Unknown argument: $1" >&2; usage ;;
    esac
done

[ -n "$passphrase_file" ] && [ -n "$action" ] || usage
check_identifier 'User name' "$db_user"
check_passphrase_file "$passphrase_file"
require_tool gpg gpgconf
case "$action" in
    verify|restore)
        [ -n "$db_backup" ] || usage
        [ -f "$db_backup" ] || { echo "Backup not found: $db_backup" >&2; exit 2; }
        if [ "$mode" = compose ]; then
            require_tool docker
            setup_compose
        else
            require_tool psql pg_restore
        fi
        ;;
    extract)
        require_tool tar
        [ -n "$config_backup" ] || usage
        [ -f "$config_backup" ] || { echo "Backup not found: $config_backup" >&2; exit 2; }
        ;;
esac
if [ "$action" = restore ]; then
    check_identifier 'Database name' "$target"
    [ "$confirm" = "$target" ] || { echo "Refusing to overwrite $target. Pass --yes-overwrite $target to confirm." >&2; exit 2; }
fi

umask 077
scratch=""
cleanup() {
    local status=$?
    if [ -n "$scratch" ]; then
        db psql -U "$db_user" -d postgres -q -c "DROP DATABASE IF EXISTS $scratch" ||
            echo "Could not drop the temporary database $scratch; drop it manually." >&2
    fi
    stop_work
    exit "$status"
}
trap cleanup EXIT
start_work

case "$action" in
    extract)
        if [ -e "$extract_to" ] && [ -n "$(ls -A "$extract_to")" ]; then
            echo "Refusing to extract into a directory that is not empty: $extract_to" >&2
            exit 2
        fi
        decrypt "$config_backup" >"$work_dir/config.tar.gz"
        mkdir -p "$extract_to"
        chmod 700 "$extract_to"
        tar -xzf "$work_dir/config.tar.gz" -C "$extract_to"
        echo "Extracted the configuration archive into $extract_to"
        ;;
    verify)
        decrypt "$db_backup" >"$work_dir/db.dump"
        name="memento_restore_check_$(date -u +%Y%m%d%H%M%S)_$$"
        db psql -U "$db_user" -d postgres -v ON_ERROR_STOP=1 -q -c "CREATE DATABASE $name"
        scratch=$name
        echo "Restoring into the temporary database $name"
        db pg_restore -U "$db_user" -d "$name" --no-owner --no-privileges --exit-on-error <"$work_dir/db.dump"
        counts=$(db psql -U "$db_user" -d "$name" -v ON_ERROR_STOP=1 -At -F ' ' -c \
            "SELECT 'schema_migrations', count(*) FROM schema_migrations
             UNION ALL SELECT 'students', count(*) FROM students
             UNION ALL SELECT 'submissions', count(*) FROM submissions
             UNION ALL SELECT 'vm_activations', count(*) FROM vm_activations")
        printf '%s\n' "$counts"
        migrations=$(printf '%s\n' "$counts" | awk '$1 == "schema_migrations" { print $2 }')
        [ "${migrations:-0}" -ge 1 ] || { echo 'The restored database has no schema migrations.' >&2; exit 1; }
        echo 'Restore drill passed; the temporary database is dropped on exit.'
        ;;
    restore)
        decrypt "$db_backup" >"$work_dir/db.dump"
        echo "Restoring into $target"
        db pg_restore -U "$db_user" -d "$target" --clean --if-exists --no-owner --no-privileges --exit-on-error <"$work_dir/db.dump"
        echo "Restored $target from ${db_backup##*/}"
        ;;
esac
