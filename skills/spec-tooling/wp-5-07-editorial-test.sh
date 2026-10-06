#!/usr/bin/env bash
# WP 5-07 editorial contracts. Assert the live sentences this package changed.
# One negative control fails if the old EXAMPLE-status sentence returns.
set -u
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT=$(CDPATH= cd -- "$HERE/../.." && pwd)
PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); printf 'PASS %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf 'FAIL %s — %s\n' "$1" "$2"; }

need() {
  local name="$1" file="$2" phrase="$3"
  if grep -qF -- "$phrase" "$ROOT/$file"; then
    pass "$name"
  else
    fail "$name" "missing: $phrase"
  fi
}

# Search only the live body. Version History may name a removed path.
body() {
  awk 'BEGIN { p=1 } /^## Version History$/ { p=0 } p' "$1"
}

absent() {
  local name="$1" file="$2" phrase="$3"
  if body "$ROOT/$file" | grep -qF -- "$phrase"; then
    fail "$name" "old sentence still present: $phrase"
  else
    pass "$name"
  fi
}

# Negative control: the old scaffold sentence must not return.
absent "negative control EXAMPLE status" \
  specs/core/SPEC-005-team-bootstrap.md \
  "marked as EXAMPLE status"
need "scaffold seeds DRAFT" \
  specs/core/SPEC-005-team-bootstrap.md \
  "marked as DRAFT status"
if grep -q 'DRAFT' "$ROOT/skills/scaffold-project/SKILL.md" \
   && ! grep -q 'EXAMPLE status' "$ROOT/skills/scaffold-project/SKILL.md"; then
  pass "scaffold code still emits DRAFT"
else
  fail "scaffold code" "DRAFT emission changed"
fi

absent "no init-team stub MUST" \
  specs/core/SPEC-005-team-bootstrap.md \
  "MUST be a one-cycle Deprecation stub"
need "init-team file is not required" \
  specs/core/SPEC-005-team-bootstrap.md \
  "There is no \`commands/init-team.md\`"
absent "no demo stub MUST" \
  specs/core/SPEC-005-team-bootstrap.md \
  "skills/demo/SKILL.md\` MUST"
need "demo skill is gone" \
  specs/core/SPEC-005-team-bootstrap.md \
  "There is no \`skills/demo/SKILL.md\`"
absent "no council stub requirement" \
  specs/core/SPEC-013-adversarial-council-tribunal.md \
  "remains only as a DEPRECATED one-cycle stub"
need "blind flag is commands/council.md" \
  specs/core/SPEC-013-adversarial-council-tribunal.md \
  "There is no separate stub file."
need "finder is not the debug refuter" \
  specs/core/SPEC-013-adversarial-council-tribunal.md \
  "refuters stay \`qa\`"
absent "setup team.md garbled path" \
  specs/core/SPEC-024-memory-seed-packs.md \
  "commands/setup team.md"
need "seed import is commands/setup.md" \
  specs/core/SPEC-024-memory-seed-packs.md \
  "commands/setup.md"
absent "freshness-gate.sh" \
  specs/core/SPEC-002-plugin-infrastructure.md \
  "freshness-gate.sh"
need "live freshness.sh" \
  specs/core/SPEC-002-plugin-infrastructure.md \
  "skills/transcript-parse/freshness.sh"

absent "parallel rule not already in AGENTS" \
  specs/core/SPEC-016-worktree-isolation.md \
  "already documented in AGENTS.md"
need "SPEC-016 forbids parallel worktrees" \
  specs/core/SPEC-016-worktree-isolation.md \
  "MUST NOT run parallel \`git worktree\` operations"
need "AGENTS.md states the same rule" \
  AGENTS.md \
  "You MUST NOT run parallel \`git worktree\` operations"

need "stanza arm 1b is documented" \
  specs/core/SPEC-002-plugin-infrastructure.md \
  "substituted \`\${CLAUDE_PLUGIN_ROOT}\` token"
# The count is whatever the tree emits today. The spec must quote that count.
# Re-derived at CDT-502-C5-T6 with the plugin-dir harness's comment/prose
# exclusion (first non-whitespace '#' or '<!--'): the C5 dual-class note in
# skills/skill-lint/lint.py is prose, not a caller site — counting it gave
# 88/100 against SPEC-002's measured 87/99. Scope is unchanged (3 roots, skip
# fixtures/ and the three named harness/decoy files); docs/ and AGENTS.md stay
# out of the caller inventory (SPEC-002 § Caller integration). Re-derivation:
#   grep -RIn --exclude-dir=fixtures 'PDH=$( {' commands skills agents \
#     | grep -v '/plugin-dir-test.sh:' | grep -v '/skill-lint/test.sh:' \
#     | grep -v '/wp-5-07-editorial-test.sh:' | grep -vcE ':[[:space:]]*(#|<!--)'
stanza_lines=$(grep -RIn --exclude-dir=fixtures 'PDH=$( {' \
  "$ROOT/commands" "$ROOT/skills" "$ROOT/agents" \
  | grep -v '/plugin-dir-test.sh:' | grep -v '/skill-lint/test.sh:' \
  | grep -v '/wp-5-07-editorial-test.sh:' \
  | grep -vE ':[[:space:]]*(#|<!--)')
