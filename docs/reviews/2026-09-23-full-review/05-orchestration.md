## Slice: orchestration (orchestrate/kickoff/epic/autopilot/init-orchestration)

I reviewed every file in the slice without editing anything. Tests ran with `TMPDIR` set to reviewer scratch space.

### Test results
| Suite | Result |
|---|---|
| orchestrate/task-store-test.sh | PASS 33/0 |
| **orchestrate/router-static-test.sh** | **FAIL 15/1: `T10 02-scope.md bad-form`** |
| epic/test.sh | PASS 745/0 |
| autopilot/test.sh | PASS 311/0 |
| init-orchestration/test-orch-allowlist.sh | PASS 24/0 |
| init-orchestration/test-disclose-force.sh | PASS 33/0 |
| init-orchestration/test-sweep-legacy-orphans.sh | PASS 47/0 |
| init-orchestration/escalation-gate-test.sh | PASS 40/0 |
| init-orchestration/test-normalize-hook-paths.sh | PASS 32/0 |
| init-orchestration/test-signing-sandbox.sh | PASS 88/0 |
| init-orchestration/check-hook-templates.sh | OK (8 templates) |

- **Why T10 fails:** `steps/02-scope.md:6` ("`ORCH_TIER` S/M/L … is **not** `budget.tier` (N14)") mentions `ORCH_TIER` in a form the whitelist at `router-static-test.sh:165-176` does not allow. The line came in with v1.17.0 (11da8af), so master has been red since then without anyone noticing.
- **Why nobody noticed:** `.github/workflows/smoke.yml` runs none of the tests in this slice (orchestrate, epic, autopilot, init-orchestration). About 1,350 assertions never run in CI.

