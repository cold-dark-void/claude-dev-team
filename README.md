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
| `/debug` | Phase-gated bug workflow — root cause → failing test → fix → verify; subcommands: `patch` (fast path), `arch` (design-first → /kickoff) |
| `/refactor` | Design-first code restructuring — design problem → characterization tests → implement → behavior-unchanged verify; `inline` subcommand for /debug handoff |
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
| `/handoff <session-uuid>` | Cold mode: reconstruct a past session from disk into a dense brief injected into the current session — survives `/compact`, multiday gaps, multi-fork transcripts |
| `/handoff` | Warm mode: capture the current live session into a five-section brief written to `.claude/handoff/` before the session ends |

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
`UNVERIFIED`, `CONTRADICTED`, `FABRICATED`). Shares an engine with `/review-and-commit`
via the `diff-mode` preset. Every verdict line must be backed by an investigator
`tool_use_id`; lines without evidence are struck and logged.

**Arguments:**

| Form | Scope |
|------|-------|
| `/council "<claim text>"` | Audit a single pasted claim |
| `/council --session [--last N]` | Audit a slice of the current session transcript |
| `/council --diff` | Audit staged diff (same engine path as `/review-and-commit`) |
| `/council --task-id <id>` | Bind verdict to a task; appends row to `.claude/council/index.json` |

`--plan <path>` and `--from-retro <anchor-id>` are deferred to COUNCIL-002 — both
fail loudly with a clear deferral message (engine exit 3). Do not substitute another
scope when either is supplied.

Engine protocol: `skills/council/SKILL.md`. Full contract: `specs/core/SPEC-013-adversarial-council-tribunal.md`.

---

## Changelog

### v0.36.0
- **feat: rename the code-review command `/review-commit` → `/review-and-commit` (D5) — finish the half-done rename across the dir, docs, and ~16 files** — the skill's invocation `name:` was already `review-and-commit` (so `/review-and-commit` already worked and `/review-commit` resolved to nothing), but the skill **directory**, its docs page, and dozens of path/slash/prose references still used the old `review-commit` name. This completes the canonical rename: `git mv skills/review-commit/ → skills/review-and-commit/` and `docs/commands/review-commit.md → review-and-commit.md` (both history-preserving), and updates every current reference — `skills/review-commit/` path strings, `/review-commit` slash-command mentions, and feature-name prose — across the specs (SPEC-002/010/013, TDD), the 6 council flavors, `commands/council.md`, `skills/council/SKILL.md`, `engine.sh` comments, and the README command table. Historical `## Changelog` entries are preserved verbatim (they record the name at their release). The council-engine locator is unaffected (it resolves `engine.sh` via `plugin-dir.sh`, not the renamed dir). Adversarially verified: a completeness refuter confirmed zero functional/dangling old-path survivors (only the historical changelog lines remain), the renames are tracked as renames, and both `/release` drift-gates stay green. Final part of the 4-part AUDIT-P1-4C split — the council subsystem consolidation is complete. (AUDIT-P1-4C-4).

### v0.35.2
- **fix: council docs — drop the phantom preset-file schema, document the implemented Phase 2.5, delete orphaned review-commit fixtures** — three doc-vs-reality cleanups. (1) `skills/council/SKILL.md` claimed each preset "lives at `skills/council/presets/<name>.md` with YAML frontmatter" — but no `presets/` directory exists; `engine.sh` resolves presets via a hardcoded `case` statement. The phantom file-claim is removed and `engine.sh`'s `case` is declared the authoritative source (the fields table is reframed as documenting what the resolution emits into the investigation plan, not a file format). (2) Added the **Phase 2.5 — Blind Cross-Review** section to the council SKILL's Engine Phases (it was implemented in the pipeline but undocumented there), mirroring SPEC-013:79–87 and `commands/council.md`'s actual behavior (anonymized per-reviewer ranking with self-exclusion + independent label shuffle, Borda consensus, Borda-ordered hand-off to Phases 4/5, bottom-quartile `WEAK_EVIDENCE`, `<3`-investigator bypass); also refreshed the Traceability table's drifted SPEC-013 line ranges for Phases 4–7 + Integration/Task-ID/Scope so the MUST→section map is monotonic and accurate. (3) Deleted the orphaned `skills/review-commit/fixtures/*` (no runner ever referenced them) and dropped the dead "Task 15's snapshot test" claim. Doc-only. Adversarially verified (an independent refuter caught — and I corrected — a renderer-attribution slip + the traceability cascade). Third of the 4-part AUDIT-P1-4C split. (AUDIT-P1-4C-3).

