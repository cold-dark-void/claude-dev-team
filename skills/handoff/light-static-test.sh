#!/usr/bin/env bash
# light-static-test.sh — CDT-91 T9d static contract for SPEC-018 M10c light preset.
# Greps committed prompt/docs/code only (no network, no LLM, no finalize).
# Run: bash skills/handoff/light-static-test.sh
set -u

HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT=$(CDPATH= cd -- "$HERE/../.." && pwd)
CMD="$ROOT/commands/handoff.md"
ASM="$HERE/assemble.py"
SPEC="$ROOT/specs/core/SPEC-018-cold-session-handoff.md"
HONESTY='light preset: reduced-cost mine, no annotation; not AC-16-scored.'

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $*"; }

# ---- T-pre: fixtures present ----
if [ -f "$CMD" ] && [ -f "$ASM" ] && [ -f "$SPEC" ]; then ok
else bad "T-pre missing CMD/ASM/SPEC"; fi

# ---- T0: commands/handoff.md pins HANDOFF_MINER_MODEL haiku default for light ----
# Exact light-knob export under LIGHT=1 branch (honor operator env when set).
if grep -qE 'HANDOFF_MINER_MODEL="\$\{HANDOFF_MINER_MODEL:-haiku\}"' "$CMD" \
  && grep -qE 'M10c light knobs|if \[ "\$LIGHT" = "1" \]' "$CMD"; then
  ok
else
  bad "T0 handoff.md missing light HANDOFF_MINER_MODEL=haiku default"
fi

# ---- T1: SKIP_ANNOTATION / skip annotation for light ----
if grep -qE 'export SKIP_ANNOTATION=1' "$CMD" \
  && grep -qiE 'Light / `SKIP_ANNOTATION=1` / `HANDOFF_LIGHT=1`: skip entirely' "$CMD" \
  && grep -qE 'if \[ "\$SKIP_ANNOTATION" = "1" \] \|\| \[ "\$HANDOFF_LIGHT" = "1" \] \|\| \[ "\$LIGHT" = "1" \]' "$CMD"; then
  ok
else
  bad "T1 handoff.md missing SKIP_ANNOTATION / light skip-annotation gate"
fi

# ---- T2: honesty string present; no UNMINED for light path ----
# Exact M10c honesty in assemble + SPEC; assemble light path must not emit UNMINED.
if grep -qF "$HONESTY" "$ASM" \
  && grep -qF "$HONESTY" "$SPEC" \
  && grep -qE 'MUST NOT say "UNMINED"|MUST NOT say .UNMINED.' "$SPEC"; then
  ok
else
  bad "T2 honesty string or no-UNMINED contract missing (asm/spec)"
fi

# assemble.py: LIGHT_HONESTY constant + append on light; no UNMINED in that constant
if grep -qE 'LIGHT_HONESTY\s*=' "$ASM" \
  && grep -qF "LIGHT_HONESTY = \"$HONESTY\"" "$ASM" \
  && ! grep -qE 'LIGHT_HONESTY\s*=.*UNMINED' "$ASM"; then
  ok
else
  bad "T2b assemble.py LIGHT_HONESTY not exact / contains UNMINED"
fi

# ---- T3: SPEC-018 M10c present ----
if grep -qE 'M10c — Light warm preset \(CDT-91\)' "$SPEC" \
  && grep -q 'HANDOFF_MINER_MODEL=haiku' "$SPEC" \
  && grep -qiE 'skip.*annotation|skip warm annotation' "$SPEC" \
  && grep -qF 'light: true' "$SPEC" \
  && grep -qE '\*-draft\.md|-draft\.md' "$SPEC"; then
  ok
else
  bad "T3 SPEC-018 M10c section incomplete"
fi

# ---- T4: handoff.md Rules mention M10c light knobs ----
if grep -qE '\*\*M10c light\*\*' "$CMD" \
  && grep -q 'SKIP_ANNOTATION' "$CMD" \
  && grep -qiE 'never claim freeform/unmined|MUST NOT say "UNMINED"|never claim.*unmined' "$CMD"; then
  ok
else
  bad "T4 handoff.md Rules M10c light summary incomplete"
fi

# ---- T5 (CDT-199): LIGHT.md thin profile exists ----
LIGHT="$HERE/LIGHT.md"
if [ -f "$LIGHT" ]; then ok
else bad "T5 skills/handoff/LIGHT.md missing"; fi

# ---- T6: --light branch cites LIGHT.md; does not require full SKILL Read ----
if grep -qE 'skills/handoff/LIGHT\.md|handoff/LIGHT\.md' "$CMD" \
  && grep -qE 'LIGHT_PROFILE|Read \$LIGHT_PROFILE' "$CMD"; then
  ok
