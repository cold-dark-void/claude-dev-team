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
`.claude/council/<date>-<slug>.md`, appends a row to a verdict index at
`.claude/council/index.json` when task-bound, and (for verdict-shape runs)
writes feedback memories for high-confidence fabrications.

Two callers share this engine: `/council` (generic, verdict-shape) and
`/review-and-commit` (diff scope, finding-shape, via the diff-mode preset). The
engine is invoked from `commands/council.md` and `skills/review-and-commit/SKILL.md`;
it is never invoked from hooks — hooks read `index.json` only.

---

## Invariants (non-negotiable)

These invariants apply to every preset and every phase. Breaking any of them
is a bug.

- **Blindness.** Investigators, Prosecutor, Devil's Advocate, and the
  Domain Specialist MUST receive raw artifacts only (files, logs, diffs,
  plan text) — never prior assistant narrative, never prior verdicts, never
  a paraphrase. (SPEC-013 line 56)
- **Evidence-or-silence.** Every claim, finding, verdict, prosecutor line,
  and advocate line MUST be backed by an investigator `tool_use_id`. Lines
  without one MUST be struck. Struck lines MUST appear in the report audit
  trail — never silently dropped. (SPEC-013 lines 43, 59, 76, 85)
- **Judge cannot run tools.** Phase 5 routes to `agents/council-judge.md`,
  whose YAML frontmatter declares `tools: ""`. The empty allowlist is
  structurally enforced by the agent file — the engine does not attempt a
  per-invocation override. (SPEC-013 lines 79–80, 86)
- **Tool_use_id required on every claim/finding line.** Missing = struck.
  This is how "evidence-or-silence" is mechanized. (SPEC-013 lines 43, 59, 85)
- **Atomic index writes.** `.claude/council/index.json` is updated via
  tmp+rename under `flock`, delegated to `skills/council/index-writer.sh`.
  A concurrent reader (the TaskCompleted hook) MUST never observe a partial
  write. (SPEC-013 line 101)
- **Output shape branching.** `verdict[]` and `finding[]` are first-class;
  every preset MUST declare exactly one. Phase 5 output, Phase 6 report
  template, Phase 7 feedback memory, and the TaskCompleted gate all branch
  on this field. (SPEC-013 lines 40–44, 82–83, 91, 105, 136)
- **Pure auditor.** The council MUST NOT propose fixes, MUST NOT modify
  files, MUST NOT audit user-authored claims, MUST NOT run automatically on
  every session or commit. (SPEC-013 lines 128–134)
- **No persistent council roles.** Investigators, Prosecutor, Advocate, and
  the (deferred) Domain Specialist are ephemeral — they are prompt-template
  variants injected into Task-tool subagent invocations, not entries in
  `agents/`. The only persistent agent is `council-judge`. (SPEC-013 lines 37, 134)

---

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
| `--plan <path>` | Audit a plan file for unverified assumptions | **Deferred — fail loud** |
| `--from-retro <anchor-id>` | Audit a fabrication anchor from `/retro` | **Deferred — fail loud** |
| `--task-id <id>` | Bind this run to an orchestrated task id | Supported |
| `--preset <name>` | Explicit preset selector (else inferred from scope) | Supported |
| `--why` | Print flavors used + specialist reasoning | **Deferred (SHOULD, COUNCIL-002)** |
| (no scope) | — | **Hard fail, non-zero exit** |

Scope exclusivity: exactly one of `<claim>`, `--session`, `--plan`, `--diff`,
`--from-retro` MUST be given. Multiple scope args or zero scope args MUST
cause `engine.sh` to exit non-zero with a clear stderr message. (SPEC-013
line 30)

Deferred scopes (`--plan`, `--from-retro`) MUST be recognized by the arg
parser and MUST fail loudly with the exact message:

```
error: --<flag> is not implemented in COUNCIL-001, planned for COUNCIL-002
```

