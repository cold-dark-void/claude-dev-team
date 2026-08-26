---
name: transcript-parse
description: Shared read-only parsing seam for host session transcripts (Claude ~/.claude/projects/*.jsonl; Grok ~/.grok/sessions/**/chat_history.jsonl). Locates a session's canonical file, host-normalizes to a gate-feed timeline, assembles a deduped chronological timeline, exposes parse primitives, and guards against mid-write files. Consumed by /handoff (SPEC-018) and /retro (SPEC-012).
---

# transcript-parse — shared transcript parsing seam

This skill is the **single source of truth** for reading host session
transcripts. Both `/handoff` (SPEC-018) and `/retro` (SPEC-012) share locate +
parse primitives + freshness here once, not duplicated per command
(SPEC-018 M1; SPEC-012 boundary).

**Hosts (CDT-156 MVP):**
- **claude** — `~/.claude/projects/<dash-encoded-cwd>/*.jsonl` (default; score-compatible)
- **grok** — `${GROK_SESSIONS_DIR:-~/.grok/sessions}/<urlencode(cwd)>/<sid>/chat_history.jsonl` (urlencode first; `.cwd` fallback)

**Adapter contract (CDT-156):** each host provides `locate` + `normalize` → a
**Claude-shaped JSONL gate feed** (stable `uuid` turn_ids, nested
`message.content`, user-wrapped `tool_result` with `is_error` when applicable).
`/retro` scores only the feed; it does not re-parse raw Grok layout. Handoff
MAY keep a skip-tool_result consumer path without requiring a SPEC-018 rewrite.

**Design rule — parse / normalize only, never score.** This module *locates*,
*normalizes host layouts*, *orders* messages, and *flattens* fields. It does
NOT score signals, distil, summarize, or rank. Consumers own all of that:

- `/retro` gate keeps its S1–S5 scoring local; it imports the flatten/field
  primitives but deliberately uses its **own** thinking-block policy (gate
  drops `thinking`; see `msg_text` note below).
- `/handoff` prepass keeps `toolUseResult` stripping, read-dedup, sidechain
  collapse (routine one-line / signal-bearing condensed multi-line via
  `SIDECHAIN_SIGNAL_CUES`), token budgeting, and chunking local.

## Files in this module

| File | Status | Provides | Consumers |
|------|--------|----------|-----------|
| `assemble.py` | **present** | CLI `locate` + `assemble` + `assemble-file` (Claude-only) | handoff prepass, retro Step 2 location, PreCompact capture |
| `hosts.py` | **present** (CDT-156) | Multi-host `locate`/`normalize` + CLI; `HOSTS=("claude","grok")` | retro discovery Step 2; handoff MAY wrap |
| `discover-host.sh` | **present** (CDT-156 T5) | Dual-host auto-detect: env pins → newest mtime; stdout `host=… session_id=… path=… source=…` | optional helper (same precedence as retro Step 2a); T4 inlines `hosts.py locate` equivalently |
| `grok_normalize.py` | **present** (CDT-156 T3) | Grok chat_history → Claude-shaped JSONL (`scoring` / `handoff`) | `hosts.normalize(host=grok)`; T8 handoff wrap |
| `parselib.py` | **present** | importable parse primitives | handoff prepass, retro gate |
| `freshness.sh` | **present** | 60 s mid-write guard (+ M14 carve-out) | handoff (M9), retro Filter-1, PreCompact (M14) |

Runtime: `python3` only (already required by retro-gate). No other deps. Every
entry point degrades with a clear error and a non-zero exit if `python3` is
absent — it must never traceback on a foreign or half-written file.

---

## `hosts.py` — multi-host adapter registry (CDT-156) — PRESENT

Single importable + CLI surface for host-scoped locate and normalize. `/retro`
MUST call this (not re-implement host discovery). Claude is score-compatible
identity; Grok locate is cwd-bucket (T2); Grok normalize is present (T3).

### Importable API

```python
HOSTS = ("claude", "grok")

def locate(
    host: str,
    session_id: str | None,
    cwd: str,
    *,
    sessions_dir: str | None = None,
) -> str | None:
    """Absolute source transcript path, or None if missing."""

def normalize(
    host: str,
    source_path: str,
    *,
    cwd: str,
    session_id: str,
    mode: str = "scoring",  # "scoring" | "handoff"
) -> str:
    """Absolute Claude-shaped gate-feed path."""
```

