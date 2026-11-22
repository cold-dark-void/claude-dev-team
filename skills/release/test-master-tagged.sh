#!/usr/bin/env bash
# SPEC-033 CDT-597 master-tag invariant tests: check-master-tagged.sh exits 0
# on an exact-match tagged tip and 1 on a synthetic untagged commit (with the
# release-train remediation line), 64 on usage; githooks/pre-push bites a
# default-branch push on an untagged tip and passes every other ref;
# install-git-hooks.sh installs both hooks; wiring asserted in SPEC-033
# `### CDT-597` and the SPEC-010 Covers list.
# Isolated temp git repos only — never the live tree. Run: bash skills/release/test-master-tagged.sh
set -u

HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "$HERE/../.." && pwd)
. "$REPO_ROOT/tests/lib/hermetic.sh"
hermetic_init

CHECK="$HERE/check-master-tagged.sh"
HOOK_SRC="$REPO_ROOT/githooks/pre-push"
INSTALL="$HERE/install-git-hooks.sh"

PASS=0
FAIL=0
OUT=""
RC=0

pass() { PASS=$((PASS + 1)); echo "PASS: $*"; }
fail() { FAIL=$((FAIL + 1)); echo "FAIL: $*"; }

expect_rc() {
  if [ "$RC" -eq "$1" ]; then
    pass "$2 → $1"
  else
    fail "$2 exit $RC != $1: $OUT"
  fi
}

expect_contains() {
  if printf '%s\n' "$OUT" | grep -Fq -- "$1"; then
    pass "output contains: $1"
  else
    fail "output missing: $1"
    printf '  out: %s\n' "$OUT" | head -c 400
    echo
  fi
}

run_check() { # run_check <repo-dir> <args...>
  RC=0
  OUT=$(cd "$1" && bash "$CHECK" "${@:2}" 2>&1) && RC=0 || RC=$?
}

run_check_here() { # run_check_here <cwd> <args...> — cwd need not be a repo
  RC=0
  OUT=$(cd "$1" 2>/dev/null && bash "$CHECK" "${@:2}" 2>&1) && RC=0 || RC=$?
}

make_repo() { # make_repo — tagged base commit on master, prints the dir
  local d
  d=$(mktemp -d "${TMPDIR:-/tmp}/master-tagged-XXXXXX")
  git -C "$d" init -q -b master
  git -C "$d" config user.email "test@example.com"
  git -C "$d" config user.name "Test"
  printf 'x\n' >"$d/f.txt"
  git -C "$d" add -A
  git -C "$d" commit -qm baseline
  git -C "$d" tag -a v1.0.0 -m "v1.0.0"
  printf '%s\n' "$d"
}

commit_on_master() { # commit_on_master <dir> <name>
  printf 'y\n' >"$1/$2"
  git -C "$1" add -A
  git -C "$1" commit -qm "$2"
  git -C "$1" rev-parse HEAD
}

make_push_repo() { # make_push_repo — hook + checker clone with a bare origin
  local d origin
  d=$(mktemp -d "${TMPDIR:-/tmp}/master-tagged-push-XXXXXX")
  origin="$d-origin.git"
  git init -q --bare "$origin"
  git -C "$d" init -q -b master
  git -C "$d" config user.email "test@example.com"
  git -C "$d" config user.name "Test"
  mkdir -p "$d/githooks" "$d/skills/release"
  cp "$HOOK_SRC" "$d/githooks/pre-push"
  chmod +x "$d/githooks/pre-push"
  cp "$CHECK" "$d/skills/release/check-master-tagged.sh"
  git -C "$d" config core.hooksPath githooks
  git -C "$d" remote add origin "$origin"
  printf 'x\n' >"$d/f.txt"
  git -C "$d" add -A
  git -C "$d" commit -qm baseline
  git -C "$d" tag v1.0.0
  git -C "$d" push -q origin master
  git -C "$d" remote set-head origin master
  printf '%s\n' "$d"
}

run_hook() { # run_hook <dir> <local-ref> <local-sha> <remote-ref> <remote-sha>
  RC=0
  OUT=$(cd "$1" && printf '%s %s %s %s\n' "$2" "$3" "$4" "$5" | bash "$HOOK_SRC" 2>&1) && RC=0 || RC=$?
}

