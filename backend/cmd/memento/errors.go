package main

import "errors"

var (
	errActivationBound       = errors.New("student is already activated on another VM")
	errDeviceInUse           = errors.New("this VM is already activated for another student")
	errStudentNotRegistered  = errors.New("student is not registered")
	errSubmissionRateLimited = errors.New("submission rate limit reached; wait before submitting again")
	errSourceTooLarge        = errors.New("bits.c is too large")
)
