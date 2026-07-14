---
name: council
description: |
  Adversarial council tribunal — reality-checks claims with material evidence.
  Spawns blind investigators, prosecutor, devil's advocate, and a tool-less
  judge. Issues per-claim verdicts with confidence scores. Use mid-session
  to audit a shaky claim, after a debug session to verify "all green", or
  on a plan file to find unverified assumptions. Shares an engine with
  /review-and-commit (diff-mode preset).
argument-hint: '"<claim>" | --session [--last N] | --diff | --plan <path> | --from-retro <id> [--task-id <id>] [--workflow]'
agent: build
---

# Council

Thin wrapper around the adversarial council tribunal engine. Parses user
arguments, invokes `skills/council/engine.sh` for deterministic scaffolding,
then drives the LLM tribunal phases (claim extraction, parallel investigation,
prosecution, defense, judgment) via Task tool subagent spawns — or, on opt-in,
via the Workflow driver `skills/council/workflow.js`. Writes a structured
report to `.claude/council/` and, for task-bound runs, appends a verdict row
to `.claude/council/index.json`.

## Arguments

- `/council "<claim text>"` — audit a single pasted claim
- `/council --session [--last N]` — audit a slice of the current session transcript
- `/council --diff` — audit staged diff (equivalent to /review-and-commit dispatch path)
- `/council --plan <path>` — audit a plan file for unverified assumptions (Phase 1 uses `plan-extractor.md`)
- `/council --from-retro <anchor-id>` — audit a /retro fabrication anchor (reads `$MROOT/.claude/retro/anchors/<id>.json`)
- `/council --task-id <id>` — explicit task binding for verdict-to-task index entry
- `/council --workflow` — opt-in Workflow execution path (CDV-196); also `COUNCIL_WORKFLOW=1`
- `/council --why` — print short debug section after summary (flavors, Phase 3 specialist reason, claim budget, preset source)
- `/council` — no scope, fails loudly with usage

Scope flags are mutually exclusive. Exactly one of `"<claim>"`, `--session`,
`--diff`, `--plan`, or `--from-retro` must be supplied. `--workflow` is
orthogonal to scope (execution transport only).

## Step 0: Resolve roots

```bash
_gc=$(git rev-parse --git-common-dir 2>/dev/null) \
  && MROOT=$(cd "$(dirname "$_gc")" && pwd) \
  || MROOT=$(pwd)
WTROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
```

## Step 1: Locate the engine

```bash
# Locate the dev-team plugin root (PDH). Dev checkout first, else installed cache (highest version). Slug-free, sort -V.
PDH=$( [ -f skills/plugin-dir.sh ] && pwd || find ~/.claude/plugins/cache -path '*/dev-team/*/skills/plugin-dir.sh' 2>/dev/null | sort -V | tail -1 | xargs -r dirname | xargs -r dirname )
ENGINE_SH=$(bash "$PDH/skills/plugin-dir.sh" file skills/council/engine.sh)

if [ ! -x "$ENGINE_SH" ]; then
  echo "error: skills/council/engine.sh not found in the installed plugin cache" >&2
  exit 1
fi
```

## Step 2: Preflight

Translate the user CLI surface into the engine's `preflight` flags, then invoke
it. The engine does NOT accept the user-facing scope flags (`--session`,
`--diff`, etc.) directly — it takes a single `--scope <name>` plus a
`--scope-arg <value>` for whatever payload that scope carries. Translation:

| User invocation | Engine `preflight` args |
|---|---|
| `"<claim text>"` | `--scope claim --scope-arg "<claim text>"` |
| `--session` | `--scope session` |
| `--session --last N` | `--scope session --last N` |
| `--diff` | `--scope diff` |
| `--plan <path>` | `--scope plan --scope-arg <path>` (path must be readable; else exit 2) |
| `--from-retro <id>` | `--scope from-retro --scope-arg <id>` (loads `$MROOT/.claude/retro/anchors/<id>.json`; missing → exit 2) |
| `--task-id <id>` | `--task-id <id>` (passthrough) |
| `--why` | `--why` (passthrough) |

The engine validates scope, resolves task-id (via `--task-id` flag →
`CLAUDE_TASK_ID` env → unbound), resolves preset (`--scope diff` → `diff-mode`,
`--scope plan|from-retro|claim|session` → `generic`), fails loudly on missing
scopes, bad plan paths, or missing retro anchors (exit 2).

