---
name: domain-glossary
description: |
    Living project ubiquitous language (CONTEXT.md). Load before naming work;
    update when terms crystallize during brainstorm/kickoff. Agent-internal —
    not a user slash command.
---

# Domain Glossary

Maintains a **committed, in-repo** domain glossary so agents and humans share
one language across sessions. Complements agent memory (SQLite / cortex) —
memory is episodic; this file is the project's **ubiquitous language**.

Inspired by community `CONTEXT.md` / grill-with-docs patterns; MIT-owned copy
here — no external dependency.

## Paths (first hit wins)

Resolve project root:

```bash
_gc=$(git rev-parse --git-common-dir 2>/dev/null) \
  && MROOT=$(cd "$(dirname "$_gc")" && pwd) \
  || MROOT=$(pwd)
```

| Priority | Path |
|----------|------|
| 1 | `$MROOT/CONTEXT.md` |
| 2 | `$MROOT/docs/domain/CONTEXT.md` |

If neither exists, the glossary is **absent** (not an error). Do not invent
terms until a user-confirmed decision produces one.

## File format

When creating or updating, use this structure (extend, never invent a second
format for the same project):

```markdown
# Domain Glossary

Project ubiquitous language. Prefer these terms in code, specs, tickets, and
agent output. Do not reintroduce avoided aliases.

## Terms

| Term | Definition | Avoid (aliases) |
|------|------------|-----------------|
| ExampleTerm | One-line definition in project words | BadName, OtherName |

## Decisions

One-way choices that affect naming or design (optional; full ADRs may live
under `docs/adr/` if the project uses them).

- YYYY-MM-DD: <decision> — <why>
```

Rules:
- **One row per term** — short definition; list aliases the team must not use
- **Update in place** — merge new terms; do not wipe existing rows without user OK
- **User-confirmed only** — never write speculative or agent-only jargon
- **Commit with the feature** when the glossary changed during a ticket/kickoff —
  never leave a durable uncommitted `CONTEXT.md` dirt on the main checkout
  (`$MROOT`) while the ticket's specs/code live on a worktree branch

## Load protocol (session / skill start)

Callers (`/brainstorm`, `/kickoff`, project-init, agents doing design work):

```bash
_gc=$(git rev-parse --git-common-dir 2>/dev/null) \
  && MROOT=$(cd "$(dirname "$_gc")" && pwd) \
  || MROOT=$(pwd)
if [ -f "$MROOT/CONTEXT.md" ]; then
  cat "$MROOT/CONTEXT.md"
elif [ -f "$MROOT/docs/domain/CONTEXT.md" ]; then
  cat "$MROOT/docs/domain/CONTEXT.md"
else
  echo "No domain glossary (CONTEXT.md) yet."
fi
```

When the file is present:
1. Prefer glossary **Term** names in specs, plans, task subjects, and code
2. If the user (or ticket) uses an **Avoid** alias, map it to the canonical Term
   and note the mapping once in the plan/spec
3. Flag conflicts: user insists on a name that contradicts the glossary → ask
   before overriding

## Update protocol (write-back)

After terms crystallize (brainstorm synthesis confirmed, kickoff ACs/design locked):

1. List candidate terms: name, definition, aliases to avoid
2. Confirm with the user if any term is new or renames an existing one
3. Choose **write target** by lifecycle (first match wins):
   | Situation | Write path | Commit |
   |-----------|------------|--------|
   | Ticket worktree exists (`$WT_PATH` from kickoff/orchestrate) | `$WT_PATH/CONTEXT.md` (or `docs/domain/` under WT if that layout is already used) | **Required** on `feat/<TICKET-ID>` with the spec/plan — same branch lifecycle (CDT-105: never direct-to-master) |
   | Session already inside a `.worktrees/<slug>` checkout | that tree's `CONTEXT.md` | **Required** on the current feature branch |
   | Pre-ticket brainstorm only (no worktree yet) | **Do not** leave uncommitted dirt on `$MROOT/CONTEXT.md` — record a `## Domain glossary delta` in the brainstorm plan only; kickoff/orchestrate promote + commit |
4. Merge rows into `## Terms` (and optional `## Decisions` lines) at the chosen path
5. Print which terms were added/updated and where they will ship

**MUST NOT:**
- Write glossary terms only to `$MROOT` then ship the feature without them
- Exclude `CONTEXT.md` from squash/PR land "because master is dirty"
- Treat master-tree dirt as a substitute for a feature-branch commit

Do **not** auto-commit from this skill alone — callers (`/kickoff` Step 7b,
`/orchestrate` Step 3b/6b, `/brainstorm` Step 4b) own when to `git add` /
`git commit`. When a ticket worktree exists, those callers **MUST** commit
`CONTEXT.md` on the feature branch with related work.

## What this is not

- Not agent memory (no SQLite, no tiers)
- Not a full ADR system (optional one-liners only)
- Not Graphify / structural graphs
- Not required for every project — empty/absent is fine until the first real term
