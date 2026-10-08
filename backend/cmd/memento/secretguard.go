package main

import (
	"crypto/sha256"
	"encoding/hex"
)

// publishedSecretDigests holds SHA-256 digests of token secrets that were
// committed to backend/.env.example. Those values are public, so a deployment
// that still uses one lets anyone derive every student's token. Only digests
// are kept so this file does not repeat the secrets.
var publishedSecretDigests = map[string]struct{}{
	"c815ae127a528b6aef8ebfa6d1cae2a61c7d06773b1df9033d0f5d5c89dfef4f": {},
}

func isPublishedSecret(secret string) bool {
	sum := sha256.Sum256([]byte(secret))
	_, published := publishedSecretDigests[hex.EncodeToString(sum[:])]
	return published
}
