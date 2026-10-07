package main

import "errors"

var (
	errActivationBound       = errors.New("student is already activated on another VM")
	errStudentNotRegistered  = errors.New("student is not registered")
	errSubmissionRateLimited = errors.New("submission rate limit reached; wait before submitting again")
	errSourceTooLarge        = errors.New("bits.c is too large")
	errDisplayNameEmpty      = errors.New("display name is empty")
	errDisplayNameTooLong    = errors.New("display name must be at most 20 characters")
	errDisplayNameInvalid    = errors.New("display name may use letters, numbers, spaces, dots, underscores, and hyphens, and must start with a letter or number")
	errDisplayNameTaken      = errors.New("display name is already taken")
)
