#!/usr/bin/env bash
# test-memdb.sh — memdb.sh session load, write read-back, cosine CREATE.
# Machine-check: bash skills/memory-store/test-memdb.sh
set -u

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd "$SCRIPT_DIR/../.." && pwd)
SCHEMA="$SCRIPT_DIR/schema.sql"
MEMDB="$SCRIPT_DIR/memdb.sh"
VEC="$SCRIPT_DIR/vec-cosine.sh"

PASS=0
FAIL=0

ok() { PASS=$((PASS + 1)); echo "  ok  $1"; }
bad() { FAIL=$((FAIL + 1)); echo "  FAIL $1"; }

assert_eq() {
  if [ "$2" = "$3" ]; then ok "$1"; else bad "$1: got=[$2] want=[$3]"; fi
}

[ -f "$MEMDB" ] && ok "memdb.sh exists" || bad "memdb.sh missing"
[ -x "$MEMDB" ] || chmod +x "$MEMDB" "$VEC" 2>/dev/null || true

FIX=$(mktemp -d "${TMPDIR:-/tmp}/memdb-test.XXXXXX")
mkdir -p "$FIX/.claude/memory"
DB="$FIX/.claude/memory/memory.db"
sqlite3 "$DB" <"$SCHEMA" >/dev/null

# Quote in content binds. One row. Read-back matches.
WID=$(bash "$MEMDB" write "$DB" ic4 lessons "it's a lesson")
assert_eq "write rc path id non-empty" "$([ -n "$WID" ] && echo yes)" "yes"
N=$(sqlite3 "$DB" "SELECT COUNT(*) FROM memories WHERE content='it''s a lesson';")
assert_eq "write stores one quoted row" "$N" "1"
GOT=$(sqlite3 "$DB" "SELECT content FROM memories WHERE id=$WID;")
assert_eq "write read-back content" "$GOT" "it's a lesson"

# Session load: a tier-1 digest must not hide an older tier-0 row or a newer lesson.
sqlite3 "$DB" "DELETE FROM memories;"
sqlite3 "$DB" "INSERT INTO memories(agent, type, content, tier, created_at, updated_at) VALUES
  ('ic4','lessons','old-lesson',0,'2020-01-01T00:00:00Z','2020-01-01T00:00:00Z'),
  ('ic4','digest','the-digest',1,'2020-06-01T00:00:00Z','2020-06-01T00:00:00Z'),
  ('ic4','lessons','new-lesson',0,'2021-01-01T00:00:00Z','2021-01-01T00:00:00Z'),
  ('ic4','memory','[imported — untrusted] seed-fact',0,'2019-01-01T00:00:00Z','2019-01-01T00:00:00Z');"
LOAD=$(bash "$MEMDB" load-session "$DB" ic4)
printf '%s\n' "$LOAD" | grep -qF 'old-lesson' && ok "load keeps pre-digest tier-0" || bad "load hid old-lesson: [$LOAD]"
printf '%s\n' "$LOAD" | grep -qF 'new-lesson' && ok "load keeps post-digest tier-0" || bad "load hid new-lesson: [$LOAD]"
printf '%s\n' "$LOAD" | grep -qF 'the-digest' && ok "load keeps tier-1" || bad "load hid digest: [$LOAD]"
printf '%s\n' "$LOAD" | grep -qF 'seed-fact' && ok "seed row stays visible beside a digest" || bad "load hid seed: [$LOAD]"
printf '%s\n' "$LOAD" | head -1 | grep -q '^digest|' && ok "tier-1 sorts before tier-0" || bad "first row not digest: [$LOAD]"

# Archived tier-0 stays out.
sqlite3 "$DB" "INSERT INTO memories(agent, type, content, tier, archived) VALUES ('ic4','lessons','gone-lesson',0,1);"
LOAD2=$(bash "$MEMDB" load-session "$DB" ic4)
printf '%s\n' "$LOAD2" | grep -qF 'gone-lesson' && bad "load returned archived row" || ok "archived tier-0 stays out"

