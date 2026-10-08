package main

import (
	"regexp"
	"strconv"
	"strings"
)

// challengeResult is one student's result for one challenge, which is one
// puzzle of the Data Lab driver. The scoreboard draws a cell for each.
type challengeResult struct {
	Name   string `json:"name"`
	Points int    `json:"points"`
	Max    int    `json:"max"`
}

// maxChallenges is far above any real problem set. It keeps a damaged log from
// producing a huge list.
const maxChallenges = 64

const challengeTableHeader = "Points\tRating\tErrors\tPoints\tOps\tPuzzle"

var (
	// One row per puzzle: correctness points, rating, errors, performance
	// points, operator count, and the puzzle name.
	challengeRowPattern = regexp.MustCompile(`^(\d{1,6})\t(\d{1,6})\t(\d{1,6})\t(\d{1,6})\t(\d{1,6})\t([A-Za-z_][A-Za-z0-9_]{0,63})$`)
	// The line that follows the table: Score = X/Y [A/B Corr + C/D Perf] (N total operators)
	challengeTotalsPattern = regexp.MustCompile(`^Score = (\d{1,9})/(\d{1,9}) \[(\d{1,9})/(\d{1,9}) Corr \+ (\d{1,9})/(\d{1,9}) Perf\]`)
)

type challengeRow struct {
	name                  string
	correct, rating, perf int
}

// parseChallenges reads the per-puzzle table that the Data Lab driver prints
// just before its final Score line. A puzzle's points are its correctness and
// performance points together, and its maximum adds the correctness rating to
// the performance rating, which the driver only reports as a total and applies
// to every puzzle alike.
//
// It returns nil unless the table is complete and agrees with the totals line,
// so a damaged log gives no breakdown instead of a wrong one. The last table in
// the text is the one read, because the driver prints it last.
func parseChallenges(text string) []challengeResult {
	lines := strings.Split(text, "\n")
	header := -1
	for i, line := range lines {
		if line == challengeTableHeader {
			header = i
		}
	}
	if header < 0 {
		return nil
	}

	var rows []challengeRow
	next := header + 1
	for ; next < len(lines); next++ {
		match := challengeRowPattern.FindStringSubmatch(lines[next])
		if match == nil {
			break
		}
		rows = append(rows, challengeRow{
			name:    match[6],
			correct: atoi(match[1]),
			rating:  atoi(match[2]),
			perf:    atoi(match[4]),
		})
	}
	if len(rows) == 0 || len(rows) > maxChallenges {
		return nil
	}

	for next < len(lines) && strings.TrimSpace(lines[next]) == "" {
		next++
	}
	if next >= len(lines) {
		return nil
	}
	totals := challengeTotalsPattern.FindStringSubmatch(lines[next])
	if totals == nil {
		return nil
	}
	total, totalMax := atoi(totals[1]), atoi(totals[2])
	correctTotal, correctRating := atoi(totals[3]), atoi(totals[4])
	perfTotal, perfRating := atoi(totals[5]), atoi(totals[6])

	var sumCorrect, sumRating, sumPerf int
	for _, row := range rows {
		sumCorrect += row.correct
		sumRating += row.rating
		sumPerf += row.perf
	}
	if sumCorrect != correctTotal || sumRating != correctRating || sumPerf != perfTotal {
		return nil
	}
	if total != correctTotal+perfTotal || totalMax != correctRating+perfRating {
		return nil
	}
	if perfRating%len(rows) != 0 {
		return nil
	}
	perfEach := perfRating / len(rows)

	seen := make(map[string]bool, len(rows))
	results := make([]challengeResult, 0, len(rows))
	for _, row := range rows {
		maximum := row.rating + perfEach
		if seen[row.name] || row.correct > row.rating || row.perf > perfEach || maximum < 1 {
			return nil
		}
		seen[row.name] = true
		results = append(results, challengeResult{Name: row.name, Points: row.correct + row.perf, Max: maximum})
	}
	return results
}

// atoi converts a run of at most nine digits, which the patterns guarantee.
func atoi(digits string) int {
	value, _ := strconv.Atoi(digits)
	return value
}
