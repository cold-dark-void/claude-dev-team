# SPEC-036: Transcript Mirror (live compressed session record)

**Status**: DRAFT
**Category**: core
**Created**: 2026-08-25

## Overview

The transcript mirror is a live per-session compressed record of the **meaning
channel** (user + assistant text) plus lossless **channel sidecars**. A Stop /
SessionEnd hook recorder appends as the session happens (bash + jq only). A
`transcript-sync` CLI is the acceptance-tested catch-up path (Python; `hosts.py`
locate + freshness). Storage is global and session-keyed at
`~/.claude/transcript/<sid>/`. Enablement is hook registration itself (default
off). The mirror is **not** an STM packet and **not** a compact seed — those
terms stay with `/handoff` (SPEC-018). This spec does not change `/handoff`,
PreCompact rescue, or M8 cache.

## MUST

- **M1 — Surface and glossary.** Product files MUST live under
  `skills/transcript-mirror/` with YAML `name` + `description`. MUST NOT add
  `commands/*.md` (not a slash Surface). Docs page MUST be
  `docs/commands/transcript-mirror.md`. Docs, skill, and `main.md` headers MUST
  use glossary terms **Transcript mirror**, **Meaning channel**, **Channel
  sidecar** (`CONTEXT.md`). Docs MUST NOT call `main.md` an STM packet or
  compact seed.
- **M2 — Store layout.** Default root MUST be `~/.claude/transcript/<sid>/`
  containing `main.md`, `thinking/`, `tool_result/`, `injection/`, `meta`, and
  `cursor`. `@refs` in `main.md` MUST be paths relative to that sid dir
  (`@thinking/…`, `@tool_result/…`, `@injection/…`). Identity is `session_id`,
  not repo / worktree. Tests MUST set `TRANSCRIPT_MIRROR_ROOT` to a temp dir
  and MUST NOT write the operator's real `~/.claude/transcript/`. That env is a
  harness override only — user-facing docs MUST NOT document it as operator
  config.
- **M3 — Enablement.** Opt-in MUST be a user-owned **second** `hooks.Stop[]`
  command (after `stop-review.sh`) **and** a `hooks.SessionEnd[]` command, both
  `timeout` 10, pointing at a thin project shim that execs the plugin recorder.
  The settings.json `command` string MUST NOT contain pipe characters (PDH
  lookup MUST live inside the `.sh`, same pattern as `precompact-rescue.sh`).
  `/setup orchestration` greenfield `hooks.Stop` MUST remain `stop-review.sh`
  only. `plugin.json` MUST NOT auto-register Stop or SessionEnd. Doctor
  `EXPECTED_HOOK_*` / `hooks.events` MUST NOT require the recorder or
  SessionEnd (SPEC-022 `transcript.mirror_lag` is additive; hook SoT
  unchanged). `hooks.hygiene` MUST stay silent for `transcript-mirror.sh`
  (user-owned; basename ∉ `EXPECTED_HOOK_SCRIPTS`). Unregistered (no hook
  stdin, no `--sid`/`--transcript`) MUST create no new store dirs.
- **M4 — Fail-open.** The recorder MUST always exit 0 and MUST NOT emit
  `decision: block`. Failures MUST append one line to `<store-root>/.errors.log`
  (root, not sid dir). Cursor MUST NOT advance if `main.md` append failed.
  An incomplete or killed tick MUST NOT leave `cursor` past unwritten content
  (write `cursor` only after a successful append, via temp file + `mv`).
  Subagent MUST no-op: `hook_event_name`/`hookEventName` is `SubagentStop`, **or**
  any of `agent_id` / `agentId` / `agent_type` / `agentType` is non-empty.
