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
	KindPing             = "Ping"
	KindPong             = "Pong"
	KindEndpointListGet  = "EndpointListGet"
	KindEndpointList     = "EndpointList"
	KindInviteRedeem     = "InviteRedeem"
	KindInviteRedeemed   = "InviteRedeemed"
	KindCredentialPut    = "CredentialPut"
	KindManifestPut      = "ManifestPut"
	KindManifestGet      = "ManifestGet"
	KindRecoverIdentity  = "RecoverIdentity"
	KindPairBegin        = "PairBegin"
	KindPairStarted      = "PairStarted"
	KindPairPut          = "PairPut"
	KindPairGet          = "PairGet"
	KindPairFetched      = "PairFetched"
	KindRecovered        = "Recovered"
	KindManifestLatest   = "ManifestLatest"
	KindAck              = "Ack"
	KindError            = "Error"
	KindMailboxCreate    = "MailboxCreate"
	KindMailboxCreated   = "MailboxCreated"
	KindEnvelopePut      = "EnvelopePut"
	KindEnvelopeAccepted = "EnvelopeAccepted"
	KindEnvelopeFetch    = "EnvelopeFetch"
	KindEnvelopes        = "Envelopes"
	KindEnvelopeAck      = "EnvelopeAck"
)

// Error codes carried in Error frames (mirrors arveil-core codec::error_code).
const (
	CodeBadRequest   uint16 = 400
	CodeUnauthorized uint16 = 401
	CodeForbidden    uint16 = 403
	CodeConflict     uint16 = 409
	CodeGone         uint16 = 410
	CodeTooLarge     uint16 = 413
	CodeQuota        uint16 = 429
	CodeInternal     uint16 = 500
)

// EnvelopeItem is one queued envelope in an Envelopes reply.
type EnvelopeItem struct {
	Seq        uint64 `cbor:"seq"`
	DeliveryID []byte `cbor:"delivery_id"`
	HpkeEnc    []byte `cbor:"hpke_enc"`
	Ciphertext []byte `cbor:"ciphertext"`
}

// Blob frames (PROTOCOL §7).
const (
	KindBlobUploadBegin   = "BlobUploadBegin"
	KindBlobUploadStarted = "BlobUploadStarted"
	KindBlobChunk         = "BlobChunk"
	KindBlobCommit        = "BlobCommit"
	KindBlobCommitted     = "BlobCommitted"
	KindBlobFetch         = "BlobFetch"
	KindBlobData          = "BlobData"
)

// KeyPackage frames (PROTOCOL §5).
const (
	KindKeyPackagesPublish = "KeyPackagesPublish"
	KindKeyPackagesClaim   = "KeyPackagesClaim"
	KindKeyPackageClaimed  = "KeyPackageClaimed"
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
	// InviteRedeemed / KeyPackagesClaim
	IdentityID []byte
	DeviceID   []byte
	// Mailbox and envelope frames
	MailboxID        []byte
	ReadCapability   []byte
	WriteCapability  []byte
	DeliveryID       []byte
	RequestedExpiry  uint64
	EffectiveExpiry  uint64
	HpkeEnc          []byte
	Ciphertext       []byte
	Cursor           uint64
	PreviousSequence uint64
	// Pairing rendezvous
	PairID      []byte
	Capability  []byte
	Slot        string
	ExpiresAt   uint64
	NextCursor  uint64
	Limit       uint16
	Items       []EnvelopeItem
	DeliveryIDs [][]byte
	// KeyPackages
	KeyPackages [][]byte
	KeyPackage  []byte
	// Blobs
	Size           uint64
	BlobID         []byte
	Offset         uint64
	Data           []byte
	CiphertextHash []byte
	Length         uint32
	TotalSize      uint64
}

type blobUploadBeginBody struct {
	Size uint64 `cbor:"size"`
}

type blobUploadStartedBody struct {
	BlobID         []byte `cbor:"blob_id"`
	ReadCapability []byte `cbor:"read_capability"`
}

type blobChunkBody struct {
	BlobID []byte `cbor:"blob_id"`
	Offset uint64 `cbor:"offset"`
	Data   []byte `cbor:"data"`
}

type blobCommitBody struct {
	BlobID          []byte `cbor:"blob_id"`
	CiphertextHash  []byte `cbor:"ciphertext_hash"`
	RequestedExpiry uint64 `cbor:"requested_expiry"`
}

type blobCommittedBody struct {
	EffectiveExpiry uint64 `cbor:"effective_expiry"`
}

