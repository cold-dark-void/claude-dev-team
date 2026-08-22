#!/usr/bin/env bash
# prune-remote-test.sh — bite-tests for wrap-ticket prune-remote.sh (CDT-157)
#
# Machine-check: bash skills/wrap-ticket/prune-remote-test.sh  (exit 0)
# Fixture git + --dry-run only. Never git push to a network remote.
# THIS SCRIPT IS A SUBPROCESS CLI — NEVER SOURCE IT.

set -u

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
PRUNE="$HERE/prune-remote.sh"
SKILL="$HERE/SKILL.md"
WT_LIB="$HERE/../worktree-lib.sh"

PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); printf '  PASS %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL %s — %s\n' "$1" "$2"; }

assert_eq() {
  local name="$1" want="$2" got="$3"
  if [ "$want" = "$got" ]; then pass "$name"
  else fail "$name" "want='$want' got='$got'"
  fi
}

assert_contains() {
  local name="$1" hay="$2" needle="$3"
  if printf '%s' "$hay" | grep -qF -- "$needle"; then pass "$name"
  else fail "$name" "missing [$needle] in [$hay]"
  fi
}

assert_not_contains() {
  local name="$1" hay="$2" needle="$3"
  if printf '%s' "$hay" | grep -qF -- "$needle"; then fail "$name" "unexpected [$needle] in [$hay]"
  else pass "$name"
  fi
}

assert_file_match() {
  local name="$1" file="$2" pat="$3"
  if grep -qE -- "$pat" "$file"; then pass "$name"
  else fail "$name" "pattern /$pat/ not in $file"
  fi
}

assert_file_nomatch() {
  local name="$1" file="$2" pat="$3"
  if grep -qE -- "$pat" "$file"; then fail "$name" "pattern /$pat/ unexpectedly in $file"
  else pass "$name"
  fi
}

assert_rc() {
  local name="$1" want="$2"
  shift 2
  local rc
  set +e
  "$@" >/dev/null 2>&1
  rc=$?
  set -e
  assert_eq "$name" "$want" "$rc"
}

TMP=$(mktemp -d "${TMPDIR:-/tmp}/prune-remote-test.XXXXXX")
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

new_repo() {
  local dir="$1"
  mkdir -p "$dir"
  git init -q -b master "$dir"
  git -C "$dir" config user.email "test@example.com"
  git -C "$dir" config user.name "Test"
  git -C "$dir" config commit.gpgsign false
}

run_in() {
  local dir="$1"
  shift
  (cd "$dir" && bash "$PRUNE" "$@")
}

# ---- usage ------------------------------------------------------------------
echo "== usage =="
assert_rc "no args → 64" 64 bash "$PRUNE"
assert_rc "unknown cmd → 64" 64 bash "$PRUNE" nope
assert_rc "allowlisted missing name → 64" 64 bash "$PRUNE" allowlisted
assert_rc "candidates missing T → 64" 64 bash "$PRUNE" candidates
assert_rc "safe-to-delete missing branch → 64" 64 bash "$PRUNE" safe-to-delete
assert_rc "prune missing T → 64" 64 bash "$PRUNE" prune

# ---- AC5 allowlisted --------------------------------------------------------
echo "== AC5 allowlisted =="
assert_rc "accept feat/CDT-157" 0 bash "$PRUNE" allowlisted feat/CDT-157
assert_rc "accept feat/epic-CDT-97" 0 bash "$PRUNE" allowlisted feat/epic-CDT-97
assert_rc "accept feat/CDT-141-C3" 0 bash "$PRUNE" allowlisted feat/CDT-141-C3
assert_rc "accept origin/feat/CDT-157" 0 bash "$PRUNE" allowlisted origin/feat/CDT-157

assert_rc "reject master" 1 bash "$PRUNE" allowlisted master
assert_rc "reject main" 1 bash "$PRUNE" allowlisted main
assert_rc "reject stable" 1 bash "$PRUNE" allowlisted stable
assert_rc "reject develop" 1 bash "$PRUNE" allowlisted develop
assert_rc "reject HEAD" 1 bash "$PRUNE" allowlisted HEAD
assert_rc "reject origin" 1 bash "$PRUNE" allowlisted origin
assert_rc "reject feat/master" 1 bash "$PRUNE" allowlisted feat/master
assert_rc "reject origin/master" 1 bash "$PRUNE" allowlisted origin/master
assert_rc "reject feat/../x" 1 bash "$PRUNE" allowlisted 'feat/../x'
assert_rc "reject empty" 1 bash "$PRUNE" allowlisted ""
assert_rc "reject extra slash" 1 bash "$PRUNE" allowlisted feat/CDT-157/extra
assert_rc "reject origin/feat/master" 1 bash "$PRUNE" allowlisted origin/feat/master

