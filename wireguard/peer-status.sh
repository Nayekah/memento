#!/bin/sh
set -eu

usage() {
    cat >&2 <<'USAGE'
Usage: peer-status.sh [options]

Lists every student peer in the server configuration with the age of its
latest WireGuard handshake, so a missing or silent student is easy to spot
during an exam. It exits 0 when every peer has handshaken recently and 1 when
any peer is stale, has never connected, is missing from the interface, or is
unknown because wg0 is down. It also warns about peers on wg0 that are not in
the configuration. That makes it usable from cron or a monitoring check.

Options:
  --server-conf PATH   Server config (default: /etc/wireguard/wg0.conf)
  --stale-seconds N    A handshake older than N seconds is stale (default: 180)
  --only-problems      Hide peers that are fine
  --format FORMAT      table (default), or tsv with student, address, seconds, status
  --now EPOCH          Treat EPOCH as the current time (for tests)
USAGE
    exit 2
}

server_conf=/etc/wireguard/wg0.conf
stale=180
only_problems=0
format=table
now=""

while [ "$#" -gt 0 ]; do
    case "$1" in
        --server-conf) server_conf=${2:?missing server config path}; shift 2 ;;
        --stale-seconds) stale=${2:?missing seconds}; shift 2 ;;
        --only-problems) only_problems=1; shift ;;
        --format) format=${2:?missing format}; shift 2 ;;
        --now) now=${2:?missing epoch}; shift 2 ;;
        -h|--help) usage ;;
        *) echo "Unknown argument: $1" >&2; usage ;;
    esac
done

case "$stale" in
    ''|*[!0-9]*|0) echo '--stale-seconds must be a positive integer.' >&2; exit 2 ;;
esac
case "$format" in
    table|tsv) ;;
    *) echo '--format must be table or tsv.' >&2; exit 2 ;;
esac
case "$now" in
    *[!0-9]*) echo '--now must be a Unix timestamp.' >&2; exit 2 ;;
esac
[ -f "$server_conf" ] || { echo "Server config not found: $server_conf" >&2; exit 1; }
command -v wg >/dev/null 2>&1 || { echo 'wg was not found in PATH.' >&2; exit 127; }
[ -n "$now" ] || now=$(date +%s)

handshakes=$(mktemp)
trap 'rm -f "$handshakes"' EXIT
interface_up=1
wg show wg0 latest-handshakes >"$handshakes" 2>/dev/null || interface_up=0
if [ "$interface_up" = 0 ]; then
    echo 'wg0 is not up; handshake times are unknown.' >&2
fi

status=0
# The first file holds "public key<TAB>timestamp" lines from wg; the second is
# the server configuration, whose "# student: ID" blocks name each peer.
awk -v now="$now" -v stale="$stale" -v format="$format" -v only_problems="$only_problems" -v up="$interface_up" '
    function ago(seconds) {
        if (seconds < 60) return seconds "s ago"
        if (seconds < 3600) return int(seconds / 60) "m ago"
        if (seconds < 86400) return int(seconds / 3600) "h ago"
        return int(seconds / 86400) "d ago"
    }
    function flush(   state, seconds) {
        if (student == "") return
        seconds = "-"
        if (!up) state = "UNKNOWN"
        else if (!(key in on_interface)) state = "MISSING"
        else if (handshake[key] == 0) state = "NEVER"
        else {
            seconds = now - handshake[key]
            if (seconds < 0) seconds = 0
            state = (seconds <= stale) ? "OK" : "STALE"
        }
        managed[key] = 1
        total++
        count[state]++
        if (state != "OK") problems++
        if (!(only_problems && state == "OK")) {
            if (format == "tsv") printf "%s\t%s\t%s\t%s\n", student, address, seconds, state
            else printf "%-16s %-16s %-16s %s\n", student, address, (seconds == "-" ? (state == "NEVER" ? "never" : "-") : ago(seconds)), state
        }
        student = ""
        key = ""
        address = ""
    }
    BEGIN { if (format == "table") printf "%-16s %-16s %-16s %s\n", "STUDENT", "ADDRESS", "LAST HANDSHAKE", "STATUS" }
    FILENAME == ARGV[1] {
        if (split($0, field, "\t") == 2) { handshake[field[1]] = field[2] + 0; on_interface[field[1]] = 1 }
        next
    }
    /^# student: / { flush(); student = substr($0, 12); next }
    student != "" && /^[[:space:]]*$/ { flush(); next }
    student != "" && $1 == "PublicKey" { key = $0; sub(/^[^=]*=[[:space:]]*/, "", key); next }
    student != "" && $1 == "AllowedIPs" { address = $0; sub(/^[^=]*=[[:space:]]*/, "", address); sub(/\/32$/, "", address); next }
    END {
        flush()
        unmanaged = 0
        for (k in on_interface) if (!(k in managed)) unmanaged++
        if (format == "table") {
            summary = total " peers:"
            sep = " "
            n = split("OK STALE NEVER MISSING UNKNOWN", order, " ")
            for (i = 1; i <= n; i++) {
                if (count[order[i]] > 0) { summary = summary sep count[order[i]] " " tolower(order[i]); sep = ", " }
            }
            if (total == 0) summary = "0 peers"
            print summary
        }
        if (unmanaged > 0) {
            printf "Warning: %d peer(s) on wg0 are not in the server configuration.\n", unmanaged > "/dev/stderr"
        }
        exit ((problems > 0 || unmanaged > 0) ? 1 : 0)
    }
' "$handshakes" "$server_conf" || status=$?
exit "$status"
