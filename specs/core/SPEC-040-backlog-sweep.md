# SPEC-040: Backlog Sweep

**Status**: ACTIVE
**Category**: core
**Created**: 2026-10-22

**Covers**: `skills/backlog/SKILL.md`, `skills/backlog/close.sh`, `skills/backlog/terminal-status.sh`, `skills/release/check-ship-history.sh`, `skills/lib/sqlq.sh`, `skills/autopilot/nest-host.sh`, `docs/commands/backlog.md`, `README.md`, `.gitignore`, `specs/TDD.md`

## Overview

A Backlog sweep is a composition layer over `/backlog` and `/orchestrate`.
It walks every open backlog item, runs a Purge pre-pass, then a size-ascending
serial walk. It never edits product code and never runs `/release`.
This spec defines sweep behavior. Cite SPEC-009 (list/close/reconcile),
SPEC-013 (council tier), SPEC-016 (serial worktrees), SPEC-025 (epic children),
SPEC-033 (autopilot, decision-cards, blocking-condition, complexity-overflow),
and SPEC-002 D1 (one operational copy). Do not restate those contracts.

Glossary: Backlog sweep, Disposition, Triage size, Purge pre-pass,
Mechanical evidence (`CONTEXT.md`).

Phase 1 (this ticket): purge + CLOSE/ASK/ORCHESTRATE/DEFER + walk + journal.
Phase 2 (spec text only): MERGE + EPIC + BC5 mid-flight reroute.

## MUST

### Surface and contract home (AC1, AC16)

- **M1 — Subcommand.** `/backlog sweep` is a subcommand of the existing
  skill-only Surface. MUST NOT add `commands/backlog.md`. MUST NOT add a
  top-level `/sweep` command. `skills/backlog/SKILL.md` MUST add one table
  row plus a pointer to the sidecar protocol. After that edit, `SKILL.md`
  MUST stay under 30720 bytes (SPEC-035 skill-size WARN).
- **M2 — Sidecar protocol (SPEC-002 D1).** The one operational copy of the
  sweep protocol is the sidecar file next to `SKILL.md` named `sweep.md`.
  Helpers live in `sweep.sh` (subprocess CLI, never sourced). Callers MUST
  cite those files. MUST NOT inline the protocol into `SKILL.md`.
- **M3 — Name collision.** `fold-sweep.sh` stays the post-ship close-out
  (SPEC-009). Sweep MUST NOT source, wrap, or rename it.
- **M4 — No product edits.** Sweep MAY write `$MROOT/.claude/sweeps/` and
  MAY flip tracker state only through close/defer verbs. MUST NOT invoke
  `/release`. MUST NOT edit files outside those two classes.

### Open set (AC1, AC10)

- **M5 — Enumerate.** Open set follows `/backlog list` semantics (SPEC-009):
  Linear preferred when MCP is up; local write-through merged by `linear_id`;
  local-only PENDING rows included; every open item exactly once.
  `--project` filters the Linear query only.
- **M6 — Linear-down.** On MCP down or error, print exactly one line
  `Linear unreachable — local backlog only.` then continue local-only.
  MUST NOT retry-loop.
- **M7 — Epic children skipped.** An item with local `epic_parent`
  frontmatter OR a non-empty Linear `parentId` is SKIP: no triage, no
  journal record, counted in the summary. Cite SPEC-025 for `parentId`
  inventory; do not restate it. `list_issues.orderBy` has no priority
  field — walk sort is client-side (M18).

### Purge pre-pass (AC2, AC3, AC4, AC5, AC6, AC14)

- **M8 — Ordering.** Purge pre-pass completes over every open item before
  the first `/orchestrate` spawn. MUST NOT interleave.
- **M9 — CLOSE evidence bar.** Auto-CLOSE requires Mechanical evidence:
  two cited passages plus counts plus a date/mtime-vs-tag or spec quote,
  meeting (a) cited Affects paths absent at HEAD via argv-safe bash, or
  (b) shipped-after-creation via a CHANGELOG entry or spec dated after
  the item `Added:` date. Insufficient evidence is not a CLOSE.
  `grep` symbol-exists is ASK-only.
- **M10 — ASK floor.** Staleness signal without the evidence bar is ASK.
  MUST NOT silent-close on inference.
- **M11 — Linear-only items.** An open Linear issue with no local
  write-through file is ASK, never CLOSE (`close.sh` needs a slug).
  Under sweep `--autopilot`, that ASK becomes DEFER (M24) with a
  journal key equal to the Linear issue id.
