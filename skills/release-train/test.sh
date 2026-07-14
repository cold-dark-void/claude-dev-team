#!/usr/bin/env bash
# Unit tests for train-lib.sh (SPEC-023). Run: bash skills/release-train/test.sh
set -u
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
LIB="$HERE/train-lib.sh"
FIX="$HERE/fixtures"
PASS=0
FAIL=0
OUT=""
RC=0

pass() { PASS=$((PASS + 1)); }
fail() { FAIL=$((FAIL + 1)); echo "FAIL: $*"; }

run_lib() {
  # run_lib <want_exit> <args...>
  local want="$1"; shift
  set +e
  OUT=$(bash "$LIB" "$@" 2>&1)
  RC=$?
  set -e
  if [ "$RC" -eq "$want" ]; then pass
  else fail "exit $RC != $want for: $*"; echo "  out: $OUT" | head -c 400; echo
  fi
}

# ---- T0: usage --------------------------------------------------------------
run_lib 64
echo "$OUT" | grep -q Usage && pass || fail "usage text missing"

# ---- temp git repo helpers --------------------------------------------------
TMPROOT=$(mktemp -d "${TMPDIR:-/tmp}/rt-test.XXXXXX")
cleanup() { rm -rf "$TMPROOT"; }
trap cleanup EXIT

setup_repo() {
  local d="$1"
  mkdir -p "$d"
  git -C "$d" init -q -b master
  git -C "$d" config user.email "test@example.com"
  git -C "$d" config user.name "Test"
  mkdir -p "$d/.claude-plugin"
  printf '%s\n' '{"name":"dev-team","version":"0.39.0"}' > "$d/.claude-plugin/plugin.json"
  printf '%s\n' '{"plugins":[{"name":"dev-team","version":"0.39.0"}]}' > "$d/.claude-plugin/marketplace.json"
  printf '%s\n' '# Changelog' '' '### v0.39.0' '- base' > "$d/CHANGELOG.md"
  mkdir -p "$d/specs"
  printf '%s\n' '# Behavioral Specifications' '' '## Spec Index' '' \
    '| ID | Title | Status | Coverage |' \
    '|----|-------|--------|----------|' \
    '| SPEC-001 | A | ACTIVE | x |' '' \
    '## Version History' '' \
    '| Date | Change |' \
    '|------|--------|' \
    '| 2026-03-16 | init |' > "$d/specs/TDD.md"
  git -C "$d" add -A
  git -C "$d" commit -q -m "init master 0.39.0"
}

REPO="$TMPROOT/repo"
setup_repo "$REPO"
export RELEASE_TRAIN_ROOT="$REPO"
cd "$REPO"

run_in() {
  local want="$1"; shift
  set +e
  OUT=$(RELEASE_TRAIN_ROOT="$REPO" bash "$LIB" "$@" 2>&1)
  RC=$?
  set -e
  if [ "$RC" -eq "$want" ]; then pass
  else fail "exit $RC != $want for: $*"; echo "  out: $OUT" | head -c 500; echo
  fi
}

# ---- init / register / list / drop ------------------------------------------
run_in 0 init
[ -f "$REPO/.claude/release-train/queue.json" ] && pass || fail "queue.json missing"
python3 -c "import json; json.load(open('$REPO/.claude/release-train/queue.json'))" && pass || fail "queue invalid JSON"

git -C "$REPO" branch feat/a
git -C "$REPO" branch feat/b

run_in 0 register feat/a --bump minor --assumed 0.40.0
run_in 0 register feat/b --bump patch
run_in 0 list
N=$(echo "$OUT" | jq '.entries|length')
[ "$N" = "2" ] && pass || fail "list length want 2 got $N"

# missing branch fails
run_in 1 register feat/nope

run_in 0 drop feat/b
N=$(RELEASE_TRAIN_ROOT="$REPO" bash "$LIB" list | jq '.entries|length')
[ "$N" = "1" ] && pass || fail "after drop length want 1 got $N"

# re-add b
run_in 0 register feat/b --bump patch

# drop non-pending fails after status change later — test pending-only later

# ---- freeze + slot arithmetic -----------------------------------------------
# freeze --order must be a full permutation of non-landed entries (no silent drops)
run_in 1 freeze --order feat/a
N=$(RELEASE_TRAIN_ROOT="$REPO" bash "$LIB" list | jq '.entries|length')
[ "$N" = "2" ] && pass || fail "partial --order dropped entries: length want 2 got $N"
F=$(RELEASE_TRAIN_ROOT="$REPO" bash "$LIB" list | jq -r '.frozen')
[ "$F" = "false" ] && pass || fail "partial --order should leave frozen=false got $F"

