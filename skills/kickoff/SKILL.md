---
name: kickoff
description: Orchestrate the full ticket intake and planning phase — parallel PM+Tech Lead
  kickoff, spec creation, implementation plan, and TaskCreate task graph. Replaces 7 manual
  prompts with one command. Usage: /kickoff <TICKET-ID> "<ticket text>" or /kickoff alone
  to be prompted.
---

# Kickoff

Collapse Phase 1 (intake) and Phase 2 (planning) of the Linear-to-prod workflow into a
single orchestrated command. Fires PM and Tech Lead in parallel, produces a spec, plan,
and task graph ready for IC agents to claim.

## Arguments

- `/kickoff <TICKET-ID> "<ticket text>"` — ticket ID and full ticket text inline
- `/kickoff <TICKET-ID>` — prompts for ticket text
- `/kickoff` — prompts for both

---

## Step 0: Resolve project root and parse args

```bash
_gc=$(git rev-parse --git-common-dir 2>/dev/null) \
  && MROOT=$(cd "$(dirname "$_gc")" && pwd) \
  || MROOT=$(pwd)
WTROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
```

If TICKET-ID or ticket text are missing, ask:
> "Ticket ID (e.g. POC-123):"
> "Paste the full ticket text (title, description, acceptance criteria):"

---

## Step 1: Load context

Read the following in parallel before doing anything else:

```bash
MEMDB="$MROOT/.claude/memory/memory.db"
```

- Claude memory:
  ```bash
  if [ -f "$MEMDB" ] && command -v sqlite3 &>/dev/null; then
    sqlite3 "$MEMDB" "SELECT content FROM memories WHERE agent='claude' AND type='memory' ORDER BY created_at DESC;"
  else
    cat "$MROOT/.claude/memory/claude/memory.md" 2>/dev/null
  fi
  ```
- Tech Lead cortex:
  ```bash
  if [ -f "$MEMDB" ] && command -v sqlite3 &>/dev/null; then
    sqlite3 "$MEMDB" "SELECT content FROM memories WHERE agent='tech-lead' AND type='cortex' ORDER BY created_at DESC;"
  else
    cat "$MROOT/.claude/memory/tech-lead/cortex.md" 2>/dev/null
  fi
  ```
- PM cortex:
  ```bash
  if [ -f "$MEMDB" ] && command -v sqlite3 &>/dev/null; then
    sqlite3 "$MEMDB" "SELECT content FROM memories WHERE agent='pm' AND type='cortex' ORDER BY created_at DESC;"
  else
    cat "$MROOT/.claude/memory/pm/cortex.md" 2>/dev/null
  fi
  ```
- `$MROOT/AGENTS.md` (project rules)

Scan `specs/` for specs likely related to the ticket:
```bash
ls $MROOT/specs/core/ 2>/dev/null || ls $MROOT/specs/ 2>/dev/null
```

Read any spec whose filename or title matches keywords from the ticket text.
Note which specs are relevant — they constrain the design.

---

## Step 2: Parallel PM + Tech Lead + Codebase Exploration

Spawn **three** agents simultaneously. Do not wait for one before starting the others.

### PM prompt (send now):
```
You are @pm. Review ticket <TICKET-ID>:

<TICKET TEXT>

Your job:
1. Confirm or rewrite each acceptance criterion — make them unambiguous and testable
2. Flag any scope questions that must be resolved before implementation starts
3. Add any missing ACs that the ticket implies but doesn't state
4. Output: revised AC list + list of open questions (if any)

Do NOT start planning implementation. Scope only.
```

### Tech Lead prompt (send now, in parallel):
```
You are @tech-lead. Orient on ticket <TICKET-ID> while @pm reviews scope.

Ticket summary: <first 2 sentences of ticket text>

Your job right now (before ACs are confirmed):
1. Read your cortex.md for architecture context
2. Identify which files/packages this ticket will likely touch
3. Identify any existing specs that constrain the design
4. Note any technical risks or unknowns

Do NOT produce a plan yet — wait for confirmed ACs.
Output: affected files, relevant specs, risks.
```

### Codebase Explorer prompt (send now, in parallel — Sonnet):
```
You are a codebase exploration agent. Deep-dive the codebase to map how
the area related to ticket <TICKET-ID> currently works.

Ticket summary: <first 2 sentences of ticket text>
Keywords: <extract 3-5 keywords from ticket text>

Your methodology:
1. DISCOVERY — Grep/Glob for the keywords across the codebase. Find all
   relevant files, types, functions, routes, handlers.
2. FLOW ANALYSIS — For the top 3-5 most relevant entry points, trace the
   execution path: caller → function → dependencies → side effects.
   Read each file fully, do not skim.
3. ARCHITECTURE MAPPING — Identify patterns: what abstractions exist,
   what conventions are followed, what data flows through the system.
4. DEPENDENCY MAP — What does this area depend on? What depends on it?

Output a structured report:
- Entry points: <list with file:line>
- Execution flows: <caller → callee chains>
- Patterns in use: <conventions, abstractions, data flow>
- Dependencies (inbound): <what calls into this area>
- Dependencies (outbound): <what this area calls>
- Landmines: <anything surprising, fragile, or undocumented>
```

