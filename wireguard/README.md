# Memento exam-network WireGuard

This is a full-tunnel exam network, not a general VPN. Each student receives a
different WireGuard peer address and private key. The generated client profile
sends all IPv4 and IPv6 traffic to the server. The server then drops every
student flow except DNS for the grading hostname and HTTPS to the Memento
proxy. As a result, webchat LLMs, LLM APIs, search engines, package mirrors,
and arbitrary agent backends have no usable network path while the tunnel is
connected.

This is network enforcement, not a complete anti-cheating guarantee. A student
can still disconnect WireGuard, use a phone hotspot/second interface, run a
local model, or use pre-downloaded material. For a meaningful exam control,
issue managed devices or require a client kill-switch that blocks untunneled
traffic, and verify the WireGuard handshake during the assessment.

## Server setup

Run these commands on the Linux host that runs `backend/compose.yaml`:

```sh
sudo apt-get update
sudo apt-get install -y wireguard nftables dnsmasq
sudo install -d -m 0700 /etc/wireguard
sudo sh -c 'umask 077; wg genkey > /etc/wireguard/server-private.key; wg pubkey < /etc/wireguard/server-private.key > /etc/wireguard/server-public.key'
sudo cp wireguard/wg0.conf.example /etc/wireguard/wg0.conf
sudo cp wireguard/memento-vpn.nft /etc/wireguard/memento-vpn.nft
sudo sed -i "s|REPLACE_WITH_SERVER_PRIVATE_KEY|$(sudo cat /etc/wireguard/server-private.key)|" /etc/wireguard/wg0.conf
sudo chmod 0600 /etc/wireguard/wg0.conf /etc/wireguard/server-private.key
```

Configure the grading DNS name in `wireguard/dnsmasq.conf.example`, then
install it and start both services:

```sh
sudo cp wireguard/dnsmasq.conf.example /etc/dnsmasq.d/memento-vpn.conf
sudo systemctl enable --now dnsmasq
sudo systemctl enable --now wg-quick@wg0
sudo wg show
```

The DNS configuration has no upstream resolver. It answers only the grading
hostname with `10.66.0.1`; all other names fail. Open only UDP `51820` from the
Internet in the host firewall. Do not add Internet masquerading or general
forwarding for `wg0`.

The compose file uses Docker network `172.30.0.0/24` and reserves Caddy at
`172.30.0.4`. Change both the Compose subnet/static addresses and
`memento-vpn.nft` if that subnet conflicts with another Docker network.

## Backend policy

Set the same student subnet in `backend/.env`:

```dotenv
VPN_SUBNET=10.66.0.0/24
```

Then deploy:

```sh
cd backend
docker compose up -d --build
```

Caddy returns `403` to public clients and exposes only these paths to a VPN
source address:

- `POST /api/v1/vm-activation`
- `POST /api/v1/submissions`
- `GET /api/v1/submissions/{id}`
- `GET /api/v1/submissions/{id}/report`
- `GET /api/v1/leaderboard`

The system status, health check, PostgreSQL, and the grader are not part of the
student network. The leaderboard remains VPN-only but is intentionally
available to students.

## Provision a student

Use one unused address per student, starting at `10.66.0.10`:

```sh
sudo wireguard/provision-peer.sh \
  --student 2200012345 \
  --address 10.66.0.10 \
  --endpoint vpn.example.edu:51820 \
  --output /secure/peers/2200012345.conf
```

The command adds the peer to the running interface and persists it in
`/etc/wireguard/wg0.conf`. Transfer the generated profile through a secure
administrative channel and delete temporary copies after import.

Import the profile into the student's WireGuard client. It contains
`AllowedIPs = 0.0.0.0/0, ::/0`, so the student's default route is the tunnel.
On WireGuard for Windows, enable **Block untunneled traffic (kill-switch)**
when importing the profile. On Linux/macOS, enforce the equivalent outbound
firewall rule with device management or a managed client profile. The official
Windows client uses this kill-switch mode for a single full-tunnel peer
configuration. Without that control, disconnecting WireGuard immediately
restores ordinary Internet access.

## Provision a cohort by NIM

For a consecutive cohort of 120 students beginning at NIM `18225001`, run the
batch command once from the repository root:

```sh
sudo wireguard/provision-cohort.sh \
  --start-nim 18225001 \
  --count 120 \
  --first-ip 10 \
  --endpoint PUBLIC_IP_SERVER:51820 \
  --output-dir /secure/memento-cohort-2026
```

This creates NIMs `18225001` through `18225120`, assigns VPN addresses
`10.66.0.10` through `10.66.0.129`, registers each NIM in Memento, generates
each token, adds each WireGuard peer, and writes one private `.conf` file per
student. The start NIM, count, first VPN address, endpoint, and output
directory are configurable. The manifest contains file paths, not token values;
the individual `.token` files are mode `0600`.

Do not reuse a profile between students. If the command is interrupted, rerun
it with the same output directory; existing student records, tokens, and peers
are detected and retained while incomplete records continue.

## Verification

From a connected student client:

```sh
nslookup grader.example.edu 10.66.0.1
curl -i https://grader.example.edu/health
curl -i https://grader.example.edu/api/v1/leaderboard
```

The DNS query should return `10.66.0.1`; `/health` should be `404` because it
is not a student route; and `/leaderboard` should succeed over VPN. A real
authenticated submission and report request should work. From a public,
non-VPN connection, every API request should return `403`.

On the server, check that each student is actually connected:

```sh
sudo wg show
```

The latest-handshake timestamp is the minimum operational signal; for a
high-stakes exam, also log peer handshakes and reject submissions whose peer
has not handshaken recently.
