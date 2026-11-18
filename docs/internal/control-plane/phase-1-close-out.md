# Close-out — control plane phase 1 implementation (CDT-628)

Carries the CDT-651 close-out for control plane Option C+ (CDT-626). Phase 1 (CDT-628) closes the
way phase 0 did: as a written record of what its ten children built, what stays blocked, and what
the next phase inherits. The shape follows [close-out.md](close-out.md) — the phase-0 close-out —
and its external-copy rule governs amendments (§ Amendments and the external copy). This file
decides nothing new: every row cites the child's own record.

## Decision register

| Field | Value |
|---|---|
| **Decision** | Phase 1 of control plane Option C+ (CDT-626) is closed as an implementation record: the ten children C1–C10 of CDT-628 (§ Deliverable set) each carry implementation documentation at the path [index.md](index.md) pins, with one owner and its blocked items named. The phase-0 AC10 ruling holds as built (§ The AC10 ruling as built); the SPEC-010 arc stays open (§ The SPEC-010 arc). |
| **Status** | Closed for phase 1 (2026-11-18). Shipped as `v2.0.0-pre.3` … `v2.0.0-pre.12` — one fold per child — on the SPEC-010 arc; no `2.0.0` cut; `stable` stays at the last 1.x final release. |
| **Date** | 2026-11-18 |
| **Sources** | The child sections of [index.md](index.md) and their AC lists under § Acceptance criteria; [record-ownership.md](record-ownership.md) rows 12, 14, 15 and the row-4/row-13 mechanics; [ADR 0001](../../adr/0001-journal-engine.md) § Decision and § Rejected; `control-plane/README.md` (the C1 boundary statement); the appended child sections of `container-runner.md`, `native-runner.md`, and `credentials.md`; [close-out.md](close-out.md) (the phase-0 record and the external-copy rule); SPEC-010 § "Pre-release arc scheme". |
| **Phase effect** | Phase 2 (CDT-629) inherits the inputs of § Inputs handed forward. Phases 3–4 (CDT-630, CDT-631) inherit their carried blocked items unchanged from phase 0. |
| **Residual items** | B8 (linger, pending-operator), B6 (forced token-refresh, blocked on a sandbox credential), the row-5 memory-owner re-test (CDT-629), the Grok ACP session-id capture gap (C9), the CDT-603 write-time validation (C5) — § Inputs handed forward. |

## Deliverable set — the ten CDT-628 children

One row per child. The implementation doc is the doc `index.md` pins (or, where a deliverable's
record lives inside `index.md`, the section that carries it); the owner is the record-ownership
row where the child created or amended one, and the child's own no-record fact otherwise; the
blocked items are the ones the child's AC list and its doc name.

