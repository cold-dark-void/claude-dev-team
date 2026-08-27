<!-- /orchestrate phase body. Load via SKILL.md router — current step only. -->

## Orchestrator Rules

These rules apply to YOU (the main Claude) throughout the entire flow:

1. **You do NOT write code.** Not even "small fixes". Route everything through agents.
2. **You do NOT make architectural decisions.** That's Tech Lead's job. You facilitate.
3. **You DO escalate** when triggers are hit (Step 8). Err on the side of asking.
4. **You DO track state** — keep a mental model of which tasks are in which state.
5. **You DO keep Linear updated** (if available) at each phase transition.
6. **You DO keep the user informed** with concise status updates at natural milestones.
7. **You DO protect the user's time** — batch questions, don't interrupt for routine progress.
8. **You DO close trackers at ship** — plan `closes:` local write-through always;
   Linear **In Review** on PR-stop, Linear **Done** only when on master (Step 11
   lifecycle). Wrap re-Dones as safety net. Never leave close-out as optional hygiene.
   **Never** stage process trackers (`.claude/backlog*`, `.claude/plans*`) into the
   product commit.
9. **You DO ship glossary with the feature** — `CONTEXT.md` write-back belongs on
   `$WT_PATH` and lands with the ticket (Steps 3b/6b + ship glossary gate). Never
   leave crystallized terms as uncommitted dirt on `$MROOT` while specs/code ship.

---

## Passive notifications (CDV-210)

