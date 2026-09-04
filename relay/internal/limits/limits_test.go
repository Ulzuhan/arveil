package limits

import (
	"testing"
	"time"
)

func TestOneAddressCannotTakeEverything(t *testing.T) {
	g := New(Config{MaxTotal: 3, MaxPerAddr: 2, PairingsPerAddr: 2, PairingWindow: time.Minute})
	r1, ok := g.Acquire("a")
	if !ok {
		t.Fatal("first refused")
	}
	if _, ok := g.Acquire("a"); !ok {
		t.Fatal("second refused")
	}
	if _, ok := g.Acquire("a"); ok {
		t.Fatal("third from the same address accepted")
	}
	// Another address still gets in, which is the whole point.
	if _, ok := g.Acquire("b"); !ok {
		t.Fatal("another address refused")
	}
	if g.Active() != 3 {
		t.Fatalf("active %d", g.Active())
	}
	// Releasing frees the slot, and releasing twice does not corrupt it.
	r1()
	r1()
	if g.Active() != 2 {
		t.Fatalf("after release %d", g.Active())
	}
	if _, ok := g.Acquire("a"); !ok {
		t.Fatal("slot not freed")
	}
}

func TestPairingWindowSlides(t *testing.T) {
	g := New(Config{PairingsPerAddr: 2, PairingWindow: time.Minute})
	now := time.Now()
	if !g.AllowPairing("a", now) || !g.AllowPairing("a", now) {
		t.Fatal("first two refused")
	}
	if g.AllowPairing("a", now) {
		t.Fatal("third within the window accepted")
	}
	if !g.AllowPairing("b", now) {
		t.Fatal("another address refused")
	}
	if !g.AllowPairing("a", now.Add(2*time.Minute)) {
		t.Fatal("the window never slides")
	}
}

func TestZeroGateAllowsEverything(t *testing.T) {
	var g *Gate
	if _, ok := g.Acquire("a"); !ok {
		t.Fatal("nil gate refused a connection")
	}
	if !g.AllowPairing("a", time.Now()) {
		t.Fatal("nil gate refused a pairing")
	}
}
