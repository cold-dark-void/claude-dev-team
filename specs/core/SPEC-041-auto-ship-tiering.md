# SPEC-041: Auto Ship Tiering

**Status**: DRAFT
**Category**: core
**Created**: 2026-11-03

**Covers**: `skills/autopilot/SKILL.md`, `skills/autopilot/parse-flags.sh`, `skills/autopilot/ship-pipeline.md`, `skills/autopilot/classify.md`, `skills/autopilot/classify-test.sh`, `skills/autopilot/test-auto-token.sh`, `skills/release/detect-surfaces.sh`, `skills/release/check-bump-class.sh`, `skills/release/test-bump-class.sh`, `skills/backlog/sweep.sh`, `skills/backlog/sweep-test.sh`, `skills/epic/epic-lib.sh`, `skills/epic/test-seal-safety.sh`, `docs/commands/backlog.md`, `docs/commands/orchestrate.md`

## Overview

Auto ship tiering adds the ship-intent token `auto`. `/backlog sweep
--ship=auto` compiles to `--autopilot=auto` (SPEC-040 M17). Under `auto`,
the ship gate decides the release bump per item: the orchestrator
classifies the baseline diff in-session (LLM judgment, two stages), a
deterministic Surface-detection veto runs after the LLM decision, and the
run folds via the existing tagged-release path with the decided bump
passed explicitly. Output space is `{patch, minor, halt}` — never major.
The shared Surface-detection helper is extracted from
`skills/release/check-bump-class.sh` so the veto and the B1–B6 gate use
one implementation. This spec owns the `auto` tier; cite SPEC-033
(tokens, decision-cards, ship gate, N3a baseline), SPEC-040 (sweep
compile, journal), and SPEC-010 (bump-class gate). Do not restate them.

## MUST

### Token and compile (AC1, AC2)

- **M1 — `auto` ship-intent token.** `/orchestrate`, `/kickoff`, and
  `/epic` accept `--autopilot=auto` in the flag position.
  `skills/autopilot/parse-flags.sh` MUST accept the token and report it in
  the status `bump` field. `AUTOPILOT=1` env MUST NOT carry a bump
  (SPEC-033 M2). All gates other than the ship gate self-answer per
  SPEC-033 unchanged.
- **M2 — Sweep compile.** `auto` joins the sweep `--ship` enum.
  `compile-ship --ship=auto` prints `--autopilot=auto`. Every existing
  value (`pr|master|patch|minor|major`) compiles byte-identical to today
  (SPEC-040 M17). Unknown and empty values still exit 64. Attended
  default is unchanged: no `--ship` (per-ticket ship question). Sweep
  MUST NOT pass literal `--ship` (SPEC-040).
- **M3 — Card bump enum frozen.** The literal token `auto` MUST NOT
  appear in any decision-card `bump` field; cards record the decided
  concrete bump only (SPEC-033 AC6 enum stays
  `patch|minor|major|master|null`). No SPEC-033 schema amendment.
- **M4 — BC5 reroute under auto.** A BC5 reroute under `auto` persists
  `release_bump: auto` in durable epic state; each child decides its
  concrete bump at its own ship gate (tag-per-item preserved; seal-intent
  rules per SPEC-033/SPEC-025 unchanged).

### Ship-gate classification (AC3, AC4)

- **M5 — In-session, pre-fold, baseline diff.** Under `auto`, the
  ship-gate bump is decided by the orchestrator in-session (LLM judgment,
  no spawned agent) on the diff against the SPEC-033 N3a worktree baseline
  (resolved push target) — the diff the fold will actually ship.
  Classification MUST run before the fold and exactly once per item. The
  orchestrator MUST NOT invoke `/release` interactively and MUST NOT
  re-run classification at fold time; the decided bump is passed
  explicitly down the existing tagged-release fold path.
- **M6 — Two stages, frozen output space.** Stage 0: the orchestrator
  judges in-session whether the diff contains a code-bearing change. No →
  journal entry from the existing M20 enum (no new outcome values), walk
  continues, no tag, no fold, no bump decision-card. Yes → stage 1
  returns exactly one of `{patch, minor, halt}`.
