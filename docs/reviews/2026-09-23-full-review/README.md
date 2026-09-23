# Full project review and enhancement proposal — 2026-09-23

**Scope:** every tracked file at `60777e7` (v1.18.14): 542 files, about 128k lines. That covers 20 commands, 41 skills, 12 agents, 38 specs, docs, tools, CI and manifests.
**Method:** ten parallel read-only reviewers, one per subsystem slice. Each reviewer read every file in its slice in full and wrote one table row per file. Each P0 and each headline P1 was then checked against the source by the lead reviewer (column **✓** below).
All 10 CI gates and all 70 test scripts that CI does not run were executed. The results are in [`test-results.md`](test-results.md).

| Document | Content |
|---|---|
| this file | Scorecard, verified top findings, systemic root causes, and a phased enhancement roadmap |
| [`coverage.md`](coverage.md) | File-by-file manifest: 542 of 542 files, each assigned to exactly one slice |
| [`test-results.md`](test-results.md) | Raw results for the CI gates and every test CI does not run |
| [`slices/01-handoff.md`](slices/01-handoff.md) … [`slices/10-core-rest.md`](slices/10-core-rest.md) | Per-file review tables, all findings with file:line and evidence, and per-subsystem enhancement proposals |

---

## 1. Scorecard

| # | Slice | Files | Grade | P0 | P1 | Headline |
|---|---|---:|:---:|---:|---:|---|
| 01 | `/handoff` | 74 | **B-** | 0 | 2 | Deterministic engine is solid. The miner prompt has no concrete finalize contract, and the stub is over its size cap. |
| 02 | Specs (SPEC-001…037, TDD.md) | 38 | **C** | 0 | 4 | Code mostly matches the specs, but spec status and cross-references have drifted and nothing lints them. |
| 03 | `/council` | 79 | **C** | 0 | 9 | Judge output is not validated. Phase 7 is documented but not implemented. Workflow Borda scoring is mis-attributed. |
| 04 | Transcript mirror / parse | 39 | **C** | 0 | 2 | The recorder exceeds its 10 s hook timeout on real sessions, and bare `/compact-transcript` cannot succeed on the live session. |
| 05 | Autopilot + `/epic` | 18 | **C** | 1 | 3 | A failed seal runs `git clean -fd` on the main checkout. |
| 06 | Orchestrate / kickoff / wrap / review-and-commit / init-orchestration | 47 | **C+** | 0 | 7 | Task-graph key mismatch. Gate hooks fail open without `timeout`. |
| 07 | Persistent memory | 33 | **D+** | 1 | 8 | The lembed API call is wrong, so local semantic search never works. Distill and validate are broken. |
| 08 | doctor / bug-hunt / debug / retro | 53 | **C+** | 0 | 2 | Scheduled `/retro` lock and report helper don't survive across fences. The debug reopen gate is a silent no-op. |
| 09 | Release, train, backlog, lint, tooling | 86 | **C+** | 0 | 7 | Backlog reconcile loses data. The train `restore` hard-resets blindly. Gates have false negatives. |
| 10 | Core (root, agents, install, libs, docs) | 75 | **C+** | 1 | 2 | `/setup team` looks for memory scripts in the wrong directory. `plugin-dir.sh` lets the user's repo shadow plugin scripts. |
| | **Total** | **542** | **C** | **3** | **46** | about 110 P2 and about 90 P3 findings in the slice reports |

**Overall.** The helper scripts are generally well engineered: atomic writes, fail-closed CLIs and many bite-tests. Most defects are in the **LLM-facing markdown**:
- bash fences that assume shell state from another fence;
- lint waivers pasted into the middle of commands;
- huge copy-pasted boilerplate.

Most defects also sit in **places CI never executes**: 70 of 80 test scripts, the fenced bash inside commands and skills, and macOS.

### Per-surface verdicts (every command, skill and agent)

`OK` means no findings. `Minor` means cosmetic or docs-only. `Issue` means a real defect with limited blast radius. `Major` means a core feature is broken or data can be lost.

