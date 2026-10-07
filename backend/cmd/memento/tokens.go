package main

import (
	"context"
	"errors"
	"fmt"
	"log"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

var (
	errStudentDisabled = errors.New("this student account is disabled")
	errTokenState      = errors.New("could not verify the token")
)

// tokenState is what the database knows about a student's token.
type tokenState struct {
	version  int
	disabled bool
}

// tokenForVersion derives a student's token. Version 0 is the original
// derivation, so every token issued before versions existed stays valid.
// Version n above 0 mixes n into the derivation after a colon, which a student
// ID cannot contain, so no version of one student's token can equal another
// student's token.
func tokenForVersion(secret, student string, version int) string {
	if version == 0 {
		return tokenFor(secret, student)
	}
	return tokenFor(secret, fmt.Sprintf("%s:%d", student, version))
}

// lookupTokenState returns the stored token state of a student. Without a
// lookup, and for a student who is not registered, it is the default: version
// 0 and not disabled.
func lookupTokenState(ctx context.Context, cfg config, student string) (tokenState, error) {
	if cfg.studentState == nil {
		return tokenState{}, nil
	}
	state, err := cfg.studentState(ctx, student)
	if err != nil {
		log.Printf("token state: student=%s: %v", student, err)
		return tokenState{}, errTokenState
	}
	return state, nil
}

func studentTokenState(ctx context.Context, db *pgxpool.Pool, student string) (tokenState, error) {
	var state tokenState
	err := db.QueryRow(ctx, `SELECT token_version, disabled_at IS NOT NULL FROM students WHERE id = $1`, student).Scan(&state.version, &state.disabled)
	if errors.Is(err, pgx.ErrNoRows) {
		return tokenState{}, nil
	}
	return state, err
}

func databaseStudentState(db *pgxpool.Pool) func(context.Context, string) (tokenState, error) {
	return func(ctx context.Context, student string) (tokenState, error) {
		return studentTokenState(ctx, db, student)
	}
}

// rotateToken invalidates a student's current token and returns the new one.
func rotateToken(ctx context.Context, db *pgxpool.Pool, secret, student string) (string, error) {
	var version int
	err := db.QueryRow(ctx, `UPDATE students SET token_version = token_version + 1 WHERE id = $1 RETURNING token_version`, student).Scan(&version)
	if errors.Is(err, pgx.ErrNoRows) {
		return "", errStudentNotRegistered
	}
	if err != nil {
		return "", err
	}
	return tokenForVersion(secret, student, version), nil
}

// setStudentDisabled disables or re-enables a student. Disabling a student
// who is already disabled keeps the original time.
func setStudentDisabled(ctx context.Context, db *pgxpool.Pool, student string, disabled bool) error {
	query := `UPDATE students SET disabled_at = NULL WHERE id = $1`
	if disabled {
		query = `UPDATE students SET disabled_at = COALESCE(disabled_at, now()) WHERE id = $1`
	}
	result, err := db.Exec(ctx, query, student)
	if err != nil {
		return err
	}
	if result.RowsAffected() == 0 {
		return errStudentNotRegistered
	}
	return nil
}

func runRotateTokenCommand(ctx context.Context, db *pgxpool.Pool, secret string, args []string) error {
	if len(args) != 1 || !studentIDPattern.MatchString(args[0]) {
		return errors.New("usage: memento rotate-token STUDENT_ID")
	}
	token, err := rotateToken(ctx, db, secret, args[0])
	if err != nil {
		return err
	}
	fmt.Println(token)
	return nil
}

func runDisabledCommand(ctx context.Context, db *pgxpool.Pool, args []string, disable bool) error {
	name := "enable"
	if disable {
		name = "disable"
	}
	if len(args) != 1 || !studentIDPattern.MatchString(args[0]) {
		return fmt.Errorf("usage: memento %s STUDENT_ID", name)
	}
	return setStudentDisabled(ctx, db, args[0], disable)
}
