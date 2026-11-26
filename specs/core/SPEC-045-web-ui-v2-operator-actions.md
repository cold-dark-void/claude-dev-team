# SPEC-045: Web UI v2 — Operator Actions, Run Detail, the Existing-Ticket Route, and the Design Pass

**Status**: ACTIVE
**Category**: core
**Created**: 2026-11-25

**Covers**: `control-plane/chief/chief.go`, `control-plane/chief/api.go`, `control-plane/chief/actions.go` (new), `control-plane/chief/output.go` (new), `control-plane/chief/errors.go`, `control-plane/chief/seams.go`, `control-plane/chief/board.go`, `control-plane/chief/chief_test.go`, `control-plane/chief/api_test.go`, `control-plane/chief/actions_test.go` (new), `control-plane/chief/e2e_test.go`, `control-plane/agent/agent.go`, `control-plane/hostadapter/adapter.go`, `control-plane/cmd/chiefd/web/{index.html,app.js,style.css}`, `control-plane/cmd/chiefd/main.go` (usage text), `docs/internal/control-plane/index.md` (CDT-650 AC1 and CDT-652 record amendments)

---

## Overview

The CDT-600 dogfood run (2026-11-25) found the phase-1 web UI too thin to
operate runs. Four gaps:

- **P1**: the Chief has three routes (defect, idea, epic) and every one
  creates a new ticket record. There is no route for work that already has
  a ticket id: running `/orchestrate CDT-600` required smuggling the command
  into a defect premise, which wrote a duplicate backlog item and mislabeled
  the run `debug`.
- **P2**: the API has only `POST /v1/route` and
  `POST /v1/runs/{id}/corrections`. There is no stop, no resume, no retry —
  a stuck run needed `node-agent stop` from a shell.
- **P3**: the board shows state and phase, but not the premise the run was
  sent, the host it rides, or its session output and journal rows.
- **P4**: the page has no visual hierarchy.

This spec lands the four fixes in one surface. The Chief's closed route set
gains a fourth kind, `ticket`: an existing backlog id routes to
`/orchestrate` (or `/epic` when the id names an epic), writes no new ticket
record, and carries an autopilot token validated by the plugin's own flag
parser. Three operator actions — **stop** (operator halt),
**resume** (same-run continuation through the takeover/resume seam), and
**retry** (a new run carrying the same ticket field) — join the API and the
UI. The run detail view shows the premise, the host, the resolved model, the
lifecycle state, the journal rows, and a live tail of the session output,
read from the host transcript read-only. The page gets the design pass: the
run board is the main view, one status color per state, runs grouped by
ticket with their attempt numbers, readable at 375 px.

The journal stays the one record: no event kind is added, no lifecycle-graph
vertex changes, and every read the UI makes rides `chief.Handler`'s
endpoints — the one interface (CDT-650 AC6).

## Boundaries

- **ADR 0001 (journal engine)** owns the closed event set. Stop journals a
  `run_halted` row with reason `operator_halt` (the existing side-effect
  intent-then-outcome plus the named halt the node agent's stop verb already
  writes); resume journals `run_resumed`; retry starts a *new* run whose
  rows are the ordinary `run_claimed`/`run_started` kinds. This spec adds no
  kind and no payload.
- **control-plane/run** owns the state machine, the named halt states, and
  `RetryBudgets`. This spec does not change a budget, a halt reason, or a
  transition. `failed` stays terminal; `halted:operator_halt` keeps its
  zero budget — the recovery path for a stopped run is retry (a new run),
  not resume.
- **CDT-650 AC1 / CDT-652** own the closed route set and the one-screen
  record. This spec amends both records *explicitly* (M9) — the closed set
  is widened by amendment, never silently.
- **CDT-671** owns the run progress signal. The output tail here is the
  host transcript read raw; it is not a progress signal and carries no
  lifecycle state.
- **CDT-630** owns remote access. Every new endpoint rides the existing
  loopback-only bind; this spec opens no remote path.
- **SPEC-037 (Model map)** owns model resolution. The model preflight read
  and the route resolve through the same `ModelResolver` seam — no second
  copy of the map.
- **SPEC-044 (takeover)** owns the resume seam. The operator resume rides
  `chief.startSupervisedResume` / `hostadapter.Adapter.Resume` — the one
  re-supervision path; no fork of it.

## MUST

