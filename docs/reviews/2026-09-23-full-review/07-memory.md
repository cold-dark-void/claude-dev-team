## Slice: memory / model-map / metrics / notify

I reviewed this slice read-only and changed no repo files. The `sqlite3` CLI was missing from the container, so I installed it with apt to run the tests. All throwaway databases went to reviewer scratch space.

### Test results
| Test | Result | Notes |
|---|---|---|
| memory-store/test-migrate.sh | PASS 38/0 | With no sqlite3 it prints `SKIP` and **exits 0** (line 87), so a CI job would look green even though nothing ran. |
| memory-store/test-seed-pack.sh | PASS 114/0 | With no sqlite3 it crashes with rc=127 at line 222 instead of skipping. |
| agent-memory/sync-includes-test.sh | PASS 58/0 | `sync-includes.py check` on the repo is also clean. |
| validate-memory/test-reconcile.sh | PASS 19/0 | With no sqlite3 it reports 18 failures instead of skipping. |
| metrics/test.sh | **FAIL 24/1** | Test 4 ("unwritable dir", :138-150) uses `chmod 555`, which root ignores. The test is not root-safe; the script under test is fine. |
| model-map/test.sh, effort-test, effort-write-test, spawn-site-test, write-model-test | PASS 30, 45, 66, 121, 51 | |
| notify/webhook-test.sh | PASS 8/0 | |

**CI gap:** `.github/workflows/smoke.yml` runs only test-seed-pack and sync-includes from this slice. Nothing in CI or `/release` runs test-migrate, test-reconcile, metrics/test, any of the 5 model-map tests, or webhook-test. There are no tests at all for embed-one.sh, download-extensions.sh (including its SHA-verify logic) or migrate-md.sh.

### Confirmed P0 bugs (reproduced)
1. **Second-order SQL injection that deletes the whole memory DB** — `validate-memory/reconcile-lib.sh:150-172, 331-343`.
   - Memories are exported as TSV (`-separator $'\t'`), so a multi-line memory's continuation lines become fake rows.
   - Their first field becomes `mid`, which is spliced into an unquoted heredoc: `WHERE memory_id = ${mid}`.
   - The sqlite3 call has no `.bail`, so statements after a failing one still run.
   - Repro: a memory with content `line one\n0); DELETE FROM memories; --`, embed mode configured, a vec table present and a vec0 file present. `reconcile-lib.sh candidates` took `memories` from 3 rows to **0**.
   - Anything that writes memory content can trigger this: agents, and imported seed packs, whose sanitizer does not block it.
2. **Broken line continuation in memory-recall** — `memory-recall/SKILL.md:106` reads `&& \  # lint-ok: C1`.
   - A backslash followed by a space and a comment does not continue the line, so the `if` result depends only on the DIMS test on line 107.
   - Result: remote mode with dims>0 **always takes the lembed branch**. I reproduced it: "TOOK LEMBED BRANCH" with `EMBED_MODE=remote`. Remote semantic search never works.
   - The same pattern appears outside this slice at `review-and-commit/SKILL.md:207` and `commands/council.md:1042`. skill-lint should flag it.
3. **Auto-archive in validation can never fire** — the `validate-memory/SKILL.md` "Composite Scoring Formula" section and `commands/memory.md:1152-1198`.
   - Highest per-claim score is 40 (CONTRADICTED), plus 5 for age, so the maximum score is 45.
   - Auto-archive needs >80 (SPEC-011:38) and is unreachable. The reviewer's "archive if >=60" is unreachable too.
   - The 40-80 band is reachable only when almost every claim is CONTRADICTED at ≥~88% confidence.
   - SPEC-011:167 expects a deleted-file memory to score >80, which is impossible under this formula.

