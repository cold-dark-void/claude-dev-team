#!/usr/bin/env bash
#
# ci-watch/poll.sh — One CI-watch poll cycle for <TICKET>
#
# Subprocess CLI invoked by a durable cron. Always exits 0 (errors are
# non-fatal and recorded in poll_error_count + the ticket log). Stdout is
# the only contract with the cron prompt body:
#
#   done  → checks/tests green (or PR merged/closed); cron should self-delete
#   fail  → real failure; cron prompt should spawn fixer
#   cap   → retry_count >= 3; cron should self-delete + notify
#   wait  → nothing actionable this cycle (sidecar missing, fixer running,
#           checks not yet reported, transient poll error, etc.)
#
# Usage: poll.sh <TICKET_ID>
# THIS SCRIPT IS A SUBPROCESS CLI — NEVER SOURCE IT.

set -u
# Note: NOT -e — every error path here is recoverable and must keep the
# process alive long enough to print one outcome word.

TICKET="${1:-}"
if [ -z "$TICKET" ]; then
  echo "wait"
  exit 0
fi
if ! printf '%s' "$TICKET" | grep -qE '^[a-zA-Z0-9._-]+$'; then
  echo "wait"
  exit 0
fi

# ---- Resolve MROOT (worktree-aware) -----------------------------------------
_gc=$(git rev-parse --git-common-dir 2>/dev/null) \
  && MROOT=$(cd "$(dirname "$_gc")" && pwd) \
  || MROOT=$(pwd)

WATCH_DIR="$MROOT/.claude/ci-watch"
LOG_FILE="$WATCH_DIR/${TICKET}.log"
LAST_FAIL="$WATCH_DIR/${TICKET}.last_failure.txt"
SIDECAR="$WATCH_DIR/${TICKET}.json"

OUT_TMP="${TMPDIR:-/tmp}/ci-watch-out-$TICKET.txt"
ERR_TMP="${TMPDIR:-/tmp}/ci-watch-err-$TICKET.txt"
trap 'rm -f "$OUT_TMP" "$ERR_TMP"' EXIT

# Sibling scripts — resolve relative to this script so the skill works
# whether invoked from the main repo or a worktree checkout.
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SIDECAR_CLI="$SCRIPT_DIR/sidecar.sh"
DETECT_CLI="$SCRIPT_DIR/detect-mode.sh"

# ---- Logging helper ---------------------------------------------------------
log_event() {
  local outcome="$1"
  mkdir -p "$WATCH_DIR" 2>/dev/null
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) $TICKET outcome=$outcome" >> "$LOG_FILE" 2>/dev/null || true
}

emit() {
  echo "$1"
  [[ "$1" != "wait" ]] && log_event "$1"
  exit 0
}

# ---- Sidecar gate -----------------------------------------------------------
if [ ! -f "$SIDECAR" ]; then
  emit "wait"
fi

# Read fixer guard first — if a fixer is currently running, do nothing.
FIXER_ACTIVE=$(bash "$SIDECAR_CLI" get "$TICKET" fixer_active 2>/dev/null || echo "false")
if [ "$FIXER_ACTIVE" = "true" ]; then
  emit "wait"
fi

MODE=$(bash "$SIDECAR_CLI" get "$TICKET" mode 2>/dev/null || echo "")

# ---- Failure-path helper (shared by ci + local-test) ------------------------
# Args: <source-tmp-file>  (file whose head -c 4096 becomes last_failure.txt)
handle_failure() {
  local src="$1"
  local retry
  retry=$(bash "$SIDECAR_CLI" get "$TICKET" retry_count 2>/dev/null || echo "0")
  case "$retry" in ''|*[!0-9]*) retry=0 ;; esac

  if [ "$retry" -ge 3 ]; then
    emit "cap"
  fi

  mkdir -p "$WATCH_DIR" 2>/dev/null
  if [ -f "$src" ]; then
    head -c 4096 "$src" > "$LAST_FAIL" 2>/dev/null || true
  fi
  emit "fail"
}

