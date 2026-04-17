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
  distill_enabled       true | false
  distill_mode          manual | suggest | auto
  distill_threshold     integer (1-9999)
  distill_model         model name (e.g., haiku, sonnet, opus)
  validate_window_days  integer (1-365)
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
  WHERE key LIKE 'distill%' OR key LIKE 'validate%' OR key = 'schema_version'
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
  distill_enabled|distill_mode|distill_threshold|distill_model|validate_window_days)
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
  validate_window_days)
    if ! [[ "$VALUE" =~ ^[0-9]+$ ]] || [ "$VALUE" -lt 1 ] || [ "$VALUE" -gt 365 ]; then
      echo "Error: validate_window_days must be an integer between 1 and 365."
      exit 1
    fi
    ;;
esac
```

### Step 5c: Apply update

```bash
python3 -c "
import sqlite3, sys
db = sqlite3.connect(sys.argv[1])
db.execute('PRAGMA busy_timeout=5000')
db.execute('UPDATE config SET value=? WHERE key=?', (sys.argv[2], sys.argv[3]))
db.commit()
" "$MEMDB" "$VALUE" "$KEY"
echo "Updated: $KEY = $VALUE"
```