- **M7 — Fail-closed.** Any stage-1 response that is empty, non-enum,
  malformed, or absent is treated as `halt`: journal outcome from the
  existing M20 enum, escalation raised, walk continues, no tag, no fold.
  Fleet-degradation posture applies (AGENTS.md degradation marker rules).
- **M8 — No deterministic path filter.** The stage-0 code-bearing
  judgment is LLM judgment with M7 fail-closed. MUST NOT add a
  path-glob or extension-based stage-0 filter.

### Surface veto (AC5)

- **M9 — Deterministic veto after the LLM.** After a stage-1 decision,
  the shared Surface-detection helper (M12) runs on the same baseline
  diff via its explicit `--against` ref. Any new top-level
  `commands/<name>.md` vetoes `patch` up to `minor`. The veto only
  raises `patch` → `minor`: it never demotes, never rescues a `halt`,
  and never produces `major`. A would-be major classifies as `halt`. If
  the LLM returned `minor` or `halt`, the veto result is recorded but
  the answer stands.

### Record and tags (AC6, AC7)

- **M10 — Decision-cards.** One `ship-choice` decision-card per decided
  bump: `bump` is the decided token; classification evidence and veto
  result ride `rationale` (SPEC-033 AC6 schema frozen, untouched).
  Halts under `auto` also write a `decision:"halt"` ship-choice card
  with `bump:null` (SPEC-033 M13 already requires a card per halt).
- **M11 — Tags only on a decided bump.** No tag is created when: the
  diff has no code-bearing change (M6 stage 0), classification halts
  (M6/M9), or the item records no code commits at the gate. Tag creation
  happens only on a decided `{patch, minor}` bump, via the existing fold
  path with the decided bump passed explicitly.

### Shared helper (AC8)

- **M12 — `detect-surfaces.sh`.** Surface detection — new top-level
  `commands/<name>.md`, `--no-renames` (rename-onto-top-level counts as
  added), untracked `git ls-files --others` mode — is extracted from
  `skills/release/check-bump-class.sh` into `skills/release/detect-surfaces.sh`,
  a subprocess CLI whose API accepts an explicit `--against` ref. Both
  `check-bump-class.sh` and the M9 veto call the helper;
  `check-bump-class.sh` MUST NOT keep a private copy. All existing
  checker modes (`worktree`, `--cached`, `--against`, `--commit`,
  `--range`) and exit codes (0/1/64) are unchanged.

## SHOULD

- SHOULD record the LLM classification evidence verbatim in the card
  `rationale` next to the veto result.
- SHOULD keep `skills/autopilot/classify.md` at or under the SPEC-035
  skill-size WARN (30720 bytes).

## MUST NOT

- MUST NOT add any new `commands/*.md` (patch ship class legality per SPEC-010).
- MUST NOT write `auto` into a decision-card `bump` field or amend the
  SPEC-033 AC6 card schema.
- MUST NOT add M20 journal outcome values (SPEC-040 M20 enum stays closed).
- MUST NOT let the veto demote a bump, rescue a `halt`, or produce `major`.
- MUST NOT spawn an agent for classification — in-session judgment only.
- MUST NOT tag or fold on the stage-0, halt, or no-code-commit paths.
- MUST NOT keep a private copy of Surface detection inside
  `check-bump-class.sh` (M12).
- MUST NOT restate SPEC-033 / SPEC-040 / SPEC-010 contracts; cite them.

## Test

- Format: `bash skills/spec-tooling/check-format.sh specs/core/SPEC-041-auto-ship-tiering.md` exits 0.
- `skills/autopilot/classify-test.sh` — matrix: no-code-change (stage 0,
  zero tag/card side effects), `patch`, `minor`, would-be major →
  `halt`, and each failure mode (empty, non-enum, malformed, absent) →
  `halt` + continue; veto matrix (LLM `patch` + new Surface → `minor`;
  LLM `minor` + new Surface → `minor`; LLM `halt` + new Surface →
  `halt`); exactly one classification per item; base ref = resolved push
  target; explicit bump reaches the fold; append-card/read-cards
  round-trip asserts schema_version 1 shape, `rationale` evidence, and
  halt-card fields; zero tag side effects on skip/halt paths.
