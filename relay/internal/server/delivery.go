package server

import (
	"bytes"
	"context"
	"errors"
	"time"

	"github.com/Ulzuhan/arveil/relay/internal/channel"
	"github.com/Ulzuhan/arveil/relay/internal/metrics"
	"github.com/Ulzuhan/arveil/relay/internal/store"
)

// Delivery frames (PROTOCOL §6). All require a member session: V1 makes the
// sender visible to the relay by design (metadata perimeter, THREAT_MODEL §3).

// Capabilities are 32 bytes, as they have always been when the relay minted
// them. The relay sees only a hash of the token in this frame, so it can
// check neither the length of the original nor its entropy: what it checks
// is the shape of what it is given and who is asking.
const capabilityHashBytes = 32

func (srv *Server) mailboxCreate(ctx context.Context, s *session, f channel.Frame, now time.Time) channel.Frame {
	if !s.member() {
		return errFrame(f.ID, channel.CodeUnauthorized, "not a member session")
	}
	if len(f.Payload.RequestKey) > 0 {
		return srv.mailboxCreateForRequest(ctx, s, f, now)
	}
	mb, err := srv.Store.CreateMailbox(ctx, s.device.IdentityID, s.device.DeviceID, now)
	if err != nil {
		return errFrame(f.ID, channel.CodeInternal, "store error")
	}
	return channel.Frame{ID: f.ID, Payload: channel.Payload{
		Kind: channel.KindMailboxCreated, MailboxID: mb.MailboxID,
		ReadCapability: mb.ReadCapability, WriteCapability: mb.WriteCapability,
	}}
}

// mailboxCreateForRequest answers a repeatable creation: the same request
// key from the same device with the same capabilities returns the mailbox it
// already made, so a client that lost the answer keeps the route it handed
// out rather than growing a second mailbox nobody writes to.
func (srv *Server) mailboxCreateForRequest(ctx context.Context, s *session, f channel.Frame, now time.Time) channel.Frame {
	p := f.Payload
	switch {
	case len(p.RequestKey) < 16 || len(p.RequestKey) > 32:
		return errFrame(f.ID, channel.CodeBadRequest, "request key must be 16 to 32 bytes")
	case len(p.ReadCapability) != capabilityHashBytes || len(p.WriteCapability) != capabilityHashBytes:
		return errFrame(f.ID, channel.CodeBadRequest, "capabilities must be 32 bytes")
	case bytes.Equal(p.ReadCapability, p.WriteCapability):
		return errFrame(f.ID, channel.CodeBadRequest, "read and write capabilities must differ")
	}
	mb, err := srv.Store.CreateMailboxForRequest(
		ctx, s.device.IdentityID, s.device.DeviceID, p.RequestKey, p.ReadCapability, p.WriteCapability, now)
	switch {
	case errors.Is(err, store.ErrRequestConflict):
		return errFrame(f.ID, channel.CodeConflict, "request key reused with other parameters")
	case errors.Is(err, store.ErrCapabilityInUse):
		return errFrame(f.ID, channel.CodeConflict, "capability already in use")
	case err != nil:
		srv.Logger.Printf("mailbox create: store error")
		return errFrame(f.ID, channel.CodeInternal, "store error")
	}
	return channel.Frame{ID: f.ID, Payload: channel.Payload{
		Kind: channel.KindMailboxCreated, MailboxID: mb.MailboxID,
		ReadCapability: mb.ReadCapability, WriteCapability: mb.WriteCapability,
	}}
}

func (srv *Server) envelopePut(ctx context.Context, s *session, f channel.Frame, now time.Time) channel.Frame {
	if !s.member() {
		return errFrame(f.ID, channel.CodeUnauthorized, "not a member session")
	}
	p := f.Payload
	if err := srv.Store.CheckCapability(ctx, p.MailboxID, p.WriteCapability, store.ScopeWrite, now); err != nil {
		return errFrame(f.ID, channel.CodeForbidden, "write capability rejected")
	}
	res, err := srv.Store.PutEnvelope(ctx, p.MailboxID, p.DeliveryID, p.HpkeEnc, p.Ciphertext, int64(p.RequestedExpiry), now)
	switch {
	case errors.Is(err, store.ErrDeliveryConflict):
		return errFrame(f.ID, channel.CodeConflict, "delivery id reused with a different body")
	case errors.Is(err, store.ErrEnvelopeTooBig):
		return errFrame(f.ID, channel.CodeTooLarge, "envelope too large")
	case errors.Is(err, store.ErrMailboxFull):
		return errFrame(f.ID, channel.CodeQuota, "mailbox queue full")
	case err != nil:
		return errFrame(f.ID, channel.CodeInternal, "store error")
	}
	metrics.EnvelopesStored.Add(1)
	// Only the empty to non-empty transition is worth a hint (M3.4).
	if res.WasEmpty && !res.Duplicate {
		srv.notifyMailbox(ctx, p.MailboxID)
	}
	return channel.Frame{ID: f.ID, Payload: channel.Payload{Kind: channel.KindEnvelopeAccepted, EffectiveExpiry: uint64(res.EffectiveExpiry)}}
}

