#!/usr/bin/env bash
#
# ci-watch/test-poll.sh — Offline bite-tests for poll.sh (PATH-mock gh)
#
# Machine-check: bash skills/ci-watch/test-poll.sh  (exit 0)
# THIS SCRIPT IS A SUBPROCESS CLI — NEVER SOURCE IT.

set -u

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
POLL_CLI="$SCRIPT_DIR/poll.sh"
SIDECAR_CLI="$SCRIPT_DIR/sidecar.sh"

PASS=0
FAIL=0
TICKET="CDV-170-TEST"

die() { echo "FAIL: $*" >&2; exit 1; }

# ---- Temp git repo (fake MROOT) ---------------------------------------------
TMP=$(mktemp -d "${TMPDIR:-/tmp}/ci-watch-test-poll.XXXXXX")
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT
export TMPDIR="$TMP/tmp"
mkdir -p "$TMPDIR"

git init -q "$TMP" || die "git init failed"
cd "$TMP" || die "cd $TMP"
mkdir -p .claude/ci-watch

# ---- Mock gh on PATH --------------------------------------------------------
MOCK_BIN="$TMP/mock-bin"
mkdir -p "$MOCK_BIN"
cat > "$MOCK_BIN/gh" << 'MOCK'
#!/bin/sh
# Controlled by GH_MOCK_RC, GH_MOCK_JSON, GH_MOCK_STATE
case " $* " in
  *" checks "*)
    printf '%s' "${GH_MOCK_JSON-}"
    exit "${GH_MOCK_RC:-0}"
    ;;
  *" view "*)
    # poll.sh: gh pr view "$pr" --json state -q .state
    printf '%s\n' "${GH_MOCK_STATE:-OPEN}"
    exit 0
    ;;
  *)
    echo "mock gh: unexpected argv: $*" >&2
    exit 99
    ;;
esac
MOCK
chmod +x "$MOCK_BIN/gh"
export PATH="$MOCK_BIN:$PATH"

# ---- Helpers ----------------------------------------------------------------
reset_sidecar() {
  local retry="${1:-0}"
  rm -f ".claude/ci-watch/${TICKET}.json" \
        ".claude/ci-watch/${TICKET}.log" \
        ".claude/ci-watch/${TICKET}.last_failure.txt"
  bash "$SIDECAR_CLI" init "$TICKET" ci 42 "branch-test" \
    || die "sidecar init failed"
  # Arm cron so re-init is not needed; set retry if non-zero
  bash "$SIDECAR_CLI" set "$TICKET" cron_job_id "job-test" >/dev/null
  if [ "$retry" != "0" ]; then
    bash "$SIDECAR_CLI" set "$TICKET" retry_count "$retry" >/dev/null
  fi
}

poll_error_count() {
  bash "$SIDECAR_CLI" get "$TICKET" poll_error_count 2>/dev/null || echo 0
}

run_case() {
  local name="$1"
  local json="$2"
  local rc="$3"
  local retry="$4"
  local expect_out="$5"
  local expect_delta="$6"

  reset_sidecar "$retry"

  local before after delta out exit_code
  before=$(poll_error_count)

  export GH_MOCK_JSON="$json"
  export GH_MOCK_RC="$rc"
  export GH_MOCK_STATE="OPEN"

  out=$(bash "$POLL_CLI" "$TICKET" 2>/dev/null)
  exit_code=$?

  after=$(poll_error_count)
  delta=$((after - before))

  local ok=1
  if [ "$exit_code" -ne 0 ]; then
    echo "  FAIL [$name]: poll exit=$exit_code (want 0)"
    ok=0
  fi
  if [ "$out" != "$expect_out" ]; then
    echo "  FAIL [$name]: stdout='$out' (want '$expect_out')"
    ok=0
  fi
  if [ "$delta" -ne "$expect_delta" ]; then
    echo "  FAIL [$name]: poll_error delta=$delta (want $expect_delta) before=$before after=$after"
    ok=0
  fi

  if [ "$ok" -eq 1 ]; then
    echo "  PASS [$name]: out=$out delta=$delta exit=0"
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
  fi
}

# ---- Cases (AC-10 + AC-7) ---------------------------------------------------
echo "ci-watch/test-poll.sh — offline PATH-mock gh"

