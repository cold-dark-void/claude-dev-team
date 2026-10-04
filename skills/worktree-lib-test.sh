#!/usr/bin/env bash
# worktree-lib-test.sh -- bite-tests for worktree-lib.sh (CDV-189 Part 2,
# CDT-162, WP 1-06 branch-deletion-safety AC E/F/G/H)
#
# Machine-check: bash skills/worktree-lib-test.sh  (exit 0)
# THIS SCRIPT IS A SUBPROCESS CLI -- NEVER SOURCE IT.

set -u

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
LIB="$SCRIPT_DIR/worktree-lib.sh"

# SPEC-030 R20 hermetic suite helper: isolated TMPDIR/HOME, fixed git author
# identity, trap hermetic_cleanup EXIT.
. "$ROOT/tests/lib/hermetic.sh"
hermetic_init
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
unset GIT_DIR GIT_INDEX_FILE GIT_WORK_TREE

PASS=0
FAIL=0

die() { echo "FAIL: $*" >&2; exit 1; }

# shellcheck source=../tests/lib/assert.sh
. "$ROOT/tests/lib/assert.sh"

# ---- Isolated fake MROOT ----------------------------------------------------
TMP=$(mktemp -d "${TMPDIR:-/tmp}/worktree-lib-test.XXXXXX")
# ERR_TMP lives under $TMP (WP 1-06 AC F3): the EXIT trap below rm -rf's
# $TMP, so a killed/died run leaves nothing under $TMPDIR either -- the old
# ERR_TMP sat directly in $TMPDIR and relied on a fragile end-of-script rm.
ERR_TMP="$TMP/wt-test-err.$$"
cleanup() { rm -rf "$TMP"; hermetic_cleanup; }
trap cleanup EXIT

git init -q -b master "$TMP" || die "git init failed"
git -C "$TMP" config user.email "test@example.com"
git -C "$TMP" config user.name "Test"
git -C "$TMP" commit --allow-empty -q -m "init" || die "empty commit failed"
cd "$TMP" || die "cd $TMP"

run_lib() {
  # Preserve exit code; capture stdout/stderr separately when needed
  bash "$LIB" "$@"
}

echo "== T1 status empty =="
OUT=$(run_lib status 2>"$ERR_TMP"); RC=$?
assert_eq "status empty exit 0" "$RC" "0"
assert_eq "status empty stdout" "$OUT" ""

echo "== T2 status FRESH / STALE =="
mkdir -p .worktrees/fresh-slug .worktrees/stale-slug
# Minimal git checkout markers optional — status tolerates (unknown) HEAD
NOW=$(date +%s)
printf '%s %s\n' "$NOW" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > .worktrees/fresh-slug/.wt-lock
OLD=$(( NOW - 86400 ))
printf '%s %s\n' "$OLD" "2020-01-01T00:00:00Z" > .worktrees/stale-slug/.wt-lock
# No-lock dir
mkdir -p .worktrees/none-slug

export WT_LOCK_TTL_SECONDS=21600
OUT=$(run_lib status 2>"$ERR_TMP"); RC=$?
assert_eq "status FRESH/STALE exit 0" "$RC" "0"
assert_contains "status has fresh FRESH" "$OUT" "fresh-slug"
assert_contains "status FRESH state" "$OUT" "fresh-slug | feat/fresh-slug | FRESH |"
assert_contains "status STALE state" "$OUT" "stale-slug | feat/stale-slug | STALE |"
assert_contains "status NONE state" "$OUT" "none-slug | feat/none-slug | NONE | - |"
assert_not_contains "status no PID field" "$OUT" "PID"
assert_not_contains "status no session_id" "$OUT" "session"

echo "== T3 list alias (age-column masked, CDT-298 de-flake) =="
# The fresh-slug lock's age column is the only field that can differ between
# two back-to-back invocations: crossing a 1s boundary flips "0s" -> "1s",
# which is exactly how the old raw `assert_eq "list == status"` flaked.
# Sleep past a boundary, prove the raw outputs really do differ, then compare
# with the volatile age column masked.
sleep 1
LIST_OUT=$(run_lib list 2>"$ERR_TMP"); LRC=$?
assert_eq "list exit 0" "$LRC" "0"
if [ "$LIST_OUT" = "$OUT" ]; then
  FAIL=$((FAIL + 1)); echo "  FAIL list vs status identical across a 1s boundary — flake regression case not live"
else
  PASS=$((PASS + 1)); echo "  ok  list vs status differ across the 1s boundary (flake case is live)"
fi
mask_age_col() { printf '%s\n' "$1" | awk -F ' \\| ' '{ OFS=" | "; $4="<age>"; print }'; }
assert_eq "list == status (age column masked)" "$(mask_age_col "$LIST_OUT")" "$(mask_age_col "$OUT")"

echo "== T4 register ok / missing =="
mkdir -p .worktrees/reg-slug
ROUT=$(run_lib register reg-slug 2>"$ERR_TMP"); RRC=$?
assert_eq "register ok exit 0" "$RRC" "0"
assert_eq "register prints path" "$ROUT" "$TMP/.worktrees/reg-slug"
assert_file "register wrote lock" ".worktrees/reg-slug/.wt-lock"
# mode 600 (umask 077)
MODE=$(stat -c '%a' .worktrees/reg-slug/.wt-lock 2>/dev/null || stat -f '%Lp' .worktrees/reg-slug/.wt-lock)
assert_eq "register lock mode 600" "$MODE" "600"
# lock format epoch ISO
LOCK_LINE=$(head -1 .worktrees/reg-slug/.wt-lock)
if [[ "$LOCK_LINE" =~ ^[0-9]+[[:space:]]+[0-9]{4}-[0-9]{2}-[0-9]{2}T ]]; then
  PASS=$((PASS + 1)); echo "  ok  register lock format"
else
  FAIL=$((FAIL + 1)); echo "  FAIL register lock format: $LOCK_LINE"
fi
# no branch created by register
if git rev-parse --verify --quiet refs/heads/feat/reg-slug >/dev/null 2>&1; then
  FAIL=$((FAIL + 1)); echo "  FAIL register must not create branch"
else
  PASS=$((PASS + 1)); echo "  ok  register no branch"
fi

ROUT=$(run_lib register missing-slug 2>"$ERR_TMP"); RRC=$?
assert_eq "register missing exit 1" "$RRC" "1"

echo "== T5 release dirty refuses =="
# Real worktree via ensure
EOUT=$(run_lib ensure dirty-slug 2>"$ERR_TMP"); ERC=$?
assert_eq "ensure dirty-slug exit 0" "$ERC" "0"
assert_dir "ensure created wt" ".worktrees/dirty-slug"
# Dirtify
echo "dirty" > .worktrees/dirty-slug/dirty.txt
REL_OUT=$(run_lib release dirty-slug 2>"$ERR_TMP"); RERC=$?
assert_eq "release dirty exit 1" "$RERC" "1"
assert_dir "release dirty kept dir" ".worktrees/dirty-slug"
assert_file "release dirty kept dirty file" ".worktrees/dirty-slug/dirty.txt"
# cleanup for later: remove dirty so we can release if needed
rm -f .worktrees/dirty-slug/dirty.txt

