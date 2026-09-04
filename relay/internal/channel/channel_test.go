package channel

import (
	"bytes"
	"encoding/hex"
	"testing"
)

// Vectors produced by arveil-core (ciborium) for the same frames. They are
// the interop contract for the codec.
var rustVectors = []struct {
	name  string
	hex   string
	frame Frame
}{
	{"ping", "a262696407677061796c6f61646450696e67", Frame{ID: 7, Payload: Payload{Kind: KindPing}}},
	{"endpoint_list_get", "a262696407677061796c6f61646f456e64706f696e744c697374476574", Frame{ID: 7, Payload: Payload{Kind: KindEndpointListGet}}},
	{"endpoint_list", "a262696409677061796c6f6164a16c456e64706f696e744c697374a1667369676e656443010203", Frame{ID: 9, Payload: Payload{Kind: KindEndpointList, Signed: []byte{1, 2, 3}}}},
	{"error", "a262696403677061796c6f6164a1654572726f72a264636f6465190194676d657373616765646e6f7065", Frame{ID: 3, Payload: Payload{Kind: KindError, Code: 404, Message: "nope"}}},
}

func TestCodecMatchesRustVectors(t *testing.T) {
	for _, v := range rustVectors {
		want, _ := hex.DecodeString(v.hex)
		got, err := Encode(v.frame)
		if err != nil {
			t.Fatalf("%s: encode: %v", v.name, err)
		}
		if !bytes.Equal(got, want) {
			t.Errorf("%s: encode mismatch\n got %x\nwant %x", v.name, got, want)
		}
		dec, err := Decode(want)
		if err != nil {
			t.Fatalf("%s: decode: %v", v.name, err)
		}
		if dec.ID != v.frame.ID || dec.Payload.Kind != v.frame.Payload.Kind ||
			!bytes.Equal(dec.Payload.Signed, v.frame.Payload.Signed) ||
			dec.Payload.Code != v.frame.Payload.Code || dec.Payload.Message != v.frame.Payload.Message {
			t.Errorf("%s: decode mismatch: %+v", v.name, dec)
		}
	}
}

func TestDecodeRejectsGarbageAndOversize(t *testing.T) {
	if _, err := Decode(make([]byte, MaxFrameBytes+1)); err == nil {
		t.Fatal("oversize accepted")
	}
	for _, g := range [][]byte{nil, {0xff}, {0xa1, 0x62, 0x69, 0x64}, []byte("hello")} {
		if _, err := Decode(g); err == nil {
			t.Errorf("garbage %x accepted", g)
		}
	}
}

func TestFragmentRoundTrip(t *testing.T) {
	for _, n := range []int{0, 1, FragmentData, FragmentData + 1, 3*FragmentData + 5} {
		in := bytes.Repeat([]byte{0xab}, n)
		r := NewReassembler(MaxFrameBytes)
		var out []byte
		var done bool
		for _, f := range Fragments(in) {
			var err error
			out, done, err = r.Push(f)
			if err != nil {
				t.Fatalf("n=%d: %v", n, err)
			}
		}
		if !done || !bytes.Equal(out, in) {
			t.Errorf("n=%d: round trip failed (done=%v, len=%d)", n, done, len(out))
		}
	}
}

func TestReassemblerBound(t *testing.T) {
	r := NewReassembler(3 * FragmentData)
	frag := append([]byte{0}, bytes.Repeat([]byte{1}, FragmentData)...)
	for i := 0; i < 3; i++ {
		if _, _, err := r.Push(frag); err != nil {
			t.Fatal(err)
		}
	}
	if _, _, err := r.Push(frag); err == nil {
		t.Fatal("fourth fragment accepted past the limit")
	}
	if r.MidFrame() {
		t.Fatal("buffer not dropped after violation")
	}
}

func establish(t *testing.T) (dev, rlm *Channel, devPub, rlmPub []byte) {
	t.Helper()
	realm, _ := GenerateStaticKeypair()
	device, _ := GenerateStaticKeypair()
	pro := Prologue([]byte("realm-test"))

	init, err := NewInitiator(device, realm.Public, pro)
	if err != nil {
		t.Fatal(err)
	}
	m1, err := init.WriteMessage1()
	if err != nil {
		t.Fatal(err)
	}
	resp, err := NewResponder(realm, pro)
	if err != nil {
		t.Fatal(err)
	}
	seen, err := resp.ReadMessage1(m1)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(seen, device.Public) {
		t.Fatal("responder did not learn the device static")
	}
	m2, rt, err := resp.WriteMessage2()
	if err != nil {
		t.Fatal(err)
	}
	dt, err := init.ReadMessage2(m2)
	if err != nil {
		t.Fatal(err)
	}
	return NewChannel(dt), NewChannel(rt), device.Public, realm.Public
}

