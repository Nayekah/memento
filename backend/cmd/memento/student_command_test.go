package main

import (
	"context"
	"errors"
	"testing"
)

func TestStudentCommandRefusesADisplayNameAnotherStudentHas(t *testing.T) {
	db := testDatabase(t)
	ctx := context.Background()
	if err := runStudentCommand(ctx, db, []string{"alice", "Ayu"}); err != nil {
		t.Fatal(err)
	}
	if err := runStudentCommand(ctx, db, []string{"bob", "ayu"}); !errors.Is(err, errDisplayNameInUse) {
		t.Errorf("a name another student has, in a different letter case: error = %v, want errDisplayNameInUse", err)
	}
	var bobs int
	if err := db.QueryRow(ctx, `SELECT count(*) FROM students WHERE id = 'bob'`).Scan(&bobs); err != nil || bobs != 0 {
		t.Errorf("the refused student was created anyway (count=%d, err=%v)", bobs, err)
	}
	if err := runStudentCommand(ctx, db, []string{"alice", "AYU"}); err != nil {
		t.Errorf("a student changing the letter case of their own name: %v", err)
	}
	if err := runStudentCommand(ctx, db, []string{"Ayu"}); !errors.Is(err, errDisplayNameInUse) {
		t.Errorf("a student ID that equals another student's name: error = %v, want errDisplayNameInUse", err)
	}
	if err := runStudentCommand(ctx, db, []string{"carol"}); err != nil {
		t.Errorf("a student whose default name is free: %v", err)
	}
}

func TestMapDisplayNameConflictPassesOtherErrorsThrough(t *testing.T) {
	other := errors.New("connection reset")
	if got := mapDisplayNameConflict(other); got != other {
		t.Errorf("mapDisplayNameConflict(other) = %v, want the same error", got)
	}
	if got := mapDisplayNameConflict(nil); got != nil {
		t.Errorf("mapDisplayNameConflict(nil) = %v, want nil", got)
	}
}
