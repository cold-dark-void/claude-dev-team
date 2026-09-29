#!/usr/bin/env bash
# prune-remote-test.sh — bite-tests for wrap-ticket prune-remote.sh (CDT-157;
# WP 1-06 SPEC-016 wp-1-06-branch-deletion-safety AC C, D)
#
# Machine-check: bash skills/wrap-ticket/prune-remote-test.sh  (exit 0)
# Fixture git only: an in-repo bare remote (never a network remote). Live
# (non-dry-run) prune runs against these local bare fixtures.
# THIS SCRIPT IS A SUBPROCESS CLI — NEVER SOURCE IT.

set -u

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
PRUNE="$HERE/prune-remote.sh"
GIT_SAFETY="$HERE/../lib/git-safety.sh"
SKILL="$HERE/SKILL.md"
WT_LIB="$HERE/../worktree-lib.sh"

# shellcheck source=../../tests/lib/hermetic.sh
. "$HERE/../../tests/lib/hermetic.sh"
hermetic_init
export GIT_CONFIG_GLOBAL=/dev/null
export GIT_CONFIG_NOSYSTEM=1
unset GIT_DIR GIT_INDEX_FILE GIT_WORK_TREE

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

# No `set -e` toggle here: this suite never enables errexit (only `set -u`
# above), and flipping it on for a top-level `assert_rc` call used to leak
# `errexit` ON for the rest of the file — any later bare command that is
# expected to fail (e.g. "branch is gone") would abort the whole suite.
assert_rc() {
  local name="$1" want="$2"
  shift 2
  local rc
  "$@" >/dev/null 2>&1
  rc=$?
  assert_eq "$name" "$want" "$rc"
}

TMP=$(mktemp -d "${TMPDIR:-/tmp}/prune-remote-test.XXXXXX")
cleanup() { hermetic_cleanup; rm -rf "$TMP"; }
trap cleanup EXIT

new_repo() {
  local dir="$1"
  mkdir -p "$dir"
  git init -q -b master "$dir"
  git -C "$dir" config user.email "test@example.com"
  git -C "$dir" config user.name "Test"
  git -C "$dir" config commit.gpgsign false
}

new_bare() {
  git init -q --bare "$1"
}

# work_repo <dir> <bare-dir>: local repo with one base commit, origin set
# to <bare-dir>, master pushed. The base commit history a candidate merges
# into must be visible on origin/master (resolve-base reads the tracking
# ref once origin exists).
work_repo() {
  local dir="$1" bare="$2"
  new_repo "$dir"
  printf 'base\n' > "$dir/base.txt"
  git -C "$dir" add base.txt
  git -C "$dir" commit -q -m base
  new_bare "$bare"
  git -C "$dir" remote add origin "$bare"
  git -C "$dir" push -q origin master
}

run_in() {
  local dir="$1"
  shift
  (cd "$dir" && bash "$PRUNE" "$@")
}

# Write a git PATH shim at <dir>/git that intercepts `git push
# ...--force-with-lease=...`; every other git invocation (fetch, rev-parse,
# git-safety.sh's own calls) passes straight through to the real git.
# SPEC-003: one shape, one helper, used by both the D1 race case and the D3
# stub cases below (mode is the only thing that differs).
#
#   make_lease_shim <dir> stub <msg> <rc>
#     Print <msg> to stderr and exit <rc> instead of pushing. Proves the
#     "already gone" classifier boundary (AC D3) without depending on which
#     exact git version wording a genuine race produces.
#   make_lease_shim <dir> race <mover-dir> <flag-file>
#     Once (guarded by <flag-file>), push <mover-dir>'s HEAD to advance the
#     remote out from under the lease before delegating to the real push
#     (AC D1). <mover-dir> must already be checked out on the target branch
#     with a pending commit.
make_lease_shim() {
  local shimdir="$1" mode="$2" real_git
  real_git=$(command -v git)
  mkdir -p "$shimdir"
  case "$mode" in
    stub)
      local msg="$3" xrc="$4"
      cat > "$shimdir/git" <<SHIM_EOF
#!/usr/bin/env bash
REAL_GIT="$real_git"
if [ "\$1" = "push" ]; then
  for a in "\$@"; do
    case "\$a" in
      --force-with-lease=*)
        printf '%s\n' "$msg" >&2
        exit $xrc
        ;;
    esac
  done
