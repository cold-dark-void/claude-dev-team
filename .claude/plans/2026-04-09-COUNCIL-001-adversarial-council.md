# COUNCIL-001 — Adversarial Council Tribunal (core)

**Status**: PLANNED
**Spec**: `specs/core/SPEC-013-adversarial-council-tribunal.md`
**Target version**: 0.17.2 → 0.18.0
**Created**: 2026-04-09

---

## Goal

Ship the core of SPEC-013: an on-demand adversarial tribunal (`/council`) that reality-checks model claims with real tool-call evidence, implemented as an engine skill (`skills/council/`) with thin command wrappers. `/review-commit` is refactored to delegate into the same engine with a `diff-mode` preset so the two adversarial systems never drift. A dedicated `council-judge` agent (empty tool allowlist, tech-lead cortex) serves as judge. Per-task metadata (`requires_council`) flows through `.claude/tasks/<id>.json` and is enforced by the TaskCompleted hook against a verdict index at `.claude/council/index.json`.

## Locked decisions (from kickoff prompt)

1. Scope split: COUNCIL-001 core; COUNCIL-002 defers `--plan`, `--from-retro` execution, Phase 3 dynamic domain specialist, `--why`, token reporting, caching.
2. Judge = NEW `agents/council-judge.md` with `tools: ""`, inheriting `tech-lead` cortex/memory/directives load path.
3. Investigator spawn = Task tool `subagent_type: "general-purpose"` (or `Explore` for code-heavy claims); flavors are prompt-template variants injected into Task prompts, NOT persistent agents.
4. Per-task metadata store: orchestrator writes `.claude/tasks/<task_id>.json` at TaskCreate/TaskUpdate; hook reads it.
5. Review-commit refactor: snapshot test is an AC (canned diff → byte-identical user-visible output pre/post refactor).
6. TaskCompleted hook contract spike is the FIRST task — 30-min time-box; deliverable is an investigation report that feeds real hook impl.
7. Version bump minor: 0.17.2 → 0.18.0.
8. Deferred scopes (`/council --plan`, `/council --from-retro`) MUST fail loudly with a clear "not implemented in COUNCIL-001, planned for COUNCIL-002" message and exit non-zero.

## Non-goals for COUNCIL-001

- Phase 3 dynamic domain specialist pull (SPEC-013 lines 62–69 deferred to COUNCIL-002)
- `/council --plan <path>` actual execution (accept flag → fail-loud stub)
- `/council --from-retro <anchor-id>` actual execution (accept flag → fail-loud stub; `/retro` hint IS in scope)
- `--why` flag, token-usage reporting, investigator read-call caching (all SHOULD-only in SPEC-013)

## Phase structure

- **Phase 1 — Foundation** (sequential where noted; rest parallel-safe). Blocks everything else.
- **Phase 2 — Engine body** (parallel branches A–E after Phase 1).
- **Phase 3 — Integration** (parallel after engine body).
- **Phase 4 — Release** (sequential after integration passes).

