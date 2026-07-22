# /spec

Unified entry point for the full spec lifecycle (SPEC-008). One dispatcher;
eight subs cover audit/validate, create, find, list, update, reverse-generate
from code, test generation, and full-system reflect. Prefer this surface over
the legacy `/check-specs`, `/create-spec`, `/find-spec`, `/list-specs`,
`/update-spec`, `/generate-specs`, `/generate-tests`, and `/reflect-specs`
commands (deprecated — removed at v1.0.0).

## Usage

```
/spec check [--tests] [--gate[=N]] [SPEC-ID]
/spec create
/spec find <keyword>
/spec list
/spec update [SPEC-ID]
/spec generate [<path>]
/spec tests [SPEC-NNN] [--dry-run]
/spec reflect
```

| Sub | Summary |
|-----|---------|
| `check` | Audit all specs (format + code alignment) or validate one by ID |
| `create` | Interactive interview → new DRAFT spec + TDD.md index row |
| `find` | Search specs by keyword (title, MUST, Overview, Test) |
| `list` | Status overview by category/lifecycle; flags orphans |
| `update` | Modify an existing spec with version history + conflict check |
| `generate` | Reverse-engineer INFERRED specs from existing code |
| `tests` | Generate tests from specs — one per MUST requirement |
| `reflect` | Exhaustive full-system health check (interactive) |

Unknown or missing sub prints the table and stops.

## Sub: `check`

Two modes depending on whether a spec ID is supplied.

| Mode | Invocation | What it does |
|------|------------|--------------|
| **Audit** (default) | `/spec check` | Phase 1 format/index + Phase 2 code alignment across specs |
| **Validate** | `/spec check SPEC-012` | Implementation validation for one spec against source |

| Flag | Effect |
|------|--------|
| *(none)* | Phase 1 + Phase 2 only — no Phase 3 section |
| `--tests` | After Phase 2 / validation, append Phase 3 MUST→test coverage matrix (report-only; exit 0 even if MISSING) |
| `--tests --gate[=N]` | Same as `--tests`, then fail closed if total MISSING > N (default N=0). **Not wired into `/release`** |

**Phase 1** — format compliance (9-section SPEC-008 skeleton), content quality,
TDD.md index integrity (orphans, dead links, status drift).

**Phase 2** — code alignment: MATCH / MISSING / DIFFERS / UNDOCUMENTED against
product sources (excludes `specs/`, `.claude/`, lockfiles, generated assets).

**Phase 3** (with `--tests`) — MUST→test matrix: COVERED / MISSING per
requirement. Tags must remain recognizable by the matrix convention (P3-M2).

**Examples:**
```
/spec check                      # Audit: Phase 1 + Phase 2
/spec check SPEC-012             # Validate one spec
/spec check --tests              # Audit + Phase 3 matrix
/spec check SPEC-012 --tests     # Validate one + Phase 3
/spec check --tests --gate       # Fail if any MISSING
/spec check --tests --gate=5     # Fail only if MISSING > 5
```

## Sub: `create`

Interactive interview that walks you through a new behavioral spec:

1. **What** — feature/behavior, problem, MUST requirements, edge cases
2. **Category** — core / performance / safety / compatibility / architecture
3. **Conflict scan** — proposed MUSTs vs all existing specs (BLOCKER / WARNING)
4. **Write** — `specs/<category>/<ID>-<slug>.md` as `DRAFT` with 9-section skeleton
5. **Index** — row in `specs/TDD.md` Spec Index + Version History

MUST requirements must be concrete and testable. Conflict decisions: revise,
also-update-other, or proceed-with-documentation.

## Sub: `find`

```
/spec find <keyword>
```

Case-insensitive search across titles, MUST, Overview, and Test sections of
all governed specs (`specs/**/*.md`, excluding `TDD.md`). Multiple terms are
ANDed. Shows up to 10 results with category, status, and a context snippet;
offers follow-ups (`/spec update`, `/spec create`).

## Sub: `list`

```
/spec list
```

Fast overview: counts by category and lifecycle status (INFERRED / DRAFT /
ACTIVE / APPROVED / DEPRECATED), last 5 Version History entries, and a
**Needs Attention** section (DRAFT, INFERRED, ORPHANS not in TDD.md).

Lifecycle status here is distinct from `/spec check` verify-status
(PASS / FAIL / WARN).

## Sub: `update`

```
/spec update [SPEC-ID]
```

Interview about changes (add / modify / remove), cross-spec conflict check,
then write. Always appends a Version History row. For ADDED/MODIFIED
requirements, prints a code-alignment warning (CODE MATCHES / CONTRADICTS /
NO CODE FOUND) before finishing — informational, does not block. Updates
TDD.md Status and Version History when lifecycle changes.

Breaking changes require explicit confirmation.

## Sub: `generate`

```
/spec generate
/spec generate <path>
```

Reverse-engineers specs from what the code *actually does*. Full codebase
scan by default; optional `<path>` limits to a package/directory. Output is
`Status: INFERRED` under `specs/core/` — a hypothesis, not ground truth.
Review, then promote via `/spec update` / `/spec reflect`.

## Sub: `tests`

```
/spec tests
/spec tests SPEC-NNN
/spec tests --dry-run
```

Generate tests from specs — one test per MUST requirement. Optional
`SPEC-NNN` limits scope; `--dry-run` shows what would be written without
writing. Emitted tags stay compatible with `/spec check --tests` Phase 3.

## Sub: `reflect`

```
/spec reflect
```

Exhaustive full-system health check (interactive pauses for decisions):

1. Inventory all governed specs
2. Cross-spec conflict scan
3. Skill/command consistency
4. Code alignment over **every** spec (not the sampled Phase 2 of `check`)
5. Coverage gaps
6. Confirm recommended actions

Goes beyond `/spec check` — use before releases or when drift is suspected.

## Spec skeleton

New specs use the SPEC-008 9-section form:

```markdown
# <PREFIX>-<NNN>: <Title>

**Status**: DRAFT
**Category**: core
**Created**: <YYYY-MM-DD>

## Overview
## MUST
## Test
## Validation
## Version History
```

Lifecycle: `INFERRED` → `DRAFT` → `ACTIVE` → `APPROVED` → `DEPRECATED`.

## See Also

- [Specs runbook](../runbooks/specs.md) — create/audit/reflect workflow
- [`/kickoff`](./kickoff.md) — writes or updates specs during planning
- [`/orchestrate`](./orchestrate.md) — full lifecycle against plan + specs
- Full contract: [`SPEC-008`](../../specs/core/SPEC-008-spec-management.md)
