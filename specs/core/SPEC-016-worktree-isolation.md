# SPEC-016: Worktree Isolation

**Status**: ACTIVE
**Category**: core
**Created**: 2026-04-28

**Covers**: `skills/worktree-lib.sh`, `skills/orchestrate/SKILL.md`, `skills/wrap-ticket/SKILL.md`, `skills/demo/SKILL.md` (DEPRECATED stub — demo behavior removed at v1.0.0, CDT-46-C2), `commands/worktree.md` (CDV-189), `AGENTS.md`, `.gitignore`

## Overview

Defines a canonical, collision-safe worktree convention for the plugin. Any skill or agent that needs an isolated worktree for implementation work MUST go through `skills/worktree-lib.sh` — a pure subprocess CLI that creates worktrees at `$MROOT/.worktrees/<slug>`, manages an advisory age-gated lock (`.wt-lock`: `<epoch> <ISO>`), and handles stale-lock recovery. Eliminates the previous pattern of skills improvising sibling-directory paths (`$MROOT/../<project>-<TICKET-ID>`) which collided across parallel runs.

## MUST

### Path convention
- MUST place all plugin-managed worktrees at `$MROOT/.worktrees/<slug>` where `$MROOT` is resolved via `_gc=$(git rev-parse --git-common-dir 2>/dev/null) && MROOT=$(cd "$(dirname "$_gc")" && pwd) || MROOT=$(pwd)` (per SPEC-009, SPEC-002)
- MUST use branch name `feat/<slug>` when creating a new worktree branch
- MUST add `.worktrees/` to `$MROOT/.gitignore`
- MUST NOT create new worktrees at sibling paths (`$MROOT/../<project>-<TICKET-ID>`); legacy paths are read-only for detection/cleanup

### `worktree-lib.sh` CLI contract
- MUST be a pure subprocess CLI — invoked as `bash "$WT_LIB" <cmd> <args>` where `$WT_LIB` is the install-aware path resolved via `plugin-dir.sh` (see Caller integration); MUST NOT require sourcing; MUST NOT mutate the caller's shell
- MUST support subcommands: `ensure <slug>`, `release <slug>`, `status` (alias `list`), `register <slug>`, and `sweep` (see subcommand sections). Unknown subcommands exit 64
- MUST resolve `$MROOT` internally using the worktree-aware formula above
- MUST exit with: `0` = success, `1` = release error / missing worktree, `2` = user aborted on collision prompt, `64` = usage error

### `ensure <slug>` semantics
- MUST create the worktree at `$MROOT/.worktrees/<slug>` if absent
- MUST create branch `feat/<slug>` if absent; MUST reuse the branch if it already exists
- MUST print the absolute worktree path to stdout on success (and only on success)
- MUST write `$MROOT/.worktrees/<slug>/.wt-lock` on success containing one line: `<epoch-seconds> <ISO-8601-UTC>` (space-separated). The lock is ADVISORY (the real holder is an LLM agent/conversation, not an OS process); AGE derived from the epoch field is authoritative. The ISO field is human-readable only
- MUST detect existing `.wt-lock`, deciding FRESH vs STALE by age against `WT_LOCK_TTL_SECONDS` (env-overridable, default 6h / 21600s):
  - If the lock is FRESH (epoch parses and `0 <= age < TTL`, or a future/negative-age stamp treated conservatively as fresh): print collision summary to stderr (slug, branch, HEAD short SHA + commit subject, lock age in human form), then:
    - Probe interactive TTY by a successful write to `/dev/tty` (not mere `-r` — `access()` can succeed while open fails ENXIO with no controlling terminal). On success: prompt on `/dev/tty` (abort | steal). On explicit `steal` overwrite lock and exit 0 with path on stdout; any other/empty answer exit 2 with nothing on stdout
    - If `/dev/tty` is not writable (no controlling TTY, e.g. agent/`setsid` with stdin closed): still print summary + prompt line to stderr, treat answer as empty, exit 2 cleanly — MUST NOT die with exit 1 / "No such device" from a bare `printf >/dev/tty` under `set -e` (AC-5)
  - If the lock is STALE (`age >= TTL`, or field 1 is unparseable — e.g. a corrupt lock or a legacy `PID TS` lock): silently overwrite lock and exit 0 with worktree path on stdout
- MUST NOT print the worktree path on stdout for any non-zero exit