Collect all three outputs before proceeding.

Present the codebase exploration findings to the user alongside PM and Tech Lead
outputs — this gives everyone a shared understanding of how the code works today
before any design decisions are made.

---

## Step 3: Resolve open questions

Present PM's open questions to the user:

```
@pm found N open questions before ACs can be confirmed:

1. <question>
2. <question>

Please answer each one so we can lock scope.
```

If PM had no open questions, skip to Step 4.

Collect answers. Feed them back to PM:
```
@pm — user answers to your open questions:
<answers>

Produce the final confirmed AC list now.
```

---

## Step 4: Check for spec gap

Using Tech Lead's list of affected areas and PM's confirmed ACs, determine:

**Does a spec already exist for this feature area?**
- Yes → read it, check if any confirmed ACs contradict or extend it
- No → a new spec must be written before implementation

Print:
```
Spec status:
- <spec-name>.md — EXISTS, covers <area> [needs update / no changes needed]
- <feature area> — NO SPEC — will create SPEC-NNN
```

---

## Step 5: Write or update spec (spec-first)

### If spec needs to be created:

```
@tech-lead Write SPEC-NNN for <feature area> based on:
- Confirmed ACs: <list>
- Affected files: <list from Step 2>
- Relevant cross-refs: <existing specs>

Use MUST/SHOULD/MUST NOT language. Save to specs/core/SPEC-NNN-<slug>.md.
Cross-reference any specs that constrain this one.
```

Determine the next SPEC number:
```bash
ls $MROOT/specs/core/ | grep -oP 'SPEC-\K\d+' | sort -n | tail -1
# increment by 1
```

### If spec needs updating:

```
@tech-lead Update <spec-file> to reflect the confirmed ACs for <TICKET-ID>.
Add/modify only what this ticket changes. Do not remove existing requirements
unless they are directly contradicted.
```

Wait for Tech Lead to write/update the spec. Then commit it:

```bash
git add $MROOT/specs/
git commit -m "spec: <TICKET-ID> — add/update <feature area> spec"
```

---

## Step 6: Implementation plan + task graph

```
@tech-lead Produce the implementation plan for <TICKET-ID>.

Confirmed ACs: <list>
Spec: <spec file path>
Affected files (your earlier assessment): <list>

Output:
1. Step-by-step plan saved to $WTROOT/.claude/plans/<YYYY-MM-DD>-<TICKET-ID>-<slug>.md
2. Task graph — which steps are independent (can run in parallel) and which have dependencies
3. For each step: recommended agent (ic4 for well-defined/extending patterns, ic5 for novel/complex),
   and what interface/contract it exposes that other steps depend on

No schema changes or new dependencies without calling them out explicitly.
```

---

## Step 7: Create task graph via TaskCreate

Read the plan Tech Lead produced. For each step, issue a TaskCreate:

```
TaskCreate:
  subject: "<TICKET-ID> Task N — <step title>"
  description: |
    <step description from plan>
    Recommended agent: <ic4|ic5|qa>
    Depends on: [Task IDs] or "none"
    Exposes: <interface/contract other tasks need, if any>
```

Create all tasks. Note their assigned IDs.

Then update the plan file to include the task IDs:
```bash
# Append task map to bottom of plan file
echo "\n## Task Map\n" >> $WTROOT/.claude/plans/<plan-file>.md
# For each task: "- Task N (id:<ID>): <title> [depends on: ...]"
```

---

## Step 8: Print kickoff summary

Print a structured summary the engineer can use as a reference:

```
Kickoff complete for <TICKET-ID>

Spec:       specs/core/SPEC-NNN-<slug>.md [created|updated]
Plan:       .claude/plans/<YYYY-MM-DD>-<TICKET-ID>-<slug>.md
Tasks:      N created

Task Graph:
  id:<N> Task 1 — <title>     → <ic4|ic5>   [ready to claim]
  id:<N> Task 2 — <title>     → <ic5>        [ready to claim]
  id:<N> Task 3 — <title>     → <ic4>        [blocked by Task 1, Task 2]
  id:<N> Task 4 — QA tests    → qa           [ready after Task 2 interface defined]

Parallel work ready:
  @ic4: claim Task 1 via TaskUpdate, start immediately
  @ic5: claim Task 2 via TaskUpdate, start immediately — SendMessage interface to @ic4 and @qa early
  @qa:  claim Task 4 via TaskUpdate, start after @ic5 defines the interface

Next: /standup to monitor progress
```

---

## Error Handling

- **No git repo**: use `pwd` as MROOT; warn that worktree isolation won't work
- **PM finds too many ambiguities (>4 open questions)**: pause and tell the user to clarify the ticket in Linear before proceeding — do not plan against a vague ticket
- **Tech Lead identifies a breaking schema change**: pause and flag to the user; suggest DevOps involvement before creating tasks
- **No specs/ directory**: create `specs/core/` and note it in the summary; this ticket is the first spec
- **Ticket text is too short to plan from**: ask the user to paste the full ticket including ACs
