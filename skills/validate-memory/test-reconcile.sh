#!/usr/bin/env bash
#
# test-reconcile.sh — SPEC-011 reconcile (CDV-195) bite-tests
#
# Machine-check: bash skills/validate-memory/test-reconcile.sh  (exit 0)
# THIS SCRIPT IS A SUBPROCESS CLI — NEVER SOURCE IT.

set -u

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
PLUGIN_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/../.." && pwd)
source "$PLUGIN_ROOT/tests/lib/skip.sh"
require_cmd sqlite3
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

# ---- T15: zero-byte vec0 and an empty vec table fall back to keyword ------
{
  R="$TMP/ext_ok"
  make_v4_db "$R"
  DB="$R/.claude/memory/memory.db"
  seed_contradiction "$DB"
  sqlite3 "$DB" <<'SQL'
INSERT OR REPLACE INTO config(key,value) VALUES
  ('embedding_mode','lembed'),
  ('embedding_dimensions','384');
CREATE TABLE IF NOT EXISTS vec_memories_384 (memory_id INTEGER, embedding BLOB);
SQL
  SUFFIX=so
  [ "$(uname -s)" = "Darwin" ] && SUFFIX=dylib
  mkdir -p "$R/.claude/memory/extensions"
  : >"$R/.claude/memory/extensions/vec0.$SUFFIX"
  OUTF="$TMP/ext_ok.jsonl"
  META=$(bash "$LIB" candidates "$DB" --out "$OUTF" 2>&1)
  RC=$?
  METHOD=$(echo "$META" | grep RECONCILE_META | sed -n 's/.*method=\([^ ]*\).*/\1/p')
  N=$(wc -l <"$OUTF" | tr -d ' ')
  NESTED_TOUCHED=0
  [ -e "$R/.claude/.claude" ] && NESTED_TOUCHED=1
  if [ "$RC" = "0" ] && [ "$METHOD" = "keyword" ] && [ "$N" -ge 1 ] && [ "$NESTED_TOUCHED" = "0" ]; then
    pass "broken vec0 and empty vec table fall back to keyword (n=$N)"
  else
    fail "keyword fallback (rc=$RC method=$METHOD n=$N nested=$NESTED_TOUCHED meta=$META)"
  fi
}

# ---- T16: path-absent — eligible embed config, no vec0 → method=keyword (AC-4)
{
  R="$TMP/ext_absent"
  make_v4_db "$R"
  DB="$R/.claude/memory/memory.db"
  seed_contradiction "$DB"
  sqlite3 "$DB" <<'SQL'
INSERT OR REPLACE INTO config(key,value) VALUES
  ('embedding_mode','lembed'),
  ('embedding_dimensions','384');
CREATE TABLE IF NOT EXISTS vec_memories_384 (memory_id INTEGER, embedding BLOB);
SQL
  OUTF="$TMP/ext_absent.jsonl"
  META=$(bash "$LIB" candidates "$DB" --out "$OUTF" 2>&1)
  RC=$?
  METHOD=$(echo "$META" | grep RECONCILE_META | sed -n 's/.*method=\([^ ]*\).*/\1/p')
  if [ "$RC" = "0" ] && [ "$METHOD" = "keyword" ]; then
    pass "path-absent: no vec0 → method=keyword"
  else
    fail "path-absent (rc=$RC method=$METHOD meta=$META)"
  fi
}

# ---- T17: path-nested-only — dummy only at .claude/.claude/... → keyword (AC-5)
{
  R="$TMP/ext_nested"
  make_v4_db "$R"
  DB="$R/.claude/memory/memory.db"
  seed_contradiction "$DB"
  sqlite3 "$DB" <<'SQL'
INSERT OR REPLACE INTO config(key,value) VALUES
  ('embedding_mode','lembed'),
  ('embedding_dimensions','384');
CREATE TABLE IF NOT EXISTS vec_memories_384 (memory_id INTEGER, embedding BLOB);
SQL
  SUFFIX=so
  [ "$(uname -s)" = "Darwin" ] && SUFFIX=dylib
  mkdir -p "$R/.claude/.claude/memory/extensions"
  : >"$R/.claude/.claude/memory/extensions/vec0.$SUFFIX"
  # correct path must NOT exist
  rm -f "$R/.claude/memory/extensions/vec0.$SUFFIX" 2>/dev/null || true
  OUTF="$TMP/ext_nested.jsonl"
  META=$(bash "$LIB" candidates "$DB" --out "$OUTF" 2>&1)
  RC=$?
  METHOD=$(echo "$META" | grep RECONCILE_META | sed -n 's/.*method=\([^ ]*\).*/\1/p')
  if [ "$RC" = "0" ] && [ "$METHOD" = "keyword" ]; then
    pass "path-nested-only: wrong .claude/.claude path ignored → keyword"
  else
    fail "path-nested-only (rc=$RC method=$METHOD meta=$META)"
  fi
}