- **M1 — The existing-ticket route (kind `ticket`).** The closed route set
  gains a fourth kind: `surfaces` carries a `ticket` entry naming the
  `orchestrate` workflow and the real plugin file
  `skills/orchestrate/SKILL.md`, and `RouteKinds` lists `ticket`. A
  `ticket` route request carries the ticket id (an existing backlog slug)
  and an optional autopilot token. The Chief MUST validate the id against
  the local store — the item file `$MROOT/.claude/backlog/<id>.md` MUST
  exist — and MUST refuse an unknown id with a typed error before any run
  row is written. The route MUST write no ticket record: the ticket seam
  (`TicketCreator`) is not called, and the store gains no row (AC8). The
  run's claim payload names the existing id as the `ticket` and
  `orchestrate` as the `workflow`; when the item's frontmatter carries
  `kind: epic`, the workflow is `epic` (the run rides the epic surface). A
  repeat route of the same id MUST create a further run (a new attempt),
  never a refusal and never a second backlog item (AC8).
- **M2 — Run-id allocation by attempt.** A ticket's first run keeps the
  plain slug as its run id. Each further run for the same ticket id is
  `<slug>-r<N>`, where N is one past the highest attempt the journal
  already carries for that ticket (the journal's `ticket` field is the
  grouping key, so restarts cannot double-allocate). The id MUST satisfy
  the node agent's run-id grammar (`^[A-Za-z0-9][A-Za-z0-9._-]*$`). The
  run's attempt number is derivable from its id (M6).
- **M3 — The autopilot token rides the plugin's own parser.** The legal
  token set is `bare | auto | patch | minor | major | master`, default
  `auto` — the vocabulary of `skills/autopilot/parse-flags.sh`. The Chief
  MUST validate the token through a seam that execs that script (argv, never
  a shell string) and MUST refuse an illegal token with a typed
  exit-64-equivalent error before any run row is written (AC1). The
  composed premise is the command line the run executes:
  `/orchestrate <ID> --autopilot=<token>` (or `/epic <ID> …` for an epic
  id; the `bare` token composes a valueless `--autopilot`). The route
  response carries the composed command and the resolved model and source.
- **M4 — Stop.** `POST /v1/runs/{run}/stop` halts a run to
  `halted:operator_halt` and MUST be valid from `running` (the node agent's
  existing signal path: intent row, stop, outcome row, named halt) and from
  `claimed` (nothing is signalled: the run holds no recorded runner yet, so
  the stop is the journal trail alone). Stop outside those states MUST
  refuse with a distinct typed error the UI renders verbatim. The action is
  journaled as `run_halted` — no new event kind.
- **M5 — Resume.** `POST /v1/runs/{run}/resume` continues the *same* run
  from `halted:<reason>` through the takeover/resume seam: the Chief
  derives the host from the run's recorded start argv and the session id
  from the run's journaled `agent.session` rows — never from the in-memory
  capture, which a restart loses — and re-supervises through
  `startSupervisedResume` / `Adapter.Resume`. The Chief is the resume
  owner. Resume MUST refuse with a distinct typed error when the run is
  not halted, when the host's matrix cell denies `CapResume`, when the
  journal names no session id to resume by, and when the reason's retry
  budget is spent (the replay's `ErrBudgetExhausted`). Because
  `operator_halt` carries budget 0, a stopped run is not resumable — its
  recovery path is retry (M6); the UI renders the refusal verbatim. The
  node agent's supervision gate — which today resumes only
  `halted:stalled` — MUST accept the operator resume of the run's current
  halt reason under the same machine call (`run.Machine.Resume`), so no
  second resume path and no new event kind exist.
- **M6 — Retry.** `POST /v1/runs/{run}/retry` starts a NEW run carrying the
  same `ticket` field, the same `workflow`, and the same journaled model,
  at attempt N+1 (M2). Retry MUST be valid from `failed` and from
  `halted:<reason>` and MUST refuse otherwise with a distinct typed error;
  `failed` stays terminal in the lifecycle graph — retry changes no state
  of the old run and adds no event kind. The retried run's premise is its
  journaled premise (the `agent.premise` row); the host derives from the
  old run's start record unless the request names one (matrix-gated as any
  start). The response carries the new run id.
