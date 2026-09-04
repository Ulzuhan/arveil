package server

import (
	"context"
	"net/http"

	"github.com/Ulzuhan/arveil/relay/internal/metrics"
	"net/url"
	"strings"
	"time"
)

// Notification hints (M3.4). A device may give the realm one URL to poke
// when its mailbox goes from empty to holding something. The request says
// nothing else: no sender, no size, no conversation, no identifier, and
// only that one transition, so whoever runs the notifier cannot count
// messages either. It is optional; with no URL configured nothing is sent
// and nothing is stored.
//
// What this does not hide: the realm already knew the mailbox received an
// envelope, and the notifier learns that this endpoint was poked at this
// time. That is the trade the operator is making.
const (
	// HintBody is the entire request body.
	HintBody = "arveil-hint/v1"
	// HintTimeout bounds one attempt. There are no retries: a missed hint
	// costs a later sync, and retrying would leak timing.
	HintTimeout = 5 * time.Second
	// MaxHintURL bounds what a device may store on the realm.
	MaxHintURL = 512
)

// validHintURL accepts an ordinary http(s) endpoint with no credentials.
func validHintURL(raw string) bool {
	if raw == "" || len(raw) > MaxHintURL {
		return false
	}
	u, err := url.Parse(raw)
	if err != nil || u.Host == "" || u.User != nil {
		return false
	}
	return u.Scheme == "http" || u.Scheme == "https"
}

// sendHint pokes one endpoint, best effort.
func (srv *Server) sendHint(target string) {
	ctx, cancel := context.WithTimeout(context.Background(), HintTimeout)
	defer cancel()
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, target, strings.NewReader(HintBody))
	if err != nil {
		return
	}
	req.Header.Set("Content-Type", "text/plain")
	req.Header.Set("User-Agent", "arveil-relay")
	resp, err := (&http.Client{Timeout: HintTimeout}).Do(req)
	if err != nil {
		metrics.HintsFailed.Add(1)
		// The endpoint is not named in the log: it belongs to the member.
		srv.Logger.Printf("notification hint failed")
		return
	}
	resp.Body.Close()
	metrics.HintsSent.Add(1)
	srv.Logger.Printf("notification hint sent")
}

// notifyMailbox fires the hint of the mailbox owner, if there is one.
func (srv *Server) notifyMailbox(ctx context.Context, mailboxID []byte) {
	target, err := srv.Store.NotifyHintForMailbox(ctx, mailboxID)
	if err != nil || target == "" {
		return
	}
	go srv.sendHint(target)
}
