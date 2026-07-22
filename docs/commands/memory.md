# /memory

Unified entry point for all agent-memory operations. One dispatcher; six subs
cover config, distillation, export, search, stats, and validation. Prefer this
surface over the legacy `/memory-*` commands (deprecated — removed at v1.0.0).

## Usage

```
/memory <config|distill|export|search|stats|validate> [args...]
```

| Sub | Summary |
|-----|---------|
| `config` | View/set distillation and validation config |
| `distill` | Compress tier-0 raw memories into digests; promote high-signal to core |
| `export` | Export sanitized tier-2 seed pack (SPEC-024) |
| `search` | Search memories (semantic → keyword → grep) |
| `stats` | Anonymized usage metrics (counts and sizes only) |
| `validate` | Cross-reference memories vs codebase; `--reconcile` for contradictions |

Unknown or missing sub prints the table and stops.

## Sub: `config`

View and update memory distillation configuration in the SQLite `config` table
(`.claude/memory/memory.db`). Requires `/init-team` first.

```
/memory config list
/memory config set <key> <value>
```

| Key | Values | Default | Description |
|-----|--------|---------|-------------|
| `distill_enabled` | `true` / `false` | `false` | Master switch for automatic distillation |
| `distill_mode` | `manual` / `suggest` / `auto` | `suggest` | When distillation triggers |
| `distill_threshold` | integer 1–9999 | `50` | Raw memory count per agent before trigger |
| `distill_model` | model name | `haiku` | Model used by `@distiller` |
| `validate_window_days` | integer 1–365 | — | Skip recently-validated rows |
| `reconcile_pair_cap` | integer 1–500 | — | Max contradiction pairs per reconcile pass |

Read-only keys (`distilling_lock`, `schema_version`) cannot be set manually.
Invalid values are rejected before write.

**Examples:**
```
/memory config list
/memory config set distill_enabled true
/memory config set distill_threshold 25
```

`distill_mode`: `manual` = explicit `/memory distill` only; `suggest` = agents
may remind when counts are high; `auto` = agents trigger at threshold.

## Sub: `distill`

Compress tier-0 (raw) memories into tier-1 digests and promote high-signal
knowledge to tier-2 core. Spawns `@distiller`. Consumed tier-0 rows are
**archived**, not deleted.

```
/memory distill [--agent <name>] [--status] [--force] [--skip-validate] [--compress]
```

| Flag | Description |
|------|-------------|
| *(none)* | Distill all agents over the configured threshold |
| `--agent <name>` | Distill one agent regardless of threshold |
| `--status` | Show tier counts per agent + config — no distillation |
| `--force` | Clear a stale distillation lock before running |
| `--skip-validate` | Skip pre-distill validation |
| `--compress` | Fact-dense rewrite of verbose tier-0 prose first (`skills/memory-compress`; also `MEMORY_COMPRESS=1`) |

Flags combine: `/memory distill --force --agent pm`. Manual invocation always
proceeds even if `distill_enabled=false`. Requires SQLite backend.

**Examples:**
```
/memory distill --status
/memory distill
/memory distill --agent ic4
/memory distill --compress --agent pm
```

## Sub: `export`

Write a sanitized, provenance-tagged seed pack from tier-2/core memories to
`.claude/memory/seed/`. For human PR review and commit — **never** git-adds,
commits, or pushes.

```
/memory export [--agent <name>] [--limit N] [--dry-run]
```

| Flag | Description |
|------|-------------|
| *(none)* | Export all 7 behavioral agents (default cap 40 entries/agent) |
| `--agent <name>` | One agent only (`pm\|tech-lead\|ic5\|ic4\|devops\|qa\|ds`) |
| `--limit N` | Override per-agent entry cap |
| `--dry-run` | Print what would be written (including exclusions); write nothing |

After export: skim for residual secrets, commit via reviewed PR. Fresh clones
import the pack on `/init-team` (warm start). See SPEC-024.

## Sub: `search`

Search all agent memories. Auto-detects the best available method: semantic
(vector embeddings) → keyword (SQLite `LIKE`) → grep (`.md` files).

```
/memory search <query>
/memory search --status
```

| Flag / Argument | Description |
|-----------------|-------------|
| `<query>` | Text to search across all agent memories |
| `--status` | Show DB path, embedding config, per-agent tier counts |

Results (DB modes) sort by tier (core → digests → raw) then relevance.
Archived memories are excluded.

**Examples:**
```
/memory search authentication token
/memory search --status
```

## Sub: `stats`

Anonymized usage metrics — counts and sizes only, never memory content. Safe
to share publicly.

```
/memory stats
/memory stats --agent <name>
```

Shows per-agent breakdown (type counts, avg/max/total chars), overall summary,
embedding coverage, and boot-load estimate (chars each agent loads at session
start, with HIGH/moderate/ok status).

## Sub: `validate`

Cross-reference agent memories against the live codebase to detect stale refs
(dead files, renamed symbols, outdated claims). With `--reconcile`, detect
**cross-agent contradictions** instead.

```
/memory validate [--agent <name>] [--deep] [--force]
/memory validate --reconcile [--report-only]
```

| Flag | Description |
|------|-------------|
| `--agent <name>` | Limit to one agent |
| `--deep` | Also rebuild digests whose sources went stale |
| `--force` | Ignore `validated_at` window; re-validate everything |
| `--reconcile` | Cross-agent contradiction pass (not codebase validation) |
| `--report-only` | With `--reconcile`: list contradictions; **zero DB writes** |

`--deep` and `--reconcile` are mutually exclusive. Never auto-archives
contradictions — user decides. Skill protocol: `skills/validate-memory/SKILL.md`.

## How It Works

Memory lives in `.claude/memory/memory.db` (shared across worktrees). Tiers:

| Tier | Name | Role |
|------|------|------|
| 0 | Raw | Session observations; agents write these |
| 1 | Digest | LLM-compressed summaries from `distill` |
| 2 | Core | Promoted high-signal knowledge (permanent) |
| — | Archived | Consumed tier-0; excluded from load/search |

Session start loads core then digests; if none exist, all raw (backward compat).
Without distillation, raw counts grow and boot load balloons.

## See Also

- [Memory runbook](../runbooks/memory.md) — tiers, hygiene, distillation workflow
- [Setup → Memory config](../setup.md#memory-configuration----memory-config) — first-time settings
- [`/recall`](./recall.md) — cross-source search (sessions, memory, specs, plans, git)
- [`/init-team`](../setup.md#init-team--bootstrap-agent-memory) — bootstrap the memory DB
