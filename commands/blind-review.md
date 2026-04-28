---
name: blind-review
description: |
  Multi-team blind peer review with quorum analysis. Spawns N unconstrained
  reviewer agents + M lens-differentiated reviewer agents in parallel, clusters
  independent findings by semantic similarity, and produces a confidence-tiered
  report. Optionally pipes Tier 1 consensus findings to /council for reverse
  validation. Use when you want adversarial multi-perspective coverage of a
  codebase, directory, or file set.
argument-hint: "[--teams N] [--lenses security,contributor,spec] [--target <path>] [--no-council]"
---

Thin wrapper — parse arguments then hand off to the skill.

## Step 1: Parse arguments

From the user's invocation, extract:

- `--teams N` → `TEAMS=N` (default: `3`)
- `--lenses L1,L2,...` → `LENSES="L1,L2,..."` (default: `"security,contributor,spec"`)
- `--target <path>` → `TARGET="<path>"` (default: `""` = full project)
- `--no-council` → `NO_COUNCIL=true` (default: `false`)

If any argument is unrecognised, print:

```
Usage: /blind-review [--teams N] [--lenses L1,L2,...] [--target <path>] [--no-council]

Available lenses: security, contributor, spec, architecture, logic
Defaults: --teams 3 --lenses security,contributor,spec
```

and stop.

## Step 2: Hand off to the skill

Read and follow `skills/blind-review/SKILL.md` with the resolved values above.
