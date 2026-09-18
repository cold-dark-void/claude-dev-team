#!/usr/bin/env bash
# skills/retro/test.sh — CDT-252 static contract + characterisation.
# Run: bash skills/retro/test.sh
set -u

HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT=$(CDPATH= cd -- "$HERE/../.." && pwd)
SKILL="$HERE/SKILL.md"
CMD="$ROOT/commands/retro.md"
SPEC="$ROOT/specs/core/SPEC-012-session-retrospective.md"
LINT="$ROOT/skills/skill-lint/check-skill-bash.sh"
CHAR="$HERE/characterisation-test.sh"

PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); echo "PASS: $*"; }
bad() { FAIL=$((FAIL + 1)); echo "FAIL: $*"; }

has() {
  local f="$1" pat="$2" label="$3"
  if grep -qE -- "$pat" "$f" 2>/dev/null; then ok "$label"
  else bad "$label (/$pat/ not in $f)"
  fi
}

has_f() {
  local f="$1" s="$2" label="$3"
  if grep -qF -- "$s" "$f" 2>/dev/null; then ok "$label"
  else bad "$label (fixed string missing in $f)"
  fi
}

# ---- Surfaces ----
if [ -f "$SKILL" ]; then ok "skills/retro/SKILL.md exists"; else bad "skills/retro/SKILL.md missing"; fi
if [ -f "$CMD" ]; then ok "commands/retro.md exists"; else bad "commands/retro.md missing"; fi
if [ -f "$SPEC" ]; then ok "SPEC-012 exists"; else bad "SPEC-012 missing"; fi

# ---- Frontmatter ----
fm_ok() {
  local f="$1" label="$2"
  if awk '
    BEGIN { in_fm=0; has_name=0; has_desc=0; closed=0 }
    NR==1 && $0=="---" { in_fm=1; next }
    in_fm && $0=="---" { closed=1; exit }
    in_fm && /^name:[[:space:]]/ { has_name=1 }
    in_fm && /^description:[[:space:]]/ { has_desc=1 }
    END { exit (closed && has_name && has_desc) ? 0 : 1 }
  ' "$f"; then
    ok "$label frontmatter name+description"
  else
    bad "$label missing YAML frontmatter (name/description)"
  fi
}
[ -f "$SKILL" ] && fm_ok "$SKILL" "skill"
[ -f "$CMD" ] && fm_ok "$CMD" "command"
has "$SKILL" '^name:[[:space:]]*retro' "skill name: retro"
has "$CMD" '^name:[[:space:]]*retro' "command name: retro"

# ---- user-invocable: false (CDT-248/251 — new skill must be flagged) ----
if grep -E '^user-invocable:[[:space:]]*(false|"false")[[:space:]]*$' "$SKILL" >/dev/null; then
  ok "skill user-invocable: false"
else
  bad "skill missing user-invocable: false in frontmatter"
fi

# ---- Command is the thin host (<150 lines) ----
cmd_lines=$(wc -l < "$CMD")
if [ "$cmd_lines" -lt 150 ]; then
  ok "command under 150 lines ($cmd_lines)"
else
  bad "command $cmd_lines lines (want <150)"
fi

has_f "$CMD" 'skills/retro/SKILL.md' "command resolves skills/retro/SKILL.md"
has_f "$CMD" 'Loaded retro protocol:' "command PDH load echo"
has_f "$CMD" 'Read `$SKILL`' "command Read-skill step"
has "$CMD" '## Step 0: Resolve skill' "command Step 0 PDH"
has_f "$SKILL" '## Step 3: Phase-1 gate' "skill owns Phase-1 gate"
if grep -qF '## Step 3: Phase-1 gate' "$CMD"; then
  bad "command still contains Phase-1 gate (engine not extracted)"
else
  ok "command does not contain Phase-1 gate"
fi
has_f "$SKILL" 'skills/retro-gate/gate.sh' "skill still calls retro-gate"
has_f "$SKILL" 'skills/retro-subagent/SKILL.md' "skill still cites retro-subagent"

# ---- skill-lint (C1–C5; unwaived findings fail) ----
if [ -f "$LINT" ]; then
  LINT_OUT=$(bash "$LINT" "$SKILL" "$CMD" 2>&1)
  LINT_RC=$?
  if [ "$LINT_RC" -eq 0 ]; then
    ok "skill-lint clean (exit 0)"
  else
    bad "skill-lint exit $LINT_RC (want 0):"
    echo "$LINT_OUT" | head -20
  fi
else
  bad "check-skill-bash.sh missing"
fi

# ---- Characterisation (byte-identical gate-path vs fixture session) ----
if [ -x "$CHAR" ] || [ -f "$CHAR" ]; then
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
echo "retro tests: $PASS pass / $FAIL fail"
if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
exit 0
