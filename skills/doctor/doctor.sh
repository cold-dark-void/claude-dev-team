#!/usr/bin/env bash
# doctor.sh — install & config diagnostics (SPEC-022 / CDV-191)
#
# Usage: doctor.sh [--json] [--fix] [--force] [--only <id|group>] [--gate=<orchestration|team>] [-h|--help]
# Exit: 0 all PASS · 1 ≥1 WARN no FAIL · 2 ≥1 FAIL · 64 usage
# Under --gate: self-remediating FAILs (exact fixit match) do not contribute to exit 2 (SPEC-022 M6c)
#
# THIS SCRIPT IS A SUBPROCESS CLI — NEVER SOURCE IT.
# Read-only by default. --fix applies only the allowlisted repairs.

set -euo pipefail

DOCTOR_SCHEMA="1"
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
PLUGIN_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/../.." && pwd)

JSON_MODE=0
FIX_MODE=0
FIX_FORCE=0
ONLY_FILTER=""
GATE=""
USAGE_ERR=0

# ---------------------------------------------------------------------------
# Arg parse
# ---------------------------------------------------------------------------
usage() {
  cat <<'EOF' >&2
Usage: doctor.sh [--json] [--fix] [--force] [--only <check-id|group>] [--gate=<orchestration|team>] [-h|--help]

  --json              Emit single JSON document on stdout (diagnostics on stderr)
  --fix               Apply allowlisted repairs only (stale distilling_lock, STALE .wt-lock, handoff *.tmp)
  --force             With --fix, also clear a fresh distilling_lock
  --only <id|group>   Run a subset of checks
  --gate=<orchestration|team>
                      Gate-mode self-remediation (CDT-67 / M6c): FAILs whose
                      fixit exactly equals /setup <gate> stay FAIL but do not
                      count toward exit 2 (exit 1 when only waived FAILs/WARNs)
  -h, --help          Show this help

Exit codes: 0=all PASS  1=WARN only (or waived FAILs under --gate)  2=FAIL  64=usage
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --json) JSON_MODE=1; shift ;;
    --fix) FIX_MODE=1; shift ;;
    --force) FIX_FORCE=1; shift ;;
    --only)
      if [ $# -lt 2 ] || [ -z "${2:-}" ]; then
        echo "doctor: --only requires an argument" >&2
        USAGE_ERR=1
        break
      fi
      ONLY_FILTER="$2"
      shift 2
      ;;
    --gate=*)
      GATE=${1#--gate=}
      case "$GATE" in
        orchestration|team) ;;
        *)
          echo "doctor: invalid --gate value: $GATE (want orchestration|team)" >&2
          USAGE_ERR=1
          break
          ;;
      esac
      shift
      ;;
    --gate)
      if [ $# -lt 2 ] || [ -z "${2:-}" ]; then
        echo "doctor: --gate requires an argument (orchestration|team)" >&2
        USAGE_ERR=1
        break
      fi
      GATE="$2"
      case "$GATE" in
        orchestration|team) ;;
        *)
          echo "doctor: invalid --gate value: $GATE (want orchestration|team)" >&2
          USAGE_ERR=1
          break
          ;;
      esac
      shift 2
      ;;
    -h|--help) usage; exit 0 ;;
    --) shift; break ;;
    -*)
      echo "doctor: unknown flag: $1" >&2
      USAGE_ERR=1
      break
      ;;
    *)
      echo "doctor: unexpected argument: $1" >&2
      USAGE_ERR=1
      break
      ;;
  esac
done

if [ "$USAGE_ERR" -eq 1 ]; then
  usage
  exit 64
fi


# ---------------------------------------------------------------------------
# Sourced check groups (rv-w3-39: doctor.sh is the dispatcher; the checks and
# their shared helpers live in checks/<group>.sh, sourced from this directory).
# lib.sh defines the roots/registry/helpers every other group compiles against
# (hooks-lib.sh calls parse_expected_hooks at source time) — source it first.
# ---------------------------------------------------------------------------
# shellcheck disable=SC1090
. "$SCRIPT_DIR/checks/lib.sh"
for _dc in "$SCRIPT_DIR"/checks/*.sh; do
  [ -f "$_dc" ] || continue
  case "$_dc" in */checks/lib.sh) continue ;; esac
  # shellcheck disable=SC1090
  . "$_dc"
done
unset _dc