- **M12 — Attended batch.** All proposed purge CLOSEs appear as one
  listing `slug | disposition | evidence`. Accept-all, or per-item
  removal. Each ASK is answered close/run/defer and becomes a terminal
  Disposition before the walk starts.
- **M13 — Close verbs only.** CLOSE runs `/backlog close` (Linear
  terminal when MCP up + `close.sh`; idempotent; SPEC-009). Sweep MUST
  NOT hand-write backlog index or item files.

### DEFER write path

- **M14 — New write verb.** `DEFERRED` is an open status
  (`terminal-status.sh`; SPEC-009). `close.sh --status` writes only
  `COMPLETED|FIXED/CLOSED`. Sweep MUST add `skills/backlog/defer.sh`:
  subprocess CLI, never sourced; holds the same backlog lock as
  `close.sh`; writes `**Status**: DEFERRED`; does not mark Linear
  terminal; does not prune; idempotent on already-DEFERRED; requires a
  valid slug (`^[A-Za-z0-9_-]+$`); exit 0 ok, 1 not found, 64 usage.
  Linear-only items without a local file MUST NOT call `defer.sh`
  (journal-only DEFER, M11).

### Triage size and walk (AC7, AC8, AC9, AC14)

- **M15 — Cheap signals.** Triage size uses title, body, Affects, and
  Effort frontmatter only. MUST NOT spawn agents to size. Mapping:
  S → `--tier=light`; M → `--tier` omitted (standard); L → `--tier=full`.
  `--council-tier` is forwarded only when the user set it. Orchestrate
  Step 2 stays authoritative (SPEC-009).
- **M16 — Serial walk.** Strict serial (SPEC-016). Size ascending
  (S then M then L). Within a size bucket: Linear priority 1, 2, 3, 4,
  then 0 (None); local-only items last, `Added:` ascending.
- **M17 — `--ship` compile.** Sweep flag
  `--ship=<pr|master|patch|minor|major>` compiles to orchestrate argv:
  `pr` → no autopilot flag (attended Step-11 gate); `master` →
  `--autopilot=master`; `patch|minor|major` → `--autopilot=<bump>`.
  Attended default: no `--ship` (per-ticket gate). Sweep `--autopilot`
  default `--ship` is `master`. Sweep MUST NOT pass literal `--ship` to
  `/orchestrate`. Orchestrate arg contract is unchanged (SPEC-009 / SPEC-033).
- **M18 — `--limit`.** Bounds code-bearing `/orchestrate` runs only.
  Purge always walks the full open set.
- **M19 — Nested invoke floor.** A Phase-1 nested `/orchestrate` from
  sweep probes `skills/autopilot/nest-host.sh can-spawn-agents`
  (SPEC-033 M14(l)). On false: print the compiled `/orchestrate` line
  and run it in the current host turn (print-and-run). MUST NOT claim a
  nested Agent spawn on that host.

### Journal and tag baseline (AC11, AC12, AC13)

- **M20 — Journal.** Append-only `$MROOT/.claude/sweeps/<slug>.jsonl`.
  Linear-only items (no slug) use the Linear issue id as the filename
  stem. Fields: `ts` (ISO-8601), `disposition`
  (`CLOSE|ASK|ORCHESTRATE|DEFER`), `evidence` (string), `args` (string),
  `tag_baseline` (release-tag name or empty), `outcome`
  (`closed|shipped|pr-stopped|deferred|asked-answered` or omitted).
  Walk-run mapping is `sweep.sh walk-outcome`: `--landed` prints `shipped`,
  `--halt <condition>` prints `pr-stopped`. A child halt name is not an
  outcome value.
  Intent record (no `outcome`) is written BEFORE the side effect.
  A completed record then adds `outcome`. Never staged or committed.
  `.gitignore` MUST list `.claude/sweeps/`.
- **M21 — Tag baseline.** At start, snapshot the last release tag via
  `skills/release/check-ship-history.sh` `is_release_tag`
  (`^v?[0-9]+\.[0-9]+\.[0-9]+$`). MUST NOT use bare `git describe`.
  Tags created mid-walk MUST NOT move the baseline. Empty baseline
  (no release tag) means AC13 skip never fires on date compare.
- **M22 — Re-run skip.** A journal record with a terminal `outcome`
  whose `ts` is greater than or equal to the date `sweep.sh tag-date`
  prints for the snapshotted tag (annotated tagger date, else
  tagged-commit committer date) is skipped (print why). Older records re-judge.
  Intent-without-outcome re-judges. `--refresh` forces re-judge all.
  `--skip-decided` forces skip of any terminal `outcome`. Both flags
  together are a usage error (exit 64) before any mutation. SKIP
  (epic children, M7) is a summary bucket only — no journal record.

