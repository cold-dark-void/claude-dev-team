# SPEC-020: Loop-Prompt Architect (/craft-loop)

**Status**: ACTIVE
**Category**: core
**Created**: 2026-07-03

**Covers**: `commands/craft-loop.md`, `skills/craft-loop/SKILL.md`, `skills/craft-loop/program-template.md`, `skills/craft-loop/examples/`

---

## Overview

`/craft-loop` designs high-quality prompts ("loop programs") for Claude Code's built-in
`/loop` and `/goal` commands — it ships no runtime of its own. A naive prompt fired
repeatedly into a session drifts, loses its place between firings, never terminates, or
takes unattended risks. This spec defines a command that turns a rough user goal into a
reviewed, file-persisted program with a per-iteration procedure, journal-based state, an
objectively checkable stop condition, guardrails, and blocked-decision escalation.
Programs live in a per-project library (`.claude/loops/`) so they can be steered mid-run
(each firing re-reads the file), refined between runs from journal evidence, and reused
via a one-line pointer prompt. Domain-adjacent to SPEC-017 (autonomous CI watch), which
owns its own CronCreate-based runtime for CI monitoring; this spec deliberately owns no
scheduling — the built-ins are the only runtime (WARNING-level scope overlap acknowledged
at creation; no contradictory requirements).

## MUST

### Command surface

- MUST ship `commands/craft-loop.md` with YAML frontmatter (`name`, `description`),
  routing four modes: **craft** (default — bare invocation or goal text), **list**
  (optional `--all`), **refine `<name>`**, and **retire `<name>`**
- MUST ship `skills/craft-loop/SKILL.md`, `skills/craft-loop/program-template.md`, and at
  least 2 example programs under `skills/craft-loop/examples/`
- MUST NOT start a loop itself in any mode — the command's terminal output is the saved
  program plus the invocation line; the user fires `/loop` or `/goal`

### Craft mode

- MUST scan the project for context relevant to the goal (affected files, available
  commands, test setup) before drafting
- MUST run a guided dialogue — one question per message — covering at minimum: stop
  condition, scope boundaries, risk tolerance, **target + cadence + unit grain as a
  single combined slot** (presets L / G / G-fat or custom), and program name
- SHOULD prefer **descriptive long kebab-case** name options for non-trivial goals
  (short aliases optional)
- MUST draft from `program-template.md`, seeded from the closest shipped example when one
  fits
- MUST validate the draft with `skills/craft-loop/check-program.sh` (write the
  draft to a temp file via `mktemp`) before presenting and fix every reported
  violation first (rv-w3-28). The unit-grain checklist item stays human
  judgment and is outside the validator's scope.
- MUST verify the draft against the quality checklist (below) and present it in chat for
  approval before writing any file
- On approval, MUST write the program to `$MROOT/.claude/loops/<name>.md`
  (the shared main checkout; creating the directory if absent) and print the exact invocation line for the chosen target, e.g.
  `/loop Follow the loop program in .claude/loops/<name>.md exactly — one iteration per firing.`
- On user **hold / dogfood / do not save / no-write**, MUST NOT write under
  `.claude/loops/`; MAY leave the draft in chat and print a would-be invocation line
- On name collision, MUST offer: overwrite, rename, or switch to refine mode
- SHOULD answer mid-dialogue product/repo questions briefly, then resume the open craft
  slot without restarting the full question set

### Quality checklist (applied to every draft, including the shipped examples)

- Cold-start executable: the procedure references no state outside the program file, its
  journal, and any **side artifacts it explicitly declares** under `.claude/loops/`
  (e.g. `<name>.findings.md`)
- Stop condition is objectively checkable (a fact of the repo/files, not a judgment call)
- Journal read is the first procedure step; journal append is the last
- Guardrails cover every destructive operation reachable from the procedure
- Blocked-behavior is specified
- One unit of work is small enough for a single firing (`target: loop`) or single
  meaningful event (`target: goal`)

### Program format

- Every generated program MUST contain YAML frontmatter (`name`, `target: loop|goal`,
  `cadence` (`dynamic` or a fixed-interval suggestion, e.g. `20m`),
  `status: ready|retired`, `created`) and the sections: `# Objective`,
  `# Every iteration`, `# Stop when`, `# Never`, `# When blocked`,
  `# Journal entry schema`
- The default `# Never` list MUST include: `git push`, branch/tag deletion, history
  rewrites, and file deletion outside the program's declared scope; entries are removable
  only by explicit user instruction during the dialogue
- `# When blocked` MUST instruct: append a decision card under `Decisions needed` in the
  journal, continue with unblocked work, and end the loop reporting BLOCKED when no
  unblocked work remains
- For `target: goal` programs, journaling is per meaningful event rather than per firing
- Stop announcements MAY use `loop complete: <name>` and/or `goal complete: <name>`
  (prefer `goal complete` when `target: goal`)

### Journal

