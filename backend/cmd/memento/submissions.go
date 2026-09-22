package main

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

type submission struct {
	ID           string         `json:"id"`
	StudentID    string         `json:"-"`
	SourceSHA256 string         `json:"source_sha256"`
	CreatedAt    time.Time      `json:"created_at"`
	UpdatedAt    time.Time      `json:"updated_at"`
	Status       string         `json:"status"`
	Score        *int           `json:"score,omitempty"`
	MaxScore     *int           `json:"max_score,omitempty"`
	Result       map[string]any `json:"result,omitempty"`
	Error        string         `json:"error,omitempty"`
}

type claimedSubmission struct {
	submission
	Source []byte
}

const submissionColumns = `s.id, s.student_id, s.source_sha256, s.created_at, s.updated_at, s.status, s.score, s.max_score, s.result, COALESCE(s.error, '')`

func createSubmission(ctx context.Context, db *pgxpool.Pool, cfg config, student string, source io.Reader) (submission, error) {
	contents, err := io.ReadAll(io.LimitReader(source, maxSourceBytes+1))
	if err != nil {
		return submission{}, err
	}
	if len(contents) > maxSourceBytes {
		return submission{}, errSourceTooLarge
	}
	tx, err := db.Begin(ctx)
	if err != nil {
		return submission{}, err
	}
	defer func() { _ = tx.Rollback(ctx) }()
	if _, err := tx.Exec(ctx, `SELECT pg_advisory_xact_lock(hashtext($1))`, student); err != nil {
		return submission{}, err
	}
	var registered bool
	if err := tx.QueryRow(ctx, `SELECT EXISTS(SELECT 1 FROM students WHERE id = $1)`, student).Scan(&registered); err != nil {
		return submission{}, err
	}
	if !registered {
		return submission{}, errStudentNotRegistered
	}
	if cfg.submissionRatePerMinute > 0 {
		var recent int
		if err := tx.QueryRow(ctx, `SELECT count(*) FROM submissions WHERE student_id = $1 AND created_at > now() - interval '1 minute'`, student).Scan(&recent); err != nil {
			return submission{}, err
		}
		if recent >= cfg.submissionRatePerMinute {
			return submission{}, errSubmissionRateLimited
		}
	}
	hash := sha256.Sum256(contents)
	value := submission{ID: newID(), StudentID: student, SourceSHA256: hex.EncodeToString(hash[:]), Status: "queued"}
	err = tx.QueryRow(ctx, `INSERT INTO submissions (id, student_id, source, source_sha256, status) VALUES ($1, $2, $3, $4, 'queued') RETURNING created_at, updated_at`, value.ID, student, contents, value.SourceSHA256).Scan(&value.CreatedAt, &value.UpdatedAt)
	if err != nil {
		return submission{}, err
	}
	if err := tx.Commit(ctx); err != nil {
		return submission{}, err
	}
	return value, nil
}

func getSubmission(ctx context.Context, db *pgxpool.Pool, id, student string) (submission, error) {
	return scanSubmission(db.QueryRow(ctx, `SELECT `+submissionColumns+` FROM submissions s WHERE s.id = $1 AND s.student_id = $2`, id, student))
}

func scanSubmission(row pgx.Row) (submission, error) {
	var value submission
	var rawResult []byte
	err := row.Scan(&value.ID, &value.StudentID, &value.SourceSHA256, &value.CreatedAt, &value.UpdatedAt, &value.Status, &value.Score, &value.MaxScore, &rawResult, &value.Error)
	if err != nil {
		return submission{}, err
	}
	if len(rawResult) > 0 && string(rawResult) != "null" {
		if err := json.Unmarshal(rawResult, &value.Result); err != nil {
			return submission{}, err
		}
	}
	return value, nil
}

func claimSubmission(ctx context.Context, db *pgxpool.Pool) (*claimedSubmission, error) {
	row := db.QueryRow(ctx, `WITH next AS (
        SELECT s.id FROM submissions s
        WHERE s.status = 'queued' OR (s.status = 'processing' AND s.claimed_at < now() - interval '5 minutes')
        ORDER BY CASE WHEN s.status = 'processing' THEN 0 ELSE 1 END,
                 CASE WHEN EXISTS (SELECT 1 FROM submissions running WHERE running.student_id = s.student_id AND running.status = 'processing' AND running.id <> s.id) THEN 1 ELSE 0 END,
                 s.created_at
        FOR UPDATE SKIP LOCKED LIMIT 1
    )
    UPDATE submissions s SET status = 'processing', updated_at = now(), claimed_at = now(), attempt_count = attempt_count + 1
    FROM next WHERE s.id = next.id
    RETURNING s.id, s.student_id, s.source_sha256, s.created_at, s.updated_at, s.status, s.score, s.max_score, s.result, COALESCE(s.error, ''), s.source`)
	var value claimedSubmission
	var rawResult []byte
	err := row.Scan(&value.ID, &value.StudentID, &value.SourceSHA256, &value.CreatedAt, &value.UpdatedAt, &value.Status, &value.Score, &value.MaxScore, &rawResult, &value.Error, &value.Source)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	if len(rawResult) > 0 && string(rawResult) != "null" {
		if err := json.Unmarshal(rawResult, &value.Result); err != nil {
			return nil, err
		}
	}
	return &value, nil
}

