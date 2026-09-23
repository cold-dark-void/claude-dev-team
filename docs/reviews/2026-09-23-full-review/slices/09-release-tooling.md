# Slice 09 — Release & tooling review

Reviewer slice: release, release-train, model-map, backlog, metrics, ci-watch, audit, docs-drift, skill-lint, spec-tooling, security-scan, notify (86 files). I read every file in full. The repo was not modified: `git status --porcelain` was empty after all test runs.

## Slice summary

- **What it does.** This slice is the plugin's release pipeline and its supporting engines:
  - `/release`, with its deterministic gates: bump-class, staged-paths and ship-history.
  - `/release-train`, a multi-branch queue that lands each branch through `/release`.
  - Mechanical gates for skill-lint (SPEC-021), docs-drift (SPEC-010 D1–D10) and spec format (`check-format.sh`).
  - Subprocess CLIs for the backlog (close / reconcile), ci-watch (cron poller plus sidecar), the model map, the metrics ledgers, `/audit` and the webhook notify sink.
  - The `/spec` lifecycle surface.
- **Overall grade: C+.** The design discipline is strong: every engine is a subprocess CLI with defined exit codes, tests run in temp repos, gates fail closed, and the vacuity guard is explicit. Most bugs are in edge paths. However, several confirmed defects destroy or duplicate user data. The engines also depend on GNU/bash-4 features on a platform whose docs target macOS.
- **Test results (all run):**
  - 18 of 20 harnesses pass.
  - `skills/release-train/test-integration.sh` **fails** (2 failures). It depends on the developer's global gitignore.
  - `skills/metrics/test.sh` **fails** (1 failure, test 4) when run as root.
  - Current state: skill-lint shows `299 findings, 299 waived`; docs-drift shows `0 findings, 0 waived`; `bash -n` passes on all slice scripts.
- **Biggest risk 1 — silent data loss or corruption in the backlog engine.**
  - `reconcile.sh` drops every non-row line of the index (group headings, sub-notes, trailing sections) and reports `applied 0 action(s)`.
  - `close.sh` duplicates `## Completed` headers and rows when the index ends with `## Completed`. That is exactly the layout `/backlog init` creates.
- **Biggest risk 2 — the release-train restore path.** `restore` runs `git reset --hard <base>` with no check of whether `/release` already made the fold commit, tag or push. It can orphan a local tag or rewind master behind origin.
- **Biggest risk 3 — portability of fail-open and fail-closed engines.**
  - `flock`: `ci-watch/sidecar.sh`, `model-map/write-model.sh`.
  - `declare -A`: `reconcile.sh`, `check-ship-history.sh`.
  - `mapfile`: `security-scan/scan.sh`.
  - GNU `timeout`: `ci-watch/poll.sh`.
  - `grep -P`: spec-tooling.
  - On stock macOS (bash 3.2, no `flock` or `timeout`) these crash. The worst cases: the fail-open SAST scan crashes instead of skipping, and `poll.sh` treats "timeout: command not found" as a test failure and spawns fixer agents.
- **Biggest risk 4 — gates with confirmed false negatives:**
  - The `--cached` bump-class pre-commit reads the worktree `plugin.json` instead of the index.
  - `check-format.sh` checks Validation checkboxes and the Version History table globally, so an empty section still passes.
  - D4 tag-retarget detection via reflog is effectively dead, because git keeps no tag reflogs by default.
  - CI checks only `--commit HEAD`.
- **Token cost.** The ~1.3 KB PDH stanza is repeated 12× in `release-train/SKILL.md` and 5× in `release/SKILL.md`. 208 identical `# lint-ok: C3` lines exist only to waive the canonical stanza. `spec-tooling/SKILL.md` is 41,448 B, over the 40 KB must-split line that `/audit` documents.

## Per-file review

