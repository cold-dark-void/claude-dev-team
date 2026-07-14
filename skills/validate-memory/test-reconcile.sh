#!/usr/bin/env bash
#
# test-reconcile.sh — SPEC-011 reconcile (CDV-195) bite-tests
#
# Machine-check: bash skills/validate-memory/test-reconcile.sh  (exit 0)
# THIS SCRIPT IS A SUBPROCESS CLI — NEVER SOURCE IT.

set -u

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
PLUGIN_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/../.." && pwd)
LIB="$SCRIPT_DIR/reconcile-lib.sh"
SCHEMA_SQL="$PLUGIN_ROOT/skills/memory-store/schema.sql"
MIGRATE_V3="$PLUGIN_ROOT/skills/memory-store/migrate-v3.sh"
MIGRATE_V4="$PLUGIN_ROOT/skills/memory-store/migrate-v4.sh"
MIGRATE="$PLUGIN_ROOT/skills/memory-store/migrate.sh"
V2_SQL="$PLUGIN_ROOT/skills/memory-store/migrate-v2.sh"

PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); echo "PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "FAIL: $1" >&2; }

TMP=$(mktemp -d "${TMPDIR:-/tmp}/reconcile-test.XXXXXX")
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

# ---- helpers ---------------------------------------------------------------

make_v4_db() {
  local root=$1
  mkdir -p "$root/.claude/memory"
  sqlite3 "$root/.claude/memory/memory.db" <"$SCHEMA_SQL"
}

make_v3_db() {
  # Build a v3 DB by applying schema then downgrading version + dropping reconcile
  local root=$1
  mkdir -p "$root/.claude/memory"
  local db="$root/.claude/memory/memory.db"
  sqlite3 "$db" <"$SCHEMA_SQL"
  sqlite3 "$db" <<'SQL'
DROP INDEX IF EXISTS idx_reconcile_pair;
DROP TABLE IF EXISTS reconcile_log;
DELETE FROM config WHERE key='reconcile_pair_cap';
UPDATE config SET value='3' WHERE key='schema_version';
SQL
}

seed_contradiction() {
  local db=$1
  sqlite3 "$db" <<'SQL'
INSERT INTO memories(agent, type, content, tier) VALUES
  ('pm', 'memory',
   'We decided to use PostgreSQL as the primary database for the product store.', 0),
  ('tech-lead', 'memory',
   'We rejected PostgreSQL as the primary database; product store stays on SQLite only.', 0),
  ('ic5', 'memory',
   'Cache uses sharded LRU with per-shard locks in internal/cache/lru.go.', 0),
  ('ic4', 'memory',
   'Cache uses sharded LRU with per-shard locks and mutex arrays.', 0),
  ('devops', 'memory',
   'Deploy pipeline runs on GitHub Actions with matrix builds for linux.', 0);
SQL
}

# ---- T1: schema.sql fresh DB has reconcile_log + version 4 -----------------
{
  R="$TMP/fresh"
  make_v4_db "$R"
  DB="$R/.claude/memory/memory.db"
  VER=$(sqlite3 "$DB" "SELECT value FROM config WHERE key='schema_version';")
  CAP=$(sqlite3 "$DB" "SELECT value FROM config WHERE key='reconcile_pair_cap';")
  HAS=$(sqlite3 "$DB" "SELECT name FROM sqlite_master WHERE type='table' AND name='reconcile_log';")
  if [ "$VER" = "4" ] && [ "$CAP" = "50" ] && [ "$HAS" = "reconcile_log" ]; then
    pass "schema.sql fresh DB v4 + reconcile_log + cap=50"
  else
    fail "schema.sql fresh (ver=$VER cap=$CAP table=$HAS)"
  fi
}

# ---- T2: migrate-v4 v3→v4 --------------------------------------------------
{
  R="$TMP/mig4"
  make_v3_db "$R"
  DB="$R/.claude/memory/memory.db"
  if ! bash "$MIGRATE_V4" "$R" >/dev/null; then
    fail "migrate-v4 exit non-zero"
  else
    VER=$(sqlite3 "$DB" "SELECT value FROM config WHERE key='schema_version';")
    HAS=$(sqlite3 "$DB" "SELECT 1 FROM sqlite_master WHERE name='reconcile_log';")
    CAP=$(sqlite3 "$DB" "SELECT value FROM config WHERE key='reconcile_pair_cap';")
    if [ "$VER" = "4" ] && [ "$HAS" = "1" ] && [ "$CAP" = "50" ]; then
      pass "migrate-v4 v3→v4"
    else
      fail "migrate-v4 state (ver=$VER has=$HAS cap=$CAP)"
    fi
  fi
  # idempotent
  OUT=$(bash "$MIGRATE_V4" "$R" 2>&1) || true
  if echo "$OUT" | grep -q "already at v4"; then
    pass "migrate-v4 idempotent"
  else
    fail "migrate-v4 idempotent: $OUT"
  fi
}