- **M7 — Run detail reads.** `RunStatus` MUST carry what the detail view
  renders: the premise text (folded from the run's journaled
  `agent.premise` rows), the host (folded from the recorded start argv —
  the same fold a correction already rides), the attempt number, and
  whether the run's host supports resume (the matrix's `CapResume` cell —
  the one copy of the verdicts). `GET /v1/runs/{run}/events` MUST serve the
  run's full journal row list. `GET /v1/runs/{run}/output` MUST serve a
  tail of the host transcript, read-only: Claude
  `~/.claude/projects/<dash-encoded-cwd>/<session-id>.jsonl`, Grok
  `~/.grok/sessions/<urlencoded-cwd>/<session-id>/chat_history.jsonl`, omp
  `~/.omp/agent/sessions/<cwd-slug>/<ISO-ts>_<session-id>.jsonl` — the
  layouts the capability matrix's probe records pin. The omp layout is
  amended (2026-11-25, landed probe): the session id is the filename's
  **suffix**, not its stem, so the glob is `*_<session-id>.jsonl` and stays
  `.jsonl`-only because a sibling directory shares the stem. Probe record
  P-OMP-C-A, session `01a1ddda-7a27-760e-bd6c-a123b85f0b5e`
  (`docs/internal/control-plane/host-capability-matrix.md`). The tail MUST
  bound both lines (default 200, at most 1000) and bytes (64 KiB) and MUST
  answer an unreadable or absent transcript with an explicit empty result —
  never an error, never a guessed path. All of these ride `chief.Handler` —
  no second interface.
- **M8 — The model preflight read.** `GET /v1/model?agent=<agent>` serves
  the Model map's resolution (model and source) through the same
  `ModelResolver` seam the route uses, so the route form displays the
  Model map default before routing (AC4). The read is pure — it writes
  nothing.
- **M9 — The records are amended explicitly.**
  `docs/internal/control-plane/index.md` § CDT-650 AC1 is amended to name
  the four-kind closed route set (`defect`, `idea`, `epic`, `ticket`) and
  § CDT-652 is amended to admit the v2 surface (the actions, the run detail
  reads, and the design pass) — each as a dated amendment paragraph that
  cites this spec. The amendment is the widening's provenance; nothing
  else widens the closed set.
- **M10 — Every new endpoint binds loopback only.** The new POST verbs and
  the two new GET verbs are served by the same chiefd process on the same
  loopback port as the existing API; the `loopbackOnly` bind guard is
  unchanged and covers them all (AC6).

## SHOULD

- The UI SHOULD poll the board at its existing cadence and the output tail
  at ~2 s — bounded polling, loopback only, no streaming channel.
- Action buttons SHOULD be hidden for states that cannot take them and
  disabled (not hidden) while the state is merely unsettled; hosts without
  `CapResume` show Retry only — the Resume button is hidden entirely (AC7).
- The run board SHOULD group runs by ticket and display each run's attempt
  number beside it (AC5).
- The design pass SHOULD keep one status color per state across the board,
  the detail view, and the lifecycle drawing, and SHOULD keep the page
  readable at 375 px with no horizontal scroll.

## MUST NOT

- MUST NOT add a journal event kind, a halt reason, a retry budget, or a
  lifecycle-graph vertex or edge. Stop, resume, and retry ride the closed
  set as it stands.
- MUST NOT change `failed` or `completed` into non-terminal states, and
  MUST NOT resume a `failed` run (retry is the path).
- MUST NOT write a ticket record from the `ticket` route — the local store
  gains no row from routing an existing id, on any repeat (AC8).
- MUST NOT add an endpoint outside `chief.Handler`, a UI-only endpoint, or
  a private UI state source (AC9).
- MUST NOT expose any endpoint off loopback, and MUST NOT add TLS, tunnel,
  or access-layer code (CDT-630 owns exposure).
- MUST NOT copy the autopilot vocabulary, the host capability verdicts, the
  Model map, or the ticket-store semantics into Go — each stays the
  plugin's own file or CLI, reached through the seams (ADR 0001).
- MUST NOT read the host transcript for anything but the tail the detail
  view serves, and MUST NOT write to it.
- MUST NOT implement the run progress signal — CDT-671 owns it.
- MUST NOT fork the takeover/resume seam: the operator resume rides
  `startSupervisedResume` / `Adapter.Resume`, and the node agent's
  supervision gate is widened in place, not duplicated.

## Test

The gate home is the test suite of `control-plane/chief/` (the route, the
actions, the detail reads, and the e2e seam) plus `control-plane/agent/`
(the claimed-stop and the widened supervision gate) and
`control-plane/cmd/chiefd/` (the served page). The e2e proof rides the C6
seam — a real child process — exactly as the CDT-652 board e2e does: every
step of route → detail → stop → resume/refusal → retry over the HTTP
endpoints the UI drives, never a Go call into the Chief.