| File | Lines | Purpose (short) | Verdict | Findings (concise, with line numbers) |
|---|---|---|---|---|
| commands/audit.md | 63 | `/audit` thin entry over audit.sh | Minor | L57 `bash "$AUDIT_SH" "$@"`: a Bash-tool fence has no positional params, so user flags are dropped unless the agent substitutes them (F17). L7 argument-hint omits the required `--from-json FILE` for apply. L13 prose uses a cwd-relative path. |
| commands/release-train.md | 56 | `/release-train` thin entry | Minor | L33-52 dispatch fence is not tagged `template`, yet it calls register/list/drop/freeze in one block with undefined `$BRANCH`/`$BUMP`. `register` drops `--assumed`. L8 advertises `status`, which is not a train-lib command (it maps to `list`; OK). |
| commands/spec.md | 777 | `/spec` unified dispatcher plus inline check/create/find/list/update | Issue | L760 "reflect: Args: none (no flags)" contradicts skill L689-692 (`--report`, `--phase N`) (F14). L767-771 says legacy commands "remain until Task 12" but they are gone (docs say removed at v1.0.0). L22-26 cite nonexistent `commands/check-specs.md` etc. L416 skeleton hard-codes `**Category**: core`, so PERF/SAFE/... specs get the wrong category (F20). L493-502 find example uses emoji statuses (✅/🔄) against the lifecycle vocabulary. L337 `/spec check audit` conflicts with the "remaining token = spec ID" rule (L68). |
| docs/commands/audit.md | 53 | User docs for /audit | OK | Consistent with the command and skill. `/doctor` link targets docs hub (fine). |
| docs/commands/spec.md | 187 | User docs for /spec | Minor | L148 reflect is shown with no flags, the same contradiction as the command vs the skill. Otherwise accurate. |
| docs/runbooks/specs.md | 233 | Specs workflow runbook | Issue | L86 example `**Status**: 🚧 NEW` violates the lifecycle vocabulary that `/spec check` Phase 1 enforces (commands/spec.md L81), so users copying it fail the audit (F19). L76 `SPEC-NNN` should be `<ID>` for non-core categories. All links resolve. |
| skills/audit/SKILL.md | 47 | /audit protocol | Minor | L34 says "`--yes` or TTY", but apply.py accepts only `--yes` (no TTY path). Under 40 KB (OK). |
| skills/audit/apply.py | 190 | Approve-then-apply replace-span | Issue | L49-75 "mechanical evidence" is shape-only: passages, counts and spec quote are never checked against file contents, so a fabricated finding passes (F13). L86 rejects any path containing a `skills` or `commands` dir anywhere (e.g. `/home/skills/...`), a false positive. Apply is not scoped to inventoried layers (any `AGENTS.md` on disk). Multi-id apply is non-transactional: an earlier write persists when a later id fails (L184-185). |
| skills/audit/audit.sh | 436 | Instruction-stack inventory | Minor | L20 `SKILL_HARD_BYTES` is only printed; no distinct must-split status, so a 41 KB SKILL is just WARN. Bare `/audit` on this repo exits 1 (9 SKILL.md > 30 KB), which an agent may read as an error. `stat`/`date` have BSD fallbacks (good). |
| skills/audit/from-session.sh | 77 | Locate session via transcript-parse | OK | Locate-only, as the spec requires. |
| skills/audit/test.sh | 473 | Audit bite-tests (37 pass) | Minor | No test for fabricated evidence quotes (F13), multi-id partial apply, or out-of-scope paths. |
| skills/backlog/SKILL.md | 589 | /backlog protocol (Linear-first plus write-through) | Issue | L104 `grep -c … \|\| echo 0` yields `0\n0` on no match (grep prints 0 and exits 1), so a numeric test errors. L33-41 vs L287/375: `add` writes to the git-common-dir root while close/reconcile default to show-toplevel. In a worktree these are different stores (F9). L483/494 "Completed count" conflicts with reconcile pruning completed items. |
| skills/backlog/close.sh | 438 | Deterministic close/verify | **Major** | L327-343 awk `getline` at EOF: when `## Completed` is the last line (the `init` template), the header is re-emitted, duplicating `## Completed` and rows on every close/re-close. Reproduced (F2). L127/L146 title = `head -n1`, which is `---` for every Linear-linked item with frontmatter, so title search breaks and synthesized rows read `- [---](…)`. L271 `awk -v` expands backslash escapes in `--note`. |
| skills/backlog/reconcile-test.sh | 570 | Reconcile tests (68 pass) | Minor | No fixture with group headings, sub-bullets or trailing sections, so the F1 data loss is untested. |
| skills/backlog/reconcile.sh | 328 | Index/item reconcile | **Major** | L250-281 rebuild keeps only the header plus slug rows. `### Group` headings, sub-bullets and any section after `## Completed` are silently deleted while it prints `applied 0 action(s)`. Reproduced (F1). L112/178-181 `declare -A` needs bash 4 (F5). L297/304 empty-array expansion under `set -u` breaks on bash < 4.4. L123/146: a blank verdict state counts as terminal, so an item file is deleted on missing data. L127 JSON parsed by regex (order-dependent). |
| skills/backlog/terminal-status.sh | 56 | Shared terminal classifier | OK | Clean token-match; UNDONE guard correct. |
| skills/backlog/test.sh | 678 | close.sh tests (98 pass) | Minor | Every fixture has a blank line or rows after `## Completed`, and title search is only tested without frontmatter. Misses F2. |
| skills/ci-watch/SKILL.md | 231 | CI watch contract plus cron prompt | Issue | L72/145-188: nothing expires `fixer_active`. If a fixer crashes, the cron polls `wait` every 7 min forever and never caps (F11). Cron step labels are disordered (a, b, c, 5a, d, 5c). L139 says tools "Task" while L171 says Agent `effort`. Prompt is ~2.9 KB (under the 4 KiB claim). |
| skills/ci-watch/detect-mode.sh | 73 | Detect ci/local-test/none | Minor | L19 `ci` wins whenever `.github/workflows` exists, even with no remote or PR. `setup.py` alone implies pytest (heuristic). |
| skills/ci-watch/poll.sh | 193 | One poll cycle | Issue | L178 GNU `timeout`: on macOS rc=127 becomes `fail`, which spawns a fixer (F6). L42-43 fixed temp names `${TMPDIR}/ci-watch-out-$TICKET.txt` (clobber / symlink risk; use mktemp). L137 `[]` → `done` is spec-sanctioned but races freshly pushed PRs whose checks have not registered yet, so the watch can end before CI starts (F12). L160 assumes worktree slug == ticket id. |
| skills/ci-watch/sidecar.sh | 208 | Sidecar JSON CLI | Issue | L85/130/175 `flock` is Linux-only; on macOS every init/set/inc fails (F5). `delete` leaves `.last_failure.txt`/`.log`. `set` retypes numeric strings (pr_number becomes a number). |
| skills/ci-watch/test-poll.sh | 141 | poll.sh ci-mode tests (7 pass) | Minor | No local-test, `fixer_active`, MERGED/CLOSED or sidecar tests. |
| skills/docs-drift/SKILL.md | 62 | docs-drift contract | Minor | L10 "Step 4.9 after T3" is a stale or undefined reference. |
| skills/docs-drift/check-docs-drift.sh | 5 | exec wrapper | OK | — |
| skills/docs-drift/check.py | 644 | Structural docs drift checker | Minor | skill-ref (L524-557) scans only `commands/*.md`: a dangling `skills/x/y.sh` in `skills/**/*.md` or agents is not caught, and `skills/plugin-dir.sh` (no subdir) is outside the regex (L40). L73-114 `section_lines` has redundant or confusing branches. cmd-index (a) waiver is effectively impossible (line 1 of a command is frontmatter). |
| skills/docs-drift/test.sh | 499 | Bite-tests (65 pass) | Issue | L375-451 mutates live repo files (AGENTS.md, marketplace.json, commands/memory.md, docs/commands/status.md) with no trap-based restore. An interrupt or CI timeout leaves the repo corrupted. L437-441 asserts a clean live tree, which couples the test to unrelated drift (F18). |
| skills/metrics/SKILL.md | 47 | Metrics helpers index | OK | — |
| skills/metrics/emit-outcome.sh | 149 | Outcomes ledger writer | Minor | L138-144 numeric fields pass unvalidated to `--argjson` (any JSON value accepted, e.g. an object). |
| skills/metrics/outcome-rates.sh | 207 | Advisory rates | OK | Non-numeric `review_cycles` fails silent (acceptable fail-open). |
| skills/metrics/rollup.sh | 322 | Read-only rollup | Minor | L202-218 `jq -s` over all task files: one malformed file zeroes the whole aggregate, contradicting the L197 comment "malformed → other". About 20 jq forks for the human view. |
| skills/metrics/test.sh | 520 | Metrics tests | Issue | Test 4 (L138-150) fails as root (chmod 555 does not stop root). Observed `PASS=24 FAIL=1`. Needs a root skip (F21). |
| skills/model-map/SKILL.md | 220 | Model map contract | Minor | The repo-layer `models.json` is committable, so a PR can downgrade `qa`/`council-judge` with only a stderr warning (design; worth a doctor FAIL-level note). Dense and long, but consistent with the scripts. |
| skills/model-map/effort-test.sh | 393 | --effort tests (45 pass) | OK | HOME isolated. |
| skills/model-map/effort-write-test.sh | 430 | set/unset-effort tests (66 pass) | Minor | No concurrent-writer test for the CDT-231 flock claim. |
| skills/model-map/resolve-model.sh | 183 | Resolve model/effort | Minor | 5-7 jq forks per layer per call (`write-model list` = 20 calls). A multi-line model value passes through. Otherwise matches the spec. |
| skills/model-map/spawn-site-test.sh | 303 | Static spawn-site contract (121 pass) | Minor | Grep-presence checks (`retry once`, `host rejected`) anywhere in a file are trivially satisfiable. The roster duplicates the SPEC-003 table (a second copy to maintain). |
| skills/model-map/test.sh | 358 | resolve tests (30 pass) | OK | — |
| skills/model-map/write-model-test.sh | 370 | set/unset tests (51 pass) | OK | — |
| skills/model-map/write-model.sh | 238 | Local map writer | Issue | L146/170/190 `flock` is Linux-only, so `/setup models set` fails on macOS (F5). L212 lock file `models.local.json.lock` is not gitignored (.gitignore L36 covers only `models.local.json`). |
| skills/notify/webhook-test.sh | 95 | Webhook tests (8 pass) | OK | Not in CI. |
| skills/notify/webhook.sh | 82 | Fail-open webhook POST | Minor | The documented event enum is never validated. "Never includes secrets" cannot be guaranteed for caller-supplied `detail`. No `SKILL.md` (asset dir; fine). |
| skills/release-train/SKILL.md | 344 | Train protocol | Issue | L264-275 (1h) restore after any `/release` failure, even post-commit, post-tag or post-push (F3). The ~1.3 KB PDH stanza appears 12× (~16 KB of repeated tokens) (E1). L308-314 resume tells the user to "re-register" a blocked entry, but `drop` allows only `pending` and `register` rejects duplicates, so a blocked entry can never be cleared except by hand-editing JSON (F15). |
| skills/release-train/fixtures/changelog/branch_entry.md | 9 | M5c fixture | OK | — |
| skills/release-train/fixtures/changelog/master.md | 9 | M5c fixture | OK | — |
| skills/release-train/fixtures/changelog/want.md | 12 | M5c expected | OK | — |
| skills/release-train/fixtures/json/marketplace.json | 8 | M5d fixture | Minor | Carries `plugins[].version`, which AGENTS says marketplace must not have (tests the "only if present" branch; OK). |
| skills/release-train/fixtures/json/plugin.json | 4 | M5d fixture | OK | — |
| skills/release-train/fixtures/renumber/CHANGELOG.md | 7 | renumber fixture | OK | — |
| skills/release-train/fixtures/renumber/marketplace.json | 8 | renumber fixture | OK | Same note as json/marketplace.json. |
| skills/release-train/fixtures/renumber/plugin.json | 4 | renumber fixture | OK | — |
| skills/release-train/fixtures/tdd-index/ours.md | 14 | M5a fixture | OK | — |
| skills/release-train/fixtures/tdd-index/theirs.md | 16 | M5a fixture | Minor | Only add-row cases. There is no fixture where the branch edits an existing row (F10). |
| skills/release-train/fixtures/tdd-index/want.md | 15 | M5a expected | OK | — |
| skills/release-train/fixtures/vh/ours.md | 9 | M5b fixture | OK | — |
| skills/release-train/fixtures/vh/theirs.md | 9 | M5b fixture | OK | — |
| skills/release-train/fixtures/vh/want.md | 11 | M5b expected | OK | — |
| skills/release-train/test-integration.sh | 212 | End-to-end simulation | Issue | **Fails in a clean environment** (`FAIL: restore dirty`, `FAIL: blocked restore not clean`, PASS=11 FAIL=2). With `RELEASE_TRAIN_ROOT=$REPO` the queue lands in untracked `.claude/release-train/`, and the fixture has no `.gitignore`. It passes only with the dev's global gitignore. Not in CI (F7). |
| skills/release-train/test.sh | 292 | train-lib unit tests (64 pass) | Issue | L164 `git add -A` on feat/c accidentally commits `.claude/release-train/queue.json`. The checkout back to master then deletes it, so the later `restore`/`preflight` "clean"/"ok" asserts (L241, L249-250) pass by accident and mask the preflight self-dirty bug (F7). |
| skills/release-train/train-lib.sh | 885 | Mechanical train CLI | Issue | L772-792 `restore` = blind `git reset --hard` (F3); L776-778 dead no-op `if`. L836-858 `preflight` reports `dirty` once `init` creates an un-ignored queue in consumer repos (F7). L547-553 tdd-index dedupes by whole line, so a branch that edits an existing row yields duplicate SPEC rows. Reproduced (F10). L816-824 lock is test-then-write (TOCTOU) with no stale-lock recovery. L128-135 `read_master_version` is cwd-relative. L481-483/569-571/660-662/741-742 `shift 2` on a missing value exits 1 silently under `set -e`. L722-727 changelog rewrite normalizes every `### X.Y.Z` heading to `### vX.Y.Z`. |
| skills/release/SKILL.md | 476 | /release contract | Issue | L42-66 Step 0 REF falls back to the checkout basename or `feat/<x>`. Dots or slashes (`my.repo`, `feat/a.b`, `feat/user/x`) fail `validate_epic_id` → exit 64, and missing `jq` → exit 1, so a non-epic release is hard-blocked (F8). L463-464 `git push origin "$BRANCH" --tags` pushes every local tag, including stale or experimental ones (F16). L143-144 "feat → minor" conflicts with AGENTS "new opt-in flags = patch". PDH stanza ×5. |
| skills/release/check-bump-class.sh | 205 | Bump-class gate | Issue | L151-155 `--cached` (pre-commit) reads the worktree `plugin.json` when it is not staged. Reproduced: staged new command + unstaged minor bump → `ok`, although the commit keeps the old version (F4). `--diff-filter=A` misses renames that create a new command name. The CI invocation checks only HEAD (F4). |
| skills/release/check-ship-history.sh | 506 | Ship-history gate | Issue | L372-373 `declare -A` needs bash 4. On bash 3.2 it exits 2, outside the 0/1/64 contract. The L371 comment claims portability (F5). L373 `release_subj_seen` is unused. L421-436 D4 reflog detection is dead by default: git keeps no reflog for tags unless `core.logAllRefUpdates=always`. Verified: a tag move shows an empty reflog (F4). |
| skills/release/check-staged-paths.sh | 120 | Staged-path allowlist | Minor | L106 `git diff --cached --name-only` with rename detection hides the deleted source path of a staged rename. Quoted non-ASCII paths (core.quotePath) false-fail. Use `-z --no-renames`. |
| skills/release/install-git-hooks.sh | 20 | Sets core.hooksPath | Minor | L18 silently overrides any existing `core.hooksPath` or `.git/hooks`, disabling the user's hooks. Step 0.6 runs it unprompted. |
| skills/release/test-bump-class.sh | 154 | Bump-class tests (16 pass) | Minor | No case for "new command staged + bump only in worktree" (F4), and no rename case. |
| skills/release/test-ship-history.sh | 320 | Ship-history tests (33 pass) | Minor | No reflog-based D4 test (the dead path is untested), no merge-commit fold case, no bash-3.2 run. |
| skills/release/test.sh | 230 | Staged-path tests plus ship-history rollup (50 pass) | Minor | Neither this file nor test-ship-history.sh runs in CI (smoke.yml runs only test-bump-class). |
| skills/security-scan/SKILL.md | 63 | Optional SAST feed | Minor | Claims "exit code is always 0", which scan.sh violates on bash 3.2 (F5). `--config=auto` fetches rules and sends metrics to the Semgrep registry; there is no privacy note (unverified detail). |
| skills/security-scan/scan.sh | 104 | Semgrep/CodeQL runner | Issue | L24 `mapfile` needs bash 4. With `set -e` (L5) the fail-open contract breaks on macOS bash 3.2 (F5). L39-42 silently truncates to 40 targets with no note in the summary. Targets are root-relative but semgrep runs from cwd. The two diff lists are not deduped. No tests. |
| skills/skill-lint/SKILL.md | 60 | Lint contract | OK | Accurate. |
| skills/skill-lint/check-skill-bash.sh | 5 | exec wrapper | OK | — |
| skills/skill-lint/fixtures/c1-cross-block.md | 32 | C1 fixture | OK | — |
| skills/skill-lint/fixtures/c2-bang.md | 19 | C2 fixture | OK | — |
| skills/skill-lint/fixtures/c3-glob.md | 18 | C3 fixture | OK | — |
| skills/skill-lint/fixtures/c4-pragma.md | 17 | C4 fixture | OK | — |
| skills/skill-lint/fixtures/c5-pdh-drift.md | 17 | C5 fixture | OK | — |
| skills/skill-lint/fixtures/clean.md | 15 | Clean fixture | OK | — |
| skills/skill-lint/fixtures/waived.md | 8 | Waiver fixture | OK | — |
| skills/skill-lint/lint.py | 510 | SPEC-021 linter | Minor | The canonical PDH stanza always trips C3, so 203 C3 plus 92 C1 waivers are needed. A waiver is also a blanket escape (`# lint-ok: C1,C2,C3,C4,C5`). Only ```` ```bash ```` fences are linted (0 ```` ```sh ```` fences today, but relabeling is a trivial bypass). No check for the AGENTS `${TMPDIR:-/tmp}` rule (E2). |
| skills/skill-lint/test.sh | 230 | Lint tests (56 pass) | OK | Good vacuity coverage. |
| skills/spec-tooling/SKILL.md | 1024 | /spec generate/tests/reflect | Issue | 41,448 B, over the 40 KB must-split line (E3). L214 `grep -oP` is GNU-only, so numbering fails on macOS (F5). L113/L214/L225 unquoted `$MROOT`. L598-599 "MUST NOT append" vs L674 "only add new tests" contradict each other. L907 "read full file" vs L913 "cap 300 lines". Phase 5 reads every source file with no count cap (token blow-up). L30 fence uses a cwd-relative maintainer path. |
| skills/spec-tooling/check-format.sh | 97 | 9-section format check | Issue | L75 and L82 check checkboxes and the `\| Date \| Change \|` header anywhere in the file, not inside their sections. Verified: an empty `## Validation` plus a table only inside a code fence → `OK` (F12b). No test of its own; not run over `specs/**` in CI. |
| skills/spec-tooling/fixtures/post-fix.spec.md | 43 | check-format fixture | Minor | Orphaned: no test or doc references it (dead fixture). Cites the legacy `/generate-specs`. |
| skills/spec-tooling/fixtures/pre-fix-baseline.spec.md | 27 | check-format fixture | Minor | Orphaned, same as above. |
| skills/spec-tooling/source-exclude.md | 40 | Include partial | Minor | L105-112 consumer list names `commands/check-specs.md`, `skills/reflect-specs/SKILL.md` and `commands/update-spec.md`, none of which exist. The real consumers are commands/spec.md and spec-tooling/SKILL.md. |
| skills/spec-tooling/spec-skeleton.md | 68 | Include partial | Minor | L141-144 name nonexistent `commands/create-spec.md` and `skills/generate-specs/SKILL.md`. L44 hard-codes `**Category**: core` (root of F20). |

