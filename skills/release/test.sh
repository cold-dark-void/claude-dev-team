#!/usr/bin/env bash
# SPEC-010 staged-path hard gate harness (CDT-189 AC-9 / S8).
# Isolated temp git repos only — never the live worktree index.
# Run: bash skills/release/test.sh
set -u

HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=../../tests/lib/hermetic.sh
. "$HERE/../../tests/lib/hermetic.sh"
hermetic_init
CHECK="$HERE/check-staged-paths.sh"
INSTALL="$HERE/install-git-hooks.sh"
PASS=0
FAIL=0
OUT=""
RC=0

pass() { PASS=$((PASS + 1)); echo "PASS: $*"; }
fail() { FAIL=$((FAIL + 1)); echo "FAIL: $*"; }

run_in_repo() { # run_in_repo <repo> -- <check-args...>
  local d="$1"; shift
  [ "$1" = "--" ] && shift
  RC=0
  OUT=$(cd "$d" && bash "$CHECK" "$@" 2>&1) && RC=0 || RC=$?
}

run_check() { # run_check <expected_exit> [args...]  — cwd = live tree OK for usage-only
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

expect_contains() { # expect_contains <needle>
  if printf '%s\n' "$OUT" | grep -Fq -- "$1"; then
    pass "output contains: $1"
  else
    fail "output missing: $1"
    echo "  out: $OUT" | head -c 500
    echo
  fi
}

expect_rc() { # expect_rc <want> <label>
  if [ "$RC" -eq "$1" ]; then
    pass "$2 → $1"
  else
    fail "$2 exit $RC != $1: $OUT"
  fi
}

# --- temp git fixture helpers ---
make_repo() {
  local d
  d=$(mktemp -d "${TMPDIR:-/tmp}/release-gate-XXXXXX")
  git -C "$d" init -q
  git -C "$d" config user.email "test@example.com"
  git -C "$d" config user.name "Test"
  git -C "$d" commit -q --allow-empty -m "init"
  printf '%s\n' "$d"
}

stage_pair() {
  local d="$1"
  mkdir -p "$d/.claude-plugin"
  printf '### v0.0.1\n\n- test\n' >"$d/CHANGELOG.md"
  printf '{"name":"t","version":"0.0.1"}\n' >"$d/.claude-plugin/plugin.json"
  git -C "$d" add CHANGELOG.md .claude-plugin/plugin.json
}

stage_file() {
  local d="$1" rel="$2" body="${3:-x}"
  local dir
  dir=$(dirname -- "$rel")
  if [ "$dir" != "." ]; then
    mkdir -p "$d/$dir"
  fi
  printf '%s\n' "$body" >"$d/$rel"
  git -C "$d" add -- "$rel"
}

write_file() {
  local d="$1" rel="$2" body="${3:-x}"
  local dir
  dir=$(dirname -- "$rel")
  if [ "$dir" != "." ]; then
    mkdir -p "$d/$dir"
  fi
  printf '%s\n' "$body" >"$d/$rel"
}

index_snapshot() {
  git -C "$1" diff --cached --name-only | sort
}

# ---------------------------------------------------------------------------
# Usage edges (S1 / S6)
# ---------------------------------------------------------------------------
run_check 64
expect_contains "--intended"

run_check 64 --no-such-flag
expect_contains "unknown flag"

# not a git repo
NOT_GIT=$(mktemp -d "${TMPDIR:-/tmp}/release-gate-nogit-XXXXXX")
RC=0
OUT=$(cd "$NOT_GIT" && bash "$CHECK" --intended foo 2>&1) && RC=0 || RC=$?
expect_rc 64 "not-a-git-repo"
rm -rf "$NOT_GIT"

# ---------------------------------------------------------------------------
# AC-9: pair + allowed path staged → 0
# ---------------------------------------------------------------------------
REPO=$(make_repo)
stage_pair "$REPO"
stage_file "$REPO" "skills/release/SKILL.md" "skill body"
run_in_repo "$REPO" -- --intended skills/release/SKILL.md
expect_rc 0 "pair+allowed"
rm -rf "$REPO"

# ---------------------------------------------------------------------------
# AC-9: pair + foreign path → 1, foreign listed, no index mutation
# ---------------------------------------------------------------------------
REPO=$(make_repo)
stage_pair "$REPO"
stage_file "$REPO" "skills/release/SKILL.md" "skill body"
stage_file "$REPO" "secrets/noise.txt" "leak"
BEFORE=$(index_snapshot "$REPO")
run_in_repo "$REPO" -- --intended skills/release/SKILL.md
expect_rc 1 "pair+foreign"
expect_contains "staged-path hard gate"
expect_contains "secrets/noise.txt"
if printf '%s\n' "$OUT" | grep -Eqi 'MUST NOT proceed|commit/tag/push'; then
  pass "forbids commit/tag/push"
else
  fail "missing no-commit wording in: $OUT"
fi
AFTER=$(index_snapshot "$REPO")
if [ "$BEFORE" = "$AFTER" ]; then
  pass "no index mutation on fail"
else
  fail "index changed: before=[$BEFORE] after=[$AFTER]"
fi
if git -C "$REPO" diff --cached --name-only | grep -Fq -- "secrets/noise.txt"; then
  pass "foreign still staged after fail"
else
  fail "gate unstaged foreign path"
fi
rm -rf "$REPO"

# ---------------------------------------------------------------------------
# AC-9: foreign on --allow-extra → 0
# ---------------------------------------------------------------------------
REPO=$(make_repo)
stage_pair "$REPO"
stage_file "$REPO" "skills/release/SKILL.md" "skill body"
stage_file "$REPO" "docs/extra.md" "extra"
run_in_repo "$REPO" -- --intended skills/release/SKILL.md --allow-extra docs/extra.md
expect_rc 0 "allow-extra admits extra"
rm -rf "$REPO"

# ---------------------------------------------------------------------------
# AC-9: unstaged foreign dirty only → 0 for this gate
# ---------------------------------------------------------------------------
REPO=$(make_repo)
stage_pair "$REPO"
stage_file "$REPO" "skills/release/SKILL.md" "skill body"
write_file "$REPO" "dirty/untracked-or-modified.txt" "not staged"
# dirty worktree on already-staged CHANGELOG (index unchanged)
printf '### v0.0.1\n\n- test\n- dirty worktree\n' >"$REPO/CHANGELOG.md"
run_in_repo "$REPO" -- --intended skills/release/SKILL.md
expect_rc 0 "unstaged dirty ignored"
if [ -n "$(git -C "$REPO" status --porcelain)" ]; then
  pass "worktree still dirty (gate ignored it)"
else
  fail "expected dirty worktree for fixture"
fi
rm -rf "$REPO"

# ---------------------------------------------------------------------------
# Empty staged → 0 (S4)
# ---------------------------------------------------------------------------
REPO=$(make_repo)
run_in_repo "$REPO" -- --intended skills/release/SKILL.md
expect_rc 0 "empty staged"
rm -rf "$REPO"

# ---------------------------------------------------------------------------
# Pair-only (no product intended paths) → 0 when only pair staged
# ---------------------------------------------------------------------------
REPO=$(make_repo)
stage_pair "$REPO"
run_in_repo "$REPO" -- --intended
expect_rc 0 "pair-only --intended (no paths)"
rm -rf "$REPO"

# ---------------------------------------------------------------------------
# -z / space-in-path (SPEC-010 S2/S3): staged path with a space, intended
# matches exactly → 0
# ---------------------------------------------------------------------------
REPO=$(make_repo)
stage_pair "$REPO"
stage_file "$REPO" "docs/a b.md" "space path"
run_in_repo "$REPO" -- --intended "docs/a b.md"
expect_rc 0 "space-in-path intended"
rm -rf "$REPO"

# ---------------------------------------------------------------------------
# -z / core.quotePath (SPEC-010 S2/S3): non-ASCII staged path, intended → 0;
# same path NOT intended → 1 with the raw (unquoted) path in the output
# ---------------------------------------------------------------------------
REPO=$(make_repo)
git -C "$REPO" config core.quotePath true
stage_pair "$REPO"
stage_file "$REPO" "docs/café.md" "accent path"
run_in_repo "$REPO" -- --intended "docs/café.md"
expect_rc 0 "quotePath non-ASCII intended"

REPO2=$(make_repo)
git -C "$REPO2" config core.quotePath true
stage_pair "$REPO2"
stage_file "$REPO2" "docs/café.md" "accent path"
run_in_repo "$REPO2" -- --intended skills/release/SKILL.md
expect_rc 1 "quotePath non-ASCII not intended"
expect_contains "docs/café.md"
rm -rf "$REPO" "$REPO2"

# ---------------------------------------------------------------------------
# ./ normalization (S2): leading ./ on --intended and --allow-extra
# ---------------------------------------------------------------------------
REPO=$(make_repo)
stage_pair "$REPO"
stage_file "$REPO" "skills/x.md" "x body"
run_in_repo "$REPO" -- --intended ./skills/x.md
expect_rc 0 "leading ./ stripped for --intended"
rm -rf "$REPO"

REPO=$(make_repo)
stage_pair "$REPO"
stage_file "$REPO" "skills/x.md" "x body"
stage_file "$REPO" "docs/e.md" "extra"
run_in_repo "$REPO" -- --intended skills/x.md --allow-extra ./docs/e.md
expect_rc 0 "leading ./ stripped for --allow-extra"
rm -rf "$REPO"

# ---------------------------------------------------------------------------
# Renames (CDT-282 [09 F23]): a staged rename from a foreign path into an
# allowed path lists only the new name when git detects renames, so the delete
# of the foreign path would pass the gate. --no-renames lists both paths.
# ---------------------------------------------------------------------------
REPO=$(make_repo)
stage_file "$REPO" "docs/foreign.md" "a file that must not ride along"
git -C "$REPO" commit -q -m "add foreign"
stage_pair "$REPO"
mkdir -p "$REPO/skills/release"
git -C "$REPO" mv docs/foreign.md skills/release/SKILL.md
run_in_repo "$REPO" -- --intended skills/release/SKILL.md
expect_rc 1 "staged rename of a foreign path into an allowed path"
expect_contains "docs/foreign.md"
# control: the same pair and a plain (non-rename) add of the allowed path passes
REPO2=$(make_repo)
stage_pair "$REPO2"
stage_file "$REPO2" "skills/release/SKILL.md" "skill body"
run_in_repo "$REPO2" -- --intended skills/release/SKILL.md
expect_rc 0 "control: plain add of the allowed path"
rm -rf "$REPO" "$REPO2"

# ---------------------------------------------------------------------------
# Static: script source holds --name-only -z (behavioural proof is the
# space/non-ASCII cases above; this guards against a future regression)
# ---------------------------------------------------------------------------
if grep -Fq -- '--name-only -z' "$CHECK"; then
  pass "source holds --name-only -z"
else
  fail "source missing --name-only -z"
fi

# ---------------------------------------------------------------------------
# install-git-hooks.sh (SPEC-010 B4): hooksPath warnings, never touch the
# real repo's git config — temp repos only
# ---------------------------------------------------------------------------
make_hook_repo() {
  local d
  d=$(mktemp -d "${TMPDIR:-/tmp}/release-gate-hooks-XXXXXX")
  git -C "$d" init -q
  git -C "$d" config user.email "test@example.com"
  git -C "$d" config user.name "Test"
  mkdir -p "$d/githooks"
  printf '#!/usr/bin/env bash\nexit 0\n' >"$d/githooks/pre-commit"
  printf '%s\n' "$d"
}

# Plain repo, no prior core.hooksPath, only .sample hooks present → no warning
REPO=$(make_hook_repo)
RC=0
OUT=$(cd "$REPO" && bash "$INSTALL" 2>&1) && RC=0 || RC=$?
expect_rc 0 "install-git-hooks: plain repo"
if printf '%s\n' "$OUT" | grep -q "warning:"; then
  fail "unexpected warning on plain repo: $OUT"
else
  pass "no warning on plain repo"
fi
if [ "$(git -C "$REPO" config --get core.hooksPath)" = "githooks" ]; then
  pass "core.hooksPath=githooks set"
else
  fail "core.hooksPath not set to githooks"
fi
rm -rf "$REPO"

# Executable .git/hooks/pre-push present → warning naming pre-push, still installed
REPO=$(make_hook_repo)
printf '#!/usr/bin/env bash\nexit 0\n' >"$REPO/.git/hooks/pre-push"
chmod +x "$REPO/.git/hooks/pre-push"
RC=0
OUT=$(cd "$REPO" && bash "$INSTALL" 2>&1) && RC=0 || RC=$?
expect_rc 0 "install-git-hooks: legacy pre-push present"
if printf '%s\n' "$OUT" | grep -q "warning:" && printf '%s\n' "$OUT" | grep -q "pre-push"; then
  pass "warning names pre-push"
else
  fail "expected warning naming pre-push: $OUT"
fi
if [ "$(git -C "$REPO" config --get core.hooksPath)" = "githooks" ]; then
  pass "still installed despite legacy hook"
else
  fail "not installed despite legacy hook: $OUT"
fi
rm -rf "$REPO"

# core.hooksPath already set to something else (.husky) → warning naming .husky
REPO=$(make_hook_repo)
git -C "$REPO" config core.hooksPath .husky
RC=0
OUT=$(cd "$REPO" && bash "$INSTALL" 2>&1) && RC=0 || RC=$?
expect_rc 0 "install-git-hooks: prior core.hooksPath=.husky"
if printf '%s\n' "$OUT" | grep -q "warning:" && printf '%s\n' "$OUT" | grep -q ".husky"; then
  pass "warning names .husky"
else
  fail "expected warning naming .husky: $OUT"
fi
if [ "$(git -C "$REPO" config --get core.hooksPath)" = "githooks" ]; then
  pass "installed after prior core.hooksPath"
else
  fail "not installed after prior core.hooksPath: $OUT"
fi
rm -rf "$REPO"

# Re-run with githooks already set and only *.sample hooks → no warning
REPO=$(make_hook_repo)
git -C "$REPO" config core.hooksPath githooks
RC=0
OUT=$(cd "$REPO" && bash "$INSTALL" 2>&1) && RC=0 || RC=$?
expect_rc 0 "install-git-hooks: re-run with githooks already set"
if printf '%s\n' "$OUT" | grep -q "warning:"; then
  fail "unexpected warning on re-run: $OUT"
else
  pass "no warning on re-run with githooks set + samples only"
fi
rm -rf "$REPO"


# ---------------------------------------------------------------------------
# CDT-188 H11: ship-history cleanliness (separate harness, same PASS/FAIL rollup)
# ---------------------------------------------------------------------------
SHIP_HARNESS="$HERE/test-ship-history.sh"
if [ ! -f "$SHIP_HARNESS" ]; then
  fail "missing test-ship-history.sh"
else
  SHIP_OUT=""
  SHIP_RC=0
  SHIP_OUT=$(bash "$SHIP_HARNESS" 2>&1) && SHIP_RC=0 || SHIP_RC=$?
  printf '%s\n' "$SHIP_OUT"
  # Parse child PASS/FAIL counts from last summary line
  SHIP_P=$(printf '%s\n' "$SHIP_OUT" | sed -n 's/.*PASS=\([0-9]*\).*/\1/p' | tail -1)
  SHIP_F=$(printf '%s\n' "$SHIP_OUT" | sed -n 's/.*FAIL=\([0-9]*\).*/\1/p' | tail -1)
  SHIP_P=${SHIP_P:-0}
  SHIP_F=${SHIP_F:-0}
  PASS=$((PASS + SHIP_P))
  FAIL=$((FAIL + SHIP_F))
  if [ "$SHIP_RC" -ne 0 ] && [ "$SHIP_F" -eq 0 ]; then
    fail "test-ship-history.sh exit $SHIP_RC without FAIL count"
  fi
fi

# ---------------------------------------------------------------------------
# T7 static guards (AC A/D/E/C): /release SKILL.md hygiene
# ---------------------------------------------------------------------------
SKILL="$HERE/SKILL.md"
REPO_ROOT=$(CDPATH= cd -- "$HERE/../.." && pwd)
AGENTS_MD="$REPO_ROOT/AGENTS.md"
SKILL_LINT_MD="$REPO_ROOT/skills/skill-lint/SKILL.md"

# S1 (AC A): no push --tags literal in skills/release/ or skills/release-train/
# (non-test, non-fixture); Step 6 calls push-release.sh; no literal 'git push'
# in SKILL.md; push-release.sh source holds --atomic and refs/tags/.
S1_HITS=$(grep -rEn 'push[^|]*--tags' "$HERE" "$REPO_ROOT/skills/release-train" \
  --include='*.sh' --include='*.md' 2>/dev/null |
  grep -Ev '(^|/)(test[^/]*\.sh|[^/]*-test\.sh)(:|$)' |
  grep -Ev '/fixtures/')
if [ -z "$S1_HITS" ]; then
  pass "S1: no push --tags literal outside test/fixtures"
else
  fail "S1: push --tags literal found: $S1_HITS"
fi
if grep -Fq 'push-release.sh' "$SKILL"; then
  pass "S1: SKILL.md names push-release.sh (Step 6)"
else
  fail "S1: SKILL.md does not name push-release.sh"
fi
if grep -Fq 'git push' "$SKILL"; then
  fail "S1: literal 'git push' still in SKILL.md"
else
  pass "S1: no literal 'git push' in SKILL.md"
fi
if grep -Fq -- '--atomic' "$HERE/push-release.sh" && grep -Fq 'refs/tags/' "$HERE/push-release.sh"; then
  pass "S1: push-release.sh source holds --atomic and refs/tags/"
else
  fail "S1: push-release.sh missing --atomic or refs/tags/"
fi
if grep -Fq -- '--no-follow-tags' "$HERE/push-release.sh"; then
  pass "S1: push-release.sh source holds --no-follow-tags"
else
  fail "S1: push-release.sh missing --no-follow-tags"
fi

# S2 (AC D, advisor 4): no cwd-relative bash|python3|sh skills/|tools/ invocation.
S2_HITS=$(grep -nE '(bash|python3|sh)[[:space:]]+(\./)?(skills|tools)/' "$SKILL")
if [ -z "$S2_HITS" ]; then
  pass "S2: no cwd-relative bash/python3/sh skills|tools invocation in SKILL.md"
else
  fail "S2: cwd-relative invocation found: $S2_HITS"
fi

# S3 (AC D): every gate section holds the PDH file-resolve call.
section_body() { # section_body <label>
  awk -v pat="^## Step ${1}:" '
    $0 ~ pat {grab=1; print; next}
    /^## / {if (grab) exit}
    grab {print}
  ' "$SKILL"
}
section_has() { # section_has <label> <needle>
  local body
  body=$(section_body "$1")
  if [ -z "$body" ]; then
    fail "S3: section 'Step $1' not found in SKILL.md"
    return
  fi
  if printf '%s\n' "$body" | grep -Fq -- "$2"; then
    pass "S3: Step $1 holds: $2"
  else
    fail "S3: Step $1 missing: $2"
  fi
}
for s in 0 0.5 0.6 4.5 4.6 4.7 4.8 4.9 4.10 4.11 4.12 4.13 5.5 6; do
  section_has "$s" 'plugin-dir.sh" file'
done

# S4 (AC D drift guard): SKILL.md cites C1-C<max from skill-lint/SKILL.md>,
# and no stale C1-Cn text for any other n.
LINT_MAX=$(grep -oE '^\| C[0-9]+ ' "$SKILL_LINT_MD" | grep -oE '[0-9]+' | sort -n | tail -1)
if [ -z "$LINT_MAX" ]; then
  fail "S4: could not determine skill-lint max class from $SKILL_LINT_MD"
else
  if grep -Fq "C1–C${LINT_MAX}" "$SKILL"; then
    pass "S4: SKILL.md cites C1–C${LINT_MAX}"
  else
    fail "S4: SKILL.md missing C1–C${LINT_MAX}"
  fi
  STALE=$(grep -oE 'C1[–-]C[0-9]+' "$SKILL" | grep -Fxv "C1–C${LINT_MAX}" || true)
  if [ -z "$STALE" ]; then
    pass "S4: no stale C1-Cn drift text in SKILL.md"
  else
    fail "S4: stale C1-Cn text found: $STALE"
  fi
fi

# S5 (AC D): no "optional but preferred" text in SKILL.md.
if grep -Fq 'optional but preferred' "$SKILL"; then
  fail "S5: 'optional but preferred' still in SKILL.md"
else
  pass "S5: no 'optional but preferred' text in SKILL.md"
fi

# S6 (AC E): AGENTS.md bump-rule line quoted verbatim; no stale feat:-forces-
# minor text; no "would choose ... minor" text.
AGENTS_LINE=$(grep '^New opt-in flags with unchanged defaults' "$AGENTS_MD" || true)
if [ -n "$AGENTS_LINE" ] && grep -Fq -- "$AGENTS_LINE" "$SKILL"; then
  pass "S6: AGENTS.md bump-rule line quoted verbatim in SKILL.md"
else
  fail "S6: AGENTS.md bump-rule line not found verbatim in SKILL.md"
fi
if grep -Fq 'feat:`/`feat(`) → **minor**' "$SKILL"; then
  fail "S6: stale feat:-forces-minor text still in SKILL.md"
else
  pass "S6: no feat:-forces-minor text in SKILL.md"
fi
if grep -Eq 'would choose[^.]*minor' "$SKILL"; then
  fail "S6: stale 'would choose ... minor' text still in SKILL.md"
else
  pass "S6: no 'would choose ... minor' text in SKILL.md"
fi

# S7 (AC C): no stale git-describe first-release logic; LAST_TAG present in
# Steps 1 and 2.
if grep -Fq 'git describe --tags --abbrev=0)' "$SKILL"; then
  fail "S7: stale 'git describe --tags --abbrev=0)' still in SKILL.md"
else
  pass "S7: no stale 'git describe --tags --abbrev=0)' in SKILL.md"
fi
section_has "1" 'LAST_TAG'
section_has "2" 'LAST_TAG'

# S8: the three new step scripts are each named in SKILL.md.
for f in step0.sh ship-start.sh push-release.sh; do
  if grep -Fq "$f" "$SKILL"; then
    pass "S8: $f named in SKILL.md"
  else
    fail "S8: $f not named in SKILL.md"
  fi
done

# S9 (review r1 N3): fail-closed --tag-snapshot wording is present, and the
# old unconditional "re-take it" wording (no autopilot/interactive split) is
# gone.
if grep -Fq 'release: tag snapshot missing' "$SKILL" && grep -Fq 'Never silently re-take' "$SKILL"; then
  pass "S9: fail-closed tag-snapshot wording present in SKILL.md"
else
  fail "S9: fail-closed tag-snapshot wording missing from SKILL.md"
fi
if grep -Fq 'A missing/expired `TAG_SNAPSHOT` named in the' "$SKILL"; then
  fail "S9: stale unconditional re-take wording still in SKILL.md"
else
  pass "S9: stale unconditional re-take wording removed from SKILL.md"
fi

# S10 (review r1 N1/N2): Step 6 runs its post-tag check (own fence, not a
# comment) before push, and clears the tag snapshot only after a distinct
# post-push check — never before it.
STEP6_BODY=$(section_body "6")
if [ -z "$STEP6_BODY" ]; then
  fail "S10: section 'Step 6' not found in SKILL.md"
else
  EXPECT_TAG_COUNT=$(printf '%s\n' "$STEP6_BODY" | grep -c -- '--expect-tag')
  if [ "$EXPECT_TAG_COUNT" -ge 2 ]; then
    pass "S10: Step 6 runs --expect-tag at least twice (post-tag + post-push)"
  else
    fail "S10: Step 6 --expect-tag count $EXPECT_TAG_COUNT < 2 (post-tag + post-push)"
  fi
  CLEAR_LINE=$(printf '%s\n' "$STEP6_BODY" | grep -n -- '"\$SHIP_START_SH" --clear' | tail -1 | cut -d: -f1)
  LAST_EXPECT_LINE=$(printf '%s\n' "$STEP6_BODY" | grep -n -- '--expect-tag' | tail -1 | cut -d: -f1)
  if [ -n "$CLEAR_LINE" ] && [ -n "$LAST_EXPECT_LINE" ] && [ "$CLEAR_LINE" -gt "$LAST_EXPECT_LINE" ]; then
    pass "S10: --clear runs after the last --expect-tag check (post-push, not before)"
  else
    fail "S10: --clear (line $CLEAR_LINE) does not run after the last --expect-tag check (line $LAST_EXPECT_LINE)"
  fi
fi

# ---------------------------------------------------------------------------
# S11 (CDT-296 / 10 E9): gen-supported-versions.sh derives SECURITY.md
# ---------------------------------------------------------------------------
GEN="$HERE/gen-supported-versions.sh"
if [ -f "$GEN" ]; then
  pass "S11: gen-supported-versions.sh exists"
  GEN_TMP=$(mktemp -d "${TMPDIR:-/tmp}/gen-sec.XXXXXX")
  trap 'rm -rf "$GEN_TMP"' EXIT
  printf '%s\n' '{"name":"t","version":"1.19.29"}' > "$GEN_TMP/plugin.json"
  OUT1=$(bash "$GEN" 1.19.29)
  echo "$OUT1" | grep -q '| 1.19.x | Yes' && pass "S11: print mode derives current minor" \
    || fail "S11: print mode output: $OUT1"
  echo "$OUT1" | grep -q '| < 1.19 | No' && pass "S11: print mode marks older minors unsupported" \
    || fail "S11: older-minor row missing"
  # plugin.json-derived (compact JSON) — copy into the plugin-layout path so
  # the script's SCRIPT_DIR/../.. root resolves to $GEN_TMP
  mkdir -p "$GEN_TMP/.claude-plugin" "$GEN_TMP/skills/release"
  printf '%s' '{"name":"t","version":"1.19.29"}' > "$GEN_TMP/.claude-plugin/plugin.json"
  cp "$GEN" "$GEN_TMP/skills/release/gen.sh"
  OUT2=$(cd "$GEN_TMP" && bash skills/release/gen.sh)
  echo "$OUT2" | grep -q '1.19.x' && pass "S11: no-arg mode reads plugin.json" \
    || fail "S11: no-arg mode output: $OUT2"
  # --write rewrites only the section
  cat > "$GEN_TMP/SECURITY.md" <<'EOF'
# Security Policy

## Supported Versions

| Version | Supported |
|---------|-----------|
| 1.1.x   | Yes       |
| < 1.1   | No        |

## Reporting a Vulnerability

Email security@example.com.
EOF
  (cd "$GEN_TMP" && SECURITY_MD="$GEN_TMP/SECURITY.md" bash skills/release/gen.sh 1.19.29 --write)
  grep -q '| 1.19.x | Yes' "$GEN_TMP/SECURITY.md" && pass "S11: --write rewrites the table" \
    || fail "S11: --write did not update the table"
  grep -q 'security@example.com' "$GEN_TMP/SECURITY.md" && pass "S11: --write preserves the rest of the file" \
    || fail "S11: --write clobbered the reporting section"
  # a bad argv exits 64
  if bash "$GEN" not-a-version >/dev/null 2>&1; then
    fail "S11: non-semver argv should exit 64"
  else
    rc=$?
    [ "$rc" -eq 64 ] && pass "S11: non-semver argv exits 64" || fail "S11: non-semver argv exit $rc"
  fi
else
  fail "S11: gen-supported-versions.sh missing"
fi

# ---------------------------------------------------------------------------
# S12 (CDT-533 / SPEC-010 H6.2): Step 5 names lead-summary.sh and --check
# before git commit; no hand-written fold summary in the fence.
# ---------------------------------------------------------------------------
STEP5_BODY=$(section_body "5")
if [ -z "$STEP5_BODY" ]; then
  fail "S12: section 'Step 5' not found in SKILL.md"
else
  if printf '%s\n' "$STEP5_BODY" | grep -Fq 'lead-summary.sh'; then
    pass "S12: Step 5 names lead-summary.sh"
  else
    fail "S12: Step 5 missing lead-summary.sh"
  fi
  LS_LINE=$(printf '%s\n' "$STEP5_BODY" | grep -n 'lead-summary.sh' | head -1 | cut -d: -f1)
  CHECK_LINE=$(printf '%s\n' "$STEP5_BODY" | grep -n -- '--check' | head -1 | cut -d: -f1)
  COMMIT_LINE=$(printf '%s\n' "$STEP5_BODY" | grep -n 'git commit -m' | head -1 | cut -d: -f1)
  if [ -n "$CHECK_LINE" ]; then
    pass "S12: Step 5 names --check"
  else
    fail "S12: Step 5 missing --check"
  fi
  if [ -n "$COMMIT_LINE" ]; then
    pass "S12: Step 5 names git commit"
  else
    fail "S12: Step 5 missing git commit command"
  fi
  if [ -n "$LS_LINE" ] && [ -n "$CHECK_LINE" ] && [ -n "$COMMIT_LINE" ] \
    && [ "$LS_LINE" -lt "$COMMIT_LINE" ] && [ "$CHECK_LINE" -lt "$COMMIT_LINE" ]; then
    pass "S12: lead-summary.sh and --check appear before git commit"
  else
    fail "S12: order lead-summary=$LS_LINE --check=$CHECK_LINE git-commit=$COMMIT_LINE"
  fi
  if printf '%s\n' "$STEP5_BODY" | grep -Fq 'one-line summary derived from the changelog lead'; then
    fail "S12: hand-written summary prose still in Step 5 fence"
  else
    pass "S12: no hand-written changelog-lead summary in Step 5"
  fi
fi

# ---------------------------------------------------------------------------
echo
echo "PASS=$PASS FAIL=$FAIL"
if [ "$FAIL" -ne 0 ]; then
  exit 1
fi
exit 0
