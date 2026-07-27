# SPEC-010: Code Review & Release

**Status**: ACTIVE
**Category**: core
**Created**: 2026-03-22

**Covers**: `skills/review-and-commit/SKILL.md`, `skills/release/SKILL.md`

## Overview

Quality gates and shipping. The review-and-commit skill delegates to the adversarial council engine (SPEC-013) in `diff-mode`, loading 5 specialist flavor presets with confidence scoring to filter false positives and block commits on critical issues. The release skill bumps version across all three required files, auto-generates changelog from git history, commits, tags, and pushes.

**Depends on**: SPEC-013 (Adversarial Council Tribunal) — `/review-and-commit` is a thin wrapper over the council engine. See SPEC-013 sections "Engine Architecture", "Phase 4 Prosecution & Defense", "Phase 5 Judgment", "Phase 6 Report & Persistence" for the contract this spec relies on.

## MUST

### Code Review (review-and-commit)
- MUST delegate to the council engine (SPEC-013) with `preset: diff-mode` — review-and-commit is a thin wrapper, not a parallel pipeline
- MUST NOT maintain an adversarial review pipeline independent of the council engine (prevents drift from SPEC-013)
- MUST load the 5 specialists as flavor presets from `skills/council/flavors/`: Logic & Correctness, Security & PII, Compliance (AGENTS.md/CLAUDE.md rules), Design & Quality, Simplification
- MUST configure the `diff-mode` preset so the engine emits the `finding[]` output shape declared in SPEC-013 Output Shapes, satisfying these preset requirements:
  - Findings match the `finding[]` schema: `[{file, line, severity, category, description, suggestion, confidence, tool_use_id}]`
  - Findings scored on 0-100 confidence scale; findings below 80 discarded at emission
  - Severity taxonomy fixed as: critical | warning | nitpick
  - No hedging language in output ("maybe", "consider", "you might want to")
  - Every issue cites a specific `file:line`
  - Every issue carries a concrete fix, not vague advice
