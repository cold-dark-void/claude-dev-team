## Slice: handoff / transcript / retro

I only read and ran things; nothing was edited or committed. Tests wrote to a scratch TMPDIR. Run as root on Linux with jq 1.7 and python 3.11.

### Test results
33 test scripts: **28 pass, 5 fail**. Of the 5, only one is a real product failure; the other four come from the environment or from the tests themselves.

| Script | Result | Cause |
|---|---|---|
| handoff/detached-stub-test.sh | **FAIL 41/1** | **Real drift.** `commands/handoff.md` is 12096 B; the test caps it at 12000 B (`detached-stub-test.sh:18,112`). |
| retro-gate/scheduled-retro-test.sh | FAIL 10/1 | **Brittle test.** Its grep `command-name.*/[a-z:-]*retro` (line 47) does not match the regex text that is actually in `commands/retro.md:575`. Filter-2 is present; use `grep -F '<command-name>/[a-z:-]*retro'`. |
| retro-gate/friction-capture-test.sh | FAIL (exit 1) | **Environment.** Needs `.claude/hooks/friction-capture.sh`, which only `/setup` generates (line 15). It should SKIP the way precompact-test does, or pull the heredoc out of init-orchestration SKILL.md. |
| transcript-mirror/test.sh | FAIL 224/3 | **Root artifact.** The M4 "append fail" cases rely on `chmod a-w main.md`, and root ignores that (`test.sh:303`). The test needs a `[ "$(id -u)" = 0 ] && skip` guard. |
| handoff/precompact-test.sh | 26 pass / 3 skip | The installed hooks are absent (T11b–T14). |
| The other 28 | PASS | Includes assemble 61, assemble-quality 52, mirror-spine 86, finalize 39, discover-warm 32, compact-transcript 93, summarize-transcript 117, transcript-sync 35, retro-gate test 27, hosts 28+23, discover-host 10, and so on. |

The tests also leak temp files into TMPDIR: 6× `handoff-grok-adapt.*.jsonl`, `grok-norm-*.jsonl` and `grok-norm.err`.

### Measured bugs, reproduced here
- **B1 (P0): the mirror recorder rescans the whole transcript on every Stop.** `transcript-mirror.sh:601` calls `index_idents`, which forks one `jq` per line (a second jq plus sha256sum for lines with no uuid, `:35-61`). This runs on every tick, even when only one line was appended.
  - A synthetic 3000-line transcript took **14.1 s per Stop**; one appended line still took 14.3 s.
  - The documented hook `timeout` is 10 s (SKILL.md:47, SPEC-036 M3). Under `timeout 10` the run exits 124, the cursor stays at the old id, the new record is never mirrored, and `tmirror.*` is leaked.
  - So any session over about 2000 lines stops mirroring for good; only the manual `transcript-sync` catches up.
  - SPEC-036 M6 says "Incremental: find the cursor identity… process records after it" and the SHOULD at line 733 expects to stay under 10 s. The code does not meet either.
- **B2 (P1): a killed rebuild can lose data.** The rebuild moves things aside in steps (`:652-686`): `agents/` and `verbatim/` go to sibling stashes, then `mv "$DIR" "$BAK"` (`:668`), then `mv NEW DIR`.
  - There is no TERM trap. If the hook timeout kills the process mid-swap, the live sid dir can be missing, `<sid>.agents.<pid>` and `.verbatim.<pid>` are orphaned, and the WORK temp dir leaks.
  - SPEC-036 M6 calls "drops agents/" a spec fail. Rebuild is exactly the slow path, so this is the likely place to be killed.
