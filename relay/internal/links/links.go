// Package links builds the join links of ADR-012 §2: one https link, or the
// QR code of that link, that gives a new person the realm and the invitation
// at once.
//
// The payload is the deterministic CBOR map the Rust client reads
// (core/crates/arveil-app/src/links.rs), base64url without padding. It sits
// in the URL fragment, which browsers never send to the web server, so the
// invitation reaches no web server log.
package links

import (
	"encoding/base64"
	"fmt"
	"strings"

	"github.com/fxamacker/cbor/v2"
	"rsc.io/qr"
)

// DefaultBase is where links point unless the relay is given another page.
const DefaultBase = "https://arveil.kaicorplabs.com"

// Version of the payload format.
const Version = 1

// MaxPayloadBytes matches the client's limit: a larger payload is refused
// before it is parsed.
const MaxPayloadBytes = 600

type joinPayload struct {
	Version         uint8  `cbor:"version"`
	Kind            string `cbor:"kind"`
	RealmSigningKey []byte `cbor:"realm_signing_key"`
	RealmNoiseKey   []byte `cbor:"realm_noise_key"`
	URL             string `cbor:"url"`
	Invitation      []byte `cbor:"invitation"`
}

var encMode cbor.EncMode

func init() {
	var err error
	encMode, err = cbor.CoreDetEncOptions().EncMode()
	if err != nil {
		panic(err)
	}
}

// JoinPayload encodes the realm and a 32-byte invitation token.
func JoinPayload(signingPublic, noisePublic []byte, url string, token []byte) (string, error) {
	if len(signingPublic) != 32 || len(noisePublic) != 32 || len(token) != 32 {
		return "", fmt.Errorf("links: keys and invitation must be 32 bytes")
	}
	if !strings.HasPrefix(url, "ws://") && !strings.HasPrefix(url, "wss://") {
		return "", fmt.Errorf("links: the endpoint %q is not a ws:// or wss:// URL", url)
	}
	b, err := encMode.Marshal(joinPayload{
		Version:         Version,
		Kind:            "join",
		RealmSigningKey: signingPublic,
		RealmNoiseKey:   noisePublic,
		URL:             url,
		Invitation:      token,
	})
	if err != nil {
		return "", err
	}
	if len(b) > MaxPayloadBytes {
		return "", fmt.Errorf("links: payload of %d bytes exceeds %d", len(b), MaxPayloadBytes)
	}
	return base64.RawURLEncoding.EncodeToString(b), nil
}

// Link puts a payload behind a page: base/kind#payload.
func Link(base, kind, payload string) string {
	return strings.TrimRight(base, "/") + "/" + kind + "#" + payload
}

// TerminalQR draws text as a QR code for a terminal: two modules per
// character cell with half blocks, black on white whatever the terminal's
// own colours, with a quiet zone of two modules.
func TerminalQR(text string) (string, error) {
	code, err := qr.Encode(text, qr.M)
	if err != nil {
		return "", err
	}
	const quiet = 2
	var b strings.Builder
	for y := -quiet; y < code.Size+quiet; y += 2 {
		b.WriteString("\x1b[30;47m")
		for x := -quiet; x < code.Size+quiet; x++ {
			top, bottom := code.Black(x, y), code.Black(x, y+1)
			switch {
			case top && bottom:
				b.WriteString("█")
			case top:
				b.WriteString("▀")
			case bottom:
				b.WriteString("▄")
			default:
				b.WriteString(" ")
			}
		}
		b.WriteString("\x1b[0m\n")
	}
	return b.String(), nil
}
