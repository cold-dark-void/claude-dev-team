# /doctor

Diagnose dev-team plugin + project install/config health in one pass and print
a `PASS`/`WARN`/`FAIL` table with a concrete fix-it line per finding. Read-only
by default; `--fix` applies allowlisted repairs only. This is the plugin
surface (`dev-team:doctor`) — it does not shadow or replace the Claude Code
harness built-in `/doctor`.

## Usage

```
/doctor
/doctor --json
/doctor --only <id|group>
/doctor --fix
/doctor --gate=<orchestration|team>
```

| Flag | Effect |
|------|--------|
| `--json` | Machine-readable report |
| `--only <id\|group>` | Run a subset of checks |
| `--fix` | Apply allowlisted repairs only (see below) |
| `--force` | With `--fix`: also repair a fresh-enough lock the default would keep |
| `--gate=<orchestration\|team>` | Apply the named gate's blocking set instead of the default |
| `-h`, `--help` | Usage |

## Check groups

`version` · `plugin` · `memory` · `hooks` · `settings` · `deps` · `worktree` ·
`transcript` · `config` · `handoff` · `tests` · `lint` — pass a group to
`--only` (e.g. `--only memory`) or a single check id (e.g.
`--only transcript.mirror_lag`).

## `--fix` allowlist (only these ever write)

1. Clear a stale `distilling_lock` (`distill-<epoch>-<pid>` older than 1800s).
2. Remove STALE-per-SPEC-016 `.wt-lock` files (never FRESH ones; never worktree
   dirs).
3. Remove handoff `*.tmp` files.

## Notes

- `--fix` never creates memory, hooks, or settings — it is repair-only.
- Exit codes: `0` all PASS/WARN, `1` at least one FAIL (read-only detail),
  `2` gate-blocking FAIL (consumed by the `/setup` doctor hard-gate).
- Flags may combine: `/doctor --json --only memory`.

## See also

- [`/audit`](audit.md) — instruction-stack hygiene (different scope)
- [`/setup`](setup.md) — bootstrap the things `/doctor` inspects
