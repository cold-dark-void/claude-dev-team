---
name: validate-memory
description: Cross-reference agent memories against the live codebase; --reconcile detects cross-agent contradictions
argument-hint: "[--agent <name>] [--deep] [--force] [--reconcile] [--report-only]"
agent: build
---

# /validate-memory

Cross-reference agent memories against the live codebase to detect and resolve
stale references — dead files, renamed functions, shifted line numbers,
outdated factual claims. Uses LLM-based per-claim extraction and two-tier
verification (bash for structural refs, LLM investigator for semantic claims)
with confidence scoring: validator proposes, tech-lead reviewer confirms,
user decides ambiguous cases.

With `--reconcile`, instead detect **cross-agent contradictions** (memories vs
memories): bounded candidate pairs → LLM pair-judge → interactive or
`--report-only` resolution. Never auto-archives contradictions.

## Arguments

- `/validate-memory` -- validate all agents' memories
- `/validate-memory --agent <name>` -- validate only one agent's memories
- `/validate-memory --deep` -- also rebuild digests whose sources have gone stale
- `/validate-memory --force` -- ignore validated_at window, re-validate everything
- `/validate-memory --reconcile` -- cross-agent contradiction pass (Steps R1–R4)
- `/validate-memory --reconcile --report-only` -- list contradictions; **zero DB writes**

Flags can be combined: `/validate-memory --deep --agent pm --force`

**Mutual exclusion:** `--deep` and `--reconcile` MUST NOT be combined — error exit.

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
- `--reconcile` -- set `RECONCILE=true`
- `--report-only` -- set `REPORT_ONLY=true` (only meaningful with `--reconcile`)

```bash
# After flag parse — mutual exclusion
if [ "$RECONCILE" = "true" ] && [ "$DEEP" = "true" ]; then
  echo "Error: --deep and --reconcile cannot be combined."
  # Stop here (exit 1)
fi
if [ "$REPORT_ONLY" = "true" ] && [ "$RECONCILE" != "true" ]; then
  echo "Error: --report-only requires --reconcile."
  # Stop here (exit 1)
fi
```

Guard: check distilling_lock. Validation must not run concurrently with
distillation (they share the same DB rows). Same guard for `--reconcile`.

```bash
_gc=$(git rev-parse --git-common-dir 2>/dev/null) \
  && MROOT=$(cd "$(dirname "$_gc")" && pwd) \
  || MROOT=$(pwd)
WTROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
MEMDB="$MROOT/.claude/memory/memory.db"
LOCK=$(sqlite3 "$MEMDB" "SELECT value FROM config WHERE key='distilling_lock';")
if [ -n "$LOCK" ]; then
  echo "Error: distilling_lock is held ($LOCK). Cannot validate while distillation is in progress."
  echo "Wait for distillation to complete, or use /memory-distill --force to clear a stale lock."
  # Stop here (exit 1)
fi
```

If `RECONCILE=true`, skip the codebase-validation pipeline (Steps 2–11) and
branch to **Steps R1–R4** below. Otherwise continue with the standard path.

Read validation window from config (standard path only):

```bash
_gc=$(git rev-parse --git-common-dir 2>/dev/null) \
  && MROOT=$(cd "$(dirname "$_gc")" && pwd) \
  || MROOT=$(pwd)
WTROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
MEMDB="$MROOT/.claude/memory/memory.db"
WINDOW_DAYS=$(sqlite3 "$MEMDB" "SELECT value FROM config WHERE key='validate_window_days';")
WINDOW_DAYS="${WINDOW_DAYS:-7}"
```

## Step 2: Query eligible memories

Build the query with optional filters for agent and validated_at window.
Order by `validated_at ASC NULLS FIRST` so never-validated entries are processed
first (SHOULD requirement: focus effort on never-validated entries).

```bash
_gc=$(git rev-parse --git-common-dir 2>/dev/null) \
  && MROOT=$(cd "$(dirname "$_gc")" && pwd) \
  || MROOT=$(pwd)
WTROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
MEMDB="$MROOT/.claude/memory/memory.db"
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
if [ -z "$MEMORIES" ]; then  # lint-ok: C1
  echo "TLDR: all memories validated within the last $WINDOW_DAYS days. Nothing to do. Use --force to re-validate."  # lint-ok: C1
  # Stop here (exit 0)
fi
```

## Step 3: Extract checkable claims via LLM

For each memory, use an LLM claim extractor to identify concrete, checkable
assertions about the codebase. This replaces the previous regex-based
extraction with semantic claim understanding.

Read the claim extractor prompt template from
`skills/validate-memory/SKILL.md` section "Claim Extractor Prompt Template".

### Step 3.1: Batch memories for extraction

Collect all eligible memories from Step 2 into batches, sized per the
"Claim extraction" row of `skills/validate-memory/SKILL.md` section "Batching
Limits". For each memory, prepare a JSON object:

```json
{
  "id": "<MEM_ID>",
  "agent": "<MEM_AGENT>",
  "content": "<CONTENT>",
  "tier": "<TIER>",
  "type": "<TYPE>",
  "created_at": "<CREATED_AT>"
}
```

