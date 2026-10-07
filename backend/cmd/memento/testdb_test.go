package main

import (
	"context"
	"fmt"
	"net/url"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

// testDatabase returns a pool on a freshly migrated database that exists only
// for the calling test. It skips the test unless MEMENTO_TEST_DATABASE_URL
// points at a PostgreSQL server where that user may create databases, for
// example postgresql://memento@127.0.0.1:5432/postgres?sslmode=disable.
func testDatabase(t *testing.T) *pgxpool.Pool {
	t.Helper()
	adminURL := os.Getenv("MEMENTO_TEST_DATABASE_URL")
	if adminURL == "" {
		t.Skip("MEMENTO_TEST_DATABASE_URL is not set")
	}
	ctx := context.Background()
	admin, err := pgx.Connect(ctx, adminURL)
	if err != nil {
		t.Fatalf("connect to the test server: %v", err)
	}
	t.Cleanup(func() { _ = admin.Close(ctx) })

	name := fmt.Sprintf("memento_test_%d_%d", os.Getpid(), time.Now().UnixNano())
	if _, err := admin.Exec(ctx, "CREATE DATABASE "+name); err != nil {
		t.Fatalf("create the test database: %v", err)
	}
	t.Cleanup(func() { _, _ = admin.Exec(ctx, "DROP DATABASE IF EXISTS "+name+" WITH (FORCE)") })

	target, err := url.Parse(adminURL)
	if err != nil {
		t.Fatalf("parse MEMENTO_TEST_DATABASE_URL: %v", err)
	}
	target.Path = "/" + name
	pool, err := openDatabase(ctx, config{databaseURL: target.String()})
	if err != nil {
		t.Fatalf("open the test database: %v", err)
	}
	t.Cleanup(pool.Close)
	return pool
}

func addStudents(t *testing.T, db *pgxpool.Pool, ids ...string) {
	t.Helper()
	for _, id := range ids {
		if _, err := db.Exec(context.Background(), `INSERT INTO students (id, display_name) VALUES ($1, $1)`, id); err != nil {
			t.Fatalf("add student %s: %v", id, err)
		}
	}
}

func newSubmission(t *testing.T, db *pgxpool.Pool, cfg config, student string) submission {
	t.Helper()
	value, err := createSubmission(context.Background(), db, cfg, student, strings.NewReader("int bitXor(int x, int y) { return 0; }"))
	if err != nil {
		t.Fatalf("create a submission for %s: %v", student, err)
	}
	return value
}

// jobID returns a valid 24-character submission ID for fixtures.
func jobID(n int) string { return fmt.Sprintf("%024x", n) }

func TestMigrationsApplyToAnEmptyDatabase(t *testing.T) {
	db := testDatabase(t)
	ctx := context.Background()
	appliedMigrations := func() int {
		var count int
		if err := db.QueryRow(ctx, `SELECT count(*) FROM schema_migrations`).Scan(&count); err != nil {
			t.Fatalf("count applied migrations: %v", err)
		}
		return count
	}
	if got := appliedMigrations(); got != len(migrations) {
		t.Fatalf("applied %d migrations, want %d", got, len(migrations))
	}
	for _, table := range []string{"students", "submissions", "vm_activations", "worker_heartbeats"} {
		var exists bool
		if err := db.QueryRow(ctx, `SELECT to_regclass($1) IS NOT NULL`, table).Scan(&exists); err != nil || !exists {
			t.Errorf("table %s is missing after migration (err=%v)", table, err)
		}
	}
	if err := migrate(ctx, db); err != nil {
		t.Fatalf("running the migrations a second time: %v", err)
	}
	if got := appliedMigrations(); got != len(migrations) {
		t.Fatalf("a second run changed the applied migrations to %d, want %d", got, len(migrations))
	}
}
