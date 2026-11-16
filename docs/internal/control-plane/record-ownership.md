# Record ownership — the eleven plugin state records

Carries AC13. Scope: phase 0 of control plane Option C+ (CDT-626). This file assigns one writer,
one conflict rule, and one owner to each plugin state record. It ships no behavior.

## Decision register

| Field | Value |
|---|---|
| **Decision** | Every plugin state record has exactly one owner and one conflict rule drawn from a closed set of five: single-writer-lease, plugin-only, control-plane-only, append-only-merge, derived-rebuild. All eleven records are **plugin**-owned. The control plane owns no record in this table; it reads them through files and CLI calls only (ADR 0001 boundary). |
| **Status** | Decided for phase 0 (2026-11-15). No record transfers to the control plane in phase 0. The table records paths and rules that exist today; nothing here is a new store. |
| **Date** | 2026-11-15 |
| **Sources** | `docs/internal/control-plane/index.md` § CDT-632 AC13; the kickoff plan § OQ-7 (eleven rows); SPEC-033 AC6/M13 + N4/N12/N14; SPEC-040 M20/M22 + AC11/AC16; SPEC-025 M6 + L10; SPEC-009 (Backlog posture, CDT-54/CDT-46-C8; Backlog root rule, CDT-351; § Backlog write integrity; the plans path); SPEC-004 + AGENTS.md § Persistent Memory Protocol; SPEC-013 (report path, `index.json`); SPEC-037 M11/M18 (CDT-228); SPEC-023 M1/M14; SPEC-036 M2/M3/M4/M6/M10; SPEC-016 § Path convention + § `ensure <slug>` semantics (`.wt-lock`); SPEC-018 M3f; SPEC-001 M7 (the NDJSON precedent SPEC-033 M13 mirrors); `docs/adr/0001-journal-engine.md` § Decision; `docs/internal/control-plane/container-runner.md` Fact 3; `.gitignore:5,6,9,10,12,14,17,32,35,41,58,59`. |
| **Phase effect** | Phase 1 (CDT-628) adds the journal as a new record: it is **control plane**-owned, git-ignored, and never in `memory.db` (ADR 0001). Phase 2 (CDT-629) may add the memory API in front of row 5 without changing that row's owner. No phase-0 file changes a writer, a path, or a rule below. |
| **Residual items** | Row 5 owner is re-tested when CDT-629 lands (the API front, not the store). The journal row is added to this table by CDT-628, which owns the path and DDL. Row 11 registry enumeration inside a container Runner is unprobed for omp and mini-swe. |

## The closed conflict-rule set

A conflict-rule cell is one of these five tokens. No cell carries any other value.

| Rule | Meaning | What enforces it today |
|---|---|---|
| `single-writer-lease` | One writer at a time holds a lease; a second writer waits or fails. The record is read-modify-written. | `flock`, a `mkdir` lock with a TTL, a noclobber lock file, a SQLite write transaction, an advisory age-gated stamp. |
| `plugin-only` | The plugin's own Surface is the only writer. No control-plane writer, no merge, no second path. Every write is a create or a full rewrite by that Surface. | The Surface that owns the file; plugin prose MUST NOT define a second writer (SPEC-002 D1 / M12 discipline). |
| `control-plane-only` | The control plane is the only writer; the plugin reads. | Not used by any row in this table. Reserved for the phase-1 journal (ADR 0001) and later control-plane records. |
| `append-only-merge` | Records are appended, never edited in place. Concurrent writers append and never merge, so no read-modify-write race exists. | JSONL append; append-newest-first + tmp+rename; create-only, no-overwrite. |
| `derived-rebuild` | The record is a mirror that a sync tool rebuilds from its source. A lost or stale copy is repaired by re-running the sync, never by hand-merging. | The sync tool plus its cursor file. |

## Ownership table (11 rows)

Paths are `$MROOT`-anchored — `$MROOT` = the parent of `git rev-parse --git-common-dir` (SPEC-009), so every row except row 10 is shared across worktrees, not per-worktree. Row 10 is host-global and lives outside any repository. The `#` column is an index for cross-references in this file; it carries no rule.

