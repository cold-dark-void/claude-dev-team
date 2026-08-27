---
name: adjust-agent
description: View and manage per-agent behavioral directives — standing orders that persist across sessions. Also sets the local Model map via --model / --model-unset.
argument-hint: "[<agent>] [--apply] [--model <string>] [--model-unset] [<prompt>]"
agent: build
---

# /adjust-agent

View and manage per-agent behavioral directives. Directives are standing orders
that load before memory, persist across sessions, and cannot be overridden by the
agent's own reasoning.

## Arguments

- `/adjust-agent` — Dashboard: show all agents and their directive counts
- `/adjust-agent <agent>` — Read-only view of current directives for one agent
- `/adjust-agent <agent> <prompt>` — Conversational adjustment of an agent's directives
- `/adjust-agent <agent> --apply <prompt>` — Non-interactive adjustment: applies directly on no conflict, exits non-zero on conflict (never prompts)
- `/adjust-agent <agent> --model <string>` — Write local Model map (`write-model.sh set`). Not a directives conversation.
- `/adjust-agent <agent> --model-unset` — Delete that agent's local Model map key (`write-model.sh unset`). Not a directives conversation.

## Step 1: Resolve paths

```bash
_gc=$(git rev-parse --git-common-dir 2>/dev/null) \
  && MROOT=$(cd "$(dirname "$_gc")" && pwd) \
  || MROOT=$(pwd)
DIRECTIVES_BASE="$MROOT/.claude/memory"
```

Resolve the plugin's install directory (for agent name validation):
```bash
# Locate the dev-team plugin root (PDH). Optional CLAUDE_PLUGIN_ROOT (force path / FR #48230), else cwd dev/worktree, else marketplace clone (slug-free agents/pm.md), else installed cache (rank by /dev-team/<VER>/ segment, not full path; CDT-166). CDT-82: marketplace before same-version cache.
# lint-ok: C3 — marketplace */ for-loop + -f guarded (SPEC-021 Q2 residual, CDT-82 PDH)
PDH=$( { [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -f "$CLAUDE_PLUGIN_ROOT/skills/plugin-dir.sh" ] && printf '%s\n' "$CLAUDE_PLUGIN_ROOT"; } || { [ -f skills/plugin-dir.sh ] && pwd; } || { for _mp in "$HOME"/.claude/plugins/marketplaces/*/; do [ -f "${_mp}skills/plugin-dir.sh" ] && [ -f "${_mp}agents/pm.md" ] && printf '%s\n' "${_mp%/}" && break; done; } || find ~/.claude/plugins/cache -path '*/dev-team/*/skills/plugin-dir.sh' 2>/dev/null | awk -F/ '{ver=""; for(i=1;i<=NF;i++) if($i=="dev-team"&&i<NF){ver=$(i+1);break}; if(ver=="") next; m=ver; gsub(/-pre\./,"~pre.",m); p=($0 ~ /\/cache\/cold-dark-void\/dev-team\//)?1:0; print m "\t" p "\t" $0}' | sort -t $'\t' -k1,1V -k2,2n -k3,3 | tail -1 | cut -f3 | xargs -r dirname | xargs -r dirname )
PLUGIN_AGENTS=$(bash "$PDH/skills/plugin-dir.sh" dir agents/pm.md)
```

## Step 2: Parse arguments

Extract the first word as `AGENT` and the remainder as `PROMPT` from the arguments.

Parse `--model` / `--model-unset` **before** treating the remainder as a
directives prompt. `--model` is not a directive conversation and MUST NOT
fall through to Step 5.

- If no arguments: go to **Step 3** (Dashboard mode)
- If agent name + `--model-unset`: go to **Step 7** (Model map unset)
- If agent name + `--model` + string: go to **Step 7** (Model map set)
- If agent name only (one word, no prompt): go to **Step 4** (Read-only mode)
- If agent name + `--apply` + prompt: go to **Step 6** (Non-interactive apply mode)
- If agent name + prompt (no `--apply`): go to **Step 5** (Adjustment mode)

`council-judge` is mappable (Step 7) even though it is not in the 7-agent
dashboard roster.

## Step 3: Dashboard mode (no arguments)

The 7 behavioral agents are: `pm`, `tech-lead`, `ic5`, `ic4`, `devops`, `qa`, `ds`.

