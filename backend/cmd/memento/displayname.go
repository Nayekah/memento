package main

import (
	"context"
	"regexp"
	"strings"
	"unicode/utf8"

	"github.com/jackc/pgx/v5/pgxpool"
)

// maxDisplayNameRunes keeps scoreboard names short enough for one leaderboard row.
const maxDisplayNameRunes = 20

// displayNamePattern allows letters and digits from any script plus space, dot,
// underscore, and hyphen, and must start with a letter or digit.
var displayNamePattern = regexp.MustCompile(`^[\p{L}\p{N}][\p{L}\p{N} ._-]*$`)

// normalizeDisplayName trims and collapses whitespace, then enforces the length
// and character rules.
func normalizeDisplayName(raw string) (string, error) {
	name := strings.Join(strings.Fields(raw), " ")
	switch {
	case name == "":
		return "", errDisplayNameEmpty
	case utf8.RuneCountInString(name) > maxDisplayNameRunes:
		return "", errDisplayNameTooLong
	case !displayNamePattern.MatchString(name):
		return "", errDisplayNameInvalid
	}
	return name, nil
}

// setDisplayName changes a student's scoreboard name. Names are unique without
// regard to case and may not equal another student's ID, so nobody can pose as
// someone else on the leaderboard.
func setDisplayName(ctx context.Context, db *pgxpool.Pool, student, name string) error {
	tx, err := db.Begin(ctx)
	if err != nil {
		return err
	}
	defer func() { _ = tx.Rollback(ctx) }()
	if _, err := tx.Exec(ctx, `SELECT pg_advisory_xact_lock(hashtext(lower($1)))`, name); err != nil {
		return err
	}
	var taken bool
	if err := tx.QueryRow(ctx, `SELECT EXISTS(SELECT 1 FROM students WHERE (lower(display_name) = lower($1) OR lower(id) = lower($1)) AND id <> $2)`, name, student).Scan(&taken); err != nil {
		return err
	}
	if taken {
		return errDisplayNameTaken
	}
	result, err := tx.Exec(ctx, `UPDATE students SET display_name = $1 WHERE id = $2`, name, student)
	if err != nil {
		return err
	}
	if result.RowsAffected() == 0 {
		return errStudentNotRegistered
	}
	return tx.Commit(ctx)
}
