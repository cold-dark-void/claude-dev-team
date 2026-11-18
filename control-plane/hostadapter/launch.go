package hostadapter

import (
	"encoding/json"
	"fmt"
	"strings"
)

// spec is one host's session contract, sourced from the capability matrix.
// The adapter realizes the host layer only through these per-host values —
// the argv and the wire frames the node agent's runner carries — never by
// exec'ing a host CLI itself (AC1).
type spec struct {
	// LaunchCommand and LaunchArgs are the headless launch of a steerable
	// session: the matrix (b) working invocation per host.
	LaunchCommand string
	LaunchArgs    []string

	// SessionIDFromLine extracts the session id from one line of the
	// session's output — the matrix AC-4 session-id source, captured at
	// start. Empty output means "not on this line".
	SessionIDFromLine func(line string) string

	// Resume is the AC-4 named resume invocation of the host, distinct
	// from the steerable launch (review B1).
	Resume resumeSpec

	// SteerFrame encodes one correction into the host's control-message
	// wire format. The message is untrusted text: it travels as data inside
	// the frame (AGENTS.md § Code Conventions), and the node agent delivers
	// the frame at the next step boundary — never mid-turn.
	SteerFrame func(sessionID, message string, seq int) string
}

// resumeSpec is the AC-4 named resume invocation of one host: a distinct
// headless invocation, not the steerable launch. The resume flags live on
// the headless route the matrix names — `grok agent stdio` accepts no
// resume flags (`grok agent stdio --help`: only --debug, --debug-file,
// --leader-socket, -h), so appending them to the steerable launch would die
// at argv parse (CDT-648 review B1).
type resumeSpec struct {
	// Command is the host CLI of the resume invocation.
	Command string
	// ByID resumes one captured session id: the matrix AC-4 flag plus the
	// headless output mode that carries the session id.
	ByID func(id string) []string
	// Continue resumes the newest session in the working directory; nil
	// when the host's matrix row names no steerable continue path.
	Continue []string
	// Fork resumes into a new session id; nil when the host names no fork
	// path (only Grok's matrix row carries --fork-session).
	Fork func(id string) []string
}

// omniJSON builds one compact JSON object from ordered key/value pairs. A
// value that is already JSON (json.RawMessage) is embedded verbatim. The
// steer encoders use it so untrusted text never reaches a shell or a command
// line — it is marshalled as data or not at all.
func omniJSON(pairs ...any) string {
	var b strings.Builder
	b.WriteByte('{')
	for i := 0; i < len(pairs); i += 2 {
		if i > 0 {
			b.WriteByte(',')
		}
		k, _ := json.Marshal(pairs[i])
		b.Write(k)
		b.WriteByte(':')
		switch v := pairs[i+1].(type) {
		case json.RawMessage:
			b.Write(v)
		case []any:
			inner := make([]string, 0, len(v))
			for _, e := range v {
				inner = append(inner, encodeValue(e))
			}
			b.WriteByte('[')
			b.WriteString(strings.Join(inner, ","))
			b.WriteByte(']')
		default:
			b.WriteString(encodeValue(v))
		}
	}
	b.WriteByte('}')
	return b.String()
}

// encodeValue marshals one JSON value, passing pre-encoded JSON through.
func encodeValue(v any) string {
	if raw, ok := v.(json.RawMessage); ok {
		return string(raw)
	}
	out, _ := json.Marshal(v)
	return string(out)
}

