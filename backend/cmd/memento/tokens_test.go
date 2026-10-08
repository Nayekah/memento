package main

import (
	"crypto/hmac"
	"crypto/sha256"
	"encoding/base32"
	"regexp"
	"testing"
)

// referenceToken is an independent copy of the derivation, so a change to
// tokenFor cannot silently invalidate the tokens that were already issued.
func referenceToken(secret, input string) string {
	mac := hmac.New(sha256.New, []byte(secret))
	_, _ = mac.Write([]byte(input))
	compact := base32.StdEncoding.WithPadding(base32.NoPadding).EncodeToString(mac.Sum(nil)[:8])[:12]
	return compact[:4] + "-" + compact[4:8] + "-" + compact[8:]
}

func TestTokenForVersionZeroIsTheOriginalDerivation(t *testing.T) {
	for _, student := range []string{"18225001", "alice", "a.b_c-d"} {
		if got, want := tokenForVersion(testSecret, student, 0), referenceToken(testSecret, student); got != want {
			t.Errorf("version 0 token for %s = %s, want %s", student, got, want)
		}
	}
}

func TestTokenForVersionMixesTheVersionIn(t *testing.T) {
	format := regexp.MustCompile(`^[A-Z2-7]{4}-[A-Z2-7]{4}-[A-Z2-7]{4}$`)
	seen := map[string]string{}
	for _, student := range []string{"18225001", "18225002"} {
		for version := range 4 {
			token := tokenForVersion(testSecret, student, version)
			if !format.MatchString(token) {
				t.Errorf("%s version %d: %q is not in the XXXX-XXXX-XXXX format", student, version, token)
			}
			if version > 0 {
				if want := referenceToken(testSecret, student+":"+string(rune('0'+version))); token != want {
					t.Errorf("%s version %d = %s, want %s", student, version, token, want)
				}
			}
			label := student + " v" + string(rune('0'+version))
			if other, clash := seen[token]; clash {
				t.Errorf("%s and %s have the same token %s", label, other, token)
			}
			seen[token] = label
		}
	}
	if tokenForVersion("another-secret-with-enough-characters", "18225001", 1) == tokenForVersion(testSecret, "18225001", 1) {
		t.Error("two secrets produced the same version 1 token")
	}
}
