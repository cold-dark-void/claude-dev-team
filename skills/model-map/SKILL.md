---
name: model-map
description: |
    Per-agent Model map: resolve a host model string from local, repo,
    and global JSON layers. Empty stdout is the Tier default. Local
    writer is write-model.sh; user Surface is /setup models.
    Agent-internal — not a user slash command.
---

# Model map

Map behavioral agents to host model strings. Empty resolver stdout means
**Tier default** (shipped `agents/*.md` frontmatter). Tiers stay the SoT
for role capability intent (SPEC-003).

## Paths

Three layers. First hit wins per agent.

| Layer | Path | Git |
|-------|------|-----|
| local | `$MROOT/.claude/dev-team/models.local.json` | gitignored |
| repo | `$MROOT/.claude/dev-team/models.json` | committable; not shipped |
| global | `~/.claude/dev-team/models.json` | user home |

`$MROOT` is `git rev-parse --git-common-dir` then `dirname` (same rule as
`worktree-lib.sh`). Read only those files. Do not read a worktree copy, a
plugin-cache copy, or `DEVTEAM_MODEL_*`. Absent file: skip. Do not warn.

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

All layers absent and empty `agents` objects both yield empty stdout and no
warning.

A listed key with a bad value (null / non-string / empty) warns and falls
through to the next layer.

## Warn, never block (`qa` / `council-judge`)

A valid string for `qa` or `council-judge` is emitted. The resolver also
warns once:

`model-map: override for adversarial role '<name>' is allowed and may weaken the gate`

Do not block, drop, or substitute the **Tier default**.

## Spawn-surface coverage

Named-roster Agent spawns honor the Model map (SPEC-037 M13 ∪ M16):

- `/orchestrate` steps 4 / 6 / 8 / 9 / 10, plus code-simplify (`ic4`) and
  ci-watch fixer (`ic5`)
- `/kickoff` — Step 2 `@pm` / `@tech-lead`, Step 3 feed-back `@pm`,
  Step 5 / 6 `@tech-lead`
- `/epic` — A.2 `@pm` / `@tech-lead` only (Mode E reuses A.2)
- `/debug ticket` — premise `ic5`, implement `--agent ic4|ic5`, refuters `qa`
- `/council` — Phase 2 `ic5`, Phase 2.5 `ic4`, Phase 5 `council-judge`
- `/bug-hunt` — S1 unconstrained / lens / quorum `ic5` and S2 investigators
  `ic5`

Resolve the agent actually spawned. Named fallback `ic5`→`ic4` resolves
`ic4`. Empty stdout = **Tier default**.

**Omit the fence:** Codebase Explorer; kickoff Step 4b verifier; unnamed /
`general-purpose` / Explore; council Phase 1 extractor, Phase 3 specialist,
Phase 4 prosecutor/advocate, `--blind` extra waves; `/handoff` miner
(`HANDOFF_MINER_MODEL`); `/memory validate`; `/retro`. Direct `@agent` /
chat stays on frontmatter.

## Local writer

`write-model.sh` is a subprocess CLI (never `source`). It writes **only**
`$MROOT/.claude/dev-team/models.local.json`. It does not write repo
`models.json` or `~/.claude/dev-team/models.json`.

```
write-model.sh list
write-model.sh set <agent> <string>
write-model.sh unset <agent>
```

- `list` — print the 8 mappable agents with the winning resolved string
  (calls `resolve-model.sh`; empty → `Tier default`) plus the local path.
  Read-only.
- `set` — merge `{version:1, agents:{...}}`. Create parent dirs. Trim.
  Empty after trim or unknown agent → exit 64. `qa` / `council-judge`
  allowed + M9 warn on stderr. Unparseable existing local → refuse, exit 1.
- `unset` — delete that key. Missing key is OK. Unknown agent → 64.
  Unparseable existing → refuse, exit 1.

Call via `plugin-dir.sh file`. `jq` is required for set/unset.

## `/setup models`

Not doctor-gated. Bare `/setup models` → `write-model.sh list`. `set` /
`unset` pass through. Unknown `/setup` sub still prints usage and does not
mutate; `models` is a known sub.

`/adjust-agent <agent> --model <string>` → `write-model.sh set`.
`/adjust-agent <agent> --model-unset` → `write-model.sh unset`. Parse those
flags before a directives prompt. `council-judge` is mappable.

## `/doctor` `models.map`

Group `config`. No map files at any of the three layer paths → SKIP. Valid
present files → PASS. Unparseable / bad agents / unknown key / `jq` missing
→ WARN (never FAIL). `qa` / `council-judge` override → WARN (M9). `--fix`
does not rewrite the map.

## Related

- SPEC-037 — Per-agent Model map
- SPEC-003 — Tier default roster
- SPEC-005 — `/setup models` dispatch
- SPEC-022 — `models.map` doctor check
