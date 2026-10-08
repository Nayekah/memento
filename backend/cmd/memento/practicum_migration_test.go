package main

import (
	"context"
	"strings"
	"testing"
)

func TestPracticumMigrationKeepsExistingSubmissionsInDataLab(t *testing.T) {
	db := emptyTestDatabase(t)
	ctx := context.Background()
	cut := migrationPosition(t, "007_submission_practicum")
	if err := applyMigrations(ctx, db, migrations[:cut]); err != nil {
		t.Fatalf("apply the migrations before the practicum column: %v", err)
	}
	if _, err := db.Exec(ctx, `INSERT INTO students (id, display_name) VALUES ('alice', 'Ayu')`); err != nil {
		t.Fatal(err)
	}
	if _, err := db.Exec(ctx, `INSERT INTO submissions (id, student_id, source, source_sha256, status) VALUES ($1, 'alice', 'x', repeat('0', 64), 'queued')`, jobID(1)); err != nil {
		t.Fatal(err)
	}
	if err := applyMigrations(ctx, db, migrations); err != nil {
		t.Fatalf("apply the practicum migration to existing data: %v", err)
	}
	var practicum string
	if err := db.QueryRow(ctx, `SELECT practicum FROM submissions WHERE id = $1`, jobID(1)).Scan(&practicum); err != nil || practicum != "datalab" {
		t.Errorf("an existing submission has practicum %q (err=%v), want datalab", practicum, err)
	}
	for _, bad := range []string{"", "Bomb Lab", "1lab", "bomb_lab", strings.Repeat("x", 33)} {
		_, err := db.Exec(ctx, `INSERT INTO submissions (id, student_id, source, source_sha256, status, practicum) VALUES ($1, 'alice', 'x', repeat('0', 64), 'queued', $2)`, jobID(2), bad)
		if err == nil {
			t.Errorf("the practicum %q was accepted", bad)
		}
	}
	var exists bool
	if err := db.QueryRow(ctx, `SELECT to_regclass('submissions_practicum_leaderboard_idx') IS NOT NULL`).Scan(&exists); err != nil || !exists {
		t.Errorf("the leaderboard index is missing (err=%v)", err)
	}
}
