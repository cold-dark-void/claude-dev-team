# /audit

Context audit of the **instruction stack** (SPEC-035). Bare `/audit` is
**read-only**: it inventories the layers hosts inject and WARNs when a
`SKILL.md` exceeds 30KB. Writes happen only via **approve-then-apply**.

`/doctor` stays install/config health. Use `/audit` for stack hygiene.

## Usage

```
/audit
/audit --json
/audit apply <id|batch> --from-json FILE [--judgment] [--yes]
/audit --from-session <id>
```

| Args | Action |
|------|--------|
| _(none)_ | Inventory + skill-size WARN. Zero writes. |
| `--json` | Machine-readable document |
| `apply <id\|batch>` | Apply approved findings to instruction-stack files only |
| `--judgment` | Opt-in: allow class=`judgment` |
| `--yes` | Required confirm before a write under `~/.claude` or `~/.grok`. There is no TTY prompt. |
| `--from-session <id>` | Locate via `skills/transcript-parse` only, then inventory |
| `-h`, `--help` | Usage |

Produce the apply FILE from a machine-readable inventory, review it, then apply:

```bash
/audit --json > .claude/audit-findings.json
/audit apply <id|batch> --from-json .claude/audit-findings.json --yes
```

## Scope

User-global (`~/.claude/CLAUDE.md`, plus Grok `~/.grok/AGENTS.md` /
`CLAUDE.md`) + current project (parents → project `AGENTS.md` / `CLAUDE.md`
+ directives). Dual-host: Claude Code and Grok share the same walk-up; Grok
also reads `~/.claude/CLAUDE.md`. There is no flag that scans every repo on
disk. `--from-session --json` keeps locate diagnostics on stderr so stdout
is one JSON document.

## Findings

Each finding carries: evidence, impact, action, confidence, layer, and
`class` ∈ {`instruction-stack`, `plugin-surface`, `handoff`, `judgment`}.

Apply requires **mechanical evidence**: two cited passages, counts, and a
date/mtime-vs-tag or spec quote. Vibes-only findings are rejected.
`plugin-surface` and `handoff` are report-only (fix via PR). Apply MUST NOT
rewrite `skills/**` or `commands/**`.

Skill-size: WARN at 30KB (30720 bytes); this Surface's own `SKILL.md` must
stay under the 40KB must-split cap.

## See also

- [`/doctor`](../README.md) — install/config diagnostics
- Protocol: `skills/audit/SKILL.md`
- Spec: `specs/core/SPEC-035-context-audit.md`
