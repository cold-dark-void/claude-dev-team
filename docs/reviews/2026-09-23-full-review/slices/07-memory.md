# Review slice 07: persistent memory subsystem

Reviewer: slice 07 of 10. Scope: 33 files from `slices/07-memory.txt`. I read every file in full.
Environment: Linux, bash 5, sqlite3 3.45.1 (I installed it for this review because it was not on PATH), shellcheck. I also downloaded the real sqlite-vec v0.1.6 and sqlite-lembed v0.0.1-alpha.8 through `download-extensions.sh` into a scratch project. HuggingFace was blocked, so the GGUF model was not downloaded.

Test runs (all green):
- `skills/memory-store/test-migrate.sh`: PASS=38 FAIL=0
- `skills/memory-store/test-seed-pack.sh`: pass=114 fail=0
- `skills/validate-memory/test-reconcile.sh`: 19 passed, 0 failed (it prints a stray `5000`, see F-19)
- `skills/agent-memory/sync-includes-test.sh`: PASS=58 FAIL=0. `sync-includes.py check` also passes. The working tree was clean afterwards.
- `bash -n`: every script is clean.
- `shellcheck -S warning`: only SC2034 (unused variable) and SC1007 warnings (listed in the per-file table).

## Slice summary

- **What it does:** each agent keeps persistent memory in a SQLite DB shared across worktrees (`.claude/memory/memory.db`), with a `.md` fallback when the DB is unavailable. There are tiers: 0 = raw, 1 = digest, 2 = core, plus an archived flag. The `distiller` agent compresses memories. `/memory validate` checks memories against the codebase, and `--reconcile` looks for contradictions between agents. Other parts:
  - optional vector search via the sqlite-vec and sqlite-lembed extensions, or a remote embedding service
  - seed packs that can be exported and imported
  - directives (standing orders) managed by `/adjust-agent`
  - an include-drift checker that keeps the memory protocol identical in all 7 agents
- **Overall grade: D+.** The security hardening of the seed-pack import is careful and well tested. Several headline features, however, do not work at all or silently do nothing, and the tests do not catch it because they cover only the host scripts and not the LLM-facing command bash.
- **Biggest risk 1: local semantic search never works.** The default `lembed` mode calls `lembed('<path to .gguf>', …)`. The real extension rejects this with `Unknown model name … Was it registered with lembed_models?`. All errors are sent to `/dev/null`, so no embedding is ever stored or queried.
- **Biggest risk 2: several `/memory` sub-flows are broken as written:**
  - `/memory distill` with no `--agent` has a `# lint-ok` comment inside a SQL string, which is a parse error.
  - The pre-distill validation always hits validate's own `distilling_lock` guard.
  - `validate --deep` has the same SQL-comment bug twice.
  - `validate --reconcile` cannot find `reconcile-lib.sh` on an installed plugin.
- **Biggest risk 3: validation scoring cannot reach its archive thresholds.** The maximum possible score is 45, but auto-archive needs more than 80. A memory that points at a deleted file scores about 36, which is the "flag to user" bucket, so validation never archives anything automatically.
- **Biggest risk 4: data loss in `migrate-md.sh`.** It deletes every line starting with `#` (headings, code comments, `#42` references) and truncates sections to 8000 characters, then deletes the source `.md` file.
- **Biggest risk 5: tiered session loading hides new raw memories.** Once an agent has any tier-1 or tier-2 row, new tier-0 memories are never loaded at session start. That includes seed imports, and seeds are imported *before* `project-init` writes its tier-0 cortex, so the day-1 bootstrap is invisible. This matches SPEC-006, so it is a design flaw rather than a spec violation.
- **Portability:**
  - `export-seed-pack.sh` needs bash 4 (`declare -A`, `mapfile`), so it fails on the stock macOS bash 3.2.
  - `seed-common.sh` hard-codes `sha256sum`.
  - The Python fallback for `realpath -m` puts untrusted paths into Python source. That fallback runs on macOS.
- **Test coverage:** `test-migrate.sh` and `test-reconcile.sh` are not wired into CI. `smoke.py` excludes `test-*.sh` and `smoke.yml` lists only test-seed-pack and sync-includes. No test runs the command-markdown bash blocks (distill, recall, validate).

## Per-file review

