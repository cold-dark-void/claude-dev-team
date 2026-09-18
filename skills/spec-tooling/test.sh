#!/usr/bin/env bash
# skills/spec-tooling/test.sh — CDT-258/CDT-254 static contract suite.
# Mirrors skills/memory-store/test.sh: dispatcher + partials + PDH + skill-lint.
# Greps committed files only — no LLM.
# Run: bash skills/spec-tooling/test.sh
set -u

HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT=$(CDPATH= cd -- "$HERE/../.." && pwd)
SKILL="$HERE/SKILL.md"
CMD="$ROOT/commands/spec.md"
BH="$ROOT/commands/bug-hunt.md"
SPEC="$ROOT/specs/core/SPEC-008-spec-management.md"
LINT="$ROOT/skills/skill-lint/check-skill-bash.sh"
FMT="$ROOT/skills/spec-tooling/check-format.sh"

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

missing_f() {
  local f="$1" s="$2" label="$3"
  if grep -qF -- "$s" "$f" 2>/dev/null; then bad "$label (still in $f)"
  else ok "$label"
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

# ---- Surfaces present -------------------------------------------------------
for f in "$SKILL" "$CMD" "$SPEC" "$HERE/check.md" "$HERE/create.md" \
         "$HERE/find.md" "$HERE/list.md" "$HERE/update.md" \
         "$HERE/check-format.sh" "$HERE/spec-skeleton.md" "$HERE/source-exclude.md"; do
  if [ -f "$f" ]; then ok "exists ${f#$ROOT/}"
  else bad "missing ${f#$ROOT/}"
  fi
done

flagged "$SKILL" "spec-tooling"

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
fm_ok "$SKILL" "skill"
fm_ok "$CMD" "command"

has "$SKILL" '^name:[[:space:]]*spec-tooling' "skill name: spec-tooling"
has "$CMD" '^name:[[:space:]]*spec' "command name: spec"

# ---- Command is the thin host (<150 lines) ----------------------------------
cmd_lines=$(wc -l < "$CMD")
if [ "$cmd_lines" -lt 150 ]; then
  ok "command under 150 lines ($cmd_lines)"
else
  bad "command $cmd_lines lines (want <150)"
fi

has_f "$CMD" 'skills/spec-tooling/check.md' "command routes check"
has_f "$CMD" 'skills/spec-tooling/create.md' "command routes create"
has_f "$CMD" 'skills/spec-tooling/find.md' "command routes find"
has_f "$CMD" 'skills/spec-tooling/list.md' "command routes list"
has_f "$CMD" 'skills/spec-tooling/update.md' "command routes update"
has_f "$CMD" 'skills/spec-tooling/SKILL.md' "command routes generate/tests/reflect"
has_f "$CMD" 'Loaded spec protocol:' "command PDH load echo"
has_f "$CMD" 'Read `$SKILL`' "command Read-skill step"
has_f "$CMD" '## Step 0: Resolve skill (PDH)' "command Step 0 PDH"

# bug-hunt PDH stanza copied verbatim (the PDH= assignment line)
if [ -f "$BH" ]; then
  pdh_bh=$(grep -E '^PDH=\$\(' "$BH" | head -1)
  pdh_spec=$(grep -E '^PDH=\$\(' "$CMD" | head -1)
  if [ -n "$pdh_bh" ] && [ "$pdh_bh" = "$pdh_spec" ]; then
    ok "PDH assignment identical to bug-hunt"
  else
    bad "PDH assignment differs from bug-hunt"
  fi
else
  bad "commands/bug-hunt.md missing (PDH verbatim check)"
fi

# ---- Command no longer hosts the five inline bodies -------------------------
missing_f "$CMD" 'Phase 1: Format & Index Checks' "command does not contain check Phase 1"
missing_f "$CMD" 'Step 2.5: Conflict Scan' "command does not contain create conflict scan"
missing_f "$CMD" 'Multiple search terms are ANDed together' "command does not contain find AND tip"
missing_f "$CMD" 'ORPHANS** (governed file not in TDD.md Spec Index)' "command does not contain list orphan row"
missing_f "$CMD" 'Step 4.5: Code Alignment Warning' "command does not contain update code-impact"
missing_f "$CMD" '<!-- include: skills/spec-tooling/source-exclude.md agent=spec -->' \
  "command does not include source-exclude"
missing_f "$CMD" '<!-- include: skills/spec-tooling/spec-skeleton.md agent=spec -->' \
  "command does not include spec-skeleton"

# ---- Moved subcommands keep protocol (behaviour-preserving) -----------------
has_f "$HERE/check.md" 'Phase 1: Format & Index Checks' "check.md owns Phase 1"
has_f "$HERE/check.md" 'GATE FAIL: Y MISSING exceeds threshold N' "check.md owns Phase 3 gate"
has_f "$HERE/check.md" 'P3-M2' "check.md owns P3-M2 tag convention"
has "$HERE/check.md" 'include: skills/spec-tooling/source-exclude.md agent=spec' \
  "check.md includes source-exclude"
n_ex=$(grep -cF 'include: skills/spec-tooling/source-exclude.md agent=spec' "$HERE/check.md" 2>/dev/null || echo 0)
if [ "$n_ex" -eq 2 ]; then ok "check.md source-exclude include count=2"
else bad "check.md source-exclude include count=$n_ex (want 2)"
fi

has_f "$HERE/create.md" 'Step 2.5: Conflict Scan' "create.md owns conflict scan"
has_f "$HERE/create.md" 'Render the literal `<STATUS>` token as `DRAFT`' "create.md emits DRAFT"
has_f "$HERE/create.md" '<!-- include: skills/spec-tooling/spec-skeleton.md agent=spec -->' \
  "create.md includes spec-skeleton"

has_f "$HERE/find.md" 'Multiple search terms are ANDed together' "find.md owns AND tip"
has_f "$HERE/find.md" 'Glob $MROOT/specs/**/*.md' "find.md uses category-agnostic glob"

has_f "$HERE/list.md" 'ORPHANS** (governed file not in TDD.md Spec Index)' "list.md owns orphan flag"
has_f "$HERE/list.md" '## Spec Overview' "list.md owns overview format"

has_f "$HERE/update.md" 'Step 4.5: Code Alignment Warning' "update.md owns code-impact"
has_f "$HERE/update.md" 'CODE CONTRADICTS' "update.md owns CODE CONTRADICTS"
has_f "$HERE/update.md" '<!-- include: skills/spec-tooling/source-exclude.md agent=spec -->' \
  "update.md includes source-exclude"

# generate/tests/reflect stay in SKILL.md
has_f "$SKILL" '/spec generate' "spec-tooling generate mode"
has_f "$SKILL" '/spec tests' "spec-tooling tests mode"
has_f "$SKILL" '/spec reflect' "spec-tooling reflect mode"
has_f "$SKILL" 'SPEC-008' "spec-tooling cites SPEC-008"
has_f "$SKILL" 'commands/spec.md' "spec-tooling cites commands/spec.md"
has "$SKILL" '@tech-lead' "spec-tooling references @tech-lead"
has_f "$SKILL" '## Shared assets (this directory)' "spec-tooling shared assets section"
has_f "$SKILL" 'check-format.sh' "spec-tooling hosts check-format.sh"

# ---- PATH-RESOLUTION GATE ---------------------------------------------------
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
path_gate "$CMD" "command"
for p in check create find list update; do
  path_gate "$HERE/$p.md" "$p.md"
done

# ---- SKILL-LINT GATE (C1–C5; unwaived findings fail) ------------------------
if [ -f "$LINT" ]; then
  set +e
  LINT_OUT=$(bash "$LINT" \
    "$SKILL" "$CMD" \
    "$HERE/check.md" "$HERE/create.md" "$HERE/find.md" \
    "$HERE/list.md" "$HERE/update.md" 2>&1)
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

# ---- CHECK-FORMAT GATE ------------------------------------------------------
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
