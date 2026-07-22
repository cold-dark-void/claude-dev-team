# SPEC-027: /incident — DevOps-Led War-Room & Postmortem

**Status**: DEPRECATED
**Category**: core
**Created**: 2026-07-03

---

## Overview

`/incident <description>` opens a devops-led **war-room mode** for production incidents — the coordination layer the roster previously lacked. `/debug` (SPEC-014) is a single-bug root-cause loop; a production incident is a different shape: multi-thread response (what changed? what's the evidence? who's affected?) plus durable artifacts plus stakeholder communication, all under time pressure when the user has the least attention to spare. The flow: user-confirmed **severity triage** → **parallel read-only investigation threads** (change correlation via git + CI, symptom evidence, blast radius) with **devops as incident commander** → a live **append-only timeline** (canonical `timeline.jsonl`, rendered `timeline.md`) at `.claude/incidents/<id>/` (timestamped entries typed `observation` / `action` / `decision`) → **rollback-first mitigation proposals** where every state-changing action requires explicit per-action user confirmation → **status-update drafts** for stakeholder comms. Post-incident, `/incident postmortem <id>` generates a postmortem (timeline, root-cause chain, 5-whys, action items) and converts action items into backlog entries. Everything works with zero external services.

**Boundaries & related specs:**
- **SPEC-014 (`/debug`)** owns the phase-gated investigation → root-cause → failing-test → fix → verify loop, including the root-cause-before-edit and self-calibration gates. `/incident` MAY invoke `/debug` as a sub-flow for the code-level root-cause thread and coordinates *around* it; this spec MUST NOT reimplement or relax any of `/debug`'s gates — inside the sub-flow they remain fully in force. `/incident` adds only what `/debug` lacks: severity, parallel threads, timeline, comms, postmortem.
- **SPEC-003 (agent role system)** owns the 7-agent roster, model tiers, and role boundaries. This spec adds **no new agent** and changes **no model tier**: incident commander is a *posture* of the existing `devops` agent (Sonnet), and `qa` validates mitigation before an incident may be declared mitigated — consistent with SPEC-003's "DevOps coordinates with QA for post-deployment smoke tests." This spec MUST NOT redefine role boundaries or duplicate SPEC-003's directive/memory contracts.
- **SPEC-009 (ticket workflow / backlog)** owns backlog storage (`.claude/backlog.md` index + `.claude/backlog/<slug>.md` items), slug generation, and the `/backlog add` auto-init behavior. Postmortem action items convert into backlog entries **via the SPEC-009 `/backlog add` flow**; this spec MUST NOT reimplement backlog file formats or the index.
- **SPEC-013 (`/council`)** owns adversarial claim verification. A "mitigated" claim MAY be handed to `/council` for verification (SHOULD, below); this spec MUST NOT build its own verification tribunal.
- **SPEC-018 (`/handoff`)** owns cross-session *session* reconstruction. `/incident resume <id>` reconstructs *incident* state solely from the incident directory — a disjoint artifact namespace (`.claude/incidents/`, never `.claude/handoff/` or `memory.db`) — and does not parse transcripts.

**Out of scope:** paging/alerting/on-call integrations (PagerDuty, Opsgenie, Slack, email — comms are text drafts the user pastes wherever they page), monitoring/metrics ingestion, SLO/error-budget tracking, automated execution of any mitigation, multi-user real-time collaboration, and remote/cloud agent execution.

---

## MUST