- Programs MUST journal to `.claude/loops/<name>.journal.md` using the entry schema
  `## Iteration <N> — <date>` with `Did` / `State` / `Next` / `Decisions needed` fields
- A decision card is answered by writing an **indented** `Answer:` line beneath it (by
  the user directly, or by a session relaying the user's decision); each firing's
  journal-read step MUST treat cards with an indented `Answer:` line as resolved input,
  and cards without one as still open
- When a journal exceeds 200 lines, the next firing MUST compact it: merge every
  `## Iteration` entry older than the last five into a `## Summary` section at the
  top (one bullet per entry: `Did` + `Next`), preserving all decision cards and
  their indented `Answer:` lines verbatim; an open decision card MUST NOT be
  deleted (rv-w3-28). `skills/craft-loop/journal-stats.sh` reports size,
  iterations, and open decisions.

### Retire mode (rv-w3-28)

- `retire <name>` MUST flip the program's frontmatter to `status: retired` only
  after an explicit user yes; nothing else in the program or journal changes
- Retiring an already-retired program MUST change nothing and say so
- `list` MUST hide `status: retired` programs unless `--all` is passed; with
  `--all`, retired rows appear with their Status column value

### Refine mode

- MUST read the program AND its journal; when no journal exists, MUST ask the user what
  happened instead of failing
- MUST diagnose against the failure taxonomy: drift, stall, guessing (decided instead of
  escalating), immortal loop (stop condition vague or unreachable), oversized ticks
- MUST present before/after edits and apply them only on approval, appending a dated
  entry to a `## Revisions` section in the program
- On unknown name, MUST list near matches from the library

### List mode

- MUST render a table over program files under `.claude/loops/`: name, target, status,
  last journal activity, and open decision-card count (cards under `Decisions needed`
  with no indented `Answer:`)
- MUST NOT treat `*.journal.md`, `*.findings.md`, or `*.ledger.md` as programs; SHOULD
  require program frontmatter `name:` and a `# Objective` heading
- MUST enumerate via `find` (not shell globs), and every bash block MUST be
  self-contained (define-before-use within the block) with no history-expansion-hostile
  literals (bang characters, HTML-comment openers) in bash blocks

## Test

- [ ] Craft a trivial 2-iteration program and run its printed `/loop` invocation: the
      journal receives 2 schema-conformant entries and the loop ends via the stop
      condition
- [ ] Force a user-decision blocker mid-loop: a decision card appears under
      `Decisions needed` and the loop continues (or ends BLOCKED) without guessing
- [ ] Craft with an already-used program name: command offers overwrite/rename/refine
- [ ] `refine` on a journaled run: produces a taxonomy-based diagnosis, applies an
      approved edit, and appends a `## Revisions` entry
- [ ] `refine` on a program with no journal: asks the user for an account instead of
      failing
- [ ] `list` shows the crafted program with the correct open-decision count
- [ ] Both shipped examples pass all 6 quality-checklist items
- [ ] `commands/craft-loop.md` and `skills/craft-loop/SKILL.md` carry valid YAML
      frontmatter
- [ ] `retire <name>` on an approved program flips `status:` to `retired`; a
      second retire is a no-op; `list` hides it and `list --all` shows it
- [ ] A journal over 200 lines is compacted on the next firing with all open
      decision cards preserved
- SPEC-020/T1 — list mode excludes journal, findings, and ledger companions, and both doors name themselves `craft-loop`. Verify: bash skills/craft-loop/test-list-exclude.sh
- SPEC-020/T2 (rv-w3-28) — check-program.sh accepts all shipped examples and rejects a broken fixture; journal-stats.sh reports iterations and open decisions. Verify: bash skills/craft-loop/test.sh

## Validation

- [x] Spec reviewed and promoted to ACTIVE

## Version History

| Date | Change |
|------|--------|
| 2026-10-03 | WP 8-B (rv-w3-28/rv-w3-29): added `retire` mode + list `--all` hiding, `check-program.sh` mechanical validation in craft mode, 200-line journal compaction rule, `journal-stats.sh`, spec-sync side ledger, library root single-homed on `$MROOT/.claude/loops`; new `target: goal` example; backlog-burn closes items via the backlog programmatic write-back (SPEC-009 dual-write) instead of hand-editing `.claude/backlog.md`. |
| 2026-10-01 | WP 2-03: SPEC-020/T1 names the list-mode companion exclusion. Verify: `skills/craft-loop/test-list-exclude.sh`. |
| 2026-07-14 | Implemented via CDV-183: status DRAFT→ACTIVE; `/craft-loop` craft/refine/list shipped. |
| 2026-07-14 | Dogfood patch: hold/no-write; target+cadence+grain slot; descriptive names; declared side artifacts; goal complete phrasing; list excludes companions; mid-dialogue product Q resume. |
| 2026-07-03 | Initial version — brainstormed design: architect dialogue + program library + journal convention + refine/list modes; no new runtime (built-in /loop and /goal only) |
