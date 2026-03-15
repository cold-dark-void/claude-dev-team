# /memory-distill
Compress raw agent memories into digests and promote high-signal knowledge to core tier.

## Usage
/memory-distill [--agent <name>] [--status] [--force]

## Flags
| Flag | Description |
|------|-------------|
| (none) | Distill all agents whose raw memory count meets the threshold |
| `--agent <name>` | Distill a specific agent regardless of threshold |
| `--status` | Show tier counts per agent and current config — no distillation runs |
| `--force` | Clear a stale distillation lock before running |

Flags can be combined: `/memory-distill --force --agent pm`

## Examples

Check how many raw memories each agent has accumulated:
```
/memory-distill --status
```
Output:
```
MEMORY TIER STATUS
================================
agent       raw  archived  digests  core
----------  ---  --------  -------  ----
ic4          12         0        2     1
pm           54         8        3     1
tech-lead    51         6        2     0

Distillation config:
key                  value
-------------------  -------
distill_enabled      true
distill_mode         suggest
distill_model        haiku
distill_threshold    50
================================
```

Run distillation for all agents over the threshold:
```
/memory-distill
```
Output:
```
DISTILLATION COMPLETE
================================
  @pm        54 raw -> 3 digests | 1 promoted to core
  @tech-lead 51 raw -> 2 digests | 0 promoted to core
================================
Lock released.
```

Distill a single agent immediately, bypassing the threshold check:
```
/memory-distill --agent ic4
```

## How It Works
`/memory-distill` reads tier-0 (raw) memories from the SQLite memory database, batches them oldest-first, and spawns the `@distiller` agent (using the configured `distill_model`, defaulting to Haiku) to compress each batch into tier-1 digest entries. After compression, each digest is evaluated for promotion to tier-2 core — the permanent, highest-signal knowledge store. The consumed tier-0 rows are archived rather than deleted, so the full history is always recoverable.

A compare-and-swap lock prevents two distillation runs from overlapping. If a previous run crashed and left the lock set, use `--force` to clear it. Manual invocation always proceeds even if `distill_enabled` is set to `false`.

## See Also
- [/memory-config](memory-config.md) — view and change distillation settings (threshold, mode, model)
- [/memory-search](memory-search.md) — search across all agent memories
