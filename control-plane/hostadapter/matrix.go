package hostadapter

import (
	"fmt"
	"strings"
)

// Host is one agent host of the capability matrix
// (docs/internal/control-plane/host-capability-matrix.md § AC-1). The set is
// closed: the four hosts the matrix carries.
type Host string

// The matrix hosts, in matrix order.
const (
	HostClaudeCode Host = "claude-code"
	HostGrok       Host = "grok"
	HostOmp        Host = "omp"
	HostMiniSwe    Host = "mini-swe"
)

// Hosts is the closed host set, in matrix order.
var Hosts = []Host{HostClaudeCode, HostGrok, HostOmp, HostMiniSwe}

// ValidHost reports whether h names a matrix host.
func ValidHost(h Host) bool {
	for _, v := range Hosts {
		if v == h {
			return true
		}
	}
	return false
}

// Capability is one matrix capability the adapter routes: the three the
// adapter implements. The matrix's other capabilities (hooks, workflow
// compatibility, memory, Intercom) are not adapter routes and are not in the
// registry.
type Capability string

const (
	// CapResume is capability (a): session resume after process death —
	// the matrix AC-4 named path (CLI flag plus session-id source).
	CapResume Capability = "resume"
	// CapHeadlessStream is capability (b): headless mode with streaming
	// input and output — the launch path a steerable session needs.
	CapHeadlessStream Capability = "headless-streaming"
	// CapSteer is capability (c): steer delivery at the next step boundary
	// (AC-3, six probes).
	CapSteer Capability = "steer"
)

// Verdict is the index vocabulary of docs/internal/control-plane/index.md:
// supported, unsupported, unverified-after-attempt. Matrix cells carry one of
// these (T-10 note 6: mini-swe's documentation-only "partial" cells stay in
// the matrix prose; the registry scores them by their finding — a
// documentation-only absence of a mechanism is an unsupported verdict with
// the doc citation).
type Verdict string

const (
	VerdictSupported   Verdict = "supported"
	VerdictUnsupported Verdict = "unsupported"
	VerdictUnverified  Verdict = "unverified-after-attempt"
)

// Cell is one matrix cell: the verdict and the evidence citation of one host
// × capability pair (AC-2: every cell carries its source). The adapter
// refuses a route whose cell is not supported, and the refusal carries this
// cell back to the caller (AC6).
type Cell struct {
	Host       Host
	Capability Capability
	Verdict    Verdict
	// Citation is the matrix source of the verdict: a probe id or a
	// vendor-primary URL, never a bare "unknown" (AC-2).
	Citation string
}

// Refusal is the AC6 typed refusal: the matrix cell verdict returned as an
// error, not a silent no-op.
type Refusal struct {
	Cell Cell
}

// Error implements error. The message names the host, the capability, the
// verdict, and the citation, so a caller sees exactly which matrix cell
// refused.
func (r Refusal) Error() string {
	return fmt.Sprintf("%s: %s × %s is %s per the capability matrix (%s)",
		ErrUnsupportedCapability, r.Cell.Host, r.Cell.Capability,
		r.Cell.Verdict, r.Cell.Citation)
}

// Unwrap names the refusal cause, so callers branch on
// ErrUnsupportedCapability with errors.Is.
func (r Refusal) Unwrap() error { return ErrUnsupportedCapability }

