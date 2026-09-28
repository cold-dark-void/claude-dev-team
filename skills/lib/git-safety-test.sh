#!/usr/bin/env bash
# skills/lib/git-safety-test.sh — unit tests for git-safety.sh (SPEC-025 M17, AC A, AC B).
# Run: bash skills/lib/git-safety-test.sh
set -u

HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
LIB="$HERE/git-safety.sh"
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
  if [ "$want" = "$got" ]; then pass "$name"; else fail "$name" "want='$want' got='$got'"; fi
}

WORK="$HERMETIC_ROOT/work"
mkdir -p "$WORK"

gs() { # <dir> <sub> [args...]
  local d="$1"; shift
  bash "$LIB" -C "$d" "$@" 2>"$WORK/.last_stderr"
}

new_repo() {
  local d="$1"
  mkdir -p "$d"
  ( cd "$d" && git init -q && git symbolic-ref HEAD refs/heads/master ) >/dev/null 2>&1
}

commit_all() {
  local d="$1" msg="$2"
  ( cd "$d" && git add -A && git commit -q -m "$msg" ) >/dev/null 2>&1
}

rev() { ( cd "$1" && git rev-parse "$2" ) 2>/dev/null; }

# ============================================================================
# is-clean
# ============================================================================

d="$WORK/ic_clean"; new_repo "$d"
printf 'a\n' > "$d/a.txt"; commit_all "$d" "c1"
gs "$d" is-clean; assert_eq "is-clean: clean tree" "0" "$?"

d="$WORK/ic_staged"; new_repo "$d"
printf 'a\n' > "$d/a.txt"; commit_all "$d" "c1"
printf 'b\n' > "$d/b.txt"; ( cd "$d" && git add b.txt ) >/dev/null 2>&1
gs "$d" is-clean; assert_eq "is-clean: staged addition -> dirty" "1" "$?"

d="$WORK/ic_unstaged"; new_repo "$d"
printf 'a\n' > "$d/a.txt"; commit_all "$d" "c1"
printf 'a2\n' > "$d/a.txt"
gs "$d" is-clean; assert_eq "is-clean: unstaged edit -> dirty" "1" "$?"

d="$WORK/ic_untracked"; new_repo "$d"
printf 'a\n' > "$d/a.txt"; commit_all "$d" "c1"
printf 'x\n' > "$d/user-notes.txt"
gs "$d" is-clean; assert_eq "is-clean: untracked -> dirty (default)" "1" "$?"
gs "$d" is-clean --tracked-only; assert_eq "is-clean --tracked-only: untracked ignored -> clean" "0" "$?"

d="$WORK/ic_ignored"; new_repo "$d"
printf 'a\n' > "$d/a.txt"; printf 'ignored-file\n' > "$d/.gitignore"; commit_all "$d" "c1"
printf 'x\n' > "$d/ignored-file"
gs "$d" is-clean; assert_eq "is-clean: ignored file not counted" "0" "$?"

d="$WORK/ic_ignstaged1"; new_repo "$d"
printf 'a\n' > "$d/a.txt"; commit_all "$d" "c1"
printf 'x\n' > "$d/user-notes.txt"; ( cd "$d" && git add user-notes.txt ) >/dev/null 2>&1
gs "$d" is-clean --ignore-staged; assert_eq "is-clean --ignore-staged: pure staged add -> clean" "0" "$?"

d="$WORK/ic_ignstaged2"; new_repo "$d"
printf 'a\n' > "$d/a.txt"; commit_all "$d" "c1"
printf 'x\n' > "$d/user-notes.txt"; ( cd "$d" && git add user-notes.txt ) >/dev/null 2>&1
printf 'x2\n' >> "$d/user-notes.txt"
gs "$d" is-clean --ignore-staged; assert_eq "is-clean --ignore-staged: staged+unstaged edit -> dirty" "1" "$?"

d="$WORK/ic_excl"; new_repo "$d"
printf 'a\n' > "$d/a.txt"; commit_all "$d" "c1"
mkdir -p "$d/excl-dir"; printf 'x\n' > "$d/excl-dir/f.txt"
printf 'x\n' > "$d/excl-file.txt"
gs "$d" is-clean -- excl-dir excl-file.txt; assert_eq "is-clean: excluded dir+file -> clean" "0" "$?"
gs "$d" is-clean -- excl-dir; assert_eq "is-clean: only dir excluded, file still counted -> dirty" "1" "$?"

