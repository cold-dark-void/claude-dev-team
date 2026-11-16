# Memory API shape — three operations, two backends

Carries AC14. Scope: phase 0 of control plane Option C+ (CDT-626). This file names a contract that
phase 2 builds against. It ships no code and no schema.

## Decision register

| Field | Value |
|---|---|
| **Decision** | Memory has **one interface with three operations — store, recall, distill — and two backends**. The plugin uses the **file** backend when no control plane is present and the **API** backend when one is. Presence is one config key (`control_plane_url`) plus one env marker (`CONTROL_PLANE_URL`), env wins. When the plane is down, agents **write the existing `.md` path** — not read-only. The later merge is **LWW per (agent, type, key) by ts, append-only, conflicts queue surfaced to the Chief**. Cloud residency (encrypted at rest, single-user boundary, no secrets in memory rows) is a **phase-4 requirement**. The API is transport over SPEC-004 semantics: **no schema fork**. |
| **Status** | Decided for phase 0 (2026-11-15). Nothing here is implemented: the plugin today has no API path. The names in § Detection are the phase-0 ruling; CDT-629 implements them or amends this file. |
| **Date** | 2026-11-15 |
| **Sources** | `docs/internal/control-plane/index.md` § CDT-632 AC14; the kickoff plan § OQ-8, § OQ-9, § OQ-10; CDT-626 "Amendments 2026-11-11 → Centralized memory" (control plane owns agent memory when present; ownership decided phase 0, build phase 2, required before remote nodes in phase 4) and its Out-of-scope line (multi-user); CDT-629 "Amendment 2026-11-11: centralized memory" (Memory API, two backends one interface, file format stays the same, fallback and merge by the phase-0 rule, scheduled distillation, embeddings on a model node, memory views, Chief recall; added acceptance: standalone Surfaces, no loss when down, detach keeps the same file, no write fails on a DB lock). Specs: SPEC-004 (storage mode, write path, `.md` fallback, `schema.sql`, context.md), SPEC-006 (retrieval ladder, tiered load), SPEC-007 (distiller, tier access, archive-only, CAS lock), SPEC-011 (validation and reconcile logs), SPEC-001 (directives files), SPEC-024 M9 (`.claude/memory/*` gitignore child glob), SPEC-022 M1/M2j/M3 (`/doctor`), SPEC-033 § AC9 (env-over-source precedence), SPEC-036 M6 (cursor as rebuild anchor), SPEC-037 M11 (gitignored local settings layer), SPEC-039 M11 (byte-identical off) and M33 (`require-agent.sh --memory`). Code: `skills/lib/require-agent.sh`, `skills/memory-store/memdb.sh`, `skills/memory-store/schema.sql`, `skills/memory-store/migrate-md.sh`. `docs/adr/0001-journal-engine.md` § The narrow-interface boundary; `docs/internal/control-plane/record-ownership.md` rows 5, 10 and § The closed conflict-rule set; `.gitignore:14`. |
| **Phase effect** | Phase 2 (CDT-629) implements the API backend, the detection rule, the degraded-mode write, the drain, and the merge, and adds the `.gitignore` line for the local settings file it reads. Phase 4 (CDT-631) carries the residency requirements in § Cloud residency; centralized memory is a precondition of remote nodes (CDT-626 amendment). Phase 0 changes no file the plugin reads. |
| **Residual items** | The node-agent CLI path and flag names are CDT-629's (§ Detection, note 5). The degraded-mode line-limit rule (§ Down fallback, note 3) needs a SPEC-004 amendment at CDT-629. The conflicts-queue path is a phase-0 name; the row enters `record-ownership.md` when CDT-629 gives it a writer. `metadata_json` as the transport-field home rests on the seed-pack precedent (`import-seed-pack.sh`); CDT-629 proves it on the drain path. The Chief's recall scope across projects is undefined until phase 2 picks one instance per project or one switchable instance (CDT-629 goal 4). |

## What this file decides

