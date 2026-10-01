package channel

import "github.com/fxamacker/cbor/v2"

const (
	KindInvitePolicyGet      = "InvitePolicyGet"
	KindInvitePolicy         = "InvitePolicy"
	KindInviteCreate         = "InviteCreate"
	KindInviteList           = "InviteList"
	KindInviteGet            = "InviteGet"
	KindInviteRevoke         = "InviteRevoke"
	KindInviteAccept         = "InviteAccept"
	KindInvitation           = "Invitation"
	KindInvitations          = "Invitations"
	KindKeyPackagesClaimOnce = "KeyPackagesClaimOnce"
)

type InvitationRecord struct {
	Sequence        uint64 `cbor:"sequence"`
	ID              []byte `cbor:"id"`
	CreatedAt       uint64 `cbor:"created_at"`
	ExpiresAt       uint64 `cbor:"expires_at"`
	State           string `cbor:"state"`
	ClaimedIdentity []byte `cbor:"claimed_identity"`
	ClaimedAt       uint64 `cbor:"claimed_at"`
}
type bodyInvitePolicy struct {
	CanInvite  bool   `cbor:"can_invite"`
	ServerTime uint64 `cbor:"server_time"`
	TTL        uint64 `cbor:"ttl"`
}
type bodyInviteCreate struct {
	RequestKey []byte `cbor:"request_key"`
	TokenHash  []byte `cbor:"token_hash"`
	TTL        uint64 `cbor:"ttl"`
}
type bodyInviteList struct {
	Cursor uint64 `cbor:"cursor"`
	Limit  uint16 `cbor:"limit"`
}
type bodyInviteGet struct {
	InvitationID []byte `cbor:"invitation_id"`
}
type bodyInviteRevoke struct {
	InvitationID []byte `cbor:"invitation_id"`
}
type bodyInviteAccept struct {
	Token []byte `cbor:"token"`
}
type bodyInvitation struct {
	Invitation InvitationRecord `cbor:"invitation"`
}
type bodyInvitations struct {
	Invitations []InvitationRecord `cbor:"invitations"`
	NextCursor  uint64             `cbor:"next_cursor"`
}
type bodyKeyPackagesClaimOnce struct {
	RequestKey []byte `cbor:"request_key"`
	IdentityID []byte `cbor:"identity_id"`
	DeviceID   []byte `cbor:"device_id"`
}

func nonNilInvitation(i InvitationRecord) InvitationRecord {
	i.ID = nonNil(i.ID)
	i.ClaimedIdentity = nonNil(i.ClaimedIdentity)
	return i
}

func encodeInvitationPayload(p Payload) (any, bool) {
	switch p.Kind {
	case KindInvitePolicyGet:
		return p.Kind, true
	case KindInvitePolicy:
		return map[string]bodyInvitePolicy{KindInvitePolicy: {CanInvite: p.CanInvite, ServerTime: p.ServerTime, TTL: p.TTL}}, true
	case KindInviteCreate:
		return map[string]bodyInviteCreate{KindInviteCreate: {RequestKey: nonNil(p.RequestKey), TokenHash: nonNil(p.TokenHash), TTL: p.TTL}}, true
	case KindInviteList:
		return map[string]bodyInviteList{KindInviteList: {Cursor: p.Cursor, Limit: p.Limit}}, true
	case KindInviteGet:
		return map[string]bodyInviteGet{KindInviteGet: {InvitationID: nonNil(p.InvitationID)}}, true
	case KindInviteRevoke:
		return map[string]bodyInviteRevoke{KindInviteRevoke: {InvitationID: nonNil(p.InvitationID)}}, true
	case KindInviteAccept:
		return map[string]bodyInviteAccept{KindInviteAccept: {Token: nonNil(p.Token)}}, true
	case KindInvitation:
		return map[string]bodyInvitation{KindInvitation: {Invitation: nonNilInvitation(p.Invitation)}}, true
	case KindInvitations:
		rows := make([]InvitationRecord, len(p.Invitations))
		for index, row := range p.Invitations {
			rows[index] = nonNilInvitation(row)
		}
		return map[string]bodyInvitations{KindInvitations: {Invitations: rows, NextCursor: p.NextCursor}}, true
	case KindKeyPackagesClaimOnce:
		return map[string]bodyKeyPackagesClaimOnce{KindKeyPackagesClaimOnce: {RequestKey: nonNil(p.RequestKey), IdentityID: nonNil(p.IdentityID), DeviceID: nonNil(p.DeviceID)}}, true
	}
	return nil, false
}
func decodeInvitationPayload(name string, raw cbor.RawMessage) (Payload, bool, error) {
	switch name {
	case KindInvitePolicy:
		var v bodyInvitePolicy
		if err := cbor.Unmarshal(raw, &v); err != nil {
			return Payload{}, true, err
		}
		return Payload{Kind: name, CanInvite: v.CanInvite, ServerTime: v.ServerTime, TTL: v.TTL}, true, nil
	case KindInviteCreate:
		var v bodyInviteCreate
		if err := cbor.Unmarshal(raw, &v); err != nil {
			return Payload{}, true, err
		}
		return Payload{Kind: name, RequestKey: v.RequestKey, TokenHash: v.TokenHash, TTL: v.TTL}, true, nil
	case KindInviteList:
		var v bodyInviteList
		if err := cbor.Unmarshal(raw, &v); err != nil {
			return Payload{}, true, err
		}
		return Payload{Kind: name, Cursor: v.Cursor, Limit: v.Limit}, true, nil
	case KindInviteGet:
		var v bodyInviteGet
		if err := cbor.Unmarshal(raw, &v); err != nil {
			return Payload{}, true, err
		}
		return Payload{Kind: name, InvitationID: v.InvitationID}, true, nil
	case KindInviteRevoke:
		var v bodyInviteRevoke
		if err := cbor.Unmarshal(raw, &v); err != nil {
			return Payload{}, true, err
		}
		return Payload{Kind: name, InvitationID: v.InvitationID}, true, nil
	case KindInviteAccept:
		var v bodyInviteAccept
		if err := cbor.Unmarshal(raw, &v); err != nil {
			return Payload{}, true, err
		}
		return Payload{Kind: name, Token: v.Token}, true, nil
	case KindInvitation:
		var v bodyInvitation
		if err := cbor.Unmarshal(raw, &v); err != nil {
			return Payload{}, true, err
		}
		return Payload{Kind: name, Invitation: v.Invitation}, true, nil
	case KindInvitations:
		var v bodyInvitations
		if err := cbor.Unmarshal(raw, &v); err != nil {
			return Payload{}, true, err
		}
		return Payload{Kind: name, Invitations: v.Invitations, NextCursor: v.NextCursor}, true, nil
	case KindKeyPackagesClaimOnce:
		var v bodyKeyPackagesClaimOnce
		if err := cbor.Unmarshal(raw, &v); err != nil {
			return Payload{}, true, err
		}
		return Payload{Kind: name, RequestKey: v.RequestKey, IdentityID: v.IdentityID, DeviceID: v.DeviceID}, true, nil
	}
	return Payload{}, false, nil
}
