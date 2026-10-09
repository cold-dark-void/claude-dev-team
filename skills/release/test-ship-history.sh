#!/usr/bin/env bash
# SPEC-010 ship-history cleanliness gate harness (CDT-188 H11).
# Isolated temp git repos only — never the live worktree.
# Run: bash skills/release/test-ship-history.sh
# Also invoked from skills/release/test.sh.
set -u

HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
CHECK="$HERE/check-ship-history.sh"
LEAD="$HERE/lead-summary.sh"
# shellcheck source=../../tests/lib/hermetic.sh
. "$HERE/../../tests/lib/hermetic.sh"
hermetic_init
PASS=0
FAIL=0
OUT=""
RC=0

pass() { PASS=$((PASS + 1)); echo "PASS: $*"; }
fail() { FAIL=$((FAIL + 1)); echo "FAIL: $*"; }

run_tool() { # run_tool <script> <repo> [--] [args...]
  local script="$1" d="$2"
  [ $# -ge 2 ] || return 64
  shift 2
  [ "${1:-}" = "--" ] && shift
  RC=0
  OUT=$(cd "$d" && bash "$script" "$@" 2>&1) && RC=0 || RC=$?
}

run_in_repo() { # run_in_repo <repo> -- <check-args...>
  run_tool "$CHECK" "$@"
}

run_lead() { # run_lead <repo> -- <args...>
  run_tool "$LEAD" "$@"
}

run_check() { # run_check <expected_exit> [args...]  — usage-only OK outside repo
  local want="$1"; shift
  RC=0
  OUT=$(bash "$CHECK" "$@" 2>&1) && RC=0 || RC=$?
  if [ "$RC" -eq "$want" ]; then
    pass "exit $want (${*:-no-args})"
  else
    fail "exit $RC != $want for: ${*:-no-args}"
    echo "  out: $OUT" | head -c 500
    echo
  fi
}

expect_contains() {
  if printf '%s\n' "$OUT" | grep -Fq -- "$1"; then
    pass "output contains: $1"
  else
    fail "output missing: $1"
    echo "  out: $OUT" | head -c 800
    echo
  fi
}

expect_rc() {
  if [ "$RC" -eq "$1" ]; then
    pass "$2 → $1"
  else
    fail "$2 exit $RC != $1: $OUT"
  fi
}

# --- temp git fixture helpers ---
make_repo() {
  local d
  d=$(mktemp -d "${TMPDIR:-/tmp}/ship-hist-XXXXXX")
  git -C "$d" init -q
  git -C "$d" config user.email "test@example.com"
  git -C "$d" config user.name "Test"
  # avoid GPG / commit.gpgsign noise
  git -C "$d" config commit.gpgsign false
  git -C "$d" commit -q --allow-empty -m "init"
  printf '%s\n' "$d"
}

commit_all() {
  local d="$1" msg="$2"
  git -C "$d" add -A
  # allow-empty so identical trees still create a distinct commit (D1 fixtures)
  git -C "$d" commit -q --allow-empty -m "$msg"
}

tag_at_head() {
  local d="$1" name="$2"
  git -C "$d" tag "$name"
}

head_sha() {
  git -C "$1" rev-parse HEAD
}

# ---------------------------------------------------------------------------
# Usage edges (H2 / H1 exit 64)
# ---------------------------------------------------------------------------
run_check 64
expect_contains "--since"

run_check 64 --no-such-flag
expect_contains "unknown flag"

run_check 64 --since
expect_contains "--since"

# not a git repo
NOT_GIT=$(mktemp -d "${TMPDIR:-/tmp}/ship-hist-nogit-XXXXXX")
RC=0
OUT=$(cd "$NOT_GIT" && bash "$CHECK" --since deadbeef 2>&1) && RC=0 || RC=$?
expect_rc 64 "not-a-git-repo"
rm -rf "$NOT_GIT"

# unresolvable --since inside a real repo
REPO=$(make_repo)
run_in_repo "$REPO" -- --since not-a-real-sha-zzzz
expect_rc 64 "unresolvable --since"
rm -rf "$REPO"

# ---------------------------------------------------------------------------
# Clean 1 tag / 1 fold → 0 (H11)
# ---------------------------------------------------------------------------
REPO=$(make_repo)
SHIP_START=$(head_sha "$REPO")
write_changelog_section "$REPO" "0.1.0" "one fold feature"
commit_all "$REPO" "feat: v0.1.0 — one fold feature"
tag_at_head "$REPO" "v0.1.0"
run_in_repo "$REPO" -- --since "$SHIP_START"
expect_rc 0 "clean 1:1"
expect_contains "clean"
rm -rf "$REPO"

# ---------------------------------------------------------------------------
# Train-shaped: two tags each with one commit → 0 (H11 / AC-4)
# ---------------------------------------------------------------------------
REPO=$(make_repo)
SHIP_START=$(head_sha "$REPO")
write_changelog_section "$REPO" "0.2.0" "train first"
# train keeps both sections — write multi-section changelog at each step
cat >"$REPO/CHANGELOG.md" <<'EOF'
# Changelog

### v0.2.0
- **train first** — a
EOF
commit_all "$REPO" "feat: v0.2.0 — train first"
tag_at_head "$REPO" "v0.2.0"
cat >"$REPO/CHANGELOG.md" <<'EOF'
# Changelog

### v0.2.1
- **train second** — b

### v0.2.0
- **train first** — a
EOF
commit_all "$REPO" "fix: v0.2.1 — train second"
tag_at_head "$REPO" "v0.2.1"
run_in_repo "$REPO" -- --since "$SHIP_START"
expect_rc 0 "train 2 tags × 1 commit"
expect_contains "clean"
rm -rf "$REPO"

# ---------------------------------------------------------------------------
# D1 multi-commit under one tag → 1 + banner (H11)
# ---------------------------------------------------------------------------
REPO=$(make_repo)
SHIP_START=$(head_sha "$REPO")
# two non-merge commits before tag (delivery + fold)
printf 'work\n' >"$REPO/work.txt"
commit_all "$REPO" "feat: delivery work for 0.3.0"
write_changelog_section "$REPO" "0.3.0" "multi commit feature"
commit_all "$REPO" "feat: v0.3.0 — multi commit feature"
tag_at_head "$REPO" "v0.3.0"
# sanity: must be 2 commits in window
_cnt=$(git -C "$REPO" rev-list --count --no-merges "${SHIP_START}..HEAD")
if [ "$_cnt" -ne 2 ]; then
  fail "D1 fixture setup: expected 2 commits got $_cnt"
fi
run_in_repo "$REPO" -- --since "$SHIP_START"
expect_rc 1 "D1 multi-commit"
expect_contains "history dirty — rewrite needed"
expect_contains "D1:"
rm -rf "$REPO"

# ---------------------------------------------------------------------------
# D2 subject ≠ CHANGELOG lead → 1 (H11)
# ---------------------------------------------------------------------------
REPO=$(make_repo)
SHIP_START=$(head_sha "$REPO")
write_changelog_section "$REPO" "0.4.0" "correct lead text"
commit_all "$REPO" "feat: v0.4.0 — wrong summary here"
tag_at_head "$REPO" "v0.4.0"
run_in_repo "$REPO" -- --since "$SHIP_START"
expect_rc 1 "D2 subject mismatch"
expect_contains "history dirty — rewrite needed"
expect_contains "D2:"
rm -rf "$REPO"

# ---------------------------------------------------------------------------
# D3 fixup / WIP → 1 (H11)
# ---------------------------------------------------------------------------
REPO=$(make_repo)
SHIP_START=$(head_sha "$REPO")
write_changelog_section "$REPO" "0.5.0" "with fixup noise"
commit_all "$REPO" "feat: v0.5.0 — with fixup noise"
tag_at_head "$REPO" "v0.5.0"
# repair-class commit after tag still in W (SINCE..HEAD)
git -C "$REPO" commit -q --allow-empty -m "fixup! leftover"
run_in_repo "$REPO" -- --since "$SHIP_START"
expect_rc 1 "D3 fixup"
expect_contains "history dirty — rewrite needed"
expect_contains "D3:"
rm -rf "$REPO"

# WIP without tags still dirty (commits in W)
REPO=$(make_repo)
SHIP_START=$(head_sha "$REPO")
git -C "$REPO" commit -q --allow-empty -m "WIP experimental"
run_in_repo "$REPO" -- --since "$SHIP_START"
expect_rc 1 "D3 WIP no tags"
expect_contains "D3:"
rm -rf "$REPO"

# Double release-shaped for same tagged version
REPO=$(make_repo)
SHIP_START=$(head_sha "$REPO")
write_changelog_section "$REPO" "0.5.1" "double fold hazard"
commit_all "$REPO" "feat: v0.5.1 — double fold hazard"
# second release-shaped before tag (interactive double-commit)
git -C "$REPO" commit -q --allow-empty -m "fix: v0.5.1 — double fold hazard"
tag_at_head "$REPO" "v0.5.1"
run_in_repo "$REPO" -- --since "$SHIP_START"
expect_rc 1 "D3 double release-shaped"
# D1 and/or D3 should fire
if printf '%s\n' "$OUT" | grep -Eq 'D1:|D3:'; then
  pass "D1 or D3 on double release-shaped"
else
  fail "expected D1 or D3 on double release-shaped: $OUT"
fi
rm -rf "$REPO"

# ---------------------------------------------------------------------------
# D4 mismatched --expect-tag → 1 (H11)
# ---------------------------------------------------------------------------
REPO=$(make_repo)
SHIP_START=$(head_sha "$REPO")
write_changelog_section "$REPO" "0.6.0" "expect tag case"
commit_all "$REPO" "feat: v0.6.0 — expect tag case"
tag_at_head "$REPO" "v0.6.0"
REAL=$(head_sha "$REPO")
# fabricate a different expected SHA (the ship-start commit)
run_in_repo "$REPO" -- --since "$SHIP_START" --expect-tag "v0.6.0=${SHIP_START}"
expect_rc 1 "D4 expect-tag mismatch"
expect_contains "history dirty — rewrite needed"
expect_contains "D4:"
# matching expect-tag → clean
run_in_repo "$REPO" -- --since "$SHIP_START" --expect-tag "v0.6.0=${REAL}"
expect_rc 0 "D4 expect-tag match"
rm -rf "$REPO"

# ---------------------------------------------------------------------------
# D4(c) --expect-tag for a branch with no tag of that name -> not a
# finding. A same-named branch (no refs/tags/<name>) MUST NOT be mistaken
# for the expected tag; resolving must stay under refs/tags/, never fall
# through git's ref disambiguation to refs/heads/<name>.
# ---------------------------------------------------------------------------
REPO=$(make_repo)
SHIP_START=$(head_sha "$REPO")
git -C "$REPO" branch v9.9.9
run_in_repo "$REPO" -- --since "$SHIP_START" --expect-tag "v9.9.9=${SHIP_START}"
expect_rc 0 "expect-tag for a branch with no matching tag is not a D4 finding"
if printf '%s\n' "$OUT" | grep -Fq "D4:"; then
  fail "unexpected D4 finding for a same-named branch with no tag: $OUT"
else
  pass "no D4 finding for a same-named branch with no tag"
fi
rm -rf "$REPO"

# ---------------------------------------------------------------------------
# Empty W (no tags, no repair) → 0
# ---------------------------------------------------------------------------
REPO=$(make_repo)
SHIP_START=$(head_sha "$REPO")
git -C "$REPO" commit -q --allow-empty -m "chore: unrelated work"
run_in_repo "$REPO" -- --since "$SHIP_START"
expect_rc 0 "empty W no tags clean"
rm -rf "$REPO"

# ---------------------------------------------------------------------------
# No ref mutation on dirty (H3/H12): tags/commits unchanged
# ---------------------------------------------------------------------------
REPO=$(make_repo)
SHIP_START=$(head_sha "$REPO")
write_changelog_section "$REPO" "0.7.0" "mutation probe"
commit_all "$REPO" "feat: delivery"
write_changelog_section "$REPO" "0.7.0" "mutation probe"
commit_all "$REPO" "feat: v0.7.0 — mutation probe"
tag_at_head "$REPO" "v0.7.0"
BEFORE_TAG=$(git -C "$REPO" rev-parse "v0.7.0")
BEFORE_HEAD=$(head_sha "$REPO")
BEFORE_LOG=$(git -C "$REPO" rev-list --count HEAD)
run_in_repo "$REPO" -- --since "$SHIP_START"
expect_rc 1 "mutation probe dirty"
AFTER_TAG=$(git -C "$REPO" rev-parse "v0.7.0")
AFTER_HEAD=$(head_sha "$REPO")
AFTER_LOG=$(git -C "$REPO" rev-list --count HEAD)
if [ "$BEFORE_TAG" = "$AFTER_TAG" ] && [ "$BEFORE_HEAD" = "$AFTER_HEAD" ] && [ "$BEFORE_LOG" = "$AFTER_LOG" ]; then
  pass "no ref mutation on dirty"
else
  fail "refs changed: tag $BEFORE_TAG→$AFTER_TAG head $BEFORE_HEAD→$AFTER_HEAD count $BEFORE_LOG→$AFTER_LOG"
fi
rm -rf "$REPO"

# ---------------------------------------------------------------------------
# Script source MUST NOT contain ref-mutating git write verbs (static)
# ---------------------------------------------------------------------------
if grep -Eiq '(^|[^[:alnum:]_-])(git[[:space:]]+(commit|tag|push|rebase|reset|branch[[:space:]]+-D)|git[[:space:]]+tag[[:space:]]+-d)' \
  "$CHECK"; then
  # allow only in comments / usage strings — re-check non-comment lines
  if grep -Ev '^[[:space:]]*#' "$CHECK" | grep -Ev 'usage|Usage|Does not|MUST NOT|no ref' \
    | grep -Eiq 'git[[:space:]]+(commit|push|rebase|reset)\b|git[[:space:]]+tag[[:space:]]' \
    ; then
    fail "check-ship-history.sh appears to mutate refs"
  else
    pass "no git write ops in checker (comments only)"
  fi
else
  pass "no git write ops in checker"
fi

# ---------------------------------------------------------------------------
# Default git config guard (SPEC-010 D4): tags have no reflog under the
# default core.logAllRefUpdates. hermetic_init isolates HOME so this must
# hold; assert it explicitly since the D4 snapshot fixtures below depend on
# the checker never consulting a tag reflog.
# ---------------------------------------------------------------------------
_lar=$(git config --get core.logAllRefUpdates 2>/dev/null || true)
if [ "$_lar" = "always" ]; then
  fail "test environment has core.logAllRefUpdates=always — D4 snapshot fixtures require default config"
else
  pass "default git config: core.logAllRefUpdates != always (got: ${_lar:-<unset>})"
fi

# ---------------------------------------------------------------------------
# D4 snapshot half (SPEC-010 H2/D4(b)): --tag-snapshot FILE
# ---------------------------------------------------------------------------
REPO=$(make_repo)
SHIP_START=$(head_sha "$REPO")
write_changelog_section "$REPO" "0.9.0" "snapshot retarget"
commit_all "$REPO" "feat: v0.9.0 — snapshot retarget"
tag_at_head "$REPO" "v0.9.0"
ORIG=$(head_sha "$REPO")
SNAP=$(mktemp "${TMPDIR:-/tmp}/ship-hist-snap-XXXXXX.tsv")
printf 'refs/tags/v0.9.0\t%s\n' "$ORIG" >"$SNAP"
# retarget the tag back to ship-start (also drops it out of W, isolating D4)
git -C "$REPO" tag -f v0.9.0 "$SHIP_START" >/dev/null 2>&1
run_in_repo "$REPO" -- --since "$SHIP_START" --tag-snapshot "$SNAP"
expect_rc 1 "D4 tag-snapshot retarget"
expect_contains "D4:"
expect_contains "tag snapshot"
# same repo, no --tag-snapshot → no D4 snapshot finding at all
run_in_repo "$REPO" -- --since "$SHIP_START"
if printf '%s\n' "$OUT" | grep -Fq "tag snapshot"; then
  fail "unexpected tag-snapshot finding without --tag-snapshot: $OUT"
else
  pass "no D4 snapshot finding without --tag-snapshot flag"
fi
rm -rf "$REPO" "$SNAP"

# Snapshot unchanged → 0
REPO=$(make_repo)
SHIP_START=$(head_sha "$REPO")
write_changelog_section "$REPO" "0.9.1" "snapshot unchanged"
commit_all "$REPO" "feat: v0.9.1 — snapshot unchanged"
tag_at_head "$REPO" "v0.9.1"
ORIG=$(head_sha "$REPO")
SNAP=$(mktemp "${TMPDIR:-/tmp}/ship-hist-snap-XXXXXX.tsv")
printf 'refs/tags/v0.9.1\t%s\n' "$ORIG" >"$SNAP"
run_in_repo "$REPO" -- --since "$SHIP_START" --tag-snapshot "$SNAP"
expect_rc 0 "D4 tag-snapshot unchanged"
rm -rf "$REPO" "$SNAP"

# Deleted tag in snapshot → no D4 (D4(b): deleted tag is not a finding)
REPO=$(make_repo)
SHIP_START=$(head_sha "$REPO")
write_changelog_section "$REPO" "0.9.2" "snapshot deleted tag"
commit_all "$REPO" "feat: v0.9.2 — snapshot deleted tag"
tag_at_head "$REPO" "v0.9.2"
ORIG=$(head_sha "$REPO")
SNAP=$(mktemp "${TMPDIR:-/tmp}/ship-hist-snap-XXXXXX.tsv")
printf 'refs/tags/v0.9.2\t%s\n' "$ORIG" >"$SNAP"
git -C "$REPO" tag -d v0.9.2 >/dev/null
run_in_repo "$REPO" -- --since "$SHIP_START" --tag-snapshot "$SNAP"
expect_rc 0 "deleted tag in snapshot is not a D4 finding"
rm -rf "$REPO" "$SNAP"

# Missing --tag-snapshot FILE → 64
run_check 64 --since deadbeefdeadbeefdeadbeefdeadbeefdeadbeef \
  --tag-snapshot /no/such/file/zzz-ship-history-missing
expect_contains "unreadable --tag-snapshot"

# ---------------------------------------------------------------------------
# ship-start.sh --list failure fails closed → 64, not a silent empty table
# (review r2 note 1: process-substitution exit status was discarded before)
# ---------------------------------------------------------------------------
REPO=$(make_repo)
SHIP_START=$(head_sha "$REPO")
write_changelog_section "$REPO" "0.9.3" "list failure fixture"
commit_all "$REPO" "feat: v0.9.3 — list failure fixture"
tag_at_head "$REPO" "v0.9.3"
REAL_GIT=$(command -v git)
SHIM_DIR=$(mktemp -d "${TMPDIR:-/tmp}/ship-hist-listfail-XXXXXX")
cat >"$SHIM_DIR/git" <<SHIMEOF
#!/usr/bin/env bash
case " \$* " in
  *" for-each-ref "*) echo "git: shim failure" >&2; exit 1 ;;