For each agent, count directives:
```bash
_gc=$(git rev-parse --git-common-dir 2>/dev/null) \
  && MROOT=$(cd "$(dirname "$_gc")" && pwd) \
  || MROOT=$(pwd)
DIRECTIVES_BASE="$MROOT/.claude/memory"
# lint-ok: C3 — marketplace */ for-loop + -f guarded (SPEC-021 Q2 residual, CDT-82 PDH)
PDH=$( { [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -f "$CLAUDE_PLUGIN_ROOT/skills/plugin-dir.sh" ] && printf '%s\n' "$CLAUDE_PLUGIN_ROOT"; } || { [ -f skills/plugin-dir.sh ] && pwd; } || { for _mp in "$HOME"/.claude/plugins/marketplaces/*/; do [ -f "${_mp}skills/plugin-dir.sh" ] && [ -f "${_mp}agents/pm.md" ] && printf '%s\n' "${_mp%/}" && break; done; } || find ~/.claude/plugins/cache -path '*/dev-team/*/skills/plugin-dir.sh' 2>/dev/null | awk -F/ '{ver=""; for(i=1;i<=NF;i++) if($i=="dev-team"&&i<NF){ver=$(i+1);break}; if(ver=="") next; m=ver; gsub(/-pre\./,"~pre.",m); p=($0 ~ /\/cache\/cold-dark-void\/dev-team\//)?1:0; print m "\t" p "\t" $0}' | sort -t $'\t' -k1,1V -k2,2n -k3,3 | tail -1 | cut -f3 | xargs -r dirname | xargs -r dirname )
RESOLVE_MODEL=$(bash "$PDH/skills/plugin-dir.sh" file skills/model-map/resolve-model.sh)
echo "Agent        Directives  Model"
echo "-----        ----------  -----"
for AGENT in pm tech-lead ic5 ic4 devops qa ds; do
  FILE="$DIRECTIVES_BASE/$AGENT/directives.md"
  COUNT=$(grep -c '^[0-9]' "$FILE" 2>/dev/null || echo 0)
  MODEL=""
  if [ -n "$RESOLVE_MODEL" ] && [ -f "$RESOLVE_MODEL" ]; then
    MODEL=$(bash "$RESOLVE_MODEL" "$AGENT") || MODEL=""
  fi
  [ -n "$MODEL" ] || MODEL="Tier default"
  printf "%-12s %-11s %s\n" "$AGENT" "$COUNT" "$MODEL"
done
```

Display as an aligned table (Model column is the resolved Model map string, or
`Tier default` when empty). `council-judge` is omitted from this roster; use
`/adjust-agent council-judge --model <string>` to map it.

```
Agent        Directives  Model
-----        ----------  -----
pm           3           grok-4
tech-lead    0           Tier default
ic5          1           Tier default
ic4          2           grok-code-fast-1
devops       0           Tier default
qa           0           Tier default
ds           0           Tier default

Use: /adjust-agent <agent> to view, /adjust-agent <agent> <prompt> to adjust,
or /adjust-agent <agent> --model <string> / --model-unset for the Model map.
```

Stop here.

## Step 4: Read-only mode (agent name only)

### Step 4a: Validate agent name

Check if the agent has a definition file in the plugin:
```bash
# lint-ok: C3 — marketplace */ for-loop + -f guarded (SPEC-021 Q2 residual, CDT-82 PDH)
PDH=$( { [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -f "$CLAUDE_PLUGIN_ROOT/skills/plugin-dir.sh" ] && printf '%s\n' "$CLAUDE_PLUGIN_ROOT"; } || { [ -f skills/plugin-dir.sh ] && pwd; } || { for _mp in "$HOME"/.claude/plugins/marketplaces/*/; do [ -f "${_mp}skills/plugin-dir.sh" ] && [ -f "${_mp}agents/pm.md" ] && printf '%s\n' "${_mp%/}" && break; done; } || find ~/.claude/plugins/cache -path '*/dev-team/*/skills/plugin-dir.sh' 2>/dev/null | awk -F/ '{ver=""; for(i=1;i<=NF;i++) if($i=="dev-team"&&i<NF){ver=$(i+1);break}; if(ver=="") next; m=ver; gsub(/-pre\./,"~pre.",m); p=($0 ~ /\/cache\/cold-dark-void\/dev-team\//)?1:0; print m "\t" p "\t" $0}' | sort -t $'\t' -k1,1V -k2,2n -k3,3 | tail -1 | cut -f3 | xargs -r dirname | xargs -r dirname )
PLUGIN_AGENTS=$(bash "$PDH/skills/plugin-dir.sh" dir agents/pm.md)
if [ -n "$PLUGIN_AGENTS" ] && [ ! -f "$PLUGIN_AGENTS/$AGENT.md" ]; then  # lint-ok: C1
  echo "Warning: No agent definition found for '$AGENT' (no agents/$AGENT.md in plugin)."
  echo "This may be a typo. Continuing anyway for forward-compatibility."
  echo ""
fi
```

