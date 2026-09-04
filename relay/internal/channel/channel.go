package channel

import "fmt"

// Channel composes transport, fragmentation and codec, like arveil-core's
// `Channel`. Seal returns the carrier messages for one frame; Open consumes
// one carrier message and returns a frame when complete.
type Channel struct {
	t *Transport
	r *Reassembler
}

func NewChannel(t *Transport) *Channel {
	return &Channel{t: t, r: NewReassembler(MaxFrameBytes)}
}

func (c *Channel) RemoteStatic() []byte { return c.t.RemoteStatic() }

func (c *Channel) Seal(f Frame) ([][]byte, error) {
	b, err := Encode(f)
	if err != nil {
		return nil, err
	}
	frags := Fragments(b)
	out := make([][]byte, 0, len(frags))
	for _, frag := range frags {
		m, err := c.t.Seal(frag)
		if err != nil {
			return nil, err
		}
		out = append(out, m)
	}
	return out, nil
}

func (c *Channel) Open(message []byte) (f Frame, ok bool, err error) {
	frag, err := c.t.Open(message)
	if err != nil {
		return Frame{}, false, fmt.Errorf("channel: %w", err)
	}
	b, done, err := c.r.Push(frag)
	if err != nil {
		return Frame{}, false, err
	}
	if !done {
		return Frame{}, false, nil
	}
	f, err = Decode(b)
	if err != nil {
		return Frame{}, false, err
	}
	return f, true, nil
}