gs "$WORK/ic_clean" is-clean -- /absolute; assert_eq "is-clean: absolute exclude -> usage 64" "64" "$?"
gs "$WORK/ic_clean" is-clean -- ':weird'; assert_eq "is-clean: exclude starting ':' -> usage 64" "64" "$?"
gs "$WORK/ic_clean" bogus-sub; assert_eq "unknown subcommand -> usage 64" "64" "$?"
gs "$WORK/ic_clean" is-merged onlyonearg; assert_eq "is-merged: missing arg -> usage 64" "64" "$?"

# ============================================================================
# is-merged
# ============================================================================

d="$WORK/im_ancestor"; new_repo "$d"
printf 'l1\n' > "$d/f.txt"; commit_all "$d" "c1"
early=$(rev "$d" HEAD)
printf 'l1\nl2\n' > "$d/f.txt"; commit_all "$d" "c2"
base=$(rev "$d" HEAD)
gs "$d" is-merged "$early" "$base"; assert_eq "is-merged: L1 ancestor" "0" "$?"

d="$WORK/im_cherry"; new_repo "$d"
printf 'l1\n' > "$d/f.txt"; commit_all "$d" "base"
anc=$(rev "$d" HEAD)
( cd "$d" && git checkout -q -b feat ) >/dev/null 2>&1
printf 'l1\nl2\n' > "$d/f.txt"; commit_all "$d" "feat c1"
feat_tip=$(rev "$d" HEAD)
( cd "$d" && git checkout -q master ) >/dev/null 2>&1
printf 'l1\nl2\n' > "$d/f.txt"; commit_all "$d" "same change on master"
base_tip=$(rev "$d" HEAD)
gs "$d" is-merged "$feat_tip" "$base_tip"; assert_eq "is-merged: L2 cherry-picked (patch-equivalent)" "0" "$?"

d="$WORK/im_l3"; new_repo "$d"
printf 'l1\n' > "$d/f.txt"; commit_all "$d" "base"
anc=$(rev "$d" HEAD)
( cd "$d" && git checkout -q -b feat ) >/dev/null 2>&1
printf 'l1\nl2\n' > "$d/f.txt"; commit_all "$d" "feat c1"
printf 'l1\nl2\nl3\n' > "$d/f.txt"; commit_all "$d" "feat c2"
feat_tip=$(rev "$d" HEAD)
( cd "$d" && git checkout -q master ) >/dev/null 2>&1
( cd "$d" && git merge --squash feat -q ) >/dev/null 2>&1
commit_all "$d" "squash"
base_tip=$(rev "$d" HEAD)
gs "$d" is-merged "$feat_tip" "$base_tip"; assert_eq "is-merged: L3 synthetic squash-merged" "0" "$?"

# squash-then-base-diverged: amend the squash commit so its tree no longer
# matches feat_tip's tree/patch.
printf 'l1\nl2\nl3\nEXTRA\n' > "$d/f.txt"
( cd "$d" && git add -A && git commit -q --amend -m "squash diverged" ) >/dev/null 2>&1
base_tip_diverged=$(rev "$d" HEAD)
gs "$d" is-merged "$feat_tip" "$base_tip_diverged"; assert_eq "is-merged: squash-then-base-diverged -> fail closed" "1" "$?"

d="$WORK/im_unmerged"; new_repo "$d"
printf 'l1\n' > "$d/f.txt"; commit_all "$d" "base"
( cd "$d" && git checkout -q -b feat ) >/dev/null 2>&1
printf 'l1\nunique-change\n' > "$d/f.txt"; commit_all "$d" "feat c1"
feat_tip=$(rev "$d" HEAD)
( cd "$d" && git checkout -q master ) >/dev/null 2>&1
base_tip=$(rev "$d" HEAD)
gs "$d" is-merged "$feat_tip" "$base_tip"; assert_eq "is-merged: unmerged -> 1" "1" "$?"

