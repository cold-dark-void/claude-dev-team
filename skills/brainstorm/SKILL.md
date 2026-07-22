---
name: brainstorm
description: |
    Socratic design refinement — structured questioning that forces requirement
    clarification before any planning or implementation. Use before /kickoff for
    complex features, or standalone for early-stage ideation. Optional --grill
    for one-question-at-a-time interviews with recommended answers.
---

# Brainstorm

Structured Socratic design refinement. Your job is to deeply understand the
problem before anyone writes a plan or a line of code.

## Arguments

- `/brainstorm <feature or problem description>` — default mode (batched rounds)
- `/brainstorm --grill <description>` — grill mode (one Q at a time + recommended answer)
- `/brainstorm --grill` — grill mode; prompts for description
- `/brainstorm` — prompts for a description (default mode)

Parse flags from the argument string first. Remaining text is the description.
If no description after flags, ask:
> "What feature or problem would you like to brainstorm?"

**Mode:**
| Flag | Mode | Questioning style |
|------|------|-------------------|
| (none) | **default** | 3–5 questions per round across fixed rounds (Step 1) |
| `--grill` | **grill** | One question at a time; walk the design tree; recommended answer each turn (Step 1-grill) |

Print once at start: `Brainstorm mode: default | grill`.

---

## Step 0: Load context

Read in parallel:
```bash
_gc=$(git rev-parse --git-common-dir 2>/dev/null) \
  && MROOT=$(cd "$(dirname "$_gc")" && pwd) \
  || MROOT=$(pwd)
MEMDB="$MROOT/.claude/memory/memory.db"
```

- `$MROOT/AGENTS.md` (project rules)
- Domain glossary (`skills/domain-glossary/SKILL.md` load protocol):
  ```bash
_gc=$(git rev-parse --git-common-dir 2>/dev/null) \
  && MROOT=$(cd "$(dirname "$_gc")" && pwd) \
  || MROOT=$(pwd)
if [ -f "$MROOT/CONTEXT.md" ]; then
  cat "$MROOT/CONTEXT.md"
elif [ -f "$MROOT/docs/domain/CONTEXT.md" ]; then
  cat "$MROOT/docs/domain/CONTEXT.md"
else
  echo "No domain glossary (CONTEXT.md) yet."
fi
  ```
  Prefer glossary **Term** names; map user/ticket **Avoid** aliases to the canonical term.
- Tech Lead cortex:
  ```bash
WTROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
MEMDB="$MROOT/.claude/memory/memory.db"
_gc=$(git rev-parse --git-common-dir 2>/dev/null) \
  && MROOT=$(cd "$(dirname "$_gc")" && pwd) \
  || MROOT=$(pwd)
  if [ -f "$MEMDB" ] && command -v sqlite3 &>/dev/null; then
    HAS_DISTILLED=$(sqlite3 "$MEMDB" "SELECT COUNT(*) FROM memories WHERE agent='tech-lead' AND tier > 0 AND archived=FALSE;")
    if [ "$HAS_DISTILLED" -gt 0 ]; then
      sqlite3 "$MEMDB" "SELECT content FROM memories WHERE agent='tech-lead' AND tier=2 AND archived=FALSE ORDER BY type, updated_at DESC;"
      sqlite3 "$MEMDB" "SELECT content FROM memories WHERE agent='tech-lead' AND tier=1 AND archived=FALSE ORDER BY type, updated_at DESC;"
    else
      sqlite3 "$MEMDB" "SELECT content FROM memories WHERE agent='tech-lead' AND tier=0 AND archived=FALSE ORDER BY type, created_at DESC;"
    fi
  else
    cat "$MROOT/.claude/memory/tech-lead/cortex.md" 2>/dev/null
  fi
  ```
- PM cortex:
  ```bash
WTROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
MEMDB="$MROOT/.claude/memory/memory.db"
_gc=$(git rev-parse --git-common-dir 2>/dev/null) \
  && MROOT=$(cd "$(dirname "$_gc")" && pwd) \
  || MROOT=$(pwd)
  if [ -f "$MEMDB" ] && command -v sqlite3 &>/dev/null; then
    HAS_DISTILLED=$(sqlite3 "$MEMDB" "SELECT COUNT(*) FROM memories WHERE agent='pm' AND tier > 0 AND archived=FALSE;")
    if [ "$HAS_DISTILLED" -gt 0 ]; then
      sqlite3 "$MEMDB" "SELECT content FROM memories WHERE agent='pm' AND tier=2 AND archived=FALSE ORDER BY type, updated_at DESC;"
      sqlite3 "$MEMDB" "SELECT content FROM memories WHERE agent='pm' AND tier=1 AND archived=FALSE ORDER BY type, updated_at DESC;"
    else
      sqlite3 "$MEMDB" "SELECT content FROM memories WHERE agent='pm' AND tier=0 AND archived=FALSE ORDER BY type, created_at DESC;"
    fi
  else
    cat "$MROOT/.claude/memory/pm/cortex.md" 2>/dev/null
  fi
  ```

