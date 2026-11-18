// Package hostadapter is the host adapter of control plane Option C+
// (CDT-626; CDT-628 C6, CDT-648): the per-host driver that starts, resumes,
// steers, and observes a host session (CONTEXT.md § Host adapter).
//
// # The adapter calls the node agent only (AC1)
//
// Every host action goes through the node agent's four-verb contract
// (control-plane/agent: start, stop, status, steer). The adapter never execs
// a host CLI — claude, grok, omp — itself: the per-host layer is data (the
// launch argv, the resume flags, the control-message frames, the session-id
// sources) that the agent's native runner carries. The agent spawns one
// host-CLI process per run slot, tracks its PID, and delivers every control
// message at a step boundary.
//
// # The capability matrix is the gate (AC4, AC6)
//
// docs/internal/control-plane/host-capability-matrix.md is the SoT for what
// each host supports. The registry in matrix.go encodes the adapter routes —
// resume (a), headless streaming (b), steer (c) — as host × capability cells
// with their verdicts and citations. A route whose cell is not supported
// returns the cell verdict as a typed refusal (Refusal, carrying
// ErrUnsupportedCapability) — never a silent no-op. mini-swe is
// documentation-only in the matrix: no resume, no steer, no streaming route,
// and every one of its routes refuses with the doc citation.
//
// # Resume follows the named path per host (AC2)
//
// Resume re-spawns the host session with the headless invocation the matrix
// AC-4 section names — a route distinct from the steerable launch, because
// the resume flags live on the headless route only (review B1: `grok agent
// stdio --help` accepts no resume flags) — riding the session id captured at
// start:
//
//   - Claude Code: claude -p --resume <session-id>; the session id comes
//     from the stream-json system/init event.
//   - Grok: grok -p --output-format json --resume <SESSION_ID_OR_TITLE>,
//     with -c/--continue (newest session in the cwd) and --fork-session
//     (resume into a new session id) on the same headless route; the
//     session id comes from the headless --output-format json result's
//     sessionId field.
//   - omp: omp -p --mode json -r <id> (id prefix, session path, or picker)
//     or --continue; the session id comes from the
//     {"type":"session","id":…} frame.
//
// The machine side needs no new state: the node agent's recovery resumes a
// halted:stalled run through the machine's run_resumed verb and re-spawns
// the runner as the next attempt (the CDT-626 adoption policy), so the
// adapter adds no run state and no event kind, and the lifecycle graph
// (CDT-642) is unchanged. C8 wiring scope (review N2): wiring Resume to
// that recovery on a halted run — instead of a fresh claim — lands with the
// C8 run orchestration. C8 wiring scope (review N4): steer delivery into a
// live ACP session (the initialize/session/new handshake the probes ran)
// lands with the C8 live-session wiring; the frame encodings here are the
// per-host contracts it will carry.
//
// # Steer never interrupts a turn (AC3)
//
// The glossary Steer term — "a message delivered to a running session at its
// next step boundary" — is written unchanged in CONTEXT.md and held by six
// reproduced probes (P-CC-C, P-GK native + P-GK-CTR-3c, P-OMP-C-C, and the
// container P-CON-STEER row). The adapter encodes the correction into the
// host's control-message frame and hands it to the node agent's steer verb;
// the agent delivers it at the next step boundary and never mid-turn.
//
// # The B7 proven-name rule (AC5)
//
// The omp provider env-var names are proven on-box, not guessed: the B7
// probe ran omp headless against each provider with a dummy, non-routing
// value in exactly one candidate variable and recorded the provider-side
// auth failure that names the bad key (credentials.md § "Gap 2 — resolved").
// The adapter injects only a proven name (credentials.go); an unproven name
// fails closed with ErrCredentialNameUnproven — no fallback chain, no
// guess. The values travel as environment entries for the runner process
// only: never argv, never a shell string, never a journal row, never a log.
//
// # Trust rule (AGENTS.md § Code Conventions)
//
// Every value arrives as argv, an environment entry, a JSON config field, or
// a Go value. The steer message is untrusted text — it is marshalled as data
// into the host's frame, never assembled into a command or a shell string.
package hostadapter
