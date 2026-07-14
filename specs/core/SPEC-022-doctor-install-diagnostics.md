# SPEC-022: /doctor — Install & Config Diagnostics

**Status**: ACTIVE
**Category**: core
**Created**: 2026-07-03

---

## Overview

A user-invocable `/doctor` command that diagnoses the install/config health of the plugin and its host project in one pass and prints a PASS/WARN/FAIL table with a concrete fix-it line per finding. The top support burden for plugin consumers is *silent misconfiguration*: version-triplet drift, a missing `sqlite3` or vec extension quietly degrading memory to `.md` fallback, hooks that were never wired (or wired with worktree-unsafe paths), absent optional deps (`jq`, `python3`, `bwrap`, `opencode`, `gh`) invisibly disabling features, stale worktree locks, and plugin-cache resolution surprises. Today each of these is debugged by hand; `/doctor` makes them one command away.

The command is **read-only by default** — it diagnoses and recommends, it never repairs or bootstraps. An explicit `--fix` mode applies only a narrow allowlist of provably-safe repairs (e.g. clearing a stale `distilling_lock`). Output is dual-mode: a human table, and `--json` with meaningful exit codes so the same battery can gate CI or a future `/release` preflight. The check battery is deterministic bash (no LLM, no network), so results are reproducible. Note: the Claude Code harness ships its own built-in `/doctor` (harness install health); the plugin command is namespaced (`dev-team:doctor`), covers plugin/project health only, and never attempts to shadow or replace the built-in.

**Boundaries & related specs (conflict scan, 2026-07-03):**
- **SPEC-005 (team bootstrap)** owns all state *creation*: `/init-team` (DB init, extension downloads, project-init scan, permission sync) and `/init-orchestration` (hooks, sandbox, AGENTS.md emission). `/doctor` diagnoses and never bootstraps — when memory/DB/hook state is absent it RECOMMENDS `/init-team` or `/init-orchestration` in its fix-it line and creates nothing itself.
- **SPEC-002 (plugin infrastructure)** owns the manifest layout, the version-triplet rule (`CHANGELOG.md` + `.claude-plugin/plugin.json` + `.claude-plugin/marketplace.json`), the settings/sandbox baseline, and the `TaskCompleted` hook contract. `/doctor` verifies conformance *to SPEC-002's rules* — it MUST NOT define its own versioning, settings, or hook policy.
- **SPEC-004 / SPEC-007 (memory storage & distillation)** own the DB schema, `schema_version`, migrations (`migrate-v2.sh`), and the `config` table including the protected keys `distilling_lock` / `schema_version`. `/doctor` reads (SELECT-only) and never migrates; the single permitted write near this domain is the `--fix` stale-lock clear, which mirrors `/memory-distill --force` semantics rather than inventing a second locking protocol.
- **SPEC-016 (worktree isolation)** owns `.worktrees/<slug>` layout, the `.wt-lock` format, and the FRESH/STALE verdict (`WT_LOCK_TTL_SECONDS`, default 21600 s). `/doctor` evaluates lock staleness using SPEC-016's exact rule (reusing `worktree-lib.sh` where it needs an authoritative answer) and MUST NOT invent a second staleness heuristic; worktree removal is always delegated to `worktree-lib.sh release`.
- **SPEC-019 (local-agent offload)** owns the `LOCAL_AGENT` opt-in flag, the liveness probe (`opencode --version`), and the wrapper exit-code contract. `/doctor` may surface that preflight's result (flag state + probe outcome exactly as SPEC-019 defines them) but MUST NOT reimplement eligibility, preflight, or sandbox-downgrade logic.
- **SPEC-010 (code review & release)** owns `/release`. Adopting `/doctor` as a `/release` preflight gate is a future SPEC-010 revision (see Open Questions), not something this spec wires in.