gs "$WORK/im_unmerged" is-merged "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef" "master"
assert_eq "is-merged: unresolvable ref -> fail closed (1)" "1" "$?"

d="$WORK/im_notarepo"; mkdir -p "$d"
gs "$d" is-merged HEAD HEAD; assert_eq "is-merged: not a repo -> fail closed (1)" "1" "$?"

# ============================================================================
# is-pushed
# ============================================================================

d="$WORK/ip_noorigin"; new_repo "$d"
printf 'a\n' > "$d/a.txt"; commit_all "$d" "c1"
gs "$d" is-pushed HEAD; assert_eq "is-pushed: no origin -> 1" "1" "$?"

d="$WORK/ip_work"; new_repo "$d"
printf 'a\n' > "$d/a.txt"; commit_all "$d" "c1"
origin="$WORK/ip_origin.git"
( git init -q --bare "$origin" ) >/dev/null 2>&1
( cd "$d" && git remote add origin "$origin" && git push -q origin master && git remote set-head origin master ) >/dev/null 2>&1
gs "$d" is-pushed HEAD; assert_eq "is-pushed: origin/HEAD contains ref" "0" "$?"

printf 'b\n' > "$d/b.txt"; commit_all "$d" "c2 unpushed"
gs "$d" is-pushed HEAD; assert_eq "is-pushed: local commit ahead of origin -> 1" "1" "$?"

d="$WORK/ip_upstream"; new_repo "$d"
printf 'a\n' > "$d/a.txt"; commit_all "$d" "c1"
origin2="$WORK/ip_origin2.git"
( git init -q --bare "$origin2" ) >/dev/null 2>&1
( cd "$d" && git remote add origin "$origin2" && git push -q origin master:unrelated-branch ) >/dev/null 2>&1
( cd "$d" && git checkout -q -b feat ) >/dev/null 2>&1
printf 'b\n' > "$d/b.txt"; commit_all "$d" "feat c1"
( cd "$d" && git push -q origin feat:tracked-elsewhere && git branch -q --set-upstream-to=origin/tracked-elsewhere feat ) >/dev/null 2>&1
( cd "$d" && git remote set-head origin unrelated-branch ) >/dev/null 2>&1
gs "$d" is-pushed HEAD; assert_eq "is-pushed: origin/HEAD does not contain -> falls to upstream, contains -> 0" "0" "$?"

# ============================================================================
# safe-delete-branch
# ============================================================================

d="$WORK/sdb"; new_repo "$d"
printf 'a\n' > "$d/a.txt"; commit_all "$d" "c1"
base=$(rev "$d" HEAD)
( cd "$d" && git checkout -q -b merged-branch ) >/dev/null 2>&1
printf 'b\n' > "$d/b.txt"; commit_all "$d" "merged c1"
( cd "$d" && git checkout -q master && git merge -q merged-branch ) >/dev/null 2>&1
gs "$d" safe-delete-branch merged-branch master
assert_eq "safe-delete-branch: merged -> deleted (rc0)" "0" "$?"
( cd "$d" && git show-ref --verify --quiet refs/heads/merged-branch )
assert_eq "safe-delete-branch: merged branch ref gone" "1" "$?"

( cd "$d" && git checkout -q -b unmerged-branch ) >/dev/null 2>&1
printf 'c\n' > "$d/c.txt"; commit_all "$d" "unmerged c1"
( cd "$d" && git checkout -q master ) >/dev/null 2>&1
gs "$d" safe-delete-branch unmerged-branch master
assert_eq "safe-delete-branch: unmerged -> refused (rc1)" "1" "$?"
( cd "$d" && git show-ref --verify --quiet refs/heads/unmerged-branch )
assert_eq "safe-delete-branch: unmerged branch ref kept" "0" "$?"

