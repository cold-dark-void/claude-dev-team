# SPEC-005: Team Bootstrap

**Status**: ACTIVE
**Category**: core
**Created**: 2026-03-22

<!-- drift-ok: skill-ref -->
**Covers**: `commands/setup.md` (single entry `/setup` with subs `project` | `orchestration` | `team` | `models`), `agents/project-init.md` (invoked by `/setup team`), `commands/init-team.md` (Deprecation stub → `/setup team`, CDT-46-C4), `skills/memory-store/download-extensions.sh`, `skills/memory-store/test-setup-team-fences.sh` (fence-exec suite for the `/setup team` fences, WP 1-13), `skills/scaffold-project/SKILL.md` (protocol retained; skill-delegate from `/setup project`, CDT-46-C4), `skills/init-orchestration/SKILL.md` (protocol retained; skill-delegate from `/setup orchestration`, CDT-46-C4; Step 4h known-legacy-orphan sweep + Step 9 summary, CDT-76), `skills/init-orchestration/sweep-legacy-orphans.sh`, `skills/init-orchestration/test-sweep-legacy-orphans.sh`, `skills/demo/SKILL.md` (DEPRECATED stub — demo behavior removed at v1.0.0, CDT-46-C2; historical only), `skills/model-map/write-model.sh` (skill-delegate from `/setup models`, CDT-228)

## Overview

Everything needed to get the dev-team running in a new or existing project. Includes SQLite DB initialization, extension downloads, project scanning, cortex file generation for all 7 agents, project scaffolding (TDD structure for greenfield), and orchestration setup (sandbox, permissions, hooks for brownfield). All bootstrap operations are idempotent.

**User-facing entry:** `/setup <project|orchestration|team|models>` is the **sole** onboarding dispatcher (`commands/setup.md`). The three onboarding subs remain **behaviorally distinct** protocols (greenfield scaffold vs brownfield orchestration vs team memory bootstrap) under one Surface — not three primary slash commands. `models` is a known non-bootstrap sub (local Model map; SPEC-037). `/init-team` is a deprecation stub only; do not treat it as the primary entry.

## MUST

### `/setup` dispatcher entry (CDT-46-C4)

- MUST provide user-invocable `commands/setup.md` with subs: `project` | `orchestration` | `team` | `models`
- MUST map: `project` → former scaffold-project behavior; `orchestration` → former init-orchestration behavior; `team` → former init-team behavior (flag pass-through: `--refresh`, `--migrate-only`, `--no-extensions`); `models` → `skills/model-map/write-model.sh` (bare = list; `set` / `unset` pass through; SPEC-037 M20)
- bare `/setup` or unknown sub MUST print usage and MUST NOT mutate project state; `models` is a known sub
- MUST keep the three onboarding flows as separate protocols (no merged greenfield/brownfield/team logic) — dispatcher only
- `/setup models` MUST NOT hard-gate on doctor
- `commands/init-team.md` MUST be a one-cycle Deprecation stub pointing to `/setup team` (removed at v1.1)

### Team Initialization (`/setup team`)
- MUST use `CREATE TABLE IF NOT EXISTS` and `INSERT OR IGNORE` for DB initialization (idempotent)
- MUST support flags: `--refresh` (re-check extensions + migration), `--migrate-only` (skip DB init + extensions), `--no-extensions` (air-gapped setups), `--skip-doctor` (doctor-gate override; see Doctor install gate)
- MUST add embedding host URLs to sandbox network allowlist when `EMBEDDING_URL` is configured
- MUST update `.gitignore` with `.claude/memory/` entries
- MUST invoke project-init agent after DB and extensions are ready
- MUST import a committed memory seed pack (SPEC-024) after DB/extensions/md-migrate and before project-init when `.claude/memory/seed/manifest.json` is present; a missing or bad pack MUST NOT block bootstrap; gitignore updates MUST use child globs + seed carve-out (never bare `.claude/memory/`)
- MUST set `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS: "1"` in settings.json env section (required for team agents)
- MUST resolve each memory-store script that a `/setup team` step runs (`schema.sql` in Step 2, `migrate.sh` in Step 2.5, `download-extensions.sh` in Step 3, `migrate-md.sh` in Step 4) with `plugin-dir.sh dir skills/memory-store/<file>` inside the fence that runs it, so `$PLUGIN_DIR` is `<plugin>/skills/memory-store`. A fence MUST NOT set `PLUGIN_DIR` to the plugin root. When the script is not found, the step MUST print a warning on stderr and skip the script; it MUST NOT fail the bootstrap (WP 1-13, CDT-261)
- MUST treat every bash fence of a `/setup` sub as its own shell: a variable set in one fence is unset in the next. A fence MUST set every variable it reads. Step 5 (`.gitignore` fallback) runs every time, guarded by `grep -qF` per entry, with no flag from Step 3. Step 7 reads the `seed-import:` line that Step 5.5 printed. Step 5b is one fence: it sets `SETTINGS` and `HOSTS_TO_ADD`, runs `mkdir -p "$MROOT/.claude"` before it writes `settings.json`, and holds no `lint-ok: C1` waiver (WP 1-13, rv-p0-09)
- MUST ask for exactly one approval on the `team` path before the `settings.json` merge (Step 5b and project-init Step 1b). The `team` path writes no hook script, so the ask MUST NOT name `bash-compress.sh` or its `permissionDecision:"allow"`; `/setup orchestration` owns that approval (WP 1-13, rv-p0-09)

