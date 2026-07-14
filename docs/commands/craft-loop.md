# /craft-loop — Loop-Prompt Architect

Designs reviewed, file-persisted *loop programs* for Claude Code's built-in
`/loop` and `/goal` commands. The command is the architect; the built-ins are
the runtime. Governing spec: `specs/core/SPEC-020-craft-loop-prompt-architect.md`.

## Why

A naive prompt fired repeatedly into a session drifts, loses its place between
firings, never terminates, or takes unattended risks on iteration 7. A crafted
program fixes that with five ingredients: a per-iteration procedure any firing
can execute cold, journal-based state, an objectively checkable stop
condition, default-strict guardrails, and decision-card escalation instead of
guessing.

## Usage

```
/craft-loop <goal text>     # craft a new program (guided dialogue)
/craft-loop                 # same, prompts for the goal
/craft-loop list            # program table + open decision counts
/craft-loop refine <name>   # improve a program from its run journal
```

## The flow

1. **Craft.** You give a rough goal; the architect scans the repo, asks
   targeted questions one at a time (stop condition, scope, risk tolerance,
   cadence, target, name), drafts from the shipped template and examples, and
   presents the program for approval. Nothing is written until you approve.
2. **Run.** You fire the printed pointer prompt, e.g.:
   `/loop Follow the loop program in .claude/loops/backlog-burn.md exactly — one iteration per firing.`
   For `target: goal` programs the skill prints a `/goal Adopt the standing
   objective…` invocation instead. Each firing re-reads the file — so you can
   edit the program mid-run to steer the loop without restarting it.
3. **Answer decisions.** When the loop hits a call only you can make, it
   parks a `- [DECISION]` card in the journal and continues with unblocked
   work. Add an **indented** `Answer:` line beneath a card to resolve it
   (leading whitespace required; a bare `Answer:` at column 0 does not close
   the card). The next firing picks the answer up.
4. **Refine.** After a run, `/craft-loop refine <name>` reads the journal,
   diagnoses failures (drift, stall, guessing, immortal loop, oversized
   ticks), and proposes before/after edits. Program quality compounds across
   runs.

## Files

| Path | What |
|------|------|
| `.claude/loops/<name>.md` | The program — reviewed, editable, reusable |
| `.claude/loops/<name>.journal.md` | Written by the running loop; one entry per iteration |

## Guardrails

Every generated program starts with a strict `# Never` list: no `git push` or
publishing, no branch/tag deletion or history rewrites, no deletion outside
the program's declared scope. Entries are removed only when you explicitly ask
during the crafting dialogue.

This command ships **no custom runtime** and never starts `/loop` or `/goal`
itself — it only designs the program and prints the invocation line.
