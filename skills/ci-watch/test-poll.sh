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

echo ""
echo "Results: PASS=$PASS FAIL=$FAIL"
if [ "$FAIL" -ne 0 ]; then
  exit 1
fi
exit 0
