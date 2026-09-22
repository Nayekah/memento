#!/usr/bin/env bash
set -euo pipefail

STAGED_BITS=/tmp/bits.c

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends curl less nano vim-tiny
apt-get clean
rm -rf /var/lib/apt/lists/*

install -d -m 0755 /etc/memento
test -f "$STAGED_BITS"

# The Packer file provisioner transfers only bits.c. The trusted backend grader
# separately receives sandbox/src through backend/Dockerfile.grader.
install -d -m 0755 /usr/local/share/memento
install -m 0644 "$STAGED_BITS" /usr/local/share/memento/bits.c.template
rm -f "$STAGED_BITS"

printf 'BACKEND_URL=%q\n' "$BACKEND_URL" >/etc/memento/backend.env
chmod 0644 /etc/memento/backend.env
cat >/etc/profile.d/memento-data-lab.sh <<'EOF'
if [ -n "${PS1:-}" ] && [ -d "$HOME/memento" ]; then
    cd "$HOME/memento"
fi
EOF
chmod 0644 /etc/profile.d/memento-data-lab.sh

cat >/etc/profile.d/memento-backend.sh <<'EOF'
if [ -r /etc/memento/backend.env ]; then
    set -a
    . /etc/memento/backend.env
    set +a
fi
EOF
chmod 0644 /etc/profile.d/memento-backend.sh

cat >/usr/local/bin/submit <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

wait_for_result=true
if [ "${1:-}" = "--no-wait" ]; then
    wait_for_result=false
    shift
fi
if [ "${1:-}" = "--help" ]; then
    echo 'usage: submit [--no-wait] [bits.c]'
    exit 0
fi
if [ "$#" -gt 1 ] || { [ "$#" -eq 1 ] && [ "$1" != "bits.c" ]; }; then
    echo 'usage: submit [--no-wait] [bits.c]' >&2
    exit 2
fi
source_file="$HOME/memento/bits.c"
auth_file="$HOME/.config/memento/auth.env"
if [ -r "$auth_file" ]; then
    set -a
    . "$auth_file"
    set +a
fi
: "${BACKEND_URL:?Open a new shell or source /etc/memento/backend.env}"
: "${STUDENT_ID:?Set your student ID first}"
: "${TOKEN:?Set your submission token first}"
if [ -L "$source_file" ] || [ ! -f "$source_file" ]; then
    echo "Required source file not found: $source_file" >&2
    exit 1
fi

response=$(curl --fail-with-body --silent --show-error \
    -H "X-Memento-Student: $STUDENT_ID" \
    -H "X-Memento-Token: $TOKEN" \
    -F "source=@${source_file};filename=bits.c;type=text/x-c" \
    "$BACKEND_URL/api/v1/submissions")
submission_id=$(printf '%s\n' "$response" | sed -n 's/.*"id":"\([a-f0-9]\{24\}\)".*/\1/p')
if [ -z "$submission_id" ]; then
    echo "Unrecognized submission response: $response" >&2
    exit 1
fi
printf 'Submission ID: %s\nVerdict: QUEUED\n' "$submission_id"
if [ "$wait_for_result" = false ]; then
    exit 0
fi

echo 'Waiting for grading results (up to 2 minutes)...'
for _ in $(seq 1 120); do
    report=$(status "$submission_id")
    if printf '%s\n' "$report" | grep -q '^Status: completed$\|^Status: failed$'; then
        printf '%s\n' "$report"
        exit 0
    fi
    sleep 1
done
echo "Grading is not finished yet. Run: status $submission_id"
EOF
chmod 0755 /usr/local/bin/submit

cat >/usr/local/bin/status <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

submission_id=${1:?usage: status SUBMISSION_ID}
auth_file="$HOME/.config/memento/auth.env"
if [ -r "$auth_file" ]; then
    set -a
    . "$auth_file"
    set +a
fi
: "${BACKEND_URL:?Open a new shell or source /etc/memento/backend.env}"
: "${STUDENT_ID:?Set your student ID first}"
: "${TOKEN:?Set your submission token first}"

curl --fail-with-body --silent --show-error \
    -H "X-Memento-Student: $STUDENT_ID" \
    -H "X-Memento-Token: $TOKEN" \
    "$BACKEND_URL/api/v1/submissions/$submission_id/report"
