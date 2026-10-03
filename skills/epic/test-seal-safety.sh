#!/usr/bin/env bash
# skills/epic/test-seal-safety.sh — WP 1-05 T3: seal safety bite suite.
# Covers SPEC-025 wp-1-05-git-safety-lib ACs C, D, E, F, G (seal squash-stage
# gate, seal_stage recording, squash/hook-fail recovery, abort/force, and the
# doc/handoff static checks that stop recommending --abort --force as the
# routine recovery path).
#
# Written RED against df697cb epic-lib.sh: no skills/lib/git-safety.sh yet,
# no seal_stage field, and _seal_reset_main runs `reset --hard` + `clean -fd`
# unconditionally (T5 implements C2 against this suite).
set -u
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
LIB="$ROOT/skills/epic/epic-lib.sh"
SKILL_MD="$ROOT/skills/epic/mode-b-execute.md"   # WP 7-04: B.7 seal text lives in the mode file

# shellcheck source=../../tests/lib/hermetic.sh
. "$ROOT/tests/lib/hermetic.sh"
hermetic_init
export GIT_CONFIG_GLOBAL=/dev/null
export GIT_CONFIG_NOSYSTEM=1
unset GIT_DIR GIT_INDEX_FILE GIT_WORK_TREE

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); }
fail() { FAIL=$((FAIL + 1)); echo "FAIL: $*"; }

# seal_run <repo> <args...> -> sets OUT, RC (never let a failure kill the suite)
# L6: no set -e/set +e here — this suite is set -u only; toggling errexit in a
# plain function call (not a subshell) leaks the change to the rest of the
# script once the function returns.
seal_run() {
  local repo="$1"; shift
  OUT=$(cd "$repo" && EPIC_ROOT="$repo" bash "$LIB" "$@" 2>&1)
  RC=$?
}

# hook_seal_run <repo> <epic> <hook-src> -- run `seal <id>` with EPIC_SEAL_RELEASE_HOOK set
# (WP 1-09: the hook runs only with EPIC_TEST_MODE=1).
hook_seal_run() {
  local repo="$1" epic="$2" hook="$3"
  OUT=$(cd "$repo" && EPIC_ROOT="$repo" EPIC_TEST_MODE=1 EPIC_SEAL_RELEASE_HOOK="$hook" \
    bash "$LIB" seal "$epic" 2>&1)
  RC=$?
}

# mk_repo -> a bare git repo with a committed README.md on refs/heads/master.
# Sets: REPO
mk_repo() {
  REPO=$(mktemp -d "${TMPDIR:-/tmp}/seal-safety-repo.XXXXXX")
  git init -q "$REPO" || { fail "mk_repo git init"; return 1; }
  git -C "$REPO" symbolic-ref HEAD refs/heads/master
  printf 'line1\n' >"$REPO/README.md"
  git -C "$REPO" add README.md
  git -C "$REPO" commit -q -m init
}

# mk_ready_epic -> a fresh repo with a seal-ready epic (worktree-enabled,
# release_bump=minor, one completed child, one committed payload file on the
# integration branch). Sets: REPO EPIC_ID INT_PATH INT_BRANCH MASTER_SHA0
mk_ready_epic() {
  mk_repo || return 1
  EPIC_ID="EPIC-$$-$RANDOM"
  seal_run "$REPO" init "$EPIC_ID" --title t --mode orchestrate \
    --worktree-enabled true --release-bump minor
  [ "$RC" -eq 0 ] || { fail "mk_ready_epic init rc=$RC out=$OUT"; return 1; }
  seal_run "$REPO" ensure-integration-worktree "$EPIC_ID"
  [ "$RC" -eq 0 ] || { fail "mk_ready_epic ensure-integration-worktree rc=$RC out=$OUT"; return 1; }
  INT_BRANCH=$(jq -r .integration_branch "$REPO/.claude/epics/$EPIC_ID/state.json")
  INT_PATH=$(jq -r .integration_path "$REPO/.claude/epics/$EPIC_ID/state.json")
  seal_run "$REPO" add-child "$EPIC_ID" --id "${EPIC_ID}-C1" --slug s1 --title t1 \
    --estimate S --agent ic4 --depends-on '[]' --problem p --ac '["a"]'
  [ "$RC" -eq 0 ] || { fail "mk_ready_epic add-child rc=$RC out=$OUT"; return 1; }
  seal_run "$REPO" set-status "$EPIC_ID" "${EPIC_ID}-C1" completed
  [ "$RC" -eq 0 ] || { fail "mk_ready_epic set-status rc=$RC out=$OUT"; return 1; }
  printf 'payload\n' >"$INT_PATH/payload.txt"
  git -C "$INT_PATH" add payload.txt
  git -C "$INT_PATH" commit -q -m "feat: payload"
  MASTER_SHA0=$(git -C "$REPO" rev-parse HEAD)
}

