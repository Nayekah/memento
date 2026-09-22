package main

import (
	"encoding/json"
	"errors"
	"io"
	"net/http"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

func serveAPI(cfg config, db *pgxpool.Pool) error {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /health", func(w http.ResponseWriter, r *http.Request) {
		if err := db.Ping(r.Context()); err != nil {
			writeError(w, http.StatusServiceUnavailable, "database unavailable")
			return
		}
		writeJSON(w, http.StatusOK, map[string]string{"status": "ok"})
	})
	mux.HandleFunc("GET /api/v1/system/status", func(w http.ResponseWriter, r *http.Request) {
		var queued, processing, activeWorkers, knownWorkers int
		if err := db.QueryRow(r.Context(), `SELECT count(*) FILTER (WHERE status = 'queued'), count(*) FILTER (WHERE status = 'processing') FROM submissions`).Scan(&queued, &processing); err != nil {
			writeError(w, http.StatusServiceUnavailable, "database unavailable")
			return
		}
		if err := db.QueryRow(r.Context(), `SELECT count(*) FILTER (WHERE last_seen_at > now() - interval '30 seconds'), count(*) FROM worker_heartbeats`).Scan(&activeWorkers, &knownWorkers); err != nil {
			writeError(w, http.StatusServiceUnavailable, "database unavailable")
			return
		}
		writeJSON(w, http.StatusOK, map[string]int{"queued": queued, "processing": processing, "active_workers": activeWorkers, "known_workers": knownWorkers})
	})
	mux.HandleFunc("POST /api/v1/vm-activation", func(w http.ResponseWriter, r *http.Request) {
		student, err := authenticate(r, cfg)
		if err != nil {
			writeError(w, http.StatusUnauthorized, err.Error())
			return
		}
		var request struct {
			DeviceID string `json:"device_id"`
		}
		r.Body = http.MaxBytesReader(w, r.Body, 1024)
		if err := json.NewDecoder(r.Body).Decode(&request); err != nil || !deviceIDPattern.MatchString(request.DeviceID) {
			writeError(w, http.StatusBadRequest, "invalid activation request")
			return
		}
		if err := activateVM(r.Context(), db, student, request.DeviceID); err != nil {
			switch {
			case errors.Is(err, errActivationBound):
				writeError(w, http.StatusConflict, err.Error())
			case errors.Is(err, errStudentNotRegistered):
				writeError(w, http.StatusForbidden, err.Error())
			default:
				writeError(w, http.StatusInternalServerError, "could not activate VM")
			}
			return
		}
		writeJSON(w, http.StatusCreated, map[string]string{"status": "activated", "student_id": student})
	})
	mux.HandleFunc("POST /api/v1/submissions", func(w http.ResponseWriter, r *http.Request) {
		student, err := authenticate(r, cfg)
		if err != nil {
			writeError(w, http.StatusUnauthorized, err.Error())
			return
		}
		r.Body = http.MaxBytesReader(w, r.Body, maxSourceBytes+8192)
		if err := r.ParseMultipartForm(maxSourceBytes + 8192); err != nil {
			writeError(w, http.StatusBadRequest, "invalid multipart submission")
			return
		}
		if len(r.MultipartForm.File) != 1 || len(r.MultipartForm.File["source"]) != 1 {
			writeError(w, http.StatusBadRequest, "submit exactly one source file named bits.c")
			return
		}
		file, header, err := r.FormFile("source")
		if err != nil || header.Filename != "bits.c" {
			writeError(w, http.StatusBadRequest, "submit a multipart source file named bits.c")
			return
		}
		defer file.Close()
		value, err := createSubmission(r.Context(), db, cfg, student, file)
		if err != nil {
			switch {
			case errors.Is(err, errStudentNotRegistered):
				writeError(w, http.StatusForbidden, err.Error())
			case errors.Is(err, errSubmissionRateLimited):
				w.Header().Set("Retry-After", "60")
				writeError(w, http.StatusTooManyRequests, err.Error())
			case errors.Is(err, errSourceTooLarge):
				writeError(w, http.StatusRequestEntityTooLarge, err.Error())
			default:
				writeError(w, http.StatusInternalServerError, err.Error())
			}
			return
		}
		writeJSON(w, http.StatusAccepted, map[string]string{"id": value.ID, "status": value.Status, "status_url": "/api/v1/submissions/" + value.ID})
	})
	mux.HandleFunc("GET /api/v1/submissions/{id}/report", func(w http.ResponseWriter, r *http.Request) {
		value, ok := submissionForRequest(w, r, cfg, db)
		if !ok {
			return
		}
		w.Header().Set("Content-Type", "text/plain; charset=utf-8")
		_, _ = io.WriteString(w, submissionReport(value))
	})
	mux.HandleFunc("GET /api/v1/submissions/{id}", func(w http.ResponseWriter, r *http.Request) {
		value, ok := submissionForRequest(w, r, cfg, db)
		if !ok {
			return
		}
		writeJSON(w, http.StatusOK, value)
	})
	mux.HandleFunc("GET /api/v1/leaderboard", func(w http.ResponseWriter, r *http.Request) { serveLeaderboard(w, r, db) })
	return http.ListenAndServe(":8067", securityHeaders(mux))
}

