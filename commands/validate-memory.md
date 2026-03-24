---
name: validate-memory
description: Cross-reference agent memories against the live codebase to detect stale references
argument-hint: "[--agent <name>] [--deep] [--force]"
---

# /validate-memory

Cross-reference agent memories against the live codebase to detect and resolve
stale references — dead files, renamed functions, shifted line numbers. Uses a
multi-stage pipeline with confidence scoring: validator proposes, tech-lead
reviewer confirms, user decides ambiguous cases.

## Arguments

- `/validate-memory` -- validate all agents' memories
- `/validate-memory --agent <name>` -- validate only one agent's memories
- `/validate-memory --deep` -- also rebuild digests whose sources have gone stale
- `/validate-memory --force` -- ignore validated_at window, re-validate everything

Flags can be combined: `/validate-memory --deep --agent pm --force`

## Step 1: Parse arguments, resolve DB

```bash
_gc=$(git rev-parse --git-common-dir 2>/dev/null) \
  && MROOT=$(cd "$(dirname "$_gc")" && pwd) \
  || MROOT=$(pwd)
WTROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
MEMDB="$MROOT/.claude/memory/memory.db"

if [ ! -f "$MEMDB" ] || ! command -v sqlite3 &>/dev/null; then
  echo "Error: memory DB not found at $MEMDB"
  echo "Run /init-team to initialize the database."
  # Stop here (exit 1)
fi
```

Parse flags from arguments:

- `--agent <name>` -- set `TARGET_AGENT=<name>`
- `--deep` -- set `DEEP=true`
- `--force` -- set `FORCE=true`

Guard: check distilling_lock. Validation must not run concurrently with
distillation (they share the same DB rows).

```bash
LOCK=$(sqlite3 "$MEMDB" "SELECT value FROM config WHERE key='distilling_lock';")
if [ -n "$LOCK" ]; then
  echo "Error: distilling_lock is held ($LOCK). Cannot validate while distillation is in progress."
  echo "Wait for distillation to complete, or use /memory-distill --force to clear a stale lock."
  # Stop here (exit 1)
fi
```

Read validation window from config:

```bash
WINDOW_DAYS=$(sqlite3 "$MEMDB" "SELECT value FROM config WHERE key='validate_window_days';")
WINDOW_DAYS="${WINDOW_DAYS:-7}"
```

## Step 2: Query eligible memories

Build the query with optional filters for agent and validated_at window.
Order by `validated_at ASC NULLS FIRST` so never-validated entries are processed
first (SHOULD requirement: focus effort on never-validated entries).

```bash
WINDOW_CLAUSE=""
if [ "$FORCE" != "true" ]; then
  WINDOW_CLAUSE="AND (validated_at IS NULL OR validated_at < strftime('%Y-%m-%dT%H:%M:%SZ', 'now', '-$WINDOW_DAYS days'))"
fi

AGENT_CLAUSE=""
if [ -n "$TARGET_AGENT" ]; then
  AGENT_CLAUSE="AND agent='$TARGET_AGENT'"
fi

MEMORIES=$(sqlite3 "$MEMDB" "
  SELECT id, agent, content, tier, type, distilled_from, created_at
  FROM memories
  WHERE archived=FALSE $AGENT_CLAUSE $WINDOW_CLAUSE
  ORDER BY validated_at ASC NULLS FIRST, created_at ASC;
")
```

If zero eligible memories, report and exit:

```bash
if [ -z "$MEMORIES" ]; then
  echo "TLDR: all memories validated within the last $WINDOW_DAYS days. Nothing to do. Use --force to re-validate."
  # Stop here (exit 0)
fi
```

## Step 3: Extract code references via pattern matching

For each memory, scan its content for checkable code references:

- **File paths**: strings ending in recognized code extensions (`.go`, `.md`,
  `.sh`, `.yaml`, `.yml`, `.json`, `.ts`, `.tsx`, `.js`, `.jsx`, `.py`, `.rs`,
  `.sql`, `.toml`, `.cfg`, `.ini`)
- **Symbol patterns**: `func <name>`, `class <name>`, `def <name>`,
  `function <name>`, `type <name> struct`
- **Line references**: `L<N>`, `:<N>` (line number notation)

