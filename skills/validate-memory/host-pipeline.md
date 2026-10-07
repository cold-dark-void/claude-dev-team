# validate

Cross-reference agent memories against the live codebase; `--reconcile`
detects cross-agent contradictions.

**Skill-delegate:** prompt templates, claim/verdict taxonomies, composite scoring,
batching limits, and pair-judge contracts live in `skills/validate-memory/SKILL.md` —
load those sections when steps below reference them. The host pipeline (steps below)
is the absorbed behavior from the former `/validate-memory` command.

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

- `/memory validate` -- validate all agents' memories
- `/memory validate --agent <name>` -- validate only one agent's memories
- `/memory validate --deep` -- also rebuild digests whose sources have gone stale
- `/memory validate --force` -- ignore validated_at window, re-validate everything
- `/memory validate --reconcile` -- cross-agent contradiction pass (Steps R1–R4)
- `/memory validate --reconcile --report-only` -- list contradictions; **zero DB writes**

Flags can be combined: `/memory validate --deep --agent pm --force`

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
  echo "Run /setup team to initialize the database."
  # Stop here (exit 1)
  exit 1
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
  exit 1
fi
if [ "$REPORT_ONLY" = "true" ] && [ "$RECONCILE" != "true" ]; then
  echo "Error: --report-only requires --reconcile."
  # Stop here (exit 1)
  exit 1
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
# LOCK_OWNER is the distill token when validate runs inside Step 4.5.
# A fresh foreign lock exits 1. The owner, an empty lock, and a stale lock pass.
bash skills/memory-store/distill-lock.sh guard "$MEMDB" "${LOCK_OWNER:-}" || exit $?
```

If `RECONCILE=true`, skip the codebase-validation pipeline (Steps 2–11).
Read `skills/validate-memory/reconcile-host.md` and follow Steps R1–R4.
The Step 1 guards above still apply. Otherwise continue with the standard path.

Read validation window from config (standard path only):

```bash
_gc=$(git rev-parse --git-common-dir 2>/dev/null) \
  && MROOT=$(cd "$(dirname "$_gc")" && pwd) \
  || MROOT=$(pwd)
WTROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
MEMDB="$MROOT/.claude/memory/memory.db"
WINDOW_DAYS=$(sqlite3 -cmd ".timeout 5000" "$MEMDB" "SELECT value FROM config WHERE key='validate_window_days';")
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
  case "$TARGET_AGENT" in
    pm|tech-lead|ic5|ic4|devops|qa|ds) ;;
    *) echo "Error: --agent must match the roster" >&2; exit 64 ;;
  esac
  bash skills/lib/require-agent.sh "$TARGET_AGENT"
  AGENT_CLAUSE="AND agent='$TARGET_AGENT'"
fi

