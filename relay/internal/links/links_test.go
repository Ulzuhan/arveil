package links

import (
	"bytes"
	"crypto/ed25519"
	"strings"
	"testing"
)

func fill(n int, b byte) []byte { return bytes.Repeat([]byte{b}, n) }

// joinVector is the payload the Rust client produces for the same inputs
// (links::tests::the_relay_and_the_client_write_the_same_join_payload).
const joinVector = "pmN1cmx4IndzczovL3JlbGF5LmV4YW1wbGUub3JnL3YxL2NoYW5uZWxka2luZGRqb2luZ3ZlcnNpb24Bamludml0YXRpb25YIAEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBb3JlYWxtX25vaXNlX2tleVggCAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAhxcmVhbG1fc2lnbmluZ19rZXlYIP0XJDhaoMdbZPt4zWAvodmR_ev3axPFjtcC6sg16fYY"

func TestJoinPayloadMatchesTheClient(t *testing.T) {
	signing := ed25519.NewKeyFromSeed(fill(32, 9)).Public().(ed25519.PublicKey)
	got, err := JoinPayload(signing, fill(32, 8), "wss://relay.example.org/v1/channel", fill(32, 1))
	if err != nil {
		t.Fatal(err)
	}
	if got != joinVector {
		t.Fatalf("payload differs from the client's:\n got %s\nwant %s", got, joinVector)
	}
	if l := Link(DefaultBase+"/", "join", got); l != "https://arveil.kaicorplabs.com/join#"+got {
		t.Fatalf("link: %s", l)
	}
}

func TestJoinPayloadRefusesWhatTheClientWouldRefuse(t *testing.T) {
	signing := ed25519.NewKeyFromSeed(fill(32, 9)).Public().(ed25519.PublicKey)
	for _, c := range []struct {
		noise, token []byte
		url          string
	}{
		{fill(31, 8), fill(32, 1), "wss://x/v1/channel"},
		{fill(32, 8), fill(16, 1), "wss://x/v1/channel"},
		{fill(32, 8), fill(32, 1), "https://x/v1/channel"},
	} {
		if _, err := JoinPayload(signing, c.noise, c.url, c.token); err == nil {
			t.Fatalf("accepted %d-byte noise key, %d-byte token, url %s", len(c.noise), len(c.token), c.url)
		}
	}
}

func TestTerminalQRIsSquareWithAQuietZone(t *testing.T) {
	out, err := TerminalQR("https://arveil.kaicorplabs.com/join#abc")
	if err != nil {
		t.Fatal(err)
	}
	lines := strings.Split(strings.TrimSuffix(out, "\n"), "\n")
	width := len([]rune(strings.TrimSuffix(strings.TrimPrefix(lines[0], "\x1b[30;47m"), "\x1b[0m")))
	if width < 25 || len(lines) != (width+1)/2 {
		t.Fatalf("%d lines of %d cells", len(lines), width)
	}
	if strings.TrimSpace(strings.TrimSuffix(strings.TrimPrefix(lines[0], "\x1b[30;47m"), "\x1b[0m")) != "" {
		t.Fatalf("the first row is not quiet: %q", lines[0])
	}
}
