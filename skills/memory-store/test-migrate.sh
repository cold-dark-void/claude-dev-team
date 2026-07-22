#!/usr/bin/env bash
# test-migrate.sh — bite tests for memory.db migrate driver (CDT-51 / SPEC-004).
# Machine-check: bash skills/memory-store/test-migrate.sh  (exit 0)
# THIS SCRIPT IS A SUBPROCESS CLI — NEVER SOURCE IT.
#
# Covers:
#   1. Fresh schema.sql → schema_version=4 + required tables + insert/read
#   2. v3→v4 floor upgrade via migrate.sh (seeded row intact)
#   3. Full v1→v4 chain via migrate.sh (in-repo migrate-v2/v3/v4)
#   4. Capture-safe contract: migrate.sh read_version has no inline PRAGMA

set -u

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SCHEMA="$SCRIPT_DIR/schema.sql"
MIGRATE="$SCRIPT_DIR/migrate.sh"
FIXDIR="$SCRIPT_DIR/fixtures/migrate"
V1_SQL="$FIXDIR/v1-minimal.sql"
V3_SQL="$FIXDIR/v3-minimal.sql"

PASS=0
FAIL=0

assert_eq() {
  local name="$1" got="$2" want="$3"
  if [ "$got" = "$want" ]; then
    PASS=$((PASS + 1)); echo "  ok  $name"
  else
    FAIL=$((FAIL + 1)); echo "  FAIL $name: got=[$got] want=[$want]"
  fi
}

assert_ok() {
  local name="$1"; shift
  if "$@"; then
    PASS=$((PASS + 1)); echo "  ok  $name"
  else
    FAIL=$((FAIL + 1)); echo "  FAIL $name (rc=$?)"
  fi
}

assert_file() {
  local name="$1" path="$2"
  if [ -f "$path" ]; then
    PASS=$((PASS + 1)); echo "  ok  $name"
  else
    FAIL=$((FAIL + 1)); echo "  FAIL $name: missing $path"
  fi
}

assert_contains() {
  local name="$1" hay="$2" needle="$3"
  if printf '%s' "$hay" | grep -qF -- "$needle"; then
    PASS=$((PASS + 1)); echo "  ok  $name"
  else
    FAIL=$((FAIL + 1)); echo "  FAIL $name: missing [$needle]"
  fi
}

assert_not_contains() {
  local name="$1" hay="$2" needle="$3"
  if printf '%s' "$hay" | grep -qF -- "$needle"; then
    FAIL=$((FAIL + 1)); echo "  FAIL $name: unexpected [$needle]"
  else
    PASS=$((PASS + 1)); echo "  ok  $name"
  fi
}

# Plain SELECT — mirrors migrate.sh read_version (no inline PRAGMA).
read_version() {
  local db="$1"
  sqlite3 "$db" "SELECT value FROM config WHERE key='schema_version';" 2>/dev/null || echo ""
}

table_exists() {
  local db="$1" table="$2"
  local n
  n=$(sqlite3 "$db" "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='$table';" 2>/dev/null || echo "0")
  [ "$n" = "1" ]
}

make_mroot() {
  local root="$1"
  mkdir -p "$root/.claude/memory"
}

if ! command -v sqlite3 &>/dev/null; then
  echo "SKIP: sqlite3 not in PATH" >&2
  exit 0
fi

assert_file "fixture v1-minimal.sql" "$V1_SQL"
assert_file "fixture v3-minimal.sql" "$V3_SQL"
assert_file "schema.sql" "$SCHEMA"
assert_file "migrate.sh" "$MIGRATE"

echo "=== test-migrate (SPEC-004 / CDT-51 AC3) ==="

# ---------- 1. Fresh schema.sql → v4 ----------
echo "-- T1 fresh schema.sql"
FIX=$(mktemp -d "${TMPDIR:-/tmp}/migrate-test-t1.XXXXXX")
make_mroot "$FIX"
DB="$FIX/.claude/memory/memory.db"
# schema.sql PRAGMA lines print to stdout — silence
sqlite3 "$DB" < "$SCHEMA" >/dev/null
VER=$(read_version "$DB")
assert_eq "T1 schema_version=4" "$VER" "4"
for t in memories config distillation_log validation_log reconcile_log embedding_meta; do
  if table_exists "$DB" "$t"; then
    PASS=$((PASS + 1)); echo "  ok  T1 table $t"
  else
    FAIL=$((FAIL + 1)); echo "  FAIL T1 table $t missing"
  fi