**Out of scope:** repairs beyond the `--fix` allowlist, network liveness probes (embedding endpoints, GitHub reachability), schema migration, version bumping, diagnosing the Claude Code harness itself (the built-in `/doctor`'s job), performance profiling, and telemetry.

---

## MUST

- **M1 — Read-only by default.** A default `/doctor` invocation MUST perform zero writes: no file or directory creation, no DB writes (SELECT/PRAGMA only against `memory.db`), no `settings.json` mutation, no git mutation, no network calls. Extension-load probes MUST run against a scratch in-memory DB (`sqlite3 :memory:`), never against the project's `memory.db`.
- **M2 — Full check battery.** A single run MUST execute at least these check groups: **(a) version triplet** — `CHANGELOG.md` latest `### vX.Y.Z` heading vs `plugin.json` `version` vs `marketplace.json` `plugins[].version`, evaluated against the *resolved* plugin install (dev checkout or cache) per SPEC-002's rule; **(b) memory stack** — `sqlite3` presence, `memory.db` existence, `schema_version` value vs the current expected schema, optional extensions (sqlite-vec / lembed) loadable, and embedding-config coherence (mode `remote` requires a non-empty `EMBEDDING_URL` and its host in the sandbox network allowlist; mode `lembed` requires extension + GGUF present); **(c) hooks wiring** — `.claude/settings.json` hooks vs the canonical set `/init-orchestration` emits, plus hook hygiene (commands `${CLAUDE_PROJECT_DIR}`-anchored, no pipe operators, referenced scripts exist and are executable); **(d) settings sanity** — valid JSON, `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS` present when team memory is initialized, and coherence warnings (e.g. `bypassPermissions` with sandbox disabled); **(e) optional dependencies** — `jq`, `python3`, `bwrap`, `opencode`, `gh`, each reported with a named per-feature impact statement (e.g. "no bwrap → local-agent runs without the OS leash"); **(f) worktree state** — stale `.worktrees/` entries, `.wt-lock` FRESH/STALE per SPEC-016's TTL rule, orphaned locks (lock without a registered git worktree and vice versa), and a held `distilling_lock`; **(g) plugin cache resolution** — resolve a known relpath via `skills/plugin-dir.sh` and report which tier answered (dev checkout / versioned cache / find-fallback) or its not-found exit 3.
- **M3 — Optional-dep absence is WARN, never FAIL.** Severity semantics: FAIL is reserved for broken hard invariants (version-triplet drift, unparseable plugin/settings JSON, `schema_version` mismatch, a wired hook pointing at a nonexistent script). The absence of any OPTIONAL dependency or opt-in feature MUST surface as WARN accompanied by its impact statement — an otherwise-healthy project missing all five optional deps MUST exit with zero FAILs.
- **M4 — Fix-it line per finding.** Every WARN and FAIL row MUST carry exactly one concrete, copy-pasteable remediation — a command (`/init-team`, `/init-orchestration`, `/release`, `/memory-distill --force`, `bash skills/worktree-lib.sh release <slug>`) or a one-line instruction. Never a vague "check your configuration".
- **M5 — Dual output.** Default output is a human table (one row per check: STATUS / check id / one-line detail, fix-it lines beneath WARN/FAIL rows, and a `N pass / N warn / N fail / N skip` summary footer). `--json` MUST emit a single stable JSON document on stdout — top-level `{doctor_schema, plugin_version, resolved_tier, checks[], summary}` with per-check `{id, group, status, detail, fixit}` (`fixit` null on PASS) — evolving additively only. Stdout discipline: with `--json`, stdout carries only the JSON payload; all diagnostics go to stderr.
- **M6 — Exit-code contract.** Exactly: `0` = all executed checks PASS; `1` = at least one WARN, no FAIL; `2` = at least one FAIL; `64` = usage error. SKIPped checks (probe tool absent) MUST NOT affect the exit code — the missing tool is already its own WARN. This tri-state lets callers choose their gate threshold (`doctor` for strict, `[ $? -le 1 ]` for FAIL-only).
- **M7 — `--fix` is a narrow, enumerated allowlist.** `--fix` MUST apply only repairs from an allowlist enumerated in the command doc, where every entry is (i) idempotent, (ii) destructive only to derived or stale state, and (iii) announced (intent printed) before it runs, with confirmation required when stdin is a TTY. Initial allowlist: clear a held `distilling_lock` (mirroring `/memory-distill --force`), remove a STALE-per-SPEC-016 `.wt-lock`, and sweep orphaned `*.tmp` files in `.claude/handoff/cache/`. Everything else stays a fix-it recommendation.
- **M8 — MUST NOT repair beyond the allowlist or bootstrap anything.** `/doctor` MUST NOT: create or initialize memory directories, DBs, or hooks; run or trigger schema migrations; download extensions; bump versions or edit `CHANGELOG.md`/manifests; write `.claude/settings.json` (hook-path repairs are a fix-it pointing at re-running `/init-orchestration`, which owns the rewrite rules); or shadow the harness built-in `/doctor`. Bootstrap is SPEC-005's job in both modes, including `--fix`.
- **M9 — Single source of truth for expectations.** Expected states MUST be derived from their owning artifact, never from a second hand-maintained list inside `/doctor`: the expected hook set comes from `skills/init-orchestration` (its templates / `check-hook-templates.sh`); worktree staleness from SPEC-016's TTL rule (honoring `WT_LOCK_TTL_SECONDS`); plugin resolution by invoking `skills/plugin-dir.sh` as a subprocess (never a private re-implementation of its 3-tier algorithm); version rules from SPEC-002; local-agent preflight from SPEC-019. If a canonical set changes, `/doctor`'s expectation follows without editing `/doctor`.
- **M10 — The doctor never crashes on the disease.** `/doctor` itself MUST require only `bash`, `git`, and coreutils. When a tool a check depends on is absent (`sqlite3`, `jq`, `python3`), the dependent check reports SKIP (or the documented degraded state, e.g. ".md fallback mode active") and the run continues to a full table and a valid exit code — a missing dependency MUST NOT abort the battery.
- **M11 — Worktree- and consumer-aware.** `/doctor` MUST resolve the project root via the worktree-aware formula (`git rev-parse --git-common-dir`) so it reads shared state correctly from inside `.worktrees/<slug>`, and MUST run meaningfully in both the dev checkout and a consumer project with a cache-installed plugin. Dev-repo-only conditions (e.g. hook-template byte-drift surfaced via `check-hook-templates.sh`) MUST NOT produce WARN/FAIL in a consumer project.
- **M12 — Deterministic and offline.** The battery MUST be LLM-free and MUST NOT make network calls in any mode (default or `--fix`); remote-embedding health is checked as *config coherence* (M2b), not endpoint liveness. Two consecutive runs on unchanged state MUST produce identical results and exit codes.

---

## SHOULD

- SHOULD print the resolved plugin version and install tier (dev checkout / cache path) in the report header — the first thing support triage needs.
- SHOULD structure checks as small registered bash functions (`id`, `group`, `run`) so new specs can add checks without restructuring the command; a future SPEC-0NN adds a check by appending a function, not editing the table renderer.
- SHOULD support `--only <check-id|group>` for a fast focused re-run after applying a fix.
- SHOULD complete in a few seconds on a typical project — no long probes, no full-DB scans (use counts/PRAGMAs).
- SHOULD, once the exit-code contract has proven stable across a release cycle, be proposed as a `/release` preflight step via a SPEC-010 revision (tracked in Open Questions, not wired by this spec).
- SHOULD surface `LOCAL_AGENT` state under optional deps: flag unset → informational; flag set but `opencode` absent or probe failing → WARN quoting SPEC-019's own fallback semantics.

---

## Test

1. **Read-only proof (M1):** snapshot mtimes + hashes of `.claude/`, `memory.db`, and `settings.json`; run default `/doctor` on a healthy project; assert the snapshot is byte-identical and no new files exist.
2. **Version drift (M2a):** against a fixture where `plugin.json` and `marketplace.json` versions differ → FAIL row naming all three files and the mismatched values, fix-it referencing `/release` (dev) or plugin update (consumer); exit `2`.
3. **Uninitialized memory (M2b, M3, M4):** in a project that never ran `/init-team` → memory checks WARN (not FAIL) and the fix-it line is `/init-team`; exit `1`.
4. **Extension degradation (M2b, M3):** `sqlite3` present but vec extension absent → WARN naming the impact ("semantic search degraded to keyword"); extension probe ran against `:memory:`, not `memory.db`.
5. **Hook drift (M2c, M9):** remove the `TaskCompleted` entry from `.claude/settings.json` → FAIL naming the missing hook with fix-it `/init-orchestration`; a hook wired as `bash .claude/hooks/x.sh` (worktree-unsafe, un-anchored) → WARN citing the `${CLAUDE_PROJECT_DIR}` rule; changing the canonical set in `skills/init-orchestration` changes `/doctor`'s expectation with no edit to `/doctor` itself.
6. **Optional deps (M2e, M3):** run with a PATH stripped of `jq`, `python3`, `bwrap`, `opencode`, `gh` → five WARNs each carrying a named feature impact, zero FAILs on an otherwise-healthy project; exit `1`.
7. **Worktree staleness (M2f, M9):** craft a `.wt-lock` older than the TTL → WARN "stale"; a fresh lock → no finding; the verdict flips when `WT_LOCK_TTL_SECONDS` is overridden, proving SPEC-016's rule (not a private heuristic) decides.
8. **Cache resolution (M2g):** report names the tier that resolved a known relpath via `plugin-dir.sh`; with an unresolvable relpath the check reflects `plugin-dir.sh` exit `3` rather than crashing.
9. **JSON output (M5):** `--json | jq .` parses; stdout contains only the JSON document; every non-PASS check carries a non-null `fixit`; `doctor_schema`, `plugin_version`, `resolved_tier`, and `summary` counts are present and correct.
10. **Exit codes (M6):** healthy project → `0`; WARN-only → `1`; any FAIL → `2`; unknown flag → `64` with usage on stderr.
11. **Fix scope (M7, M8):** seed a held `distilling_lock` → `--fix` prints intent, clears it (config value back to `''`), and a second `--fix` run is a no-op; hash-compare proves `--fix` never touched `settings.json`, schema, manifests, or `CHANGELOG.md`.
12. **Never bootstraps (M8):** run default and `--fix` modes in a bare project → no `.claude/memory/`, no `memory.db`, no hooks created; the report recommends `/init-team` / `/init-orchestration` instead.
13. **Degraded doctor (M10):** run with `sqlite3` and `jq` absent → the battery completes, dependent checks show SKIP/degraded-state, the table and exit code are still produced.
14. **Worktree + consumer context (M11):** run from inside `.worktrees/<slug>` → shared state resolved via the git-common-dir formula; run in a consumer project with a cache-installed plugin → no dev-repo-only findings appear.
15. **Determinism/offline (M12):** two consecutive runs on unchanged state produce byte-identical `--json` output; running with networking disabled produces the same result.

---

## Validation

- [x] Spec reviewed and promoted to ACTIVE
- [x] Default run proven read-only on a real initialized project (snapshot diff clean)
- [x] All five optional deps absent → zero FAILs (WARN-with-impact only)
- [x] Exit-code contract (`0`/`1`/`2`/`64`) verified end-to-end
- [x] `--json` output parses with `jq` and is stable across two unchanged runs
- [x] Expected hook set single-sourced from `skills/init-orchestration` (no duplicated list inside `/doctor`)
- [x] `--fix` allowlist reviewed item-by-item against the M7 safety criteria
- [ ] Backlog item `.claude/backlog/doctor-install-diagnostics.md` closed via `/backlog close` (at merge)

---

## Open Questions

- **`/release` preflight adoption:** should `/release` (SPEC-010) hard-gate on `/doctor` exit ≤ 1 once the contract is stable? Owned by a future SPEC-010 revision. **Deferred (CDV-191):** out of scope; do not wire into `/release` on this ticket.
- **Command naming vs the harness built-in:** ~~rename (e.g. `/team-doctor`) before ACTIVE?~~ **RESOLVED (user lock, CDV-191):** keep plugin command `doctor` → namespaced `dev-team:doctor`. Document collision with Claude Code harness built-in `/doctor` in command docs + overview (already noted). Do **not** rename to `/team-doctor`.
- **Opt-in `--probe` mode:** live network checks (e.g. `EMBEDDING_URL` liveness) are excluded by M12; worth a separate opt-in flag later, or leave to the owning features' own error paths? **Deferred (CDV-191):** out of scope; leave as future OQ — no live network probes this ticket.
- **`distilling_lock` repair home:** keep the clear in `--fix`, or delegate entirely to `/memory-distill --force` to avoid two clearing paths? Current answer: `--fix` mirrors `--force` semantics; revisit if the two drift.

---

## Version History

| Date | Change |
|------|--------|
| 2026-07-03 | Initial DRAFT — ideation wave 2 |
| 2026-07-14 | ACTIVE (CDV-191): `commands/doctor.md` + `skills/doctor/doctor.sh` + test harness; naming lock `dev-team:doctor`; OQs deferred (`/release` preflight, `--probe`) |

**Covers**: `commands/doctor.md`, `skills/doctor/doctor.sh`, `skills/doctor/SKILL.md`, `skills/doctor/test.sh`

## Cross-references

- **SPEC-002** — Plugin Infrastructure: version-triplet rule, manifest layout, settings/sandbox baseline, `TaskCompleted` hook contract (`/doctor` verifies, never redefines).
- **SPEC-005** — Team Bootstrap: `/init-team` + `/init-orchestration` own all creation/repair of memory, extensions, and hooks (`/doctor` recommends, never bootstraps).
- **SPEC-004 / SPEC-007** — Memory Storage & Distillation: schema, `schema_version`, migrations, protected config keys (`/doctor` is SELECT-only; stale-lock clear mirrors `/memory-distill --force`).
- **SPEC-010** — Code Review & Release: `/release` owns version bumping; future preflight adoption tracked in Open Questions.
- **SPEC-016** — Worktree Isolation: `.wt-lock` format + TTL staleness rule; removals delegate to `worktree-lib.sh release`.
- **SPEC-019** — Local-Agent Offload: `LOCAL_AGENT` flag, liveness probe, fallback contract (`/doctor` surfaces, never reimplements).
- Backlog: `.claude/backlog/doctor-install-diagnostics.md` (banked 2026-07-03; this spec is its "Goal" realized as a DRAFT).
