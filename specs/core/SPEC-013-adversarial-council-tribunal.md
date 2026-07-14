# SPEC-013: Adversarial Council Tribunal

**Status**: ACTIVE
**Category**: core
**Created**: 2026-04-09

---

## Overview

`/council` is an on-demand adversarial tribunal that reality-checks Claude's claims with material evidence. It addresses a recurring failure mode where the model produces confident narrative without touching reality — fabricating config failures, green-lighting deploys without correlating logs/metrics with the actual change, or asserting facts about code it never read.

The council is structured as a court: a **Prosecutor** (jaded senior) demands receipts, **Investigators** (paranoid ICs, blind and read-only) collect evidence with real tool calls, a **Devil's Advocate** (yolo IC) argues the claim is true to prevent prosecutor monoculture, a dynamic **Domain Specialist** is pulled per topic (devops/ds/etc.), and a dedicated `council-judge` agent (with an empty tool allowlist, optionally calibrated by `tech-lead`'s project cortex) serves as **Judge** — forbidden from running tools, issuing verdicts only from collected evidence.

Core architecture is an engine skill (`skills/council/`) with thin command wrappers. `/council` is the generic entry. `/review-and-commit` is refactored to call the same engine with a diff-mode preset, eliminating drift between the two adversarial systems. Integration updates have been applied to SPEC-002, SPEC-009, SPEC-010, and SPEC-012.

Source brainstorm: `.claude/plans/2026-04-09-brainstorm-council.md`

---

## MUST

### Command Shape & Scope
- MUST support `/council "<claim text>"` — audit a single pasted claim
- MUST support `/council --session` — audit a slice of the current session transcript
- MUST support `/council --session --last N` — audit last N turns only
- MUST support `/council --plan <path>` — audit a plan file for unverified assumptions
- MUST support `/council --diff` — audit staged diff (equivalent to `/review-and-commit` invocation path)
- MUST support `/council --from-retro <anchor-id>` — audit a fabrication anchor surfaced by `/retro`
- MUST refuse to run with no scope argument and no prior context (must fail loudly, not guess)
- MUST accept optional `/council --workflow` (or `COUNCIL_WORKFLOW=1`) as an execution-path selector orthogonal to scope flags — does not replace scope exclusivity rules; default remains engine.sh

### Engine Architecture
- MUST implement core logic as a skill at `skills/council/` (NOT duplicated inline in commands)
- MUST expose `commands/council.md` as a thin wrapper over the engine skill
- MUST refactor `skills/review-and-commit/SKILL.md` to call the same engine with a `preset: diff-mode` — MUST NOT maintain a parallel adversarial pipeline
- MUST define flavor presets as files in `skills/council/flavors/<name>.md` — each containing name, system-prompt delta, and tool allowlist
- For every council prompt template under `skills/council/prompts/`, that file's own `## Variables` table is the authoritative declaration of its `{{TEMPLATE_VARIABLE}}` contract; `commands/council.md` substitution blocks and `skills/council/SKILL.md`'s documented-variables table MUST name exactly the variables declared in each prompt's Variables table — no more (no dead substitutions), no fewer (no unsubstituted placeholders leaking into spawned subagents)
- MUST NOT register Prosecutor, Investigator, Devil's Advocate, or Domain Specialist as persistent team agents (no entries in `agents/`, no cortex, no `init-team` bootstrap) — `council-judge` is the sole exception, as it requires a persistent agent definition to enforce the empty-tool-allowlist invariant structurally

### Output Shapes
- MUST declare two first-class engine output shapes; every preset MUST declare which shape it emits:
  - `verdict[]` — schema: `{claim, verdict, confidence, evidence_blob}` where `verdict` is drawn from `VERIFIED | PARTIALLY_VERIFIED | UNVERIFIED | CONTRADICTED | FABRICATED`
  - `finding[]` — schema: `{file, line, severity, category, description, suggestion, confidence, tool_use_id}` where `severity` is drawn from `critical | warning | nitpick`
- MUST require every `finding` to carry a `tool_use_id` citing the Read/Grep that observed the cited `file:line` — evidence-or-silence applied to findings as to verdicts
- MUST treat confidence as a single 0–100 scale across both shapes; threshold semantics are declared per shape (diff-mode findings filter <80 at emission; verdicts carry confidence for downstream feedback-memory and TaskCompleted gates)

### Phase 1 — Claim Extraction
- MUST run a claim-extraction pass before investigation when scope is `--session`, `--plan`, or transcript-derived
- MUST enrich diff-mode raw input with the applicable-specs grep output (from diff-mode intake) before claim extraction runs; diff-mode claim extraction extracts candidate findings from the diff, not claims-as-assertions
- MUST produce a structured list of load-bearing assertions with: claim text, source locator (turn ID / file:line), claim type (factual / causal / recommendation)
- MUST skip the extraction pass when scope is a single pasted claim or `--from-retro <anchor-id>` (claim already isolated)
- MUST enforce a per-run claim budget (default: 10 claims) to prevent runaway cost
- MUST rank claims by load-bearing weight when the budget is exceeded (highest-stakes first)

### Phase 2 — Parallel Investigation
- MUST spawn investigators in parallel, one task per claim (up to the claim budget)
- MUST pass each investigator the raw artifacts (files, logs, diffs, plan text) required for the claim — MUST NOT pass the model's prior narrative or prior verdicts
- MUST forbid investigators from any write operation (read-only tool allowlist: Read, Grep, Glob, Bash for read commands, MCP query tools)
- MUST require each investigator to return an **evidence bundle** containing: tool_use_id, raw tool output blob, file:line citation, reproducible command
- MUST reject evidence bundles that lack a tool_use_id — the engine MUST treat such bundles as "no evidence collected"
- MUST spawn at least 2 investigators per claim with distinct flavor presets (paranoid-ic + at least one other) to defeat monoculture

### Spawn-failure degradation *(CDV-199)*

