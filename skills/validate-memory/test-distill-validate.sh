#!/usr/bin/env bash
# WP 2-07: distill lock ownership, scaled staleness score, atomic distill commit,
# deep rebuild that archives only after success, extraction coverage, sqlite timeout.
set -u
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
SCHEMA="$ROOT/skills/memory-store/schema.sql"
LOCK="$ROOT/skills/memory-store/distill-lock.sh"
COMMIT="$ROOT/skills/memory-store/distill-commit.sh"
DEEP="$ROOT/skills/memory-store/deep-rebuild.sh"
SCORE="$ROOT/skills/validate-memory/score.sh"
EXTRACT="$ROOT/skills/validate-memory/check-extraction.sh"
PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); echo "PASS: $1"; }
bad() { FAIL=$((FAIL + 1)); echo "FAIL: $1"; }

need() {
  if [ -f "$1" ]; then ok "present $1"
  else bad "missing $1"; fi
}
need "$LOCK"
need "$COMMIT"
need "$DEEP"
need "$SCORE"
need "$EXTRACT"

newdb() {
  local d
  d=$(mktemp -d "${TMPDIR:-/tmp}/distill-val.XXXXXX")
  mkdir -p "$d/.claude/memory"
  sqlite3 "$d/.claude/memory/memory.db" <"$SCHEMA" >/dev/null
  printf '%s\n' "$d"
}

if [ -x "$SCORE" ] || [ -f "$SCORE" ]; then
  s=$(bash "$SCORE" 0 0 CONTRADICTED:90)
  if [ "$s" -gt 80 ]; then ok "deleted-file score $s is above 80"
  else bad "deleted-file score $s is not above 80"; fi
  s0=$(bash "$SCORE" 0 0 VALID:100)
  if [ "$s0" = 0 ]; then ok "all-valid score is 0"
  else bad "all-valid score is $s0"; fi
else
  bad "score.sh not runnable"
fi

if [ -f "$LOCK" ]; then
  D=$(newdb)
  DB="$D/.claude/memory/memory.db"
  A=$(bash "$LOCK" acquire "$DB")
  RC=0
  bash "$LOCK" acquire "$DB" >/dev/null 2>"$D/held.err" || RC=$?
  if [ "$RC" = 75 ] && [ "$(sqlite3 "$DB" "SELECT value FROM config WHERE key='distilling_lock';")" = "$A" ]; then
    ok "a fresh lock blocks a second acquire"
  else
    bad "second acquire rc=$RC"
  fi
  bash "$LOCK" release "$DB" "distill-other"
  if [ "$(sqlite3 "$DB" "SELECT value FROM config WHERE key='distilling_lock';")" = "$A" ]; then
    ok "a release without the token leaves the lock"
  else
    bad "wrong token cleared the lock"
  fi
  GRC=0
  LOCK_OUT=$(bash "$LOCK" guard "$DB" "") || GRC=$?
  if [ "$GRC" = 1 ]; then ok "a foreign lock blocks validate"
  else bad "guard on a foreign lock rc=$GRC out=$LOCK_OUT"; fi
  GRC=0
  bash "$LOCK" guard "$DB" "$A" || GRC=$?
  if [ "$GRC" = 0 ]; then ok "the lock owner may validate"
  else bad "owner guard rc=$GRC"; fi
  bash "$LOCK" release "$DB" "$A"
  if [ -z "$(sqlite3 "$DB" "SELECT value FROM config WHERE key='distilling_lock';")" ]; then
    ok "the owner release clears the lock"
  else
    bad "owner release left a lock"
  fi
  sqlite3 "$DB" "UPDATE config SET value='distill-1' WHERE key='distilling_lock';"
  B=$(bash "$LOCK" acquire "$DB")
  if [ -n "$B" ] && [ "$B" != "distill-1" ]; then ok "a stale lock can be taken"
  else bad "stale acquire got [$B]"; fi
  rm -rf "$D"
fi

