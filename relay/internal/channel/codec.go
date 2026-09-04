package channel

import (
	"errors"
	"fmt"

	"github.com/fxamacker/cbor/v2"
)

// MaxFrameBytes bounds one encoded frame; checked before decoding.
const MaxFrameBytes = 1024 * 1024

// Frame kinds, named exactly as the Rust `Payload` enum variants: on the
// wire a unit variant is a text string and a struct variant is a one-entry
// map keyed by the variant name (serde's externally tagged representation).
const (
	KindPing            = "Ping"
	KindPong            = "Pong"
	KindEndpointListGet = "EndpointListGet"
	KindEndpointList    = "EndpointList"
	KindInviteRedeem    = "InviteRedeem"
	KindInviteRedeemed  = "InviteRedeemed"
	KindCredentialPut   = "CredentialPut"
	KindManifestPut     = "ManifestPut"
	KindAck             = "Ack"
	KindError           = "Error"
)

// Error codes carried in Error frames (mirrors arveil-core codec::error_code).
const (
	CodeBadRequest   uint16 = 400
	CodeUnauthorized uint16 = 401
	CodeForbidden    uint16 = 403
	CodeConflict     uint16 = 409
	CodeGone         uint16 = 410
	CodeInternal     uint16 = 500
)

var ErrFrameTooLarge = errors.New("codec: frame exceeds the size limit")

// Frame is `{ id, payload }`.
type Frame struct {
	ID      uint64
	Payload Payload
}

// Payload holds the kind and the variant fields that apply to it.
type Payload struct {
	Kind string
	// EndpointList
	Signed []byte
	// Error
	Code    uint16
	Message string
	// InviteRedeem / CredentialPut / ManifestPut
	Token      []byte
	Credential []byte
	Manifest   []byte
	// InviteRedeemed
	IdentityID []byte
}

type inviteRedeemBody struct {
	Token      []byte `cbor:"token"`
	Credential []byte `cbor:"credential"`
	Manifest   []byte `cbor:"manifest"`
}

type inviteRedeemedBody struct {
	IdentityID []byte `cbor:"identity_id"`
}

type credentialPutBody struct {
	Credential []byte `cbor:"credential"`
}

type manifestPutBody struct {
	Manifest []byte `cbor:"manifest"`
}

type endpointListBody struct {
	Signed []byte `cbor:"signed"`
}

type errorBody struct {
	Code    uint16 `cbor:"code"`
	Message string `cbor:"message"`
}

type wireFrame struct {
	ID      uint64          `cbor:"id"`
	Payload cbor.RawMessage `cbor:"payload"`
}

var encMode cbor.EncMode

func init() {
	var err error
	encMode, err = cbor.CoreDetEncOptions().EncMode()
	if err != nil {
		panic(err)
	}
}

// Encode a frame; refuses frames over MaxFrameBytes.
func Encode(f Frame) ([]byte, error) {
	var payload any
	switch f.Payload.Kind {
	case KindPing, KindPong, KindEndpointListGet, KindAck:
		payload = f.Payload.Kind
	case KindInviteRedeem:
		payload = map[string]inviteRedeemBody{KindInviteRedeem: {Token: f.Payload.Token, Credential: f.Payload.Credential, Manifest: f.Payload.Manifest}}
	case KindInviteRedeemed:
		payload = map[string]inviteRedeemedBody{KindInviteRedeemed: {IdentityID: f.Payload.IdentityID}}
	case KindCredentialPut:
		payload = map[string]credentialPutBody{KindCredentialPut: {Credential: f.Payload.Credential}}
	case KindManifestPut:
		payload = map[string]manifestPutBody{KindManifestPut: {Manifest: f.Payload.Manifest}}
	case KindEndpointList:
		payload = map[string]endpointListBody{KindEndpointList: {Signed: f.Payload.Signed}}
	case KindError:
		payload = map[string]errorBody{KindError: {Code: f.Payload.Code, Message: f.Payload.Message}}
	default:
		return nil, fmt.Errorf("codec: unknown frame kind %q", f.Payload.Kind)
	}
	raw, err := encMode.Marshal(payload)
	if err != nil {
		return nil, err
	}
	out, err := encMode.Marshal(wireFrame{ID: f.ID, Payload: raw})
	if err != nil {
		return nil, err
	}
	if len(out) > MaxFrameBytes {
		return nil, ErrFrameTooLarge
	}
	return out, nil
}

// Decode a frame; refuses inputs over MaxFrameBytes before parsing.
func Decode(b []byte) (Frame, error) {
	if len(b) > MaxFrameBytes {
		return Frame{}, ErrFrameTooLarge
	}
	var w wireFrame
	if err := cbor.Unmarshal(b, &w); err != nil {
		return Frame{}, fmt.Errorf("codec: %w", err)
	}
	f := Frame{ID: w.ID}

	// Unit variant: a text string.
	var kind string
	if err := cbor.Unmarshal(w.Payload, &kind); err == nil {
		switch kind {
		case KindPing, KindPong, KindEndpointListGet, KindAck:
			f.Payload.Kind = kind
			return f, nil
		}
		return Frame{}, fmt.Errorf("codec: unknown unit variant %q", kind)
	}

	// Struct variant: one-entry map keyed by the variant name.
	var tagged map[string]cbor.RawMessage
	if err := cbor.Unmarshal(w.Payload, &tagged); err != nil {
		return Frame{}, fmt.Errorf("codec: payload is neither a variant name nor a tagged map: %w", err)
	}
	if len(tagged) != 1 {
		return Frame{}, fmt.Errorf("codec: tagged payload must have exactly one entry, got %d", len(tagged))
	}
	for name, body := range tagged {
		switch name {
		case KindEndpointList:
			var v endpointListBody
			if err := cbor.Unmarshal(body, &v); err != nil {
				return Frame{}, fmt.Errorf("codec: %s: %w", name, err)
			}
			f.Payload = Payload{Kind: name, Signed: v.Signed}
		case KindError:
			var v errorBody
			if err := cbor.Unmarshal(body, &v); err != nil {
				return Frame{}, fmt.Errorf("codec: %s: %w", name, err)
			}
			f.Payload = Payload{Kind: name, Code: v.Code, Message: v.Message}
		case KindInviteRedeem:
			var v inviteRedeemBody
			if err := cbor.Unmarshal(body, &v); err != nil {
				return Frame{}, fmt.Errorf("codec: %s: %w", name, err)
			}
			f.Payload = Payload{Kind: name, Token: v.Token, Credential: v.Credential, Manifest: v.Manifest}
		case KindInviteRedeemed:
			var v inviteRedeemedBody
			if err := cbor.Unmarshal(body, &v); err != nil {
				return Frame{}, fmt.Errorf("codec: %s: %w", name, err)
			}
			f.Payload = Payload{Kind: name, IdentityID: v.IdentityID}
		case KindCredentialPut:
			var v credentialPutBody
			if err := cbor.Unmarshal(body, &v); err != nil {
				return Frame{}, fmt.Errorf("codec: %s: %w", name, err)
			}
			f.Payload = Payload{Kind: name, Credential: v.Credential}
		case KindManifestPut:
			var v manifestPutBody
			if err := cbor.Unmarshal(body, &v); err != nil {
				return Frame{}, fmt.Errorf("codec: %s: %w", name, err)
			}
			f.Payload = Payload{Kind: name, Manifest: v.Manifest}
		default:
			return Frame{}, fmt.Errorf("codec: unknown variant %q", name)
		}
	}
	return f, nil
}
