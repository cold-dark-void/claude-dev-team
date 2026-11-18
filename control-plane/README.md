# control-plane

The Control plane service (control plane Option C+ (CDT-626)) lives here: the
container service that owns run state, the queue, and host sessions for one
project. Phase 1 of the Control plane arc builds it.

This directory is an isolated top-level service directory inside the
`dev-team` plugin repository. It is deliberately not plugin product:

- **One version per artifact.** The service version lives in `VERSION` and is
  bumped only by service-owning tickets. `.claude-plugin/plugin.json` stays
  the plugin's only version surface; service tags never use the plugin tag
  shape `vX.Y.Z`.
- **Boundary — single-homed.** The rule that the control plane talks to the
  plugin through files and CLI calls only is owned by
  [`docs/adr/0001-journal-engine.md`](../docs/adr/0001-journal-engine.md)
  (§ "The narrow-interface boundary"). This README cites it and never
  restates it: the service imports no plugin code, and the ADR alone defines
  what may cross.
- **Not a plugin Surface.** Nothing here ships in the installed plugin.
  `install.sh`, `install-test.sh`, and the plugin manifest exclude this
  directory; plugin packaging stays pure markdown/JSON.
- **Not plugin gate territory.** Release-gate, discovery and
  consistency tooling (`detect-surfaces.sh`, docs-drift, the smoke harness,
  the all-suites runner) carve this directory out — see the SPEC-030
  Discovery/R4 amendment and the SPEC-010 S7 service-path wording.

Build outputs (Go and container artifacts) are git-ignored at the repo root
`.gitignore`; this directory carries no checked-in binaries.

## Files

| File | Carries |
|------|---------|
| `VERSION` | Service semantic version (starts `0.1.0`) |
| `image-reference` | Placeholder container-image pin; the real G-02 request is CDT-628-C4's AC |
| `go.mod`, `go.sum` | The Go module: the service implementation (CDT-643). Build it in the container, not on the host |
| `journal/` | The append-only run journal: SQLite behind the narrow interface, `schema.sql`, replay, the lease table |
| `run/` | The run state machine: lease and fencing token, named halt states, retry budgets, stall limits, the watchdog |
| `reconcile/` | The on-start reconciler: the journal against worktrees, branches, and processes (AC5) |
| `lifecycle/` | The lifecycle-graph loader (CDT-642) |
| `spool/` | The phase-event spool (CDT-642) |
| `agent/` | The node agent (CDT-644): the four-verb contract — start, stop, status, steer — with two runners: the native runner (a process on the node's own OS, CDT-644) and the container runner (one container per run, CDT-647). The agent is the only holder of the Docker socket, and only through the container runner |
| `hostadapter/` | The host adapter (CDT-648): the per-host driver over the node agent's four verbs — start, resume, steer, observe — gated by the capability matrix |
| `queue/` | The run queue (CDT-649): the slot ledger — one slot is one runner, the node and per-model caps enforced independently, the accounting folded from the journal |
| `chief/` | The Chief (CDT-650): the single point of contact — routes work to the existing Surfaces and reports from journal and queue state. Its one interface is the HTTP API the web UI consumes |
| `cmd/node-agent/` | The node-agent binary, one per node |
| `cmd/journalctl/` | The journal CLI — the plugin↔service boundary: one append, one read, exit codes 0/1/64 |
| `cmd/chiefd/` | The Chief's host process: it serves `chief.Handler` — the API the web UI consumes — and runs the halt watch that pages the operator through the Intercom |
| `killtest/` | The AC7 kill-test lane: SIGKILL at every phase boundary, in the G-02 container; parameterised by runner type since CDT-644 |
| `build.sh` | The CDT-644 build entry: the three phase-0 targets in the G-02-approved Go image |
| `README.md` | This boundary and ownership statement |

## Selecting the container runner (a containers-only node)

A node whose owner keeps the containers-only rule runs every phase-1 session
in a container with no plugin-side change. The canonical operator recipe —
the one-time host-CLI login, the Docker CLI on the agent's PATH, and the
start command — lives in
[`docs/internal/control-plane/container-runner.md`](../docs/internal/control-plane/container-runner.md)
§ "Operator recipe — a containers-only node". The essential selection:

```json
{ "runner": "container", "command": "claude" }
```

in `$MROOT/.claude/dev-team/node.json`, or `$DEVTEAM_RUNNER=container` for
one invocation. Native stays the default: a node whose selection is `native`
(or absent) runs exactly the C4 native runner.
