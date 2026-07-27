# SPEC-005: Team Bootstrap

**Status**: ACTIVE
**Category**: core
**Created**: 2026-03-22

**Covers**: `commands/setup.md` (single entry `/setup` with subs `project` | `orchestration` | `team`), `agents/project-init.md` (invoked by `/setup team`), `commands/init-team.md` (Deprecation stub → `/setup team`, CDT-46-C4), `skills/memory-store/download-extensions.sh`, `skills/scaffold-project/SKILL.md` (protocol retained; skill-delegate from `/setup project`, CDT-46-C4), `skills/init-orchestration/SKILL.md` (protocol retained; skill-delegate from `/setup orchestration`, CDT-46-C4), `skills/demo/SKILL.md` (DEPRECATED stub — demo behavior removed at v1.0.0, CDT-46-C2; historical only)

## Overview

Everything needed to get the dev-team running in a new or existing project. Includes SQLite DB initialization, extension downloads, project scanning, cortex file generation for all 7 agents, project scaffolding (TDD structure for greenfield), and orchestration setup (sandbox, permissions, hooks for brownfield). All bootstrap operations are idempotent.

**User-facing entry:** `/setup <project|orchestration|team>` is the **sole** onboarding dispatcher (`commands/setup.md`). The three subs remain **behaviorally distinct** protocols (greenfield scaffold vs brownfield orchestration vs team memory bootstrap) under one Surface — not three primary slash commands. `/init-team` is a deprecation stub only; do not treat it as the primary entry.

## MUST

### `/setup` dispatcher entry (CDT-46-C4)

- MUST provide user-invocable `commands/setup.md` with subs: `project` | `orchestration` | `team`
- MUST map: `project` → former scaffold-project behavior; `orchestration` → former init-orchestration behavior; `team` → former init-team behavior (flag pass-through: `--refresh`, `--migrate-only`, `--no-extensions`)
- bare `/setup` or unknown sub MUST print usage and MUST NOT mutate project state
- MUST keep the three flows as separate protocols (no merged greenfield/brownfield/team logic) — dispatcher only
- `commands/init-team.md` MUST be a one-cycle Deprecation stub pointing to `/setup team` (removed at v1.1)

### Team Initialization (`/setup team`)
- MUST use `CREATE TABLE IF NOT EXISTS` and `INSERT OR IGNORE` for DB initialization (idempotent)
- MUST support flags: `--refresh` (re-check extensions + migration), `--migrate-only` (skip DB init + extensions), `--no-extensions` (air-gapped setups), `--skip-doctor` (doctor-gate override; see Doctor install gate)
- MUST add embedding host URLs to sandbox network allowlist when `EMBEDDING_URL` is configured
- MUST update `.gitignore` with `.claude/memory/` entries
- MUST invoke project-init agent after DB and extensions are ready
- MUST import a committed memory seed pack (SPEC-024) after DB/extensions/md-migrate and before project-init when `.claude/memory/seed/manifest.json` is present; a missing or bad pack MUST NOT block bootstrap; gitignore updates MUST use child globs + seed carve-out (never bare `.claude/memory/`)
- MUST set `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS: "1"` in settings.json env section (required for team agents)

### Extension Downloads
- MUST detect platform via `uname -s` and `uname -m` (support linux-x86_64, linux-aarch64, macos-x86_64, macos-aarch64)
- MUST skip downloads if files already exist (idempotent)
- MUST skip lembed on linux-aarch64 (no published binary)
- MUST NOT block on download failures — fall back to keyword-only mode
- MUST resolve embedding mode in priority order: remote (EMBEDDING_URL set) → lembed (extension + GGUF present) → fallback (keyword only)
- MUST migrate legacy "ollama" mode (v0.12.x) to "fallback" with hint to re-enable via EMBEDDING_URL
- MUST create vec_memories virtual tables only if vec0 extension loads successfully
- MUST store embedding config (mode, model, dimensions, url) in SQLite config table

### Project Init Agent
- MUST scan AGENTS.md first if it exists (contains critical project rules)
- MUST create all 7 agent memory directories at `.claude/memory/<agent>/`
- MUST write role-specific cortex.md files — each agent gets unique content tailored to their role (not copy-paste)
- MUST write real content based on project scan findings (no placeholders, no "TBD")
- MUST omit sections where information cannot be found (rather than guessing)
- MUST NOT write identical content to all agent cortex files
- MUST sync `.claude/settings.json` permissions using merge strategy (preserve existing user additions, never overwrite)
- MUST extract lessons from AGENTS.md and write to tech-lead and ic5 lessons files
- MUST use focused one-fact-per-INSERT approach in SQLite mode

