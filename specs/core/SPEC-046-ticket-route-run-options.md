# SPEC-046: Ticket-Route Run Options — the /orchestrate Options and the Budget Caps on the Chief's Existing-Ticket Route

**Status**: DRAFT
**Category**: core
**Created**: 2026-11-27 (CDT-677)

**Covers**: `control-plane/chief/chief.go` (route request, composition,
option-validation wiring), `control-plane/chief/seams.go` (the option and
advisor validation seams), `control-plane/chief/api.go` (`POST /v1/route`,
the error surface, the run-detail read), `control-plane/chief/actions.go`
(retry), `control-plane/chief/takeover.go` (takeover re-spawn),
`control-plane/journal/replay.go` (`StartPayload` extension),
`control-plane/journal/state.go` (journaled caps),
`control-plane/hostadapter/adapter.go` (the run-scoped environment channel),
`control-plane/cmd/chiefd/web/{app.js,index.html,style.css}` (the Advanced
section), and their test suites.

## Overview

The CDT-672 ticket route carries only the autopilot token. A Chief-routed
run is less capable than a terminal run: `--with-advisor`, `--tier`,
`--council-tier`, `--max-loc`, `--concurrency`, and the
`AUTOPILOT_WALLCLOCK_CAP` / `AUTOPILOT_ITERATION_CAP` budget caps cannot be
set from the Chief UI or the API. This spec widens the existing-ticket route
(kind `ticket`) with those options, validates them through the plugin's own
parsers, carries the caps in the spawned session's environment, and makes
retry, resume, and takeover reproduce the same run faithfully.

The plugin side gains nothing: no new flag, no new parser key, no env-name
change (SPEC-033 N12, N14). The control plane composes the command line the
plugin already parses and relays operator-set caps the plugin's
`budget-check.sh` already reads from the environment.

## MUST

- **M1 — Route options contract.** The `ticket` route request MUST gain
  optional fields: `with_advisor` (empty = off; `true` = the bare
  `--with-advisor`; any other non-empty value = the `=<model>` token),
  `tier` (`light|standard|full`), `council_tier` (`skip|light|full`),
  `max_loc` (positive integer or the literal `unbound`), `concurrency`
  (positive integer ≥ 1), and `wallclock_cap` / `iteration_cap` (positive
  integers). An absent or empty field MUST compose nothing. Every new
  field MUST be refused (HTTP 400) on the `defect`, `idea`, and `epic`
  route kinds.
- **M2 — Pinned composition order.** The ticket route MUST compose the
  premise command line as `/<workflow> <ID>` followed by the present
  options in this pinned order: `--tier=<t>`, `--council-tier=<ct>`,
  `--max-loc=<n|unbound>`, `--concurrency N`, `--with-advisor[=<model>]`,
  then `--autopilot[=<token>]` last. `/<workflow>` is `/orchestrate`, or
  `/epic` when the local item's frontmatter kind is `epic` (SPEC-045 M1
  unchanged). A request with no options MUST compose today's exact command
  byte-for-byte.
- **M3 — Validation rides the plugin's own parsers; refuse before any row.**
  The Chief MUST validate through seams that exec the plugin's own scripts
  as argv — never a shell string, never a copied vocabulary (the
  SPEC-045 M3 pattern): `skills/autopilot/parse-flags.sh` validates the
  composed `--tier` / `--council-tier` / `--max-loc` tokens;
  `skills/advisor/parse-flags.sh` validates the `--with-advisor=<model>`
  token (SPEC-039 M37: charset `[A-Za-z0-9._:+@~/-]+`; `null` and
  `--clear` are reserved and refused). `concurrency` MUST be a mechanical
  positive-integer check at route time — the CDT-573 grammar cited, not
  copied; the council engine's preflight still owns the final in-session
  merge. The caps MUST be positive integers only, with no upper ceiling.
  An illegal value MUST answer a typed HTTP 400 error before any journal
  row is written.
- **M4 — Epic refusal for orchestrate-only options.** When the local
  item's kind is `epic` and the request carries any orchestrate-only
  option (`tier`, `council_tier`, `max_loc`, `concurrency`,
  `with_advisor`), the route MUST refuse with HTTP 400 naming the options
  that do not apply. An epic id MUST compose `/epic <ID>
  --autopilot[=<token>]` only.
- **M5 — Caps ride the runner's environment through a run-scoped
  non-credential channel.** `wallclock_cap` and `iteration_cap` MUST
  become `AUTOPILOT_WALLCLOCK_CAP` / `AUTOPILOT_ITERATION_CAP` on that
  run's runner environment only — native and container runners — through a
  new adapter seam beside the B7 credential injection, with an explicit
  allowlist of exactly the two cap names; any other name in the channel
  MUST refuse the start fail-closed. The caps are not credentials and MUST
  NOT touch the B7 proven-name table.
