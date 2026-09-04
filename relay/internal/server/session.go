package server

import (
	"context"
	"crypto/sha256"
	"errors"
	"time"

	"github.com/Ulzuhan/arveil/relay/internal/channel"
	"github.com/Ulzuhan/arveil/relay/internal/identity"
	"github.com/Ulzuhan/arveil/relay/internal/store"
)

// session is the authorization state of one channel.
//
// A connection whose Noise static key is unknown is *provisional*: it may
// only redeem an invite, fetch the endpoint list and ping. Once the static
// key maps to an active credential the session is a *member* session.
type session struct {
	remoteStatic []byte
	device       *store.Device // nil while provisional
}

func (s *session) member() bool { return s.device != nil }

// authorize decides whether to answer message 1 at all: revoked or expired
// credentials are refused before message 2 (nothing is processed for them).
func (srv *Server) authorize(ctx context.Context, remoteStatic []byte, now time.Time) (*session, error) {
	if srv.Store == nil {
		return &session{remoteStatic: remoteStatic}, nil
	}
	d, err := srv.Store.DeviceByTransportKey(ctx, remoteStatic)
	if err != nil {
		return nil, err
	}
	if d != nil && (d.Status != "active" || d.NotAfter < now.Unix()) {
		return nil, errors.New("credential revoked or expired")
	}
	return &session{remoteStatic: remoteStatic, device: d}, nil
}

func errFrame(id uint64, code uint16, msg string) channel.Frame {
	return channel.Frame{ID: id, Payload: channel.Payload{Kind: channel.KindError, Code: code, Message: msg}}
}

func (srv *Server) dispatchSession(ctx context.Context, s *session, f channel.Frame, now time.Time) channel.Frame {
	switch f.Payload.Kind {
	case channel.KindPing:
		return channel.Frame{ID: f.ID, Payload: channel.Payload{Kind: channel.KindPong}}
	case channel.KindEndpointListGet:
		return channel.Frame{ID: f.ID, Payload: channel.Payload{Kind: channel.KindEndpointList, Signed: srv.SignedList}}
	case channel.KindInviteRedeem:
		return srv.inviteRedeem(ctx, s, f, now)
	case channel.KindCredentialPut:
		return srv.credentialPut(ctx, s, f, now)
	case channel.KindManifestPut:
		return srv.manifestPut(ctx, s, f)
	case channel.KindManifestGet:
		return srv.manifestGet(ctx, s, f)
	case channel.KindRecoverIdentity:
		return srv.recoverIdentity(ctx, s, f, now)
	case channel.KindPairBegin:
		return srv.pairBegin(ctx, f, now)
	case channel.KindPairPut:
		return srv.pairPut(ctx, f, now)
	case channel.KindPairGet:
		return srv.pairGet(ctx, f, now)
	case channel.KindBlobUploadBegin:
		return srv.blobUploadBegin(ctx, s, f, now)
	case channel.KindBlobChunk:
		return srv.blobChunk(ctx, s, f)
	case channel.KindBlobCommit:
		return srv.blobCommit(ctx, s, f, now)
	case channel.KindBlobFetch:
		return srv.blobFetch(ctx, s, f, now)
	case channel.KindBlobResume:
		return srv.blobResume(ctx, s, f)
	case channel.KindKeyPackagesPublish:
		return srv.keyPackagesPublish(ctx, s, f, now)
	case channel.KindKeyPackagesClaim:
		return srv.keyPackagesClaim(ctx, s, f)
	case channel.KindMailboxCreate:
		return srv.mailboxCreate(ctx, s, f, now)
	case channel.KindEnvelopePut:
		return srv.envelopePut(ctx, s, f, now)
	case channel.KindEnvelopeFetch:
		return srv.envelopeFetch(ctx, s, f, now)
	case channel.KindEnvelopeAck:
		return srv.envelopeAck(ctx, s, f, now)
	default:
		return errFrame(f.ID, channel.CodeBadRequest, "unsupported frame")
	}
}

