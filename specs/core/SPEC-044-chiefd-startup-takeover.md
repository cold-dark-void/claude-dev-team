# SPEC-044: Chief Startup Takeover — chiefd Re-Supervises In-Flight Runs After a Restart

**Status**: ACTIVE
**Category**: core
**Created**: 2026-11-20

**Covers**: `control-plane/cmd/chiefd/main.go`, `control-plane/chief/chief.go`, `control-plane/chief/halts.go`, `control-plane/chief/takeover.go` (new), `control-plane/chief/takeover_test.go` (new), `control-plane/agent/agent.go`, `control-plane/agent/agent_test.go`, `control-plane/cmd/node-agent/main.go`, `control-plane/agent/doc.go`, `docs/internal/control-plane/native-runner.md`, `specs/core/SPEC-043-control-plane-setup.md`, `control-plane/VERSION`, `.github/workflows/smoke.yml` (comment-only, if at all)

---

## Overview

The CDT-626 reboot contract says: after a chiefd crash or restart, every
in-flight run continues without a human. Today chiefd does not honor it.
Four premises describe the gap:

- **P1**: after a chiefd crash the run sits in `running` with a stale lease.
  No halt row exists and no page goes out — `chief.ScanHalts` reports
  existing halt rows only, and the watchdog runs inside the dead
  supervisor's beat loop.
- **P2**: chiefd restarts in ~2 s (systemd `RestartSec=2`), but lease expiry
  takes at least one stall limit (108 s sonnet, 270 s opus; heartbeat
  cadence `clamp(limit/2, 250ms, 30s)`). A one-shot startup scan adopts
  nothing: it runs before any lease has expired. The scan must repeat.
- **P3**: a graceful SIGTERM restart lands every run in
  `halted:operator_halt`. `agent.Supervise` registers its own
  `signal.NotifyContext` and its `ctx.Done` branch calls `operatorHalt`,
  and `Supervise` refuses every halt except `halted:stalled`. One systemd
  stop permanently parks every in-flight run.
- **P4**: `queue.Queue.Grant` has no production caller. There is no slot
  accounting to "respect"; slot caps are out of scope.

This spec lands the chiefd half of the reboot contract. On startup and for
its whole service lifetime, chiefd runs a **takeover scan** — repeating on
the halt-watch cadence — that finds each run whose replayed state is
`running` or `claimed` with an expired lease, or `halted:stalled`, and
re-supervises it through the one spawn path that already exists: the host
adapter's `Start` verb, which rides the node agent's `Supervise` — the
pidfile check, the orphan kill, the fencing-token takeover
(`lease_acquired`, token+1), the `halted:stalled` resume, and the re-spawn
as attempt N+1. No takeover logic is forked. No event kind is added. No
lifecycle-graph vertex changes.

**Naming rule.** The domain glossary's `adopt` is the closed repair verb of
`control-plane/reconcile/doc.go`: it means *journal discovered reality*. The
takeover is not that verb, and no code identifier, journal row, or event may
be named `adopt`/`re-adopt` for it. The feature's nouns are **takeover**
(the scan and the lease acquisition) and **adoption** (prose only, as in the
ticket and ACs). Code identifiers use `takeover`.

## Boundaries

- **ADR 0001 (journal engine)** owns the closed event set and the
  intent-then-outcome rule. The takeover journals only existing kinds:
  `lease_acquired` (reason `takeover`), `side_effect` (`agent.kill`,
  `agent.start`), `stint_started`. This spec adds no kind and no payload.
- **control-plane/run** owns the lease and the state machine
  (`run.Lease.Expired`, `run.Machine.Claim` takeover at token+1,
  `run.Machine.Resume`, `run.RetryBudgets`, `run.ResolveStallLimit`). The
  chief calls them; it never re-implements one.
- **control-plane/agent** owns supervision (`Supervise`: pidfile check →
  orphan kill → claim → resume → spawn). The takeover reaches the runner
  only through it. The agent's trust rule holds: the takeover introduces no
  new untrusted-text carrier.
- **control-plane/queue** owns the slot ledger. The takeover does not grant,
  wait for, or count slots (P4): adoption is serial, one run at a time, and
  no slot cap gates it.
- **control-plane/reconcile** owns the on-start reality repair. The takeover
  scan is a different contract over the same journal: it re-supervises work,
  it does not journal discovered reality, and it never writes
  `run_halted`/`repair` rows. The two passes do not write each other's rows.