| Surface | Kind | Slice | Verdict |
|---|---|---|---|
| `council-judge` (`agents/council-judge.md`) | agent | 03 | Minor |
| `debugger` (`agents/debugger.md`) | agent | 08 | Minor |
| `devops` (`agents/devops.md`) | agent | 10 | OK |
| `distiller` (`agents/distiller.md`) | agent | 07 | Minor |
| `ds` (`agents/ds.md`) | agent | 10 | OK |
| `finder` (`agents/finder.md`) | agent | 03 | Minor |
| `ic4` (`agents/ic4.md`) | agent | 10 | Minor |
| `ic5` (`agents/ic5.md`) | agent | 10 | Minor |
| `pm` (`agents/pm.md`) | agent | 10 | Minor |
| `project-init` (`agents/project-init.md`) | agent | 07 | Issue |
| `qa` (`agents/qa.md`) | agent | 10 | OK |
| `tech-lead` (`agents/tech-lead.md`) | agent | 10 | OK |
| `adjust-agent` (`commands/adjust-agent.md`) | command | 07 | Minor |
| `audit` (`commands/audit.md`) | command | 09 | Minor |
| `bug-hunt` (`commands/bug-hunt.md`) | command | 08 | OK |
| `compact-transcript` (`commands/compact-transcript.md`) | command | 04 | Issue |
| `council` (`commands/council.md`) | command | 03 | **Major** |
| `craft-loop` (`commands/craft-loop.md`) | command | 10 | OK |
| `debug` (`commands/debug.md`) | command | 08 | Minor |
| `doctor` (`commands/doctor.md`) | command | 08 | Minor |
| `epic` (`commands/epic.md`) | command | 05 | Issue |
| `handoff` (`commands/handoff.md`) | command | 01 | Issue |
| `memory` (`commands/memory.md`) | command | 07 | **Major** |
| `mode` (`commands/mode.md`) | command | 10 | Minor |
| `recall` (`commands/recall.md`) | command | 07 | Minor |
| `release-train` (`commands/release-train.md`) | command | 09 | Minor |
| `retro` (`commands/retro.md`) | command | 08 | **Major** |
| `setup` (`commands/setup.md`) | command | 10 | **Major** |
| `spec` (`commands/spec.md`) | command | 09 | Issue |
| `status` (`commands/status.md`) | command | 10 | Minor |
| `tdd-gate` (`commands/tdd-gate.md`) | command | 10 | Issue |
| `worktree` (`commands/worktree.md`) | command | 10 | Minor |
| `audit` (`skills/audit/SKILL.md`) | skill | 09 | Minor |
| `autopilot` (`skills/autopilot/SKILL.md`) | skill | 05 | Issue |
| `backlog` (`skills/backlog/SKILL.md`) | skill | 09 | Issue |
| `blunt` (`skills/blunt/SKILL.md`) | skill | 10 | Minor |
| `brainstorm` (`skills/brainstorm/SKILL.md`) | skill | 10 | Issue |
| `bug-hunt` (`skills/bug-hunt/SKILL.md`) | skill | 08 | Issue |
| `ci-watch` (`skills/ci-watch/SKILL.md`) | skill | 09 | Issue |
| `code-simplify` (`skills/code-simplify/SKILL.md`) | skill | 10 | Minor |
| `council` (`skills/council/SKILL.md`) | skill | 03 | **Major** |
| `craft-loop` (`skills/craft-loop/SKILL.md`) | skill | 10 | OK |
| `debug` (`skills/debug/SKILL.md`) | skill | 08 | Issue |
| `docs-drift` (`skills/docs-drift/SKILL.md`) | skill | 09 | Minor |
| `doctor` (`skills/doctor/SKILL.md`) | skill | 08 | Minor |
| `domain-glossary` (`skills/domain-glossary/SKILL.md`) | skill | 10 | Minor |
| `epic` (`skills/epic/SKILL.md`) | skill | 05 | Issue |
| `fix-ticket` (`skills/fix-ticket/SKILL.md`) | skill | 06 | Issue |
| `focus` (`skills/focus/SKILL.md`) | skill | 10 | Minor |
| `handoff` (`skills/handoff/SKILL.md`) | skill | 01 | Issue |
| `init-orchestration` (`skills/init-orchestration/SKILL.md`) | skill | 06 | **Major** |
| `kickoff` (`skills/kickoff/SKILL.md`) | skill | 06 | **Major** |
| `memory-compress` (`skills/memory-compress/SKILL.md`) | skill | 07 | Minor |
| `memory-recall` (`skills/memory-recall/SKILL.md`) | skill | 07 | **Major** |
| `memory-store` (`skills/memory-store/SKILL.md`) | skill | 07 | Issue |
| `metrics` (`skills/metrics/SKILL.md`) | skill | 09 | OK |
| `model-map` (`skills/model-map/SKILL.md`) | skill | 09 | Minor |
| `orchestrate` (`skills/orchestrate/SKILL.md`) | skill | 06 | OK |
| `refactor` (`skills/refactor/SKILL.md`) | skill | 10 | Issue |
| `release-train` (`skills/release-train/SKILL.md`) | skill | 09 | Issue |
| `release` (`skills/release/SKILL.md`) | skill | 09 | Issue |
| `retro-gate` (`skills/retro-gate/SKILL.md`) | skill | 08 | Issue |
| `retro-subagent` (`skills/retro-subagent/SKILL.md`) | skill | 08 | Minor |
| `review-and-commit` (`skills/review-and-commit/SKILL.md`) | skill | 06 | **Major** |
| `scaffold-project` (`skills/scaffold-project/SKILL.md`) | skill | 10 | Issue |
| `security-scan` (`skills/security-scan/SKILL.md`) | skill | 09 | Minor |
| `skill-lint` (`skills/skill-lint/SKILL.md`) | skill | 09 | OK |
| `spec-tooling` (`skills/spec-tooling/SKILL.md`) | skill | 09 | Issue |
| `standup` (`skills/standup/SKILL.md`) | skill | 10 | Minor |
| `transcript-mirror` (`skills/transcript-mirror/SKILL.md`) | skill | 04 | Minor |
| `transcript-parse` (`skills/transcript-parse/SKILL.md`) | skill | 04 | Minor |
| `validate-memory` (`skills/validate-memory/SKILL.md`) | skill | 07 | Issue |
| `wrap-ticket` (`skills/wrap-ticket/SKILL.md`) | skill | 06 | Issue |
| `agent-memory` (`skills/agent-memory/`, no SKILL.md) | skill-dir | 07 | Issue/Minor |
| `notify` (`skills/notify/`, no SKILL.md) | skill-dir | 09 | Minor/OK |