else
  bad "T6 commands/handoff.md --light path must cite LIGHT.md / LIGHT_PROFILE"
fi

# Light dispatch must forbid a required full SKILL.md load
if grep -qE 'MUST NOT Read.*skills/handoff/SKILL\.md|MUST NOT Read \$SKILL' "$CMD"; then
  ok
else
  bad "T6b command light path must MUST NOT Read full SKILL.md"
fi

# ---- T7: LIGHT.md is not a required-load of SKILL.md or commands/handoff.md ----
# Negated mentions ("MUST NOT Read …") are allowed; a required Read is not.
if [ -f "$LIGHT" ]; then
  REQ_SKILL=$(grep -nE 'Read[[:space:]].*skills/handoff/SKILL\.md|Read[[:space:]]+\$SKILL' "$LIGHT" 2>/dev/null \
    | grep -vE 'MUST NOT|Do \*\*not\*\*|do \*\*not\*\*|do not Read|Do not Read' || true)
  REQ_CMD=$(grep -nE 'Read[[:space:]].*commands/handoff\.md' "$LIGHT" 2>/dev/null \
    | grep -vE 'MUST NOT|Do \*\*not\*\*|do \*\*not\*\*|do not Read|Do not Read' || true)
  if [ -z "$REQ_SKILL" ] && [ -z "$REQ_CMD" ]; then
    ok
  else
    bad "T7 LIGHT.md instructs required Read of SKILL.md or commands/handoff.md"
  fi
else
  bad "T7 skipped — LIGHT.md missing"
fi

# ---- T8: LIGHT.md carries M10c knobs + honesty + skip annotation + miner template ----
if [ -f "$LIGHT" ] \
  && grep -qF "$HONESTY" "$LIGHT" \
  && grep -q 'HANDOFF_MINER_MODEL' "$LIGHT" \
  && grep -q 'SKIP_ANNOTATION' "$LIGHT" \
  && grep -qiE 'skip.*annotation|no annotation' "$LIGHT" \
  && grep -q 'light: true' "$LIGHT" \
  && grep -qE 'through_line\.json' "$LIGHT" \
  && grep -q 'MERGED MINER' "$LIGHT"; then
  ok
else
  bad "T8 LIGHT.md missing M10c knobs / honesty / miner template / skip-annotation"
fi

# ---- T9: LIGHT.md keeps Product surfaces + Open ship gaps (CDT-198 / C2) ----
if [ -f "$LIGHT" ] \
  && grep -q 'Product surfaces' "$LIGHT" \
  && grep -q 'Open ship gaps' "$LIGHT" \
  && grep -q 'facet' "$LIGHT"; then
  ok
else
  bad "T9 LIGHT.md must keep Product surfaces / Open ship gaps (assemble C2)"
fi

# ---- T10: Step 2 light branch resolves LIGHT.md not SKILL.md ----
if awk '/^## Step 2: Locate the engine/,/^## Step 3:/' "$CMD" \
    | grep -qE 'skills/handoff/LIGHT\.md'; then
  ok
else
  bad "T10 Step 2 must resolve skills/handoff/LIGHT.md on the light branch"
fi

# ---- T11 (CDT-201 / Test 37): ruling-context + product_surface negatives ----
# LIGHT.md AND SKILL.md (byte-same examples; CDT-199: light never Reads SKILL).
SKILL="$HERE/SKILL.md"
if [ -f "$LIGHT" ] && [ -f "$SKILL" ]; then
  if grep -qF '"B Y"' "$LIGHT" && grep -qF '"B Y"' "$SKILL"; then
    ok
  else
    bad "T11 ruling negative \"B Y\" missing from LIGHT.md or SKILL.md"
  fi
  if grep -qF 'picked goja' "$LIGHT" && grep -qF 'picked goja' "$SKILL"; then
    ok
  else
    bad "T11 ruling positive picked goja missing from LIGHT.md or SKILL.md"
  fi
  if grep -qF 'not Product surfaces' "$LIGHT" \
    && grep -qF 'not Product surfaces' "$SKILL"; then
    ok
  else
    bad "T11 'not Product surfaces' missing from LIGHT.md or SKILL.md"
  fi
  if grep -qE 'CDT-198|XYZ-336' "$LIGHT" && grep -qE 'CDT-198|XYZ-336' "$SKILL" \
    && grep -qF 'XYZ-336' "$LIGHT" && grep -qF 'XYZ-336' "$SKILL"; then
    ok
  else
    bad "T11 ticket-ID negative (CDT-198 / XYZ-336) missing from LIGHT.md or SKILL.md"
  fi
else
  bad "T11 skipped — LIGHT.md or SKILL.md missing"
fi

echo "PASS=$PASS FAIL=$FAIL"
if [ "$FAIL" -eq 0 ]; then
  exit 0
fi
exit 1