| # | Record | Exact path | Writer | Reader | Owner | Conflict rule |
|---|---|---|---|---|---|---|
| 1 | Autopilot decision-cards | `$MROOT/.claude/autopilot/<TICKET-ID>.jsonl` | `skills/autopilot/append-card.sh` — one append per gate answer, halt, or reroute | `skills/autopilot/read-cards.sh`; the M14 ship gate; `/standup` | plugin | append-only-merge |
| 2 | Epic state | `$MROOT/.claude/epics/<EPIC-ID>/state.json` (+ per-epic `seeds/`) | `/epic` through `skills/epic/epic-lib.sh` | `/epic` resume and `/epic sync`; `/standup` rollup; the seal gate | plugin | single-writer-lease |
| 3 | Backlog sweep journal | `$MROOT/.claude/sweeps/<slug>.jsonl` | `/backlog sweep` only (intent record before the side effect, `outcome` on completion) | `/backlog sweep` on its next run (re-run skip; invalidation boundary = last release tag) | plugin | append-only-merge |
| 4 | Backlog index and item files | `$MROOT/.claude/backlog.md` + `$MROOT/.claude/backlog/<slug>.md` | Linear is the SoT for open work while the MCP is up; the local files are a mandatory write-through cache on every path — `/backlog add`, `close.sh`, `reconcile.sh`, `/kickoff`, `/epic` | `/backlog list`, `/kickoff` intake, `/standup`, ship close-out | plugin | single-writer-lease |
| 5 | Memory store | `$MROOT/.claude/memory/memory.db` | The behavioral agents and `advisor` through `skills/memory-store/memdb.sh`; `/setup team`, `migrate*.sh`, and `/memory distill` (the distiller) | Agent session-start load (`memdb.sh load-session`); `/memory search`, `/memory stats`; `/doctor`; SPEC-011 validation | plugin | single-writer-lease |
| 6 | Plans | `$MROOT/.claude/plans/<YYYY-MM-DD>-<TICKET-ID>-<slug>.md` | `/brainstorm` and `/kickoff` (the plan author; the Task Map block is appended by `/kickoff`) | `/orchestrate` (the committed plan is the AC source for the M14 ship gate); `/wrap-ticket` learnings; `/standup` | plugin | plugin-only |
| 7 | Council reports and verdict index | `$MROOT/.claude/council/<YYYY-MM-DD>-<slug>[--<task_id>][-<N>].md` + `$MROOT/.claude/council/index.json` | The council engine (`engine.sh`, and the parallel engine at strict output parity) | The SPEC-002 TaskCompleted hook (`task-completed.sh` reads `index.json`, never the report files); `/retro`; the M14 ship gate | plugin | append-only-merge |
| 8 | Model map local layer | `$MROOT/.claude/dev-team/models.local.json` (+ `.lock`) | `skills/model-map/write-model.sh` only (SPEC-037 M18, CDT-228). `/setup models` and `/adjust-agent --model` call it. The repo and global layers stay hand-edited. | `skills/model-map/resolve-model.sh` at every spawn site; `/doctor` `models.map`; `/adjust-agent` | plugin | single-writer-lease |
| 9 | Release-train queue | `$MROOT/.claude/release-train/queue.json` (+ `train.lock`) | `skills/release-train/train-lib.sh` (in-directory temp + rename, never a cross-filesystem rename) | `/release-train` (order and version assignment, resume); `/release` per queue entry | plugin | single-writer-lease |
| 10 | Transcript mirror | `~/.claude/transcript/<sid>/` — host-global, outside the repository, not per-project | The SPEC-036 recorder: the opt-in `hooks.Stop[]` / `SessionEnd` hook plus `skills/transcript-mirror/transcript-sync.sh`. Fail-open: the recorder always exits 0. | `/handoff` (SPEC-018 M3f reads `main.md`); `transcript-sync --check`; `/doctor` lag check | plugin | derived-rebuild |
| 11 | Worktree registry | `$MROOT/.worktrees/<slug>/` + `$MROOT/.worktrees/<slug>/.wt-lock`; git's own entries at `$MROOT/.git/worktrees/<slug>/` | `git worktree add`/`remove`, invoked only by `skills/worktree-lib.sh` (`ensure`, `release`, `register`) as a subprocess | `/status worktree`; `skills/wrap-ticket/resolve-worktree.sh`; `/wrap-ticket` Step 6; `/epic` shared integration path | plugin | single-writer-lease |

## Conflict-rule mechanics per row