- **CDT-610** owns any change to the stall-limit and heartbeat numbers. This
  spec tunes none of them; the takeover bound is computed from the
  journaled stall limit and the existing watch interval.
- **CDT-661** (follow-up) owns journaling the host session id so a takeover
  can resume a session instead of re-spawning. Phase 1 re-spawns fresh
  (attempt N+1) and relies on workflow idempotency; `Adapter.Resume` stays
  unusable at boot and is not called by the scan.
- **CDT-631** (phase 4) owns multi-node and the node-agent daemon verb. The
  daemon verb is not needed for the single-node reboot contract: chiefd
  supervises in-process, and the unit + linger + the shutdown contract of
  M8 + this scan suffice.
- **SPEC-043** owns the install surface (unit, linger, verify table). This
  spec changes none of it; it only updates the M5 daemon-verb follow-up line
  and the docs that record the reboot contract.
- **SPEC-033 (arc)** owns the plugin version pair. The plugin pair
  (`.claude-plugin/plugin.json` + `CHANGELOG.md`) is untouched: the control
  plane has its own version (`control-plane/VERSION`), which moves
  0.1.0 → 0.2.0.

## MUST

- **M1 — The selection set is closed.** The takeover scan selects a run
  only when the replayed state is one of:
  - `running` with an expired lease (`run.Lease.Expired(now)` — the stale
    lease of P1, no halt row);
  - `claimed` (spawn-pending: a claim row, no `run_started`) with an
    expired lease;
  - `halted:stalled`.
  It never selects `halted:operator_halt`, `halted:lease_lost`,
  `halted:reconcile_failed`, `halted:budget_exhausted`, `completed`,
  `failed`, `new`, or the `reconcile.JournalRun` pseudo-Run (`run_id`
  "reconcile"). The selection reads the journal replay only — no queue read,
  no slot read.
- **M2 — The scan repeats on the halt-watch cadence.** The scan runs inside
  the existing `chief.Watch` loop, every `chief.DefaultWatchInterval` (5 s),
  for the service lifetime — never once at startup. Order inside one tick:
  the takeover pass first, then the halt page pass. Every run in the M1 set
  is taken over within **stall limit + one scan interval** of chiefd being
  up (P2: the takeover of a live-but-unexpired lease is impossible, so the
  bound is the journaled stall limit, not a new knob). CDT-610 stays
  blocked; no new duration flag or env var exists.
- **M3 — One takeover path.** The scan takes a run over by calling the
  existing `hostadapter.Adapter.Start` with the journaled ticket
  (`run_claimed` payload), workflow (`run_claimed` payload), model
  (`run_claimed`/`run_started` payload), and the host derived from the
  run's newest recorded `agent.start` intent via `hostByCommand`
  (`takeoverStartCommand` reads the newest intent; the steer/correct path's
  `chief.hostFromJournal` reads the oldest). No
  second spawn path, no takeover method on the adapter, no new event kind,
  no lifecycle-graph change. The supervision rides the chief's base context
  on its own goroutine — the same shape `chief.startRun` uses, including the
  `runRecord` bookkeeping (`Host`, `Capture`) so the board, steer, and
  checks readings work on adopted runs without special cases.
- **M4 — No double spawn.** A run whose lease is live and unexpired is not
  selected, and a takeover race is refused by the lease itself:
  `journal.ErrLeaseHeld` from `run.Machine.Claim` ends that run's takeover,
  touches nothing else. N chiefd restarts with no supervisor death produce
  exactly one live Runner per run: the pidfile check (`agent.ErrRunning`)
  and the fencing token (takeover writes land at token+1; a zombie owner's
  writes are refused with `journal.ErrStaleToken`) are the mechanisms.
- **M5 — No host, no spawn.** A selected run whose journal carries no
  `agent.start` intent (a run that died between `run_claimed` and the spawn
  intent) has no host to derive and is skipped — never spawned, never
  failed. The skip is named in a report line on `GET /v1/checks` and on
  chiefd's stdout (journald captures it). The scan continues.
