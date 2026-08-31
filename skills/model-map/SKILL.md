---
name: model-map
description: |
    Per-agent Model map: resolve a host model string or effort token
    from local, repo, and global JSON layers. Empty model stdout is
    the Tier default. Empty effort stdout is inherited effort. Local
    writer is write-model.sh; user Surface is /setup models.
    Agent-internal — not a user slash command.
---

# Model map

Map behavioral agents to host model strings and optional effort tokens.
Empty resolver stdout for a model means **Tier default** (shipped
`agents/*.md` frontmatter). Empty `--effort` stdout means **inherited
effort** (omit the Agent `effort` param). Tiers stay the SoT for role
capability intent (SPEC-003).

## Paths

Three layers. Per-field first hit wins (local > repo > global > omit).
Model and effort resolve independently.

| Layer | Path | Git |
|-------|------|-----|
| local | `$MROOT/.claude/dev-team/models.local.json` | gitignored |
| repo | `$MROOT/.claude/dev-team/models.json` | committable; not shipped |
| global | `~/.claude/dev-team/models.json` | user home |

`$MROOT` is `git rev-parse --git-common-dir` then `dirname` (same rule as
`worktree-lib.sh`). Read only those files. Do not read a worktree copy, a
plugin-cache copy, or `DEVTEAM_MODEL_*`. Absent file: skip. Do not warn.

## Schema

JSON of the form
`{ "version": 1, "agents": { "<name>": "<model-string>" }, "effort": { "<name>": "<token>" } }`.

- Partial `agents` and partial `effort` are fine.
- Missing or unknown `version` is treated as `1`.
- Extra top-level keys are ignored.
- `agents` values stay non-empty strings. Do not put effort inside `agents`.
- `effort` is a sibling object. Do not bump `version` for effort.

## Example

```json
{
  "version": 1,
  "agents": {
    "ic4": "grok-code-fast-1",
    "qa": "grok-4"
  },
  "effort": {
    "ic4": "high",
    "qa": "max"
  }
}
```

## Effort tokens

Closed allowlist after trim and lowercase: `low`, `medium`, `high`,
`xhigh`, `max`. No aliases. The resolver prints the lowercase token.

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

## Empty stdout = inherited effort

Call `resolve-model.sh --effort <agent>` as a subprocess via
`plugin-dir.sh file` (never `source`). Flag-first: `--effort` is argv[1].

- Non-empty stdout → pass the token as the Agent `effort` param.
- Empty stdout → omit `effort` (do not pass `""`). This is **inherited effort**.
- Warnings go to stderr. Surface them. Do not abort spawn.

All layers absent and empty `effort` objects both yield empty stdout and no
warning.

A listed `effort` key with a bad value (null / non-string / empty / not in
the allowlist) warns and falls through to the next layer. `effort` present
but not an object: skip effort on that layer; still resolve `agents`.

Per-field first-hit: local > repo > global > omit (**inherited effort**).
Independent of the model winner.

Light Step 8 `@ic4` omit-path still passes `effort: low`. A non-empty map
token wins over that default.

If spawn fails because of the `effort` param, retry once omitting effort
and warn
`model-map: host rejected effort '<token>' for <agent>; retrying with inherited effort`.
Light `@ic4` retry uses `effort: low`. Do not combinatorial-retry with model.

## Warn, never block (`qa` / `council-judge`)

A valid model string or effort token for `qa` or `council-judge` is
emitted. The resolver also warns once:

`model-map: override for adversarial role '<name>' is allowed and may weaken the gate`

Do not block, drop, or substitute the **Tier default** (model) or
**inherited effort** (effort). Empty effort stdout for those roles does
not emit this warning.

## Spawn-surface coverage

Named-roster Agent spawns honor the Model map (SPEC-037 M13 ∪ M16). Each
site also runs `resolve-model.sh --effort` for the same agent:

- `/orchestrate` steps 4 / 6 / 8 / 9 / 10, plus code-simplify (`ic4`) and
  ci-watch fixer (`ic5`)
- `/kickoff` — Step 2 `@pm` / `@tech-lead`, Step 3 feed-back `@pm`,
  Step 5 / 6 `@tech-lead`
- `/epic` — A.2 `@pm` / `@tech-lead` only (Mode E reuses A.2)
- `/debug ticket` — premise `debugger`, implement `--agent ic4|ic5`, refuters `qa`
- `/council` — Phase 2 `finder`, Phase 2.5 `finder`, Phase 5 `council-judge`
- `/bug-hunt` — S1 unconstrained / lens / quorum `finder` and S2 investigators
  `finder`

