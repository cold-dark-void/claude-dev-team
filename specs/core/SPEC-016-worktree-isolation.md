# SPEC-016: Worktree Isolation

**Status**: ACTIVE
**Category**: core
**Created**: 2026-04-28

<!-- drift-ok: skill-ref -->
**Covers**: `skills/worktree-lib.sh`, `skills/orchestrate/SKILL.md`, `skills/kickoff/SKILL.md` (create-caller, CDT-105), `skills/wrap-ticket/SKILL.md`, `skills/demo/SKILL.md` (DEPRECATED stub — demo behavior removed at v1.0.0, CDT-46-C2), `commands/worktree.md` (reduced: `release` only, CDT-46-C4), `commands/status.md` (`/status worktree` read-only list, CDT-46-C4), `AGENTS.md`, `.gitignore`. WP 1-06 adds `skills/worktree-lib-test.sh`, `skills/wrap-ticket/resolve-worktree.sh`, `skills/wrap-ticket/wrap-ticket-test.sh`, `docs/commands/worktree.md` and `docs/commands/wrap-ticket.md`. This spec consumes `skills/lib/git-safety.sh` (SPEC-025 M17).

## Overview

Defines a canonical, collision-safe worktree convention for the plugin. Any skill or agent that needs an isolated worktree for implementation work MUST go through `skills/worktree-lib.sh` — a pure subprocess CLI that creates worktrees at `$MROOT/.worktrees/<slug>`, manages an advisory age-gated lock (`.wt-lock`: `<epoch> <ISO>`), and handles stale-lock recovery with dirty-tree and live-task guards (CDT-162). Eliminates the previous pattern of skills improvising sibling-directory paths (`$MROOT/../<project>-<TICKET-ID>`) which collided across parallel runs.

## MUST

### Path convention
- MUST place all plugin-managed worktrees at `$MROOT/.worktrees/<slug>` where `$MROOT` is resolved via `_gc=$(git rev-parse --git-common-dir 2>/dev/null) && MROOT=$(cd "$(dirname "$_gc")" && pwd) || MROOT=$(pwd)` (per SPEC-009, SPEC-002)
- MUST use branch name `feat/<slug>` when creating a new worktree branch
- MUST add `.worktrees/` to `$MROOT/.gitignore`
- MUST NOT create new worktrees at sibling paths (`$MROOT/../<project>-<TICKET-ID>`); legacy paths are read-only for detection/cleanup

### `worktree-lib.sh` CLI contract
- MUST be a pure subprocess CLI — invoked as `bash "$WT_LIB" <cmd> <args>` where `$WT_LIB` is the install-aware path resolved via `plugin-dir.sh` (see Caller integration); MUST NOT require sourcing; MUST NOT mutate the caller's shell
- MUST support subcommands: `ensure <slug>`, `release [--preview] <slug>`, `status` (alias `list`), `register <slug>`, and `sweep` (see subcommand sections). Unknown subcommands exit 64
- MUST resolve `$MROOT` internally using the worktree-aware formula above
- MUST exit with: `0` = success, `1` = safety/error (including `release` blocked on missing worktree, dirty tree or a failed `git worktree remove`; `ensure` STALE reclaim refused for dirty tree or live task; `ensure` on an existing directory that is not a git worktree; `register` missing dir), `2` = user aborted on collision prompt, `64` = usage error

### `ensure <slug>` semantics
- MUST create the worktree at `$MROOT/.worktrees/<slug>` if absent
- MUST create branch `feat/<slug>` if absent; MUST reuse the branch if it already exists
- MUST route create-path `git worktree add` (both existing-branch and `-b` new-branch arms) through `git_retry 3 200` (same budget as `release` mutators) so EBUSY-class `.git/config` races do not fail a single bare `git worktree add` (CDT-161). On create-path failure after a partial `-b` that left `refs/heads/feat/<slug>` without a usable worktree dir, MUST re-probe the branch and retry via plain `git_retry 3 200 worktree add <path> <branch>` (MUST NOT sticky-retry `-b` after the branch exists). Exhausted/non-retryable failures MUST propagate `git_retry`'s non-zero rc with empty stdout and MUST NOT write a success lock
- MUST print the absolute worktree path to stdout on success (and only on success)
- MUST write `$MROOT/.worktrees/<slug>/.wt-lock` on success containing one line: `<epoch-seconds> <ISO-8601-UTC>` (space-separated). The lock is ADVISORY (the real holder is an LLM agent/conversation, not an OS process); AGE derived from the epoch field is authoritative. The ISO field is human-readable only
- MUST detect existing `.wt-lock`, deciding FRESH vs STALE by age against `WT_LOCK_TTL_SECONDS` (env-overridable, default 6h / 21600s):
  - If the lock is FRESH (epoch parses and `0 <= age < TTL`, or a future/negative-age stamp treated conservatively as fresh): print collision summary to stderr (slug, branch, HEAD short SHA + commit subject, lock age in human form), then:
    - Probe interactive TTY by a successful write to `/dev/tty` (not mere `-r` — `access()` can succeed while open fails ENXIO with no controlling terminal). On success: prompt on `/dev/tty` (abort | steal). On explicit `steal` overwrite lock and exit 0 with path on stdout; any other/empty answer exit 2 with nothing on stdout
    - If `/dev/tty` is not writable (no controlling TTY, e.g. agent/`setsid` with stdin closed): still print summary + prompt line to stderr, treat answer as empty, exit 2 cleanly — MUST NOT die with exit 1 / "No such device" from a bare `printf >/dev/tty` under `set -e` (AC-5)
  - If the lock is STALE (`age >= TTL`, or field 1 is unparseable — e.g. a corrupt lock or a legacy `PID TS` lock): before overwriting the lock, MUST apply reclaim guards (CDT-162). Order is not mandated; both checks MUST run when applicable:
    1. **Dirty-tree guard** — if the worktree has uncommitted changes under the **same dirty definition as `release`** (`git -C <wt> status --porcelain`, excluding only the exact path `.wt-lock` via porcelain filter): MUST NOT overwrite `.wt-lock`; MUST print a clear reason on stderr (e.g. uncommitted changes block reclaim); MUST leave stdout empty; MUST exit `1`. No FRESH-style steal prompt for dirty STALE in this ticket.
    2. **Live-task guard** — if `slug_has_live_task <slug>` is true (same predicate as `sweep`: `$MROOT/.claude/tasks/*.json` with status `pending`/`in_progress`/`blocked` whose compound key or content references the slug): MUST NOT overwrite `.wt-lock`; MUST print a clear reason on stderr (e.g. live task blocks reclaim); MUST leave stdout empty; MUST exit `1`.
    3. **Eligible reclaim** — if the tree is clean under that dirty definition **and** no live task references the slug: MUST overwrite `.wt-lock` and exit `0` with the worktree path on stdout (stderr diagnostics such as a reclaim notice are allowed; path remains stdout-only on success).