```bash
PDH=$( [ -f skills/plugin-dir.sh ] && pwd || find ~/.claude/plugins/cache -path '*/dev-team/*/skills/plugin-dir.sh' 2>/dev/null | sort -V | tail -1 | xargs -r dirname | xargs -r dirname )
ENGINE_SH=$(bash "$PDH/skills/plugin-dir.sh" file skills/council/engine.sh)
PLAN_FILE=$(mktemp "${TMPDIR:-/tmp}/council-plan.XXXXXX.json") \
  || { echo "council error: mktemp failed for PLAN_FILE"; exit 1; }

"$ENGINE_SH" preflight <translated-args> > "$PLAN_FILE"
EXIT=$?
```

Exit code handling:

- **Exit 2 (no scope / bad plan path / missing retro anchor / mutually exclusive scopes):** print
  engine's stderr verbatim and exit. Do NOT continue. Missing or unreadable
  `--plan` path and missing `--from-retro` anchor file are exit 2.
- **Exit 4 (unknown preset):** print engine's stderr verbatim and exit.
- **Exit 0:** `$PLAN_FILE` contains the investigation-plan JSON. Proceed to
  Step 3.

The investigation-plan JSON emitted by `preflight` contains at minimum:
`scope`, `scope_arg`, `resolved_claim` (claim text when `scope` is `from-retro`;
empty otherwise), `preset`, `output_shape`, `task_id` (or null),
`claim_budget`, `phases.1_claim_extraction.skip` (bool — true when extraction
should be skipped, i.e. for single pasted claims and `--from-retro`), and
`flavors` (array).

## Step 2.5: Execution-path routing (CDV-196)

Opt-in detection (true iff either condition holds):

| Input | Workflow path? |
|-------|----------------|
| no `--workflow`, `COUNCIL_WORKFLOW` unset/0 | **No** — Task path (Steps 3–4 below) |
| `--workflow` present | **Yes** if probe ok |
| `COUNCIL_WORKFLOW=1` | **Yes** if probe ok |
| opt-in + probe fail | **No** — fallback Task path |

```bash
PDH=$( [ -f skills/plugin-dir.sh ] && pwd || find ~/.claude/plugins/cache -path '*/dev-team/*/skills/plugin-dir.sh' 2>/dev/null | sort -V | tail -1 | xargs -r dirname | xargs -r dirname )
USE_WORKFLOW=0
# set USE_WORKFLOW=1 when user passed --workflow or COUNCIL_WORKFLOW=1
if [ "${COUNCIL_WORKFLOW:-}" = "1" ] || [ "${_COUNCIL_WORKFLOW_FLAG:-}" = "1" ]; then
  USE_WORKFLOW=1
fi
if [ "$USE_WORKFLOW" = "1" ]; then
  PROBE=$(bash "$PDH/skills/plugin-dir.sh" file skills/council/workflow-probe.sh)
  if ! bash "$PROBE"; then
    echo "council: Workflow unavailable; falling back to engine.sh" >&2
    USE_WORKFLOW=0
  fi
fi
```

When `USE_WORKFLOW=1`, drive the tribunal via `skills/council/workflow.js`
(Workflow tool / `agent()` schema steps). Pass the same scope payload as JSON
args (`scope`, `claim`/`scope_arg`, `task_id`, `input_text`, `raw_artifacts`,
…). The script runs `engine.sh preflight` + phases + `engine.sh finalize`
internally — **skip Steps 3–4 Task spawns**. Protocol:
`skills/council/SKILL.md` § Workflow execution path.

On Workflow dispatch error after a green probe (tool missing mid-session),
print the same stderr one-liner and continue with the Task path below.
Fallback is never a degraded report.

When `USE_WORKFLOW=0`, continue with Step 3 (Task path).

## Step 3: Drive the council tribunal phases

Read the investigation-plan JSON from `$PLAN_FILE`. The interpreting Claude
executes the phases below, spawning Task subagents as specified. All subagent
spawns for a given phase must be issued in a single message (parallel
execution). (Skipped when Step 2.5 selected Workflow.)

### Phase 1 — Claim Extraction