- **M1 — Severity triage, user-confirmed.** `/incident <description>` MUST open with a severity proposal — SEV1 (user-facing outage / data loss), SEV2 (degraded or partial impact), SEV3 (minor / no current user impact) — with a one-paragraph rationale grounded in the description and a quick blast-radius probe. The user MUST confirm or override the severity before any investigation thread spawns; the confirmed severity is recorded as a `decision` timeline entry. Bare `/incident` prompts for a description first. Severity labels are fixed SEV1–3 (not user-configurable in v1).
- **M2 — Durable incident workspace.** Each incident MUST get a directory `.claude/incidents/<id>/` (id = `<YYYY-MM-DD>-<slug>`, collision-suffixed `-2`, `-3`, …) under the worktree-aware project root (`$MROOT` formula per AGENTS.md), holding all artifacts: `meta.json`, `timeline.jsonl`, `timeline.md`, `comms/`, and (after postmortem) `postmortem.md`. State MUST survive session death: `/incident resume <id>` MUST reconstruct war-room state (severity, open threads, last decisions, pending proposals) **solely** from the incident directory — no live-session memory, transcript parsing, or `memory.db` reads required.
- **M3 — Append-only typed timeline (jsonl-canonical).** The canonical store is `timeline.jsonl` (one JSON object per line). Each entry carries an id (`eNNN`), an ISO-8601 timestamp, an actor (agent role or `user`), and a type ∈ {`observation`, `action`, `decision`}, plus `summary` and optional `detail` / `refs`. `timeline.md` MUST be a full re-render from jsonl after each append (never hand-edited). Existing jsonl lines MUST NEVER be edited or deleted — corrections are new entries referencing the corrected one. At minimum, the following MUST be logged: severity confirmation/changes, each thread's findings, every mitigation proposal, every user confirmation or decline, every executed action, and resolution. The only writer path is `skills/incident/timeline.sh append`.
- **M4 — DevOps commands, QA validates.** The `devops` agent MUST act as incident commander: it owns triage framing, thread dispatch, timeline curation, and mitigation sequencing. The roster and model tiers are unchanged (SPEC-003); commander is a posture shipped in `agents/devops.md`, not a new agent and not a seeded directive. An incident MUST NOT transition to `mitigated` until a QA-validation entry (test/smoke-check result or explicit user attestation) is appended to the timeline.
- **M5 — Parallel read-only investigation threads.** After severity confirmation, the commander MUST dispatch investigation threads in parallel (one tool-use block), covering at minimum: (a) **change correlation** — recent deploys/merges/config changes via `git log`/`git diff` plus CI status; (b) **symptom evidence** — logs, stack traces, and error output the user points at; (c) **blast radius** — affected surfaces/consumers, feeding severity revision. Investigation threads MUST be read-only (no file mutation); findings land as `observation` timeline entries with drill-down pointers (commit hash, file:line, log path).
- **M6 — Root-cause thread delegates to /debug.** When a code-level root cause is suspected, the deep-dive MUST be delegated to `/debug` (SPEC-014) as a sub-flow — never a reimplementation of its loop. All `/debug` gates (root-cause-before-edit, failing-test-first, self-calibration) remain in force inside the sub-flow; the commander MAY defer the fix phase until after mitigation (mitigation-first ordering), in which case the deferred fix becomes a postmortem action item (M9).
- **M7 — Rollback-first, propose-only mitigation.** Mitigation proposals MUST be ordered rollback-first: reverting the correlated change (deploy, commit, config) is proposed before any forward-fix. Every proposal MUST name the exact command(s)/change, expected effect, and risk. Execution requires explicit per-action user confirmation; a declined proposal is logged as a `decision` entry and nothing runs.
- **M8 — Stakeholder comms drafts.** On severity confirmation and on each material state change (mitigation proposed/executed/validated, severity change, resolution), the commander MUST draft a status update to `.claude/incidents/<id>/comms/<seq>-<slug>.md` — plain text carrying severity, current impact, what is known, current status, and next-update expectation — for the user to paste into their own channels. The command MUST NOT transmit these drafts anywhere.
- **M9 — Postmortem generation.** `/incident postmortem <id>` (also offered at resolution) MUST generate `postmortem.md` containing: incident summary (severity, duration, impact), the assembled timeline, the root-cause chain, a 5-whys analysis, what-went-well / what-went-poorly, and numbered action items each with a suggested owner role. The postmortem MUST be built from the incident-directory artifacts (M2/M3), not live-session memory, so it works cold in a fresh session.
- **M10 — Action items → backlog.** Each postmortem action item MUST be offered for conversion into a backlog entry via the SPEC-009 `/backlog add` flow (index + item format owned by SPEC-009, not reimplemented). User-accepted items MUST be created and their slugs back-referenced next to the corresponding action item in `postmortem.md`.
- **M11 — Zero external services, graceful degradation.** The full flow MUST work with only git and the local filesystem. Optional local tooling (e.g. `gh` for CI status in the change-correlation thread) MUST be detected and, when absent or unauthenticated, skipped with a one-line note — never an error, never a degraded timeline/postmortem.
- **M12 — MUST NOT (hard boundaries).** `/incident` MUST NOT execute any state-changing action (deploy, revert, restart, config change, file edit outside `.claude/incidents/<id>/`) without explicit per-action user confirmation; MUST NOT call external paging/alerting/monitoring services; MUST NOT edit or delete existing timeline entries; MUST NOT reimplement `/debug`'s root-cause loop or SPEC-009's backlog storage; MUST NOT write incident state into `memory.db` or `.claude/handoff/`.

---

## SHOULD

- SHOULD default a next-update cadence per severity in comms drafts (SEV1 ≈ 30 min, SEV2 ≈ 2 h, SEV3 ≈ daily), user-overridable.
- SHOULD offer `/council` (SPEC-013) verification of the "mitigated" claim for SEV1 incidents before resolution is declared.
- SHOULD suggest switching to `/incident` when a `/debug` invocation reads like a production incident (multiple services, live user impact) — a suggestion only; `/debug` behavior is unchanged.
- SHOULD append a one-line learnings summary to devops agent memory at incident close via the standard memory-store protocol (storage contract owned by SPEC-004).

---

## Test

