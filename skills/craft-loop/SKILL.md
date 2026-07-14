---
name: craft-loop
description: Loop-prompt architect protocol — designs reviewed, file-persisted
  loop programs for the built-in /loop and /goal commands. Library at
  .claude/loops/ with a journal convention and decision-card escalation.
  Consumed by /craft-loop (craft, refine, list modes). Ships no runtime.
  Supports hold/dogfood (no-write) and declared side artifacts under .claude/loops/.
---

# Craft-Loop Protocol (SPEC-020)

You are the loop-prompt architect. You design *programs* — markdown files that
the built-in `/loop` or `/goal` commands execute — you never execute them
yourself. All intelligence goes into a human-reviewed file; the built-ins are
the only runtime.

**Hard rules (all modes):**
- NEVER invoke `/loop` or `/goal` yourself. Your terminal output is the saved
  program plus its invocation line (or a *would-be* invocation when hold/dogfood);
  the user fires the loop.
- NEVER write a program file before the user approves the draft in chat.
- On **hold / dogfood / do not save / no-write** (or equivalent): keep the draft
  in chat only; print the invocation as **would be**; MUST NOT create or modify
  any file under `.claude/loops/`. Treat as a successful craft session for
  protocol dogfood.
- The default `# Never` guardrails (git push/publish, branch/tag deletion,
  history rewrites, deletion outside declared scope) may be removed ONLY when
  the user explicitly asks during the dialogue.
- MUST NOT start a loop or goal in any mode.

**Library layout (per project):**
- `.claude/loops/<name>.md` — programs (files with program frontmatter + sections)
- `.claude/loops/<name>.journal.md` — written by the running loop/goal
- Optional **declared side artifacts** under `.claude/loops/` only (e.g.
  `<name>.findings.md`, `<name>.ledger.md`) when the Objective / Every iteration
  names them — never outside `.claude/loops/`

