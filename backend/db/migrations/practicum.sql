-- Every submission belongs to a practicum. Everything submitted so far is Data
-- Lab, the only practicum the grader handles, so that is the default.
ALTER TABLE submissions
    ADD COLUMN practicum text NOT NULL DEFAULT 'datalab' CHECK (practicum ~ '^[a-z][a-z0-9-]{0,31}$');

CREATE INDEX submissions_practicum_leaderboard_idx ON submissions (practicum, student_id, score DESC, completed_at ASC) WHERE status = 'completed' AND score IS NOT NULL;
