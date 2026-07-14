#!/usr/bin/env bash
# workflow-probe.sh — best-effort Workflow capability probe (CDV-196 / OQ1).
#
# Exit 0  → treat Workflow as available (optimistic; host may still fail later)
# Exit 1  → unavailable; caller MUST fall back to engine.sh Task path
#
# Exact "tool unavailable" shapes on free plan / CC < 2.1.154 are not yet
# empirically locked. Until then:
#   - COUNCIL_WORKFLOW_FORCE_FALLBACK=1 always fails the probe (test harness)
#   - Otherwise succeed; orchestrator still catches dispatch errors and falls back
#
# Stderr one-liner on fail is printed by the caller (commands/council.md), not here.

set -euo pipefail

if [ "${COUNCIL_WORKFLOW_FORCE_FALLBACK:-}" = "1" ]; then
  exit 1
fi

# Optional: reject obviously ancient installs if CLAUDE_CODE_VERSION is set and
# parseable as major.minor.patch below 2.1.154. Best-effort only — missing env
# does not fail the probe.
if [ -n "${CLAUDE_CODE_VERSION:-}" ]; then
  ver="${CLAUDE_CODE_VERSION#v}"
  IFS=. read -r maj min pat _ <<< "${ver}.0.0"
  maj=${maj:-0}; min=${min:-0}; pat=${pat%%[^0-9]*}
  pat=${pat:-0}
  if [ "$maj" -lt 2 ] 2>/dev/null || \
     { [ "$maj" -eq 2 ] && [ "$min" -lt 1 ]; } 2>/dev/null || \
     { [ "$maj" -eq 2 ] && [ "$min" -eq 1 ] && [ "$pat" -lt 154 ]; } 2>/dev/null; then
    exit 1
  fi
fi

exit 0
