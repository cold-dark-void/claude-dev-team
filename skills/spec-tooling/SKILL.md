---
name: spec-tooling
description: |
    Spec lifecycle tooling for /spec generate|tests|reflect. Reverse-engineer
    behavioral specs from source (generate), emit unit/integration tests from
    MUST requirements (tests), and run full-system health reflection across all
    specs/skills/code (reflect). Also hosts shared partials (spec-skeleton.md,
    source-exclude.md) and check-format.sh used by the broader /spec surface.
user-invocable: false
---

# Spec Tooling

Backing skill for `/spec generate`, `/spec tests`, and `/spec reflect`
(commands/spec.md routes those three subs here). The three modes live in this file.

Governing contract: `specs/core/SPEC-008-spec-management.md`.

## Shared assets (this directory)

| Asset | Role |
|-------|------|
| `spec-skeleton.md` | Canonical 9-section emitter partial (SPEC-008). Include via `<!-- include: skills/spec-tooling/spec-skeleton.md agent=spec -->`. |
| `source-exclude.md` | Canonical code-alignment exclude set (SPEC-008 § Source Exclusions). Include via `<!-- include: skills/spec-tooling/source-exclude.md agent=spec -->`. |
| `check-format.sh` | Mechanized Phase-1 format check (9 required sections). Exit 0 = OK. |
| `fixtures/` | check-format fixtures (pre/post-fix). |

Do NOT hand-edit include regions; refresh from the repo root:
```bash
_gc=$(git rev-parse --git-common-dir 2>/dev/null) \
  && MROOT=$(cd "$(dirname "$_gc")" && pwd) \
  || MROOT=$(pwd)
python3 "$MROOT/skills/agent-memory/sync-includes.py" apply "$MROOT/skills/spec-tooling/SKILL.md"
```

## Dispatch

| Invocation | Mode |
|------------|------|
| `/spec generate [path]` | **generate** — code → INFERRED specs |
| `/spec tests [SPEC-NNN] [--dry-run]` | **tests** — specs → tagged test files |
| `/spec reflect [--report] [--phase N]` | **reflect** — full-system health audit |

Unknown sub → refuse; list the three modes above.

Every fenced bash block re-resolves `$MROOT` (skill-lint C1 — fresh shell each fence):

```bash
_gc=$(git rev-parse --git-common-dir 2>/dev/null) \
  && MROOT=$(cd "$(dirname "$_gc")" && pwd) \
  || MROOT=$(pwd)
```

All paths below are relative to `$MROOT` unless noted.

---

## Load protocol

Mode bodies live in `modes/` — this file is the router. Read **only the
current mode**; do not read every mode file up front.

1. Re-resolve `$MROOT` per fence (fresh shell — skill-lint C1).
2. Resolve and read the mode file for the sub you are running:
   `STEP=$(bash "$PDH/skills/plugin-dir.sh" file skills/spec-tooling/modes/<mode>)`.

| Mode | File | What |
|------|------|------|
| generate | `modes/generate.md` | G0–G7: code → INFERRED specs (G3 TL grouping, G5 emitter) |
| tests | `modes/tests.md` | T0–T7: specs → tagged test files |
| reflect | `modes/reflect.md` | Phase 1–6 full-system health audit |

Shared partials (`spec-skeleton.md`, `source-exclude.md`) and `check-format.sh`
stay in this directory (table above).
