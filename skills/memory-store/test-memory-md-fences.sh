#!/usr/bin/env bash
# skills/memory-store/test-memory-md-fences.sh — SPEC-021 wp-1-12-fence-state
# ACs (CDT-264 [07 F-2]: `# lint-ok` inside SQL strings in commands/memory.md).
# Runs three `sqlite3` fences of commands/memory.md in fresh shells against a
# real fixture DB (schema.sql). Each fence used to hold a waiver INSIDE a
# double-quoted SQL string, so sqlite3 got `# lint-ok: C1` as SQL text (parse
# error) and the fence returned nothing. Each fence now rebuilds its own input
# and the waiver is gone.
#
#   Step 5 (distill)   "Determine which agents to process": without --agent the
#                      threshold comes from config and the agents over it are found
#   Step 10.1 (deep)   tier-1 digests are listed, with and without --agent
#   Step 10.5 (deep)   the valid source IDs of a digest are collected
#
# Hermetic: private TMPDIR/HOME (tests/lib/hermetic.sh). MEMORY_MD may name
# another revision of memory.md (bite-on-old-code run); default is this checkout.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
MEMORY_MD="${MEMORY_MD:-$ROOT/commands/memory.md}"

# shellcheck source=../../tests/lib/hermetic.sh
. "$ROOT/tests/lib/hermetic.sh"
# shellcheck source=../../tests/lib/fence.sh
. "$ROOT/tests/lib/fence.sh"
# shellcheck source=../../tests/lib/skip.sh
. "$ROOT/tests/lib/skip.sh"
# shellcheck source=../../tests/lib/check.sh
. "$ROOT/tests/lib/check.sh"
hermetic_init
require_cmd sqlite3 git

export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
unset GIT_DIR GIT_INDEX_FILE GIT_WORK_TREE

pass=0
fail=0

WORK="$HERMETIC_ROOT/work"
REPO="$WORK/repo"
mkdir -p "$REPO/.claude/memory"
( cd "$REPO" && git init -q . && git commit -q --allow-empty -m init ) || { echo "FATAL: fixture repo"; exit 1; }
DB="$REPO/.claude/memory/memory.db"
sqlite3 "$DB" < "$ROOT/skills/memory-store/schema.sql" > /dev/null || { echo "FATAL: schema"; exit 1; }
# a1: 3 raw rows (over threshold 2); a2: 1 raw row. Two tier-1 digests (one per
# agent). ids 11/12/13 are sources of a digest: live, distilled, stale.
sqlite3 "$DB" "
  UPDATE config SET value='2' WHERE key='distill_threshold';
  INSERT INTO memories(id, agent, type, content, tier) VALUES
    (1, 'a1', 'memory', 'a1 raw one', 0), (2, 'a1', 'memory', 'a1 raw two', 0),
    (3, 'a1', 'memory', 'a1 raw three', 0), (4, 'a2', 'memory', 'a2 raw one', 0),
    (5, 'a1', 'digest', 'a1 digest', 1), (6, 'a2', 'digest', 'a2 digest', 1);
  INSERT INTO memories(id, agent, type, content, tier, archived, archive_reason) VALUES
    (11, 'a1', 'memory', 'src live', 0, 0, NULL),
    (12, 'a1', 'memory', 'src distilled', 0, 1, 'distilled'),
    (13, 'a1', 'memory', 'src stale', 0, 1, 'stale');" || { echo "FATAL: fixture rows"; exit 1; }

# run_fence <fence-text> <prefix> [VAR=value ...] — fresh bash, cwd = the repo.
# A footer line (passed in $FOOTER) prints the variable the fence computed; the
# host model would carry on with it in the same way.
run_fence() {
  local text="$1" prefix="$2"; shift 2
  fence_exec "$prefix" "$REPO" "$text"$'\n'"${FOOTER:-}" "$@"
}
no_sql_error() { ! grep -qiE 'parse error|unrecognized token|syntax error|incomplete input' "$1.err"; }

# ---- extract ----------------------------------------------------------------
DISTILL="$(fence_nth "$MEMORY_MD" "## Step 5: Check distill_enabled" 2)"
DEEP101="$(fence_nth "$MEMORY_MD" "### Step 10.1" 1)"
DEEP105="$(fence_nth "$MEMORY_MD" "### Step 10.5" 2)"
for pair in "Step 5 (distill) agents:$DISTILL" "Step 10.1:$DEEP101" "Step 10.5 valid IDs:$DEEP105"; do
  if [ -n "${pair#*:}" ]; then pass_line "structural: ${pair%%:*} fence extracted"
  else fail_line "structural: ${pair%%:*} fence extracted (zero)"; fi
done

# planted negative control: a waiver inside a SQL string IS a sqlite3 parse error
ctl_err=$(sqlite3 "$DB" "SELECT 1  # lint-ok: C1
;" 2>&1 >/dev/null || true)
check "control: sqlite3 rejects a '# lint-ok' waiver inside a SQL string (got: ${ctl_err:-no error})" [ -n "$ctl_err" ]

# ---- distill: which agents -----------------------------------------------------
FOOTER='printf "AGENTS=%s\n" "$AGENTS"' run_fence "$DISTILL" "$WORK/d1"
check "distill without --agent: exits 0 (rc=$RUN_RC)" [ "$RUN_RC" -eq 0 ]
check "distill without --agent: no SQL error on stderr ($(head -c 120 "$WORK/d1.err"))" no_sql_error "$WORK/d1"
check "distill without --agent: finds the agent over the threshold (a1 only)" grep -qx 'AGENTS=a1' "$WORK/d1.out"
check "distill without --agent: does not report 'No agents have enough'" bash -c '! grep -q "No agents have enough" "$1"' _ "$WORK/d1.out"

FOOTER='printf "AGENTS=%s\n" "$AGENTS"' run_fence "$DISTILL" "$WORK/d2" TARGET_AGENT=a2
check "distill with --agent a2: processes a2 regardless of threshold" grep -qx 'AGENTS=a2' "$WORK/d2.out"

# ---- validate --deep: digests and source IDs -----------------------------------
FOOTER='printf "DIGESTS=%s\n" "$DIGESTS"' run_fence "$DEEP101" "$WORK/v1"
check "deep 10.1 without --agent: no SQL error ($(head -c 120 "$WORK/v1.err"))" no_sql_error "$WORK/v1"
check "deep 10.1 without --agent: lists both tier-1 digests" bash -c 'grep -q "5|a1" "$1" && grep -q "6|a2" "$1"' _ "$WORK/v1.out"

FOOTER='printf "DIGESTS=%s\n" "$DIGESTS"' run_fence "$DEEP101" "$WORK/v2" TARGET_AGENT=a1
check "deep 10.1 with --agent a1: lists only the a1 digest" bash -c 'grep -q "5|a1" "$1" && ! grep -q "6|a2" "$1"' _ "$WORK/v2.out"

FOOTER='printf "VALID_IDS=%s\n" "$(echo "$VALID_IDS" | tr "\n" " ")"' run_fence "$DEEP105" "$WORK/v3" 'DISTILLED_FROM=[11,12,13]'
check "deep 10.5: exits 0 (rc=$RUN_RC)" [ "$RUN_RC" -eq 0 ]
check "deep 10.5: no SQL error ($(head -c 120 "$WORK/v3.err"))" no_sql_error "$WORK/v3"
check "deep 10.5: keeps the live and the distilled sources, drops the stale one" grep -qx 'VALID_IDS=11 12 ' "$WORK/v3.out"

echo "---"
echo "memory.md fence tests: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
