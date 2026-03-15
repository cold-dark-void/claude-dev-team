# /review-commit

Brutally honest multi-agent review of staged and modified files. Runs 5 specialist sub-agents in parallel, applies confidence scoring to filter noise, and gates the commit on the results.

## Usage

```
/review-commit [output-path]
```

## Flags

| Flag / Argument | Description |
|-----------------|-------------|
| _(none)_ | Print review to conversation only |
| `output-path` | Also write review to this file (e.g. `/tmp/review.md`) |

## Examples

**Review and commit interactively:**
```
/review-commit
```

**Save review for later reference:**
```
/review-commit /tmp/review-$(date +%Y%m%d).md
```

Output (abbreviated):
```
## Critical Issues (Must Fix) [confidence 95-100]
src/cache.go:87 — nil pointer deref when cache miss returns early without
  initializing result — return an empty struct, not nil [confidence: 97]

## Compliance Violations
commands/foo.md:1 — missing YAML frontmatter (name, description required by AGENTS.md)
  — add frontmatter block [confidence: 99]

## Overall Assessment
One nil-deref will crash in production on any cache miss. Two files missing
required frontmatter. All other findings are clean.
NEEDS DISCUSSION — fix critical issues first.

Action Items: 2 BLOCKERs, 0 DESIGN, 1 NITPICK — commit blocked
```

**Clean diff — commit proceeds:**
```
/review-commit
# ... review output with no critical findings ...
# Claude commits automatically with a conventional commit message
```

## How It Works

`/review-commit` runs a structured pipeline that treats code review as a first-class engineering step, not a formality.

**Step 1 — Gather changes:** Reads `git diff --cached` and `git diff`. If nothing is staged or modified, stops immediately. Each changed file is read in full — findings are not made on diff hunks in isolation.

**Step 2 — Load project rules:** Reads `AGENTS.md`, `CLAUDE.md`, and any per-directory `CLAUDE.md` files in directories containing changed files. These become the compliance checklist for Agent 3.

**Step 3 — Five parallel sub-agents:** All five agents receive the full diff and the full content of every changed file simultaneously. Each has a narrow, non-overlapping focus:

| Agent | Focus |
|-------|-------|
| **Logic & Correctness** | Bugs, off-by-ones, race conditions, swallowed errors, N+1 queries |
| **Security & PII** | Injection, auth bypass, secret exposure, OWASP top 10, PII in logs |
| **Compliance** | Every rule in AGENTS.md and CLAUDE.md, version file sync, size limits, naming conventions |
| **Design & Quality** | Wrong abstractions, hidden coupling, premature generalization, one-impl interfaces |
| **Simplification** | Dead code, unused imports, complexity reduction, pattern consistency |

Each agent outputs findings as structured JSON with `file`, `line`, `severity`, `category`, `description`, and `suggestion` fields. Tone rules are non-negotiable: no hedging, no congratulations, every issue references a specific `file:line`.

**Step 4 — Confidence scoring:** All findings are scored 0–100. The scoring weighs whether there is clear evidence in the code, whether the reviewer might be misunderstanding intent, whether the issue pre-exists the diff, and whether a linter should catch it instead. Findings below 80 are discarded. This noise filter keeps the final report actionable.

**Step 5 — Spec alignment:** Checks `specs/` for specs related to the changed behavior and updates any that are now out of date.

**Step 6 — Commit gate:**
- **Critical Issues or Compliance Violations** (severity "critical") → commit is blocked; the user is told exactly what must be fixed.
- **Design Problems / Nitpicks only** → user is asked "Proceed with commit despite findings? (y/n)".
- **Clean (or user confirmed)** → Claude commits with a conventional commit message explaining why the change was made.

After every run — even when the commit proceeds — a structured action-items checklist is printed so no finding is lost.

## See Also

- [/wrap-ticket](wrap-ticket.md) — end-of-ticket checklist that runs review-commit as a final gate
- [/orchestrate](orchestrate.md) — full ticket lifecycle that assigns review-commit to a QA agent
