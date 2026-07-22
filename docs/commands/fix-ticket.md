# /fix-ticket

> **Deprecated** — removed at v1.0.0 (CDT-46-C4). Use **[`/debug ticket`](./debug.md)** instead.
> This page remains as a redirect until v1.1.

Premise → implement → adversarial refuters for a **known** bug ticket. Verifies
the bug still exists, applies the smallest fix in a SPEC-016 worktree, spawns
parallel qa refuters, and writes a report. **Never commits, never bumps
versions, never calls `/release`.**

Governing spec: [SPEC-028](../../specs/core/SPEC-028-fix-ticket-workflow.md).

## Replacement

```
/debug ticket <ticket-id> "<bug/premise>"
/debug ticket CDV-42 "off-by-one in pagination offset" --fix "clamp offset to >= 0"
/debug ticket AUDIT-P0.8 "migrate-v3 corrupts CURRENT_VERSION" --agent ic5 --lenses correctness,completeness
/debug ticket CDV-42 "X is wrong" --worktree /path/to/.worktrees/CDV-42
```

| Flag / argument | Required | Default | Description |
|-----------------|----------|---------|-------------|
| `<ticket-id>` | Yes | — | Ticket id used for worktree slug + report name |
| `"<bug/premise>"` | Yes | — | Documented bug description |
| `--fix "<instructions>"` | No | (empty / premise-only) | Explicit fix instructions for implementer |
| `--agent ic4\|ic5` | No | `ic4` | Implementer agent |
| `--lenses a,b` | No | `correctness,completeness` | Comma-separated adversarial lenses |
| `--worktree <path>` | No | `worktree-lib.sh ensure <ticket-id>` | Existing worktree path |

Full reference: [`/debug`](./debug.md) (`ticket` mode).

## See also

- [`/debug`](./debug.md) — primary surface (`patch` · `arch` · `ticket` · full)
- [`/wrap-ticket`](./wrap-ticket.md) — close out after the fix PR is merged
