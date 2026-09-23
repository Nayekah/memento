package main

import (
	"context"
	"crypto/hmac"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/base32"
	"errors"
	"net/http"
	"strings"

	"github.com/jackc/pgx/v5/pgxpool"
)

func tokenFor(secret, student string) string {
	mac := hmac.New(sha256.New, []byte(secret))
	_, _ = mac.Write([]byte(student))
	compact := base32.StdEncoding.WithPadding(base32.NoPadding).EncodeToString(mac.Sum(nil)[:8])[:12]
	return compact[:4] + "-" + compact[4:8] + "-" + compact[8:]
}

func normalizeToken(token string) string {
	return strings.ToUpper(strings.ReplaceAll(token, "-", ""))
}

func authenticate(r *http.Request, cfg config) (string, error) {
	student := r.Header.Get("X-Memento-Student")
	if !studentIDPattern.MatchString(student) {
		return "", errors.New("invalid student identifier")
	}
	token := normalizeToken(r.Header.Get("X-Memento-Token"))
	expected := normalizeToken(tokenFor(cfg.secret, student))
	if subtle.ConstantTimeCompare([]byte(token), []byte(expected)) != 1 {
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
