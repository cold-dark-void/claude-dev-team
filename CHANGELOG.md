# Changelog

All notable changes to **claude-dev-team**, newest first.
Authoritative version history. Prefer **`/release`** to add `### vX.Y.Z` headings.
Pre-written headings (release-train M5c, orchestrate version-sync tasks) are kept
via skip-if-present when `/release` is given an explicit version — do not invent a
second heading for the same version.

### v1.8.2
- **`/wrap-ticket` prunes remote `feat/` branches** — after local worktree release, `git push origin --delete feat/<ticket>` and `feat/epic-<ticket>` (fail-open). Local remove alone left remotes behind.

### v1.8.1
- **Grok `/retro` gate sees real user text** — unwrap `<user_query>` before S1/S5 word-count and regex; S1 lexicon adds `wtf` / `fuck(ing)` / `why merge` / `why would you`. Weights/caps/threshold unchanged. Fixture Grok-UQ score 7.0. SPEC-012.

### v1.8.0
- **`/audit` instruction-stack Surface (CDT-200/201)** — new `/audit` command: read-only inventory of CLAUDE.md/AGENTS.md/directives + skill-size WARN (30KB); `apply` is approve-then-apply on instruction-stack files only with mechanical evidence. Dual-host Grok user-global `~/.grok/AGENTS.md`/`CLAUDE.md`; `--yes` covers `~/.claude` and `~/.grok`; `--from-session --json` stdout is one JSON document (locate on stderr); MROOT via `git -C --cwd` (no invoker-cwd leak); apply uses `realpath` so a symlink into `skills/**` is refused. SPEC-035. `/doctor` pointer. No `reinit`.
- **Master bump-class hook** — `githooks/pre-commit` + `check-bump-class.sh`: a new `commands/*.md` on master / `/release` requires minor or major, not patch. CI `bump-class` job. SPEC-010 B1–B6.
- **STM Product surfaces + Open ship gaps (CDT-198)** — assemble fail-closed unless both headings appear in State now (cold/warm/light). Miner facets; `_unspecified_` when untagged.
- **Orchestrate router + `/handoff --light` thin profile (CDT-199)** — `skills/orchestrate/SKILL.md` is a 50-line router; phase bodies in `steps/*.md`. Light path Reads `LIGHT.md` only (not full SKILL).
- **CDT-46 freeze marked historical (CDT-197)** — `v1.0.0` is tagged; AGENTS.md no longer binds master to CDT-46-only.

### v1.7.36
- **CONTEXT.md glossary ships on the feature branch, not dirty master** — brainstorm Step 4b records a plan `## Domain glossary delta` and commits only inside a ticket worktree (no durable uncommitted `$MROOT` dirt). `/orchestrate` Step 3b promotes MROOT/plan deltas into `$WT_PATH` + commits `context: <id>`; Step 6b mirrors kickoff 7b; squash/land glossary gate forbids excluding `CONTEXT.md` or leaving master-only dirt. `domain-glossary` + kickoff 7b document promote-and-restore. Fixes the XYZ-323 class failure (specs on worktree, glossary stuck dirty on master).

### v1.7.35
- **`--autopilot=master` land-no-release (CDT-195)** — third ship terminal: flag-only sentinel `bump:"master"` squash-lands onto the worktree baseline / `origin/HEAD` without PR or `/release` (commit + non-force push; ship-history + Done). Release path (`=patch|minor|major`) and bare PR-stop unchanged. SPEC-033 M2/M4/M13/N3a + `parse-flags`/`append-card`/`resume-state` enum, self-answer F13, end-state §5b dual branch, orchestrate Step 11/resume-ship context-aware.

### v1.7.34
- **skill-lint C1 on /retro multi-host Step 2 (CDT-156 CI)** — re-parse `MODE`/`EXPLICIT_SID`/`HOST` at start of discovery fence; split multi-name `local` into separate lines so C1 sees `_sid`/`_src` defs. Unblocks CI `skill-lint` after v1.7.33 (3 unwaived C1 findings).

### v1.7.33
- **Multi-host /retro adapters Claude+Grok MVP (CDT-156)** — `transcript-parse` host adapter surface (`hosts.py` locate/normalize): Claude identity path + Grok cwd-bucket discovery (`chat_history.jsonl`) with scoring normalize (tool_result + `write`→Write / `search_replace`→Edit + `exit:N≠0` → `is_error`). `/retro --host claude|grok|all` with auto-detect and live `HOST_CWD` (WTROOT); Filter-1 freshness on source; no Claude fallback on explicit Grok miss. SPEC-012 multi-host MUSTS amended; Claude gate weights unchanged; Grok friction fixture + locate/normalize suites green; handoff `grok-to-claude-jsonl` thin wrapper `mode=handoff`.

### v1.7.32
- **Ship-history cleanliness gate (CDT-188)** — `check-ship-history.sh` enforces one-commit-per-tag (D1–D4) in ship window W; dirty prints exact `history dirty — rewrite needed`. Wired into `/release` (Step 0.5/5.5), autopilot end-state (§3.5/§5.5), and `/orchestrate` Step 11–12 so Done / Orchestration complete cannot claim while fixup noise remains. Interactive rewrite needs confirm before force-push; autopilot halts (no silent force). SPEC-010 H1–H12 owns the predicate (cite-not-fork). H11 fixtures: 33 ship-history + staged-path suite green.

### v1.7.31
- **skill-lint C1 on release Step 5 staged-path fence (CDT-189 follow-up)** — re-resolve `PDH` inside the Step 5 `check-staged-paths.sh` bash block (fresh shell; SPEC-021 C1). Unblocks smoke `skill-lint` after v1.7.30.

### v1.7.30
- **Release staged-path hard gate (CDT-189)** — `/release` Step 5 now runs `skills/release/check-staged-paths.sh` after intentional `git add` and before `git commit`. Allowed staged set = version pair (`CHANGELOG.md`, `.claude-plugin/plugin.json`) ∪ `--intended` product paths ∪ optional `--allow-extra`. Foreign staged paths → exit 1 (list every path), no commit/tag/push; unstaged/untracked dirty is ignored. SPEC-010 S1–S9; `skills/release/test.sh` 17 cases.

### v1.7.29
- **Escape EMBED_MODEL in migrate-md.sh SQL (CDT-190)** — same class as CDT-164/`embed-one.sh`: after model resolution (outside the per-row loop), apply `:-all-MiniLM-L6-v2` then single-quote-double into `EMBED_MODEL_ESC` for the `embedding_meta` INSERT only; provider body still gets the raw name via `jq --arg`. SPEC-004 Version History records the fix.

### v1.7.28
- **Seed-pack manifest side-channel integrity + empty content_hash hard reject (CDT-194)** — a `files` key containing newline or TAB split the tab-delimited `FILE_LIST` so the hash field emptied and `[ -n "$expected_hash" ]` skipped verification. Preparse now rejects non-exact roster keys and control-char keys before the side channel is written; empty/missing `content_hash` is a hard reject; side channel uses `|` so empty middle fields survive bash IFS. SPEC-024 M8/M12 wording (trailer roster → M8; symlink warn ≠ roster). Tests CDT194a–e; suite 114/0.

### v1.7.27
- **Seed-pack trailer must match file agent (CDT-193 / SPEC-024 M13)** — after CDT-174/176 roster allowlists, import still trusted a well-formed trailer `agent=` for the write sink, so `pm.md` could declare `agent=tech-lead` and store content under the wrong agent. Import now requires exact equality between the trailer `agent=` and the manifest filename stem after M12 roster checks and before hash/sanitize/insert; mismatches reject with a warning that names both ids, increment `rejected`, and never rebind to either agent (DB or fallback). `export-seed-pack.sh` unchanged (already writes matching pairs). SPEC-024 gains normative **M13**; `test-seed-pack.sh` adds M13a–d (SQLite cross-agent, fallback cross-agent, match regression, partial-file match+mismatch); suite 91/0.

### v1.7.26
- **close.sh slug charset guard before path construction (CDT-192)** — same `^[A-Za-z0-9_-]+$` guard as CDT-175/`reconcile.sh`/`worktree-lib validate_slug` at every site that builds `.claude/backlog/<slug>.md` (`find_slugs` direct match, dir-scan basename, index-link resolve, verify, close, update_index). Invalid/traversal-only hits fail closed non-zero with no filesystem ops outside the backlog dir; free-text title QUERY still works when it resolves to a valid slug. Regression tests (hostile index + outside canary + valid sibling under hostile index); SPEC-009 normative block + Version History.

### v1.7.25
- **TaskCompleted multi-true compound preference is lex-asc basename (CDT-186)** — when bare task id `T` matches ≥2 task-meta compounds with `requires_council: true`, preferred basename `P` for isolate index lookup is `min(stems)` (lexicographic ascending), not first-in-glob order. Flat true still loses to any true compound. No multi-key score union (CDT-163). SPEC-002 + init-orchestration META_SCAN template + B11/B11b/B12 regression tests.

### v1.7.24
- **Ship-gate process stamps + technical-only claim (CDT-185)** — M14 ship-gate no longer compounds process assertions (QA PASS / Step-10b) into the council claim. Autopilot pre-flights process stamps = clean ship-choice card #1 via `read-cards.sh` (stamp shape in SPEC-033 M14(a)); stamp fail skips `/council` and records card #2 BC7 conf=0 (reuse BC7, not a 9th BC). Stamp pass → technical-only claim under audit (merge-base diff vs ACs/spec); locators-only / no RAW_ARTIFACTS injection preserved. M14(d) degraded path unchanged. Procedure: `skills/autopilot/ship-gate-council.md` §2a/§3b/§7. Contract tests in `skills/autopilot/test.sh` (av–bd); suite 84/0.

### v1.7.23
- **Seed-pack target-agent resolution dead-branch cleanup (CDT-174 / CDT-176 follow-up)** — behavior-preserving clarity patch, no logic change, suite unchanged at 71/71. `seed_parse_trailer()`'s regex requires `agent=<non-space>+`, so a successfully parsed `SEED_AGENT` is never empty (an empty one fails parsing and is rejected as an unparseable trailer). CDT-174's v1.7.22 trailer-agent roster gate therefore rejects every non-roster id *before* flow reaches the `target_agent` resolution point, which made both the `local target_agent="$agent"` filename fallback and the following `seed_is_valid_agent "$target_agent"` re-check unreachable — CDT-176's headline call-site guard was silently no longer the code doing the work, and the fallback branch read as a live path that can never be taken. The fallback is removed and the re-check is kept, relabelled as an explicit backstop so a future change to trailer parsing or target selection still cannot reach the SQL/filesystem sinks unvalidated. Also records that a trailer naming a roster agent other than its own file is deliberately *not* rejected here (that is CDT-193). Defense-in-depth guards inside `insert_db()`/`insert_fallback()` are untouched — they remain reachable preconditions for other callers.