When a required Task spawn for an investigator, cross-reviewer, prosecutor,
advocate, specialist, or judge fails or returns unusable output (rate-limit,
refusal, empty/malformed return — any unusable spawn, not rate-limit-only):

- MUST have the **orchestrator** (the session driving `/council` or
  `/review-and-commit`) perform that role's work with real tools — MUST NOT
  treat the implementer's self-assertion as verification
- MUST set report frontmatter `verification_mode: self-verified` and include
  the exact marker string `self-verified — refuters unavailable` in the
  report body (via finalize `--verification-mode self-verified`)
- MUST continue finalize when self-verify yields ≥1 usable evidence bundle
  (or equivalent role output for non-investigator phases)
- MUST keep exit 5 when evidence is empty **and** self-verify was not
  attempted or still produced zero bundles
- MUST NOT invent local-agent routing for investigators (deferred; out of
  scope for this degradation path)
- Self-verified runs still satisfy `requires_council` when a task-bound
  index row is written — the marker is for audit visibility, not a gate block

Default (all spawns succeed): `verification_mode: full` and no banner.

### Phase 3 — Dynamic Domain Specialist *(CDV-209)*

Active. Topic classification via `skills/council/prompts/topic-classifier.md`;
dispatch in `commands/council.md`; plan fields from `engine.sh` preflight
(`phases.3_domain_specialist.deferred: false`). Runs after Phase 2 and
**before** Phase 2.5. Diff-mode (`finding[]`) MUST skip Phase 3 (flavor
investigators already cover specialist axes).

- MUST inspect each claim's topic and pull a domain specialist when a match exists:
  - Deploy / infra / CI / Docker / K8s claims → `devops` agent
  - Metrics / statistics / ML / data-pipeline claims → `ds` agent
  - Test / coverage / regression claims → `qa` agent
  - Product / requirements / scope claims → `pm` agent
- MUST NOT pull a specialist when no confident topic match is found
  (confidence threshold ≥ 0.75; weak signal → skip)
- MUST cap at most one specialist spawn per council run
- MUST treat the specialist as an additional investigator (blind to prior narrative, read-only, returns an evidence bundle)
- MUST NOT pull a specialist in diff-mode (`finding[]` / `--diff`)

### Phase 2.5 — Blind Cross-Review *(COUNCIL-002)*
- MUST anonymize evidence bundles before cross-review: strip investigator identity, assign random labels (A, B, C…), and shuffle label order independently per reviewer to defeat position bias
- MUST exclude each investigator from ranking their own bundle (self-exclusion)
- MUST forbid cross-reviewers from running any tools — evaluation is over submitted bundles only, not raw artifacts
- MUST aggregate per-reviewer rankings via Borda count into a consensus quality score per bundle
- MUST pass evidence bundles to Phase 4 (Prosecution & Defense) and Phase 5 (Judgment) ordered by Borda consensus rank, not submission order
- MUST flag bundles in the bottom Borda quartile as `WEAK_EVIDENCE` in the report
- MUST skip Phase 2.5 when fewer than 3 investigators participate (minimum for meaningful cross-ranking); proceed directly to Phase 4 and note the bypass reason in the report
- SHOULD record each reviewer's per-bundle rankings in the report as a visible audit trail

### Phase 4 — Prosecution & Defense
- MUST spawn exactly one Prosecutor and one Devil's Advocate per council run
- MUST pass both the evidence bundles from investigators, NOT the original claims — the Prosecutor and Devil's Advocate are BLIND to the original claim list and operate on evidence alone; each role groups bundles by the `claim_id` carried inside the bundles, never by a separately supplied claims list (the Judge in Phase 5 still receives the original claims — that seam is unchanged)
- MUST require Prosecutor to produce a brief listing each claim (by the `claim_id` in the bundles), the evidence against it, and a requested verdict
- MUST require Devil's Advocate to produce a brief listing each claim (by the `claim_id` in the bundles), the evidence supporting it, and a requested verdict
- MUST forbid Prosecutor and Devil's Advocate from making factual assertions not backed by an investigator tool_use_id — such lines MUST be struck by the engine

### Phase 5 — Judgment
- MUST route judgment to a dedicated `council-judge` agent defined at `agents/council-judge.md`; the `council-judge` agent MUST declare an empty tool allowlist in its YAML frontmatter. The Judge's authority is the evidence bundle plus its standing behavioral rules. The engine MAY prepend `tech-lead`'s project cortex to the Judge invocation for plausibility calibration, but this is OPTIONAL — the Judge is by-design evidence-only (empty tool allowlist, cannot run a recall/cortex-load path itself), so it MUST function correctly with no cortex injected
- MUST forbid the Judge from running any tool (Read, Grep, Bash, MCP, Write, Edit) — enforced structurally via tool allowlist
- MUST pass the Judge: original claims, evidence bundles, Prosecutor brief, Devil's Advocate brief
- MUST require, for `verdict[]`-shape presets, the Judge to produce a per-claim verdict from the fixed taxonomy: `VERIFIED | PARTIALLY_VERIFIED | UNVERIFIED | CONTRADICTED | FABRICATED`
- MUST require, for `finding[]`-shape presets, the Judge to emit findings from the fixed severity taxonomy `critical | warning | nitpick` — the Judge's job in diff-mode is to dedupe, cross-check citations, and strike unsupported findings, not to verdict-ify claims
- MUST require a 0–100 confidence score on each verdict or finding
- MUST require inline raw tool output blobs in the verdict (not paraphrased) — if the blob is missing or does not contain the quoted citation, the verdict line MUST be struck as unsupported
- MUST preserve the empty tool allowlist for the Judge across both output shapes

