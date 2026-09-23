#!/usr/bin/env bash
set -euo pipefail

usage() {
    echo 'Usage: build-iso.sh --source-iso PATH --backend-url URL [--output PATH]'
}

source_iso=""
backend_url=""
output=""

while [ "$#" -gt 0 ]; do
    case "$1" in
        --source-iso) source_iso=${2:?missing ISO path}; shift 2 ;;
        --backend-url) backend_url=${2:?missing backend URL}; shift 2 ;;
        --output) output=${2:?missing output path}; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Unknown argument: $1" >&2; usage >&2; exit 2 ;;
    esac
done

[ -n "$source_iso" ] || { echo '--source-iso is required.' >&2; exit 2; }
[ -f "$source_iso" ] || { echo "ISO not found: $source_iso" >&2; exit 2; }
[ -n "$backend_url" ] || { echo '--backend-url is required.' >&2; exit 2; }

for command in 7z cpio gzip mkisofs; do
    command -v "$command" >/dev/null || { echo "$command was not found in PATH." >&2; exit 127; }
done

ca_bundle=${SSL_CERT_FILE:-}
if [ -z "$ca_bundle" ]; then
    for candidate in /etc/ssl/certs/ca-certificates.crt /etc/pki/tls/certs/ca-bundle.crt; do
        if [ -f "$candidate" ]; then
            ca_bundle=$candidate
            break
        fi
    done
fi
[ -f "$ca_bundle" ] || { echo 'A CA certificate bundle was not found. Set SSL_CERT_FILE to its path.' >&2; exit 1; }

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
sandbox_root=$(cd "$script_dir/.." && pwd)
output=${output:-"$sandbox_root/output/memento-lab.iso"}
output=$(mkdir -p "$(dirname "$output")" && cd "$(dirname "$output")" && pwd)/$(basename "$output")
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

mkdir -p "$work/iso" "$work/overlay"
7z x -y "-o$work/iso" "$source_iso" >/dev/null
cp -a "$sandbox_root/vm/overlay/." "$work/overlay/"
install -d "$work/overlay/usr/local/share/memento" "$work/overlay/usr/local/share/fonts" "$work/overlay/usr/local/etc/ssl/certs"
install -m 0644 "$sandbox_root/src/bits.c" "$work/overlay/usr/local/share/memento/bits.c.template"
install -m 0644 "$sandbox_root/vm/bg/wallpaper.jpg" "$work/overlay/usr/local/share/memento/wallpaper.jpg"
install -m 0644 "$sandbox_root/vm/fonts/JetBrainsMono-Regular.ttf" "$work/overlay/usr/local/share/fonts/JetBrainsMono-Regular.ttf"
install -m 0644 "$ca_bundle" "$work/overlay/usr/local/etc/ssl/certs/ca-certificates.crt"
chmod 0755 "$work/overlay/sbin/autologin" "$work/overlay/sbin/memento-login" "$work/overlay/usr/local/bin/submit" "$work/overlay/usr/local/bin/status"

escaped_backend=$(printf '%s' "$backend_url" | sed 's/[&|]/\\&/g')
find "$work/overlay" -type f -exec sed -i "s|__BACKEND_URL__|$escaped_backend|g" {} +
(cd "$work/overlay" && find . -print | cpio -o -H newc 2>/dev/null | gzip -9) >"$work/iso/boot/sisterd.gz"
mkisofs -l -r -J -V MEMENTO_LAB -b boot/isolinux/isolinux.bin -c boot/isolinux/boot.cat -no-emul-boot -boot-load-size 4 -boot-info-table -o "$output" "$work/iso" >/dev/null
printf 'ISO created: %s\n' "$output"