- MUST NOT print the worktree path on stdout for any non-zero exit
- FRESH collision/steal path MUST remain unchanged by CDT-162 (no new dirty/live-task gates on FRESH)
- The no-lock + existing-directory path is **out of scope** for CDT-162. WP 1-06 (CDT-298) adds one check to it:
  - Before it writes the lock, `ensure` MUST make sure that `$MROOT/.worktrees/<slug>` is a git worktree. The check passes only when `<wt>/.git` exists and `git -C <wt> rev-parse --show-toplevel` equals the resolved `<wt>` path.
  - The exit code of `git -C <wt>` alone is not enough. For a plain directory under `$MROOT/.worktrees/`, git walks up and finds `$MROOT`.
  - When the check fails, `ensure` MUST print the directory on stderr, MUST NOT write `.wt-lock`, MUST leave stdout empty and MUST exit `1`.
  - When the check passes, `ensure` stamps the lock. This behavior does not change.
  - The FRESH and STALE lock paths do not get this check in WP 1-06.

### `release [--preview] <slug>` semantics
- MUST remove `$MROOT/.worktrees/<slug>/.wt-lock`
- MUST run `git worktree remove "$MROOT/.worktrees/<slug>"` with no `--force`
- MUST NOT fall back to `git worktree remove --force` (WP 1-06, CDT-298). A second run of the dirty check does not make a forced remove safe: a file can change after any check.
- If `git worktree remove` fails after the dirty check passed (for example, a file changed after the check, or the worktree is locked), `release` MUST exit `1` with a stderr message. The worktree directory, the `feat/<slug>` branch and the `branch.feat/<slug>` config section MUST stay unchanged.
- MUST exit non-zero (exit `1`) with a clear stderr message if the worktree has uncommitted changes; MUST NOT force-remove
- Dirty definition for `release` (and for `ensure` STALE reclaim): `git -C <wt> status --porcelain` output with lines matching the exact bookkeeping path `.wt-lock` excluded; any remaining line means dirty
- **Branch delete (WP 1-06).** After the worktree is removed, and only when `refs/heads/feat/<slug>` exists:
  1. Resolve the base with `git-safety.sh -C "$MROOT" resolve-base` (SPEC-025 M17).
  2. Delete the branch with `git-safety.sh -C "$MROOT" safe-delete-branch feat/<slug> <base>`. This deletes the branch only when `is-merged` holds, so a squash-merged branch is deleted.
  3. When the branch is deleted, remove the `branch.feat/<slug>` config section.
  4. When the base does not resolve, or `safe-delete-branch` refuses, MUST keep the branch and its config section. MUST print `release: kept feat/<slug>: not merged into <base>` (or `release: kept feat/<slug>: no base`) on stderr. MUST exit `0`.
  - `release` MUST NOT run `git branch -D` directly. The only delete path is `safe-delete-branch`.
  - Exit `0` for a kept branch is deliberate. Callers such as `skills/refactor/SKILL.md` run `release || exit 1`, and a kept branch is not a failure. Callers do not change.
