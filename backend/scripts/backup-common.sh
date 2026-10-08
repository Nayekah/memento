# shellcheck shell=bash
# shellcheck disable=SC2154
# Helpers shared by backup.sh and restore.sh. Source this file; do not run it.
# The caller defines mode (compose or direct), compose_file, and passphrase_file.

require_tool() {
    local tool
    for tool in "$@"; do
        command -v "$tool" >/dev/null 2>&1 || { echo "$tool was not found in PATH." >&2; exit 127; }
    done
}

# check_identifier LABEL VALUE: names that end up in SQL or file names stay simple.
check_identifier() {
    case "$2" in
        ''|*[!A-Za-z0-9_]*) echo "$1 may only contain letters, digits, and underscores." >&2; exit 2 ;;
    esac
}

check_passphrase_file() {
    local file=$1 file_mode
    [ -f "$file" ] || { echo "Passphrase file not found: $file" >&2; exit 2; }
    [ -s "$file" ] || { echo "Passphrase file is empty: $file" >&2; exit 2; }
    file_mode=$(stat -c %a "$file")
    if [ $((8#$file_mode & 8#077)) -ne 0 ]; then
        echo "Passphrase file must not be accessible by group or others (mode $file_mode): $file" >&2
        exit 2
    fi
}

setup_compose() {
    local compose_dir
    [ -f "$compose_file" ] || { echo "Compose file not found: $compose_file" >&2; exit 2; }
    compose_args=(-f "$compose_file")
    compose_dir=$(cd "$(dirname "$compose_file")" && pwd)
    if [ -f "$compose_dir/.env" ]; then
        compose_args+=(--env-file "$compose_dir/.env")
    fi
}

# start_work creates a private scratch directory that also serves as a throwaway
# GnuPG home, so the caller's keyring and agent are never touched.
start_work() {
    work_dir=$(mktemp -d)
    chmod 700 "$work_dir"
    mkdir -m 700 "$work_dir/gnupg"
    export GNUPGHOME="$work_dir/gnupg"
}

stop_work() {
    [ -n "${work_dir:-}" ] || return 0
    gpgconf --kill gpg-agent >/dev/null 2>&1 || true
    rm -rf "$work_dir"
}

encrypt() {
    gpg --batch --yes --quiet --pinentry-mode loopback --passphrase-file "$passphrase_file" \
        --symmetric --cipher-algo AES256 --compress-algo none "$@"
}

decrypt() {
    gpg --batch --quiet --pinentry-mode loopback --passphrase-file "$passphrase_file" --decrypt "$@"
}

# db COMMAND...: run a PostgreSQL client command where the database is reachable.
db() {
    if [ "$mode" = compose ]; then
        docker compose "${compose_args[@]}" exec -T postgres "$@"
    else
        "$@"
    fi
}
