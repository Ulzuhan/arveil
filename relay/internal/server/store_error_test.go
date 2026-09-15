package server

import (
	"bytes"
	"errors"
	"fmt"
	"log"
	"testing"

	"github.com/Ulzuhan/arveil/relay/internal/channel"
)

type privateStoreError struct{}

func (privateStoreError) Error() string { return "SQL with private parameters and a profile path" }
func (privateStoreError) Code() int     { return 517 }

func TestStoreErrorLogsOnlyOperationAndSQLiteCode(t *testing.T) {
	for _, tc := range []struct {
		name string
		err  error
		code int
	}{
		{"wrapped sqlite", fmt.Errorf("private context: %w", privateStoreError{}), 517},
		{"other storage failure", errors.New("private path and secret parameters"), 0},
	} {
		t.Run(tc.name, func(t *testing.T) {
			var output bytes.Buffer
			srv := &Server{Logger: log.New(&output, "", 0)}
			reply := srv.storeError(42, "key packages claim", tc.err)
			want := fmt.Sprintf("key packages claim: store error (sqlite_code=%d)\n", tc.code)
			if output.String() != want {
				t.Fatalf("unexpected diagnostic: %q", output.String())
			}
			if reply.ID != 42 || reply.Payload.Kind != channel.KindError ||
				reply.Payload.Code != channel.CodeInternal || reply.Payload.Message != "store error" {
				t.Fatalf("unexpected public error frame: %+v", reply)
			}
		})
	}
}