esac
exec "$REAL_GIT" "\$@"
SHIMEOF
chmod +x "$SHIM_DIR/git"
RC=0
OUT=$(cd "$REPO" && PATH="$SHIM_DIR:$PATH" bash "$CHECK" --since "$SHIP_START" 2>&1) && RC=0 || RC=$?
expect_rc 64 "ship-start.sh --list failure fails closed"
expect_contains "tag list failed"
rm -rf "$REPO" "$SHIM_DIR"

# ---------------------------------------------------------------------------
# R2 full refnames: a same-named branch has no effect on D1/D4
# ---------------------------------------------------------------------------
# (a) a D1-dirty fixture with a same-named branch stays dirty
REPO=$(make_repo)
SHIP_START=$(head_sha "$REPO")
printf 'work\n' >"$REPO/work.txt"
commit_all "$REPO" "feat: delivery work for 0.8.0"
write_changelog_section "$REPO" "0.8.0" "branch collision dirty"
commit_all "$REPO" "feat: v0.8.0 — branch collision dirty"
tag_at_head "$REPO" "v0.8.0"
git -C "$REPO" branch v0.8.0
run_in_repo "$REPO" -- --since "$SHIP_START"
expect_rc 1 "D1-dirty fixture stays dirty despite same-named branch (R2)"
expect_contains "D1:"
rm -rf "$REPO"

