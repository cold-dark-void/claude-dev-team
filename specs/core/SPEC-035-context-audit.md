# SPEC-035: Context Audit Surface (`/audit`)

**Status**: ACTIVE
**Category**: core
**Created**: 2026-08-16

## Overview

`/audit` is a user-invocable Surface that inventories the **instruction stack**
hosts inject (user-global `~/.claude/CLAUDE.md`, walk-up `AGENTS.md`/`CLAUDE.md`,
per-agent directives) and WARNs when plugin `SKILL.md` files exceed the size
gate. Bare `/audit` is read-only. Writes use **approve-then-apply** on
instruction-stack files only, and only when the finding carries **mechanical
evidence**. `/doctor` remains install/config health; this spec owns stack
hygiene. Skill splits and handoff packet fields are separate workstreams
(PRs / other tickets) — `/audit apply` MUST NOT rewrite them.

## MUST

- **M1 — Surface.** The user-facing command MUST be `/audit` with
  `commands/audit.md` + `skills/audit/` (YAML `name` + `description` required).
- **M2 — Read-only default.** Bare `/audit` (and `inventory`) MUST perform zero
  writes under the project or `~/.claude`. Scratch files MAY use `$TMPDIR`.
- **M3 — Inventory.** A default run MUST list instruction-stack layers
  (user-global + parents → current project + directives) and plugin `SKILL.md`
  sizes. Scope MUST NOT include a `--all` repos walk (that flag MUST exit 64).
- **M4 — Dual-host.** Discovery MUST match host walk-up for Claude Code and
  Grok (`AGENTS.md` / `CLAUDE.md` from cwd toward `/`). Grok MUST also include
  `~/.claude/CLAUDE.md` (shared user-global file) **and** Grok-only user-global
  `~/.grok/AGENTS.md` and `~/.grok/CLAUDE.md` when those files exist. Inventory
  MUST resolve the shared-repo root (MROOT / directives) via `git -C <cwd>`
  (or `--path-format=absolute --git-common-dir`); the invoker process cwd MUST
  NOT leak into MROOT.
- **M5 — Findings shape.** Each finding MUST carry evidence, impact, action,
  confidence, layer, and `class` ∈ {`instruction-stack`, `plugin-surface`,
  `handoff`, `judgment`}.
- **M6 — Mechanical evidence.** Apply MUST reject a finding unless evidence
  includes two cited passages (`path` + `quote`), counts (`bytes` and/or
  `lines`), and a date/mtime-vs-tag or spec quote. Judgment-class findings
  MUST NOT enter an apply batch unless `--judgment` (or an explicit id list
  with that flag).
- **M7 — Apply path allowlist.** `/audit apply <id|batch>` MUST write only
  instruction-stack files (`CLAUDE.md`, `AGENTS.md`, `directives.md`). It MUST
  refuse paths under `skills/**` or `commands/**`. Path checks MUST use
  `realpath` (not `abspath` alone) so a symlink whose target is under
  `skills/**` or `commands/**`, or whose basename is not an instruction-stack
  file, is refused. Extra confirm (`--yes` or TTY) is required before any
  write under `~/.claude` **or** `~/.grok`.
- **M8 — Skill-size gate.** Inventory MUST WARN when a scanned `SKILL.md`
  exceeds 30KB (30720 bytes) and list top skills by size. `skills/audit/SKILL.md`
  MUST ship under the 40KB (40960 bytes) must-split cap.
- **M9 — `--from-session`.** If shipped, `--from-session <id>` MUST call
  `skills/transcript-parse` locate only (`hosts.py`) and MUST NOT add a second
  transcript parse engine. Locate/parse diagnostics MUST go to stderr.
  Combined with `--json`, stdout MUST be a single JSON document (no `host=`
  locate line on stdout).
- **M10 — Compose, do not absorb.** `/doctor` MUST remain install diagnostics.
  `/audit` docs and `/doctor` MUST carry a one-line pointer at each other.
  `/audit apply` MUST NOT rewrite plugin-surface or handoff artifacts.

## Test

- [ ] Inventory on a fixture with user-global, parent, project, and directives
      files lists each layer (M3, M4)
- [ ] Apply rejects a finding with empty or passages-only evidence (M6)
- [ ] Apply refuses `skills/**` and `commands/**` targets (M7)
- [ ] Command/skill/docs/cli text does not ship a stack-rebuild alias (M1)
- [ ] `skills/audit/SKILL.md` is under 40960 bytes and documents the 30KB WARN
      threshold (M8)
- [ ] `--from-session` invokes `skills/transcript-parse/hosts.py` locate (M9)
- [ ] `--from-session --json` stdout is parseable JSON only; locate is on stderr (M9)
- [ ] Inventory includes `~/.grok/AGENTS.md` when present (M4)
- [ ] Directives MROOT comes from `--cwd`, not the invoker process cwd (M4)
- [ ] Apply refuses a symlink whose `realpath` is under `skills/**` (M7)
- [ ] Bare inventory leaves fixture hashes unchanged (M2)
- [ ] `--all` exits 64 (M3)

## Validation

- [x] Spec reviewed against CDT-200 ACs
- [x] `bash skills/audit/test.sh` green
- [x] docs-drift + skill-lint clean on new files
- [x] Status promoted to ACTIVE after land

## Version History

| Date | Change |
|------|--------|
| 2026-08-16 | Initial DRAFT — CDT-200 /audit v1 (CDT-196-C4) |
| 2026-08-16 | Promoted ACTIVE on v1.8.0 land |
| 2026-08-16 | CDT-201: M4 `~/.grok` user-global + MROOT from `--cwd`; M7 `realpath` + `--yes` for `~/.grok`; M9 `--json` stdout JSON-only |

**Covers**: `commands/audit.md`, `skills/audit/SKILL.md`, `skills/audit/audit.sh`,
`skills/audit/apply.py`, `skills/audit/from-session.sh`, `skills/audit/test.sh`,
`docs/commands/audit.md`

## SHOULD

- SHOULD emit `--json` with `audit_schema: "1"` for agent apply payloads
- SHOULD keep `skills/audit/SKILL.md` well under the 30KB WARN (thin router)

## Cross-references

- **SPEC-022** — `/doctor` install health (not stack hygiene)
- **SPEC-012 / SPEC-018** — `skills/transcript-parse` locate seam
- **SPEC-021** — skill-bash lint on command/skill fences
- **SPEC-001** — per-agent directives files
