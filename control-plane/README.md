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
| `agent/` | The node agent (CDT-644): the four-verb contract — start, stop, status, steer — and the native runner, a process on the node's own OS. No Docker in the contract, the code, or the build |
| `cmd/node-agent/` | The node-agent binary, one per node |
| `cmd/journalctl/` | The journal CLI — the plugin↔service boundary: one append, one read, exit codes 0/1/64 |
| `killtest/` | The AC7 kill-test lane: SIGKILL at every phase boundary, in the G-02 container; parameterised by runner type since CDT-644 |
| `build.sh` | The CDT-644 build entry: the three phase-0 targets in the G-02-approved Go image |
| `README.md` | This boundary and ownership statement |