func (srv *Server) inviteRedeem(ctx context.Context, s *session, f channel.Frame, now time.Time) channel.Frame {
	if srv.Store == nil {
		return errFrame(f.ID, channel.CodeInternal, "no store")
	}
	if s.member() {
		return errFrame(f.ID, channel.CodeConflict, "session is already a member")
	}
	v, err := identity.VerifyCredential(f.Payload.Credential, uint64(now.Unix()))
	if err != nil {
		return errFrame(f.ID, channel.CodeUnauthorized, "credential rejected")
	}
	// The root authorized exactly this session's Noise key for transport.
	if err := v.BindsSession(s.remoteStatic); err != nil {
		return errFrame(f.ID, channel.CodeUnauthorized, "credential does not bind this session")
	}
	m, err := identity.VerifyManifest(f.Payload.Manifest, v.Root)
	if err != nil {
		return errFrame(f.ID, channel.CodeUnauthorized, "manifest rejected")
	}
	if m.ManifestSequence != 1 || !containsHash(m.ActiveCredentialHashes, v.Hash) || len(m.PreviousManifestHash) != 0 {
		return errFrame(f.ID, channel.CodeBadRequest, "first manifest must be sequence 1 and list the credential")
	}
	tokenHash := sha256.Sum256(f.Payload.Token)
	err = srv.Store.RedeemInvite(ctx, tokenHash[:], now, store.Enrollment{
		IdentityID:     v.IdentityID,
		RootPublic:     v.Root,
		CredentialHash: v.Hash,
		DeviceID:       v.Credential.DeviceID,
		TransportKey:   v.Credential.TransportNoisePublicKey,
		SignedCred:     f.Payload.Credential,
		NotAfter:       int64(v.Credential.Validity.NotAfter),
		ManifestSeq:    m.ManifestSequence,
		SignedManifest: f.Payload.Manifest,
	}, nil)
	switch {
	case errors.Is(err, store.ErrInviteInvalid):
		return errFrame(f.ID, channel.CodeGone, "invite invalid")
	case errors.Is(err, store.ErrAlreadyMember), errors.Is(err, store.ErrDeviceKeyInUse):
		return errFrame(f.ID, channel.CodeConflict, "already enrolled")
	case err != nil:
		srv.Logger.Printf("invite redeem: store error")
		return errFrame(f.ID, channel.CodeInternal, "store error")
	}
	s.device = &store.Device{
		CredentialHash: v.Hash,
		IdentityID:     v.IdentityID,
		DeviceID:       v.Credential.DeviceID,
		Status:         "active",
		NotAfter:       int64(v.Credential.Validity.NotAfter),
	}
	return channel.Frame{ID: f.ID, Payload: channel.Payload{Kind: channel.KindInviteRedeemed, IdentityID: v.IdentityID}}
}

func (srv *Server) credentialPut(ctx context.Context, s *session, f channel.Frame, now time.Time) channel.Frame {
	if !s.member() {
		return errFrame(f.ID, channel.CodeUnauthorized, "not a member session")
	}
	v, err := identity.VerifyCredential(f.Payload.Credential, uint64(now.Unix()))
	if err != nil {
		return errFrame(f.ID, channel.CodeUnauthorized, "credential rejected")
	}
	root, err := srv.Store.RootPublic(ctx, s.device.IdentityID)
	if err != nil || string(root) != string(v.Root) {
		return errFrame(f.ID, channel.CodeForbidden, "credential is not signed by this member's root")
	}
	// Enrollment is never silent: the newest manifest, signed by the root,
	// must already list this credential as active.
	seq, signed, err := srv.Store.LatestManifest(ctx, s.device.IdentityID)
	if err != nil || signed == nil {
		return errFrame(f.ID, channel.CodeBadRequest, "no manifest for this identity")
	}
	m, err := identity.VerifyManifest(signed, root)
	if err != nil || !containsHash(m.ActiveCredentialHashes, v.Hash) {
		return errFrame(f.ID, channel.CodeBadRequest, "credential not listed active in the newest manifest")
	}
	err = srv.Store.PutCredential(ctx, store.Enrollment{
		IdentityID:     v.IdentityID,
		CredentialHash: v.Hash,
		DeviceID:       v.Credential.DeviceID,
		TransportKey:   v.Credential.TransportNoisePublicKey,
		SignedCred:     f.Payload.Credential,
		NotAfter:       int64(v.Credential.Validity.NotAfter),
	})
	if errors.Is(err, store.ErrDeviceKeyInUse) {
		return errFrame(f.ID, channel.CodeConflict, "transport key already registered")
	}
	if err != nil {
		return errFrame(f.ID, channel.CodeInternal, "store error")
	}
	srv.Logger.Printf("device linked: identity %x device %x under manifest %d", s.device.IdentityID[:4], v.Credential.DeviceID[:4], seq)
	return channel.Frame{ID: f.ID, Payload: channel.Payload{Kind: channel.KindAck}}
}

