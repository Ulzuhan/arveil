// Package realm holds the relay's own identity: the Ed25519 signing key that
// authenticates endpoint lists and the X25519 static key of the Noise
// channel. Both live under <data-dir>/server-secrets and are created on
// first start. They are operational secrets, never personal ones.
package realm

import (
	"crypto/ed25519"
	"crypto/rand"
	"crypto/sha256"
	"errors"
	"fmt"
	"os"
	"path/filepath"

	"github.com/flynn/noise"

	"github.com/Ulzuhan/arveil/relay/internal/channel"
)

const (
	secretsDir     = "server-secrets"
	signingKeyFile = "realm-signing.key" // 32-byte Ed25519 seed
	noiseKeyFile   = "realm-noise.key"   // 32-byte X25519 private key
	sequenceFile   = "endpoint-sequence" // decimal, monotonic

	realmIDContext = "arveil/realm-id/v1"
)

// Identity is the loaded realm identity.
type Identity struct {
	SigningKey ed25519.PrivateKey
	NoiseKey   noise.DHKey
	// ID = SHA-256(realmIDContext || signing public key).
	ID  []byte
	dir string
}

// Load reads or creates the identity under dataDir.
func Load(dataDir string) (*Identity, error) {
	dir := filepath.Join(dataDir, secretsDir)
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return nil, err
	}
	seed, err := loadOrCreate(filepath.Join(dir, signingKeyFile), 32)
	if err != nil {
		return nil, fmt.Errorf("signing key: %w", err)
	}
	priv := ed25519.NewKeyFromSeed(seed)

	nk, err := loadOrCreate(filepath.Join(dir, noiseKeyFile), 32)
	if err != nil {
		return nil, fmt.Errorf("noise key: %w", err)
	}
	noiseKey, err := channel.StaticKeypairFromPrivate(nk)
	if err != nil {
		return nil, err
	}

	h := sha256.New()
	h.Write([]byte(realmIDContext))
	h.Write(priv.Public().(ed25519.PublicKey))

	return &Identity{SigningKey: priv, NoiseKey: noiseKey, ID: h.Sum(nil), dir: dir}, nil
}

// SigningPublic is the realm's Ed25519 public key.
func (i *Identity) SigningPublic() ed25519.PublicKey {
	return i.SigningKey.Public().(ed25519.PublicKey)
}

// NextSequence increments and persists the endpoint list sequence.
// Phase 0: bumped on every start, which is monotonic and good enough until
// the list becomes operator-edited configuration.
func (i *Identity) NextSequence() (uint64, error) {
	path := filepath.Join(i.dir, sequenceFile)
	var seq uint64
	if b, err := os.ReadFile(path); err == nil {
		if _, err := fmt.Sscanf(string(b), "%d", &seq); err != nil {
			return 0, fmt.Errorf("endpoint sequence file corrupt: %w", err)
		}
	} else if !errors.Is(err, os.ErrNotExist) {
		return 0, err
	}
	seq++
	if err := writeAtomic(path, []byte(fmt.Sprintf("%d\n", seq)), 0o600); err != nil {
		return 0, err
	}
	return seq, nil
}

func loadOrCreate(path string, n int) ([]byte, error) {
	b, err := os.ReadFile(path)
	if err == nil {
		if len(b) != n {
			return nil, fmt.Errorf("%s: expected %d bytes, got %d", path, n, len(b))
		}
		return b, nil
	}
	if !errors.Is(err, os.ErrNotExist) {
		return nil, err
	}
	b = make([]byte, n)
	if _, err := rand.Read(b); err != nil {
		return nil, err
	}
	if err := writeAtomic(path, b, 0o600); err != nil {
		return nil, err
	}
	return b, nil
}

func writeAtomic(path string, data []byte, mode os.FileMode) error {
	tmp := path + ".tmp"
	if err := os.WriteFile(tmp, data, mode); err != nil {
		return err
	}
	f, err := os.Open(tmp)
	if err != nil {
		return err
	}
	if err := f.Sync(); err != nil {
		f.Close()
		return err
	}
	f.Close()
	return os.Rename(tmp, path)
}