- **M5 — Dual-host locate (hook = bash + jq only).** Claude: read
  `transcript_path` // `transcriptPath`. Grok: if that path ends with
  `updates.jsonl` and sibling `chat_history.jsonl` exists, switch to the
  sibling; `cursor` MUST key to the **resolved** path. If the path is still
  empty: reconstruct `chat_history.jsonl` with the Grok cwd-bucket locate
  in **M5a** (`cwd` from stdin else `$PWD`; `sid` from stdin `session_id`
  // `sessionId` else `$GROK_SESSION_ID`). Missing reconstructed file:
  silent no-op (no sid dir; `.errors.log` unchanged). Parse both stdin
  casings (`hook_event_name` // `hookEventName`, `session_id` //
  `sessionId`, `transcript_path` // `transcriptPath`, agent keys above).
  Stop: process only when `reason` is empty, `end_turn`, `channel_closed`, or
  `shutdown`; other reasons no-op. SessionEnd MUST flush (ignore `reason`)
  unless the M4 subagent rule applies. Manual:
  `transcript-mirror.sh --transcript <file.jsonl> --sid <session-id>`.
  SessionEnd absent on a host is graceful absence (settings entry inert).
- **M5a — Grok cwd-bucket locate (CDT-218; dual-engine).** Stop/SessionEnd
  reconstruct (bash + jq only) and `hosts.py` locate / `grok_cwd_bucket`
  (Python; transcript-sync only) MUST implement the same contract. Python
  MUST NOT run in the recorder or any helper it sources. Do not invent
  Grok's slug+hash write algorithm. Prefer `.cwd` content match.
  **Cwd:** `abspath(expanduser(cwd))`. Hook: stdin cwd else `$PWD`; if the
  value is not absolute, prefix `$PWD`. **Urlencode:** hook
  `jq -rn --arg s "$abs" '$s|@uri'`; Python
  `urllib.parse.quote(abs, safe="")`. Tests MUST use ASCII absolute
  fixture paths so both encodings match. Sessions root:
  `${GROK_SESSIONS_DIR:-$HOME/.grok/sessions}`.
  1. If
     `$root/<urlencode(abs-cwd)>/<sid>/chat_history.jsonl` is a regular
     file, use it (urlencode hit wins).
  2. On miss: list **immediate children** of `$root` only (maxdepth 1).
     For each child directory, if `$child/.cwd` exists, read it as UTF-8
     and strip one trailing LF, CR, or CRLF (no other trim). If that
     text equals `abs-cwd`, the child is a matching bucket. `.cwd` is
     valid only at the bucket root. MUST NOT recurse into session dirs
     or parse JSONL.
  3. Among matching buckets where `$child/<sid>/chat_history.jsonl` is a
     regular file: 0 → treat as missing (hook: silent no-op; locate:
     `None`); 1 → use that file; N → use the lexical-min path and still
     write / return it.
  4. `grok_cwd_bucket(cwd)` for M10/M11 enumeration: urlencode directory
     if it exists; else the lexical-min `.cwd`-matched bucket; else the
     urlencode path (may not exist). Then list `*/chat_history.jsonl`
     under that bucket and `hosts.locate` **by sid**.
  5. Tests MUST set `GROK_SESSIONS_DIR` and `TRANSCRIPT_MIRROR_ROOT` to
     temp fixtures. MUST NOT walk the operator's `~/.grok/sessions`.
- **M6 — Cursor.** `cursor` is one line: `<identity>\t<source-path>\t<main-sha256>\n`.
  Watermark identity is the last **successfully mirrored** source record plus
  the resolved source path.
  - Claude: identity = non-null string `.uuid`. Null/missing uuid →
    `h:` + SHA-256 of `jq -S -c` canonical JSON of that line.
  - Grok: raw `chat_history.jsonl` has no uuid. Identity MUST be `h:` + SHA-256
    of `jq -S -c` canonical JSON of the record (content-stable). Line index
    and `prompt_index` alone MUST NOT be the identity.
  Incremental: find the cursor identity in the current file; process records
  after it. Identity absent (truncate rewind, path change, hash mismatch on
  `main.md`): **rebuild** `main.md` + sidecars from the full file (temp dir +
  rename), then write `cursor`. Rebuild is allowed and MUST leave `main.md`
  duplicate-free. Re-run with no new records MUST be a no-op (byte-identical
  `main.md`). Two-phase append (tick A then tick B) MUST be byte-identical to
  one-shot over the same source. Path change vs stored source-path: treat as
  identity-absent (rebuild).
- **M7 — Meaning channel and sidecars.** Closed taxonomy:
  `thinking | tool_result | injection`. `main.md` MUST contain user + assistant
  text verbatim after wrapper strip. Route to sidecars (lossless):
  - `<system-reminder>`, `<command-message>` / `<command-name>` / `<command-args>`,
    `<user_query>` wrappers → `injection/`
  - `isMeta == true` and Grok `synthetic_reason` present → `injection/`
  - `tool_result` blocks and `tool_use` / `tool_calls` → `tool_result/`
  - `thinking` blocks and Grok `type=reasoning` → `thinking/`
  Empty or encrypted thinking/reasoning MUST write a placeholder
  (`(signature-only, no plaintext)` or `(encrypted reasoning, no plaintext)`).
  MUST NOT invent a fourth sidecar kind.
- **M8 — Format.** `main.md` section headers MUST be `## user` and
  `## assistant`. Consecutive `@tool_result` **only** lines (no meaning-channel
  text between them) MUST collapse to one `@ref` per turn. `@thinking` MUST
  appear only after a `## assistant` header (never as a leading ref before the
  header).
- **M9 — Fork, resume, compact.** New `session_id` MUST create a new sid dir.
  When the child source has `forkedFrom.sessionId` (object; Claude), `meta`
  MUST contain `parent: <that-sid>`. If the parent mirror dir exists, skip
  identities already covered by the parent mirror (copied prefix). If the
  parent dir is missing, still write `parent:` and mirror the full child.
  Grok: write `parent:` only when `forkedFrom.sessionId` is present; do not
  invent a parent. Same sid after compact: keep appending in the same dir.
- **M10 — `transcript-sync`.** Ship `skills/transcript-mirror/transcript-sync.sh`
  (CLI) + Python helper. Python is allowed **only** here. Locate MUST call
  `skills/transcript-parse/hosts.py` locate only (no second parse engine).
  Freshness: `freshness.sh check` — in-progress (exit 9) MUST skip that
  session (MUST NOT write that sid). `--sid` and/or `--transcript` MUST
  create-or-update that sid's Transcript mirror (correct = sid dir with
  Meaning-channel `main.md` + Channel sidecar dirs `thinking/` /
  `tool_result/` / `injection/` + `cursor` whose identity equals the last
  source record; sidecar *files* only when the source has that kind).
  **No-args write target set:** refresh every existing sid dir under the
  store root; **and** if the cwd project is opted-in (any
  `hooks.*.command` contains `transcript-mirror.sh` in
  `.claude/settings.json` or `.claude/settings.local.json`),
  create-or-update **ALL** cwd-bucket sessions — not newest-only.
  Cwd-bucket enumeration: list `*.jsonl` in the Claude project dir for
  `--cwd` (default: pwd) **and** `*/chat_history.jsonl` in the **resolved**
  Grok cwd bucket (M5a `grok_cwd_bucket`: urlencode directory if it
  exists, else `.cwd`-matched bucket), then `hosts.py` locate **by sid**.
  MUST NOT call `hosts.locate(host, None, cwd)` (newest-only). Unregistered no-args MUST
  NOT create new sid dirs. Fail-open: exit 0 always. For opted-in
  projects, periodic `transcript-sync` (cron or equivalent) is **mandatory**
  in docs — not optional. Stop is the fast path. SessionEnd is an
  opportunistic flush. Docs MUST NOT inspect crontab.
- **M11 — `transcript-sync --check` and doctor lag (CDT-221).** `--check`
  MUST print one `sid=<sid> status=<status> source=<path>` line per target
  and MUST exit 0 on `ok`, `lag`, `missing`, and `in-progress`. Status
  vocabulary is exactly those four tokens. `--check` without
  `--sid`/`--transcript` MUST target **ALL** sessions locatable in the
  `--cwd` Claude project dir and Grok cwd bucket (same enumerate + locate
  by sid as M10). MUST NOT report store sid dirs whose source is outside
  those buckets. `freshness.sh check` exit 9 → `status=in-progress`.
  No sid dir → `status=missing` even when `<store-root>/.errors.log` has
  no line for that sid (hook write miss is still missing; lag MUST NOT
  require an error log). `/doctor` MUST register check id
  `transcript.mirror_lag` (group `transcript`) and MUST call
  `transcript-sync --check` only (default `/doctor` and `--json`; MUST NOT
  invoke transcript-sync without `--check`). Mapping: any cwd target
  `missing` or `lag` → WARN; all cwd targets `ok` or `in-progress` (or
  zero targets) → PASS; not opted-in → SKIP; `python3` or transcript-sync
  helper absent → SKIP. MUST NOT FAIL (SPEC-022 M3). MUST NOT treat
  `--check` exit code as FAIL. `--fix` MUST NOT add transcript-sync.
  Fix-it MUST be one copy-pasteable transcript-sync invocation and MUST
  NOT be `/setup team` or `/setup orchestration`. Doctor MUST NOT invent a
  second lag heuristic — stdout `sid=… status=…` is the SoT.
- **M12 — Freeze.** MUST NOT change `/handoff` CLI, PreCompact templates /
  `precompact-capture.sh`, or M8 cache files.
- **M13 — Tests and docs.** `skills/transcript-mirror/test.sh` MUST use
  `$TMPDIR` / `TRANSCRIPT_MIRROR_ROOT` / `GROK_SESSIONS_DIR` fixtures,
  cover dual-host, and cover M1–M11 (including never-fired Stop +
  registered + existing transcript → sync creates a correct mirror; two
  cwd-bucket sessions where the older was never mirrored → no-args
  creates the older sid; dual-host Claude `*.jsonl` + Grok
  `chat_history.jsonl`; long-cwd `.cwd` reconstruct AC1–AC3 and AC2
  decoy; SessionEnd with empty `transcript_path`).
  `hosts-grok-locate-test.sh` MUST cover M5a short-cwd plus AC1/AC2/AC6.
  `transcript-sync-test.sh` MUST include one `--check` line for the
  long-cwd sid when opted-in. Skill YAML required. Recorder MUST ship in
  the plugin package (`skills/transcript-mirror/transcript-mirror.sh`),
  not `tools/transcript-mirror-poc.sh`. Docs “Grok Stop holes” MUST
  describe urlencode then `.cwd` fallback.

## Test

- [ ] `bash skills/spec-tooling/check-format.sh specs/core/SPEC-036-transcript-mirror.md` exits 0
- [ ] Store under `TRANSCRIPT_MIRROR_ROOT/<sid>/` has `main.md`, three sidecar
      dirs, `meta`, `cursor`; `@refs` are relative (M2)
- [ ] Test run does not create `$HOME/.claude/transcript/` entries (M2)
- [ ] Unregistered invocation (no stdin, no flags) creates no store dirs (M3)
- [ ] Recorder exit code is 0 on jq failure; `cursor` unchanged when append
      fails; `.errors.log` gains a line (M4)
- [ ] SubagentStop and non-empty `agent_id` are no-ops (M4)
- [ ] Claude `transcript_path` and Grok `updates.jsonl` → sibling
      `chat_history.jsonl`; both stdin casings parse (M5)
- [ ] Missing Grok reconstructed file is a silent no-op (M5, AC2: no
      urlencode file; no matching `.cwd`+file; `.cwd` matches but file
      missing; decoy `.cwd`; ghost-cwd)
- [ ] Long-cwd Stop reconstruct (`jq @uri` encoding >255 bytes; no
      urlencode-named dir; short bucket; `.cwd` = abs cwd; unique
      Meaning-channel string): exit 0, no `decision: block`, `main.md`
      contains the string, cursor source-path is resolved
      `chat_history.jsonl` (M5a AC1)
- [ ] Long-cwd SessionEnd with empty `transcript_path` flushes the same
      fixture (M5a AC1)
- [ ] Short-cwd Grok + Claude unchanged; decoy slug+hash for another cwd
      not selected; `updates.jsonl` → sibling `chat_history.jsonl`
      unchanged (M5a AC3)
- [ ] `hosts.locate("grok", sid, cwd, sessions_dir=…)` returns the AC1
      `.cwd` file and `None` for AC2; N matching `.cwd`+file →
      lexical-min; short-cwd suite green (M5a AC5, AC6)
- [ ] Opted-in `transcript-sync --check` prints the long-cwd sid (M5a AC5)
- [ ] Stop `reason=other` no-ops; SessionEnd with that reason still flushes (M5)
- [ ] Claude uuid cursor: re-run is idempotent; two ticks = one-shot bytes (M6)
- [ ] Grok rewind (truncate JSONL before last identity) rebuilds with no
      duplicate `## user` / `## assistant` blocks (M6)
- [ ] Grok identity is not line-index-only: inserting a line before the
      cursor record does not duplicate already-mirrored text (M6)
- [ ] Wrappers and `synthetic_reason` land in `injection/`; tool_use in
      `tool_result/`; empty thinking gets a placeholder (M7)
- [ ] Consecutive `@tool_result` refs collapse; `@thinking` only after
      `## assistant` (M8)
- [ ] Child with `forkedFrom.sessionId` writes `parent:` and does not
      re-copy parent-mirrored identities when parent dir exists (M9)
- [ ] `transcript-sync --sid` on a fixture never touched by Stop creates
      a correct mirror; `--check` exits 0 (M10, M11)
- [ ] No-args sync with a registered settings fixture locates a
      never-mirrored cwd session (M10)
- [ ] Two cwd-bucket sessions (older never mirrored, newer already has a
      sid dir): no-args MUST create the older sid; newest-only locate
      MUST fail this test (M10 AC1)
- [ ] Dual-host: Claude `*.jsonl` in the project dir AND Grok
      `chat_history.jsonl` in the cwd bucket; no-args creates both sids
      when opted-in (M10 AC13)
- [ ] `--check` without `--sid` lists ALL cwd-bucket sessions; MUST NOT
      list a store sid whose source is outside those buckets (M11 AC11)
- [ ] No sid dir and no `.errors.log` line → `--check status=missing`
      (M11 AC8)
- [ ] `freshness.sh check` exit 9 → `--check status=in-progress`; sync
      MUST NOT write that sid; doctor MUST NOT WARN (M10, M11 AC10)
- [ ] SessionEnd stdin for sid S with no prior Stop / no sid dir flushes
      S immediately (ignore `reason`), exit 0, no `decision: block`,
      that sid only (M5 AC2)
- [ ] Unregistered no-args MUST NOT create new sid dirs (M10)
- [ ] `git grep` in this change does not modify `commands/handoff.md`,
      `skills/handoff/`, `precompact-capture.sh`, init-orch `HOOKS=`, or
      doctor `EXPECTED_HOOK_` (M3, M12)

## Validation

- [x] Spec reviewed against CDT-220 ACs (OQ1 Option A locked)
- [x] Spec amended against CDT-221 ACs (doctor lag in; all cwd-bucket
      sessions; `--check` SoT)
- [x] Spec amended against CDT-218 ACs (M5a dual-engine `.cwd` locate;
      CDT-218 OUT dropped)
- [ ] `bash skills/transcript-mirror/test.sh` green
- [ ] `bash skills/transcript-parse/hosts-grok-locate-test.sh` green
- [ ] `bash skills/transcript-mirror/transcript-sync-test.sh` green
- [ ] `bash skills/doctor/test.sh` green (`transcript.mirror_lag`)
- [ ] docs-drift + skill-lint clean on touched files
- [ ] Status promoted to ACTIVE after land

## Version History

| Date | Change |
|------|--------|
| 2026-08-25 | CDT-218: M5a Grok cwd-bucket locate — urlencode file then bounded `.cwd` fallback (dual-engine: bash+jq hook, Python `hosts.py` / transcript-sync). Drop CDT-218 OUT. |
| 2026-08-25 | CDT-221: M10 no-args = ALL cwd-bucket sessions (not newest-only); M11 doctor `transcript.mirror_lag` WARN maps `--check` stdout; OQ1 Option A in; sandbox-write OQ closed as not proven (AC5+AC8) |
| 2026-08-25 | Initial DRAFT — CDT-220 transcript mirror v1 (Option B) |

**Covers**: `skills/transcript-mirror/SKILL.md`,
`skills/transcript-mirror/transcript-mirror.sh`,
`skills/transcript-mirror/hook-shim.sh`,
`skills/transcript-mirror/transcript-sync.sh`,
`skills/transcript-mirror/transcript-sync.py`,
`skills/transcript-mirror/test.sh`,
`skills/transcript-mirror/transcript-sync-test.sh`,
`skills/transcript-parse/hosts.py`,
`skills/transcript-parse/hosts-grok-locate-test.sh`,
`docs/commands/transcript-mirror.md`

## SHOULD

- SHOULD keep Stop-hook wall time under the 10s timeout on typical sessions;
  first-tick catch-up on a huge transcript MAY rely on SessionEnd +
  `transcript-sync` (hook still exits 0).
- SHOULD bound the M5a `.cwd` scan to sessions-root immediate children
  (maxdepth 1). MUST NOT `find` the operator `~/.grok/sessions` tree.
- SHOULD document the opt-in settings snippet with `stop-review.sh` as the
  first Stop command and the recorder as the second.
- SHOULD document `transcript-sync` (cron or equivalent periodic/on-demand)
  as mandatory for opted-in projects. Stop is the fast path. SessionEnd
  is opportunistic. Do not inspect crontab.

## MUST NOT

- MUST NOT add the recorder to `skills/init-orchestration` greenfield Stop
  array, `HOOKS=` list, or `check-hook-templates.sh`.
- MUST NOT extend SPEC-022 / doctor `EXPECTED_HOOK_EVENTS` /
  `EXPECTED_HOOK_SCRIPTS`.
- MUST NOT register hooks from `.claude-plugin/plugin.json`.
- MUST NOT put pipe operators in the settings.json hook `command` string.
- MUST NOT document `TRANSCRIPT_MIRROR_ROOT` in user-facing docs.
- MUST NOT re-implement `hosts.py` locate inside the Python backstop.
- MUST NOT call Python from the Stop/SessionEnd recorder or any helper
  it sources.
- MUST NOT invent Grok's slug+hash write algorithm (`.cwd` content match
  only).