// specs is the per-host contract table. Every field cites the matrix row or
// probe that fixes it.
var specs = map[Host]spec{
	// Claude Code 2.1.325 — matrix (b) P-CC-B working invocation; AC-4
	// resume `claude -p --resume <session-id>` with the id from the
	// stream-json system/init event; steer P-CC-C (stream-json user
	// message, absorbed_mid_turn at the next step boundary). The AC-4 row
	// names `-c/--continue` only parenthetically on the interactive route,
	// so no steerable continue invocation is encoded here.
	HostClaudeCode: {
		LaunchCommand: "claude",
		LaunchArgs: []string{
			"-p", "--verbose",
			"--input-format", "stream-json",
			"--output-format", "stream-json",
			"--include-hook-events",
			"--replay-user-messages",
		},
		SessionIDFromLine: typedSessionID("session_id", "system", "init"),
		Resume: resumeSpec{
			Command: "claude",
			ByID:    func(id string) []string { return []string{"-p", "--resume", id} },
		},
		SteerFrame: func(_, message string, _ int) string {
			return omniJSON("type", "user", "message", json.RawMessage(omniJSON(
				"role", "user",
				"content", []any{json.RawMessage(omniJSON("type", "text", "text", message))})))
		},
	},

	// Grok 1.0.77 — ACP transport (`grok agent stdio`) is the streaming
	// conversational route the steer probes ran on (P-GK native +
	// P-GK-CTR-3c); the single-turn `-p` route has no mid-run injection
	// surface (matrix (b)). AC-4 resume rides the headless route, not the
	// steerable one — `grok agent stdio --help` accepts no resume flags
	// (review B1): `grok -p --output-format json --resume <id>` is the
	// P-GK probe invocation, `-c/--continue` resumes the newest session in
	// the cwd, and `--fork-session` resumes into a new session id; the
	// session id comes from the headless json result's `sessionId` field.
	HostGrok: {
		LaunchCommand:     "grok",
		LaunchArgs:        []string{"agent", "--always-approve", "stdio"},
		SessionIDFromLine: sessionIDField("sessionId"),
		Resume: resumeSpec{
			Command:  "grok",
			ByID:     func(id string) []string { return []string{"-p", "--output-format", "json", "--resume", id} },
			Continue: []string{"-p", "--output-format", "json", "--continue"},
			Fork: func(id string) []string {
				return []string{"-p", "--output-format", "json", "--resume", id, "--fork-session"}
			},
		},
		SteerFrame: func(sessionID, message string, seq int) string {
			// ACP session/prompt (JSON-RPC): the second prompt merges into
			// the running turn (P-GK-CTR-3c) — delivered at the next step
			// boundary, never a separate turn.
			//
			// C8 wiring scope (review N3): over the ACP transport the
			// session id arrives in the initialize/session/new response
			// frames, not in a line the headless-json parser matches. A
			// live Grok session therefore needs an ACP-aware capture wired
			// before a steer can name the session.
			return omniJSON(
				"jsonrpc", "2.0",
				"id", seq,
				"method", "session/prompt",
				"params", json.RawMessage(omniJSON(
					"sessionId", sessionID,
					"prompt", []any{json.RawMessage(omniJSON("type", "text", "text", message))})))
		},
	},

	// omp — RPC mode is the steerable route (P-OMP-C-C: the
	// {"type":"steer"} command); AC-4 resume `-r, --resume=<value>` (by id
	// prefix, session path, or picker) or `-c, --continue` for the previous
	// session — one option, one spelling (review B2) — riding the P-OMP-C-A
	// probe invocation `omp -p --mode json -r <id>`; the session id comes
	// from the {"type":"session","id":…} frame.
	HostOmp: {
		LaunchCommand:     "omp",
		LaunchArgs:        []string{"--mode", "rpc"},
		SessionIDFromLine: typedSessionID("id", "session", ""),
		Resume: resumeSpec{
			Command:  "omp",
			ByID:     func(id string) []string { return []string{"-p", "--mode", "json", "-r", id} },
			Continue: []string{"-p", "--mode", "json", "--continue"},
		},
		SteerFrame: func(_, message string, _ int) string {
			return omniJSON("type", "steer", "message", message)
		},
	},

	// mini-swe — documentation-only host: no streaming route, no resume
	// flag, no steer mechanism (matrix mini-swe rows; T-06). The adapter
	// refuses every route; the spec exists so the closed host set has one
	// row per host.
	HostMiniSwe: {},
}

// specOf returns the contract of one host. An unknown host is a named error.
func specOf(h Host) (spec, error) {
	if !ValidHost(h) {
		return spec{}, fmt.Errorf("%w: %q is not one of %s", ErrUnknownHost, h, hostList())
	}
	return specs[h], nil
}

// sessionIDField returns a line parser that reads a JSON object and returns
// the string value of the named field. It is the shared shape of the three
// matrix session-id sources: Claude Code's stream-json system/init
// ("session_id"), Grok's headless json result ("sessionId"), and omp's
// session frame ("id"). A line that is not such an object yields "".
func sessionIDField(field string) func(string) string {
	return func(line string) string {
		line = strings.TrimSpace(line)
		if line == "" || line[0] != '{' {
			return ""
		}
		var obj map[string]json.RawMessage
		if err := json.Unmarshal([]byte(line), &obj); err != nil {
			return ""
		}
		raw, ok := obj[field]
		if !ok {
			return ""
		}
		var id string
		if err := json.Unmarshal(raw, &id); err != nil {
			return ""
		}
		return id
	}
}

// typedSessionID returns a line parser like sessionIDField but gated on the
// frame type (and subtype when non-empty). It pins the parser to the exact
// frame the matrix names — Claude Code's stream-json system/init event and
// omp's {"type":"session"} frame — so an unrelated "id" field on another
// frame never stands in for the session id.
func typedSessionID(field, typeName, subtype string) func(string) string {
	inner := sessionIDField(field)
	return func(line string) string {
		trimmed := strings.TrimSpace(line)
		if trimmed == "" || trimmed[0] != '{' {
			return ""
		}
		var obj map[string]json.RawMessage
		if err := json.Unmarshal([]byte(trimmed), &obj); err != nil {
			return ""
		}
		var t string
		if raw, ok := obj["type"]; ok {
			_ = json.Unmarshal(raw, &t)
		}
		if t != typeName {
			return ""
		}
		if subtype != "" {
			var sub string
			if raw, ok := obj["subtype"]; ok {
				_ = json.Unmarshal(raw, &sub)
			}
			if sub != subtype {
				return ""
			}
		}
		return inner(trimmed)
	}
}
