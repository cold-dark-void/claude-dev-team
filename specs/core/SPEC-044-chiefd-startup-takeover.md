# SPEC-044: Chief Startup Takeover — chiefd Re-Supervises In-Flight Runs After a Restart

**Status**: ACTIVE
**Category**: core
**Created**: 2026-11-20

**Covers**: `control-plane/cmd/chiefd/main.go`, `control-plane/chief/chief.go`, `control-plane/chief/halts.go`, `control-plane/chief/takeover.go` (new), `control-plane/chief/takeover_test.go` (new), `control-plane/chief/e2e_test.go`, `control-plane/chief/steer_test.go`, `control-plane/agent/agent.go`, `control-plane/agent/agent_test.go`, `control-plane/hostadapter/adapter.go`, `control-plane/hostadapter/launch.go`, `control-plane/hostadapter/hostadapter_test.go`, `control-plane/cmd/node-agent/main.go`, `control-plane/agent/doc.go`, `docs/internal/control-plane/native-runner.md`, `specs/core/SPEC-043-control-plane-setup.md`, `control-plane/VERSION`, `.github/workflows/smoke.yml` (comment-only, if at all)

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
  cadence `clamp(limit/2, 250ms, 30s)`). A one-shot startup scan takes over
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
  `agent.start`, `agent.session`, `agent.premise`), `stint_started`. This
  spec adds no kind and no payload.
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
  no slot read. A `running`/`claimed` run that carries no lease row at all is
  selected: no owner can prove liveness, which is `run.Lease.Expired`'s own
  rule for a lease whose liveness it cannot read.
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
  `chief.hostFromJournal` reads the first matching intent — the correction
  needs any recorded host — and collapses a run with no start intent and a
  start intent naming an unknown host command into one `ErrNotSteerable`). No
  second spawn path, no takeover method on the adapter, no new event kind,
  no lifecycle-graph change. The supervision rides the chief's base context
  on its own goroutine — the same shape `chief.startRun` uses, including the
  `runRecord` bookkeeping (`Host`, `Cap`) so the board, steer, and
  checks readings work on taken-over runs without special cases.
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
  An unreadable lease row stops that run's takeover the same way and is the
  scan's one silent continue: a lease that cannot be read proves no expiry,
  so the run is left alone and the next tick reads it again.
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
  - On shutdown, chiefd never releases the lease. Releasing is the
    reconciler's path: `reconcile` journals a `Machine.Repair` row
    (`p.repair(..., ActionReleaseStaleLease, ...)`), and the closed event set
    carries no lease-release verb of its own (ADR 0001 boundary; AC3 forbids
    a new kind), so a release on shutdown is the run event this contract
    forbids. A live lease at shutdown is left to expire; an expired one is
    re-selected by the next scan, and M2's bound covers the restart. The
    fencing token guards every window: a zombie of the dead chiefd writes
    nothing (`journal.ErrStaleToken`).
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
- **M12 — Node-local boundary.** The scan takes over only runs whose Runner
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
- **M16 — The run's work premise reaches the session's first turn.** A
  start that carries a premise — the ticket record's text, the run's **work
  premise** (not this spec's numbered assumptions P1–P4) — delivers it as
  the session's first turn. The node agent journals the delivery as a
  `side_effect` of the effect name `agent.premise`, keyed
  `agent:premise:<run>#<attempt>`, under the live lease token: the intent
  row carries the premise text and the attempt, the outcome row carries
  `delivered`, the attempt, and the session the frame named. The agent
  renders nothing: the host adapter's per-host spec owns the first-turn
  frame shape, and the premise rides the spawn as data
  (`StartRequest.Premise`), exactly like the command and argv.
  The re-delivery rule is the takeover's, and it is the same
  intent-then-outcome rule `deliverSteers` applies to a correction: a
  premise pair that CLOSED for the run ends the effect for every attempt —
  the takeover re-adoption writes no frame to the child and journals no new
  row, so the session never gets a duplicate turn, and a pair the agent
  settled undelivered (M17) is never retried; a premise intent left PENDING
  is the crash between the row and the frame, and the re-adoption performs
  it exactly once, from the text that row carries — the re-spawn needs no
  ticket store. The host adapter attaches that renderer from the host's spec
  on every spawn of that host — the gate is the SPEC, never the request's
  premise text — so a re-adoption that carries no text of its own can still
  perform the row; a host whose spec names no first-turn frame attaches
  nothing and is never refused for it, so a premise-less mini-swe re-spawn
  behaves as it did before this clause. A start that carries no premise
  journals no premise row.
  The window this clause does not claim: the effect begins at its intent row.
  A run re-adopted between the spawn and the supervision loop's first poll
  tick carries no premise row and no premise text, so the re-adoption journals
  nothing and the session opens with no premise — no record of the miss
  exists, and M16 claims none. Closing it needs a premise that survives the
  spawn (a ticket-store read at the re-adoption, which the chief does not
  have: its `TicketStore` writes only), so it stays a named gap, not a
  guarantee.
- **M18 — An ACP session is opened by its client.** A host whose transport
  is client-driven names its handshake in the host's spec, and the handshake
  rides the spawn as data (`StartRequest.Handshake`), exactly like the
  command, argv, and the premise frame of M16: the agent writes frames and
  never assembles host wire frames itself. The node agent performs the
  handshake before its poll loop and journals it as a `side_effect` of the
  effect name `agent.handshake`, keyed `agent:handshake:<run>#<attempt>`,
  under the live lease token — the intent row carries the attempt and the cwd
  the child inherits, the outcome row carries `delivered`, the attempt, and
  the frame count. It rides every spawn of that host: the first attempt and a
  takeover re-spawn alike, because the re-spawn's child is a new agent on that
  transport. The capture stays the single CDT-661 path: the session id is
  captured from the response that names it and is journaled as the
  `agent.session` pair; the handshake adds no second capture and no second
  id. A handshake that cannot complete is a halt, not a ride: M17's ride-on
  rule covers the frame that names an id the run never got, and an
  unopened ACP session never gets one — the child idles forever, so the
  supervisor stops the child and lands the named halt
  (`handshake_failed`).
- **M17 — The premise is never a hang and never a halt.** A first-turn
  frame that names the session (the ACP transport, probe P-GK-ACP-1)
  renders on the poll tick that captures the id. The agent retries the
  render on each tick for a bounded wait
  (`agent.DefaultPremiseSessionWait`, overridable for a test); past the
  bound it closes the pair with `delivered: false` and the named cause, and
  the run rides on. An undeliverable premise is a journal record, never a
  pending intent the reconciler halts a run for, and never a stalled
  supervision loop.

## SHOULD

- **S1 — One report line per skip and per refusal.** chiefd's stdout (and
  therefore journald) carries one line per M5 skip and per M6 refusal, each
  naming the run id, the state it was found in, and the refusal reason. The
  lines are the operator's first reading after a reboot; they are never the
  only record (the journal is).
  A pass that ends before a start's journal proof lands reports that run in
  the unconfirmed bucket: the start rides the chief's base context and may
  still land, so the line names an unproven start, never a refusal.
  `chief.logTakeover` writes each line only the first time the process sees
  it; the report stays the journal's truth on every pass — the dedup covers
  the log line, never the reading.
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
  takes over the quietly-shutdown run after expiry.
