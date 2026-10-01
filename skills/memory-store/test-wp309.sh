#!/usr/bin/env bash
# WP 3-09: config upsert, empty source list, rewrite embed, stats --agent,
# distill --compress, /spec check audit, adjust-agent seed gitignore, council --workflow.
# Machine-check: bash skills/memory-store/test-wp309.sh
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck source=../../tests/lib/hermetic.sh
. "$ROOT/tests/lib/hermetic.sh"
# shellcheck source=../../tests/lib/fence.sh
. "$ROOT/tests/lib/fence.sh"
# shellcheck source=../../tests/lib/check.sh
. "$ROOT/tests/lib/check.sh"
hermetic_init

export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
unset GIT_DIR GIT_INDEX_FILE GIT_WORK_TREE

pass=0
fail=0

WORK="$HERMETIC_ROOT/work"
REPO="$WORK/repo"
mkdir -p "$REPO/.claude/memory"
( cd "$REPO" && git init -q . && git commit -q --allow-empty -m init ) || { echo "FATAL: fixture repo"; exit 1; }
DB="$REPO/.claude/memory/memory.db"
sqlite3 "$DB" < "$ROOT/skills/memory-store/schema.sql" >/dev/null || { echo "FATAL: schema"; exit 1; }
sqlite3 "$DB" "
  INSERT INTO memories(id, agent, type, content, tier) VALUES
    (1, 'pm', 'memory', 'pm row', 0),
    (2, 'ic5', 'memory', 'ic5 row', 0);
" || { echo "FATAL: rows"; exit 1; }

subst_args() {
  local t="$1" s="$2"
  case "$t" in *$'\n''$ARGUMENTS'$'\n'*) ;; *) return 1 ;; esac
  printf '%s\n' "${t/$'\n''$ARGUMENTS'$'\n'/$'\n'$s$'\n'}"
}

run_fence() {
  local text="$1" prefix="$2"; shift 2
  fence_exec "$prefix" "$REPO" "$text" "$@"
}

BYTES=$(wc -c < "$ROOT/commands/memory.md")
check "router is under 10 KB ($BYTES bytes)" test "$BYTES" -lt 10240

# ---- config: missing key is inserted ----
SET=$(fence_nth "$ROOT/skills/memory-store/modes/config.md" "### Step 5c: Apply update" 1)
check "config Step 5c fence extracted" test -n "$SET"
sqlite3 "$DB" "DELETE FROM config WHERE key='distill_model';"
run_fence "$SET" "$WORK/cfg" KEY=distill_model VALUE=opus
check "config set on a missing key exits 0 (rc=$RUN_RC)" test "$RUN_RC" -eq 0
GOT=$(sqlite3 "$DB" "SELECT value FROM config WHERE key='distill_model';")
check "config set creates distill_model=opus (got $GOT)" test "$GOT" = "opus"

MODEL=$(fence_nth "$ROOT/skills/memory-store/modes/config.md" "### Step 5b: Validate value" 1)
run_fence "$MODEL" "$WORK/badmodel" KEY=distill_model VALUE=gpt
check "distill_model rejects a name outside haiku|sonnet|opus (rc=$RUN_RC)" test "$RUN_RC" -eq 1
run_fence "$MODEL" "$WORK/okmodel" KEY=distill_model VALUE=sonnet
check "distill_model accepts sonnet (rc=$RUN_RC)" test "$RUN_RC" -eq 0

# ---- empty source list does not run IN () ----
STALE=$(fence_nth "$ROOT/skills/validate-memory/host-pipeline.md" "### Step 10.2" 1)
check "Step 10.2 fence extracted" test -n "$STALE"
FOOT='printf "STALE_COUNT=%s\n" "$STALE_COUNT"'
fence_exec "$WORK/empty" "$REPO" "$STALE"$'\n'"$FOOT" DISTILLED_FROM='[]'
check "empty distilled_from exits 0 (rc=$RUN_RC)" test "$RUN_RC" -eq 0
check "empty distilled_from sets STALE_COUNT=0" grep -qx 'STALE_COUNT=0' "$WORK/empty.out"
check "empty distilled_from has no SQL error" bash -c '! grep -qiE "parse error|syntax error|IN \\(\\)" "$1"' _ "$WORK/empty.err"

