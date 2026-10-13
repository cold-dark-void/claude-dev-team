#!/usr/bin/env bash
# scaffold-project/test.sh — CDT-297 [10 scaffold-fences] + rv-w3-32 de-GUI,
# no non-roster memory dir, and SPEC-008 skeleton starter specs.
# bite-tests: the two emitted templates survive their inner ``` fences (4-backtick
# outer), no phantom ~/.claude/CLAUDE.md reference, the starter specs are
# stack-neutral and emitted from the spec-skeleton.md include region, and no
# .claude/memory/claude/ is created.
#
# Machine-check: bash skills/scaffold-project/test.sh  (exit 0)
# THIS SCRIPT IS A SUBPROCESS CLI — NEVER SOURCE IT.

set -u

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SKILL="$HERE/SKILL.md"

pass=0
fail=0
pass_line() { pass=$((pass + 1)); echo "PASS: $1"; }
fail_line() { fail=$((fail + 1)); echo "FAIL: $1" >&2; }

S=$(cat "$SKILL")

# ---- T1: the two big templates use 4-backtick outer fences -------------------
N4=$(printf '%s' "$S" | grep -c '^````markdown$')
if [ "$N4" -eq 2 ]; then
  pass_line "exactly two 4-backtick template fences (TDD.md + AGENTS.md)"
else
  fail_line "expected 2 four-backtick fences, found $N4"
fi
printf '%s\n' '````markdown' | grep -q '^````markdown$' \
  && pass_line "negative control: 4-backtick fence marker is detectable" \
  || fail_line "negative control: 4-backtick marker not detectable"

# ---- T2: each template body survives past its inner ``` tree fence -----------
# Extract the 4-backtick template that follows a given heading and assert the
# sections AFTER the inner fence are still inside the body. On the old
# 3-backtick outer fences the body was truncated at the first inner ``` —
# this test fails there.
template_body() { # template_body <heading-grep>
  awk -v pat="$1" '
    $0 ~ pat { seen=1; next }
    seen && /^````markdown$/ { grab=1; next }
    grab && /^````$/ { exit }
    grab { print }
  ' "$SKILL"
}

TDD_BODY=$(template_body '^### Step 5: Create TDD.md$')
AG_BODY=$(template_body '^### Step 6: Create AGENTS.md$')
if [ -z "$TDD_BODY" ]; then fail_line "TDD.md template extracted"; fi
if [ -z "$AG_BODY" ]; then fail_line "AGENTS.md template extracted"; fi

for needle in "## Spec Layout" "├── core/" "## Version History" "## Instructions for AI Agents"; do
  if printf '%s' "$TDD_BODY" | grep -qF -- "$needle"; then
    pass_line "TDD.md template keeps '$needle' inside the copied body"
  else
    fail_line "TDD.md template truncated before '$needle' (inner fence closed the outer)"
  fi
done
for needle in "## Architecture Notes" "├── \[directory\] - \[Purpose\]" "## Adversarial fleet degradation" "## Commit Guidelines"; do
  if printf '%s' "$AG_BODY" | grep -qE -- "$needle"; then
    pass_line "AGENTS.md template keeps section inside the copied body"
  else
    fail_line "AGENTS.md template truncated before: $needle"
  fi
done

# The inner 3-backtick tree fences must still be plain ``` inside the body.
printf '%s' "$TDD_BODY" | grep -q '^```$' \
  && pass_line "TDD.md body keeps its inner triple-backtick tree fence" \
  || fail_line "TDD.md body lost the inner triple-backtick fence"

# ---- T3: no phantom ~/.claude/CLAUDE.md reference ----------------------------
if printf '%s' "$S" | grep -q '~/.claude/CLAUDE.md'; then
  fail_line "skill still references the never-created ~/.claude/CLAUDE.md"
else
  pass_line "no ~/.claude/CLAUDE.md reference (CDT-297 10 scaffold-fences)"
fi
printf '%s\n' 'Read ~/.claude/CLAUDE.md for docs' | grep -q '~/.claude/CLAUDE.md' \
  && pass_line "negative control: the phantom reference text is detectable" \
  || fail_line "negative control: phantom reference not detectable"

# ---- T4: starter specs are stack-neutral (rv-w3-32 de-GUI half) --------------
for banned in "Application Launch" "Basic Navigation" "screen sizes/resolutions" "UI responsiveness"; do
  if printf '%s' "$S" | grep -qF -- "$banned"; then
    fail_line "GUI-centric starter text still present: $banned"
  else
    pass_line "no GUI-centric starter text: $banned"
  fi