### Autopilot sweep and summary (AC14, AC15)

- **M23 — Zero human turns.** Sweep `--autopilot` asks nothing. CLOSE
  only at the M9 bar. Every would-be ASK converts to DEFER with
  missing-evidence reason in the journal. Each spawned `/orchestrate`
  emits its own decision-cards (SPEC-033). A blocking-condition halt
  inside a run MUST NOT halt the sweep: journal the outcome, list it
  in the final summary, continue.
- **M24 — Terminal summary.** Print N open plus per-Disposition counts
  (CLOSE/ASK/ORCHESTRATE/DEFER/SKIP) plus escalations. Every item is
  in exactly one bucket. Exit 0 with escalations. Non-zero only on
  machinery failure (usage, I/O, lock).
- **M25 — Untrusted ticket text.** Title, body, Affects, and slug reach
  helpers as argv or as a JSON file path. SQL (if any) goes through
  `skills/lib/sqlq.sh`. MUST NOT `eval` or `bash -c` ticket text.

### Phase 2 (spec only; no Phase-1 code)

- **M26 — MERGE.** Journal names the surviving slug plus Mechanical
  evidence. Attended confirms in the purge batch. Autopilot converts
  ASK to DEFER (never auto-merge unattended). Close the absorbed item
  via M13 verbs.
- **M27 — EPIC disposition.** An item that meets SPEC-033 AC4/M10
  complexity-overflow or a Workstream split hands off mid-walk to
  `/epic`. Journal the epic id. Continue the walk. New children carry
  `epic_parent` and are skipped via M7.
- **M28 — BC5 mid-flight.** A run outcome `epic-reroute` is journaled.
  The sweep ship-intent bump is not dropped (SPEC-033 seal-intent).

## SHOULD

- SHOULD print the skip reason on an AC13 hit (`journal <stem> outcome=<x> ts=<t> baseline=<tag>`).
- SHOULD keep the `SKILL.md` pointer at or under 20 lines.
- SHOULD leave `fold-sweep.sh` and `fold-sweep-test.sh` byte-identical
  unless an unrelated defect is in-scope.

## MUST NOT

- MUST NOT add `commands/backlog.md` or any new `commands/*.md`.
- MUST NOT pass literal `--ship` to `/orchestrate`.
- MUST NOT invoke `/release` or release-train from sweep.
- MUST NOT hand-write `.claude/backlog.md` or `.claude/backlog/*.md`.
- MUST NOT auto-CLOSE on `grep` symbol-exists.
- MUST NOT interleave Purge pre-pass with `/orchestrate`.
- MUST NOT run parallel `git worktree` operations (SPEC-016).
- MUST NOT restate SPEC-009 / SPEC-013 / SPEC-016 / SPEC-025 / SPEC-033
  contracts; cite them.
- MUST NOT treat `fold-sweep.sh` as the Backlog sweep engine.
- MUST NOT auto-merge under sweep `--autopilot` (Phase 2).

## Test

- Format: `bash skills/spec-tooling/check-format.sh specs/core/SPEC-040-backlog-sweep.md` exits 0.
- Phase 1 suite (plan creates it; discovered as a `*-test.sh`): helpers for
  compile-ship, last-release-tag (`is_release_tag` only), journal intent-then-outcome,
  re-run skip, `--refresh`/`--skip-decided` usage 64, evidence bar (a)/(b) and
  insufficient, triage-size with no spawn, walk-sort, epic-child skip, Linear-down
  one-line, Linear-only ASK, defer.sh lock+status, untrusted metachar/SQL-fragment
  fixtures, summary bucket counts, SKILL.md byte-size under 30720, .gitignore
  .claude/sweeps/, no commands/backlog.md file, fold-sweep.sh unsourced.
- `bash tools/spec-lint.sh` exits 0 on this spec (index row + covers of files
  present at spec commit).

## Validation

- `compile-ship --ship=pr` prints empty autopilot argv; `--ship=master` prints
  `--autopilot=master`; `--ship=patch` prints `--autopilot=patch` (suite).
- `tag-date --root PATH --tag TAG` prints the ISO-8601 date the tag carries:
  annotated tagger date, else tagged-commit committer date (suite).