## Findings

1. **[P1] `reconcile.sh` silently deletes non-row index content.**
   - Where: `skills/backlog/reconcile.sh:250-281`.
   - Evidence: an index with `### Group A`, a `  - sub-note: keep me` bullet and a trailing `## Notes\nimportant` section is reduced to header plus rows plus an empty `## Completed`. The script prints `reconcile: applied 0 action(s).`
   - Why it matters: `close.sh:292` explicitly promises "Preserve hierarchical Pending content", so the two scripts disagree.
   - Fix: rebuild by filtering in place. Stream the file, drop only the pruned, dead or duplicate slug rows, and keep every other line and every section. Add a fixture with headings, sub-bullets and trailing sections.

2. **[P1] `close.sh` duplicates `## Completed` and rows when the header is the last line.**
   - Where: `skills/backlog/close.sh:327-343`.
   - Evidence: an index ending in `## Completed` (the SKILL `init` template, `SKILL.md:64-70`) produced, after close and re-close:

     ```
     ## Completed
     - [Foo bar](backlog/foo.md) - x [COMPLETED]

     - [Foo bar](backlog/foo.md) - x [COMPLETED]

     ## Completed
     - ... ## Completed
     ```

   - Cause: awk `getline` at EOF returns 0 and leaves `$0` as the header, which is then printed again.
   - Fix: `if ((getline nxt) > 0) {...} else { print ""; print newline; inserted=1 }`. Also derive the title from the first `^# ` line after the frontmatter, not `head -n1`; today it yields `---` for Linear-linked items (L127, L146).