…and exit non-zero. The engine MUST NOT silently accept them, treat them as
no-ops, or fall through to another scope. (Locked decision 8.)

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
| `spec_grep` | bool | If true, intake enriches raw input with applicable-specs bundle (diff-mode only in v1) |
| `feedback_memory_enabled` | bool | If false, Phase 7 is a no-op regardless of verdicts |
| `confidence_filter_threshold` | int 0–100 \| null | If set, findings/verdicts below this are filtered at emission (diff-mode: 80) |

**Concrete COUNCIL-001 presets:**

- **`generic`** — `output_shape: verdict[]`, flavors: `paranoid-ic` +
  `jaded-senior` (investigators) + `jaded-senior` (prosecutor) + `yolo-ic`
  (advocate), `spec_grep: false`, `feedback_memory_enabled: true`,
  `confidence_filter_threshold: null`.
- **`diff-mode`** — `output_shape: finding[]`, flavors: `logic`, `security`,
  `compliance`, `quality`, `simplification` as investigators + jaded-senior /
  yolo-ic for prosecution/defense, `spec_grep: true`,
  `feedback_memory_enabled: false` (SPEC-013 line 105; a code bug is not a
  fabrication), `confidence_filter_threshold: 80` (SPEC-013 line 44,
  SPEC-010 line 24).

### Task-id resolution

Fallback chain, evaluated left-to-right (SPEC-013 lines 119–120):

1. `--task-id <id>` command-line flag
2. `CLAUDE_TASK_ID` environment variable
3. **Unbound** (no task id — report filename has no suffix, no index row)

This fallback chain applies ONLY to direct command-path invocations
(`/council`, `/review-and-commit` → `engine.sh`). The SPEC-002 TaskCompleted
hook uses its own stdin-based task-id resolution and does NOT participate in
this fallback chain — the two paths are independent. (SPEC-013 line 125.)

When task-bound:
- Report filename MUST include `--<task_id>` suffix (Phase 6).
- Report frontmatter MUST include a `task_id: <id>` field (Phase 6).
- Engine MUST call `index-writer.sh` after writing the report file (Phase 6).

When unbound:
- Report filename MUST NOT have a `--<task_id>` suffix.
- Report frontmatter MUST NOT include a `task_id` field.
- Engine MUST NOT write to `.claude/council/index.json`.

Orchestrated-task invocations rely on SPEC-009's `CLAUDE_TASK_ID` export
(orchestrator's responsibility — not this engine's). Reference SPEC-009 line
46; do not re-specify here.

---

## Engine Phases

### Phase 0 — Intake

Parse args → resolve scope → resolve task id (fallback chain above) →
resolve preset (explicit or inferred) → validate mutually exclusive flags →
fail loud on deferred scopes → fail loud on no-scope invocation.

For diff-mode only: run spec-grep over the changed file paths against
`specs/**/*.md` MUST requirements and produce an "applicable-specs" bundle.
This bundle is appended to the raw input that Phase 1 receives. The diff
itself is the primary raw input; the spec bundle is context for claim
extraction. (SPEC-013 line 48, SPEC-010 line 29, taxonomy resolution doc
section 1.)

No user code runs in Phase 0. No subagents spawn. This phase is pure
validation + input assembly.

### Phase 1 — Claim Extraction

**When it runs:**
- `--session`, `--plan` (deferred), transcript-derived scopes: extraction
  runs over the transcript slice and produces a list of load-bearing claims.
- `--diff` (diff-mode): extraction runs over the diff + applicable-specs
  bundle and produces candidate **findings** (not claims-as-assertions) —
  the finding IS the assertion in diff-mode. (SPEC-013 line 48.)
- Single pasted claim (`"<claim>"`) and `--from-retro` (deferred): extraction
  is SKIPPED — the claim is already isolated. (SPEC-013 line 50.)

**Output shape (structured records):**

```
claim := {
  claim: string,
  source_locator: string,   // turn id / file:line / anchor id
  claim_type: "factual" | "causal" | "recommendation"
}
```

For diff-mode the record shape is parallel but records are candidate
findings with `{file, line, description}` — Phase 5 will finalize severity
and confidence.

**Budget:**
- Default claim budget: **10** per run. Configurable per preset (not
  per-invocation in COUNCIL-001 — hardcoded default until COUNCIL-002).
