package main

import (
	"context"
	"errors"
	"strings"

	"github.com/jackc/pgx/v5/pgxpool"
)

func runStudentCommand(ctx context.Context, db *pgxpool.Pool, args []string) error {
	if len(args) < 1 || !studentIDPattern.MatchString(args[0]) {
		return errors.New("usage: memento student STUDENT_ID [DISPLAY_NAME]")
	}
	name := args[0]
	if len(args) > 1 {
		name = strings.Join(args[1:], " ")
	}
	_, err := db.Exec(ctx, `INSERT INTO students (id, display_name) VALUES ($1, $2) ON CONFLICT (id) DO UPDATE SET display_name = EXCLUDED.display_name`, args[0], name)
	return err
}

func runResetActivationCommand(ctx context.Context, db *pgxpool.Pool, args []string) error {
	if len(args) != 1 || !studentIDPattern.MatchString(args[0]) {
		return errors.New("usage: memento reset-activation STUDENT_ID")
	}
	_, err := db.Exec(ctx, `DELETE FROM vm_activations WHERE student_id = $1`, args[0])
	return err
}

func runRegradeCommand(ctx context.Context, db *pgxpool.Pool, args []string) error {
	if len(args) != 1 || !jobIDPattern.MatchString(args[0]) {
		return errors.New("usage: memento regrade SUBMISSION_ID")
	}
	result, err := db.Exec(ctx, `UPDATE submissions SET status = 'queued', result = NULL, error = NULL, score = NULL, max_score = NULL, claimed_at = NULL, completed_at = NULL, updated_at = now() WHERE id = $1 AND status IN ('completed', 'failed')`, args[0])
	if err != nil {
		return err
	}
	if result.RowsAffected() == 0 {
		return errors.New("submission is not available for regrade")
	}
	return nil
}