# ============================================================================
# AC C: squash-stage refuses on a dirty main (untracked / tracked / non-default
# branch), excludes are .claude/epics/, .worktrees/, .wt-lock.
# ============================================================================
{
  mk_ready_epic || true
  if [ -n "${REPO:-}" ]; then
    # c-1: untracked non-ignored file -> seal must refuse; file + HEAD survive.
    printf 'notes\n' >"$REPO/user-notes.txt"
    UN_SHA=$(git -C "$REPO" hash-object "$REPO/user-notes.txt")
    seal_run "$REPO" seal "$EPIC_ID"
    [ "$RC" -ne 0 ] && pass || fail "C-1 untracked file: seal must refuse (rc=$RC out=$OUT)"
    [ -f "$REPO/user-notes.txt" ] && pass || fail "C-1 untracked file removed"
    [ "$(git -C "$REPO" hash-object "$REPO/user-notes.txt" 2>/dev/null)" = "$UN_SHA" ] \
      && pass || fail "C-1 untracked file content changed"
    [ "$(git -C "$REPO" rev-parse HEAD)" = "$MASTER_SHA0" ] \
      && pass || fail "C-1 HEAD moved"
    rm -f "$REPO/user-notes.txt"

    # c-2: dirty tracked file -> seal must refuse; file + HEAD survive.
    printf 'line1\ndirty\n' >"$REPO/README.md"
    seal_run "$REPO" seal "$EPIC_ID"
    [ "$RC" -ne 0 ] && pass || fail "C-2 dirty tracked file: seal must refuse (rc=$RC out=$OUT)"
    grep -q '^dirty$' "$REPO/README.md" && pass || fail "C-2 dirty tracked file content changed"
    [ "$(git -C "$REPO" rev-parse HEAD)" = "$MASTER_SHA0" ] \
      && pass || fail "C-2 HEAD moved"
    git -C "$REPO" checkout -q -- README.md

    # c-3: start on a non-default branch, with an untracked and a dirty
    # tracked file -> seal must refuse (assert only survival + rc).
    git -C "$REPO" checkout -q -b other
    printf 'notes\n' >"$REPO/user-notes.txt"
    printf 'line1\ndirty2\n' >"$REPO/README.md"
    seal_run "$REPO" seal "$EPIC_ID"
    [ "$RC" -ne 0 ] && pass || fail "C-3 non-default branch: seal must refuse (rc=$RC out=$OUT)"
    [ -f "$REPO/user-notes.txt" ] && pass || fail "C-3 untracked file removed"
    grep -q '^dirty2$' "$REPO/README.md" && pass || fail "C-3 dirty tracked file content changed"
    rm -rf "$REPO"
  fi
}

# ============================================================================
# AC D: successful squash-stage records seal_stage {base_sha, staged_tree,
# added_paths[]}; the field is additive (older/other reads still work).
# ============================================================================
{
  mk_ready_epic || true
  if [ -n "${REPO:-}" ]; then
    PRE_SHA="$MASTER_SHA0"
    seal_run "$REPO" seal "$EPIC_ID"
    [ "$RC" -eq 0 ] && pass || fail "D-1 handoff seal rc=$RC out=$OUT"
    WT_SHA=$(git -C "$REPO" write-tree 2>/dev/null || true)
    ST="$REPO/.claude/epics/$EPIC_ID/state.json"
    jq -e --arg s "$PRE_SHA" '.seal_stage.base_sha == $s' "$ST" >/dev/null 2>&1 \
      && pass || fail "D-1 seal_stage.base_sha wrong or missing"
    jq -e --arg t "$WT_SHA" '.seal_stage.staged_tree == $t' "$ST" >/dev/null 2>&1 \
      && pass || fail "D-1 seal_stage.staged_tree wrong or missing"
    jq -e '.seal_stage.added_paths | index("payload.txt") != null' "$ST" >/dev/null 2>&1 \
      && pass || fail "D-1 seal_stage.added_paths missing payload.txt"
    rm -rf "$REPO"
  fi

  # D-2: a state file that never went through seal_stage still reads fine.
  mk_ready_epic || true
  if [ -n "${REPO:-}" ]; then
    seal_run "$REPO" show "$EPIC_ID"
    [ "$RC" -eq 0 ] && pass || fail "D-2 show without seal_stage rc=$RC"
    seal_run "$REPO" seal-ready "$EPIC_ID"
    [ "$RC" -eq 0 ] && pass || fail "D-2 seal-ready without seal_stage rc=$RC"
    seal_run "$REPO" seal "$EPIC_ID" --dry-run
    [ "$RC" -eq 0 ] && pass || fail "D-2 seal --dry-run without seal_stage rc=$RC"
    rm -rf "$REPO"
  fi
}