fi
exec "\$REAL_GIT" "\$@"
SHIM_EOF
      ;;
    race)
      local mover="$3" flag="$4"
      cat > "$shimdir/git" <<SHIM_EOF
#!/usr/bin/env bash
REAL_GIT="$real_git"
if [ "\$1" = "push" ]; then
  for a in "\$@"; do
    case "\$a" in
      --force-with-lease=*)
        if [ ! -e "$flag" ]; then
          touch "$flag"
          "\$REAL_GIT" -C "$mover" push -q origin HEAD >/dev/null 2>&1
        fi
        ;;
    esac
  done
fi
exec "\$REAL_GIT" "\$@"
SHIM_EOF
      ;;
    *)
      printf 'make_lease_shim: unknown mode: %s\n' "$mode" >&2
      return 64
      ;;
  esac
  chmod +x "$shimdir/git"
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

# ---- AC2 / AC7 fixture: FF, squash, leftover (no-origin local fallback) ----
echo "== AC2 safety fixtures (local fallback, no origin) =="

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

# ---- AC D2 static: lease present, no bare --force ---------------------------
echo "== AC D2 static: lease, no bare --force =="
assert_file_match "helper has --force-with-lease" "$PRUNE" '--force-with-lease'
assert_file_nomatch "helper no bare --force" "$PRUNE" '--force([^-]|$)'
FIXTURE_BAREFORCE="$TMP/planted-bareforce.txt"
printf 'git push --force origin :refs/heads/x\n' > "$FIXTURE_BAREFORCE"
assert_file_match "static negative control: planted bare --force detected" "$FIXTURE_BAREFORCE" '--force([^-]|$)'

# ---- AC C1 static: fetch into refs/remotes/origin/<n>, is-merged on $ref ---
echo "== AC C1 static =="
assert_file_match "fetch targets refs/remotes/origin/<n>" "$PRUNE" 'refs/remotes/origin/\$\{name\}'
assert_file_match "is-merged invoked on the fetched ref" "$PRUNE" 'is-merged "\$ref" "\$base"'
assert_file_nomatch "is-merged never called directly on refs/heads/\$name" "$PRUNE" 'is-merged "refs/heads/\$name"'
FIXTURE_HEADSMATCH="$TMP/planted-headsmatch.sh"
printf 'bash "$GIT_SAFETY" is-merged "refs/heads/$name" "$base"\n' > "$FIXTURE_HEADSMATCH"
assert_file_match "static negative control: planted refs/heads/\$name is-merged call detected" "$FIXTURE_HEADSMATCH" 'is-merged "refs/heads/\$name"'

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

# ---- AC4 already-gone silent (no origin, never pushed) ----------------------
echo "== AC4 idempotent silent =="
GONE="$TMP/gone"
new_repo "$GONE"
git -C "$GONE" commit --allow-empty -q -m init
OUT=$(run_in "$GONE" prune CDT-157 --dry-run)
RC=$?
assert_eq "never-pushed dry-run exit 0" "0" "$RC"
assert_eq "never-pushed silent" "" "$OUT"

# ---- AC C3 bare-remote fixtures: FF and squash, dry-run and live -----------
echo "== AC C3 bare-remote FF / squash =="

BFF="$TMP/bff"; BFF_BARE="$TMP/bff-bare.git"
work_repo "$BFF" "$BFF_BARE"
git -C "$BFF" checkout -q -b feat/CDT-200
git -C "$BFF" commit --allow-empty -q -m feat
git -C "$BFF" checkout -q master
git -C "$BFF" merge -q --ff-only feat/CDT-200
git -C "$BFF" push -q origin master feat/CDT-200

OUT=$(run_in "$BFF" prune CDT-200 --dry-run)
RC=$?
assert_eq "bare FF dry-run exit 0" "0" "$RC"
assert_contains "bare FF dry-run pruned" "$OUT" "pruned: feat/CDT-200"
git -C "$BFF_BARE" show-ref --verify --quiet refs/heads/feat/CDT-200
assert_eq "bare FF dry-run deletes nothing" "0" "$?"

