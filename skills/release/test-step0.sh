#!/usr/bin/env bash
# Behavioural tests for step0.sh (SPEC-010 via SKILL Step 0; SPEC-025 C4).
# Run: bash skills/release/test-step0.sh
set -u

HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
STEP0="$HERE/step0.sh"
EPIC_LIB="$HERE/../epic/epic-lib.sh"
# shellcheck source=../../tests/lib/hermetic.sh
. "$HERE/../../tests/lib/hermetic.sh"
. "$HERE/../../tests/lib/skip.sh"
hermetic_init

PASS=0
FAIL=0
OUT=""
RC=0

pass() { PASS=$((PASS + 1)); echo "PASS: $*"; }
fail() { FAIL=$((FAIL + 1)); echo "FAIL: $*"; }

expect_rc() {
  if [ "$RC" -eq "$1" ]; then
    pass "$2 -> $1"
  else
    fail "$2 exit $RC != $1: $OUT"
  fi
}

expect_contains() {
  if printf '%s\n' "$OUT" | grep -Fq -- "$1"; then
    pass "output contains: $1"
  else
    fail "output missing: $1"
    echo "  out: $OUT" | head -c 400
    echo
  fi
}

expect_not_contains() {
  if printf '%s\n' "$OUT" | grep -Fq -- "$1"; then
    fail "output unexpectedly contains: $1"
  else
    pass "output does not contain: $1"
  fi
}

make_repo() {
  local d
  d=$(mktemp -d "${TMPDIR:-/tmp}/step0-XXXXXX")
  git -C "$d" init -q -b master
  git -C "$d" config user.email "test@example.com"
  git -C "$d" config user.name "Test"
  printf '%s\n' "root" >"$d/README.md"
  git -C "$d" add README.md
  git -C "$d" commit -q -m "fix: v0.0.1 — baseline"
  printf '%s\n' "$d"
}

run_step0() {
  local d="$1"; shift
  RC=0
  OUT=$(cd "$d" && bash "$STEP0" "$@" 2>&1) && RC=0 || RC=$?
}

epic_state() {
  # epic_state <dir> <epic-id> <release_bump> <sealed> <children-json>
  local d="$1" id="$2" rb="$3" sealed="$4" children="$5"
  mkdir -p "$d/.claude/epics/$id"
  printf '{"epic_id":"%s","release_bump":"%s","sealed":%s,"children":%s}\n' \
    "$id" "$rb" "$sealed" "$children" >"$d/.claude/epics/$id/state.json"
}

# ---- usage -------------------------------------------------------------------
REPO=$(make_repo)
run_step0 "$REPO" --help
expect_rc 0 "--help"
expect_contains "Usage: step0.sh"

run_step0 "$REPO" --nope
expect_rc 64 "unknown flag"

NOT_GIT=$(mktemp -d "${TMPDIR:-/tmp}/step0-nogit-XXXXXX")
run_step0 "$NOT_GIT"
expect_rc 64 "not a git repo"
expect_contains "not a git repository"
rm -rf "$NOT_GIT"
rm -rf "$REPO"

# ---- detached HEAD ------------------------------------------------------------
REPO=$(make_repo)
git -C "$REPO" checkout -q --detach
BEFORE_STATUS=$(git -C "$REPO" status --porcelain)
BEFORE_HEAD=$(git -C "$REPO" rev-parse HEAD)
run_step0 "$REPO"
expect_rc 64 "detached HEAD"
expect_contains "detached HEAD"
AFTER_STATUS=$(git -C "$REPO" status --porcelain)
AFTER_HEAD=$(git -C "$REPO" rev-parse HEAD)
[ "$BEFORE_STATUS" = "$AFTER_STATUS" ] && pass "detached HEAD: status unchanged" || fail "detached HEAD: status changed"
[ "$BEFORE_HEAD" = "$AFTER_HEAD" ] && pass "detached HEAD: HEAD unchanged" || fail "detached HEAD: HEAD changed"
rm -rf "$REPO"

# ---- branch feat/v1.2-fix, no epics dir --------------------------------------
REPO=$(make_repo)
git -C "$REPO" checkout -q -b feat/v1.2-fix
run_step0 "$REPO"
expect_rc 0 "feat/v1.2-fix, no epics dir"
expect_contains "skipped"
rm -rf "$REPO"

