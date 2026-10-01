package channel

import "testing"

func TestInvitationRecordsUseEmptyByteStringsAndArrays(t *testing.T) {
	for _, payload := range []Payload{
		{Kind: KindInvitation, Invitation: InvitationRecord{ID: []byte{1}, State: "pending"}},
		{Kind: KindInvitations, Invitations: []InvitationRecord{{ID: []byte{1}, State: "pending"}}},
		{Kind: KindInvitations},
	} {
		encoded, err := Encode(Frame{ID: 7, Payload: payload})
		if err != nil {
			t.Fatal(err)
		}
		decoded, err := Decode(encoded)
		if err != nil {
			t.Fatal(err)
		}
		if decoded.Payload.Kind == KindInvitation && decoded.Payload.Invitation.ClaimedIdentity == nil {
			t.Fatal("null cannot decode as Rust bytes")
		}
		if decoded.Payload.Kind == KindInvitations {
			if decoded.Payload.Invitations == nil {
				t.Fatal("null cannot decode as Rust Vec")
			}
			for _, row := range decoded.Payload.Invitations {
				if row.ClaimedIdentity == nil {
					t.Fatal("null claimant in list")
				}
			}
		}
	}
}