- **M6 — N12 ruling.** SPEC-033 N12 governs the plugin engine — it never
  writes `AUTOPILOT_ITERATION_CAP` / `AUTOPILOT_WALLCLOCK_CAP` to apply a
  derived budget. chiefd relaying an operator's explicitly requested
  per-run values is the operator's own act of writing, the same act as
  exporting the variables before a terminal run. N12 stays intact. N14
  stays intact: the caps carry no upper ceiling, touch no auto-tune tier
  table, and never become a plugin flag.
- **M7 — The caps ride the journaled `run_started` payload.** `StartPayload`
  MUST gain optional `wallclock_cap_s` / `iteration_cap_s` fields; replay
  MUST validate them non-negative when present — a present `0` means unset,
  the encoding `State` uses for "no cap" — and MUST refuse a negative cap as
  `ErrReplayInconsistent`; `State` MUST carry them so the API reads them.
  The route refuses a `0` cap under M3, so a journaled `0` is the absent
  cap. No new journal event kind. Retry MUST read the old run's
  caps from the journaled state; a takeover re-spawn MUST read them the
  same way and re-inject them through the one `startSupervised` seam — no
  second spawn path. An operator resume of a live session reuses the
  session by id and re-execs nothing, so the resume seam is unchanged.
- **M8 — Tracker-id passthrough.** A ticket-route id that matches the
  run-id grammar (SPEC-045 M2) but names no local backlog item MUST pass
  through: the route composes `/orchestrate <ID>` exactly as a local id,
  writes no store row, and the session fetches the tracker item itself —
  chiefd MUST NOT gain a Linear dependency or a network read. When a local
  item's frontmatter carries `linear_id: <ID>` matching the requested id,
  the route MUST resolve to that item: the kind-epic switch and the M4
  refusal apply as for a local id.
  This MUST amends SPEC-045 M1 explicitly (the SPEC-045 M9 discipline — an
  amendment, never a silent widening): SPEC-045 M1's rule that the local
  item file MUST exist, and its refusal of an unknown id with a typed
  error, now apply only to an id that fails the run-id grammar of
  SPEC-045 M2. A grammar-valid id with no local backlog item passes
  through as above. The matching dated row is in SPEC-045's Version
  History.
- **M9 — Run detail shows the options used.** The run detail read MUST
  show the composed command (the premise the run carries — SPEC-045 AC3)
  and the two caps in effect, derived from the journal and the API only;
  the UI MUST NOT add a private state source (SPEC-045 AC9).
- **M10 — Retry fidelity.** A retry MUST start the new attempt with the
  same premise flags and the same caps, recovered from the journaled
  trail. The retry request body MUST NOT accept option overrides.

## SHOULD

- The web UI SHOULD gain an Advanced section on the new-run (ticket route)
  form with the six new options, all empty by default; an empty form
  composes today's exact command. Caps SHOULD be numeric inputs; vocab
  fields SHOULD offer the plugin vocabularies as client hints only — the
  chiefd validation of M3 is the gate. The autopilot token SHOULD stay a
  first-class field outside Advanced.

## MUST NOT

- MUST NOT add a plugin flag, a seventh `parse-flags.sh` key, or any
  budget-cap surface to the plugin (SPEC-033 N12).
- MUST NOT raise the auto-tune L ceiling or add a `/setup` budget store
  (SPEC-033 N14).
- MUST NOT copy any flag vocabulary into `control-plane/` — every
  vocabulary check execs the plugin's own parser (M3).
- MUST NOT put a cap value in the premise command line, the chiefd unit
  environment, or another run's environment (M5).
- MUST NOT add a journal event kind (M7) or a second spawn/resume path.
- MUST NOT widen the closed route set or add a route kind (M1 keeps the
  four-kind closed set).
- MUST NOT accept option overrides on a retry request body (M10).

## Test

The gate home is the test suite of `control-plane/chief/` (the route, the
composition, the validation seams, the actions, and the e2e seam) plus
`control-plane/journal/` (the payload extension and replay validation),
`control-plane/hostadapter/` (the environment channel), and
`control-plane/cmd/chiefd/` (the served page). The e2e proof rides the C6
seam — a real child process — exactly as the CDT-652 board e2e does.

## Acceptance criteria

### CDT-677

