#!/usr/bin/env bash
# SPEC-010 ship-start.sh + push-release.sh fixtures. Isolated temp repos and
# local bare remotes only — no network. Run: bash skills/release/test-ship-steps.sh
set -u

HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "$HERE/../.." && pwd)
. "$REPO_ROOT/tests/lib/hermetic.sh"
hermetic_init

SHIP_START="$HERE/ship-start.sh"
PUSH_RELEASE="$HERE/push-release.sh"

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

field() {
  # field NAME <<<"$OUT" -> value after NAME=
  printf '%s\n' "$OUT" | sed -n "s/^$1=//p"
}

make_repo() {
  local d
  d=$(mktemp -d "${TMPDIR:-/tmp}/ship-steps-XXXXXX")
  git -C "$d" init -q -b master
  git -C "$d" config user.email "test@example.com"
  git -C "$d" config user.name "Test"
  printf 'x\n' >"$d/f.txt"
  write_changelog_section "$d" "0.0.1" "baseline" "fixture"
  git -C "$d" add f.txt CHANGELOG.md
  git -C "$d" commit -q -m "fix: v0.0.1 — baseline"
  printf '%s\n' "$d"
}

# =========================== ship-start.sh ==================================

# --help → 0, usage on stdout
RC=0
OUT=$(bash "$SHIP_START" --help 2>&1) && RC=0 || RC=$?
expect_rc 0 "ship-start --help"
expect_contains "Usage: ship-start.sh"

# unknown flag → 64
RC=0
OUT=$(bash "$SHIP_START" --nope 2>&1) && RC=0 || RC=$?
expect_rc 64 "ship-start unknown flag"

# not a git repo
NOT_GIT=$(mktemp -d "${TMPDIR:-/tmp}/ship-steps-nogit-XXXXXX")
RC=0
OUT=$(cd "$NOT_GIT" && bash "$SHIP_START" 2>&1) && RC=0 || RC=$?
expect_rc 64 "ship-start not-a-repo"
rm -rf "$NOT_GIT"

# tagless repo: exit 0, LAST_TAG empty, snapshot exists and is empty
REPO=$(make_repo)
RC=0
OUT=$(cd "$REPO" && bash "$SHIP_START" 2>&1) && RC=0 || RC=$?
expect_rc 0 "ship-start tagless"
LAST_TAG=$(field LAST_TAG)
[ -z "$LAST_TAG" ] && pass "tagless LAST_TAG empty" || fail "tagless LAST_TAG not empty: $LAST_TAG"
SNAP=$(field TAG_SNAPSHOT)
if [ -f "$SNAP" ] && [ ! -s "$SNAP" ]; then
  pass "tagless snapshot exists and is empty"
else
  fail "tagless snapshot missing/nonempty: $SNAP"
fi
BEFORE_STATUS=$(git -C "$REPO" status --porcelain)
[ -z "$BEFORE_STATUS" ] && pass "ship-start leaves worktree clean" || fail "ship-start dirtied worktree: $BEFORE_STATUS"

GITDIR=$(git -C "$REPO" rev-parse --absolute-git-dir)
case "$SNAP" in
  "$GITDIR"/dev-team-release/tags-*.tsv) pass "snapshot path under git dir" ;;
  *) fail "snapshot path not under git dir: $SNAP" ;;
esac

# After a lightweight and an annotated tag: LAST_TAG=v0.1.0, snapshot lines
git -C "$REPO" tag v0.1.0
git -C "$REPO" tag -a v0.2.0 -m "annotated" 2>/dev/null
ANN_COMMIT=$(git -C "$REPO" rev-parse v0.2.0^{commit})
RC=0
OUT=$(cd "$REPO" && bash "$SHIP_START" 2>&1) && RC=0 || RC=$?
expect_rc 0 "ship-start with tags"
LAST_TAG=$(field LAST_TAG)
[ "$LAST_TAG" = "v0.2.0" ] || [ "$LAST_TAG" = "v0.1.0" ] && pass "LAST_TAG set: $LAST_TAG" || fail "LAST_TAG unexpected: $LAST_TAG"
SNAP=$(field TAG_SNAPSHOT)
if grep -qxF "$(printf 'refs/tags/v0.1.0\t%s' "$(git -C "$REPO" rev-parse v0.1.0^{commit})")" "$SNAP"; then
  pass "lightweight tag line correct"