# (b) a clean fixture with an extra unrelated branch stays clean
REPO=$(make_repo)
SHIP_START=$(head_sha "$REPO")
write_changelog_section "$REPO" "0.8.1" "clean with extra branch"
commit_all "$REPO" "feat: v0.8.1 — clean with extra branch"
tag_at_head "$REPO" "v0.8.1"
git -C "$REPO" branch v9.9.9
run_in_repo "$REPO" -- --since "$SHIP_START"
expect_rc 0 "clean fixture unaffected by unrelated branch v9.9.9 (R2)"
rm -rf "$REPO"

# (c) D4 remote half: refs/remotes/origin/<name> (branch namespace) is
# dropped — only refs/remotes/origin/tags/<name> counts (R2)
REPO=$(make_repo)
SHIP_START=$(head_sha "$REPO")
write_changelog_section "$REPO" "0.8.2" "remote branch ns ignored"
commit_all "$REPO" "feat: v0.8.2 — remote branch ns ignored"
tag_at_head "$REPO" "v0.8.2"
git -C "$REPO" remote add origin "file://${REPO}/not-a-real-remote.git"
git -C "$REPO" update-ref refs/remotes/origin/v0.8.2 "$SHIP_START"
run_in_repo "$REPO" -- --since "$SHIP_START"
expect_rc 0 "refs/remotes/origin/<name> branch namespace ignored for D4 (R2)"
rm -rf "$REPO"

