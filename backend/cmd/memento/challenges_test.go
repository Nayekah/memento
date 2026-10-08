package main

import (
	"encoding/json"
	"fmt"
	"os"
	"reflect"
	"strings"
	"testing"
)

// The fixtures are real output of the Data Lab driver (perl ./driver.pl -f
// bits.c -A). The skeleton file is the untouched bits.c. In the mixed file
// bitAnd, getByte and tmin are solved, logicalShift is wrong, and negate is
// correct but over its operator limit.
func fixture(t *testing.T, name string) string {
	t.Helper()
	data, err := os.ReadFile("testdata/" + name)
	if err != nil {
		t.Fatal(err)
	}
	return string(data)
}

// mutate replaces old with replacement and fails if old is not there exactly
// once, so a test cannot pass because its edit matched nothing.
func mutate(t *testing.T, text, old, replacement string) string {
	t.Helper()
	if count := strings.Count(text, old); count != 1 {
		t.Fatalf("expected %q exactly once in the fixture, found %d", old, count)
	}
	return strings.Replace(text, old, replacement, 1)
}

func TestParseChallengesOfAnUntouchedSkeleton(t *testing.T) {
	got := parseChallenges(fixture(t, "driver-skeleton.txt"))
	// The correctness rating of each puzzle plus 2 for performance.
	want := []challengeResult{
		{"bitAnd", 0, 3}, {"getByte", 0, 4}, {"logicalShift", 0, 5}, {"bitCount", 0, 6}, {"bang", 0, 6},
		{"tmin", 0, 3}, {"fitsBits", 0, 4}, {"divpwr2", 0, 4}, {"negate", 0, 4}, {"isPositive", 0, 5},
		{"isLessOrEqual", 0, 5}, {"ilog2", 0, 6}, {"float_neg", 0, 4}, {"float_i2f", 0, 6}, {"float_twice", 0, 6},
	}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("challenges = %+v\nwant         %+v", got, want)
	}
}

func TestParseChallengesSeparatesSolvedPartialAndWrong(t *testing.T) {
	got := parseChallenges(fixture(t, "driver-mixed.txt"))
	byName := map[string]challengeResult{}
	for _, c := range got {
		byName[c.Name] = c
	}
	if len(got) != 15 {
		t.Fatalf("got %d challenges, want 15", len(got))
	}
	for name, want := range map[string]challengeResult{
		"bitAnd":       {"bitAnd", 3, 3},       // correct and within its operators
		"getByte":      {"getByte", 4, 4},      // likewise
		"tmin":         {"tmin", 3, 3},         // likewise
		"negate":       {"negate", 2, 4},       // correct, 8 operators for a limit of 5
		"logicalShift": {"logicalShift", 0, 5}, // wrong answer
		"bitCount":     {"bitCount", 0, 6},     // untouched
	} {
		if byName[name] != want {
			t.Errorf("%s = %+v, want %+v", name, byName[name], want)
		}
	}
	points := 0
	for _, c := range got {
		points += c.Points
	}
	if points != 12 {
		t.Errorf("the points add up to %d, but the driver's Score line says 12", points)
	}
}

func TestParseChallengesReadsTheLastTable(t *testing.T) {
	forged := "Points\tRating\tErrors\tPoints\tOps\tPuzzle\n9\t9\t0\t2\t1\tforged\n\nScore = 11/11 [9/9 Corr + 2/2 Perf] (1 total operators)\n"
	real := fixture(t, "driver-mixed.txt")
	if got, want := parseChallenges(forged+real), parseChallenges(real); got == nil || !reflect.DeepEqual(got, want) {
		t.Fatalf("a table printed earlier changed the result: %+v", got)
	}
}

func TestParseChallengesRejectsWhatItCannotTrust(t *testing.T) {
	mixed := fixture(t, "driver-mixed.txt")
	table := mixed[strings.Index(mixed, challengeTableHeader):]
	rows := func(n int) string {
		var b strings.Builder
		b.WriteString(challengeTableHeader + "\n")
		for i := 0; i < n; i++ {
			fmt.Fprintf(&b, "1\t1\t0\t2\t1\tp%d\n", i)
		}
		fmt.Fprintf(&b, "\nScore = %d/%d [%d/%d Corr + %d/%d Perf] (1 total operators)\n", 3*n, 3*n, n, n, 2*n, 2*n)
		return b.String()
	}

	tests := []struct {
		name string
		text string
	}{
		{"an empty log", ""},
		{"a log without a table", "Score = 12/71 [6/41 Corr + 6/30 Perf] (17 total operators)\n"},
		{"a header without rows", challengeTableHeader + "\n\nScore = 0/0 [0/0 Corr + 0/0 Perf] (0 total operators)\n"},
		{"a table cut off before the totals", table[:strings.Index(table, "float_neg")]},
		{"a table without the totals line", table[:strings.Index(table, "\nScore =")]},
		{"a total that is not the sum", mutate(t, mixed, "Score = 12/71", "Score = 13/71")},
		{"a maximum that is not the sum", mutate(t, mixed, "Score = 12/71", "Score = 12/72")},
		{"a row that is not part of the totals", mutate(t, mixed, "2\t2\t0\t2\t3\tgetByte", "1\t2\t0\t2\t3\tgetByte")},
		{"a performance rating that does not divide evenly", mutate(t, mutate(t, mixed, "6/30 Perf", "6/31 Perf"), "12/71", "12/72")},
		{"a puzzle listed twice", mutate(t, mixed, "float_neg", "bitAnd")},
		{"points above the rating", mutate(t, mutate(t, mutate(t, mixed, "1\t1\t0\t2\t1\ttmin", "5\t1\t0\t2\t1\ttmin"), "6/41 Corr", "10/41 Corr"), "Score = 12/71", "Score = 16/71")},
		{"a puzzle worth nothing", challengeTableHeader + "\n0\t0\t0\t0\t0\tfree\n\nScore = 0/0 [0/0 Corr + 0/0 Perf] (0 total operators)\n"},
		{"a name that is not an identifier", mutate(t, mixed, "getByte", "get Byte")},
		{"more puzzles than any problem set", rows(maxChallenges + 1)},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			if got := parseChallenges(tc.text); got != nil {
				t.Fatalf("expected no challenges, got %+v", got)
			}
		})
	}

	if got := parseChallenges(rows(maxChallenges)); len(got) != maxChallenges {
		t.Fatalf("a table of exactly %d puzzles gave %d challenges", maxChallenges, len(got))
	}
}

func TestChallengeResultJSONNamesAreWhatTheScoreboardReads(t *testing.T) {
	encoded, err := json.Marshal([]challengeResult{{"bitAnd", 3, 3}})
	if err != nil {
		t.Fatal(err)
	}
	if got, want := string(encoded), `[{"name":"bitAnd","points":3,"max":3}]`; got != want {
		t.Fatalf("encoded = %s, want %s", got, want)
	}
}
