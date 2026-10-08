#!/bin/sh
set -eu

usage() {
    echo "Usage: $0 --student STUDENT_ID --address 10.66.0.N --endpoint HOST:51820 --output PATH [--server-conf PATH]" >&2
    exit 2
}

student_id=""
peer_address=""
endpoint=""
output=""
server_conf=/etc/wireguard/wg0.conf

while [ "$#" -gt 0 ]; do
    case "$1" in
        --student) student_id=${2:?missing student ID}; shift 2 ;;
        --address) peer_address=${2:?missing peer address}; shift 2 ;;
        --endpoint) endpoint=${2:?missing endpoint}; shift 2 ;;
        --output) output=${2:?missing output path}; shift 2 ;;
        --server-conf) server_conf=${2:?missing server config path}; shift 2 ;;
        -h|--help) usage ;;
        *) echo "Unknown argument: $1" >&2; usage ;;
    esac
done

[ -n "$student_id" ] && [ -n "$peer_address" ] && [ -n "$endpoint" ] && [ -n "$output" ] || usage
[ -f "$server_conf" ] || { echo "Server config not found: $server_conf" >&2; exit 1; }
command -v wg >/dev/null 2>&1 || { echo 'wg was not found in PATH.' >&2; exit 127; }

case "$student_id" in
    *[!A-Za-z0-9._-]*) echo 'Student ID contains unsupported characters.' >&2; exit 2 ;;
esac
case "$peer_address" in
    10.66.0.*) ;;
    *) echo 'Peer address must be inside 10.66.0.0/24.' >&2; exit 2 ;;
esac

umask 077
tmp_dir=$(mktemp -d)
trap 'rm -rf "$tmp_dir"' EXIT
client_private=$(wg genkey)
client_public=$(printf '%s\n' "$client_private" | wg pubkey)
preshared_key=$(wg genpsk)
server_public=$(wg show wg0 public-key 2>/dev/null || wg pubkey </etc/wireguard/server-private.key)

if grep -q "# student: $student_id$" "$server_conf"; then
    echo "A peer for $student_id already exists in $server_conf." >&2
    exit 1
fi
if grep -Eq "^[[:space:]]*AllowedIPs[[:space:]]*=[[:space:]]*$peer_address/32[[:space:]]*$" "$server_conf"; then
    echo "The peer address $peer_address is already allocated." >&2
    exit 1
fi

peer_key_file="$tmp_dir/peer.key"
printf '%s\n' "$preshared_key" >"$peer_key_file"
wg set wg0 peer "$client_public" preshared-key "$peer_key_file" allowed-ips "$peer_address/32"

cat >>"$server_conf" <<EOF

# student: $student_id
[Peer]
PublicKey = $client_public
PresharedKey = $preshared_key
AllowedIPs = $peer_address/32
EOF

cat >"$output" <<EOF
[Interface]
PrivateKey = $client_private
Address = $peer_address/32
DNS = 10.66.0.1

[Peer]
PublicKey = $server_public
PresharedKey = $preshared_key
Endpoint = $endpoint
# Full tunnel: webchat, LLM APIs, package mirrors, and arbitrary Internet
# destinations are sent to the server, where the default-drop policy rejects
# them. Only the grading HTTPS flow is permitted there.
AllowedIPs = 0.0.0.0/0, ::/0
PersistentKeepalive = 25
EOF
chmod 0600 "$output"
echo "Created WireGuard client config: $output"
echo "Import it on the student's managed laptop; do not commit or email it."
