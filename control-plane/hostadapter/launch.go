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

	// PremiseFrame encodes the work premise into the host's first-turn wire
	// frame (SPEC-044 CDT-665). It answers ok=false when the frame cannot
	// render yet: the ACP transport names the session in the frame, so a
	// Grok premise waits for the captured session id (probe P-GK-ACP-1).
	// nil is the matrix refusal — mini-swe, the host with no steerable
	// route.
	PremiseFrame func(sessionID, premise string, seq int) (frame string, ok bool)

	// HandshakeFrames encodes the client half of the host's session
	// transport (SPEC-044 CDT-679): the frames the node agent writes on the
	// child's stdin, in order, before the host answers anything. cwd is the
	// working directory the child inherited at spawn. nil means the host
	// opens its session on its own transport — Claude Code, omp, and
	// mini-swe name no handshake.
	HandshakeFrames func(cwd string) []string
}

// The ACP request ids of the client handshake, pinned to the recorded probe
// transcript (P-GK-ACP-1): initialize answers id 0, session/new answers id 1.
// The capture reads the session/new answer — and its error — by that id.
const (
	acpInitializeRequestID = 0
	acpSessionNewRequestID = 1
)

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

// streamJSONUserFrame is Claude Code's stdin frame on the stream-json route:
// a user message, absorbed at the next step boundary as a correction
// (P-CC-C) and read as the prompt as the session's first turn (CDT-665). The
// frame names no session.
func streamJSONUserFrame(_, message string, _ int) string {
	return omniJSON("type", "user", "message", json.RawMessage(omniJSON(
		"role", "user",
		"content", []any{json.RawMessage(omniJSON("type", "text", "text", message))})))
}

// grokPromptFrame is Grok's ACP session/prompt frame (JSON-RPC): the second
// prompt merges into the running turn (P-GK-CTR-3c) and the first prompt
// opens the session (CDT-665). The transport names the session in the frame,
// and the id arrives in the session/new response (probe P-GK-ACP-1), so the
// premise rides the tick that captures it.
func grokPromptFrame(sessionID, message string, seq int) string {
	return omniJSON(
		"jsonrpc", "2.0",
		"id", seq,
		"method", "session/prompt",
		"params", json.RawMessage(omniJSON(
			"sessionId", sessionID,
			"prompt", []any{json.RawMessage(omniJSON("type", "text", "text", message))})))
}

// grokHandshakeFrames is the client half of Grok's ACP transport (SPEC-044
// CDT-679 AC1, probe P-GK-ACP-1): `initialize`, `notifications/initialized`,
// and `session/new` naming the working directory. The agent answers nothing
// before them, so a spawn that writes no handshake idles forever.
//
// The client capabilities are the P-GK-CTR-3c adapter constraint:
// `terminal: false`. With terminal capability the agent issues `terminal/*`
// client requests the node agent never answers, and the turn stalls
// (P-GK-CTR-3b, the recorded failed variant); the `fs` cells are the probe's
// — the node agent answers no client request at all.
func grokHandshakeFrames(cwd string) []string {
	return []string{
		omniJSON("jsonrpc", "2.0", "id", acpInitializeRequestID, "method", "initialize",
			"params", json.RawMessage(omniJSON(
				"protocolVersion", 1,
				"clientCapabilities", json.RawMessage(omniJSON(
					"terminal", false,
					"fs", json.RawMessage(omniJSON(
						"readTextFile", false, "writeTextFile", false))))))),
		omniJSON("jsonrpc", "2.0", "method", "notifications/initialized"),
		omniJSON("jsonrpc", "2.0", "id", acpSessionNewRequestID, "method", "session/new",
			"params", json.RawMessage(omniJSON("cwd", cwd, "mcpServers", []any{}))),
	}
}

// ompSteerFrame is omp's RPC steer command (P-OMP-C-C): it enters the
// steering queue and is delivered at the step boundary. The command names no
// session.
func ompSteerFrame(_, message string, _ int) string {
	return omniJSON("type", "steer", "message", message)
}

// frameIgnoresSession adapts a frame builder whose frame names no session to
// the premise contract: it renders on the first tick.
func frameIgnoresSession(build func(sessionID, message string, seq int) string) func(string, string, int) (string, bool) {
	return func(sessionID, message string, seq int) (string, bool) {
		return build(sessionID, message, seq), true
	}
}