- **AC1.** Route accepts the options (kind `ticket` only). `POST /v1/route`
  with kind `ticket` accepts the optional fields of M1 and composes them
  into the run's premise command line in the pinned order of M2 — id
  first, then `--tier=… --council-tier=… --max-loc=… --concurrency N
  --with-advisor[=<model>]`, then `--autopilot[=<token>]` last; the
  composition is byte-exact testable, and empty fields compose today's
  exact command. The response echoes the composed command as today. The
  new fields are refused with HTTP 400 on the `defect`, `idea`, and `epic`
  route kinds. Proof: `TestRouteTicketComposesOptionsInPinnedOrder`,
  `TestRouteTicketEmptyOptionsComposeTodaysCommand`, and
  `TestRouteNonTicketKindsRefuseTheOptionFields`
  (`control-plane/chief/`).  
  Verify: bash control-plane/test.sh
- **AC2.** Validation rides the plugin's own parsers; refuse before any
  journal row. The tier, council-tier, and max-loc values are validated by
  a seam that execs `skills/autopilot/parse-flags.sh` as argv; the advisor
  model token is validated by a seam that execs
  `skills/advisor/parse-flags.sh` (SPEC-039 M37 charset; `null` and
  `--clear` refused). Concurrency and the two caps are checked as positive
  integers at route time. No vocabulary is copied into `control-plane/`.
  An illegal value answers a typed HTTP 400 error before any run row is
  written. Proof: `TestRouteOptionValidationRidesThePluginParsers`,
  `TestRouteRefusesIllegalAdvisorModelToken`, and
  `TestRouteRefusesIllegalConcurrencyAndCaps` (`control-plane/chief/`).  
  Verify: bash control-plane/test.sh
- **AC3.** Caps ride the spawned session's environment, per run, nothing
  else. `wallclock_cap` and `iteration_cap` become
  `AUTOPILOT_WALLCLOCK_CAP` / `AUTOPILOT_ITERATION_CAP` on that run's
  runner environment only — native and container runners — through the
  run-scoped non-credential channel of M5 with its two-name allowlist.
  They never appear in the premise command line, the chiefd unit
  environment, or another run's environment. An operator-set cap overrides
  the Model map for that run (CDT-649 env precedence). Proof:
  `TestCapsReachTheRunnerEnvironmentPerRun`,
  `TestCapsNeverRideTheCommandOrUnitEnv`, and
  `TestRunEnvChannelAllowlistIsExactlyTheTwoCaps`
  (`control-plane/chief/`, `control-plane/hostadapter/`).  
  Verify: bash control-plane/test.sh
- **AC4.** Web UI Advanced section. The new-run form gains an Advanced
  section with the six new options; all empty by default; an empty form
  composes today's exact command. Caps are numeric inputs; vocab fields
  carry the plugin vocabularies as client hints only — the chiefd
  validation is the gate. The autopilot token stays a first-class field
  outside Advanced. Proof: `TestTheAdvancedSectionCarriesTheSixOptions`
  and `TestComposedCommandsPreviewCoversTheAdvancedOptions`
  (`control-plane/cmd/chiefd/`).  
  Verify: bash control-plane/test.sh