| # | Decision | Section |
|---|---|---|
| D1 | Three operations: store, recall, distill. Each runs the roster check. | § The three operations |
| D2 | Two backends, one interface: file when no plane, API when there is one. The control plane is the only memory writer in API mode. | § The two-backend rule |
| D3 | Presence = one config key (`control_plane_url`) + one env marker (`CONTROL_PLANE_URL`). Env over file. | § Detection |
| D4 | Plane down = write to `.md`, not read-only. One writer per backend; no double write. | § Down fallback |
| D5 | Merge = LWW per (agent, type, key) by ts, append-only, conflicts queue surfaced to the Chief. | § Merge rule |
| D6 | No schema fork. The API is transport over SPEC-004 semantics. | § No schema fork |

Out of scope: the API's wire format, auth, the node-agent CLI names, the memory views in the UI,
and the scheduled-distillation batch sizes. CDT-629 owns those. This file constrains them.

## Two axes — read this before the tables

Two independent detections exist. Do not conflate them.

| Axis | Question | Values | Owner |
|---|---|---|---|
| **Backend** | Who owns memory state: the local file or the control plane? | `file` \| `api` \| `degraded` | This file (D2, D3) |
| **Storage** | How does the file backend persist: SQLite or `.md`? | SQLite \| `.md` | SPEC-004 § Storage Mode Detection (unchanged) |

