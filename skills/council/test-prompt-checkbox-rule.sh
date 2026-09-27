#!/usr/bin/env bash
# WP 1-15 T5 (AC J) — checkbox-is-not-evidence rule, present in each of the
# three council prompts with a different function per SPEC-033 M14(g)/
# Design 8: the investigator records a checkbox line as file content only
# (never a result), the phase4-brief never cites checkbox state for or
# against a claim, and the judge strikes any brief/verdict line that rests
# on checkbox state.
#
# Hermetic: no fixed paths, private mktemp -d TMPDIR, EXIT trap.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

# shellcheck source=../../tests/lib/skip.sh
. "$ROOT/tests/lib/skip.sh"
# shellcheck source=../../tests/lib/hermetic.sh
. "$ROOT/tests/lib/hermetic.sh"
hermetic_init

INVESTIGATOR_MD="$ROOT/skills/council/prompts/investigator.md"
PHASE4_MD="$ROOT/skills/council/prompts/phase4-brief.md"
JUDGE_MD="$ROOT/skills/council/prompts/judge.md"
SPEC_MD="$ROOT/specs/core/SPEC-033-autopilot-policy.md"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/checkbox-rule-test.XXXXXX")"
trap 'rm -rf "$TMP"; hermetic_cleanup' EXIT

fail=0
ok() { echo "OK: $1"; }
fail_msg() { echo "FAIL: $1"; fail=1; }

# Print the first blank-line-delimited paragraph in FILE that mentions
# "checkbox" (case-insensitive). Empty output means no such paragraph.
checkbox_paragraph() {
  local file="$1"
  awk 'BEGIN{RS=""} tolower($0) ~ /checkbox/ {print; exit}' "$file"
}

# Run the three per-prompt rule checks against the given file paths.
# Prints OK/FAIL lines and returns 1 if any check fails, 0 otherwise.
check_checkbox_rules() {
  local inv="$1" p4="$2" judge="$3" spec="$4"
  local rc=0

  local inv_para p4_para judge_para
  inv_para="$(checkbox_paragraph "$inv")"
  p4_para="$(checkbox_paragraph "$p4")"
  judge_para="$(checkbox_paragraph "$judge")"

  if [ -n "$inv_para" ] && grep -qF 'file content only, never as a result' <<<"$inv_para"; then
    ok "investigator: records a checkbox line as file content only, never a result"
  else
    fail_msg "investigator: no checkbox-as-file-content-only rule found"
    rc=1
  fi

  if [ -n "$p4_para" ] && grep -qF 'NEVER cite a spec checkbox' <<<"$p4_para"; then
    ok "phase4-brief: never cites checkbox state for or against a claim"
  else
    fail_msg "phase4-brief: no never-cite-checkbox rule found"
    rc=1
  fi

  if [ -n "$judge_para" ] && grep -qF 'MUST be struck' <<<"$judge_para"; then
    ok "judge: strikes a brief/verdict line that rests on checkbox state"
  else
    fail_msg "judge: no checkbox-strike rule found"
    rc=1
  fi

  if grep -qF 'Checkboxes are not evidence' "$spec"; then
    ok "spec: SPEC-033 M14(g) holds \"Checkboxes are not evidence\""
  else
    fail_msg "spec: SPEC-033 M14(g) is missing \"Checkboxes are not evidence\""
    rc=1
  fi

  # The three prompts state the rule in different words (Design 8: "a
  # different function in each file", not copies of one sentence).
  if [ -n "$inv_para" ] && [ -n "$p4_para" ] && [ -n "$judge_para" ]; then
    if [ "$inv_para" != "$p4_para" ] && [ "$inv_para" != "$judge_para" ] \
      && [ "$p4_para" != "$judge_para" ]; then
      ok "the 3 checkbox sentences are not byte-identical to each other"
    else
      fail_msg "two or more checkbox sentences are byte-identical"
      rc=1
    fi
  else
    fail_msg "cannot compare checkbox sentences — at least one prompt has none"
    rc=1
  fi

  return "$rc"
}

# ---- real files -------------------------------------------------------------
if check_checkbox_rules "$INVESTIGATOR_MD" "$PHASE4_MD" "$JUDGE_MD" "$SPEC_MD"; then
  ok "all checkbox rules present on the real prompt files"
else
  fail_msg "checkbox rule check failed on the real prompt files"
  fail=1
fi

# ---- bite test: removing the judge checkbox paragraph must fail closed -----
BITE_JUDGE="$TMP/judge.bitten.md"
awk 'BEGIN{RS="";ORS="\n\n"} tolower($0) !~ /checkbox/ {print}' "$JUDGE_MD" > "$BITE_JUDGE"

if (check_checkbox_rules "$INVESTIGATOR_MD" "$PHASE4_MD" "$BITE_JUDGE" "$SPEC_MD") >/dev/null 2>&1; then
  fail_msg "bite test: removing the judge checkbox line did not fail the check"
  fail=1
else
  ok "bite test: removing the judge checkbox line fails the check"
fi

if [ "$fail" -eq 0 ]; then
  echo "PASS: test-prompt-checkbox-rule.sh"
  exit 0
else
  echo "FAIL: test-prompt-checkbox-rule.sh"
  exit 1
fi
