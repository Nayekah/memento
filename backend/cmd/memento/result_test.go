package main

import (
	"encoding/json"
	"reflect"
	"testing"
)

func TestResultFromOutputKeepsTheLogScoreAndAutoresult(t *testing.T) {
	text := "some output\n\nScore = 12/71 [6/41 Corr + 6/30 Perf] (17 total operators)\nAUTORESULT_STRING=12|6|6|17\n"
	want := map[string]any{
		"log":        text,
		"score":      "12/71 [6/41 Corr + 6/30 Perf] (17 total operators)",
		"autoresult": "12|6|6|17",
	}
	if got := resultFromOutput(text); !reflect.DeepEqual(got, want) {
		t.Fatalf("result = %v\nwant     %v", got, want)
	}
}

func TestResultFromOutputWithoutAScoreHasOnlyTheLog(t *testing.T) {
	text := "the grader printed nothing useful\n"
	want := map[string]any{"log": text}
	if got := resultFromOutput(text); !reflect.DeepEqual(got, want) {
		t.Fatalf("result = %v\nwant     %v", got, want)
	}
}

func TestResultFromOutputStoresTheChallenges(t *testing.T) {
	result := resultFromOutput(fixture(t, "driver-mixed.txt"))
	challenges, ok := result["challenges"].([]challengeResult)
	if !ok || len(challenges) != 15 {
		t.Fatalf("challenges = %#v, want 15 entries", result["challenges"])
	}
	if want := (challengeResult{"bitAnd", 3, 3}); challenges[0] != want {
		t.Fatalf("first challenge = %+v, want %+v", challenges[0], want)
	}

	// The result is stored as JSON, so check that form too.
	stored, err := json.Marshal(result)
	if err != nil {
		t.Fatal(err)
	}
	var back struct {
		Score      string            `json:"score"`
		Challenges []challengeResult `json:"challenges"`
	}
	if err := json.Unmarshal(stored, &back); err != nil {
		t.Fatal(err)
	}
	if back.Score == "" || !reflect.DeepEqual(back.Challenges, challenges) {
		t.Fatalf("stored result lost data: score %q, challenges %+v", back.Score, back.Challenges)
	}
}
