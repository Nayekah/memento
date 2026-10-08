package main

import (
	"context"
	"errors"
	"strings"
	"testing"
)

func TestActivateVMBindsOneDevicePerStudent(t *testing.T) {
	db := testDatabase(t)
	ctx := context.Background()
	addStudents(t, db, "alice")
	first, second := strings.Repeat("a", 32), strings.Repeat("b", 32)

	if err := activateVM(ctx, db, "alice", first); err != nil {
		t.Fatalf("first activation: %v", err)
	}
	if err := activateVM(ctx, db, "alice", first); err != nil {
		t.Errorf("activating the same device again: %v", err)
	}
	if err := activateVM(ctx, db, "alice", second); !errors.Is(err, errActivationBound) {
		t.Errorf("a second device: error = %v, want errActivationBound", err)
	}
	if err := activateVM(ctx, db, "ghost", first); !errors.Is(err, errStudentNotRegistered) {
		t.Errorf("an unregistered student: error = %v, want errStudentNotRegistered", err)
	}
	if err := runResetActivationCommand(ctx, db, []string{"alice"}); err != nil {
		t.Fatalf("reset activation: %v", err)
	}
	if err := activateVM(ctx, db, "alice", second); err != nil {
		t.Errorf("activating a new device after a reset: %v", err)
	}
}
