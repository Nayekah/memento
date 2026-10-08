# Memento Backend

> API, queue, persistence, and isolated grading for Memento Lab.

[Root README](../README.md) · [VM Guide](../sandbox/README.md)

## Overview

The backend accepts `bits.c`, stores submissions in PostgreSQL, and grades them
inside a restricted Docker container. The API never executes student code.

```text
Student VM -> Caddy HTTPS proxy -> API -> PostgreSQL queue -> Worker -> Grader
```

| Service | Responsibility |
| --- | --- |
| `proxy` | Caddy TLS termination and public HTTPS entry point |
| `api` | Activation, submission, report, and leaderboard endpoints |
| `worker` | Concurrent queue consumer and grader launcher |
| `postgres` | Persistent students, submissions, scores, and queue state |

## Configuration

Copy `.env.example` to `.env` and fill in every empty value:

| Variable | Purpose |
| --- | --- |
| `DOMAIN` | Public domain used by Caddy |
| `TOKEN_SECRET` | HMAC secret for student tokens. Every token derives from it, so generate it once with `openssl rand -base64 32` and keep it |
| `POSTGRES_PASSWORD` | PostgreSQL password. It is placed in a connection URL, so use URL-safe characters, for example `openssl rand -hex 24` |
| `WORK_DIR` | Absolute Linux directory for temporary grader files |
| `SUBMISSION_RATE_PER_MINUTE` | Per-student submission limit; `0` disables it |

The example file ships without secret values. `docker compose` refuses to start
while `TOKEN_SECRET` or `POSTGRES_PASSWORD` is empty, and the API and the
`token` command refuse the token secret that earlier versions of the example
file contained. A deployment that ran with those earlier values should be
treated as compromised: choose new secrets, then issue new student tokens.

## Deployment

```bash
cp .env.example .env
mkdir -p /srv/memento/grader-work
docker compose build grader-image api worker
docker compose up -d
```

Point the DNS A/AAAA records for `DOMAIN` to this server and allow inbound TCP
ports `80` and `443`. Caddy manages TLS and forwards requests internally to the
API on port `8067`. PostgreSQL is not published.

## Operations

```bash
docker compose run --rm api student STUDENT_ID "Display Name"
docker compose run --rm api token STUDENT_ID
docker compose run --rm api reset-activation STUDENT_ID
docker compose up -d --scale worker=4
docker compose run --rm api regrade SUBMISSION_ID
```

The queue uses `FOR UPDATE SKIP LOCKED`, so one submission is claimed by one
worker. A per-student advisory lock protects the submission rate limit.

## API

- `POST /api/v1/vm-activation`
- `POST /api/v1/submissions`
- `PUT /api/v1/me/display-name`
- `GET /api/v1/submissions/{id}`
- `GET /api/v1/submissions/{id}/report`
- `GET /api/v1/leaderboard`
- `GET /api/v1/system/status`

Submission, report, and display-name endpoints require `X-Memento-Student`
and `X-Memento-Token`. The leaderboard is global and uses each student's best
completed score.

## Verification

From WSL, after building the images:

```bash
bash scripts/smoke-test.sh
```

The smoke test creates temporary services, submits `bits.c`, verifies grading
and leaderboard output, then removes its temporary resources.

The Go tests run with `go test ./cmd/memento`. The ones that need PostgreSQL
(migrations, submission ownership, the rate limit, queue claiming, VM
activation, and the leaderboard) skip themselves unless
`MEMENTO_TEST_DATABASE_URL` points at a server where that user may create
databases. Each test creates and drops its own database, so the URL can name
any existing database:

```bash
MEMENTO_TEST_DATABASE_URL='postgresql://user:password@127.0.0.1:5432/postgres?sslmode=disable' \
  go test -race ./cmd/memento
```

## Peer binding

A student token is derived from the student ID, so on its own it works from any
VPN peer. Peer binding ties each student to the VPN address that
`wireguard/provision-cohort.sh` assigned and checks that address on every
authenticated request. Register the addresses once the cohort is provisioned,
using the manifest the script wrote:

```bash
docker compose run --rm -T api peers import < /secure/memento-cohort-2026/students.tsv
docker compose run --rm api peer 18225001             # show one address
docker compose run --rm api peer 18225001 10.66.0.10  # set or change it
docker compose run --rm api peer 18225001 --clear     # remove it
```

The import reads the student ID and the address from the first two columns,
skips a header row that starts with `nim`, and registers either every row or
none, naming the line it refuses. Replacing a peer's keys with
`wireguard/replace-peer.sh` keeps its address, so nothing needs to be
registered again.

`PEER_BINDING` selects what the API does when a request does not come from the
registered address:

| Value | Behaviour |
| --- | --- |
| `off` (default) | No check. |
| `log` | The mismatch is logged as `peer binding: student=... client=...` and the request is allowed. |
| `enforce` | The request is rejected with `401`. A student with no registered address is rejected too. |

Roll it out in that order: rehearse with `log`, fix the registrations that the
log shows, then switch to `enforce`. Set `PEER_BINDING` in `.env` and restart
the API. `PEER_BINDING=off` and a restart is the way back.