# ============================================================================
# AC E: squash conflict and hook failure reset only the squash set; no
# `git clean`; an untracked/ignored main file survives recovery.
# ============================================================================
{
  # E-1: squash conflict (main and integration both edit README.md) with an
  # ignored file present; recovery must not run `git clean`, must remove
  # SQUASH_MSG, and the ignored file must survive. L5: `git clean -fd`
  # (the pre-fix code) never touches gitignored paths, so the ignored-file
  # assertion alone does not bite on df697cb — also assert survival of the
  # untracked, *non*-ignored, seal-excluded epic state.json, which old
  # `clean -fd` would delete.
  mk_ready_epic || true
  if [ -n "${REPO:-}" ]; then
    printf 'int-edit\n' >"$INT_PATH/README.md"
    git -C "$INT_PATH" add README.md
    git -C "$INT_PATH" commit -q -m "feat: integration edit"

    printf 'master-edit\n' >"$REPO/README.md"
    git -C "$REPO" add README.md
    git -C "$REPO" commit -q -m "feat: master edit"

    printf 'scratch/\n' >"$REPO/.gitignore"
    git -C "$REPO" add .gitignore
    git -C "$REPO" commit -q -m "chore: ignore scratch/"
    PRE_CONFLICT_SHA=$(git -C "$REPO" rev-parse HEAD)
    mkdir -p "$REPO/scratch"
    printf 'ignored\n' >"$REPO/scratch/x"
    SCRATCH_SHA=$(git -C "$REPO" hash-object "$REPO/scratch/x")
    STATE_PATH="$REPO/.claude/epics/$EPIC_ID/state.json"
    STATE_SHA=$(git -C "$REPO" hash-object "$STATE_PATH")

    seal_run "$REPO" seal "$EPIC_ID"
    [ "$RC" -ne 0 ] && pass || fail "E-1 squash conflict must refuse (rc=$RC out=$OUT)"
    [ "$(git -C "$REPO" rev-parse HEAD)" = "$PRE_CONFLICT_SHA" ] \
      && pass || fail "E-1 HEAD moved on conflict"
    git -C "$REPO" diff --quiet && git -C "$REPO" diff --cached --quiet \
      && pass || fail "E-1 tracked tree dirty after conflict recovery"
    [ ! -f "$REPO/.git/SQUASH_MSG" ] && pass || fail "E-1 SQUASH_MSG left behind"
    [ -f "$REPO/scratch/x" ] && pass || fail "E-1 ignored file removed"
    [ "$(git -C "$REPO" hash-object "$REPO/scratch/x" 2>/dev/null)" = "$SCRATCH_SHA" ] \
      && pass || fail "E-1 ignored file content changed"
    [ -f "$STATE_PATH" ] && pass || fail "E-1 untracked non-ignored epic state.json removed by recovery"
    [ "$(git -C "$REPO" hash-object "$STATE_PATH" 2>/dev/null)" = "$STATE_SHA" ] \
      && pass || fail "E-1 epic state.json content changed"
    rm -rf "$REPO"
  fi

  # E-2: hook creates an untracked user file then fails; recovery must not
  # wipe it (no `git clean`).
  mk_ready_epic || true
  if [ -n "${REPO:-}" ]; then
    PRE_HOOK_SHA=$(git -C "$REPO" rev-parse HEAD)
    hook_seal_run "$REPO" "$EPIC_ID" 'printf "hooked\n" >user-notes.txt; exit 1'
    [ "$RC" -ne 0 ] && pass || fail "E-2 hook fail must propagate (rc=$RC out=$OUT)"
    [ "$(git -C "$REPO" rev-parse HEAD)" = "$PRE_HOOK_SHA" ] \
      && pass || fail "E-2 HEAD moved on hook fail"
    git -C "$REPO" diff --quiet && git -C "$REPO" diff --cached --quiet \
      && pass || fail "E-2 tracked tree dirty after hook-fail recovery"
    [ -f "$REPO/user-notes.txt" ] && pass || fail "E-2 hook's untracked file wiped"
    jq -e '(.sealed // false) == false' "$REPO/.claude/epics/$EPIC_ID/state.json" >/dev/null 2>&1 \
      && pass || fail "E-2 sealed must stay false after hook fail"
    jq -e '.seal_stage == null' "$REPO/.claude/epics/$EPIC_ID/state.json" >/dev/null 2>&1 \
      && pass || fail "E-2 seal_stage stale after hook-fail recovery"
    rm -rf "$REPO"
  fi

  # E-3: static — no code path runs `git clean`.
  N=$(grep -c 'git clean\|clean -fd' "$LIB" || true)
  [ "$N" -eq 0 ] && pass || fail "E-3 grep 'git clean|clean -fd' epic-lib.sh = $N (want 0)"
}

