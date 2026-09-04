package main

import (
	"archive/tar"
	"compress/gzip"
	"context"
	"flag"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"

	"github.com/Ulzuhan/arveil/relay/internal/store"
)

// Backup and restore (M4.5). What a realm is made of: the database, the
// realm's own keys, and the committed blobs. Staging uploads are left out
// on purpose, since they are half-written by definition and the client
// resumes or restarts them.
//
// The database is copied first with VACUUM INTO, which is consistent under
// WAL while the relay keeps serving, and the blobs afterwards. A blob
// committed between the two steps is harmless: the database is the source
// of truth and the reconciler removes files that have no row.
const (
	backupDB      = "realm.db"
	backupSecrets = "server-secrets"
	backupBlobs   = "blobs"
)

func backupCommand(args []string) int {
	fs := flag.NewFlagSet("backup", flag.ContinueOnError)
	dataDir := fs.String("data-dir", "./data", "relay data directory to back up")
	out := fs.String("out", "", "archive to write (.tar.gz); required")
	if err := fs.Parse(args); err != nil {
		return 2
	}
	if *out == "" {
		fmt.Fprintln(os.Stderr, "backup: -out is required")
		return 2
	}
	if err := runBackup(*dataDir, *out); err != nil {
		fmt.Fprintf(os.Stderr, "backup: %v\n", err)
		return 1
	}
	return 0
}

func runBackup(dataDir, out string) error {
	st, err := store.Open(filepath.Join(dataDir, backupDB))
	if err != nil {
		return fmt.Errorf("open store: %w", err)
	}
	defer st.Close()

	tmp, err := os.MkdirTemp(filepath.Dir(out), ".arveil-backup-")
	if err != nil {
		return err
	}
	defer os.RemoveAll(tmp)
	snapshot := filepath.Join(tmp, backupDB)
	if err := st.BackupTo(context.Background(), snapshot); err != nil {
		return fmt.Errorf("snapshot database: %w", err)
	}

	f, err := os.OpenFile(out, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0o600)
	if err != nil {
		return err
	}
	defer f.Close()
	gz := gzip.NewWriter(f)
	tw := tar.NewWriter(gz)

	if err := addFile(tw, snapshot, backupDB); err != nil {
		return err
	}
	files := 0
	for _, dir := range []string{backupSecrets, backupBlobs} {
		n, err := addDir(tw, filepath.Join(dataDir, dir), dir)
		if err != nil {
			return err
		}
		files += n
	}
	if err := tw.Close(); err != nil {
		return err
	}
	if err := gz.Close(); err != nil {
		return err
	}
	if err := f.Sync(); err != nil {
		return err
	}
	info, err := f.Stat()
	if err != nil {
		return err
	}
	fmt.Printf("backup: %s written (%d bytes, database plus %d file(s))\n", out, info.Size(), files)
	fmt.Println("It holds the realm's private keys: encrypt it and keep it away from the realm.")
	return nil
}

func addFile(tw *tar.Writer, path, name string) error {
	info, err := os.Stat(path)
	if err != nil {
		return err
	}
	if err := tw.WriteHeader(&tar.Header{
		Name: name, Mode: 0o600, Size: info.Size(), ModTime: info.ModTime(), Typeflag: tar.TypeReg,
	}); err != nil {
		return err
	}
	src, err := os.Open(path)
	if err != nil {
		return err
	}
	defer src.Close()
	_, err = io.Copy(tw, src)
	return err
}

func addDir(tw *tar.Writer, dir, prefix string) (int, error) {
	entries, err := os.ReadDir(dir)
	if os.IsNotExist(err) {
		return 0, nil
	}
	if err != nil {
		return 0, err
	}
	n := 0
	for _, e := range entries {
		if e.IsDir() {
			continue
		}
		if err := addFile(tw, filepath.Join(dir, e.Name()), prefix+"/"+e.Name()); err != nil {
			return n, err
		}
		n++
	}
	return n, nil
}

func restoreCommand(args []string) int {
	fset := flag.NewFlagSet("restore", flag.ContinueOnError)
	in := fset.String("in", "", "archive written by `arveil-relay backup`; required")
	dataDir := fset.String("data-dir", "", "directory to restore into; must be empty or absent")
	if err := fset.Parse(args); err != nil {
		return 2
	}
	if *in == "" || *dataDir == "" {
		fmt.Fprintln(os.Stderr, "restore: -in and -data-dir are required")
		return 2
	}
	if err := runRestore(*in, *dataDir); err != nil {
		fmt.Fprintf(os.Stderr, "restore: %v\n", err)
		return 1
	}
	return 0
}

func runRestore(in, dataDir string) error {
	// Never write into a directory that already holds a realm: restoring
	// over a live one would mix two states and roll back revocations.
	if entries, err := os.ReadDir(dataDir); err == nil && len(entries) > 0 {
		return fmt.Errorf("%s is not empty; restore into a new directory and move it into place yourself", dataDir)
	}
	if err := os.MkdirAll(dataDir, 0o700); err != nil {
		return err
	}
	f, err := os.Open(in)
	if err != nil {
		return err
	}
	defer f.Close()
	gz, err := gzip.NewReader(f)
	if err != nil {
		return fmt.Errorf("not a gzip archive: %w", err)
	}
	defer gz.Close()
	tr := tar.NewReader(gz)
	files := 0
	for {
		h, err := tr.Next()
		if err == io.EOF {
			break
		}
		if err != nil {
			return err
		}
		if h.Typeflag != tar.TypeReg {
			continue
		}
		name := filepath.Clean(h.Name)
		if filepath.IsAbs(name) || strings.HasPrefix(name, "..") {
			return fmt.Errorf("archive entry %q escapes the data directory", h.Name)
		}
		target := filepath.Join(dataDir, name)
		if err := os.MkdirAll(filepath.Dir(target), 0o700); err != nil {
			return err
		}
		out, err := os.OpenFile(target, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0o600)
		if err != nil {
			return err
		}
		if _, err := io.Copy(out, tr); err != nil {
			out.Close()
			return err
		}
		if err := out.Close(); err != nil {
			return err
		}
		files++
	}
	if _, err := os.Stat(filepath.Join(dataDir, backupDB)); err != nil {
		return fmt.Errorf("the archive holds no %s", backupDB)
	}
	fmt.Printf("restore: %d file(s) into %s\n", files, dataDir)
	fmt.Println("Start the relay against it; its realm identity and every membership come back with it.")
	return nil
}
