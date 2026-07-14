---
name: backlog-burn
target: loop
cadence: dynamic
status: ready
created: 2026-07-03
---

# Objective

Work through the project backlog (`.claude/backlog.md` index) one item per
iteration until no `[PENDING]` items remain. Done = the Pending section of
`.claude/backlog.md` lists zero `[PENDING]` items.

# Every iteration

1. Read `.claude/loops/backlog-burn.journal.md`. Recover the previous entry's
   `Next` field and treat any decision card that now has an indented `Answer:`
   line as resolved input. If the journal does not exist, create it with a
   `# Journal — backlog-burn` heading; this is iteration 1.
2. Read `.claude/backlog.md` and pick the topmost `[PENDING]` item not marked
   blocked in the journal.
3. Re-verify the item's premise against the current code: read the item's
   backlog file and the files it names. If the premise no longer holds, mark
   the item `[EVAPORATED]` in the index with a one-line reason, record the
   evidence in the journal, and skip to step 7.
4. Implement the item within its stated scope, including any tests or checks
   the item calls for. Touch only what this one item requires.
5. Run the project's checks (test suite if one exists, otherwise the item's
   own acceptance checks) and record the result.
6. Mark the item `[DONE]` in `.claude/backlog.md` only when its checks pass;
   commit the change locally with a message naming the item.
7. Append a journal entry using the schema below. This is always the last step.

# Stop when

`.claude/backlog.md` contains no lines with `[PENDING]`. When true: announce
"loop complete: backlog-burn", append a final journal entry, and end the loop
— do not continue iterating.

# Never

- Run `git push` or any command that publishes to a remote
- Delete branches or tags, or rewrite git history
- Delete files outside the scope the current backlog item declares
- Start a second backlog item in the same iteration

# When blocked

If an item needs a call only the user can make (product direction, destructive
migration, external credentials): append a decision card under
`Decisions needed`, note the item as blocked in `State`, and pick the next
`[PENDING]` item. If every remaining item is blocked, append a final entry and
end the loop announcing "loop BLOCKED: backlog-burn — see journal".

# Journal entry schema

Append to `.claude/loops/backlog-burn.journal.md`:

## Iteration <N> — <YYYY-MM-DD>
- Did: <item worked and outcome>
- State: <counts: pending / done / evaporated / blocked>
- Next: <item the next firing should pick>
- Decisions needed:
  - [DECISION] <the question, with enough context to answer it cold>

A card is open until an **indented** `Answer: <text>` line is added beneath it
(leading whitespace required — a bare `Answer:` at column 0 does not close the
card). Omit the `Decisions needed` list when there are none.