func TestHandshakeAndFramesBothWays(t *testing.T) {
	dev, rlm, devPub, rlmPub := establish(t)
	if !bytes.Equal(rlm.RemoteStatic(), devPub) || !bytes.Equal(dev.RemoteStatic(), rlmPub) {
		t.Fatal("remote statics wrong")
	}
	msgs, err := dev.Seal(Frame{ID: 7, Payload: Payload{Kind: KindEndpointListGet}})
	if err != nil || len(msgs) != 1 {
		t.Fatalf("seal: %v (%d msgs)", err, len(msgs))
	}
	f, ok, err := rlm.Open(msgs[0])
	if err != nil || !ok || f.ID != 7 || f.Payload.Kind != KindEndpointListGet {
		t.Fatalf("open: %v ok=%v %+v", err, ok, f)
	}
	big := Frame{ID: 1, Payload: Payload{Kind: KindEndpointList, Signed: bytes.Repeat([]byte{0xcd}, 200_000)}}
	msgs, err = rlm.Seal(big)
	if err != nil || len(msgs) < 4 {
		t.Fatalf("seal big: %v (%d msgs)", err, len(msgs))
	}
	for i, m := range msgs {
		f, ok, err := dev.Open(m)
		if err != nil {
			t.Fatal(err)
		}
		if ok != (i == len(msgs)-1) {
			t.Fatalf("fragment %d: ok=%v", i, ok)
		}
		if ok && !bytes.Equal(f.Payload.Signed, big.Payload.Signed) {
			t.Fatal("big frame mismatch")
		}
	}
}

func TestWrongStaticOrPrologueFailsOnMessage1(t *testing.T) {
	realm, _ := GenerateStaticKeypair()
	impostor, _ := GenerateStaticKeypair()
	device, _ := GenerateStaticKeypair()
	pro := Prologue([]byte("realm-test"))

	init, _ := NewInitiator(device, impostor.Public, pro)
	m1, _ := init.WriteMessage1()
	resp, _ := NewResponder(realm, pro)
	if _, err := resp.ReadMessage1(m1); err == nil {
		t.Fatal("message 1 for another realm was accepted")
	}

	init, _ = NewInitiator(device, realm.Public, Prologue([]byte("other")))
	m1, _ = init.WriteMessage1()
	resp, _ = NewResponder(realm, pro)
	if _, err := resp.ReadMessage1(m1); err == nil {
		t.Fatal("message 1 with another prologue was accepted")
	}
}

func TestReplayedMessage1HasNoEffect(t *testing.T) {
	realm, _ := GenerateStaticKeypair()
	device, _ := GenerateStaticKeypair()
	pro := Prologue([]byte("realm-test"))
	init, _ := NewInitiator(device, realm.Public, pro)
	m1, _ := init.WriteMessage1()

	resp, _ := NewResponder(realm, pro)
	if _, err := resp.ReadMessage1(m1); err != nil {
		t.Fatal(err)
	}
	m2, _, _ := resp.WriteMessage2()
	if _, err := init.ReadMessage2(m2); err != nil {
		t.Fatal(err)
	}

	// Replay against a fresh responder.
	resp2, _ := NewResponder(realm, pro)
	if _, err := resp2.ReadMessage1(m1); err != nil {
		t.Fatal("IK cannot detect the replay by itself; read must succeed")
	}
	m2r, rt2, _ := resp2.WriteMessage2()
	other, _ := NewInitiator(device, realm.Public, pro)
	_, _ = other.WriteMessage1()
	if _, err := other.ReadMessage2(m2r); err == nil {
		t.Fatal("replayer opened message 2 without the original ephemeral")
	}
	if _, err := rt2.Open(make([]byte, 64)); err == nil {
		t.Fatal("forged transport message opened")
	}
	if _, err := rt2.Open(m1); err == nil {
		t.Fatal("message 1 opened as transport")
	}
}

func TestStaticKeypairFromPrivateMatchesGenerated(t *testing.T) {
	kp, _ := GenerateStaticKeypair()
	re, err := StaticKeypairFromPrivate(kp.Private)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(re.Public, kp.Public) {
		t.Fatal("public key derivation mismatch")
	}
}

