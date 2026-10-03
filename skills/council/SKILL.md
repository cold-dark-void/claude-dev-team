---
name: council
description: |
  Adversarial council tribunal engine — reality-checks claims with material
  evidence. Shared engine for /council and /review-and-commit (diff-mode preset).
  Blind investigators, evidence-or-silence rule, dual output shapes
  (verdict[] and finding[]), atomic verdict index at .claude/council/index.json,
  feedback-memory learning loop. Judge is a dedicated agent with an empty
  tool allowlist. See specs/core/SPEC-013-adversarial-council-tribunal.md.
---

# council — Engine Protocol

Protocol specification for the adversarial council tribunal engine. This file
is the contract every component in `skills/council/` codes against —
`engine.sh`, the prompt templates, the report templates, the diff-mode
preset, the `/council` command wrapper, and the refactored
`skills/review-and-commit/SKILL.md` all read this file to know what to
build. It is a spec for the implementation, not the implementation itself.

Authoritative source of truth for all MUSTs cited below:
`specs/core/SPEC-013-adversarial-council-tribunal.md`. Every MUST in this
document is traceable to a line in that spec.

---

## Overview

The council is a court-shaped audit pipeline. Blind Investigators gather
raw tool-call evidence for claims extracted from the subject (a pasted claim,
a session slice, a diff). A Prosecutor (jaded-senior flavor) and a Devil's
Advocate (yolo-ic flavor) write adversarial briefs over that evidence. A
dedicated `council-judge` agent — with a structurally empty tool allowlist —
issues the final verdicts or findings. The engine writes a report to
`.claude/council/<date>-<slug>[--<task_id>][-<N>].md` (report
no-overwrite, SPEC-013 Phase 6, below), appends a row to a verdict index at
`.claude/council/index.json` when task-bound. Phase 7 feedback memory
is DEFERRED (CDT-325): the engine does not write lessons.

Two callers share this engine: `/council` (generic, verdict-shape) and
`/review-and-commit` (diff scope, finding-shape, via the diff-mode preset). The
engine is invoked from `commands/council.md` and `skills/review-and-commit/SKILL.md`;
it is never invoked from hooks — hooks read `index.json` only.

`/council --blind` is a **third entry** on the same command surface but a
**distinct execution path** (no tribunal Phases 1–5, no `engine.sh`
preflight/finalize): N unconstrained + M lens reviewers → semantic clustering
→ confidence-tiered findings. See § Blind-review path.

---

## Invariants (non-negotiable)

These invariants apply to every preset and every phase. Breaking any of them
is a bug.

- **Blindness.** Investigators, Prosecutor, Devil's Advocate, and the
  Domain Specialist MUST receive raw artifacts only (files, logs, diffs,
  plan text) — never prior assistant narrative, never prior verdicts, never
  a paraphrase. (SPEC-013 § Output Shapes)
- **Evidence-or-silence.** Every claim, finding, verdict, prosecutor line,
  and advocate line MUST be backed by an investigator `tool_use_id`. Lines
  without one MUST be struck. Struck lines MUST appear in the report audit
  trail — never silently dropped. (SPEC-013 § Engine Architecture)
- **Judge cannot run tools.** Phase 5 routes to `agents/council-judge.md`,
  whose YAML frontmatter declares `tools: ""`. The empty allowlist is
  structurally enforced by the agent file — the engine does not attempt a
  per-invocation override. (SPEC-013 § Council tiering)
- **Tool_use_id required on every claim/finding line.** Missing = struck.
  This is how "evidence-or-silence" is mechanized. (SPEC-013 § Engine Architecture)
- **Atomic index writes.** `.claude/council/index.json` is updated via
  tmp+rename under `flock`, delegated to `skills/council/index-writer.sh`.
  A concurrent reader (the TaskCompleted hook) MUST never observe a partial
  write. (SPEC-013 § Council tiering)
- **Output shape branching.** `verdict[]` and `finding[]` are first-class;
  every preset MUST declare exactly one. Phase 5 output, Phase 6 report
  template, Phase 7 feedback memory, and the TaskCompleted gate all branch
  on this field. (SPEC-013 § Engine Architecture)
- **Pure auditor.** The council MUST NOT propose fixes, MUST NOT modify
  files, MUST NOT audit user-authored claims, MUST NOT run automatically on
  every session or commit. (SPEC-013 § Council tiering)