func submissionForRequest(w http.ResponseWriter, r *http.Request, cfg config, db *pgxpool.Pool) (submission, bool) {
	student, err := authenticate(r, cfg)
	if err != nil {
		writeError(w, http.StatusUnauthorized, err.Error())
		return submission{}, false
	}
	id := r.PathValue("id")
	if !jobIDPattern.MatchString(id) {
		writeError(w, http.StatusNotFound, "submission not found")
		return submission{}, false
	}
	value, err := getSubmission(r.Context(), db, id, student)
	if errors.Is(err, pgx.ErrNoRows) {
		writeError(w, http.StatusNotFound, "submission not found")
	} else if err != nil {
		writeError(w, http.StatusInternalServerError, "could not read submission")
	} else {
		return value, true
	}
	return submission{}, false
}

func serveLeaderboard(w http.ResponseWriter, r *http.Request, db *pgxpool.Pool) {
	rows, err := db.Query(r.Context(), `WITH best AS (SELECT DISTINCT ON (s.student_id) s.student_id, s.score, s.max_score, s.completed_at FROM submissions s WHERE s.status = 'completed' AND s.score IS NOT NULL ORDER BY s.student_id, s.score DESC, s.completed_at ASC) SELECT RANK() OVER (ORDER BY b.score DESC, b.completed_at ASC), st.display_name, b.score, b.max_score FROM best b JOIN students st ON st.id = b.student_id ORDER BY 1, st.display_name`)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "could not read leaderboard")
		return
	}
	defer rows.Close()
	type entry struct {
		Rank     int    `json:"rank"`
		Name     string `json:"name"`
		Score    int    `json:"score"`
		MaxScore int    `json:"max_score"`
	}
	entries := make([]entry, 0)
	for rows.Next() {
		var e entry
		if err := rows.Scan(&e.Rank, &e.Name, &e.Score, &e.MaxScore); err != nil {
			writeError(w, http.StatusInternalServerError, "could not read leaderboard")
			return
		}
		entries = append(entries, e)
	}
	if err := rows.Err(); err != nil {
		writeError(w, http.StatusInternalServerError, "could not read leaderboard")
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"entries": entries})
}

func securityHeaders(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Cache-Control", "no-store")
		w.Header().Set("X-Content-Type-Options", "nosniff")
		next.ServeHTTP(w, r)
	})
}
func writeJSON(w http.ResponseWriter, code int, value any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(code)
	_ = json.NewEncoder(w).Encode(value)
}
func writeError(w http.ResponseWriter, code int, message string) {
	writeJSON(w, code, map[string]string{"error": message})
}