Every supporting file (scripts, tests, fixtures, templates, prompts, specs, docs) has its own row in the slice reports. See [`coverage.md`](coverage.md) for the mapping.

---

## 2. Test and CI status (measured)

| Set | Scripts | Pass | Fail | Notes |
|---|---:|---:|---:|---|
| CI-wired gates (`smoke.yml`) | 10 | 9 | 1 | `test-seed-pack.sh` failed here only because `sqlite3` was not installed. The slice-07 reviewer installed it and got 114/0. |
| Test scripts **not** in CI | 70 | 62 | 8 | See the breakdown below. |
| skill-lint | 1 | pass | – | **299 of 299 findings are waived**: 221 × C3, 118 × C1, 10 × C5. |

The 8 failures CI never sees:

| Script | Cause | Class |
|---|---|---|
| `handoff/detached-stub-test.sh` | `commands/handoff.md` is 12096 B; SPEC-018 caps it at 12000. Introduced by v1.18.14. | **real drift** |
| `orchestrate/router-static-test.sh` | T10 fails on `steps/02-scope.md:6`. Red since v1.17.0. | **real drift** |
| `retro-gate/scheduled-retro-test.sh` | The grep for "Filter 2" no longer matches `commands/retro.md`. | **stale test** |
| `retro-gate/friction-capture-test.sh` | Needs `.claude/hooks/friction-capture.sh`, which is gitignored and only generated by `/setup orchestration`. | **non-hermetic test** |
| `release-train/test-integration.sh` | Passes only if the developer's global gitignore hides `.claude/`. | **non-hermetic test** |
| `council/test-workflow-static.sh` | Exits 1 silently under `set -e` when `CLAUDE_CODE_VERSION` is set: the unforced probe returns non-zero and no FAIL line is printed. | **non-hermetic test** |
| `metrics/test.sh` (T4) | `chmod 555` does not block writes for root. | env (root) |
| `transcript-mirror/test.sh` (M4) | `chmod a-w` does not block writes for root. | env (root) |

