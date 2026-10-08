package main

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"reflect"
	"testing"
)

type leaderboardEntry struct {
	Rank     int    `json:"rank"`
	Name     string `json:"name"`
	Score    int    `json:"score"`
	MaxScore int    `json:"max_score"`
}

func TestLeaderboardUsesTheBestCompletedScore(t *testing.T) {
	db := testDatabase(t)
	ctx := context.Background()
	for _, student := range [][2]string{{"a", "Ayu"}, {"b", "Budi"}, {"c", "Citra"}, {"d", "Dewi"}, {"e", "Eko"}, {"f", "Fajar"}} {
		if _, err := db.Exec(ctx, `INSERT INTO students (id, display_name) VALUES ($1, $2)`, student[0], student[1]); err != nil {
			t.Fatal(err)
		}
	}
	// id, student, status, score, completed_at
	rows := [][5]any{
		{jobID(1), "a", "completed", 50, "2026-01-01 09:00:00+00"},
		{jobID(2), "a", "completed", 90, "2026-01-01 10:00:00+00"}, // Ayu's best
		{jobID(3), "b", "completed", 90, "2026-01-01 11:00:00+00"}, // same score, later
		{jobID(4), "c", "completed", 70, "2026-01-01 12:00:00+00"},
		{jobID(5), "d", "completed", 70, "2026-01-01 12:00:00+00"}, // exact tie with Citra
		{jobID(6), "e", "failed", nil, nil},                        // never completed
		{jobID(7), "f", "queued", nil, nil},                        // still waiting
	}
	for _, r := range rows {
		_, err := db.Exec(ctx, `
			INSERT INTO submissions (id, student_id, source, source_sha256, status, score, max_score, completed_at)
			VALUES ($1, $2, 'x', repeat('0', 64), $3, $4::int, CASE WHEN $4::int IS NULL THEN NULL ELSE 100 END, $5::timestamptz)`,
			r[0], r[1], r[2], r[3], r[4])
		if err != nil {
			t.Fatalf("insert %v: %v", r[0], err)
		}
	}

	rec := httptest.NewRecorder()
	serveLeaderboard(rec, httptest.NewRequest(http.MethodGet, "/api/v1/leaderboard", nil), db)
	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d: %s", rec.Code, rec.Body.String())
	}
	var body struct {
		Entries []leaderboardEntry `json:"entries"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &body); err != nil {
		t.Fatalf("decode: %v", err)
	}
	want := []leaderboardEntry{
		{1, "Ayu", 90, 100},
		{2, "Budi", 90, 100}, // the earlier completion wins an equal score
		{3, "Citra", 70, 100},
		{3, "Dewi", 70, 100}, // an identical score and time share a rank
	}
	if !reflect.DeepEqual(body.Entries, want) {
		t.Fatalf("entries = %+v\nwant     %+v", body.Entries, want)
	}
}

func TestLeaderboardIsEmptyWithoutCompletedSubmissions(t *testing.T) {
	db := testDatabase(t)
	rec := httptest.NewRecorder()
	serveLeaderboard(rec, httptest.NewRequest(http.MethodGet, "/api/v1/leaderboard", nil), db)
	if rec.Code != http.StatusOK || rec.Body.String() != "{\"entries\":[]}\n" {
		t.Fatalf("status = %d body = %q, want 200 and an empty entries list", rec.Code, rec.Body.String())
	}
}
