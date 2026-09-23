# Slice 04: transcript review (transcript-mirror + transcript-parse + /compact-transcript)

## Slice summary

- **What it does:** `transcript-parse` is the shared read-only layer that finds and parses host transcripts. It covers Claude `~/.claude/projects/*.jsonl` and Grok `chat_history.jsonl`, and its consumers are `/handoff`, `/retro`, `/audit` and transcript-sync. `transcript-mirror` is an opt-in Stop/SessionEnd/SubagentStop hook recorder. It writes a Meaning-channel `main.md` plus sidecars to `~/.claude/transcript/<sid>/`. It also includes a catch-up CLI (`transcript-sync`), a bounded-tail slash Surface (`/compact-transcript`, M14) and an on-demand overlay CLI (`summarize-transcript`, M15).
- **Overall grade: C.** The code is careful and defensive: fail-open and fail-closed rules are respected, sid and agent_id inputs are sanitised, writes are atomic, and there are about 530 test assertions. Two design-level P1s make the headline features unreliable in real use.
- **Biggest risk 1 (P1), recorder cost:** `transcript-mirror.sh` re-hashes the **whole** transcript on every tick and starts 1–2 `jq` processes per JSONL line. Measured: a 2,000-line transcript takes 9.3 s on first run and **9.8 s for a one-line incremental tick**. 1,000 uuid-less Grok lines take 12.5 s. The documented hook `timeout` is 10 s, so real sessions (thousands of lines) will be killed on every Stop and the "fast path" silently never updates.
- **Biggest risk 2 (P1), bare `/compact-transcript` always misses for the live session:** it resolves the live sid, and the only allowed gate is `transcript-sync --check` returning `status=ok`. The live transcript was just written by the slash-command turn itself, so the check returns `in-progress`, or `lag` once 60 s have passed because the Stop hook has not yet fired for the current turn. The spec (SPEC-036 M14) makes these two requirements contradict each other. No test covers the bare path.
- **Secondary risks:**
  - Mirror files are written with the default umask (0644 files, 0755 dirs). They hold full tool results and thinking, which is a PII/secret exposure on multi-user hosts.
  - None of the 7 test suites in this slice run in CI (`smoke.yml`).
  - Test suites use GNU-only `touch -d`, `find -printf` and `sha256sum`.
  - Install docs tell users to run cwd-relative `bash skills/transcript-mirror/...` and to "copy `skills/transcript-mirror/hook-shim.sh`". Neither works from a user project on a real install, which contradicts the AGENTS.md install-aware rule.
- **Prompt/docs quality:** `docs/commands/transcript-mirror.md` and `skills/transcript-mirror/SKILL.md` duplicate about 150 lines verbatim: the enablement JSON, SubagentStop JSON and the whole M15 section. The command description is jargon-heavy ("Meaning-channel file (Meaning tail)"). `commands/compact-transcript.md` passes `"$@"` instead of `$ARGUMENTS`.
- **Test run evidence:**
  - `test.sh`: PASS=224 FAIL=3. The 3 failures are the M4 append-fail test, which uses `chmod a-w` and cannot fail a write when run as root (uid 0 in this container). This is an environment artifact, not a code bug.
  - All other 6 suites pass: compact 93/0, summarize 117/0, sync 35/0, discover-host 10/0, hosts-grok-locate 23/0, test-hosts 28/0.
  - `bash -n` and `py_compile` are clean on all scripts. All JSON/JSONL fixtures are valid.

## Per-file review

