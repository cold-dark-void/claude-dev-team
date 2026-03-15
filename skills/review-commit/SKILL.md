---
name: review-and-commit
description: Brutally honest review of staged/modified files — no sugar-coating, no
  diplomacy. Runs 5 parallel specialist sub-agents (Logic, Security, Compliance,
  Quality, Simplification) with confidence scoring to filter false positives. Blocks
  commit on critical issues. Prints review as text; accepts an optional path argument
  to also save to a file.
---

# Review and Commit

Your job is NOT to be nice. Your job is to protect the codebase from entropy.

## Arguments

- No argument: print review as text only
- With path (e.g. `/review-and-commit /tmp/review.md`): also save to that file

---

## Step 1: Get the Changes

Read all staged and modified files:
```bash
git diff --cached
git diff
```

If nothing is staged or modified, tell the user there is nothing to review and stop.

Read every changed file in full — do not review hunks in isolation.

---

## Step 2: Load Project Rules

Read these files (skip any that don't exist):

```bash
_gc=$(git rev-parse --git-common-dir 2>/dev/null) \
  && MROOT=$(cd "$(dirname "$_gc")" && pwd) \
  || MROOT=$(pwd)
```

- `$MROOT/AGENTS.md` — project rules and conventions
- `$MROOT/CLAUDE.md` — project instructions
- Any per-directory `CLAUDE.md` files in directories containing changed files

Extract all rules, conventions, and constraints from these files. These form
the compliance checklist for Step 3.

---

## Step 3: Parallel Multi-Agent Review

Launch **5 specialist sub-agents in parallel** (Opus model). Each receives the
full diff, the full content of changed files, and their specific review focus.

### Agent 1: Logic & Correctness
Focus exclusively on:
- Bugs, off-by-ones, missed early returns
- Race conditions and concurrency mistakes
- Error handling gaps — swallowed errors, missing retries, silent failures
- Edge cases the author clearly didn't think about
- N+1 queries, unbounded allocations, hot-path inefficiencies

### Agent 2: Security & PII
Focus exclusively on:
- Injection vulnerabilities (SQL, command, template)
- Auth bypass, missing authorization checks
- Secret or token exposure in code or logs
- OWASP top 10 violations
- Trust boundary violations — unvalidated external input treated as safe
- Logging that emits PII fields (email, name, phone, address, password, token,
  secret, ssn, card, account, session, ip, user_id, customer_id)
- Error messages that leak internal state or user data
- Struct serialization of types with sensitive fields missing omit/redact tags

### Agent 3: Compliance (AGENTS.md / CLAUDE.md)
Focus exclusively on:
- Every rule extracted from AGENTS.md — validate the diff does not violate it
- Every rule from CLAUDE.md files — validate compliance
- Version file sync (plugin.json, marketplace.json, README.md)
- File size constraints (no file > 1k lines)
- PR size constraints (~1k LOC soft cap, 2k hard cap)
- Memory file line limits if agent memory files are changed
- Naming conventions and code conventions from project rules
- Commit hygiene rules

For each rule checked, report: PASS, FAIL, or N/A.

### Agent 4: Design & Quality
Focus exclusively on:
- Wrong abstractions or layering
- Hidden coupling that will cause pain later
- Breaking API changes without justification
- Copy-paste that should be abstracted — or premature abstractions that shouldn't exist
- Interfaces with one implementation — delete the interface
- Helpers used in exactly one place — inline them
- Config for things that never change
- Premature generalization for hypothetical future requirements
- Naming that requires a comment to decode

### Agent 5: Simplification
Focus exclusively on:
- Can any changed code be made simpler while preserving behavior?
- Are there shorter, clearer ways to express the same logic?
- Is there dead code, unused imports, unreachable branches?
- Consistent patterns — does the new code match existing conventions?
- Complexity reduction opportunities
- Prefer deletion over addition — if a simpler path exists, that is the path

### Sub-agent output format

Each agent must output findings as a JSON array:
```json
[
  {
    "file": "path/to/file",
    "line": 42,
    "severity": "critical|warning|nitpick",
    "category": "logic|security|compliance|design|simplification",
    "description": "what is wrong",
    "suggestion": "what to do instead"
  }
]
```

If no issues found, return `[]`.

### Tone rules for ALL agents (non-negotiable)
- Do not soften criticism
- Do not congratulate
- No hedging language — never say "maybe", "consider", "you might want to"
- Every issue must reference a specific `file:line`
- Suggest concrete fixes, not vague advice

---

## Step 4: Confidence Scoring

After collecting all findings from the 5 agents, score each finding for
confidence on a 0-100 scale:

- **0-25**: Likely false positive — the code is probably fine
- **26-50**: Uncertain — might be an issue but not clear
- **51-79**: Probable issue — worth a second look
- **80-94**: High confidence — this should be fixed (WARNING)
- **95-100**: Near certain — this must be fixed (CRITICAL)

Scoring criteria:
- Is there clear evidence in the code for the issue?
- Could the reviewer be misunderstanding intent or context?
- Is this a pre-existing issue or introduced by this diff?
- Is this something a linter would catch? (deprioritize — linters should handle it)

**Discard all findings scoring below 80.** This is the noise filter.

---

## Step 5: Spec Alignment

Check `specs/` for specs related to the changed behavior. If any spec is out of
date with the changes, update it now. Never skip this step — if no specs
directory exists, note it and move on.

---

## Step 6: Output the Review

Print the review directly in the conversation using this structure.
Omit any section that has no items (after confidence filtering).

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

If a path argument was provided, also write the same output to that file.

---

## Step 7: Commit Gate

- If any **Critical Issues** or **Compliance Violations** with severity "critical" exist:
  do NOT commit. Tell the user exactly what must be fixed first.
- If only Design Problems / Nitpicks / Simplification: ask the user
  "Proceed with commit despite findings? (y/n)"
- If clean (or user confirmed): commit with a conventional commit message
  explaining *why* the change was made.

## Step 8: Action Items

After the review output, always print a structured action list — even if the
commit proceeds.

Print a summary line first:
```
Action Items: N BLOCKERs, M DESIGN, K NITPICK — [commit blocked | commit proceeded]
```

Then the checklist:
```
## Action Items
- [ ] BLOCKER `file:line` — what is wrong — exactly what to do [confidence: N]
- [ ] DESIGN  `file:line` — what is wrong — exactly what to do [confidence: N]
- [ ] NITPICK `file:line` — what is wrong — exactly what to do [confidence: N]
```

Rules:
- Every item from the review must appear here — nothing omitted
- Each item is one line: severity tag, `file:line`, problem, fix, confidence
- No vague items — "refactor this" is not acceptable; "delete QueueInterface, use ConcreteQueue directly" is
- Ordered: BLOCKERs first, then COMPLIANCE, then DESIGN, then NITPICK

---

## Step 9: Verify

Run `git status` to confirm clean state.