done
# insert + read round-trip (PRAGMA in same session for write path; silence its result row)
sqlite3 "$DB" "PRAGMA busy_timeout=5000;
INSERT INTO memories(agent, type, content) VALUES ('ic4', 'memory', 'fresh-roundtrip');
" >/dev/null
GOT=$(sqlite3 "$DB" "SELECT content FROM memories WHERE agent='ic4' AND content='fresh-roundtrip';")
assert_eq "T1 insert+read round-trip" "$GOT" "fresh-roundtrip"
rm -rf "$FIX"

# ---------- 2. v3 → v4 floor via migrate.sh ----------
echo "-- T2 v3→v4 floor"
FIX=$(mktemp -d "${TMPDIR:-/tmp}/migrate-test-t2.XXXXXX")
make_mroot "$FIX"
DB="$FIX/.claude/memory/memory.db"
sqlite3 "$DB" < "$V3_SQL" >/dev/null
assert_eq "T2 pre schema_version=3" "$(read_version "$DB")" "3"
SEED=$(sqlite3 "$DB" "SELECT content FROM memories WHERE content LIKE 'v3-seed-row:%';")
assert_contains "T2 pre seed present" "$SEED" "v3-seed-row:"
OUT=$(bash "$MIGRATE" "$FIX" 2>&1) || true
assert_contains "T2 migrate reports latest" "$OUT" "Schema migrated to v4"
assert_eq "T2 post schema_version=4" "$(read_version "$DB")" "4"
if table_exists "$DB" "reconcile_log"; then
  PASS=$((PASS + 1)); echo "  ok  T2 reconcile_log exists"
else
  FAIL=$((FAIL + 1)); echo "  FAIL T2 reconcile_log missing"
fi
CAP=$(sqlite3 "$DB" "SELECT value FROM config WHERE key='reconcile_pair_cap';" 2>/dev/null || echo "")
assert_eq "T2 reconcile_pair_cap=50" "$CAP" "50"
SEED_AFTER=$(sqlite3 "$DB" "SELECT content FROM memories WHERE content LIKE 'v3-seed-row:%';")
assert_eq "T2 seeded row intact" "$SEED_AFTER" "$SEED"
rm -rf "$FIX"

# ---------- 3. Full v1 → v4 chain ----------
echo "-- T3 full v1→v4 chain"
FIX=$(mktemp -d "${TMPDIR:-/tmp}/migrate-test-t3.XXXXXX")
make_mroot "$FIX"
DB="$FIX/.claude/memory/memory.db"
sqlite3 "$DB" < "$V1_SQL" >/dev/null
assert_eq "T3 pre schema_version=1" "$(read_version "$DB")" "1"
SEED=$(sqlite3 "$DB" "SELECT content FROM memories WHERE content LIKE 'v1-seed-row:%';")
assert_contains "T3 pre seed present" "$SEED" "v1-seed-row:"
OUT=$(bash "$MIGRATE" "$FIX" 2>&1) || true
assert_contains "T3 step v1→v2" "$OUT" "Migrating schema v1 -> v2"
assert_contains "T3 step v2→v3" "$OUT" "Migrating schema v2 -> v3"
assert_contains "T3 step v3→v4" "$OUT" "Migrating schema v3 -> v4"
assert_contains "T3 migrate reports latest" "$OUT" "Schema migrated to v4"
assert_eq "T3 post schema_version=4" "$(read_version "$DB")" "4"
for t in distillation_log validation_log reconcile_log; do
  if table_exists "$DB" "$t"; then
    PASS=$((PASS + 1)); echo "  ok  T3 table $t"
  else
    FAIL=$((FAIL + 1)); echo "  FAIL T3 table $t missing"
  fi