To enforce that run cap, add `LIMIT 100` to the Step 2 SQL query (the SQL-LIMIT
overflow handling named in the Batching Limits table). Memories beyond this
limit remain unvalidated and will be picked up on the next run (they keep
`validated_at IS NULL` and retain highest processing priority).

### Step 3.2: Spawn claim extractors

For each batch, substitute `{{MEMORY_BATCH}}` in the claim extractor prompt
with the JSON array of memories, and spawn a Task subagent
(`subagent_type: "general-purpose"`).

Spawn all extraction batches in parallel (all Task calls in one tool-use
block).

### Step 3.3: Validate extraction results

For each returned result, enforce all six rules in `skills/validate-memory/SKILL.md`
section "Claim Extractor Prompt Template" → "Validation rules (command-enforced)".
That includes the "Maximum 8 claims per memory" cap (rule 6): truncate extractions
that exceed it. The `claim_type` values it references are the six terms in the
"Claim Type Taxonomy" section.

Memories with malformed extraction results go to FLAG_USER with score 30 and
reason "claim extraction failed".

### Step 3.4: Partition memories

After extraction, partition memories into:

- **Has claims**: proceed to Step 4
- **No claims (skip_reason set)**: skip entirely, do NOT set `validated_at`
- **Extraction failed**: add to FLAG_USER bucket with score 30

Also partition claims by type for Step 4:

- **Tier A claims** (`file_reference`, `symbol_reference`): verified by bash
- **Tier B claims** (`line_content`, `behavioral`, `architectural`,
  `configuration`): verified by LLM investigator

## Step 4: Two-tier claim verification

Verify each claim against the live codebase. Tier A (bash, no LLM cost) for
structural references, Tier B (LLM investigator) for semantic claims.

Both tiers produce per-claim verdicts using the same taxonomy — see
`skills/validate-memory/SKILL.md` section "Verdict Taxonomy" for the four
verdicts (`VALID`, `STALE`, `CONTRADICTED`, `AMBIGUOUS`) and their score points.

Each verdict carries a `confidence` score (0-100) and an `evidence` string.

### Step 4a: Tier A verification (bash)

**Path containment guard** — apply to every claim before any file operation.
REF_PATH comes from LLM-extracted claims (untrusted). Canonicalize and reject
paths that escape the project root:

```bash
_gc=$(git rev-parse --git-common-dir 2>/dev/null) \
  && MROOT=$(cd "$(dirname "$_gc")" && pwd) \
  || MROOT=$(pwd)
WTROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
# Resolve the path and verify it stays within WTROOT
# REF_PATH set by surrounding claim loop (session state across fences)
RESOLVED=$(realpath -m "$WTROOT/$REF_PATH" 2>/dev/null \  # lint-ok: C1
  || python3 -c "import os.path; print(os.path.normpath(os.path.join('$WTROOT','$REF_PATH')))")
case "$RESOLVED" in
  "$WTROOT"/*) ;;  # safe — inside project
  *)
    verdict="AMBIGUOUS"; confidence=20
    evidence="path escapes project root, skipped"
    continue
    ;;
esac
```

**realpath portability note**: `realpath` is GNU coreutils; not available on
macOS by default. All `realpath --relative-to` calls below use a fallback:

```bash
_gc=$(git rev-parse --git-common-dir 2>/dev/null) \
  && MROOT=$(cd "$(dirname "$_gc")" && pwd) \
  || MROOT=$(pwd)
WTROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
# Helper: relative path with fallback for macOS
relpath() {
  realpath --relative-to="$WTROOT" "$1" 2>/dev/null \
    || python3 -c "import os.path; print(os.path.relpath('$1','$WTROOT'))"
}
```

For `file_reference` claims (after path containment guard):

```bash
_gc=$(git rev-parse --git-common-dir 2>/dev/null) \
  && MROOT=$(cd "$(dirname "$_gc")" && pwd) \
  || MROOT=$(pwd)
WTROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
for each claim where claim_type == "file_reference":
  REF_PATH="${code_refs[0].path}"
  # ... apply path containment guard above ...
  if [[ "$REF_PATH" == */* ]]; then
    if [ -f "$WTROOT/$REF_PATH" ]; then
      verdict="VALID"; confidence=90
      evidence="file exists at $REF_PATH"
    else
      # Rename detection: glob for basename in nearby directories
      BASENAME=$(basename "$REF_PATH")
      PARENT=$(dirname "$REF_PATH")
      NEARBY=$(find "$WTROOT/$PARENT/.." -name "$BASENAME" -maxdepth 3 2>/dev/null | head -1)
      if [ -n "$NEARBY" ]; then
        verdict="STALE"; confidence=70
        evidence="file moved to $(relpath "$NEARBY")"
      else
        verdict="CONTRADICTED"; confidence=90
        evidence="file not found, no similar file nearby"
      fi
    fi
  else
    # Bare filename with no path separator — too ambiguous
    verdict="AMBIGUOUS"; confidence=30
    evidence="bare filename, cannot resolve without path"
  fi
```

For `symbol_reference` claims (after path containment guard):