# ============================================================================
# AC F: seal --abort. Bare abort resets only the seal-owned stage (clean tree,
# or write-tree == seal_stage.staged_tree with no other dirt outside
# excludes); everything else refuses. --force stashes (never wipes silently).
# ============================================================================
{
  # F-1: staged seal only -> bare abort exit 0, tracked tree clean, seal_stage null.
  mk_ready_epic || true
  if [ -n "${REPO:-}" ]; then
    seal_run "$REPO" seal "$EPIC_ID"
    [ "$RC" -eq 0 ] || fail "F-1 setup: handoff seal rc=$RC out=$OUT"
    seal_run "$REPO" seal "$EPIC_ID" --abort
    [ "$RC" -eq 0 ] && pass || fail "F-1 staged-only bare abort rc=$RC out=$OUT"
    git -C "$REPO" diff --quiet && git -C "$REPO" diff --cached --quiet \
      && pass || fail "F-1 tracked tree dirty after bare abort"
    jq -e '.seal_stage == null' "$REPO/.claude/epics/$EPIC_ID/state.json" >/dev/null 2>&1 \
      && pass || fail "F-1 seal_stage not nulled"
    rm -rf "$REPO"
  fi

  # F-2: staged seal + untracked file -> bare abort refuses; tree byte-identical.
  mk_ready_epic || true
  if [ -n "${REPO:-}" ]; then
    seal_run "$REPO" seal "$EPIC_ID"
    [ "$RC" -eq 0 ] || fail "F-2 setup: handoff seal rc=$RC out=$OUT"
    printf 'wip\n' >"$REPO/user-notes.txt"
    STATUS_BEFORE=$(git -C "$REPO" status --porcelain)
    TREE_BEFORE=$(git -C "$REPO" write-tree)
    seal_run "$REPO" seal "$EPIC_ID" --abort
    [ "$RC" -eq 1 ] && pass || fail "F-2 dirty bare abort rc=$RC (want 1) out=$OUT"
    printf '%s\n' "$OUT" | grep -qi dirty && printf '%s\n' "$OUT" | grep -qi refuse \
      && pass || fail "F-2 stderr missing dirty+refuse (out=$OUT)"
    [ "$(git -C "$REPO" status --porcelain)" = "$STATUS_BEFORE" ] \
      && pass || fail "F-2 porcelain changed across refused abort"
    [ "$(git -C "$REPO" write-tree)" = "$TREE_BEFORE" ] \
      && pass || fail "F-2 tree changed across refused abort"
    rm -rf "$REPO"
  fi

  # F-3: staged seal + unstaged tracked edit -> same refuse.
  mk_ready_epic || true
  if [ -n "${REPO:-}" ]; then
    seal_run "$REPO" seal "$EPIC_ID"
    [ "$RC" -eq 0 ] || fail "F-3 setup: handoff seal rc=$RC out=$OUT"
    printf 'line1\nmore\n' >>"$REPO/README.md"
    seal_run "$REPO" seal "$EPIC_ID" --abort
    [ "$RC" -eq 1 ] && pass || fail "F-3 unstaged-edit bare abort rc=$RC (want 1) out=$OUT"
    printf '%s\n' "$OUT" | grep -qi dirty && printf '%s\n' "$OUT" | grep -qi refuse \
      && pass || fail "F-3 stderr missing dirty+refuse (out=$OUT)"
    rm -rf "$REPO"
  fi

  # F-4: --abort --force with a dirty tracked edit + untracked file -> exit 0,
  # named stash holds the edit, untracked file survives.
  mk_ready_epic || true
  if [ -n "${REPO:-}" ]; then
    printf 'line1\nforce-edit\n' >"$REPO/README.md"
    printf 'wip\n' >"$REPO/user-notes.txt"
    seal_run "$REPO" seal "$EPIC_ID" --abort --force
    [ "$RC" -eq 0 ] && pass || fail "F-4 abort --force rc=$RC out=$OUT"
    git -C "$REPO" stash list | grep -q "epic-seal-${EPIC_ID}-" \
      && pass || fail "F-4 named stash missing (stash list: $(git -C "$REPO" stash list))"
    STASH_REF=$(git -C "$REPO" stash list | grep "epic-seal-${EPIC_ID}-" | head -1 | cut -d: -f1)
    if [ -n "$STASH_REF" ]; then
      git -C "$REPO" stash show -p "$STASH_REF" | grep -q 'force-edit' \
        && pass || fail "F-4 stash does not hold the tracked edit"
    else
      fail "F-4 no stash ref to inspect"
    fi
    [ -f "$REPO/user-notes.txt" ] && pass || fail "F-4 untracked file wiped by force"
    rm -rf "$REPO"
  fi

  # F-4b (M2): untracked-only dirt + --abort --force -> `git stash push`
  # creates no stash (nothing tracked to save) and must not claim a false
  # stash@{0}; the untracked file still survives; rc=0.
  mk_ready_epic || true
  if [ -n "${REPO:-}" ]; then
    printf 'wip\n' >"$REPO/user-notes.txt"
    STASH_BEFORE=$(git -C "$REPO" stash list | wc -l | tr -d ' ')
    F4B_ERR=$(mktemp "${TMPDIR:-/tmp}/seal-safety-f4b-err.XXXXXX")
    OUT=$(cd "$REPO" && EPIC_ROOT="$REPO" bash "$LIB" seal "$EPIC_ID" --abort --force 2>"$F4B_ERR")
    RC=$?
    ERR=$(cat "$F4B_ERR"); rm -f "$F4B_ERR"
    [ "$RC" -eq 0 ] && pass || fail "F-4b untracked-only abort --force rc=$RC out=$OUT err=$ERR"
    STASH_AFTER=$(git -C "$REPO" stash list | wc -l | tr -d ' ')
    [ "$STASH_AFTER" -eq "$STASH_BEFORE" ] \
      && pass || fail "F-4b created a stash with nothing tracked to save (before=$STASH_BEFORE after=$STASH_AFTER)"
    printf '%s' "$ERR" | grep -qi 'no tracked edits to stash' \
      && pass || fail "F-4b stderr falsely claims a stash (err=$ERR)"
    printf '%s' "$ERR" | grep -q 'stash@{0}' \
      && fail "F-4b stderr names stash@{0} (can belong to another session)" || pass
    [ -f "$REPO/user-notes.txt" ] && pass || fail "F-4b untracked file wiped by force"
    rm -rf "$REPO"
  fi

  # F-5: --force alone (no --abort) -> usage 64.
  mk_ready_epic || true
  if [ -n "${REPO:-}" ]; then
    seal_run "$REPO" seal "$EPIC_ID" --force
    [ "$RC" -eq 64 ] && pass || fail "F-5 bare --force rc=$RC (want 64) out=$OUT"
    rm -rf "$REPO"
  fi
}