# ---- T3: migrate-v4 rejects non-v3 ----------------------------------------
{
  R="$TMP/badver"
  make_v4_db "$R"
  sqlite3 "$R/.claude/memory/memory.db" "UPDATE config SET value='2' WHERE key='schema_version';"
  if bash "$MIGRATE_V4" "$R" >/dev/null 2>&1; then
    fail "migrate-v4 should reject v2"
  else
    pass "migrate-v4 rejects unexpected version"
  fi
}

# ---- T4: migrate.sh LATEST=4 from synthetic v3 ----------------------------
{
  R="$TMP/chain"
  make_v3_db "$R"
  OUT=$(bash "$MIGRATE" "$R" 2>&1) || { fail "migrate.sh chain failed: $OUT"; }
  VER=$(sqlite3 "$R/.claude/memory/memory.db" "SELECT value FROM config WHERE key='schema_version';")
  if [ "$VER" = "4" ]; then
    pass "migrate.sh chain ends at v4"
  else
    fail "migrate.sh ended at $VER"
  fi
}

# ---- T5: keyword candidates find topical cross-agent pairs ----------------
{
  R="$TMP/kw"
  make_v4_db "$R"
  DB="$R/.claude/memory/memory.db"
  seed_contradiction "$DB"
  OUTF="$TMP/pairs.jsonl"
  META=$(bash "$LIB" candidates "$DB" --out "$OUTF" 2>&1 >/dev/null) || true
  # re-run capturing both
  META=$(bash "$LIB" candidates "$DB" --out "$OUTF" 2>&1)
  # candidates writes jsonl to --out; meta on stderr mixed with stdout if any
  # Actually meta is stderr, jsonl is --out only when --out set... wait, cmd prints
  # meta to stderr and copies to out. stdout empty when --out set.
  N=$(wc -l <"$OUTF" | tr -d ' ')
  METHOD=$(echo "$META" | grep RECONCILE_META | sed -n 's/.*method=\([^ ]*\).*/\1/p')
  # Expect at least the postgres contradiction pair and/or cache pair
  HAS_PG=0
  if [ -s "$OUTF" ]; then
    if python3 -c '
import json,sys
pairs=open(sys.argv[1]).read().strip().splitlines()
found=False
for line in pairs:
  o=json.loads(line)
  blob=(o["content_a"]+" "+o["content_b"]).lower()
  if "postgresql" in blob:
    found=True
print("yes" if found else "no")
' "$OUTF" | grep -q yes; then
      HAS_PG=1
    fi
  fi
  if [ "$METHOD" = "keyword" ] && [ "$HAS_PG" = "1" ] && [ "$N" -ge 1 ]; then
    pass "keyword candidates produce postgresql cross-agent pair (n=$N)"
  else
    fail "keyword candidates (method=$METHOD n=$N has_pg=$HAS_PG meta=$META)"
    cat "$OUTF" >&2 || true
  fi
}

# ---- T6: cap enforcement ---------------------------------------------------
{
  R="$TMP/cap"
  make_v4_db "$R"
  DB="$R/.claude/memory/memory.db"
  seed_contradiction "$DB"
  # add more overlapping pairs
  for i in 1 2 3 4 5; do
    sqlite3 "$DB" "INSERT INTO memories(agent,type,content,tier) VALUES
      ('pm','memory','Feature flag system uses LaunchDarkly for rollout $i shared tokens feature flag system',0),
      ('qa','memory','Feature flag system uses LaunchDarkly for testing $i shared tokens feature flag system',0);"
  done
  OUTF="$TMP/cap.jsonl"
  META=$(bash "$LIB" candidates "$DB" --cap 2 --out "$OUTF" 2>&1)
  N=$(wc -l <"$OUTF" | tr -d ' ')
  HIT=$(echo "$META" | grep RECONCILE_META | grep -o 'cap_hit=[^ ]*' || true)
  if [ "$N" -le 2 ] && [ "$N" -ge 1 ]; then
    pass "cap limits pairs to ≤2 (n=$N $HIT)"
  else
    fail "cap (n=$N meta=$META)"
  fi
}