- **AC5.** Retry reuses the original run's options. `POST
  /v1/runs/{run}/retry` starts the new attempt with the same premise flags
  and the same caps, recoverable from the journaled trail of M7; no new
  journal event kind. The retry request body cannot override options. The
  retry refusal contract of SPEC-045 AC2 is unchanged. Proof:
  `TestRetryCarriesTheOriginalOptionsAndCaps` (`control-plane/chief/`).  
  Verify: bash control-plane/test.sh
- **AC6.** Run detail shows the options used. The run detail read shows the
  composed command and the two caps in effect, derived from the journal
  and the API only — no private UI state source. Proof:
  `TestRunDetailShowsTheComposedCommandAndCaps`
  (`control-plane/chief/`, `control-plane/cmd/chiefd/`).  
  Verify: bash control-plane/test.sh
- **AC7.** Tracker id with no local item passes through. A ticket-route id
  matching the run-id grammar with no local backlog item composes
  `/orchestrate <ID>` and writes no store row; chiefd gains no Linear
  dependency. A local item whose frontmatter `linear_id:` matches the id
  routes to that item, keeping the kind: epic → `/epic` switch. An id
  matching neither a slug nor any item's `linear_id:` composes the
  passthrough run — the "unknown ticket" refusal remains only for ids the
  grammar refuses. Proof: `TestRouteTrackerIDWithoutLocalItemPassesThrough`
  and `TestRouteResolvesALinearIDFrontmatterMatch`
  (`control-plane/chief/`).  
  Verify: bash control-plane/test.sh
- **AC8.** Resume and takeover reproduce the same environment. Operator
  resume and chiefd startup takeover carry the original run's caps again:
  a takeover re-spawn re-injects the caps from the journaled
  `run_started` payload through the existing `startSupervised` seam, and a
  resume rides the same seam unchanged — no second spawn or resume path.
  Proof: `TestTakeoverRespawnCarriesTheJournaledCaps` and
  `TestResumeRidesTheUnchangedResumeSeam` (`control-plane/chief/`).  
  Verify: bash control-plane/test.sh
- **AC9.** Boundary and scope locks preserved. No plugin flag for the caps
  (SPEC-033 N12); no L-ceiling raise (N14); no new journal event kind; no
  second spawn or resume path; the closed route set is unchanged. Proof:
  the unchanged plugin diff at `skills/` (no new flag or parser key) and
  the unchanged replay event-kind set (`control-plane/journal/`).  
  Verify: bash control-plane/test.sh

## Alternatives considered

- **Compose the caps into the command line.** Rejected: SPEC-033 N12
  forbids a budget-cap flag and a seventh `parse-flags.sh` key; a
  command-line cap would be exactly that flag.
- **Put the caps in the chiefd unit environment.** Rejected: the unit env
  is process-wide — every run and every route would inherit one operator's
  caps. The caps are per-run operator intent (M5).
- **Carry the caps in a new journal event kind** (for example
  `run_configured`). Rejected: the closed event-kind set exists so replay
  stays total; the `run_started` payload is the natural carrier of a
  start's own parameters, as `stall_limit_s` already is.
- **Validate the vocabularies in Go.** Rejected for the parser-backed
  vocabularies — the SPEC-045 M3 pattern exists and the plugin's token
  sets drift. Kept in Go only for the mechanical checks the plugin itself
  does not own a parser for: positive-integer concurrency (CDT-573
  grammar, cited) and the positive-integer caps.
- **A separate `with_advisor` boolean plus an `advisor_model` field.**
  Rejected: two fields can disagree (`with_advisor: false` with a model
  set); one field mirrors the surface grammar `--with-advisor[=<model>]`
  exactly.
- **Fetch the tracker item server-side for a passthrough id.** Rejected:
  chiefd would gain a Linear dependency and a network read on the route
  path; the session already fetches the item like a terminal run (M8).

## Validation

Proof plan — each row names the test that lands the AC's evidence
(`control-plane/test.sh` runs the whole Go lane; the record below is filled
with landed proof as the work merges):

- AC1/AC4-refusals/M4: `control-plane/chief/chief_test.go` — the pinned
  composition, the byte-exact no-options regression, and the HTTP 400
  refusal of the new fields on `defect`/`idea`/`epic`
- AC2: `control-plane/chief/seams_test.go` — the parser seams exec the
  plugin scripts as argv; the typed refusals land before any journal row
- AC3/AC8: `control-plane/hostadapter/adapter_test.go` and
  `control-plane/chief/takeover_test.go` — the two-name allowlist channel,
  the per-run env isolation, and the takeover re-spawn re-injection
- AC5/AC7/M7: `control-plane/journal/replay_test.go` — the
  `StartPayload` extension replays green, the re-claim consistency check
  stays green, the non-negative check bites (`TestReplayRefusesANegativeCap`
  refuses a negative cap; `TestReplayTreatsAZeroCapAsUnset` reads a present
  `0` as unset)
- AC4/AC6: `control-plane/cmd/chiefd/web_test.go` — the Advanced section,
  the composed-command preview, and the journal-derived detail read

## Version History

| Date | Change |
|------|--------|
| 2026-11-27 | SPEC-046 created (CDT-677): ticket-route run options — the six option fields with pinned composition, plugin-parser validation seams, the per-run cap environment channel, journaled caps on `run_started`, tracker-id passthrough, the Advanced UI section, and retry/resume/takeover fidelity. |
| 2026-11-27 | CDT-677 Step-9 rework: **M8** records the explicit amendment of SPEC-045 M1 — its "the item file MUST exist" rule and unknown-id refusal now apply only to an id that fails the run-id grammar; a grammar-valid id with no local item passes through. Dated row added to SPEC-045's Version History (SPEC-045 M9 discipline). |
| 2026-11-27 | CDT-677 Step-10b alignment: **M7** wording matched to the design and the pinned journal contract — replay validates the caps non-negative when present, a present `0` means unset, and a negative cap refuses as `ErrReplayInconsistent`. The route-time rule of M3 (integer of at least 1) is unchanged. Test entry names the two replay tests; `TestReplayRefusesANonPositiveCap` renamed to `TestReplayRefusesANegativeCap`. |
