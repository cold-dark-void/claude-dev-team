#!/usr/bin/env bash
# W3-15: quoted YAML, no live placeholders in comments, check-template-vars covers the report.
set -u

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CHECK="$ROOT/skills/fix-ticket/check-template-vars.sh"
TPL="$ROOT/skills/fix-ticket/templates/report.md"
pass=0
fail=0
ok() { pass=$((pass + 1)); echo "OK: $*"; }
bad() { fail=$((fail + 1)); echo "FAIL: $*"; }

if [ -f "$CHECK" ] && bash -n "$CHECK"; then
  ok "check-template-vars.sh parses"
else
  bad "check-template-vars.sh missing or does not parse"
  echo "PASS=$pass FAIL=$fail"
  exit 1
fi

# Planted negative: an extra body var and an HTML-comment var must fail the gate.
neg="$(mktemp -d "${TMPDIR:-/tmp}/fix-ticket-tpl.XXXXXX")"
cp "$TPL" "$neg/report.md"
printf '\n{{NOT_A_REAL_VAR}}\n<!-- {{ALSO_COMMENT}} -->\n' >> "$neg/report.md"
if FIX_TICKET_TEMPLATE="$neg/report.md" bash "$CHECK" >"$neg/out" 2>"$neg/err"; then
  bad "control: checker accepted a planted extra var"
else
  if grep -q 'NOT_A_REAL_VAR\|HTML comment' "$neg/err"; then
    ok "control: checker rejects a planted var"
  else
    bad "control: checker failed without naming the plant"
  fi
fi
rm -rf "$neg"

if grep -qE '^ticket: "\{\{TICKET\}\}"$' "$TPL" && grep -qE '^worktree: "\{\{WORKTREE\}\}"$' "$TPL"; then
  ok "report YAML quotes ticket and worktree"
else
  bad "report YAML ticket or worktree is unquoted"
fi

if bash "$CHECK"; then
  ok "check-template-vars covers the report template"
else
  bad "check-template-vars failed on the report template"
fi

echo "PASS=$pass FAIL=$fail"
[ "$fail" -eq 0 ]