Run when `phases.1_claim_extraction.skip` is `false` in the investigation plan
(i.e. for `--session`, `--diff`, and `--plan` scopes). Skip for single pasted
claims and `--from-retro` — extraction is not needed when the claim is already
isolated.

Use the prompt path from `plan.phases.1_claim_extraction.prompt` (session/diff
→ `claim-extractor.md`; plan → `plan-extractor.md`).

**Session / diff** — spawn one Agent subagent:

```
description: "Extract claims from session"
subagent_type: "general-purpose"
prompt: skills/council/prompts/claim-extractor.md
  with substitutions:
    {{SCOPE_TYPE}}   ← plan.scope
    {{INPUT_TEXT}}   ← raw transcript slice / diff text (artifacts only, no prior narrative);
                       in diff-mode the applicable-specs bundle is prepended/concatenated
                       into INPUT_TEXT so the spec context still reaches the extractor
    {{CLAIM_BUDGET}} ← plan.claim_budget (default 10)
```

**Plan** (`plan.scope == "plan"`) — read the plan file at `plan.scope_arg`, then:

```
description: "Extract claims from plan"
subagent_type: "general-purpose"
prompt: skills/council/prompts/plan-extractor.md
  with substitutions:
    {{PLAN_PATH}}    ← plan.scope_arg (path as given to --plan)
    {{INPUT_TEXT}}   ← raw plan file contents (Read plan.scope_arg; artifacts only)
    {{CLAIM_BUDGET}} ← plan.claim_budget (default 10)
```

**From-retro / single claim** (`phases.1_claim_extraction.skip == true`) — do
not spawn an extractor. Build a one-element claim list:

```
claim.claim          ← plan.resolved_claim if scope is from-retro, else plan.scope_arg
claim.source_locator ← "retro:<anchor-id>" when scope is from-retro; else "cli:claim"
claim.claim_type     ← "factual"
```

When `plan.scope == "from-retro"`, optionally Read
`$MROOT/.claude/retro/anchors/<plan.scope_arg>.json` for
`evidence_for_fabrication` / `source_jsonl_path` to enrich `{{RAW_ARTIFACTS}}`
in Phase 2 (artifacts only — no prior narrative).

Receive the structured claim list: `[{ claim, source_locator, claim_type }]`.
Plan locators use `file:heading-path:line`. For diff-mode the records are
candidate findings `{ file, line, description }`.

**Spawn failure:** if the extractor spawn fails or returns unusable output →
orchestrator performs extraction with tools; set `degraded=true`. Protocol:
`skills/council/SKILL.md` § Spawn-failure degradation.

### Phase 2 — Parallel Investigation

For each claim from Phase 1 (or the single pasted / from-retro claim), spawn at
least 2 investigator Task subagents in parallel with distinct flavor presets.
Minimum: `paranoid-ic` flavor + at least one other (e.g. `jaded-senior`) to
prevent monoculture. Use `plan.flavors` to determine which flavors to spawn.

**Optional cache seed (CDV-211):** before spawning investigators, when
`plan.cache_dir` is set, best-effort pre-read files named in claim
`source_locator`s into the shared cache (reliability backstop if subagents
ignore cache-first instructions). For each unique path-like locator (strip
`:line` / `:heading-path:line` suffixes when present; skip non-file locators
like turn ids / `retro:…`):

```bash
# PLAN_FILE is session-held by the orchestrating Claude (created in Step 1); not a
# cross-fence shell export — same contract as finalize --plan-file below.
CACHE_DIR=$(jq -r '.cache_dir // empty' "$PLAN_FILE")  # lint-ok: C1
# for each unique file path P that exists and is readable:
key=$(printf '%s' "$P" | sha256sum | awk '{print $1}')
mkdir -p "$CACHE_DIR/reads"
# only write on miss — do not overwrite peer-written entries mid-run
[ -s "$CACHE_DIR/reads/$key.txt" ] || cat -- "$P" > "$CACHE_DIR/reads/$key.txt" 2>/dev/null || true
```
Empty/missing seed is fine — correctness unchanged. Do not seed narrative.

Spawn pattern (one Agent per claim per flavor):