| Host | `locate` | `normalize` |
|------|----------|-------------|
| `claude` | `session_id` set → `assemble.locate(uuid)` (fork-aware, all projects); `session_id is None` → newest-mtime `*.jsonl` under `~/.claude/projects/<dash-encoded-cwd>/` | **identity** — returns `abspath(source_path)` for both modes (no score change) |
| `grok` | cwd-bucket under `GROK_SESSIONS_DIR`: urlencode path first, then `.cwd` fallback; by-id or newest `chat_history.jsonl`; honors `GROK_TRANSCRIPT_PATH` when under root | **present** — `grok_normalize.normalize_to_file` → TMPDIR Claude-shaped JSONL; scoring keeps `tool_result` + name map; handoff skips `tool_result` |

`sessions_dir` overrides the host root (Claude: projects dir; Grok: sessions
dir). Unknown `host` / `mode` → `ValueError`.

### CLI

```
hosts.py locate   --host claude|grok [--session-id SID] --cwd DIR [--sessions-dir DIR]
hosts.py normalize --host claude|grok --source PATH --cwd DIR --session-id SID [--mode scoring|handoff]
```

- `locate` success → absolute path on stdout, exit 0; not found → stderr + exit 1;
  unknown host / not implemented → stderr + exit 2.
- `normalize` success → absolute feed path on stdout, exit 0.

Verification:
`python3 -c "from hosts import locate, normalize, HOSTS; assert 'claude' in HOSTS"`
from this skill directory.

---

## `discover-host.sh` — dual-host auto-detect (CDT-156 T5) — PRESENT

Thin shell helper over `hosts.py locate` for SPEC-012 auto-detect / OQ2 when
`--host` is omitted. `commands/retro.md` Step 2a inlines the same precedence
via `hosts.py locate` (T4); this script is the extractable equivalent for tests
and other callers.

```
discover-host.sh [--cwd DIR] [--env-check]
# stdout: host=<claude|grok> session_id=… path=… source=…
# exit 0 found; 1 none; 2 usage/missing python3
```

Precedence:
1. `GROK_SESSION_ID` / `GROK_TRANSCRIPT_PATH` when resolvable
2. Claude env (`CLAUDE_CODE_SESSION_ID` | `CLAUDE_SESSION_ID` |
   `CLAUDE_TRANSCRIPT_PATH` | `TRANSCRIPT_PATH`) when resolvable
3. Newest mtime across Claude project dir + Grok cwd bucket for `--cwd`
   (`source=mtime`). Skipped when `--env-check` (env pins only).

Test overrides: `CLAUDE_PROJECTS_DIR`, `GROK_SESSIONS_DIR`.
Verify: `bash skills/transcript-parse/discover-host-test.sh` (dual-host trees).

---

## `assemble.py` — locate + fork-assembly (SPEC-018 M1) — PRESENT

Read-only. Streams files line-by-line; never `read()`s a whole transcript
(monsters are 70 MB+ and may be mid-write).

### CLI

```
assemble.py locate <uuid>
assemble.py assemble <uuid>
assemble.py assemble-file <path>
```

#### `locate <uuid>`
Print the **canonical transcript file** for the session and exit 0.

- *Canonical* = the **latest descendant**: among every file under
  `~/.claude/projects/*/` that contains the uuid, the one with the greatest
  maximum `timestamp`. "Contains the uuid" means the uuid is the file's name
  **stem** (`<uuid>.jsonl`) OR appears as some line's non-null `uuid` field.
- Ties on max-timestamp break by path (deterministic).
- Not found → message on **stderr**, **exit 1**, nothing on stdout.

Rationale: a fork copies its chosen-path prefix into the child file, so the
most-complete copy is the descendant with the latest content. We pick by
max-timestamp, **not** first match.

#### `assemble <uuid>`
Locate the canonical file, then stream **one raw-JSON message line per
surviving message** to stdout, in chronological order. Exit 0 on success;
**exit 1** if the uuid cannot be located (or the file vanished mid-read).