- `walk-outcome --landed` prints `shipped`; `--halt <condition>` prints
  `pr-stopped`; journal-append rejects a child halt name as `outcome` (suite).
- Last-release-tag ignores a non-release tag that `git describe` would pick
  (suite).
- A fixture item whose Affects paths exist at HEAD is not CLOSE (suite).
- `--refresh --skip-decided` exits 64 with no journal write (suite).
- `SKILL.md` byte count stays under 30720 after the pointer edit (suite).
- Linear-down: an empty Linear JSON yields the local-only open set; the
  fail-open line is printed once; no retry loop (suite).
- A fixture with shell metachars and SQL fragments in title/body/Affects is
  triaged with no extra command execution (suite).
- `bash skills/spec-tooling/check-format.sh specs/core/SPEC-040-backlog-sweep.md`
  exits 0.

## Version History

| Date | Change |
|------|--------|
| 2026-10-23 | Fold old AC17 into AC1 and old AC18 into AC3 (M14(j) claim budget ≤16). |
| 2026-10-23 | Register `tag-date` and `walk-outcome` helper verbs (CDT-582). |
| 2026-10-22 | Initial ACTIVE (CDT-582). Phase 1 Backlog sweep: sidecar protocol, Purge pre-pass, CLOSE/ASK/ORCHESTRATE/DEFER, journal, `--ship` compile. Phase 2 MERGE/EPIC/BC5 spec text only. |

## Acceptance criteria

Format and rules: SPEC-033 M14(g) and M14(h).

### CDT-582

  AC ids renumbered 2026-10-23 (M14(j) budget): old AC17 → merged into AC1; old AC18 → merged into AC3; AC2–AC16 shift unchanged.

- **AC1.** Open set uses `/backlog list` semantics (Linear preferred when MCP is up; local write-through merged by `linear_id`; local-only PENDING rows included); every open item appears exactly once; `--project` filters the Linear query only; Linear-down fail-open prints exactly one `Linear unreachable — local backlog only.` then uses the local-only open set and local-only closes; no retry loop.
  Verify: bash skills/backlog/sweep-test.sh
- **AC2.** Purge pre-pass completes over every open item before the first `/orchestrate` spawn; no interleaving.
  Verify: bash skills/backlog/sweep-test.sh
- **AC3.** Every auto-CLOSE carries Mechanical evidence (two cited passages plus counts plus a date/mtime-vs-tag or spec quote) meeting (a) cited Affects paths absent at HEAD via argv-safe bash, or (b) shipped-after-creation via a CHANGELOG entry or spec dated after the item Added date; insufficient evidence is not a CLOSE; grep symbol-exists is ASK-only; untrusted ticket text is argv or a JSON file path; SQL uses `skills/lib/sqlq.sh`; never `eval`; a fixture with shell metachars and SQL fragments in title/body/Affects is triaged with no extra command execution.
  Verify: bash skills/backlog/sweep-test.sh
- **AC4.** A staleness signal without the evidence bar is ASK; never a silent close on inference.
  Verify: bash skills/backlog/sweep-test.sh
- **AC5.** All proposed purge closes appear as one batch listing `slug | disposition | evidence`; accept-all, or per-item removal; each ASK answered close/run/defer becomes a terminal Disposition.
  Verify: bash skills/backlog/sweep-test.sh
- **AC6.** CLOSE uses `/backlog close` (Linear terminal when MCP up plus `close.sh`; idempotent); sweep does not hand-write backlog index or item files.
  Verify: bash skills/backlog/sweep-test.sh
- **AC7.** Triage size uses title, body, Affects, and Effort frontmatter only, with no spawns; S maps to `--tier=light`, M to standard (flag omitted), L to `--tier=full`; `--council-tier` is forwarded only when the user set it.
  Verify: bash skills/backlog/sweep-test.sh
- **AC8.** Walk is strict serial; size ascending; Linear priority within size (client-side sort); local-only items last within a bucket by Added date ascending.
  Verify: bash skills/backlog/sweep-test.sh
- **AC9.** Sweep flag `--ship=<pr|master|patch|minor|major>` compiles: `pr` to no autopilot flag; `master` to `--autopilot=master`; `patch|minor|major` to `--autopilot=<bump>`; attended default is the per-ticket gate; sweep `--autopilot` default `--ship` is `master`; sweep does not pass literal `--ship` to `/orchestrate`.
  Verify: bash skills/backlog/sweep-test.sh
- **AC10.** Local `epic_parent` frontmatter or a non-empty Linear `parentId` yields SKIP (no triage, no journal record, counted in the summary).
  Verify: bash skills/backlog/sweep-test.sh
