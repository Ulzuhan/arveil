// Package metrics counts load, never people.
//
// Everything here describes how busy the realm is: connections, frames,
// envelopes, bytes. Nothing is labelled by identity, device, mailbox or
// conversation, because a metrics endpoint is exactly the place where a
// well-meaning operator would otherwise rebuild the social graph the rest
// of the design refuses to keep (THREAT_MODEL §3).
package metrics

import (
	"fmt"
	"io"
	"sync/atomic"
	"time"
)

// Counters are process-wide and monotonic unless noted.
var (
	ConnectionsTotal   atomic.Int64
	ConnectionsRefused atomic.Int64
	HandshakesFailed   atomic.Int64
	FramesHandled      atomic.Int64
	EnvelopesStored    atomic.Int64
	EnvelopesSwept     atomic.Int64
	BlobsSwept         atomic.Int64
	PairingsOpened     atomic.Int64
	PairingsRefused    atomic.Int64
	HintsSent          atomic.Int64
	HintsFailed        atomic.Int64

	start = time.Now()
)

// Gauges the caller supplies at scrape time.
type Snapshot struct {
	ActiveConnections int
}

// WriteTo renders the Prometheus text format. It is deliberately hand
// written: one dependency less in a binary an operator has to trust.
func WriteTo(w io.Writer, s Snapshot) error {
	metrics := []struct {
		name, help, kind string
		value            int64
	}{
		{"arveil_uptime_seconds", "Seconds since the relay started.", "counter", int64(time.Since(start).Seconds())},
		{"arveil_connections_total", "Channels accepted since start.", "counter", ConnectionsTotal.Load()},
		{"arveil_connections_refused_total", "Channels refused by a limit.", "counter", ConnectionsRefused.Load()},
		{"arveil_connections_active", "Channels open right now.", "gauge", int64(s.ActiveConnections)},
		{"arveil_handshakes_failed_total", "Handshakes that did not complete.", "counter", HandshakesFailed.Load()},
		{"arveil_frames_total", "Frames answered on established channels.", "counter", FramesHandled.Load()},
		{"arveil_envelopes_stored_total", "Envelopes accepted into mailboxes.", "counter", EnvelopesStored.Load()},
		{"arveil_envelopes_swept_total", "Envelopes removed after expiry.", "counter", EnvelopesSwept.Load()},
		{"arveil_blobs_swept_total", "Blobs removed after expiry.", "counter", BlobsSwept.Load()},
		{"arveil_pairings_opened_total", "Pairing rendezvous opened.", "counter", PairingsOpened.Load()},
		{"arveil_pairings_refused_total", "Pairing rendezvous refused by a limit.", "counter", PairingsRefused.Load()},
		{"arveil_notification_hints_total", "Notification hints sent.", "counter", HintsSent.Load()},
		{"arveil_notification_hints_failed_total", "Notification hints that failed.", "counter", HintsFailed.Load()},
	}
	for _, m := range metrics {
		if _, err := fmt.Fprintf(w, "# HELP %s %s\n# TYPE %s %s\n%s %d\n", m.name, m.help, m.name, m.kind, m.name, m.value); err != nil {
			return err
		}
	}
	return nil
}