func (srv *Server) envelopeFetch(ctx context.Context, s *session, f channel.Frame, now time.Time) channel.Frame {
	if !s.member() {
		return errFrame(f.ID, channel.CodeUnauthorized, "not a member session")
	}
	p := f.Payload
	if err := srv.Store.CheckCapability(ctx, p.MailboxID, p.ReadCapability, store.ScopeRead, now); err != nil {
		return errFrame(f.ID, channel.CodeForbidden, "read capability rejected")
	}
	items, next, err := srv.Store.FetchEnvelopes(ctx, p.MailboxID, p.Cursor, int(p.Limit), now)
	if err != nil {
		return errFrame(f.ID, channel.CodeInternal, "store error")
	}
	out := make([]channel.EnvelopeItem, 0, len(items))
	for _, e := range items {
		out = append(out, channel.EnvelopeItem{Seq: e.Seq, DeliveryID: e.DeliveryID, HpkeEnc: e.HpkeEnc, Ciphertext: e.Ciphertext})
	}
	return channel.Frame{ID: f.ID, Payload: channel.Payload{Kind: channel.KindEnvelopes, Items: out, NextCursor: next}}
}

func (srv *Server) envelopeAck(ctx context.Context, s *session, f channel.Frame, now time.Time) channel.Frame {
	if !s.member() {
		return errFrame(f.ID, channel.CodeUnauthorized, "not a member session")
	}
	p := f.Payload
	if err := srv.Store.CheckCapability(ctx, p.MailboxID, p.ReadCapability, store.ScopeRead, now); err != nil {
		return errFrame(f.ID, channel.CodeForbidden, "read capability rejected")
	}
	if err := srv.Store.AckEnvelopes(ctx, p.MailboxID, p.DeliveryIDs); err != nil {
		return errFrame(f.ID, channel.CodeInternal, "store error")
	}
	return channel.Frame{ID: f.ID, Payload: channel.Payload{Kind: channel.KindAck}}
}

func (srv *Server) keyPackagesPublish(ctx context.Context, s *session, f channel.Frame, now time.Time) channel.Frame {
	if !s.member() {
		return errFrame(f.ID, channel.CodeUnauthorized, "not a member session")
	}
	err := srv.Store.PublishKeyPackages(ctx, s.device.IdentityID, s.device.DeviceID, f.Payload.KeyPackages, now)
	switch {
	case errors.Is(err, store.ErrKeyPackageBatch):
		return errFrame(f.ID, channel.CodeQuota, "key package batch exceeds the bound")
	case errors.Is(err, store.ErrEnvelopeTooBig):
		return errFrame(f.ID, channel.CodeTooLarge, "key package too large")
	case err != nil:
		return errFrame(f.ID, channel.CodeInternal, "store error")
	}
	return channel.Frame{ID: f.ID, Payload: channel.Payload{Kind: channel.KindAck}}
}

// keyPackagesStatus lets a device see how close it is to running out, so a
// client can top up before somebody is refused a conversation (M4.6).
func (srv *Server) keyPackagesStatus(ctx context.Context, s *session, f channel.Frame) channel.Frame {
	if !s.member() {
		return errFrame(f.ID, channel.CodeUnauthorized, "not a member session")
	}
	n, err := srv.Store.AvailableKeyPackages(ctx, s.device.DeviceID)
	if err != nil {
		return errFrame(f.ID, channel.CodeInternal, "store error")
	}
	return channel.Frame{ID: f.ID, Payload: channel.Payload{Kind: channel.KindKeyPackagesAvail, Count: uint32(n)}}
}

func (srv *Server) keyPackagesClaim(ctx context.Context, s *session, f channel.Frame) channel.Frame {
	if !s.member() {
		return errFrame(f.ID, channel.CodeUnauthorized, "not a member session")
	}
	kp, err := srv.Store.ClaimKeyPackage(ctx, f.Payload.IdentityID, f.Payload.DeviceID)
	if errors.Is(err, store.ErrNoKeyPackage) {
		return errFrame(f.ID, channel.CodeGone, "no key package available")
	}
	if err != nil {
		return errFrame(f.ID, channel.CodeInternal, "store error")
	}
	return channel.Frame{ID: f.ID, Payload: channel.Payload{Kind: channel.KindKeyPackageClaimed, KeyPackage: kp}}
}
