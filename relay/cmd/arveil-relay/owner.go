package main

import (
	"context"
	"encoding/hex"
	"flag"
	"fmt"
	"os"
	"path/filepath"
	"time"

	"github.com/Ulzuhan/arveil/relay/internal/store"
)

// Host access is the authority here. This is not exposed over the network.
func makeOwnerCommand(args []string) int {
	fs := flag.NewFlagSet("make-owner", flag.ContinueOnError)
	dir := fs.String("data-dir", "./data", "relay data directory")
	id := fs.String("identity", "", "full identity id verified in the owner's app")
	if fs.Parse(args) != nil {
		return 2
	}
	identity, err := hex.DecodeString(*id)
	if err != nil || len(identity) != 32 || fs.NArg() != 0 {
		fmt.Fprintln(os.Stderr, "supply the exact 32-byte identity with -identity")
		return 2
	}
	s, err := store.Open(filepath.Join(*dir, "realm.db"))
	if err != nil {
		fmt.Fprintln(os.Stderr, "cannot open realm store")
		return 1
	}
	defer s.Close()
	if err = s.MakeOwner(context.Background(), identity, time.Now()); err != nil {
		fmt.Fprintln(os.Stderr, "owner promotion failed: identity must already be an active member")
		return 1
	}
	fmt.Println("Existing identity is now an owner; reopen Invitations in its app.")
	return 0
}