# ---- stats --agent ----
STATS=$(fence_nth "$ROOT/skills/memory-store/modes/stats.md" "## Step 3: Gather and display stats" 1)
STATS_PM=$(subst_args "$STATS" 'stats --agent pm') || STATS_PM=""
check "stats fence accepts an argument slot" test -n "$STATS_PM"
run_fence "$STATS_PM" "$WORK/stpm" CLAUDE_PLUGIN_ROOT="$ROOT"
check "stats --agent pm exits 0 (rc=$RUN_RC)" test "$RUN_RC" -eq 0
check "stats --agent pm shows pm" grep -q 'pm' "$WORK/stpm.out"
check "stats --agent pm hides ic5" bash -c '! grep -q ic5 "$1"' _ "$WORK/stpm.out"
STATS_BAD=$(subst_args "$STATS" 'stats --agent nope') || STATS_BAD=""
run_fence "$STATS_BAD" "$WORK/stbad" CLAUDE_PLUGIN_ROOT="$ROOT"
check "stats --agent nope exits 64 (rc=$RUN_RC)" test "$RUN_RC" -eq 64

# ---- distill --compress ----
COMP=$(fence_nth "$ROOT/skills/memory-store/modes/distill.md" "## Step 1: Parse arguments, resolve DB" 2)
COMP_ON=$(subst_args "$COMP" 'distill --compress') || COMP_ON=""
fence_exec "$WORK/con" "$REPO" "$COMP_ON"$'\n''printf "COMPRESS=%s\n" "$COMPRESS"'
check "distill --compress sets COMPRESS=true" grep -qx 'COMPRESS=true' "$WORK/con.out"
COMP_OFF=$(subst_args "$COMP" 'distill --compress') || COMP_OFF=""
fence_exec "$WORK/coff" "$REPO" "$COMP_OFF"$'\n''printf "COMPRESS=%s\n" "$COMPRESS"' MEMORY_COMPRESS=0
check "MEMORY_COMPRESS=0 forces COMPRESS off" grep -qx 'COMPRESS=false' "$WORK/coff.out"

# ---- rewrite calls the shipped embed-one ----
REW=$(fence_nth "$ROOT/skills/validate-memory/host-pipeline.md" "### On REWRITE" 1)
check "rewrite fence calls embed-one.sh" bash -c 'printf "%s\n" "$1" | grep -q "skills/memory-store/embed-one.sh"' _ "$REW"
sqlite3 "$DB" "UPDATE config SET value='lembed' WHERE key='embedding_mode';"
run_fence "$REW" "$WORK/rew" CLAUDE_PLUGIN_ROOT="$ROOT" MEM_ID=1 MEM_AGENT=pm SCORE=50 REWRITE_CONTENT='rewritten fact'
check "rewrite exits 0 (rc=$RUN_RC)" test "$RUN_RC" -eq 0
BODY=$(sqlite3 "$DB" "SELECT content FROM memories WHERE id=1;")
check "rewrite stores the new content" bash -c 'printf "%s" "$1" | grep -q "rewritten fact"' _ "$BODY"
META=$(sqlite3 "$DB" "SELECT COUNT(*) FROM embedding_meta WHERE memory_id=1;")
if [ "$META" != "0" ]; then
  check "rewrite left an embedding_meta row" test "$META" -ge 1
else
  check "rewrite invoked embed-one (missing lembed files are logged)" grep -q 'embed-one' "$REPO/.claude/memory/.errors.log"
fi

