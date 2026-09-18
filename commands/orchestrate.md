---
name: orchestrate
description: >
  Full lifecycle orchestrator — fetches issue context, creates a worktree,
  spawns agents end-to-end, enforces tech-lead review loops, and optionally
  ships a PR. You stay observer/navigator; agents do the work. Usage:
  /orchestrate <ISSUE-ID> | /orchestrate
argument-hint: '<ISSUE-ID> [--autopilot[=<token>]] [--tier=<light|standard|full>] [--council-tier=<skip|light|full>] [--resume-ship] [--max-loc=<n|unbound>]'
---

# /orchestrate

Thin host over `skills/orchestrate/SKILL.md`. Protocol lives in the skill;
this file only resolves the skill and passes args through.

```
/orchestrate <ISSUE-ID>
/orchestrate
```

Flags (`--autopilot`, `--tier`, `--council-tier`, `--resume-ship`, `--max-loc`)
are skill-owned. Do not restate the pipeline here.

## Step 0: Resolve skill (PDH)

```bash
_gc=$(git rev-parse --git-common-dir 2>/dev/null) \
  && MROOT=$(cd "$(dirname "$_gc")" && pwd) \
  || MROOT=$(pwd)
WTROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
# lint-ok: C3 — marketplace */ for-loop + -f guarded (SPEC-021 Q2 residual, CDT-82 PDH)
PDH=$( { [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -f "$CLAUDE_PLUGIN_ROOT/skills/plugin-dir.sh" ] && printf '%s\n' "$CLAUDE_PLUGIN_ROOT"; } || { [ -f skills/plugin-dir.sh ] && pwd; } || { _pr='${CLAUDE_PLUGIN_ROOT}'; [ -f "$_pr/skills/plugin-dir.sh" ] && printf '%s\n' "$_pr"; } || { for _mp in "$HOME"/.claude/plugins/marketplaces/*/; do [ -f "${_mp}skills/plugin-dir.sh" ] && [ -f "${_mp}agents/pm.md" ] && printf '%s\n' "${_mp%/}" && break; done; } || find ~/.claude/plugins/cache -path '*/dev-team/*/skills/plugin-dir.sh' 2>/dev/null | awk -F/ '{ver=""; for(i=1;i<=NF;i++) if($i=="dev-team"&&i<NF){ver=$(i+1);break}; if(ver=="") next; m=ver; gsub(/-pre\./,"~pre.",m); p=($0 ~ /\/cache\/cold-dark-void\/dev-team\//)?1:0; print m "\t" p "\t" $0}' | sort -t $'\t' -k1,1V -k2,2n -k3,3 | tail -1 | cut -f3 | xargs -r dirname | xargs -r dirname )
SKILL=$(bash "$PDH/skills/plugin-dir.sh" file skills/orchestrate/SKILL.md)
if [ -z "$SKILL" ] || [ ! -f "$SKILL" ]; then
  echo "error: skills/orchestrate/SKILL.md not found in the installed plugin" >&2
  exit 1
fi
echo "Loaded orchestrate protocol: $SKILL"
```

## Step 1: Follow the skill

Read `$SKILL` and execute it end-to-end with `$ARGUMENTS` unchanged.

- Parse, flags, and step files live in the skill — do not restate protocol here.
