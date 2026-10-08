ALTER TABLE students
    ADD COLUMN token_version integer NOT NULL DEFAULT 0 CHECK (token_version >= 0),
    ADD COLUMN disabled_at timestamptz;