### `release <slug>` semantics
- MUST remove `$MROOT/.worktrees/<slug>/.wt-lock`
- MUST run `git worktree remove "$MROOT/.worktrees/<slug>"`
- MUST exit non-zero with a clear stderr message if the worktree has uncommitted changes; MUST NOT force-remove
- MUST exit 0 on clean removal

### `status` / `list` semantics (CDV-189)
- MUST enumerate only plugin-managed worktrees under `$MROOT/.worktrees/*` (directories); MUST NOT include sibling-path or harness-default worktrees outside that tree
- For each slug, MUST report on stdout (human-readable table or stable one-line-per-slug form): slug, branch (`feat/<slug>` or current branch if present), lock state **FRESH|STALE|NONE** by epoch age vs `WT_LOCK_TTL_SECONDS`, lock age human form when a lock exists, HEAD short SHA + subject when the worktree is a valid git checkout
- MUST NOT report PID or session id (lock is age/epoch only)
- `list` MUST be a byte-equivalent alias of `status`
- MUST exit 0 even when zero worktrees exist (empty listing)

### `register <slug>` semantics (CDV-189)
- MUST require the worktree directory `$MROOT/.worktrees/<slug>` to already exist; MUST NOT create branch, worktree, or prompt
- MUST write/overwrite `.wt-lock` as `<epoch-seconds> <ISO-8601-UTC>` (same format as `ensure`)
- MUST print absolute worktree path on stdout on success; MUST exit 1 if the directory is absent; MUST exit 64 on invalid slug
- Intended for thin lock stamping by callers that already own the directory (not a substitute for `ensure`)

### `sweep` semantics (CDV-189)
- MUST list candidate stale worktrees as **PROPOSALS only** on stderr (or clearly labeled proposal lines on stdout): slug where `.wt-lock` is STALE (age ≥ TTL or unparseable) AND no live task in `$MROOT/.claude/tasks/*` with status `pending`/`in_progress`/`blocked` whose compound key or content references the slug (task-store per SPEC-009/SPEC-017)
- MUST NOT remove worktrees, branches, or locks
- MUST exit 0 after printing proposals (including zero candidates)

### `/worktree` user command (CDV-189)
- MUST provide a user-invocable command `commands/worktree.md` with subcommands: `status` | `list` | `release <slug>`
- `status`/`list` MUST shell out to `worktree-lib.sh status` (plugin-dir resolved)
- `release <slug>` MUST ask for **chat confirmation** before calling `worktree-lib.sh release <slug>`; on decline, MUST NOT call release
- MUST reuse lib dirty-tree refusal; MUST NOT force-remove

### Caller integration
- Callers MUST resolve `worktree-lib.sh` through `plugin-dir.sh` (install-aware: the script ships in the plugin, not the user's repo) — emit the canonical bootstrap stanza (SPEC-002) to set `$PDH`, then `WT_LIB=$(bash "$PDH/skills/plugin-dir.sh" file skills/worktree-lib.sh)`. MUST NOT invoke the cwd-relative form `bash skills/worktree-lib.sh` (absent on a real install) nor `$MROOT/skills/worktree-lib.sh` (resolves to the user's repo, not the plugin)
- `skills/orchestrate/SKILL.md` Step 3 MUST call `bash "$WT_LIB" ensure <slug>` as a subprocess and capture stdout as the worktree path. MUST remove the legacy sibling-path creation. On exit 1: surface the stderr error to the user and halt. On exit 2: halt cleanly without error
- `skills/wrap-ticket/SKILL.md` Step 6 MUST call `bash "$WT_LIB" release <slug>` as a subprocess. MUST remove any direct `git worktree remove` call targeting `.worktrees/` paths
- `skills/wrap-ticket/SKILL.md` MUST detect both `.worktrees/<slug>` (new) and `$MROOT/../<project>-<TICKET-ID>` (legacy) worktree paths; MUST prefer the new path when both exist
- `skills/wrap-ticket/SKILL.md` MUST anchor every `grep` for a TICKET-ID so `WISO-1` does not match `WISO-10` (use `grep -E "(^|[^A-Z0-9-])WISO-1([^0-9]|$)"` or `grep -wF`); fix everywhere wrap-ticket greps for ticket ID
- **OBSOLETE at v1.0.0 (CDT-46-C2):** `/demo` was removed (`skills/demo/SKILL.md` is now a deprecation stub); this requirement is retained one deprecation cycle as historical record only. ~~`skills/demo/SKILL.md` MUST keep its dedicated `$TMPDIR/demo-project` path and MUST NOT depend on `worktree-lib.sh`. MUST add a 2-3 line inline check at worktree creation: if path exists, prompt user before proceeding~~
- `AGENTS.md` MUST contain a "Worktree Protocol" section that: declares `.worktrees/<slug>` as the canonical path, points to `skills/worktree-lib.sh` and SPEC-016, and states in one sentence that sibling-directory worktrees are forbidden when the lib is in use
- `AGENTS.md` Worktree Protocol SHOULD mention `/worktree status|list|release` as the user-facing management surface once shipped