The API reads the client address from the connection. Behind Caddy that
connection is the proxy, so `TRUSTED_PROXY` lists the proxy's address, as
addresses or CIDR ranges separated by commas. The Compose default is
`172.30.0.4`, the proxy's fixed address in the WireGuard setup. A request from a
listed proxy is attributed to the last `X-Forwarded-For` entry, and the header
is ignored on every other connection, so a client cannot choose its own
address. If the proxy's address is wrong, every request looks as if it came
from the proxy; `log` mode shows that before `enforce` locks anyone out.

`bash scripts/peer-binding-test.sh` checks all of this with real Caddy in front
of the API. Students connect from different loopback addresses, and forged
`X-Forwarded-For` headers must not change the outcome. It needs the PostgreSQL
server binaries, `caddy`, `curl`, and Go.

## Student tokens

A token is derived from `TOKEN_SECRET` and the student ID, so it does not change
by itself. Each student also has a token version, which starts at 0, and a
disabled flag. Version 0 is the original derivation, so tokens that have
already been issued keep working until their student is rotated.

```bash
docker compose run --rm -T api token 18225001         # print the current token
docker compose run --rm -T api rotate-token 18225001  # invalidate it and print a new one
docker compose run --rm api disable 18225001          # refuse every request from this student
docker compose run --rm api enable 18225001           # undo that
```

`rotate-token` changes one student's token and nobody else's. The old token is
refused with `invalid submission token` from the next request, so the student
has to be given the new one. To rebuild a cohort profile around it, write the
token to a file and pass that file to `wireguard/replace-peer.sh --token-file`.

A disabled student's requests are refused with `this student account is
disabled`, but only when the token is valid, so a wrong token does not reveal
whether an account is disabled. Submissions and scores are kept. Disabling does
not touch the VPN; revoke the peer separately.

For a lost laptop, revoke the peer with `wireguard/revoke-peer.sh`, rotate the
token, and replace the peer with the new token file. Use `disable` instead to
lock a student out until you decide otherwise.

The API reads the student's token version on every authenticated request, so a
rotation or a disable takes effect at once and needs no restart.

`bash scripts/token-state-test.sh` checks the commands and the API's behaviour
against a temporary PostgreSQL cluster. It needs the PostgreSQL server binaries,
`curl`, and Go.

## Display names

Display names are unique without regard to letter case, which a unique index on
`lower(display_name)` enforces. `memento student STUDENT_ID "Name"` answers
`that display name is already used by another student` when another student has
the name.

The index is created by a migration that runs at startup. Where students
already share a name, the student who registered first keeps it and every later
one gets their student ID added, so `Ayu` and `ayu` become `Ayu` and
`ayu 18225002`. The migration can then finish on existing data without a manual
step, and those students can choose a new name afterwards.

## Practicums

Every submission belongs to a practicum, recorded in `submissions.practicum`.
Everything submitted before the column existed is Data Lab, which is also the
default, because Data Lab is the only practicum the grader handles.

Each practicum has its own leaderboard at
`GET /api/v1/practicums/{practicum}/leaderboard`, in the same shape as
`GET /api/v1/leaderboard`, which stays the Data Lab board. The practicums the
API knows are listed in `practicumIDs` in `backend/cmd/memento/practicums.go`:
`datalab` and `bomblab`. An ID that is not listed answers `404`, and a listed
practicum without scores returns an empty list. To open a new practicum, add
its ID to the list. The scoreboard picks one in its configuration with the
`practicum` and `endpoint` fields.

Nothing accepts Bomb Lab submissions yet, so its board stays empty until the
grader and a submission route for it exist.

When the proxy lets VPN clients reach only an allowlist of API paths,
`/api/v1/practicums/*/leaderboard` has to be added to it before the scoreboard
can show a practicum other than Data Lab.

## Challenge results

The Data Lab driver ends its output with one row per puzzle and a `Score =`
line. When grading completes, the worker reads that table and stores it in the
submission's result as `challenges`, one entry per puzzle in the order the
driver printed them:

```json
{"challenges": [{"name": "bitAnd", "points": 3, "max": 3}, {"name": "negate", "points": 2, "max": 4}]}
```

`points` adds the correctness and performance points the student earned for the
puzzle, and `max` adds the correctness rating to the performance rating. The
driver reports the performance rating only as a total, so it is divided evenly
across the puzzles. A puzzle is solved when `points` equals `max`, partly done
when it has some points but not all (for example, a correct answer that uses
more operators than allowed), and unsolved when it has none. The number of
puzzles comes from the problem set in the grader image, so the practicum and
its dry run need no extra configuration.

The leaderboard returns the list for each student's best submission as
`challenges` in the entry. The field is left out when there is nothing to
return. Ranking and the other fields do not change.

The parser accepts only a complete table whose rows add up to the totals line.
If the driver's output format changes, for example with a new problem set, the
field is left out instead of being guessed, and the scoreboard falls back to
its score bar. Update `backend/cmd/memento/challenges.go` and the captured
output in `backend/cmd/memento/testdata` to match.

Submissions graded before this feature have no `challenges`. Running
`memento regrade SUBMISSION_ID` queues one for grading again, and it stays off
the board until the worker has finished it.