- **Row 1** — SPEC-033 AC6/M13 fixes the card as append-only JSONL, one object per event. Cards are never edited in place, so appends need no lease.
- **Row 2** — SPEC-025 M6: an exclusive `flock` on `$MROOT/.claude/epics/.lock` covers the whole read-modify-write of `state.json`; the publish is tmp+rename. The lock is not held across Linear MCP calls or worktree operations, and readers may observe a stale but complete snapshot.
- **Row 3** — SPEC-040 M20 fixes the journal as append-only, one record per swept item; M22 skips an item whose record carries a terminal `outcome`.
- **Row 4** — SPEC-009 § Backlog write integrity: `close.sh` and `reconcile.sh` hold one shared `mkdir` lock, `$MROOT/.claude/backlog.lock/`, with an epoch stamp (TTL 60 s, wait 30 s), over the whole read-decide-write of both the index and the item files. Reconcile is the idempotent repair pass for a broken lease. Linear is the SoT when MCP is up; the local write-through always happens, and MCP-down is local-only plus a one-line notice (SPEC-009, Backlog posture).
- **Row 5** — SQLite serializes writers. `memdb.sh` binds values and sets a 5000 ms busy timeout (SPEC-004, `skills/memory-store/memdb.sh`); a write that does not commit is retried, never double-written.
- **Row 6** — One plan file per ticket, created by `/kickoff` and read thereafter. `/wrap-ticket` reads the worktree copy first and falls back to `$MROOT` (SPEC-009 WP 1-06 / CDT-278 F20). No Surface merges two plan files.
- **Row 7** — SPEC-013: report files are create-only (report no-overwrite; a collision appends `-<N>`), and `index.json` rows are append-only per `task_id` (newest first, never mutated in place), published by tmp+rename so the hook never sees a partial write.
- **Row 8** — SPEC-037 M18: `write-model.sh` MUST write only this local layer and MUST NOT write the repo or global layer, so the machine-writable layer has exactly one writer. The lock sidecar is `.gitignore:42`.
- **Row 9** — SPEC-023 M14: `train.lock` is acquired with noclobber and expires by `RELEASE_TRAIN_LOCK_TTL` (default 1800 s). A dead pid does not release it; the train releases on all exit paths.
- **Row 10** — SPEC-036: the mirror is derived from the host's own session store. The M6 cursor line (`<identity>\t<source-path>\t<main-sha256>`) is the rebuild anchor, `transcript-sync` re-derives any lag, and the recorder fails open. A deleted sid dir is rebuilt by re-running the sync; nothing merges it by hand.
- **Row 11** — SPEC-016 § `ensure <slug>` semantics: `.wt-lock` holds one line, `<epoch-seconds> <ISO-8601-UTC>`, and is advisory — the real holder is an agent conversation, so age is authoritative (`WT_LOCK_TTL_SECONDS`, default 21600 s), not the pid. A FRESH lock blocks a second `ensure`; `ensure` also adds `.wt-lock` to the shared `info/exclude` so no consumer worktree can stage it. Parallel `git worktree` operations are forbidden (SPEC-016).

## Invariants this table states (AC13)

1. **`memory.db` lives at `$MROOT` and is shared across worktrees.** One database serves the main checkout and every `.worktrees/<slug>` tree (SPEC-004; AGENTS.md § Persistent Memory Protocol; row 5). Only `.claude/memory/<agent>/context.md` is per-worktree (SPEC-004: `context.md` is never migrated to SQLite).
2. **Decision-cards are git-ignored and never in `memory.db`.** `.claude/autopilot/` is not committed (`.gitignore:35`), and SPEC-033 AC6/M13 states both halves of this rule for its own NDJSON ledger, mirroring SPEC-001 M7. Row 5 never carries card content: run state is not memory — it is not distilled, not embedded, and not read by a session-start load (ADR 0001 § Decision). The same rule holds for the sweeps journal (SPEC-040 M20, `.gitignore:9`) and for every other row: no row in this table is committed product delivery.
3. **The container Runner mounts the worktree at the same absolute path.** CDT-627 Fact 3 (`container-runner.md:58-68`) reproduced it for Claude Code and Grok: the host worktree appears inside the container at its own host path, and the mount must cover `$MROOT` as well, because `<wt>/.git` points at `$MROOT/.git/worktrees/<slug>`. Consequence for this table: rows 1-9 and 11 need no path rewrite inside a container, and a container writer and a host writer contend on the *same* record, so the conflict rule of that row is the real guard.

## Owner ruling

All eleven rows are plugin-owned. The control plane owns none of them in phase 0. It reads plugin
records through files and CLI calls only, and it never becomes a second writer of a plugin record
(ADR 0001 § Decision: the card writer and reader stay `append-card.sh` and `read-cards.sh`).

The control plane owns its own records: the run journal (phase 1, CDT-628) and the memory API's
server-side state behind row 5 (phase 2, CDT-629). Those records enter this table as
`control-plane-only` rows when their paths exist. This table does not pre-name those paths — the
tickets that create them own the naming.

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