### Extension Downloads
- MUST detect platform via `uname -s` and `uname -m` (support linux-x86_64, linux-aarch64, macos-x86_64, macos-aarch64)
- MUST skip the download only when the destination file already exists AND verifies against its pinned SHA-256 (idempotent); a present file that mismatches its pin, has no pinned hash, or cannot be hashed (no `sha256sum`/`shasum`) MUST be deleted and re-downloaded — a present-but-unverified artifact is never used (fail closed, CDT-173)
- MUST pin the SHA-256 of both the downloaded artifact (extension `.tar.gz`, verified pre-extraction; model `.gguf`) and the extracted extension member (`.so`/`.dylib`), and MUST verify the extracted member against its pin before moving it into place
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

### Known-legacy-orphan sweep (CDT-76)

- `/setup orchestration` MUST maintain an **explicit finite** known-legacy-orphan
  list of basenames under `.claude/hooks/`. v1 list MUST be exactly:
  `bash-compress-wrapper.sh`. Adding names is a deliberate product change (spec +
  list update together); free-form / glob / "delete anything unused" GC is forbidden.
- After managed hook bodies are emitted in Step 4 (including `bash-compress.sh`),
  the flow MUST run the orphan sweep for every name on that list. Greenfield
  (file absent) MUST be a silent no-op for that name.
- A listed file is **removable** only when **all** hold:
  1. path exists at `$PROJ/.claude/hooks/<name>` (project root used for setup;
     same root as other Step-4 emits — typically show-toplevel / cwd project),
  2. no `hooks.*.hooks[].command` (or equivalent command string under the hooks
     tree) in `.claude/settings.json` contains the basename as a path segment /
     referenced script name,
  3. no other file matching `.claude/hooks/*.sh` (excluding the candidate itself)
     contains a reference to that basename.
- If the file exists but is referenced by settings and/or another hook: MUST NOT
  remove it; MUST print a WARN naming the orphan path and each referencer
  (settings key/path and/or hook file path).
- When removing: MUST (1) copy to
  `.claude/hooks/<name>.bak-force-<ts>` where `<ts>` is UTC
  `%Y%m%dT%H%M%SZ` or epoch fallback (same pattern as stop-review force path);
  (2) print FORCE-OVERWRITE disclosure with stable labels `key:`, `old:`,
  `new:`, `restore:` **before** delete (via `disclose-force-overwrite.sh` or
  identical labels); (3) then delete the live file. Forced + silent delete is FAIL.
  Suggested disclosure values:
  - `key:`   `.claude/hooks/<name>`
  - `old:`   `legacy orphan present (known-legacy list)`
  - `new:`   `removed (no longer managed; inline successor owns behavior)`
  - `restore:` the `.bak-force-<ts>` path
- Re-run when the file is already absent MUST be a no-op (no disclose, no bak).
- Step 9 summary MUST report each listed name's action: removed (+ restore path)
  or left (still referenced — with reason).