Resolve the agent actually spawned. Named fallback `ic5`→`ic4` resolves
`ic4` (pre-CDT-230 sites still on `ic5`, e.g. `/orchestrate`, `/kickoff`).
`finder`/`debugger` spawns fall back to `ic5` on host-reject (CDT-230),
never `ic4`. Empty model stdout = **Tier default**. Empty effort stdout =
**inherited effort**.

**Omit the fence:** Codebase Explorer; kickoff Step 4b verifier; unnamed /
`general-purpose` / Explore; council Phase 1 extractor, Phase 3 specialist,
Phase 4 prosecutor/advocate, `--blind` extra waves; `/handoff` miner
(`HANDOFF_MINER_MODEL`); `/memory validate`; `/retro`;
`skills/council/workflow.js`. Direct `@agent` / chat stays on frontmatter.
"Omit the fence" means these stay outside the named-roster model-map — it
does not mean unpinned. `/handoff`'s chunk-summarizer/annotation spawns,
`/retro`'s friction-analysis spawn, and `/memory validate`'s claim-extractor
/ investigator / pair-judge spawns hardcode `model: haiku` directly in their
own command/skill file (bounded rubric work, command-enforced output
validation catches malformed results). The miner spawn is the one
intentional session-tier-inherit case among these.

## Local writer

`write-model.sh` is a subprocess CLI (never `source`). It writes **only**
`$MROOT/.claude/dev-team/models.local.json`. It does not write repo
`models.json` or `~/.claude/dev-team/models.json`.

```
write-model.sh list
write-model.sh set <agent> <string>
write-model.sh unset <agent>
write-model.sh set-effort <agent> <token>
write-model.sh unset-effort <agent>
```

- `list` — print the 10 mappable agents with the winning resolved model
  (calls `resolve-model.sh`; empty → `Tier default`) and the winning
  resolved effort (calls `resolve-model.sh --effort`; empty → `inherited`)
  plus the local path. Read-only.
- `set` — merge `{version:1, agents:{...}}`. Create parent dirs. Trim.
  Empty after trim or unknown agent → exit 64. `qa` / `council-judge`
  allowed + M9 warn on stderr. Unparseable existing local → refuse, exit 1.
  Does not drop `effort` or extra top-level keys.
- `unset` — delete that agents key. Missing key is OK. Unknown agent → 64.
  Unparseable existing → refuse, exit 1. Does not drop `effort`.
- `set-effort` — trim+lowercase, then allowlist `low|medium|high|xhigh|max`.
  Store the lowercase token. Empty / invalid token or unknown agent →
  exit 64. `qa` / `council-judge` allowed + M9 warn. Does not drop `agents`.
- `unset-effort` — delete that effort key. Missing key is OK. Unknown
  agent → 64. Unparseable existing → refuse, exit 1. Does not drop `agents`.

Call via `plugin-dir.sh file`. `jq` is required for set/unset/set-effort/
unset-effort.

## `/setup models`

Not doctor-gated. Bare `/setup models` → `write-model.sh list` (model +
effort). `set` / `unset` / `set-effort` / `unset-effort` pass through.
Unknown `/setup` sub still prints usage and does not mutate; `models` is a
known sub.

`/adjust-agent <agent> --model <string>` → `write-model.sh set`.
`/adjust-agent <agent> --model-unset` → `write-model.sh unset`.
`/adjust-agent <agent> --effort <token>` → `write-model.sh set-effort`.
`/adjust-agent <agent> --effort-unset` → `write-model.sh unset-effort`.
Parse those flags before a directives prompt. `--model` and `--effort` MAY
appear together; each write touches only its field. `council-judge` is
mappable. Dashboard (7 behavioral agents) adds an Effort column
(`inherited` when empty).

## `/doctor` `models.map`

Group `config`. No map files at any of the three layer paths → SKIP. Valid
present files → PASS. Unparseable / bad agents / unknown key / `jq` missing
→ WARN (never FAIL). `qa` / `council-judge` in `agents` or `effort` → WARN
(M9). `--fix` does not rewrite the map.

A present file with only `effort` (no `agents`) is present → validate
effort (do not SKIP). Effort keys must be mappable. Values must be
`low|medium|high|xhigh|max` after trim+lowercase. Unparseable / `effort`
not an object / bad effort value / unknown effort key → WARN (never FAIL).

## Related

- SPEC-037 — Per-agent Model map
- SPEC-003 — Tier default roster
- SPEC-005 — `/setup models` dispatch
- SPEC-022 — `models.map` doctor check
- SPEC-009 — light Step 8 `@ic4` omit-path `effort: low`