### v0.35.1
- **fix: council report-generation cluster — COMPLIANCE action-item label, Phase-4 skipped in diff-mode, placeholders-only report templates** — three engine.sh/template defects in council report rendering. (1) **COMPLIANCE label:** `engine.sh`'s action-item label was keyed only by severity (`critical→BLOCKER, warning→DESIGN, nitpick→NITPICK`), so a `category=compliance` finding never received the COMPLIANCE label that `review-and-commit`'s 4-label contract (`BLOCKER → COMPLIANCE → DESIGN → NITPICK`) requires — making that contract unsatisfiable. Labeling and sort order are now category-then-severity: a non-critical compliance finding gets the COMPLIANCE label and sorts to rank 1 (a critical one stays BLOCKER at rank 0 — critical always blocks first). (2) **Phase-4 in diff-mode:** the preflight investigation-plan emitted `4_prosecution_defense` unconditionally, contradicting the documented "Phase 4 skipped in diff-mode" behavior; the plan now gates that block on `output_shape` (`verdict[]` gets prosecutor/advocate; `finding[]`/diff-mode gets `{skipped: true, reason: "finding[]-shape preset"}`), and the council SKILL + command Phase-4 prose are reconciled to match. (3) **Placeholders-only templates:** `report-finding.md`/`report-verdict.md` carried static example/fallback content after their `{{…}}` placeholders (a fenced `Action Items: N BLOCKERs…` example + three `- [ ] BLOCKER/DESIGN/NITPICK … what is wrong …` lines, the `| Severity | Count | … | — |` placeholder tables, and duplicate `No findings/lines struck.` lines) that **leaked into every rendered report**; the static content is removed and the now-dead post-substitution strip-regexes in `engine.sh` are removed in sync (the `{{VAR}}` safety-net and the runtime `struck_md` fallback are kept). Adversarially verified: independent refuters rendered both report shapes (incl. zero-item and scrambled-input cases) and confirmed correct COMPLIANCE labeling/ordering, Phase-4 gating, and zero static leaks / leftover placeholders. Second of the 4-part AUDIT-P1-4C split. (AUDIT-P1-4C-2).

### v0.35.0
- **feat: merge the council Phase-4 prosecutor/advocate prompts into one role-parameterized `phase4-brief.md` and make the roles blind to the original claims** — the Prosecutor and Devil's Advocate prompts (`prompts/prosecutor.md`, `prompts/advocate.md`) were ~80% identical, and both declared/used `{{ORIGINAL_CLAIMS}}` in their bodies while `commands/council.md` deliberately never substituted it (SPEC-013's evidence-alone design) — so the literal `{{ORIGINAL_CLAIMS}}` placeholder leaked into the spawned subagent on every run (the same defect class as v0.34.0). The two are now one `skills/council/prompts/phase4-brief.md` parameterized by `{{ROLE}}` / `{{ROLE_BIAS}}` / `{{EVIDENCE_FIELD}}` (`evidence_against` for the Prosecutor, `evidence_for` for the Advocate — the judge-consumed field names, preserved byte-for-byte) plus `{{EVIDENCE_BUNDLES}}` / `{{FLAVOR_DELTA}}`. The merged body carries **no `{{ORIGINAL_CLAIMS}}`**: each role reconstructs the claim set from the `claim_id` carried inside the evidence bundles, never from a supplied claims list (the Judge in Phase 5 still receives the claims — that seam is unchanged). SPEC-013's Phase-4 MUSTs are clarified to state the claim-blindness invariant explicitly. The `/release` template-variable drift-gate now **covers** `phase4-brief.md` (moved out of the deferred set; it handles the dual-spawn by taking the union of the two `commands/council.md` substitution blocks). First of the 4-part AUDIT-P1-4C split (council bug-class + preset + the `/review-and-commit` rename follow). (AUDIT-P1-4C-1).

### v0.34.1
- **fix: merge the council engine's two duplicated JSON-repair routines into one shared function** — `skills/council/engine.sh` carried two near-identical backslash-repair blocks (`PYREPAIR` for the evidence file, `PYJUDGEFIX` for the judge output) whose repair cores were byte-identical except the loop variable and comments — the file even self-documented the duplication ("Apply the same backslash repair as evidence"). Both are now one shared `repair_json_file <file> <mode> <err_label> <exit_code>` bash function: a single backslash-repair core, with the markdown-fence-strip pre-step guarded to judge mode only, and the per-mode exit contract (5 evidence / 7 judge) emitted via `sys.exit` inside Python so it survives `set -euo pipefail` errexit. Pure internal refactor, **no behavior change** — a proof harness extracting the real shipped Python from the pre- and post-refactor `engine.sh` confirms byte-identical repaired output, identical exit codes, and identical stderr (incl. the evidence-only "(unescaped backslashes)" suffix and the judge-only 200-char debug line) across an unescaped-regex / valid-escape / mixed / fenced / unrepairable corpus. Net −19 LOC. The two larger P1-4B candidates evaporated under verification: `flavors/_shared.md` is runtime-infeasible (the engine injects each flavor's whole body as `{{FLAVOR_DELTA}}`; a base+delta compose would need new orchestrator logic and contradicts SPEC-013's self-contained-flavor MUST), and the `prosecutor`/`advocate` → `phase4-brief.md` merge is a judge-consumed-field contract change entangled with the Phase-4 blind-input contradiction — both deferred to AUDIT-P1-4C. (AUDIT-P1-4B).

