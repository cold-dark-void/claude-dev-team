#!/usr/bin/env bash
# skills/release-train/test-restore-safety.sh — M12 `restore` decision table
# (SPEC-023 M6/M7/M8/M12/M13(b), Test 17; WP 1-05 AC J).
#
# Covers: empty range resets; committed-only (untagged, unpushed) range
# resets to base_sha; a tagged commit in range halts (HEAD, tag, index
# unchanged); a commit reachable from origin halts (HEAD unchanged); no
# origin remote treats the range as unpushed (resets); an unresolvable base
# fails closed with no change; static grep for the forbidden literals
# `git tag` / `git push` / `git commit`.
set -u
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
LIB="$HERE/train-lib.sh"
export GIT_CONFIG_GLOBAL=/dev/null
export GIT_CONFIG_NOSYSTEM=1
unset GIT_DIR GIT_INDEX_FILE GIT_WORK_TREE
# shellcheck source=../../tests/lib/hermetic.sh
. "$HERE/../../tests/lib/hermetic.sh"
hermetic_init

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); }
fail() { FAIL=$((FAIL + 1)); echo "FAIL: $*"; }

TMPROOT="$TMPDIR/restore-safety"
mkdir -p "$TMPROOT"

setup_repo() {
  # setup_repo <dir>
  local d="$1"
  mkdir -p "$d"
  git -C "$d" init -q
  git -C "$d" symbolic-ref HEAD refs/heads/master
  git -C "$d" config user.email "test@example.com"
  git -C "$d" config user.name "Test"
  printf 'base\n' > "$d/file.txt"
  git -C "$d" add -A
  git -C "$d" commit -q -m "init"
}

run_restore() {
  # run_restore <dir> <want_rc> <base_sha>
  local d="$1" want="$2" base="$3"
  OUT=$(cd "$d" && bash "$LIB" restore "$base" 2>&1)
  RC=$?
  if [ "$RC" -eq "$want" ]; then pass
  else fail "restore rc=$RC != $want for base=$base"; echo "  out: $OUT" | head -c 500; echo
  fi
}

# ---- Case 1: empty range resets (no-op, HEAD == base) -----------------------
R1="$TMPROOT/c1"
setup_repo "$R1"
HEAD1=$(git -C "$R1" rev-parse HEAD)
run_restore "$R1" 0 "$HEAD1"
[ "$(git -C "$R1" rev-parse HEAD)" = "$HEAD1" ] && pass || fail "c1: HEAD moved"

# ---- Case 2: committed-only (untagged, unpushed) resets to base -------------
R2="$TMPROOT/c2"
setup_repo "$R2"
BASE2=$(git -C "$R2" rev-parse HEAD)
printf 'second\n' >> "$R2/file.txt"
git -C "$R2" commit -q -am "second commit"
printf 'untracked\n' > "$R2/user-notes.txt"
run_restore "$R2" 0 "$BASE2"
[ "$(git -C "$R2" rev-parse HEAD)" = "$BASE2" ] && pass || fail "c2: HEAD not reset to base"
[ -f "$R2/user-notes.txt" ] && pass || fail "c2: untracked file lost"
[ "$(git -C "$R2" status --porcelain -- ':/' | grep -c '^ M')" -eq 0 ] && pass || fail "c2: tracked tree dirty after reset"

# ---- Case 3: committed + tagged halts (HEAD, tag, index unchanged) ----------
R3="$TMPROOT/c3"
setup_repo "$R3"
BASE3=$(git -C "$R3" rev-parse HEAD)
printf 'second\n' >> "$R3/file.txt"
git -C "$R3" commit -q -am "second commit"
TIP3=$(git -C "$R3" rev-parse HEAD)
git -C "$R3" tag v1.0.0 "$TIP3"
run_restore "$R3" 1 "$BASE3"
[ "$(git -C "$R3" rev-parse HEAD)" = "$TIP3" ] && pass || fail "c3: HEAD moved on halt"
[ "$(git -C "$R3" rev-parse v1.0.0)" = "$TIP3" ] && pass || fail "c3: tag moved/removed on halt"
[ -z "$(git -C "$R3" status --porcelain -- ':/')" ] && pass || fail "c3: index/tree dirtied on halt"
echo "$OUT" | grep -q "HALT" && pass || fail "c3: no HALT message on stderr"