3. **[P1] Release-train `restore` blindly hard-resets after a partial `/release`.**
   - Where: `skills/release-train/train-lib.sh:772-792` and `skills/release-train/SKILL.md:264-275`.
   - Evidence: 1h runs `restore "$BASE"` (→ `git reset --hard`) on any `/release` failure. `/release` can fail after the Step 5 fold commit, after the Step 6 local tag (ship-history dirty), or after a push (sandbox or post-push checks).
   - Result: the fold commit is dropped while the tag still points at it, or local master ends up behind origin.
   - Fix: in `restore`, refuse unless `git rev-list --count BASE..HEAD` is 0 or the caller passes `--allow-rewind`. Detect tags pointing inside `BASE..HEAD` and report them. Have SKILL 1h branch on "HEAD moved?" and hand over to the H7 interactive path instead.

4. **[P1] Release gates have confirmed false negatives.**
   - (a) `check-bump-class.sh:151-155`: `--cached` reads the worktree `plugin.json` when it is not staged. Reproduced: new command staged plus `1.1.0` only in the worktree → `bump-class: 1 new command(s), 1.0.0 -> 1.1.0 (minor) — ok`, although the commit keeps `1.0.0`. **Fix:** always use `git show :.claude-plugin/plugin.json` in `--cached` mode.
   - (b) `check-ship-history.sh:421-436`: D4 local retarget relies on `git reflog show <tag>`. Git does not log tag refs by default; verified that an empty reflog follows `git tag -f`. **Fix:** make `--expect-tag` mandatory in `/release` Step 6, or snapshot `git for-each-ref refs/tags` at Step 0.5 and compare.
   - (c) `.github/workflows/smoke.yml:43`: CI runs `--commit HEAD` only, so a multi-commit push hides a new command in an earlier commit. **Fix:** loop over `github.event.before..HEAD`.
   - (d) `--diff-filter=A` misses renamed-in command files. **Fix:** use `AR`.