- `skills/autopilot/test-auto-token.sh` — parse/reject per Surface
  (illegal and empty values exit 64 with zero side effects); `auto`
  accepted; BC5 persistence asserts `release_bump: auto` in epic state.
- `skills/backlog/sweep-test.sh` — AC9 block: `auto` row added; every
  existing row retained byte-identical.
- `skills/release/test-bump-class.sh` — existing suite green
  (behavior-preserving refactor) plus helper unit cases: added file,
  nested path, edit, rename-onto, untracked.
- `bash tools/spec-lint.sh` exits 0 on this spec (index row + covers of
  files present at spec commit).

## Validation

- `compile-ship --ship=auto` prints `--autopilot=auto`; all other values
  byte-identical to the pre-change outputs (suite).
- `parse-flags --autopilot=auto` succeeds on each Surface; illegal values
  exit 64 with zero side effects (suite).
- Classifier matrix rows above all green; stage-0 and halt paths create
  zero tags and zero bump cards (suite).
- `check-bump-class.sh` regression suite green and byte-identical outputs
  across all five modes (suite).
- `bash skills/epic/test-seal-safety.sh` green with the
  `release_bump: auto` persistence case (suite).

## Version History

| Date | Change |
|------|--------|
| 2026-11-03 | Initial DRAFT (sweep-auto-ship-tiering): `--ship=auto` compile, ship-gate bump classifier with two-stage in-session judgment, deterministic Surface veto, shared `detect-surfaces.sh` helper. |

## Acceptance criteria

### sweep-auto-ship-tiering

- **AC1.** Sweep flag parse and compile (extends SPEC-040 M17/AC9). `--ship=auto` is accepted by the Backlog sweep `--ship` enum. `compile-ship --ship=auto` prints `--autopilot=auto`. Every existing value (`pr|master|patch|minor|major`) compiles byte-identical to today. Unknown and empty values still exit 64. Attended default stays: no `--ship` (per-ticket ship question). No invocation of `compile-ship` ever prints a literal `--ship`.
  Verify: bash skills/backlog/sweep-test.sh
- **AC2.** General `--autopilot=auto` token. `/orchestrate`, `/kickoff`, and `/epic` accept `--autopilot=auto`. All gates other than the ship gate self-answer per SPEC-033 unchanged. The literal token `auto` never appears in a decision-card `bump` field — cards record the decided bump only (SPEC-033 AC6 `bump` enum stays `patch|minor|major|master|null`). A BC5 reroute under auto persists `release_bump: auto`; each child's own ship gate decides its concrete bump at its own gate (tag-per-item preserved).
  Verify: bash skills/autopilot/test-auto-token.sh
- **AC3.** Classification is in-session, pre-fold, against the worktree baseline. Under `--autopilot=auto`, the ship-gate bump is decided by the orchestrator in-session (LLM judgment, no spawned agent) on the diff against the SPEC-033 N3a worktree baseline (resolved push target) — the diff the fold will actually ship. Classification runs before the fold. The orchestrator MUST NOT invoke `/release` interactively and MUST NOT re-run classification at fold time — the decided bump is passed explicitly down the existing tagged-release fold path.
  Verify: bash skills/autopilot/classify-test.sh
- **AC4.** Two-stage classification; output space frozen. Stage 0: the orchestrator judges in-session whether the diff contains a code-bearing change. No → journal entry from the existing M20 enum (no new outcome values), walk continues, no tag, no fold, no bump decision-card. Yes → the classifier returns exactly one of `{patch, minor, halt}`. Any other response — empty, non-enum, malformed, or no response — is treated as `halt` (fail-closed, fleet-degradation posture): journal outcome from the existing enum, escalation raised, walk continues, no tag, no fold.
  Verify: bash skills/autopilot/classify-test.sh