- When the extraction pass produces more than the budget, claims MUST be
  ranked by load-bearing weight (highest-stakes first) and truncated to the
  budget. The report MUST note the cap and list the un-audited claims.
  (SPEC-013 lines 51–52.)

**Implementation note:** claim extraction is performed by a Task-tool
subagent using `skills/council/prompts/claim-extractor.md`.
The extractor is itself blind — it sees raw transcript/diff, never prior
narrative or prior verdicts.

### Phase 2 — Parallel Investigation

**Spawn contract:**
- Spawn investigators via the Task tool with
  `subagent_type: "general-purpose"` (or `"Explore"` for code-heavy claims).
- **Minimum 2 investigators per claim with distinct flavor presets** (e.g.
  `paranoid-ic` + one other) to defeat monoculture. (SPEC-013 line 60.)
- One task per claim per flavor — investigators MUST spawn in parallel
  within a single message, subject to Task-tool concurrency limits.
- Investigators MUST NOT receive prior assistant narrative, prior verdicts,
  or prior advocate/prosecutor output. They see raw artifacts only.
  (SPEC-013 line 56.)

**Tool allowlist (read-only):**
`Read`, `Grep`, `Glob`, `Bash` for read commands only, MCP query tools.
No Write, Edit, MultiEdit, no Bash mutating commands. (SPEC-013 line 57.)
This allowlist is injected into the Task prompt by the investigator prompt
template; Task-tool spawns do not have per-invocation tool allowlists,
so enforcement is prompt-level + strike-rule at evidence-bundle validation.

**Evidence bundle schema (required return shape):**

```
evidence_bundle := {
  tool_use_id: string,            // MANDATORY
  raw_blob: string,                // raw tool output, NOT paraphrased
  file_line: string,               // "path/to/file:42" or equivalent locator
  reproducible_command: string     // e.g. "grep -n 'foo' path/to/file"
}
```

**Validation (strike rule):** Bundles missing `tool_use_id` MUST be treated
as "no evidence collected" for that claim. The engine MUST NOT accept a
bundle that paraphrases a tool output instead of inlining the raw blob.
(SPEC-013 line 59.)

### Phase 2.5 — Blind Cross-Review

Anonymized peer-ranking of the Phase 2 evidence bundles by the investigators
themselves, aggregated by Borda count into a consensus quality score per
bundle. This phase is implemented in the council pipeline (driven by
`commands/council.md`; its Cross-Review section is rendered into both
`templates/report-verdict.md` and `templates/report-finding.md` — Phase 2.5 is
not shape-gated; the reviewer prompt is `prompts/cross-reviewer.md`).

**Spawn contract:**
- For N investigators, spawn N cross-reviewers via the Task tool
  (`subagent_type: "general-purpose"`), in parallel.
- Each reviewer sees every bundle **EXCEPT its own** (self-exclusion) — never
  investigator identities, prior narrative, or prior verdicts. (SPEC-013
  lines 80–82.)

**Anonymization:** Bundles are stripped of investigator identity and assigned
random labels (`A`, `B`, `C`, …). The `label → bundle` mapping is shuffled
**independently per reviewer** to defeat position bias. (SPEC-013 line 80.)

**Tool allowlist:** Cross-reviewers MUST NOT run any tools — evaluation is over
the submitted bundles only, never raw artifacts. (SPEC-013 line 82.)

**Aggregation (Borda count):** Each reviewer returns a `RANKING: X > Y > Z`
line; an invalid/missing line is an abstain. Rankings are mapped back to bundle
identities and summed into a Borda consensus score per bundle. The ranked list
(stable-sorted, original submission order as tiebreaker) is passed to **Phase 4
and Phase 5 ordered by Borda consensus rank, not submission order.** (SPEC-013
lines 83–84.)

**WEAK_EVIDENCE:** Bundles in the bottom Borda quartile (score ≤ the
25th-percentile threshold) MUST be flagged `WEAK_EVIDENCE` in the report.
(SPEC-013 line 85.)

