---
name: metrics
description: Read-only all-time rollup of local-agent, council, outcomes, and worktree/task counts
---

# /metrics

Display-only observability rollup across plugin metric surfaces. **Never writes**
to any ledger, index, task store, or DB. Aggregation is owned exclusively by
`skills/metrics/rollup.sh` — agents MUST NOT hand-aggregate JSONL/index files.

Sources (read-only):

| Section | Path | Spec |
|---------|------|------|
| `local` | `.claude/local-agent/metrics.jsonl` | SPEC-019 (dual-shape) |
| `council` | `.claude/council/index.json` | SPEC-013 |
| `outcomes` | `.claude/metrics/outcomes.jsonl` | SPEC-026 |
| `worktree` | `.worktrees/*` + `.claude/tasks/*.json` | cheap counts |

Out of scope: retro friction / gate re-score, full CDV-204 token reporting,
hook-based session cost capture, windowing/decay, writes to any store.

## Arguments

- `/metrics` — all sections, human tables
- `/metrics --json` — single JSON object on stdout
- `/metrics --section <all|local|council|outcomes|worktree>` — one section
- Flags may combine: `/metrics --json --section outcomes`

## Step 1: Resolve rollup.sh

Install-aware resolution via `plugin-dir.sh` (script ships in the plugin, not
necessarily the project tree):

```bash
PDH=$( [ -f skills/plugin-dir.sh ] && pwd || find ~/.claude/plugins/cache -path '*/dev-team/*/skills/plugin-dir.sh' 2>/dev/null | sort -V | tail -1 | xargs -r dirname | xargs -r dirname )
ROLLUP_SH=$(bash "$PDH/skills/plugin-dir.sh" file skills/metrics/rollup.sh)

if [ -z "$ROLLUP_SH" ] || [ ! -f "$ROLLUP_SH" ]; then
  echo "error: skills/metrics/rollup.sh not found in the installed plugin cache" >&2
  exit 1
fi
```

## Step 2: Invoke rollup (pass-through flags)

Forward any user-supplied `--json` / `--section` args unchanged. Do not re-parse
or re-aggregate:

```bash
PDH=$( [ -f skills/plugin-dir.sh ] && pwd || find ~/.claude/plugins/cache -path '*/dev-team/*/skills/plugin-dir.sh' 2>/dev/null | sort -V | tail -1 | xargs -r dirname | xargs -r dirname )
ROLLUP_SH=$(bash "$PDH/skills/plugin-dir.sh" file skills/metrics/rollup.sh)
bash "$ROLLUP_SH" "$@"
```

Exit contract (from `rollup.sh`):

| Code | Meaning |
|------|---------|
| 0 | Success or partial (missing sources / no jq → section degrade, still 0) |
| 64 | Usage error (unknown flag / bad section) |

Fail-open per section: a missing ledger or index zeros that section with
`present: false` and does not fail the command.

## Step 3: Present output

Print the script's stdout as-is (human tables or JSON). Do not reformat, and do
not open report bodies under `.claude/council/*.md`.

## Notes

- **Display-only** — MUST NOT call `emit-outcome.sh`, `emit-orch-metric.sh`,
  council index writers, or any task-store mutator.
- **Dual-shape local-agent** — companion rows have `ticket`; run.sh rows have
  `outcome` and lack `ticket`. Never double-count.
- **All-time only** — no window filter.