# ---- T7: pick-survivor archives loser with archive_reason=reconciled ------
{
  R="$TMP/pick"
  make_v4_db "$R"
  DB="$R/.claude/memory/memory.db"
  seed_contradiction "$DB"
  ID_PM=$(sqlite3 "$DB" "SELECT id FROM memories WHERE agent='pm' LIMIT 1;")
  ID_TL=$(sqlite3 "$DB" "SELECT id FROM memories WHERE agent='tech-lead' LIMIT 1;")
  bash "$LIB" resolve-pick "$DB" "$ID_PM" "$ID_TL" "pm" "tech-lead" \
    "use PostgreSQL" "rejected PostgreSQL" 90 "pm wins" >/dev/null
  ARCH=$(sqlite3 "$DB" "SELECT archived, archive_reason FROM memories WHERE id=$ID_TL;")
  WIN=$(sqlite3 "$DB" "SELECT archived FROM memories WHERE id=$ID_PM;")
  LOG=$(sqlite3 "$DB" "SELECT action, winner_id, loser_id FROM reconcile_log ORDER BY id DESC LIMIT 1;")
  if [ "$ARCH" = "1|reconciled" ] && [ "$WIN" = "0" ] && [ "$LOG" = "pick-survivor|$ID_PM|$ID_TL" ]; then
    pass "pick-survivor archives loser reconciled + log"
  else
    fail "pick-survivor (arch=$ARCH win=$WIN log=$LOG)"
  fi
}