# H2: a tag named like the branch, pointing at a merged commit, must not
# make an unmerged same-named branch look merged.
d="$WORK/sdb_tagcollision"; new_repo "$d"
printf 'a\n' > "$d/a.txt"; commit_all "$d" "c1"
( cd "$d" && git tag x ) >/dev/null 2>&1
( cd "$d" && git checkout -q -b x ) >/dev/null 2>&1
printf 'b\n' > "$d/b.txt"; commit_all "$d" "unmerged c1 on branch x"
unmerged_commit=$(rev "$d" HEAD)
( cd "$d" && git checkout -q master ) >/dev/null 2>&1
gs "$d" safe-delete-branch x master
assert_eq "safe-delete-branch (H2): tag/branch name collision -> refused (rc1)" "1" "$?"
( cd "$d" && git show-ref --verify --quiet refs/heads/x )
assert_eq "safe-delete-branch (H2): branch x survives the tag collision" "0" "$?"
assert_eq "safe-delete-branch (H2): unmerged commit still reachable from branch x" "$unmerged_commit" "$(rev "$d" refs/heads/x)"

# ============================================================================
# safe-reset --stage
# ============================================================================

setup_stage_fixture() {
  local d="$1"
  new_repo "$d"
  printf 'keep\n' > "$d/keep2.txt"
  printf 'outside\n' > "$d/outside.txt"
  printf 'todelete\n' > "$d/todelete.txt"
  commit_all "$d" "base"
  ( cd "$d" && git checkout -q -b feat ) >/dev/null 2>&1
  printf 'keep-changed\n' > "$d/keep2.txt"
  printf 'added\n' > "$d/added.txt"
  rm -f "$d/todelete.txt"
  commit_all "$d" "feat changes"
  ( cd "$d" && git checkout -q master ) >/dev/null 2>&1
}

d="$WORK/stage_ok"; setup_stage_fixture "$d"
base_sha=$(rev "$d" HEAD)
( cd "$d" && git merge --squash feat -q ) >/dev/null 2>&1
staged_tree=$( cd "$d" && git write-tree )
printf 'noise\n' > "$d/untracked-notes.txt"
printf 'dirty\n' > "$d/outside.txt"
gs "$d" safe-reset --stage "$base_sha" "$staged_tree"
assert_eq "safe-reset --stage: success rc0" "0" "$?"
assert_eq "safe-reset --stage: HEAD unchanged" "$base_sha" "$(rev "$d" HEAD)"
assert_eq "safe-reset --stage: modified path restored" "keep" "$(cat "$d/keep2.txt" 2>/dev/null)"
[ -e "$d/added.txt" ] && fail "safe-reset --stage: added path removed" "still present" || pass "safe-reset --stage: added path removed"
assert_eq "safe-reset --stage: deleted path restored" "todelete" "$(cat "$d/todelete.txt" 2>/dev/null)"
assert_eq "safe-reset --stage: untracked outside file survives" "noise" "$(cat "$d/untracked-notes.txt" 2>/dev/null)"
assert_eq "safe-reset --stage: dirty tracked file outside set survives" "dirty" "$(cat "$d/outside.txt" 2>/dev/null)"

d="$WORK/stage_headmismatch"; setup_stage_fixture "$d"
base_sha=$(rev "$d" HEAD)
( cd "$d" && git merge --squash feat -q ) >/dev/null 2>&1
staged_tree=$( cd "$d" && git write-tree )
( cd "$d" && git reset -q --hard ) >/dev/null 2>&1
printf 'unrelated\n' >> "$d/outside.txt"; commit_all "$d" "moved HEAD"
gs "$d" safe-reset --stage "$base_sha" "$staged_tree"
assert_eq "safe-reset --stage: HEAD mismatch -> refused (rc1)" "1" "$?"

d="$WORK/stage_editedset"; setup_stage_fixture "$d"
base_sha=$(rev "$d" HEAD)
( cd "$d" && git merge --squash feat -q ) >/dev/null 2>&1
staged_tree=$( cd "$d" && git write-tree )
printf 'further-edit\n' >> "$d/keep2.txt"
pre_call_write_tree=$( cd "$d" && git write-tree )
pre_call_diff_cached=$( cd "$d" && git diff --cached )
gs "$d" safe-reset --stage "$base_sha" "$staged_tree"
assert_eq "safe-reset --stage: edited set path -> refused (rc1)" "1" "$?"
assert_eq "safe-reset --stage: refused -> HEAD still unchanged" "$base_sha" "$(rev "$d" HEAD)"
post_call_write_tree=$( cd "$d" && git write-tree )
post_call_diff_cached=$( cd "$d" && git diff --cached )
assert_eq "safe-reset --stage: refused -> index (write-tree) unchanged (H1)" "$pre_call_write_tree" "$post_call_write_tree"
assert_eq "safe-reset --stage: refused -> staged diff unchanged (H1)" "$pre_call_diff_cached" "$post_call_diff_cached"

