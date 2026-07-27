# SPEC-028: `/fix-ticket` — Premise → Implement → Adversarial Refute

**Status**: ACTIVE
**Category**: core
**Created**: 2026-07-14
**Issue**: CDV-197

> **Entry Surface (CDT-46-C4):** user entry is `/debug ticket …` via `commands/debug.md` + `skills/debug/SKILL.md`. `commands/fix-ticket.md` and `skills/fix-ticket/` are one-cycle Deprecation stubs. **Full fold of this spec into SPEC-014 is W5 out of scope** — protocol MUSTs below remain authoritative for the pipeline until that fold.

---

## Overview

The premise→implement→adversarial-refuters pipeline (originally `/fix-ticket`) productizes a battle-tested p0 workflow. Given a ticket id and a bug premise, the orchestrator verifies the premise still holds (read-only ic5), implements the fix in a SPEC-016 worktree (ic4/ic5), spawns N adversarial qa refuters in parallel, and writes a report under `.claude/fix-ticket/`. The caller owns commit and release — the skill never touches the version triplet or runs git commit.

**Authoritative path:** markdown Task-spawn protocol (historically `skills/fix-ticket/SKILL.md`; after CDT-46-C4, reachable from `/debug ticket` / `skills/debug/`). Optional `workflow.js` is a non-invoked reference asset (args-as-JSON-string guard for CDV-196 Workflow authoring conventions).

**Boundaries & related specs:**
- **SPEC-009 (ticket workflow)** — family member; does not absorb orchestrate lifecycle, task store, or PR automation.
- **SPEC-016 (worktree isolation)** — worktrees via `worktree-lib.sh ensure <ticket-id>` when path not provided.
- **SPEC-013 (council)** — spawn-failure degradation protocol home is `skills/council/SKILL.md` § Spawn-failure degradation (CDV-199). This spec reuses the exact marker and actor rule; it does not restate a second protocol.
- **CDV-196** — council Workflow re-platform; out of scope. Share Workflow authoring conventions only (args-string guard).
- **SPEC-014 `/debug`** — hosts `ticket` mode entry (CDT-46-C4); non-ticket modes remain investigation discipline for open-ended bugs.

**Out of scope:** council engine reuse / finding[] schema, task store / `requires_council`, Linear status automation, local-agent refuter tier, auto-release / version bump, auto `/review-and-commit`.

---

## MUST

### Surface & invocation

- **M1 — Thin entry.** User entry is `/debug ticket` via thin `commands/debug.md` (SPEC-014). Protocol MUST live in a skill reachable from that entry (`skills/debug/` and/or retained fix-ticket protocol files). `commands/fix-ticket.md` MUST be a Deprecation stub naming `/debug ticket` for one cycle (v1.1 removal).
- **M2 — YAML frontmatter.** Live Surfaces MUST declare `name` and `description` in YAML frontmatter for discovery (stubs included).
- **M3 — Required args.** Invocation is `/debug ticket <ticket-id> "<bug/premise>"` (legacy `/fix-ticket …` equivalent). Missing ticket-id or premise MUST produce a usage error and MUST NOT spawn agents.
- **M4 — Optional flags.** Skill MUST accept: `--fix "<instructions>"`, `--agent ic4|ic5` (default `ic4`), `--lenses a,b` (default `correctness,completeness`), `--worktree <path>`.
- **M5 — Worktree placement.** When the skill creates a worktree, path MUST be under `$MROOT/.worktrees/<slug>` via `skills/worktree-lib.sh ensure` (SPEC-016). Sibling-directory worktrees MUST NOT be created.

### Phase: Verify-premise

- **M6 — Read-only premise.** Orchestrator MUST spawn one ic5 (or Explore-capable) agent that does not write files.
- **M7 — Premise schema.** Premise return MUST include at least `holds` (boolean) and `evidence` (string). SHOULD include `current_locations`, `scope_notes`, `sibling_occurrences`, `reference_impl`.
- **M8 — Sibling grep.** Premise prompt MUST require a sibling-occurrence grep for the same bug pattern.
- **M9 — Premise-fail hard stop.** When `holds=false`, the skill MUST stop: write a report with `premise_holds: false`, MUST NOT implement or refute, and MUST surface a clear stop message.

### Phase: Implement

- **M10 — Worktree-only edits.** Implementer MUST edit only under the target worktree path.
- **M11 — No version files.** Implementer MUST NOT touch `.claude-plugin/plugin.json`, `.claude-plugin/marketplace.json`, or README version/changelog sections.
- **M12 — No git mutation.** Implementer MUST NOT run `git commit`, `git checkout`, `git reset`, or `git add`. Changes remain uncommitted.
- **M13 — Sibling completeness.** Implementer MUST fix every sibling occurrence listed by premise.
- **M14 — Smallest patch.** Implementer MUST make the smallest change that fully fixes the bug — no scope creep, no new features.
- **M15 — Impl schema.** Implement return MUST include `files_changed`, `diff_summary`, and `changelog_md` (one draft bullet for the caller; skill MUST NOT apply it to CHANGELOG).

### Phase: Adversarial-verify

- **M16 — Parallel refuters.** Orchestrator MUST spawn one qa refuter per lens in parallel (default lenses: `correctness`, `completeness`).
- **M17 — Verdict schema.** Each refuter MUST return at least `lens` and `holds` (boolean); SHOULD include `issues` and `detail`.
- **M18 — No git checkout in refuters.** Refuter prompts MUST forbid `git checkout`, `git restore`, and `git reset` for cleaning bite-tests. Revert MUST use `cp` from backup or explicit sed-reverse of the injection.
- **M19 — Default holds=false.** Refuters MUST default to `holds=false` on any real problem; `holds=true` only when genuinely cannot break the fix. Citations MUST include file:line.