- The kill test (AC13): a real process killed with SIGKILL mid-run, chiefd
  restarted, the run taken over and completed exactly once — the trail of
  M11 asserted on the journal.
- The docs tests: whatever each touched doc's owner runs
  (`skills/docs-drift/test.sh` where the drift check applies).

## Open Questions

- **OQ1 (shutdown semantics)** — CLOSED (DRI 2026-11-20, ruling (a)):
  chiefd shutdown journals no `operator_halt`; a graceful shutdown releases
  the lease only when the closed event set already has a legal release path
  — which it does not (M8): the release is the reconciler's journaled
  `Machine.Repair` path, forbidden on shutdown — so the lease expires and
  the repeated scan takes over. Fencing token guards safety. Landed as M8.
- **OQ2 (crashed-run halts)** — CLOSED (DRI 2026-11-20): a `halted:stalled`
  run is taken over through `run.RecoveryPlan`'s machine path and resumed;
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

Grok's ACP transport is client-driven: the client must send `initialize`,
then `notifications/initialized`, then `session/new` before the agent
answers anything (probe P-GK-ACP-1 ran the handshake by hand; the node
agent never did, so a Grok run spawned, waited for a session id that never
arrived, timed the premise out at the 30 s bound, and sat `running` — run
`test-sidecar-sh-fails-after-dst-transitions-local-`, 2026-11-27). These
ACs close the client half of the handshake. The handshake frames travel as
data on the host's spec, the way the premise renderer does (CDT-665 M16):
the agent writes frames, never builds them.

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
- **AC12.** Node scope. The scan takes over only runs whose Runner lives on
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
  the standalone `node-agent start` signal path). On shutdown chiefd never
  releases the lease: a live lease waits for expiry, an expired one is
  re-selected by the next scan, and releasing needs a journaled repair row,
  which the no-run-event rule forbids. The fencing token guards safety. The
  pidfile survives shutdown so the next supervisor's
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

### CDT-661

- **AC1.** The host session id is journaled at capture time: the node agent
  journals the id its runner's session capture holds as a `side_effect` of
  the effect name `agent.session` — an intent row and its outcome row, both
  carrying the captured id and the attempt number, written under the live
  lease token while the run runs. The event-kind set of
  `control-plane/journal/schema.sql` is unchanged,
  `journal_meta.schema_version` stays `1`, and no new record exists
  (ADR 0001 § "The narrow-interface boundary"): the field rides the row-12
  journal's existing payload shape. A crash between the two appends leaves
  one pending intent, which the reconciler adopts and closes from the row's
  own payload — never `halted:reconcile_failed`, a state the takeover
  refuses.
  Verify: bash control-plane/test.sh
- **AC2.** Every captured host names its id: the claude-code stream-json
  init line and the omp session frame capture as today, and the Grok ACP
  transport (`grok agent --always-approve stdio`) captures the session id
  the `session/new` response frame carries, so a live ACP session is
  journal-named at capture time. The initial prompt delivery over ACP stays
  CDT-665's.
  Verify: bash control-plane/test.sh