EOF
chmod 0755 /usr/local/bin/status

install -d -m 0700 /var/lib/memento

cat >/usr/local/sbin/memento-firstboot <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

state_dir=/var/lib/memento
activation_file="$state_dir/activation"
device_file="$state_dir/device-id"
template_file=/usr/local/share/memento/bits.c.template

[ -f "$activation_file" ] && exit 0
exec </dev/tty1 >/dev/tty1 2>&1

if [ ! -r /etc/memento/backend.env ]; then
    echo 'Backend configuration was not found.'
    exit 1
fi
set -a
. /etc/memento/backend.env
set +a

if [ ! -f "$device_file" ]; then
    tr -d '-' </proc/sys/kernel/random/uuid >"$device_file"
    chmod 0600 "$device_file"
fi
device_id=$(cat "$device_file")

while true; do
    clear || true
    echo '=== Memento Lab Activation ==='
    echo 'Enter your student ID and activation token.'
    echo
    read -r -p 'Student ID: ' student_id
    if [[ ! "$student_id" =~ ^[A-Za-z0-9._-]{1,64}$ ]]; then
        echo 'Invalid student ID. Press Enter to try again.'
        read -r
        continue
    fi
    read -r -s -p 'Token: ' token
    echo
    if [ -z "$token" ]; then
        echo 'Token cannot be empty. Press Enter to try again.'
        read -r
        continue
    fi
    read -r -s -p 'New Linux password: ' password
    echo
    read -r -s -p 'Repeat password: ' confirmation
    echo
    if [ "$password" != "$confirmation" ] || [ ${#password} -lt 10 ]; then
        echo 'Passwords must match and be at least 10 characters long. Press Enter to try again.'
        read -r
        continue
    fi

    if ! response=$(curl --fail-with-body --silent --show-error --connect-timeout 10 --max-time 30 \
        -H "X-Memento-Student: $student_id" \
        -H "X-Memento-Token: $token" \
        -H 'Content-Type: application/json' \
        --data "{\"device_id\":\"$device_id\"}" \
        "$BACKEND_URL/api/v1/vm-activation"); then
        echo
        echo "Activation failed: $response"
        echo 'Check the network connection, student ID, and token. Press Enter to try again.'
        read -r
        continue
    fi

    if ! id "$student_id" >/dev/null 2>&1; then
        useradd --create-home --shell /bin/bash "$student_id"
    fi
    printf '%s:%s\n' "$student_id" "$password" | chpasswd
    install -d -o "$student_id" -g "$student_id" -m 0700 "/home/$student_id/.config/memento"
    {
        printf 'STUDENT_ID=%q\n' "$student_id"
        printf 'TOKEN=%q\n' "$token"
    } >"/home/$student_id/.config/memento/auth.env"
    chown "$student_id:$student_id" "/home/$student_id/.config/memento/auth.env"
    chmod 0600 "/home/$student_id/.config/memento/auth.env"
    install -d -o "$student_id" -g "$student_id" -m 0755 "/home/$student_id/memento"
    if [ ! -f "/home/$student_id/memento/bits.c" ]; then
        install -o "$student_id" -g "$student_id" -m 0644 "$template_file" "/home/$student_id/memento/bits.c"
    fi
    printf '%s\n' "$student_id" >"$activation_file"
    chmod 0600 "$activation_file"
    echo
    echo "Activation succeeded. Sign in as $student_id to begin."
    sleep 3
    exit 0
done
EOF
chmod 0755 /usr/local/sbin/memento-firstboot

cat >/etc/systemd/system/memento-firstboot.service <<'EOF'
[Unit]
Description=Activate a Memento student VM on first boot
Wants=network-online.target
After=network-online.target
Before=getty@tty1.service
ConditionPathExists=!/var/lib/memento/activation

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/memento-firstboot
StandardInput=tty-force
StandardOutput=tty
StandardError=tty
TTYPath=/dev/tty1
TTYReset=yes
TTYVHangup=yes

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable memento-firstboot.service
# This build-only account is used by Packer SSH. Student VMs must activate a
# unique account instead of sharing it.
passwd -l practicant
usermod --expiredate 1 practicant
