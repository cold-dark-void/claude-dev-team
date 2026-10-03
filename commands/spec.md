---
name: spec
description: Unified spec management entry — audit/validate, create, find, list,
  update, reverse-generate from code, generate tests, and full-system reflect.
  Usage /spec <check|create|find|list|update|generate|tests|reflect> [args...]
argument-hint: "<check|create|find|list|update|generate|tests|reflect> [args...]"
agent: build
---

# /spec — Unified Spec Management

Single entry point for all spec lifecycle operations (SPEC-008). This file is
the dispatcher only.

## Dispatch

Parse the first positional argument as `<sub>`. If absent or unknown, print the
sub list below and stop. Remaining args (including flags) pass through unchanged
to the routed sub-behavior. Read **only the routed file** — do not read the
other sub files.

| Sub | Source / target |
|-----|-----------------|
| `check` | `skills/spec-tooling/modes/check.md` |
| `create` | `skills/spec-tooling/modes/create.md` |
| `find` | `skills/spec-tooling/modes/find.md` |
| `list` | `skills/spec-tooling/modes/list.md` |
| `update` | `skills/spec-tooling/modes/update.md` |
| `generate` | `skills/spec-tooling/SKILL.md` (router) → `modes/generate.md` |
| `tests` | `skills/spec-tooling/SKILL.md` (router) → `modes/tests.md` |
| `reflect` | `skills/spec-tooling/SKILL.md` (router) → `modes/reflect.md` |

```
/spec check [--tests] [--gate[=N]] [SPEC-ID]
/spec create
/spec find <keyword>
/spec list
/spec update [SPEC-ID]
/spec generate [<path>]
/spec tests [SPEC-NNN] [--dry-run]
/spec reflect [--report] [--phase N]
```

Unknown/missing sub → print this table and stop. Do not guess a default sub.

---

## Sub: `generate` — skill-delegate → `skills/spec-tooling`

**Do not implement generate behavior here.** Read and follow
`skills/spec-tooling/SKILL.md` (router) → `modes/generate.md` with
**sub=`generate`** and remaining args passed through unchanged.

| Invocation | Expected behavior |
|------------|-------------------|
| `/spec generate` | Full codebase scan; Tech Lead decides domain grouping; write INFERRED specs under `specs/core/` |
| `/spec generate <path>` | Limit scan to a package or directory |

Args: optional `<path>` only. No flags in the current surface.

Preserve every MUST from SPEC-008 for this mode (project-language
markers, source exclusions, INFERRED status, human-review requirement).

---

## Sub: `tests` — skill-delegate → `skills/spec-tooling`

**Do not implement tests-generation behavior here.** Read and follow
`skills/spec-tooling/SKILL.md` (router) → `modes/tests.md` with
**sub=`tests`** and remaining args passed through unchanged.

| Invocation | Expected behavior |
|------------|-------------------|
| `/spec tests` | Generate tests for all specs |
| `/spec tests SPEC-NNN` | Generate tests for a single spec |
| `/spec tests --dry-run` | Show what would be generated; write nothing |

Args: optional `SPEC-NNN` and/or `--dry-run`. Flag parity with `/spec tests` MUST hold.

Tag forms emitted MUST remain recognizable by `/spec check --tests` Phase 3 (P3-M2 /
SPEC-008 § Spec-test coverage matrix). Do not fork the tag convention.

---

## Sub: `reflect` — skill-delegate → `skills/spec-tooling`

**Do not implement reflect behavior here.** Read and follow
`skills/spec-tooling/SKILL.md` (router) → `modes/reflect.md` with
**sub=`reflect`** and remaining args passed through unchanged.

| Invocation | Expected behavior |
|------------|-------------------|
| `/spec reflect` | Full-system health check: inventory → cross-spec conflicts → skill/command consistency → exhaustive code alignment (ALL specs, not sampled) → coverage gaps → interactive confirmation |
| `/spec reflect --report` | Same phases; skip the Phase 6 interactive loop |
| `/spec reflect --phase N` | Run only phase N |

Args: optional `--report` and/or `--phase N`. Phases and interactive pause-for-decision
behavior MUST match `skills/spec-tooling/modes/reflect.md`. `--report` skips Phase 6.

Goes beyond `/spec check` (sampled Phase 2) — exhaustive over every governed spec.

---

## Flag parity

- Examples that must keep working:
  - `/spec check --tests`
  - `/spec check SPEC-012`
  - `/spec check SPEC-012 --tests --gate=5`
  - `/spec tests --dry-run`
  - `/spec generate path/to/pkg`