### Proposed extension — Worktree lifecycle hooks (DRAFT — **blocked by harness contract**, CDV-189 spike)

> **DRAFT marker:** WLH-1–WLH-8 below remain design-only. **Not promoted.** `/spec check` MUST exclude them from MATCH/MISSING scoring until this marker is dropped.
>
> **CDV-189 spike (2026-07-14) — events exist, enforcement design does not fit:**
>
> | Claim (pre-spike) | Evidence | Verdict |
> |---|---|---|
> | `WorktreeCreate` / `WorktreeRemove` events exist | Official hooks ref (`code.claude.com/docs/en/hooks`); Claude Code changelog ("Added `WorktreeCreate` and `WorktreeRemove` hook events"); local CC **v2.1.190** | **YES** |
> | Create is post-hoc registration observer | Docs: configuring WorktreeCreate **replaces default `git worktree`**; hook **must print path on stdout** (last non-empty line); any non-zero aborts create | **NO** — provider, not registrar |
> | Remove blocks via exit 2 (dirty / FRESH lock) | Docs exit-code table: `WorktreeRemove` → **No** decision control; "can't block worktree removal"; failures debug-only | **NO** — exit 2 does **not** block |
> | Events intercept hand-typed `git worktree add/remove` | Docs: fire for `--worktree` / `isolation: "worktree"` harness isolation only | **NO** — skill/`git` paths unchanged |
>
> **Stdin schemas (verified from docs):**
> - Create: common fields + `hook_event_name: "WorktreeCreate"` + `name` (slug)
> - Remove: common fields + `hook_event_name: "WorktreeRemove"` + `worktree_path` (absolute)
>
> **Ship decision (CDV-189):** Part 2 (`/worktree` + lib `status`/`list`/`register`/`sweep`) ships. Part 1 hook enforcement **stays DRAFT**. A future redesign may use WorktreeCreate as an **isolation provider** (`ensure` + path on stdout) and WorktreeRemove as **best-effort cleanup** (never block) — that is a different product shape than WLH-1–5 as written.
>
> Original WLH bullets retained below for redesign reference only.

- **WLH-1 — WorktreeCreate registration (SUPERSEDED by provider model).** Original: stamp lock only after create. Harness reality: if a Create hook is configured, the hook **is** the creator and MUST print the worktree path. Redesign candidate: call `ensure <name>` (or create under `.worktrees/<name>`) and print path; do not treat Create as observe-only.
- **WLH-2 — Non-canonical path warning (never block creation).** Still desirable for any path outside `$MROOT/.worktrees/`, but only meaningful if the plugin owns creation (provider). Original "exit 0 warn" conflicts with Create's "any non-zero aborts" only if we exit non-zero — warn-on-stderr + still create under canonical path is the viable shape.
- **WLH-3 — Serialized removal via exit 2 (UNIMPLEMENTABLE).** Harness does not honor exit 2 on WorktreeRemove. Serialization stays convention + `release` single-caller discipline.
- **WLH-4 — Dirty-tree removal block via exit 2 (UNIMPLEMENTABLE on WorktreeRemove).** Dirty protection remains inside `worktree-lib.sh release` and `/worktree release` confirmation — not harness-enforced for isolation teardown.
- **WLH-5 — Stale-lock detection on removal.** Partially applicable as soft logic inside a future best-effort Remove handler (warn/sweep only).
- **WLH-6 — Stale-worktree sweep is proposal-only.** **Ships in CDV-189 as `worktree-lib.sh sweep`** (lib surface; not hook-bound).
- **WLH-7 — Wiring via init-orchestration + graceful absence.** Deferred with Part 1. Do **not** wire WorktreeCreate in init-orchestration until provider redesign is intentional (wiring Create alone replaces default git isolation).
- **WLH-8 — MUST NOT auto-delete from hooks.** Still valid if/when Remove cleanup is implemented: proposal/warn only unless explicitly paired with a Create provider that owns the lifecycle.

