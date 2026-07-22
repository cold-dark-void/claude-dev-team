---
name: fix-ticket
description: >
  Premise→implement→adversarial-refuters for a known bug ticket. Verifies the
  premise, implements in a worktree, spawns qa refuters, writes a report.
  Never commits or releases.
argument-hint: '<ticket-id> "<bug/premise>" [--fix "..."] [--agent ic4|ic5] [--lenses a,b] [--worktree <path>]'
---

# /fix-ticket

Thin wrapper over `skills/fix-ticket/SKILL.md` (SPEC-028).

**premise (ic5) → implement (ic4/ic5) → N qa refuters → report**

Caller owns commit and `/release`. Distinct from `/debug` (investigation),
`/orchestrate` (full lifecycle), `/council` (audit only), `/review-and-commit`
(diff review + optional commit).

## Arguments

| Args | Action |
|------|--------|
| `<ticket-id> "<bug>"` | Required. Run full pipeline. |
| `--fix "<instructions>"` | Optional fix instructions (else implementer uses premise). |
| `--agent ic4\|ic5` | Implementer (default `ic4`). |
| `--lenses a,b` | Refute lenses (default `correctness,completeness`). |
| `--worktree <path>` | Existing worktree; else `worktree-lib.sh ensure <ticket-id>`. |

Missing ticket-id or premise → usage error, no spawn.

## Step 0: Resolve roots

```bash
_gc=$(git rev-parse --git-common-dir 2>/dev/null) \
  && MROOT=$(cd "$(dirname "$_gc")" && pwd) \
  || MROOT=$(pwd)
WTROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
PDH=$( { [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -f "$CLAUDE_PLUGIN_ROOT/skills/plugin-dir.sh" ] && printf '%s\n' "$CLAUDE_PLUGIN_ROOT"; } || { [ -f skills/plugin-dir.sh ] && pwd; } || find ~/.claude/plugins/cache -path '*/dev-team/*/skills/plugin-dir.sh' 2>/dev/null | sed 's/-pre\./~pre./' | sort -V | tail -1 | sed 's/~pre\./-pre./' | xargs -r dirname | xargs -r dirname )
```

## Step 1: Load skill + invoke

Resolve and follow the full phase driver in the skill (do not restate protocol here):

```bash
_gc=$(git rev-parse --git-common-dir 2>/dev/null) \
  && MROOT=$(cd "$(dirname "$_gc")" && pwd) \
  || MROOT=$(pwd)
PDH=$( { [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -f "$CLAUDE_PLUGIN_ROOT/skills/plugin-dir.sh" ] && printf '%s\n' "$CLAUDE_PLUGIN_ROOT"; } || { [ -f skills/plugin-dir.sh ] && pwd; } || find ~/.claude/plugins/cache -path '*/dev-team/*/skills/plugin-dir.sh' 2>/dev/null | sed 's/-pre\./~pre./' | sort -V | tail -1 | sed 's/~pre\./-pre./' | xargs -r dirname | xargs -r dirname )
SKILL=$(bash "$PDH/skills/plugin-dir.sh" file skills/fix-ticket/SKILL.md)
if [ -z "$SKILL" ] || [ ! -f "$SKILL" ]; then
  echo "error: skills/fix-ticket/SKILL.md not found in the installed plugin" >&2
  exit 1
fi
echo "Loaded fix-ticket protocol: $SKILL"
```

Pass user arguments through unchanged. Execute Steps 1–8 of
`skills/fix-ticket/SKILL.md` (parse args → ensure worktree → premise →
implement → refuters → review → report → next steps).

On refuter spawn failure, follow CDV-199 protocol:
`skills/council/SKILL.md` § Spawn-failure degradation
(marker: `self-verified — refuters unavailable`).

## Notes

- Protocol + schemas + prompts: `skills/fix-ticket/`
- Spec: `specs/core/SPEC-028-fix-ticket-workflow.md`
- Full docs: `docs/commands/fix-ticket.md`
- Report dir: `$MROOT/.claude/fix-ticket/`