- **B3 (P1): the Claude project-dir encoding differs across 5 places.** Claude Code turns every non-alphanumeric character into `-`. `retro-gate/hint.sh:33` and `resolve-root.sh:148` do this correctly.
  - These only replace `/`: `transcript-parse/hosts.py:78`, `handoff/discover-warm.sh:409`, `retro-gate/trial-review.sh:207`, `commands/retro.md:230`.
  - Result: any cwd containing `.`, `_` or a space (e.g. `~/john.doe/my_app`) gets no newest-session locate for retro auto-detect, warm handoff step 6, transcript-sync `cwd_sessions`, or trial-review.
  - The tests (`discover-host-test.sh:27`, `discover-warm-test.sh:189`) repeat the same wrong encoding, so they cannot catch it.
- **B4 (P1): the scheduled-report writer can loop forever.** In `write-scheduled-report.sh:41-60`, a flag given with no value (e.g. `--mroot` as the last argument) makes `shift 2` fail without shifting, so the loop never ends. Confirmed: `timeout 3` gave rc=124.
  - The same pattern appears in `trial-meta.sh:80-83,137-140` and `trial-review.sh:61-73`.
- **B5 (P1): `transcript-parse/assemble.py:235` crashes on a non-hashable uuid.** A line like `{"uuid":{"x":1}}` raises `TypeError: unhashable type: 'dict'`, which kills assemble and therefore every cold, warm and PreCompact handoff. The message-line filter should require `isinstance(u, str)`.
- **B6 (P2): handoff `assemble.py` crashes on `"order": Infinity`.** In `validate_event`, `int(float('inf'))` raises OverflowError, which is not caught (only TypeError/ValueError are); verified crash. NaN is accepted, which corrupts the sort.
- **B7 (P1): the scheduled-retro lock does not exclude concurrent runs.** `scheduled-lock.sh:35-60` checks, then writes with `mv -f`. Two runs starting together both get the lock. `release` (`:68`) also deletes a lock owned by another pid. Use `mkdir`/`noclobber` (O_EXCL) and compare the pid on release.
- **B8 (P2): Grok temp files are not portable to macOS and are never cleaned up.** `discover-warm.sh:372,376` uses `mktemp …XXXXXX.jsonl`. BSD mktemp only randomizes trailing Xs, so on macOS the name is literal and the second concurrent or later run fails. Nothing deletes the adapted transcript copy (verified leak); the same is true of `grok_normalize` output on the retro path.
- **B9 (P2): `compact-transcript.py:153` `bound_tail` is O(n²).** It re-joins and re-encodes `blocks[i:]` on every iteration: 1.57 s on a 6 MB main.md, growing quadratically after that.