```
description: "Investigate claim <N> (<flavor>)"
subagent_type: "general-purpose"
prompt: skills/council/prompts/investigator.md
  with substitutions:
    {{CLAIM_TEXT}}     ← claim.claim (verbatim)
    {{SOURCE_LOCATOR}} ← claim.source_locator
    {{RAW_ARTIFACTS}}  ← raw files / logs / diff / anchor evidence (artifacts only)
    {{FLAVOR_DELTA}}   ← contents of skills/council/flavors/<flavor>.md body
    {{CACHE_DIR}}      ← plan.cache_dir (per-run council-cache under TMPDIR)
    # tool allowlist is fixed in the investigator prompt body (not substituted)
```

**Blindness invariant:** do NOT pass prior assistant narrative, prior
verdicts, or prior advocate/prosecutor output to any investigator. Raw
artifacts only. Cache is shared across investigators of this run only.

Collect evidence bundles. Required schema per bundle:
```
{ tool_use_id, raw_blob, file_line, reproducible_command }
```

Bundles missing `tool_use_id` are treated as "no evidence collected" for
that claim. Do not discard them yet — pass the full set to Phase 4 and let
the engine finalize strike accounting.

**Spawn failure:** if any investigator spawn fails or returns unusable
output → orchestrator self-verifies that claim/flavor with tools; keep
usable peer bundles; set `degraded=true`. If all spawns fail and
self-verify yields ≥1 bundle, continue. Protocol:
`skills/council/SKILL.md` § Spawn-failure degradation.

### Phase 3 — Domain Specialist (CDV-209; before Phase 2.5)

Conditional pull of one team agent (`devops` / `ds` / `qa` / `pm`) as an
**additional blind investigator** when a claim's topic confidently matches.
Plan fields: `phases.3_domain_specialist` (`deferred: false`,
`confidence_threshold: 0.75`, `max_specialists_per_run: 1`,
`classifier_prompt`, `specialist_prompt`).

**Skip entirely (no classify, no spawn) when:**
- `plan.phases.3_domain_specialist.skipped == true` (diff-mode / `finding[]`
  — five flavor investigators already cover specialist axes), OR
- `plan.output_shape == "finding[]"`

Record runtime reason for `--why`:
`skipped (diff-mode)`.

**Otherwise — classify every claim:**

For each claim from Phase 1, spawn a cheap classifier Task (parallel OK):

```
description: "Classify claim topic for domain specialist"
subagent_type: "general-purpose"
prompt: skills/council/prompts/topic-classifier.md
  with substitutions:
    {{CLAIM_TEXT}}  ← claim.claim (verbatim)
```

Pass nothing else — no prior narrative, no other claims, no evidence bundles.
Classifier returns JSON:
`{topic, confidence, agent}` with `agent ∈ {devops,ds,qa,pm,null}`.

**Eligibility (orchestrator-enforced):**
1. Reject malformed / missing JSON → treat that claim as no-match.
2. Require `agent != null` AND `confidence >= plan.phases.3_domain_specialist.confidence_threshold`
   (default **0.75**). Below threshold → skip (never invent a specialist).
3. Cap **1 specialist per run** (`max_specialists_per_run: 1`): if multiple
   claims qualify, pick the **highest confidence**; ties keep Phase-1 claim
   order. Do not spawn a second agent even if topics differ.

Topic map (SPEC-013):

| Topic signal | Agent |
|---|---|
| deploy / infra / CI / Docker / K8s / rollout | `devops` |
| metrics / stats / ML / data-pipeline / a-b | `ds` |
| test / coverage / regression / fixture | `qa` |
| product / requirements / scope / user-story | `pm` |

If no claim qualifies → record `phase3_specialist_reason =
"skipped (no confident match)"` and pass Phase 2 bundles unchanged to Phase 2.5.

**When one claim qualifies — spawn the specialist:**

```
description: "Domain specialist investigation (<agent>) for claim <claim-id>"
subagent_type: "dev-team:<agent>"   # e.g. dev-team:devops — NOT general-purpose
prompt: skills/council/prompts/investigator.md
  with substitutions:
    {{CLAIM_TEXT}}      ← winning claim.claim (verbatim)
    {{SOURCE_LOCATOR}}  ← winning claim.source_locator
    {{RAW_ARTIFACTS}}   ← same raw artifacts as Phase 2 for that claim
    {{FLAVOR_DELTA}}    ← domain-specialist delta (below), NOT a flavor file
    {{CACHE_DIR}}       ← plan.cache_dir (same per-run cache as Phase 2)
```

