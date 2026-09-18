#!/usr/bin/env bash
# skills/debug/test.sh — CDT-258 static contract suite for the debug skill.
# Mirrors skills/bug-hunt/test.sh: frontmatter, name↔dir, path-resolution
# gate, skill-lint (C1–C5) gate, check-format gate on the cited SPEC, plus
# skill-specific structural asserts. Greps committed files only — no LLM.
# Run: bash skills/debug/test.sh
set -u

HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT=$(CDPATH= cd -- "$HERE/../.." && pwd)
SKILL="$HERE/SKILL.md"
CMD="$ROOT/commands/debug.md"
SPEC="$ROOT/specs/core/SPEC-014-debug-workflow.md"
LINT="$ROOT/skills/skill-lint/check-skill-bash.sh"
FMT="$ROOT/skills/spec-tooling/check-format.sh"
MARKER='self-verified — refuters unavailable'

PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); echo "PASS: $*"; }
bad() { FAIL=$((FAIL + 1)); echo "FAIL: $*"; }

has() {
  # has <file> <pattern> <label>
  local f="$1" pat="$2" label="$3"
  if grep -qE -- "$pat" "$f" 2>/dev/null; then ok "$label"
  else bad "$label (/$pat/ not in $f)"
  fi
}

has_f() {
  # has_f <file> <fixed-string> <label>
  local f="$1" s="$2" label="$3"
  if grep -qF -- "$s" "$f" 2>/dev/null; then ok "$label"
  else bad "$label (fixed string missing in $f)"
  fi
}

# ---- Surfaces present -------------------------------------------------------
if [ -f "$SKILL" ]; then ok "skills/debug/SKILL.md exists"; else bad "skills/debug/SKILL.md missing"; fi
if [ -n "$CMD" ]; then
  if [ -f "$CMD" ]; then ok "commands/debug.md exists"; else bad "commands/debug.md missing"; fi
fi
if [ -f "$SPEC" ]; then ok "specs/core/SPEC-014-debug-workflow.md exists"; else bad "specs/core/SPEC-014-debug-workflow.md missing"; fi

# ---- Frontmatter (YAML name + description) ----------------------------------
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
[ -n "$CMD" ] && [ -f "$CMD" ] && fm_ok "$CMD" "command"

# ---- name matches directory -------------------------------------------------
has "$SKILL" '^name:[[:space:]]*debug' "skill name: debug"
[ -n "$CMD" ] && has "$CMD" '^name:[[:space:]]*debug' "command name: debug"

# ---- PATH-RESOLUTION GATE: every referenced plugin path resolves -----------
# Conservative filter: only tokens with a file extension are checked, so prose
# tokens like "skills/code" are skipped on purpose.
path_gate() {
  local f="$1" label="$2" n=0 missing=0 ref
  while IFS= read -r ref; do
    [ -n "$ref" ] || continue
    n=$((n + 1))
    if [ ! -f "$ROOT/$ref" ]; then
      missing=$((missing + 1))
      echo "  unresolved: $ref"
    fi
  done < <(grep -oE '(skills|commands|agents)/[A-Za-z0-9_./-]+\.(md|sh|py|js|json)' "$f" | sort -u)
  if [ "$n" -eq 0 ]; then bad "$label path-resolution: no path refs found (want ≥1)"
  elif [ "$missing" -eq 0 ]; then ok "$label path-resolution: $n refs resolve"
  else bad "$label path-resolution: $missing of $n refs unresolved"
  fi
}
path_gate "$SKILL" "skill"
[ -n "$CMD" ] && path_gate "$CMD" "command"

# ---- debug structural contracts ---------------------------------------------
has_f "$SKILL" "$MARKER" "debug skill self-verified marker"
has_f "$SKILL" '/debug patch' "debug patch mode"
has_f "$SKILL" '/debug arch' "debug arch mode"
has_f "$SKILL" '/debug ticket' "debug ticket mode"
has_f "$SKILL" '## Step 2: Full mode' "debug Step 2 full"
has_f "$SKILL" '## Step 3: Patch mode' "debug Step 3 patch"
has_f "$SKILL" '## Step 4: Arch mode' "debug Step 4 arch"
has_f "$SKILL" '## Step 5: Ticket mode (SPEC-028)' "debug Step 5 ticket"
has_f "$SKILL" '## Root-cause triad' "debug root-cause triad"
has_f "$SKILL" 'SPEC-029' "debug cites SPEC-029 gates"
has_f "$SKILL" 'skills/fix-ticket/SKILL.md' "debug cites fix-ticket backend"
has_f "$SKILL" 'skills/debug/theme-status.sh' "debug cites theme-status.sh"
if [ -f "$HERE/theme-status.sh" ]; then ok "theme-status.sh exists"; else bad "theme-status.sh missing"; fi
has_f "$CMD" 'skills/debug/SKILL.md' "command points at skill"
has_f "$CMD" 'argument-hint:' "command argument-hint"

# ---- SKILL-LINT GATE (C1–C5; unwaived findings fail) ------------------------
if [ -f "$LINT" ]; then
  set +e
  if [ -n "$CMD" ]; then
    LINT_OUT=$(bash "$LINT" "$SKILL" "$CMD" 2>&1)
  else
    LINT_OUT=$(bash "$LINT" "$SKILL" 2>&1)
  fi
  LINT_RC=$?
  set -e
  if [ "$LINT_RC" -eq 0 ]; then
    ok "skill-lint clean (exit 0)"
  else
    bad "skill-lint exit $LINT_RC (want 0):"
    echo "$LINT_OUT" | head -20
  fi
else
  bad "check-skill-bash.sh missing"
fi

# ---- CHECK-FORMAT GATE (cited SPEC carries the 9 required sections) ---------
if [ -f "$FMT" ]; then
  set +e
  FMT_OUT=$(bash "$FMT" "$SPEC" 2>&1)
  FMT_RC=$?
  set -e
  if [ "$FMT_RC" -eq 0 ]; then
    ok "check-format exit 0 on cited SPEC"
  else
    bad "check-format exit $FMT_RC (want 0):"
    echo "$FMT_OUT" | head -20
  fi
else
  bad "check-format.sh missing"
fi

echo "PASS=$PASS FAIL=$FAIL"
if [ "$FAIL" -eq 0 ]; then
  exit 0
fi
exit 1