- MUST NOT alter `bash-compress.sh` template/behavior; MUST NOT delete unlisted
  files; MUST NOT add doctor checks for this sweep (doctor OOS for CDT-76).

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
- SHOULD implement the known-legacy-orphan sweep (CDT-76) as a subprocess CLI helper under `skills/init-orchestration/` (never sourced), parallel to `normalize-hook-paths.sh` / `disclose-force-overwrite.sh`
- ~~SHOULD print teaching commentary at key decision gates in demo mode~~ (historical / OBSOLETE — demo removed)

## Test

- Verify `/setup team` is idempotent (run twice, no errors, no duplicates)
- Verify extension downloads skip an existing file only when it matches its pinned SHA-256; a tampered/corrupt present `vec0.so` / `lembed0.so` / `.gguf` is deleted and re-downloaded, and when re-download is impossible the run still lands `embedding_mode=fallback` with exit 0
- Verify project-init creates 7 distinct cortex files with role-specific content
- Verify `/setup project` (scaffold-project) creates directory structure without overwriting existing files
- Verify `/setup orchestration` merges into existing settings.json without data loss
- ~~Verify demo creates and cleans up worktree~~ (historical / OBSOLETE — demo removed)
- Verify the emitted AGENTS.md template (both blocks) contains NO `<!-- include: -->` markers and that its Team Coordination section carries the `SendMessage` no-addressable-parent guidance: `! grep -q '<!-- include:' skills/init-orchestration/SKILL.md` within the two template fences, and the SendMessage peer-to-peer line is present in both
- Test: known-legacy-orphan present + unreferenced → bak-force + FORCE-OVERWRITE labels + file gone
- Test: known-legacy-orphan absent → no-op exit
- Test: settings references basename → kept + WARN
- Test: sibling hook references basename → kept + WARN
- Test: second run after remove → no-op

## Validation

- [ ] `sqlite3 .claude/memory/memory.db "SELECT COUNT(*) FROM memories"` returns > 0 after `/setup team`
- [ ] All 7 directories exist under `.claude/memory/`
- [ ] Cortex files differ across agents (diff any two)
- [ ] settings.json is valid JSON after `/setup orchestration` merge
- [ ] `bash skills/init-orchestration/test-sweep-legacy-orphans.sh` exits 0
- [ ] ~~Demo worktree removed after teardown~~ (historical / OBSOLETE)

## Open Questions

- [x] ~~Should scaffold-project and init-orchestration be merged?~~ **Resolved: No** — greenfield scaffold vs brownfield orchestration remain distinct `/setup` subs (dispatcher only; separate protocols).
- [x] ~~Is the demo's Go project assumption too restrictive for non-Go users?~~ **Resolved: N/A** — demo removed at v1.0.0 (CDT-46-C2); historical only.
- [x] ~~Should init-team auto-run init-orchestration, or keep them as separate steps?~~ **Resolved: separate** — `/setup team` and `/setup orchestration` stay independent subs under the single `/setup` entry.

## Acceptance criteria

### wp-1-13-setup-team-lembed

- **A.** Steps 2, 2.5, 3 and 4 of the `/setup team` sub of `commands/setup.md`, run as extracted in a fresh shell in a temp project with a fake plugin root (`CLAUDE_PLUGIN_ROOT`), find their scripts under `skills/memory-store/`. Step 2 applies `schema.sql` and creates `memory.db` with a `schema_version`. Steps 2.5, 3 and 4 call `migrate.sh`, `download-extensions.sh` and `migrate-md.sh` with the project root as their argument. Stderr holds no missing-file error. No fence sets `PLUGIN_DIR` to the plugin root, and every `$PLUGIN_DIR/<file>` literal in the team fences names a file under `skills/memory-store/` in the repo. Run on `commands/setup.md` at the parent commit, the same suite fails.
  Verify: bash skills/memory-store/test-setup-team-fences.sh
- **B.** With `migrate.sh` absent from the plugin, the Step 2.5 fence exits 0, prints a warning on stderr and does not run the script. `MEMDB` in Steps 2.5 and 4 comes from `MROOT`: both scripts run only when `<project>/.claude/memory/memory.db` exists, and they do.
  Verify: bash skills/memory-store/test-setup-team-fences.sh
