# Slice 03: Council subsystem review

Reviewer slice: `slices/03-council.txt` (79 files). Read-only review. Every file was read in full; large files were read in chunks.

## Slice summary

- **What it is.** `/council` is an adversarial tribunal. `engine.sh preflight` emits a plan JSON. The orchestrating Claude then runs Phase 1 (extract), 2 (investigate), 3 (domain specialist), 2.5 (Borda cross-review), 4 (prosecutor and advocate) and 5 (the tool-less `council-judge`). `engine.sh finalize` renders a report and calls `index-writer.sh`, which feeds the SPEC-002 `requires_council` TaskCompleted gate. There is also an opt-in Workflow transport (`workflow.js`), a `--blind` multi-team peer-review path, an external CLI slot (`external-reviewer.sh`), and CDT-126 tier grading (`tier-grade.sh`).
- **Overall grade: C.** The deterministic core is solid and well tested: the tier grader, index atomicity, the tool_use_id strike packaging, and YAML/template-injection hardening. But the LLM-facing contract describes many checks that no code performs. Three examples: "engine-enforced" validation, the confidence filter, and Phase 7 feedback memory.
- **Biggest risk 1: the evidence-or-silence guarantee is mostly unenforced.**
  - The only mechanical check is that `tool_use_id` is a non-empty string.
  - A verdict outside the taxonomy, or one with an empty `evidence_blob`, passes finalize. It lands in the index with its confidence (verified: `BOGUS`@99 produced index row `max_verdict_confidence: 99`).
  - The gate uses the maximum confidence whatever the verdict, so a high-confidence `FABRICATED` verdict satisfies `requires_council`.
- **Biggest risk 2: the "blind, ≥2 distinct investigators" monoculture defense is weaker than documented.**
  - The generic preset's second investigator flavor (`jaded-senior`) tells the investigator it cannot use tools.
  - Several blind roles are spawned as memory-loading `ic4`/`ic5` team agents that have Write/Edit.
  - In `workflow.js`, the Borda cross-review attributes votes to the wrong bundles.
- **Biggest risk 3: the spec and the docs have drifted from the code.**
  - Phase 7 feedback memory (a SPEC-013 MUST) is not implemented anywhere, yet three docs say the engine does it.
  - Dozens of stale "SPEC-013 line N" citations.
  - The SKILL.md still references `commands/blind-review.md`, which does not exist.
- **Portability.** `index-writer.sh` uses `local -n` (bash ≥4.3) and `flock`, so task-bound finalize fails on stock macOS. `tier-grade.sh` uses `declare -A`, so on stock macOS it always fails closed to `full`. `sha256sum` appears in three places.
- **Test coverage.** The four council test scripts exist and pass locally (29/29, ALL PASS, ALL PASS, 47 OK). None of them runs in CI (`.github/workflows/smoke.yml`). `test-workflow-static.sh` aborts silently with rc=1 when `CLAUDE_CODE_VERSION` is set below 2.1.154, which is the case in this environment (2.1.42).
- **Token cost.** `commands/council.md` (72 KB) plus `SKILL.md` (69 KB) is about 35k tokens. The PDH one-liner appears 11 times and the model-map spawn boilerplate 6 times, verbatim.

## Per-file review