# ---- T8: resolved pair skipped on re-run ----------------------------------
{
  R="$TMP/skipres"
  make_v4_db "$R"
  DB="$R/.claude/memory/memory.db"
  seed_contradiction "$DB"
  ID_PM=$(sqlite3 "$DB" "SELECT id FROM memories WHERE agent='pm' LIMIT 1;")
  ID_TL=$(sqlite3 "$DB" "SELECT id FROM memories WHERE agent='tech-lead' LIMIT 1;")
  # First candidates should include pair
  OUT1="$TMP/s1.jsonl"
  bash "$LIB" candidates "$DB" --out "$OUT1" 2>/dev/null
  bash "$LIB" resolve-pick "$DB" "$ID_PM" "$ID_TL" "pm" "tech-lead" \
    "a" "b" 90 "done" >/dev/null
  OUT2="$TMP/s2.jsonl"
  bash "$LIB" candidates "$DB" --out "$OUT2" 2>/dev/null
  STILL=$(python3 -c '
import json,sys
ids=set(map(int,sys.argv[1:3]))
for line in open(sys.argv[3]):
  o=json.loads(line)
  if {o["id_a"],o["id_b"]}==ids:
    print("yes"); raise SystemExit
print("no")
' "$ID_PM" "$ID_TL" "$OUT2")
  if [ "$STILL" = "no" ]; then
    pass "resolved pair skipped on re-run"
  else
    fail "resolved pair still proposed"
  fi
}

# ---- T9: both-stale archives both -----------------------------------------
{
  R="$TMP/both"
  make_v4_db "$R"
  DB="$R/.claude/memory/memory.db"
  seed_contradiction "$DB"
  ID_PM=$(sqlite3 "$DB" "SELECT id FROM memories WHERE agent='pm' LIMIT 1;")
  ID_TL=$(sqlite3 "$DB" "SELECT id FROM memories WHERE agent='tech-lead' LIMIT 1;")
  bash "$LIB" resolve-both-stale "$DB" "$ID_PM" "$ID_TL" "pm" "tech-lead" \
    "a" "b" 85 "both wrong" >/dev/null
  C=$(sqlite3 "$DB" "SELECT COUNT(*) FROM memories WHERE id IN ($ID_PM,$ID_TL) AND archived=TRUE AND archive_reason='reconciled';")
  if [ "$C" = "2" ]; then
    pass "both-stale archives both reconciled"
  else
    fail "both-stale count=$C"
  fi
}

# ---- T10: deep-audit prints /council, no archive --------------------------
{
  R="$TMP/deep"
  make_v4_db "$R"
  DB="$R/.claude/memory/memory.db"
  seed_contradiction "$DB"
  ID_PM=$(sqlite3 "$DB" "SELECT id FROM memories WHERE agent='pm' LIMIT 1;")
  ID_TL=$(sqlite3 "$DB" "SELECT id FROM memories WHERE agent='tech-lead' LIMIT 1;")
  OUT=$(bash "$LIB" resolve-deep-audit "$DB" "$ID_PM" "$ID_TL" "pm" "tech-lead" \
    "claim A postgres" "claim B no postgres" 70 "needs council")
  ARCH=$(sqlite3 "$DB" "SELECT COUNT(*) FROM memories WHERE archived=TRUE;")
  LOG=$(sqlite3 "$DB" "SELECT action FROM reconcile_log ORDER BY id DESC LIMIT 1;")
  if echo "$OUT" | grep -q '/council "' && [ "$ARCH" = "0" ] && [ "$LOG" = "deep-audit" ]; then
    pass "deep-audit prints /council, no archive"
  else
    fail "deep-audit (out=$OUT arch=$ARCH log=$LOG)"
  fi
}

# ---- T11: report-only simulation — candidates alone never writes log ------
{
  R="$TMP/ro"
  make_v4_db "$R"
  DB="$R/.claude/memory/memory.db"
  seed_contradiction "$DB"
  bash "$LIB" candidates "$DB" --out "$TMP/ro.jsonl" 2>/dev/null
  LOGN=$(sqlite3 "$DB" "SELECT COUNT(*) FROM reconcile_log;")
  ARCH=$(sqlite3 "$DB" "SELECT COUNT(*) FROM memories WHERE archived=TRUE;")
  if [ "$LOGN" = "0" ] && [ "$ARCH" = "0" ]; then
    pass "candidates path zero writes (report-only safe)"
  else
    fail "candidates wrote log=$LOGN arch=$ARCH"
  fi
}

# ---- T12: --agent filter (at least one side) ------------------------------
{
  R="$TMP/ag"
  make_v4_db "$R"
  DB="$R/.claude/memory/memory.db"
  seed_contradiction "$DB"
  OUTF="$TMP/ag.jsonl"
  bash "$LIB" candidates "$DB" --agent pm --out "$OUTF" 2>/dev/null
  BAD=$(python3 -c '
import json,sys
bad=0
for line in open(sys.argv[1]):
  o=json.loads(line)
  if o["agent_a"]!="pm" and o["agent_b"]!="pm":
    bad+=1
print(bad)
' "$OUTF")
  if [ "$BAD" = "0" ] && [ -s "$OUTF" ]; then
    pass "--agent pm filters pairs (at least one side)"
  else
    fail "--agent filter bad=$BAD"
  fi
}

# ---- T13: merge preserves winner tier/type, archives loser ----------------
{
  R="$TMP/merge"
  make_v4_db "$R"
  DB="$R/.claude/memory/memory.db"
  seed_contradiction "$DB"
  ID_PM=$(sqlite3 "$DB" "SELECT id FROM memories WHERE agent='pm' LIMIT 1;")
  ID_TL=$(sqlite3 "$DB" "SELECT id FROM memories WHERE agent='tech-lead' LIMIT 1;")
  bash "$LIB" resolve-merge "$DB" "$ID_PM" "$ID_TL" "pm" "tech-lead" \
    "a" "b" 88 "Merged: SQLite for local, Postgres deferred" "merged decision" >/dev/null
  CONTENT=$(sqlite3 "$DB" "SELECT content FROM memories WHERE id=$ID_PM;")
  TIER=$(sqlite3 "$DB" "SELECT tier FROM memories WHERE id=$ID_PM;")
  ARCH=$(sqlite3 "$DB" "SELECT archive_reason FROM memories WHERE id=$ID_TL;")
  if echo "$CONTENT" | grep -q '\[reconciled:' && [ "$TIER" = "0" ] && [ "$ARCH" = "reconciled" ]; then
    pass "merge updates winner + tag, archives loser"
  else
    fail "merge content/tier/arch"
  fi
}

# ---- T14: skip logs only --------------------------------------------------
{
  R="$TMP/sk"
  make_v4_db "$R"
  DB="$R/.claude/memory/memory.db"
  seed_contradiction "$DB"
  ID_PM=$(sqlite3 "$DB" "SELECT id FROM memories WHERE agent='pm' LIMIT 1;")
  ID_TL=$(sqlite3 "$DB" "SELECT id FROM memories WHERE agent='tech-lead' LIMIT 1;")
  bash "$LIB" resolve-skip "$DB" "$ID_PM" "$ID_TL" "pm" "tech-lead" \
    "a" "b" 50 "not sure" >/dev/null
  ARCH=$(sqlite3 "$DB" "SELECT COUNT(*) FROM memories WHERE archived=TRUE;")
  LOG=$(sqlite3 "$DB" "SELECT action FROM reconcile_log;")
  if [ "$ARCH" = "0" ] && [ "$LOG" = "skip" ]; then
    pass "skip logs only, no archive"
  else
    fail "skip arch=$ARCH log=$LOG"
  fi
}

# ---- summary --------------------------------------------------------------
echo ""
echo "Results: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
exit 0
