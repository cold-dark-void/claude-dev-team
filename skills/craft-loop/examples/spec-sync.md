---
name: spec-sync
target: loop
cadence: dynamic
status: ready
created: 2026-07-03
---

# Objective

Bring every spec listed in `specs/TDD.md` into alignment with the code it
covers, one spec per iteration, fixing documentation-side drift only. The
check-list lives in a declared side artifact, `.claude/loops/spec-sync.ledger.md`
(NOT in the journal `State` — an ID list repeated per entry grows the journal
quadratically, rv-w3-28). Done = every spec ID in the `specs/TDD.md` index is
marked checked with a verdict in the ledger's **current sweep**.

A **current sweep** is one full pass over the `specs/TDD.md` index: it starts
when the ledger is created and when a completed sweep is followed by a changed
index (a spec ID added, renamed, or removed), and it is complete when every ID
in the index has a checked verdict in the ledger's active sweep section.

# Every iteration

1. Read `.claude/loops/spec-sync.journal.md`. Recover the previous entry's
   `Next` field and treat any decision card that now has an indented `Answer:`
   line as resolved input. If the journal does not exist, create it with a
   `# Journal — spec-sync` heading; this is iteration 1.
2. Read `.claude/loops/spec-sync.ledger.md`. If it does not exist, create it
   with a `## Sweep <YYYY-MM-DD>` section listing every spec ID from the
   `specs/TDD.md` index as unchecked — this begins the current sweep. If it
   exists, reconcile its ID list against the `specs/TDD.md` index: an ID in
   the index but not the ledger is appended unchecked; an ID in the ledger but
   no longer in the index is marked `dropped-from-index` (never deleted).
3. Pick the first unchecked spec ID from the ledger's current sweep.
4. Read that spec and every file its `Covers` line names. Compare each MUST
   requirement to the code; classify MATCH, DIFFERS, or MISSING with file:line
   evidence.
5. For documentation-side drift (code is correct, spec text stale): update the
   spec wording and append a Version History row dated today.
6. For code-side drift (code violates a MUST): do NOT change code — add a
   decision card asking whether to fix the code or relax the spec.
7. Append the journal entry — mark the spec checked in the ledger with its
   verdict first, then record the verdict in `Did`. This append is always the
   last step.

# Stop when

Every spec ID from the `specs/TDD.md` index is marked checked with a verdict
in the ledger's current sweep — and the index has not changed since that
sweep completed. When true: announce "loop complete: spec-sync", append a
final journal entry, and end the loop — do not continue iterating.

# Never

- Run `git push` or any command that publishes to a remote
- Delete branches or tags, or rewrite git history
- Delete files outside the scope the Objective declares (only
  `specs/*.md` wording edits and the two declared `.claude/loops/spec-sync.*`
  files are writable)
- Modify source code, scripts, or hooks — this loop edits `specs/*.md` only
- Change a MUST requirement's meaning to force a MATCH (wording
  clarifications only; semantic changes are decision cards)

# When blocked

Code-side violations (step 6) are always decision cards, never unilateral
edits. After adding the card, continue with the next unchecked spec. If every
remaining spec is blocked on a card, append a final entry and end the loop
announcing "loop BLOCKED: spec-sync — see journal".

# Journal entry schema

Append to `.claude/loops/spec-sync.journal.md`:

## Iteration <N> — <YYYY-MM-DD>
- Did: <spec checked and verdict; ledger updated at .claude/loops/spec-sync.ledger.md>
- State: <checked>/<total> specs in the current sweep (full list lives in the ledger); next sweep trigger: <none | index changed>
- Next: <spec ID the next firing should check>
- Decisions needed:
  - [DECISION] <the question, with enough context to answer it cold>

A card is open until an **indented** `Answer: <text>` line is added beneath it
(leading whitespace required — a bare `Answer:` at column 0 does not close the
card). Omit the `Decisions needed` list when there are none.

Journal hygiene (rv-w3-28): when this journal exceeds 200 lines, the next
firing starts by compacting it — merge every `## Iteration` entry older than
the last five into a `## Summary` section at the top (one bullet per entry:
`Did` + `Next`), preserving all decision cards and their indented `Answer:`
lines verbatim. Never delete an open decision card.