```bash
_gc=$(git rev-parse --git-common-dir 2>/dev/null) \
  && MROOT=$(cd "$(dirname "$_gc")" && pwd) \
  || MROOT=$(pwd)
WTROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
for each claim where claim_type == "symbol_reference":
  REF_PATH="${code_refs[0].path}"
  SYM_NAME="${code_refs[0].symbol}"
  # ... apply path containment guard above ...

  if [ -n "$REF_PATH" ] && [ -f "$WTROOT/$REF_PATH" ]; then
    # Check symbol in the SPECIFIC file the memory claims
    if grep -qF "$SYM_NAME" "$WTROOT/$REF_PATH" 2>/dev/null; then
      verdict="VALID"; confidence=85
      evidence="$SYM_NAME found in $REF_PATH"
    else
      # Symbol not in claimed file — check if it exists elsewhere
      FOUND=$(grep -rlF "$SYM_NAME" "$WTROOT" \
        --include='*.go' --include='*.py' --include='*.ts' \
        --include='*.js' --include='*.sh' --include='*.rs' \
        --exclude-dir='.claude' 2>/dev/null | head -1)
      if [ -n "$FOUND" ]; then
        verdict="STALE"; confidence=70
        evidence="$SYM_NAME found in $(relpath "$FOUND"), not in claimed $REF_PATH"
      else
        verdict="CONTRADICTED"; confidence=85
        evidence="$SYM_NAME not found anywhere in codebase"
      fi
    fi
  elif [ -n "$REF_PATH" ] && [ -n "$SYM_NAME" ]; then
    # REF_PATH provided but file deleted — grep globally, verdict is STALE if found
    FOUND=$(grep -rlF "$SYM_NAME" "$WTROOT" \
      --include='*.go' --include='*.py' --include='*.ts' \
      --include='*.js' --include='*.sh' --include='*.rs' \
      --exclude-dir='.claude' 2>/dev/null | head -1)
    if [ -n "$FOUND" ]; then
      verdict="STALE"; confidence=65
      evidence="$SYM_NAME found in $(relpath "$FOUND"), claimed file $REF_PATH deleted"
    else
      verdict="CONTRADICTED"; confidence=80
      evidence="$SYM_NAME not found in codebase, claimed file $REF_PATH deleted"
    fi
  elif [ -n "$SYM_NAME" ]; then
    # No file specified — grep globally
    FOUND=$(grep -rlF "$SYM_NAME" "$WTROOT" \
      --include='*.go' --include='*.py' --include='*.ts' \
      --include='*.js' --include='*.sh' --include='*.rs' \
      --exclude-dir='.claude' 2>/dev/null | head -1)
    if [ -n "$FOUND" ]; then
      verdict="VALID"; confidence=60
      evidence="$SYM_NAME found in $(relpath "$FOUND") (no file specified in memory)"
    else
      verdict="CONTRADICTED"; confidence=80
      evidence="$SYM_NAME not found in codebase"
    fi
  else
    # No symbol name to check — cannot verify
    verdict="AMBIGUOUS"; confidence=30
    evidence="symbol_reference claim has no symbol name to check"
  fi
```

### Step 4b: Tier B verification (LLM investigator)

For `line_content`, `behavioral`, `architectural`, and `configuration` claims.

Read the investigator prompt template from `skills/validate-memory/SKILL.md`
section "Investigator Prompt Template".

1. Collect all Tier B claims from all memories.
2. Batch claims per the "Tier B investigation" row of
   `skills/validate-memory/SKILL.md` section "Batching Limits".
3. For each batch, substitute `{{CLAIMS_TO_VERIFY}}` with the JSON array of
   claims and spawn a Task subagent (`subagent_type: "general-purpose"`).
4. Spawn all investigation batches in parallel.
5. Apply that table's run cap and overflow handling: claims beyond the cap are
   skipped — their parent memories are excluded from scoring and deferred to the
   next run (do NOT set `validated_at`, so they retain highest processing
   priority).

Validate returned verdicts per the rules in `skills/validate-memory/SKILL.md`
section "Investigator Prompt Template" → "Validation rules (command-enforced)".

Claims with no returned verdict (missing from output or malformed) default to
`AMBIGUOUS` with confidence 50.

## Step 5: Composite scoring

For each memory, combine its per-claim verdicts into a single staleness
score (0-100). See `skills/validate-memory/SKILL.md` "Composite Scoring
Formula" for the canonical reference.

```bash
# Per-claim points (weighted by confidence)
BASE_POINTS={"VALID": 0, "STALE": 25, "AMBIGUOUS": 10, "CONTRADICTED": 40}

for each claim verdict:
  weighted_pts = BASE_POINTS[verdict] * (confidence / 100)

# Average across all claims for this memory
raw_score = SUM(weighted_pts) / num_claims

# --- Age modifier (0-5 pts) ---
CREATED_EPOCH=$(date -d "$CREATED_AT" +%s 2>/dev/null || date -j -f '%Y-%m-%dT%H:%M:%SZ' "$CREATED_AT" +%s 2>/dev/null)
NOW_EPOCH=$(date +%s)
AGE_DAYS=$(( (NOW_EPOCH - CREATED_EPOCH) / 86400 ))
if [ "$AGE_DAYS" -gt 180 ]; then
  age_mod=5
elif [ "$AGE_DAYS" -gt 30 ]; then
  age_mod=$(( (AGE_DAYS - 30) * 5 / 150 ))
else
  age_mod=0
fi

# --- Tier modifier ---
tier_mod=0
if [ "$TIER" = "2" ]; then
  tier_mod=-5
fi

# --- Final score ---
SCORE=$(( raw_score + age_mod + tier_mod ))
[ "$SCORE" -lt 0 ] && SCORE=0
[ "$SCORE" -gt 100 ] && SCORE=100
```

