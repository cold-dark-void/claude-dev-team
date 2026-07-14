---
name: docs-drift
description: |
    Deterministic, LLM-free structural docs-consistency checker (SPEC-010 D1–D8).
    Checks: cmd-index (README ## Commands ↔ commands/*.md), agent-roster
    (AGENTS.md + README ↔ agents/*.md), docs-hub (docs/commands links/orphans),
    manifest-desc (plugin.json description == marketplace plugins[].description).
    Wired by /release as Step 4.9 after T3. Run manually via:
    bash skills/docs-drift/check-docs-drift.sh [--root DIR]
---

# docs-drift

Structural documentation drift gate — sibling of SPEC-021 skill-bash lint
(content of fenced bash) and SPEC-008 check-format (spec structure). This gate
owns index tables, roster tables, page links, and manifest description fields.

Governing spec: `specs/core/SPEC-010-code-review-release.md` (D1–D8).

## Usage

    bash skills/docs-drift/check-docs-drift.sh              # scan git toplevel
    bash skills/docs-drift/check-docs-drift.sh --root DIR   # override root

Exit codes: `0` clean (unwaived=0), `1` unwaived findings, `64` usage error.

Stdout format (one line per unwaived finding):

    <file>: [<check-id>] <message>

Trailing summary always printed:

    N findings, M waived

## Checks

| ID | Rule |
|----|------|
| `cmd-index` | Bidirectional: every `commands/*.md` appears in README `## Commands` table rows `\| \`/name\``; every index `/name` resolves to `commands/<name>.md` **or** `skills/<name>/SKILL.md` (skills-backed ok). Internal skills not required in the index. |
| `agent-roster` | AGENTS.md roster table ↔ `agents/*.md` (count+names both ways); every README Agents table row names a real agent; every `agents/*.md` basename appears as `` `<name>` `` in the README Agents section. |
| `docs-hub` | Every `docs/commands/*.md` link in README / `docs/README.md` resolves; every `docs/commands/*.md` file is linked from `docs/README.md` (no orphans). Index-only commands without a docs page are fine. |
| `manifest-desc` | `.claude-plugin/plugin.json` `description` byte-identical to each `marketplace.json` `plugins[].description`. Version sync is NOT this check (SPEC-002). |

## Waivers

Add `<!-- drift-ok: <check-id> -->` on the offending line or the line immediately
adjacent (above/below). Waived findings are counted in the summary — never silent.

`manifest-desc` is **unwaivable** (JSON cannot carry comments) — fix the string.

## Bite-tests

    bash skills/docs-drift/test.sh

Live inject + `cp` restore only (never `git checkout`). Asserts each check-id
produces exit 1 when drifted, and restores leave git status clean of injects.
