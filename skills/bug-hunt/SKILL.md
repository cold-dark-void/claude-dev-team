---
name: bug-hunt
description: |
  Use when asked to find or audit unknown bugs in a path — unknown-defect
  discovery pipeline: scoped multi-perspective discover → continuous
  refute/confirm → user-visible report → findings plan + proceed-gated
  bh-quality backlog materialize → severity-band phase handoff emit-only
  (stages 1–4). MUST NOT invoke /orchestrate|/epic or fix product code; no
  re-S1–S2 invent. Entry: /bug-hunt [path] [--severity-floor …] [--proceed]
       | /bug-hunt materialize <path> [--severity-floor …] [--proceed]
       | /bug-hunt handoff <plan-path> [--start-phase <n]>
user-invocable: false
---

# bug-hunt — Discover → Refute → Materialize → Handoff (stages 1–4)

Protocol for `/bug-hunt` stages **discover**, **refute/confirm**,
**findings plan + backlog materialize**, and **phase handoff emit-only**.
Thin command host: `commands/bug-hunt.md` (PDH-resolves this skill).

**Governing contract:** `specs/core/SPEC-034-bug-hunt-workflow.md` (DRAFT;
M8 materialize lock; M38–M41 stage-3 — CDT-138; M42–M48 stage-4 — CDT-139).
**Composition home (cite, do not fork):**

| Stage | Compose from | Do not |
|-------|--------------|--------|
| S1 Discover | `skills/council/SKILL.md` § Blind-review path + `commands/council.md` § Blind-review path (SPEC-013) | Nested `/council` user lock; second finder protocol |
| S2 Refute | SPEC-013 investigator pattern — `skills/council/prompts/investigator.md` + existing `skills/council/flavors/*` | Tribunal Phases 3–5 per candidate; new flavors; `engine.sh` whole-hunt finalize |
| S3 Materialize | `skills/backlog/SKILL.md` § **Programmatic write-back** (SPEC-009 dual-write; Linear-first fail-open) | Second dual-write / index / `add.sh` fork; auto-materialize without M8 proceed |
| S4 Handoff | templates `phase-plan.md` + `handoff-phase.md` (field contracts); M9 locks | Invoke `/orchestrate`/`/epic`; spawn fix ICs; edit product code; re-S1–S3 invent |

Neighboring surfaces (when-to-use — SPEC-034 M26):

| Surface | Job vs this skill |
|---------|-------------------|
| `/bug-hunt` (this) | Unknown defects; stages 1–4 (discover → refute → plan+materialize → phase handoff emit-only) |
| `/debug` / `/debug ticket` | Known bug premise → fix (not discovery) |
| `/council --blind` | One-shot blind investigation; no hunt report / floor / refute wave |
| `/backlog` | Interactive backlog; S3 cites programmatic write-back only |
| `/orchestrate` / `/epic` | Downstream fix engines — **print-only** hints from S4; never invoked here |

## Invariants (non-negotiable)

Hard walls — breaking any is a bug (SPEC-034 M8 / M27–M30 / N1–N13 / CDT-138 AC4–AC5 /
CDT-139 AC9–AC12):

- **MUST NOT materialize without proceed** — plan write (S3c) is allowed; backlog create
  (S3e) only after M8 (`--proceed` or typed `proceed`). Auto-materialize without proceed
  MUST NOT occur (AC4; M8; N2).
- **MUST NOT dual-write fork** — materialize cites `skills/backlog/SKILL.md` § Programmatic
  write-back only; MUST NOT reimplement mkdir/printf/index/`add.sh` (AC5; M40).
- **MUST NOT invoke engines / fix** — S4 **emits** phase templates under M9 locks; **MUST NOT
  invoke** `/orchestrate`, `/epic`, spawn fix ICs, or edit product code to "fix"
  (AC9/AC12; M30; N1; N12). Print `invocation_hint` only after arm.
- **MUST NOT re-run S1 discover or S2 refute on resume** — `materialize <path>` and
  `handoff <plan>` load artifacts only (AC12 / OQ5 / N13).
- **MUST NOT invent severity taxonomy or parallel ticket lifecycle** — severity ∈
  {`critical`,`warning`,`nitpick`} only; no second backlog/orchestrator (M13, M19, M29, N5, N9).
- **MUST NOT place a user lock between S1 and S2** — single continuous run (M7, N8).
  Proceed lock at S3d (after plan); phase lock at S4e (start phase 0 + between phases).
- **MUST NOT invent confirmed findings** — evidence-or-silence; fail closed on thin evidence
  (prefer `refuted`).
- **MUST NOT re-enter S1–S3 invent during handoff** — S4 loads C3 plan only (N13).
- **CDV-199 marker** — on unusable investigator/refuter spawn, exact string  
  `self-verified — refuters unavailable`  
  Actor = orchestrator only; never ship on implementer self-validation. Protocol home:  
  `skills/council/SKILL.md` § Spawn-failure degradation (cite; do not restate a second protocol).
- **No version files** — never edit `.claude-plugin/plugin.json`, `marketplace.json`,
  `CHANGELOG.md` version sections, or run `/release`.
- **No commit** — never `git commit` / `git add` / `git checkout` / `git reset` in the hunt
  pipeline.
- **Process artifacts uncommitted** — under `$MROOT/.claude/bug-hunt/` only (M25); root
  `.gitignore` lists `.claude/bug-hunt/`. Backlog items under `.claude/backlog/` also
  process-local (SPEC-009).
- **Output mode: terse** on every Task spawn.
- **Compose, do not fork** — S1/S2 reuse SPEC-013 patterns (M16); S3 reuses SPEC-009
  programmatic write-back; no nested slash-command UX that implies a user lock before S3d.

---

---

## Load protocol

Stage bodies live in this directory — this file is the router. Read **only the
current stage**; do not read every stage file up front.

1. Resolve the plugin root with the PDH stanza in `s0-parse.md` § 0a (fresh
   shell — re-run that fence first when the carried root is not held).
2. Resolve and read the stage file for the step you are executing:
   `STEP=$(bash "$PDH/skills/plugin-dir.sh" file skills/bug-hunt/<stage>)`.
3. After a stage finishes, read the next stage's file. `BH_*` session bindings
   carry across stages per the table in `s0-parse.md`.

| Stage | File | What |
|-------|------|------|
| Arguments + S0 | `s0-parse.md` | Usage, args, session bindings, parse/validate (M2–M5) |
| S1 | `s1-discover.md` | Discover — compose blind path (M20) |
| S2 | `s2-refute.md` | Refute/confirm — investigator wave (M21) |
| REPORT | `report.md` | User-visible report + findings.json |
| S3 | `s3-materialize.md` | Findings plan + proceed-gated materialize (M38–M41) |
| S4 | `s4-handoff.md` | Phase handoff emit-only (M42–M48) |
| Reference | `pipeline.md` | Stage diagram + finding model (schema map) |
| Reference | `traceability.md` | SPEC-034 MUST map + interaction with other components |
