#!/usr/bin/env bash
#
# ci-watch/poll.sh — One CI-watch poll cycle for <TICKET>
#
# Subprocess CLI invoked by the CI-watch cron. Always exits 0 (errors are
# non-fatal and recorded in poll_error_count + the ticket log). Stdout is
# the only contract with the cron prompt body:
#
#   done  → checks/tests green (or PR merged/closed); cron should self-delete
#   fail  → real failure; cron prompt should spawn fixer
#   cap   → retry_count >= 3, or poll_error_count >= 10; cron should self-delete + notify
#   wait  → nothing actionable this cycle (sidecar missing, fresh fixer running,
#           checks not yet reported, transient poll error under the cap, etc.)
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
if ! [[ "$TICKET" =~ ^[A-Za-z0-9_-]+$ ]]; then
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

# Private names (mktemp, mode 600). A path that embeds $TICKET is predictable
# (CWE-377): another user can plant a symlink before the poll creates it.
OUT_TMP=$(mktemp "${TMPDIR:-/tmp}/ci-watch-out.XXXXXX") || { echo "wait"; exit 0; }
ERR_TMP=$(mktemp "${TMPDIR:-/tmp}/ci-watch-err.XXXXXX") || { rm -f "$OUT_TMP"; echo "wait"; exit 0; }
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

# Recoverable poll failure: count it, log the outcome word, then emit "wait".
# Args: [outcome-word]  (default: poll_error). Never returns (emit exits).
# A stderr hint belongs to the caller and prints BEFORE this call.
poll_error_wait() {
  local w="${1:-poll_error}"
  local n
  n=$(bash "$SIDECAR_CLI" inc "$TICKET" poll_error_count 2>/dev/null || echo 0)
  case "$n" in ''|*[!0-9]*) n=0 ;; esac
  log_event "$w"
  # Ten consecutive poll errors is a dead watch (auth, missing tree). Stop it.
  if [ "$n" -ge 10 ]; then
    emit "cap"
  fi
  emit "wait"
}

# ---- Sidecar gate -----------------------------------------------------------
if [ ! -f "$SIDECAR" ]; then
  emit "wait"
fi

# Read fixer guard first — a fresh fixer blocks a second spawn.
# A missing or expired fixer_started_at is a crashed fixer: clear it, count
# one retry, log fixer_stale, and continue this poll. Default TTL is 1800s.
FIXER_TTL="${CI_WATCH_FIXER_TTL:-1800}"
FIXER_ACTIVE=$(bash "$SIDECAR_CLI" get "$TICKET" fixer_active 2>/dev/null || echo "false")
if [ "$FIXER_ACTIVE" = "true" ]; then
  started=$(bash "$SIDECAR_CLI" get "$TICKET" fixer_started_at 2>/dev/null || echo "")
  now=$(date +%s)
  fixer_age=""
  if [[ "$started" =~ ^[0-9]+$ ]]; then
    fixer_age=$((now - started))
  fi
  if [ -z "$fixer_age" ] || [ "$fixer_age" -ge "$FIXER_TTL" ]; then
    bash "$SIDECAR_CLI" set "$TICKET" fixer_active false >/dev/null 2>&1 || true
    bash "$SIDECAR_CLI" inc "$TICKET" retry_count >/dev/null 2>&1 || true
    log_event "fixer_stale"
    echo "ci-watch: fixer stale for $TICKET; cleared fixer_active and counted a retry" >&2
  else
    emit "wait"
  fi
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
  # Capture stdout + exit status. gh exits 1 (fail) / 8 (pending) with
  # parseable JSON — those are signals, not poll errors (SPEC-017 AC-1/7/8).
  local result gh_rc
  result=$(gh pr checks "$pr" --json name,state,bucket 2>"$ERR_TMP")
  gh_rc=$?

  if ! printf '%s' "$result" | jq -e 'type == "array"' >/dev/null 2>&1; then
    if [ "$gh_rc" -eq 8 ]; then
      emit "wait"
    fi
    poll_error_wait
  fi

  local total fail_count ok_count
  total=$(echo "$result" | jq 'length' 2>/dev/null || echo 0)
  fail_count=$(echo "$result" | jq '[.[] | select(.bucket == "fail" or .bucket == "cancel")] | length' 2>/dev/null || echo 0)
  ok_count=$(echo "$result" | jq '[.[] | select(.bucket == "pass" or .bucket == "skipping")] | length' 2>/dev/null || echo 0)

  # Empty checks. No workflow dir means there is nothing to wait for.
  # With workflows present, the first empty polls are a push race: wait until
  # K consecutive empty results (default 3). A later non-empty poll resets.
  if [ "$total" -eq 0 ]; then
    if [ ! -d "$MROOT/.github/workflows" ]; then
      emit "done"
    fi
    local empty_n empty_k
    empty_k="${CI_WATCH_EMPTY_POLLS:-3}"
    empty_n=$(bash "$SIDECAR_CLI" inc "$TICKET" empty_poll_count 2>/dev/null || echo 0)
    case "$empty_n" in ''|*[!0-9]*) empty_n=0 ;; esac
    if [ "$empty_n" -ge "$empty_k" ]; then
      emit "done"
    fi
    emit "wait"
  fi
  bash "$SIDECAR_CLI" set "$TICKET" empty_poll_count 0 >/dev/null 2>&1 || true

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
  TIMEOUT_BIN=$(command -v timeout 2>/dev/null || command -v gtimeout 2>/dev/null || true)
  if [ -z "$TIMEOUT_BIN" ]; then
    echo "ci-watch: neither 'timeout' nor 'gtimeout' is on PATH — install coreutils; not running tests" >&2
    poll_error_wait "timeout_missing"
  fi

  # A shared epic child has no .worktrees/<TICKET>. Epic hands the
  # integration tree in EPIC_INTEGRATION_PATH (skills/epic/SKILL.md B.4).
  local wt=""
  if [ -n "${EPIC_INTEGRATION_PATH:-}" ] && [ -d "$EPIC_INTEGRATION_PATH" ]; then
    wt="$EPIC_INTEGRATION_PATH"
  elif [ -d "$MROOT/.worktrees/$TICKET" ]; then
    wt="$MROOT/.worktrees/$TICKET"
  else
    emit "wait"
  fi

  local mode_out test_cmd
  mode_out=$(bash "$DETECT_CLI" "$wt" 2>/dev/null || echo "none")
  test_cmd=$(echo "$mode_out" | sed -n 2p)

  if [ -z "$test_cmd" ]; then
    poll_error_wait
  fi

  # test_cmd MUST be a hardcoded literal from detect-mode.sh — never interpolate user data here
  ( cd "$wt" && "$TIMEOUT_BIN" 120 bash -c "$test_cmd" ) > "$OUT_TMP" 2>&1
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
