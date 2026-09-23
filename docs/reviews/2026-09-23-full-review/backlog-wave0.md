Backlog items for milestone **Wave 0 — P0 fixes** of project P-CDT-30, generated from `docs/reviews/2026-09-23-full-review/backlog.json` (branch `claude/craft-loop-review-enhancement-4jq3wb`). These are written as a document because the workspace is at its free-plan issue limit; each item has everything needed to become an issue later.

51 items · Urgent 20 · High 31

## Checklist

- [ ] `P0-01` [memory] Close second-order SQL injection in reconcile-lib that empties the memory DB — Urgent, S
- [ ] `P0-02` [epic] Stop epic seal recovery from deleting untracked files (`git clean -fd`) — Urgent, S
- [ ] `P0-03` [wrap-ticket] Make prune-remote check the remote ref and delete with a lease — Urgent, S
- [ ] `P0-04` [lint-ok] Fix `\  # lint-ok` after line-continuation in 3 live bash fences — Urgent, S
- [ ] `P0-05` [memory] Move `# lint-ok` out of SQL strings in commands/memory.md — Urgent, S
- [ ] `P0-06` [memory] Fix `/memory distill` self-deadlock on distilling_lock at Step 4.5 — Urgent, S
- [ ] `P0-07` [memory] Remove Python code injection via LLM-extracted REF_PATH — Urgent, S
- [ ] `P0-08` [retro] Make scheduled retro lock and report actually work across fences — Urgent, S
- [ ] `P0-09` [setup] Fix broken `/setup team` bash: PLUGIN_DIR, MROOT ordering, cross-fence state — Urgent, S
- [ ] `P0-10` [agents] Fix project-init writing `/.claude/CLAUDE.md` and truncating lessons — Urgent, S
- [ ] `P0-11` [epic] Correct commands/epic.md `--autopilot` row: bump token is seal-intent — Urgent, S
- [ ] `P0-12` [council] Restore tier-grade signal 4 under the CDT-132 exec exception — Urgent, S
- [ ] `P0-13` [council] Fix Workflow-path Borda label mapping and add per-reviewer shuffle — Urgent, S
- [ ] `P0-14` [council] Fail closed when the degraded diff-mode judge falls back — Urgent, S
- [ ] `P0-15` [council] Render struck_lines objects instead of Python dict text — Urgent, S
- [ ] `P0-16` [review-and-commit] Map every council category to a report bucket; unify vocabulary — Urgent, S
- [ ] `P0-17` [debug] Make the SPEC-029 reopen gate work on installs and count days correctly — Urgent, M
- [ ] `P0-18` [memory] Normalize validation composite score so auto-archive can fire — Urgent, S
- [ ] `P0-19` [transcript-mirror] Make the Stop-hook mirror incremental (byte-offset cursor) — Urgent, M
- [ ] `P0-20` [install] Derive opencode tier map from agent `model:` frontmatter (SPEC-003) — Urgent, S
- [ ] `W1-01` [tests] Make the five red-on-master suites green — High, S
- [ ] `W1-02` [worktree] Stop worktree-lib release from force-deleting unmerged/unpushed branches — High, S
- [ ] `W1-03` [release] check-bump-class `--cached` must read plugin.json from the index — High, S
- [ ] `W1-04` [wrap-ticket] Fix `${CHILD_WT:-{}}` defaults and the legacy prefix-match `branch -D` — High, S
- [ ] `W1-05` [release] Push only the release tag atomically; refuse detached HEAD — High, S
- [ ] `W1-06` [autopilot] Add clean-tree precheck before end-state squash and `reset --hard` — High, S
- [ ] `W1-07` [backlog] close.sh: fix duplicate `## Completed` header and awk escape mangling — High, S
- [ ] `W1-08` [orchestrate] Unify task-store keys on plan index; fix per-fence DAG_FILE — High, S
- [ ] `W1-09` [orchestrate] Scope dag-lib ready-set per issue, skip corrupt files, add tests — High, S
- [ ] `W1-10` [orchestrate] Write task status `in_progress` at spawn (SPEC-009:72) — High, S
- [ ] `W1-11` [autopilot] resume-state: match the exact ticket id, scope grep to Tracking — High, S
- [ ] `W1-12` [transcript] One Claude project-dir encoder used everywhere — High, S
- [ ] `W1-13` [transcript] Harden transcript-parse assemble: uuid type, utf-8, single locate — High, S
- [ ] `W1-14` [scripts] Guard every `shift 2` with a value check (infinite loops, silent exits) — High, S
- [ ] `W1-15` [retro] Make scheduled-lock.sh atomic with owner-checked release — High, S
- [ ] `W1-16` [security] Stop resolving plugin scripts from cwd or a consumer repo — High, S
- [ ] `W1-17` [memory] Distill lock ownership, real exits, safe deep rebuild — High, S
- [ ] `W1-18` [memory] Reconcile: resolve PLUGIN_ROOT via plugin-dir.sh; put LIMIT in the query — High, S
- [ ] `W1-19` [memory] Use `-cmd ".timeout 5000"` on every memory DB access — High, S
- [ ] `W1-20` [scripts] Replace the `grep -c … || echo 0` idiom (prints `0\n0`) — High, S
- [ ] `W1-21` [retro] Small retro.md correctness fixes (freshness shell, counts, applied stats) — High, S
- [ ] `W1-22` [council] Blind path: worktree-correct file scope and unique report names — High, S
- [ ] `W1-23` [fix-ticket] Refuters must inspect untracked files created by the implementer — High, S
- [ ] `W1-24` [review-and-commit] Review exactly what gets committed (untracked + staging) — High, S
- [ ] `W1-25` [bug-hunt] Argument strictness, report-name collisions, materialize confinement — High, S
- [ ] `W1-26` [debug] Fix Step 0c/1b relative-path guard in debug and refactor — High, S
- [ ] `W1-27` [handoff] Collapse parse into Step 3; mktemp error file; emit SPINE; real exits — High, S
- [ ] `W1-28` [tdd-gate] Fix hook script shebang, matcher, fence type and arg handling — High, S
- [ ] `W1-29` [recall] Harden /recall: YAML hint, empty topic, shell/LIKE injection, caps — High, S
- [ ] `W1-30` [install] Reject unknown flags; make install/uninstall failure-safe — High, S
- [ ] `W1-31` [security] Narrow Bash allowlists seeded by `/setup team` and `/setup project` — High, S

## Items

### P0-01 · [memory] Close second-order SQL injection in reconcile-lib that empties the memory DB
**Priority** Urgent · **Effort** S · **Labels** Bug, Security · **Ticket group** T1 memory-safety

**Problem**
`skills/validate-memory/reconcile-lib.sh:150-172,331-343` exports memories as TSV, so continuation lines of a multi-line memory become fake rows. Their first field becomes `mid` and is spliced unquoted into `WHERE memory_id = ${mid}`; sqlite3 runs without `.bail`, so statements after an error still execute. Reproduced: content `line one\n0); DELETE FROM memories; --` took `memories` from 3 rows to 0 during `reconcile-lib.sh candidates`. Reachable via any agent write or a seed-pack import (the sanitizer does not block it). The same TSV export also truncates multi-line claims to their first line before they reach the judge.

**Fix**
- Export candidates with Python `sqlite3` using parameterized KNN queries (or JSONL instead of TSV) so content never crosses a line-oriented boundary.
- Validate every `mid` against `^[0-9]+$` before use; reject otherwise.
- Add `.bail on` to every heredoc SQL block in the file.
- Pass full multi-line content to the judge.

**Acceptance**
- Regression test in `validate-memory/test-reconcile.sh` with multi-line and injection content leaves row count unchanged.
- No `${mid}`-style unquoted numeric interpolation remains in reconcile-lib.sh.
- Judge input contains the full multi-line claim.

**Source**
- [README.md](README.md) #P0-1
- [07-memory.md](07-memory.md) #1
- [07-memory.md](07-memory.md) #P0-bug-1
- [07-memory.md](07-memory.md) #F:validate-memory/reconcile-lib.sh

Sources: `README.md#P0-1`, `07-memory.md#1`, `07-memory.md#P0-bug-1`, `07-memory.md#F:validate-memory/reconcile-lib.sh`

### P0-02 · [epic] Stop epic seal recovery from deleting untracked files (`git clean -fd`)
**Priority** Urgent · **Effort** S · **Labels** Bug · **Ticket group** T2 git-safety

**Problem**
`skills/epic/epic-lib.sh` live `seal` prechecks cleanliness with `git diff --quiet && git diff --cached --quiet` (tracked files only), but squash-fail and hook-fail recovery call `_seal_reset_main`, which runs `git reset --hard` + `git clean -fd` (`:979-983`). Reproduced: an untracked `notes.txt` in the main repo and `.claude/epics/E1/state.json` (when `.claude` is not gitignored) were deleted on a squash conflict. Contradicts SPEC-025:161/166 ("after a clean precheck"). `seal` also silently `git checkout`s the user's main repo to master/main.

**Fix**
- In `cmd_seal` live path replace the diff checks with the existing porcelain `_seal_main_is_dirty` check and die 1 when dirty (untracked included).
- Change `_seal_reset_main` to `reset --hard` only; drop `clean -fd` (or restrict it to paths seal itself created).
- Print a message before switching the main checkout's branch.

**Acceptance**
- New epic test: untracked file in main repo survives a forced squash conflict.
- Seal refuses with exit 1 when main has untracked files.
- No `git clean -fd` remains in epic-lib.sh.

**Source**
- [README.md](README.md) #P0-2
- [05-orchestration.md](05-orchestration.md) #1
- [05-orchestration.md](05-orchestration.md) #F:epic/epic-lib.sh

Sources: `README.md#P0-2`, `05-orchestration.md#1`, `05-orchestration.md#F:epic/epic-lib.sh`

### P0-03 · [wrap-ticket] Make prune-remote check the remote ref and delete with a lease
**Priority** Urgent · **Effort** S · **Labels** Bug · **Ticket group** T2 git-safety

**Problem**
`skills/wrap-ticket/prune-remote.sh:128-167`: `resolve_branch_ref` prefers the local `refs/heads/feat/X`, so the merged-safety check runs on the local branch while the remote branch is deleted. Reproduced even after `git fetch`: a teammate's extra commit on `origin/feat/CDT-9` was removed when the local branch was merged. It never fetches, and the delete is not lease-guarded. `is_already_gone` (`:181`) matches the bare phrase `does not exist`, silently swallowing "repository does not exist" and auth failures; only the first failure is printed.

**Fix**
- `git fetch origin "refs/heads/$n:refs/remotes/origin/$n"`, then run the ancestor/cherry check on `refs/remotes/origin/$n`.
- Delete with `git push --force-with-lease=refs/heads/$n:<checked-sha> origin :refs/heads/$n`.
- Tighten `is_already_gone` to "remote ref does not exist"; print every failure.

**Acceptance**
- New prune-remote-test case: remote ahead of a merged local branch → branch kept, reported.
- Auth failure is reported as an error, not a skip.
- Existing 61 prune-remote tests still pass.

**Source**
- [README.md](README.md) #P0-3
- [09-release-tooling.md](09-release-tooling.md) #1
- [09-release-tooling.md](09-release-tooling.md) #F:wrap-ticket/prune-remote.sh
- [09-release-tooling.md](09-release-tooling.md) #F:wrap-ticket/prune-remote-test.sh

Sources: `README.md#P0-3`, `09-release-tooling.md#1`, `09-release-tooling.md#F:wrap-ticket/prune-remote.sh`, `09-release-tooling.md#F:wrap-ticket/prune-remote-test.sh`

### P0-04 · [lint-ok] Fix `\  # lint-ok` after line-continuation in 3 live bash fences
**Priority** Urgent · **Effort** S · **Labels** Bug · **Ticket group** T3 council-integrity

