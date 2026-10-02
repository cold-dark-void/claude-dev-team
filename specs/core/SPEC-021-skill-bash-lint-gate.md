# SPEC-021: Skill-Bash Lint Gate

**Status**: ACTIVE
**Category**: core
**Created**: 2026-07-03

**Covers**: `skills/skill-lint/check-skill-bash.sh`, `lint.py`, `fence-state.awk`, `fence-scan.awk`, `scan-set.sh`, `SKILL.md`, `test.sh`, `test-command-fences.sh`, `fixtures/`, `skills/release/SKILL.md` (Step 4.8 only)

## Overview

This plugin is prompts-as-code: its executable logic lives inside fenced ```bash blocks
in `commands/*.md`, `skills/**/*.md`, and `agents/*.md`. The 2026-06 consolidation-audit
arcs showed that a small set of bash-block defect classes recurred **despite each being
individually documented as a lesson after it first bit**: variables used in a block but
defined only in a different block (blocks run as separate shells), zsh history-expansion
mangling of `!`/`<!--` in executed text, zsh-fatal unguarded globs that match nothing,
and command substitution capturing a `sqlite3` call whose SQL opens with an inline
`PRAGMA` assignment (emits a value row on sqlite ≥3.51.2, poisoning the captured read).
Every one of these is mechanically detectable by static inspection. This spec defines a
deterministic, LLM-free linter (`check-skill-bash.sh`) that scans fenced bash blocks for
these classes, and wires it into `/release` as a pre-commit gate — converting one-off
lessons into permanent enforcement. Gate ownership follows the SPEC-013 (template-vars)
and SPEC-002 (hook-templates) precedent: the gate contract lives here; `/release` hosts
the invocation step. Known scope overlap with SPEC-008 is resolved by exclusion — see
Out of Scope.

## MUST

### CLI contract

- MUST ship `skills/skill-lint/check-skill-bash.sh` as a pure-subprocess CLI (bash, awk and python3 only, no LLM, no network), invoked from any cwd
- MUST run two engines behind that one CLI: `lint.py` (C1–C5) and `fence-state.awk` (C6, C8, C9, C10; bash and awk only, no interpreter) over the same file set, and print one merged report — one finding stream, one `N findings, M waived` summary, one `--json` array and one exit code. A failure of the awk engine MUST exit `1` with an `error:` line on stderr naming `fence-state.awk`; it MUST NOT read as a clean run
- MUST run both awk engines and the fence-exec harness (SPEC-030) on one fence parser, `skills/skill-lint/fence-scan.awk`, and `check-skill-bash.sh` and the harness on one no-argument file list, `skills/skill-lint/scan-set.sh`. An engine MUST NOT carry its own fence-opener match or file list
- MUST exit `0` when no unwaived findings exist, `1` when at least one unwaived finding exists, `64` on usage error
- MUST NOT execute any scanned code (static analysis only) and MUST NOT modify any scanned file
- MUST print each finding as one line in the form `<file>:<line>: [<check-id>] <message>` where `<line>` is the line number in the source `.md` file (not the offset within the extracted block)
- MUST skip unreadable paths with a `warn:` line on stderr and continue
- MUST exit `64` when every explicit file-list argument is missing/unreadable (no scannable targets). A mix of readable + unreadable is not a usage error (scan the readable ones).

### Scan coverage

- MUST, in the no-argument form, scan every fenced ```bash block in `commands/**/*.md`, `skills/**/*.md`, `agents/**/*.md`, and `AGENTS.md` under the repo root
- MUST, in the no-argument form, exclude `skills/skill-lint/fixtures/**` from discovery (fixture defects must not self-fail the live-tree gate)
- MUST support an explicit file-list argument form (`check-skill-bash.sh <file>...`) that scans only the named files
- MUST treat a fence as bash iff the first whitespace-delimited token of the info string is exactly `bash` (e.g. ```` ```bash ````, ```` ```bash {linenos} ````). Other info strings (```sql, ```json, bare ```) are ignored. Only depth-0 CommonMark fences count; open-fence content with an info-string is not a new fence. The skill-lint awk engine (C6, C8, C9, C10) also lints a fence whose first token is `sh` or `shell` (CDT-286 [09 E2]). `tools/fence-exec` does not: it leaves that alias unset and still scans `bash` only.

### Check classes

- MUST flag **C1 (cross-block variable scope)**: a variable expanded in a fenced bash block (`$VAR` / `${VAR}`) that is defined in a *different* bash block of the same file but not in the expanding block. Definitions include assignment, `for` loop variables, `read` targets, function parameters, `export`, and bash attribute declarations `local` / `declare` / `readonly` (with or without `-` options before the name). An allowlist exempts environment-provided variables (at minimum `HOME`, `PATH`, `PWD`, `TMPDIR`, `OLDPWD`, `CLAUDE_PROJECT_DIR`, shell specials `$?`, `$!`, `$$`, `$@`, `$*`, `$#`, `$0`-`$9`, `$_`)
- MUST flag **C2 (zsh history-expansion hazard)**: a `!` immediately followed by a word character inside a heredoc body or quoted string within a bash block, and any `<!--` literal anywhere in a bash block — excluding `!=` comparisons, `[ ! ` / `if ! ` / `while ! ` negations, `#!` shebangs, and `$!`. The finding message MUST name the remedy (author the content via the Write tool, or build `!` as `chr(33)`)
- MUST flag **C3 (zsh-fatal unguarded glob)**: an unquoted glob pattern used as a `for`-loop word list or command argument with no surrounding no-match guard, where an empty match aborts the block under zsh. The finding message MUST name the remedy (`find -maxdepth 1 -name` iteration or an explicit existence check). Residual false positives after the fixture-defined safe idioms (`find -name`, `case` arms, `[[ … ]]`, quoted globs) MUST be handled by `# lint-ok: C3` waivers at adoption — do not weaken the check to chase zero FPs.
- MUST flag **C4 (captured inline-PRAGMA sqlite poison)**: command substitution `$( sqlite3 ... )` where the SQL string begins with `PRAGMA <name>=<value>;` followed by further statements. The finding message MUST name the remedy (`sqlite3 -cmd ".timeout N"` or a plain statement without the inline PRAGMA). Uncaptured heredoc/multi-line sqlite3 invocations MUST NOT be flagged
- MUST flag **C5 (PDH bootstrap-stanza drift)**: a line inside a fenced bash block matching `^\s*PDH=\$\(` that is not byte-identical, after leading-whitespace strip, to the canonical bootstrap stanza defined by SPEC-002 ("Locating `plugin-dir.sh` itself"). The canonical text MUST be read at runtime from SPEC-002's fenced block — the single source of truth — and MUST NOT be duplicated as a literal in `lint.py` (a second copy is itself the drift class this check exists to prevent). The check MUST fail with a distinct message when the canonical block cannot be located or parsed from SPEC-002 (a silent pass would make the gate vacuous). The finding message MUST name the remedy (copy the stanza verbatim from SPEC-002) and MUST report the first differing column. `skills/plugin-dir.sh` (the locator cannot bootstrap itself) and `skills/plugin-dir-test.sh` (holds no stanza copy at all — it extracts the canonical text from SPEC-002 at runtime, per CDT-232; the exclusion is retained as a no-op) MUST be excluded; both are standalone `.sh` files already outside this linter's scan set. Rationale: SPEC-002 mandates the stanza be emitted "VERBATIM (byte-for-byte identical across all sites)", a MUST that 110 emissions across 26 files currently satisfy with nothing enforcing it — exactly the "documented as a lesson, still recurs" pattern this spec exists to convert into permanent enforcement (the retro.md `$PDH` incident is already in the C1 lesson corpus)
- MUST flag **C6 (assign-before-use)**: inside ONE fenced bash block, a read (`$NAME` or `${NAME}`, also in an unquoted heredoc body) of `MROOT`, `WTROOT`, `MEMDB`, `PLUGIN_DIR`, `PDH` or `EXT_DIR` that comes before the first assignment of that same name in that block. Every block is a separate shell, so the read is empty: `MEMDB="$MROOT/.claude/memory/memory.db"` before `MROOT` is set makes `MEMDB=/.claude/memory/memory.db`, `USE_DB` stays false and the skill silently takes its `.md` fallback. Assignment forms: `NAME=`, `NAME+=`, `export`/`local`/`readonly`/`declare` forms and `${NAME:=…}`. Reads in comments, in single quotes and in quoted heredoc bodies are not reads. One finding per name per block. A block that never assigns the name is out of scope (C1 covers a name defined only in a sibling block). Narrow C6 therefore does not catch a name that no block of the file assigns (`agents/distiller.md` reads `$MEMDB` this way) or a read that a C1 waiver hides (`agents/project-init.md:455`). The finding message MUST name the variable, the line of its first assignment and the required order (`_gc`/`MROOT`, then `WTROOT`, then `MEMDB`, then `USE_DB`). This narrows, and raises to error level for these six names, the SHOULD below on use-before-define within a block
- MUST flag **C8 (idiom hazards)**: six sub-rules, each read on the code part of a line in a bash fence (a masked copy of the line: text in comments, single quotes and heredoc bodies is not code; one finding per line and sub-rule). (a) `grep`, `egrep`, `fgrep` or `rg` with a count flag (`-c`, a short-flag cluster that holds `c`, or `--count`) followed by `|| echo 0`: with no match it prints `0` and exits 1, so the value is `0` newline `0` and `[ "$n" -eq 0 ]` fails with "integer expression expected". (b) `$$` in a word that also holds `TMPDIR` or `/tmp`: a predictable temp path (CWE-377), and a new PID in every Bash-tool call. (c) A bare `/tmp/` path that is not preceded by a name character (the AGENTS.md rule: `"${TMPDIR:-/tmp}/…"` or `mktemp`; `--tmpfs /tmp` and `${TMPDIR:-/tmp}` do not match). (d) A `{` inside a `${VAR:-…}` default (also `:=`, `:+`, `:?`) that does not open a nested `${…}`: the expansion ends at the first `}`, so `${X:-{}}` is `{` plus a stray `}`. (e) A `# Stop here` comment (any case) whose next command, or the end of the fence, is not `exit` or `return`; a comment after an `exit` on the same line is fine. (f) `git branch -D`, `git reset --hard`, `git clean` with `-f` or `--force`, and `git push` with `--force`, `--force-with-lease`, `-f`, `--delete` or `-d`, with any `-C`, `-c` or `--option` before the subcommand. Each message MUST name the remedy: `n=$(grep -c … || true); n=${n:-0}` for (a), `mktemp` for (b), `"${TMPDIR:-/tmp}/…"` for (c), `DEF='{}'` and `${X:-$DEF}` for (d), an `exit` for (e), `skills/lib/git-safety.sh` or a `# lint-ok: C8` waiver with the reason for (f). C8 MUST read every bash fence in every scanned file.
- MUST flag **C9 (argument pass-through in a command fence)**, in `commands/<name>.md` only: a Bash-tool fence is a fresh shell with no positional arguments, and Claude Code writes the user's text into the command only where `$ARGUMENTS` appears. (a) A read of `$@`, `$*`, `$#`, `$1` to `$9`, `${1}` or `${@:2}` at the top level of a fence, before any top-level `set --` in that fence. A function body (`name() { … }`, `function name { … }`) has its own arguments and is not flagged; `${#array[@]}` and `$0` are not positional reads. (b) `$ARGUMENTS` in an unquoted word (word-split and glob-expanded) or in an unquoted heredoc body. A quoted heredoc body (`<<'__A__'`), a double-quoted `"$ARGUMENTS"` and single quotes are not flagged. The convention the message names is the one `commands/handoff.md` Step 1 uses: `ARGS=$(cat <<'__A__'` with `$ARGUMENTS` as the body, then `set -f; set -- $ARGS; set +f`
- MUST flag **C10 (comment or waiver that changes the command)**: (a) a `\` followed by blanks and then end of line or `#` (an escaped space, not a line continuation); (b) a `#` comment line directly after a line that ends in `\` (the comment ends the command and the next line runs on its own, exit 127); (c) `# lint-ok:` inside any open quote, and a `#` that starts a word inside an open quote while a `sqlite3` command is running (the text is SQL or string content, not a comment). The scanner MUST track single quotes, double quotes, `$'…'` and `$( … )` nesting across lines within a block. Heredoc bodies are not scanned by C10. The finding message MUST say to move the comment or waiver onto its own line above the command, or to remove the need for it

### Waivers

- MUST suppress a finding when the offending line, or the line immediately above it within the same block, carries a waiver comment `# lint-ok: <check-id>[,<check-id>...]` naming that check
- MUST count waived findings and print a one-line summary (`N findings, M waived`) — waivers are visible, never silent
- A waiver naming one check-id MUST NOT suppress findings of a different check on the same line
- MUST NOT let a waiver suppress **C10**: a waiver there would hide the defect it reports. A waiver MUST sit on its own comment line above the command, never after a `\` continuation and never inside an open quote (WP 1-12). C6, C8 and C9 are waivable like C1–C5. A real C6 hit MUST be fixed by reordering the block, and a real C8 or C9 hit MUST be fixed in the text, not waived: the live tree MUST hold no C8 or C9 finding, waived or not (WP 2-02)

### Release gate wiring

- `/release` MUST run `check-skill-bash.sh` (no-argument form) as a pre-commit gate step alongside the existing include/template-var/hook-template gates; a non-zero exit MUST block commit and tag until the finding is fixed or explicitly waived
- The change that first wires the gate MUST land with the existing tree scanning clean (every pre-existing finding fixed or waived in the same change) — the gate lands green, never red

### Bite-tests

- MUST ship fixtures under `skills/skill-lint/fixtures/`: one clean fixture and, per check class, at least one defect fixture (C6, C8, C9 and C10 include planted negatives in the same file, so the rule is proven to stay silent on the correct forms)
- MUST verify, before the gate is wired into `/release`, that each defect fixture produces exit 1 with a finding naming its check-id, and that the clean fixture produces exit 0 (a gate that merely runs clean on the live tree is not proven — it must be shown to bite)

## SHOULD

- SHOULD flag use-before-define *within* a single block (same C1 machinery, weaker signal) at warning level without affecting the exit code
- SHOULD support a `--json` flag emitting findings as a JSON array for tooling
- SHOULD complete a full no-argument scan of this repo in under 10 seconds

## MUST NOT

- MUST NOT enforce checks the lesson corpus does not evidence (no generic shellcheck ambitions — scope is the recurring prompts-as-code defect classes above)
- MUST NOT auto-fix findings (report-only; fixes are authored and reviewed like any change)

## Out of Scope

- Ordered-table monotonicity (Version History date order) — `tools/spec-lint.sh` checks that dates are monotonic. SPEC-008 records newest-first for this corpus. `check-format.sh` only checks that the Version History table exists. Not this linter.
- Linting of standalone `.sh` files (`skills/*.sh`) — real shells with real linters; candidates for shellcheck, not this tool
- Runtime/behavioral verification of bash blocks — this is static inspection only

## Test

- [x] Defect fixture per check class (C1, C2, C3, C4) → exit 1, finding line names the correct check-id and source line number
- [x] C5 defect fixture: a stanza with one mutated byte (e.g. `sort -V` → bare `sort`) → exit 1 naming `C5` and the first differing column
- [x] C5 whitespace tolerance: the same canonical stanza indented 2 and 4 spaces (both occur live) → no finding
- [x] C5 vacuous-gate guard: SPEC-002 absent or its fenced block unparseable → non-zero with a distinct "canonical stanza not resolvable" message, never a silent pass
- [x] C5 live-tree baseline: no-arg run over the real tree reports zero C5 findings. The v1.3.0 count of 110 emissions across 26 files is historical. C5 checks byte-identity, not that count.
- [x] C5 heading anchor: a SPEC-002 holding decoy fenced bash blocks both before and after the canonical section still resolves the canonical stanza (a "first fenced block in the file" anchor would compare every emission against the decoy and still exit 0 — vacuous, and invisible)
- [x] C6 fixture `c6-assign-before-use.md`: planted positives (MEMDB from `$MROOT` before MROOT; MEMDB tested before `MEMDB=`; PLUGIN_DIR; a read in an unquoted heredoc body) → exit 1 naming `C6` and the source line; a `# lint-ok: C6` waiver is counted, not printed; negatives (correct order, same-line assign, `export`, `${NAME:=…}`, single quotes, comments, quoted heredoc, a longer name, a block that never assigns the name) → no C6 finding
- [x] C6 resolver names (WP 2-01): fixture `c6-resolver-names.md` plants a `$PDH` read before its assignment (line 6) and an `$EXT_DIR` read before its assignment (line 15) → exit 1, two `[C6]` lines that name the variable, a waived `$PDH` read at line 23 counted in `--json`; correct order, `export`, `:=`, quotes, comments, a longer name and a block that never assigns the name → no C6 finding. One parser: `fence-state.awk` holds no fence-opener match, `check-skill-bash.sh` holds no `discover()`, and the same grep finds the match in `fence-scan.awk`
- [x] C10 fixture `c10-waiver-placement.md`: a waiver after `\`; `\` plus a trailing space; a comment line inside a continuation; `# lint-ok:` inside a double quote; `#` inside a double-quoted and a single-quoted `sqlite3` SQL argument → six C10 findings; the correct forms (waiver above the command, waiver after a closed quote, `#` in `'#tag'`, `${#x}`, heredoc SQL, a `#` after the `sqlite3` command ended) → none; a `# lint-ok: C10` waiver does not hide a C10 finding
- [x] C8 fixture `c8-idioms.md` (WP 2-02): planted positives for each of the six sub-rules (grep -c with an echo 0 fallback, a `$$` temp path, a bare `/tmp/` path, a brace in a `${VAR:-…}` default, a "Stop here" comment without an exit, destructive git) → exit 1, 17 `[C8]` lines at the source lines; a `# lint-ok: C8` waiver is counted, not printed; negatives (`wc`, `stat` and `jq` fallbacks, quoted and commented text, `${TMPDIR:-/tmp}`, `--tmpfs /tmp`, `${A:-${B}}`, a Stop here with an exit, `git branch -d`, `git clean -n`) → no C8 finding; a `# lint-ok: C3` waiver above a planted hit does not hide it
- [x] C9 fixture `c9-args.md` (WP 2-02): copied into a `commands/` directory → 10 `[C9]` lines (top-level `$@`, `${1:-}`, `${@:2}`, `$#`, `$1`; a read before `set --`; a read after a function closed; unquoted `$ARGUMENTS` twice and an unquoted heredoc body); the same file under `skills/` → exit 0; negatives (after `set --`, function bodies, `${#arr[@]}`, `$0 $$ $? $!`, single quotes, comments, the quoted heredoc convention, `"$ARGUMENTS"`) → none
- [x] Live tree (WP 2-02): `check-skill-bash.sh --json` holds no C8 and no C9 entry, waived or not
- [x] Command fences (WP 2-02): `skills/skill-lint/test-command-fences.sh` runs the Step 1 and Step 2 fences of `/audit`, `/compact-transcript`, `/doctor`, `/status`, `/setup` (team Step 0 and models), `/memory export`, `/worktree release`, `/adjust-agent` (Step 7 and the dashboard) and `/retro` (Step 1 and Step 2a) in fresh shells with a sample that holds spaces and `*`: each word arrives intact; an empty directives file gives one `0`; `/retro --all --host grok` with no Grok session prints its error; the planted old `|| echo 0` text fails each count case
- [x] Merged report: a file with one C4 and one C6 finding prints both and `2 findings, 0 waived`; `--json` holds both; a broken `awk` exits 1 naming `fence-state`; no-arg discovery reports C6 and C10 planted in `commands/`, `skills/**`, `agents/` and `AGENTS.md` and skips the fixtures directory
- [x] Clean fixture → exit 0, no findings
- [x] Fixture with a `# lint-ok: C3` waiver on the offending line → exit 0, summary reports 1 waived
- [x] Waiver for C3 on a line that also trips C2 → C2 finding still reported (exit 1)
- [x] No-argument form discovers a defect planted in each of `commands/`, `skills/`, `agents/`, and `AGENTS.md` (coverage bite-test — every globbed dir proven, per the P1-5B default-files lesson)
- [x] Explicit file-list form scans only the named files
- [x] `!=` comparison, `if ! cmd`, `[ ! -f ]`, and `#!` shebang inside a bash block → no C2 finding (false-positive guard)
- [x] Uncaptured heredoc sqlite3 with leading PRAGMA → no C4 finding; captured `$(sqlite3 "PRAGMA busy_timeout=5000; SELECT ...")` → C4 finding
- [x] Full no-arg run on this repo exits 0 after the initial fix/waive pass
- [ ] `/release` dry run with an injected C1 defect → release blocked at the gate step
- [x] Fixtures dir excluded from no-arg discovery
- [x] All explicit paths missing/unreadable → exit 64
- [x] Unreadable among valid paths → warn + scan rest
- [x] `declare`/`local`/`readonly` count as C1 defs
- [x] Info string `bash foo` treated as bash fence

## Validation

- [x] All bite-tests above pass (each gate class proven to bite, not just run clean)
- [x] C5 lands green: live tree reports zero C5 findings at wiring time, and the check is proven to bite via the mutated-byte fixture
- [x] Initial adoption pass complete: live tree scans clean; every waiver reviewed as genuinely safe
- [x] Gate step is `/release` Step 4.8 in `skills/release/SKILL.md`. It has shipped. It is not an open wiring task.
- [x] Spec reviewed and promoted to ACTIVE

## Acceptance criteria

### wp-1-12-fence-state

- **A.** `bash skills/skill-lint/check-skill-bash.sh skills/skill-lint/fixtures/c6-assign-before-use.md` exits 1 and prints `[C6]` at lines 7, 21, 30 and 38 and nowhere else. Each message names the variable (`$MROOT`, `$MEMDB`, `$PLUGIN_DIR`, `$MROOT`) and the line of its first assignment in the same fence. Line 47 holds a `# lint-ok: C6` waiver: that finding is counted as waived (`--json` shows `waived` true) and is not printed. The negative fences (correct order, same-line assignment, `export`, `${NAME:=…}`, single quotes, a comment, a quoted heredoc, `$MROOT_OTHER`, a fence that never assigns the name) produce no `[C6]` line.
  Verify: bash skills/skill-lint/test.sh
- **B.** `check-skill-bash.sh skills/skill-lint/fixtures/c10-waiver-placement.md` exits 1 and prints exactly six `[C10]` lines, at lines 6 (a waiver after a `\` continuation), 13 (`\` followed by a space), 21 (a comment line inside a continuation), 29 (`# lint-ok:` inside a double quote), 39 (`#` inside a double-quoted `sqlite3` SQL string) and 47 (`#` inside a single-quoted `sqlite3` SQL string). The correct forms in the same file print no `[C10]` line. A `# lint-ok: C10` waiver above a planted defect does not hide it, and a `# lint-ok: C6` waiver does not hide a C10 finding.
  Verify: bash skills/skill-lint/test.sh
- **C.** The wrapper merges both engines. A file with one C4 and one C6 finding prints both and the summary `2 findings, 0 waived`, and `--json` holds a C4 and a C6 entry in one array. An `awk` that exits 2 makes the run exit 1 with an `error:` line that names `fence-state`. `--root` discovery reports a planted C6 and C10 in `commands/`, `skills/**`, `agents/` and `AGENTS.md`, and skips `skills/skill-lint/fixtures/`. `--help` exits 0, and an unknown option or a bare `--root` exits 64.
  Verify: bash skills/skill-lint/test.sh
- **D.** On the live tree, `check-skill-bash.sh --json` holds no C6 and no C10 entry, waived or not. This covers the `MROOT`-before-`MEMDB` order in the three `skills/kickoff/SKILL.md` and two `skills/brainstorm/SKILL.md` memory fences and the `skills/orchestrate/steps/00-resolve.md` claude-memory fence, the three continuation sites (`commands/council.md` finalize, `skills/review-and-commit/SKILL.md` Step 5, `skills/memory-recall/SKILL.md` Step 4), the three SQL-string sites in `commands/memory.md` and the quoted script in `commands/retro.md`.
  Verify: bash skills/skill-lint/test.sh
- **E.** The Step 5 fence of `skills/review-and-commit/SKILL.md` reads no variable that an earlier fence sets: skill-lint reports no C1 (waived or not) inside it and the text has no `${degraded…}` expansion. Run as extracted in a fresh shell with `<PLAN_FILE>` filled in and `<DEGRADED>` set to `false`, it passes `finalize --plan-file <path> --evidence-file <path> --judge-output <path>` to the engine and no `--verification-mode`. With `<DEGRADED>` set to `true` it also passes `--verification-mode self-verified`. With `<PLAN_FILE>` or `<DEGRADED>` left unfilled, or `DEGRADED` set to any other value, it exits non-zero and never calls the engine. The Step 3 fence prints `PLAN_FILE=<path>` for a file that exists.
  Verify: bash skills/review-and-commit/test-fences.sh
- **F.** The `--impact` caller grep of `skills/review-and-commit/SKILL.md` Step 1b, run on a fixture tree, lists the `.py`, `.ts`, `.sh`, `.go`, `.rs` and `.js` files that hold the symbol and skips `.txt`, `node_modules` and `vendor`. The old `--include='*.{py,…}'` form matches nothing on the same tree.
  Verify: bash skills/review-and-commit/test-fences.sh
- **G.** The Step 4 fence of `skills/memory-recall/SKILL.md`, run in a fresh shell against a fixture DB, exits 0 in each embedding mode. In `none` mode, with a leftover `embedding_dimensions` of 384, it reports the keyword fallback and sends no `.load`. In `lembed` mode it sends `.load "<MROOT>/.claude/memory/extensions/vec0"` and `.load "<MROOT>/.claude/memory/extensions/lembed0"`, then registers the model with `INSERT INTO temp.lembed_models(name, model) SELECT 'mini', lembed_model_from_file('<MROOT>/.claude/memory/models/all-MiniLM-L6-v2.gguf')` and calls `lembed('mini', …)` after it (WP 1-13: `lembed()` takes a registered name, never a path). In `remote` mode (curl stub) it sends the quoted `vec0` load and the returned vector. No `.load` path starts with an empty root. The `.load` step is stubbed where sqlite-vec is not installed.
  Verify: bash skills/memory-recall/test-fences.sh
- **H.** The Step 5 fence of `skills/memory-recall/SKILL.md` prints nothing when `memory.db` exists (`USE_DB=true`). With no DB it matches with `grep -F` (`needle.token` does not match `needleXtoken`), and a query of `$(touch X)`, a backtick command or a quote-breaking string executes nothing. A linked worktree's own `.claude/memory/*/context.md` is searched.
  Verify: bash skills/memory-recall/test-fences.sh
- **I.** In Steps 3, 4 (both keyword fallbacks) and 8 of `skills/memory-recall/SKILL.md`, a query of `100%` matches the row that holds `100%` and not `1000 widgets`, `a_b` does not match `axb`, and a query with a single quote still matches.
  Verify: bash skills/memory-recall/test-fences.sh
- **J.** The `commands/memory.md` distill Step 5 "Determine which agents" fence, run without `--agent` against a fixture DB with `distill_threshold` 2, finds the one agent over the threshold and reports no SQL error. The `validate --deep` Step 10.1 fence lists the tier-1 digests with and without `--agent`. The Step 10.5 fence returns the live and distilled source IDs and drops the stale one. Run on the file at the parent commit, the same suite fails.
  Verify: bash skills/memory-store/test-memory-md-fences.sh
- **K.** [process] The release ship notes record the evaporated sites, with the file and lines that show each one already ordered `MROOT`, `WTROOT`, `MEMDB` before this work package: `AGENTS.md` (both snippets), `commands/setup.md` (Step 2.5 and Step 4) and `skills/wrap-ticket/SKILL.md` (the Step 3 fences). They record the C6/C10 rule IDs (C7 to C9 stay reserved for WP 6-03 and WP 2-02), the C10 hit in `commands/retro.md` that no member named, and the CDT-264 change: a waiver inside a SQL string cannot move above the command, so each fence now rebuilds its variable.
- **L.** [process] `bash tools/run-all-tests.sh` exits 0 and every `/release` gate passes.

## Version History

| Date | Change |
|------|--------|

| 2026-10-02 | CDT-371: Version History monotonicity is `tools/spec-lint.sh`, not `check-format.sh`. The 110/26 emission count is historical. Step 4.8 has shipped. |
| 2026-09-30 | WP 1-13 (`wp-1-13-setup-team-lembed`; CDT-262): AC G of `wp-1-12-fence-state` names the lembed call of the `skills/memory-recall/SKILL.md` Step 4 fence. `lembed()` takes a registered name, so AC G now says the fence registers the model (`INSERT INTO temp.lembed_models …`) and then calls `lembed('mini', …)`. SPEC-004 and SPEC-006 own the rule; no lint check changes. |
| 2026-09-30 | WP 2-01 (`wp-2-01-fence-harness`; CDT-272): **C6 names** widen to `PDH` and `EXT_DIR` (the live tree holds no hit; fixture `c6-resolver-names.md`). **One fence parser and one scan set:** `fence-scan.awk` (fence opener and closer, bash test, latest heading) replaces the copy inside `fence-state.awk`, and `scan-set.sh` holds the no-argument file list that `check-skill-bash.sh` carried. The fence-exec harness in `tools/fence-exec/` runs on both; SPEC-030 owns it. C7–C9 stay reserved for WP 2-02 and WP 6-03. |
| 2026-09-30 | WP 1-12 (`wp-1-12-fence-state`; CDT-264, CDT-320, CDT-263, CDT-357, W2-22): added **C6 (assign-before-use)** for `MROOT`, `WTROOT`, `MEMDB` and `PLUGIN_DIR` inside one fence, and **C10 (comment or waiver that changes the command)** — a waiver after a `\` continuation, `\` plus blanks, a comment line inside a continuation, `# lint-ok:` inside an open quote and `#` inside a quoted `sqlite3` SQL string. Both run in the new `fence-state.awk` (bash and awk only, no interpreter); `lint.py` (C1–C5) is unchanged; `check-skill-bash.sh` now runs both engines and merges the report, `--json` and the exit code, and an awk failure exits 1. C10 cannot be waived; real C6 hits are fixed, not waived. Rule IDs: C7 is reserved for WP 6-03 and C8/C9 for WP 2-02. CDT-264 goal text changed: a waiver inside a multi-line SQL string cannot move onto its own line above the command, so the three `commands/memory.md` fences rebuild their variable instead. New `## Acceptance criteria` section with `### wp-1-12-fence-state`. Status stays ACTIVE. |
| 2026-08-01 | CDT-99: added **C5 (PDH bootstrap-stanza drift)** — byte-identity of every `PDH=$(` emission against SPEC-002's canonical fenced block, with the canonical text read from SPEC-002 at runtime (no second literal). Homed here rather than as docs-drift D9 because SPEC-010 D8 bars that checker from fenced-bash content, which is where every stanza lives. |
| 2026-07-13 | CDV-180: codify Q1 fixtures-exclude, Q3 skip/all-missing→64, Q4 declare/local/readonly, Q5 first info-string token; Covers + lint.py/test.sh |
| 2026-07-13 | CDV-180 implemented (Tasks T0–T11): skills/skill-lint C1–C4 + waivers + fixtures/test.sh; adoption pass live-clean; `/release` Step 4.8 wired; status DRAFT→ACTIVE. Remaining: first real release exercises gate (~0.39.0). |
| 2026-07-03 | Initial version (DRAFT). ID 021: SPEC-020 is allocated to /craft-loop on its own feature branch. |
## Cross-references

- SPEC-002 — plugin infrastructure; hook-template drift gate precedent (gate owned by domain spec, hosted by /release). Also owns the **canonical PDH bootstrap stanza** that C5 reads as its single source of truth, and the caller-family fail-mode table whose completeness C5 now guarantees
- SPEC-008 — spec format contract; owns `check-format.sh` and any table/format checks (see Out of Scope)
- SPEC-010 — code review & release; `/release` is the host of this gate's invocation step
- SPEC-013 — council template-var drift gate precedent
- Lesson corpus: AUDIT-P0/P1 project memory — cross-block scope (retro.md $PDH incident), zsh `!` mangling (v0.32.0 release), empty-glob fatality (P0.5), inline-PRAGMA poison (P0.8/P0.15/P0.16)
