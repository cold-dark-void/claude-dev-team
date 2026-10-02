<!-- /orchestrate phase body. Load via SKILL.md router — current step only. -->

## Step 5: Resolve open questions (escalate to user)

**Autopilot:** if `AUTOPILOT_ON` (Step 0) and any open question is still open, do NOT wait on the user. Build the C3 §2 envelope `{ workflow:"orchestrate", ticket_id:<ISSUE-ID>, gate:"scope-confirm", run_id:RUN_ID, iteration:ITER, run_start_epoch:RUN_START_EPOCH, autopilot_bump:AUTOPILOT_BUMP, max_loc:MAX_LOC, <the open questions> }` and call `skills/autopilot/self-answer.md` (expected: BC1 → `halt`). On `halt`, emit `task_blocked` via **Passive notifications → Tier B** (`cross-cutting.md`), print `scope-confirm halt: <rationale> — card: <card-file-path>`, and return. Do not block.

When `[ "$ORCH_TIER" = "light" ]`: if the scoper-planner surfaced open questions and autopilot is off, present them to the user before plan-approve. They MUST NOT be dropped. Feed answers back into the AC list and the plan file. If none, proceed.

Otherwise (omit / `standard` / `full`), and autopilot is off:

If PM found open questions:

```
@pm found N open questions:

1. <question>
2. <question>

Please answer so we can lock scope.
```

Wait for user answers. Feed them back to PM for final AC list.

If no open questions, proceed.