**Bypass:** When fewer than 3 investigators participate — or every reviewer
response is rejected — Phase 2.5 is SKIPPED; bundles pass through in original
submission order and the bypass reason is noted in the report. (SPEC-013
line 86.)

`commands/council.md` stores the per-reviewer rankings and consensus scores for
the `{{CROSS_REVIEW_RANKINGS}}` / `{{CROSS_REVIEW_SCORES}}` report variables
(audit trail; SPEC-013 line 87).

*Traceability:* SPEC-013 lines 79–86. SPEC-013 tags this phase
*(COUNCIL-002)*, but unlike the Phase 3 domain specialist (a true v1 no-op),
Phase 2.5 is live in the council pipeline.

### Phase 3 — Domain Specialist (DEFERRED TO COUNCIL-002)

**Status:** Reserved in the protocol. Implemented as a **no-op in v1**.

The protocol reserves this phase so COUNCIL-002 can introduce dynamic
specialist pull (`devops` / `ds` / `qa` / `pm` agents as additional
investigators for domain-matching claims, per SPEC-013 lines 62–69) without
rearchitecting the pipeline. In COUNCIL-001 the engine MUST NOT inspect
claim topics, MUST NOT pull any specialist agent, and MUST NOT attempt
dynamic agent selection.

The phase exists in the protocol so downstream consumers (Phase 4, Phase 5)
can be written as if specialist evidence might appear in the bundle set,
even though in v1 it never does.

### Phase 4 — Prosecution & Defense

**Applies to `verdict[]`-shape runs only.** In `finding[]`-shape runs
(diff-mode), Phase 4 is **skipped** — specialist findings route directly to
the Judge with no prosecutor/advocate step (the engine's investigation plan
emits `4_prosecution_defense: {skipped: true}` for that shape). See
`skills/review-and-commit/SKILL.md` ("Phase 4 — skipped in diff-mode").

**Spawn contract (verdict[]-shape):**
- Spawn exactly **one** Prosecutor (flavor: `jaded-senior`) and exactly
  **one** Devil's Advocate (flavor: `yolo-ic`) per council run, in parallel.
  (SPEC-013 line 72.)
- Both roles are **BLIND to the original claims.** They receive **ONLY the
  evidence bundles** — not the original claim list, not the prior narrative,
  not each other's output. Each role reconstructs the set of claims under
  audit from the `claim_id` carried inside each bundle; it is never handed a
  separate claims list. Prosecution and defense operate on evidence alone.
  (SPEC-013 lines 89–94.)

**Output contract:**
- Prosecutor produces a brief: each claim → evidence against → requested
  verdict.
- Advocate produces a brief: each claim → evidence supporting → requested
  verdict.
- Both roles MUST NOT assert a fact unbacked by an investigator
  `tool_use_id`. Any such line MUST be struck by the engine before Phase 5.
  (SPEC-013 line 76.)

