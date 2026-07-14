---
name: craft-loop
description: Design a reviewed, file-persisted loop program for the built-in
  /loop and /goal commands — guided crafting dialogue, journal-based state,
  refine-from-journal, and library listing. Usage /craft-loop [goal text |
  list | refine <name>]
---

# Craft Loop

Designs *loop programs* — reviewed markdown files under `.claude/loops/` that
the **built-in** `/loop` and `/goal` commands execute via a pointer prompt.
This command ships no runtime and never starts a loop: it produces the program
file and hands you the invocation line.

Why: a naive prompt fired repeatedly into a session drifts, loses its place
between firings, never terminates, or takes unattended risks. A crafted
program carries a per-iteration procedure, journal-based state, an objectively
checkable stop condition, guardrails, and decision-card escalation.

Governing spec: `specs/core/SPEC-020-craft-loop-prompt-architect.md`.

## Usage

```
/craft-loop <goal text>     # craft a new program (guided dialogue)
/craft-loop                 # craft mode; you will be asked for the goal
/craft-loop list            # table of the project's programs + open decisions
/craft-loop refine <name>   # improve a program from its run journal
```

## Mode routing

Interpret the arguments:

1. Exactly `list` (`/craft-loop list`) → **list mode**
2. Starts with `refine` followed by a name → **refine mode** for that name
   (bare `refine` with no name: ask which program, offering the library list)
3. Anything else (including empty) → **craft mode**; the arguments are the
   goal, or ask for the goal if empty

Then invoke the `craft-loop` skill (namespaced `dev-team:craft-loop` when the
plugin is installed from the marketplace) with the Skill tool and follow its
protocol for the selected mode. The skill's hard rules apply verbatim — most
importantly: never invoke `/loop` or `/goal` yourself, and never write a
program file before the user approves the draft in chat.

**Hard rule (restated):** MUST NOT start `/loop` or `/goal` in any mode. This
command is the architect only; the user fires the built-in runtime.

## Relationship to the built-ins

| | Built-in `/loop` / `/goal` | This command |
|---|---|---|
| Role | Runtime — fires the prompt | Architect — designs the program |
| State | The session | `.claude/loops/` files, editable mid-run |
| Output | Iterations of work | A reviewed program + invocation line |