# ---- T18: static — no mroot_guess / double-dirname of memdb (AC-2)
{
  if grep -E 'mroot_guess|dirname "\$\(dirname' "$LIB" >/dev/null 2>&1; then
    fail "static: mroot_guess or double-dirname still in reconcile-lib"
  else
    pass "static: no mroot_guess / double-dirname of memdb"
  fi
}

# ---- T19: injection and multiline content do not change the row count -----
{
  R="$TMP/inject"
  make_v4_db "$R"
  DB="$R/.claude/memory/memory.db"
  seed_contradiction "$DB"
  sqlite3 "$DB" "INSERT INTO memories(agent,type,content,tier) VALUES
    ('qa','memory','line one' || char(10) || '0); DELETE FROM memories; --' || char(9) || 'pipe|inside',0),
    ('ic5','memory','line one' || char(10) || '0); DELETE FROM memories; --' || char(9) || 'pipe|inside',0);"
  BEFORE=$(sqlite3 "$DB" "SELECT COUNT(*) FROM memories;")
  OUTF="$TMP/inject.jsonl"
  bash "$LIB" candidates "$DB" --out "$OUTF" 2>/dev/null
  AFTER=$(sqlite3 "$DB" "SELECT COUNT(*) FROM memories;")
  FULL=$(python3 -c '
import json,sys
want="line one\n0); DELETE FROM memories; --\tpipe|inside"
for line in open(sys.argv[1], encoding="utf-8"):
    o=json.loads(line)
    if o.get("content_a")==want or o.get("content_b")==want:
        print("yes")
        raise SystemExit
print("no")
' "$OUTF")
  if [ "$BEFORE" = "$AFTER" ] && [ "$FULL" = "yes" ]; then
    pass "injection and multiline content stay intact (rows=$AFTER)"
  else
    fail "injection (before=$BEFORE after=$AFTER full=$FULL)"
  fi
}

# ---- T20: 1400-row keyword pass finishes within 30s -----------------------
{
  R="$TMP/fast"
  make_v4_db "$R"
  DB="$R/.claude/memory/memory.db"
  {
    echo "BEGIN;"
    for agent in pm tech-lead ic5 ic4 devops qa ds; do
      i=1
      while [ "$i" -le 200 ]; do
        printf "INSERT INTO memories(agent,type,content,tier) VALUES ('%s','memory','sharedtokenfeature reconciliation keyword overlap memory store item %s',0);\n" "$agent" "$i"
        i=$((i + 1))
      done
    done
    echo "COMMIT;"
  } | sqlite3 "$DB"
  OUTF="$TMP/fast.jsonl"
  START=$(date +%s)
  bash "$LIB" candidates "$DB" --cap 50 --out "$OUTF" >/dev/null
  END=$(date +%s)
  ELAPSED=$((END - START))
  N=$(wc -l <"$OUTF" | tr -d ' ')
  if [ "$ELAPSED" -lt 30 ] && [ "$N" -ge 1 ] && [ "$N" -le 50 ]; then
    pass "1400-row keyword pass in ${ELAPSED}s (n=$N)"
  else
    fail "1400-row keyword pass elapsed=${ELAPSED}s n=$N"
  fi
}

# ---- T21: bad resolve ids leave the database unchanged --------------------
{
  R="$TMP/guard"
  make_v4_db "$R"
  DB="$R/.claude/memory/memory.db"
  seed_contradiction "$DB"
  ID_PM=$(sqlite3 "$DB" "SELECT id FROM memories WHERE agent='pm' LIMIT 1;")
  BEFORE=$(sqlite3 "$DB" "SELECT COUNT(*) FROM memories WHERE archived=0; SELECT COUNT(*) FROM reconcile_log;")
  if bash "$LIB" resolve-pick "$DB" "$ID_PM" "$ID_PM" "pm" "tech-lead" "a" "b" 90 "same" >/dev/null 2>&1; then
    fail "winner=loser should exit non-zero"
  fi
  if bash "$LIB" resolve-pick "$DB" "$ID_PM" 999999 "pm" "tech-lead" "a" "b" 90 "missing" >/dev/null 2>&1; then
    fail "missing id should exit non-zero"
  fi
  AFTER=$(sqlite3 "$DB" "SELECT COUNT(*) FROM memories WHERE archived=0; SELECT COUNT(*) FROM reconcile_log;")
  if [ "$BEFORE" = "$AFTER" ]; then
    pass "rejected resolve leaves no partial state"
  else
    fail "rejected resolve mutated db (before=$BEFORE after=$AFTER)"
  fi
}

# ---- T22: merge drops the winner vector row --------------------------------
{
  R="$TMP/vecdrop"
  make_v4_db "$R"
  DB="$R/.claude/memory/memory.db"
  seed_contradiction "$DB"
  ID_PM=$(sqlite3 "$DB" "SELECT id FROM memories WHERE agent='pm' LIMIT 1;")
  ID_TL=$(sqlite3 "$DB" "SELECT id FROM memories WHERE agent='tech-lead' LIMIT 1;")
  sqlite3 "$DB" "CREATE TABLE vec_memories_384 (memory_id INTEGER, embedding BLOB);
    INSERT INTO vec_memories_384(memory_id, embedding) VALUES ($ID_PM, X'00');"
  bash "$LIB" resolve-merge "$DB" "$ID_PM" "$ID_TL" "pm" "tech-lead" \
    "a" "b" 88 "Merged body" "merged decision" >/dev/null
  LEFT=$(sqlite3 "$DB" "SELECT COUNT(*) FROM vec_memories_384 WHERE memory_id=$ID_PM;")
  if [ "$LEFT" = "0" ]; then
    pass "merge deletes the winner vector row"
  else
    fail "merge left vector rows=$LEFT"
  fi
}

# ---- T23: static — no unquoted id splice; command uses plugin-dir + LIMIT -
{
  if grep -n 'memory_id = \${' "$LIB" >/dev/null 2>&1 || grep -n '\${mid}' "$LIB" >/dev/null 2>&1; then
    fail "static: unquoted id interpolation remains in reconcile-lib.sh"
  else
    pass "static: reconcile-lib.sh does not splice \${mid}"
  fi
  MEM_MD="$PLUGIN_ROOT/commands/memory.md"
  if grep -n 'CLAUDE_PLUGIN_ROOT:-\$WTROOT' "$MEM_MD" >/dev/null 2>&1; then
    fail "static: memory.md still falls back to CLAUDE_PLUGIN_ROOT:-WTROOT"
  elif ! grep -n 'plugin-dir.sh" file skills/validate-memory/reconcile-lib.sh' "$MEM_MD" >/dev/null 2>&1; then
    fail "static: memory.md does not resolve reconcile-lib.sh via plugin-dir"
  elif ! grep -n 'LIMIT 100' "$MEM_MD" >/dev/null 2>&1; then
    fail "static: memory.md Step 2 has no LIMIT 100"
  else
    pass "static: memory.md resolves reconcile-lib and limits Step 2"
  fi
}

# ---- T24: deep-audit escapes a quote in the council handoff ---------------
{
  R="$TMP/esc"
  make_v4_db "$R"
  DB="$R/.claude/memory/memory.db"
  seed_contradiction "$DB"
  ID_PM=$(sqlite3 "$DB" "SELECT id FROM memories WHERE agent='pm' LIMIT 1;")
  ID_TL=$(sqlite3 "$DB" "SELECT id FROM memories WHERE agent='tech-lead' LIMIT 1;")
  OUT=$(bash "$LIB" resolve-deep-audit "$DB" "$ID_PM" "$ID_TL" "pm" "tech-lead" \
    'say "hello"' 'cost $1' 70 "needs council")
  if printf '%s\n' "$OUT" | grep -F 'say \"hello\"' >/dev/null && printf '%s\n' "$OUT" | grep -F 'cost \$1' >/dev/null; then
    pass "deep-audit escapes quotes and dollars"
  else
    fail "deep-audit escape (out=$OUT)"
  fi
}

# ---- T25: embed counts the vec table only after load_extension ------------
{
  PASS_PY="$SCRIPT_DIR/reconcile-pass.py"
  ORDER=$(awk '
    /def try_embed\(/ { on=1 }
    /def emit_candidates\(/ { on=0 }
    on && /load_vec_extension\(/ { if (!seen_count) loaded=1 }
    on && /SELECT COUNT\(\*\)/ { if (!loaded) bad=1; seen_count=1 }
    END { if (bad || !loaded || !seen_count) print "bad"; else print "ok" }
  ' "$PASS_PY")
  if [ "$ORDER" = "ok" ]; then
    pass "try_embed loads vec0 before counting the vec table"
  else
    fail "try_embed counts the vec table before load_extension"
  fi
}

# ---- summary --------------------------------------------------------------
echo ""
echo "Results: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
exit 0
