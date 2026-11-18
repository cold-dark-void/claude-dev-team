# Record ownership — one owner and one conflict rule per state record

Carries AC13. Scope: phase 0 of control plane Option C+ (CDT-626). This file assigns one writer,
one conflict rule, and one owner to each plugin state record. It ships no behavior.

CDT-643 (CDT-628 C2, 2026-11-16) carries AC8 of phase 1: it adds row 12, the run journal — the one
record in this table owned by the control plane. Rows 1-11 keep the writer, path, owner, and rule
the AC13 ruling gave them.

CDT-646 (CDT-628 C7, 2026-11-17) amends row 4 — the tracker inversion: the local backlog store
becomes the source of truth for ticket records, Linear becomes an opt-in per-project mirror behind
the `linear_sync` key, and row 13 (the project config that holds that key) enters the table.
Row 4's owner and conflict rule are re-tested and stay `plugin` / `single-writer-lease`; see its
mechanics entry.

CDT-644 (CDT-628 C4, 2026-11-17) adds row 14: the node agent's per-node runner selection
(`.claude/dev-team/node.json`, key `runner`) — `control-plane-only` with the C7 single-reader
pattern, fail-closed.

## Decision register

| Field | Value |
|---|---|
| **Decision** | Every plugin state record has exactly one owner and one conflict rule drawn from a closed set of five: single-writer-lease, plugin-only, control-plane-only, append-only-merge, derived-rebuild. Phase-0 ruling: all eleven records are **plugin**-owned. The control plane owns no record in this table; it reads them through files and CLI calls only (ADR 0001 boundary). Phase 1 (CDT-643, 2026-11-16) adds row 12 — the run journal — as the one **control-plane-only** row. Rows 1-11 keep the owner, path, and rule the phase-0 ruling gave them. Phase 1 (CDT-646, 2026-11-17) amends row 4's posture — the backlog store is the source of truth for ticket records and Linear is an opt-in mirror — and adds row 13, the project config, as **plugin** / `plugin-only`. The control plane owns no ticket record. |
| **Status** | Decided for phase 0 (2026-11-15). No record transfers to the control plane in phase 0. The table records paths and rules that exist today; nothing here is a new store. Amended for phase 1 (2026-11-16, CDT-643): row 12 exists; the store is real and git-ignored. Amended again (2026-11-17, CDT-646): row 4 is the source of truth for ticket records; row 13 exists, is git-ignored, and has one reader. |
| **Date** | 2026-11-15 (phase 0); amended 2026-11-16 (CDT-643, row 12); amended 2026-11-17 (CDT-646, rows 4 and 13) |
| **Sources** | `docs/internal/control-plane/index.md` § CDT-632 AC13; the kickoff plan § OQ-7 (eleven rows); SPEC-033 AC6/M13 + N4/N12/N14; SPEC-040 M20/M22 + AC11/AC16; SPEC-025 M6 + L10; SPEC-009 (Backlog posture, CDT-54/CDT-46-C8; Backlog root rule, CDT-351; § Backlog write integrity; the plans path); SPEC-004 + AGENTS.md § Persistent Memory Protocol; SPEC-013 (report path, `index.json`); SPEC-037 M11/M18 (CDT-228); SPEC-023 M1/M14; SPEC-036 M2/M3/M4/M6/M10; SPEC-016 § Path convention + § `ensure <slug>` semantics (`.wt-lock`); SPEC-018 M3f; SPEC-001 M7 (the NDJSON precedent SPEC-033 M13 mirrors); `docs/adr/0001-journal-engine.md` § Decision; `docs/internal/control-plane/container-runner.md` Fact 3; `.gitignore:5,6,9,10,12,14,17,32,35,41,58,59`. Row 12 adds: CDT-643 AC8; `control-plane/journal/open.go:24` (the path), `control-plane/journal/schema.sql:95` (`lease`), `control-plane/journal/schema.sql:113-117` (`journal_meta` owner and engine), `control-plane/run/lease.go` (the fencing check); `docs/adr/0001-journal-engine.md` § "The narrow-interface boundary"; `.gitignore:39`. Rows 4 and 13 add: CDT-646; SPEC-009 § Linear sync is opt-in and § Backlog; `skills/backlog/linear-gate.sh` (the one reader of `linear_sync`); `skills/backlog/ticket.sh`, `add.sh`, `close.sh` (the ticket verbs); the `.claude/dev-team/config.json` entry in `.gitignore`. |
| **Phase effect** | Phase 1 (CDT-628) adds the journal as a new record: it is **control plane**-owned, git-ignored, and never in `memory.db` (ADR 0001). CDT-643 lands it as row 12. Phase 2 (CDT-629) may add the memory API in front of row 5 without changing that row's owner. No phase-0 file changes a writer, a path, or a rule below. |
| **Residual items** | Row 5 owner is re-tested when CDT-629 lands (the API front, not the store) — CDT-643 AC8 carries that re-test. Closed 2026-11-16: the journal row entered this table as row 12 (CDT-643 owns the path and DDL). Row 11 registry enumeration inside a container Runner is unprobed for omp and mini-swe. Closed 2026-11-17: the ticket record plane was re-tested (CDT-646) — row 4 stays `plugin` with `single-writer-lease`, and no ticket record is `control-plane-only`. A control-plane writer for the ticket store, if CDT-629+ ever adds one, re-opens this row. |

