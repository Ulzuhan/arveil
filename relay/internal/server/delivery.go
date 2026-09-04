package server

import (
	"context"
	"errors"
	"time"

	"github.com/Ulzuhan/arveil/relay/internal/channel"
	"github.com/Ulzuhan/arveil/relay/internal/store"
)

// Delivery frames (PROTOCOL §6). All require a member session: V1 makes the
// sender visible to the relay by design (metadata perimeter, THREAT_MODEL §3).

func (srv *Server) mailboxCreate(ctx context.Context, s *session, f channel.Frame, now time.Time) channel.Frame {
	if !s.member() {
		return errFrame(f.ID, channel.CodeUnauthorized, "not a member session")
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