Tiered, fail-open progress visibility for long `/orchestrate` runs. **Never block**
orchestration on notify failures. Unset MCP + unset `AGENT_WEBHOOK_URL` → silent
(today's behavior). Dual delivery is OK when both MCP and webhook are available.

### Tier A — MCP (human milestones)

At each milestone below, if any Slack/Discord MCP tool is available
(`mcp__slack__*` / `mcp__discord__*` or project-equivalent), post a **short**
summary (one line + ticket/task id). Missing tools = skip. Never block.

| Milestone | When |
|-----------|------|
| task completed | Agent spawn returns success; after `TaskUpdate(completed)` |
| task blocked (+ reason) | Agent/task enters blocked; after `TaskUpdate(blocked)` |
| QA pass / QA fail | Step 10 QA terminal report |
| council finished | `/council` returns — verdict one-liner **or** findings one-liner |
| unrecoverable error / hard stop | Orchestration cannot continue |

Do **not** notify on routine progress (lint, intermediate test flakes the IC is
fixing, CI-watch polls).

### Tier B — Webhook (`AGENT_WEBHOOK_URL`)

When `AGENT_WEBHOOK_URL` is set, fire the shared fail-open helper at the same
milestones. Resolve via plugin-dir (fresh shell each fence):

```bash
# lint-ok: C3 — marketplace */ for-loop + -f guarded (SPEC-021 Q2 residual, CDT-82 PDH)
PDH=$( { [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -f "$CLAUDE_PLUGIN_ROOT/skills/plugin-dir.sh" ] && printf '%s\n' "$CLAUDE_PLUGIN_ROOT"; } || { [ -f skills/plugin-dir.sh ] && pwd; } || { for _mp in "$HOME"/.claude/plugins/marketplaces/*/; do [ -f "${_mp}skills/plugin-dir.sh" ] && [ -f "${_mp}agents/pm.md" ] && printf '%s\n' "${_mp%/}" && break; done; } || find ~/.claude/plugins/cache -path '*/dev-team/*/skills/plugin-dir.sh' 2>/dev/null | awk -F/ '{ver=""; for(i=1;i<=NF;i++) if($i=="dev-team"&&i<NF){ver=$(i+1);break}; if(ver=="") next; m=ver; gsub(/-pre\./,"~pre.",m); p=($0 ~ /\/cache\/cold-dark-void\/dev-team\//)?1:0; print m "\t" p "\t" $0}' | sort -t $'\t' -k1,1V -k2,2n -k3,3 | tail -1 | cut -f3 | xargs -r dirname | xargs -r dirname )
NOTIFY=$(bash "$PDH/skills/plugin-dir.sh" file skills/notify/webhook.sh)
# Optional context (omit empty):
#   NOTIFY_SOURCE=orchestrate  NOTIFY_AGENT=<agent>  NOTIFY_TASK=<task_id>  NOTIFY_TICKET=<ISSUE-ID>
NOTIFY_SOURCE=orchestrate NOTIFY_TICKET="<ISSUE-ID>" NOTIFY_TASK="<task_id>" NOTIFY_AGENT="<agent>" \
  bash "$NOTIFY" <event> "<detail ≤500 chars>"
```

**Event enum:**

| Event | Orchestrate call site |
|-------|----------------------|
| `task_complete` | Task completed (optional: TaskCompleted hook also emits with `source=task_completed`) |
| `task_blocked` | Task blocked — detail = reason |
| `qa_pass` | Step 10 QA PASS |
| `qa_fail` | Step 10 QA FAIL — detail = short failure list |
| `council_verdict` | Council finished with verdict[] — detail = verdict one-liner |
| `council_findings` | Council finished with findings only — detail = findings one-liner |
| `error` | Unrecoverable error / hard stop — detail = short cause |

`scheduled_retro` remains **CDV-190-owned** (`write-scheduled-report.sh`); same
URL is fine. Helper always exits 0 (`curl -m 5 || true`). Payload fields:
`event`, `time` (ISO-UTC), `source`; optional `agent` / `task` / `ticket` /
`detail` (≤500). **No secrets, transcripts, or file bodies.**

### Tier C — Silent

Neither MCP tools nor `AGENT_WEBHOOK_URL` → zero I/O beyond existing user-facing
status lines.

---

## Change Discipline

These rules constrain how work is structured. Violating them is an escalation trigger.

### Atomic PRs — one logical change per PR

- Each ticket = its own branch + its own PR. Never bundle multiple tickets into one change.
- A PR should do ONE thing. If the description needs "and" to explain it, it's too big.

### Size limits

Caps apply to **counted** LOC (SPEC-033 M15 — cite; do not fork). Same exclusion as autopilot BC4 / M10.1. Classify with `skills/autopilot/loc-exclude.sh is-excluded <path>` (exit 0 = excluded, 1 = count). Specs and tests stay exempt (M15 arm 3; the helper does not classify tests). Lockfiles, `*.snap`, and vendored prefixes (`vendor/`, `third_party/`, `node_modules/`) are also excluded (M15 arm 2 / helper). `.gitattributes linguist-generated` excludes via arm 1.

- **~1,000 counted LOC** per PR (soft cap, non-halting). Specs, tests, migrations, and M15-excluded paths do not count.
- **Hard cap: 2,000 counted LOC** per PR (default). Tests are **not** in this cap. If counted change exceeds this, split the PR.
- **No single counted file > 1,000 lines.** If a counted file approaches this, pause and discuss decomposition with Tech Lead before continuing.

When a task would exceed these limits, the orchestrator must:
1. Stop the IC agent
2. Have Tech Lead split the task into smaller, shippable increments
3. Each increment gets its own task, branch, and PR
4. Increments ship sequentially — each must be green and mergeable on its own

### Refactoring is always a separate PR

If implementation requires refactoring existing code:
1. **Stop implementation.** Do not mix refactoring with feature work.
2. Have Tech Lead design the refactor — what changes, what stays, what's the migration path.
3. Ship the refactor PR first. Get it merged.
4. Resume feature implementation on top of the clean base.

If the refactor is large enough to warrant its own ticket, create one (in Linear if available, otherwise `/backlog add`).

### Discovered work → new tickets

When agents discover work that wasn't in the original plan:
- **Do NOT absorb it** into the current PR.
- Create a new ticket (Linear if available, otherwise `/backlog add`).
- If it blocks the current work, escalate to user with: "This blocks <ISSUE-ID>. Create a blocking ticket and do it first, or defer?"

### Replan gate

Whenever the approach changes materially — new dependencies discovered, scope expanded, architecture assumption invalidated:
1. **Pause all IC work.**
2. Spawn Tech Lead to replan.
3. Present updated plan to user for approval.
4. Only resume after user confirms.
5. When regenerating the plan file, re-write the `## Tracking` `autopilot_on`/
   `autopilot_bump` lines with the current run's Step-0 values (same rule as
   Step 6 — CDT-111-C8 AC1; never drop them on replan).

This applies even if the change seems small. Small deviations compound.

---

## Error Handling

Task metadata writes via `skills/orchestrate/task-store.sh` are **distinct from** the Claude Code TaskList / TaskCreate / TaskUpdate tools. Both tracks must stay in sync: TaskCreate → `task-store.sh create`, each TaskUpdate → `task-store.sh update-status`. If either track fails, the orchestrator MUST surface the failure to the user rather than silently diverging. The task store is the persistent source of truth for the TaskCompleted council gate (SPEC-002); TaskList is the in-session state.

- **No git repo**: warn; skip worktree, work in current directory
- **Linear MCP unavailable**: fall back to prompted context; use plans for tracking instead
- **Agent fails to start**: retry once, then report to user with error details
- **Worktree already exists for this issue**: `worktree-lib.sh ensure` reuses it silently (writes a fresh lock). A prompt only appears if another live PID holds the lock — in that case surface the lib's stderr output to the user.
- **Branch already exists**: check if it has unmerged work; ask user before resetting
- **All agents stuck**: don't panic — present the full state to user and ask for direction
- **User goes AFK mid-flow**: pause gracefully; state is in tasks + plan file; resumable
