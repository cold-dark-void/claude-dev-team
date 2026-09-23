Backlog items for milestone **Wave 2 — Structural** of project P-CDT-30, generated from `docs/reviews/2026-09-23-full-review/backlog.json` (branch `claude/craft-loop-review-enhancement-4jq3wb`). These are written as a document because the workspace is at its free-plan issue limit; each item has everything needed to become an issue later.

46 items · High 12 · Medium 34

## Checklist

- [ ] `W2-01` [retro] Move retro's deterministic pipeline into scripts — High, L
- [ ] `W2-02` [memory] Split commands/memory.md into a router plus per-sub mode files — High, L
- [ ] `W2-07` [bug-hunt] Split bug-hunt SKILL.md into stage references; extract parse/load scripts — High, L
- [ ] `W2-08` [bug-hunt] Behavioural tests for parse-args and load scripts — High, M
- [ ] `W2-11` [council] Implement real finalize validation and the 80-confidence filter — High, M
- [ ] `W2-12` [council] Split jaded-senior: prosecutor only; add `adversarial-ic` investigator — High, S
- [ ] `W2-13` [council] Remove or tool-write the LLM-written investigator evidence cache — High, M
- [ ] `W2-14` [council] Workflow ↔ Task parity or explicit fallback — High, L
- [ ] `W2-16` [memory] Fix the tier-0 eclipse; add write read-back; cortex-load selects type — High, M
- [ ] `W2-17` [memory] Treat seed-pack imports as untrusted: tier 0, confirm, framing — High, M
- [ ] `W2-26` [privacy] umask 077, gitignore runtime dirs in user projects, redact mirrored secrets — High, M
- [ ] `W2-41` [debug] Define full-mode commit/land/exit and fix rule contradictions — High, M
- [ ] `W2-03` [spec] Router-ize commands/spec.md — Medium, M
- [ ] `W2-04` [council] Move tier-grading procedure and `--blind` path out of commands/council.md — Medium, M
- [ ] `W2-05` [epic] Split epic and kickoff SKILL.md monoliths into steps/ — Medium, L
- [ ] `W2-06` [init-orchestration] Move embedded hook bodies to shellcheck-able templates/*.sh — Medium, L
- [ ] `W2-09` [context] Resolve PDH once per invocation instead of ~210 pasted stanzas — Medium, M
- [ ] `W2-10` [agents] Shared agent preamble include; unify agent embed resolver with PDH — Medium, M
- [ ] `W2-15` [council] engine.sh / report rendering fixes (duplicate FINDINGS, empty sections) — Medium, S
- [ ] `W2-18` [memory] Seed-pack export/import fixes: trailer, line cap, dedupe, sanitizer — Medium, S
- [ ] `W2-19` [memory] Verify native extension hashes at `.load` time; harden downloader — Medium, M
- [ ] `W2-20` [security] Harden curl calls: timeouts, protocols, secrets off argv — Medium, S
- [ ] `W2-21` [memory] Use cosine distance for vec0 tables (or convert L2) and fix spec text — Medium, M
- [ ] `W2-22` [memory] memory-recall Step 4/5: define roots first, `grep -F`, per-fence vars — Medium, S
- [ ] `W2-23` [memory] Atomic migrate-v2 and pre-migration backup; migrate.sh fails loudly — Medium, S
- [ ] `W2-24` [memory] commands/memory.md P2/P3 fixes: config UPSERT, SOURCE_IDS, re-embed, nits — Medium, S
- [ ] `W2-25` [prompts] Untrusted-data framing and per-run nonce delimiters in all prompts — Medium, S
- [ ] `W2-27` [transcript-mirror] Stable overlay keys instead of ordinal turn ids — Medium, M
- [ ] `W2-28` [transcript] Shared mirrorlib for check-line, turn split, record identity, Grok mapping — Medium, M
- [ ] `W2-29` [retro] gate.sh scores the assembled (fork-deduplicated) timeline — Medium, M
- [ ] `W2-30` [temp] Clean up leaked temp dirs: council cache/wf, Grok copies, prepass temps — Medium, S
- [ ] `W2-31` [handoff] Harden precompact-capture: timeout, retention sort, temp cleanup, tests — Medium, S
- [ ] `W2-32` [transcript-parse] Fix discover-warm/helper drift: Grok .cwd, bridge freshness, sanitizing — Medium, S
- [ ] `W2-33` [orchestrate] steps/ cleanup: Step 9 TASK_ID, error handling, light-tier contradictions — Medium, S
- [ ] `W2-34` [epic] Persist seal-intent on resume; fail rather than diverge — Medium, S
- [ ] `W2-35` [release-train] Unblock path for blocked entries; safe atomic restore and lock — Medium, M
- [ ] `W2-36` [ci-watch] Cap poll errors, unique temp files, no premature green — Medium, S
- [ ] `W2-37` [audit] Harden audit apply: verify evidence, atomic batch, scope gate, 40 KB tier — Medium, M
- [ ] `W2-38` [doctor] doctor.sh correctness: worktree paths with spaces, safe --fix, marketplace tier — Medium, S
- [ ] `W2-39` [release] release/SKILL.md correctness pass: REF, tagless describe, resolver consistency — Medium, S
- [ ] `W2-40` [files] Fix mktemp+mv writes that leave repo files 0600 or non-atomic — Medium, S
- [ ] `W2-42` [code-simplify] Re-review simplify edits; safe revert; untracked scope — Medium, M
- [ ] `W2-43` [review-and-commit] Rebuild as `council --diff --tier full` + commit-gate post-step — Medium, M
- [ ] `W2-44` [commands] Fix cross-fence state: adjust-agent $AGENT, council COUNCIL_TIER/PLAN_FILE — Medium, S
- [ ] `W2-45` [commands] Implement or remove dead flags (memory, council, spec) — Medium, S
- [ ] `W2-46` [specs] Spec ownership registry; specs for /mode, /tdd-gate, domain-glossary — Medium, M

## Items

### W2-01 · [retro] Move retro's deterministic pipeline into scripts
**Priority** High · **Effort** L · **Labels** Tech Debt, Improvement · **Ticket group** —

**Problem**
`commands/retro.md` (87 KB, ~22k tokens, 1967 lines) embeds three large programs the LLM re-reads every run: Step 2 discovery (~260 lines), `parse_one` (~50) and the Jaccard classifier (~60), plus 12 PDH lines and 60 `lint-ok` pragmas. Cross-fence state bugs (P0-08) come from this shape. `parse_one` (`:909-916`) sanitizes only tabs — a newline in `proposed_text` splits the TSV row before Rule 3b, so a truncated proposal passes validation, and a tab in `pattern_summary` shifts columns (R10). Step 5b loads `RULES_PM..RULES_CLAUDE` via `load_rules_raw` and nothing reads them; 5c re-`cat`s the files (`:1171-1189,1231-1238`), with a stale note at `:772-774` (R7).

**Fix**
- `skills/retro-gate/discover.sh` (Steps 1–2d → gate-feed paths + counters JSON), `parse-results.py` (4d parse/validate/anchor persist with full sanitization), `classify.py` (5a–5e incl. the repeat-filter fix), reuse `scheduled-run.sh`.
- retro.md becomes ~350 lines of orchestration/UI; delete dead 5b loads.

**Acceptance**
- Behavioral tests for each script with fixtures (newline/tab injection rejected).
- retro.md < 25 KB.
- scheduled-retro and retro-gate tests pass.

**Source**
- [03-large-commands.md](03-large-commands.md) #E4
- [03-large-commands.md](03-large-commands.md) #R7
- [03-large-commands.md](03-large-commands.md) #R10
- [03-large-commands.md](03-large-commands.md) #R18
- [03-large-commands.md](03-large-commands.md) #cross-1
- [README.md](README.md) #wave2-deterministic
- [README.md](README.md) #1-exec-2
- [README.md](README.md) #4.6

Sources: `03-large-commands.md#E4`, `03-large-commands.md#R7`, `03-large-commands.md#R10`, `03-large-commands.md#R18`, `03-large-commands.md#cross-1`, `README.md#wave2-deterministic`, `README.md#1-exec-2`, `README.md#4.6`

### W2-02 · [memory] Split commands/memory.md into a router plus per-sub mode files
**Priority** High · **Effort** L · **Labels** Tech Debt, Improvement · **Ticket group** —

**Problem**
`commands/memory.md` (65 KB, ~16k tokens, 1795 lines) loads in full for every sub, even `/memory stats`; ~58% is `validate`. The 4–6-line `_gc/MROOT/WTROOT/MEMDB` block appears 45 times (~7 KB), several copies mis-indented inside numbered lists (`:363-367,1495-1499,1509-1513`), and the tier-status SQL is duplicated in distill `--status` (`:276`) and search `--status` (`:600`).

**Fix**
- Keep `commands/memory.md` as dispatch + usage + one root-resolution block (~120 lines).
- Move subs to `skills/memory-store/modes/{config,distill,export,stats,search}.md`, validate Steps 1–11 to `skills/validate-memory/host-pipeline.md`, reconcile R1–R4 to `skills/validate-memory/reconcile.md`; router reads only the needed file.
- Deduplicate the tier-status SQL.

**Acceptance**
- `/memory stats` loads < 10 KB of instructions.
- All P0/W0 memory fixes preserved (tests pass).
- docs-drift and smoke cover new mode files.

**Source**
- [03-large-commands.md](03-large-commands.md) #E3
- [03-large-commands.md](03-large-commands.md) #M19
- [README.md](README.md) #wave2-router
- [README.md](README.md) #4.6

Sources: `03-large-commands.md#E3`, `03-large-commands.md#M19`, `README.md#wave2-router`, `README.md#4.6`

### W2-07 · [bug-hunt] Split bug-hunt SKILL.md into stage references; extract parse/load scripts
**Priority** High · **Effort** L · **Labels** Tech Debt, Improvement · **Ticket group** —

**Problem**
`skills/bug-hunt/SKILL.md` is 3391 lines / 135 KB (~34k tokens), ~28× the ~500-line guideline, loaded on every invocation including handoff-only runs. S3 is 1015 lines, S4 870. The bindings table (`:72-101`) is duplicated in each stage's "session outputs" section. `bug-hunt/test.sh`'s 206 assertions grep `$SKILL` only, blocking any move of text into reference files.

**Fix**
- Keep SKILL.md ~350 lines: frontmatter, overview, invariants, stage router by `BH_MODE`, bindings.
- Move stages to `reference/{s1-discover,s2-refute,report,s3-materialize,s4-handoff}.md`, read on entry.
- Extract the S0 parse and S3a load blocks into `parse-args.sh`/`load.sh`; update test.sh to grep the whole directory.

**Acceptance**
- SKILL.md < 20 KB.
- test.sh passes against the directory.
- Handoff-only run reads only s4-handoff.md.

**Source**
- [08-workflow-skills.md](08-workflow-skills.md) #9
- [08-workflow-skills.md](08-workflow-skills.md) #F:bug-hunt/SKILL.md(size)
- [08-workflow-skills.md](08-workflow-skills.md) #F:bug-hunt/test.sh
- [README.md](README.md) #wave2-deterministic

Sources: `08-workflow-skills.md#9`, `08-workflow-skills.md#F:bug-hunt/SKILL.md(size)`, `08-workflow-skills.md#F:bug-hunt/test.sh`, `README.md#wave2-deterministic`

### W2-08 · [bug-hunt] Behavioural tests for parse-args and load scripts
**Priority** High · **Effort** M · **Labels** Tech Debt · **Ticket group** —

**Problem**
bug-hunt's 206 tests are static greps; none execute bash. §0c lists expected parse failure behaviours (exit codes, stdout) that are never run, and S3a load / S4 banding have no behavioural coverage. Depends on the bug-hunt split extracting `parse-args.sh` and `load.sh`.

**Fix**
- Run every row of the §0c table through `parse-args.sh` asserting exit code and stdout.
- Run `load.sh` against fixture reports; test S4 banding.

**Acceptance**
- Every §0c row has an executed case.
- Fixture-based load test passes.
- Included in run-all-tests.

**Source**
- [08-workflow-skills.md](08-workflow-skills.md) #10
- [08-workflow-skills.md](08-workflow-skills.md) #test-results-bh

Sources: `08-workflow-skills.md#10`, `08-workflow-skills.md#test-results-bh`

### W2-11 · [council] Implement real finalize validation and the 80-confidence filter
**Priority** High · **Effort** M · **Labels** Bug, Improvement · **Ticket group** T3 council-integrity

**Problem**
judge.md:196-213, investigator.md:164-174 and phase4-brief.md promise "engine-enforced" validation (taxonomy, confidence 0–100, non-empty evidence_blob, verbatim quotes, required struck_lines; exit 7), but finalize only checks the JSON parses and even repairs it (`engine.sh:749-756,1007-1070`). The plan sets `confidence_filter_threshold:80` (`:280`) but finalize never reads it — a confidence-40 finding was rendered and counted while report-finding.md:111 says it was "filtered at emission"; diff-mode.md (`:201-204`) and flavors disagree on whether sub-threshold findings are struck or not emitted. A bare-list judge output writes report+index then fails at `jq` (`:1310-1314`) → exit 5; non-dict items/`verdicts:null` → traceback exit 1 (undocumented; SKILL failure table omits exit 1). Schemas don't require `claim_id` ("Claim ?") or struck_lines fields.

**Fix**
- Finalize Python: enforce enums, integer confidence 0–100, evidence_blob, struck_lines, shape key (exit 7); move findings below the plan threshold into struck with reason; normalize or reject bare lists before any write.
- Align prompts, diff-mode.md, report template, SKILL failure table and schemas.

**Acceptance**
- Tests: each invalid judge shape exits 7 with no report written; confidence 40 appears only in struck trail.
- Schema requires `claim_id`.
- Docs no longer claim unimplemented checks.

**Source**
- [04-council.md](04-council.md) #5
- [04-council.md](04-council.md) #F:council/engine.sh(1,2,4,5)
- [04-council.md](04-council.md) #cross-1
- [04-council.md](04-council.md) #F:prompts/judge.md,phase4-brief.md,cross-reviewer.md
- [04-council.md](04-council.md) #F:templates/report-finding.md(111)
- [04-council.md](04-council.md) #F:council/SKILL.md(3)
- [04-council.md](04-council.md) #F:flavors/paranoid-ic,yolo-ic,external,diff-mode.md
- [04-council.md](04-council.md) #F:council/workflow-schemas.js(required)
- [README.md](README.md) #1-exec-6
- [README.md](README.md) #wave2-council

Sources: `04-council.md#5`, `04-council.md#F:council/engine.sh(1,2,4,5)`, `04-council.md#cross-1`, `04-council.md#F:prompts/judge.md,phase4-brief.md,cross-reviewer.md`, `04-council.md#F:templates/report-finding.md(111)`, `04-council.md#F:council/SKILL.md(3)`, `04-council.md#F:flavors/paranoid-ic,yolo-ic,external,diff-mode.md`, `04-council.md#F:council/workflow-schemas.js(required)`, `README.md#1-exec-6`, `README.md#wave2-council`

### W2-12 · [council] Split jaded-senior: prosecutor only; add `adversarial-ic` investigator
**Priority** High · **Effort** S · **Labels** Bug · **Ticket group** T3 council-integrity

**Problem**
`skills/council/flavors/jaded-senior.md` is both the Phase 4 prosecutor and the generic preset's second investigator (`engine.sh:277`), yet it says "You cannot Read, Grep, or Bash" (`:310-311`). Injected into investigator.md, it tells an investigator not to use tools, defeating the ≥2-flavor monoculture defence.

**Fix**
- Add `flavors/adversarial-ic.md` (tools allowed, sceptical prior) for generic Phase 2; keep jaded-senior as prosecutor only.
- Update engine.sh:277 flavors, SKILL.md and SPEC-013.

**Acceptance**
- Generic preset investigators contain no 'cannot Read' text (test).
- check-template-vars passes.
- SPEC-013 roster updated.

**Source**
- [04-council.md](04-council.md) #6
- [04-council.md](04-council.md) #F:council/flavors/jaded-senior.md
- [04-council.md](04-council.md) #cross-5
- [README.md](README.md) #wave2-council

Sources: `04-council.md#6`, `04-council.md#F:council/flavors/jaded-senior.md`, `04-council.md#cross-5`, `README.md#wave2-council`

### W2-13 · [council] Remove or tool-write the LLM-written investigator evidence cache
**Priority** High · **Effort** M · **Labels** Security, Bug · **Ticket group** T3 council-integrity

**Problem**
The CDV-211 cache (`skills/council/prompts/investigator.md:58-83`) is written by an investigator's LLM "raw output" via Bash and then `cat`-ed by other investigators as real tool_use evidence, so one investigator's paraphrase or fabrication becomes another's "raw bytes" — breaking evidence-or-silence and blindness. The cache key is built with `printf '%s' "P"` from an untrusted path (command injection if the path contains `$(…)`).

**Fix**
- Either drop cache writes (read-only investigators) or have the orchestrator seed `reads/` from real Read output; cite cache content as secondary evidence only.
- Hash via stdin, never an interpolated path.

**Acceptance**
- Prompt contains no LLM-write-to-cache instruction (or orchestrator-seeded only).
- Path `$(touch X)` in a probe executes nothing.
- Council tests pass.

**Source**
- [04-council.md](04-council.md) #7
- [04-council.md](04-council.md) #F:prompts/investigator.md
- [README.md](README.md) #4.4
- [README.md](README.md) #wave2-council

Sources: `04-council.md#7`, `04-council.md#F:prompts/investigator.md`, `README.md#4.4`, `README.md#wave2-council`

### W2-14 · [council] Workflow ↔ Task parity or explicit fallback
**Priority** High · **Effort** L · **Labels** Bug, Feature · **Ticket group** T3 council-integrity

**Problem**
`skills/council/workflow.js` lacks Phase 3 (domain specialist) and `--external`, breaking SKILL.md:519's "a consumer can never tell which path produced a run". Cross-review uses one reviewer per bundle (not per investigator). Investigators use `agentType 'dev-team:ic4'` (model map says `finder`); `--tokens-file` is never passed (tokens → console.log); weak_evidence is computed but never rendered. `loadPrompt` (`:125-128`) substitutes sequentially, so a claim containing `{{RAW_ARTIFACTS}}` expands (template injection fixed in engine.sh:1185). Diff/session scope get empty RAW_ARTIFACTS/INPUT_TEXT unless undocumented `raw_artifacts`/`input_text` are passed. Self-verify stub bundles (`:437-443`) carry synthetic ids and no evidence. `JSON.parse(pre.stdout)` unguarded (`:299`); unused `input`/`capture` params; `:633` fallback double-counts struck lines; no guard refusing `council_tier:light`; schemas (`{bundles}`, JSON `ranking`) contradict investigator.md and cross-reviewer's `RANKING:` text.

**Fix**
- Implement Phase 3, `--external`, `--tokens-file`, `finder`; otherwise fall back to the Task path when Phase 3/external is requested.
- Single-pass `loadPrompt`; documented diff/spec intake; drop evidence-less stubs; guard parse; refuse light tier; reconcile schemas and prompts.

**Acceptance**
- Parity test runs the same fixture through both paths with equivalent reports.
- Injection probe `{{RAW_ARTIFACTS}}` stays literal.
- workflow-static test covers fallback.

**Source**
- [04-council.md](04-council.md) #8
- [04-council.md](04-council.md) #cross-2
- [04-council.md](04-council.md) #F:council/workflow.js(2,3,5-11)
- [04-council.md](04-council.md) #F:prompts/judge.md,phase4-brief.md,cross-reviewer.md(RANKING)
- [README.md](README.md) #4.4-loadPrompt
- [README.md](README.md) #wave2-council

Sources: `04-council.md#8`, `04-council.md#cross-2`, `04-council.md#F:council/workflow.js(2,3,5-11)`, `04-council.md#F:prompts/judge.md,phase4-brief.md,cross-reviewer.md(RANKING)`, `README.md#4.4-loadPrompt`, `README.md#wave2-council`

### W2-16 · [memory] Fix the tier-0 eclipse; add write read-back; cortex-load selects type
**Priority** High · **Effort** M · **Labels** Bug · **Ticket group** —

**Problem**
The session read rule "load tier-0 only when no tier>0 rows exist" (`skills/agent-memory/protocol.md:62-74`, SPEC-006:20, `cortex-load.md`, AGENTS.md) hides every lesson written after the last distill — and after any seed import (which inserts tier 1), `/setup team --refresh` hides all of an agent's existing tier-0 memories. This is the biggest silent memory-loss issue. protocol.md also has no read-back of writes (SPEC-004 MUST), and cortex-load selects `content` only instead of `type, content` (SPEC-006:26).

**Fix**
- Always load tier-0 rows newer than the newest digest (or the last N tier-0 rows) alongside tier 1/2.
- Add a read-back check after writes; select `type, content` in cortex-load.
- Update SPEC-006, protocol.md, AGENTS.md; re-sync includes.

**Acceptance**
- Test: lesson written after a distill appears in session-start output.
- Seed import doesn't hide existing tier-0 rows.
- sync-includes clean.

**Source**
- [07-memory.md](07-memory.md) #4
- [07-memory.md](07-memory.md) #cross-tier-eclipse
- [07-memory.md](07-memory.md) #F:agent-memory/protocol.md(tier,readback)
- [07-memory.md](07-memory.md) #F:agent-memory/cortex-load.md(select)
- [07-memory.md](07-memory.md) #F:memory-store/import-seed-pack.sh(eclipse)
- [README.md](README.md) #wave2-memory
- [10-specs.md](10-specs.md) #SPEC-006

Sources: `07-memory.md#4`, `07-memory.md#cross-tier-eclipse`, `07-memory.md#F:agent-memory/protocol.md(tier,readback)`, `07-memory.md#F:agent-memory/cortex-load.md(select)`, `07-memory.md#F:memory-store/import-seed-pack.sh(eclipse)`, `README.md#wave2-memory`, `10-specs.md#SPEC-006`

### W2-17 · [memory] Treat seed-pack imports as untrusted: tier 0, confirm, framing
**Priority** High · **Effort** M · **Labels** Security · **Ticket group** —

**Problem**
`skills/memory-store/import-seed-pack.sh` imports repo-supplied pack content as tier-1 digests. Only a self-attesting sha256 protects it — no signature, no instruction-pattern screen, no user confirmation — so any cloned repo's `.claude/memory/seed/` becomes trusted digest-tier context for every agent: a prompt-injection channel.

**Fix**
- Import as tier 0 (or behind a flag) until validated.
- Show the import diff and require confirmation in `/setup team`.
- Frame seed rows as "imported — untrusted" at load; screen for instruction-like patterns; optionally verify commit signer/author of the seed directory.

**Acceptance**
- test-seed-pack: import lands tier 0 with a provenance marker.
- Non-interactive import without confirm flag is refused.
- Injection-pattern fixture is flagged.

**Source**
- [07-memory.md](07-memory.md) #6
- [07-memory.md](07-memory.md) #F:memory-store/import-seed-pack.sh(trust)
- [README.md](README.md) #P1-seed-pack
- [README.md](README.md) #4.4
- [README.md](README.md) #wave2-memory

Sources: `07-memory.md#6`, `07-memory.md#F:memory-store/import-seed-pack.sh(trust)`, `README.md#P1-seed-pack`, `README.md#4.4`, `README.md#wave2-memory`

### W2-26 · [privacy] umask 077, gitignore runtime dirs in user projects, redact mirrored secrets
**Priority** High · **Effort** M · **Labels** Security · **Ticket group** —

**Problem**
No script sets `umask 077` (grep: 0 hits); `~/.claude/transcript/**` and `$MROOT/.claude/{handoff,retro}` files are 0644/dirs 0755 (verified), storing thinking, tool I/O and injected system text readable by other local users. `.claude/handoff/` and `.claude/retro/` aren't added to user-project .gitignore (setup adds only memory paths), though precompact-capture.sh:17 claims "gitignored" — rescue spines can be committed. `model-map/SKILL.md` claims `models.local.json` is gitignored, but nothing adds `.claude/dev-team/models.local.json*` to user repos (SPEC-037 M1 MUST). Spine and mirror keep full `tool_use` inputs (tokens, `Authorization:` headers) with no redaction.

**Fix**
- `umask 077` in the recorder, precompact-capture, prepass finalize and friction-capture.
- `/setup orchestration` and `/setup models` add `.claude/handoff/`, `.claude/retro/`, `.claude/dev-team/models.local.json*` to .gitignore.
- `redact()` (Bearer, `sk-…`, `AKIA…`, `password=`) in `digest_input` and the mirror.

**Acceptance**
- Test: mirrored files are 0600.
- Setup adds the ignore entries idempotently.
- Redaction fixture masks each pattern.

**Source**
- [06-handoff-transcript.md](06-handoff-transcript.md) #7
- [06-handoff-transcript.md](06-handoff-transcript.md) #cross-2
- [06-handoff-transcript.md](06-handoff-transcript.md) #F:handoff/precompact-capture.sh(gitignored)
- [06-handoff-transcript.md](06-handoff-transcript.md) #F:transcript-mirror/transcript-mirror.sh(perm)
- [07-memory.md](07-memory.md) #9-gitignore
- [07-memory.md](07-memory.md) #F:model-map/SKILL.md
- [10-specs.md](10-specs.md) #SPEC-037
- [README.md](README.md) #4.8
- [README.md](README.md) #wave2-transcript

Sources: `06-handoff-transcript.md#7`, `06-handoff-transcript.md#cross-2`, `06-handoff-transcript.md#F:handoff/precompact-capture.sh(gitignored)`, `06-handoff-transcript.md#F:transcript-mirror/transcript-mirror.sh(perm)`, `07-memory.md#9-gitignore`, `07-memory.md#F:model-map/SKILL.md`, `10-specs.md#SPEC-037`, `README.md#4.8`, `README.md#wave2-transcript`

### W2-41 · [debug] Define full-mode commit/land/exit and fix rule contradictions
**Priority** High · **Effort** M · **Labels** Bug, Improvement · **Ticket group** —

**Problem**
`skills/debug/SKILL.md` full mode never says when to commit the fix, yet 2.8 (`:664`) assumes "fix already committed in 2.7", 2.10 asks for commit hashes, and it suggests `/wrap-ticket after PR merged` with no PR, landing or worktree-release step; refactor §2.4 (CDT-103) says `/debug` "owns the exit", which debug never defines. Contradictions: Rules `:1036` "Do NOT apply the same fix in multiple places" vs 2.8 `:666` "address it (if trivial — same fix)"; `:30` "patch skips … escalation" vs mandatory P.2a. P.5 checklist omits SPEC-029's theme / S.6 write-back. No "Step 1" in the numbering.

**Fix**
- Add 2.7a "commit fix on the §2.4a branch" and 2.10a "bounded exit (PR/squash) + worktree release", citing refactor §2.4.
- Resolve the two contradictions; add theme/S.6 to P.5; renumber steps.

**Acceptance**
- Static test asserts 2.7a/2.10a exist and contradictions are gone.
- SPEC-014 updated to match.
- Refactor §2.4 reference resolves.

**Source**
- [08-workflow-skills.md](08-workflow-skills.md) #12
- [08-workflow-skills.md](08-workflow-skills.md) #F:debug/SKILL.md(contradictions,lifecycle)
- [10-specs.md](10-specs.md) #SPEC-014-80

Sources: `08-workflow-skills.md#12`, `08-workflow-skills.md#F:debug/SKILL.md(contradictions,lifecycle)`, `10-specs.md#SPEC-014-80`

### W2-03 · [spec] Router-ize commands/spec.md
**Priority** Medium · **Effort** M · **Labels** Tech Debt · **Ticket group** —

**Problem**
`commands/spec.md` (34 KB, ~8.5k tokens) inlines check/create/find/list/update, so all five load for any sub, while generate/tests/reflect already delegate to `skills/spec-tooling`. The source-exclude include is inlined three times deliberately (SPEC-008 drift gate).

**Fix**
- Move check/create/find/list/update into `skills/spec-tooling/modes/*.md`; `commands/spec.md` becomes ~60 lines of dispatch.
- Keep the `<!-- include -->` regions in the mode files and update the `sync-includes.py` consumer list.

**Acceptance**
- `/spec list` loads < 8 KB of instructions.
- sync-includes check clean.
- docs-drift passes.

**Source**
- [03-large-commands.md](03-large-commands.md) #E6
- [03-large-commands.md](03-large-commands.md) #S9
- [README.md](README.md) #wave2-router

Sources: `03-large-commands.md#E6`, `03-large-commands.md#S9`, `README.md#wave2-router`

### W2-04 · [council] Move tier-grading procedure and `--blind` path out of commands/council.md
**Priority** Medium · **Effort** M · **Labels** Tech Debt · **Ticket group** —

**Problem**
`commands/council.md` (72 KB) carries ~175 lines of tier-grading procedure (§1.5.1–1.5.5, `:139-315`) it never runs itself; they stay only because `skills/autopilot/ship-gate-council.md:124,130`, `prompts/tier-triage.md:6,25,179` and `skills/orchestrate/steps/08-execute.md:119` cite "commands/council.md § 1.5.2". The `--blind` path (`:1121-1345`, ~225 lines) loads on every tribunal run and duplicates SKILL.md § Blind-review path.

**Fix**
- Create `skills/council/tier-grading.md` with §1.5.2–1.5.5; leave a 10-line passthrough §1.5; update the three cites.
- Move the blind path to `skills/council/blind-path.md`, merged with SKILL.md's section; Step 0.5 reads it when scope=blind.

**Acceptance**
- council.md shrinks by ≥15 KB.
- check-template-vars passes for both files.
- No remaining cite to `commands/council.md § 1.5.2`.

**Source**
- [03-large-commands.md](03-large-commands.md) #E1
- [03-large-commands.md](03-large-commands.md) #E2
- [03-large-commands.md](03-large-commands.md) #C4
- [03-large-commands.md](03-large-commands.md) #C16
- [README.md](README.md) #wave2-router

Sources: `03-large-commands.md#E1`, `03-large-commands.md#E2`, `03-large-commands.md#C4`, `03-large-commands.md#C16`, `README.md#wave2-router`

### W2-05 · [epic] Split epic and kickoff SKILL.md monoliths into steps/
**Priority** Medium · **Effort** L · **Labels** Tech Debt · **Ticket group** —

**Problem**
`skills/epic/SKILL.md` (1277 lines, 80 KB, 25 PDH copies) and `skills/kickoff/SKILL.md` (971 lines, 61 KB, 18 PDH copies) load whole on every invocation. `skills/orchestrate` already demonstrates a lean router that loads one step at a time.

**Fix**
- epic → router + `steps/{0-flags,A-decompose,B-execute,B7-seal,C-F-modes}.md`; kickoff → router + `steps/`.
- Keep behavioural tests green; extend router-static-style tests to both.

**Acceptance**
- Each SKILL.md < 15 KB.
- epic/test.sh (745) passes.
- Static router test asserts each step file is referenced.

**Source**
- [05-orchestration.md](05-orchestration.md) #13-epic-kickoff
- [README.md](README.md) #wave2-router
- [README.md](README.md) #4.6

Sources: `05-orchestration.md#13-epic-kickoff`, `README.md#wave2-router`, `README.md#4.6`

### W2-06 · [init-orchestration] Move embedded hook bodies to shellcheck-able templates/*.sh
**Priority** Medium · **Effort** L · **Labels** Tech Debt · **Ticket group** —

**Problem**
`skills/init-orchestration/SKILL.md` is 2157 lines (102 KB); about 1,200 lines are embedded hook templates (Steps 4–4i) that the model copies and that cannot be shellchecked. `normalize-hook-paths.sh` exits 1 for "no-op", which a `set -e` caller treats as failure; helpers mix Python and jq toolchains.

**Fix**
- Move hook bodies to `templates/*.sh`, copied via Write; `check-hook-templates` runs shellcheck/bash -n on real files.
- SKILL.md ≈ 700 lines.
- `normalize-hook-paths.sh` exits 0 on no-op (distinct code documented otherwise).

**Acceptance**
- All 6 init-orchestration tests pass.
- shellcheck clean on templates.
- Generated hooks byte-identical to before (golden test).

**Source**
- [05-orchestration.md](05-orchestration.md) #13-init
- [05-orchestration.md](05-orchestration.md) #F:init-orchestration/*.sh
- [README.md](README.md) #wave2-router

Sources: `05-orchestration.md#13-init`, `05-orchestration.md#F:init-orchestration/*.sh`, `README.md#wave2-router`

### W2-09 · [context] Resolve PDH once per invocation instead of ~210 pasted stanzas
**Priority** Medium · **Effort** M · **Labels** Tech Debt, Improvement · **Ticket group** —

**Problem**
The ~750–1100-byte PDH one-liner is emitted ~210 times: setup 9, adjust-agent 4, status 4, audit 2, council 8 (plus the finder resolver block twice verbatim at `:564-579,786-801` despite `:466` saying not to), retro 12, epic 25, kickoff 18, init-orchestration 8, orchestrate steps 29 (twice in 00-resolve and 09-review), 16 in workflow skills, and 5 shell scripts that already know `$SCRIPT_DIR`. Model-resolve + retry prose is copied at every spawn site (3× in 04-kickoff; debug `:920-940` = code-simplify). ≈ 23 KB+ per load path.

**Fix**
- Resolve PDH in Step 0 and cache it to `$MROOT/.claude/.pdh` (stanza as fallback) or a managed include; later fences read the cache.
- Add `skills/model-map/spawn-protocol.md` partial for model resolve/retry.
- Respect the SPEC-002 CDT-233 irreducibility verdict — cache, don't delegate; update skill-lint C3.

**Acceptance**
- Count of full PDH stanzas repo-wide < 30.
- plugin-dir-test and smoke pass on all install tiers.
- SPEC-002 documents the cache.

**Source**
- [README.md](README.md) #1-exec-7
- [README.md](README.md) #4.6
- [README.md](README.md) #wave2-pdh
- [02-commands-docs.md](02-commands-docs.md) #12
- [02-commands-docs.md](02-commands-docs.md) #cross-3
- [03-large-commands.md](03-large-commands.md) #E5
- [03-large-commands.md](03-large-commands.md) #C15
- [03-large-commands.md](03-large-commands.md) #M19
- [03-large-commands.md](03-large-commands.md) #cross-4
- [05-orchestration.md](05-orchestration.md) #12
- [05-orchestration.md](05-orchestration.md) #cross-2
- [05-orchestration.md](05-orchestration.md) #F:steps/04-kickoff.md
- [08-workflow-skills.md](08-workflow-skills.md) #23
- [08-workflow-skills.md](08-workflow-skills.md) #F:debug/SKILL.md(model-map-dup)
- [06-handoff-transcript.md](06-handoff-transcript.md) #cross-1-pdh
- [02-commands-docs.md](02-commands-docs.md) #F:commands/adjust-agent.md(4)
- [02-commands-docs.md](02-commands-docs.md) #F:commands/status.md
- [02-commands-docs.md](02-commands-docs.md) #F:commands/audit.md(pdh)
- [02-commands-docs.md](02-commands-docs.md) #F:commands/setup.md(10)
- [05-orchestration.md](05-orchestration.md) #F:steps/00-resolve.md(pdh)
- [05-orchestration.md](05-orchestration.md) #F:steps/09-review.md(pdh)

Sources: `README.md#1-exec-7`, `README.md#4.6`, `README.md#wave2-pdh`, `02-commands-docs.md#12`, `02-commands-docs.md#cross-3`, `03-large-commands.md#E5`, `03-large-commands.md#C15`, `03-large-commands.md#M19`, `03-large-commands.md#cross-4`, `05-orchestration.md#12`, `05-orchestration.md#cross-2`, `05-orchestration.md#F:steps/04-kickoff.md`, `08-workflow-skills.md#23`, `08-workflow-skills.md#F:debug/SKILL.md(model-map-dup)`, `06-handoff-transcript.md#cross-1-pdh`, `02-commands-docs.md#F:commands/adjust-agent.md(4)`, `02-commands-docs.md#F:commands/status.md`, `02-commands-docs.md#F:commands/audit.md(pdh)`, `02-commands-docs.md#F:commands/setup.md(10)`, `05-orchestration.md#F:steps/00-resolve.md(pdh)`, `05-orchestration.md#F:steps/09-review.md(pdh)`

### W2-10 · [agents] Shared agent preamble include; unify agent embed resolver with PDH
**Priority** Medium · **Effort** M · **Labels** Tech Debt · **Ticket group** —

**Problem**
The ~20-line output-intensity block is copied into 9 agents and AGENTS.md:222-235 with no managed include; the ~110-line memory include re-derives `MROOT` four times per agent — ~130 lines of repeated preamble per behavioral spawn. The agent embed resolver (`agents/ic5.md:209-210`) has only 2 tiers (no `${CLAUDE_PLUGIN_ROOT}`, no marketplace), while the PDH stanza (AGENTS.md:92) has 5, so on a marketplace-only install the embedding lookup silently misses.

**Fix**
- Move output-intensity to `skills/agent-memory/output-mode.md` with an `<!-- include -->` region.
- Collapse the protocol partial's 4 MROOT derivations into one "run in every fence" line.
- Use literal `${CLAUDE_PLUGIN_ROOT}` (substituted per v1.18.14) as tier 0, falling back to PDH; re-sync includes.

**Acceptance**
- sync-includes check clean.
- Agent files shrink by ≥ 40 lines each.
- Embed lookup succeeds in a marketplace-only layout test.

**Source**
- [01-agents-infra.md](01-agents-infra.md) #9
- [01-agents-infra.md](01-agents-infra.md) #10
- [01-agents-infra.md](01-agents-infra.md) #cross-2
- [01-agents-infra.md](01-agents-infra.md) #cross-6
- [01-agents-infra.md](01-agents-infra.md) #F:agents/pm.md(block)
- [01-agents-infra.md](01-agents-infra.md) #F:agents/ic5.md(resolver)
- [README.md](README.md) #wave2-agent-preamble

Sources: `01-agents-infra.md#9`, `01-agents-infra.md#10`, `01-agents-infra.md#cross-2`, `01-agents-infra.md#cross-6`, `01-agents-infra.md#F:agents/pm.md(block)`, `01-agents-infra.md#F:agents/ic5.md(resolver)`, `README.md#wave2-agent-preamble`

### W2-15 · [council] engine.sh / report rendering fixes (duplicate FINDINGS, empty sections)
**Priority** Medium · **Effort** S · **Labels** Bug · **Ticket group** T3 council-integrity

**Problem**
`skills/council/templates/report-finding.md:115` has a literal `` `{{FINDINGS}}` `` in prose, so the findings list renders twice (confirmed). In `engine.sh`: DIFF_SUMMARY falls back to `scope_arg` (`""` for diff) and `applicable_specs` is never set (`:1085`); an empty `suggestion` renders "desc —  [confidence" (`:1129`); `${plan_report_path#$MROOT/}` unquoted pattern (`:1295`); dead `$?` guards (`:734,753`); tokens parser duplicated (`:805-845,1394-1441`); task-id passed with `--report-out` isn't validated before being written to YAML, so index-writer rejects it (exit 6) after the report exists. `index-writer.sh:35` accepts an empty TASK_ID, creating a `""` key.

**Fix**
- Replace the placeholder with plain text; populate or omit DIFF_SUMMARY/specs; omit empty suggestion; quote the pattern; delete dead guards; share one tokens parser; validate task-id up front; reject empty TASK_ID.

**Acceptance**
- Rendered report fixture contains FINDINGS once.
- Invalid task-id fails before any file is written.
- Empty TASK_ID rejected (test).

**Source**
- [04-council.md](04-council.md) #12
- [04-council.md](04-council.md) #F:templates/report-finding.md(115)
- [04-council.md](04-council.md) #F:council/engine.sh(8-15)
- [04-council.md](04-council.md) #F:council/index-writer.sh(TASK_ID)

Sources: `04-council.md#12`, `04-council.md#F:templates/report-finding.md(115)`, `04-council.md#F:council/engine.sh(8-15)`, `04-council.md#F:council/index-writer.sh(TASK_ID)`

### W2-18 · [memory] Seed-pack export/import fixes: trailer, line cap, dedupe, sanitizer
**Priority** Medium · **Effort** S · **Labels** Bug · **Ticket group** —

**Problem**
`export-seed-pack.sh:65` puts `basename "$MROOT"` unescaped in the trailer; import requires `project=\S+`, so a project dir with a space rejects every entry (verified "My Proj": imported=0). The count query (`:136`) has no timeout. Import's fallback cap check (`:186-192`) appends whenever existing < 80 lines (79 + one entry = 83, violating SPEC-024 M10); dedupe is a full-table `LIKE '%hash=…]%'` scan that treats any memory quoting a trailer as duplicate; `sanitized` is computed then discarded (`:353-362`). `seed-common.sh` lacks the SPEC-024 M2 username/high-entropy checks and its `set -u` (`:19`) leaks into sourcing shells. The M10 test (`:279-303`) never tests a cap.

**Fix**
- Slugify project name in export (`tr -c 'A-Za-z0-9._-' '-'`) and relax the import regex.
- Refuse/truncate when `existing + add > limit` and report omissions; dedupe by an indexed hash column; use the sanitized value; add M2 checks; scope `set -u`.

**Acceptance**
- Tests: project with space round-trips; cap enforced at 80; real M10 cap test.
- Sanitizer rejects a high-entropy token.
- Count query uses timeout.

**Source**
- [07-memory.md](07-memory.md) #11
- [07-memory.md](07-memory.md) #12
- [07-memory.md](07-memory.md) #F:memory-store/export-seed-pack.sh
- [07-memory.md](07-memory.md) #F:memory-store/import-seed-pack.sh(cap,dedupe,sanitized)
- [07-memory.md](07-memory.md) #F:memory-store/seed-common.sh
- [07-memory.md](07-memory.md) #F:memory-store/test-seed-pack.sh
- [10-specs.md](10-specs.md) #SPEC-024

Sources: `07-memory.md#11`, `07-memory.md#12`, `07-memory.md#F:memory-store/export-seed-pack.sh`, `07-memory.md#F:memory-store/import-seed-pack.sh(cap,dedupe,sanitized)`, `07-memory.md#F:memory-store/seed-common.sh`, `07-memory.md#F:memory-store/test-seed-pack.sh`, `10-specs.md#SPEC-024`

### W2-19 · [memory] Verify native extension hashes at `.load` time; harden downloader
**Priority** Medium · **Effort** M · **Labels** Security · **Ticket group** —

**Problem**
`download-extensions.sh` verifies SHA-256 on the tarball and member, but consumers (embed-one, memory-recall, reconcile-lib, migrate-md) `.load` whatever sits in `.claude/memory/extensions/` without re-checking — a hostile repo that force-commits `vec0.so` gets native code execution on the first memory write. `.load` paths are unquoted. Downloader: no `--proto =https --proto-redir =https`; the model downloads straight to its destination (`:240`, concurrent embed may read a partial file); cross-filesystem `mv` of the `.so` isn't atomic; `MODE=lembed` chosen without checking vec0; temp dir not trapped on signals.

**Fix**
- Record verified hashes (config table or sidecar) at download; all consumers verify before `.load` and quote paths.
- Download to temp + `mv` in the same filesystem; add proto flags; check vec0 before lembed; trap cleanup.

**Acceptance**
- Test: tampered vec0 is refused by embed-one.
- Interrupted model download leaves no partial file at destination.
- All `.load` paths quoted (grep).

**Source**
- [07-memory.md](07-memory.md) #13
- [07-memory.md](07-memory.md) #F:memory-store/embed-one.sh(load)
- [07-memory.md](07-memory.md) #F:memory-store/download-extensions.sh
- [07-memory.md](07-memory.md) #cross-native
- [README.md](README.md) #wave2-memory

Sources: `07-memory.md#13`, `07-memory.md#F:memory-store/embed-one.sh(load)`, `07-memory.md#F:memory-store/download-extensions.sh`, `07-memory.md#cross-native`, `README.md#wave2-memory`

### W2-20 · [security] Harden curl calls: timeouts, protocols, secrets off argv
**Priority** Medium · **Effort** S · **Labels** Security · **Ticket group** —

**Problem**
`notify/webhook.sh:78-80` puts the webhook URL (Slack/Discord embed the secret in the path) and payload on curl's argv, visible in `ps`; no `--proto =https` (curl accepts `file:`, `gopher:`); the event enum isn't enforced; `detail` is free text without redaction despite "Never includes secrets"; `${DETAIL:0:500}` can split UTF-8. `embed-one.sh:94`, memory-recall and migrate-md curl calls have no `--max-time`, `--fail` or `--proto`, so a stalled endpoint hangs an agent write; embed-one has no trap removing the temp file holding the API key, `'$MODEL_PATH'` isn't escaped and it uses `echo "$CONTENT"`.

**Fix**
- Add `--max-time 30 --fail --proto =https,http` to memory curls; trap-remove the key file; printf; escape MODEL_PATH.
- webhook: URL and body via `-K -`/`--data @-`, `--proto =https`, enforce event enum, redact detail, UTF-8-safe truncation.

**Acceptance**
- webhook-test asserts no URL in argv (ps shim).
- Stalled endpoint times out in 30 s.
- Key temp file removed on SIGINT.

**Source**
- [07-memory.md](07-memory.md) #14
- [07-memory.md](07-memory.md) #F:notify/webhook.sh
- [07-memory.md](07-memory.md) #F:memory-store/embed-one.sh(curl,key)
- [07-memory.md](07-memory.md) #F:memory-recall/SKILL.md(curl)

Sources: `07-memory.md#14`, `07-memory.md#F:notify/webhook.sh`, `07-memory.md#F:memory-store/embed-one.sh(curl,key)`, `07-memory.md#F:memory-recall/SKILL.md(curl)`

### W2-21 · [memory] Use cosine distance for vec0 tables (or convert L2) and fix spec text
**Priority** Medium · **Effort** M · **Labels** Bug · **Ticket group** —

**Problem**
vec0 tables are created without `distance_metric=cosine`, so the metric is L2, yet the validate candidate contract says "cosine similarity ≥0.55", memory-recall scores `(1-distance)*100`, and SPEC-006/SPEC-011 say cosine. Scores and thresholds are therefore meaningless.

**Fix**
- Create new vec tables with `distance_metric=cosine` and migrate existing ones (re-embed or rebuild), or convert L2 to cosine for normalized vectors.
- Fix SPEC-006/011 wording and thresholds.

**Acceptance**
- Test: identical vectors score 100, orthogonal ~0.
- Migration note in CHANGELOG and memory runbook.
- Validate threshold behaves on a fixture pair.

**Source**
- [07-memory.md](07-memory.md) #15
- [07-memory.md](07-memory.md) #F:validate-memory/SKILL.md(cosine)
- [07-memory.md](07-memory.md) #F:memory-recall/SKILL.md(score)
- [10-specs.md](10-specs.md) #SPEC-011
- [README.md](README.md) #4.5
- [README.md](README.md) #wave2-memory

Sources: `07-memory.md#15`, `07-memory.md#F:validate-memory/SKILL.md(cosine)`, `07-memory.md#F:memory-recall/SKILL.md(score)`, `10-specs.md#SPEC-011`, `README.md#4.5`, `README.md#wave2-memory`

### W2-22 · [memory] memory-recall Step 4/5: define roots first, `grep -F`, per-fence vars
**Priority** Medium · **Effort** S · **Labels** Bug, Security · **Ticket group** —

**Problem**
`skills/memory-recall/SKILL.md` Step 5 (`:202-210`) uses `$MROOT` before defining it, so `MEMDB=/.claude/memory/memory.db`, `USE_DB=false` and the grep fallback runs even with a DB. `grep -lil "<QUERY>"` is regex, not `-F`, and a raw placeholder in double quotes is a shell-injection risk. Step 4 uses `EXT_DIR`/`MODEL_DIR` defined only in Step 1's shell. `.load` unquoted; LIKE `%`/`_` unescaped.

**Fix**
- Resolve MROOT/WTROOT first in each fence; define EXT_DIR/MODEL_DIR per fence.
- Capture the query via quoted heredoc; `grep -Fil -- "$QUERY"`; include WTROOT context.md; escape LIKE; quote `.load`.

**Acceptance**
- Extracted Step 5 uses the DB when present.
- Query `$(touch X)` executes nothing.
- Query with `%` matches literally.

**Source**
- [07-memory.md](07-memory.md) #16
- [07-memory.md](07-memory.md) #F:memory-recall/SKILL.md(step5,step4,like)
- [README.md](README.md) #4.2

Sources: `07-memory.md#16`, `07-memory.md#F:memory-recall/SKILL.md(step5,step4,like)`, `README.md#4.2`

### W2-23 · [memory] Atomic migrate-v2 and pre-migration backup; migrate.sh fails loudly
**Priority** Medium · **Effort** S · **Labels** Bug · **Ticket group** —

**Problem**
`migrate-v2.sh:88-110` runs `distillation_log`, config inserts and the `schema_version='2'` bump after COMMIT (SPEC-004 requires one transaction); a crash between them makes the rerun rebuild again and reset tier/archived. The rebuild drops the `sqlite_sequence` high-water mark, so ids can be reused and collide with orphaned `embedding_meta`. `migrate.sh:43` `read_version` has no `.timeout` and swallows errors (`2>/dev/null || echo ""`), so a locked DB reads as "No schema_version — skipping", exit 0; no backup before the destructive v2 rebuild; `LATEST=4` duplicates schema.sql. `PRAGMA foreign_keys=ON` in schema.sql is per-connection (FKs decorative). test-migrate lacks rollback, rerun-at-target, partial-v3 and locked-DB cases.

**Fix**
- Move all v2 statements inside the transaction; preserve `sqlite_sequence`.
- `migrate.sh`: `VACUUM INTO memory.db.bak-v$V` before the first step; `-cmd .timeout`; treat read errors as failure.
- Document or enforce FKs; add the missing tests.

**Acceptance**
- Crash-injection test leaves DB at v1 or v2, never half.
- Locked DB makes migrate exit non-zero.
- Backup file created.

**Source**
- [07-memory.md](07-memory.md) #17
- [07-memory.md](07-memory.md) #F:memory-store/migrate.sh
- [07-memory.md](07-memory.md) #F:memory-store/migrate-v2.sh
- [07-memory.md](07-memory.md) #F:memory-store/test-migrate.sh
- [07-memory.md](07-memory.md) #F:memory-store/schema.sql
- [10-specs.md](10-specs.md) #SPEC-004
- [README.md](README.md) #wave2-memory

Sources: `07-memory.md#17`, `07-memory.md#F:memory-store/migrate.sh`, `07-memory.md#F:memory-store/migrate-v2.sh`, `07-memory.md#F:memory-store/test-migrate.sh`, `07-memory.md#F:memory-store/schema.sql`, `10-specs.md#SPEC-004`, `README.md#wave2-memory`

### W2-24 · [memory] commands/memory.md P2/P3 fixes: config UPSERT, SOURCE_IDS, re-embed, nits
**Priority** Medium · **Effort** S · **Labels** Bug · **Ticket group** —

**Problem**
`commands/memory.md`: `config set` (`:198-205`) is a plain UPDATE — on a missing row (e.g. `validate_window_days`, `reconcile_pair_cap` on pre-v3/v4 DBs) it does nothing but prints "Updated"; `distill_model` accepts any non-empty string (M11). `SOURCE_IDS_CSV` from `tr ' ' ','` yields `1,,2` with spaced JSON and `IN ()` when empty; the `TOTAL_SOURCES==0` guard (`:1461`) runs after the query (M12). REWRITE (`:1339-1348`) updates content without re-embedding (M13). Deep mode says both "skip to 10.6" and "exit with an error" (`:1403-1413` vs `:1486`, M16). `find … -name X -maxdepth 3` option order; `grep -F "$SYM_NAME"` needs `--` (`:1038,1068`, M17).

**Fix**
- UPSERT (`INSERT … ON CONFLICT`) or check `changes()`; validate distill_model against known models.
- Build the id list with `json_each`; guard before the query.
- Call embed-one after REWRITE; pick one deep-mode behavior; fix find/grep args.

**Acceptance**
- Test: `config set` on a missing key creates it.
- Empty source list skips the query.
- Rewritten memory has a fresh embedding_meta row.

**Source**
- [03-large-commands.md](03-large-commands.md) #M11
- [03-large-commands.md](03-large-commands.md) #M12
- [03-large-commands.md](03-large-commands.md) #M13
- [03-large-commands.md](03-large-commands.md) #M16
- [03-large-commands.md](03-large-commands.md) #M17

Sources: `03-large-commands.md#M11`, `03-large-commands.md#M12`, `03-large-commands.md#M13`, `03-large-commands.md#M16`, `03-large-commands.md#M17`

### W2-25 · [prompts] Untrusted-data framing and per-run nonce delimiters in all prompts
**Priority** Medium · **Effort** S · **Labels** Security · **Ticket group** —

**Problem**
Fixed delimiters `<<<END_BATCH>>>`/`<<<END_PAIRS>>>` in `skills/validate-memory/SKILL.md` survive JSON encoding, so memory content can close the data block early despite the SECURITY note. The council `--blind` prompts (unconstrained-reviewer, lens-reviewer, quorum-analyst) have no untrusted-data guard or delimiters, so repo content and team findings flow straight into the quorum analyst; their severity scale (critical/high/medium/low) has no documented mapping to the tribunal's. `topic-classifier` has no delimiters around CLAIM_TEXT. fix-ticket prompts (premise, implement, refute) pass repo-derived BUG/FIX/PREMISE_EVIDENCE to a writing implementer without framing.

**Fix**
- Generate a per-run nonce delimiter (or strip/escape sentinels from content) wherever data is embedded.
- Add the SECURITY block + `<<<BEGIN/END-$NONCE>>>` delimiters to the blind, topic-classifier and fix-ticket prompts; document the severity mapping.

**Acceptance**
- Content containing the old sentinel cannot close the block (test).
- check-template-vars covers the nonce variable.
- grep shows every prompt with untrusted input has a SECURITY block.

**Source**
- [07-memory.md](07-memory.md) #18
- [07-memory.md](07-memory.md) #F:validate-memory/SKILL.md(delimiters)
- [04-council.md](04-council.md) #21
- [04-council.md](04-council.md) #F:prompts/unconstrained-reviewer,lens-reviewer,quorum-analyst
- [04-council.md](04-council.md) #F:prompts/claim-extractor,plan-extractor,topic-classifier,tier-triage
- [04-council.md](04-council.md) #F:fix-ticket/prompts/*.md
- [README.md](README.md) #4.4
- [README.md](README.md) #wave1-input-safety-nonce

Sources: `07-memory.md#18`, `07-memory.md#F:validate-memory/SKILL.md(delimiters)`, `04-council.md#21`, `04-council.md#F:prompts/unconstrained-reviewer,lens-reviewer,quorum-analyst`, `04-council.md#F:prompts/claim-extractor,plan-extractor,topic-classifier,tier-triage`, `04-council.md#F:fix-ticket/prompts/*.md`, `README.md#4.4`, `README.md#wave1-input-safety-nonce`

### W2-27 · [transcript-mirror] Stable overlay keys instead of ordinal turn ids
**Priority** Medium · **Effort** M · **Labels** Bug · **Ticket group** —

**Problem**
`summarize-transcript.py` keys overlays by ordinal turn (`T%06d`) with heading detection `^## (user|assistant)$`. Text containing such a line, or any rebuild changing the block count, makes reapply (`reapply-overlay.sh`) land a summary on the wrong turn. `strip_main.py` also drops user-authored lines starting with `> @`.

**Fix**
- Key verbatim/overlays by source line `L<n>` (already in refs).
- Escape body lines matching `^## (user|assistant)$` in emit_tick.
- Restrict strip_main's `> @` removal to generated lines.

**Acceptance**
- Test: heading-like user text doesn't shift overlays.
- Rebuild with changed block count reapplies correctly.
- User `> @` line preserved.

**Source**
- [06-handoff-transcript.md](06-handoff-transcript.md) #11
- [06-handoff-transcript.md](06-handoff-transcript.md) #F:transcript-mirror/summarize-transcript.py
- [06-handoff-transcript.md](06-handoff-transcript.md) #F:transcript-mirror/reapply-overlay.sh
- [06-handoff-transcript.md](06-handoff-transcript.md) #F:transcript-mirror/strip_main.py

Sources: `06-handoff-transcript.md#11`, `06-handoff-transcript.md#F:transcript-mirror/summarize-transcript.py`, `06-handoff-transcript.md#F:transcript-mirror/reapply-overlay.sh`, `06-handoff-transcript.md#F:transcript-mirror/strip_main.py`

### W2-28 · [transcript] Shared mirrorlib for check-line, turn split, record identity, Grok mapping
**Priority** Medium · **Effort** M · **Labels** Tech Debt · **Ticket group** —

**Problem**
Parsing is implemented many times: record identity (jq `ident_line` vs `transcript-sync.record_ident` `:104-120` — jq 1.6 vs Python float/bigint formatting disagree on `h:` idents, giving false "lag"); turn-block splitting (compact, summarize, reapply awk, emit_tick); `--check` `sid=/status=` parsing (`prepass.sh:1440`, `compact-transcript.py:111`, `summarize-transcript.py:119`); Grok→Claude mapping (`grok_normalize.py` reads flat `tc.name/arguments`; the mirror jq also accepts `.function.name`); newest-mtime locate (5 places); stderr-drain Popen threads (2). A list-typed JSONL line raises AttributeError in transcript-sync, losing `lag_status` for the sid.

**Fix**
- Add `skills/transcript-mirror/mirrorlib.py` (check-line parse, block split, `record_ident`, Grok mapping, locate newest) used by prepass, compact, summarize, sync and the recorder helper.
- Tolerate non-object lines.

**Acceptance**
- Identity parity test jq vs Python on float/bigint fixtures.
- grep shows single implementations.
- All transcript suites pass.

**Source**
- [06-handoff-transcript.md](06-handoff-transcript.md) #13
- [06-handoff-transcript.md](06-handoff-transcript.md) #cross-1
- [06-handoff-transcript.md](06-handoff-transcript.md) #F:transcript-mirror/transcript-sync.py
- [06-handoff-transcript.md](06-handoff-transcript.md) #F:transcript-parse/grok_normalize.py(mapping)
- [README.md](README.md) #wave2-transcript
- [10-specs.md](10-specs.md) #SPEC-012-seam

Sources: `06-handoff-transcript.md#13`, `06-handoff-transcript.md#cross-1`, `06-handoff-transcript.md#F:transcript-mirror/transcript-sync.py`, `06-handoff-transcript.md#F:transcript-parse/grok_normalize.py(mapping)`, `README.md#wave2-transcript`, `10-specs.md#SPEC-012-seam`

### W2-29 · [retro] gate.sh scores the assembled (fork-deduplicated) timeline
**Priority** Medium · **Effort** M · **Labels** Bug · **Ticket group** —

**Problem**
`skills/retro-gate/gate.sh` reads the raw transcript, so a forked child re-scores the copied parent prefix (double counting). SPEC-012:51 says consumers must use the shared assemble seam.

**Fix**
- When the file has `forkedFrom`, feed `assemble.py assemble-file` output (dedup) to the scorer.

**Acceptance**
- Test: forked child scores equal to its unique suffix.
- Non-forked scoring unchanged.
- retro-gate tests pass.

**Source**
- [06-handoff-transcript.md](06-handoff-transcript.md) #14
- [06-handoff-transcript.md](06-handoff-transcript.md) #F:retro-gate/gate.sh
- [10-specs.md](10-specs.md) #SPEC-012

Sources: `06-handoff-transcript.md#14`, `06-handoff-transcript.md#F:retro-gate/gate.sh`, `10-specs.md#SPEC-012`

### W2-30 · [temp] Clean up leaked temp dirs: council cache/wf, Grok copies, prepass temps
**Priority** Medium · **Effort** S · **Labels** Tech Debt · **Ticket group** —

**Problem**
Product code leaks temp state: every council `preflight` leaks a `council-cache-*` dir when finalize doesn't run (engine.sh:367; 32 after one test run); `council-wf-*` handoff dirs from workflow.js are never removed; the adapted Grok transcript copy (`handoff/discover-warm.sh`) and `grok_normalize` output on the retro path are never deleted; `handoff/prepass.sh` has no EXIT trap, so `handoff-git.*`, `events-out`, `events-built` leak on `set -e` aborts.

**Fix**
- workflow.js removes its handoff dir on success; preflight prunes `council-cache-*` older than 24 h.
- handoff: write the Grok adapter output into `$WORK_DIR`; retro `_normalize_feed` adds `trap rm`.
- prepass: EXIT trap removing its temps.

**Acceptance**
- After a council run + handoff + retro in tests, TMPDIR has no new leftovers.
- Aborted prepass leaves no temp files.
- Stale cache pruning covered by a test.

**Source**
- [04-council.md](04-council.md) #15
- [04-council.md](04-council.md) #cross-4
- [04-council.md](04-council.md) #F:council/engine.sh(14)
- [06-handoff-transcript.md](06-handoff-transcript.md) #18
- [06-handoff-transcript.md](06-handoff-transcript.md) #B8-cleanup
- [06-handoff-transcript.md](06-handoff-transcript.md) #F:handoff/prepass.sh(e)

Sources: `04-council.md#15`, `04-council.md#cross-4`, `04-council.md#F:council/engine.sh(14)`, `06-handoff-transcript.md#18`, `06-handoff-transcript.md#B8-cleanup`, `06-handoff-transcript.md#F:handoff/prepass.sh(e)`

### W2-31 · [handoff] Harden precompact-capture: timeout, retention sort, temp cleanup, tests
**Priority** Medium · **Effort** S · **Labels** Bug · **Ticket group** —

**Problem**
`skills/handoff/precompact-capture.sh` is fail-open as designed, but: `timeout` is only applied if the binary exists (`:90`, unbounded on macOS); the settings entry has no `timeout` (init-orchestration SKILL.md:387-392), so the 60 s default applies; `timeout` doesn't kill prepass's Python grandchildren; retention `sort -r` (`:165`) is lexicographic and breaks after seq 999; the `.tmp` file is left behind on a render exception; no test covers the timeout path.

**Fix**
- Use `_timeout()` with process-group kill (`setsid`/`kill -- -pgid`).
- Add an explicit `timeout` to the generated settings entry.
- Numeric retention sort (`sort -t- -k… -n`); remove `.tmp` on failure; add timeout test.

**Acceptance**
- Test: slow prepass is killed including grandchildren.
- Retention correct across seq 999→1000.
- precompact-test passes.

**Source**
- [06-handoff-transcript.md](06-handoff-transcript.md) #F:handoff/precompact-capture.sh
- [06-handoff-transcript.md](06-handoff-transcript.md) #cross-3

Sources: `06-handoff-transcript.md#F:handoff/precompact-capture.sh`, `06-handoff-transcript.md#cross-3`

### W2-32 · [transcript-parse] Fix discover-warm/helper drift: Grok .cwd, bridge freshness, sanitizing
**Priority** Medium · **Effort** S · **Labels** Bug · **Ticket group** —

**Problem**
`handoff/discover-warm.sh` lacks the `.cwd`-marker fallback for Grok buckets that `hosts.py` has (SPEC-036 M5a); prefers a stale `.live-session.json` bridge (step 4) with no `updated_at` freshness check; session id and transcript path can come from different env vars. `grok_normalize.py` mixes synthetic 2026-01-01 timestamps with real ones (reorders under assemble's sort), `sanitize_session_id` keeps `..`, and the unsanitized `sessionId` is written to JSON. `freshness.sh` treats a future mtime as negative age → permanent exit 9. `discover-host.sh:213-214` aborts under pipefail before the `${CMTIME:-0}` fallback; `cmd+=($(…_args))` (`:112,115`) word-splits paths; `path=` output is ambiguous with spaces. `hosts.py:201-208` monkey-patches `assemble.PROJECTS_DIR` (not thread-safe).

**Fix**
- Add `.cwd` fallback and bridge freshness; derive id and path from the same source.
- Stable timestamps for synthetic events; strip `..`; clamp future mtime; safe stat fallback; array-safe arg building; NUL/JSON output; pass PROJECTS_DIR as a parameter.

**Acceptance**
- Tests per fix (Grok `.cwd`, stale bridge, `..` id, future mtime, space path).
- discover-warm/discover-host suites pass.
- SPEC-036 M5a satisfied.

**Source**
- [06-handoff-transcript.md](06-handoff-transcript.md) #F:handoff/discover-warm.sh
- [06-handoff-transcript.md](06-handoff-transcript.md) #F:transcript-parse/grok_normalize.py
- [06-handoff-transcript.md](06-handoff-transcript.md) #F:transcript-parse/freshness.sh
- [06-handoff-transcript.md](06-handoff-transcript.md) #F:transcript-parse/discover-host.sh
- [06-handoff-transcript.md](06-handoff-transcript.md) #F:transcript-parse/hosts.py(monkeypatch)
- [06-handoff-transcript.md](06-handoff-transcript.md) #cross-4
- [10-specs.md](10-specs.md) #SPEC-036

Sources: `06-handoff-transcript.md#F:handoff/discover-warm.sh`, `06-handoff-transcript.md#F:transcript-parse/grok_normalize.py`, `06-handoff-transcript.md#F:transcript-parse/freshness.sh`, `06-handoff-transcript.md#F:transcript-parse/discover-host.sh`, `06-handoff-transcript.md#F:transcript-parse/hosts.py(monkeypatch)`, `06-handoff-transcript.md#cross-4`, `10-specs.md#SPEC-036`

### W2-33 · [orchestrate] steps/ cleanup: Step 9 TASK_ID, error handling, light-tier contradictions
**Priority** Medium · **Effort** S · **Labels** Bug · **Ticket group** —

**Problem**
`steps/09-review.md` Defensive CI-watch cleanup reads `$TASK_ID`, never set in that fresh shell → `sidecar get ""`; `:5` says `--council-tier=full` "runs council" but light tier forbids `requires_council`, so nothing runs it; the `skip`+`requires_council` conflict surfaces only after implementation. `00-resolve.md:124-128` reads MEMDB before re-deriving MROOT. `03-worktree.md:54,86` call `ensure-ticket-worktree` without error handling while cross-cutting says "No git repo: skip worktree" (ensure exits 1). `06-design.md` duplicates kickoff's Tracking block and ticket-class list. `11-ship.md` squash has no baseline/clean check and maps every assert failure to 64. `12-wrap.md` calls `$PDH/skills/retro-gate/hint.sh` directly instead of via `plugin-dir.sh file`.

**Fix**
- Substitute `TASK_ID`; reconcile light-tier text; at Step 7 halt BC1 when `COUNCIL_TIER_OVERRIDE=skip` and any task requires council.
- Fix ordering; handle ensure failure per the no-git rule; dedupe tracking text; clean/baseline check before squash with distinct exit codes; resolve hint.sh via plugin-dir.

**Acceptance**
- router-static-test extended for each fix.
- skip+requires_council halts before spawn (test).
- No unset-var reads in step fences (lint).

**Source**
- [05-orchestration.md](05-orchestration.md) #11
- [05-orchestration.md](05-orchestration.md) #20
- [05-orchestration.md](05-orchestration.md) #F:steps/00-resolve.md(memdb)
- [05-orchestration.md](05-orchestration.md) #F:steps/03-worktree.md
- [05-orchestration.md](05-orchestration.md) #F:steps/06-design.md
- [05-orchestration.md](05-orchestration.md) #F:steps/09-review.md
- [05-orchestration.md](05-orchestration.md) #F:steps/11-ship.md
- [05-orchestration.md](05-orchestration.md) #F:steps/12-wrap.md
- [05-orchestration.md](05-orchestration.md) #F:steps/07-tasks.md(halt)
- [README.md](README.md) #4.2

Sources: `05-orchestration.md#11`, `05-orchestration.md#20`, `05-orchestration.md#F:steps/00-resolve.md(memdb)`, `05-orchestration.md#F:steps/03-worktree.md`, `05-orchestration.md#F:steps/06-design.md`, `05-orchestration.md#F:steps/09-review.md`, `05-orchestration.md#F:steps/11-ship.md`, `05-orchestration.md#F:steps/12-wrap.md`, `05-orchestration.md#F:steps/07-tasks.md(halt)`, `README.md#4.2`

### W2-34 · [epic] Persist seal-intent on resume; fail rather than diverge
**Priority** Medium · **Effort** S · **Labels** Bug · **Ticket group** —

**Problem**
`skills/epic/SKILL.md` Step 0.5 BC5 seal-intent sets the session var `RELEASE_BUMP=$AUTOPILOT_BUMP` "before A.6 init", but on resume there is no init, so the session var and durable `release_bump` diverge and `assert-release-allowed` still allows a mid-epic land (the AGENTS.md seal-intent rule).

**Fix**
- On resume with `--autopilot=<bump>` and a null state `release_bump`, fail 64 (C6 policy) with guidance, instead of mutating only the session var; or persist via an explicit `epic-lib set-release-bump` call.

**Acceptance**
- epic/test.sh: resume with bump and null state fails 64 (or persists).
- assert-release-allowed blocks mid-epic land after resume.
- SPEC-025 documents the rule.

**Source**
- [05-orchestration.md](05-orchestration.md) #10
- [05-orchestration.md](05-orchestration.md) #F:epic/SKILL.md(resume)

Sources: `05-orchestration.md#10`, `05-orchestration.md#F:epic/SKILL.md(resume)`

### W2-35 · [release-train] Unblock path for blocked entries; safe atomic restore and lock
**Priority** Medium · **Effort** M · **Labels** Bug, Concurrency · **Ticket group** —

**Problem**
`blocked` is terminal: SPEC-023 M15 allows only pending→landing→landed/blocked, `drop` accepts only pending and `register` refuses a queued branch, so `SKILL.md:313`'s "re-register/re-freeze" requires hand-editing queue.json. Step 1h runs `restore` (`reset --hard`) after any `/release` failure, including one after the push, leaving local master behind origin. `train-lib.sh:772-791` `restore` has no master/main branch check; `:776-778` is dead; `acquire-lock` (~`:815`) is check-then-write with no stale detection; `register`'s `shift 2 || die` runs after reading `${2:-}`.

**Fix**
- Add `set-status blocked→pending` (with re-freeze) or allow `drop` from blocked; amend SPEC-023 M15.
- `restore` asserts master/main and refuses when HEAD was already pushed; atomic lock (`set -C`/mkdir + stale check); remove dead code.

**Acceptance**
- release-train tests: blocked entry can be requeued; restore after push refuses.
- Concurrent acquire: one wins.
- SPEC-023 updated.

**Source**
- [09-release-tooling.md](09-release-tooling.md) #10
- [09-release-tooling.md](09-release-tooling.md) #F:release-train/SKILL.md
- [09-release-tooling.md](09-release-tooling.md) #F:release-train/train-lib.sh(1,2,4)
- [02-commands-docs.md](02-commands-docs.md) #F:commands/release-train.md(dry-run)
- [README.md](README.md) #4.3
- [README.md](README.md) #wave3-release-train

Sources: `09-release-tooling.md#10`, `09-release-tooling.md#F:release-train/SKILL.md`, `09-release-tooling.md#F:release-train/train-lib.sh(1,2,4)`, `02-commands-docs.md#F:commands/release-train.md(dry-run)`, `README.md#4.3`, `README.md#wave3-release-train`

### W2-36 · [ci-watch] Cap poll errors, unique temp files, no premature green
**Priority** Medium · **Effort** S · **Labels** Bug · **Ticket group** —

**Problem**
`poll_error_count` is incremented but never capped, so permanently broken states (gh unauthenticated, worktree removed) poll every 7 minutes forever; `detect-mode.sh` treats `gh pr checks --help` success as usable even when unauthenticated, and `setup.py` alone implies pytest. `poll.sh:115-116` uses predictable fixed names `$TMPDIR/ci-watch-out-$TICKET.txt` that collide across repos; `total==0 → done` (`:210`) can declare green before checks register. The local-test path, detect-mode and sidecar are untested.

**Fix**
- Emit `cap` when `poll_error_count ≥ 10`; check `gh auth status` in detect-mode.
- `mktemp` for OUT/ERR; require non-empty checks or PR age > X before done.
- Add local-test, detect-mode and sidecar tests.

**Acceptance**
- test-poll: 10 consecutive errors → cap.
- Empty checks list within grace period → pending.
- Two repos with the same ticket don't collide.

**Source**
- [09-release-tooling.md](09-release-tooling.md) #11
- [09-release-tooling.md](09-release-tooling.md) #F:ci-watch/SKILL.md
- [09-release-tooling.md](09-release-tooling.md) #F:ci-watch/detect-mode.sh
- [09-release-tooling.md](09-release-tooling.md) #F:ci-watch/poll.sh(2-4)
- [09-release-tooling.md](09-release-tooling.md) #F:ci-watch/test-poll.sh
- [README.md](README.md) #wave3-ci-watch

Sources: `09-release-tooling.md#11`, `09-release-tooling.md#F:ci-watch/SKILL.md`, `09-release-tooling.md#F:ci-watch/detect-mode.sh`, `09-release-tooling.md#F:ci-watch/poll.sh(2-4)`, `09-release-tooling.md#F:ci-watch/test-poll.sh`, `README.md#wave3-ci-watch`

### W2-37 · [audit] Harden audit apply: verify evidence, atomic batch, scope gate, 40 KB tier
**Priority** Medium · **Effort** M · **Labels** Bug, Security · **Ticket group** —

**Problem**
`skills/audit/apply.py` "mechanical evidence" (`:49-75`) is self-asserted — passage quotes are never checked against the cited files; the batch isn't atomic (validation up front, but `apply_one` can die mid-batch; two findings on one file interact; writes in place without temp+rename); any CLAUDE.md/AGENTS.md anywhere on disk is writable though the spec scope is user-global + project walk-up. SKILL.md says "Extra confirm (`--yes` or TTY)" but apply.py only honors `--yes`. `audit.sh:20` passes `SKILL_HARD_BYTES` and never uses it, so the 40 KB must-split tier is not enforced (five SKILL.md files exceed it).

**Fix**
- Verify each quote is in the file; pre-validate all `old` counts per file, apply in memory, write via temp+rename; restrict paths to the inventory set.
- Implement the TTY confirm or fix the doc; classify > 40 KB as FAIL (with a waiver list until splits land).

**Acceptance**
- audit/test.sh: fabricated quote rejected; mid-batch failure changes nothing.
- Out-of-scope path refused.
- 40 KB file reported as must-split.

**Source**
- [09-release-tooling.md](09-release-tooling.md) #15
- [09-release-tooling.md](09-release-tooling.md) #F:audit/SKILL.md
- [09-release-tooling.md](09-release-tooling.md) #F:audit/audit.sh
- [09-release-tooling.md](09-release-tooling.md) #F:audit/apply.py
- [README.md](README.md) #4.6-audit
- [02-commands-docs.md](02-commands-docs.md) #F:commands/audit.md(file)

Sources: `09-release-tooling.md#15`, `09-release-tooling.md#F:audit/SKILL.md`, `09-release-tooling.md#F:audit/audit.sh`, `09-release-tooling.md#F:audit/apply.py`, `README.md#4.6-audit`, `02-commands-docs.md#F:commands/audit.md(file)`

### W2-38 · [doctor] doctor.sh correctness: worktree paths with spaces, safe --fix, marketplace tier
**Priority** Medium · **Effort** S · **Labels** Bug · **Ticket group** —

**Problem**
`skills/doctor/doctor.sh:1313` `awk '{print $2}'` and `:1323` `for wt in $git_wts` split worktree paths containing spaces, producing false "orphan lock" warnings. `--fix` auto-confirms when stdin is not a TTY (SPEC-022 M7 allows it), so an agent run clears `distilling_lock` regardless of age and can break a running distill. `infer_tier` has no marketplace tier (marketplace clones report `fallback`). `json_escape` doesn't escape control characters < 0x20 other than \n\r\t. Checks `memory.ext.vec`, `memory.ext.lembed`, `hooks.templates`, `settings.agent_teams` have no tests.

**Fix**
- Parse `git worktree list --porcelain` line-wise.
- `--fix` clears `distilling_lock` only when older than the TTL (or with explicit `--force`).
- Add marketplace tier; escape all control chars; add tests for the four checks.

**Acceptance**
- doctor/test.sh: worktree path with a space → no false warning.
- Non-TTY `--fix` leaves a fresh lock.
- New check tests pass.

**Source**
- [09-release-tooling.md](09-release-tooling.md) #F:doctor/doctor.sh(2-5,7)

Sources: `09-release-tooling.md#F:doctor/doctor.sh(2-5,7)`

### W2-39 · [release] release/SKILL.md correctness pass: REF, tagless describe, resolver consistency
**Priority** Medium · **Effort** S · **Labels** Bug · **Ticket group** —

**Problem**
`skills/release/SKILL.md:46-59` on master falls back `REF` to the repo basename and passes it to `assert-release-allowed` (works only because epic-lib returns 0 for unknown ids); the master/main guard at `:61` tests `REF`, not `BR`. `git describe --tags --abbrev=0` (`:141,183`) is empty in tagless/shallow clones, so auto-detect and "Nothing to release" misfire. `:295` says C1–C4 (C5 exists). Steps 4.5–4.10/4.12 use cwd-relative `bash skills/...` while 4.11/5/5.5 use PDH. `:423` calls a gate "optional but preferred". `check-staged-paths.sh` uses `--name-only` without `-z` (quotePath paths never match) and doesn't normalize `./x`. `install-git-hooks.sh` silently disables existing `.git/hooks` (e.g. husky).

**Fix**
- Test `BR` for the master guard; skip the assert on master; handle tagless repos explicitly (first-release path).
- Resolve all steps via PDH; say C1–C9 (after lint item); make the gate mandatory.
- `-z` + normalization in check-staged-paths; warn on existing non-sample hooks.

**Acceptance**
- release/test.sh covers tagless repo and master REF.
- check-staged-paths test with a space/non-ASCII path.
- No cwd-relative `bash skills/` in release SKILL (lint).

**Source**
- [09-release-tooling.md](09-release-tooling.md) #F:release/SKILL.md(2-6)
- [09-release-tooling.md](09-release-tooling.md) #F:release/check-staged-paths.sh
- [09-release-tooling.md](09-release-tooling.md) #F:release/install-git-hooks.sh

Sources: `09-release-tooling.md#F:release/SKILL.md(2-6)`, `09-release-tooling.md#F:release/check-staged-paths.sh`, `09-release-tooling.md#F:release/install-git-hooks.sh`

### W2-40 · [files] Fix mktemp+mv writes that leave repo files 0600 or non-atomic
**Priority** Medium · **Effort** S · **Labels** Bug · **Ticket group** —

**Problem**
Files built with `mktemp "$TMPDIR"` then `mv` into the repo end up mode 0600 and the rename isn't atomic across filesystems: `release-train/train-lib.sh` (write_queue, renumber, resolve-json → `plugin.json`, `marketplace.json`), `backlog/close.sh` and `reconcile.sh` (backlog.md), `memory-store/seed-common.sh:254` (`.gitignore`). Council reports via `mkstemp` are 0600. SPEC-023 M1 itself prescribes "rename under ${TMPDIR:-/tmp}".

**Fix**
- Create temp files in the destination directory (`mktemp "$dir/.x.XXXXXX"`), copy the original mode (`chmod --reference` or stat fallback), then `mv`.
- Shared `atomic_write` helper in portable.sh; amend SPEC-023 M1.

**Acceptance**
- Tests: rewritten plugin.json/backlog.md/.gitignore keep 0644.
- No cross-FS rename (temp in same dir).
- SPEC-023 text updated.

**Source**
- [09-release-tooling.md](09-release-tooling.md) #cross-4
- [09-release-tooling.md](09-release-tooling.md) #F:release-train/train-lib.sh(3)
- [09-release-tooling.md](09-release-tooling.md) #F:backlog/close.sh(3)
- [07-memory.md](07-memory.md) #F:memory-store/seed-common.sh(0600)
- [04-council.md](04-council.md) #F:council/engine.sh(11)
- [10-specs.md](10-specs.md) #SPEC-023-M1

Sources: `09-release-tooling.md#cross-4`, `09-release-tooling.md#F:release-train/train-lib.sh(3)`, `09-release-tooling.md#F:backlog/close.sh(3)`, `07-memory.md#F:memory-store/seed-common.sh(0600)`, `04-council.md#F:council/engine.sh(11)`, `10-specs.md#SPEC-023-M1`

### W2-42 · [code-simplify] Re-review simplify edits; safe revert; untracked scope
**Priority** Medium · **Effort** M · **Labels** Bug · **Ticket group** —

**Problem**
`skills/code-simplify/SKILL.md` edits land after Tech Lead APPROVE and are never re-reviewed. `:43-44` "revert the simplify edits" doesn't say how; `git checkout -- f` would wipe uncommitted IC work too. Scope discovery (`:55-65`) misses untracked files. A manual run with no orchestrate context has no sensible home (should route to `/refactor`).

**Fix**
- Commit IC work before the simplify spawn; revert via `git reset --hard <pre-simplify-sha>` inside the worktree.
- Hand simplify edits to the Tech Lead as a delta review (or run before APPROVE); include untracked files.
- Route manual runs without orchestrate context to `/refactor`.

**Acceptance**
- Static test for the pre-simplify commit and reset instructions.
- Orchestrate step 9/10 references the delta review.
- Manual invocation text points to /refactor.

**Source**
- [08-workflow-skills.md](08-workflow-skills.md) #22
- [08-workflow-skills.md](08-workflow-skills.md) #F:code-simplify/SKILL.md
- [08-workflow-skills.md](08-workflow-skills.md) #overlap-refactor-simplify

Sources: `08-workflow-skills.md#22`, `08-workflow-skills.md#F:code-simplify/SKILL.md`, `08-workflow-skills.md#overlap-refactor-simplify`

### W2-43 · [review-and-commit] Rebuild as `council --diff --tier full` + commit-gate post-step
**Priority** Medium · **Effort** M · **Labels** Tech Debt · **Ticket group** —

**Problem**
`commands/council.md:30` calls review-and-commit and `/council --diff` "equivalent", but review-and-commit adds SAST, `--impact`, a legacy render and the commit gate, and always runs full tier. Two render paths are why the category-mapping drift (P0-16) happened.

**Fix**
- Make review-and-commit literally `council --diff --tier full` plus a `commit-gate` post-step.
- Move the Step 6 render into `skills/council/templates/`; keep SAST/impact as optional pre-steps.
- Fix the council.md:30 wording.

**Acceptance**
- One render template for both surfaces.
- review-and-commit output unchanged for a fixture (golden).
- Category-parity test still passes.

**Source**
- [08-workflow-skills.md](08-workflow-skills.md) #overlap-review-and-commit
- [03-large-commands.md](03-large-commands.md) #F:commands/council.md:30

Sources: `08-workflow-skills.md#overlap-review-and-commit`, `03-large-commands.md#F:commands/council.md:30`

### W2-44 · [commands] Fix cross-fence state: adjust-agent $AGENT, council COUNCIL_TIER/PLAN_FILE
**Priority** Medium · **Effort** S · **Labels** Bug · **Ticket group** —

**Problem**
`commands/adjust-agent.md` Steps 4–6 use `$AGENT`, never set in the shell, hidden by `lint-ok: C1` waivers (`:125,142,167,264`). `commands/council.md` assigns `COUNCIL_TIER` in one fence (`:359`) and reads it in Step 2.5 (`:432`), so the light-tier Workflow fallback relies on model substitution; `PLAN_FILE` likewise (`:548,633`), and comments at `:546,632` say it was created in Step 1 (actually Step 2, `:370`).

**Fix**
- Persist these values to a per-run state file (or have each fence re-derive/receive them as literal substitutions with an explicit template marker); remove the waivers.
- Fix the Step 1 → Step 2 comments.

**Acceptance**
- No `lint-ok: C1` waiver remains for these vars.
- Extracted fences run standalone given the state file.
- Skill-lint passes without waivers.

**Source**
- [README.md](README.md) #4.2
- [02-commands-docs.md](02-commands-docs.md) #F:commands/adjust-agent.md(2)
- [03-large-commands.md](03-large-commands.md) #C6
- [03-large-commands.md](03-large-commands.md) #C7

Sources: `README.md#4.2`, `02-commands-docs.md#F:commands/adjust-agent.md(2)`, `03-large-commands.md#C6`, `03-large-commands.md#C7`

### W2-45 · [commands] Implement or remove dead flags (memory, council, spec)
**Priority** Medium · **Effort** S · **Labels** Bug · **Ticket group** —

**Problem**
Documented flags do nothing: `/memory --compress`/`MEMORY_COMPRESS` (`commands/memory.md:222-224`) aren't parsed or applied (M9); `/memory stats --agent` (`:628`) filters nothing and `embedding_meta` may not exist in older DBs (M10); `_COUNCIL_WORKFLOW_FLAG` (`commands/council.md:418`) is never set anywhere, so `--workflow` only works if the model invents it (C5); `/spec check audit` (`commands/spec.md:337`) is parsed as spec ID "audit" (S2).

**Fix**
- memory: wire `--compress` into distill Step 6 or remove it; add `WHERE agent=?` to stats and guard `embedding_meta` existence.
- council: set the flag in Step 0.5 parse.
- spec: define `audit` as a keyword or remove the example.

**Acceptance**
- Each flag has a test or is gone from docs and argument-hint.
- `stats --agent pm` shows only pm rows.
- `/spec check audit` behaves as documented.

**Source**
- [03-large-commands.md](03-large-commands.md) #E13
- [03-large-commands.md](03-large-commands.md) #M9
- [03-large-commands.md](03-large-commands.md) #M10
- [03-large-commands.md](03-large-commands.md) #C5
- [03-large-commands.md](03-large-commands.md) #S2

Sources: `03-large-commands.md#E13`, `03-large-commands.md#M9`, `03-large-commands.md#M10`, `03-large-commands.md#C5`, `03-large-commands.md#S2`

### W2-46 · [specs] Spec ownership registry; specs for /mode, /tdd-gate, domain-glossary
**Priority** Medium · **Effort** M · **Labels** Tech Debt · **Ticket group** —

**Problem**
Several specs claim the same files with no ownership map: `skills/transcript-parse/` (SPEC-012 owner, SPEC-018, SPEC-036 hosts.py), `autopilot/parse-flags.sh`/`loc-exclude.sh` (SPEC-009, SPEC-033), init-orchestration hook templates (SPEC-002, 005, 031), `orchestrate/steps/*` (SPEC-009, 017, 026, 037). `commands/mode.md` (focus/blunt), `commands/tdd-gate.md` and `skills/domain-glossary` have no spec.

**Fix**
- Add `owner:` vs `cites:` to Covers, or a `specs/OWNERS` path-glob → spec map; check-index rejects two owners for one path.
- Write short specs (or explicit "unspecced" entries) for /mode, /tdd-gate, domain-glossary.

**Acceptance**
- check-index enforces single ownership.
- Every shipped surface maps to a spec or an explicit unspecced entry.
- TDD index updated.

**Source**
- [10-specs.md](10-specs.md) #6
- [10-specs.md](10-specs.md) #cross-ownership
- [10-specs.md](10-specs.md) #numbering-unspecced
- [10-specs.md](10-specs.md) #SPEC-012-claims
- [10-specs.md](10-specs.md) #SPEC-017-claims

Sources: `10-specs.md#6`, `10-specs.md#cross-ownership`, `10-specs.md#numbering-unspecced`, `10-specs.md#SPEC-012-claims`, `10-specs.md#SPEC-017-claims`