Pipeline (this is the authoritative M1 algorithm — validated against real
72 MB transcripts):

1. **LOCATE** the canonical file (above).
2. **LOAD** — stream it; a *message line* is one that parses to a JSON object
   with a **non-null `uuid`**. Null-`uuid` bookkeeping lines (`mode`,
   `custom-title`, `agent-name`, `last-prompt`, `file-history-snapshot`, and
   also-seen `permission-mode` / `queue-operation`) are **dropped** from the
   timeline. The non-null-uuid rule is generic, so new bookkeeping types need
   no code change.
3. **DEDUP** on `uuid`, **KEEP-LAST**: a later copy replaces the earlier
   payload + timestamp, but the **first-seen line index** is pinned for
   tie-breaking.
4. **ORDER** by `(timestamp, first_seen_index)`. NOT the `parentUuid` DAG
   (copy-duplication makes it multi-root/branchy); NOT raw file order (copied
   segments overlap in time).
5. **SIDECHAIN** — maximal contiguous runs where `isSidechain` is truthy are tagged
   (span begin/end logged to stderr) and passed through **unmodified**.
   Collapsing / signal-bearing reconstruction is the prepass's job (SPEC-018 M2 /
   CDV-205), not the parser's. In real data no line is ever a sidechain, so this
   is a defensive no-op. Detection uses the shared `parselib.is_sidechain`
   (`bool(obj.get("isSidechain"))`) — tolerant of the field being absent.

Output is exactly the input raw lines, reordered/deduped — fields are NOT
rewritten or stripped here (the prepass strips). One JSON object per line.

#### `assemble-file <path>`
Stream **exactly** the named transcript file — no `locate` over
`~/.claude/projects/`. Identical output contract to `assemble` (dedup
KEEP-LAST, timestamp order, per-line corrupt/truncated tail drop via
`_stream_message_lines`). Exit 0 on success (including zero surviving
messages after drop); **exit 1** if the path is missing/unreadable.

Consumed **ONLY** by the SPEC-018 M12 PreCompact capture path via
`prepass.sh prepare --transcript <path>`. The hook already names the live
file, so M1 locate is skipped. Mid-write truncated final lines are dropped
per-line — that is what makes PreCompact capture safe under M14.

### Hard guarantees (honor in any change here)

