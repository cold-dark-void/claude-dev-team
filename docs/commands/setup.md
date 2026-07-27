# /setup

Onboarding dispatcher (SPEC-005). Three behaviorally distinct flows share one
Surface — do not merge their protocols.

| Sub | Maps from | What it does |
|-----|-----------|--------------|
| `project` | scaffold-project skill | TDD structure: `AGENTS.md`, `specs/TDD.md`, `.claude/plans/`, settings allowlist |
| `orchestration` | init-orchestration skill | Agent Teams: sandbox, hooks, `dontAsk`, AGENTS.md team section |
| `team` | former init-team command | Memory bootstrap: SQLite DB, embedding extensions, project-init scan |

Prefer this surface over the init-team / scaffold-project / init-orchestration
discovery paths (deprecated stubs or skill tombstones as of v1.0.0).

## Usage

```
/setup <project|orchestration|team> [flags...]
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

## See also

- [Setup & Configuration](../setup.md) — prerequisites, upgrading, memory config
- [Onboarding runbook](../runbooks/onboarding.md)