### Phase 6 — Report & Persistence
- MUST write a report to `.claude/council/<YYYY-MM-DD>-<slug>.md` (create parent dir if absent)
- MUST include in the report: scope, extracted claims, investigator flavors used, evidence bundles, Prosecutor brief, Devil's Advocate brief, per-claim verdict or per-finding entry with confidence and raw evidence
- MUST branch the report template on output shape: `verdict[]` presets emit a verdict summary by taxonomy (session/plan/claim scopes); `finding[]` presets emit a findings summary by severity (diff scope)
- MUST print a summary to stdout with verdict counts by taxonomy (or finding counts by severity for `finding[]`-shape presets) and a path to the full report
- MUST resolve the project root with the worktree-aware formula: `_gc=$(git rev-parse --git-common-dir 2>/dev/null) && MROOT=$(cd "$(dirname "$_gc")" && pwd) || MROOT=$(pwd)`

#### Task Binding & Verdict Index
- Report templates (`skills/council/templates/report-verdict.md`, `report-finding.md`) MUST carry a single YAML frontmatter block that includes `task_id: "{{TASK_ID}}"` (plus `scope`, `preset`, hard-coded `output_shape`, `created_at`, `verification_mode`); finalize substitutes `{{…}}` placeholders and MUST NOT prepend a second synthetic frontmatter block
- When a council run is associated with an orchestrated task (resolved via the fallback chain: `--task-id` flag → `CLAUDE_TASK_ID` env var → none), the report MUST include a `task_id` field in its frontmatter/header section and MUST write the report to `.claude/council/<YYYY-MM-DD>-<slug>--<task_id>.md`
- When no task id is resolved, finalize MUST strip the unbound `task_id` key entirely (not null, not empty string) so the field is absent from the report frontmatter, and the filename MUST NOT carry a `--<task_id>` suffix
- The engine MUST maintain a lightweight verdict index at `.claude/council/index.json` — a single JSON document shaped as `{ "<task_id>": [ { "report_path": string, "max_verdict_confidence": int, "max_finding_confidence": int, "created_at": ISO-8601 }, … ], … }`; entries are append-only per task_id (newest first), never mutated in place
- The engine MUST append a new index entry at the end of every task-bound council run, after the report file is written
- The verdict index MUST be the single source of truth queried by the SPEC-002 TaskCompleted hook — the hook MUST NOT scan `.claude/council/*.md` report files directly
- The engine MUST update the index atomically via write-to-tmp + rename (`.claude/council/index.json.tmp` → `.claude/council/index.json`) so a concurrent hook read never observes a partial write
- `finding[]`-shape runs MUST still populate `max_finding_confidence` in the index row but MUST leave `max_verdict_confidence` as `null` (the hook ignores findings-shape rows when gating)

### Phase 7 — Learning Loop (Feedback Memory)
- MUST scope Phase 7 to `verdict[]`-shape presets only; `finding[]`-shape presets (e.g., diff-mode) MUST NOT trigger feedback memory writes — a code bug is not a fabrication
- MUST auto-write a feedback memory when any verdict is `FABRICATED` with confidence ≥ 70
- MUST auto-write a feedback memory when any verdict is `UNVERIFIED` with confidence ≥ 85
- MUST structure each feedback memory with: the false claim, the contradicting evidence, the tool that should have been run before asserting it, a **Why:** line, a **How to apply:** line
- MUST write feedback memories to the plain-Claude lessons file (`$MROOT/.claude/memory/claude/lessons.md`) when the audited subject is a plain Claude session
- MUST route feedback memories for team-agent-authored claims through `/adjust-agent <agent> --apply` (consistent with SPEC-012 routing convention, preserves SPEC-001 conflict detection)
- MUST make the confidence thresholds configurable via `.claude/settings.json` (`council.feedback.fabricated_min`, `council.feedback.unverified_min`)

### Integration Hooks
- MUST add a `/retro` hint: when the retrospective detects a fabrication-pattern anchor, MUST print `Consider: /council --from-retro <anchor-id>` — MUST NOT auto-run council (SPEC-012 update required)
- MUST support an opt-in `requires_council: true` metadata field on orchestrated tasks; when present, the TaskCompleted hook MUST block completion until a council verdict exists with confidence ≥ threshold (SPEC-009 update required)
- MUST NOT enable any integration hook globally — all council invocations MUST be explicit (user-typed or opt-in task metadata)

#### Task-ID Plumbing
- `/council` MUST accept an optional `--task-id <id>` flag to explicitly bind a run to a specific orchestrated task
- The engine MUST resolve the active task id via the fallback chain: `--task-id <id>` flag → `CLAUDE_TASK_ID` environment variable → unbound
- Orchestrated-task council invocations MUST set `CLAUDE_TASK_ID=<id>` in the spawned council subprocess environment so ambient detection works even when the flag is omitted
- `task-completed.sh` MUST look up the completing task's id in `.claude/council/index.json` and apply `council.taskgate.min_confidence` to the maximum `max_verdict_confidence` across that task's entries — deferring to SPEC-002 for the authoritative hook behavior; this bullet exists only to name the index as the lookup surface
- When `requires_council: true` is declared on a task but no entry exists in `.claude/council/index.json` for that task id, the index miss is the canonical "no verdict exists" signal the SPEC-002 hook MUST fail on
- The engine MUST NOT fall back to filename pattern scanning when the index is missing or unreadable — a missing index is a hard miss, never a soft miss
- The `/council` command task-id fallback chain (`--task-id` flag → `CLAUDE_TASK_ID` env → unbound) applies only to direct command invocations; the SPEC-002 TaskCompleted hook uses its own stdin-based task-id resolution per SPEC-002 hook contract and does NOT participate in this fallback chain — the two paths are independent