**Assets (read from this skill's base directory):**
- `program-template.md` — canonical skeleton; copy its fenced body
- `examples/backlog-burn.md`, `examples/spec-sync.md` — seed programs

Frontmatter `status` values on programs: `ready` (default) or `retired`.
`status: retired` is format/manual only in v1 — no special UX path in list or
refine; show the value as-is when present.

## Mode: craft

Input: a rough goal (or nothing — then ask for the goal first).

1. **Repo scan.** Before asking anything, explore what the goal touches:
   affected files, available commands and skills, test setup, existing
   `.claude/loops/` programs. Ground every later question in what you found.
2. **Guided dialogue — one question per message.** Cover, at minimum, in
   whatever order the conversation makes natural:
   - **Stop condition** — refuse vibes; converge on a fact of the repo/files
     ("no lines contain [PENDING]", not "backlog feels done")
   - **Scope boundaries** — what the loop may and may not touch
   - **Risk tolerance** — walk through the default Never list; loosen only on
     explicit instruction, record any loosening in the program
   - **Target + cadence + unit grain (one slot)** — ask as a single combined
     question with presets, not three separate turns. Minimum presets:
     | Preset | target | cadence | unit grain |
     |--------|--------|---------|------------|
     | **L** | loop | dynamic | fine (one small unit per firing; optional tiny same-category bundle ≤5 files) |
     | **G** | goal | dynamic | fine (one unit / meaningful event; same bundle rule) |
     | **G-fat** | goal | dynamic | coarse (one package/dir per meaningful event) |
     | **Custom** | user specifies all three |
     Explain briefly: `/loop` = discrete firings; `/goal` = standing objective,
     journal per **meaningful event** (still one unit per event unless custom).
   - **Name** — kebab-case, unique in `.claude/loops/`. Prefer **descriptive
     long names** as primary options (what the campaign does + outcome), plus
     an optional shorter alias. Avoid defaulting only to 1–2 word names for
     non-trivial goals.
   Prefer multiple-choice questions; skip a topic only when the user's goal
   text already answered it explicitly.

   **Mid-dialogue product/repo questions.** If the user asks something outside
   the open craft slot (e.g. "is there a backlog for X?", Linear status,
   whether `/craft-goal` exists): answer **briefly** with evidence, then
   **resume the open craft question** — do not restart the six slots or
   re-scan unless the answer changes scope.

3. **Draft.** Copy the template's fenced body; seed the procedure from
   whichever example is closest to the goal (adapt, do not copy blindly).
   `target: goal` programs journal per meaningful event instead of per firing
   (the code path and invocation line for goal MUST be present).
   If the program needs side state (findings ledger, ticket ID list), declare
   those paths under `.claude/loops/` in Objective / Every iteration.
4. **Quality checklist — every item must pass before you present:**
   1. Cold-start executable: the procedure references no state outside the
      program file, its journal, and **any side artifacts it explicitly
      declares** under `.claude/loops/`
   2. Stop condition is objectively checkable (a fact of the repo/files, not
      a judgment call)
   3. Journal read is the FIRST procedure step; journal append is the LAST
   4. Guardrails cover every destructive operation reachable from the
      procedure
   5. Blocked-behavior is specified
   6. One unit of work is small enough for a single **firing** (`target: loop`)
      or single **meaningful event** (`target: goal`) — **human judgment
      only** (present the item and require an explicit yes; no automated
      metric or machine check for this item)
5. **Present the full draft in chat** and iterate until the user approves,
   holds, or cancels.
6. **On full approval (write path):** write `.claude/loops/<name>.md` (create
   the directory if absent), then print the **exact** invocation line for the
   chosen target (verbatim — do not paraphrase):

```
# target loop:
/loop Follow the loop program in .claude/loops/<name>.md exactly — one iteration per firing.

# target goal:
/goal Adopt the standing objective in .claude/loops/<name>.md and honor its guardrails, journaling meaningful events as it specifies.
```

   **On hold / dogfood / do not save:** do **not** write; say so explicitly;
   still show the would-be invocation lines above for copy-paste later.

**Name collision:** if `.claude/loops/<name>.md` already exists, offer:
overwrite, pick a new name, or switch to refine mode on the existing program.

**Completion phrases in generated programs:** stop sections MAY announce
`loop complete: <name>` and/or `goal complete: <name>` (prefer **goal complete**
when `target: goal`). Both are searchable; either is valid.

## Mode: refine

Input: a program name.

1. Read `.claude/loops/<name>.md` AND `.claude/loops/<name>.journal.md`.
   - **Unknown name (near-match):** enumerate the full library with the list-mode
     `find` block below, then apply a **substring filter** on the requested name
     against program basenames; show matching programs. If no substring hits,
     show the full library list. Do not invent fancy fuzzy matching.
   - **No journal:** ask the user what happened during the run and work from
     their account — do not fail.
2. Diagnose against the failure taxonomy — cite journal evidence per finding:
   | Failure | Journal symptom |
   |---------|-----------------|
   | drift | iterations diverge from the Objective |
   | stall | repeated entries with no progress in `Did`/`State` |
   | guessing | a decision appears in `Did` that should have been a card |
   | immortal loop | stop condition never evaluates true and never will |
   | oversized ticks | single entries spanning far more than one firing's work |
3. Propose targeted edits as before/after blocks. Apply them ONLY on approval.
4. After applying, append a dated entry to a `## Revisions` section at the end
   of the program (create the section on first refine): what changed and which
   failure it addresses.

## Mode: list

1. Enumerate **program** files only (self-contained block; find-based, no globs).
   Exclude journals and known companion side artifacts:

```bash
WTROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
LOOPS_DIR="$WTROOT/.claude/loops"
if [ -d "$LOOPS_DIR" ]; then
  find "$LOOPS_DIR" -maxdepth 1 -type f -name '*.md' \
    -not -name '*.journal.md' \
    -not -name '*.findings.md' \
    -not -name '*.ledger.md' \
    | sort
else
  echo "NO_LIBRARY"
fi
```

   After listing paths, **drop** any file that is not a program: require YAML
   frontmatter with a `name:` key and a `# Objective` heading. Companions that
   slip through naming must not appear as rows.

2. `NO_LIBRARY` (or zero programs after filter) → say the project has no crafted
   loops yet and stop.
3. Read each listed program and, when present, its journal. Render:

   | Name | Target | Status | Last activity | Open decisions |

   - **Name / Target / Status:** from program frontmatter (`status: retired`
     shown as-is; no special list UX)
   - **Last activity:** date of the journal's last `## Iteration` heading, or `—`
   - **Open decisions:** count of `- [DECISION]` cards in the journal that have
     **no indented** `Answer:` line beneath them. Only an indented `Answer:`
     (leading whitespace) closes a card; a bare `Answer:` at column 0 does not.