For why the score averages across claims (and worked examples), see
`skills/validate-memory/SKILL.md` section "Composite Scoring Formula".

## Step 6: Triage by threshold

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
| Skipped (no checkable claims) | No | Not subject to validation |

### Clean pass (score = 0)

For memories where all claims verified as VALID (score 0 after composite scoring),
mark as validated immediately:

```bash
_gc=$(git rev-parse --git-common-dir 2>/dev/null) \
  && MROOT=$(cd "$(dirname "$_gc")" && pwd) \
  || MROOT=$(pwd)
WTROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
MEMDB="$MROOT/.claude/memory/memory.db"
sqlite3 "$MEMDB" "PRAGMA busy_timeout=5000;
  UPDATE memories SET validated_at=strftime('%Y-%m-%dT%H:%M:%SZ','now')
  WHERE id=$MEM_ID;
  INSERT INTO validation_log(memory_id, agent, action, confidence, reason)
  VALUES ($MEM_ID, '$MEM_AGENT', 'pass', 0, 'all claims verified');"
```

These entries will be skipped on the next run (within the `validate_window_days`
window), ensuring idempotency.

## Step 7: Auto-archive high-confidence stale entries (score > 80)

For each memory with score strictly greater than 80:

Build a reason string summarizing per-claim verdicts for the audit log:

```bash
_gc=$(git rev-parse --git-common-dir 2>/dev/null) \
  && MROOT=$(cd "$(dirname "$_gc")" && pwd) \
  || MROOT=$(pwd)
WTROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
MEMDB="$MROOT/.claude/memory/memory.db"
# Build per-claim summary for audit log
# e.g., "CONTRADICTED(90%): file missing; STALE(70%): symbol moved"
CLAIM_SUMMARY=""
for each claim verdict for this memory:
  CLAIM_SUMMARY="${CLAIM_SUMMARY:+$CLAIM_SUMMARY; }${verdict}(${confidence}%): ${evidence}"  # lint-ok: C1

ESCAPED_REASON=$(printf '%s' "$CLAIM_SUMMARY" | sed "s/'/''/g")
sqlite3 "$MEMDB" "PRAGMA busy_timeout=5000;
  UPDATE memories SET archived=TRUE, archive_reason='stale'
  WHERE id=$MEM_ID;
  INSERT INTO validation_log(memory_id, agent, action, confidence, reason)
  VALUES ($MEM_ID, '$MEM_AGENT', 'archive', $SCORE, '$ESCAPED_REASON');"
```

Do NOT set `validated_at` on archived entries (spec: MUST NOT set validated_at
on archived memories).

Log each auto-archive action for the TLDR summary.

## Step 8: Reviewer pipeline (score 40-80)

Spawn the tech-lead agent (Opus model, per SPEC-003) as a reviewer for entries
in the 40-80 score range. Batch up to 20 entries per call, max 5 batches per
run. Any remainder beyond 5 batches (100 entries) overflows to the user-flagged
list.

For each batch, provide the reviewer with:

- Memory ID
- Content (first 200 chars)
- **Per-claim verdicts with evidence** (each claim's verdict, confidence, and
  evidence string from Step 4)
- **Composite score breakdown** (which claims drove the score up)
- Current codebase state for CONTRADICTED/STALE claims
- **Recommended action**: `archive` if score >= 60, `keep` if score < 60
  (the reviewer may override this recommendation)

Before sending to the reviewer, log each entry as routed to review:

```bash
_gc=$(git rev-parse --git-common-dir 2>/dev/null) \
  && MROOT=$(cd "$(dirname "$_gc")" && pwd) \
  || MROOT=$(pwd)
WTROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
MEMDB="$MROOT/.claude/memory/memory.db"
ESCAPED_REASON=$(printf '%s' "$CLAIM_SUMMARY" | sed "s/'/''/g")  # lint-ok: C1
sqlite3 "$MEMDB" "PRAGMA busy_timeout=5000;
  INSERT INTO validation_log(memory_id, agent, action, confidence, reason)
  VALUES ($MEM_ID, '$MEM_AGENT', 'flag_review', $SCORE, '$ESCAPED_REASON');"
```

Ask the reviewer for a structured response per entry, one of:
- `ARCHIVE` -- memory is stale, archive it
- `REWRITE: <new content>` -- memory can be salvaged with updated content
- `KEEP` -- memory is still valid, mark as validated

Process reviewer responses:

### On ARCHIVE

Same as Step 7: set `archived=TRUE`, `archive_reason='stale'`. Log to
`validation_log` with action `'archive'`. Do NOT set `validated_at`.

