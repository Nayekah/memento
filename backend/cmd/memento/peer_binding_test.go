package main

import (
	"net/http"
	"net/http/httptest"
	"net/netip"
	"strings"
	"testing"
)

func mustProxies(t *testing.T, value string) []netip.Prefix {
	t.Helper()
	prefixes, err := parseTrustedProxies(value)
	if err != nil {
		t.Fatalf("parseTrustedProxies(%q): %v", value, err)
	}
	return prefixes
}

func TestParsePeerBindingMode(t *testing.T) {
	cases := []struct {
		in      string
		want    peerBindingMode
		wantErr bool
	}{
		{"", peerBindingOff, false},
		{"off", peerBindingOff, false},
		{"OFF", peerBindingOff, false},
		{" log ", peerBindingLog, false},
		{"enforce", peerBindingEnforce, false},
		{"on", peerBindingOff, true},
		{"enforced", peerBindingOff, true},
	}
	for _, c := range cases {
		got, err := parsePeerBindingMode(c.in)
		if (err != nil) != c.wantErr || got != c.want {
			t.Errorf("parsePeerBindingMode(%q) = %v, %v; want %v, error=%v", c.in, got, err, c.want, c.wantErr)
		}
	}
}

func TestParseTrustedProxies(t *testing.T) {
	cases := []struct {
		in      string
		want    string
		wantErr bool
	}{
		{"", "", false},
		{"172.30.0.4", "172.30.0.4/32", false},
		{"172.30.0.0/24, 10.0.0.1", "172.30.0.0/24 10.0.0.1/32", false},
		{"10.0.0.5/24", "10.0.0.0/24", false},
		{"::1", "::1/128", false},
		{"::ffff:172.30.0.4", "172.30.0.4/32", false},
		{"nonsense", "", true},
		{"10.0.0.1,bad", "", true},
	}
	for _, c := range cases {
		got, err := parseTrustedProxies(c.in)
		if (err != nil) != c.wantErr {
			t.Errorf("parseTrustedProxies(%q) error = %v, want error=%v", c.in, err, c.wantErr)
			continue
		}
		var parts []string
		for _, prefix := range got {
			parts = append(parts, prefix.String())
		}
		if joined := strings.Join(parts, " "); joined != c.want {
			t.Errorf("parseTrustedProxies(%q) = %q, want %q", c.in, joined, c.want)
		}
	}
}

func TestClientAddress(t *testing.T) {
	proxy := mustProxies(t, "172.30.0.4")
	cases := []struct {
		name    string
		remote  string
		headers []string
		trusted []netip.Prefix
		want    string
	}{
		{"a direct peer", "10.66.0.10:41234", nil, nil, "10.66.0.10"},
		{"a forged header from a direct peer is ignored", "10.66.0.10:41234", []string{"10.66.0.99"}, nil, "10.66.0.10"},
		{"a forged header from an address that is not the proxy is ignored", "10.66.0.10:41234", []string{"10.66.0.99"}, proxy, "10.66.0.10"},
		{"the proxy's forwarded client", "172.30.0.4:5555", []string{"10.66.0.10"}, proxy, "10.66.0.10"},
		{"the last entry of the header is used", "172.30.0.4:5555", []string{"10.66.0.99, 10.66.0.10"}, proxy, "10.66.0.10"},
		{"the last header line is used", "172.30.0.4:5555", []string{"10.66.0.99", "10.66.0.10"}, proxy, "10.66.0.10"},
		{"a range of proxies", "172.30.0.7:5555", []string{"10.66.0.10"}, mustProxies(t, "172.30.0.0/24"), "10.66.0.10"},
		{"the proxy sent no header", "172.30.0.4:5555", nil, proxy, ""},
		{"the proxy sent an empty header", "172.30.0.4:5555", []string{""}, proxy, ""},
		{"the proxy sent a malformed header", "172.30.0.4:5555", []string{"not-an-address"}, proxy, ""},
		{"an IPv4 address in IPv6 form", "[::ffff:10.66.0.10]:1", nil, nil, "10.66.0.10"},
		{"an IPv6 address", "[2001:db8::1]:443", nil, nil, "2001:db8::1"},
		{"a remote address without a port", "10.66.0.10", nil, nil, "10.66.0.10"},
		{"an unparsable remote address", "garbage", nil, nil, ""},
	}
	for _, c := range cases {
		r := httptest.NewRequest(http.MethodGet, "/", nil)
		r.RemoteAddr = c.remote
		for _, value := range c.headers {
			r.Header.Add("X-Forwarded-For", value)
		}
		got, ok := clientAddress(r, c.trusted)
		if c.want == "" {
			if ok {
				t.Errorf("%s: got %v, want no usable address", c.name, got)
			}
			continue
		}
		if !ok || got.String() != c.want {
			t.Errorf("%s: got %v (ok=%v), want %s", c.name, got, ok, c.want)
		}
	}
}

func TestLoadConfigPeerSettings(t *testing.T) {
	t.Setenv("DATABASE_URL", "postgresql://example")
	t.Setenv("TOKEN_SECRET", "a-secret-with-more-than-24-characters")

	t.Setenv("PEER_BINDING", "enforce")
	t.Setenv("TRUSTED_PROXY", "172.30.0.4, 10.0.0.0/8")
	cfg, err := loadConfig(true)
	if err != nil || cfg.peerBinding != peerBindingEnforce || len(cfg.trustedProxies) != 2 {
		t.Fatalf("loadConfig = %+v, %v; want enforce with two trusted proxies", cfg, err)
	}

	t.Setenv("PEER_BINDING", "sometimes")
	if _, err := loadConfig(true); err == nil || !strings.Contains(err.Error(), "PEER_BINDING") {
		t.Errorf("an invalid PEER_BINDING: error = %v", err)
	}
	t.Setenv("PEER_BINDING", "off")
	t.Setenv("TRUSTED_PROXY", "nonsense")
	if _, err := loadConfig(true); err == nil || !strings.Contains(err.Error(), "TRUSTED_PROXY") {
		t.Errorf("an invalid TRUSTED_PROXY: error = %v", err)
	}
}