func completeSubmission(ctx context.Context, db *pgxpool.Pool, value *claimedSubmission, result map[string]any, gradeErr error) error {
	if gradeErr != nil {
		_, err := db.Exec(ctx, `UPDATE submissions SET status = 'failed', error = $2, updated_at = now(), completed_at = now() WHERE id = $1 AND status = 'processing'`, value.ID, truncate(gradeErr.Error(), 16000))
		return err
	}
	resultJSON, err := json.Marshal(result)
	if err != nil {
		return err
	}
	var score, maxScore *int
	if raw, ok := result["score"].(string); ok {
		if parsed := scoreValuePattern.FindStringSubmatch(raw); len(parsed) == 3 {
			current, _ := strconv.Atoi(parsed[1])
			maximum, _ := strconv.Atoi(parsed[2])
			score, maxScore = &current, &maximum
		}
	}
	_, err = db.Exec(ctx, `UPDATE submissions SET status = 'completed', result = $2::jsonb, score = $3, max_score = $4, error = NULL, updated_at = now(), completed_at = now() WHERE id = $1 AND status = 'processing'`, value.ID, resultJSON, score, maxScore)
	return err
}

func grade(ctx context.Context, cfg config, value *claimedSubmission) (map[string]any, error) {
	if cfg.workDir == "" || cfg.dockerWorkDir == "" {
		return nil, errors.New("WORK_DIR and DOCKER_WORK_DIR are required by the worker")
	}
	workSourceDir := filepath.Join(cfg.workDir, value.ID)
	if err := os.MkdirAll(workSourceDir, 0755); err != nil {
		return nil, err
	}
	defer func() { _ = os.RemoveAll(workSourceDir) }()
	if err := os.WriteFile(filepath.Join(workSourceDir, "bits.c"), value.Source, 0644); err != nil {
		return nil, err
	}
	ctx, cancel := context.WithTimeout(ctx, 60*time.Second)
	defer cancel()
	args := []string{"run", "--rm", "--network", "none", "--read-only", "--pids-limit", "64", "--memory", "256m", "--cpus", "0.5", "--cap-drop", "ALL", "--security-opt", "no-new-privileges", "--tmpfs", "/tmp:rw,nosuid,nodev,exec,size=32m,mode=1777", "--tmpfs", "/var/tmp:rw,nosuid,nodev,exec,size=64m,mode=1777", "--tmpfs", "/work:rw,nosuid,nodev,exec,size=96m,mode=1777", "--mount", "type=bind,src=" + filepath.Join(cfg.dockerWorkDir, value.ID) + ",dst=/input,readonly", cfg.graderImage, "/input/bits.c"}
	output, err := exec.CommandContext(ctx, "docker", args...).CombinedOutput()
	if ctx.Err() != nil {
		return nil, errors.New("grader exceeded its 60 second limit")
	}
	text := truncate(string(output), 16000)
	if err != nil {
		return nil, fmt.Errorf("grader failed: %w\n%s", err, text)
	}
	result := map[string]any{"log": text}
	if score := scorePattern.FindStringSubmatch(text); len(score) == 2 {
		result["score"] = score[1]
	}
	if autoresult := resultPattern.FindStringSubmatch(text); len(autoresult) == 2 {
		result["autoresult"] = autoresult[1]
	}
	return result, nil
}

func submissionReport(value submission) string {
	var report strings.Builder
	fmt.Fprintf(&report, "Submission: %s\nStatus: %s\n", value.ID, value.Status)
	switch value.Status {
	case "queued":
		report.WriteString("Verdict: QUEUED\nWaiting for a grading worker.\n")
	case "processing":
		report.WriteString("Verdict: GRADING\nThe grading worker is evaluating this submission.\n")
	case "failed":
		report.WriteString("Verdict: GRADER_ERROR\n")
		if value.Error != "" {
			fmt.Fprintf(&report, "Detail: %s\n", value.Error)
		}
	case "completed":
		report.WriteString("Verdict: GRADED\n")
		if value.Score != nil && value.MaxScore != nil {
			fmt.Fprintf(&report, "Score: %d/%d\n", *value.Score, *value.MaxScore)
		}
		if logText, ok := value.Result["log"].(string); ok && logText != "" {
			report.WriteString("\nDetailed grading:\n")
			report.WriteString(logText)
			if !strings.HasSuffix(logText, "\n") {
				report.WriteByte('\n')
			}
		}
	}
	return report.String()
}