5. **[P1] GNU and bash-4 dependencies break macOS, which the docs target (`docs/setup.md:226` brew).**
   - `declare -A`: `reconcile.sh:112,178-181` and `check-ship-history.sh:372-373` (exit 2, outside the contract).
   - `mapfile`: `scan.sh:24`. This is a fail-open tool that now crashes under `set -e`.
   - `flock`: `sidecar.sh:85,130,175` and `write-model.sh:146,170,190`.
   - `grep -oP`: `spec-tooling/SKILL.md:214`.
   - Fix:
     - Replace the associative arrays with newline-delimited files or `case`/`grep -Fx` lookups.
     - Replace `mapfile` with a `while read` loop.
     - Add a `mkdir`-lock fallback when `command -v flock` fails.
     - Use `sed -n 's/.*SPEC-\([0-9]*\).*/\1/p'`.
     - Add a CI job with `bash:3.2` (docker) or `macos-latest`.

6. **[P1] `ci-watch/poll.sh` spawns fixers when `timeout` is missing.**
   - Where: `skills/ci-watch/poll.sh:178`.
   - Evidence: `( cd "$wt" && timeout 120 bash -c "$test_cmd" )`. On macOS without coreutils, rc=127 and a non-zero rc goes to `handle_failure`, which emits `fail`. The cron then spawns an ic5 "hot-fix" for `timeout: command not found`, up to the 3-retry cap.
   - Fix: resolve `timeout`/`gtimeout`. If neither exists, run without a timeout or emit `wait` plus `poll_error_count++`. Treat rc 126/127 as a poll error, not a test failure.

