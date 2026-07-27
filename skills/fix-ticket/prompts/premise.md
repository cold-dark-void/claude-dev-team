---
name: fix-ticket-premise
description: |
  Read-only premise verification prompt for /debug ticket. Confirms the
  documented bug still exists; returns structured premise including sibling
  grep. Spawned as ic5. Placeholders: {{TICKET}} {{WORKTREE}} {{BUG}}
---

# Premise prompt template

Runtime template for the Verify-premise phase. Orchestrator substitutes
`{{TICKET}}`, `{{WORKTREE}}`, `{{BUG}}` before the Task spawn.

---

## Prompt body (pasted into the Task tool)

```
You are verifying whether a documented bug ({{TICKET}}) STILL EXISTS in the
CURRENT code. Do NOT edit anything — read only.
Output mode: terse.

Worktree to inspect: {{WORKTREE}}
Documented bug: {{BUG}}

Read the relevant CURRENT files under {{WORKTREE}} (line numbers may have
moved). Confirm whether the bug is present as described.

Required work:
1. Locate CURRENT file:line of the bug as it exists now.
2. State concise evidence of the wrong behavior.
3. Note any scope nuance the fixer must know.
4. Grep for SIBLING occurrences of the same bug pattern across the worktree
   (no whack-a-mole later — list every hit).
5. If a correct reference implementation exists elsewhere, give its file:line.

Return a structured object:
{
  "holds": true|false,   // true = bug still exists as described
  "current_locations": ["file:line", ...],
  "evidence": "<concise wrong behavior>",
  "scope_notes": "<nuance or empty>",
  "sibling_occurrences": ["file:line", ...],
  "reference_impl": "<file:line or empty>"
}

holds and evidence are required. If the bug is gone or was misstated,
holds=false with evidence explaining why.
```