run_in 0 freeze --order feat/a,feat/b
N=$(echo "$OUT" | jq '.entries|length')
[ "$N" = "2" ] && pass || fail "full --order length want 2 got $N"
echo "$OUT" | jq -e '.frozen == true' >/dev/null && pass || fail "not frozen"
A0=$(echo "$OUT" | jq -r '.entries[] | select(.branch=="feat/a") | .assigned_version')
A1=$(echo "$OUT" | jq -r '.entries[] | select(.branch=="feat/b") | .assigned_version')
[ "$A0" = "0.40.0" ] && pass || fail "feat/a assigned want 0.40.0 got $A0"
[ "$A1" = "0.40.1" ] && pass || fail "feat/b assigned want 0.40.1 got $A1"

run_in 0 show-plan
P0=$(echo "$OUT" | jq -r '.entries[] | select(.branch=="feat/a") | .assigned_version')
[ "$P0" = "0.40.0" ] && pass || fail "show-plan not identical"

# freeze --print-only does not change status fields
STAT_BEFORE=$(RELEASE_TRAIN_ROOT="$REPO" bash "$LIB" list | jq -c '[.entries[].status]')
run_in 0 freeze --print-only
STAT_AFTER=$(RELEASE_TRAIN_ROOT="$REPO" bash "$LIB" list | jq -c '[.entries[].status]')
[ "$STAT_BEFORE" = "$STAT_AFTER" ] && pass || fail "print-only mutated statuses"

# empty freeze fails
EMPTY="$TMPROOT/empty"
setup_repo "$EMPTY"
run_in_empty() {
  local want="$1"; shift
  set +e
  OUT=$(RELEASE_TRAIN_ROOT="$EMPTY" bash "$LIB" "$@" 2>&1)
  RC=$?
  set -e
  if [ "$RC" -eq "$want" ]; then pass
  else fail "empty: exit $RC != $want for: $*"; fi
}
RELEASE_TRAIN_ROOT="$EMPTY" bash "$LIB" init >/dev/null
run_in_empty 1 freeze

# ---- set-status + lock ------------------------------------------------------
cd "$REPO"
export RELEASE_TRAIN_ROOT="$REPO"
run_in 0 set-status feat/a landing --base-sha deadbeef
run_in 1 set-status feat/a pending   # illegal reverse
run_in 0 set-status feat/a landed --tag v0.40.0

# drop landed fails
run_in 1 drop feat/a

run_in 0 acquire-lock
run_in 1 acquire-lock
run_in 0 release-lock
run_in 0 acquire-lock
run_in 0 release-lock

# ---- detect-assumed + renumber ----------------------------------------------
# branch with assumed content
git -C "$REPO" checkout -q -b feat/c
printf '%s\n' '# Changelog' '' '### v0.40.0' '- c feature' > "$REPO/CHANGELOG.md"
printf '%s\n' '{"name":"dev-team","version":"0.40.0"}' > "$REPO/.claude-plugin/plugin.json"
git -C "$REPO" add -A && git -C "$REPO" commit -q -m "feat c assume 0.40.0"
git -C "$REPO" checkout -q master

run_in 0 detect-assumed feat/c
[ "$OUT" = "0.40.0" ] && pass || fail "detect-assumed want 0.40.0 got [$OUT]"

# renumber on copy of fixture
RND="$TMPROOT/renumber"
mkdir -p "$RND/.claude-plugin"
cp "$FIX/renumber/CHANGELOG.md" "$RND/CHANGELOG.md"
cp "$FIX/renumber/plugin.json" "$RND/.claude-plugin/plugin.json"
cp "$FIX/renumber/marketplace.json" "$RND/.claude-plugin/marketplace.json"
(
  cd "$RND"
  bash "$LIB" renumber 0.40.0 0.41.0 >/dev/null
)
grep -q '### v0.41.0' "$RND/CHANGELOG.md" && pass || fail "renumber CHANGELOG"
[ "$(jq -r .version "$RND/.claude-plugin/plugin.json")" = "0.41.0" ] && pass || fail "renumber plugin"
[ "$(jq -r '.plugins[0].version' "$RND/.claude-plugin/marketplace.json")" = "0.41.0" ] && pass || fail "renumber market"
# source fixture unchanged
grep -q '### v0.40.0' "$FIX/renumber/CHANGELOG.md" && pass || fail "fixture mutated"

# ---- M5a tdd-index ----------------------------------------------------------
OUTF=$(mktemp "${TMPDIR:-/tmp}/rt-tdd.XXXXXX")
bash "$LIB" resolve-tdd-index \
  --ours "$FIX/tdd-index/ours.md" \
  --theirs "$FIX/tdd-index/theirs.md" \
  --out "$OUTF"
if diff -u "$FIX/tdd-index/want.md" "$OUTF" >/dev/null; then pass
else fail "tdd-index diff"; diff -u "$FIX/tdd-index/want.md" "$OUTF" | head -30
fi
# master rows byte-identical substring
grep -F '| SPEC-001 | Per-Agent Directives | ACTIVE | commands/adjust-agent.md |' "$OUTF" >/dev/null && pass || fail "master row missing"
rm -f "$OUTF"

