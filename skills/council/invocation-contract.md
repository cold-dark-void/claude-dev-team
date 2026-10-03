<!-- /council stage body — load via SKILL.md router; read only the current stage. -->

## Invocation Contract

### CLI arguments

`engine.sh` is the single entry point. It is invoked by `commands/council.md`
(thin passthrough) and by `skills/review-and-commit/SKILL.md` (passes a scope +
preset selector). The argument surface:

| Argument | Purpose | Status in COUNCIL-001 |
|---|---|---|
| `"<claim text>"` (positional) | Audit a single pasted claim | Supported |
| `--session` | Audit a slice of the current session transcript | Supported |
| `--session --last N` | Audit last N turns only | Supported |
| `--diff` | Audit staged diff (review-and-commit entry path) | Supported |
| `--plan <path>` | Audit a plan file for unverified assumptions | Supported (CDV-208) |
| `--from-retro <anchor-id>` | Audit a fabrication anchor from `/retro` | Supported (CDV-212) |
| `--blind` | Multi-team blind peer review (absorbs `/blind-review`) | Supported (CDT-46-C3) |
| `--teams N` | Blind parity: unconstrained reviewer count (default 3) | Supported with `--blind` only |
| `--lenses L1,L2,...` | Blind parity: lens list (default security,contributor,spec) | Supported with `--blind` only |
| `--target <path>` | Blind parity: narrow file scope (default full project) | Supported with `--blind` only |
| `--task-id <id>` | Bind this run to an orchestrated task id | Supported |
| `--preset <name>` | Explicit preset selector (else inferred from scope) | Supported |
| `--workflow` | Opt-in Workflow execution path (CDV-196); orthogonal to tribunal scope | Supported — **not** applied to `--blind` |
| `--why` | Print flavors used + specialist reasoning after summary | Supported (CDV-206) |
| `--external[=codex\|gemini]` | Optional external investigator slot (codex → gemini) | Supported (CDV-207) |
| `--council-tier=<light\|full>` | Command-surface tier override. `commands/council.md` maps it to engine `--tier`. Not an `engine.sh` flag | Supported (CDT-126) |
| `--tier light\|full` | Engine preflight tier. Absent means `full`. `skip` is refused | Supported (CDT-126) |
| (no scope) | — | **Hard fail, non-zero exit** |

Env: `COUNCIL_WORKFLOW=1` is equivalent to `--workflow`.
`COUNCIL_WORKFLOW_FORCE_FALLBACK=1` forces probe fail (tests).

Scope exclusivity: exactly one of `<claim>`, `--session`, `--plan`, `--diff`,
`--from-retro`, `--blind` MUST be given. `--teams` / `--lenses` / `--target`
without `--blind`, or `--blind` combined with another scope, MUST fail loudly.
There is **no** `--no-council` flag. `--workflow` is **not** a scope — it only
selects the execution transport for tribunal paths (see Workflow execution
path); MUST NOT apply to `--blind`. For tribunal scopes, `commands/council.md`
translates the user surface into the engine's single `--scope <name>` — the
engine itself takes one `--scope` value. `--blind` never reaches `engine.sh`
preflight; it is orchestrated entirely by `commands/council.md` per §
Blind-review path. A zero-scope invocation reaches the engine as an empty
`--scope` and MUST exit non-zero with a clear stderr message. (SPEC-013 § Command Shape & Scope)

`--plan <path>` is live (CDV-208): missing/unreadable path → exit 2 with a clear
stderr message; present path → preset `generic`, Phase 1 extraction via
`skills/council/prompts/plan-extractor.md`, source locators
`file:heading-path:line`.

`--from-retro <anchor-id>` is live (CDV-212): loads
`$MROOT/.claude/retro/anchors/<anchor-id>.json` (MROOT, not WTROOT). Missing
or unreadable file, invalid JSON, or empty `fabricated_claim_text` → exit 2.
Present → preset `generic`, Phase 1 **skip**, investigation plan includes
`resolved_claim` (claim text) with `scope_arg` still the anchor-id. Fixture:
`skills/council/fixtures/from-retro-anchor.json`.

### Presets

