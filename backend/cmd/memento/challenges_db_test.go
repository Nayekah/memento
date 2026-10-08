package main

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"reflect"
	"testing"

	"github.com/jackc/pgx/v5/pgxpool"
)

type challengeEntry struct {
	Rank       int               `json:"rank"`
	Name       string            `json:"name"`
	Score      int               `json:"score"`
	MaxScore   int               `json:"max_score"`
	Challenges []challengeResult `json:"challenges"`
}

func completedWithResult(t *testing.T, db *pgxpool.Pool, n int, student, practicum string, score int, result string) {
	t.Helper()
	_, err := db.Exec(context.Background(), `
		INSERT INTO submissions (id, student_id, source, source_sha256, status, score, max_score, result, completed_at, practicum)
		VALUES ($1, $2, 'x', repeat('0', 64), 'completed', $3, 100, $4::jsonb, '2026-01-01 10:00:00+00'::timestamptz + make_interval(mins => $5), $6)`,
		jobID(n), student, score, result, n, practicum)
	if err != nil {
		t.Fatalf("insert submission %d: %v", n, err)
	}
}

// leaderboardBody serves a board and returns the entries twice: typed, and as
// raw fields so a test can tell an absent key from an empty one.
func leaderboardBody(t *testing.T, handler http.HandlerFunc, practicum string) ([]challengeEntry, []map[string]json.RawMessage) {
	t.Helper()
	req := httptest.NewRequest(http.MethodGet, "/", nil)
	if practicum != "" {
		req.SetPathValue("practicum", practicum)
	}
	rec := httptest.NewRecorder()
	handler(rec, req)
	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d: %s", rec.Code, rec.Body.String())
	}
	var typed struct {
		Entries []challengeEntry `json:"entries"`
	}
	var raw struct {
		Entries []map[string]json.RawMessage `json:"entries"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &typed); err != nil {
		t.Fatalf("decode %s: %v", rec.Body.String(), err)
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &raw); err != nil {
		t.Fatalf("decode %s: %v", rec.Body.String(), err)
	}
	return typed.Entries, raw.Entries
}

func TestLeaderboardReturnsTheChallengesOfTheBestSubmission(t *testing.T) {
	db := testDatabase(t)
	addStudents(t, db, "a", "b", "c", "d", "e")
	graded, err := json.Marshal(resultFromOutput(fixture(t, "driver-mixed.txt")))
	if err != nil {
		t.Fatal(err)
	}

	completedWithResult(t, db, 1, "a", "datalab", 50, `{"challenges":[{"name":"older","points":1,"max":3}]}`)
	completedWithResult(t, db, 2, "a", "datalab", 90, string(graded)) // the better one is the one shown
	completedWithResult(t, db, 3, "b", "datalab", 70, `{"log":"graded before the breakdown existed"}`)
	completedWithResult(t, db, 4, "c", "datalab", 60, `{"challenges":null}`)
	completedWithResult(t, db, 5, "d", "datalab", 50, `{"challenges":"unreadable"}`)
	completedWithResult(t, db, 6, "e", "datalab", 40, `{"challenges":[{"name":"x","points":"many"}]}`)

	entries, raw := leaderboardBody(t, func(w http.ResponseWriter, r *http.Request) { serveLeaderboard(w, r, db) }, "")

	if got := len(entries); got != 5 {
		t.Fatalf("got %d entries, want 5", got)
	}
	for i, want := range []struct {
		name  string
		score int
	}{{"a", 90}, {"b", 70}, {"c", 60}, {"d", 50}, {"e", 40}} {
		if e := entries[i]; e.Rank != i+1 || e.Name != want.name || e.Score != want.score || e.MaxScore != 100 {
			t.Errorf("entry %d = %+v, want rank %d, %s, score %d of 100", i, e, i+1, want.name, want.score)
		}
	}

	wantChallenges := parseChallenges(fixture(t, "driver-mixed.txt"))
	if len(wantChallenges) != 15 || !reflect.DeepEqual(entries[0].Challenges, wantChallenges) {
		t.Errorf("a's challenges = %+v\nwant           %+v", entries[0].Challenges, wantChallenges)
	}
	// Anything else leaves the key out, so older clients see the shape they know.
	for i := 1; i < 5; i++ {
		if _, present := raw[i]["challenges"]; present {
			t.Errorf("entry %d has a challenges key: %s", i, raw[i]["challenges"])
		}
	}
}

func TestPracticumLeaderboardReturnsItsOwnChallenges(t *testing.T) {
	db := testDatabase(t)
	addStudents(t, db, "a", "b")
	completedWithResult(t, db, 1, "a", "datalab", 80, `{"challenges":[{"name":"p","points":3,"max":3}]}`)
	completedWithResult(t, db, 2, "b", "bomblab", 60, `{"challenges":[{"name":"phase_1","points":10,"max":10},{"name":"phase_2","points":0,"max":10}]}`)

	entries, _ := leaderboardBody(t, practicumLeaderboardHandler(db), "bomblab")

	want := []challengeEntry{{1, "b", 60, 100, []challengeResult{{"phase_1", 10, 10}, {"phase_2", 0, 10}}}}
	if !reflect.DeepEqual(entries, want) {
		t.Fatalf("entries = %+v\nwant     %+v", entries, want)
	}
}
