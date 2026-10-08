#!/bin/sh
set -eu
LC_ALL=C
export LC_ALL

usage() {
    cat >&2 <<'USAGE'
Usage: peer-log.sh [options]

Appends WireGuard peer events to a log so an incident can be reconstructed
afterwards: when each student first connected, how long a gap lasted, which
public address a profile was used from, and when a peer was added or removed.
It only records. It never changes a peer or the firewall.

Every --interval seconds it reads `wg show INTERFACE latest-handshakes`,
`endpoints`, and `transfer`, compares them with the previous sample, and writes
one line per change. A peer is silent when it has sent no handshake and no
traffic for --silent-seconds. A summary line follows every --summary-seconds, so
a gap in the log shows that the logger itself was not running.

Each line is a timestamp and key=value pairs:

  event=start        the logger started
  event=connected    a peer completed its first handshake (baseline=1: it was
                     already connected when the logger first looked)
  event=silent       a connected peer went quiet (idle_seconds)
  event=recovered    a silent peer is back (gap_seconds)
  event=endpoint_changed  the peer's public address changed (from, to)
  event=peer_added / peer_removed / peer_missing  the interface and the server
                     configuration disagree, or a peer was provisioned or revoked
  event=unknown_peer a peer on the interface that is not in the configuration
  event=interface_down / interface_up  wg could not be read, or can be again
  event=summary      peers, up, silent, never, missing, unknown
  event=stop         the logger was stopped cleanly

Options:
  --server-conf PATH     Server config naming each peer's student (default: /etc/wireguard/wg0.conf)
  --interface NAME       WireGuard interface (default: wg0)
  --log-file PATH        Event log (default: /var/log/memento-vpn-events.log)
  --state-dir DIR        Where the previous sample is kept (default: /run/memento-vpn)
  --interval SECONDS     Seconds between samples (default: 10)
  --silent-seconds N     Quiet for N seconds counts as silent (default: 60)
  --summary-seconds N    Write a summary line every N seconds (default: 60)
  --once                 Take one sample, write its events, and exit
  --now EPOCH            Treat EPOCH as the current time (with --once, for tests)
USAGE
    exit 2
}

server_conf=/etc/wireguard/wg0.conf
interface=wg0
log_file=/var/log/memento-vpn-events.log
state_dir=/run/memento-vpn
interval=10
silent=60
summary_every=60
once=0
fixed_now=""

while [ "$#" -gt 0 ]; do
    case "$1" in
        --server-conf) server_conf=${2:?missing server config path}; shift 2 ;;
        --interface) interface=${2:?missing interface name}; shift 2 ;;
        --log-file) log_file=${2:?missing log file path}; shift 2 ;;
        --state-dir) state_dir=${2:?missing state directory}; shift 2 ;;
        --interval) interval=${2:?missing seconds}; shift 2 ;;
        --silent-seconds) silent=${2:?missing seconds}; shift 2 ;;
        --summary-seconds) summary_every=${2:?missing seconds}; shift 2 ;;
        --once) once=1; shift ;;
        --now) fixed_now=${2:?missing epoch}; shift 2 ;;
        -h|--help) usage ;;
        *) echo "Unknown argument: $1" >&2; usage ;;
    esac
done

for number in "$interval" "$silent" "$summary_every"; do
    case "$number" in
        ''|*[!0-9]*|0) echo 'Intervals and thresholds must be positive integers.' >&2; exit 2 ;;
    esac
done
case "$interface" in
    ''|*[!A-Za-z0-9._-]*) echo '--interface contains unsupported characters.' >&2; exit 2 ;;
esac
case "$fixed_now" in
    *[!0-9]*) echo '--now must be a Unix timestamp.' >&2; exit 2 ;;
esac
if [ -n "$fixed_now" ] && [ "$once" -ne 1 ]; then
    echo '--now only makes sense with --once.' >&2
    exit 2
fi
[ -f "$server_conf" ] || { echo "Server config not found: $server_conf" >&2; exit 1; }
command -v wg >/dev/null 2>&1 || { echo 'wg was not found in PATH.' >&2; exit 127; }

umask 077
mkdir -p "$state_dir"
chmod 0700 "$state_dir"
state_file=$state_dir/peers.state
meta_file=$state_dir/meta
touch "$log_file"

iso_time() {
    date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -r "$1" +%Y-%m-%dT%H:%M:%SZ
}

current_time() {
    if [ -n "$fixed_now" ]; then printf '%s\n' "$fixed_now"; else date +%s; fi
}

# note writes one event line that is not tied to a sample.
note() {
    printf '%s event=%s%s\n' "$(iso_time "$(current_time)")" "$1" "${2:+ $2}" >>"$log_file"
}

