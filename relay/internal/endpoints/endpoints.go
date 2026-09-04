// Package endpoints builds and signs the RealmEndpointList (ADR-008).
//
// Wire format, shared with arveil-core's `channel::endpoints`:
//
//	SignedObject { context: tstr, body: bstr, signature: bstr(64) }
//	signature = Ed25519( u16be(len(context)) || context || body )
//	body      = deterministic CBOR of RealmEndpointList
package endpoints

import (
	"crypto/ed25519"
	"encoding/binary"
	"fmt"

	"github.com/fxamacker/cbor/v2"
)

// Context is the domain-separation string for endpoint list signatures.
const Context = "arveil/endpoint-list/v1"

// Version of the RealmEndpointList body.
const Version uint8 = 1

// Endpoint kinds. "admin" endpoints accept administrative frames only.
const (
	KindLAN     = "lan"
	KindTailnet = "tailnet"
	KindPublic  = "public"
	KindAdmin   = "admin"
)

type Endpoint struct {
	Kind     string `cbor:"kind"`
	URL      string `cbor:"url"`
	Priority uint8  `cbor:"priority"`
}

type RealmEndpointList struct {
	Version             uint8      `cbor:"version"`
	RealmID             []byte     `cbor:"realm_id"`
	Sequence            uint64     `cbor:"sequence"`
	RealmNoisePublicKey []byte     `cbor:"realm_noise_public_key"`
	Endpoints           []Endpoint `cbor:"endpoints"`
}

type SignedObject struct {
	Context   string `cbor:"context"`
	Body      []byte `cbor:"body"`
	Signature []byte `cbor:"signature"`
}

var det cbor.EncMode

func init() {
	var err error
	det, err = cbor.CoreDetEncOptions().EncMode()
	if err != nil {
		panic(err)
	}
}

// SigningInput is what the signature covers.
func SigningInput(context string, body []byte) []byte {
	out := make([]byte, 2, 2+len(context)+len(body))
	binary.BigEndian.PutUint16(out, uint16(len(context)))
	out = append(out, context...)
	return append(out, body...)
}

// Sign encodes and signs the list. Returns the SignedObject bytes.
func Sign(list RealmEndpointList, key ed25519.PrivateKey) ([]byte, error) {
	if list.Version != Version {
		return nil, fmt.Errorf("endpoints: unsupported version %d", list.Version)
	}
	body, err := det.Marshal(list)
	if err != nil {
		return nil, err
	}
	sig := ed25519.Sign(key, SigningInput(Context, body))
	return det.Marshal(SignedObject{Context: Context, Body: body, Signature: sig})
}

// Verify checks a SignedObject against the realm signing key and returns the list.
func Verify(signed []byte, pub ed25519.PublicKey) (RealmEndpointList, error) {
	var so SignedObject
	if err := cbor.Unmarshal(signed, &so); err != nil {
		return RealmEndpointList{}, fmt.Errorf("endpoints: %w", err)
	}
	if so.Context != Context {
		return RealmEndpointList{}, fmt.Errorf("endpoints: wrong context %q", so.Context)
	}
	if !ed25519.Verify(pub, SigningInput(so.Context, so.Body), so.Signature) {
		return RealmEndpointList{}, fmt.Errorf("endpoints: bad signature")
	}
	var list RealmEndpointList
	if err := cbor.Unmarshal(so.Body, &list); err != nil {
		return RealmEndpointList{}, fmt.Errorf("endpoints: body: %w", err)
	}
	if list.Version != Version {
		return RealmEndpointList{}, fmt.Errorf("endpoints: unsupported version %d", list.Version)
	}
	return list, nil
}