// frameNeedsSession adapts a frame builder that names the session to the
// premise contract: the premise is the session's first turn, so a frame with
// no id to name is not renderable — the node agent retries on the next poll
// tick (SPEC-044 CDT-665 AC1).
func frameNeedsSession(build func(sessionID, message string, seq int) string) func(string, string, int) (string, bool) {
	return func(sessionID, message string, seq int) (string, bool) {
		if sessionID == "" {
			return "", false
		}
		return build(sessionID, message, seq), true
	}
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
		SteerFrame:   streamJSONUserFrame,
		PremiseFrame: frameIgnoresSession(streamJSONUserFrame),
	},

	// Grok 1.0.92 — ACP transport (`grok agent --always-approve stdio`) is the
	// streaming conversational route the steer probes ran on (P-GK native +
	// P-GK-CTR-3c); the single-turn `-p` route has no mid-run injection
	// surface (matrix (b)). AC-4 resume rides the headless route, not the
	// steerable one — `grok agent stdio --help` accepts no resume flags
	// (review B1): `grok -p --output-format json --resume <id>` is the
	// P-GK probe invocation, `-c/--continue` resumes the newest session in
	// the cwd, and `--fork-session` resumes into a new session id; the
	// session id comes from the headless json result's `sessionId` field or,
	// over the ACP transport, the `session/new` response frame
	// (`acpSessionID`, probe P-GK-ACP-1).
	HostGrok: {
		LaunchCommand:     "grok",
		LaunchArgs:        []string{"agent", "--always-approve", "stdio"},
		SessionIDFromLine: acpSessionID(),
		Resume: resumeSpec{
			Command:  "grok",
			ByID:     func(id string) []string { return []string{"-p", "--output-format", "json", "--resume", id} },
			Continue: []string{"-p", "--output-format", "json", "--continue"},
			Fork: func(id string) []string {
				return []string{"-p", "--output-format", "json", "--resume", id, "--fork-session"}
			},
		},
		// ACP session/prompt (JSON-RPC) is both frames: the second prompt
		// merges into the running turn (P-GK-CTR-3c) — delivered at the next
		// step boundary, never a separate turn — and the first prompt opens
		// the session (CDT-665). Over the ACP transport the session id
		// arrives in the session/new response frame, which `acpSessionID`
		// reads (CDT-661), so a live ACP session is capture-named and both
		// frames can name it.
		SteerFrame:   grokPromptFrame,
		PremiseFrame: frameNeedsSession(grokPromptFrame),
		// ACP is client-driven: these three frames open the session whose
		// id the capture reads and the premise names (CDT-679 AC1).
		HandshakeFrames: grokHandshakeFrames,
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
		SteerFrame:   ompSteerFrame,
		PremiseFrame: frameIgnoresSession(ompSteerFrame),
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

// acpSessionID returns the Grok session-id source of both Grok routes: the
// headless json result's top-level "sessionId", and the ACP transport's
// response frame, where the id rides the result object
// (`{"jsonrpc":"2.0","id":…,"result":{"sessionId":"…"}}`).
//
// The ACP half is probe P-GK-ACP-1 (grok 1.0.92, 2026-11-24), reproduced by
// probe P-GK-ACP-2 the same day: the session/new response is the frame that
// names the id, and the initialize response carries none (its result is
// protocolVersion, agentCapabilities, authMethods, and `_meta.agentId` only) —
// so the matcher reads `result.sessionId` from any response frame and needs no
// method-name match. ACP notification frames carry the id as
// `params.sessionId`, and the probe names it in a `session/setup` notification
// (frame 7) before the response answers (frame 17, `id: 1`); reading
// notifications stays out of scope — a frame with an `id` is the answer the
// session is opened by, a notification is progress.
//
// Recorded transcript: testdata/grok-acp-session-frames.jsonl — the probe's
// first four frames (initialize response, two session/setup notifications, the
// session/new response).
func acpSessionID() func(string) string {
	field := sessionIDField("sessionId")
	return func(line string) string {
		if id := field(line); id != "" {
			return id
		}
		trimmed := strings.TrimSpace(line)
		if trimmed == "" || trimmed[0] != '{' {
			return ""
		}
		var frame map[string]json.RawMessage
		if json.Unmarshal([]byte(trimmed), &frame) != nil {
			return ""
		}
		raw, ok := frame["result"]
		if !ok {
			return ""
		}
		return field(string(raw))
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