- **AC5.** Deterministic Surface veto. After the LLM classification, the shared Surface-detection helper (AC8) runs on the same baseline diff via its explicit `--against` ref. Any new top-level `commands/<name>.md` vetoes `patch` up to `minor`. The veto can only raise `patch` → `minor`: it never demotes, never rescues a `halt`, and never produces `major`. If the LLM returned `minor` or `halt`, the veto result is recorded but the answer stands. A would-be major classifies as `halt`.
  Verify: bash skills/autopilot/classify-test.sh
- **AC6.** Decision-cards (SPEC-033 AC6 schema frozen; no amendment). One `ship-choice` decision-card per decided bump with: decided `bump`, classification evidence, and veto result — all riding existing fields (`rationale` carries evidence + veto result; schema untouched). Halts under auto also write a `decision:"halt"` ship-choice card with `bump:null` (SPEC-033 M13 already requires a card per halt). `bump:"auto"` is invalid everywhere.
  Verify: bash skills/autopilot/classify-test.sh
- **AC7.** Tags only on a decided bump. No tag is created when: the diff has no code-bearing change (AC4 stage 0), classification halts (AC4/AC5), or the item records no code commits at the gate. Tag creation happens only on a decided `{patch, minor}` bump, via the existing fold path with the decided bump passed explicitly.
  Verify: bash skills/autopilot/classify-test.sh
- **AC8.** Shared Surface-detection helper extraction (behavior-preserving). Surface detection (new top-level `commands/*.md`, `--no-renames`, rename-onto-top-level-counts-as-added, untracked-ls-files mode) is extracted from `skills/release/check-bump-class.sh` into a reusable script under `skills/release/` with an API that accepts an explicit `--against` ref. Both `check-bump-class.sh` and the ship-gate veto call the helper — `check-bump-class.sh` MUST NOT keep a private copy. All existing modes (worktree, `--cached`, `--against`, `--commit`, `--range`) and exit codes (0/1/64) are unchanged; B1–B6 gate behavior unchanged.
  Verify: bash skills/release/test-bump-class.sh
- **AC9.** [process] Spec amendments shipped with the code. SPEC-040 M17/AC9 amended (`auto` joins enum; literal `--ship` ban intact). SPEC-033 unchanged (rationale carries evidence/veto; M13 already covers halt cards). No M20 journal outcome enum change. Ship class: patch per AGENTS.md (new opt-in value, default behavior unchanged) — no new `commands/*.md`, so the bump-class gate stays green.

## Alternatives considered

- Sweep-side classification — rejected: violates SPEC-040 "sweep MUST NOT
  invoke `/release`"; the diff does not exist until orchestrate implements;
  duplicates fold logic.
- `/release`-native `auto` keyword — rejected: classification would run
  after the code reaches master; the B1–B6 gate on the fold commit fires
  first; wrong sequencing for the veto.
- `bump:"auto"` in the decision-card schema — rejected: SPEC-033 AC6 is
  frozen; evidence and veto ride `rationale` instead (DRI OQ3).
- Deterministic path-glob filter for stage 0 — rejected (DRI OQ6): LLM
  judgment plus fail-closed degradation is the decided posture.
- Veto before the LLM — rejected: sequencing AC5 runs the veto after the
  LLM decision so the LLM raise is confirmed by the mechanical floor and
  a `halt` is never rescued.

## Cross-references

- SPEC-033 — M2 ship-intent tokens, AC6 decision-card schema, AC7 ship
  gate, N3a baseline (resolved push target), WP 1-14 verdict mapper
- SPEC-040 — M17/AC9 `--ship` compile, M20 journal enum
- SPEC-010 — bump-class gate (B1–B6); no new `commands/*.md` keeps patch legal
- SPEC-016 — worktree isolation (baseline diff context)
- SPEC-021 — skill bash lint gate (new shell scripts)
- SPEC-031 — escalation gate (halt + continue posture)
- SPEC-035 — skill-size WARN 30720