**Problem**
A backslash followed by spaces and a comment is not a line continuation. Sites: `skills/review-and-commit/SKILL.md:207` (finalize runs with only `--plan-file`; the next line runs `--evidence-file` as a command — reproduced), `commands/council.md:1042` (fence labelled plain `bash`, also has `[--task-id …]` brackets), `skills/memory-recall/SKILL.md:106` (remote mode with dims>0 always takes the lembed branch — reproduced). In review-and-commit, `$PLAN_FILE` also comes from a Step 3 fence (empty in this fresh shell) and `${degraded:+…}` is never set.

**Fix**
- Move each `# lint-ok` pragma to its own line above the command.
- review-and-commit: re-derive `PLAN_FILE` in-block (or have the model substitute the literal path) and replace `${degraded:+…}` with an explicit literal.
- council.md:1041-1047: mark the fence `bash template` or make it valid bash.
- Lint rule preventing recurrence is tracked in the skill-lint C6–C9 item.

**Acceptance**
- Extracting and running each fixed block passes all intended flags (probe shows evidence/judge args reach finalize).
- memory-recall remote mode takes the remote branch in a scripted probe.
- `grep -nE '\\[ \t]+#' ` over commands/ skills/ agents/ returns nothing.

**Source**
- [README.md](README.md) #P0-4
- [07-memory.md](07-memory.md) #2
- [07-memory.md](07-memory.md) #P0-bug-2
- [08-workflow-skills.md](08-workflow-skills.md) #1
- [03-large-commands.md](03-large-commands.md) #C2
- [08-workflow-skills.md](08-workflow-skills.md) #F:review-and-commit/SKILL.md

Sources: `README.md#P0-4`, `07-memory.md#2`, `07-memory.md#P0-bug-2`, `08-workflow-skills.md#1`, `03-large-commands.md#C2`, `08-workflow-skills.md#F:review-and-commit/SKILL.md`

### P0-05 · [memory] Move `# lint-ok` out of SQL strings in commands/memory.md
**Priority** Urgent · **Effort** S · **Labels** Bug · **Ticket group** T1 memory-safety

**Problem**
`commands/memory.md:413,1426,1516` append `# lint-ok: C1` inside double-quoted SQL (e.g. `HAVING COUNT(*) >= $THRESHOLD  # lint-ok: C1`). The pragma becomes part of the SQL and sqlite fails with `unrecognized token: "#"` (checked with python sqlite3). The all-agents distill target query, deep-validate digest query and rebuild source query all fail on every run.

**Fix**
- Close the quoted SQL string before the pragma or put the pragma on its own line outside the string at each of the three sites.
- Grep the rest of commands/ and skills/ for `lint-ok` inside an open quote and fix any other hit.

**Acceptance**
- Each of the three queries, extracted with placeholder values, executes under sqlite3 without error.
- Skill-lint rule for pragma-inside-quote (C7, lint item) flags a fixture reproducing this.
- `/memory distill` all-agents target selection returns candidates on a seeded DB.

**Source**
- [README.md](README.md) #P0-5
- [03-large-commands.md](03-large-commands.md) #M1
- [03-large-commands.md](03-large-commands.md) #E0

Sources: `README.md#P0-5`, `03-large-commands.md#M1`, `03-large-commands.md#E0`

### P0-06 · [memory] Fix `/memory distill` self-deadlock on distilling_lock at Step 4.5
**Priority** Urgent · **Effort** S · **Labels** Bug, Concurrency · **Ticket group** T1 memory-safety

**Problem**
Distill takes `distilling_lock` at Step 4 (`commands/memory.md:314-357`), then Step 4.5 runs validate "Steps 1–8". Validate Step 1 (`:831-845`) exits when that lock is held, as SPEC-011:101 requires. So every default `/memory distill` fails pre-distill validation and aborts. Neither SPEC-011 nor SPEC-007 defines an exemption.

**Fix**
- Pass an owner token from distill into the pre-distill validate call; validate Step 1 proceeds when the held lock value equals that token.
- Document the pre-distill exemption in SPEC-011 (and cross-reference from SPEC-007).
- Keep refusing for any other holder.

**Acceptance**
- Scripted distill on a seeded DB completes Step 4.5 and reaches Step 5.
- Validate invoked standalone while another token holds the lock still exits with the lock error.
- SPEC-011 lock section names the owner-token exemption.

**Source**
- [README.md](README.md) #P0-6
- [03-large-commands.md](03-large-commands.md) #M2
- [03-large-commands.md](03-large-commands.md) #E0

Sources: `README.md#P0-6`, `03-large-commands.md#M2`, `03-large-commands.md#E0`

### P0-07 · [memory] Remove Python code injection via LLM-extracted REF_PATH
**Priority** Urgent · **Effort** S · **Labels** Bug, Security · **Ticket group** T1 memory-safety

**Problem**
The containment-guard fallback in `commands/memory.md:993-994,1016` runs `python3 -c "…os.path.join('$WTROOT','$REF_PATH')"`. `REF_PATH` is extracted by the LLM from memory content (untrusted, as the file notes at :982). A `'` in the path injects Python. The fallback runs whenever `realpath -m` is missing — i.e. every macOS/BSD host. The `relpath()` helper has the same flaw with `'$1'`.

**Fix**
- Pass values via argv: `python3 -c 'import os,sys;print(os.path.normpath(os.path.join(sys.argv[1],sys.argv[2])))' "$WTROOT" "$REF_PATH"`.
- Same for `relpath()`.
- General convention is tracked in the input-safety item.

**Acceptance**
- No `'$VAR'` interpolation inside `python3 -c` remains in commands/memory.md.
- Probe with `REF_PATH="x'); import os; os.system('touch PWNED'); ('"` creates no file and yields a normalized path.
- Works with `realpath -m` absent (PATH shim).

**Source**
- [README.md](README.md) #P0-7
- [03-large-commands.md](03-large-commands.md) #M3
- [03-large-commands.md](03-large-commands.md) #E0

Sources: `README.md#P0-7`, `03-large-commands.md#M3`, `03-large-commands.md#E0`

### P0-08 · [retro] Make scheduled retro lock and report actually work across fences
**Priority** Urgent · **Effort** S · **Labels** Bug, Concurrency · **Ticket group** T5 retro-scheduled

**Problem**
`commands/retro.md:150-179`: `trap '… release' EXIT` and `write_scheduled_report_if_needed` are defined in the Step 1b fence. Each fence is a fresh shell (the file says so at :234/:617), so the trap fires as soon as Step 1b ends — `scheduled.lock` is released immediately and concurrent cron runs are not excluded (`:1900` falsely claims otherwise). The report writer is called at `:602,745,1521,1962` where it is undefined (`command not found`), and `SCHED_WRITER`, `MODE`, `AUTO` are missing there, so the SPEC-012 S1/S3 scheduled report is never written.

**Fix**
- Add `skills/retro-gate/scheduled-run.sh` with `acquire`, `report <reason>` and `release` subcommands that persist state in a run file (mktemp) keyed by token.
- Replace the in-fence trap/function with explicit `scheduled-run.sh` calls at every exit site, releasing by token.
- Remove the false claim at :1900.

**Acceptance**
- Two concurrent `--all --auto` runs: the second exits with lock-held.
- Each early-exit path writes the SPEC-012 report (test in retro-gate).
- No function/trap defined in one fence is referenced from another in retro.md.

**Source**
- [README.md](README.md) #P0-8
- [03-large-commands.md](03-large-commands.md) #R1
- [03-large-commands.md](03-large-commands.md) #R2
- [03-large-commands.md](03-large-commands.md) #E0

Sources: `README.md#P0-8`, `03-large-commands.md#R1`, `03-large-commands.md#R2`, `03-large-commands.md#E0`

### P0-09 · [setup] Fix broken `/setup team` bash: PLUGIN_DIR, MROOT ordering, cross-fence state
**Priority** Urgent · **Effort** S · **Labels** Bug · **Ticket group** T4 setup-agents

**Problem**
`commands/setup.md` Steps 2/2.5/3/4 set `PLUGIN_DIR="$PDH"` (`:246,270,297,327`), but `schema.sql`, `migrate.sh`, `download-extensions.sh`, `migrate-md.sh` live in `skills/memory-store/`, so all four steps fail. Steps 2.5 and 4 set `MEMDB="$MROOT/…"` before `MROOT` is computed (`:272→273`, `:329→330`) → `/.claude/memory/memory.db`, migration silently skipped. Step 5b sets `SETTINGS`/`HOSTS_TO_ADD` in one fence (`:415-430`) and uses them in the next (`:463-483`) → `echo '{}' > ""`; C1 waivers at :466/:470 hide it. `EXT_GITIGNORE_DONE` (:307) and `SEED_IMPORT_SUMMARY` (:407) are also lost across fences; `echo '{}' > "$SETTINGS"` has no `mkdir -p .claude`; the team approval text (:447-453) asks to approve a bash-compress.sh the team path never writes.

**Fix**
- Resolve each script via `bash "$PDH/skills/plugin-dir.sh" file skills/memory-store/<x>`.
- Compute MROOT before MEMDB in every fence; merge the Step 5b fences and drop the C1 waivers.
- Persist cross-step values to a state file or re-derive them; add `mkdir -p .claude`.
- Remove the bash-compress approval line from the team path.

**Acceptance**
- Scripted `/setup team` run in a temp project executes Steps 2–5b with no missing-file errors.
- Allowlist step writes to `.claude/settings.json`.
- No `lint-ok: C1` waivers remain in Step 5b.

**Source**
- [README.md](README.md) #P0-9
- [02-commands-docs.md](02-commands-docs.md) #1
- [02-commands-docs.md](02-commands-docs.md) #P0-1
- [02-commands-docs.md](02-commands-docs.md) #F:commands/setup.md

Sources: `README.md#P0-9`, `02-commands-docs.md#1`, `02-commands-docs.md#P0-1`, `02-commands-docs.md#F:commands/setup.md`

### P0-10 · [agents] Fix project-init writing `/.claude/CLAUDE.md` and truncating lessons
**Priority** Urgent · **Effort** S · **Labels** Bug, Security · **Ticket group** T4 setup-agents

**Problem**
`agents/project-init.md` Step 4 fence (`:455-470`) uses `$MROOT` without deriving it in that fresh shell → `mkdir -p "/.claude"` and a write to `/.claude/CLAUDE.md` (silently succeeds in root containers). `:148-150` uses an indented heredoc terminator (`  EOF`, invalid with `<<`) and `cat >`, which truncates lessons and violates the SPEC-004 append-only contract on re-runs. `:481` uses unquoted `<< EOF` for content filled from scanned repo text, so `$(…)`/backticks execute. Also: `:448` "placeholder lessons.md" contradicts `:520` "no placeholders"; the `:143` sqlite INSERT has no `.timeout` and no embedding.

**Fix**
- Prepend the `_gc`/MROOT derivation to the Step 4 fence.
- Use `cat >>`, column-0 `EOF`, and route writes through the protocol write block.
- Quote the heredoc at :481 (`<< 'EOF'`).
- Reconcile the placeholder wording; add `-cmd ".timeout 5000"` and a note/backfill call for embedding.

**Acceptance**
- Running the fenced blocks in a temp project writes only under `$MROOT/.claude/`.
- Re-running `/setup team` in .md mode keeps existing lessons.
- Smoke/lint coverage for agents/ (tracked separately) flags an un-derived MROOT fixture.

**Source**
- [README.md](README.md) #P0-10
- [01-agents-infra.md](01-agents-infra.md) #1
- [01-agents-infra.md](01-agents-infra.md) #2
- [01-agents-infra.md](01-agents-infra.md) #F:agents/project-init.md

Sources: `README.md#P0-10`, `01-agents-infra.md#1`, `01-agents-infra.md#2`, `01-agents-infra.md#F:agents/project-init.md`

### P0-11 · [epic] Correct commands/epic.md `--autopilot` row: bump token is seal-intent
**Priority** Urgent · **Effort** S · **Labels** Bug · **Ticket group** T4 setup-agents

