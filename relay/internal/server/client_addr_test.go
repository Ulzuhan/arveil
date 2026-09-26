package server

import (
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/Ulzuhan/arveil/relay/internal/limits"
)

func request(remote string, forwarded ...string) *http.Request {
	r := httptest.NewRequest(http.MethodGet, ChannelPath, nil)
	r.RemoteAddr = remote
	for _, value := range forwarded {
		r.Header.Add("X-Forwarded-For", value)
	}
	return r
}

func TestForwardedForIsIgnoredUnlessTrusted(t *testing.T) {
	s := &Server{}
	if got := s.clientAddr(request("192.0.2.5:40000", "198.51.100.7")); got != "192.0.2.5" {
		t.Fatalf("untrusted header used: %q", got)
	}
}

func TestTrustedProxyEntryIsTheLastOne(t *testing.T) {
	s := &Server{TrustForwardedFor: true}
	for _, c := range []struct {
		name      string
		forwarded []string
		want      string
	}{
		{"single entry", []string{"198.51.100.7"}, "198.51.100.7"},
		{"client prepends an address of its choice", []string{"203.0.113.9, 198.51.100.7"}, "198.51.100.7"},
		{"several header lines", []string{"203.0.113.9", "192.0.2.44, 198.51.100.7"}, "198.51.100.7"},
		{"not an address falls back to the peer", []string{"198.51.100.7, unknown"}, "127.0.0.1"},
		{"empty falls back to the peer", []string{""}, "127.0.0.1"},
		{"no header uses the peer", nil, "127.0.0.1"},
	} {
		t.Run(c.name, func(t *testing.T) {
			if got := s.clientAddr(request("127.0.0.1:50000", c.forwarded...)); got != c.want {
				t.Fatalf("got %q, want %q", got, c.want)
			}
		})
	}
}

func TestIPv6AddressesShareTheirSlash64(t *testing.T) {
	s := &Server{TrustForwardedFor: true}
	a := s.clientAddr(request("[2001:db8:1:2::10]:443"))
	b := s.clientAddr(request("[2001:db8:1:2:ffff:ffff:ffff:1]:443"))
	c := s.clientAddr(request("[2001:db8:1:3::10]:443"))
	if a != "2001:db8:1:2::/64" || a != b || a == c {
		t.Fatalf("got %q, %q, %q", a, b, c)
	}
	if got := s.clientAddr(request("127.0.0.1:1", "2001:db8:1:2::99")); got != a {
		t.Fatalf("forwarded IPv6 got %q, want %q", got, a)
	}
	if got := s.clientAddr(request("[::ffff:192.0.2.5]:443")); got != "192.0.2.5" {
		t.Fatalf("IPv4-mapped got %q", got)
	}
	if got := s.clientAddr(request("[fe80::1%eth0]:443")); got != "fe80::/64" {
		t.Fatalf("zoned got %q", got)
	}

	// One address's connection limit now covers its whole /64.
	gate := limits.New(limits.Config{MaxPerAddr: 1})
	if _, ok := gate.Acquire(a); !ok {
		t.Fatal("first connection refused")
	}
	if _, ok := gate.Acquire(b); ok {
		t.Fatal("a second address in the same /64 escaped the limit")
	}
	if _, ok := gate.Acquire(c); !ok {
		t.Fatal("another /64 was refused")
	}
}
