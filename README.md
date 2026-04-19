# Claude Dev Team

A FAANG-style AI dev team plugin for [Claude Code](https://claude.ai/claude-code). Gives you seven specialized agents with persistent per-project memory, plus a full spec management workflow and project scaffolding — all wired together.

## Install

```bash
/plugin marketplace add cold-dark-void/claude-dev-team
```

Or if you haven't added this marketplace yet:

```bash
/plugin marketplace add cold-dark-void/claude-dev-team
/plugin install dev-team
```

## What You Get

### Agents

| Agent | Model | Tools | Role |
|-------|-------|-------|------|
| `pm` | Sonnet | Read, Write, Edit, Grep, Glob, Bash, Task*, SendMessage | Requirements, user stories, acceptance criteria, prioritization |
| `tech-lead` | Opus | Read, Write, Edit, Grep, Glob, Bash, Task*, SendMessage | Architecture, system design, cross-cutting concerns, unblocking ICs |
| `ic5` | Opus | Read, Write, Edit, Bash, Grep, Glob, Task*, SendMessage | Complex implementation — ambiguous problems, hard bugs, new systems |
| `ic4` | Sonnet | Read, Write, Edit, Bash, Grep, Glob, Task*, SendMessage | Well-defined tasks — extending patterns, tests, simple fixes |
| `devops` | Sonnet | Read, Write, Edit, Bash, Grep, Glob, Task*, SendMessage | Deployments, CI/CD, infrastructure, monitoring, incident response |
| `qa` | Opus | Read, Write, Edit, Grep, Glob, Bash, Task*, SendMessage | Test planning, validation, bug reports, **release gating** |
| `ds` | Opus | Read, Write, Edit, Bash, Grep, Glob, Task*, SendMessage | Data analysis, ML/AI pipelines, A/B testing, metrics, statistical modeling |
| `project-init` | Sonnet | Read, Write, Edit, Bash, Grep, Glob, SendMessage | _(internal)_ One-time team memory bootstrap — invoked by `/init-team`, not directly |
| `distiller` | Haiku | Bash, Read | _(internal)_ Memory compression specialist — invoked by `/memory-distill`, not directly |

Each agent has persistent memory — stored in SQLite (preferred) or markdown files (fallback):

### Memory Storage

| Storage | When | Description |
|---------|------|-------------|
| SQLite DB | After `/init-team` with extensions | Single DB at `.claude/memory/memory.db` with semantic search |
| .md files | Fallback (no sqlite3 or extensions) | Per-agent files at `.claude/memory/<agent>/` |
| `context.md` | Always | Per-worktree task progress (never migrated to DB) |

After running `/init-team`, the plugin downloads sqlite-vec + sqlite-lembed extensions and an embedding model (~29MB total) for semantic search. If unavailable, agents fall back to .md files transparently.

### Embedding Modes

| Mode | Trigger | Quality |
|------|---------|---------|
| `remote` | `EMBEDDING_URL` env var set (OpenAI-compatible endpoint) | Best (provider-dependent dims) |
| `lembed` | Extensions + GGUF model downloaded | Good (384-dim, all-MiniLM-L6-v2) |
| `fallback` | No extensions available | Keyword search only |

Mode is detected during `/init-team` and can be refreshed with `/init-team --refresh`.

### Commands / Skills

#### Setup (run once per project)

| Command | What it does |
|---------|-------------|
| `/init-team` | Bootstrap all 7 agents' memory for the current project |
| `/adjust-agent` | View and manage per-agent behavioral directives (supports `--apply` for non-interactive use) |
| `/scaffold-project` | Create TDD workflow structure: `AGENTS.md`, `specs/TDD.md`, `.claude/plans/` |
| `/init-orchestration` | Enable Agent Teams: sandbox, env var, auto-memory + Stop + TaskCompleted hooks, AGENTS.md |

#### Feature work

| Command | What it does |
|---------|-------------|
| `/brainstorm` | Socratic design refinement — structured questioning before planning |
| `/kickoff` | Parallel PM+TL kickoff → spec → implementation plan → task graph |
| `/orchestrate` | Full lifecycle: fetch issue → worktree → agents → review loops → PR |
| `/standup` | Status snapshot: TaskList + agent context, surfaces blockers and stale tasks |
| `/wrap-ticket` | Close out: verify tasks, capture learnings, update plans, remove worktree |

#### Spec management

| Command | What it does |
|---------|-------------|
| `/create-spec` | Guided interview → new behavioral spec in `specs/` |
| `/update-spec` | Modify an existing spec with version history |
| `/find-spec` | Search specs by keyword |
| `/list-specs` | Quick status overview of all specs |
| `/generate-specs` | Reverse-engineer specs from existing code (legacy project baseline) |

#### Code quality

| Command | What it does |
|---------|-------------|
| `/review-and-commit` | 5-agent parallel review with confidence scoring, blocks commit on critical issues |
| `/check-specs` | Audit spec format + code alignment (MATCH/MISSING/DIFFERS per requirement) |
| `/reflect-specs` | Full health check — ALL specs exhaustively, cross-spec conflicts, interactive |
| `/generate-tests` | Generate tests from specs — one test per MUST requirement, tagged with spec ID |
| `/tdd-gate` | Toggle hook-based TDD enforcement — blocks Write/Edit without tests (on/off/status) |

#### Memory & recall

| Command | What it does |
|---------|-------------|
| `/memory-search <query>` | Search agent memories — semantic, keyword, or grep fallback |
| `/memory-stats` | Show memory usage statistics (counts, sizes, growth) |
| `/recall` | Cross-source search: sessions, memory, specs, plans, git history |
| `/memory-distill` | Compress raw memories into digests, promote high-signal to core |
| `/memory-config` | View and set memory configuration (distill mode, threshold) |

#### Maintenance

| Command | What it does |
|---------|-------------|
| `/backlog` | Manage project backlog items (add, close, list, init) |
| `/release` | Bump version across all files, commit, tag, push |
| `/scout-plugins` | Research new plugins, evaluate against current setup, propose enhancements |
| `/retro` | Review past sessions for friction patterns, propose directive adjustments — `--all` for cross-session, `--auto` to apply without confirm, `--why` for gate calibration |
| `/council` | Adversarial tribunal — reality-checks a claim, session slice, or diff via blind investigators, prosecutor, devil's advocate, and a tool-less judge. See [/council](#council) below. |

---

## Quick Start

> **Heads up**: `/init-team` downloads sqlite-vec, sqlite-lembed, and an embedding model (~29MB total) for semantic memory search. This takes 1-2 minutes and requires internet access. If you're on a restricted network or air-gapped, use `/init-team --no-extensions` to skip downloads and use keyword-only search.

### New project

```
/scaffold-project          # Sets up AGENTS.md, specs/TDD.md, .claude/plans/
/init-team                 # Bootstraps all agent memories from your codebase
/init-orchestration        # Enable Agent Teams: env var + quality-gate hook + AGENTS.md
```

### Existing project

```
/init-team                 # Run once — reads AGENTS.md, code, CI, infra, writes memory for each agent
```

> **Note**: `/init-team` downloads sqlite-vec + sqlite-lembed extensions and an embedding model (~29MB) for semantic memory search. If the download fails or `sqlite3` is unavailable, agents fall back to .md files automatically.

> **Note**: The bundled `.claude/settings.json` pre-approves common operations so agents run without permission prompts. See [Autonomy & Permissions](#autonomy--permissions) below.

### Starting a task

```
/kickoff POC-123 "Add user avatar upload with S3 storage"
```

This runs PM + Tech Lead in parallel, creates a spec, produces an implementation plan, and generates a task graph — all in one command.

For full lifecycle automation (branch, implement, review, PR):
```
/orchestrate POC-123
```

You can also invoke agents directly when needed:
```
Use the ic5 subagent to implement: [complex task]
Use the qa subagent to validate against the spec before we deploy
```

Or just describe the task — Claude will route to the right agent automatically based on their descriptions.

---

## Typical Workflow

```
PM  ──► defines requirements + acceptance criteria
         │
Tech Lead ──► architecture direction, unblocks ICs
         │
IC5 / IC4 ──► implement (IC5: complex, IC4: simple)
         │
QA  ──► validates all acceptance criteria ─── BLOCK if issues ──► back to IC
         │ GO
DevOps ──► deploy + monitor
```

### Routing shortcuts

| Task type | Agent |
|-----------|-------|
| Ambiguous / hard / new system | IC5 |
| Clear pattern extension / tests / config | IC4 |
| Design question / architecture | Tech Lead |
| Bug investigation + fix | IC5 |
| Infrastructure, deploy, CI | DevOps |
| Spec validation, release gate | QA |
| Requirements, scoping | PM |

---

## Memory Layout

After `/init-team` runs:

**SQLite mode** (sqlite3 + extensions available):
```
{project}/.claude/memory/
  memory.db          ← single shared DB (all agents, all types)
  extensions/
    vec0.so          ← sqlite-vec (vector search)
    lembed0.so       ← sqlite-lembed (local embeddings)
  models/
    all-MiniLM-L6-v2.gguf

{worktree}/.claude/memory/{agent}/context.md   ← per-worktree, stays as .md
```

**Fallback mode** (no sqlite3 or extensions):
```
{project}/.claude/memory/
  pm/           cortex.md ✓   memory.md   lessons.md
  tech-lead/    cortex.md ✓   memory.md   lessons.md ✓ (seeded from AGENTS.md)
  ic5/          cortex.md ✓   memory.md   lessons.md ✓ (seeded from AGENTS.md)
  ic4/          cortex.md ✓   memory.md   lessons.md
  devops/       cortex.md ✓   memory.md   lessons.md
  qa/           cortex.md ✓   memory.md   lessons.md

{worktree}/.claude/memory/{agent}/context.md   ← fills as work happens
```

Cortex knowledge is populated on init. Everything else fills naturally as the team works. The team gets sharper the more you use it on a project — agents stop re-reading the codebase from scratch each session.

### Memory Distillation

Over time, raw memories accumulate — context windows fill up and agents re-read stale information. Run `/memory-distill` periodically to keep memory lean. When triggered, it batches tier-0 (raw) rows, spawns the `@distiller` agent (Haiku) to compress them into tier-1 digests, evaluates each digest for tier-2 promotion, and archives the consumed tier-0 rows (never deletes). A good time to run it: after wrapping a ticket, or when `/memory-distill --status` shows a high raw count.

| Tier | Label | Description |
|------|-------|-------------|
| 0 | raw | Every memory written by agents during work |
| 1 | digest | LLM-compressed summaries from batches of raw memories |
| 2 | core | Promoted permanent knowledge (decisions, lessons, architecture) |

Configure with `/memory-config` — see [memory configuration](docs/setup.md#memory-configuration----memory-config) for the full options table.

### Remote Embeddings

Set `EMBEDDING_URL`, `EMBEDDING_API_KEY`, and `EMBEDDING_MODEL` env vars before `/init-team --refresh` to use any OpenAI-compatible provider. See [Remote Embeddings setup](docs/setup.md#remote-embeddings) for details.

### Re-initialize after major changes

```
/init-team    # Safe to re-run — updates cortex.md for all agents
```

---

## Spec Workflow

Specs live in `specs/` and are tracked in `specs/TDD.md`. The QA agent reads them as acceptance criteria. The IC agents read them before implementation.

```
/create-spec          # Guided interview → new spec file + TDD.md entry
/list-specs           # Quick status: what's passing, new, broken
/find-spec thumbnail  # Search across all spec content
/check-specs          # Audit all specs: format compliance + code alignment (samples 3–5 recent specs)
/check-specs SPEC-012 # Validate spec: Grep source, classify each MUST as MATCH/MISSING/DIFFERS, flag drift
/update-spec          # Modify spec: cross-spec conflict check + code alignment warning on changed requirements
/reflect-specs       # Full health check: ALL specs + cross-spec conflicts + skill consistency + interactive confirmation
```

### Spec categories

| Prefix | Category |
|--------|----------|
| `SPEC-` | Core behavior |
| `PERF-` | Performance |
| `SAFE-` | Safety / concurrency |
| `COMPAT-` | Compatibility |
| `ARCH-` | Architecture |

---

## Autonomy & Permissions

The plugin ships `.claude/settings.json` which pre-approves common operations so agents run without prompting for every tool call:

```json
{
  "permissions": {
    "defaultMode": "acceptEdits",
    "allow": [
      "Bash(git:*)", "Bash(npm:*)", "Bash(go:*)", "Bash(gh:*)",
      "Bash(_gc=*)", "Bash(MROOT=*)", "Bash(AGENT_*)", "Bash({:*)",
      "Bash(grep:*)", "Bash(sed -n:*)", "Bash(if :*)", "Bash(for :*)",
      "..."
    ]
  }
}
```

- **`defaultMode: "acceptEdits"`** — file reads, writes, and edits are auto-approved
- **Bash allow list** — 41 entries covering dev tools, agent bootstrap patterns (variable assignments, compound commands, shell control flow), and common read-only utilities
- **Intentionally excluded**: destructive commands (`rm`, `curl`, `wget`) still prompt for confirmation

Both `/scaffold-project` (new projects) and `/init-team` (existing projects) emit/sync the full allowlist automatically.

To extend for your stack, add entries to `.claude/settings.json`:

```json
"Bash(terraform:*)",
"Bash(kubectl:*)",
"Bash(docker:*)"
```

### Memory budgets

In SQLite mode, there are no line limits — the DB handles storage efficiently.

In .md fallback mode, agents enforce file size limits to prevent context blowout:

| File | Limit |
|------|-------|
| `cortex.md` | ≤ 100 lines |
| `memory.md` | ≤ 50 lines |
| `lessons.md` | ≤ 80 lines |
| `context.md` | ≤ 60 lines (always .md, both modes) |

Agents trim stale content before writing and skip files that don't exist yet.

---

## Adding to a Team

Check the plugin into your project's settings so teammates get it automatically. The plugin already ships `.claude/settings.json` — merge the marketplace entry into it:

**`.claude/settings.json`**:
```json
{
  "permissions": {
    "defaultMode": "acceptEdits",
    "allow": ["Bash(git:*)", "Bash(npm:*)", "..."]
  },
  "extraKnownMarketplaces": {
    "dev-team": {
      "source": {
        "source": "github",
        "repo": "cold-dark-void/claude-dev-team"
      }
    }
  }
}
```

---

## Requirements

- Claude Code 2.x+
- Git (for worktree-aware memory path resolution)

---

## /council

Adversarial tribunal that reality-checks claims with material evidence. Spawns
blind Investigators (read-only tools only), a Prosecutor (jaded-senior flavor),
a Devil's Advocate (yolo-ic flavor), and a tool-less `council-judge` agent.
Issues per-claim verdicts with confidence scores (`VERIFIED`, `PARTIALLY_VERIFIED`,
`UNVERIFIED`, `CONTRADICTED`, `FABRICATED`). Shares an engine with `/review-commit`
via the `diff-mode` preset. Every verdict line must be backed by an investigator
`tool_use_id`; lines without evidence are struck and logged.

**Arguments:**

| Form | Scope |
|------|-------|
| `/council "<claim text>"` | Audit a single pasted claim |
| `/council --session [--last N]` | Audit a slice of the current session transcript |
| `/council --diff` | Audit staged diff (same engine path as `/review-commit`) |
| `/council --task-id <id>` | Bind verdict to a task; appends row to `.claude/council/index.json` |

`--plan <path>` and `--from-retro <anchor-id>` are deferred to COUNCIL-002 — both
fail loudly with a clear deferral message (engine exit 3). Do not substitute another
scope when either is supplied.

Engine protocol: `skills/council/SKILL.md`. Full contract: `specs/core/SPEC-013-adversarial-council-tribunal.md`.

---

## Changelog

### v0.19.5
- **Session 00000000 dogfood improvements** — 9 fixes from analyzing a real 17-hour orchestration session on the Project project (Architecture 2.0 overhaul, 98 subagents, 7 tickets shipped)
- **Council evidence JSON repair** — `engine.sh finalize` now auto-repairs invalid JSON caused by unescaped backslashes in investigator `raw_blob` fields (Go regex, Windows paths, etc.). Character-by-character repair runs only when jq rejects the evidence file. Tested against the exact jq exit-5 error from session 00000000
- **Task store upsert** — `task-store.sh create` now upserts instead of erroring on duplicate task IDs; `update-status` auto-creates stub if task file missing after session pause/resume
- **Mandatory spec alignment check** — new Step 10b in orchestrate: `/check-specs` runs after QA and survives pause/resume (explicitly flagged as non-skippable)
- **PM kickoff enforced for all child tickets** — orchestrate now requires PM AC review for every ticket in an umbrella, not just leaf/bug tickets
- **IC agent prompts include architecture context** — orchestrate Step 8 spawn template now enumerates all affected backends/services/platforms so ICs don't discover them by accident
- **ic4→ic5 escalation heuristic** — kickoff and orchestrate now guide Tech Lead: tasks touching >10 files or >15 callsites should go to ic5, not ic4
- **Plain git squash merge** — orchestrate prefers `git merge --squash` over `gh pr merge`; gh is optional, not required
- **Go sandbox cache detection** — init-orchestration detects `go.mod` and offers `GOCACHE=$TMPDIR/go-cache GOWORK=off` injection into agent prompts
- **Worktree cleanup serialized** — orchestrate documents serial worktree removal to avoid `git config: Device or resource busy` from parallel operations

### v0.19.4
- **Remaining review fixes** — stop-review stamp stored project-locally (not in $TMPDIR), generic preset uses only investigator-role flavors, memory-capture deduplicates consecutive identical observations, FK constraints on distillation_log and validation_log

### v0.19.3
- **33-finding upstream review sweep** — comprehensive bug, security, and correctness fixes from external review
- **Council engine fixed** — judge output parser now unwraps `{verdicts: [...]}` / `{findings: [...]}` object (was treating as flat array, producing empty reports). All 12 jq queries + Python renderer corrected. Evidence validation accepts object shape. Report writes are atomic (tmp+rename). Diff-mode flavor list trimmed to 5 specialists
- **Security hardening** — SQL injection eliminated across 5 files (sed-escaped interpolation replaced with python3 parameterized queries). Bearer tokens passed via `curl --config` file instead of `-H` flag (invisible to `ps aux`). Path traversal validation on task_id and slug. Memory-capture redacts secret patterns in bash args
- **Correctness fixes** — `commands/council.md` uses `$ENGINE_SH` variable instead of bare `engine.sh`. Preflight field names match engine output. `init-orchestration` baseline seeding uses DELETE+INSERT (was broken INSERT OR REPLACE). `tdd-gate` intercepts MultiEdit and handles `src/` path prefix. `memory-distill` validation abort gated by exit code. `distiller.md` INSERT+lastrowid in single call. PRAGMA busy_timeout=5000 on all read paths. Schema lookup uses vendor-agnostic glob
- **Migration**: existing projects should re-run `/init-orchestration` to pick up the new hook templates and memory-capture fixes

### v0.19.2
- **Fix stop-review hook infinite loop** — the Stop hook (`stop-review.sh`) installed by `/init-orchestration` would enter an infinite exit-block loop when uncommitted changes existed before the session (or when the agent couldn't commit). Now uses a one-shot stamp keyed on `session_id` from stdin JSON: warns once, then lets the agent exit
- **Migration**: existing projects should re-run `/init-orchestration` to regenerate the hook, or manually replace `.claude/hooks/stop-review.sh`

### v0.19.1
- **Simplify project-init bash permissions** — replaced 44-entry command allowlist with single `Bash(*)` wildcard

### v0.19.0
- New `/tdd-gate` command — toggle hook-based TDD enforcement. When enabled, a `PreToolUse` hook blocks Write/Edit to implementation files unless a corresponding test file exists. Supports TypeScript, JavaScript, Python, Go, Rust. Inspired by Superpowers + TDD Guard
- Usage: `/tdd-gate on` to enable, `/tdd-gate off` to disable, `/tdd-gate status` to check

### v0.18.4
- Auto memory capture — `/init-orchestration` now installs a `PostToolUse` hook (`memory-capture.sh`) that logs Write/Edit/Bash actions to tier-0 memory automatically. No LLM calls — raw observations feed `/memory-distill` for compression later. Inspired by claude-mem
- **Migration**: existing projects should re-run `/init-orchestration` to pick up the new PostToolUse hook

### v0.18.3
- Stop hook self-review gate — `/init-orchestration` now installs a `Stop` hook (`stop-review.sh`) that blocks agent exit when uncommitted changes exist, forcing the agent to verify completeness before finishing. Inspired by codex-plugin-cc
- **Migration**: existing projects should re-run `/init-orchestration` to pick up the new Stop hook

### v0.18.2
- Terse agent-to-agent communication — agents compress output ~65% when spawned by `/orchestrate` or `/kickoff` (decisions, code, blockers only; no narrative). Inspired by Caveman plugin. Override per-agent via `/adjust-agent`
- Trigger: `Output mode: terse` in task prompt activates compressed output; user-facing sessions unaffected

### v0.18.1
- Fix: council report template substitution — `engine.sh finalize` now renders all `{{VAR}}` placeholders instead of dumping raw templates with appended JSON
- Fix: claim extractor now prioritizes behavioral claims ("the fix works") over code-structure assertions ("line N calls X") in frustration-heavy debugging sessions
- Fix: stdout summary surfaces PARTIALLY_VERIFIED / FABRICATED verdicts with claim text + confidence ("Needs attention" block), not just counts

### v0.18.0
- New `/council` adversarial tribunal — reality-checks claims with material evidence via blind investigators, prosecutor, devil's advocate, and a tool-less judge
- `/review-commit` refactored to delegate to the council engine via `diff-mode` preset (finding-shape output; identical user-visible behavior preserved)
- `/retro` now classifies fabrication anchors and prints `Consider: /council --from-retro <anchor-id>` hints at completion
- TaskCompleted hook gains an opt-in council quality gate — blocks completion until a council verdict at or above threshold when task metadata sets `requires_council: true`
- New `council-judge` agent with structurally empty tool allowlist enforcing the evidence-only invariant
- Per-task metadata store at `.claude/tasks/<id>.json` (orchestrator-owned) and verdict index at `.claude/council/index.json` (engine-owned)
- 60+ new MUSTs across SPEC-013 (new), SPEC-002, SPEC-009, SPEC-010, SPEC-012

### v0.17.2
- **Docs catch-up for v0.17.0/v0.17.1**: new `docs/commands/retro.md` walks through `/retro` end-to-end (flags, two-phase pipeline, dedup classification, apply paths, integration with `/kickoff` and `/orchestrate`)
- `docs/commands/kickoff.md` and `docs/commands/orchestrate.md` now document the Step 8b / Step 12b friction-check hook and link to `/retro`
- README `Commands / Skills` table gains a `/retro` row and notes `/adjust-agent`'s new `--apply` non-interactive mode

### v0.17.1
- **Polish pass on v0.17.0**: `commands/retro.md` 1031 → 993 lines; ~190 net LOC deleted across the retro feature
- Dead jq fallback paths removed from `skills/retro-gate/gate.sh` and `commands/retro.md` (python3 was already required elsewhere)
- Step 4a `load_rules()` helper deleted (superseded by Step 5b); `build_anchor_json()` and `target_rules_for()` helpers inlined
- `--why` signal parser rewritten from grep+awk to a python3 one-liner
- TIGHTEN classifier now uses a deterministic `existing_ref + "; additionally, " + proposed_text` merge instead of the "mentally rewrite" prompt-in-comment pattern
- New `skills/retro-gate/hint.sh` — friction-check helper; `/kickoff` and `/orchestrate` hooks now call it instead of duplicating ~30 lines each. One parser, one contract.
- `/adjust-agent`: conflict-detection rules extracted into a named subsection; Step 5c (interactive) and Step 6c (`--apply`) both reference it cleanly
- `skills/retro-subagent/SKILL.md`: 44-line worked example pruned to a UUID-format callout under the Input contract
- Nitpicks cleaned: HTML comments with personal paths and planning residue removed; unused `last_tool_use_target` variable and `tool_target()` helper deleted from gate.sh

### v0.17.0
- `/retro`: session retrospective — two-phase friction gate + phase-2 deep-read subagent; proposes targeted adjustments to agent directives
- `/adjust-agent --apply` non-interactive mode (SPEC-001 extension) — enables automation callers like `/retro --auto` while preserving conflict detection
- `/kickoff` and `/orchestrate` gain non-blocking friction-check hooks that suggest `/retro <session-id>` when friction accumulated
- New skills: `skills/retro-gate/` (phase-1 heuristic scorer), `skills/retro-subagent/` (phase-2 analysis prompt template)

### v0.16.0
- `/validate-memory`: cross-reference agent memories against the live codebase to detect stale references (dead files, renamed functions, shifted line numbers)
- Multi-stage validation pipeline: confidence scoring (0-100), auto-archive (>80), tech-lead review (40-80), user flag (<40)
- `--deep` mode: rebuild tier-1 digests whose source memories have gone stale
- Pre-distill integration: `/memory-distill` now validates before compressing (opt-out via `--skip-validate`)
- Schema v3 migration: `validated_at`, `archive_reason` columns, `validation_log` table
- Configurable validation window via `/memory-config set validate_window_days <N>`

### v0.15.1
- **SKILL.md YAML fix** — convert all multiline `description` fields to `|` block scalar syntax, fixing parse errors when skills are used outside Claude Code (colons in continuation lines were misinterpreted as YAML keys)
- **Baseline specs** — establish SPEC-001 through SPEC-010 from /generate-specs

### v0.15.0
- `/adjust-agent`: per-agent behavioral directives — customize agent tone, strictness, and standing orders per project
- Directives load before memory (Asimov model — standing orders agents cannot override)
- All 7 behavioral agents support directives loading
- `/init-team` now hints about `/adjust-agent` after bootstrap

### v0.14.2
- **Documentation revamp**: 10 command guides in `docs/commands/`, expanded memory distillation and remote embeddings docs
- **Doc restructure**: split 1313-line runbook into `docs/setup.md` (config/troubleshooting) and 6 goal-oriented runbooks in `docs/runbooks/`

### v0.14.1
- Fix CAS lock in `/memory-distill` — UPDATE + `changes()` now run in single sqlite3 session
- Add `@distiller` agent to README agents table
- Fix changelog: 7 working agents have tiered loading (not 8; project-init has no session read)

### v0.14.0
- **3-layer tiered memory distillation**: raw memories (tier 0) can now be compressed into LLM-generated digests (tier 1) and promoted to permanent core knowledge (tier 2) via `/memory-distill`
- **`/memory-distill`**: new command — compress raw agent memories into concise digests, evaluate for tier-2 promotion; supports `--agent`, `--status`, and `--force` flags; orchestrates a dedicated `@distiller` agent (Haiku)
- **`/memory-config`**: new command — view and set distillation config keys (`distill_enabled`, `distill_mode`, `distill_threshold`, `distill_model`) with validation
- **`@distiller` agent**: lightweight Haiku specialist spawned only by `/memory-distill`; never self-prompts; archives source memories after distillation (never deletes)
- **Tiered session loading**: all 7 working agents load tier-2 + tier-1 when distilled content exists; fall back to tier-0 for full backward compatibility on undistilled DBs
- **Auto-distill hook in `/wrap-ticket`**: in `suggest` mode prints notice when agents exceed threshold; in `auto` mode queues distillation at ticket close
- **Schema v2 migration**: `memories` table gains `tier`, `archived`, `distilled_from` columns; new `distillation_log` table; `migrate-v2.sh` for upgrading existing DBs; `/init-team` auto-migrates v1 DBs
- **`archived=FALSE` filters**: all memory queries (recall, memory-search, skill reads) exclude archived memories; `tier` column visible in search results

### v0.13.3
- **Smarter `/release` skill**: auto-detects patch/minor/major from args or commit history, auto-generates changelog from git log instead of asking, handles push failures gracefully
- **MEM-001/MEM-002 design docs**: brainstorm, specs, and plans for memory system improvements

### v0.13.2
- **Upgrade review-commit sub-agents to Opus**: the 5 parallel specialist review agents (Logic, Security, Compliance, Quality, Simplification) now use Opus instead of Sonnet

### v0.13.1
- **`/recall` two-phase search**: structured sources (memory, specs, plans, commits) are searched first, then related keywords are extracted and used to expand the session history search — finds precursor sessions that predate the formal identifier

### v0.13.0
- **Opus by default** for ic5, qa, and ds agents — removes aspirational escalation clauses in favor of native Opus reasoning where it matters (complex implementation, release gating, statistical analysis)
- **Comprehensive polish pass** driven by 4-agent quorum review (Tech Lead, PM, QA, IC5):
  - Fix `LIMIT 1` memory loads in kickoff/orchestrate/brainstorm/wrap-ticket — agents were booting with almost no context from the append-only DB
  - Add `Write, Edit` tools to tech-lead, pm, qa — they were chartered to produce artifacts but couldn't write files
  - Fix heredoc `'MEMEOF'` quoting bug that prevented `$CONTENT` expansion in wrap-ticket and init-orchestration fallback paths
  - Add `PRAGMA busy_timeout=5000` to memory-store write template (per-connection setting, not persisted in DB)
  - Resolve `schema.sql` from plugin cache for marketplace-installed users (was using `git rev-parse --show-toplevel` which only works in the plugin's own repo)
  - Sync scaffold-project allowlist with project-init (add `sqlite3:*`, `curl:*`)
  - Standardize `PROOT` → `MROOT` variable naming across all skills and commands
  - Fix undefined `$AGENT_MEM_ROOT` variable in project-init
  - Add YAML frontmatter to all 6 original command files — without it they were invisible to Claude Code's discovery/suggestion system
- **README overhaul**: correct agent count, replace deprecated ollama with remote in embedding table, group 22-command flat table into 6 workflow-stage sections, rewrite "Starting a task" to lead with `/kickoff`, add download size warning, fix memory layout diagram
- **Marketplace presence**: benefit-led descriptions replacing FAANG jargon, add `memory`, `orchestration`, `persistent`, `workflow`, `sqlite` keywords
- **Document commands/ vs skills/ convention** in AGENTS.md

### v0.12.4
- **`/init-team`**: sandbox allowlist setup is now zero-intervention — automatically adds `github.com:22` and embedding host to `.claude/settings.json`, prompts user once for sandbox approval

### v0.12.3
- **`/memory-search`**: unified — absorbs `/mem-search` into a single command with 3-tier auto-detection: semantic (embeddings) → keyword (DB LIKE) → grep (.md files); adds error handling for curl failures, dynamic vec table dims, and non-agent directory filtering

### v0.12.2
- **Generic remote embeddings** — set `EMBEDDING_URL` and `EMBEDDING_API_KEY` env vars to use any OpenAI-compatible embedding provider (OpenAI, LLMGateway, ollama, etc.)
- Ollama is no longer a special case — just set `EMBEDDING_URL=http://localhost:11434/api/embed`
- `/init-team` resolves plugin install path correctly for target projects
- `/init-team` auto-adds embedding host to sandbox network allowlist
- **Chunked migration** — .md files split by `##` sections into focused chunks for better embedding quality
- Migration generates embeddings inline, handles legacy vec table schemas, truncates to ~1000 chars

### v0.12.1
- **`/memory-stats`** — anonymized memory usage metrics (counts, sizes, boot load per agent). Safe to share for data-driven decisions.

### v0.12.0
- **SQLite memory backend** — agents now store memory in a single SQLite DB per project with semantic search via sqlite-vec embeddings
- **`/memory-search`** — new semantic search command across all agent memories
- **`memory-store` / `memory-recall` skills** — agent skills for DB-backed memory operations
- **Tiered embedding strategy** — remote provider (best quality) > sqlite-lembed (air-gapped) > keyword fallback
- **Automatic migration** — `/init-team` migrates existing .md memory files to SQLite
- **`/init-team --refresh`** — re-probe embedding mode and re-run migration

### v0.11.1
- **`/scout-plugins`**: new skill — automated competitive intelligence scan of the Claude Code plugin ecosystem; searches for new/updated plugins within a configurable time window (default 1 week), evaluates each against dev-team's current capabilities, classifies as ADOPT/STEAL/WATCH/SKIP, and produces an enhancement proposal table

### v0.11.0
- **`/brainstorm`**: new skill — Socratic design refinement with structured questioning rounds (Core Intent → Scope & Constraints → Edge Cases → Alternatives) that forces requirement clarity before planning; saves synthesis to `.claude/plans/`; inspired by Superpowers
- **`/recall [topic]`**: new command — cross-project session search across `history.jsonl`, agent memory, git history, specs, plans, and backlog; groups results by session and outputs `claude --resume <id>` commands for instant context recovery; inspired by WorkCommand
- **`/memory-search [query]`**: now unified — absorbs `/mem-search`; auto-detects best mode: semantic (embeddings) → keyword (DB LIKE) → grep (.md files)
- **`/review-and-commit` overhaul**: now runs 5 parallel specialist sub-agents (Logic, Security, Compliance, Design, Simplification) instead of single-agent review; adds confidence scoring (0-100) that filters findings below 80 to reduce false positives; adds AGENTS.md/CLAUDE.md compliance checking as a dedicated review dimension; inspired by local-review
- **`/kickoff` enhancement**: adds a parallel codebase exploration agent alongside PM and Tech Lead — traces execution paths, maps architecture patterns, and documents dependencies before design decisions; inspired by feature-dev
- **TDD gates**: IC4 and IC5 agents now enforce mandatory RED-GREEN-REFACTOR cycle for new features and bug fixes — write failing test first, then implement, then refactor; skip only for config/docs or when user opts out; inspired by Superpowers
- **Micro-task decomposition**: Tech Lead now breaks implementation plans into 2-5 minute micro-tasks with exact file paths, specific changes, interface contracts, verification steps, and dependencies; inspired by Superpowers

### v0.10.2
- **`/orchestrate`**: add Change Discipline rules — atomic PRs, ~1k LOC soft cap / 2k hard cap, no file >1k lines, refactoring always separate, discovered work becomes new tickets, replan gate on material deviations
- **`/init-orchestration`**: bake Change Discipline into AGENTS.md template and seeded memory so all agents self-police from project setup

### v0.10.1
- **`/init-orchestration`**: seeds `.claude/memory/claude/memory.md` with baseline orchestrator rules during project setup — prevents known mistakes (e.g. main session implementing instead of delegating) from being repeated in new projects

### v0.10.0
- **`/orchestrate`**: new skill — full lifecycle issue orchestrator; fetches issue context (Linear or prompted), creates branch/worktree, spawns PM+Tech Lead for scoping, IC4/IC5 for implementation, QA for validation, enforces tech-lead review loops with deadloop detection, optionally creates PR; main Claude stays as observer/navigator throughout

### v0.9.10
- **`/init-orchestration`**: enable bubblewrap sandbox (`sandbox.enabled: true`, `autoAllowBashIfSandboxed: true`) + simplify permissions to `Bash(*)` with `bypassPermissions` — replaces 70-line command allowlist with OS-level isolation for zero-prompt fully autonomous agents

### v0.9.9
- **`/init-orchestration`**: now creates `CLAUDE.md` as `AGENTS.md` reference (migrates existing content); AGENTS.md template gains battle-tested workflow rules (spec compliance, project-local paths, version bumping, no over-planning); hook template adds spec-change detection example

### v0.9.8
- **`/generate-tests`**: new skill — generates unit/integration tests from behavioral specs; reads MUST/SHOULD/MUST NOT requirements, detects project test framework and conventions, writes one test per requirement tagged with source spec ID (`// Generated from SPEC-NNN`), runs tests and reports pass/fail baseline; closes the spec-to-test gap when used after `/generate-specs` or `/create-spec`

### v0.9.7
- **`/generate-specs`**: new skill — reverse-engineers behavioral specs from existing source code; groups public surface into 8–15 domain-level specs with MUST/SHOULD/MUST NOT language; marks all output `INFERRED` for human review; designed for legacy project onboarding
- **runbook**: adds Phase 0 (legacy baseline) referencing `/generate-specs`; Phase 1.3 now directs to `/generate-specs` when no specs exist; Quick Reference updated

### v0.9.6
- **`/kickoff`**: new skill — orchestrates full ticket intake + planning phase; parallel PM+Tech Lead kickoff, spec creation, implementation plan, and TaskCreate task graph from a single command
- **`/standup`**: new skill — status snapshot of active agent team work; reads TaskList + each agent's context.md, surfaces blockers and stale tasks
- **`/wrap-ticket`**: new skill — close-out workflow; verifies all tasks completed, captures learnings to project memory, updates plans index, removes worktree, prints Linear checklist
- **docs**: Linear-to-prod runbook with full agent team orchestration walkthrough (POC-123 example)

### v0.9.5
- **Agent autonomy**: fix `Task` → `TaskCreate, TaskList, TaskUpdate, TaskGet` on all coordinating agents (pm, tech-lead, ic5, qa); add Task tools + `SendMessage` to all 8 agents so they can coordinate and communicate without human intervention
- **Bash allow list**: expand init-orchestration permissions from 38 to 73 entries, covering shell builtins, text processing, and common dev tools; remove dangerous commands (rm, chmod, curl, wget, patch, source) to require human approval

### v0.9.4
- **Cost efficiency**: downgrade `ds`, `project-init` to Sonnet; add dynamic Opus escalation for `pm`, `ic5`, `qa`, `ds` with role-specific trigger conditions

### v0.9.3
- **`/review-and-commit` overhaul**: brutal honest review — no sugar-coating, explicit PII/data exposure scan, over-engineering and simplicity checks, commit gated on critical issues, "What I Would Do Instead" section, structured action items checklist, file:line citations required on every finding; review printed as text with optional save path arg

### v0.9.2
- **`/release` skill**: bumps version in all three required files (README.md, plugin.json, marketplace.json), commits, tags, and pushes — ensures they never get out of sync

### v0.9.1
- **`/reflect-specs` rename**: `/reflect-skills` renamed to `/reflect-specs` — the skill audits specs (and code alignment), not just skills; the old name was misleading

### v0.9.0
- **`/init-orchestration` skill**: bootstrap Agent Teams for any project — enables `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS`, adds a `TaskCompleted` quality-gate hook, and creates/updates `AGENTS.md` with team coordination rules; idempotent (safe to re-run)
- **`AGENTS.md`**: added to this plugin repo for contributors

### v0.8.1
- **`/review-and-commit` fix**: review output now written to `/tmp/review.md` instead of a project-local file, eliminating any risk of accidentally staging or committing it

### v0.8.0
- **`/reflect-specs` skill**: full-system health check — exhaustive code alignment across ALL specs (not sampled), cross-spec BLOCKER/WARNING/terminology-drift detection, skill/command self-consistency audit, interactive Phase 6 confirmation loop
- **Phase 5 independent code read**: reads every source file in full (not just keyword hits), summarizes each module's purpose, maps public surface (exported functions/types/routes/handlers) to specs, produces a module summary table with COVERED/UNCOVERED status — finds gaps that spec-driven grep would miss

### v0.7.0
- **Permissions sync**: `/init-team` now auto-syncs `.claude/settings.json` — merges missing permissions into existing projects without overwriting user additions
- **Expanded allowlist**: 41 entries covering agent bootstrap patterns (`_gc=*`, `MROOT=*`, `AGENT_*`), compound commands (`{:*`), shell control flow (`if`, `for`), and read-only `sed -n`
- **`/scaffold-project`** updated to emit the full allowlist for new projects

### v0.6.0
- **`/review-and-commit` skill**: review staged/modified files for bugs and spec drift, update out-of-date specs, append findings to `review.md`, then commit

### v0.5.0
- **`/check-specs` audit**: adds Phase 2 code alignment — samples 3–5 recently-updated specs, Greps source files, classifies each MUST requirement as MATCH / MISSING / DIFFERS, flags undocumented behavior (drift)
- **`/check-specs <ID>` validate**: fully rewritten — keyword extraction, language detection, source file discovery, per-requirement reasoning with `file:~line` evidence, drift detection, structured report with counts
- **`/create-spec`**: new Step 2.5 conflict scan — before creating, reads all existing specs and flags BLOCKER (direct contradictions) and WARNING (scope overlap); pauses for user decision
- **`/update-spec`**: new Step 3.5 cross-spec conflict check (same BLOCKER/WARNING logic, handles removed requirements); new Step 4.5 code alignment warning for added/modified requirements

### v0.4.0
- **Autonomy**: Added `.claude/settings.json` with `defaultMode: "acceptEdits"` and Bash allow list
- **Orchestration**: `pm`, `qa`, `tech-lead` can now spawn subagents via `Task` tool
- **project-init**: Added `Edit` tool for in-place file patching
- **Context efficiency**: All agents enforce memory file size budgets; ic5 applies `max_turns` limits
- **Scaffolding**: `/scaffold-project` now generates `.claude/settings.json` for new projects

### v0.3.0
- **Memory bootstrap**: `project-init` and `scaffold-project` now create `.claude/CLAUDE.md` and seed `.claude/memory/claude/memory.md` for project-local Claude Code memory

### v0.2.0
- **Backlog**: Added `/backlog` skill for `.claude/backlog/` management (add, close, list, init)

### v0.1.0
- Initial release: pm, tech-lead, ic5, ic4, devops, qa, ds, project-init agents
- Four-file per-agent memory system (cortex, memory, lessons, context) — worktree-aware
- Spec management: `/create-spec`, `/update-spec`, `/find-spec`, `/list-specs`, `/check-specs`
- `/scaffold-project` and `/init-team` commands

---

## Troubleshooting

See [Troubleshooting](docs/setup.md#troubleshooting) in the Setup Guide.

---

## License

MIT
