---
name: brainstorm
description: Socratic design refinement — structured questioning that forces
  requirement clarification before any planning or implementation. Use before
  /kickoff for complex features, or standalone for early-stage ideation.
---

# Brainstorm

Structured Socratic design refinement. Your job is to deeply understand the
problem before anyone writes a plan or a line of code.

## Arguments

- `/brainstorm <feature or problem description>` — start brainstorming
- `/brainstorm` — prompts for a description

If no argument provided, ask:
> "What feature or problem would you like to brainstorm?"

---

## Step 0: Load context

Read in parallel:
```bash
_gc=$(git rev-parse --git-common-dir 2>/dev/null) \
  && PROOT=$(cd "$(dirname "$_gc")" && pwd) \
  || PROOT=$(pwd)
MEMDB="$PROOT/.claude/memory/memory.db"
```

- `$PROOT/AGENTS.md` (project rules)
- Tech Lead cortex:
  ```bash
  if [ -f "$MEMDB" ] && command -v sqlite3 &>/dev/null; then
    sqlite3 "$MEMDB" "SELECT content FROM memories WHERE agent='tech-lead' AND type='cortex' ORDER BY updated_at DESC LIMIT 1;"
  else
    cat "$PROOT/.claude/memory/tech-lead/cortex.md" 2>/dev/null
  fi
  ```
- PM cortex:
  ```bash
  if [ -f "$MEMDB" ] && command -v sqlite3 &>/dev/null; then
    sqlite3 "$MEMDB" "SELECT content FROM memories WHERE agent='pm' AND type='cortex' ORDER BY updated_at DESC LIMIT 1;"
  else
    cat "$PROOT/.claude/memory/pm/cortex.md" 2>/dev/null
  fi
  ```

Scan `specs/` for any specs related to the topic. Note constraints.

---

## Step 1: Understand the problem (DO NOT SKIP)

Before proposing anything, ask the user targeted questions across these
dimensions. Ask 3-5 questions at a time, not all at once.

### Round 1: Core Intent
- What problem does this solve? Who has this problem today?
- What does success look like? How would you measure it?
- What's the trigger — why now?

Wait for answers before continuing.

### Round 2: Scope & Constraints
- What is explicitly OUT of scope?
- Are there hard constraints? (timeline, tech stack, backward compat, performance)
- What existing behavior must NOT change?
- Are there regulatory, security, or compliance requirements?

Wait for answers.

### Round 3: Edge Cases & Integration
- What happens when [unexpected input / failure / concurrent access]?
- What other systems or features does this interact with?
- What's the migration story for existing data/users?
- Are there known anti-patterns or past attempts that failed?

Wait for answers.

### Round 4: Alternatives (if the problem is still ambiguous)
- Have you considered [simpler alternative]?
- What's the minimum viable version of this?
- What would you cut if you had half the time?

---

## Step 2: Synthesize understanding

After all rounds, present a structured summary:

```
## Problem Statement
<1-2 sentences — what the user actually needs>

## Success Criteria
- <measurable outcome 1>
- <measurable outcome 2>

## Scope
IN:  <what's included>
OUT: <what's explicitly excluded>

## Constraints
- <hard constraint 1>
- <hard constraint 2>

## Key Risks
- <risk 1> — mitigation: <approach>
- <risk 2> — mitigation: <approach>

## Open Questions (if any remain)
- <unresolved question>
```

Ask the user: "Does this capture it? Anything to add or correct?"

---

## Step 3: Design options

Only after the user confirms the synthesis, present 2-3 design approaches:

```
## Option A: <name>
Approach: <1-2 sentences>
Pros: <list>
Cons: <list>
Effort: <relative estimate>
Risk: <low/medium/high>

## Option B: <name>
...

## Recommendation
<which option and why — be opinionated, explain the tradeoff>
```

Wait for the user to pick or modify.

---

## Step 4: Output

Save the brainstorm results to a file:

```bash
WTROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
# Save to .claude/plans/<date>-brainstorm-<slug>.md
```

Print:
```
Brainstorm saved to: .claude/plans/<date>-brainstorm-<slug>.md

Next steps:
  /kickoff — to start formal planning with PM + Tech Lead
  /create-spec — to write a behavioral spec from this brainstorm
```

---

## Rules

- NEVER propose solutions during Step 1 — questions only
- NEVER skip rounds — even if the user says "just build it"
- Present questions in digestible batches (3-5), not a wall of 15
- If the user's answers reveal the problem is simpler than expected, say so
  and suggest a simpler approach
- If the user's answers reveal the problem is much harder, flag it and suggest
  breaking it into phases
- Be opinionated in your recommendation — don't present options without a clear pick
- Reference existing specs and architecture from Step 0 context when relevant
