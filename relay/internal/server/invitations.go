package server

import (
	"context"
	"crypto/sha256"
	"errors"
	"time"

	"github.com/Ulzuhan/arveil/relay/internal/channel"
	"github.com/Ulzuhan/arveil/relay/internal/store"
)

func invitationRecord(i store.Invitation) channel.InvitationRecord {
	return channel.InvitationRecord{Sequence: i.Sequence, ID: i.ID, CreatedAt: i.CreatedAt, ExpiresAt: i.ExpiresAt, State: i.State, ClaimedIdentity: i.ClaimedIdentity, ClaimedAt: i.ClaimedAt}
}

func (srv *Server) invitationError(id uint64, err error) channel.Frame {
	switch {
	case errors.Is(err, store.ErrInvitePermission):
		return errFrame(id, channel.CodeForbidden, "invitation permission denied")
	case errors.Is(err, store.ErrInviteRequest):
		return errFrame(id, channel.CodeBadRequest, "invalid invitation request")
	case errors.Is(err, store.ErrRequestConflict):
		return errFrame(id, channel.CodeConflict, "invitation request conflict")
	case errors.Is(err, store.ErrInviteUsed):
		return errFrame(id, channel.CodeConflict, "invitation already used")
	case errors.Is(err, store.ErrInviteInvalid):
		return errFrame(id, channel.CodeGone, "invitation unavailable")
	case errors.Is(err, store.ErrNoKeyPackage):
		return errFrame(id, channel.CodeGone, "no key package available")
	case errors.Is(err, store.ErrInviteQuota):
		return errFrame(id, channel.CodeQuota, "invitation limit reached")
	default:
		return srv.storeError(id, "invitation operation", err)
	}
}

func (srv *Server) invitation(ctx context.Context, s *session, f channel.Frame, now time.Time) channel.Frame {
	if !s.member() {
		return errFrame(f.ID, channel.CodeUnauthorized, "not a member session")
	}
	// Bound rejected attempts too, independently of successful-issuance quotas.
	if now.Sub(s.invitationWindow) >= time.Minute {
		s.invitationWindow = now
		s.invitationRequests = 0
	}
	s.invitationRequests++
	if s.invitationRequests > 60 || !srv.Limits.AllowInvitation(s.addr, now) {
		return errFrame(f.ID, channel.CodeQuota, "invitation request limit reached")
	}
	if srv.Store == nil {
		return errFrame(f.ID, channel.CodeInternal, "no store")
	}
	p := f.Payload
	cred := s.device.CredentialHash
	var i store.Invitation
	var err error
	switch p.Kind {
	case channel.KindInvitePolicyGet:
		var allowed bool
		allowed, err = srv.Store.InvitationPolicy(ctx, cred, now)
		if err == nil {
			return channel.Frame{ID: f.ID, Payload: channel.Payload{Kind: channel.KindInvitePolicy, CanInvite: allowed, ServerTime: uint64(now.Unix()), TTL: uint64(store.InvitationTTL / time.Second)}}
		}
	case channel.KindInviteCreate:
		i, err = srv.Store.IssueInvitation(ctx, cred, p.RequestKey, p.TokenHash, p.TTL, now)
	case channel.KindInviteGet, channel.KindInviteRevoke:
		if len(p.InvitationID) != 32 {
			err = store.ErrInviteRequest
			break
		}
		if p.Kind == channel.KindInviteGet {
			i, err = srv.Store.GetInvitation(ctx, cred, p.InvitationID, now)
		} else {
			i, err = srv.Store.RevokeInvitation(ctx, cred, p.InvitationID, now)
		}
	case channel.KindInviteList:
		var list []store.Invitation
		list, err = srv.Store.ListInvitations(ctx, cred, p.Cursor, p.Limit, now)
		if err == nil {
			items := []channel.InvitationRecord{}
			cursor := p.Cursor
			for _, row := range list {
				items = append(items, invitationRecord(row))
				cursor = row.Sequence
			}
			return channel.Frame{ID: f.ID, Payload: channel.Payload{Kind: channel.KindInvitations, Invitations: items, NextCursor: cursor}}
		}
	case channel.KindInviteAccept:
		if len(p.Token) != 32 {
			err = store.ErrInviteRequest
			break
		}
		h := sha256.Sum256(p.Token)
		i, err = srv.Store.AcceptInvitation(ctx, cred, h[:], now)
	case channel.KindKeyPackagesClaimOnce:
		var pkg []byte
		pkg, err = srv.Store.ClaimKeyPackageOnce(ctx, cred, p.RequestKey, p.IdentityID, p.DeviceID, now)
		if err == nil {
			return channel.Frame{ID: f.ID, Payload: channel.Payload{Kind: channel.KindKeyPackageClaimed, KeyPackage: pkg}}
		}
	}
	if err != nil {
		return srv.invitationError(f.ID, err)
	}
	return channel.Frame{ID: f.ID, Payload: channel.Payload{Kind: channel.KindInvitation, Invitation: invitationRecord(i)}}
}
