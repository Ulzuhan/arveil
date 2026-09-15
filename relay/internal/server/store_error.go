package server

import (
	"errors"

	"github.com/Ulzuhan/arveil/relay/internal/channel"
)

// storeError keeps SQL text, paths and parameters out of logs and replies.
// Callers supply a fixed operation label, never a value from a request.
func (srv *Server) storeError(id uint64, operation string, err error) channel.Frame {
	code := 0 // Non-SQLite errors still have a useful operation label.
	var coded interface{ Code() int }
	if errors.As(err, &coded) {
		code = coded.Code()
	}
	if srv.Logger != nil {
		srv.Logger.Printf("%s: store error (sqlite_code=%d)", operation, code)
	}
	return errFrame(id, channel.CodeInternal, "store error")
}
