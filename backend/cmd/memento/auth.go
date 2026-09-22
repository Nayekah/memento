package main

import (
	"context"
	"crypto/hmac"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/hex"
	"errors"
	"net/http"

	"github.com/jackc/pgx/v5/pgxpool"
)

func tokenFor(secret, student string) string {
	mac := hmac.New(sha256.New, []byte(secret))
	_, _ = mac.Write([]byte(student))
	return hex.EncodeToString(mac.Sum(nil))
}

func authenticate(r *http.Request, cfg config) (string, error) {
	student := r.Header.Get("X-Memento-Student")
	if !studentIDPattern.MatchString(student) {
		return "", errors.New("invalid student identifier")
	}
	token := r.Header.Get("X-Memento-Token")
	if subtle.ConstantTimeCompare([]byte(token), []byte(tokenFor(cfg.secret, student))) != 1 {
		return "", errors.New("invalid submission token")
	}
	return student, nil
}

func activateVM(ctx context.Context, db *pgxpool.Pool, student, deviceID string) error {
	var registered bool
	if err := db.QueryRow(ctx, `SELECT EXISTS(SELECT 1 FROM students WHERE id = $1)`, student).Scan(&registered); err != nil {
		return err
	}
	if !registered {
		return errStudentNotRegistered
	}
	result, err := db.Exec(ctx, `
		INSERT INTO vm_activations (student_id, device_id)
		VALUES ($1, $2)
		ON CONFLICT (student_id) DO UPDATE SET last_seen_at = now()
		WHERE vm_activations.device_id = EXCLUDED.device_id`, student, deviceID)
	if err != nil {
		return err
	}
	if result.RowsAffected() == 0 {
		return errActivationBound
	}
	return nil
}