if [ -f "$COMMIT" ]; then
  D=$(newdb)
  DB="$D/.claude/memory/memory.db"
  sqlite3 "$DB" "INSERT INTO memories(agent, type, content) VALUES ('pm','memory','source one'), ('pm','memory','source two');"
  ID=$(bash "$COMMIT" "$DB" pm "O'Brien kept the quote" 1 2)
  PACK=$(sqlite3 "$DB" "SELECT distilled_from FROM memories WHERE id=$ID;")
  GOT=$(sqlite3 "$DB" "SELECT content FROM memories WHERE id=$ID;")
  ARCH=$(sqlite3 "$DB" "SELECT COUNT(*) FROM memories WHERE id IN (1,2) AND archived=1 AND archive_reason='distilled';")
  LOGN=$(sqlite3 "$DB" "SELECT COUNT(*) FROM distillation_log WHERE result_memory_id=$ID;")
  if [ "$GOT" = "O'Brien kept the quote" ] && [ "$ARCH" = 2 ] && [ "$LOGN" = 1 ] && [ "$PACK" = "[1,2]" ]; then
    ok "distill commit stores the quote and archives sources"
  else
    bad "commit got=[$GOT] arch=$ARCH log=$LOGN pack=$PACK"
  fi
  D2=$(newdb)
  DB2="$D2/.claude/memory/memory.db"
  sqlite3 "$DB2" "INSERT INTO memories(agent, type, content) VALUES ('pm','memory','keep me');"
  FRC=0
  DISTILL_FAIL_AFTER=insert bash "$COMMIT" "$DB2" pm "should roll back" 1 >/dev/null 2>"$D2/err" || FRC=$?
  LEFT=$(sqlite3 "$DB2" "SELECT COUNT(*) FROM memories WHERE content='should roll back';")
  STILL=$(sqlite3 "$DB2" "SELECT archived FROM memories WHERE id=1;")
  if [ "$FRC" != 0 ] && [ "$LEFT" = 0 ] && [ "$STILL" = 0 ]; then
    ok "a failure after insert rolls the commit back"
  else
    bad "rollback rc=$FRC left=$LEFT archived=$STILL"
  fi
  rm -rf "$D" "$D2"
fi

if [ -f "$DEEP" ]; then
  D=$(newdb)
  DB="$D/.claude/memory/memory.db"
  sqlite3 "$DB" "INSERT INTO memories(id, agent, type, content) VALUES (1,'pm','memory','source');"
  sqlite3 "$DB" "INSERT INTO memories(id, agent, type, content, tier, distilled_from) VALUES (7,'pm','digest','old digest',1,'[1]');"
  FRC=0
  bash "$DEEP" "$DB" 7 fail >/dev/null 2>"$D/deep.err" || FRC=$?
  LIVE=$(sqlite3 "$DB" "SELECT archived FROM memories WHERE id=7;")
  if [ "$FRC" != 0 ] && [ "$LIVE" = 0 ]; then ok "deep failure leaves the digest live"
  else bad "deep fail rc=$FRC archived=$LIVE"; fi
  bash "$DEEP" "$DB" 7 content "new digest" >/dev/null
  OLD=$(sqlite3 "$DB" "SELECT archive_reason FROM memories WHERE id=7;")
  NEW=$(sqlite3 "$DB" "SELECT COUNT(*) FROM memories WHERE content='new digest' AND tier=1 AND archived=0;")
  if [ "$OLD" = "stale" ] && [ "$NEW" = 1 ]; then ok "deep success archives only after the new digest exists"
  else bad "deep success old=$OLD new=$NEW"; fi
  D3=$(newdb)
  DB3="$D3/.claude/memory/memory.db"
  sqlite3 "$DB3" "INSERT INTO memories(id, agent, type, content, archived, archive_reason) VALUES (2,'pm','memory','stale source',1,'stale');"
  sqlite3 "$DB3" "INSERT INTO memories(id, agent, type, content, tier, distilled_from) VALUES (8,'pm','digest','keep me',1,'[2]');"
  FRC=0
  bash "$DEEP" "$DB3" 8 content "should not land" >/dev/null 2>"$D3/err" || FRC=$?
  STILL=$(sqlite3 "$DB3" "SELECT archived FROM memories WHERE id=8;")
  MARK=$(sqlite3 "$DB3" "SELECT archive_reason FROM memories WHERE id=2;")
  if [ "$FRC" != 0 ] && [ "$STILL" = 0 ] && [ "$MARK" = "stale" ]; then
    ok "deep rebuild does not archive when every source is stale"
  else
    bad "all-stale deep rc=$FRC digest=$STILL source=$MARK"
  fi
  rm -rf "$D" "$D3"
