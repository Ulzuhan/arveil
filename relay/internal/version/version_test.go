package version

import "testing"

func TestProtocolIsPreRelease(t *testing.T) {
	if Protocol != 0 {
		t.Fatalf("protocol version must stay 0 until the v1 gates are met, got %d", Protocol)
	}
}