```bash
# Extract file paths (words containing / and ending in code extension)
FILE_REFS=$(echo "$CONTENT" | grep -oE '[a-zA-Z0-9_./-]+\.(go|md|sh|yaml|yml|json|ts|tsx|js|jsx|py|rs|sql|toml|cfg|ini)\b')

# Extract symbol names
SYMBOL_REFS=$(echo "$CONTENT" | grep -oE '(func|class|def|function|type)\s+[A-Za-z_][A-Za-z0-9_]*')

# Extract line references
LINE_REFS=$(echo "$CONTENT" | grep -oE '(L[0-9]+|:[0-9]+)')
```

**Skip memories that match NONE of these patterns.** They have no checkable
ground truth (e.g., process decisions, domain knowledge without code anchors).
Do NOT set `validated_at` on skipped entries -- they are simply not subject to
code-reference validation.

## Step 4: Compute confidence scores (staleness probability 0-100)

For each memory with at least one code reference, compute a composite staleness
score. Higher score = more likely stale.

| Signal | Weight | How to check | Points |
|--------|--------|--------------|--------|
| File existence | High | `test -f "$WTROOT/<path>"` | 0 (exists) or 40 (missing) |
| Symbol existence | High | `grep -r "<symbol>" "$WTROOT"` in codebase | 0 (found) or 30 (missing) |
| Line content match | Medium | Read line N from file, fuzzy compare | 0-20 scaled |
| Memory age | Low | Days since `created_at`, scaled | 0-5 scaled |
| Tier bias | Slight | Tier-2 gets benefit of doubt | -5 for tier-2 |

```bash
SCORE=0

# --- File existence (0 or 40 pts per missing file) ---
# Skip bare filenames with no path separator (e.g., "main.go" without a
# directory -- too ambiguous to resolve).
# Also capture the first existing file path for line-content matching later.
NEAREST_FILE=""
for FILE_PATH in $FILE_REFS; do
  if [[ "$FILE_PATH" == */* ]]; then
    if [ -f "$WTROOT/$FILE_PATH" ]; then
      [ -z "$NEAREST_FILE" ] && NEAREST_FILE="$FILE_PATH"
    else
      SCORE=$((SCORE + 40))
      STALE_SIGNAL="file missing: $FILE_PATH"
      break  # One dead file is enough evidence
    fi
  fi
done

# --- Symbol existence (0 or 30 pts per missing symbol) ---
for SYM in $SYMBOL_REFS; do
  SYM_NAME=$(echo "$SYM" | awk '{print $2}')
  if ! grep -rqF -- "$SYM_NAME" "$WTROOT" --include='*.go' --include='*.py' \
       --include='*.ts' --include='*.js' --include='*.sh' --include='*.rs' \
       2>/dev/null; then
    SCORE=$((SCORE + 30))
    STALE_SIGNAL="${STALE_SIGNAL:+$STALE_SIGNAL; }symbol missing: $SYM_NAME"
    break  # One dead symbol is enough
  fi
done

# --- Line content match (0-20 pts) ---
# For each line reference paired with the nearest valid file, read the line
# and check if it exists. If the file exists but line is out of range,
# add up to 20 points.
for LINE_REF in $LINE_REFS; do
  LINE_NUM=$(echo "$LINE_REF" | tr -d 'L:')
  if [ -n "$NEAREST_FILE" ] && [ -f "$WTROOT/$NEAREST_FILE" ]; then
    ACTUAL_LINE=$(sed -n "${LINE_NUM}p" "$WTROOT/$NEAREST_FILE" 2>/dev/null)
    if [ -z "$ACTUAL_LINE" ]; then
      SCORE=$((SCORE + 20))
      STALE_SIGNAL="${STALE_SIGNAL:+$STALE_SIGNAL; }line $LINE_NUM out of range in $NEAREST_FILE"
    fi
    break  # Check one line reference
  fi
done

# --- Memory age (0-5 pts) ---
# Scale: 0 pts for <30 days, 5 pts for >180 days
CREATED_EPOCH=$(date -d "$CREATED_AT" +%s 2>/dev/null || date -j -f '%Y-%m-%dT%H:%M:%SZ' "$CREATED_AT" +%s 2>/dev/null)
NOW_EPOCH=$(date +%s)
AGE_DAYS=$(( (NOW_EPOCH - CREATED_EPOCH) / 86400 ))
if [ "$AGE_DAYS" -gt 180 ]; then
  SCORE=$((SCORE + 5))
elif [ "$AGE_DAYS" -gt 30 ]; then
  SCORE=$((SCORE + (AGE_DAYS - 30) * 5 / 150))
fi

# --- Tier bias (-5 pts for tier-2) ---
if [ "$TIER" = "2" ]; then
  SCORE=$((SCORE - 5))
fi

# --- Clamp to 0-100 ---
[ "$SCORE" -lt 0 ] && SCORE=0
[ "$SCORE" -gt 100 ] && SCORE=100
```

