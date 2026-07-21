#!/usr/bin/env bash
# SPEC-030 smoke-harness bite-test. Run: bash tools/smoke/test.sh
#
# Proves the gate BITES: each broken fixture -> exit 1 with a FAIL line naming
# the right reason; clean inputs -> exit 0; live no-arg run -> exit 0; the
# `bash template` opt-out is not a hole (syntax skipped, frontmatter still
# enforced); usage errors -> exit 64; and no-arg output is deterministic.
#
# Static bite-test only: it invokes the harness, never the discovered bodies.
# All temp material lives under mktemp -d and is removed on EXIT. No git
# checkout is used to revert anything (the suite writes only under TMP).
set -u

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
RUN="$HERE/run.sh"
FIX="$HERE/fixtures"
REPO_ROOT=$(cd "$HERE/../.." && pwd)

PASS=0
FAIL=0
OUT=""
RC=0

TMP=$(mktemp -d "${TMPDIR:-/tmp}/smoke-test.XXXXXX")
trap 'rm -rf "$TMP"' EXIT

pass() { PASS=$((PASS + 1)); }
fail() { # fail <message>
  FAIL=$((FAIL + 1))
  echo "FAIL: $1"
  [ -n "$OUT" ] && echo "$OUT" | head -5
}

run_smoke() { # run_smoke <args...> — captures OUT + RC
  OUT=$(bash "$RUN" "$@" 2>&1)
  RC=$?
}

expect_exit() { # expect_exit <want> <label>
  if [ "$RC" -eq "$1" ]; then pass; else
    fail "$2: got exit $RC, want $1"
  fi
}

expect_out() { # expect_out <substring> <label>
  if echo "$OUT" | grep -qF "$1"; then pass; else
    fail "$2: output missing '$1'"
  fi
}

expect_not_out() { # expect_not_out <substring> <label>
  if echo "$OUT" | grep -qF "$1"; then
    fail "$2: output unexpectedly contains '$1'"
  else pass; fi
}

# ---------------------------------------------------------------------------
# Case 1: each broken fixture -> exit 1 AND FAIL line names the right reason.
# ---------------------------------------------------------------------------

# 1a. bad-frontmatter: missing `name` field.
run_smoke "$FIX/bad-frontmatter/command.md"
expect_exit 1 "bad-frontmatter"
expect_out "FAIL" "bad-frontmatter emits FAIL"
expect_out "bad-frontmatter/command.md" "bad-frontmatter names the file"
expect_out "name" "bad-frontmatter reason names the missing field"

# 1b. bad-yaml: frontmatter does not parse cleanly. The stdlib parser folds the
# malformed indented line into the prior key, so `description` never appears —
# the FAIL is a frontmatter defect either way. Assert exit 1 + a frontmatter
# reason, not the exact wording (see NOTE to team lead re: fixture intent).
run_smoke "$FIX/bad-yaml/command.md"
expect_exit 1 "bad-yaml"
expect_out "FAIL" "bad-yaml emits FAIL"
expect_out "bad-yaml/command.md" "bad-yaml names the file"
expect_out "frontmatter" "bad-yaml reason names a frontmatter defect"

# 1c. bad-fence: a bash fence that fails bash -n; reason names the line range.
run_smoke "$FIX/bad-fence/command.md"
expect_exit 1 "bad-fence"
expect_out "FAIL" "bad-fence emits FAIL"
expect_out "bad-fence/command.md" "bad-fence names the file"
expect_out "bash fence at lines" "bad-fence reason names the fence line range"
expect_out "bash -n" "bad-fence reason cites bash -n"

# 1d. bad-engine: a .sh that fails bash -n; reason names the script + bash -n.
run_smoke "$FIX/bad-engine/engine.sh"
expect_exit 1 "bad-engine"
expect_out "FAIL" "bad-engine emits FAIL"
expect_out "bad-engine/engine.sh" "bad-engine names the script"
expect_out "bash -n" "bad-engine reason cites bash -n"

