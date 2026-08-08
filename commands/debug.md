---
name: debug
description: >
  Phase-gated bug investigation → root-cause → fix → verify (full/patch/arch),
  or premise→implement→adversarial-refuters ticket pipeline (SPEC-028).
  Usage: /debug [patch|arch|ticket] …
argument-hint: '[patch|arch|ticket] <args…>'
---

# /debug

Thin host over `skills/debug/SKILL.md` (SPEC-014; ticket protocol SPEC-028).

| First token | Mode | Behavior |
|-------------|------|----------|
| _(none / other)_ | `full` | Investigation → root cause → fix → verify |
| `patch` | `patch` | Fast path: root cause → test → fix |
| `arch` | `arch` | Root cause only → mandatory `/kickoff` |
| `ticket` | `ticket` | Premise → implement → N qa refuters → report |

**Ticket grammar:**

```
/debug ticket <ticket-id> "<bug/premise>" [--fix "…"] [--agent ic4|ic5] [--lenses a,b] [--worktree <path>]
```

Missing ticket-id or premise → usage error, no agent spawn.
`ticket` mode MUST NOT commit, version-bump, or run `/release` (caller owns ship).

## Step 0: Resolve skill (PDH)

```bash
_gc=$(git rev-parse --git-common-dir 2>/dev/null) \
  && MROOT=$(cd "$(dirname "$_gc")" && pwd) \
  || MROOT=$(pwd)
WTROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
# lint-ok: C3 — marketplace */ for-loop + -f guarded (SPEC-021 Q2 residual, CDT-82 PDH)
PDH=$( { [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -f "$CLAUDE_PLUGIN_ROOT/skills/plugin-dir.sh" ] && printf '%s\n' "$CLAUDE_PLUGIN_ROOT"; } || { [ -f skills/plugin-dir.sh ] && pwd; } || { for _mp in "$HOME"/.claude/plugins/marketplaces/*/; do [ -f "${_mp}skills/plugin-dir.sh" ] && [ -f "${_mp}agents/pm.md" ] && printf '%s\n' "${_mp%/}" && break; done; } || find ~/.claude/plugins/cache -path '*/dev-team/*/skills/plugin-dir.sh' 2>/dev/null | awk -F/ '{ver=""; for(i=1;i<=NF;i++) if($i=="dev-team"&&i<NF){ver=$(i+1);break}; if(ver=="") next; m=ver; gsub(/-pre\./,"~pre.",m); p=($0 ~ /\/cache\/cold-dark-void\/dev-team\//)?1:0; print m "\t" p "\t" $0}' | sort -t $'\t' -k1,1V -k2,2n -k3,3 | tail -1 | cut -f3 | xargs -r dirname | xargs -r dirname )
SKILL=$(bash "$PDH/skills/plugin-dir.sh" file skills/debug/SKILL.md)
if [ -z "$SKILL" ] || [ ! -f "$SKILL" ]; then
  echo "error: skills/debug/SKILL.md not found in the installed plugin" >&2
  exit 1
fi
echo "Loaded debug protocol: $SKILL"
```

## Step 1: Follow the skill

Read `$SKILL` and execute it end-to-end with the user arguments unchanged.

- First-token mode parse, SPEC-014/029 gates (`full`/`patch`/`arch`), and
  `ticket` → SPEC-028 pipeline live in the skill — do not restate protocol here.
- On `ticket` refuter spawn failure, follow CDV-199:
  `skills/council/SKILL.md` § Spawn-failure degradation
  (marker: `self-verified — refuters unavailable`).

## Notes

- Protocol body: `skills/debug/SKILL.md`
- Ticket pipeline assets (internal backend for `/debug ticket`): `skills/fix-ticket/`
- Specs: `specs/core/SPEC-014-debug-workflow.md`, `SPEC-028-fix-ticket-workflow.md`, `SPEC-029`
- Docs: `docs/commands/debug.md`