## Step 5: Triage by threshold

Four buckets based on staleness confidence score:

- **0** (zero): Clean pass. All code references verified valid. Set `validated_at`
  and log action `'pass'`. This enables idempotency — next run skips these.
- **1-39**: Non-blocking flagged list to user. Some ambiguity detected but low
  confidence of staleness. Command does NOT wait for user input. `validated_at`
  is NOT set — these entries resurface until the user acts or code changes.
- **40-80** (inclusive both ends): Route to tech-lead reviewer agent for
  confirmation before acting. Score of exactly 80 goes to reviewer, NOT auto-archive.
- **>80** (strictly greater than): Auto-archive. High confidence the memory is
  stale.

Collect memories into four arrays: `CLEAN_PASS`, `FLAG_USER`, `REVIEW`, `AUTO_ARCHIVE`.

**validated_at contract:**

| Outcome | validated_at set? | Why |
|---------|-------------------|-----|
| Clean pass (score 0) | Yes | All refs valid, enables idempotency |
| Auto-archive (>80) | No | Archived, no longer active |
| Reviewer: ARCHIVE | No | Archived, no longer active |
| Reviewer: REWRITE | Yes | Content updated, now fresh |
| Reviewer: KEEP | Yes | Confirmed still valid |
| User-flagged (1-39) | No | Awaiting user decision |
| Skipped (no code refs) | No | Not subject to validation |

### Clean pass (score = 0)

For memories where all code references checked out (score 0 after all signals),
mark as validated immediately:

```bash
sqlite3 "$MEMDB" "PRAGMA busy_timeout=5000;
  UPDATE memories SET validated_at=strftime('%Y-%m-%dT%H:%M:%SZ','now')
  WHERE id=$MEM_ID;
  INSERT INTO validation_log(memory_id, agent, action, confidence, reason)
  VALUES ($MEM_ID, '$MEM_AGENT', 'pass', 0, 'all references valid');"
```

These entries will be skipped on the next run (within the `validate_window_days`
window), ensuring idempotency.

## Step 6: Auto-archive high-confidence stale entries (score > 80)

For each memory with score strictly greater than 80:

```bash
ESCAPED_REASON=$(printf '%s' "$STALE_SIGNAL" | sed "s/'/''/g")
sqlite3 "$MEMDB" "PRAGMA busy_timeout=5000;
  UPDATE memories SET archived=TRUE, archive_reason='stale'
  WHERE id=$MEM_ID;
  INSERT INTO validation_log(memory_id, agent, action, confidence, reason)
  VALUES ($MEM_ID, '$MEM_AGENT', 'archive', $SCORE, '$ESCAPED_REASON');"
```

Do NOT set `validated_at` on archived entries (spec: MUST NOT set validated_at
on archived memories).

Log each auto-archive action for the TLDR summary.

## Step 7: Reviewer pipeline (score 40-80)

Spawn the tech-lead agent (Opus model, per SPEC-003) as a reviewer for entries
in the 40-80 score range. Batch up to 20 entries per call, max 5 batches per
run. Any remainder beyond 5 batches (100 entries) overflows to the user-flagged
list.

For each batch, provide the reviewer with:

- Memory ID
- Content (first 200 chars)
- Stale signal (what reference failed)
- Confidence score
- Current codebase state (what exists at the referenced path/symbol now)

Ask the reviewer for a structured response per entry, one of:
- `ARCHIVE` -- memory is stale, archive it
- `REWRITE: <new content>` -- memory can be salvaged with updated content
- `KEEP` -- memory is still valid, mark as validated

Process reviewer responses:

### On ARCHIVE

Same as Step 6: set `archived=TRUE`, `archive_reason='stale'`. Log to
`validation_log` with action `'archive'`. Do NOT set `validated_at`.

