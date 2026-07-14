---
name: adjust-agent
description: View and manage per-agent behavioral directives — standing orders that persist across sessions.
argument-hint: "[<agent>] [--apply] [<prompt>]"
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

## Step 1: Resolve paths

```bash
_gc=$(git rev-parse --git-common-dir 2>/dev/null) \
  && MROOT=$(cd "$(dirname "$_gc")" && pwd) \
  || MROOT=$(pwd)
DIRECTIVES_BASE="$MROOT/.claude/memory"
```

Resolve the plugin's install directory (for agent name validation):
```bash
# Locate the dev-team plugin root (PDH). Dev checkout first, else installed cache (highest version). Slug-free, sort -V.
PDH=$( [ -f skills/plugin-dir.sh ] && pwd || find ~/.claude/plugins/cache -path '*/dev-team/*/skills/plugin-dir.sh' 2>/dev/null | sort -V | tail -1 | xargs -r dirname | xargs -r dirname )
PLUGIN_AGENTS=$(bash "$PDH/skills/plugin-dir.sh" dir agents/pm.md)
```

## Step 2: Parse arguments

Extract the first word as `AGENT` and the remainder as `PROMPT` from the arguments.

- If no arguments: go to **Step 3** (Dashboard mode)
- If agent name only (one word, no prompt): go to **Step 4** (Read-only mode)
- If agent name + `--apply` + prompt: go to **Step 6** (Non-interactive apply mode)
- If agent name + prompt (no `--apply`): go to **Step 5** (Adjustment mode)

## Step 3: Dashboard mode (no arguments)

The 7 behavioral agents are: `pm`, `tech-lead`, `ic5`, `ic4`, `devops`, `qa`, `ds`.

For each agent, count directives:
```bash
_gc=$(git rev-parse --git-common-dir 2>/dev/null) \
  && MROOT=$(cd "$(dirname "$_gc")" && pwd) \
  || MROOT=$(pwd)
DIRECTIVES_BASE="$MROOT/.claude/memory"
for AGENT in pm tech-lead ic5 ic4 devops qa ds; do
  FILE="$DIRECTIVES_BASE/$AGENT/directives.md"
  COUNT=$(grep -c '^[0-9]' "$FILE" 2>/dev/null || echo 0)
  printf "%-12s %s\n" "$AGENT" "$COUNT"
done
```

Display as an aligned table:

```
Agent        Directives
-----        ----------
pm           3
tech-lead    0
ic5          1
ic4          2
devops       0
qa           0
ds           0

Use: /adjust-agent <agent> to view, or /adjust-agent <agent> <prompt> to adjust.
```

Stop here.

## Step 4: Read-only mode (agent name only)

### Step 4a: Validate agent name

Check if the agent has a definition file in the plugin:
```bash
PDH=$( [ -f skills/plugin-dir.sh ] && pwd || find ~/.claude/plugins/cache -path '*/dev-team/*/skills/plugin-dir.sh' 2>/dev/null | sort -V | tail -1 | xargs -r dirname | xargs -r dirname )
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

The result MUST be a numbered list, one directive per line:
```
1. First directive
2. Second directive
3. Third directive
```

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

- Step 5d (holistic rewrite)
- Step 5e (`.gitignore` coverage)
- Step 5f (write file)
- Step 5g (show final result to stdout)

Exit 0.