type blobFetchBody struct {
	BlobID         []byte `cbor:"blob_id"`
	ReadCapability []byte `cbor:"read_capability"`
	Offset         uint64 `cbor:"offset"`
	Length         uint32 `cbor:"length"`
}

type blobDataBody struct {
	TotalSize uint64 `cbor:"total_size"`
	Data      []byte `cbor:"data"`
}

type keyPackagesPublishBody struct {
	KeyPackages [][]byte `cbor:"key_packages"`
}

type keyPackagesClaimBody struct {
	IdentityID []byte `cbor:"identity_id"`
	DeviceID   []byte `cbor:"device_id"`
}

type keyPackageClaimedBody struct {
	KeyPackage []byte `cbor:"key_package"`
}

type mailboxCreatedBody struct {
	MailboxID       []byte `cbor:"mailbox_id"`
	ReadCapability  []byte `cbor:"read_capability"`
	WriteCapability []byte `cbor:"write_capability"`
}

type envelopePutBody struct {
	MailboxID       []byte `cbor:"mailbox_id"`
	WriteCapability []byte `cbor:"write_capability"`
	DeliveryID      []byte `cbor:"delivery_id"`
	RequestedExpiry uint64 `cbor:"requested_expiry"`
	HpkeEnc         []byte `cbor:"hpke_enc"`
	Ciphertext      []byte `cbor:"ciphertext"`
}

type envelopeAcceptedBody struct {
	EffectiveExpiry uint64 `cbor:"effective_expiry"`
}

type envelopeFetchBody struct {
	MailboxID      []byte `cbor:"mailbox_id"`
	ReadCapability []byte `cbor:"read_capability"`
	Cursor         uint64 `cbor:"cursor"`
	Limit          uint16 `cbor:"limit"`
}

type envelopesBody struct {
	Items      []EnvelopeItem `cbor:"items"`
	NextCursor uint64         `cbor:"next_cursor"`
}