- MUST exit 0 on clean removal, when the branch is deleted and when the branch is kept
- **`--preview` (WP 1-06, rv-w3-08).** `release --preview <slug>` is read-only. It MUST NOT remove the lock, the worktree, the branch or the config section. It does not need the worktree directory. It MUST print exactly these eight lines on stdout, in this order, and exit `0`:
  ```
  branch: feat/<slug>|none
  base: <ref>|none
  ahead_of_base: <n>
  upstream: <ref>|none
  ahead_of_upstream: <n>
  merged: yes|no
  pushed: yes|no
  confirm: slug|yesno
  ```
  - `base` is the output of `git-safety.sh resolve-base`.
  - `ahead_of_base` is `git rev-list --count <base>..feat/<slug>`. With no base, it counts every commit of `feat/<slug>`.
  - `upstream` is the short name of `feat/<slug>@{upstream}`, or `none`.
  - `ahead_of_upstream` is `git rev-list --count feat/<slug>@{upstream}..feat/<slug>`. With no upstream, it is `git rev-list --count feat/<slug> --not --remotes` (commits on no remote ref).
  - `merged` is `yes` when `git-safety.sh is-merged refs/heads/feat/<slug> <base>` exits `0`. With no base, it is `no`.
  - `pushed` is `yes` when `git-safety.sh is-pushed feat/<slug>` exits `0`. Use the short branch name: `refs/heads/<b>@{upstream}` does not resolve (verified on git 2.53).
  - `confirm` is `slug` when the branch exists and `merged` is `no`. Else it is `yesno`, whatever the `pushed` value. `pushed`, `upstream` and the counts are information only (D2 revised): `release` deletes only a merged branch, so the work of a merged branch is already on the base.
  - When the branch does not exist, the counts are `0`, `merged` and `pushed` are `no`, and `confirm` is `yesno`. Nothing is deleted.
  - When a count fails with a git error, print `?` for that count. `confirm` still follows `merged`. A git error in `is-merged` gives `merged: no`, so `confirm: slug`.
  - An invalid slug exits `64`.

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

### `/worktree` user command (CDV-189; reduced CDT-46-C4)

- MUST provide a user-invocable command `commands/worktree.md` as a **reduced mutate-only** Surface (NOT a Deprecation stub)
- MUST support only the mutating action: `release <slug>`
- `release <slug>` MUST ask for **chat confirmation** before calling `worktree-lib.sh release <slug>`; on decline, MUST NOT call release
- **Counts and typed slug (WP 1-06, rv-w3-08).** Before it asks, `release <slug>` MUST run `worktree-lib.sh release --preview <slug>` and show `ahead_of_base`, `ahead_of_upstream` (or `no upstream`), `merged` and `pushed`.
  - When the preview prints `confirm: slug`, the command MUST accept only the exact typed slug as confirmation. `yes` is not confirmation.
  - When the preview prints `confirm: yesno`, a plain yes/no answer is enough.
  - The prompt MUST state what the lib does: it removes the worktree only when the tree is clean, it never force-removes, and it deletes `feat/<slug>` only when the branch is merged. An unmerged branch is kept.
  - The prompt stays a chat confirmation. It MUST NOT move into the lib's `/dev/tty` path.
- MUST reuse lib dirty-tree refusal; MUST NOT force-remove
- `status` / `list` args on `/worktree` MUST print usage pointing to `/status worktree` and MUST NOT invoke `worktree-lib.sh status` (read-only listing moved to `/status`)
- bare or unknown args MUST print usage: `release <slug>` + pointer to `/status worktree`

### `/status worktree` read-only views (CDT-46-C4)

- MUST provide worktree **status|list** display via `/status worktree` (see also SPEC-009 Standup entry under `/status`)
- `/status worktree` MUST shell out to `worktree-lib.sh status` (plugin-dir resolved) — same lib semantics as former `/worktree status|list`
- `/status` (and its worktree sub) MUST NOT call `worktree-lib.sh release` or otherwise mutate worktrees, locks, or branches

### Caller integration
- Callers MUST resolve `worktree-lib.sh` through `plugin-dir.sh` (install-aware: the script ships in the plugin, not the user's repo) — emit the canonical bootstrap stanza (SPEC-002) to set `$PDH`, then `WT_LIB=$(bash "$PDH/skills/plugin-dir.sh" file skills/worktree-lib.sh)`. MUST NOT invoke the cwd-relative form `bash skills/worktree-lib.sh` (absent on a real install) nor `$MROOT/skills/worktree-lib.sh` (resolves to the user's repo, not the plugin)
- `skills/orchestrate/SKILL.md` Step 3 MUST call `bash "$WT_LIB" ensure <slug>` as a subprocess and capture stdout as the worktree path. MUST remove the legacy sibling-path creation. On exit 1: surface the stderr error to the user and halt. On exit 2: halt cleanly without error
- `skills/kickoff/SKILL.md` MUST call `bash "$WT_LIB" ensure <slug>` as a subprocess **before any spec commit, plan write, or task-graph creation** — placed immediately after context load (Step 1) and before the parallel PM+Tech Lead spawn (Step 2), mirroring `/orchestrate`'s Step 3→4 ordering. The slug MUST be the bare `<TICKET-ID>` (identical to `/orchestrate` Step 3's `SLUG`) so a later `/orchestrate <TICKET-ID>` reuses the same worktree via `ensure`'s same-slug reuse path rather than creating a second tree (CDT-105). MUST capture stdout as `$WT_PATH` and MUST handle exit codes distinctly: `0` = proceed with `$WT_PATH`; `1` = surface stderr and halt; `2` = user aborted the collision prompt, halt cleanly; `64` = invalid slug, halt and report. MUST NOT silently proceed without a worktree — a planning run without `$WT_PATH` would fall back to committing the spec on the current branch (the CDT-105 origin defect: `/kickoff` committing straight to master). MUST redefine the plan/spec-commit root to `$WT_PATH` for the remainder of the run (spec `git add` targets `$WT_PATH/specs` via `git -C "$WT_PATH"`; plan file writes under `$WT_PATH/.claude/plans/`). MUST NOT call `bash "$WT_LIB" release` at its own exit — releasing would destroy the just-written spec/plan before any implementation; the worktree is left as documented resumable state (SPEC-009 § Kickoff). No producer holds a live worktree when it invokes `/kickoff` on an escalation route (`/refactor` releases its worktree before handing off — `skills/refactor/SKILL.md` § 2.2a.5; `/debug` escalate/arch paths create none), so this `ensure` is always a clean create and never double-creates or orphans
- `skills/wrap-ticket/SKILL.md` Step 6 MUST call `bash "$WT_LIB" release <slug>` as a subprocess. MUST remove any direct `git worktree remove` call targeting `.worktrees/` paths
- `skills/wrap-ticket/SKILL.md` MUST detect both `.worktrees/<slug>` (new) and `$MROOT/../<project>-<TICKET-ID>` (legacy) worktree paths; MUST prefer the new path when both exist
- `skills/wrap-ticket/SKILL.md` MUST anchor every `grep` for a TICKET-ID so `WISO-1` does not match `WISO-10` (use `grep -E "(^|[^A-Z0-9-])WISO-1([^0-9]|$)"` or `grep -wF`); fix everywhere wrap-ticket greps for ticket ID
- **One worktree matcher (WP 1-06).** `skills/wrap-ticket/SKILL.md` MUST resolve the ticket worktree through `bash skills/wrap-ticket/resolve-worktree.sh <TICKET-ID>` (resolved through `plugin-dir.sh`) in Step 0, Step 2 and Step 6. No fence keeps its own matcher.
  - The helper prints one absolute path, or nothing, and exits `0`. An empty or invalid id (not `^[A-Za-z0-9_-]+$`) exits `64`.
  - Order: (1) the epic shared integration path (`resolve-child-worktree` gives `use_shared: true`); (2) `$MROOT/.worktrees/<TICKET-ID>` when the directory exists; (3) a legacy entry from `git worktree list --porcelain` whose branch line is exactly `branch refs/heads/feat/<TICKET-ID>`, or whose basename equals `<TICKET-ID>` or ends with `-<TICKET-ID>`.
  - The helper MUST NOT match by substring or by `grep -w`. `CDT-1` MUST NOT match `CDT-1-2`.