- **AC11.** Journal is append-only `$MROOT/.claude/sweeps/<slug>.jsonl` (Linear-only items keyed by issue id) with fields `ts`, `disposition`, `evidence`, `args`, `tag_baseline`, `outcome`; intent record is written before the side effect; a completed record carries `outcome` in `{closed,shipped,pr-stopped,deferred,asked-answered}`; never staged or committed.
  Verify: bash skills/backlog/sweep-test.sh
- **AC12.** Tag baseline is the last release tag at start via `skills/release/check-ship-history.sh` `is_release_tag`; tags created mid-walk do not move the baseline.
  Verify: bash skills/backlog/sweep-test.sh
- **AC13.** A journal record with a terminal `outcome` whose `ts` is at or after the snapshotted tag committer-date is skipped (print why); older records re-judge; intent-without-outcome re-judges; `--refresh` forces re-judge all; `--skip-decided` forces skip; both flags together exit 64 before mutation.
  Verify: bash skills/backlog/sweep-test.sh
- **AC14.** Sweep `--autopilot` asks nothing; CLOSE only at the AC3 bar; every would-be ASK converts to DEFER with missing-evidence reason in the journal; each spawned run emits its own decision-cards; a blocking-condition halt inside a run does not halt the sweep (journal outcome, list in the final summary, continue); `--limit` bounds code-bearing runs only; purge always full.
  Verify: bash skills/backlog/sweep-test.sh
- **AC15.** Terminal summary prints N open plus per-Disposition counts (CLOSE/ASK/ORCHESTRATE/DEFER/SKIP) plus escalations; every item is in exactly one bucket; exit 0 with escalations; non-zero only on machinery failure.
  Verify: bash skills/backlog/sweep-test.sh
- **AC16.** Sweep edits nothing outside `.claude/sweeps/` and tracker flips via close/defer verbs; it does not invoke `/release`; `commands/backlog.md` is absent.
  Verify: bash skills/backlog/sweep-test.sh

### Phase-2

- **AC19.** MERGE: journal names the surviving slug plus Mechanical evidence; attended confirms in the purge batch; autopilot converts ASK to DEFER (never auto-merge unattended); the absorbed item is closed via AC6 verbs.
  Verify: bash skills/backlog/sweep-test.sh
- **AC20.** EPIC disposition: an item that meets SPEC-033 AC4/M10 complexity-overflow or a Workstream split hands off mid-walk to `/epic`; journal records the epic id; the walk continues; children with `epic_parent` are skipped via AC10.
  Verify: bash skills/backlog/sweep-test.sh
- **AC21.** BC5 mid-flight reroute: a run outcome `epic-reroute` is journaled; the sweep ship-intent bump is not dropped (seal-intent rules).
  Verify: bash skills/backlog/sweep-test.sh

## Alternatives considered

- Top-level `/sweep` command — rejected (Grok menu-slot collision with skills).
- `commands/backlog.md` — rejected (skill-only Surface; bump-class would become minor).
- Inline protocol in `SKILL.md` — rejected (`SKILL.md` is 29628/30720; `/audit` size FAIL).
- Bare `git describe` for last tag — rejected (picks non-release tags; `is_release_tag` is the helper).
- Pass `--ship` through to `/orchestrate` — rejected (`--ship` is not an orchestrate flag).
- Auto-CLOSE on `grep` symbol-exists — rejected (ASK-only).
- `/debug` as the nit floor — rejected (`/debug` is defect-only; `--tier=light` is the floor).
- Reuse `fold-sweep.sh` — rejected (post-ship close-out, different job).
- Age-based journal invalidation — rejected (last release tag is the boundary).
- Parallel walk — rejected (SPEC-016 serial worktrees).

## Open questions

None. Eight DRI answers resolved OQ1–OQ8 before spec authoring.

## Cross-references

- SPEC-002 D1 — one operational copy (sidecar `sweep.md`, not `SKILL.md`)
- SPEC-009 — list/close/reconcile, backlog root, terminal-status, write lock
- SPEC-013 — `--council-tier` (forwarded only when user-set)
- SPEC-016 — serial `git worktree` operations
- SPEC-025 — epic `parentId` inventory; `epic_parent` frontmatter
- SPEC-033 — autopilot, decision-cards, blocking-condition, complexity-overflow, nest-host, seal-intent
- SPEC-035 — skill-size WARN 30720
- SPEC-010 — bump-class: no new `commands/*.md` keeps patch legal