### Project Scaffolding (greenfield)
- MUST create directory structure: `.claude/plans/`, `.claude/context/`, `.claude/memory/claude/`, `specs/`
- MUST create `.claude/settings.json` with `defaultMode: "acceptEdits"` and comprehensive Bash allowlist
- MUST seed TDD.md with 3 example spec entries in the index table marked as EXAMPLE status (to be replaced by real specs)
- MUST NOT overwrite existing AGENTS.md or CLAUDE.md without asking user first
- MUST create .gitkeep files in empty directories

### Orchestration Setup (brownfield — `/setup orchestration`)
- MUST be idempotent (safe to re-run, merge not overwrite) unless an explicit force-overwrite path is invoked
- MUST auto-detect network domains from package manifests (package.json, go.mod, requirements.txt, Cargo.toml, Gemfile) and git config
- MUST add TaskCompleted hook with `bash "${CLAUDE_PROJECT_DIR}/.claude/hooks/task-completed.sh"`
- MUST set orchestration `permissions.defaultMode` and allow list to the **SPEC-002 winning least-privilege cell** — shipped winner **(D)** `auto` + **matrix allow set** (`Bash(*)`, `Read`, `Write`, `Edit`, `Glob`, `Grep`, `Agent`, `Task`) (matrix evidence: `docs/runbooks/permission-posture-matrix.md` CDT-75; contingency: may retain `bypassPermissions` + matrix allow only if non-bypass cells fail AC1) and MUST enable sandbox + `autoAllowBashIfSandboxed` when the winning cell requires them. Brownfield merge MUST ensure **all** matrix allow entries are present (not only `Bash(*)`)
- MUST make task-completed.sh executable (chmod +x)
- MUST seed orchestrator memory with anti-pattern learnings
- MUST merge existing settings.json (preserve existing allow entries, merge domains)

### Hook template single SoT (CDT-54 / CDT-46-C8)
- **Template SoT.** Canonical hook **bodies** MUST live only in `skills/init-orchestration` templates (fenced blocks in `SKILL.md` and/or package-path `skills/init-orchestration/hooks/*.sh` if extracted). Live project files under `.claude/hooks/*.sh` MUST be **emitted** by `/setup orchestration` (and any equivalent emit path) from those templates — never authored or maintained as a second copy in the plugin package.
- **Generated + gitignored.** After CDT-54 hygiene, live `.claude/hooks/*` on the consumer (and on this repo when dogfooding) MUST be generated install-time artifacts and MUST NOT be tracked as package product. Process state under `.claude/` (hooks, backlog, plans, epics, …) is never upstream; seed carve-out only (SPEC-024 / SPEC-002).
- **Dual-copy gate retired.** The historical dual-copy integrity check (`check-hook-templates.sh` requiring byte-identity between tracked live hooks and templates) is **retired or reduced** to template-internal checks that do **not** require tracked live files under `.claude/hooks/`. Release / doctor MUST NOT FAIL solely because package-tracked live hooks are absent (see SPEC-010 Step 4.7, SPEC-022).
- **Regenerate after clone.** Contributors regenerating hooks MUST re-run `/setup orchestration` (or the scripted emit path it owns); editing live hooks without updating templates is a defect.

### Doctor install gate (CDT-51 / CDT-46-C5 / CDT-67)
- `/setup team` MUST invoke `dev-team:doctor` with `--gate=team` before mutation;
  `/setup orchestration` MUST invoke with `--gate=orchestration`. Exit ≤1 continues;
  exit 2 blocks. Self-remediating FAILs (fix-it exact match to the active sub per
  SPEC-022 M6c) do not block. Override `--skip-doctor` unchanged (WARNING then proceed).
- Override flag (e.g. `--skip-doctor` / equivalent) MUST print an explicit warning that the gate was skipped, then proceed; silent skip is forbidden
- `/setup project` MUST soft-advise only (recommend running doctor; MUST NOT block scaffold on doctor FAIL)
- Marketplace install path MUST NOT hard-gate on doctor (no gate at marketplace install time)
- Doctor itself remains non-bootstrap (SPEC-022) — the gate **calls** doctor; setup still owns creation

### Force-overwrite disclosure (CDT-51 / CDT-46-C5)
- When a re-run **force-overwrites** an existing managed file (settings, hooks, or other setup-owned artifacts), the path MUST print **old** summary, **new** summary, and a **restore key** (backup path or recovery handle) before replacing content
- Forced + silent overwrite is a FAIL (no silent clobber)

