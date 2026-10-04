---
name: journal-hygiene
target: goal
cadence: dynamic
status: ready
created: 2026-10-03
---

# Objective

Keep every loop journal in the shared library (`.claude/loops/*.journal.md`)
within its hygiene bound: no journal over 200 lines, no unresolved decision
card older than two weeks, and every journal parseable by
`skills/craft-loop/journal-stats.sh`. This is a standing objective
(`target: goal`): it journals per **meaningful event** — a journal crossed the
line bound, a card was resolved or aged out, or a full pass found nothing to
do — not per firing.

# Every iteration

1. Read `.claude/loops/journal-hygiene.journal.md`. Recover the previous
   entry's `Next` field and treat any decision card that now has an indented
   `Answer:` line as resolved input. If the journal does not exist, create it
   with a `# Journal — journal-hygiene` heading; this is iteration 1.
2. Enumerate candidate journals (self-contained block):

```bash
_gc=$(git rev-parse --git-common-dir 2>/dev/null) \
  && MROOT=$(cd "$(dirname "$_gc")" && pwd) \
  || MROOT=$(pwd)
LOOPS_DIR="$MROOT/.claude/loops"
if [ -d "$LOOPS_DIR" ]; then
  find "$LOOPS_DIR" -maxdepth 1 -type f -name '*.journal.md' | sort
else
  echo "NO_LIBRARY"
fi
```

3. Run `skills/craft-loop/journal-stats.sh` on each candidate journal. For any
   journal over 200 lines: compact it — merge every `## Iteration` entry
   older than the last five into a `## Summary` section at the top (one
   bullet per entry: `Did` + `Next`), preserving all decision cards and their
   indented `Answer:` lines verbatim. Never delete an open decision card.
4. For any open decision card older than two weeks (compare its `## Iteration`
   date), surface it: append a decision card for it to THIS journal's
   `Decisions needed` so the user resolves it in one place. Do not answer
   cards yourself.
5. Append the journal entry using the schema below — this is always the last
   step. A meaningful event is anything logged in `Did` this iteration: a
   compaction performed, an aged card surfaced, or a full pass with nothing
   to do.

# Stop when

A `target: goal` program has no hard stop: it ends when the user retires it
(`/craft-loop retire journal-hygiene`) or edits this file. The objective is
satisfied — announce "goal complete: journal-hygiene (standing)" — on any
iteration where a full pass found no journal over 200 lines and no card older
than two weeks, then continue standing by for the next meaningful event.

# Never

- Run `git push` or any command that publishes to a remote
- Delete branches or tags, or rewrite git history
- Delete files outside the scope the Objective declares (only
  `.claude/loops/*.journal.md` rewrites are allowed, compaction only)
- Answer a decision card yourself — cards are resolved by the user or a
  session relaying the user's decision
- Compact a journal in a way that drops an open decision card or its
  indented `Answer:` line

# When blocked

If a journal cannot be parsed by `journal-stats.sh` or a compaction would
have to drop content, append a decision card under `Decisions needed`
describing the file and the problem, then continue with the next journal. If
everything remaining is blocked, append a final entry and end announcing
"goal BLOCKED: journal-hygiene — see journal".

# Journal entry schema

Append to `.claude/loops/journal-hygiene.journal.md`:

## Iteration <N> — <YYYY-MM-DD>
- Did: <meaningful event — compaction, surfaced card, or clean pass>
- State: <journals over bound: n; open cards older than 2 weeks: n>
- Next: <journal to revisit, or "stand by">
- Decisions needed:
  - [DECISION] <the question, with enough context to answer it cold>

A card is open until an **indented** `Answer: <text>` line is added beneath it
(leading whitespace required — a bare `Answer:` at column 0 does not close the
card). Omit the `Decisions needed` list when there are none.