## The closed conflict-rule set

A conflict-rule cell is one of these five tokens. No cell carries any other value.

| Rule | Meaning | What enforces it today |
|---|---|---|
| `single-writer-lease` | One writer at a time holds a lease; a second writer waits or fails. The record is read-modify-written. | `flock`, a `mkdir` lock with a TTL, a noclobber lock file, a SQLite write transaction, an advisory age-gated stamp. |
| `plugin-only` | The plugin's own Surface is the only writer. No control-plane writer, no merge, no second path. Every write is a create or a full rewrite by that Surface. | The Surface that owns the file; plugin prose MUST NOT define a second writer (SPEC-002 D1 / M12 discipline). |
| `control-plane-only` | The control plane is the only writer; the plugin reads. | Row 12 (the run journal, added by CDT-643): the SQLite write transaction plus the `lease` table. Reserved for later control-plane records. |
| `append-only-merge` | Records are appended, never edited in place. Concurrent writers append and never merge, so no read-modify-write race exists. | JSONL append; append-newest-first + tmp+rename; create-only, no-overwrite. |
| `derived-rebuild` | The record is a mirror that a sync tool rebuilds from its source. A lost or stale copy is repaired by re-running the sync, never by hand-merging. | The sync tool plus its cursor file. |

## Ownership table (14 rows)

Paths are `$MROOT`-anchored — `$MROOT` = the parent of `git rev-parse --git-common-dir` (SPEC-009), so every row except row 10 is shared across worktrees, not per-worktree. Row 10 is host-global and lives outside any repository. The `#` column is an index for cross-references in this file; it carries no rule.

Rows 1-11 are the plugin records AC13 ruled in phase 0. Row 12 is the control plane's own record,
added by CDT-643 under the AC8 naming rule: same `$MROOT` anchoring, git-ignored, and reached by the
plugin through the journal CLI only. Row 13 is the project config that carries the `linear_sync` key,
added by CDT-646 (tracker inversion). Row 14 is the node agent's per-node runner selection, added by
CDT-644.