# --- m1: tagged tip passes -------------------------------------------------
REPO=$(make_repo)
TIP=$(git -C "$REPO" rev-parse HEAD)
run_check "$REPO" "$TIP"
expect_rc 0 "annotated tag on the tip"
expect_contains "v1.0.0"

# --- m2: lightweight tag on the tip passes too -----------------------------
LW=$(make_repo)
git -C "$LW" tag -d v1.0.0 >/dev/null
commit_on_master "$LW" lw.txt >/dev/null
git -C "$LW" tag v1.0.1
run_check "$LW" "$(git -C "$LW" rev-parse HEAD)"
expect_rc 0 "lightweight tag on the tip"

# --- m3: tagged base + one untagged commit bites ---------------------------
UNTAGGED=$(make_repo)
BAD=$(commit_on_master "$UNTAGGED" extra.txt)
run_check "$UNTAGGED" "$BAD"
expect_rc 1 "untagged commit on master"
expect_contains "/release-train register"
expect_contains "CDT-597"

# --- m4: a tag on an ancestor does not rescue the tip ----------------------
DEEP=$(make_repo)
commit_on_master "$DEEP" a.txt >/dev/null
BAD2=$(commit_on_master "$DEEP" b.txt)
run_check "$DEEP" "$BAD2"
expect_rc 1 "tag two commits back does not rescue the tip"

# --- m5: usage errors → 64 -------------------------------------------------
run_check "$REPO"
expect_rc 64 "no args → 64"
run_check "$REPO" "$TIP" extra
expect_rc 64 "two args → 64"
run_check "$REPO" deadbeefdeadbeefdeadbeefdeadbeefdeadbeef
expect_rc 64 "unresolvable sha → 64"
run_check "$REPO" ""
expect_rc 64 "empty sha → 64"
NOREPO=$(mktemp -d "${TMPDIR:-/tmp}/master-tagged-norepo-XXXXXX")
run_check_here "$NOREPO" "$TIP"
expect_rc 64 "non-repo cwd → 64"

# --- m6: the hook bites a default-branch push, other refs pass -------------
PUSH=$(make_push_repo)
run_hook "$PUSH" refs/heads/master "$(git -C "$PUSH" rev-parse HEAD)" refs/heads/master "$(git -C "$PUSH" rev-parse HEAD)"
expect_rc 0 "hook: tagged master tip"
BADTIP=$(commit_on_master "$PUSH" ship.txt)
run_hook "$PUSH" refs/heads/master "$BADTIP" refs/heads/master "$(git -C "$PUSH" rev-parse HEAD~1)"
expect_rc 1 "hook: untagged master tip"
expect_contains "/release-train register"
RC=0
OUT=$(cd "$PUSH" && git push origin master 2>&1) && RC=0 || RC=$?
expect_rc 1 "git push origin master is blocked on an untagged tip"
git -C "$PUSH" tag v1.0.2
RC=0
OUT=$(cd "$PUSH" && git push -q origin master 2>&1) && RC=0 || RC=$?
expect_rc 0 "git push origin master passes once the tip is tagged"

# --- m6b: the /release Step 6 shape (tag, then atomic branch+tag push) passes
REL=$(make_push_repo)
commit_on_master "$REL" release.txt >/dev/null
git -C "$REL" tag v1.1.0
RC=0
OUT=$(cd "$REL" && git push -q --atomic origin refs/heads/master refs/tags/v1.1.0 2>&1) && RC=0 || RC=$?
expect_rc 0 "atomic branch+tag push (the /release fold) passes the hook"

FEAT=$(make_push_repo)
FEATTIP=$(commit_on_master "$FEAT" feat.txt)
git -C "$FEAT" checkout -q -b feat/thing
run_hook "$FEAT" refs/heads/feat/thing "$FEATTIP" refs/heads/feat/thing 0000000000000000000000000000000000000000
expect_rc 0 "hook: non-default remote ref is skipped"
RC=0
OUT=$(cd "$FEAT" && git push -q origin feat/thing 2>&1) && RC=0 || RC=$?
expect_rc 0 "git push origin feat/thing succeeds"
run_hook "$FEAT" refs/heads/master "$FEATTIP" refs/heads/master 0000000000000000000000000000000000000000
expect_rc 1 "hook: the all-zeros remote sha is a new default branch, not a deletion"
DEL_SHA=$(git -C "$FEAT" rev-parse HEAD)
run_hook "$FEAT" refs/heads/master 0000000000000000000000000000000000000000 refs/heads/master "$DEL_SHA"
expect_rc 0 "hook: a branch deletion (all-zeros local sha) is skipped"

