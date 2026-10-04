# /refactor

Design-first code restructuring that preserves observable behavior. Before any
file is touched, the design problem is written down; when test coverage is thin,
characterization tests are written and confirmed passing on the original code;
and after the change, the full suite must pass with zero observable behavior
change. Use `/refactor` to improve internal structure (extract, rename,
decouple, deduplicate) — use [`/debug`](debug.md) to fix incorrect behavior.

## Usage

```
/refactor <description>
/refactor inline [--worktree <path>] <description>
/refactor
```

| Form | Description |
|------|-------------|
| `/refactor <description>` | Default mode. Full sequence: design problem statement (hard gate) → approach decision → **Escalation gate** → coverage check (gate) → implement → validate → self-calibration checklist. |
| `/refactor inline [--worktree <path>] <description>` | Inline mode. For handoff from [`/debug`](debug.md) (scope=refactor-first) — currently the only inline caller. Skips the design-problem and approach-decision steps; **keeps the Escalation gate**, coverage check, and validation. `--worktree <path>` lands the refactor on `/debug`'s existing branch (inert in default mode). |
| `/refactor` | No description. Prompts: "What is the area or change to refactor?" then proceeds in default mode. |

**Parser rule:** if the first token is exactly `inline` (case-sensitive), it
selects inline mode and the remainder is the description; a `--worktree <path>`
pair is stripped first in inline mode. A description that legitimately starts
with "inline" is ambiguous — rephrase it.

## Escalation gate (mandatory, every invocation)

After the approach is settled (default) or stated (inline), the Escalation gate
runs — there is no size threshold and no flag that bypasses it:

1. **Ticket-weight routing test** — the approach is tested against the
   canonical `WHY INLINE REJECTED` reasons (the same set the escalation
   handoff emits).
2. **Workstream split check** — if the approach decomposes into 2+
   independently shippable ideas, the run reroutes to [`/epic`](epic.md) child
   tickets instead of a single ticket.
3. **Edit go-ahead [ALWAYS ASK]** — bounded routes get an explicit go-ahead
   before any edit.
4. **Worktree (bounded routes only)** — bounded routes create/reuse the
   SPEC-016 worktree (`.worktrees/<slug>`) via `worktree-lib.sh ensure`;
   escalating routes never create one.
5. **Gate outcome** — an outcome block is printed before any file is edited,
   recording route, reason, and worktree. On an escalating route, the run
   emits the 4-field escalation handoff and chains to `/kickoff`, `/spec
   update`, or `/epic` — it never edits product code.

## Worktree isolation

All file modification happens inside `$MROOT/.worktrees/<slug>` — there is no
current-branch direct-edit path, in both modes, with no exception for trivial
or single-line changes. The tree is created only on a bounded route, resolved
through `plugin-dir.sh` (SPEC-016 caller integration; SPEC-031 universal
worktree isolation).

## Coverage check and validation

- Coverage gate: if tests near the affected path are thin, characterization
  tests are written and confirmed passing on the **original** code first.
- After the change, the full suite must pass; if any test needed its expected
  output updated, the workflow stops — a behavioral diff means this is a bug
  or feature, not a refactor, and it routes to [`/debug`](debug.md) (bug) or
  `/kickoff` (feature) via the escalation handoff.

## Self-calibration checklist

Emitted verbatim before any completion language:

```
Self-calibration checklist:
  [ ] Design problem written before any file was edited (default mode)
  [ ] Escalation gate outcome block appeared before any file was edited (§ 2.2a.5 / § 3.1a)
  [ ] Worktree isolation was used for every edit — no edit made on the current/session branch (§ 2.2a.4, § 2.4 Worktree wiring)
  [ ] Escalation gate ran on this invocation — not skipped, regardless of scope (§ 2.2a)
  [ ] Characterization tests written and passing on original code (if coverage was thin)
  [ ] All tests pass after refactor
  [ ] No feature or bug-fix changes mixed into this refactor
```

In inline mode the first item is marked `[N/A — inline mode]`. If any item is
✗, no completion language is output — resolve the gap or escalate.

## See also

- [`/debug`](debug.md) — fix incorrect behavior; hands off to `/refactor inline` when the fix is purely structural
- [`/epic`](epic.md) — receives workstream-split escalations
- [`/orchestrate`](orchestrate.md) — may dispatch a refactor as an isolated step
- `skills/refactor/SKILL.md` + `specs/core/SPEC-031-escalation-gate.md`, `specs/core/SPEC-015-refactor-workflow.md` — the contract