- **Legacy path delete (WP 1-06, rv-w1-04).** In Step 6, when the legacy lookup is empty, the fence MUST print a skip message and exit `0` with no `git worktree remove` and no `git branch` call. Else it runs `git worktree remove` with no `--force`, then `git-safety.sh safe-delete-branch feat/<TICKET-ID> <base>` with the base from `git-safety.sh resolve-base`. An unmerged branch MUST be kept, and a message MUST name it. `SKILL.md` MUST NOT run `git branch -D "feat/$TICKET_ID"`.
- **Step 6 confirmation (WP 1-06, rv-w3-08).** The Step 6 prompt MUST follow the `/worktree` counts and typed-slug rule (§ `/worktree` user command). It MUST NOT state that the branch "has already been merged".
- **OBSOLETE at v1.0.0 (CDT-46-C2):** `/demo` was removed (`skills/demo/SKILL.md` is now a deprecation stub); this requirement is retained one deprecation cycle as historical record only. ~~`skills/demo/SKILL.md` MUST keep its dedicated `$TMPDIR/demo-project` path and MUST NOT depend on `worktree-lib.sh`. MUST add a 2-3 line inline check at worktree creation: if path exists, prompt user before proceeding~~
- `AGENTS.md` MUST contain a "Worktree Protocol" section that: declares `.worktrees/<slug>` as the canonical path, points to `skills/worktree-lib.sh` and SPEC-016, and states in one sentence that sibling-directory worktrees are forbidden when the lib is in use
- `AGENTS.md` Worktree Protocol SHOULD mention `/worktree release <slug>` (mutate) and `/status worktree` (read-only list) as the user-facing surfaces

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
- SHOULD exclude `.wt-lock` from the dirty-tree check in `release` and in `ensure` STALE reclaim (it is bookkeeping, not user content)
- SHOULD share one dirty-tree helper between `release` and `ensure` STALE reclaim so the porcelain filter cannot drift

## MUST NOT

- MUST NOT source `worktree-lib.sh`; subprocess invocation only (matches `task-store.sh`, `gate.sh` precedent)
- MUST NOT silently reuse a worktree whose lock is still FRESH (age < `WT_LOCK_TTL_SECONDS`); MUST prompt (abort/steal) instead
- MUST NOT overwrite a STALE `.wt-lock` when the worktree is dirty (release-equivalent porcelain) or when `slug_has_live_task` is true (CDT-162)
- MUST NOT delete or `--force` a worktree with uncommitted changes
- MUST NOT fall back to `git worktree remove --force` in `release` (WP 1-06)
- MUST NOT delete `feat/<slug>` in `release` or in the wrap-ticket legacy path unless `git-safety.sh is-merged` holds against the resolved base (WP 1-06)
- MUST NOT stamp `.wt-lock` on an existing directory that is not a git worktree (`ensure` no-lock path; WP 1-06)
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

Field 1 (epoch seconds) is authoritative — freshness is `now - epoch` compared against `WT_LOCK_TTL_SECONDS`. Field 2 (ISO timestamp) is human-readable only. The lock is advisory: it records *when* a worktree was claimed, not *who* holds it (the holder is an LLM agent/conversation, not a checkable OS process). Legacy `<SESSION_ID> <PID> <ISO>` locks have a non-numeric field 1 and classify as STALE; reclaim still requires a clean tree and no live task (CDT-162).