### Per-file review
| File | Purpose | Verdict | Findings |
|---|---|---|---|
| handoff/SKILL.md | Spine-mine protocol | Minor drift | Line 119 calls `load_merged_for_summary(dir, prior=…)`, but the signature is `prior_path=` (`assemble.py:456`), so the call as written raises TypeError; line 610 is correct. 984 lines is heavy for an agent to read. |
| handoff/LIGHT.md | --light profile | OK | No frontmatter; acceptable because it is a sub-document, not a Surface. |
| handoff/assemble.py | Events → STM packet | OK with bugs | B6. `load_events` (`:274`) does not catch OSError on an unreadable miner file (traceback). The packet write (`:1230`) is not atomic. |
| handoff/prepass.sh | prepare / cache-check / finalize | Works; performance and hygiene issues | (a) A cold prepare runs the full `locate` scan of every transcript in `~/.claude/projects` up to 3 times: bash `assemble.py locate` (`:1070`), python `assemble <uuid>` (which locates again, `:1210`), and M3f `transcript-sync --check --sid`, whose `hosts.locate` → `assemble.locate` plus `last_ident` reads the whole file again. `compute_leaf` in finalize and cache-check without `--leaf` is a fourth. Fix: once located, pass `assemble-file $CANONICAL` everywhere. (b) Memory: `records` (`:1305`) holds every parsed message; only the top-level `toolUseResult` is stripped, and the `tool_result` content blocks stay, so large transcripts cost hundreds of MB. (c) The PDH stanza at `:1102` has a dead tier (`_pr='${CLAUDE_PLUGIN_ROOT}'`, a literal string in a .sh file) and prefers the cwd's `skills/plugin-dir.sh`, which can run a different dev-team checkout's mirror scripts; `$SCRIPT_DIR/..` is always known. (d) `--help | grep` soft-detection of `--events-out/--prior-events/--light` (`:709-727`) is dead now that assemble ships these flags, and costs 3 extra python starts. (e) No EXIT trap: `handoff-git.*`, `events-out` and `events-built` temp files leak on `set -e` aborts. (f) `int(HANDOFF_SPINE_TOKENS)` gives a traceback on bad input. (g) The default `--out plan.json` writes spine and chunks into the caller's cwd. (h) `_mirror_check_ok` subprocess has no timeout. |
| handoff/precompact-capture.sh | PreCompact rescue engine | Mostly good (fail-open holds) | Always exits 0, stdin read is bounded, writes are atomic. But: `timeout` is only applied if the binary exists (`:90`), and stock macOS has none, so it is unbounded there; the settings entry has no `timeout` (init-orchestration SKILL.md:387-392), so the 60 s default applies. `timeout` does not kill prepass's python grandchildren. The retention `sort -r` (`:165`) is lexicographic and breaks after seq 999. The header claims "gitignored" (`:17`), but nothing adds `.claude/handoff/` to the user project's .gitignore (setup.md adds only memory paths), so rescue spines can be committed. The `.tmp` file is left behind on a render exception. No test covers the timeout path. |
| handoff/discover-warm.sh | Warm session id + transcript | Works; drift | B3 at `:409`; B8. It has no `.cwd`-marker fallback for Grok buckets, although hosts.py (SPEC-036 M5a) does. A stale `.live-session.json` bridge (step 4) is preferred over cwd-newest and has no `updated_at` freshness check. Session id and transcript path can come from different env vars (CLAUDE_CODE_SESSION_ID vs a CLAUDE_TRANSCRIPT_PATH with another stem). |
| handoff/resolve-root.sh | Target MROOT/HANDOFF_DIR | Good | Correct non-alphanumeric decode. `open()` has no `encoding=` (`:121`). |
| handoff/packet_dedup.py, packet_quality.py | Dedup / invent-guard | Good | Pairwise O(n²) re-normalization; fine at event scale. |
| handoff/leafrule.py | M8 leaf rule | Good | — |
| handoff/grok-to-claude-jsonl.py | CDT-92 wrapper | Good | Thin shim over grok_normalize. |
| handoff/*-test.sh (19) | Tests | Good except detached-stub | Leak Grok adapter temps. |
| transcript-parse/assemble.py | locate / assemble | Bug + performance | B5. `locate` fully JSON-parses every line of every project JSONL; a pre-filter (`if target in line`) would cut that heavily. `by_uuid` keeps every raw line, contrary to the "never read whole" docstring. `open()` has no `encoding="utf-8"` (`:118,181`) while parselib forces UTF-8, so behavior depends on the locale. BrokenPipe traceback when the consumer closes early. |
| transcript-parse/parselib.py | Primitives | OK | `iter_lines`, `sidechain_is_signal` and `is_tool_result` have no production consumer (dead public API; gate mentions iter_lines only in a comment). |
| transcript-parse/hosts.py | Host locate/normalize | Bug | B3 at `:78`. `_claude_locate` monkey-patches `assemble.PROJECTS_DIR` (`:201-208`), which is not thread-safe. |
| transcript-parse/grok_normalize.py | Grok → Claude JSONL | Drift | Reads only flat `tc.name/arguments`; the mirror jq also accepts `.function.name` (OpenAI shape), so the two drift. Synthetic 2026-01-01 timestamps mixed with real ones reorder under assemble's timestamp sort. `sanitize_session_id` keeps `..`. The unsanitized `sessionId` is written into JSON. |
| transcript-parse/freshness.sh | 60 s guard | Good | A future mtime (clock skew) gives a negative age and a permanent exit 9. |
| transcript-parse/discover-host.sh | Retro host detect | Minor bugs | `:213-214`: under `set -euo pipefail`, if both `stat` calls fail the script aborts before the `${CMTIME:-0}` fallback. `cmd+=($(…_args))` (`:112,115`) word-splits paths with spaces. `path=` in the key=value output is ambiguous when the path has spaces. |
| transcript-parse/SKILL.md | Docs | OK | Documents unused API as public. |
| transcript-mirror/transcript-mirror.sh | Stop/SessionEnd recorder | **Broken at scale** | B1, B2. Hook stdin `STDIN=$(cat)` is unbounded (`:517`). `jq … "$TP" \| head -1` for PARENT (`:588`) fails on a malformed line under pipefail. `sha256sum` has no `shasum -a 256` fallback (macOS); `date -Is` and `base64 -d` are GNU-leaning. Files are written 0644 and dirs 0755, and no umask is set; verified. That stores thinking, tool I/O and injected system text readable by other local users. No lock against concurrent Stop / SessionEnd / SubagentStop / summarize-transcript. |
| transcript-mirror/hook-shim.sh | Hook shim | Fail-open OK | The `pwd` tier (`:17`) runs `skills/…/transcript-mirror.sh` from the current cwd. If the session has cd'd into an untrusted repo that contains `skills/plugin-dir.sh`, a Stop hook runs that repo's code; it should use `$CLAUDE_PROJECT_DIR` and the cache only. Only `bash -n` checked (`test.sh:173`); no behavioral test. |
| transcript-mirror/transcript-sync.py/.sh | Catch-up / `--check` | OK | `record_ident` duplicates the jq identity rule (`:104-120`); jq 1.6 vs Python float and bigint formatting can disagree on `h:` idents, giving a false "lag". A list-typed JSONL line raises AttributeError, and the whole `lag_status` for that sid is lost. Wrapper PDH has the same cwd-tier concern. |
| transcript-mirror/compact-transcript.py/.sh | Meaning tail | OK | B9. The atomic write is good. |
| transcript-mirror/summarize-transcript.py/.sh | M15 overlay | Works; fragile | Overlays are keyed by ordinal turn (`T%06d`), and heading detection is regex `^## (user\|assistant)$`. User or assistant text containing such a line, or any rebuild that changes the block count, makes reapply land a summary on the wrong turn. No lock against the recorder. |
| transcript-mirror/reapply-overlay.sh | Rebuild apply | OK | Same ordinal fragility. Sound mktemp-in-dir + `mv -f`. |
| transcript-mirror/strip_main.py | Shared strip | Good | Also drops user-authored lines that start with `> @`. |
| transcript-mirror/SKILL.md | Docs | Drift | Promises a 10 s-safe Stop hook; B1 contradicts that. |
| retro-gate/gate.sh | S1–S5 scoring | Works | Reads the raw file, not the assembled timeline, so a forked child re-scores the copied parent prefix (double counting). SPEC-012:51 says consumers must use the shared assemble. A non-numeric `RETRO_THRESHOLD` gives a traceback at `:73` and invalid JSON in the early exits (`:28-47`). |
| retro-gate/hint.sh | Non-blocking hint | Good | The only correct encoder. `ls -t` glob. |
| retro-gate/trial-meta.sh | Trial metadata | Minor | Unquoted `printf '%s\n' $body` (`:30`) glob-expands tokens against the cwd; B4. `date -d` / `-j -f` fallback is fine. |
| retro-gate/trial-review.sh | Trial review | Minor | B3 at `:207`; B4. |
| retro-gate/scheduled-lock.sh | Scheduled lock | Bug | B7. The test (scheduled-lock-test.sh) never runs two acquirers at once. |
| retro-gate/write-scheduled-report.sh | Report + webhook | Bug | B4. The webhook JSON (~`:190`) interpolates `$REPORT` without escaping and the counts are unvalidated (`--applied-count x` produces invalid JSON). Retention uses `ls -t`. |
| retro-gate/SKILL.md | Docs | Consistent with gate.sh tunables | — |
| retro-subagent/SKILL.md | Phase-2 prompt contract | Good | Has an untrusted-data clause and target validation. |

### Cross-cutting findings
1. **The same parsing logic is implemented many times:**
   - Project-dir encoding: 6 copies, 4 wrong (B3).
   - Grok bucket (urlencode + `.cwd`): hosts.py, transcript-mirror.sh:411, discover-warm.sh (missing `.cwd`).
   - Grok → Claude mapping: grok_normalize.py vs the mirror's jq `JQ_COMMON`.
   - Record identity: jq `ident_line` vs `transcript-sync.record_ident`.
   - Turn-block splitting: compact-transcript.py, summarize-transcript.py, reapply awk, emit_tick.
   - `--check` `sid=/status=` parsing: prepass.sh:1440, compact-transcript.py:111, summarize-transcript.py:119.
   - Newest-mtime locate: hosts.py, discover-warm, hint.sh, trial-review, retro.md.
   - Stderr-drain Popen threads: duplicated in prepass `compute_leaf` and prepare.
   - The PDH stanza is copied into 5 scripts that already know `$SCRIPT_DIR`.
2. **Privacy:** no `umask 077` anywhere in the slice (grep: 0 hits). `~/.claude/transcript/**` and `$MROOT/.claude/{handoff,retro}` are world-readable. `.claude/handoff/` and `.claude/retro/` are not gitignored in user projects. The spine and mirror keep first lines of Bash commands and full `tool_use` inputs (tokens, `Authorization:` headers) with no redaction. Grok normalized copies leak in TMPDIR.
3. **Hook safety:**
   - precompact-capture: correct (exit 0, bounded stdin, soft timeout).
   - hook-shim and recorder: fail-open exit 0 is correct, but runtime is unbounded and gets killed at 10 s (B1/B2).
   - Neither hook has a timeout fallback for macOS (no `timeout` or `gtimeout` check).
4. **Where code and spec disagree:**
   - SPEC-036 M6 "incremental" / SHOULD ≤10 s (B1).
   - SPEC-036 M6 "parent rebuild MUST preserve agents/" is not robust to kill (B2).
   - SPEC-012:51 "single parse seam": gate has no fork dedup; the recorder has its own jq parser.
   - SPEC-036 M5a `.cwd` fallback is missing from discover-warm.
   - `commands/handoff.md` exceeds the size cap.
   - The "gitignored" claim in precompact-capture.sh:17.
5. **Untested paths:** hook-shim behavior, precompact timeout, concurrent lock, recorder under hook timeout or large N, non-string uuid, B4 argument parsing, wrong encoding for dotted paths (the tests encode it wrong too).

### Enhancement proposals
| # | Title | Rationale | Concrete change | Effort | Priority |
|---|---|---|---|---|---|
| 1 | Make the mirror truly incremental | B1: 14 s/tick at 3k lines; the 10 s timeout means it silently never updates | Store the byte offset as cursor field 4. On a tick, `tail -c +off`, confirm the identity of the line just before the offset, and fall back to a full rebuild only on mismatch. Replace the per-line jq with one `jq -R` pass (or a python helper shared with transcript-sync) that emits idents for the whole file. | M | P0 |
| 2 | Crash-safe rebuild | B2: data loss under timeout kill | Build NEW fully, keep agents/verbatim in place and hard-link or copy them into NEW, then a single `mv -T`/rename swap. Add `trap … TERM INT`. On startup, recover orphaned `<sid>.{bak,agents,verbatim}.*`. | M | P1 |
| 3 | One project-dir encoder | B3 | Add `hosts.claude_encode_cwd` using `re.sub('[^A-Za-z0-9]','-',abs)` plus a CLI `hosts.py encode-cwd`. Replace the sed in discover-warm, trial-review and retro.md; fix the two tests. | S | P1 |
| 4 | Harden transcript-parse assemble | B5 plus 3–4 full-disk scans per cold handoff | Require `isinstance(u,str)`; `encoding="utf-8"`; substring pre-filter in `locate`; prepass passes `assemble-file $CANONICAL` to `compute_leaf` and assemble, and M3f passes `--transcript`. | S | P1 |
| 5 | Safe argument parsing | B4 infinite loops | `[ $# -ge 2 ] \|\| usage` before every `shift 2` (the prepass pattern), in write-scheduled-report, trial-meta and trial-review. | S | P1 |
| 6 | Atomic scheduled lock | B7 | `mkdir "$LOCK.d"` or `set -C` for O_EXCL; steal a stale lock via rename; `release` checks the pid. | S | P1 |
| 7 | Privacy baseline | World-readable transcripts; handoff/retro files committable | `umask 077` in the recorder, precompact-capture, prepass finalize and friction-capture. Have `/setup orchestration` add `.claude/handoff/` and `.claude/retro/` to .gitignore. A small `redact()` (Bearer, `sk-…`, `AKIA…`, `password=`) in `digest_input` and the mirror call sidecar. | M | P1 |
| 8 | Remove the cwd tier from hook and script PDH | A Stop hook can run a repo's scripts after cd | In the hook-shim and precompact wrapper, resolve from `$CLAUDE_PROJECT_DIR`, then the cache. In skills/*.sh, use `$SCRIPT_DIR/..`. Delete the dead `'${CLAUDE_PLUGIN_ROOT}'` tier in the .sh copies. | S | P1 |
| 9 | Fix and de-flake tests | 4 non-product failures | scheduled-retro-test: `grep -F`. friction-capture-test: SKIP when absent, or extract from SKILL.md. transcript-mirror M4: skip as root. Trim `commands/handoff.md` below 12000 B. Clean up TMPDIR artifacts. | S | P1 |
| 10 | macOS portability | mktemp suffix, sha256sum, timeout | `mktemp -d` then a fixed name inside; a `sha256()` helper with `shasum -a 256` fallback; `_timeout()` trying `timeout`/`gtimeout` and otherwise running unbounded with a warning. | S | P2 |
| 11 | Stable overlay keys | Ordinal T-ids go to the wrong turn after heading-like text or a rebuild | Key verbatim by source line `L<n>` (already in the refs); escape body lines matching `^## (user\|assistant)$` in emit_tick. | M | P2 |
| 12 | Mirror concurrency lock | Stop / SessionEnd / SubagentStop / summarize races | Per-sid `mkdir` lock with a short wait-or-skip, since hooks must stay fail-open. | S | P2 |
| 13 | Shared `mirror_check()` and turn-split helpers | Parsing implemented 3 times | Add `transcript-mirror/mirrorlib.py` (check-line parse, block split, `record_ident`) used by prepass, compact, summarize and sync. | M | P2 |
| 14 | Gate uses the assembled timeline | Double-counts fork prefixes; SPEC-012:51 | `gate.sh` reads `assemble.py assemble-file` output (dedup) when the file has `forkedFrom`. | M | P2 |
| 15 | Linear `bound_tail` | B9 | Precompute per-block byte lengths and accumulate from the end. | S | P3 |
| 16 | Validate numeric inputs | Tracebacks and invalid JSON | assemble `order`: catch OverflowError and reject non-finite values; gate/prepass: validate `RETRO_THRESHOLD` and `HANDOFF_SPINE_TOKENS`; webhook body built with python `json.dumps`. | S | P3 |
| 17 | Prune dead code | Maintenance | Drop the `--help`-grep soft-detect in prepass; mark parselib `iter_lines`/`sidechain_is_signal`/`is_tool_result` test-only or remove them; fix SKILL.md:119 kwarg. | S | P3 |
| 18 | Clean up Grok temp files | Transcript copies accumulate in TMPDIR | handoff: put the adapter output in `$WORK_DIR` (already cleaned by the detached flow); retro: add a `trap rm` in `_normalize_feed`. | S | P2 |