### Scope Exclusions
- MUST NOT grant write access to any council role (Prosecutor, Investigator, Devil's Advocate, Domain Specialist, Judge)
- MUST NOT propose fixes in the verdict report — council is a pure auditor
- MUST NOT audit the user's claims — only model-authored output
- MUST NOT run council automatically on every session, commit, or retro
- MUST NOT replace `/retro` or `/orchestrate` — council composes with them
- MUST NOT register council members in `init-team` bootstrap
- MUST NOT persist investigator state between runs (ephemeral only, no cortex)
- MUST NOT gate TaskCompleted on `finding[]`-shape runs — diff-mode is code review, not a fabrication audit
- The TaskCompleted council gate MUST apply to `verdict[]`-shape runs only; `finding[]`-shape index rows MUST be ignored by the hook


### Council-on-Workflow execution path *(CDV-196)*

Optional Workflow-tool execution path for the tribunal. **Strict output parity**
with the default `engine.sh` + Task path: same verdict/finding schemas, same
`.claude/council/index.json` rows, same report files/naming. Judge stays tool-less
on both paths. Transparent fallback when Workflow unavailable. Reuse CDV-199
degradation marker — never invent a second string. Distinct from CDV-197
(`/fix-ticket` workflow promotion) — share authoring conventions only
(args-as-JSON-string guard).

- MUST keep `skills/council/engine.sh` as the canonical default execution path — the Workflow path activates only on explicit opt-in (`/council --workflow` flag or `COUNCIL_WORKFLOW=1` environment variable); with neither set, behavior is byte-for-byte today's engine.sh path
- MUST detect Workflow availability before relying on it (capability probe or attempt-and-fallback): when the Workflow tool is unavailable (free plan, or a Claude Code version below the Workflow minimum), the run MUST fall back transparently to engine.sh with a one-line stderr notice — never a hard failure, never a degraded report
- MUST preserve strict output parity with engine.sh: identical `verdict[]`/`finding[]` JSON schemas and taxonomies, identical `.claude/council/index.json` writes (same row shape, append-only, atomic tmp+rename), and identical report shape and naming at `.claude/council/<YYYY-MM-DD>-<slug>[--<task_id>].md` — downstream consumers (the SPEC-002 TaskCompleted gate, `/retro`) MUST NOT be able to tell which path produced a run
- MUST keep the Judge tool-less on the Workflow path: the judgment step MUST use agentType `council-judge` (plugin-qualified as installed, e.g. `dev-team:council-judge`) with an empty tool allowlist (Phase 5 invariant unchanged) — schema-forced output changes the transport, not the evidence-only design
- MUST use `agent()` schema-forced structured output for the investigator, Prosecutor, Devil's Advocate, and Judge steps; the Workflow path MUST NOT port the engine.sh JSON-repair layers forward — a schema violation on this path is a step failure, not a repair candidate
- MUST handle investigator/refuter spawn failures on the Workflow path with the same explicit self-verified-marker degradation as Spawn-failure degradation (CDV-199): pass `engine.sh finalize --verification-mode self-verified` so the report carries the exact marker `self-verified — refuters unavailable` — never silent role omission; never invent a parallel degradation string
- MUST single-source prompt and flavor bodies: the Workflow path reads the same `skills/council/prompts/*` and `skills/council/flavors/*` assets as the Task path, honoring each prompt's `## Variables` table contract — MUST NOT fork or inline-duplicate prompt content between the two paths
- MUST share Workflow authoring conventions with CDV-197 / fix-ticket workflow (adjacent, distinct): notably the args-may-arrive-as-JSON-string guard (`typeof args === 'string' ? JSON.parse(args) : args`)
- MUST implement the Workflow driver at `skills/council/workflow.js` and hand off plan + evidence + judge JSON files to **existing** `engine.sh finalize` (shared finalize — no dual report renderers)
- MUST document opt-in + fallback in `commands/council.md` and `skills/council/SKILL.md`; `/review-and-commit` MUST honor the same opt-in (`--workflow` or `COUNCIL_WORKFLOW=1`) and cite the council dual-path protocol (no parallel pipeline)


---

## SHOULD

- SHOULD rank claims in extraction phase by load-bearing weight (high-stakes claims audited first when budget is tight)
- SHOULD cache investigator tool calls within a single council run to avoid redundant file reads across claims (CDV-211: preflight creates `${TMPDIR:-/tmp}/council-cache-<run_id>/` with `reads/` + `greps/` keyed by sha256; plan emits `cache_dir` + `run_id`; investigator.md cache-first protocol via `{{CACHE_DIR}}`; optional orchestrator seed from claim locators; finalize best-effort rm; empty cache is correctness-neutral)
- SHOULD report per-phase token usage in the summary to make cost visible (CDV-204: finalize `--tokens-file` with phase→int map; optional report frontmatter `tokens_total` / `tokens_by_phase`; graceful omit when harness has no tokens — never invent `0` as measured usage; does not alter `index.json` schema)
- SHOULD support `--why` flag to print the flavor presets used and the reasoning behind domain specialist selection
- SHOULD surface struck verdict lines (evidence-less claims by Judge/Prosecutor/Advocate) in the report as a visible audit trail, not silently dropped
- SHOULD print a concise stdout summary by default and reserve the full report for the file

---

## Test

### Test 1 — Single claim audit with fabrication
1. Paste a known-false claim: `/council "the retry logic in commands/retro.md uses exponential backoff with jitter"`
2. Observe: investigators spawn, read `commands/retro.md`, return evidence bundles
3. Verify: Judge verdict is `FABRICATED` with confidence ≥ 70
4. Verify: report written to `.claude/council/<date>-*.md`
5. Verify: feedback memory written to `.claude/memory/claude/lessons.md` with Why/How-to-apply lines
6. Verify: raw file content appears inline in the report, not paraphrased

### Test 2 — Blind investigator guarantee
1. Invoke `/council --session --last 20` after a session where the model made a shaky claim
2. Inspect the spawned investigator task prompts (via task output)
3. Verify: investigator prompts contain raw artifacts (file contents, logs) but NOT prior narrative claims or assistant turn text
4. Verify: investigator tool_use_ids match the tool calls recorded in the evidence bundles

### Test 3 — Judge cannot run tools
1. Inspect the Judge invocation in the council engine
2. Verify: Judge's tool allowlist is empty of Read, Grep, Bash, Write, Edit, MCP query tools
3. Attempt to run council with a Judge that tries to call a tool (via test harness)
4. Verify: the attempt is blocked and the verdict is marked invalid

### Test 4 — Evidence-or-silence enforcement
1. Run a council where the Judge paraphrases a tool output instead of including the raw blob
2. Verify: the paraphrased verdict line is struck from the report
3. Verify: the struck line is visible in the report's audit trail (not silently dropped)

### Test 5 — `/review-and-commit` engine share
1. Run `/review-and-commit` on a staged diff after SPEC-013 implementation
2. Verify: it dispatches to the council engine with `preset: diff-mode`
3. Verify: the 5 original specialists (Logic, Security, Compliance, Quality, Simplification) are loaded as flavor presets from `skills/council/flavors/`
4. Verify: the verdict schema matches `/council` output (same taxonomy, same confidence score format)

### Test 6 — `/retro` integration hint
1. Run a session containing a fabricated claim, then `/retro`
2. Verify: `/retro` detects the fabrication anchor and prints `Consider: /council --from-retro <anchor-id>`
3. Verify: `/retro` does NOT auto-invoke `/council`

### Test 7 — Budget enforcement
1. Run `/council --session` on a large session with 50+ extractable claims
2. Verify: only the top N (default 10) claims are investigated
3. Verify: the report notes the budget cap and lists the un-audited claims

### Test 8 — Domain specialist selection (CDV-209)
1. Run `/council "the k8s rollout is healthy"`
2. Verify: topic classifier maps claim to deploy/devops with confidence ≥ 0.75
3. Verify: the `devops` agent is pulled as a domain specialist (blind investigator bundle)
4. Run `/council "the a/b test shows statistical significance at p<0.05"`
5. Verify: the `ds` agent is pulled
6. Run `/council "users love the new onboarding flow"` (no topic match)
7. Verify: no domain specialist is pulled, only default investigators
8. Run `/council --diff` (or any finding[] preset): Verify Phase 3 is skipped
9. Static: `engine.sh preflight` → `.phases["3_domain_specialist"].deferred == false`

### Test 9 — Task-bound council gate
1. Declare an orchestrated task with metadata `requires_council: true` and capture its id as `$TID`
2. Run `/council --task-id $TID --session --last 10` against a session containing a verifiable claim
3. Verify: report file is written to `.claude/council/<date>-<slug>--$TID.md` (task-id suffix present)
4. Verify: report frontmatter includes a `task_id: $TID` line
5. Verify: `.claude/council/index.json` exists and contains a `"$TID"` key whose newest entry points to the report written in step 3 with a populated `max_verdict_confidence`
6. Verify: `.claude/council/index.json` was written via tmp+rename (no partial-read window — `index.json.tmp` is absent post-run)
7. Set `council.taskgate.min_confidence` below the run's `max_verdict_confidence`, invoke `task-completed.sh` with `CLAUDE_TASK_ID=$TID`, verify exit code 0
8. Set `council.taskgate.min_confidence` above the run's `max_verdict_confidence`, invoke `task-completed.sh` with `CLAUDE_TASK_ID=$TID`, verify exit code 2 and stderr naming the blocked task id
9. Invoke `task-completed.sh` with `CLAUDE_TASK_ID=unknown-task`, verify the index-miss path fails with a clear "no verdict exists" stderr message
10. Run `/council --diff` (findings shape) bound to a separate task id, verify the resulting index row has `max_verdict_confidence: null` and the hook does NOT treat it as a qualifying verdict
11. Unset `--task-id` and rerun with `CLAUDE_TASK_ID=$TID` exported — verify the env fallback produces the same task-bound report path and index entry as step 3
12. Run plain `/council "<claim>"` with no flag and no env var — verify the report filename has no `--<task_id>` suffix and the index is not updated

### Test 10 — Blind Cross-Review ordering
1. Run `/council` with ≥ 3 investigators on a session containing a contested claim
2. Verify: cross-review prompts contain anonymized bundle labels (A/B/C) with no investigator identity present
3. Verify: each cross-reviewer's prompt omits their own bundle
4. Verify: label ordering differs between at least two reviewers' prompts (position-bias mitigation)
5. Verify: when bundles have unequal evidence quality, the Borda-ranked order in the report differs from submission order
6. Verify: Phase 4 Prosecution brief references bundles in Borda-ranked order
7. Run with exactly 2 investigators — verify Phase 2.5 is skipped and the report notes the bypass reason
8. Verify: any bundle in the bottom Borda quartile is labelled `WEAK_EVIDENCE` in the report

### Test 11 — Spawn-failure self-verified mode
1. Static: `skills/council/SKILL.md` and `commands/council.md` document spawn-failure degradation with marker `self-verified — refuters unavailable`
2. Run `engine.sh finalize` with fixtures and `--verification-mode self-verified` — report body contains the marker and frontmatter has `verification_mode: "self-verified"`
3. Run finalize without the flag (or with `full`) — report has no marker banner and `verification_mode: "full"`
4. Empty evidence still exits 5 when no self-verify path supplied usable bundles


### Test 12 — Council-on-Workflow opt-in default
1. With neither `--workflow` nor `COUNCIL_WORKFLOW=1` set, run `/council "<claim>"`
2. Verify the Workflow tool is never invoked and behavior matches today's engine.sh path

### Test 13 — Council-on-Workflow output parity
1. With opt-in set on a Workflow-capable install, run the same fixture claim set through both paths
2. Diff the verdict JSON, the `.claude/council/index.json` rows, and the report bodies (modulo timestamps/slug)
3. Verify no consumer-visible differences (strict parity)

### Test 14 — Council-on-Workflow transparent fallback
1. With opt-in set but Workflow unavailable (free plan, pre-Workflow CC, or `COUNCIL_WORKFLOW_FORCE_FALLBACK=1`)
2. Verify the run falls back to engine.sh with stderr notice `council: Workflow unavailable; falling back to engine.sh`
3. Verify successful non-degraded report (`verification_mode: full`) — no hard failure solely for missing Workflow

### Test 15 — Council-on-Workflow judge tool-less
1. Inspect `skills/council/workflow.js` judgment step
2. Verify it uses agentType `council-judge` (plugin-qualified) and `agents/council-judge.md` still has `tools: ""`
3. Verify a tool-call attempt by the Judge is blocked (Test 3 invariant holds on this path)

### Test 16 — Council-on-Workflow resume
1. Kill a Workflow-path tribunal mid-run and resume it
2. Verify the run continues from the last completed Workflow phase (not full restart from claim extraction)
3. Verify final artifacts still pass Test 13 parity (manual QA if CI cannot kill/resume)

### Test 17 — Council-on-Workflow spawn-failure degradation
1. Simulate an investigator/refuter spawn failure on the Workflow path
2. Verify the report and frontmatter carry exact marker `self-verified — refuters unavailable` via finalize `--verification-mode self-verified`
3. Verify no silent role omission; actor is the workflow driver/orchestrator, never implementer-of-subject

### Test 18 — Council-on-Workflow single-source prompts + args guard
1. Grep `skills/council/workflow.js` — verify it loads `prompts/*` and `flavors/*` at runtime with no forked prompt bodies
2. Verify args-as-JSON-string guard (`typeof args === 'string'`) is present
3. Verify marker string `self-verified — refuters unavailable` is NOT present in workflow.js (only via finalize flag)

### Test 19 — Council-on-Workflow no repair layers + token summary
1. Grep workflow.js for `PYREPAIR` / `repair_json` — expect zero hits
2. When Workflow budget API / Task envelope tokens are available, verify per-run (ideally per-phase) token usage appears in stdout summary via finalize `--tokens-file` (`Tokens:` block; optional FM `tokens_total` / `tokens_by_phase`)
3. When tokens file is missing, `source: unavailable`, or all null/≤0 — omit Tokens block and FM keys (exit 0; never invent `0` as real); partial phases print known rows under `Tokens (partial):`

### Test 20 — Plan-file scope (`--plan <path>`, CDV-208)
1. Static: `bash skills/council/engine.sh preflight --scope plan --scope-arg /nonexistent.md` exits **2** (not 3) with stderr naming the path
2. Static: preflight `--scope plan --scope-arg skills/council/fixtures/plan-scope-sample.md` exits **0**; JSON has `scope=plan`, `preset=generic`, `phases.1_claim_extraction.skip=false`, `phases.1_claim_extraction.prompt` ending in `plan-extractor.md`
3. Static: `skills/council/prompts/plan-extractor.md` exists; documents locator format `file:heading-path:line` and claim schema `{claim, source_locator, claim_type}`
4. Static: fixture `skills/council/fixtures/plan-scope-sample.md` contains one true claim (SQLite memory path) and one fabricated claim (Rust council crate)
5. Live (optional): `/council --plan skills/council/fixtures/plan-scope-sample.md` extracts ≥1 claim; investigators produce bundles; pipeline completes with verdicts

### Test 21 — From-retro scope (`--from-retro <anchor-id>`, CDV-212)
1. Static: preflight `--scope from-retro --scope-arg missing-id` exits **2** with stderr naming missing anchor path under `$MROOT/.claude/retro/anchors/`
2. Static: stage fixture `skills/council/fixtures/from-retro-anchor.json` to `$MROOT/.claude/retro/anchors/<anchor_id>.json`; preflight exits **0**; JSON has `scope=from-retro`, `preset=generic`, `phases.1_claim_extraction.skip=true`, `resolved_claim` matching fixture `fabricated_claim_text`, `scope_arg` = anchor id
3. Static: `/retro` single-writer contract — `commands/retro.md` persists anchors after validation; subagent emits JSON only
4. Live (optional): `/council --from-retro <id>` skips Phase 1 and runs Phase 2–5 against the isolated claim

---

## Validation

- [ ] `skills/council/` skill exists with engine protocol documented
- [ ] `commands/council.md` exists as a thin wrapper calling the engine
- [ ] `skills/review-and-commit/SKILL.md` refactored to call the engine with `preset: diff-mode` (SPEC-010 updated via `/update-spec`)
- [ ] `skills/council/flavors/` directory contains: paranoid-ic, jaded-senior, yolo-ic, plus the 5 review-and-commit specialists
- [ ] `agents/council-judge.md` exists with `tools: ""` and judges evidence-only (no self-loaded cortex/memory; any `tech-lead` cortex calibration is optional engine-prepended context, not a required load path); engine invokes `council-judge` (not `tech-lead`) for Phase 5
- [ ] Verdict taxonomy enforced structurally (not free-form)
- [ ] Feedback memory auto-write verified on `FABRICATED ≥70` and `UNVERIFIED ≥85`
- [ ] `.claude/council/` directory added to `.gitignore` conventions
- [ ] SPEC-012 updated with `/retro` → `/council` integration hint
- [ ] SPEC-009 updated with `requires_council: true` TaskCompleted gate flag
- [ ] SPEC-010 updated to reflect `/review-and-commit` delegation to council engine
- [ ] Settings keys `council.feedback.fabricated_min` and `council.feedback.unverified_min` documented in `/memory-config` or equivalent
- [ ] `.claude/council/index.json` exists after any task-bound run and is written atomically (tmp + rename)
- [ ] `task_id` field appears in report frontmatter and `--<task_id>` suffix appears in filename when a run is task-bound
- [ ] `CLAUDE_TASK_ID` env var fallback produces the same binding as the `--task-id` flag
- [ ] TaskCompleted gate queries `index.json` only (no filename scans) and applies to `verdict[]`-shape rows exclusively
- [ ] `skills/council/prompts/cross-reviewer.md` exists; council.md Phase 2.5 block describes N cross-reviewers spawned with per-reviewer shuffled labels, self-exclusion, Borda-ranked bundle output to Phase 4 and Phase 5, bottom-quartile WEAK_EVIDENCE flagging, and bypass recorded when < 3 investigators
- [ ] Spawn-failure degradation: `engine.sh finalize --verification-mode self-verified` writes marker `self-verified — refuters unavailable` + frontmatter `verification_mode`; default/full omits banner; protocol in SKILL.md + commands
- [ ] `--why` (CDV-206): preflight with `--why` emits `why: true` + `why_detail` (`preset`, `flavors`, `phase3_specialist`, `claim_budget`, `preset_source`); without flag `why` is not true and no debug section; `commands/council.md` Step 5 prints short labeled block after summary; no verdict impact, no raw prompt dumps
- [ ] Phase 3 domain specialist (CDV-209): `phases.3_domain_specialist.deferred==false`; `topic-classifier.md` present; council.md classifies → pull devops/ds/qa/pm at conf ≥ 0.75, cap 1/run, skip weak match + diff-mode; before Phase 2.5; `why_detail.phase3_specialist` runtime strings; Test 8
- [ ] Token usage (CDV-204): finalize `--tokens-file` prints `Tokens:` (or `Tokens (partial):`) when usable; omits when missing/unavailable/zeros; optional FM `tokens_total`/`tokens_by_phase`; `commands/council.md` best-effort collect + pass-through; index.json unchanged
- [x] Plan scope (CDV-208): `--plan <path>` preflight path-check exit 2 / live exit 0; `plan-extractor.md` + fixture; Test 20
- [x] From-retro scope (CDV-212): anchor files at `$MROOT/.claude/retro/anchors/<id>.json`; missing → exit 2; present → Phase 1 skip + `resolved_claim`; exit 3 deferred removed; Test 21
- [ ] Test 1–11 pass against the implementation
- [x] Proposed extension 'Council-on-Workflow execution path' implemented and promoted (CDV-196; Tests 12–19)
- [ ] Test 12–19 (Council-on-Workflow) pass against the implementation
- [ ] Test 20 (plan scope) pass against the implementation
- [ ] Test 21 (from-retro scope) pass against the implementation

---

## Version History

| Date | Change |
|------|--------|
| 2026-07-14 | CDV-209: Phase 3 dynamic domain specialist live — topic-classifier.md; engine `3_domain_specialist.deferred=false` (skip finding[]/diff-mode); classify → at most one of devops/ds/qa/pm when confidence ≥ 0.75; before Phase 2.5; why_detail runtime specialist strings; Test 8 active. |
| 2026-07-14 | CDV-212: `/council --from-retro <anchor-id>` live — preflight loads `$MROOT/.claude/retro/anchors/<id>.json` (exit 2 if missing); preset `generic`; Phase 1 skip; `resolved_claim` in investigation plan; `/retro` single-writer after validation; exit 3 deferred residual removed. Test 21. |
| 2026-07-14 | CDV-208: `/council --plan <path>` live — preflight requires readable path (exit 2 if missing, not exit 3); preset `generic`; Phase 1 via `skills/council/prompts/plan-extractor.md` with locator `file:heading-path:line`; fixture `skills/council/fixtures/plan-scope-sample.md`; `--from-retro` remains deferred exit 3 until CDV-212. Test 20. |
| 2026-04-09 | Initial spec created from brainstorm `.claude/plans/2026-04-09-brainstorm-council.md` |
| 2026-04-09 | Taxonomy resolution: added Output Shapes section declaring `verdict[]` and `finding[]` as first-class engine outputs; Phase 1 enriches diff-mode input with applicable-specs bundle; Phase 5 Judge emits the shape declared by the preset (empty tool allowlist unchanged); Phase 6 report template branches on shape; Phase 7 feedback memory scoped to `verdict[]` only; findings require `tool_use_id` citations; confidence unified as 0–100 with per-shape thresholds. |
| 2026-04-09 | Task binding closure: Phase 6 adds a verdict index at `.claude/council/index.json` (atomic tmp+rename writes) as the single source of truth for the SPEC-002 TaskCompleted gate; reports gain a `task_id` frontmatter field and `--<task_id>` filename suffix when task-bound; `/council` accepts `--task-id` with a `CLAUDE_TASK_ID` env fallback; the gate is scoped to `verdict[]`-shape rows only (findings-shape runs excluded); Test 9 and validation checkboxes added for the new plumbing. |
| 2026-04-09 | Path drift fix: corrected engine path from `skills/dev-team:council/` to `skills/council/` (the `dev-team:` prefix is invocation-time namespace, not filesystem); corrected refactor target from `commands/review-and-commit.md` to `skills/review-and-commit/SKILL.md` (review-and-commit is skill-only, no command shim exists). No behavioral change. |
| 2026-04-09 | Judge agent split: Phase 5 now routes judgment to a dedicated `council-judge` agent at `agents/council-judge.md` (inherits `tech-lead`'s cortex/memory/directives load path, declares empty tool allowlist in frontmatter) instead of reusing the `tech-lead` agent directly — no per-invocation tool-allowlist override mechanism exists, so the empty allowlist invariant is enforced structurally via a distinct agent file. Overview and validation checkbox updated accordingly. |
| 2026-04-09 | Task-ID path separation (post-Task-1 spike): clarified in Task-ID Plumbing that the `/council` command fallback chain (`--task-id` → `CLAUDE_TASK_ID` → unbound) governs direct command invocations only; the SPEC-002 TaskCompleted hook resolves its task id from stdin JSON (primary) per the verified Claude Code contract and does NOT share this fallback chain. Prevents the hook IC from reusing command-side plumbing. No change to the command path itself. |
| 2026-04-26 | Clarified "no entries in agents/" MUST NOT: scoped to Prosecutor/Investigator/DA/Specialist only; `council-judge` is explicitly excluded because its empty-tool-allowlist invariant requires a persistent agent file. |
| 2026-04-28 | Phase 3 deferral formalised: added blockquote deferral notice to Phase 3 section marking COUNCIL-002 as the delivery milestone; status promoted to ACTIVE; closes spec-code compliance gap flagged in v0.25.2 plugin review. |
| 2026-04-29 | Added Phase 2.5 — Blind Cross-Review (COUNCIL-002): anonymized peer-review round between Phase 2 and Phase 4, Borda-count aggregation of investigator rankings, self-exclusion, position-bias mitigation via per-reviewer label shuffling, WEAK_EVIDENCE flagging for bottom-quartile bundles, bypass when fewer than 3 investigators. Inspired by Karpathy's llm-council anonymized peer-review pattern. Added Test 10. Purely additive — no existing phase behavior changes. |
| 2026-06-14 | v0.34.0 (AUDIT-P1-4A): added Engine Architecture MUST naming each `skills/council/prompts/*` file's own `## Variables` table as the authoritative `{{TEMPLATE_VARIABLE}}` contract, with `commands/council.md` substitution blocks and `skills/council/SKILL.md`'s documented-variables table required to name exactly those variables — no dead substitutions, no unsubstituted placeholders leaking into spawned subagents. Fixes the 3-way contract disagreement (council.md named 3 variables absent from the prompt bodies). Contract MUST only; verdict/finding/evidence schema and taxonomy unchanged. |
| 2026-06-14 | v0.35.0 (AUDIT-P1-4C-1): merged the Phase-4 `prompts/prosecutor.md` + `prompts/advocate.md` templates into one role-parameterized `prompts/phase4-brief.md` (vars: `{{ROLE}}`, `{{ROLE_BIAS}}`, `{{EVIDENCE_FIELD}}`, `{{EVIDENCE_BUNDLES}}`, `{{FLAVOR_DELTA}}`). Made the Phase-4 claim-blindness invariant explicit (line 91): both roles are BLIND to the original claim list and group evidence by the `claim_id` carried inside the bundles — fixes the v0.34.0-class literal leak where the prompt bodies declared/used `{{ORIGINAL_CLAIMS}}` that council.md never substituted, leaking the literal placeholder into the spawned subagent. Judge (Phase 5) still receives original claims — unchanged. Brief output schema (`evidence_against`/`evidence_for` + `struck_lines`) preserved byte-for-byte. |
| 2026-06-15 | Editorial hygiene (AUDIT-P3.5b): Status `✅ ACTIVE`→`ACTIVE` (no emoji); reordered Version-History rows ascending by date (two stray 2026-04-09 rows were sitting after 04-26/04-28). Row content preserved verbatim. No behavioral change. |
| 2026-06-15 | Judge cortex-inheritance reconciled to reality (AUDIT-P4.4): no cortex/memory injection is implemented in `commands/council.md` Phase-5 spawn or `engine.sh`, and the evidence-only Judge (`tools: ""`) cannot run a recall/cortex-load path itself. Relaxed the Phase-5 cortex MUST (line 97) from "MUST inherit `tech-lead`'s cortex/memory/directives load path" to OPTIONAL engine-prepended calibration the Judge MUST function without; updated the Overview line and the validation checkbox accordingly so neither asserts an unimplemented load path. The Judge's authority is the evidence bundle plus its standing behavioral rules. Aligned `agents/council-judge.md` (removed the impossible "Read SPEC-013" checklist step and the false "cortex injected by the council engine" assertion) and trimmed duplicated reasoning in `skills/council/prompts/judge.md`. No engine/spawn behavior change — docs now match the shipped evidence-only design. |
| 2026-07-14 | CDV-196: Council-on-Workflow execution path promoted from DRAFT to active MUSTs — opt-in `--workflow`/`COUNCIL_WORKFLOW=1`, capability probe + transparent fallback, `skills/council/workflow.js` schema-forced agent() steps, shared `engine.sh finalize`, no PYREPAIR on Workflow path, CDV-199 marker via finalize flag only, single-source prompts/flavors, args-as-JSON-string guard (shared with CDV-197). Tests 12–19. |
| 2026-07-14 | CDV-199: Spawn-failure degradation MUST — on unusable investigator/specialist/prosecutor/advocate/judge Task spawn, orchestrator self-verifies with tools; finalize `--verification-mode self-verified` surfaces exact marker `self-verified — refuters unavailable` in report body + frontmatter; exit 5 only when evidence still empty after self-verify path; no local-agent investigator routing. Test 11 + validation checkbox. |
| 2026-07-14 | CDV-203: Report templates own YAML frontmatter (`task_id: "{{TASK_ID}}"` + scope/preset/output_shape/created_at/verification_mode); finalize substitutes template FM as single source (no dual prepend) and strips empty `task_id` when unbound so the key is absent — not null, not `""`. |
| 2026-07-14 | CDV-204: Per-phase token usage reporting (SHOULD) — finalize optional `--tokens-file` (phase→int map + source); stdout `Tokens:` / `Tokens (partial):` block; optional report FM `tokens_total` / `tokens_by_phase`; graceful omit when missing/unavailable/zeros (never invent measured `0`); Task path best-effort envelope scrape in `commands/council.md`; does not alter `index.json`. Test 19 aligned. |
| 2026-07-14 | CDV-211: Investigator tool-call caching within a run (SHOULD) — preflight creates `${TMPDIR:-/tmp}/council-cache-<run_id>/` (`reads/`, `greps/`, `manifest.json`), emits `cache_dir` + `run_id` on plan; investigator.md cache-first via `{{CACHE_DIR}}`; optional orchestrator seed from claim locators; finalize best-effort rm; empty cache correctness-neutral. |
