#!/usr/bin/env bash
# test-seed-pack.sh — bite tests for SPEC-024 seed pack export/import (CDV-194).
# Machine-check: bash skills/memory-store/test-seed-pack.sh  (exit 0)
# THIS SCRIPT IS A SUBPROCESS CLI — NEVER SOURCE IT.

set -u

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
PLUGIN_ROOT=$(cd "$SCRIPT_DIR/../.." && pwd)
EXPORT="$SCRIPT_DIR/export-seed-pack.sh"
IMPORT="$SCRIPT_DIR/import-seed-pack.sh"
COMMON="$SCRIPT_DIR/seed-common.sh"
SCHEMA="$SCRIPT_DIR/schema.sql"

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

# shellcheck source=seed-common.sh
. "$COMMON"

# --- fixture helpers ---
make_fixture() {
  local root="$1"
  mkdir -p "$root/.claude/memory"
  # minimal git repo so check-ignore / ensure_seed_gitignore work
  git -C "$root" init -q
  git -C "$root" config user.email "test@example.com"
  git -C "$root" config user.name "test"
  # Isolate from developer global excludes (e.g. ~/.gitignore with .claude/)
  git -C "$root" config core.excludesFile /dev/null
  printf '%s\n' "# fixture" ".claude/memory/" > "$root/.gitignore"
  # schema.sql PRAGMA lines print to stdout — silence
  sqlite3 "$root/.claude/memory/memory.db" < "$SCHEMA" >/dev/null
}

