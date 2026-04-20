---
name: tdd-gate
description: Toggle hook-based TDD enforcement — blocks Write/Edit to implementation files when no corresponding test file exists. Usage /tdd-gate on, /tdd-gate off, /tdd-gate status
---

# TDD Gate

Hook-based TDD enforcement toggle. When enabled, a `PreToolUse` hook enforces
Write/Edit operations on implementation files unless a corresponding test file
already exists. Uses graduated enforcement per session: hint (1st attempt) →
warning (2nd) → hard block (3rd+). Forces the red-green-refactor discipline
at the tool level — deterministic, not probabilistic.

## Arguments

- `/tdd-gate on` — install the PreToolUse hook
- `/tdd-gate off` — remove the PreToolUse hook
- `/tdd-gate status` — show current state
- `/tdd-gate` (no argument) — same as `status`

## How It Works

The hook intercepts Write and Edit tool calls. For each target file, it checks
whether a corresponding test file exists. If no test file is found, the hook
exits with code 2 (block) and tells the agent to write a failing test first.

**Test file detection** (checked in order):

| Source file pattern | Expected test file(s) |
|--------------------|-----------------------|
| `src/foo.ts` | `src/foo.test.ts`, `src/foo.spec.ts`, `test/foo.test.ts`, `tests/foo.test.ts` |
| `src/foo.js` | `src/foo.test.js`, `src/foo.spec.js`, `test/foo.test.js`, `tests/foo.test.js` |
| `src/foo.py` | `src/test_foo.py`, `tests/test_foo.py`, `test/test_foo.py`, `src/foo_test.py` |
| `pkg/foo.go` | `pkg/foo_test.go` |
| `src/foo.rs` | `src/foo_test.rs`, `tests/foo.rs` |

**Always allowed** (never blocked):

- Test files themselves (`*.test.*`, `*.spec.*`, `test_*`, `*_test.*`)
- Config files (`*.json`, `*.yaml`, `*.yml`, `*.toml`, `*.md`, `*.txt`)
- CI/CD files (`.github/`, `.gitlab-ci*`, `Dockerfile*`, `docker-compose*`)
- Lock files (`*.lock`, `package-lock.json`, `go.sum`)
- Type definitions (`*.d.ts`, `*.pyi`)
- Migration files (`**/migrations/**`)
- Spec files (`specs/**`)
- `.claude/**` files

## Step 1: Resolve paths

```bash
WTROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
SETTINGS="$WTROOT/.claude/settings.json"
HOOK_SCRIPT="$WTROOT/.claude/hooks/tdd-gate.sh"
```

## Step 2: Parse argument

Default to `status` if no argument is given.

## Step 3: Handle `status`

Check if `$HOOK_SCRIPT` exists and if `$SETTINGS` contains a `PreToolUse` hook
referencing `tdd-gate.sh`. Print one of:

```
TDD Gate: ENABLED — Write/Edit to implementation files blocked without tests
TDD Gate: DISABLED
```

## Step 4: Handle `on`

### 4a: Create the hook script

Create `.claude/hooks/` if needed, then write `.claude/hooks/tdd-gate.sh`:

```bash
#!/usr/bin/env bash
# PreToolUse hook — TDD gate. Blocks Write/Edit to implementation files
# when no corresponding test file exists.
# Exit 2 = block (stderr feedback to agent). Exit 0 = allow.

INPUT=$(cat)

TOOL_NAME=$(echo "$INPUT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('tool_name',''))" 2>/dev/null || true)

# Only gate Write, Edit, and MultiEdit
case "$TOOL_NAME" in
  Write|Edit|MultiEdit) ;;
  *) exit 0 ;;
esac

FILE_PATH=$(echo "$INPUT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('tool_input',{}).get('file_path',''))" 2>/dev/null || true)
[ -z "$FILE_PATH" ] && exit 0

BASENAME=$(basename "$FILE_PATH")
DIRNAME=$(dirname "$FILE_PATH")

# Always allow: test files
case "$BASENAME" in
  *.test.*|*.spec.*|test_*|*_test.go|*_test.rs|*_test.py) exit 0 ;;
esac

# Always allow: config, docs, CI, locks, types, migrations, specs, .claude
case "$BASENAME" in
  *.json|*.yaml|*.yml|*.toml|*.md|*.txt|*.lock|*.d.ts|*.pyi) exit 0 ;;
  Dockerfile*|docker-compose*|Makefile|Taskfile*|*.sh) exit 0 ;;
esac
case "$FILE_PATH" in
  */.github/*|*/.gitlab-ci*|*/migrations/*|*/specs/*|*/.claude/*) exit 0 ;;
esac

# Determine language and expected test patterns
EXT="${BASENAME##*.}"
NAME="${BASENAME%.*}"

FOUND_TEST=false

check_exists() { [ -f "$1" ] && FOUND_TEST=true; }

case "$EXT" in
  ts|tsx)
    check_exists "$DIRNAME/$NAME.test.$EXT"
    check_exists "$DIRNAME/$NAME.spec.$EXT"
    check_exists "$DIRNAME/$NAME.test.ts"
    check_exists "$DIRNAME/$NAME.spec.ts"
    # Check test/ and tests/ directories relative to project root
    WTROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
    REL=${FILE_PATH#"$WTROOT/"}
    REL_NAME="${REL%.*}"
    REL_NAME_STRIPPED="${REL_NAME#src/}"  # Strip src/ prefix for test/ lookups
    check_exists "$WTROOT/test/$REL_NAME_STRIPPED.test.ts"
    check_exists "$WTROOT/tests/$REL_NAME_STRIPPED.test.ts"
    check_exists "$WTROOT/__tests__/$REL_NAME_STRIPPED.test.ts"
    ;;
  js|jsx)
    check_exists "$DIRNAME/$NAME.test.$EXT"
    check_exists "$DIRNAME/$NAME.spec.$EXT"
    check_exists "$DIRNAME/$NAME.test.js"
    check_exists "$DIRNAME/$NAME.spec.js"
    WTROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
    REL=${FILE_PATH#"$WTROOT/"}
    REL_NAME="${REL%.*}"
    REL_NAME_STRIPPED="${REL_NAME#src/}"  # Strip src/ prefix for test/ lookups
    check_exists "$WTROOT/test/$REL_NAME_STRIPPED.test.js"
    check_exists "$WTROOT/tests/$REL_NAME_STRIPPED.test.js"
    check_exists "$WTROOT/__tests__/$REL_NAME_STRIPPED.test.js"
    ;;
  py)
    check_exists "$DIRNAME/test_$NAME.py"
    check_exists "$DIRNAME/${NAME}_test.py"
    WTROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
    REL=${FILE_PATH#"$WTROOT/"}
    REL_DIR=$(dirname "$REL")
    check_exists "$WTROOT/tests/test_$NAME.py"
    check_exists "$WTROOT/test/test_$NAME.py"
    check_exists "$WTROOT/tests/$REL_DIR/test_$NAME.py"
    ;;
  go)
    check_exists "$DIRNAME/${NAME}_test.go"
    ;;
  rs)
    check_exists "$DIRNAME/${NAME}_test.rs"
    WTROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
    check_exists "$WTROOT/tests/$NAME.rs"
    ;;
  *)
    # Unknown language — allow
    exit 0
    ;;
esac

if [ "$FOUND_TEST" = "false" ]; then
  # Graduated enforcement: hint (1st) → warning (2nd) → block (3rd+)
  SESSION_ID=$(echo "$INPUT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('session_id','unknown'))" 2>/dev/null || echo "unknown")
  FILE_HASH=$(echo "$FILE_PATH" | python3 -c "import sys,hashlib; print(hashlib.md5(sys.stdin.read().strip().encode()).hexdigest()[:8])" 2>/dev/null || echo "unknown")
  COUNTER_FILE="${TMPDIR:-/tmp}/tdd-gate-${SESSION_ID}-${FILE_HASH}"

  # Increment counter
  COUNT=1
  [ -f "$COUNTER_FILE" ] && COUNT=$(( $(cat "$COUNTER_FILE") + 1 ))
  echo "$COUNT" > "$COUNTER_FILE"

  LOCATIONS=""
  case "$EXT" in
    ts|tsx) LOCATIONS="$DIRNAME/$NAME.test.ts or $DIRNAME/$NAME.spec.ts" ;;
    js|jsx) LOCATIONS="$DIRNAME/$NAME.test.js or $DIRNAME/$NAME.spec.js" ;;
    py)     LOCATIONS="$DIRNAME/test_$NAME.py or tests/test_$NAME.py" ;;
    go)     LOCATIONS="$DIRNAME/${NAME}_test.go" ;;
    rs)     LOCATIONS="$DIRNAME/${NAME}_test.rs or tests/$NAME.rs" ;;
  esac

  if [ "$COUNT" -eq 1 ]; then
    # Hint: allow but nudge
    echo "TDD hint: No test file found for $BASENAME. Consider writing a failing test first." >&2
    echo "Expected: $LOCATIONS" >&2
    exit 0
  elif [ "$COUNT" -eq 2 ]; then
    # Warning: allow but stronger nudge
    echo "TDD warning: Still no test file for $BASENAME. Write the test before continuing implementation." >&2
    echo "Expected: $LOCATIONS" >&2
    exit 0
  else
    # Block: 3rd+ attempt
    echo "TDD GATE: No test file found for $BASENAME — blocked after $COUNT attempts." >&2
    echo "Write a failing test first, then implement." >&2
    echo "Expected: $LOCATIONS" >&2
    exit 2
  fi
fi

exit 0
```

Make it executable:
```bash
chmod +x .claude/hooks/tdd-gate.sh
```

### 4b: Add the PreToolUse hook to settings.json

Read `$SETTINGS`. If `hooks.PreToolUse` does not exist, add it:

```json
"PreToolUse": [
  {
    "hooks": [
      {
        "type": "command",
        "command": "bash .claude/hooks/tdd-gate.sh"
      }
    ]
  }
]
```

If `hooks.PreToolUse` already exists, append the tdd-gate entry to the
existing array. Write the merged result back.

### 4c: Print confirmation

```
TDD Gate: ENABLED
Write/Edit to implementation files will be blocked unless a test file exists.
Supported: TypeScript, JavaScript, Python, Go, Rust
Disable with: /tdd-gate off
```

## Step 5: Handle `off`

1. Remove the `PreToolUse` hook entry referencing `tdd-gate.sh` from `$SETTINGS`
   - If `PreToolUse` array becomes empty after removal, delete the key entirely
2. Delete `$HOOK_SCRIPT` if it exists
3. Print:

```
TDD Gate: DISABLED
```

## Notes

- The hook is per-project (installed in the worktree's `.claude/settings.json`)
- It only gates supported languages — unknown extensions are always allowed
- The hook does NOT check whether the test is failing (that's the agent's job)
- It only verifies that a test file _exists_ — a minimal bar that ensures TDD
  is at least structurally followed
- Graduated enforcement tracks attempts per file per session via `$TMPDIR`
  counter files. Counter resets on new session. First attempt is a hint (exit 0),
  second is a warning (exit 0), third+ is a block (exit 2).
- Does not interfere with `/init-orchestration` hooks — they use different events