`{{FLAVOR_DELTA}}` body (paste verbatim; substitute `<agent>` / `<topic>`):

```
DOMAIN SPECIALIST LENS (<agent>, topic=<topic>)
You are the project's <agent> agent acting as a council investigator for this
domain. Use domain judgment to pick the cheapest falsifying tool calls.
You remain BLIND: raw artifacts + claim only. Do NOT load prior council
reports, prior verdicts, or assistant narrative. Do NOT write files.
Return the same evidence-bundle schema as any investigator.
```

**Blindness + tools:** same as Phase 2 — read-only tools only; no prior
council reports; evidence-or-silence. Team-agent tool allowlists may be
broader than investigator flavors — the prompt still forbids Write/Edit and
mutating Bash; strike violations at bundle validation.

**Collect:** merge specialist evidence bundles into the Phase 2 set for the
winning claim (tag `investigator: "specialist:<agent>"` for audit). Pass the
full set to Phase 2.5 (specialist counts toward the ≥3-investigator bar).

**Spawn failure:** if classifier or specialist spawn fails → skip Phase 3
pull; keep Phase 2 bundles; set `degraded=true` only if specialist was
required mid-flight and self-verify cannot recover a bundle. Protocol:
`skills/council/SKILL.md` § Spawn-failure degradation.

**`--why` runtime string** (overwrite preflight stub when printing Step 5):
- pulled: `"<agent> (topic=<topic> conf=<confidence>)"` e.g. `devops (topic=deploy conf=0.91)`
- no match: `"skipped (no confident match)"`
- diff-mode: `"skipped (diff-mode)"`
- classifier error / all rejected: `"skipped (classifier unusable)"`

### Phase 2.5 — Blind Cross-Review

Anonymized cross-ranking of Phase 2 evidence bundles by the investigators
themselves (each reviewing peers, never their own bundle), aggregated by
Borda count to produce a quality-ranked bundle list for Phase 4 and Phase 5.

**Bypass check (do this first):**

Skip Phase 2.5 entirely if either:
- Fewer than 3 investigators participated (i.e. fewer than 3 bundles collected
  in Phase 2). Record bypass reason `"fewer than 3 investigators (N found)"`.