# (d) D4(a) remote half — POSITIVE bite: refs/remotes/origin/tags/<name>
# at a different commit than the local tag fires (the (a)/(b)/(c) cases
# above only prove the checker ignores what it must ignore; this proves
# the real remote-tracking-tag compare still fires when it should).
REPO=$(make_repo)
SHIP_START=$(head_sha "$REPO")
write_changelog_section "$REPO" "0.8.3" "remote tag retarget positive"
commit_all "$REPO" "feat: v0.8.3 — remote tag retarget positive"
tag_at_head "$REPO" "v0.8.3"
git -C "$REPO" remote add origin "file://${REPO}/not-a-real-remote.git"
git -C "$REPO" update-ref refs/remotes/origin/tags/v0.8.3 "$SHIP_START"
run_in_repo "$REPO" -- --since "$SHIP_START"
expect_rc 1 "D4(a) remote-tracking tag retarget fires (positive)"
expect_contains "D4:"
expect_contains "refs/remotes/origin/tags/v0.8.3"
rm -rf "$REPO"

# ---------------------------------------------------------------------------
# CDT-533 / SPEC-010 R4: lead-summary.sh SoT + CLI
# ---------------------------------------------------------------------------
if [ ! -f "$LEAD" ]; then
  fail "lead-summary.sh missing"