# ---- AC1 candidates ---------------------------------------------------------
echo "== AC1 candidates =="
REPO="$TMP/cands"
new_repo "$REPO"
git -C "$REPO" commit --allow-empty -q -m init

OUT=$(run_in "$REPO" candidates CDT-157)
assert_eq "always feat/T" "feat/CDT-157" "$OUT"

OUT=$(run_in "$REPO" candidates CDT-157 --linear-id CDT-157)
assert_eq "linear_id == T no extra" "feat/CDT-157" "$OUT"

OUT=$(run_in "$REPO" candidates CDT-157 --linear-id LIN-9)
assert_contains "linear_id != T adds feat/LIN-9" "$OUT" "feat/CDT-157"
assert_contains "linear_id != T has LIN-9" "$OUT" "feat/LIN-9"

OUT=$(run_in "$REPO" candidates CDT-97 --epic)
assert_contains "--epic adds feat/T" "$OUT" "feat/CDT-97"
assert_contains "--epic adds feat/epic-T" "$OUT" "feat/epic-CDT-97"

OUT=$(run_in "$REPO" candidates CDT-97 --epic --child CDT-97-C1 --child CDT-141)
assert_contains "child id" "$OUT" "feat/CDT-97-C1"
assert_contains "child linear_id" "$OUT" "feat/CDT-141"
assert_contains "epic still present" "$OUT" "feat/epic-CDT-97"
assert_not_contains "no parent invented" "$OUT" "feat/epic-CDT-141"

# skip_release child: MUST NOT add parent feat/epic-<parent>
mkdir -p "$REPO/.claude/epics/CDT-97"
cat > "$REPO/.claude/epics/CDT-97/state.json" <<'EOF'
{"epic_id":"CDT-97","children":[{"id":"CDT-157","linear_id":"CDT-157"}]}
EOF
OUT=$(run_in "$REPO" candidates CDT-157)
assert_eq "skip_release child is feat/T only" "feat/CDT-157" "$OUT"
assert_not_contains "child wrap no parent epic" "$OUT" "feat/epic-CDT-97"

# wrapping that epic reads children from state.json
OUT=$(run_in "$REPO" candidates CDT-97 --epic)
assert_contains "epic wrap child from state" "$OUT" "feat/CDT-157"
assert_contains "epic wrap feat/epic-T" "$OUT" "feat/epic-CDT-97"

# no origin/feat/* glob: extra local branch must not appear
git -C "$REPO" checkout -q -b feat/CDT-157-extra
git -C "$REPO" commit --allow-empty -q -m extra
git -C "$REPO" checkout -q master
OUT=$(run_in "$REPO" candidates CDT-157)
assert_eq "no feat/T* glob" "feat/CDT-157" "$OUT"
assert_not_contains "no extra suffix" "$OUT" "feat/CDT-157-extra"

# ---- AC2 / AC7 fixture: FF, squash, leftover --------------------------------
echo "== AC2 safety fixtures =="

# FF ancestor → would-delete
FF="$TMP/ff"
new_repo "$FF"
git -C "$FF" commit --allow-empty -q -m base
git -C "$FF" checkout -q -b feat/CDT-157
git -C "$FF" commit --allow-empty -q -m feat
git -C "$FF" checkout -q master
git -C "$FF" merge --ff-only -q feat/CDT-157
OUT=$(run_in "$FF" prune CDT-157 --dry-run)
RC=$?
assert_eq "FF dry-run exit 0" "0" "$RC"
assert_contains "FF would-delete" "$OUT" "pruned: feat/CDT-157"
assert_not_contains "FF no leftover" "$OUT" "leftover:"

