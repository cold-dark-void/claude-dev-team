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
| Batch-synchronous fleet fan-out (council waves under a Spawn concurrency cap) | Spawn a batch, await every return, then spawn the next batch | Not available | Run the batches one after another in plan order. See "The Spawn concurrency cap fan-out" below; the canonical copy is `skills/council/spawn-contract.md` § Degrade path. |
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

## The Spawn concurrency cap fan-out

A capped council run carries its batch plan in `plan.waves[]`. Each wave runs
in `batch` order: spawn the slots of batch k in one message, await every
return, then run batch k+1.

- **No batch-synchronous fan-out primitive.** Run the batches one after
  another in plan order. Keep blindness: a batch never reads a sibling
  batch's output. Set no `verification_mode` and emit no CDV-199 marker.
  Queueing is not a spawn failure. The canonical degrade path is
  `skills/council/spawn-contract.md` § Degrade path — cite it, do not restate
  it.
- **Known limit: no host-ceiling API.** A host exposes no count of the spawns
  it runs in flight, so the plugin cannot read a host maximum. `waves[]` fixes
  over-dispatch in the plan; it does not fix host queueing. A host that runs
  fewer than X spawns in flight is compliant, and a plan's X is a ceiling,
  never a floor. QA MUST NOT hard-fail a wave-plan-enforced run on an observed
  in-flight spawn count (SPEC-013 `### CDT-594` AC16).
- **Mechanical enforcement on the Grok host: the spawn tripwire (CDT-607).**
  The ceiling is enforced outside the plugin by two host files:
  `~/.grok/hooks/spawn-tripwire.json` runs
  `~/.claude/hooks/spawn-tripwire.sh` as a `PreToolUse` gate on
  `spawn_subagent`, fed by `SubagentStart` and `SubagentStop`. The gate keeps
  a per-host ledger of in-flight subagents, shared across sessions, and denies
  a spawn at 4 in flight (default cap; `SPAWN_TRIPWIRE_MAX` overrides it). It
  fails open: a broken, corrupt, or jq-less tripwire never blocks a spawn. An
  entry older than the 6h TTL is pruned on the next read, so a wedged
  subagent self-heals and releases its slot. The plugin reads nothing from the
  ledger — the deny reason reaches the model only, and `waves[]` stays the
  plan-side fix. The config half runs beside it: `[subagents]` in
  `~/.grok/config.toml` sets `max_concurrent = 3` with
  `limit_behavior = "queue"`.

SPEC-013 § Spawn concurrency cap owns the normative text for these points.
This map carries the per-host note only.

## Scope

- The map covers tools that gate flows and orchestrators call by name.
- The `model` spawn param is in scope for the same reason: the council
  model-pin fence (SPEC-042) depends on how each host treats it.
- The batch-synchronous fan-out is in scope for the same reason: the Spawn
  concurrency cap (SPEC-013) depends on how each host runs a batch of spawns.
- Host-specific setup lives in the host runbook: [oh-my-pi (omp)](runbooks/omp.md).
- Claude Code needs no fallback; every tool above is native there.
