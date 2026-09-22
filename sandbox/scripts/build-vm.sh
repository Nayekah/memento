#!/usr/bin/env bash
set -euo pipefail

usage() {
    cat <<'EOF'
Usage: build-vm.sh --iso PATH --checksum sha256:HEX [options]

Builds a ready-to-import VirtualBox OVA by default.

Options:
  --target virtualbox|vmware     Default: virtualbox
  --backend-url URL              Required public backend URL
  -h, --help                     Show this help
EOF
}

iso_path=""
checksum=""
target="virtualbox"
backend_url=""

while [ "$#" -gt 0 ]; do
    case "$1" in
        --iso) iso_path=${2:?missing ISO path}; shift 2 ;;
        --checksum) checksum=${2:?missing checksum}; shift 2 ;;
        --target) target=${2:?missing target}; shift 2 ;;
        --backend-url) backend_url=${2:?missing backend URL}; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Unknown argument: $1" >&2; usage >&2; exit 2 ;;
    esac
done

[ -n "$iso_path" ] || { echo '--iso is required.' >&2; exit 2; }
[ -n "$checksum" ] || { echo '--checksum is required.' >&2; exit 2; }
[ -n "$backend_url" ] || { echo '--backend-url is required.' >&2; exit 2; }
[ -f "$iso_path" ] || { echo "ISO not found: $iso_path" >&2; exit 2; }
[[ "$checksum" =~ ^sha256:[[:xdigit:]]{64}$ ]] || { echo 'Checksum must use the sha256:<64-digit-hex> format.' >&2; exit 2; }
case "$target" in virtualbox|vmware) ;; *) echo 'Target must be virtualbox or vmware.' >&2; exit 2 ;; esac
command -v packer >/dev/null || { echo 'Packer was not found in PATH.' >&2; exit 127; }

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
sandbox_root=$(cd "$script_dir/.." && pwd)
vm_directory="$sandbox_root/vm"
iso_path=$(cd "$(dirname "$iso_path")" && pwd)/$(basename "$iso_path")

arguments=(build)
if [ "$target" = "virtualbox" ]; then
    command -v VBoxManage >/dev/null || { echo 'VBoxManage was not found in PATH.' >&2; exit 127; }
    builder="virtualbox-iso.memento"
else
    builder="vmware-iso.memento"
fi

arguments+=(-only="$builder")
arguments+=(-var "iso_url=$iso_path")
arguments+=(-var "iso_checksum=$checksum")
arguments+=(-var "backend_url=$backend_url")
arguments+=("$vm_directory")

echo "Building $target image..."
packer init "$vm_directory"
packer "${arguments[@]}"

if [ "$target" = "virtualbox" ]; then output_directory="$sandbox_root/output-virtualbox"; else output_directory="$sandbox_root/output-vmware"; fi
echo "Complete. Artifact available at $output_directory"
