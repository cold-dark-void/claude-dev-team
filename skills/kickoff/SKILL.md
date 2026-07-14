---
name: kickoff
description: |
    Orchestrate the full ticket intake and planning phase — parallel PM+Tech Lead
    kickoff, spec creation, implementation plan, and TaskCreate task graph. Replaces
    7 manual prompts with one command. Usage: /kickoff <TICKET-ID> "<ticket text>"
    or /kickoff alone to be prompted.
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

## Accepted escalation handoff (input contract)

When `/kickoff` is reached as an escalation target from `/debug` (scope =
escalate-to-kickoff, or arch mode) or `/refactor` (scope exceeds inline work),
the `<ticket text>` argument is the producer's structured handoff. This is the ONE
canonical contract both producers emit and `/kickoff` consumes — per SPEC-014 §
Escalation and SPEC-015 § Escalation, which each MUST a 4-field structured handoff.

The handoff MUST contain exactly these four fields:

```
ROOT CAUSE: <root-cause statement (/debug) or design-problem statement (/refactor)>
AFFECTED FILES:
  - <file or module>
PROPOSED APPROACH: <2-3 sentences describing the intended fix or structural change>
WHY INLINE REJECTED: <one of the canonical reasons below>
```

**Canonical `WHY INLINE REJECTED` vocabulary** (shared by `/debug` and `/refactor`;
producers MUST emit one of these verbatim, consumers validate against this set):

- `cross-subsystem or multi-directory refactor required`
- `architectural decision required`
- `tech-lead design review required`
- `arch mode — design decision required` (`/debug` arch mode only)
- `callsite count exceeded threshold`

On intake, `/kickoff` treats this 4-field text as the ticket body: ROOT CAUSE and
PROPOSED APPROACH seed the ticket summary, AFFECTED FILES seed the Tech Lead's
affected-files assessment (Step 2), and WHY INLINE REJECTED records why the work
could not be resolved inline. If a field is missing or WHY INLINE REJECTED is not
one of the canonical values, treat the handoff as a malformed ticket and ask the
producer (or user) to re-emit it before planning.

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
    HAS_DISTILLED=$(sqlite3 "$MEMDB" "SELECT COUNT(*) FROM memories WHERE agent='claude' AND tier > 0 AND archived=FALSE;")
    if [ "$HAS_DISTILLED" -gt 0 ]; then
      sqlite3 "$MEMDB" "SELECT content FROM memories WHERE agent='claude' AND tier=2 AND archived=FALSE ORDER BY type, updated_at DESC;"
      sqlite3 "$MEMDB" "SELECT content FROM memories WHERE agent='claude' AND tier=1 AND archived=FALSE ORDER BY type, updated_at DESC;"
    else
      sqlite3 "$MEMDB" "SELECT content FROM memories WHERE agent='claude' AND tier=0 AND archived=FALSE ORDER BY type, created_at DESC;"
    fi
  else
    cat "$MROOT/.claude/memory/claude/memory.md" 2>/dev/null
  fi
  ```
- Tech Lead cortex:
  ```bash
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
- `$MROOT/AGENTS.md` (project rules)

Scan `specs/` for specs likely related to the ticket (SPEC-008 `### Spec Discovery`):
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

Output mode: terse

<TICKET TEXT>

Your job:
1. Confirm or rewrite each acceptance criterion — make them unambiguous and testable
2. Flag any scope questions that must be resolved before implementation starts
3. Add any missing ACs that the ticket implies but doesn't state
4. Output: revised AC list + list of open questions (if any)

Do NOT start planning implementation. Scope only.
Return your output as this agent's final message — do NOT SendMessage to the
orchestrator; there is no addressable parent.
```

### Tech Lead prompt (send now, in parallel):
```
You are @tech-lead. Orient on ticket <TICKET-ID> while @pm reviews scope.

Output mode: terse

Ticket summary: <first 2 sentences of ticket text>

Your job right now (before ACs are confirmed):
1. Read your cortex.md for architecture context
2. Identify which files/packages this ticket will likely touch
3. Identify any existing specs that constrain the design
4. Note any technical risks or unknowns
5. List any external API parameters, library/SDK flags, model capabilities, or
   endpoint behaviors this ticket would ASSUME work — these feed the verification
   gate before the spec is written. If none, say "no external assumptions".

Do NOT produce a plan yet — wait for confirmed ACs.
Output: affected files, relevant specs, risks, assumed external behaviors.
Return your output as this agent's final message — do NOT SendMessage to the
orchestrator; there is no addressable parent.
```

### Codebase Explorer prompt (send now, in parallel — Sonnet):
```
You are a codebase exploration agent. Deep-dive the codebase to map how
the area related to ticket <TICKET-ID> currently works.

