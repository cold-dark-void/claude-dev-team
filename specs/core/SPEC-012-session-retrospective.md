# SPEC-012: Session Retrospective

**Status**: APPROVED
**Category**: core
**Created**: 2026-04-07

**Covers**: `commands/retro.md`, `skills/retro-gate/`, `skills/retro-subagent/`, `skills/transcript-parse/`, live friction ledger hook `.claude/hooks/friction-capture.sh` (emitted by `skills/init-orchestration/`), integration hooks in `skills/kickoff/SKILL.md` and `skills/orchestrate/SKILL.md`

---

## Overview

`/retro` reviews past Claude sessions to find friction patterns ("frustrating
sessions") and proposes concrete behavioral adjustments targeted at the
correct actor — either a team agent (pm, tech-lead, ic5, ic4, devops, qa, ds)
via the existing `/adjust-agent` flow, or plain Claude itself via
project-local lessons at `$MROOT/.claude/memory/claude/lessons.md`.

Design is two-phase to avoid wasting tokens on smooth sessions:
1. **Phase 1 — Gate**: cheap heuristic grep of session JSONL(s) for friction
   signals. Sessions scoring below threshold exit immediately with "nothing
   to retro."
2. **Phase 2 — Deep-read**: for each flagged session, a subagent reads the
   JSONL anchored at the specific friction turns and proposes fixes with
   cited evidence (message IDs).

Proposals go through a confirm/reject/edit UI (or `--auto` to apply all).
Duplicate detection reads existing directives/lessons first and flags rules
that already cover the pattern — preferring to **tighten existing rules**
over appending new ones, to prevent directive sprawl.

`/retro` does NOT write team-agent directives directly; all team-agent
proposals route through `/adjust-agent <agent>` to preserve SPEC-001's
conflict-detection and holistic-rewrite guarantees.

---

## MUST

### Command Shape
- MUST support `/retro` (default: last session in current project)
- MUST support `/retro <session-id>` (specific session)
- MUST support `/retro --all` (all projects under `~/.claude/projects/`, cross-session pattern mining)
- MUST support `/retro --auto` (skip confirm UI, apply all proposals)
- MUST support `/retro --why` (print which phase-1 gate signals matched, for heuristic calibration)
- MUST exit in under 5 seconds on smooth sessions (gate-only path, no subagent spawn)

### Session Discovery
- Transcript location, canonical-file selection, fork-tree assembly, parse primitives, and the in-progress freshness guard are owned by the shared read-only parsing seam `skills/transcript-parse/` (`assemble.py` locate/assemble, `parselib.py` parse primitives, `freshness.sh` 60 s mid-write guard, plus `SKILL.md`). `/retro` and `/handoff` (SPEC-018) MUST both consume this single module — neither MUST re-implement transcript parsing privately. `/retro` owns only its own friction scoring on top of the shared primitives.
- MUST read session JSONL files from `~/.claude/projects/<encoded-project-path>/` for current-project mode
- MUST default to the most recently modified `.jsonl` file when no `<session-id>` given
- MUST NOT read in-progress JSONL files (skip files modified within the last 60 seconds)
- MUST NOT read sessions from other users or shared directories outside `~/.claude/projects/`
- MUST skip sessions where `/retro` was itself invoked (prevent retro-of-retros loops)

### Phase 1 — Friction Gate (heuristic)
- MUST compute a friction score for each candidate session using signals including (but not limited to):
  - User messages containing: `revert`, `stop`, `no that's wrong`, `why did you`, `don't`, `wrong`
  - Consecutive tool errors on the same file or command
  - Repeated edit-tool uses (`Write` / `Edit` / `MultiEdit` / `NotebookEdit`) on the same path within a short window (≥ 3 uses in ≤ 10 assistant turns), **except** a clean draft-polish path: a path whose first edit-tool in the session is `Write` (session-created) and that has no intervening tool error (`tool_result.is_error: true`) and no intervening S1-eligible real user rejection after that creating `Write` and at or before the last edit-tool in the candidate window. Clean draft-polish paths MUST NOT contribute to the S3 (edit-loop) score. Pre-existing paths (first edit-tool is not `Write`) and session-created paths with intervening tool error or S1 rejection remain eligible for S3
  - "let me try again" / retry-loop patterns from the assistant
  - Terse user replies (≤ 3 words) immediately following long assistant turns (> 500 chars)
- MUST exit with "smooth, nothing to retro" when score is below threshold — MUST NOT spawn a subagent
- MUST NOT invent findings when the gate rejects a session (no phase-2 fallback on rejection)
- MUST print matched signals when `--why` flag is set

### Phase 2 — Deep Read (subagent)
- MUST spawn one subagent per flagged session (parallel when `--all` flags multiple)
- MUST pass the JSONL path and a list of friction-turn message IDs as anchors to the subagent
- MUST require the subagent to cite evidence (message ID + 1-line excerpt) for every proposed finding
- MUST reject proposals from the subagent that lack citations
- MUST require `--all` mode to collapse findings that occurred only once across all sessions — only surface repeat patterns (≥ 2 occurrences) when `--all` is set
- MUST classify findings that indicate fabricated or unverified assistant claims with a `fabrication_anchor` marker containing: the turn ID, the fabricated claim text, and a stable anchor-id (for downstream `/council --from-retro` integration per SPEC-013)

### Phase 3 — Routing & Deduplication
- MUST classify each proposal's target as one of:
  - A specific team agent (`pm`, `tech-lead`, `ic5`, `ic4`, `devops`, `qa`, `ds`) — based on evidence from the session
  - `claude` (plain Claude sessions — the default, non-team case)
- MUST NOT classify proposals as targeting `project-init` or `distiller` (consistent with SPEC-001)
- MUST load existing rules before presenting proposals:
  - For team-agent targets: read `.claude/memory/<agent>/directives.md`
  - For `claude` target: read `$MROOT/.claude/memory/claude/lessons.md`
- MUST label each proposal with one action:
  - **NEW** — no existing rule covers the pattern
  - **TIGHTEN** — an existing rule is close but was not enforced in the reviewed session; propose a reworded version
  - **DUPLICATE** — existing rule already covers the pattern; flag as "rule not working, consider removing or rewording"
- MUST NOT auto-append new rules when a TIGHTEN candidate exists for the same pattern (prevents sprawl)

### Phase 4 — Confirm / Apply
- MUST present each proposal with: target, action (NEW/TIGHTEN/DUPLICATE), proposed text, cited evidence
- MUST offer confirm / reject / edit per proposal in default mode
- MUST skip confirm UI and apply all proposals when `--auto` flag is set
- MUST route team-agent proposals through `/adjust-agent <agent>` — MUST NOT write `directives.md` files directly (preserves SPEC-001 conflict detection and holistic rewrite)
- MUST invoke `/adjust-agent <agent> --apply "<text>"` (non-interactive mode, SPEC-001) when `--auto` flag is set
- MUST surface `/adjust-agent --apply` conflict refusals as normal confirm-mode proposals in the `/retro` output (user resolves manually), so `--auto` degrades gracefully on conflict rather than silently dropping the proposal
- MUST append `claude` proposals to `$MROOT/.claude/memory/claude/lessons.md` (create file and parent dir if absent)
- MUST resolve `$MROOT` using the worktree-aware formula: `_gc=$(git rev-parse --git-common-dir 2>/dev/null) && MROOT=$(cd "$(dirname "$_gc")" && pwd) || MROOT=$(pwd)`
- MUST print the directive count for each affected agent after apply, so the user sees the pile growing
- MUST surface non-actionable findings as "observed pattern, no fix proposed" (visibility without action)

### Integration Hooks
- `/kickoff` MUST print `Consider: /retro <session-id>` at completion if the phase-1 gate detected friction in the just-completed session
- `/orchestrate` MUST print `Consider: /retro <session-id>` at completion if the phase-1 gate detected friction in the just-completed session
- These hints MUST be printed as plain suggestions — MUST NOT auto-run `/retro`, MUST NOT block completion, MUST NOT require user action
- `/retro` MUST print `Consider: /council --from-retro <anchor-id>` as a plain suggestion for each detected `fabrication_anchor` at completion (SPEC-013 integration)
- The `/council` hint MUST NOT auto-run `/council`, MUST NOT block completion, MUST NOT require user action (mirrors the `/kickoff` and `/orchestrate` hint contracts above)
- `/retro` MUST surface at most one `/council` hint per distinct anchor-id (dedup within a single run)

### Scope Exclusions
- MUST NOT modify `AGENTS.md`
- MUST NOT modify `~/.claude/CLAUDE.md` or any global user configuration
- MUST NOT modify code files, tests, or specs under any circumstance
- MUST NOT apply any proposal without `--auto` or explicit per-proposal confirm
- MUST NOT install real-time hooks, `Stop` hooks, or session interruption mechanisms as part of `/retro` itself. Live friction ledger hook wiring is owned exclusively by `/init-orchestration` (see "Live friction telemetry ledger" below) — never by `/retro`, `/kickoff`, or `/orchestrate`

### Live friction telemetry ledger (CDV-186)

Capture friction in real time via harness hook events `PostToolUseFailure`,
`PermissionDenied`, and `StopFailure`, so phase-1 can use observed failure
evidence for S2 and still observes permission/stop failures that do not always
surface as transcript `tool_result.is_error` rows. Banked design context:
`.claude/backlog/friction-telemetry-hooks.md`.

- **M1 — Ledger capture.** A single shared handler `.claude/hooks/friction-capture.sh` MUST handle all three events (`PostToolUseFailure`, `PermissionDenied`, `StopFailure`) and MUST append exactly one NDJSON line per accepted event to `$MROOT/.claude/retro/friction.jsonl` (worktree-aware `$MROOT`, same resolution formula as Phase 4). Schema (exact keys):
  ```json
  {"ts":"<ISO-8601>","session_id":"<id>","event":"<PostToolUseFailure|PermissionDenied|StopFailure>","tool":"<name or empty>","path":"<optional path or omit/empty>"}
  ```
  `tool` and `path` MUST be empty (or `path` omitted) when the event carries none. Handler MUST extract fields best-effort from stdin hook JSON (tolerate key variants such as `tool_name` → `tool`, `file_path` → `path`); if `session_id` is missing/empty after extraction, MUST skip the append (still exit 0).
- **M2 — No payload bodies.** Ledger lines MUST NOT contain tool outputs, tool inputs, file contents, environment-variable values, secrets, or free-text error bodies. Only the schema fields in M1. (No `brief_detail` field.)
- **M3 — Bounded growth.** The ledger MUST be bounded by the appending handler: default **10_000 lines** OR **5 MiB**, whichever is hit first; both caps MUST be env-overridable (constants at top of handler, e.g. `FRICTION_LEDGER_MAX_LINES`, `FRICTION_LEDGER_MAX_BYTES`). On cap hit, prune oldest lines (keep newest) before or after append so the file never grows unbounded. Unbounded growth is a defect.
- **M4 — Hybrid scoring (ledger S2 + transcript S1/S3/S4/S5).** `retro-gate` phase 1 MUST:
  1. Resolve the target session's `session_id` (from transcript metadata / path basename / caller).
  2. Consult `$MROOT/.claude/retro/friction.jsonl` when present.
  3. **Covered** = ≥1 well-formed ledger row whose `session_id` matches the target. When covered: derive **S2 only** from ledger events for that session; still parse the transcript for **S1, S3, S4, S5** (and for message-id anchors those signals need).
  4. Ledger → S2 mapping: each of the three event types counts as an error observation. Apply the same consecutive-run rule as transcript S2 (≥2 consecutive errors form one run; score = number of runs × S2 weight). Ledger has no success/user-turn reset markers — events for the session form one append-order sequence (so N≥2 events ⇒ one S2 run unless a future success marker is added). S2 `signals[].ids` MAY use synthetic anchors (`ledger:<event>:<ts>` or line refs) when no transcript message UUID exists.
  5. **Uncovered or ambiguous** (no matching rows; ledger missing/unreadable; `session_id` unresolved; corrupt-only rows for that id) → full transcript path for **all** signals including S2 — identical to pre-CDV-186 behavior. No errors, no warnings on the graceful path.
  6. This extension MUST NOT change scoring semantics for weights, caps, threshold, signal set (S1–S5), or `--why` output shape. MUST NOT retune S3 (CDV-184 draft-polish exemption remains authoritative).
- **M5 — Wiring via `/init-orchestration`; graceful absence.** Hook registration for the three events MUST be emitted by `/init-orchestration` alongside existing hook templates, pointing at the same `friction-capture.sh`, with `${CLAUDE_PROJECT_DIR}`-anchored paths and no pipe operators. Live template MUST stay byte-identical to the fenced block in `skills/init-orchestration/SKILL.md` (`check-hook-templates.sh` MUST include `friction-capture`). `/retro` MUST NOT install hooks. When hooks are unwired, events are unsupported by the installed Claude Code version, or the ledger is absent/empty, the gate MUST behave exactly as today (full transcript parse, no errors, no warnings).
- **M6 — Transcript always available.** Full transcript parsing remains required for S1/S3/S4/S5 on every path, and for S2 whenever the session is not ledger-covered (M4). Sessions predating hook install, other projects in `--all` mode, and foreign sessions MUST work without a ledger.
- **M7 — Handlers fail open; never block.** `friction-capture.sh` MUST be lightweight: no LLM, no network, bounded runtime, exit `0` on every path including failures (one-line diagnostic to stderr). MUST NOT exit `2`. MUST NOT block or delay the observed tool/permission/stop flow. (Mirrors SPEC-018 M17.)

*Adjacency (non-normative):* ledger tool-error evidence may eventually obsolete S3 draft-polish heuristics for hook-covered sessions — **out of scope for CDV-186**; do not change S3 without a separate ticket. CDV-184 fixtures MUST continue to pass.

---

## SHOULD

- SHOULD rank proposals by confidence (citation count, signal strength) when presenting them
- SHOULD cap proposals per retro run at 5 by default to prevent proposal floods
- SHOULD print the friction score alongside matched signals when `--why` is set
- SHOULD group `--all` output by target agent, not by source session, so the user sees "ic5 has 3 repeat patterns" rather than a session-by-session report

---

## Test

- Verify `/retro` on a smooth session exits in < 5s with "nothing to retro" and spawns no subagent
- Verify `/retro` on a session containing `revert` + consecutive tool failures passes the gate
- Verify `/retro --why` prints the specific signals that matched
- Verify phase-2 subagent rejects findings that lack message-ID citations
- Verify `/retro --all` only surfaces patterns with ≥ 2 occurrences across sessions
- Verify a NEW proposal for a team agent routes through `/adjust-agent <agent>` and does not write `directives.md` directly
- Verify a NEW proposal for plain Claude appends to `$MROOT/.claude/memory/claude/lessons.md`
- Verify DUPLICATE detection correctly identifies when an existing directive already covers a pattern
- Verify TIGHTEN action proposes a reworded existing rule instead of a new one
- Verify `--auto` applies all proposals without prompting
- Verify `/retro` refuses to read JSONL files modified within the last 60 seconds
- Verify `/retro` skips sessions where `/retro` was previously invoked
- Verify `/kickoff` and `/orchestrate` print the `Consider: /retro` hint only when the gate flags their session

**Live friction telemetry ledger (CDV-186):**

1. **Ledger capture (M1):** feed each of the three event stdin shapes to `friction-capture.sh` → exactly one NDJSON line per event in `$MROOT/.claude/retro/friction.jsonl` with keys `ts`, `session_id`, `event`, `tool`, and optional `path` only.
2. **No bodies (M2):** feed a failure payload containing a multi-KB canary → ledger line has no canary and no payload/body fields.
3. **Bounded growth (M3):** append past 10k lines or 5 MiB (or lowered env caps in test) → rotation keeps newest; file stays within bound.
4. **Hybrid S2 (M4):** session with ≥1 ledger row and ≥2 failure events → S2 from ledger; S1/S3/S4/S5 still require transcript evidence. Forced full-transcript S2 path on same session without ledger coverage still scores S2 from transcript. Weights/caps/threshold/`--why` shape unchanged.
5. **Wiring + graceful absence (M5):** `/init-orchestration` registers all three events to `friction-capture.sh`; `check-hook-templates.sh` includes it; with no ledger, `gate.sh` matches pre-CDV-186 transcript behavior (no errors/warnings).
6. **Fallback (M6):** session absent from ledger → full transcript S2; unresolved `session_id` → full transcript path.
7. **Fail-open (M7):** unwritable ledger dir → handler exits 0 (never 2), one-line stderr diagnostic.
8. **CDV-184 regression:** existing S3 draft-polish fixtures (`ac1`–`ac5`) still pass; no S3 weight/exemption changes.

---

## Validation

- [ ] `commands/retro.md` exists with valid YAML frontmatter (`name`, `description`)
- [ ] `/retro` on the latest smooth session exits in < 5s with no subagent spawned
- [ ] `/retro` on a deliberately frustrating test session produces ≥ 1 cited proposal
- [ ] Team-agent proposals go through `/adjust-agent <agent>` (verified by conflict-detection output from SPEC-001 flow)
- [ ] Claude proposals append to `$MROOT/.claude/memory/claude/lessons.md` (file exists after run)
- [ ] `/retro --all` reports only repeat patterns (manually verified across ≥ 2 sessions)
- [ ] `/retro --why` prints matched friction signals
- [ ] `/retro --auto` applies proposals without prompting
- [ ] `/kickoff` and `/orchestrate` print the `Consider: /retro` hint after a frustrating test run
- [ ] No modifications to `AGENTS.md`, `~/.claude/CLAUDE.md`, or any code files after any `/retro` run
- [ ] Live friction ledger implemented (M1–M7): handler, hybrid gate path, init-orch wiring, rotation, fail-open
- [ ] CDV-184 S3 fixtures still pass

---

## Open Questions

- Phase-1 heuristic thresholds (friction score cutoff, edit-loop window, "terse reply" char limit) will need calibration; initial values ship in the implementation and are tuned via `--why` feedback.
- Should `/retro --all` have a per-project cap to prevent one noisy project from dominating cross-project patterns? Deferred to implementation.
- Should there be a `/retro --dry-run` distinct from default confirm mode? Current design treats default-confirm as equivalent to dry-run-with-opt-in; revisit if users find this confusing.
- **Hook stdin field names** for `PostToolUseFailure` / `PermissionDenied` / `StopFailure` — event *names* appear in the Claude Code hook inventory (ideation wave 2); per-field schema is **not fully verified**. Implementation MUST spike stdin shapes first and map best-effort (`session_id`, `tool`/`tool_name`, path keys); graceful skip when `session_id` absent (M1/M5/M7).

---

## Out of Scope

- Modifying `AGENTS.md` or global `CLAUDE.md` (too broad; each eng↔Claude interaction is project-specific)
- Auto-application without explicit `--auto` flag
- S3 weight/exemption retune (CDV-184 stands; adjacency only)
- Ledger supplying S1/S3/S4/S5 (hybrid is S2-only from ledger)
- `/retro` installing or managing hooks
- Retro'ing sessions from shared directories or other users
- Redaction of session content before review (same trust boundary as normal Claude reads)
- Retroactively deleting or rewriting past directives/lessons (only add or tighten)
- Metrics dashboards or long-term friction analytics beyond the bounded ledger

---

## Version History

| Date | Change |
|------|--------|
| 2026-04-07 | Initial spec created from brainstorm `.claude/plans/2026-04-07-brainstorm-retro.md` |
| 2026-04-08 | Added `--apply` routing MUSTs after kickoff revealed `/adjust-agent` had no non-interactive mode. Resolved by extending SPEC-001 rather than bypassing it. |
| 2026-04-09 | Added `fabrication_anchor` classification in phase-2 and `Consider: /council --from-retro <anchor-id>` integration hint (additive, non-blocking, dedup per anchor-id) per SPEC-013. |
| 2026-06-15 | Editorial hygiene (AUDIT-P3.5b): Status `🚧 NEW`→`APPROVED` (no emoji, matches TDD index); refreshed Covers (dropped `(to be created)`, added shipped `skills/retro-gate/`, `skills/retro-subagent/`, `skills/transcript-parse/`); added the shared transcript-parse seam ownership MUST so SPEC-018's "see SPEC-012" citation resolves. No behavioral change. |
| 2026-07-14 | CDV-184: Phase-1 S3 (edit-loop) MUST exempts clean draft-polish paths (session-created via first `Write`, no intervening tool error or S1 rejection). Pre-existing paths and dirty session-created paths still score. No threshold/weight changes. |
| 2026-07-14 | CDV-186: Promoted live friction telemetry ledger (M1–M7). Hybrid scoring: ledger supplies S2 when session covered (≥1 row); S1/S3/S4/S5 remain transcript. Schema `{ts,session_id,event,tool,path?}`. Single `friction-capture.sh` for PostToolUseFailure/PermissionDenied/StopFailure. Rotation 10k lines or 5 MiB. Wiring via `/init-orchestration` only. No S3 retune. |

---

## Cross-references

- **SPEC-001: Per-Agent Directives** — `/retro` routes all team-agent proposals through `/adjust-agent` to preserve conflict detection and holistic rewrite. MUST NOT bypass. Uses the `--apply` non-interactive mode added to SPEC-001 on 2026-04-08 to support `/retro --auto`.
- **SPEC-002: Plugin Infrastructure** — hook path hygiene (`${CLAUDE_PROJECT_DIR}`, no pipes); init-orchestration template byte-identity gate.
- **SPEC-003: Agent Role System** — `/retro` targets the 7 behavioral agents plus plain `claude`; excludes `project-init` and `distiller`.
- **SPEC-009: Ticket Workflow** — `/kickoff` and `/orchestrate` gain a soft-suggestion hook at completion. No behavioral change to existing ticket-workflow MUST requirements.
- **SPEC-016: Worktree Isolation** — ledger is `$MROOT`-anchored and shared across worktrees (M1).
- **SPEC-018: Cold Session Handoff** — fail-open / graceful-absence precedent (M17/M18) for hook handlers; PreCompact stdin `session_id` pattern.