else
  pass "lead-summary.sh exists"
fi

# SoT: checker has no local normalizer; invokes sibling helper (AC E)
if grep -E '(^|[[:space:]])normalize_lead[[:space:]]*\(' "$CHECK" >/dev/null; then
  fail "check-ship-history.sh still defines normalize_lead"
else
  pass "no local normalize_lead in check-ship-history.sh"
fi
if grep -E '(^|[[:space:]])changelog_lead_for[[:space:]]*\(' "$CHECK" >/dev/null; then
  fail "check-ship-history.sh still defines changelog_lead_for"
else
  pass "no local changelog_lead_for in check-ship-history.sh"
fi
if grep -Fq 'lead-summary.sh' "$CHECK"; then
  pass "check-ship-history.sh invokes lead-summary.sh"
else
  fail "check-ship-history.sh does not name lead-summary.sh"
fi
if grep -Fq -- '--from-commit' "$CHECK"; then
  pass "check-ship-history.sh uses --from-commit"
else
  fail "check-ship-history.sh missing --from-commit"
fi

# VERSION prints D2-normalized lead (AC A)
REPO=$(make_repo)
write_changelog_section "$REPO" "1.2.3" "bold lead text"
run_lead "$REPO" -- 1.2.3
expect_rc 0 "lead-summary VERSION"
if [ "$OUT" = "bold lead text" ]; then
  pass "VERSION prints normalized lead"