echo "== T6 sweep no-delete =="
# stale-slug already STALE, no tasks → PROPOSAL
# fresh-slug FRESH → not proposed
# Add live-task worktree STALE but protected by task
mkdir -p .worktrees/live-slug .claude/tasks
printf '%s %s\n' "$OLD" "2020-01-01T00:00:00Z" > .worktrees/live-slug/.wt-lock
cat > .claude/tasks/live-slug.json << 'JSON'
{"task_id":"live-slug","subject":"held","status":"in_progress","requires_council":false,"depends_on":[],"created_at":"2020-01-01T00:00:00Z"}
JSON

SWEEP=$(run_lib sweep 2>"$ERR_TMP"); SRC=$?
assert_eq "sweep exit 0" "$SRC" "0"
assert_contains "sweep proposes stale-slug" "$SWEEP" "PROPOSAL stale-slug"
assert_not_contains "sweep skips FRESH" "$SWEEP" "PROPOSAL fresh-slug"
assert_not_contains "sweep skips live task" "$SWEEP" "PROPOSAL live-slug"
assert_dir "sweep did not delete stale" ".worktrees/stale-slug"
assert_file "sweep did not delete stale lock" ".worktrees/stale-slug/.wt-lock"
assert_dir "sweep did not delete live" ".worktrees/live-slug"

# completed task should NOT protect
cat > .claude/tasks/stale-slug.json << 'JSON'
{"task_id":"stale-slug","subject":"done","status":"completed","requires_council":false,"depends_on":[],"created_at":"2020-01-01T00:00:00Z"}
JSON
SWEEP2=$(run_lib sweep 2>"$ERR_TMP"); SRC2=$?
assert_eq "sweep completed still proposes" "$SRC2" "0"
assert_contains "sweep still proposes completed-task slug" "$SWEEP2" "PROPOSAL stale-slug"

echo "== T7 ensure git_retry (CDT-161) =="
# AC-1 static: every worktree add in cmd_ensure must use git_retry 3 200
ENSURE_BODY=$(awk '
  /^cmd_ensure\(\)/ { p=1; next }
  /^cmd_[a-z_]+\(\)/ { if (p) exit }
  p { print }
' "$LIB")
RETRY_ADD=0
BARE_ADD=0
while IFS= read -r line; do
  [ -z "$line" ] && continue
  # Comments may mention worktree add — only code lines with the phrase
  case "$line" in
    *'#'*) continue ;;
  esac
  printf '%s' "$line" | grep -q 'worktree add' || continue
  if printf '%s' "$line" | grep -q 'git_retry 3 200'; then
    RETRY_ADD=$((RETRY_ADD + 1))
  else
    BARE_ADD=$((BARE_ADD + 1))
  fi
done <<EOF
$ENSURE_BODY
EOF
assert_eq "AC-1 no bare worktree add in cmd_ensure" "$BARE_ADD" "0"
# Require 3: existing-branch arm + -b arm + plain fallback after re-probe
if [ "$RETRY_ADD" -ge 3 ]; then
  PASS=$((PASS + 1))
  echo "  ok  AC-1 git_retry 3 200 worktree add count>=3 ($RETRY_ADD)"
else
  FAIL=$((FAIL + 1))
  echo "  FAIL AC-1 git_retry 3 200 worktree add count>=3: got=$RETRY_ADD"
fi
# Re-probe path pin: capture -b rc via _add_rc, gate plain fallback on ! -e wt
if printf '%s\n' "$ENSURE_BODY" | grep -q '_add_rc' \
   && printf '%s\n' "$ENSURE_BODY" | grep -qF '[ ! -e "$wt" ]'; then
  PASS=$((PASS + 1))
  echo "  ok  AC-1 re-probe fallback pattern present"
else
  FAIL=$((FAIL + 1))
  echo "  FAIL AC-1 re-probe fallback pattern missing (_add_rc + ! -e wt)"
fi

# AC-3/4 runtime: PATH git shim fails first N worktree-add with EBUSY, then real git.
# Skip only if REAL_GIT cannot be resolved before PATH override.
REAL_GIT=$(command -v git || true)
if [ -n "$REAL_GIT" ] && [ -x "$REAL_GIT" ]; then
  SHIMDIR=$(mktemp -d "${TMPDIR:-/tmp}/wt-git-shim.XXXXXX")
  COUNTER_FILE="$SHIMDIR/add-count"
  cat > "$SHIMDIR/git" <<'SHIM'
#!/usr/bin/env bash
# Forward all git; on worktree add fail first FAIL_N times with EBUSY (CDT-161).
is_add=0
prev=""
for a in "$@"; do
  if [ "$prev" = "worktree" ] && [ "$a" = "add" ]; then
    is_add=1
    break
  fi
  prev=$a
done
if [ "$is_add" -eq 1 ]; then
  n=0
  if [ -n "${COUNTER_FILE:-}" ] && [ -f "$COUNTER_FILE" ]; then
    n=$(cat "$COUNTER_FILE" 2>/dev/null || echo 0)
  fi
  case "$n" in ''|*[!0-9]*) n=0 ;; esac
  if [ "$n" -lt "${FAIL_N:-0}" ]; then
    echo $((n + 1)) > "$COUNTER_FILE"
    echo "fatal: could not create worktree: Device or resource busy" >&2
    exit 1
  fi
fi
exec "$REAL_GIT" "$@"
SHIM
  chmod +x "$SHIMDIR/git"
  # Expand env into shim (heredoc was quoted — inject via wrapper env)
  # REAL_GIT / COUNTER_FILE / FAIL_N read from environment by shim.

  run_lib_shim() {
    PATH="$SHIMDIR:$PATH" REAL_GIT="$REAL_GIT" COUNTER_FILE="$COUNTER_FILE" \
      FAIL_N="$FAIL_N" bash "$LIB" "$@"
  }

  # AC-3: N=2 (< budget 3) → ensure succeeds, path + lock
  FAIL_N=2
  echo 0 > "$COUNTER_FILE"
  E3OUT=$(run_lib_shim ensure ebusy-ok 2>"$ERR_TMP"); E3RC=$?
  assert_eq "AC-3 EBUSY within budget exit 0" "$E3RC" "0"
  assert_eq "AC-3 stdout path" "$E3OUT" "$TMP/.worktrees/ebusy-ok"
  assert_dir "AC-3 worktree dir" ".worktrees/ebusy-ok"
  assert_file "AC-3 lock written" ".worktrees/ebusy-ok/.wt-lock"

  # AC-4: N=5 (≥ budget 3) → non-zero, empty stdout, no success lock
  FAIL_N=5
  echo 0 > "$COUNTER_FILE"
  E4OUT=$(run_lib_shim ensure ebusy-fail 2>"$ERR_TMP"); E4RC=$?
  if [ "$E4RC" -ne 0 ]; then
    PASS=$((PASS + 1))
    echo "  ok  AC-4 exhausted EBUSY non-zero (rc=$E4RC)"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL AC-4 exhausted EBUSY non-zero: got rc=0"
  fi
  assert_eq "AC-4 empty stdout" "$E4OUT" ""
  if [ ! -f ".worktrees/ebusy-fail/.wt-lock" ]; then
    PASS=$((PASS + 1))
    echo "  ok  AC-4 no success lock"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL AC-4 no success lock: lock present"
  fi

  rm -rf "$SHIMDIR"