- **M6 — Per-run refusals are isolated.** A matrix refusal
  (`hostadapter.Refusal`), `agent.ErrNoRunnerSelected`, an unknown host
  command in the start argv, `journal.ErrTerminalState`, or
  `journal.ErrLeaseHeld` during one run's takeover stops that run only:
  the scan continues with the next selected run, and chiefd keeps serving.
  A refusal is reported (stdout line plus the run's state), never swallowed.
- **M7 — The takeover never blocks serving and never lies.** chiefd binds
  and answers `GET /v1/runs` before the first takeover pass finishes. Every
  report (`/v1/runs`, the board, `/v1/checks`) shows the replayed journal
  truth; no projection of "will be adopted" state exists anywhere.
- **M8 — The shutdown contract (DRI OQ1(a)).** A chiefd shutdown — SIGTERM
  or SIGINT from systemd — journals **no** run event: no
  `halted:operator_halt`, no halt row of any reason. `operator_halt` is
  journaled only from an explicit operator stop (the UI stop → the adapter's
  `Stop` → the agent's journal-first stop verb; the standalone
  `node-agent start` CLI's own signal path). Concretely:
  - `agent.Supervise` stops deriving the operator halt from its own
    `signal.NotifyContext`: a cancelled supervision context is a **quiet
    shutdown** — stop the runner child quietly (SIGTERM, then SIGKILL after
    a bounded grace no longer than `agent.DefaultGrace`), keep the pidfile
    and the lease row, write no halt row, and return. The registering of
    process signals moves to the caller that owns it
    (`cmd/node-agent start`, whose signal stop keeps the operator-halt
    semantics by driving the journal-first stop verb).
  - chiefd passes its own signal context as the chief's base context
    (`chief.WithBaseContext`), so a shutdown cancels every supervised run's
    context and the quiet path applies.
  - On shutdown, chiefd releases the lease **only** through an existing
    state-machine path: `run.Machine.ReleaseStaleLease` when the lease has
    already expired. The closed event set has no live-lease release verb and
    this spec adds none (ADR 0001 boundary; AC3 forbids a new kind), so a
    live lease at shutdown is left to expire and M2's bound covers the
    restart. The fencing token guards every window: a zombie of the dead
    chiefd writes nothing (`journal.ErrStaleToken`).
  - chiefd MUST NOT remove the pidfile on shutdown: the recorded runner pid
    is what the next supervisor's orphan probe reads.
- **M9 — The takeover pages nothing (DRI OQ2).** The takeover path calls no
  `Phone`. The operator is paged only when adoption fails for a selected
  run (M5/M6 refusals that leave the run un-supervised) or when a
  `halted:stalled` run's retry budget is spent (M10). A crashed run's stale
  lease (P1) produces no page on its own — the page discipline of the halt
  watch is unchanged for halts the scan does not handle, and a
  `halted:stalled` run inside the M1 set whose budget has remaining retries
  is **not** paged: the takeover is the response. The page suppression must
  not silence a halt the scan refuses.
- **M10 — Budget-bound; no respawn loop (DRI OQ2).** A `halted:stalled`
  takeover resumes through `run.Machine.Resume` and spends the stalled retry
  budget (`run.RetryBudgets["stalled"]` = 2). When the budget is spent, the
  takeover of that run stops: the run stays halted, the operator is paged
  once, and chiefd never re-spawns it again — the budget check is the
  machine's own (`journal.ErrBudgetExhausted`), not a chief-side counter.
- **M11 — The takeover is board-visible.** After a successful takeover the
  web UI run board's state cell reads `running` and the halt cell is clear,
  with no operator action. The journal trail is the proof: for a killed
  runner, `lease_acquired` (reason `takeover`, token+1) → `agent.kill`
  intent/outcome → `agent.start` (new pid) → `stint_started`
  (attempt N+1) → … → `run_completed`.
- **M12 — Node-local boundary.** The scan adopts only runs whose Runner
  lives on chiefd's own Node (CONTEXT.md § Node): chiefd never spawns,
  probes, or signals a process on another machine, and no remote node agent
  is called. Phase 1 has one node, so the boundary is structural — the
  takeover re-spawn is always executed by chiefd's own in-process agent on
  the local node. A run whose records name a runner on another node (a
  phase-4 shape) is refused, and the refusal text names the node-local
  boundary explicitly.
- **M13 — The takeover re-spawn is fresh (DRI OQ6).** Phase 1 re-spawns the
  host session as attempt N+1 through the host's normal launch route. The
  host session id of the dead stint is not journaled today and
  `Adapter.Resume` needs one, so no resume is attempted; CDT-661 journals
  the session id for a true resume later. The docs record that the fresh
  re-spawn relies on workflow idempotency.
- **M14 — The kill test stays a plain `go test` under `control-plane/`.**
  The restart kill test is part of the suite the control-plane CI job
  (`.github/workflows/smoke.yml` § control-plane: `go build && go vet &&
  go test ./...`, digest-pinned G-02 image, `timeout-minutes: 10`) already
  runs. The test kills a real process with SIGKILL (the `killtest` re-exec
  pattern — the test does not run `go build`), skips nothing (`t.Skip` is a
  failure), writes only under `$TMPDIR`/`t.TempDir()`, locates the journal
  at `$DEVTEAM_RUN_DB`, and finishes inside the job's timeout.
- **M15 — Version.** `control-plane/VERSION` moves `0.1.0` → `0.2.0` in the
  same change. The plugin version pair
  (`.claude-plugin/plugin.json`, `CHANGELOG.md`) is untouched, and no
  plugin release runs for this change.

## SHOULD

- **S1 — One report line per skip and per refusal.** chiefd's stdout (and
  therefore journald) carries one line per M5 skip and per M6 refusal, each
  naming the run id, the state it was found in, and the refusal reason. The
  lines are the operator's first reading after a reboot; they are never the
  only record (the journal is).
- **S2 — The scan's work is bounded per tick.** The takeover pass processes
  the M1 set serially, one run at a time (DRI OQ4); a tick that finds more
  selected runs than it finishes leaves the rest to the next tick. No
  concurrency knob exists.

## MUST NOT

- **MUST NOT journal a new event kind or payload.** ADR 0001's closed set is
  fixed; the takeover reuses `lease_acquired`/`side_effect`/`stint_started`
  only (AC3).
- **MUST NOT fork a second spawn path.** Every takeover goes through
  `hostadapter.Adapter.Start` → the node agent's `Supervise` (AC3). A
  `chief`-owned spawn loop is a violation even if it calls the same verbs.
- **MUST NOT re-spawn a run the selection set excludes** — in particular
  `halted:operator_halt` (the operator stopped it; `agent.ErrHaltState` is
  the refusing mechanism), `halted:lease_lost`, `halted:reconcile_failed`,
  `halted:budget_exhausted`, and the terminal states (AC1, AC8).
- **MUST NOT page the operator on a successful takeover** (AC9).
- **MUST NOT re-spawn past the spent stalled retry budget** (AC10): a
  `journal.ErrBudgetExhausted` refusal ends the takeover of that run; no
  chief-side counter retries it.
- **MUST NOT introduce slot caps, queue grants, or queue waits in the
  takeover path** (P4 / DRI OQ4). `queue.Queue.Grant` gains no production
  caller from this spec.
- **MUST NOT tune the stall limit, heartbeat cadence, or lease expiry
  numbers** (CDT-610 stays blocked) and MUST NOT add a takeover-interval
  knob (DRI OQ3): the cadence is `chief.DefaultWatchInterval`.
- **MUST NOT name any code identifier, journal row, or event for this
  feature `adopt`/`re-adopt`.** The glossary `adopt` verb belongs to
  `control-plane/reconcile` alone (naming rule above).
- **MUST NOT touch the plugin version pair or cut a plugin release** for
  this change; the control plane's own `VERSION` carries the bump (M15).
- **MUST NOT call `hostadapter.Adapter.Resume` in the scan.** It needs a
  journaled session id the journal does not carry (CDT-661); the phase-1
  re-spawn is fresh (M13).
- **MUST NOT let the takeover path run untrusted text into a command
  line.** Host names, run ids, and models travel as argv/data through the
  existing seams; the agent's trust rule is unchanged.

## Test

- The takeover scan's selection set is a table test over journal fixtures:
  one fixture per state in the closed set (AC1's select list and refuse
  list), asserting select/refuse per row and that the `reconcile` pseudo-Run
  is never selected.
- The repetition test: with `DEVTEAM_STALL_LIMIT=2`, a run left in
  `running` with a stale lease by a killed chiefd is taken over within the
  M2 bound after a restart, with no human input.
- The no-double-spawn test: N restarts against a live lease produce exactly
  one live Runner and one `journal.ErrLeaseHeld` refusal per racing
  takeover.
- The shutdown-contract test: SIGTERM to chiefd lands no run event; an
  explicit stop still lands `halted:operator_halt`; a restarted chiefd
  adopts the quietly-shutdown run after expiry.
- The kill test (AC13): a real process killed with SIGKILL mid-run, chiefd
  restarted, the run taken over and completed exactly once — the trail of
  M11 asserted on the journal.
- The docs tests: whatever each touched doc's owner runs
  (`skills/docs-drift/test.sh` where the drift check applies).

## Open Questions

- **OQ1 (shutdown semantics)** — CLOSED (DRI 2026-11-20, ruling (a)):
  chiefd shutdown journals no `operator_halt`; a graceful shutdown releases
  the lease only when the closed event set already has a legal release path,
  otherwise the lease expires and the repeated scan takes over. Fencing
  token guards safety. Landed as M8.
- **OQ2 (crashed-run halts)** — CLOSED (DRI 2026-11-20): a `halted:stalled`
  run is adopted through `run.RecoveryPlan`'s machine path and resumed;
  the operator is paged only on adoption failure or a spent budget. Landed
  as M9/M10.
- **OQ3 (scan cadence)** — CLOSED (DRI 2026-11-20): the scan folds into the
  5 s Watch loop; the bound is stall limit + scan interval; no new knob.
  Landed as M2.
- **OQ4 (slot caps / parallelism)** — CLOSED (DRI 2026-11-20): slot caps
  out (P4); adoption is serial, one run at a time. Landed as M1/S2.
- **OQ5 (board attempt column)** — CLOSED (DRI 2026-11-20): deferred; the
  attempt count stays in the journal trail (`stint_started`), not on the
  board.
- **OQ6 (resume vs fresh spawn)** — CLOSED (DRI 2026-11-20): fresh
  re-spawn, attempt N+1, documented; CDT-661 journals the host session id
  for a true resume. Landed as M13.
- **OQ7 (node-agent daemon verb)** — CLOSED (DRI 2026-11-20): out of scope;
  the single-node reboot contract needs no daemon verb. Phase-4 concern
  (CDT-631). Recorded in Boundaries.
- **OQ8 (version bump)** — CLOSED (DRI 2026-11-20): `control-plane/VERSION`
  0.1.0 → 0.2.0 in the same change; the plugin pair untouched. Landed as
  M15.

## Acceptance criteria

### CDT-660

- **AC1.** Selection set (closed). The scan selects a Run only when
  replayed state is `running` or `claimed` (spawn-pending: claim row, no
  `run_started`) with an expired lease (`run.Lease.Expired(now)`), or
  `halted:stalled`. It never selects `halted:operator_halt`,
  `halted:lease_lost`, `halted:reconcile_failed`, `halted:budget_exhausted`,
  `completed`, `failed`, `new`, or the `reconcile.JournalRun` pseudo-Run.
- **AC2.** The scan repeats. The scan runs on the halt-watch cadence
  (`chief.DefaultWatchInterval`, 5 s) for the service lifetime; every AC1-set
  run is taken over within stall limit + scan interval of chiefd being up,
  with no human.
- **AC3.** One takeover path, no fork. The takeover calls the existing
  `hostadapter.Adapter.Start` with the journaled ticket, workflow, and
  model (from `run_claimed`/`run_started`) and the host derived from the
  run's newest recorded `agent.start` intent via `hostByCommand`
  (`takeoverStartCommand`). No new takeover logic, no second spawn path, no
  event kind, no lifecycle-graph change.
- **AC4.** No double spawn. A live lease is refused with
  `journal.ErrLeaseHeld`, untouched. N restarts with no supervisor death
  produce exactly one live Runner and no second `agent.start` outcome;
  `agent.ErrRunning` is honored.
- **AC5.** No host, no spawn. A selected run with no `agent.start` intent
  row is skipped, named in a report line (`GET /v1/checks` + chiefd
  stdout/journald); the scan continues.
- **AC6.** Per-run refusals are isolated. A matrix refusal,
  `agent.ErrNoRunnerSelected`, an unknown command, `journal.ErrTerminalState`,
  or `journal.ErrLeaseHeld` on one run stops that run only; the scan
  continues; chiefd still serves.
- **AC7.** Adoption never blocks serving. chiefd binds and answers
  `GET /v1/runs` before the scan finishes; reports carry replayed truth,
  never projected state.
- **AC8.** Operator halts stay halted. `halted:operator_halt` and other
  non-stalled halts are not re-spawned and keep paging through the halt
  watch (`agent.ErrHaltState` is the mechanism).
- **AC9.** Adoption pages nothing. The takeover path calls no `Phone`; the
  operator is paged only when adoption fails or the stalled retry budget is
  spent.
- **AC10.** Budget-bound; no respawn loop. A `halted:stalled` takeover
  resumes and spends the stalled retry budget (2, `run.RetryBudgets`); when
  spent, the run stays halted, pages once, and chiefd stops re-spawning it.
- **AC11.** Board-visible. After adoption the web UI run board's state
  cell reads `running` and the halt cell clears, with no operator action;
  the journal rows (`lease_acquired` reason `takeover` token+1 →
  `agent.kill` → `agent.start` new pid → `stint_started` attempt N+1 →
  `run_completed`) are the proof.
- **AC12.** Node scope. The scan adopts only runs whose Runner lives on
  chiefd's own Node; no remote spawn; the node-local boundary is named in
  the refusal text.
- **AC13.** [process] The kill test is a plain `go test` under
  `control-plane/`, run by the existing control-plane job (`go build && go
  vet && go test ./...` in the digest-pinned golang image,
  `timeout-minutes: 10`); it kills a real process with SIGKILL (the
  `killtest` re-exec pattern, no `go build` inside the test), skips nothing,
  writes only under `$TMPDIR`/`t.TempDir()`, locates the journal at
  `$DEVTEAM_RUN_DB`, and finishes inside the job timeout.
- **AC14.** Docs close the open contract in their owners.
  `control-plane/agent/doc.go` § Adoption policy names the takeover scan as
  its caller; `docs/internal/control-plane/native-runner.md` records the
  chiefd half of the reboot contract is landed; SPEC-043 M5's daemon-verb
  follow-up line cites the follow-up (the daemon verb itself stays a
  phase-4 concern, CDT-631); the linger step (SPEC-043 M10 / B8) stays an
  operator step.
- **AC15.** Shutdown contract (DRI OQ1(a)). A chiefd shutdown (SIGTERM
  from systemd) journals no `operator_halt` and no halt row of any reason;
  `operator_halt` comes only from an explicit stop (UI stop → the stop verb;
  the standalone `node-agent start` signal path). On graceful shutdown the
  lease is released only through an existing state-machine path
  (`run.Machine.ReleaseStaleLease` when already expired); otherwise the
  lease waits for expiry and the repeated scan takes over. The fencing token
  guards safety. The pidfile survives shutdown so the next supervisor's
  orphan probe reads it.
- **AC16.** Version (DRI OQ8). `control-plane/VERSION` reads `0.2.0` in
  the same change; `.claude-plugin/plugin.json` and `CHANGELOG.md` are
  untouched.

### CDT-656

- **A.** The steer-then-stop supervision test is clock-independent:
  `TestSuperviseSteerThenOperatorStop` pins a wide `DEVTEAM_STALL_LIMIT`
  (270) so the heartbeat — half the stall limit, `heartbeatFloor`-clamped —
  can never go stale between `waitRunner` and the `Steer` call, and a
  loaded CI runner can no longer race the 1 s default limit into
  `ErrSteerLost`. The C2 kill semantics of the test stay asserted: the
  steer is delivered at a step boundary, the stop SIGTERMs then SIGKILLs
  past the grace, and the run lands `halted:operator_halt` with the
  pidfile cleared and a second stop refused `ErrNotRunning`.
  Verify: bash control-plane/test.sh
- **B.** The seam tests are environment-independent: the chief model-map
  subtest ("the real script falls back to the tier default with no
  layers") execs the REAL `resolve-model.sh` against a layer-free fixture
  checkout of its own (git-inited, `skills/model-map/` copied in, `HOME`
  and the process cwd pinned to the fixture), so the script's MROOT rule
  — which follows `git rev-parse --git-common-dir` from the process cwd —
  reads the fixture, never the shared worktree store's local Model map
  layer. A DRI machine with `.claude/dev-team/models.local.json` now gets
  the same tier-default verdict CI gets.
  Verify: bash control-plane/test.sh
- **C.** `control-plane/test.sh` exists as the Go lane's suite script — the
  SPEC-044 Version History names it the follow-up that restores the
  ship-gate Verify binding after the per-file Verify lines were dropped —
  and it runs `go test ./... -count=1` green from the repo root.
  Verify: bash control-plane/test.sh

## Validation

- Spec reviewed and promoted to ACTIVE
- Selection set (AC1): the closed select/refuse table over journal fixtures
  and the selection predicate pass in `control-plane/chief/takeover_test.go`
  (`TestTakeoverSetSelection`, `TestTakeoverSetSelectionPredicate`)
- Scan executor (AC2–AC7, AC9–AC12): the same file proves the selected set is
  spawned through the one takeover path, a per-run refusal is isolated, a
  host-less run is skipped and reported, an unknown start command and a
  Runner on another node are refused, and a live lease is left alone
  (`TestTakeoverScan*`)
- Watch fold and page suppression (AC2/AC8/AC9/AC10):
  `control-plane/chief/halts_test.go` proves the takeover pass runs at
  startup and repeats on the watch cadence, an answered stall is not paged,
  a failed takeover pages the stalled halt, and an operator halt keeps
  paging after the pass
- Checks and board wiring (AC5/AC11): the takeover report reaches
  `GET /v1/checks` (`control-plane/chief/api_test.go`) and the board shows a
  taken-over run as `running` with a clear halt cell
  (`control-plane/chief/board_test.go`)
- Restart kill test (AC13): `control-plane/killtest/restart_test.go`
  SIGKILLs a real supervising process mid-run and asserts the M11 trail to
  `run_completed` — the run completes exactly once. It runs in the
  control-plane CI job (`timeout-minutes: 10`); the `killtest` package takes
  49 s of that budget
- Shutdown contract (AC15): the quiet-shutdown cases pass in
  `control-plane/agent/agent_test.go`, chiefd journals no run event on
  shutdown (`control-plane/cmd/chiefd/main_test.go`), and the standalone
  `node-agent start` signal path still lands `halted:operator_halt`
  (`control-plane/cmd/node-agent/main_test.go`)
- `go build ./... && go vet ./... && go test ./...` green in the
  digest-pinned G-02 image (`golang:1.27-bookworm@sha256:4fa7c968…`): all 13
  packages ok
- Spec-lint (SPEC-008) and docs-drift green on the landed diff

## Version History

| Date | Change |
|------|--------|
| 2026-11-21 | CDT-656: clock- and environment-independent control-plane tests — `TestSuperviseSteerThenOperatorStop` pins a wide `DEVTEAM_STALL_LIMIT` (270) so a loaded CI runner can no longer race the 1 s default limit into `ErrSteerLost` between `waitRunner` and the steer; the chief model-map seam subtest execs the real `resolve-model.sh` against a layer-free fixture checkout (its own git root + pinned `HOME`/cwd) instead of the live worktree, whose shared store may carry a DRI's local Model map layer; new `control-plane/test.sh` runs `go test ./... -count=1` and restores the ship-gate Verify binding the spec-lint pass dropped. `### CDT-656` ACs A–C. |
| 2026-11-20 | Spec-lint pass (CDT-660): added the `## Validation` record — the landed proofs per AC, incl. the AC13 restart kill test inside the control-plane CI job and the digest-pinned G-02 image run. Every AC bullet now carries the M14(g) bullet form `- **ACn.** …`; the 14 `Verify:` lines that named Go `_test.go` files are dropped, because M14(g) admits a suite script basename (`test.sh`, `test-*.sh`, `*-test.sh`) only and no suite script covers the Go lane — the proofs are named in `## Validation` instead (a `control-plane/test.sh` suite is the follow-up that restores the ship-gate Verify binding). AC13 is a `[process]` AC, so it holds no Verify line by rule. Registered in `specs/TDD.md`. No MUST, Test, or AC requirement text changed. |
| 2026-11-20 | SPEC-044 created (CDT-660): chiefd startup takeover of in-flight runs — the chiefd half of the CDT-626 reboot contract. Premises P1–P4 accepted per the DRI rulings of 2026-11-20; AC1–AC14 from the PM's revised scope review, plus AC15 (shutdown contract) and AC16 (version) from the rulings. |
