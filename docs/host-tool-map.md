# Host tool map

How agent-facing tools map across hosts. Claude Code is the reference
host and is unchanged. Use this map when you run the plugin on another
host (for example omp) or when you port a workflow.

One rule: when the host lacks a tool, degrade gracefully. Print the
would-be action and continue, or halt per the gate's fail mode. Never
fabricate tool output.

| Tool | Claude Code | omp | Fallback guidance |
|------|-------------|-----|-------------------|
| `TaskCreate` / `TaskUpdate` | Native shared task list | `task` / `todo` tools | Use the host task or todo tool. If the host has neither, print the task state change and continue. |
| `SendMessage` | Peer-to-peer teammate DM and broadcast | Not available | Do not assume an addressable orchestrator. Return work as your final output; the spawn caller reads the return value. |
| `AskUserQuestion` | Interactive prompt | `ask` tool | If the host has no ask path, print the question and halt per the gate's fail mode. Never self-answer a gate. |
| `CronCreate` | Durable scheduled task | Not available | Use session-only scheduling or print the would-be cron line. `/ci-watch` documents this degrade (session-only when durable is denied). |
| Agent teams (`TaskList`, teammates, config) | Native teams | Not available | Spawn via the host subagent mechanism, or run the role inline and mark the result self-verified per the fleet-degradation rule. |

## Scope

- The map covers tools that gate flows and orchestrators call by name.
- Host-specific setup lives in the host runbook: [oh-my-pi (omp)](runbooks/omp.md).
- Claude Code needs no fallback; every tool above is native there.