This is a warning only -- do NOT hard-block. This allows setting directives for
agents that may be added in future versions.

### Step 4b: Display current directives

```bash
_gc=$(git rev-parse --git-common-dir 2>/dev/null) \
  && MROOT=$(cd "$(dirname "$_gc")" && pwd) \
  || MROOT=$(pwd)
DIRECTIVES_BASE="$MROOT/.claude/memory"
FILE="$DIRECTIVES_BASE/$AGENT/directives.md"  # lint-ok: C1
if [ -s "$FILE" ]; then
  echo "Directives for $AGENT:"
  echo ""
  cat "$FILE"
else
  echo "No directives set for $AGENT."
fi
```

Stop here. Do NOT prompt for input.

## Step 5: Adjustment mode (agent + prompt)

### Step 5a: Validate agent name

Same validation as Step 4a. Warn if no agent definition exists, but continue.

### Step 5b: Read existing directives

```bash
_gc=$(git rev-parse --git-common-dir 2>/dev/null) \
  && MROOT=$(cd "$(dirname "$_gc")" && pwd) \
  || MROOT=$(pwd)
DIRECTIVES_BASE="$MROOT/.claude/memory"
FILE="$DIRECTIVES_BASE/$AGENT/directives.md"  # lint-ok: C1
EXISTING=""
if [ -s "$FILE" ]; then
  EXISTING=$(cat "$FILE")
fi
```

### Conflict detection rules

A conflict exists when the incoming prompt is semantically contradictory to an
existing directive (e.g., existing says "always use tabs" and the new prompt says
"use spaces"). When a conflict is found, format it as:

```
Conflict detected:
  Existing #2: "Always use tabs for indentation"
  New request:  "Use 2-space indentation"

These are contradictory. Which should take precedence?
```

### Step 5c: Interpret prompt and detect conflicts

Apply conflict detection rules. If a conflict is found, show it to the user and
wait for their response before continuing. Do NOT silently resolve conflicts by
dropping or rewriting directives without the user's awareness.

### Step 5d: Produce holistic rewrite

Rewrite the ENTIRE directives file as a coherent set. Do NOT blindly append the
new directive to the existing list. Consider all directives together:

- Merge related directives where appropriate
- Remove duplicates
- Resolve any user-confirmed conflict decisions
- Maintain consistent phrasing and scope
- Re-number sequentially starting from 1
- **Trial annotations (SPEC-001 M1 / CDV-200):** lines may end with
  `<!-- trial start=… source=… review-after=… -->`. On holistic rewrite MUST
  **copy through** any trial comment on lines that are not intentionally
  removed or text-replaced. Do not invent trial metadata for lines that never
  had it. Do not strip trial comments unless the prompt explicitly requests
  KEEP-promote (strip) or the line is removed (REVERT).

The result MUST be a numbered list, one directive per line:
```
1. First directive
2. Second directive <!-- trial start=2026-07-03 source=sess#a review-after=10-sessions -->
3. Third directive
```

#### Trial outcome prompt shapes (automation callers / SPEC-001 M5)

Callers (`/retro` trial-review) MUST use these shapes so rewrite intent is unambiguous:

- **KEEP (promote trial → permanent):** strip only the trial comment; keep the
  directive text. Prompt example:
  ```
  Promote the following trial directive to permanent by removing only its
  <!-- trial … --> annotation (leave the directive text). Do not add or remove
  other directives: "<exact directive text without relying on number>"
  ```
  Equivalent `--apply` form is fine. Result line has no trial comment.

- **REVERT (remove trial directive):** delete the directive entirely via the
  normal removal path. Prompt example:
  ```
  Remove this directive entirely (trial REVERT): "<exact directive text>"
  ```
  Conflict detection still applies (M8); on `--apply` conflict, refuse and exit
  non-zero — callers degrade to MANUAL_FOLLOWUP.

Trial directives are full standing orders mid-trial (M8): conflict detection
evaluates them exactly like permanent lines.

### Step 5e: Ensure .gitignore coverage

Before writing, verify that `.claude/memory/` is covered by `.gitignore`:
```bash
_gc=$(git rev-parse --git-common-dir 2>/dev/null) \
  && MROOT=$(cd "$(dirname "$_gc")" && pwd) \
  || MROOT=$(pwd)
GITIGNORE="$MROOT/.gitignore"
if ! grep -qE '^\.claude/memory(/|$)' "$GITIGNORE" 2>/dev/null && \
   ! grep -qF '.claude/memory/' "$GITIGNORE" 2>/dev/null; then
  echo ".claude/memory/" >> "$GITIGNORE"
  echo "(Added .claude/memory/ to .gitignore)"
fi
```

