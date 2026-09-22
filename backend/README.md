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
