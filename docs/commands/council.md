# /council

An on-demand adversarial tribunal that reality-checks Claude's claims with material evidence. It exists to catch a recurring failure mode — confident narrative that never touched reality (fabricated config failures, "all green" deploys nobody correlated with the change, facts asserted about code that was never read). The tribunal is court-shaped: blind investigators gather raw tool-call evidence, a prosecutor and a devil's advocate argue over it, and a tool-less judge issues a verdict. You stay out of it — every line of the verdict must be backed by an investigator's `tool_use_id` or it gets struck.

## Usage

```
/council "<claim text>"
/council --session [--last N]
/council --diff
/council --task-id <id>
/council --workflow "<claim text>"
```

## Arguments

| Argument | Description |
|----------|-------------|
| `"<claim text>"` | Audit a single pasted claim. Extraction is skipped — the claim is already isolated. |
| `--session [--last N]` | Audit a slice of the current session transcript. `--last N` limits to the last N turns. |
| `--diff` | Audit the staged diff. Routes through the same engine as [`/review-and-commit`](./review-and-commit.md) (diff-mode preset, finding-shape output). |
| `--task-id <id>` | Bind the run to an orchestrated task. Adds a `task_id` to the report and appends a row to `.claude/council/index.json`. Falls back to the `CLAUDE_TASK_ID` env var, then unbound. |
| `--workflow` | Opt-in Workflow execution path (schema-forced `agent()` steps). Also `COUNCIL_WORKFLOW=1`. Orthogonal to scope. Falls back to the default Task path with a one-line stderr notice when Workflow is unavailable — never a hard fail. |
| `--plan <path>` | Deferred to COUNCIL-002 — fails loudly (engine exit 3). |
| `--from-retro <id>` | Deferred to COUNCIL-002 — fails loudly (engine exit 3). |

Scope flags are mutually exclusive: exactly one of `"<claim>"`, `--session`, `--diff`, `--plan`, or `--from-retro` must be supplied. `--workflow` is not a scope. Running `/council` with no scope fails loudly with usage — it never guesses.

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

## Error handling / degraded runs

If investigator, prosecutor, advocate, or judge Task spawns fail (rate-limit
or any unusable return), the orchestrator self-verifies that role with tools
and finalizes with `--verification-mode self-verified`. The report Summary
shows the marker **`self-verified — refuters unavailable`** and frontmatter
`verification_mode: self-verified`. Full (happy-path) runs omit the banner.
Empty evidence after self-verify still aborts (engine exit 5).

## Notes

- The council is a **pure auditor**: it never proposes fixes, never modifies files, never audits user-authored claims, and never runs automatically on a session or commit. Every invocation is explicit.
- For `verdict[]` runs, a `FABRICATED` (confidence ≥ 70) or `UNVERIFIED` (≥ 85) verdict triggers a feedback-memory write — to `.claude/memory/claude/lessons.md` for plain Claude, or via `/adjust-agent` for a team-agent author. Diff-mode (`finding[]`) never writes feedback memory: a code bug is not a fabrication.
- Deferred scopes fail loud by design. `/retro` prints `Consider: /council --from-retro <anchor-id>` as a hint; running it surfaces the COUNCIL-002 deferral message, which is the expected behavior.

## See Also

- [`/review-and-commit`](./review-and-commit.md) — the same engine with the `diff-mode` preset (finding-shape code review)
- Engine protocol: [`skills/council/SKILL.md`](../../skills/council/SKILL.md)
- Full contract: [`SPEC-013`](../../specs/core/SPEC-013-adversarial-council-tribunal.md)