### Per-file review
| File | Purpose | Verdict | Findings |
|---|---|---|---|
| memory-store/SKILL.md | Write protocol | **Needs fix** | See bullets under the table. |
| memory-store/schema.sql | Fresh v4 schema | OK | A v1→v4 migrated schema is column-for-column and config-identical to a fresh one (verified). `PRAGMA foreign_keys=ON` (:117) is per-connection and has no effect for other connections, so the FKs are decorative. `journal_mode=WAL` prints "wal" (callers already silence it). |
| memory-store/migrate.sh | Drives migrations to LATEST | Minor | `read_version` (:43) has no `.timeout` and swallows errors with `2>/dev/null \|\| echo ""`. A locked DB therefore reads as "No schema_version — skipping", exit 0: the migration is **silently skipped**. There is no backup before the destructive v2 rebuild. `LATEST=4` duplicates the seed in schema.sql (only covered indirectly by tests). |
| memory-store/migrate-v2.sh | v1→v2 table rebuild | **Spec drift** | `distillation_log`, the config inserts and the `schema_version='2'` bump (:88-110) run **after COMMIT**, which violates SPEC-004 "all schema changes in a single transaction". A crash between them makes the rerun rebuild again and reset tier/archived. The rebuild also drops the `sqlite_sequence` high-water mark, so ids can be reused and collide with orphaned `embedding_meta` rows. |
| memory-store/migrate-v3.sh | v2→v3 | OK | Column-presence guard and `.bail`/transaction are correct. The unquoted heredoc holds only constants. |
| memory-store/migrate-v4.sh | v3→v4 | OK | Idempotent and transactional. |
| memory-store/migrate-md.sh | Bulk .md→DB migration | **Data loss** | See bullets under the table. |
| memory-store/embed-one.sh | Best-effort per-write embedding | **Needs fix** | See bullets under the table. |
| memory-store/download-extensions.sh | Fetch vec0/lembed0/GGUF | Good supply chain, minor issues | See bullets under the table. |
| memory-store/seed-common.sh | Shared helpers for export/import | Minor | `seed_content_hash` and `seed_file_sha256` (:53,100) use `sha256sum` with no `shasum` fallback (download-extensions has one), so this may break on macOS. `ensure_seed_gitignore` replaces `.gitignore` via a 0600 `mktemp` file plus `mv` (:254), so the file ends up mode 0600. The sanitizer lacks the "username" and "high-entropy string" checks SPEC-024 M2 requires. `set -u` at :19 leaks into any shell that sources the file. |
| memory-store/export-seed-pack.sh | Export tier-2 memories to a committable pack | **Bug** | `PROJECT_NAME=$(basename "$MROOT")` (:65) goes into the trailer unescaped. The import regex needs `project=\S+`, so **a project directory whose name contains a space makes every entry rejected on import**. Verified: "My Proj" gave `rejected=1 imported=0`. The count query (:136) has no timeout. |
| memory-store/import-seed-pack.sh | Import pack as tier-1 digests | **Trust / design issue** | See bullets under the table. |
| memory-store/test-migrate.sh | Migration tests | Gaps | Missing: failure rollback, rerun of each `migrate-vN` at its target version, partial-v3 rerun, locked DB. Skips with exit 0. |
| memory-store/test-seed-pack.sh | Seed-pack tests | Good coverage | The M10 test (:279-303) is labelled "line caps" but never tests a cap. No test for a project name with spaces. |
| memory-store/fixtures/migrate/*.sql | Migration fixtures | OK | |
| memory-recall/SKILL.md | Cross-agent search | **Broken** | See bullets under the table. |
| memory-compress/SKILL.md | Prose-compression rules | Drift | Says "Companion to /memory-distill"; the command is `/memory distill`. Points to a "memory-store UPDATE protocol" that does not exist (memory-store is append-only). Rewriting tier-0 rows in place contradicts SPEC-004's append-only rule. The protocol snippet (:45-53) does nothing. |
| agent-memory/protocol.md | Single-source agent read/write block | Mostly OK | Uses `-cmd .timeout` and `${HAS_DISTILLED:-0}` correctly. The embed-one lookup (:106) checks a cwd-relative `skills/memory-store/embed-one.sh` **first**, so a user repo containing that path gets that script executed with memory content. It also skips `CLAUDE_PLUGIN_ROOT` and marketplace installs and doesn't use `plugin-dir.sh` as AGENTS.md mandates. No read-back of the write (SPEC-004 MUST). The tiered read has a design flaw: once any tier>0 row exists, **all tier-0 memories disappear from session start**, including lessons written after the last distill (SPEC-006:20 codifies this). |
| agent-memory/cortex-load.md | Cross-agent cortex fragment | Minor | No `.timeout`. Bare `[ "$HAS_DISTILLED" -gt 0 ]` (:35) errors on empty output from a locked DB and silently loads tier-0 instead. Selects `content` only, not the `type, content` SPEC-006:26 requires. |
| agent-memory/sync-includes.py | Include drift check/apply | OK | Partial path from a marker is joined without containment (`../`, absolute paths). A missing partial produces a traceback. A region missing its `<!-- /include -->` makes the non-greedy regex swallow up to the next close, and `apply` then corrupts the file. |
| agent-memory/sync-includes-test.sh | Tests | OK | |
| validate-memory/SKILL.md | Prompt templates and contracts | **Bug + drift** | Scoring formula is P0 #3. Data delimiters (`<<<END_BATCH>>>`, `<<<END_PAIRS>>>`) survive JSON encoding, so memory content can close the data block early — a prompt-injection path despite the SECURITY note. The candidate contract says "cosine similarity", but vec0 tables are created without `distance_metric=cosine`, so the metric is L2 (default) and `1-distance` is not cosine. |
| validate-memory/reconcile-lib.sh | Reconcile candidate generation and resolvers | **Critical** | See bullets under the table. |
| validate-memory/test-reconcile.sh | Tests | Gaps | T15 asserts `method=embed` with a dummy vec0, which locks in the fail-closed-to-nothing bug above. No multi-line or injection cases. Fails instead of skipping without sqlite3. |
| domain-glossary/SKILL.md | CONTEXT.md load/update | Drift | The load protocol (:73-83) reads only `$MROOT` (main checkout), while updates go to the worktree branch. A session inside a worktree loads a stale glossary; it should read `WTROOT` first, then `MROOT`. |
| metrics/SKILL.md | Documentation | OK | |
| metrics/emit-outcome.sh | Outcomes ledger writer | Minor | `json_num_or_null` (:137) passes any JSON to `--argjson`, so objects or strings land in numeric fields. Bad input reports "cannot write" (misleading). Numbers aren't checked against `^[0-9]+$`. |
| metrics/outcome-rates.sh | Advisory escalation rates | OK | Fails silently and safely. `printf '%.1f'` depends on locale. |
| metrics/rollup.sh | Read-only rollup | Minor | One malformed task JSON makes `jq -s` (:203) zero all task counts; the comment says malformed files count as "other". A non-string `.agent` makes the whole outcomes section report n=0. |
| metrics/test.sh | Tests | Root-unsafe | Test 4 (see Test results). |
| model-map/SKILL.md | Documentation | Drift | Claims `models.local.json` is "gitignored". That is only true in the plugin's own `.gitignore`: nothing adds `.claude/dev-team/models.local.json` or its `.lock` to user repos (SPEC-037 M1 says the repo `.gitignore` MUST list it). |
| model-map/resolve-model.sh | Layered resolver | OK | Model string isn't validated: an embedded newline passes through and the output becomes multi-line. A committed repo-layer `models.json` from an untrusted clone can downgrade `qa`/`council-judge`; this only warns on stderr (by design). |
| model-map/write-model.sh | Local-layer writer | **Portability** | `flock` (:146,170,190) is util-linux and not on stock macOS. With `set -e`, every set/unset fails with 127 there, so `/setup models` and `/adjust-agent --model/--effort` are broken on macOS. The leftover `models.local.json.lock` file can end up committed. |
| model-map/*-test.sh (5 files) | Tests | Pass | None of them run in CI. |
| notify/webhook.sh | Fail-open webhook POST | Minor security | The webhook URL (Slack/Discord URLs embed the secret in the path) and the payload go on curl's argv (:78-80), visible in `ps`. No `--proto =https,http` (curl accepts `file:`, `gopher:` and so on; there is no `-L`, which is good). The event enum isn't enforced. `detail` is caller free text with no secret redaction, despite the "Never includes secrets" header. `${DETAIL:0:500}` counts bytes in the C locale and can split a UTF-8 character. |
| notify/webhook-test.sh | Tests | OK | |

**memory-store/SKILL.md details**
- :236-237 says "Heredoc syntax sidesteps [escaping] for static content". False: a quoted heredoc avoids shell quoting, but a `'` inside the SQL literal (as in the :70-76 example) still breaks the SQL.
- :161 says "Always prepend `PRAGMA busy_timeout=5000;`", but that PRAGMA prints `5000`, which corrupts `$(...)` captures such as `MEMORY_ID` at :86. This contradicts protocol.md and import-seed-pack, which use `-cmd ".timeout 5000"`.
- :59 inserts `<AGENT>`/`<TYPE>` without escaping.
- :147 uses a cwd-relative `bash skills/memory-store/embed-one.sh`, which is absent on a real install, so embedding never happens there. The design notes admit this.
- The fallback heredoc breaks on a content line that is exactly `EOF`, and there is no line-cap enforcement.

**memory-store/migrate-md.sh details**
- Every chunk goes through `sed '/^#/d'` (:109,119). That deletes the `## Header` line itself, every `###` subheader and every line starting with `#`, and `sed '/^$/d'` removes blank lines.
- `head -c 8000` / `head -c 5000` silently truncates and can split UTF-8.
- The fail-closed gate ignores truncation and stripping, so **the source is deleted after lossy migration**.
- :250-254: if `PRAGMA table_info` fails (lock with no timeout, or a `.load` failure), `grep -c` gives 0 and the script runs `DROP TABLE vec_memories_N`, wiping every vector while the `embedding_meta` rows stay. Those memories are then treated as embedded and never re-embedded.
- :234: `json(lembed(...))` on a BLOB probably errors (`vec_to_json` is the right function; unverified here), so the lembed path would never work.
- With `set -e` and `pipefail`, a non-JSON endpoint response (:221,242) aborts the whole script.
- `.load $EXT_DIR/...` is unquoted.

**memory-store/embed-one.sh details**
- Uses no busy timeout on any write (:55,126,132), against SPEC-004 "MUST busy_timeout on every write". Under concurrent worktree writes, lembed-mode vectors are **silently lost** because of `2>/dev/null || true`, which also contradicts the file's own "do NOT silently swallow" comment at :119.
- `.load $EXT_DIR/vec0` is unquoted (a path with spaces breaks it).
- `'$MODEL_PATH'` isn't escaped (a path containing `'` breaks the SQL).
- curl (:94) has no `--max-time`, `--fail` or `--proto`, so a stalled endpoint hangs the agent's write.
- No trap removes the temp file holding the API key if the script is interrupted.
- `.load`s any vec0/lembed0 found in the project directory without hash verification. A hostile repo that force-commits `.claude/memory/extensions/vec0.so` gets native code execution on the first memory write.
- Uses `echo "$CONTENT"` instead of printf.

**memory-store/download-extensions.sh details**
- Supply chain is **good**: pinned versions, pinned model commit, https only, SHA-256 checked on the tarball *and* on the extracted member, fail-closed on a missing hash or tool.
- No `--proto =https --proto-redir =https` (mitigated by the hashes).
- The model downloads straight to its destination (:240), so a concurrent embed can read a partial file; download to a temp file and `mv`.
- The cross-filesystem `mv` of the `.so` is not atomic.
- `DIMS` comes from `EMBEDDING_DIMENSIONS` and is interpolated unescaped at :346.
- The `OLD_MODE=$(sqlite3 ...)` at :307 and the later writes have no timeout and abort the script under `set -e` if the DB is locked.
- `MODE=lembed` is chosen without checking that vec0 is present.
- The temp directory isn't trapped on signals.

**memory-store/import-seed-pack.sh details**
- Agent roster, symlink, hash and trailer-match gates are solid.
- **The tier-0 eclipse:** it inserts `tier=1`, and the session read (protocol.md:62-74, SPEC-006:20) loads tier-0 only when no tier>0 rows exist. So `/setup team --refresh` on a project with raw memories and no digests **hides all of the agent's existing tier-0 memories** at session start.
- Pack content is repo-supplied and untrusted. Only a self-attesting sha256 protects it; there is no signature, no instruction-pattern screen and no user confirmation. The content lands as trusted digest-tier context, making seed packs a prompt-injection channel.
- The fallback cap check (:186-192) appends whenever existing lines are under 80. Verified: 79 + one entry gave **83 lines**, against SPEC-024 M10.
- Dedupe is a full-table `LIKE '%hash=…]%'` scan, and any memory that quotes a trailer counts as a duplicate.
- The `sanitized` value is computed and then thrown away (:353-362).

**memory-recall/SKILL.md details**
- The :106 continuation bug is P0 #2.
- Step 5 (:202-210) uses `$MROOT` before defining it: `MEMDB` becomes `/.claude/memory/memory.db`, `USE_DB` is false, and the grep fallback runs even when the DB exists.
- The Step 5 `grep -lil "<QUERY>"` is regex, not `-F`, and a raw placeholder inside double quotes is a shell-injection risk if substituted literally.
- The Step 4 block uses `EXT_DIR`/`MODEL_DIR`, which are defined only in Step 1's separate shell.
- `.load` is unquoted. LIKE `%`/`_` in the query aren't escaped. `<AGENT_FILTER>`, `<TYPE_FILTER>` and `<CURRENT_MODEL>` placeholders are unescaped. curl has no timeout.
- The score `(1-distance)*100` uses L2 distance, not cosine.

**validate-memory/reconcile-lib.sh details**
- The P0 #1 injection.
- Multi-line content is truncated to its first line, so the judge sees partial claims (verified).
- `_embed_candidates` always `return 0` (:359). If vec0 exists but fails to load, the result is `method=embed` with 0 candidates and **no keyword fallback**.
- The keyword path is O(n²) with mktemp, sort and comm per pair: at the 1400-row cap that is about 1M pairs and hours of runtime.
- KNN uses k=6 and filters by agent *after* the KNN, so same-agent neighbours crowd out cross-agent ones (SPEC-011:119 says k=5).
- Resolvers archive and log in two separate non-transactional calls (:395-400, 427-435).
- `resolve-merge W W` archives the merged winner, and nothing checks that the ids exist or are unarchived.
- The deep-audit `printf '/council "%s vs %s"'` doesn't escape the claims.

### Cross-cutting findings
- **SQL interpolation:** `'`→`''` escaping is applied consistently for content, query, URL and model strings. The real sinks are elsewhere:
  - unquoted numeric or identifier values taken from parsed text (reconcile `mid`: P0);
  - unescaped `<PLACEHOLDER>` substitutions in memory-recall and memory-store;
  - `DIMS` in download-extensions;
  - multi-statement sqlite3 calls without `.bail on`, so injected statements after a syntax error still run.
- **Concurrency:** WAL plus shared `$MROOT/.claude/memory/memory.db` is right. busy_timeout coverage is inconsistent:
  - Missing in embed-one (all writes), migrate.sh read (silent skip), migrate-md (per-row sqlite3 and the DROP path), download-extensions, cortex-load, memory-recall, memory-store Step 5.5, and export.
  - Correct (`-cmd .timeout`) in protocol.md, import-seed-pack and reconcile-lib.
  - On WAL-hostile filesystems the fallback to DELETE journaling makes the missing timeouts much worse.
- **Tier eclipse:** the "tier-0 only if no distilled rows" rule (SPEC-006:20, protocol.md, cortex-load, AGENTS.md) drops every lesson written after the last distill, and after any seed import. This is the biggest silent memory-loss issue in the design.
- **Spec drift:**
  - SPEC-004 single transaction (migrate-v2), busy_timeout on every write (embed-one), read-back (protocol.md).
  - SPEC-024 M2 username/high-entropy checks missing; M10 caps exceeded; validation checkboxes :89-91 unchecked although tests exist.
  - SPEC-011 score thresholds unreachable; "cosine ≥0.55" and k=5 vs the implementation's L2 and k=6.
  - SPEC-037 M1 gitignore.
  - SPEC-006 "cosine distance".
  - AGENTS.md's session-start snippet checks `$MEMDB` in `USE_DB` before `MROOT`/`MEMDB` are assigned, and selects `content` rather than `type, content`.
- **Portability:** `flock` (write-model), `sha256sum` only (seed-common), `sleep 0.2`, unquoted `.load` paths break on paths with spaces (common on macOS), and project names with spaces break seed trailers. No hard-coded `/tmp` found; everything uses `${TMPDIR:-/tmp}` or `mktemp`.
- **Native code and supply chain:** the downloader verifies hashes, but consumers (embed-one, memory-recall, reconcile, migrate-md) `.load` whatever sits in `.claude/memory/extensions/` without re-checking.
- **Tests:** 9 of the 11 test scripts in this slice aren't in CI. The sqlite3-missing behaviour is inconsistent (skip with exit 0, crash with 127, or fail). Several tests encode the bugs above (T15).

### Enhancement proposals
| # | Title | Rationale | Concrete change | Effort | Pri |
|---|---|---|---|---|---|
| 1 | Close the reconcile SQL injection | Memory content can delete the DB (reproduced) | Export candidates with Python `sqlite3` and parameterized KNN, or JSONL instead of TSV. Validate `mid` against `^[0-9]+$`. Add `.bail on` to every heredoc SQL block. Add a regression test with multi-line and injection content. | S | P0 |
| 2 | Fix the memory-recall `\ # comment` continuation | Remote semantic search is always misrouted | Move `# lint-ok` to its own line. Add a skill-lint rule for `\\[[:space:]]+#`. Fix review-and-commit:207 and council.md:1042 too. | S | P0 |
| 3 | Rescale validation composite scoring | Auto-archive and reviewer thresholds can't be reached | Normalize `raw_score` to 0-100 (e.g. `SUM(pts)/(40*n)*95`) or retune thresholds to 0-45. Fix SPEC-011 and memory.md together, and add a numeric test. | S | P0 |
| 4 | Fix the tier-0 eclipse | Post-distill lessons and pre-import memories vanish from session start | Always load tier-0 rows with `created_at >` the newest digest time (or last N tier-0 rows) alongside tier 1/2. Update SPEC-006 and protocol.md, then re-sync includes. | M | P1 |
| 5 | Stop lossy deletion in migrate-md | Headers, `###` lines and text past 8000 chars are lost before the source is deleted | Keep header lines. Split oversized sections instead of truncating. Count truncation as "skipped" so the source is kept. Guard the `DROP TABLE` with an explicit load check plus timeout, and delete matching `embedding_meta`. Add a test. | M | P1 |
| 6 | Harden seed-pack import trust | Untrusted repo content becomes trusted digest-tier context | Import as tier 0 (or a flag) until validated. Show the import diff and ask the user to confirm in `/setup team`. Frame seed rows as "imported — untrusted" at load. Screen for instruction-like patterns. Optionally verify the commit signer or author of `.claude/memory/seed/`. | M | P1 |
| 7 | Consistent busy timeout | Silent embedding loss and migration skips under concurrency | Swap every `sqlite3 "$MEMDB"` in the slice for `sqlite3 -cmd ".timeout 5000"`. Fix memory-store SKILL.md :161 to recommend `-cmd` instead of the PRAGMA. Add a lint rule: sqlite3 on `$MEMDB` without `.timeout`. | S | P1 |
| 8 | Reconcile fallback and performance | Embed path silently yields 0 candidates; keyword path is O(n²) with process spawns | Return non-zero when the `.load`/KNN fails so keyword runs. Do Jaccard in one Python pass with an inverted index. Use k=5 plus a larger k before filtering. Wrap resolve UPDATE and log in one transaction; reject winner==loser. | M | P1 |
| 9 | Portable locking in write-model | `/setup models` is broken on macOS | Fall back to a `mkdir`-lock or Python `fcntl` when `flock` is absent. Put `*.lock` in a gitignored path, and make `/setup models` add `.claude/dev-team/models.local.json*` to the user's `.gitignore` (SPEC-037 M1). | S | P1 |
| 10 | Wire the slice tests into CI and make sqlite3 skips uniform | 9 test scripts never run | Add smoke.yml jobs for test-migrate, test-reconcile, metrics/test, the 5 model-map tests and webhook-test. Make every sqlite-dependent test skip with exit 77 or fail consistently. Make metrics test 4 root-safe (skip when `id -u`=0, or use a read-only bind). | S | P1 |
| 11 | Escape the seed trailer project name | A path with a space breaks every import | Slugify `PROJECT_NAME` (`tr -c 'A-Za-z0-9._-' '-'`) in export. Make the import regex tolerant, or keep project in the manifest only. | S | P2 |
| 12 | Enforce the fallback line cap on import | Violates SPEC-024 M10 (83 > 80 verified) | Refuse (or truncate to one line) when `existing + add_lines > limit`; report omissions. Add a real cap test to M10. | S | P2 |
| 13 | Verify extension hashes at `.load` time | A committed `.so` in a hostile repo gives code execution | Record verified hashes in `config` (or a sidecar) at download. embed-one, memory-recall, reconcile and migrate-md check before `.load`. Quote `.load "…"` paths. | M | P2 |
| 14 | Harden curl calls | Hangs, protocol smuggling, secrets in `ps` | embed-one, memory-recall and migrate-md: add `--max-time 30 --fail --proto =https,http`. webhook.sh: pass URL and body via `-K -` / `--data @-` and add `--proto =https`. Trap-remove the key file. | S | P2 |
| 15 | Correct the distance metric | Scores and thresholds assume cosine but vec0 defaults to L2 | Create vec tables with `distance_metric=cosine` (new tables, plus a migration note) or convert L2 to cosine. Fix the SPEC-006/011 wording. | M | P2 |
| 16 | Fix memory-recall Step 5 ordering and `grep -F` | Grep fallback runs with a DB present; regex/shell risk | Resolve MROOT first, use `grep -Fil -- "$QUERY"`, include `WTROOT` context.md. Define EXT_DIR/MODEL_DIR inside each fence. | S | P2 |
| 17 | Make migrate-v2 fully atomic and add a pre-migration backup | SPEC-004 drift; rebuild risk | Move `distillation_log`, config and version into the transaction. `migrate.sh` runs `VACUUM INTO memory.db.bak-v$V` before the first step; add `-cmd .timeout` to `read_version` and treat a read error as a failure, not a skip. | S | P2 |
| 18 | Randomize prompt data delimiters | `<<<END_BATCH>>>` inside content can close the data block | Use per-run nonce delimiters, or strip or escape the sentinels from content before substitution. | S | P2 |
| 19 | Domain-glossary worktree-aware load | Worktree sessions read a stale glossary | Load `WTROOT/CONTEXT.md` first, then fall back to `MROOT`. | S | P3 |
| 20 | Doc cleanups | Misleading guidance | memory-store :236 heredoc claim, the `/memory-distill` name, the nonexistent "UPDATE protocol", the model-map "gitignored" claim, embed-one lookup via `plugin-dir.sh` instead of cwd; tick the SPEC-024 :89-91 boxes. | S | P3 |
| 21 | Validate numeric fields in emit-outcome | Garbage lands in numeric ledger fields | Check `^[0-9]+$\|null` and exit 64 on violation. rollup: count malformed task files per file. | S | P3 |

Repro scripts and databases are in `reviewer scratch space (not committed)/` (`rc/` for the injection, `c1.sh` for the continuation bug, `proj/` for the seed-pack checks).