# ============================================================================
# AC G: static — docs/handoff stop recommending --abort --force as routine;
# every --force mention sits with "stash then reset".
# ============================================================================
{
  # G-1: handoff on_failure is bare --abort (negative control: today it is
  # "... --abort --force").
  mk_ready_epic || true
  if [ -n "${REPO:-}" ]; then
    seal_run "$REPO" seal "$EPIC_ID"
    [ "$RC" -eq 0 ] || fail "G-1 setup: handoff seal rc=$RC out=$OUT"
    ON_FAILURE=$(printf '%s\n' "$OUT" | jq -r '.on_failure // empty')
    printf '%s' "$ON_FAILURE" | grep -q -- '--force' \
      && fail "G-1 on_failure still names --force ($ON_FAILURE)" || pass
    printf '%s' "$ON_FAILURE" | grep -q -- '--abort' \
      && pass || fail "G-1 on_failure missing bare --abort ($ON_FAILURE)"
    rm -rf "$REPO"
  fi

  # G-2: SKILL.md B.7 recovery step and the "Seal failure" edge-case row do
  # not name --abort --force as the routine step (negative control: today
  # both do — see the two greps below).
  if grep -q -- '--abort --force' "$SKILL_MD"; then
    B7_BLOCK=$(awk '/^\*\*B\.7/,/^\*\*(B\.8|C\.)/' "$SKILL_MD")
    printf '%s' "$B7_BLOCK" | grep -q -- 'seal --abort --force' \
      && fail "G-2 B.7 recovery step still names --abort --force as routine" || pass
    ROW=$(grep -n '^| Seal failure' "$SKILL_MD" || true)
    printf '%s' "$ROW" | grep -q -- '--abort --force' \
      && fail "G-2 'Seal failure' edge-case row still names --abort --force as routine" || pass
  else
    fail "G-2 negative control absent: SKILL.md no longer contains '--abort --force' at all — grep below is meaningless"
  fi

  # G-3: every --force mention in SKILL.md / epic-lib.sh sits with "stash
  # then reset" (negative control: today none do).
  BAD=0
  while IFS= read -r n; do
    [ -n "$n" ] || continue
    CTX=$(sed -n "$((n > 2 ? n - 2 : 1)),$((n + 2))p" "$SKILL_MD")
    printf '%s' "$CTX" | grep -qi 'stash then reset' || BAD=$((BAD + 1))
  done < <(grep -n -- '--force' "$SKILL_MD" | cut -d: -f1)
  while IFS= read -r n; do
    [ -n "$n" ] || continue
    CTX=$(sed -n "$((n > 2 ? n - 2 : 1)),$((n + 2))p" "$LIB")
    printf '%s' "$CTX" | grep -qi 'stash then reset' || BAD=$((BAD + 1))
  done < <(grep -n -- '--force' "$LIB" | cut -d: -f1)
  [ "$BAD" -eq 0 ] && pass || fail "G-3 $BAD --force mention(s) not paired with 'stash then reset'"
}

