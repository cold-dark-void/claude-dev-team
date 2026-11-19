# Host tool map

How agent-facing tools map across hosts. Claude Code is the reference
host and is unchanged. Use this map when you run the plugin on another
host (for example omp or Grok) or when you port a workflow.

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
| `model` param on a spawn (`Task` / `spawn_subagent`, Workflow `agent()`) | Ignored for a namespaced `dev-team:*` roster spawn — the plugin agent file's frontmatter `model:` sets the model (CDT-641) | Honoured. With no `model`, the spawn inherits the session model | Pass an explicit model at every covered council/workflow spawn (SPEC-042 M2): a map-resolved role uses its Model map value, and its SPEC-003 § Tier-default alias when the map is empty; a tool-less scribe-class role pins `sonnet`. Never omit at a covered site. On a model-attributed reject, retry once with the sibling alias, never with `model` omitted (SPEC-042 M4). |

## The model param on a spawn

The pin in the row above bites only where the host honours the param
(SPEC-042).

- Claude Code: a Task-path spawn of a namespaced agent (`dev-team:*`) ignores
  an explicit `model`. The plugin file's frontmatter `model:` decides. So
  passing the Tier-default alias explicitly changes nothing there, and the
  SPEC-042 M7 parity guard holds trivially on this host.
- Grok host: the param is live, and a spawn with no `model` inherits the
  session model. Every covered council/workflow spawn needs the explicit pin.

Keep the pin on both hosts. Do not add a host probe for model validity; the
single sibling-alias retry is the whole check (SPEC-042 M4).

## Scope

- The map covers tools that gate flows and orchestrators call by name.
- The `model` spawn param is in scope for the same reason: the council
  model-pin fence (SPEC-042) depends on how each host treats it.
- Host-specific setup lives in the host runbook: [oh-my-pi (omp)](runbooks/omp.md).
- Claude Code needs no fallback; every tool above is native there.