stanza_files=0; stanza_hits=0
if [ -n "$stanza_lines" ]; then
  stanza_files=$(printf '%s\n' "$stanza_lines" | cut -d: -f1 | sort -u | wc -l | tr -d ' ')
  stanza_hits=$(printf '%s\n' "$stanza_lines" | wc -l | tr -d ' ')
fi
need "measured emission count" \
  specs/core/SPEC-002-plugin-infrastructure.md \
  "${stanza_files} caller files, ${stanza_hits} emissions"
need "version pair cross-ref" \
  specs/core/SPEC-002-plugin-infrastructure.md \
  "bumps the version pair"
absent "three version files" \
  specs/core/SPEC-002-plugin-infrastructure.md \
  "bumps all three version files"
absent "SPEC-010 three files" \
  specs/core/SPEC-010-code-review-release.md \
  "all three required files"

need "directives cite SPEC-003" \
  specs/core/SPEC-001-per-agent-directives.md \
  "non-behavioral roster agents in SPEC-003"
need "AGENTS.md names finder" \
  AGENTS.md \
  "finder, debugger, council-judge"
absent "reviewer Opus pin" \
  specs/core/SPEC-011-memory-validation.md \
  "MUST use Opus model for the reviewer agent"
need "reviewer is tech-lead frontmatter" \
  specs/core/SPEC-011-memory-validation.md \
  "The model is that agent's frontmatter"

need "L5 is interactive" \
  specs/core/SPEC-025-epic-umbrella-decomposition.md \
  "No auto-chain in interactive mode"
absent "ticket git diff test" \
  specs/core/SPEC-003-agent-role-system.md \
  "git diff --name-only -- commands/"
need "measurement task class" \
  specs/core/SPEC-026-adaptive-agent-routing.md \
  "\`measurement\` is the class"

need "newest-first history" \
  specs/core/SPEC-008-spec-management.md \
  "Version History rows are newest-first"
need "M5b does not rewrite master rows" \
  specs/core/SPEC-023-release-train-queue.md \
  "Do not rewrite a master row."

need "mode is unspecced" specs/OWNERS "commands/mode.md	UNSPECCED"
need "tdd-gate is unspecced" specs/OWNERS "commands/tdd-gate.md	UNSPECCED"
need "domain-glossary is unspecced" specs/OWNERS "skills/domain-glossary	UNSPECCED"
need "TDD names unspecced surfaces" \
  specs/TDD.md \
  "## Unspecced surfaces"

# Two owners for one path must be rejected by spec-lint itself.
dup_root=$(mktemp -d "${TMPDIR:-/tmp}/wp507-owners.XXXXXX")
mkdir -p "$dup_root/specs/core" "$dup_root/skills/spec-tooling" \
  "$dup_root/commands" "$dup_root/agents" "$dup_root/skills"
cp "$ROOT/skills/spec-tooling/check-format.sh" "$dup_root/skills/spec-tooling/check-format.sh"
printf '%s\n' '# agents' > "$dup_root/AGENTS.md"
cat > "$dup_root/specs/TDD.md" << 'EOF'
| ID | Title | Status | Coverage |
|----|-------|--------|----------|
| SPEC-001 | Clean title | ACTIVE | x |
EOF
cat > "$dup_root/specs/core/SPEC-001-clean.md" << 'EOF'
# SPEC-001: Clean title

**Status**: ACTIVE
**Category**: core
**Created**: 2026-10-01

**Covers**: `skills/spec-tooling/check-format.sh`

## Overview

Clean.

## MUST

- MUST stay clean

## Test

- the format script exists

## Validation

- [x] reviewed

## Version History

| Date | Change |
|------|--------|
| 2026-10-01 | initial |
| 2026-09-01 | older
EOF
printf '%s\n' '# mode' > "$dup_root/commands/mode.md"
printf '%s\n' $'commands/mode.md\tUNSPECCED' $'commands/mode.md\tSPEC-001' > "$dup_root/specs/OWNERS"
dup_out=$(bash "$ROOT/tools/spec-lint.sh" --root "$dup_root" 2>&1) || dup_rc=$?
dup_rc=${dup_rc:-0}
if [ "$dup_rc" -ne 0 ] && printf '%s\n' "$dup_out" | grep -q 'duplicate commands/mode.md'; then
  pass "spec-lint rejects two owners"
else
  fail "two owners" "rc=$dup_rc out=$dup_out"
fi
rm -rf "$dup_root"
if awk -F'\t' 'NF==2 && seen[$1]++ { found=1 } END { exit found ? 1 : 0 }' "$ROOT/specs/OWNERS"; then
  pass "OWNERS has one line per path"
else
  fail "OWNERS" "duplicate path"
fi

need "ticket home stays SPEC-014" \
  specs/core/SPEC-014-debug-workflow.md \
  "There is no \`commands/fix-ticket.md\`"
if [ -f "$ROOT/skills/fix-ticket/SKILL.md" ]; then
  pass "fix-ticket skill kept"
else
  fail "fix-ticket skill" "deleted"
fi

printf '%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