done
# v1→v2 defaults
TIER=$(sqlite3 "$DB" "SELECT tier FROM memories WHERE content LIKE 'v1-seed-row:%';")
ARCH=$(sqlite3 "$DB" "SELECT archived FROM memories WHERE content LIKE 'v1-seed-row:%';")
assert_eq "T3 seeded tier=0" "$TIER" "0"
# SQLite may report 0/1 for boolean
case "$ARCH" in
  0|false|FALSE) PASS=$((PASS + 1)); echo "  ok  T3 seeded archived=false ($ARCH)" ;;
  *) FAIL=$((FAIL + 1)); echo "  FAIL T3 seeded archived: got=[$ARCH] want=0/false" ;;
esac
SEED_AFTER=$(sqlite3 "$DB" "SELECT content FROM memories WHERE content LIKE 'v1-seed-row:%';")
assert_eq "T3 seeded row intact" "$SEED_AFTER" "$SEED"
# already at LATEST is no-op
OUT2=$(bash "$MIGRATE" "$FIX" 2>&1) || true
assert_contains "T3 re-run up to date" "$OUT2" "up to date"
assert_eq "T3 re-run still v4" "$(read_version "$DB")" "4"
rm -rf "$FIX"

# ---------- 4. Capture-safe contract (PRAGMA-poison) ----------
echo "-- T4 capture-safe read_version"
# Extract the body of read_version() from migrate.sh and assert the captured
# sqlite3 SELECT has no inline PRAGMA (would pollute the version string).
RV_BODY=$(awk '
  /^read_version\(\)/ { in_fn=1; next }
  in_fn && /^}/ { exit }
  in_fn { print }
' "$MIGRATE")
assert_contains "T4 read_version SELECT schema_version" "$RV_BODY" "SELECT value FROM config WHERE key='schema_version'"
# The captured sqlite3 invocation must not prefix PRAGMA busy_timeout
if printf '%s' "$RV_BODY" | grep -E 'sqlite3[^;]*PRAGMA[[:space:]]+busy_timeout' >/dev/null; then
  FAIL=$((FAIL + 1)); echo "  FAIL T4 inline PRAGMA in captured SELECT"
else
  PASS=$((PASS + 1)); echo "  ok  T4 no inline PRAGMA in captured SELECT"
fi
# Negative proof: inline PRAGMA emits a result row that would poison $(...) capture
POISON_FIX=$(mktemp -d "${TMPDIR:-/tmp}/migrate-test-t4.XXXXXX")
make_mroot "$POISON_FIX"
POISON_DB="$POISON_FIX/.claude/memory/memory.db"
sqlite3 "$POISON_DB" < "$SCHEMA" >/dev/null
POISONED=$(sqlite3 "$POISON_DB" "PRAGMA busy_timeout=5000; SELECT value FROM config WHERE key='schema_version';" 2>/dev/null || echo "")
# busy_timeout PRAGMA returns the timeout value as a row → multi-line / polluted
case "$POISONED" in
  *$'\n'*|5000*)
    PASS=$((PASS + 1)); echo "  ok  T4 negative: inline PRAGMA pollutes capture"
    ;;
  *)
    # Some sqlite builds may suppress PRAGMA result; still assert plain SELECT is clean
    PLAIN=$(sqlite3 "$POISON_DB" "SELECT value FROM config WHERE key='schema_version';")
    if [ "$PLAIN" = "4" ] && [ "$POISONED" = "4" ]; then
      PASS=$((PASS + 1)); echo "  ok  T4 negative: plain SELECT clean (PRAGMA silent on this build)"
    else
      FAIL=$((FAIL + 1)); echo "  FAIL T4 negative poison check: poisoned=[$POISONED]"
    fi
    ;;
esac
PLAIN=$(sqlite3 "$POISON_DB" "SELECT value FROM config WHERE key='schema_version';")
assert_eq "T4 plain SELECT returns 4" "$PLAIN" "4"
rm -rf "$POISON_FIX"

# ---------- summary ----------
echo "=== results: PASS=$PASS FAIL=$FAIL ==="
if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
exit 0