MEMORIES=$(sqlite3 -cmd ".timeout 5000" "$MEMDB" "
  SELECT id, agent, content, tier, type, distilled_from, created_at
  FROM memories
  WHERE archived=FALSE $AGENT_CLAUSE $WINDOW_CLAUSE
  ORDER BY validated_at ASC NULLS FIRST, created_at ASC
  LIMIT 100;
")
```

If zero eligible memories, report and exit:

```bash
if [ -z "$MEMORIES" ]; then  # lint-ok: C1
  echo "TLDR: all memories validated within the last $WINDOW_DAYS days. Nothing to do. Use --force to re-validate."  # lint-ok: C1
  # Stop here (exit 0)
  exit 0
fi
```

## Step 3: Extract checkable claims via LLM

For each memory, use an LLM claim extractor to identify concrete, checkable
assertions about the codebase.

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

The Step 2 SQL query includes `LIMIT 100` (the SQL-LIMIT overflow handling
named in the Batching Limits table). Memories beyond this limit remain
unvalidated and will be picked up on the next run (they keep
`validated_at IS NULL` and retain highest processing priority).

### Step 3.2: Spawn claim extractors

For each batch, run `skills/lib/prompt-frame.sh nonce`, then
`prompt-frame.sh strip` on the JSON array, then substitute `{{DATA_NONCE}}`
and `{{MEMORY_BATCH}}` with that stripped JSON. Spawn a Task subagent
(`subagent_type: "general-purpose"`, `model: haiku`). Cheap tier is safe here
— the six command-enforced validation rules below catch malformed output.

Spawn all extraction batches in parallel (all Task calls in one tool-use
block).

### Step 3.3: Validate extraction results

For each returned result, enforce the rules in `skills/validate-memory/SKILL.md`
section "Claim Extractor Prompt Template" → "Validation rules (command-enforced)".
That includes the "Maximum 8 claims per memory" cap (rule 6): truncate extractions
that exceed it. Rule 7: every input id appears once. The `claim_type` values it
references are the six terms in the "Claim Type Taxonomy" section.

```bash
# INPUT_IDS are the batch ids. EXTRACTION_JSON is the extractor's one line.
printf '%s\n' "$EXTRACTION_JSON" | bash skills/validate-memory/check-extraction.sh $INPUT_IDS || {
  echo "claim extraction failed: an input memory id is missing"
  exit 1
}
```

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
# lint-ok: C1
RESOLVED=$(realpath -m "$WTROOT/$REF_PATH" 2>/dev/null \
  || python3 -c 'import os,sys; print(os.path.normpath(os.path.join(sys.argv[1], sys.argv[2])))' "$WTROOT" "$REF_PATH")
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
    || python3 -c 'import os,sys; print(os.path.relpath(sys.argv[1], sys.argv[2]))' "$1" "$WTROOT"
}
```

For `file_reference` claims (after path containment guard):

```bash template
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
      NEARBY=$(find "$WTROOT/$PARENT/.." -maxdepth 3 -name "$BASENAME" 2>/dev/null | head -1)
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

```bash template
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
    if grep -qF -- "$SYM_NAME" "$WTROOT/$REF_PATH" 2>/dev/null; then
      verdict="VALID"; confidence=85
      evidence="$SYM_NAME found in $REF_PATH"
    else
      # Symbol not in claimed file — check if it exists elsewhere
      FOUND=$(grep -rlF -- "$SYM_NAME" "$WTROOT" \
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
    FOUND=$(grep -rlF -- "$SYM_NAME" "$WTROOT" \
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
    FOUND=$(grep -rlF -- "$SYM_NAME" "$WTROOT" \
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
3. For each batch, run `skills/lib/prompt-frame.sh nonce`, then
   `prompt-frame.sh strip` on the JSON array, then substitute `{{DATA_NONCE}}`
   and `{{CLAIMS_TO_VERIFY}}` with that stripped JSON. Spawn a Task subagent
   (`subagent_type: "general-purpose"`,
   `model: haiku`). Cheap tier is safe here — malformed/missing verdicts
   default to `AMBIGUOUS` conf 50 rather than being trusted blindly.
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

```bash template
# Per-claim points (weighted by confidence)
BASE_POINTS={"VALID": 0, "STALE": 25, "AMBIGUOUS": 10, "CONTRADICTED": 40}

for each claim verdict:
  weighted_pts = BASE_POINTS[verdict] * (confidence / 100)

# Average across all claims for this memory (0-40), then scale to 0-100.
raw_score = SUM(weighted_pts) / num_claims
scaled = raw_score * 100 / 40

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
# Executable form: skills/validate-memory/score.sh <age_days> <tier> VERDICT:CONF...
SCORE=$(bash skills/validate-memory/score.sh "$AGE_DAYS" "$TIER" "${VERDICT_ARGS[@]}")
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
sqlite3 -cmd ".timeout 5000" "$MEMDB" "
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

```bash template
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
sqlite3 -cmd ".timeout 5000" "$MEMDB" "
  UPDATE memories SET archived=TRUE, archive_reason='stale'
  WHERE id=$MEM_ID;
  INSERT INTO validation_log(memory_id, agent, action, confidence, reason)
  VALUES ($MEM_ID, '$MEM_AGENT', 'archive', $SCORE, '$ESCAPED_REASON');"
```

Do NOT set `validated_at` on archived entries (spec: MUST NOT set validated_at
on archived memories).

Log each auto-archive action for the TLDR summary.

## Step 8: Reviewer pipeline (score 40-80)

Spawn the tech-lead agent (its frontmatter sets the model; SPEC-003) as a reviewer for entries
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
sqlite3 -cmd ".timeout 5000" "$MEMDB" "
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
sqlite3 -cmd ".timeout 5000" "$MEMDB" "
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
sqlite3 -cmd ".timeout 5000" "$MEMDB" "
  UPDATE memories SET content='$ESCAPED_CONTENT',
    validated_at=strftime('%Y-%m-%dT%H:%M:%SZ','now')
  WHERE id=$MEM_ID;
  INSERT INTO validation_log(memory_id, agent, action, confidence, reason)
  VALUES ($MEM_ID, '$MEM_AGENT', 'rewrite', $SCORE, 'reviewer: rewrite');"
# Re-embed the rewritten row. A content change without a new vector is stale search.
# lint-ok: C3 — marketplace */ for-loop + -f guarded (SPEC-021 Q2 residual, CDT-82 PDH)
PDH=$( { [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -f "$CLAUDE_PLUGIN_ROOT/skills/plugin-dir.sh" ] && printf '%s\n' "$CLAUDE_PLUGIN_ROOT"; } || { [ -f skills/plugin-dir.sh ] && [ -f agents/pm.md ] && grep -qF '"name": "dev-team"' .claude-plugin/plugin.json 2>/dev/null && pwd; } || { _pr='${CLAUDE_PLUGIN_ROOT}'; [ "${_pr#\$}" = "$_pr" ] && [ -f "$_pr/skills/plugin-dir.sh" ] && printf '%s\n' "$_pr"; } || { for _mp in "$HOME"/.claude/plugins/marketplaces/*/; do [ -f "${_mp}skills/plugin-dir.sh" ] && [ -f "${_mp}agents/pm.md" ] && printf '%s\n' "${_mp%/}" && break; done; } || find ~/.claude/plugins/cache \( -path '*/dev-team/*/skills/plugin-dir.sh' -o -path '*/dev-team-edge/*/skills/plugin-dir.sh' \) 2>/dev/null | awk -F/ '{ver=""; for(i=1;i<=NF;i++) if(($i=="dev-team"||$i=="dev-team-edge")&&i<NF){ver=$(i+1);break}; if(ver=="") next; m=ver; gsub(/-pre\./,"~pre.",m); p=($0 ~ /\/cache\/cold-dark-void\/dev-team\//)?2:(($0 ~ /\/cache\/cold-dark-void\/dev-team-edge\//)?1:0); print m "\t" p "\t" $0}' | sort -t $'\t' -k1,1V -k2,2n -k3,3 | tail -1 | cut -f3 | xargs -r dirname | xargs -r dirname )
EMBED_ONE=$(bash "$PDH/skills/plugin-dir.sh" file skills/memory-store/embed-one.sh 2>/dev/null || true)
if [ -n "$EMBED_ONE" ] && [ -f "$EMBED_ONE" ]; then
  bash "$EMBED_ONE" "$MEMDB" "$MEM_ID" "$NEW_CONTENT" >/dev/null 2>&1 || true
fi
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
sqlite3 -cmd ".timeout 5000" "$MEMDB" "
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
sqlite3 -cmd ".timeout 5000" "$MEMDB" "
  INSERT INTO validation_log(memory_id, agent, action, confidence, reason)
  VALUES ($MEM_ID, '$MEM_AGENT', 'flag_user', $SCORE, '$ESCAPED_REASON');"
```

## Step 10: Deep mode (--deep flag only)

Runs only when `--deep` is set. Executes AFTER standard validation completes
(Steps 2-9). Deep mode checks whether tier-1 digests have become unreliable
because too many of their source memories were archived as stale.

> **IMPORTANT: Circularity guard.** When `/memory distill` calls
> `/memory validate` as a pre-distill step, it MUST NOT pass `--deep`.
> Deep mode invokes the @distiller agent, which would create a circular
> dependency. The caller (`/memory distill`) is responsible for omitting `--deep`.
> This subcommand does not enforce the guard itself.

### Step 10.1: Query tier-1 digests

```bash
_gc=$(git rev-parse --git-common-dir 2>/dev/null) \
  && MROOT=$(cd "$(dirname "$_gc")" && pwd) \
  || MROOT=$(pwd)
WTROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
MEMDB="$MROOT/.claude/memory/memory.db"
# This block is a new shell: rebuild the agent filter here (same rule as Step 3).
AGENT_CLAUSE=""
if [ -n "$TARGET_AGENT" ]; then
  case "$TARGET_AGENT" in
    pm|tech-lead|ic5|ic4|devops|qa|ds) ;;
    *) echo "Error: --agent must match the roster" >&2; exit 64 ;;
  esac
  bash skills/lib/require-agent.sh "$TARGET_AGENT"
  AGENT_CLAUSE="AND agent='$TARGET_AGENT'"
fi
DIGESTS=$(sqlite3 -cmd ".timeout 5000" "$MEMDB" "
  SELECT id, agent, distilled_from
  FROM memories
  WHERE tier=1 AND archived=FALSE $AGENT_CLAUSE
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
# Count sources before any query. An empty list must not become IN ().
TOTAL_SOURCES=$(printf '%s' "${DISTILLED_FROM:-[]}" | python3 -c 'import json,sys
try:
    data=json.load(sys.stdin)
except Exception:
    data=[]
print(len(data) if isinstance(data, list) else 0)')
if [ "${TOTAL_SOURCES:-0}" -eq 0 ]; then
  STALE_COUNT=0
else
  ESC_FROM=$(printf '%s' "$DISTILLED_FROM" | sed "s/'/''/g")
  STALE_COUNT=$(sqlite3 -cmd ".timeout 5000" "$MEMDB" "
    SELECT COUNT(*) FROM memories
    WHERE archive_reason='stale'
      AND id IN (SELECT value FROM json_each('$ESC_FROM'));
  ")
fi
```

### Step 10.3: Flag digests for rebuild

If more than 50% of sources are stale, flag the digest for rebuild. The 50%
threshold is fixed for v1. Use cross-multiplication to avoid bash integer
division truncation:

```bash template
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
# Skip only a fresh foreign lock. An empty lock and a lock older than 30 minutes pass.
if ! bash skills/memory-store/distill-lock.sh guard "$MEMDB"; then
  echo "Error: distiller lock held. Cannot rebuild digests. Try again later."
  # Report all flagged digests as skipped, do NOT archive them
  DEEP_SKIPPED=$FLAGGED_COUNT
  # Skip to Step 10.6 deep mode reporting. Do not exit the command.
fi
```

Do NOT archive digests if the lock is held. Report the skip in Step 10.6.

### Step 10.5: Rebuild flagged digests

For each flagged digest:

1. Ask @distiller for the replacement text only. Do not write the database in
   that step. The text is `NEW_DIGEST`.

2. Write the new digest, then archive the old row. `deep-rebuild.sh` keeps
   sources whose `archive_reason` is null or `distilled`, and it leaves the
   old digest live when the distiller fails or no source remains:
   ```bash
_gc=$(git rev-parse --git-common-dir 2>/dev/null) \
  && MROOT=$(cd "$(dirname "$_gc")" && pwd) \
  || MROOT=$(pwd)
WTROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
MEMDB="$MROOT/.claude/memory/memory.db"
   if [ -z "$NEW_DIGEST" ]; then
     bash skills/memory-store/deep-rebuild.sh "$MEMDB" "$DIGEST_ID" fail
   else
     bash skills/memory-store/deep-rebuild.sh "$MEMDB" "$DIGEST_ID" content "$NEW_DIGEST"
   fi
   ```

3. The valid source ids are those whose `archive_reason` is null or
   `distilled`. `deep-rebuild.sh` uses the same rule. This fence is the
   check the host can run before it asks for the new text:
   ```bash
_gc=$(git rev-parse --git-common-dir 2>/dev/null) \
  && MROOT=$(cd "$(dirname "$_gc")" && pwd) \
  || MROOT=$(pwd)
WTROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
MEMDB="$MROOT/.claude/memory/memory.db"
   # This block is a new shell. An empty list must not become IN ().
   TOTAL_SOURCES=$(printf '%s' "${DISTILLED_FROM:-[]}" | python3 -c 'import json,sys
try:
    data=json.load(sys.stdin)
except Exception:
    data=[]
print(len(data) if isinstance(data, list) else 0)')
   if [ "${TOTAL_SOURCES:-0}" -eq 0 ]; then
     VALID_IDS=""
   else
     ESC_FROM=$(printf '%s' "$DISTILLED_FROM" | sed "s/'/''/g")
     VALID_IDS=$(sqlite3 -cmd ".timeout 5000" "$MEMDB" "
       SELECT id FROM memories
       WHERE id IN (SELECT value FROM json_each('$ESC_FROM'))
         AND (archive_reason IS NULL OR archive_reason='distilled')
       ORDER BY created_at ASC, id ASC;
     ")
   fi
   ```

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
  [id=88] "Team standup runs via /status standup command" | skipped (no checkable claims)
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