# H1 (isolated): a changed set with NO deleted path, so a buggy
# `update-index --refresh -- <paths>` cannot abort on a missing file and
# silently stages the further edit instead.
d="$WORK/stage_editedset_modonly"; new_repo "$d"
printf 'keep\n' > "$d/keep2.txt"; commit_all "$d" "base"
( cd "$d" && git checkout -q -b feat ) >/dev/null 2>&1
printf 'keep-changed\n' > "$d/keep2.txt"; commit_all "$d" "feat changes"
( cd "$d" && git checkout -q master ) >/dev/null 2>&1
base_sha=$(rev "$d" HEAD)
( cd "$d" && git merge --squash feat -q ) >/dev/null 2>&1
staged_tree=$( cd "$d" && git write-tree )
printf 'keep-changed\nfurther-edit\n' > "$d/keep2.txt"
pre_call_write_tree=$( cd "$d" && git write-tree )
pre_call_diff_cached=$( cd "$d" && git diff --cached )
gs "$d" safe-reset --stage "$base_sha" "$staged_tree"
assert_eq "safe-reset --stage (H1, modify-only set): edited set path -> refused (rc1)" "1" "$?"
post_call_write_tree=$( cd "$d" && git write-tree )
post_call_diff_cached=$( cd "$d" && git diff --cached )
assert_eq "safe-reset --stage (H1, modify-only set): index (write-tree) unchanged" "$pre_call_write_tree" "$post_call_write_tree"
assert_eq "safe-reset --stage (H1, modify-only set): staged diff unchanged" "$pre_call_diff_cached" "$post_call_diff_cached"

d="$WORK/stage_untracked_at_deleted"; setup_stage_fixture "$d"
base_sha=$(rev "$d" HEAD)
( cd "$d" && git merge --squash feat -q ) >/dev/null 2>&1
staged_tree=$( cd "$d" && git write-tree )
printf 'unrelated-untracked-content\n' > "$d/todelete.txt"
gs "$d" safe-reset --stage "$base_sha" "$staged_tree"
assert_eq "safe-reset --stage: untracked file at squash-deleted path -> refused (rc1)" "1" "$?"
assert_eq "safe-reset --stage: untracked file at deleted path is not overwritten" "unrelated-untracked-content" "$(cat "$d/todelete.txt" 2>/dev/null)"

# D3: safe-reset --stage on an empty changed set (base_sha == staged_tree)
# must still remove SQUASH_MSG (M17 item 7 applies to both forms).
d="$WORK/stage_empty_set"; new_repo "$d"
printf 'a\n' > "$d/a.txt"; commit_all "$d" "base"
base_sha=$(rev "$d" HEAD)
same_tree=$( cd "$d" && git write-tree )
squash_msg_path="$d/$(cd "$d" && git rev-parse --git-path SQUASH_MSG)"
printf 'leftover squash msg\n' > "$squash_msg_path"
gs "$d" safe-reset --stage "$base_sha" "$same_tree"
assert_eq "safe-reset --stage (D3): empty changed set -> rc0" "0" "$?"
[ -f "$squash_msg_path" ] && fail "safe-reset --stage (D3): SQUASH_MSG removed on empty set" "still present" || pass "safe-reset --stage (D3): SQUASH_MSG removed on empty set"

# ============================================================================
# safe-reset --clean-at
# ============================================================================