7. **[P1] Release-train preflight flags its own queue as dirty, and the tests mask it.**
   - Where: `train-lib.sh:836-858` and `test-integration.sh:168,200`.
   - Evidence: in a consumer repo without `.claude/release-train/` in `.gitignore`, `init` creates an untracked file, so `preflight` → `dirty` and the train cannot start. `test-integration.sh` fails in a clean environment (`FAIL: restore dirty` / `FAIL: blocked restore not clean`; `git status --porcelain` shows `?? .claude/`).
   - `test.sh:164` hides the bug: `git add -A` on feat/c commits the queue, and checking out master deletes it.
   - Fix: have `preflight` ignore `.claude/release-train/` (`git status --porcelain -- . ':!.claude/release-train'`), or have `init` append to `.git/info/exclude`. Add `.gitignore` to the fixtures, use `git add <explicit paths>`, and add both harnesses to CI.

8. **[P2] `/release` Step 0 hard-blocks ordinary releases in some layouts.**
   - Where: `skills/release/SKILL.md:52-66`.
   - Evidence: REF falls back to `basename $WTROOT` or `feat/<rest>`. `validate_epic_id` (`epic-lib.sh:69`) rejects anything outside `[A-Za-z0-9_-]` with exit 64, and missing `jq` gives exit 1. Both map to `exit 64` with the message "release=end mode", even when no epic exists. Affected: a checkout at `~/src/my.plugin`, or branch `feat/v1.2-fix` / `feat/user/topic`.
   - Fix: only call `assert-release-allowed` when REF matches the charset and `$MROOT/.claude/epics` exists. Treat rc≠64 as "no epic context".

9. **[P2] The backlog root is split between `add` and close/reconcile.**
   - Where: `skills/backlog/SKILL.md:33-41` vs `close.sh:92-102` and `reconcile.sh:59-69`.
   - Evidence: `add` writes under the git-common-dir root. close and reconcile default to `--show-toplevel`, which is the worktree. From a `.worktrees/<slug>` checkout, close cannot find items that add created ("no backlog item matching") and may create a divergent index.
   - Fix: pick one root. SPEC-016 shared-state semantics suggest MROOT, or have the scripts accept MROOT by default.

10. **[P2] The release-train TDD-index resolver duplicates rows the branch edited.**
    - Where: `train-lib.sh:547-553`.
    - Evidence: a branch changing `SPEC-010 … INFERRED` to `ACTIVE` produced both rows in the output.
    - Fix: key rows by SPEC-ID, prefer the branch's version for IDs present in both (or halt M6 on a differing same-ID row), and add a fixture.

11. **[P2] ci-watch `fixer_active` can latch forever.**
    - Where: `ci-watch/SKILL.md:72,159-187` and `poll.sh:71-74`.
    - Evidence: if the fixer Task errors or the session dies between 5a and 5c, `fixer_active=true` persists. poll emits silent `wait` every 7 min indefinitely (a durable cron keeps firing), and nothing notifies the user.
    - Fix: store `fixer_started_at`, treat the guard as stale after N minutes (log `fixer_stale`, clear it, count a retry), and notify.

