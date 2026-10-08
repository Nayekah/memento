package main

import (
	"context"
	"errors"
	"testing"
)

func TestStudentsStartAtTokenVersionZero(t *testing.T) {
	db := testDatabase(t)
	ctx := context.Background()
	addStudents(t, db, "alice")
	state, err := studentTokenState(ctx, db, "alice")
	if err != nil || state.version != 0 || state.disabled {
		t.Fatalf("a new student has state %+v (err=%v), want version 0 and enabled", state, err)
	}
	if state, err := studentTokenState(ctx, db, "ghost"); err != nil || state != (tokenState{}) {
		t.Errorf("an unregistered student has state %+v (err=%v), want the default", state, err)
	}
}

func TestRotateTokenChangesTheTokenVersion(t *testing.T) {
	db := testDatabase(t)
	ctx := context.Background()
	addStudents(t, db, "alice", "bob")

	first, err := rotateToken(ctx, db, testSecret, "alice")
	if err != nil || first != tokenForVersion(testSecret, "alice", 1) || first == tokenFor(testSecret, "alice") {
		t.Fatalf("first rotation = %q, %v; want the version 1 token", first, err)
	}
	second, err := rotateToken(ctx, db, testSecret, "alice")
	if err != nil || second != tokenForVersion(testSecret, "alice", 2) || second == first {
		t.Fatalf("second rotation = %q, %v; want the version 2 token", second, err)
	}
	if state, _ := studentTokenState(ctx, db, "alice"); state.version != 2 {
		t.Errorf("alice's version = %d, want 2", state.version)
	}
	if state, _ := studentTokenState(ctx, db, "bob"); state.version != 0 {
		t.Errorf("bob's version = %d after alice's rotations, want 0", state.version)
	}
	if _, err := rotateToken(ctx, db, testSecret, "ghost"); !errors.Is(err, errStudentNotRegistered) {
		t.Errorf("rotating an unregistered student: error = %v, want errStudentNotRegistered", err)
	}
	for _, args := range [][]string{{}, {"bad id"}, {"alice", "bob"}} {
		if err := runRotateTokenCommand(ctx, db, testSecret, args); err == nil {
			t.Errorf("rotate-token %v: expected a usage error", args)
		}
	}
}

func TestDisableAndEnableStudents(t *testing.T) {
	db := testDatabase(t)
	ctx := context.Background()
	addStudents(t, db, "alice", "bob")

	if err := setStudentDisabled(ctx, db, "alice", true); err != nil {
		t.Fatal(err)
	}
	if state, _ := studentTokenState(ctx, db, "alice"); !state.disabled {
		t.Error("alice is not disabled after disabling her")
	}
	if state, _ := studentTokenState(ctx, db, "bob"); state.disabled {
		t.Error("bob is disabled after alice was")
	}
	var firstDisabledAt, again string
	if err := db.QueryRow(ctx, `SELECT disabled_at::text FROM students WHERE id = 'alice'`).Scan(&firstDisabledAt); err != nil {
		t.Fatal(err)
	}
	if err := setStudentDisabled(ctx, db, "alice", true); err != nil {
		t.Fatal(err)
	}
	if err := db.QueryRow(ctx, `SELECT disabled_at::text FROM students WHERE id = 'alice'`).Scan(&again); err != nil || again != firstDisabledAt {
		t.Errorf("disabling twice moved the time from %s to %s (err=%v)", firstDisabledAt, again, err)
	}
	if err := setStudentDisabled(ctx, db, "alice", false); err != nil {
		t.Fatal(err)
	}
	if state, _ := studentTokenState(ctx, db, "alice"); state.disabled {
		t.Error("alice is still disabled after enabling her")
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
