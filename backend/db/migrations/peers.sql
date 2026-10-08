CREATE TABLE student_peers (
    student_id text PRIMARY KEY REFERENCES students(id) ON DELETE CASCADE,
    peer_ip inet NOT NULL UNIQUE,
    created_at timestamptz NOT NULL DEFAULT now(),
    CHECK (masklen(peer_ip) = CASE family(peer_ip) WHEN 4 THEN 32 ELSE 128 END)
);
