---
name: memory-config
description: View and set memory configuration (distillation mode, threshold, model)
argument-hint: list | set <key> <value>
---

# /memory-config

View and update memory distillation configuration stored in the SQLite config table.

## Arguments

- `/memory-config list` — show all distill-related config keys and values
- `/memory-config set <key> <value>` — update a config key
- `/memory-config` (no args) — print usage

## Step 1: Parse arguments

If no arguments provided, print:
```
Usage: /memory-config list
       /memory-config set <key> <value>

Settable keys:
  distill_enabled    true | false
  distill_mode       manual | suggest | auto
  distill_threshold  integer (1-9999)
  distill_model      model name (e.g., haiku, sonnet, opus)
```
And stop.

## Step 2: Resolve paths

```bash
_gc=$(git rev-parse --git-common-dir 2>/dev/null) \
  && MROOT=$(cd "$(dirname "$_gc")" && pwd) \
  || MROOT=$(pwd)
MEMDB="$MROOT/.claude/memory/memory.db"
```

## Step 3: Guard — DB must exist

```bash
if [ ! -f "$MEMDB" ]; then
  echo "Error: memory DB not found. Run /init-team first."
  exit 1
fi
```

## Step 4: Handle `list` subcommand

If the first argument is `list`:

```bash
sqlite3 -header -column "$MEMDB" \
  "SELECT key,
    CASE WHEN key='distilling_lock' AND value='' THEN '(none)' ELSE value END AS value,
    updated_at
  FROM config
  WHERE key LIKE 'distill%' OR key = 'schema_version'
  ORDER BY key;"
```

And stop.

## Step 5: Handle `set <key> <value>` subcommand

If the first argument is `set`, extract `KEY` (second argument) and `VALUE` (third argument).

If fewer than 3 arguments provided, print:
```
Usage: /memory-config set <key> <value>
```
And stop.

### Step 5a: Reject read-only and unknown keys

```bash
case "$KEY" in
  distilling_lock)
    echo "Error: 'distilling_lock' cannot be set manually. Use /memory-distill --force to clear."
    exit 1
    ;;
  schema_version)
    echo "Error: 'schema_version' is managed by migrations."
    exit 1
    ;;
  distill_enabled|distill_mode|distill_threshold|distill_model)
    # settable — continue to validation
    ;;
  *)
    echo "Error: '$KEY' is not a settable config key."
    exit 1
    ;;
esac
```

### Step 5b: Validate value per key

```bash
case "$KEY" in
  distill_enabled)
    if [ "$VALUE" != "true" ] && [ "$VALUE" != "false" ]; then
      echo "Error: distill_enabled must be 'true' or 'false'."
      exit 1
    fi
    ;;
  distill_mode)
    if [ "$VALUE" != "manual" ] && [ "$VALUE" != "suggest" ] && [ "$VALUE" != "auto" ]; then
      echo "Error: distill_mode must be 'manual', 'suggest', or 'auto'."
      exit 1
    fi
    ;;
  distill_threshold)
    if ! [[ "$VALUE" =~ ^[0-9]+$ ]] || [ "$VALUE" -lt 1 ] || [ "$VALUE" -gt 9999 ]; then
      echo "Error: distill_threshold must be an integer between 1 and 9999."
      exit 1
    fi
    ;;
  distill_model)
    if [ -z "$VALUE" ]; then
      echo "Error: distill_model cannot be empty."
      exit 1
    fi
    ;;
esac
```

### Step 5c: Apply update

```bash
ESCAPED=$(printf '%s' "$VALUE" | sed "s/'/''/g")
sqlite3 "$MEMDB" "UPDATE config SET value='$ESCAPED' WHERE key='$KEY';"
echo "Updated: $KEY = $VALUE"
```
