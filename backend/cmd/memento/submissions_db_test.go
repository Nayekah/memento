package main

import (
	"bytes"
	"context"
	"errors"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"

	"github.com/jackc/pgx/v5"
)

const testSecret = "unit-test-secret-0123456789abcdef"

func TestSubmissionOwnership(t *testing.T) {
	db := testDatabase(t)
	addStudents(t, db, "alice", "bob")
	cfg := config{secret: testSecret}
	owned := newSubmission(t, db, cfg, "alice")

	read := func(student, token, id string) (bool, int) {
		req := httptest.NewRequest(http.MethodGet, "/api/v1/submissions/"+id, nil)
		req.SetPathValue("id", id)
		req.Header.Set("X-Memento-Student", student)
		req.Header.Set("X-Memento-Token", token)
		rec := httptest.NewRecorder()
		_, ok := submissionForRequest(rec, req, cfg, db)
		return ok, rec.Code
	}
	alice, bob := tokenFor(testSecret, "alice"), tokenFor(testSecret, "bob")
	cases := []struct {
		name     string
		student  string
		token    string
		id       string
		wantOK   bool
		wantCode int
	}{
		{"the owner can read it", "alice", alice, owned.ID, true, http.StatusOK},
		{"another student with a valid token gets not found", "bob", bob, owned.ID, false, http.StatusNotFound},
		{"the owner's ID with another student's token is unauthorized", "alice", bob, owned.ID, false, http.StatusUnauthorized},
		{"a missing token is unauthorized", "alice", "", owned.ID, false, http.StatusUnauthorized},
		{"a malformed ID is not found", "alice", alice, "../etc/passwd", false, http.StatusNotFound},
	}
	for _, c := range cases {
		if ok, code := read(c.student, c.token, c.id); ok != c.wantOK || code != c.wantCode {
			t.Errorf("%s: got ok=%v status=%d, want ok=%v status=%d", c.name, ok, code, c.wantOK, c.wantCode)
		}
	}
	if _, err := getSubmission(context.Background(), db, owned.ID, "bob"); !errors.Is(err, pgx.ErrNoRows) {
		t.Errorf("getSubmission for another student = %v, want pgx.ErrNoRows", err)
	}
}

func TestSubmissionRequiresARegisteredStudent(t *testing.T) {
	db := testDatabase(t)
	_, err := createSubmission(context.Background(), db, config{}, "ghost", strings.NewReader("int x;"))
	if !errors.Is(err, errStudentNotRegistered) {
		t.Fatalf("error = %v, want errStudentNotRegistered", err)
	}
}

func TestSourceSizeLimit(t *testing.T) {
	db := testDatabase(t)
	ctx := context.Background()
	addStudents(t, db, "alice")
	if _, err := createSubmission(ctx, db, config{}, "alice", bytes.NewReader(make([]byte, maxSourceBytes))); err != nil {
		t.Errorf("a source of exactly %d bytes was refused: %v", maxSourceBytes, err)
	}
	if _, err := createSubmission(ctx, db, config{}, "alice", bytes.NewReader(make([]byte, maxSourceBytes+1))); !errors.Is(err, errSourceTooLarge) {
		t.Errorf("a source one byte over the limit: error = %v, want errSourceTooLarge", err)
	}
}

func TestSubmissionRateLimitIsPerStudent(t *testing.T) {
	db := testDatabase(t)
	ctx := context.Background()
	addStudents(t, db, "alice", "bob")
	limited := config{submissionRatePerMinute: 3}
	for range 3 {
		newSubmission(t, db, limited, "alice")
	}
	if _, err := createSubmission(ctx, db, limited, "alice", strings.NewReader("int x;")); !errors.Is(err, errSubmissionRateLimited) {
		t.Errorf("the fourth submission in a minute: error = %v, want errSubmissionRateLimited", err)
	}
	newSubmission(t, db, limited, "bob")
	newSubmission(t, db, config{}, "alice") // a limit of 0 disables the check
}

func TestSubmissionRateLimitHoldsUnderConcurrency(t *testing.T) {
	db := testDatabase(t)
	ctx := context.Background()
	addStudents(t, db, "alice")
	limited := config{submissionRatePerMinute: 3}
	const attempts = 12
	var mu sync.Mutex
	accepted, refused := 0, 0
	var wg sync.WaitGroup
	for range attempts {
		wg.Add(1)
		go func() {
			defer wg.Done()
			_, err := createSubmission(ctx, db, limited, "alice", strings.NewReader("int x;"))
			mu.Lock()
			defer mu.Unlock()
			switch {
			case err == nil:
				accepted++
			case errors.Is(err, errSubmissionRateLimited):
				refused++
			default:
				t.Errorf("unexpected error: %v", err)
			}
		}()
	}
	wg.Wait()
	if accepted != 3 || refused != attempts-3 {
		t.Fatalf("accepted %d and refused %d of %d concurrent submissions, want 3 and %d", accepted, refused, attempts, attempts-3)
	}
}