**Problem**
`commands/epic.md:36` says the `--autopilot` token is "Unused by /epic… Independent of --worktree/--release". This contradicts `skills/epic/SKILL.md:209-212` and AGENTS.md ("seal-intent… Token is not unused"). An agent that trusts the command drops `release_bump` — the forbidden mid-epic landing. `docs/commands/epic.md` also omits `--autopilot[=token]` and `--no-context-discipline` and never states seal intent. In the dispatch block (`:53-62`) `$EPIC_ID`/`$CHILD_ID` are never set, and `--redecompose`/`--no-context-discipline` routing is prose-only.

**Fix**
- Rewrite :36: "bump token ∈ {patch,minor,major} = seal-intent: persist `release_bump` and enable worktree (BC5)".
- Add both flags and the seal-intent rule to docs/commands/epic.md.
- Set or explicitly template `$EPIC_ID`/`$CHILD_ID` in the dispatch block and document the prose-only routes.

**Acceptance**
- commands/epic.md, skills/epic/SKILL.md and AGENTS.md agree on seal intent (grep check).
- docs/commands/epic.md flags table lists `--autopilot` and `--no-context-discipline`.
- docs-drift passes.

**Source**
- [README.md](README.md) #P0-11
- [02-commands-docs.md](02-commands-docs.md) #2
- [02-commands-docs.md](02-commands-docs.md) #P0-2
- [02-commands-docs.md](02-commands-docs.md) #F:commands/epic.md
- [02-commands-docs.md](02-commands-docs.md) #F:docs/commands/epic.md

Sources: `README.md#P0-11`, `02-commands-docs.md#2`, `02-commands-docs.md#P0-2`, `02-commands-docs.md#F:commands/epic.md`, `02-commands-docs.md#F:docs/commands/epic.md`

### P0-12 · [council] Restore tier-grade signal 4 under the CDT-132 exec exception
**Priority** Urgent · **Effort** S · **Labels** Bug · **Ticket group** T3 council-integrity

**Problem**
`skills/council/tier-grade.sh:314-334` clears `exec_why` for a mode-unchanged 100755 file with LOC < 100 (an unspecced CDT-132 exception; SPEC-013:225-228 has none). Signal 4 (`:340-342`) depends on `exec_why`, so deleting 31–99 lines from an existing executable grades **light** and skips council. Confirmed: `0 50 tools/x` with `:100755 100755 … M` yields `clear-low`, no signals. CDT-132 has no test.

**Fix**
- Compute signal 4 from `mode==100755 || shebang` before clearing `exec_why`, or skip the CDT-132 relaxation when deletions > 30.
- Record the CDT-132 exception in SPEC-013 §signals.

**Acceptance**
- test-tier-grade.sh gains `M`-status executable fixtures: 50-line deletion grades non-light; small add stays light.
- SPEC-013 documents the exception and its bound.

**Source**
- [README.md](README.md) #P0-12
- [04-council.md](04-council.md) #1
- [04-council.md](04-council.md) #F:council/tier-grade.sh(1)
- [04-council.md](04-council.md) #F:test-tier-grade.sh

Sources: `README.md#P0-12`, `04-council.md#1`, `04-council.md#F:council/tier-grade.sh(1)`, `04-council.md#F:test-tier-grade.sh`

### P0-13 · [council] Fix Workflow-path Borda label mapping and add per-reviewer shuffle
**Priority** Urgent · **Effort** S · **Labels** Bug · **Ticket group** T3 council-integrity

**Problem**
In `skills/council/workflow.js` `runReview` (`:474-481`) each reviewer labels only *other* bundles (self excluded), but `bordaRank` (`:196-198`) maps labels to the *global* index, misattributing votes. Confirmed: the strong bundle scored 3 (correct 2) and its peer 0 (correct 1). No per-reviewer shuffle (SKILL.md requires one); labels overflow past 26; multi-claim runs rank all bundles against `claims[0]` (`:483`).

**Fix**
- Build a per-reviewer `label → globalIndex` map in `runReview` with a shuffle; return it with the ranking and use it in `bordaRank`.
- Rank per claim using that claim's text.
- Use two-letter labels (or numeric) beyond 26.

**Acceptance**
- Unit test (node) with 3 bundles reproduces the correct scores 2/1/0.
- Shuffle observed across reviewers (seeded test).
- Multi-claim fixture ranks each claim against its own text.

**Source**
- [README.md](README.md) #P0-13
- [04-council.md](04-council.md) #2
- [04-council.md](04-council.md) #F:council/workflow.js(1)

Sources: `README.md#P0-13`, `04-council.md#2`, `04-council.md#F:council/workflow.js(1)`

### P0-14 · [council] Fail closed when the degraded diff-mode judge falls back
**Priority** Urgent · **Effort** S · **Labels** Bug, Security · **Ticket group** T3 council-integrity

**Problem**
`skills/council/workflow.js:601-614`: when the diff-mode judge spawn fails, the fallback marks every finding `warning`, so `commit_gate` stays PASSED. A judge failure therefore produces a green commit gate.

**Fix**
- In the fallback set severity `critical` (or set a plan flag so finalize emits BLOCKED when `verification_mode=self-verified` and the shape is `finding[]`).
- Surface the degradation reason in the report header.

**Acceptance**
- Test forcing a judge failure yields `commit_gate: BLOCKED`.
- Report shows the degraded-judge reason.
- Normal judge path unchanged (existing tests pass).

**Source**
- [README.md](README.md) #P0-14
- [04-council.md](04-council.md) #4
- [04-council.md](04-council.md) #F:council/workflow.js(4)

Sources: `README.md#P0-14`, `04-council.md#4`, `04-council.md#F:council/workflow.js(4)`

### P0-15 · [council] Render struck_lines objects instead of Python dict text
**Priority** Urgent · **Effort** S · **Labels** Bug · **Ticket group** T3 council-integrity

**Problem**
`skills/council/engine.sh:1080` renders struck lines with `f"- {ln}"`. judge.md:141 and phase4-brief.md mandate objects `{claim,line,reason}`, so every real report shows `- {'claim': 'x', ...}` (confirmed). Fixtures only use string struck lines, hiding the bug.

**Fix**
- Format dicts as `` `{claim or claim_id}` — {line} ({reason}) ``; keep string handling for legacy.
- Convert fixtures to the object shape (plus one legacy string case).

**Acceptance**
- Finalize on an object-shaped fixture renders readable lines with no `{'` text.
- Legacy string fixture still renders.
- test-finalize-missing-tid.sh and new fixture test pass.

**Source**
- [README.md](README.md) #P0-15
- [04-council.md](04-council.md) #3
- [04-council.md](04-council.md) #F:council/engine.sh(3)
- [04-council.md](04-council.md) #F:fixtures/

Sources: `README.md#P0-15`, `04-council.md#3`, `04-council.md#F:council/engine.sh(3)`, `04-council.md#F:fixtures/`

### P0-16 · [review-and-commit] Map every council category to a report bucket; unify vocabulary
**Priority** Urgent · **Effort** S · **Labels** Bug · **Ticket group** T3 council-integrity

**Problem**
`skills/review-and-commit/SKILL.md:265-270` groups findings by category, but the logic flavor emits `category:"logic"` (no bucket — warnings vanish) and the quality flavor emits `"design"` while the Maintainability bucket matches `quality`, so it is always empty. The vocabulary also drifts across layers: external-reviewer and the workflow fallback use `quality`; `workflow-schemas.js` leaves `category` a free string.

**Fix**
- Pick one vocabulary (`design` or `quality`) and apply it in the flavors, external-reviewer mapper, workflow fallback and a schema enum.
- Map `logic` → Correctness/Critical by severity and `design` → Design Problems in Step 6; add a catch-all "Other" bucket.

**Acceptance**
- New category-parity test: every `category` value in flavor files and mappers has a Step 6 bucket.
- Schema enum rejects unknown categories.
- A logic warning appears in a rendered review-and-commit report.

**Source**
- [README.md](README.md) #P0-16
- [08-workflow-skills.md](08-workflow-skills.md) #3
- [04-council.md](04-council.md) #16
- [04-council.md](04-council.md) #F:council/workflow-schemas.js
- [04-council.md](04-council.md) #F:flavors/logic,security,compliance,quality,simplification(5)

Sources: `README.md#P0-16`, `08-workflow-skills.md#3`, `04-council.md#16`, `04-council.md#F:council/workflow-schemas.js`, `04-council.md#F:flavors/logic,security,compliance,quality,simplification(5)`

### P0-17 · [debug] Make the SPEC-029 reopen gate work on installs and count days correctly
**Priority** Urgent · **Effort** M · **Labels** Bug · **Ticket group** T7 debug-gates

**Problem**
`skills/debug/SKILL.md:315-338` looks for `theme-status.sh` only under `$MROOT/skills/…` (the user repo) and `${CLAUDE_PLUGIN_ROOT}`; on real installs it falls back to REOPEN=0/forced=no, so SPEC-029's forced redesign never fires, and the fallback key algorithm differs from `derive`. In `theme-status.sh`: history already holds the current prompt so today counts as a prior day (`:87-107`); `root_n not in pth and pth not in root_n` (`:97`) makes an empty `project` match everything and `/a/app` match `/a/app2`; `derive` keys on word order (`:21`); `append` doesn't sanitize `/`/`..` (`:140-147`, escapes `themes/`); bare `architecture`/`redesign` force redesign (`:166-167`); undated lines count as a day; duplicate/dead stopwords. Probe: empty-project entry + current run → forced=yes on day 2. No test exists.

**Fix**
- Resolve via PDH + `plugin-dir.sh file skills/debug/theme-status.sh`; add the site to SPEC-002's resolver table; fallback calls one inline `force-check` copy.
- Exclude history entries from the current invocation; require exact project match; skip empty project; sort tokens in `derive`; sanitize keys in `append`; word-boundary keyword match.

**Acceptance**
- New `skills/debug/theme-status-test.sh` covers SPEC-029 T1–T5 and the probes above.
- Installed-layout test (plugin-dir cache tier) resolves the helper.
- Path-escape key is rejected.

**Source**
- [README.md](README.md) #P0-17
- [08-workflow-skills.md](08-workflow-skills.md) #4
- [08-workflow-skills.md](08-workflow-skills.md) #5
- [08-workflow-skills.md](08-workflow-skills.md) #F:debug/theme-status.sh
- [08-workflow-skills.md](08-workflow-skills.md) #F:debug/SKILL.md(helper)
- [10-specs.md](10-specs.md) #SPEC-029

Sources: `README.md#P0-17`, `08-workflow-skills.md#4`, `08-workflow-skills.md#5`, `08-workflow-skills.md#F:debug/theme-status.sh`, `08-workflow-skills.md#F:debug/SKILL.md(helper)`, `10-specs.md#SPEC-029`

### P0-18 · [memory] Normalize validation composite score so auto-archive can fire
**Priority** Urgent · **Effort** S · **Labels** Bug · **Ticket group** T1 memory-safety

**Problem**
Per-claim max is 40 (CONTRADICTED) + 5 age, so the composite max is 45 (`skills/validate-memory/SKILL.md` Composite Scoring; `commands/memory.md:1152-1198`). Auto-archive needs >80 (SPEC-011:38) and reviewer archive ≥60 — both unreachable; SPEC-011:167 expects a deleted-file memory to score >80. The scoring "bash template" also mixes Python dict syntax with bash integer arithmetic on a float `raw_score`, and BSD `date -j -f '%Y-%m-%dT%H:%M:%SZ'` fails on SQLite's default `YYYY-MM-DD HH:MM:SS` timestamps.

**Fix**
- Normalize `raw_score` to 0–100 (e.g. `SUM(pts)/(40*n)*95 + age`) or retune thresholds to the 0–45 range; update SPEC-011 and memory.md together.
- Compute the score in one Python snippet (argv inputs) instead of mixed bash/Python; parse both timestamp formats.