## SHOULD

- SHOULD include the slug, branch, HEAD short SHA, commit subject, and lock age (human form, e.g. "held 12m ago") in the collision summary so the user can decide informed
- SHOULD derive freshness from lock age (`now - epoch` vs `WT_LOCK_TTL_SECONDS`); there is no live holder process to probe, so age is the only signal
- SHOULD treat absent `$MROOT` resolution as a fatal error and exit non-zero with a clear message
- SHOULD exclude `.wt-lock` from the dirty-tree check in `release` (it is bookkeeping, not user content)

## MUST NOT

- MUST NOT source `worktree-lib.sh`; subprocess invocation only (matches `task-store.sh`, `gate.sh` precedent)
- MUST NOT silently reuse a worktree whose lock is still FRESH (age < `WT_LOCK_TTL_SECONDS`); MUST prompt (abort/steal) instead
- MUST NOT delete or `--force` a worktree with uncommitted changes
- MUST NOT run parallel `git worktree` operations — already documented in AGENTS.md; this spec inherits that constraint

## Lock file format

`.wt-lock` contains exactly one line:

```
<epoch-seconds> <ISO-8601-UTC>
```

Example:

```
1718521234 2026-06-16T06:34:41Z
```

Field 1 (epoch seconds) is authoritative — freshness is `now - epoch` compared against `WT_LOCK_TTL_SECONDS`. Field 2 (ISO timestamp) is human-readable only. The lock is advisory: it records *when* a worktree was claimed, not *who* holds it (the holder is an LLM agent/conversation, not a checkable OS process). Legacy `<SESSION_ID> <PID> <ISO>` locks have a non-numeric field 1 and are auto-reclaimed as stale.

## Exit code contract

| Code | Meaning |
|------|---------|
| 0 | Success — worktree ready, path on stdout |
| 1 | `release` error — missing worktree or uncommitted changes block removal |
| 2 | User aborted on prompt (live lock collision declined or no answer given) |
| 64 | Usage error — missing slug or unknown subcommand |
| non-zero (other) | Fatal error |

## Test

- Verify `ensure <slug>` creates `.worktrees/<slug>`, branch `feat/<slug>`, and `.wt-lock` in `<epoch> <ISO>` format; prints absolute path; exits 0
- Verify `ensure` against a FRESH lock (epoch = now, age < TTL): stderr shows summary, exit 2 on abort, stdout empty
- Verify `ensure` against a STALE lock (age >= TTL, or unparseable/legacy `PID TS` format): silently overwrites, exits 0, prints path
- Verify `ensure` no-TTY / unwritable `/dev/tty` collision (e.g. `setsid … </dev/null` against a FRESH lock): prompts on stderr, exits 2, stdout empty, no "No such device" on stderr
- Verify `release` cleans `.wt-lock` + removes worktree on clean tree; exits non-zero on dirty tree without force
- Verify orchestrate Step 3 captures stdout path correctly and halts on exit 1/2
- Verify wrap-ticket grep does not match `WISO-10` when looking for `WISO-1`
- Verify wrap-ticket detects both `.worktrees/<slug>` and legacy sibling path; prefers new
- Verify `status`/`list` list only `$MROOT/.worktrees/*`; show FRESH|STALE|NONE by epoch age; no PID/session fields; exit 0 when empty
- Verify `register <slug>` stamps lock without creating branch/worktree; exit 1 if dir missing
- Verify `sweep` prints proposals only and never deletes worktree/lock/branch
- Verify `/worktree release` requires chat confirmation before calling lib release

**Lifecycle hooks (DRAFT — not required for CDV-189 ship):**
- Do **not** require WorktreeRemove exit-2 block tests (harness cannot honor them)
- Future provider redesign tests: WorktreeCreate handler prints path via `ensure`; WorktreeRemove is side-effect-only

## Validation

- [ ] `skills/worktree-lib.sh` exists and is executable as a subprocess CLI
- [ ] `.worktrees/` is in `$MROOT/.gitignore`
- [ ] `AGENTS.md` has a "Worktree Protocol" section pointing to SPEC-016
- [ ] `orchestrate` Step 3 calls `worktree-lib.sh ensure`
- [ ] `wrap-ticket` Step 6 calls `worktree-lib.sh release`
- [ ] `wrap-ticket` ticket-ID greps are anchored
- [ ] ~~`demo` retains its inline worktree check; does not call `worktree-lib.sh`~~ (OBSOLETE at v1.0.0, CDT-46-C2 — `/demo` removed)
- [ ] `status`/`list`/`register`/`sweep` subcommands exist (CDV-189)
- [ ] `commands/worktree.md` ships with status|list|release (CDV-189)
- [ ] Proposed extension 'Worktree lifecycle hooks' remains DRAFT until provider redesign + promotion

