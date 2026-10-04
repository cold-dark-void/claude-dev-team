# /adjust-agent

View and manage per-agent behavioral directives — standing orders that load
before memory, persist across sessions, and cannot be overridden by the
agent's own reasoning. Also writes the local Model map via `--model` /
`--effort`. Conflicts are flagged, never silently ignored.

The 7 behavioral agents (`pm`, `tech-lead`, `ic5`, `ic4`, `devops`, `qa`, `ds`)
carry directives. The SPEC-003 non-behavioral roster (`finder`, `debugger`,
`project-init`, `distiller`, `council-judge`, `council-scribe`) does not —
`council-judge`, `finder`, and `debugger` are mappable for the Model map only.

## Usage

```
/adjust-agent
/adjust-agent <agent>
/adjust-agent <agent> <prompt>
/adjust-agent <agent> --apply <prompt>
/adjust-agent <agent> --model <string> | --model-unset
/adjust-agent <agent> --effort <low|medium|high|xhigh|max> | --effort-unset
```

| Args | Action |
|------|--------|
| _(none)_ | Dashboard: all agents + directive counts (also the local Model map) |
| `<agent>` | Read-only view of that agent's directives |
| `<agent> <prompt>` | Conversational adjustment with conflict detection |
| `--apply <prompt>` | Non-interactive apply: applies on no conflict, exits non-zero on conflict — never prompts |
| `--model <string>` | Write the local Model map (`write-model.sh set`) |
| `--model-unset` | Delete the agent's local Model map key |
| `--effort <token>` | Write the local effort key (`set-effort`; `low\|medium\|high\|xhigh\|max`) |
| `--effort-unset` | Delete the agent's local effort key |

`--model` and `--effort` may appear together; each writes only its own field.
They are not a directives conversation and never fall through to the prompt path.

## Files

- Directives: `.claude/memory/<agent>/directives.md` (numbered, one per line,
  local — never committed)
- Local Model map: `$MROOT/.claude/dev-team/models.local.json` (never repo or
  global layers)

## Load order

Directives load **before** memory: directives → memory → context.

## See also

- [`/setup models`](setup.md) — the same local Model map via `/setup models`
- [Setup guide](../setup.md) — memory layout and tiers