func (srv *Server) manifestPut(ctx context.Context, s *session, f channel.Frame) channel.Frame {
	if !s.member() {
		return errFrame(f.ID, channel.CodeUnauthorized, "not a member session")
	}
	root, err := srv.Store.RootPublic(ctx, s.device.IdentityID)
	if err != nil {
		return errFrame(f.ID, channel.CodeForbidden, "unknown member")
	}
	m, err := identity.VerifyManifest(f.Payload.Manifest, root)
	if err != nil {
		return errFrame(f.ID, channel.CodeUnauthorized, "manifest rejected")
	}
	err = srv.Store.PutManifest(ctx, s.device.IdentityID, m.ManifestSequence, f.Payload.Manifest)
	if errors.Is(err, store.ErrManifestOrder) {
		return errFrame(f.ID, channel.CodeConflict, "manifest sequence not increasing")
	}
	if err != nil {
		return errFrame(f.ID, channel.CodeInternal, "store error")
	}
	revoked, err := srv.Store.RevokeCredentials(ctx, s.device.IdentityID, m.RevokedCredentialHashes)
	if err != nil {
		return errFrame(f.ID, channel.CodeInternal, "store error")
	}
	srv.Logger.Printf("manifest %d for identity %x: %d active, %d revoked (%d newly revoked)", m.ManifestSequence, s.device.IdentityID[:4], len(m.ActiveCredentialHashes), len(m.RevokedCredentialHashes), revoked)
	return channel.Frame{ID: f.ID, Payload: channel.Payload{Kind: channel.KindAck}}
}

// Pairing rendezvous (M3.1). A provisional session may use these frames:
// the device being paired has no credential yet. The capability is the only
// authorization, and the realm never learns what the blobs mean.
func (srv *Server) pairBegin(ctx context.Context, f channel.Frame, now time.Time) channel.Frame {
	if srv.Store == nil {
		return errFrame(f.ID, channel.CodeInternal, "no store")
	}
	id, capability, expires, err := srv.Store.BeginPair(ctx, now, srv.PairTTL)
	if errors.Is(err, store.ErrPairBusy) {
		return errFrame(f.ID, channel.CodeQuota, "too many pairings in progress")
	}
	if err != nil {
		return errFrame(f.ID, channel.CodeInternal, "store error")
	}
	return channel.Frame{ID: f.ID, Payload: channel.Payload{
		Kind: channel.KindPairStarted, PairID: id, Capability: capability, ExpiresAt: uint64(expires),
	}}
}

func pairError(id uint64, err error) (channel.Frame, bool) {
	switch {
	case errors.Is(err, store.ErrPairUnknown):
		return errFrame(id, channel.CodeGone, "unknown rendezvous, wrong capability or expired"), true
	case errors.Is(err, store.ErrPairSlot):
		return errFrame(id, channel.CodeBadRequest, "unknown slot"), true
	case errors.Is(err, store.ErrPairSize):
		return errFrame(id, channel.CodeTooLarge, "payload too large for a rendezvous slot"), true
	case errors.Is(err, store.ErrPairTaken):
		return errFrame(id, channel.CodeConflict, "that slot already holds different bytes"), true
	case err != nil:
		return errFrame(id, channel.CodeInternal, "store error"), true
	}
	return channel.Frame{}, false
}

func (srv *Server) pairPut(ctx context.Context, f channel.Frame, now time.Time) channel.Frame {
	if srv.Store == nil {
		return errFrame(f.ID, channel.CodeInternal, "no store")
	}
	err := srv.Store.PutPair(ctx, f.Payload.PairID, f.Payload.Capability, f.Payload.Slot, f.Payload.Data, now)
	if frame, bad := pairError(f.ID, err); bad {
		return frame
	}
	return channel.Frame{ID: f.ID, Payload: channel.Payload{Kind: channel.KindAck}}
}

func (srv *Server) pairGet(ctx context.Context, f channel.Frame, now time.Time) channel.Frame {
	if srv.Store == nil {
		return errFrame(f.ID, channel.CodeInternal, "no store")
	}
	data, err := srv.Store.GetPair(ctx, f.Payload.PairID, f.Payload.Capability, f.Payload.Slot, now)
	if frame, bad := pairError(f.ID, err); bad {
		return frame
	}
	return channel.Frame{ID: f.ID, Payload: channel.Payload{Kind: channel.KindPairFetched, Data: data}}
}