```bash
_gc=$(git rev-parse --git-common-dir 2>/dev/null) \
  && MROOT=$(cd "$(dirname "$_gc")" && pwd) \
  || MROOT=$(pwd)
WTROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
MEMDB="$MROOT/.claude/memory/memory.db"
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
_gc=$(git rev-parse --git-common-dir 2>/dev/null) \
  && MROOT=$(cd "$(dirname "$_gc")" && pwd) \
  || MROOT=$(pwd)
WTROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
MEMDB="$MROOT/.claude/memory/memory.db"
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
_gc=$(git rev-parse --git-common-dir 2>/dev/null) \
  && MROOT=$(cd "$(dirname "$_gc")" && pwd) \
  || MROOT=$(pwd)
WTROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
MEMDB="$MROOT/.claude/memory/memory.db"
sqlite3 "$MEMDB" "PRAGMA busy_timeout=5000;
  UPDATE memories SET validated_at=strftime('%Y-%m-%dT%H:%M:%SZ','now')
  WHERE id=$MEM_ID;
  INSERT INTO validation_log(memory_id, agent, action, confidence, reason)
  VALUES ($MEM_ID, '$MEM_AGENT', 'pass', $SCORE, 'reviewer: keep');"
```

## Step 9: Surface low-confidence entries to user (score 1-39)

Print a flagged list for the user. Each entry shows per-claim breakdown:

```
FLAGGED FOR REVIEW (score 1-39, non-blocking):
  ID: $MEM_ID | Score: $SCORE
  Content: <first 80 chars>...
  Claims:
    [VALID  90%] File internal/cache/lru.go exists
    [STALE  70%] Default shard count is 16 — actual: 32 at L70
  Recommended: keep (low staleness confidence)
```

Do NOT set `validated_at` on these entries (spec: MUST NOT set validated_at on
user-flagged memories).

Log to `validation_log` with action `'flag_user'`, including per-claim
verdict summary in reason:

```bash
_gc=$(git rev-parse --git-common-dir 2>/dev/null) \
  && MROOT=$(cd "$(dirname "$_gc")" && pwd) \
  || MROOT=$(pwd)
WTROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
MEMDB="$MROOT/.claude/memory/memory.db"
ESCAPED_REASON=$(printf '%s' "$CLAIM_SUMMARY" | sed "s/'/''/g")  # lint-ok: C1
sqlite3 "$MEMDB" "PRAGMA busy_timeout=5000;
  INSERT INTO validation_log(memory_id, agent, action, confidence, reason)
  VALUES ($MEM_ID, '$MEM_AGENT', 'flag_user', $SCORE, '$ESCAPED_REASON');"
```

## Step 10: Deep mode (--deep flag only)

Runs only when `--deep` is set. Executes AFTER standard validation completes
(Steps 2-9). Deep mode checks whether tier-1 digests have become unreliable
because too many of their source memories were archived as stale.

> **IMPORTANT: Circularity guard.** When `/memory-distill` calls
> `/validate-memory` as a pre-distill step, it MUST NOT pass `--deep`.
> Deep mode invokes the @distiller agent, which would create a circular
> dependency. The caller (memory-distill) is responsible for omitting `--deep`.
> This command does not enforce the guard itself.

### Step 10.1: Query tier-1 digests

```bash
_gc=$(git rev-parse --git-common-dir 2>/dev/null) \
  && MROOT=$(cd "$(dirname "$_gc")" && pwd) \
  || MROOT=$(pwd)
WTROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
MEMDB="$MROOT/.claude/memory/memory.db"
DIGESTS=$(sqlite3 "$MEMDB" "
  SELECT id, agent, distilled_from
  FROM memories
  WHERE tier=1 AND archived=FALSE $AGENT_CLAUSE  # lint-ok: C1
  ORDER BY created_at ASC;
")
```

### Step 10.2: Check source staleness ratio

For each digest, parse the `distilled_from` JSON array of source memory IDs.
Count how many sources have `archive_reason='stale'`.

```bash
_gc=$(git rev-parse --git-common-dir 2>/dev/null) \
  && MROOT=$(cd "$(dirname "$_gc")" && pwd) \
  || MROOT=$(pwd)
WTROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
MEMDB="$MROOT/.claude/memory/memory.db"
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

### Step 10.3: Flag digests for rebuild

If more than 50% of sources are stale, flag the digest for rebuild. The 50%
threshold is fixed for v1. Use cross-multiplication to avoid bash integer
division truncation:

```bash
if [ "$TOTAL_SOURCES" -eq 0 ]; then  # lint-ok: C1
  continue  # skip digests with no source references
fi
if [ $((STALE_COUNT * 2)) -gt "$TOTAL_SOURCES" ]; then
  # More than 50% of sources are stale — flag for rebuild
fi
```

### Step 10.4: Check distiller lock before rebuilding

```bash
_gc=$(git rev-parse --git-common-dir 2>/dev/null) \
  && MROOT=$(cd "$(dirname "$_gc")" && pwd) \
  || MROOT=$(pwd)
WTROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
MEMDB="$MROOT/.claude/memory/memory.db"
LOCK=$(sqlite3 "$MEMDB" "SELECT value FROM config WHERE key='distilling_lock';")
if [ -n "$LOCK" ]; then
  echo "Error: distiller lock held ($LOCK). Cannot rebuild digests. Try again later."
  # Report all flagged digests as skipped, do NOT archive them
  DEEP_SKIPPED=$FLAGGED_COUNT
  # Skip to Step 10.6 deep mode reporting