insert_tier2() {
  local db="$1" agent="$2" content="$3" id_out="${4:-}"
  local esc mid
  esc=$(printf '%s' "$content" | sed "s/'/''/g")
  mid=$(sqlite3 "$db" "PRAGMA busy_timeout=5000;
INSERT INTO memories(agent, type, content, tier, distilled_from)
VALUES ('$agent', 'core', '$esc', 2, '[]');
SELECT last_insert_rowid();")
  if [ -n "$id_out" ]; then
    eval "$id_out=$mid"
  fi
}

echo "=== test-seed-pack (SPEC-024) ==="

# ---------- 1. Deterministic double-export ----------
echo "-- M1 deterministic export"
FIX=$(mktemp -d "${TMPDIR:-/tmp}/seed-test-m1.XXXXXX")
make_fixture "$FIX"
insert_tier2 "$FIX/.claude/memory/memory.db" "ic5" "Chose SQLite over Postgres for local agent memory simplicity."
insert_tier2 "$FIX/.claude/memory/memory.db" "pm" "Acceptance criteria live in specs/ MUST section only."
bash "$EXPORT" --limit 40 "$FIX" >/dev/null
cp -a "$FIX/.claude/memory/seed" "$FIX/seed-copy1"
bash "$EXPORT" --limit 40 "$FIX" >/dev/null
if diff -rq "$FIX/.claude/memory/seed" "$FIX/seed-copy1" >/dev/null; then
  PASS=$((PASS + 1)); echo "  ok  M1 double-export identical"
else
  FAIL=$((FAIL + 1)); echo "  FAIL M1 double-export differs"
  diff -u "$FIX/seed-copy1/manifest.json" "$FIX/.claude/memory/seed/manifest.json" || true
fi
assert_file "M1 ic5.md" "$FIX/.claude/memory/seed/ic5.md"
assert_file "M1 pm.md" "$FIX/.claude/memory/seed/pm.md"
assert_file "M1 manifest" "$FIX/.claude/memory/seed/manifest.json"
assert_contains "M1 format_version" "$(cat "$FIX/.claude/memory/seed/manifest.json")" '"format_version": 1'
rm -rf "$FIX"

# ---------- 2. Sanitize exclude + path rewrite ----------
echo "-- M2 sanitization"
FIX=$(mktemp -d "${TMPDIR:-/tmp}/seed-test-m2.XXXXXX")
make_fixture "$FIX"
insert_tier2 "$FIX/.claude/memory/memory.db" "ic5" "Secret key AKIAIOSFODNN7EXAMPLE must never ship."
insert_tier2 "$FIX/.claude/memory/memory.db" "ic5" "Home path /home/someone/.ssh/id_rsa is local only."
insert_tier2 "$FIX/.claude/memory/memory.db" "ic5" "Schema lives at $FIX/skills/memory-store/schema.sql for migrations."
OUT=$(bash "$EXPORT" --agent ic5 "$FIX" 2>&1)
assert_contains "M2 exclude AWS" "$OUT" "AWS access key"
assert_contains "M2 exclude home" "$OUT" "absolute path"
# rewritten project path should be included (repo-relative)
if [ -f "$FIX/.claude/memory/seed/ic5.md" ]; then
  BODY=$(cat "$FIX/.claude/memory/seed/ic5.md")
  assert_contains "M2 rewritten path" "$BODY" "skills/memory-store/schema.sql"
  if printf '%s' "$BODY" | grep -qF "$FIX"; then
    FAIL=$((FAIL + 1)); echo "  FAIL M2 absolute root still present"
  else
    PASS=$((PASS + 1)); echo "  ok  M2 no absolute project root in pack"
  fi
else
  FAIL=$((FAIL + 1)); echo "  FAIL M2 expected ic5.md with rewritten path entry"
fi
rm -rf "$FIX"

# ---------- 3. Trailer hash round-trip ----------
echo "-- M3 trailer hash"
FIX=$(mktemp -d "${TMPDIR:-/tmp}/seed-test-m3.XXXXXX")
make_fixture "$FIX"
insert_tier2 "$FIX/.claude/memory/memory.db" "qa" "Always run bite tests before marking task complete."
bash "$EXPORT" --agent qa "$FIX" >/dev/null
ENTRY=$(cat "$FIX/.claude/memory/seed/qa.md")
TRAILER=$(printf '%s' "$ENTRY" | tail -n1)
SEED_HASH=""; SEED_PROJECT=""; SEED_DATE=""; SEED_TIER=""; SEED_AGENT=""
if seed_parse_trailer "$TRAILER"; then
  PASS=$((PASS + 1)); echo "  ok  M3 trailer parses"
else
  FAIL=$((FAIL + 1)); echo "  FAIL M3 trailer parse: $TRAILER"
fi
BODY=$(seed_strip_trailer "$ENTRY")
REHASH=$(seed_content_hash "$BODY")
assert_eq "M3 hash matches" "$REHASH" "$SEED_HASH"
rm -rf "$FIX"

# ---------- 4. Import then re-import → skipped-duplicate ----------
echo "-- M6 idempotent re-import"
FIX=$(mktemp -d "${TMPDIR:-/tmp}/seed-test-m6.XXXXXX")
make_fixture "$FIX"
insert_tier2 "$FIX/.claude/memory/memory.db" "devops" "CI uses GitHub Actions with matrix for linux/macos."
bash "$EXPORT" --agent devops "$FIX" >/dev/null
# wipe DB rows but keep pack — simulate fresh clone with pack
sqlite3 "$FIX/.claude/memory/memory.db" "DELETE FROM memories;"
OUT1=$(bash "$IMPORT" "$FIX" 2>&1)
assert_contains "M6 first import" "$OUT1" "imported=1"
OUT2=$(bash "$IMPORT" "$FIX" 2>&1)
assert_contains "M6 reimport skipped-dup" "$OUT2" "skipped-duplicate=1"
assert_contains "M6 reimport zero new" "$OUT2" "imported=0"
CNT=$(sqlite3 "$FIX/.claude/memory/memory.db" "SELECT COUNT(*) FROM memories WHERE tier=1;")
assert_eq "M6 single row" "$CNT" "1"
TIER=$(sqlite3 "$FIX/.claude/memory/memory.db" "SELECT tier||'|'||type||'|'||IFNULL(validated_at,'NULL') FROM memories LIMIT 1;")
assert_eq "M6 tier/type/validated" "$TIER" "1|digest|NULL"
rm -rf "$FIX"

# ---------- 5. Archived seed not resurrected ----------
echo "-- M6 archived not resurrected"
FIX=$(mktemp -d "${TMPDIR:-/tmp}/seed-test-m6b.XXXXXX")
make_fixture "$FIX"
insert_tier2 "$FIX/.claude/memory/memory.db" "ds" "Metrics rollup lives in skills/metrics/."
bash "$EXPORT" --agent ds "$FIX" >/dev/null
sqlite3 "$FIX/.claude/memory/memory.db" "DELETE FROM memories;"
bash "$IMPORT" "$FIX" >/dev/null
sqlite3 "$FIX/.claude/memory/memory.db" "UPDATE memories SET archived=1, archive_reason='stale';"
OUT=$(bash "$IMPORT" "$FIX" 2>&1)
assert_contains "M6 skipped-archived" "$OUT" "skipped-archived=1"
CNT=$(sqlite3 "$FIX/.claude/memory/memory.db" "SELECT COUNT(*) FROM memories;")
assert_eq "M6 still one row" "$CNT" "1"
ARCH=$(sqlite3 "$FIX/.claude/memory/memory.db" "SELECT archived FROM memories LIMIT 1;")
assert_eq "M6 stays archived" "$ARCH" "1"
rm -rf "$FIX"

# ---------- 6. Bad secret in pack → rejected; exit 0 ----------
echo "-- M8 bad secret rejected"
FIX=$(mktemp -d "${TMPDIR:-/tmp}/seed-test-m8a.XXXXXX")
make_fixture "$FIX"
insert_tier2 "$FIX/.claude/memory/memory.db" "ic4" "Follow existing patterns in skills/ before inventing new ones."
bash "$EXPORT" --agent ic4 "$FIX" >/dev/null
# inject secret into pack entry body
python3 - "$FIX/.claude/memory/seed/ic4.md" "$FIX/.claude/memory/seed/manifest.json" <<'PY'
import hashlib, json, pathlib, sys
p = pathlib.Path(sys.argv[1])
text = p.read_text()
# append secret mid-body before trailer
lines = text.rstrip("\n").split("\n")
trailer = lines[-1]
body = "\n".join(lines[:-1]) + "\nSecret: AKIAIOSFODNN7EXAMPLE\n"
# leave trailer as-is so hash check fails OR recompute — we want sanitize reject;
# recompute trailer hash so hash check passes and sanitize catches it
import re, subprocess, os
# normalize + hash via same rules as seed_content_hash: use sha256 of normalized
def norm(t):
    ls = [ln.rstrip() for ln in t.replace("\r\n","\n").replace("\r","\n").split("\n")]
    while ls and ls[-1]=="": ls.pop()
    return "\n".join(ls) + "\n"
nb = norm(body)
h = hashlib.sha256(nb.encode()).hexdigest()[:12]
# rewrite trailer hash=
new_trailer = re.sub(r"hash=[a-f0-9]{12}", f"hash={h}", trailer)
p.write_text(nb + new_trailer + "\n")
# update manifest file hash
mp = pathlib.Path(sys.argv[2])
m = json.loads(mp.read_text())
fh = hashlib.sha256(p.read_bytes()).hexdigest()
m["files"]["ic4.md"]["content_hash"] = fh
mp.write_text(json.dumps(m, sort_keys=True, indent=2) + "\n")
PY
sqlite3 "$FIX/.claude/memory/memory.db" "DELETE FROM memories;"
set +e
OUT=$(bash "$IMPORT" "$FIX" 2>&1)
RC=$?
set -e
assert_eq "M8 exit 0 on secret" "$RC" "0"
assert_contains "M8 rejected" "$OUT" "rejected=1"
CNT=$(sqlite3 "$FIX/.claude/memory/memory.db" "SELECT COUNT(*) FROM memories;")
assert_eq "M8 no rows" "$CNT" "0"
rm -rf "$FIX"

# ---------- 7. Manifest hash mismatch → skip; exit 0 ----------
echo "-- M8 manifest hash mismatch"
FIX=$(mktemp -d "${TMPDIR:-/tmp}/seed-test-m8b.XXXXXX")
make_fixture "$FIX"
insert_tier2 "$FIX/.claude/memory/memory.db" "tech-lead" "Worktrees live under .worktrees/<slug> via worktree-lib.sh."
bash "$EXPORT" --agent tech-lead "$FIX" >/dev/null
python3 - "$FIX/.claude/memory/seed/manifest.json" <<'PY'
import json,sys
p=sys.argv[1]
m=json.load(open(p))
for k in m["files"]:
    m["files"][k]["content_hash"]="0"*64
json.dump(m, open(p,"w"), sort_keys=True, indent=2)
open(p,"a").write("\n")
PY
sqlite3 "$FIX/.claude/memory/memory.db" "DELETE FROM memories;"
set +e
OUT=$(bash "$IMPORT" "$FIX" 2>&1)
RC=$?
set -e
assert_eq "M8b exit 0" "$RC" "0"
assert_contains "M8b hash mismatch warn" "$OUT" "hash mismatch"
CNT=$(sqlite3 "$FIX/.claude/memory/memory.db" "SELECT COUNT(*) FROM memories;")
assert_eq "M8b no import" "$CNT" "0"
rm -rf "$FIX"

# ---------- 8. git check-ignore seed vs db ----------
echo "-- M9 gitignore carve-out"
FIX=$(mktemp -d "${TMPDIR:-/tmp}/seed-test-m9.XXXXXX")
make_fixture "$FIX"
insert_tier2 "$FIX/.claude/memory/memory.db" "pm" "Ship the smallest PR that proves the MUST."
bash "$EXPORT" --agent pm "$FIX" >/dev/null
set +e
git -C "$FIX" -c core.excludesFile=/dev/null check-ignore -q .claude/memory/seed/pm.md
RC_SEED=$?
git -C "$FIX" -c core.excludesFile=/dev/null check-ignore -q .claude/memory/memory.db
RC_DB=$?
set -e
assert_eq "M9 seed not ignored" "$RC_SEED" "1"
assert_eq "M9 db ignored" "$RC_DB" "0"
# export must not create git commits
COMMITS=$(git -C "$FIX" rev-list --count HEAD 2>/dev/null || echo 0)
# fresh init has 0 commits
assert_eq "M9 no auto-commit" "$COMMITS" "0"
rm -rf "$FIX"

# ---------- 9. Fallback export/import line caps ----------
echo "-- M10 fallback mode"
FIX=$(mktemp -d "${TMPDIR:-/tmp}/seed-test-m10.XXXXXX")
mkdir -p "$FIX/.claude/memory/ic5"
git -C "$FIX" init -q
printf '%s\n' ".claude/memory/*" "!.claude/memory/seed/" "!.claude/memory/seed/**" > "$FIX/.gitignore"
# no sqlite db → fallback
printf '%s\n' "Core fact: agents write tier 0 only." "Lesson: never skip YAML frontmatter." > "$FIX/.claude/memory/ic5/cortex.md"
printf '%s\n' "Anti-pattern: giant blob memory rows defeat retrieval." > "$FIX/.claude/memory/ic5/lessons.md"
# Force fallback by ensuring no db (and hide sqlite? we just omit db)
OUT=$(bash "$EXPORT" --agent ic5 "$FIX" 2>&1)
assert_file "M10 fallback pack" "$FIX/.claude/memory/seed/ic5.md"
# import into fallback (no db)
rm -f "$FIX/.claude/memory/memory.db"
# clear agent lessons to test append
: > "$FIX/.claude/memory/ic5/lessons.md"
OUT=$(bash "$IMPORT" "$FIX" 2>&1)
assert_contains "M10 fallback import count" "$OUT" "imported="
# lessons should have content
if [ -s "$FIX/.claude/memory/ic5/lessons.md" ]; then
  PASS=$((PASS + 1)); echo "  ok  M10 fallback append"
else
  FAIL=$((FAIL + 1)); echo "  FAIL M10 lessons empty after import"
fi
rm -rf "$FIX"

# ---------- 10. No pack → import exit 0 silent ----------
echo "-- M11 graceful absence"
FIX=$(mktemp -d "${TMPDIR:-/tmp}/seed-test-m11.XXXXXX")
make_fixture "$FIX"
set +e
OUT=$(bash "$IMPORT" "$FIX" 2>&1)
RC=$?
set -e
assert_eq "M11 exit 0" "$RC" "0"
assert_eq "M11 silent" "$OUT" ""
rm -rf "$FIX"

# ---------- unit: content hash stable ----------
echo "-- unit helpers"
H1=$(seed_content_hash "hello world")
H2=$(seed_content_hash "hello world")
assert_eq "hash stable" "$H1" "$H2"
assert_eq "hash len 12" "${#H1}" "12"
T=$(seed_trailer "proj" "2026-07-14" 2 "ic5" "$H1")
assert_contains "trailer form" "$T" "[seed: project=proj date=2026-07-14 tier=2 agent=ic5 hash=$H1]"

echo ""
echo "=== results: pass=$PASS fail=$FAIL ==="
if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
exit 0
