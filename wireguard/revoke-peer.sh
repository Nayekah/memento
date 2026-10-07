#!/bin/sh
set -eu

usage() {
    cat >&2 <<'USAGE'
Usage: revoke-peer.sh --student STUDENT_ID [options]

Cuts a student's WireGuard access: removes the peer from the running wg0
interface, deletes its block from the server configuration, and records the
revocation in a log. Use replace-peer.sh to give the student a new profile.

Options:
  --server-conf PATH  Server config (default: /etc/wireguard/wg0.conf)
  --log PATH          Revocation log (default: /var/log/memento-vpn-revocations.log)
  --reason TEXT       One line of free text recorded in the log
  --dry-run           Show what would change and change nothing
USAGE
    exit 2
}

student_id=""
server_conf=/etc/wireguard/wg0.conf
log=/var/log/memento-vpn-revocations.log
reason=""
dry_run=0

while [ "$#" -gt 0 ]; do
    case "$1" in
        --student) student_id=${2:?missing student ID}; shift 2 ;;
        --server-conf) server_conf=${2:?missing server config path}; shift 2 ;;
        --log) log=${2:?missing log path}; shift 2 ;;
        --reason) reason=${2:?missing reason}; shift 2 ;;
        --dry-run) dry_run=1; shift ;;
        -h|--help) usage ;;
        *) echo "Unknown argument: $1" >&2; usage ;;
    esac
done

[ -n "$student_id" ] || usage
case "$student_id" in
    *[!A-Za-z0-9._-]*) echo 'Student ID contains unsupported characters.' >&2; exit 2 ;;
esac
case "$reason" in
    *'
'*) echo 'The reason must be a single line.' >&2; exit 2 ;;
esac
[ -f "$server_conf" ] || { echo "Server config not found: $server_conf" >&2; exit 1; }
command -v wg >/dev/null 2>&1 || { echo 'wg was not found in PATH.' >&2; exit 127; }

# peer_field NAME: the value of NAME inside the student's block, which starts
# at the "# student: ID" marker that provision-peer.sh writes and ends at the
# next blank line or marker.
peer_field() {
    awk -v student="$student_id" -v field="$1" '
        $0 == "# student: " student { in_block = 1; next }
        in_block && ($0 ~ /^[[:space:]]*$/ || $0 ~ /^# student: /) { in_block = 0 }
        in_block && $1 == field { sub(/^[^=]*=[[:space:]]*/, ""); print; exit }
    ' "$server_conf"
}

public_key=$(peer_field PublicKey)
address=$(peer_field AllowedIPs)
if [ -z "$public_key" ] || [ -z "$address" ]; then
    echo "No peer for $student_id in $server_conf." >&2
    exit 1
fi

interface_up=1
wg show wg0 >/dev/null 2>&1 || interface_up=0

if [ "$dry_run" = 1 ]; then
    echo "Would remove the peer for $student_id ($address) from $server_conf."
    if [ "$interface_up" = 1 ]; then
        echo 'Would remove it from the running wg0 interface.'
    else
        echo 'wg0 is not up, so only the configuration file would change.'
    fi
    exit 0
fi

# Cut access first; the configuration edit only matters for the next restart.
if [ "$interface_up" = 1 ]; then
    wg set wg0 peer "$public_key" remove
else
    echo "wg0 is not up; only $server_conf is updated." >&2
fi

tmp=$(mktemp "$server_conf.XXXXXX")
trap 'rm -f "$tmp"' EXIT
awk -v student="$student_id" '
    { lines[NR] = $0 }
    END {
        skip = 0
        for (i = 1; i <= NR; i++) {
            if (lines[i] == "# student: " student) {
                skip = 1
                if (kept > 0 && out[kept] ~ /^[[:space:]]*$/) kept--
                continue
            }
            if (skip && (lines[i] ~ /^[[:space:]]*$/ || lines[i] ~ /^# student: /)) skip = 0
            if (!skip) out[++kept] = lines[i]
        }
        for (i = 1; i <= kept; i++) print out[i]
    }' "$server_conf" >"$tmp"
chmod "$(stat -c %a "$server_conf")" "$tmp"
mv "$tmp" "$server_conf"

timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)
operator=${SUDO_USER:-${USER:-unknown}}
reason=$(printf '%s' "$reason" | tr '"' "'")
fingerprint=$(printf '%s' "$public_key" | cut -c1-8)
if ! (umask 077; printf '%s revoked student=%s address=%s key=%s operator=%s reason="%s"\n' \
    "$timestamp" "$student_id" "$address" "$fingerprint" "$operator" "$reason" >>"$log") 2>/dev/null; then
    echo "Warning: could not write the revocation log: $log" >&2
fi

echo "Revoked the WireGuard peer for $student_id ($address)."
echo "Delete that student's profile from the cohort output directory; its key no longer works."
