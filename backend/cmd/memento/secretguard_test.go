package main

import (
	"crypto/sha256"
	"encoding/hex"
	"strings"
	"testing"
)

func digestOf(secret string) string {
	sum := sha256.Sum256([]byte(secret))
	return hex.EncodeToString(sum[:])
}

func TestPublishedSecretDigestsAreWellFormed(t *testing.T) {
	if len(publishedSecretDigests) == 0 {
		t.Fatal("the list of published secrets is empty")
	}
	for digest := range publishedSecretDigests {
		decoded, err := hex.DecodeString(digest)
		if err != nil || len(decoded) != sha256.Size || digest != strings.ToLower(digest) {
			t.Errorf("%q is not a lower-case SHA-256 hex digest", digest)
		}
	}
}

func TestLoadConfigRejectsAPublishedSecret(t *testing.T) {
	const published = "unit-test-published-secret-0123456789"
	publishedSecretDigests[digestOf(published)] = struct{}{}
	t.Cleanup(func() { delete(publishedSecretDigests, digestOf(published)) })
	t.Setenv("DATABASE_URL", "postgresql://example")

	cases := []struct {
		name          string
		secret        string
		requireSecret bool
		wantError     string
	}{
		{"published secret is refused", published, true, "published in this repository"},
		{"fresh secret is accepted", "a-fresh-secret-that-nobody-published", true, ""},
		{"short secret is still refused for length", "short", true, "at least 24 characters"},
		{"commands that do not use the secret are unaffected", published, false, ""},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			t.Setenv("TOKEN_SECRET", c.secret)
			_, err := loadConfig(c.requireSecret)
			switch {
			case c.wantError == "" && err != nil:
				t.Fatalf("unexpected error: %v", err)
			case c.wantError != "" && (err == nil || !strings.Contains(err.Error(), c.wantError)):
				t.Fatalf("error = %v, want one containing %q", err, c.wantError)
			}
		})
	}
}