# ---- branch feat/v1.2-fix, WITH epics dir → charset skip ---------------------
REPO=$(make_repo)
git -C "$REPO" checkout -q -b feat/v1.2-fix
mkdir -p "$REPO/.claude/epics"
run_step0 "$REPO"
expect_rc 0 "feat/v1.2-fix, with epics dir (charset skip)"
expect_contains "is not an epic or ticket id"
rm -rf "$REPO"

# ---- branch feat/plain, no epics dir -----------------------------------------
REPO=$(make_repo)
git -C "$REPO" checkout -q -b feat/plain
run_step0 "$REPO"
expect_rc 0 "feat/plain, no epics dir"
expect_contains "no"
rm -rf "$REPO"

# ---- master, no explicit env: epic-lib not called ----------------------------
REPO=$(make_repo)
MARKER="$REPO/marker"
STUB="$REPO/stub-epic-lib.sh"
cat >"$STUB" <<STUB_EOF
#!/usr/bin/env bash
touch "$MARKER"
exit 0
STUB_EOF
chmod +x "$STUB"
run_step0 "$REPO" --epic-lib "$STUB"
expect_rc 0 "master, no explicit env"
[ -f "$MARKER" ] && fail "master: epic-lib was called" || pass "master: epic-lib not called"
rm -rf "$REPO"

# ---- real epic-lib: release=end mid-flight -----------------------------------
if ( require_cmd jq ); then
  REPO=$(make_repo)
  epic_state "$REPO" E1 minor false '[{"id":"C1"}]'

  git -C "$REPO" checkout -q -b feat/epic-E1
  run_step0 "$REPO"
  expect_rc 64 "feat/epic-E1, release=end mid-flight"
  expect_contains "release=end"

  git -C "$REPO" checkout -q -b feat/C1 master
  run_step0 "$REPO"
  expect_rc 64 "feat/C1, parent epic release=end mid-flight"

  git -C "$REPO" checkout -q master
  RC=0
  OUT=$(cd "$REPO" && EPIC_RELEASE_END=E1 bash "$STEP0" 2>&1) && RC=0 || RC=$?
  expect_rc 64 "master + EPIC_RELEASE_END=E1 (DD2, explicit ref asserted)"

  RC=0
  OUT=$(cd "$REPO" && EPIC_RELEASE_END=E1 EPIC_ALLOW_SEAL_RELEASE=1 bash "$STEP0" 2>&1) && RC=0 || RC=$?
  expect_rc 0 "master + EPIC_RELEASE_END=E1 + EPIC_ALLOW_SEAL_RELEASE=1"

  epic_state "$REPO" E1 minor true '[{"id":"C1"}]'
  RC=0
  OUT=$(cd "$REPO" && EPIC_RELEASE_END=E1 bash "$STEP0" 2>&1) && RC=0 || RC=$?
  expect_rc 0 "master + EPIC_RELEASE_END=E1, sealed:true"

  rm -rf "$REPO"
fi

# ---- jq missing --------------------------------------------------------------
SHIMDIR=$(mktemp -d "${TMPDIR:-/tmp}/step0-shim-XXXXXX")
for c in bash git dirname basename cat mkdir rm env sed grep head tr find sort pwd; do
  p=$(command -v "$c" 2>/dev/null) || continue
  ln -s "$p" "$SHIMDIR/$c"
done

REPO=$(make_repo)
epic_state "$REPO" E2 minor false '[]'
git -C "$REPO" checkout -q -b feat/epic-E2
RC=0
OUT=$(cd "$REPO" && PATH="$SHIMDIR" bash "$STEP0" 2>&1) && RC=0 || RC=$?
expect_rc 69 "jq missing, epics dir present"
expect_contains "jq is required"
rm -rf "$REPO"

REPO=$(make_repo)
git -C "$REPO" checkout -q -b feat/epic-E2
RC=0
OUT=$(cd "$REPO" && PATH="$SHIMDIR" bash "$STEP0" 2>&1) && RC=0 || RC=$?
expect_rc 0 "jq missing, no epics dir (skip before jq check)"
rm -rf "$REPO"
rm -rf "$SHIMDIR"

echo
echo "$PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
exit 0
