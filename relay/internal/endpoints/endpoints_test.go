package endpoints

import (
	"crypto/ed25519"
	"crypto/rand"
	"testing"
)

func TestSignVerifyRoundTrip(t *testing.T) {
	pub, priv, _ := ed25519.GenerateKey(rand.Reader)
	list := RealmEndpointList{
		Version:             Version,
		RealmID:             make([]byte, 32),
		Sequence:            3,
		RealmNoisePublicKey: make([]byte, 32),
		Endpoints:           []Endpoint{{Kind: KindLAN, URL: "ws://127.0.0.1:8447/v1/channel", Priority: 0}},
	}
	signed, err := Sign(list, priv)
	if err != nil {
		t.Fatal(err)
	}
	got, err := Verify(signed, pub)
	if err != nil {
		t.Fatal(err)
	}
	if got.Sequence != 3 || len(got.Endpoints) != 1 || got.Endpoints[0].URL != list.Endpoints[0].URL {
		t.Fatalf("round trip mismatch: %+v", got)
	}

	other, _, _ := ed25519.GenerateKey(rand.Reader)
	if _, err := Verify(signed, other); err == nil {
		t.Fatal("verified with the wrong key")
	}
	tampered := append([]byte(nil), signed...)
	tampered[len(tampered)-1] ^= 1
	if _, err := Verify(tampered, pub); err == nil {
		t.Fatal("verified a tampered object")
	}
}