| File | Lines | Purpose (short) | Verdict | Findings (concise, with line numbers) |
|---|---|---|---|---|
| agents/distiller.md | 94 | Haiku agent that turns tier-0 into tier-1 digests and promotes tier-1 to tier-2 | Minor | Frontmatter OK. Digests are never embedded (no embed-one call at 30-51), so tier-1/2 rows are invisible to semantic search (F-16). The INSERT (33-41), archive (45) and log (50) steps are not in one transaction, so a mid-batch failure leaves duplicates. Rule 90 says to escape with sed, but step 3 uses Python parameters: the guidance is mixed. The promotion criterion "Referenced multiple times across sessions" (64) is not something the distiller can observe. |
| agents/project-init.md | 525 | One-time bootstrap of cortex and lessons for 7 agents | Issue | Line 148 uses `cat >` (truncate) and 150 has an indented `  EOF` that never ends the heredoc. That breaks the append-only contract, and a re-run (516) clobbers the .md fallback (F-17). Line 455 uses `$MROOT` in a fence where it is never set, so it writes `/.claude/CLAUDE.md` (F-17). DB inserts (143, 166-168) have no `.timeout` and no embedding. Step 1b adds `Bash(*)` plus `acceptEdits` even when there is no sandbox (61-70) (F-22). `SendMessage` is listed in tools but never used. Its tier-0 writes are hidden by seeded tier-1 rows (12, F-5). |
| commands/adjust-agent.md | 388 | Directives dashboard, view, edit and Model-map flags | Minor | Line 81: `grep -c … \|\| echo 0` gives `0\n0` for a file with no matches, which breaks the table (verified). Lines 250-252 append a bare `.claude/memory/` to .gitignore, which contradicts SPEC-024 M9 (seed must stay committable; F-20). The Step 7 block (348-381) reads `$1…`, which is empty in a Bash-tool fence unless the model adds `set --` (F-21). The long PDH stanza is duplicated 4 times (39, 75, 123, 342). |
| commands/memory.md | 1795 | `/memory` dispatcher: config, distill, export, search, stats, validate, reconcile | Major | 413: `# lint-ok: C1` inside SQL gives `unrecognized token "#"` (verified), so distill-all always reports "no agents" (F-2). 1426 and 1516: same bug in `--deep` (F-2). Distill 4.5 (336-371) calls validate, but validate's lock guard (831-845) refuses because distill already holds the lock (F-3). 1150-1199: max score 45 can never pass >80, and 40-80 is rarely reached (F-4). 1595-1600, 1706 etc.: reconcile-lib is found via WTROOT/`CLAUDE_PLUGIN_ROOT` rather than the PDH stanza (F-6). 994 and 1016: Python fallback puts `$REF_PATH` into Python source (F-11). `--agent` is interpolated into SQL unescaped (437, 882). 535: `bash "$EXPORT_SH" $ARGUMENTS "$MROOT"` only works by accident because the last positional wins. `stats --agent` is documented (628) but not implemented. `--compress` is not in the flag parse list (258-261). The reconcile cap goes up to 500 but judge batches stop at 50 (1642). |
| commands/recall.md | 251 | Cross-source finder over sessions, memory, specs, plans, git | Minor | Rules 247 say "5 memory matches" but the SQL at 77 uses `LIMIT 10` and prose at 62 says a 10-row cap. `$MROOT` is unquoted in grep at 87, 103, 116 and 129. `$ARGUMENTS` is pasted into double-quoted shell (41, 70, 87), so a quote in the topic breaks the command (the user is the only source, so low risk). `CLAUDE_DIR` (28) is unused. |
| docs/commands/memory.md | 185 | User docs for /memory | Minor | 40-41 give defaults for validate_window_days and reconcile_pair_cap as "—", but the schema has 7 and 50. 183: the anchor `#memory-configuration-memory-config` is broken; the real slug is `--memory-config`, which README uses. 5: the "removed at v1.0.0" deprecation note is stale. 137 documents `stats --agent`, which is not implemented. |
| docs/commands/recall.md | 64 | User docs for /recall | Minor | 58 repeats the "5 memory matches" cap that conflicts with the command. The MEM-002 example IDs (21-35) predate the SPEC-xxx naming. |
| docs/runbooks/memory.md | 220 | Memory runbook | Minor | 83 says "cosine similarity", but the metric is L2 (F-9). 172 calls lembed the "Default after /setup team", but it is broken (F-1). 207 says core memories "can't be edited through commands", but validate rewrite and reconcile merge exist. The quick reference omits validate, export and stats. The tier-hiding behaviour (F-5) is not mentioned. |
| skills/agent-memory/cortex-load.md | 44 | Shared tiered-cortex read partial (/debug, /refactor) | Minor | 34-35: no `.timeout`, and `[ "$HAS_DISTILLED" -gt 0 ]` has no `:-0` default, which errors when the DB is busy or missing. It selects `content` only, while SPEC-006 requires `type, content`. The fallback (42) reads only cortex.md, while protocol.md reads 3 files. The heading "Tech Lead" (22) is hard-coded despite the `<AGENT>` parameter. |
| skills/agent-memory/protocol.md | 130 | Canonical agent memory protocol, inlined into 7 agents | Issue | 62-75: tiered read hides tier-0 once any tier>0 row exists (F-5). 106-108: the embed-one path uses cwd `skills/…` then the cache `find`. It skips `CLAUDE_PLUGIN_ROOT` and the marketplace clone, unlike the PDH rule. 100-103: the retry re-runs the INSERT, which can double-insert if the first call committed but returned non-zero. 112-114: the fallback writes the literal placeholder `<content>` while the DB branch uses `$CONTENT`, which is inconsistent. |
| skills/agent-memory/sync-includes-test.sh | 124 | Bite tests for sync-includes.py mode parsing | Minor | 58/58 pass. It runs `apply` against the live repo (97-100), which is safe only when there is no drift. There is no test for a missing partial (traceback) or for real drift detection or rewrite on a fixture. |
| skills/agent-memory/sync-includes.py | 131 | Expand and verify managed `<!-- include -->` regions | Minor | 44: a missing partial raises an uncaught `FileNotFoundError` traceback. Explicit file args resolve relative to cwd while partials resolve against `--root`, which is inconsistent. The docstring (24, 67) says only agents/ and skills/ are scanned, but the code also scans commands/ and AGENTS.md. "(and, later, the AGENTS.md rule-body partials)" (16-17) is stale. |
| skills/memory-compress/SKILL.md | 56 | Guidance for rewriting memory prose to be fact-dense | Minor | 5: "Companion to /memory-distill" uses a removed command name. 51-52 refer to a "memory-store UPDATE protocol" that does not exist (memory-store is INSERT-only). The protocol bash (45-53) is a no-op. Rewriting content in place leaves vectors stale. |
| skills/memory-recall/SKILL.md | 295 | Cross-agent keyword and semantic search | Major | 106: `&& \  # lint-ok: C1` breaks the line continuation, so the lembed branch runs whenever DIMS>0, including in remote mode (verified run output: `.load /vec0.so` fails) (F-7). 108 and 113: `EXT_DIR`/`MODEL_DIR` are never set in this fence (separate shell), so `.load /vec0` fails in both branches (F-7). 121: `lembed('$MODEL_PATH', …)` uses the wrong API (F-1). 117 and 284-285: says cosine, but vec0 defaults to L2, so the score can be negative (F-9). 202-210: `MEMDB` is set from `$MROOT` before MROOT is resolved, so USE_DB is always false and the grep fallback runs even when a DB exists (F-18). 146: `curl` has no timeout. |
| skills/memory-store/SKILL.md | 254 | Memory write protocol reference | Issue | 147: `bash skills/memory-store/embed-one.sh` is cwd-relative, so it is absent on an installed plugin, despite 154-155 claiming PDH resolution (F-13). 86-89: `$ESCAPED` is not defined in that fence. 211-214: "verify the write" selects the globally newest row, which is wrong under concurrent writers. 194: `-ge "$THRESHOLD"` with an empty value errors. 240: the lembed file-path claim is false (F-1). 249: lists only 384/768 tables, but remote creates any dimension. |
| skills/memory-store/download-extensions.sh | 425 | Download and verify extensions and model; set embedding mode; manage .gitignore | Minor | SHA-256 pinning is fail-closed and good. 328: picks `lembed` mode without requiring vec0. 307: under `set -e`, having no sqlite3 on PATH aborts the script. There is no `trap` to clean the `mktemp -d` dir on abort. On macOS, `/usr/bin/sqlite3` may lack `.load` support (unverified); the script degrades cleanly but gives the user no hint to install Homebrew sqlite. `curl` has no timeout. |
| skills/memory-store/embed-one.sh | 142 | Embed one memory row, best effort | Issue | 56-59: the lembed branch uses the wrong API, so every embed fails silently (F-1, verified with the real lembed0.so). 56, 126 and 133: `.load $EXT_DIR/vec0` is unquoted, so it breaks on paths with spaces (download-extensions quotes it). 94: `curl` has no `--max-time`, so an agent memory write can hang on an unreachable endpoint (F-14). 73: EMBED_MODEL falls back to the DB value `none` or `remote` and is sent to the provider as `model` (verified: `embedding_meta.model='none'`). The remote path works (verified against a stub server). |
| skills/memory-store/export-seed-pack.sh | 327 | Export a sanitized tier-2 seed pack | Issue | 87-89 and 224: `declare -A` and `mapfile` need bash 4, so the script fails on macOS bash 3.2 (F-10). 301-308 and 250-253: `--agent X` deletes every other agent's pack file and rewrites the manifest with only X (verified: `ic5.md` removed) (F-12). Content containing a `---` line is not escaped, so import rejects the entry (F-12, verified). SC2034: `mtype` is unused (92). |
| skills/memory-store/fixtures/migrate/v1-minimal.sql | 40 | Test fixture: v1 schema | OK | Matches the historical v1 shape. It has one seed row but no embedding rows, so migrate is not tested against a DB with vec tables. |
| skills/memory-store/fixtures/migrate/v3-minimal.sql | 72 | Test fixture: v3 schema | OK | Consistent with migrate-v2 and migrate-v3 output. |
| skills/memory-store/import-seed-pack.sh | 445 | Import a seed pack (security-hardened) | Minor | Validation of roster, symlinks, hashes and key side-channels is strong. Seeds are inserted as tier 1, which triggers F-5 for that agent. 186-192: the fallback line cap is not enforced when `existing < limit` (it appends anyway), and FALLBACK_LIMITS_* (161-163) are unused. Dedupe (224-227) is global by hash, not per agent. Embed calls inherit F-1. SC2034: `rc` and `fcount` are unused. |
| skills/memory-store/migrate-md.sh | 320 | Migrate legacy .md memory into the DB, then delete the source | Major | 109 and 119: `sed '/^#/d'` drops headings and any content line starting with `#`, then the source is deleted at 296 (verified data loss) (F-8). `head -c 8000` / `head -c 5000` (109, 126) silently truncate before deletion (F-8). 234: lembed uses the wrong API. 250-254: a failed `table_info` probe makes it DROP the existing vec table. 175/267 embed archived rows too. python3 and sqlite3 availability are not checked (55, 167). |
| skills/memory-store/migrate-v2.sh | 112 | Migrate v1 to v2 (table rebuild) | Minor | The version check (31) runs outside the transaction and uses plain `BEGIN` rather than `BEGIN IMMEDIATE` (55), so two worktrees migrating at once can both rebuild. The schema_version bump and `distillation_log` creation (90-109) run after COMMIT. The window is small and the result idempotent, but not atomic. |
| skills/memory-store/migrate-v3.sh | 87 | Migrate v2 to v3 (validation columns) | OK | Guards for existing columns are good and `.bail on` is used. Same non-IMMEDIATE transaction note as v2. |
| skills/memory-store/migrate-v4.sh | 78 | Migrate v3 to v4 (reconcile_log) | OK | Idempotent and transactional. |
| skills/memory-store/migrate.sh | 91 | Loop migrations up to LATEST | OK | Correct loop with a no-advance guard. `LATEST=4` is duplicated in schema.sql, with no single source. |
| skills/memory-store/schema.sql | 117 | Fresh v4 schema | Minor | `vec0(memory_id INTEGER, embedding FLOAT[N])`, created elsewhere, uses the default L2 metric, while docs say cosine (F-9). The `PRAGMA foreign_keys=ON` at 117 is per-connection and has no lasting effect, which the comment implies it does. `journal_mode=WAL` prints `wal` on apply (callers silence it). |
| skills/memory-store/seed-common.sh | 269 | Shared seed helpers (sanitize, hash, gitignore) | Issue | 53 and 100: `sha256sum` only, while download-extensions has a `shasum` fallback; this breaks on macOS without coreutils (F-10). The sanitizer rejects any URL with a path, even on allowlisted github.com (`/github.com/foo/bar` is flagged as an absolute path), and dotted filenames like `next.config.js` are flagged as hostnames (verified, F-15). 127: `[\w.-/]` is a range and does not include `-`. 254: `mv` of a mktemp file changes `.gitignore` mode to 0600. |
| skills/memory-store/test-migrate.sh | 231 | Bite tests for migrate driver | Minor | 38/38 pass. **Not wired into CI** (F-20b). No concurrency test, no test with vec tables present, no negative test (v2→v3 with a pre-existing column is covered only by the code path). |
| skills/memory-store/test-seed-pack.sh | 961 | Bite tests for seed export/import | Minor | 114/114 pass and it runs in CI. 76-81: `insert_tier2` captures the output of an inline `PRAGMA busy_timeout` (`5000\n<id>`) and then `eval`s it; this is a latent bug when `id_out` is used. `set -e` is switched on mid-script (226) and stays on. Missing tests: `--agent` scoped export pruning, `---` inside content, and macOS bash 3.2. SC2034: `PLUGIN_ROOT` is unused. |
| skills/validate-memory/SKILL.md | 505 | Prompt templates and contracts for validate and reconcile | Issue | 481-505: the scoring formula caps at 45, which makes the >80 and ≥40 buckets unreachable or rare (F-4; SPEC-011:167 expects >80 for a deleted file). 350 says the embed score is "cosine similarity", but it is 1-L2 (F-9). Extractor rule 2 (107) does not require every input memory to appear in the output. The prompts themselves are clear, have good injection guards and are well bounded. |
| skills/validate-memory/reconcile-lib.sh | 489 | Candidate pairing and resolve SQL for reconcile | Issue | 306-319: the O(n²) keyword path spawns about 12 processes per pair. I measured 70 memories at 75 s; the 1,400-row sample it allows extrapolates to hours (F-8b). 150/161: TSV export of multi-line or tab content misparses rows, truncating content or dropping pairs (verified). 347: `IFS='\|'` parsing of KNN output breaks on `\|` or newlines in content. 351: `1-distance` on L2 (F-9). 359: `_embed_candidates` always returns 0, so a broken vec0 or empty vec table reports `method=embed` with 0 candidates and never falls back to keyword. With F-1 this makes reconcile a no-op on every lembed install (F-8b). 380/395/408: `PRAGMA busy_timeout` writes `5000` to stdout. No check that winner≠loser or that the ids exist, and no transaction around archive plus log. `BEHAVIORAL` (24) is unused. |
| skills/validate-memory/test-reconcile.sh | 460 | Bite tests for reconcile lib and migrate-v4 | Minor | 19/19 pass. **Not wired into CI** (F-20b). T15 (364-391) asserts `method=embed` with a zero-byte `vec0.so`, which locks in the silent-no-fallback bug. `MIGRATE_V3` and `V2_SQL` are unused. SC1007 at 10-11. |