## Acceptance criteria

### CDT-672

- **AC1.** Existing-ticket route (kind `ticket`). The route form accepts a
  ticket id (an existing backlog slug) and an autopilot token; the legal
  token set is `bare | auto | patch | minor | major | master` (default
  `auto`, the vocabulary of `skills/autopilot/parse-flags.sh`) and the form
  shows all six choices. The Chief starts `/orchestrate <ID>
  --autopilot[=<token>]`, writes no new backlog item, and records the
  workflow as `orchestrate`. An epic ticket id routes `/epic <ID>
  --autopilot[=<token>]`. The route kind `ticket` is added to the closed
  `surfaces` set; the CDT-650 AC1 and CDT-652 records are amended
  explicitly in this ticket (M9), not silently widened. Proof:
  `TestRouteExistingTicketStartsOneRun` (one run, zero new store rows,
  `workflow == "orchestrate"`), `TestRouteExistingEpicRoutesTheEpicPath`,
  `TestRouteRefusesAnIllegalAutopilotToken`,
  `TestRouteRefusesAnUnknownTicketID`, and
  `TestSurfacesStillWorkStandaloneInTheTerminal` with the four-kind set
  (`control-plane/chief/`).  
  Verify: bash control-plane/test.sh
- **AC2.** Operator actions (stop, resume, retry). Stop is an operator halt
  to `halted:operator_halt` from `running` or `claimed`, journaled as
  `run_halted`. Resume is the same-run continuation of a `halted:<reason>`
  run through the takeover/resume seam (`startSupervisedResume` /
  `Adapter.Resume`), the Chief is the resume owner, it is journaled as
  `run_resumed`, and it spends one retry of that reason per
  `RetryBudgets`; the Resume button is gated on the host's `CapResume`
  capability cell — hosts without the capability show Retry only. Retry is
  a NEW run carrying the same ticket field; `failed` stays terminal in the
  lifecycle graph. Every action appends events in the closed journal event
  set — no second event taxonomy. Proof:
  `TestStopHaltsRunningAndClaimedRuns`,
  `TestResumeContinuesTheSameRunThroughTheResumeSeam`, and
  `TestRetryStartsANewRunWithTheSameTicket` (`control-plane/chief/`).  
  Verify: bash control-plane/test.sh