### Spawn-failure degradation (CDV-199 reuse)

- **M20 — Marker.** On unusable refuter spawn (rate-limit, empty, refusal), report MUST include the exact marker string `self-verified — refuters unavailable`.
- **M21 — Actor rule.** Self-verify is always the orchestrator — NEVER the implementer agent. Never ship on implementer self-validation.
- **M22 — Protocol cite.** Skill MUST cite `skills/council/SKILL.md` § Spawn-failure degradation as protocol home — MUST NOT invent a second protocol string.
- **M23 — Partial fleet.** Keep good refuter returns; self-verify only missing lenses; still mark the run degraded (`verification_mode: self-verified`).

### Report & orchestration

- **M24 — Report path.** Orchestrator MUST write `$MROOT/.claude/fix-ticket/<YYYY-MM-DD>-<ticket-id>.md`.
- **M25 — Report frontmatter.** Report MUST include YAML frontmatter keys: `ticket`, `worktree`, `premise_holds`, `all_hold`, `verification_mode` (`full`|`self-verified`), `created_at` (ISO-8601 UTC).
- **M26 — all_hold.** `all_hold` is true only when every lens holds and ≥1 verdict exists.
- **M27 — Degraded banner.** When `verification_mode: self-verified`, report body MUST include banner line: `> **self-verified — refuters unavailable**`
- **M28 — No auto-release.** Skill MUST NOT commit, bump version, open PR, or invoke `/release`. MUST print next-step hints only.
- **M29 — Terse spawns.** Every Task spawn prompt MUST include `Output mode: terse`.

### Workflow reference asset (when shipped)

- **M30 — Args guard.** If `skills/fix-ticket/workflow.js` is present, it MUST guard `typeof args === 'string' ? JSON.parse(args) : args` before use and MUST fail loud when required fields (`ticket`, `worktree`) are missing.

---

## SHOULD

- SHOULD document the args-as-JSON-string guard as a shared Workflow authoring convention (for CDV-196 to cite).
- SHOULD allow bite-test mutations under the backup/sed-reverse rule; default posture remains read-only.
- SHOULD validate shell scripts with `bash -n` and exercise realistic inputs after implement.
- SHOULD draft changelog bullets in house style for the caller to apply at `/release`.
- SHOULD document distinction from `/debug`, `/orchestrate`, `/council`, `/review-and-commit`.

---

## Test

1. **Usage error (M3):** invoke without ticket or premise → usage message, no Task spawns.
2. **Premise-fail stop (M9):** premise returns `holds=false` → report with `premise_holds: false`; no implement/refute spawns; clear stop message.
3. **Full green path (M16–M26):** premise holds → implement → all lenses hold → report `all_hold: true`, `verification_mode: full`, no degraded banner.
4. **Refuter holds=false (M19):** at least one lens fails → `all_hold: false`; issues cite file:line.
5. **Spawn-fail self-verified (M20–M23):** simulate unusable refuter → orchestrator self-verifies; report banner exact `self-verified — refuters unavailable`; `verification_mode: self-verified`.
6. **No-checkout string (M18 / AC10):** `rg -n 'git checkout|git restore|NEVER' skills/fix-ticket/prompts/refute.md` matches.
7. **Worktree path (M5):** without `--worktree`, ensure path is `$MROOT/.worktrees/<ticket-id>`.
8. **No version/commit (M11–M12, M28):** implement prompt contains bans on version files and `git commit`; skill does not call `/release`.
9. **Thin entry (M1):** user entry is `/debug ticket` via thin `commands/debug.md` (SPEC-014); protocol lives in a skill reachable from that entry; `commands/fix-ticket.md` is a Deprecation stub naming `/debug ticket` (no full phase protocol restated in host or stub).
10. **Args guard (M30):** `rg "typeof args === 'string'" skills/fix-ticket/workflow.js` matches; `node --check skills/fix-ticket/workflow.js` passes.
11. **skill-lint C1:** `bash skills/skill-lint/check-skill-bash.sh commands/fix-ticket.md skills/fix-ticket/SKILL.md` exits 0.
12. **Docs index:** README + `docs/README.md` list `/fix-ticket`; `docs/commands/fix-ticket.md` present.

---

## Validation

- [ ] SPEC reviewed and promoted to ACTIVE
- [ ] AC1–AC10 from CDV-197 plan pass under QA
- [ ] Manual matrix: premise-fail, full green, refute fail, degraded marker
- [ ] skill-lint clean on command + skill
- [ ] docs-drift clean for `/fix-ticket` cmd-index
- [ ] No council/engine files modified (CDV-196 boundary)
- [ ] `/release` minor after QA (caller)

---

## Open Questions

- None locked open. OQ1–OQ7 resolved in plan: markdown authoritative + optional workflow.js; bite-tests under revert rule; separate report dir; changelog draft only; premise hard stop; SPEC-028 number; no auto `/review-and-commit`.

---

## Version History

| Date | Change |
|------|--------|
| 2026-07-14 | Initial ACTIVE — CDV-197 productize p0-fix-workflow as `/fix-ticket` |
| 2026-07-22 | CDT-46-C4: entry Surface moves to `/debug ticket` (SPEC-014 host). M1/M3 retargeted; command+skill become Deprecation stubs. Full SPEC-028→SPEC-014 fold deferred to W5. |