done
if printf '%s' "$S" | grep -q '<First Core Behavior>'; then
  pass_line "starter spec titles are placeholder-neutral"
else
  fail_line "starter spec titles not neutralized"
fi

# ---- T5: no non-roster memory dir is created (rv-w3-32) -----------------------
if printf '%s' "$S" | grep -q 'memory/claude'; then
  fail_line "scaffold still creates .claude/memory/claude (rv-w3-32)"
else
  pass_line "no .claude/memory/claude creation (rv-w3-32)"
fi
printf '%s\n' 'mkdir -p "$PROJ_ROOT/.claude/memory/claude"' | grep -q 'memory/claude' \
  && pass_line "negative control: memory/claude text is detectable" \
  || fail_line "negative control: memory/claude text not detectable"

# ---- T6: memory dirs are created for the 7 roster agents only (rv-w3-32) ------
if printf '%s' "$S" | grep -qF 'for _agent in pm tech-lead ic5 ic4 devops qa ds'; then
  pass_line "memory dirs created for the 7 roster agents only (rv-w3-32)"
else
  fail_line "roster memory-dir loop missing"
fi

# ---- T7: starter specs come from the spec-skeleton.md include region ----------
# (rv-w3-32): the 9-section body must be the drift-gated partial, byte-identical,
# and the old inline '## Core Specifications' block must be gone.
SKELETON="$HERE/../spec-tooling/spec-skeleton.md"
if [ ! -f "$SKELETON" ]; then
  fail_line "spec-skeleton.md not found"
else
  PARTIAL=$(mktemp "${TMPDIR:-/tmp}/sc-part.XXXXXX")
  REGION=$(mktemp "${TMPDIR:-/tmp}/sc-reg.XXXXXX")
  awk 'f{print} !f && $0=="-->"{f=1}' "$SKELETON" > "$PARTIAL"
  awk '/^<!-- include: skills\/spec-tooling\/spec-skeleton\.md agent=spec -->$/{g=1;next} /^<!-- \/include -->$/{g=0} g' "$SKILL" > "$REGION"
  if [ -s "$REGION" ] && diff -q "$PARTIAL" "$REGION" >/dev/null; then
    pass_line "skeleton include region is byte-identical to the partial (rv-w3-32)"
  else
    fail_line "include region missing or drifted from spec-skeleton.md (rv-w3-32)"
  fi
  rm -f "$PARTIAL" "$REGION"
fi
printf '%s\n' '## Core Specifications' | grep -q '^## Core Specifications$' \
  && pass_line "negative control: old inline-spec heading is detectable" \
  || fail_line "negative control: old inline-spec heading not detectable"
if printf '%s' "$S" | grep -q '^## Core Specifications$'; then
  fail_line "old inline '## Core Specifications' block still present (rv-w3-32)"
else
  pass_line "old inline spec block replaced by the skeleton include (rv-w3-32)"
fi

# ---- T8: the rendered starter spec passes check-format.sh (rv-w3-32) ----------
CHECK_FORMAT="$HERE/../spec-tooling/check-format.sh"
if [ ! -x "$CHECK_FORMAT" ] && [ ! -f "$CHECK_FORMAT" ]; then
  fail_line "check-format.sh not found"
else
  SPEC=$(mktemp "${TMPDIR:-/tmp}/sc-spec.XXXXXX")
  awk '/^<!-- include: skills\/spec-tooling\/spec-skeleton\.md agent=spec -->$/{g=1;next} /^<!-- \/include -->$/{g=0} g' "$SKILL" \
    | sed -e '1d' -e '$d' \
    | sed -e 's/^# <PREFIX>-<NNN>: <Title>$/# SPEC-001: <First Core Behavior>/' \
          -e 's/^\*\*Status\*\*: <STATUS>/**Status**: DRAFT/' \
          -e 's/^\*\*Category\*\*: <CATEGORY>/**Category**: core/' > "$SPEC"
  if bash "$CHECK_FORMAT" "$SPEC" >/dev/null 2>&1; then
    pass_line "rendered starter spec passes check-format.sh (rv-w3-32)"
  else
    fail_line "rendered starter spec fails check-format.sh (rv-w3-32)"
  fi
  if grep -qE '^[[:space:]]*[-*][[:space:]]*\[[ xX]\]' "$SPEC"; then
    fail_line "rendered starter spec carries retired checkbox syntax (SPEC-008 retirement)"
  else
    pass_line "rendered starter spec has no retired checkbox syntax (SPEC-008 retirement)"
  fi
  rm -f "$SPEC"
fi

echo
echo "scaffold-project: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
