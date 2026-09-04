package identity

import (
	"bytes"
	"crypto/ed25519"
	"encoding/hex"
	"testing"
)

// Vectors produced by arveil-core (examples/dump_vectors.rs, fixed keys).
const (
	vecRootPub        = "fd1724385aa0c75b64fb78cd602fa1d991fdebf76b13c58ed702eac835e9f618"
	vecIdentityID     = "6a4e50dca462fe613f9a80ac3519f7757d78385f217a2524e8e239b25cc07251"
	vecCredential     = "a364626f647959014ea86776657273696f6e016876616c6964697479a2696e6f745f61667465721a713fb3006a6e6f745f6265666f72651a6553f100696465766963655f696450111111111111111111111111111111116c616c6c6f7765645f75736573037818656e76656c6f70655f68706b655f7075626c69635f6b65795820555555555555555555555555555555555555555555555555555555555555555578186964656e746974795f726f6f745f7075626c69635f6b65795820fd1724385aa0c75b64fb78cd602fa1d991fdebf76b13c58ed702eac835e9f61878186d6c735f7369676e61747572655f7075626c69635f6b657958202222222222222222222222222222222222222222222222222222222222222222781a7472616e73706f72745f6e6f6973655f7075626c69635f6b65795820444444444444444444444444444444444444444444444444444444444444444467636f6e74657874781b61727665696c2f6465766963652d63726564656e7469616c2f7631697369676e61747572655840ac04e722724ae180e5a549bd6ae01ce40cc15afec90d9eb66bcee7a406a510774cedb9e57a1ddf694b5ddf707ae00e22ee73547e561fcfe34f03d449fe23c005"
	vecCredentialHash = "8059375603e27049a859f724f255f79e5fc5bddbea4bc0c99eecf86bb410371e"
	vecManifest       = "a364626f647958bca66776657273696f6e016b6964656e746974795f696458206a4e50dca462fe613f9a80ac3519f7757d78385f217a2524e8e239b25cc07251716d616e69666573745f73657175656e6365017670726576696f75735f6d616e69666573745f686173684078186163746976655f63726564656e7469616c5f6861736865738158208059375603e27049a859f724f255f79e5fc5bddbea4bc0c99eecf86bb410371e78197265766f6b65645f63726564656e7469616c5f6861736865738067636f6e74657874781961727665696c2f6465766963652d6d616e69666573742f7631697369676e6174757265584048721874900121b4bb60360db910359eec6bfe43b475963d664a65597725d63891997eb1c603a866882f83af54080e61bbc47414a6af0b5adc9e459de13c4a0c"
	vecManifestHash   = "d3777ca6ca62aeb45c7b7647b011a8d4f82d700e80fd8260f5a9e5330a5fd852"
)

func h(s string) []byte { b, _ := hex.DecodeString(s); return b }

func TestCredentialAndManifestFromArveilCore(t *testing.T) {
	root := ed25519.PublicKey(h(vecRootPub))
	if !bytes.Equal(IdentityID(root), h(vecIdentityID)) {
		t.Fatal("identity id derivation differs from the core")
	}
	cred := h(vecCredential)
	v, err := VerifyCredential(cred, 1_800_000_000)
	if err != nil {
		t.Fatalf("verify credential: %v", err)
	}
	if !bytes.Equal(v.Root, root) || !bytes.Equal(v.IdentityID, h(vecIdentityID)) || !bytes.Equal(v.Hash, h(vecCredentialHash)) {
		t.Fatal("credential fields or hash differ from the core")
	}
	if v.Credential.AllowedUses != UseMLSLeaf|UseTransport {
		t.Fatalf("allowed uses %b", v.Credential.AllowedUses)
	}
	if err := v.BindsSession(bytes.Repeat([]byte{0x44}, 32)); err != nil {
		t.Fatalf("binds session: %v", err)
	}
	if err := v.BindsSession(bytes.Repeat([]byte{0x45}, 32)); err == nil {
		t.Fatal("bound to the wrong static key")
	}
	if _, err := VerifyCredential(cred, 1_950_000_000); err == nil {
		t.Fatal("expired credential accepted")
	}
	tampered := append([]byte(nil), cred...)
	tampered[len(tampered)/2] ^= 1
	if _, err := VerifyCredential(tampered, 1_800_000_000); err == nil {
		t.Fatal("tampered credential accepted")
	}

	man := h(vecManifest)
	m, err := VerifyManifest(man, root)
	if err != nil {
		t.Fatalf("verify manifest: %v", err)
	}
	if m.ManifestSequence != 1 || len(m.ActiveCredentialHashes) != 1 || !bytes.Equal(m.ActiveCredentialHashes[0], h(vecCredentialHash)) {
		t.Fatalf("manifest content: %+v", m)
	}
	if !bytes.Equal(ManifestHash(man), h(vecManifestHash)) {
		t.Fatal("manifest hash differs from the core")
	}
	other, _, _ := ed25519.GenerateKey(nil)
	if _, err := VerifyManifest(man, other); err == nil {
		t.Fatal("manifest verified with another root")
	}
}