- Zero valid RANKING lines were collected after the cross-review round (every
  reviewer's response was rejected). Record bypass reason `"no valid
  cross-review rankings collected"`.

In either case, proceed to Phase 4 with the bundles in their original
submission order.

**Anonymization:**

- Assign a random label (`A`, `B`, `C`, …) to each bundle.
- Generate an independent `label → bundle` shuffled mapping for each
  reviewer, so reviewer 1 might see `A=bundle2, B=bundle0, C=bundle1` while
  reviewer 2 sees `A=bundle1, B=bundle2, C=bundle0`. Independent shuffles
  per reviewer defeat position bias.

**Spawn cross-reviewers in parallel:**

For each investigator (N investigators → N cross-reviewers), spawn one
ephemeral Task subagent. Each reviewer sees all bundles EXCEPT their own,
labeled with their personal shuffled mapping:

```
description: "Cross-review evidence bundles for claim <claim-id>"
subagent_type: "general-purpose"
prompt: skills/council/prompts/cross-reviewer.md
  with substitutions:
    {{CLAIM_TEXT}}    ← claim.claim (verbatim)
    {{BUNDLE_BLOCK}}  ← all bundles EXCEPT this reviewer's own,
                        labeled per this reviewer's shuffled mapping
```

Pass nothing else: do NOT pass investigator identities, prior narrative,
prior verdicts, or anything outside the bundles themselves.

**Collect RANKING lines:**

Each reviewer returns a `RANKING: X > Y > Z` line per the cross-reviewer
output schema. Reject any response missing a valid `RANKING:` line — treat
it as an abstain and exclude that reviewer from the Borda tally.

**Borda count:**

- For each reviewer's ranking over their presented set of `M = N − 1`
  bundles (self-exclusion removes their own): rank-1 vote = `M − 1` points,
  rank-2 = `M − 2` points, …, rank-M = `0` points.
- Map each reviewer's label ranking back to the original bundle identities
  using that reviewer's `label → bundle` mapping.
- Sum Borda points per bundle across all valid reviewers.
- Sort bundles descending by total Borda score.
- **Tiebreaker:** when two bundles share equal total Borda score, preserve
  their original submission order (stable sort — do not break ties
  arbitrarily).

**WEAK_EVIDENCE flagging:**

- Compute the 25th-percentile Borda score across all bundles as the
  threshold.
- Flag any bundle with score `≤ threshold` as `WEAK_EVIDENCE`.

Pass the ranked bundle list (with WEAK_EVIDENCE flags) to Phase 4; store
per-reviewer rankings and scores for `{{CROSS_REVIEW_RANKINGS}}` /
`{{CROSS_REVIEW_SCORES}}`.

**Spawn failure:** if cross-reviewer spawns fail → treat as Phase 2.5
bypass with reason `"cross-review spawns failed"`; set `degraded=true` if
not already. Protocol: `skills/council/SKILL.md` § Spawn-failure degradation.

### Phase 4 — Prosecution and Defense

Runs for `verdict[]`-shape only. In `finding[]`-shape (diff-mode) Phase 4 is
skipped — the plan emits `4_prosecution_defense: {skipped: true}` and
specialist findings route straight to the Judge (Phase 5). See
`skills/review-and-commit/SKILL.md`. For `verdict[]`-shape, spawn exactly one
Prosecutor and one Devil's Advocate in parallel:

```
Prosecutor:
  description: "Prosecute claims against evidence"
  subagent_type: "general-purpose"
  prompt: skills/council/prompts/phase4-brief.md
    with substitutions:
      {{ROLE}}             ← "Prosecutor"
      {{ROLE_BIAS}}        ← "You prosecute. Your default prior is the claim is
                             FALSE until the bundles overwhelmingly prove
                             otherwise. Be brutal: strike anything vague,
                             paraphrased, or that merely 'sounds right'. Demand
                             receipts."
      {{EVIDENCE_FIELD}}   ← "evidence_against"
      {{EVIDENCE_BUNDLES}} ← Borda-ranked evidence bundles from Phase 2.5
                             (or Phase 2 if Phase 2.5 was bypassed) — raw,
                             no narrative
      {{FLAVOR_DELTA}}     ← contents of skills/council/flavors/jaded-senior.md body

Devil's Advocate:
  description: "Defend claims with evidence"
  subagent_type: "general-purpose"
  prompt: skills/council/prompts/phase4-brief.md
    with substitutions:
      {{ROLE}}             ← "Devil's Advocate"
      {{ROLE_BIAS}}        ← "You defend, to prevent prosecutor monoculture.
                             Your bias is FOR the claim: look for any defensible
                             reading of the bundles that supports it, leaning
                             VERIFIED or PARTIALLY_VERIFIED. But concede when the
                             bundles truly contradict the claim — a dishonest
                             advocate is worse than no advocate."
      {{EVIDENCE_FIELD}}   ← "evidence_for"
      {{EVIDENCE_BUNDLES}} ← Borda-ranked evidence bundles from Phase 2.5
                             (or Phase 2 if Phase 2.5 was bypassed) — raw,
                             no narrative
      {{FLAVOR_DELTA}}     ← contents of skills/council/flavors/yolo-ic.md body
```

Both roles receive evidence bundles only — not the original claims, not each
other's output, not prior narrative. They are BLIND to the original claim
list and reconstruct the claims under audit from the `claim_id` carried inside
each bundle.

Collect: prosecutor brief, advocate brief.

**Spawn failure:** if prosecutor and/or advocate spawn fails → orchestrator
writes the missing brief(s) from evidence bundles with tools; set
`degraded=true`. Protocol: `skills/council/SKILL.md` § Spawn-failure degradation.

### Phase 5 — Judgment

Spawn the council judge via the Task tool using the agent definition at
`agents/council-judge.md`. That file declares `tools: ""` — the empty tool
allowlist is structurally enforced; the judge cannot call any tool.

```
description: "Judge claims from evidence"
subagent_type: "dev-team:council-judge"
prompt: skills/council/prompts/judge.md
  with substitutions:
    {{ORIGINAL_CLAIMS}}   ← original claim list from Phase 1 (verbatim records)
    {{EVIDENCE_BUNDLES}}  ← Borda-ranked evidence bundles from Phase 2.5
                           (or Phase 2 if Phase 2.5 was bypassed)
    {{PROSECUTOR_BRIEF}}  ← prosecutor brief (post Phase 4)
    {{ADVOCATE_BRIEF}}    ← advocate brief (post Phase 4)
    {{OUTPUT_SHAPE}}      ← plan.output_shape ("verdict[]" or "finding[]")
```

Receive the judge's verdict list or finding list.

**Spawn failure:** if judge spawn fails → orchestrator emits judge JSON from
evidence + briefs (do not grant tools to a spawned judge agent); set
`degraded=true`. Protocol: `skills/council/SKILL.md` § Spawn-failure degradation.

Expected schemas (canonical taxonomy/schema is normatively defined in SPEC-013; this is a quick reference):

```
verdict[]  → [{ claim, verdict, confidence, evidence_blob }]
  verdict values: VERIFIED | PARTIALLY_VERIFIED | UNVERIFIED | CONTRADICTED | FABRICATED

finding[]  → [{ file, line, severity, category, description, suggestion, confidence, tool_use_id }]
  severity values: critical | warning | nitpick
```

### Strike Enforcement (before finalize)

Before passing outputs to Step 4, scan prosecutor brief, advocate brief, and
judge output for lines that lack an investigator `tool_use_id` reference.
Collect these into a `struck_lines` array. The engine's finalize subcommand
expects this array as input.

Also strike:
- Any verdict with a value outside the five-term taxonomy
- Any finding with a severity outside the three-term taxonomy
- Any verdict or finding line missing an inline raw evidence blob

Struck lines must be preserved — never silently dropped.

## Step 4: Finalize and persist

Write collected outputs (evidence bundles, prosecutor brief, advocate brief,
judge output, struck_lines) to temp files, then call `engine.sh finalize`.

### Token usage collection (CDV-204; best-effort)

After each Task (or Workflow agent) spawn returns, **best-effort** scrape any
token-usage fields from the result envelope. Task envelope schema is
**unverified** — do not hard-depend on a specific field name. When a usable
integer is found, add it to a phase map:

| Phase | Key |
|-------|-----|
| Claim extraction | `1_claim_extraction` |
| Investigation (sum per claim/flavor) | `2_parallel_investigation` |
| Cross-review | `2_5_cross_review` |
| Prosecutor | `4_prosecution` |
| Advocate | `4_advocate` |
| Judge | `5_judge` |

Write a tokens JSON file (orchestrator-owned) before finalize:

```json
{
  "phases": { "1_claim_extraction": 2341, "5_judge": 12556 },
  "total": 14897,
  "source": "task_envelope"
}
```

`source` values: `task_envelope` | `workflow` | `partial` | `unavailable`.

- Some phases known, others missing → set `source: "partial"` and include only
  known positive ints (never invent `0` as real usage).
- No usable fields on any spawn → either omit the file, or write
  `{"phases":{},"source":"unavailable"}`. Finalize exits 0 either way and
  omits the Tokens block / frontmatter keys.
- Do **not** change `index.json` schema for tokens (CDV-187 is a later
  display-only consumer of the write path here).

```bash
PDH=$( [ -f skills/plugin-dir.sh ] && pwd || find ~/.claude/plugins/cache -path '*/dev-team/*/skills/plugin-dir.sh' 2>/dev/null | sort -V | tail -1 | xargs -r dirname | xargs -r dirname )
ENGINE_SH=$(bash "$PDH/skills/plugin-dir.sh" file skills/council/engine.sh)
TOKENS_FILE="${TMPDIR:-/tmp}/council-tokens-$$.json"  # lint-ok: C1
# write tokens JSON when any usable ints collected; else skip or source=unavailable
"$ENGINE_SH" finalize \
  --plan-file    "$PLAN_FILE" \  # lint-ok: C1
  --evidence-file "$EVIDENCE_FILE" \
  --judge-output  "$JUDGE_FILE" \
  [--task-id      "<task_id if present>"] \
  [--verification-mode self-verified]   # when degraded=true; else omit (defaults full)
  [--tokens-file  "$TOKENS_FILE"]       # CDV-204; omit when no file / unavailable
```

Finalize best-effort `rm -rf` of `plan.cache_dir` (CDV-211 council-cache under
TMPDIR). No orchestrator cleanup required.

When any phase set `degraded=true`, pass `--verification-mode self-verified`
so the report surfaces the marker `self-verified — refuters unavailable`
(frontmatter + Summary banner). See `skills/council/SKILL.md` § Spawn-failure
degradation.

The engine renders the report from the appropriate template
(`skills/council/templates/report-verdict.md` or `report-finding.md`),
writes it to `.claude/council/`, calls `skills/council/index-writer.sh`
for task-bound runs, and prints a stdout summary. When `--tokens-file`
carries usable data, the summary includes a `Tokens:` block and the report
frontmatter may gain `tokens_total` / `tokens_by_phase` (omitted when
unavailable).

Capture the engine's stdout. On non-zero exit, print engine stderr verbatim
and exit non-zero.

## Step 5: Print stdout summary

Print the engine's stdout summary verbatim. It will contain:

```
Council report: <relative path>
Scope: <scope>
Preset: <preset> (<output_shape>)
verification_mode=<full|self-verified>
<verdict counts or finding counts by severity>
<struck lines count>

Tokens:                    # only when --tokens-file had usable data (CDV-204)
  <phase_key>: <int>
  Total: <int>
```

When tokens are partial, the header is `Tokens (partial):`. When the harness
has no token fields, the entire Tokens block is omitted (never invent `0`).

### `--why` debug block (CDV-206)

If `plan.why == true`, print a short labeled debug section **after** the
summary (including any Tokens block; never before; never dump raw prompts).
Source fields from `plan.why_detail` (emitted by `engine.sh preflight --why`).
For `phase3_specialist`, prefer the **runtime** reason recorded in Phase 3
(overwrites preflight stubs `pending (runtime classify)` /
`skipped (diff-mode)`):

```
Why:
  preset: <why_detail.preset> (<why_detail.preset_source>)
  flavors: <why_detail.flavors joined by ", ">
  phase3_specialist: <runtime Phase 3 reason, else why_detail.phase3_specialist>
  claim_budget: <why_detail.claim_budget>
```

Optional one-line runtime notes (claim ranking / cap applied) may follow the
bullets when observed during Phases 1–3. Without `--why`, omit this section
entirely. The flag MUST NOT change verdicts or findings.

## Step 6: Surface struck lines

If the engine reported `struck_lines > 0`, print a one-line warning:

```
Warning: N verdict lines were struck for missing evidence — see <report path> Audit Trail section.
```

## Error Handling

- **No scope and no prior context** → engine exits 2 → print usage and exit
- **Missing/unreadable `--plan` path** → engine exits 2 → print stderr and exit
- **Missing/unreadable `--from-retro` anchor** → engine exits 2 → print stderr
  and exit (`$MROOT/.claude/retro/anchors/<id>.json` not found)
- **Unknown preset** → engine exits 4 → print stderr and exit
- **Engine not found** → print clear error mentioning expected paths and exit
- **Investigator returns no evidence** → legal "no evidence found" outcome;
  the judge marks the verdict UNVERIFIED with low confidence
- **Judge attempts to call a tool** → structurally impossible (empty tool
  allowlist) but if it happens, the evidence-or-silence rule strikes the
  affected lines
- **Phase 2 produces zero bundles** → attempt orchestrator self-verify first
  (`skills/council/SKILL.md` § Spawn-failure degradation); if still empty →
  engine finalize exits 5 → print stderr and exit. If self-verify yields ≥1
  bundle, continue with `--verification-mode self-verified`
- **Index write failure** → engine finalize exits 6 → print stderr and exit
- **Judge returned malformed output** → engine finalize exits 7 → print stderr and exit

## Rules

- This command does NOT write code. It orchestrates Task subagents and pipes
  their outputs through the engine.
- Investigators MUST be blind (no prior assistant narrative passed)
- Judge MUST NOT have any tool access (enforced by `agents/council-judge.md`)
- Every verdict line MUST be backed by an investigator tool_use_id
- Phase 3 (domain specialist, CDV-209): classify claims; pull at most one of
  devops/ds/qa/pm when confidence ≥ 0.75; skip on weak match and in
  diff-mode; run before Phase 2.5
- Phase 7 (feedback memory) is invoked by the engine for `verdict[]`-shape
  runs only; the command does not call it directly
- Missing scopes and missing retro anchors MUST fail loudly via engine exit
  code 2 — never silently
  substitute another behavior
