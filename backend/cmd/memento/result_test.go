package main

import (
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
