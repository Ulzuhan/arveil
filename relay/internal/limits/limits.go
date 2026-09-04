// Package limits bounds what one address can take from the realm.
//
// Quotas elsewhere are per mailbox and per identity, which only bind once
// somebody is a member. The pairing rendezvous is the one surface a
// stranger can touch (PROTOCOL §8), so it needs a bound that applies before
// anyone is authenticated: otherwise one address opens rendezvous until the
// global cap is reached and nobody else can pair.
//
// Addresses are held in memory only, never written to the database and
// never logged: a refusal says that a limit bit, not who hit it.
package limits

import (
	"sync"
	"time"
)

// Config is what an operator can tune.
type Config struct {
	// MaxTotal bounds concurrent channels on the whole relay.
	MaxTotal int
	// MaxPerAddr bounds concurrent channels from one address.
	MaxPerAddr int
	// PairingsPerAddr bounds rendezvous opened from one address within
	// PairingWindow.
	PairingsPerAddr int
	PairingWindow   time.Duration
}

// Default values sized for a family realm behind a home connection.
func Default() Config {
	return Config{
		MaxTotal:        256,
		MaxPerAddr:      8,
		PairingsPerAddr: 4,
		PairingWindow:   10 * time.Minute,
	}
}

// Gate applies a Config. The zero value allows everything, which is what
// tests that do not care about limits want.
type Gate struct {
	cfg Config

	mu       sync.Mutex
	total    int
	perAddr  map[string]int
	pairings map[string][]time.Time
}

func New(cfg Config) *Gate {
	return &Gate{cfg: cfg, perAddr: map[string]int{}, pairings: map[string][]time.Time{}}
}

// Acquire takes one connection slot for addr. The returned release must be
// called when the channel ends; ok is false when a limit refused it.
func (g *Gate) Acquire(addr string) (release func(), ok bool) {
	if g == nil {
		return func() {}, true
	}
	g.mu.Lock()
	defer g.mu.Unlock()
	if g.cfg.MaxTotal > 0 && g.total >= g.cfg.MaxTotal {
		return nil, false
	}
	if g.cfg.MaxPerAddr > 0 && g.perAddr[addr] >= g.cfg.MaxPerAddr {
		return nil, false
	}
	g.total++
	g.perAddr[addr]++
	var once sync.Once
	return func() {
		once.Do(func() {
			g.mu.Lock()
			defer g.mu.Unlock()
			g.total--
			if n := g.perAddr[addr] - 1; n > 0 {
				g.perAddr[addr] = n
			} else {
				delete(g.perAddr, addr)
			}
		})
	}, true
}

// AllowPairing reports whether addr may open another rendezvous now.
func (g *Gate) AllowPairing(addr string, now time.Time) bool {
	if g == nil || g.cfg.PairingsPerAddr <= 0 {
		return true
	}
	g.mu.Lock()
	defer g.mu.Unlock()
	cutoff := now.Add(-g.cfg.PairingWindow)
	kept := g.pairings[addr][:0]
	for _, t := range g.pairings[addr] {
		if t.After(cutoff) {
			kept = append(kept, t)
		}
	}
	if len(kept) >= g.cfg.PairingsPerAddr {
		g.pairings[addr] = kept
		return false
	}
	g.pairings[addr] = append(kept, now)
	return true
}

// Active reports the current connection count, for metrics.
func (g *Gate) Active() int {
	if g == nil {
		return 0
	}
	g.mu.Lock()
	defer g.mu.Unlock()
	return g.total
}