| # | Deliverable | Child | Implementation doc | Owner | Blocked items |
|---|---|---|---|---|---|
| 1 | The service carve-out — the isolated top-level service directory | C1 (CDT-645) | [`control-plane/README.md`](../../../control-plane/README.md) — the boundary and ownership statement; `control-plane/VERSION` | No state record. The boundary record is single-homed in ADR 0001 (C1 AC3); the directory is not a plugin Surface (C1 AC11). | None. The C1 `image-reference` placeholder was superseded by C8's G-02 presentation record (`container-runner.md` § "The session image — named and digest-pinned"). |
| 2 | The run journal, the state machine, and the CI kill test | C2 (CDT-643) | [index.md](index.md) § "CDT-643 — Run journal, state machine, CI kill test" | Row 12 — the run journal (`record-ownership.md:76`): `control-plane-only`, `single-writer-lease`. | The stall-limit knob reads `blocked: CDT-610` (CDT-643 AC9). K2 — the forced-reboot test — stays the epic-level acceptance line until the B8 linger step runs (CDT-643 AC7). |
| 3 | The lifecycle graph and the phase-event contract | C3 (CDT-642) | [lifecycle-graph.json](lifecycle-graph.json) — one committed file; the loader `control-plane/lifecycle/`, the spool `control-plane/spool/` | No ownership row. The graph is committed delivery; the phase-event spool is service state under the git-ignored `.claude/runs/` tree (CDT-642 AC3). | None. |
| 4 | The node agent — the four-verb contract and the native runner | C4 (CDT-644) | [index.md](index.md) § "CDT-644 — Node agent"; `native-runner.md` § CDT-644; `node-agent-build-probe.md` § "The C4 build" | Row 14 — the node agent's per-node runner selection (`record-ownership.md:78`): `control-plane-only`; one reader, `agent.Load`. | Two operator steps are pending-operator: B8 linger and the reboot acceptance test (`native-runner.md` § "Operator step B8 — linger (pending-operator)", § "Operator step — reboot acceptance test"). The B6 conservative credential rule carries over (`native-runner.md` § CDT-644). |
| 5 | The run queue — the slot ledger and the SPEC-033 amendment | C5 (CDT-649) | [index.md](index.md) § "CDT-649 — Run queue"; the landed amendment: `run-budget.md` § Amendment and `specs/core/SPEC-033-autopilot-policy.md` § Version History | No new record — the slot ledger journals grant, wait, and release through the C2 machine; row 12 stays the run-state record. | CDT-603 stays open and owns the match key's write-time validation (CDT-649 AC4 (v)). |
| 6 | The host adapter — start, resume, steer, observe | C6 (CDT-648) | [index.md](index.md) § "CDT-648 — Host adapter"; `credentials.md` § "Gap 2 — resolved: the omp provider env-var names (B7)" | No new record — service code over the node agent's four verbs; it reads row 14 through `agent.Load`. | None blocked. B7 closed on-box with a recorded deviation: the probe ran on the node's omp 18.22.0; the matrix-locked 18.7.0 rows stand as dated evidence (CDT-648 AC4, AC5). |
| 7 | The tracker inversion — the local backlog store as the source of truth | C7 (CDT-646) | [record-ownership.md](record-ownership.md) row 4 mechanics and row 13; `skills/backlog/ticket.sh` (the C7 verb CLI) | Rows 4 and 13 — `plugin` / `single-writer-lease` and `plugin` / `plugin-only` (`record-ownership.md:68`, `:77`). | None blocked. Residuals of record: row 11's registry enumeration is unprobed for omp and mini-swe, and a control-plane writer for the ticket store, if CDT-629+ ever adds one, re-opens row 4 (record-ownership.md § Residual items). |
| 8 | The container runner — one container per run | C8 (CDT-647) | [`container-runner.md`](container-runner.md) § "CDT-647 — the container runner is real" | Row 14's mechanics — the `container` token of the C4 closed set (`agent.KnownRunners`); row 14 stays the node-selection record. | B6 — the forced token-refresh probe stays a named blocker: a sandbox credential is needed, so the conservative writable-mount rule stands (`container-runner.md` Fact 2; CDT-647 AC4). |
| 9 | The Chief — the single point of contact | C9 (CDT-650) | [index.md](index.md) § "CDT-650 — The Chief"; `control-plane/chief/doc.go` | Row 15 — the Chief's page record (`record-ownership.md:79`): `control-plane-only`, `append-only-merge`. | The Grok steer capture gap: over the ACP transport the session id arrives in frames the headless-json parser does not match, so a live Grok steer needs an ACP-aware capture wired before it can name the session (`control-plane/hostadapter/launch.go`, review N3). |
| 10 | The web UI — one screen over the one API | C10 (CDT-652) | [index.md](index.md) § "CDT-652 — The web UI" | No record — static files embedded in the chiefd binary; delivery, not state (record-ownership.md, CDT-650's following paragraph). | None. Remote access is CDT-630's phase-3 scope by design (CDT-652 AC6). |

## The AC10 ruling as built

The phase-0 ruling (CDT-632 AC10, [ADR 0001](../../adr/0001-journal-engine.md)): **the journal
engine is SQLite behind a narrow interface** — the control plane talks to the plugin through files
and CLI calls only.

As built (phase 1):

- The engine is the `modernc.org/sqlite` v1.62.0 embedded driver inside the service's one Go
  module (`control-plane/go.mod:5`) — the ADR's own consequence: "SQLite needs an embedded driver
  in that same binary, not a partner service."
- Every write and read passes through the narrow surface of `control-plane/journal` (`engine.go`
  `Doer`): values bind as `?` parameters, the INSERT-only statement guard and the
  `events_no_update` / `events_no_delete` triggers hold the append-only discipline, and the DDL
  home is one file, `control-plane/journal/schema.sql`.
- The plugin never opens the database: it calls `control-plane/cmd/journalctl` — the two CLI
  commands — and never holds SQL of its own (ADR 0001 § "The narrow-interface boundary"; C1 AC3
  single-homes the rule there).

The rejected option and its reason stand as recorded: the durable-execution engine (Temporal, R1;
Restate, R2) is REJECTED-WITH-MECHANISM in ADR 0001 § Rejected. R1 carries five independent
mechanisms — it inverts the boundary (the caller becomes the engine through a worker SDK), forks
the source of truth that lives in `skills/` + SPEC-033, costs 3–5 new container images and a
stateful store, wants a network posture phase 0 does not have, and lands a journal payload that is
readable at rest by default. R2's concession — the cheapest and strongest engine here, fsync
before acknowledge — is recorded rather than hidden, and its two mechanisms stand: the same
boundary inversion, and a Kubernetes-operator deployment shape that does not fit three
maintainer-owned machines. Phase 1 paid the decision's named cost: it wrote the crash-recovery
code — the intent-then-outcome effects, the lease with the fencing token, and the reconciler-on-
start (CDT-643 AC3–AC5) — and the CI kill test (CDT-643 AC7) is the gate that falsifies ADR 0001
cost 1.

## Inputs handed forward

### The four CDT-627 residual phase-1 inputs

Carried from [close-out.md](close-out.md) § "CDT-627 residual phase-1 inputs", with their
phase-1 status.

| # | Input | Status at phase-1 close-out | Owner — where the record lives |
|---|---|---|---|
| 1 | B8 — `loginctl enable-linger` on the node | Pending-operator. A machine change, out of every ticket's footprint: the CDT-626 reboot contract is proven in code (`go test ./agent/` — the takeover and pending-spawn recovery tests), and the acceptance line "after a forced reboot, every in-flight run continues without a human" holds once the step and the reboot test run. | C4: `native-runner.md` § "Operator step B8 — linger (pending-operator)" and the reboot acceptance test next to it. |
| 2 | B7 — the omp provider env-var-name probe | Resolved on-box (2026-11-17, C6). The adapter's proven-name table carries the five proven names plus the negative result (llama.cpp reads no env var), and injection of anything unproven refuses with `ErrCredentialNameUnproven` before any journal row is written. Deviation recorded: the probe ran on omp 18.22.0 — the matrix-locked 18.7.0 binary was replaced. | C6: `credentials.md` § "Gap 2 — resolved: the omp provider env-var names (B7)"; CDT-648 AC5. |
| 3 | B6 — the forced token-refresh probe (Claude Code, Grok) | Still blocked — it needs a sandbox credential first: a forced refresh rotates the operator's live subscription credential. The conservative writable-mount rule stands in the container runner's credential mounts. | C8: `container-runner.md` Fact 2; CDT-647 AC4. Feeds CDT-631 (phase 4), as phase 0 ruled. |
| 4 | The Slot open question — one slot per runner, or per model endpoint | Closed by ruling in phase 1 — status line only, per the CDT-651 ticket; the ruling lives in C5. One slot is one runner; the per-model-endpoint limit is a separate cap the queue reads from the Model map, with both caps enforced independently and overflow waiting and showing as waiting. The CONTEXT.md Slot term is amended there. | C5: CDT-649 AC1, AC2, AC5; `CONTEXT.md` § Terms (the Slot row). |

### The CDT-629 inputs

- **The row-5 memory-owner re-test.** Owning AC: CDT-643 AC8 carried it — "the row-5 memory-owner
  re-test is carried here: it re-runs when CDT-629 lands, against the API front, not the store."
  [record-ownership.md](record-ownership.md) § Residual items carries the same open item, and row
  5 stays `plugin` / `single-writer-lease` until the re-test runs. No re-test happens in this
  child.
- The rest of what CDT-629 must carry stays single-homed in
  [close-out.md](close-out.md) § "Decisions that unblock" (the CDT-629 row) — the node-agent CLI
  path and flag names, the `.gitignore` line for `config.json` (closed by C7), the SPEC-004
  no-trim-while-degraded amendment, the conflicts-queue path and its writer, and the Chief's
  recall scope across projects.

## Amendments and the external copy

- **This child amends no decision.** The phase-1 records extend, never rewrite, the phase-0
  decision set: ADR 0001, the five decision records, and [close-out.md](close-out.md) are
  unchanged since `v2.0.0-pre.2` — the AC10 ruling is restated as built above, not amended.
- The external-copy rule of [close-out.md](close-out.md) § External copy record therefore adds no
  dated line here. The rule fires when a ticket amends a decision recorded in the mirror; the one
  decision-state change of phase 1 — the Slot open question, closed — was made and recorded by its
  owning child C5 (CDT-649 AC5), not by this close-out.
- Standing rule for any later amendment, restated as pointer, not as fork: re-copy the changed
  section into the Linear mirror, append one dated line to the table in
  [close-out.md](close-out.md) § External copy record, never edit an existing row, and never place
  a secret, token, or credential value in the mirror.

## The SPEC-010 arc

- Phase 1 shipped on the arc: `v2.0.0-pre.3` (C1) through `v2.0.0-pre.12` (C10) — one fold per
  child, per SPEC-033.
- No `2.0.0` cut. The Control plane arc is open, so the final cut stays reserved for the arc's
  end; `stable` stays at the last 1.x final release (`v1.28.20`, commit `5edb490`) and the arc
  pre-releases ride `master` (the `dev-team-edge` channel). Source of truth: SPEC-010
  § "Pre-release arc scheme" P1 — cited here, never restated as policy.

## Verification

```bash
cd docs/internal/control-plane
sed -n '/^## Deliverable set/,/^## The AC10 ruling/p' phase-1-close-out.md \
  | grep -c '^| [0-9]* |'                                            # 10 — one row per child
sed -n '/^### The four CDT-627/,/^### The CDT-629 inputs/p' phase-1-close-out.md \
  | grep -c '^| [0-9]* |'                                            # 4 — the carried inputs
grep -n 'modernc.org/sqlite' ../../../control-plane/go.mod            # the as-built engine
grep -c 'REJECTED-WITH-MECHANISM' ../../adr/0001-journal-engine.md   # >= 2 — R1 and R2
grep -n 'Operator step B8 — linger (pending-operator)' native-runner.md    # B8 owner
grep -n 'Gap 2 — resolved: the omp provider env-var names (B7)' credentials.md   # B7 owner
grep -n 'one slot is one runner' ../../../CONTEXT.md                  # the C5 Slot ruling
grep -n 'CDT-643 AC8' phase-1-close-out.md                            # the row-5 re-test's owning AC
git log --oneline -- close-out.md | head -1                          # 9ca2c92 — close-out.md unchanged since v2.0.0-pre.2
git tag --list 'v2.0.0-pre*' | wc -l                                  # 12 arc tags, pre.1 … pre.12
git tag --list 'v2.0.0'                                               # empty — no final cut
git rev-parse stable                                                  # 5edb490… = v1.28.20, the last 1.x final
```

Expected: ten deliverable rows and four carried-input rows; the as-built engine and the rejected
option cited; the B8/B7/Slot/row-5 pointers resolve to the records named; `close-out.md` carries
no phase-1 commit; twelve arc tags, no `v2.0.0` tag, and `stable` at the `v1.28.20` commit.