else
  echo "  skip AC-3/4 runtime (git not found for shim)"
fi

# ---- CDT-162: ensure STALE reclaim guards ---------------------------------
NOW=$(date +%s)
OLD=$(( NOW - 86400 ))

echo "== T8 ensure STALE clean reclaim =="
EOUT=$(run_lib ensure ens-clean 2>"$ERR_TMP"); ERC=$?
assert_eq "ensure ens-clean create exit 0" "$ERC" "0"
assert_eq "ensure ens-clean path" "$EOUT" "$TMP/.worktrees/ens-clean"
printf '%s %s\n' "$OLD" "2020-01-01T00:00:00Z" > .worktrees/ens-clean/.wt-lock
LOCK_STALE=$(cat .worktrees/ens-clean/.wt-lock)
EOUT=$(run_lib ensure ens-clean 2>"$ERR_TMP"); ERC=$?
assert_eq "ensure STALE clean exit 0" "$ERC" "0"
assert_eq "ensure STALE clean path" "$EOUT" "$TMP/.worktrees/ens-clean"
LOCK_AFTER=$(cat .worktrees/ens-clean/.wt-lock)
if [ "$LOCK_AFTER" != "$LOCK_STALE" ]; then
  PASS=$((PASS + 1)); echo "  ok  ensure STALE clean lock rewritten"
else
  FAIL=$((FAIL + 1)); echo "  FAIL ensure STALE clean lock unchanged: $LOCK_AFTER"
fi
EPOCH_AFTER=$(awk '{print $1}' .worktrees/ens-clean/.wt-lock)
if [[ "$EPOCH_AFTER" =~ ^[0-9]+$ ]] && [ "$EPOCH_AFTER" -ge $((NOW - 120)) ]; then
  PASS=$((PASS + 1)); echo "  ok  ensure STALE clean lock epoch fresh"
else
  FAIL=$((FAIL + 1)); echo "  FAIL ensure STALE clean lock epoch: $EPOCH_AFTER"
fi

echo "== T9 ensure STALE dirty refuse =="
EOUT=$(run_lib ensure ens-dirty 2>"$ERR_TMP"); ERC=$?
assert_eq "ensure ens-dirty create exit 0" "$ERC" "0"
printf '%s %s\n' "$OLD" "2020-01-01T00:00:00Z" > .worktrees/ens-dirty/.wt-lock
LOCK_STALE=$(cat .worktrees/ens-dirty/.wt-lock)
echo "dirt" > .worktrees/ens-dirty/dirty.txt
EOUT=$(run_lib ensure ens-dirty 2>"$ERR_TMP"); ERC=$?
ERR=$(cat "$ERR_TMP" 2>/dev/null || true)
assert_eq "ensure STALE dirty exit 1" "$ERC" "1"
assert_eq "ensure STALE dirty empty stdout" "$EOUT" ""
assert_eq "ensure STALE dirty lock unchanged" "$(cat .worktrees/ens-dirty/.wt-lock)" "$LOCK_STALE"
if [ -n "$ERR" ]; then
  PASS=$((PASS + 1)); echo "  ok  ensure STALE dirty stderr non-empty"
else
  FAIL=$((FAIL + 1)); echo "  FAIL ensure STALE dirty stderr empty"
fi
assert_contains "ensure STALE dirty reason" "$ERR" "refusing STALE reclaim"
rm -f .worktrees/ens-dirty/dirty.txt

echo "== T10 ensure STALE live-task refuse =="
EOUT=$(run_lib ensure ens-live 2>"$ERR_TMP"); ERC=$?
assert_eq "ensure ens-live create exit 0" "$ERC" "0"
printf '%s %s\n' "$OLD" "2020-01-01T00:00:00Z" > .worktrees/ens-live/.wt-lock
LOCK_STALE=$(cat .worktrees/ens-live/.wt-lock)
mkdir -p .claude/tasks
cat > .claude/tasks/ens-live.json << 'JSON'
{"task_id":"ens-live","subject":"held","status":"in_progress","requires_council":false,"depends_on":[],"created_at":"2020-01-01T00:00:00Z"}
JSON
EOUT=$(run_lib ensure ens-live 2>"$ERR_TMP"); ERC=$?
ERR=$(cat "$ERR_TMP" 2>/dev/null || true)
assert_eq "ensure STALE live exit 1" "$ERC" "1"
assert_eq "ensure STALE live empty stdout" "$EOUT" ""
assert_eq "ensure STALE live lock unchanged" "$(cat .worktrees/ens-live/.wt-lock)" "$LOCK_STALE"
if [ -n "$ERR" ]; then
  PASS=$((PASS + 1)); echo "  ok  ensure STALE live stderr non-empty"
else
  FAIL=$((FAIL + 1)); echo "  FAIL ensure STALE live stderr empty"
fi
assert_contains "ensure STALE live reason" "$ERR" "live task"

# ERR_TMP is under $TMP; the EXIT trap (cleanup) removes it -- no explicit
# rm needed here (WP 1-06 AC F3).

# ---------------------------------------------------------------------------
# WP 1-06 branch-deletion-safety: AC E (release never forces, branch delete
# only via git-safety.sh), AC F (ensure non-git-dir refusal, no leaked temp
# file), AC G (release --preview), AC H (docs match the lib).
# ---------------------------------------------------------------------------

# mk_release_fixture <slug>
# ensure-creates .worktrees/<slug> on branch feat/<slug>, commits one real
# file in it, and plants a branch.feat/<slug> config key so the E/G checks
# below can tell whether release's branch-delete step touched it.
mk_release_fixture() {
  local slug="$1" out rc
  out=$(run_lib ensure "$slug" 2>"$ERR_TMP"); rc=$?
  [ "$rc" -eq 0 ] || die "mk_release_fixture $slug: ensure failed rc=$rc $(cat "$ERR_TMP" 2>/dev/null)"
  printf 'line one for %s\n' "$slug" > ".worktrees/$slug/file-$slug.txt"
  git -C ".worktrees/$slug" add "file-$slug.txt"
  git -C ".worktrees/$slug" commit -q -m "work on $slug"
  git config "branch.feat/$slug.description" "test-marker-$slug"
}

