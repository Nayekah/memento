package main

import (
	"context"
	"errors"
	"strings"
	"testing"

	"github.com/jackc/pgx/v5/pgconn"
)

func migrationPosition(t *testing.T, version string) int {
	t.Helper()
	for position, m := range migrations {
		if m.version == version {
			return position
		}
	}
	t.Fatalf("migration %s is not registered", version)
	return -1
}

func TestUniqueDisplayNameMigrationResolvesExistingDuplicates(t *testing.T) {
	db := emptyTestDatabase(t)
	ctx := context.Background()
	cut := migrationPosition(t, "006_unique_display_names")
	if err := applyMigrations(ctx, db, migrations[:cut]); err != nil {
		t.Fatalf("apply the migrations before the unique index: %v", err)
	}
	long := strings.Repeat("x", 120)
	students := [][3]string{
		{"s1", "Ayu", "10:00"}, {"s2", "ayu", "11:00"}, {"s3", "AYU", "12:00"},
		{"s4", "Budi", "13:00"}, {"s5", "budi", "14:00"}, {"s6", "Citra", "15:00"},
		{"s7", long, "16:00"}, {"s8", strings.ToUpper(long), "17:00"},
	}
	for _, s := range students {
		if _, err := db.Exec(ctx, `INSERT INTO students (id, display_name, created_at) VALUES ($1, $2, ('2026-01-01 ' || $3 || ':00+00')::timestamptz)`, s[0], s[1], s[2]); err != nil {
			t.Fatalf("insert %s: %v", s[0], err)
		}
	}
	if err := applyMigrations(ctx, db, migrations); err != nil {
		t.Fatalf("applying the unique index to a table that already has duplicates: %v", err)
	}

	want := map[string]string{
		"s1": "Ayu", "s2": "ayu s2", "s3": "AYU s3", // the first holder keeps the name
		"s4": "Budi", "s5": "budi s5",
		"s6": "Citra",
		"s7": long,                                // the first of two 120-character names
		"s8": strings.ToUpper(long)[:117] + " s8", // trimmed so the result still fits 120 characters
	}
	rows, err := db.Query(ctx, `SELECT id, display_name FROM students`)
	if err != nil {
		t.Fatal(err)
	}
	defer rows.Close()
	got := map[string]string{}
	for rows.Next() {
		var id, name string
		if err := rows.Scan(&id, &name); err != nil {
			t.Fatal(err)
		}
		got[id] = name
	}
	for id, name := range want {
		if got[id] != name {
			t.Errorf("%s: display name %q, want %q", id, got[id], name)
		}
	}
	rows.Close()
	var duplicates int
	if err := db.QueryRow(ctx, `SELECT count(*) FROM (SELECT lower(display_name) FROM students GROUP BY 1 HAVING count(*) > 1) d`).Scan(&duplicates); err != nil || duplicates != 0 {
		t.Errorf("%d duplicate names remain (err=%v)", duplicates, err)
	}
}

func TestDisplayNamesAreUniqueIgnoringCase(t *testing.T) {
	db := testDatabase(t)
	ctx := context.Background()
	insert := func(id, name string) error {
		_, err := db.Exec(ctx, `INSERT INTO students (id, display_name) VALUES ($1, $2)`, id, name)
		return err
	}
	if err := insert("a1", "Ayu"); err != nil {
		t.Fatal(err)
	}
	err := insert("a2", "AYU")
	var pgErr *pgconn.PgError
	if !errors.As(err, &pgErr) || pgErr.ConstraintName != displayNameUniqueIndex {
		t.Fatalf("a name that differs only in letter case: error = %v, want a violation of %s", err, displayNameUniqueIndex)
	}
	if err := insert("a2", "Budi"); err != nil {
		t.Fatalf("a different name: %v", err)
	}
	if _, err := db.Exec(ctx, `UPDATE students SET display_name = 'budi' WHERE id = 'a2'`); err != nil {
		t.Errorf("a student changing the letter case of their own name: %v", err)
	}
	if _, err := db.Exec(ctx, `UPDATE students SET display_name = 'ayu' WHERE id = 'a2'`); err == nil {
		t.Error("renaming a student to another student's name in a different letter case was accepted")
	}
}