- MUST NOT invoke the council engine's feedback-memory path (Phase 7) — diff findings are not fabrications
- Engine invariants (blind investigators, evidence-or-silence, tool_use_id citations, judge-can't-run-tools) apply to diff-mode findings exactly as they apply to session-mode verdicts
- MUST block commit if ANY critical issue or compliance violation exists in the engine verdict
- MUST grep changed file paths against MUST requirements in `specs/` to detect spec misalignment (diff-mode preset responsibility, invoked during diff-mode intake, producing an applicable-specs artifact bundle fed into Phase 1)
- MUST support optional file path argument to save review report; the engine still writes the canonical `.claude/council/<YYYY-MM-DD>-<slug>.md` report, and `/review-and-commit` copies that canonical file to the user-supplied path after the engine returns

### Release
- MUST update all three files per SPEC-002 version sync rules: CHANGELOG.md changelog, plugin.json version, marketplace.json version — never skip any
- MUST verify version strings are semantically identical across all three files before committing
- MUST NOT proceed if no commits exist since last tag ("Nothing to release")
- MUST auto-detect version bump: minor if any `feat:` commits since last tag, else patch
- MUST support explicit version: `/release [patch|minor|major|vX.Y.Z]`
- MUST auto-generate changelog from git log (never ask user for description)
- MUST exclude `chore: release` commits from changelog generation
- MUST group related commits into single changelog bullets (not one line per commit)
- MUST add new changelog section at the top of the changelog in `CHANGELOG.md` (repo root), directly under the file header. The README MUST NOT carry changelog entries — only a pointer to `CHANGELOG.md`.
- MUST, when invoked with an **explicit** version `X.Y.Z` / `vX.Y.Z`, if `CHANGELOG.md` already contains a top-level heading `### vX.Y.Z` or `### X.Y.Z` with a non-empty body (at least one non-empty line under it before the next `### ` heading): **skip** changelog generation (Step 2) and **skip** prepending a new section (Step 3a); verify the existing section and proceed to triplet sync of JSON files if needed. MUST NOT create a duplicate heading for that version. If the heading exists but the body is empty, treat as missing and generate as usual. If the version was auto-detected or a bump keyword (`patch`/`minor`/`major`), never skip — always generate. Cross-ref: SPEC-023 train M5c pre-writes this heading; the train invokes `/release` with the explicit assigned version (**skip-if-present**).
- MUST run the managed-include drift-gate before committing/tagging a release: `python3 skills/agent-memory/sync-includes.py check`. If it exits non-zero, a managed `<!-- include: -->` region has drifted from its canonical partial — MUST NOT commit or tag; fix the drift (re-expand the region to match the partial) and re-run until it exits 0. Currently single-sourced regions: the agent-memory protocol expanded across the 7 agents (`skills/agent-memory/protocol.md`), and the shared tech-lead tiered-cortex load block in `/debug` and `/refactor` Step 0 (`skills/agent-memory/cortex-load.md`).
- The drift-gate covers only managed-include regions (markers present). It does NOT cross-check AGENTS.md against the emitted consumer template — those are intentionally distinct documents (SPEC-005), with no managed-include relationship.

### Docs drift gate

Goal: a deterministic, LLM-free docs-consistency gate for `/release` — a structural sibling of the SPEC-021 skill-bash lint gate (Step 4.8). **Scope boundary:** SPEC-021 owns the *content* of fenced ```bash blocks (its C1–C4 defect classes); THIS gate owns *structural* documentation drift — index tables, roster tables, page links, and manifest description fields that can silently diverge from the `commands/`, `agents/`, `docs/`, and `.claude-plugin/` surfaces they describe. Neither gate inspects what the other owns.

- **D1 — Deterministic checker CLI.** MUST ship `skills/docs-drift/check-docs-drift.sh` as a pure-subprocess CLI (bash and/or python3-stdlib only; no LLM, no network, no third-party dependency), invocable from any cwd. Exit codes: `0` = no unwaived drift, `1` = at least one unwaived finding, `64` = usage error. Each finding prints as one line `<file>: [<check-id>] <message>`; check-ids are `cmd-index`, `agent-roster`, `docs-hub`, `manifest-desc`.
- **D2 — Command-index sync (`cmd-index`).** MUST verify the README `## Commands` index against the real command surface, bidirectionally: (a) every `commands/*.md` file has an entry in the index (no undocumented commands); (b) every `/name` entry in the index resolves to `commands/<name>.md` OR `skills/<name>/SKILL.md` (no ghost entries — skills-backed commands like `/council` and `/release` are legitimate). Internal, non-user-invoked skills (e.g. `memory-store`, `local-agent`) are NOT required to be indexed.
- **D3 — Agent-roster sync (`agent-roster`).** MUST verify the agent roster tables against `agents/*.md` — mechanizing the existing critical rule "Do not add agents without updating the README agent roster table" (AGENTS.md "What NOT to Do"), currently enforced only by convention: (a) the AGENTS.md roster table names match `agents/*.md` basenames exactly (count + names, both directions); (b) every README roster-table row names an existing agent file, and every `agents/*.md` basename appears as a literal `` `<name>` `` token within the README Agents section (table row or internal-agents prose line).
- **D4 — Docs-hub page sync (`docs-hub`).** MUST verify `docs/` command pages against documented commands: (a) every `docs/commands/*.md` link in README and `docs/README.md` resolves to an existing file (each documented command's claimed page exists); (b) every `docs/commands/*.md` file is linked from `docs/README.md` (no orphan pages). Commands documented only in index tables, with no page link, are NOT findings — a docs page is optional; a dead or orphaned one is drift.
- **D5 — Manifest description sync (`manifest-desc`).** MUST verify that descriptive fields duplicated between `.claude-plugin/plugin.json` and `.claude-plugin/marketplace.json` `plugins[]` — at minimum `description` — are byte-identical. Version-string sync is explicitly NOT this check: SPEC-002 rules via release Step 4 own it.
- **D6 — Waiver token.** MUST suppress a finding in a markdown source when the offending line, or the line immediately adjacent within the same table/section, carries `<!-- drift-ok: <check-id> -->` naming that check. Waived findings MUST be counted and summarized (`N findings, M waived`) — visible, never silent. JSON manifests cannot carry comments, so `manifest-desc` findings are unwaivable by design (fix, don't waive).
- **D7 — Release gate wiring + mandatory bite-tests.** MUST be wired as `/release` Step **4.9** (after 4.5 include, 4.6 template-var, 4.7 hook-template, 4.8 skill-bash): non-zero exit blocks commit and tag until fixed or waived, and the wiring change MUST land with the live tree scanning clean (pre-existing drift fixed or waived in the same change — the gate lands green, never red). Bite-tests are MANDATORY before wiring: for each check-id, back up the target file (`cp` to a scratch path), inject a drift, assert exit `1` naming that check-id, then restore via cp-from-backup — NEVER `git checkout` — and assert the clean tree exits `0`.
- **D8 — MUST NOT (scope boundaries).** The checker MUST NOT inspect fenced ```bash block content (SPEC-021's lint classes), MUST NOT re-check spec structural format (SPEC-008's `check-format.sh` owns that), MUST NOT check version-string sync across the three version files (SPEC-002 / release Step 4 owns that), MUST NOT invoke any LLM or network, and MUST NOT modify any scanned file (report-only; no auto-fix).

## SHOULD

- SHOULD check spec alignment as part of review (are changed behaviors still spec-compliant?)
- SHOULD report push failures clearly with manual push command if sandbox blocks

## Test

- Verify review spawns 5 sub-agents and collects structured JSON findings
- Verify confidence scoring discards findings below 80
- Verify commit blocked on critical issues
- Verify release updates all three version files identically
- Verify release auto-detects patch vs minor from commit messages
- Verify changelog excludes `chore: release` commits
- Verify `/release` aborts (no commit/tag) when `sync-includes.py check` exits non-zero (drifted managed-include region), and proceeds when it exits 0

**Docs drift gate:**

1. **Checker CLI (D1):** run `check-docs-drift.sh` from a non-root cwd on a clean tree → exit `0`; findings (when present) each match `<file>: [<check-id>] <message>`; no network calls, no LLM invocation.
2. **Command index bites both ways (D2):** inject an undocumented command (create a stray `commands/zz-test.md` copy) → exit `1` with `[cmd-index]`; inject a ghost index row (`/no-such-cmd`) into the README → exit `1` with `[cmd-index]`; a skills-backed entry (`/council`) → no finding.
3. **Roster bites (D3):** remove one row from the AGENTS.md roster table → exit `1` with `[agent-roster]`; add a ghost row naming a nonexistent agent to the README roster → exit `1` with `[agent-roster]`.
4. **Docs hub bites (D4):** point one README command link at a nonexistent `docs/commands/` page → exit `1` with `[docs-hub]`; drop an unlinked orphan page into `docs/commands/` → exit `1` with `[docs-hub]`; a command documented in the index without any page link → no finding.
5. **Manifest description bites (D5):** mutate one character of the `marketplace.json` `plugins[].description` → exit `1` with `[manifest-desc]`; version fields deliberately excluded (mutating only versions produces no finding from THIS gate).
6. **Waiver (D6):** add `<!-- drift-ok: cmd-index -->` beside an injected ghost entry → exit `0`, summary reports `1 waived`; a `drift-ok: docs-hub` waiver on the same line does NOT suppress a `cmd-index` finding.
7. **Gate wiring + restore discipline (D7):** `/release` dry run with an injected roster drift → release blocked at Step 4.9 before commit/tag; every bite-test injection above restored via cp-from-backup (assert `git status` clean afterwards; `git checkout` never invoked by the fixture harness).
8. **Scope boundaries (D8):** a fenced-bash defect (SPEC-021 class) and a spec missing its `## Validation` section (SPEC-008 class) both produce NO finding from this checker; scanned files are byte-identical before/after a run.

## Validation

- [ ] Review of clean code produces no critical findings
- [ ] Review of code with obvious bug produces critical finding with file:line
- [ ] Release with no commits since tag reports "Nothing to release"
- [ ] After release: plugin.json, marketplace.json, CHANGELOG.md versions match
- [ ] Docs drift gate: `bash skills/docs-drift/test.sh` exits 0; live tree `check-docs-drift.sh` exits 0; Step 4.9 present in `skills/release/SKILL.md`

## Open Questions

- [ ] Should review-and-commit auto-fix nitpicks instead of just reporting them?
- [ ] Is the 80 confidence threshold optimal, or should it be configurable per project?
- [ ] Should release support pre-release versions (e.g., 0.16.0-beta.1)?

## Version History

| Date | Change |
|------|--------|
| 2026-07-22 | CDT-52 / CDT-46-C6: human-reviewed promote INFERRED→ACTIVE; evidence: Linear CDT-52 ship comment + /spec check exit-0. |
| 2026-03-22 | Initial spec generated by /generate-specs |
| 2026-03-23 | Moved version format rules to SPEC-002. Clarified spec alignment check: grep changed paths against MUST requirements. Referenced SPEC-002 for version sync rules. |
| 2026-04-09 | Refactored `/review-and-commit` to delegate to the council engine (SPEC-013) with `preset: diff-mode`. 5 specialists now loaded as flavor presets from `skills/council/flavors/`. Behavioral contracts (JSON schema, 80-confidence threshold, severity levels, no-hedging, file:line, concrete fixes) preserved as engine preset requirements. Added MUST NOT clause forbidding a parallel adversarial pipeline. |
| 2026-04-09 | Taxonomy resolution: reframed findings schema as diff-mode preset emission of SPEC-013's `finding[]` output shape; clarified spec-grep runs at diff-mode intake feeding Phase 1 (not a pre-Phase-1 hook); clarified optional report path triggers a post-engine copy of the canonical council report; forbade diff-mode from invoking Phase 7 feedback memory; recorded engine invariants apply to findings as to verdicts. |
| 2026-04-09 | Path drift fix: corrected flavor preset directory from `skills/dev-team:council/flavors/` to `skills/council/flavors/` (filesystem path carries no `dev-team:` namespace prefix). No behavioral change. |
| 2026-06-13 | AUDIT-P1-1B: anchored the managed-include drift-gate (`sync-includes.py check`, shipped v0.32.0 in `skills/release/SKILL.md` Step 4.5) as a Release MUST — it was previously specced nowhere. Scoped it to managed-include regions only; clarified it does NOT cross-check AGENTS.md vs the emitted template (SPEC-005 distinctness). |
| 2026-06-22 | Doc-IA pass: changelog target moved from `README.md` to a dedicated repo-root `CHANGELOG.md`. Release MUST now writes the new `### vX.Y.Z` section to `CHANGELOG.md` and the README only points to it. `skills/release/SKILL.md` Steps 2/3a/4/5 updated accordingly. |
| 2026-07-13 | CDV-181 / SPEC-023: Release MUST skip-if-present — when `/release` is invoked with an explicit version and CHANGELOG already has that heading with a non-empty body, skip Step 2 generation and Step 3a prepend (no duplicate heading). Enables train M5c pre-write. |
| 2026-07-14 | CDV-188: promoted Docs drift gate (D1–D8) from ideation-wave-2 DRAFT — deterministic checker, four check-ids, waiver token, Step 4.9 release wiring, mandatory bite-tests, scope boundaries vs SPEC-021/008/002. |

## Cross-references

- SPEC-013: Adversarial Council Tribunal — engine that `/review-and-commit` delegates to via `preset: diff-mode`
- SPEC-002: Plugin Infrastructure — version sync rules, version format conventions
- SPEC-009: Ticket Workflow — orchestrate triggers review before PR creation
- SPEC-003: Agent Role System — QA agent has veto power that review-and-commit formalizes
- SPEC-008: Spec Management — review checks spec alignment
- SPEC-021: Skill-bash lint gate — content-class sibling; docs-drift owns structural doc drift only
- SPEC-023: Release Train Queue — multi-branch sequencer invokes `/release` with explicit assigned version; relies on skip-if-present for pre-written CHANGELOG headings