---

## 3. Verified top findings (P0 and headline P1)

✓ means the lead reviewer re-read the cited lines and confirmed the defect. R means the slice reviewer reproduced it by running code.

| ID | Sev | ✓ | Finding | Where | Fix |
|---|---|---|---|---|---|
| T-1 | **P0** | ✓ R | **A failed epic seal deletes untracked user files.** The dirty gate uses `git diff` and `git diff --cached`, which ignore untracked files. The failure and abort paths then run `git clean -fd` on the **main checkout**. The skill also recommends `seal --abort --force` for routine recovery. | `skills/epic/epic-lib.sh:979-983, 1147-1150` | Gate on `git status --porcelain` including untracked files. Drop `clean -fd`, or restrict it to paths the squash staged (`git diff --name-only --diff-filter=A` before and after). Add a test with an untracked file. |
| T-2 | **P0** | ✓ | **`/setup team` cannot initialise SQLite memory.** It sets `PLUGIN_DIR="$PDH"` (the plugin root) and then reads `$PLUGIN_DIR/schema.sql`, `migrate.sh`, `download-extensions.sh` and `migrate-md.sh`. Those files live in `skills/memory-store/`. | `commands/setup.md:232-334` | `PLUGIN_DIR="$PDH/skills/memory-store"`, or resolve each file via `plugin-dir.sh file skills/memory-store/…`. Add a fence-execution test. |
| T-3 | **P0** | ✓ R | **Local semantic search never works.** `lembed('<path.gguf>', …)` passes a file path, but sqlite-lembed needs a model **name** registered through `lembed_models`. Errors go to `/dev/null`, so no vectors are ever stored or queried. | `skills/memory-store/embed-one.sh:56-59`, `memory-recall/SKILL.md:121`, `migrate-md.sh:234` | `INSERT INTO temp.lembed_models(name, model) SELECT 'mini', lembed_model_from_file(:path)`, then `lembed('mini', …)`. Stop sending errors to `/dev/null`. Add an embedding smoke test in CI. |
| T-4 | P1 | ✓ | **SQLite memory is silently skipped** wherever a fence sets `MEMDB="$MROOT/…"` before it sets `MROOT`. MEMDB then becomes `/.claude/memory/memory.db`, the file doesn't exist, and the fence takes the `.md` fallback. **The AGENTS.md canonical snippet has the same ordering bug**: it tests `$MEMDB` before defining it. | 12 sites in 7 files: `AGENTS.md:153`, `commands/setup.md:272,329`, `skills/brainstorm:64,83`, `kickoff:121,140,159`, `memory-recall:203`, `orchestrate/steps/00-resolve.md:66`, `wrap-ticket:196,230` | Reorder. Add skill-lint rule **C6**: assign-before-use within a fence for `MROOT`, `WTROOT`, `MEMDB` and `PLUGIN_DIR`. |
| T-5 | P1 | ✓ | **Lint waivers break code.** A trailing `# lint-ok: C1` after `\` ends the command, so the rest of the command runs as a separate line (exit 127). Inside a SQL string the comment becomes a SQL parse error, so distill without `--agent` finds no agents and `validate --deep` fails. | continuation: `review-and-commit/SKILL.md:207`, `commands/council.md:1042`, `memory-recall/SKILL.md:106`; SQL: `commands/memory.md:413,1426,1516` | Move waivers to their own line above the command. skill-lint should reject `\ # lint-ok` and `lint-ok` inside quotes. |
| T-6 | P1 | ✓ R | **`plugin-dir.sh` lets the user's repo shadow plugin scripts.** Tier 1 (worktree) and tier 2 (main checkout) come before the plugin install. A consumer repo that contains `skills/worktree-lib.sh` gets that file executed by `/worktree`, `/status` and `/setup`. | `skills/plugin-dir.sh:178-192` | Accept the cwd tiers only when the root is the dev-team plugin, e.g. `.claude-plugin/plugin.json` with `"name":"dev-team"`. Otherwise go straight to the install tiers. |
| T-7 | P1 | ✓ | **Transcript recorder exceeds its hook timeout.** It spawns `jq` once or twice per line and re-hashes the whole file on every Stop. The measured time was 9.8 s for a 1-line delta on a 2k-line transcript, against `"timeout": 10`. | `skills/transcript-mirror/transcript-mirror.sh:35-60,601`, `SKILL.md:47` | Use a byte-offset cursor (`tail -c +N`) and one python pass per tick. |
| T-8 | P1 | ✓ | **`/retro --all --auto` scheduled path.** The lock's `trap … EXIT` fires when its own fence exits, and `write_scheduled_report_if_needed` is called from fences where it isn't defined. Separately, `grep -c … \|\| echo 0` prints `0\n0`. | `commands/retro.md:150,157,465,473,591` | Move the lock and report steps into a `retro-report.sh` subprocess CLI. Replace `grep -c … \|\| echo 0` with `grep -c … \|\| true`. |
| T-9 | P1 | ✓ | **Council judge output is not validated.** Unknown verdicts pass through (`.get(verd, verd)`), confidence is not range-checked, and an empty `evidence_blob` is accepted. The task gate also uses max confidence regardless of the verdict, so FABRICATED@95 passes. | `skills/council/engine.sh:1007-1031` | Add a `validate_judge` step to finalize, and make the gate verdict-aware (spec change to SPEC-002/013). |
| T-10 | P1 | ✓ | **The release-train `restore` blindly runs `git reset --hard <base>`** after any `/release` failure, even one that already committed, tagged or pushed. | `skills/release-train/train-lib.sh:772-792` | Reset only when HEAD has no new tag and is not an ancestor of `origin/master`. Otherwise halt and print recovery steps. |
| T-11 | P1 | ✓ | **SPEC-028 is DEPRECATED but still marked authoritative** for `/debug ticket`, and it is wrong: it names ic5 instead of `debugger` and requires the deleted `commands/fix-ticket.md`. | `specs/core/SPEC-028-*.md` header | Fold the live MUSTs into SPEC-014 and archive SPEC-028. |
| T-12 | P1 | R | **Task-graph key mismatch.** Dependencies are keyed by plan ordinal (`<ID>-N`); task files are keyed by the TaskCreate id. Dependents never become ready unless the ids happen to line up. | `skills/orchestrate/steps/07-tasks.md:11,101`, `kickoff/SKILL.md:778-789` | Store `plan_ordinal` in `task-store.sh create` and key the DAG on it. |
| T-13 | P1 | R | **Gate hooks fail open on stock macOS.** The generated `task-completed.sh` reads stdin with `timeout 1 cat`; without `timeout` the hook exits 0 and the council gate never runs. | `skills/init-orchestration/SKILL.md:718` | Use `read -t` or a python stdin read, and fail closed. |
| T-14 | P1 | R | **Backlog data loss.** `reconcile.sh` drops headings, sub-bullets and sections after `## Completed` while reporting "applied 0". `close.sh` duplicates `## Completed` when it is the last line, which is the `/backlog init` default. | `skills/backlog/reconcile.sh:250-281`, `close.sh:327-343` | Make edits line-preserving (only touch matched rows) and add fixture round-trip tests. |
| T-15 | P1 | R | **Autopilot end-state runs `git reset --hard` on the main repo** after a squash conflict, with no check that the tree was clean first. | `skills/autopilot/end-state.md` §4 | Refuse when the tree is dirty, or stash first. |

