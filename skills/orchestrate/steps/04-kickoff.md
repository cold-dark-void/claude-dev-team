<!-- /orchestrate phase body. Load via SKILL.md router — current step only. -->

## Step 4: Parallel PM + Tech Lead kickoff

When `[ "$ORCH_TIER" = "light" ]`: spawn exactly one scoper-planner (not parallel PM+TL). Use `@tech-lead` (or a general agent). That agent (1) locks ACs and (2) writes a short (~5-line) plan. Then Step 5. Do not spawn the PM agent or Tech Lead orientation below.

```
You are the scoper-planner for issue <ISSUE-ID> (light tier).

Output mode: terse

<ISSUE CONTEXT>

Your job:
1. Confirm or rewrite each acceptance criterion — unambiguous and testable.
   Flag any scope questions that must be resolved before implementation.
   Add any missing ACs the issue implies but doesn't state.
2. Write a short (~5-line) implementation plan to
   `.claude/plans/<YYYY-MM-DD>-<ISSUE-ID>-<slug>.md` with a Tracking section:

## Tracking
- source: linear | backlog | freeform
- ticket_id: <ISSUE-ID>
- closes:
  - backlog/<slug>.md
  - linear:<ID>
- autopilot_on: <true|false>
- autopilot_bump: <patch|minor|major|master|null>

`autopilot_on`/`autopilot_bump` MUST always be written (Step-0
`AUTOPILOT_ON`/`AUTOPILOT_BUMP`). Empty closes only for freeform.

Do NOT produce a full task graph. Do NOT spawn further agents.
Return your output as this agent's final message — do NOT SendMessage to the
orchestrator; there is no addressable parent.
```

Collect one output. Continue to Step 5.

Otherwise (omit / `standard` / `full`):

Use `/kickoff` logic but adapted — spawn both agents in the worktree:

### PM agent (spawn now):
```
You are @pm. Review issue <ISSUE-ID>:

Output mode: terse

<ISSUE CONTEXT>

Your job:
1. Confirm or rewrite each acceptance criterion — make them unambiguous and testable
2. Flag any scope questions that must be resolved before implementation
3. Add any missing ACs the issue implies but doesn't state
4. Output: revised AC list + open questions (if any)

Do NOT plan implementation. Scope only.
Return your output as this agent's final message — do NOT SendMessage to the
orchestrator; there is no addressable parent.
```

### Tech Lead agent (spawn now, in parallel):
```
You are @tech-lead. Orient on issue <ISSUE-ID> while @pm reviews scope.

Output mode: terse

Issue summary: <title + first 2 sentences>

Your job:
1. Read your cortex.md for architecture context
2. Identify which files/packages this will likely touch
3. Identify existing specs that constrain the design
4. Note technical risks or unknowns

Do NOT produce a plan yet — wait for confirmed ACs.
Output: affected files, relevant specs, risks.
Return your output as this agent's final message — do NOT SendMessage to the
orchestrator; there is no addressable parent.
```

Collect both outputs.

