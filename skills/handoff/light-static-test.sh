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

echo "PASS=$PASS FAIL=$FAIL"
if [ "$FAIL" -eq 0 ]; then
  exit 0
fi
exit 1
