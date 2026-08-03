---
name: epic
description: |
    Umbrella decomposition + sequenced child orchestration (SPEC-025). PM+TL
    decompose an epic into child tickets with a cross-ticket DAG; walk ready
    children via /kickoff or /orchestrate. Composition only — PM mandatory per
    child; Linear optional (Project create/link best-effort — SPEC-025 M12 /
    skill A.6). Usage: /epic <EPIC-ID> ["text"] | status | complete | block
    | unblock | --redecompose
argument-hint: "<EPIC-ID> [\"text\"] | status | complete | block | unblock | --redecompose"
---

# /epic

Thin entrypoint for the epic skill. Full protocol: `skills/epic/SKILL.md`.
Mechanical CLI: `bash skills/epic/epic-lib.sh <cmd> …`.

Governing spec: `specs/core/SPEC-025-epic-umbrella-decomposition.md`.

## Args

| Args | Action |
|------|--------|
| `<EPIC-ID> "<text>"` | Decompose if no state; else resume execute |
| `<EPIC-ID>` | Resume / status if state exists; else prompt for text |
| `status [<EPIC-ID>]` | Rollup one or all active epics |
| `--redecompose <EPIC-ID> "<text>"` | Confirm → re-decompose non-completed only |
| `complete <EPIC-ID> <CHILD-ID>` | Manual complete (kickoff-mode) |
| `block <EPIC-ID> <CHILD-ID>` | Mark child blocked |
| `unblock <EPIC-ID> <CHILD-ID>` | Mark child pending |

## Routing

1. Resolve plugin paths (`plugin-dir.sh` → `skills/epic/epic-lib.sh`).
2. Dispatch:

```bash
_gc=$(git rev-parse --git-common-dir 2>/dev/null) \
  && MROOT=$(cd "$(dirname "$_gc")" && pwd) \
  || MROOT=$(pwd)
# lint-ok: C3 — marketplace */ for-loop + -f guarded (SPEC-021 Q2 residual, CDT-82 PDH)
PDH=$( { [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -f "$CLAUDE_PLUGIN_ROOT/skills/plugin-dir.sh" ] && printf '%s\n' "$CLAUDE_PLUGIN_ROOT"; } || { [ -f skills/plugin-dir.sh ] && pwd; } || { for _mp in "$HOME"/.claude/plugins/marketplaces/*/; do [ -f "${_mp}skills/plugin-dir.sh" ] && [ -f "${_mp}agents/pm.md" ] && printf '%s\n' "${_mp%/}" && break; done; } || find ~/.claude/plugins/cache -path '*/dev-team/*/skills/plugin-dir.sh' 2>/dev/null | sed 's/-pre\./~pre./' | sort -V | tail -1 | sed 's/~pre\./-pre./' | xargs -r dirname | xargs -r dirname )
EPIC_LIB=$(bash "$PDH/skills/plugin-dir.sh" file skills/epic/epic-lib.sh)

# status
bash "$EPIC_LIB" show "$EPIC_ID"          # or: rollup

# complete / block / unblock
bash "$EPIC_LIB" set-status "$EPIC_ID" "$CHILD_ID" completed   # or blocked | pending

# exists? → resume execute; else decompose
bash "$EPIC_LIB" exists "$EPIC_ID"
```

3. For **decompose**, **execute/resume**, and **--redecompose**, load and follow
   `skills/epic/SKILL.md` end-to-end (PM∥TL, cycle gate, approval, backlog,
   confirm-before-handoff, handoff to `/kickoff` or `/orchestrate`).

4. **Do not** improvise ticket lifecycle here. **Do not** skip PM on any child
   handoff. **Do not** write epic children into `.claude/tasks/`.

## Handoff shape (no PM skip)

```
/<kickoff|orchestrate> <CHILD-ID> "<problem>

Acceptance criteria:
- …

Epic parent: <EPIC-ID>
depends_on: … (already satisfied)
Recommended agent: <ic4|ic5>
Estimate: <S|M|L>

Output mode: terse for agent spawns.
PM kickoff is mandatory — do not skip."
```