- MUST NOT recurse into session dirs or parse JSONL when resolving `.cwd`.
- MUST NOT walk the operator's `~/.grok/sessions` in tests.
- MUST NOT call `hosts.locate(host, None, cwd)` for no-args / `--check`
  cwd targeting (newest-only).
- MUST NOT treat `transcript-sync --check` exit code as a doctor FAIL.
- MUST NOT run transcript-sync without `--check` from `/doctor`.
- MUST NOT add transcript-sync to doctor `--fix`.
- MUST NOT remove or replace the Stop recorder (timeout 10 unchanged).
- MUST NOT add `commands/*.md` (not a new Surface).

## Open Questions

- [x] OQ1 — doctor lag WARN vs `transcript-sync --check` only → **Option A**
      (`--check` only). Implemented CDT-221: `/doctor` maps `--check`
      stdout; WARN never FAIL.
- [x] OQ long-cwd locate (CDT-218) → **Option A**: Stop/SessionEnd
      reconstruct **and** `hosts.py` locate / transcript-sync `--check` /
      doctor lag find the `.cwd` bucket. Dual-engine. `.cwd` content
      match; do not invent Grok's hash.
- [ ] SessionEnd payload on Grok is unverified; treat missing event as
      graceful absence (M5).
- [x] Whether Stop/SessionEnd hooks can write `$HOME/.claude/transcript/`
      under a sandboxed hook env is **not proven here**. AC5 fail-open +
      AC8 (missing without an `.errors.log` line still WARNs) cover the
      symptom.

## Cross-references

- **SPEC-002** — hook packaging, no pipes in hook commands, plugin-dir inside
  the script; recorder is user-owned, not a managed Additional Hook
- **SPEC-005 / init-orchestration** — greenfield Stop stays `stop-review` only
- **SPEC-012** — `hosts.py` locate + `freshness.sh`; no second parse engine.
  This ticket extends Grok cwd-bucket resolve (urlencode then `.cwd`).
  `/retro` behavior is unchanged beyond existing suite green.
- **SPEC-016** — store is global session-keyed, not `$MROOT` / worktree
- **SPEC-018** — STM packet / compact seed / PreCompact / M8 frozen
- **SPEC-021** — skill-bash lint on `SKILL.md` fences; PDH stanza if any
- **SPEC-022** — `transcript.mirror_lag` (group `transcript`); WARN never
  FAIL; `--check` SoT; `EXPECTED_HOOK_*` frozen
- **SPEC-010** — docs-drift `docs-hub` for `docs/commands/transcript-mirror.md`
