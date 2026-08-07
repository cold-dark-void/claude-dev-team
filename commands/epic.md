---
name: epic
description: |
    Umbrella decomposition + sequenced child orchestration (SPEC-025). PM+TL
    decompose an epic into child tickets with a cross-ticket DAG; walk ready
    children via /kickoff or /orchestrate. Composition only — PM mandatory per
    child; Linear optional (Project create/link best-effort — SPEC-025 M12 /
    skill A.6). Multi-child Mode B applies between-child context discipline
    (M13) by default. Usage: /epic <EPIC-ID> ["text"] | status | complete |
    block | unblock | --redecompose | [--no-context-discipline] |
    [--worktree] [--release <bump>]
argument-hint: "<EPIC-ID> [\"text\"] [--worktree] [--release <bump>] [--autopilot[=<bump>]] [--no-context-discipline] | status | complete | block | unblock | --redecompose"
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
| `[--worktree]` | (decompose/execute/resume/`--redecompose` only) Epic integration-worktree mode (SPEC-025 M14 / CDT-141). Bare flag only — value forms hard-fail (exit 64). Persists `worktree_enabled=true` on init; C2 ensures `epic-<ID>` tree. Resume: omit flags → honor store + same tree (C6); flags that conflict with state → exit 64. Illegal on `status` \| `complete` \| `block` \| `unblock`. |
| `[--release <bump>]` | (with `--worktree` only) End-of-epic release bump intent; `<bump>` ∈ {patch,minor,major}. Space form canonical; `--release=<bump>` accepted alias. Alone / bare / `each`\|`end` / without `--worktree` → exit 64, zero side effects. Persists `release_bump` on init. Resume omit honors store (no silent clear); mismatch → 64 (C6). After last child completed: Mode B.7 seal once (squash → one `/release <bump>` → `sealed=true`; C5). Without this flag: no epic seal path. Orthogonal to `--autopilot`. |
| `[--autopilot[=<bump>]]` | (with decompose/resume) self-answer A.5/B.3 scope gates (SPEC-033 / CDT-111-C4). Flag beats `AUTOPILOT=1` env; `<bump>` ∈ {patch,minor,major} borrowed from `/release`, unused by `/epic` (never ships). B.5 completion is never self-answered (N8). Independent of `--worktree`/`--release`. |
| `[--no-context-discipline]` | Debug opt-out of Mode B between-child context discipline (SPEC-025 M13). Also `EPIC_NO_CONTEXT_DISCIPLINE=1`. Default **on** for multi-child (≥2) Mode B; single-child epics exempt. Protocol: `skills/epic/SKILL.md` Mode B M13 — do not improvise here. |

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
   handoff. **Do not** write epic children into `.claude/tasks/`. **M11/M14:**
   composition only — carve-out is ensure/route one `epic-<ID>` integration
   worktree + seal composition; no per-child WT create, no `/release` reimpl.

### Hard-fail (M14)

Illegal flag combos exit **64** with zero side effects (see SPEC-025 M14
illegal list / `skills/epic/parse-flags.sh`). Rejected public names: `--bump`,
`--land`, `--seal`, `--worktree` mode enums, `--release each|end`.

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
