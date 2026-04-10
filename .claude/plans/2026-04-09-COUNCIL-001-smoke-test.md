# COUNCIL-001 Smoke Test Report

**Date:** 2026-04-09
**Tester:** qa
**Branch:** feat/COUNCIL-001-adversarial-council
**Scope:** SPEC-013 Tests 1, 3, 4, 5, 6, 9 deterministic portions; Tests 2, 7, 8 SKIPPED-COUNCIL-002

## Summary

39 deterministic structural and bash-engine checks run. **38 pass, 1 minor observation** (templates place `{{TASK_ID}}` in a comment line immediately below the frontmatter rather than strictly inside the `---` fenced YAML block; functionally equivalent — the engine's render step substitutes by string, not by YAML parse). No blocking issues. All engine subcommands, index writer, task store, and hook council gate behave per contract. LLM-driven phases (claim extraction, tribunal investigation, judge verdict) are deferred to the manual smoke procedure below.

## Deterministic test results

| #  | Check | Result | Notes |
|----|---|---|---|
| 1  | skills/council/SKILL.md exists + frontmatter `name: council`, description | PASS | |
| 2  | engine.sh executable + preflight/finalize/resolve-task-id/report-path dispatch | PASS | usage printed for unknown subcmd |
| 3  | commands/council.md frontmatter valid | PASS | name, description, argument-hint present |
| 4  | agents/council-judge.md frontmatter `tools: ""`, `model: opus` | PASS | |
| 5  | 5 prompt files present (claim-extractor, investigator, prosecutor, advocate, judge) | PASS | |
| 5  | 3 tribunal flavor files present (paranoid-ic, jaded-senior, yolo-ic) | PASS | |
| 6  | 6 diff-mode files present (diff-mode, logic, security, compliance, quality, simplification) | PASS | |
| 7  | report-verdict.md + report-finding.md templates present | PASS | |
| 8  | `engine.sh resolve-task-id --task-id abc` → `abc` | PASS | exit 0 |
| 9  | `CLAUDE_TASK_ID=xyz engine.sh resolve-task-id` → `xyz` | PASS | exit 0 |
| 10 | `engine.sh resolve-task-id` → empty line | PASS | exit 0 |
| 11 | `engine.sh report-path my-slug` → UTC-dated path | PASS | `2026-04-10-my-slug.md` (UTC correct, local 2026-04-09) |
| 12 | `engine.sh report-path my-slug --task-id 42` → suffix `--42.md` | PASS | |
| 13 | `preflight --scope plan ...` → exit 3 + COUNCIL-002 deferral msg | PASS | |
| 14 | `preflight --scope from-retro ...` → exit 3 | PASS | |
| 15 | `preflight` no scope → exit 2 + usage | PASS | |
| 16 | `engine.sh nonsense-subcommand` → exit 2 + usage | PASS | |
| 17 | index-writer creates entry (verdict shape 85/null) | PASS | |
| 18 | index-writer second entry (finding shape null/90), newest first | PASS | ordering verified |
| 19 | no leftover `.tmp` files after writes | PASS | atomic rename working |
| 20 | temp dir cleaned | PASS | |
| 21 | task-store create writes correct schema (task_id/subject/requires_council/created_at/status=pending) | PASS | |
| 22 | update-status preserves other fields | PASS | |
| 23 | duplicate create → exit 1 "task already exists" | PASS | |
| 24 | temp dir cleaned | PASS | |
| 25 | hook pass: max=85 ≥ threshold 80 → exit 0 | PASS | |
| 26 | hook block: threshold 90 > 85 → exit 2 "below threshold" | PASS | |
| 27 | hook: task_id not in task store → exit 0 silent (pre-gate task) | PASS | spec interpretation: task file absent = pre-gate |
| 27b| hook: requires_council=true but missing from index → exit 2 "no council verdict" | PASS | covers true "not in index" case |
| 28 | hook: requires_council=false → exit 0 silent | PASS | |
| 29 | hook: no stdin no env → exit 0 silent | PASS | |
| 30 | hook: env fallback (CLAUDE_TASK_ID only) → exit 0 | PASS | |
| 31 | hook regression: invalid plugin.json → exit 2 "is not valid JSON" | PASS | ran in tmp dir with corrupted copy |
| 32 | real .claude-plugin/plugin.json not touched | PASS | |
| 33 | all flavor files have valid YAML frontmatter | PASS | 9/9 |
| 34 | all prompt files have valid YAML frontmatter | PASS | 5/5 |
| 35 | templates have `{{TASK_ID}}` placeholder near frontmatter | NOTE | present in `[//]: #` comment line immediately below `---`, not inside fenced YAML. String-substitution render path unaffected. |
| 36 | 5 specialist flavors declare `output_shape[_constraint]: finding[]` | PASS | |
| 37 | 3 tribunal flavors declare roles (investigator/prosecutor/advocate) | PASS | |
| 38 | diff-mode declares `output_shape: finding[]` + `feedback_memory_enabled: false` | PASS | |
| 39 | agents/council-judge.md declares `tools: ""` (empty string, not list) | PASS | |

## SPEC-013 test mapping

- **Test 1** (single-claim audit + fabrication + feedback memory): partial — structural validation passed. Feedback memory enabled for verdict[]-shape; disabled for finding[]-shape (diff-mode) per contract. Full LLM smoke deferred to manual step 1.
- **Test 3** (judge cannot run tools): PASS structural — `tools: ""` verified in agents/council-judge.md.
- **Test 4** (evidence-or-silence strike rule): partial — documented in prompts/investigator.md + SKILL.md. LLM verification deferred to manual step 1-2.
- **Test 5** (/review-commit shares engine): PASS structural — review-commit delegates to council engine via diff-mode preset; full output parity deferred to manual step 3.
- **Test 6** (/retro fabrication hint): PASS structural — retro-subagent emits fabrication_anchors, commands/retro.md prints `/council --from-retro <id>` hint; the deferred command itself correctly fails loudly with exit 3 + COUNCIL-002 message (Test 14).
- **Test 9** (task-bound council gate): PASS deterministic — all 8 hook gate cases (25-32) pass. LLM-driven verdict generation (steps 1-6 of Test 9) deferred to manual step 1 with `--task-id`.

**SKIPPED — deferred to COUNCIL-002:**
- **Test 2** (blind investigator guarantee): requires real LLM Task subagent spawn; isolation is structurally enforced by engine's prompt bundling (no cross-investigator context), but end-to-end proof needs live run.
- **Test 7** (budget enforcement): requires real LLM claim extraction to exceed budgets; engine has budget knobs but their firing path is LLM-gated.
- **Test 8** (domain specialist routing): explicitly deferred to COUNCIL-002 per scope decision.

## Manual smoke procedure (for the user)

Run these to validate the LLM-driven path:

1. `/council "skills/council/index-writer.sh uses python for atomic writes"` — a false claim (the script uses bash + `jq` + `mv`, not python). **Expected:** FABRICATED verdict, confidence ≥70, lesson appended to `.claude/memory/claude/lessons.md` (feedback memory on for verdict[] shape).
2. `/council --session --last 20` after a session that contains a shaky assistant claim. **Expected:** claim extraction → parallel blind investigators → prosecutor/advocate briefs → judge verdict report in `.claude/council/YYYY-MM-DD-<slug>.md`.
3. `/review-commit` against a small staged diff. **Expected:** identical UX to pre-refactor — finding[] shape, severity triage, commit gate unchanged; internally now routed through council engine diff-mode preset.
4. `/retro` after a session with fabricated assistant claims. **Expected:** fabrication_anchors captured + hint `Consider: /council --from-retro <anchor-id>` printed. Running that command then exits 3 with COUNCIL-002 deferral message — which is the intended COUNCIL-001 behavior.
5. (Optional, Test 9 full) Create a task via orchestrate with `requires_council: true`, run `/council "<claim>" --task-id <id>`, then trigger the TaskCompleted hook. **Expected:** gate reads index, compares to `council.taskgate.min_confidence`, pass/block accordingly.

## Known issues / non-blocking observations

1. **Templates `{{TASK_ID}}` placement** (test 35): the placeholder lives in a `[//]: #` markdown comment line directly below the frontmatter `---` fence, not inside the YAML block. The engine's finalize path substitutes by string replacement, so this is functionally correct, but a strict reading of the Task 15 acceptance criterion ("placeholder in the frontmatter section") is ambiguous. Recommend: clarify criterion in SPEC-013 or move the placeholder line one row up into the YAML block in a follow-up polish commit. **Not blocking.**
2. **Test 27 ambiguity:** the spec line "Run with task_id not in index → exit 2" is ambiguous between (a) no task metadata file at all and (b) metadata file exists with `requires_council: true` but index has no row. The hook silently passes (a) — correct per SPEC-002 "pre-gate tasks pass silently" — and blocks (b) with exit 2 + "no council verdict". Both behaviors are correct; Test 27b was added to cover case (b) explicitly.
3. **UTC date drift:** `report-path` emits `2026-04-10` while local date is 2026-04-09. Intentional (SKILL.md specifies UTC) but worth noting for future users who might file a false bug report.

## Conclusion

**PASS WITH NOTES.** All 39 deterministic checks produce correct behavior. The single NOTE item (template placeholder placement) is cosmetic and does not affect engine correctness. The deterministic foundation for COUNCIL-001 is solid: engine dispatch, task store, index writer, hook gate, deferral messaging, and all structural contracts verified. **Recommend proceeding to Task 16 (v0.18.0 release)** after the user runs the 4-step manual smoke procedure above to validate the LLM-driven phases.