# squash (cherry all -) → would-delete
SQ="$TMP/squash"
new_repo "$SQ"
printf 'base\n' > "$SQ/f"
git -C "$SQ" add f
git -C "$SQ" commit -q -m base
git -C "$SQ" checkout -q -b feat/CDT-157
printf 'feat\n' > "$SQ/g"
git -C "$SQ" add g
git -C "$SQ" commit -q -m feat
git -C "$SQ" checkout -q master
git -C "$SQ" merge --squash -q feat/CDT-157
git -C "$SQ" commit -q -m squashed
OUT=$(run_in "$SQ" prune CDT-157 --dry-run)
RC=$?
assert_eq "squash dry-run exit 0" "0" "$RC"
assert_contains "squash would-delete" "$OUT" "pruned: feat/CDT-157"
assert_not_contains "squash no leftover" "$OUT" "leftover:"

# unique + → leftover, no delete
LF="$TMP/leftover"
new_repo "$LF"
printf 'base\n' > "$LF/f"
git -C "$LF" add f
git -C "$LF" commit -q -m base
git -C "$LF" checkout -q -b feat/CDT-157
printf 'feat\n' > "$LF/g"
git -C "$LF" add g
git -C "$LF" commit -q -m feat
printf 'unique\n' > "$LF/h"
git -C "$LF" add h
git -C "$LF" commit -q -m unique
git -C "$LF" checkout -q master
git -C "$LF" merge --squash -q feat/CDT-157^
git -C "$LF" commit -q -m squashed-partial
OUT=$(run_in "$LF" prune CDT-157 --dry-run)
RC=$?
assert_eq "leftover dry-run exit 0" "0" "$RC"
assert_contains "leftover notice" "$OUT" "leftover: feat/CDT-157"
assert_not_contains "leftover no pruned" "$OUT" "pruned: feat/CDT-157"

# never --force in helper
assert_file_nomatch "helper no --force" "$PRUNE" --force

# ---- AC3 fail-open ----------------------------------------------------------
echo "== AC3 fail-open =="
FO="$TMP/failopen"
new_repo "$FO"
git -C "$FO" commit --allow-empty -q -m init
# no origin remote; live prune (not dry-run) must not hang and must exit 0
OUT=$(run_in "$FO" prune CDT-157 2>/dev/null)
RC=$?
assert_eq "missing origin exit 0" "0" "$RC"
assert_contains "missing origin fail-open" "$OUT" "remote prune failed:"

# ---- AC4 already-gone silent ------------------------------------------------
echo "== AC4 idempotent silent =="
GONE="$TMP/gone"
new_repo "$GONE"
git -C "$GONE" commit --allow-empty -q -m init
OUT=$(run_in "$GONE" prune CDT-157 --dry-run)
RC=$?
assert_eq "never-pushed dry-run exit 0" "0" "$RC"
assert_eq "never-pushed silent" "" "$OUT"

# ---- AC7 SKILL presence -----------------------------------------------------
echo "== AC7 SKILL =="
assert_file_match "plugin-dir resolve" "$SKILL" 'plugin-dir\.sh" file skills/wrap-ticket/prune-remote\.sh'
assert_file_match "leftover string" "$SKILL" leftover
assert_file_nomatch "naive feat delete gone" "$SKILL" 'push origin --delete "feat/\$TICKET_ID" 2>/dev/null \|\| true'
assert_file_nomatch "naive epic delete gone" "$SKILL" 'push origin --delete "feat/epic-\$TICKET_ID" 2>/dev/null \|\| true'
assert_file_match "Step 6.x heading" "$SKILL" '^## Step 6\.x'
assert_file_match "skip_release vs parent epic" "$SKILL" 'skip_release'

# ---- AC8 worktree-lib must not grow remote delete ---------------------------
echo "== AC8 worktree-lib =="
assert_file_nomatch "worktree-lib no remote delete" "$WT_LIB" 'push origin --delete'

# ---- no origin/feat/* scan in helper ----------------------------------------
echo "== no glob scan =="
assert_file_nomatch "no origin/feat/* glob" "$PRUNE" 'origin/feat/\*'
assert_file_nomatch "no ls-remote glob" "$PRUNE" 'ls-remote.*feat/\*'

echo
echo "PASS=$PASS FAIL=$FAIL"
if [ "$FAIL" -ne 0 ]; then
  exit 1
fi
exit 0
