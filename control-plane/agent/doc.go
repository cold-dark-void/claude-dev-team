// Package agent is the node agent of control plane Option C+ (CDT-626; CDT-628
// C4, CDT-644): one Go binary — control-plane/cmd/node-agent — with the
// four-verb contract start, stop, status, and steer. The control plane talks
// only to the node agent. The agent never talks to Docker, and no Docker
// dependency exists in this package, in the CLI, or in the build: the
// G-02-approved Go image builds the binary, it never runs it as a runner
// (docs/internal/control-plane/node-agent-build-probe.md § "Approved image").
//
// # The native runner
//
// The native runner is the first runner built and the default once selected:
// an agent session is a process on the node's own OS, using the installed host
// CLIs and their logins (docs/internal/control-plane/credentials.md — the
// per-host AC-9 grid; the CLI's own credential paths, never an injected
// secret). The agent spawns one host-CLI process per run slot, tracks its PID,
// steers it (a control message delivered at the next step boundary), and stops
// it (SIGTERM, then SIGKILL after a grace). Runner selection is a per-node
// setting — the runner key of $MROOT/.claude/dev-team/node.json, overridden by
// $DEVTEAM_RUNNER (record-ownership row 14), the
// skills/backlog/linear-gate.sh C7 pattern: first hit wins, one reader, and
// every unrecognised value resolves to no selection. A node with no selection
// starts no run (fail-closed).
//
// # Journal-first verbs
//
// Every state-changing verb writes its intent row before it acts and its
// outcome row after (the SPEC-040 AC11 intent-then-outcome pattern, through
// run.Machine.Intent and run.Machine.Outcome). start journals the spawn before
// it spawns the host CLI, stop journals the stop before it signals the
// process, steer journals the message before it is delivered. status reads;
// on a running run it journals its reading as an intent-then-outcome pair —
// the only state where a side_effect row is replayable — and on any other
// state it degrades to a pure read and says so in its output.
//
// # Supervision
//
// The agent reuses control-plane/run, never forks it: one lease per run with a
// monotonic fencing token (run.Machine.Claim), heartbeats inside the journaled
// stall limit (run.Machine.Heartbeat), and the run state as the replay of the
// journal (journal.Replay). The agent supervises the runner process it
// spawned: a clean exit completes the run, a failing exit fails it with a
// named reason, and the operator's stop lands the run in halted:operator_halt.
//
// Adoption policy (the CDT-626 reboot contract — every in-flight run
// continues without a human): a run's live runner process is recorded in
// $MROOT/.claude/runs/agent/<run-id>.pid together with the PID of the agent
// that supervises it. When an agent starts a run whose lease has expired, the
// recorded supervisor is by definition a dead or zombie owner: the agent
// kills the recorded runner orphan, records the takeover the machine journals
// anyway, and re-spawns the runner as the next attempt — the run continues,
// and its trail stays in the journal. A live lease refuses a second owner
// (journal.ErrLeaseHeld), so a healthy run is never double-spawned.
//
// Trust rule (AGENTS.md § Code Conventions): every value arrives as argv, an
// environment entry, a JSON config field, or a Go value. The steer message is
// untrusted text — it is marshalled as data into the control file and written
// to the runner process's stdin, never assembled into a command or a shell
// string. SQL belongs to the journal package, which binds every value through
// ?.
package agent
