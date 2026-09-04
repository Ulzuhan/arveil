package channel

import (
	"errors"
	"fmt"
)

// Fragment wire format: flags(1 byte) || data. Bit 0 marks the last
// fragment of a frame. Fragments of one frame are contiguous on a channel.
const (
	FlagLast     byte = 0b0000_0001
	FragmentData      = MaxNoisePayload - 1
)

var (
	ErrEmptyFragment = errors.New("fragment: empty message")
	ErrTooLarge      = errors.New("fragment: reassembled frame would exceed the limit")
)

// Fragments splits encoded frame bytes; it always yields at least one.
func Fragments(b []byte) [][]byte {
	if len(b) == 0 {
		return [][]byte{{FlagLast}}
	}
	var out [][]byte
	for len(b) > 0 {
		n := min(len(b), FragmentData)
		chunk := make([]byte, 1, n+1)
		chunk = append(chunk, b[:n]...)
		b = b[n:]
		if len(b) == 0 {
			chunk[0] = FlagLast
		}
		out = append(out, chunk)
	}
	return out
}

// Reassembler is the bounded reassembly buffer of one channel.
type Reassembler struct {
	limit  int
	buffer []byte
}

func NewReassembler(limit int) *Reassembler { return &Reassembler{limit: limit} }

// Push consumes one fragment; returns the frame bytes on the last one.
func (r *Reassembler) Push(fragment []byte) (frame []byte, done bool, err error) {
	if len(fragment) == 0 {
		return nil, false, ErrEmptyFragment
	}
	flags, data := fragment[0], fragment[1:]
	if flags&^FlagLast != 0 {
		return nil, false, fmt.Errorf("fragment: unknown flags %#04x", flags)
	}
	if len(r.buffer)+len(data) > r.limit {
		r.buffer = nil
		return nil, false, ErrTooLarge
	}
	r.buffer = append(r.buffer, data...)
	if flags&FlagLast == 0 {
		return nil, false, nil
	}
	out := r.buffer
	r.buffer = nil
	return out, true, nil
}

// MidFrame reports whether a frame is partially received.
func (r *Reassembler) MidFrame() bool { return len(r.buffer) > 0 }