Output mode: terse

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

## Step 4b: Verify external API/behavior assumptions (conditional gate)

Before any spec or plan is written, check whether the ticket depends on an
**external API parameter, library/SDK flag, model capability, endpoint behavior,
or config flag** whose behavior is not already proven in this codebase. Use the
Tech Lead's "assumed external behaviors" (Step 2) plus the confirmed ACs.

**If there are none** (pure UI, internal refactor, docs, etc.), print one line and
continue to Step 5:
```
GATE 1 (API verification): no external assumptions to verify — skipped.
```

**If there are**, spawn a verification agent NOW — before the spec locks in the design:
```
You are a verification agent. Do NOT write production code or a spec.

Output mode: terse

For each assumed external behavior below, empirically determine whether it is real
and honored, in this order of preference:
1. Grep this codebase for existing, proven usage.
2. Run the smallest possible probe and observe the actual result.
3. Cite official docs for the exact parameter/flag and version.

Assumptions to verify:
<one per line, from Tech Lead's list + confirmed ACs>

Output a table — Assumption | Verdict (HONORED / IGNORED / DECORATIVE / UNKNOWN) |
Evidence (command output, file:line, or doc URL). Never guess: UNKNOWN is the
required answer when you cannot prove it. Do not SendMessage the orchestrator;
return the table as your final message.
```

Present the table to the user, then gate:
- Every assumption a **confirmed AC depends on** that returns `IGNORED`, `DECORATIVE`,
  or `UNKNOWN` → **pause**. Surface it and ask the user whether to (a) drop/rework
  that AC, or (b) proceed with it explicitly marked unverified. Do NOT silently
  design around an unproven capability.
- `HONORED` assumptions → proceed.

Carry the verified table into Step 5: the spec MUST record what is proven vs. what
is decorative/no-op, so the design never quietly relies on an unverified behavior.

---

## Step 5: Write or update spec (spec-first)

### If spec needs to be created:

```
@tech-lead Write SPEC-NNN for <feature area> based on:
- Confirmed ACs: <list>
- Affected files: <list from Step 2>
- Relevant cross-refs: <existing specs>

Follow the SPEC-008 format contract (required sections, status taxonomy, index columns).
Save to specs/core/SPEC-NNN-<slug>.md.
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
   and what interface/contract it exposes that other steps depend on.

   Escalation heuristic: assign ic5 (not ic4) when a task:
   - Touches more than 10 files
   - Requires deleting/modifying code across more than 15 callsites
   - Involves wide-scope structural refactoring (e.g. removing a mode, renaming a concept)
   - Has unclear replacement strategy (each removed usage needs a different fix)
   ic4 excels at focused, well-scoped tasks. Wide-scope structural work burns excessive
   ic4 context (300+ messages observed). Either assign ic5, or split the task further.

No schema changes or new dependencies without calling them out explicitly.
For each task, list dependencies as `Depends on: <TaskID>, <TaskID>` or `Depends on: none` so kickoff can extract them programmatically.
```

---

## Step 7: Create task graph via TaskCreate

Before creating any tasks, extract the dependency graph from the Tech Lead plan:
1. For each task in the plan, note its ID (Task 1, Task 2, etc.) and its "Depends on:" list
2. Build a JSON array: `[{"task_id": "TICKET-N", "depends_on": ["TICKET-M", ...]}, ...]`
3. Write the dependency JSON to `$DAG_FILE` and run:
   ```bash
   DAG_FILE="${TMPDIR:-/tmp}/kickoff-dag-$$.json"
   CYCLE_ERR="${TMPDIR:-/tmp}/kickoff-cycle-err-$$.txt"
   # (caller already wrote the dependency JSON into $DAG_FILE)
   # Re-resolve PDH (each bash fence is a fresh shell)
   PDH=$( [ -f skills/plugin-dir.sh ] && pwd || find ~/.claude/plugins/cache -path '*/dev-team/*/skills/plugin-dir.sh' 2>/dev/null | sort -V | tail -1 | xargs -r dirname | xargs -r dirname )
   DAG_LIB=$(bash "$PDH/skills/plugin-dir.sh" file skills/orchestrate/dag-lib.sh)
   bash "$DAG_LIB" check-cycle "$DAG_FILE" 2>"$CYCLE_ERR"
   rc=$?
   if [ "$rc" -eq 1 ]; then
     # $CYCLE_MSG is the detected back-edge ("cycle: <from> -> <to>"), not a full path.
     CYCLE_MSG=$(cat "$CYCLE_ERR" 2>/dev/null || true)
     rm -f "$DAG_FILE" "$CYCLE_ERR"
     echo "Kickoff error: circular dependency detected ($CYCLE_MSG). Revise the task graph."
     # halt — do NOT call TaskCreate for any task
   elif [ "$rc" -ne 0 ]; then
     DIAG=$(cat "$CYCLE_ERR" 2>/dev/null || true)
     rm -f "$DAG_FILE" "$CYCLE_ERR"
     echo "Kickoff error: cycle gate could not run (rc=$rc): $DIAG"
     # halt — do NOT call TaskCreate for any task
   fi
   rm -f "$DAG_FILE" "$CYCLE_ERR"
   ```
   Do NOT call TaskCreate for any task if a cycle is detected or the cycle gate could not run.