## Findings

**F-1 [P0] The lembed embedding mode (the default local semantic search) cannot work because it uses the wrong sqlite-lembed API.**
- **Where:** `skills/memory-store/embed-one.sh:56-59`, `skills/memory-recall/SKILL.md:121` and `:286`, `skills/memory-store/migrate-md.sh:234-235`, `skills/memory-store/SKILL.md:240`.
- **Evidence:** with the pinned `lembed0.so` v0.0.1-alpha.8 that `download-extensions.sh` downloaded:
  ```
  $ sqlite3 :memory: ".load …/lembed0" "select lembed('/path/model.gguf','hi');"
  Error: stepping, Unknown model name '/path/model.gguf'. Was it registered with lembed_models?
  ```
  embed-one runs the batch with `2>/dev/null || true`, so every lembed write silently stores no vector. recall's semantic query fails the same way.
- **Fix:** register the model in the same session before calling `lembed()`:
  ```
  INSERT INTO temp.lembed_models(name, model) SELECT 'all-MiniLM-L6-v2', lembed_model_from_file('<path>');
  ```
  Then call `lembed('all-MiniLM-L6-v2', …)`. Put this in one shared helper used by embed-one, recall and migrate-md. Correct the "takes the model file path" notes in two SKILLs. Add a CI test that loads the real extension, or at least asserts that the registration SQL is present.

