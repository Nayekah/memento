package main

import (
	"bytes"
	"context"
	"errors"
	"log"
	"net/http"
	"net/http/httptest"
	"net/netip"
	"os"
	"strings"
	"testing"
)

// capturedLog returns what f writes to the standard logger.
func capturedLog(f func()) string {
	var buf bytes.Buffer
	log.SetOutput(&buf)
	defer log.SetOutput(os.Stderr)
	f()
	return buf.String()
}

func peerRequest(student, remote string, forwarded ...string) *http.Request {
	r := httptest.NewRequest(http.MethodGet, "/", nil)
	r.RemoteAddr = remote
	r.Header.Set("X-Memento-Student", student)
	r.Header.Set("X-Memento-Token", tokenFor(testSecret, student))
	for _, value := range forwarded {
		r.Header.Add("X-Forwarded-For", value)
	}
	return r
}

func TestPeerBindingModes(t *testing.T) {
	db := testDatabase(t)
	ctx := context.Background()
	addStudents(t, db, "alice", "bob", "carol")
	for student, address := range map[string]string{"alice": "10.66.0.10", "bob": "10.66.0.11"} {
		if err := setStudentPeer(ctx, db, student, netip.MustParseAddr(address)); err != nil {
			t.Fatal(err)
		}
	}
	proxy := mustProxies(t, "172.30.0.4")
	withMode := func(mode peerBindingMode) config {
		return config{secret: testSecret, peerBinding: mode, trustedProxies: proxy, peerLookup: databasePeerLookup(db)}
	}
	cases := []struct {
		name    string
		request *http.Request
		enforce error // the error enforce mode returns; log and off modes always allow
	}{
		{"the registered address through the proxy", peerRequest("alice", "172.30.0.4:5000", "10.66.0.10"), nil},
		{"another student's address through the proxy", peerRequest("alice", "172.30.0.4:5000", "10.66.0.11"), errPeerMismatch},
		{"a forged header from a direct connection", peerRequest("alice", "10.66.0.11:5000", "10.66.0.10"), errPeerMismatch},
		{"a direct connection from the registered address", peerRequest("alice", "10.66.0.10:5000"), nil},
		{"the proxy forwarded nothing", peerRequest("alice", "172.30.0.4:5000"), errPeerMismatch},
		{"a student with no registered address", peerRequest("carol", "172.30.0.4:5000", "10.66.0.12"), errPeerUnregistered},
	}
	for _, c := range cases {
		if got, err := authenticate(c.request, withMode(peerBindingOff)); err != nil || got == "" {
			t.Errorf("off: %s: %q, %v; want the request allowed", c.name, got, err)
		}
		var logErr error
		logged := capturedLog(func() { _, logErr = authenticate(c.request, withMode(peerBindingLog)) })
		if logErr != nil {
			t.Errorf("log: %s: %v; want the request allowed", c.name, logErr)
		}
		if mismatch := c.enforce != nil; mismatch != strings.Contains(logged, "peer binding: student=") {
			t.Errorf("log: %s: log output %q does not match a mismatch of %v", c.name, logged, c.enforce)
		}
		if _, err := authenticate(c.request, withMode(peerBindingEnforce)); !errors.Is(err, c.enforce) {
			t.Errorf("enforce: %s: error = %v, want %v", c.name, err, c.enforce)
		}
	}
}

func TestPeerBindingChecksTheTokenFirstAndHandlesLookupFailures(t *testing.T) {
	calls := 0
	failing := func(context.Context, string) (netip.Addr, bool, error) {
		calls++
		return netip.Addr{}, false, errors.New("database unavailable")
	}
	cfg := config{secret: testSecret, peerBinding: peerBindingEnforce, peerLookup: failing}

	bad := peerRequest("alice", "10.66.0.10:5000")
	bad.Header.Set("X-Memento-Token", "AAAA-AAAA-AAAA")
	if _, err := authenticate(bad, cfg); err == nil || errors.Is(err, errPeerLookup) || calls != 0 {
		t.Errorf("a wrong token: error = %v, lookups = %d; want the token error and no lookup", err, calls)
	}
	if _, err := authenticate(peerRequest("alice", "10.66.0.10:5000"), cfg); !errors.Is(err, errPeerLookup) {
		t.Errorf("enforce with a failing lookup: error = %v, want errPeerLookup", err)
	}
	cfg.peerBinding = peerBindingLog
	var err error
	logged := capturedLog(func() { _, err = authenticate(peerRequest("alice", "10.66.0.10:5000"), cfg) })
	if err != nil || !strings.Contains(logged, "database unavailable") {
		t.Errorf("log with a failing lookup: error = %v, log = %q; want the request allowed and the failure logged", err, logged)
	}
	cfg.peerBinding = peerBindingOff
	before := calls
	if _, err := authenticate(peerRequest("alice", "10.66.0.10:5000"), cfg); err != nil || calls != before {
		t.Errorf("off: error = %v, extra lookups = %d; want the request allowed without a lookup", err, calls-before)
	}
}
