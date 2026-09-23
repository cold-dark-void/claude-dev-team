# Full Project Review & Enhancement Proposal — 2026-09-23

Baseline: `master` @ `60777e7` (v1.18.14). Read-only review; no product file was
changed by this review. Every file in the repo was assigned to exactly one of ten
review slices and read in full (fixture data sampled). Findings cite `file:line`;
P0 items were reproduced or re-verified against source before inclusion here.

| # | Slice | Scope | Report |
|---|-------|-------|--------|
| 1 | Agents + infra | `agents/*` (12), AGENTS/CLAUDE/CONTEXT/README/SECURITY/LICENSE, `.claude-plugin/*`, `.github/`, `githooks/`, `install*.sh`, `uninstall.sh`, `tools/**` | [01-agents-infra.md](01-agents-infra.md) |
| 2 | Commands (small) + docs | 16 small `commands/*.md`, all of `docs/**` | [02-commands-docs.md](02-commands-docs.md) |
| 3 | Large commands | `commands/{council,memory,retro,spec}.md` | [03-large-commands.md](03-large-commands.md) |
| 4 | Council + fix-ticket | `skills/council/**`, `skills/fix-ticket/**` | [04-council.md](04-council.md) |
| 5 | Orchestration | `skills/{orchestrate,kickoff,epic,autopilot,init-orchestration}/**` | [05-orchestration.md](05-orchestration.md) |
| 6 | Handoff / transcript / retro | `skills/{handoff,transcript-mirror,transcript-parse,retro-gate,retro-subagent}/**` | [06-handoff-transcript.md](06-handoff-transcript.md) |
| 7 | Memory / model-map / metrics / notify | `skills/{memory-*,agent-memory,validate-memory,domain-glossary,metrics,model-map,notify}/**` | [07-memory.md](07-memory.md) |
| 8 | Workflow skills | `skills/{bug-hunt,debug,refactor,review-and-commit,code-simplify,brainstorm,blunt,focus,standup,scaffold-project,spec-tooling,security-scan,craft-loop}/**` | [08-workflow-skills.md](08-workflow-skills.md) |
| 9 | Release / tooling | `skills/{release,release-train,backlog,wrap-ticket,ci-watch,doctor,docs-drift,skill-lint,audit}/**`, `skills/plugin-dir.sh`, `skills/worktree-lib.sh` | [09-release-tooling.md](09-release-tooling.md) |
| 10 | Specs | `specs/TDD.md`, `specs/core/SPEC-001…037` | [10-specs.md](10-specs.md) |

---

## 1. Executive summary

The plugin is ambitious and, in most places, carefully engineered: the core
libraries (`plugin-dir.sh`, `task-store.sh`, `autopilot/*`, `epic-lib.sh`,
`backlog/`, `doctor.sh`) have real bite tests, and several thousand assertions pass. The
problems cluster into a small number of **systemic root causes** rather than
isolated slips:

1. **Tests exist but are not gated.** CI (`smoke.yml`) runs 9 jobs covering ~9 of
   **76** test scripts. Five suites are **red on master today** with nobody
   noticing (§3). Whole subsystems (council, orchestrate, epic, autopilot,
   handoff, model-map, doctor) have zero CI coverage.