| # | Record | Exact path | Writer | Reader | Owner | Conflict rule |
|---|---|---|---|---|---|---|
| 1 | Autopilot decision-cards | `$MROOT/.claude/autopilot/<TICKET-ID>.jsonl` | `skills/autopilot/append-card.sh` — one append per gate answer, halt, or reroute | `skills/autopilot/read-cards.sh`; the M14 ship gate; `/standup` | plugin | append-only-merge |
| 2 | Epic state | `$MROOT/.claude/epics/<EPIC-ID>/state.json` (+ per-epic `seeds/`) | `/epic` through `skills/epic/epic-lib.sh` | `/epic` resume and `/epic sync`; `/standup` rollup; the seal gate | plugin | single-writer-lease |
| 3 | Backlog sweep journal | `$MROOT/.claude/sweeps/<slug>.jsonl` | `/backlog sweep` only (intent record before the side effect, `outcome` on completion) | `/backlog sweep` on its next run (re-run skip; invalidation boundary = last release tag) | plugin | append-only-merge |
| 4 | Backlog index and item files — the plane-owned ticket records | `$MROOT/.claude/backlog.md` + `$MROOT/.claude/backlog/<slug>.md` | The plugin's own ticket verbs, in the local store, in this order: `skills/backlog/add.sh` (create, incl. `--kind epic|child`), `close.sh claim` (claim), `close.sh` + `fold-sweep.sh` (close), `reconcile.sh` (repair) — all under the shared `mkdir` lease. The store is the **source of truth** for ticket records (CDT-646); Linear is an **opt-in mirror** (`linear_sync`, SPEC-009) and is never a writer of this row | `/backlog list`, `/kickoff` intake, `/orchestrate` intake + ship close-out, `/status` open set (`sweep.sh merge-open`), `/standup`, `/epic` modes A/B/E/F, ship close-out | plugin | single-writer-lease |
| 5 | Memory store | `$MROOT/.claude/memory/memory.db` | The behavioral agents and `advisor` through `skills/memory-store/memdb.sh`; `/setup team`, `migrate*.sh`, and `/memory distill` (the distiller) | Agent session-start load (`memdb.sh load-session`); `/memory search`, `/memory stats`; `/doctor`; SPEC-011 validation | plugin | single-writer-lease |
| 6 | Plans | `$MROOT/.claude/plans/<YYYY-MM-DD>-<TICKET-ID>-<slug>.md` | `/brainstorm` and `/kickoff` (the plan author; the Task Map block is appended by `/kickoff`) | `/orchestrate` (the committed plan is the AC source for the M14 ship gate); `/wrap-ticket` learnings; `/standup` | plugin | plugin-only |
| 7 | Council reports and verdict index | `$MROOT/.claude/council/<YYYY-MM-DD>-<slug>[--<task_id>][-<N>].md` + `$MROOT/.claude/council/index.json` | The council engine (`engine.sh`, and the parallel engine at strict output parity) | The SPEC-002 TaskCompleted hook (`task-completed.sh` reads `index.json`, never the report files); `/retro`; the M14 ship gate | plugin | append-only-merge |
| 8 | Model map local layer | `$MROOT/.claude/dev-team/models.local.json` (+ `.lock`) | `skills/model-map/write-model.sh` only (SPEC-037 M18, CDT-228). `/setup models` and `/adjust-agent --model` call it. The repo and global layers stay hand-edited. | `skills/model-map/resolve-model.sh` at every spawn site; `/doctor` `models.map`; `/adjust-agent` | plugin | single-writer-lease |
| 9 | Release-train queue | `$MROOT/.claude/release-train/queue.json` (+ `train.lock`) | `skills/release-train/train-lib.sh` (in-directory temp + rename, never a cross-filesystem rename) | `/release-train` (order and version assignment, resume); `/release` per queue entry | plugin | single-writer-lease |
| 10 | Transcript mirror | `~/.claude/transcript/<sid>/` — host-global, outside the repository, not per-project | The SPEC-036 recorder: the opt-in `hooks.Stop[]` / `SessionEnd` hook plus `skills/transcript-mirror/transcript-sync.sh`. Fail-open: the recorder always exits 0. | `/handoff` (SPEC-018 M3f reads `main.md`); `transcript-sync --check`; `/doctor` lag check | plugin | derived-rebuild |
| 11 | Worktree registry | `$MROOT/.worktrees/<slug>/` + `$MROOT/.worktrees/<slug>/.wt-lock`; git's own entries at `$MROOT/.git/worktrees/<slug>/` | `git worktree add`/`remove`, invoked only by `skills/worktree-lib.sh` (`ensure`, `release`, `register`) as a subprocess | `/status worktree`; `skills/wrap-ticket/resolve-worktree.sh`; `/wrap-ticket` Step 6; `/epic` shared integration path | plugin | single-writer-lease |
| 12 | Run journal | `$MROOT/.claude/runs/run.db` (git-ignored, `.gitignore:39`; the DDL home is `control-plane/journal/schema.sql`) | The control-plane service, one writer per open: `control-plane/journal` appends the event, `control-plane/run` writes the `lease` row in the same transaction, one owner per run through the lease | The control-plane service (replay is the state) and the plugin through the journal CLI (`control-plane/cmd/journalctl`) — files + CLI calls only, the ADR 0001 boundary | control-plane-only | single-writer-lease |
| 13 | Project config (`linear_sync`) | `$MROOT/.claude/dev-team/config.json` (git-ignored, `.gitignore` — the `linear_sync` opt-in key, SPEC-009 § Linear sync is opt-in) | `skills/backlog/linear-gate.sh set` only (tmp + rename through `skills/lib/portable.sh atomic_write`; it refuses a file that is not valid JSON) | `skills/backlog/linear-gate.sh` — the single reader; every Surface (`/kickoff`, `/orchestrate`, `/status`, `/epic`) and `ticket.sh` read the key through that helper, never the file | plugin | plugin-only |
| 14 | Node agent config (`runner`) | `$MROOT/.claude/dev-team/node.json` (git-ignored, `.gitignore` — the per-node runner selection, CDT-644) | The node operator's provisioning step today — an out-of-band write, like the systemd user unit file; no verb writes it yet. No plugin Surface may write it | `control-plane/agent` — the single reader: `agent.Load` resolves the `runner` key (closed set; the native runner is the first built and the default once selected), overridden by `$DEVTEAM_RUNNER`, and every unrecognised value resolves to no selection, so a node with no selection starts no run (fail-closed) | control-plane-only | control-plane-only |

