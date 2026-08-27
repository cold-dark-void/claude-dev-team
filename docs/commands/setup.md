# /setup

Onboarding dispatcher (SPEC-005). Three behaviorally distinct onboarding flows
plus the local Model map share one Surface — do not merge their protocols.

| Sub | Maps from | What it does |
|-----|-----------|--------------|
| `project` | scaffold-project skill | TDD structure: `AGENTS.md`, `specs/TDD.md`, `.claude/plans/`, settings allowlist |
| `orchestration` | init-orchestration skill | Agent Teams: sandbox, hooks, `dontAsk`, AGENTS.md team section |
| `team` | former init-team command | Memory bootstrap: SQLite DB, embedding extensions, project-init scan |
| `models` | `write-model.sh` | Local Model map list/set/unset (not doctor-gated) |

Prefer this surface. Old slash names (`/init-team`, `/scaffold-project`,
`/init-orchestration`) were removed at v1.1; scaffold and orchestration
protocol lives under `skills/` as permanent skill-delegate backends.

## Usage

```
/setup <project|orchestration|team|models> [flags...]
```

Bare or unknown sub prints usage and **stops with zero side effects** — no default.

### Examples

```
/setup project
/setup orchestration
/setup team
/setup team --refresh
/setup team --migrate-only
/setup team --no-extensions
/setup models
/setup models set ic4 grok-code-fast-1
/setup models unset ic4
```

## Sub: `project`

Greenfield / add-TDD scaffold. Idempotent; asks before overwrite. See
`skills/scaffold-project/SKILL.md` and the [Setup guide](../setup.md).

## Sub: `orchestration`

Brownfield merge for Agent Teams. Safe re-run (merge, not clobber). Ship posture
is Cell D `auto` + sandbox + matrix allow (CDT-75). **Not pure zero-intervention:**
settings merge + `bash-compress.sh` need one batched explicit approval up front
(CDT-68). Doctor gate uses `--gate=orchestration` so self-remediating FAILs do
not circular-block (CDT-67). See `skills/init-orchestration/SKILL.md` and
[Setup → `/setup orchestration`](../setup.md#setup-orchestration--enable-agent-teams).

## Sub: `team`

Bootstrap all 7 agents' memory for the current project.

| Flag | Effect |
|------|--------|
| `--refresh` | Re-probe / re-seed cortex |
| `--migrate-only` | Schema migrate without full project-init scan |
| `--no-extensions` | Keyword-only search (skip embedding download) |

Full procedure: [Setup → `/setup team`](../setup.md#setup-team--bootstrap-agent-memory).

## Sub: `models`

Local Model map (SPEC-037). Bare `/setup models` lists the 8 mappable agents
(winning string or `Tier default`) plus the local path. `set` / `unset` write
only `$MROOT/.claude/dev-team/models.local.json`. Not doctor-gated. Sugar:
`/adjust-agent <agent> --model <string>` / `--model-unset`.

## See also

- [Setup & Configuration](../setup.md) — prerequisites, upgrading, memory config
- [Onboarding runbook](../runbooks/onboarding.md)