- **C.** The Step 5 fence, run in a fresh shell with nothing from Step 3, exits 0 and leaves the five memory entries in `.gitignore`. No team fence exports or reads `EXT_GITIGNORE_DONE` or `SEED_IMPORT_SUMMARY`, and Step 7 reads the `seed-import:` line that Step 5.5 printed. The team sub holds no `lint-ok: C1` waiver.
  Verify: bash skills/memory-store/test-setup-team-fences.sh
- **D.** Step 5b is one bash fence. Run in a fresh shell in a project with no `.claude/` directory, it creates `.claude/settings.json` as valid JSON with `github.com:22` in `sandbox.network.allowedDomains`. A second run adds nothing and reports the host as already present. With `EMBEDDING_URL` set, the embedding host is added too, and existing keys such as `permissions.defaultMode` stay.
  Verify: bash skills/memory-store/test-setup-team-fences.sh
- **E.** The team Step 5b asks the user for one approval, the `settings.json` merge. It does not ask to write a hook or name `permissionDecision`. The orchestration sub still names `bash-compress.sh`.
  Verify: bash skills/memory-store/test-setup-team-fences.sh
- **F.** `embed-one.sh` in `lembed` mode registers the model before it calls `lembed()`. Against a fixture project and a `sqlite3` shim that refuses an unregistered name, the batch holds `INSERT INTO temp.lembed_models(name, model) SELECT 'mini', lembed_model_from_file('<MROOT>/.claude/memory/models/all-MiniLM-L6-v2.gguf');` after the `.load` lines and before `lembed('mini', '<text, quotes doubled>')`. The first argument of every `lembed()` call is `'mini'`, never a path, and the vector write is accepted. `embed-one.sh` and `migrate-md.sh` build the statement with `embed_lembed_register_sql` from `embed-common.sh` and hold no typed copy. A model path with a single quote is registered with the quote doubled. Run on `embed-one.sh` at the parent commit, the same suite fails.
  Verify: bash skills/memory-store/test-embed-lembed.sh
- **G.** A failed embed is logged and never breaks the caller. In `lembed` mode a failing batch, a missing model file and a missing extension each add one line `<UTC ts> embed embed-one memory 1: …` to `<MROOT>/.claude/memory/.errors.log`, and `embed-one.sh` exits 0. In `remote` mode a response with no vector adds one line. In `fallback` mode nothing is logged and `sqlite3` is not called.
  Verify: bash skills/memory-store/test-embed-lembed.sh
- **H.** `migrate-md.sh` in `lembed` mode, with unembedded rows and no `.md` file, registers the model in the same `sqlite3` call as `SELECT vec_to_json(lembed('mini', '<text>'))` and writes the vector row for each memory. A failing call prints `WARN: lembed failed for chunk N` and adds one line `<UTC ts> embed migrate-md chunk N: …` to `.errors.log`. A call that succeeds but prints to stderr still embeds the chunk and logs nothing. An embedding with no dimensions (`[]` or not JSON) prints `WARN: invalid embedding dimensions`, adds one log line, writes no vector row and does not stop the run. With `embed-common.sh` missing next to the script, it warns on stderr, skips embedding and still imports the `.md` file.
  Verify: bash skills/memory-store/test-embed-lembed.sh
- **I.** The Step 4 fence of `skills/memory-recall/SKILL.md`, run in a fresh shell in `lembed` mode, registers the model with the GGUF path under `<MROOT>/.claude/memory/models/` after both `.load` lines and before it calls `lembed('mini', '<query, quotes doubled>')`. No `lembed()` call gets a path. The fence takes the statement and the name from `embed-common.sh`, resolved through `plugin-dir.sh`, and holds no typed copy. When `embed-common.sh` does not resolve, the fence uses keyword search and sends no `.load`.
  Verify: bash skills/memory-recall/test-fences.sh
- **J.** The `/memory stats` Step 3 fence prints `Embed errors: 0` with no `.errors.log`. With two `embed` lines and one other line it prints `Embed errors: 2`. It prints no log detail. The count comes from `embed_error_count` in `embed-common.sh`, resolved through `plugin-dir.sh`, with no copy of the counter. When `embed-common.sh` does not resolve, it prints `Embed errors: unavailable` and no count.
  Verify: bash skills/memory-store/test-memory-md-fences.sh
