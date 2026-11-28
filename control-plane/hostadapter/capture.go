package hostadapter

import (
	"encoding/json"
	"fmt"
	"strings"
	"sync"
	"time"

	"github.com/cold-dark-void/claude-dev-team/control-plane/journal"
)

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
	// handshakeErr is the message of the JSON-RPC error the session/new
	// response carried (SPEC-044 CDT-679 AC3). It is read only while no
	// session id has landed: once the session is open, a response with the
	// same id is a prompt answer, not a failed handshake.
	handshakeErr string
	// lastOut is the moment the stream last landed (SPEC-044 CDT-671 AC2): the
	// progress reading, stamped from the bytes, never parsed out of them.
	lastOut time.Time
}

// NewCapture returns the capture of one host session.
func NewCapture(h Host) *Capture { return &Capture{host: h} }

// Write scans the stream line by line and records the first session id the
// host's matrix AC-4 source names. Later ids never overwrite an earlier
// one: the id captured at start is the id every resume rides.
func (c *Capture) Write(p []byte) (int, error) {
	c.stamp(p)
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

// stamp records the moment the stream last landed. It is a fact about the
// bytes, not a reading of the host, so an unknown host stamps as well: the
// progress time answers "the capture saw the stream then", nothing more
// (SPEC-044 CDT-671 AC2).
func (c *Capture) stamp(p []byte) {
	if len(p) == 0 {
		return
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	c.lastOut = time.Now().UTC()
}

// LastOutputTS returns the time the capture last saw the host's stream, in the
// journal's timestamp shape, and "" when it has seen nothing at all. It
// satisfies the agent package's ProgressSource seam, which is how the node
// agent carries the progress time without parsing host output (SPEC-044
// CDT-671 AC2).
func (c *Capture) LastOutputTS() string {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.lastOut.IsZero() {
		return ""
	}
	return journal.FormatTS(c.lastOut)
}

// consumeLine parses one complete output line for the session id, and — on a
// host whose transport the client opens (SPEC-044 CDT-679) — for the error the
// session/new response carries.
func (c *Capture) consumeLine() {
	if c.id == "" && len(c.line) > 0 {
		sp := specs[c.host]
		line := string(c.line)
		if id := sp.SessionIDFromLine(line); id != "" {
			c.id = id
		} else if sp.HandshakeFrames != nil && c.handshakeErr == "" {
			c.handshakeErr = acpSessionNewError(line)
		}
	}
	c.line = c.line[:0]
}

// acpSessionNewError reads the message of a JSON-RPC error response to the
// client's session/new request (probe P-GK-ACP-1 fixes its id), and "" for
// every other frame. A response that answers with a result is not an error;
// a notification carries no id.
func acpSessionNewError(line string) string {
	trimmed := strings.TrimSpace(line)
	if trimmed == "" || trimmed[0] != '{' {
		return ""
	}
	var frame struct {
		ID    *int `json:"id"`
		Error *struct {
			Code    int    `json:"code"`
			Message string `json:"message"`
		} `json:"error"`
	}
	if json.Unmarshal([]byte(trimmed), &frame) != nil {
		return ""
	}
	if frame.ID == nil || *frame.ID != acpSessionNewRequestID || frame.Error == nil {
		return ""
	}
	if frame.Error.Message == "" {
		return fmt.Sprintf("code %d", frame.Error.Code)
	}
	return fmt.Sprintf("code %d: %s", frame.Error.Code, frame.Error.Message)
}

// SessionID returns the captured session id, empty before the host named
// one.
func (c *Capture) SessionID() string {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.id
}

// HandshakeError reports why the host refused to open the session: the
// message of the JSON-RPC error on the session/new response, empty while the
// handshake can still land (SPEC-044 CDT-679 AC3). It satisfies the agent
// package's HandshakeSource seam, which is how the node agent learns of the
// refusal without parsing host output.
func (c *Capture) HandshakeError() string {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.handshakeErr
}
