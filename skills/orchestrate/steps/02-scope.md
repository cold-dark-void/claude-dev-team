<!-- /orchestrate phase body. Load via SKILL.md router — current step only. -->

## Step 2: Evaluate issue and confirm scope with user

Present the issue summary:

```
Issue: <ISSUE-ID> — <title>
Priority: <priority>
Current status: <status>

Description:
<description summary>

Acceptance Criteria:
1. <AC>
2. <AC>
...

My assessment:
- Complexity: <simple | moderate | complex>
- Estimated agents needed: <list>
- Likely affected areas: <educated guess from issue text + project memory>

Proceed with this scope? Any adjustments?
```

**Autopilot:** if `AUTOPILOT_ON` (Step 0), do NOT wait for the user here. Build the
C3 §2 envelope `{ workflow:"orchestrate", ticket_id:<ISSUE-ID>, gate:"scope-confirm",
run_id:RUN_ID, iteration:ITER, run_start_epoch:RUN_START_EPOCH,
autopilot_bump:AUTOPILOT_BUMP, <issue-text sufficiency evidence, destructive-op flags,
and the complexity signals from the assessment above> }` and call
`skills/autopilot/self-answer.md`'s procedure for `{decision, blocking_condition,
confidence, rationale}` (exactly one `decided_by:"auto"` card is appended). Act on
`decision`:
- `proceed` → continue to Step 3 exactly as the user's "yes" would.
- `reroute-epic` → print the one-line message below, hand off to `/epic` decompose, and
  return control.
  The `/epic` decompose invocation MUST carry the autopilot state forward — pass
  `--autopilot[=<bump>]` (or `AUTOPILOT=1`). When `<bump>` ∈ {patch,minor,major},
  also pass `--worktree --release <bump>` (seal-intent; MUST NOT land each child
  on master). `/epic` persists that bump as `release_bump` (SPEC-033 M11a / CDT-196).
- `halt` → emit `task_blocked` (detail = the one-line message below) via **Passive
  notifications → Tier B** (fail-open; § below), then print the one-line message below and
  return control:
```
scope-confirm <decision>: <rationale> — card: <card-file-path>
```
Otherwise (autopilot off), the user-confirmation gate below applies unchanged.

Wait for user confirmation before proceeding. This is the first escalation gate.

