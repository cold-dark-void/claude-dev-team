# Setup & Configuration Guide

Setup, initialization, and memory configuration for the claude-dev-team plugin.

---

## Prerequisites

- **Claude Code** — 2.x+
- **`sqlite3`** — for SQLite memory backend (`apt install sqlite3` / `brew install sqlite3`); agents fall back to .md files if unavailable
- **Git** — for worktree-aware memory path resolution
- **Plugin installed**:
  ```bash
  /plugin marketplace add cold-dark-void/claude-dev-team
  /plugin install dev-team
  ```

---

## `/init-team` — Bootstrap Agent Memory

Run once per project. Reads your codebase, CI, and infra, then writes memory for all 7 agents.

```bash
/init-team
```

What it does:
- Spawns `@project-init` to read `AGENTS.md`, source files, CI config, etc.
- Downloads sqlite-vec + sqlite-lembed extensions and an embedding model (~29MB) for semantic search
- Agents store memory in `.claude/memory/memory.db` (SQLite mode) or `.claude/memory/<agent>/` (.md fallback)
- Migrates existing v1 DBs to v2 schema automatically
- Syncs `.claude/settings.json` with the full Bash allow list

Safe to re-run — updates cortex for all agents without losing history.

**Flags:**

| Flag | Effect |
|------|--------|
| `--refresh` | Re-probe embedding mode and re-run migration |
| `--migrate-only` | Only run DB schema migration, skip agent bootstrap |
| `--no-extensions` | Skip sqlite-vec/lembed download; use keyword-only search |

**What gets downloaded (~29MB):**
- `sqlite-vec` — vector search extension
- `sqlite-lembed` — local embedding extension
- `all-MiniLM-L6-v2.gguf` — 384-dim embedding model

If the download fails or `sqlite3` is unavailable, agents fall back to .md files automatically.

---

## `/init-orchestration` — Enable Agent Teams

Enables multi-agent coordination. Run once per project after `/init-team`.

```bash
/init-orchestration
```

What it does:
- Sets `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1` in `.claude/settings.json`
- Wires a `TaskCompleted` quality-gate hook
- Creates/updates `AGENTS.md` with team coordination rules
- Seeds `.claude/memory/claude/memory.md` with baseline orchestrator rules

Safe to re-run (idempotent).

---

## `/generate-specs` — Legacy Project Baseline

For projects with no `specs/` directory. Run once before your first ticket.

```bash
/init-team
/init-orchestration
/generate-specs
```

`/generate-specs` will:
- Read every source file and map the public surface by module
- Ask Tech Lead to group modules into 8–15 domain-level feature areas
- Write one `MUST/SHOULD/MUST NOT` spec per domain in `specs/core/`
- Mark all output `Status: INFERRED — requires human review`
- Flag open questions where intent is ambiguous
- Write a `specs/TDD.md` index

After it runs:
1. Review each generated spec — correct misattributed MUSTs, resolve open questions
2. Run `/reflect-specs` to verify specs match the code
3. Optionally generate tests:
   ```bash
   /generate-tests
   ```
4. Commit:
   ```bash
   git add specs/ tests/
   git commit -m "spec: establish baseline specs and tests from /generate-specs + /generate-tests"
   ```

> Generated specs describe *what the code does*, not necessarily *what it should do*. Treat them as a hypothesis.

---

## Memory Configuration — `/memory-config`

View and set memory distillation settings:

```bash
/memory-config list                              # show current values
/memory-config set distill_enabled true          # enable distillation
/memory-config set distill_mode suggest          # suggest/manual/auto
/memory-config set distill_threshold 50          # raw count trigger
/memory-config set distill_model haiku           # compression model
```

| Key | Values | Default | Description |
|-----|--------|---------|-------------|
| `distill_enabled` | true / false | false | Master switch |
| `distill_mode` | manual / suggest / auto | suggest | manual: only on explicit run; suggest: prints notice at threshold; auto: runs at ticket close |
| `distill_threshold` | 1–9999 | 50 | Raw memory count before suggest/auto triggers |
| `distill_model` | model name | haiku | LLM for compression (Haiku recommended for cost) |

Run `/memory-distill` to compress raw memories into digests. A good time: after wrapping a ticket, or when `--status` shows a high raw count.

---

## Remote Embeddings

To use a remote provider instead of the bundled local model, set these env vars before `/init-team`:

```bash
export EMBEDDING_URL=https://api.openai.com/v1/embeddings
export EMBEDDING_API_KEY=sk-...
export EMBEDDING_MODEL=text-embedding-3-small
/init-team --refresh
```

Any OpenAI-compatible endpoint works (OpenAI, Azure OpenAI, LLMGateway, ollama, etc.). When `EMBEDDING_URL` is set, `/init-team` skips the local extension download entirely.

| Mode | Trigger | Quality |
|------|---------|---------|
| `remote` | `EMBEDDING_URL` env var set | Best (provider-dependent dims) |
| `lembed` | Extensions + GGUF model downloaded | Good (384-dim, all-MiniLM-L6-v2) |
| `fallback` | No extensions available | Keyword search only |

---

## Troubleshooting

### `sqlite3: command not found`

Install via your package manager:
```bash
apt install sqlite3      # Debian/Ubuntu
brew install sqlite3     # macOS
```
Without it, agents fall back to .md files — the plugin still works, just without semantic search.

### Extension download fails

`/init-team` downloads sqlite-vec and sqlite-lembed (~29MB). If on a restricted network:
- Use `/init-team --no-extensions` for keyword-only search
- Or set `EMBEDDING_URL` for remote embeddings (no local extensions needed)

### Schema migration errors

If you see "table already exists" or column errors after upgrading:
- Run `/init-team --refresh` to re-probe and re-migrate
- Or delete `.claude/memory/memory.db` and re-run `/init-team` (loses stored memories)

### Agents not discovering commands

All command/skill `.md` files require YAML frontmatter (`name`, `description`).
Files without frontmatter are invisible to Claude Code's discovery system.