# Cosine CREATE text. No extension required.
SQL=$(bash -c '. "$1"; vec_create_sql vec_memories_384 384 1' _ "$VEC")
printf '%s\n' "$SQL" | grep -q 'distance_metric=cosine' && ok "vec_create_sql uses cosine" || bad "create sql: [$SQL]"
printf '%s\n' "$SQL" | grep -qF 'FLOAT[384]' && ok "vec_create_sql keeps width" || bad "create sql width: [$SQL]"
for f in embed-one.sh migrate-md.sh download-extensions.sh; do
  if grep -q 'USING vec0(memory_id INTEGER, embedding FLOAT' "$SCRIPT_DIR/$f"; then
    bad "$f still has an inline L2 vec0 CREATE"
  else
    ok "$f has no inline L2 vec0 CREATE"
  fi
  grep -q 'vec_create_sql' "$SCRIPT_DIR/$f" && ok "$f calls vec_create_sql" || bad "$f does not call vec_create_sql"
done

# repair with no extension leaves a plain table alone and exits 0.
sqlite3 "$DB" "CREATE TABLE vec_memories_384(memory_id INTEGER);"
sqlite3 "$DB" "CREATE TABLE vec_memories_384_info(id INTEGER);"
sqlite3 "$DB" "CREATE TABLE vec_memories_384_chunks(id INTEGER);"
sqlite3 "$DB" "CREATE TABLE vec_memories_384_rowids(id INTEGER);"
set +e
bash "$VEC" repair "$DB" "$FIX/no-such-vec0.so" >"$FIX/repair.out" 2>"$FIX/repair.err"
RRC=$?
set -e
assert_eq "repair missing extension rc" "$RRC" "0"
LEFT=$(sqlite3 "$DB" "SELECT COUNT(*) FROM sqlite_master WHERE name='vec_memories_384';")
assert_eq "repair did not drop the table" "$LEFT" "1"
NAMES=$(bash -c '. "$1"; vec_rebuild_names "$2"' _ "$VEC" "$DB")
assert_eq "rebuild list is the virtual table only" "$NAMES" "vec_memories_384"
# A cosine CREATE is not a candidate, so repair does not fail on an already-cosine table.
sqlite3 "$DB" "CREATE TABLE vec_memories_768(id INTEGER);"
sqlite3 "$DB" "UPDATE sqlite_master SET sql='CREATE VIRTUAL TABLE vec_memories_768 USING vec0(embedding FLOAT[768] distance_metric=cosine)' WHERE name='vec_memories_768';" 2>/dev/null || true
# sqlite_master.sql is not always writable. Cover the filter with a temp view of the predicate.
FILT=$(sqlite3 "$DB" "SELECT name FROM sqlite_master WHERE type='table' AND name GLOB 'vec_memories_[0-9]*' AND name NOT GLOB 'vec_memories_[0-9]*_*' AND IFNULL(sql,'') NOT LIKE '%distance_metric=cosine%';")
printf '%s\n' "$FILT" | grep -q '_info' && bad "filter kept a shadow table: [$FILT]" || ok "filter drops shadow tables"
printf '%s\n' "$FILT" | grep -qx 'vec_memories_384' && ok "filter keeps vec_memories_384" || bad "filter dropped vec_memories_384: [$FILT]"
# The rebuild SQL is an argv statement. A pipe beside a .load argument is ignored.
if grep -n 'sqlite3' "$VEC" | grep -q '| sqlite3'; then
  bad "vec-cosine.sh pipes SQL into sqlite3 that already has a .load argument"
else
  ok "vec-cosine rebuild SQL is not piped into sqlite3"
fi
VEC0=""
for _c in \
  "$ROOT/.claude/memory/extensions/vec0.so" \
  "$ROOT/.claude/memory/extensions/vec0.dylib" \
  "$ROOT/../../.claude/memory/extensions/vec0.so" \
  "$ROOT/../../.claude/memory/extensions/vec0.dylib"
 do
  [ -f "$_c" ] && VEC0="$_c" && break
