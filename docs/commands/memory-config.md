# /memory-config
View and update memory distillation configuration.

## Usage
/memory-config list
/memory-config set <key> <value>

## Flags
This command uses subcommands rather than flags.

| Subcommand | Description |
|------------|-------------|
| `list` | Print all distillation config keys, their current values, and last-updated timestamps |
| `set <key> <value>` | Update a config key to a new value |

## Settable Keys
| Key | Values | Default | Description |
|-----|--------|---------|-------------|
| `distill_enabled` | `true` / `false` | `false` | Master switch for automatic distillation |
| `distill_mode` | `manual` / `suggest` / `auto` | `suggest` | When distillation triggers |
| `distill_threshold` | integer 1–9999 | `50` | Raw memory count per agent before distillation is triggered |
| `distill_model` | model name | `haiku` | LLM used by the `@distiller` agent for compression |

Read-only keys (`distilling_lock`, `schema_version`) cannot be set manually.

## Examples

Show current configuration:
```
/memory-config list
```
Output:
```
key                  value    updated_at
-------------------  -------  -------------------
distill_enabled      false    2026-01-10 09:00:00
distill_mode         suggest  2026-01-10 09:00:00
distill_model        haiku    2026-01-10 09:00:00
distill_threshold    50       2026-01-10 09:00:00
```

Enable automatic distillation:
```
/memory-config set distill_enabled true
```
Output:
```
Updated: distill_enabled = true
```

Lower the threshold so distillation triggers sooner:
```
/memory-config set distill_threshold 25
```

## How It Works
Configuration is stored in the `config` table of the project's SQLite memory database (`.claude/memory/memory.db`). `/memory-config list` reads all `distill*` keys from that table. `/memory-config set` validates the value against the key's allowed range or enum before writing, so invalid values are rejected with a clear error message before any change is made.

The `distill_mode` setting controls how distillation is triggered: `manual` means only explicit `/memory-distill` invocations run it; `suggest` means agents may remind you to run it when counts are high; `auto` means agents trigger it themselves when the threshold is crossed.

## See Also
- [/memory-distill](memory-distill.md) — run distillation
- [/memory-search](memory-search.md) — search across all agent memories