- **No persistent council roles.** Investigators, Prosecutor, and Advocate are
  ephemeral prompt-template variants injected into Task-tool subagent
  invocations, not entries in `agents/`. Phase 3 Domain Specialist reuses an
  existing team agent (`devops`/`ds`/`qa`/`pm`) as an investigator for one
  claim — still ephemeral for the run, not a new council agent file. Persistent
  council agent files are `council-judge` (Phase 5) and `council-scribe`
  (tool-less extractor, classifier, prosecutor, advocate, cross-reviewer,
  quorum analyst). (SPEC-013 § Command Shape & Scope)

---

---

## Load protocol

Stage bodies live in this directory — this file is the router. Read **only the
current stage**; do not read every stage file up front.

1. Once per run: run the PDH stanza fence in `model-map.md` § Investigator
   spawn (prints `PDH=<root>` to stderr); every later fence carries the root
   for reuse (the `PDH:-<PDH>` carry form) — re-run that fence first when the
   carried root is not held.
2. Resolve and read the stage file for the section you are executing:
   `STEP=$(bash "$PDH/skills/plugin-dir.sh" file skills/council/<stage>)`.

| Section | File | What |
|---------|------|------|
| Model map (SPEC-037) | `model-map.md` | finder / council-scribe / council-judge spawn fences |
| Invocation Contract | `invocation-contract.md` | CLI arguments, presets, task-id resolution |
| Phases 0–2 | `phases-0-2.md` | Intake, claim extraction, parallel investigation, spawn-failure degradation |
| Workflow + blind path | `phases-blind.md` | workflow.js execution path, `--blind`, blind cross-review (Phase 2.5), Phase 3 |
| Phases 4–5 | `phases-4-5.md` | Prosecution & defense, judgment |
| Phases 6–7 | `phases-6-7.md` | Report & persistence, learning loop |
| Schemas | `schemas.md` | Flavor file schema, prompt template schema + documented variables table |
| Reference | `reference.md` | Interaction with other components, failure modes, deferred backlog |
## Traceability: SPEC-013 MUST → section

| SPEC-013 lines | Requirement | Covered in |
|---|---|---|
| 24–36 | Command shape & scope (incl. `--blind` exclusivity + parity) | Invocation Contract → CLI arguments |
| Blind-review path / Test 22 | `--blind` fan-out, tiers, Tier-1 sever recursion | Blind-review path (`--blind`) |
| 33–37 | Engine architecture (skill + thin wrapper, no parallel pipeline) | Overview, Interaction table |
| 40–44 | Output shapes (verdict[]/finding[], tool_use_id, confidence scale) | Invariants, Presets, Phase 5 |
| 46–52 | Phase 1 claim extraction (budget, ranking, skip rules, diff-mode enrichment) | Phase 1 |
| 54–60 | Phase 2 investigation (parallel, blindness, read-only, evidence bundle, ≥2 flavors) | Phase 2 |
| 62–69 | Phase 3 domain specialist | Phase 3 (CDV-209 live) |
| 79–87 | Phase 2.5 blind cross-review (anonymized peer ranking, Borda consensus, WEAK_EVIDENCE, <3-investigator bypass) | Phase 2.5 |
| 89–94 | Phase 4 prosecution + defense (evidence-only, strike rule) | Phase 4 |
| 96–104 | Phase 5 judgment (council-judge agent, taxonomies, strike rule, empty allowlist) | Phase 5 |
| 106–121 | Phase 6 report + verdict index (path, frontmatter, atomic writes, null columns) | Phase 6 |
| 122–130 | Phase 7 feedback memory (verdict[]-only, thresholds, routing, settings keys) | Phase 7 |
| 131–135 | Integration hooks (retro hint, requires_council, no global enable) | Interaction table |
| 136–144 | Task-ID plumbing (fallback chain, command-path only, post-replan clarification) | Task-id resolution |
| 145–157 | Scope exclusions (no writes, no fixes, not automatic, dual-shape gate + claim-scope policy) | Invariants, Phase 6, Phase 7 |

Every MUST in SPEC-013 traces to a section above. If a future edit to
SPEC-013 adds a MUST without a corresponding section here, that is a bug in
this file — update this file to cover it.
