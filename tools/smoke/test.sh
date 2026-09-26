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
# Case 7: agent fixtures (SPEC-030 Check set — Agent). Clean + block-sequence
# `tools` -> PASS; missing `effort` and out-of-domain `model` -> FAIL naming
# the field/value.
# ---------------------------------------------------------------------------
run_smoke "$FIX/agents/clean.md"
expect_exit 0 "agent clean"
expect_out "PASS $FIX/agents/clean.md" "agent clean PASSes"

run_smoke "$FIX/agents/block-list.md"
expect_exit 0 "agent block-list tools"
expect_out "PASS $FIX/agents/block-list.md" "agent block-sequence tools PASSes"

run_smoke "$FIX/agents/missing-effort.md"
expect_exit 1 "agent missing effort"
expect_out "FAIL" "agent missing effort emits FAIL"
# Assert the actual reason text, not just the substring "effort" -- the
# fixture path itself contains "effort" (missing-effort.md), so a bare
# `expect_out "effort"` would pass even if the reason said nothing about it.
expect_out "missing \`effort\`" "agent missing-effort reason names the missing field"

run_smoke "$FIX/agents/bad-model.md"
expect_exit 1 "agent bad model"
expect_out "FAIL" "agent bad model emits FAIL"
expect_out "gpt-4" "agent bad-model reason names the bad value"

# ---------------------------------------------------------------------------
# Case 8: broken githook and broken test-script fixtures -> FAIL naming the
# file, exit 1.
# ---------------------------------------------------------------------------
run_smoke "$FIX/githooks/pre-commit"
expect_exit 1 "broken githook"
expect_out "FAIL $FIX/githooks/pre-commit" "broken githook names the file"
expect_out "bash -n" "broken githook reason cites bash -n"

run_smoke "$FIX/bad-test/broken-test.sh"
expect_exit 1 "broken test script"
expect_out "FAIL $FIX/bad-test/broken-test.sh" "broken test script names the file"
expect_out "bash -n" "broken test script reason cites bash -n"

# ---------------------------------------------------------------------------
# Case 9: no-arg `--root` discovery of the new kinds on a mktemp tree that is
# NOT a git repo (walk fallback). Holds a broken agent, a broken githook, a
# broken `*-test.sh`, a broken sub-doc fence, and a broken test script under a
# `fixtures/` segment that must never surface in the output.
# ---------------------------------------------------------------------------
ROOT9="$TMP/root9"
mkdir -p "$ROOT9/agents" "$ROOT9/githooks" "$ROOT9/skills/a/steps" "$ROOT9/skills/a/fixtures"

{
  printf -- '---\n'
  printf 'name: root9-bad-agent\n'
  printf 'description: broken agent for --root discovery\n'
  printf 'tools: Read\n'
  printf 'model: sonnet\n'
  printf -- '---\n'
} > "$ROOT9/agents/x.md"  # missing `effort` -> FAIL

{
  printf '#!/usr/bin/env bash\n'
  printf 'set -euo pipefail\n'
  printf 'if true\n'
  printf '  echo "unclosed"\n'
} > "$ROOT9/githooks/pre-commit"  # fails bash -n -> FAIL

{
  printf '#!/usr/bin/env bash\n'
  printf 'if true\n'
  printf '  echo "unclosed"\n'
} > "$ROOT9/skills/a/b-test.sh"  # fails bash -n -> FAIL

{
  printf '# doc\n\n'
  printf '```bash\n'
  printf 'if true\n'
  printf '  echo "unclosed"\n'
  printf '```\n'
} > "$ROOT9/skills/a/steps/doc.md"  # broken sub-doc fence -> FAIL

{
  printf '#!/usr/bin/env bash\n'
  printf 'if true\n'
  printf '  echo "unclosed"\n'
} > "$ROOT9/skills/a/fixtures/ok-test.sh"  # under a `fixtures` segment -> excluded

run_smoke --root "$ROOT9"
expect_exit 1 "root9 --root discovery"
expect_out "root9/agents/x.md" "root9 broken agent FAILs"
expect_out "effort" "root9 broken agent names effort"
expect_out "root9/githooks/pre-commit" "root9 broken githook FAILs"
expect_out "root9/skills/a/b-test.sh" "root9 broken test script FAILs"
expect_out "root9/skills/a/steps/doc.md" "root9 broken sub-doc fence FAILs"
expect_not_out "root9/skills/a/fixtures" "root9 excludes the fixtures-segment script"
FAIL_LINES=$(echo "$OUT" | grep -c '^FAIL ')
if [ "$FAIL_LINES" -eq 4 ]; then pass; else
  fail "root9 --root discovery: want 4 FAIL lines, got $FAIL_LINES"
fi

# ---------------------------------------------------------------------------
# Case 10: --invoke-flags MUST NOT invoke a test script or a githook even when
# its own text declares --help (SPEC-030 Check set — Script). Each fixture
# exits 1 if actually invoked with --help, so a PASS here proves the harness
# skipped invocation rather than merely tolerating a zero exit.
# ---------------------------------------------------------------------------
run_smoke --invoke-flags "$FIX/invoke-flags-guard/guard-test.sh"
expect_exit 0 "invoke-flags guard: test script not invoked"
expect_out "PASS $FIX/invoke-flags-guard/guard-test.sh" "invoke-flags guard: test script PASSes"

run_smoke --invoke-flags "$FIX/invoke-flags-guard/githooks/pre-push"
expect_exit 0 "invoke-flags guard: githook not invoked"
expect_out "PASS $FIX/invoke-flags-guard/githooks/pre-push" "invoke-flags guard: githook PASSes"

# ---------------------------------------------------------------------------
# Case 11: classify() MUST use a repo-relative path, not an absolute one. An
# ancestor directory that happens to be named `skills` (outside the target
# tree's own skills/ dir) must never leak into the shape classify() sees --
# it would otherwise misclassify commands/*.md as a frontmatter-exempt
# Sub-doc and silently pass a broken Surface (T1 review fix).
# ---------------------------------------------------------------------------
ROOT11="$TMP/skills/repo"
mkdir -p "$ROOT11/commands"
{
  printf -- '---\n'
  printf 'description: missing the name field\n'
  printf -- '---\n'
} > "$ROOT11/commands/broken.md"  # missing `name` -> FAIL, if classified Surface

run_smoke --root "$ROOT11"
expect_exit 1 "skills-ancestor root: broken command FAILs"
expect_out "FAIL $ROOT11/commands/broken.md" "skills-ancestor root: broken command names the file"
expect_out "missing \`name\`" "skills-ancestor root: reason names the missing field"
expect_out "1 checked, 1 failed" "skills-ancestor root: exactly one target, one failure"

# ---------------------------------------------------------------------------
echo "---"
echo "smoke bite-test: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
