package hostadapter

import "sync"

// Capture records the session id of one runner session from its output
// stream (AC2: the session id is captured at start, from the matrix AC-4
// session-id source of the host). It is an io.Writer the node agent's
// runner output drains into; the bytes pass through untouched, so the
// capture never alters what the run's output surfaces carry.
type Capture struct {
	host Host

	mu   sync.Mutex
	buf  []byte
	line []byte
	id   string
}

// NewCapture returns the capture of one host session.
func NewCapture(h Host) *Capture { return &Capture{host: h} }

// Write scans the stream line by line and records the first session id the
// host's matrix AC-4 source names. Later ids never overwrite an earlier
// one: the id captured at start is the id every resume rides.
func (c *Capture) Write(p []byte) (int, error) {
	if !ValidHost(c.host) {
		// An unknown host names no source; the stream still passes through.
		return len(p), nil
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	for _, b := range p {
		if b == '\n' {
			c.consumeLine()
			continue
		}
		c.line = append(c.line, b)
	}
	return len(p), nil
}

// consumeLine parses one complete output line for the session id.
func (c *Capture) consumeLine() {
	if c.id == "" && len(c.line) > 0 {
		sp := specs[c.host]
		if id := sp.SessionIDFromLine(string(c.line)); id != "" {
			c.id = id
		}
	}
	c.line = c.line[:0]
}

// SessionID returns the captured session id, empty before the host named
// one.
func (c *Capture) SessionID() string {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.id
}