### Per-file review
| File | Purpose | Verdict | Findings |
|---|---|---|---|
| orchestrate/SKILL.md (59) | Step router | Good | Lean router, loads one step at a time. |
| steps/00-resolve.md | Parse flags, resume detection | Minor issues | PDH stanza pasted twice in one step (:113, :156). The memory fence reads `MEMDB` before it re-derives `MROOT` (:124-128); harmless but confusing. `ITER=0` "++ once per stint" (:162), but **no step ever increments ITER**, and resume does not restore it from the cards → BC6 iteration cap never trips (SPEC-033 M9 defines a stint as each spawn). |
| steps/01-fetch.md | Ticket source | OK | — |
| steps/02-scope.md | Scope gate + tier auto-size | Test-red | :6 breaks T10 (above). |
| steps/03-worktree.md | Worktree + glossary 3b | Minor | Re-derive fences (:54, :86) call `ensure-ticket-worktree` with no error handling. Error Handling in cross-cutting says "No git repo: skip worktree", but Step 3 always calls ensure, which exits 1 → contradiction. |
| steps/04-kickoff.md | PM + TL spawn | Bloat | Model-resolve block copied 3× in this file (~12 lines + PDH each). |
| **steps/05-questions.md** | Open questions | **Gap P1** | The standard/full branch "Wait for user answers" (:17) has **no autopilot branch** (kickoff Step 3 maps this to BC1 halt). An autopilot `/orchestrate` run stalls here. |
| steps/06-design.md | Plan, 6b glossary, 6c security council | OK/minor | Duplicates the Tracking block and ticket-class list that kickoff also carries. |
| **steps/07-tasks.md** | DAG + task-store | **Bug P1** | Key drift: the pre-gate maps plan "Task N" → `<ISSUE-ID>-N` (:11), but `create` keys by the **TaskCreate integer** `<ISSUE-ID>-<task_id>` (:101-104). TaskCreate ids are session-global and need not equal N, so `depends_on` never matches the file keys and `ready-set` deadlocks or releases tasks wrongly. The cycle fence sets `DAG_FILE=…-$$.json` and assumes it is "already written" (:14-16), but `$$` differs per fence, so the file is missing → rc=2 "could not run". Halt branches only `echo` (no `exit`). |
| **steps/08-execute.md** | Spawn/monitor, CI-watch, stint emit | **Bug P1** | Nothing writes `task-store update-status … in_progress` at spawn (SPEC-009:72 requires it). `ready-set` keeps returning in-flight tasks → double-spawn risk; the "check in-progress task store status" rule (:304) cannot be met. The ready-set it consumes is global (see dag-lib). |
| **steps/09-review.md** | TL loop, council gate | **Bug P1** | The Defensive CI-watch cleanup fence reads `$TASK_ID`, which is never set in that fresh shell → `TICKET=""` → `sidecar get ""`. PDH resolved twice in one fence. Light tier contradiction: :5 says `--council-tier=full` "runs council", but 07/08 light forbid `requires_council` and the council addendum, so nothing runs it. The `skip`+`requires_council` conflict is only caught after implementation; it could be caught at Step 0/7. |
| **steps/10-qa.md** | QA + 10b | **Gap P1** | "Repeat until QA passes" (:370) has no cap and no autopilot halt. BC2 (`qa_bounces>=3`) is evaluated only at ship-choice, which is reached only after a PASS, so the loop is unbounded. The 10b "survives resume" check relies on the conversation, with no persisted marker. |
| steps/11-ship.md | Ship, resume-ship, Linear, cleanup | Minor | The interactive squash `cd <main-repo-path>; git merge --squash` has no check that main is on the baseline or clean. `assert… \|\| exit 64` maps every failure to 64. |
| steps/12-wrap.md | Wrap, friction | OK | Calls `$PDH/skills/retro-gate/hint.sh` directly instead of through `plugin-dir.sh file` (inconsistent). |
| steps/cross-cutting.md | Rules, notify, change discipline | OK | — |
| **orchestrate/task-store.sh** | Task JSON store | Minor/portability | `flock` is required (:91, :148) with no `command -v flock` guard; **stock macOS has no flock**. `create` prints both "upserted" and "created" on upsert. `status-of`/dag-lib does not use the compound-resolution that `update-status` does. |
| **orchestrate/dag-lib.sh** | Cycle check / ready-set | **Bug P1, untested** | No dedicated test (task-store-test has 0 references; epic/test.sh uses check-cycle only through its wrapper). `ready-set` reads **every** `.claude/tasks/*.json` from every issue ever (the store is never pruned by design), so stale pending tasks from other or abandoned issues get fanned out. **One corrupt JSON file fails the whole ready-set (reproduced: rc=5).** `blocked` deps wait forever with no signal. `status-of` has no task_id charset check (`../` path join). The DFS itself is correct (I checked self-loop, diamond, 3-cycle and unknown dep). |
| orchestrate/router-static-test.sh | Static router lint | Failing | See T10. |
| orchestrate/task-store-test.sh | task-store tests | OK | No dag-lib coverage. |
| **kickoff/SKILL.md (971)** | Kickoff monolith | Bloat + bugs | 18 copies of the PDH stanza (~14KB ≈ 3.5k tokens). Step 7 has the same DAG key drift (`TICKET-N` vs `<TICKET-ID>-<task_id>`) and the same `$$` DAG_FILE issue. `echo "\n## Task Map\n" >> $WT_PATH/...` writes literal `\n` and leaves `$WT_PATH` unquoted. The TaskCreate template has no `requires_council` line but `task-store create` needs one. The exit 64 comment (:89) omits `--tier`/`--max-loc`. `/kickoff` accepts and ignores `--tier`/`--council-tier`. |
| **epic/SKILL.md (1277)** | Epic decompose/execute/seal | Bloat + gap | 25 copies of the PDH stanza. Step 0.5 BC5 seal-intent sets the session var `RELEASE_BUMP=$AUTOPILOT_BUMP` "before A.6 init", but on **resume** there is no init, so the session var and durable `release_bump` diverge and `assert-release-allowed` still allows mid-epic land. Step 0.4 maps every resolve failure to exit 64. |
| **epic/epic-lib.sh (1987)** | Epic state CLI | **P0 data loss** | Live `seal`'s clean precheck is `git diff --quiet && diff --cached --quiet` (tracked only), but squash-fail and hook-fail recovery run `_seal_reset_main` → `git reset --hard` + **`git clean -fd`** (:979-983). **Reproduced:** an untracked `notes.txt` in the main repo was deleted on a squash conflict, and so was `.claude/epics/E1/state.json` when `.claude` is not gitignored. This contradicts SPEC-025:161/166 ("after a clean precheck"). Fix: use the `_seal_main_is_dirty` porcelain check before staging, and drop `clean -fd` (or limit it to paths seal created). Other: `seal` silently `git checkout`s the user's main repo to master/main. `eval "$EPIC_SEAL_RELEASE_HOOK"` is a test hook in production code. An `EPIC_ALLOW_SEAL_RELEASE=1` leaked into the env bypasses every C4 guard. `_find_parent_epic_for_ticket` takes the first alphabetical match, including sealed or old epics. `mark-done` marks the child completed in **every** epic containing it. `cmd_waves` spawns one jq per dep edge (O(N·D) processes). The ready-set jq expression is copied 3× (:1287, :1362, `_seed_render`). `init --title --mode x` sets title to "--mode". |
| epic/parse-flags.sh (156) | `--worktree`/`--release` | OK | See the drift comparison below. |
| epic/test.sh (2000) | 745 assertions | Good | `waves` has 4 mentions and `check-cycle` 5 (thin coverage). |
| **autopilot/parse-flags.sh (254)** | 6-key flag parser | Drift | Four different duplicate policies in one file: `--tier` strict (dies), `--council-tier`/`--max-loc` last-wins, `--autopilot` mixed (`--autopilot=patch --autopilot` keeps patch because `FLAG_HAS_EQ` sticks; the reverse order yields minor). Typos such as `--autopliot` are silently ignored → autopilot off. |
| autopilot/append-card.sh (343) | Card writer | Minor P2 | Comment :283-285 relies on PIPE_BUF atomicity, which applies to pipes, not regular files, and rationale has **no length cap**. jq's stdio may flush a large card in several `write()`s, so concurrent appends can interleave. Cap rationale (~2KB) or flock. |
| autopilot/read-cards.sh | Card reader | OK | — |
| **autopilot/resume-state.sh** | Resume lookup | **Bug P1** | The glob `*-<ID>-*.md` (:112) matches child plans: `CDT-141` matches `…-CDT-141-C3-slug.md`. With several matches the newest mtime wins, so resume can seed the wrong autopilot state from an epic child's plan. `grep -m1 '^- autopilot_on:'` is not scoped to `## Tracking`. `--accumulated` takes the max over **all** historical runs of the ticket. |
| autopilot/budget-check.sh | BC6 + derive | OK | Logic is correct. |
| autopilot/loc-exclude.sh | M15 exclusion | OK/perf | One process per path; add batch `git check-attr --stdin`. It checks attributes from cwd, not the worktree's `.gitattributes`. |
| autopilot/SKILL.md (535) | Policy contract | OK | — |
| autopilot/self-answer.md | Gate engine | OK | Correctly isolates kickoff/epic (argc=2). |
| autopilot/self-answer-scenarios.md | QA fixtures (tests only, not loaded) | OK | — |
| **autopilot/end-state.md** | Autopilot land | **Bug P1** | No clean-tree precheck before §4 `git merge --squash`. The §4 conflict path and §6.5 abort both run `git reset --hard` on the main repo, **discarding tracked WIP** (e.g. the `CONTEXT.md` dirt that orchestrate 3b explicitly allows to remain). `return 1` in a bash fence is invalid outside a function. BC3 checks `origin/HEAD` without a fetch (stale ref). |
| autopilot/ship-gate-council.md | M14 council at ship | OK | — |
| autopilot/test.sh | 311 assertions | Good | — |
| **init-orchestration/SKILL.md (2157)** | `/setup orchestration` | Bloat + P1 | About 1,200 lines are embedded hook templates (Steps 4–4i). Task-completed template :746-760: a bare TaskCreate id `3` collects **every** historical `*-3.json` across all issues, and any-true `requires_council` with no status filter means an old issue's council task can gate or block an unrelated task #3 forever. `python3 -c "…open('$f')"` (:700) injects the path into code. |
| init-orchestration/*.sh helpers | Settings/hook tooling | OK | `normalize-hook-paths.sh` exits 1 for "no-op", which a set -e caller would treat as a failure. Python-based while the rest of the slice uses jq (two JSON toolchains). |

### Cross-cutting findings
1. **Tests not in CI:** none of the slice's suites (about 1,350 assertions) run in `smoke.yml`, and one is already red on master.
2. **PDH stanza bloat:** 87 copies of an ~800-char one-liner across slice markdown (epic 25, kickoff 18, init 8, orchestrate steps 29). That is roughly 70KB, about 17k tokens. The model-resolve plus 8-line retry boilerplate is copied at every spawn site as well.
3. **Task-store is global and never pruned, but readers treat it as per-run:** this breaks `ready-set` (stale fan-out; one bad file kills it), the TaskCompleted hook (cross-issue `*-N.json` gate leakage) and `update-status` bare-id ambiguity.
4. **Task key drift:** plan index N vs TaskCreate integer, in both orchestrate Step 7 and kickoff Step 7.
5. **Main-repo destructive recovery without a porcelain precheck:** epic seal runs `clean -fd` (P0, reproduced) and end-state runs `reset --hard`.
6. **Autopilot state-machine holes:** ITER is never incremented, so the BC6 iteration cap is dead; Step 5 has no autopilot branch; the Step 10 QA loop is unbounded with BC2 unreachable mid-loop; epic resume does not persist seal-intent.
7. **Portability:** `flock` (task-store, epic-lib, sidecar, index-writer, write-model) has no guard or fallback; stock macOS lacks it. There are no `sed -i`, `date -d` or `stat` hazards in the slice. `/tmp` is always written as `${TMPDIR:-/tmp}` (fine).
8. **parse-flags drift:** the autopilot and epic parsers use different loops (`for` vs index-walk), different duplicate policies (autopilot has three internally; epic is strict), and different value forms (`=` only vs space-or-`=` for `--release`). Both silently ignore unknown `--flags`. The "own parser" split is by spec (SPEC-025 AC8), but there is no shared test matrix for the common edge cases.

### Enhancement proposals
| # | Title | Rationale | Concrete change | Effort | Pri |
|---|---|---|---|---|---|
| 1 | Seal: porcelain precheck, no `clean -fd` | Reproduced loss of untracked files and epic state | In `cmd_seal` live path, replace the diff checks with `_seal_main_is_dirty` → die 1; change `_seal_reset_main` to `reset --hard` only; add a test with an untracked file surviving a squash conflict | S | P0 |
| 2 | Fix T10 and wire slice tests into CI | Master is red; about 1,350 assertions have no gate | Reword `02-scope.md:6` (e.g. "pipeline tier (S/M/L) is not `budget.tier`"), or extend the T10 whitelist; add jobs for epic, autopilot, orchestrate and init-orchestration tests to `smoke.yml` | S | P0 |
| 3 | Unify task keys | The DAG deadlocks or releases tasks wrongly | Key the task store by plan index `<ISSUE-ID>-N` everywhere (07-tasks, kickoff Step 7); record a TaskCreate-id ↔ N map in the plan; pass `-N` to update-status | S | P1 |
| 4 | Scope ready-set per run | Stale cross-issue fan-out; one corrupt file kills fan-out | `dag-lib.sh ready-set [--prefix <ISSUE-ID>-]`, skip unparseable files with a stderr warning; add `dag-lib-test.sh` | S | P1 |
| 5 | Write in_progress at spawn | SPEC-009:72 drift; double-spawn | 08-execute: `task-store update-status <key> in_progress` right after each spawn | S | P1 |
| 6 | Hook: filter the candidate set | Cross-issue council-gate leakage | Task-completed template: ignore candidates with `status=="completed"`, or match by `CLAUDE_TICKET` prefix when available | M | P1 |
| 7 | Autopilot gaps | Stalls and unbounded loops | Add an autopilot BC1 branch to `05-questions.md`; cap the Step 10 QA loop at `qa_bounces>=3` → BC2 halt; add explicit `ITER=$((ITER+1))` at each spawn site and restore it on resume from `max(.budget.iteration)` | M | P1 |
| 8 | end-state clean precheck | `reset --hard` destroys tracked WIP | §3.6: `git -C main status --porcelain` must be empty or halt BC3/BC7; replace `return 1` with prose | S | P1 |
| 9 | resume-state exact match | Epic child plans hijack resume | Match `^[0-9-]+-<ID>-` and parse `ticket_id:` in Tracking equal to `<ID>`; scope the grep to the `## Tracking` block | S | P1 |
| 10 | Persist epic seal-intent on resume | Session var and state diverge | On resume with `--autopilot=<bump>` and a null state `release_bump`, fail 64 (C6 policy) rather than mutating the session var | S | P2 |
| 11 | Fix the Step 9 cleanup fence | `$TASK_ID` unset | Add `TASK_ID="<task_id>"` substitution; drop the duplicate PDH | S | P2 |
| 12 | Collapse the PDH stanza | About 17k tokens of bloat | Resolve once per step: `PDH=$(cat "$MROOT/.claude/.pdh" 2>/dev/null)` cached at Step 0, with the stanza as fallback; or a one-line `eval "$(bash plugin-dir.sh --pdh-export)"`. Needs a skill-lint C3 update | M | P2 |
| 13 | Split monolith SKILL.md files | kickoff 971, epic 1277, init 2157 lines loaded whole | epic → router + `steps/{0-flags,A-decompose,B-execute,B7-seal,C-F-modes}.md` (mirror orchestrate); kickoff → steps/; init-orchestration → move hook bodies to `templates/*.sh` (copy with Write, and `check-hook-templates` runs shellcheck on real files), SKILL.md ≈ 700 lines | L | P2 |
| 14 | flock portability | macOS breakage | Shared `lock_run()` helper: `flock` if present, else `mkdir`-lock with retry/timeout; guard with a clear error | M | P2 |
| 15 | Shared flag-edge test matrix | Parser drift | One table-driven test covering duplicate, bare, empty, `=`, space form and unknown-flag typo across both parsers; normalize `--autopilot` duplicates to last-wins explicitly, or die | S | P2 |
| 16 | Cap card rationale / flock append | PIPE_BUF claim wrong for regular files | `append-card.sh`: reject rationale > 2000 bytes (or truncate with a marker); fix the comment | S | P3 |
| 17 | Remove the epic-lib test hook eval | eval of an env var in production | Guard `EPIC_SEAL_RELEASE_HOOK` behind `EPIC_TEST_MODE=1`; refuse `EPIC_ALLOW_SEAL_RELEASE` unless the state is seal-staged | S | P3 |
| 18 | Deduplicate epic ready-set jq and speed up waves | Maintainability and O(N·D) jq spawns | One `jq` def file, or a `_ready_ids` function; compute waves in one jq Kahn pass | S | P3 |
| 19 | kickoff Task Map echo | Literal `\n`, unquoted var | `printf '\n## Task Map\n\n' >> "$WT_PATH/…"` | S | P3 |
| 20 | Detect skip+requires_council early | Conflict surfaces only after the work is built | At Step 7, if `COUNCIL_TIER_OVERRIDE=skip` and any task has `requires_council:true`, halt BC1 before spawning | S | P3 |

Key paths:
- skills/epic/epic-lib.sh (the seal code, :979-1120)
- skills/orchestrate/steps/02-scope.md:6
- skills/orchestrate/steps/07-tasks.md
- skills/orchestrate/dag-lib.sh
- skills/autopilot/resume-state.sh:112
- skills/autopilot/end-state.md §4/§6.5
- skills/init-orchestration/SKILL.md:746-800
- .github/workflows/smoke.yml

The seal repro script was a throwaway fixture in reviewer scratch space (`sealtest/`).
