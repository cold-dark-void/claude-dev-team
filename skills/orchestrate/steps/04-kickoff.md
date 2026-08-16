<!-- /orchestrate phase body. Load via SKILL.md router — current step only. -->

## Step 4: Parallel PM + Tech Lead kickoff

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

