// Package channel implements the relay side of the carrier-independent
// device↔realm channel (ADR-008): a Noise IK session carrying CBOR frames,
// fragmented into Noise messages of at most 65 535 bytes. It mirrors
// arveil-core's `channel` module byte for byte; the Rust test vectors in
// codec_test.go are the contract.
package channel

import (
	"crypto/rand"
	"errors"
	"fmt"

	"github.com/flynn/noise"
)

// ProtocolName is fixed for V1 and shared with arveil-core.
const ProtocolName = "Noise_IK_25519_ChaChaPoly_BLAKE2s"

// ProtocolVersion is the wire protocol major version (see relay/internal/version).
const ProtocolVersion uint16 = 0

const (
	// MaxNoiseMessage is the Noise spec limit for one message.
	MaxNoiseMessage = noise.MaxMsgLen
	// MaxNoisePayload is the largest payload of one transport message.
	MaxNoisePayload = MaxNoiseMessage - 16
)

var (
	ErrPayloadTooLarge      = errors.New("noise: payload exceeds one message")
	ErrUnexpectedPayload    = errors.New("noise: handshake message carried unexpected payload")
	ErrHandshakeNotFinished = errors.New("noise: handshake not finished")
)

var suite = noise.NewCipherSuite(noise.DH25519, noise.CipherChaChaPoly, noise.HashBLAKE2s)

// Prologue binds protocol version and realm identity, exactly as arveil-core does.
func Prologue(realmID []byte) []byte {
	p := []byte(fmt.Sprintf("arveil/%d/", ProtocolVersion))
	return append(p, realmID...)
}

// GenerateStaticKeypair returns a fresh X25519 keypair for the channel.
func GenerateStaticKeypair() (noise.DHKey, error) {
	return suite.GenerateKeypair(rand.Reader)
}

// StaticKeypairFromPrivate rebuilds a keypair from a stored 32-byte private key.
func StaticKeypairFromPrivate(private []byte) (noise.DHKey, error) {
	if len(private) != 32 {
		return noise.DHKey{}, fmt.Errorf("noise: private key must be 32 bytes, got %d", len(private))
	}
	// X25519 public key derivation via the suite's DH with the base point is
	// not exposed by flynn/noise; use x/crypto's curve25519 through DH25519.
	pub, err := x25519Public(private)
	if err != nil {
		return noise.DHKey{}, err
	}
	return noise.DHKey{Private: append([]byte(nil), private...), Public: pub}, nil
}

// Responder is the realm side of the IK handshake.
type Responder struct {
	hs *noise.HandshakeState
}

// NewResponder prepares to answer one initiator.
func NewResponder(static noise.DHKey, prologue []byte) (*Responder, error) {
	hs, err := noise.NewHandshakeState(noise.Config{
		CipherSuite:   suite,
		Pattern:       noise.HandshakeIK,
		Initiator:     false,
		Prologue:      prologue,
		StaticKeypair: static,
	})
	if err != nil {
		return nil, err
	}
	return &Responder{hs: hs}, nil
}

// ReadMessage1 consumes the initiator's first message and returns its static
// public key. Nothing is authenticated for the initiator yet: the caller
// decides whether to answer at all, and processes no frame until a transport
// message opens.
func (r *Responder) ReadMessage1(message []byte) (initiatorStatic []byte, err error) {
	payload, _, _, err := r.hs.ReadMessage(nil, message)
	if err != nil {
		return nil, err
	}
	if len(payload) != 0 {
		return nil, ErrUnexpectedPayload
	}
	return append([]byte(nil), r.hs.PeerStatic()...), nil
}

// WriteMessage2 produces the responder's message and the established transport.
func (r *Responder) WriteMessage2() (message []byte, t *Transport, err error) {
	// flynn/noise returns, once the handshake completes, the CipherState for
	// initiator→responder first and responder→initiator second.
	out, csI2R, csR2I, err := r.hs.WriteMessage(nil, nil)
	if err != nil {
		return nil, nil, err
	}
	if csI2R == nil || csR2I == nil {
		return nil, nil, ErrHandshakeNotFinished
	}
	return out, &Transport{
		enc:          csR2I,
		dec:          csI2R,
		remoteStatic: append([]byte(nil), r.hs.PeerStatic()...),
	}, nil
}

// Initiator is the device side; the relay only needs it for tests and
// for talking to other relays in the future.
type Initiator struct {
	hs *noise.HandshakeState
}

func NewInitiator(static noise.DHKey, remoteStatic, prologue []byte) (*Initiator, error) {
	hs, err := noise.NewHandshakeState(noise.Config{
		CipherSuite:   suite,
		Pattern:       noise.HandshakeIK,
		Initiator:     true,
		Prologue:      prologue,
		StaticKeypair: static,
		PeerStatic:    remoteStatic,
	})
	if err != nil {
		return nil, err
	}
	return &Initiator{hs: hs}, nil
}

func (i *Initiator) WriteMessage1() ([]byte, error) {
	out, _, _, err := i.hs.WriteMessage(nil, nil)
	return out, err
}

func (i *Initiator) ReadMessage2(message []byte) (*Transport, error) {
	payload, csI2R, csR2I, err := i.hs.ReadMessage(nil, message)
	if err != nil {
		return nil, err
	}
	if len(payload) != 0 {
		return nil, ErrUnexpectedPayload
	}
	if csI2R == nil || csR2I == nil {
		return nil, ErrHandshakeNotFinished
	}
	return &Transport{
		enc:          csI2R,
		dec:          csR2I,
		remoteStatic: append([]byte(nil), i.hs.PeerStatic()...),
	}, nil
}

// Transport is an established session. One Seal produces one wire message.
type Transport struct {
	enc, dec     *noise.CipherState
	remoteStatic []byte
}

// RemoteStatic is the peer's static public key authenticated by the handshake.
func (t *Transport) RemoteStatic() []byte { return t.remoteStatic }

func (t *Transport) Seal(payload []byte) ([]byte, error) {
	if len(payload) > MaxNoisePayload {
		return nil, ErrPayloadTooLarge
	}
	return t.enc.Encrypt(nil, nil, payload)
}

func (t *Transport) Open(message []byte) ([]byte, error) {
	if len(message) > MaxNoiseMessage {
		return nil, ErrPayloadTooLarge
	}
	return t.dec.Decrypt(nil, nil, message)
}