# ---- ci mode ----------------------------------------------------------------
poll_ci() {
  local pr
  pr=$(bash "$SIDECAR_CLI" get "$TICKET" pr_number 2>/dev/null || echo "")
  if [ -z "$pr" ] || [ "$pr" = "null" ]; then
    emit "wait"
  fi

  # PR state — merged/closed short-circuits to done (silent done at cron prompt).
  local state
  state=$(gh pr view "$pr" --json state -q .state 2>/dev/null || echo "UNKNOWN")
  if [ "$state" = "MERGED" ] || [ "$state" = "CLOSED" ]; then
    emit "done"
  fi

  # Fetch checks. `gh pr checks --json` has no `conclusion` field — decisions
  # key off `bucket`, gh's stable normalization of check state:
  #   pass | skipping (SKIPPED/NEUTRAL) | fail (FAILURE/ERROR/TIMED_OUT/
  #   ACTION_REQUIRED) | cancel (CANCELLED) | pending (queued/in-progress).
  local result
  if ! result=$(gh pr checks "$pr" --json name,state,bucket 2>"$ERR_TMP"); then
    bash "$SIDECAR_CLI" inc "$TICKET" poll_error_count >/dev/null 2>&1 || true
    log_event "poll_error"
    emit "wait"
  fi

  local total fail_count ok_count
  total=$(echo "$result" | jq 'length' 2>/dev/null || echo 0)
  fail_count=$(echo "$result" | jq '[.[] | select(.bucket == "fail" or .bucket == "cancel")] | length' 2>/dev/null || echo 0)
  ok_count=$(echo "$result" | jq '[.[] | select(.bucket == "pass" or .bucket == "skipping")] | length' 2>/dev/null || echo 0)

  # No checks configured for this PR → nothing to wait on.
  if [ "$total" -eq 0 ]; then
    emit "done"
  fi

  # Some failed → handle failure (fail/cap).
  if [ "$fail_count" -gt 0 ]; then
    # Capture the failing-check JSON as the failure context.
    echo "$result" | jq '[.[] | select(.bucket == "fail" or .bucket == "cancel")]' > "$OUT_TMP" 2>/dev/null \
      || echo "$result" > "$OUT_TMP" 2>/dev/null
    handle_failure "$OUT_TMP"
  fi

  # All checks resolved green (passed or skipped).
  if [ "$ok_count" -eq "$total" ]; then
    emit "done"
  fi

  # Otherwise still pending (in-progress checks).
  emit "wait"
}

# ---- local-test mode --------------------------------------------------------
poll_local_test() {
  local wt="$MROOT/.worktrees/$TICKET"
  if [ ! -d "$wt" ]; then
    bash "$SIDECAR_CLI" inc "$TICKET" poll_error_count >/dev/null 2>&1 || true
    log_event "poll_error"
    emit "wait"
  fi

  local mode_out test_cmd
  mode_out=$(bash "$DETECT_CLI" "$wt" 2>/dev/null || echo "none")
  test_cmd=$(echo "$mode_out" | sed -n 2p)

  if [ -z "$test_cmd" ]; then
    bash "$SIDECAR_CLI" inc "$TICKET" poll_error_count >/dev/null 2>&1 || true
    log_event "poll_error"
    emit "wait"
  fi

  # test_cmd MUST be a hardcoded literal from detect-mode.sh — never interpolate user data here
  ( cd "$wt" && timeout 120 bash -c "$test_cmd" ) > "$OUT_TMP" 2>&1
  local rc=$?

  if [ "$rc" -eq 0 ]; then
    emit "done"
  fi

  handle_failure "$OUT_TMP"
}

# ---- Dispatch ---------------------------------------------------------------
case "$MODE" in
  ci)         poll_ci ;;
  local-test) poll_local_test ;;
  *)          emit "wait" ;;
esac
