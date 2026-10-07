#!/usr/bin/env bash
set -euo pipefail

usage() {
    cat >&2 <<'USAGE'
Usage: provision-cohort.sh --endpoint HOST:51820 [options]

Options:
  --start-nim NIM       First NIM (default: 18225001)
  --count NUMBER        Number of consecutive students (default: 120)
  --first-ip NUMBER     Last octet of first VPN IP (default: 10)
  --output-dir PATH     Secure output directory (default: ./cohort-output)
  --server-conf PATH    Server WireGuard config (default: /etc/wireguard/wg0.conf)
  --compose-file PATH   Backend Compose file (default: ./backend/compose.yaml)
USAGE
    exit 2
}

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd "$script_dir/.." && pwd)
start_nim=18225001
count=120
first_ip=10
endpoint=""
output_dir="$repo_root/cohort-output"
server_conf=/etc/wireguard/wg0.conf
compose_file="$repo_root/backend/compose.yaml"

while [ "$#" -gt 0 ]; do
    case "$1" in
        --start-nim) start_nim=${2:?missing starting NIM}; shift 2 ;;
        --count) count=${2:?missing student count}; shift 2 ;;
        --first-ip) first_ip=${2:?missing first VPN IP octet}; shift 2 ;;
        --endpoint) endpoint=${2:?missing WireGuard endpoint}; shift 2 ;;
        --output-dir) output_dir=${2:?missing output directory}; shift 2 ;;
        --server-conf) server_conf=${2:?missing server config path}; shift 2 ;;
        --compose-file) compose_file=${2:?missing Compose file path}; shift 2 ;;
        -h|--help) usage ;;
        *) echo "Unknown argument: $1" >&2; usage ;;
    esac
done

[ -n "$endpoint" ] || { echo '--endpoint is required.' >&2; usage; }
[ -f "$server_conf" ] || { echo "Server config not found: $server_conf" >&2; exit 1; }
[ -f "$compose_file" ] || { echo "Compose file not found: $compose_file" >&2; exit 1; }
command -v docker >/dev/null 2>&1 || { echo 'docker was not found in PATH.' >&2; exit 127; }

is_positive_integer() {
    [[ "$1" =~ ^[0-9]+$ ]] && [ "$1" -gt 0 ]
}

is_positive_integer "$start_nim" || { echo '--start-nim must be a positive integer.' >&2; exit 2; }
is_positive_integer "$count" || { echo '--count must be a positive integer.' >&2; exit 2; }
[[ "$first_ip" =~ ^[0-9]+$ ]] || { echo '--first-ip must be an integer.' >&2; exit 2; }
[ "$first_ip" -ge 2 ] && [ "$first_ip" -le 254 ] || { echo '--first-ip must be between 2 and 254.' >&2; exit 2; }
[ $((first_ip + count - 1)) -le 254 ] || { echo 'The cohort does not fit in the 10.66.0.0/24 VPN subnet.' >&2; exit 2; }

mkdir -p "$output_dir"
chmod 0700 "$output_dir"
manifest="$output_dir/students.tsv"
if [ -e "$manifest" ]; then
    head -n 1 "$manifest" | grep -qx $'nim\tvpn_ip\tconfig_file\ttoken_file' || {
        echo "Unexpected manifest format: $manifest" >&2
        exit 1
    }
else
    printf 'nim\tvpn_ip\tconfig_file\ttoken_file\n' >"$manifest"
    chmod 0600 "$manifest"
fi

compose_args=(-f "$compose_file")
compose_dir=$(cd "$(dirname "$compose_file")" && pwd)
if [ -f "$compose_dir/.env" ]; then
    compose_args+=(--env-file "$compose_dir/.env")
fi

for ((index = 0; index < count; index++)); do
    nim=$((start_nim + index))
    vpn_ip="10.66.0.$((first_ip + index))"
    config_file="$output_dir/$nim.conf"
    token_file="$output_dir/$nim.token"

    echo "Provisioning NIM $nim ($vpn_ip)"
    docker compose "${compose_args[@]}" run --rm -T api student "$nim" "$nim" >/dev/null

    if [ -e "$token_file" ]; then
        echo "  token already exists: $token_file"
    else
        docker compose "${compose_args[@]}" run --rm -T api token "$nim" >"$token_file"
        chmod 0600 "$token_file"
    fi

    if grep -q "# student: $nim$" "$server_conf"; then
        [ -f "$config_file" ] || {
            echo "Peer exists for $nim but its client config is missing: $config_file" >&2
            exit 1
        }
        echo "  peer already exists; kept existing config"
    else
        "$script_dir/provision-peer.sh" \
            --student "$nim" \
            --address "$vpn_ip" \
            --endpoint "$endpoint" \
            --output "$config_file" \
            --server-conf "$server_conf"
    fi

    if ! grep -q "^${nim}[[:space:]]" "$manifest"; then
        printf '%s\t%s\t%s\t%s\n' "$nim" "$vpn_ip" "$config_file" "$token_file" >>"$manifest"
    fi
done

echo "Created $count student records starting at NIM $start_nim."
echo "Last NIM: $((start_nim + count - 1))"
echo "Secure output: $output_dir"