// matrix is the registry of per-host capability rows, sourced from
// docs/internal/control-plane/host-capability-matrix.md. Every row cites the
// probe or doc that owns its verdict; the file is the SoT and this table
// never outranks it.
var matrix = map[Host]map[Capability]Cell{
	HostClaudeCode: {
		CapHeadlessStream: {HostClaudeCode, CapHeadlessStream, VerdictSupported,
			"matrix (b), probe P-CC-B — claude -p --verbose --input-format stream-json --output-format stream-json (claude 2.1.325, probed 2026-11-15)"},
		CapResume: {HostClaudeCode, CapResume, VerdictSupported,
			"matrix AC-4 Claude Code — claude -p --resume <session-id>; session id from the stream-json system/init event (probes P-CC-A, P-CON-A)"},
		CapSteer: {HostClaudeCode, CapSteer, VerdictSupported,
			"matrix (c), probe P-CC-C — stream-json stdin injection absorbed mid-turn (absorbed_mid_turn), delivered at the next step boundary"},
	},
	HostGrok: {
		CapHeadlessStream: {HostGrok, CapHeadlessStream, VerdictSupported,
			"matrix (b) — grok agent stdio (ACP) streams session/update both ways (grok 1.0.77, probed 2026-11-15)"},
		CapResume: {HostGrok, CapResume, VerdictSupported,
			"matrix AC-4 Grok — --resume <SESSION_ID_OR_TITLE>, -c/--continue for the newest session in the cwd, --fork-session resumes into a new session id; session id from the headless --output-format json result sessionId (probe P-GK-CTR-2) or, over the ACP transport, the session/new response frame's result.sessionId (probe P-GK-ACP-1, grok 1.0.92, probed 2026-11-24)"},
		CapSteer: {HostGrok, CapSteer, VerdictSupported,
			"matrix (c), probes P-GK native + P-GK-CTR-3c — ACP session/prompt mid-turn merges into the running turn and is consumed at the next step boundary"},
	},
	HostOmp: {
		CapHeadlessStream: {HostOmp, CapHeadlessStream, VerdictSupported,
			"matrix (b) — omp -p --mode json streams text_delta; --mode rpc is bidirectional JSONL (omp, probed 2026-11-15)"},
		CapResume: {HostOmp, CapResume, VerdictSupported,
			"matrix AC-4 omp — -r, --resume=<value> (id prefix, session path, or picker) or -c, --continue; session id from the {\"type\":\"session\",\"id\":…} frame (probe P-OMP-C-A)"},
		CapSteer: {HostOmp, CapSteer, VerdictSupported,
			"matrix (c), probe P-OMP-C-C — the RPC {\"type\":\"steer\",\"message\":…} command enters the steering queue and is delivered at the step boundary"},
	},
	HostMiniSwe: {
		CapHeadlessStream: {HostMiniSwe, CapHeadlessStream, VerdictUnsupported,
			"matrix mini-swe (b) — documentation-only: an unattended run is documented, no streaming stdin/stdout protocol exists (https://mini-swe-agent.com/latest/usage/mini/, checked 2026-11-15)"},
		CapResume: {HostMiniSwe, CapResume, VerdictUnsupported,
			"matrix mini-swe (a) — documentation-only: the CLI carries no resume/continue flag and DefaultAgent.run() resets the message list (https://mini-swe-agent.com/latest/usage/mini/ + https://mini-swe-agent.com/latest/advanced/control_flow/, checked 2026-11-15); the AC-4 named path is the checkpoint fallback"},
		CapSteer: {HostMiniSwe, CapSteer, VerdictUnsupported,
			"matrix mini-swe (c) — documentation-only: no steer or mid-run injection path is documented (https://mini-swe-agent.com/latest/usage/mini/ + https://mini-swe-agent.com/latest/advanced/control_flow/, checked 2026-11-15)"},
	},
}

// cell returns the matrix cell for host × capability. An unknown host is a
// named error, never a lookup miss treated as a verdict.
func cell(h Host, c Capability) (Cell, error) {
	rows, ok := matrix[h]
	if !ok {
		return Cell{}, fmt.Errorf("%w: %q is not one of %s", ErrUnknownHost, h, hostList())
	}
	return rows[c], nil
}

// route checks the matrix cell of host × capability and refuses anything the
// matrix does not support (AC6). Supported cells pass; every other verdict —
// including the documentation-only mini-swe cells — returns the cell as a
// Refusal.
func route(h Host, c Capability) error {
	cell, err := cell(h, c)
	if err != nil {
		return err
	}
	if cell.Verdict != VerdictSupported {
		return Refusal{Cell: cell}
	}
	return nil
}

// hostList is the closed host set, for error text.
func hostList() string {
	parts := make([]string, 0, len(Hosts))
	for _, h := range Hosts {
		parts = append(parts, string(h))
	}
	return strings.Join(parts, ", ")
}
