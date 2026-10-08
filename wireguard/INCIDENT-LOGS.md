# Incident logs for the exam VPN

The VPN host keeps three records that help reconstruct an incident afterwards.
Nothing here flags or disconnects a student. The logs only record, and a person
decides what they mean.

| Record | Where | Shows |
| --- | --- | --- |
| Connection events | `/var/log/memento-vpn-events.log` | When each student connected, went quiet, came back, or changed public address, and when peers were added, removed, or unknown |
| Dropped traffic | The kernel log, lines that start with `memento-vpn-drop` | What a student's tunnel tried to reach and could not, for the first few packets each minute per student |
| Drop counters | `nft list chain inet memento_vpn input` and `forward` | How many packets were dropped in total, which the per-student limit does not cap |

## Set it up

Do this once on the VPN host, before the exam.

```sh
# The connection log, as a service. Edit ExecStart to match where the repository is.
sudo cp wireguard/memento-vpn-log.service.example /etc/systemd/system/memento-vpn-log.service
sudo cp wireguard/memento-vpn-log.logrotate.example /etc/logrotate.d/memento-vpn-events
sudo systemctl daemon-reload
sudo systemctl enable --now memento-vpn-log

# The dropped-traffic log: install the rules and reload them the way wg0.conf does.
sudo cp wireguard/memento-vpn.nft /etc/wireguard/memento-vpn.nft
sudo nft delete table inet memento_vpn
sudo nft -f /etc/wireguard/memento-vpn.nft
```

Check that both work:

```sh
tail -f /var/log/memento-vpn-events.log
```

The first line is `event=start`, and an `event=summary` line follows every
minute. If summaries stop, the logger stopped.

## The connection log

Each line is a timestamp and `key=value` pairs:

```text
2026-10-16T06:58:13Z event=connected student=18225001 address=10.66.0.10 endpoint=203.0.113.7:51820
2026-10-16T07:03:13Z event=silent student=18225001 address=10.66.0.10 idle_seconds=64 endpoint=203.0.113.7:51820
2026-10-16T07:04:43Z event=recovered student=18225001 address=10.66.0.10 gap_seconds=94 endpoint=203.0.113.7:51820
2026-10-16T07:10:03Z event=endpoint_changed student=18225002 address=10.66.0.11 from=203.0.113.9:51820 to=198.51.100.4:40000
2026-10-16T07:11:03Z event=summary peers=130 up=127 silent=2 never=1 missing=0 unknown=0
```

| Event | Meaning |
| --- | --- |
| `start`, `stop` | The logger started, or was stopped cleanly. A `start` has `previous_sample_age`, the seconds since the last sample before it, when there was one. |
| `connected` | A peer completed its first handshake. `baseline=1` means it was already connected when the logger first looked. |
| `silent` | A connected peer sent no handshake and no traffic for `--silent-seconds` (60). |
| `recovered` | A silent peer is back. `gap_seconds` runs from its last sign of life. |
| `endpoint_changed` | The peer's public address changed. A new port on the same address is not recorded. |
| `peer_added`, `peer_removed`, `peer_missing` | A peer was provisioned, left the server configuration or the interface, or is in the configuration but not on the interface. |
| `unknown_peer` | A peer is on the interface but not in the server configuration, with its public key. |
| `interface_down`, `interface_up` | `wg` could not be read, or can be again. |
| `summary` | Counts of peers that are up, silent, never connected, missing, and unknown. |

### How exact the times are

A peer counts as silent after 60 seconds without a handshake or any received
traffic. The generated profiles send a keepalive every 25 seconds and the
logger samples every 10 seconds, so a drop shorter than about a minute is not
recorded, and the times of `silent` and `recovered` are accurate to roughly half
a minute. Silence is also what a sleeping laptop or a Wi-Fi roam looks like. The
log records that it happened, not why.

Change the settings with `--interval`, `--silent-seconds`, and
`--summary-seconds` on the `ExecStart` line. `--once` takes a single sample, for
a cron job.

## Questions the logs answer

One student's timeline:

```sh
grep 'student=18225001 ' /var/log/memento-vpn-events.log
```

Who never connected. `roster.txt` has one student ID per line:

```sh
grep -o ' event=connected student=[^ ]*' /var/log/memento-vpn-events.log | sed 's/.*student=//' | sort -u > connected.txt
sort -u roster.txt | comm -23 - connected.txt
```

How long each student was silent, in total:

```sh
awk '/ event=recovered / { for (i = 1; i <= NF; i++) { split($i, kv, "="); v[kv[1]] = kv[2] } gaps[v["student"]]++; secs[v["student"]] += v["gap_seconds"] } END { for (s in gaps) printf "%s\t%d gaps\t%d s\n", s, gaps[s], secs[s] }' /var/log/memento-vpn-events.log
```

A student who was silent when the log ends has a `silent` line and no later
`recovered` line, so check for that as well.

Who used a profile from more than one public address, most changes first:

```sh
grep ' event=endpoint_changed ' /var/log/memento-vpn-events.log | awk '{ print $3 }' | sort | uniq -c | sort -rn
```

One change can be a student moving from Wi-Fi to a phone hotspot. Repeated
changes back and forth are what two devices sharing one profile look like.

What a student tried to reach. The tunnel address is in the server
configuration, and the kernel logs the first few dropped packets per minute for
each address:

```sh
sudo grep -A4 'student: 18225001$' /etc/wireguard/wg0.conf | grep AllowedIPs
sudo journalctl -k | grep memento-vpn-drop | grep 'SRC=10.66.0.10 '
```

Each line names the destination (`DST`), protocol, and port. These lines are
written by the host's kernel, so they appear only in the VPN host's kernel log.
For totals that the limit does not cap, read the packet counters:

```sh
sudo nft list chain inet memento_vpn input
sudo nft list chain inet memento_vpn forward
```

## Retention and access

The connection log holds student IDs, tunnel addresses, and public IP addresses,
which is personal data. It is created readable by root only. Do not copy it to a
shared drive. Keep it, with its rotated files, until the grades are final and any
appeal period has ended, then delete it. The example rotation keeps 30 daily
files, so shorten or lengthen `rotate` to match.

## What the logs cannot show

- What a student sent over HTTPS to the grading proxy, or anything on their own machine.
- A drop shorter than the timings above.
- Use of a phone hotspot or a second network, which never touches the tunnel.
- The logs are only as complete as the logger's uptime. A gap between summary lines is a gap in the record.