## Conflict-rule mechanics per row

- **Row 1** — SPEC-033 AC6/M13 fixes the card as append-only JSONL, one object per event. Cards are never edited in place, so appends need no lease.
- **Row 2** — SPEC-025 M6: an exclusive `flock` on `$MROOT/.claude/epics/.lock` covers the whole read-modify-write of `state.json`; the publish is tmp+rename. The lock is not held across Linear MCP calls or worktree operations, and readers may observe a stale but complete snapshot.
- **Row 3** — SPEC-040 M20 fixes the journal as append-only, one record per swept item; M22 skips an item whose record carries a terminal `outcome`.
- **Row 4** — SPEC-009 § Backlog write integrity: `add.sh`, `close.sh` (close and claim), `defer.sh`,
  and `reconcile.sh` hold one shared `mkdir` lock, `$MROOT/.claude/backlog.lock/`, with an epoch stamp
  (TTL 60 s, wait 30 s), over the whole read-decide-write of both the index and the item files.
  Reconcile is the idempotent repair pass for a broken lease.
  **Owner ruling for this row (CDT-646, 2026-11-17 — tracker inversion).** The row was re-tested
  against the closed set and stays **plugin**, not `control-plane-only`: every writer named above is
  plugin code that runs in the plugin's own Surface, and the control-plane service reaches the store
  through files and CLI calls only (ADR 0001 § "The narrow-interface boundary"), so it is not a writer
  and cannot hold the lease. What changed in CDT-646 is the **posture**, not the owner: the store is
  the source of truth for ticket records, and Linear — previously the SoT for open work while the MCP
  was up — is now an opt-in downstream mirror behind `linear_sync` (SPEC-009 § Linear sync is opt-in;
  one reader `skills/backlog/linear-gate.sh`; default `off` = zero Linear MCP calls). With the key
  `on`, the plugin writes this row first and the Linear mirror second; a mirror failure writes nothing
  back here. The row keeps `single-writer-lease`: one verb holds the lease per read-decide-write, and
  a second writer (another worktree's `close.sh`, a sweep close) waits or fails.
- **Row 5** — SQLite serializes writers. `memdb.sh` binds values and sets a 5000 ms busy timeout (SPEC-004, `skills/memory-store/memdb.sh`); a write that does not commit is retried, never double-written.
- **Row 6** — One plan file per ticket, created by `/kickoff` and read thereafter. `/wrap-ticket` reads the worktree copy first and falls back to `$MROOT` (SPEC-009 WP 1-06 / CDT-278 F20). No Surface merges two plan files.
- **Row 7** — SPEC-013: report files are create-only (report no-overwrite; a collision appends `-<N>`), and `index.json` rows are append-only per `task_id` (newest first, never mutated in place), published by tmp+rename so the hook never sees a partial write.
- **Row 8** — SPEC-037 M18: `write-model.sh` MUST write only this local layer and MUST NOT write the repo or global layer, so the machine-writable layer has exactly one writer. The lock sidecar is `.gitignore:42`.
- **Row 9** — SPEC-023 M14: `train.lock` is acquired with noclobber and expires by `RELEASE_TRAIN_LOCK_TTL` (default 1800 s). A dead pid does not release it; the train releases on all exit paths.
- **Row 10** — SPEC-036: the mirror is derived from the host's own session store. The M6 cursor line (`<identity>\t<source-path>\t<main-sha256>`) is the rebuild anchor, `transcript-sync` re-derives any lag, and the recorder fails open. A deleted sid dir is rebuilt by re-running the sync; nothing merges it by hand.
- **Row 11** — SPEC-016 § `ensure <slug>` semantics: `.wt-lock` holds one line, `<epoch-seconds> <ISO-8601-UTC>`, and is advisory — the real holder is an agent conversation, so age is authoritative (`WT_LOCK_TTL_SECONDS`, default 21600 s), not the pid. A FRESH lock blocks a second `ensure`; `ensure` also adds `.wt-lock` to the shared `info/exclude` so no consumer worktree can stage it. Parallel `git worktree` operations are forbidden (SPEC-016).
- **Row 12** — CDT-643 AC8 (2026-11-16). The owner is recorded in the file itself: `journal_meta` carries `owner` = `control-plane-only` and `engine` = `sqlite-behind-narrow-interface` (`control-plane/journal/schema.sql:113-117`). The lease record is the `lease` table (`control-plane/journal/schema.sql:95`): one row per run, one `owner`, and a strictly monotonic fencing `token`. `control-plane/run/lease.go` checks the token inside the same `BEGIN IMMEDIATE` transaction as the append and refuses a token at or below the live one with `journal.ErrStaleToken`, so a stale owner writes nothing. Each acquisition is journaled as `lease_acquired` with its reason (`claim`, `takeover`, `self`); a terminal state drops the row and its event is the journal's record of the release. The plugin never opens this database with SQL: it reads through the journal CLI (ADR 0001 § "The narrow-interface boundary"). `journal.Open` refuses a path that resolves to `memory.db`, so invariant 2 holds for run state too. The container Runner mounts the worktree at the same absolute path (`container-runner.md` Fact 3), so row 12 needs no path rewrite inside a container and the lease is the real guard.
- **Row 13** — CDT-646 (2026-11-17). One writer: `linear-gate.sh set`. The write is tmp + rename in
  the destination directory (`skills/lib/portable.sh atomic_write`), so a reader never sees a partial
  file, and it refuses a target that is not valid JSON. There is no second path and no merge: the
  per-run `$LINEAR_SYNC` override is process environment, not a second copy of this record. Reads are
  fail-closed — an absent file, an absent key, invalid JSON, an unknown token, or a box with no `jq`
  all yield `off` — so the offline path needs no state in this row at all, and a project that never
  opts in never creates the file. The row is scoped to the `linear_sync` key: the file is the project
  config that `docs/internal/control-plane/memory-api.md` § Config key pre-names for
  `control_plane_url` (CDT-629, phase 2), and CDT-646 lands the `.gitignore` line that close-out
  § CDT-629 lists as a residual. When CDT-629 adds that key it brings its own writer and enters as
  its own row; this row's one-writer claim covers `linear_sync` only.
- **Row 14** — CDT-644 (2026-11-17). One reader: `control-plane/agent` (`agent.Load`), the C7
  pattern of row 13's reader — first hit wins (`$DEVTEAM_RUNNER` overrides the file's `runner` key),
  one reader, and every unrecognised value resolves to no selection, so a node with no selection
  starts no run (fail-closed). The closed runner set is `native` first — the first runner built and
  the default once selected — and, since CDT-647 (2026-11-17), `container`: one container per run
  whose image reference is digest-pinned (`control-plane/agent/container.go`, `agent.SessionImage`).
  The node agent holds the Docker socket and is the only component that does; the session container
  never receives it (`agent.guardSessionArgv`). The writer is the node operator's provisioning step,
  out-of-band like the systemd user unit file
  it belongs with; the control plane ships no writer verb yet, and no plugin Surface reads or writes
  the file. The record is node state, never committed (`.gitignore`), and shared across the
  worktrees of one node through the `$MROOT` anchor.