# ============================================================================
# WP 1-09 (CDT-350): seal never switches branches. It runs the dirty gate on the
# checkout as it is, then refuses (exit 1) unless HEAD is the default branch; the
# default branch comes from git-safety resolve-base (origin/HEAD first), not a
# hard-coded branch name.
# ============================================================================
{
  # N-1: dirty tracked file + untracked file on a non-default branch -> exit 1 at
  # the dirty gate (so the message is the M14 item 13 dirty refusal),
  # stderr names dirty + refuse, HEAD branch stays `other`, files survive.
  mk_ready_epic || true
  if [ -n "${REPO:-}" ]; then
    git -C "$REPO" checkout -q -b other
    OTHER_SHA=$(git -C "$REPO" rev-parse HEAD)
    printf 'line1\ndirty-n1\n' >"$REPO/README.md"
    printf 'notes\n' >"$REPO/user-notes.txt"
    seal_run "$REPO" seal "$EPIC_ID"
    [ "$RC" -eq 1 ] && pass || fail "N-1 dirty non-default branch: rc=$RC (want 1) out=$OUT"
    printf '%s\n' "$OUT" | grep -qi dirty && printf '%s\n' "$OUT" | grep -qi refuse \
      && pass || fail "N-1 stderr missing dirty+refuse (out=$OUT)"
    [ "$(git -C "$REPO" symbolic-ref --short HEAD 2>/dev/null)" = "other" ] \
      && pass || fail "N-1 HEAD branch moved off 'other' before the dirty gate (got $(git -C "$REPO" symbolic-ref --short HEAD 2>/dev/null))"
    [ "$(git -C "$REPO" rev-parse HEAD)" = "$OTHER_SHA" ] && pass || fail "N-1 HEAD sha moved"
    grep -q '^dirty-n1$' "$REPO/README.md" && pass || fail "N-1 tracked edit lost"
    [ -f "$REPO/user-notes.txt" ] && pass || fail "N-1 untracked file lost"
    [ "$(git -C "$REPO" rev-parse refs/heads/master)" = "$MASTER_SHA0" ] \
      && pass || fail "N-1 master moved"
    rm -rf "$REPO"
  fi

  # N-2: CLEAN tree on a non-default branch -> seal refuses (exit 1), names the
  # current branch and the default branch, and changes nothing: HEAD branch and
  # SHA, the default branch, the index and seal_stage. It never checks out.
  mk_ready_epic || true
  if [ -n "${REPO:-}" ]; then
    git -C "$REPO" checkout -q -b other
    OTHER_SHA=$(git -C "$REPO" rev-parse HEAD)
    seal_run "$REPO" seal "$EPIC_ID"
    [ "$RC" -eq 1 ] && pass || fail "N-2 clean non-default branch: rc=$RC (want 1) out=$OUT"
    printf '%s\n' "$OUT" | grep -q 'HEAD is other, not master' \
      && printf '%s\n' "$OUT" | grep -q 'check out master' \
      && pass || fail "N-2 stderr must say 'HEAD is other, not master' and 'check out master' (out=$OUT)"
    [ "$(git -C "$REPO" symbolic-ref --short HEAD 2>/dev/null)" = "other" ] \
      && pass || fail "N-2 HEAD branch moved off 'other' (got $(git -C "$REPO" symbolic-ref --short HEAD 2>/dev/null))"
    [ "$(git -C "$REPO" rev-parse HEAD)" = "$OTHER_SHA" ] && pass || fail "N-2 HEAD sha moved"
    [ "$(git -C "$REPO" rev-parse refs/heads/master)" = "$MASTER_SHA0" ] && pass || fail "N-2 master moved"
    git -C "$REPO" diff --cached --quiet && pass || fail "N-2 something was staged"
    jq -e '.seal_stage == null' "$REPO/.claude/epics/$EPIC_ID/state.json" >/dev/null 2>&1 \
      && pass || fail "N-2 seal_stage recorded on a refused seal"
    rm -rf "$REPO"
  fi

  # N-2b: detached HEAD on the default commit -> refuse too, HEAD unchanged.
  mk_ready_epic || true
  if [ -n "${REPO:-}" ]; then
    git -C "$REPO" checkout -q --detach
    seal_run "$REPO" seal "$EPIC_ID"
    [ "$RC" -eq 1 ] && pass || fail "N-2b detached HEAD: rc=$RC (want 1) out=$OUT"
    printf '%s\n' "$OUT" | grep -q 'HEAD is detached, not master' \
      && pass || fail "N-2b stderr must say 'HEAD is detached, not master' (out=$OUT)"
    [ -z "$(git -C "$REPO" symbolic-ref -q HEAD 2>/dev/null)" ] && pass || fail "N-2b HEAD was re-attached"
    [ "$(git -C "$REPO" rev-parse HEAD)" = "$MASTER_SHA0" ] && pass || fail "N-2b HEAD sha moved"
    rm -rf "$REPO"
  fi

  # N-3: default branch is `trunk` (origin/HEAD -> origin/trunk; no master, no
  # main) -> seal stages on trunk. The old code died "no master/main branch".
  mk_ready_epic || true
  if [ -n "${REPO:-}" ]; then
    git -C "$REPO" branch -m master trunk
    git -C "$REPO" update-ref refs/remotes/origin/trunk "$MASTER_SHA0"
    git -C "$REPO" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/trunk
    seal_run "$REPO" seal "$EPIC_ID"
    [ "$RC" -eq 0 ] && pass || fail "N-3 default branch trunk: rc=$RC out=$OUT"
    printf '%s' "$OUT" | jq -e '.default_branch=="trunk" and .staged==true' >/dev/null 2>&1 \
      && pass || fail "N-3 handoff JSON must name default_branch trunk (out=$OUT)"
    [ "$(git -C "$REPO" symbolic-ref --short HEAD 2>/dev/null)" = "trunk" ] \
      && pass || fail "N-3 HEAD must be trunk"
    git -C "$REPO" diff --cached --name-only | grep -q '^payload.txt$' \
      && pass || fail "N-3 payload.txt not staged on trunk"
    rm -rf "$REPO"
  fi

  # N-4: origin/HEAD names a branch that has no local copy -> fail closed (exit
  # 1, names the branch), no squash, HEAD unchanged. Never falls back to a
  # different branch for the squash.
  mk_ready_epic || true
  if [ -n "${REPO:-}" ]; then
    git -C "$REPO" update-ref refs/remotes/origin/elsewhere "$MASTER_SHA0"
    git -C "$REPO" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/elsewhere
    seal_run "$REPO" seal "$EPIC_ID"
    [ "$RC" -eq 1 ] && pass || fail "N-4 no local default branch: rc=$RC (want 1) out=$OUT"
    printf '%s\n' "$OUT" | grep -q 'elsewhere' && pass || fail "N-4 stderr must name the branch (out=$OUT)"
    [ "$(git -C "$REPO" rev-parse HEAD)" = "$MASTER_SHA0" ] && pass || fail "N-4 HEAD moved"
    git -C "$REPO" diff --cached --quiet && pass || fail "N-4 squash staged on a wrong branch"
    rm -rf "$REPO"
  fi

  # N-5: static — the hard-coded branch probes are gone from epic-lib.sh
  # (negative control: the pre-fix text is planted in a temp file).
  _n5_hardcoded() { grep -q 'refs/heads/master' "$1" || grep -q 'refs/heads/main' "$1"; }
  N5_PLANT=$(mktemp "${TMPDIR:-/tmp}/seal-n5.XXXXXX")
  printf '%s\n' 'git -C "$main" show-ref --verify --quiet refs/heads/master' >"$N5_PLANT"
  if _n5_hardcoded "$N5_PLANT"; then pass; else fail "N-5 negative control: planted probe not detected"; fi
  rm -f "$N5_PLANT"
  if _n5_hardcoded "$LIB"; then fail "N-5 epic-lib.sh still probes refs/heads/master or refs/heads/main"; else pass; fi

  # N-6: static — seal has no `git ... checkout` (it refuses instead), and the
  # squash-stage dirty gate is called once (negative control: planted pre-fix text).
  _n6_checkout() { grep -v '^[[:space:]]*#' "$1" | grep -q 'git -C "\$main" checkout'; }
  N6_PLANT=$(mktemp "${TMPDIR:-/tmp}/seal-n6.XXXXXX")
  printf '%s\n' '    if ! git -C "$main" checkout -q "$default" 2>/dev/null; then' >"$N6_PLANT"
  if _n6_checkout "$N6_PLANT"; then pass; else fail "N-6 negative control: planted checkout not detected"; fi
  rm -f "$N6_PLANT"
  if _n6_checkout "$LIB"; then fail "N-6 epic-lib.sh still runs git checkout in seal"; else pass; fi
  # is-clean with the plain seal excludes: abort path (1) + squash-stage gate (1)
  N6_GATES=$(grep -c 'is-clean -- "\${SEAL_EXCLUDES\[@\]}"' "$LIB" || true)
  [ "$N6_GATES" -eq 2 ] && pass || fail "N-6 is-clean -- SEAL_EXCLUDES appears $N6_GATES times (want 2: abort gate + one squash-stage gate)"
}