| File | Lines | Purpose (short) | Verdict | Findings (concise, with line numbers) |
|---|---|---|---|---|
| agents/council-judge.md | 50 | Tool-less Phase 5 judge agent | Minor | Frontmatter OK (`tools: ""`, model, effort). The verdict[] output contract (l.39) has no `claim_id`, so real reports render `### Claim ?:` (F-26). The "cortex MAY be prepended … not currently injected" text (l.18) is dead guidance. |
| agents/finder.md | 50 | Read-only fan-out investigator | Minor | Has the `SendMessage` tool (l.4) although it is "blind … do not coordinate" (l.39). l.46 says a caller "never widen[s] past read-only", but `prompts/investigator.md` widens it with cache writes (F-20). |
| commands/council.md | 1385 | `/council` dispatcher (tribunal + blind path) | Major | Broken Step 4 bash (l.1041-1047, F-19). `_COUNCIL_WORKFLOW_FLAG` is never set (l.418). `$ARTIFACTS_FILE`/`$EVIDENCE_FILE`/`$JUDGE_FILE` are never created. Finalize omits `--cross-review-*` (F-13). The blind path uses MROOT and gives an empty or wrong-tree file list from worktrees (l.1146-1160, F-7). l.1380 claims the engine runs Phase 7 (F-1). l.546/632 say "created in Step 1" but it is Step 2. `sha256sum` at l.550. `agent: build` in the frontmatter. PDH repeated 8× and model-map repeated 3× (F-30). |
| docs/commands/council.md | 197 | User docs for `/council` | Issue | Usage/arguments omit `--external`, `--why`, `--council-tier`. The example report slug `claim-the-retry-logic-in` (l.95) does not match the engine's `claim`. The sample stdout lacks the `verification_mode=` line. Notes l.182 promise feedback-memory writes that are unimplemented (F-1) and a <80 filter that is unimplemented (F-14). |
| skills/council/SKILL.md | 1307 | Engine protocol spec | Major | l.324 (Step 1.5 passes `--grading-reason`) contradicts command §1.5.1/1.5.5. l.597 says "MROOT worktree-aware" (it isn't). l.845-863 say taxonomy/blob/citation strikes are engine-enforced (they aren't, F-2). l.1090-1129 Phase 7 is not implemented (F-1). l.1153 flavors must be <60 lines, but 5 exceed. l.1166 says external.md is injected by the helper (it isn't). l.1184 "tier-triage `--diff` only" is stale. l.1224 `commands/blind-review.md` is missing. l.693 cross-reviewers "MUST NOT run tools" but are spawned as tool-bearing `finder`. SPEC line citations are stale throughout (F-17). |
| skills/council/check-template-vars.sh | 190 | Prompt var-set drift gate (used by /release) | Minor | Passes (rc=0). The `[A-Z_]+` regex (l.72,97,109) cannot see digit vars; engine uses `[A-Z0-9_]+`. A later `status=1` overwrites an earlier `status=2` (l.130 vs 145). Does not cover `workflow.js` var sets or report templates. The l.22 comment "tier-triage (--diff scope only)" is stale. |
| skills/council/engine.sh | 1478 | preflight/finalize scaffolding | Major | No taxonomy, blob or confidence-filter enforcement (l.1007-1031, F-2/F-14). No Phase 7 (F-1). A list-shaped judge crashes after the index write (l.1310 vs 901, F-11). A dict brief crashes (l.975-979, F-12). Non-unique slugs overwrite reports (l.297-313, F-15). `sed 's/^-\+//'` is GNU-only (l.306). `--scope bogus --preset generic` is accepted (l.259). `.finalize-meta.json` sidecars accumulate (l.1266). python3 is never dependency-checked. |
| skills/council/external-reviewer.sh | 421 | Optional codex/gemini investigator slot | Issue | Findings without `file:line` are silently dropped because jq `capture` yields empty (l.174-175, verified, F-25). `sha256sum` (l.135) under `set -e` breaks the "never hard-fail" promise where it is absent. Never reads `flavors/external.md`. `codex review --uncommitted` (l.278) reviews unstaged changes too, not the staged diff. |
| skills/council/fixtures/finalize-missing-tid/evidence-mixed.json | 37 | Strike fixture (bundles) | OK | Used by test-finalize-missing-tid.sh. |
| skills/council/fixtures/finalize-missing-tid/judge-all-struck.json | 34 | Strike fixture (all struck) | OK | Categories `quality`/`style` are not in any flavor's category set; harmless. |
| skills/council/fixtures/finalize-missing-tid/judge-mixed.json | 44 | Strike fixture (mixed) | OK | Category `correctness` is not in the flavor taxonomy (not validated anywhere). |
| skills/council/fixtures/finalize-missing-tid/plan-finding.json | 19 | finding[] plan fixture | Minor | Hard-coded `report_path: /tmp/...` (tests strip it; still a trap for manual use). |
| skills/council/fixtures/finalize-task-id/evidence.json | 8 | Minimal bundle fixture | OK | — |
| skills/council/fixtures/finalize-task-id/judge.json | 12 | Minimal verdict fixture | OK | Includes `claim_id`, which the real judge schema never emits (F-26). |
| skills/council/fixtures/finalize-task-id/plan-bound.json | 11 | Bound plan fixture | Minor | Hard-coded `/tmp` report_path. Only one flavor (below the ≥2 invariant, fine for a fixture). |
| skills/council/fixtures/finalize-task-id/plan-unbound.json | 11 | Unbound plan fixture | Minor | Same `/tmp` report_path. |
| skills/council/fixtures/finalize-tokens/tokens-full.json | 11 | Tokens fixture | OK | — |
| skills/council/fixtures/finalize-tokens/tokens-partial.json | 8 | Tokens fixture | OK | — |
| skills/council/fixtures/finalize-tokens/tokens-unavailable.json | 5 | Tokens fixture | OK | — |
| skills/council/fixtures/finalize-tokens/tokens-zeros.json | 8 | Tokens fixture | OK | — |
| skills/council/fixtures/from-retro-anchor.json | 9 | Retro anchor fixture | Minor | The test copies it into the real `$MROOT/.claude/retro/anchors/` and leaves it there (F-23). |
| skills/council/fixtures/parity/README.md | 49 | Manual parity procedure | Minor | Manual-only. No automated test uses the parity fixtures. |
| skills/council/fixtures/parity/false-claim.json | 8 | Parity fixture | Minor | Referenced only by the parity README (orphan to automation). |
| skills/council/fixtures/parity/mini-diff.patch | 9 | Parity fixture | Minor | Same: unused by any script. |
| skills/council/fixtures/parity/true-claim.json | 8 | Parity fixture | Minor | Same. |
| skills/council/fixtures/plan-scope-sample.md | 17 | --plan fixture | OK | Used by test-workflow-static.sh. |
| skills/council/fixtures/tier-grade/clear-high-files.numstat | 25 | Grader fixture | OK | — |
| skills/council/fixtures/tier-grade/clear-high-loc.numstat | 3 | Grader fixture | OK | — |
| skills/council/fixtures/tier-grade/clear-low-5-files.numstat | 5 | Grader fixture | OK | — |
| skills/council/fixtures/tier-grade/clear-low.numstat | 3 | Grader fixture | OK | — |
| skills/council/fixtures/tier-grade/empty.numstat | 0 | Grader fixture | OK | — |
| skills/council/fixtures/tier-grade/malformed-nonnumeric.numstat | 1 | Grader fixture | OK | — |
| skills/council/fixtures/tier-grade/malformed-notabs.numstat | 1 | Grader fixture | OK | — |
| skills/council/fixtures/tier-grade/middle-20-files.numstat | 20 | Grader fixture | OK | — |
| skills/council/fixtures/tier-grade/middle.numstat | 8 | Grader fixture | OK | — |
| skills/council/fixtures/tier-grade/quoted-path.numstat | 1 | Grader fixture | OK | — |
| skills/council/fixtures/tier-grade/sig1-frontmatter.numstat | 1 | Grader fixture | OK | — |
| skills/council/fixtures/tier-grade/sig1-spec-basename.numstat | 1 | Grader fixture | OK | — |
| skills/council/fixtures/tier-grade/sig1-specs-path.numstat | 1 | Grader fixture | OK | — |
| skills/council/fixtures/tier-grade/sig2-mode.numstat | 1 | Grader fixture | OK | — |
| skills/council/fixtures/tier-grade/sig2-mode.raw | 1 | Grader fixture | OK | — |
| skills/council/fixtures/tier-grade/sig2-shebang.numstat | 1 | Grader fixture | OK | — |
| skills/council/fixtures/tier-grade/sig3-fanin-clear-low.numstat | 2 | Grader fixture | OK | — |
| skills/council/fixtures/tier-grade/sig3-fanin.numstat | 8 | Grader fixture | OK | — |
| skills/council/fixtures/tier-grade/sig4-deletion-heavy-exec.numstat | 1 | Grader fixture | Minor | Covers only whole-file deletion (mode 100755→000000). There is no fixture for a content-only deletion on an unchanged 100755 file, which is exactly the case F-9 breaks. |
| skills/council/fixtures/tier-grade/sig4-deletion-heavy-exec.raw | 1 | Grader fixture | Minor | Same gap as above. |
| skills/council/fixtures/tier-grade/sig5-test-removal.numstat | 1 | Grader fixture | OK | — |
| skills/council/flavors/compliance.md | 120 | diff-mode compliance specialist | Issue | Over the 60-line cap. Invents rules (file >1k lines, PR 1k/2k caps, plugin.json/CHANGELOG sync, l.46-48), contradicting its own l.111 "MUST NOT flag a rule you invented". The "Return JSON array … nothing else" / "MUST suggest a fix" text contradicts investigator.md (F-24). |
| skills/council/flavors/diff-mode.md | 116 | "Preset" doc living in flavors/ | Issue | Orphan: grep shows no references. Contradicts SKILL l.244 "Presets are not files". Claims engine spec-grep and a <80 filter with strike (l.33-45, 79-82) that do not exist (F-14). The severity map has no nitpick band (l.73-77). `role: preset` is outside the flavor schema enum. |
| skills/council/flavors/external.md | 44 | External CLI flavor | Issue | l.15 says the helper injects it; `external-reviewer.sh build_prompt` never reads it (dead delta). |
| skills/council/flavors/jaded-senior.md | 48 | Prosecutor flavor (also used as Phase 2 investigator) | Major | The body says "You cannot Read, Grep, or Bash" (l.26), but the generic preset uses it as the 2nd Phase 2 investigator (engine.sh l.277, workflow.js l.389). F-4. |
| skills/council/flavors/logic.md | 89 | diff-mode logic specialist | Issue | Over 60 lines. Its output contract (raw JSON array, "MUST suggest concrete fix") conflicts with investigator.md (`{claim_id,evidence_bundles}`, "NEVER propose a fix"). F-24. |
| skills/council/flavors/paranoid-ic.md | 46 | Paranoid investigator flavor | OK | Consistent with investigator.md. |
| skills/council/flavors/quality.md | 98 | diff-mode design specialist | Issue | Over 60 lines. Category is `design`, not `quality`. Same output/fix contradiction (F-24). |
| skills/council/flavors/security.md | 108 | diff-mode security specialist | Issue | Over 60 lines. Its embedded bash runs `security-scan/scan.sh`, a side-effecting scan inside a "read-only" investigator. Same F-24 contradiction. |
| skills/council/flavors/simplification.md | 103 | diff-mode simplification specialist | Issue | Over 60 lines. "Dead code → critical" (l.52), and critical blocks the commit gate. "Most land as nitpick" conflicts with its 80-94/95-100 map. F-24. |
| skills/council/flavors/yolo-ic.md | 48 | Advocate flavor | OK | — |
| skills/council/index-writer.sh | 118 | Sole atomic writer of index.json | Issue | `local -n` (l.45, bash ≥4.3) and `flock` (l.100) fail on stock macOS, so every task-bound finalize exits 6 (F-8). Otherwise correct: validation, floor, prepend under lock. |
| skills/council/prompts/claim-extractor.md | 176 | Phase 1 extractor (session/diff) | Issue | Duplicate step "5." (l.115/118). "Validation rules (engine-enforced)" l.164-174 are not implemented anywhere, including the substring anti-fabrication check (F-16). No diff/candidate-finding output shape despite SKILL l.346. `un_audited` does not match the workflow schema's `unaudited`, and `behavioral` is not in the schema enum (F-22). |
| skills/council/prompts/cross-reviewer.md | 121 | Phase 2.5 ranker | Minor | Engine-enforced validation (l.112-118) is not implemented on the Task path. "NO TOOLS" (l.31), yet it is spawned as `finder`, which has tools. "Your own bundle" assumes 1 bundle per investigator. |
| skills/council/prompts/investigator.md | 177 | Phase 2 investigator | Issue | Cache-write exception (l.61-86) contradicts finder.md read-only. The shared cache also leaks peer reads and allows poisoning (F-20). `sha256sum` (l.76). Engine validation l.162-173 is unimplemented (F-16). Relies on the model reproducing real `tool_use_id`s, which is unverifiable (F-2). |
| skills/council/prompts/judge.md | 215 | Phase 5 judge prompt | Issue | Validation l.195-212 ("engine MUST reject … exit 7") is unimplemented. #6 contradicts the SKILL/engine strike-and-continue on empty tid (F-16). The verdict schema lacks `claim_id` (F-26). |
| skills/council/prompts/lens-reviewer.md | 89 | --blind lens reviewer | Minor | Its PROJECT_ROOT/FILE_LIST come from the MROOT bug (F-7). A full-project FILE_LIST is unbounded token cost. |
| skills/council/prompts/phase4-brief.md | 163 | Prosecutor/advocate | Issue | Returns a JSON object, but engine `format_brief` expects a string and crashes on a dict (F-12). Engine-enforced validation l.150-160 is unimplemented (F-16). "Tool allowlist empty", yet it is spawned as `ic5` with Write/Edit (F-10). |
| skills/council/prompts/plan-extractor.md | 158 | Phase 1 extractor (plan) | Minor | The `file:heading-path:line` locator is ambiguous when a heading contains `:`. The example itself (l.88 `Decision:sqlite`) does, and it omits the `###` marker that l.84 mandates. Validation is not implemented (F-16). |
| skills/council/prompts/quorum-analyst.md | 110 | --blind clusterer | OK | Consistent with the command B4 and the tier definitions. |
| skills/council/prompts/tier-triage.md | 182 | Middle-band triage | Minor | Says "read the actual diff content" (l.86), but it receives numstat only. "Strictly between bands" ignores the LOC-unavailable route to middle (tier-grade l.411-423). l.151 cites §1.5.1; should be §1.5.2. |
| skills/council/prompts/topic-classifier.md | 117 | Phase 3 topic classify | Minor | "Cheap … pass", yet it is spawned as `dev-team:ic4`, which loads project memory at session start (cost, plus blindness, F-10). |
| skills/council/prompts/unconstrained-reviewer.md | 73 | --blind unconstrained reviewer | Minor | Same MROOT/FILE_LIST concern (F-7). |
| skills/council/templates/report-finding.md | 149 | finding[] report template | Issue | Omits the evidence bundles, briefs and extracted claims that SKILL l.950-954 says both shapes MUST include. Asserts "Findings below confidence 80 were filtered" (l.112), which is false (F-14). DIFF_SUMMARY/APPLICABLE_SPECS are always empty. |
| skills/council/templates/report-verdict.md | 170 | verdict[] report template | Minor | l.147-148 assert strikes the engine never performs (F-2). The `COMPLETION_TIME` placeholder is always `N/A`. The `CROSS_REVIEW_STATUS` doc values ('RAN'/'BYPASSED') do not match what is emitted. Borda text (N−1) conflicts with the command's M=N−1. |
| skills/council/test-finalize-missing-tid.sh | 278 | CDT-178 strike regression test | OK | PASS=29 FAIL=0. Isolated repo. Not in CI (F-23). |
| skills/council/test-tier-engine.sh | 392 | Tier plumbing + index tests | Minor | ALL PASS. l.327-335 test jq expressions the engine no longer uses (it now uses Python `int()`), so they are tautological. The node block runs `workflow.js` from ROOT and writes a report into the real repo `.claude/council/`. Not in CI. |
| skills/council/test-tier-grade.sh | 520 | Grader tests | Minor | ALL PASS, thorough (real git ops, decoy attack). Missing a case for a content-only edit of an existing executable (CDT-132 path, F-9). shellcheck SC1007 at l.431 (intended `PATH=`). Not in CI. |
| skills/council/test-workflow-static.sh | 379 | Workflow/static ACs | Issue | rc=1 with no FAIL line when `CLAUDE_CODE_VERSION`<2.1.154: l.17 runs the probe under `set -e`. Verified with env 2.1.42; passes with `env -u CLAUDE_CODE_VERSION` (47 OK). Requires `rg` and `node`; if `rg` is absent, the l.10/l.12 negative checks false-pass. Writes into the real `$MROOT/.claude/retro/anchors` (l.65) and `.claude/council` (via the mock run). |
| skills/council/tier-grade.sh | 445 | CDT-126 deterministic grader | Issue | CDT-132 suppression (l.317-334) clears `exec_why` before signal 4, so a 40-line deletion in an unchanged 100755 file grades light (verified), against SPEC-013 l.228 (F-9). `declare -A` (l.130) means macOS bash 3.2 always fails closed. shellcheck SC2221/2222 at l.346 (patterns are spec-mandated, but `*test*` subsumes the others and over-matches `latest`/`attest`). |
| skills/council/workflow-probe.sh | 35 | Workflow capability probe | Minor | Correct. The version gate makes the workflow test environment-dependent (F-23). |
| skills/council/workflow-schemas.js | 193 | Workflow agent() schemas | Issue | `CLAIM_TYPES` lacks `behavioral` (l.17), the extractor's top-priority type. `unaudited` vs prompt `un_audited`. No diff-mode extraction schema (F-22). `struck_lines` objects render as Python dict reprs in the report. |
| skills/council/workflow.js | 723 | Workflow transport driver | Major | Borda label mismatch (l.477-480 vs l.197), no per-reviewer shuffle, all claims pooled under `claims[0]` (F-5). Fabricated self-verify bundles bypass exit 5 (l.432-444, F-6). No Phase 3, no `--external`, tokens not passed to `--tokens-file`, handoff dir never removed. `loadPrompt` substitutes sequentially (the injection class the engine fixed). Investigators/cross-reviewers use `ic4`, not `finder` (F-21). |

## Findings

**F-1 [P1] Phase 7 feedback memory is not implemented, yet three docs say it runs**
- **Where:** SKILL.md:1090-1129, commands/council.md:1380-1381, docs/commands/council.md:182. SPEC-013 l.421-427 is a MUST.
- **Evidence:** `grep -rn "fabricated_min\|unverified_min" --include=*.sh --include=*.md --include=*.js . | grep -v specs/` finds only SKILL.md:1101-1102. `engine.sh` contains no reference to `lessons`, `feedback` (other than the plan flag) or `adjust-agent`.
- **Impact:** The "learning loop" never writes, and users are told it does.
- **Fix:** Implement a post-render step in finalize, gated on `feedback_memory_enabled` and thresholds read from `.claude/settings.json`, that appends to `$MROOT/.claude/memory/claude/lessons.md`. Emit a "route via /adjust-agent" instruction on stdout for team-agent claims. Or mark Phase 7 DEFERRED in SPEC, SKILL, command and docs.

**F-2 [P1] Judge output is not validated; an out-of-taxonomy, blob-less verdict reaches the index**
- **Where:** engine.sh:1007-1031 and :1246-1250.
- **Evidence:** A judge output of `{"verdicts":[{"claim":"x","verdict":"BOGUS","confidence":99,"evidence_blob":""}]}` finalized with exit 0 and `Struck lines: 0`. Index row: `"max_verdict_confidence": 99`.
- **Contradicted by:** SKILL.md:845-863 ("MUST be rejected and struck"), judge.md:195-212, and report-verdict.md:147-148, which the report prints as though it happened.
- **Also:** The engine never checks that a finding's `tool_use_id` exists among the bundle ids, or that quoted text is a substring of a raw_blob.
- **Fix:** In finalize, strike any verdict where `verdict ∉ taxonomy`, `evidence_blob` is empty, `confidence ∉ [0,100]`, or `evidence_blob` is not a substring of some bundle `raw_blob`. Strike any finding where `severity ∉ taxonomy` or `tool_use_id ∉ {bundle ids}`. Compute max confidence over unstruck items only (this already happens for tid strikes).

**F-3 [P1, design risk, spec-conformant] The task gate treats confidence as a pass signal whatever the verdict**
- **Where:** engine.sh:1246-1250 computes `max(confidence)` across all verdicts. The init-orchestration hook (`skills/init-orchestration/SKILL.md` ~l.897-907) passes when that max ≥ `min_confidence`. This matches SPEC-002 l.52.
- **Impact:** A `FABRICATED`@95 or `CONTRADICTED`@95 audit of the task's own claim satisfies `requires_council`.
- **Fix (spec change):** Record `max_verified_confidence`, computed over VERIFIED and PARTIALLY_VERIFIED only, or a `worst_verdict` column, and have the gate fail when any verdict is CONTRADICTED or FABRICATED.

**F-4 [P1] The generic preset's second investigator is told it cannot use tools**
- **Evidence:** engine.sh:277 has `flavors='["paranoid-ic","jaded-senior"]'`; SKILL.md:263-264 says the same. `flavors/jaded-senior.md:26` says "You operate on evidence bundles ONLY. You cannot Read, Grep, or Bash." It is injected into investigator.md, which requires tool calls. workflow.js:389 does the same.
- **Impact:** The ≥2 distinct-investigator anti-monoculture rule is nominal. The second investigator returns nothing or conflicts with itself.
- **Fix:** Add a tool-using skeptic investigator flavor (e.g. `skeptic-ic`) for Phase 2. Keep `jaded-senior` for prosecution only. Update the preset, the light-tier table and the tests.

**F-5 [P1] `workflow.js` Borda cross-review attributes votes to the wrong bundles**
- **Evidence:** The reviewer block labels `others` (all bundles except the reviewer's own) sequentially: `labs[j]` at l.477-480. `bordaRank` maps a label to the global index, `lab.charCodeAt(0)-65` at l.197 ("labels are global A=0"). For reviewer `ri`, every label after its own position is shifted by one, so votes land on the wrong bundle and a reviewer can score its own bundle. `valid` (l.503) drops the reviewer index, so the mapping cannot be recovered.
- **Also:**
  - No per-reviewer shuffle (SKILL.md:689-691).
  - All claims' bundles are ranked together under `claims[0].claim` (l.483).
  - "Reviewers" are counted as bundles, not investigators (l.472).
- **Fix:** Build a per-reviewer `label→bundleIndex` map with a shuffle, keep it next to each result, and run cross-review per claim.

**F-6 [P1] The Workflow path fabricates evidence when investigators fail, bypassing exit 5**
- **Evidence:** workflow.js:432-444 returns a bundle with `tool_use_id: self-verify-${claimId}-${flavor}` and `raw_blob: "(self-verified) no investigator spawn …"`. That id passes the non-empty tid check, so `bundles.length` is never 0 and exit 5 is unreachable when all investigators fail.
- **Also:** The judge fallback at l.598-630 issues verdicts from those stubs.
- **Contradicts:** SKILL.md:484-485: "exit 5 … when evidence is empty and no self-verify path produced usable bundles". The comment at l.433 admits tools were not run.
- **Fix:** Return `{ok:false, exit_code:5}` when no real bundle exists. Make any self-verify step actually run tools (a Workflow agent step), not emit stub text.

**F-7 [P1] `--blind` reviews the wrong tree, or nothing, from a worktree**
- **Where:** commands/council.md:1146-1160 and 1185/1200 (`PROJECT_ROOT ← $MROOT`).
- **Evidence:** In a linked worktree, `git ls-files "$MROOT"` fails with "fatal: … is outside repository" (rc=128), which is hidden by `2>/dev/null`, so FILE_LIST is empty. With `--target`, the command falls back to `find "$MROOT/$TARGET"` over the main checkout. All plugin worktrees live at `.worktrees/<slug>`.
- **Also:**
  - `git ls-files <untracked path>` exits 0, so the `find` fallback never runs in the main tree.
  - `grep -v '.git/'` is an unescaped regex.
  - SKILL.md:597 wrongly calls MROOT "worktree-aware".
- **Fix:** Use `WTROOT` and `git -C "$WTROOT" ls-files -- "$TARGET"`, and fail loudly on an empty list. Keep MROOT only for the report path.

**F-8 [P1, portability] `index-writer.sh` cannot run on stock macOS**
- **Evidence:** `local -n _vc_ref="$1"` at l.45 needs bash ≥4.3 (macOS ships 3.2). `flock -x 9` at l.100 is not shipped on macOS.
- **Impact:** Under `set -e`, every task-bound finalize exits 6.
- **Related:** `tier-grade.sh:130` uses `declare -A`, so on macOS it always fails closed to `full`: safe, but tiering is disabled.
- **Fix:** Replace the nameref with `printf -v "$1"` or echo-and-capture. Add a `mkdir`-lock fallback when `flock` is absent (flock is used repo-wide, so this could be a shared helper).

**F-9 [P1] Tier grader suppresses signal 4 (deletion-heavy executable) for content-only deletions**
- **Evidence:** A scratch repo with numstat `0\t40\ttools/x` and raw `:100755 100755 … M\ttools/x` grades `tier: "light"`, `band: "clear-low"`, `critical_signals: []`.
- **Cause:** The CDT-132 block (tier-grade.sh:317-334) clears `exec_why` for same-mode edits under 100 LOC, and signal 4 (l.340) is keyed on `exec_why`.
- **Contradicts:** SPEC-013 l.228: "more than 30 deleted lines in a file matching signal 2". CDT-132 does not appear in SPEC-013.
- **Fix:** Evaluate signal 4 against the unsuppressed executable status (mode or shebang) before the CDT-132 relaxation, and add a fixture for this case.

**F-10 [P2] Blind and auditor roles run as memory-loading, write-capable team agents**
- **Evidence:** Phase 1 (`dev-team:ic4`), topic classifier (`ic4`), Phase 4 (`ic5`), blind reviewers and quorum analyst (`ic5`), and Phase 3 (`devops`/`ds`/`qa`/`pm`) are spawned as team agents (commands/council.md:486, 500, 675, 865, 882, 1180, 1193, 1219). `agents/ic5.md` has `tools: Read, Write, Edit, …` and a "Session start — load directives / read memory" block (l.141-180).
- **Impact:** Project memory, which can include prior council lessons, enters "blind" roles, and roles marked "tool allowlist empty" have Write/Edit plus a memory write-back habit.
- **Fix:** Add a tool-less, memory-less internal agent (like `council-judge`) for extractor, classifier, Phase 4 and quorum roles. Use `finder` for read-only roles.

**F-11 [P2] A top-level-array judge output crashes finalize after the report and index row are written**
- **Evidence:** A judge file `[{"claim":"x","verdict":"VERIFIED",...}]` gave: report written, then `jq: error … Cannot index array with string "verdicts"`, exit 5. The renderer accepts a list (engine.sh:901-902) but the stdout counters use `.verdicts // []` (l.1310-1314).
- **Impact:** A task-bound run has already written its index row. Exit 5 is misreported as "empty evidence", and cache cleanup is skipped.
- **Fix:** Normalize the judge file to object form right after repair, or use `(if type=="array" then . else .verdicts // [] end)`.

**F-12 [P2] A brief stored as JSON crashes finalize**
- **Evidence:** An evidence file with `"prosecutor_brief":{"briefs":[]}` gave `AttributeError: 'dict' object has no attribute 'strip'`, exit 1 (engine.sh:975-979).
- **Cause:** phase4-brief.md returns a JSON object, and command Step 4 never says to stringify it. Exit 1 is also missing from the exit table.
- **Fix:** Have `format_brief` accept a dict or list (render briefs, as workflow.js `briefToText` does). Document the evidence-file schema.

**F-13 [P2] On the Task path, Phase 2.5 results never reach the report**
- **Evidence:** The finalize invocation at commands/council.md:1041-1047 passes no `--cross-review-status/-rankings/-scores`. engine.sh:859-865 then renders "Phase 2.5 not run". The command itself says to store the rankings "for `{{CROSS_REVIEW_RANKINGS}}`" (l.841-843).
- **Fix:** Add the three flags to the Step 4 template.

**F-14 [P2] Diff-mode filter, spec-grep and report sections are documented but absent**
- **Confidence filter:** `confidence_filter_threshold: 80` is emitted in the plan (engine.sh:280, 450) and never applied. Findings below 80 render, count, and can BLOCK the commit gate (l.1091-1096).
- **Spec-grep:** "Phase 0 spec-grep" (SKILL.md:328-333, diff-mode.md:31-45) has no implementation. `APPLICABLE_SPECS` is always "_None matched._".
- **Diff summary:** `DIFF_SUMMARY` falls back to `scope_arg` (""), so the section is empty.
- **Template:** report-finding.md lacks the evidence bundles and briefs that SKILL.md:950-954 requires.
- **Fix:** Apply the threshold in finalize, moving sub-80 findings to struck with a reason. Either implement spec-grep in preflight or move it explicitly to the orchestrator. Add an evidence section to the finding template.

**F-15 [P2] Report filenames collide within a day**
- **Evidence:** Slugs are `claim`, `diff-staged` and `session[-last-N]` (engine.sh:297-313). Two unbound claim audits on the same day overwrite `…-claim.md`. Re-running the same task on the same day rewrites the file that the older index row still points to, so the history no longer matches.
- **Also:** docs/commands/council.md:95 and SKILL.md:879 promise `claim-<first-5-words>`.
- **Fix:** Add `-HHMMSS` or the `run_id` to the slug, or a slugged claim prefix plus a short hash.

**F-16 [P2] Prompts describe "engine-enforced" validation that no code performs, and some of it contradicts the engine**
- **Where:** claim-extractor.md:164-174, investigator.md:162-173, cross-reviewer.md:112-118, phase4-brief.md:150-160, judge.md:195-212.
- **Contradiction:** judge.md #6 says an empty `tool_use_id` means exit 7. SKILL.md:855-859 and test-finalize-missing-tid.sh assert strike-and-continue with exit 0.
- **Impact:** The model and the maintainers get false assurances.
- **Fix:** Rename these sections "orchestrator checks (not automated)", or implement them (see F-2). Delete the exit-7-on-empty-tid rule.

**F-17 [P2] Every "SPEC-013 line N" citation is stale**
- **Evidence:** `sed -n 56p` of SPEC-013 gives "### Council tiering *(CDT-126)*". SKILL.md cites that line as the blindness invariant. SPEC-013 is now 727 lines. The SKILL.md traceability table (l.1285-1303) and all prompts and flavors cite line numbers.
- **Fix:** Cite section anchors (e.g. "SPEC-013 § Phase 2") and drop line numbers.

**F-18 [P2] Stale or contradictory statements in SKILL.md**
- l.324 says Step 1.5 passes `--tier/--grading-reason`; command §1.5.1 and §1.5.5 say it doesn't.
- l.1184 and check-template-vars.sh:22 say tier-triage is "`--diff` scope only"; it is the ship gate now.
- l.1224 references `commands/blind-review.md`, which does not exist.
- l.1166 says external.md is injected by the helper; it isn't.
- l.1153 sets a <60-line flavor cap; logic (89), quality (98), simplification (103), security (108) and compliance (120) exceed it.
- The CLI table (l.185-202) omits `--council-tier`/`--tier`.
- **Fix:** Correct each item.

**F-19 [P2] The Step 4 finalize block in commands/council.md is not valid shell and references undefined variables**
- **Where:** commands/council.md:1041-1047.
- `--plan-file "$PLAN_FILE" \  # lint-ok: C1`: the backslash escapes a space, so the comment ends the command and the following lines run as separate commands.
- `[--task-id …]` is pseudo-syntax inside a plain ```bash fence (not ```bash template).
- `$EVIDENCE_FILE`, `$JUDGE_FILE` and `$ARTIFACTS_FILE` (l.638) are never created.
- `_COUNCIL_WORKFLOW_FLAG` (l.418) is never set anywhere.
- l.1039 builds a predictable `$$` path instead of using `mktemp`.
- **Fix:** Mark the block as a template, move the lint comment to its own line, show `mktemp` for each handoff file, and set `_COUNCIL_WORKFLOW_FLAG=1` in Step 0.5 when `--workflow` is parsed.

**F-20 [P2] The investigator cache protocol breaks read-only and blindness rules**
- investigator.md:61-86 lets Bash write under CACHE_DIR. finder.md:46 says callers may "never widen [rules] past read-only".
- A shared, writable `reads/` directory lets one flavor see, and poison, what another read. Cache-hit `cat` output becomes a new "tool_use_id" for bytes another agent produced.
- `sha256sum` is used at l.76 and commands/council.md:550.
- **Fix:** Have only the orchestrator seed the cache and give investigators read-only access, or drop the cache. Use a portable hash helper.

**F-21 [P2] The Workflow path lacks parity with the Task path**
- No Phase 3 (meta phases at l.38-46), yet the report says "ELIGIBLE (runtime classify)".
- `t.external` is ignored.
- Token usage is only `console.log`'d; no `--tokens-file` is passed, contrary to SKILL.md:543-546.
- Investigators and cross-reviewers use `agentType: 'dev-team:ic4'`; the Task path prefers `finder` (CDT-230).
- The `council-wf-*` handoff directory, which holds raw evidence, is never removed.
- `loadPrompt` (l.119-130) substitutes with a sequential `split/join`, the template-injection class that engine.sh:1185-1194 explicitly fixed.
- **Fix:** Close each gap, or document the Workflow path as a reduced tribunal.

**F-22 [P2] Workflow schemas conflict with the extractor prompts**
- workflow-schemas.js:17 has `CLAIM_TYPES = ['factual','causal','recommendation']`, but claim-extractor ranks `behavioral` highest (l.61, 106). A schema-forced extractor must mislabel it or fail.
- `unaudited` (l.36) does not match the prompts' `un_audited`.
- Diff-mode extraction (`{file,line,description}`) has no schema.
- **Fix:** Align the enum and key names, and add a candidate-finding schema.

**F-23 [P2] Council tests are not in CI, and one is environment-fragile and leaves artifacts**
- smoke.yml runs none of `test-*.sh`; only check-template-vars runs, and only in /release.
- test-workflow-static.sh:17 (`bash workflow-probe.sh` under `set -euo pipefail`) exits rc=1 after 5 OKs with no FAIL line when `CLAUDE_CODE_VERSION=2.1.42`.
- The tests depend on `rg` and `node`.
- They write into the real repo's `.claude/retro/anchors/` and `.claude/council/`. Artifacts from my runs remain there (gitignored); my attempt to delete them was blocked by the sandbox classifier.
- **Fix:**
  - Add the four scripts to smoke.yml.
  - Run the probe with `env -u CLAUDE_CODE_VERSION`, or treat a non-zero probe as info.
  - Run everything from an isolated temp repo (`cd "$TMP/repo"`).
  - Fall back from `rg` to `grep`.

**F-24 [P2] Diff-mode flavor bodies contradict the investigator prompt they are injected into**
- The flavors say "Return a JSON array of findings … nothing else" and "MUST suggest a concrete fix" (e.g. logic.md:52-82).
- investigator.md requires `{claim_id, evidence_bundles}` and "NEVER propose a fix".
- commands/council.md:536 says the investigator schema "wins", but the model receives both instructions in one prompt.
- **Fix:** Strip output-contract and fix language from the flavor deltas, keeping only the focus lens.

**F-25 [P2] `external-reviewer.sh` silently drops findings that have no location**
- **Evidence:** Two bullets, `- CRITICAL: sql injection in foo.py:12` and `- nit: rename variable (no location)`, produce only one finding. `capture(...) | .f // "unknown"` yields empty when there is no match, so the object is dropped (l.174-175).
- **Also:**
  - `flavors/external.md` is never loaded.
  - Missing `sha256sum` (l.135) exits non-zero despite the "never hard-fail" contract.
  - `codex review --uncommitted` (l.278) is broader than the staged `--diff` scope.
- **Fix:** Use `(capture(...) // {f:"unknown",l:"0"})`, read external.md into `build_prompt`, and add a hash fallback.

**F-26 [P3] Judge schema has no `claim_id`, so reports print `### Claim ?:`**
- judge.md, council-judge.md and VerdictSchema do not require it. Rendered reports show `### Claim ?: x`; verified at report line 138.
- **Fix:** Add `claim_id` to the judge output contract.

**F-27 [P3] Minor engine robustness gaps**
- `sed 's/^-\+//…'` is GNU-only (engine.sh:306; cosmetic on BSD).
- An explicit `--preset` skips scope validation (l.259-269), so `--scope bogus` is accepted.
- `shift 2` on a missing flag value exits silently under `set -e`.
- python3 is never dependency-checked.
- `.finalize-meta.json` sidecars accumulate in `.claude/council/` (l.1266).
- Reports are written with mode 0600 (`mkstemp`).
- `COMPLETION_TIME` is always `N/A`.

**F-28 [P3] Prompt nits**
- claim-extractor.md has a duplicate step "5." (l.115/118).
- In plan-extractor, headings containing `:` make the locator ambiguous, and the l.88 example violates l.84.
- tier-triage.md:86 promises "diff content" but supplies numstat only, ignores the LOC-unavailable middle route, and cites §1.5.1 where §1.5.2 is meant (l.151).
- compliance.md invents rules (l.46-48) against its own l.111. simplification.md makes dead code `critical` (commit-blocking).
- `finder` carries `SendMessage` despite "stay blind".

**F-29 [P3] Orphan and dead files**
- `flavors/diff-mode.md` has no references (grep) and contradicts "presets are not files".
- The parity fixtures are manual-only.
- test-tier-engine.sh:327-335 asserts jq pipelines the engine no longer uses.
- **Fix:** Delete or wire them up.

**F-30 [P3] Token cost and duplication**
- `commands/council.md` and SKILL.md total ~141 KB (~35k tokens).
- The 1.2 KB PDH one-liner appears 11×, and the 9-line model-map retry block 6× verbatim.
- The blind path and the §1.5.2-1.5.4 grading procedure (cited by another file) live inside the command.
- **Fix:** See E-6.

## Enhancement proposals

| # | Proposal | Effort | Impact |
|---|---|---|---|
| E-1 | Add a `validate_judge` step to finalize: taxonomy, confidence range, `tool_use_id ∈ bundle ids`, `evidence_blob` substring of a bundle `raw_blob`, and the diff-mode ≥80 filter. Invalid items go to struck. Fixes F-2/F-14/F-16 in one place. | M | High: makes evidence-or-silence mechanical |
| E-2 | Make the gate verdict-aware: add `max_verified_confidence` or `worst_verdict` to the index row and gate on it (SPEC-002/013 change). | M | High: stops FABRICATED@95 passing `requires_council` |
| E-3 | Implement Phase 7 in finalize (settings thresholds, lessons.md append, `/adjust-agent` hint), or formally defer it in SPEC and docs. | M | Med |
| E-4 | Fix Workflow Borda: per-reviewer shuffled label maps carried with results, per-claim cross-review, self-exclusion by investigator. Add a unit test with a known ranking. | S | High for Workflow users |
| E-5 | Add a tool-less, memory-less internal agent (e.g. `council-scribe`) for extractor, classifier, prosecutor/advocate and quorum. Use a tool-using skeptic flavor instead of `jaded-senior` in Phase 2. | M | High: restores blindness and ≥2 real investigators |
| E-6 | Put the model-map fence once in `skills/model-map` and reference it. Move §1.5.2-1.5.4 grading to `skills/council/tier-grading.md` and the blind path to `skills/council/blind.md`. Target: commands/council.md under 600 lines. | M | ~40-50% token cut per `/council` |
| E-7 | Add all four council tests to `smoke.yml`. Isolate test MROOT in a temp repo, `env -u CLAUDE_CODE_VERSION` for the probe, `rg`→`grep` fallback, and a signal-4 content-only fixture. | S | High: prevents regressions like F-9/F-11 |
| E-8 | Portability shim `skills/lib/portable.sh`: `sha256` (`sha256sum`/`shasum -a 256`), a lock (`flock` or `mkdir`), no namerefs or assoc arrays in the index path. | S | macOS support |
| E-9 | Unique report slugs (`<scope>-<HHMMSS>-<runid4>`) plus sidecar cleanup. | S | Integrity of index history |
| E-10 | Blind path: use `WTROOT`, `git -C "$WTROOT" ls-files -z -- "$TARGET"`, fail loudly on an empty list, and apply the lockfile/vendor excludes to `--target` too. | S | Correctness in worktrees |
| E-11 | Replace "SPEC-013 line N" with section anchors, and add a docs-drift check that forbids `SPEC-\d+ line \d+`. | S | Maintainability |
| E-12 | Make `format_brief` accept structured briefs, and publish a JSON schema for the evidence file that both transports write. | S | Removes F-12 class |
| E-13 | Generate `commands/council.md` substitution blocks and the SKILL var table from the prompts' `## Variables` tables, instead of drift-checking three copies. | M | Removes a whole drift class |

## Coverage attestation

- Files in slice list (`slices/03-council.txt`): **79**
- Rows in the Per-file review table: **79** (same order; verified by diff against the slice list)
- Every file was read in full. Large files were read in chunks: commands/council.md, SKILL.md, engine.sh, workflow.js, tier-grade.sh, all tests.
- Commands run for evidence:
  - `bash -n` on all 10 `.sh` files: all OK.
  - `shellcheck -S warning`: 3 warnings.
  - `node --check`: OK.
  - `check-template-vars.sh`: PASS.
  - test-finalize-missing-tid: 29/0.
  - test-tier-engine: ALL PASS.
  - test-tier-grade: ALL PASS.
  - test-workflow-static: rc=1 with env `CLAUDE_CODE_VERSION=2.1.42`; rc=0 (47 OK) with the var unset.
  - Ad-hoc scratch repro runs for F-2, F-7, F-9, F-11, F-12 and F-25.