- **AC3.** Run detail view. Selecting a run shows the premise text sent to
  the host, the host (Claude / Grok / omp), the resolved model (the Model
  map), the current lifecycle graph state, the full journal event list, and
  a live tail of the session output. Run state derives from the journal
  only; the output tail reads the host transcript read-only (Grok
  `~/.grok/sessions/<cwd>/<id>/chat_history.jsonl`; Claude
  `~/.claude/projects/<cwd>/<id>.jsonl`; omp per the matrix's probe record)
  with a last-N-lines bound and a byte cap. The tail refreshes by bounded
  polling (~2 s), loopback only. The progress signal itself stays in
  CDT-671. Proof: `TestRunDetailCarriesPremiseHostModelState`,
  `TestRunEventsServeTheClosedKinds`, and
  `TestOutputTailBoundedAndReadOnly` (`control-plane/chief/`).  
  Verify: bash control-plane/test.sh
- **AC4.** Host picker. The route form shows the host the run will use
  (Claude / Grok / omp) with the Model map default preselected and
  displayed. Proof: `TestModelPreflightServesTheMapDefault`
  (`control-plane/chief/`) and `TestTheUIRidesTheAPISPort`
  (`control-plane/cmd/chiefd/`).  
  Verify: bash control-plane/test.sh
- **AC5.** Design pass. The run board is the main view; one status color
  per state (`claimed`, `running`, `halted:<reason>`, `completed`,
  `failed`); run detail opens on select; the page is readable at 375 px
  with no horizontal scroll; static files via `go:embed` with no build
  step. The board groups runs by ticket and displays the attempt number
  for each run. Proof: `TestTheBoardGroupsRunsByTicketWithAttempts` and
  `TestTheUIRidesTheAPISPort` (`control-plane/cmd/chiefd/`).  
  Verify: bash control-plane/test.sh
- **AC6.** Loopback containment. Every new endpoint binds loopback only;
  CDT-672 does not open remote access (CDT-630 owns exposure). Proof:
  `TestNonLoopbackBindIsRefused` and `TestRunRefusesANonLoopbackAddr`
  unchanged, plus `TestNewEndpointsServeOnTheLoopbackHandler`
  (`control-plane/cmd/chiefd/`, `control-plane/chief/`).  
  Verify: bash control-plane/test.sh
- **AC7.** State consistency of actions. Stop / Resume / Retry are refused
  with distinct, UI-rendered errors on states where they are not valid:
  stop outside `running`/`claimed`; resume outside `halted:<reason>`;
  resume where the reason's retry budget is spent. Action buttons are
  disabled or hidden for states that cannot take them, and hidden entirely
  on hosts lacking `CapResume` (Retry-only hosts). Proof:
  `TestActionRefusalsAreDistinctAndTyped` (`control-plane/chief/`) and
  `TestActionButtonsGateOnStateAndCapability`
  (`control-plane/cmd/chiefd/`).  
  Verify: bash control-plane/test.sh
- **AC8.** Duplicate prevention. Routing an existing ticket id never
  creates a second backlog item, including on repeat routes of the same
  id. Two routes for one ticket create two runs (distinct attempts) and
  still exactly one ticket. Proof: `TestRepeatRoutesNeverWriteTheStore`
  (`control-plane/chief/`).  
  Verify: bash control-plane/test.sh
- **AC9.** Single read source. All UI reads derive from the journal/API
  (the one interface in `api.go`); the UI adds no private state source.
  Proof: `TestTheUIReadsOnlyTheAPI` (`control-plane/cmd/chiefd/`).  
  Verify: bash control-plane/test.sh

## Alternatives considered

- **Let the operator resume a `halted:operator_halt` run.** Rejected: the
  C2 budget contract gives `operator_halt` budget 0 by design — an operator
  resume that bypassed it would fork the budget rule or widen
  `RetryBudgets`, and the recovery path (retry, a fresh attempt) preserves
  the same work without touching the contract.
- **Hard-code the autopilot vocabulary in Go.** Rejected: it duplicates
  `skills/autopilot/parse-flags.sh` and drifts when the plugin's token set
  changes; the seam costs one exec per route.
- **Serve the output tail from the in-memory capture.** Rejected: the
  capture is lost on a chiefd restart, which is exactly when an operator
  needs the detail view; the journaled `agent.session` rows and the host's
  transcript on disk are the durable source.
- **Journal a `run_retried` event on the old run.** Rejected: the closed
  event set needs no new kind — the new run's own claim row is the record,
  and the old run's terminal state stays untouched.
- **Let the browser read the host transcript directly.** Rejected: it
  breaks the one-API rule (AC9) and would need a file-serving endpoint
  outside `chief.Handler`'s fold discipline; the chief's bounded tail keeps
  the read server-side, capped, and journaled-source-only.

## Validation

Proof plan — each row names the test that lands the AC's evidence
(`control-plane/test.sh` runs the whole Go lane; the record below is filled
with landed proof as the work merges):

- AC1/AC8: `control-plane/chief/chief_test.go` — the `ticket` route starts
  one run per route with zero store rows, refuses an illegal autopilot
  token and an unknown id before any row, and repeat routes allocate
  `<slug>-rN` attempt ids
- AC2/AC7: `control-plane/chief/actions_test.go` — stop from `running` and
  `claimed`, resume through the resume seam with the spent-budget refusal,
  retry from `failed`/`halted` with the same ticket field, and the typed
  refusal set
- AC3: `control-plane/chief/output_test.go` — the detail fields, the
  journal row list, and the per-host bounded transcript tail
- AC4/AC5/AC6/AC9: `control-plane/cmd/chiefd/main_test.go` — the served
  page's board markup, the model preflight, the loopback bind, and the
  `/v1`-only fetch contract
- The supervision-gate widening for the operator resume is proved in
  `control-plane/agent/agent_test.go`

## Version History

| Date | Change |
|------|--------|
| 2026-11-25 | SPEC-045 created (CDT-672): web UI v2 — the existing-ticket route (kind `ticket`), the stop/resume/retry operator actions, the run detail reads (premise, host, events, bounded output tail), and the design pass. The CDT-650 AC1 and CDT-652 records are amended explicitly by the ticket. |
| 2026-11-25 | M7 omp transcript layout corrected to the landed probe: `~/.omp/agent/sessions/<cwd-slug>/<ISO-ts>_<session-id>.jsonl` — the session id is the filename suffix, so the glob is `*_<session-id>.jsonl`, `.jsonl`-only (a sibling directory shares the stem). Record P-OMP-C-A, session `01a1ddda-7a27-760e-bd6c-a123b85f0b5e`. |
