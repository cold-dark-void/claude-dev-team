#!/usr/bin/env bash
# skills/brainstorm/test.sh — CDT-258 static contract suite for the brainstorm skill.
# Mirrors skills/bug-hunt/test.sh: frontmatter, name↔dir, path-resolution
# gate, skill-lint (C1–C5) gate, check-format gate on the cited SPEC, plus
# skill-specific structural asserts. Greps committed files only — no LLM.
# Run: bash skills/brainstorm/test.sh
set -u

HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT=$(CDPATH= cd -- "$HERE/../.." && pwd)
SKILL="$HERE/SKILL.md"
CMD=""
SPEC="$ROOT/specs/core/SPEC-021-skill-bash-lint-gate.md"
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
if [ -f "$SKILL" ]; then ok "skills/brainstorm/SKILL.md exists"; else bad "skills/brainstorm/SKILL.md missing"; fi
if [ -n "$CMD" ]; then
  if [ -f "$CMD" ]; then ok " exists"; else bad " missing"; fi
fi
if [ -f "$SPEC" ]; then ok "specs/core/SPEC-021-skill-bash-lint-gate.md exists"; else bad "specs/core/SPEC-021-skill-bash-lint-gate.md missing"; fi

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
has "$SKILL" '^name:[[:space:]]*brainstorm' "skill name: brainstorm"
[ -n "$CMD" ] && has "$CMD" '^name:[[:space:]]*brainstorm' "command name: brainstorm"

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

# ---- brainstorm structural contracts ----------------------------------------
# No self-verified marker in this skill; assert the Socratic contract instead.
has_f "$SKILL" 'Socratic' "brainstorm Socratic design refinement"
has_f "$SKILL" '--grill' "brainstorm --grill mode"
has_f "$SKILL" '## Step 1: Understand the problem (DO NOT SKIP)' "brainstorm Step 1 DO NOT SKIP"
has_f "$SKILL" '## Step 1-grill: One-question interview (grill mode only)' "brainstorm grill interview step"
has_f "$SKILL" '## Step 3: Design options' "brainstorm Step 3 design options"
has_f "$SKILL" '/kickoff' "brainstorm hands off to /kickoff"
has_f "$SKILL" 'skills/domain-glossary/SKILL.md' "brainstorm cites domain-glossary"
has_f "$SKILL" 'skills/backlog/SKILL.md' "brainstorm cites backlog"
has_f "$SKILL" 'SPEC-021' "brainstorm cites SPEC-021 (C1 re-resolve)"

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
