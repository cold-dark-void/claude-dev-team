<!-- /council stage body — load via SKILL.md router; read only the current stage. -->

## Flavor file schema

Flavor files live at `skills/council/flavors/<name>.md`. They come in two
groups: the tribunal flavors and the diff-mode specialist flavors.

**YAML frontmatter (required fields):**

```yaml
---
name: <flavor-id>                   # matches filename stem
role: investigator | prosecutor | advocate | specialist
output_shape_constraint: verdict[] | finding[] | any
tool_allowlist: [Read, Grep, Glob, Bash]   # prompt-level only
---
```

(SPEC-013 § Command Shape & Scope.)

**Body:** a Markdown system-prompt delta. There is no line cap. The delta is
a focus lens, not a second full prompt. Tribunal flavors put authoring notes
above a `## Delta body` marker. `loadFlavor` in `workflow.js` strips
frontmatter, `[//]: #` authoring lines, and everything above that marker,
then the orchestrator injects the rest as `{{FLAVOR_DELTA}}`. Diff-mode
flavors have no marker; the whole body is the delta.

`external.md` is not injected by `loadFlavor`. `external-reviewer.sh`
`build_prompt` reads `## Delta body` and puts that text in the CLI prompt.

**Committed flavor set (COUNCIL-001):**
- `paranoid-ic.md` — hostile-read investigator; demands receipts for
  every asserted fact.
- `skeptic-ic.md` — tool-using Phase 2 investigator; generic preset pairs
  it with `paranoid-ic`. It may Read, Grep, and Bash.
- `jaded-senior.md` — prosecutor flavor only; has seen every failure mode;
  assumes the claim is wrong until evidence proves otherwise. Not a Phase 2
  investigator.
- `yolo-ic.md` — advocate flavor; argues the claim is true; exists to
  defeat prosecutor monoculture.
- `logic.md`, `security.md`, `compliance.md`, `quality.md`,
  `simplification.md` — diff-mode specialist investigators; the 5
  focus areas migrated from the pre-refactor `skills/review-and-commit/SKILL.md`.
- `external.md` — external CLI investigator (CDV-207); not Task-spawned.
  Loaded by `external-reviewer.sh` `build_prompt` (it reads `## Delta body`).
  Not injected by `loadFlavor`. Additive slot only.

---

## Prompt template schema

Role prompt templates live at `skills/council/prompts/<name>.md`. Files:

- `claim-extractor.md` — Phase 1 for session/diff
- `plan-extractor.md` — Phase 1 for `--plan` (CDV-208)
- `investigator.md` — runs in Phase 2 (one per claim per flavor) and Phase 3 specialist
- `topic-classifier.md` — Phase 3 topic classify (one per claim; CDV-209)
- `phase4-brief.md` — runs in Phase 4 (spawned twice: once as Prosecutor, once as Devil's Advocate, parameterized by role)
- `judge.md` — delivered to the `council-judge` agent in Phase 5
- `blind-scribe.md` — council `--blind` reviewers (tool-less; file text preloaded)
- `unconstrained-reviewer.md` — bug-hunt unconstrained teams (tool-using; not council `--blind`)
- `lens-reviewer.md` — bug-hunt lens teams (tool-using; not council `--blind`)
- `quorum-analyst.md` — `--blind` semantic clustering (CDT-46-C3)
- `tier-triage.md` — ambiguous-middle council-tier triage (CDT-126). Procedure is `commands/council.md` §§ 1.5.2–1.5.4. The live caller is the autopilot ship gate (`skills/autopilot/ship-gate-council.md` §3a/§3b), which grades its own merge-base numstat. `/council --diff` does not auto-grade (§ 1.5.1). Input is numstat, not a full patch.

Templates are Markdown with `{{VARIABLE}}` placeholders. Tribunal templates:
`engine.sh` / `commands/council.md` substitute before Task/judge. Blind-path
templates: `commands/council.md` substitutes on the `--blind` path only.

**Documented variables per template:**

| Template | Variables |
|---|---|
| `claim-extractor.md` | `{{SCOPE_TYPE}}`, `{{INPUT_TEXT}}`, `{{CLAIM_BUDGET}}` |
| `plan-extractor.md` | `{{PLAN_PATH}}`, `{{INPUT_TEXT}}`, `{{CLAIM_BUDGET}}` |
| `investigator.md` | `{{CLAIM_TEXT}}`, `{{SOURCE_LOCATOR}}`, `{{RAW_ARTIFACTS}}`, `{{FLAVOR_DELTA}}`, `{{CACHE_DIR}}`, `{{TOOL_BUDGET}}`, `{{VERIFY_COMMAND}}` |
| `topic-classifier.md` | `{{CLAIM_TEXT}}`, `{{DATA_NONCE}}` |
| `cross-reviewer.md` | `{{CLAIM_TEXT}}`, `{{BUNDLE_BLOCK}}` |
| `phase4-brief.md` | `{{ROLE}}`, `{{ROLE_BIAS}}`, `{{EVIDENCE_FIELD}}`, `{{EVIDENCE_BUNDLES}}`, `{{FLAVOR_DELTA}}` |
| `judge.md` | `{{ORIGINAL_CLAIMS}}`, `{{EVIDENCE_BUNDLES}}`, `{{PROSECUTOR_BRIEF}}`, `{{ADVOCATE_BRIEF}}`, `{{OUTPUT_SHAPE}}` |
| `blind-scribe.md` | `{{TEAM_ID}}`, `{{LENS_NAME}}`, `{{FLAVOR_DELTA}}`, `{{FILE_LIST}}`, `{{PROJECT_ROOT}}`, `{{SCOPE_NOTE}}`, `{{FILE_TEXT}}`, `{{DATA_NONCE}}` |
| `unconstrained-reviewer.md` | `{{TEAM_ID}}`, `{{FILE_LIST}}`, `{{PROJECT_ROOT}}`, `{{SCOPE_NOTE}}` |
| `lens-reviewer.md` | `{{TEAM_ID}}`, `{{LENS_NAME}}`, `{{FLAVOR_DELTA}}`, `{{FILE_LIST}}`, `{{PROJECT_ROOT}}`, `{{SCOPE_NOTE}}` |
| `quorum-analyst.md` | `{{ALL_FINDINGS}}`, `{{TEAM_MANIFEST}}`, `{{UNCONSTRAINED_TEAMS}}`, `{{LENS_TEAMS}}`, `{{TOTAL_TEAMS}}`, `{{DATA_NONCE}}` |
| `tier-triage.md` | `{{FILES_CHANGED}}`, `{{LOC_CHANGED}}`, `{{GRADING_REASON}}`, `{{DIFF_SUMMARY}}` |

Templates MUST NOT include `{{ASSISTANT_NARRATIVE}}` or any similar variable
that would leak prior model output into a blind role. Enforcing this is
primarily a code review discipline (the prompt templates are reviewed against this rule).

---