# regression: safe-to-delete must strip a caller-supplied "origin/" prefix
# even when origin exists (classify_candidate fetches by bare name).
run_in "$BFF" safe-to-delete origin/feat/CDT-200 --base master >/dev/null 2>&1
assert_eq "safe-to-delete origin/feat/X with origin present -> safe (rc0)" "0" "$?"

OUT=$(run_in "$BFF" prune CDT-200)
RC=$?
assert_eq "bare FF live exit 0" "0" "$RC"
assert_contains "bare FF live pruned" "$OUT" "pruned: feat/CDT-200"
git -C "$BFF_BARE" show-ref --verify --quiet refs/heads/feat/CDT-200
assert_eq "bare FF live: remote branch deleted" "1" "$?"

BSQ="$TMP/bsq"; BSQ_BARE="$TMP/bsq-bare.git"
work_repo "$BSQ" "$BSQ_BARE"
git -C "$BSQ" checkout -q -b feat/CDT-201
printf 'feat\n' > "$BSQ/g"
git -C "$BSQ" add g
git -C "$BSQ" commit -q -m feat
git -C "$BSQ" checkout -q master
git -C "$BSQ" merge -q --squash feat/CDT-201
git -C "$BSQ" commit -q -m squashed
git -C "$BSQ" push -q origin master feat/CDT-201

OUT=$(run_in "$BSQ" prune CDT-201 --dry-run)
RC=$?
assert_eq "bare squash dry-run exit 0" "0" "$RC"
assert_contains "bare squash dry-run pruned" "$OUT" "pruned: feat/CDT-201"

OUT=$(run_in "$BSQ" prune CDT-201)
RC=$?
assert_eq "bare squash live exit 0" "0" "$RC"
assert_contains "bare squash live pruned" "$OUT" "pruned: feat/CDT-201"
git -C "$BSQ_BARE" show-ref --verify --quiet refs/heads/feat/CDT-201
assert_eq "bare squash live: remote branch deleted" "1" "$?"

# ---- AC C4 dry-run fetches when origin exists; no-origin local fallback ----
echo "== AC C4 dry-run fetches; no-origin fallback =="

BDR="$TMP/bdr"; BDR_BARE="$TMP/bdr-bare.git"
work_repo "$BDR" "$BDR_BARE"
git -C "$BDR" checkout -q -b feat/CDT-202
git -C "$BDR" commit --allow-empty -q -m feat
git -C "$BDR" checkout -q master
git -C "$BDR" merge -q --ff-only feat/CDT-202
git -C "$BDR" push -q origin master feat/CDT-202
git -C "$BDR" update-ref -d refs/remotes/origin/feat/CDT-202 2>/dev/null
git -C "$BDR" rev-parse --verify --quiet refs/remotes/origin/feat/CDT-202 >/dev/null 2>&1
assert_eq "C4: no local tracking ref before dry-run" "1" "$?"
OUT=$(run_in "$BDR" prune CDT-202 --dry-run)
RC=$?
assert_eq "C4: dry-run exit 0" "0" "$RC"
assert_contains "C4: dry-run pruned (proves fetch ran)" "$OUT" "pruned: feat/CDT-202"
git -C "$BDR" rev-parse --verify --quiet refs/remotes/origin/feat/CDT-202 >/dev/null 2>&1
assert_eq "C4: dry-run populated the tracking ref" "0" "$?"
git -C "$BDR_BARE" show-ref --verify --quiet refs/heads/feat/CDT-202
assert_eq "C4: dry-run deletes nothing" "0" "$?"

NOORIG="$TMP/noorig"
new_repo "$NOORIG"
git -C "$NOORIG" commit --allow-empty -q -m base
git -C "$NOORIG" checkout -q -b feat/CDT-203
git -C "$NOORIG" commit --allow-empty -q -m feat
git -C "$NOORIG" checkout -q master
git -C "$NOORIG" merge -q --ff-only feat/CDT-203
OUT=$(run_in "$NOORIG" prune CDT-203 --dry-run)
RC=$?
assert_eq "no-origin dry-run exit 0" "0" "$RC"
assert_contains "no-origin dry-run local fallback pruned" "$OUT" "pruned: feat/CDT-203"