# --- m7: the hook degrades when git has no describe ------------------------
SHIM=$(mktemp -d "${TMPDIR:-/tmp}/master-tagged-shim-XXXXXX")
REALGIT=$(command -v git)
{
  printf '#!/bin/sh\n'
  printf '[ "$1" = "--list-cmds=main" ] && exit 0\n'
  printf 'exec %s "$@"\n' "$REALGIT"
} >"$SHIM/git"
chmod +x "$SHIM/git"
RC=0
OUT=$(cd "$PUSH" && printf '%s %s %s %s\n' refs/heads/master "$BADTIP" refs/heads/master "$BADTIP" \
  | PATH="$SHIM:$PATH" bash "$HOOK_SRC" 2>&1) && RC=0 || RC=$?
expect_rc 0 "hook: git without describe degrades open"
expect_contains "describe"

# --- m8: the hook degrades when origin/HEAD is unresolvable ----------------
NOHEAD=$(make_push_repo)
git -C "$NOHEAD" symbolic-ref -d refs/remotes/origin/HEAD
NOHEADTIP=$(commit_on_master "$NOHEAD" lone.txt)
run_hook "$NOHEAD" refs/heads/master "$NOHEADTIP" refs/heads/master "$(git -C "$NOHEAD" rev-parse HEAD~1)"
expect_rc 0 "hook: unresolvable origin/HEAD degrades open"
expect_contains "origin/HEAD"

# --- m9: install-git-hooks.sh installs both hooks --------------------------
if [ -x "$HOOK_SRC" ]; then
  pass "githooks/pre-push exists and is executable"
else
  fail "githooks/pre-push missing or not executable"
fi
if grep -qF 'check-master-tagged.sh' "$HOOK_SRC"; then
  pass "githooks/pre-push execs the checker"
else
  fail "githooks/pre-push does not name check-master-tagged.sh"
fi
if grep -qF 'pre-push' "$INSTALL" && grep -qF 'pre-commit' "$INSTALL"; then
  pass "install-git-hooks.sh installs both hooks"
else
  fail "install-git-hooks.sh does not name both hooks"
fi
IH=$(mktemp -d "${TMPDIR:-/tmp}/master-tagged-install-XXXXXX")
git -C "$IH" init -q
git -C "$IH" config user.email "test@example.com"
git -C "$IH" config user.name "Test"
mkdir -p "$IH/githooks"
printf '#!/usr/bin/env bash\nexit 0\n' >"$IH/githooks/pre-commit"
printf '#!/usr/bin/env bash\nexit 0\n' >"$IH/githooks/pre-push"
RC=0
OUT=$(cd "$IH" && bash "$INSTALL" 2>&1) && RC=0 || RC=$?
expect_rc 0 "install-git-hooks: both hooks present"
if [ "$(git -C "$IH" config --get core.hooksPath)" = "githooks" ]; then
  pass "install-git-hooks: core.hooksPath=githooks set"
else
  fail "install-git-hooks: core.hooksPath not set: $OUT"
fi
rm "$IH/githooks/pre-push"
RC=0
OUT=$(cd "$IH" && bash "$INSTALL" 2>&1) && RC=0 || RC=$?
expect_rc 1 "install-git-hooks: missing githooks/pre-push → 1"
expect_contains "pre-push"

# --- m10: spec wiring ------------------------------------------------------
if grep -qF 'Verify: bash skills/release/test-master-tagged.sh' \
  "$REPO_ROOT/specs/core/SPEC-033-autopilot-policy.md"; then
  pass "SPEC-033 CDT-597 Verify points at this suite"
else
  fail "SPEC-033 CDT-597 Verify line missing"
fi
if grep -qF 'githooks/pre-push' "$REPO_ROOT/specs/core/SPEC-010-code-review-release.md"; then
  pass "SPEC-010 Covers lists githooks/pre-push"
else
  fail "SPEC-010 Covers does not list githooks/pre-push"
fi

printf '\nPASS=%d FAIL=%d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