fi
```

Do NOT archive digests if the lock is held. Exit deep mode with an error in
this case.

### Step 10.5: Rebuild flagged digests

For each flagged digest:

1. Archive the stale digest:
   ```bash
_gc=$(git rev-parse --git-common-dir 2>/dev/null) \
  && MROOT=$(cd "$(dirname "$_gc")" && pwd) \
  || MROOT=$(pwd)
WTROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
MEMDB="$MROOT/.claude/memory/memory.db"
   sqlite3 "$MEMDB" "PRAGMA busy_timeout=5000;
     UPDATE memories SET archived=TRUE, archive_reason='stale'
     WHERE id=$DIGEST_ID;"
   ```

2. Collect the remaining valid source IDs (those NOT archived as stale).
   Include `archive_reason='distilled'` sources — they were valid at
   distillation time and their content is still usable for re-distillation:
   ```bash
_gc=$(git rev-parse --git-common-dir 2>/dev/null) \
  && MROOT=$(cd "$(dirname "$_gc")" && pwd) \
  || MROOT=$(pwd)
WTROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
MEMDB="$MROOT/.claude/memory/memory.db"
   VALID_IDS=$(sqlite3 "$MEMDB" "
     SELECT id FROM memories
     WHERE id IN ($SOURCE_IDS_CSV)  # lint-ok: C1
       AND (archive_reason IS NULL OR archive_reason='distilled')
     ORDER BY created_at ASC;
   ")
   ```

3. Invoke the @distiller agent to re-distill the valid sources into a new
   digest. The distiller reads the source memories and produces a replacement
   tier-1 entry.

### Step 10.6: Report deep mode results

```bash
# DEEP_* counters accumulated across deep-mode steps (session state)
echo "@$DIGEST_AGENT: $DIGESTS_CHECKED digests checked, $DEEP_REBUILT rebuilt, $DEEP_ARCHIVED archived, $DEEP_SKIPPED skipped (locked)"  # lint-ok: C1
```

One line per agent processed in deep mode.

## Step 11: Print TLDR summary

Output the TLDR block FIRST (one line per agent), then detailed per-entry
reasoning with per-claim breakdown below.

```
TLDR: @<agent>: N checked, M archived, K rewritten, J flagged for review
```

Example output:

```
TLDR: @pm: 12 checked, 3 archived, 1 rewritten, 2 flagged for review
TLDR: @tech-lead: 8 checked, 0 archived, 0 rewritten, 1 flagged for review

DETAIL:
  [id=42] "Cache uses sharded LRU with per-shard lo..." | score: 7 | action: flagged
    [VALID  90%] File internal/cache/lru.go exists
    [VALID  95%] ShardedCache has mutex per shard
    [STALE  85%] Default shard count is 16 — actual: 32 at L70
  [id=55] "API handler validates JWT in middleware/a..." | score: 45 | action: rewrite (reviewer)
    [CONTRA 90%] File middleware/auth.go exists — not found
    [CONTRA 85%] ValidateJWT exists in middleware/auth.go — not found anywhere
  [id=71] "Config loader reads from configs/base.ya..." | score: 0 | action: pass
    [VALID  95%] File configs/base.yaml exists
    [VALID  80%] Falls back to env vars — confirmed at config.go:88
  [id=88] "Team standup runs via /standup command" | skipped (no checkable claims)
```

Each detail entry includes:
- Memory ID
- First 80 chars of content
- Composite staleness score
- Action taken
- Indented per-claim lines with 6-char verdict tag (`VALID`, `STALE`,
  `CONTRA`, `AMBIG`), confidence percentage, and evidence summary
- CONTRADICTED and STALE claims include a dash-separated evidence note
- Skipped memories (no checkable claims) show "skipped" with reason

---

# Reconcile path (`--reconcile`)

Runs only when `RECONCILE=true` after Step 1 guards. Skips Steps 2–11
(codebase claim pipeline). Contracts and pair-judge prompt live in
`skills/validate-memory/SKILL.md` (Reconcile Candidate Contract, Pair-Judge
Prompt Template). Host library: `skills/validate-memory/reconcile-lib.sh`.

## Step R1: Candidate pair generation (no LLM)

Resolve plugin root for the lib (worktree-aware; sibling of commands/):

```bash
_gc=$(git rev-parse --git-common-dir 2>/dev/null) \
  && MROOT=$(cd "$(dirname "$_gc")" && pwd) \
  || MROOT=$(pwd)
WTROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
MEMDB="$MROOT/.claude/memory/memory.db"
# Plugin root: prefer WTROOT when it contains the skill; else walk from this
# command file's known install layout.
PLUGIN_ROOT="$WTROOT"
if [ ! -f "$PLUGIN_ROOT/skills/validate-memory/reconcile-lib.sh" ]; then
  # Fallback: installed plugin path from CLAUDE_PLUGIN_ROOT if set
  PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$WTROOT}"
fi
RECONCILE_LIB="$PLUGIN_ROOT/skills/validate-memory/reconcile-lib.sh"
PAIRS_FILE=$(mktemp "${TMPDIR:-/tmp}/reconcile-pairs.XXXXXX")
AGENT_ARGS=()
if [ -n "${TARGET_AGENT:-}" ]; then
  AGENT_ARGS=(--agent "$TARGET_AGENT")