# ---- AC C5 fetch failure classification -------------------------------------
echo "== AC C5 fetch failure classification =="

BNP="$TMP/bnp"; BNP_BARE="$TMP/bnp-bare.git"
work_repo "$BNP" "$BNP_BARE"
OUT=$(run_in "$BNP" prune CDT-204)
RC=$?
assert_eq "origin present, branch never pushed: exit 0" "0" "$RC"
assert_eq "origin present, branch never pushed: silent (couldn't find remote ref)" "" "$OUT"

BADURL="$TMP/badurl"
new_repo "$BADURL"
git -C "$BADURL" commit --allow-empty -q -m base
git -C "$BADURL" checkout -q -b feat/CDT-205
git -C "$BADURL" commit --allow-empty -q -m feat
git -C "$BADURL" checkout -q master
git -C "$BADURL" remote add origin "$TMP/does-not-exist-bare.git"
OUT=$(run_in "$BADURL" prune CDT-205 2>/dev/null)
RC=$?
assert_eq "origin URL missing path: exit 0" "0" "$RC"
LINES=$(printf '%s\n' "$OUT" | grep -c '^remote prune failed: feat/CDT-205: ')
assert_eq "origin URL missing path: exactly one failure line" "1" "$LINES"
assert_not_contains "origin URL missing path: nothing pruned" "$OUT" "pruned:"

# ---- AC C2 remote ahead of a merged local branch ----------------------------
echo "== AC C2 remote ahead of a merged local branch =="

BAH="$TMP/bah"; BAH_BARE="$TMP/bah-bare.git"
work_repo "$BAH" "$BAH_BARE"
git -C "$BAH" checkout -q -b feat/CDT-9
git -C "$BAH" commit --allow-empty -q -m feat1
git -C "$BAH" checkout -q master
git -C "$BAH" merge -q --ff-only feat/CDT-9
git -C "$BAH" push -q origin master feat/CDT-9
MOVER2="$TMP/bah-mover"
git clone -q "$BAH_BARE" "$MOVER2" >/dev/null 2>&1
git -C "$MOVER2" checkout -q feat/CDT-9
git -C "$MOVER2" commit --allow-empty -q -m "unique remote-only commit"
git -C "$MOVER2" push -q origin feat/CDT-9

OUT=$(run_in "$BAH" prune CDT-9)
RC=$?
assert_eq "remote-ahead: exit 0" "0" "$RC"
assert_contains "remote-ahead: leftover (unique commits), not deleted" "$OUT" "leftover: feat/CDT-9 (unique commits)"
assert_not_contains "remote-ahead: not pruned" "$OUT" "pruned: feat/CDT-9"
git -C "$BAH_BARE" show-ref --verify --quiet refs/heads/feat/CDT-9
assert_eq "remote-ahead: remote branch survives" "0" "$?"

# stale local tracking ref: primed at the merged state, then the remote
# advances past it. The fresh fetch, not the stale cache, must decide.
BST="$TMP/bst"; BST_BARE="$TMP/bst-bare.git"
work_repo "$BST" "$BST_BARE"
git -C "$BST" checkout -q -b feat/CDT-10
git -C "$BST" commit --allow-empty -q -m feat1
git -C "$BST" checkout -q master
git -C "$BST" merge -q --ff-only feat/CDT-10
git -C "$BST" push -q origin master feat/CDT-10
git -C "$BST" fetch -q origin >/dev/null 2>&1
MOVER3="$TMP/bst-mover"
git clone -q "$BST_BARE" "$MOVER3" >/dev/null 2>&1
git -C "$MOVER3" checkout -q feat/CDT-10
git -C "$MOVER3" commit --allow-empty -q -m "unique remote-only commit"
git -C "$MOVER3" push -q origin feat/CDT-10

OUT=$(run_in "$BST" prune CDT-10)
RC=$?
assert_eq "stale tracking ref: exit 0" "0" "$RC"
assert_contains "stale tracking ref: leftover (fresh fetch beats stale cache)" "$OUT" "leftover: feat/CDT-10 (unique commits)"
git -C "$BST_BARE" show-ref --verify --quiet refs/heads/feat/CDT-10
assert_eq "stale tracking ref: remote branch survives" "0" "$?"

