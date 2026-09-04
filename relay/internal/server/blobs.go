package server

import (
	"context"
	"errors"
	"time"

	"github.com/Ulzuhan/arveil/relay/internal/channel"
	"github.com/Ulzuhan/arveil/relay/internal/store"
)

// Blob frames (PROTOCOL §7): staging upload by the owner, commit with a hash
// check, capability-gated reads. Member sessions only.

func (srv *Server) blobsReady(s *session, f channel.Frame) *channel.Frame {
	if !s.member() {
		e := errFrame(f.ID, channel.CodeUnauthorized, "not a member session")
		return &e
	}
	if srv.Blobs == nil {
		e := errFrame(f.ID, channel.CodeInternal, "blobs not configured")
		return &e
	}
	return nil
}

func blobError(id uint64, err error) channel.Frame {
	switch {
	case errors.Is(err, store.ErrBlobUnknown):
		return errFrame(id, channel.CodeForbidden, "blob unknown or capability rejected")
	case errors.Is(err, store.ErrBlobExpired):
		return errFrame(id, channel.CodeGone, "blob expired")
	case errors.Is(err, store.ErrBlobSize):
		return errFrame(id, channel.CodeTooLarge, "blob size or chunk refused")
	case errors.Is(err, store.ErrBlobQuota):
		return errFrame(id, channel.CodeQuota, "blob quota exceeded")
	case errors.Is(err, store.ErrBlobOffset), errors.Is(err, store.ErrBlobState), errors.Is(err, store.ErrBlobHash):
		return errFrame(id, channel.CodeConflict, err.Error())
	default:
		return errFrame(id, channel.CodeInternal, "store error")
	}
}

func (srv *Server) blobUploadBegin(ctx context.Context, s *session, f channel.Frame, now time.Time) channel.Frame {
	if e := srv.blobsReady(s, f); e != nil {
		return *e
	}
	id, cap, err := srv.Blobs.Begin(ctx, s.device.IdentityID, f.Payload.Size, now)
	if err != nil {
		return blobError(f.ID, err)
	}
	return channel.Frame{ID: f.ID, Payload: channel.Payload{Kind: channel.KindBlobUploadStarted, BlobID: id, ReadCapability: cap}}
}

func (srv *Server) blobChunk(ctx context.Context, s *session, f channel.Frame) channel.Frame {
	if e := srv.blobsReady(s, f); e != nil {
		return *e
	}
	if err := srv.Blobs.Chunk(ctx, s.device.IdentityID, f.Payload.BlobID, f.Payload.Offset, f.Payload.Data); err != nil {
		return blobError(f.ID, err)
	}
	return channel.Frame{ID: f.ID, Payload: channel.Payload{Kind: channel.KindAck}}
}

// blobResume reports how much of an interrupted upload the realm holds.
func (srv *Server) blobResume(ctx context.Context, s *session, f channel.Frame) channel.Frame {
	if !s.member() {
		return errFrame(f.ID, channel.CodeUnauthorized, "not a member session")
	}
	if srv.Blobs == nil {
		return errFrame(f.ID, channel.CodeInternal, "no blob store")
	}
	off, err := srv.Blobs.StagedOffset(ctx, s.device.IdentityID, f.Payload.BlobID)
	if err != nil {
		return blobError(f.ID, err)
	}
	return channel.Frame{ID: f.ID, Payload: channel.Payload{Kind: channel.KindBlobOffset, Offset: off}}
}

func (srv *Server) blobCommit(ctx context.Context, s *session, f channel.Frame, now time.Time) channel.Frame {
	if e := srv.blobsReady(s, f); e != nil {
		return *e
	}
	exp, err := srv.Blobs.Commit(ctx, s.device.IdentityID, f.Payload.BlobID, f.Payload.CiphertextHash, int64(f.Payload.RequestedExpiry), now)
	if err != nil {
		return blobError(f.ID, err)
	}
	return channel.Frame{ID: f.ID, Payload: channel.Payload{Kind: channel.KindBlobCommitted, EffectiveExpiry: uint64(exp)}}
}

func (srv *Server) blobFetch(ctx context.Context, s *session, f channel.Frame, now time.Time) channel.Frame {
	if e := srv.blobsReady(s, f); e != nil {
		return *e
	}
	data, total, err := srv.Blobs.Read(ctx, f.Payload.BlobID, f.Payload.ReadCapability, f.Payload.Offset, int(f.Payload.Length), now)
	if err != nil {
		return blobError(f.ID, err)
	}
	return channel.Frame{ID: f.ID, Payload: channel.Payload{Kind: channel.KindBlobData, TotalSize: total, Data: data}}
}