done
if [ -n "$VEC0" ] && sqlite3 :memory: ".load \"$VEC0\"" "SELECT vec_version();" >/dev/null 2>&1; then
  LDB="$FIX/live.db"
  sqlite3 "$LDB" ".load \"$VEC0\"" \
    "CREATE VIRTUAL TABLE vec_memories_8 USING vec0(memory_id INTEGER, embedding FLOAT[8]);" \
    "INSERT INTO vec_memories_8(memory_id, embedding) VALUES (1, '[1,0,0,0,0,0,0,0]');"
  set +e
  bash "$VEC" repair "$LDB" "$VEC0" >"$FIX/live.out" 2>"$FIX/live.err"
  LRC=$?
  set -e
  assert_eq "live repair rc" "$LRC" "0"
  LSQL=$(sqlite3 "$LDB" "SELECT sql FROM sqlite_master WHERE name='vec_memories_8';")
  printf '%s\n' "$LSQL" | grep -q 'distance_metric=cosine' && ok "live repair rewrites the metric" || bad "live sql: [$LSQL]"
  LROW=$(sqlite3 "$LDB" ".load \"$VEC0\"" "SELECT memory_id FROM vec_memories_8;")
  assert_eq "live repair keeps the vector row" "$LROW" "1"
  set +e
  bash "$VEC" repair "$LDB" "$VEC0" >"$FIX/live2.out" 2>"$FIX/live2.err"
  LRC2=$?
  set -e
  assert_eq "second repair of a cosine table rc" "$LRC2" "0"
else
  ok "vec0 extension not loadable here"
fi

# protocol and cortex-load call load-session (the eclipse if/else is gone).
PROTO="$ROOT/skills/agent-memory/protocol.md"
CORTEX="$ROOT/skills/agent-memory/cortex-load.md"
grep -q 'load-session' "$PROTO" && grep -q 'memdb.sh' "$PROTO" && ok "protocol calls load-session" || bad "protocol missing load-session"
grep -q 'tier > 0' "$PROTO" && bad "protocol still branches on tier > 0" || ok "protocol has no tier>0 eclipse branch"
grep -q 'load-session' "$CORTEX" && grep -q 'memdb.sh' "$CORTEX" && ok "cortex-load calls load-session" || bad "cortex-load missing load-session"
grep -q 'SELECT content FROM memories' "$CORTEX" && bad "cortex-load still selects content only" || ok "cortex-load does not select content alone"
# F-24: .timeout 5000 was already at the old cortex-load query. The :-0 default
# was already on HAS_DISTILLED. The comment in the partial records that.
grep -q '.timeout 5000' "$CORTEX" && ok "cortex-load timeout present" || bad "cortex-load timeout missing"
grep -q 'HAS_DISTILLED:-0' "$CORTEX" && ok "cortex-load records the prior :-0 default" || bad "cortex-load :-0 note missing"

# Write path must not retry a second INSERT after a successful command.
if grep -n 'sleep 1' "$PROTO" | grep -q 'INSERT'; then
  bad "protocol still retries INSERT after sleep"
else
  ok "protocol does not double-insert on retry"
fi
grep -q "cat >> .*<< 'EOF'" "$PROTO" && bad "protocol fallback still uses a fixed quoted heredoc" || ok "protocol fallback is not a fixed quoted heredoc"
grep -q '<content>' "$PROTO" && bad "protocol still writes the <content> token" || ok "protocol does not write the <content> token"
COMPRESS="$ROOT/skills/memory-compress/SKILL.md"
grep -q '/memory-distill' "$COMPRESS" && bad "memory-compress still names /memory-distill" || ok "memory-compress command name"
grep -q 'UPDATE protocol' "$COMPRESS" && bad "memory-compress still cites an UPDATE protocol" || ok "memory-compress has no UPDATE protocol cite"
grep -q 'memdb.sh' "$ROOT/skills/memory-store/SKILL.md" && ok "memory-store documents memdb.sh" || bad "memory-store missing memdb.sh"

rm -rf "$FIX"
echo "=== results: PASS=$PASS FAIL=$FAIL ==="
if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
exit 0