```bash
sqlite3 "$MEMDB" "PRAGMA busy_timeout=5000;
  UPDATE memories SET archived=TRUE, archive_reason='stale'
  WHERE id=$MEM_ID;
  INSERT INTO validation_log(memory_id, agent, action, confidence, reason)
  VALUES ($MEM_ID, '$MEM_AGENT', 'archive', $SCORE, 'reviewer-confirmed: archive');"
```

### On REWRITE

UPDATE the memory content in-place. Preserve original `tier`, `type`, and
`distilled_from`. Append `[validated: YYYY-MM-DD]` tag to the new content.
If existing `[validated: ...]` tag is present, replace it (no duplicates).
Set `validated_at` to now.

```bash
TODAY=$(date -u +%Y-%m-%d)
# Remove existing [validated: ...] tag if present, then append new one
NEW_CONTENT=$(echo "$REWRITE_CONTENT" | sed 's/\[validated: [0-9-]*\]//g')
NEW_CONTENT=$(printf '%s\n\n[validated: %s]' "$NEW_CONTENT" "$TODAY")

ESCAPED_CONTENT=$(printf '%s' "$NEW_CONTENT" | sed "s/'/''/g")
sqlite3 "$MEMDB" "PRAGMA busy_timeout=5000;
  UPDATE memories SET content='$ESCAPED_CONTENT',
    validated_at=strftime('%Y-%m-%dT%H:%M:%SZ','now')
  WHERE id=$MEM_ID;
  INSERT INTO validation_log(memory_id, agent, action, confidence, reason)
  VALUES ($MEM_ID, '$MEM_AGENT', 'rewrite', $SCORE, 'reviewer: rewrite');"
```

Note: the rewrite SQL is executed by this command script (the host), not by the
reviewer agent directly. The reviewer only returns the decision and new content.

### On KEEP

Mark as validated (set `validated_at`). Log with action `'pass'`.

```bash
sqlite3 "$MEMDB" "PRAGMA busy_timeout=5000;
  UPDATE memories SET validated_at=strftime('%Y-%m-%dT%H:%M:%SZ','now')
  WHERE id=$MEM_ID;
  INSERT INTO validation_log(memory_id, agent, action, confidence, reason)
  VALUES ($MEM_ID, '$MEM_AGENT', 'pass', $SCORE, 'reviewer: keep');"
```

## Step 8: Surface low-confidence entries to user (score < 40)

Print a flagged list for the user. Each entry shows:

- Memory ID
- First 80 chars of content
- Stale signal (what reference was checked)
- Confidence score
- Recommended action

```bash
echo "FLAGGED FOR REVIEW (score < 40, non-blocking):"
echo "  ID: $MEM_ID | Score: $SCORE"
echo "  Content: $(echo "$CONTENT" | head -c 80)..."
echo "  Signal: $STALE_SIGNAL"
echo "  Recommended: keep (low staleness confidence)"
echo ""
```

Do NOT set `validated_at` on these entries (spec: MUST NOT set validated_at on
user-flagged memories).

Log to `validation_log` with action `'flag_user'`:

```bash
ESCAPED_REASON=$(printf '%s' "$STALE_SIGNAL" | sed "s/'/''/g")
sqlite3 "$MEMDB" "PRAGMA busy_timeout=5000;
  INSERT INTO validation_log(memory_id, agent, action, confidence, reason)
  VALUES ($MEM_ID, '$MEM_AGENT', 'flag_user', $SCORE, '$ESCAPED_REASON');"
```

## Step 9: Deep mode (--deep flag only)

Runs only when `--deep` is set. Executes AFTER standard validation completes
(Steps 2-9). Deep mode checks whether tier-1 digests have become unreliable
because too many of their source memories were archived as stale.

> **IMPORTANT: Circularity guard.** When `/memory-distill` calls
> `/validate-memory` as a pre-distill step (Task 5), it MUST NOT pass `--deep`.
> Deep mode invokes the @distiller agent, which would create a circular
> dependency. The caller (memory-distill) is responsible for omitting `--deep`.
> This command does not enforce the guard itself.

### Step 9.1: Query tier-1 digests

