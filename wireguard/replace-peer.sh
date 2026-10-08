#!/bin/sh
set -eu

usage() {
    cat >&2 <<'USAGE'
Usage: replace-peer.sh --student STUDENT_ID --endpoint HOST:51820 --output PATH [options]

Gives a student new WireGuard keys on the same VPN address, for example after
a lost laptop. The old peer is revoked and a new profile is written to --output;
write it to the student's existing profile path to replace that file.

Options:
  --token-file PATH   Token file for the profile comment (see provision-peer.sh)
  --server-conf PATH  Server config (default: /etc/wireguard/wg0.conf)
  --log PATH          Revocation log (default: /var/log/memento-vpn-revocations.log)
  --reason TEXT       One line recorded in the log (default: keys replaced)
USAGE
    exit 2
}

student_id=""
endpoint=""
output=""
token_file=""
server_conf=/etc/wireguard/wg0.conf
log=/var/log/memento-vpn-revocations.log
reason="keys replaced"

while [ "$#" -gt 0 ]; do
    case "$1" in
        --student) student_id=${2:?missing student ID}; shift 2 ;;
        --endpoint) endpoint=${2:?missing endpoint}; shift 2 ;;
        --output) output=${2:?missing output path}; shift 2 ;;
        --token-file) token_file=${2:?missing token file}; shift 2 ;;
        --server-conf) server_conf=${2:?missing server config path}; shift 2 ;;
        --log) log=${2:?missing log path}; shift 2 ;;
        --reason) reason=${2:?missing reason}; shift 2 ;;
        -h|--help) usage ;;
        *) echo "Unknown argument: $1" >&2; usage ;;
    esac
done

[ -n "$student_id" ] && [ -n "$endpoint" ] && [ -n "$output" ] || usage
case "$student_id" in
    *[!A-Za-z0-9._-]*) echo 'Student ID contains unsupported characters.' >&2; exit 2 ;;
esac
[ -f "$server_conf" ] || { echo "Server config not found: $server_conf" >&2; exit 1; }
script_dir=$(cd "$(dirname "$0")" && pwd)

# Check everything that could fail after the revocation first, so a bad
# argument never leaves the student without a peer.
if [ -n "$token_file" ]; then
    token=$(sed -n '1p' "$token_file" 2>/dev/null | tr -d '[:space:]')
    printf '%s\n' "$token" | grep -Eqx '[A-Z2-7]{4}-[A-Z2-7]{4}-[A-Z2-7]{4}' || {
        echo "Token file does not contain a Memento token: $token_file" >&2
        exit 2
    }
fi
output_dir=$(dirname "$output")
[ -d "$output_dir" ] && [ -w "$output_dir" ] || { echo "Cannot write to the output directory: $output_dir" >&2; exit 2; }

address=$(awk -v student="$student_id" '
    $0 == "# student: " student { in_block = 1; next }
    in_block && ($0 ~ /^[[:space:]]*$/ || $0 ~ /^# student: /) { in_block = 0 }
    in_block && $1 == "AllowedIPs" { sub(/^[^=]*=[[:space:]]*/, ""); sub(/\/32$/, ""); print; exit }
' "$server_conf")
[ -n "$address" ] || { echo "No peer for $student_id in $server_conf." >&2; exit 1; }

"$script_dir/revoke-peer.sh" --student "$student_id" --server-conf "$server_conf" --log "$log" --reason "$reason"

if [ -n "$token_file" ]; then
    set -- --token-file "$token_file"
else
    set --
fi
if ! "$script_dir/provision-peer.sh" --student "$student_id" --address "$address" --endpoint "$endpoint" \
    --output "$output" --server-conf "$server_conf" "$@"; then
    echo "The peer for $student_id was revoked but a new one could not be created." >&2
    echo "Run provision-peer.sh with --student $student_id --address $address to finish." >&2
    exit 1
fi