var rustVectorsM03 = []struct {
	hex   string
	frame Frame
}{
	{"a262696401677061796c6f6164a16c496e7669746552656465656da365746f6b656e420102686d616e6966657374430405066a63726564656e7469616c4103", Frame{ID: 1, Payload: Payload{Kind: KindInviteRedeem, Token: []byte{1, 2}, Credential: []byte{3}, Manifest: []byte{4, 5, 6}}}},
	{"a262696401677061796c6f6164a16e496e7669746552656465656d6564a16b6964656e746974795f69644409090909", Frame{ID: 1, Payload: Payload{Kind: KindInviteRedeemed, IdentityID: []byte{9, 9, 9, 9}}}},
	{"a262696402677061796c6f6164a16d43726564656e7469616c507574a16a63726564656e7469616c4107", Frame{ID: 2, Payload: Payload{Kind: KindCredentialPut, Credential: []byte{7}}}},
	{"a262696403677061796c6f6164a16b4d616e6966657374507574a1686d616e69666573744108", Frame{ID: 3, Payload: Payload{Kind: KindManifestPut, Manifest: []byte{8}}}},
	{"a262696404677061796c6f61646341636b", Frame{ID: 4, Payload: Payload{Kind: KindAck}}},
}

func TestCodecMatchesRustVectorsM03(t *testing.T) {
	for _, v := range rustVectorsM03 {
		want, _ := hex.DecodeString(v.hex)
		got, err := Encode(v.frame)
		if err != nil {
			t.Fatalf("%s: encode: %v", v.frame.Payload.Kind, err)
		}
		if !bytes.Equal(got, want) {
			t.Errorf("%s: encode mismatch\n got %x\nwant %x", v.frame.Payload.Kind, got, want)
		}
		dec, err := Decode(want)
		if err != nil {
			t.Fatalf("%s: decode: %v", v.frame.Payload.Kind, err)
		}
		if dec.Payload.Kind != v.frame.Payload.Kind || !bytes.Equal(dec.Payload.Token, v.frame.Payload.Token) ||
			!bytes.Equal(dec.Payload.Credential, v.frame.Payload.Credential) || !bytes.Equal(dec.Payload.Manifest, v.frame.Payload.Manifest) ||
			!bytes.Equal(dec.Payload.IdentityID, v.frame.Payload.IdentityID) {
			t.Errorf("%s: decode mismatch: %+v", v.frame.Payload.Kind, dec.Payload)
		}
	}
}

var rustVectorsM04 = []struct {
	hex   string
	frame Frame
}{
	{"a262696401677061796c6f61646d4d61696c626f78437265617465", Frame{ID: 1, Payload: Payload{Kind: KindMailboxCreate}}},
	{"a262696401677061796c6f6164a16e4d61696c626f7843726561746564a36a6d61696c626f785f696441016f726561645f6361706162696c69747941027077726974655f6361706162696c6974794103", Frame{ID: 1, Payload: Payload{Kind: KindMailboxCreated, MailboxID: []byte{1}, ReadCapability: []byte{2}, WriteCapability: []byte{3}}}},
	{"a262696402677061796c6f6164a16b456e76656c6f7065507574a66868706b655f656e6341056a636970686572746578744206076a6d61696c626f785f696441016b64656c69766572795f69644104707265717565737465645f65787069727918637077726974655f6361706162696c6974794103", Frame{ID: 2, Payload: Payload{Kind: KindEnvelopePut, MailboxID: []byte{1}, WriteCapability: []byte{3}, DeliveryID: []byte{4}, RequestedExpiry: 99, HpkeEnc: []byte{5}, Ciphertext: []byte{6, 7}}}},
	{"a262696402677061796c6f6164a170456e76656c6f70654163636570746564a1706566666563746976655f6578706972791862", Frame{ID: 2, Payload: Payload{Kind: KindEnvelopeAccepted, EffectiveExpiry: 98}}},
	{"a262696403677061796c6f6164a16d456e76656c6f70654665746368a4656c696d69740a66637572736f72006a6d61696c626f785f696441016f726561645f6361706162696c6974794102", Frame{ID: 3, Payload: Payload{Kind: KindEnvelopeFetch, MailboxID: []byte{1}, ReadCapability: []byte{2}, Cursor: 0, Limit: 10}}},
	{"a262696403677061796c6f6164a169456e76656c6f706573a2656974656d7381a463736571016868706b655f656e6341056a636970686572746578744206076b64656c69766572795f696441046b6e6578745f637572736f7201", Frame{ID: 3, Payload: Payload{Kind: KindEnvelopes, Items: []EnvelopeItem{{Seq: 1, DeliveryID: []byte{4}, HpkeEnc: []byte{5}, Ciphertext: []byte{6, 7}}}, NextCursor: 1}}},
	{"a262696404677061796c6f6164a16b456e76656c6f706541636ba36a6d61696c626f785f696441016c64656c69766572795f6964738141046f726561645f6361706162696c6974794102", Frame{ID: 4, Payload: Payload{Kind: KindEnvelopeAck, MailboxID: []byte{1}, ReadCapability: []byte{2}, DeliveryIDs: [][]byte{{4}}}}},
}

