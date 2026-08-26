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
off). Opt-in **SubagentStop** (CDT-217) writes an **agent nest** under
`<sid>/agents/<id>/` with a nest-ref from parent `main.md`; Stop/SessionEnd
with a non-empty agent key stay v1 no-ops. The mirror is **not** an STM packet
and **not** a compact seed — those terms stay with `/handoff` (SPEC-018). This
spec does not change `/handoff` CLI, PreCompact rescue, or M8 cache **schema**.
SPEC-018 M3f (CDT-216) MAY **read** `main.md` (strip `@ref`s) when
`transcript-sync --check --sid` reports `status=ok`. **C7 (CDT-215):** slash
Surface `/compact-transcript` MAY write a bounded sibling
`<store-root>/<sid>.meaning-tail.md` from stripped `main.md` when that same
`--check --sid` line is `status=ok`. That file is Meaning-channel text for the
operator to `@`; it is **not** an STM packet and **not** a compact seed. This
Surface MUST NOT invoke host `/compact` or PreCompact. **M15 (CDT-214):**
skill CLI `summarize-transcript` (not a slash Surface; default off) MAY,
after an explicit invoke and `--check --sid` `status=ok`, overlay oversized
Meaning-channel bodies in parent `main.md` with an LLM summary plus a
`> @verbatim/…` ref to a **Verbatim original**. The recorder still writes
verbatim. Channel sidecar taxonomy stays `thinking | tool_result | injection`.

## MUST

- **M1 — Surface and glossary.** Product files MUST live under
  `skills/transcript-mirror/` with YAML `name` + `description`. MUST NOT add
  `commands/*.md` except **C7 carve-out (CDT-215):** exactly one file,
  `commands/compact-transcript.md`, with YAML `name: compact-transcript` and a
  `description`. Recorder remains not a slash Surface (do not add
  `commands/transcript-mirror.md`). Docs pages MUST be
  `docs/commands/transcript-mirror.md` and `docs/commands/compact-transcript.md`.
  Docs, skill, command frontmatter, CHANGELOG, `main.md` headers, and the
  meaning-tail file MUST use glossary terms **Transcript mirror**, **Meaning
  channel**, **Channel sidecar**, **Meaning tail**, **Verbatim original**
  (`CONTEXT.md`). Docs, skill, command frontmatter, CHANGELOG, and output
  MUST NOT call `main.md`, `<sid>.meaning-tail.md`, the M15 overlay, or
  Verbatim original files an STM packet, compact seed, or Channel sidecar.
  Compact seed stays STM packet / `/handoff`. `/compact-transcript` is not
  a host `/compact` replacement. M15 MUST NOT add a second `commands/*.md`.
- **M2 — Store layout.** Default root MUST be `~/.claude/transcript/<sid>/`
  containing `main.md`, `thinking/`, `tool_result/`, `injection/`, `meta`, and
  `cursor`. An optional **agent nest** MUST live at
  `<sid>/agents/<sanitized-agent-id>/` with the same six entries (same layout,
  own `cursor`). `@refs` in parent `main.md` MUST be paths relative to that
  sid dir (`@thinking/…`, `@tool_result/…`, `@injection/…`, nest-refs
  `@agents/<id>/main.md`, and M15 `@verbatim/…`). Identity is `session_id`,
  not repo / worktree. Nest identity is `(session_id, sanitized agent_id)`.
  A C7 meaning-tail file MUST live at `<store-root>/<sid>.meaning-tail.md`
  (sibling of the sid dir, never inside it) and MUST NOT be one of the six
  sid-dir entries. **M15 Verbatim original dir:** optional extra
  `<sid>/verbatim/` (not a Channel sidecar kind; not one of the six
  required entries; not under `thinking/` / `tool_result/` / `injection/` /
  `agents/`). Tests MUST set `TRANSCRIPT_MIRROR_ROOT` to a temp dir and
  MUST NOT write the operator's real `~/.claude/transcript/`. That env is a
  harness override only — user-facing docs MUST NOT document it as operator
  config.
- **M3 — Enablement.** Opt-in MUST be a user-owned **second** `hooks.Stop[]`
  command (after `stop-review.sh`) **and** a `hooks.SessionEnd[]` command, both
  `timeout` 10, pointing at a thin project shim that execs the plugin recorder.
  The settings.json `command` string MUST NOT contain pipe characters (PDH
  lookup MUST live inside the `.sh`, same pattern as `precompact-rescue.sh`).
  `/setup orchestration` greenfield `hooks.Stop` MUST remain `stop-review.sh`
  only. `plugin.json` MUST NOT auto-register Stop, SessionEnd, or
  SubagentStop. Doctor `EXPECTED_HOOK_*` / `hooks.events` MUST NOT require
  the recorder, SessionEnd, or SubagentStop (SPEC-022 `transcript.mirror_lag`
  is additive; hook SoT unchanged). `hooks.hygiene` MUST stay silent for
  `transcript-mirror.sh` (user-owned; basename ∉ `EXPECTED_HOOK_SCRIPTS`).
  Default docs/SKILL settings snippet MUST stay Stop + SessionEnd only.
  SubagentStop is a **separate** opt-in event (same shim `command`, no
  pipes). Unregistered (no hook stdin, no `--sid`/`--transcript`) MUST
  create no new store dirs.
- **M4 — Fail-open.** The recorder MUST always exit 0 and MUST NOT emit
  `decision: block`. Failures MUST append one line to `<store-root>/.errors.log`
  (root, not sid dir). Cursor MUST NOT advance if `main.md` append failed.
  An incomplete or killed tick MUST NOT leave `cursor` past unwritten content
  (write `cursor` only after a successful append, via temp file + `mv`).
  Stop and SessionEnd MUST no-op when any of `agent_id` / `agentId` /
  `agent_type` / `agentType` is non-empty (v1; AC1). That no-op MUST leave
  the store byte-identical to v1 (no nest dir, no parent mutation).
  `SubagentStop` is **not** this no-op — see **M4a**.