# ---- Case 4: commit reachable from origin halts (HEAD unchanged) -----------
R4="$TMPROOT/c4"
setup_repo "$R4"
BASE4=$(git -C "$R4" rev-parse HEAD)
ORIGIN4="$TMPROOT/c4-origin.git"
git init -q --bare "$ORIGIN4"
git -C "$R4" remote add origin "$ORIGIN4"
printf 'second\n' >> "$R4/file.txt"
git -C "$R4" commit -q -am "second commit"
TIP4=$(git -C "$R4" rev-parse HEAD)
git -C "$R4" push -q origin master
run_restore "$R4" 1 "$BASE4"
[ "$(git -C "$R4" rev-parse HEAD)" = "$TIP4" ] && pass || fail "c4: HEAD moved on halt"
[ -z "$(git -C "$R4" status --porcelain -- ':/')" ] && pass || fail "c4: index/tree dirtied on halt"
echo "$OUT" | grep -q "HALT" && pass || fail "c4: no HALT message on stderr"

# ---- Case 5: origin removed -> committed-only range resets -----------------
R5="$TMPROOT/c5"
setup_repo "$R5"
BASE5=$(git -C "$R5" rev-parse HEAD)
ORIGIN5="$TMPROOT/c5-origin.git"
git init -q --bare "$ORIGIN5"
git -C "$R5" remote add origin "$ORIGIN5"
printf 'second\n' >> "$R5/file.txt"
git -C "$R5" commit -q -am "second commit"
git -C "$R5" remote remove origin
run_restore "$R5" 0 "$BASE5"
[ "$(git -C "$R5" rev-parse HEAD)" = "$BASE5" ] && pass || fail "c5: HEAD not reset after origin removed"

# ---- Case 6: unresolvable base -> nonzero, no change ------------------------
R6="$TMPROOT/c6"
setup_repo "$R6"
HEAD6=$(git -C "$R6" rev-parse HEAD)
run_restore "$R6" 1 "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef"
[ "$(git -C "$R6" rev-parse HEAD)" = "$HEAD6" ] && pass || fail "c6: HEAD moved on unresolvable base"


# ---- Case 7: origin present but commit not pushed -> still resets ----------
R7="$TMPROOT/c7"
setup_repo "$R7"
BASE7=$(git -C "$R7" rev-parse HEAD)
ORIGIN7="$TMPROOT/c7-origin.git"
git init -q --bare "$ORIGIN7"
git -C "$R7" remote add origin "$ORIGIN7"
git -C "$R7" push -q origin master
printf 'second\n' >> "$R7/file.txt"
git -C "$R7" commit -q -am "second commit (not pushed)"
run_restore "$R7" 0 "$BASE7"
[ "$(git -C "$R7" rev-parse HEAD)" = "$BASE7" ] && pass || fail "c7: HEAD not reset with origin present but commit unpushed"

# ---- Case 8: a git failure in the ref query halts (fail toward halt) -------
# Design 5: the origin/tag check must fail toward halt, not toward reset.
# A PATH-shimmed git that fails only for-each-ref proves the caller does not
# silently treat a broken check as "not released".
R8="$TMPROOT/c8"
setup_repo "$R8"
BASE8=$(git -C "$R8" rev-parse HEAD)
printf 'second\n' >> "$R8/file.txt"
git -C "$R8" commit -q -am "second commit"
TIP8=$(git -C "$R8" rev-parse HEAD)
SHIM8="$TMPROOT/c8-shim"
mkdir -p "$SHIM8"
REAL_GIT=$(command -v git)
{
  printf '#!/usr/bin/env bash\n'
  printf 'if [ "$1" = "for-each-ref" ]; then\n'
  printf '  echo "shim: for-each-ref forced failure" >&2\n'
  printf '  exit 1\n'
  printf 'fi\n'
  printf 'exec %q "$@"\n' "$REAL_GIT"
} > "$SHIM8/git"
chmod 755 "$SHIM8/git"
OUT=$(cd "$R8" && PATH="$SHIM8:$PATH" bash "$LIB" restore "$BASE8" 2>&1)
RC=$?
[ "$RC" -ne 0 ] && pass || fail "c8: shimmed for-each-ref failure did not halt (rc=$RC)"
[ "$(git -C "$R8" rev-parse HEAD)" = "$TIP8" ] && pass || fail "c8: HEAD moved despite for-each-ref failure"
echo "$OUT" | grep -q "HALT" && pass || fail "c8: no HALT message for for-each-ref failure"

# ---- Case 9: static grep -- no `git tag` / `git push` / `git commit` -------
if grep -nE 'git (tag|push|commit)\b' "$HERE/train-lib.sh" >/dev/null 2>&1; then
  fail "c9: forbidden literal (git tag/push/commit) present in train-lib.sh"
else
  pass
fi

echo "----"
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