func TestCodecMatchesRustVectorsM04(t *testing.T) {
	for _, v := range rustVectorsM04 {
		want, _ := hex.DecodeString(v.hex)
		got, err := Encode(v.frame)
		if err != nil {
			t.Fatalf("%s: encode: %v", v.frame.Payload.Kind, err)
		}
		if !bytes.Equal(got, want) {
			t.Errorf("%s: encode mismatch\n got %x\nwant %x", v.frame.Payload.Kind, got, want)
		}
		dec, err := Decode(want)
		if err != nil {
			t.Fatalf("%s: decode: %v", v.frame.Payload.Kind, err)
		}
		if dec.Payload.Kind != v.frame.Payload.Kind || dec.Payload.RequestedExpiry != v.frame.Payload.RequestedExpiry ||
			dec.Payload.EffectiveExpiry != v.frame.Payload.EffectiveExpiry || dec.Payload.Cursor != v.frame.Payload.Cursor ||
			dec.Payload.Limit != v.frame.Payload.Limit || dec.Payload.NextCursor != v.frame.Payload.NextCursor ||
			len(dec.Payload.Items) != len(v.frame.Payload.Items) || len(dec.Payload.DeliveryIDs) != len(v.frame.Payload.DeliveryIDs) ||
			!bytes.Equal(dec.Payload.MailboxID, v.frame.Payload.MailboxID) || !bytes.Equal(dec.Payload.Ciphertext, v.frame.Payload.Ciphertext) {
			t.Errorf("%s: decode mismatch: %+v", v.frame.Payload.Kind, dec.Payload)
		}
	}
}

func TestCodecMatchesRustVectorsKeyPackages(t *testing.T) {
	vectors := []struct {
		hex   string
		frame Frame
	}{
		{"a262696401677061796c6f6164a1724b65795061636b616765735075626c697368a16c6b65795f7061636b61676573824201024103", Frame{ID: 1, Payload: Payload{Kind: KindKeyPackagesPublish, KeyPackages: [][]byte{{1, 2}, {3}}}}},
		{"a262696402677061796c6f6164a1704b65795061636b61676573436c61696da2696465766963655f69644204046b6964656e746974795f69644409090909", Frame{ID: 2, Payload: Payload{Kind: KindKeyPackagesClaim, IdentityID: []byte{9, 9, 9, 9}, DeviceID: []byte{4, 4}}}},
		{"a262696402677061796c6f6164a1714b65795061636b616765436c61696d6564a16b6b65795f7061636b616765420102", Frame{ID: 2, Payload: Payload{Kind: KindKeyPackageClaimed, KeyPackage: []byte{1, 2}}}},
		{"a26269640a677061796c6f6164714b65795061636b61676573537461747573", Frame{ID: 10, Payload: Payload{Kind: KindKeyPackagesStatus}}},
		{"a26269640a677061796c6f6164a1744b65795061636b61676573417661696c61626c65a165636f756e7403", Frame{ID: 10, Payload: Payload{Kind: KindKeyPackagesAvail, Count: 3}}},
	}
	for _, v := range vectors {
		want, _ := hex.DecodeString(v.hex)
		got, err := Encode(v.frame)
		if err != nil || !bytes.Equal(got, want) {
			t.Errorf("%s: encode mismatch (%v)\n got %x\nwant %x", v.frame.Payload.Kind, err, got, want)
		}
		dec, err := Decode(want)
		if err != nil || dec.Payload.Kind != v.frame.Payload.Kind || len(dec.Payload.KeyPackages) != len(v.frame.Payload.KeyPackages) ||
			!bytes.Equal(dec.Payload.KeyPackage, v.frame.Payload.KeyPackage) || !bytes.Equal(dec.Payload.IdentityID, v.frame.Payload.IdentityID) ||
			dec.Payload.Count != v.frame.Payload.Count {
			t.Errorf("%s: decode mismatch (%v): %+v", v.frame.Payload.Kind, err, dec.Payload)
		}
	}
}