| File | Lines | Purpose (short) | Verdict | Findings |
|---|---|---|---|---|
| commands/compact-transcript.md | 64 | `/compact-transcript` slash Surface; dispatches compact-transcript.sh | Issue | Frontmatter OK (name, description, argument-hint). L51 passes `"$@"`, which is empty in the Bash tool shell, so a positional `<sid>` depends on the LLM substituting it; `$ARGUMENTS` is not referenced (F7). Bare mode is structurally unable to hit on the live session (F2). Steps 1 and 2 duplicate the 1.3 kB PDH stanza, and the .sh resolves PDH a third time (E4). Description is jargon ("Meaning-channel", "Surface") with no user-facing trigger phrase (F16). |
| docs/commands/compact-transcript.md | 52 | User doc for /compact-transcript | Minor | Accurate to the implementation. Does not warn that bare usage on the live session will miss (in-progress/lag) or say to wait or run from another session (F2). |
| docs/commands/transcript-mirror.md | 326 | User doc for recorder, sync, overlay | Issue | L173–186, L200 and L209–212 give cwd-relative `bash skills/transcript-mirror/...` including the **cron line** (L200), which fails in any user project on a real install (F6). L22 "Copy skills/transcript-mirror/hook-shim.sh" does not say where the file lives in an install (F6). About 150 lines duplicate SKILL.md (E1). Cron PATH caveat for `jq`/`python3` missing (F6). No mention of the 10 s timeout vs. transcript size (F1). |
| skills/transcript-mirror/SKILL.md | 301 | Skill protocol for the mirror | Minor | Frontmatter OK. L32, L125, L147 and L175 use the same cwd-relative paths; L178–180 at least mention plugin-dir.sh (F6). L203–301 duplicate docs M15 verbatim (E1). Otherwise consistent with SPEC-036. |
| skills/transcript-mirror/compact-transcript-test.sh | 777 | M14 test suite | Minor | Passes 93/0. No test of **bare** (no-sid) mode or discover-warm (F2/F12). L5 stale "PDH resolves to feat/CDT-215" (F15). GNU-only `touch -d`, `find -printf`, `sha256sum` (F11). `plant_hit`/`write_store`/`store_fingerprint` are copy-pasted into the summarize test (E6). Sets `CLAUDE_PROJECTS_DIR`, which hosts.py ignores; it works only because HOME is also faked. |
| skills/transcript-mirror/compact-transcript.py | 226 | M14 engine: gate, strip, bound, atomic write | Minor | Logic is correct: UTF-8-safe clip, atomic mkstemp+replace, refuses writes inside the sid dir. A `UnicodeDecodeError` on a non-UTF-8 main.md (L200) is not caught, giving a traceback (still exit 1). Meaning lines that begin with `> @` are silently dropped by the strip (F13). |
| skills/transcript-mirror/compact-transcript.sh | 26 | Fail-closed wrapper; PDH then python3 | OK | Correct fail-closed exits. The PDH stanza's `_pr='${CLAUDE_PLUGIN_ROOT}'` tier is a dead literal in a .sh file (harmless, repo-wide pattern). Could self-locate via `$(dirname "$0")` (E4). |
| skills/transcript-mirror/fixtures/claude-uuid.jsonl | 6 | Claude fixture (meta, command wrappers, thinking, tool_use/result) | OK | Valid JSONL; used by test.sh and the compact test. |
| skills/transcript-mirror/fixtures/fork-child.jsonl | 4 | Fork child with `forkedFrom` | OK | Valid; used by AC9. |
| skills/transcript-mirror/fixtures/fork-parent.jsonl | 2 | Fork parent | OK | Valid; used by AC9 and the trailing nest-ref test. |
| skills/transcript-mirror/fixtures/grok-chat_history.jsonl | 6 | Grok fixture (synthetic_reason, reasoning, tool_calls) | OK | Valid; used by AC5/M11. |
| skills/transcript-mirror/fixtures/grok-updates.jsonl | 3 | Grok JSON-RPC updates stream | OK | Valid; used by AC5 sibling rewrite. |
| skills/transcript-mirror/fixtures/never-mirrored.jsonl | 2 | Never-fired-Stop fixture | OK | Valid; used by AC10. |
| skills/transcript-mirror/fixtures/parent-with-task.jsonl | 4 | Parent with Task tool_use spawning worker-1 | OK | Valid; used by AC3/AC7. |
| skills/transcript-mirror/fixtures/rewind-truncate.jsonl | 6 | Rewind/truncate fixture | OK | Valid; used by AC6 and compact case 9. |
| skills/transcript-mirror/fixtures/settings-registered.json | 31 | Opted-in settings fixture | OK | Valid JSON; matches the documented snippet. |
| skills/transcript-mirror/fixtures/subagent-child.jsonl | 2 | SubagentStop child fixture | OK | Valid; used by M4a. No empty or tool-only child fixture, so the documented "signal ratio" is 1.00 by construction (F12). |
| skills/transcript-mirror/hook-shim.sh | 54 | Project-installed hook; finds plugin, execs recorder | Minor | Always exits 0 and drains stdin. Only 2 PDH tiers (cwd, cache): a `--plugin-dir`/marketplace-clone dev install that is not in the cache silently skips (L16–38). Runs `find ~/.claude/plugins/cache` on every Stop tick (cost is small). No test exercises the cache-resolution branch. |
| skills/transcript-mirror/reapply-overlay.sh | 151 | M15 rebuild: re-applies `.sum` overlays | Minor | Correct and idempotent (tested T2.4). Ordinals come from `^## (user\|assistant)$` lines, which unescaped Meaning text (or a summarizer's output) can contain, so the turn split can shift (F13). Uses mktemp under `${TMPDIR:-/tmp}` correctly. |
| skills/transcript-mirror/strip_main.py | 24 | Shared strip helper (SPEC-018 M3f / M14) | OK | Single source, also used by skills/handoff/prepass.sh. Drops any Meaning line starting `> @` (F13). |
| skills/transcript-mirror/summarize-transcript-test.sh | 1096 | M15 test suite | Minor | Passes 117/0. Stale comments at L4 ("feat/CDT-214"), L6 ("RED until T3") and L844 ("until T4 wires rebuild") (F15). GNU-only helpers (F11). Its `last_ident` (L82, jq uuid-only) differs from the compact test's python version, so identical helpers have drifted (E6). |
| skills/transcript-mirror/summarize-transcript.py | 358 | M15 overlay/restore CLI | Minor | Solid: safe shlex seam with no shell, atomic writes, size gate. Summaries are not sanitised: a summary line matching `^## (user\|assistant)$` or `^>\s*@` shifts turn ordinals and ref parsing, so later runs can reuse or overwrite a `T######` id (F13). There is no lock against a concurrent recorder tick: `mv` over main.md can drop an in-flight append (F14, unverified race). |
| skills/transcript-mirror/summarize-transcript.sh | 26 | Fail-closed wrapper | OK | Same shape as compact-transcript.sh (E4). |
| skills/transcript-mirror/test.sh | 1319 | Main M1–M11 + M4a + M5a harness; runs the M14/M15 suites | Issue | 224/3. The M4 append-fail case (L297–325) uses `chmod a-w`, which does not stop root, so it fails whenever the suite runs as root, including in CI containers. It should skip when uid is 0 or use a read-only mount/dir trick (F10). GNU-only `touch -d`, `find -printf`, `sha256sum` (F11). No perf/size test (F1), no concurrency test, and no escaping test for content containing `## user` or `> @` (F12/F13). Not wired into CI (F9). |
| skills/transcript-mirror/transcript-mirror.sh | 724 | The recorder (hook plus manual CLI) | Major | **F1:** `index_idents` (L54–60) forks jq per line and runs on the full file every tick (L601, plus a parent index at L467), so it is O(N) processes per tick and times out the 10 s hook for about 2k+ lines. **F4:** creates the store with the default umask; tool_result/thinking are written with mode 0644. **F5:** no lock against concurrent Stop, SessionEnd, sync or summarize runs. A kill mid-rebuild (L668–683) leaves `<sid>.bak.PID`/`.agents.PID` dirs that sync then treats as sids. **F8:** `--sid .` passes validation (L565–566) and mirrors into the store root (reproduced). `--transcript` must be argv[1] or the script silently no-ops (L492). Uses `sha256sum` with no `shasum -a 256` fallback (F11). |
| skills/transcript-mirror/transcript-sync-test.sh | 729 | transcript-sync suite | Minor | Passes 35/0. Several assertions grep the implementation source (L≈540–560 `grep -q 'grok_cwd_bucket('`, `parse_known_args`), which is brittle (E6). The identity parity test covers unicode but not DEL, floats or big numbers (F17). GNU-only helpers. |
| skills/transcript-mirror/transcript-sync.py | 390 | Catch-up plus `--check` lag report | Issue | `existing_sids` (L149–163) accepts leftover `<sid>.bak.PID` crash dirs as sids, and their cursor source still resolves, so a phantom mirror gets refreshed (F5). No-args mode refreshes **every** sid in the store from every opted-in project's cron, which is N-fold duplicated work multiplied by F1's per-line cost (F1). Identity parity with bash is `json.dumps(ensure_ascii=False)` vs `jq -S -c`, which differ on `\u007f` (verified) and on floats with jq 1.6 (F17). |
| skills/transcript-mirror/transcript-sync.sh | 27 | Fail-open wrapper | OK | Correct fail-open. |
| skills/transcript-parse/SKILL.md | 360 | Parsing layer reference | Minor | Frontmatter OK. L286 says "POSIX sh", but freshness.sh is bash. L299–302 say the carve-out is "EXCLUSIVELY" precompact-capture, while freshness.sh L14–18 also lists warm bare /handoff (contradiction, F18). The consumer list omits transcript-sync, /audit and the mirror. L234/257 say `set[str]` but the code is a frozenset. L259 omits the `path` key. Very long (about 4.5k tokens) for an auto-invocable skill (E2). |
| skills/transcript-parse/assemble.py | 314 | Claude locate plus fork-assembly | Minor | `locate(uuid)` json-parses every line of every transcript under ~/.claude/projects on each call (L75–163). transcript-sync `--check --sid`, and therefore every compact/summarize, pays a full-corpus scan (F3). Docstring L36 "We never read the whole file" is misleading; the code streams, but still reads every byte of every file. `open(...)` has no `encoding=` (L118, L181), so it depends on the locale. |
| skills/transcript-parse/discover-host-test.sh | 209 | discover-host suite | OK | Passes 10/0. GNU `touch -d`. |
| skills/transcript-parse/discover-host.sh | 232 | Dual-host auto-detect helper | Minor | **Orphan:** no caller outside its own SKILL.md and test; retro.md inlines the logic (verified by grep) (F19). L112/L115 `cmd+=($(...))` word-splits `CLAUDE_PROJECTS_DIR`/`GROK_SESSIONS_DIR` paths containing spaces. L213–214: under `set -e`, if both `stat` variants fail the script aborts (freshness.sh added `\|\| true` for exactly this). The space-separated `key=value` output breaks on paths with spaces. |
| skills/transcript-parse/fixtures/grok-chat-scoring.jsonl | 14 | Grok scoring fixture | OK | Valid; covers skip types, name map and exit codes. |
| skills/transcript-parse/freshness.sh | 72 | 60 s mid-write guard | OK | Portable stat with a GNU/BSD fallback. Header L14–18 is the correct side of the F18 contradiction. |
| skills/transcript-parse/grok_normalize.py | 459 | Grok to Claude-shaped JSONL | Minor | `is_error_from_content` (L152–168) matches `exit:\s*N` anywhere in the body, so a file read containing "exit: 1" becomes a false S2 error (F20). TMPDIR outputs are never cleaned; mkstemp gives 0600, which is fine for privacy but they accumulate. |
| skills/transcript-parse/hosts-grok-locate-test.sh | 429 | hosts.py Grok locate suite | Minor | Passes 23/0. Under `set -euo pipefail`, the `python3 - <<PY` blocks followed by `if [ $? -eq 0 ]` (L127–141, L187, L262, L354, L397, L426) mean a failed assertion aborts the script with no FAIL line or summary. The `bad` branches are dead code (F21). |
| skills/transcript-parse/hosts.py | 543 | Multi-host locate/normalize | Issue | `dash_encode_cwd` (L75–78) replaces only `/`. Claude Code's project-dir encoding also maps other non-alphanumerics (for example `.`, `_`, spaces) to `-` (unverified against host source, high confidence), so newest-locate and cwd enumeration miss projects whose path contains a dot or underscore (e.g. `~/my.app`, `/Users/j.doe`) (F22). |
| skills/transcript-parse/parselib.py | 329 | Shared parse helpers | Minor | Module-level annotations `frozenset[str]` (L33, L117) and `set[str]` (L244) are evaluated at import (no `from __future__ import annotations`), so Python 3.8 or older raises TypeError (F23). |
| skills/transcript-parse/test-hosts.sh | 213 | Grok adapter umbrella suite | Minor | Passes 28/0. Re-counts the child suite's PASS lines as its own `locate-suite[i]` passes, which inflates totals. Referenced by nothing, not even the SKILL.md verify line (F9/F19). |

## Findings

1. **P1: Recorder is O(N) processes per tick and exceeds the documented 10 s hook timeout on realistic sessions.**
   - Location: `skills/transcript-mirror/transcript-mirror.sh:35-60, 601, 467`.
   - Evidence: `index_idents` runs `ident_line` per source line, and each call starts `jq` (uuid) and, for uuid-less lines, `jq -S -c | sha256sum`. It runs over the **entire** file on every tick. Measured on this box:
     - 2,000-line Claude transcript: first run `real 0m9.297s`, then after appending one line `real 0m9.796s`.
     - 1,000-line uuid-less (Grok) file: `real 0m12.488s`.
   - Docs and SKILL.md require `"timeout": 10`. Real sessions reach thousands of lines (SKILL.md cites a 5,542-line transcript), so the Stop "fast path" is killed every turn, and the fast path stops working after about 2k lines without any visible error. transcript-sync (cron) then does the same per-line work for every sid, multiplied by the number of opted-in projects (F-sync).
   - Fix: store the source line number in the cursor. At tick time, verify only that line's ident (one `jq` call) and slice from there. Fall back to a full index only on a mismatch. Alternatively, compute all idents in one pass (`jq -R -c -S 'fromjson? // empty'` once, then one `python3`/`perl` hashing pass, or `jq` with `.uuid // (tojson)` and hash in a single `awk | sha256sum` per changed line only). Add a perf regression test (for example 5k lines with an incremental tick under 2 s).

2. **P1: Bare `/compact-transcript` can essentially never hit on the live session.**
   - Location: `commands/compact-transcript.md` (Arguments table), `compact-transcript.py:185-195`, `transcript-sync.py:301-317`, SPEC-036 M14 (L359–372).
   - Evidence: bare mode uses the live sid (discover-warm line 1), and the only allowed gate is `--check` returning `status=ok`. For the live session:
     - The user's `/compact-transcript` prompt was just appended to the JSONL, so `freshness.sh` exits 9 and the status is `in-progress`.
     - After 60 s the Stop hook has still not run for the current turn, so the cursor is not equal to the last ident and the status is `lag`.
   - Reproduced: after appending one line, `compact-transcript.sh live1` gives rc=1. No test exercises bare mode (`grep -n 'run_ct)' compact-transcript-test.sh` returns nothing).
   - Fix, via a spec amendment:
     - For the bare/live sid, accept `status ∈ {ok, lag, in-progress}` when `main.md` exists. It is a tail of what has been mirrored so far, and the tail can note "mirror as of cursor".
     - Or run the recorder once (`--transcript <live> --sid <sid>`) before checking.
     - Or pass the M14-style `--allow-in-progress` carve-out.
   - Add a bare-mode test using `CLAUDE_CODE_SESSION_ID`.

3. **P2: Locating by sid scans every transcript on the machine.**
   - Location: `skills/transcript-parse/assemble.py:75-163`, reached via `hosts._claude_locate` and then `transcript-sync --check --sid`.
   - Evidence: `_scan_file_for_uuid` json-parses every line of every `*.jsonl` under `~/.claude/projects/*/` to decide "contains". Every `/compact-transcript` and `summarize-transcript` run (through `--check --sid`) pays a full-corpus scan, which can be GBs for heavy users.
   - Fix: fast path first. If `<pdir>/<sid>.jsonl` exists under any project dir (cheap `os.path.isfile` per dir), return it. Fall back to the scan only for fork-descendant resolution. In transcript-sync, prefer the cursor's recorded source (as `source_for_sid` already does for no-args) before `locate_source`.

4. **P2: Mirror data (tool results, thinking, injected context) is written with the default umask.**
   - Location: `skills/transcript-mirror/transcript-mirror.sh` (no `umask`).
   - Evidence: `ls -la` of a fresh store shows `-rw-r--r-- main.md`, `drwxr-xr-x thinking`. Sidecars copy tool output verbatim, including anything read from `.env` or secrets files. There is no redaction (none is specified), so on a multi-user host the data is readable by others.
   - Fix: add `umask 077` at the top of transcript-mirror.sh (and of the sync/summarize/compact entry points). Document that the mirror is as sensitive as `~/.claude/projects` and holds unredacted tool output.

5. **P2: No concurrency control, and crash leftovers become phantom sids.**
   - Location: `transcript-mirror.sh:650-683`, `transcript-sync.py:149-163`.
   - Evidence: the rebuild does `mv DIR DIR.bak.$$`, `mv NEW DIR`, then restores the stashes. A hook timeout kill (see F1) between these steps leaves `<sid>.bak.PID`, `<sid>.agents.PID` or `<sid>.verbatim.PID` in the store root, and `$WORK` in TMPDIR is never cleaned because a RETURN trap does not fire on SIGKILL. `existing_sids()` includes any non-dot directory, so `<sid>.bak.PID` (with a valid cursor) is re-mirrored as a new sid on the next no-args sync. Separately, cron sync, SessionEnd and summarize can run on the same sid concurrently with no lock (unverified race).
   - Fix:
     - Take a per-sid lock: `mkdir "$ROOT/.$SID.lock"` with a stale-age check, or `flock` when present.
     - Name the stash dirs with a leading dot (`.${SID}.bak.$$`) so `existing_sids` skips them.
     - Have sync reject names matching `\.(bak|agents|verbatim)\.[0-9]+$`.
     - Sweep stale stashes on the next tick.

6. **P2: Install/cron docs use cwd-relative plugin paths that do not exist in a user project.**
   - Location: `docs/commands/transcript-mirror.md:22, 173-176, 198-201, 211-212, 309-316`; `skills/transcript-mirror/SKILL.md:32, 125-126, 147, 175`.
   - Evidence: `0 * * * * cd <PROJECT> && bash skills/transcript-mirror/transcript-sync.sh` (docs L200). AGENTS.md says callers "MUST resolve it through plugin-dir.sh … NOT the cwd-relative `bash skills/...` (absent on a real install)". SKILL.md L178–180 adds a caveat; the docs page does not. "Copy `skills/transcript-mirror/hook-shim.sh`" does not tell the user where that file is in the plugin cache. The cron environment usually lacks the Homebrew `jq`/`python3` on PATH, so the recorder only logs "jq missing".
   - Fix: give a copy-paste recipe using `SHIM=$(bash "$PDH/skills/plugin-dir.sh" file skills/transcript-mirror/hook-shim.sh)` and a cron line that calls the resolved absolute `transcript-sync.sh` path with `PATH=/usr/local/bin:/opt/homebrew/bin:$PATH`. Ideally add a `/setup` sub-flag or a helper script that installs the shim, to remove the manual step.

7. **P2: `commands/compact-transcript.md:51` forwards `"$@"`, not `$ARGUMENTS`.**
   - Evidence: `bash "$COMPACT_SH" "$@"`. In the Bash tool shell `$@` is empty, so `/compact-transcript <sid>` depends on the model noticing and substituting the argument. If it does not, it silently uses the live sid, which then misses (F2). The same pattern exists in `commands/audit.md:57` and `commands/doctor.md:86` (outside this slice).
   - Fix: `bash "$COMPACT_SH" $ARGUMENTS`, quoted per repo convention, or an explicit instruction: "pass the user's `<sid>` argument (if any) as the single positional".

8. **P3: `--sid .` passes sid validation.**
   - Location: `transcript-mirror.sh:565-566`.
   - Evidence: the case pattern rejects `*..*` but not `.`. `transcript-mirror.sh --transcript fixtures/claude-uuid.jsonl --sid .` wrote `main.md`, `cursor`, `meta`, `thinking/`… directly into the store root (reproduced).
   - Fix: add `'.'` and leading `.*` to the reject pattern (mirror `sanitize_agent_id`).

9. **P2: None of the slice's 7 suites run in CI.**
   - Location: `.github/workflows/smoke.yml`.
   - Evidence: smoke.yml runs retro-gate, release, memory-store, wrap-ticket, plugin-dir and agent-memory tests only. `grep` finds no reference to `transcript-mirror/test.sh`, `transcript-sync-test.sh`, `test-hosts.sh`, etc. `test-hosts.sh` and `discover-host-test.sh` are referenced by nothing except SKILL.md.
   - Fix: add a `transcript` job that runs `bash skills/transcript-mirror/test.sh` (which already chains M14/M15), `transcript-sync-test.sh` and `skills/transcript-parse/test-hosts.sh` (which chains the grok-locate suite), plus `discover-host-test.sh`.

10. **P3: The M4 append-fail test cannot pass as root.**
    - Location: `skills/transcript-mirror/test.sh:297-325`.
    - Evidence: `FAIL M4 cursor advanced on append fail …`, `FAIL M4 main.md mutated on append fail`, `FAIL M4 .errors.log missing append failed` when run with `id -u` = 0, because root ignores `chmod a-w`. This will also fail in root CI containers once F9 is done.
    - Fix: skip with a note when `[ "$(id -u)" -eq 0 ]`, or make the store dir read-only through a different mechanism (for example replace `main.md` with a directory or a dangling symlink to force a write error).

11. **P2: Portability. Tests (and the recorder's hashing) assume GNU coreutils.**
    - Evidence: `touch -d '2 minutes ago'` is used in all mirror/parse suites; BSD `touch -d` needs ISO format. `find -printf` (operator-store guard) silently degrades to an empty snapshot on BSD. `sha256sum` is used in the recorder (L46, L63) and tests. Stock macOS historically ships only `shasum -a 256` (unverified for current macOS).
    - Consequence: if the recorder runs without `sha256sum`, idents for uuid-less lines become empty. No cursor gets written for Grok sessions, so every tick is a full rebuild.
    - Fix: add a `_sha256()` helper (`sha256sum` or `shasum -a 256` or `openssl dgst -sha256 -r`) and an `age()` helper using `touch -t $(date -v-2M …)` or python `os.utime`.

12. **P3: Coverage gaps.**
    - No bare `/compact-transcript` test (F2).
    - No large-transcript or performance test (F1).
    - No concurrent-tick or kill-mid-rebuild test (F5).
    - No test for Meaning text containing `## user` or `> @` lines (F13).
    - No test for the hook-shim cache-resolution path.
    - The SubagentStop "signal ratio" table is 1.00 only because there is no empty or tool-only child fixture (docs L126–127 admit this). Add one to make the metric meaningful.

13. **P3: Meaning-channel text is not escaped, so structural markers can be spoofed.**
    - Location: `transcript-mirror.sh:140-156`, `strip_main.py:137-156`, `reapply-overlay.sh:74-78`, `summarize-transcript.py:24-26`.
    - Evidence: user or assistant text is emitted raw. A content line equal to `## user`/`## assistant` splits a turn (shifting overlay ordinals `T######` and compact block boundaries). A content line starting `> @` is dropped from Meaning tails and collapsed by `collapse_tr` if it matches `> @tool_result/`. Summaries from `SUMMARIZE_TRANSCRIPT_CMD` are spliced in unsanitised, so later runs can mis-number turns.
    - Fix: when emitting and splicing, prefix such lines with a zero-width or escape marker (for example a leading space or `\`), or indent the Meaning payload. Reject or escape summary lines that match `HEADING_RE`/`REF_RE`.

14. **P3 (unverified race): summarize vs recorder.**
    - Location: `summarize-transcript.py:298-302` together with `reapply-overlay.sh:149`.
    - `reapply` does `mv -f OUT main.md` while a recorder tick may be appending with `cat >> main.md`. The append lands on the old inode and is lost, and `update_cursor_field3` then stamps the new hash, so the loss is never detected.
    - The `status=ok` gate (source idle ≥60 s) makes this unlikely.
    - Fix: the same per-sid lock as F5.

15. **P3: Stale ticket/branch comments.**
    - `compact-transcript-test.sh:5` ("PDH resolves to feat/CDT-215, not master cache").
    - `summarize-transcript-test.sh:4` ("feat/CDT-214"), `:6` ("Suite is RED until T3"), `:844` ("until T4 wires rebuild").
    - Fix: delete them.

16. **P3: Command description is not user-trigger friendly.**
    - Location: `commands/compact-transcript.md:3-5`.
    - Evidence: "Bounded Meaning-channel file (Meaning tail) for the operator to @. Not a host /compact replacement." It uses internal glossary terms and does not say "short recent-conversation excerpt you can @-attach in a new session".
    - Fix: lead with the plain-language benefit, then keep the glossary term.

17. **P3: bash/Python identity parity edge cases.**
    - Location: `transcript-sync.py:104-120` vs `transcript-mirror.sh:35-52`.
    - Evidence: `printf '{"a":"\u007f"}' | jq -S -c .` gives `{"a":"\u007f"}`, but `json.dumps(..., ensure_ascii=False)` gives `{"a": "\x7f"}` (raw DEL). With jq ≤1.6, floats like `1.0` become `1` and large ints lose precision. A uuid-less record with these values then reports a permanent `status=lag`, which blocks compact/summarize.
    - Fix: canonicalise in one implementation. For example, have `--check` shell out to the same `jq -S -c | sha256` for the last line, or have the recorder store the last line's byte offset and hash raw bytes instead of re-serialising.

18. **P3: Carve-out contradiction.**
    - `skills/transcript-parse/SKILL.md:299-302` says `--allow-in-progress` is passed "EXCLUSIVELY by precompact-capture.sh". `freshness.sh:14-18` also lists "warm bare /handoff (commands/handoff.md Step 1w PREPARE_EXTRA)". SKILL.md L286 calls freshness.sh "POSIX sh", but it is bash.
    - Fix: align SKILL.md with the header.

19. **P3: Orphans.**
    - `skills/transcript-parse/discover-host.sh` has no production caller: retro.md inlines the logic, and `grep -rl discover-host.sh` outside the dir returns nothing.
    - `test-hosts.sh` is referenced by nothing.
    - Fix: either wire retro.md Step 2a to call discover-host.sh (removing the duplicated precedence logic) or delete it and its test.

20. **P3: Grok `is_error` false positives.**
    - Location: `grok_normalize.py:41-42, 152-168`.
    - `_EXIT_RE.search` matches `exit: 1` anywhere, including inside file contents returned by read tools.
    - Fix: anchor to the first line (`re.match(r"\s*exit:\s*(\d+)", text)`), which is how the live format shows it.

21. **P3: Opaque failure mode in hosts-grok-locate-test.sh.**
    - Location: L127–141 and similar.
    - With `set -euo pipefail`, a failing `python3 - <<PY` aborts before `if [ $? -eq 0 ] … else bad …`, so there is no FAIL line and no summary.
    - Fix: wrap in `if python3 - <<PY … PY then pass …; else bad …; fi`, or use `set +e`/`set -e` as test-hosts.sh does.

22. **P2 (high-confidence, unverified against host source): Claude project-dir encoding is wrong for paths with non-`/` special characters.**
    - Location: `hosts.py:75-78`.
    - `dash_encode_cwd` replaces only `/`. Claude Code maps every non-alphanumeric character to `-` (for example `/Users/j.doe/my_app` becomes `-Users-j-doe-my-app`).
    - Effect: newest-locate, `cwd_sessions()` (sync no-args and `--check`), `/doctor` lag and `/retro` discovery all miss such projects. Tests encode the same way, so they cannot catch it.
    - Fix: `re.sub(r"[^A-Za-z0-9]", "-", abs_cwd)`, keeping the old form as a fallback candidate. Add a test with a dotted path.

23. **P3: Python version floor.**
    - `parselib.py:33, 117, 244` evaluate `frozenset[str]`/`set[str]` at import, so Python 3.8 or older raises `TypeError: 'type' object is not subscriptable`.
    - Fix: add `from __future__ import annotations` or use `typing.FrozenSet`/`Set`. Document python ≥3.9 otherwise.

## Enhancement proposals

- **E1: One source for the mirror docs (S, high token and drift impact).** `docs/commands/transcript-mirror.md` and `skills/transcript-mirror/SKILL.md` duplicate the enablement JSON, the SubagentStop JSON, the Catch-up section and the entire M15 section (about 150 lines). Keep the operator detail in docs and cut SKILL.md to a roughly 60-line protocol with links. This saves about 2.5k tokens whenever the skill loads and removes a drift surface. The test.sh M1 glossary checks can still run on both files.
- **E2: Trim transcript-parse/SKILL.md (S, medium).** At 360 lines (about 4.5k tokens) it is mostly a human design record: the validated-monster notes, the pipeline rationale and the Grok normalize notes. Move that to `docs/` or the spec, and keep the API tables and landmines in SKILL.md.
- **E3: Cursor-with-offset incremental recorder (M, high).** This is the fix for F1: cursor = `ident \t source \t main_sha \t line_no \t byte_offset`. A tick reads from `byte_offset` (`tail -c +N`), verifies the ident at `line_no` with one `jq` call, and rebuilds only on a mismatch. Expected cost is O(new lines), which makes the 10 s Stop timeout safe and makes cron sync cheap.
- **E4: Collapse the PDH triple-resolution (S, low-medium).** compact/summarize/sync `.sh` wrappers already live inside the plugin, so `HERE=$(cd "$(dirname "$0")" && pwd)` is sufficient and avoids picking up a different plugin copy from cwd tier 2. In `commands/compact-transcript.md`, merge Steps 1 and 2 into one block, which saves about 1.3 kB per invocation.
- **E5: Installer helper (M, high UX).** Add `skills/transcript-mirror/install.sh [--subagent] [--cron]` (install-aware, idempotent JSON merge using `jq`). It copies the shim, merges settings, and prints the exact cron line with an absolute resolved sync path and PATH. This removes F6 entirely and makes opt-in a one-liner, reachable from `/setup` as an explicit opt-in flag if SPEC allows.
- **E6: Shared test lib (S–M, medium).** Put `plant_hit`, `write_store`, `last_ident`, `store_fingerprint`, `sha_file`, `age` and the operator-store guard in `skills/transcript-mirror/test-lib.sh`, sourced only by tests. This removes the drifted copies (the jq vs python `last_ident`), centralises GNU/BSD shims (F11) and the root skip (F10). Replace grep-the-source assertions in transcript-sync-test.sh with behaviour tests.
- **E7: Status-aware Meaning tail (S, high).** Once F2's spec change lands, include a one-line footer or header comment in the tail, such as `<!-- mirror cursor: <ident>, lag: N lines -->`. The operator then knows how fresh it is, and bare mode becomes useful mid-session.
- **E8: Security hardening (S, medium).** Add `umask 077` (F4). Optionally add a configurable redaction pass for sidecars (for example `TRANSCRIPT_MIRROR_REDACT_CMD`, mirroring the summarizer seam), plus a doc warning that `@`-attaching `main.md` or tails into other sessions or tools re-exposes their contents.
- **E9: CI job (S, high).** See F9. With E6's root skip and GNU/BSD shims, the suites can run on both `ubuntu-latest` and `macos-latest`.

## Coverage attestation

- Files in slice list (`slices/04-transcript.txt`): **39**
- Rows in the Per-file review table: **39**
- Every file was read in full, with large test suites read in chunks, section by section. Tests run: `skills/transcript-mirror/test.sh` (224/3; the 3 failures are the root-only chmod artifact), `compact-transcript-test.sh` (93/0), `summarize-transcript-test.sh` (117/0), `transcript-sync-test.sh` (35/0), `skills/transcript-parse/discover-host-test.sh` (10/0), `hosts-grok-locate-test.sh` (23/0), `test-hosts.sh` (28/0). All `.sh` pass `bash -n`, all `.py` pass `py_compile`, and all fixtures are valid JSON. shellcheck is not installed. No repo files were modified; the scratch experiments used `TRANSCRIPT_MIRROR_ROOT` under the session scratchpad, and the `__pycache__` dirs created by test runs were removed.