### v0.34.0
- **feat: council contract home (SPEC-013) — fix the template-variable contract that leaked 3 placeholders into every council subagent** — the council prompt-variable contract was defined in 3 disagreeing places, and the runtime substituter (`commands/council.md`) named three variables absent from the prompt bodies — `{{RAW_INPUT}}`/`{{CLAIM}}`/`{{CLAIMS}}` where the bodies declare `{{INPUT_TEXT}}`/`{{CLAIM_TEXT}}`/`{{ORIGINAL_CLAIMS}}` — so those literal `{{…}}` placeholders shipped unsubstituted into the spawned claim-extractor / investigator / judge subagents on every run. SPEC-013 now normatively declares each prompt's own `## Variables` table the authoritative contract, with `commands/council.md` **and** `skills/council/SKILL.md`'s documented-variables table required to name exactly those variables (no dead substitutions, no unsubstituted leaks). council.md and the SKILL table are reconciled to the bodies (two dead substitutions — `{{SPEC_BUNDLE}}`, `{{TOOL_ALLOWLIST}}` — resolved body-authoritative and behavior-preserving; the missing `cross-reviewer` row added). New `skills/council/check-template-vars.sh` mechanizes the contract for both halves (council.md substitution blocks + the SKILL.md doc table, each vs the prompt's Variables table) and is wired into `/release` as a pre-commit drift-gate. blind-review's council reverse-validation display is aligned to the canonical 5-term verdict taxonomy (it was dropping `UNVERIFIED`/`FABRICATED`). The audit's broader "schema defined in 6+ places" premise was tested and largely held-already-consistent (the 6 homes agreed; 4 are runtime-operational or parsing code that cannot become cites) — so the real, shippable fix is the variable-contract correctness, not a decorative schema include. prosecutor/advocate's `{{ORIGINAL_CLAIMS}}` contract is entangled with the Phase-4 blind-input contradiction and is deferred (the gate logs the gap) to AUDIT-P1-4C. (AUDIT-P1-4A).

### v0.33.1
- **fix: single-source the shared spec-tooling procedures (SPEC-008) — reconcile 5 drifted classes** — the spec-tooling commands hand-rolled five overlapping procedures in divergent copies: spec discovery (7 ways), the MUST→code alignment pipeline (4×), conflict-scan (3×), language detection (4×), and the code-alignment grep-exclude list (5 drifted variants that silently changed what counts as "source"). SPEC-008 is now the single normative home for all five (Spec Discovery, Source Exclusions, Project-Language Markers, Code-Alignment Verdicts + the separate update-spec Code-Impact Warning, Spec Conflict Scan); consumers cite it and keep their scope-specific operational copy inline (no runtime resolution). The one byte-identical datum — the grep-exclude set — is single-sourced from `skills/spec-tooling/source-exclude.md` and included into the 4 alignment consumers (5 regions), drift-gated at `/release`. The canonical exclude set drops the `skills/`/`commands/` path-exclude (the `*.md` extension exclude already removes plugin prose, while real `skills/*.sh` implementation stays visible to alignment) — corrective in both directions. Fixes two discovery bugs: find-spec's hardcoded per-category globs (new categories were invisible) → category-agnostic glob, and list-specs' index-only read (orphan spec files were invisible) → orphan cross-check. Editorial consolidation; the exclude reconciliation is the one intended behavior change. (AUDIT-P1-5B).

### v0.33.0
- **feat: single-source the spec-file format contract (SPEC-008) — fresh `/generate-specs` output now passes `/check-specs`** — the spec format was defined 4× contradictorily, so every freshly generated spec failed `/check-specs` Phase 1 (it omitted `**Category**`, `**Created**`, `## Test`, `## Validation`, `## Version History`). SPEC-008 is now the single normative contract: the 9 required sections (sourced from one byte-identical `skills/spec-tooling/spec-skeleton.md` partial that `/generate-specs` and `/create-spec` include via `<!-- include -->` markers, drift-gated at `/release`), a two-axis status taxonomy (lifecycle `INFERRED → DRAFT → ACTIVE → APPROVED → DEPRECATED` as the spec's `**Status**:`; the `✅/❌/⚠️` legend demoted to report-only verify-status), canonical TDD-index columns `| ID | Title | Status | Coverage |`, and a 2-column Version-History row (the 3-column variant is retired). `/check-specs`, `/reflect-specs`, `/kickoff`, `/list-specs`, `/update-spec`, and `scaffold-project` now cite the contract instead of restating it; emitter-specific extras (SHOULD/Open-Questions/Cross-references, `---`) stay outside the shared region. New `skills/spec-tooling/check-format.sh` mechanizes the 9-section check (MC-6 bootstrap proof). Fixes two live corruptions: the `specs/TDD.md` stray 3rd version-row cell, and dead "Quick Status Table"/"Navigation by Category" references in 4 commands. (AUDIT-P1-5A; P1-5B — shared discovery/alignment/grep-exclude procedures — follows).

### v0.32.1
- **fix: push the `SendMessage` no-addressable-parent guidance into the emitted consumer AGENTS.md template** — `init-orchestration`'s generated AGENTS.md (both the new-file template and the append-only Team Coordination block) lacked the rule that spawned sub-agents have no addressable parent (no agent named `main`/`orchestrator`) and must return work as their final message. Consumer-spawned agents could DM a non-existent parent and lose their result; the guidance is now present, lifted verbatim from this repo's `AGENTS.md` for consistency. Declares in SPEC-005 that this repo's hand-tuned `AGENTS.md` and the emitted consumer template are intentionally **distinct** documents (shared by manual reconciliation, not byte-level single-sourcing) and that emitted consumer files MUST stay `<!-- include -->`-marker-free. Anchors the v0.32.0 managed-include drift-gate (`sync-includes.py check` at `/release`) as a SPEC-010 Release MUST — it was previously specced nowhere — scoped to managed-include regions only (not an AGENTS.md-vs-template cross-check). Doc-only; no engine/agent/runtime change. (AUDIT-P1-1B).

### v0.32.0
- **feat: single-source the agent memory protocol (managed-inline + drift-check)** — the ~700-line memory block that was hand-duplicated across all 7 behavioral agents is now generated from one canonical partial (`skills/agent-memory/protocol.md`) expanded inline between `<!-- include -->` markers; `skills/agent-memory/sync-includes.py` byte-checks the copies and `/release` blocks on drift. Agents stay self-contained (no runtime skill resolution — portability preserved), and the block is **upgraded**: the write path now uses `PRAGMA busy_timeout`, SQLITE_BUSY retry, `MEMORY_ID` capture, and **best-effort embedding via `embed-one.sh`** — so agent-written memories are embedded and surface in semantic `/memory-search` for the first time. The tiered read is corrected to `SELECT type, content`. Fixes 3 latent bugs: P0.1 the silent-no-op `memory-capture.sh` INSERT (sqlite3 CLI can't bind `?` from argv — was storing NULLs; same fix in the emitted `/init-orchestration` hook template), P0.5 `wrap-ticket` `INSERT OR REPLACE` appending a duplicate doc every wrap (now append-only), P0.11 the truncating `.md` fallback (`cat >`→`>>`). Reconciles the memory line-limit contract on SPEC-004 (the stray SPEC-009 "150-line" warn was wrong → 50). Adds the MC-4 spawn-`terse` MUST to SPEC-003/009. Removes the dead memory-load bash from the tool-less `council-judge`. (AUDIT-P1-1).

### v0.31.2
- **fix: extract `skills/memory-store/embed-one.sh`** — the write-time embedding logic (lembed + remote provider) is single-sourced into one best-effort `embed-one.sh <db> <memory_id> <text>` helper; `memory-store` Step 4 now delegates to it instead of inlining ~90 lines. Self-derives extension/model paths from the DB, always exits 0, and silently skips when extensions are absent or mode is `fallback`. Zero behavior change — Step 4 produces byte-identical `vec_*`/`embedding_meta` rows. Prerequisite for the AUDIT-P1-1 agent memory-write path. (AUDIT-P1-1C).

### v0.31.1
- **docs: single-source the project-root resolution contract (SPEC-002)** — declared the three authoritative root-resolution contexts (shared-root via `git rev-parse --git-common-dir`; working-tree-root via `--show-toplevel`; cwd-anchored single-root for project-bootstrap skills) with a MUST-NOT-mix-roots clause. Doc-only: no behavioral change. The real subdir-invocation hardening for `scaffold-project`/`init-orchestration` (anchor every `.claude/` op on one resolved root) is filed as `.claude/backlog/bootstrap-single-root-anchoring.md` — deferred after review showed a naive partial anchor would split the scaffold. (AUDIT-P1-2).

### v0.31.0
- **feat: plugin-dir locator consolidation** — new `skills/plugin-dir.sh` subprocess CLI resolves any plugin file via a single `sort -V` highest-version algorithm with a dev-checkout fast path; replaces ~15 hand-rolled locators across 11 command/skill files (drops the duplicated `PLUGIN_VER` grep, the hardcoded `cold-dark-void` slug, and two divergent glob-first-match resolvers). SPEC-002 gains the `plugin-dir.sh` CLI contract + caller bootstrap clause. `retro-gate/hint.sh` now self-locates `gate.sh`. (AUDIT-P1-3).

### v0.30.4
- **ci-watch ci-mode poll works again (`skills/ci-watch/poll.sh`)** — the poll queried `gh pr checks --json name,conclusion`, but `conclusion` has never been a valid `gh pr checks` JSON field, so every poll errored and the error-tolerant path swallowed it as an eternal `wait`: the watcher never reported green, never spawned a fixer, and only `poll_error_count` climbed. The poll now fetches `name,state,bucket` and classifies via `bucket`, gh's version-stable normalization — `fail`/`cancel` → failure, `pass`/`skipping` → green, `pending` → wait. Skipped checks no longer block green (previously another eternal-wait), `ERROR`/`ACTION_REQUIRED` states now correctly count as failures, and `last_failure.txt` carries each failing check's `state` for the fixer agent. Verified against gh 2.94.0 field validation plus a stub-gh harness (pass/fail/pending/skip/cancel/cap scenarios). SPEC-017 and the skill's decision matrix updated to match.

### v0.30.3
- **Natural-break chunking for monster-session handoffs (`skills/handoff/prepass.sh`)** — when a transcript is too large for one window and must be chunked, `prepare` now prefers to cut at a user-turn boundary (the start of a user message) once past a soft threshold, instead of an arbitrary token cutoff, so a hypothesis->test->correction arc stays within one chunk and the convergence through-line survives the map step. The hard token budget is still never exceeded (an oversized single message is the only thing that can exceed it, as before). Measured on a real session, turn-aligned chunk boundaries rose 40%->76%. Tunable via `HANDOFF_CHUNK_SOFT_RATIO` (default 0.8; 1.0 restores pure budget cutting).

### v0.30.2
- **Tool-Offload Discipline in the generated AGENTS.md (`/init-orchestration`)** — the prevention prong of session-handoff now ships where it reaches users: the `/init-orchestration` AGENTS.md template gains a Tool-Offload Discipline section, so new projects instruct both the main loop and all agents to offload bulk tool I/O (reads spanning 3+ files, > ~400-line reads, or > ~50-line/unbounded command output) to a subagent that returns findings + pointers, not raw dumps. MUST above the bar; below it the rule does not apply.

### v0.30.1
- **Handoff cache retention (`/handoff` cold cache)** — `skills/handoff/prepass.sh` now bounds `.claude/handoff/cache/` instead of letting it grow forever: after `finalize` writes a brief it keeps the newest `HANDOFF_CACHE_MAX_ENTRIES` cached briefs (default 50) by `created_at` and prunes the rest oldest-first, never evicting the entry just written, and sweeps orphan `*.tmp` files. Safe by construction — a cached brief is a derived memoization of its transcript, so an evicted entry is rebuilt on the next cache MISS (no recoverable context lost). Best-effort and silent under the cap; confined to the cache dir (never `memory.db`). Implements the SPEC-018 M8 eviction follow-up.

### v0.30.0
- **Session handoff (`/handoff`) — SPEC-018**: cold `/handoff <uuid>` reconstructs a past session from disk (fork-tree assembly, `toolUseResult` strip, size-adaptive spine + chunking for 90 MB+ multi-fork transcripts, 5 specialized extractors → a pointer-bearing brief, cached) — survives `/compact`. Warm `/handoff` captures the live session.
- **Shared `skills/transcript-parse/` module** (session-JSONL location, fork-tree assembly, parse primitives, freshness guard); `/retro` refactored onto it with zero scoring regression.
- **Deprecated** the personal `~/.claude/skills/handoff` skill in favour of the unified plugin command.

### v0.29.13
- **`/release` skill matches the real one-folded-commit convention** — the bundled skill assumed the work was already committed: it derived the version and changelog from `git log` since the last tag (empty when the change is still uncommitted, so it wrongly reported "nothing to release"), staged only the 3 version files, and committed a standalone `chore: release vX.Y.Z`. It now derives the changelog from the uncommitted working-tree changes (plus any commits since the tag), stages the changed source files alongside the version files, and folds everything into a single `fix:/feat: vX.Y.Z — <summary>` commit with a `Co-Authored-By: Claude <Model> (1M context)` trailer — no `chore: release` commit, no tag pointing at a version-bump-only commit that omits its own code.

### v0.29.12
- **Agents verify external behavior before building on it** — real-session insights showed agents repeatedly designing around unverified API params / SDK flags / model capabilities (e.g. `reasoning_effort`, vLLM flags) that the backend silently ignored, then shipping fixes that missed the real issue. `agents/ic4.md`, `agents/ic5.md`, and `agents/tech-lead.md` now carry a standing rule: empirically verify any external API parameter, library/SDK flag, model capability, or endpoint behavior (grep for proven usage, run a minimal probe, or cite docs for the exact version) before building or designing around it, and label any option that proves decorative/no-op instead of implying it works. IC4 also gains reproduce-then-root-cause-before-edit and an anti-rationalization row against spraying the same guard across many callsites (escalate to IC5 — there's one upstream fix). Tech Lead gains an honest-judgment rule: no verdict resting on a single convenient metric, no unverified "success" claims.
- **kickoff GATE-1 — verify API assumptions before the spec** — `/kickoff` gains a conditional Step 4b that runs before the spec is written. Tech Lead's Step 2 orientation now emits the external behaviors the ticket *assumes*; if any exist, a verification agent classifies each `HONORED / IGNORED / DECORATIVE / UNKNOWN` (codebase grep → minimal probe → cited docs). If a confirmed AC depends on a capability that isn't `HONORED`, kickoff pauses and surfaces it instead of baking the unverified assumption into the spec. No-op for pure-UI/refactor tickets — skips in one line.

### v0.29.11
- **Visible WAL fallback for memory.db** — sandboxed filesystems (bubblewrap tmpdirs, NFS, some CI containers) reject `PRAGMA journal_mode=WAL` and SQLite silently degrades to `journal_mode=delete`. The DB still works but concurrent agent writes serialize instead of running in parallel — invisible regression. `/init-orchestration` Step 7 now probes `PRAGMA journal_mode;` after schema apply and prints a clear stderr warning when WAL was rejected, telling the user what degraded and how to recover (re-run outside the sandbox / on a local filesystem). Schema comment in `schema.sql` documents the same fallback path.

### v0.29.10
- **Reconcile TaskList against Agent-spawn lifecycle** — `Agent` tool's `async_launched` is *not* a TaskList status; it lives on the spawn-result, not the task. A spawned agent's `TaskUpdate(completed)` runs in its own sandbox session and never reaches the orchestrator, so TaskList rows for async-spawned work stay `in_progress` forever and the TaskCompleted council hook never fires. Two complementary fixes: `skills/orchestrate/SKILL.md` Step 8 monitoring loop now states explicitly that the *orchestrator* must record `task_id ↔ agentId` at spawn time and call `TaskUpdate(completed)` itself on every Agent-completion notification; `skills/standup/SKILL.md` now reads the file-store at `.claude/tasks/*.json` (the source of truth) alongside `TaskList`, prefers the file-store on disagreement, and surfaces a new `🟡 LIKELY-DONE` category for `in_progress` tasks whose owner has no live activity but whose file-store shows completed — these need an orchestrator-side TaskUpdate to close the loop.

### v0.29.9
- **Orchestrator post-compaction discipline** — long `/orchestrate` sessions saw 28 "File has not been read yet" errors all originating from the main orchestrator (not sub-agents) clustered on post-compaction continuations: the harness wipes the per-tool read-tracker on summary-resume but the conversation summary still convinces the model it has read those files. Same compaction also lets the "you do NOT write code" rule decay — orchestrator drifts into doing IC work directly. Added explicit post-compaction discipline to `skills/orchestrate/SKILL.md` Step 8: the no-code rule survives compaction; the "File not read yet" error means compaction just happened, treat it as a directive to re-Read every file you intend to touch this turn, not a one-off retry.

### v0.29.8
- **Harden worktree cleanup against WSL2 EBUSY** — `worktree-lib.sh release` now (a) retries every git op 3× with 200ms backoff on `Device or resource busy` / `could not write config` / `update of config-file failed` errors, (b) actually deletes the feature branch (was missing — `release` only ran `worktree remove` before), (c) runs `worktree prune` to reap partial-failure admin entries, (d) sweeps any orphaned `[branch "feat/X"]` config stanza via `git config --remove-section`. Each step is a separate `git` call so the second never fires while the first is still releasing `.git/config`. Updated `orchestrate/SKILL.md` worktree-cleanup prose to point at the lib first and to forbid chained `worktree remove && branch -D` in by-hand cleanups (the chained form is the exact pattern that races on WSL2's 9p mmap-rename).

### v0.29.7
- **Stop spawned agents from hallucinating an addressable orchestrator** — child agents under `/orchestrate` and `/kickoff` repeatedly invented symbolic recipients (`main`, `orchestrator`, `tl-cdv162-plan`) and tried `SendMessage` with `to: "<that name>"`, which the runtime rejects (only opaque agent IDs are addressable). The agent then logged apologetic prose ("The orchestrator isn't running as an addressable agent named 'main'…") and dumped its report to final output anyway — wasted tokens with no functional benefit. Spawn templates in `skills/orchestrate/SKILL.md` and `skills/kickoff/SKILL.md` now explicitly tell agents: return your output as the final message, do NOT SendMessage to the orchestrator. AGENTS.md `Team Coordination` section gains the same rule for hand-edited spawns.

### v0.29.6
- **stop-review.sh: sync install template, fix stamp key** — the install heredoc in `/init-orchestration` still shipped the legacy blocking version (`exit 2`) while the plugin's own dogfood copy was already non-blocking — silent drift. Both are now the same non-blocking script. The stamp key is now `cwd + HEAD-sha` instead of `session_id`; `claude --resume` mints a fresh `session_id` per invocation, so the old guard re-fired on every resume even when no new dirty state existed. The new stamp re-fires only when HEAD moves (a commit lands). Stale stamps from prior HEAD shas are swept on each fire to keep `.claude/` tidy. On re-run, `/init-orchestration` overwrites legacy `exit 2` / `SESSION_ID` versions of the hook.

### v0.29.5
- **Worktree-safe hook paths** — `/init-orchestration` now writes hook commands as `bash "${CLAUDE_PROJECT_DIR}/.claude/hooks/<name>.sh"` instead of relative `.claude/hooks/<name>.sh`. Relative paths broke every Bash tool call from agents spawned inside worktrees (worktrees share `.git/` but not `.claude/`), producing "No such file or directory" on every PreToolUse / PostToolUse / Stop / TaskCompleted fire. The Step 1 upgrade check now also auto-rewrites stale relative paths in existing settings.json on re-run.

### v0.29.4
- **retro-gate: exclude context-continuation messages** — S1/S5 no longer fire on "This session is being continued from a previous conversation..." messages, whose session summaries often contain rejection-like words that are not user friction.
- **retro.md: fix `$N` substitution** — Claude Code substitutes `$1`–`$6` CLI args into skill text, clobbering awk field refs and bash function `$1`/`$2` params. Replaced all awk `$N` with `cut -fN`, singleton filter awk with a `while read` loop, and function params with `$*` / env-var pass-through.

### v0.29.3
- **retro `plugin` target** — `/retro` now classifies friction caused by the plugin itself (gate false positives, skill bugs, missing commands) as `target: "plugin"` and routes proposals to `/backlog add` instead of agent directives. Fixes the core issue where project-specific friction was being written as universal behavioral rules.

### v0.29.2
- **retro-gate false positive fixes** — S1 no longer fires on `<task-notification>` and `<command-name>` system messages; S5 no longer fires on slash commands or common approval words (`waive`, `ok`, `merge`, `lgtm`, etc.) that signal user satisfaction, not friction.
- **retro-subagent generalizability filter** — proposals must now apply across any project; domain-specific rules (e.g. about a particular DB schema) are demoted to observations instead of becoming universal behavioral directives.

### v0.29.1
- **SPEC-017 security + quality hotfix** — `sidecar.sh` and `poll.sh` lacked the `^[a-zA-Z0-9._-]+$` ticket ID validation that `task-store.sh` already enforced; a crafted ticket ID could construct arbitrary file paths including `rm -f` in `sidecar.sh cmd_delete`. Fixed with a `validate_ticket_id()` helper in both scripts. Additional: `poll.sh` EXIT trap for temp file cleanup, `emit_quiet` collapsed into `emit`, trust-boundary comment on `bash -c "$test_cmd"`. `dag-lib.sh` cycle-path reconstruction replaced with a one-line message (was ~25 lines for cosmetic stderr output), outer-loop guard added so cycle detection stops at first back-edge, `for child in $children` replaced with `read -ra` to prevent glob expansion. `task-store.sh` success messages redirected to stderr. `SKILL.md` frontmatter corrected from "5 min" to "7 min".

### v0.29.0
- **SPEC-017 — Autonomous CI Watch + Task DAG** — Two coupled autonomy features. *CI Watch*: after /orchestrate pushes work, a durable CronCreate loop monitors quality checks and auto-spawns a `dev-team:ic5` fixer agent on failure (retry cap: 3). Adapts to the project's setup: `ci` mode polls `gh pr checks`; `local-test` mode runs the detected test command (`npm test`, `make test`, `go test ./...`, `pytest`); `none` mode skips silently. New subprocess CLIs: `skills/ci-watch/sidecar.sh` (atomic sidecar state), `skills/ci-watch/detect-mode.sh` (mode probe), `skills/ci-watch/poll.sh` (deterministic `done|fail|cap|wait` decision). *Task DAG*: `task-store.sh` gains an optional 4th `depends_on` arg; new `skills/orchestrate/dag-lib.sh` provides `check-cycle` (3-color DFS), `ready-set`, and `status-of`. `/kickoff` Step 7 detects cycles before any `TaskCreate` and populates `depends_on` using compound keys. `/orchestrate` fans out all unblocked tasks in parallel via `dag-lib.sh ready-set`. `/standup` READY/WAITING computed from task store files (not prose). `/wrap-ticket` Step 6.5 cleans up the CI-watcher cron via `CronDelete`. New spec: `SPEC-017`.

### v0.28.1
- **Agent behavioral improvements from retro** — ic4 and ic5 gain rule to complete all edits on one file before moving to the next (prevents mid-task file interleaving); tech-lead gains rule to lead with a single recommendation rather than listing alternatives unprompted.

### v0.28.0
- **SPEC-013 Phase 2.5 — Blind Cross-Review** — Adds an anonymized peer-review round to the `/council` pipeline between Phase 2 (investigation) and Phase 4 (prosecution/defense), inspired by Karpathy's llm-council design. Each investigator cross-ranks peers' evidence bundles using anonymized labels (per-reviewer independent shuffle defeats position bias; self-exclusion prevents reviewing your own bundle). Rankings are aggregated via Borda count; bundles in the bottom quartile are flagged `WEAK_EVIDENCE`. Phase 4 and Phase 5 receive bundles in consensus rank order rather than submission order. Bypasses gracefully when fewer than 3 investigators participated or all reviewer responses are invalid. Engine finalize wired with `--cross-review-status/rankings/scores` flags; both report templates gain a `## Cross-Review` section. New `skills/council/prompts/cross-reviewer.md` prompt template.

### v0.27.0
- **Worktree isolation convention** — `skills/worktree-lib.sh`: new subprocess CLI for collision-safe worktree management. `ensure <slug>` creates `.worktrees/<slug>` with a PID-based lock, prompts on live-lock collision (abort/steal), and silently recovers stale locks. `release <slug>` removes the lock and worktree, refuses on uncommitted changes. Security hardened: slug sanitization (`[A-Za-z0-9_-]` only), PID lower-bound guard (rejects PID ≤1), `umask 077` on lock writes, bounded lock-file reads. `/orchestrate` Step 3 updated to call `worktree-lib.sh ensure`; `/wrap-ticket` Step 6 calls `release`, with new+legacy path detection and anchored ticket-ID greps (`-wF`). `/demo` gets an interactive existence prompt. `AGENTS.md` Worktree Protocol section added. `SPEC-016-worktree-isolation.md` written.

### v0.26.0
- **`/blind-review`** — New skill: multi-team blind peer review with automatic quorum analysis. Spawns N unconstrained + M lens-differentiated reviewer agents in parallel (security, contributor, spec, architecture, logic lenses available), clusters independent findings by semantic similarity into Tier 1 (cross-cohort ≥2 teams), Tier 2 (same-cohort ≥2 teams), and Tier 3 (single team) confidence buckets, and optionally forwards Tier 1 consensus findings to `/council` for reverse validation. Writes a ranked report to `.claude/reviews/`

### v0.25.3
- **Security + bug fixes from 6-team blind review** — `memory-search` and `recall` now escape query strings before SQLite LIKE interpolation; `stop-review.sh` sanitizes `SESSION_ID` before using it in a filesystem path; `task-store.sh` validates `task_id` against `[a-zA-Z0-9._-]+` in both `create` and `update-status`; `memory-distill.md` pre-validation step rewritten as numbered instructions (was referencing an unset `$VALIDATION_EXIT`); `init-team` gains v2→v3 schema migration branch; council generic preset corrected (`logic` → `jaded-senior`); SPEC-013 Phase 3 deferral formalised and status promoted to ACTIVE

### v0.25.2
- **`/orchestrate` task-store collision fix** — `TaskCreate` resets integers to 1 each new Claude process; switched to compound `<ISSUE-ID>-<task_id>` keys (e.g. `CDV-QF-FILTER-1.json`) to prevent cross-run upsert stomping; `task-completed.sh` hook gains `*-<id>.json` glob fallback for backward compatibility

### v0.25.1
- **`/reflect-specs` health-check fixes** — spec and code alignment corrections from full system audit: SPEC-013 council-judge MUST NOT clarified, TDD.md stale paths/status corrected, SPEC-004 whole-file chunk truncation documented, SPEC-007 terminology aligned, SPEC-002 now covers three previously-undocumented hooks (`bash-compress`, `memory-capture`, `stop-review`), `migrate-v2.sh` gains missing `PRAGMA busy_timeout`

### v0.25.0
- **`/refactor` skill** — standalone design-first refactor workflow: design problem gate (no file edits until problem is written), approach decision (auto-proceed when unambiguous, options + approval when scope is ambiguous), characterization tests when coverage is thin, behavioral-change detection halts the refactor, self-calibration checklist before completion; `inline` subcommand skips gates for handoffs from `/debug` or `/orchestrate`

### v0.24.0
- `/debug` — phase-gated bug workflow: root-cause → failing test → fix → verify; subcommands `patch` (fast path) and `arch` (design-first → /kickoff); enforces root-cause-before-edit gate, self-calibration checklist, holistic callsite scan, escalation ladder to /kickoff → /orchestrate

### v0.23.1
- **Fix hooks for Claude Code 2.1.116** — rewrote `bash-compress.sh` to inline compression instead of calling `bash wrapper.sh` (the wrapper re-triggered permission checks). Narrowed `memory-capture.sh` to Write/Edit only. Made `stop-review.sh` non-blocking (exit 0). Rewrote all hooks to use temp files instead of pipes (pipes poison the sandbox session)

### v0.23.0
- **Per-claim memory validation** — `/validate-memory` now uses LLM-based claim extraction + two-tier verification instead of regex+grep. Extracts checkable assertions from each memory, verifies file/symbol refs via bash (Tier A) and behavioral/architectural claims via read-only investigator subagent (Tier B). Composite scoring averages per-claim verdicts weighted by confidence. Includes path traversal guard, rename detection, file-scoped symbol lookup, and per-claim breakdown in reports

### v0.22.0
- **Bash output compression** — `/init-orchestration` now installs a PreToolUse hook (`bash-compress.sh`) that rewrites noisy test/build commands through a compression wrapper. Uses Claude Code's `updatedInput` to transparently pipe output through head/tail (threshold: 50 lines, shows first 20 + last 20). Covers npm/jest/vitest/pytest/go/cargo/mvn/gradle test, build commands, make, and tsc. Zero external deps — pure bash. Unblocked by `/council --session` audit that revealed PreToolUse hooks support `updatedInput` for command rewriting

### v0.21.0
- **Graduated TDD nudges** — `/tdd-gate` now uses soft enforcement: hint on 1st Write/Edit to untested file (allowed), warning on 2nd (allowed), hard block on 3rd+ (exit 2). Per-file counter tracked per session via `$TMPDIR`. Reduces wasted context from block+retry cycles while still enforcing TDD. Inspired by barkain/claude-code-workflow-orchestration

### v0.20.0
- **Blast radius analysis for reviews** — `/review-and-commit --impact` runs a lightweight impact analysis before spawning reviewers: extracts changed function/class names from diff hunks, greps for callers across the codebase (cap 20 files), and passes affected-caller context to all 5 specialists. Reviewers can now flag callers that may break due to signature changes or removed functions. Inspired by Code Review Graph (11.4K stars)

### v0.19.8
- **Lean orchestrator startup** — removed redundant Tech Lead and PM memory loading from `/orchestrate` Step 0. Both agents load their own memory when spawned in Step 4; pre-loading saved ~2-5K tokens of wasted orchestrator context

### v0.19.7
- **Anti-rationalization directives** — ic5, ic4, and qa agents now embed excuse/rebuttal tables that counter common step-skipping rationalizations (TDD shortcuts, spec non-compliance, premature approval). Inspired by addyosmani/agent-skills

### v0.19.6
- **Judge output JSON validation** — `engine.sh finalize` now validates and repairs judge output (strips markdown fences, fixes unescaped backslashes) with clear error messages on failure (exit 7). Found during v0.19.5 council self-review when LLM-generated judge JSON was malformed
- **Dead code comment** — documented that the `$?` guard after evidence repair is reached via `set -e` errexit, not the explicit check (council tribunal finding, confidence 85)

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