```bash
DIGESTS=$(sqlite3 "$MEMDB" "
  SELECT id, agent, distilled_from
  FROM memories
  WHERE tier=1 AND archived=FALSE $AGENT_CLAUSE
  ORDER BY created_at ASC;
")
```

### Step 9.2: Check source staleness ratio

For each digest, parse the `distilled_from` JSON array of source memory IDs.
Count how many sources have `archive_reason='stale'`.

```bash
# Parse distilled_from JSON array (e.g., '[1,2,3]')
SOURCE_IDS=$(echo "$DISTILLED_FROM" | tr -d '[]' | tr ',' ' ')
TOTAL_SOURCES=$(echo "$SOURCE_IDS" | wc -w)

# Count stale sources
SOURCE_IDS_CSV=$(echo "$SOURCE_IDS" | tr ' ' ',')
STALE_COUNT=$(sqlite3 "$MEMDB" "
  SELECT COUNT(*) FROM memories
  WHERE id IN ($SOURCE_IDS_CSV) AND archive_reason='stale';
")
```

### Step 9.3: Flag digests for rebuild

If more than 50% of sources are stale, flag the digest for rebuild. The 50%
threshold is fixed for v1. Use cross-multiplication to avoid bash integer
division truncation:

```bash
if [ "$TOTAL_SOURCES" -eq 0 ]; then
  continue  # skip digests with no source references
fi
if [ $((STALE_COUNT * 2)) -gt "$TOTAL_SOURCES" ]; then
  # More than 50% of sources are stale — flag for rebuild
fi
```

### Step 9.4: Check distiller lock before rebuilding

```bash
LOCK=$(sqlite3 "$MEMDB" "SELECT value FROM config WHERE key='distilling_lock';")
if [ -n "$LOCK" ]; then
  echo "Error: distiller lock held ($LOCK). Cannot rebuild digests. Try again later."
  # Report all flagged digests as skipped, do NOT archive them
  DEEP_SKIPPED=$FLAGGED_COUNT
  # Skip to Step 10.6 reporting
fi
```

Do NOT archive digests if the lock is held. Exit deep mode with an error in
this case.

### Step 9.5: Rebuild flagged digests

For each flagged digest:

1. Archive the stale digest:
   ```bash
   sqlite3 "$MEMDB" "PRAGMA busy_timeout=5000;
     UPDATE memories SET archived=TRUE, archive_reason='stale'
     WHERE id=$DIGEST_ID;"
   ```

2. Collect the remaining valid source IDs (those NOT archived as stale).
   Include `archive_reason='distilled'` sources — they were valid at
   distillation time and their content is still usable for re-distillation:
   ```bash
   VALID_IDS=$(sqlite3 "$MEMDB" "
     SELECT id FROM memories
     WHERE id IN ($SOURCE_IDS_CSV)
       AND (archive_reason IS NULL OR archive_reason='distilled')
     ORDER BY created_at ASC;
   ")
   ```

3. Invoke the @distiller agent to re-distill the valid sources into a new
   digest. The distiller reads the source memories and produces a replacement
   tier-1 entry.

### Step 9.6: Report deep mode results

```bash
echo "@$DIGEST_AGENT: $DIGESTS_CHECKED digests checked, $DEEP_REBUILT rebuilt, $DEEP_ARCHIVED archived, $DEEP_SKIPPED skipped (locked)"
```

One line per agent processed in deep mode.

## Step 10: Print TLDR summary

Output the TLDR block FIRST (one line per agent), then detailed per-entry
reasoning below.

```
TLDR: @<agent>: N checked, M archived, K rewritten, J flagged for review
```

Example output:

```
TLDR: @pm: 12 checked, 3 archived, 1 rewritten, 2 flagged for review
TLDR: @tech-lead: 8 checked, 0 archived, 0 rewritten, 1 flagged for review

DETAIL:
  [id=42] "Cache uses sharded LRU with per-shard lo..." | signal: file missing: internal/cache/lru.go | score: 85 | action: archived
  [id=55] "API handler validates JWT in middleware/a..." | signal: symbol missing: ValidateJWT | score: 60 | action: rewrite (reviewer)
  [id=71] "Config loader reads from configs/base.ya..." | signal: age >180 days | score: 5 | action: flagged for user
```

Each detail line includes:
- Memory ID
- First 80 chars of content
- Stale signal (or "none" if all refs checked out)
- Confidence score
- Action taken