**Acceptance**
- Numeric test: a deleted-file memory scores >80; an all-SUPPORTED memory scores <40.
- SPEC-011 thresholds and formula match the implementation.
- Score computation works with SQLite-default timestamps on BSD and GNU date.

**Source**
- [README.md](README.md) #P0-18
- [07-memory.md](07-memory.md) #3
- [07-memory.md](07-memory.md) #P0-bug-3
- [03-large-commands.md](03-large-commands.md) #M15
- [07-memory.md](07-memory.md) #F:validate-memory/SKILL.md

Sources: `README.md#P0-18`, `07-memory.md#3`, `07-memory.md#P0-bug-3`, `03-large-commands.md#M15`, `07-memory.md#F:validate-memory/SKILL.md`

### P0-19 · [transcript-mirror] Make the Stop-hook mirror incremental (byte-offset cursor)
**Priority** Urgent · **Effort** M · **Labels** Bug · **Ticket group** T6 mirror-perf

**Problem**
`skills/transcript-mirror/transcript-mirror.sh:601` calls `index_idents`, which forks one `jq` per line (plus a second jq and sha256sum for uuid-less lines, `:35-61`) on every Stop. Measured: 14.1 s/tick at 3000 lines, 14.3 s with one appended line. The hook timeout is 10 s (SKILL.md:47, SPEC-036 M3), so the run exits 124, the cursor never advances and `tmirror.*` leaks — mirroring silently stops for any session over ~2000 lines. Violates SPEC-036 M6 "incremental" and the ≤10 s SHOULD; SKILL.md still promises a 10 s-safe hook.

**Fix**
- Store the byte offset as cursor field 4; on a tick `tail -c +off`, verify the identity of the line just before the offset, full rebuild only on mismatch.
- Replace per-line jq with one `jq -R` pass (or a Python helper shared with transcript-sync) that emits idents for the whole file.

**Acceptance**
- Benchmark test: 3000-line transcript + 1 appended line completes a tick in <1 s.
- Offset mismatch (rewritten file) triggers full rebuild and stays correct.
- transcript-mirror test suite passes.

**Source**
- [README.md](README.md) #P0-19
- [06-handoff-transcript.md](06-handoff-transcript.md) #1
- [06-handoff-transcript.md](06-handoff-transcript.md) #B1
- [06-handoff-transcript.md](06-handoff-transcript.md) #F:transcript-mirror/SKILL.md

Sources: `README.md#P0-19`, `06-handoff-transcript.md#1`, `06-handoff-transcript.md#B1`, `06-handoff-transcript.md#F:transcript-mirror/SKILL.md`

### P0-20 · [install] Derive opencode tier map from agent `model:` frontmatter (SPEC-003)
**Priority** Urgent · **Effort** S · **Labels** Bug · **Ticket group** T4 setup-agents

**Problem**
`install.sh:123-196` hardcodes haiku→ic4,qa; sonnet→devops,pm; opus→tech-lead,ic5,ds. SPEC-003 says ic4/qa are sonnet, pm is opus, ic5 is sonnet (effort xhigh). The picker prompts are equally wrong, so opencode users get wrong models. Also unverified: pins are written to `.agent["ic4"]` while agents install under `agents/dev-team/`, whose names may be namespaced (`dev-team/ic4`), so pins may not apply at all.

**Fix**
- Read each agent's `model:` frontmatter before stripping and group agents by value; generate prompts from that grouping.
- Verify opencode's agent key for namespaced installs and write pins under the correct key.

**Acceptance**
- install-test asserts the generated tier grouping equals SPEC-003's table.
- Pin key verified against a real opencode config (or documented).
- No hardcoded agent→tier list remains in install.sh.

**Source**
- [README.md](README.md) #P0-20
- [01-agents-infra.md](01-agents-infra.md) #3
- [01-agents-infra.md](01-agents-infra.md) #F:install.sh(1)
- [01-agents-infra.md](01-agents-infra.md) #F:install.sh(6)
- [01-agents-infra.md](01-agents-infra.md) #cross-1

Sources: `README.md#P0-20`, `01-agents-infra.md#3`, `01-agents-infra.md#F:install.sh(1)`, `01-agents-infra.md#F:install.sh(6)`, `01-agents-infra.md#cross-1`

### W1-01 · [tests] Make the five red-on-master suites green
**Priority** High · **Effort** S · **Labels** Bug, Tech Debt · **Ticket group** T8 ci-all-tests

**Problem**
Five suites fail on master for real reasons: (1) `handoff/detached-stub-test.sh` — `commands/handoff.md` is 12096 B > 12000 cap (SPEC-018 T39); (2) `orchestrate/router-static-test.sh` T10 — `skills/orchestrate/steps/02-scope.md:6` mentions `ORCH_TIER` in a non-whitelisted form (red since v1.17.0); (3) `retro-gate/scheduled-retro-test.sh:47` greps a pattern that no longer matches `commands/retro.md:575` (Filter-2 is present); (4) `release-train/test-integration.sh` — fixture repo lacks `.gitignore`, so `restore` leaves `?? .claude/`; (5) `council/test-workflow-static.sh:17` calls `workflow-probe.sh` bare under `set -e` and exits 1 silently when `CLAUDE_CODE_VERSION` < 2.1.154, contradicting its "no live host" header.

**Fix**
- Trim `commands/handoff.md` below 12000 B (coordinate with the handoff Step1/3 item).
- Reword 02-scope.md:6 ("pipeline tier (S/M/L) is not `budget.tier`") or extend the T10 whitelist.
- Use `grep -F '<command-name>/[a-z:-]*retro'`.
- Add `.gitignore` with `.claude/` to the release-train fixture.
- Run the probe under `env -u CLAUDE_CODE_VERSION` and assert on its result.

**Acceptance**
- All five suites pass locally on Linux (non-root and root).
- Each is included in the CI all-tests job.

**Source**
- [README.md](README.md) #3-red-real
- [README.md](README.md) #wave0-red-suites
- [01-agents-infra.md](01-agents-infra.md) #cross-7
- [04-council.md](04-council.md) #test-results
- [05-orchestration.md](05-orchestration.md) #2
- [05-orchestration.md](05-orchestration.md) #F:steps/02-scope.md
- [06-handoff-transcript.md](06-handoff-transcript.md) #9
- [06-handoff-transcript.md](06-handoff-transcript.md) #test-results
- [09-release-tooling.md](09-release-tooling.md) #8
- [09-release-tooling.md](09-release-tooling.md) #test-results
- [10-specs.md](10-specs.md) #headline-5
- [10-specs.md](10-specs.md) #SPEC-018
- [10-specs.md](10-specs.md) #SPEC-009
- [10-specs.md](10-specs.md) #SPEC-017
- [10-specs.md](10-specs.md) #SPEC-012
- [10-specs.md](10-specs.md) #SPEC-013

Sources: `README.md#3-red-real`, `README.md#wave0-red-suites`, `01-agents-infra.md#cross-7`, `04-council.md#test-results`, `05-orchestration.md#2`, `05-orchestration.md#F:steps/02-scope.md`, `06-handoff-transcript.md#9`, `06-handoff-transcript.md#test-results`, `09-release-tooling.md#8`, `09-release-tooling.md#test-results`, `10-specs.md#headline-5`, `10-specs.md#SPEC-018`, `10-specs.md#SPEC-009`, `10-specs.md#SPEC-017`, `10-specs.md#SPEC-012`, `10-specs.md#SPEC-013`

### W1-02 · [worktree] Stop worktree-lib release from force-deleting unmerged/unpushed branches
**Priority** High · **Effort** S · **Labels** Bug · **Ticket group** T2 git-safety

**Problem**
`skills/worktree-lib.sh:324-334` `release` runs `git branch -D feat/<slug>` with no merged/pushed check (the dirty check covers only uncommitted changes). Reproduced: a committed, unmerged change became unreachable after `release` exited 0. It falls back to `worktree remove --force` (`:324-325`), which SPEC-016 L48 forbids, and removes `.wt-lock` (`:317`) before removal succeeds. `-D` is intentional for squash merges, but there is no patch-id/cherry or pushed check.

**Fix**
- Before deleting, require the branch to be an ancestor of the default branch, cherry-clean against it, or equal to `origin/feat/<slug>`; otherwise keep it, print `kept feat/<slug> (unmerged)` and exit 0 (use `git-safety.sh is-merged` once available).
- Drop the `--force` fallback; remove `.wt-lock` only after a successful remove.
- Mention the branch delete in SPEC-016.

**Acceptance**
- worktree-lib-test: release on an unmerged and on an unpushed branch keeps the branch.
- Squash-merged branch (cherry-clean) is still deleted.
- No `worktree remove --force` in worktree-lib.sh.

**Source**
- [README.md](README.md) #P1-worktree-lib
- [09-release-tooling.md](09-release-tooling.md) #2
- [09-release-tooling.md](09-release-tooling.md) #F:worktree-lib.sh(1-3)
- [09-release-tooling.md](09-release-tooling.md) #F:worktree-lib-test.sh
- [09-release-tooling.md](09-release-tooling.md) #cross-5
- [02-commands-docs.md](02-commands-docs.md) #cross-8
- [README.md](README.md) #4.3

Sources: `README.md#P1-worktree-lib`, `09-release-tooling.md#2`, `09-release-tooling.md#F:worktree-lib.sh(1-3)`, `09-release-tooling.md#F:worktree-lib-test.sh`, `09-release-tooling.md#cross-5`, `02-commands-docs.md#cross-8`, `README.md#4.3`

### W1-03 · [release] check-bump-class `--cached` must read plugin.json from the index
**Priority** High · **Effort** S · **Labels** Bug · **Ticket group** T2 git-safety

**Problem**
`skills/release/check-bump-class.sh:151-155` in `--cached` (pre-commit) mode reads the **worktree** `plugin.json` when it is not staged. Reproduced: stage a new command, bump plugin.json to 1.8.0 without staging → "ok", and the commit lands the command at 1.7.36. Also: `--diff-filter=A` misses renamed commands (a rename is a new Surface name); pre-release versions (`1.0.0-pre.N`) are `invalid` and hard-fail; the `commands/*.md` case glob matches nested paths; CI runs `--commit HEAD` with fetch-depth 2, so only the tip of a multi-commit push is gated.

**Fix**
- Always read `git show :.claude-plugin/plugin.json` in `--cached` mode.
- Use `--diff-filter=AR`; accept semver pre-release suffixes; anchor the glob to top-level `commands/`.
- CI: fetch enough depth and check every commit in the push range.

**Acceptance**
- New test: worktree bumped, index not → check fails.
- Rename of a command on a patch bump fails.
- Pre-release version accepted; nested `commands/x/y.md` ignored.

**Source**
- [README.md](README.md) #P1-bump-class
- [09-release-tooling.md](09-release-tooling.md) #3
- [09-release-tooling.md](09-release-tooling.md) #F:release/check-bump-class.sh
- [09-release-tooling.md](09-release-tooling.md) #F:release/test*.sh

Sources: `README.md#P1-bump-class`, `09-release-tooling.md#3`, `09-release-tooling.md#F:release/check-bump-class.sh`, `09-release-tooling.md#F:release/test*.sh`

### W1-04 · [wrap-ticket] Fix `${CHILD_WT:-{}}` defaults and the legacy prefix-match `branch -D`
**Priority** High · **Effort** S · **Labels** Bug · **Ticket group** T2 git-safety

**Problem**
`skills/wrap-ticket/SKILL.md:53,54,403,507` use `"${CHILD_WT:-{}}"`; bash closes the expansion at the first `}`, so non-empty values get a stray `}` (`{"a":1}}`) and jq errors "Unmatched '}'" — works by accident, breaks under pipefail. The legacy path (`:442-452`) uses `grep -wF "$TICKET_ID"`, which matches `CDT-1` inside `CDT-1-2`, then runs `git worktree remove` and `git branch -D feat/$TICKET_ID` with no merged/pushed check while the prompt at `:413` asserts "already merged"; an empty match yields `git worktree remove ""`. `cd $MROOT` (`:427`) is unquoted.

