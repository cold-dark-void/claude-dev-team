#!/usr/bin/env bash
# WP 2-02 (CDT-286 [08 F16], rv-w1-14) — a value flag with no value must exit 2
# at once, never hang and never exit 1 with no message.
#
# engine.sh and external-reviewer.sh parse `X="${2:-}"; shift 2`. With one
# argument left, `shift 2` fails without shifting; under `set -e` the script
# then exits 1 with no output. This suite runs each flag of each subcommand as
# the last argument (tests/lib/trailing-flag.sh) and expects exit 2, the
# engine's usage exit code (engine.sh --help: "2 usage/no-scope").
# Standalone: bash skills/council/test-trailing-flag.sh
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
ENGINE="$ROOT/skills/council/engine.sh"
EXTREV="$ROOT/skills/council/external-reviewer.sh"

# shellcheck source=../../tests/lib/hermetic.sh
. "$ROOT/tests/lib/hermetic.sh"
# shellcheck source=../../tests/lib/check.sh
. "$ROOT/tests/lib/check.sh"
# shellcheck source=../../tests/lib/trailing-flag.sh
. "$ROOT/tests/lib/trailing-flag.sh"
hermetic_init
pass=0
fail=0

# probe_case <label> <want-flag-count> <script> <want-rc> <fn|-> [pre-arg...]
probe_case() {
  local label="$1" wantn="$2" want_rc="$4"
  shift 2
  trailing_flag_scan "$@"
  if [ "$TF_SKIP" = "1" ]; then
    pass_line "$label: skipped, no timeout command"
    return 0
  fi
  if [ "$TF_N" = "$wantn" ]; then
    pass_line "$label: $wantn value flags probed"
  else
    fail_line "$label: want $wantn value flags, probed $TF_N"
  fi
  if [ -z "$TF_BAD" ]; then
    pass_line "$label: each value flag with no value exits $want_rc"
  else
    fail_line "$label: trailing flag (flag=rc):$TF_BAD"
  fi
}

# engine.sh needs a git repo for MROOT; keep it inside the hermetic root.
REPO="$HERMETIC_ROOT/repo"
mkdir -p "$REPO"
git init -q "$REPO"
cd "$REPO" || exit 1

# --external takes an optional value (`--external` alone is valid).
# rv-w3-39/L-10: engine.sh is a dispatcher — the probe runs against a hermetic
# combined copy (engine.sh with its source lines replaced by the inlined
# helper bodies) so the flag scan sees the function bodies AND the dispatch.
ENGINE_PROBE="$HERMETIC_ROOT/engine-probe.sh"
# Helper bodies first, then engine.sh (minus its source lines) so the
# functions are defined before the dispatch case runs.
cat "$ROOT/skills/council/engine-util.sh" \
  "$ROOT/skills/council/engine-report-path.sh" \
  "$ROOT/skills/council/engine-preflight.sh" \
  "$ROOT/skills/council/engine-finalize.sh" > "$ENGINE_PROBE"
sed '/^\. "\$SCRIPT_DIR\/engine-/d' "$ENGINE" >> "$ENGINE_PROBE"
TF_EXEMPT="--external" probe_case "engine preflight" 7 "$ENGINE_PROBE" 2 cmd_preflight preflight
probe_case "engine finalize" 11 "$ENGINE_PROBE" 2 cmd_finalize finalize
probe_case "engine resolve-task-id" 1 "$ENGINE_PROBE" 2 cmd_resolve_task_id resolve-task-id
probe_case "engine report-path" 1 "$ENGINE_PROBE" 2 cmd_report_path report-path some-slug
probe_case "external-reviewer detect" 1 "$EXTREV" 2 cmd_detect detect
probe_case "external-reviewer normalize" 4 "$EXTREV" 2 cmd_normalize normalize
probe_case "external-reviewer run" 5 "$EXTREV" 2 cmd_run run

echo
echo "PASS=$pass FAIL=$fail"
[ "$fail" -eq 0 ]