## Invariants this table states (AC13)

1. **`memory.db` lives at `$MROOT` and is shared across worktrees.** One database serves the main checkout and every `.worktrees/<slug>` tree (SPEC-004; AGENTS.md § Persistent Memory Protocol; row 5). Only `.claude/memory/<agent>/context.md` is per-worktree (SPEC-004: `context.md` is never migrated to SQLite).
2. **Decision-cards are git-ignored and never in `memory.db`.** `.claude/autopilot/` is not committed (`.gitignore:35`), and SPEC-033 AC6/M13 states both halves of this rule for its own NDJSON ledger, mirroring SPEC-001 M7. Row 5 never carries card content: run state is not memory — it is not distilled, not embedded, and not read by a session-start load (ADR 0001 § Decision). The same rule holds for the sweeps journal (SPEC-040 M20, `.gitignore:9`), the ticket records (row 4, SPEC-009 § Backlog), the project config (row 13, `.gitignore`), and for every other row: no row in this table is committed product delivery.
3. **The container Runner mounts the worktree at the same absolute path.** CDT-627 Fact 3 (`container-runner.md:58-68`) reproduced it for Claude Code and Grok: the host worktree appears inside the container at its own host path, and the mount must cover `$MROOT` as well, because `<wt>/.git` points at `$MROOT/.git/worktrees/<slug>`. Consequence for this table: rows 1-9, 11, and 13-14 need no path rewrite inside a container, and a container writer and a host writer contend on the *same* record, so the conflict rule of that row is the real guard.