- **AC3.** Adoption resumes the host session: the takeover scan, for a
  selected run whose journal carries a captured session id (the newest
  `agent.session` row — a pending intent's payload carries the id too) and
  whose host names a supported resume cell, re-supervises the run through
  `hostadapter.Adapter.Resume` — the host's by-id resume invocation rides
  the one takeover path (`Adapter.Resume` → the node agent's `Supervise`),
  the spawn intent carries the resume argv and attempt N+1, and the trail
  is journaled intent-then-outcome exactly like a start. The resumed path
  records the run's capture so `Correct` keeps steering it.
  Verify: bash control-plane/test.sh
- **AC4.** The fallback is CDT-660's fresh re-spawn, unchanged: a selected
  run whose journal carries no captured session id (before-capture hosts
  and capture-less starts), or whose host names no supported resume cell
  (mini-swe, pre-checked through `hostadapter.ResumeRoute`), re-spawns
  fresh through `hostadapter.Adapter.Start` with byte-identical trail,
  report, and budget behaviour.
  Verify: bash control-plane/test.sh
- **AC5.** The kill test proves true resume: the restart kill test's host
  stand-in emits a captureable session id, the closed `agent.session` row
  lands before the SIGKILL, the takeover's re-spawn argv is the host's
  resume invocation naming that same session id — the same host session
  continues across the crash — and the run still completes exactly once.
  Verify: bash control-plane/test.sh
- **AC6.** Version: `control-plane/VERSION` reads `0.2.1` in the same
  change; `.claude-plugin/plugin.json` and `CHANGELOG.md` are untouched.
- **AC7.** [process] The Grok ACP session-id frame shape is verified against a
  live `grok agent --always-approve stdio` probe before the extractor's
  citation lands in the capability-matrix comment, and the extractor ships
  only against a recorded-transcript fixture that the suite reads: probe
  P-GK-ACP-1 (grok 1.0.92, 2026-11-24) named the id as `result.sessionId` on
  the `session/new` response, and probe P-GK-ACP-2 reproduced that shape the
  same day. A probe that cannot run on the lane is recorded as an open gap in
  this spec's Validation record.

### CDT-664

- **AC1.** The chief's run record survives a sibling start's refusal: a
  start that refuses (the claim fence, the live lease, the matrix) deletes
  the run's record only when no confirmed start owns it — the record a
  confirmed start populated (its capture) survives a sibling's refusal, and
  a refused-then-confirmed pair records the confirmed start's capture, so
  the board, steer, and checks readings survive the unconfirmed-then-
  re-selected window. No double spawn exists in any interleaving (M4's
  fence is untouched).
  Verify: bash control-plane/test.sh
- **AC2.** A `halted:stalled` halt the takeover answers during the page
  pass pages nothing: the page decision re-reads the answered state after
  the intent row and before the channel call, closes the intent row with an
  outcome row (`delivered: false`, error "suppressed: the takeover answered
  the halt"), and the next scan reports the halt without paging. The page
  record stays at-least-once: a start that lands after the re-check can
  still page once (the residual window is inherent — the start rides the
  base context), and no new wait or knob exists.
  Verify: bash control-plane/test.sh
- **AC3.** [process] SPEC-044 states the shutdown contract's actual
  mechanism: chiefd never calls `run.Machine.ReleaseStaleLease` on
  shutdown — the lease waits for expiry (M2's bound covers the restart),
  and releasing is the reconciler's path (`Machine.Repair`-journaled
  `ActionReleaseStaleLease`), which the no-run-event rule forbids on
  shutdown; M3 names the `runRecord` field `Cap`;
  `chief.hostFromJournal` returns the first matching `agent.start` intent
  and collapses no-intent and unknown-host into one `ErrNotSteerable`; the
  takeover prose says "takes over"; and M1, M6, and S1 name the
  no-lease-row selection, the unreadable-lease continue, the
  `TakeoverUnconfirmed` report bucket, and the per-process report-line
  dedup. The gate for this change is the Go suite plus `tools/spec-lint.sh`.
- **AC4.** Version: `control-plane/VERSION` reads `0.2.2` in the same
  change; `.claude-plugin/plugin.json` and `CHANGELOG.md` are untouched.

### CDT-669

- **AC1.** The CDT-661 resume proof no longer races the journal: the
  resume tests await the re-spawn's `agent.start` intent with a bounded
  poll (the `takeoverWatch` proof reads `lease_acquired`, which can land
  before the async append) — `TestTakeoverScanResumesTheJournaledSession`
  and `TestTakeoverScanSpawnsTheSelectedSet` read the journal only after
  the awaited row lands.
  Verify: bash control-plane/test.sh
- **AC2.** The live-lease proof's window is wider than any fixture gap:
  `TestTakeoverScanLeavesALiveLeaseAlone` seeds the lease with a 600 s
  stored stall limit, so package parallelism cannot age it past expiry
  between the seed and the scan.
  Verify: bash control-plane/test.sh
- **AC3.** The late-id proof outlives starvation: the
  `TestSuperviseSessionJournalRetriesUntilTheIDIsNamed` child runs 5 s
  under a 270 s stall limit (the file's CDT-656 precedent), so package
  parallelism cannot starve the journal ticks before the late id lands.
  Verify: bash control-plane/test.sh
- **AC4.** [process] No production file changes — the deflake is
  test-only (`*_test.go`), the Go suite stays green solo in the pinned
  G-02 image, and `-race` stays clean on chief and agent.
### CDT-665

- **AC1.** A routed run reaches work with no human turn: the chief carries
  the route's premise text onto the start (`hostadapter.StartRequest.Premise`
  → `agent.StartRequest.Premise`), the node agent delivers it to the spawned
  session, and the run reaches `completed` with no correction ever posted.
  The e2e seam proves it on a real child that reads its FIRST stdin frame
  and exits: the frame carries the route's text, and the steer output file
  the same child would write stays absent.
  Verify: bash control-plane/test.sh
- **AC2.** The delivery is intent-then-outcome: one closed `agent.premise`
  pair for the run, keyed `agent:premise:<run>#<attempt>` by the attempt that
  opened the session, and never duplicated by a later attempt (M16's rule is
  run-wide) — the intent row carries the premise text and the attempt, the
  outcome row carries `delivered: true`, the attempt, and the session the
  frame named, naming the same attempt as its intent — written under the live
  lease token. A start that carries no premise journals no premise row.
  Verify: bash control-plane/test.sh
- **AC3.** No duplicate turn: a takeover re-adoption of a run whose premise
  pair CLOSED writes no frame to the child's stdin and journals no new
  premise row — the child that sits reading stdin (the 0-CPU shape of the
  defect) receives nothing at all.
  Verify: bash control-plane/test.sh
- **AC4.** The crash window is performed: a premise intent left PENDING is
  delivered exactly once by the re-adoption, from the text the pending row
  carries (the re-spawn carries no premise of its own), the row closes with
  `delivered: true`, and no second intent lands under the key. The renderer is
  not a caller-supplied extra: `Adapter.Start` and `Adapter.Resume` attach the
  host's first-turn renderer whenever the host's spec names one, gated on the
  spec and not on the request's premise text, and the proof spawns with an
  empty premise. A premise-less spawn on a host whose spec names no
  first-turn frame attaches nothing and is not refused — mini-swe does not
  regress into a refusal.
  Verify: bash control-plane/test.sh
- **AC5.** Each steerable host renders the premise as its own first-turn
  frame, from the adapter's per-host spec: Claude Code the stream-json user
  message (P-CC-C shape), Grok the ACP `session/prompt` frame naming the
  captured session (P-GK-CTR-3c shape, id per probe P-GK-ACP-1), omp the RPC
  `{"type":"steer","message":…}` command (P-OMP-C-C). A frame that names the
  session renders no bytes before the capture names the id.
  Verify: bash control-plane/test.sh
- **AC6.** The refusal and the bound are both records, never a hang: a host
  with no steerable route (mini-swe, matrix cell (c)) refuses a start that
  carries a premise with its matrix cell verdict before the agent is called,
  so no journal row lands; and a runner that never names a session closes
  the pair with `delivered: false` and the named cause once the bounded
  session-id wait expires, with the run riding on to its own terminal state.
  Verify: bash control-plane/test.sh
- **AC7.** Version: `control-plane/VERSION` reads `0.3.0` in the same
  change (a new capability that completes the CDT-626 route contract);
  `.claude-plugin/plugin.json` and `CHANGELOG.md` are untouched.

### CDT-679

- **AC1.** Every Grok ACP start performs the client handshake: the node
  agent writes, on the child's stdin and in order, `initialize` (client
  capabilities `terminal: false`, the P-GK-CTR-3c adapter constraint),
  `notifications/initialized`, and `session/new` naming the run's cwd — the
  working directory the child actually inherits. The handshake rides every
  ACP spawn: the first attempt and a takeover re-spawn alike (the re-spawn
  is a fresh `Adapter.Start` whose child is a new ACP agent). The delivery
  is journaled intent-then-outcome under the live lease token, the
  CDT-661/665 side-effect pattern. The frames are data the host's spec
  carries — the adapter's spec owns the encoding; the agent never assembles
  host wire frames itself. Claude Code and omp name no handshake: their
  hosts open sessions on their own transports, and their starts are
  unchanged.
  Verify: bash control-plane/test.sh
- **AC2.** The captured session id stays the CDT-661 path, unchanged: the
  handshake adds no second capture. The node agent's capture reads
  `result.sessionId` off the `session/new` response, journals it as the
  `agent.session` pair exactly as before, and the premise then renders as
  the first `session/prompt` naming that id — the `agent.premise` outcome
  closes `delivered: true` with the session id in it, on the first poll
  tick after the capture, not after the 30 s bound.
  Verify: bash control-plane/test.sh
- **AC3.** A handshake that cannot complete halts the run: a `session/new`
  response that carries a JSON-RPC error, a child that dies before the
  session id lands, or a capture still empty at the bounded wait — the
  supervisor stops the child and the run lands in a named halt whose
  reason says the handshake failed. It never stays `running` with an idle
  host that is waiting for its client. This narrows CDT-665 AC6's ride-on
  rule for the handshake transport: an undelivered premise there was a
  record because the child might exit on its own; an ACP child does not —
  it idles forever, so the named halt is the ride.
  Verify: bash control-plane/test.sh
- **AC4.** A test drives the full handshake against the recorded probe
  transcript `control-plane/hostadapter/testdata/grok-acp-session-frames.jsonl`:
  the client frames the suite feeds a fake child are the P-GK-ACP-1 shapes,
  the fake child answers from the transcript, and the captured session id
  renders the premise `session/prompt` frame against the fixture — the
  premise the probe's session would have received.
  Verify: bash control-plane/test.sh
- **AC5.** [process] A live Chief run on Grok delivers its premise: the
  run's journal carries `agent.premise` outcome `delivered: true` and the
  run reaches work — the AC4 suite proves the mechanics, this one proves
  the host answered live. Evidence lands in this spec's Validation record,
  not in the suite.
- **AC6.** Version: `control-plane/VERSION` reads `0.5.1` in the same
  change (a defect fix in the CDT-626 route contract — no new capability);
  `.claude-plugin/plugin.json` and `CHANGELOG.md` are untouched.

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
- Session-id journaling and adoption resume (CDT-661 AC1–AC6): the capture-time
  `agent.session` intent/outcome pair lands once per attempt under the live
  lease token, retries a failed write, and is absent for a capture-less runner
  (`control-plane/agent/agent_test.go`); a pending `agent.session` intent is
  adopted from its own payload and never lands `halted:reconcile_failed`
  (`control-plane/reconcile/reconcile_test.go`); the Grok ACP capture reads the
  session id off the recorded probe transcript and `ResumeRoute` splits the
  three real hosts from mini-swe (`control-plane/hostadapter/hostadapter_test.go`,
  `TestGrokACPCaptureReadsTheProbeTranscript`, `TestResumeRoutePredicate`); the
  takeover resumes a journaled id through `Adapter.Resume`, re-spawns fresh
  without one, and falls back on mini-swe
  (`control-plane/chief/takeover_test.go`); the restart kill test asserts the
  closed row lands before the SIGKILL and the re-spawn argv is
  `-p --resume killtest-session-1` — the same host session, completed exactly
  once (`control-plane/killtest/restart_test.go`). `control-plane/VERSION`
  reads `0.2.1` (AC6).
- Grok ACP probe (AC7): probes P-GK-ACP-1 and P-GK-ACP-2 ran live on
  2026-11-24 against grok 1.0.92 from scratch dirs under `/tmp`, sending
  `initialize`, `notifications/initialized`, and `session/new` on the stdio
  transport. The `session/new` response (`id: 1`) is the frame that names the
  id, as `result.sessionId`; the `initialize` response names none, and the
  notification frames carry it as `params.sessionId` from frame 7 of 29 —
  frames the capture deliberately does not read. The probe's exchange is pinned
  as
  `control-plane/hostadapter/testdata/grok-acp-session-frames.jsonl`: the four
  recorded response frames, then the three client frames the probe sent, with
  `__CWD__` where it named its scratch directory. Both suites read the file, so
  no lane carries a mirror of the wire bytes. No open gap.
- `go build ./... && go vet ./... && go test ./...` green in the
  digest-pinned G-02 image (`golang:1.27-bookworm@sha256:4fa7c968…`): all 13
  packages ok
- Premise delivery to the session's first turn (CDT-665 AC1–AC6): the
  per-host first-turn frames and the mini-swe refusal pass in
  `control-plane/hostadapter/hostadapter_test.go` (`TestPremiseFramePerHost`,
  `TestPremiseRouteRefusesAHostWithNoSteerableRoute`); the closed pair, the
  captured-session-id dependency, the bounded wait, the closed-row skip, the
  pending-row re-delivery, and the no-premise start pass in
  `control-plane/agent/agent_test.go` (`TestSuperviseDeliversThePremiseAsTheFirstTurn`,
  `TestSupervisePremiseWaitsForTheCapturedSessionID`,
  `TestSupervisePremiseClosesUndeliveredPastTheSessionWait`,
  `TestSuperviseTakeoverSkipsAClosedPremiseRow`,
  `TestSuperviseTakeoverRedeliversThePendingPremiseRow`,
  `TestSuperviseWithNoPremiseJournalsNoPremiseRow`); the routed run that
  reaches `completed` with no correction ever posted passes in
  `control-plane/chief/e2e_test.go`
  (`TestAPremiseTurnCompletesARoutedRunWithNoSteer`); and the two-frame order
  — the premise first, the correction second — is asserted on the same seam
  in `control-plane/chief/steer_test.go`, `control-plane/chief/e2e_test.go`,
  and `control-plane/hostadapter/hostadapter_test.go`.
- The AC4 renderer is proved unmasked: `control-plane/chief/steer_test.go`
  (`TestTakeoverRedeliversThePendingPremiseRowFromTheJournal`) takes a run
  over with an empty premise and a seeded PENDING premise row, asserts the
  spawn carries no caller-supplied frame, and reaches `completed` on the row's
  own text with `delivered: true` and one attempt named in both rows;
  `control-plane/hostadapter/hostadapter_test.go`
  (`TestStartAndResumeCarryTheRendererWithNoPremise`) pins that `Start` and
  `Resume` carry the renderer for every steerable host, and that a host whose
  spec names no first-turn frame answers nil with no refusal.
- The Grok ACP client handshake (CDT-679 AC1–AC4): the Grok host spec carries
  the three client frames as data — `initialize` with client capabilities
  `terminal: false` (P-GK-CTR-3c), `notifications/initialized`, and
  `session/new` naming the directory the child inherits at spawn
  (`control-plane/hostadapter/hostadapter_test.go`,
  `TestGrokHandshakeFramesAreTheProbeShapes`); the frames ride every Grok start,
  the takeover re-spawn included, and a host that names none carries nil
  (`TestHandshakeFramesRideEveryGrokSpawn`). The node agent writes them
  journal-first as an `agent.handshake` intent/outcome pair keyed
  `agent:handshake:<run>#<attempt>` under the live lease token, records the
  inherited cwd on the intent and the frame count on the outcome, and builds no
  frame
  (`control-plane/agent/agent_test.go`,
  `TestSuperviseWritesTheHandshakeThenDeliversThePremise`,
  `TestSuperviseWithNoHandshakeJournalsNoHandshakeRow`); the capture reports the
  `session/new` refusal beside the id (`TestCaptureReportsTheSessionNewRefusal`);
  and the three failures land the named halt `halted:handshake_failed` with the
  child stopped — the JSON-RPC error, the child that dies before capture, and
  the bounded wait that expires with no session id
  (`TestSuperviseHandshakeHaltsOnTheSessionNewError`,
  `TestSuperviseHandshakeHaltsWhenTheChildDiesBeforeTheSessionID`,
  `TestSuperviseHandshakeHaltsPastTheBoundedWait`). Each of those judgements
  reads the capture, never the loop's tick snapshot, so an exit that races the
  tick with an id already captured completes the run instead of taking the halt
  (`TestSuperviseHandshakeExitWithACapturedIDCompletesTheRun`). The end-to-end
  proof feeds a
  fake child the P-GK-ACP-1 frame shapes, answers it from
  `control-plane/hostadapter/testdata/grok-acp-session-frames.jsonl`, and asserts
  the captured `result.sessionId`, the closed handshake row, the rendered premise
  `session/prompt` frame, `delivered: true`, and `completed`
  (`TestGrokACPSessionOpensThroughTheAgent`). `handshake_failed` joins the closed
  halt set — journal `HaltReasons`, `run.RetryBudgets` (1), the lifecycle graph
  vertex and its `running → halted` edge — and sits on the takeover refuse list,
  so a handshake that never opened cannot idle as `running` (AC3 narrows CDT-665
  AC6's ride-on rule). The pair's crash window is closed the CDT-661 way: an
  `agent.handshake` intent with no outcome is self-evidencing — the row names
  the attempt it opened and the cwd its frames carried, the frames went to a
  child's stdin no reality re-probes, and the takeover re-spawn performs no
  replay — so the pass adopts it and the run never lands
  `halted:reconcile_failed` (`control-plane/reconcile/reconcile_test.go`,
  `TestPendingHandshakeIntentIsSelfEvidencing`,
  `TestPendingHandshakeIntentClosesWithNoReality`); a row that names no attempt
  has no evidence and keeps the halt
  (`TestHandshakeIntentWithNoAttemptIsNotSelfEvidencing`).
  The client frames have one home: both suites read them from
  `control-plane/hostadapter/testdata/grok-acp-session-frames.jsonl`, where the
  probe's recorded responses are followed by the probe's three requests
  (`__CWD__` names each lane's directory), and the capture proves it reads no id
  and no refusal off its own client frames
  (`TestGrokACPCaptureReadsTheProbeTranscript`). `control-plane/VERSION` reads
  `0.3.1` (AC6).
- CDT-679 gate run (2026-11-27, digest-pinned G-02 image, go1.27.4):
  `go build ./... && go vet ./...` clean, `gofmt -l agent chief hostadapter
  journal run lifecycle reconcile cmd queue spool killtest` clean, and
  `bash control-plane/test.sh` (`go test ./... -count=1`) green in 12 of the 13
  packages (`agent` 24.1 s, `hostadapter` 1.0 s, `journal` 1.8 s, `killtest`
  49.7 s, `lifecycle`, `run`, `queue`, `reconcile`, `spool`, `cmd/*`) with
  `chief` the one red: `TestAutopilotSeamRunsThePluginParser` and
  `TestTheAPIServesTheTicketRouteAndItsRefusals` are deterministic there because
  the image carries no `jq` for `skills/orchestrate/parse-flags.sh`, and both
  reproduce on the full-tree `git archive HEAD` baseline (`2d8de57`) in the same
  image. The takeover lease/retry cases move with load, not with this diff:
  `TestTakeoverSetSelection` appeared in one full-suite run (the CDT-661 lease
  flake named above) and `chief` in isolation is red only on the `jq` pair, 3/3
  runs. `-race` is clean on `./agent ./hostadapter` (25.9 s / 2.0 s). Every
  CDT-679 test is green at `-count=10` (`agent` 10.7 s, `hostadapter` 2.4 s).
- CDT-679 review-round-1 rework gate run (2026-11-27, same digest-pinned G-02
  image): `go build ./... && go vet ./...` clean and
  `gofmt -l agent chief hostadapter journal run lifecycle reconcile cmd queue
  spool killtest` clean. `bash control-plane/test.sh` green in 12 of the 13
  packages (`agent` 24.3 s, `hostadapter` 1.0 s, `reconcile` 2.7 s, `killtest`
  49.7 s); `chief` is red only on the `jq`-absent pair named above plus the
  takeover lease flake, and the `git archive HEAD` baseline in the same image is
  red on the same set — 3 of 3 probe rounds at baseline against 1 of 3 here
  (`TestTakeoverSetSelection`, `TestRetryStartsANewRunWithTheSameTicket`), and
  both are green at `-count=5` in isolation. `./reconcile ./agent ./hostadapter`
  are green at `-count=5` (8.4 s / 118.2 s / 4.0 s) and clean under `-race`.
  Mutation checks: turning the `agent.handshake` self-evidence branch off fails
  `TestPendingHandshakeIntentIsSelfEvidencing` alone; judging `runnerExit` from a
  stale id fails `TestSuperviseHandshakeExitWithACapturedIDCompletesTheRun`
  alone; one byte of drift in the fixture's client frames fails
  `TestGrokHandshakeFramesAreTheProbeShapes` and
  `TestGrokACPSessionOpensThroughTheAgent`. Spec-lint (SPEC-008) clean,
  docs-drift green (3 waived), traceability report-only (1 pre-existing).
- AC5 (live Grok run reaches `agent.premise` `delivered: true`) — `[process]`,
  LANDED 2026-11-27: the fixed binary was deployed to `~/.local/bin/chiefd`
  (prior binary kept at `~/.local/bin/chiefd.pre-CDT-679`), the live
  `dev-team-chiefd.service` restarted (chiefd pid 281410, journal
  `.claude/runs/run.db`), and a minimal live run routed through
  `POST /v1/route` (`{"kind":"defect","title":"cdt-679-live-acp-handshake-proof",
  "host":"grok"}`). Run `cdt-679-live-acp-handshake-proof` journal reading:
  `agent.start` outcome pid 283287 (seq 161); the `agent.handshake` closed pair
  `delivered: true, frames: 3` (seq 163→164); `agent.session` captured
  `01a21c89-0525-78d2-b292-4e682593c8ae` (seq 165→166); `agent.premise`
  outcome `delivered: true` naming that session id (seq 167→168) — the
  premise landed as the session's first turn within ~20 s of the spawn,
  where the pre-fix run `test-sidecar-sh-fails-after-dst-transitions-local-`
  (2026-11-27) timed out at the 30 s bound with `delivered: false`. The host
  reached work: the grok session transcript
  (`~/.grok/sessions/…/01a21c89-0525-78d2-b292-4e682593c8ae/chat_history.jsonl`)
  shows the premise received, one tool call executed against the repo
  (read `CHANGELOG.md` line 1), and the agent's text reply. The node agent
  runs inside chiefd (`control-plane/cmd/chiefd/main.go:138` `agent.New()`),
  so the fixed binary ride is chiefd itself.
- Spec-lint (SPEC-008) and docs-drift green on the landed diff
- CDT-665 gate run (2026-11-25, digest-pinned G-02 image, go1.27.4):
  `go build ./... && go vet ./...` clean, `gofmt -l agent chief hostadapter`
  clean, and `bash control-plane/test.sh` (`go test ./... -count=1`) green —
  all 13 packages `ok`, incl. the `killtest` restart lane (49.9 s). `-race` is
  clean on `./chief ./agent ./hostadapter` (7.99 s / 14.5 s / 1.46 s) with the
  three pre-existing cases skipped: `TestTakeoverScanResumesTheJournaledSession`
  and `TestTakeoverSetSelection` (the CDT-661 async-row read and the 1 s-limit
  lease flake — both cured on `master` by CDT-669 and red at this branch's
  v2.1.26 baseline: stash-verified, 5/5 under `-race`), and
  `TestSuperviseTakeoverKillsTheLiveOrphan` (deterministic in this container at
  the baseline, 3/3; `ok` in the full-suite runs on this diff). Every CDT-665
  test is green at `-count=10`: the six premise cases in
  `control-plane/agent/agent_test.go`, the three in
  `control-plane/hostadapter/hostadapter_test.go` (incl.
  `TestStartAndResumeCarryTheRendererWithNoPremise`) plus the widened
  `TestSteerThroughTheAgentDeliversAtTheBoundary` seam, and the four
  `control-plane/chief` seam cases (incl.
  `TestTakeoverRedeliversThePendingPremiseRowFromTheJournal`).
- The TL-review fixes are RED-proved with the masks put back: gate the
  renderer on the request's premise text and the chief proof fails with "the
  takeover spawn carries no premise frame renderer" while the adapter test
  fails "carries no premise frame renderer" on all six Start/Resume rows;
  recount the attempt from `agent.start` and the pair reads attempt 1 (intent)
  / 2 (outcome). All three restore to green.

## Version History

| Date | Change |
|------|--------|
| 2026-11-27 | CDT-679: Grok runs start. The Grok host spec carries the ACP client handshake as data — `grokHandshakeFrames(cwd)`: `initialize` (client capabilities `terminal: false`, P-GK-CTR-3c), `notifications/initialized`, `session/new` with the run's cwd — and `hostadapter.Adapter.Start`/`Resume` hand it to the agent as `StartRequest.Handshake`, the CDT-665 M16 shape: the agent writes frames, never encodes them. The node agent performs the handshake before its poll loop, journal-first as an `agent.handshake` intent/outcome pair keyed `agent:handshake:<run>#<attempt>` under the live lease token, writing the frames with the runner's `Steer` seam; the cwd it journals is the directory the child inherits at spawn. The capture keeps the CDT-661 path and gains one reading: a `session/new` response that carries a JSON-RPC error is reported beside the id (`HandshakeSource.HandshakeError`). A handshake that cannot complete stops the child and halts the run in a new named halt, `handshake_failed` (retry budget 1, takeover-refused), for the three causes AC3 names — the JSON-RPC error, a child that dies before the id lands, and the bounded wait that expires empty — so an ACP child never idles as `running`; this narrows CDT-665 AC6's ride-on rule for the handshake transport. Claude Code, omp, and mini-swe name no handshake and their starts are unchanged. New M18, `### CDT-679` AC1–AC6, the `handshake_failed` vertex and edge in `docs/internal/control-plane/lifecycle-graph.json`. `control-plane/VERSION` `0.3.0` → `0.3.1` (a defect fix — a Grok run never reached work; no new capability); the plugin version pair is untouched. |
| 2026-11-25 | CDT-665: the run's work premise reaches the spawned session's first turn. The chief carries the route's premise text onto the start (`hostadapter.StartRequest.Premise` → `agent.StartRequest.Premise`), the node agent delivers it journal-first as an `agent.premise` intent/outcome pair keyed `agent:premise:<run>#<attempt>` (one closed pair per run, keyed by the attempt that opened the session, under the live lease token), and the host adapter's per-host spec owns the first-turn frame: the Claude Code stream-json user message, the Grok ACP `session/prompt` (waiting on the captured session id, probe P-GK-ACP-1, because the frame names the session), and the omp RPC `{"type":"steer","message":…}` command; mini-swe's matrix cell (c) refuses a start that carries a premise. The takeover re-delivery rule is `deliverSteers` generalized — a CLOSED pair writes no second turn and journals no new row, a PENDING intent is performed once from the text the row carries — and M3's one spawn path is untouched. The bounded session-id poll closes an unrenderable premise with `delivered: false` and the named cause: never a halt, never a hang. New M16/M17, `### CDT-665` AC1–AC7, and `docs/internal/control-plane/native-runner.md` § "CDT-644" D4 names the premise frame in the runner contract. `control-plane/VERSION` `0.2.2` → `0.3.0` (a new capability that completes the CDT-626 route contract: a chief-routed run reaches `completed` without a human); the plugin version pair is untouched. TL review landed in the same change: the first-turn renderer attaches from the host's SPEC on every `Adapter.Start` and `Adapter.Resume` of that host — never on the request's premise text — so a re-adoption that carries no text performs the pending row (AC4, proved unmasked by `TestTakeoverRedeliversThePendingPremiseRowFromTheJournal`: empty premise, no caller-supplied frame), a premise-less spawn on mini-swe attaches nothing and is not refused, the outcome of a re-delivery names the attempt its intent opened, AC2 reads per-run (M16's rule is run-wide), and M16 names the pre-intent window it does not claim. |
| 2026-11-24 | CDT-664 (CDT-660 TL-review follow-ups): the chief's run record survives a refused start — two starts for one run id share one `runRecord`, so registration keeps a confirmed start's `Cap`, an errored start deletes only an unconfirmed record, and a confirmed start re-creates the record a refused sibling removed (M3's bookkeeping); the halt scan re-reads the takeover's answer before it pages, closing the intent row with the outcome `suppressed: the takeover answered the halt` (M9/AC9). Prose letters: M8/AC15 state the shutdown truth (chiefd never releases the lease — the release is the reconciler's `Machine.Repair` path, which the no-run-event rule forbids on shutdown), M3 names the `Cap` field and the `chief.hostFromJournal` split (first matching intent, one `ErrNotSteerable`), M1 records the no-lease-row selection, M6 the unreadable-lease continue, S1 the unconfirmed bucket and the per-process log-line dedup, and the loose `adopts` verb becomes "takes over". `control-plane/VERSION` `0.2.1` → `0.2.2`. |
| 2026-11-24 | CDT-661: the host session id is journaled and adoption resumes it — the node agent journals the id its runner's capture holds as an `agent.session` `side_effect` intent/outcome pair under the live lease token (AC1), the Grok ACP transport joins the captured hosts by reading `result.sessionId` off the `session/new` response frame pinned to a recorded probe transcript (AC2, AC7), the takeover resumes the journaled session through `hostadapter.Adapter.Resume` with `hostadapter.ResumeRoute` gating CDT-660's fresh re-spawn fallback (AC3/AC4), `effectEvidence` treats a pending `agent.session` intent as self-evidencing so the two-append crash window never halts the run `halted:reconcile_failed` (a state the takeover refuses), and the restart kill test proves the same host session survives the crash (AC5). `control-plane/VERSION` `0.2.0` → `0.2.1` (AC6). `### CDT-661` AC1–AC7. |
| 2026-11-21 | CDT-656: clock- and environment-independent control-plane tests — `TestSuperviseSteerThenOperatorStop` pins a wide `DEVTEAM_STALL_LIMIT` (270) so a loaded CI runner can no longer race the 1 s default limit into `ErrSteerLost` between `waitRunner` and the steer; the chief model-map seam subtest execs the real `resolve-model.sh` against a layer-free fixture checkout (its own git root + pinned `HOME`/cwd) instead of the live worktree, whose shared store may carry a DRI's local Model map layer; new `control-plane/test.sh` runs `go test ./... -count=1` and restores the ship-gate Verify binding the spec-lint pass dropped. `### CDT-656` ACs A–C. |
| 2026-11-20 | Spec-lint pass (CDT-660): added the `## Validation` record — the landed proofs per AC, incl. the AC13 restart kill test inside the control-plane CI job and the digest-pinned G-02 image run. Every AC bullet now carries the M14(g) bullet form `- **ACn.** …`; the 14 `Verify:` lines that named Go `_test.go` files are dropped, because M14(g) admits a suite script basename (`test.sh`, `test-*.sh`, `*-test.sh`) only and no suite script covers the Go lane — the proofs are named in `## Validation` instead (a `control-plane/test.sh` suite is the follow-up that restores the ship-gate Verify binding). AC13 is a `[process]` AC, so it holds no Verify line by rule. Registered in `specs/TDD.md`. No MUST, Test, or AC requirement text changed. |
| 2026-11-20 | SPEC-044 created (CDT-660): chiefd startup takeover of in-flight runs — the chiefd half of the CDT-626 reboot contract. Premises P1–P4 accepted per the DRI rulings of 2026-11-20; AC1–AC14 from the PM's revised scope review, plus AC15 (shutdown contract) and AC16 (version) from the rulings. |
