# Runbook: Working with Specs

Specs are behavioral contracts that drive the entire dev-team workflow. They define what the code
MUST do, what it SHOULD do, and what it MUST NOT do — and every other runbook depends on them.

This runbook covers: creating specs, maintaining them, and keeping them aligned with code.

For prerequisites and setup, see [Setup Guide](../setup.md).

---

## Why Specs Matter

Specs are the source of truth for the agent team:
- `/kickoff` and `/orchestrate` write or update specs before any code
- QA validates against spec MUST requirements, not ticket text
- Tech Lead reviews against specs, not opinions
- `/spec reflect` catches drift between code and specs

No spec = agents guessing. Bad spec = agents building the wrong thing confidently.

---

## Quick Reference

| Task | Command | When |
|------|---------|------|
| Bootstrap specs for a legacy project | `/spec generate` | Once, at project start |
| Create a spec for a new feature | `/spec create` | Before implementation |
| Find a spec by keyword | `/spec find <keyword>` | Anytime |
| List all specs with status | `/spec list` | Anytime |
| Update an existing spec | `/spec update SPEC-012` | When requirements change |
| Validate one spec against code | `/spec check SPEC-012` | After implementation |
| Audit all specs (format + alignment) | `/spec check` | Periodic health check |
| Full system health check | `/spec reflect` | Before releases or when drift is suspected |
| Generate tests from specs | `/spec tests` | After spec is stable |

---

## Starting from Zero: Legacy Project

If your project has no `specs/` directory:

```
/spec generate
```

This reads your entire codebase, groups the public surface by domain, and writes
MUST/SHOULD/MUST NOT specs from what the code *actually does*. All output is marked
`Status: INFERRED` — it's a hypothesis, not ground truth.

After it runs:

1. **Review each spec** — correct misattributed MUSTs, resolve open questions
2. **Validate** — `/spec reflect` to verify specs match the code
3. **Generate tests** (optional) — `/spec tests` to make requirements executable
4. **Commit** — `git add specs/ && git commit -m "spec: establish baseline from /spec generate"`

You only do this once per project. After the baseline exists, use `/spec create` and
`/spec update` going forward.

---

## Creating a New Spec

```
/spec create
```

Interactive interview that walks you through:

1. **What** — feature/behavior being specified, problem it solves
2. **Requirements** — MUST behaviors, edge cases
3. **Category** — core, performance, safety, compatibility, or architecture
4. **Conflict scan** — checks proposed MUSTs against all existing specs for contradictions
5. **Write** — generates the spec file in `specs/<category>/SPEC-NNN-<slug>.md`
6. **Index** — updates `specs/TDD.md`

### Spec structure

Every spec follows this format:

```markdown
# SPEC-026: Batch Export Descriptions

**Status**: 🚧 NEW
**Category**: core
**Created**: 2026-03-15

## Overview
Brief description.

## MUST
- MUST read from cache via GetAllForFolder
- MUST export to CSV, JSON, or Markdown
- MUST NOT overwrite without confirmation

## Test
Concrete test steps to verify each MUST.

## Validation
- [ ] Checkbox items for manual verification

## Version History
| Date | Change |
|------|--------|
| 2026-03-15 | Initial spec created |
```

Key rules:
- MUST requirements must be **concrete and testable** — not "should be fast" but "MUST respond within 200ms"
- Each MUST becomes an acceptance criterion that QA validates against
- Specs are committed before implementation begins (spec-first discipline)

---

## Updating a Spec

```
/spec update SPEC-012
```

Or without an ID to be prompted:

```
/spec update
```

The update flow:
1. Shows current spec content
2. You describe the change
3. **Cross-spec conflict check** — flags if updated MUSTs contradict other specs
4. **Code alignment warning** — warns if changed requirements no longer match existing code
5. Updates the spec with version history entry
6. Updates `specs/TDD.md` if needed

### When to update vs create new

- **Update** when the same feature's requirements change (new AC, relaxed constraint, bug fix to spec)
- **Create new** when it's a genuinely new feature area with its own domain

---

## Finding and Browsing Specs

**Search by keyword:**
```
/spec find authentication
```
Searches across titles, MUST requirements, overview, and test sections.

**Quick status overview:**
```
/spec list
```
Shows counts by category and status, recent changes, items needing attention.

---

## Validating Specs Against Code

### Single spec

```
/spec check SPEC-012
```

For each MUST requirement, reports:
- **MATCH** — code satisfies it (with file:line citation)
- **MISSING** — no implementation found
- **DIFFERS** — code contradicts the requirement (with file:line)
- **UNDOCUMENTED** — code does things the spec doesn't mention (drift)

### All specs (audit)

```
/spec check
```

Two-phase audit:
1. **Format check** — all specs have required sections, TDD.md index is consistent
2. **Code alignment** — samples the most recently modified specs and checks MUSTs against source

### Full health check

```
/spec reflect
```

The most thorough option — checks **every** spec (not sampled), detects cross-spec conflicts,
audits skill/command consistency, and pauses for your confirmation at each finding.
Use before releases or when you suspect drift.

---

## Generating Tests from Specs

```
/spec tests
```

Or for a specific spec:

```
/spec tests SPEC-012
```

Reads MUST/SHOULD requirements and generates test files with one test case per requirement.
Each test is tagged with its source spec for traceability. Uses the project's existing test
framework.

---

## Spec Lifecycle

Specs flow into the other runbooks:

| Runbook | How specs are used |
|---------|-------------------|
| [Idea to Plan](idea-to-plan.md) | `/kickoff` creates or updates specs as part of planning |
| [Orchestrated](orchestrate.md) | Tech Lead writes spec at Gate 3; QA validates against it |
| [Manual](manual.md) | You ask Tech Lead to write/update specs in Phase 2 |

---

## See Also

- [Project Onboarding](onboarding.md) — day-one setup for a new project
- [Working with Memory](memory.md) — memory tiers, search, distillation
- [Idea to Plan](idea-to-plan.md) — brainstorm → spec → Linear tickets
- [Orchestrated Runbook](orchestrate.md) — spec → PR (autopilot)
- [Manual Runbook](manual.md) — spec → PR (you drive)
- [Setup Guide](../setup.md) — prerequisites and configuration