else
  fail "VERSION lead mismatch: [$OUT]"
fi
run_lead "$REPO" -- v1.2.3
expect_rc 0 "lead-summary vVERSION"
if [ "$OUT" = "bold lead text" ]; then
  pass "vVERSION matches ### vX.Y.Z"
else
  fail "vVERSION lead mismatch: [$OUT]"
fi

# heading without v
cat >"$REPO/CHANGELOG.md" <<'EOF'
# Changelog

### 1.2.4
- plain lead — trailing detail
EOF
run_lead "$REPO" -- 1.2.4
expect_rc 0 "heading without v"
if [ "$OUT" = "plain lead" ]; then
  pass "strips trailing em-dash detail"
else
  fail "em-dash strip failed: [$OUT]"
fi

# missing section → 1
run_lead "$REPO" -- 9.9.9
expect_rc 1 "missing CHANGELOG section"

# empty section → 1
cat >"$REPO/CHANGELOG.md" <<'EOF'
# Changelog

### v2.0.0

### v1.0.0
- **old** — x
EOF
run_lead "$REPO" -- 2.0.0
expect_rc 1 "empty CHANGELOG section"

# bad argv → 64
run_lead "$REPO" --
expect_rc 64 "lead-summary no VERSION"
run_lead "$REPO" -- --nope 1.0.0
expect_rc 64 "lead-summary unknown flag"
run_lead "$REPO" -- not-a-ver
expect_rc 64 "lead-summary bad VERSION"