# ============================================================================
# WP 1-09 (CDT-414 / W3-37): EPIC_SEAL_RELEASE_HOOK runs only with
# EPIC_TEST_MODE=1; EPIC_ALLOW_SEAL_RELEASE=1 counts only while the state is
# seal-staged (seal_stage non-null).
# ============================================================================
{
  # assert_env <repo> <epic> [VAR=val...] -> sets RC (assert-release-allowed)
  assert_env() {
    local repo="$1" epic="$2"; shift 2
    OUT=$(cd "$repo" && env ${@+"$@"} EPIC_ROOT="$repo" bash "$LIB" assert-release-allowed "$epic" 2>&1)
    RC=$?
  }

  # H-1: hook set without EPIC_TEST_MODE -> NOT run (no marker), handoff path,
  # stage recorded, warning on stderr. Only the exact value 1 enables the hook.
  mk_ready_epic || true
  if [ -n "${REPO:-}" ]; then
    HOOK_MARK=$(mktemp -u "${TMPDIR:-/tmp}/hook-ran.XXXXXX")
    HOOK_ERR=$(mktemp "${TMPDIR:-/tmp}/hook-err.XXXXXX")
    SO=$(cd "$REPO" && EPIC_ROOT="$REPO" EPIC_SEAL_RELEASE_HOOK="touch $HOOK_MARK" \
      bash "$LIB" seal "$EPIC_ID" 2>"$HOOK_ERR")
    RC=$?
    [ "$RC" -eq 0 ] && pass || fail "H-1 seal without test mode rc=$RC out=$SO err=$(cat "$HOOK_ERR")"
    [ ! -e "$HOOK_MARK" ] && pass || fail "H-1 hook ran without EPIC_TEST_MODE=1"
    printf '%s' "$SO" | jq -e '.sealed==false and .staged==true and .release_invoked==false' >/dev/null 2>&1 \
      && pass || fail "H-1 want the handoff JSON (out=$SO)"
    grep -q 'EPIC_TEST_MODE' "$HOOK_ERR" && pass || fail "H-1 stderr must explain the ignored hook (err=$(cat "$HOOK_ERR"))"
    jq -e '.seal_stage != null' "$REPO/.claude/epics/$EPIC_ID/state.json" >/dev/null 2>&1 \
      && pass || fail "H-1 handoff must leave seal_stage recorded"

    # H-2: the production flow. Staged + env -> allowed; staged without env ->
    # refused; --complete (sealed=true) -> allowed without env.
    assert_env "$REPO" "$EPIC_ID" EPIC_ALLOW_SEAL_RELEASE=1
    [ "$RC" -eq 0 ] && pass || fail "H-2 staged + env must allow (rc=$RC out=$OUT)"
    assert_env "$REPO" "$EPIC_ID"
    [ "$RC" -eq 64 ] && pass || fail "H-2 staged without env must refuse (rc=$RC out=$OUT)"
    seal_run "$REPO" seal "$EPIC_ID" --complete
    [ "$RC" -eq 0 ] && pass || fail "H-2 --complete rc=$RC out=$OUT"
    assert_env "$REPO" "$EPIC_ID"
    [ "$RC" -eq 0 ] && pass || fail "H-2 sealed=true must allow without env (rc=$RC out=$OUT)"
    rm -f "$HOOK_ERR"
    rm -rf "$REPO"
  fi

  # H-3: EPIC_TEST_MODE=true (not the exact value 1) also ignores the hook.
  mk_ready_epic || true
  if [ -n "${REPO:-}" ]; then
    HOOK_MARK=$(mktemp -u "${TMPDIR:-/tmp}/hook-ran.XXXXXX")
    SO=$(cd "$REPO" && EPIC_ROOT="$REPO" EPIC_TEST_MODE=true EPIC_SEAL_RELEASE_HOOK="touch $HOOK_MARK" \
      bash "$LIB" seal "$EPIC_ID" 2>/dev/null)
    [ ! -e "$HOOK_MARK" ] && pass || fail "H-3 hook ran with EPIC_TEST_MODE=true"
    rm -rf "$REPO"
  fi

  # H-4: with EPIC_TEST_MODE=1 the hook runs once, with the seal env set and
  # seal_stage still recorded while it runs (what assert-release-allowed reads).
  mk_ready_epic || true
  if [ -n "${REPO:-}" ]; then
    HOOK_OUT=$(mktemp "${TMPDIR:-/tmp}/hook-out.XXXXXX")
    HOOK_SRC='assert_rc=0; bash "$EPIC_LIB_UNDER_TEST" assert-release-allowed "$EPIC_ID" >/dev/null 2>&1 || assert_rc=$?; printf "%s %s\n" "$EPIC_ALLOW_SEAL_RELEASE" "$assert_rc" >>"$HOOK_OUT_FILE"'
    SO=$(cd "$REPO" && EPIC_ROOT="$REPO" EPIC_TEST_MODE=1 EPIC_LIB_UNDER_TEST="$LIB" HOOK_OUT_FILE="$HOOK_OUT" \
      EPIC_SEAL_RELEASE_HOOK="$HOOK_SRC" bash "$LIB" seal "$EPIC_ID" 2>/dev/null)
    RC=$?
    [ "$RC" -eq 0 ] && pass || fail "H-4 hook seal rc=$RC out=$SO"
    [ "$(cat "$HOOK_OUT")" = "1 0" ] && pass || fail "H-4 hook saw '$(cat "$HOOK_OUT")' (want '1 0': env=1 and assert allowed while staged)"
    rm -f "$HOOK_OUT"
    rm -rf "$REPO"
  fi

  # H-5: after a bare --abort the stage is gone, so the env var no longer bypasses.
  mk_ready_epic || true
  if [ -n "${REPO:-}" ]; then
    seal_run "$REPO" seal "$EPIC_ID"
    [ "$RC" -eq 0 ] && pass || fail "H-5 seal rc=$RC out=$OUT"
    seal_run "$REPO" seal "$EPIC_ID" --abort
    [ "$RC" -eq 0 ] && pass || fail "H-5 abort rc=$RC out=$OUT"
    assert_env "$REPO" "$EPIC_ID" EPIC_ALLOW_SEAL_RELEASE=1
    [ "$RC" -eq 64 ] && pass || fail "H-5 env after abort must not bypass (rc=$RC out=$OUT)"
    rm -rf "$REPO"
  fi
}

echo "----------------------------------------"
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