fi
# R1a embed KNN (when vec0+embeddings available) else R1b keyword Jaccard.
# Lib enforces: behavioral agents only, cross-agent, sim/Jaccard thresholds,
# resolved-pair skip, sample ≤200/agent, cap from reconcile_pair_cap.
# stderr carries RECONCILE_META; JSONL goes to --out only
META_FILE=$(mktemp "${TMPDIR:-/tmp}/reconcile-meta.XXXXXX")
bash "$RECONCILE_LIB" candidates "$MEMDB" "${AGENT_ARGS[@]}" --out "$PAIRS_FILE" \
  2>"$META_FILE" >/dev/null || true
META=$(cat "$META_FILE")
rm -f "$META_FILE"
# Parse RECONCILE_META candidates=N cap=K cap_hit=bool method=keyword|embed
CAND_N=$(echo "$META" | sed -n 's/.*candidates=\([0-9]*\).*/\1/p' | tail -1)
CAP_K=$(echo "$META" | sed -n 's/.*cap=\([0-9]*\).*/\1/p' | tail -1)
CAP_HIT=$(echo "$META" | sed -n 's/.*cap_hit=\([^ ]*\).*/\1/p' | tail -1)
METHOD=$(echo "$META" | sed -n 's/.*method=\([^ ]*\).*/\1/p' | tail -1)
```

If `CAND_N` is 0:

```bash
_gc=$(git rev-parse --git-common-dir 2>/dev/null) \
  && MROOT=$(cd "$(dirname "$_gc")" && pwd) \
  || MROOT=$(pwd)
MEMDB="$MROOT/.claude/memory/memory.db"
CAP_K=$(sqlite3 "$MEMDB" "SELECT value FROM config WHERE key='reconcile_pair_cap';" 2>/dev/null || echo "50")
CAP_K="${CAP_K:-50}"
echo "TLDR: reconcile: 0 candidates, 0 judged, 0 contradictory, 0 resolved, 0 skipped, cap=${CAP_K}"
# Stop here (exit 0) — zero writes
```

Path-containment: N/A (no filesystem paths from untrusted claim text in R1).

## Step R2: LLM pair-judge

Read `skills/validate-memory/SKILL.md` section **Pair-Judge Prompt Template**.

1. Load pairs from `$PAIRS_FILE` (JSONL → JSON array).
2. Batch ≤10 pairs per call, max 5 batches (Batching Limits table).
3. For each batch, substitute `{{PAIR_BATCH}}` and spawn Task subagent
   (`subagent_type: "general-purpose"`). Spawn batches in parallel.
4. Validate each batch against "Validation rules (command-enforced)".
5. Malformed batch → every pair in that batch becomes `unrelated` conf 0;
   note in DETAIL: `judge malformed → unrelated`.

Collect all judgements into `JUDGEMENTS` (JSON array).

## Step R3: Partition

- `CONTRADICTORY` — verdict `contradictory` (only these enter resolution)
- `NON_ACTION` — `consistent` | `unrelated` (no resolution prompt, no mutation)

Counters: `J` = judged count, `C` = contradictory count.

## Step R4a: `--report-only` or no contradictions

If `REPORT_ONLY=true` OR `C=0`:

```bash
# Session counters from R1–R3 (agent state across steps — not a prior bash block):
# CAND_N, CAP_K, CAP_HIT, J, C, PAIRS_FILE
HIT_SUFFIX=""
[ "${CAP_HIT:-false}" = "true" ] && HIT_SUFFIX=" HIT"  # lint-ok: C1
echo "TLDR: reconcile: ${CAND_N:-0} candidates, ${J:-0} judged, ${C:-0} contradictory, 0 resolved, 0 skipped, cap=${CAP_K:-50}${HIT_SUFFIX}"  # lint-ok: C1
echo ""
echo "DETAIL:"
# For each judgement: ids, agents, verdict, claim quotes, confidence, rationale
# For contradictory under --report-only: still print evidence; action=report
# MUST NOT: UPDATE memories, INSERT reconcile_log, archive anything
rm -f "${PAIRS_FILE:-}"  # lint-ok: C1
# Stop here (exit 0)
```

**AC7:** Even max-confidence `contradictory` never archives on this path.

## Step R4b: Interactive resolution

For each pair in `CONTRADICTORY`, present:

```
CONTRADICTION [id_a=@agent_a vs id_b=@agent_b] conf=N%
  claim_a: "…"
  claim_b: "…"
  rationale: …
Choose: pick-survivor | merge | both-stale | skip | deep-audit
```

Host applies SQL via `reconcile-lib.sh` (never auto-archive without this choice).
All writes use SPEC-004 `PRAGMA busy_timeout=5000` inside the lib.

### pick-survivor

User picks winner id (other becomes loser):

```bash
_gc=$(git rev-parse --git-common-dir 2>/dev/null) \
  && MROOT=$(cd "$(dirname "$_gc")" && pwd) \
  || MROOT=$(pwd)
WTROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
MEMDB="$MROOT/.claude/memory/memory.db"
PLUGIN_ROOT="$WTROOT"
[ -f "$PLUGIN_ROOT/skills/validate-memory/reconcile-lib.sh" ] || PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$WTROOT}"
RECONCILE_LIB="$PLUGIN_ROOT/skills/validate-memory/reconcile-lib.sh"
bash "$RECONCILE_LIB" resolve-pick "$MEMDB" "$WINNER_ID" "$LOSER_ID" \
  "$AGENT_A" "$AGENT_B" "$CLAIM_A" "$CLAIM_B" "$CONF" "$REASON"
# Archives loser with archive_reason='reconciled'; logs pick-survivor
```

### merge

User supplies merged text (or accepts host-proposed merge of both contents).
Host writes SQL (OQ-5 — judge/user supply text only):

```bash
_gc=$(git rev-parse --git-common-dir 2>/dev/null) \
  && MROOT=$(cd "$(dirname "$_gc")" && pwd) \
  || MROOT=$(pwd)
WTROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
MEMDB="$MROOT/.claude/memory/memory.db"
PLUGIN_ROOT="$WTROOT"
[ -f "$PLUGIN_ROOT/skills/validate-memory/reconcile-lib.sh" ] || PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$WTROOT}"
RECONCILE_LIB="$PLUGIN_ROOT/skills/validate-memory/reconcile-lib.sh"
bash "$RECONCILE_LIB" resolve-merge "$MEMDB" "$WINNER_ID" "$LOSER_ID" \
  "$AGENT_A" "$AGENT_B" "$CLAIM_A" "$CLAIM_B" "$CONF" "$MERGED_CONTENT" "$REASON"
# UPDATE winner content (preserve tier/type/distilled_from); tag [reconciled: YYYY-MM-DD];
# archive loser reconciled
```

### both-stale

```bash
_gc=$(git rev-parse --git-common-dir 2>/dev/null) \
  && MROOT=$(cd "$(dirname "$_gc")" && pwd) \
  || MROOT=$(pwd)
WTROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
MEMDB="$MROOT/.claude/memory/memory.db"
PLUGIN_ROOT="$WTROOT"
[ -f "$PLUGIN_ROOT/skills/validate-memory/reconcile-lib.sh" ] || PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$WTROOT}"
RECONCILE_LIB="$PLUGIN_ROOT/skills/validate-memory/reconcile-lib.sh"
bash "$RECONCILE_LIB" resolve-both-stale "$MEMDB" "$ID_A" "$ID_B" \
  "$AGENT_A" "$AGENT_B" "$CLAIM_A" "$CLAIM_B" "$CONF" "$REASON"
```

### skip

```bash
_gc=$(git rev-parse --git-common-dir 2>/dev/null) \
  && MROOT=$(cd "$(dirname "$_gc")" && pwd) \
  || MROOT=$(pwd)
WTROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
MEMDB="$MROOT/.claude/memory/memory.db"
PLUGIN_ROOT="$WTROOT"
[ -f "$PLUGIN_ROOT/skills/validate-memory/reconcile-lib.sh" ] || PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$WTROOT}"
RECONCILE_LIB="$PLUGIN_ROOT/skills/validate-memory/reconcile-lib.sh"
bash "$RECONCILE_LIB" resolve-skip "$MEMDB" "$ID_A" "$ID_B" \
  "$AGENT_A" "$AGENT_B" "$CLAIM_A" "$CLAIM_B" "$CONF" "$REASON"
# Log only — pair may reappear on a later run (skip is not a resolved action)
```

### deep-audit

```bash
_gc=$(git rev-parse --git-common-dir 2>/dev/null) \
  && MROOT=$(cd "$(dirname "$_gc")" && pwd) \
  || MROOT=$(pwd)
WTROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
MEMDB="$MROOT/.claude/memory/memory.db"
PLUGIN_ROOT="$WTROOT"
[ -f "$PLUGIN_ROOT/skills/validate-memory/reconcile-lib.sh" ] || PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$WTROOT}"
RECONCILE_LIB="$PLUGIN_ROOT/skills/validate-memory/reconcile-lib.sh"
bash "$RECONCILE_LIB" resolve-deep-audit "$MEMDB" "$ID_A" "$ID_B" \
  "$AGENT_A" "$AGENT_B" "$CLAIM_A" "$CLAIM_B" "$CONF" "$REASON"
# Prints: /council "claim_a vs claim_b"
# MUST NOT spawn tribunal phases (SPEC-013 owns that surface)
```

Track `R` (resolved = pick-survivor|merge|both-stale) and `S` (skip + deep-audit).

### Final TLDR

```bash
# Session counters from R1–R4b (agent state): CAND_N CAP_K CAP_HIT J C R S PAIRS_FILE
HIT_SUFFIX=""
[ "${CAP_HIT:-false}" = "true" ] && HIT_SUFFIX=" HIT"  # lint-ok: C1
echo "TLDR: reconcile: ${CAND_N:-0} candidates, ${J:-0} judged, ${C:-0} contradictory, ${R:-0} resolved, ${S:-0} skipped, cap=${CAP_K:-50}${HIT_SUFFIX}"  # lint-ok: C1
echo ""
echo "DETAIL:"
# Per pair: ids, agents, verdict, quotes, action taken
rm -f "${PAIRS_FILE:-}"  # lint-ok: C1
```