fi

if [ -f "$EXTRACT" ]; then
  ERC=0
  printf '%s\n' '{"extractions":[{"memory_id":1,"claims":[]}]}' | bash "$EXTRACT" 1 2 >/dev/null 2>"${TMPDIR:-/tmp}/dv-extract.err" || ERC=$?
  if [ "$ERC" != 0 ]; then ok "extraction rejects a missing memory id"
  else bad "extraction accepted a missing id"; fi
  ERC=0
  printf '%s\n' '{"extractions":[{"memory_id":1,"claims":[]},{"memory_id":2,"claims":[],"skip_reason":"none"}]}' | bash "$EXTRACT" 1 2 || ERC=$?
  if [ "$ERC" = 0 ]; then ok "extraction accepts one entry per input id"
  else bad "extraction rejected a complete set rc=$ERC"; fi
fi

MEM="$ROOT/commands/memory.md"
if grep -q 'distill-lock.sh guard' "$MEM" && grep -q 'deep-rebuild.sh' "$MEM" && grep -q 'score.sh' "$MEM" && grep -q 'check-extraction.sh' "$MEM"; then
  ok "memory.md calls the lock guard, the score helper, deep-rebuild, and extraction check"
else
  bad "memory.md is missing a helper call"
fi
if grep -q 'plugin-dir.sh' "$ROOT/agents/distiller.md" && grep -q 'distill-commit.sh' "$ROOT/agents/distiller.md"; then
  ok "distiller resolves distill-commit.sh through plugin-dir"
else
  bad "distiller does not resolve distill-commit.sh outside the consumer repo"
fi
if grep -q 'scaled = raw_score \* 100 / 40' "$ROOT/skills/validate-memory/SKILL.md"; then
  ok "the score formula scales 0-40 up to 0-100"
else
  bad "score formula is still capped at 40"
fi
if grep -q 'Every input memory id' "$ROOT/skills/validate-memory/SKILL.md"; then
  ok "extractor rule requires every input id"
else
  bad "extractor rule still allows a dropped memory"
fi
if grep -q 'distill-commit.sh' "$ROOT/agents/distiller.md" && ! grep -q "s/'/''/g" "$ROOT/agents/distiller.md"; then
  ok "distiller commits in one call and does not sed-escape"
else
  bad "distiller still uses a split insert or sed escaping"
fi

# Every sqlite3 "$MEMDB" in product skills, commands, and agents carries .timeout.
MISS=0
while IFS= read -r line; do
  case "$line" in
    *fixtures/*|*skill-lint/fixtures/*) continue ;;
  esac
  file=${line%%:*}
  base=$(basename "$file")
  case "$base" in
    test.sh|test-*.sh|*-test.sh) continue ;;
  esac
  body=${line#*:}
  case "$body" in
    *".timeout"*) continue ;;
    *"command -v sqlite3"*) continue ;;
    *"have_cmd sqlite3"*) continue ;;
    *'sqlite3'*'"$MEMDB"'*) MISS=$((MISS + 1)); echo "NO-TIMEOUT $line" ;;
  esac
done < <(grep -n 'sqlite3' "$ROOT/skills" "$ROOT/commands" "$ROOT/agents" -r --include='*.md' --include='*.sh' || true)
if [ "$MISS" = 0 ]; then ok "sqlite3 \$MEMDB uses .timeout"
else bad "sqlite3 \$MEMDB missing .timeout ($MISS)"; fi

echo "---"
echo "distill-validate: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