# ---- AC D1 lease race (real git, PATH shim) ---------------------------------
echo "== AC D1 lease race =="

BLR="$TMP/blr"; BLR_BARE="$TMP/blr-bare.git"
work_repo "$BLR" "$BLR_BARE"
git -C "$BLR" checkout -q -b feat/CDT-206
git -C "$BLR" commit --allow-empty -q -m feat
git -C "$BLR" checkout -q master
git -C "$BLR" merge -q --ff-only feat/CDT-206
git -C "$BLR" push -q origin master feat/CDT-206

MOVER="$TMP/blr-mover"
git clone -q "$BLR_BARE" "$MOVER" >/dev/null 2>&1
git -C "$MOVER" checkout -q feat/CDT-206
git -C "$MOVER" commit --allow-empty -q -m "race move"

SHIMDIR="$TMP/blr-shim"
MOVER_FLAG="$TMP/blr-mover.done"
make_lease_shim "$SHIMDIR" race "$MOVER" "$MOVER_FLAG"

OUT=$(cd "$BLR" && PATH="$SHIMDIR:$PATH" timeout 30 bash "$PRUNE" prune CDT-206)
RC=$?
assert_eq "lease race: exit 0" "0" "$RC"
assert_contains "lease race: reported as failure (stale info), not silent" "$OUT" "remote prune failed: feat/CDT-206:"
assert_not_contains "lease race: not reported as pruned" "$OUT" "pruned: feat/CDT-206"
git -C "$BLR_BARE" show-ref --verify --quiet refs/heads/feat/CDT-206
assert_eq "lease race: remote branch survives (moved, not deleted)" "0" "$?"
CUR_SHA=$(git -C "$BLR_BARE" rev-parse refs/heads/feat/CDT-206)
MOVER_SHA=$(git -C "$MOVER" rev-parse HEAD)
assert_eq "lease race: remote now at the mover's advanced commit" "$MOVER_SHA" "$CUR_SHA"

# ---- AC D3 push-stub classification (narrow is_already_gone) ---------------
echo "== AC D3 push-stub classification =="

BPS1="$TMP/bps1"; BPS1_BARE="$TMP/bps1-bare.git"
work_repo "$BPS1" "$BPS1_BARE"
git -C "$BPS1" checkout -q -b feat/CDT-207
git -C "$BPS1" commit --allow-empty -q -m feat
git -C "$BPS1" checkout -q master
git -C "$BPS1" merge -q --ff-only feat/CDT-207
git -C "$BPS1" push -q origin master feat/CDT-207
SHIM1="$TMP/bps1-shim"
make_lease_shim "$SHIM1" stub "fatal: repository 'https://example.invalid/x.git' does not exist" 128
OUT=$(cd "$BPS1" && PATH="$SHIM1:$PATH" timeout 30 bash "$PRUNE" prune CDT-207)
RC=$?
assert_eq "push stub repo-not-found: exit 0" "0" "$RC"
assert_contains "push stub repo-not-found: reported, not silent" "$OUT" "remote prune failed: feat/CDT-207:"
git -C "$BPS1_BARE" show-ref --verify --quiet refs/heads/feat/CDT-207
assert_eq "push stub repo-not-found: remote branch survives" "0" "$?"

BPS2="$TMP/bps2"; BPS2_BARE="$TMP/bps2-bare.git"
work_repo "$BPS2" "$BPS2_BARE"
git -C "$BPS2" checkout -q -b feat/CDT-208
git -C "$BPS2" commit --allow-empty -q -m feat
git -C "$BPS2" checkout -q master
git -C "$BPS2" merge -q --ff-only feat/CDT-208
git -C "$BPS2" push -q origin master feat/CDT-208
SHIM2="$TMP/bps2-shim"
make_lease_shim "$SHIM2" stub "fatal: Authentication failed for 'https://example.invalid/x.git'" 128
OUT=$(cd "$BPS2" && PATH="$SHIM2:$PATH" timeout 30 bash "$PRUNE" prune CDT-208)
RC=$?
assert_eq "push stub auth-failure: exit 0" "0" "$RC"
assert_contains "push stub auth-failure: reported, not silent" "$OUT" "remote prune failed: feat/CDT-208:"