**F-2 [P1] Three SQL strings in `commands/memory.md` contain a `# lint-ok: C1` comment inside the query, which is a SQL parse error.**
- **Where:** `commands/memory.md:413` (distill agent selection), `:1426` (deep 10.1), `:1516` (deep 10.5).
- **Evidence:** running the block verbatim:
  ```
  Error: in prepare, unrecognized token: "#"   … HAVING COUNT(*) >= 1  # lint-ok: C1
  ```
  `/memory distill` with no `--agent` always gets empty `AGENTS` and prints "No agents have enough raw memories". `--deep` digest lookup and rebuild fail too. `$THRESHOLD` is also undefined in that fence.
- **Fix:** move the lint markers onto a bash line outside the SQL string, or use `-- lint-ok` SQL comments if the linter accepts them. Re-derive `THRESHOLD` inside the fence. Add a lint rule that flags `#` inside a quoted `sqlite3` SQL argument.

**F-3 [P1] Pre-distill validation always aborts because of distill's own lock.**
- **Where:** `commands/memory.md:336-371` and `:831-845`.
- **Evidence:** distill Step 4 sets `distilling_lock='distill-<epoch>'`. Step 4.5 then runs "the validate sub (Steps 1–8)". Validate Step 1 says: "if [ -n "$LOCK" ] … Error: distilling_lock is held … Stop". Distill Step 4.5.3 then releases the lock and aborts with "Validation failed". There is no exemption text anywhere (I grepped for pre-distill, own and called from).
- **Fix:** pass an explicit `CALLER=distill` / `LOCK_OWNER=<token>` and have validate skip its guard when the lock value equals the caller's token. Alternatively, run validation before acquiring the lock.