# assert_preview_order <name> <preview_output>
# WP 1-06 review spec-check gap 2b: the eight release --preview lines must
# come in the fixed SPEC-016 order, not just be present somewhere in the
# output.
assert_preview_order() {
  local name="$1" out="$2" want got
  want="branch\nbase\nahead_of_base\nupstream\nahead_of_upstream\nmerged\npushed\nconfirm"
  want=$(printf '%b' "$want")
  got=$(printf '%s\n' "$out" | sed -n 's/^\([a-zA-Z_]*\):.*/\1/p')
  assert_eq "$name" "$got" "$want"
}

echo "== T11 release static: no force fallback, no direct branch delete (AC E1) =="
LIB_TEXT=$(cat "$LIB")
assert_not_contains "worktree-lib.sh has no 'worktree remove --force' text" "$LIB_TEXT" "worktree remove --force"
assert_not_contains "worktree-lib.sh has no 'branch -D' text" "$LIB_TEXT" "branch -D"
assert_contains "worktree-lib.sh usage mentions --preview" "$LIB_TEXT" "release [--preview]"
assert_not_contains "worktree-lib.sh has no base-order list copy" "$LIB_TEXT" "origin/master origin/main master main"

# Planted negative control (hazard checklist): prove the exact-substring
# checks above are not vacuously true by running them against text that
# DOES contain the banned strings.
PLANTED='git worktree remove --force "$wt"
git branch -D "$branch"
candidates="origin/master origin/main master main"'
CTRL_HIT=0
printf '%s' "$PLANTED" | grep -qF -- "worktree remove --force" && CTRL_HIT=$((CTRL_HIT + 1))
printf '%s' "$PLANTED" | grep -qF -- "branch -D" && CTRL_HIT=$((CTRL_HIT + 1))
printf '%s' "$PLANTED" | grep -qF -- "origin/master origin/main master main" && CTRL_HIT=$((CTRL_HIT + 1))
assert_eq "T11 negative control catches all 3 banned strings" "$CTRL_HIT" "3"

echo "== T12 ensure refuses a non-git directory under .worktrees/ (AC F1) =="
mkdir -p .worktrees/plain-dir
NGOUT=$(run_lib ensure plain-dir 2>"$ERR_TMP"); NGRC=$?
NGERR=$(cat "$ERR_TMP" 2>/dev/null || true)
assert_eq "ensure plain-dir exit 1" "$NGRC" "1"
assert_eq "ensure plain-dir empty stdout" "$NGOUT" ""
assert_contains "ensure plain-dir stderr names the dir" "$NGERR" ".worktrees/plain-dir"
if [ -f ".worktrees/plain-dir/.wt-lock" ]; then
  FAIL=$((FAIL + 1)); echo "  FAIL ensure plain-dir must not write .wt-lock"
else
  PASS=$((PASS + 1)); echo "  ok  ensure plain-dir wrote no .wt-lock"
fi
# Negative control: a real worktree at the same shape (existing dir, no
# lock) must still succeed -- proves the check does not blanket-refuse.
CTRLOUT=$(run_lib ensure ctrl-real-wt 2>"$ERR_TMP"); CTRLRC=$?
assert_eq "ensure real worktree control exit 0" "$CTRLRC" "0"
rm -f .worktrees/ctrl-real-wt/.wt-lock
CTRLOUT2=$(run_lib ensure ctrl-real-wt 2>"$ERR_TMP"); CTRLRC2=$?
assert_eq "ensure real worktree, no-lock re-run, exit 0 (negative control)" "$CTRLRC2" "0"

echo "== T13 release: a locked worktree refuses, no force retry (AC E2) =="
mk_release_fixture rel-locked
git worktree lock ".worktrees/rel-locked" 2>"$ERR_TMP" || die "git worktree lock failed: $(cat "$ERR_TMP")"
LKOUT=$(run_lib release rel-locked 2>"$ERR_TMP"); LKRC=$?
LKERR=$(cat "$ERR_TMP" 2>/dev/null || true)
assert_eq "release locked exit 1" "$LKRC" "1"
assert_dir "release locked kept the worktree dir" ".worktrees/rel-locked"
if git rev-parse --verify --quiet refs/heads/feat/rel-locked >/dev/null 2>&1; then
  PASS=$((PASS + 1)); echo "  ok  release locked kept the branch"
else
  FAIL=$((FAIL + 1)); echo "  FAIL release locked deleted the branch"
fi
LKCFG=$(git config --get "branch.feat/rel-locked.description" 2>/dev/null || true)
assert_eq "release locked kept the config section" "$LKCFG" "test-marker-rel-locked"
assert_contains "release locked stderr states not-forcing (not a force retry)" "$LKERR" "not forcing"
git worktree unlock ".worktrees/rel-locked" 2>/dev/null || true

echo "== T14 release: a fast-forward-merged branch is deleted (AC E3) =="
mk_release_fixture rel-ff
git merge -q --ff-only "feat/rel-ff" || die "ff-only merge failed"
FFOUT=$(run_lib release rel-ff 2>"$ERR_TMP"); FFRC=$?
FFERR=$(cat "$ERR_TMP" 2>/dev/null || true)
assert_eq "release ff-merged exit 0" "$FFRC" "0"
if [ -d ".worktrees/rel-ff" ]; then
  FAIL=$((FAIL + 1)); echo "  FAIL release ff-merged worktree still present"
else
  PASS=$((PASS + 1)); echo "  ok  release ff-merged worktree removed"
fi
if git rev-parse --verify --quiet refs/heads/feat/rel-ff >/dev/null 2>&1; then
  FAIL=$((FAIL + 1)); echo "  FAIL release ff-merged branch still present"
else
  PASS=$((PASS + 1)); echo "  ok  release ff-merged branch deleted"
fi
FFCFG=$(git config --get "branch.feat/rel-ff.description" 2>/dev/null || true)
assert_eq "release ff-merged config section gone" "$FFCFG" ""
assert_not_contains "release ff-merged stderr has no kept message" "$FFERR" "kept feat/rel-ff"

echo "== T15 release: a squash-merged branch is deleted (AC E3) =="
mk_release_fixture rel-squash
git merge -q --squash "feat/rel-squash" || die "squash merge (stage) failed"
git commit -q -m "squash rel-squash"
SQOUT=$(run_lib release rel-squash 2>"$ERR_TMP"); SQRC=$?
assert_eq "release squash-merged exit 0" "$SQRC" "0"
if [ -d ".worktrees/rel-squash" ]; then
  FAIL=$((FAIL + 1)); echo "  FAIL release squash-merged worktree still present"
else
  PASS=$((PASS + 1)); echo "  ok  release squash-merged worktree removed"
fi
if git rev-parse --verify --quiet refs/heads/feat/rel-squash >/dev/null 2>&1; then
  FAIL=$((FAIL + 1)); echo "  FAIL release squash-merged branch still present"
else
  PASS=$((PASS + 1)); echo "  ok  release squash-merged branch deleted"
fi
SQCFG=$(git config --get "branch.feat/rel-squash.description" 2>/dev/null || true)
assert_eq "release squash-merged config section gone" "$SQCFG" ""

