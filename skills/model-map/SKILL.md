---
name: model-map
description: |
    Per-agent Model map: resolve a host model string from
    $MROOT/.claude/dev-team/models.local.json. Empty stdout is the Tier
    default. Agent-internal — not a user slash command.
---

# Model map

Phase 1 local layer. Map behavioral agents to host model strings.
Empty resolver stdout means **Tier default** (shipped `agents/*.md`
frontmatter). Tiers stay the SoT for role capability intent (SPEC-003).

## Path

File: `$MROOT/.claude/dev-team/models.local.json`

`$MROOT` is `git rev-parse --git-common-dir` then `dirname` (same rule as
`worktree-lib.sh`). Read only that file. Do not read a worktree copy, a
plugin-cache copy, or any other path.

## Schema

JSON of the form `{ "version": 1, "agents": { "<name>": "<model-string>" } }`.

- Partial `agents` is fine.
- Missing or unknown `version` is treated as `1`.
- Extra top-level keys are ignored.

## Example

```json
{
  "version": 1,
  "agents": {
    "ic4": "grok-code-fast-1",
    "qa": "grok-4"
  }
}
```

## Empty stdout = Tier default

Call `resolve-model.sh <agent>` as a subprocess via `plugin-dir.sh file`
(never `source`).

- Non-empty stdout → pass the trimmed string as the Agent `model` param.
- Empty stdout → omit `model` (do not pass `""`). Use the **Tier default**.
- Warnings go to stderr. Surface them. Do not abort spawn.

Absent file and empty `agents` object both yield empty stdout and no
warning.

## Warn, never block (`qa` / `council-judge`)

A valid string for `qa` or `council-judge` is emitted. The resolver also
warns:

`model-map: override for adversarial role '<name>' is allowed and may weaken the gate`

Do not block, drop, or substitute the **Tier default**.

## Phase 1 coverage

Phase 1 wires the Model map only at `/orchestrate` named-roster Agent spawn
sites (SPEC-037 M13). `/kickoff`, `/epic`, `/debug`, and `/council` do not
read the Model map this version. Direct `@agent` / chat stays on frontmatter.

Repo and global layers are out of scope.

## Related

- SPEC-037 — per-agent Model map (phase 1)
- SPEC-003 — Tier default roster