# ---- /spec check audit is not a spec id ----
SPEC=$(fence_nth "$ROOT/commands/spec.md" "#### Flags (both modes)" 1)
SPEC_A=$(subst_args "$SPEC" 'check audit') || SPEC_A=""
fence_exec "$WORK/spa" "$REPO" "$SPEC_A"$'\n''printf "MODE=%s\nSPEC_ID=%s\n" "$MODE" "$SPEC_ID"'
check "/spec check audit is audit mode" grep -qx 'MODE=audit' "$WORK/spa.out"
check "/spec check audit has an empty spec id" grep -qx 'SPEC_ID=' "$WORK/spa.out"
SPEC_V=$(subst_args "$SPEC" 'check SPEC-012') || SPEC_V=""
fence_exec "$WORK/spv" "$REPO" "$SPEC_V"$'\n''printf "MODE=%s\nSPEC_ID=%s\n" "$MODE" "$SPEC_ID"'
check "/spec check SPEC-012 is validate mode" grep -qx 'MODE=validate' "$WORK/spv.out"
check "/spec check SPEC-012 keeps the id" grep -qx 'SPEC_ID=SPEC-012' "$WORK/spv.out"

# ---- council --workflow is set inside Step 0.5 ----
CW=$(fence_nth "$ROOT/commands/council.md" "## Step 0.5: Scope parse" 1)
CW_ON=$(subst_args "$CW" '--diff --workflow') || CW_ON=""
fence_exec "$WORK/cwon" "$REPO" "$CW_ON"$'\n''printf "FLAG=%s\n" "$_COUNCIL_WORKFLOW_FLAG"'
check "council --workflow sets the flag" grep -qx 'FLAG=1' "$WORK/cwon.out"
CW_OFF=$(subst_args "$CW" '--diff') || CW_OFF=""
fence_exec "$WORK/cwoff" "$REPO" "$CW_OFF"$'\n''printf "FLAG=%s\n" "$_COUNCIL_WORKFLOW_FLAG"'
check "council without --workflow leaves the flag unset" grep -qx 'FLAG=0' "$WORK/cwoff.out"

# ---- adjust-agent gitignore keeps the seed pack committable ----
IGN=$(fence_nth "$ROOT/commands/adjust-agent.md" "### Step 5e: Ensure .gitignore coverage" 1)
: > "$REPO/.gitignore"
run_fence "$IGN" "$WORK/ign" CLAUDE_PLUGIN_ROOT="$ROOT"
check "gitignore fence exits 0 (rc=$RUN_RC)" test "$RUN_RC" -eq 0
check "gitignore uses .claude/memory/*" grep -qxF '.claude/memory/*' "$REPO/.gitignore"
check "gitignore negates the seed directory" grep -qxF '!.claude/memory/seed/' "$REPO/.gitignore"
check "gitignore does not ignore the memory directory itself" bash -c '! grep -qxF ".claude/memory/" "$1"' _ "$REPO/.gitignore"
mkdir -p "$REPO/.claude/memory/seed"
printf 'x\n' > "$REPO/.claude/memory/seed/probe.md"
if git -C "$REPO" -c core.excludesFile=/dev/null check-ignore -q -- .claude/memory/seed/probe.md; then
  fail_line "seed probe is still ignored"
else
  pass_line "seed probe is committable"
fi

# one copy of the tier SELECT
TIER_HITS=$(grep -l 'SUM(CASE WHEN tier=0 AND archived=FALSE' \
  "$ROOT/skills/memory-store/modes/tier-status.md" \
  "$ROOT/skills/memory-store/modes/search.md" \
  "$ROOT/skills/memory-store/modes/distill.md" 2>/dev/null | wc -l)
check "tier SELECT lives in one mode file (hits=$TIER_HITS)" test "$TIER_HITS" -eq 1
check "reconcile judge text does not stop at 5 batches" bash -c '! grep -q "max 5 batches" "$1"' _ "$ROOT/skills/validate-memory/reconcile-host.md"
check "reconcile judge text covers the cap" grep -q 'reconcile_pair_cap' "$ROOT/skills/validate-memory/reconcile-host.md"

echo "---"
echo "wp 3-09: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