12. **[P2] ci-watch `[]` → `done` races freshly pushed PRs.**
    - Where: `poll.sh:137`; the behavior is spec-sanctioned (SPEC-017 L65).
    - Detail: right after the first push, GitHub commonly reports no checks for a few seconds to minutes. Arming at Step 8.5 followed by a first poll inside that window deletes the cron, so CI is never watched. (Timing unverified live; the logic is verified.)
    - Fix: treat `[]` as `done` only when `.github/workflows` is absent or after K consecutive empty polls. Amend SPEC-017.

12b. **[P2] `check-format.sh` validates presence globally instead of per section.**
    - Where: `skills/spec-tooling/check-format.sh:75,82`.
    - Evidence: a spec with an empty `## Validation` section, whose only checkbox sits under `## Test`, and whose `| Date | Change |` exists only inside a fenced block → `OK: all 9 required sections present`.
    - Fix: scope with awk between the section heading and the next `## ` (as the MUST check at L59-65 already does), and skip fenced lines. Add a harness using the orphaned fixtures (see 22).

13. **[P2] `/audit apply` "mechanical evidence" is shape-only.**
    - Where: `skills/audit/apply.py:49-75`.
    - Evidence: any two `{path, quote}` objects plus `counts.bytes` plus a `spec.id`/`quote` pass. Quotes are never checked against the files, so an LLM-fabricated finding meets the "vibes rejected" gate.
    - Fix: verify each `passage.quote` occurs in `passage.path` (and at `line` if given), verify `counts.bytes` equals the file size, and check that the spec quote appears in the spec file. Also restrict `path` to layers from the inventory JSON.

14. **[P2] `/spec reflect` flags contradict across files.**
    - Evidence: `commands/spec.md:760` says "Args: none … (no flags)". `docs/commands/spec.md:148` agrees. `skills/spec-tooling/SKILL.md:689-692,967` defines `--report` and `--phase N`.
    - Fix: document the flags in the command table (L39) and the docs, or remove them from the skill.

15. **[P2] Blocked train entries have no exit path.**
    - Where: `train-lib.sh:202-217,343-375` and `SKILL.md:312-317`.
    - Evidence: the only legal transitions are pending→landing→landed|blocked. `drop` allows only pending, and `register` rejects an already-queued branch. The SKILL tells the user to "re-register", which is impossible without hand-editing `queue.json`.
    - Fix: add `blocked→pending` (`requeue <branch>`) or allow `drop` of blocked entries.

16. **[P2] `/release` pushes all local tags.**
    - Where: `skills/release/SKILL.md:463-464`.
    - Evidence: `git push origin "$BRANCH" --tags` pushes stale, experimental or deleted-upstream tags too. It also conflicts with the H5/H10 "only push the tag you verified" intent.
    - Fix: `git push origin "$BRANCH" "refs/tags/vX.Y.Z"` (or annotated tags plus `--follow-tags`).

17. **[P2] Command fences use `"$@"` in the Bash tool.**
    - Where: `commands/audit.md:57`.
    - Evidence: Bash-tool invocations have no positional parameters, so `/audit --json` or `apply …` args are silently dropped unless the agent rewrites the fence.
    - Fix: tag the fence `bash template` with an explicit `<args>` placeholder, as other commands do.

18. **[P2] The docs-drift test mutates the live repo without a restore trap.**
    - Where: `skills/docs-drift/test.sh:375-451`.
    - Evidence: it rewrites `AGENTS.md`, `.claude-plugin/marketplace.json`, `commands/memory.md` and `docs/commands/status.md` in place. Restores run inline, with no trap on INT/TERM/ERR. Parallel runs (for example skill-lint over `commands/memory.md`) can flake.
    - Fix: copy the repo into a mktemp dir and run live-tree injects with `--root <copy>`, or at least `trap 'restore_all' EXIT INT TERM`.

19. **[P3] The runbook example violates the lifecycle vocabulary.**
    - Where: `docs/runbooks/specs.md:86`.
    - Evidence: `**Status**: 🚧 NEW`, whereas `/spec check` requires INFERRED/DRAFT/ACTIVE/APPROVED/DEPRECATED.
    - Fix: use `DRAFT`.

20. **[P3] The spec skeleton hard-codes `**Category**: core`.**
    - Where: `spec-skeleton.md:44` and `commands/spec.md:416`.
    - Detail: `/spec create` for PERF/SAFE/COMPAT/ARCH is told to replace only `<…>` placeholders, so the category stays `core`.
    - Fix: use a `<CATEGORY>` token and add a render instruction.

21. **[P3] The metrics test is not root-safe.**
    - Where: `skills/metrics/test.sh:138-150`.
    - Evidence: `FAIL: 4 unwritable rc=0 ledger=y err=`, because root ignores `chmod 555`.
    - Fix: `[ "$(id -u)" -eq 0 ] && skip`.

22. **[P3] Stale references, dead code and dead files.**
    - `source-exclude.md:105-112` and `spec-skeleton.md:141-144` list nonexistent consumer files.
    - `commands/spec.md:22-26,767-771` refer to legacy commands as live.
    - `docs-drift/SKILL.md:10` has "after T3".
    - `train-lib.sh:776-778` has a no-op `if`.
    - `check-ship-history.sh:373` has an unused `release_subj_seen`.
    - `spec-tooling/fixtures/*.spec.md` are unreferenced.
    - `audit.sh` `SKILL_HARD_BYTES` is unused for status.

