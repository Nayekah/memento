package main

import (
	"errors"
	"fmt"
	"log"
	"net"
	"net/http"
	"net/netip"
	"strings"
)

var (
	errPeerMismatch     = errors.New("this token is not valid from this address")
	errPeerUnregistered = errors.New("no VPN address is registered for this student")
	errPeerLookup       = errors.New("could not verify the VPN address")
)

// peerBindingMode says what the API does when an authenticated request does
// not come from the VPN address registered for its student.
type peerBindingMode int

const (
	peerBindingOff     peerBindingMode = iota // no check
	peerBindingLog                            // log a mismatch and allow the request
	peerBindingEnforce                        // reject the request
)

func parsePeerBindingMode(value string) (peerBindingMode, error) {
	switch strings.ToLower(strings.TrimSpace(value)) {
	case "", "off":
		return peerBindingOff, nil
	case "log":
		return peerBindingLog, nil
	case "enforce":
		return peerBindingEnforce, nil
	}
	return peerBindingOff, fmt.Errorf("PEER_BINDING must be off, log, or enforce, not %q", value)
}

// parseTrustedProxies reads a comma or space separated list of IP addresses
// and CIDR ranges. An empty value trusts no proxy.
func parseTrustedProxies(value string) ([]netip.Prefix, error) {
	var prefixes []netip.Prefix
	for _, field := range strings.FieldsFunc(value, func(r rune) bool { return r == ',' || r == ' ' || r == '\t' }) {
		if prefix, err := netip.ParsePrefix(field); err == nil {
			prefixes = append(prefixes, prefix.Masked())
			continue
		}
		addr, err := netip.ParseAddr(field)
		if err != nil {
			return nil, fmt.Errorf("TRUSTED_PROXY entry %q is not an IP address or a CIDR range", field)
		}
		addr = addr.Unmap()
		prefixes = append(prefixes, netip.PrefixFrom(addr, addr.BitLen()))
	}
	return prefixes, nil
}

func trusted(prefixes []netip.Prefix, addr netip.Addr) bool {
	for _, prefix := range prefixes {
		if prefix.Contains(addr) {
			return true
		}
	}
	return false
}

// clientAddress returns the address a request really came from. A request
// that arrives directly is attributed to its TCP peer, and any
// X-Forwarded-For header is ignored, because the client could have written
// it. A request from a trusted proxy is attributed to the last address in
// X-Forwarded-For, which is the one the proxy added itself. The second result
// is false when no usable address is available.
func clientAddress(r *http.Request, trustedProxies []netip.Prefix) (netip.Addr, bool) {
	host, _, err := net.SplitHostPort(r.RemoteAddr)
	if err != nil {
		host = r.RemoteAddr
	}
	peer, err := netip.ParseAddr(host)
	if err != nil {
		return netip.Addr{}, false
	}
	peer = peer.Unmap().WithZone("")
	if !trusted(trustedProxies, peer) {
		return peer, true
	}
	values := r.Header.Values("X-Forwarded-For")
	if len(values) == 0 {
		return netip.Addr{}, false
	}
	entries := strings.Split(values[len(values)-1], ",")
	client, err := netip.ParseAddr(strings.TrimSpace(entries[len(entries)-1]))
	if err != nil {
		return netip.Addr{}, false
	}
	return client.Unmap().WithZone(""), true
}

// checkPeer applies the configured peer binding mode to an authenticated
// request from the given student.
func checkPeer(r *http.Request, cfg config, student string) error {
	if cfg.peerBinding == peerBindingOff || cfg.peerLookup == nil {
		return nil
	}
	client, haveClient := clientAddress(r, cfg.trustedProxies)
	registered, isRegistered, err := cfg.peerLookup(r.Context(), student)
	if err != nil {
		log.Printf("peer binding: student=%s: look up registered address: %v", student, err)
		if cfg.peerBinding == peerBindingEnforce {
			return errPeerLookup
		}
		return nil
	}
	if isRegistered && haveClient && client == registered {
		return nil
	}
	var reason error
	switch {
	case !isRegistered:
		reason = errPeerUnregistered
	default:
		reason = errPeerMismatch
	}
	seen := "unknown"
	if haveClient {
		seen = client.String()
	}
	log.Printf("peer binding: student=%s client=%s registered=%v: %v", student, seen, isRegistered && registered.IsValid(), reason)
	if cfg.peerBinding == peerBindingEnforce {
		return reason
	}
	return nil
}
