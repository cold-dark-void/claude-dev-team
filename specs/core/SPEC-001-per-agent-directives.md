# SPEC-001: Per-Agent Directives

**Status**: ACTIVE — implemented in v0.15.0
**Category**: core
**Created**: 2026-03-16
**Ticket**: DIR-001

**Covers**: `commands/adjust-agent.md`, `agents/*.md` (directives loading block), `skills/retro-gate/trial-meta.sh`, `skills/retro-gate/trial-review.sh` (trial loop helpers; review step owned by SPEC-012)

## Overview

Persistent behavioral instructions for individual agents — project-specific standing orders that survive across sessions, load before any memory, and cannot be overridden by the agent's own reasoning. Managed via `/adjust-agent` command. Follows the Asimov model: directives are non-negotiable, zero-impact when absent, minimal footprint (~3 lines per agent), and user-owned as plain numbered lists.

## MUST

### Directives File
- MUST store per-agent directives at `.claude/memory/<agent>/directives.md` where `<agent>` is one of: `pm`, `tech-lead`, `ic5`, `ic4`, `devops`, `qa`, `ds`
- MUST NOT load directives for `project-init` or `distiller` agents (internal-only, no user behavioral overrides)
- MUST have zero impact when `directives.md` does not exist — no errors, no warnings, no placeholder output
- MUST use numbered list format, one directive per line (e.g., `1. Always write specs in Gherkin format`)
- MUST NOT commit `directives.md` files to git (covered by `.gitignore` patterns under `.claude/memory/`)

### Agent Loading Protocol
- MUST load directives BEFORE memory during session start — load order: (1) directives, (2) memory, (3) context
- MUST frame directives as "standing orders for this project" that take priority over agent reasoning and memory
- MUST NOT error when the file is absent or empty — use `cat ... 2>/dev/null` or equivalent silent fallback
- MUST use ~3 lines of bash for loading, consistent across all 7 agents — placed after path resolution, before memory loading. The canonical directives-load-then-memory sequence lives in the managed-inline agent memory protocol (`skills/agent-memory/protocol.md`, "load directives (before memory)" then the tiered read of `skills/memory-recall` Step 2); see SPEC-006.
- MUST NOT allow agent to override directives via its own reasoning — framing and load-first positioning are the enforcement mechanisms

### /adjust-agent Command
- MUST display dashboard (all 7 agents + directive counts) when invoked with no arguments
- MUST display read-only directive list when invoked with agent name only — MUST NOT prompt for input
- MUST trigger conversational adjustment flow when invoked with agent name + prompt: read existing → interpret → detect conflicts → holistic rewrite → show final state
- MUST accept any agent name string but MUST warn if no matching agent `.md` file exists in `agents/` (forward-compatible, typo-safe)
- MUST detect conflicts between new intent and existing directives interactively — MUST NOT silently resolve conflicts
- MUST rewrite entire `directives.md` holistically on each adjustment (never append) — all directives re-evaluated as coherent set
- MUST display final directive list after writing so user can verify
- MUST create `directives.md` file and parent directory if they do not exist
- MUST be idempotent: same prompt on same state produces same result (no duplicates, no drift)
- MUST support a non-interactive `--apply` flag: `/adjust-agent <agent> --apply <prompt>` skips user prompting and applies the adjustment directly — but on conflict detection MUST refuse the write and exit with a clear error (fail-fast, never silently resolve). Enables automation callers (e.g. `/retro --auto`) to request directive updates without bypassing conflict safety.

### /init-team Integration
- MUST output hint about `/adjust-agent` after init-team completes bootstrap

### .gitignore Coverage
- MUST ensure `.gitignore` covers `directives.md` files (verify existing `.claude/memory/` patterns are sufficient; add explicit entry if not)
- MUST check coverage in `/init-team` and in `/adjust-agent` when creating a new directives file

### Directive A/B trial loop (CDV-200)

Goal: close the `/retro` self-improvement loop with evidenced trial periods. Retro-born directives start as **trials** with inline metadata; after a review window `/retro` compares SPEC-012 phase-1 friction-gate scores (baseline vs in-trial) and proposes KEEP or REVERT with evidence. Outcomes always route through `/adjust-agent` — never silent auto-revert. Plain (unannotated) directives keep permanent semantics.