echo "== T16 release: an unmerged branch is kept with a stderr warning (AC E4) =="
mk_release_fixture rel-unique
UQOUT=$(run_lib release rel-unique 2>"$ERR_TMP"); UQRC=$?
UQERR=$(cat "$ERR_TMP" 2>/dev/null || true)
assert_eq "release unmerged exit 0" "$UQRC" "0"
if [ -d ".worktrees/rel-unique" ]; then
  FAIL=$((FAIL + 1)); echo "  FAIL release unmerged worktree still present"
else
  PASS=$((PASS + 1)); echo "  ok  release unmerged worktree removed"
fi
if git rev-parse --verify --quiet refs/heads/feat/rel-unique >/dev/null 2>&1; then
  PASS=$((PASS + 1)); echo "  ok  release unmerged kept the branch"
else
  FAIL=$((FAIL + 1)); echo "  FAIL release unmerged deleted the branch"
fi
UQCFG=$(git config --get "branch.feat/rel-unique.description" 2>/dev/null || true)
assert_eq "release unmerged kept the config section" "$UQCFG" "test-marker-rel-unique"
assert_contains "release unmerged stderr kept message" "$UQERR" "release: kept feat/rel-unique"

echo "== T17 release: a dirty tree refuses, branch/config untouched (AC E5) =="
mk_release_fixture rel-dirty2
echo "dirty" > .worktrees/rel-dirty2/scratch.txt
D2OUT=$(run_lib release rel-dirty2 2>"$ERR_TMP"); D2RC=$?
assert_eq "release dirty2 exit 1" "$D2RC" "1"
assert_dir "release dirty2 kept the worktree dir" ".worktrees/rel-dirty2"
if git rev-parse --verify --quiet refs/heads/feat/rel-dirty2 >/dev/null 2>&1; then
  PASS=$((PASS + 1)); echo "  ok  release dirty2 kept the branch"
else
  FAIL=$((FAIL + 1)); echo "  FAIL release dirty2 deleted the branch"
fi
D2CFG=$(git config --get "branch.feat/rel-dirty2.description" 2>/dev/null || true)
assert_eq "release dirty2 kept the config section" "$D2CFG" "test-marker-rel-dirty2"
rm -f .worktrees/rel-dirty2/scratch.txt

echo "== T18 preview: unmerged branch, no upstream, worktree already gone (AC G1) =="
# Expected per SPEC-016 section release: "ahead_of_upstream counts the
# commits that are on no remote ref" when there is no upstream.
EXPECT_UP18=$(git rev-list --count feat/rel-unique --not --remotes)
PVOUT=$(run_lib release --preview rel-unique 2>"$ERR_TMP"); PVRC=$?
assert_eq "preview unmerged exit 0" "$PVRC" "0"
assert_contains "preview unmerged branch line" "$PVOUT" "branch: feat/rel-unique"
assert_contains "preview unmerged base line" "$PVOUT" "base: master"
assert_contains "preview unmerged upstream none" "$PVOUT" "upstream: none"
assert_contains "preview unmerged ahead_of_upstream value" "$PVOUT" "ahead_of_upstream: $EXPECT_UP18"
assert_contains "preview unmerged merged no" "$PVOUT" "merged: no"
assert_contains "preview unmerged pushed no" "$PVOUT" "pushed: no"
assert_contains "preview unmerged confirm slug" "$PVOUT" "confirm: slug"
PVLINES=$(printf '%s\n' "$PVOUT" | wc -l | tr -d ' ')
assert_eq "preview prints exactly 8 lines" "$PVLINES" "8"
assert_preview_order "preview unmerged lines are in SPEC-016 order" "$PVOUT"

echo "== T19 preview: branch does not exist (AC G1 branch-absent) =="
NBOUT=$(run_lib release --preview no-such-branch-slug 2>"$ERR_TMP"); NBRC=$?
assert_eq "preview no-branch exit 0" "$NBRC" "0"
assert_contains "preview no-branch branch none" "$NBOUT" "branch: none"
assert_contains "preview no-branch ahead_of_base 0" "$NBOUT" "ahead_of_base: 0"
assert_contains "preview no-branch upstream none" "$NBOUT" "upstream: none"
assert_contains "preview no-branch ahead_of_upstream 0" "$NBOUT" "ahead_of_upstream: 0"
assert_contains "preview no-branch merged no" "$NBOUT" "merged: no"
assert_contains "preview no-branch pushed no" "$NBOUT" "pushed: no"
assert_contains "preview no-branch confirm yesno" "$NBOUT" "confirm: yesno"

echo "== T20 preview: squash-merged local, no upstream; no side effects (AC G1, G2) =="
mk_release_fixture prev-squash
git merge -q --squash "feat/prev-squash" || die "squash merge (stage) failed"
git commit -q -m "squash prev-squash"
PS_LOCK_BEFORE=$(cat .worktrees/prev-squash/.wt-lock)
PS_SHA_BEFORE=$(git rev-parse refs/heads/feat/prev-squash)
PS_CFG_BEFORE=$(git config --get "branch.feat/prev-squash.description")
PSOUT=$(run_lib release --preview prev-squash 2>"$ERR_TMP"); PSRC=$?
EXPECT_UP20=$(git rev-list --count feat/prev-squash --not --remotes)
assert_eq "preview squash-local exit 0" "$PSRC" "0"
assert_contains "preview squash-local branch line" "$PSOUT" "branch: feat/prev-squash"
assert_contains "preview squash-local merged yes" "$PSOUT" "merged: yes"
assert_contains "preview squash-local pushed no" "$PSOUT" "pushed: no"
assert_contains "preview squash-local ahead_of_upstream value" "$PSOUT" "ahead_of_upstream: $EXPECT_UP20"
assert_contains "preview squash-local confirm yesno" "$PSOUT" "confirm: yesno"
assert_dir "preview squash-local worktree unchanged (still present)" ".worktrees/prev-squash"
assert_eq "preview squash-local lock unchanged" "$(cat .worktrees/prev-squash/.wt-lock)" "$PS_LOCK_BEFORE"
assert_eq "preview squash-local branch sha unchanged" "$(git rev-parse refs/heads/feat/prev-squash)" "$PS_SHA_BEFORE"
assert_eq "preview squash-local config unchanged" "$(git config --get "branch.feat/prev-squash.description")" "$PS_CFG_BEFORE"