## Owner ruling

Rows 1-11 — the eleven plugin records — are all plugin-owned. The control plane owns none of them
in phase 0. It reads plugin
records through files and CLI calls only, and it never becomes a second writer of a plugin record
(ADR 0001 § Decision: the card writer and reader stay `append-card.sh` and `read-cards.sh`).

The control plane owns its own records: the run journal (row 12, landed by CDT-643) and the memory
API's server-side state behind row 5 (phase 2, CDT-629). Those records enter this table as
`control-plane-only` rows when their paths exist — row 12 entered when CDT-643 named the path and
the DDL. This table does not pre-name those paths — the tickets that create them own the naming.

CDT-646 (2026-11-17) inverts the tracker plane and changes no owner. The ticket records — the
backlog index and item files (row 4) — are the source of truth, and the plugin's own verbs
(`skills/backlog/ticket.sh` over `add.sh` and `close.sh`) stay the only writers. Linear is a
downstream mirror behind `linear_sync`, so it never holds this row at all. Row 13, the project
config that carries that key, is `plugin` / `plugin-only` with one reader
(`skills/backlog/linear-gate.sh`). Row 12 stays the table's only `control-plane-only` row.

## Boundaries — no contradiction with SPEC-033 and SPEC-040

**SPEC-033.**

- Row 1 keeps the frozen card schema untouched (AC6/M13): no new key, no new card `type`, no
  fourth `gate` value, no ninth BC (N14). The `gate` enum stays the frozen three-value set.
- Nothing in this table adds a budget flag, a seventh `parse-flags.sh` key, a `/setup` budget
  store, or an engine-written `AUTOPILOT_ITERATION_CAP` / `AUTOPILOT_WALLCLOCK_CAP` (N12, N14).
  Row 5 is a memory store, not a budget store.
- No row defines a second `/release` bump vocabulary or a second copy of the release contract:
  row 9 stores queue state and drives `/release` for all commit, tag, and push mechanics
  (N4, SPEC-023).
- The plan label "SPEC-033 M7 journal path" for the card path is SPEC-033 **M13** (AC6). SPEC-033
  M7 is halt semantics; SPEC-001 M7 is the NDJSON ledger invariant M13 mirrors. This file cites
  M13 for the card path to keep that mapping straight.

**SPEC-040.**

- Row 3 is the SPEC-040 M20 journal: append-only, at `$MROOT/.claude/sweeps/<slug>.jsonl`, keyed
  by issue id for Linear-only items, with the intent record written before the side effect
  (AC11). `.gitignore` MUST list `.claude/sweeps/` (M20; satisfied at `.gitignore:9`).
- Row 3 keeps the sweep's write boundary: a sweep edits nothing outside `.claude/sweeps/` and
  never invokes `/release` (AC16). Ownership of backlog and Linear state stays with rows 4 and 1,
  so this table grants the sweep no writer role on them.