sample() {
    now=$(current_time)
    work=$(mktemp -d "$state_dir/sample.XXXXXX")
    up=1
    # Only the per-peer subcommands are used: `wg show IFACE dump` would
    # print the interface's private key.
    for field in latest-handshakes endpoints transfer; do
        wg show "$interface" "$field" >"$work/$field" 2>/dev/null || up=0
    done
    awk -v now="$now" -v ts="$(iso_time "$now")" -v silent="$silent" -v summary_every="$summary_every" \
        -v up="$up" -v interface="$interface" -v conf="$server_conf" \
        -v state_in="$state_file" -v state_out="$work/state" -v meta_in="$meta_file" -v meta_out="$work/meta" \
        -v hs_file="$work/latest-handshakes" -v ep_file="$work/endpoints" -v tx_file="$work/transfer" '
        function clean(name) { gsub(/[^A-Za-z0-9._-]/, "_", name); return name }
        function ip_of(endpoint,    ip) {
            if (endpoint == "" || endpoint == "-" || endpoint == "(none)") return ""
            ip = endpoint
            sub(/:[0-9]+$/, "", ip)
            gsub(/^\[|\]$/, "", ip)
            return ip
        }
        function dash(value) { return value == "" ? "-" : value }
        function emit(event, who, where, extra,    line) {
            line = ts " event=" event
            if (who != "") line = line " student=" who " address=" where
            if (extra != "") line = line " " extra
            print line
        }
        function flush_conf() {
            if (c_student != "" && c_key != "") {
                n++
                order[n] = c_key
                student[c_key] = c_student
                address[c_key] = c_addr
                managed[c_key] = 1
            }
            c_student = ""; c_key = ""; c_addr = ""
        }
        function save(k, who, where, s, alive, rx, hs, ep) {
            printf "%s\t%s\t%s\t%s\t%.0f\t%.0f\t%.0f\t%s\n", k, who, where, s, alive, rx, hs, dash(ep) > state_out
        }
        BEGIN {
            # The server configuration names each student; only the public key and the address are read.
            while ((getline line < conf) > 0) {
                if (line ~ /^# student: /) { flush_conf(); c_student = clean(substr(line, 12)) }
                else if (c_student != "" && line ~ /^[[:space:]]*$/) flush_conf()
                else if (c_student != "" && line ~ /^[[:space:]]*PublicKey[[:space:]]*=/) { c_key = line; sub(/^[^=]*=[[:space:]]*/, "", c_key) }
                else if (c_student != "" && line ~ /^[[:space:]]*AllowedIPs[[:space:]]*=/) { c_addr = line; sub(/^[^=]*=[[:space:]]*/, "", c_addr); sub(/\/32[[:space:]]*$/, "", c_addr) }
            }
            flush_conf()
            close(conf)

            while ((getline line < state_in) > 0) {
                if (split(line, f, "\t") == 8) {
                    k = f[1]
                    pn++; p_order[pn] = k
                    p_student[k] = f[2]; p_address[k] = f[3]; p_state[k] = f[4]
                    p_alive[k] = f[5] + 0; p_rx[k] = f[6] + 0; p_hs[k] = f[7] + 0
                    p_ep[k] = (f[8] == "-" ? "" : f[8])
                }
            }
            close(state_in)
            while ((getline line < meta_in) > 0) {
                if (split(line, f, "=") == 2) meta[f[1]] = f[2]
            }
            close(meta_in)
            baseline = !("tracked" in meta)

            while ((getline line < hs_file) > 0) {
                if (split(line, f, "\t") == 2) { hn++; h_order[hn] = f[1]; present[f[1]] = 1; hs[f[1]] = f[2] + 0 }
            }
            close(hs_file)
            while ((getline line < ep_file) > 0) {
                if (split(line, f, "\t") == 2) ep[f[1]] = f[2]
            }
            close(ep_file)
            while ((getline line < tx_file) > 0) {
                if (split(line, f, "\t") >= 3) rx[f[1]] = f[2] + 0
            }
            close(tx_file)

            iface_was = ("iface" in meta) ? meta["iface"] : "up"
            if (!up) {
                # Keep the previous records and report the interface once.
                if (iface_was != "down") emit("interface_down", "", "", "interface=" interface)
                for (j = 1; j <= pn; j++) {
                    k = p_order[j]
                    save(k, p_student[k], p_address[k], p_state[k], p_alive[k], p_rx[k], p_hs[k], p_ep[k])
                }
                meta_iface = "down"
            } else {
                if (iface_was == "down") emit("interface_up", "", "", "interface=" interface)
                meta_iface = "up"
                for (i = 1; i <= n; i++) {
                    k = order[i]; who = student[k]; where = address[k]
                    had = (k in p_state) && (p_state[k] != "unknown")
                    old = had ? p_state[k] : ""
                    h = (k in hs) ? hs[k] : 0
                    r = (k in rx) ? rx[k] : 0
                    e = (k in ep) ? ep[k] : ""
                    if (e == "(none)") e = ""
                    if (!(k in present)) {
                        s = "missing"
                        alive = had ? p_alive[k] : 0
                        keep_rx = had ? p_rx[k] : 0; keep_hs = had ? p_hs[k] : 0; keep_ep = had ? p_ep[k] : ""
                    } else {
                        if (!had) alive = (h > 0) ? h : 0
                        else {
                            alive = p_alive[k]
                            if (h > p_hs[k] || r > p_rx[k]) alive = now
                        }
                        if (alive == 0) s = "never"
                        else s = ((now - alive) <= silent) ? "up" : "silent"
                        keep_rx = r; keep_hs = h
                        keep_ep = (e != "") ? e : (had ? p_ep[k] : "")
                    }
                    shown = dash(keep_ep)
                    flag = baseline ? " baseline=1" : ""
                    if (old == "") {
                        if (!baseline) emit("peer_added", who, where, "")
                        if (s == "up") emit("connected", who, where, "endpoint=" shown flag)
                        else if (s == "silent") emit("silent", who, where, "idle_seconds=" (now - alive) " endpoint=" shown flag)
                        else if (s == "missing") emit("peer_missing", who, where, "")
                    } else if (old != s) {
                        if (s == "missing") emit("peer_removed", who, where, "reason=not_on_interface")
                        else if (old == "missing") {
                            emit("peer_added", who, where, "")
                            if (s == "up") emit("connected", who, where, "endpoint=" shown)
                        }
                        else if (old == "never" && s == "up") emit("connected", who, where, "endpoint=" shown)
                        else if (old == "up" && s == "silent") emit("silent", who, where, "idle_seconds=" (now - alive) " endpoint=" shown)
                        else if (old == "silent" && s == "up") emit("recovered", who, where, "gap_seconds=" (now - p_alive[k]) " endpoint=" shown)
                    }
                    if (s != "missing" && e != "" && had && p_ep[k] != "" && ip_of(e) != ip_of(p_ep[k]))
                        emit("endpoint_changed", who, where, "from=" p_ep[k] " to=" e)
                    save(k, who, where, s, alive, keep_rx, keep_hs, keep_ep)
                    count[s]++
                }
                # Peers that were tracked and are no longer in the configuration.
                for (j = 1; j <= pn; j++) {
                    k = p_order[j]
                    if (!(k in managed) && p_state[k] != "unknown") emit("peer_removed", p_student[k], p_address[k], "reason=not_in_config")
                }
                # Peers on the interface that the configuration does not name.
                for (j = 1; j <= hn; j++) {
                    k = h_order[j]
                    if (k in managed) continue
                    e = (k in ep) ? ep[k] : ""
                    if (e == "(none)") e = ""
                    if (!(k in p_state) || p_state[k] != "unknown") emit("unknown_peer", "", "", "key=" k " endpoint=" dash(e))
                    save(k, "-", "-", "unknown", 0, 0, 0, e)
                    count["unknown"]++
                }
                meta_tracked = 1
            }

            last = ("last_summary" in meta) ? meta["last_summary"] + 0 : -1
            if (last < 0 || now - last >= summary_every) {
                if (up) emit("summary", "", "", "peers=" (n + 0) " up=" count["up"] + 0 " silent=" count["silent"] + 0 " never=" count["never"] + 0 " missing=" count["missing"] + 0 " unknown=" count["unknown"] + 0)
                else emit("summary", "", "", "peers=" (n + 0) " interface=down")
                last = now
            }
            printf "iface=%s\n", meta_iface > meta_out
            printf "last_summary=%.0f\n", last > meta_out
            printf "last_sample=%.0f\n", now > meta_out
            if (meta_tracked || ("tracked" in meta)) printf "tracked=1\n" > meta_out
            close(state_out); close(meta_out)
        }' >>"$log_file"
    : >>"$work/state"
    mv "$work/state" "$state_file"
    mv "$work/meta" "$meta_file"
    rm -rf "$work"
}

if [ "$once" -eq 1 ]; then
    sample
    exit 0
fi

previous=""
if [ -f "$meta_file" ]; then
    previous=$(sed -n 's/^last_sample=//p' "$meta_file")
fi
case "$previous" in
    ''|*[!0-9]*) previous="" ;;
esac
note start "interface=$interface interval=$interval silent_after=$silent summary_every=$summary_every${previous:+ previous_sample_age=$(($(date +%s) - previous))}"

sleeper=""
stop() {
    [ -z "$sleeper" ] || kill "$sleeper" 2>/dev/null || true
    note stop
    exit 0
}
trap stop INT TERM

while :; do
    sample
    sleep "$interval" &
    sleeper=$!
    wait "$sleeper" || true
    sleeper=""
done
