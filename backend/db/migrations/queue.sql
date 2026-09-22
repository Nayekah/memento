ALTER TABLE submissions
    ADD COLUMN attempt_count integer NOT NULL DEFAULT 0;

CREATE TABLE worker_heartbeats (
    id text PRIMARY KEY,
    status text NOT NULL CHECK (status IN ('idle', 'grading')),
    current_submission_id char(24),
    started_at timestamptz NOT NULL DEFAULT now(),
    last_seen_at timestamptz NOT NULL DEFAULT now(),
    completed_count integer NOT NULL DEFAULT 0,
    failed_count integer NOT NULL DEFAULT 0,
    CHECK ((status = 'idle' AND current_submission_id IS NULL) OR (status = 'grading' AND current_submission_id IS NOT NULL))
);

CREATE INDEX worker_heartbeats_seen_idx ON worker_heartbeats (last_seen_at DESC);
