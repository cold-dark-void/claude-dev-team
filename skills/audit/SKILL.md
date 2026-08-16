---
name: audit
description: >
  Context audit of the instruction stack (CLAUDE.md, AGENTS.md, directives)
  plus skill-size WARN. Bare is read-only. Apply is approve-then-apply on
  instruction-stack files only (SPEC-035).
---

# audit

Read-only inventory of the instruction stack and skill-size WARNs.
Approve-then-apply is opt-in and gated on mechanical evidence.

Governing spec: `specs/core/SPEC-035-context-audit.md`.

Size gate (dogfood): WARN 30KB (30720 bytes); must-split 40KB (40960 bytes).
This SKILL.md MUST stay under the cap — put mechanics in `*.sh` / `apply.py`.

## CLI

```
bash skills/audit/audit.sh [inventory] [--json]
bash skills/audit/audit.sh apply <id|batch> --from-json FILE [--judgment] [--yes]
bash skills/audit/audit.sh --from-session <id>
```

`--from-session` calls `skills/transcript-parse/hosts.py` locate only.

## Hard walls

- Bare inventory: zero writes (scratch under `$TMPDIR` only)
- Apply: `CLAUDE.md` / `AGENTS.md` / `directives.md` only
- MUST NOT rewrite `skills/**` or `commands/**` (those are PRs)
- Extra confirm (`--yes` or TTY) before any write under `~/.claude` or `~/.grok`
- class `judgment` requires `--judgment`; `plugin-surface` / `handoff` never apply
- Mechanical evidence: two cited passages + counts + (mtime/tag or spec quote)
- Dual-host: Claude + Grok walk-up; Grok also `~/.grok/AGENTS.md` + `~/.claude/CLAUDE.md`
- `--from-session --json`: locate line on stderr; stdout is one JSON document
- Scope: user-global + current project (parents → project). No `--all` repos
- `/doctor` stays install health — pointer only

## Agent steps

1. Resolve `skills/audit/audit.sh` via `plugin-dir.sh`; run with user args.
2. Present inventory (layers, top skills, findings). Do not write.
3. On apply: build finding JSON (evidence, impact, action, confidence, layer, class), then `audit.sh apply`.
4. Never invent apply actions for plugin-surface or handoff (open a PR).
