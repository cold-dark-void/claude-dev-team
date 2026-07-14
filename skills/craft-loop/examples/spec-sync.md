---
name: spec-sync
target: loop
cadence: dynamic
status: ready
created: 2026-07-03
---

# Objective

Bring every spec listed in `specs/TDD.md` into alignment with the code it
covers, one spec per iteration, fixing documentation-side drift only. Done =
every spec ID in the `specs/TDD.md` index is marked checked in this loop's
journal `State` for the current sweep.

# Every iteration

1. Read `.claude/loops/spec-sync.journal.md`. Recover the previous entry's
   `Next` field and treat any decision card that now has an indented `Answer:`
   line as resolved input. If the journal does not exist, create it with a
   `# Journal — spec-sync` heading, list every spec ID from the `specs/TDD.md`
   index as unchecked in `State`, and treat this as iteration 1.
2. Pick the first unchecked spec ID from the journal `State`.
3. Read that spec and every file its `Covers` line names. Compare each MUST
   requirement to the code; classify MATCH, DIFFERS, or MISSING with file:line
   evidence.
4. For documentation-side drift (code is correct, spec text stale): update the
   spec wording and append a Version History row dated today.
5. For code-side drift (code violates a MUST): do NOT change code — add a
   decision card asking whether to fix the code or relax the spec.
6. Mark the spec checked in `State` with its verdict.
7. Append a journal entry using the schema below. This is always the last step.

# Stop when

Every spec ID from the `specs/TDD.md` index is marked checked in the journal's
current-sweep `State`. When true: announce "loop complete: spec-sync", append
a final journal entry, and end the loop — do not continue iterating.

# Never

- Run `git push` or any command that publishes to a remote
- Delete branches or tags, or rewrite git history
- Modify source code, scripts, or hooks — this loop edits `specs/*.md` only
- Change a MUST requirement's meaning to force a MATCH (wording
  clarifications only; semantic changes are decision cards)

# When blocked

Code-side violations (step 5) are always decision cards, never unilateral
edits. After adding the card, continue with the next unchecked spec. If every
remaining spec is blocked on a card, append a final entry and end the loop
announcing "loop BLOCKED: spec-sync — see journal".

# Journal entry schema

Append to `.claude/loops/spec-sync.journal.md`:

## Iteration <N> — <YYYY-MM-DD>
- Did: <spec checked and verdict>
- State: <checked/unchecked spec IDs and verdicts for the current sweep>
- Next: <spec ID the next firing should check>
- Decisions needed:
  - [DECISION] <the question, with enough context to answer it cold>

A card is open until an **indented** `Answer: <text>` line is added beneath it
(leading whitespace required — a bare `Answer:` at column 0 does not close the
card). Omit the `Decisions needed` list when there are none.