## Exit code contract

| Code | Meaning |
|------|---------|
| 0 | Success — worktree ready, path on stdout; `release` done (branch deleted, or an unmerged branch kept with a stderr warning); `release --preview` printed |
| 1 | Safety/error — `release` missing worktree, dirty tree or failed `git worktree remove`; `ensure` STALE reclaim refused (dirty tree or live task); `ensure` on an existing directory that is not a git worktree; `register` missing dir |
| 2 | User aborted on prompt (FRESH lock collision declined or no answer given) |
| 64 | Usage error — missing slug or unknown subcommand |
| non-zero (other) | Fatal error |

Caller contract (unchanged): exit `1` → surface stderr and halt; exit `2` → clean halt; MUST NOT treat a non-zero exit as success or consume a path from stdout.

## Test

- Verify `ensure <slug>` creates `.worktrees/<slug>`, branch `feat/<slug>`, and `.wt-lock` in `<epoch> <ISO>` format; prints absolute path; exits 0
- Verify `ensure` create-path has no bare `git worktree add` (both arms invoke `git_retry 3 200`); optional: EBUSY within budget → exit 0 + path + lock; exhausted EBUSY → non-zero, empty stdout, no success lock (CDT-161)
- Verify `ensure` against a FRESH lock (epoch = now, age < TTL): stderr shows summary, exit 2 on abort, stdout empty
- Verify `ensure` against a **clean** STALE lock (age >= TTL, or unparseable/legacy `PID TS` format) with **no** live task: overwrites lock, exits 0, prints path (AC-3 / AC-9)
- Verify `ensure` against a **dirty** STALE lock: does **not** overwrite lock, exit 1, empty stdout, stderr reason (AC-1 / AC-2 / AC-4 / AC-9)
- Verify `ensure` against a **clean** STALE lock with a **live** task (`pending`/`in_progress`/`blocked` referencing slug): does **not** overwrite lock, exit 1, empty stdout, stderr reason (AC-5 / AC-9)
- Verify `ensure` FRESH path unchanged (collision summary + abort/steal / no-TTY exit 2) (AC-8 / AC-9)
- Verify `ensure` no-TTY / unwritable `/dev/tty` collision (e.g. `setsid … </dev/null` against a FRESH lock): prompts on stderr, exits 2, stdout empty, no "No such device" on stderr
- Verify `release` cleans `.wt-lock` + removes worktree on clean tree; exits non-zero on dirty tree without force
- Verify `release` has no `worktree remove --force` and no direct `branch -D`; a locked clean worktree gives exit 1 and keeps the directory, the branch and its config (WP 1-06)
- Verify `release` deletes a merged (fast-forward or squash) `feat/<slug>` and keeps an unmerged one with exit 0 and a stderr warning (WP 1-06)
- Verify `release --preview` prints the eight lines and changes nothing; `confirm: slug` only for an unmerged branch; a merged branch gives `confirm: yesno` whether pushed or not (WP 1-06)
- Verify `ensure` on a plain directory under `.worktrees/` exits 1 with no lock and empty stdout (WP 1-06)
- Verify orchestrate Step 3 captures stdout path correctly and halts on exit 1/2
- Verify wrap-ticket grep does not match `WISO-10` when looking for `WISO-1`
- Verify wrap-ticket detects both `.worktrees/<slug>` and legacy sibling path; prefers new
- Verify `status`/`list` list only `$MROOT/.worktrees/*`; show FRESH|STALE|NONE by epoch age; no PID/session fields; exit 0 when empty
- Verify `register <slug>` stamps lock without creating branch/worktree; exit 1 if dir missing
- Verify `sweep` prints proposals only and never deletes worktree/lock/branch
- Verify `/worktree release` requires chat confirmation before calling lib release
- Verify `/worktree release` and wrap-ticket Step 6 run `release --preview`, show both counts and require the typed slug when the preview prints `confirm: slug` (WP 1-06)
- Verify `resolve-worktree.sh CDT-1` does not return the `CDT-1-2` worktree, and the wrap-ticket legacy path keeps an unmerged branch (WP 1-06)

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
- [ ] `status`/`list`/`register`/`sweep` subcommands exist on the **lib** (CDV-189)
- [ ] `commands/worktree.md` is reduce-to-release only; listing is `/status worktree` (CDT-46-C4)
- [ ] Proposed extension 'Worktree lifecycle hooks' remains DRAFT until provider redesign + promotion

## Open Questions

- [ ] Should `ensure` accept a `--no-prompt` / `--steal` flag for fully non-interactive callers (CI)? Currently unwritable `/dev/tty` aborts with exit 2 (CDV-201); if CI needs reclaim without TTY, add later.
- [ ] Should `release` support an explicit `--force` for callers that have already confirmed loss is acceptable? Out of scope for v1. WP 1-06 does not add it: `release` keeps an unmerged branch and exits 0, so no caller needs `--force` to finish a release.
- [x] ~~Do WorktreeCreate/Remove support exit-2 enforcement?~~ **No** (CDV-189 spike). Remove has no decision control; Create is a provider that must print path.
- [ ] Future: should the plugin wire WorktreeCreate as isolation provider (`ensure` + path stdout) for `--worktree` / `isolation: worktree`? Separate ticket; do not wire in init-orchestration until intentional.

## Version History

| Date | Change |
|------|--------|