### v1.7.22
- **Seed-pack manifest-key roster guard + symlink refusal at both import sinks (CDT-174)** — `import-seed-pack.sh` joined a manifest `files` key to `SEED_DIR` unvalidated, so a hostile pack manifest could name `../../…/outside.md` and have the importer read and import a file from an arbitrary path outside the pack (CDT-176's v1.7.20 fix guarded the *trailer* `agent=` id before the SQL and fallback-write sinks, but not the *manifest key*, which is the read sink — demonstrated live: the same hostile pack imports the escaped file on v1.7.21 and rejects it with this fix). SPEC-024 gains M12: manifest keys must be exactly `<agent>.md` for a `seed_agents()` roster member, validated before any path is constructed, and both import sinks now refuse symlinks (the pack file at the read sink; the agent memory dir/`lessons.md` at the fallback write sink — closing a hash-free write primitive, since M3 excludes the trailer from the entry hash). Rejections warn one line and count into `rejected=`; roster validation stays out of `seed_parse_trailer` per M12. New `test-seed-pack.sh` regression harness wired into CI as a fifth `smoke.yml` job — combined suite 71/71 after reconciling with CDT-176 (one canonical `seed_is_valid_agent()`); QA adversarially validated with 16 hostile manifest-key shapes (112 assertions) and 12 hostile trailer agents × DB/fallback modes (156 assertions), all rejected before any path construction, plus a full 7-agent valid-pack round trip in both modes (no over-strictness; hyphenated `tech-lead` passes).

### v1.7.21
- **Backlog slug charset guard before reconcile fs ops (CDT-175)** — an index-row slug is untrusted input that `reconcile.sh` turned directly into a path under `.claude/backlog/`, so a crafted row like `backlog/../../../etc/foo` could reach the existence check and the terminal-item `rm` outside the backlog directory. Slugs are now validated against `^[A-Za-z0-9_-]+$` (the same charset `worktree-lib.sh` `validate_slug()` enforces) before any `-f` test, read, or delete; an invalid row never reaches the filesystem, survives verbatim in the rebuilt index (it is *not* a dead reference — reconcile never looked for its file, so it has no evidence to prune on), and is reported as an `INVALID slug` action needing manual triage, re-reported on every run under the open-orphan idempotency precedent. `--linear-verdicts` slugs (lookup-only keys) and orphan-scan slugs (derived from real directory entries) are deliberately unguarded — neither can introduce a path. 16 regression assertions added (case n: traversal slug untouched inside and outside the store, row survival, idempotent second run, dry-run notice); SPEC-009 gains the normative slug-charset validation block, an idempotency clarification, an acceptance criterion, and a Version History row.

### v1.7.20
- **Seed-pack agent id closed-set allowlist before SQL + path sinks (CDT-176)** — a hostile memory seed pack could supply an unvalidated agent id (the trailer `agent=` field, or the pack filename) that reached a raw `sqlite3` `INSERT` unescaped in `import-seed-pack.sh`'s `insert_db()` (multi-statement SQL injection) and a filesystem path build in `insert_fallback()` (directory traversal outside `.claude/memory/`) — `content`/`metadata_json` were already escaped, `agent` was the sole unescaped interpolation. Fixed with a new `seed_is_valid_agent()` in `seed-common.sh`, validating the resolved agent id against the existing closed-set `seed_agents()` roster (the same 7 canonical agents already enforced as the export-side trust boundary) before either sink is reached — enforced at the `target_agent` resolution point (does the SPEC-024 M8 reject accounting) plus defense-in-depth guards inside both sink functions. 5 regression cases added to `test-seed-pack.sh` (SQL injection, path traversal in both DB and fallback mode, apostrophe non-member, valid-agent no-regression); the flagship SQL-injection case was mutation-tested (verified it actually fails without the fix — an earlier payload variant silently passed regardless of the fix, since a column-count mismatch aborted the statement before reaching the injected `DROP TABLE`). SPEC-024 M8 extended with the agent-id validation contract.

### v1.7.19
- **Extension SHA-256 re-verification on every run (CDT-173)** — `download_and_extract()` and `download_file()` in `skills/memory-store/download-extensions.sh` unconditionally skipped integrity checking whenever the destination file already existed, so a tampered or corrupt on-disk `vec0.so` / `lembed0.so` / `all-MiniLM-L6-v2.gguf` was `.load`ed forever (a partial regression of the CLUSTER-010 fail-closed guarantee — verification was once-ever, not per-run). Present files are now re-verified against their pinned SHA-256 before being skipped; a mismatch, missing pin, or missing hash tool deletes the file and falls through to a normal re-download (fail closed). Adds a second pinned table, `expected_member_sha256()`, covering the SHA-256 of the *extracted* `.so`/`.dylib` member (the existing table only pins the source tarball) — verified both on a present file and again immediately before `mv`ing a freshly extracted member into place, which also closes a latent defect where a stray non-binary tarball member (e.g. a bundled `LICENSE`) could be installed as long as the tarball hash still matched. No change to the existing no-block-on-failure guarantee (`|| true` at all three call sites; helpers still return non-zero, never `exit 1`). SPEC-005 updated to match the new fail-closed contract.

### v1.7.18
- **Escape EMBED_MODEL before SQL interpolation (CDT-164)** — `embed-one.sh`'s remote-embed path interpolated `EMBED_MODEL` raw into a SQL `VALUES` literal (SPEC-004 SQL-safety MUST violation); an apostrophe in the model name aborted the sqlite batch mid-write, leaving an orphaned `vec_memories_<dims>` row with no `embedding_meta` and a stale `embedding_dimensions`. Fixed by mirroring the file's existing `CONTENT_ESC` quote-doubling pattern into a new `EMBED_MODEL_ESC`, used only in the SQL literal — the provider JSON body still keeps the raw name via `jq --arg`; also corrected a misleading partial-batch warning. `migrate-md.sh` carries the same defect at its own `embedding_meta` INSERT, tracked separately as CDT-190 (not fixed here). SPEC-004 updated with the governing MUST/MUST NOT block.

### v1.7.17
- **plugin-dir version-segment ranking (CDT-166)** — tier-4 `find|path_ver_pick` ranks by `/dev-team/<VER>/` (not full abs path); equal VER prefers `cold-dark-void`; bootstrap PDH stanza C5 mass-update + multi-slug tests; SPEC-002.

### v1.7.16
- **Council finalize strikes missing `tool_use_id` (CDT-178)** — finalize packaging partitions findings/bundles with blank/absent/whitespace `tool_use_id` into the struck audit trail (append-merge, never silent drop); unstruck-only commit gate, severity tables, action items, and `max_*_confidence` via finalize-meta sidecar; regression `test-finalize-missing-tid.sh` (29 asserts) + SKILL strike clarifier.

### v1.7.15
- **TaskCompleted index isolate scores (CDT-163)** — resolve at most one council index key (exact → preferred compound only → unique suffix); multi-key max-merge removed; preferred miss / multi-suffix hard-fail exit 2; SPEC-002 + template + B6–B10 tests. Live hooks: re-run `/setup orchestration`.

### v1.7.14
- **Docs dead links + D10 docs-page-links (CDT-180)** — retarget `docs/commands/epic.md` `/release` → `skills/release/SKILL.md` and `mode.md` legacy focus/blunt to in-page anchors; add docs-drift `docs-page-links` check (SPEC-010 D10) with bite-tests so relative `*.md` hrefs under `docs/commands/` fail closed.

### v1.7.13
- **Index-writer confidence floor-normalize (CDT-181)** — accept JSON number conf (int/float), floor to 0..100 via jq before index write; non-numeric / OOB fail closed without mutate; engine/tests + SPEC-013 note.

### v1.7.12
- **Shared terminal-status classifier for close/reconcile (CDT-160)** — one `skills/backlog/terminal-status.sh is-closed` matcher (token-boundary, not unanchored substring); wires `close.sh` + `reconcile.sh`; DONE/CANCELLED parity for verify/Already-closed/prune; write surface still COMPLETED|FIXED/CLOSED only; unit+integration tests (87+59) + SPEC-009/SKILL.md.

### v1.7.11
- **Bare-id task-store stub cannot shadow compound council meta (CDT-167)** — `update-status` invents bare `rc:false` only when no `*-<id>.json` exists (unique compound → redirect update; multi → fail closed); TaskCompleted template uses any-true over flat∪suffix candidates so historical bare stubs no longer silent-pass; SPEC-002/009/017 + `task-store-test.sh` (22 cases). Live hooks: re-run `/setup orchestration`.


### v1.7.10
- **Epic state.json RMW flock (CDT-165)** — `epic-lib` serializes all `state.json` mutators with exclusive `flock` on `.claude/epics/.lock` covering full read-modify-write (re-read under lock); `write_state` stays unlocked tmp+mv; compound cmds keep external I/O outside the lock; concurrent bite-test + SPEC-025 M6 MUST.

### v1.7.9
- **Retry ensure create-path worktree add on EBUSY (CDT-161)** — `cmd_ensure` wraps both `git worktree add` arms in `git_retry 3 200` (parity with release); failed `-b` re-probes branch and falls back to plain add; tests pin AC-1 (RETRY_ADD≥3 + re-probe) and AC-3/4 EBUSY shim; SPEC-016 MUST + Test + VH.

### v1.7.8
- **Refuse STALE ensure reclaim when dirty or live task (CDT-162)** — `worktree-lib ensure` no longer overwrites a STALE `.wt-lock` on dirty trees or when `slug_has_live_task`; shared `is_worktree_dirty` with `release`; SPEC-016 STALE MUST + T7/T8/T9 tests (clean reclaim / dirty refuse / live-task refuse).

### v1.7.7
- **EPIC-ID path charset guard (CDT-169)** — `epic-lib` rejects ids outside `^[A-Za-z0-9_-]+$` (exit 64) in `epic_paths` and `assert-release-allowed` before any `.claude/epics/` path join; SPEC-025 M6 MUST + charset bite-tests (`../` and peers).

### v1.7.6
- **Gate `seal --abort` on dirty main (CDT-170)** — bare `--abort` refuses non-empty `git status --porcelain` on main (exit 1, zero `reset`/`clean`, WIP preserved, including `already_sealed`); `--abort --force` MAY wipe; squash/hook same-invocation recovery still ungated; handoff `on_failure` and B.7 failure fence use `--force` after staged seal. SPEC-025 M14 C5 + tests (`c5-abort-dirty`).

### v1.7.5
- **Align TaskCompleted dual-shape gate docs with CDT-122 (CDT-183)** — SPEC-013 no longer forbids `finding[]`/`max_finding_confidence` rows; SPEC-002 L30 matches L36 dual-shape; orchestrate + council skill/command drop the false "finding[] deadlock" story. Claim-scope remains the orchestrated task-gate **policy**; live hook/template behavior unchanged.

### v1.7.4
- **Fix release-train install paths (CDT-171)** — `commands/release-train.md` and `skills/release-train/SKILL.md` resolve `train-lib.sh` via `plugin-dir.sh` (PDH bootstrap) instead of cwd-relative `bash skills/release-train/…`, so marketplace/cache installs work. SPEC-023 M12 requires install-aware resolve; `train-lib.sh` behavior unchanged.

### v1.7.3
- **Fix standup WAITING fence path (CDT-168)** — `skills/standup/SKILL.md` Step 4 WAITING-dep status resolves `skills/orchestrate/dag-lib.sh` (which implements `status-of`) instead of nonexistent `skills/task-dag.sh`. SPEC-002 resolution-site table row 17 drops the phantom `TASK_DAG` path; single `DAG_LIB` for both `ready-set` and `status-of` (soft fail-mode unchanged).

### v1.7.2
- **Fix vec0 extension path in `/memory validate --reconcile` (CDT-172)** — `skills/validate-memory/reconcile-lib.sh` no longer double-`dirname`s `memory.db` into nested `.claude/.claude/memory/extensions`. Derives `ext_dir` as sibling-of-memdb (`$(dirname "$MEMDB")/extensions`), matching `embed-one.sh` / `download-extensions.sh`, so KNN can load an installed `vec0` instead of silently falling back to keyword. Regression tests cover path-correct → `method=embed`, absent / nested-wrong-path → `method=keyword`.

### v1.7.1
- **Fix stale "DEPRECATED / disappears at v1.1" discovery copy on protocol-retained backends** — `skills/{init-orchestration,scaffold-project,standup,fix-ticket}` frontmatter + hub/docs/spec wording now describe them as permanent internal skill-delegate backends for `/setup`, `/status standup`, and `/debug ticket` (v1.1 deleted the old slash commands, not these bodies). Stops skill discovery from advertising a removal that was never supposed to happen.

### v1.7.0
- **`/bug-hunt` full stages 1–4 (CDT-97 epic)** — productized July bug-hunt playbook as a first-class surface: discover → refute/confirm → findings plan + proceed-gated backlog materialize → phased `/orchestrate`|`/epic` handoff with user locks. Thin `commands/bug-hunt.md` + `skills/bug-hunt/` protocol; process under `.claude/bug-hunt/` (gitignored). Static suite `skills/bug-hunt/test.sh` (206 checks).
- **SPEC-034 bug-hunt product contract (CDT-97-C1 / CDT-140)** — DRAFT core spec locks surface, stages/locks, finding model (`locator`/`severity`/`description`/`evidence`/`status`), floor filter, composition boundaries, phase-done metrics, when-to-use matrix, non-goals; runtime add-ons M31–M48 (discover-refute, materialize, stage-4 handoff) + Covers for command/skill.
- **Stages 1–2 discover + refute (CDT-97-C2 / CDT-136)** — path scope + `--severity-floor` (default `nitpick`, loud fail); SPEC-013 blind-compose multi-perspective discover; ≥2-flavor investigator refute; confirmed-actionable report + SHOULD findings.json intermediate.
- **Stage 3 findings plan + bh-* backlog materialize (CDT-97-C3 / CDT-138)** — load C2 artifacts; plan at `…-plan.md`; M8 proceed (`--proceed` or typed token) before any create; SPEC-009 programmatic dual-write only; self-contained bh-quality bodies; plan↔item linkage; M22 phase-done; zero-actionable clean path.
- **Stage 4 phased handoff + locks (CDT-97-C4 / CDT-139)** — severity-band phase plan (critical→warning→nitpick); per-phase handoff templates; M18 route (`/orchestrate` default; `/epic` when ≥2 phases ∧ ≥2 items); M9 start-phase-0 and between-phase locks; emit-only pasteable commands (never auto-spawn/fix); M23 handoff phase-done + resume identity.
- **Surface + docs (CDT-97-C5 / CDT-137)** — full args (`materialize` / `handoff` / `--proceed` / `--start-phase`); docs/commands page (when-to-use, stages, outputs, locks, non-goals, smoke); README + docs hub Core index.

### v1.6.3
- **Linear lifecycle: Done only on master / wrap** — PR-stop and off-master ship set Linear **In Review** (not Done); **Done** only after squash/merge/`/release` lands on master, or `/wrap-ticket` post-merge (idempotent). Fixes Done-before-master footgun. SPEC-009 + orchestrate Step 11 + wrap-ticket + end-state + epic sync status map (In Review stays open for walkers).

### v1.6.2
- **M15 `/epic sync` — refresh stale `state.json` from Linear** — explicit `sync <EPIC-ID> [--dry-run]`: inventory parented issues, fill null `linear_id`/`linear_project_id`, pull status forward; never re-open `completed`; orphans report-only (no auto-add); MCP down → M5 notice + zero mutation. Mechanical `epic-lib sync-apply` (session owns MCP); resume tip only (no auto-sync). SPEC-025 M15 + skill Mode F + commands/docs + tests.

### v1.6.1
- **M4.1 link-before-create for `/epic` dual-write** — before any child `save_issue` create, inventory `list_issues(parentId=<EPIC-ID>)`; adopt a unique title/`child_id` map (zero creates), HALT on ambiguous parented children (refuse silent second set), create only when zero survivors; inventory failure skips Linear creates (local continues). Autopilot never force-creates. SPEC-025 M4.1 + skill protocol + presence tests (CDT-141 dogfood: E1–E7 already under parent when local state empty).

### v1.6.0
- **CDT-141 — `/epic --worktree` + `--release <bump>` (one master commit)** — locked CLI for epic integration worktree + end-of-epic seal: bare `--worktree` and `--release patch|minor|major` (space or `=`), illegal combos exit 64 with zero side effects, durable `worktree_enabled`/`release_bump` on epic state.
- **Integration worktree + shared child tree** — `ensure-integration-worktree` creates/reuses `.worktrees/epic-<ID>` (`feat/epic-<ID>`); `ensure-ticket-worktree` routes children into the shared tree (no per-child worktrees); wrap-ticket must not release the integration slug.
- **Mid-epic release forbid + seal** — `assert-release-allowed` hard-fails mid-epic `/release` and master-merge when `release_bump` is set; `seal`/`seal-ready` squash-stage then one `/release <bump>` with `EPIC_ALLOW_SEAL_RELEASE`; resume honors stored modes or conflicts at exit 64.
- **SPEC-025 M14 + surface docs + 457 bite-tests** — full CLI/semantics/illegal/done-when tables; commands/skill/docs hub updated; `skills/epic/test.sh` covers parse through seal.

### v1.5.14
- **CDT-129 — S5 approval tokens do not suppress negated friction** — `approve`/`accept` (and other any-word allowlist tokens) no longer suppress S5 when a negation co-occurs (`dont accept`, `no, accept`). Bare `approve`/`accept` and `accept, anything else?` still suppress. Apostrophes normalized (`don't` → `dont`). Fixture + tests updated.

### v1.5.13
- **CDT-134 — M14(d) infra-vs-evidentiary design note (no behavior change)** — document open design for a future "infra-degraded" class without implementing ship-clearing. Safe interim: keep BC7 halt + confidence=0; reduce spawn flakiness (CDT-133); human override only via `--resume-ship` (CDT-135).

### v1.5.12
- **CDT-133 — Prefer named dev-team agents for council Task spawns** — investigators/phase-4/brief writers/extractors/blind reviewers prefer `dev-team:ic5`/`ic4` over bare `general-purpose` (dogfood: named agents 9/9 final output vs GP flaky). Fallback chain retained. Completion: final-message JSON required; max 2 re-requests before spawn-failure degradation.

### v1.5.11
- **CDT-135 — Resume ship after BC7 override** — `/orchestrate <ISSUE-ID> --resume-ship[=<bump>]` (or in-session `resume ship <bump>`) runs one human-confirmed sequence: end-state `/release <bump>` then `/wrap-ticket`. BC7 halt now prints the resume hint. Autopilot MUST NOT self-answer the confirm step.

### v1.5.10
- **CDT-132 — executable signal respects material LOC** — `tier-grade.sh` signal 2 (mode 100755) no longer forces `council_tier=full` for tiny content-only edits to already-executable files (`< BAND_LOW_LOC` LOC, mode unchanged). Mode flips, renames/copies of executables, shebang-only detection, and material LOC still fire clear-high. Addresses 63-LOC ship-gate over-grade class from CDT-124.

### v1.5.9
- **CDT-123 — Notify-on-blocked/done for /kickoff and /epic** — wired the same `skills/notify/webhook.sh` Tier B fail-open pattern as CDT-111-C7/`/orchestrate`: `task_blocked` on autopilot halts (kickoff OQ/API-verify/>4-OQ/breaking-schema; epic A.5 + B.3), `task_complete` on successful kickoff summary and epic A.6 persist. Unset `AGENT_WEBHOOK_URL` remains silent.

### v1.5.8
- **CDT-125 — S3 edit-loop requires struggle evidence** — `retro-gate/gate.sh` S3 no longer fires on error-free multi-edit streaks (multi-section doc authoring on existing or new files). S3 now requires an intervening `tool_result is_error` or S1 user rejection inside the edit window. Supersedes the Write-only clean draft-polish exemption (still covered). AC3 fixture flipped to expect S3=0; AC4/AC5 still require S3 with error/S1.

### v1.5.7
- **CDT-122 — TaskCompleted council gate: compound keys + finding[] confidence** — index lookup now mirrors task-metadata compound-key fallback (bare TaskUpdate id `7` resolves rows under `CDT-…-7`); `finding[]` rows with `max_finding_confidence` pass the gate the same as `verdict[]` `max_verdict_confidence` (diff-mode `requires_council` IC reviews no longer structurally blocked). SoT: task-completed template in `skills/init-orchestration/SKILL.md`; SPEC-002 updated. Re-run `/setup orchestration` to regenerate live consumer hooks.

### v1.5.6
- **CDT-128 — tier-grade.sh quality debt (confirmed pair)** — `fail_closed()` sanitizes all `[[:cntrl:]]` (not just \\`/"/LF/TAB) so a CR in a path cannot emit invalid JSON; `post_image_head()` strips NUL before capture so binary blobs no longer spam bash "NUL" warnings under command substitution. Regression tests for both. Re-triage of the other delta-review nits: FILES==0 guard still useful defense-in-depth; middle-band REASON overwrite is intentional for LOC_UNAVAILABLE; sha all-zero guard stays; leftover nits deferred.

### v1.5.5
- **CDT-130 — Wire `skills/retro-gate/test.sh` into CI** — added a fourth independent job `retro-gate` on `.github/workflows/smoke.yml` (push/PR to master), running `bash skills/retro-gate/test.sh` byte-identical to local runs. Closes the SPEC-012 gap where friction-heuristic regressions were manual-only; same pattern as CDT-96 for `skill-lint` / `docs-drift` (no `needs:` chaining).

### v1.5.4
- **CDT-131 — Version sync is a pair, not a triplet** — practice since `9f3ea07` only bumps `CHANGELOG.md` + `plugin.json`; `marketplace.json` pins install channels via git refs (`stable`/`master`) and no longer carries `plugins[].version`. Docs and contracts now match: `skills/release/SKILL.md`, `AGENTS.md`, `README.md` Versioning, SPEC-002 / SPEC-010 / SPEC-022 / SPEC-023, release-train renumber/M5d (update marketplace version only if already present — never invent one).
- **`/doctor` version check** — `version.triplet` check id kept for callers, semantics are pair-only (`plugin.json` ↔ `CHANGELOG`). Fixes a standing FAIL on healthy checkouts after the marketplace field was removed.
- **CHANGELOG header** — documents skip-if-present for pre-written headings (release-train M5c / orchestrate) instead of forbidding all hand-written headings.

### v1.5.3
- **CDT-124 — Fix `retro-gate/gate.sh` S5 false positives on terse approval tokens** — after a long assistant turn (≥500 chars), a short user reply is scored as friction signal S5 unless it's on the `is_approval` allowlist. `"approve"`/`"accept"` were missing from that allowlist and got misclassified as friction. Added.
- **New single-token `"y"` guard** — a bare `"y"` message (word count exactly 1) is now treated as approval too, but only as the *whole* message: `"y tho"` and `"y not"` still register S5, since those are real pushback that happens to start with `y`. The `y` check tests the whole message instead of joining the allowlist, which matches any word in a <=3-word message — that separation is what keeps it from swallowing genuine short-form friction.
- New regression fixture `skills/retro-gate/fixtures/s5-approval-tokens.jsonl` + `skills/retro-gate/test.sh` case covering `y`/`approve`/`accept` suppression and confirming `y tho`/`y not` still fire S5.
- `skills/retro-gate/SKILL.md` updated to document the `is_approval` allowlist and correct two stale claims (trailing-only strip → leading/trailing; "immediately after" → no reset on user turns).

### v1.5.2
- **Fix — remote embedding model fell back to empty instead of the DB config** — `skills/memory-store/embed-one.sh`, `skills/memory-store/migrate-md.sh`, and `skills/memory-recall/SKILL.md` all read `EMBED_MODEL` as `${EMBEDDING_MODEL:-}`, so when the `EMBEDDING_MODEL` env var was unset the model name silently went empty instead of falling back to the durable `embedding_model` value already stored in `config`. All three now resolve `EMBED_MODEL` as env-if-set-else-DB-config, matching how `EMBED_URL` was already resolved. `skills/memory-recall/SKILL.md`'s remote-embedding docs section updated to describe the same precedence.

### v1.5.1
- **CDT-127 — Epic orchestration context discipline (SPEC-025 M13)** — multi-child Mode B `/epic` walks hard-cut live context between children so cost scales with the active child (+ compact seed), not the whole epic transcript (the CDT-111 cache-read blowup class). Default **on** for ≥2 children; debug opt-out `--no-context-discipline` / `EPIC_NO_CONTEXT_DISCIPLINE=1`; single-child exempt.
  - **Primary A + secondary C** — mechanical SPEC-018-shaped seed from `state.json` via `epic-lib build-seed` / `validate-seed` (fail-closed before next child); optional `last_seed_path` + per-child `outcome_summary` (status remains sole SoT). Secondary guardrail forces the same boundary at ~400k tokens or 50% of the model window (between children only).
  - **Mode B protocol (`skills/epic/SKILL.md` B.6)** — degrade ladder (new session/@seed preferred; `/compact` + seed fallback; MUST NOT inline next handoff with prior child transcripts live); silent under autopilot (not a new SPEC-033 gate); exact halt `context-discipline: seed failed — <reason>`. CDT-126 council tiering is complementary, not a substitute.
  - **Tests** — M13 bite-tests + protocol greps in `skills/epic/test.sh` (shape, fail-closed, no status mutation, legacy tolerate, M8/M11/M13 greps).

### v1.5.0
- **CDT-126 — Council tiering (`skip | light | full`) with hybrid grading (SPEC-013, SPEC-033)** — both gated council call sites can now run a cheaper `light` pipeline (exactly 2 distinct-flavor investigators + Judge, Phase 3/Phase 4 skipped) instead of always paying for `full`. Grading bands the site's own diff (`files`/`loc` via `--numstat`) plus 5 structural critical-area signals (spec/contract file, executable, high fan-in, deletion-heavy executable, test removal — none hardcoded as literal paths); a clear-low band grades `light`, clear-high grades `full`, and an ambiguous middle band resolves via one haiku-tier triage call (`skills/council/prompts/tier-triage.md`). Every failure mode — missing `jq`, git failure, empty/unresolvable diff, unresolvable `origin/HEAD`, grader non-zero exit, invalid/timeout/non-zero triage — fails **closed to `full`**, deliberately inverting SPEC-026 M9's fail-open precedent since under-grading here would silently weaken a verification gate. `skip` exists only as an explicit DRI-supplied `--council-tier=skip`; it is never auto-selected.
  - **Automatic at the ship gate (SPEC-033 M14)** — every autopilot ship-choice run is graded and tiered with no flag needed; the grading diff is `git diff --numstat` against the merge-base with `origin/HEAD`, reusing N3a's existing resolution mechanism. BC7 is now tier-aware: a halt from a `light` run offers a full-council re-run escalation that a `full` halt has no room for.
  - **Opt-in at the task gate** — the orchestrated task-gate call only tiers when a DRI explicitly passes `--council-tier=<light|full>`; the unset/default case still runs `full`, unchanged from today. (A second automatic-grading path was deliberately not built here — it would have duplicated the ship gate's diff-scope grader against a claim-scope call site with no diff of its own.) The task-gate call also now binds `claim` scope / `generic` preset rather than `--diff`/`diff-mode`, since a `diff-mode` row always writes `max_verdict_confidence: null` and could never satisfy the SPEC-002 TaskCompleted confidence gate.
  - `council_tier` is a new field orthogonal to `verification_mode` (which stays a strict `full | self-verified` two-value enum) — a light run whose judge spawn fails is both `light` and `self-verified` at once, a distinction one widened enum could not express. Recorded in report frontmatter, the `.claude/council/index.json` row, and (ship gate only) the autopilot decision card. `full` is behaviorally unchanged (same phases, flavors, prompts, and stdout) but not byte-identical in its artifacts: report frontmatter and the `index.json` row gain the two additive `council_tier`/`grading_reason` keys on every run, with an ungraded `full` recording a default `grading_reason`. Its stdout is unchanged, and the new `council_tier=<tier> (<grading_reason>)` stdout line prints only for non-`full` runs.
  - Cross-reference: CDT-122 (task-gate `diff-mode` rows never satisfying `requires_council`) is neither fixed nor worsened by this ticket.

### v1.4.0
- **CDT-111 — `--autopilot[=<bump>]` flag on `/orchestrate`, `/kickoff`, `/epic` (SPEC-033)** — new opt-in unattended mode. Bare `--autopilot` (or `AUTOPILOT=1` env) runs hands-off through PR creation, then stops; `--autopilot=<patch|minor|major>` runs hands-off through PR, squash-stage, and `/release <bump>`. Default off — every gate stays fully human-interactive with no behavior change when the flag is absent.
- **Gate self-answer engine (`skills/autopilot/self-answer.md`)** — replaces each workflow's "wait for user" with "auto-answer per checklist, unless a blocking condition fires." Covers `/orchestrate`'s three gates (`scope-confirm`, `plan-approve`, `ship-choice`) plus `/kickoff`'s and `/epic`'s differently-shaped checkpoints (Step 3 open-questions, Step 4b API-verification gate, A.5 atomic scope+plan verdict, B.3 per-child handoff confirm) — mapped honestly per command rather than forced into a false 3×3 shape.
- **8 ordered blocking conditions (BC1–BC8)** force a human halt instead of auto-answering: genuine ambiguity, QA failure past 3 bounces, destructive/irreversible operations, LOC soft-cap/file-size breach, run-budget breach, self-uncertainty (confidence < 80), and unverified external dependency (`IGNORED`/`DECORATIVE`/`UNKNOWN` API/SDK/config verification a confirmed AC depends on). BC5 (complexity overflow — LOC hard-cap, 3+ workstreams, task-graph size, multi-spec scope, 3+ subsystems, or wall-clock overrun) is the sole non-blocking condition: it reroutes the run to `/epic` decompose and continues autonomously rather than halting.
- **Decision-card audit trail** — every auto-answer, halt, and reroute is appended as one JSONL record to `$MROOT/.claude/autopilot/<TICKET-ID>.jsonl` (git-ignored, never stored in `memory.db`), naming the gate, decision, blocking condition (if any), confidence, rationale, and run-budget snapshot. Written/read via new `skills/autopilot/append-card.sh` / `read-cards.sh`.
- **Mid-run escalation and reroute-to-`/epic` on complexity overflow** — a `/orchestrate` run that hits scope creep, an agent stuck after 2 attempts, an ambiguous requirement, a breaking-change discovery, or a review deadloop now resolves via the closest blocking condition under autopilot instead of waiting on an absent human; an overflow-classified scope-creep hands only the remaining/newly-discovered scope to `/epic` decompose, leaving already-shipped task state untouched.
- **Council ship-gate pass (`skills/autopilot/ship-gate-council.md`)** — a clean `pr`/`merge` ship-choice answer now runs exactly one adversarial `/council` pass before any ship action; a sub-80 or degraded/self-verified verdict forces a halt rather than letting a clean self-answer alone authorize an autonomous merge or release.
- **Notification on blocked/done** — halts emit `task_blocked` and successful autopilot ship end-states (`pr`/`merge`) emit `task_complete`, both via the existing `/orchestrate` notify sink (`skills/notify/webhook.sh`, fail-open) — no new transport.
- **Resume support (`skills/autopilot/resume-state.sh`)** — a paused or interrupted autopilot run picks back up in its recorded mode (read from the plan file's `autopilot_on`/`autopilot_bump` Tracking fields) on the next invocation, provided no fresh `--autopilot`/`AUTOPILOT=1` was given (flag/env always win). The wall-clock budget on resume is measured against accumulated active time only, derived from prior decision cards — pause duration never counts against the 45-minute cap.
- New spec: `specs/core/SPEC-033-autopilot-policy.md` (contract home). Operational copy lives in `skills/autopilot/SKILL.md`; `/orchestrate`, `/kickoff`, `/epic` cite it rather than forking their own checklists/conditions/budget/schema. `CONTEXT.md` gains matching domain-glossary entries (decision-card, blocking-condition, run-budget, complexity-overflow).

### v1.3.19
- **Fix — backlog write-back consolidation (SPEC-002 D1 duplication + non-self-contained Linear descriptions)** — discovered live: a Linear issue (CDT-111) was created pointing solely at a local `.claude/plans/**` file, unreadable by anyone without that exact checkout. Root-caused to a wider pattern: `skills/refactor/SKILL.md`'s escalation-gate auto-chain and `commands/retro.md`'s `--auto` mode each independently forked their own logic for writing a backlog item without a user turn — one reimplementing `mkdir`/`printf`/`awk` inline, the other ambiguously invoking `/backlog add` directly (risking an interactive prompt under a mode that claims to be non-interactive).
- **New `skills/backlog/SKILL.md` § Programmatic write-back protocol** — the SPEC-002 D1 contract home for any skill writing a backlog item without a user turn: content pre-supplied (skips the interactive ask), dedup guard fixed to suffix (the abort branch has no user to report a collision to), and MCP mode a caller-declared choice (`Linear-first` default or explicit `--local-only`, never a silent default). Also added a **Self-contained content** MUST: `/backlog add` must inline actual problem/goal substance in the Linear description, never a bare pointer to a local-only file path.
- `skills/refactor/SKILL.md` § 2.2a.5's ~28-line bespoke inline backlog write replaced with a citation to the new protocol (`--local-only`, matching its original deliberate no-MCP-round-trip-mid-chain rationale).
- `commands/retro.md`'s two `/backlog add` call sites (default print-and-confirm, `--auto` direct-write) now cite the same protocol's two calling conventions instead of restating or ambiguously invoking the command.
- `skills/brainstorm/SKILL.md` gets a new **Step 4c: Backlog write-back** — offers to file the accepted design synthesis as a backlog/Linear item (via the new protocol, Linear-first, self-contained content sourced from the Step 2 synthesis) unless `/kickoff` runs immediately in the same session. Closes the actual gap that surfaced CDT-111: an accepted brainstorm synthesis could evaporate into a plan file with no tracked-work visibility for anyone without local disk access.
- `specs/core/SPEC-009-ticket-workflow.md` updated: new Brainstorm MUST (offer write-back on accepted synthesis), new Backlog MUSTs (self-contained content; protocol contract-home registration with citing callers), Test/Validation coverage, Version History entry.
- `CONTEXT.md` — added the **Autopilot mode** domain term, crystallized during the `/orchestrate --autopilot` brainstorm session (CDT-111) that surfaced this defect.

### v1.3.18
- **New `docs-drift` check: `skill-ref` (SPEC-010 D9)** — every literal `skills/<name>/<file>` path mentioned in `commands/*.md` (prose or embedded in a bash fence) must resolve to a real file. This is the deterministic guard for the exact defect class fixed in v1.3.14/v1.3.15: a command left delegating to a skill that was stubbed, renamed, or deleted. Wired automatically through the existing `/release` Step 4.9 and CI job — no new wiring needed, same script. Lands on an already-clean tree (v1.3.15–v1.3.17 fixed every pre-existing dangling reference this check would have flagged) — no waivers needed. 55/55 `docs-drift` bite-tests pass, including 3 new `skill-ref` cases (dangling ref, live ref, ref inside a bash fence) plus a live-tree inject/restore bite.

### v1.3.17
- **Fix — `commands/retro.md` `GATE_SH` resolved to the wrong script (×2 sites)** — unrelated to the CDT-46-C3 class: Step 3b and Step 4c re-derived `$GATE_SH` in a fresh bash block (shell vars don't persist across blocks) but pointed it at a `skills/transcript-parse/freshness-gate.sh` that never existed, instead of `skills/retro-gate/gate.sh` (used correctly at Step 3a and consistent with the downstream `score`/`passed`/`threshold` JSON parsing and `FRICTION_SIGNALS_JSON` usage). Traced the actual call-site contract before fixing — a naive rename to the similarly-named `freshness.sh` would have "fixed" the dangling reference while shipping the wrong tool. Found while building the `skill-ref` docs-drift guard (shipping separately).

### v1.3.16
- **Fix — `commands/spec.md` dead fallback prose removed (×3)** — the `generate`/`tests`/`reflect` subs each carried a conditional "Task 6 alignment" fallback block pointing at `skills/generate-specs`, `skills/generate-tests`, `skills/reflect-specs` — all three were fully absorbed into `skills/spec-tooling` long ago (it documents all three modes), so the fallback branches were permanently unreachable dead documentation referencing deleted files. Removed; no behavior change. Found while building the `skill-ref` docs-drift guard (shipping separately).

### v1.3.15
- **Fix — `skills/memory-compress` restored, non-functional since v1.1.0** — same defect and same root-cause commit (CDT-46-C3) as `skills/validate-memory` fixed in v1.3.14: `commands/memory.md` was born already delegating `/memory distill --compress` / `MEMORY_COMPRESS=1` to `skills/memory-compress/SKILL.md` in the same commit that stubbed-then-deleted that file. Restored verbatim from git history (56 lines, self-contained prose skill, no engine dependencies) with one stale `/memory-distill` → `/memory distill` naming update. Found while building the `skill-ref` docs-drift guard (shipping separately).

### v1.3.14
- **`/memory validate` restored — non-functional since v1.1.0** — the deletion of `skills/validate-memory/SKILL.md` at v1.1.0 (CDT-46-C4 deprecation-stub cleanup) removed the claim-extractor prompt, investigator prompt, batching limits, verdict/claim taxonomies, composite-scoring formula, and reconcile pair-judge prompt — the entire LLM-driven contract `/memory validate` and its `--reconcile` mode depend on. `commands/memory.md` was left pointing at a nonexistent (and misspelled — `skills/memory validate/` instead of `skills/validate-memory/`) path, so every `/memory validate` run since, including the automatic pre-distill check inside `/memory distill`, executed on undefined behavior. Confirmed via git archaeology: the 505-line skill content existed at v0.56.0, was gutted to a deprecation stub at v1.0.0-pre.3 without migrating its content into the new unified `commands/memory.md`, then deleted outright at v1.1.0.
- **Fix** — restored `skills/validate-memory/SKILL.md`, `reconcile-lib.sh`, and `test-reconcile.sh` from the last commit before deletion (git history, v0.56.0), re-pointed all 18 broken references in `commands/memory.md` at the correct `skills/validate-memory/` path, and updated the routing-table/section framing that had been rewritten to (incorrectly) claim the skill was intentionally inlined. Verified compatible with the current v4 DB schema — all 15 `test-reconcile.sh` bite-tests pass unmodified.
- **Security hardening in the restored `reconcile-lib.sh`** (caught by background review while re-adding the file): the Jaccard-similarity helper wrote to predictable `${TMPDIR:-/tmp}/jac_a.$$` / `jac_b.$$` paths (symlink/TOCTOU risk) — switched to `mktemp`. The `resolve-pick`/`resolve-both-stale`/`resolve-merge` subcommands interpolated `winner_id`/`loser_id`/`id_a`/`id_b`/`confidence` directly into SQL without validating they were numeric — added a `require_int` guard at every call site (including the shared `_log_reconcile` sink) before interpolation.
- Ran a full `/memory validate` + `/memory distill` pass to confirm the fix end-to-end: validated 100 memories (9 clean pass, 44 flagged for review, 0 false-archives — composite scoring correctly declined to archive memories where only some claims were stale), then distilled `@auto`'s 209 raw memories into 12 tier-1 digests with 5 promoted to tier-2 core.

### v1.3.13
- **CDT-95 — `install.sh` hardened with `--dry-run`, opencode auto-detection, and a capacity warning** — the opencode installer did a destructive `rm -rf` of any prior install with no preview, and would happily write into `~/.config/opencode` even when opencode itself was never installed. No known platform silent-failure modes (e.g. agent-count caps) were surfaced at install time.
- **Fix** — `install.sh --dry-run` now previews every planned mutation (removals, dirs, symlink, model-pin reset, agent copies) via a `run()` gate wrapping the argv-form mutations, with explicit `if $DRY_RUN` guards on the two `jq` config rewrites that can't go through the wrapper — nothing is written, exit 0. An auto-detect gate (`opencode` binary on PATH OR an existing config dir — OR semantics, so a first-time real install with the binary but no config dir yet still proceeds) now runs before any destructive operation; if both are absent, install warns and skips cleanly (exit 0) instead of writing into a dead config tree. A capacity warning fires (in both normal and dry-run mode) when the opencode agent tree has 100+ agent `.md` files, hedged as "may silently ignore" since the exact cap isn't independently verified. `--dry-run --assign-models` together never touches stdin/TTY.
- `uninstall.sh` gets a mirrored `--dry-run` (`would remove: X` / `not found: X`, removes nothing) and its trailing summary line is now dry-run-aware so it never claims to have uninstalled when it didn't.
- New `install-test.sh` smoke harness (repeatable, 17/17 passing) verifies filesystem-untouched guarantees via before/after snapshot diffing, including that the second `jq` write (inside the `--assign-models` picker) is structurally unreachable whenever `--dry-run` is set.
- README updated to document all of the above. No spec created — the installer is ungoverned by design (two-script hardening task, documented rationale in the shipping plan).

### v1.3.12
- **CDT-96 — `skill-lint` and `docs-drift` now run in CI, not only at `/release`** — the two deterministic, LLM-free structural linters (SPEC-021 C1–C5, SPEC-010 D1–D8) previously ran only as `/release` pre-commit gates (Steps 4.8/4.9). Any push or PR to `master` outside the release flow got no automated signal from either linter, so a violation shipped undetected until the next `/release` blocked it — at that point it blocks the release, not the PR that introduced it.
- **Fix** — added sibling `skill-lint` and `docs-drift` jobs to `.github/workflows/smoke.yml`, alongside the existing (unchanged) `smoke` job. Each new job invokes its linter byte-identically to `/release` Steps 4.8/4.9 (no flags, from repo root), so CI and `/release` can never diverge in what they accept. Independent sibling jobs (no `needs:` chaining) mean one linter failing can never skip or short-circuit the other, and each surfaces as its own distinctly-named check. Waivers (`# lint-ok:`, `<!-- drift-ok: -->`) are honored identically to `/release` since it's the same script, same no-arg discovery.
- Both linters' `SKILL.md` now document CI as a second caller alongside `/release`.
- New spec: `specs/core/SPEC-032-ci-linter-parity-gate.md` (ACTIVE) — owns the CI wiring and structural properties (fail-the-build, always-run, distinguishable); check definitions and exit contracts remain owned by SPEC-021/SPEC-010, and `/release` itself is untouched.
- **Manual follow-up (not in this diff):** registering `skill-lint`/`docs-drift` as required branch-protection status checks is a GitHub repo-settings action, not a file — see the plan's ship-note `gh api` command.

### v1.3.11
- **CDT-107 — hook-runtime PDH resolver comment no longer claims false parity with the canonical bootstrap** — `skills/init-orchestration/SKILL.md`'s hook-runtime PDH resolver was commented as "Same bootstrap as `/orchestrate` and init-orchestration Step 7," but the resolver has only 2 tiers (dev-checkout fast path, else highest-installed-cache-version) where the canonical caller-site stanza has 4 (`CLAUDE_PLUGIN_ROOT` → cwd dev checkout → marketplace clone → installed cache) — and "Step 7" isn't a PDH resolver at all, it's an unrelated `PROJ_ROOT` project-bootstrap step. The construct itself was always correct (already properly waived by skill-lint's C5 check as distinct from the caller-site stanza) — only the comment was misleading.
- **Fix** — reworded the comment to state the resolver's actual 2-tier contract and explain why it's legitimately narrower (hooks run detached, with no session context, so `CLAUDE_PLUGIN_ROOT` and the marketplace-clone tier are unreachable), anchored to the phrasing already used at the site's own C5 waiver comments. Comment-only — bash logic untouched.
- This closes out the CDT-98 follow-up arc (CDT-99 through CDT-109).

### v1.3.10
- **CDT-109 — bare `<model>` commit trailers now carry honest-identity framing at every emit site** — five templates across four files emitted `Co-Authored-By: Claude <model> <noreply@anthropic.com>` with no adjacent instruction that `<model>` is a fill-in-the-blank, not literal text. This already landed unsubstituted, verbatim, in two real production commits during dogfooding. `skills/release/SKILL.md` already carried the correct "Honest identity" framing with worked examples — it just wasn't mirrored anywhere else.
- **Fix** — added the same framing (instruction to substitute the real agent/model identity, plus the same two worked examples reused verbatim) at `skills/orchestrate/SKILL.md`'s squash-merge template, `skills/scaffold-project/SKILL.md` (two sites), `skills/init-orchestration/SKILL.md`, and `docs/runbooks/manual.md` (found during Tech Lead review of the first four sites and folded into this same release). Every insertion sits outside its fence; the `<model>` placeholder itself is unchanged everywhere.
- No spec change — pure documentation/prompt-quality fix.

### v1.3.9
- **CDT-108 — `task_id`/`TASK_ID`/`TICKET` validation no longer bypassable via embedded newlines** — six sites across five files validated caller-supplied IDs with `printf '%s' "$X" | grep -qE '^<class>$'`, but `grep -q` succeeds if *any line* of multi-line input matches, not the whole string. An ID containing embedded newlines where each line individually looked valid passed validation whole, then flowed into a filesystem path — producing a file with literal newline bytes in its name. This already corrupted a real user's task store in production dogfooding (reported against `skills/orchestrate/task-store.sh`, and confirmed to hit the identical pattern in `skills/council/index-writer.sh`, `skills/council/engine.sh`, `skills/ci-watch/poll.sh`, and `skills/ci-watch/sidecar.sh` — one of them explicitly comment-labeled "path traversal prevention").
- **Fix** — all six sites now use bash-native, whole-string-anchored `[[ "$X" =~ ^<class>$ ]]` in place of the per-line `grep -q` check. Each site's own character class (with or without a dot), exit-code convention, and special behavior were preserved exactly rather than unified: `index-writer.sh`'s empty-`TASK_ID`-allowed guard is untouched, and `poll.sh`'s `echo "wait"; exit 0` rejection response — its documented stdout contract with the CI-watch cron — is unchanged even though it's now rejecting more inputs correctly.
- No spec change — the fix enforces contracts each file's own comments or governing spec (SPEC-009, SPEC-017) already state; nothing was altered, only correctly implemented.

### v1.3.8
- **CDT-106 — `epic-lib.sh` resolution restored to `plugin-dir.sh`, matching its documented contract** — `commands/epic.md:34`'s prose claimed `EPIC_LIB` was resolved via `plugin-dir.sh`, but the code at line 43 (and 10 more sites in `skills/epic/SKILL.md`) did a bare `$PDH` concat instead, losing `plugin-dir.sh`'s exit-3 not-found signal — the same defect class as CDT-99's row-12 finding, where a silently-swallowed bad path can route `/epic` into its DECOMPOSE branch instead of failing loudly.
- **Fix** — all 11 sites now resolve via `EPIC_LIB=$(bash "$PDH/skills/plugin-dir.sh" file skills/epic/epic-lib.sh)`, matching the `DAG_LIB=` reference pattern already used alongside it in `SKILL.md`. Mechanical, behavior-unchanged on the happy path; on a broken install, `/epic` now hard-fails with a diagnostic instead of silently falling through.
- No spec change — mechanical conformance to SPEC-002's existing `plugin-dir.sh` contract, not new behavior.

### v1.3.7
- **CDT-105 — `/kickoff` now creates a worktree before writing specs, closing a reproducible master-branch pollution bug** — `/kickoff`'s Step 5 ("Write or update spec") committed directly with `git add specs/ && git commit`, with no worktree-creation step anywhere earlier in its protocol. Since `/kickoff` explicitly supports standalone invocation, this landed the commit on whatever branch the session happened to be on — reproduced twice landing straight on master (CDT-104's `a049044`, CDT-99's `0fdf420`), both caught and manually relocated by hand after the fact.
- **Fix** — a new Step 1b creates a worktree (`worktree-lib.sh ensure <TICKET-ID>`, bare slug) immediately after context load and before the PM+Tech Lead spawn, mirroring `/orchestrate`'s own Step 3→4 ordering. Every downstream write — the spec commit, the plan file, the CONTEXT.md domain-glossary write-back — now targets that worktree. The worktree is deliberately left in place at `/kickoff`'s own exit (no `release` call) as a documented resumable handoff: `/kickoff` ships spec+plan, not code, so SPEC-031's bounded-exit rule (scoped to implementation-capable skills) doesn't apply here. A later `/orchestrate <TICKET-ID>` transparently reuses the same-slug tree.
- **Caught in review** — the first draft embedded `$WT_PATH` as literal text inside spawned-agent prompts; since agents don't inherit the orchestrator's shell variables, this would have caused the spec-writing agent to write outside the worktree. Fixed by substituting the resolved absolute path into agent prompts explicitly.
- Amended: `specs/core/SPEC-016-worktree-isolation.md` (kickoff added as a create-caller), `specs/core/SPEC-009-ticket-workflow.md` (kickoff lifecycle/resumable-exit contract), `specs/core/SPEC-002-plugin-infrastructure.md` (caller-integration site table).

### v1.3.6
- **CDT-103 — `/debug` + `/refactor inline` now share a worktree/branch, restoring the git-bisect commit-ordering guarantee** — `/debug`'s refactor-first path used to hand off to `/refactor inline`, which always created its own separately-slugged worktree and independently squash-merged or PR'd it onto the base branch. `/debug`'s eventual fix commit then landed on a *different* branch, cut from base before the refactor merged — so `skills/debug/SKILL.md`'s claims that the refactor commit "must land before the fix commit" and that they end up as "separate commits in the same branch" were false as implemented, breaking bisect/revert.
- **Fix** — `/refactor inline` gains an optional `--worktree <path>` flag. When `/debug` supplies its own worktree, `/refactor inline` reuses that worktree and branch, commits the refactor onto it, and skips its own bounded exit entirely (no PR, no squash-merge, no worktree release) — `/debug` owns the single exit and lands its fix commit on the same branch afterward. When no worktree is supplied, `/refactor inline` self-creates and takes its own bounded exit exactly as before (unchanged fallback — there is currently no other live caller).
- **Corrected a stale claim** — `skills/refactor/SKILL.md` named `/orchestrate` as an inline-mode caller in three places; confirmed via grep that `/orchestrate` has zero call sites into `/refactor inline` (it routes refactors as their own separate PR/ticket instead) and fixed the dead reference.
- Amended: `specs/core/SPEC-015-refactor-workflow.md` (§ Worktree Isolation, § Commit discipline), `specs/core/SPEC-014-debug-workflow.md` (§ Fix, bisect-ordering wording).

### v1.3.5
- **CDT-101 — `/debug`'s escalate and arch paths now run the mandatory workstream-split check** — `skills/debug/SKILL.md` § 2.4 previously stopped the escalating run ("emit `/kickoff` and stop") before § 2.4a's split check (SPEC-031 § Workstream split) was ever reached, so an escalating bug that actually decomposed into 2+ independently shippable workstreams was always bundled into a single `/kickoff` ticket instead of routing to `/epic`. Arch mode (`A.3`) had the same defect, and worse — it had no escalation-gate section at all. Both paths now run the split check (cited from `skills/refactor/SKILL.md` § 2.2a.2) before emitting any handoff; a confirmed split routes to `/epic` via the existing § 2.2a.5 sub-route, a non-split run keeps today's `/kickoff` emit-and-stop unchanged.
- **New documented arm-model exception** — under CDT-102's "debug never arms" model, debug now arms on exactly one route: the split-confirmed `/epic` auto-chain, disarming at `/epic` completion. The `/kickoff` non-split path stays emit-and-stop and never arms. Arch mode's `/epic` route creates no worktree, so the worktree-release sub-step is a documented no-op there; arm/disarm still apply. Recorded in `specs/core/SPEC-031-escalation-gate.md` § D1 as the "new decision" its contract-home pin requires before expanding debug's sibling-fix scope.
- Amended: `specs/core/SPEC-014-debug-workflow.md` (escalation MUSTs, T12/T13, validation checkboxes reconciled from `/kickoff`-only to `/kickoff`-or-`/epic`), `specs/core/SPEC-031-escalation-gate.md` § D1.

### v1.3.4
- **CDT-102 — escalation-gate marker lifecycle: arm-on-escalate, disarm-at-handoff-completion** — closes 16 findings from CDT-98's adversarial council review. The marker is now armed only on the escalate-and-auto-chain route (`/kickoff`/`/epic`), never at worktree creation and never on bounded runs; disarm is a single success-path call at handoff completion instead of scattered happy-path calls, closing the disarm-gap class (findings #1, #2, #12) by construction. The 8h leak-expiry TTL is demoted from primary reclaim to an abnormal-termination backstop.
- **Allowlist tamper-surface carve-out** — an armed run can no longer self-disarm by writing the hook script, `settings.json`, or the marker directory before the broad `.claude/**` allowlist exempts it (finding #4); the broad `*.md`/`*.txt` doc exemption is retained deliberately, closing finding #15 without narrowing it.
- **WARN-latch hardened** — session-scoped (finding #3, was bleeding across unrelated sessions) and symlink-guarded (finding #5, CWE-59/377).
- **Sibling skills reconciled** — `skills/debug/SKILL.md` and `skills/code-simplify/SKILL.md` had dead arm/disarm apparatus removed (neither ever arms under the new model); `skills/review-and-commit/SKILL.md` gained a proper D1 citation (finding #8) and had its dead disarm block removed (finding #11, since it never arms either).
- New `skills/init-orchestration/escalation-gate-test.sh` (40 tests) — this hook previously had no dedicated test harness. `.gitignore` gains the missing `.claude/escalation-gate/` entry (finding #7); the `/setup orchestration` fallback-ask string now names all three hooks (finding #14).
- Amended: `specs/core/SPEC-031-escalation-gate.md`.
- Deferred to backlog: finding #6 (theoretical plan-file slug `..`-traversal, low confidence, read-only). Dropped: finding #9, already resolved by CDT-99.

### v1.3.3
- **CDT-100 — fix stale `/tdd-gate` doc claim about hook non-interference** — `commands/tdd-gate.md:274` claimed `/tdd-gate`'s `PreToolUse` hook doesn't interfere with `/setup orchestration` hooks because they "use different events" — false; both register into the same `PreToolUse` array. The conclusion (no interference) was correct, but the stated reason invited a future clobbering merge if someone trusted the "different events" claim while adding a third `PreToolUse` hook. Replaced with the real mechanism: both sides append/remove element-wise and dedup by matcher + command set (see `skills/init-orchestration/SKILL.md` § "`PreToolUse` array append rule (SPEC-031)"), so neither clobbers the other regardless of install order.

### v1.3.2
- **CDT-99 — SPEC-002 caller-site table reconciled + new skill-lint C5 gate** — the table claimed "15 call sites" but the actual measured surface is 26 files / 110 emissions of the PDH bootstrap stanza (all byte-identical). Rewrote as 25 semantic-family rows with an inline re-derivation command so the count is re-checkable rather than trusted, and corrected one inaccurate fail-mode (row 12, `commands/epic.md` + `skills/epic/SKILL.md`) discovered during review.
- **New `skill-lint` check: C5 (PDH bootstrap-stanza drift)** — enforces that every `PDH=$(` emission stays byte-identical to the canonical stanza defined in `specs/core/SPEC-002-plugin-infrastructure.md`, closing the gap that let the table go stale with nothing checking it. Reads the canonical text from SPEC-002 at runtime (never duplicated as a literal — a second copy would itself be the drift class this check exists to prevent); fails loudly with a distinct message if the canonical block can't be located, rather than silently passing. Homed in `skill-lint` (not `docs-drift`) because SPEC-010 explicitly bars `docs-drift` from inspecting fenced-bash content, which is where every stanza lives. 57 new tests; zero regression in the existing C1–C4 checks.
- Amended: `specs/core/SPEC-002-plugin-infrastructure.md`, `specs/core/SPEC-021-skill-bash-lint-gate.md`.
- Filed as follow-ups (out of scope for this release): CDT-106 (`commands/epic.md` doc/code drift on `plugin-dir.sh` resolution) and CDT-107 (a hook-runtime `PDH` resolver comment overstating parity with the canonical stanza).

### v1.3.1
- **CDT-104 — fix dead anti-hijack gate in warm `/handoff`** — `skills/handoff/discover-warm.sh`'s live-Claude-env guard and Claude session-id precedence chain checked `CLAUDE_SESSION_ID`, but Claude Code actually exports `CLAUDE_CODE_SESSION_ID`. The guard never fired, so bare `/handoff` could silently mine a stale Grok session during a live Claude session with no error surfaced — the exact failure mode SPEC-018's honesty rules exist to prevent. Fixed: both the guard and the Claude precedence chain now check `CLAUDE_CODE_SESSION_ID` first (preferred), falling back to `CLAUDE_SESSION_ID` then `SESSION_ID`, matching the existing `ARM_SID` pattern in `skills/refactor/SKILL.md:494`. Grok discovery step 2 deliberately left unchanged (admitting the live id there would reopen the hijack the gate closes).
- **Test-isolation leak closed** — `discover-warm-test.sh`'s env-isolation unset list was missing `CLAUDE_CODE_SESSION_ID`, so the ambient live value would have silently leaked into every fixture the moment the variable was honored. Fixed in the same commit; 4 new tests added (32/0, up from 28/0), including a regression test demonstrating the original hijack failing pre-fix.
- Docs synced: `commands/handoff.md` (3 sites) and `docs/commands/handoff.md` now state the correct precedence order.
- Amended: `specs/core/SPEC-018-cold-session-handoff.md` (M10b, Test 35).

### v1.3.0
- **CDT-98 — Escalation gate for implementation-capable skills (SPEC-031)** — `/refactor` gains a mandatory inline `2.2a Escalation gate` between approach decision and coverage check (also active in `/refactor inline`): an always-asked edit go-ahead with no silent-proceed exception, ticket-weight routing reusing the existing `WHY INLINE REJECTED` enum, workstream-split detection routing 2+ independently-shippable ideas to `/epic`, and universal worktree isolation with no current-branch direct-edit path. On escalation, the gate emits the 4-field handoff and auto-chains in-session to `/kickoff` (writing a real backlog record, not just a plan-file assertion) and, after one confirm, to `/orchestrate` through PR/squash.
- **Self-satisfiable exemption closed** — the old "skip `/kickoff` if a `.claude/plans/` file already exists" loophole (a run could write its own plan file and treat that as a prior ticket) now requires a *resolving* `ticket_id:`/`closes:` reference in the plan's Tracking section, scoped to that section, and explicitly excludes plans written by the current run. The retired "escalation ladder" appendix is removed; `skills/epic/SKILL.md`'s equivalent guard is the precedent this follows.
- **Sibling skills cite, don't restate (D1 contract-home)** — `/debug` (full + patch mode), `/review-and-commit`, and `/code-simplify`'s manual path all gained the same gate treatment via section citation into `/refactor`'s single operational copy, plus `/epic` collision guarding against an unresolved `epic-lib.sh`.
- **Graduated `PreToolUse` hook (`.claude/hooks/escalation-gate.sh`, opt-in via `/setup orchestration`)** — WARNs (never blocks) on any matched write outside `.worktrees/` once installed; hard-BLOCKs only when a live marker armed by the current session exists. Explicitly documented as NOT tamper-proof (Bash bypasses it; the arming actor is the enforced actor; coverage is tool-name-scoped; path matching falls back to unnormalized `..` traversal without `realpath`). Coexists with `/tdd-gate` via a new `PreToolUse` array-append-with-dedup rule (Claude Code allows multiple entries per event; any one exiting 2 blocks).
- **Adversarial council caught 2 critical bugs before ship** — an independent 5-investigator + judge review of the full diff found `/debug` arming the gate with no disarm path (self-blocking every session that reached it for 8 hours) and `/review-and-commit`'s worktree-creation logic committing nothing (the reviewed diff never existed in the freshly-created worktree). Both fixed and re-verified in this release. 16 lower-severity findings from the same review filed as CDT-102 for follow-up; SPEC-002 table drift as CDT-99; a `/tdd-gate.md` stale comment as CDT-100; a git-bisect ordering gap between `/debug` and `/refactor inline` as CDT-103.
- New spec: `specs/core/SPEC-031-escalation-gate.md` (ACTIVE). Amended: `specs/core/SPEC-015-refactor-workflow.md`.

### v1.2.5
- **Fix `close.sh` line-merge corruption** — `update_item_file`'s awk replacement dropped the trailing newline after the rewritten `**Status**:` line (command substitution strips it, and the awk `printf` never re-added one), silently merging whatever line came immediately after onto the Status line. Every existing test fixture — and the skill's own canonical item template — has a blank line right after `**Status**:`, so an empty `print` happened to emit a bare newline and mask the bug; a file with content on the very next line (no blank line) got corrupted. Found while closing a legacy-format backlog item. Fixed by switching the awk replacement from `printf "%s", ns` to `print ns` (which always terminates with exactly one newline), applied to both the status-line and closed-footer writes.
- Added a regression test (`test.sh`) covering the no-blank-line-after-Status case so this can't silently reappear. 45/45 backlog tests pass; skill-lint and docs-drift clean.

### v1.2.4
- **Backlog reconcile now prunes, not archives** — `/backlog reconcile` deletes a terminal item's file and drops its index row (local `Status:` or a `--linear-verdicts` hit), instead of moving it into a `## Completed` section that never got swept. The local write-through is a disposable cache; Linear (when linked) or git/commit history is the durable record for done work.
- **Orphan item-file detection** — `reconcile.sh` now also scans `.claude/backlog/` directly for item files with no index row at all (previously invisible to both `list` and `reconcile`, since the scan only ever ran index→disk). Closed-status orphans are pruned; open/unrecognized-status orphans are reported (`ORPHAN not pruned`) and left untouched — never silently deleted, never auto-added to the index.
- **`close.sh` intentionally unchanged** — still moves a closed item into `## Completed` as a transient staging area, because `orchestrate`/`wrap-ticket` call `close.sh verify` immediately after close as a ship gate; deleting there would break that check. Pruning stays isolated to the standalone `reconcile.sh` sweep.
- Rewrote `reconcile-test.sh` for the new behavior (9 cases updated + a new orphan-handling case), and updated SPEC-009's normative reconcile MUSTs to match. Fixes the local `.claude/backlog/` directory accumulating stale/shipped items indefinitely despite Linear being the source of truth.

### v1.2.3
- **CDT-64 review fix — team resolution no longer gates project link** — M12.2/M12.3 + skill A.6: search and link need no team (only `save_project` does), so an epic whose project already exists still links when the team is unresolvable; team resolved **once** on the create branch and reused for every child `save_issue`; team-unknown now skips create only. P2 lock restated.
- **SPEC-025 M12** — drop stray blank line that rendered the 1–10 requirement list loose from item 4.
- **epic-lib** — flatten `set-linear-project` nested flag `case` into one case; behavior unchanged (`--clear`/`null`/empty clear; `--clea`/`-x` → usage 64). Tests 96/0.

### v1.2.2
- **CDT-64 test coverage** — lock rollup `linear_project_id` (set + null); pre-v1.2.0 legacy state (field absent) via show/rollup `// null` + set creates field; project-field assertions are jq-only (no python3).

### v1.2.1
- **CDT-64 follow-up — set-linear-project exit codes + M12 protocol harden** — missing epic now exits **1** (same as `read_state`/`set-status`; was inverted **2**); reject unknown flags like `--clea` (usage 64, no silent id write); empty-string clear + typo tests.
- **M12 protocol** — client-side exact-equality filter after `list_projects` query prefilter + cursor pagination; resolve Linear team once up front for project create and child issues; pin multi-hit advisory string.

### v1.2.0
- **CDT-64 — `/epic` Linear Project per epic (M12)** — on approved decompose, best-effort create/link one Linear Project named exactly the epic title; attach dual-written children; record `linear_project_id` in `state.json`; fail-open reuses M5 notice; resume/redecompose idempotent (no bare-resume create when null).
- **epic-lib** — nullable `linear_project_id` + `set-linear-project` / `--clear`; show/rollup surface the field; no network/MCP in bash.
- **SPEC-025** — M12 + M3/M5/M6/M9 extensions; P1–P8 locks; skill A.6/B/E protocol + command thin pointer; schema/CLI tests (PASS=78).

### v1.1.8
- **CDT-94 — gen-3 `load_prior_events` id collision** — disambiguate duplicate prior raw ids with unique `prior:{stem}:{raw}#N` (+ stderr); assemble T28 / SPEC-018 Test 34.

### v1.1.7
- **CDT-91 — `/handoff --light` warm preset (M10c)** — haiku miner, skip annotation, optional spine 40k; `mode: warm` + `light: true`; `*-draft.md`; no M8 cache write; Supersedes includes drafts.
- AC-16 dogfood excludes light; AGENTS opt-in flag = patch rule.
- Honesty: light preset is a reduced-cost mine path (not UNMINED freeform).

### v1.1.6
- **CDT-88 — warm delta-mine re-capture (M8b)** — second warm mines only since prior M8 leaf when cache has cumulative `events`; assemble merges prior+delta with generation order and `prior:{stem}:{id}`; auto-delta when eligible; `--full` / `HANDOFF_FULL=1` forces full re-mine; old cache without `events` → full; cold path unchanged; since-leaf miss clears prior (R8).

### v1.1.5
- **CDT-93 — event-id namespace at assemble load** — `load_events` prefixes `{stem}:{id}` so warm annotations cannot mis-target across `through_line`/`state`; Step 7 + SKILL use namespaced ids; bare ids drop with stderr; pointer index shows bare `_raw_id`; collision fixtures + assemble T18–T20.

### v1.1.4
- **CDT-90 — spawn model cost knobs** — chunk-summarizers + warm annotation default `model: haiku`; merged miner inherits session model with opt-in `HANDOFF_MINER_MODEL`; effort optional never MUST; `HANDOFF_SPINE_TOKENS` default 120k unchanged (docs tradeoff); SPEC-018 M3e + static `spawn-model-ac-test.sh`.

### v1.1.3
- **CDT-89 — single merged miner** — spine-mine uses one LLM Task (one spine read) that writes both `through_line.json` + `state.json`; halves miner spine input (~50% of dual-miner baseline); SPEC-018 M3b + SKILL + command Step 6; AC1/AC2 fixture tests.

### v1.1.2
- **Fix dual-host warm discover hijack** — Grok cwd-newest (step 3) no longer overrides a live Claude env (`CLAUDE_SESSION_ID` / non-Grok `*_TRANSCRIPT_PATH`); explicit Grok env still wins; `is_grok_chat_history` requires path under sessions root; adapter uses `mktemp`; dual-present + outside-path tests.

### v1.1.1
- **CDT-92 — Grok warm `/handoff`** — dual-host `discover-warm` (Grok wins when resolvable; Claude bridge does not override active Grok); `grok-to-claude-jsonl.py` normalizes Grok `chat_history.jsonl` to Claude-shaped spine; bare warm uses same prepare → miners → assemble path as Claude Code; SPEC-018 M10b + dogfood/docs honesty.

### v1.1.0

- **CDT-79 — STM packet /handoff** — rework cold/warm handoff from five-section inject brief to **STM packet** compact seed (`State now → Through-line → appendix`); shared spine-mine (2 LLM miners + git), LLM-free `assemble.py`, warm = cold-on-self + event_id-only annotation; SPEC-018 rewrite + docs/runbook.
- **CDT-80** — packet/cache/git root from **target session** project (not invoker cwd); `resolve-root.sh` + fail-hard when undetermined.
- **CDT-81** — assemble normalizes transcript refs (no `transcript:Ltranscript:L` double-prefix).
- **CDT-82** — PDH prefers marketplace/dev over same-version cache; worktree uses show-toplevel; dogfood PDH verify gate.
- **CDT-83** — production path passes prepare `stats.est_tokens` as `stripped_spine_tokens` for advisory ratio footer.
- **CDT-84** — skill-lint C1: self-contained bash fences in `commands/handoff.md`.
- **CDT-85** — warm session-id bridge + hard fail (no freeform live-context pretending to be STM); AC-16 human dogfood remains open for Claude Code warm score.
- **v1.1 contract** — W1–W3 deprecation **command stubs deleted**; pure stub skills removed (`local-agent`, `demo`, `incident`, `blind-review`, `generate-*`, `reflect-specs`, empty `validate-memory`/`memory-compress` stubs). Protocol-retained backends kept: `init-orchestration`, `scaffold-project`, `standup`, `fix-ticket`.

### v1.0.3

- **CDT-76** — `/setup orchestration` sweeps known-legacy orphan hook `bash-compress-wrapper.sh` after Step 4 emit: bak-force + FORCE-OVERWRITE disclose when unreferenced; WARN+keep if still referenced (SPEC-005).
- **CDT-77** — doctor `hooks.hygiene` is **managed-only** (basename ∈ `EXPECTED_HOOK_SCRIPTS`); user pathless/custom hooks no longer permanent-WARN with a setup fix-it setup will not apply (SPEC-022 M2c″).
- **CDT-78** — doctor `settings.sandbox_runtime`: functional bwrap init probe (WARN) when `sandbox.enabled=true`; surfaces hollow Cell D guarantees when config PASSes but OS sandbox cannot init; runbook residual #4 updated.

### v1.0.2

- **CDT-75** — matrix Cell D (`auto` + sandbox + matrix allow): core-loop `PASS_ZERO_PROMPT`; safety delta vs `dontAsk` documented; ship orchestration default flips Cell C → **Cell D** (epic C5 “sandbox + auto”). Probe harness adds Cell D + MCP/settings delta (`tools/permission-matrix-probe.sh`).
- **CDT-74 residual** — no MCP-server detection machinery (superseded by Cell D). Doctor WARN `settings.mcp_allow` when brownfield still on `dontAsk` with zero `mcp__*` allows. Runbook + setup/migrate/README honesty.
- **CDT-58** — interactive Cell C evidence retained in posture matrix (0 dialogs for allow-set work; MCP silent-deny under `dontAsk`).

### v1.0.1

- **CDT-67** — doctor `--gate=orchestration|team`: self-remediating FAIL rows (exact fix-it = gated `/setup` command) stay FAIL but do not block setup Step 0; bare doctor exit 2 unchanged (SPEC-022 M6c / SPEC-005).
- **CDT-70** — `hooks.hygiene` dedupes multi-event missing/nonexec script names.
- **CDT-59** — doctor WARN when Claude Code version drifts from last matrix probe pin (`tools/permission-matrix-cc-version`); probe updates pin on success.
- **CDT-69** — init-orchestration Step 1 normalizes absolute hook paths under project root to `${CLAUDE_PROJECT_DIR}` with force-overwrite disclosure.
- **CDT-68** — setup docs: batch dontAsk approvals for settings.json + bash-compress (do not eliminate permission prompts).
- **CDT-63 / CDT-57** — `close.sh` calm Linear-only no-index path (exit 0); fix dual-tag strip on FIXED/CLOSED re-close.
- **CDT-66** — consumer runbook `docs/runbooks/migrate-to-v1.md` (README + docs hub).
- **CDT-62** — scaffold-project documents full Cell C matrix allow set (not Bash(*)-only).
- **CDT-55** — marketplace 1.0.0 host evidence accepted (pre.N not re-observable; PDH tilde map verified).

### v1.0.0

- **v1.0 release (CDT-53 / CDT-46-C7)** — stability contract: tiered docs, governance files, complete migration table, reflect green, freeze lifts on this tag.
- **Tiered Surface map** — README + docs hub: **Core / Advanced / Internal / Migration**; one-line when-to-use per Live Surface; Deprecation stubs migration-only (D2 still indexes every `commands/*.md`).
- **Full docs-tree reconcile** — `docs/README.md` + `docs/commands/*` + runbooks accuracy-only; old primary names → hubs; stubs tombstoned with replacements.
- **Governance** — root `LICENSE` (MIT, © 2026 cold-dark-void); `SECURITY.md` (supported 1.0.x; report via GitHub private vulnerability reporting / Security Advisories); versioning pointer → `/release` + SPEC-002.
- **SPEC amends** — SPEC-002 MUST ship root LICENSE; SPEC-001 session boot → `agent-memory/protocol.md` (memory-recall = search only); hub-name hygiene across SPEC-003/007/009/012/013/022/024.
- **PDH final gate** — tree-wide bare `sort -V | tail` uniformity check in `plugin-dir-test.sh` (tilde map required; intentional bare hazard assert only).
- **AGENTS freeze** — active only until `v1.0.0` is tagged on master; section becomes historical after this release.
- **W1–W3 Deprecation stubs** remain loadable; **scheduled deletion at v1.1**.
- **Authoritative migration table** (below) consolidates pre.1/pre.3/pre.4 fragment tables.

**Migration (old → new)** — authoritative table for W1–W3 renames, absorptions, and removals.
All **W1–W3 Deprecation stubs** (command + skill) are **deleted at v1.1**.

| Old | New / fate | Wave | Delete-at |
|-----|------------|------|-----------|
| `/local-do` | removed (local-agent offload excised) | W1 | v1.1 |
| `/incident` | removed (use `/debug`; no war-room Surface) | W1 | v1.1 |
| `/demo` | removed (use `/setup` + `/kickoff` on scratch) | W1 | v1.1 |
| `skills/local-agent` | removed with `/local-do` | W1 | v1.1 |
| `skills/incident` | stub; devops role independent of war-room Surface | W1 | v1.1 |
| `skills/demo` | stub | W1 | v1.1 |
| `/memory-config` | `/memory config` | W2 | v1.1 |
| `/memory-distill` | `/memory distill` | W2 | v1.1 |
| `/memory-export` | `/memory export` | W2 | v1.1 |
| `/memory-search` | `/memory search` | W2 | v1.1 |
| `/memory-stats` | `/memory stats` | W2 | v1.1 |
| `/validate-memory` | `/memory validate` | W2 | v1.1 |
| `/check-specs` | `/spec check` | W2 | v1.1 |
| `/create-spec` | `/spec create` | W2 | v1.1 |
| `/find-spec` | `/spec find` | W2 | v1.1 |
| `/list-specs` | `/spec list` | W2 | v1.1 |
| `/update-spec` | `/spec update` | W2 | v1.1 |
| `/blind-review` | `/council --blind` | W2 | v1.1 |
| `/reflect-specs` | `/spec reflect` | W2 | v1.1 |
| `/generate-specs` | `/spec generate` | W2 | v1.1 |
| `/generate-tests` | `/spec tests` | W2 | v1.1 |
| `skills/validate-memory` | `/memory validate` (protocol via `/memory`) | W2 | v1.1 |
| `skills/blind-review` | `/council --blind` (prompts retained for engine) | W2 | v1.1 |
| `skills/reflect-specs` | `/spec reflect` (`skills/spec-tooling/`) | W2 | v1.1 |
| `skills/generate-specs` | `/spec generate` (`skills/spec-tooling/`) | W2 | v1.1 |
| `skills/generate-tests` | `/spec tests` (`skills/spec-tooling/`) | W2 | v1.1 |
| `/focus` | `/mode focus` | W3 | v1.1 |
| `/blunt` | `/mode blunt` | W3 | v1.1 |
| `/metrics` | `/status metrics` | W3 | v1.1 |
| `/fix-ticket` | `/debug ticket` | W3 | v1.1 |
| `/init-team` | `/setup team` | W3 | v1.1 |
| `/init-orchestration` | `/setup orchestration` | W3 | v1.1 |
| `/scaffold-project` | `/setup project` | W3 | v1.1 |
| `/standup` | `/status standup` | W3 | v1.1 |
| `/worktree list\|status` | `/status worktree` (`/worktree release` remains live) | W3 | n/a (behavior moved; not a command stub) |
| `skills/init-orchestration` | `/setup orchestration` (templates retained) | W3 | v1.1 |
| `skills/scaffold-project` | `/setup project` | W3 | v1.1 |
| `skills/standup` | `/status standup` (protocol retained for hub) | W3 | v1.1 |
| `skills/fix-ticket` | `/debug ticket` (protocol retained for hub) | W3 | v1.1 |

Notes:
- **19 command Deprecation stubs** (`incident`, `local-do`, `blind-review`, `check-specs`, `create-spec`, `find-spec`, `list-specs`, `update-spec`, `memory-config`, `memory-distill`, `memory-export`, `memory-search`, `memory-stats`, `validate-memory`, `focus`, `blunt`, `metrics`, `fix-ticket`, `init-team`) + absorbed skill stubs above: remove at **v1.1**.
- Live hubs after migration: `/memory`, `/spec`, `/mode`, `/status`, `/setup`, `/debug`, `/council`, `/worktree` (release-only).
- Wave source: W1 = CDT-46-C2 (`1.0.0-pre.1`); W2 = CDT-46-C3 (`1.0.0-pre.3`); W3 = CDT-46-C4 (`1.0.0-pre.4`).
- Prefer hub names always; do not hardcode Surface counts in prose (docs-drift D2 owns the index).

### v1.0.0-pre.7
- **v1.0-W6 hygiene: de-`.claude` upstream + hook template SoT + Linear-first backlog (CDT-54 / CDT-46-C8)** — release-candidate *prose* only; version remains `-pre.7` (never `rc.*` — PDH tilde-map hazard).
- **`.claude` never upstream** — gitignore + untrack process paths (hooks, backlog, plans, epics); `git ls-files '.claude/**'` empty except optional seed carve-out; live hooks regenerated via `/setup orchestration`.
- **Hook template single SoT** — `check-hook-templates` is template-internal (extract + `bash -n`); dual-copy live↔template gate retired; release Step 4.7 + doctor `hooks.templates` aligned.
- **Backlog Linear-first + mandatory write-through** — add/list/close prefer Linear when MCP up; always dual-write local files; MCP-down fail-open; `--linear-verdicts` retained; ship/wrap **never** stage trackers into product commits.
- **SPEC amends** — SPEC-002/005/009/010/012/018/022/025 (M4/M5 Linear preferred; local C\<n\> keys canonical); policy prose in AGENTS, epic, orchestrate, scaffold, wrap-ticket.
- **OQ4 migrate** — reconcile + map PENDING before untrack; no silent loss.

### v1.0.0-pre.6
- **v1.0-W5 INFERRED promote-or-cut + PM/TL cortex pin (CDT-52 / CDT-46-C6)** — stability-contract wave: zero INFERRED specs remaining on kept v1 Surfaces; cortexes pinned to pre.6 for C7 kickoff.
- **SPEC-002…010 → ACTIVE** — human-reviewed tri-state disposition (promote-as-is | amend-then-promote | cut); VH evidence rows; TDD index Status synced; final format check clean.
- **SPEC-005 /setup honesty** — Overview/Covers reworked for sole entry `/setup` (`project|orchestration|team`); C5 doctor-gate + posture MUSTs retained; demo historical only.
- **SPEC-028 → DEPRECATED (retained)** — protocol home for `/debug ticket` until v1.1; SPEC-014 fold note; file not deleted.
- **SPEC-026 verify-keep** — ACTIVE confirmed (metrics emit/outcome-rates + orchestrate advisory).
- **Restores `skills/memory-recall`** — agent-internal recall protocol over-stubbed in pre.3 (C3); full body restored; session-read SoT remains `agent-memory/protocol.md`.
- **PDH bare `sort -V` bugfix** — `task-completed.sh`, `precompact-rescue.sh`, and init-orchestration hook templates use pre-safe tilde map; `check-hook-templates` green.
- **Local dogfood passenger (CDT-51 residue)** — host `.claude/settings.json` flipped to `dontAsk` + full matrix allow (gitignored; not in release tree). Documented on Linear CDT-51/52.

### v1.0.0-pre.5
- **v1.0-W4 permission posture, doctor install gate, migrate tests (CDT-51 / CDT-46-C5)** — enterprise-credibility wave: least-privilege orchestration default, bootstrap doctor gate, and schema survival tests.
- **Orchestration posture flip (AC1–AC2)** — live A/B/C matrix on Claude Code 2.1.190 (`docs/runbooks/permission-posture-matrix.md`); winner **Cell C `dontAsk`** + sandbox + `autoAllowBashIfSandboxed` + matrix allow set (`Bash(*)`, Read, Write, Edit, Glob, Grep, Agent, Task). Evidence before template flip; interactive `/setup project` stays `acceptEdits`.
- **`/setup` doctor hard-gate (AC4)** — `/setup team` and `/setup orchestration` block on `dev-team:doctor` exit 2; exit ≤1 (WARN) proceeds; `--skip-doctor` prints WARNING then continues; `/setup project` soft advisory only; marketplace install ungated.
- **Force-overwrite disclosure (AC5)** — re-run that changes managed settings (esp. `permissions.defaultMode`) prints key / old / new / restore via `disclose-force-overwrite.sh`; forced+silent = fail.
- **DB migrate harness (AC3)** — `skills/memory-store/test-migrate.sh`: fresh `schema.sql` → v4, v3→v4 floor, full v1→v4 chain, PRAGMA-poison capture-safe reads; fixtures under `fixtures/migrate/`.
- **Doctor sandbox coherence** — WARN when `dontAsk` or `bypassPermissions` without sandbox; project-init Step 1b relabeled team-bootstrap (never demotes managed orch `defaultMode`).
- **Specs** — scoped MUST amendments on SPEC-002/005 (posture + doctor-gate), SPEC-022 M6b caller gate, SPEC-004 migrate notes; INFERRED status unchanged (W5 promote).

### v1.0.0-pre.4
- **v1.0-W3 surface merges (CDT-46-C4)** — session tone, read-only status, onboarding, and ticket-fix entries unified under four hubs; five one-cycle Deprecation stubs remain until v1.1.
- **`/mode`** — single session-tone entry for `focus|blunt [on|off|status]`, `/mode status`, `/mode off`; orthogonal focus⊥blunt stack; skill-delegate backends.
- **`/status`** — read-only snapshot hub: bare = standup → metrics → worktree list; subs `standup`, `metrics` (flag parity via rollup.sh), `worktree`.
- **`/setup`** — onboarding dispatcher `project|orchestration|team` (distinct protocols; bare = usage only); team flags `--refresh|--migrate-only|--no-extensions`.
- **`/debug` host + `ticket` mode** — thin `commands/debug.md`; first-token `patch|arch|ticket`; ticket absorbs former `/fix-ticket` (SPEC-028 protocol; full fold W5 OOS).
- **`/worktree` reduce-to-release (OQ1)** — mutate-only `release <slug>` with chat confirm; status/list moved to `/status worktree` — **not** a Deprecation stub.
- **Five command Deprecation stubs** — `focus`, `blunt`, `metrics`, `fix-ticket`, `init-team` (prose-only; `removed at v1.0.0` / removed at v1.1).
- **Skill tombstones** — standup, scaffold-project, init-orchestration, fix-ticket (protocol retained for hub delegates); focus/blunt remain live `/mode` backends.
- **Docs** — README Commands + docs hub retargeted; AGENTS Worktree Protocol cites `/worktree release` + `/status worktree`; docs-drift green.

| Old command | New form |
|-------------|----------|
| `/focus` | `/mode focus` |
| `/blunt` | `/mode blunt` |
| `/metrics` | `/status metrics` |
| `/fix-ticket` | `/debug ticket` |
| `/init-team` | `/setup team` |
| `/worktree status\|list` | `/status worktree` (release stays `/worktree release`) |

### v1.0.0-pre.3
- **v1.0-W2 surface merges (CDT-46-C3)** — twelve standalone commands folded into unified dispatchers (`/memory`, `/spec`) or `/council --blind`. One-cycle Deprecation stubs remain until v1.1 (marketplace auto-latest makes silent removal user-visible breakage).
- **`/memory <sub>`** — single entry for `config|distill|export|search|stats|validate` with full flag parity; six old command files are prose-only stubs.
- **`/spec <sub>`** — single entry for `check|create|find|list|update|generate|tests|reflect`; generate/tests/reflect behavior absorbed into `skills/spec-tooling/`.
- **`/council --blind`** — absorbs `/blind-review` (N unconstrained + M lens reviewers → clustering → confidence tiers); Tier-1 clusters emit as findings with no recursive `/council` reverse-validation; `--no-council` removed.
- **Pre-release-safe PDH resolution (SPEC-002)** — tilde-mapped `sort -V` so final `1.0.0` outranks retained `1.0.0-pre.N` cache dirs; hardened `plugin-dir.sh` + tree-wide bootstrap stanza; `plugin-dir-test.sh` (17 cases).

| Old command | New form |
|-------------|----------|
| `/memory-config` | `/memory config` |
| `/memory-distill` | `/memory distill` |
| `/memory-export` | `/memory export` |
| `/memory-search` | `/memory search` |
| `/memory-stats` | `/memory stats` |
| `/validate-memory` | `/memory validate` |
| `/check-specs` | `/spec check` |
| `/create-spec` | `/spec create` |
| `/find-spec` | `/spec find` |
| `/list-specs` | `/spec list` |
| `/update-spec` | `/spec update` |
| `/blind-review` | `/council --blind` |

### v1.0.0-pre.2
- **v1.0.0 pre-release line opened (CDT-46 program decision)** — version re-wire, no functional changes: the breaking W1-cuts release below is renumbered `1.0.0-pre.1` (the old `v0.80.1` tag is removed), and this content-identical republish ships as `1.0.0-pre.2`. Remaining v1.0 program waves ship as `1.0.0-pre.N`, final `1.0.0` at W6.

### v1.0.0-pre.1
*(originally released as `v0.80.1`; renumbered — the old tag no longer exists)*
- **v1.0-W1 surface cuts (CDT-46-C2)** — four undefended Surfaces removed with one-cycle Deprecation stubs (marketplace auto-latest makes silent removal user-visible breakage; stubs deleted at v1.1).
- **Removed `/local-do` + `skills/local-agent` (full excision)** — the entire local-offload path is gone, not just the command: orchestrate offload fork + review loop, debug P.4 and refactor 3.3 offload blocks, standup `[local]` routing column, metrics `local_agent` rollup key + dual-shape handling, doctor `deps.bwrap`/`deps.opencode`/`deps.local_agent` checks, and the AGENTS.md opt-in section. SPEC-019 → DEPRECATED.
- **Removed `/incident`** — war-room command + skill stubbed, engine scripts (`timeline.sh`, `workspace.sh`) deleted; devops agent reframed to a skill-independent incident-response role. SPEC-027 → DEPRECATED.
- **Removed `/demo`** — deprecated stub for one cycle; use /setup + /kickoff on a scratch project instead. Migration table will consolidate at v1.0.0.
- **`scout-plugins` relocated to `tools/`** — internal ecosystem-scan tool, no longer a loaded Surface (no spec, no smoke entry, no frontmatter contract).
- **`/backlog reconcile` (SPEC-009 amendment)** — new idempotent subcommand: Linear issue state is source of truth when the MCP is reachable (verdicts passed via `--linear-verdicts`); local item-file status is the fallback. Moves stale COMPLETED rows, removes dead-reference rows, collapses duplicates; `--dry-run` supported. Fixes the CDV-214-class stale-index bug. Plus a dedup guard on `/backlog add`. 22-case deterministic test suite.
- **Docs reconciled** — README/docs-hub rows for the four cut Surfaces removed or tagged deprecated; orphan `docs/commands/{incident,demo}.md` pages deleted; consumer specs (SPEC-002/005/016/022/026) Covers lists updated. docs-drift gate: 0 findings, 0 waived.

### v0.80.0
- **Smoke-harness gate (SPEC-030, CDT-46-C1)** — deterministic LLM-free load-check for every Surface: `tools/smoke/run.sh` verifies frontmatter (name+description) and `bash -n` on all fences of `commands/*.md` + `skills/*/SKILL.md`, plus `bash -n` on engine `.sh` scripts. Exit 0/1/64; dynamic discovery, no static list; 35-case bite-test suite (`tools/smoke/test.sh`) + 5 fixtures.
- **First CI on the repo** — `.github/workflows/smoke.yml` runs the harness on push and pull_request to master.
- **`/release` Step 4.10** — smoke harness wired as a pre-commit gate after docs-drift; non-zero aborts the release.
- **Template-fence marker** — documentation-shape fences opt out of syntax check via ```` ```bash template ```` info string (16 fences tagged across 6 files; skill-lint C1–C4 coverage unaffected); bare broken fences still fail.
- **Fixed pre-existing bug** — `commands/validate-memory.md`: a trailing `# lint-ok` comment defeated a line continuation, leaving an unterminated `$(...)` in live code; found by the new gate on its first full-tree run.
- **v1.0 feature freeze declared (CDT-46)** — AGENTS.md: only CDT-46 child work and bug fixes land on master until v1.0.0 tags; covers commands, skills, agents, hooks, specs.
- **Domain glossary** — new `CONTEXT.md` with v1 contract terms (Surface, Deprecation stub).

### v0.79.0
- **`/blunt` session tone** — opt-in no-sugarcoat mode: verdict-first, confidence must match evidence, disagree when warranted, not hostile. Command + `skills/blunt`; stacks with `/focus`. Session-only, no hooks.

### v0.78.1
- **`/focus` evidence pillar (anti-gaslighting)** — second pillar beside action-first output: CONFIRMED/LIKELY/UNKNOWN, tool-backed causal claims, kill false smoking guns, in-session dead ends, systematic observe→hypothesize→check. Explicit vs `/debug` and `/council`. No hooks/disk.

### v0.78.0
- **`/focus` session output shaping** — opt-in action-first replies (numbered steps, restate state, no preamble/pleasantries). Command + `skills/focus`; docs index. Inspired by ayghri/i-have-adhd (MIT); session-only, no hooks.

### v0.77.1
- **Docs: upgrade + discovery for v0.71–v0.77** — setup Upgrading section (no migration); hub/README pointers; review/memory/idea-to-plan/demo aligned; demo seeds CONTEXT.md.

### v0.77.0
- **Think-in-code bulk analysis** — IC5/Tech Lead + `/debug` prefer short aggregate scripts over mass full-file Reads for counts/inventories. Zero external deps (prompt/protocol only).

### v0.76.0
- **Graphify companion docs** — optional structural knowledge-graph tool documented in setup + onboarding; `/review-and-commit --impact` may shell out to `graphify path/explain` when installed. Not a dependency.

### v0.75.0
- **Terse intensity levels + memory prose compress** — `Output mode: terse|ultra` (AGENTS.md + 7 agents); optional `/memory-distill --compress` / `MEMORY_COMPRESS=1` via `skills/memory-compress`. Zero external deps.

### v0.74.0
- **Optional host SAST feed** — `skills/security-scan` (Semgrep / CodeQL if present; fail-open). Wired into `/review-and-commit` Step 1c + council security flavor variant analysis. `SECURITY_SCAN=0` to skip. No required deps.

### v0.73.0
- **`/brainstorm --grill`** — one-question-at-a-time interview with recommended answers; design-tree walk; codebase answers when possible; optional CONTEXT.md Decisions write-back. Default batched mode unchanged.

### v0.72.0
- **Post-implement code-simplify** — optional behavior-preserving polish after Tech Lead APPROVE, before QA (`skills/code-simplify`; orchestrate Step 9.5). Recently modified files only; fail-open; skip with `CODE_SIMPLIFY=0`. Zero external deps.

### v0.71.0
- **Living domain glossary (`CONTEXT.md`)** — committed ubiquitous language (not agent memory). Load/update protocol in `skills/domain-glossary`; wired into `/brainstorm`, `/kickoff`, project-init cortex seed, `/scaffold-project` template, AGENTS.md + docs. Zero external deps.

### v0.70.2
- **CI-watch CronCreate harness-aware durable** — prefer `durable: true` (Claude Code); on deny/unavailable (e.g. cmux rejects durable outright) arm once with `durable: false` and notify session-only. Stops avoidable denied first calls without regressing native durable watches. SPEC-017 + `skills/ci-watch` + orchestrate Step 8.5
- **SPEC-029 DRAFT→ACTIVE** — promote after describer dogfood (docs/status only)

### v0.70.1
- **`theme-status.sh append` stdin** — stop always-forwarding empty `$3` (was writing a blank line and dropping stdin); documented stdin / `--` / argv forms

### v0.70.0
- **SPEC-029 debug reopen & multi-surface done gates (DRAFT)** — `/debug` forces redesign after ≥2 prior theme-days or isolation keywords; multi-UI surface matrix before done; concurrent interleaved regression; human override (logged); theme log under `.claude/debug/themes/`
- **`theme-status.sh` helper** — derive/status/force-check/count-prior (UTC day semantics, empty-key → `unthemed`); wired from `skills/debug/SKILL.md` (C1-safe S.6 placeholders)
- **SPEC-014 + refactor handoff** — see-also/checklist extension; `/refactor` preserves theme context on debug handoff
- **TDD index hygiene** — SPEC-029 row after 028; drop duplicate SPEC-011/012 index lines

### v0.69.0
- **Ship-time backlog/Linear tracking close-out** — `/orchestrate` resolves source (Linear → backlog → freeform), records plan `closes:`, and closes trackers via `skills/backlog/close.sh` on the feature worktree in the **same delivery commit** as product code; `/wrap-ticket` re-closes idempotently; SPEC-009 MUSTs + unit tests

### v0.68.1
- **TMPDIR-safe worktree-lib-test stderr (CDV-213)** — route suite stderr via `ERR_TMP` under `${TMPDIR:-/tmp}` instead of bare `/tmp/wt-test-err.$$`; fixes spurious 20/32 failures under sandboxed harnesses with RO `/tmp`

### v0.68.0
- **External reviewer option (CDV-207)** — optional `--external` (codex/gemini CLI); one additive investigator slot; graceful skip if missing; review-and-commit passthrough

### v0.67.0
- **Council investigator tool-call caching (CDV-211)** — per-run TMPDIR cache; preflight seed + cache-first investigator protocol; finalize cleanup

### v0.66.0
- **Council Phase 3 domain specialist (CDV-209)** — topic-classifier prompt; pull devops/ds/qa/pm at confidence ≥0.75 (cap 1/run); skip diff-mode; SPEC-013 undefferred

### v0.65.0
- **`/council --from-retro` (CDV-212)** — retro persists anchors under `.claude/retro/anchors/`; council loads claim and skips Phase 1; deferred exit 3 removed for from-retro

### v0.64.0
- **`/council --plan <path>` (CDV-208)** — plan-file claim extraction live; plan-extractor prompt; deferred exit removed for plan (from-retro still deferred)

### v0.63.0
- **Council per-phase token reporting (CDV-204)** — optional `--tokens-file` on finalize; Tokens stdout block + frontmatter when known; graceful omit when unavailable

### v0.62.0
- **`/council --why` (CDV-206)** — preflight `why_detail` + stdout debug section (preset/flavors/specialist stub); no verdict impact

### v0.61.0
- **Agent notification sink (CDV-210)** — fail-open `skills/notify/webhook.sh` + orchestrate MCP/webhook milestones; TaskCompleted success emit; silent default when `AGENT_WEBHOOK_URL` unset

### v0.60.0
- **Handoff signal-bearing sidechain reconstruction (CDV-205)** — prepass expands sidechains with rejection/correction cues for Dead-ends; synthetic fixtures + sidechain-test; SPEC-018 M2

### v0.59.0
- **COUNCIL-002 template `task_id` frontmatter (CDV-203)** — report templates own YAML FM with `task_id: "{{TASK_ID}}"`; finalize strips unbound `task_id` key; SPEC-013 + SKILL docs

### v0.58.0
- **SPEC-027 /incident war-room (CDV-193)** — severity triage SEV1–3; jsonl timeline; devops commander; propose-only mitigation; postmortem → backlog; no external paging

### v0.57.0
- **SPEC-025 /epic umbrella decomposition (CDV-192)** — prompt-driven epic decompose + DAG handoff; `epic-lib.sh`; standup rollup; wrap-ticket mark-done; Linear optional

### v0.56.0
- **SPEC-011 /validate-memory --reconcile (CDV-195)** — bounded cross-agent contradiction candidates; LLM pair-judge; interactive or `--report-only`; schema v4 `reconcile_log`; never auto-archive

### v0.55.0
- **optional Council-on-Workflow tribunal path (CDV-196)**

### v0.54.0
- **directive A/B trial loop SPEC-001 M1–M8 (CDV-200)**

### v0.53.0
- **SPEC-028 /fix-ticket premise→implement→refuters (CDV-197)**

### v0.52.0
- **SPEC-024 memory seed packs (CDV-194)** — `/memory-export` writes sanitized tier-2 seed packs; `/init-team` Step 5.5 non-blocking import with content-hash dedupe; gitignore carve-out for `.claude/memory/seed/`; SPEC-005/007 forward refs

### v0.51.0
- **Local-agent expansion: debug/refactor consumers + optional net egress (CDV-198)** — `/debug patch` and `/refactor inline` may offload mechanical steps via `/local-do` loop when `LOCAL_AGENT=opencode`; `LOCAL_AGENT_NET=none` adds bwrap `--unshare-net` (default host net unchanged); SPEC-019 updated

### v0.50.0
- **SPEC-022 `/doctor` install & config diagnostics (CDV-191)** — `dev-team:doctor` read-only check battery (version triplet, memory stack, hooks, settings, optional deps, worktrees, plugin resolve); `--json` + exit 0/1/2/64; narrow `--fix` allowlist; documents harness `/doctor` name collision

### v0.49.0
- **Council spawn-failure self-verified degradation (CDV-199)** — on unusable refuter/investigator spawn, orchestrator self-verifies with explicit `self-verified — refuters unavailable` marker; engine `--verification-mode full|self-verified`; SPEC-013 + council/review-and-commit/AGENTS guidance

### v0.48.0
- **Scheduled autonomous `/retro --all --auto` (CDV-190)** — report under `.claude/retro/scheduled-*.md` (retention 12); scheduled.lock (2h TTL); runbook for CronCreate + OS cron (opt-in weekly); Filter 1/2 unchanged; thin optional `AGENT_WEBHOOK_URL`

### v0.47.0
- **`/metrics` observability rollup (CDV-187)** — read-only `skills/metrics/rollup.sh` over local-agent metrics, council index, SPEC-026 outcomes, and cheap worktree/task counts; fail-open per section; command + README index

### v0.46.0
- **Friction telemetry ledger (CDV-186)** — `friction-capture.sh` hooks for PostToolUseFailure/PermissionDenied/StopFailure append NDJSON to `.claude/retro/friction.jsonl`; retro-gate hybrid S2 from ledger when covered; init-orch templates; no S3 retune

### v0.45.0
- **`/worktree` + lib status/register/sweep (CDV-189)** — user command for status/list/release; worktree-lib gains status/list/register/sweep (FRESH/STALE age locks); lifecycle hooks remain DRAFT (Remove has no exit-2 control); 32 lib tests

### v0.44.0
- **SPEC-026 outcomes ledger + adaptive routing (CDV-185)** — append-only `.claude/metrics/outcomes.jsonl` via `emit-outcome.sh`; assignment-time advisory from `outcome-rates.sh` (never silent reroute); orchestrate Task-class + stint-end emit; local-do escalate emit; 16 unit tests

### v0.43.0
- **Docs-drift release gate (CDV-188)** — `skills/docs-drift` checks cmd-index, agent-roster, docs-hub, manifest-desc; wired as `/release` Step 4.9; 44 bite-tests
- **`/check-specs --tests` Phase 3** — opt-in MUST→test coverage matrix (report-only; `--gate` not release-wired); SPEC-008/010 extensions promoted
- **README command index** — added craft-loop, release-train, local-do rows so drift gate lands green

### v0.42.2
- **Retro-gate S3 draft-polish exemption (CDV-184)** — clean session-created Write paths no longer score as edit loops unless a tool error or user rejection intervenes; dual-direction bite-tests + SPEC-012 update

### v0.42.1
- **fix: craft-loop dogfood polish (SPEC-020)** — hold/dogfood/no-write (draft in chat, no `.claude/loops/` write); target+cadence+unit grain as one dialogue slot (L/G/G-fat presets); prefer descriptive program names; cold-start allows declared side artifacts under `.claude/loops/`; goal complete phrasing; list excludes `*.findings.md`/`*.ledger.md`; mid-dialogue product questions resume open craft slot.

### v0.42.0
- **feat: /craft-loop loop-prompt architect (SPEC-020 / CDV-183)** — designs reviewed loop programs for Claude Code's built-in `/loop` and `/goal` (no new runtime). Modes: craft / refine / list; program template + backlog-burn & spec-sync examples; journal + indented `Answer:` decision cards; `.claude/loops/` library. SPEC-020 ACTIVE.

### v0.41.0
- **feat: PreCompact auto-handoff rescue capture (SPEC-018 M12–M18 / CDV-182)** — deterministic LLM-free `PreCompact` hook writes spine+pointer artifacts to `.claude/handoff/<sid>-precompact-<seq>.md` (not M4 brief); `assemble-file` + scoped `--allow-in-progress` freshness carve-out; bounded retention (N=3); fail-open (never blocks compaction); PostCompact/SessionStart pointer surfacing; init-orchestration templates + drift gate; 29 bite-tests. Existing installs: re-run `/init-orchestration` to wire hooks.

### v0.40.0
- **feat: release train queue coordinator (SPEC-023 / CDV-181)** — `/release-train` + `skills/release-train/train-lib.sh`: manual queue, frozen slot versions, mechanical M5a–d conflict pre-resolve (TDD index/VH/CHANGELOG/JSON), agent-driven `/release <assigned>` per entry; `--dry-run`/print-only inert; abort-safe queue under `.claude/release-train/`. `/release` gains **skip-if-present** for explicit CHANGELOG headings (train Option A). 64 unit + 13 integration tests. SPEC-023 ACTIVE.

### v0.39.0
- **feat: skill-bash lint gate (SPEC-021 / CDV-180)** — deterministic LLM-free linter `skills/skill-lint/` (`check-skill-bash.sh` + `lint.py`) for fenced ```bash blocks: C1 cross-block vars, C2 zsh `!`/`<!--` hazards, C3 unguarded globs, C4 captured inline-PRAGMA sqlite; `# lint-ok:` waivers; fixture bite-tests (34); wired as `/release` Step 4.8; live tree lands green (session-state C1s waived). SPEC-021 ACTIVE.

### v0.38.12
- **fix: minor robustness hardening batch (CDV-179)** — per-repo memory-capture dedup + timeout stdin; migrate-v2/v3 `.bail on`; bash-compress `#`-safe via `printf %q`; freshness set -e safe mtime; handoff prepass concurrent stderr + oversize force-split; plugin-dir tier2 versioned layout; retro-gate path encoding; download-extensions quoted `.load`.

### v0.38.11
- **fix: stop-review counts dual-status porcelain lines (CDV-178)** — MM/AM/MD/RM were missed by single-column case patterns; now count all porcelain except untracked/ignored. Hook + init-orchestration template stay in sync.

### v0.38.10
- **fix: memory-distill CAS lock fail-closed on sqlite error (CDV-176)** — empty CHANGED from busy/fail was treated as acquired. Require CHANGED==1 with `-cmd ".timeout 5000"`; otherwise stop with holder diagnostic.

### v0.38.9
- **fix: download-extensions hash-mismatch falls back instead of abort (CDV-175)** — call sites use `|| true`; helpers return 1 on curl/hash fail; SQL-escape embedding URL/model. Init reaches embedding_mode=fallback with exit 0.

### v0.38.8
- **fix: migrate-md never deletes .md after partial/zero migration (CDV-172)** — short chunks (≤20 chars after strip) were dropped without incrementing `FAILED`, so zero-row or partial migrations still `rm`'d source memory files. Per-file fail-closed: only delete when every considered chunk inserted and none skipped; warn + preserve file otherwise.

### v0.38.7
- **fix: PDH-resolve remaining orchestrate/kickoff helpers + bootstrap PROJ_ROOT (CDV-174)** — cycle-gate / task-store / sidecar / detect-mode call sites still used cwd-relative `bash skills/…`, which silently fails (exit 127) on consumer installs. All resolve via `$PDH` + `plugin-dir.sh` per block. Scaffold-project and init-orchestration Step 7 anchor every `.claude/`/`specs/` op on `PROJ_ROOT=$(git rev-parse --show-toplevel || pwd)` so subdir invocation cannot split the tree. Emitted hooks keep `git-common-dir` (documented). SPEC-002 updated.

### v0.38.6
- **fix: worktree-lib non-TTY fresh-lock aborts cleanly (CDV-201)** — `[ -r /dev/tty ]` is true without a controlling terminal; `printf >/dev/tty` then fails ENXIO under `set -e` → messy exit 1. Probe TTY by successful write (`printf 2>/dev/null >/dev/tty`); on failure take stderr path and **exit 2** (abort). Steal only on explicit `steal`. SPEC-016 documents non-TTY exit 2.

### v0.38.5
- **fix: orchestrate Step 8.5 single-shell CI-watch arming + define BRANCH (CDV-177)** — arming was four separate bash fences sharing vars (each fence is a fresh shell), and `$BRANCH` was never assigned, so sidecar init could run with empty mode/pr/branch. Merged into one self-contained block that re-derives roots, reads branch via `git -C "$WT_PATH"`, detects mode, draft-PR, guards empty MODE/BRANCH, then `sidecar init`. CronCreate remains a separate tool step.

### v0.38.4
- **fix: create worktree memory dir before context.md write (CDV-173)** — session-end context snapshot wrote to `$WTROOT/.claude/memory/<agent>/context.md` without `mkdir -p`, so every fresh orchestrate worktree failed the write (`.claude/` is gitignored). Partial `protocol.md` now mkdir's first; session-start reads add `sqlite3 -cmd ".timeout 5000"` and `"${HAS_DISTILLED:-0}"`. Re-expanded via sync-includes to all 7 agents; same timeout/guard on orchestrate + memory-recall tiered reads.

### v0.38.3
- **fix: TMPDIR-safe temps in orchestrate/kickoff/council/handoff (CDV-171)** — hard-coded `/tmp` paths broke under sandboxed harnesses with RO `/tmp` and writable `$TMPDIR` (false cycle-gate halt on redirect failure; empty `mktemp` paths). Cycle pre-gates now use `"${TMPDIR:-/tmp}/…"` plus explicit `rc` handling (only rc=1 = circular dependency; other non-zero = "cycle gate could not run"). Council/review-and-commit/handoff use TMPDIR-safe `mktemp` with fail-loud. AGENTS.md documents the convention.

### v0.38.2
- **fix: ci-watch poll_ci no longer treats gh non-zero exit as poll error (CDV-170)** — `gh pr checks --json` exits 1 on failing checks and 8 when pending; the old `if ! result=$(gh …)` path mapped both to `poll_error`/`wait`, so fail→fixer/`cap` was dead code and pending forever inflated `poll_error_count`. Capture stdout + `gh_rc`, gate on `jq type==array`, classify by `bucket`. Exit 8 + non-array → `wait` without error count. SPEC-017 + SKILL.md document the contract; offline `skills/ci-watch/test-poll.sh` (PATH-mock gh) covers fail/cap/pending/poll_error/empty/AC-7.

### v0.38.1
- **fix: harden `install.sh` model-picker and command symlink (opencode)** — three robustness fixes to the v0.38.0 opencode installer, no behavior change on the happy path. (1) The `--assign-models` summary no longer re-derives unvalidated menu indices: a single `resolve_model` helper validates each 1-based choice once and the summary reads its result, so an out-of-range pick (e.g. `99`) can no longer abort the script under `set -u` on an unbound array index, and `0` no longer wraps to bash's negative index and mis-report the last model as assigned; invalid non-empty input now prints a per-tier `⚠ … stays on the session model` notice instead. (2) The prior-install cleanup now `rm -rf`s the command entry (previously it removed only a *symlink*), and the link is created with `ln -sfn`, so a stale real directory at `~/.config/opencode/commands/dev-team` is replaced rather than having the new symlink nested *inside* it. (3) When `jq` is absent the installer now prints an explicit note that it cannot read models or clear existing dev-team model pins (instead of silently leaving stale pins and falling through), and the "nothing to assign" message covers the zero-model case.

### v0.38.0
- **feat: opencode support — run the dev-team agents, commands, and skills under [opencode](https://opencode.ai) alongside Claude Code** — agent `.md` files keep their Claude Code frontmatter (`name`, `description`, `tools`, `model`) plus a single opencode field, `mode: subagent` (Claude Code ignores it). The two runtimes disagree on the `tools:` key — Claude Code wants a comma-separated string, opencode requires an object and **hard-errors** ("Configuration is invalid … Expected object") on the string form — so the source files keep `tools:` (Claude Code needs it for per-agent scoping) and `install.sh` **generates** opencode-valid agent copies with the `tools:` and `model:` lines stripped (Claude Code's tier names aren't opencode model IDs); commands are symlinked as-is, and skills load in place via `opencode.json` `skills.paths`. This preserves Claude Code's per-agent tool scoping — including `council-judge`'s tool-less `tools: ""` (SPEC-013) — while opencode falls back to its own default permissions. By default agents **inherit the session model** — every run clears the dev-team model pins `install.sh` manages, so a no-flag run (or `--reset`) is a clean inherit. Pass `--assign-models` to opt into an interactive per-tier picker (haiku/sonnet/opus → real opencode model IDs written to the `opencode.json` `agent` section); it prompts only with >1 model on a TTY, otherwise it inherits. The internal agents (`council-judge`, `project-init`, `distiller`) always inherit. All 19 command files gain `agent: build` for opencode routing, and the three `$ARGS` references were corrected to `$ARGUMENTS` (the real Claude Code substitution token — this also fixes latent argument parsing in `/handoff`, `/retro`, and `/init-team`). Adds `install.sh`/`uninstall.sh` and an opencode install/usage section in the README. Commands are namespaced `/dev-team/<command>` on opencode.

### v0.37.4
- **docs: information-architecture pass — changelog out of the README, slim router, complete command reference** — the `## Changelog` section (≈580 lines, v0.37.3 → v0.1.0) moved **verbatim** out of `README.md` into this dedicated repo-root **`CHANGELOG.md`**. `README.md` dropped from **962 → 251 lines**, reshaped from a kitchen-sink into a router (install, agent roster, command index, quick start, workflow) that links into `docs/` instead of duplicating the setup/memory/permissions content that already lived there. Added **`docs/README.md`** as a documentation hub indexing every command (dedicated page or guide link, so nothing is left undocumented), plus five new full command pages — `docs/commands/{council,handoff,debug,refactor,blind-review}.md` — each written from its own source and styled after the existing `orchestrate.md`. Verified: README + all `docs/` have zero broken relative links and the `setup.md` section anchors resolve under GitHub's anchor algorithm.
- **chore: repoint the release pipeline and version-sync contract at `CHANGELOG.md`** — `skills/release/SKILL.md` Steps 2/3a/4/5 now generate, write to, verify, and stage `CHANGELOG.md` rather than the README changelog; the README is treated as an ordinary source file that may change per release. `SPEC-002` (the three version-synced files are now `plugin.json`, `marketplace.json`, **`CHANGELOG.md`** — not the README) and `SPEC-010` (release MUST writes the new `### vX.Y.Z` section to `CHANGELOG.md`; README carries only a pointer) updated to match, each with a version-history entry; the stale `skills/scout-plugins/SKILL.md` README-changelog reference was corrected. This release is the first to exercise the new flow end-to-end.
- **fix: document feature-line versioning policy in `/release` (CDV-23)** — `/release` now spells out how a multi-PR feature arc tracked by a single spec may hold subsequent increments under one minor line via an explicit `/release patch` while keeping honest `feat:` commit subjects, with SPEC-019's 0.37.x arc as the worked example.

### v0.37.3
- **feat: `/local-do` — standalone local-agent offload command** — a new user-invokable command that runs the SPEC-019 offload loop on a single task without spinning up a full `/orchestrate`: `/local-do <brief> --check <shell-expr> [--worktree <path>]` (worktree defaults to cwd, validated as a git worktree). It calls the `skills/local-agent/run.sh` engine and branches on its exit code — `2` → fall back to Claude, `1` → re-attempt against the machine-check (capped at 2 local tries), `0` → review — then has the invoking Claude review the resulting diff directly (lightweight, not a council run) and escalates to Claude with the partial diff after 2 rejected reviews (the same two-cap escalation `/orchestrate` uses). Deliberately built **standalone**: a line-by-line diff against orchestrate's offload sub-block found ~0 verbatim-shared prose, so a managed-include extraction would have added surface rather than removed it — `skills/orchestrate/SKILL.md` is left untouched. `/debug` and `/refactor` are documented as future consumers (not yet wired). Also corrects the `skills/local-agent/` SKILL description — which misleadingly read as a user-facing capability — to mark it the **internal engine primitive** driven by `/orchestrate` and `/local-do`.

### v0.37.2
- **feat: SPEC-019 OS-leash — bubblewrap FS confinement for the local agent (CDV-21)** — the local agent's `opencode run` is now wrapped in a bubblewrap sandbox when `bwrap` is present, upgrading the PR1 best-effort `--dir` leash to **OS-enforced filesystem confinement**: deny-by-default (`--ro-bind / /`, private `--dev`/`--proc`/`--tmpfs /tmp`), with read-write access bound only to the ticket worktree, **its git plumbing** (resolved gitdir + git-common-dir — required because a linked worktree's `.git` points *outside* the tree, so git index/ref writes would otherwise fail), and opencode's XDG state dirs; everything else is read-only. Opt-in and graceful: absent `bwrap`, `LOCAL_AGENT_SANDBOX=0`, or a failed pre-flight probe falls back to the best-effort `--dir` path with a one-line notice, and the exit-code contract (`0`/`1`/`2`/`64`) is unchanged in every mode. Only the `opencode` call is sandboxed — the caller-supplied `--check` runs unconfined on the host (trusted verification). Network egress is intentionally **not** restricted here (no `--unshare-net`); an egress allowlist remains a separate future ticket. Empirically verified with the harness sandbox off: writes outside the bound set are blocked, a real opencode run completes confined, and the gitdir bind is load-bearing (negative control fails without it). SPEC-019's isolation MUST upgraded from "best-effort" to "OS-enforced when available."

### v0.37.1
- **feat: SPEC-019 PR2 — local-agent offload now wired into orchestration** — the opt-in offload engine from v0.37.0 is routed by `/orchestrate`: a routing fork before the Step 8 spawn fence sends eligible mechanical tasks (ic4-class implementation / discovery / docs, gated on a per-task `Machine-check:` field + an `opencode` preflight) to `skills/local-agent/run.sh`, with a hard forbidden-agent guard (tech-lead / ic5 / QA-gate / council judge+investigators / PM / release are never offloaded). Adds a two-cap offload-review loop — 2 local machine-check retries (exit 1) and 2 Claude-reviewed retries (exit-0 reject, reusing council `diff-mode`) — that escalates to the Claude executor with the partial worktree diff as context. New `skills/local-agent/emit-orch-metric.sh` writes the orchestrator-owned companion metrics record (`{ts, ticket, saved_est_tokens, spent_review_escalation}`) to `.claude/local-agent/metrics.jsonl`; `run.sh` stays byte-frozen; `saved_est_tokens` uses labeled constants and `spent_review_escalation` is pinned `null` (no fabricated token meter). Adds a `/standup` local-vs-Claude routing surface. The `skills/orchestrate/SKILL.md` edit is strictly additive (the Claude spawn fence, DAG fan-out loop, and Step-9 review body are untouched). **SPEC-019 promoted DRAFT → ACTIVE.**

### v0.37.0
- **feat: local-agent offload via OpenCode — opt-in wrapper (SPEC-019 PR1)** — new `skills/local-agent/run.sh` pure-subprocess CLI that offloads mechanical, machine-verifiable work to a local model through `opencode run`, gated behind an opt-in `LOCAL_AGENT=opencode` env flag (off by default; unset → transparent fallback to Claude). Preflight checks `opencode` on PATH + an `opencode --version` liveness probe; invokes `opencode run --dir <worktree> "<brief>"` (worktree-scoped cwd, brief passed positionally, nothing from memory/cortex/credentials appended); runs the caller-supplied machine-check via `bash -c` (never `eval`); exit-code contract `0`=success / `1`=check-failed / `2`=fallback / `64`=usage; appends one JSONL record per terminal path to `.claude/local-agent/metrics.jsonl` (`{ts, outcome, exit_code, saved_est_tokens, spent_tokens}`, jq-guarded, `saved_est_tokens` null in PR1). Leash is best-effort (`--dir` + OpenCode's own permission config; OS-level enforcement is a documented residual risk deferred to a follow-up). Ships the standalone engine only — orchestrate routing + Claude diff-review + 2-attempt escalation are PR2. Adds `SPEC-019` (DRAFT), the `skills/local-agent/SKILL.md` contract, and an AGENTS.md opt-in note.

### v0.36.43
- **fix: security hardening — remove eval, validate uuid, disambiguate command-rewrite, document autonomy risk (blind-review)** — `/handoff` no longer `eval`s shell assignments built from session-transcript content (`read_plan` now emits NUL-delimited field values read into the same vars via `IFS= read -r -d ''`), closing an arbitrary-command-execution path (022 — verified injection-safe); `skills/handoff/prepass.sh` now validates its `--uuid` shape in-script (rejects `/`, `..`, anything outside `[A-Za-z0-9._-]`) instead of trusting the caller, closing a path-traversal gap (032); the bash-compress hook's brittle `_ccout=$(( … ))` was disambiguated to `$( ( … ) )` (command-substitution, not arithmetic), in lockstep with its init-orchestration template (033); and the orchestration `bypassPermissions`/`Bash(*)` default now carries an explicit blast-radius risk note in init-orchestration + SPEC-002 — the posture is intentional, the documentation of it was missing (031). (blind-review CLUSTER-022/031/032/033).

### v0.36.42
- **fix: blind-review nit cleanup — spec/code reconciliations & stale doc-comments (blind-review)** — nine small fixes: SPEC-002's bash-compress "noisy commands" list reworded as non-exhaustive to match the hook (005); `dag-lib.sh`'s docstring + the kickoff user message now describe the actual cycle back-edge instead of a full path (006); corrected the overstated "replaces ~15 locators" claim in README/SPEC-002 to acknowledge the remaining best-effort `embed-one.sh` locator (013); aligned SPEC-002 to the Stop hook's actual cwd+HEAD reminder keying (014) and SPEC-017 to `detect-mode`'s pytest-section requirement for `pyproject.toml` (021); made `migrate-v3.sh` idempotent against a partially-applied prior run (probes `PRAGMA table_info` before each `ADD COLUMN`) (026); corrected the distiller agent's "exclusively sqlite3 CLI" rule to match its actual Bash/python3/Read usage (028); marked `ci-watch` "Not user-invoked — armed by /orchestrate" like its peers (034); and replaced brittle `SPEC-002:NN` line-number citations in the task-completed hook with quoted phrases, in lockstep with its init-orchestration template (024). (blind-review CLUSTER-005/006/013/014/021/026/028/034/024).

### v0.36.41
- **fix: reconcile memory-store embedding & truncation contracts (blind-review)** — corrected the false "single source of truth" claim in `embed-one.sh` / `memory-store/SKILL.md` (migrate-md.sh has its own bulk-migration embedding path, it is not a caller) and aligned the embedding-input truncation to **1500** in both, so a memory embeds over the same amount of text regardless of write path (017); fixed the `##`-section chunk-storage truncation in `migrate-md.sh` to the SPEC-004-mandated **8000** chars (was 5000; the no-header fallback correctly stays 5000) (018); added `embed-one.sh` and `migrate.sh` to SPEC-004's `Covers` (030); and made remote-mode embedding **fail loud-but-nonfatal** when the `vec0` extension is absent (it was silently dropped), with README/SKILL now clarifying that remote mode still requires vec0 to store/query vectors (016). (blind-review CLUSTER-016/017/018/030).

### v0.36.40
- **fix: replace the broken PID-liveness worktree lock with an advisory age-gated lock (blind-review)** — `skills/worktree-lib.sh` recorded its own ephemeral PID in `.wt-lock` (the `ensure` subprocess exits within milliseconds), so the `kill -0` collision check always read "stale" and silently overwrote — two parallel runs could grab the same worktree, defeating the lock's purpose. Investigation confirmed there is no live holder process to track (the holder is an LLM agent/conversation, not an OS PID) and no session id is available to the script, so PID-liveness is structurally unworkable. The lock is now advisory: one line `<epoch> <ISO-8601-UTC>`; an existing lock younger than `WT_LOCK_TTL_SECONDS` (default 6h) prompts abort/steal, while an older/corrupt/legacy lock is reclaimed as stale. SPEC-016's PID-authoritative MUSTs were relaxed to the age-based model — which also reconciles the prior 3-field-spec vs 2-field-code drift (legacy `PID TIMESTAMP` locks auto-reclaim). (blind-review: wt-lock ephemeral-PID bug + CLUSTER-004).

### v0.36.39
- **fix: verify downloaded native extensions & model against pinned SHA-256 (blind-review)** — `skills/memory-store/download-extensions.sh` fetched the sqlite-vec / sqlite-lembed native extensions and the embedding model over the network and `.load`ed the extensions as native code with **no integrity check** (a MITM or a compromised release asset would mean arbitrary code execution). Now every artifact is verified against a pinned SHA-256 **before** extraction/load — fail-closed: a hash mismatch, a missing pinned hash, or no available sha256 tool aborts without extracting or loading. The tarball is hashed pre-extraction (download→verify→extract, replacing the old `curl | tar` pipe), and the model URL's floating `main` ref is pinned to commit `7a7bac3`. Pinned hashes (4 vec0 + 3 lembed0 platforms + model) live next to the version constants with a regenerate-after-bump note. Verified fail-closed — a tampered payload aborts before any `.load`. (blind-review CLUSTER-010).

### v0.36.38
- **fix: harden the memory subsystem against SQL injection (blind-review)** — the semantic-search and `LIKE` paths in `skills/memory-recall/SKILL.md` and `commands/memory-search.md` interpolated the raw user query into SQL unescaped (only the keyword path escaped it); they now apply the same `'`→`''` escaping everywhere, and the remote-endpoint `$QUERY_EMBEDDING` is charset-validated (a network trust boundary) before use. In `skills/memory-store/embed-one.sh` and `migrate-md.sh`, the endpoint-supplied `$DIMS`, row id, and embedding vector are strictly validated (`^[0-9]+$` / numeric-array charset) before being interpolated into `CREATE`/`INSERT`, so a compromised embedding endpoint can no longer inject SQL. Proven with an injection test (`o'brien'); DROP TABLE…` is now neutralized as a literal). Tightens the v0.19.3 "SQL injection eliminated" claim, which had not actually covered the read/query or embedding-write paths. (blind-review CLUSTER-008/009).

### v0.36.37
- **fix: resolve plugin helper scripts via `plugin-dir.sh` — repair the consumer-install hard-break (blind-review)** — `/orchestrate`, `/wrap-ticket`, `/standup`, and `/ci-watch` invoked their helper scripts via the dogfood-only path `bash "$MROOT/skills/X.sh"`, where `$MROOT` is the *user's* project root — so on a real (cache) install the scripts are absent, `bash` exits 127, and the flow halts (it only "worked" when dogfooding, where cwd == the plugin checkout). Converted every such call site to resolve through the install-aware `plugin-dir.sh` (the same pattern those files already use for retro-gate/council), covering `worktree-lib.sh`, `dag-lib.sh`, and the ci-watch `sidecar`/`detect-mode` helpers; all five helpers were confirmed to self-resolve their data root, so none needed internal changes. Updated SPEC-016's caller-integration MUSTs (dropped the cwd-relative mandate) and SPEC-002's resolution-site table (11→15 sites) to match. (blind-review CLUSTER-003).

### v0.36.36
- **fix: reconcile council documentation with `engine.sh` behavior (blind-review)** — six doc/code-drift fixes in the council subsystem: the deferred-scope and no-scope error messages that `skills/council/SKILL.md` called "exact" now quote `engine.sh`'s actual output verbatim; removed the phantom exit-code 8 row (the engine emits 0–7; empty/refused judge output is exit 7); corrected `skills/release/SKILL.md`'s gate-coverage note (the template-var gate covers 5 prompts incl. `phase4-brief` and defers nothing — prosecutor/advocate were merged into it); added the user→engine flag mapping (`--session`/`--diff`/`--plan`/`<claim>` → `--scope`/`--scope-arg`) to `commands/council.md` preflight and reworded the false "engine detects multiple scope arguments" claim; removed the unreachable `from-retro|plan` branches in `engine.sh`; and replaced two off-by-one `SPEC-013 line N` citations with rot-proof quoted phrases. `check-template-vars.sh` still passes. (blind-review CLUSTER-007/015/025/027/029/023).

### v0.36.35
- **fix: reconcile the SPEC-017 row in the TDD index (blind-review)** — `specs/TDD.md` listed SPEC-017 as `DRAFT` with a 5-path Coverage column, but the spec's own header is `**Status**: ACTIVE` (since 2026-04-30) and its `**Covers**:` list names 10 paths — a SPEC-008 index-integrity violation for a fully-shipped, smoke-tested feature. Set Status → `ACTIVE` and expanded Coverage to all 10 paths (adds `skills/orchestrate/dag-lib.sh` and `skills/ci-watch/{SKILL.md,poll.sh,sidecar.sh,detect-mode.sh}`). Doc-only; the sole file-vs-index status mismatch among the 18 specs. (blind-review CLUSTER-002/020).

### v0.36.34
- **fix: clarify `.claude/settings.json` is generated, not shipped, and document the two-mode permission posture (blind-review)** — three README claims that the plugin "ships"/"bundles"/"already ships" `.claude/settings.json` were false (the file is gitignored/untracked; it is generated locally by `/scaffold-project` and `/init-orchestration`) and contradicted the README's own AUDIT-P0.12 changelog — reworded to "generated, not shipped". Documented the two real permission modes instead of one false guarantee: `/scaffold-project`'s curated **interactive** allowlist (rm/wget excluded, still prompt) vs **orchestration** mode (`/init-team` → `Bash(*)`; `/init-orchestration` → `bypassPermissions`) contained by the OS sandbox. Fixed `AGENTS.md` (init-team sets `Bash(*)` and syncs the network allowlist — not "only the network allowlist, not the permission list") and `docs/setup.md` (init-team syncs the sandbox **network** allowlist, not the Bash permission list). Doc-only. (blind-review CLUSTER-001/019).

### v0.36.33
- **fix: align the council-judge prose to its evidence-only design (AUDIT-P4.4)** — `agents/council-judge.md` told a `tools: ""` agent to `Read SPEC-013` and asserted its tech-lead cortex "is injected by the council engine", but no injection exists (the Phase-5 spawn substitutes only 5 template vars; `engine.sh` has zero cortex code) and the agent cannot run Read. Reworded the Session-Start checklist to a passive standing-rules statement ("you do not read any spec or file… you cannot run tools"), softened the cortex claim to optional engine-prepended calibration the judge functions without, and **relaxed the matching SPEC-013 contract in the same change** — the Phase-5 cortex MUST (:97), the Overview (:13), and the validation checkbox (:252) no longer mandate an unimplemented cortex-load path (the Judge's authority is the evidence bundle + its standing behavioral rules; cortex is optional). Also de-duplicated the explanatory framing in `skills/council/prompts/judge.md` to a pointer at the agent file while keeping its verbatim runtime payload intact. Docs-only, patch-scoped — reconciles all three layers to the shipped reality rather than building new engine-side injection for a by-design evidence-only judge. (AUDIT-P4.4).
- **🎉 Completes the consolidation-audit release train (AUDIT-P0 → P1 → P2 → P3 → P4).**

### v0.36.32
- **fix: stale counts, a dead block, and decorative comments in the agent docs (AUDIT-P4.3)** — `project-init` claimed "6 roles/files" though 7 agents are enumerated (frontmatter + loop), carried a **dead storage-detect block** whose `USE_DB` var was never read and whose comment named a non-existent "Step 3b", `distiller`'s distillation step list skipped number 4 (1,2,3,5,6), `migrate-v2.sh`'s header mislabeled the heredoc range ("Steps 2-9" vs the actual 1a..12) and restated every statement with decorative `-- Step N` comments, and `scaffold-project`'s `.claude/` file-tree omitted the `settings.json` that Step 2b creates. Corrected all counts to 7, deleted the dead block (Step 3's `MEMORY_BACKEND` detect stays — verified `USE_DB` is now grep-absent), renumbered the list sequentially, fixed the header and dropped the noise comments (**SQL byte-identical, migrate v1→v2 verified end-to-end**), and added the `settings.json` tree row. The `/validate-memory` triple-grep "hoist" was deliberately skipped (the three blocks aren't byte-identical — distinct if/elif branches). Doc/comment-only, no behavior change. (AUDIT-P4.3).

### v0.36.31
- **fix: correct stale doc-comments and a report template that contradict current code (AUDIT-P4.2)** — eight doc/template-only fixes, no behavior change: `report-finding.md` dropped three static severity subheadings + two `_See findings above._` filler buckets above `{{FINDINGS}}` (which `engine.sh` already fills with per-finding `### [SEVERITY] file:line` headings) and now describes the section accurately (findings carry their own severity inline, emitted in judge order — **not** the false "ordered critical → warning → nitpick" an adversarial check caught the first draft re-introducing); `retro.md` fixed a non-existent "Step 4a" reference (→ Step 4c) and added the missing `fabrication_anchor` row to the Step-4d row-format box; four fake `msg_`-prefixed example ids were switched to UUIDs (`gate.sh`, retro-gate SKILL, retro-subagent SKILL — consistent with the "ids are UUIDs, not `msg_`" note those files already carry); a stale `gate.sh:77-81` line cite was re-pointed to the drift-proof `S4_RE` symbol; and a phantom "warm-mode section appended to this file" cross-ref in the handoff SKILL was re-pointed to `commands/handoff.md` Step 1b. Engine/gate logic untouched. (AUDIT-P4.2).

### v0.36.30
- **fix: strip build-arc plan-graph narration from shipped docs & comments (AUDIT-P4.1)** — removed the private build-task references (COUNCIL-001/CDV-10 `T`-numbers like "(T6)/(committed in T3)/After the T13 refactor", `(Task N)` parentheticals, one-time session anecdotes like the CDV-151 PM note and the "19,762 message contents, 0 diffs" run log) that had shipped as comments/prose across the council skill+flavors+engine, handoff, transcript-parse, orchestrate, retro, ci-watch, and the task-completed hook — meaningless to users/consumers. Also flipped transcript-parse's self-contradicting "PLANNED (Task 3)" section headers to "present" (both files exist) and de-narrated the `engine.sh`/`gate.sh` runtime strings. **Carefully preserved** the legitimate surfaces: the shipped `COUNCIL-001/002` feature/scope-gate identifier (appears in fail-loud runtime messages), the `Task 1/2/…` example-DAG illustrations, and `CDV-N` issue-ID placeholders. The `(preserve verbatim)` build-comment was removed from **both** the live `task-completed.sh` and its emitted init-orchestration template in lockstep so the G3 byte-match drift-gate stays green. 22 files, no behavior change. (AUDIT-P4.1).

### v0.36.29
- **fix: backlog hygiene — stale item bodies, phantom paths, and the backlog format contract (AUDIT-P3.6)** — rewrote `.claude/backlog/bash-output-compression.md`'s body (still describing the abandoned PostToolUse "blocked/deferred" design) to the **shipped PreToolUse + `updatedInput` design** that matches `.claude/hooks/bash-compress.sh`, so it no longer contradicts its own COMPLETED status; fixed `agent-notification-sink.md`'s phantom Affects paths (`skills/init-orchestration/memory-capture.sh` → `.claude/hooks/memory-capture.sh`; `commands/orchestrate.md` → `skills/orchestrate/SKILL.md`); reworded `worktree-skill-user-invocable.md`'s stale "must ship first" prerequisite to satisfied (worktree-lib.sh shipped); and reconciled `skills/backlog/SKILL.md`'s three-way add-template ↔ Format-Reference drift — both now document the `## Affects` and `## Effort` (optional) sections that real items use, plus a note on ad-hoc sections, and Status includes DEFERRED. Doc-only; out-of-scope items (session-cost-tracking, the --why/token items) verified correct and left untouched. (AUDIT-P3.6).

### v0.36.28
- **fix: spec cross-duplication & format hygiene pass (AUDIT-P3.5b)** — editorial reconciliation across the spec set: normalized three emoji-prefixed/non-canonical Status fields to plain SPEC-008 taxonomy words matching the TDD index (`SPEC-012`/`SPEC-014`→APPROVED, `SPEC-013`→ACTIVE); replaced `SPEC-009`'s stale 5-field task-store schema with a pointer to `SPEC-017`'s canonical 6-field schema and pointed its READY/uncommitted-worktree MUSTs at SPEC-017/SPEC-016; gave `SPEC-012` a shared-transcript-parsing-seam MUST + Covers (so `SPEC-018`'s "see SPEC-012" citation resolves) and reconciled the TDD index ownership; trimmed `SPEC-003`'s directives restatement to a pointer at `SPEC-001` and the `SPEC-007`/`SPEC-011` `busy_timeout` MUSTs to `per SPEC-004`; reordered `SPEC-013` + TDD version-history rows chronologically; de-chained the WSL2-hazardous `git worktree remove && git branch -D` in `SPEC-005`/demo to separate calls; added the missing `SPEC-005↔016` cross-reference; and normalized `SPEC-018`'s `Category: Core`→`core`. Doc-only; all touched specs pass `check-format.sh`. The audit's inverted/evaporated sub-claims (009→002 hook MUSTs, DDL restatement, CLAUDE_TASK_ID/threshold/settings) were verified and left as legitimately distinct. (AUDIT-P3.5b).

### v0.36.27
- **fix: re-sync the bash-compress hook spec, delete the dead wrapper, and align migrator FK clauses with schema.sql (AUDIT-P3.5a)** — `SPEC-002` still MUST'd piping output through a `bash-compress-wrapper.sh` that no longer exists (the live hook inlines the rewrite via `jq -n --arg cmd` → `updatedInput.command`), so the MUST is rewritten to the shipped inline design and the vestigial wrapper script is deleted (nothing live referenced it; the G3 drift-gate checks the inline hook). Separately, `migrate-v2.sh` (`distillation_log.result_memory_id`) and `migrate-v3.sh` (`validation_log.memory_id`) omitted the `REFERENCES memories(id)` FK that `schema.sql` ships, so a migrated DB and a fresh DB diverged — both now emit schema.sql's exact column DDL (FK is correct-on-create and inert during the `foreign_keys=OFF` table rebuild; verified valid + `foreign_key_check` clean). `schema.sql` is added to `SPEC-004`'s Covers as its normative home (`migrate-v3.sh` stays owned by SPEC-011 — not double-listed); TDD index + Version-History updated per the spec-update procedure. (AUDIT-P3.5a).

### v0.36.26
- **fix: converge divergent commit-trailer literals onto one model-agnostic form (AUDIT-P3.4)** — five `Co-Authored-By` trailers (the scaffold-project + init-orchestration emitted AGENTS templates, the `manual.md` runbook example, and the plugin's own `/orchestrate` squash-merge) had drifted into three forms: the stale `Claude Sonnet 4.6`, a no-model `Claude`, and the release form. All five now use one **model-agnostic** form — `Co-Authored-By: Claude <model> <noreply@anthropic.com>` — so a consumer project fills in whatever model is doing the work instead of inheriting a hardcoded one. Each literal was fixed in place (no managed-include — these are independent surfaces per D2/SPEC-005); the `skills/release/SKILL.md` release contract (`Claude <Model> (1M context)`, this repo's own convention) and the `/orchestrate` PR-body footer are left untouched, and legitimate Sonnet model-tier assignments elsewhere are unaffected. (AUDIT-P3.4).

### v0.36.25
- **fix: purge worktree fossils and de-dup orchestration prose in the runbooks (AUDIT-P3.3)** — `docs/runbooks/manual.md` taught the SPEC-016/AGENTS.md-**forbidden** sibling-directory worktree pattern (`git worktree add ../project-ENG-123` / `git worktree remove ../…`) and `docs/runbooks/orchestrate.md`'s worked example printed `../project-POC-123`; replaced all three with the canonical `bash skills/worktree-lib.sh ensure|release <slug>` CLI and `.worktrees/<slug>` paths. The runbook's "Escalation Triggers" and "Change Discipline" blocks were byte-duplicates of the `/orchestrate` command page (verified by `diff` before removing) → collapsed to one-line links so the command doc stays the single source. `idea-to-plan.md`'s brainstorm example was left as-is (it's the runbook's running ENG-456 example threaded through later steps, not a verbatim copy). Doc-only, two files; `manual.md`'s stale model trailer is left for P3.4. (AUDIT-P3.3).

### v0.36.24
- **fix: reconcile the README/AGENTS rosters, command tables, and release/allowlist claims (AUDIT-P3.2)** — the agent roster in both `README.md` and `AGENTS.md` omitted `council-judge` (violating AGENTS.md's own "update the roster" rule); added it to both, framed as an internal (non-behavioral) agent alongside `project-init`/`distiller` so the "7 behavioral agents" wording stays correct. Added the missing `/blind-review`, `/validate-memory`, and `/demo` rows to the README command tables; added a `Task*` shorthand footnote; deduped the install block + the triple "~29MB" note. `AGENTS.md` "Release Rules" now **cites** `skills/release/SKILL.md` as the authoritative commit-format contract instead of restating it (single source). Corrected three false allowlist claims: `curl` is **allowed** (not "intentionally excluded" — it's in the emitted allowlist for downloads/remote-embedding; only `rm`/`wget` are excluded), the stale "41 entries" count → a reference to the canonical emitter (now 43), and the attribution that `/init-team` emits the Bash allowlist (it only syncs the sandbox **network** allowlist — only `/scaffold-project` emits the Bash permission list; fixed at both `README` and `AGENTS.md`). Scope: this repo's `README.md`/`AGENTS.md` + the one scaffold-project curl note — the SPEC-005/010-locked emitted consumer template was not touched. (AUDIT-P3.2).

### v0.36.23
- **fix: correct stale references in the `docs/commands/` guides (AUDIT-P3.1)** — fixed the only dead intra-docs link (`docs/commands/retro.md` pointed at a nonexistent `./adjust-agent.md` — de-linked to plain text, since `/adjust-agent` has its own SKILL) and three stale literals in `docs/commands/wrap-ticket.md`: "runs seven steps" → "nine steps" (the list has nine), the Step-1 cross-reference "removal in Step 6" → "Step 8" (worktree removal moved to item 8 when the file-store-authoritative verify step landed in P0.5), and the memory-size warning "exceeds 150 lines" → "exceeds its SPEC-004 line limit (memory: 50 lines)" (the last surviving 150-literal after P1-1 reconciled the limit to 50 everywhere else). The audit's broader "7+ pages frozen at pre-council architecture" premise had already evaporated — the pages document the current council+worktree flow. Doc-only, two files. (AUDIT-P3.1).

### v0.36.22
- **fix: bootstrap-triangle gitignore defects in `/adjust-agent` and `/init-team` (AUDIT-P2.8)** — `adjust-agent.md`'s memory-gitignore guard used a single-quoted `grep -qE '^\\.claude/memory(/|$)'` whose **double**-backslash made the ERE branch dead, so a pre-existing bare `.claude/memory` line got a redundant `.claude/memory/` duplicate appended; corrected to a single-backslash ERE. `/init-team` Step 5 re-wrote the same 5-line memory gitignore block that Step 3's `download-extensions.sh` already writes; Step 5 is now a fallback gated on `EXT_GITIGNORE_DONE`, which is set **only when `download-extensions.sh` succeeds** (`&&`-chained — a mid-run abort leaves the flag unset so the fallback still covers the `extensions/`/`models/` dirs the script `mkdir`'d before failing). Net: the block is written exactly once on the normal path yet still covers the `--no-extensions`/no-sqlite/download-failure paths. Scoped to those two concrete defects; the audit's broader "three variants / two settings philosophies / two AGENTS templates" premise had already evaporated (version resolution unified via `plugin-dir.sh` in P1-3, settings precedence assigned by use-case in SPEC-005, AGENTS templates SPEC-005-locked distinct). (AUDIT-P2.8).

### v0.36.21
- **fix: single-source the debug/refactor tiered-cortex block, the root-cause triad, and the `/kickoff` handoff contract (AUDIT-P2.7b)** — three debug/refactor consolidations: (1) the byte-identical tech-lead tiered-cortex query (`HAS_DISTILLED → tier2/tier1 else tier0`) duplicated in `/debug` and `/refactor` Step 0 was extracted to a new `skills/agent-memory/cortex-load.md` partial, expanded into both via `sync-includes.py` markers placed **outside** the ```bash fence (P1-5A leak-safe), and the `/release` G1 drift-gate now covers it (bite-tested: inject drift → exit 1, `apply` heals); scoped to debug+refactor only (the 6 other skills carrying a tiered-cortex fragment are NOT byte-identical and were deliberately excluded — no silent widening). (2) the what/why/originating-layer root-cause triad, restated 3× inside `/debug`, is now one `## Root-cause triad` definition the three modes cite. (3) `/kickoff` had no input schema for the escalation handoff it receives and the two producers' WHY-INLINE-REJECTED enums shared zero values — added a canonical `## Accepted escalation handoff (input contract)` to `/kickoff` (the consumer/contract home per SPEC-014/SPEC-015), reconciled both producers to one 5-value vocabulary, and pointed `SPEC-010`/`SPEC-014`/`SPEC-015` at the single contract. The P2.7a SAFE_PATH hardening (Step 0b) was left untouched. (AUDIT-P2.7b).

### v0.36.20
- **fix: harden the `/debug` affected-path sanitizer and fix a copy-paste skip message (AUDIT-P2.7a)** — both affected-path blocks in `/debug` Step 0b sanitized untrusted `$DESC`-derived paths with only `echo … | tr -cd`, lacking the `printf '%s'` capture (echo mishandles a leading `-`/backslashes), the `*..*` path-traversal rejection, and the `$WTROOT` containment guard that the `/refactor` SKILL already carries — so a crafted path could escape the worktree or be mangled. Ported `/refactor`'s exact three hardenings into both `/debug` blocks (`RAW_PATH` single-quoted capture → `printf` sanitize → traversal `case` → WTROOT-containment), and corrected the test-scan block's empty-path message from the wrongly-copied "skip git log" to "skip test scan". Scope is `skills/debug/SKILL.md` only (a worktree-wide grep confirmed `/debug` and `/refactor` are the sole carriers of the pattern — no shared partial governs them; that dedup is tracked separately as P2.7b). WTROOT was already resolved in Step 0. (AUDIT-P2.7a).

### v0.36.19
- **fix: bring `/orchestrate` spawn templates into terse-MUST compliance + unify the ticket-ID regex across the ci-watch/orchestrate seam (AUDIT-P2.6)** — five `/orchestrate` agent-spawn templates (PM & Tech-Lead Step-4, Step-6 TL-feed, Step-9 review, Step-10 QA) were missing the `Output mode: terse` line that SPEC-003 (MC-4) + SPEC-009 require on every spawn template (only the Step-8 IC spawn had it); all now carry it, plus the now-canonical ci-watch fixer-spawn block. The ticket-ID validators diverged — `sidecar.sh`, `poll.sh`, and `task-store.sh` accepted dots (`[a-zA-Z0-9._-]+`) while `worktree-lib.sh` forbids them, so a dotted ID passed task-create but hard-failed at worktree creation; the three orchestrate/ci-watch validators now reject dots too (`[A-Za-z0-9_-]+`), failing fast at create time (council's separate path-component validators were left untouched — they never feed worktree-lib and are out of this seam's scope). Also: the Step-8.5 idempotent guard now resolves its sidecar via `sidecar.sh path` instead of a hand-built path; the fixer-convention now cites the canonical `ci-watch/SKILL.md` block (which owns the create/inc/update bookkeeping) while keeping the runtime `fixer_active false` line inline; and three stale/brittle hardcoded `SPEC-009 line N` citations were corrected/de-brittled to MUST-text references. (AUDIT-P2.6).

### v0.36.18
- **fix: dedup transcript-parse primitives onto `parselib` + worktree-correct the `/retro` hint (AUDIT-P2.5)** — `skills/transcript-parse/assemble.py` re-implemented `KNOWN_TOP_FIELDS`, line-parsing, the schema-drift warning, and the `isSidechain` check that its sibling `parselib.py` already owns, and its warning text had diverged (ASCII `--` vs parselib's em-dash "seen in first"). `assemble.py` now `sys.path`-injects its own dir and imports `KNOWN_TOP_FIELDS`/`parse_line`/`warn_schema_drift`/`is_sidechain` from `parselib` (true identity — works both as a CLI script and when imported), so the drift warning is byte-identical across consumers and the stale "matches gate.sh" claims are corrected (`gate.sh` keeps its own `retro-gate:`-prefixed variant by design). Sidechain detection now uses parselib's shared `bool(isSidechain)` truthy test (a no-op on real data — transcripts emit JSON booleans — with the SKILL docs updated to match). Separately, `skills/retro-gate/hint.sh` resolved its project dir from `pwd` (wrong in a git worktree, where `pwd ≠ MROOT`) — it now uses the same `git rev-parse --git-common-dir` formula as `/retro` so the friction hint targets the correct session; `set -u` + always-exit-0 preserved. (AUDIT-P2.5).

### v0.36.17
- **fix: enforce `/retro` proposal validation rules 2 & 6 and the EXISTING_RULES `empty` sentinel (AUDIT-P2.4)** — `/retro` violated three clauses of its own validation contract (`skills/retro-subagent/SKILL.md`): rule 6 (confidence ∈ [0,1]) was a no-op comment, so a subagent emitting `confidence > 1.0` inflated `rank = confidence × citation_count` and floated a bogus proposal into the top-5; rule 2 was unenforced, so a proposal whose sole citation had an empty `message_id`/`excerpt` survived; and a missing per-target rules file substituted a blank into the subagent prompt instead of the literal `empty` the contract promises. The fix adds a numeric, in-range confidence gate that **drops** bad proposals *before* the rank multiply, skips empty/malformed citations in `parse_one` (so they fail the existing count gate), and coalesces missing rules files to `empty` on the prompt path only — Step 5b's classifier (which deliberately needs the raw empty string) is byte-for-byte untouched. Single file (`commands/retro.md`); adversarially verified by the orchestrator (the workflow refuters hit a session rate-limit): Rule-6 gate matrix, `parse_one` citation-filter sim, and gate-before-rank ordering all confirmed. (AUDIT-P2.4).

### v0.36.16
- **fix: single-source the `/handoff` section spelling, headings, and leaf rule; skip the redundant `finalize` re-stream (AUDIT-P2.3)** — `skills/handoff/` carried four internal dedup defects: `SECTION_SPEC` used hyphen keys papered over by fuzzy variant-stem acceptance lists while the extractors emit underscore `*.json`; the five section headings rendered three different ways (verbose cold, bare warm, bold-in-SKILL) so warm ≠ cold; the "last surviving uuid" leaf rule was implemented twice; and `finalize` re-streamed the whole (~87 MB) transcript via `compute_leaf()` purely to recompute the M8 cache key that `prepare` had already written to `plan.json`. Fixed: one canonical **UNDERSCORE** spelling end-to-end (`SECTION_SPEC` + emitted filenames + SKILL/command tables, with a single hyphen fallback), one bare-heading source rendered identically by cold and warm, a single `leafrule.py` keep-last-uuid rule reused by both sites, and a new optional `finalize --leaf <uuid>` that uses the already-computed leaf and falls back to `compute_leaf()` only when absent (cache-check's re-stream is deliberately untouched). Verified end-to-end: the M8 cache key is identical whether `--leaf` is passed or recomputed. (AUDIT-P2.3).

### v0.36.15
- **fix: reconcile cross-agent memory search to SPEC-006 (AUDIT-P2.2)** — the `memory-recall` SKILL (nominal owner of the search contract) had drifted *below* SPEC-006 while the commands complied: its queries returned raw `e.distance` instead of `(1 − distance)·100` similarity, defaulted limits to 5 instead of top-10 semantic / up-to-20 keyword, and the lembed branch hardcoded `vec_memories_384` (breaking 768-dim configs). Brought the SKILL up to spec (score `(1−distance)·100 || '%'`, `k=10`/`LIMIT 20`, dimension-correct `vec_memories_${DIMS}` with a numeric-DIMS guard); unified the `--status` archived-counting convention across `memory-search`/`memory-distill` (per-tier, archived excluded from the active digests/core columns — `memory-distill`'s form chosen as canonical); fixed `memory-stats` to exclude archived rows from all counts and report "Boot load" as only what the tiered protocol actually loads (a CTE: tier-1+tier-2 when distilled, else tier-0); and annotated `/recall`'s keyword block as an intentional keyword-only cross-source specialization citing `memory-recall` Step 3. Scope = the search surface only — Step 2's `sync-includes` managed-include read region is untouched and the G1 drift-gate still passes. (AUDIT-P2.2).

### v0.36.14
- **fix: stop restating SKILL-owned contracts in `/validate-memory` and restore the dropped 8-claim cap (AUDIT-P2.1)** — `commands/validate-memory.md` duplicated six contracts owned by `skills/validate-memory/SKILL.md` (extractor rules, verdict taxonomy, `claim_type` list, investigator rules, scoring narrative, batching caps), and the copies had drifted — most consequentially Step 3.3 listed only 5 of 6 extractor rules, **silently dropping the "Maximum 8 claims per memory" cap** that bounds the per-memory score denominator. Each block now cites its owning `SKILL.md` section by name (D1: SPEC defines, SKILL carries the one operational copy, command cites — never restates), and the missing cap is restored as an enforced rule ("truncate extractions that exceed it"). Doc-only, single file: the SPEC-011 Tier-A bash checks and the executable composite-scoring computation are untouched; the batching numbers already agreed, so no behavior change beyond the restored cap. (AUDIT-P2.1).

### v0.36.13
- **fix: stop poisoning the captured agent-memory `MEMORY_ID` on sqlite ≥ 3.51.2 (AUDIT-P0.16)** — the agent-memory write protocol captured the new row id with an inline `PRAGMA busy_timeout=5000;` assignment *inside* the `$(…)` feeding `MEMORY_ID`; on sqlite ≥ 3.51.2 that assignment emits a `5000` result row, so `MEMORY_ID` became `5000\n<rowid>` and the malformed id was passed to `embed-one.sh` — silently breaking agent-memory embeddings (the memory row still wrote, but its embedding was keyed to a bad id). Replaced the result-emitting PRAGMA with `sqlite3 -cmd ".timeout 5000"`, which sets the same busy timeout without emitting a row and keeps the `INSERT` + `last_insert_rowid()` in one session. Fixed across the canonical `skills/agent-memory/protocol.md` partial (both the primary capture and the SQLITE_BUSY retry-fallback), the **7 agents re-expanded via `sync-includes.py apply`** (not hand-edited — the `/release` managed-include drift-gate stays green), and the standalone `wrap-ticket` capture. Same poison-row class as AUDIT-P0.8/P0.15, in the rowid write-capture path; the non-capturing bare-INSERT PRAGMAs elsewhere are not poison and were left untouched. (AUDIT-P0.16).

### v0.36.12
- **fix: remove the inline `PRAGMA busy_timeout` from all 5 captured-read sites in `migrate-md.sh` (AUDIT-P0.15)** — on sqlite ≥ 3.51.2 a `PRAGMA busy_timeout=5000;` inside a captured `$(sqlite3 … "PRAGMA …; SELECT …")` emits a `5000` result row that prepends to the captured value, corrupting `EMBED_MODE` (wrongly entering the embed block), the `UNEMBEDDED`/`TOTAL_ROWS` counts (arithmetic errors), `EMBED_URL` (a broken curl target), and the `while read MEM_ID` loop (a spurious first id `5000`). All five captured reads now use `sqlite3 -cmd ".timeout 5000"`, which sets the same busy timeout via a dot-command that emits no result row (mirroring the AUDIT-P0.8 migrate-v3 fix); the four `db.execute('PRAGMA busy_timeout=5000')` Python write-path calls are correct and untouched. This bug was discovered during AUDIT-P0.8 (same poison-row class, separate `.md`-embedding migration path). (AUDIT-P0.15).

### v0.36.11
- **fix: single-source the `/retro` proposal-TSV schema and thread provenance + citation pairs end-to-end (AUDIT-P0.7)** — `commands/retro.md`'s CLASSIFIED_PROPOSALS TSV schema was restated three times and had drifted into two live bugs: the Step-5c rebuild overwrote `source_jsonl` with `best_jaccard` (so `--all` mode's per-session count was unimplementable), and the parser collapsed citations to `len(cites)` (so the `Evidence:` display could only ever show a number). Fixed by defining the column layout **once** as a canonical 9-column block — adding `source_jsonl` (col 8) and a TSV-safe JSON `citations_json` (col 9, `[{message_id, excerpt}…]`) rather than overwriting `best_jaccard` — and pointing every other site at it; the count is still carried for ranking while the actual citation pairs flow through to the Evidence renderer (which now prints real excerpt text). Every `cut -fN` reader was re-mapped to the canonical layout. Patch-scoped to the one command file — the SPEC/SKILL contracts were already correct. (AUDIT-P0.7).

### v0.36.10
- **fix: regenerate the `/init-orchestration` hook templates to byte-match the live hooks + add a drift gate (AUDIT-P0.2)** — the hook templates `/init-orchestration` emits to consumer projects had drifted from this repo's canonical live `.claude/hooks/*.sh`, shipping consumers broken/stale hooks: the **bash-compress** template built its rewrite JSON with `printf` interpolating an **unescaped `$COMMAND`** into a string field (JSON injection / breakage on any command containing a quote or backslash); the **memory-capture** template predated the AUDIT-P0.1/P1-1 INSERT fix and incorrectly fired on `Bash`; and the **task-completed** template was a bare `exit 0` stub with none of the live council-gate/plugin-validation logic (incl. the AUDIT-P0.10 WTROOT fix). Each emitted template is now byte-identical to its live hook — bash-compress uses injection-safe `jq -n --arg`, and the dead `bash-compress-wrapper.sh` template is dropped since the live hook inlines compression. A new `skills/init-orchestration/check-hook-templates.sh` extracts each template and `diff`s it against the live hook, wired into `/release` as a pre-commit gate so they can't silently re-drift. (stop-review was already in sync.) The stale `SPEC-002:54` bash-compress *wrapper* description is pre-existing drift left to the P3.5 spec-hygiene pass. (AUDIT-P0.2).

### v0.36.9
- **fix: correct the phantom "shipped" status for session-cost-tracking (AUDIT-P0.13, doc-status half)** — "Session cost tracking" was attempted (a stranded `feat/session-cost-tracking` branch carries a phantom `chore: release v0.23.0` commit) but never actually worked — its backlog item is authoritatively `PENDING — DEFERRED (hook payloads lack token data)`. Two tracked indices falsely claimed success: `.claude/backlog.md` marked it `[COMPLETED]` and `.claude/plans/2026-04-19-scout-plugins.md` marked it `**SHIPPED** v0.23.0`. Both are corrected to `DEFERRED`/`—` to match the item file. (The stranded branch itself — whose phantom `v0.23.0` collides with master's real `v0.23.0` and which predates the privacy-scrub — is left for an explicit maintainer decision; its deletion is an outward-facing, scrub-sensitive operation, not part of this patch.) (AUDIT-P0.13).

### v0.36.8
- **fix: `/wrap-ticket` no longer destroys an incomplete worktree after `/clear` (AUDIT-P0.5)** — Step 1 verified task completion from the in-session `TaskList` alone, which empties out after `/clear`; the ticket filter then matched zero tasks, the "any task not completed" gate passed vacuously, and Step 6 removed the worktree with work still in flight. Step 1 now dual-reads the `.claude/tasks/<ISSUE-ID>-<task_id>.json` file store as authoritative (those records survive `/clear`): it selects the ticket's tasks by **compound-key filename** via `find … -name "<TICKET-ID>-*.json"` (not by free-text subject, and `-`-anchored so `FOO-1` can't match `FOO-10-1`), refuses to wrap if any is not `completed` — an empty `TaskList` no longer overrides — and prints an explicit "could not be verified" note rather than silently passing when no records exist. The block re-resolves `$MROOT`/`$TICKET_ID` (each skill bash block is a fresh shell) and uses `find` rather than a bare glob (an empty glob is fatal under zsh). The Error-Handling path no longer skips the check when `TaskList` is unavailable, and `docs/commands/wrap-ticket.md` is updated to match. Scope is the verification/dual-read half only (the memory-write half was fixed in AUDIT-P1-1). (AUDIT-P0.5).

### v0.36.7
- **fix: worktree-safe the hook-registration commands in the shipped specs and `/tdd-gate` (AUDIT-P0.12)** — tracked artifacts still registered hooks in `settings.json` with a **relative** `bash .claude/hooks/<name>.sh` command, which resolves from the firing agent's cwd and fails inside a git worktree (worktrees share `.git/` but not `.claude/`) — the exact pattern `init-orchestration` brands "worktree-unsafe" and rewrites. The three registration sites — `commands/tdd-gate.md` (the PreToolUse snippet), `SPEC-002:18`, and `SPEC-005:54` — now use `bash "${CLAUDE_PROJECT_DIR}/.claude/hooks/<name>.sh"`, matching the form `init-orchestration` already emits, so the normative contract matches the safe emitter. Direct test invocations run from the project root (`SPEC-002:157`, the init-orchestration bootstrap verification) correctly stay relative. (The audit's literal target — the repo's own `.claude/settings.json` — is gitignored/untracked, so it is not a shippable artifact; the shipped emitter template was already safe.) (AUDIT-P0.12).

### v0.36.6
- **fix: anchor the TaskCompleted plugin-JSON validation on the working-tree root + drop an unreachable gate branch (AUDIT-P0.10)** — `.claude/hooks/task-completed.sh` validated `.claude-plugin/*.json` via **cwd-relative** paths behind a `[ -f ]` guard, so the check silently no-op'd whenever the hook ran with cwd ≠ repo root (the Claude-Code-native case carries a `cwd` field; the installed-plugin case runs in the user's project) — a broken manifest sailed through. It now resolves `WTROOT` via `git rev-parse --show-toplevel` and anchors both manifest paths on it: `.claude-plugin/*.json` is a **per-worktree** tracked artifact, so the gate validates *this* working tree's copy (git-common-dir would resolve to the main checkout and miss a break in a linked worktree). The council gate keeps its git-common-dir `$MROOT` for the **shared** `.claude/tasks`/`.claude/council`/`settings.json` state (SPEC-002:24), now resolved once at the top. Also deleted the unreachable no-task-id `exit 2` block — the earlier silent-pass guard makes it dead code (SPEC-002:30 mandates no-task-id is always a silent pass; SPEC-002:35 itself calls that fail path "a structural impossibility"). Hook-only; no spec or council-gate-logic changes. (AUDIT-P0.10).

### v0.36.5
- **fix: gate semantic memory search on a positive `embedding_dimensions`, and make `embed-one.sh` persist the real dims (AUDIT-P0.9)** — read sites guarded the embedding dimension with `[[ "$DIMS" =~ ^[0-9]+$ ]]`, which matches the schema-seeded `embedding_dimensions=0`, so semantic search built and queried a nonexistent `vec_memories_0` table instead of falling back to keyword search. The read gates in `commands/memory-search.md` (lembed + remote) and the previously-unguarded remote branch in `skills/memory-recall/SKILL.md` now also require `[ "$DIMS" -gt 0 ]`. But the per-write path `embed-one.sh` (run by every agent) created `vec_memories_<dims>` and inserted real embeddings yet never updated `config.embedding_dimensions` — so for remote providers that gate would have stranded search on keyword permanently. Both `embed-one.sh` write heredocs now `UPDATE config` with the real dimension (768 remote / 384 lembed), mirroring the one-time `migrate-md.sh` path, so the config value becomes authoritative after the first embed. Scoped to the two read gates plus the two `embed-one.sh` config writes; the hardcoded `vec_memories_384`/`vec_memories_768` references are untouched. (AUDIT-P0.9).

### v0.36.4
- **fix: make a v1 `memory.db` reach the latest schema (v3) in a single `/init-team` run (AUDIT-P0.8)** — two coupled defects blocked v3. (1) `init-team` Step 2.5 used an `if/elif` chain that advanced the schema only one version per invocation, so a v1 DB reached only v2. (2) Worse, `migrate-v3.sh`'s own version/row reads prepended `PRAGMA busy_timeout=5000;` to *captured* `sqlite3` substitutions — on sqlite ≥ 3.51.2 the PRAGMA assignment emits a `5000` result row, so `CURRENT_VERSION` became `5000\n2` ≠ `2`, migrate-v3 hard-errored on its input guard, and v3 was unreachable even across repeated runs. Added `skills/memory-store/migrate.sh`, a to-latest driver that loops applying each idempotent `migrate-v<N>.sh` until `schema_version` reaches the latest (with a stuck-migrator guard so a non-advancing step fails loudly rather than looping), wired into Step 2.5 (covering all three entry points — init, `--refresh`, `--migrate-only`); and changed migrate-v3.sh's two captured reads (`:31` schema_version, `:43` row count) to plain `SELECT`s mirroring the already-correct `migrate-v2.sh`. The single-step migrators' DDL is otherwise unchanged (FK-clause drift remains P0.14/P3.5). Verified end-to-end on sqlite 3.51.2: a v1 DB reaches v3 in one run, an idempotent re-run reports "up to date", and an absent `schema_version` is a safe no-op. (AUDIT-P0.8).

### v0.36.3
- **fix: repair the `.gitignore` inline-comment bug and ignore `.claude/ci-watch/` runtime state (AUDIT-P0.6)** — `.claude/handoff/` was effectively un-ignored in consumer clones: gitignore has no trailing-comment syntax, so the embedded `          # M8 …` turned the line into a pattern that matched nothing (masked on the dev box only by the user's global excludesfile blanket-ignoring `.claude/`). The comment now sits on its own line above a clean `.claude/handoff/` pattern. `.claude/ci-watch/` (CI-watch runtime sidecar/state) was missing from `.gitignore` entirely and is now added. The obsolete nested `skills/ci-watch/.gitignore` (which listed `.lock` and `*.last_failure.txt`) is deleted — both files are written under `.claude/ci-watch/` (verified: `sidecar.sh` `$WATCH_DIR/.lock`, `poll.sh` `$WATCH_DIR/*.last_failure.txt`), so the nested ignore guarded a directory nothing writes to. Verified with the global excludes bypassed: both paths now match the repo's own `.gitignore`. (AUDIT-P0.6).

### v0.36.2
- **fix: thread task dependencies + a cycle pre-gate through `/orchestrate` Step 7 (AUDIT-P0.4)** — `orchestrate`'s `task-store.sh create` call omitted the optional 4th `[depends_on]` argument, so every orchestrate-created task was written `depends_on=[]` and `dag-lib.sh ready-set` marked them all READY at once — defeating the dependency DAG and ignoring the Tech Lead plan's ordering (every task fanned out simultaneously). Step 7 now extracts each task's "Depends on:" list, compound-keys it (`<ISSUE-ID>-N`, matching the create-key convention so `ready-set`'s set-subtraction matches the completed-set) and passes it as the 4th colon-separated arg, and ports `/kickoff`'s `dag-lib.sh check-cycle` pre-gate to reject cyclic graphs before any `TaskCreate`. Doc-only change to `skills/orchestrate/SKILL.md`, mirroring the already-correct `/kickoff` path; `task-store.sh`, `dag-lib.sh`, and ci-watch's deliberate dependency-free CI-fixer form are untouched. (AUDIT-P0.4).

### v0.36.1
- **fix: `/standup` file-store view read a task-id field that the task store never writes (AUDIT-P0.3)** — `skills/standup/SKILL.md`'s reconciliation step read `.id` and `.owner` from `.claude/tasks/*.json`, but the task store (`skills/orchestrate/task-store.sh`) writes `task_id` and has no `owner` field at all. So the file-store view — the post-`/clear` source of truth that the in-session `TaskList` is told to defer to — printed an empty id for every task and a constant `—` owner, making it unusable for reconciliation. The jq now reads `[.task_id, .status, .subject]`, dropping the vestigial never-populated owner column (adding real owner-tracking would mean plumbing an owner through create/spawn/schema — a feature, out of scope for this fix). `dag-lib.sh` already used `task_id`; standup was the only stale reader. First ticket of the AUDIT-P0 realized-bug tier. (AUDIT-P0.3).

### v0.36.0
- **feat: rename the code-review command `/review-commit` → `/review-and-commit` (D5) — finish the half-done rename across the dir, docs, and ~16 files** — the skill's invocation `name:` was already `review-and-commit` (so `/review-and-commit` already worked and `/review-commit` resolved to nothing), but the skill **directory**, its docs page, and dozens of path/slash/prose references still used the old `review-commit` name. This completes the canonical rename: `git mv skills/review-commit/ → skills/review-and-commit/` and `docs/commands/review-commit.md → review-and-commit.md` (both history-preserving), and updates every current reference — `skills/review-commit/` path strings, `/review-commit` slash-command mentions, and feature-name prose — across the specs (SPEC-002/010/013, TDD), the 6 council flavors, `commands/council.md`, `skills/council/SKILL.md`, `engine.sh` comments, and the README command table. Historical `## Changelog` entries are preserved verbatim (they record the name at their release). The council-engine locator is unaffected (it resolves `engine.sh` via `plugin-dir.sh`, not the renamed dir). Adversarially verified: a completeness refuter confirmed zero functional/dangling old-path survivors (only the historical changelog lines remain), the renames are tracked as renames, and both `/release` drift-gates stay green. Final part of the 4-part AUDIT-P1-4C split — the council subsystem consolidation is complete. (AUDIT-P1-4C-4).

### v0.35.2
- **fix: council docs — drop the phantom preset-file schema, document the implemented Phase 2.5, delete orphaned review-commit fixtures** — three doc-vs-reality cleanups. (1) `skills/council/SKILL.md` claimed each preset "lives at `skills/council/presets/<name>.md` with YAML frontmatter" — but no `presets/` directory exists; `engine.sh` resolves presets via a hardcoded `case` statement. The phantom file-claim is removed and `engine.sh`'s `case` is declared the authoritative source (the fields table is reframed as documenting what the resolution emits into the investigation plan, not a file format). (2) Added the **Phase 2.5 — Blind Cross-Review** section to the council SKILL's Engine Phases (it was implemented in the pipeline but undocumented there), mirroring SPEC-013:79–87 and `commands/council.md`'s actual behavior (anonymized per-reviewer ranking with self-exclusion + independent label shuffle, Borda consensus, Borda-ordered hand-off to Phases 4/5, bottom-quartile `WEAK_EVIDENCE`, `<3`-investigator bypass); also refreshed the Traceability table's drifted SPEC-013 line ranges for Phases 4–7 + Integration/Task-ID/Scope so the MUST→section map is monotonic and accurate. (3) Deleted the orphaned `skills/review-commit/fixtures/*` (no runner ever referenced them) and dropped the dead "Task 15's snapshot test" claim. Doc-only. Adversarially verified (an independent refuter caught — and I corrected — a renderer-attribution slip + the traceability cascade). Third of the 4-part AUDIT-P1-4C split. (AUDIT-P1-4C-3).

### v0.35.1
- **fix: council report-generation cluster — COMPLIANCE action-item label, Phase-4 skipped in diff-mode, placeholders-only report templates** — three engine.sh/template defects in council report rendering. (1) **COMPLIANCE label:** `engine.sh`'s action-item label was keyed only by severity (`critical→BLOCKER, warning→DESIGN, nitpick→NITPICK`), so a `category=compliance` finding never received the COMPLIANCE label that `review-and-commit`'s 4-label contract (`BLOCKER → COMPLIANCE → DESIGN → NITPICK`) requires — making that contract unsatisfiable. Labeling and sort order are now category-then-severity: a non-critical compliance finding gets the COMPLIANCE label and sorts to rank 1 (a critical one stays BLOCKER at rank 0 — critical always blocks first). (2) **Phase-4 in diff-mode:** the preflight investigation-plan emitted `4_prosecution_defense` unconditionally, contradicting the documented "Phase 4 skipped in diff-mode" behavior; the plan now gates that block on `output_shape` (`verdict[]` gets prosecutor/advocate; `finding[]`/diff-mode gets `{skipped: true, reason: "finding[]-shape preset"}`), and the council SKILL + command Phase-4 prose are reconciled to match. (3) **Placeholders-only templates:** `report-finding.md`/`report-verdict.md` carried static example/fallback content after their `{{…}}` placeholders (a fenced `Action Items: N BLOCKERs…` example + three `- [ ] BLOCKER/DESIGN/NITPICK … what is wrong …` lines, the `| Severity | Count | … | — |` placeholder tables, and duplicate `No findings/lines struck.` lines) that **leaked into every rendered report**; the static content is removed and the now-dead post-substitution strip-regexes in `engine.sh` are removed in sync (the `{{VAR}}` safety-net and the runtime `struck_md` fallback are kept). Adversarially verified: independent refuters rendered both report shapes (incl. zero-item and scrambled-input cases) and confirmed correct COMPLIANCE labeling/ordering, Phase-4 gating, and zero static leaks / leftover placeholders. Second of the 4-part AUDIT-P1-4C split. (AUDIT-P1-4C-2).

### v0.35.0
- **feat: merge the council Phase-4 prosecutor/advocate prompts into one role-parameterized `phase4-brief.md` and make the roles blind to the original claims** — the Prosecutor and Devil's Advocate prompts (`prompts/prosecutor.md`, `prompts/advocate.md`) were ~80% identical, and both declared/used `{{ORIGINAL_CLAIMS}}` in their bodies while `commands/council.md` deliberately never substituted it (SPEC-013's evidence-alone design) — so the literal `{{ORIGINAL_CLAIMS}}` placeholder leaked into the spawned subagent on every run (the same defect class as v0.34.0). The two are now one `skills/council/prompts/phase4-brief.md` parameterized by `{{ROLE}}` / `{{ROLE_BIAS}}` / `{{EVIDENCE_FIELD}}` (`evidence_against` for the Prosecutor, `evidence_for` for the Advocate — the judge-consumed field names, preserved byte-for-byte) plus `{{EVIDENCE_BUNDLES}}` / `{{FLAVOR_DELTA}}`. The merged body carries **no `{{ORIGINAL_CLAIMS}}`**: each role reconstructs the claim set from the `claim_id` carried inside the evidence bundles, never from a supplied claims list (the Judge in Phase 5 still receives the claims — that seam is unchanged). SPEC-013's Phase-4 MUSTs are clarified to state the claim-blindness invariant explicitly. The `/release` template-variable drift-gate now **covers** `phase4-brief.md` (moved out of the deferred set; it handles the dual-spawn by taking the union of the two `commands/council.md` substitution blocks). First of the 4-part AUDIT-P1-4C split (council bug-class + preset + the `/review-and-commit` rename follow). (AUDIT-P1-4C-1).

### v0.34.1
- **fix: merge the council engine's two duplicated JSON-repair routines into one shared function** — `skills/council/engine.sh` carried two near-identical backslash-repair blocks (`PYREPAIR` for the evidence file, `PYJUDGEFIX` for the judge output) whose repair cores were byte-identical except the loop variable and comments — the file even self-documented the duplication ("Apply the same backslash repair as evidence"). Both are now one shared `repair_json_file <file> <mode> <err_label> <exit_code>` bash function: a single backslash-repair core, with the markdown-fence-strip pre-step guarded to judge mode only, and the per-mode exit contract (5 evidence / 7 judge) emitted via `sys.exit` inside Python so it survives `set -euo pipefail` errexit. Pure internal refactor, **no behavior change** — a proof harness extracting the real shipped Python from the pre- and post-refactor `engine.sh` confirms byte-identical repaired output, identical exit codes, and identical stderr (incl. the evidence-only "(unescaped backslashes)" suffix and the judge-only 200-char debug line) across an unescaped-regex / valid-escape / mixed / fenced / unrepairable corpus. Net −19 LOC. The two larger P1-4B candidates evaporated under verification: `flavors/_shared.md` is runtime-infeasible (the engine injects each flavor's whole body as `{{FLAVOR_DELTA}}`; a base+delta compose would need new orchestrator logic and contradicts SPEC-013's self-contained-flavor MUST), and the `prosecutor`/`advocate` → `phase4-brief.md` merge is a judge-consumed-field contract change entangled with the Phase-4 blind-input contradiction — both deferred to AUDIT-P1-4C. (AUDIT-P1-4B).

### v0.34.0
- **feat: council contract home (SPEC-013) — fix the template-variable contract that leaked 3 placeholders into every council subagent** — the council prompt-variable contract was defined in 3 disagreeing places, and the runtime substituter (`commands/council.md`) named three variables absent from the prompt bodies — `{{RAW_INPUT}}`/`{{CLAIM}}`/`{{CLAIMS}}` where the bodies declare `{{INPUT_TEXT}}`/`{{CLAIM_TEXT}}`/`{{ORIGINAL_CLAIMS}}` — so those literal `{{…}}` placeholders shipped unsubstituted into the spawned claim-extractor / investigator / judge subagents on every run. SPEC-013 now normatively declares each prompt's own `## Variables` table the authoritative contract, with `commands/council.md` **and** `skills/council/SKILL.md`'s documented-variables table required to name exactly those variables (no dead substitutions, no unsubstituted leaks). council.md and the SKILL table are reconciled to the bodies (two dead substitutions — `{{SPEC_BUNDLE}}`, `{{TOOL_ALLOWLIST}}` — resolved body-authoritative and behavior-preserving; the missing `cross-reviewer` row added). New `skills/council/check-template-vars.sh` mechanizes the contract for both halves (council.md substitution blocks + the SKILL.md doc table, each vs the prompt's Variables table) and is wired into `/release` as a pre-commit drift-gate. blind-review's council reverse-validation display is aligned to the canonical 5-term verdict taxonomy (it was dropping `UNVERIFIED`/`FABRICATED`). The audit's broader "schema defined in 6+ places" premise was tested and largely held-already-consistent (the 6 homes agreed; 4 are runtime-operational or parsing code that cannot become cites) — so the real, shippable fix is the variable-contract correctness, not a decorative schema include. prosecutor/advocate's `{{ORIGINAL_CLAIMS}}` contract is entangled with the Phase-4 blind-input contradiction and is deferred (the gate logs the gap) to AUDIT-P1-4C. (AUDIT-P1-4A).

### v0.33.1
- **fix: single-source the shared spec-tooling procedures (SPEC-008) — reconcile 5 drifted classes** — the spec-tooling commands hand-rolled five overlapping procedures in divergent copies: spec discovery (7 ways), the MUST→code alignment pipeline (4×), conflict-scan (3×), language detection (4×), and the code-alignment grep-exclude list (5 drifted variants that silently changed what counts as "source"). SPEC-008 is now the single normative home for all five (Spec Discovery, Source Exclusions, Project-Language Markers, Code-Alignment Verdicts + the separate update-spec Code-Impact Warning, Spec Conflict Scan); consumers cite it and keep their scope-specific operational copy inline (no runtime resolution). The one byte-identical datum — the grep-exclude set — is single-sourced from `skills/spec-tooling/source-exclude.md` and included into the 4 alignment consumers (5 regions), drift-gated at `/release`. The canonical exclude set drops the `skills/`/`commands/` path-exclude (the `*.md` extension exclude already removes plugin prose, while real `skills/*.sh` implementation stays visible to alignment) — corrective in both directions. Fixes two discovery bugs: find-spec's hardcoded per-category globs (new categories were invisible) → category-agnostic glob, and list-specs' index-only read (orphan spec files were invisible) → orphan cross-check. Editorial consolidation; the exclude reconciliation is the one intended behavior change. (AUDIT-P1-5B).

### v0.33.0
- **feat: single-source the spec-file format contract (SPEC-008) — fresh `/generate-specs` output now passes `/check-specs`** — the spec format was defined 4× contradictorily, so every freshly generated spec failed `/check-specs` Phase 1 (it omitted `**Category**`, `**Created**`, `## Test`, `## Validation`, `## Version History`). SPEC-008 is now the single normative contract: the 9 required sections (sourced from one byte-identical `skills/spec-tooling/spec-skeleton.md` partial that `/generate-specs` and `/create-spec` include via `<!-- include -->` markers, drift-gated at `/release`), a two-axis status taxonomy (lifecycle `INFERRED → DRAFT → ACTIVE → APPROVED → DEPRECATED` as the spec's `**Status**:`; the `✅/❌/⚠️` legend demoted to report-only verify-status), canonical TDD-index columns `| ID | Title | Status | Coverage |`, and a 2-column Version-History row (the 3-column variant is retired). `/check-specs`, `/reflect-specs`, `/kickoff`, `/list-specs`, `/update-spec`, and `scaffold-project` now cite the contract instead of restating it; emitter-specific extras (SHOULD/Open-Questions/Cross-references, `---`) stay outside the shared region. New `skills/spec-tooling/check-format.sh` mechanizes the 9-section check (MC-6 bootstrap proof). Fixes two live corruptions: the `specs/TDD.md` stray 3rd version-row cell, and dead "Quick Status Table"/"Navigation by Category" references in 4 commands. (AUDIT-P1-5A; P1-5B — shared discovery/alignment/grep-exclude procedures — follows).

### v0.32.1
- **fix: push the `SendMessage` no-addressable-parent guidance into the emitted consumer AGENTS.md template** — `init-orchestration`'s generated AGENTS.md (both the new-file template and the append-only Team Coordination block) lacked the rule that spawned sub-agents have no addressable parent (no agent named `main`/`orchestrator`) and must return work as their final message. Consumer-spawned agents could DM a non-existent parent and lose their result; the guidance is now present, lifted verbatim from this repo's `AGENTS.md` for consistency. Declares in SPEC-005 that this repo's hand-tuned `AGENTS.md` and the emitted consumer template are intentionally **distinct** documents (shared by manual reconciliation, not byte-level single-sourcing) and that emitted consumer files MUST stay `<!-- include -->`-marker-free. Anchors the v0.32.0 managed-include drift-gate (`sync-includes.py check` at `/release`) as a SPEC-010 Release MUST — it was previously specced nowhere — scoped to managed-include regions only (not an AGENTS.md-vs-template cross-check). Doc-only; no engine/agent/runtime change. (AUDIT-P1-1B).

### v0.32.0
- **feat: single-source the agent memory protocol (managed-inline + drift-check)** — the ~700-line memory block that was hand-duplicated across all 7 behavioral agents is now generated from one canonical partial (`skills/agent-memory/protocol.md`) expanded inline between `<!-- include -->` markers; `skills/agent-memory/sync-includes.py` byte-checks the copies and `/release` blocks on drift. Agents stay self-contained (no runtime skill resolution — portability preserved), and the block is **upgraded**: the write path now uses `PRAGMA busy_timeout`, SQLITE_BUSY retry, `MEMORY_ID` capture, and **best-effort embedding via `embed-one.sh`** — so agent-written memories are embedded and surface in semantic `/memory-search` for the first time. The tiered read is corrected to `SELECT type, content`. Fixes 3 latent bugs: P0.1 the silent-no-op `memory-capture.sh` INSERT (sqlite3 CLI can't bind `?` from argv — was storing NULLs; same fix in the emitted `/init-orchestration` hook template), P0.5 `wrap-ticket` `INSERT OR REPLACE` appending a duplicate doc every wrap (now append-only), P0.11 the truncating `.md` fallback (`cat >`→`>>`). Reconciles the memory line-limit contract on SPEC-004 (the stray SPEC-009 "150-line" warn was wrong → 50). Adds the MC-4 spawn-`terse` MUST to SPEC-003/009. Removes the dead memory-load bash from the tool-less `council-judge`. (AUDIT-P1-1).

### v0.31.2
- **fix: extract `skills/memory-store/embed-one.sh`** — the write-time embedding logic (lembed + remote provider) is single-sourced into one best-effort `embed-one.sh <db> <memory_id> <text>` helper; `memory-store` Step 4 now delegates to it instead of inlining ~90 lines. Self-derives extension/model paths from the DB, always exits 0, and silently skips when extensions are absent or mode is `fallback`. Zero behavior change — Step 4 produces byte-identical `vec_*`/`embedding_meta` rows. Prerequisite for the AUDIT-P1-1 agent memory-write path. (AUDIT-P1-1C).

### v0.31.1
- **docs: single-source the project-root resolution contract (SPEC-002)** — declared the three authoritative root-resolution contexts (shared-root via `git rev-parse --git-common-dir`; working-tree-root via `--show-toplevel`; cwd-anchored single-root for project-bootstrap skills) with a MUST-NOT-mix-roots clause. Doc-only: no behavioral change. The real subdir-invocation hardening for `scaffold-project`/`init-orchestration` (anchor every `.claude/` op on one resolved root) is filed as `.claude/backlog/bootstrap-single-root-anchoring.md` — deferred after review showed a naive partial anchor would split the scaffold. (AUDIT-P1-2).

### v0.31.0
- **feat: plugin-dir locator consolidation** — new `skills/plugin-dir.sh` subprocess CLI resolves any plugin file via a single `sort -V` highest-version algorithm with a dev-checkout fast path; replaces most of the ~15 hand-rolled locators across 11 command/skill files (drops the duplicated `PLUGIN_VER` grep, the hardcoded `cold-dark-void` slug, and two divergent glob-first-match resolvers). A best-effort `embed-one.sh` locator (`find … | sort -V | tail -1`) is deliberately kept at the remaining ~9 sites — it degrades gracefully via `|| true` and is out of scope for this consolidation. SPEC-002 gains the `plugin-dir.sh` CLI contract + caller bootstrap clause. `retro-gate/hint.sh` now self-locates `gate.sh`. (AUDIT-P1-3).

### v0.30.4
- **ci-watch ci-mode poll works again (`skills/ci-watch/poll.sh`)** — the poll queried `gh pr checks --json name,conclusion`, but `conclusion` has never been a valid `gh pr checks` JSON field, so every poll errored and the error-tolerant path swallowed it as an eternal `wait`: the watcher never reported green, never spawned a fixer, and only `poll_error_count` climbed. The poll now fetches `name,state,bucket` and classifies via `bucket`, gh's version-stable normalization — `fail`/`cancel` → failure, `pass`/`skipping` → green, `pending` → wait. Skipped checks no longer block green (previously another eternal-wait), `ERROR`/`ACTION_REQUIRED` states now correctly count as failures, and `last_failure.txt` carries each failing check's `state` for the fixer agent. Verified against gh 2.94.0 field validation plus a stub-gh harness (pass/fail/pending/skip/cancel/cap scenarios). SPEC-017 and the skill's decision matrix updated to match.

### v0.30.3
- **Natural-break chunking for monster-session handoffs (`skills/handoff/prepass.sh`)** — when a transcript is too large for one window and must be chunked, `prepare` now prefers to cut at a user-turn boundary (the start of a user message) once past a soft threshold, instead of an arbitrary token cutoff, so a hypothesis->test->correction arc stays within one chunk and the convergence through-line survives the map step. The hard token budget is still never exceeded (an oversized single message is the only thing that can exceed it, as before). Measured on a real session, turn-aligned chunk boundaries rose 40%->76%. Tunable via `HANDOFF_CHUNK_SOFT_RATIO` (default 0.8; 1.0 restores pure budget cutting).

### v0.30.2
- **Tool-Offload Discipline in the generated AGENTS.md (`/init-orchestration`)** — the prevention prong of session-handoff now ships where it reaches users: the `/init-orchestration` AGENTS.md template gains a Tool-Offload Discipline section, so new projects instruct both the main loop and all agents to offload bulk tool I/O (reads spanning 3+ files, > ~400-line reads, or > ~50-line/unbounded command output) to a subagent that returns findings + pointers, not raw dumps. MUST above the bar; below it the rule does not apply.

### v0.30.1
- **Handoff cache retention (`/handoff` cold cache)** — `skills/handoff/prepass.sh` now bounds `.claude/handoff/cache/` instead of letting it grow forever: after `finalize` writes a brief it keeps the newest `HANDOFF_CACHE_MAX_ENTRIES` cached briefs (default 50) by `created_at` and prunes the rest oldest-first, never evicting the entry just written, and sweeps orphan `*.tmp` files. Safe by construction — a cached brief is a derived memoization of its transcript, so an evicted entry is rebuilt on the next cache MISS (no recoverable context lost). Best-effort and silent under the cap; confined to the cache dir (never `memory.db`). Implements the SPEC-018 M8 eviction follow-up.

### v0.30.0
- **Session handoff (`/handoff`) — SPEC-018**: cold `/handoff <uuid>` reconstructs a past session from disk (fork-tree assembly, `toolUseResult` strip, size-adaptive spine + chunking for 90 MB+ multi-fork transcripts, 5 specialized extractors → a pointer-bearing brief, cached) — survives `/compact`. Warm `/handoff` captures the live session.
- **Shared `skills/transcript-parse/` module** (session-JSONL location, fork-tree assembly, parse primitives, freshness guard); `/retro` refactored onto it with zero scoring regression.
- **Deprecated** the personal `~/.claude/skills/handoff` skill in favour of the unified plugin command.

### v0.29.13
- **`/release` skill matches the real one-folded-commit convention** — the bundled skill assumed the work was already committed: it derived the version and changelog from `git log` since the last tag (empty when the change is still uncommitted, so it wrongly reported "nothing to release"), staged only the 3 version files, and committed a standalone `chore: release vX.Y.Z`. It now derives the changelog from the uncommitted working-tree changes (plus any commits since the tag), stages the changed source files alongside the version files, and folds everything into a single `fix:/feat: vX.Y.Z — <summary>` commit with a `Co-Authored-By: Claude <Model> (1M context)` trailer — no `chore: release` commit, no tag pointing at a version-bump-only commit that omits its own code.

### v0.29.12
- **Agents verify external behavior before building on it** — real-session insights showed agents repeatedly designing around unverified API params / SDK flags / model capabilities (e.g. `reasoning_effort`, vLLM flags) that the backend silently ignored, then shipping fixes that missed the real issue. `agents/ic4.md`, `agents/ic5.md`, and `agents/tech-lead.md` now carry a standing rule: empirically verify any external API parameter, library/SDK flag, model capability, or endpoint behavior (grep for proven usage, run a minimal probe, or cite docs for the exact version) before building or designing around it, and label any option that proves decorative/no-op instead of implying it works. IC4 also gains reproduce-then-root-cause-before-edit and an anti-rationalization row against spraying the same guard across many callsites (escalate to IC5 — there's one upstream fix). Tech Lead gains an honest-judgment rule: no verdict resting on a single convenient metric, no unverified "success" claims.
- **kickoff GATE-1 — verify API assumptions before the spec** — `/kickoff` gains a conditional Step 4b that runs before the spec is written. Tech Lead's Step 2 orientation now emits the external behaviors the ticket *assumes*; if any exist, a verification agent classifies each `HONORED / IGNORED / DECORATIVE / UNKNOWN` (codebase grep → minimal probe → cited docs). If a confirmed AC depends on a capability that isn't `HONORED`, kickoff pauses and surfaces it instead of baking the unverified assumption into the spec. No-op for pure-UI/refactor tickets — skips in one line.

### v0.29.11
- **Visible WAL fallback for memory.db** — sandboxed filesystems (bubblewrap tmpdirs, NFS, some CI containers) reject `PRAGMA journal_mode=WAL` and SQLite silently degrades to `journal_mode=delete`. The DB still works but concurrent agent writes serialize instead of running in parallel — invisible regression. `/init-orchestration` Step 7 now probes `PRAGMA journal_mode;` after schema apply and prints a clear stderr warning when WAL was rejected, telling the user what degraded and how to recover (re-run outside the sandbox / on a local filesystem). Schema comment in `schema.sql` documents the same fallback path.

### v0.29.10
- **Reconcile TaskList against Agent-spawn lifecycle** — `Agent` tool's `async_launched` is *not* a TaskList status; it lives on the spawn-result, not the task. A spawned agent's `TaskUpdate(completed)` runs in its own sandbox session and never reaches the orchestrator, so TaskList rows for async-spawned work stay `in_progress` forever and the TaskCompleted council hook never fires. Two complementary fixes: `skills/orchestrate/SKILL.md` Step 8 monitoring loop now states explicitly that the *orchestrator* must record `task_id ↔ agentId` at spawn time and call `TaskUpdate(completed)` itself on every Agent-completion notification; `skills/standup/SKILL.md` now reads the file-store at `.claude/tasks/*.json` (the source of truth) alongside `TaskList`, prefers the file-store on disagreement, and surfaces a new `🟡 LIKELY-DONE` category for `in_progress` tasks whose owner has no live activity but whose file-store shows completed — these need an orchestrator-side TaskUpdate to close the loop.

### v0.29.9
- **Orchestrator post-compaction discipline** — long `/orchestrate` sessions saw 28 "File has not been read yet" errors all originating from the main orchestrator (not sub-agents) clustered on post-compaction continuations: the harness wipes the per-tool read-tracker on summary-resume but the conversation summary still convinces the model it has read those files. Same compaction also lets the "you do NOT write code" rule decay — orchestrator drifts into doing IC work directly. Added explicit post-compaction discipline to `skills/orchestrate/SKILL.md` Step 8: the no-code rule survives compaction; the "File not read yet" error means compaction just happened, treat it as a directive to re-Read every file you intend to touch this turn, not a one-off retry.

### v0.29.8
- **Harden worktree cleanup against WSL2 EBUSY** — `worktree-lib.sh release` now (a) retries every git op 3× with 200ms backoff on `Device or resource busy` / `could not write config` / `update of config-file failed` errors, (b) actually deletes the feature branch (was missing — `release` only ran `worktree remove` before), (c) runs `worktree prune` to reap partial-failure admin entries, (d) sweeps any orphaned `[branch "feat/X"]` config stanza via `git config --remove-section`. Each step is a separate `git` call so the second never fires while the first is still releasing `.git/config`. Updated `orchestrate/SKILL.md` worktree-cleanup prose to point at the lib first and to forbid chained `worktree remove && branch -D` in by-hand cleanups (the chained form is the exact pattern that races on WSL2's 9p mmap-rename).

### v0.29.7
- **Stop spawned agents from hallucinating an addressable orchestrator** — child agents under `/orchestrate` and `/kickoff` repeatedly invented symbolic recipients (`main`, `orchestrator`, `tl-cdv162-plan`) and tried `SendMessage` with `to: "<that name>"`, which the runtime rejects (only opaque agent IDs are addressable). The agent then logged apologetic prose ("The orchestrator isn't running as an addressable agent named 'main'…") and dumped its report to final output anyway — wasted tokens with no functional benefit. Spawn templates in `skills/orchestrate/SKILL.md` and `skills/kickoff/SKILL.md` now explicitly tell agents: return your output as the final message, do NOT SendMessage to the orchestrator. AGENTS.md `Team Coordination` section gains the same rule for hand-edited spawns.

### v0.29.6
- **stop-review.sh: sync install template, fix stamp key** — the install heredoc in `/init-orchestration` still shipped the legacy blocking version (`exit 2`) while the plugin's own dogfood copy was already non-blocking — silent drift. Both are now the same non-blocking script. The stamp key is now `cwd + HEAD-sha` instead of `session_id`; `claude --resume` mints a fresh `session_id` per invocation, so the old guard re-fired on every resume even when no new dirty state existed. The new stamp re-fires only when HEAD moves (a commit lands). Stale stamps from prior HEAD shas are swept on each fire to keep `.claude/` tidy. On re-run, `/init-orchestration` overwrites legacy `exit 2` / `SESSION_ID` versions of the hook.

### v0.29.5
- **Worktree-safe hook paths** — `/init-orchestration` now writes hook commands as `bash "${CLAUDE_PROJECT_DIR}/.claude/hooks/<name>.sh"` instead of relative `.claude/hooks/<name>.sh`. Relative paths broke every Bash tool call from agents spawned inside worktrees (worktrees share `.git/` but not `.claude/`), producing "No such file or directory" on every PreToolUse / PostToolUse / Stop / TaskCompleted fire. The Step 1 upgrade check now also auto-rewrites stale relative paths in existing settings.json on re-run.

### v0.29.4
- **retro-gate: exclude context-continuation messages** — S1/S5 no longer fire on "This session is being continued from a previous conversation..." messages, whose session summaries often contain rejection-like words that are not user friction.
- **retro.md: fix `$N` substitution** — Claude Code substitutes `$1`–`$6` CLI args into skill text, clobbering awk field refs and bash function `$1`/`$2` params. Replaced all awk `$N` with `cut -fN`, singleton filter awk with a `while read` loop, and function params with `$*` / env-var pass-through.

### v0.29.3
- **retro `plugin` target** — `/retro` now classifies friction caused by the plugin itself (gate false positives, skill bugs, missing commands) as `target: "plugin"` and routes proposals to `/backlog add` instead of agent directives. Fixes the core issue where project-specific friction was being written as universal behavioral rules.

### v0.29.2
- **retro-gate false positive fixes** — S1 no longer fires on `<task-notification>` and `<command-name>` system messages; S5 no longer fires on slash commands or common approval words (`waive`, `ok`, `merge`, `lgtm`, etc.) that signal user satisfaction, not friction.
- **retro-subagent generalizability filter** — proposals must now apply across any project; domain-specific rules (e.g. about a particular DB schema) are demoted to observations instead of becoming universal behavioral directives.

### v0.29.1
- **SPEC-017 security + quality hotfix** — `sidecar.sh` and `poll.sh` lacked the `^[a-zA-Z0-9._-]+$` ticket ID validation that `task-store.sh` already enforced; a crafted ticket ID could construct arbitrary file paths including `rm -f` in `sidecar.sh cmd_delete`. Fixed with a `validate_ticket_id()` helper in both scripts. Additional: `poll.sh` EXIT trap for temp file cleanup, `emit_quiet` collapsed into `emit`, trust-boundary comment on `bash -c "$test_cmd"`. `dag-lib.sh` cycle-path reconstruction replaced with a one-line message (was ~25 lines for cosmetic stderr output), outer-loop guard added so cycle detection stops at first back-edge, `for child in $children` replaced with `read -ra` to prevent glob expansion. `task-store.sh` success messages redirected to stderr. `SKILL.md` frontmatter corrected from "5 min" to "7 min".

### v0.29.0
- **SPEC-017 — Autonomous CI Watch + Task DAG** — Two coupled autonomy features. *CI Watch*: after /orchestrate pushes work, a durable CronCreate loop monitors quality checks and auto-spawns a `dev-team:ic5` fixer agent on failure (retry cap: 3). Adapts to the project's setup: `ci` mode polls `gh pr checks`; `local-test` mode runs the detected test command (`npm test`, `make test`, `go test ./...`, `pytest`); `none` mode skips silently. New subprocess CLIs: `skills/ci-watch/sidecar.sh` (atomic sidecar state), `skills/ci-watch/detect-mode.sh` (mode probe), `skills/ci-watch/poll.sh` (deterministic `done|fail|cap|wait` decision). *Task DAG*: `task-store.sh` gains an optional 4th `depends_on` arg; new `skills/orchestrate/dag-lib.sh` provides `check-cycle` (3-color DFS), `ready-set`, and `status-of`. `/kickoff` Step 7 detects cycles before any `TaskCreate` and populates `depends_on` using compound keys. `/orchestrate` fans out all unblocked tasks in parallel via `dag-lib.sh ready-set`. `/standup` READY/WAITING computed from task store files (not prose). `/wrap-ticket` Step 6.5 cleans up the CI-watcher cron via `CronDelete`. New spec: `SPEC-017`.

### v0.28.1
- **Agent behavioral improvements from retro** — ic4 and ic5 gain rule to complete all edits on one file before moving to the next (prevents mid-task file interleaving); tech-lead gains rule to lead with a single recommendation rather than listing alternatives unprompted.

### v0.28.0
- **SPEC-013 Phase 2.5 — Blind Cross-Review** — Adds an anonymized peer-review round to the `/council` pipeline between Phase 2 (investigation) and Phase 4 (prosecution/defense), inspired by Karpathy's llm-council design. Each investigator cross-ranks peers' evidence bundles using anonymized labels (per-reviewer independent shuffle defeats position bias; self-exclusion prevents reviewing your own bundle). Rankings are aggregated via Borda count; bundles in the bottom quartile are flagged `WEAK_EVIDENCE`. Phase 4 and Phase 5 receive bundles in consensus rank order rather than submission order. Bypasses gracefully when fewer than 3 investigators participated or all reviewer responses are invalid. Engine finalize wired with `--cross-review-status/rankings/scores` flags; both report templates gain a `## Cross-Review` section. New `skills/council/prompts/cross-reviewer.md` prompt template.

### v0.27.0
- **Worktree isolation convention** — `skills/worktree-lib.sh`: new subprocess CLI for collision-safe worktree management. `ensure <slug>` creates `.worktrees/<slug>` with a PID-based lock, prompts on live-lock collision (abort/steal), and silently recovers stale locks. `release <slug>` removes the lock and worktree, refuses on uncommitted changes. Security hardened: slug sanitization (`[A-Za-z0-9_-]` only), PID lower-bound guard (rejects PID ≤1), `umask 077` on lock writes, bounded lock-file reads. `/orchestrate` Step 3 updated to call `worktree-lib.sh ensure`; `/wrap-ticket` Step 6 calls `release`, with new+legacy path detection and anchored ticket-ID greps (`-wF`). `/demo` gets an interactive existence prompt. `AGENTS.md` Worktree Protocol section added. `SPEC-016-worktree-isolation.md` written.

### v0.26.0
- **`/blind-review`** — New skill: multi-team blind peer review with automatic quorum analysis. Spawns N unconstrained + M lens-differentiated reviewer agents in parallel (security, contributor, spec, architecture, logic lenses available), clusters independent findings by semantic similarity into Tier 1 (cross-cohort ≥2 teams), Tier 2 (same-cohort ≥2 teams), and Tier 3 (single team) confidence buckets, and optionally forwards Tier 1 consensus findings to `/council` for reverse validation. Writes a ranked report to `.claude/reviews/`

### v0.25.3
- **Security + bug fixes from 6-team blind review** — `memory-search` and `recall` now escape query strings before SQLite LIKE interpolation; `stop-review.sh` sanitizes `SESSION_ID` before using it in a filesystem path; `task-store.sh` validates `task_id` against `[a-zA-Z0-9._-]+` in both `create` and `update-status`; `memory-distill.md` pre-validation step rewritten as numbered instructions (was referencing an unset `$VALIDATION_EXIT`); `init-team` gains v2→v3 schema migration branch; council generic preset corrected (`logic` → `jaded-senior`); SPEC-013 Phase 3 deferral formalised and status promoted to ACTIVE

### v0.25.2
- **`/orchestrate` task-store collision fix** — `TaskCreate` resets integers to 1 each new Claude process; switched to compound `<ISSUE-ID>-<task_id>` keys (e.g. `CDV-QF-FILTER-1.json`) to prevent cross-run upsert stomping; `task-completed.sh` hook gains `*-<id>.json` glob fallback for backward compatibility

### v0.25.1
- **`/reflect-specs` health-check fixes** — spec and code alignment corrections from full system audit: SPEC-013 council-judge MUST NOT clarified, TDD.md stale paths/status corrected, SPEC-004 whole-file chunk truncation documented, SPEC-007 terminology aligned, SPEC-002 now covers three previously-undocumented hooks (`bash-compress`, `memory-capture`, `stop-review`), `migrate-v2.sh` gains missing `PRAGMA busy_timeout`

### v0.25.0
- **`/refactor` skill** — standalone design-first refactor workflow: design problem gate (no file edits until problem is written), approach decision (auto-proceed when unambiguous, options + approval when scope is ambiguous), characterization tests when coverage is thin, behavioral-change detection halts the refactor, self-calibration checklist before completion; `inline` subcommand skips gates for handoffs from `/debug` or `/orchestrate`

### v0.24.0
- `/debug` — phase-gated bug workflow: root-cause → failing test → fix → verify; subcommands `patch` (fast path) and `arch` (design-first → /kickoff); enforces root-cause-before-edit gate, self-calibration checklist, holistic callsite scan, escalation ladder to /kickoff → /orchestrate

### v0.23.1
- **Fix hooks for Claude Code 2.1.116** — rewrote `bash-compress.sh` to inline compression instead of calling `bash wrapper.sh` (the wrapper re-triggered permission checks). Narrowed `memory-capture.sh` to Write/Edit only. Made `stop-review.sh` non-blocking (exit 0). Rewrote all hooks to use temp files instead of pipes (pipes poison the sandbox session)

### v0.23.0
- **Per-claim memory validation** — `/validate-memory` now uses LLM-based claim extraction + two-tier verification instead of regex+grep. Extracts checkable assertions from each memory, verifies file/symbol refs via bash (Tier A) and behavioral/architectural claims via read-only investigator subagent (Tier B). Composite scoring averages per-claim verdicts weighted by confidence. Includes path traversal guard, rename detection, file-scoped symbol lookup, and per-claim breakdown in reports

### v0.22.0
- **Bash output compression** — `/init-orchestration` now installs a PreToolUse hook (`bash-compress.sh`) that rewrites noisy test/build commands through a compression wrapper. Uses Claude Code's `updatedInput` to transparently pipe output through head/tail (threshold: 50 lines, shows first 20 + last 20). Covers npm/jest/vitest/pytest/go/cargo/mvn/gradle test, build commands, make, and tsc. Zero external deps — pure bash. Unblocked by `/council --session` audit that revealed PreToolUse hooks support `updatedInput` for command rewriting

### v0.21.0
- **Graduated TDD nudges** — `/tdd-gate` now uses soft enforcement: hint on 1st Write/Edit to untested file (allowed), warning on 2nd (allowed), hard block on 3rd+ (exit 2). Per-file counter tracked per session via `$TMPDIR`. Reduces wasted context from block+retry cycles while still enforcing TDD. Inspired by barkain/claude-code-workflow-orchestration

### v0.20.0
- **Blast radius analysis for reviews** — `/review-and-commit --impact` runs a lightweight impact analysis before spawning reviewers: extracts changed function/class names from diff hunks, greps for callers across the codebase (cap 20 files), and passes affected-caller context to all 5 specialists. Reviewers can now flag callers that may break due to signature changes or removed functions. Inspired by Code Review Graph (11.4K stars)

### v0.19.8
- **Lean orchestrator startup** — removed redundant Tech Lead and PM memory loading from `/orchestrate` Step 0. Both agents load their own memory when spawned in Step 4; pre-loading saved ~2-5K tokens of wasted orchestrator context

### v0.19.7
- **Anti-rationalization directives** — ic5, ic4, and qa agents now embed excuse/rebuttal tables that counter common step-skipping rationalizations (TDD shortcuts, spec non-compliance, premature approval). Inspired by addyosmani/agent-skills

### v0.19.6
- **Judge output JSON validation** — `engine.sh finalize` now validates and repairs judge output (strips markdown fences, fixes unescaped backslashes) with clear error messages on failure (exit 7). Found during v0.19.5 council self-review when LLM-generated judge JSON was malformed
- **Dead code comment** — documented that the `$?` guard after evidence repair is reached via `set -e` errexit, not the explicit check (council tribunal finding, confidence 85)

### v0.19.5
- **Session 00000000 dogfood improvements** — 9 fixes from analyzing a real 17-hour orchestration session on the Project project (Architecture 2.0 overhaul, 98 subagents, 7 tickets shipped)
- **Council evidence JSON repair** — `engine.sh finalize` now auto-repairs invalid JSON caused by unescaped backslashes in investigator `raw_blob` fields (Go regex, Windows paths, etc.). Character-by-character repair runs only when jq rejects the evidence file. Tested against the exact jq exit-5 error from session 00000000
- **Task store upsert** — `task-store.sh create` now upserts instead of erroring on duplicate task IDs; `update-status` auto-creates stub if task file missing after session pause/resume
- **Mandatory spec alignment check** — new Step 10b in orchestrate: `/check-specs` runs after QA and survives pause/resume (explicitly flagged as non-skippable)
- **PM kickoff enforced for all child tickets** — orchestrate now requires PM AC review for every ticket in an umbrella, not just leaf/bug tickets
- **IC agent prompts include architecture context** — orchestrate Step 8 spawn template now enumerates all affected backends/services/platforms so ICs don't discover them by accident
- **ic4→ic5 escalation heuristic** — kickoff and orchestrate now guide Tech Lead: tasks touching >10 files or >15 callsites should go to ic5, not ic4
- **Plain git squash merge** — orchestrate prefers `git merge --squash` over `gh pr merge`; gh is optional, not required
- **Go sandbox cache detection** — init-orchestration detects `go.mod` and offers `GOCACHE=$TMPDIR/go-cache GOWORK=off` injection into agent prompts
- **Worktree cleanup serialized** — orchestrate documents serial worktree removal to avoid `git config: Device or resource busy` from parallel operations

### v0.19.4
- **Remaining review fixes** — stop-review stamp stored project-locally (not in $TMPDIR), generic preset uses only investigator-role flavors, memory-capture deduplicates consecutive identical observations, FK constraints on distillation_log and validation_log

### v0.19.3
- **33-finding upstream review sweep** — comprehensive bug, security, and correctness fixes from external review
- **Council engine fixed** — judge output parser now unwraps `{verdicts: [...]}` / `{findings: [...]}` object (was treating as flat array, producing empty reports). All 12 jq queries + Python renderer corrected. Evidence validation accepts object shape. Report writes are atomic (tmp+rename). Diff-mode flavor list trimmed to 5 specialists
- **Security hardening** — SQL injection eliminated across 5 files (sed-escaped interpolation replaced with python3 parameterized queries). Bearer tokens passed via `curl --config` file instead of `-H` flag (invisible to `ps aux`). Path traversal validation on task_id and slug. Memory-capture redacts secret patterns in bash args
- **Correctness fixes** — `commands/council.md` uses `$ENGINE_SH` variable instead of bare `engine.sh`. Preflight field names match engine output. `init-orchestration` baseline seeding uses DELETE+INSERT (was broken INSERT OR REPLACE). `tdd-gate` intercepts MultiEdit and handles `src/` path prefix. `memory-distill` validation abort gated by exit code. `distiller.md` INSERT+lastrowid in single call. PRAGMA busy_timeout=5000 on all read paths. Schema lookup uses vendor-agnostic glob
- **Migration**: existing projects should re-run `/init-orchestration` to pick up the new hook templates and memory-capture fixes

### v0.19.2
- **Fix stop-review hook infinite loop** — the Stop hook (`stop-review.sh`) installed by `/init-orchestration` would enter an infinite exit-block loop when uncommitted changes existed before the session (or when the agent couldn't commit). Now uses a one-shot stamp keyed on `session_id` from stdin JSON: warns once, then lets the agent exit
- **Migration**: existing projects should re-run `/init-orchestration` to regenerate the hook, or manually replace `.claude/hooks/stop-review.sh`

### v0.19.1
- **Simplify project-init bash permissions** — replaced 44-entry command allowlist with single `Bash(*)` wildcard

### v0.19.0
- New `/tdd-gate` command — toggle hook-based TDD enforcement. When enabled, a `PreToolUse` hook blocks Write/Edit to implementation files unless a corresponding test file exists. Supports TypeScript, JavaScript, Python, Go, Rust. Inspired by Superpowers + TDD Guard
- Usage: `/tdd-gate on` to enable, `/tdd-gate off` to disable, `/tdd-gate status` to check

### v0.18.4
- Auto memory capture — `/init-orchestration` now installs a `PostToolUse` hook (`memory-capture.sh`) that logs Write/Edit/Bash actions to tier-0 memory automatically. No LLM calls — raw observations feed `/memory-distill` for compression later. Inspired by claude-mem
- **Migration**: existing projects should re-run `/init-orchestration` to pick up the new PostToolUse hook

### v0.18.3
- Stop hook self-review gate — `/init-orchestration` now installs a `Stop` hook (`stop-review.sh`) that blocks agent exit when uncommitted changes exist, forcing the agent to verify completeness before finishing. Inspired by codex-plugin-cc
- **Migration**: existing projects should re-run `/init-orchestration` to pick up the new Stop hook

### v0.18.2
- Terse agent-to-agent communication — agents compress output ~65% when spawned by `/orchestrate` or `/kickoff` (decisions, code, blockers only; no narrative). Inspired by Caveman plugin. Override per-agent via `/adjust-agent`
- Trigger: `Output mode: terse` in task prompt activates compressed output; user-facing sessions unaffected

### v0.18.1
- Fix: council report template substitution — `engine.sh finalize` now renders all `{{VAR}}` placeholders instead of dumping raw templates with appended JSON
- Fix: claim extractor now prioritizes behavioral claims ("the fix works") over code-structure assertions ("line N calls X") in frustration-heavy debugging sessions
- Fix: stdout summary surfaces PARTIALLY_VERIFIED / FABRICATED verdicts with claim text + confidence ("Needs attention" block), not just counts

### v0.18.0
- New `/council` adversarial tribunal — reality-checks claims with material evidence via blind investigators, prosecutor, devil's advocate, and a tool-less judge
- `/review-commit` refactored to delegate to the council engine via `diff-mode` preset (finding-shape output; identical user-visible behavior preserved)
- `/retro` now classifies fabrication anchors and prints `Consider: /council --from-retro <anchor-id>` hints at completion
- TaskCompleted hook gains an opt-in council quality gate — blocks completion until a council verdict at or above threshold when task metadata sets `requires_council: true`
- New `council-judge` agent with structurally empty tool allowlist enforcing the evidence-only invariant
- Per-task metadata store at `.claude/tasks/<id>.json` (orchestrator-owned) and verdict index at `.claude/council/index.json` (engine-owned)
- 60+ new MUSTs across SPEC-013 (new), SPEC-002, SPEC-009, SPEC-010, SPEC-012

### v0.17.2
- **Docs catch-up for v0.17.0/v0.17.1**: new `docs/commands/retro.md` walks through `/retro` end-to-end (flags, two-phase pipeline, dedup classification, apply paths, integration with `/kickoff` and `/orchestrate`)
- `docs/commands/kickoff.md` and `docs/commands/orchestrate.md` now document the Step 8b / Step 12b friction-check hook and link to `/retro`
- README `Commands / Skills` table gains a `/retro` row and notes `/adjust-agent`'s new `--apply` non-interactive mode

### v0.17.1
- **Polish pass on v0.17.0**: `commands/retro.md` 1031 → 993 lines; ~190 net LOC deleted across the retro feature
- Dead jq fallback paths removed from `skills/retro-gate/gate.sh` and `commands/retro.md` (python3 was already required elsewhere)
- Step 4a `load_rules()` helper deleted (superseded by Step 5b); `build_anchor_json()` and `target_rules_for()` helpers inlined
- `--why` signal parser rewritten from grep+awk to a python3 one-liner
- TIGHTEN classifier now uses a deterministic `existing_ref + "; additionally, " + proposed_text` merge instead of the "mentally rewrite" prompt-in-comment pattern
- New `skills/retro-gate/hint.sh` — friction-check helper; `/kickoff` and `/orchestrate` hooks now call it instead of duplicating ~30 lines each. One parser, one contract.
- `/adjust-agent`: conflict-detection rules extracted into a named subsection; Step 5c (interactive) and Step 6c (`--apply`) both reference it cleanly
- `skills/retro-subagent/SKILL.md`: 44-line worked example pruned to a UUID-format callout under the Input contract
- Nitpicks cleaned: HTML comments with personal paths and planning residue removed; unused `last_tool_use_target` variable and `tool_target()` helper deleted from gate.sh

### v0.17.0
- `/retro`: session retrospective — two-phase friction gate + phase-2 deep-read subagent; proposes targeted adjustments to agent directives
- `/adjust-agent --apply` non-interactive mode (SPEC-001 extension) — enables automation callers like `/retro --auto` while preserving conflict detection
- `/kickoff` and `/orchestrate` gain non-blocking friction-check hooks that suggest `/retro <session-id>` when friction accumulated
- New skills: `skills/retro-gate/` (phase-1 heuristic scorer), `skills/retro-subagent/` (phase-2 analysis prompt template)

### v0.16.0
- `/validate-memory`: cross-reference agent memories against the live codebase to detect stale references (dead files, renamed functions, shifted line numbers)
- Multi-stage validation pipeline: confidence scoring (0-100), auto-archive (>80), tech-lead review (40-80), user flag (<40)
- `--deep` mode: rebuild tier-1 digests whose source memories have gone stale
- Pre-distill integration: `/memory-distill` now validates before compressing (opt-out via `--skip-validate`)
- Schema v3 migration: `validated_at`, `archive_reason` columns, `validation_log` table
- Configurable validation window via `/memory-config set validate_window_days <N>`

### v0.15.1
- **SKILL.md YAML fix** — convert all multiline `description` fields to `|` block scalar syntax, fixing parse errors when skills are used outside Claude Code (colons in continuation lines were misinterpreted as YAML keys)
- **Baseline specs** — establish SPEC-001 through SPEC-010 from /generate-specs

### v0.15.0
- `/adjust-agent`: per-agent behavioral directives — customize agent tone, strictness, and standing orders per project
- Directives load before memory (Asimov model — standing orders agents cannot override)
- All 7 behavioral agents support directives loading
- `/init-team` now hints about `/adjust-agent` after bootstrap

### v0.14.2
- **Documentation revamp**: 10 command guides in `docs/commands/`, expanded memory distillation and remote embeddings docs
- **Doc restructure**: split 1313-line runbook into `docs/setup.md` (config/troubleshooting) and 6 goal-oriented runbooks in `docs/runbooks/`

### v0.14.1
- Fix CAS lock in `/memory-distill` — UPDATE + `changes()` now run in single sqlite3 session
- Add `@distiller` agent to README agents table
- Fix changelog: 7 working agents have tiered loading (not 8; project-init has no session read)

### v0.14.0
- **3-layer tiered memory distillation**: raw memories (tier 0) can now be compressed into LLM-generated digests (tier 1) and promoted to permanent core knowledge (tier 2) via `/memory-distill`
- **`/memory-distill`**: new command — compress raw agent memories into concise digests, evaluate for tier-2 promotion; supports `--agent`, `--status`, and `--force` flags; orchestrates a dedicated `@distiller` agent (Haiku)
- **`/memory-config`**: new command — view and set distillation config keys (`distill_enabled`, `distill_mode`, `distill_threshold`, `distill_model`) with validation
- **`@distiller` agent**: lightweight Haiku specialist spawned only by `/memory-distill`; never self-prompts; archives source memories after distillation (never deletes)
- **Tiered session loading**: all 7 working agents load tier-2 + tier-1 when distilled content exists; fall back to tier-0 for full backward compatibility on undistilled DBs
- **Auto-distill hook in `/wrap-ticket`**: in `suggest` mode prints notice when agents exceed threshold; in `auto` mode queues distillation at ticket close
- **Schema v2 migration**: `memories` table gains `tier`, `archived`, `distilled_from` columns; new `distillation_log` table; `migrate-v2.sh` for upgrading existing DBs; `/init-team` auto-migrates v1 DBs
- **`archived=FALSE` filters**: all memory queries (recall, memory-search, skill reads) exclude archived memories; `tier` column visible in search results

### v0.13.3
- **Smarter `/release` skill**: auto-detects patch/minor/major from args or commit history, auto-generates changelog from git log instead of asking, handles push failures gracefully
- **MEM-001/MEM-002 design docs**: brainstorm, specs, and plans for memory system improvements

### v0.13.2
- **Upgrade review-commit sub-agents to Opus**: the 5 parallel specialist review agents (Logic, Security, Compliance, Quality, Simplification) now use Opus instead of Sonnet

### v0.13.1
- **`/recall` two-phase search**: structured sources (memory, specs, plans, commits) are searched first, then related keywords are extracted and used to expand the session history search — finds precursor sessions that predate the formal identifier

### v0.13.0
- **Opus by default** for ic5, qa, and ds agents — removes aspirational escalation clauses in favor of native Opus reasoning where it matters (complex implementation, release gating, statistical analysis)
- **Comprehensive polish pass** driven by 4-agent quorum review (Tech Lead, PM, QA, IC5):
  - Fix `LIMIT 1` memory loads in kickoff/orchestrate/brainstorm/wrap-ticket — agents were booting with almost no context from the append-only DB
  - Add `Write, Edit` tools to tech-lead, pm, qa — they were chartered to produce artifacts but couldn't write files
  - Fix heredoc `'MEMEOF'` quoting bug that prevented `$CONTENT` expansion in wrap-ticket and init-orchestration fallback paths
  - Add `PRAGMA busy_timeout=5000` to memory-store write template (per-connection setting, not persisted in DB)
  - Resolve `schema.sql` from plugin cache for marketplace-installed users (was using `git rev-parse --show-toplevel` which only works in the plugin's own repo)
  - Sync scaffold-project allowlist with project-init (add `sqlite3:*`, `curl:*`)
  - Standardize `PROOT` → `MROOT` variable naming across all skills and commands
  - Fix undefined `$AGENT_MEM_ROOT` variable in project-init
  - Add YAML frontmatter to all 6 original command files — without it they were invisible to Claude Code's discovery/suggestion system
- **README overhaul**: correct agent count, replace deprecated ollama with remote in embedding table, group 22-command flat table into 6 workflow-stage sections, rewrite "Starting a task" to lead with `/kickoff`, add download size warning, fix memory layout diagram
- **Marketplace presence**: benefit-led descriptions replacing FAANG jargon, add `memory`, `orchestration`, `persistent`, `workflow`, `sqlite` keywords
- **Document commands/ vs skills/ convention** in AGENTS.md

### v0.12.4
- **`/init-team`**: sandbox allowlist setup is now zero-intervention — automatically adds `github.com:22` and embedding host to `.claude/settings.json`, prompts user once for sandbox approval

### v0.12.3
- **`/memory-search`**: unified — absorbs `/mem-search` into a single command with 3-tier auto-detection: semantic (embeddings) → keyword (DB LIKE) → grep (.md files); adds error handling for curl failures, dynamic vec table dims, and non-agent directory filtering

### v0.12.2
- **Generic remote embeddings** — set `EMBEDDING_URL` and `EMBEDDING_API_KEY` env vars to use any OpenAI-compatible embedding provider (OpenAI, LLMGateway, ollama, etc.)
- Ollama is no longer a special case — just set `EMBEDDING_URL=http://localhost:11434/api/embed`
- `/init-team` resolves plugin install path correctly for target projects
- `/init-team` auto-adds embedding host to sandbox network allowlist
- **Chunked migration** — .md files split by `##` sections into focused chunks for better embedding quality
- Migration generates embeddings inline, handles legacy vec table schemas, truncates to ~1000 chars

### v0.12.1
- **`/memory-stats`** — anonymized memory usage metrics (counts, sizes, boot load per agent). Safe to share for data-driven decisions.

### v0.12.0
- **SQLite memory backend** — agents now store memory in a single SQLite DB per project with semantic search via sqlite-vec embeddings
- **`/memory-search`** — new semantic search command across all agent memories
- **`memory-store` / `memory-recall` skills** — agent skills for DB-backed memory operations
- **Tiered embedding strategy** — remote provider (best quality) > sqlite-lembed (air-gapped) > keyword fallback
- **Automatic migration** — `/init-team` migrates existing .md memory files to SQLite
- **`/init-team --refresh`** — re-probe embedding mode and re-run migration

### v0.11.1
- **`/scout-plugins`**: new skill — automated competitive intelligence scan of the Claude Code plugin ecosystem; searches for new/updated plugins within a configurable time window (default 1 week), evaluates each against dev-team's current capabilities, classifies as ADOPT/STEAL/WATCH/SKIP, and produces an enhancement proposal table

### v0.11.0
- **`/brainstorm`**: new skill — Socratic design refinement with structured questioning rounds (Core Intent → Scope & Constraints → Edge Cases → Alternatives) that forces requirement clarity before planning; saves synthesis to `.claude/plans/`; inspired by Superpowers
- **`/recall [topic]`**: new command — cross-project session search across `history.jsonl`, agent memory, git history, specs, plans, and backlog; groups results by session and outputs `claude --resume <id>` commands for instant context recovery; inspired by WorkCommand
- **`/memory-search [query]`**: now unified — absorbs `/mem-search`; auto-detects best mode: semantic (embeddings) → keyword (DB LIKE) → grep (.md files)
- **`/review-and-commit` overhaul**: now runs 5 parallel specialist sub-agents (Logic, Security, Compliance, Design, Simplification) instead of single-agent review; adds confidence scoring (0-100) that filters findings below 80 to reduce false positives; adds AGENTS.md/CLAUDE.md compliance checking as a dedicated review dimension; inspired by local-review
- **`/kickoff` enhancement**: adds a parallel codebase exploration agent alongside PM and Tech Lead — traces execution paths, maps architecture patterns, and documents dependencies before design decisions; inspired by feature-dev
- **TDD gates**: IC4 and IC5 agents now enforce mandatory RED-GREEN-REFACTOR cycle for new features and bug fixes — write failing test first, then implement, then refactor; skip only for config/docs or when user opts out; inspired by Superpowers
- **Micro-task decomposition**: Tech Lead now breaks implementation plans into 2-5 minute micro-tasks with exact file paths, specific changes, interface contracts, verification steps, and dependencies; inspired by Superpowers

### v0.10.2
- **`/orchestrate`**: add Change Discipline rules — atomic PRs, ~1k LOC soft cap / 2k hard cap, no file >1k lines, refactoring always separate, discovered work becomes new tickets, replan gate on material deviations
- **`/init-orchestration`**: bake Change Discipline into AGENTS.md template and seeded memory so all agents self-police from project setup

### v0.10.1
- **`/init-orchestration`**: seeds `.claude/memory/claude/memory.md` with baseline orchestrator rules during project setup — prevents known mistakes (e.g. main session implementing instead of delegating) from being repeated in new projects

### v0.10.0
- **`/orchestrate`**: new skill — full lifecycle issue orchestrator; fetches issue context (Linear or prompted), creates branch/worktree, spawns PM+Tech Lead for scoping, IC4/IC5 for implementation, QA for validation, enforces tech-lead review loops with deadloop detection, optionally creates PR; main Claude stays as observer/navigator throughout

### v0.9.10
- **`/init-orchestration`**: enable bubblewrap sandbox (`sandbox.enabled: true`, `autoAllowBashIfSandboxed: true`) + simplify permissions to `Bash(*)` with `bypassPermissions` — replaces 70-line command allowlist with OS-level isolation for zero-prompt fully autonomous agents

### v0.9.9
- **`/init-orchestration`**: now creates `CLAUDE.md` as `AGENTS.md` reference (migrates existing content); AGENTS.md template gains battle-tested workflow rules (spec compliance, project-local paths, version bumping, no over-planning); hook template adds spec-change detection example

### v0.9.8
- **`/generate-tests`**: new skill — generates unit/integration tests from behavioral specs; reads MUST/SHOULD/MUST NOT requirements, detects project test framework and conventions, writes one test per requirement tagged with source spec ID (`// Generated from SPEC-NNN`), runs tests and reports pass/fail baseline; closes the spec-to-test gap when used after `/generate-specs` or `/create-spec`

### v0.9.7
- **`/generate-specs`**: new skill — reverse-engineers behavioral specs from existing source code; groups public surface into 8–15 domain-level specs with MUST/SHOULD/MUST NOT language; marks all output `INFERRED` for human review; designed for legacy project onboarding
- **runbook**: adds Phase 0 (legacy baseline) referencing `/generate-specs`; Phase 1.3 now directs to `/generate-specs` when no specs exist; Quick Reference updated

### v0.9.6
- **`/kickoff`**: new skill — orchestrates full ticket intake + planning phase; parallel PM+Tech Lead kickoff, spec creation, implementation plan, and TaskCreate task graph from a single command
- **`/standup`**: new skill — status snapshot of active agent team work; reads TaskList + each agent's context.md, surfaces blockers and stale tasks
- **`/wrap-ticket`**: new skill — close-out workflow; verifies all tasks completed, captures learnings to project memory, updates plans index, removes worktree, prints Linear checklist
- **docs**: Linear-to-prod runbook with full agent team orchestration walkthrough (POC-123 example)

### v0.9.5
- **Agent autonomy**: fix `Task` → `TaskCreate, TaskList, TaskUpdate, TaskGet` on all coordinating agents (pm, tech-lead, ic5, qa); add Task tools + `SendMessage` to all 8 agents so they can coordinate and communicate without human intervention
- **Bash allow list**: expand init-orchestration permissions from 38 to 73 entries, covering shell builtins, text processing, and common dev tools; remove dangerous commands (rm, chmod, curl, wget, patch, source) to require human approval

### v0.9.4
- **Cost efficiency**: downgrade `ds`, `project-init` to Sonnet; add dynamic Opus escalation for `pm`, `ic5`, `qa`, `ds` with role-specific trigger conditions

### v0.9.3
- **`/review-and-commit` overhaul**: brutal honest review — no sugar-coating, explicit PII/data exposure scan, over-engineering and simplicity checks, commit gated on critical issues, "What I Would Do Instead" section, structured action items checklist, file:line citations required on every finding; review printed as text with optional save path arg

### v0.9.2
- **`/release` skill**: bumps version in all three required files (README.md, plugin.json, marketplace.json), commits, tags, and pushes — ensures they never get out of sync

### v0.9.1
- **`/reflect-specs` rename**: `/reflect-skills` renamed to `/reflect-specs` — the skill audits specs (and code alignment), not just skills; the old name was misleading

### v0.9.0
- **`/init-orchestration` skill**: bootstrap Agent Teams for any project — enables `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS`, adds a `TaskCompleted` quality-gate hook, and creates/updates `AGENTS.md` with team coordination rules; idempotent (safe to re-run)
- **`AGENTS.md`**: added to this plugin repo for contributors

### v0.8.1
- **`/review-and-commit` fix**: review output now written to `/tmp/review.md` instead of a project-local file, eliminating any risk of accidentally staging or committing it

### v0.8.0
- **`/reflect-specs` skill**: full-system health check — exhaustive code alignment across ALL specs (not sampled), cross-spec BLOCKER/WARNING/terminology-drift detection, skill/command self-consistency audit, interactive Phase 6 confirmation loop
- **Phase 5 independent code read**: reads every source file in full (not just keyword hits), summarizes each module's purpose, maps public surface (exported functions/types/routes/handlers) to specs, produces a module summary table with COVERED/UNCOVERED status — finds gaps that spec-driven grep would miss

### v0.7.0
- **Permissions sync**: `/init-team` now auto-syncs `.claude/settings.json` — merges missing permissions into existing projects without overwriting user additions
- **Expanded allowlist**: 41 entries covering agent bootstrap patterns (`_gc=*`, `MROOT=*`, `AGENT_*`), compound commands (`{:*`), shell control flow (`if`, `for`), and read-only `sed -n`
- **`/scaffold-project`** updated to emit the full allowlist for new projects

### v0.6.0
- **`/review-and-commit` skill**: review staged/modified files for bugs and spec drift, update out-of-date specs, append findings to `review.md`, then commit

### v0.5.0
- **`/check-specs` audit**: adds Phase 2 code alignment — samples 3–5 recently-updated specs, Greps source files, classifies each MUST requirement as MATCH / MISSING / DIFFERS, flags undocumented behavior (drift)
- **`/check-specs <ID>` validate**: fully rewritten — keyword extraction, language detection, source file discovery, per-requirement reasoning with `file:~line` evidence, drift detection, structured report with counts
- **`/create-spec`**: new Step 2.5 conflict scan — before creating, reads all existing specs and flags BLOCKER (direct contradictions) and WARNING (scope overlap); pauses for user decision
- **`/update-spec`**: new Step 3.5 cross-spec conflict check (same BLOCKER/WARNING logic, handles removed requirements); new Step 4.5 code alignment warning for added/modified requirements

### v0.4.0
- **Autonomy**: Added `.claude/settings.json` with `defaultMode: "acceptEdits"` and Bash allow list
- **Orchestration**: `pm`, `qa`, `tech-lead` can now spawn subagents via `Task` tool
- **project-init**: Added `Edit` tool for in-place file patching
- **Context efficiency**: All agents enforce memory file size budgets; ic5 applies `max_turns` limits
- **Scaffolding**: `/scaffold-project` now generates `.claude/settings.json` for new projects

### v0.3.0
- **Memory bootstrap**: `project-init` and `scaffold-project` now create `.claude/CLAUDE.md` and seed `.claude/memory/claude/memory.md` for project-local Claude Code memory

### v0.2.0
- **Backlog**: Added `/backlog` skill for `.claude/backlog/` management (add, close, list, init)

### v0.1.0
- Initial release: pm, tech-lead, ic5, ic4, devops, qa, ds, project-init agents
- Four-file per-agent memory system (cortex, memory, lessons, context) — worktree-aware
- Spec management: `/create-spec`, `/update-spec`, `/find-spec`, `/list-specs`, `/check-specs`
- `/scaffold-project` and `/init-team` commands
