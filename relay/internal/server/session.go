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
	return channel.Frame{ID: f.ID, Payload: channel.Payload{Kind: channel.KindAck}}
}

func containsHash(list [][]byte, h []byte) bool {
	for _, x := range list {
		if string(x) == string(h) {
			return true
		}
	}
	return false
}
