#!/usr/bin/env bash
# Digit vars and status ordering for check-template-vars.sh (PF-check-template-vars).
# A {{TOOL2}} declared in the prompt table must fail the checker when the
# substitution block omits it, and pass when the block includes it.
set -u

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CHECK="$ROOT/skills/council/check-template-vars.sh"
GEN="$ROOT/skills/council/gen-template-vars.sh"
fail=0

TMP="$(mktemp -d "${TMPDIR:-/tmp}/tpl-vars.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

write_tree() {  # <include-tool2: yes|no>
  local inc="$1"
  rm -rf "$TMP/tree"
  mkdir -p "$TMP/tree/commands" "$TMP/tree/skills/council/prompts"
  cat > "$TMP/tree/skills/council/prompts/toy.md" <<'EOF'
# toy

## Variables

| Variable | Type | Source |
|---|---|---|
| `{{NAME}}` | string | engine |
| `{{TOOL2}}` | string | engine — second tool |

## Output
EOF
  if [ "$inc" = yes ]; then
    cat > "$TMP/tree/commands/council.md" <<'EOF'
prompt: skills/council/prompts/toy.md
  with substitutions:
    {{NAME}}
    {{TOOL2}}
```
EOF
    cat > "$TMP/tree/skills/council/SKILL.md" <<'EOF'
| `toy.md` | `{{NAME}}`, `{{TOOL2}}` |
EOF
  else
    cat > "$TMP/tree/commands/council.md" <<'EOF'
prompt: skills/council/prompts/toy.md
  with substitutions:
    {{NAME}}
```
EOF
    cat > "$TMP/tree/skills/council/SKILL.md" <<'EOF'
| `toy.md` | `{{NAME}}` |
EOF
  fi
}

run_check() {
  COUNCIL_TEMPLATE_ROOT="$TMP/tree" COUNCIL_TEMPLATE_COVERED="toy" \
    bash "$CHECK"
}

write_tree no
set +e
out="$(run_check 2>&1)"
rc=$?
set -e
if [ "$rc" -eq 1 ] && printf '%s\n' "$out" | grep -q '{{TOOL2}}'; then
  echo "OK: omitted {{TOOL2}} fails the checker"
else
  echo "FAIL: omitted {{TOOL2}} rc=$rc out=$out"; fail=1
fi

write_tree yes
set +e
out="$(run_check 2>&1)"
rc=$?
set -e
if [ "$rc" -eq 0 ] && printf '%s\n' "$out" | grep -q 'PASS:'; then
  echo "OK: included {{TOOL2}} passes the checker"
else
  echo "FAIL: included {{TOOL2}} rc=$rc out=$out"; fail=1
fi

# Generator is the reader. It must print the digit var.
gvars="$(bash "$GEN" vars "$TMP/tree/skills/council/prompts/toy.md")"
if printf '%s\n' "$gvars" | grep -qx '{{TOOL2}}' && printf '%s\n' "$gvars" | grep -qx '{{NAME}}'; then
  echo "OK: generator prints {{TOOL2}}"
else
  echo "FAIL: generator vars: $gvars"; fail=1
fi

# A structural miss (status 2) must survive a later drift (status 1).
write_tree no
rm -f "$TMP/tree/skills/council/prompts/missing.md"
set +e
out="$(COUNCIL_TEMPLATE_ROOT="$TMP/tree" COUNCIL_TEMPLATE_COVERED="missing toy" bash "$CHECK" 2>&1)"
rc=$?
set -e
if [ "$rc" -eq 2 ]; then
  echo "OK: status 2 is not overwritten by a later drift"
else
  echo "FAIL: max status rc=$rc (want 2) out=$out"; fail=1
fi

if [ "$fail" -eq 0 ]; then echo "ALL PASS"; else echo "FAILURES PRESENT"; fi
exit "$fail"