2. **Prose-as-program across fresh shells.** Commands and skills rely on
   variables, functions and `trap`s defined in one ```` ```bash ```` fence being
   alive in the next — each fence is a fresh shell. This silently breaks locks,
   report writers, `/setup team`, `/handoff`, distiller, project-init and more.
3. **Lint waivers that change semantics.** `# lint-ok: C1` placed after a
   line-continuation `\` or inside a quoted SQL string breaks the command
   (4 live sites, all P0). skill-lint passes them.
4. **Destructive git with no shared safety primitive.** `git clean -fd`,
   `branch -D`, remote delete and `reset --hard` each carry their own guard (or
   none) — three reproduced data-loss paths.
5. **Untrusted text interpolated into code.** Memory content → SQL (a reproduced
   full-table delete), LLM-extracted paths → `python3 -c`, `$ARGUMENTS` → shell.
6. **Documented-but-unenforced contracts.** Council's "engine-enforced" judge
   validation and 80-confidence filter don't exist; memory validation's
   auto-archive threshold is mathematically unreachable; spec statuses drift.
7. **Context-window cost.** The ~750-byte PDH stanza is emitted ~210 times;
   eleven instruction files exceed 40 KB (bug-hunt `SKILL.md` alone is ~34k
   tokens). Much of that is deterministic code the model re-reads every run.
8. **Portability.** Scripts need bash ≥ 4, `flock`, GNU `timeout`,
   `sha256sum`, GNU `sed`/`find -printf`; stock macOS has none. No macOS CI, no
   `/doctor` probe, no documented platform floor.

Fixing items 1–4 structurally (CI-all-tests, a fence-state lint, a pragma-placement
lint, one `git-safety.sh`) prevents most of the P0 classes below from recurring.

---

## 2. P0 — fix first (all verified)

| # | Defect | Where | Impact | Fix sketch | Rpt |
|---|--------|-------|--------|-----------|-----|
| P0-1 | **Second-order SQL injection empties memory DB** — multi-line memory content becomes a fake TSV row whose first field is spliced unquoted into `WHERE memory_id = ${mid}`; no `.bail` | `skills/validate-memory/reconcile-lib.sh:150-172,331-343` | Reproduced: `memories` 3 → 0 rows. Reachable via any agent write or seed-pack import | Parameterized Python / JSONL export; validate `^[0-9]+$`; `.bail on` on every heredoc SQL | 7 |
| P0-2 | **Epic seal deletes untracked files** — recovery runs `reset --hard` + `git clean -fd` after a tracked-only clean precheck | `skills/epic/epic-lib.sh:979-983` | Reproduced: untracked user file and `.claude/epics/*/state.json` deleted on squash conflict | Porcelain precheck (`_seal_main_is_dirty`); drop `clean -fd` | 5 |
| P0-3 | **prune-remote deletes a teammate's commit** — safety check runs on local `refs/heads/X`, delete targets the remote | `skills/wrap-ticket/prune-remote.sh:128-167` | Reproduced | Fetch + check `refs/remotes/origin/X`; `--force-with-lease=<sha>` delete | 9 |
| P0-4 | **`\  # lint-ok` after a line-continuation** breaks the command | `skills/review-and-commit/SKILL.md:207`, `commands/council.md:1042`, `skills/memory-recall/SKILL.md:106` | review-and-commit finalize runs without evidence/judge; remote semantic recall always takes the lembed branch (reproduced) | Pragma on its own line; new skill-lint rule `\\[ \t]+#` | 3,7,8 |
| P0-5 | **`# lint-ok` inside SQL strings** → `unrecognized token "#"` | `commands/memory.md:413,1426,1516` | All-agents distill, deep-validate and rebuild queries fail | Move pragma outside the string | 3 |
| P0-6 | **`/memory distill` deadlocks itself** — takes `distilling_lock`, then runs validate which refuses when the lock is held | `commands/memory.md:314-357` vs `:831-845` | Every default distill aborts at Step 4.5 | Owner-token exemption; document in SPEC-011 | 3 |
| P0-7 | **Python code injection** via LLM-extracted `REF_PATH` in `python3 -c "…'$REF_PATH'"` (runs whenever `realpath -m` is missing, i.e. macOS) | `commands/memory.md:993-994,1016` | Arbitrary code from memory content | Pass via argv/env | 3 |
| P0-8 | **Scheduled retro lock & report never work** — `trap … EXIT` and `write_scheduled_report_if_needed` live in one fence, used in later fences | `commands/retro.md:150-179` vs `:602,745,1521,1900,1962` | Concurrent cron runs not excluded; SPEC-012 report never written | Move into one script (`scheduled-run.sh`) | 3 |
| P0-9 | **`/setup team` broken** — `PLUGIN_DIR="$PDH"` (not `skills/memory-store`), `MEMDB` before `MROOT`, cross-fence `SETTINGS` | `commands/setup.md:246-330,415-483` | Schema/migrate/extension steps fail; allowlist step writes to `""` | Resolve via `plugin-dir.sh`; merge fences | 2 |
| P0-10 | **project-init writes `/.claude/CLAUDE.md`** — Step 4 fence uses underived `$MROOT`; `cat >` truncates lessons; indented heredoc terminator | `agents/project-init.md:148-150,455-481` | Writes at filesystem root (root containers); wipes accumulated lessons | Derive MROOT; `>>`; column-0 `EOF`; quoted heredoc | 1 |
| P0-11 | **`commands/epic.md:36` says `--autopilot` token is "Unused"** — contradicts AGENTS.md seal-intent rule | `commands/epic.md:36` | Agents drop `release_bump` → forbidden mid-epic landing | Rewrite row; document in docs/commands/epic.md | 2 |
| P0-12 | **Tier-grade signal 4 disabled** by an unspecced CDT-132 exception | `skills/council/tier-grade.sh:314-342` | Deleting 31–99 lines of an existing executable grades **light** (skips council) | Compute signal 4 before clearing `exec_why` | 4 |
| P0-13 | **Workflow-path Borda mislabels votes** (self-excluded labels mapped to global indices) | `skills/council/workflow.js:196-198,474-481` | Consensus ranking corrupted | Per-reviewer label map + shuffle | 4 |
| P0-14 | **Degraded diff-mode judge fails open** (all findings → `warning`, gate PASSED) | `skills/council/workflow.js:601-614` | Judge failure = green commit gate | Fail closed (critical / BLOCKED) | 4 |
| P0-15 | **Struck lines render as Python dicts** in every report | `skills/council/engine.sh:1080` | Every real council report | Format `{claim,line,reason}` | 4 |
| P0-16 | **review-and-commit drops findings** — `logic` has no bucket; `quality` vs `design` mismatch | `skills/review-and-commit/SKILL.md:265-270` | Logic warnings vanish; Maintainability always empty | Mapping + category-parity test | 8 |
| P0-17 | **SPEC-029 reopen gate inert on installs & wrong in dev** | `skills/debug/SKILL.md:315-338`, `skills/debug/theme-status.sh:87-107` | Forced redesign never fires for users; fires a day early in dev | Resolve via `plugin-dir.sh`; exclude current invocation; exact project match | 8 |
| P0-18 | **Validation composite score max = 45**; auto-archive needs > 80 | `skills/validate-memory/SKILL.md`, `commands/memory.md:1152-1198`, SPEC-011:38 | Auto-archive / reviewer thresholds unreachable | Normalize to 0–100 | 7 |
| P0-19 | **Transcript mirror is O(N) jq-forks per Stop** | `skills/transcript-mirror/transcript-mirror.sh:35-61,601` | Measured 14 s/tick at 3k lines > 10 s hook timeout → mirroring silently stops for long sessions | Byte-offset cursor; single-pass ident | 6 |
| P0-20 | **install.sh tier map contradicts SPEC-003** | `install.sh:123-196` | opencode users get wrong models (e.g. pm on sonnet) | Derive from `model:` frontmatter | 1 |

**P1 data-loss / safety items that are one step from P0:** `worktree-lib.sh release`
force-deletes branches with unmerged, unpushed commits (`:324-334`; `-D` is intentional
for squash-merges, but there is no patch-id/pushed check) and falls back to
`worktree remove --force` against SPEC-016; `backlog/reconcile.sh:250-281` silently
drops non-row index content; `autopilot/end-state.md` §4/§6.5 `reset --hard` on the
main repo with no clean precheck; `release/SKILL.md:463` `git push … --tags` pushes
every local tag; `check-bump-class.sh:151-155` reads the worktree `plugin.json` in
`--cached` mode (reproduced bypass); `migrate-md.sh` deletes the source after lossy
migration; seed-pack import is an unscreened prompt-injection channel into digest-tier
memory; `/setup team` grants `Bash(*)` without a sandbox while docs say "the sandbox
is the boundary".

---

## 3. Test baseline (this review)

76 `*test*.sh` scripts + lint/drift/include/smoke gates were run on Linux as root.

| Result | Suites |
|---|---|
| **Red on master — real** | `handoff/detached-stub-test.sh` (`commands/handoff.md` 12096 B > 12000 cap, SPEC-018 T39); `orchestrate/router-static-test.sh` T10 (`steps/02-scope.md:6`, red since v1.17.0); `retro-gate/scheduled-retro-test.sh` (brittle grep vs `commands/retro.md:575`); `release-train/test-integration.sh` (fixture lacks `.gitignore` → `?? .claude/`); `council/test-workflow-static.sh` (calls `workflow-probe.sh` bare under `set -e`; exits 1 silently when `CLAUDE_CODE_VERSION` < 2.1.154 — contradicts its "no live host required" header) |
| Red — environment / test hygiene | `metrics/test.sh` #4 and `transcript-mirror/test.sh` M4 (`chmod` ignored by root — need root skip); `retro-gate/friction-capture-test.sh` (needs generated hooks — should SKIP); `memory-store/test-seed-pack.sh` crashes rc=127 without `sqlite3` instead of skipping |
| Green | 67 other suites; `skill-lint`, `docs-drift`, `sync-includes check`, `tools/smoke/run.sh` |

Tests that write into the live repo or leak temp files: `council/test-workflow-static.sh`
(writes `.claude/council/`, `.claude/retro/anchors/`), `docs-drift/test.sh` (mutates
README/commands, backups deleted on interrupt), handoff Grok adapters, council preflight
cache dirs.

---

## 4. Cross-cutting findings (root causes)

### 4.1 CI parity
- 9 CI jobs vs 76 test scripts; `/release` adds only three more. Linters' own bite
  tests (`skill-lint/test.sh`, `docs-drift/test.sh`, `tools/smoke/test.sh`,
  `install-test.sh`) are not gated.
- No `permissions:` block, no SHA-pinned actions, no `concurrency`, triggers only
  on `master` (not `stable`/epic branches), no macOS job, no shellcheck.
- sqlite3-missing behaviour differs per test (skip-exit-0 / crash-127 / fail).

### 4.2 Fresh-shell state across fences
Affected: `commands/retro.md` (lock/report), `commands/setup.md`, `commands/handoff.md`
(UUID/WARM), `commands/adjust-agent.md` (`$AGENT`), `commands/council.md`
(`COUNCIL_TIER`, `PLAN_FILE`, dead `_COUNCIL_WORKFLOW_FLAG`), `commands/memory.md`
(`# Stop here` without `exit`), `agents/distiller.md`, `agents/project-init.md`,
`skills/orchestrate/steps/07-tasks.md` (`DAG_FILE=…-$$`), `steps/09-review.md`
(`$TASK_ID`), `skills/memory-recall` Step 4/5, AGENTS.md memory sample. skill-lint's
C1 waivers hide many of these; C1 does not check intra-fence order or `agents/`.

### 4.3 Destructive git
`epic-lib.sh` seal (`clean -fd`), `worktree-lib.sh release` (`branch -D`, `--force`),
`wrap-ticket` legacy path (`grep -wF` prefix match → `branch -D`), `prune-remote.sh`
(wrong ref), `train-lib.sh restore`/`autopilot/end-state.md` (`reset --hard` without
branch/clean checks). No shared `is-merged/is-pushed/is-clean` primitive.

### 4.4 Untrusted input → code
SQL: reconcile `mid` (P0-1), memory `--agent`, memory-recall placeholders,
`DIMS`. Python `-c`: memory `REF_PATH`, retro `$JSONL`, init-orchestration hook
template `open('$f')`. Shell: `/recall` topic, `/handoff` `set -- $ARGUMENTS`, council
investigator cache `printf '%s' "P"`. Prompt: seed packs as trusted digests, fixed
`<<<END_BATCH>>>` delimiters, blind-path prompts without data framing, fix-ticket
prompts without untrusted-data framing, `loadPrompt` recursive substitution in
`workflow.js`.

### 4.5 Unenforced contracts & spec drift
Council "engine-enforced" validation and 80-filter (§ report 4); validation score
range; SPEC-016 no-force vs worktree-lib; SPEC-036 incremental mirror; SPEC-004
single-transaction (migrate-v2) and busy-timeout-on-every-write; SPEC-024 M10 caps;
SPEC-037 M1 gitignore; SPEC-011 "Opus reviewer" / cosine vs L2 distance. Specs
index: SPEC-035 status mismatch, SPEC-033 fails `check-format.sh`, five
implemented specs still DRAFT, three APPROVED specs with 0 Validation boxes,
SPEC-005/014/028 still mandate deleted v1.1 stubs, SPEC-019/027 have no
implementation.

### 4.6 Context cost
~210 PDH emissions (~23 KB+ of identical text per load path); 45 root-derivation
blocks in `memory.md`; ~130 lines of shared preamble per agent spawn (output-intensity
block copied 9×). Files > 40 KB: bug-hunt SKILL (135 KB), init-orchestration SKILL
(102 KB), retro cmd (87 KB), epic SKILL (80 KB), council cmd (72 KB), council SKILL
(69 KB), memory cmd (65 KB), kickoff SKILL (61 KB), debug/refactor SKILL (52 KB).
`audit.sh` defines a 40 KB must-split tier but never enforces it.

### 4.7 Surface hygiene
- 7 surfaces lack a docs page (adjust-agent, doctor, release-train, tdd-gate,
  backlog, ci-watch, release); `docs/README.md` mislabels four commands as skills.
- ~20 internal/backend skills lack `user-invocable: false` and appear as
  `/dev-team:*`; 9 commands share a `name:` with a skill.
- Stale wording: `dontAsk` vs shipped `auto` posture, 2 vs 3 approvals,
  "removed at v1.0.0" vs v1.1.0, "deprecation stub" for focus/blunt.
- Five commands pass args via `"$@"` (empty in a Bash-tool shell).

### 4.8 Portability & privacy
bash 4 (`declare -A`, `local -n`) in ≥ 8 scripts, `flock` in ≥ 7, GNU `timeout` in
≥ 5, `sha256sum` without `shasum` fallback, GNU `sed \+`/`\s`, `find -printf`,
BSD-mktemp suffix. Claude project-dir encoding implemented 6×, 4 wrong for paths
with `.`/`_`/space. No `umask 077` anywhere; transcripts, handoff spines and retro
artifacts are world-readable, `.claude/handoff/` and `.claude/retro/` are not
gitignored in user projects, and no secret redaction on mirrored tool I/O.

---

## 5. Enhancement roadmap

Effort: S ≤ ½ day, M ≤ 2 days, L > 2 days. Waves are ordered so each wave's
safety nets catch regressions in the next.

### Wave 0 — P0 fixes (≈ 3–4 days total, all S unless noted)
All twenty rows of §2, plus: make the five red suites green (trim
`commands/handoff.md`, reword `02-scope.md:6`, `grep -F` in scheduled-retro-test,
`.gitignore` in release-train fixture, hermetic workflow-static test). Group into
patch releases by subsystem (memory, council, git-safety, setup/agents,
transcript-mirror).

### Wave 1 — Safety nets (≈ 1 week)
| Proposal | Detail | Effort |
|---|---|---|
| **Run every test in CI** | `tools/run-all-tests.sh` (glob `**/*test*.sh`, explicit env-skip list, uniform exit 77 skip); CI matrix job + `/release` step; add `permissions: contents: read`, `concurrency`, `stable`/epic triggers, a macOS job | M |
| **skill-lint C6–C9** | C6 `\` + trailing comment; C7 `lint-ok` inside an open quote; C8 `${X:-{…}}` brace default (4 live sites in wrap-ticket); C9 destructive git (`branch -D`, `reset --hard`, `clean -f`, `push --force/--delete`) without adjacent guard/waiver; intra-fence use-before-define; extend scan to `agents/*.md`, `sh`/`shell` fences; cwd-relative `bash skills/…` in consumer fences | M |
| **`skills/lib/git-safety.sh`** | `is-clean`, `is-merged <ref> <base>` (ancestor or patch-id/cherry clean), `is-pushed`; used by seal, worktree release, wrap-ticket, prune-remote, end-state, train restore | S |
| **Spec lint** | `check-format.sh` over all specs + `check-index.sh` (index status = file status, Covers paths exist, APPROVED ⇒ boxes checked, dated history order); promote/demote the drifted specs; archive SPEC-019/027; fold SPEC-028 into SPEC-014 | S |
| **Platform floor** | Document bash ≥ 4 / flock / timeout; `/doctor` probes `deps.bash4|flock|timeout`; shared `lock_run` (flock → mkdir fallback), `sha256()` and `_timeout()` helpers | M |
| **Smoke harness scope** | Add `agents/*.md` (frontmatter incl. `effort`), `githooks/`, root and `tools/*.sh` | S |
| **Input-safety convention** | AGENTS.md rule + helpers: argv/env for Python, `?` params for SQL, roster-regex for `--agent`, heredoc capture for `$ARGUMENTS`, per-run nonce delimiters for prompt data | S |

### Wave 2 — Structural (≈ 2–3 weeks)
| Proposal | Detail | Effort |
|---|---|---|
| **Deterministic code out of prose** | retro → `discover.sh`, `parse-results.py`, `classify.py`, `scheduled-run.sh` (~−1,500 lines loaded); memory distill/validate pipelines → scripts; bug-hunt S0/S3a parse/load → `parse-args.sh`/`load.sh` with behavioural tests | L |
| **Router + on-demand modes** | `commands/memory.md` → ~120-line router + `modes/*.md` (−15k tokens/run); `commands/spec.md` → router; `commands/council.md` → move tier-grading (§1.5) and `--blind` path into skill files; epic/kickoff → `steps/` like orchestrate; bug-hunt → `reference/s1…s4.md`; init-orchestration hook bodies → `templates/*.sh` (shellcheck-able) | L |
| **PDH once per invocation** | Resolve PDH in Step 0 and cache to `$MROOT/.claude/.pdh` (stanza as fallback) or a managed include; must respect the SPEC-002 CDT-233 irreducibility verdict — cache, don't delegate | M |
| **Shared agent preamble** | Output-intensity block → managed include; single root-derivation line in the memory protocol partial; unify the agent embed resolver with PDH | M |
| **Council integrity** | Real finalize validation (taxonomy, confidence 0–100, verbatim quotes, exit 7) + apply `confidence_filter_threshold`; split jaded-senior into prosecutor vs `adversarial-ic` investigator; drop or tool-write the LLM evidence cache; Workflow parity (Phase 3, `--external`, `finder`, tokens) or explicit fallback | M–L |
| **Orchestration correctness** | Unify task keys on plan index; `ready-set --prefix`, skip corrupt files; write `in_progress` at spawn; filter TaskCompleted hook candidates; autopilot branches for Step 5 / bounded QA loop / real `ITER`; exact-match `resume-state` | M |
| **Memory design** | Fix tier-0 eclipse (always load tier-0 newer than last digest); import seed packs as untrusted/tier-0 with confirm; consistent `-cmd .timeout 5000`; verify extension hashes at `.load`; cosine metric; atomic migrate-v2 + pre-migration `VACUUM INTO` backup | M |
| **Transcript/handoff** | Crash-safe mirror rebuild; one project-dir encoder in `hosts.py`; single `locate` per handoff; `umask 077` + gitignore + redaction; mirrorlib shared parsing | M |

### Wave 3 — Quality & UX (ongoing)
- Docs: add the 7 missing pages; fix README index; global stale-wording pass;
  replace cwd-relative `bash skills/…` in runbooks; move maintainer evidence
  (`handoff-stm-dogfood`, permission matrix) to `docs/internal/`.
- `user-invocable: false` on internal skills; resolve 9 command/skill name
  collisions; rewrite skill descriptions to lead with "Use when …"; rename
  `code-simplify` (clashes with built-in `/simplify`).
- `/worktree release` and `/wrap-ticket`: show unmerged/unpushed count, require
  typing the slug when non-zero.
- `security-scan`: scan staged + untracked, `cd "$WTROOT"`, report truncation and
  semgrep status, optional gitleaks/osv-scanner.
- `craft-loop`: `check-program.sh` validator, `retire` mode, journal compaction
  rule, a `target: goal` example, fix backlog-burn status tokens, `$MROOT` library.
- `doctor.sh` split into `checks/<group>.sh`; `release-train` unblock path;
  `ci-watch` poll-error cap; council `external-reviewer` timeout + gemini sandbox.
- Strip changelog/ticket-history prose from instruction files (council, spec,
  memory, retro); SECURITY.md supported-versions table; re-run permission probe
  for current CC.

---

## 6. Suggested ticket slicing

| Ticket | Contents | Bump |
|---|---|---|
| T1 memory-safety | P0-1, P0-5, P0-6, P0-7, P0-18, memory-recall P0-4 | patch |
| T2 git-safety | P0-2, P0-3, `git-safety.sh`, worktree release / end-state / wrap-ticket guards, `--tags` push, bump-class index read | patch |
| T3 council-integrity | P0-4 (council, review-and-commit), P0-12…P0-16 | patch |
| T4 setup-agents | P0-9, P0-10, P0-11, P0-20, distiller atomicity | patch |
| T5 retro-scheduled | P0-8 + scheduled-lock atomicity + arg-parse loops | patch |
| T6 mirror-perf | P0-19 + crash-safe rebuild | patch |
| T7 debug-gates | P0-17 + Step 0c path guard | patch |
| T8 ci-all-tests | Wave 1 CI, red-suite fixes, spec-lint | patch |
| T9 lint-rules | skill-lint C6–C9 + smoke scope | patch |
| T10+ | Wave 2 items as individual minors where a Surface changes | minor |

Per AGENTS.md, work lands on `feat/<ticket>` branches and folds through `/release`;
none of this review's proposals were applied in this change.
