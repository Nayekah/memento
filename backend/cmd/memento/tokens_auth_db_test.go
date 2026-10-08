package main

import (
	"context"
	"errors"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/jackc/pgx/v5/pgxpool"
)

func tokenRequest(student, token string) *http.Request {
	r := httptest.NewRequest(http.MethodGet, "/", nil)
	r.Header.Set("X-Memento-Student", student)
	r.Header.Set("X-Memento-Token", token)
	return r
}

func withStateFrom(db *pgxpool.Pool) config {
	return config{secret: testSecret, studentState: databaseStudentState(db)}
}

func TestTokensIssuedBeforeVersionsExistedKeepWorking(t *testing.T) {
	db := testDatabase(t)
	addStudents(t, db, "alice")
	if got, err := authenticate(tokenRequest("alice", tokenFor(testSecret, "alice")), withStateFrom(db)); err != nil || got != "alice" {
		t.Errorf("the original token: %q, %v; want it accepted", got, err)
	}
}

func TestRotateTokenInvalidatesOnlyThatStudentsToken(t *testing.T) {
	db := testDatabase(t)
	ctx := context.Background()
	addStudents(t, db, "alice", "bob")
	cfg := withStateFrom(db)
	first := tokenFor(testSecret, "alice")

	second, err := rotateToken(ctx, db, testSecret, "alice")
	if err != nil || second == first || second != tokenForVersion(testSecret, "alice", 1) {
		t.Fatalf("rotateToken = %q, %v; want a new version 1 token different from %q", second, err, first)
	}
	if _, err := authenticate(tokenRequest("alice", first), cfg); err == nil || !strings.Contains(err.Error(), "invalid submission token") {
		t.Errorf("the old token after rotation: error = %v, want invalid submission token", err)
	}
	if got, err := authenticate(tokenRequest("alice", second), cfg); err != nil || got != "alice" {
		t.Errorf("the new token: %q, %v; want it accepted", got, err)
	}
	if _, err := authenticate(tokenRequest("bob", tokenFor(testSecret, "bob")), cfg); err != nil {
		t.Errorf("another student's token after alice's rotation: %v", err)
	}

	third, err := rotateToken(ctx, db, testSecret, "alice")
	if err != nil || third == second || third == first {
		t.Fatalf("second rotation = %q, %v; want a token different from both earlier ones", third, err)
	}
	if _, err := authenticate(tokenRequest("alice", second), cfg); err == nil {
		t.Error("the version 1 token still works after the second rotation")
	}
	if state, err := studentTokenState(ctx, db, "alice"); err != nil || state.version != 2 {
		t.Errorf("token state = %+v, %v; want version 2", state, err)
	}
	if _, err := rotateToken(ctx, db, testSecret, "ghost"); !errors.Is(err, errStudentNotRegistered) {
		t.Errorf("rotating an unregistered student: error = %v, want errStudentNotRegistered", err)
	}
}

func TestDisabledStudentIsRefused(t *testing.T) {
	db := testDatabase(t)
	ctx := context.Background()
	addStudents(t, db, "alice", "bob")
	cfg := withStateFrom(db)
	alice, bob := tokenFor(testSecret, "alice"), tokenFor(testSecret, "bob")

	if err := setStudentDisabled(ctx, db, "alice", true); err != nil {
		t.Fatal(err)
	}
	if _, err := authenticate(tokenRequest("alice", alice), cfg); !errors.Is(err, errStudentDisabled) {
		t.Errorf("a disabled student with a valid token: error = %v, want errStudentDisabled", err)
	}
	if _, err := authenticate(tokenRequest("alice", "AAAA-AAAA-AAAA"), cfg); err == nil || errors.Is(err, errStudentDisabled) {
		t.Errorf("a wrong token for a disabled student: error = %v, want the invalid token error so the status is not revealed", err)
	}
	if _, err := authenticate(tokenRequest("bob", bob), cfg); err != nil {
		t.Errorf("another student while alice is disabled: %v", err)
	}

	var firstDisabledAt string
	if err := db.QueryRow(ctx, `SELECT disabled_at::text FROM students WHERE id = 'alice'`).Scan(&firstDisabledAt); err != nil {
		t.Fatal(err)
	}
	if err := setStudentDisabled(ctx, db, "alice", true); err != nil {
		t.Fatal(err)
	}
	var again string
	if err := db.QueryRow(ctx, `SELECT disabled_at::text FROM students WHERE id = 'alice'`).Scan(&again); err != nil || again != firstDisabledAt {
		t.Errorf("disabling twice moved the time from %s to %s (err=%v)", firstDisabledAt, again, err)
	}

	rotated, err := rotateToken(ctx, db, testSecret, "alice")
	if err != nil {
		t.Fatal(err)
	}
	if _, err := authenticate(tokenRequest("alice", rotated), cfg); !errors.Is(err, errStudentDisabled) {
		t.Errorf("a rotated token while disabled: error = %v, want errStudentDisabled", err)
	}
	if err := setStudentDisabled(ctx, db, "alice", false); err != nil {
		t.Fatal(err)
	}
	if got, err := authenticate(tokenRequest("alice", rotated), cfg); err != nil || got != "alice" {
		t.Errorf("after enabling: %q, %v; want the rotated token accepted", got, err)
	}
	for _, disable := range []bool{true, false} {
		if err := setStudentDisabled(ctx, db, "ghost", disable); !errors.Is(err, errStudentNotRegistered) {
			t.Errorf("setStudentDisabled(ghost, %v): error = %v, want errStudentNotRegistered", disable, err)
		}
	}
	for _, args := range [][]string{{}, {"bad id"}, {"alice", "bob"}} {
		if err := runDisabledCommand(ctx, db, args, true); err == nil {
			t.Errorf("disable %v: expected a usage error", args)
		}
	}
}

func TestUnregisteredStudentsAreStillAuthenticatedByTheDerivation(t *testing.T) {
	db := testDatabase(t)
	// Handlers answer 403 for these students after authentication; that must not change.
	if got, err := authenticate(tokenRequest("ghost", tokenFor(testSecret, "ghost")), withStateFrom(db)); err != nil || got != "ghost" {
		t.Errorf("an unregistered student with the derived token: %q, %v; want it authenticated", got, err)
	}
}

func TestTokenStateLookupFailureRefusesTheRequest(t *testing.T) {
	failing := config{secret: testSecret, studentState: func(context.Context, string) (tokenState, error) {
		return tokenState{}, errors.New("database unavailable")
	}}
	var err error
	logged := capturedLog(func() { _, err = authenticate(tokenRequest("alice", tokenFor(testSecret, "alice")), failing) })
	if !errors.Is(err, errTokenState) || !strings.Contains(logged, "database unavailable") {
		t.Errorf("a failing lookup: error = %v, log = %q; want errTokenState and the failure logged", err, logged)
	}
}