**Dogfood gate**: The TaskCompleted council gate MUST NOT be enabled (i.e., the hook's new council-path code path may be committed but no `requires_council: true` task exists) until Tasks T1, T3, T5, T6, T7, T8, T10, T11, T12 are all COMPLETED. At that point, T15's smoke test against SPEC-013 Test 9 becomes the canonical dogfood moment.

---

## Tasks

### Phase 1 — Foundation

#### TASK 1: TaskCompleted hook contract spike
- **agent**: ic5
- **depends_on**: none
- **files**: `.claude/plans/2026-04-09-taskcompleted-hook-spike.md` (investigation report only — no code lands)
- **exposes**: Documented contract for what Claude Code actually passes to `TaskCompleted` hooks on stdin / env / argv, feeding T10.
- **description**: 30-minute time-boxed investigation. Write a throwaway stub hook (not committed) that logs `stdin`, `env`, `argv`, and any JSON payload Claude Code streams. Trigger a real TaskCompleted event manually (via `TaskUpdate` flipping a task to `completed`) and capture raw output. Report findings in the plan file above: does Claude Code pass a JSON payload on stdin? which env vars are present? is `CLAUDE_TASK_ID` naturally populated by the runtime, or does the orchestrator have to export it? This answers SPEC-002 Open Question line 76.
- **ACs**:
  - Investigation report exists at `.claude/plans/2026-04-09-taskcompleted-hook-spike.md`
  - Report names: stdin format, env vars present, argv shape, whether `CLAUDE_TASK_ID` is runtime-provided
  - Report explicitly states which of SPEC-002 MUSTs (lines 22–37) need adjustment, if any
  - Stub hook is NOT committed (throwaway)

#### TASK 2: `skills/council/SKILL.md` engine protocol doc
- **agent**: ic5
- **depends_on**: [Task 1]
- **files**: `skills/council/SKILL.md` (new, ~400–600 lines)
- **exposes**: The engine protocol every other council task codes against — CLI arg contract, flavor-file schema, prompt-template contract, output shapes (`verdict[]` | `finding[]`), index.json row schema, report frontmatter.
- **description**: Write the engine-as-skill spec document. This is a protocol doc (docs-as-code), not an implementation. Must cover: CLI args (`"<claim>"`, `--session [--last N]`, `--plan <path>` stub, `--diff`, `--from-retro <id>` stub, `--task-id <id>`), scope argument required (SPEC-013 line 30), task-id fallback chain (`--task-id` → `CLAUDE_TASK_ID` → unbound, line 120), output shape declarations per preset, flavor file schema (`name`, `system-prompt delta`, `tool allowlist`, SPEC-013 line 36), prompt template file list, report path rules (line 89, 96, 97), index.json schema and atomic-write contract (line 98–102, 107), per-shape gate/feedback rules (line 105, 135). Cross-reference the T1 spike report for hook contract.
- **ACs**:
  - SPEC-013 MUSTs lines 24–30 (command shape) documented as CLI contract
  - SPEC-013 MUSTs lines 33–37 (engine architecture) documented
  - SPEC-013 MUSTs lines 40–44 (output shapes) documented
  - SPEC-013 MUSTs lines 89–102 (report + index) documented
  - SPEC-013 MUSTs lines 118–124 (task-id plumbing) documented
  - Deferred-scope fail-loud behavior explicitly called out for `--plan` and `--from-retro`
  - No implementation code in this file (doc only)

#### TASK 3: `skills/council/index-writer.sh`
- **agent**: ic4
- **depends_on**: none (parallel with T2; can start immediately)
- **files**: `skills/council/index-writer.sh` (new, ~80–120 lines)
- **exposes**: `append_index_entry "$INDEX_PATH" "$TASK_ID" "$REPORT_PATH" "$MAX_VERDICT_CONF" "$MAX_FINDING_CONF" "$CREATED_AT"` — atomic, `flock`-protected, tmp+rename.
- **description**: Pure shell helper that appends one row to `.claude/council/index.json` for a given `task_id`. MUST use tmp-file + `mv` (rename) for atomicity per SPEC-013 line 101. MUST use `flock` on a lock file to serialize concurrent writers. MUST handle missing index file (create empty `{}` first). MUST preserve newest-first per-task ordering. MUST accept `null` for either confidence field and serialize correctly. Uses `jq` for JSON manipulation (list `jq` dependency in the SKILL.md).
- **ACs**:
  - SPEC-013 line 98 — single JSON document shape `{"<task_id>": [ {...}, ... ], ...}`
  - SPEC-013 line 99 — append-only per task_id, newest first, never mutated in place
  - SPEC-013 line 101 — atomic tmp+rename
  - SPEC-013 line 102 — `finding[]` rows populate `max_finding_confidence` and set `max_verdict_confidence: null`
  - Concurrent invocation test: 10 parallel calls produce exactly 10 rows, no corruption

#### TASK 4: `agents/council-judge.md`
- **agent**: ic4
- **depends_on**: none (parallel)
- **files**: `agents/council-judge.md` (new, ~100 lines)
- **exposes**: A judge agent identity the engine will invoke via subagent dispatch.
- **description**: Create the new judge agent file. YAML frontmatter MUST declare `tools: ""` (empty allowlist, SPEC-013 line 80, 86). Body MUST mirror the `agents/tech-lead.md` cortex/memory/directives load pattern (read `tech-lead/directives.md`, `tech-lead/cortex`, `tech-lead/memory`, `tech-lead/lessons`, worktree-local `tech-lead/context.md`) so the judge inherits project context without duplicating storage. System-prompt body MUST state the Phase 5 judgment contract: receive evidence bundles + prosecutor + advocate briefs + original claims; emit either `verdict[]` (taxonomy: `VERIFIED | PARTIALLY_VERIFIED | UNVERIFIED | CONTRADICTED | FABRICATED`) or `finding[]` (severity: `critical | warning | nitpick`) depending on declared shape; require 0–100 confidence; MUST strike any line missing an inline raw tool output blob (SPEC-013 lines 82–86).
- **ACs**:
  - YAML frontmatter `tools: ""` (empty string, not missing)
  - Cortex inheritance from `tech-lead/` paths (NOT a duplicated cortex file)
  - Body references both output shapes with their fixed taxonomies
  - Strike-unsupported-lines rule present (SPEC-013 line 85)

#### TASK 5: `.claude/tasks/` store helper library
- **agent**: ic4
- **depends_on**: none (parallel)
- **files**: `skills/orchestrate/task-store.sh` (new, ~100 lines)
- **exposes**: `task_store_write "$TASK_ID" "$SUBJECT" "$REQUIRES_COUNCIL" "$STATUS"` — atomic per-task JSON writer consumed by `skills/orchestrate/SKILL.md` and (read-only) by `task-completed.sh`.
- **description**: Pure shell helper that writes `$MROOT/.claude/tasks/<task_id>.json` with schema from SPEC-009 line 48: `{task_id, subject, requires_council, created_at, status}`. MUST resolve `$MROOT` worktree-aware (SPEC-009 line 52). MUST use tmp+rename atomic write (SPEC-009 line 51). MUST create `.claude/tasks/` if absent (line 48). MUST preserve existing fields on update (line 49 — only `status` changes on TaskUpdate). MUST NOT delete the file (line 50).
- **ACs**:
  - Worktree-aware `$MROOT` resolution from `git rev-parse --git-common-dir`
  - Atomic tmp+rename write
  - Update-preserves-fields verified by shellcheck + manual round-trip test
  - `.claude/tasks/` directory auto-created on first write

---

### Phase 2 — Engine body (parallel branches)

#### TASK 6: `skills/council/engine.sh` — scope parser + task-id fallback + orchestration driver
- **agent**: ic5
- **depends_on**: [Task 2, Task 3]
- **files**: `skills/council/engine.sh` (new, est 400–700 lines)
- **exposes**: `engine.sh <scope-args>` — the single entry point `commands/council.md` and `skills/review-commit/SKILL.md` both call. Produces a report file + index entry + stdout summary.
- **description**: Implementation of the engine protocol doc from T2. Parses CLI args; resolves task-id via fallback chain (T2 contract); dispatches to scope-specific intake (single-claim, session slice, diff); calls into prompt-template assembly (T7); orchestrates investigator → prosecutor/advocate → judge subagent spawning via Task tool with `subagent_type: "general-purpose"` (or `"Explore"` for code-heavy claims); collects evidence bundles; writes report file (branched on output shape — T8); calls `index-writer.sh` (T3) when task-bound; prints stdout summary. MUST fail loudly on `--plan` and `--from-retro` with "not implemented in COUNCIL-001, planned for COUNCIL-002" and exit non-zero (locked decision 8). MUST refuse to run with no scope argument (SPEC-013 line 30). Soft LOC target 700; if exceeding, split evidence-collection into a sidecar script.
- **ACs**:
  - SPEC-013 line 24–30 command-shape arg parsing (all flags recognized)
  - SPEC-013 line 30 no-scope failure is loud (non-zero exit, stderr message)
  - SPEC-013 lines 46–52 Phase 1 claim extraction dispatch (claims budget default 10)
  - SPEC-013 lines 55–60 investigator spawn: ≥2 per claim with distinct flavors, read-only tool allowlist, no narrative passed
  - SPEC-013 lines 72–76 prosecutor + advocate spawn on evidence bundles only
  - SPEC-013 lines 79–86 judge dispatched via `council-judge` agent (not `tech-lead`)
  - SPEC-013 lines 118–124 task-id fallback chain
  - Deferred-scope fail-loud verified: `engine.sh --plan foo.md` exits non-zero with required message
  - Deferred-scope fail-loud verified: `engine.sh --from-retro abc` exits non-zero with required message

#### TASK 7: Prompt templates + tribunal flavor files
- **agent**: ic5
- **depends_on**: [Task 2]
- **files**:
  - `skills/council/prompts/claim-extractor.md`
  - `skills/council/prompts/investigator.md`
  - `skills/council/prompts/prosecutor.md`
  - `skills/council/prompts/advocate.md`
  - `skills/council/prompts/judge.md`
  - `skills/council/flavors/paranoid-ic.md`
  - `skills/council/flavors/jaded-senior.md`
  - `skills/council/flavors/yolo-ic.md`
- **exposes**: Prompt templates the engine injects into Task-tool subagent prompts. Flavor files follow the schema from T2 (`name`, `system-prompt delta`, `tool allowlist`).
- **description**: Author the five role prompt templates and three tribunal flavor files. Templates are Markdown with `{{VARIABLE}}` placeholders that `engine.sh` substitutes. `investigator.md` MUST enforce: read-only tool allowlist, no narrative passed, returns evidence bundle with `tool_use_id`, raw blob, `file:line`, reproducible command (SPEC-013 lines 56–59). `prosecutor.md` + `advocate.md` MUST enforce: operate on evidence bundles NOT original claims; any factual assertion without an investigator `tool_use_id` is struck (lines 74–76). `judge.md` MUST enforce both output shapes with fixed taxonomies + strike-unsupported rule (lines 82–86). `claim-extractor.md` MUST produce structured `{claim, source_locator, claim_type}` records (lines 50–52). Flavor files are each <60 lines.
- **ACs**:
  - SPEC-013 line 36 flavor schema observed (name / system-prompt delta / tool allowlist)
  - SPEC-013 line 56 investigator is read-only
  - SPEC-013 lines 58–59 evidence bundle contract encoded
  - SPEC-013 line 60 paranoid-ic + one other distinct flavor (jaded-senior or yolo-ic can pair)
  - SPEC-013 line 76 strike-rule enforced in prosecutor + advocate prompts
  - SPEC-013 line 82–83 dual-taxonomy enforced in judge prompt

#### TASK 8: Report templates
- **agent**: ic4
- **depends_on**: [Task 2]
- **files**:
  - `skills/council/templates/report-verdict.md`
  - `skills/council/templates/report-finding.md`
- **exposes**: Two report templates the engine renders — one per output shape.
- **description**: Two Markdown templates with `{{VARIABLE}}` substitution slots. `report-verdict.md` MUST include scope, extracted claims, investigator flavors, evidence bundles, prosecutor brief, advocate brief, per-claim verdict with confidence and raw evidence, verdict summary by taxonomy (SPEC-013 line 90–91); frontmatter MUST support optional `task_id` field (line 96). `report-finding.md` MUST use finding[] schema with severity summary (line 91), no verdict taxonomy. Both templates MUST surface struck lines as a visible audit trail (SHOULD line 145 — treat as hard AC for COUNCIL-001).
- **ACs**:
  - SPEC-013 line 90 report contents list covered
  - SPEC-013 line 91 branching by shape
  - SPEC-013 line 96 `task_id` frontmatter field optional
  - Struck-lines audit-trail section present in both

#### TASK 9: Diff-mode preset + 5 specialist flavor files
- **agent**: ic5
- **depends_on**: [Task 2]
- **files**:
  - `skills/council/flavors/diff-mode.md`
  - `skills/council/flavors/logic.md`
  - `skills/council/flavors/security.md`
  - `skills/council/flavors/compliance.md`
  - `skills/council/flavors/quality.md`
  - `skills/council/flavors/simplification.md`
- **exposes**: The diff-mode preset bundle `skills/review-commit/SKILL.md` will select.
- **description**: Create the diff-mode preset and migrate the 5 specialist prompt bodies from the current `skills/review-commit/SKILL.md` (lines 60–113) into flavor files, preserving exact focus bullets so the snapshot test in T13 can pass. `diff-mode.md` MUST declare `output_shape: finding[]`, 80-confidence filter at emission (SPEC-013 line 44), spec-grep intake producing applicable-specs bundle (line 48, SPEC-010 line 31), feedback-memory OFF (SPEC-013 line 105, SPEC-010 line 28), tool_use_id required on findings (SPEC-013 line 43). Each specialist flavor file follows T7's flavor schema and contains ONE of the 5 focus bullet-lists.
- **ACs**:
  - SPEC-013 line 40–44 finding[] shape declared
  - SPEC-013 line 105 feedback-memory OFF
  - SPEC-010 line 20 5-specialist list matches
  - SPEC-010 line 24 80-confidence threshold
  - SPEC-010 line 26 no-hedging + file:line enforced in flavor bodies
  - Specialist bullet content byte-matches the current SKILL.md focus sections (needed for T13 snapshot)

#### TASK 10: `task-completed.sh` council gate logic
- **agent**: ic4
- **depends_on**: [Task 1, Task 3, Task 5]
- **files**: `.claude/hooks/task-completed.sh` (modified, current 22 lines → est 120–160)
- **exposes**: The TaskCompleted hook that SPEC-002 lines 22–37 + SPEC-013 line 122 define.
- **description**: Extend the existing hook. Preserve plugin/marketplace JSON validation as-is (lines 6–12). Add: worktree-aware `$MROOT` resolution (SPEC-002 line 23); resolve task id from `CLAUDE_TASK_ID` (authoritative) with optional stdin JSON payload as secondary per T1 spike result (lines 27–28); read `$MROOT/.claude/tasks/<task_id>.json`; if missing → silent no-op pass (line 24); if `requires_council: false`/absent → silent no-op pass (line 25); if `requires_council: true` → query `$MROOT/.claude/council/index.json`, ignore rows where `max_verdict_confidence` is null (finding[]-shape), apply `council.taskgate.min_confidence` (default 80), pass if any qualifying row (lines 26, 30, 31), else hard-fail exit 2 with distinct stderr messages per failure mode (lines 32–36). MUST NOT scan `.claude/council/*.md` (line 29). MUST NOT invoke `/council` (line 29).
- **ACs**:
  - Existing plugin JSON validation still passes existing tests
  - SPEC-002 line 23 `$MROOT` via `git rev-parse --git-common-dir`
  - SPEC-002 line 24–25 silent no-op paths
  - SPEC-002 lines 32–36 five distinct hard-fail stderr messages
  - SPEC-013 Test 9 steps 7–9 pass when run manually
  - Contract matches T1 spike findings

#### TASK 11: Orchestrate — `CLAUDE_TASK_ID` export + task-store writes
- **agent**: ic4
- **depends_on**: [Task 5]
- **files**: `skills/orchestrate/SKILL.md` (modified)
- **exposes**: The ambient task-id transport and per-task metadata side-effects SPEC-009 lines 46–52 require.
- **description**: Add two pieces of orchestration behavior. (1) Whenever orchestrator spawns an agent or invokes `/council` as a step, MUST export `CLAUDE_TASK_ID=<task_id>` in the subprocess env (SPEC-009 line 46). (2) On every `TaskCreate`, call `task_store_write` (T5) with `requires_council` from task metadata (default false); on every `TaskUpdate` status transition, call `task_store_write` again updating only `status` (line 48–49). Document the atomic-write guarantee and the never-delete rule (lines 50–51). Worktree-aware `$MROOT` (line 52).
- **ACs**:
  - SPEC-009 line 46 `CLAUDE_TASK_ID` export documented as a MUST in orchestrate SKILL
  - SPEC-009 line 48 TaskCreate writes metadata file
  - SPEC-009 line 49 TaskUpdate updates status only, preserves other fields
  - SPEC-009 line 50 never-delete rule documented
  - SPEC-009 line 51 atomic write referenced (delegated to T5 helper)

#### TASK 12: `commands/council.md` thin wrapper
- **agent**: ic4
- **depends_on**: [Task 6]
- **files**: `commands/council.md` (new)
- **exposes**: The user-facing `/council` slash command.
- **description**: Thin command file with YAML frontmatter (per AGENTS.md conventions — `name`, `description`, allowed-tools if needed). Body delegates directly to `skills/council/engine.sh` with passthrough args. MUST NOT re-implement any engine logic inline (SPEC-013 line 34). Must pass through `--task-id` and inherit `CLAUDE_TASK_ID` from env. File should be <80 lines.
- **ACs**:
  - SPEC-013 line 34 thin-wrapper only
  - YAML frontmatter present + valid (AGENTS.md rule)
  - All CLI args from T6 passthrough without modification
  - `--plan` and `--from-retro` fail-loud messages bubble up unchanged

---

### Phase 3 — Integration

#### TASK 13: Refactor `skills/review-commit/SKILL.md` to delegate to engine
- **agent**: ic5
- **depends_on**: [Task 6, Task 9, Task 12]
- **files**: `skills/review-commit/SKILL.md` (modified — refactor from 250-line text spec to thin caller)
- **exposes**: The single canonical `/review-commit` path, now backed by the council engine in diff-mode.
- **description**: Rewrite SKILL.md to delegate to the council engine with `preset: diff-mode` (SPEC-010 line 18). MUST NOT carry a parallel adversarial pipeline (line 19). Specialists MUST be loaded as flavor presets (line 20, already authored in T9). Optional path argument behavior: engine writes canonical `.claude/council/<date>-<slug>.md`, review-commit copies that file to the user-supplied path after engine returns (line 32). Includes: snapshot test fixture (canned staged diff under `skills/review-commit/fixtures/canned-diff.patch` + `expected-output.txt`) and a script that runs review-commit pre-refactor (on a git stash of old SKILL.md) and post-refactor and byte-compares user-visible sections. Snapshot test passing is a hard AC.
- **ACs**:
  - SPEC-010 lines 18–32 all satisfied
  - Snapshot test: canned diff → byte-identical user-visible sections pre/post refactor
  - LOC reduction: refactored SKILL.md ≤ 80 lines (was 250)
  - No mention of inline sub-agent spawn in the refactored file — all engine-delegated

#### TASK 14: `/retro` fabrication anchor + `/council --from-retro` hint
- **agent**: ic4
- **depends_on**: [Task 12]
- **files**: `commands/retro.md` (modified), `skills/retro-subagent/SKILL.md` (modified)
- **exposes**: The `/retro` → `/council` integration hint SPEC-012 line 72 + line 104 require.
- **description**: Add phase-2 classification of `fabrication_anchor` findings with `{turn_id, claim_text, anchor_id}` (SPEC-012 line 72). At retro completion, print `Consider: /council --from-retro <anchor-id>` for each detected anchor (line 104). MUST be a plain suggestion — no auto-invoke (SPEC-013 line 114). Dedupe hints per anchor-id. Since `/council --from-retro` is deferred in COUNCIL-001, the hint will print but running it will fail-loud from T6 — that is the correct, locked-decision-8 behavior; document it in the retro SKILL so users aren't surprised.
- **ACs**:
  - SPEC-012 line 72 classification present
  - SPEC-012 line 104 hint printed per anchor at completion
  - No auto-invoke
  - Dedup per anchor-id
  - Documented: running the hinted command will fail-loud in v0.18.0

#### TASK 15: `.gitignore` + end-to-end smoke test
- **agent**: qa
- **depends_on**: [Task 13, Task 14]
- **files**: `.gitignore` (modified), `.claude/plans/2026-04-09-COUNCIL-001-smoke-test.md` (test log)
- **exposes**: A reviewed, recorded pass on SPEC-013 Tests 1, 3, 4, 5, 6, 9. Validates the dogfood gate.
- **description**: Add `.claude/council/` and `.claude/tasks/` to `.gitignore` (SPEC-013 validation checkbox line 226). Execute and log the following SPEC-013 test sections: Test 1 (single-claim audit + FABRICATED verdict + feedback memory write), Test 3 (judge tool-allowlist empty), Test 4 (evidence-or-silence enforcement), Test 5 (`/review-commit` engine share — runs the T13 snapshot), Test 6 (`/retro` hint), Test 9 (task-bound gate — all 12 sub-steps). Deferred tests (2 blind investigator, 7 budget, 8 domain specialist) are NOT run in COUNCIL-001 — note as skipped for COUNCIL-002. Log each step + expected vs actual in the smoke-test plan file. FAIL = re-open the relevant Phase 2/3 task.
- **ACs**:
  - `.claude/council/` and `.claude/tasks/` in `.gitignore`
  - SPEC-013 Test 1 pass
  - SPEC-013 Test 3 pass
  - SPEC-013 Test 4 pass
  - SPEC-013 Test 5 pass (snapshot byte-identical)
  - SPEC-013 Test 6 pass
  - SPEC-013 Test 9 all 12 sub-steps pass
  - Deferred tests explicitly marked SKIPPED-COUNCIL-002 in the log

---

### Phase 4 — Release

#### TASK 16: Version bump + changelog + README `/council` section
- **agent**: devops
- **depends_on**: [Task 15]
- **files**:
  - `.claude-plugin/plugin.json`
  - `.claude-plugin/marketplace.json`
  - `README.md`
- **exposes**: A shippable v0.18.0.
- **description**: Bump version 0.17.2 → 0.18.0 across plugin.json + marketplace.json per SPEC-002 version sync (lines 15–17). Add README changelog entry under `## Changelog` at top (AGENTS.md release style: terse `## v0.18.0 — <slug>` heading, grouped bullets, no ticket IDs in subject). Add a new README `## /council` documentation section (command shape from SPEC-013 line 24–30; brief one-paragraph description of the engine; link to `skills/council/SKILL.md`; note deferred scopes). Verify version files parseable (SPEC-002 validation lines 68–70). Commit style MUST match project convention: `chore: release v0.18.0 — adversarial council core` (per `MEMORY.md` feedback_commit_style).
- **ACs**:
  - Version string semantically identical across all three files (no `v` prefix in JSON, `v` prefix in README heading)
  - Changelog grouped bullets, no file lists
  - README `/council` section present with command-shape table
  - Both JSON files parse (`python3 -c 'import json; json.load(open(...))'`)
  - Commit message matches project terse style
  - TaskCompleted hook (now with council gate logic from T10) passes on the release commit

---

## Dogfood gate — when the TaskCompleted council gate becomes real

The hook code from T10 is committed as soon as T10 lands, but no task in this plan carries `requires_council: true` — we are not gating ourselves during bring-up. The canonical dogfood moment is T15, which runs SPEC-013 Test 9 end-to-end and proves the hook gates correctly on a real task-bound run. Only after T15 passes should any future ticket opt into `requires_council: true`.

Required-green-before-gate-enable: **T1, T3, T5, T6, T7, T8, T10, T11, T12** (every task on the hook's read path + the engine's write path).

## Spec holes found

None. SPEC-013 + SPEC-002 + SPEC-009 + SPEC-010 + SPEC-012 compose cleanly at the MUST level for the COUNCIL-001 scope. The only pre-existing open question (SPEC-002 line 76 — TaskCompleted stdin payload shape) is explicitly resolved by T1's spike; no re-design needed.

## Task Map (created 2026-04-09)

| # | Title | Agent | Depends on | Phase |
|---|---|---|---|---|
| 1  | TaskCompleted hook contract spike        | ic5    | —          | Foundation |
| 2  | skills/council/SKILL.md protocol doc     | ic5    | 1          | Foundation |
| 3  | skills/council/index-writer.sh           | ic4    | —          | Foundation |
| 4  | agents/council-judge.md                  | ic4    | —          | Foundation |
| 5  | .claude/tasks/ store helper library      | ic4    | —          | Foundation |
| 6  | skills/council/engine.sh                 | ic5    | 2, 3       | Engine body |
| 7  | Prompt templates + 3 tribunal flavors    | ic5    | 2          | Engine body |
| 8  | Report templates (verdict + finding)     | ic4    | 2          | Engine body |
| 9  | Diff-mode preset + 5 specialist flavors  | ic5    | 2          | Engine body |
| 10 | task-completed.sh council gate logic     | ic4    | 1, 3, 5    | Engine body |
| 11 | Orchestrate CLAUDE_TASK_ID + task-store  | ic4    | 5          | Engine body |
| 12 | commands/council.md thin wrapper         | ic4    | 6          | Engine body |
| 13 | Refactor review-commit to engine delegate| ic5    | 6, 9, 12   | Integration |
| 14 | /retro fabrication anchor + hint         | ic4    | 12         | Integration |
| 15 | .gitignore + smoke test                  | qa     | 13, 14     | Integration |
| 16 | Release v0.18.0                          | devops | 15         | Release |

Tasks created via TaskCreate with IDs 1–16 matching the task numbers above.