**F-4 [P1] Validation's composite score can never reach its thresholds, so it never auto-archives.**
- **Where:** `skills/validate-memory/SKILL.md:481-505`, `commands/memory.md:1150-1199`, and SPEC-011:26 vs :37-38 and :167.
- **Evidence:** the score is the average of `BASE_POINTS × confidence/100`, with a maximum of 40, plus an age modifier of up to 5, giving at most 45. The `>80` auto-archive bucket is therefore unreachable. The `40-80` reviewer bucket needs nearly every claim CONTRADICTED at high confidence on a memory older than 30 days. A deleted-file memory (CONTRADICTED@90) scores 36, which lands in "flag_user" and is never archived. SPEC-011:167 expects it to be ">80, auto-archive".
- **Fix:** either scale the average to 0-100 (for example `raw = avg(pts)/40*100`) or rescale the buckets to the 0-45 range. Update SPEC-011 and add a worked-example test.

**F-5 [P1] Tiered session load hides all tier-0 memories once any digest or core row exists (design flaw; SPEC-006-conformant).**
- **Where:** `skills/agent-memory/protocol.md:62-75`, which is inlined into 7 agents, and `cortex-load.md:34-40`.
- **Evidence:** `if HAS_DISTILLED>0 → load tier2 + tier1 only`. The consequences:
  - Raw memories written after the last distill are invisible at session start until the next distill.
  - `import-seed-pack.sh` inserts seeds as tier 1 *before* `project-init` writes its tier-0 cortex (`agents/project-init.md:12`), so a seeded project never loads its own bootstrap.
  - `distill_enabled` defaults to false.
- **Fix:** always also load recent tier-0 rows, for example `tier=0 AND archived=FALSE AND created_at > (SELECT MAX(created_at) FROM distillation_log WHERE agent=…)` with a cap. Alternatively, load tier-0 whose ids are not in any digest's `distilled_from`. Amend SPEC-006.