- **M4a — Agent nest (CDT-217; opt-in SubagentStop).** Opt-in tick is
  stdin `hook_event_name` // `hookEventName` equal to `SubagentStop`
  (AC1b). Same shim as Stop/SessionEnd. `/setup orchestration` and
  `plugin.json` MUST NOT register SubagentStop. Default docs snippet
  MUST NOT include it. Measure signal ratio; MUST NOT default-on.
  **Identity.** `session_id` // `sessionId` is the parent sid
  (SPEC-031: subagent hooks carry parent sid). Nest directory name is
  sanitized `agent_id` // `agentId` only — MUST NOT use `agent_type` /
  `agentType` as the nest id. Empty `agent_id` after sanitize: log one
  `.errors.log` line, create no nest, exit 0.
  **Sanitize (AC2c).** Map with `tr -c 'A-Za-z0-9._-' '_'`, then
  `cut -c1-64`. Reject (log, no nest) if the result is empty, `.`, `..`,
  starts with `.`, or contains `..` or `/`. MUST NOT write outside
  `<sid>/agents/<sanitized-id>/`.
  **Source path (AC2b, AC10).** Resolve
  `agent_transcript_path` // `agentTranscriptPath` else
  `transcript_path` // `transcriptPath`. Honor `updates.jsonl` → sibling
  `chat_history.jsonl` when that sibling exists. MUST NOT run M5a Grok
  cwd-bucket reconstruct on SubagentStop. Empty or missing file: log,
  create no nest, exit 0 (fail-open).
  **Flush (OQ5 / AC10).** SubagentStop MUST flush regardless of
  `reason` (including empty and values that Stop would no-op).
  **Create (OQ7 / AC2).** First successful SubagentStop MUST create
  `<sid>/agents/<id>/` with the M2 six entries even when
  `<sid>/main.md` is missing. Nest `meta` MUST include `parent: <sid>`.
  Nest `cursor` follows **M6** inside the nest dir.
  **Parent nest-ref (AC3, OQ7).** A nest-ref is one line
  `> @agents/<id>/main.md` in parent `main.md`. Each nest id MUST appear
  exactly once. Placement: spawn-adjacent (after the parent assistant
  turn whose Task/Agent `tool_use` names that agent) when that turn
  exists in the parent source; otherwise trailing (after the last
  meaning-channel block). Insert on the first **parent** meaning-channel
  write after the nest exists (Stop / SessionEnd / manual without
  `--agent`). SubagentStop-first (no parent `main.md` yet) MUST still
  create the nest and MUST add the nest-ref on the next parent write.
  Commute: SubagentStop-then-parent-Stop vs parent-Stop-then-SubagentStop
  MUST leave the same nest-ref set in parent `main.md` (exactly one line
  per nest id). Parent rebuild (`emit_tick`) MUST re-apply nest-refs
  from existing `<sid>/agents/*/main.md` so they survive a full rewrite.
  **Manual (OQ2 / AC8).**
  `transcript-mirror.sh --transcript FILE --sid SID --agent ID`
  writes that nest. `transcript-sync` MUST NOT invent, enumerate, or
  refresh agent nests (live hook + `--agent` only).