### Emitted AGENTS.md Template (distinctness contract)
- This repo's hand-tuned `AGENTS.md` and the AGENTS.md template emitted by `init-orchestration` (Step 5) are intentionally DISTINCT documents. They share rule *bodies* by convention (manual reconciliation), NOT by byte-level single-sourcing. No managed-include relationship exists or is required between them.
- MUST NOT introduce a `<!-- include: -->` managed-include relationship between this repo's `AGENTS.md` and the emitted consumer template, nor drift-check one against the other. (The `sync-includes.py` managed-include engine, SPEC-010, covers the agent-memory protocol only — not AGENTS.md.)
- The emitted consumer AGENTS.md (both the new-file template and the append-only "Team Coordination section only" block) MUST be marker-free: no `<!-- include: -->` / `<!-- /include -->` directives may appear in any file written into a consumer project. Managed-include markers are a dev-repo-only single-sourcing device and MUST NOT leak into generated consumer files.
- When a shared rule body is corrected in one document, the maintainer MUST reconcile the other by hand (e.g. the `SendMessage` no-addressable-parent guidance applies to consumer-spawned agents and so MUST appear in the emitted template's Team Coordination section, not only in this repo's AGENTS.md).

### Demo (historical / OBSOLETE — not live bootstrap)
> **OBSOLETE at v1.0.0 (CDT-46-C2):** the `/demo` skill was removed in the v1.0 surface-cleanup pass (`skills/demo/SKILL.md` is now a deprecation stub). The bullets below are **historical record only** — they do **not** describe live bootstrap behavior and MUST NOT be treated as current product requirements. Live bootstrap is `/setup` only. Replacement workflow: `/setup` + `/kickoff` on a scratch repo, or `/orchestrate` directly.

- ~~MUST verify preflight checks (memory.db or memory.md exists, AGENTS.md exists)~~ (historical)
- ~~MUST create temporary worktree with throwaway branch (`demo/dev-team-<timestamp>`)~~ (historical)
- ~~MUST scaffold minimal but realistic Go project with passing tests~~ (historical)
- ~~MUST pause at each decision gate so user sees the workflow~~ (historical)
- ~~MUST provide teardown prompt (clean up or keep for exploration)~~ (historical)
- ~~MUST clean up gracefully via the worktree-teardown discipline in SPEC-016 — `git worktree remove` then `git branch -D` as SEPARATE git calls (never chained `&&`; the WSL2 `.git/config` device-or-resource-busy hazard); prefer `skills/worktree-lib.sh release` where available~~ (historical)

## SHOULD

- SHOULD report summary at end of `/setup team` (init status, file status, permission status)
- SHOULD ask user which additional domains to allowlist beyond auto-detected ones
- SHOULD validate settings.json is valid JSON before writing
- ~~SHOULD print teaching commentary at key decision gates in demo mode~~ (historical / OBSOLETE — demo removed)

## Test

- Verify `/setup team` is idempotent (run twice, no errors, no duplicates)
- Verify extension downloads skip existing files
- Verify project-init creates 7 distinct cortex files with role-specific content
- Verify `/setup project` (scaffold-project) creates directory structure without overwriting existing files
- Verify `/setup orchestration` merges into existing settings.json without data loss
- ~~Verify demo creates and cleans up worktree~~ (historical / OBSOLETE — demo removed)
- Verify the emitted AGENTS.md template (both blocks) contains NO `<!-- include: -->` markers and that its Team Coordination section carries the `SendMessage` no-addressable-parent guidance: `! grep -q '<!-- include:' skills/init-orchestration/SKILL.md` within the two template fences, and the SendMessage peer-to-peer line is present in both

## Validation

- [ ] `sqlite3 .claude/memory/memory.db "SELECT COUNT(*) FROM memories"` returns > 0 after `/setup team`
- [ ] All 7 directories exist under `.claude/memory/`
- [ ] Cortex files differ across agents (diff any two)
- [ ] settings.json is valid JSON after `/setup orchestration` merge
- [ ] ~~Demo worktree removed after teardown~~ (historical / OBSOLETE)

## Open Questions

- [x] ~~Should scaffold-project and init-orchestration be merged?~~ **Resolved: No** — greenfield scaffold vs brownfield orchestration remain distinct `/setup` subs (dispatcher only; separate protocols).
- [x] ~~Is the demo's Go project assumption too restrictive for non-Go users?~~ **Resolved: N/A** — demo removed at v1.0.0 (CDT-46-C2); historical only.
- [x] ~~Should init-team auto-run init-orchestration, or keep them as separate steps?~~ **Resolved: separate** — `/setup team` and `/setup orchestration` stay independent subs under the single `/setup` entry.