- **`forkedFrom` is PROVENANCE, never a cross-file pointer.** It is an object
  `{sessionId, messageUuid}` where `messageUuid` is **self-referential** (==
  the line's own `uuid`). There is intentionally **no cross-file message
  walk**: the fork's chosen-path prefix is already copied into the canonical
  file. Ancestor-only branches (paths forked away from) are excluded by
  design.
- **Stream only.** Files are opened once, iterated line-by-line. Never load a
  whole transcript into memory.
- **Per-line `try/except`.** A single corrupt / half-flushed line (common on a
  mid-write monster tail) is skipped, never fatal.
- **Schema-drift warning.** If none of `KNOWN_TOP_FIELDS`
  (`type, uuid, message, parentUuid, sessionId, timestamp`) appears in the
  first 50 parsed lines of a file, a `transcript-parse: WARNING …` is written
  to **stderr** via the shared `parselib.warn_schema_drift` helper (so
  `assemble.py` and any `parselib` consumer emit byte-identical text;
  `retro-gate/gate.sh` deliberately keeps its own `retro-gate:`-prefixed
  variant — see gate.sh's drift note). Stdout stays clean so it can be piped.
- **Tolerate missing files.** A referenced ancestor project/file that no
  longer exists is normal — `FileNotFoundError` / unreadable dirs are caught
  and skipped, never opened blindly, never fatal.
- **`python3` required.** Absent → clear stderr error, non-zero exit.

### Importable surface (for `parselib`/consumers)

`assemble.py` also exposes, for `import`:

- `locate(uuid) -> str | None` — canonical path or `None`.
- `assemble(uuid, out=sys.stdout, path=None) -> int | None` — writes the
  timeline to `out`, returns the count emitted, or `None` if not located /
  path missing. When `path` is given, locate is skipped (assemble-file mode).
- `KNOWN_TOP_FIELDS: set[str]` — shared schema-drift field set.
- `PROJECTS_DIR: str` — `~/.claude/projects`.

### Validated (against real data)

Monster `00000000-0000-4000-8000-000000000003` in
`~/.claude/projects/-home-user-vibes-project/` (~87 MB, mid-write):
`locate` resolves the file; `assemble | wc -l` = **3862** deduped lines from
**5542** raw lines; output verified strictly timestamp-ordered, zero duplicate
uuids, zero null-uuid leaks, no schema-drift/sidechain warnings. Unknown uuid →
exit 1 with a clear stderr message.

---

## `parselib.py` — parse primitives (SPEC-018 M2 helpers) — PRESENT

Importable, no CLI. Lifted from the inlined helpers in
`skills/retro-gate/gate.sh` so both consumers share one definition. **Contract**
(derived from spec + plan §"Shared parser seam"):

| Symbol | Signature | Contract |
|--------|-----------|----------|
| `msg_text` | `msg_text(content) -> str` | Flatten a message `content` (str, or list of blocks) to a single string. **KEEPS `thinking` blocks** (handoff M4b needs hypothesis-rejection reasoning). `text` and `thinking` block `text` are joined by `\n`; non-text blocks (tool_use, tool_result, image…) skipped. **Differs from gate.sh's local `msg_text`, which drops `thinking` on purpose** — the gate keeps its thinking-skip at the call site, NOT in this lib. |
| `KNOWN_TOP_FIELDS` | `set[str]` | Same set `assemble.py` exposes: `{type, uuid, message, parentUuid, sessionId, timestamp}`. |
| `is_edit_tool` | `is_edit_tool(name) -> bool` | True for `Edit`, `Write`, `MultiEdit`, `NotebookEdit`. |
| `edit_file_path` | `edit_file_path(tool_input) -> str | None` | Extract the edited path (`file_path`/`notebook_path`) from a tool-use input; `None` if absent. |
| `is_meta` | `is_meta(obj) -> bool` | True for a meta/system bookkeeping line (e.g. `isMeta is True`). |
| `is_sidechain` | `is_sidechain(obj) -> bool` | `bool(obj.get("isSidechain"))` — truthy test, tolerant of the field being absent (returns False). |
| `SIDECHAIN_SIGNAL_CUES` | `tuple[str, ...]` | Closed cue list for signal-bearing sidechain detection (CDV-205 / SPEC-018 M2). Single source of truth — prepass imports this; do not scatter cue strings. |
| `sidechain_cue_hit` | `sidechain_cue_hit(text) -> (cue, line) \| None` | First case-insensitive substring hit from `SIDECHAIN_SIGNAL_CUES`; returns `(cue, matching_line)` or `None`. |
| `sidechain_is_signal` | `sidechain_is_signal(texts) -> bool` | True if any text in the iterable hits a cue (MVP: ≥1). |
| `is_tool_result` | `is_tool_result(obj) -> bool` | True if the **line dict** (as returned by `parse_line` / `iter_lines`) carries a `tool_result` block inside `obj["message"]["content"]`. Accepts a full line object, not a raw content list. Returns False on missing/unexpected structure. |
| `schema_drift_warn` | `schema_drift_warn(path) -> None` | Stream the file's first 50 lines; if no `KNOWN_TOP_FIELDS` seen, write the same `transcript-parse: WARNING …` to stderr. |
| `iter_lines` | `iter_lines(path, schema_drift_check_n=50) -> Iterator[(int, dict)]` | Yield `(line_no, dict)` for every valid JSONL line in `path`. Handles schema-drift detection automatically after the first `schema_drift_check_n` lines. Uses UTF-8 with replacement for robustness on files with stray bytes. Skips blank/unparseable lines. |

Notes:
- Keep these **pure parse helpers** — no scoring, no I/O beyond
  `schema_drift_warn`'s stderr.
- Real message IDs are **UUIDs, not `msg_`** — do not add any `msg_`-prefix
  regex.
- Importable both as `from parselib import msg_text, …` (when
  `skills/transcript-parse/` is on `sys.path`) and from gate.sh's embedded
  python (which points here).

Verification gate:
`python3 -c "from parselib import msg_text; print(msg_text([{'type':'thinking','text':'x'},{'type':'text','text':'y'}]))"`
→ output includes **both** `x` and `y`.

---

## `freshness.sh` — mid-write guard (SPEC-018 M9 / SPEC-012 Filter-1) — PRESENT

POSIX sh. **Contract:**

```
freshness.sh check <path> [--allow-in-progress]
```

- Compute the file's mtime age. If modified **< 60 s ago** (in-progress
  write), print a warning to **stderr** and **exit 9** (decline to parse
  mid-write).
- Fresh enough (≥ 60 s) → **exit 0**, silent on stdout. Missing file → exit 1.
- Portable mtime: support **both GNU** (`stat -c %Y`) **and BSD/macOS**
  (`stat -f %m`) `stat`.

**SCOPED CARVE-OUT (SPEC-018 M14):** a PreCompact capture is by definition
mid-write. Passed EXCLUSIVELY by `skills/handoff/precompact-capture.sh` via
`prepass.sh prepare --allow-in-progress`. No user-invoked path (`/handoff`
cold, `/retro`) passes it — default guard behavior (exit 9) is unchanged.
With the flag: mtime < 60 s → NOTE on stderr, **exit 0** (warn-and-proceed).

Exit codes are the API: `0` = ok to parse, `9` = too fresh (caller warns +
declines). Consumed by the handoff prepass (M9 → warn + stop) and the retro
location/Filter-1 path.

Verification gate: `freshness.sh check` on a just-`touch`ed
file → **exit 9**; same + `--allow-in-progress` → **exit 0**.

---

## Consumer wiring (informational)

- **/handoff prepass** (`skills/handoff/prepass.sh prepare`):
  `freshness.sh check` (exit 9 → warn+decline) → `assemble.py assemble` →
  strip `toolUseResult` → dedup repeated reads → collapse sidechains (noise
  one-line / signal multi-line via `SIDECHAIN_SIGNAL_CUES`) → token budget →
  spine or chunk manifest. `source_files` is the single canonical file (no
  cross-file engine).
- **/retro**: gate.sh imports `parselib` primitives (keeps its own
  thinking-skip + S1–S5 scoring local); `retro.md` Step 2 resolves host →
  adapter `locate` + `normalize` → `gate.sh` on the Claude-shaped feed;
  Filter-1 freshness via `freshness.sh check` on the **source** path (Claude
  JSONL or Grok `chat_history.jsonl`). Claude default remains score-compatible
  with pre-CDT-156 fixtures.

### Grok normalize notes (scoring path, CDT-156)

Implemented in `grok_normalize.py` (called from `hosts.normalize(host="grok")`).

- Skip `system` / `reasoning` / `backend_tool_call` for the gate feed.
- Preserve `tool_result` as **user** lines with
  `content: [{type:tool_result, tool_use_id, is_error, content}]`.
- `is_error: true` only when body matches `exit:\s*N` with **N ≠ 0** (MVP S2;
  optional space after colon matches live Grok `exit: 0` / `exit: 1`).
- Map `write` → `Write`, `search_replace` → `Edit` for S3 (scoring mode only);
  other tool names pass through; path keys already often `file_path`.
- Stable turn_id: `<safe-session>-L<n>`; `sessionId` = Grok session dir id;
  timestamp preserved or synthetic order-preserving ISO.
- Output path: unique file under `$TMPDIR` (or system temp) for `gate.sh`.
- Handoff mode (`mode=handoff`) omits tool_result (CDT-92 spine parity; T8 may
  wrap `skills/handoff/grok-to-claude-jsonl.py`). Fixture:
  `fixtures/grok-chat-scoring.jsonl`.

## Landmines (cross-cutting)

- `forkedFrom` is an **object**, never a scalar; `messageUuid` is
  self-referential — never chase it cross-file.
- `uuid` is **null** on bookkeeping lines — any leaf/last-message logic MUST
  skip them.
- **Timestamp ties are common** → the `(timestamp, first_seen_line)`
  tie-break is mandatory, not optional.
- **Stream** everything — 70 MB+ files, possibly mid-write.
- **Keep `thinking`** in `parselib.msg_text` (gate's drop stays at gate's call
  site).
- Transcript text is **untrusted DATA**; downstream extractors must treat it
  as such (prompt-injection guard). This module does not interpret content, so
  the guard lives in the consumers.