### Step 5f: Write directives file

```bash
_gc=$(git rev-parse --git-common-dir 2>/dev/null) \
  && MROOT=$(cd "$(dirname "$_gc")" && pwd) \
  || MROOT=$(pwd)
DIRECTIVES_BASE="$MROOT/.claude/memory"
mkdir -p "$DIRECTIVES_BASE/$AGENT"  # lint-ok: C1
cat > "$DIRECTIVES_BASE/$AGENT/directives.md" << 'DIREOF'
<the holistic rewritten numbered list>
DIREOF
```

### Step 5g: Show final result

Display the final directive list so the user can verify:
```
Directives for <agent> (updated):

1. First directive
2. Second directive
3. Third directive
```

## Idempotency

Invoking this command with the same prompt twice on the same state MUST produce
the same result. No duplicate directives, no numbering drift, no semantic changes.
When the existing directives already fully satisfy the prompt, confirm this and
leave the file unchanged.

## Step 6: Non-interactive apply mode (`--apply`)

This mode is intended for automation callers (e.g., `/retro --auto`). It reuses
the conflict-detection and holistic-rewrite logic from Step 5 but NEVER prompts.

### Step 6a: Validate agent name

Same validation as Step 4a. Warn to stderr if no agent definition exists, continue.

### Step 6b: Read existing directives

Same as Step 5b.

### Step 6c: Conflict detection (fail-fast)

Apply conflict detection rules. If a conflict is found:

1. Print the conflict description to **stderr**.
2. Do NOT write the file.
3. Exit with a non-zero status.

Do NOT prompt. Do NOT attempt to resolve the conflict automatically.

### Step 6d: Apply on no conflict

If no conflict is detected, proceed directly to:

- Step 5d (holistic rewrite — **including trial-annotation preservation**)
- Step 5e (`.gitignore` coverage)
- Step 5f (write file)
- Step 5g (show final result to stdout)

Exit 0.

Trial KEEP-strip and REVERT-remove prompts (Step 5d shapes) work under `--apply`
the same way as any other non-conflicting rewrite.

## Step 7: Model map (`--model` / `--model-unset`)

Not a directives conversation. Do **not** mix into Step 5. Writes only the
local Model map via `write-model.sh` (never repo/global, never `directives.md`).

`--model <string>` → `write-model.sh set <agent> <string>`
`--model-unset` → `write-model.sh unset <agent>`

`council-judge` is allowed (M8). `qa` / `council-judge` emit the M9 warn on
stderr; still write. Unknown agent / empty string: CLI exits 64 (print stderr).

```bash
# lint-ok: C3 — marketplace */ for-loop + -f guarded (SPEC-021 Q2 residual, CDT-82 PDH)
PDH=$( { [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -f "$CLAUDE_PLUGIN_ROOT/skills/plugin-dir.sh" ] && printf '%s\n' "$CLAUDE_PLUGIN_ROOT"; } || { [ -f skills/plugin-dir.sh ] && pwd; } || { for _mp in "$HOME"/.claude/plugins/marketplaces/*/; do [ -f "${_mp}skills/plugin-dir.sh" ] && [ -f "${_mp}agents/pm.md" ] && printf '%s\n' "${_mp%/}" && break; done; } || find ~/.claude/plugins/cache -path '*/dev-team/*/skills/plugin-dir.sh' 2>/dev/null | awk -F/ '{ver=""; for(i=1;i<=NF;i++) if($i=="dev-team"&&i<NF){ver=$(i+1);break}; if(ver=="") next; m=ver; gsub(/-pre\./,"~pre.",m); p=($0 ~ /\/cache\/cold-dark-void\/dev-team\//)?1:0; print m "\t" p "\t" $0}' | sort -t $'\t' -k1,1V -k2,2n -k3,3 | tail -1 | cut -f3 | xargs -r dirname | xargs -r dirname )
WRITE_MODEL=$(bash "$PDH/skills/plugin-dir.sh" file skills/model-map/write-model.sh)
if [ -z "$WRITE_MODEL" ] || [ ! -f "$WRITE_MODEL" ]; then
  echo "error: skills/model-map/write-model.sh not found in the installed plugin" >&2
  exit 1
fi
AGENT="${1:-}"
shift || true
case "${1:-}" in
  --model-unset) bash "$WRITE_MODEL" unset "$AGENT" ;;
  --model)
    shift || true
    bash "$WRITE_MODEL" set "$AGENT" "${1:-}"
    ;;
  *)
    echo "usage: /adjust-agent <agent> --model <string> | --model-unset" >&2
    exit 64
    ;;
esac
```

Stop here. Do not open a directives rewrite.
