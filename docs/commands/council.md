# /council

An on-demand adversarial tribunal that reality-checks Claude's claims with material evidence. It exists to catch a recurring failure mode — confident narrative that never touched reality (fabricated config failures, "all green" deploys nobody correlated with the change, facts asserted about code that was never read). The tribunal is court-shaped: blind investigators gather raw tool-call evidence, a prosecutor and a devil's advocate argue over it, and a tool-less judge issues a verdict. You stay out of it — every line of the verdict must be backed by an investigator's `tool_use_id` or it gets struck.

## Usage

```
/council "<claim text>"
/council --session [--last N]
/council --diff
/council --plan <path>
/council --from-retro <anchor-id>
/council --blind [--teams N] [--lenses L1,L2,...] [--target <path>]
/council --task-id <id>
/council --workflow "<claim text>"
```

## Arguments

| Argument | Description |
|----------|-------------|
| `"<claim text>"` | Audit a single pasted claim. Extraction is skipped — the claim is already isolated. |
| `--session [--last N]` | Audit a slice of the current session transcript. `--last N` limits to the last N turns. |
| `--diff` | Audit the staged diff. Routes through the same engine as [`/review-and-commit`](./review-and-commit.md) (diff-mode preset, finding-shape output). |
| `--blind` | Multi-team blind peer review (absorbs former `/blind-review`). Distinct path — no tribunal Phases 1–5. See [Blind peer review](#blind-peer-review---blind) below. |
| `--teams N` | Blind-path only. Number of unconstrained reviewer teams (default `3`). Hard fail without `--blind`. |
| `--lenses L1,L2,...` | Blind-path only. Comma-separated lens teams (default `security,contributor,spec`). Available: `security`, `contributor`, `spec`, `architecture`, `logic`. Hard fail without `--blind`. |
| `--target <path>` | Blind-path only. Narrow review to a path (default: full project). Hard fail without `--blind`. |
| `--task-id <id>` | Bind the run to an orchestrated task. Adds a `task_id` to the report and appends a row to `.claude/council/index.json`. Falls back to the `CLAUDE_TASK_ID` env var, then unbound. Not applied to `--blind` index rows (findings-shaped / gate-ignored). |
| `--workflow` | Opt-in Workflow execution path (schema-forced `agent()` steps). Also `COUNCIL_WORKFLOW=1`. Orthogonal to tribunal scopes; **must not** apply to `--blind`. Falls back to the default Task path with a one-line stderr notice when Workflow is unavailable — never a hard fail. |
| `--plan <path>` | Audit a plan file for unverified assumptions (CDV-208). Missing path exits 2. |
| `--from-retro <id>` | Audit a fabrication anchor persisted by `/retro` under `.claude/retro/anchors/<id>.json` (CDV-212). Missing anchor exits 2; Phase 1 skipped. |

Scope flags are mutually exclusive: exactly one of `"<claim>"`, `--session`, `--diff`, `--plan`, `--from-retro`, or `--blind` must be supplied. `--workflow` is not a scope. `--teams` / `--lenses` / `--target` require `--blind`. Running `/council` with no scope fails loudly with usage — it never guesses. There is **no** `--no-council` flag.

**Dual path (CDV-196):** default is `engine.sh` + Task subagents. With `--workflow` / `COUNCIL_WORKFLOW=1`, the tribunal may run via `skills/council/workflow.js` and still finish through shared `engine.sh finalize` (same report and index shape). See `skills/council/SKILL.md` § Workflow execution path.

## The Tribunal

`/council` is a thin wrapper over the council engine. Each run plays out as a sequence of blind, adversarial roles:

- **Investigators** (read-only) — spawned in parallel, at least 2 per claim with distinct flavor presets (`paranoid-ic` plus another) to defeat monoculture. Their tool allowlist is read-only: `Read`, `Grep`, `Glob`, `Bash` for read commands, MCP query tools — no `Write`, no `Edit`. Each returns an evidence bundle: `tool_use_id`, raw output blob, `file:line` citation, reproducible command. Bundles without a `tool_use_id` count as "no evidence collected".
- **Prosecutor** (`jaded-senior` flavor) — assumes the claim is false until the evidence overwhelmingly proves otherwise; strikes anything vague or paraphrased.
- **Devil's Advocate** (`yolo-ic` flavor) — argues *for* the claim to prevent prosecutor monoculture, but concedes when the bundles truly contradict it.
- **Judge** (`council-judge` agent) — issues the final verdicts. Its tool allowlist is structurally empty (`tools: ""` in `agents/council-judge.md`): it cannot run any tool and decides purely from the evidence bundles and the two briefs.

**Blindness invariant:** investigators, prosecutor, and advocate receive raw artifacts only — never prior assistant narrative, never prior verdicts, never a paraphrase. The prosecutor and advocate are even blind to the original claim list; they reconstruct it from the `claim_id` carried inside each bundle.

**Evidence-or-silence rule:** every verdict, finding, prosecutor line, and advocate line must be backed by an investigator `tool_use_id`. Lines without one are *struck* — never silently dropped — and surfaced in the report's audit trail with a one-line warning.

### Verdict vocabulary

For claim and session scopes (`verdict[]` shape), the judge issues one verdict per claim from a fixed taxonomy, each with a 0–100 confidence score:

| Verdict | Meaning |
|---------|---------|
| `VERIFIED` | Evidence fully supports the claim. |
| `PARTIALLY_VERIFIED` | Evidence supports part of the claim. |
| `UNVERIFIED` | No evidence found either way (e.g. investigators returned empty bundles). |
| `CONTRADICTED` | Evidence directly contradicts the claim. |
| `FABRICATED` | The claim asserts something the evidence shows was invented. |

Diff scope (`--diff`) emits `finding[]` instead — `{file, line, severity, category, description, suggestion, confidence, tool_use_id}` with severity drawn from `critical | warning | nitpick`, filtered below confidence 80 at emission.

## Examples

**Audit a shaky claim mid-session:**
```
/council "the retry logic in commands/retro.md uses exponential backoff with jitter"
```
Spawns investigators that read `commands/retro.md`, return evidence bundles, and let the judge rule.

**Expected output:**
```
Council report: .claude/council/2026-06-22-claim-the-retry-logic-in.md
Scope: claim
Preset: generic (verdict[])
FABRICATED: 1   CONTRADICTED: 0   UNVERIFIED: 0   PARTIALLY_VERIFIED: 0   VERIFIED: 0
Struck lines: 0

Warning: 0 verdict lines were struck for missing evidence.
```

**Audit the last 20 turns after a debug session that claimed "all green":**
```
/council --session --last 20
```
Extracts load-bearing claims (default budget 10, highest-stakes first), investigates each in parallel, and reports per-claim verdicts.

**Verify a task before it completes:**
```
/council --task-id CDV-42 --session --last 10
```
Writes `.claude/council/<date>-<slug>--CDV-42.md` and appends a row to `.claude/council/index.json` so the `requires_council` TaskCompleted gate can read it.

## Blind peer review (`--blind`)

Distinct execution path that absorbs the former `/blind-review` command.
**Does not** run tribunal Phases 1–5, `engine.sh` preflight/finalize, or
Workflow. Clustering + confidence tiering **is** the verdict.

```
/council --blind
/council --blind --teams 3 --lenses security,contributor,spec --target path/
```

| Flag | Description |
|------|-------------|
| `--teams N` | Unconstrained reviewer teams (default `3`) |
| `--lenses L1,L2,...` | Lens teams (default `security,contributor,spec`). Available: `security`, `contributor`, `spec`, `architecture`, `logic` |
| `--target <path>` | Narrow to a path/glob; omit for full project (tracked files, minus lockfiles/generated) |

There is **no** `--no-council` flag. Tier-1 clusters emit as findings
**directly** — the blind path MUST NOT re-invoke `/council` (or re-enter the
tribunal) on consensus findings.

### How it works

1. **Resolve scope** — full project (`git ls-files`, excluding lockfiles / minified / `node_modules` / `dist` / `vendor`) or `--target` path.
2. **Single parallel wave** — spawn all unconstrained teams (`U1`…`UN`) and all lens teams (`L-security`, …) at once. Reviewers are read-only and blind to each other and to session narrative.
3. **Namespace and validate** — prefix findings with team ID; drop malformed findings (missing Category, Severity, Files, Claim, or Evidence).
4. **Quorum analysis** — one non-blind analyst clusters findings by semantic similarity and assigns tiers.
5. **Emit findings** — Tier 1/2/3 written directly; no recursive reverse-validation pass.
6. **Write report** — `.claude/council/<date>-blind[-<target-slug>].md`. Always written even if a team returns 0 findings.

### Confidence tiers

| Tier | Condition | Interpretation |
|------|-----------|----------------|
| 1 | Cross-cohort AND ≥2 teams | Highest confidence — unconstrained + lens independently. Emitted as findings (no second council). |
| 2 | Single-cohort AND ≥2 teams | Good signal within one cohort. |
| 3 | Exactly 1 team | Minority finding — reported, not reverse-validated. |

### Examples

**Full-project review with defaults:**
```
/council --blind
```
Spawns 3 unconstrained + `security` / `contributor` / `spec` lens teams (6 reviewers).

**Scoped review with custom lenses:**
```
/council --blind --teams 2 --lenses logic,architecture --target internal/parser/
```

**Expected summary:**
```
Blind council complete.

Report: .claude/council/2026-06-22-blind-internal-parser.md

Summary:
  Tier 1 (cross-cohort ≥2 teams): 2 clusters
  Tier 2 (same-cohort ≥2 teams):  4 clusters
  Tier 3 (single team):           9 clusters

Top findings:
  [CLUSTER-001] high — unescaped path joined into shell command (3/4 teams)
  [CLUSTER-002] medium — token-limit constant disagrees with the spec (2/4 teams)
  (showing top 5 Tier 1+2 only)

Tier-1 reverse-validation: none (severed — clusters are findings)
```

Each lens is a *reading angle*, not a scope restriction: a lens reviewer still
reads everything, but from a fixed perspective (e.g. `security` as an attacker,
`contributor` as a newcomer, `spec` against stated contracts).

## Error handling / degraded runs

If investigator, prosecutor, advocate, or judge Task spawns fail (rate-limit
or any unusable return), the orchestrator self-verifies that role with tools
and finalizes with `--verification-mode self-verified`. The report Summary
shows the marker **`self-verified — refuters unavailable`** and frontmatter
`verification_mode: self-verified`. Full (happy-path) runs omit the banner.
Empty evidence after self-verify still aborts (engine exit 5). On the blind
path, a failed reviewer slot is noted as 0 findings / self-verified; the
report is still written.

Hard fails (print usage, exit non-zero): zero or multiple scopes;
`--teams` / `--lenses` / `--target` without `--blind`; unknown lens;
non-positive `--teams`; missing `--target` path.

## Notes

- The council is a **pure auditor**: it never proposes fixes, never modifies files, never audits user-authored claims, and never runs automatically on a session or commit. Every invocation is explicit.
- For `verdict[]` runs, a `FABRICATED` (confidence ≥ 70) or `UNVERIFIED` (≥ 85) verdict triggers a feedback-memory write — to `.claude/memory/claude/lessons.md` for plain Claude, or via `/adjust-agent` for a team-agent author. Diff-mode (`finding[]`) and blind-path findings never write feedback memory: a code bug is not a fabrication.
- `/retro` prints `Consider: /council --from-retro <anchor-id>` and persists anchors under `.claude/retro/anchors/`; `/council --from-retro` loads that file and skips claim extraction.
- Blind-path reports are findings-shaped and **gate-ignored** — they do not write an `index.json` row that would satisfy `requires_council`.

## See Also

- [`/review-and-commit`](./review-and-commit.md) — the same engine with the `diff-mode` preset (finding-shape code review)
- Engine protocol: [`skills/council/SKILL.md`](../../skills/council/SKILL.md)
- Full contract: [`SPEC-013`](../../specs/core/SPEC-013-adversarial-council-tribunal.md)