The remaining P1s are in the slice reports. The major ones:
- council `--blind` in worktrees, Borda mis-attribution, tier-grade signal 4 (03);
- memory distill lock self-deadlock, validation score cap, `migrate-md` data loss (07);
- `/debug` reopen gate no-op on installs (08);
- `/handoff` finalize contract (01);
- the `/epic --autopilot` contract contradicting itself (05);
- bump-class gate false negatives (09, P2 once verified: it bites only when `plugin.json` is bumped but not staged).

---

## 4. Systemic root causes

The ~250 findings reduce to seven causes. Fixing the causes is cheaper than fixing the findings one by one.

1. **Fenced bash in LLM-facing markdown is never executed by any test.**
   The helper `.sh` and `.py` files have good tests. The ```bash fences in commands and skills, where T-2, T-4, T-5 and T-8 live, have none. Each fence runs in a fresh shell, yet many fences assume variables, functions or traps from an earlier fence.
   *Fix:* a **fence-exec harness** that extracts fences by heading, substitutes placeholders and runs them against fixtures. Also move multi-fence logic into subprocess CLIs, the pattern `/bug-hunt` and `/debug` already follow.
2. **CI runs 10 of 80 test scripts.**
   Two gates are currently red on master and CI cannot see them (§2).
   *Fix:* one `tools/run-all-tests.sh` that discovers every `*test*.sh`, with an explicit quarantine list for environment-only failures, wired into `smoke.yml`.
3. **No macOS or bash 3.2 lane, although the docs target macOS** (`docs/setup.md` uses brew).
   `flock`, `declare -A`, `mapfile`, `local -n`, `${x,,}`, `timeout`, `grep -P`, `sha256sum`, `touch -d` and `find -printf` break `/epic`, `/orchestrate` DAG, council finalize, the task store, `ci-watch`, the seed-pack export and several hooks. Some of these fail *open*.
   *Fix:* a `skills/lib/portable.sh` shim (sha256, mkdir-lock, timeout), a `macos-latest` CI matrix entry, and a skill-lint rule for bash-4-only constructs.
4. **Boilerplate instead of shared resolution.**
   - The 844-byte PDH stanza appears **220 times in 57 files**, about 44k tokens repo-wide and about 26% of `skills/epic/SKILL.md`.
   - It accounts for 206 of the 221 C3 waivers.
   - The model-map block is copied about 20 times.
   - `LIGHT.md` is 85% a copy of `handoff/SKILL.md`.
   - `docs/commands/transcript-mirror.md` repeats about 150 lines of its SKILL.md.

   *Fix:* resolve PDH once per skill (Step 0), then refer to it by name. Rely on the literal `${CLAUDE_PLUGIN_ROOT}` substitution that v1.18.14 found works. Shared partials go through the existing `sync-includes` mechanism.
5. **Token cost of monolithic skills.**
   `bug-hunt/SKILL.md` is 3,391 lines (about 34k tokens) and `init-orchestration` 2,157. `retro.md` (1,967), `memory.md` (1,795), `council.md` (1,385), `epic` (1,277, about 20k tokens) and `refactor` (about 50 KB) follow. Each loads in full on every invocation.
   *Fix:* a router plus per-stage step files, as `/orchestrate steps/*.md` already does. Hook bodies move to real `.sh` files. Ticket archaeology (`CDT-xxx` provenance) moves out of the prompts into CHANGELOG and specs.
6. **Lint-by-waiver.**
   All 299 skill-lint findings are waived, the waiver comments themselves break code (T-5), and reviewers can no longer see real hits.
   *Fix:* auto-exempt the byte-exact canonical stanza from C3, and forbid inline waivers after `\` or inside quotes. Add C6 (assign-before-use) and C7 (bash-4-only constructs).
7. **Spec drift with no spec lint.**
   - Five shipped specs are still DRAFT, and the index and file status disagree for SPEC-035.
   - About 30 cited paths no longer exist.
   - Every "SPEC-013 line N" citation is stale.
   - A deprecated spec is still marked authoritative.

   *Fix:* a `spec-lint` CI job covering `check-format.sh`, index↔status parity, Covers paths existing, version-history order and a ban on `SPEC-\d+ line \d+`.

Also cross-cutting:
- **Project-dir encoding** (`s|/|-|g`) is wrong wherever a path contains `.` or `_`, which includes every `.worktrees/<slug>`. Two slices found it independently (`handoff/discover-warm.sh:409`, `transcript-parse/hosts.py`). Fix it once with a single `hosts.py encode-project`.
- **Several arg parsers hang forever on a trailing flag with no value** (`shift 2`): four orchestrate helpers and three retro-gate CLIs. Fix with one shared `need_arg` helper and a lint rule.

---

## 5. Enhancement proposal — phased roadmap

Effort key: S = under 1 day, M = 1–3 days, L = more than 3 days. The versioning notes follow the AGENTS.md rules.

### Phase 0 — Stop the bleeding (patch releases, about 2–3 days)

| # | Item | Fixes | Effort |
|---|---|---|---|
| 0.1 | Seal safety: untracked-aware dirty gate, no `clean -fd` on the main checkout; autopilot end-state clean-tree precondition | T-1, T-15 | S |
| 0.2 | `/setup team` memory-store paths | T-2 | S |
| 0.3 | sqlite-lembed model registration; stop sending embed errors to `/dev/null` | T-3 | S |
| 0.4 | Reorder MEMDB/MROOT in all 12 sites, AGENTS.md first | T-4 | S |
| 0.5 | Move the 6 code-breaking waivers onto their own lines | T-5 | S |
| 0.6 | `plugin-dir.sh`: cwd tiers accepted only for the dev-team plugin identity | T-6 | S |
| 0.7 | Get `handoff.md` under 12000 B (e.g. replace `jq` with a python helper, which also removes an undeclared dependency); fix router T10 | red gates | S |
| 0.8 | Backlog reconcile/close line-preserving edits; train `restore` safety | T-10, T-14 | M |
| 0.9 | Fail-closed hook stdin read; `task-completed.sh` without `timeout` | T-13 | S |

### Phase 1 — Make CI see what's broken (patch, about 2 days)

| # | Item | Effort | Impact |
|---|---|---|---|
| 1.1 | `tools/run-all-tests.sh`: discover and run all `*test*.sh`; quarantine file with a reason per entry; wire into `smoke.yml` | S | Surfaces the 8 hidden failures and guards about 3,000 existing assertions |
| 1.2 | Make the 5 non-hermetic tests hermetic: temp `HOME` and `MROOT`, `env -u CLAUDE_CODE_VERSION`, skip permission tests when `uid=0` | S | Green baseline |
| 1.3 | `macos-latest` matrix entry for the portable subset (then everything, as Phase 3 lands) | S | Catches the class-3 root cause |
| 1.4 | **Fence-exec harness** (`tools/fence-exec/`): extract ```bash fences per heading, stub placeholders, run under `bash -n` plus an assign-before-use check, and run selected fences against fixtures | M | Covers the class-1 root cause; would have caught T-2, T-4, T-5 and T-8 |
| 1.5 | `spec-lint` job (format, status parity, Covers existence, no line-number citations) | M | Covers the class-7 root cause |
| 1.6 | CI hygiene: `permissions: contents: read`, `timeout-minutes`, `bump-class` across the PR range instead of HEAD only | S | Hardening |

### Phase 2 — Correctness of flagship features (minor release, about 1–2 weeks)

| # | Item | Slice | Effort |
|---|---|---|---|
| 2.1 | Council: `validate_judge` plus a verdict-aware gate (spec change); fix workflow.js Borda label mapping; no fabricated self-verify bundles; use a tool-capable skeptic in Phase 2; implement or formally defer Phase 7; `--blind` via `WTROOT` | 03 | M |
| 2.2 | Memory: `memdb.sh` subprocess CLI with parameterized python sqlite (removes string-interpolated SQL); bounded tier-0 tail after distill; rescale validation scoring; non-destructive `migrate-md`; python reconcile candidate generation; TTL on the distill lock | 07 | L |
| 2.3 | Transcript: byte-offset incremental recorder; status-aware `/compact-transcript` default (SPEC-036 M14 change); `umask 077`; lock plus `.bak` cleanup; installer helper | 04 | M |
| 2.4 | Orchestrate/kickoff: unified task identity (`plan_ordinal`); dag-lib as pure jq; resolve the kickoff↔orchestrate Steps 4–7 drift | 06 | M |
| 2.5 | `/retro`: extract Steps 2–6 into `retro-discover.sh`, `retro-classify.py` and `retro-report.sh`; `/debug` reopen gate resolved through `plugin-dir.sh` | 08 | M |
| 2.6 | `/handoff`: a copy-verbatim finalize block; sanitize newlines in `assemble.py` so event text can't forge sections | 01 | S |
| 2.7 | `/epic`: reconcile the `--autopilot` contract across `commands/epic.md`, SKILL, SPEC-033 and autopilot; an exact-ticket plan resolver shared by resume, kickoff and orchestrate | 05 | S |

### Phase 3 — Portability (patch or minor, about 1 week)

- `skills/lib/portable.sh`: `sha256` via `sha256sum` or `shasum -a 256`; a `mkdir`-based lock instead of `flock`; `timeout` via a perl or python fallback.
- Remove `declare -A`, `mapfile`, `local -n`, `${,,}` and `${a[-1]}` from `epic-lib`, `dag-lib`, `index-writer`, `reconcile`, `check-ship-history`, `security-scan` and the hooks.
- New skill-lint rule **C7**: flag bash-4-only constructs in any file that ships to consumers.
- `epic-lib doctor` and `/doctor` checks for the required tools, with clear messages.

### Phase 4 — Token and maintainability diet (minor, about 2 weeks, measurable)

| # | Item | Estimated saving |
|---|---|---|
| 4.1 | Resolve PDH once per skill or command and drop the other copies; auto-exempt the canonical stanza from C3 (removes about 206 waivers) | about 35–40k tokens repo-wide; about 5k per `/epic` run |
| 4.2 | Split `bug-hunt`, `epic`, `council`, `retro`, `memory`, `spec-tooling` and `refactor` into router plus stage files; enforce router ≤ 150 lines with a test | 40–70% less loaded per invocation |
| 4.3 | Move `init-orchestration` hook bodies into real `skills/init-orchestration/hooks/*.sh` (shellcheck-able) | SKILL shrinks from 2,157 to about 900 lines |
| 4.4 | Shared partials via `sync-includes`: model-map spawn fence, autopilot envelope, handoff miner prompt (shared by SKILL and LIGHT) | about 10k tokens; one source of truth |
| 4.5 | Move ticket archaeology (`CDT-xxx`, clause codes, dated measurements) out of prompts and specs into CHANGELOG and `docs/adr/` | prompt clarity; about 10–15% per large skill |
| 4.6 | Shared test libs (`assert_*`, arg-parse `need_arg`) per subsystem | less test drift |
| 4.7 | Archive deprecated specs (SPEC-019, 027, 028) under `specs/archive/`; promote shipped DRAFTs | spec clarity |

### Phase 5 — Product and UX enhancements

- **`user-invocable: false`** on internal skills (`memory-store`, `memory-recall`, `agent-memory`, `transcript-parse`, `model-map`, …). Also retire `/focus` and `/blunt` as their deprecation notices promise. Add a docs-drift rule that user-invocable skills equal the README index.
- **Generate** the `install.sh` opencode tier map and the `SECURITY.md` supported-version line from the source of truth: agent frontmatter and `plugin.json`.
- **Docs and settings consistency.** Remove the `dontAsk`/Cell C wording where Cell D (`auto`) ships. Fix the scaffold `.gitignore` so it stops ignoring the committable seed pack. Correct the allowlist claims in scaffold.
- **Worktree lib.** Add `release --keep-branch`, warn about unmerged commits, and add no-TTY tests.
- **Glossary and hand-back block** in the 7 behavioral agents: load CONTEXT.md, and return results as the final message rather than via SendMessage.
- **Observability.** `/doctor` reports the embedding mode, whether a vector round-trip actually works, the hook timeout budget against the transcript size, and the lint-waiver count trend.

### Suggested sequencing

Phase 0 and Phase 1 go first, together, so every fix lands with a test CI actually runs. Phase 2 and Phase 3 can run in parallel as separate epics. Phase 4 comes after Phase 1.4, so the fence harness guards the large prompt refactors. Phase 5 is opportunistic.

---

## 6. What is working well (keep)

- Fail-closed CLIs with exit-code contracts: `sync-includes`, `plugin-dir.sh`, `check-staged-paths.sh` and the handoff `prepass.sh`.
- Atomic index writes, `tool_use_id` strikes and a deterministic tier grader in council.
- Strong bite-test culture where tests exist: plugin-dir 189 assertions, epic 745, autopilot 311, handoff about 500, retro-gate, and prune-remote 61.
- Consistent manifests. CHANGELOG has 364 entries, strictly ordered and in sync with `plugin.json`, and the agent tier table matches all 12 frontmatters.
- Explicit ship/land rules and a bump-class gate.

---

## 7. Housekeeping from this review

Review test runs left gitignored artifacts in the working tree, none of them tracked:
- `.claude/retro/anchors/a1b2c3d4e5f60718.json`
- `.claude/council/2026-09-23-claim.md` and its `.finalize-meta.json`

Delete them locally if desired. Their existence is itself a hermeticity finding: tests write into the repo's own `.claude/`.
