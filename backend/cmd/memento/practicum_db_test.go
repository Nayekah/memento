package main

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"reflect"
	"regexp"
	"testing"

	"github.com/jackc/pgx/v5/pgxpool"
)

func TestPracticumRegistryHoldsValidIDs(t *testing.T) {
	valid := regexp.MustCompile(`^[a-z][a-z0-9-]{0,31}$`) // the database constraint
	seen := map[string]bool{}
	for _, id := range practicumIDs {
		if !valid.MatchString(id) {
			t.Errorf("%q would be rejected by the practicum column", id)
		}
		if seen[id] {
			t.Errorf("%q is listed twice", id)
		}
		seen[id] = true
	}
	if !knownPracticum(defaultPracticum) {
		t.Errorf("the default practicum %q is not in the registry", defaultPracticum)
	}
}

func completedIn(t *testing.T, db *pgxpool.Pool, n int, student, practicum string, score int) {
	t.Helper()
	_, err := db.Exec(context.Background(), `
		INSERT INTO submissions (id, student_id, source, source_sha256, status, score, max_score, completed_at, practicum)
		VALUES ($1, $2, 'x', repeat('0', 64), 'completed', $3, 100, '2026-01-01 10:00:00+00'::timestamptz + make_interval(mins => $4), $5)`,
		jobID(n), student, score, n, practicum)
	if err != nil {
		t.Fatalf("insert submission %d: %v", n, err)
	}
}

func fetchBoard(t *testing.T, handler http.HandlerFunc, practicum string) (int, []leaderboardEntry) {
	t.Helper()
	req := httptest.NewRequest(http.MethodGet, "/", nil)
	req.SetPathValue("practicum", practicum)
	rec := httptest.NewRecorder()
	handler(rec, req)
	var body struct {
		Entries []leaderboardEntry `json:"entries"`
	}
	if rec.Code == http.StatusOK {
		if err := json.Unmarshal(rec.Body.Bytes(), &body); err != nil {
			t.Fatalf("decode %s: %v", rec.Body.String(), err)
		}
	}
	return rec.Code, body.Entries
}

func TestLeaderboardIsPerPracticum(t *testing.T) {
	db := testDatabase(t)
	ctx := context.Background()
	for _, s := range [][2]string{{"a", "Ayu"}, {"b", "Budi"}, {"c", "Citra"}} {
		if _, err := db.Exec(ctx, `INSERT INTO students (id, display_name) VALUES ($1, $2)`, s[0], s[1]); err != nil {
			t.Fatal(err)
		}
	}
	completedIn(t, db, 1, "a", "datalab", 90)
	completedIn(t, db, 2, "a", "bomblab", 40)
	completedIn(t, db, 3, "b", "datalab", 70)
	completedIn(t, db, 4, "c", "bomblab", 60)
	handler := practicumLeaderboardHandler(db)

	wantDatalab := []leaderboardEntry{{1, "Ayu", 90, 100}, {2, "Budi", 70, 100}}
	wantBomblab := []leaderboardEntry{{1, "Citra", 60, 100}, {2, "Ayu", 40, 100}}
	if code, got := fetchBoard(t, handler, "datalab"); code != http.StatusOK || !reflect.DeepEqual(got, wantDatalab) {
		t.Errorf("datalab: status %d entries %+v, want 200 and %+v", code, got, wantDatalab)
	}
	if code, got := fetchBoard(t, handler, "bomblab"); code != http.StatusOK || !reflect.DeepEqual(got, wantBomblab) {
		t.Errorf("bomblab: status %d entries %+v, want 200 and %+v", code, got, wantBomblab)
	}
	// /api/v1/leaderboard stays the Data Lab board.
	if code, got := fetchBoard(t, func(w http.ResponseWriter, r *http.Request) { serveLeaderboard(w, r, db) }, ""); code != http.StatusOK || !reflect.DeepEqual(got, wantDatalab) {
		t.Errorf("/api/v1/leaderboard: status %d entries %+v, want the Data Lab board %+v", code, got, wantDatalab)
	}
}

func TestEmptyPracticumHasAnEmptyBoardAndUnknownOnesAreNotFound(t *testing.T) {
	db := testDatabase(t)
	handler := practicumLeaderboardHandler(db)

	req := httptest.NewRequest(http.MethodGet, "/", nil)
	req.SetPathValue("practicum", "bomblab")
	rec := httptest.NewRecorder()
	handler(rec, req)
	if rec.Code != http.StatusOK || rec.Body.String() != "{\"entries\":[]}\n" {
		t.Errorf("a known practicum with no scores: status %d body %q, want 200 and an empty list", rec.Code, rec.Body.String())
	}
	for _, id := range []string{"nope", "", "DATALAB", "datalab/extra", "../datalab", "bomb lab"} {
		code, _ := fetchBoard(t, handler, id)
		if code != http.StatusNotFound {
			t.Errorf("practicum %q: status %d, want 404", id, code)
		}
	}
}
