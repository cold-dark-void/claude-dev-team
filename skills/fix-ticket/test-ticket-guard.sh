#!/usr/bin/env bash
# CDT-392 + W3-15: ticket id, dotted slug, non-git --worktree, same-day report.
# Fails on the old skill: no ticket-guard.sh, ensure gets the raw dotted id,
# --worktree is only `[ -d ]`, Step 7 does not assign TICKET, reports overwrite.
set -u

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
GUARD="$ROOT/skills/fix-ticket/ticket-guard.sh"
SKILL="$ROOT/skills/fix-ticket/SKILL.md"
pass=0
fail=0

ok() { pass=$((pass + 1)); echo "OK: $*"; }
bad() { fail=$((fail + 1)); echo "FAIL: $*"; }

if [ -f "$GUARD" ]; then
  ok "ticket-guard.sh exists"
else
  bad "ticket-guard.sh missing"
  echo "PASS=$pass FAIL=$fail"
  exit 1
fi

if bash -n "$GUARD"; then
  ok "ticket-guard.sh parses"
else
  bad "ticket-guard.sh bash -n"
fi

# Planted negative: the old `[ -d ]`-only check accepts a non-git directory.
neg="$(mktemp -d "${TMPDIR:-/tmp}/ticket-guard-neg.XXXXXX")"
if [ -d "$neg" ]; then
  ok "control: a non-git directory still passes [ -d ]"
else
  bad "control: negative directory missing"
fi

out="$(bash "$GUARD" validate '../x' 2>"$neg/err")"
rc=$?
if [ "$rc" -ne 0 ] && grep -q 'invalid ticket id' "$neg/err"; then
  ok "validate rejects ../x (rc=$rc)"
else
  bad "validate accepted ../x (rc=$rc)"
fi

out="$(bash "$GUARD" validate 'AUDIT-P0.8' 2>"$neg/err")"
rc=$?
if [ "$rc" -eq 0 ] && [ "$out" = "AUDIT-P0.8" ]; then
  ok "validate accepts a dotted id"
else
  bad "validate rejected AUDIT-P0.8 (rc=$rc out=$out)"
fi

out="$(bash "$GUARD" slug 'AUDIT-P0.8' 2>"$neg/err")"
rc=$?
if [ "$rc" -eq 0 ] && [ "$out" = "AUDIT-P0-8" ]; then
  ok "slug maps AUDIT-P0.8 to AUDIT-P0-8"
else
  bad "slug did not sanitize the dot (rc=$rc out=$out)"
fi

out="$(bash "$GUARD" slug '../x' 2>"$neg/err")"
rc=$?
if [ "$rc" -ne 0 ]; then
  ok "slug rejects ../x"
else
  bad "slug accepted ../x ($out)"
fi

if bash "$GUARD" check-worktree "$neg" >/dev/null 2>"$neg/err"; then
  bad "check-worktree accepted a non-git directory"
else
  if grep -q 'not a git worktree' "$neg/err"; then
    ok "check-worktree rejects a non-git directory"
  else
    bad "check-worktree failed without the git-worktree error"
  fi
fi

git_root="$(git -C "$ROOT" rev-parse --show-toplevel 2>/dev/null || true)"
if [ -n "$git_root" ] && bash "$GUARD" check-worktree "$git_root" >/dev/null 2>"$neg/err"; then
  ok "check-worktree accepts a git work tree"
else
  bad "check-worktree rejected the repo work tree"
fi

rep="$(mktemp -d "${TMPDIR:-/tmp}/ticket-guard-rep.XXXXXX")"
base="$(bash "$GUARD" report-path "$rep" 2026-10-01 CDT-392)"
if [ "$base" = "$rep/2026-10-01-CDT-392.md" ]; then
  ok "report-path uses the date-ticket name when free"
else
  bad "report-path base was $base"
fi
printf 'x\n' > "$base" || { bad "could not plant the existing report"; }
second="$(bash "$GUARD" report-path "$rep" 2026-10-01 CDT-392)"
if [ "$second" = "$rep/2026-10-01-CDT-392-2.md" ] && [ "$second" != "$base" ]; then
  ok "report-path suffixes a same-day collision"
else
  bad "same-day report was not suffixed ($second)"
fi
printf 'x\n' > "$second"
third="$(bash "$GUARD" report-path "$rep" 2026-10-01 CDT-392)"
if [ "$third" = "$rep/2026-10-01-CDT-392-3.md" ]; then
  ok "report-path advances the suffix"
else
  bad "suffix did not advance ($third)"
fi

if bash "$GUARD" report-path "$rep" '../2026' CDT-392 >/dev/null 2>"$neg/err"; then
  bad "report-path accepted a bad date"
else
  ok "report-path rejects a bad date"
fi

# Skill wiring. These strings are absent before the fix.
if grep -qF 'skills/fix-ticket/ticket-guard.sh' "$SKILL" \
  && grep -qF 'check-worktree' "$SKILL" \
  && grep -qF 'report-path' "$SKILL"; then
  ok "SKILL.md calls ticket-guard validate, check-worktree, and report-path"
else
  bad "SKILL.md does not call ticket-guard.sh"
fi
if grep -qF 'TICKET="<TICKET>"' "$SKILL"; then
  ok "SKILL.md re-resolves TICKET inside the fence"
else
  bad "SKILL.md Step fences do not assign TICKET"
fi
if grep -qF 'ensure "$SLUG"' "$SKILL" && grep -qF 'slug' "$SKILL"; then
  ok "ensure receives the sanitized slug"
else
  bad "ensure still receives the raw ticket id"
fi
# The old check was a bare directory test with no git rev-parse.
if grep -qF 'rev-parse --is-inside-work-tree' "$SKILL" \
  || grep -qF 'check-worktree' "$SKILL"; then
  ok "user --worktree is a git worktree check, not only [ -d ]"
else
  bad "--worktree is still only [ -d ]"
fi

rm -rf "$neg" "$rep"
echo "PASS=$pass FAIL=$fail"
[ "$fail" -eq 0 ]