A **preset** is a named bundle of engine behavior: which flavors to spawn,
which output shape to emit, whether spec-grep intake runs, whether feedback
memory is enabled, and what confidence filter (if any) is applied at
emission.

Preset selection:
1. Explicit via `--preset <name>`
2. Otherwise inferred from scope: `--diff` → `diff-mode`; everything else →
   `generic`

There is no `skills/council/presets/` directory. Presets are not files:
`engine.sh` resolves them via a hardcoded `case` statement (the `generic` and
`diff-mode` arms) and emits the resolved field values into the investigation
plan JSON it hands to the orchestrating Claude. That `case` is the
**authoritative source of preset values** — the fields below document what the
resolution emits into the plan, not a file format:

| Field | Type | Description |
|---|---|---|
| `name` | string | Preset identifier |
| `description` | string | One-line purpose |
| `output_shape` | `verdict[]` \| `finding[]` | Mandatory — drives Phase 5/6/7 branching |
| `flavor_list` | array of flavor names | Which flavors spawn as investigators (paranoid-ic + ≥1 other) and/or specialists |
| `spec_grep` | bool | Recorded true for diff-mode. The engine does not grep. The orchestrator assembles applicable specs (WP 3-01) |
| `feedback_memory_enabled` | bool | Reserved. No effect until Phase 7 is implemented |
| `confidence_filter_threshold` | int 0–100 \| null | If set, findings/verdicts below this are filtered at emission (diff-mode: 80) |

**Concrete COUNCIL-001 presets:**

- **`generic`** — `output_shape: verdict[]`, flavors: `paranoid-ic` +
  `skeptic-ic` (investigators) + `jaded-senior` (prosecutor) + `yolo-ic`
  (advocate), `spec_grep: false`, `feedback_memory_enabled: true`
  (reserved; no effect until Phase 7 is implemented),
  `confidence_filter_threshold: null`.
- **`diff-mode`** — `output_shape: finding[]`, flavors: `logic`, `security`,
  `compliance`, `quality`, `simplification` as investigators. Phase 4
  prosecution/defense is skipped (`finding[]-shape preset`). `spec_grep`
  is recorded `true`; the engine does not grep (orchestrator, WP 3-01).
  `feedback_memory_enabled: false` (SPEC-013 § Council tiering; a code bug is not a
  fabrication), `confidence_filter_threshold: 80` (SPEC-013 § Engine Architecture,
  SPEC-010 § Code Review (review-and-commit)).

**Light-tier flavor subsets (CDT-126).** `--tier light` narrows `flavor_list`
only; every other preset field is untouched:

| Preset | `full` flavors | `light` flavors |
|---|---|---|
| `generic` | `paranoid-ic`, `skeptic-ic` | unchanged — already exactly the 2 distinct flavors Phase 2 requires |
| `diff-mode` | `logic`, `security`, `compliance`, `quality`, `simplification` | `logic`, `security` — the two correctness/safety axes; the three polish axes drop |

Prosecutor/advocate flavors are not subset because `light` does not run Phase 4
at all.

### Task-id resolution

Fallback chain, evaluated left-to-right (SPEC-013 § Council tiering):

1. `--task-id <id>` command-line flag
2. `CLAUDE_TASK_ID` environment variable
3. **Unbound** (no task id — report filename has no suffix, no index row)

This fallback chain applies ONLY to direct command-path invocations
(`/council`, `/review-and-commit` → `engine.sh`). The SPEC-002 TaskCompleted
hook uses its own stdin-based task-id resolution and does NOT participate in
this fallback chain — the two paths are independent. (SPEC-013 § Council tiering.)

When task-bound:
- Report filename MUST include `--<task_id>` suffix (Phase 6).
- Report frontmatter MUST include a `task_id: <id>` field (Phase 6).
- Engine MUST call `index-writer.sh` after writing the report file (Phase 6).

When unbound:
- Report filename MUST NOT have a `--<task_id>` suffix.
- Report frontmatter MUST NOT include a `task_id` field.
- Engine MUST NOT write to `.claude/council/index.json`.

Orchestrated-task invocations rely on SPEC-009's `CLAUDE_TASK_ID` export
(orchestrator's responsibility — not this engine's). Reference SPEC-009 § Orchestrate; do not re-specify here.

---