23. **[P3] Miscellaneous shell hygiene.**
    - `backlog/SKILL.md:104` `grep -c … || echo 0` gives `0\n0`.
    - `poll.sh:42-43` uses predictable temp names; use `mktemp`.
    - `check-staged-paths.sh:106` should use `-z --no-renames`.
    - `install-git-hooks.sh:18` clobbers an existing `core.hooksPath`.
    - `.gitignore` lacks `.claude/dev-team/models.local.json.lock`.
    - `train-lib acquire-lock` (L816-824) is non-atomic and has no stale recovery.
    - `scan.sh:39-42` truncates targets silently.

## Enhancement proposals

- **E1. Resolve PDH once per skill and stop repeating it (effort M, impact high).**
  - `release-train/SKILL.md` has 12 copies (~16 KB) and `release/SKILL.md` has 5.
  - Merge the adjacent fences that only resolve `TRAIN_LIB` into one fence per step, or add a tiny `train.sh` wrapper resolved once that dispatches to train-lib.
  - Estimated saving: ~20 KB of tokens per `/release-train` load.
- **E2. Skill-lint improvements (effort S, impact medium).**
  - Auto-exempt C3 (and the related C1) on lines that pass C5 byte-equality with the canonical stanza. That removes 208 boilerplate `# lint-ok: C3 — marketplace…` lines (~17 KB across the repo).
  - Add a C6 check for bare `/tmp/` writes (the AGENTS rule, currently convention-only).
  - Lint ```` ```sh ````/```` ```shell ```` fences too, closing the relabel bypass.
- **E3. Split `spec-tooling/SKILL.md` into `generate.md`, `tests.md` and `reflect.md` (effort M, impact medium).**
  - Load them lazily from the dispatcher. Each mode is ~13 KB, and today every `/spec generate` pays for all three.
  - Resolve the append contradiction and the 300-line/full-read contradiction at the same time.
- **E4. Add a portability CI matrix (effort S, impact high).**
  - Add a `macos-latest` job (bash 3.2, BSD tools) that runs the slice harnesses. It would have caught F5 and F6 immediately.
  - Add `release/test.sh`, `release-train/test*.sh`, `backlog/*test.sh`, `ci-watch/test-poll.sh`, `metrics/test.sh`, `notify/webhook-test.sh` and `audit/test.sh` to `smoke.yml`. Today only bump-class, docs-drift, skill-lint and a few others run.
- **E5. Make backlog index edits line-preserving (effort M, impact high).**
  - Have close.sh and reconcile.sh share one awk "row rewriter" that touches only matched rows and never regenerates sections (fixes F1 and F2 together).
  - Add fixtures for group headings, sub-bullets, `## Completed` at EOF, frontmatter titles and trailing sections.
- **E6. Add a ship-history tag snapshot (effort S, impact medium).**
  - At `/release` Step 0.5, write `git for-each-ref --format='%(refname) %(objectname)' refs/tags` to a temp file. Pass `--tags-snapshot FILE` so D4 compares pre and post and works without reflogs.
- **E7. Add a release-train `rewind-safe` restore (effort S, impact high).**
  - `restore` should refuse if HEAD is ahead of the base or any tag points inside `BASE..HEAD`, and print the recovery commands (see F3).
- **E8. Verify evidence in `/audit apply` (effort S, impact medium).** Implement quote-in-file, size-match and scope checks (F13), with bite-tests for fabricated quotes.
- **E9. Add a ci-watch stale-guard plus empty-checks debounce (effort S, impact medium).** Add `fixer_started_at` with a TTL, and require K consecutive `[]` polls or no workflows before `done` (F11, F12).
- **E10. Make `check-format.sh` section-scoped and run it in CI over `specs/**/*.md` (effort S, impact medium).** Wire the two orphaned fixtures into a `check-format-test.sh`.

## Coverage attestation

- Files in the slice list (`slices/09-release-tooling.txt`): **86**.
- Rows in the Per-file review table: **86**. The counts match. Every file was read in full; large files were read in chunks, including `train-lib.sh` (885), `commands/spec.md` (777), `spec-tooling/SKILL.md` (1024), `check.py` (644) and `lint.py` (510).
- Harnesses executed:

| Harness | Result |
|---|---|
| release/test-bump-class | 16/0 |
| release/test-ship-history | 33/0 |
| release/test | 50/0 |
| skill-lint/check-skill-bash | exit 0 (299 findings, 299 waived) |
| skill-lint/test | 56/0 |
| docs-drift/check-docs-drift | exit 0 |
| docs-drift/test | 65/0 |
| audit/test | 37/0 |
| backlog/test | 98/0 |
| backlog/reconcile-test | 68/0 |
| ci-watch/test-poll | 7/0 |
| **metrics/test** | **24/1 (root env)** |
| model-map test | 30/0 |
| model-map effort-test | 45/0 |
| model-map effort-write-test | 66/0 |
| model-map spawn-site-test | 121/0 |
| model-map write-model-test | 51/0 |
| notify/webhook-test | 8/0 |
| release-train/test | 64/0 |
| **release-train/test-integration** | **11/2** |

- `bash -n` is clean on all slice `.sh` files. shellcheck is not installed (install attempt blocked by the proxy).
