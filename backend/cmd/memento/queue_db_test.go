package main

import (
	"context"
	"errors"
	"fmt"
	"strings"
	"sync"
	"testing"

	"github.com/jackc/pgx/v5/pgxpool"
)

// insertRaw stores a submission with chosen ages, bypassing createSubmission.
// claimedAgo is a PostgreSQL interval such as "6 minutes", or empty for never.
func insertRaw(t *testing.T, db *pgxpool.Pool, id, student, status, createdAgo, claimedAgo string) {
	t.Helper()
	_, err := db.Exec(context.Background(), `
		INSERT INTO submissions (id, student_id, source, source_sha256, status, created_at, claimed_at, attempt_count)
		VALUES ($1, $2, 'x', repeat('0', 64), $3, now() - $4::text::interval,
		        CASE WHEN $5::text = '' THEN NULL ELSE now() - $5::text::interval END,
		        CASE WHEN $3 = 'processing' THEN 1 ELSE 0 END)`,
		id, student, status, createdAgo, claimedAgo)
	if err != nil {
		t.Fatalf("insert submission %s: %v", id, err)
	}
}

func TestClaimSubmissionIsExclusive(t *testing.T) {
	db := testDatabase(t)
	ctx := context.Background()
	addStudents(t, db, "s1", "s2", "s3", "s4", "s5", "s6")
	const total = 30
	queued := map[string]bool{}
	for i := range total {
		queued[newSubmission(t, db, config{}, fmt.Sprintf("s%d", i%6+1)).ID] = true
	}

	var mu sync.Mutex
	claims := map[string]int{}
	var wg sync.WaitGroup
	for range 8 {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for {
				job, err := claimSubmission(ctx, db)
				if err != nil {
					t.Errorf("claim: %v", err)
					return
				}
				if job == nil {
					return
				}
				mu.Lock()
				claims[job.ID]++
				mu.Unlock()
			}
		}()
	}
	wg.Wait()

	if len(claims) != total {
		t.Fatalf("%d submissions were claimed, want %d", len(claims), total)
	}
	for id, count := range claims {
		if count != 1 || !queued[id] {
			t.Errorf("submission %s claimed %d times (known=%v), want once", id, count, queued[id])
		}
	}
	var processing, attempts int
	if err := db.QueryRow(ctx, `SELECT count(*) FILTER (WHERE status = 'processing'), COALESCE(sum(attempt_count), 0) FROM submissions`).Scan(&processing, &attempts); err != nil {
		t.Fatal(err)
	}
	if processing != total || attempts != total {
		t.Errorf("processing=%d attempts=%d, want %d and %d", processing, attempts, total, total)
	}
}

func TestClaimPrefersAStudentWithoutAJobInProgress(t *testing.T) {
	db := testDatabase(t)
	ctx := context.Background()
	addStudents(t, db, "alice", "bob")
	insertRaw(t, db, jobID(1), "alice", "processing", "30 minutes", "1 minute")
	insertRaw(t, db, jobID(2), "alice", "queued", "20 minutes", "")
	insertRaw(t, db, jobID(3), "bob", "queued", "10 minutes", "")

	first, err := claimSubmission(ctx, db)
	if err != nil || first == nil || first.ID != jobID(3) {
		t.Fatalf("first claim = %+v, %v; want bob's submission %s even though alice's is older", first, err, jobID(3))
	}
	second, err := claimSubmission(ctx, db)
	if err != nil || second == nil || second.ID != jobID(2) {
		t.Fatalf("second claim = %+v, %v; want alice's submission %s", second, err, jobID(2))
	}
	if third, err := claimSubmission(ctx, db); err != nil || third != nil {
		t.Fatalf("third claim = %+v, %v; want nothing left", third, err)
	}
}

func TestStaleProcessingSubmissionIsReclaimed(t *testing.T) {
	db := testDatabase(t)
	ctx := context.Background()
	addStudents(t, db, "alice", "bob")
	insertRaw(t, db, jobID(1), "alice", "processing", "20 minutes", "6 minutes")
	insertRaw(t, db, jobID(2), "bob", "processing", "20 minutes", "1 minute")

	job, err := claimSubmission(ctx, db)
	if err != nil || job == nil || job.ID != jobID(1) {
		t.Fatalf("claim = %+v, %v; want the stale submission %s", job, err, jobID(1))
	}
	var attempts int
	if err := db.QueryRow(ctx, `SELECT attempt_count FROM submissions WHERE id = $1`, jobID(1)).Scan(&attempts); err != nil || attempts != 2 {
		t.Errorf("attempt_count = %d (err=%v), want 2 after the reclaim", attempts, err)
	}
	if again, err := claimSubmission(ctx, db); err != nil || again != nil {
		t.Fatalf("a submission that is still being graded was claimed: %+v, %v", again, err)
	}
}

func TestCompleteSubmissionRecordsScoreAndFailure(t *testing.T) {
	db := testDatabase(t)
	ctx := context.Background()
	addStudents(t, db, "alice", "bob")
	newSubmission(t, db, config{}, "alice")
	newSubmission(t, db, config{}, "bob")
	graded, err := claimSubmission(ctx, db)
	if err != nil || graded == nil {
		t.Fatalf("claim: %+v, %v", graded, err)
	}
	failed, err := claimSubmission(ctx, db)
	if err != nil || failed == nil {
		t.Fatalf("claim: %+v, %v", failed, err)
	}

	if err := completeSubmission(ctx, db, graded, map[string]any{"score": "65/71", "log": "ok"}, nil); err != nil {
		t.Fatal(err)
	}
	if err := completeSubmission(ctx, db, failed, nil, errors.New("grader exceeded its 60 second limit")); err != nil {
		t.Fatal(err)
	}
	// A second completion must not rewrite a finished submission.
	if err := completeSubmission(ctx, db, graded, map[string]any{"score": "1/71"}, nil); err != nil {
		t.Fatal(err)
	}

	var status string
	var score, maxScore *int
	if err := db.QueryRow(ctx, `SELECT status, score, max_score FROM submissions WHERE id = $1`, graded.ID).Scan(&status, &score, &maxScore); err != nil {
		t.Fatal(err)
	}
	if status != "completed" || score == nil || maxScore == nil || *score != 65 || *maxScore != 71 {
		t.Errorf("graded submission = %s %v/%v, want completed 65/71", status, score, maxScore)
	}
	var message string
	if err := db.QueryRow(ctx, `SELECT status, COALESCE(error, '') FROM submissions WHERE id = $1`, failed.ID).Scan(&status, &message); err != nil {
		t.Fatal(err)
	}
	if status != "failed" || !strings.Contains(message, "60 second limit") {
		t.Errorf("failed submission = %s %q, want failed with the grader error", status, message)
	}
}