# ---------------------------------------------------------------------------
# Register all checks
# ---------------------------------------------------------------------------
register_check "version.triplet" "version" check_version_triplet
register_check "matrix.cc_version" "version" check_matrix_cc_version
register_check "plugin.resolve" "plugin" check_plugin_resolve
register_check "memory.sqlite3" "memory" check_memory_sqlite3
register_check "memory.db" "memory" check_memory_db
register_check "memory.schema" "memory" check_memory_schema
register_check "memory.ext.vec" "memory" check_memory_ext_vec
register_check "memory.ext.lembed" "memory" check_memory_ext_lembed
register_check "memory.embedding_config" "memory" check_memory_embedding_config
register_check "memory.embed_errors" "memory" check_memory_embed_errors
register_check "memory.mode" "memory" check_memory_mode
register_check "memory.embed_roundtrip" "memory" check_memory_embed_roundtrip
register_check "hooks.events" "hooks" check_hooks_events
register_check "hooks.hygiene" "hooks" check_hooks_hygiene
register_check "hooks.templates" "hooks" check_hooks_templates_dev
register_check "settings.json" "settings" check_settings_json
register_check "settings.agent_teams" "settings" check_settings_agent_teams
register_check "settings.sandbox_coherence" "settings" check_settings_sandbox_coherence
register_check "settings.sandbox_runtime" "settings" check_settings_sandbox_runtime
register_check "settings.mcp_allow" "settings" check_settings_mcp_allow
register_check "deps.jq" "deps" check_deps_jq
register_check "deps.python3" "deps" check_deps_python3
register_check "deps.gh" "deps" check_deps_gh
register_check "deps.bash" "deps" check_deps_bash
register_check "deps.flock" "deps" check_deps_flock
register_check "deps.rg" "deps" check_deps_rg
register_check "deps.timeout" "deps" check_deps_timeout
register_check "worktree.locks" "worktree" check_worktree_locks
register_check "worktree.distill_lock" "worktree" check_worktree_distill_lock
register_check "transcript.mirror_lag" "transcript" check_transcript_mirror_lag
register_check "transcript.budget" "transcript" check_transcript_budget
register_check "models.map" "config" check_models_map
register_check "handoff.tmp" "handoff" check_handoff_tmp
register_check "lint.waivers" "lint" check_lint_waivers
register_check "test.quarantine" "tests" check_test_quarantine

# ---------------------------------------------------------------------------
# --only filter validation
# ---------------------------------------------------------------------------
should_run() {
  local id="$1" group="$2"
  [ -z "$ONLY_FILTER" ] && return 0
  [ "$ONLY_FILTER" = "$id" ] && return 0
  [ "$ONLY_FILTER" = "$group" ] && return 0
  return 1
}

if [ -n "$ONLY_FILTER" ]; then
  known=0
  i=0
  while [ $i -lt ${#REG_IDS[@]} ]; do
    if [ "$ONLY_FILTER" = "${REG_IDS[$i]}" ] || [ "$ONLY_FILTER" = "${REG_GROUPS[$i]}" ]; then
      known=1
      break
    fi
    i=$((i + 1))
  done
  if [ "$known" -eq 0 ]; then
    echo "doctor: unknown check id or group: $ONLY_FILTER" >&2
    echo "Known groups: version memory hooks settings deps worktree plugin transcript config handoff lint tests" >&2
    echo "Known ids: ${REG_IDS[*]}" >&2
    exit 64
  fi
fi

if [ "$FIX_MODE" -eq 1 ]; then
  do_fix
fi

# ---------------------------------------------------------------------------
# Run
# ---------------------------------------------------------------------------
i=0
while [ $i -lt ${#REG_IDS[@]} ]; do
  if should_run "${REG_IDS[$i]}" "${REG_GROUPS[$i]}"; then
    "${REG_FNS[$i]}"
  fi
  i=$((i + 1))
done

# ---------------------------------------------------------------------------
# Summarize + gate-mode self-remediation (SPEC-022 M6c / CDT-67)
# ---------------------------------------------------------------------------
N_PASS=0 N_WARN=0 N_FAIL=0 N_SKIP=0
N_FAIL_BLOCK=0 N_FAIL_WAIVED=0
GATE_CMD=""
case "$GATE" in
  orchestration) GATE_CMD="/setup orchestration" ;;
  team) GATE_CMD="/setup team" ;;
esac

i=0
while [ $i -lt ${#CHECK_IDS[@]} ]; do
  case "${CHECK_STATUSES[$i]}" in
    PASS) N_PASS=$((N_PASS + 1)) ;;
    WARN) N_WARN=$((N_WARN + 1)) ;;
    FAIL)
      N_FAIL=$((N_FAIL + 1))
      if [ -n "$GATE_CMD" ] && fixit_matches_gate "${CHECK_FIXITS[$i]}" "$GATE_CMD"; then
        CHECK_GATE_WAIVED[$i]=1
        N_FAIL_WAIVED=$((N_FAIL_WAIVED + 1))
        # Annotate detail for human+JSON honesty (status stays FAIL)
        CHECK_DETAILS[$i]="${CHECK_DETAILS[$i]} [self-remediating under --gate=${GATE}]"
      else
        N_FAIL_BLOCK=$((N_FAIL_BLOCK + 1))
      fi
      ;;
    SKIP) N_SKIP=$((N_SKIP + 1)) ;;
  esac
  i=$((i + 1))
done

EXIT_CODE=0
if [ -n "$GATE" ]; then
  # Under --gate: blocking FAILs → 2; WARN or waived-only FAIL → 1; clear → 0
  if [ "$N_FAIL_BLOCK" -gt 0 ]; then
    EXIT_CODE=2
  elif [ "$N_WARN" -gt 0 ] || [ "$N_FAIL_WAIVED" -gt 0 ]; then
    EXIT_CODE=1
  fi
else
  # Bare doctor (M6): any FAIL → 2
  if [ "$N_FAIL" -gt 0 ]; then
    EXIT_CODE=2
  elif [ "$N_WARN" -gt 0 ]; then
    EXIT_CODE=1
  fi
fi


# ---------------------------------------------------------------------------
# Render + exit
# ---------------------------------------------------------------------------
if [ "$JSON_MODE" -eq 1 ]; then
  render_json
else
  render_human
fi

exit "$EXIT_CODE"