The single role-parameterized prompt template `prompts/phase4-brief.md`
encodes these constraints; the engine spawns it twice (as Prosecutor and as
Devil's Advocate).

### Phase 5 — Judgment

**Agent:** `agents/council-judge.md`. Structurally
forbidden from running tools via `tools: ""` in YAML frontmatter. (SPEC-013
lines 79–80, 86.)

**Engine passes to the Judge:**
1. Original claims (the list from Phase 1, not narrative summaries)
2. Evidence bundles (all bundles from Phase 2; Phase 3 is empty in v1)
3. Prosecutor brief (post-strike)
4. Devil's Advocate brief (post-strike)
5. Output shape flag (`verdict[]` or `finding[]`, from the active preset)

**Engine expects from the Judge:**

The verdict / finding / evidence schema below is the operational copy; the
canonical schema is normatively defined in
`specs/core/SPEC-013-adversarial-council-tribunal.md`.

For `verdict[]`-shape runs, a list of records:

```
verdict := {
  claim: string,                                             // original claim text
  verdict: "VERIFIED" | "PARTIALLY_VERIFIED" | "UNVERIFIED"
         | "CONTRADICTED" | "FABRICATED",
  confidence: integer 0..100,
  evidence_blob: string                                      // raw inline blob
}
```

For `finding[]`-shape runs (diff-mode), a list of records:

```
finding := {
  file: string,
  line: integer,
  severity: "critical" | "warning" | "nitpick",
  category: string,                                          // from specialist flavor
  description: string,
  suggestion: string,
  confidence: integer 0..100,
  tool_use_id: string                                        // MANDATORY
}
```

The fixed taxonomies above are enforced by the engine: any verdict with a
value outside the five-term set MUST be rejected and struck; any finding
with a severity outside the three-term set MUST be struck. (SPEC-013 lines
82–83.)

**Strike rule (engine-enforced after Judge returns):**
- Any verdict or finding line missing an inline raw evidence blob MUST be
  struck. (SPEC-013 line 85.)
- Any line whose quoted citation does not appear verbatim in the provided
  raw blob MUST be struck.
- Any line missing a `tool_use_id` (for findings) MUST be struck. (SPEC-013
  line 43.)
- Any line making a factual assertion not traceable to any evidence bundle
  MUST be struck.
- Struck lines MUST be preserved in an "audit trail" section of the report,
  never silently dropped. (SPEC-013 SHOULD line 146; treated as hard AC.)

The Judge reasoning is documented in `agents/council-judge.md` and the
`prompts/judge.md` template. This SKILL only documents what the engine
passes to and expects from the Judge — not how it decides.

### Phase 6 — Report & Persistence

**Canonical report path:**

- Unbound: `.claude/council/<YYYY-MM-DD>-<slug>.md`
- Task-bound: `.claude/council/<YYYY-MM-DD>-<slug>--<task_id>.md`

(SPEC-013 lines 89, 96–97.)

`<slug>` is a short kebab-case tag derived from the scope (e.g.
`session-last-20`, `diff-staged`, `claim-<first-5-words>`). The engine MUST
create the `.claude/council/` parent directory if absent. The engine MUST
resolve `$MROOT` with the worktree-aware formula (SPEC-013 line 93):

```
_gc=$(git rev-parse --git-common-dir 2>/dev/null) \
  && MROOT=$(cd "$(dirname "$_gc")" && pwd) \
  || MROOT=$(pwd)
```

**Report frontmatter (YAML):**

```yaml
scope: "<claim | session | plan | diff | from-retro>"
preset: "<preset-name>"
output_shape: "<verdict[] | finding[]>"
created_at: "<ISO-8601 UTC>"
task_id: "<id>"   # present IFF task-bound
```

The `task_id` field MUST be absent when unbound — not null, not empty
string. (SPEC-013 line 97.)

**Report body (branches on output shape):**

Both shapes MUST include: scope, extracted claims (or candidate findings),
investigator flavors used, evidence bundles (inlined raw blobs), Prosecutor
brief, Devil's Advocate brief, per-claim verdict or per-finding entry with
confidence + raw evidence, a **struck-lines audit trail** section.
(SPEC-013 line 90.)

- `verdict[]` template (`templates/report-verdict.md`): verdict summary
  grouped by taxonomy (VERIFIED / PARTIALLY_VERIFIED / UNVERIFIED /
  CONTRADICTED / FABRICATED counts).
- `finding[]` template (`templates/report-finding.md`): findings summary
  grouped by severity (critical / warning / nitpick counts).

(SPEC-013 line 91.)

**Stdout summary (engine prints this after writing the report):**

```
Council report: <relative path>
Scope: <scope>
Preset: <preset> (<output_shape>)
<verdict counts OR finding counts by severity>
<struck lines count>
```

(SPEC-013 line 92.)

**Index writer (task-bound runs only):**

After the report file is written, the engine MUST append a row to
`.claude/council/index.json` by shelling out to
`skills/council/index-writer.sh`. The engine MUST NOT
open, read, or write `index.json` directly — `index-writer.sh` is the sole
writer and owns the atomic tmp+rename + `flock` semantics. (SPEC-013 lines
98–101.)

Index row schema (produced by `index-writer.sh`):

```json
{
  "report_path": "<absolute or MROOT-relative path>",
  "max_verdict_confidence": <int 0..100 | null>,
  "max_finding_confidence": <int 0..100 | null>,
  "created_at": "<ISO-8601 UTC>"
}
```

Per-shape population rule:
- `verdict[]` runs: `max_verdict_confidence` = `max(confidence)` across all
  unstruck verdicts; `max_finding_confidence = null`.
- `finding[]` runs: `max_finding_confidence` = `max(confidence)` across all
  unstruck findings; `max_verdict_confidence = null`. (SPEC-013 line 102.)

The TaskCompleted hook (SPEC-002) reads this index as its single source of
truth and ignores rows with `max_verdict_confidence: null` when gating.
Finding-shape runs therefore never satisfy a `requires_council: true` gate —
diff-mode is code review, not a fabrication audit. (SPEC-013 lines 122,
135–136.) The hook's behavior is authoritative in SPEC-002; this SKILL does
not re-specify it.

**Hard rule:** The engine MUST NOT fall back to filename scanning of
`.claude/council/*.md` if the index is missing or unreadable. A missing
index row is a hard miss. (SPEC-013 line 124.)

### Phase 7 — Learning Loop (Feedback Memory)

**Scope:** `verdict[]`-shape presets ONLY. `finding[]`-shape presets (i.e.
`diff-mode`) MUST NOT trigger feedback memory writes. Additionally, any
preset with `feedback_memory_enabled: false` MUST skip this phase entirely.
(SPEC-013 line 105.)

**Trigger thresholds (configurable via `.claude/settings.json`):**

| Setting key | Default | Trigger |
|---|---|---|
| `council.feedback.fabricated_min` | 70 | Auto-write on `verdict == FABRICATED && confidence >= 70` |
| `council.feedback.unverified_min` | 85 | Auto-write on `verdict == UNVERIFIED && confidence >= 85` |

(SPEC-013 lines 106–107, 111.)

**Feedback memory entry structure (required fields):**

```
- claim: "<verbatim false claim>"
- contradicting_evidence: "<raw blob excerpt + tool_use_id>"
- should_have_run: "<the tool + command that would have caught this>"
- Why: "<one-line explanation of the failure mode>"
- How to apply: "<one-line rule the agent should adopt>"
```

(SPEC-013 line 108.)

**Routing:**
- **Plain-Claude subject** (no team agent authored the claim): append the
  entry to `$MROOT/.claude/memory/claude/lessons.md`. (SPEC-013 line 109.)
- **Team-agent subject** (claim authored by pm / tech-lead / ic5 / ic4 /
  devops / qa / ds): route through `/adjust-agent <agent> --apply` — this
  preserves SPEC-001 conflict detection and SPEC-012 routing convention.
  The engine MUST NOT write directly to `.claude/memory/<agent>/directives.md`.
  (SPEC-013 line 110.)

Detection of "who authored the claim" is done at Phase 1 extraction time
using source locators (turn metadata / agent attribution on the transcript
slice). When authorship is ambiguous, default to plain-Claude routing.

---

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

(SPEC-013 line 36.)

**Body:** a Markdown system-prompt delta. The engine injects this body into
the role's base prompt template via a `{{FLAVOR_DELTA}}` placeholder. Keep
each flavor file under 60 lines; the delta is a focus lens, not a full
prompt.

**Committed flavor set (COUNCIL-001):**
- `paranoid-ic.md` — hostile-read investigator; demands receipts for
  every asserted fact.
- `jaded-senior.md` — prosecutor flavor; has seen every failure mode;
  assumes the claim is wrong until evidence proves otherwise.
- `yolo-ic.md` — advocate flavor; argues the claim is true; exists to
  defeat prosecutor monoculture.
- `logic.md`, `security.md`, `compliance.md`, `quality.md`,
  `simplification.md` — diff-mode specialist investigators; the 5
  focus areas migrated from the pre-refactor `skills/review-and-commit/SKILL.md`.

---

## Prompt template schema

Role prompt templates live at `skills/council/prompts/<name>.md`. Files:

- `claim-extractor.md` — runs in Phase 1
- `investigator.md` — runs in Phase 2 (one per claim per flavor)
- `phase4-brief.md` — runs in Phase 4 (spawned twice: once as Prosecutor, once as Devil's Advocate, parameterized by role)
- `judge.md` — delivered to the `council-judge` agent in Phase 5

Templates are Markdown with `{{VARIABLE}}` placeholders. `engine.sh`
substitutes variables before invoking the Task tool or the judge agent.

**Documented variables per template:**

| Template | Variables |
|---|---|
| `claim-extractor.md` | `{{SCOPE_TYPE}}`, `{{INPUT_TEXT}}`, `{{CLAIM_BUDGET}}` |
| `investigator.md` | `{{CLAIM_TEXT}}`, `{{SOURCE_LOCATOR}}`, `{{RAW_ARTIFACTS}}`, `{{FLAVOR_DELTA}}` |
| `cross-reviewer.md` | `{{CLAIM_TEXT}}`, `{{BUNDLE_BLOCK}}` |
| `phase4-brief.md` | `{{ROLE}}`, `{{ROLE_BIAS}}`, `{{EVIDENCE_FIELD}}`, `{{EVIDENCE_BUNDLES}}`, `{{FLAVOR_DELTA}}` |
| `judge.md` | `{{ORIGINAL_CLAIMS}}`, `{{EVIDENCE_BUNDLES}}`, `{{PROSECUTOR_BRIEF}}`, `{{ADVOCATE_BRIEF}}`, `{{OUTPUT_SHAPE}}` |

Templates MUST NOT include `{{ASSISTANT_NARRATIVE}}` or any similar variable
that would leak prior model output into a blind role. Enforcing this is
primarily a code review discipline (the prompt templates are reviewed against this rule).

---

## Interaction with other components

| Component | Relationship |
|---|---|
| `skills/council/index-writer.sh` | **Sole writer** of `.claude/council/index.json`. The engine shells out to this helper in Phase 6; never opens the index file directly. |
| `skills/orchestrate/task-store.sh` | Writes `.claude/tasks/<task_id>.json` with task metadata (including `requires_council: true`). The engine does NOT write to this file; the orchestrator owns it. Referenced by SPEC-009. |
| `agents/council-judge.md` | The Judge agent invoked in Phase 5. Empty tool allowlist. |
| `skills/review-and-commit/SKILL.md` | Calls this engine with `--preset diff-mode` (or `--diff` with inferred preset). Must not carry a parallel pipeline. |
| `commands/council.md` | Thin wrapper; passes CLI args through to `engine.sh` unchanged. |
| `.claude/hooks/task-completed.sh` | **Reads** `.claude/council/index.json` to apply the `requires_council` gate. Never calls the engine. Authoritative behavior is SPEC-002's domain — referenced here, not re-specified. |
| `commands/retro.md` | Prints `Consider: /council --from-retro <anchor-id>` as a hint. Does NOT auto-invoke. The `--from-retro` scope fails loud in COUNCIL-001 — users will see the fail-loud message, which is correct (SPEC-013 line 114, locked decision 8). |

---

## Failure modes

Every failure mode has a distinct exit code and a stderr message contract.
Callers (`commands/council.md`, `skills/review-and-commit/SKILL.md`) rely on
exit codes to decide whether to continue.

| Exit | Meaning | Stderr message contract |
|---|---|---|
| 0 | Success | none on stderr |
| 2 | No scope argument supplied | `error: no scope specified — pass one of "<claim>", --session, --diff, --plan, --from-retro` |
| 2 | Multiple scope arguments | `error: scope arguments are mutually exclusive — got: <list>` |
| 3 | Deferred scope: `--plan` | `error: --plan is not implemented in COUNCIL-001, planned for COUNCIL-002` |
| 3 | Deferred scope: `--from-retro` | `error: --from-retro is not implemented in COUNCIL-001, planned for COUNCIL-002` |
| 4 | Unknown preset | `error: unknown preset: <name> — known: generic, diff-mode` |
| 5 | No investigators could spawn | `error: Phase 2 produced zero evidence bundles — aborting (no claims could be verified)` |
| 6 | Index write failure | `error: failed to update .claude/council/index.json — see index-writer.sh stderr` |
| 7 | Judge returned malformed output | `error: Phase 5 judge output failed schema validation — see report audit trail` |
| 8 | Judge refused output | `error: Phase 5 judge returned empty result — council aborted` |

Exit code 3 is reserved for deferred-scope fail-loud per locked decision 8.

---

## Deferred to COUNCIL-002

The following are explicitly **out of scope** for COUNCIL-001. Each MUST
either fail loud (if user-reachable via CLI) or be a protocol-reserved no-op
(if an internal phase).

- **`--plan <path>` scope** — arg parser MUST recognize it and fail loud
  with the COUNCIL-002 message. No plan-file ingestion, no per-assumption
  extraction. (SPEC-013 line 27, locked decision 8.)
- **`--from-retro <anchor-id>` scope** — arg parser MUST recognize it and
  fail loud with the COUNCIL-002 message. `/retro` still prints the hint
  but running the hinted command fails — this is correct, documented,
  and expected v0.18.0 behavior. (SPEC-013 line 29, locked decision 8.)
- **Phase 3 dynamic domain specialist** — no-op in v1. The engine MUST NOT
  inspect claim topics or attempt agent pull. Phase 3 exists in the protocol
  for v2 extensibility. (SPEC-013 lines 62–69.)
- **`--why` flag** — SHOULD in SPEC-013 line 145; not implemented. Arg
  parser may accept or fail loud — either is fine; prefer fail loud for
  consistency.
- **Per-phase token usage reporting** — SHOULD in SPEC-013 line 144; not
  implemented.
- **Investigator tool-call caching within a run** — SHOULD in SPEC-013 line
  143; not implemented. Each investigator spawn is independent.
- **Per-invocation preset overrides** — in COUNCIL-001, `confidence_filter_threshold`
  and `claim_budget` are hardcoded per preset. COUNCIL-002 may expose
  CLI overrides.

---

## Traceability: SPEC-013 MUST → section

| SPEC-013 lines | Requirement | Covered in |
|---|---|---|
| 24–30 | Command shape & scope | Invocation Contract → CLI arguments |
| 33–37 | Engine architecture (skill + thin wrapper, no parallel pipeline) | Overview, Interaction table |
| 40–44 | Output shapes (verdict[]/finding[], tool_use_id, confidence scale) | Invariants, Presets, Phase 5 |
| 46–52 | Phase 1 claim extraction (budget, ranking, skip rules, diff-mode enrichment) | Phase 1 |
| 54–60 | Phase 2 investigation (parallel, blindness, read-only, evidence bundle, ≥2 flavors) | Phase 2 |
| 62–69 | Phase 3 domain specialist | Phase 3 (deferred) |
| 79–87 | Phase 2.5 blind cross-review (anonymized peer ranking, Borda consensus, WEAK_EVIDENCE, <3-investigator bypass) | Phase 2.5 |
| 89–94 | Phase 4 prosecution + defense (evidence-only, strike rule) | Phase 4 |
| 96–104 | Phase 5 judgment (council-judge agent, taxonomies, strike rule, empty allowlist) | Phase 5 |
| 106–121 | Phase 6 report + verdict index (path, frontmatter, atomic writes, null columns) | Phase 6 |
| 122–130 | Phase 7 feedback memory (verdict[]-only, thresholds, routing, settings keys) | Phase 7 |
| 131–135 | Integration hooks (retro hint, requires_council, no global enable) | Interaction table |
| 136–144 | Task-ID plumbing (fallback chain, command-path only, post-replan clarification) | Task-id resolution |
| 145–157 | Scope exclusions (no writes, no fixes, not automatic, verdict[]-only gate) | Invariants, Phase 7 |

Every MUST in SPEC-013 traces to a section above. If a future edit to
SPEC-013 adds a MUST without a corresponding section here, that is a bug in
this file — update this file to cover it.
