---
name: craft-loop
description: Design a reviewed, file-persisted loop program for the built-in
  /loop and /goal commands — guided crafting dialogue, journal-based state,
  refine-from-journal, and library listing. Supports hold/dogfood (no-write).
  Usage /craft-loop [goal text | list | refine <name>]
---

# Craft Loop

Designs *loop programs* — reviewed markdown files under `.claude/loops/` that
the **built-in** `/loop` and `/goal` commands execute via a pointer prompt.
This command ships no runtime and never starts a loop: it produces the program
file and hands you the invocation line (or a would-be line in hold/dogfood).

Why: a naive prompt fired repeatedly into a session drifts, loses its place
between firings, never terminates, or takes unattended risks. A crafted
program carries a per-iteration procedure, journal-based state, an objectively
checkable stop condition, guardrails, and decision-card escalation.

Governing spec: `specs/core/SPEC-020-craft-loop-prompt-architect.md`.

## Usage

```
/craft-loop <goal text>     # craft a new program (guided dialogue)
/craft-loop                 # craft mode; you will be asked for the goal
/craft-loop list            # table of the project's programs + open decisions
/craft-loop refine <name>   # improve a program from its run journal
```

**Hold / dogfood:** if during craft you say hold, dogfood only, do not save, or
no-write, the architect keeps the draft in chat and does **not** write
`.claude/loops/`.

## Mode routing

Interpret the arguments:

1. Exactly `list` (`/craft-loop list`) → **list mode**
2. Starts with `refine` followed by a name → **refine mode** for that name
   (bare `refine` with no name: ask which program, offering the library list)
3. Anything else (including empty) → **craft mode**; the arguments are the
   goal, or ask for the goal if empty

## Step 0: Resolve skill (PDH)

```bash
_gc=$(git rev-parse --git-common-dir 2>/dev/null) \
  && MROOT=$(cd "$(dirname "$_gc")" && pwd) \
  || MROOT=$(pwd)
WTROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
# lint-ok: C3 — marketplace */ for-loop + -f guarded (SPEC-021 Q2 residual, CDT-82 PDH)
PDH=$( { [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -f "$CLAUDE_PLUGIN_ROOT/skills/plugin-dir.sh" ] && printf '%s\n' "$CLAUDE_PLUGIN_ROOT"; } || { [ -f skills/plugin-dir.sh ] && pwd; } || { _pr='${CLAUDE_PLUGIN_ROOT}'; [ -f "$_pr/skills/plugin-dir.sh" ] && printf '%s\n' "$_pr"; } || { for _mp in "$HOME"/.claude/plugins/marketplaces/*/; do [ -f "${_mp}skills/plugin-dir.sh" ] && [ -f "${_mp}agents/pm.md" ] && printf '%s\n' "${_mp%/}" && break; done; } || find ~/.claude/plugins/cache -path '*/dev-team/*/skills/plugin-dir.sh' 2>/dev/null | awk -F/ '{ver=""; for(i=1;i<=NF;i++) if($i=="dev-team"&&i<NF){ver=$(i+1);break}; if(ver=="") next; m=ver; gsub(/-pre\./,"~pre.",m); p=($0 ~ /\/cache\/cold-dark-void\/dev-team\//)?1:0; print m "\t" p "\t" $0}' | sort -t $'\t' -k1,1V -k2,2n -k3,3 | tail -1 | cut -f3 | xargs -r dirname | xargs -r dirname )
SKILL=$(bash "$PDH/skills/plugin-dir.sh" file skills/craft-loop/SKILL.md)
if [ -z "$SKILL" ] || [ ! -f "$SKILL" ]; then
  echo "error: skills/craft-loop/SKILL.md not found in the installed plugin" >&2
  exit 1
fi
echo "Loaded craft-loop protocol: $SKILL"
```

## Step 1: Follow the skill

Read `$SKILL` and execute it end-to-end for the selected mode with the user
arguments unchanged.

The skill's hard rules apply verbatim — most importantly: never invoke `/loop`
or `/goal` yourself, and never write a program file before the user approves
the draft in chat (and never on hold).

**Hard rule (restated):** MUST NOT start `/loop` or `/goal` in any mode. This
command is the architect only; the user fires the built-in runtime.

## Relationship to the built-ins

| | Built-in `/loop` / `/goal` | This command |
|---|---|---|
| Role | Runtime — fires the prompt | Architect — designs the program |
| State | The session | `.claude/loops/` files, editable mid-run |
| Output | Iterations of work | A reviewed program + invocation line |