**Fix**
- `DEF='{}'; jq … <<<"${CHILD_WT:-$DEF}"` at all four sites.
- Legacy path: exact basename match, refuse empty path, use `branch -d` or the shared is-merged check.
- Quote `cd "$MROOT"`.

**Acceptance**
- Extracted block with non-empty CHILD_WT produces valid jq input (no stderr).
- Legacy path with tickets CDT-1 and CDT-1-2 touches only CDT-1.
- Unmerged branch is kept.

**Source**
- [09-release-tooling.md](09-release-tooling.md) #4
- [09-release-tooling.md](09-release-tooling.md) #F:wrap-ticket/SKILL.md
- [README.md](README.md) #4.3

Sources: `09-release-tooling.md#4`, `09-release-tooling.md#F:wrap-ticket/SKILL.md`, `README.md#4.3`

### W1-05 · [release] Push only the release tag atomically; refuse detached HEAD
**Priority** High · **Effort** S · **Labels** Bug · **Ticket group** T2 git-safety

**Problem**
`skills/release/SKILL.md:463-464` runs `git push origin "$BRANCH" --tags`, publishing every local tag (including stale or deleted false-patch tags), non-atomically. On a detached HEAD `BRANCH=HEAD` and the push fails midway.

**Fix**
- `git push --atomic origin "$BRANCH" "refs/tags/vX.Y.Z"`.
- Refuse at Step 0 when HEAD is detached, with a clear message.

**Acceptance**
- release/test.sh asserts the push command names exactly one tag with `--atomic`.
- Detached-HEAD run exits before any mutation.
- AGENTS.md release rules still satisfied (docs-drift passes).

**Source**
- [README.md](README.md) #P1-tags
- [09-release-tooling.md](09-release-tooling.md) #7
- [09-release-tooling.md](09-release-tooling.md) #F:release/SKILL.md(1)
- [09-release-tooling.md](09-release-tooling.md) #F:release/SKILL.md(7)

Sources: `README.md#P1-tags`, `09-release-tooling.md#7`, `09-release-tooling.md#F:release/SKILL.md(1)`, `09-release-tooling.md#F:release/SKILL.md(7)`

### W1-06 · [autopilot] Add clean-tree precheck before end-state squash and `reset --hard`
**Priority** High · **Effort** S · **Labels** Bug · **Ticket group** T2 git-safety

**Problem**
`skills/autopilot/end-state.md` has no clean-tree precheck before §4 `git merge --squash`; the §4 conflict path and §6.5 abort both run `git reset --hard` on the main repo, discarding tracked WIP (e.g. the `CONTEXT.md` dirt orchestrate 3b explicitly allows). `return 1` in a bash fence is invalid outside a function, and BC3 checks `origin/HEAD` without a fetch (stale ref).

**Fix**
- §3.6: require `git -C <main> status --porcelain` to be empty, else halt BC3/BC7 with the dirty paths listed.
- Replace `return 1` with explicit prose/exit.
- `git fetch origin` before evaluating BC3.

**Acceptance**
- autopilot/test.sh case: dirty main repo halts before squash; WIP intact.
- BC3 evaluated against a freshly fetched ref.
- No bare `return` at fence top level.

**Source**
- [README.md](README.md) #P1-end-state
- [05-orchestration.md](05-orchestration.md) #8
- [05-orchestration.md](05-orchestration.md) #F:autopilot/end-state.md
- [README.md](README.md) #4.3

Sources: `README.md#P1-end-state`, `05-orchestration.md#8`, `05-orchestration.md#F:autopilot/end-state.md`, `README.md#4.3`

### W1-07 · [backlog] close.sh: fix duplicate `## Completed` header and awk escape mangling
**Priority** High · **Effort** S · **Labels** Bug · **Ticket group** —

**Problem**
`skills/backlog/close.sh:327-343`: when `## Completed` is the last line, awk's `getline` fails and leaves `$0` unchanged, emitting a duplicate header (reproduced). `:271,324` pass values with `awk -v`, which expands escapes: `--note 'a\tb'` becomes a literal TAB and backslashes in notes/tickets are mangled (reproduced). There is no lock between concurrent close and reconcile runs.

**Fix**
- Replace `getline` with a state flag.
- Pass `ns`, `cl`, `newline` via `ENVIRON` instead of `-v`.
- Take a shared backlog lock (mkdir-based) in close.sh and reconcile.sh.

**Acceptance**
- backlog/test.sh: closing when `## Completed` is last yields one header.
- Note with `\t` and backslashes round-trips verbatim.
- Concurrent close+reconcile serialize.

**Source**
- [09-release-tooling.md](09-release-tooling.md) #6
- [09-release-tooling.md](09-release-tooling.md) #F:backlog/close.sh

Sources: `09-release-tooling.md#6`, `09-release-tooling.md#F:backlog/close.sh`

### W1-08 · [orchestrate] Unify task-store keys on plan index; fix per-fence DAG_FILE
**Priority** High · **Effort** S · **Labels** Bug · **Ticket group** —

**Problem**
The Step 7 pre-gate maps plan "Task N" → `<ISSUE-ID>-N` (`skills/orchestrate/steps/07-tasks.md:11`), but `create` keys by the TaskCreate integer `<ISSUE-ID>-<task_id>` (`:101-104`). TaskCreate ids are session-global, so `depends_on` never matches and `ready-set` deadlocks or releases tasks wrongly. Kickoff Step 7 has the same drift. The cycle fence sets `DAG_FILE=…-$$.json` and assumes it was written earlier (`:14-16`), but `$$` differs per fence → rc=2 "could not run". Halt branches only `echo` (no `exit`).

**Fix**
- Key the task store by plan index `<ISSUE-ID>-N` in orchestrate 07 and kickoff Step 7; record a TaskCreate-id ↔ N map in the plan; pass `-N` to update-status.
- Use a deterministic DAG file path (`.claude/tasks/<ISSUE>-dag.json`).
- Add `exit` to halt branches.

**Acceptance**
- task-store-test: dependencies resolve when TaskCreate ids ≠ plan indices.
- Cycle check finds the DAG file written in a previous fence.
- router-static-test passes.

**Source**
- [05-orchestration.md](05-orchestration.md) #3
- [05-orchestration.md](05-orchestration.md) #F:steps/07-tasks.md
- [05-orchestration.md](05-orchestration.md) #cross-4
- [05-orchestration.md](05-orchestration.md) #F:kickoff/SKILL.md(dag)
- [README.md](README.md) #4.2

Sources: `05-orchestration.md#3`, `05-orchestration.md#F:steps/07-tasks.md`, `05-orchestration.md#cross-4`, `05-orchestration.md#F:kickoff/SKILL.md(dag)`, `README.md#4.2`

### W1-09 · [orchestrate] Scope dag-lib ready-set per issue, skip corrupt files, add tests
**Priority** High · **Effort** S · **Labels** Bug · **Ticket group** —

**Problem**
`skills/orchestrate/dag-lib.sh` `ready-set` reads every `.claude/tasks/*.json` from every issue ever (the store is never pruned), so stale pending tasks from other or abandoned issues are fanned out. One corrupt JSON file fails the whole ready-set (reproduced rc=5). `blocked` dependencies wait forever with no signal; `status-of` has no task_id charset check (`../` joins). dag-lib has no dedicated test. In `task-store.sh`, `create` prints both "upserted" and "created" on upsert, and `status-of` lacks the compound resolution that `update-status` uses.

**Fix**
- `ready-set [--prefix <ISSUE-ID>-]`, required by orchestrate callers; skip unparseable files with a stderr warning.
- Report tasks blocked on `blocked` deps.
- Validate task ids `^[A-Za-z0-9._-]+$`.
- Fix the upsert message; share compound resolution.

**Acceptance**
- New `dag-lib-test.sh`: prefix scoping, corrupt-file skip, blocked-dep report, traversal rejection.
- Existing DFS cases (self-loop, diamond, 3-cycle) covered.
- Wired into CI.

**Source**
- [05-orchestration.md](05-orchestration.md) #4
- [05-orchestration.md](05-orchestration.md) #F:orchestrate/dag-lib.sh
- [05-orchestration.md](05-orchestration.md) #F:orchestrate/task-store.sh
- [05-orchestration.md](05-orchestration.md) #F:task-store-test.sh
- [05-orchestration.md](05-orchestration.md) #cross-3

Sources: `05-orchestration.md#4`, `05-orchestration.md#F:orchestrate/dag-lib.sh`, `05-orchestration.md#F:orchestrate/task-store.sh`, `05-orchestration.md#F:task-store-test.sh`, `05-orchestration.md#cross-3`

### W1-10 · [orchestrate] Write task status `in_progress` at spawn (SPEC-009:72)
**Priority** High · **Effort** S · **Labels** Bug, Concurrency · **Ticket group** —

**Problem**
Nothing writes `task-store update-status … in_progress` when a task is spawned (`skills/orchestrate/steps/08-execute.md`), although SPEC-009:72 requires it. `ready-set` keeps returning in-flight tasks, risking double-spawn, and the rule at `:304` ("check in-progress task store status") cannot be met.

**Fix**
- In 08-execute, call `task-store update-status <key> in_progress` immediately after each spawn (plan-index key).
- On resume, treat stale `in_progress` tasks explicitly (re-spawn prompt).

**Acceptance**
- Test: after a simulated spawn, ready-set no longer returns that task.
- router-static-test asserts the update-status call exists in 08-execute.
- SPEC-009:72 satisfied.

**Source**
- [05-orchestration.md](05-orchestration.md) #5
- [05-orchestration.md](05-orchestration.md) #F:steps/08-execute.md

Sources: `05-orchestration.md#5`, `05-orchestration.md#F:steps/08-execute.md`

### W1-11 · [autopilot] resume-state: match the exact ticket id, scope grep to Tracking
**Priority** High · **Effort** S · **Labels** Bug · **Ticket group** —

**Problem**
`skills/autopilot/resume-state.sh:112` globs `*-<ID>-*.md`, so `CDT-141` matches epic child plans like `…-CDT-141-C3-slug.md`; with several matches the newest mtime wins and resume can seed the wrong autopilot state. `grep -m1 '^- autopilot_on:'` is not scoped to `## Tracking`, and `--accumulated` takes the max over all historical runs of the ticket.

**Fix**
- Match `^[0-9-]+-<ID>-` and confirm `ticket_id:` in the Tracking block equals `<ID>`.
- Scope field greps to the `## Tracking` block.
- Limit `--accumulated` to the current run lineage (or document).

**Acceptance**
- autopilot/test.sh: parent CDT-141 with child CDT-141-C3 plan resolves to the parent.
- Field outside Tracking is ignored.
- 311 existing assertions still pass.

**Source**
- [05-orchestration.md](05-orchestration.md) #9
- [05-orchestration.md](05-orchestration.md) #F:autopilot/resume-state.sh

Sources: `05-orchestration.md#9`, `05-orchestration.md#F:autopilot/resume-state.sh`

### W1-12 · [transcript] One Claude project-dir encoder used everywhere
**Priority** High · **Effort** S · **Labels** Bug · **Ticket group** —

**Problem**
Claude Code maps every non-alphanumeric character in the cwd to `-`. Only `retro-gate/hint.sh:33` and `handoff/resolve-root.sh:148` do this; `transcript-parse/hosts.py:78`, `handoff/discover-warm.sh:409`, `retro-gate/trial-review.sh:207` and `commands/retro.md:230` replace only `/`. Any cwd containing `.`, `_` or a space (e.g. `~/john.doe/my_app`) gets no newest-session locate for retro auto-detect, warm handoff, transcript-sync and trial-review. The tests (`discover-host-test.sh:27`, `discover-warm-test.sh:189`) encode it the same wrong way.