# ---- M5b vh -----------------------------------------------------------------
OUTF=$(mktemp "${TMPDIR:-/tmp}/rt-vh.XXXXXX")
bash "$LIB" resolve-vh \
  --ours "$FIX/vh/ours.md" \
  --theirs "$FIX/vh/theirs.md" \
  --out "$OUTF"
if diff -u "$FIX/vh/want.md" "$OUTF" >/dev/null; then pass
else fail "vh diff"; diff -u "$FIX/vh/want.md" "$OUTF" | head -30
fi
rm -f "$OUTF"

# ---- M5c changelog ----------------------------------------------------------
OUTF=$(mktemp "${TMPDIR:-/tmp}/rt-cl.XXXXXX")
bash "$LIB" resolve-changelog 0.41.0 \
  --branch-file "$FIX/changelog/branch_entry.md" \
  --master-file "$FIX/changelog/master.md" \
  --out "$OUTF"
if diff -u "$FIX/changelog/want.md" "$OUTF" >/dev/null; then pass
else fail "changelog diff"; diff -u "$FIX/changelog/want.md" "$OUTF" | head -40
fi
# exactly one assigned heading
[ "$(grep -c '^### v0.41.0' "$OUTF")" = "1" ] && pass || fail "duplicate assigned heading"
rm -f "$OUTF"

# ---- M5d json ---------------------------------------------------------------
JDIR="$TMPROOT/json"
mkdir -p "$JDIR"
cp "$FIX/json/plugin.json" "$JDIR/plugin.json"
cp "$FIX/json/marketplace.json" "$JDIR/marketplace.json"
bash "$LIB" resolve-json 0.40.0 --plugin "$JDIR/plugin.json" --market "$JDIR/marketplace.json" >/dev/null
[ "$(jq -r .version "$JDIR/plugin.json")" = "0.40.0" ] && pass || fail "resolve-json plugin"
[ "$(jq -r '.plugins[0].version' "$JDIR/marketplace.json")" = "0.40.0" ] && pass || fail "resolve-json market"
python3 -c "import json; json.load(open('$JDIR/plugin.json')); json.load(open('$JDIR/marketplace.json'))" && pass || fail "json invalid"

# ---- restore + verify-tag + preflight ---------------------------------------
cd "$REPO"
export RELEASE_TRAIN_ROOT="$REPO"
BASE=$(git -C "$REPO" rev-parse HEAD)
# dirty tree
echo dirty > "$REPO/dirty.txt"
git -C "$REPO" add dirty.txt
run_in 0 restore "$BASE"
[ -z "$(git -C "$REPO" status --porcelain)" ] && pass || fail "restore not clean"
[ "$(git -C "$REPO" rev-parse HEAD)" = "$BASE" ] && pass || fail "restore wrong HEAD"

# verify-tag missing
run_in 1 verify-tag v9.9.9
git -C "$REPO" tag v0.39.0
run_in 0 verify-tag v0.39.0

run_in 0 preflight
[ "$OUT" = "ok" ] && pass || fail "preflight want ok got $OUT"

git -C "$REPO" checkout -q -b not-master
run_in 1 preflight
echo "$OUT" | grep -q wrong-branch && pass || fail "preflight wrong-branch"
git -C "$REPO" checkout -q master

# ---- M10 static: no release internals ---------------------------------------
if ! grep -nE 'git (tag|push|commit)\b' "$LIB" >/dev/null; then pass
else fail "train-lib contains git tag/push/commit"; grep -nE 'git (tag|push|commit)\b' "$LIB"
fi
if ! grep -nE 'Co-Authored-By|chore: release|sync-includes|check-template-vars|check-hook-templates|check-skill-bash' "$LIB" >/dev/null; then pass
else fail "train-lib contains release internals"
fi

# ---- gitignore --------------------------------------------------------------
ROOT_GI=$(cd "$HERE/../.." && pwd)
if grep -qxF '.claude/release-train/' "$ROOT_GI/.gitignore" 2>/dev/null \
  || grep -qxF '.claude/release-train/' "$HERE/../../.gitignore" 2>/dev/null; then
  pass
else
  # worktree root
  WT=$(git -C "$HERE" rev-parse --show-toplevel 2>/dev/null || true)
  if [ -n "$WT" ] && grep -qxF '.claude/release-train/' "$WT/.gitignore"; then pass
  else fail "gitignore missing .claude/release-train/"
  fi
fi

# ---- status transitions matrix ----------------------------------------------
# fresh entry
git -C "$REPO" branch feat/d 2>/dev/null || true
# reset queue for clean transition test
rm -rf "$REPO/.claude/release-train"
RELEASE_TRAIN_ROOT="$REPO" bash "$LIB" init >/dev/null
RELEASE_TRAIN_ROOT="$REPO" bash "$LIB" register feat/d --bump minor >/dev/null
run_in 0 set-status feat/d landing
run_in 0 set-status feat/d blocked --paths skills/foo.sh
# blocked cannot go to landed
run_in 1 set-status feat/d landed

echo
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