echo "== T21 preview: squash-merged, upstream contains it (AC G1 upstream) =="
BARE="$TMP-origin.git"
git init -q -b master --bare "$BARE" >/dev/null 2>&1 || die "bare origin init failed"
git remote add origin "$BARE"
git push -q origin master
mk_release_fixture prev-up
git push -q -u origin "feat/prev-up"
git merge -q --squash "feat/prev-up" || die "squash merge (stage) failed"
git commit -q -m "squash prev-up"
git push -q origin master
PUOUT=$(run_lib release --preview prev-up 2>"$ERR_TMP"); PURC=$?
assert_eq "preview upstream exit 0" "$PURC" "0"
assert_contains "preview upstream branch line" "$PUOUT" "branch: feat/prev-up"
assert_contains "preview upstream base is origin/master" "$PUOUT" "base: origin/master"
assert_contains "preview upstream merged yes" "$PUOUT" "merged: yes"
assert_contains "preview upstream pushed yes" "$PUOUT" "pushed: yes"
assert_contains "preview upstream confirm yesno" "$PUOUT" "confirm: yesno"
AHEAD_LINE=$(printf '%s\n' "$PUOUT" | grep '^ahead_of_base: ')
AHEAD_N=${AHEAD_LINE#ahead_of_base: }
case "$AHEAD_N" in
  ''|*[!0-9]*)
    FAIL=$((FAIL + 1)); echo "  FAIL preview upstream ahead_of_base not numeric: [$AHEAD_LINE]" ;;
  0)
    FAIL=$((FAIL + 1)); echo "  FAIL preview upstream ahead_of_base should be > 0, got 0" ;;
  *)
    PASS=$((PASS + 1)); echo "  ok  preview upstream ahead_of_base > 0 ($AHEAD_N)" ;;
esac

echo "== T22 static: release --preview confirm prompt markers (AC G3) =="
check_c4_markers() {
  local name="$1" path="$2" text
  text=$(cat "$path" 2>/dev/null)
  assert_contains "$name has a release --preview fence" "$text" "release --preview"
  assert_contains "$name has ahead_of_base token" "$text" "ahead_of_base"
  assert_contains "$name has ahead_of_upstream token" "$text" "ahead_of_upstream"
  assert_contains "$name has confirm: slug token" "$text" "confirm: slug"
  assert_contains "$name has confirm: yesno token" "$text" "confirm: yesno"
  if printf '%s' "$text" | grep -qE 'Type .* to confirm'; then
    PASS=$((PASS + 1)); echo "  ok  $name has a 'Type ... to confirm' prompt line"
  else
    FAIL=$((FAIL + 1)); echo "  FAIL $name missing a 'Type ... to confirm' prompt line"
  fi
  # Tolerant of markdown emphasis around "not" (e.g. "is **not** confirmation").
  if printf '%s' "$text" | grep -qE 'not\*{0,2}[[:space:]]+confirmation'; then
    PASS=$((PASS + 1)); echo "  ok  $name states yes is not confirmation"
  else
    FAIL=$((FAIL + 1)); echo "  FAIL $name missing the 'yes is not confirmation' rule sentence"
  fi
}
check_c4_markers "commands/worktree.md" "$ROOT/commands/worktree.md"
# wrap-ticket SKILL.md is T3's file (parallel wave-1 task) -- red here until
# T3's commit lands; expected per the plan's C4 handshake note.
check_c4_markers "skills/wrap-ticket/SKILL.md" "$ROOT/skills/wrap-ticket/SKILL.md"
assert_not_contains "skills/wrap-ticket/SKILL.md has no 'has already been merged'" \
  "$(cat "$ROOT/skills/wrap-ticket/SKILL.md" 2>/dev/null)" "has already been merged"

echo "== T23 static: docs match the lib (AC H) =="
check_doc_markers() {
  local name="$1" path="$2" text
  text=$(cat "$path" 2>/dev/null)
  assert_contains "$name states never force-removes" "$text" "never force-removes"
  assert_contains "$name states only when it is merged" "$text" "only when it is merged"
  assert_contains "$name states typed slug" "$text" "typed slug"
}
check_doc_markers "docs/commands/worktree.md" "$ROOT/docs/commands/worktree.md"
check_doc_markers "docs/commands/wrap-ticket.md Step 9" "$ROOT/docs/commands/wrap-ticket.md"
assert_not_contains "docs/commands/worktree.md table row is not the bare old text" \
  "$(cat "$ROOT/docs/commands/worktree.md" 2>/dev/null)" \
  "| \`release <slug>\` | Confirm in chat, then remove lock + worktree if clean |"
assert_not_contains "docs/commands/wrap-ticket.md has no bare 'before running git worktree remove'" \
  "$(cat "$ROOT/docs/commands/wrap-ticket.md" 2>/dev/null)" \
  'before running `git worktree remove`'