FAIL_JSON='[{"name":"ci","state":"FAILURE","bucket":"fail"}]'
PENDING_JSON='[{"name":"ci","state":"IN_PROGRESS","bucket":"pending"}]'
NON_ARRAY='{"err":1}'
EMPTY_ARRAY='[]'

run_case "fail→fail"            "$FAIL_JSON"    1 0 "fail" 0
run_case "fail+retry≥3→cap"     "$FAIL_JSON"    1 3 "cap"  0
run_case "pending→wait"         "$PENDING_JSON" 8 0 "wait" 0
run_case "non-array→poll_error" "$NON_ARRAY"    1 0 "wait" 1
run_case "[]→done"              "$EMPTY_ARRAY"  0 0 "done" 0
run_case "AC-7 rc8 non-array"   "$NON_ARRAY"    8 0 "wait" 0

# empty body non-array + rc1 also poll_error (optional coverage of AC-8 empty)
run_case "empty-body→poll_error" ""             1 0 "wait" 1

# ---- AC-E: ci-watch does not spawn a fixer when timeout is missing --------
echo ""
echo "AC-E: local-test mode, timeout/gtimeout missing"

FARM_LIB="$SCRIPT_DIR/../../tests/lib/path-farm.sh"
[ -f "$FARM_LIB" ] || die "tests/lib/path-farm.sh not found"
. "$FARM_LIB"

BASH_BIN=$(command -v bash) || die "bash not found"
REAL_TIMEOUT=$(command -v timeout) || die "real timeout not found on host"

FARM="$TMP/farm"
path_farm "$FARM" bash git jq sed awk date mkdir head rm dirname cat mv mktemp tr basename printf flock
FARM_RC=$?
[ "$FARM_RC" -eq 0 ] || die "path_farm rc=$FARM_RC (unexpectedly refused a non-timeout command)"

E_MOCK_BIN="$TMP/e-mock-bin"
mkdir -p "$E_MOCK_BIN"
cp "$MOCK_BIN/gh" "$E_MOCK_BIN/gh"
chmod +x "$E_MOCK_BIN/gh"

E_PATH="$E_MOCK_BIN:$FARM"

if PATH="$E_PATH" command -v timeout >/dev/null 2>&1; then
  die "farm PATH unexpectedly resolves timeout"
fi
if PATH="$E_PATH" command -v gtimeout >/dev/null 2>&1; then
  die "farm PATH unexpectedly resolves gtimeout"
fi

reset_sidecar_local() {
  rm -f ".claude/ci-watch/${TICKET}.json" \
        ".claude/ci-watch/${TICKET}.log" \
        ".claude/ci-watch/${TICKET}.last_failure.txt"
  bash "$SIDECAR_CLI" init "$TICKET" local-test 0 "branch-test" \
    || die "sidecar init (local-test) failed"
  bash "$SIDECAR_CLI" set "$TICKET" cron_job_id "job-test" >/dev/null
}

reset_sidecar_local

E_OUT="$TMP/e-out.txt"
E_ERR="$TMP/e-err.txt"
before=$(poll_error_count)
retry_before=$(bash "$SIDECAR_CLI" get "$TICKET" retry_count 2>/dev/null || echo 0)

"$REAL_TIMEOUT" 30 env PATH="$E_PATH" "$BASH_BIN" "$POLL_CLI" "$TICKET" >"$E_OUT" 2>"$E_ERR"
e_rc=$?

after=$(poll_error_count)
retry_after=$(bash "$SIDECAR_CLI" get "$TICKET" retry_count 2>/dev/null || echo 0)
e_out=$(cat "$E_OUT")

e_ok=1
if [ "$e_rc" -ne 0 ]; then
  echo "  FAIL [AC-E no-timeout]: rc=$e_rc (want 0)"
  e_ok=0
fi
if [ "$e_out" != "wait" ]; then
  echo "  FAIL [AC-E no-timeout]: stdout='$e_out' (want 'wait')"
  e_ok=0
fi
if [ "$((after - before))" -ne 1 ]; then
  echo "  FAIL [AC-E no-timeout]: poll_error_count delta=$((after - before)) (want 1)"
  e_ok=0
fi
if [ "$retry_after" != "$retry_before" ]; then
  echo "  FAIL [AC-E no-timeout]: retry_count changed ($retry_before -> $retry_after)"
  e_ok=0