## Open Questions

- [ ] Should `ensure` accept a `--no-prompt` / `--steal` flag for fully non-interactive callers (CI)? Currently unwritable `/dev/tty` aborts with exit 2 (CDV-201); if CI needs reclaim without TTY, add later.
- [ ] Should `release` support an explicit `--force` for callers that have already confirmed loss is acceptable? Out of scope for v1.
- [x] ~~Do WorktreeCreate/Remove support exit-2 enforcement?~~ **No** (CDV-189 spike). Remove has no decision control; Create is a provider that must print path.
- [ ] Future: should the plugin wire WorktreeCreate as isolation provider (`ensure` + path stdout) for `--worktree` / `isolation: worktree`? Separate ticket; do not wire in init-orchestration until intentional.

## Version History

| Date | Change |
|------|--------|
| 2026-04-28 | Initial spec for WISO-001. |
| 2026-04-29 | Exit code table corrected to match implementation (exit 1 = release error, exit 2 = abort/decline, exit 64 = usage). Added SHOULD for .wt-lock dirty-check exclusion. |
| 2026-06-16 | CLUSTER-003/A5: caller-integration MUSTs changed from the cwd-relative `bash skills/worktree-lib.sh` to install-aware resolution via `plugin-dir.sh` (`WT_LIB=$(bash "$PDH/skills/plugin-dir.sh" file skills/worktree-lib.sh)`). The cwd-relative form (and `$MROOT/skills/…`) is absent / wrong on a real cache install where the script ships in the plugin, not the user's repo. The lib still self-resolves `$MROOT` internally for worktree data paths. |
| 2026-06-16 | Switched the lock from PID-liveness to advisory, age-based locking. The lock now holds `<epoch-seconds> <ISO-8601-UTC>`; freshness is `now - epoch` vs `WT_LOCK_TTL_SECONDS` (env-overridable, default 6h). Rationale: the holder is an LLM agent/conversation, not an OS process — `kill -0` liveness was structurally unworkable (the old code recorded `worktree-lib.sh`'s own ephemeral subprocess PID, so collision detection never fired). FRESH → prompt abort/steal; STALE (age ≥ TTL or unparseable) → silent reclaim; legacy `PID TS` locks auto-reclaim as stale. Reconciles the prior 3-field-spec (`SESSION_ID PID ISO`) vs 2-field-code (`PID ISO`) drift (CLUSTER-004). |
| 2026-07-13 | CDV-201: FRESH-lock prompt probes TTY via successful `printf >/dev/tty` (not `-r` alone). Unwritable `/dev/tty` (no controlling TTY / ENXIO) prints prompt to stderr and exits 2 cleanly under `set -e` instead of dying exit 1 with "No such device". Steal only on explicit `steal`. |
| 2026-07-14 | CDV-189: promoted Part 2 lib surface (`status`/`list`/`register`/`sweep`) + `/worktree` command MUSTs; lock model remains epoch FRESH\|STALE. Lifecycle hooks WLH kept DRAFT after spike: WorktreeCreate/Remove **exist** (docs + changelog, CC ≥ event-add, local 2.1.190) but Create **replaces** git and must print path; Remove has **no** exit-2 block. Dirty/FRESH enforcement stays in `release` + user command. |
| 2026-07-21 | CDT-46-C2: `/demo` removed in the v1.0 surface-cleanup pass (`skills/demo/SKILL.md` → deprecation stub). Marked the demo-specific MUST and its validation checkbox OBSOLETE-at-v1.0.0 (retained one cycle as historical record, not deleted); annotated the demo Covers entry as a DEPRECATED stub. Worktree-lib/orchestrate/wrap-ticket behavior unchanged. |

## Cross-references

- SPEC-002: Plugin Infrastructure — `$MROOT` resolution formula; subprocess CLI precedent (`task-store.sh`, `gate.sh`)
- SPEC-009: Ticket Workflow — wrap-ticket worktree cleanup MUSTs; orchestrate Step 3 ownership; `$MROOT` worktree-aware resolution
