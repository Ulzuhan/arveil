package metrics

import (
	"strings"
	"testing"
)

func TestOutputIsLoadOnly(t *testing.T) {
	ConnectionsTotal.Store(7)
	EnvelopesStored.Store(3)
	var b strings.Builder
	if err := WriteTo(&b, Snapshot{ActiveConnections: 2}); err != nil {
		t.Fatal(err)
	}
	out := b.String()
	for _, want := range []string{
		"arveil_connections_total 7",
		"arveil_connections_active 2",
		"arveil_envelopes_stored_total 3",
		"# TYPE arveil_uptime_seconds counter",
	} {
		if !strings.Contains(out, want) {
			t.Errorf("missing %q in:\n%s", want, out)
		}
	}
	// No labels at all: a label is where a per-identity or per-mailbox
	// dimension would arrive, and there is no reason to have one here.
	// Help text may say "mailbox"; a sample may not carry one.
	for _, line := range strings.Split(out, "\n") {
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		if strings.ContainsAny(line, "{}") {
			t.Errorf("a sample carries labels: %q", line)
		}
		if fields := strings.Fields(line); len(fields) != 2 {
			t.Errorf("a sample is not `name value`: %q", line)
		}
	}
}