# ---------------------------------------------------------------------------
# Case 2: clean fixture dir -> exit 0 (valid surface + valid engine script).
# ---------------------------------------------------------------------------
run_smoke "$FIX/clean/command.md" "$FIX/clean/engine.sh"
expect_exit 0 "clean fixtures"
expect_out "PASS $FIX/clean/command.md" "clean surface PASSes"
expect_out "PASS $FIX/clean/engine.sh" "clean engine PASSes"
expect_out "2 checked, 0 failed" "clean summary is 2 checked 0 failed"

# ---------------------------------------------------------------------------
# Case 3: live-tree no-arg run from the worktree root -> exit 0.
# ---------------------------------------------------------------------------
OUT=$(cd "$REPO_ROOT" && bash "$RUN" 2>&1)
RC=$?
expect_exit 0 "live no-arg run"
expect_out "0 failed" "live no-arg summary reports 0 failed"
expect_not_out "FAIL " "live no-arg run has no FAIL lines"
# Discovery sanity: the run checks a non-trivial set, none of it fixture material.
expect_not_out "tools/smoke/fixtures" "live run excludes harness fixtures"

# ---------------------------------------------------------------------------
# Case 4: `bash template` opt-out is NOT a hole. A broken fence bare -> FAIL;
# the same fence tagged `bash template` -> PASS (syntax skipped); BUT the
# frontmatter check set still applies to a template-tagged file.
# ---------------------------------------------------------------------------
BROKEN_BODY='if true'$'\n''  echo "unclosed if with no fi"'

# 4a. bare ```bash with a broken body -> exit 1 (syntax enforced).
{
  printf -- '---\n'
  printf 'name: tmpl-probe\n'
  printf 'description: template opt-out probe\n'
  printf -- '---\n\n'
  printf '```bash\n%s\n```\n' "$BROKEN_BODY"
} > "$TMP/bare.md"
run_smoke "$TMP/bare.md"
expect_exit 1 "template probe: bare broken fence FAILs"
expect_out "bash fence at lines" "bare broken fence reason names the fence"

# 4b. same fence tagged ```bash template -> exit 0 (syntax skipped).
{
  printf -- '---\n'
  printf 'name: tmpl-probe\n'
  printf 'description: template opt-out probe\n'
  printf -- '---\n\n'
  printf '```bash template\n%s\n```\n' "$BROKEN_BODY"
} > "$TMP/tmpl.md"
run_smoke "$TMP/tmpl.md"
expect_exit 0 "template probe: tagged fence syntax skipped -> PASS"
expect_out "PASS $TMP/tmpl.md" "template-tagged file PASSes"

# 4c. template-tagged fence, but frontmatter missing `description` -> exit 1.
# The opt-out covers ONLY the fence syntax check; frontmatter is still enforced.
{
  printf -- '---\n'
  printf 'name: tmpl-probe\n'
  printf -- '---\n\n'
  printf '```bash template\n%s\n```\n' "$BROKEN_BODY"
} > "$TMP/tmpl-badfm.md"
run_smoke "$TMP/tmpl-badfm.md"
expect_exit 1 "template probe: frontmatter still enforced on template file"
expect_out "frontmatter" "template file frontmatter defect still FAILs"
expect_out "description" "template file names the missing description field"

# ---------------------------------------------------------------------------
# Case 5: usage error -> exit 64. Two shapes per SPEC-030: an invalid flag, and
# an explicit target list where every named path is missing/unreadable.
# ---------------------------------------------------------------------------
run_smoke --no-such-flag
expect_exit 64 "usage error: invalid flag"

run_smoke "$TMP/does-not-exist-a.md" "$TMP/does-not-exist-b.md"
expect_exit 64 "usage error: all target paths missing"

# ---------------------------------------------------------------------------
# Case 6: determinism — two consecutive no-arg runs produce identical output.
# ---------------------------------------------------------------------------
(cd "$REPO_ROOT" && bash "$RUN") > "$TMP/run1.txt" 2>/dev/null
(cd "$REPO_ROOT" && bash "$RUN") > "$TMP/run2.txt" 2>/dev/null
if diff -q "$TMP/run1.txt" "$TMP/run2.txt" >/dev/null 2>&1; then
  pass
else
  OUT=$(diff "$TMP/run1.txt" "$TMP/run2.txt" | head -20)
  fail "determinism: two no-arg runs differ"
fi

# ---------------------------------------------------------------------------
echo "---"
echo "smoke bite-test: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
