#!/usr/bin/env bash
# covers: SPEC-020/T1
# Frontmatter of the two doors, plus the shipped list-mode find fence.
set -u
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
# shellcheck source=../../tests/lib/fence.sh
. "$ROOT/tests/lib/fence.sh"
# shellcheck source=../../tests/lib/check.sh
. "$ROOT/tests/lib/check.sh"
pass=0
fail=0

name_of() { # name_of FILE
  awk '
    BEGIN { state=0 }
    /^---$/ { state++; next }
    state==1 && /^name: / { sub(/^name: /, ""); print; exit }
  ' "$1"
}

for f in "$ROOT/commands/craft-loop.md" "$ROOT/skills/craft-loop/SKILL.md"; do
  got=$(name_of "$f")
  [ "$got" = "craft-loop" ] && pass_line "name craft-loop in ${f#"$ROOT/"}" \
    || fail_line "name craft-loop in ${f#"$ROOT/"} (got ${got:-empty})"
done

FENCE=$(fence_nth "$ROOT/skills/craft-loop/SKILL.md" "Mode: list" 1) || FENCE=""
if [ -z "$FENCE" ]; then
  fail_line "list-mode fence extracted"
  echo "craft-loop list exclude: $pass passed, $fail failed"
  exit 1
fi
pass_line "list-mode fence extracted"

LOOPS="$ROOT/.claude/loops"
mkdir -p "$LOOPS"
STEM="zz-spec020-trace"
rm -f "$LOOPS/$STEM.md" "$LOOPS/$STEM.journal.md" \
  "$LOOPS/$STEM.findings.md" "$LOOPS/$STEM.ledger.md"
trap 'rm -f "$LOOPS/$STEM.md" "$LOOPS/$STEM.journal.md" "$LOOPS/$STEM.findings.md" "$LOOPS/$STEM.ledger.md"' EXIT

cat > "$LOOPS/$STEM.md" << 'EOF'
---
name: zz-spec020-trace
---
# Objective
plant
EOF
printf '%s\n' journal > "$LOOPS/$STEM.journal.md"
printf '%s\n' findings > "$LOOPS/$STEM.findings.md"
printf '%s\n' ledger > "$LOOPS/$STEM.ledger.md"

OUT=$(cd "$ROOT" && bash -c "$FENCE")
printf '%s\n' "$OUT" | grep -qx "$LOOPS/$STEM.md" \
  && pass_line "program file is listed" || fail_line "program file is listed"
printf '%s\n' "$OUT" | grep -q "$STEM.journal.md" \
  && fail_line "journal companion excluded" || pass_line "journal companion excluded"
printf '%s\n' "$OUT" | grep -q "$STEM.findings.md" \
  && fail_line "findings companion excluded" || pass_line "findings companion excluded"
printf '%s\n' "$OUT" | grep -q "$STEM.ledger.md" \
  && fail_line "ledger companion excluded" || pass_line "ledger companion excluded"

echo "craft-loop list exclude: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
