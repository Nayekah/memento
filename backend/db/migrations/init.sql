CREATE TABLE students (
    id text PRIMARY KEY,
    display_name text NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now(),
    CHECK (id ~ '^[A-Za-z0-9._-]{1,64}$'),
    CHECK (char_length(display_name) BETWEEN 1 AND 120)
);

CREATE TABLE submissions (
    id char(24) PRIMARY KEY,
    student_id text NOT NULL REFERENCES students(id) ON DELETE RESTRICT,
    source bytea NOT NULL,
    source_sha256 char(64) NOT NULL,
    status text NOT NULL CHECK (status IN ('queued', 'processing', 'completed', 'failed')),
    score integer,
    max_score integer,
    result jsonb,
    error text,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    claimed_at timestamptz,
    completed_at timestamptz,
    CHECK ((score IS NULL AND max_score IS NULL) OR (score >= 0 AND max_score > 0 AND score <= max_score))
);

CREATE INDEX submissions_queue_idx ON submissions (created_at) WHERE status = 'queued';
CREATE INDEX submissions_student_idx ON submissions (student_id, created_at DESC);
CREATE INDEX submissions_leaderboard_idx ON submissions (student_id, score DESC, completed_at ASC) WHERE status = 'completed' AND score IS NOT NULL;
