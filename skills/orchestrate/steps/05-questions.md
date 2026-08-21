<!-- /orchestrate phase body. Load via SKILL.md router — current step only. -->

## Step 5: Resolve open questions (escalate to user)

When `[ "$ORCH_TIER" = "light" ]`: if the scoper-planner surfaced open questions, present them to the user (or Autopilot mode) before plan-approve. They MUST NOT be dropped. Feed answers back into the AC list and the plan file. If none, proceed.

Otherwise (omit / `standard` / `full`):

If PM found open questions:

```
@pm found N open questions:

1. <question>
2. <question>

Please answer so we can lock scope.
```

Wait for user answers. Feed them back to PM for final AC list.

If no open questions, proceed.