**Fix**
- Add `hosts.claude_encode_cwd` (`re.sub('[^A-Za-z0-9]','-',abs)`) and a CLI `hosts.py encode-cwd`.
- Replace the sed encoders in discover-warm, trial-review, retro.md (and hint/resolve-root) with the CLI.
- Fix the two tests.

**Acceptance**
- Tests cover a cwd with `.`, `_` and space.
- grep finds no other project-dir encoder implementation.
- discover-warm and discover-host tests pass.

**Source**
- [06-handoff-transcript.md](06-handoff-transcript.md) #3
- [06-handoff-transcript.md](06-handoff-transcript.md) #B3
- [README.md](README.md) #4.8
- [06-handoff-transcript.md](06-handoff-transcript.md) #cross-1
- [06-handoff-transcript.md](06-handoff-transcript.md) #F:transcript-parse/hosts.py
- [06-handoff-transcript.md](06-handoff-transcript.md) #F:retro-gate/trial-review.sh

Sources: `06-handoff-transcript.md#3`, `06-handoff-transcript.md#B3`, `README.md#4.8`, `06-handoff-transcript.md#cross-1`, `06-handoff-transcript.md#F:transcript-parse/hosts.py`, `06-handoff-transcript.md#F:retro-gate/trial-review.sh`

### W1-13 · [transcript] Harden transcript-parse assemble: uuid type, utf-8, single locate
**Priority** High · **Effort** S · **Labels** Bug · **Ticket group** —

**Problem**
`skills/transcript-parse/assemble.py:235` crashes on a non-hashable uuid (`{"uuid":{"x":1}}` → TypeError), killing every cold, warm and PreCompact handoff. `open()` lacks `encoding="utf-8"` (`:118,181`; also `resolve-root.sh:121`), so behavior depends on locale. `locate` JSON-parses every line of every project JSONL; BrokenPipe traceback when the consumer closes early. A cold `prepass.sh` prepare locates up to 3–4 times (`:1070`, python assemble `:1210`, M3f transcript-sync, compute_leaf) and holds every parsed message including `tool_result` blocks in memory (`:1305`).

**Fix**
- Require `isinstance(u, str)` in the message filter; add `encoding="utf-8"` everywhere.
- Substring pre-filter in `locate`; handle BrokenPipe.
- prepass: locate once and pass `assemble-file $CANONICAL` to assemble/compute_leaf and `--transcript` to M3f; strip tool_result content from retained records.

**Acceptance**
- Test with a dict uuid line: assemble succeeds and skips it.
- Cold prepare invokes locate once (counted in a test shim).
- Runs under `LC_ALL=C` with non-ASCII transcripts.

**Source**
- [06-handoff-transcript.md](06-handoff-transcript.md) #4
- [06-handoff-transcript.md](06-handoff-transcript.md) #B5
- [06-handoff-transcript.md](06-handoff-transcript.md) #F:transcript-parse/assemble.py
- [06-handoff-transcript.md](06-handoff-transcript.md) #F:handoff/prepass.sh(a)
- [06-handoff-transcript.md](06-handoff-transcript.md) #F:handoff/prepass.sh(b)
- [06-handoff-transcript.md](06-handoff-transcript.md) #F:handoff/resolve-root.sh

Sources: `06-handoff-transcript.md#4`, `06-handoff-transcript.md#B5`, `06-handoff-transcript.md#F:transcript-parse/assemble.py`, `06-handoff-transcript.md#F:handoff/prepass.sh(a)`, `06-handoff-transcript.md#F:handoff/prepass.sh(b)`, `06-handoff-transcript.md#F:handoff/resolve-root.sh`

### W1-14 · [scripts] Guard every `shift 2` with a value check (infinite loops, silent exits)
**Priority** High · **Effort** S · **Labels** Bug · **Ticket group** T5 retro-scheduled

**Problem**
A flag given with no value makes `shift 2` fail without shifting: `retro-gate/write-scheduled-report.sh:41-60` loops forever (confirmed `timeout 3` rc=124); same pattern in `trial-meta.sh:80-83,137-140` and `trial-review.sh:61-73`. In `skills/council/engine.sh` (`:79,111,142-152,630-639`) and `external-reviewer.sh`, `preflight --task-id` exits 1 silently instead of printing usage and exiting 2. `trial-meta.sh:30` also uses unquoted `printf '%s\n' $body`, glob-expanding tokens against the cwd.

**Fix**
- Add a `need_val` helper (`[ $# -ge 2 ] || { usage; exit 2; }`) before every `shift 2` in these five scripts (prepass already has the pattern).
- Quote `$body` in trial-meta.

**Acceptance**
- Each script called with a trailing valueless flag exits 2 with usage within 1 s (test per script).
- `grep -n 'shift 2'` in these files shows each guarded.
- Glob characters in trial body are preserved.

**Source**
- [06-handoff-transcript.md](06-handoff-transcript.md) #5
- [06-handoff-transcript.md](06-handoff-transcript.md) #B4
- [04-council.md](04-council.md) #11
- [04-council.md](04-council.md) #F:council/engine.sh(6)
- [06-handoff-transcript.md](06-handoff-transcript.md) #F:retro-gate/trial-meta.sh
- [README.md](README.md) #6-T5

Sources: `06-handoff-transcript.md#5`, `06-handoff-transcript.md#B4`, `04-council.md#11`, `04-council.md#F:council/engine.sh(6)`, `06-handoff-transcript.md#F:retro-gate/trial-meta.sh`, `README.md#6-T5`

### W1-15 · [retro] Make scheduled-lock.sh atomic with owner-checked release
**Priority** High · **Effort** S · **Labels** Bug, Concurrency · **Ticket group** T5 retro-scheduled

**Problem**
`skills/retro-gate/scheduled-lock.sh:35-60` checks then writes with `mv -f`, so two runs starting together both acquire the lock. `release` (`:68`) deletes a lock owned by another pid. `scheduled-lock-test.sh` never runs two acquirers at once.

**Fix**
- Acquire with `mkdir "$LOCK.d"` or `set -C` (O_EXCL); steal a stale lock via rename after an age/pid-liveness check.
- `release` compares the stored pid/token before removing.

**Acceptance**
- Test runs two acquirers concurrently: exactly one succeeds.
- Release by a non-owner is refused.
- Stale lock (dead pid) is stolen.

**Source**
- [06-handoff-transcript.md](06-handoff-transcript.md) #6
- [06-handoff-transcript.md](06-handoff-transcript.md) #B7
- [06-handoff-transcript.md](06-handoff-transcript.md) #F:retro-gate/scheduled-lock.sh
- [README.md](README.md) #6-T5

Sources: `06-handoff-transcript.md#6`, `06-handoff-transcript.md#B7`, `06-handoff-transcript.md#F:retro-gate/scheduled-lock.sh`, `README.md#6-T5`

### W1-16 · [security] Stop resolving plugin scripts from cwd or a consumer repo
**Priority** High · **Effort** S · **Labels** Security · **Ticket group** —

**Problem**
Several resolvers trust the working directory: `transcript-mirror/hook-shim.sh:17` runs `skills/…/transcript-mirror.sh` from `pwd`, so a Stop hook after `cd` into an untrusted repo runs that repo's code; `handoff/prepass.sh:1102` and other `.sh` PDH copies prefer cwd `skills/plugin-dir.sh` and carry a dead literal `'${CLAUDE_PLUGIN_ROOT}'` tier; `agent-memory/protocol.md:106` checks cwd-relative `skills/memory-store/embed-one.sh` first (executed with memory content). `skills/plugin-dir.sh` tiers 1–2 (`:178-192`) accept `$WTROOT/<rel>` in any repo without checking it is dev-team. Also dead helpers (`highest_cache_ver` :146, `plugin_root_of` :290), first-match `marketplace_roots`, `sort -V`.