func TestCodecMatchesRustVectorsBlobs(t *testing.T) {
	vectors := []struct {
		hex   string
		frame Frame
	}{
		{"a262696401677061796c6f6164a16f426c6f6255706c6f6164426567696ea16473697a651903e8", Frame{ID: 1, Payload: Payload{Kind: KindBlobUploadBegin, Size: 1000}}},
		{"a262696401677061796c6f6164a171426c6f6255706c6f616453746172746564a267626c6f625f696441016f726561645f6361706162696c6974794102", Frame{ID: 1, Payload: Payload{Kind: KindBlobUploadStarted, BlobID: []byte{1}, ReadCapability: []byte{2}}}},
		{"a262696402677061796c6f6164a169426c6f624368756e6ba36464617461420304666f66667365740067626c6f625f69644101", Frame{ID: 2, Payload: Payload{Kind: KindBlobChunk, BlobID: []byte{1}, Offset: 0, Data: []byte{3, 4}}}},
		{"a262696403677061796c6f6164a16a426c6f62436f6d6d6974a367626c6f625f696441016f636970686572746578745f686173684105707265717565737465645f65787069727907", Frame{ID: 3, Payload: Payload{Kind: KindBlobCommit, BlobID: []byte{1}, CiphertextHash: []byte{5}, RequestedExpiry: 7}}},
		{"a262696403677061796c6f6164a16d426c6f62436f6d6d6974746564a1706566666563746976655f65787069727908", Frame{ID: 3, Payload: Payload{Kind: KindBlobCommitted, EffectiveExpiry: 8}}},
		{"a262696404677061796c6f6164a169426c6f624665746368a4666c656e6774680a666f66667365740067626c6f625f696441016f726561645f6361706162696c6974794102", Frame{ID: 4, Payload: Payload{Kind: KindBlobFetch, BlobID: []byte{1}, ReadCapability: []byte{2}, Offset: 0, Length: 10}}},
		{"a262696404677061796c6f6164a168426c6f6244617461a264646174614203046a746f74616c5f73697a6502", Frame{ID: 4, Payload: Payload{Kind: KindBlobData, TotalSize: 2, Data: []byte{3, 4}}}},
		{"a262696408677061796c6f6164a16a426c6f62526573756d65a167626c6f625f6964420102", Frame{ID: 8, Payload: Payload{Kind: KindBlobResume, BlobID: []byte{1, 2}}}},
		{"a262696408677061796c6f6164a16a426c6f624f6666736574a1666f6666736574183c", Frame{ID: 8, Payload: Payload{Kind: KindBlobOffset, Offset: 60}}},
		{"a262696409677061796c6f6164a16d4e6f7469667948696e74536574a16375726c781968747470733a2f2f6578616d706c652e696e76616c69642f78", Frame{ID: 9, Payload: Payload{Kind: KindNotifyHintSet, URL: "https://example.invalid/x"}}},
	}
	for _, v := range vectors {
		want, _ := hex.DecodeString(v.hex)
		got, err := Encode(v.frame)
		if err != nil || !bytes.Equal(got, want) {
			t.Errorf("%s: encode mismatch (%v)\n got %x\nwant %x", v.frame.Payload.Kind, err, got, want)
		}
		dec, err := Decode(want)
		if err != nil || dec.Payload.Kind != v.frame.Payload.Kind || dec.Payload.Size != v.frame.Payload.Size ||
			!bytes.Equal(dec.Payload.BlobID, v.frame.Payload.BlobID) || !bytes.Equal(dec.Payload.Data, v.frame.Payload.Data) ||
			dec.Payload.Offset != v.frame.Payload.Offset || dec.Payload.Length != v.frame.Payload.Length ||
			dec.Payload.TotalSize != v.frame.Payload.TotalSize || dec.Payload.EffectiveExpiry != v.frame.Payload.EffectiveExpiry {
			t.Errorf("%s: decode mismatch (%v): %+v", v.frame.Payload.Kind, err, dec.Payload)
		}
	}
}

