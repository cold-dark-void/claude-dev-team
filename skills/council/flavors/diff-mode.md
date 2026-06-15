---
name: diff-mode
role: preset
description: |
  Code-review preset used by /review-and-commit. Emits finding[] output shape with
  the 5 review-and-commit specialists as investigator flavors. Spec-grep intake
  enriched into Phase 1. Feedback memory disabled — code bugs are not
  fabrications.
output_shape: finding[]
flavor_list: [logic, security, compliance, quality, simplification]
spec_grep: true
feedback_memory_enabled: false
confidence_filter_threshold: 80
severity_taxonomy: [critical, warning, nitpick]
commit_gate_blocks_on: [critical, compliance]
---

# Diff-Mode Preset

The `diff-mode` preset fires when the council engine is invoked with `--diff`
or an explicit `--preset diff-mode`. It configures the engine as a
code-review pipeline over a staged/modified diff: 5 specialist investigators
in parallel, `finding[]` output shape, 80-confidence discard filter, and no
feedback-memory writes (a code bug is not a fabrication — SPEC-013 line 105).

This preset is the ONLY v1 caller path for `/review-and-commit`. The command
wrapper at `skills/review-and-commit/SKILL.md` is a thin entry point
that resolves the diff scope and passes control to `engine.sh` with this
preset selected.

## Intake (Phase 0 enrichment)

Before Phase 1 extraction runs, the engine performs a spec-grep enrichment
step specific to diff-mode (SPEC-013 line 48, SPEC-010 line 31):

1. Enumerate changed file paths from the staged + modified diff.
2. For each changed path, grep `specs/**/*.md` for MUST lines whose scope
   matches the path (by directory prefix, explicit file reference, or
   covered-by declaration in spec frontmatter).
3. Assemble the matching MUSTs into an **applicable-specs bundle**.
4. Append the bundle to the raw input handed to Phase 1 claim extraction
   alongside the diff itself. The diff remains the primary artifact; the
   bundle is context so extraction can surface spec-misalignment findings.

This step runs only for `diff-mode`. Other presets leave spec_grep off.

## Specialist roles

The preset spawns 5 investigator flavors in parallel during Phase 2, each
receiving the full diff, the full content of changed files, and the
applicable-specs bundle:

- **logic** — bugs, off-by-ones, race conditions, error handling gaps, edge
  cases, hot-path inefficiencies. Category: `logic`.
- **security** — injection, auth/authz, secret & PII exposure, OWASP top 10,
  trust boundary violations, PII-bearing logs. Category: `security`.
- **compliance** — AGENTS.md / CLAUDE.md rule violations, version sync, file
  size caps, naming conventions, commit hygiene. Category: `compliance`.
- **quality** — wrong abstractions, hidden coupling, breaking API changes,
  premature generalization, naming that lies. Category: `design`.
- **simplification** — dead code, over-engineering, redundant helpers,
  shorter equivalent expressions, consolidation wins. Category:
  `simplification`.

Each specialist is an investigator (`role: investigator`) bound to the
`finding[]` output shape. Flavor deltas live in `skills/council/flavors/`
alongside this preset.

## Severity classification

Findings are scored on the SPEC-010 confidence rubric (0-100):

- **0-25** — likely false positive. Discard.
- **26-50** — uncertain. Discard.
- **51-79** — probable issue. Discard.
- **80-94** — high confidence. Emit as **warning**.
- **95-100** — near certain. Emit as **critical**.

The engine applies `confidence_filter_threshold: 80` at emission: any finding
below 80 is dropped before Phase 6 writes the report (SPEC-013 line 44,
SPEC-010 line 23). Below-threshold findings are preserved in the report's
struck-lines audit trail, never silently dropped.

Severity taxonomy is fixed: `critical | warning | nitpick`. Any finding with
a severity outside this set MUST be struck by the engine (SPEC-013 line 83).

## Commit gate

The `/review-and-commit` command enforces a commit gate after the engine returns:

- ANY finding with `severity == critical` blocks the commit.
- ANY finding with `category == compliance` blocks the commit, regardless of
  severity.
- Warnings and nitpicks (non-compliance) surface in the report but do not
  block; the user is prompted whether to proceed.

The gate reads the canonical report or the engine's stdout summary; it does
not re-parse the finding list. Authoritative gate behavior is SPEC-010 line
30.

## Feedback memory

Disabled for diff-mode. Phase 7 is a no-op under this preset. Rationale: a
code bug discovered by a specialist is not a claim fabrication; writing it to
an agent's directives would conflate "caught a bug" with "caught a lie"
(SPEC-013 line 105, SPEC-010 line 28).

## Cross-references

- SPEC-010 Code Review & Release — owns the user-facing `/review-and-commit`
  contract and the 5-specialist requirement.
- SPEC-013 Adversarial Council Tribunal — owns the `finding[]` output shape,
  the strike rule, and the Phase 1 spec-grep enrichment step.
- `skills/council/SKILL.md` — engine protocol this preset plugs into.
- `skills/review-and-commit/SKILL.md` — original source of the 5 specialist
  sub-prompts migrated into the flavor files listed above.
