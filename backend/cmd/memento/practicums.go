package main

import (
	"net/http"

	"github.com/jackc/pgx/v5/pgxpool"
)

// defaultPracticum is the practicum that /api/v1/leaderboard serves and that
// submissions belong to unless they say otherwise.
const defaultPracticum = "datalab"

// practicumIDs lists the practicums the API has a leaderboard for. Add an ID
// here when a practicum starts accepting submissions. The scoreboard names the
// same IDs in its configuration.
var practicumIDs = []string{"datalab", "bomblab"}

func knownPracticum(id string) bool {
	for _, known := range practicumIDs {
		if id == known {
			return true
		}
	}
	return false
}

// practicumLeaderboardHandler serves GET /api/v1/practicums/{practicum}/leaderboard.
// An ID the API does not know answers 404.
func practicumLeaderboardHandler(db *pgxpool.Pool) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		practicum := r.PathValue("practicum")
		if !knownPracticum(practicum) {
			writeError(w, http.StatusNotFound, "practicum not found")
			return
		}
		serveLeaderboardFor(w, r, db, practicum)
	}
}