- **M5 — Dual-host locate (hook = bash + jq only).** Claude: read
  `transcript_path` // `transcriptPath`. Grok: if that path ends with
  `updates.jsonl` and sibling `chat_history.jsonl` exists, switch to the
  sibling; `cursor` MUST key to the **resolved** path. If the path is still
  empty: reconstruct `chat_history.jsonl` with the Grok cwd-bucket locate
  in **M5a** (`cwd` from stdin else `$PWD`; `sid` from stdin `session_id`
  // `sessionId` else `$GROK_SESSION_ID`). Missing reconstructed file:
  silent no-op (no sid dir; `.errors.log` unchanged). Parse both stdin
  casings (`hook_event_name` // `hookEventName`, `session_id` //
  `sessionId`, `transcript_path` // `transcriptPath`, agent keys above,
  plus `agent_transcript_path` // `agentTranscriptPath`).
  Stop: process only when `reason` is empty, `end_turn`, `channel_closed`, or
  `shutdown`; other reasons no-op. SessionEnd MUST flush (ignore `reason`)
  unless the M4 Stop/SessionEnd agent-key no-op applies. SubagentStop
  reason is M4a (always flush). Manual:
  `transcript-mirror.sh --transcript <file.jsonl> --sid <session-id>
  [--agent <agent-id>]`.
  SessionEnd absent on a host is graceful absence (settings entry inert).
  SubagentStop absent is graceful absence (v1 no-op for agent keys).
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
  **Agent nest (AC7).** Each nest dir has its own `cursor`. Nest rebuild
  MUST NOT mutate parent `main.md` / parent `cursor`. Parent rebuild MUST
  preserve `<sid>/agents/` (move the tree aside to a **sibling** of the
  sid dir, never under `$WORK` / the RETURN `rm -rf` temp, then restore
  after swap). A parent rebuild that drops `agents/` is a spec fail.
  After parent rebuild, re-apply M4a nest-refs from the preserved tree.
  Rebuild MUST NOT delete, move, truncate, or rewrite
  `<store-root>/<sid>.meaning-tail.md`. Sid-dir bak names (`<dir>.bak.<pid>`,
  `<dir>.agents.<pid>`, `<dir>.verbatim.<pid>`) MUST NOT equal that tail
  path. **M15 verbatim stash:** parent rebuild MUST move `<sid>/verbatim/`
  aside to a **sibling** of the sid dir (`<dir>.verbatim.<pid>`), never
  under `$WORK` / the RETURN `rm -rf` temp, then restore after swap (same
  pattern as `agents/`). A parent rebuild that drops `verbatim/` is a spec
  fail. After restore, the recorder MUST re-apply the overlay **without
  LLM and without Python** via `reapply-overlay.sh` (M15), then write
  `cursor` `main-sha256` of the post-reapply `main.md`.
- **M7 — Meaning channel and sidecars.** Closed taxonomy:
  `thinking | tool_result | injection`. The recorder MUST write user +
  assistant text into `main.md` verbatim after wrapper strip. **M15
  overlay:** after an explicit `summarize-transcript` invoke only, eligible
  Meaning-channel bodies in parent `main.md` MAY be an LLM summary plus
  `> @verbatim/…` (Verbatim original ref). Absent that invoke, `main.md`
  stays v1 verbatim. Route to sidecars (lossless):
  - `<system-reminder>`, `<command-message>` / `<command-name>` / `<command-args>`,
    `<user_query>` wrappers → `injection/`
  - `isMeta == true` and Grok `synthetic_reason` present → `injection/`
  - `tool_result` blocks and `tool_use` / `tool_calls` → `tool_result/`
  - `thinking` blocks and Grok `type=reasoning` → `thinking/`
  Empty or encrypted thinking/reasoning MUST write a placeholder
  (`(signature-only, no plaintext)` or `(encrypted reasoning, no plaintext)`).
  MUST NOT invent a fourth sidecar kind. A line `> @agents/<id>/main.md`
  is a **nest-ref** (pointer to an agent nest), not a Channel sidecar.
  A line `> @verbatim/…` is a **Verbatim original** ref (M15), not a
  Channel sidecar. Closed sidecar taxonomy stays
  `thinking | tool_result | injection`.
- **M8 — Format.** `main.md` section headers MUST be `## user` and
  `## assistant`. Consecutive `@tool_result` **only** lines (no meaning-channel
  text between them) MUST collapse to one `@ref` per turn. `@thinking` MUST
  appear only after a `## assistant` header (never as a leading ref before the
  header). M15 overlay MUST keep those rules: the `@verbatim/` ref sits
  with the summary, never inside a consecutive `@tool_result` run.
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
  NOT create new sid dirs. MUST NOT invent, enumerate, or refresh
  `<sid>/agents/` (OQ2: live SubagentStop + recorder `--agent` only).
  Fail-open: exit 0 always. MUST NOT invoke `summarize-transcript` (M15 is
  explicit CLI only; no-args / cron MUST NOT overlay). For opted-in
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
- **M12 — Freeze.** MUST NOT change `/handoff` CLI (flags, help, argument-hint),
  PreCompact templates / `precompact-capture.sh`, or M8 cache **schema**
  (`leaf_uuid`, `packet`/`brief`, `events`, `path`, `created_at`, optional
  `light`). **Carve-out (CDT-216 / SPEC-018 M3f):** `/handoff` `prepare` MAY
  **read** `<store>/<sid>/main.md` and `meta`, and MAY run
  `transcript-sync --check --sid <handoff-sid>` as the consume gate. MUST NOT
  write the Transcript mirror store. MUST NOT invoke the recorder. MUST NOT
  run `transcript-sync` without `--check`. MUST NOT read Channel sidecar
  bodies or `agents/` for miner input. MUST NOT retarget M8 `leaf_uuid` at
  `cursor`. **Carve-out (CDT-215 / C7):** `/compact-transcript` MAY **read**
  `<store>/<sid>/main.md` and MAY run `transcript-sync --check --sid <sid>`
  as the sole consume gate (same stdout contract as M3f). On hit it MAY
  atomically write `<store-root>/<sid>.meaning-tail.md` (sibling of the sid
  dir). MUST NOT write `main.md`, `cursor`, Channel sidecars, `meta`,
  `agents/`, or any other path inside the sid dir. MUST NOT invoke the
  recorder. MUST NOT run `transcript-sync` without `--check`. MUST NOT read
  Channel sidecar bodies, `agents/`, or `verbatim/` for the tail. MUST NOT
  add `/handoff` flags. MUST NOT change M3f hit/miss, JSONL identity,
  `leaf_uuid`, or PreCompact. MUST NOT summarize. **Carve-out (CDT-214 /
  M15):** `summarize-transcript` MAY **read** `<store>/<sid>/main.md` and
  `cursor`, MAY run `transcript-sync --check --sid <sid>` as the sole
  consume gate, and MAY write parent `main.md`, `<sid>/verbatim/`, and
  `cursor` field 3 (`main-sha256`) only. MUST NOT write Channel sidecars,
  `meta`, `agents/`, or `*.meaning-tail.md`. MUST NOT invoke the recorder.
  MUST NOT run `transcript-sync` without `--check`. MUST NOT enumerate,
  summarize, or restore `agents/*/main.md`. `/handoff` miners MUST NOT
  read `verbatim/`, Channel sidecar bodies, or `agents/`. After overlay,
  M3f strip keeps summary text and drops `@ref`s (including `@verbatim/`).
  Recorder rebuild MAY stash/restore `verbatim/` and exec
  `reapply-overlay.sh` (no LLM, no Python). Sync write path, M4a nest,
  and M5a locate stay frozen. Recorder and `transcript-sync` MUST NOT
  create, update, or delete `*.meaning-tail.md` or invoke
  `summarize-transcript`.
- **M13 — Tests and docs.** `skills/transcript-mirror/test.sh` MUST use
  `$TMPDIR` / `TRANSCRIPT_MIRROR_ROOT` / `GROK_SESSIONS_DIR` fixtures,
  cover dual-host, and cover M1–M11 plus M4a (including never-fired Stop +
  registered + existing transcript → sync creates a correct mirror; two
  cwd-bucket sessions where the older was never mirrored → no-args
  creates the older sid; dual-host Claude `*.jsonl` + Grok
  `chat_history.jsonl`; long-cwd `.cwd` reconstruct AC1–AC3 and AC2
  decoy; SessionEnd with empty `transcript_path`; SubagentStop nest;
  Stop-with-agent-keys byte-identical to v1; commute nest-ref; rebuild
  preserves `agents/`; M5a suite still green).
  `hosts-grok-locate-test.sh` MUST cover M5a short-cwd plus AC1/AC2/AC6.
  `transcript-sync-test.sh` MUST include one `--check` line for the
  long-cwd sid when opted-in, and MUST assert no-args / `--sid` does not
  create `agents/` dirs. Skill YAML required. Recorder MUST ship in
  the plugin package (`skills/transcript-mirror/transcript-mirror.sh`),
  not `tools/transcript-mirror-poc.sh`. Docs “Grok Stop holes” MUST
  describe urlencode then `.cwd` fallback. Docs MUST document
  SubagentStop as a separate opt-in (same shim), MUST tell the operator
  to measure meaning-channel vs empty-tick signal ratio, and MUST NOT
  add SubagentStop to the default Stop + SessionEnd snippet.
  `compact-transcript-test.sh` MUST cover M14 and MUST be invoked from
  `test.sh` or run as a sibling suite in Validation.
  `summarize-transcript-test.sh` MUST cover M15 and MUST be invoked from
  `test.sh` or run as a sibling suite in Validation. Docs MUST document
  the skill CLI (not as a slash Surface) and `SUMMARIZE_TRANSCRIPT_CMD`.
- **M14 — Meaning tail (`/compact-transcript`, CDT-215).** Slash Surface
  `/compact-transcript` MUST emit a bounded Meaning-channel file for the
  operator to `@`. It MUST NOT invoke host `/compact` or PreCompact.
  PreCompact rescue (`precompact-capture.sh`) MUST NOT consume `main.md` or
  `*.meaning-tail.md`.
  - **CLI.** `commands/compact-transcript.md` (YAML `name: compact-transcript`)
    MUST dispatch install-aware `skills/transcript-mirror/compact-transcript.sh`.
    Bare (no positional) MUST use the live session id from `discover-warm.sh`
    line 1 (same identity as bare `/handoff` M10b). Positional `<sid>` MUST be
    that sid as given. MUST NOT remap to `hosts.locate()` descendant stem.
    `<sid>` MUST be a single path component (no `/`, not `.` or `..`); else
    fail-closed, no write. Argument-hint: `[<sid>]`. No `--bytes` / `--turns`.
  - **Detect (sole gate).** Invoke install-aware
    `skills/transcript-mirror/transcript-sync.sh --check --sid <sid>` only
    (MUST NOT omit `--check`; MUST NOT pass `--transcript`). Consume only
    when stdout contains a line `sid=<sid> status=ok` (status token exact).
    MUST NOT invent a second detect path. Strip MUST be the same
    `strip_mirror_main` implementation SPEC-018 M3f uses (one helper; no
    drifted copy).
  - **Miss (this Surface only).** Any of: status in
    `{lag, missing, in-progress}`, no matching line, helper missing,
    `python3` missing, live sid unresolvable, stripped body empty, `<sid>`
    rejected → exit non-zero (1 for miss/empty/unresolvable; 64 for usage),
    create or update no tail file, stderr names status or reason. MUST NOT
    fall back to JSONL. MUST NOT exit 0 (recorder/sync/doctor fail-open
    unchanged).
  - **Hit write.** Read `<store>/<sid>/main.md`. Strip: drop the
    `# transcript mirror` title; drop every line matching `^>\s*@` (Channel
    sidecar refs, nest-refs, and `@verbatim/` refs). MUST NOT inline sidecar,
    nest, or Verbatim original bodies.
    Drop leading lines until the first `## user` or `## assistant` heading.
    If nothing remains, treat as miss (empty). Bound: UTF-8 byte length of
    the file MUST be `<= 32768`. Tests MUST assert `wc -c`, not a tokenizer.
    Selection: longest trailing **complete turn-block** suffix that fits.
    A turn-block starts at a line matching `^## (user|assistant)[[:space:]]*$`
    and runs until the next such heading or EOF. If the newest block alone
    exceeds the cap: emit that heading plus a prefix of its body, truncated
    at a UTF-8 code-point boundary so the file is `<= 32768` bytes and valid
    UTF-8. MUST NOT exceed the cap. First line of the file MUST be
    `## user` or `## assistant`. MUST NOT emit STM / Compact-seed headings
    (`## State now`, `## Through-line`, `## appendix`). Atomic overwrite of
    `<store-root>/<sid>.meaning-tail.md` (temp in the same directory + `mv`).
    Idempotent: same `main.md` bytes → same tail bytes. On success print
    exactly one stdout line: the absolute path of the tail file. Exit 0.
  - **Store isolation.** After success, `main.md` sha256, `cursor`, Channel
    sidecar trees, `agents/`, and `verbatim/` MUST be byte-identical to
    before the invocation. This Surface MUST NOT truncate, rewrite, or
    delete store files inside the sid dir. MUST NOT summarize. MUST NOT
    invoke `summarize-transcript`. After an M15 overlay, the Meaning tail
    MAY be stale until the operator re-runs `/compact-transcript`.
  - **Docs.** `docs/commands/transcript-mirror.md` MUST NOT recommend
    `@main.md` as the compact attach. Compact `@`-attach MUST point at
    `/compact-transcript`. `@main.md` remains valid only as the full
    unbounded Meaning channel. See-also both ways with `/handoff` and
    transcript-mirror. README `## Commands` Advanced (adjacent to
    `/handoff`) and `docs/README.md` command reference MUST index
    `/compact-transcript`. Docs-drift `cmd-index`, `docs-hub`, and
    `docs-page-links` MUST be clean on the touched files.
  - **Ship.** New `commands/*.md` ⇒ bump class **minor** (v1.13.0 at
    `/release`). A patch ship MUST fail `check-bump-class.sh` (SPEC-010
    B1–B6).
  - **Tests.** `skills/transcript-mirror/compact-transcript-test.sh` MUST
    set `TRANSCRIPT_MIRROR_ROOT` and `$TMPDIR` and MUST NOT write
    `$HOME/.claude/transcript/`. Coverage: hit write + path stdout; miss
    no-write; `main.md` sha256 unchanged; strip title / `@refs` / nest-refs;
    `wc -c <= 32768`; newest-block overflow still `<= 32768` and newest
    heading present; overwrite idempotent; recorder/sync do not create or
    mutate a planted tail; sid-dir rebuild leaves the sibling tail
    byte-identical; SPEC-018 Test 40 no-mirror identity (T1.3: no
    `spine_origin`).
- **M15 — Meaning-channel overlay (`summarize-transcript`, CDT-214).**
  Skill CLI (not a slash Surface). Default off. Explicit invoke only.
  Recorder still writes verbatim (M7).
  - **CLI.** Ship install-aware
    `skills/transcript-mirror/summarize-transcript.sh` (PDH + `python3`;
    fail-closed like `compact-transcript.sh`). Python helper
    `summarize-transcript.py`. Apply engine
    `reapply-overlay.sh` (bash+awk only). MUST NOT add `commands/*.md`.
    `--sid <sid>` is required. `<sid>` MUST be a single path component
    (no `/`, not `.` or `..`). No positional. No-args / unknown flags /
    `--restore` without `<turn-id>` → exit 64, no write.
    Overlay: `summarize-transcript.sh --sid <sid>`.
    Restore one turn: `summarize-transcript.sh --sid <sid> --restore <turn-id>`.
    `<turn-id>` is `T` + 6-digit 1-based ordinal of `^## (user|assistant)[[:space:]]*$`
    headings in parent `main.md` (`T000001`). MUST NOT hang off
    `transcript-sync` no-args or cron. MUST NOT run from
    `/compact-transcript`, `/handoff`, `/doctor`, `/setup orchestration`,
    or the recorder.
  - **Detect (sole gate).** Invoke install-aware
    `transcript-sync.sh --check --sid <sid>` only (MUST NOT omit
    `--check`; MUST NOT pass `--transcript`). Consume only when stdout
    contains `sid=<sid> status=ok` (status token exact). Else exit 1,
    stderr names status or reason, store byte-identical. MUST NOT invent
    a second detect path.
  - **Eligibility (size only).** A turn-block starts at a line matching
    `^## (user|assistant)[[:space:]]*$` and runs until the next such
    heading or EOF. **Meaning payload** = turn-block lines that are not
    the heading and do not match `^>\s*@`. Eligible iff UTF-8 `wc -c` of
    the meaning payload is **> 8192**. Already-replaced turns (body has
    `^>\s*@verbatim/`), empty payloads, Channel sidecar bodies, and
    nest-ref lines are not eligible. User and assistant both in scope.
    MUST NOT use age. Parent sid `main.md` only — MUST NOT enumerate
    `agents/*/main.md`.
  - **Replacement.** Keep the heading. Keep existing Channel sidecar /
    nest-ref `^>\s*@` lines as two groups: leading (before the first
    meaning-payload line) and trailing (after the last). Replace the
    meaning payload with: non-empty LLM summary + exactly one
    `> @verbatim/<turn-id>.txt` immediately after the summary and
    before trailing refs. MUST NOT add, drop, merge, or duplicate
    headings. MUST NOT place the verbatim `@ref` inside a consecutive
    `@tool_result` run (M8). If the summary is empty, the summarizer
    exits non-zero, or `wc -c(summary) >= wc -c(payload)`, leave that
    turn verbatim (no write for that turn). MUST NOT write
    `[summarization failed]` or any placeholder.
  - **Verbatim original store.** One file per replaced turn inside
    `<sid>/verbatim/<turn-id>.txt`. `@ref` is relative to the sid dir.
    File bytes MUST equal the pre-replacement meaning payload
    (lossless). Companion `<sid>/verbatim/<turn-id>.sum` holds the
    summary text only (for rebuild re-apply without LLM). `.sum` is
    **not** a Verbatim original, **not** a Channel sidecar, **not** a
    Meaning tail. MUST NOT write under `thinking/` / `tool_result/` /
    `injection/` / `agents/`. MUST NOT write
    `<store-root>/<sid>.meaning-tail.md` or any sibling tail.
  - **Restore.** `--restore <turn-id>` splices `.txt` back as the
    meaning payload, drops that turn's `> @verbatim/…` line, deletes
    that turn's `.txt` and `.sum`, and updates `cursor` `main-sha256`.
    MUST NOT re-LLM. MUST NOT touch other turns. Missing or
    not-overlaid `<turn-id>` → exit 1, store byte-identical.
  - **Cursor.** After overlay or restore: `cursor` identity and
    source-path unchanged; field 3 MUST equal sha256 of the post-write
    `main.md`. Next recorder tick MUST NOT treat this as hash-mismatch
    rebuild and MUST NOT duplicate `## user` / `## assistant`. New
    source records append verbatim.
  - **Rebuild re-apply.** Sid-dir rebuild MUST NOT delete, move,
    truncate, or rewrite `verbatim/` files or `*.meaning-tail.md`.
    After stash/restore of `verbatim/`, exec
    `skills/transcript-mirror/reapply-overlay.sh <sid-dir>` (bash+awk;
    no Python; no LLM; no `SUMMARIZE_TRANSCRIPT_CMD`). For every
    `<turn-id>` that still has both `.txt` and `.sum`, overlay that
    heading-ordinal turn (summary + `@ref`; no duplicate headings).
    Then write `cursor` `main-sha256` of the post-reapply `main.md`.
  - **Summarizer seam.** Env `SUMMARIZE_TRANSCRIPT_CMD` is the only
    seam. stdin = UTF-8 meaning payload; stdout = UTF-8 summary; exit
    0 required. Unset, empty, non-zero exit, or empty stdout → that
    turn verbatim. Plugin MUST NOT ship a live LLM caller. Tests MUST
    stub this env. `--restore` and `reapply-overlay.sh` MUST NOT read
    this env and MUST NOT invoke an LLM.
  - **Fail-closed (this CLI only).** Detect miss / helper missing /
    `python3` missing / bad sid → exit 1 (64 for usage), store
    byte-identical. MUST NOT exit 0 on miss (do not copy
    `transcript-sync` fail-open). Zero eligible turns → exit 0,
    byte-identical. Per-turn LLM fail → that turn verbatim. Overlay
    success stdout is exactly one line `sid=<sid> replaced=<n>`.
    Restore success stdout is exactly one line
    `sid=<sid> restored=<turn-id>`. Recorder / `transcript-sync` /
    doctor fail-open unchanged.
  - **Consumers.** This CLI MUST NOT create, update, or delete
    `*.meaning-tail.md`. `/compact-transcript` MUST NOT summarize.
    M14 strip still drops `^>\s*@`; tail and SPEC-018 M3f see summary
    text, not originals. Miners MUST NOT read `verbatim/`.
  - **Python.** Allowed on this CLI and existing `transcript-sync`
    only. Never from the recorder or any helper it sources.
    `reapply-overlay.sh` MUST stay bash+awk so the recorder may exec
    it.
  - **Ship.** No new `commands/*.md` ⇒ bump class **patch**. A new
    `commands/*.md` in the same tree MUST fail `check-bump-class.sh`
    as patch (SPEC-010 B1–B6) and ship as **minor**.
  - **Tests.** `skills/transcript-mirror/summarize-transcript-test.sh`
    MUST set `TRANSCRIPT_MIRROR_ROOT` and `$TMPDIR` and MUST NOT write
    `$HOME/.claude/transcript/`. Stub `SUMMARIZE_TRANSCRIPT_CMD` (no
    live LLM in CI). Coverage: AC3 miss no-write; oversized replace +
    `@ref` + original bytes; undersized untouched; idempotent
    re-invoke; restore splice; cursor sha256; recorder increment
    no-dup; rebuild re-applies overlay and does not eat `verbatim/`
    or Meaning tail; M7 still three sidecar kinds; M14 + SPEC-018
    Test 40 green; glossary grep.

## Test

- [ ] `bash skills/spec-tooling/check-format.sh specs/core/SPEC-036-transcript-mirror.md` exits 0
- [ ] Store under `TRANSCRIPT_MIRROR_ROOT/<sid>/` has `main.md`, three sidecar
      dirs, `meta`, `cursor`; `@refs` are relative (M2)
- [ ] Test run does not create `$HOME/.claude/transcript/` entries (M2)
- [ ] Unregistered invocation (no stdin, no flags) creates no store dirs (M3)
- [ ] Recorder exit code is 0 on jq failure; `cursor` unchanged when append
      fails; `.errors.log` gains a line (M4)
- [ ] Stop/SessionEnd with non-empty `agent_id` / `agentType` are v1
      no-ops: no nest dir, parent sid dir sha256 unchanged (M4, AC1, AC4)
- [ ] SubagentStop creates `<sid>/agents/<id>/` with M2 layout even when
      parent `main.md` is missing; nest `meta` has `parent: <sid>` (M4a, AC2)
- [ ] SubagentStop source is `agent_transcript_path` else `transcript_path`;
      MUST NOT M5a-reconstruct; missing file: no nest, exit 0 (M4a, AC2b, AC10)
- [ ] Bad `agent_id` (`..`, `/`, empty after sanitize) creates no nest
      and does not write outside `<sid>/agents/` (M4a, AC2c)
- [ ] Parent `main.md` has exactly one `> @agents/<A>/main.md`; commute
      SubagentStop↔parent Stop; spawn-adjacent or trailing (M4a, AC3)
- [ ] Parent rebuild preserves `agents/` and re-emits nest-refs (M6, AC7)
- [ ] `--agent` CLI writes the nest; no-args/`--sid` sync does not
      invent `agents/` (M4a, M10, AC8)
- [ ] SubagentStop `reason=other` still flushes (M4a, AC10)
- [ ] Nest-ref is not a fourth sidecar kind; M5a tests still green (M7, AC9)
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
- [ ] Recorder/sync/doctor PRs: `git grep` does not modify
      `commands/handoff.md`, `precompact-capture.sh`, init-orch `HOOKS=`,
      or doctor `EXPECTED_HOOK_` (M3, M12). `skills/handoff/` MAY change
      only under SPEC-018 M3f as a **read** of `main.md` / `--check`
      (CDT-216); MUST NOT change M8 cache schema or PreCompact
- [ ] CDT-216 consume: `--check --sid` `status=ok` is the only handoff
      read gate; cursor is not `leaf_uuid` (SPEC-018 Test 40)
- [ ] C7 hit: `--check --sid` `status=ok` → writes
      `$TRANSCRIPT_MIRROR_ROOT/<sid>.meaning-tail.md`; stdout is that
      absolute path; exit 0 (M14)
- [ ] C7 miss: status `lag` / `missing` / `in-progress`, no line, helper
      absent, empty after strip, unresolvable live sid → exit non-zero, no
      tail file created or updated, stderr names status or reason; MUST NOT
      exit 0 (M14)
- [ ] C7 store isolation: after hit, `main.md` sha256, `cursor`, sidecar
      trees, `agents/` byte-identical (M14, AC2)
- [ ] C7 strip: fixture with `# transcript mirror`, `> @tool_result/…`,
      `> @agents/…` → tail has no title and no `^>\s*@` lines; first line
      is `## user` or `## assistant` (M14, AC7)
- [ ] C7 cap: `wc -c` of tail `<= 32768`; newest heading present; newest
      block alone > cap still `<= 32768` (M14, AC7)
- [ ] C7 overwrite idempotent: second hit with unchanged `main.md` → same
      tail sha256 (M14)
- [ ] C7 recorder/sync: planted `*.meaning-tail.md` sha256 unchanged after
      Stop tick and after `transcript-sync --sid`; neither creates a tail
      (M12, M14)
- [ ] C7 rebuild: planted sibling tail sha256 unchanged after sid-dir
      rebuild (M6, M14)
- [ ] C7 tests do not create `$HOME/.claude/transcript/` entries (M2, M14)
- [ ] C7 glossary: `git grep -i` on command/docs/skill/CHANGELOG does not
      call `main.md` or `meaning-tail.md` an STM packet or compact seed (M1)
- [ ] C7 docs: transcript-mirror page points compact `@`-attach at
      `/compact-transcript`; does not recommend `@main.md` as the compact
      attach; README Advanced + `docs/README.md` index `/compact-transcript`;
      `docs/commands/compact-transcript.md` exists and is linked (M1, M14)
- [ ] C7 handoff identity: SPEC-018 Test 40 T1.3 still has no
      `spine_origin`; no new `/handoff` flags (M12, AC4, AC6)
- [ ] C7 bump-class: `commands/compact-transcript.md` added + patch version
      → `check-bump-class.sh` exits 1; + minor → 0 (SPEC-010 B1–B6, AC5)
- [ ] M15 miss: `--check` not `ok` / no line / helper missing → exit 1,
      store byte-identical; no-args / unknown flags → 64 (M15, AC3, AC10)
- [ ] M15 oversized: meaning payload `wc -c` > 8192 → summary in `main.md`,
      exactly one `> @verbatim/TNNNNNN.txt`, file bytes equal pre-replacement
      payload; undersized untouched (M15, AC4, AC5, AC6)
- [ ] M15 idempotent re-invoke: second overlay with same `main.md` →
      byte-identical store; already-replaced not eligible (M15, AC4)
- [ ] M15 restore: `--restore TNNNNNN` splices payload, drops `@verbatim/`
      for that turn only, deletes that turn's `.txt`/`.sum`, updates
      `cursor` field 3; no LLM (M15, AC7)
- [ ] M15 cursor: overlay updates `main-sha256` only; next Stop appends
      verbatim with no duplicate headings and no rebuild (M15, AC8)
- [ ] M15 rebuild: `verbatim/` and sibling Meaning tail survive; overlay
      re-applies without LLM; `cursor` sha256 matches post-reapply
      `main.md` (M15, AC9)
- [ ] M15 zero eligible → exit 0, byte-identical; per-turn stub fail →
      that turn verbatim, no placeholder (M15, AC10)
- [ ] M15 MUST NOT touch `*.meaning-tail.md`; M14 + Test 40 still green;
      M7 sidecar dirs remain exactly `thinking` / `tool_result` /
      `injection` (M15, AC11, AC12, AC16)
- [ ] M15 nests OUT: `agents/*/main.md` unchanged; no nest invented
      (M15, AC13)
- [ ] M15 glossary: `git grep -i` on skill/docs/CHANGELOG does not call
      `main.md`, overlay, `verbatim/`, or meaning-tail an STM packet,
      compact seed, or Channel sidecar (M15, AC14)
- [ ] M15 bump-class: no new `commands/*.md` + patch →
      `check-bump-class.sh` exits 0 (SPEC-010 B1–B6, AC15)
- [ ] M15 recorder does not call Python; `reapply-overlay.sh` has no
      `python3` (M15, AC1, AC17)

## Validation

- [x] Spec reviewed against CDT-220 ACs (OQ1 Option A locked)
- [x] Spec amended against CDT-221 ACs (doctor lag in; all cwd-bucket
      sessions; `--check` SoT)
- [x] Spec amended against CDT-218 ACs (M5a dual-engine `.cwd` locate;
      CDT-218 OUT dropped)
- [x] Spec amended against CDT-217 ACs (M4a SubagentStop agent nest;
      Stop agent-key no-op stays; OQ2/OQ5/OQ7 locked)
- [ ] `bash skills/transcript-mirror/test.sh` green
- [ ] `bash skills/transcript-parse/hosts-grok-locate-test.sh` green
- [ ] `bash skills/transcript-mirror/transcript-sync-test.sh` green
- [ ] `bash skills/doctor/test.sh` green (`transcript.mirror_lag`)
- [ ] docs-drift + skill-lint clean on touched files
- [ ] Status promoted to ACTIVE after land
- [ ] CDT-216 M12 carve-out: handoff reads `main.md` only via SPEC-018 M3f;
      recorder / M4a / M5a / PreCompact / M8 schema unchanged
- [x] Spec amended against CDT-215 ACs (M1 C7 carve-out; M12 consumer
      carve-out; M14 meaning-tail; Test 40 unchanged)
- [ ] `bash skills/transcript-mirror/compact-transcript-test.sh` green
- [ ] `bash skills/handoff/mirror-spine-test.sh` green (Test 40 T1.3)
- [x] Spec amended against CDT-214 ACs (M15 overlay; `verbatim/` dir;
      skill CLI; no new `commands/*.md`; taxonomy closed)
- [ ] `bash skills/transcript-mirror/summarize-transcript-test.sh` green

## Version History

| Date | Change |
|------|--------|
| 2026-08-26 | CDT-214: M15 Meaning-channel overlay — skill CLI `summarize-transcript.sh --sid` / `--restore` (no `commands/*.md`). `--check --sid` `status=ok` gate. Size-only eligibility >8192 UTF-8 bytes. Overlay = summary + `@verbatim/TNNNNNN.txt`; originals in `<sid>/verbatim/`. Recorder still verbatim. Rebuild stashes `verbatim/` like `agents/` and re-applies via bash `reapply-overlay.sh` (no LLM/Python). Seam `SUMMARIZE_TRANSCRIPT_CMD`. Patch bump. |
| 2026-08-26 | CDT-215: M1 C7 carve-out — exactly `commands/compact-transcript.md`. M12 consumer carve-out + M14 meaning-tail: `--check --sid` `status=ok` MAY write sibling `<sid>.meaning-tail.md` (≤32768 UTF-8 bytes, trailing turn-blocks, strip title/`^>\s*@`). Fail-closed on miss. Recorder/sync MUST NOT touch `*.meaning-tail.md`. Rebuild MUST NOT eat the sibling. Not Compact seed / STM packet. Not a `/compact` replacement. Minor bump (v1.13.0 at `/release`). |
| 2026-08-26 | CDT-216: M12 carve-out — `/handoff` prepare MAY read `main.md` + `--check --sid` (SPEC-018 M3f). CLI / PreCompact / M8 schema / recorder / M4a / M5a still frozen. |
| 2026-08-26 | CDT-217: M4a opt-in SubagentStop agent nest under `<sid>/agents/<id>/`; Stop/SessionEnd agent-key no-op stays v1; parent nest-ref; rebuild preserves `agents/`. OQ2/OQ5/OQ7 locked. |
| 2026-08-25 | CDT-218: M5a Grok cwd-bucket locate — urlencode file then bounded `.cwd` fallback (dual-engine: bash+jq hook, Python `hosts.py` / transcript-sync). Drop CDT-218 OUT. |
| 2026-08-25 | CDT-221: M10 no-args = ALL cwd-bucket sessions (not newest-only); M11 doctor `transcript.mirror_lag` WARN maps `--check` stdout; OQ1 Option A in; sandbox-write OQ closed as not proven (AC5+AC8) |
| 2026-08-25 | Initial DRAFT — CDT-220 transcript mirror v1 (Option B) |

**Covers**: `skills/transcript-mirror/SKILL.md`,
`skills/transcript-mirror/transcript-mirror.sh`,
`skills/transcript-mirror/hook-shim.sh`,
`skills/transcript-mirror/transcript-sync.sh`,
`skills/transcript-mirror/transcript-sync.py`,
`skills/transcript-mirror/strip_main.py`,
`skills/transcript-mirror/compact-transcript.sh`,
`skills/transcript-mirror/compact-transcript.py`,
`skills/transcript-mirror/test.sh`,
`skills/transcript-mirror/transcript-sync-test.sh`,
`skills/transcript-mirror/compact-transcript-test.sh`,
`skills/transcript-parse/hosts.py`,
`skills/transcript-parse/hosts-grok-locate-test.sh`,
`commands/compact-transcript.md`,
`docs/commands/transcript-mirror.md`,
`docs/commands/compact-transcript.md`,
`skills/transcript-mirror/summarize-transcript.sh`,
`skills/transcript-mirror/summarize-transcript.py`,
`skills/transcript-mirror/reapply-overlay.sh`,
`skills/transcript-mirror/summarize-transcript-test.sh`

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
- SHOULD document SubagentStop as a second opt-in event (same shim
  `command`, `timeout` 10, no pipes) **below** the default Stop +
  SessionEnd snippet. SHOULD tell the operator to count meaning-channel
  ticks vs empty/tool-only SubagentStop before considering default-on.
- SHOULD document `/compact-transcript` as the compact `@`-attach path.
  SHOULD keep `@main.md` documented as the full unbounded Meaning channel
  only (optionally M15-overlaid).
- SHOULD document `summarize-transcript.sh --sid` as the opt-in overlay
  CLI and `SUMMARIZE_TRANSCRIPT_CMD` as the only summarizer seam. SHOULD
  tell the operator the plugin does not ship a live LLM caller.

## MUST NOT

- MUST NOT add the recorder to `skills/init-orchestration` greenfield Stop
  array, `HOOKS=` list, or `check-hook-templates.sh`.
- MUST NOT add SubagentStop to greenfield settings, `plugin.json`, or
  doctor `EXPECTED_HOOK_*`.
- MUST NOT default-on SubagentStop in the docs/SKILL Stop + SessionEnd
  snippet (signal-ratio measurement first).
- MUST NOT run M5a Grok reconstruct on SubagentStop.
- MUST NOT invent agent nests from `transcript-sync` no-args / `--sid` /
  `--check`.
- MUST NOT treat `@agents/…` or `@verbatim/…` as a fourth Channel sidecar
  kind.
- MUST NOT drop `<sid>/agents/` or `<sid>/verbatim/` on parent rebuild.
- MUST NOT extend SPEC-022 / doctor `EXPECTED_HOOK_EVENTS` /
  `EXPECTED_HOOK_SCRIPTS`.
- MUST NOT register hooks from `.claude-plugin/plugin.json`.
- MUST NOT put pipe operators in the settings.json hook `command` string.
- MUST NOT document `TRANSCRIPT_MIRROR_ROOT` in user-facing docs.
- MUST NOT re-implement `hosts.py` locate inside the Python backstop.
- MUST NOT call Python from the Stop/SessionEnd/SubagentStop recorder or
  any helper it sources (including `reapply-overlay.sh`).
- MUST NOT invoke an LLM from the recorder, `transcript-sync`,
  `reapply-overlay.sh`, or `--restore`.
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
- MUST NOT add `commands/*.md` except `commands/compact-transcript.md`
  (M1 C7 carve-out). MUST NOT add `commands/transcript-mirror.md`.
  MUST NOT add `commands/summarize-transcript.md`.
- MUST NOT let `/handoff` write the Transcript mirror store, invoke the
  recorder, or run `transcript-sync` except `--check --sid` (M12 carve-out).
- MUST NOT treat mirror `cursor` as SPEC-018 `leaf_uuid`.
- MUST NOT call `main.md`, `<sid>.meaning-tail.md`, the M15 overlay, or
  Verbatim original files an STM packet, compact seed, or Channel sidecar.
- MUST NOT write a meaning-tail inside the sid dir. MUST NOT truncate
  store `main.md` except M15 overlay/restore of eligible turn bodies.
- MUST NOT create, update, or delete `*.meaning-tail.md` from the
  recorder or `transcript-sync`.
- MUST NOT eat `<store-root>/<sid>.meaning-tail.md` on sid-dir rebuild.
- MUST NOT fail-open `/compact-transcript` (exit 0) on detect miss.
- MUST NOT fall back to JSONL from `/compact-transcript`.
- MUST NOT invoke host `/compact` or PreCompact from `/compact-transcript`.
- MUST NOT add `--bytes` / `--turns` / new `/handoff` flags.
- MUST NOT change SPEC-018 M3f hit/miss, JSONL identity, `leaf_uuid`, or
  M8 schema.
- MUST NOT write Verbatim originals under `thinking/` / `tool_result/` /
  `injection/` / `agents/` or as a meaning-tail sibling.
- MUST NOT run `summarize-transcript` from `transcript-sync` no-args /
  cron, `/compact-transcript`, `/handoff`, `/doctor`, `/setup
  orchestration`, or the recorder.
- MUST NOT fail-open `summarize-transcript` (exit 0) on detect miss.
- MUST NOT enumerate, summarize, or restore `agents/*/main.md`.

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
- [x] OQ2 — agent-nest catch-up → **live SubagentStop + recorder
      `--agent` only**. `transcript-sync` MUST NOT invent children.
- [x] OQ5 — SubagentStop `reason` → **always flush** (ignore `reason`).
- [x] OQ7 — create vs parent `@ref` → **create nest on first
      SubagentStop**; parent nest-ref on first parent meaning-channel
      write (commute).
- [ ] Live SubagentStop payload field `agent_transcript_path` is
      **unverified**. Spec prefers it then `transcript_path`. Tests use
      fixtures. Missing both: fail-open, no nest.
- [x] CDT-216 OQ-H — JSONL-prefix + mirror-suffix hybrid → **OUT**.
- [x] CDT-216 OQ-F — parent-prefix stitch → **JSONL fallback this ticket**
      (Test 1). Stitch unproven; MUST NOT ship suffix-only.
- [x] CDT-216 OQ-K — `--check --sid` target → **handoff session id**
      (warm discover sid / cold CLI uuid). MUST NOT remap to locate()
      descendant stem.
- [x] CDT-215 write path → **A**: sibling
      `<store-root>/<sid>.meaning-tail.md` (not inside the sid dir).
- [x] CDT-215 seed bound → **32768 UTF-8 bytes** (`wc -c`); longest
      trailing complete turn-block suffix; newest-block overflow = heading
      + UTF-8-safe body prefix. Never exceed cap.
- [x] CDT-215 detect miss → **fail-closed this Surface only** (no JSONL
      fallback). `/handoff` M3f miss path unchanged.
- [x] CDT-214 dirname → **`verbatim/`** inside the sid dir.
- [x] CDT-214 eligibility → **size-only**, UTF-8 `wc -c` of meaning
      payload **> 8192**.
- [x] CDT-214 vehicle → **skill CLI** `summarize-transcript.sh` (no
      `commands/*.md`). Seam `SUMMARIZE_TRANSCRIPT_CMD`.

## Cross-references

- **SPEC-002** — hook packaging, no pipes in hook commands, plugin-dir inside
  the script; recorder is user-owned, not a managed Additional Hook
- **SPEC-005 / init-orchestration** — greenfield Stop stays `stop-review` only
- **SPEC-012** — `hosts.py` locate + `freshness.sh`; no second parse engine.
  This ticket extends Grok cwd-bucket resolve (urlencode then `.cwd`).
  `/retro` behavior is unchanged beyond existing suite green.
- **SPEC-016** — store is global session-keyed, not `$MROOT` / worktree
- **SPEC-031** — subagent hooks carry **parent** `session_id`; child is
  `agent_id` (verified CC v2.1.212). Nest under parent sid, not a new sid.
- **SPEC-018** — STM packet / compact seed / PreCompact / M8 schema frozen;
  M3f MAY read `main.md` when `--check --sid` is `ok` (CDT-216). CDT-215
  `/compact-transcript` is a separate Surface (M14); M3f hit/miss and
  Test 40 stay unchanged. After M15 overlay, strip keeps summary text
  and drops `@verbatim/` refs. Miners MUST NOT read `verbatim/`. Bare
  sid identity = M10b `discover-warm.sh` line 1.
- **SPEC-021** — skill-bash lint on `SKILL.md` / `commands/*.md` fences;
  PDH stanza if any
- **SPEC-022** — `transcript.mirror_lag` (group `transcript`); WARN never
  FAIL; `--check` SoT; `EXPECTED_HOOK_*` frozen
- **SPEC-010** — docs-drift `cmd-index` / `docs-hub` / `docs-page-links`
  for `/compact-transcript` + `docs/commands/transcript-mirror.md`;
  bump-class B1–B6 (new `commands/*.md` ⇒ minor; M15 no new command ⇒
  patch)