**F-6 [P1] `/memory validate --reconcile` cannot find `reconcile-lib.sh` on an installed plugin.**
- **Where:** `commands/memory.md:1595-1600`, `:1706-1708`, `:1725-1727`, `:1742-1744`, `:1757-1759`, `:1773-1775`.
- **Evidence:** it resolves via `$WTROOT` (the user's repo) and then `${CLAUDE_PLUGIN_ROOT:-$WTROOT}`. The `export` sub in the same file uses the mandated PDH stanza plus `plugin-dir.sh file`. The PDH stanza itself treats `CLAUDE_PLUGIN_ROOT` as possibly unset or text-substituted. When unset, `bash "$RECONCILE_LIB"` fails, `|| true` hides it, and `CAND_N` is empty. (Runtime behaviour on a real install is unverified; the divergence from the AGENTS.md rule is verified.)
- **Fix:** use the PDH stanza plus `plugin-dir.sh file skills/validate-memory/reconcile-lib.sh` in all six places, and fail loudly if it is not found.

**F-7 [P1] The semantic-search fence in memory-recall Step 4 is broken twice.**
- **Where:** `skills/memory-recall/SKILL.md:106-113`.
- **Evidence:** the line ends `… && \  # lint-ok: C1`. A backslash followed by a space escapes the space rather than the newline. The `if` condition becomes the next line alone (`[[ DIMS ]] && [ DIMS -gt 0 ]`), so remote mode enters the lembed branch. Running the fence verbatim in remote mode:
  ```
  + '[' remote = lembed ']'
  + [[ 8 =~ ^[0-9]+$ ]]
  + MODEL_PATH=/all-MiniLM-L6-v2.gguf
  Error: /vec0.so: cannot open shared object file
  Error: /lembed0.so: cannot open shared object file
  Parse error near line 3: no such module: vec0
  ```
  `EXT_DIR` and `MODEL_DIR` are also unset because every fence is a separate shell (SPEC-021 C1).
- **Fix:** put the lint marker on its own line, and define `EXT_DIR`/`MODEL_DIR` inside the fence. Add a fence-execution test with a fixture DB in each mode.

**F-8 [P1] `migrate-md.sh` loses data and then deletes the source files.**
- **Where:** `skills/memory-store/migrate-md.sh:109,119,126,296`.
- **Evidence:** with a lessons.md containing `## Auth module`, a `# NEVER run this against prod…` comment inside a code fence, and `#42 was the ticket…`, the migrated row keeps only the non-`#` lines. The report shows `Deleted: 1`. `head -c 8000` and `head -c 5000` truncate longer sections before deletion.
- **Fix:**
  - Strip only the leading `## ` heading line, and keep its text as a prefix of the chunk.
  - Never drop body lines.
  - Split, rather than truncate, oversized chunks.
  - Keep a `.bak` copy instead of `rm`, or require `--delete-sources`.

**F-8b [P1] Reconcile candidate generation is unusable at scale and silently a no-op in embed mode.**
- **Where:** `skills/validate-memory/reconcile-lib.sh:306-319`, `:359`, `:150-172`.
- **Evidence:**
  - 70 memories took 75 s (`time` measured). The sample cap allows 200 per agent × 7 = 1,400 rows, about 840k pairs, which extrapolates to about 8 h.
  - `_embed_candidates` always `return 0`, and test-reconcile T15 asserts `method=embed` with a zero-byte vec0. So a broken extension or an empty vec table (always the case in lembed mode because of F-1) yields 0 candidates with no keyword fallback.
  - Multi-line content is truncated at its first newline in the TSV (verified).
- **Fix:**
  - Compute Jaccard for all pairs in a single python3 pass. The script already depends on python3.
  - Export rows as JSON, not TSV.
  - Return non-zero from `_embed_candidates` when the `.load` or query fails or the vec table has 0 rows, so it falls back to keyword.

**F-9 [P2] The vector metric is L2, but every consumer treats it as cosine.**
- **Where:** `skills/memory-recall/SKILL.md:117,284-285`, `reconcile-lib.sh:349-351`, `validate-memory/SKILL.md:350`, `docs/runbooks/memory.md:83`. Tables are created at `download-extensions.sh:375-376`, `embed-one.sh:127` and `migrate-md.sh:254`.
- **Evidence:** vec0 `[10,0]` vs `[0,10]` gives distance `14.1421356201172`, which is L2. `score=(1-d)*100` can be very negative. The reconcile threshold `1-d ≥ 0.55` is far stricter than intended.
- **Fix:** create the tables with `embedding FLOAT[N] distance_metric=cosine` plus a migration that rebuilds existing vec tables. Alternatively, convert L2 on normalized vectors to cosine with `1 - d²/2`.

**F-10 [P2] Seed-pack scripts are not portable to macOS.**
- **Where:** `export-seed-pack.sh:87-89,224` and `seed-common.sh:53,100`.
- **Evidence:** `declare -A` and `mapfile` are bash 4+, and `#!/usr/bin/env bash` resolves to 3.2 on stock macOS. `sha256sum` is not on stock macOS. download-extensions.sh already has a `shasum -a 256` fallback (106-116).
- **Fix:** replace the associative arrays with per-agent temp files or `eval`'d variable names, replace `mapfile` with a `while read` loop, and reuse download-extensions' `sha256_of` in seed-common.

**F-11 [P2] Code injection through untrusted claim paths in the validate fallbacks.**
- **Where:** `commands/memory.md:993-994,1014-1017`.
- **Evidence:** `python3 -c "…os.path.join('$WTROOT','$REF_PATH')…"`. `REF_PATH` comes from LLM-extracted claims over memory content, and that content can come from a committed seed pack, which is untrusted per SPEC-024 M8. This fallback runs whenever `realpath -m` is unavailable, which includes macOS BSD realpath. A path such as `x');import os;os.system('…');('` executes code. This is (unverified) end-to-end, because the model executes the fence, but the pattern is verified.
- **Fix:** pass the values as argv: `python3 -c 'import os,sys;print(os.path.normpath(os.path.join(sys.argv[1],sys.argv[2])))' "$WTROOT" "$REF_PATH"`. Do the same for `relpath`.

**F-12 [P2] Scoped export destroys other agents' packs, and `---` in content breaks round-trips.**
- **Where:** `export-seed-pack.sh:250-253,301-314` and `import-seed-pack.sh:281-303`.
- **Evidence:** `export` wrote `ic5.md` and `pm.md`; `export --agent pm` then left only `manifest.json` and `pm.md`. This contradicts SPEC-024 "SHOULD support --agent … for partial exports". A tier-2 row containing a `---` line imports as `rejected=2` ("unparseable trailer" and "hash mismatch").
- **Fix:** when `--agent` is set, only rewrite that agent's file and merge it into the existing manifest. Escape a body line that is exactly `---` (for example with a leading zero-width space or `\---`) on export and unescape it on import, or switch to a per-entry length or JSONL framing.

**F-13 [P2] The embedding helper is referenced by a cwd-relative path in the write protocol.**
- **Where:** `skills/memory-store/SKILL.md:147` (Step 4) and `skills/agent-memory/protocol.md:106-107`.
- **Evidence:** `bash skills/memory-store/embed-one.sh …` only exists in the plugin dev checkout. protocol.md adds only a `~/.claude/plugins/cache` fallback and skips `CLAUDE_PLUGIN_ROOT` and the marketplace clone, unlike the PDH rule.
- **Fix:** use the PDH stanza plus `plugin-dir.sh file skills/memory-store/embed-one.sh` in both. For the inlined agent protocol, the full stanza is acceptable given it already carries the cache `find`.

**F-14 [P2] Network calls have no timeouts.**
- **Where:** `embed-one.sh:94`, `memory-recall/SKILL.md:150`, `migrate-md.sh:219`, `download-extensions.sh:166,240`.
- **Evidence:** `curl -s "$EMBED_URL" …` has no `--max-time` or `--connect-timeout`. embed-one runs synchronously on every agent memory write.
- **Fix:** add `--connect-timeout 5 --max-time 20` for embeds and a longer limit for downloads.

**F-15 [P3] The seed sanitizer over-rejects common safe content.**
- **Where:** `seed-common.sh:133-185`.
- **Evidence:** `seed_sanitize_entry "See https://github.com/foo/bar …"` → `absolute path: /github.com/foo/bar`. `"… next.config.js …"` → `hostname: next.config.js`.
- **Fix:** strip `scheme://host` before the absolute-path scan and apply the host allowlist to URLs. Exclude tokens that end in known file extensions from the hostname heuristic.

**F-16 [P2] Digests and core rows are never embedded.**
- **Where:** `agents/distiller.md:30-51,74-78` and `agents/project-init.md:143,166-168`.
- **Evidence:** the distiller INSERTs tier-1 rows with no embed-one call. project-init INSERTs have no embed step either. Semantic search therefore covers mostly archived tier-0 vectors, filtered out by the join, and misses the highest-value rows.
- **Fix:** call embed-one after each digest insert and after project-init inserts, or run a "backfill unembedded" pass at the end of `/memory distill` and `/setup team`.

**F-17 [P2] Several project-init fences are incorrect.**
- **Where:** `agents/project-init.md:148-150,455-457,516`.
- **Evidence:**
  - The fallback uses `cat > … << 'EOF'` with an indented `  EOF`, so the heredoc never terminates, and the `>` truncates (append-only contract).
  - Line 455 uses `$MROOT` without resolving it, so it becomes `/.claude/CLAUDE.md`.
  - The advice to re-run `/setup team` duplicates DB rows or clobbers `.md` files.
- **Fix:** use `cat >>` with an unindented `EOF`, and resolve MROOT in that fence. In the DB path, dedupe by exact content before inserting on re-run.

**F-18 [P2] The grep fallback in memory-recall Step 5 uses MROOT before setting it.**
- **Where:** `skills/memory-recall/SKILL.md:202-210`.
- **Evidence:** `MEMDB="$MROOT/.claude/memory/memory.db"` (203) comes before `_gc=…MROOT=…` (208), so `USE_DB` is always false.
- **Fix:** move the `_gc`/`MROOT` lines to the top of the fence.

**F-19 [P3] An inline `PRAGMA busy_timeout` pollutes stdout.**
- **Where:** `reconcile-lib.sh:380,395,408,427` and `test-seed-pack.sh:76-81`.
- **Evidence:** `sqlite3 :memory: "PRAGMA busy_timeout=5000; SELECT 1;"` prints `5000\n1`. The test-reconcile output shows a stray `5000`. `insert_tier2` `eval`s the captured `5000\n<id>`.
- **Fix:** use `-cmd ".timeout 5000"` everywhere, as import-seed-pack already does.

**F-20 [P2] adjust-agent's gitignore step contradicts SPEC-024 M9.**
- **Where:** `commands/adjust-agent.md:250-252`.
- **Evidence:** it appends a bare `.claude/memory/`. `ensure_seed_gitignore` explicitly rewrites exactly that pattern, because it makes `.claude/memory/seed/` uncommittable.
- **Fix:** call `ensure_seed_gitignore`, or append `.claude/memory/*` together with the seed negations.

**F-20b [P2] The migrate and reconcile tests are not run in CI.**
- **Where:** `.github/workflows/smoke.yml` and `tools/smoke/smoke.py:26-28`.
- **Evidence:** smoke.yml runs only `test-seed-pack.sh` and `sync-includes*`. smoke.py excludes `test-*.sh` from discovery. `test-migrate.sh` (38 asserts) and `test-reconcile.sh` (19) never gate a PR.
- **Fix:** add jobs for both. They need `sqlite3`: `sudo apt-get install -y sqlite3`, or note that ubuntu-latest images may already have it.

**F-21 [P3] The adjust-agent Step 7 fence depends on positional args that do not exist.**
- **Where:** `commands/adjust-agent.md:348-381`.
- **Evidence:** `AGENT="${1:-}"` and a loop over `$@`. In a Bash-tool fence these are empty, so it prints the usage and exits 64 unless the model injects `set -- <agent> <flags>`, which the prose never says.
- **Fix:** add an explicit `set -- <agent> <flags…>  # model substitutes parsed args` line and document it.

**F-22 [P3, security posture] project-init grants `Bash(*)` plus `acceptEdits` even when no sandbox is active.**
- **Where:** `agents/project-init.md:45-71`.
- **Evidence:** it seeds `Bash(*)` whenever orchestration markers are absent, which is exactly the no-sandbox case. AGENTS.md's justification ("the sandbox is the boundary") does not hold on this path.
- **Fix:** seed `Bash(sqlite3:*)`, `Bash(git:*)` and similar narrow patterns when there is no sandbox, or ask for confirmation.

**F-23 [P3] Documentation drift.**
- **Where:** `docs/commands/memory.md:40-41,137,183`, `docs/runbooks/memory.md:83,172,207`, `commands/recall.md:62,77,247` vs `docs/commands/recall.md:58`, `skills/memory-compress/SKILL.md:5,51`, `skills/memory-store/SKILL.md:249`, and AGENTS.md "distiller invoked by /memory distill only" vs `commands/memory.md:1522` (`--deep` also invokes it).
- **Evidence:** wrong defaults, a broken anchor, "cosine", the "5 vs 10" memory-match cap, the stale `/memory-distill` name, a nonexistent "UPDATE protocol", and an unimplemented `stats --agent`.
- **Fix:** a doc sweep, plus a docs-drift check for the anchor.

**F-24 [P3] Robustness gaps in cortex-load.md.**
- **Where:** `skills/agent-memory/cortex-load.md:34-42`.
- **Evidence:** there is no `.timeout`, and `[ "$HAS_DISTILLED" -gt 0 ]` has no default, so a busy or locked DB gives `integer expression expected`. It selects `content` without `type`, contrary to SPEC-006:26. The fallback reads cortex.md only.
- **Fix:** mirror protocol.md (`-cmd ".timeout 5000"`, `${HAS_DISTILLED:-0}`, `type, content`).

**F-25 [P3] reconcile-lib resolve commands are not transactional and have no sanity checks.**
- **Where:** `reconcile-lib.sh:390-436`.
- **Evidence:** the archive UPDATE and the reconcile_log INSERT are separate sqlite3 invocations. There is no check that `winner != loser` or that the ids exist and are unarchived. Merge updates content but leaves a stale vector.
- **Fix:** put both statements in one `BEGIN IMMEDIATE…COMMIT` batch and add guards. Delete or refresh the winner's vec row on merge.

## Enhancement proposals

1. **A single `memdb.sh` CLI (subprocess) for all DB operations.** Subcommands: `insert`, `embed`, `tiered-read`, `search`, and `lock acquire/release`. It would use parameterized python3 sqlite, which is already a hard dependency. Command and agent markdown would call it through PDH instead of carrying about 60 duplicated `_gc/MROOT/WTROOT/MEMDB` preambles and hand-escaped SQL. This removes whole classes of bugs (F-2, F-7, F-18 and the SQL-injection-by-flag cases) and cuts tokens substantially: commands/memory.md is 1,795 lines and repeats the 4-line resolve block more than 40 times. Effort L, impact High.
2. **An embedding smoke test in CI.** Download the pinned vec0 and lembed0 in a job, allowing HF fetch or using a tiny cached GGUF artifact. Then assert that `embed-one` stores a vector and that recall's semantic fence returns it. This would have caught F-1, F-7 and F-9. Effort M, impact High.
3. **Fence-execution tests for command markdown.** Extract ```bash fences from `commands/memory.md`, `memory-recall/SKILL.md` and `recall.md`, run them against a fixture DB with placeholder substitution, and assert exit 0 and no `Parse error`. Extend skill-lint to flag `#` inside a quoted SQL argument and a `\` followed by a trailing space. Effort M, impact High.
4. **Fix tiered loading (F-5) with a bounded "since last distill" tier-0 tail.** Add an `/memory stats` column showing hidden tier-0 counts. Effort S, impact High.
5. **Rewrite reconcile candidate generation in python.** One pass, JSON I/O, token sets computed once, O(n²) in-process, which is milliseconds for 1,400 rows. Return non-zero when the embed path fails. Effort S-M, impact High.
6. **Rescale validation scoring (F-4)** and add unit tests for the formula against SPEC-011's worked examples. Effort S, impact High.
7. **Make migrate-md non-destructive by default.** Keep sources as `*.md.migrated`, add a dry-run, and preserve headings as a chunk prefix. Effort S, impact Med-High.
8. **Seed-pack portability and framing.** Rewrite export's aggregation in python3 (which is already used), remove the bash 4 dependencies, move to per-entry JSONL or length-prefixed framing, and make `--agent` merge rather than replace. Effort M, impact Med.
9. **Wire `test-migrate.sh` and `test-reconcile.sh` into `smoke.yml`,** and add macOS runners for the memory jobs. Effort S, impact Med.
10. **Lock TTL for `distilling_lock`.** Store the epoch, which is already done, and treat locks older than N minutes as stale automatically, so `--force` is not needed after crashes. Effort S, impact Low-Med.
11. **Trim `agents/project-init.md`.** Its 525 lines are about 60% role templates written in .md form, while SQLite mode wants one row per fact. Replace the templates with a compact per-role "focus" table plus the one-fact-per-row rule, and drop the unused `SendMessage` tool. Effort S, impact Low-Med (tokens).

## Coverage attestation

- Files in the slice list (`slices/07-memory.txt`): **33**
- Rows in the per-file review table: **33**, in the same order as the slice list.
- Every file was read in full: large files in 250-300-line chunks, and test-seed-pack.sh in full via a persisted output file. The test scripts in the slice were executed and passed. Findings marked "(unverified)" are the only ones not confirmed by running code or reading the exact lines.
