---
name: review-and-commit
description: |
    Brutally honest review of staged/modified files — no sugar-coating. Thin
    wrapper over the council engine with preset `diff-mode`: 5 specialist
    investigators (logic, security, compliance, quality, simplification) run
    in parallel, filtered at confidence 80. Blocks commit on critical or
    compliance findings. Optional path argument saves the review to a file.
---

# Review and Commit

Thin wrapper over `skills/council/engine.sh` with `preset: diff-mode`. The
engine owns the adversarial pipeline; this skill configures the diff scope,
drives the LLM phases, and renders findings in the legacy review-and-commit
format users already know. Your job is NOT to be nice — protect the codebase
from entropy.

## Arguments

- No argument: print review as text only
- `/review-and-commit <path>`: also save the rendered review to that file
- `/review-and-commit --impact`: run blast radius analysis before review (adds affected callers as supplementary context for reviewers)
- `/review-and-commit --impact <path>`: both impact analysis and save to file

## Step 1: Stage and inspect

```bash
git diff --cached
git diff
```

If nothing is staged or modified, stop. Read every changed file in full —
do not review hunks in isolation.

## Step 1b: Blast radius analysis (only when `--impact` is passed)

Skip this step entirely if `--impact` was not passed. When enabled:

1. **Extract changed symbols** — parse the diff hunks for function, method,
   and class names that were modified (added, removed, or changed signature).
   Use simple regex heuristics, not a full parser:
   - Python: `def <name>`, `class <name>`
   - JS/TS: `function <name>`, `<name>(`, `class <name>`, `export.*<name>`
   - Go: `func <name>`, `func (.*) <name>`
   - Rust: `fn <name>`, `struct <name>`, `impl <name>`
   - Shell: `<name>()`, `function <name>`
   - Fallback: any line matching `^\+.*\b(def|func|fn|function|class|struct|impl)\s+(\w+)`

2. **Find callers** — for each extracted symbol, grep the codebase for
   references (exclude the changed files themselves, test files, and
   vendor/node_modules directories):
   ```bash
   grep -rl --include='*.{py,js,ts,go,rs,sh}' '<symbol>' . \
     | grep -v node_modules | grep -v vendor | grep -v __pycache__
   ```
   Cap at 20 caller files total to avoid context blowout.

3. **Build impact context** — produce a concise summary:
   ```
   ## Impact Analysis (--impact)

   Changed symbols: <list>
   Affected files (callers): <N files>
   - path/to/caller1.py:42 — calls <symbol>
   - path/to/caller2.go:18 — references <symbol>
   ...

   Reviewers: check these callers for compatibility with the changes above.
   ```

4. **Pass to specialists** — include the impact context as supplementary
   material in the Phase 1 investigator prompts (alongside the diff and
   changed-file contents). Specialists should flag callers that may break
   due to signature changes, removed functions, or altered behavior.

If no symbols are extracted (e.g., only config/doc changes), skip silently
and proceed without impact context.

## Step 2: Locate the council engine

Same resolution pattern as `commands/council.md`:

```bash
# Locate the dev-team plugin root (PDH). Dev checkout first, else installed cache (highest version). Slug-free, sort -V.
PDH=$( [ -f skills/plugin-dir.sh ] && pwd || find ~/.claude/plugins/cache -path '*/dev-team/*/skills/plugin-dir.sh' 2>/dev/null | sort -V | tail -1 | xargs -r dirname | xargs -r dirname )
ENGINE_SH=$(bash "$PDH/skills/plugin-dir.sh" file skills/council/engine.sh)
[ -x "$ENGINE_SH" ] || { echo "error: council engine.sh not found" >&2; exit 1; }
```

## Step 3: Preflight (diff-mode preset)

```bash
PDH=$( [ -f skills/plugin-dir.sh ] && pwd || find ~/.claude/plugins/cache -path '*/dev-team/*/skills/plugin-dir.sh' 2>/dev/null | sort -V | tail -1 | xargs -r dirname | xargs -r dirname )
ENGINE_SH=$(bash "$PDH/skills/plugin-dir.sh" file skills/council/engine.sh)
PLAN_FILE=$(mktemp "${TMPDIR:-/tmp}/review-and-commit-plan.XXXXXX.json") \
  || { echo "review-and-commit error: mktemp failed for PLAN_FILE"; exit 1; }
"$ENGINE_SH" preflight --scope diff --preset diff-mode > "$PLAN_FILE"
```

Preflight runs Phase 0 intake including spec-grep enrichment over
`$MROOT/specs/**/*.md` for MUSTs matching changed paths. The plan declares
`output_shape: finding[]`, flavor list (logic, security, compliance, quality,
simplification), `spec_grep: true`, `feedback_memory_enabled: false`,
`confidence_filter_threshold: 80`.

## Step 4: Drive the diff-mode council phases

Follow `commands/council.md` Step 3 (Phases 1–5) with these diff-mode deltas:

- **Phase 1** — the 5 specialist flavors ARE the investigators. Spawn 5 Task
  subagents in one message (parallel), one per flavor from
  `skills/council/flavors/{logic,security,compliance,quality,simplification}.md`,
  using `skills/council/prompts/investigator.md`. Pass full diff, full
  changed-file contents, applicable-specs bundle, impact context from
  Step 1b if available (empty string if `--impact` was not used),
  `output_shape: finding[]`,
  tool allowlist `Read, Grep, Glob, Bash (read-only)`. Every finding MUST
  carry a `tool_use_id`.
- **Phase 2 / Phase 3** — n/a (specialists already investigate; domain
  specialist deferred).
- **Phase 4** — skipped in diff-mode; route specialist findings directly to
  the judge.
