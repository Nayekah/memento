#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=backup-common.sh
. "$script_dir/backup-common.sh"

usage() {
    cat >&2 <<'USAGE'
Usage: backup.sh --passphrase-file FILE --output-dir DIR [options]

Writes an encrypted PostgreSQL backup and, with --config, an encrypted archive
of configuration files. Both are encrypted with GnuPG (AES-256, symmetric) and
come with a .sha256 file.

Options:
  --passphrase-file FILE  File holding the passphrase, mode 0600 or stricter (required)
  --output-dir DIR        Directory for the backups, created with mode 0700 (required)
  --compose FILE          Dump inside the postgres service of this Compose file
                          (default: backend/compose.yaml next to this script)
  --direct                Run pg_dump from PATH instead; connection settings come
                          from the PG* variables
  --database NAME         Database to dump (default: memento)
  --user NAME             Database user (default: memento)
  --config PATH           File or directory to include in the configuration
                          archive; repeat for several paths
  --keep N                Keep the newest N backups of each kind and delete older ones
USAGE
    exit 2
}

passphrase_file=""
output_dir=""
mode=compose
compose_file="$script_dir/../compose.yaml"
database=memento
db_user=memento
keep=0
config_paths=()

while [ "$#" -gt 0 ]; do
    case "$1" in
        --passphrase-file) passphrase_file=${2:?missing passphrase file}; shift 2 ;;
        --output-dir) output_dir=${2:?missing output directory}; shift 2 ;;
        --compose) mode=compose; compose_file=${2:?missing Compose file}; shift 2 ;;
        --direct) mode=direct; shift ;;
        --database) database=${2:?missing database name}; shift 2 ;;
        --user) db_user=${2:?missing user name}; shift 2 ;;
        --config) config_paths+=("${2:?missing config path}"); shift 2 ;;
        --keep) keep=${2:?missing count}; shift 2 ;;
        -h|--help) usage ;;
        *) echo "Unknown argument: $1" >&2; usage ;;
    esac
done

[ -n "$passphrase_file" ] && [ -n "$output_dir" ] || usage
check_identifier 'Database name' "$database"
check_identifier 'User name' "$db_user"
case "$keep" in
    ''|*[!0-9]*) echo '--keep must be a non-negative integer.' >&2; exit 2 ;;
esac
check_passphrase_file "$passphrase_file"
require_tool gpg gpgconf tar sha256sum
if [ "$mode" = compose ]; then
    require_tool docker
    setup_compose
else
    require_tool pg_dump
fi
for path in ${config_paths[@]+"${config_paths[@]}"}; do
    [ -e "$path" ] || { echo "Config path not found: $path" >&2; exit 2; }
done

umask 077
mkdir -p "$output_dir"
chmod 700 "$output_dir"
partials=()
cleanup() {
    rm -f ${partials[@]+"${partials[@]}"}
    stop_work
}
trap cleanup EXIT
start_work

stamp=$(date -u +%Y%m%dT%H%M%SZ)

# finish PARTIAL FINAL MAGIC_BYTES_AS_HEX: confirm the new file decrypts to the
# expected format, then publish it with a checksum.
finish() {
    local partial=$1 final=$2 expected=$3 magic
    magic=$({ decrypt "$partial" 2>/dev/null | head -c "$((${#expected} / 2))" | od -An -tx1 | tr -d ' \n'; } || true)
    [ "$magic" = "$expected" ] || { echo "The new backup does not decrypt to the expected format: ${final##*/}" >&2; exit 1; }
    mv "$partial" "$final"
    (cd "$output_dir" && sha256sum "${final##*/}" >"${final##*/}.sha256")
    echo "Wrote ${final##*/} ($(wc -c <"$final" | tr -d ' ') bytes)"
}

db_backup="$output_dir/memento-db-$stamp.dump.gpg"
[ ! -e "$db_backup" ] || { echo "Backup already exists: $db_backup (wait a second and retry)." >&2; exit 1; }
partials+=("$db_backup.partial")
db pg_dump --format=custom --no-owner -U "$db_user" -d "$database" | encrypt --output "$db_backup.partial"
finish "$db_backup.partial" "$db_backup" 5047444d50   # "PGDMP"

if [ "${#config_paths[@]}" -gt 0 ]; then
    config_backup="$output_dir/memento-config-$stamp.tar.gz.gpg"
    [ ! -e "$config_backup" ] || { echo "Backup already exists: $config_backup (wait a second and retry)." >&2; exit 1; }
    partials+=("$config_backup.partial")
    tar_args=()
    for path in "${config_paths[@]}"; do
        path=${path%/}
        tar_args+=(-C "$(dirname "$path")" "$(basename "$path")")
    done
    tar -czf - "${tar_args[@]}" | encrypt --output "$config_backup.partial"
    finish "$config_backup.partial" "$config_backup" 1f8b   # gzip
fi

# prune PATTERN: keep the newest $keep files that match. Names carry a UTC
# timestamp, so lexical order is chronological.
prune() {
    local files file count
    [ "$keep" -gt 0 ] || return 0
    shopt -s nullglob
    # shellcheck disable=SC2206
    files=("$output_dir"/$1)
    shopt -u nullglob
    count=${#files[@]}
    [ "$count" -gt "$keep" ] || return 0
    for file in "${files[@]:0:count-keep}"; do
        rm -f -- "$file" "$file.sha256"
        echo "Removed old backup ${file##*/}"
    done
}
prune 'memento-db-*.dump.gpg'
prune 'memento-config-*.tar.gz.gpg'

echo "Keep the passphrase file apart from these backups; without it they cannot be restored."