- **M1 — Trial metadata format (inline, format-preserving).** A directive created from a `/retro` proposal MUST carry trial metadata inline on its numbered-list line as a trailing HTML-comment annotation (e.g. `3. Always run bash -n before writing scripts <!-- trial start=2026-07-03 source=<session-uuid>#<anchor-id> review-after=10-sessions -->`), carrying at minimum: source anchor (session uuid + phase-1 friction-anchor message id), trial-start date (`YYYY-MM-DD`), and a review-after window expressed as `N-sessions` or `D-days`. The annotated line MUST remain a valid SPEC-001 directive: load order, standing-order framing, the `grep -c '^[0-9]'` dashboard count, and the holistic-rewrite flow operate on it unchanged — and holistic rewrites MUST preserve trial annotations on directives they do not intentionally modify or remove.
- **M2 — Plain directives keep today's semantics (backward compatibility).** A directive line without trial metadata is permanent — exactly today's behavior. The trial machinery MUST have zero impact on existing `directives.md` files (no migration, no warnings) and MUST NOT reinterpret, annotate, or propose reversion of any directive that never carried trial metadata.
- **M3 — Default tagging at creation.** The `/retro` proposal emitter (SPEC-012 proposal routing) MUST attach trial metadata by default to every NEW team-agent directive it routes through `/adjust-agent`, populated from the proposal's own citation anchors; the user MAY strip the metadata at confirm time to create a permanent directive immediately. Manually created directives (plain `/adjust-agent` usage) remain untagged unless the user explicitly requests a trial. TIGHTEN MUST NOT invent new trial metadata (preserves annotation if already present).
- **M4 — Trial review step (evidence comparison).** `/retro` MUST include a trial-review step: for each trial directive whose review-after window has elapsed, compare SPEC-012 phase-1 friction-gate scores for candidate sessions inside the trial window against the pre-trial baseline (same scoring semantics — signal set, weights, caps, threshold unchanged; the gate is the metric), then emit a KEEP or REVERT proposal showing the evidence: baseline scores, in-trial scores, and the session ids behind each number. MVP session set is project-level (or `--all` scope), split by session mtime vs trial `start` — not agent-filtered. Decision rule: if either side has `n < 2` → DEFER (no proposal); elif `mean(in_trial) < mean(baseline)` → KEEP; else REVERT (ties → REVERT). The same review step MUST run on the scheduled `/retro --all --auto` path (SPEC-012 S1–S9) with outcomes still surfaced as proposals per M6.
- **M5 — Outcomes execute only through `/adjust-agent` paths.** A confirmed KEEP MUST drop the trial metadata via the `/adjust-agent` holistic-rewrite flow, leaving a plain permanent directive; a confirmed REVERT MUST remove the directive via the `/adjust-agent` removal path (interactive, or `--apply` with its fail-fast conflict refusal). The trial loop MUST NOT write `directives.md` directly — mirroring the shipped SPEC-012 rule that `/retro` routes team-agent changes through `/adjust-agent`.
- **M6 — MUST NOT silently auto-revert.** Trial outcomes are proposals to the user by default: the loop MUST NOT auto-revert (or auto-keep) any directive without user confirmation. An explicit opt-in automation mode (`/retro --auto`) MAY apply KEEP/REVERT decisions without per-item prompting, but MUST print each applied decision with its evidence, and `--apply` conflict refusals MUST degrade to confirm-mode proposals rather than silent drops (same degradation contract as SPEC-012's `--auto`).
- **M7 — Audit trail.** Every trial decision — KEEP, REVERT, or a user override of either — MUST append one NDJSON record to `$MROOT/.claude/retro/directive-history.jsonl` (worktree-aware `$MROOT`), fields: `{ts, agent, directive, source, trial_start, baseline, in_trial, decision, decided_by}` (`decided_by` ∈ `user` | `auto`; `baseline`/`in_trial` are `{mean, n, sessions}`), so the evidence behind every kept or reverted directive is reconstructable. The ledger is append-only local state (not committed) and MUST NOT live in `memory.db`. Audit write is owned by the apply path (after successful `/adjust-agent`), not by dry-run review.
- **M8 — Conflict parity for trial directives.** A trial directive is a full standing order while under trial: SPEC-001's existing conflict rules apply unchanged — `/adjust-agent` conflict detection (interactive surfacing; `--apply` fail-fast refusal) MUST evaluate trial directives when adding or changing directives, and the agent-side rule (flag a conflicting user instruction rather than silently ignoring the directive) MUST bind trial directives exactly as permanent ones. Trial status never weakens a directive's authority — it only schedules its review.

Helpers (subprocess only, never sourced): `skills/retro-gate/trial-meta.sh` (parse/annotate/strip/is-elapsed) and `skills/retro-gate/trial-review.sh` (review emit + `--record-decision` audit append).

## SHOULD

- SHOULD compute directive count via `grep -c '^[0-9]'` for dashboard display

## Test

- Verify directives load before memory in all 7 agent session-start sequences
- Verify absent directives file causes no errors or output
- Verify `/adjust-agent` dashboard shows correct counts for all 7 agents
- Verify `/adjust-agent <agent>` read-only mode does not prompt for input
- Verify `/adjust-agent <agent> <prompt>` detects conflicts and surfaces them
- Verify holistic rewrite produces no duplicates on repeated invocation
- Verify `project-init` and `distiller` agents do not load directives
- **Metadata round-trip (M1):** create a retro-born directive → the `directives.md` line carries the source anchor, trial-start date, and review-after annotation; agent load, dashboard count, and an unrelated `/adjust-agent` holistic rewrite all leave the annotation intact.
- **Backward compatibility (M2):** run the trial-review step against a pre-existing `directives.md` with no annotations → zero changes, zero warnings, no review proposals.
- **Default tagging (M3):** a `/retro` NEW team-agent proposal lands with trial metadata populated from its citation anchors; declining the trial at confirm time yields a plain permanent line; a manual `/adjust-agent` directive gets no annotation.
- **Evidenced review (M4):** seed baseline sessions (high friction) and in-trial sessions (low friction), elapse the window → the review emits KEEP citing both score sets and their session ids; invert the scores → it emits REVERT; scoring semantics are identical to the shipped gate.
- **Outcome paths (M5):** a confirmed KEEP drops only the annotation via holistic rewrite; a confirmed REVERT removes the directive via the `/adjust-agent` removal path; no direct `directives.md` write occurs from the trial loop.
- **No silent revert (M6):** without opt-in auto mode, an elapsed REVERT-leaning trial changes nothing until the user confirms; with auto mode, each applied decision prints its evidence, and an `--apply` conflict refusal degrades to a confirm-mode proposal instead of being dropped.
- **Audit trail (M7):** each decision appends exactly one NDJSON line to `$MROOT/.claude/retro/directive-history.jsonl` with the required fields; nothing is written to `memory.db`.
- **Conflict parity (M8):** an adjustment conflicting with a trial directive is surfaced interactively and refused under `--apply`, exactly as with a permanent directive.

## Validation

- [ ] All 7 agent `.md` files contain directives loading block after path resolution
- [ ] `project-init.md` and `distiller.md` do NOT contain directives loading block
- [ ] `/adjust-agent` with no args shows 7-row dashboard
- [ ] `/adjust-agent pm "use Gherkin"` creates/updates `.claude/memory/pm/directives.md`
- [ ] Running same adjustment twice produces identical file content (idempotent)
- [ ] Deleting `directives.md` causes zero errors on next agent session start
- [ ] `/adjust-agent <agent> --apply <prompt>` writes directives on no-conflict; refuses with non-zero exit on conflict
- [x] Directive A/B trial loop (M1–M8) implemented — helpers + `/retro` + `/adjust-agent` wiring (CDV-200); fixture tests in `skills/retro-gate/trial-meta-test.sh` and `trial-review-test.sh`

## Open Questions

None — all ACs confirmed by user. OQ-2 (agent-filtered session scoring) deferred to a follow-up if needed; MVP uses project-level scores.

## Out of Scope

- Directive inheritance (global directives for all agents)
- Directive versioning or full history beyond the trial-decision audit trail (`directive-history.jsonl`, M7)
- Directive validation against agent capabilities
- Remote/shared directive storage
- Programmatic directive API beyond `/adjust-agent`
- Agent-filtered session scoring for trial review (MVP = project-level; OQ-2)
- Auto-migrate existing directives into trials
- Trial loop for `claude` lessons or `plugin` backlog items

## Version History

| Date | Change |
|------|--------|
| 2026-03-16 | Initial spec drafted by tech-lead for DIR-001 |
| 2026-03-16 | Implemented and shipped in v0.15.0 |
| 2026-03-23 | Reformatted for /reflect-specs compliance: added Category, Created, Covers, Overview, Test, Validation, Version History sections. Consolidated section-based requirements into bulleted MUST format. Status updated from Draft to ACTIVE. |
| 2026-04-08 | Added `--apply` non-interactive mode MUST to enable automation callers (RETRO-001 / SPEC-012). Fail-fast on conflict preserves existing conflict-detection guarantee. |
| 2026-06-13 | Cross-referenced the canonical directives-load-then-memory sequence to the managed-inline agent memory protocol (skills/agent-memory/protocol.md) and SPEC-006 Step 2 tiered read (AUDIT-P1-1). |
| 2026-07-03 | Proposed extension (DRAFT): Directive A/B trial loop — ideation wave 2 |
| 2026-07-14 | CDV-200: promoted Directive A/B trial loop M1–M8 from DRAFT to shipped MUST; helpers `trial-meta.sh` / `trial-review.sh`; audit `directive-history.jsonl`. |

## Cross-references

- SPEC-003: Agent Role System — 7 behavioral agents, directives in memory architecture
- SPEC-005: Team Bootstrap — init-team outputs /adjust-agent hint
- SPEC-006: Memory Retrieval — tiered session-start read that runs after directives load (directives → memory → context)
