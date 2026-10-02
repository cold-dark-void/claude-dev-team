#!/usr/bin/env bash
# CDT-278 F28 text drift. implement.md README cite is already gone; not asserted.
set -u

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
pass=0
fail=0
ok() { pass=$((pass + 1)); echo "OK: $*"; }
bad() { fail=$((fail + 1)); echo "FAIL: $*"; }

if printf '%s\n' 'Spawned as ic5.' | grep -qF 'Spawned as ic5'; then
  ok "control: old premise spawn line is detectable"
else
  bad "control: premise detector is dead"
fi

prem="$ROOT/skills/fix-ticket/prompts/premise.md"
if grep -qF 'Spawned as ic5' "$prem"; then
  bad "premise.md still says Spawned as ic5"
else
  ok "premise.md does not say Spawned as ic5"
fi
if grep -qF 'debugger' "$prem"; then
  ok "premise.md names debugger"
else
  bad "premise.md does not name debugger"
fi

spec="$ROOT/specs/core/SPEC-028-fix-ticket-workflow.md"
if grep -qF 'read-only ic5' "$spec"; then
  bad "SPEC-028 still says read-only ic5"
else
  ok "SPEC-028 dropped read-only ic5"
fi
if grep -qF 'debugger' "$spec"; then
  ok "SPEC-028 names debugger"
else
  bad "SPEC-028 does not name debugger"
fi

skill="$ROOT/skills/fix-ticket/SKILL.md"
if grep -qF 'README version/changelog' "$skill"; then
  bad "SKILL.md still says README version/changelog"
else
  ok "SKILL.md dropped README version/changelog"
fi
if grep -qF 'CHANGELOG.md' "$skill"; then
  ok "SKILL.md names CHANGELOG.md as the version file"
else
  bad "SKILL.md does not name CHANGELOG.md"
fi
if grep -qF 'fix-ticket assumes known premise + fix' "$skill"; then
  bad "SKILL.md still treats all of /debug as distinct from this pipeline"
else
  ok "SKILL.md dropped the confusing /debug one-liner"
fi
if grep -qF '/debug ticket' "$skill" && grep -qF 'This pipeline' "$skill"; then
  ok "SKILL.md says /debug ticket is this pipeline"
else
  bad "SKILL.md does not say /debug ticket is this pipeline"
fi

wf="$ROOT/skills/fix-ticket/workflow.js"
if grep -qF '.claude/p0-fix-workflow.js' "$wf"; then
  bad "workflow.js still cites .claude/p0-fix-workflow.js"
else
  ok "workflow.js dropped the missing p0-fix-workflow path"
fi

impl="$ROOT/skills/fix-ticket/prompts/implement.md"
if grep -qF 'README' "$impl"; then
  bad "implement.md gained a README version claim"
else
  ok "implement.md still has no README version claim"
fi

echo "PASS=$pass FAIL=$fail"
[ "$fail" -eq 0 ]