The storage axis does not change. SPEC-004 keeps detecting on `memory.db` presence plus `sqlite3`
availability. The backend axis is new. Three states are reachable: API, file+SQLite (today's
normal), file+`.md` (today's fallback). The presence of `memory.db` is never evidence that a
control plane exists, and a control plane is never evidence that `sqlite3` exists.

## The three operations (D1)

The interface has three operations. Each is a thin name over a protocol that already exists, so
each operation has one owner spec and one owner surface.

| Op | Inputs | Reads/writes | Today's owner | API-mode owner |
|---|---|---|---|---|
| **store** | `agent`, `type`, `content`, provenance | append one focused fact | SPEC-004 § SQLite Write Path and § `.md` Fallback Path; `skills/memory-store/memdb.sh write` | control plane (node agent relays) |
| **recall** | `query`, optional `agent`, `type`, tier and archive filters | read; returns rows, never mutates | SPEC-006 (tiered load, semantic → keyword → grep) | control plane; Chief recall spans all agents |
| **distill** | `agent`, tier floor, batch size | tier 0 → 1 → 2 transitions, archive of sources, audit log | SPEC-007 (`/memory distill`, `@distiller`, CAS lock) | control-plane job in bounded batches (CDT-629) |

Rules that bind all three:

- **One writer per backend.** In API mode the control plane is the only writer (CDT-629). The
  plugin never writes the local store and the API in the same call.
- **Reads never hard-fail.** A session-start load that cannot reach the plane degrades to the
  `.md` path and prints one line. It never blocks a session.
- **No lock failures on the write path.** In file mode SPEC-004 keeps `busy_timeout=5000` plus one
  retry. In API mode there is no local database lock, so CDT-629's acceptance line — parallel
  agents never fail a memory write on a database lock — holds by construction.
- **The write result is confirmed.** SPEC-004's read-back rule stays: a store returns the id it
  wrote, and a store that cannot confirm reports failure to the caller. Silent success is banned.

### store

```bash
# Roster gate first — before any transport, in both backends (SPEC-039 M33).
bash "$PDH/skills/lib/require-agent.sh" --memory "$AGENT" || exit 64
```

File mode: unchanged. `memdb.sh write` (bound `?`, busy timeout, read-back), best-effort embed
through `embed-one.sh`, or the `.md` append when SQLite is unavailable (SPEC-004).
API mode: the call is relayed to the node agent. Embeddings are computed once, on a node that has
the model (CDT-629), so the writer-side plugin runs no embedding step.
Degraded: the `.md` append (D4).

### recall

```bash
bash "$PDH/skills/lib/require-agent.sh" --memory "$AGENT" || exit 64   # per --agent filter
```

`--agent` is optional. When it is present, it is a roster name; the check runs once per requested
agent value. An unfiltered recall (Chief recall) spans all agents, and `advisor` rows are in scope
(SPEC-039 M33). File mode keeps the SPEC-006 ladder: semantic → keyword → grep, tier-2 → tier-1 →
non-archived tier-0, `archived = TRUE` never returned. API mode asks the plane and returns the same
row shape. Degraded mode is the ladder's existing grep tier over `.md`, plus the local mirror if
one exists. No new mode name is added to SPEC-006.

### distill

```bash
bash "$PDH/skills/lib/require-agent.sh" --memory "$AGENT" || exit 64   # target agent, not the distiller
```

The roster check runs on the **target** agent, because digest rows carry the target agent's name;
`distiller` is not a roster name and never reaches this check. `--memory` is required so advisor
memories are distillable (SPEC-039 M33 names `/memory distill`). Tier access control is unchanged:
only `@distiller` sets `tier > 0` (SPEC-007). File mode keeps the SPEC-007 CAS lock; API mode turns
that lock into the job lease on the batch, and each batch is verified for provenance (CDT-629).
Archive-only is unchanged: distillation never deletes (SPEC-007).

## The roster check (all three operations)

Every operation validates `--agent` before it reaches transport, SQL, or a shell string:

```bash
bash "$PDH/skills/lib/require-agent.sh" --memory "$AGENT"
```

- Admitted set: `pm`, `tech-lead`, `ic5`, `ic4`, `devops`, `qa`, `ds`, plus `advisor` under
  `--memory` (SPEC-039 M33). Anything else exits 64 and writes nothing.
- The default (no `--memory`) form stays the 7-name gate. Memory tooling MUST use `--memory`,
  because the API admits advisor rows (SPEC-039 M33 names memory-store, `/memory distill`,
  `/doctor`).
- `/adjust-agent`'s directives dashboard MUST NOT list `advisor` (SPEC-039 M33). The memory API
  admits advisor; the directives surface does not.
- The API inherits this rule server-side. A request whose agent fails the same check is rejected
  before it reaches the store, with exit 64 semantics.

## The two-backend rule (D2)

**Decision: the memory skills use the local file when there is no control plane, and the API when
there is one. The interface and the file format stay the same, so every Surface works standalone.**

| Backend | Writer of memory state | Local `memory.db` | Reader path |
|---|---|---|---|
| `file` (no plane) | the plugin, per SPEC-004 | authoritative store | today's path, byte-identical (precedent SPEC-039 M11, byte-identical off) |
| `api` (plane present and reachable) | the control plane, exclusively | a **mirror** only — a `derived-rebuild` record in the `record-ownership.md` closed set | API for recall; the mirror exists so a detach keeps working |
| `degraded` (plane named, unreachable) | the plugin, into `.md` | not written in this mode (see D4) | `.md` first, then the mirror |

Consequences, stated:

- **Detach is a rebuild, not a merge.** CDT-629 requires that a user can detach and continue with
  the same memory file. In API mode the mirror is rebuilt from the plane by export, the same
  `derived-rebuild` rule the transcript mirror uses (SPEC-036 M6, `record-ownership.md` row 10).
  A stale mirror is repaired by re-running the export, never by hand-merging.
- **One interface, so no second code path in Surfaces.** A Surface calls store, recall, or distill.
  It never branches on the backend itself, except to print which one is in use.
- **The plane owns the record, the plugin owns the file.** `record-ownership.md` row 5 keeps
  `memory.db` plugin-owned in the file backend. The API's server-side state is a separate
  `control-plane-only` record, added to that table by CDT-629.

## Detection — "control plane present" (D3, OQ-8)

Phase 0 names the rule. **Phase 2 (CDT-629) implements it.** One config key and one env marker, and
nothing else.

| Signal | Name | Where | Writer |
|---|---|---|---|
| **Env marker** | `CONTROL_PLANE_URL` | the environment of a spawned host CLI | the node agent, when it starts a run (CDT-626: the control plane starts host CLIs headless) |
| **Config key** | `control_plane_url` | `$MROOT/.claude/dev-team/config.json`, project-local, gitignored | the node-agent register step, once per project |

Resolution: **env over file**, matching SPEC-033 § AC9's env-first shape and SPEC-037 M11's
first-hit-wins rule. A marker is present when the variable is set and non-empty. Precedence chain:

```bash
# Phase-2 implementation shape. Phase 0 fixes the names and the order.
PLANE_URL="${CONTROL_PLANE_URL:-}"
URL_SOURCE=env
if [ -z "$PLANE_URL" ] && [ -f "$MROOT/.claude/dev-team/config.json" ]; then
  PLANE_URL=$(jq -r '.control_plane_url // empty' "$MROOT/.claude/dev-team/config.json" 2>/dev/null || true)
  URL_SOURCE=file
fi
case "$PLANE_URL" in
  http://*|https://*) : ;;
  *) PLANE_URL=""; URL_SOURCE=none ;;   # absent, malformed, or unparseable file: treat as no plane
esac
if [ -z "$PLANE_URL" ]; then
  BACKEND=file                                  # standalone: today's behavior, byte-identical
elif ! command -v node-agent >/dev/null 2>&1; then
  BACKEND=degraded                              # plane named, no node agent on this node
elif node-agent memory ping --url "$PLANE_URL" --timeout-ms 2000 >/dev/null 2>&1; then
  BACKEND=api
else
  BACKEND=degraded
fi
printf 'backend=%s url_source=%s\n' "$BACKEND" "$URL_SOURCE"
```

Notes that bind the implementation:

1. **One config key, one file, one layer.** No global layer and no per-worktree layer. The plane is
   project-scoped (CDT-626), and `$MROOT` is the project scope. CDT-629 adds the `.gitignore` entry
   for the file, next to `.gitignore:41-43` (the model-map local layer).
2. **The key is not in `memory.db`.** The `config` table cannot select its own store. Bootstrap
   order is: read the key → pick the backend → open the store.
3. **The value is untrusted input.** Accept only `http://` or `https://` with no whitespace.
   Anything else is treated as absent. The URL is passed as argv (`--url "$PLANE_URL"`), never
   eval'd, never interpolated into a SQL string, never into a command string built by concatenation
   (AGENTS.md untrusted-input rule).
4. **The probe has a deadline, on every path.** One attempt, bounded by `--timeout-ms 2000` on the
   node-agent call. No plugin-side retry loop, so no `continue` without a deadline. The plugin runs
   no `timeout(1)` — macOS has none (bash 3.2 portability, CDT-502); the deadline belongs to the
   callee. Cache the probe result for the session, and re-probe on the next session: a plane that
   dies mid-session is caught by rule 5, not by re-probing on every fence.
5. **Probe-then-write is a race, so the write path re-degrades.** The plane can drop between the
   probe and the write. A store that the API rejects MUST fall through to the `.md` write in the
   same call, and MUST report which backend accepted the write. It MUST NOT report success on a
   failed API write, and MUST NOT re-throw the failure as a lost memory.
6. **What is NOT the rule.** `memory.db` presence (that is SPEC-004's storage axis), `sqlite3`
   availability, `$CLAUDE_PLUGIN_ROOT`, a `.control-plane/` directory probe, a lock file, a
   `curl` to a port, and `git remote` naming. Naming these keeps phase 2 from inventing a second
   rule.
7. **Zero-behavior default.** No marker and no key is the normal state of every checkout today.
   In that state the plugin behaves byte-identically, per the SPEC-039 M11 precedent.

## Down fallback (D4) — the explicit decision

**Decision: when the control plane is present in configuration and unreachable, agents write the
existing `.md` path. The plugin does not run memory in read-only mode.**

This is the CDT-629 acceptance line "No memory is lost when the control plane is down" made
concrete. Read-only-while-down was the rejected option: it drops writes, which is the loss CDT-629
forbids, and it fails every agent's write path at the worst moment.

| Operation | Degraded behavior |
|---|---|
| store | Append to `$MROOT/.claude/memory/<agent>/{cortex,memory,lessons}.md` — SPEC-004 § `.md` Fallback Path, unchanged format. No embedding, no DB write, one line to stderr naming the mode. |
| recall | Grep over `.md`, plus the local mirror if present. Semantic search is unavailable: embeddings live with the plane in API mode (SPEC-006's ladder degrades, it does not fork). |
| distill | No-op with a named message. SPEC-007 requires a SQLite DB, so distillation does not run against `.md`. The tier-0 pile grows; the plane's scheduled distillation (CDT-629) absorbs it after the drain. |

Notes:

1. **One writer, not two.** A degraded write goes to `.md` only. It never also writes
   `memory.db`: that would make the plugin a second writer of the plane's record and would create a
   merge problem that CDT-629 does not need.
2. **The `.md` file is a durable spool.** It is the input to the drain in § Merge rule. Agents keep
   writing it with the append-only discipline SPEC-004 sets.
3. **No trim while degraded.** SPEC-004's line limits (cortex 100, memory 50, lessons 80) are
   enforced by trimming, and trimming an undrained spool deletes notes the plane has never seen. In
   degraded mode the writer MUST NOT trim past the limit; the limit is re-applied after the drain,
   where the store has no line limit. CDT-629 carries this as a SPEC-004 amendment.
4. **The drain runs on reconnect, under a lease.** One drainer per project, so a reconnect does not
   apply the same spool twice. The lease is the `single-writer-lease` rule of the closed set in
   `record-ownership.md`; the drain consumes a spool file by rename before it applies it.
5. **Degraded is visible.** A store in degraded mode prints `memory: control plane unreachable —
   appended to .md (drain pending)`. The pending count surfaces in `/memory stats` and as a
   `/doctor` check (SPEC-022 M2j shape: WARN, never FAIL, read-only).

## Merge rule (D5, OQ-9)

**The rule, verbatim: LWW per (agent, type, key) by ts, append-only, conflicts queue surfaced to
the Chief.**

Binding detail, all of it inside that rule:

**Key space.** `key` is the record's stable identity inside (agent, type). It is not a new column:
each key below is data SPEC-004 already carries, or a file-unit record that is not a memory row.

| Record class | (agent, type) | `key` | `ts` |
|---|---|---|---|
| Existing memory row | agent, one of `cortex`/`memory`/`lessons`/`digest`/`core` | the row id — server-assigned in API mode, local rowid in file mode | `updated_at` (SPEC-004, UTC ISO-8601 seconds) |
| New note from a degraded `.md` write | agent, the file's type | `md-<first 12 hex of sha256 of the note body>` — minted at drain, so a fresh note never collides | file mtime at drain, rendered in the same UTC format |
| Directives file | agent, `directives` | `file` — the whole file is the unit, because `/adjust-agent` Step 6f rewrites it whole (SPEC-001) | file mtime |
| Config key | no agent, `config` | the `config.key` string (SPEC-004 config table) | `config.updated_at` |
| `context.md` | — | **not merged.** Per-worktree and never in the store (SPEC-004) | — |

**Drain algorithm** (per record in the spool, one drainer under the lease):

1. Compute `(agent, type, key, ts, content)`. Chunking, the 8000-char cap, and the skip-under-20
   rule are SPEC-004's `.md` → SQLite migration rules, so the drain reuses tested behavior.
2. Key absent on the plane → insert. This is the common case, and it is append-only.
3. Key present, content identical → skip. This makes the drain idempotent, per SPEC-004's
   "check existing row count before re-inserting".
4. Key present, spool `ts` strictly newer → **LWW**: apply the spool content, and archive the
   superseded row (`archived = TRUE`). Never delete (SPEC-007: archive only).
5. Key present, both sides changed since the common ancestor → **conflict**. Keep both rows, apply
   neither, and append one record to the conflicts queue. Equal `ts` is a conflict of this kind,
   with the plane row marked the survivor for read paths (the plane clock is authoritative for a
   single-user boundary).
6. A whole-file record (directives) uses steps 2-5 with `key = file`. Two edits of one agent's
   directives, one in a terminal and one in the UI, are the expected conflict case.

**Append-only, stated twice because it is the safety property:** the merge never deletes a record
and never rewrites one in place. A merge loser is archived, and the spool file is consumed by
rename. A drain deletes a spool file only when every record in it applied — SPEC-004's rule for the
`.md` → SQLite migration ("MUST delete source .md files ONLY if all inserts succeeded") — so a
drain that fails partway leaves the spool intact and re-runs from the same state (idempotent by
step 3).

**Conflicts queue.** Phase-0 name: `$MROOT/.claude/memory/.merge-conflicts.jsonl` — one JSON object
per conflict (agent, type, key, both ids, both `ts`, drain run id), append-only, git-ignored by the
`.claude/memory/*` child glob (`.gitignore:14`, SPEC-024 M9). The shape follows the decision-card
and sweeps-journal precedent (SPEC-033 M13, SPEC-040 M20) and CDT-626's constraint that the control
plane reads plugin state through files. Surfacing:

- The Chief reads the file. Its memory views (CDT-629) show open conflicts, and the user resolves
  them in the UI, which is the CDT-629 "correct and archive" surface.
- `/memory stats` prints the open count — a count, no content, per the anonymized rule.
- `/doctor` carries a `memory.merge_conflicts` check: WARN when the count is non-zero, never FAIL,
  read-only, one fix-it that names the file (SPEC-022 M2j, M3).

## No schema fork (D6)

The API is transport over SPEC-004 semantics. The floor it must not cross:

- `schema_version` stays **4** (SPEC-004, `skills/memory-store/schema.sql`). This decision adds no
  migration and no `migrate-v5.sh`.
- No new table, no new column, no new index in `memories`. No new `type` value beyond
  `cortex`/`memory`/`lessons`/`digest`/`core`. No new `tier` value beyond 0, 1, 2. `archived`,
  `distilled_from`, `validated_at`, `archive_reason` keep their SPEC-004 meanings.
- No new distill config keys. `/memory config`'s settable set is unchanged (SPEC-007).
- `context.md` never crosses the interface (SPEC-004 MUST NOT migrate it).
- The `.md` file format is unchanged, which is CDT-629's own line ("The file format stays the
  same") and the reason detach and standalone keep working.
- **Transport fields ride `metadata_json`.** The origin backend, the node id, the ts source, and
  the drain run id go in the existing `metadata_json` column, which is SPEC-004's provenance
  extension point (SPEC-024 M5 uses it for seed-pack provenance). This is the mechanism that keeps
  D5's merge keys from becoming columns.
- Directives and config are **record classes, not memory rows**. Directives stay files under
  `$MROOT/.claude/memory/<agent>/` (SPEC-001, gitignored), and config keys stay in the `config`
  table. The interface carries them; it does not move them into `memories`.
- The conflicts queue and the local mirror are plugin-side records, not memory state. They enter
  `record-ownership.md` as rows when CDT-629 gives them writers.

The boundary holds: the plugin calls the node agent through a CLI call with argv, and it opens no
socket to the control plane (ADR 0001 § The narrow-interface boundary). The node agent owns
transport, auth, and retries (CDT-626 amendment: every node runs a node agent, and the control
plane talks only to the node agent).

## Per-Surface standalone table

Every Surface in the first column works with no control plane present. CDT-626 goal: "Every
existing Surface still works standalone in a terminal."

| Surface | No control plane (today, unchanged) | Plane present (`api`) | Plane down (`degraded`) |
|---|---|---|---|
| `/memory search` | SPEC-006 ladder: semantic → keyword → grep | API recall, same row shape | grep over `.md`, plus the mirror; prints the degraded line |
| `/memory stats` | counts and sizes from `memory.db`; no DB → the "run `/setup team`" notice | counts from the API; content still never printed | counts from the mirror when one exists, else the no-DB notice plus the pending-spool count |
| `/memory config` | reads and writes the `config` table in `memory.db` | config keys are memory state: read and write through the API | reads the local mirror; a write is refused with a named reason — a refused config write is not a lost memory |
| `/memory distill` | `@distiller` under the SPEC-007 CAS lock | control-plane job, bounded batches, provenance-checked; `/memory distill` becomes a trigger and a status view | no-op with a named message (SPEC-007 requires SQLite); pending count surfaces |
| `/memory export` | sanitized tier-2 seed pack (SPEC-024) | tier-2 rows read through recall; the same sanitizer and the same floor warning | exports from the mirror; the same sanitizer |
| `/memory validate [--reconcile]` | SPEC-011 logs into `memory.db` | verdicts written through the API as memory-state writes | deferred with a named message; the validator reads `.md` and reports that it wrote nothing |
| `/setup team` | doctor gate, creates `memory.db`, schema migration, extension download, `.md` migration, `.gitignore` check, seed-pack import, `@project-init` | registers the project with the plane; MUST NOT create a competing authoritative store; extension download is skipped when a model node computes embeddings (CDT-629) | runs the standalone path in full — a plane that is down is indistinguishable, at bootstrap, from a machine that never had one |
| `/adjust-agent` | writes `$MROOT/.claude/memory/<agent>/directives.md`; `--model`/`--effort` write the local Model map (not memory) | directives read and write through the API; the file becomes a `derived-rebuild` mirror | writes the file directly (D4); the drain merges by LWW with `key = file`, and a both-sides edit becomes a conflict record |
| `advisor` memory | `require-agent.sh --memory` gates writes; `/doctor` reports advisor memory present / empty / n/a | same gate, API transport; advisor rows are in Chief recall scope | `.md` path at `$MROOT/.claude/memory/advisor/`, drained like every agent |
| `@distiller` (internal) | `sqlite3` CLI only, tier 0 → 1 → 2, archive-only, `distillation_log` | runs as the plane's job; the CAS lock becomes the batch lease | does not run (SPEC-007 requires a DB); no `.md` distillation path is invented |
| `/doctor` (reader) | read-only memory stack checks (SPEC-022 M1, M2b, M2j) | adds the backend in use, the mirror age, and the open-conflict count — all read-only | WARN on a non-zero pending-spool count, never FAIL |

## Cloud residency — phase-4 requirement (OQ-10)

Recorded as a requirement on phase 4 (CDT-631), where memory state leaves the maintainer's machine.
Centralized memory is a precondition of remote nodes (CDT-626 amendment), so these three rows gate
that phase.

| # | Requirement | Boundary of the requirement |
|---|---|---|
| R1 | **Encrypted at rest.** Every memory row, its embedding, and the directives mirror are encrypted at rest in the cloud deployment. | Covers the volume, the database file, snapshots, and backups. In transit stays TLS. Phase 4 names the mechanism (volume-level or engine-level); the requirement is the property, not the tool. |
| R2 | **Single-user boundary.** One human's memory. No shared, tenanted, or per-user-scoped memory. | CDT-626 puts multi-user out of scope. A remote node is that same user's machine, not another person's. A second user is a new decision, not a config change. |
| R3 | **No secrets in memory rows.** Memory content MUST NOT carry credentials, tokens, API keys, private keys, cookies, or password material. | The writer enforces it before the row leaves the node, and the plane re-checks on store. Precedents: the seed-pack sanitizer is "a floor, not a guarantee" (SPEC-024, `/memory export`), and `.errors.log` stays out of git because it can quote memory content (SPEC-004). A row that carries a secret is scrubbed at write time and the scrub is logged as a count, not as content. |

Residency notes for phase 4: R1-R3 are the phase-0 ruling; CDT-631 writes the implementation
documentation CDT-626 requires per phase. Phase 2 and phase 3 keep memory on the maintainer's
machine, so R1-R3 bind at the phase-4 boundary, not before. Region and provider selection are
phase-4 work and are not decided here.

## Phase hand-off

- **CDT-629 (phase 2)** implements, in this order: the two-name detection of D3, the degraded
  `.md` write, the mirror as `derived-rebuild`, the leased drain, LWW merge, the conflicts queue
  and its surfacing, scheduled distillation as a job, Chief recall, and the memory views. It
  carries the SPEC-004 amendment for rule 3 of § Down fallback, and the `.gitignore` line for
  `$MROOT/.claude/dev-team/config.json`.
- **CDT-628 (phase 1)** touches none of this file. The journal is not memory: it is
  control-plane-owned, git-ignored, and never in `memory.db` (ADR 0001 § The narrow-interface
  boundary; `record-ownership.md` invariant 2).
- **CDT-631 (phase 4)** carries R1-R3.

## Residual items

1. Node-agent CLI path and flag names are CDT-629's. The `node-agent memory ping` shape in §
   Detection is a shape, not a name.
2. The no-trim rule for degraded mode needs a SPEC-004 amendment. Until it lands, a long degraded
   period can trim notes, so degraded periods are expected to be short.
3. `metadata_json` as the transport-field home has one working precedent and no proof at scale.
   `import-seed-pack.sh` writes provenance into it (`$.seed.hash`) and indexes it with
   `json_extract` (SPEC-024 M5). `memdb.sh write` and `migrate-md.sh` leave it at the default `{}`,
   so CDT-629 proves the pattern on the drain path.
4. Conflicts-queue retention is open: the queue is append-only, so a resolved conflict needs a
   resolution record. CDT-629 decides the resolution shape with the UI.
5. Cross-project memory scope is open. CDT-629 goal 4 chooses one instance per project or one
   switchable instance; Chief recall spans all agents of **one** project either way, and this file
   grants no cross-project read.
6. `ts` granularity is one second (SPEC-004 `strftime('%Y-%m-%dT%H:%M:%SZ', 'now')`). Two writes in
   the same second inside one key resolve by rule 5's tie clause, not by sub-second order. A
   sub-second timestamp is a schema change and is out of scope under D6.