## Version History

| Date | Change |
|------|--------|
| 2026-03-22 | Initial spec generated by /generate-specs |
| 2026-03-23 | Resolved scaffold/orchestration merge question. Moved AGENT_TEAMS env var here from SPEC-002. Clarified TDD.md seeding as index entries not full specs. |
| 2026-06-13 | AUDIT-P1-1B (D4): declared this repo's AGENTS.md and the emitted consumer template intentionally DISTINCT (no managed-include single-sourcing between them; emitted files MUST stay marker-free). Pushed the `SendMessage` no-addressable-parent guidance into the emitted template's Team Coordination section (both blocks) — consumers previously lacked it, risking spawned agents DMing a non-existent parent. |
| 2026-06-14 | AUDIT-P0.12: TaskCompleted-hook registration command changed to the worktree-safe `bash "${CLAUDE_PROJECT_DIR}/.claude/hooks/task-completed.sh"` form, matching the init-orchestration safe emitter (relative path resolved from agent cwd and failed inside worktrees). |
| 2026-06-15 | Editorial hygiene (AUDIT-P3.5b): reworded the Demo cleanup MUST to defer to SPEC-016's safe worktree-teardown (separate `git worktree remove` / `git branch -D` calls, never chained `&&`; prefer `worktree-lib.sh release`); added SPEC-016 cross-reference. No behavioral change. |
| 2026-07-21 | CDT-46-C2: `/demo` removed in the v1.0 surface-cleanup pass (`skills/demo/SKILL.md` → deprecation stub). Marked the Demo MUST/SHOULD/Test/Validation items OBSOLETE-at-v1.0.0 (retained one cycle as historical record, not deleted); annotated the demo Covers entry as a DEPRECATED stub. Bootstrap requirements (init-team, scaffold, init-orchestration) unchanged. |
| 2026-07-22 | CDT-46-C4: user entry unified under `/setup <project\|orchestration\|team>` (`commands/setup.md`). Covers retargeted; `commands/init-team.md` → Deprecation stub. Scaffold/init-orch/team behaviors remain distinct protocols under the dispatcher. |
| 2026-07-22 | CDT-51 / CDT-46-C5: posture + doctor-gate — orchestration defaultMode follows SPEC-002 matrix winner; hard-gate doctor on `/setup team` + `/setup orchestration` (exit ≤1 OK; FAIL blocks; override warns); soft-advise on `/setup project`; marketplace no gate; force-overwrite old/new/restore disclosure. |
| 2026-07-22 | CDT-51 AC2: orchestration ship default named as matrix winner **(C)** `dontAsk` + `Bash(*)` + sandbox. |
| 2026-07-22 | CDT-75: ship winner flipped to **(D)** `auto` + matrix allow + sandbox (epic C5 wording). |
| 2026-07-22 | CDT-51 TL P0/P1: orchestration allow = full matrix set; project-init Step 1b is team-bootstrap (acceptEdits seed only when mode missing AND no orch markers) — never clobber managed orch defaultMode. |
| 2026-07-22 | CDT-52 / CDT-46-C6: amend-then-promote — Overview/Covers name sole entry `/setup` (subs project\|orchestration\|team; `/init-team` stub only); demo kept OBSOLETE/historical (not live bootstrap); drop W5/full-rewrite OOS language that blocked promote honesty; retain C5 doctor-gate + SPEC-002 posture MUSTs; Status INFERRED→ACTIVE. Evidence: Linear CDT-52. |
| 2026-07-22 | CDT-54 / CDT-46-C8: hook template single SoT — `/setup orchestration` emits live hooks from init-orch templates; live `.claude/hooks` generated+gitignored (not package product); dual-copy `check-hook-templates` gate retired/reduced; regenerate via `/setup orchestration`. |
| 2026-07-22 | CDT-67: doctor gate passes `--gate=<sub>` (`team` / `orchestration`); M6c self-remediation (exact fix-it match) does not block. |

## Cross-references

- SPEC-002: Plugin Infrastructure — settings.json structure and hook registration
- SPEC-003: Agent Role System — 7 agents that project-init bootstraps
- SPEC-004: Memory Storage — SQLite DB schema that init-team creates
- SPEC-006: Memory Retrieval — extensions downloaded here enable semantic search
- SPEC-016: Worktree Isolation — owns the safe worktree-teardown discipline used by the demo cleanup step (`worktree-lib.sh`, separate-call removal)