d="$WORK/cleanat_conflict"; new_repo "$d"
printf 'l1\n' > "$d/f.txt"
printf 'orig\n' > "$d/user-notes.txt"
commit_all "$d" "base"
sha_before=$(rev "$d" HEAD)
( cd "$d" && git checkout -q -b feat ) >/dev/null 2>&1
printf 'l1-feat\n' > "$d/f.txt"; commit_all "$d" "feat conflicting"
( cd "$d" && git checkout -q master ) >/dev/null 2>&1
printf 'l1-master\n' > "$d/f.txt"; commit_all "$d" "master conflicting"
sha_before2=$(rev "$d" HEAD)
( cd "$d" && git merge --squash feat ) >/dev/null 2>&1
squash_rc=$?
[ "$squash_rc" -ne 0 ] && pass "cleanat: squash produced a real conflict" || fail "cleanat: squash produced a real conflict" "rc=$squash_rc"
gs "$d" safe-reset --clean-at "$sha_before2"
assert_eq "safe-reset --clean-at: rc0 after conflict" "0" "$?"
assert_eq "safe-reset --clean-at: HEAD unchanged" "$sha_before2" "$(rev "$d" HEAD)"
assert_eq "safe-reset --clean-at: untracked file survives" "orig" "$(cat "$d/user-notes.txt" 2>/dev/null)"
gs "$d" is-clean --tracked-only; assert_eq "safe-reset --clean-at: index/worktree clean after reset" "0" "$?"

d="$WORK/cleanat_mismatch"; new_repo "$d"
printf 'l1\n' > "$d/f.txt"; commit_all "$d" "base"
sha_before=$(rev "$d" HEAD)
printf 'l1\nl2\n' > "$d/f.txt"; commit_all "$d" "moved on"
pre_call_sha=$(rev "$d" HEAD)
gs "$d" safe-reset --clean-at "$sha_before"
assert_eq "safe-reset --clean-at: HEAD mismatch -> refused (rc1)" "1" "$?"
assert_eq "safe-reset --clean-at: refused -> HEAD unchanged" "$pre_call_sha" "$(rev "$d" HEAD)"
[ -f "$d/f.txt" ] && [ "$(cat "$d/f.txt")" = "l1
l2" ] && pass "safe-reset --clean-at: refused -> content unchanged" || fail "safe-reset --clean-at: refused -> content unchanged" "changed"

# ============================================================================
# premise (security council finding, Step 6c): `git merge --squash` refuses
# to overwrite an untracked, non-ignored file at a path the incoming branch
# adds. The end-state H/I untracked-safety design (T6) rests on this.
# ============================================================================

d="$WORK/squash_untracked_premise"; new_repo "$d"
printf 'base\n' > "$d/base.txt"; commit_all "$d" "base"
sha_before=$(rev "$d" HEAD)
( cd "$d" && git checkout -q -b feat ) >/dev/null 2>&1
printf 'added-by-branch\n' > "$d/newpath.txt"; commit_all "$d" "feat adds newpath.txt"
( cd "$d" && git checkout -q master ) >/dev/null 2>&1
printf 'unrelated-untracked-bytes\n' > "$d/newpath.txt"
( cd "$d" && git merge --squash feat ) >/dev/null 2>&1
squash_rc=$?
[ "$squash_rc" -ne 0 ] && pass "premise: squash refuses to overwrite untracked file at added path" || fail "premise: squash refuses to overwrite untracked file at added path" "rc=$squash_rc"
assert_eq "premise: untracked file bytes unchanged after refused squash" "unrelated-untracked-bytes" "$(cat "$d/newpath.txt" 2>/dev/null)"
assert_eq "premise: HEAD unchanged after refused squash" "$sha_before" "$(rev "$d" HEAD)"
gs "$d" is-clean --tracked-only
assert_eq "premise: tracked tree still clean after refused squash (no partial index change)" "0" "$?"
# ============================================================================
# static: no `git clean` anywhere in the library
# ============================================================================

grep_count=$(grep -c 'git clean' "$LIB" || true)
assert_eq "static: no 'git clean' in git-safety.sh" "0" "$grep_count"

FIXTURE_GITCLEAN="$WORK/planted-gitclean.sh"
printf '# a fixture line calling git clean -fd\n' > "$FIXTURE_GITCLEAN"
neg_count=$(grep -c 'git clean' "$FIXTURE_GITCLEAN" || true)
assert_eq "static negative control: planted 'git clean' detected" "1" "$neg_count"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
