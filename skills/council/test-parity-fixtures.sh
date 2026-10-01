#!/usr/bin/env bash
# F-29: parity fixtures are wired. false-claim stays false; true-claim stays true.
# diff-mode.md stays (test-workflow-static.sh references it) and does not claim
# to be the preset file.
set -u

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PAR="$ROOT/skills/council/fixtures/parity"
fail=0
cd "$ROOT"

ok() { echo "OK: $1"; }
bad() { echo "FAIL: $1"; fail=1; }

claim="$(jq -r .claim "$PAR/false-claim.json")"
if printf '%s' "$claim" | grep -q 'exponential backoff' \
  && ! grep -q 'exponential backoff' commands/retro.md; then
  ok "false-claim premise: retro.md has no exponential backoff"
else
  bad "false-claim fixture no longer matches commands/retro.md"
fi

true_claim="$(jq -r .claim "$PAR/true-claim.json")"
if printf '%s' "$true_claim" | grep -q 'tools:' \
  && grep -q 'tools: ""' agents/council-judge.md; then
  ok "true-claim premise: council-judge tools are empty"
else
  bad "true-claim fixture no longer matches agents/council-judge.md"
fi

if grep -q '^diff --git' "$PAR/mini-diff.patch"; then
  ok "mini-diff.patch is a unified diff"
else
  bad "mini-diff.patch is not a diff"
fi

note="skills/council/flavors/diff-mode.md"
if [ -f "$note" ] \
  && grep -qF 'Presets are not files' "$note" \
  && grep -qF 'Phase 7 is DEFERRED' "$note" \
  && grep -qF 'does not write lessons.md' "$note" \
  && grep -qF 'skills/council/flavors/diff-mode.md' skills/council/test-workflow-static.sh; then
  ok "diff-mode.md is a note, not a preset file, and the static test still references it"
else
  bad "diff-mode.md missing, still a preset, or no longer referenced"
fi

if grep -q 'flavors/diff-mode.md' skills/council/engine.sh skills/council/workflow.js; then
  bad "engine or workflow loads flavors/diff-mode.md"
else
  ok "engine and workflow do not load flavors/diff-mode.md"
fi

if [ "$fail" -eq 0 ]; then echo "ALL PASS"; else echo "FAILURES PRESENT"; fi
exit "$fail"
