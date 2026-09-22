package main

import (
	"context"
	"errors"
	"fmt"
	"log"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
)

func runWorker(cfg config, db *pgxpool.Pool) error {
	if cfg.workDir == "" || cfg.dockerWorkDir == "" {
		return errors.New("WORK_DIR and DOCKER_WORK_DIR are required by the worker")
	}
	if err := heartbeat(context.Background(), db, cfg.workerID, "idle", nil, 0, 0); err != nil {
		return fmt.Errorf("register worker heartbeat: %w", err)
	}
	for {
		job, err := claimSubmission(context.Background(), db)
		if err != nil {
			log.Printf("claim submission: %v", err)
			setWorkerIdle(db, cfg.workerID, 0, 0)
			time.Sleep(time.Second)
			continue
		}
		if job == nil {
			setWorkerIdle(db, cfg.workerID, 0, 0)
			time.Sleep(time.Second)
			continue
		}
		gradeOne(cfg, db, job)
	}
}

func gradeOne(cfg config, db *pgxpool.Pool, job *claimedSubmission) {
	if err := heartbeat(context.Background(), db, cfg.workerID, "grading", &job.ID, 0, 0); err != nil {
		log.Printf("heartbeat submission %s: %v", job.ID, err)
	}
	stop, done := make(chan struct{}), make(chan struct{})
	go func() { defer close(done); heartbeatWhileGrading(db, cfg.workerID, job.ID, stop) }()
	result, gradeErr := grade(context.Background(), cfg, job)
	close(stop)
	<-done
	if err := completeSubmission(context.Background(), db, job, result, gradeErr); err != nil {
		log.Printf("complete submission %s: %v", job.ID, err)
	}
	if gradeErr != nil {
		setWorkerIdle(db, cfg.workerID, 0, 1)
	} else {
		setWorkerIdle(db, cfg.workerID, 1, 0)
	}
}

func setWorkerIdle(db *pgxpool.Pool, workerID string, completed, failed int) {
	if err := heartbeat(context.Background(), db, workerID, "idle", nil, completed, failed); err != nil {
		log.Printf("idle heartbeat: %v", err)
	}
}

func heartbeatWhileGrading(db *pgxpool.Pool, workerID, submissionID string, stop <-chan struct{}) {
	ticker := time.NewTicker(10 * time.Second)
	defer ticker.Stop()
	for {
		select {
		case <-stop:
			return
		case <-ticker.C:
			if err := heartbeat(context.Background(), db, workerID, "grading", &submissionID, 0, 0); err != nil {
				log.Printf("grading heartbeat: %v", err)
			}
		}
	}
}

func heartbeat(ctx context.Context, db *pgxpool.Pool, workerID, status string, submissionID *string, completed, failed int) error {
	_, err := db.Exec(ctx, `INSERT INTO worker_heartbeats (id, status, current_submission_id, completed_count, failed_count) VALUES ($1, $2, $3, $4, $5) ON CONFLICT (id) DO UPDATE SET status = EXCLUDED.status, current_submission_id = EXCLUDED.current_submission_id, last_seen_at = now(), completed_count = worker_heartbeats.completed_count + EXCLUDED.completed_count, failed_count = worker_heartbeats.failed_count + EXCLUDED.failed_count`, workerID, status, submissionID, completed, failed)
	return err
}
