// Package identity verifies device credentials and manifests on the relay.
// It mirrors arveil-core's `identity` and `signed` modules: same contexts,
// same hashes, same signing input. The relay never issues identity; it only
// checks that what a device presents is consistently signed by a root and,
// for credentials, that the Noise static key of the session is the one the
// root authorized.
package identity

import (
	"crypto/ed25519"
	"crypto/sha256"
	"encoding/binary"
	"errors"
	"fmt"

	"github.com/fxamacker/cbor/v2"
)

const (
	CredentialContext = "arveil/device-credential/v1"
	ManifestContext   = "arveil/device-manifest/v1"

	identityIDContext     = "arveil/identity-id/v1"
	credentialHashContext = "arveil/credential-hash/v1"
	manifestHashContext   = "arveil/manifest-hash/v1"

	CredentialVersion uint8 = 1
	ManifestVersion   uint8 = 1

	UseMLSLeaf   uint8 = 0b001
	UseTransport uint8 = 0b010
	UseEnvelope  uint8 = 0b100
)

var (
	ErrBadSignature   = errors.New("identity: bad signature")
	ErrWrongContext   = errors.New("identity: wrong context")
	ErrVersion        = errors.New("identity: unsupported version")
	ErrNotValidNow    = errors.New("identity: credential not valid now")
	ErrIdentityID     = errors.New("identity: manifest identity id does not match the root")
	ErrTransportKey   = errors.New("identity: credential transport key does not match the session")
	ErrNoTransportUse = errors.New("identity: credential does not allow transport use")
)

type SignedObject struct {
	Context   string `cbor:"context"`
	Body      []byte `cbor:"body"`
	Signature []byte `cbor:"signature"`
}

type Validity struct {
	NotBefore uint64 `cbor:"not_before"`
	NotAfter  uint64 `cbor:"not_after"`
}

type DeviceCredential struct {
	Version                 uint8    `cbor:"version"`
	IdentityRootPublicKey   []byte   `cbor:"identity_root_public_key"`
	DeviceID                []byte   `cbor:"device_id"`
	MLSSignaturePublicKey   []byte   `cbor:"mls_signature_public_key"`
	TransportNoisePublicKey []byte   `cbor:"transport_noise_public_key"`
	EnvelopeHPKEPublicKey   []byte   `cbor:"envelope_hpke_public_key"`
	Validity                Validity `cbor:"validity"`
	AllowedUses             uint8    `cbor:"allowed_uses"`
}

type DeviceManifest struct {
	Version                 uint8    `cbor:"version"`
	IdentityID              []byte   `cbor:"identity_id"`
	ManifestSequence        uint64   `cbor:"manifest_sequence"`
	PreviousManifestHash    []byte   `cbor:"previous_manifest_hash"`
	ActiveCredentialHashes  [][]byte `cbor:"active_credential_hashes"`
	RevokedCredentialHashes [][]byte `cbor:"revoked_credential_hashes"`
}

func hash(context string, data []byte) []byte {
	h := sha256.New()
	h.Write([]byte(context))
	h.Write(data)
	return h.Sum(nil)
}

func IdentityID(root ed25519.PublicKey) []byte { return hash(identityIDContext, root) }
func CredentialHash(signed []byte) []byte      { return hash(credentialHashContext, signed) }
func ManifestHash(signed []byte) []byte        { return hash(manifestHashContext, signed) }

// SigningInput is u16be(len(context)) || context || body.
func SigningInput(context string, body []byte) []byte {
	out := make([]byte, 2, 2+len(context)+len(body))
	binary.BigEndian.PutUint16(out, uint16(len(context)))
	out = append(out, context...)
	return append(out, body...)
}

func open(signed []byte, context string, key ed25519.PublicKey) ([]byte, error) {
	var so SignedObject
	if err := cbor.Unmarshal(signed, &so); err != nil {
		return nil, fmt.Errorf("identity: decode: %w", err)
	}
	if so.Context != context {
		return nil, ErrWrongContext
	}
	if len(key) != ed25519.PublicKeySize || !ed25519.Verify(key, SigningInput(so.Context, so.Body), so.Signature) {
		return nil, ErrBadSignature
	}
	return so.Body, nil
}

// VerifiedCredential is a credential whose root signature checked out.
type VerifiedCredential struct {
	Credential DeviceCredential
	Root       ed25519.PublicKey
	IdentityID []byte
	Hash       []byte
}

// VerifyCredential reads the root from the body, checks the signature against
// it and the validity window at `now` (Unix seconds).
func VerifyCredential(signed []byte, now uint64) (*VerifiedCredential, error) {
	var so SignedObject
	if err := cbor.Unmarshal(signed, &so); err != nil {
		return nil, fmt.Errorf("identity: decode: %w", err)
	}
	var c DeviceCredential
	if err := cbor.Unmarshal(so.Body, &c); err != nil {
		return nil, fmt.Errorf("identity: credential body: %w", err)
	}
	if c.Version != CredentialVersion {
		return nil, ErrVersion
	}
	root := ed25519.PublicKey(c.IdentityRootPublicKey)
	if _, err := open(signed, CredentialContext, root); err != nil {
		return nil, err
	}
	if now < c.Validity.NotBefore || now > c.Validity.NotAfter {
		return nil, ErrNotValidNow
	}
	return &VerifiedCredential{Credential: c, Root: root, IdentityID: IdentityID(root), Hash: CredentialHash(signed)}, nil
}

// BindsSession checks that the credential authorizes transport with the
// Noise static key seen in the handshake.
func (v *VerifiedCredential) BindsSession(remoteStatic []byte) error {
	if v.Credential.AllowedUses&UseTransport == 0 {
		return ErrNoTransportUse
	}
	if string(v.Credential.TransportNoisePublicKey) != string(remoteStatic) {
		return ErrTransportKey
	}
	return nil
}

// VerifyManifest checks the manifest's signature against `root` and that it
// belongs to that root's identity.
func VerifyManifest(signed []byte, root ed25519.PublicKey) (*DeviceManifest, error) {
	body, err := open(signed, ManifestContext, root)
	if err != nil {
		return nil, err
	}
	var m DeviceManifest
	if err := cbor.Unmarshal(body, &m); err != nil {
		return nil, fmt.Errorf("identity: manifest body: %w", err)
	}
	if m.Version != ManifestVersion {
		return nil, ErrVersion
	}
	if string(m.IdentityID) != string(IdentityID(root)) {
		return nil, ErrIdentityID
	}
	return &m, nil
}