Scan `specs/` for any specs related to the topic. Note constraints.

---

## Step 1: Understand the problem (DO NOT SKIP)

**If mode is grill → use Step 1-grill instead of the default rounds below.**

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

Then continue to Step 2.

---

## Step 1-grill: One-question interview (grill mode only)

Use when `--grill` is set. Same goal as Step 1 (shared understanding before
design options) but a **different cadence** — inspired by community grill-me
patterns; no external dependency.

### Cadence rules

1. **One question at a time.** Wait for the user's answer before the next.
2. **Always offer a recommended answer** (opinionated default) so the user can
   accept, tweak, or reject:
   ```
   Q: <single question>
   Recommended: <your best default, 1–2 sentences>
   (accept / edit / reject)
   ```
3. **Walk the design tree** — resolve dependencies between decisions in order
   (intent → scope → constraints → edge cases → naming → alternatives). Do not
   jump to UI chrome before problem/scope is locked.
4. **Read the codebase when a question is answerable from the repo** — do not
   ask the user what the code already shows. State what you found and move on.
5. **Honor the domain glossary** — if `CONTEXT.md` defines a Term, use it; if
   the user uses an Avoid alias, map and confirm once.
6. **Stop grilling** when every open branch is resolved (or the user says
   "enough / proceed"). Then go to Step 2. Soft cap: if 15+ questions without
   synthesis, offer to synthesize now.

### Coverage (not a rigid script)

Ensure these themes get at least one resolved decision (combine only if trivial):
- Core intent & success criteria
- In/out of scope
- Hard constraints & must-not-break
- Edge cases / failure modes
- Integration points
- Domain naming (candidate Terms for glossary)
- Optional one-way decisions for `## Decisions` in CONTEXT.md

Then continue to Step 2.

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

## Domain terms (candidates)
- **<Term>** — <definition> (avoid: <aliases>) — only terms that crystallized this session
```

Ask the user: "Does this capture it? Anything to add or correct?" Include whether candidate domain terms should land in `CONTEXT.md`.

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

### Step 4b: Domain glossary write-back (conditional)

If the user confirmed one or more domain terms in Step 2/3, follow
`skills/domain-glossary/SKILL.md` **Update protocol**:

1. Prefer `$MROOT/CONTEXT.md`; use `$MROOT/docs/domain/CONTEXT.md` only if that
   path already exists and root `CONTEXT.md` does not
2. Create the file from the domain-glossary format if absent; otherwise merge
   new rows into `## Terms` (and optional `## Decisions` lines)
3. Do not invent terms the user did not confirm
4. In **grill** mode, also merge user-confirmed one-way decisions into
   `## Decisions` as `YYYY-MM-DD: <decision> — <why>` when they asked for that
   or explicitly accepted a recommended irreversible choice
5. Note the path in the brainstorm plan file and the printout below

If no terms crystallized, skip silently (absent glossary is fine).

Print:
```
Brainstorm saved to: .claude/plans/<date>-brainstorm-<slug>.md
Mode: <default|grill>
Domain glossary: <updated CONTEXT.md path | no new terms>

Next steps:
  /kickoff — to start formal planning with PM + Tech Lead
  /spec create — to write a behavioral spec from this brainstorm
```

---

## Rules

- NEVER propose full solutions during Step 1 / Step 1-grill — questions (and in
  grill mode, recommended *answers to questions*) only until synthesis
- NEVER skip default rounds when mode is default — even if the user says "just build it"
- Default mode: questions in digestible batches (3-5), not a wall of 15
- Grill mode: one question at a time; always include Recommended; soft-cap ~15 Qs
- If the user's answers reveal the problem is simpler than expected, say so
  and suggest a simpler approach
- If the user's answers reveal the problem is much harder, flag it and suggest
  breaking it into phases
- Be opinionated in your recommendation — don't present options without a clear pick
- Reference existing specs, architecture, and domain glossary from Step 0 when relevant
- Prefer glossary **Term** names in the saved plan and recommendations; do not
  reintroduce listed aliases