type envelopeAckBody struct {
	MailboxID      []byte   `cbor:"mailbox_id"`
	ReadCapability []byte   `cbor:"read_capability"`
	DeliveryIDs    [][]byte `cbor:"delivery_ids"`
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

type pairStartedBody struct {
	PairID     []byte `cbor:"pair_id"`
	Capability []byte `cbor:"capability"`
	ExpiresAt  uint64 `cbor:"expires_at"`
}

type pairPutBody struct {
	PairID     []byte `cbor:"pair_id"`
	Capability []byte `cbor:"capability"`
	Slot       string `cbor:"slot"`
	Data       []byte `cbor:"data"`
}

type pairGetBody struct {
	PairID     []byte `cbor:"pair_id"`
	Capability []byte `cbor:"capability"`
	Slot       string `cbor:"slot"`
}

type pairFetchedBody struct {
	Data []byte `cbor:"data"`
}

type recoverIdentityBody struct {
	Credential []byte `cbor:"credential"`
	Manifest   []byte `cbor:"manifest"`
}

type recoveredBody struct {
	IdentityID       []byte `cbor:"identity_id"`
	PreviousSequence uint64 `cbor:"previous_sequence"`
}

type manifestGetBody struct {
	IdentityID []byte `cbor:"identity_id"`
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
	case KindPing, KindPong, KindEndpointListGet, KindAck, KindMailboxCreate, KindPairBegin:
		payload = f.Payload.Kind
	case KindPairStarted:
		payload = map[string]pairStartedBody{KindPairStarted: {PairID: f.Payload.PairID, Capability: f.Payload.Capability, ExpiresAt: f.Payload.ExpiresAt}}
	case KindPairPut:
		payload = map[string]pairPutBody{KindPairPut: {PairID: f.Payload.PairID, Capability: f.Payload.Capability, Slot: f.Payload.Slot, Data: nonNil(f.Payload.Data)}}
	case KindPairGet:
		payload = map[string]pairGetBody{KindPairGet: {PairID: f.Payload.PairID, Capability: f.Payload.Capability, Slot: f.Payload.Slot}}
	case KindPairFetched:
		payload = map[string]pairFetchedBody{KindPairFetched: {Data: nonNil(f.Payload.Data)}}
	case KindBlobUploadBegin:
		payload = map[string]blobUploadBeginBody{KindBlobUploadBegin: {Size: f.Payload.Size}}
	case KindBlobUploadStarted:
		payload = map[string]blobUploadStartedBody{KindBlobUploadStarted: {BlobID: f.Payload.BlobID, ReadCapability: f.Payload.ReadCapability}}
	case KindBlobChunk:
		payload = map[string]blobChunkBody{KindBlobChunk: {BlobID: f.Payload.BlobID, Offset: f.Payload.Offset, Data: f.Payload.Data}}
	case KindBlobCommit:
		payload = map[string]blobCommitBody{KindBlobCommit: {BlobID: f.Payload.BlobID, CiphertextHash: f.Payload.CiphertextHash, RequestedExpiry: f.Payload.RequestedExpiry}}
	case KindBlobCommitted:
		payload = map[string]blobCommittedBody{KindBlobCommitted: {EffectiveExpiry: f.Payload.EffectiveExpiry}}
	case KindBlobFetch:
		payload = map[string]blobFetchBody{KindBlobFetch: {BlobID: f.Payload.BlobID, ReadCapability: f.Payload.ReadCapability, Offset: f.Payload.Offset, Length: f.Payload.Length}}
	case KindBlobData:
		payload = map[string]blobDataBody{KindBlobData: {TotalSize: f.Payload.TotalSize, Data: f.Payload.Data}}
	case KindKeyPackagesPublish:
		kps := f.Payload.KeyPackages
		if kps == nil {
			kps = [][]byte{}
		}
		payload = map[string]keyPackagesPublishBody{KindKeyPackagesPublish: {KeyPackages: kps}}
	case KindKeyPackagesClaim:
		payload = map[string]keyPackagesClaimBody{KindKeyPackagesClaim: {IdentityID: f.Payload.IdentityID, DeviceID: f.Payload.DeviceID}}
	case KindKeyPackageClaimed:
		payload = map[string]keyPackageClaimedBody{KindKeyPackageClaimed: {KeyPackage: f.Payload.KeyPackage}}
	case KindMailboxCreated:
		payload = map[string]mailboxCreatedBody{KindMailboxCreated: {MailboxID: f.Payload.MailboxID, ReadCapability: f.Payload.ReadCapability, WriteCapability: f.Payload.WriteCapability}}
	case KindEnvelopePut:
		payload = map[string]envelopePutBody{KindEnvelopePut: {MailboxID: f.Payload.MailboxID, WriteCapability: f.Payload.WriteCapability, DeliveryID: f.Payload.DeliveryID, RequestedExpiry: f.Payload.RequestedExpiry, HpkeEnc: f.Payload.HpkeEnc, Ciphertext: f.Payload.Ciphertext}}
	case KindEnvelopeAccepted:
		payload = map[string]envelopeAcceptedBody{KindEnvelopeAccepted: {EffectiveExpiry: f.Payload.EffectiveExpiry}}
	case KindEnvelopeFetch:
		payload = map[string]envelopeFetchBody{KindEnvelopeFetch: {MailboxID: f.Payload.MailboxID, ReadCapability: f.Payload.ReadCapability, Cursor: f.Payload.Cursor, Limit: f.Payload.Limit}}
	case KindEnvelopes:
		items := f.Payload.Items
		if items == nil {
			items = []EnvelopeItem{}
		}
		payload = map[string]envelopesBody{KindEnvelopes: {Items: items, NextCursor: f.Payload.NextCursor}}
	case KindEnvelopeAck:
		ids := f.Payload.DeliveryIDs
		if ids == nil {
			ids = [][]byte{}
		}
		payload = map[string]envelopeAckBody{KindEnvelopeAck: {MailboxID: f.Payload.MailboxID, ReadCapability: f.Payload.ReadCapability, DeliveryIDs: ids}}
	case KindInviteRedeem:
		payload = map[string]inviteRedeemBody{KindInviteRedeem: {Token: f.Payload.Token, Credential: f.Payload.Credential, Manifest: f.Payload.Manifest}}
	case KindInviteRedeemed:
		payload = map[string]inviteRedeemedBody{KindInviteRedeemed: {IdentityID: f.Payload.IdentityID}}
	case KindCredentialPut:
		payload = map[string]credentialPutBody{KindCredentialPut: {Credential: f.Payload.Credential}}
	case KindManifestPut:
		payload = map[string]manifestPutBody{KindManifestPut: {Manifest: f.Payload.Manifest}}
	case KindManifestGet:
		payload = map[string]manifestGetBody{KindManifestGet: {IdentityID: f.Payload.IdentityID}}
	case KindRecoverIdentity:
		payload = map[string]recoverIdentityBody{KindRecoverIdentity: {Credential: f.Payload.Credential, Manifest: f.Payload.Manifest}}
	case KindRecovered:
		payload = map[string]recoveredBody{KindRecovered: {IdentityID: f.Payload.IdentityID, PreviousSequence: f.Payload.PreviousSequence}}
	case KindManifestLatest:
		payload = map[string]manifestPutBody{KindManifestLatest: {Manifest: nonNil(f.Payload.Manifest)}}
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
		case KindPing, KindPong, KindEndpointListGet, KindAck, KindMailboxCreate, KindPairBegin:
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
		case KindPairStarted:
			var v pairStartedBody
			if err := cbor.Unmarshal(body, &v); err != nil {
				return Frame{}, fmt.Errorf("codec: %s: %w", name, err)
			}
			f.Payload = Payload{Kind: name, PairID: v.PairID, Capability: v.Capability, ExpiresAt: v.ExpiresAt}
		case KindPairPut:
			var v pairPutBody
			if err := cbor.Unmarshal(body, &v); err != nil {
				return Frame{}, fmt.Errorf("codec: %s: %w", name, err)
			}
			f.Payload = Payload{Kind: name, PairID: v.PairID, Capability: v.Capability, Slot: v.Slot, Data: v.Data}
		case KindPairGet:
			var v pairGetBody
			if err := cbor.Unmarshal(body, &v); err != nil {
				return Frame{}, fmt.Errorf("codec: %s: %w", name, err)
			}
			f.Payload = Payload{Kind: name, PairID: v.PairID, Capability: v.Capability, Slot: v.Slot}
		case KindPairFetched:
			var v pairFetchedBody
			if err := cbor.Unmarshal(body, &v); err != nil {
				return Frame{}, fmt.Errorf("codec: %s: %w", name, err)
			}
			f.Payload = Payload{Kind: name, Data: v.Data}
		case KindRecoverIdentity:
			var v recoverIdentityBody
			if err := cbor.Unmarshal(body, &v); err != nil {
				return Frame{}, fmt.Errorf("codec: %s: %w", name, err)
			}
			f.Payload = Payload{Kind: name, Credential: v.Credential, Manifest: v.Manifest}
		case KindRecovered:
			var v recoveredBody
			if err := cbor.Unmarshal(body, &v); err != nil {
				return Frame{}, fmt.Errorf("codec: %s: %w", name, err)
			}
			f.Payload = Payload{Kind: name, IdentityID: v.IdentityID, PreviousSequence: v.PreviousSequence}
		case KindManifestGet:
			var v manifestGetBody
			if err := cbor.Unmarshal(body, &v); err != nil {
				return Frame{}, fmt.Errorf("codec: %s: %w", name, err)
			}
			f.Payload = Payload{Kind: name, IdentityID: v.IdentityID}
		case KindManifestPut, KindManifestLatest:
			var v manifestPutBody
			if err := cbor.Unmarshal(body, &v); err != nil {
				return Frame{}, fmt.Errorf("codec: %s: %w", name, err)
			}
			f.Payload = Payload{Kind: name, Manifest: v.Manifest}
		case KindBlobUploadBegin:
			var v blobUploadBeginBody
			if err := cbor.Unmarshal(body, &v); err != nil {
				return Frame{}, fmt.Errorf("codec: %s: %w", name, err)
			}
			f.Payload = Payload{Kind: name, Size: v.Size}
		case KindBlobUploadStarted:
			var v blobUploadStartedBody
			if err := cbor.Unmarshal(body, &v); err != nil {
				return Frame{}, fmt.Errorf("codec: %s: %w", name, err)
			}
			f.Payload = Payload{Kind: name, BlobID: v.BlobID, ReadCapability: v.ReadCapability}
		case KindBlobChunk:
			var v blobChunkBody
			if err := cbor.Unmarshal(body, &v); err != nil {
				return Frame{}, fmt.Errorf("codec: %s: %w", name, err)
			}
			f.Payload = Payload{Kind: name, BlobID: v.BlobID, Offset: v.Offset, Data: v.Data}
		case KindBlobCommit:
			var v blobCommitBody
			if err := cbor.Unmarshal(body, &v); err != nil {
				return Frame{}, fmt.Errorf("codec: %s: %w", name, err)
			}
			f.Payload = Payload{Kind: name, BlobID: v.BlobID, CiphertextHash: v.CiphertextHash, RequestedExpiry: v.RequestedExpiry}
		case KindBlobCommitted:
			var v blobCommittedBody
			if err := cbor.Unmarshal(body, &v); err != nil {
				return Frame{}, fmt.Errorf("codec: %s: %w", name, err)
			}
			f.Payload = Payload{Kind: name, EffectiveExpiry: v.EffectiveExpiry}
		case KindBlobFetch:
			var v blobFetchBody
			if err := cbor.Unmarshal(body, &v); err != nil {
				return Frame{}, fmt.Errorf("codec: %s: %w", name, err)
			}
			f.Payload = Payload{Kind: name, BlobID: v.BlobID, ReadCapability: v.ReadCapability, Offset: v.Offset, Length: v.Length}
		case KindBlobData:
			var v blobDataBody
			if err := cbor.Unmarshal(body, &v); err != nil {
				return Frame{}, fmt.Errorf("codec: %s: %w", name, err)
			}
			f.Payload = Payload{Kind: name, TotalSize: v.TotalSize, Data: v.Data}
		case KindKeyPackagesPublish:
			var v keyPackagesPublishBody
			if err := cbor.Unmarshal(body, &v); err != nil {
				return Frame{}, fmt.Errorf("codec: %s: %w", name, err)
			}
			f.Payload = Payload{Kind: name, KeyPackages: v.KeyPackages}
		case KindKeyPackagesClaim:
			var v keyPackagesClaimBody
			if err := cbor.Unmarshal(body, &v); err != nil {
				return Frame{}, fmt.Errorf("codec: %s: %w", name, err)
			}
			f.Payload = Payload{Kind: name, IdentityID: v.IdentityID, DeviceID: v.DeviceID}
		case KindKeyPackageClaimed:
			var v keyPackageClaimedBody
			if err := cbor.Unmarshal(body, &v); err != nil {
				return Frame{}, fmt.Errorf("codec: %s: %w", name, err)
			}
			f.Payload = Payload{Kind: name, KeyPackage: v.KeyPackage}
		case KindMailboxCreated:
			var v mailboxCreatedBody
			if err := cbor.Unmarshal(body, &v); err != nil {
				return Frame{}, fmt.Errorf("codec: %s: %w", name, err)
			}
			f.Payload = Payload{Kind: name, MailboxID: v.MailboxID, ReadCapability: v.ReadCapability, WriteCapability: v.WriteCapability}
		case KindEnvelopePut:
			var v envelopePutBody
			if err := cbor.Unmarshal(body, &v); err != nil {
				return Frame{}, fmt.Errorf("codec: %s: %w", name, err)
			}
			f.Payload = Payload{Kind: name, MailboxID: v.MailboxID, WriteCapability: v.WriteCapability, DeliveryID: v.DeliveryID, RequestedExpiry: v.RequestedExpiry, HpkeEnc: v.HpkeEnc, Ciphertext: v.Ciphertext}
		case KindEnvelopeAccepted:
			var v envelopeAcceptedBody
			if err := cbor.Unmarshal(body, &v); err != nil {
				return Frame{}, fmt.Errorf("codec: %s: %w", name, err)
			}
			f.Payload = Payload{Kind: name, EffectiveExpiry: v.EffectiveExpiry}
		case KindEnvelopeFetch:
			var v envelopeFetchBody
			if err := cbor.Unmarshal(body, &v); err != nil {
				return Frame{}, fmt.Errorf("codec: %s: %w", name, err)
			}
			f.Payload = Payload{Kind: name, MailboxID: v.MailboxID, ReadCapability: v.ReadCapability, Cursor: v.Cursor, Limit: v.Limit}
		case KindEnvelopes:
			var v envelopesBody
			if err := cbor.Unmarshal(body, &v); err != nil {
				return Frame{}, fmt.Errorf("codec: %s: %w", name, err)
			}
			f.Payload = Payload{Kind: name, Items: v.Items, NextCursor: v.NextCursor}
		case KindEnvelopeAck:
			var v envelopeAckBody
			if err := cbor.Unmarshal(body, &v); err != nil {
				return Frame{}, fmt.Errorf("codec: %s: %w", name, err)
			}
			f.Payload = Payload{Kind: name, MailboxID: v.MailboxID, ReadCapability: v.ReadCapability, DeliveryIDs: v.DeliveryIDs}
		default:
			return Frame{}, fmt.Errorf("codec: unknown variant %q", name)
		}
	}
	return f, nil
}

// nonNil makes an absent byte string encode as an empty one, never as null.
func nonNil(b []byte) []byte {
	if b == nil {
		return []byte{}
	}
	return b
}