- **K.** `doctor.sh --only memory.embed_errors` gives PASS with no log or no `embed` line. It gives WARN, exit 1, with the count and a fix-it that names the log, when the log holds `embed` lines, and `--gate=team` still exits 1. It gives SKIP with no `memory.db`, and with no `embed-common.sh` in the doctor install. The count comes from `embed_error_count`, with no copy of the counter in `doctor.sh`. The run leaves the log byte-identical.
  Verify: bash skills/doctor/test.sh
- **L.** The memory schema suite exits 0: a fresh `schema.sql` gives `schema_version` 4, and v3 and v1 fixtures migrate without data loss.
  Verify: bash skills/memory-store/test-migrate.sh
- **M.** The seed pack suite exits 0 with no FAIL line. This work package does not change seed export or import.
  Verify: bash skills/memory-store/test-seed-pack.sh
- **N.** [process] The CI round-trip embedding smoke test (Linear CDT-262 `[07 P-2]`, a cached tiny GGUF or the pinned model in CI) is deferred. It needs user approval for a CI model download. This work package adds no model download and no extension download to any test or CI job.
- **O.** [process] `bash tools/run-all-tests.sh` exits 0 and every `/release` gate passes.

## Version History

| Date | Change |
|------|--------|

| 2026-09-30 | WP 1-13 (`wp-1-13-setup-team-lembed`; CDT-261 `[10 F1]`, rv-p0-09; the lembed half of the package is CDT-262, see SPEC-004): **/setup team finds its scripts.** `commands/setup.md` Steps 2, 2.5, 3 and 4 set `PLUGIN_DIR` to the plugin root, so `schema.sql`, `migrate.sh`, `download-extensions.sh` and `migrate-md.sh` (all under `skills/memory-store/`) were never found and `/setup team` could not enable SQLite memory. Each fence now resolves its script with `plugin-dir.sh dir skills/memory-store/<file>` and skips with a warning when it is absent. Each fence is its own shell, so no variable crosses a fence: Step 5b is one fence (it set `SETTINGS` and `HOSTS_TO_ADD` in one fence and read them in the next, so `echo '{}' > ""` failed), it runs `mkdir -p "$MROOT/.claude"`, and it holds no `lint-ok: C1` waiver. Step 5 runs every time, without the `EXT_GITIGNORE_DONE` flag. Step 7 reads the printed `seed-import:` line. The team approval ask names only the `settings.json` merge, because the team path writes no hook (`bash-compress.sh` belongs to `/setup orchestration`). The `MROOT`-before-`MEMDB` premise of rv-p0-09 was already fixed by WP 1-12 (Steps 2.5 and 4), so nothing changed there. New `### wp-1-13-setup-team-lembed` AC subsection. Status stays ACTIVE. |
| 2026-08-26 | CDT-228: `/setup models` dispatch (local Model map writer; not doctor-gated). Subs are `project` \| `orchestration` \| `team` \| `models`. Status stays ACTIVE. |
| 2026-08-08 | CDT-173: present-file SHA-256 re-verification. The unconditional `[skip] already present` short-circuit in `download_and_extract()` / `download_file()` skipped integrity checking entirely, so a tampered or corrupt on-disk `vec0.so` / `lembed0.so` / `.gguf` was `.load`ed forever (partial regression of the CLUSTER-010 fail-closed guarantee). Skip is now conditional on the present file matching its pin; mismatch/unverifiable deletes and re-downloads. Adds a second pinned table for the **extracted member** (`.so`/`.dylib`) alongside the existing tarball pins — a sidecar hash file was rejected as a self-attesting anchor (an attacker who can write the binary can write the sidecar) and because it would break the documented hand-place-the-file recovery path. Member pin also closes a latent defect: the post-extract `find … \| head -1` could `mv` a stray tarball member (LICENSE/README) into place with the tarball hash still matching. No change to SPEC-005's no-block-on-failure guarantee — helpers return non-zero, call sites keep `\|\| true`, top level never `exit 1`. |
| 2026-07-22 | CDT-75: ship winner flipped to **(D)** `auto` + matrix allow + sandbox (epic C5 wording). |
| 2026-07-22 | CDT-51 TL P0/P1: orchestration allow = full matrix set; project-init Step 1b is team-bootstrap (acceptEdits seed only when mode missing AND no orch markers) — never clobber managed orch defaultMode. |
| 2026-07-22 | CDT-52 / CDT-46-C6: amend-then-promote — Overview/Covers name sole entry `/setup` (subs project\|orchestration\|team; `/init-team` stub only); demo kept OBSOLETE/historical (not live bootstrap); drop W5/full-rewrite OOS language that blocked promote honesty; retain C5 doctor-gate + SPEC-002 posture MUSTs; Status INFERRED→ACTIVE. Evidence: Linear CDT-52. |
| 2026-07-22 | CDT-54 / CDT-46-C8: hook template single SoT — `/setup orchestration` emits live hooks from init-orch templates; live `.claude/hooks` generated+gitignored (not package product); dual-copy `check-hook-templates` gate retired/reduced; regenerate via `/setup orchestration`. |
| 2026-07-22 | CDT-67: doctor gate passes `--gate=<sub>` (`team` / `orchestration`); M6c self-remediation (exact fix-it match) does not block. |
| 2026-07-22 | CDT-76: known-legacy-orphan sweep on /setup orchestration Step 4 — finite list (v1: bash-compress-wrapper.sh); bak-force + FORCE-OVERWRITE; ref-guard WARN; Step 9 summary. |
| 2026-07-22 | CDT-46-C4: user entry unified under `/setup <project\|orchestration\|team>` (`commands/setup.md`). Covers retargeted; `commands/init-team.md` → Deprecation stub. Scaffold/init-orch/team behaviors remain distinct protocols under the dispatcher. |
| 2026-07-22 | CDT-51 / CDT-46-C5: posture + doctor-gate — orchestration defaultMode follows SPEC-002 matrix winner; hard-gate doctor on `/setup team` + `/setup orchestration` (exit ≤1 OK; FAIL blocks; override warns); soft-advise on `/setup project`; marketplace no gate; force-overwrite old/new/restore disclosure. |
| 2026-07-22 | CDT-51 AC2: orchestration ship default named as matrix winner **(C)** `dontAsk` + `Bash(*)` + sandbox. |
| 2026-07-21 | CDT-46-C2: `/demo` removed in the v1.0 surface-cleanup pass (`skills/demo/SKILL.md` → deprecation stub). Marked the Demo MUST/SHOULD/Test/Validation items OBSOLETE-at-v1.0.0 (retained one cycle as historical record, not deleted); annotated the demo Covers entry as a DEPRECATED stub. Bootstrap requirements (init-team, scaffold, init-orchestration) unchanged. |
| 2026-06-15 | Editorial hygiene (AUDIT-P3.5b): reworded the Demo cleanup MUST to defer to SPEC-016's safe worktree-teardown (separate `git worktree remove` / `git branch -D` calls, never chained `&&`; prefer `worktree-lib.sh release`); added SPEC-016 cross-reference. No behavioral change. |
| 2026-06-14 | AUDIT-P0.12: TaskCompleted-hook registration command changed to the worktree-safe `bash "${CLAUDE_PROJECT_DIR}/.claude/hooks/task-completed.sh"` form, matching the init-orchestration safe emitter (relative path resolved from agent cwd and failed inside worktrees). |
| 2026-06-13 | AUDIT-P1-1B (D4): declared this repo's AGENTS.md and the emitted consumer template intentionally DISTINCT (no managed-include single-sourcing between them; emitted files MUST stay marker-free). Pushed the `SendMessage` no-addressable-parent guidance into the emitted template's Team Coordination section (both blocks) — consumers previously lacked it, risking spawned agents DMing a non-existent parent. |
| 2026-03-23 | Resolved scaffold/orchestration merge question. Moved AGENT_TEAMS env var here from SPEC-002. Clarified TDD.md seeding as index entries not full specs. |
| 2026-03-22 | Initial spec generated by /generate-specs |
## Cross-references

- SPEC-002: Plugin Infrastructure — settings.json structure and hook registration
- SPEC-003: Agent Role System — 7 agents that project-init bootstraps
- SPEC-004: Memory Storage — SQLite DB schema that init-team creates
- SPEC-006: Memory Retrieval — extensions downloaded here enable semantic search
- SPEC-016: Worktree Isolation — owns the safe worktree-teardown discipline used by the demo cleanup step (`worktree-lib.sh`, separate-call removal)