| 2026-09-28 | WP 1-06 (`wp-1-06-branch-deletion-safety`; CDT-278 `[06 F20]` `[06 F21]` `[06 F22]`, CDT-298 `[10 worktree-lib-misc]`, rv-w1-04, rv-p0-03, rv-w3-08). `release` has no `--force` fallback: a failed `git worktree remove` exits 1 and keeps the directory, branch and config. `release` deletes `feat/<slug>` only through `git-safety.sh safe-delete-branch`; an unmerged branch is kept with a stderr warning and exit 0 (callers unchanged). New `release --preview <slug>` prints base and upstream counts plus the `confirm` rule. `/worktree release` and wrap-ticket Step 6 show the counts and require the typed slug only when the branch is not merged (the pushed state is information only). `ensure` refuses an existing directory that is not a git worktree (no-lock path only). wrap-ticket resolves its worktree through one helper, `skills/wrap-ticket/resolve-worktree.sh`; the legacy path uses an exact match and keeps an unmerged branch. Exit-code table updated. New `## Acceptance criteria` section holds this WP's ACs. |
| 2026-08-07 | CDT-161: ensure create-path MUST use `git_retry 3 200` for both `worktree add` arms (parity with release mutators); re-probe branch after failed `-b` so sticky `-b` is not used once `feat/<slug>` exists; no new exit-code contract (passthrough `git_retry` rc). |
| 2026-08-07 | CDT-162: `ensure` STALE reclaim is no longer unconditional. Dirty STALE (release-equivalent porcelain, excl `.wt-lock`) and STALE with a live task (`slug_has_live_task`) MUST refuse reclaim — no lock overwrite, empty stdout, exit `1`. Clean STALE with no live task still overwrites lock and exits 0 with path. FRESH path and no-lock+existing-dir path unchanged. Exit-code table: exit `1` is shared safety/error for release and ensure STALE guards. |
| 2026-08-02 | CDT-105: added `skills/kickoff/SKILL.md` as a create-caller. `/kickoff` MUST `ensure <TICKET-ID>` after context load and before the PM+TL spawn (mirroring orchestrate Step 3→4), commit its spec/plan/task work inside `$WT_PATH` (never `$MROOT`), and MUST NOT `release` at exit — the worktree is a resumable planning handoff (SPEC-009). Bare-`<TICKET-ID>` slug makes a later `/orchestrate <TICKET-ID>` reuse the same tree. Fixes the origin defect where standalone `/kickoff` committed the spec straight to master (CDT-104 a049044, CDT-99 0fdf420). No producer holds a live worktree at `/kickoff` handoff time (refactor releases first; debug creates none), so no double-create/orphan. |
| 2026-07-22 | CDT-46-C4: `/worktree` reduced to mutate-only `release <slug>` (chat confirm retained). Read-only status\|list moves to `/status worktree`. `/worktree` is NOT a Deprecation stub. AGENTS Worktree Protocol SHOULD cite both surfaces. Lib `status`/`list`/`register`/`sweep` unchanged. |
| 2026-07-21 | CDT-46-C2: `/demo` removed in the v1.0 surface-cleanup pass (`skills/demo/SKILL.md` → deprecation stub). Marked the demo-specific MUST and its validation checkbox OBSOLETE-at-v1.0.0 (retained one cycle as historical record, not deleted); annotated the demo Covers entry as a DEPRECATED stub. Worktree-lib/orchestrate/wrap-ticket behavior unchanged. |
| 2026-07-14 | CDV-189: promoted Part 2 lib surface (`status`/`list`/`register`/`sweep`) + `/worktree` command MUSTs; lock model remains epoch FRESH\|STALE. Lifecycle hooks WLH kept DRAFT after spike: WorktreeCreate/Remove **exist** (docs + changelog, CC ≥ event-add, local 2.1.190) but Create **replaces** git and must print path; Remove has **no** exit-2 block. Dirty/FRESH enforcement stays in `release` + user command. |
| 2026-07-13 | CDV-201: FRESH-lock prompt probes TTY via successful `printf >/dev/tty` (not `-r` alone). Unwritable `/dev/tty` (no controlling TTY / ENXIO) prints prompt to stderr and exits 2 cleanly under `set -e` instead of dying exit 1 with "No such device". Steal only on explicit `steal`. |
| 2026-06-16 | CLUSTER-003/A5: caller-integration MUSTs changed from the cwd-relative `bash skills/worktree-lib.sh` to install-aware resolution via `plugin-dir.sh` (`WT_LIB=$(bash "$PDH/skills/plugin-dir.sh" file skills/worktree-lib.sh)`). The cwd-relative form (and `$MROOT/skills/…`) is absent / wrong on a real cache install where the script ships in the plugin, not the user's repo. The lib still self-resolves `$MROOT` internally for worktree data paths. |
| 2026-06-16 | Switched the lock from PID-liveness to advisory, age-based locking. The lock now holds `<epoch-seconds> <ISO-8601-UTC>`; freshness is `now - epoch` vs `WT_LOCK_TTL_SECONDS` (env-overridable, default 6h). Rationale: the holder is an LLM agent/conversation, not an OS process — `kill -0` liveness was structurally unworkable (the old code recorded `worktree-lib.sh`'s own ephemeral subprocess PID, so collision detection never fired). FRESH → prompt abort/steal; STALE (age ≥ TTL or unparseable) → silent reclaim; legacy `PID TS` locks auto-reclaim as stale. Reconciles the prior 3-field-spec (`SESSION_ID PID ISO`) vs 2-field-code (`PID ISO`) drift (CLUSTER-004). |
| 2026-04-29 | Exit code table corrected to match implementation (exit 1 = release error, exit 2 = abort/decline, exit 64 = usage). Added SHOULD for .wt-lock dirty-check exclusion. |
| 2026-04-28 | Initial spec for WISO-001. |
## Cross-references

- SPEC-002: Plugin Infrastructure — `$MROOT` resolution formula; subprocess CLI precedent (`task-store.sh`, `gate.sh`); kickoff caller-integration row (site table)
- SPEC-009: Ticket Workflow — wrap-ticket worktree cleanup MUSTs; orchestrate Step 3 ownership; `$MROOT` worktree-aware resolution; **owns the kickoff worktree lifecycle / resumable-state exit contract** (CDT-105)
- SPEC-031: Escalation Gate & Universal Worktree Isolation — its bounded-exit "MUST NOT leave a worktree as final state" is scoped to *implementation-capable* skills that ship code; `/kickoff` ships spec+plan (no source edits) and its worktree is deliberately the handoff artifact, so that rule does NOT extend here (CDT-105)
- SPEC-025: Epic Umbrella Decomposition — M17 owns `skills/lib/git-safety.sh` (`resolve-base`, `is-merged`, `is-pushed`, `safe-delete-branch`). `release`, `release --preview` and the wrap-ticket legacy path consume it (WP 1-06)
- SPEC-009: Ticket Workflow — owns `skills/wrap-ticket/prune-remote.sh` (remote prune MUSTs, WP 1-06 lease amendment). The WP 1-06 ACs below cover both specs

## Acceptance criteria

Format and rules: SPEC-033 M14(g) and M14(h). Each ticket that ships through M14 has one
`### <ticket_id>` subsection below.

### wp-1-06-branch-deletion-safety

- **A.** wrap-ticket learnings fences (CDT-278 F20, F21). (1) The Step 2 fences set `TICKET_ID="<TICKET-ID>"` and read the worktree from `resolve-worktree.sh`. Fixture: MROOT and `.worktrees/<ID>/.claude/memory/<agent>/context.md` hold different text. The extracted Step 2 fences, run from MROOT, print the worktree text and not the MROOT text. The plan lookup prints the matching plan name from the worktree `.claude/plans/` first, then from MROOT. With the worktree removed, the fence prints a warning and reads MROOT. (2) Each fence in `SKILL.md` that uses `$TICKET_ID` sets `TICKET_ID="<TICKET-ID>"`. No `lint-ok: C1` waiver is on a line that uses `$TICKET_ID`, and `bash skills/skill-lint/check-skill-bash.sh skills/wrap-ticket/SKILL.md` reports no C1. (3) `## Step 5:` comes before `## Step 5.5:`. (4) The Step 3 write fence resolves `MROOT` before `MEMDB` and takes the learnings from a quoted heredoc or a file, never from a double-quoted literal. Payload: `$(touch x)`, a backtick `touch y` and a `"`. The fence creates no `x` and no `y`, and the stored text equals the payload byte for byte, on the sqlite path and on the `.md` fallback path.
  Verify: bash skills/wrap-ticket/wrap-ticket-test.sh
- **B.** wrap-ticket worktree match and legacy delete (rv-w1-04). (1) `SKILL.md` has no `:-{}}`. Each `CHILD_WT` default uses a separate variable (`DEF='{}'`, then `${CHILD_WT:-$DEF}`). The extracted jq lines give exit 0 and empty stderr with `CHILD_WT='{"skip_release":false,"use_shared":false}'` and with an empty `CHILD_WT`. (2) Fixture: legacy worktrees on `feat/CDT-1` and `feat/CDT-1-2`. `resolve-worktree.sh CDT-1` prints only the `CDT-1` path. Step 0, Step 2 and Step 6 call the helper, and no `grep -wF "$TICKET_ID"` over `git worktree list` output remains. (3) The extracted Step 6 legacy fence for `CDT-1` removes only the `CDT-1` tree. The `CDT-1-2` tree and branch stay. (4) With an empty lookup, the fence prints a skip message, exits 0 and makes zero `git worktree remove` and `git branch` calls (PATH shim). (5) An unmerged `feat/CDT-1` (one unique commit) stays, and a message names it. A merged branch, fast-forward or squash, is deleted. `SKILL.md` has no `git branch -D "feat/$TICKET_ID"`. (6) The Step 6 line reads `cd "$MROOT"`, and no unquoted `cd $MROOT` remains.
  Verify: bash skills/wrap-ticket/wrap-ticket-test.sh
- **C.** prune-remote checks the fetched remote ref (CDT-278 F22, rv-p0-03). (1) For each allowlisted candidate, prune runs `git fetch origin "+refs/heads/<n>:refs/remotes/origin/<n>"` before its check. The check is `git-safety.sh is-merged refs/remotes/origin/<n> <base>` and never reads `refs/heads/<n>`. (2) Bare-remote fixture: the local `feat/CDT-9` is merged and the remote `feat/CDT-9` has one extra commit. The remote branch stays, and the output has `leftover: feat/CDT-9 (unique commits)`. A second fixture with a stale tracking ref behind the remote gives the same result. (3) On bare-remote fixtures, a fast-forward-merged and a squash-merged remote branch print `pruned:` in `--dry-run` and in a live run, and the live run deletes them. (4) `--dry-run` fetches when `origin` exists. With no `origin`, `--dry-run` uses local refs as before. (5) A fetch that fails with `couldn't find remote ref` is a silent skip with exit 0. Any other fetch failure (fixture: the origin URL is a missing path) prints one `remote prune failed: <n>: <err>` line, deletes nothing and exits 0.
  Verify: bash skills/wrap-ticket/prune-remote-test.sh
- **D.** prune-remote deletes with a lease and reports every failure (rv-p0-03). (1) The delete is `git push --force-with-lease=refs/heads/<n>:<sha> origin :refs/heads/<n>`, where `<sha>` is the fetched SHA that the check evaluated. Fixture: a `git` PATH shim moves the remote branch between the check and the push. The push is refused, the remote branch stays, and the output has `remote prune failed: feat/<n>: …`. (2) Static check: `prune-remote.sh` has `--force-with-lease` and no bare `--force` (regex `--force([^-]|$)`). This check replaces the old `--force` assertion. (3) Only `remote ref does not exist` and `src refspec … does not match` count as already gone. A push stub that prints `repository does not exist` or an auth failure gives a `remote prune failed:` line, not a silent skip. (4) With two failing candidates, the output has exactly two `remote prune failed:` lines, and each failure is one line (multi-line git stderr is joined). (5) The usage, allowlist, candidates, fail-open, SKILL 6.x, worktree-lib and no-glob cases pass.
  Verify: bash skills/wrap-ticket/prune-remote-test.sh
- **E.** worktree-lib `release` never forces and keeps an unmerged branch (CDT-298, D1). (1) `worktree-lib.sh` has no `worktree remove --force` and no `branch -D`. (2) Fixture: a clean worktree locked with `git worktree lock`. `release` exits 1 with stderr, and the worktree directory, `feat/<slug>` and the `branch.feat/<slug>` config section stay. (3) A merged branch, fast-forward or squash, is deleted: `release` exits 0, and the worktree, the branch and the config section are gone. (4) An unmerged branch (one unique commit): `release` exits 0, the worktree is gone, the branch and its config section stay, and stderr has `release: kept feat/<slug>`. (5) A dirty tree still gives exit 1 with no change.
  Verify: bash skills/worktree-lib-test.sh
- **F.** worktree-lib `ensure` refuses a non-git directory, and the suite leaks no temp file (CDT-298). (1) `ensure <slug>` for an existing `.worktrees/<slug>` with no `.git` entry exits 1, prints the directory on stderr, prints nothing on stdout and writes no `.wt-lock`. The check compares `git -C <wt> rev-parse --show-toplevel` with `<wt>`. (2) The `status`, `register` and `sweep` cases that use plain directories still pass. (3) `ERR_TMP` is under `$TMP`. A run with a new empty `TMPDIR` leaves no `wt-test-err.*` file in it.
  Verify: bash skills/worktree-lib-test.sh
- **G.** `release` shows counts and asks for the typed slug (rv-w3-08, D2). (1) `release --preview <slug>` prints the eight lines of SPEC-016 § `release` in order. Fixtures: a squash-merged branch whose upstream contains it gives `merged: yes`, `pushed: yes`, `confirm: yesno` and `ahead_of_base` above 0. A squash-merged branch with no upstream gives `merged: yes`, `pushed: no` and `confirm: yesno`. An unmerged branch gives `merged: no` and `confirm: slug`. A branch with no upstream gives `upstream: none`, and `ahead_of_upstream` counts the commits that are on no remote ref. (2) After `--preview`, the lock, the worktree, the branch and the config section are unchanged. (3) Static check: the release step of `commands/worktree.md` and Step 6 of `skills/wrap-ticket/SKILL.md` both run `release --preview` before they ask, show both counts, accept only the typed slug when the preview prints `confirm: slug`, and accept yes/no when it prints `confirm: yesno`. `SKILL.md` has no "has already been merged".
  Verify: bash skills/worktree-lib-test.sh
- **H.** The docs match the lib (rv-w3-08). `docs/commands/worktree.md` and Step 9 of `docs/commands/wrap-ticket.md` state that release never force-removes, deletes `feat/<slug>` only when it is merged, keeps an unmerged branch with a warning, and shows the counts and asks for the typed slug when the branch is not merged. A grep check fails when either page says that release removes the branch with no merge condition, or when `wrap-ticket.md` describes a plain `git worktree remove`. The text follows ASD-STE100.
  Verify: bash skills/worktree-lib-test.sh
- **I.** One shared base resolver (D2). `git-safety.sh resolve-base` prints the first ref that resolves, in this order: the target of `refs/remotes/origin/HEAD`, `origin/master`, `origin/main`, `master`, `main`. It exits 0, or exits 1 with empty stdout when no ref resolves. Tests cover each step of the order and the no-ref case. `prune-remote.sh` (after its `--base` flag) and `worktree-lib.sh` call it. A grep check finds no copy of the order list in `prune-remote.sh`, `worktree-lib.sh` or `skills/wrap-ticket/SKILL.md`.
  Verify: bash skills/lib/git-safety-test.sh
- **J.** [process] These suites pass: `skills/wrap-ticket/wrap-ticket-test.sh`, `skills/wrap-ticket/prune-remote-test.sh`, `skills/worktree-lib-test.sh`, `skills/lib/git-safety-test.sh` and `skills/skill-lint/test.sh`.
- **K.** [process] Every `/release` gate passes.
