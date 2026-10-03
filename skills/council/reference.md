<!-- /council stage body — load via SKILL.md router; read only the current stage. -->

## Interaction with other components

| Component | Relationship |
|---|---|
| `skills/council/index-writer.sh` | **Sole writer** of `.claude/council/index.json`. The engine shells out to this helper in Phase 6; never opens the index file directly. |
| `skills/orchestrate/task-store.sh` | Writes `.claude/tasks/<task_id>.json` with task metadata (including `requires_council: true`). The engine does NOT write to this file; the orchestrator owns it. Referenced by SPEC-009. |
| `agents/council-judge.md` | The Judge agent invoked in Phase 5. Empty tool allowlist. |
| `agents/council-scribe.md` | Tool-less internal council role (extractor, classifier, prosecutor, advocate, cross-reviewer, quorum analyst). No memory. |
| `skills/review-and-commit/SKILL.md` | Calls this engine with `--preset diff-mode` (or `--diff` with inferred preset). Must not carry a parallel pipeline. |
| `commands/council.md` | Thin wrapper; tribunal scopes → `engine.sh` + Task/Workflow; `--blind` → Blind-review path (no engine preflight). |
| `skills/council/workflow.js` | Optional Workflow-tool driver (CDV-196); schema-forced agent steps + shared finalize. Not used by `--blind`. |
| `.claude/hooks/task-completed.sh` | **Reads** `.claude/council/index.json` to apply the `requires_council` gate (dual-shape: verdict conf **or** finding conf — SPEC-002). Never calls the engine. Blind-path rows remain gate-ignored (unbound / no qualifying row / both-null); `finding[]` is **not** blanket-ignored. |
| `commands/retro.md` | Prints `Consider: /council --from-retro <anchor-id>` as a hint. Does NOT auto-invoke. Persists anchors to `$MROOT/.claude/retro/anchors/<id>.json` after validation (single writer; CDV-212). |
| `commands/council.md` § Blind-review path | Former `/blind-review` lives in that section (CDT-46-C3). The old command file was removed. |

---

## Failure modes

Every failure mode has a distinct exit code and a stderr message contract.
Callers (`commands/council.md`, `skills/review-and-commit/SKILL.md`) rely on
exit codes to decide whether to continue.

| Exit | Meaning | Stderr message contract |
|---|---|---|
| 0 | Success | none on stderr |
| 2 | No scope argument supplied | `engine.sh: scope required (--scope claim\|session\|diff\|plan\|from-retro)` (tribunal); `--blind` exclusivity / parity fails print usage from `commands/council.md` Step 0.5 |
| 2 | Unknown preflight flag | `engine.sh: unknown preflight flag: <flag>` |
| 2 | `--tier` outside `light\|full` | `engine.sh: invalid --tier value: <v> (want light\|full)`; `skip` gets its own line — `engine.sh: --tier skip is resolved by the caller — the run must not reach preflight`. The caller has already fail-closed to `full` before invoking (SPEC-013 Fail-closed contract), so coercing here would mask a broken caller |
| 2 | Plan path missing / unreadable | `engine.sh: plan file not found or not readable: <path>` (or `--plan requires a path`) |
| 2 | Retro anchor missing / unreadable / invalid | `engine.sh: retro anchor not found: <path>` (or requires anchor-id / missing fabricated_claim_text / not valid JSON) |
| 3 | Reserved | (unused after CDV-212; no deferred scopes remain) |
| 4 | Unknown preset | `engine.sh: unknown preset: <name> — known: generic, diff-mode` |
| 5 | Empty evidence **and** no self-verify path | `engine.sh: Phase 2 produced zero evidence bundles — aborting` (after spawn failure, attempt orchestrator self-verify first — see Spawn-failure degradation; exit 5 only if still empty) |
| 6 | Index write failure | `engine.sh: failed to update .claude/council/index.json` |
| 7 | Judge returned malformed/empty output | `engine.sh: judge output is not valid JSON and repair failed: <detail>` (also covers an empty or refused judge result, which fails JSON repair) |
| 8 | M14 per-AC split fails closed (SPEC-033 M14(g)) | `m14-ac-split: <cause>` (one line, names the case; no plan printed on stdout) |
| 9 | Report no-overwrite candidates exhausted (SPEC-013 Phase 6) | Probe (`cmd_report_path`): `engine.sh: report-path: every candidate up to -99 is taken for slug '<slug>' (report no-overwrite, SPEC-013 Phase 6)`. Finalize: `engine.sh: report no-overwrite: every candidate up to -99 is taken for slug '<slug>' — writing no report (SPEC-013 Phase 6)` (finalize writes no report) |

---

## Deferred / remaining backlog

- **`--from-retro <anchor-id>` scope** — **implemented CDV-212**. Preflight
  loads `$MROOT/.claude/retro/anchors/<id>.json` (exit 2 if missing); Phase 1
  skip; `resolved_claim` in investigation plan. Fixture:
  `skills/council/fixtures/from-retro-anchor.json`. `/retro` is the single
  writer of anchor files after validation.
- **`--plan <path>` scope** — **implemented CDV-208**. Preflight requires a
  readable path (exit 2 if missing); Phase 1 uses `plan-extractor.md`;
  rest of pipeline claim-shape agnostic. Fixture:
  `skills/council/fixtures/plan-scope-sample.md`.
- **Phase 3 dynamic domain specialist** — **implemented CDV-209**. Topic
  classifier + at most one of devops/ds/qa/pm when confidence ≥ 0.75; skip
  weak match and diff-mode; before Phase 2.5. (SPEC-013 Phase 3.)
- **Investigator tool-call caching within a run** — **implemented CDV-211**.
  Preflight creates `${TMPDIR:-/tmp}/council-cache-<run_id>/` (`reads/`,
  `greps/`, `manifest.json`) and emits `cache_dir` + `run_id` in the plan.
  Orchestrator may seed a read-only `{{CACHE_DIR}}`; the investigator must
  not write it (CDT-275). Finalize best-effort `rm -rf`. Empty cache
  is fine — correctness unchanged.
  *(Per-phase token usage reporting — SPEC-013 SHOULD — implemented CDV-204
  via finalize `--tokens-file`; graceful omit when harness has no tokens.)*
- **External investigator slot** — **implemented CDV-207**. Opt-in
  `--external[=codex|gemini]`; helper `external-reviewer.sh` + flavor
  `external.md`; plan.external; graceful skip; additive only.
- **Per-invocation preset overrides** — `confidence_filter_threshold` and
  `claim_budget` remain hardcoded per preset unless a later ticket exposes
  CLI overrides.
- **Phase 7 feedback memory** — **DEFERRED (CDT-325)**. The engine does not
  run it. `feedback_memory_enabled` is reserved and has no effect until
  Phase 7 is implemented. Do not write `lessons.md` from finalize.
- **`/council --blind`** — **implemented CDT-46-C3**. Scope flag + parity
  `--teams|--lenses|--target`; council reviewers use tool-less
  `blind-scribe.md` (file text preloaded); `quorum-analyst` clusters;
  bug-hunt keeps `unconstrained-reviewer` and `lens-reviewer`. Tier-1 emit
  as findings (no recursive `/council`); no `--no-council`.
  (SPEC-013 Blind-review path; Test 22.)

---
