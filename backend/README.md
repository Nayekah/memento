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

Copy `.env.example` to `.env` and configure:

| Variable | Purpose |
| --- | --- |
| `DOMAIN` | Public domain used by Caddy |
| `TOKEN_SECRET` | HMAC secret for student tokens |
| `POSTGRES_PASSWORD` | PostgreSQL password |
| `WORK_DIR` | Absolute Linux directory for temporary grader files |
| `SUBMISSION_RATE_PER_MINUTE` | Per-student submission limit; `0` disables it |

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

## Backups

Back up the database and the files that cannot be regenerated. Every student
token derives from `TOKEN_SECRET`, so a database backup alone is not enough to
restore the service: without the secret, every token changes.

```bash
umask 077
openssl rand -base64 32 > /secure/memento-backup.pass
bash scripts/backup.sh \
  --passphrase-file /secure/memento-backup.pass \
  --output-dir /secure/backups \
  --config .env --config scoreboard-config \
  --keep 14
```

Each run writes `memento-db-<UTC time>.dump.gpg` and, because of `--config`,
`memento-config-<UTC time>.tar.gz.gpg`, each with a `.sha256` file. The files are
encrypted with GnuPG (AES-256, symmetric). Keep a copy of the passphrase file
away from the server and away from the backups: without it they cannot be
restored. Add more `--config` paths for anything else the server holds, such as
`/etc/wireguard` and the cohort output directory with the student profiles.

The dump runs inside the `postgres` container through `docker compose exec`, so
that container has to be running and its client always matches the server
version. Use `--direct` to run `pg_dump` from `PATH` instead; the connection then
comes from the standard `PG*` variables. To schedule backups, call the script
from cron or a systemd timer. The scripts target Linux hosts.

### Restore drill

Run the drill after the first backup and whenever the setup changes. It restores
into a temporary database, prints row counts for the main tables, and drops the
database again, so nothing that exists is touched:

```bash
bash scripts/restore.sh \
  --passphrase-file /secure/memento-backup.pass \
  --db-backup /secure/backups/memento-db-<UTC time>.dump.gpg \
  --verify
```

### Restoring

Stop everything that writes to the database, restore, then start it again.
`--yes-overwrite` must repeat the database name. The backup is decrypted and
authenticated before anything is changed.

```bash
docker compose stop proxy api worker
bash scripts/restore.sh \
  --passphrase-file /secure/memento-backup.pass \
  --db-backup /secure/backups/memento-db-<UTC time>.dump.gpg \
  --restore-into memento --yes-overwrite memento
docker compose up -d
```

The configuration archive unpacks into a new or empty directory with
`--config-backup FILE --extract-to DIR`; copy the files into place from there.

`bash scripts/backup-test.sh` checks all of this against a temporary PostgreSQL
cluster. It needs the PostgreSQL server binaries, `gpg`, and Go, and it exercises
the Compose code path through a stub `docker`.

## API

- `POST /api/v1/vm-activation`
- `POST /api/v1/submissions`
- `GET /api/v1/submissions/{id}`
- `GET /api/v1/submissions/{id}/report`
- `GET /api/v1/leaderboard`
- `GET /api/v1/system/status`

Submission and report endpoints require `X-Memento-Student` and
`X-Memento-Token`. The leaderboard is global and uses each student's best
completed score.

## Verification

From WSL, after building the images:

```bash
bash scripts/smoke-test.sh
```

The smoke test creates temporary services, submits `bits.c`, verifies grading
and leaderboard output, then removes its temporary resources.
