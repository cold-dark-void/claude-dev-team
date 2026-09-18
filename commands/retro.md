---
name: retro
description: Session retrospective — scan past sessions for friction patterns and propose targeted behavioral adjustments for team agents or plain Claude. Supports Claude Code and Grok hosts via --host. --all --auto writes a scheduled report under .claude/retro/.
argument-hint: "[<session-id>] [--host claude|grok|all] [--all] [--auto] [--why]"
agent: build
---

# /retro

Thin host over `skills/retro/SKILL.md` (SPEC-012). Protocol owns parse →
discover → phase-1 gate → phase-2 spawn → route/dedup → trial review →
confirm/apply. This file only resolves the skill and passes args through.

```
/retro
/retro <session-id>
/retro --host claude|grok|all
/retro --host grok <session-id>
/retro --all
/retro --auto
/retro --why
/retro --all --auto
```

| Arg / flag | Default | Notes |
|------------|---------|-------|
| `<session-id>` | newest for host | Claude UUID; Grok cwd-bucket id. Mutually exclusive with `--all`. |
| `--host claude\|grok\|all` | auto-detect | Bare `--all` without `--host` ⇒ `--host all`. Explicit `--host grok` never falls back to Claude. |
| `--all` | off | Cross-session mining; surface patterns that recur in 2+ sessions. |
| `--auto` | off | Skip confirm UI. With `--all`, scheduled runner (lock + report). |
| `--why` | off | Print per-session gate signal table (calibration). |

**Sequence (skill-owned):**

```
parse → lock (--all --auto) → discover/filter/normalize → gate
  → [smooth exit] → spawn retro-subagent → validate/rank → route/dedup
  → trial review → confirm/apply → summary [→ scheduled report]
```

**Hard walls (one-liner):** `--all` and `<session-id>` mutually exclusive; explicit `--host grok` never falls back to Claude; missing `gate.sh` is a hard error; no directive writes except via `/adjust-agent`; DUPLICATE never auto-applied; scheduled lock skip does not write a report.

## Step 0: Resolve skill (PDH)

```bash
_gc=$(git rev-parse --git-common-dir 2>/dev/null) \
  && MROOT=$(cd "$(dirname "$_gc")" && pwd) \
  || MROOT=$(pwd)
WTROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
# lint-ok: C3 — marketplace */ for-loop + -f guarded (SPEC-021 Q2 residual, CDT-82 PDH)
PDH=$( { [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -f "$CLAUDE_PLUGIN_ROOT/skills/plugin-dir.sh" ] && printf '%s\n' "$CLAUDE_PLUGIN_ROOT"; } || { [ -f skills/plugin-dir.sh ] && pwd; } || { _pr='${CLAUDE_PLUGIN_ROOT}'; [ -f "$_pr/skills/plugin-dir.sh" ] && printf '%s\n' "$_pr"; } || { for _mp in "$HOME"/.claude/plugins/marketplaces/*/; do [ -f "${_mp}skills/plugin-dir.sh" ] && [ -f "${_mp}agents/pm.md" ] && printf '%s\n' "${_mp%/}" && break; done; } || find ~/.claude/plugins/cache -path '*/dev-team/*/skills/plugin-dir.sh' 2>/dev/null | awk -F/ '{ver=""; for(i=1;i<=NF;i++) if($i=="dev-team"&&i<NF){ver=$(i+1);break}; if(ver=="") next; m=ver; gsub(/-pre\./,"~pre.",m); p=($0 ~ /\/cache\/cold-dark-void\/dev-team\//)?1:0; print m "\t" p "\t" $0}' | sort -t $'\t' -k1,1V -k2,2n -k3,3 | tail -1 | cut -f3 | xargs -r dirname | xargs -r dirname )
SKILL=$(bash "$PDH/skills/plugin-dir.sh" file skills/retro/SKILL.md)
if [ -z "$SKILL" ] || [ ! -f "$SKILL" ]; then
  echo "error: skills/retro/SKILL.md not found in the installed plugin" >&2
  exit 1
fi
echo "Loaded retro protocol: $SKILL"
```

## Step 1: Follow the skill

Read `$SKILL` and execute it end-to-end with the user arguments unchanged.

- Parse, scheduled lock, session discovery, filters, phase-1 gate, phase-2
  spawn, routing, trial review, and confirm/apply live in the skill —
  do not restate protocol here.
- Phase 1 still calls `skills/retro-gate/gate.sh`. Phase 2 still uses
  `skills/retro-subagent/SKILL.md` for the Task prompt.
- Do not invoke `/council` from this command (print-only fabrication hints).

## Notes

- Protocol body: `skills/retro/SKILL.md`
- Spec: `specs/core/SPEC-012-session-retrospective.md`
- Gate: `skills/retro-gate/` · Subagent: `skills/retro-subagent/` · Locate: `skills/transcript-parse/`