func TestCodecMatchesRustVectorsManifests(t *testing.T) {
	vectors := []struct {
		hex   string
		frame Frame
	}{
		{"a262696403677061796c6f6164a16b4d616e6966657374476574a16b6964656e746974795f69644409090909", Frame{ID: 3, Payload: Payload{Kind: KindManifestGet, IdentityID: []byte{9, 9, 9, 9}}}},
		{"a262696403677061796c6f6164a16e4d616e69666573744c6174657374a1686d616e696665737442aabb", Frame{ID: 3, Payload: Payload{Kind: KindManifestLatest, Manifest: []byte{0xaa, 0xbb}}}},
		{"a262696404677061796c6f6164a16f5265636f7665724964656e74697479a2686d616e696665737441036a63726564656e7469616c420102", Frame{ID: 4, Payload: Payload{Kind: KindRecoverIdentity, Credential: []byte{1, 2}, Manifest: []byte{3}}}},
		{"a262696404677061796c6f6164a1695265636f7665726564a26b6964656e746974795f69644209097170726576696f75735f73657175656e636502", Frame{ID: 4, Payload: Payload{Kind: KindRecovered, IdentityID: []byte{9, 9}, PreviousSequence: 2}}},
	}
	for _, v := range vectors {
		want, _ := hex.DecodeString(v.hex)
		got, err := Encode(v.frame)
		if err != nil || !bytes.Equal(got, want) {
			t.Errorf("%s: encode mismatch (%v)\n got %x\nwant %x", v.frame.Payload.Kind, err, got, want)
		}
		dec, err := Decode(want)
		if err != nil || dec.Payload.Kind != v.frame.Payload.Kind ||
			!bytes.Equal(dec.Payload.IdentityID, v.frame.Payload.IdentityID) ||
			!bytes.Equal(dec.Payload.Manifest, v.frame.Payload.Manifest) {
			t.Errorf("%s: decode mismatch (%v): %+v", v.frame.Payload.Kind, err, dec.Payload)
		}
	}
}

func TestCodecMatchesRustVectorsPairing(t *testing.T) {
	vectors := []struct {
		hex   string
		frame Frame
	}{
		{"a262696405677061796c6f61646950616972426567696e", Frame{ID: 5, Payload: Payload{Kind: KindPairBegin}}},
		{"a262696405677061796c6f6164a16b5061697253746172746564a367706169725f69644201026a6361706162696c69747941036a657870697265735f617409", Frame{ID: 5, Payload: Payload{Kind: KindPairStarted, PairID: []byte{1, 2}, Capability: []byte{3}, ExpiresAt: 9}}},
		{"a262696406677061796c6f6164a16750616972507574a4646461746142040564736c6f74616167706169725f69644201026a6361706162696c6974794103", Frame{ID: 6, Payload: Payload{Kind: KindPairPut, PairID: []byte{1, 2}, Capability: []byte{3}, Slot: "a", Data: []byte{4, 5}}}},
		{"a262696407677061796c6f6164a16750616972476574a364736c6f74616267706169725f69644201026a6361706162696c6974794103", Frame{ID: 7, Payload: Payload{Kind: KindPairGet, PairID: []byte{1, 2}, Capability: []byte{3}, Slot: "b"}}},
		{"a262696407677061796c6f6164a16b5061697246657463686564a164646174614106", Frame{ID: 7, Payload: Payload{Kind: KindPairFetched, Data: []byte{6}}}},
	}
	for _, v := range vectors {
		want, _ := hex.DecodeString(v.hex)
		got, err := Encode(v.frame)
		if err != nil || !bytes.Equal(got, want) {
			t.Errorf("%s: encode mismatch (%v)\n got %x\nwant %x", v.frame.Payload.Kind, err, got, want)
		}
		dec, err := Decode(want)
		if err != nil || dec.Payload.Kind != v.frame.Payload.Kind ||
			!bytes.Equal(dec.Payload.PairID, v.frame.Payload.PairID) ||
			!bytes.Equal(dec.Payload.Capability, v.frame.Payload.Capability) ||
			dec.Payload.Slot != v.frame.Payload.Slot ||
			!bytes.Equal(dec.Payload.Data, v.frame.Payload.Data) ||
			dec.Payload.ExpiresAt != v.frame.Payload.ExpiresAt {
			t.Errorf("%s: decode mismatch (%v): %+v", v.frame.Payload.Kind, err, dec.Payload)
		}
	}
}