else
  fail "lightweight tag line missing: $(cat "$SNAP")"
fi
if grep -qxF "$(printf 'refs/tags/v0.2.0\t%s' "$ANN_COMMIT")" "$SNAP"; then
  pass "annotated tag peeled line correct"
else
  fail "annotated tag peeled line missing: $(cat "$SNAP")"
fi

# Ambient SHIP_START_SHA (abbrev) → SHIP_START is the full SHA
ABBREV=$(git -C "$REPO" rev-parse --short HEAD)
FULL=$(git -C "$REPO" rev-parse HEAD)
RC=0
OUT=$(cd "$REPO" && SHIP_START_SHA="$ABBREV" bash "$SHIP_START" 2>&1) && RC=0 || RC=$?
expect_rc 0 "ship-start ambient sha"
SS=$(field SHIP_START)
[ "$SS" = "$FULL" ] && pass "ambient SHA resolves to full SHA" || fail "ambient SHA mismatch: $SS != $FULL"

# bad ambient SHA → 64
RC=0
OUT=$(cd "$REPO" && SHIP_START_SHA="deadbeef" bash "$SHIP_START" 2>&1) && RC=0 || RC=$?
expect_rc 64 "ship-start bad ambient sha"
expect_contains "unresolvable ambient SHIP_START_SHA"

# --path SHA equals TAG_SNAPSHOT for that SHA
RC=0
OUT=$(cd "$REPO" && bash "$SHIP_START" --path "$FULL" 2>&1) && RC=0 || RC=$?
expect_rc 0 "ship-start --path"
PATH_OUT="$OUT"
[ "$PATH_OUT" = "$GITDIR/dev-team-release/tags-$FULL.tsv" ] && pass "--path matches snapshot naming" || fail "--path mismatch: $PATH_OUT"

# --path with unresolvable SHA → 64
RC=0
OUT=$(cd "$REPO" && bash "$SHIP_START" --path nosuchsha 2>&1) && RC=0 || RC=$?
expect_rc 64 "ship-start --path bad sha"

# second run with a different HEAD sweeps the first file
printf 'y\n' >>"$REPO/f.txt"
git -C "$REPO" commit -qam "fix: v0.0.2 — second"
FIRST_FILE="$GITDIR/dev-team-release/tags-$FULL.tsv"
[ -f "$FIRST_FILE" ] && pass "first snapshot exists before sweep" || fail "first snapshot missing before sweep"
RC=0
OUT=$(cd "$REPO" && bash "$SHIP_START" 2>&1) && RC=0 || RC=$?
expect_rc 0 "ship-start second run"
if [ -f "$FIRST_FILE" ]; then
  fail "stale snapshot not swept: $FIRST_FILE"
else
  pass "stale snapshot swept"
fi
COUNT=$(find "$GITDIR/dev-team-release" -maxdepth 1 -name 'tags-*.tsv' | wc -l)
[ "$COUNT" -eq 1 ] && pass "exactly one snapshot after sweep" || fail "snapshot count after sweep: $COUNT"

# --clear removes every snapshot; dir removed when empty
RC=0
OUT=$(cd "$REPO" && bash "$SHIP_START" --clear 2>&1) && RC=0 || RC=$?
expect_rc 0 "ship-start --clear"
if [ -d "$GITDIR/dev-team-release" ] && [ -n "$(ls -A "$GITDIR/dev-team-release" 2>/dev/null)" ]; then
  fail "--clear left snapshots"
else
  pass "--clear left no snapshots"
fi