- **Phase 5** — spawn `agents/council-judge.md` (empty tool allowlist) with
  `skills/council/prompts/judge.md`, `claims=[]`, findings as evidence
  bundles, `output_shape: finding[]`. Judge dedupes, strikes findings
  missing `tool_use_id` or confidence <80, emits final `finding[]`.
- **Strike enforcement** — same rule as `commands/council.md`: any line
  without a `tool_use_id`, severity outside `critical|warning|nitpick`, or
  confidence <80 → `struck_lines`; never silently drop.

## Step 5: Finalize

```bash
PDH=$( [ -f skills/plugin-dir.sh ] && pwd || find ~/.claude/plugins/cache -path '*/dev-team/*/skills/plugin-dir.sh' 2>/dev/null | sort -V | tail -1 | xargs -r dirname | xargs -r dirname )
ENGINE_SH=$(bash "$PDH/skills/plugin-dir.sh" file skills/council/engine.sh)
EVIDENCE_FILE=$(mktemp "${TMPDIR:-/tmp}/rc-evidence.XXXXXX.json") \
  || { echo "review-and-commit error: mktemp failed for EVIDENCE_FILE"; exit 1; }
JUDGE_FILE=$(mktemp "${TMPDIR:-/tmp}/rc-judge.XXXXXX.json") \
  || { echo "review-and-commit error: mktemp failed for JUDGE_FILE"; exit 1; }
# populate from Phase 1 / Phase 5 outputs, then:
"$ENGINE_SH" finalize --plan-file "$PLAN_FILE" \  # lint-ok: C1
  --evidence-file "$EVIDENCE_FILE" --judge-output "$JUDGE_FILE"
```

Engine renders the canonical report via
`skills/council/templates/report-finding.md` to
`$MROOT/.claude/council/<YYYY-MM-DD>-diff-staged.md`.

## Step 6: Output the Review (legacy format — DO NOT ALTER)

Read the judge's finding[] output and print it in this exact structure. Omit
empty sections. Every heading, label, and bracket-confidence annotation is
load-bearing — user muscle memory depends on it.

```
## Critical Issues (Must Fix) [confidence 95-100]
Bugs, security risks, confirmed PII leaks, correctness failures.
Each item: `file:line` — what is wrong — what to do instead. [confidence: N]

## Compliance Violations
AGENTS.md / CLAUDE.md rule violations.
Each item: `file:line` — rule violated — what to fix. [confidence: N]

## Design Problems [confidence 80-94]
Wrong abstractions, unnecessary complexity, over-engineering.

## Security & PII [confidence 80-94]
Trust boundaries, auth gaps, data exposure, logging risks.

## Maintainability Risks
Hidden coupling, future migration pain, naming that lies.

## Simplification Opportunities
Concrete ways to make the code simpler.

## Nitpicks (Yes, They Matter) [confidence 80-94]
Small things that compound. Still cite file:line.

## What I Would Do Instead
The simpler or safer direction. Prefer subtraction.

## Overall Assessment
2–3 blunt sentences. End with one of: APPROVE / REQUEST CHANGES / NEEDS DISCUSSION

Review stats: N findings from 5 agents, M passed confidence filter (≥80), K discarded.
```

Grouping rules: `severity=critical` → Critical Issues; `category=compliance`
(any severity) → Compliance Violations; `category=design,severity=warning` →
Design Problems; `category=security,severity=warning` → Security & PII;
`category=quality,severity=warning` → Maintainability Risks;
`category=simplification` → Simplification Opportunities; `severity=nitpick`
→ Nitpicks. If spec-grep detected drift, add `## Spec Alignment` listing
affected specs. If a path argument was given, also write this output there.

Tone rules (non-negotiable): no softening, no congratulation, no hedging
("maybe", "consider", "you might want to"), every issue references a
specific `file:line`, fixes are concrete.

## Step 7: Commit Gate

- Any **Critical Issues** or **Compliance Violations** → do NOT commit; tell
  the user exactly what must be fixed. (Matches diff-mode preset
  `commit_gate_blocks_on: [critical, compliance]`.)
- Design / Nitpicks / Simplification only → ask
  "Proceed with commit despite findings? (y/n)"
- Clean or user-confirmed → `git commit` with a conventional message
  explaining *why* the change was made.

## Step 8: Action Items

Always print — even if the commit proceeds. Summary line first:

```
Action Items: N BLOCKERs, M DESIGN, K NITPICK — [commit blocked | commit proceeded]
```

Then the checklist:

```
## Action Items
- [ ] BLOCKER `file:line` — what is wrong — exactly what to do [confidence: N]
- [ ] COMPLIANCE `file:line` — rule violated — exactly what to do [confidence: N]
- [ ] DESIGN  `file:line` — what is wrong — exactly what to do [confidence: N]
- [ ] NITPICK `file:line` — what is wrong — exactly what to do [confidence: N]
```

Rules: every review item appears here; one line each; no vague items
("refactor this" is not acceptable — "delete QueueInterface, use
ConcreteQueue directly" is); ordered BLOCKER → COMPLIANCE → DESIGN → NITPICK.

## Step 9: Verify

`git status` to confirm clean state (if the commit proceeded).

## Notes

- Thin wrapper over `skills/council/SKILL.md` with `preset: diff-mode`. The
  5 specialists load from `skills/council/flavors/{logic,security,compliance,quality,simplification}.md`.
- **Phase 7 feedback memory is DISABLED** for diff-mode
  (`feedback_memory_enabled: false`). A code bug is not a claim fabrication;
  conflating them would poison agent directives. See SPEC-013 line 105,
  SPEC-010 line 28.
- Engine always writes the canonical report to
  `$MROOT/.claude/council/<date>-diff-staged.md`. An optional path argument
  writes an ADDITIONAL copy in the legacy text format rendered by Step 6.
