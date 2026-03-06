---
name: review-and-commit
description: Brutally honest review of staged/modified files — no sugar-coating, no
  diplomacy. Checks for bugs, security issues, PII/data exposure, over-engineering,
  and spec drift. Blocks commit on critical issues. Prints review as text; accepts
  an optional path argument to also save to a file.
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

---

## Step 2: Review the Changes

Read every changed file in full — do not review hunks in isolation.

### Tone rules (non-negotiable)
- Do not soften criticism
- Do not congratulate
- Do not say "nice work" or "looks good"
- No hedging language — never say "maybe", "consider", "you might want to"
- Every issue must reference a specific `file:line`
- Suggest concrete fixes, not vague advice
- If the code is genuinely fine: write "No issues found. This is appropriately boring."

### What to look for

**Correctness**
- Bugs, off-by-ones, missed early returns
- Race conditions and concurrency mistakes
- Error handling gaps — swallowed errors, missing retries, silent failures
- Edge cases the author clearly didn't think about

**Security**
- Injection vulnerabilities (SQL, command, template)
- Auth bypass, missing authorization checks
- Secret or token exposure in code or logs
- OWASP top 10 violations
- Trust boundary violations — unvalidated external input treated as safe

**PII & Data Exposure**
- Logging calls (`log.*`, `fmt.Print*`, `console.log`, `print()`, `logger.*`) that emit fields
  resembling: email, name, phone, address, SSN, card number, account ID, auth token, password,
  session ID, IP address, or any field named `user*`, `customer*`, `pii*`, `private*`
- Error messages returned to callers that leak internal state or user data
- Struct serialization (JSON/XML marshaling) of types containing sensitive fields with no
  explicit omit/redact tags
- Any place where a PII field is passed into a format string, structured log, or error

**Simplicity & Over-engineering**
- Treat complexity as a bug unless proven otherwise
- Interfaces with one implementation — delete the interface
- Helpers used in exactly one place — inline them
- Abstractions that exist to feel clever, not to solve a problem
- Config for things that never change
- Premature generalization for hypothetical future requirements
- Prefer deletion over addition — if a simpler path exists, that is the path

**Design**
- Wrong abstractions or layering
- Hidden coupling that will cause pain later
- Breaking API changes without justification
- Copy-paste that should be abstracted — or premature abstractions that shouldn't exist
- Naming that requires a comment to decode

**Performance**
- N+1 queries
- Unbounded allocations
- Obvious hot-path inefficiencies

---

## Step 3: PII Scan (dedicated pass)

After the general review, do a dedicated grep pass on changed files for:
1. Any logging statement containing field names matching: `email`, `name`, `phone`, `address`,
   `password`, `token`, `secret`, `ssn`, `card`, `account`, `session`, `ip`, `user_id`,
   `customer_id` (case-insensitive)
2. Any error string construction that includes user-supplied data without sanitization
3. Any HTTP response body that serializes a full user/customer struct

Flag every hit as at minimum a WARNING. Flag any confirmed leak as a BLOCKER.

---

## Step 4: Spec Alignment

Check `specs/` for specs related to the changed behavior. If any spec is out of date with
the changes, update it now. Never skip this step — if no specs directory exists, note it
and move on.

---

## Step 5: Output the Review

Print the review directly in the conversation using this structure.
Omit any section that has no items.

```
## Critical Issues (Must Fix)
Bugs, security risks, confirmed PII leaks, correctness failures.
Each item: `file:line` — what is wrong — what to do instead.

## Design Problems
Wrong abstractions, unnecessary complexity, over-engineering.

## Security & PII
Trust boundaries, auth gaps, data exposure, logging risks.

## Maintainability Risks
Hidden coupling, future migration pain, naming that lies.

## Nitpicks (Yes, They Matter)
Small things that compound. Still cite file:line.

## What I Would Do Instead
The simpler or safer direction. Prefer subtraction.

## Overall Assessment
2–3 blunt sentences. End with one of: APPROVE / REQUEST CHANGES / NEEDS DISCUSSION
```

If a path argument was provided, also write the same output to that file.

---

## Step 6: Commit Gate

- If any **Critical Issues** exist: do NOT commit. Tell the user exactly what must be fixed first.
- If only Design Problems / Nitpicks / Maintainability: ask the user "Proceed with commit despite findings? (y/n)"
- If clean (or user confirmed): commit with a conventional commit message explaining *why* the change was made.

## Step 7: Action Items

After the review output, always print a structured action list — even if the commit proceeds.
This gives the agent (or user) a concrete checklist to execute.

Print a summary line first:
```
Action Items: N BLOCKERs, M DESIGN, K NITPICK — [commit blocked | commit proceeded]
```

Then the checklist:
```
## Action Items
- [ ] BLOCKER `file:line` — what is wrong — exactly what to do
- [ ] DESIGN  `file:line` — what is wrong — exactly what to do
- [ ] NITPICK `file:line` — what is wrong — exactly what to do
```

Rules:
- Every item from the review must appear here — nothing omitted
- Each item is one line: severity tag, `file:line`, problem, fix
- No vague items — "refactor this" is not acceptable; "delete QueueInterface, use ConcreteQueue directly" is
- Ordered: BLOCKERs first, then DESIGN, then NITPICK

---

## Step 8: Verify

Run `git status` to confirm clean state.