Then detect quality-check mode:
```bash
# Re-resolve PDH (each bash fence is a fresh shell)
PDH=$( [ -f skills/plugin-dir.sh ] && pwd || find ~/.claude/plugins/cache -path '*/dev-team/*/skills/plugin-dir.sh' 2>/dev/null | sort -V | tail -1 | xargs -r dirname | xargs -r dirname )
DETECT_CLI=$(bash "$PDH/skills/plugin-dir.sh" file skills/ci-watch/detect-mode.sh)
QC_MODE=$(bash "$DETECT_CLI" "$WTROOT" | head -n1)
```

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

After each TaskCreate, register the task in the task store with its dependencies:
```bash
# Build colon-separated depends_on from plan dep list
# Map to compound keys: replace "Task N" with "<TICKET>-<taskid>"
# e.g. if Task 3 depends on Task 1 and Task 2, and TICKET-ID is CDV-1:
#   DEPS="CDV-1-1:CDV-1-2"
# If no deps:
#   DEPS=""
DEPS=$(echo "<dep task IDs from plan, space/comma-separated>" | tr ', ' ':' | tr -s ':' | sed 's/^://;s/:$//')
# Replace each "Task N" reference with "<TICKET-ID>-N" compound key
# Re-resolve PDH (each bash fence is a fresh shell)
PDH=$( [ -f skills/plugin-dir.sh ] && pwd || find ~/.claude/plugins/cache -path '*/dev-team/*/skills/plugin-dir.sh' 2>/dev/null | sort -V | tail -1 | xargs -r dirname | xargs -r dirname )
TASK_STORE=$(bash "$PDH/skills/plugin-dir.sh" file skills/orchestrate/task-store.sh)
bash "$TASK_STORE" create "<TICKET-ID>-<task_id>" "<subject>" <requires_council> "$DEPS"
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
Quality check: <ci|local-test|none>  (detected via skills/ci-watch/detect-mode.sh $WTROOT)

Parallel work ready:
  @ic4: claim Task 1 via TaskUpdate, start immediately
  @ic5: claim Task 2 via TaskUpdate, start immediately — SendMessage interface to @ic4 and @qa early
  @qa:  claim Task 4 via TaskUpdate, start after @ic5 defines the interface

Next: /standup to monitor progress
```

---

## Step 8b: Friction check (non-blocking)

After printing the kickoff summary, silently check whether the current session
has accumulated enough friction to warrant a retrospective. This check is
entirely non-blocking: if anything fails, print nothing and move on.

```bash
# Locate the dev-team plugin root (PDH). Dev checkout first, else installed cache (highest version). Slug-free, sort -V.
PDH=$( [ -f skills/plugin-dir.sh ] && pwd || find ~/.claude/plugins/cache -path '*/dev-team/*/skills/plugin-dir.sh' 2>/dev/null | sort -V | tail -1 | xargs -r dirname | xargs -r dirname )
bash "$PDH/skills/retro-gate/hint.sh" 2>/dev/null || true
```

Rules:
- Do **not** auto-run `/retro`. The single printed line is a suggestion only.
- Do **not** surface any error output from gate.sh or from path resolution.
- If gate.sh is missing, the session JSONL is missing, or the gate returns `passed:false`, print nothing.
- This section must never block or delay the rest of the kickoff output.

---

## Error Handling

- **No git repo**: use `pwd` as MROOT; warn that worktree isolation won't work
- **PM finds too many ambiguities (>4 open questions)**: pause and tell the user to clarify the ticket in Linear before proceeding — do not plan against a vague ticket
- **Tech Lead identifies a breaking schema change**: pause and flag to the user; suggest DevOps involvement before creating tasks
- **No specs/ directory**: create `specs/core/` and note it in the summary; this ticket is the first spec
- **Ticket text is too short to plan from**: ask the user to paste the full ticket including ACs