BPS3="$TMP/bps3"; BPS3_BARE="$TMP/bps3-bare.git"
work_repo "$BPS3" "$BPS3_BARE"
git -C "$BPS3" checkout -q -b feat/CDT-209
git -C "$BPS3" commit --allow-empty -q -m feat
git -C "$BPS3" checkout -q master
git -C "$BPS3" merge -q --ff-only feat/CDT-209
git -C "$BPS3" push -q origin master feat/CDT-209
SHIM3="$TMP/bps3-shim"
make_lease_shim "$SHIM3" stub "error: unable to delete 'feat/CDT-209': remote ref does not exist" 1
OUT=$(cd "$BPS3" && PATH="$SHIM3:$PATH" timeout 30 bash "$PRUNE" prune CDT-209)
RC=$?
assert_eq "push stub already-gone (remote ref does not exist): exit 0" "0" "$RC"
assert_eq "push stub already-gone (remote ref does not exist): silent" "" "$OUT"

BPS4="$TMP/bps4"; BPS4_BARE="$TMP/bps4-bare.git"
work_repo "$BPS4" "$BPS4_BARE"
git -C "$BPS4" checkout -q -b feat/CDT-210
git -C "$BPS4" commit --allow-empty -q -m feat
git -C "$BPS4" checkout -q master
git -C "$BPS4" merge -q --ff-only feat/CDT-210
git -C "$BPS4" push -q origin master feat/CDT-210
SHIM4="$TMP/bps4-shim"
make_lease_shim "$SHIM4" stub "error: src refspec feat/CDT-210 does not match any" 1
OUT=$(cd "$BPS4" && PATH="$SHIM4:$PATH" timeout 30 bash "$PRUNE" prune CDT-210)
RC=$?
assert_eq "push stub already-gone (src refspec does not match): exit 0" "0" "$RC"
assert_eq "push stub already-gone (src refspec does not match): silent" "" "$OUT"

# ---- AC D4 two failing candidates -> exactly two lines ----------------------
echo "== AC D4 two failing candidates =="

BTWO="$TMP/btwo"; BTWO_BARE="$TMP/btwo-bare.git"
work_repo "$BTWO" "$BTWO_BARE"
git -C "$BTWO" checkout -q -b feat/CDT-211
git -C "$BTWO" commit --allow-empty -q -m feat1
git -C "$BTWO" checkout -q master
git -C "$BTWO" merge -q --ff-only feat/CDT-211
git -C "$BTWO" checkout -q -b feat/LIN-99
git -C "$BTWO" commit --allow-empty -q -m feat2
git -C "$BTWO" checkout -q master
git -C "$BTWO" merge -q --ff-only feat/LIN-99
git -C "$BTWO" push -q origin master feat/CDT-211 feat/LIN-99
SHIM5="$TMP/btwo-shim"
make_lease_shim "$SHIM5" stub "fatal: repository 'https://example.invalid/x.git' does not exist" 128
OUT=$(cd "$BTWO" && PATH="$SHIM5:$PATH" timeout 30 bash "$PRUNE" prune CDT-211 --linear-id LIN-99)
RC=$?
assert_eq "two failures: exit 0" "0" "$RC"
LINES=$(printf '%s\n' "$OUT" | grep -c '^remote prune failed: feat/')
assert_eq "two failures: exactly two failure lines" "2" "$LINES"
assert_contains "two failures: CDT-211 line" "$OUT" "remote prune failed: feat/CDT-211:"
assert_contains "two failures: LIN-99 line" "$OUT" "remote prune failed: feat/LIN-99:"
TOTAL_LINES=$(printf '%s\n' "$OUT" | grep -c .)
assert_eq "two failures: no other output lines" "2" "$TOTAL_LINES"

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

# ---- AC I: resolve_base delegates, no copy of the order list ---------------
echo "== AC I no copy of the base order =="
assert_file_nomatch "prune-remote.sh has no copy of the base order" "$PRUNE" 'origin/master origin/main master main'
assert_file_match "prune-remote.sh delegates to git-safety.sh resolve-base" "$PRUNE" 'GIT_SAFETY.*resolve-base'

echo
echo "PASS=$PASS FAIL=$FAIL"
if [ "$FAIL" -ne 0 ]; then
  exit 1
fi
exit 0
