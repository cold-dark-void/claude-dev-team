<!-- /orchestrate phase body. Load via SKILL.md router — current step only. -->

## Step 2: Evaluate issue and confirm scope with user

When `[ "$ORCH_TIER" = "null" ]` (no `--tier` on this run): classify S/M/L from cheap signals with NO extra agent spawn: AC count, estimated files touched, bugfix-vs-feature shape, diff-size guess. Mapping: S → light, M → standard, L → full. Classification failure or missing signals → propose `standard`. Show proposed tier + one-line rationale in THIS same gate (not a new gate). Autopilot `proceed` uses the proposed tier unless overridden. Decision-card records proposed + selected. After confirm/override, bind `ORCH_TIER=<selected>` (`light` / `standard` / `full`).
`ORCH_TIER` S/M/L (pipeline `light`/`standard`/`full`) is **not** `budget.tier` (N14). Do not bind them.

When `--tier` was explicit (`light` / `standard` / `full` already bound in Step 0): skip classification; the flag wins. Still show the resolved tier in the gate for visibility.

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
- Proposed tier: <light|standard|full> (<S|M|L> — <one-line rationale>)
  (when `--tier` was explicit: Resolved tier: <value> (flag) — skip Proposed)

Proceed with this scope? Any adjustments? Confirm or override the tier.
```

**Autopilot:** if `AUTOPILOT_ON` (Step 0), do NOT wait for the user here. Pre-freeze:
MUST NOT pass auto-tune signals `tasks` / `projected_loc` / `waves` (argc=2; S-tighter
caps are not in force — AC9). Build the
C3 §2 envelope `{ workflow:"orchestrate", ticket_id:<ISSUE-ID>, gate:"scope-confirm",
run_id:RUN_ID, iteration:ITER, run_start_epoch:RUN_START_EPOCH,
autopilot_bump:AUTOPILOT_BUMP, max_loc:MAX_LOC, <issue-text sufficiency evidence, destructive-op flags,
and the complexity signals from the assessment above, proposed_tier, selected_tier> }` and call
`skills/autopilot/self-answer.md`'s procedure for `{decision, blocking_condition,
confidence, rationale}` (exactly one `decided_by:"auto"` card is appended). Act on
`decision`:
- `proceed` → continue to Step 3 exactly as the user's "yes" would. Use the proposed tier unless overridden. Bind `ORCH_TIER=<selected>`.
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