# linked worktree: path is under the worktree's own git dir
WT=$(mktemp -d "${TMPDIR:-/tmp}/ship-steps-wt-XXXXXX")
rmdir "$WT"
git -C "$REPO" worktree add -q -b wt-branch "$WT" HEAD >/dev/null 2>&1
if [ -d "$WT" ]; then
  WT_GITDIR=$(git -C "$WT" rev-parse --absolute-git-dir)
  RC=0
  OUT=$(cd "$WT" && bash "$SHIP_START" 2>&1) && RC=0 || RC=$?
  expect_rc 0 "ship-start in linked worktree"
  SNAP=$(field TAG_SNAPSHOT)
  case "$SNAP" in
    "$WT_GITDIR"/dev-team-release/*) pass "linked worktree snapshot under its own git dir" ;;
    *) fail "linked worktree snapshot path wrong: $SNAP (gitdir=$WT_GITDIR)" ;;
  esac
  git -C "$REPO" worktree remove -f "$WT" >/dev/null 2>&1
else
  fail "linked worktree not created"
fi

rm -rf "$REPO"

# =========================== push-release.sh =================================

setup_push_repo() {
  local d rd
  d=$(mktemp -d "${TMPDIR:-/tmp}/ship-steps-push-XXXXXX")
  git -C "$d" init -q -b master
  git -C "$d" config user.email "test@example.com"
  git -C "$d" config user.name "Test"
  printf 'x\n' >"$d/f.txt"
  write_changelog_section "$d" "0.1.0" "baseline" "fixture"
  git -C "$d" add f.txt CHANGELOG.md
  git -C "$d" commit -q -m "fix: v0.1.0 — baseline"
  git -C "$d" tag v0.1.0
  rd=$(mktemp -d "${TMPDIR:-/tmp}/ship-steps-remote-XXXXXX")
  git init -q --bare "$rd"
  git -C "$d" remote add origin "$rd"
  printf 'y\n' >>"$d/f.txt"
  git -C "$d" commit -qam "fix: junk parent"
  git -C "$d" tag junk
  git -C "$d" tag v0.0.9
  git -C "$d" reset -q --hard v0.1.0
  printf '%s %s' "$d" "$rd"
}


READ=$(setup_push_repo)
REPO=${READ% *}
REMOTE=${READ##* }

# --help
RC=0
OUT=$(bash "$PUSH_RELEASE" --help 2>&1) && RC=0 || RC=$?
expect_rc 0 "push-release --help"
expect_contains "Usage: push-release.sh"

# missing --tag → 64
RC=0
OUT=$(cd "$REPO" && bash "$PUSH_RELEASE" 2>&1) && RC=0 || RC=$?
expect_rc 64 "push-release missing --tag"

# bad tag format → 64
RC=0
OUT=$(cd "$REPO" && bash "$PUSH_RELEASE" --tag notasemver 2>&1) && RC=0 || RC=$?
expect_rc 64 "push-release bad tag format"

# missing tag → 64
RC=0
OUT=$(cd "$REPO" && bash "$PUSH_RELEASE" --tag v9.9.9 --remote origin 2>&1) && RC=0 || RC=$?
expect_rc 64 "push-release missing tag"

# tag not at HEAD → 64
RC=0
OUT=$(cd "$REPO" && bash "$PUSH_RELEASE" --tag v0.0.9 --remote origin 2>&1) && RC=0 || RC=$?
expect_rc 64 "push-release tag not at HEAD"
expect_contains "points at"

REMOTE_BEFORE=$(git -C "$REMOTE" for-each-ref)

# detached HEAD → 64, remote unchanged
git -C "$REPO" checkout -q --detach
RC=0
OUT=$(cd "$REPO" && bash "$PUSH_RELEASE" --tag v0.1.0 --remote origin 2>&1) && RC=0 || RC=$?
expect_rc 64 "push-release detached HEAD"
expect_contains "detached HEAD"
expect_contains "push-release: detached HEAD"
expect_contains "nothing pushed"
expect_not_contains "re-run /release"
REMOTE_AFTER=$(git -C "$REMOTE" for-each-ref)
[ "$REMOTE_BEFORE" = "$REMOTE_AFTER" ] && pass "detached HEAD leaves remote unchanged" || fail "remote changed on detached-HEAD failure"
git -C "$REPO" checkout -q master

# --print: one line, has --atomic, refs/heads/<branch>, refs/tags/v0.1.0; remote unchanged
RC=0
OUT=$(cd "$REPO" && bash "$PUSH_RELEASE" --tag v0.1.0 --remote origin --print 2>&1) && RC=0 || RC=$?
expect_rc 0 "push-release --print"
LINES=$(printf '%s\n' "$OUT" | wc -l)
[ "$LINES" -eq 1 ] && pass "--print is one line" || fail "--print produced $LINES lines: $OUT"
expect_contains "--atomic"
expect_contains "refs/heads/master"
expect_contains "refs/tags/v0.1.0"
REMOTE_AFTER=$(git -C "$REMOTE" for-each-ref)
[ "$REMOTE_BEFORE" = "$REMOTE_AFTER" ] && pass "--print leaves remote unchanged" || fail "--print changed remote"

# real push: remote gets branch + v0.1.0 tag, not junk / v0.0.9
RC=0
OUT=$(cd "$REPO" && bash "$PUSH_RELEASE" --tag v0.1.0 --remote origin 2>&1) && RC=0 || RC=$?
expect_rc 0 "push-release real push"
expect_contains "pushed refs/heads/master"

LS=$(git ls-remote "$REMOTE")
HEAD_SHA=$(git -C "$REPO" rev-parse HEAD)
if printf '%s\n' "$LS" | grep -q "^$HEAD_SHA[[:space:]]refs/heads/master$"; then
  pass "remote branch matches HEAD"
else
  fail "remote branch mismatch: $LS"
fi
if printf '%s\n' "$LS" | grep -q "refs/tags/v0.1.0$"; then
  pass "remote has v0.1.0 tag"
else
  fail "remote missing v0.1.0 tag: $LS"
fi
if printf '%s\n' "$LS" | grep -q "refs/tags/junk"; then
  fail "remote unexpectedly has junk tag"
else
  pass "remote has no junk tag"
fi
if printf '%s\n' "$LS" | grep -q "refs/tags/v0.0.9"; then
  fail "remote unexpectedly has v0.0.9 tag"
else
  pass "remote has no v0.0.9 tag"
fi

# followTags regression (B1 review): push.followTags=true must not leak an
# unpushed annotated tag that is reachable from the branch/tag being pushed.
FT_REPO=$(mktemp -d "${TMPDIR:-/tmp}/ship-steps-followtags-XXXXXX")
git -C "$FT_REPO" init -q -b master
git -C "$FT_REPO" config user.email "test@example.com"
git -C "$FT_REPO" config user.name "Test"
printf 'x\n' >"$FT_REPO/f.txt"
write_changelog_section "$FT_REPO" "0.0.8" "base" "fixture"
git -C "$FT_REPO" add f.txt CHANGELOG.md
git -C "$FT_REPO" commit -q -m "fix: v0.0.8 — base"
git -C "$FT_REPO" tag -a v0.0.9-stale -m "stale annotated at HEAD~1"
printf 'y\n' >>"$FT_REPO/f.txt"
write_changelog_section "$FT_REPO" "0.1.0" "tip" "fixture"
git -C "$FT_REPO" add CHANGELOG.md
git -C "$FT_REPO" commit -qam "fix: v0.1.0 — tip"
git -C "$FT_REPO" tag v0.1.0
FT_REMOTE=$(mktemp -d "${TMPDIR:-/tmp}/ship-steps-followtags-remote-XXXXXX")
git init -q --bare "$FT_REMOTE"
git -C "$FT_REPO" remote add origin "$FT_REMOTE"
git -C "$FT_REPO" config push.followTags true
RC=0
OUT=$(cd "$FT_REPO" && bash "$PUSH_RELEASE" --tag v0.1.0 --remote origin 2>&1) && RC=0 || RC=$?
expect_rc 0 "push-release with push.followTags=true"
FT_LS=$(git ls-remote "$FT_REMOTE")
if printf '%s\n' "$FT_LS" | grep -q "refs/tags/v0.0.9-stale"; then
  fail "push.followTags leaked unpushed annotated tag v0.0.9-stale onto remote"
else
  pass "push.followTags=true does not leak an unpushed annotated tag"
fi
if printf '%s\n' "$FT_LS" | grep -q "refs/tags/v0.1.0$"; then
  pass "followTags fixture: intended tag v0.1.0 still pushed"
else
  fail "followTags fixture: intended tag v0.1.0 missing: $FT_LS"
fi
rm -rf "$FT_REPO" "$FT_REMOTE"

# Atomic: non-fast-forward push fails whole, tag not on remote, message names "Run by hand"
CLONE=$(mktemp -d "${TMPDIR:-/tmp}/ship-steps-clone-XXXXXX")
rmdir "$CLONE"
git clone -q "$REMOTE" "$CLONE" >/dev/null 2>&1
git -C "$CLONE" config user.email "test@example.com"
git -C "$CLONE" config user.name "Test"
printf 'z\n' >>"$CLONE/f.txt"
git -C "$CLONE" commit -qam "fix: v0.1.1 — from other clone"
git -C "$CLONE" push -q origin master

write_changelog_section "$REPO" "0.1.2" "nff fold" "fixture"
git -C "$REPO" add CHANGELOG.md
git -C "$REPO" commit -q -m "fix: v0.1.2 — nff fold"
git -C "$REPO" tag v0.1.2
RC=0
OUT=$(cd "$REPO" && bash "$PUSH_RELEASE" --tag v0.1.2 --remote origin 2>&1) && RC=0 || RC=$?
expect_rc 1 "push-release non-fast-forward"
expect_contains "Run by hand"
LS=$(git ls-remote "$REMOTE")
if printf '%s\n' "$LS" | grep -q "refs/tags/v0.1.2"; then
  fail "remote unexpectedly has v0.1.2 tag after failed atomic push"
else
  pass "remote has no v0.1.2 tag after failed atomic push"
fi

rm -rf "$REPO" "$REMOTE" "$CLONE"

# D2 mismatch: exit 1, remote unchanged, output has D2: + expected subject
MM=$(mktemp -d "${TMPDIR:-/tmp}/ship-steps-d2-XXXXXX")
git -C "$MM" init -q -b master
git -C "$MM" config user.email "test@example.com"
git -C "$MM" config user.name "Test"
printf 'x\n' >"$MM/f.txt"
write_changelog_section "$MM" "0.1.0" "correct lead" "fixture"
git -C "$MM" add f.txt CHANGELOG.md
git -C "$MM" commit -q -m "feat: v0.1.0 — wrong summary"
git -C "$MM" tag v0.1.0
MM_REMOTE=$(mktemp -d "${TMPDIR:-/tmp}/ship-steps-d2-remote-XXXXXX")
git init -q --bare "$MM_REMOTE"
git -C "$MM" remote add origin "$MM_REMOTE"
REMOTE_BEFORE=$(git -C "$MM_REMOTE" for-each-ref)
RC=0
OUT=$(cd "$MM" && bash "$PUSH_RELEASE" --tag v0.1.0 --remote origin 2>&1) && RC=0 || RC=$?
expect_rc 1 "push-release D2 mismatch"
expect_contains "D2:"
expect_contains "feat: v0.1.0 — correct lead"
REMOTE_AFTER=$(git -C "$MM_REMOTE" for-each-ref)
[ "$REMOTE_BEFORE" = "$REMOTE_AFTER" ] && pass "D2 mismatch leaves remote unchanged" || fail "D2 mismatch changed remote"
# --print skips D2 and still pushes nothing
RC=0
OUT=$(cd "$MM" && bash "$PUSH_RELEASE" --tag v0.1.0 --remote origin --print 2>&1) && RC=0 || RC=$?
expect_rc 0 "push-release --print skips D2"
expect_contains "--atomic"
REMOTE_AFTER=$(git -C "$MM_REMOTE" for-each-ref)
[ "$REMOTE_BEFORE" = "$REMOTE_AFTER" ] && pass "--print on D2-mismatch still leaves remote unchanged" || fail "--print changed remote"
rm -rf "$MM" "$MM_REMOTE"

# =========================== static (AC A) ====================================

STATIC_DIR="$REPO_ROOT/skills/release $REPO_ROOT/skills/release-train"
HITS=$(grep -rEn 'push[^|]*--tags' $STATIC_DIR --include='*.sh' --include='*.md' 2>/dev/null |
  grep -Ev '(^|/)(test[^/]*\.sh|[^/]*-test\.sh)(:|$)' |
  grep -Ev '/fixtures/')
if [ -z "$HITS" ]; then
  pass "no push --tags literal outside test/fixtures"
else
  fail "push --tags literal found: $HITS"
fi

echo "PASS=$PASS FAIL=$FAIL"
if [ "$FAIL" -eq 0 ]; then
  exit 0
else
  exit 1
fi