# --changelog PATH override
printf '%s\n' "# Changelog

### v3.0.0
- **alt path lead** — d
" >"$REPO/ALT.md"
run_lead "$REPO" -- --changelog ALT.md 3.0.0
expect_rc 0 "--changelog PATH"
if [ "$OUT" = "alt path lead" ]; then
  pass "--changelog reads override path"
else
  fail "--changelog lead mismatch: [$OUT]"
fi

# --cached reads index, not worktree
write_changelog_section "$REPO" "4.0.0" "committed lead"
git -C "$REPO" add CHANGELOG.md
git -C "$REPO" commit -q -m "cl committed"
write_changelog_section "$REPO" "4.0.0" "staged lead"
git -C "$REPO" add CHANGELOG.md
write_changelog_section "$REPO" "4.0.0" "worktree lead"
run_lead "$REPO" -- --cached 4.0.0
expect_rc 0 "--cached"
if [ "$OUT" = "staged lead" ]; then
  pass "--cached reads index CHANGELOG"
else
  fail "--cached got [$OUT] want [staged lead]"
fi

# --from-commit reads that commit's tree
write_changelog_section "$REPO" "5.0.0" "at first"
git -C "$REPO" add CHANGELOG.md
git -C "$REPO" commit -q -m "first cl"
FIRST=$(head_sha "$REPO")
write_changelog_section "$REPO" "5.0.0" "at second"
git -C "$REPO" add CHANGELOG.md
git -C "$REPO" commit -q -m "second cl"
run_lead "$REPO" -- --from-commit "$FIRST" 5.0.0
expect_rc 0 "--from-commit"
if [ "$OUT" = "at first" ]; then
  pass "--from-commit reads that commit"
else
  fail "--from-commit got [$OUT] want [at first]"
fi
rm -rf "$REPO"

