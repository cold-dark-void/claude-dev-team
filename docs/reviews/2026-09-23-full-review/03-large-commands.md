## Slice: large commands

I read all four files in full: council.md (1385 lines), memory.md (1795), retro.md (1967) and spec.md (777). Together they are about 258 KB, roughly 65k tokens, all loaded into context each time one of these commands runs. I cross-checked them against skills/council/SKILL.md, skills/autopilot/ship-gate-council.md, skills/retro-subagent/SKILL.md, skills/memory-store/export-seed-pack.sh, skills/spec-tooling/*, and specs SPEC-007, -008, -011, -012, -013 and -037. I edited nothing.

Repetition counts per file (PDH = the plugin-dir lookup one-liner, ~1.1 KB each):

| File | PDH one-liners | `_gc=` root blocks | `lint-ok` pragmas | CDT/CDV ticket refs |
|---|---|---|---|---|
| council | 8 | 3 | 14 | 51 |
| memory | 1 | 45 | 18 | 1 |
| retro | 12 | 17 | 60 | 25 |
| spec | 0 | 0 | 0 | 0 |

### Per-file review

#### commands/council.md (72 KB, ~18k tokens)
**Purpose:** a wrapper around `skills/council/engine.sh` that drives the tribunal (Phases 1–5), plus a separate `--blind` multi-team review path.
**Verdict:** the logic is sound, but the file is heavily bloated. It carries about 175 lines of tier-grading procedure it never runs itself, and one contradiction with SKILL.md about the model map.

| # | Sev | Where | Finding |
|---|---|---|---|
| C1 | P1 | 463-470 vs SKILL.md:99-105, 386-388, 679-684 | Contradiction in the model-map intro. It says "`ic5` investigators, `ic4` cross-reviewers… Named fallback `ic5`→`ic4`". The actual spawns (583, 805) and SKILL.md use `dev-team:finder`, with fallback `finder`→`ic5` (CDT-230). The intro is stale. |
| C2 | P1 | 1041-1047 | The finalize fence is labelled plain ```` ```bash ```` (not `bash template`), but it is not valid bash. `--plan-file "$PLAN_FILE" \  # lint-ok: C1`: the backslash escapes a space instead of the newline, so the command ends there. `[--task-id …]` brackets and trailing comments break the continuation too. Run literally, it calls finalize with only `--plan-file`. It should be marked as a template, or the pragma moved to its own line. |
| C3 | P1 | 1149-1158 (B1) | `git ls-files "$MROOT/$TARGET"`: from a linked worktree, `$MROOT` is the main checkout, so git errors "outside repository" and the fallback `find` reviews the main checkout, not the worktree. Also, `git ls-files` exits 0 with empty output for untracked paths, so the fallback never fires. Use `$WTROOT` with repo-relative paths. `grep -v '.git/'` has an unescaped dot; `grep -v 'dist/'` also drops paths like `redist/`. |
| C4 | P2 | 139-315 (§1.5.1–1.5.5) | About 175 lines of tier-grading procedure (`tier-grade.sh` + haiku triage) that the command itself says it does not run (§1.5.1). They stay here only because `skills/autopilot/ship-gate-council.md:124,130`, `prompts/tier-triage.md:6,25,179` and `skills/orchestrate/steps/08-execute.md:119` cite "commands/council.md § 1.5.2". This is the biggest candidate to move out (E1). |
| C5 | P2 | 418 | `_COUNCIL_WORKFLOW_FLAG` is never set anywhere in the repo (checked with grep). It is a dead variable: `--workflow` only takes effect if the model invents it. |
| C6 | P2 | 359 vs 432 | `COUNCIL_TIER` is assigned in one fence and read in another (Step 2.5). Each fence is a fresh shell, so the light-tier Workflow fallback depends entirely on the model re-substituting it. The same fragility applies to `PLAN_FILE` (548, 633). |
| C7 | P2 | 546, 632 | Comments say `PLAN_FILE` was "created in Step 1"; it is actually created in Step 2 (370). Stale. |
| C8 | P2 | 550 | `sha256sum` is GNU-only. macOS needs `shasum -a 256`, so the cache seed silently no-ops there. |
| C9 | P2 | 663-667 vs 744-748 vs 1377-1379 | The Phase 3 `--why` string list and the Rules section leave out `skipped (council_tier: light)`, which 667 defines. |
| C10 | P2 | 758-760 | The Phase 2.5 bypass ("fewer than 3 investigators") does not say whether that is per claim or per run. The generic preset has 2 flavors (`engine.sh:277`), so a single claim always bypasses unless the specialist or external slot fires. Line 737 implies per claim. |
| C11 | P3 | 1039 | `TOKENS_FILE=…council-tokens-$$.json` uses a predictable name, is never cleaned up, and is inconsistent with the `mktemp` used elsewhere in the file (370, 629). |
| C12 | P3 | 1248-1249 | The blind report path `${DATE}-blind[-slug].md` is overwritten by a second run on the same day. |
| C13 | P3 | 1380 | "Phase 7 (feedback memory)" appears only in the Rules; Phases 6 and 7 live in SKILL.md:869/1090 and are never introduced here. |
| C14 | P3 | 835-839 | WEAK_EVIDENCE is "≤ 25th-percentile". This always flags at least one bundle, even when all bundles are strong. |
| C15 | ctx | 115, 368, 415, 564, 626, 786, 921, 1037 | 8 identical PDH lines (~9 KB). The finder resolver block appears twice verbatim (564-579, 786-801), even though 466 says "Do not paste full PDH at every later spawn of the same role". |
| C16 | ctx | 1121-1345 | The `--blind` path (~225 lines) loads on every tribunal run although it is a separate execution path, and it duplicates SKILL.md § Blind-review path. |

#### commands/memory.md (65 KB, ~16k tokens)
**Purpose:** dispatcher for `config`, `distill`, `export`, `search`, `stats` and `validate` (the last including `--deep` and `--reconcile`).
**Verdict:** has real P0 bugs. Several SQL strings contain bash comments, the distill → validate lock deadlocks itself, and there is code injection through the python fallback. About 58% of the file is the `validate` sub.

| # | Sev | Where | Finding |
|---|---|---|---|
| M1 | **P0** | 413, 1426, 1516 | `# lint-ok: C1` sits inside double-quoted SQL strings (e.g. `HAVING COUNT(*) >= $THRESHOLD  # lint-ok: C1`). It becomes part of the SQL. I checked with python's sqlite3 module (the sqlite3 CLI is not installed here): `unrecognized token: "#"`. The all-agents distill target query, deep-mode digest query and rebuild source query all fail. |
| M2 | **P0** | 314-334 + 357 vs 831-845 | Self-deadlock. Distill takes `distilling_lock` (Step 4), then Step 4.5 says to run validate "Steps 1–8". Validate Step 1 exits with an error when that same lock is held (as SPEC-011:101 requires). So every default `/memory distill` fails validation and aborts. Neither SPEC-011 nor SPEC-007 defines an exemption for the pre-distill call. |
| M3 | **P0** (security) | 993-994, 1016 | The containment-guard fallback runs `python3 -c "…os.path.join('$WTROOT','$REF_PATH')"`. `REF_PATH` is LLM-extracted from memory content (untrusted, as the file itself says at 982). A `'` in the path injects Python code. The fallback runs whenever `realpath -m` is missing (macOS/BSD `realpath` has no `-m`). `relpath()` has the same flaw with `'$1'`. Pass values via argv or env. |
| M4 | P1 | 437, 442, 882 | `--agent <name>` is interpolated unescaped into SQL (`agent='$AGENT'`) and is never checked against the roster. |
| M5 | P1 | 329-333, 417-422, 474-487 | Lock not acquired, or no agents found: the only response is a `# Stop here` comment, with no `exit`. Step 8 then releases unconditionally (`SET value=''`) without comparing the holder token. A run that failed to get the lock can clear another process's live lock. Release should be `WHERE value='$MY_TOKEN'`. The same `# Stop here` without `exit` appears at 252, 807, 824, 827, 844. |
| M6 | P1 | 1489-1524 | Deep rebuild archives the digest first, then re-distills. If the distiller fails, the digest is gone and its sources stay archived as `distilled`, so the knowledge is lost. It also only *checks* the lock (10.4) and never takes it, so it can race. Re-distill first, archive after success, and hold the lock throughout. |
| M7 | P1 | 1587-1600, 1706-1775 | Reconcile resolves `PLUGIN_ROOT` via `$WTROOT` or `$CLAUDE_PLUGIN_ROOT`, not via `plugin-dir.sh` as AGENTS.md requires. On a real install `$WTROOT` has no `skills/`, and if `CLAUDE_PLUGIN_ROOT` is unset the lib path doesn't exist. `\|\| true` (1612) swallows that, `CAND_N` comes out empty (not 0), and the R1 "if 0" branch is ambiguous. The PLUGIN_ROOT boilerplate is repeated 6 times. |
| M8 | P1 | 928 vs 885-890 | Step 3.1 tells the reader to "add `LIMIT 100` to the Step 2 SQL", but the Step 2 SQL has no LIMIT. Put it in the query itself. |
| M9 | P2 | 222-224 vs 256-261 | The `--compress` flag and `MEMORY_COMPRESS` are documented but are not in the flag parser, and no step applies them. Dead flag. |
| M10 | P2 | 628 | `stats --agent <name>` is documented but none of the queries filter by agent. Dead flag. `embedding_meta` may not exist in older databases and would error. |
| M11 | P2 | 198-205 | `config set` uses a plain `UPDATE`. If the row is missing (e.g. `validate_window_days` or `reconcile_pair_cap` on a pre-v3/v4 database), it silently does nothing but still prints "Updated". Use an UPSERT or check `changes()`. `distill_model` accepts any non-empty string. |
| M12 | P2 | 1443-1451 | `SOURCE_IDS_CSV` from `tr ' ' ','` produces `1,,2` if `distilled_from` has spaces (e.g. from python `json.dumps` defaults), and `IN ()` when empty. The `TOTAL_SOURCES==0` guard (1461) runs *after* the query. |
| M13 | P2 | 1339-1348 | REWRITE updates content but does not re-embed, so the `embedding_meta` vector no longer matches the text. |
| M14 | P2 | 535 | `bash "$EXPORT_SH" $ARGUMENTS "$MROOT"` is unquoted, and `$ARGUMENTS` includes the word `export`. It only works because the script's positional `MROOT` is overwritten by the trailing `"$MROOT"` (export-seed-pack.sh:40-41). |
| M15 | P2 | 1150-1182 | The scoring "bash template" mixes Python dict syntax with bash integer arithmetic on float `raw_score`. BSD `date -j -f '%Y-%m-%dT%H:%M:%SZ'` fails if `created_at` uses SQLite's default `YYYY-MM-DD HH:MM:SS` format. |
| M16 | P3 | 1403-1413 vs 1486 | Deep mode says both "skip to 10.6 reporting" and "Exit deep mode with an error". Pick one. |
| M17 | P3 | 1038, 1068 | `find … -name X -maxdepth 3` puts the option order backwards (GNU warns). `grep -F "$SYM_NAME"` needs `--` or `-e` for symbols starting with `-`. |
| M18 | P3 | 34-39 | "former `/memory-config`" provenance column is history, not instruction. `distill_mode` is settable but unused by this command. |
| M19 | ctx | whole file | The 4–6 line `_gc/MROOT/WTROOT/MEMDB` block appears 45 times (~7 KB). Several inner copies are mis-indented inside numbered lists (363-367, 1495-1499, 1509-1513). The tier-status SQL is duplicated in distill `--status` (276) and search `--status` (600). |

#### commands/retro.md (87 KB, ~22k tokens)
**Purpose:** session retrospective. Discovers sessions for multiple hosts, gates them, runs a haiku deep-read, validates and ranks proposals, classifies them against existing rules, reviews trials, and applies. `--all --auto` is the scheduled path.
**Verdict:** the largest file, and mostly deterministic code pasted as prose. Its shared state across fences is broken: the scheduled lock and the report writer do not work as documented.

| # | Sev | Where | Finding |
|---|---|---|---|
| R1 | **P0** | 150 vs 1900 | `trap '… release' EXIT` is set inside the Step 1b fence. Each fence is a fresh shell (the file says so at 234 and 617), so the trap fires as soon as Step 1b ends. `scheduled.lock` is therefore released immediately and concurrent cron runs are not excluded. 1900 claims "The EXIT trap from Step 1b releases scheduled.lock", which is false. |
| R2 | **P0** | 157-179 vs 602, 745, 1521, 1962 | `write_scheduled_report_if_needed` is defined only in the Step 1b fence and called from four later fences, where it is undefined (`command not found`). The SPEC-012 S1/S3 scheduled report is never written by literal execution. `SCHED_WRITER`, `MODE` and `AUTO` are also missing in those fences. |
| R3 | P1 | 465-466, 473, 591, 1676, 1774, 1883, 1957-1959 | `$(… \| grep -c . \|\| echo 0)` gives `"0\n0"` when the count is 0, because `grep -c` prints 0 and exits 1. I reproduced it: `[ "$x" -eq 0 ]` → "integer expression expected". The `--host grok` "no sessions" error branch (466) and the directive counts for empty files are broken. Use `grep -c . \|\| true` or `${x:-0}`. |
| R4 | P1 | 1100-1126 | Top-5 cap (4e) runs **before** the `--all` repeat/singleton filter (4f/5a). Repeats are counted only among the top 5, so SPEC-012:95 ("collapse findings that occurred only once across all sessions") is evaluated on a truncated set. Singletons are counted per proposal row, not per distinct session. Exact-string `pattern_summary` matching across independent haiku runs will almost never match, so `--all` drops nearly everything. |
| R5 | P1 | 543 | `sh "$FRESHNESS"`, but `freshness.sh` has a `#!/usr/bin/env bash` shebang. Under dash, any bash-ism errors give an rc that is neither 0 nor 9, so the session is treated as fresh and the 60 s in-progress guard is silently disabled. Use `bash`. |
| R6 | P1 | 1312-1314 vs 1325, 1344-1355, 1662 | TIGHTEN merge (5d) is contradictory. The schema says col 4 is "deterministically merged by Step 5d", 1312 says the orchestrating Claude does it at presentation time, 5d says it happens "in the same Python pass… or post-loop", and there is no code for it. Apply (1662) passes `proposed_text` "unchanged". |
| R7 | P2 | 1171-1189 | Step 5b loads `RULES_PM..RULES_CLAUDE` via `load_rules_raw`, and nothing reads them: Step 5c re-`cat`s the files (1231-1238). Dead code, plus a stale note at 772-774. |
| R8 | P2 | 1517 vs 1503-1511 | The prose says to short-circuit only if proposals, observations **and** `TRIAL_DECISIONS` are empty. The code ignores `TRIAL_DECISIONS`. |
| R9 | P2 | 1919-1931 | `APPLIED_FILE` writes every NEW/TIGHTEN row, including ones parked in `MANUAL_FOLLOWUP`, even though the comment says to exclude them. The scheduled report over-reports applied items. |
| R10 | P2 | 909-916 (parse_one) | Only tabs are sanitized, not newlines, and `target` / `pattern_summary` are not sanitized at all. A newline in `proposed_text` splits the TSV row before Rule 3b runs, so a truncated proposal passes validation. An adversarial `pattern_summary` with a tab shifts columns. |
| R11 | P2 | 667-675 | The `--all` "2 s per-file cap" is measured after `gate.sh` finishes. Nothing is capped; completed results are just thrown away. |
| R12 | P2 | 318 | `find -printf` is GNU-only. On macOS without hosts.py, single-mode discovery returns nothing. |
| R13 | P2 | 53, 240 | `for arg in $ARGUMENTS` is subject to word-splitting and globbing. Unknown flags only warn (86). The whole Step 1 parser (60 lines) is duplicated verbatim at 234-273. |
| R14 | P3 | 1534 | "see Step 6f" for duplicates; they are in 6d (6f is observations). There is no Step 4a. |
| R15 | P3 | 1679 | Default-mode `a` for team agents only *prints* `/adjust-agent …` but increments `APPLIED`, so the summary claims changes that were never made. |
| R16 | P3 | 815-820, 1412-1417 | `'$JSONL '` is interpolated into Python source (breaks on a quote). The `trial-review-$$.err` temp name is predictable (allowed under AGENTS.md, but inconsistent with the file's `mktemp` use). |
| R17 | P3 | 768 | The gate is re-run per session in 4b ("~60ms") although Step 3b already had its output. |
| R18 | ctx | whole file | 12 PDH lines (~13 KB), 60 `lint-ok` pragmas, and three large embedded programs (parse_one ~50 lines, the Jaccard classifier ~60, Step 2 discovery ~260) that the LLM re-reads on every run instead of executing as scripts. |

#### commands/spec.md (34 KB, ~8.5k tokens)
**Purpose:** `/spec` dispatcher. check, create, find, list and update are inline; generate, tests and reflect delegate to `skills/spec-tooling`.
**Verdict:** clean and consistent with SPEC-008 (the source-exclude includes are byte-identical). The main issues are stale migration scaffolding and the inline subs costing context.

| # | Sev | Where | Finding |
|---|---|---|---|
| S1 | P2 | 22-26, 721-722, 740-741, 758, 767-777 | Stale migration history. "transplanted from `commands/check-specs.md`…", "Maps from `/generate-specs`", "Notes for consumers (Tasks 9/11/13)… legacy `/check-specs`… remain until Task 12 stubs them". None of those legacy commands exist (checked with ls). This is changelog prose in an instruction file. |
| S2 | P2 | 337 vs 68 | `/spec check audit` is listed as "Explicit audit mode", but the parser treats any non-flag token as a spec ID, so `audit` becomes spec ID "audit". Either define it as a keyword or remove the example. |
| S3 | P2 | 416 (skeleton include) | The skeleton hard-codes `**Category**: core`, while Step 2 offers PERF/SAFE/COMPAT/ARCH. Non-core specs get the wrong category unless the model notices. It needs a `<CATEGORY>` token (fix in `skills/spec-tooling/spec-skeleton.md`, then sync). |
| S4 | P2 | 490-503 | The `find` example shows `**Status**: ✅` / `🔄 UPDATED`, which contradicts the lifecycle vocabulary (INFERRED/DRAFT/ACTIVE/APPROVED/DEPRECATED) enforced at 81 and 580-585. |
| S5 | P2 | 110-117 (and SPEC-008:178-181) | The canonical exclude set drops `*.md` and `*.json`. For this plugin (pure markdown/bash), Phase 2 and validate mode find almost no "source", so `/spec check` on its own repo always says "code alignment skipped". Phase 3 handles frameworkless repos; Phase 2 does not. This is a spec-level gap to raise with SPEC-008's owner. |
| S6 | P3 | 32, 66 | `--gate` without `--tests` is undefined. It should hard-fail or imply `--tests`. |
| S7 | P3 | 386 | The example `AUTH-003` uses a prefix outside the allowed set (SPEC/PERF/SAFE/COMPAT/ARCH). |
| S8 | P3 | 532 | "Categories (derived from ID prefix or Coverage column)": Coverage does not carry the category; use the prefix or directory. |
| S9 | ctx | 112-117, 278-283, 658-663 | The same include is inlined 3 times, deliberately (SPEC-008 drift gate), so it is cheap to keep. The real cost is that all 5 inline subs load for every sub invocation. |

### Cross-cutting findings
1. **Cross-fence shell state (retro R1/R2, council C5/C6, memory M5).** All three bash-heavy commands rely on functions, traps and variables defined in one fence being alive in a later one, while also saying (retro 234/617) that each fence is a fresh shell. Every contract that depends on this (locks, report writers, tier fallback, workflow opt-in) is broken if executed literally, or works only through model improvisation. The fix is structural: move stateful pipelines into real scripts under `skills/<x>/` and call them once per step with explicit args, or persist state to a mktemp state file.
2. **Lint-pragma placement causes bugs.** `# lint-ok: C1` appended to lines inside quoted SQL (memory M1) or after a line-continuation backslash (council C2) changes semantics. skill-lint should require pragmas on their own line, or check that a pragma is not inside an open quote or continuation.
3. **`# Stop here` without `exit`** appears throughout memory.md. Pick one convention (a real `exit N`) so literal execution matches the prose.
4. **Boilerplate is most of the context cost.** 21 PDH one-liners (~23 KB), 65 `_gc` root blocks (~9 KB) and 3 resolver fences (~5 KB) across the slice, about 9–10k tokens, with no instruction value after the first copy.
5. **Changelog prose in instruction files.** Ticket IDs (council 51, retro 25), "used to auto-grade… removed because…" (council 145-158), "transplanted from" and "Tasks 9/11/13" (spec). This belongs in CHANGELOG or the specs.
6. **Inconsistent plugin-root resolution.** memory.md reconcile uses `$WTROOT` / `$CLAUDE_PLUGIN_ROOT` while everything else uses PDH + `plugin-dir.sh` (AGENTS.md Worktree Protocol).
7. **Portability gaps:** `realpath -m`, `find -printf`, `sha256sum` and `sh` running a bash script. Each has a silent-failure mode rather than a loud one.
8. **Untrusted text interpolated into code:** python `-c` with `'$VAR'` (memory M3, retro R16) and SQL with `'$AGENT'` (memory M4). Standardize on argv/env passing, the pattern already used correctly at memory.md:198-204 and retro.md:1240-1245.

### Enhancement proposals

| # | Title | Rationale | Concrete change | Effort | Pri |
|---|---|---|---|---|---|
| E0 | Fix the P0 bugs | They break commands on every run | memory: move `# lint-ok` out of the SQL at 413/1426/1516. Exempt pre-distill validate from the lock guard (pass an internal "lock-owner = this run" flag, and document it in SPEC-011 as the pre-distill exemption). Replace the python fallbacks with argv/env (`python3 -c 'import os,sys;print(os.path.normpath(os.path.join(sys.argv[1],sys.argv[2])))' "$WTROOT" "$REF_PATH"`). retro: move lock acquire/trap and the report-writer call into one script (`skills/retro-gate/scheduled-run.sh wrap`), or re-define the helper and release the lock explicitly at every exit site. | S–M | P0 |
| E1 | Move council tier-grading into a skill file | Saves ~175 always-loaded lines that this command never runs | Create `skills/council/tier-grading.md` with §1.5.2–1.5.5 verbatim. Leave a 10-line §1.5 (passthrough only) in council.md. Update the cites in `ship-gate-council.md:124,130`, `prompts/tier-triage.md:6,25,179` and `orchestrate/steps/08-execute.md:119`. About −9 KB. | S | P1 |
| E2 | Load the `--blind` path on demand | A separate execution path should not load on tribunal runs | Move 1121-1345 to `skills/council/blind-path.md` (merge with SKILL.md § Blind-review path to remove the duplication). Step 0.5 then says "scope=blind → Read that file and follow it". About −8 KB. | S | P1 |
| E3 | Split memory.md into a router plus per-sub modes | 1795 lines load for `/memory stats` | Keep `commands/memory.md` as dispatch, usage and one root-resolution block (~120 lines). Move subs to `skills/memory-store/modes/{config,distill,export,stats}.md`, `skills/validate-memory/host-pipeline.md` (validate Steps 1–11) and `skills/validate-memory/reconcile.md` (R1–R4). Router reads the one mode file needed. About −1650 lines always loaded (~15k tokens). Fixes M2 in the same move. | M | P1 |
| E4 | Turn retro's embedded programs into scripts | Deterministic code as prose costs ~12k tokens a run and causes the cross-fence bugs | `skills/retro-gate/discover.sh` (Steps 1–2d → prints gate-feed paths plus counters JSON); `parse-results.py` (4d parse/validate/anchor persist, also fixing R10); `classify.py` (5a–5e including the missing 5d merge, fixing R4 ordering by filtering repeats before the top-5 cap); `scheduled-run.sh` (lock + report). retro.md becomes about 350 lines of orchestration and UI (confirm loop, Task spawns). About −1500 lines. | L | P1 |
| E5 | Consolidate PDH and resolver boilerplate | ~10k tokens of repetition across the slice | Define PDH once per file in Step 0 ("re-use this line verbatim in later fences"), or add a tiny `skills/pdh.sh` printing the root. Council's 3 resolver fences become one reference to SKILL.md § Model map with the agent name as the only variable. The same applies to memory's 45 `_gc` blocks: one canonical block, and later fences reference `$MEMDB` from the state file. | M | P2 |
| E6 | Router-ize spec.md | 5 inline subs load together | Move check/create/find/list/update into `skills/spec-tooling/modes/*.md`, matching generate/tests/reflect. `commands/spec.md` becomes about 60 lines. Keep the `<!-- include -->` regions in the mode files (the sync-includes.py consumer list needs updating). Delete the S1 stale prose. About −700 lines. | M | P2 |
| E7 | Strip historical and changelog prose | Instruction files should state current behavior | Remove council 145-158 ("used to auto-grade…") and the ticket-ID parentheticals that carry no instruction value. Remove the memory "former /…" column, spec "transplanted from" / "Maps from" / "Notes for consumers". Keep IDs only where a spec MUST is cited. | S | P2 |
| E8 | Make skill-lint reject unsafe pragma placement | Prevents M1/C2-class bugs coming back | In `skills/skill-lint`, fail when `lint-ok` appears after an unclosed quote or after a trailing `\`. Add a check that `# Stop here` comments in executable fences are followed by `exit`. | S | P2 |
| E9 | Lock-token ownership in distill | Prevents one run from clearing another's lock (M5) and fixes M6 | Store the token from Step 4 and release with `WHERE value='$TOKEN'`. Take the lock in deep mode. Re-distill before archiving. | S | P1 |
| E10 | Standardize untrusted-input passing | Removes the SQL/py injection class | Validate `--agent` against the roster regex `^(pm\|tech-lead\|ic5\|ic4\|devops\|qa\|ds)$` at parse time in distill/validate/stats. Use python `?` params for every write carrying LLM text. Add a guard to AGENTS.md Code Conventions. | S | P1 |
| E11 | Fix the retro count idiom and portability | Removes R3, R5, R12 and C8 | Global `grep -c … \|\| echo 0` → `\|\| true`; `sh` → `bash`; `find -printf` → `stat` loop or python; `sha256sum` → `shasum -a 256` fallback. | S | P1 |
| E12 | Council blind path: worktree-correct scope and unique report names | Fixes C3 and C12 | Use `git -C "$WTROOT" ls-files -- "$TARGET"` with a fallback when the list is empty. Add `-HHMMSS` to the report name. | S | P1 |
| E13 | Implement or remove the dead flags | They mislead users | memory `--compress` (wire into distill Step 6 or drop), `stats --agent` (add `WHERE agent=?`), council `_COUNCIL_WORKFLOW_FLAG` (set it in Step 0.5 parse), spec `check audit` keyword. | S | P2 |

**Estimated always-loaded savings if E1–E7 land:** council 72 KB → ~40 KB, memory 65 KB → ~6 KB router, retro 87 KB → ~20 KB, spec 34 KB → ~4 KB router. Across the slice that is about 258 KB → ~70 KB, roughly −47k tokens per invocation. The moved content is only read when its mode runs.

