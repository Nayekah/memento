package main

import (
	"crypto/rand"
	"encoding/hex"
	"errors"
	"fmt"
	"os"
	"regexp"
	"strconv"
)

const (
	maxSourceBytes = 128 * 1024
	usage          = "usage: memento [api|worker|token STUDENT_ID|student STUDENT_ID [DISPLAY_NAME]|reset-activation STUDENT_ID|regrade SUBMISSION_ID]"
)

var (
	studentIDPattern  = regexp.MustCompile(`^[A-Za-z0-9._-]{1,64}$`)
	jobIDPattern      = regexp.MustCompile(`^[a-f0-9]{24}$`)
	deviceIDPattern   = regexp.MustCompile(`^[a-f0-9]{32}$`)
	scorePattern      = regexp.MustCompile(`(?m)^Score = (.+)$`)
	scoreValuePattern = regexp.MustCompile(`^(\d+)/(\d+)`)
	resultPattern     = regexp.MustCompile(`(?m)^AUTORESULT_STRING=(.+)$`)
)

type config struct {
	databaseURL             string
	workDir                 string
	dockerWorkDir           string
	graderImage             string
	secret                  string
	workerID                string
	submissionRatePerMinute int
}

func loadConfig(requireSecret bool) (config, error) {
	cfg := config{
		databaseURL:   os.Getenv("DATABASE_URL"),
		workDir:       os.Getenv("WORK_DIR"),
		dockerWorkDir: os.Getenv("DOCKER_WORK_DIR"),
		graderImage:   envOr("GRADER_IMAGE", "memento-datalab-grader:local"),
		secret:        os.Getenv("TOKEN_SECRET"),
		workerID:      envOr("WORKER_ID", defaultWorkerID()),
	}
	rate, err := envNonNegativeInt("SUBMISSION_RATE_PER_MINUTE", 8)
	if err != nil {
		return config{}, err
	}
	cfg.submissionRatePerMinute = rate
	if cfg.databaseURL == "" {
		return config{}, errors.New("DATABASE_URL is required")
	}
	if requireSecret && len(cfg.secret) < 24 {
		return config{}, errors.New("TOKEN_SECRET must contain at least 24 characters")
	}
	return cfg, nil
}

func envOr(key, fallback string) string {
	if value := os.Getenv(key); value != "" {
		return value
	}
	return fallback
}

func envNonNegativeInt(key string, fallback int) (int, error) {
	if value := os.Getenv(key); value != "" {
		parsed, err := strconv.Atoi(value)
		if err != nil || parsed < 0 {
			return 0, fmt.Errorf("%s must be a non-negative integer", key)
		}
		return parsed, nil
	}
	return fallback, nil
}

func defaultWorkerID() string {
	host, err := os.Hostname()
	if err != nil || host == "" {
		host = "worker"
	}
	return fmt.Sprintf("%s-%d", host, os.Getpid())
}

func newID() string {
	var random [12]byte
	if _, err := rand.Read(random[:]); err != nil {
		panic(err)
	}
	return hex.EncodeToString(random[:])
}

func truncate(value string, length int) string {
	if len(value) <= length {
		return value
	}
	return value[len(value)-length:]
}