# --check match → 0; mismatch → 1 + D2: + expected subject (AC B)
REPO=$(make_repo)
write_changelog_section "$REPO" "6.0.0" "exact lead"
run_lead "$REPO" -- --check 6.0.0 "feat: v6.0.0 — exact lead"
expect_rc 0 "--check match"
run_lead "$REPO" -- --check 6.0.0 "feat: v6.0.0 — wrong summary"
expect_rc 1 "--check mismatch"
expect_contains "D2:"
expect_contains "feat: v6.0.0 — exact lead"
# unknown prefix → expected uses fix:
run_lead "$REPO" -- --check 6.0.0 "chore: v6.0.0 — exact lead"
expect_rc 1 "--check unknown prefix"
expect_contains "fix: v6.0.0 — exact lead"
# --check does not mutate index/refs
BEFORE_HEAD=$(head_sha "$REPO")
BEFORE_INDEX=$(git -C "$REPO" diff --cached --name-only | sort)
write_changelog_section "$REPO" "6.0.0" "exact lead"
git -C "$REPO" add CHANGELOG.md
STAGED_INDEX=$(git -C "$REPO" diff --cached --name-only | sort)
run_lead "$REPO" -- --check --cached 6.0.0 "feat: v6.0.0 — wrong"
AFTER_HEAD=$(head_sha "$REPO")
AFTER_INDEX=$(git -C "$REPO" diff --cached --name-only | sort)
if [ "$BEFORE_HEAD" = "$AFTER_HEAD" ] && [ "$STAGED_INDEX" = "$AFTER_INDEX" ]; then
  pass "--check does not mutate index or refs"
else
  fail "--check mutated refs/index: head $BEFORE_HEAD→$AFTER_HEAD index [$STAGED_INDEX]→[$AFTER_INDEX]"
fi
rm -rf "$REPO"

# --cached / --from-commit need a git repo → 64
NOT_GIT=$(mktemp -d "${TMPDIR:-/tmp}/ship-hist-nogit-XXXXXX")
RC=0
OUT=$(cd "$NOT_GIT" && bash "$LEAD" --cached 1.0.0 2>&1) && RC=0 || RC=$?
expect_rc 64 "--cached outside git repo"
rm -rf "$NOT_GIT"

# ---------------------------------------------------------------------------
# plan DD6 linear prev lookup: O(T) git calls, not O(T^2) (bite in plan verify)
# ---------------------------------------------------------------------------
SHIP_HISTORY_T="${SHIP_HISTORY_T:-200}"
REPO=$(make_repo)
SHIP_START=$(head_sha "$REPO")
_i=1
while [ "$_i" -le "$SHIP_HISTORY_T" ]; do
  printf '%s\n' "$_i" >"$REPO/n.txt"
  git -C "$REPO" add -A
  git -C "$REPO" commit -q -m "fix: v0.0.$_i — x"
  git -C "$REPO" tag "v0.0.$_i"
  _i=$((_i + 1))
done

REAL_GIT=$(command -v git)
SHIM_DIR=$(mktemp -d "${TMPDIR:-/tmp}/ship-hist-shim-XXXXXX")
COUNT_FILE=$(mktemp "${TMPDIR:-/tmp}/ship-hist-count-XXXXXX")
: >"$COUNT_FILE"
cat >"$SHIM_DIR/git" <<SHIMEOF
#!/usr/bin/env bash
echo 1 >> "$COUNT_FILE"
exec "$REAL_GIT" "\$@"
SHIMEOF
chmod +x "$SHIM_DIR/git"

RC=0
OUT=$(cd "$REPO" && PATH="$SHIM_DIR:$PATH" bash "$CHECK" --since "$SHIP_START" 2>&1) && RC=0 || RC=$?
CALLS=$(wc -l <"$COUNT_FILE" | tr -d '[:space:]')
BUDGET=$((15 * SHIP_HISTORY_T + 50))
if [ "$CALLS" -le "$BUDGET" ]; then
  pass "linear prev lookup: $CALLS git calls <= budget $BUDGET for T=$SHIP_HISTORY_T"
else
  fail "linear prev lookup exceeded budget: $CALLS calls > $BUDGET for T=$SHIP_HISTORY_T (O(T^2) regression?)"
fi
rm -rf "$REPO" "$SHIM_DIR" "$COUNT_FILE"

# ---------------------------------------------------------------------------
echo
echo "ship-history PASS=$PASS FAIL=$FAIL"
if [ "$FAIL" -ne 0 ]; then
  exit 1
fi
exit 0