**Fix**
- hook-shim/precompact wrapper: resolve from `$CLAUDE_PROJECT_DIR` then the cache; skills/*.sh use `$SCRIPT_DIR/..`.
- protocol.md embed lookup via `plugin-dir.sh`.
- plugin-dir tiers 1–2 require `.claude-plugin/plugin.json` name `dev-team`; remove dead helpers.

**Acceptance**
- Test: a consumer repo with a hostile `skills/plugin-dir.sh` is not executed by hook-shim.
- plugin-dir-test covers the identity check.
- sync-includes check clean after protocol change.

**Source**
- [06-handoff-transcript.md](06-handoff-transcript.md) #8
- [09-release-tooling.md](09-release-tooling.md) #16
- [07-memory.md](07-memory.md) #F:agent-memory/protocol.md(embed)
- [07-memory.md](07-memory.md) #20
- [06-handoff-transcript.md](06-handoff-transcript.md) #F:transcript-mirror/hook-shim.sh
- [06-handoff-transcript.md](06-handoff-transcript.md) #F:handoff/prepass.sh(c)
- [06-handoff-transcript.md](06-handoff-transcript.md) #F:transcript-mirror/transcript-sync.py
- [09-release-tooling.md](09-release-tooling.md) #F:plugin-dir.sh

Sources: `06-handoff-transcript.md#8`, `09-release-tooling.md#16`, `07-memory.md#F:agent-memory/protocol.md(embed)`, `07-memory.md#20`, `06-handoff-transcript.md#F:transcript-mirror/hook-shim.sh`, `06-handoff-transcript.md#F:handoff/prepass.sh(c)`, `06-handoff-transcript.md#F:transcript-mirror/transcript-sync.py`, `09-release-tooling.md#F:plugin-dir.sh`

### W1-17 · [memory] Distill lock ownership, real exits, safe deep rebuild
**Priority** High · **Effort** S · **Labels** Bug, Concurrency · **Ticket group** T1 memory-safety

**Problem**
In `commands/memory.md` a failed lock acquisition or empty agent set responds only with a `# Stop here` comment and no `exit` (`:329-333,417-422,474-487`; also `:252,807,824,827,844`). Step 8 then releases unconditionally (`SET value=''`), so a run that never got the lock can clear another process's live lock. Deep rebuild (`:1489-1524`) archives the digest first and re-distills after; if the distiller fails the knowledge is lost, and it only checks (10.4) and never takes the lock.

**Fix**
- Store the Step 4 token; release with `UPDATE … WHERE value='$TOKEN'`.
- Replace every `# Stop here` in executable fences with a real `exit N`.
- Deep mode: take the lock, re-distill first, archive the old digest only after success.

**Acceptance**
- Test: a run without the lock cannot clear another token's lock.
- Distiller failure during deep rebuild leaves the original digest live.
- No `# Stop here` without `exit` in memory.md (lint rule in lint item).

**Source**
- [03-large-commands.md](03-large-commands.md) #E9
- [03-large-commands.md](03-large-commands.md) #M5
- [03-large-commands.md](03-large-commands.md) #M6
- [03-large-commands.md](03-large-commands.md) #cross-3
- [README.md](README.md) #4.2

Sources: `03-large-commands.md#E9`, `03-large-commands.md#M5`, `03-large-commands.md#M6`, `03-large-commands.md#cross-3`, `README.md#4.2`

### W1-18 · [memory] Reconcile: resolve PLUGIN_ROOT via plugin-dir.sh; put LIMIT in the query
**Priority** High · **Effort** S · **Labels** Bug · **Ticket group** T1 memory-safety

**Problem**
`commands/memory.md:1587-1600,1706-1775` resolves reconcile's `PLUGIN_ROOT` from `$WTROOT` or `$CLAUDE_PLUGIN_ROOT` instead of `plugin-dir.sh` (AGENTS.md). On a real install `$WTROOT` has no `skills/`, and with `CLAUDE_PLUGIN_ROOT` unset the lib path doesn't exist; `|| true` (:1612) swallows it, `CAND_N` is empty (not 0) and the R1 "if 0" branch is ambiguous. The boilerplate repeats 6 times. Step 3.1 (`:928`) tells the reader to add `LIMIT 100` to the Step 2 SQL, which has no LIMIT (`:885-890`).

**Fix**
- Resolve reconcile-lib via PDH + `plugin-dir.sh file skills/validate-memory/reconcile-lib.sh` once; fail loudly if missing; default `CAND_N=${CAND_N:-0}`.
- Put `LIMIT 100` directly in the Step 2 query.

**Acceptance**
- Scripted reconcile in an installed-layout temp dir finds reconcile-lib.
- Missing lib produces an error, not silent zero.
- Step 2 SQL contains LIMIT 100.

**Source**
- [03-large-commands.md](03-large-commands.md) #M7
- [03-large-commands.md](03-large-commands.md) #M8
- [03-large-commands.md](03-large-commands.md) #cross-6

Sources: `03-large-commands.md#M7`, `03-large-commands.md#M8`, `03-large-commands.md#cross-6`

### W1-19 · [memory] Use `-cmd ".timeout 5000"` on every memory DB access
**Priority** High · **Effort** S · **Labels** Bug, Concurrency · **Ticket group** T1 memory-safety

**Problem**
busy_timeout coverage is inconsistent. Missing in `embed-one.sh` (all writes `:55,126,132` — lembed vectors silently lost under concurrent worktree writes via `2>/dev/null || true`, contradicting its own `:119` comment), `migrate.sh` read, `migrate-md.sh`, `download-extensions.sh`, `cortex-load.md`, `memory-recall`, memory-store Step 5.5, export. `memory-store/SKILL.md:161` and `agents/distiller.md:45,50,76-77` recommend `PRAGMA busy_timeout=5000;`, which prints `5000` and corrupts `$(…)` captures (e.g. `MEMORY_ID` :86). SPEC-004 requires a timeout on every write. `cortex-load.md:35` bare `[ "$HAS_DISTILLED" -gt 0 ]` errors on empty output.

**Fix**
- Replace every `sqlite3 "$MEMDB"` with `sqlite3 -cmd ".timeout 5000" "$MEMDB"`; fix SKILL.md:161 and distiller guidance.
- Stop swallowing write errors in embed-one; `${HAS_DISTILLED:-0}` in cortex-load.
- Lint rule (sqlite3 on `$MEMDB` without `.timeout`) tracked in the lint item.

**Acceptance**
- grep finds no `sqlite3 "$MEMDB"` without `.timeout` in skills/, commands/, agents/.
- Concurrency test: two embed-one writers both persist vectors.
- No `PRAGMA busy_timeout` inside captured commands.

**Source**
- [07-memory.md](07-memory.md) #7
- [07-memory.md](07-memory.md) #cross-concurrency
- [07-memory.md](07-memory.md) #F:memory-store/embed-one.sh(timeout)
- [07-memory.md](07-memory.md) #F:memory-store/SKILL.md(:161)
- [07-memory.md](07-memory.md) #F:agent-memory/cortex-load.md
- [01-agents-infra.md](01-agents-infra.md) #F:agents/distiller.md(4)
- [10-specs.md](10-specs.md) #SPEC-004

Sources: `07-memory.md#7`, `07-memory.md#cross-concurrency`, `07-memory.md#F:memory-store/embed-one.sh(timeout)`, `07-memory.md#F:memory-store/SKILL.md(:161)`, `07-memory.md#F:agent-memory/cortex-load.md`, `01-agents-infra.md#F:agents/distiller.md(4)`, `10-specs.md#SPEC-004`

### W1-20 · [scripts] Replace the `grep -c … || echo 0` idiom (prints `0\n0`)
**Priority** High · **Effort** S · **Labels** Bug · **Ticket group** —

**Problem**
`grep -c` prints `0` and exits 1 on no match, so `$(grep -c … || echo 0)` yields `"0\n0"`. Confirmed at `commands/adjust-agent.md:81` (dashboard misaligned) and in `commands/retro.md:465-466,473,591,1676,1774,1883,1957-1959` (reproduced `[ "$x" -eq 0 ]` → "integer expression expected"; the `--host grok` no-sessions branch and empty-file directive counts break). `tools/permission-matrix-probe.sh:354` has the same with `rg -c`. adjust-agent L61/96 also omit that finder and debugger are mappable (`write-model.sh:29`).

**Fix**
- Use `COUNT=$(grep -c … 2>/dev/null); COUNT=${COUNT:-0}` or `|| true` at every site.
- Mention finder/debugger mappability in adjust-agent.
- Add a lint rule for `grep -c[^|]*\|\| echo 0` (lint item).

**Acceptance**
- grep over repo finds no `-c … || echo 0` pattern.
- Extracted adjust-agent dashboard renders a single count for an empty file.
- retro grok no-sessions branch prints its error.

**Source**
- [02-commands-docs.md](02-commands-docs.md) #13
- [02-commands-docs.md](02-commands-docs.md) #F:commands/adjust-agent.md(1)
- [02-commands-docs.md](02-commands-docs.md) #F:commands/adjust-agent.md(3)
- [03-large-commands.md](03-large-commands.md) #R3
- [03-large-commands.md](03-large-commands.md) #E11
- [01-agents-infra.md](01-agents-infra.md) #F:tools/permission-matrix-probe.sh(rg-c)

Sources: `02-commands-docs.md#13`, `02-commands-docs.md#F:commands/adjust-agent.md(1)`, `02-commands-docs.md#F:commands/adjust-agent.md(3)`, `03-large-commands.md#R3`, `03-large-commands.md#E11`, `01-agents-infra.md#F:tools/permission-matrix-probe.sh(rg-c)`

### W1-21 · [retro] Small retro.md correctness fixes (freshness shell, counts, applied stats)
**Priority** High · **Effort** S · **Labels** Bug · **Ticket group** —

**Problem**
`commands/retro.md` has several independent slips: `:543` runs `sh "$FRESHNESS"` on a bash script, so under dash any bash-ism yields an rc that is neither 0 nor 9 and the 60 s in-progress guard is silently disabled (R5, P1). `:1517` ignores `TRIAL_DECISIONS` in the short-circuit (R8). `:1919-1931` writes MANUAL_FOLLOWUP rows to `APPLIED_FILE`, over-reporting (R9). The `--all` 2 s cap (`:667-675`) is measured after `gate.sh` finishes (R11). `:1534` says Step 6f (duplicates are 6d); no Step 4a (R14). `:1679` increments `APPLIED` when only printing `/adjust-agent` (R15). The gate is re-run in 4b (`:768`) despite Step 3b output (R17).

**Fix**
- `bash "$FRESHNESS"`; include `TRIAL_DECISIONS` in the short-circuit; exclude parked rows from APPLIED_FILE; count printed-only suggestions separately.
- Enforce the per-file cap with `timeout`/helper or drop the claim; fix step references; reuse 3b gate output.

**Acceptance**
- Freshness guard fires for an in-progress session under `sh` = dash.
- Scheduled report's applied count excludes MANUAL_FOLLOWUP rows.
- Step references resolve.

**Source**
- [03-large-commands.md](03-large-commands.md) #R5
- [03-large-commands.md](03-large-commands.md) #R8
- [03-large-commands.md](03-large-commands.md) #R9
- [03-large-commands.md](03-large-commands.md) #R11
- [03-large-commands.md](03-large-commands.md) #R14
- [03-large-commands.md](03-large-commands.md) #R15
- [03-large-commands.md](03-large-commands.md) #R17

Sources: `03-large-commands.md#R5`, `03-large-commands.md#R8`, `03-large-commands.md#R9`, `03-large-commands.md#R11`, `03-large-commands.md#R14`, `03-large-commands.md#R15`, `03-large-commands.md#R17`

### W1-22 · [council] Blind path: worktree-correct file scope and unique report names
**Priority** High · **Effort** S · **Labels** Bug · **Ticket group** —

**Problem**
`commands/council.md:1149-1158` (B1) runs `git ls-files "$MROOT/$TARGET"`; from a linked worktree `$MROOT` is the main checkout, so git errors "outside repository" and the `find` fallback reviews the main checkout, not the worktree. `git ls-files` exits 0 with empty output for untracked paths, so the fallback never fires. `grep -v '.git/'` has an unescaped dot and `grep -v 'dist/'` drops `redist/`. The blind report path `${DATE}-blind[-slug].md` (`:1248-1249`) is overwritten by a second same-day run.

**Fix**
- `git -C "$WTROOT" ls-files -- "$TARGET"` with a fallback when the list is empty.
- Anchor exclusion patterns (`grep -vE '(^|/)\.git/|(^|/)dist/'`).
- Add `-HHMMSS` to the blind report name.

**Acceptance**
- Blind run from a linked worktree reviews worktree files (fixture test).
- Untracked target falls back to find.
- Two same-day runs produce two reports.

**Source**
- [03-large-commands.md](03-large-commands.md) #E12
- [03-large-commands.md](03-large-commands.md) #C3
- [03-large-commands.md](03-large-commands.md) #C12

Sources: `03-large-commands.md#E12`, `03-large-commands.md#C3`, `03-large-commands.md#C12`

### W1-23 · [fix-ticket] Refuters must inspect untracked files created by the implementer
**Priority** High · **Effort** S · **Labels** Bug, Security · **Ticket group** —

**Problem**
Refuters inspect `git diff` only (`skills/fix-ticket/prompts/refute.md:24`, `workflow.js:187`), so files newly created by the implementer are invisible to adversarial review.

**Fix**
- refute.md and workflow.js: run `git status --porcelain` and read every `??` path in addition to `git diff`.
- Include the untracked file list in the refuter evidence section.

**Acceptance**
- Prompt text instructs refuters to read untracked files (grep test).
- workflow.js passes the porcelain list (node unit test with a stub).
- check-template-vars covers any new variable.

**Source**
- [04-council.md](04-council.md) #10
- [04-council.md](04-council.md) #F:fix-ticket/SKILL.md(1)

Sources: `04-council.md#10`, `04-council.md#F:fix-ticket/SKILL.md(1)`

### W1-24 · [review-and-commit] Review exactly what gets committed (untracked + staging)
**Priority** High · **Effort** S · **Labels** Bug · **Ticket group** —

**Problem**
`skills/review-and-commit/SKILL.md:33` reviews staged + unstaged changes but misses untracked files, and Step 7.4 runs `git commit` with no `git add`, so the reviewed set differs from the committed set. The "N findings from 5 agents" stat ignores the external-reviewer slot.

**Fix**
- Step 1: include untracked files (`git add -N` or `git ls-files --others --exclude-standard`).
- 7.4: stage exactly the reviewed paths, or refuse when unstaged changes exist outside the reviewed set.
- Compute the agent count from the plan.

**Acceptance**
- Fixture: new untracked file appears in the review input.
- Commit contains only reviewed paths.
- Stat line reflects external reviewer when enabled.

**Source**
- [08-workflow-skills.md](08-workflow-skills.md) #8
- [08-workflow-skills.md](08-workflow-skills.md) #F:review-and-commit/SKILL.md(scope)

Sources: `08-workflow-skills.md#8`, `08-workflow-skills.md#F:review-and-commit/SKILL.md(scope)`

### W1-25 · [bug-hunt] Argument strictness, report-name collisions, materialize confinement
**Priority** High · **Effort** S · **Labels** Bug · **Ticket group** —

**Problem**
In `skills/bug-hunt/SKILL.md`, handoff mode silently accepts `--proceed`/`--severity-floor` (`:398-437`, probe: `handoff x-plan.md --proceed --severity-floor critical` accepted), breaking M4 "no silent ignore". Materialize takes `--start-phase`, missing from the usage line (`:57`). `BH_FLOOR_FROM_CLI` (`:1461`) is never set or read. The report stem `<date>-<slug>` (`:534-541`) has no collision check, so a same-day re-run overwrites report and json. Materialize accepts any absolute path and sets `BH_REPORT_DIR` to its directory (`:1525,1559`), writing plans outside `.claude/bug-hunt/` (M25).

**Fix**
- Reject `--proceed`/`--severity-floor` in handoff mode with exit 64.
- Add `--start-phase` to usage; delete `BH_FLOOR_FROM_CLI`.
- Suffix `-2…` when the stem exists; confine `BH_MAT_ABS` to `$MROOT/.claude/bug-hunt/`.

**Acceptance**
- Extracted S0 block: handoff with `--proceed` exits 64.
- Second same-day hunt writes `-2` files.
- Materialize with an absolute path outside `.claude/bug-hunt/` is refused.

**Source**
- [08-workflow-skills.md](08-workflow-skills.md) #11
- [08-workflow-skills.md](08-workflow-skills.md) #F:bug-hunt/SKILL.md(bash)
- [08-workflow-skills.md](08-workflow-skills.md) #test-results

Sources: `08-workflow-skills.md#11`, `08-workflow-skills.md#F:bug-hunt/SKILL.md(bash)`, `08-workflow-skills.md#test-results`

### W1-26 · [debug] Fix Step 0c/1b relative-path guard in debug and refactor
**Priority** High · **Effort** S · **Labels** Bug · **Ticket group** T7 debug-gates

**Problem**
`skills/debug/SKILL.md:240-278` and `skills/refactor/SKILL.md:196-231` (`:208,229`) do `[[ "$SAFE_PATH" != "$WTROOT"* ]] && SAFE_PATH=""`, discarding every relative path such as `src/x.go`. Then `git log -- ""` fails ("empty string is not a valid pathspec", reproduced) and `find "$(dirname "")"` falls back to the cwd.

**Fix**
- Resolve `SAFE_PATH` against `$WTROOT` when relative, normalize (`realpath -m` or Python argv fallback), then check the prefix.
- Guard `git log`/`find` with `[ -n "$SAFE_PATH" ]`.
- Extract to `skills/lib/safe-path.sh` used by both skills.

**Acceptance**
- Test for safe-path.sh: relative in-tree kept, `../x` rejected, absolute outside rejected.
- debug and refactor fences call the shared helper.
- No `git log -- ""` possible (guarded).

**Source**
- [08-workflow-skills.md](08-workflow-skills.md) #6
- [08-workflow-skills.md](08-workflow-skills.md) #F:debug/SKILL.md(0c)
- [08-workflow-skills.md](08-workflow-skills.md) #F:refactor/SKILL.md(1b)
- [README.md](README.md) #6-T7

Sources: `08-workflow-skills.md#6`, `08-workflow-skills.md#F:debug/SKILL.md(0c)`, `08-workflow-skills.md#F:refactor/SKILL.md(1b)`, `README.md#6-T7`

### W1-27 · [handoff] Collapse parse into Step 3; mktemp error file; emit SPINE; real exits
**Priority** High · **Effort** S · **Labels** Bug, Concurrency · **Ticket group** —

**Problem**
`commands/handoff.md` Step 1 (parse) and Step 3 are separate fences; Step 3 re-defaults `UUID="${UUID:-}"; WARM="${WARM:-0}"` (`:98`), so a bare `/handoff` becomes cold mode with an empty UUID and fails the shape check. `set -- $ARGUMENTS` (`:18`) word-splits and globs. `E="${TMPDIR:-/tmp}/handoff.err"` (`:102`) collides across sessions. The spawn prompt asks for `SPINE=…` (`:208`) that the parent never prints. Help/unknown flags exit 0, and only in prose. The UUID check (`:106`) accepts anything after 8 hex chars. Step 2 prose is garbled ("light skills/handoff/LIGHT.md"). Cache-hit/too-fresh messages differ from docs/commands/handoff.md L349, L407-411.

**Fix**
- Merge parse into the Step 3 fence; capture args via quoted heredoc.
- `E=$(mktemp)`; echo `SPINE=`; `exit 64` on unknown flag; full UUID regex; fix Step 2 prose; align doc strings.
- Keep the file ≤ 12000 B (SPEC-018 T39).

**Acceptance**
- detached-stub-test passes including size cap.
- Bare `/handoff` extracted block resolves warm mode.
- Unknown flag exits 64; doc and command strings match (grep test).

**Source**
- [02-commands-docs.md](02-commands-docs.md) #4
- [02-commands-docs.md](02-commands-docs.md) #F:commands/handoff.md
- [02-commands-docs.md](02-commands-docs.md) #F:docs/commands/handoff.md(strings)
- [README.md](README.md) #4.2
- [README.md](README.md) #4.4

Sources: `02-commands-docs.md#4`, `02-commands-docs.md#F:commands/handoff.md`, `02-commands-docs.md#F:docs/commands/handoff.md(strings)`, `README.md#4.2`, `README.md#4.4`

### W1-28 · [tdd-gate] Fix hook script shebang, matcher, fence type and arg handling
**Priority** High · **Effort** S · **Labels** Bug · **Ticket group** —

**Problem**
`commands/tdd-gate.md`: the hook body starts with a `_gc=…MROOT/WTROOT` preamble before `#!/usr/bin/env bash` (`:78-82`), so the written script's shebang is not on line 1 and the preamble is dead. The file content sits in a runnable-looking ```` ```bash ```` fence; if run, `INPUT=$(cat)` hangs. The settings JSON (`:229-238`) has no `matcher`, so python3 spawns on every tool call, while Notes `:275` say dedup is by matcher. No `argument-hint`, no unknown-arg handling. Description/`:248` say "blocks" though hits 1–2 are allowed; the docs' allowed list omits `*.sh`, `Makefile`, `Taskfile*`; `chmod +x .claude/hooks/…` (`:221`) depends on cwd.

**Fix**
- Remove the preamble; put the file in an `sh` fence labelled "file content — do not execute".
- Add `"matcher":"Write|Edit|MultiEdit"`, `argument-hint: "[on|off|status]"`, usage on unknown args.
- Fix wording and allowed list; chmod via `$WTROOT`-anchored path.

**Acceptance**
- Generated hook has shebang on line 1 (test).
- Settings entry includes matcher.
- Unknown arg prints usage.

**Source**
- [02-commands-docs.md](02-commands-docs.md) #5
- [02-commands-docs.md](02-commands-docs.md) #F:commands/tdd-gate.md

Sources: `02-commands-docs.md#5`, `02-commands-docs.md#F:commands/tdd-gate.md`

### W1-29 · [recall] Harden /recall: YAML hint, empty topic, shell/LIKE injection, caps
**Priority** High · **Effort** S · **Labels** Bug, Security · **Ticket group** —

**Problem**
`commands/recall.md`: `argument-hint: [topic]` (`:6`) is unquoted YAML and parses as a list; bare `/recall` greps `""` and matches everything; `$ARGUMENTS` goes straight into shell (`:41,87-138`) so quotes or `$()` break or inject; `$MROOT` unquoted (`:87,103,116,129`); LIKE wildcards `%`/`_` not escaped (`:74`); SQL `LIMIT 10` (`:77`) vs the "5 memory matches" rule (`:247`); `2>/dev/null` on grep instead of ls (`:138`). The docs page doesn't document empty-topic behavior.

**Fix**
- Quote the hint; bare invocation prints usage.
- Read the topic via quoted heredoc into `TOPIC`; `grep -F -- "$TOPIC"`; escape LIKE with `ESCAPE '\'`; quote paths; align caps; fix redirection.
- Document empty-topic behavior.

**Acceptance**
- Topic `$(touch X)` creates no file (test).
- `50%` topic matches literally.
- Frontmatter parses hint as a string.

**Source**
- [02-commands-docs.md](02-commands-docs.md) #6
- [02-commands-docs.md](02-commands-docs.md) #F:commands/recall.md
- [02-commands-docs.md](02-commands-docs.md) #F:docs/commands/recall.md
- [README.md](README.md) #4.4

Sources: `02-commands-docs.md#6`, `02-commands-docs.md#F:commands/recall.md`, `02-commands-docs.md#F:docs/commands/recall.md`, `README.md#4.4`

### W1-30 · [install] Reject unknown flags; make install/uninstall failure-safe
**Priority** High · **Effort** S · **Labels** Bug · **Ticket group** T4 setup-agents

**Problem**
`install.sh:30-36` silently ignores unknown flags, so `--dryrun` performs a real install; same in uninstall.sh. `install.sh:70-77` removes the previous install before the jq steps, so a later failure leaves a half-installed state; `:94` `jq … > tmp && mv` failing inside `&&` escapes `set -e` and leaves `opencode.json.tmp` (and opencode.json may be JSONC). `:240` `grep -v -E '^\s*(tools|model):'` strips matching lines anywhere in the body and uses GNU `\s`. `:11-12` duplicate comment. uninstall.sh `:4` says "removing symlinks" (agents are generated), leaves `--assign-models` pins pointing at removed agents, and has no opencode detection despite README:282.

**Fix**
- `*) echo "unknown flag $arg" >&2; exit 64 ;;` in both scripts.
- Validate/parse config (reject JSONC with a clear message) before `rm -rf`; `trap` to clean `.tmp`; explicit error checks around jq.
- Strip only frontmatter lines with `[[:space:]]`; uninstall removes pins and detects opencode.

**Acceptance**
- install-test: `--dryrun` exits 64 with no changes.
- Simulated jq failure leaves the previous install intact.
- Uninstall removes pins.

**Source**
- [01-agents-infra.md](01-agents-infra.md) #8
- [01-agents-infra.md](01-agents-infra.md) #F:install.sh(2-5,7)
- [01-agents-infra.md](01-agents-infra.md) #F:uninstall.sh

Sources: `01-agents-infra.md#8`, `01-agents-infra.md#F:install.sh(2-5,7)`, `01-agents-infra.md#F:uninstall.sh`

### W1-31 · [security] Narrow Bash allowlists seeded by `/setup team` and `/setup project`
**Priority** High · **Effort** S · **Labels** Security · **Ticket group** —

**Problem**
`agents/project-init.md:50` seeds `Bash(*)` + `acceptEdits` without a sandbox on the non-orchestration `/setup team` path, while AGENTS.md:267 justifies `Bash(*)` with "the sandbox is the boundary" and README:245 says "`rm` still prompts" — both false after setup. `skills/scaffold-project/SKILL.md:159` claims destructive commands are excluded, yet the committed `acceptEdits` settings allow `Bash(python3:*)`, `node:*`, `npx:*`, `for :*`, `{:*`, `git:*` (push --force, clean -fdx), `find:*` (-delete), `curl:*` — effectively `Bash(*)`.

**Fix**
- `/setup team`: seed the curated `/setup project` allowlist, or add `Bash(*)` only when sandbox markers are present.
- scaffold: drop interpreters, `git:*`, `curl:*` from defaults (narrow git to status/diff/log/add/commit); rewrite :159 honestly.
- Fix AGENTS.md:267 and README:245.

**Acceptance**
- Generated settings in a temp project contain no `Bash(*)` without sandbox.
- Scaffolded allowlist has no interpreter or `git:*` wildcard.
- AGENTS.md and README statements match behavior.

**Source**
- [01-agents-infra.md](01-agents-infra.md) #7
- [01-agents-infra.md](01-agents-infra.md) #F:agents/project-init.md(5)
- [01-agents-infra.md](01-agents-infra.md) #cross-5
- [08-workflow-skills.md](08-workflow-skills.md) #13
- [08-workflow-skills.md](08-workflow-skills.md) #F:scaffold-project/SKILL.md
- [README.md](README.md) #P1-bash-star

Sources: `01-agents-infra.md#7`, `01-agents-infra.md#F:agents/project-init.md(5)`, `01-agents-infra.md#cross-5`, `08-workflow-skills.md#13`, `08-workflow-skills.md#F:scaffold-project/SKILL.md`, `README.md#P1-bash-star`
