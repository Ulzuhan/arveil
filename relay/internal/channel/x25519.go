package channel

import "golang.org/x/crypto/curve25519"

func x25519Public(private []byte) ([]byte, error) {
	return curve25519.X25519(private, curve25519.Basepoint)
}