1. **Triage gate (M1):** invoke `/incident "checkout 500s spiking"` → a severity proposal with rationale appears; assert no investigation thread spawns before the user confirms; override to SEV2 → the `decision` entry records SEV2.
2. **Durable workspace + resume (M2):** start an incident, kill the session; in a fresh session run `/incident resume <id>` → war-room state (severity, threads, pending proposal) is reconstructed solely from `.claude/incidents/<id>/`.
3. **Append-only timeline (M3):** after a full run, assert every entry has timestamp + actor + type ∈ {observation, action, decision}; issue a correction → a new entry is appended and the prior entry is byte-identical. `bash skills/incident/timeline-test.sh` exercises append/render/validate/collision.
4. **Commander & QA gate (M4):** assert devops-role output leads coordination; attempt to declare `mitigated` with no QA-validation entry → refused until one is appended.
5. **Parallel read-only threads (M5):** threads (change correlation / evidence / blast radius) are dispatched in one tool-use block; `git status` is clean after investigation (no mutation); findings appear as `observation` entries with resolvable pointers.
6. **`/debug` delegation (M6):** a code-level root-cause thread produces `/debug`'s own root-cause statement and gates in the session output (delegation, not reimplementation); with mitigation-first chosen, the deferred fix appears as a postmortem action item.
7. **Rollback-first + confirmation (M7, M12):** the mitigation list proposes a revert before any forward-fix; a state-changing proposal awaits explicit confirmation; decline it → a `decision` entry is logged and nothing executed (working tree unchanged).
8. **Comms drafts (M8):** severity confirmation and a mitigation execution each produce sequential drafts under `comms/`; assert no network/send operation occurred.
9. **Cold postmortem (M9):** in a fresh session, `/incident postmortem <id>` produces `postmortem.md` with all required sections (summary, timeline, root-cause chain, 5-whys, well/poorly, action items) built only from the incident directory.
10. **Backlog conversion (M10):** accept two action items → `.claude/backlog/<slug>.md` files and index rows exist per SPEC-009's format, and `postmortem.md` back-references the slugs.
11. **Degradation (M11):** with `gh` absent from PATH, the change-correlation thread skips CI status with a one-line note; the run otherwise completes normally.
12. **Boundary sweep (M12):** across a full simulated incident, assert zero unconfirmed state-changing commands, zero external service calls, zero writes to `memory.db` or `.claude/handoff/`, and zero edits to prior timeline entries.

---

## Validation

- [ ] Spec reviewed and promoted to ACTIVE
- [ ] Severity triage gate holds: no investigation threads before user confirmation
- [ ] Timeline verified append-only across a full incident (corrections are new entries)
- [ ] Root-cause thread delegates to `/debug`; no gate of SPEC-014 is relaxed or duplicated
- [ ] No state-changing action executed without explicit per-action confirmation in a live run
- [ ] `/incident resume <id>` reconstructs state from the incident directory in a fresh session
- [ ] Postmortem generated cold from artifacts only, with all required sections
- [ ] Action items land in the backlog via the SPEC-009 flow (no format reimplementation)
- [ ] Full flow completes with zero external services (`gh` absent)
- [ ] `bash skills/incident/timeline-test.sh` passes

---

## Resolved (MVP)

| OQ | Decision | Rationale |
|----|----------|-----------|
| OQ1 — Severity scale | **Fixed SEV1–3** | Comms templates + cadence defaults need stable labels; configurable labels deferred |
| OQ2 — Commander posture | **`agents/devops.md` edit** | Plugin ships global posture; directives are local/uncommitted and miss install consumers |
| OQ3 — Timeline store | **`timeline.jsonl` canonical; `timeline.md` render** | Resume/parse reliability; helper always appends jsonl then re-renders md |
| OQ4 — Retention/archival | **None v1** | Small text artifacts; leave forever; no rotate/delete job |
| OQ5 — `/orchestrate` from AI slug | **No** | Normal path: backlog → `/kickoff`; avoid dual ticket sources |

---

## Version History

| Date | Change |
|------|--------|
| 2026-07-21 | DEPRECATED — /incident surface excised at v1.0.0 (CDT-46-C2); command/skill replaced by one-cycle Deprecation stubs; engine scripts deleted |
| 2026-07-14 | ACTIVE — ship `/incident` + workspace/timeline CLIs; OQs locked; jsonl-canonical MUST |
| 2026-07-03 | Initial DRAFT — ideation wave 2 |

**Covers:** `commands/incident.md`, `skills/incident/SKILL.md`, `skills/incident/workspace.sh`, `skills/incident/timeline.sh`, `skills/incident/timeline-test.sh`, `agents/devops.md` (incident-commander posture), `docs/commands/incident.md`, `.gitignore` (`.claude/incidents/`), `skills/debug/SKILL.md` (SHOULD cross-suggest), `README.md` (commands table).

## Cross-references

- **SPEC-014 — Debug Workflow:** the root-cause sub-flow `/incident` delegates to; its gates are inherited, never reimplemented.
- **SPEC-003 — Agent Role System:** devops (commander posture) and qa (mitigation validation) roles; roster and model tiers unchanged.
- **SPEC-009 — Ticket Workflow:** `/backlog add` flow and backlog file formats for postmortem action items.
- **SPEC-013 — Adversarial Council Tribunal:** optional verification of the "mitigated" claim (SHOULD).
- **SPEC-018 — Session Handoff:** disjoint artifact namespaces; `/incident resume` is incident-state, not session, reconstruction.
- **SPEC-004 — Persistent Memory:** optional one-line devops learnings at close only; never incident state.