fi
if [ -f ".claude/ci-watch/${TICKET}.last_failure.txt" ]; then
  echo "  FAIL [AC-E no-timeout]: last_failure.txt written"
  e_ok=0
fi
if ! grep -q 'outcome=timeout_missing' ".claude/ci-watch/${TICKET}.log" 2>/dev/null; then
  echo "  FAIL [AC-E no-timeout]: log missing outcome=timeout_missing"
  e_ok=0
fi
if ! grep -q 'timeout' "$E_ERR"; then
  echo "  FAIL [AC-E no-timeout]: stderr missing 'timeout'"
  e_ok=0
fi
if ! grep -q 'gtimeout' "$E_ERR"; then
  echo "  FAIL [AC-E no-timeout]: stderr missing 'gtimeout'"
  e_ok=0
fi

if [ "$e_ok" -eq 1 ]; then
  echo "  PASS [AC-E no-timeout]: out=wait delta=1 log+stderr correct exit=0"
  PASS=$((PASS + 1))
else
  FAIL=$((FAIL + 1))
fi

# ---- AC-E: gtimeout shim present → no timeout_missing ----------------------
reset_sidecar_local
GT_DIR="$TMP/gtimeout-bin"
mkdir -p "$GT_DIR"
cat > "$GT_DIR/gtimeout" << 'GTMOCK'
#!/bin/sh
shift
exec "$@"
GTMOCK
chmod +x "$GT_DIR/gtimeout"

E_PATH2="$E_MOCK_BIN:$GT_DIR:$FARM"

E_OUT2="$TMP/e-out2.txt"
E_ERR2="$TMP/e-err2.txt"
"$REAL_TIMEOUT" 30 env PATH="$E_PATH2" "$BASH_BIN" "$POLL_CLI" "$TICKET" >"$E_OUT2" 2>"$E_ERR2"
e2_rc=$?
e2_out=$(cat "$E_OUT2")

e2_ok=1
if [ "$e2_rc" -ne 0 ]; then
  echo "  FAIL [AC-E gtimeout-shim]: rc=$e2_rc (want 0)"
  e2_ok=0
fi
if [ "$e2_out" != "wait" ]; then
  echo "  FAIL [AC-E gtimeout-shim]: stdout='$e2_out' (want 'wait')"
  e2_ok=0
fi
if grep -q 'outcome=timeout_missing' ".claude/ci-watch/${TICKET}.log" 2>/dev/null; then
  echo "  FAIL [AC-E gtimeout-shim]: log has timeout_missing (should not, planted negative control)"
  e2_ok=0
fi

if [ "$e2_ok" -eq 1 ]; then
  echo "  PASS [AC-E gtimeout-shim]: no timeout_missing when gtimeout present exit=0"
  PASS=$((PASS + 1))
else
  FAIL=$((FAIL + 1))
fi

# ---- Static: one shared poll-error helper (SPEC-003 no copy-paste) ----------
echo ""
echo "Static: poll_error_count increment lives in one helper"
count_inc_sites() { grep -c 'inc "\$TICKET" poll_error_count' "$1" 2>/dev/null || true; }
NEG_CTRL="$TMP/neg-ctrl.sh"
printf '%s\n' 'bash "$C" inc "$TICKET" poll_error_count' 'bash "$C" inc "$TICKET" poll_error_count' > "$NEG_CTRL"
if [ "$(count_inc_sites "$NEG_CTRL")" = "2" ]; then
  echo "  PASS [static negative control]: counter sees 2 planted sites"
  PASS=$((PASS + 1))
else
  echo "  FAIL [static negative control]: counter did not see 2 planted sites"
  FAIL=$((FAIL + 1))
fi
inc_sites=$(count_inc_sites "$POLL_CLI")
if [ "$inc_sites" = "1" ]; then
  echo "  PASS [static poll_error_wait]: 1 inc site in poll.sh"
  PASS=$((PASS + 1))
else
  echo "  FAIL [static poll_error_wait]: $inc_sites 'inc poll_error_count' sites in poll.sh (want 1, in poll_error_wait)"
  FAIL=$((FAIL + 1))
fi
echo ""
echo "Results: PASS=$PASS FAIL=$FAIL"
if [ "$FAIL" -ne 0 ]; then
  exit 1
fi
exit 0
