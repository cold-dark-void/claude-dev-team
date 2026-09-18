#!/usr/bin/env bash
# skills/memory-store/test.sh — CDT-253 dispatcher contract + characterisation.
# Run: bash skills/memory-store/test.sh
set -u

HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT=$(CDPATH= cd -- "$HERE/../.." && pwd)
CMD="$ROOT/commands/memory.md"
STORE="$HERE/SKILL.md"
RECALL="$ROOT/skills/memory-recall/SKILL.md"
COMPRESS="$ROOT/skills/memory-compress/SKILL.md"
VALIDATE="$ROOT/skills/validate-memory/SKILL.md"
PIPELINE="$ROOT/skills/validate-memory/pipeline.md"
LINT="$ROOT/skills/skill-lint/check-skill-bash.sh"
CHAR="$HERE/characterisation-test.sh"

PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); echo "PASS: $*"; }
bad() { FAIL=$((FAIL + 1)); echo "FAIL: $*"; }

has_f() {
  local f="$1" s="$2" label="$3"
  if grep -qF -- "$s" "$f" 2>/dev/null; then ok "$label"
  else bad "$label (fixed string missing in $f)"
  fi
}

flagged() {
  local f="$1" label="$2"
  if grep -E '^user-invocable:[[:space:]]*(false|"false")[[:space:]]*$' "$f" >/dev/null; then
    ok "$label user-invocable: false"
  else
    bad "$label missing user-invocable: false"
  fi
}

# ---- Surfaces ----
for f in "$CMD" "$STORE" "$RECALL" "$COMPRESS" "$VALIDATE" \
         "$HERE/config.md" "$HERE/distill.md" "$HERE/export.md" "$HERE/stats.md" \
         "$PIPELINE"; do
  if [ -f "$f" ]; then ok "exists ${f#$ROOT/}"
  else bad "missing ${f#$ROOT/}"
  fi
done

flagged "$STORE" "memory-store"
flagged "$RECALL" "memory-recall"
flagged "$COMPRESS" "memory-compress"
flagged "$VALIDATE" "validate-memory"

# ---- Command is the thin host (<150 lines) ----
cmd_lines=$(wc -l < "$CMD")
if [ "$cmd_lines" -lt 150 ]; then
  ok "command under 150 lines ($cmd_lines)"
else
  bad "command $cmd_lines lines (want <150)"
fi

has_f "$CMD" 'skills/memory-store/config.md' "command routes config"
has_f "$CMD" 'skills/memory-store/distill.md' "command routes distill"
has_f "$CMD" 'skills/memory-store/export.md' "command routes export"
has_f "$CMD" 'skills/memory-recall/SKILL.md' "command routes search"
has_f "$CMD" 'skills/memory-store/stats.md' "command routes stats"
has_f "$CMD" 'skills/validate-memory/SKILL.md' "command routes validate"
has_f "$CMD" 'Loaded memory protocol:' "command PDH load echo"
has_f "$CMD" 'Read `$SKILL`' "command Read-skill step"
has_f "$CMD" '## Step 0: Resolve skill' "command Step 0 PDH"

if grep -qF 'Per-agent stats' "$CMD"; then
  bad "command still contains stats gather (engine not extracted)"
else
  ok "command does not contain stats gather"
fi
if grep -qF '## Step 4a: Tier A verification' "$CMD"; then
  bad "command still contains validate Tier A (engine not extracted)"
else
  ok "command does not contain validate pipeline"
fi
if grep -qF 'echo "Memory DB:' "$CMD"; then
  bad "command still contains search --status fence"
else
  ok "command does not contain search --status fence"
fi

has_f "$HERE/stats.md" 'Per-agent stats' "stats.md owns gather fence"
has_f "$RECALL" 'echo "Memory DB:' "memory-recall owns --status"
has_f "$PIPELINE" '## Step 4a: Tier A verification' "pipeline.md owns validate host"
has_f "$VALIDATE" 'pipeline.md' "validate SKILL cites pipeline.md"
has_f "$HERE/distill.md" 'skills/validate-memory/pipeline.md' "distill cites validate pipeline"
has_f "$HERE/distill.md" 'skills/memory-compress/SKILL.md' "distill cites compress"

# ---- skill-lint (C1–C5; unwaived findings fail) ----
if [ -f "$LINT" ]; then
  LINT_OUT=$(bash "$LINT" \
    "$CMD" "$STORE" "$RECALL" "$COMPRESS" "$VALIDATE" \
    "$HERE/config.md" "$HERE/distill.md" "$HERE/export.md" "$HERE/stats.md" \
    "$PIPELINE" 2>&1)
  LINT_RC=$?
  if [ "$LINT_RC" -eq 0 ]; then
    ok "skill-lint clean (exit 0)"
  else
    bad "skill-lint exit $LINT_RC (want 0):"
    echo "$LINT_OUT" | head -30
  fi
else
  bad "check-skill-bash.sh missing"
fi

# ---- Characterisation (stats + search output vs fixture DB) ----
if [ -f "$CHAR" ]; then
  CHAR_OUT=$(bash "$CHAR" 2>&1)
  CHAR_RC=$?
  echo "$CHAR_OUT"
  if [ "$CHAR_RC" -eq 0 ]; then
    ok "characterisation-test.sh exit 0"
  else
    bad "characterisation-test.sh exit $CHAR_RC"
  fi
else
  bad "characterisation-test.sh missing"
fi

echo ""
echo "memory-store dispatch tests: $PASS pass / $FAIL fail"
if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
exit 0