// recoverIdentity is the only way a provisional session becomes a member
// without an invite (ADR-006): possession of the identity's root is the
// authorization, and the realm only checks that the chain it already holds
// is advanced, never rolled back.
func (srv *Server) recoverIdentity(ctx context.Context, s *session, f channel.Frame, now time.Time) channel.Frame {
	if srv.Store == nil {
		return errFrame(f.ID, channel.CodeInternal, "no store")
	}
	if s.member() {
		return errFrame(f.ID, channel.CodeConflict, "session is already a member")
	}
	v, err := identity.VerifyCredential(f.Payload.Credential, uint64(now.Unix()))
	if err != nil {
		return errFrame(f.ID, channel.CodeUnauthorized, "credential rejected")
	}
	if err := v.BindsSession(s.remoteStatic); err != nil {
		return errFrame(f.ID, channel.CodeUnauthorized, "credential does not bind this session")
	}
	root, err := srv.Store.RootPublic(ctx, v.IdentityID)
	if err != nil {
		return errFrame(f.ID, channel.CodeForbidden, "unknown identity")
	}
	if string(root) != string(v.Root) {
		return errFrame(f.ID, channel.CodeForbidden, "credential is not signed by this identity's root")
	}
	m, err := identity.VerifyManifest(f.Payload.Manifest, root)
	if err != nil {
		return errFrame(f.ID, channel.CodeUnauthorized, "manifest rejected")
	}
	if !containsHash(m.ActiveCredentialHashes, v.Hash) {
		return errFrame(f.ID, channel.CodeBadRequest, "manifest does not list the new credential as active")
	}
	previous, err := srv.Store.RecoverIdentity(ctx, store.Enrollment{
		IdentityID:     v.IdentityID,
		CredentialHash: v.Hash,
		DeviceID:       v.Credential.DeviceID,
		TransportKey:   v.Credential.TransportNoisePublicKey,
		SignedCred:     f.Payload.Credential,
		NotAfter:       int64(v.Credential.Validity.NotAfter),
		ManifestSeq:    m.ManifestSequence,
		SignedManifest: f.Payload.Manifest,
	}, m.RevokedCredentialHashes)
	switch {
	case errors.Is(err, store.ErrManifestOrder):
		return errFrame(f.ID, channel.CodeConflict, "the realm holds a newer manifest for this identity")
	case errors.Is(err, store.ErrDeviceKeyInUse):
		return errFrame(f.ID, channel.CodeConflict, "transport key already registered")
	case err != nil:
		return errFrame(f.ID, channel.CodeInternal, "store error")
	}
	s.device = &store.Device{
		CredentialHash: v.Hash,
		IdentityID:     v.IdentityID,
		DeviceID:       v.Credential.DeviceID,
		Status:         "active",
		NotAfter:       int64(v.Credential.Validity.NotAfter),
	}
	srv.Logger.Printf("identity recovered: %x now on device %x, manifest %d (was %d)", v.IdentityID[:4], v.Credential.DeviceID[:4], m.ManifestSequence, previous)
	return channel.Frame{ID: f.ID, Payload: channel.Payload{
		Kind: channel.KindRecovered, IdentityID: v.IdentityID, PreviousSequence: previous,
	}}
}

// manifestGet returns the newest manifest the realm holds for an identity,
// so members can learn revocations even when the in-group copy is late. A
// realm that hides versions is caught by the in-group copy, and the reverse.
func (srv *Server) manifestGet(ctx context.Context, s *session, f channel.Frame) channel.Frame {
	if !s.member() {
		return errFrame(f.ID, channel.CodeUnauthorized, "not a member session")
	}
	_, signed, err := srv.Store.LatestManifest(ctx, f.Payload.IdentityID)
	if err != nil {
		return errFrame(f.ID, channel.CodeInternal, "store error")
	}
	return channel.Frame{ID: f.ID, Payload: channel.Payload{Kind: channel.KindManifestLatest, Manifest: signed}}
}

func containsHash(list [][]byte, h []byte) bool {
	for _, x := range list {
		if string(x) == string(h) {
			return true
		}
	}
	return false
}
