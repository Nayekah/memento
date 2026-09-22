CREATE TABLE vm_activations (
    student_id text PRIMARY KEY REFERENCES students(id) ON DELETE CASCADE,
    device_id char(32) NOT NULL UNIQUE,
    activated_at timestamptz NOT NULL DEFAULT now(),
    last_seen_at timestamptz NOT NULL DEFAULT now(),
    CHECK (device_id ~ '^[a-f0-9]{32}$')
);