echo "== T24 ERR_TMP lives under \$TMP, not bare \$TMPDIR (AC F3) =="
case "$ERR_TMP" in
  "$TMP"/*) PASS=$((PASS + 1)); echo "  ok  ERR_TMP is under \$TMP" ;;
  *) FAIL=$((FAIL + 1)); echo "  FAIL ERR_TMP not under \$TMP: $ERR_TMP" ;;
esac

echo "== T25 release: an extra argument after the slug is rejected (review L1) =="
mk_release_fixture rel-badflag
git merge -q --ff-only "feat/rel-badflag" || die "ff-only merge failed"
BF1OUT=$(run_lib release rel-badflag --preview 2>"$ERR_TMP"); BF1RC=$?
BF1ERR=$(cat "$ERR_TMP" 2>/dev/null || true)
assert_eq "release <slug> --preview exit 64" "$BF1RC" "64"
assert_eq "release <slug> --preview empty stdout" "$BF1OUT" ""
assert_contains "release <slug> --preview stderr names the extra arg" "$BF1ERR" "unexpected argument"
assert_dir "release <slug> --preview left the worktree dir" ".worktrees/rel-badflag"
if git rev-parse --verify --quiet refs/heads/feat/rel-badflag >/dev/null 2>&1; then
  PASS=$((PASS + 1)); echo "  ok  release <slug> --preview left the branch (did not really release)"
else
  FAIL=$((FAIL + 1)); echo "  FAIL release <slug> --preview deleted the branch"
fi
BFCFG=$(git config --get "branch.feat/rel-badflag.description" 2>/dev/null || true)
assert_eq "release <slug> --preview left the config section" "$BFCFG" "test-marker-rel-badflag"

BF2OUT=$(run_lib release --preview rel-badflag extra-garbage 2>"$ERR_TMP"); BF2RC=$?
assert_eq "release --preview <slug> <extra> exit 64" "$BF2RC" "64"
assert_eq "release --preview <slug> <extra> empty stdout" "$BF2OUT" ""
assert_dir "release --preview <slug> <extra> left the worktree dir" ".worktrees/rel-badflag"

echo "== T26 release: branch-delete retries a transient git failure (review L2) =="
# origin exists from T21 onward; resolve-base (rv-w3-40) now points the
# ensure-created fixture branch at origin/master, so sync origin with the
# local master BEFORE creating the fixture (the -b start point) and AGAIN
# after the ff-merge (so is-merged sees the branch's commits).
git push -q origin master || die "push master (sync origin, pre-fixture) failed"
mk_release_fixture rel-ebusy
git merge -q --ff-only "feat/rel-ebusy" || die "ff-only merge failed"
git push -q origin master || die "push master (sync origin, post-merge) failed"
REAL_GIT2=$(command -v git || true)
if [ -n "$REAL_GIT2" ] && [ -x "$REAL_GIT2" ]; then
  SHIMDIR2=$(mktemp -d "${TMPDIR:-/tmp}/wt-branchD-shim.XXXXXX")
  COUNTER2="$SHIMDIR2/count"
  echo 0 > "$COUNTER2"
  cat > "$SHIMDIR2/git" <<'SHIM2'
#!/usr/bin/env bash
# Forward all git; on `branch -D` fail the first FAIL_N2 times with a
# WSL2-style EBUSY error, then pass through (WP 1-06 review L2).
is_bd=0
prev=""
for a in "$@"; do
  if [ "$prev" = "branch" ] && [ "$a" = "-D" ]; then
    is_bd=1
    break
  fi
  prev=$a
done
if [ "$is_bd" -eq 1 ]; then
  n=0
  if [ -n "${COUNTER2:-}" ] && [ -f "$COUNTER2" ]; then
    n=$(cat "$COUNTER2" 2>/dev/null || echo 0)
  fi
  case "$n" in ''|*[!0-9]*) n=0 ;; esac
  if [ "$n" -lt "${FAIL_N2:-0}" ]; then
    echo $((n + 1)) > "$COUNTER2"
    echo "error: could not write config: Device or resource busy" >&2
    exit 1
  fi
fi
exec "$REAL_GIT2" "$@"
SHIM2
  chmod +x "$SHIMDIR2/git"
  FAIL_N2=2
  REBOUT=$(PATH="$SHIMDIR2:$PATH" REAL_GIT2="$REAL_GIT2" COUNTER2="$COUNTER2" FAIL_N2="$FAIL_N2" \
    run_lib release rel-ebusy 2>"$ERR_TMP"); REBRC=$?
  REBERR=$(cat "$ERR_TMP" 2>/dev/null || true)
  assert_eq "release ebusy-retry exit 0" "$REBRC" "0"
  if git rev-parse --verify --quiet refs/heads/feat/rel-ebusy >/dev/null 2>&1; then
    FAIL=$((FAIL + 1)); echo "  FAIL release ebusy-retry branch still present after retry"
  else
    PASS=$((PASS + 1)); echo "  ok  release ebusy-retry branch deleted after retrying past the transient failure"
  fi
  EBCFG=$(git config --get "branch.feat/rel-ebusy.description" 2>/dev/null || true)
  assert_eq "release ebusy-retry config section gone" "$EBCFG" ""
  assert_not_contains "release ebusy-retry stderr has no false 'kept' message" "$REBERR" "kept feat/rel-ebusy"
  rm -rf "$SHIMDIR2"
else
  echo "  skip T26 ebusy retry (git not found for shim)"
fi

echo "== T27 negative control: the C4/H marker checks correctly flag a fixture missing them (review L7) =="
DECOY_C4=$(mktemp "${TMPDIR:-/tmp}/wt-decoy-c4.XXXXXX")
cat > "$DECOY_C4" << 'DECOYEOF'
# decoy prompt file with none of the required markers
Ask the user to confirm removal.
DECOYEOF
C4_MISS=0
grep -qF -- "release --preview" "$DECOY_C4" || C4_MISS=$((C4_MISS + 1))
grep -qF -- "ahead_of_base" "$DECOY_C4" || C4_MISS=$((C4_MISS + 1))
grep -qF -- "ahead_of_upstream" "$DECOY_C4" || C4_MISS=$((C4_MISS + 1))
grep -qF -- "confirm: slug" "$DECOY_C4" || C4_MISS=$((C4_MISS + 1))
grep -qF -- "confirm: yesno" "$DECOY_C4" || C4_MISS=$((C4_MISS + 1))
grep -qE 'Type .* to confirm' "$DECOY_C4" || C4_MISS=$((C4_MISS + 1))
grep -qE 'not\*{0,2}[[:space:]]+confirmation' "$DECOY_C4" || C4_MISS=$((C4_MISS + 1))
assert_eq "T22 negative control: decoy prompt file misses all 7 C4 markers" "$C4_MISS" "7"

DECOY_HIT=$(mktemp "${TMPDIR:-/tmp}/wt-decoy-c4hit.XXXXXX")
cat > "$DECOY_HIT" << 'DECOYHITEOF'
This branch has already been merged.
DECOYHITEOF
if grep -qF -- "has already been merged" "$DECOY_HIT"; then
  PASS=$((PASS + 1)); echo "  ok  T22 negative control: banned-phrase check catches a planted hit"
else
  FAIL=$((FAIL + 1)); echo "  FAIL T22 negative control: banned-phrase check missed a planted hit"
fi
rm -f "$DECOY_C4" "$DECOY_HIT"

DECOY_H=$(mktemp "${TMPDIR:-/tmp}/wt-decoy-h.XXXXXX")
cat > "$DECOY_H" << 'DECOYHEOF'
# decoy docs page with none of the required markers
Release removes the worktree and the branch.
DECOYHEOF
H_MISS=0
grep -qF -- "never force-removes" "$DECOY_H" || H_MISS=$((H_MISS + 1))
grep -qF -- "only when it is merged" "$DECOY_H" || H_MISS=$((H_MISS + 1))
grep -qF -- "typed slug" "$DECOY_H" || H_MISS=$((H_MISS + 1))
assert_eq "T23 negative control: decoy docs page misses all 3 doc markers" "$H_MISS" "3"

DECOY_ROW=$(mktemp "${TMPDIR:-/tmp}/wt-decoy-row.XXXXXX")
cat > "$DECOY_ROW" << 'DECOYROWEOF'
| `release <slug>` | Confirm in chat, then remove lock + worktree if clean |
DECOYROWEOF
if grep -qF -- "| \`release <slug>\` | Confirm in chat, then remove lock + worktree if clean |" "$DECOY_ROW"; then
  PASS=$((PASS + 1)); echo "  ok  T23 negative control: bare-row check catches a planted hit"
else
  FAIL=$((FAIL + 1)); echo "  FAIL T23 negative control: bare-row check missed a planted hit"
fi
rm -f "$DECOY_H" "$DECOY_ROW"

echo "== T28 invalid slug / missing slug rejected (CDT-298 missing tests) =="
IS_OUT=$(run_lib ensure 'bad/slug' 2>"$ERR_TMP"); IS_RC=$?
assert_eq "ensure invalid slug exit 64" "$IS_RC" "64"
assert_eq "ensure invalid slug empty stdout" "$IS_OUT" ""
RS_OUT=$(run_lib release 'bad slug' 2>"$ERR_TMP"); RS_RC=$?
assert_eq "release invalid slug exit 64" "$RS_RC" "64"
assert_eq "release invalid slug empty stdout" "$RS_OUT" ""
NE_OUT=$(run_lib ensure 2>"$ERR_TMP"); NE_RC=$?
assert_eq "ensure missing slug exit 64" "$NE_RC" "64"
assert_eq "ensure missing slug empty stdout" "$NE_OUT" ""

echo "== T29 ensure FRESH collision with no TTY aborts (CDT-298 missing tests) =="
mk_release_fixture coll-slug
printf '%s %s\n' "$NOW" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > .worktrees/coll-slug/.wt-lock
if command -v setsid >/dev/null 2>&1; then
  # setsid: no controlling terminal -> the /dev/tty probe fails -> exit 2.
  NTOUT=$(setsid timeout 30 bash "$LIB" ensure coll-slug 2>"$ERR_TMP"); NT_RC=$?
  assert_eq "no-TTY collision exit 2" "$NT_RC" "2"
  assert_eq "no-TTY collision empty stdout" "$NTOUT" ""
  assert_contains "no-TTY collision names the slug" "$(cat "$ERR_TMP" 2>/dev/null)" "Worktree collision: coll-slug"
  assert_file "no-TTY collision kept the lock" ".worktrees/coll-slug/.wt-lock"
else
  echo "  skip T29 (setsid unavailable)"
fi

echo "== T30 ensure -b starts from the default branch (rv-w3-40) =="
# Main checkout is deliberately parked on an older commit; the new worktree
# branch must still start at the resolved base (origin/master), not at the
# main checkout's HEAD. Sync origin first so the base is the current master
# and therefore differs from the side-base checkout point.
git push -q origin master || die "push master (sync origin, T30) failed"
git checkout -q -b side-base master~1
SIDE_SHA=$(git rev-parse HEAD)
BOUT=$(run_lib ensure base-slug 2>"$ERR_TMP"); B_RC=$?
assert_eq "ensure base-slug exit 0" "$B_RC" "0"
assert_contains "ensure base-slug path" "$BOUT" "$TMP/.worktrees/base-slug"
NEW_SHA=$(git rev-parse refs/heads/feat/base-slug 2>/dev/null || echo "missing")
if [ "$NEW_SHA" = "$SIDE_SHA" ]; then
  FAIL=$((FAIL + 1)); echo "  FAIL ensure -b branched from the main checkout HEAD ($SIDE_SHA), not the default branch"
else
  PASS=$((PASS + 1)); echo "  ok  ensure -b branched from the default branch ($NEW_SHA != side HEAD)"
fi
if [ "$NEW_SHA" = "$(git rev-parse master)" ]; then
  PASS=$((PASS + 1)); echo "  ok  ensure -b start point equals master"
else
  FAIL=$((FAIL + 1)); echo "  FAIL ensure -b start point $NEW_SHA != master $(git rev-parse master)"
fi
git checkout -q master

echo "== T31 git add -A in a worktree does not stage the lock (rv-w3-40) =="
EOUT=$(run_lib ensure excl-slug 2>"$ERR_TMP"); E_RC=$?
assert_eq "ensure excl-slug exit 0" "$E_RC" "0"
printf 'content\n' > .worktrees/excl-slug/stage-me.txt
git -C .worktrees/excl-slug add -A
STAGED=$(git -C .worktrees/excl-slug diff --cached --name-only)
case "$STAGED" in
  *.wt-lock*)
    FAIL=$((FAIL + 1)); echo "  FAIL git add -A staged the lock: $STAGED" ;;
  *)
    PASS=$((PASS + 1)); echo "  ok  git add -A did not stage the lock" ;;
esac
printf '%s' "$STAGED" | grep -qF 'stage-me.txt' \
  && { PASS=$((PASS + 1)); echo "  ok  negative control: a real file did stage"; } \
  || { FAIL=$((FAIL + 1)); echo "  FAIL negative control: stage-me.txt missing from the index"; }

echo "== T32 slug_has_live_task uses slug boundaries, not word boundaries (rv-w3-40) =="
mkdir -p .claude/tasks
# Real worktree so the dirty check is scoped to it (a plain dir would walk up
# to the main repo's status). ensure CDT-1 first, then stamp the lock STALE.
CDOUT=$(run_lib ensure CDT-1 2>"$ERR_TMP"); CD0_RC=$?
assert_eq "ensure CDT-1 create exit 0" "$CD0_RC" "0"
printf '%s %s\n' "$OLD" "2020-01-01T00:00:00Z" > .worktrees/CDT-1/.wt-lock
# Live task for CDT-1-2 only; its text contains "CDT-1" followed by a slug
# char, which the old `grep -wF CDT-1` wrongly counted as CDT-1's own task.
cat > .claude/tasks/CDT-1-2.json << 'JSON'
{"task_id":"CDT-1-2","subject":"child ticket","status":"in_progress","requires_council":false,"depends_on":[],"created_at":"2020-01-01T00:00:00Z","note":"refs CDT-1-2"}
JSON
CDOUT=$(run_lib ensure CDT-1 2>"$ERR_TMP"); CD_RC=$?
assert_eq "ensure CDT-1 reclaims when only CDT-1-2 is live" "$CD_RC" "0"
assert_eq "ensure CDT-1 stdout path" "$CDOUT" "$TMP/.worktrees/CDT-1"
# Negative control: a task that genuinely references CDT-2 (quote boundary)
# must still block the reclaim.
EOUT=$(run_lib ensure CDT-2 2>"$ERR_TMP"); CD2A_RC=$?
assert_eq "ensure CDT-2 create exit 0 (control setup)" "$CD2A_RC" "0"
printf '%s %s\n' "$OLD" "2020-01-01T00:00:00Z" > .worktrees/CDT-2/.wt-lock
cat > .claude/tasks/CDT-2.json << 'JSON'
{"task_id":"CDT-2","subject":"own ticket","status":"in_progress","requires_council":false,"depends_on":[],"created_at":"2020-01-01T00:00:00Z"}
JSON
CD2OUT=$(run_lib ensure CDT-2 2>"$ERR_TMP"); CD2_RC=$?
assert_eq "ensure CDT-2 refuses its own live task (control)" "$CD2_RC" "1"
assert_contains "ensure CDT-2 refusal reason (control)" "$(cat "$ERR_TMP" 2>/dev/null)" "live task"

echo "== T33 git_retry sleep conversion handles ms >= 1000 (rv-w3-40) =="
# Static: the ms->s conversion must keep the carry (1200ms = 1.200s), and the
# old form that turned 1200ms into 0.1200s must be gone.
assert_contains "git_retry divides sleep_ms by 1000" "$LIB_TEXT" 'sleep_ms / 1000'
assert_not_contains "git_retry no 0.<ms> malformed sleep" "$LIB_TEXT" '0.$(printf '"'"'%03d'"'"' "$sleep_ms")'
# Planted negative control: the exact banned substring bites a fixture.
PLANT33='local secs="0.$(printf '"'"'%03d'"'"' "$sleep_ms")"'
printf '%s' "$PLANT33" | grep -qF '0.$(printf' \
  && { PASS=$((PASS + 1)); echo "  ok  T33 negative control: banned old sleep form is detectable"; } \
  || { FAIL=$((FAIL + 1)); echo "  FAIL T33 negative control: banned form not detected"; }

echo
echo "Results: PASS=$PASS FAIL=$FAIL"
if [ "$FAIL" -ne 0 ]; then
  exit 1
fi
exit 0
