#!/usr/bin/env bash
# SPEC-030 R1-R17: one discovering runner for every bash test suite in the
# repo (test.sh, test-*.sh, *-test.sh). Pure subprocess CLI: bash, git and
# POSIX utilities only (no python3/node in the runner itself; suites MAY need
# them). Runs suites serially, in repo-root cwd, with a per-suite wall-clock
# timeout and a dirty-tree guard, and reports a reasoned quarantine list
# (tools/test-quarantine.txt) separately from real failures.
#
# bash 3.2 portable (macOS lane, CDT-271): no associative arrays, no
# mapfile, no `wait -n`. Quarantine lookup uses a TSV temp file + awk, not an
# associative array.
set -uo pipefail

PROG="tools/run-all-tests.sh"

usage() {
  cat <<'USAGE'
Usage: bash tools/run-all-tests.sh [--root DIR] [--list] [-h|--help]

Discovers every test.sh, test-*.sh and *-test.sh suite under --root (default:
git rev-parse --show-toplevel of the cwd) via `git ls-files --cached --others
--exclude-standard`, excluding any path with a fixtures, .worktrees or
node_modules segment and the runner itself. Runs each suite serially, in
sorted order, as `bash <repo-relative-path>` with cwd = root.

  --root DIR    Repo root to scan and run from. MUST be a directory and a
                git work tree.
  --list        Print the discovered suite paths, one per line. Run nothing.
  -h, --help    Show this help and exit.

Environment:
  RUN_ALL_TESTS_TIMEOUT   Per-suite wall-clock timeout in seconds. MUST be a
                          positive integer. Default: 300.

Quarantine file: tools/test-quarantine.txt (repo-relative to --root). A
quarantined suite still runs; a FAIL/TIMEOUT/dirty-tree outcome is reported
as QUARANTINED and does not affect the exit code. A quarantined suite that
passes is reported as PASS plus a stderr warn: line (stale entry).

Exit codes: 0 every non-quarantined suite passed; 1 at least one failed or
timed out; 64 usage error (bad flag, bad --root, bad timeout, malformed
quarantine file).
USAGE
}

ROOT=""
ROOT_GIVEN=false
LIST_ONLY=false

while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help)
      usage
      exit 0
      ;;
    --root)
      if [ $# -lt 2 ]; then
        echo "$PROG: --root requires an argument" >&2
        exit 64
      fi
      ROOT="$2"
      ROOT_GIVEN=true
      shift 2
      ;;
    --root=*)
      ROOT="${1#--root=}"
      ROOT_GIVEN=true
      shift
      ;;
    --list)
      LIST_ONLY=true
      shift
      ;;
    *)
      echo "$PROG: unknown argument: $1" >&2
      exit 64
      ;;
  esac
done

# --- Resolve and validate --root (R3, R2) -----------------------------------

# An explicit --root (or --root=) with an empty value is a usage error, not
# an invitation to fall back to cwd -- that fallback is only for when --root
# was never given at all.
if [ "$ROOT_GIVEN" = true ] && [ -z "$ROOT" ]; then
  echo "$PROG: --root requires a non-empty argument" >&2
  exit 64
fi

if [ -z "$ROOT" ]; then
  ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || {
    echo "$PROG: cwd is not inside a git work tree; pass --root DIR" >&2
    exit 64
  }
fi

if [ ! -d "$ROOT" ]; then
  echo "$PROG: --root $ROOT is not a directory" >&2
  exit 64
fi

if ! git -C "$ROOT" rev-parse --show-toplevel >/dev/null 2>&1; then
  echo "$PROG: --root $ROOT is not a git work tree" >&2
  exit 64
fi

# Normalize to the git toplevel so R4-discovered paths (repo-relative) match
# the cwd the suites run from (R6) and the git status snapshots (R9), even
# when --root pointed at a subdirectory.
ROOT=$(git -C "$ROOT" rev-parse --show-toplevel)

# --- Validate RUN_ALL_TESTS_TIMEOUT (R3, R7) --------------------------------

TIMEOUT_SECS="${RUN_ALL_TESTS_TIMEOUT:-300}"
case "$TIMEOUT_SECS" in
  ''|*[!0-9]*)
    echo "$PROG: RUN_ALL_TESTS_TIMEOUT must be a positive integer, got '$TIMEOUT_SECS'" >&2
    exit 64
    ;;
esac
if [ "$TIMEOUT_SECS" -le 0 ]; then
  echo "$PROG: RUN_ALL_TESTS_TIMEOUT must be a positive integer, got '$TIMEOUT_SECS'" >&2
  exit 64
fi

# --- Scratch workdir (never hardcode /tmp; mktemp honors $TMPDIR) ----------

WORKDIR=$(mktemp -d "${TMPDIR:-/tmp}/run-all-tests.XXXXXX")
trap 'rm -rf "$WORKDIR"' EXIT

SUITES_FILE="$WORKDIR/suites.txt"
QTSV="$WORKDIR/quarantine.tsv"
OUTFILE="$WORKDIR/suite.out"
FLAGFILE="$WORKDIR/suite.timedout"

: > "$QTSV"

# --- Discovery (R4, R5) ------------------------------------------------------

discover_suites() {
  # -z / NUL-delimited: git quotes non-ASCII (and other special) bytes in
  # its default output (core.quotePath), which would corrupt or hide those
  # paths here. -z sidesteps quoting entirely.
  git -C "$ROOT" ls-files -z --cached --others --exclude-standard 2>/dev/null \
    | while IFS= read -r -d '' p; do
        base="${p##*/}"
        case "$base" in
          test.sh|test-*.sh|*-test.sh) ;;
          *) continue ;;
        esac
        case "/$p/" in
          */fixtures/*|*/.worktrees/*|*/node_modules/*) continue ;;
        esac
        [ "$p" = "tools/run-all-tests.sh" ] && continue
        [ -f "$ROOT/$p" ] || continue
        printf '%s\n' "$p"
      done | LC_ALL=C sort -u
}

discover_suites > "$SUITES_FILE"

if [ "$LIST_ONLY" = true ]; then
  cat "$SUITES_FILE"
  exit 0
fi

# --- Quarantine: validate + load (R11) --------------------------------------
# MUST validate the whole file before running any suite -- 64 is a pre-run
# failure, never a mid-run one.

QFILE="$ROOT/tools/test-quarantine.txt"
QSEEN="$WORKDIR/quarantine-seen.txt"
: > "$QSEEN"

if [ -f "$QFILE" ]; then
  lineno=0
  while IFS= read -r qline || [ -n "$qline" ]; do
    lineno=$((lineno + 1))

    qpath=""
    qreason=""
    read -r qpath qreason <<< "$qline"

    [ -z "$qpath" ] && continue
    case "$qpath" in
      '#'*) continue ;;
    esac

    if [ -z "$qreason" ]; then
      echo "$PROG: $QFILE:$lineno: missing reason for $qpath" >&2
      exit 64
    fi

    if ! grep -Fxq -- "$qpath" "$SUITES_FILE"; then
      echo "$PROG: $QFILE:$lineno: $qpath is not a discovered suite" >&2
      exit 64
    fi

    if grep -Fxq -- "$qpath" "$QSEEN"; then
      echo "$PROG: $QFILE:$lineno: $qpath is listed twice" >&2
      exit 64
    fi

    printf '%s\n' "$qpath" >> "$QSEEN"
    printf '%s\t%s\n' "$qpath" "$qreason" >> "$QTSV"
  done < "$QFILE"
fi

# --- Execution (R6-R9) -------------------------------------------------------

PASS_N=0
FAIL_N=0
TIMEOUT_N=0
QUAR_N=0
SKIP_N=0
EXIT_CODE=0

while IFS= read -r suite; do
  [ -n "$suite" ] || continue

  : > "$OUTFILE"
  rm -f "$FLAGFILE"

  before=$(git -C "$ROOT" status --porcelain --untracked-files=all)

  # Each of the suite and its watchdog gets its own process group (set -m),
  # so TERM/KILL targeting -"$pid" never touches the runner or the other job.
  set -m
  ( cd "$ROOT" && exec bash "$suite" </dev/null >"$OUTFILE" 2>&1 ) &
  pid=$!
  ( sleep "$TIMEOUT_SECS"; : > "$FLAGFILE"; kill -TERM -- -"$pid" 2>/dev/null; sleep 5; kill -KILL -- -"$pid" 2>/dev/null ) &
  watchdog=$!

  wait "$pid" 2>/dev/null
  rc=$?

  # If the timeout already fired, the watchdog's KILL escalation may still
  # be pending: a suite leader that dies on TERM lets `wait "$pid"` return
  # before a TERM-ignoring grandchild in the same process group does (it
  # only dies on the watchdog's later KILL). Let the watchdog finish its 5s
  # grace and deliver that KILL instead of killing the watchdog itself
  # (R7) -- only tear the watchdog down early on the no-timeout path, where
  # it is still asleep for the remainder of $TIMEOUT_SECS.
  if [ -f "$FLAGFILE" ]; then
    wait "$watchdog" 2>/dev/null
  else
    kill -- -"$watchdog" 2>/dev/null
    wait "$watchdog" 2>/dev/null
  fi
  set +m

  after=$(git -C "$ROOT" status --porcelain --untracked-files=all)

  timed_out=false
  [ -f "$FLAGFILE" ] && timed_out=true

  dirtied=false
  [ "$before" = "$after" ] || dirtied=true

  detail=""
  if [ "$timed_out" = true ]; then
    status="TIMEOUT"
    detail="timed out after ${TIMEOUT_SECS}s"
  elif [ "$dirtied" = true ]; then
    status="FAIL"
    detail="modified the working tree"
  elif [ "$rc" -eq 77 ]; then
    status="SKIP"
  elif [ "$rc" -eq 0 ]; then
    status="PASS"
  else
    status="FAIL"
    detail="exit $rc"
  fi

  qreason=$(awk -F'\t' -v p="$suite" '$1==p{print $2; exit}' "$QTSV")
  if [ -n "$qreason" ]; then
    case "$status" in
      SKIP) : ;;
      PASS)
        echo "$PROG: warn: $suite is quarantined (tools/test-quarantine.txt) but passed; remove the entry" >&2
        ;;
      *)
        status="QUARANTINED"
        ;;
    esac
  fi

  case "$status" in
    PASS) PASS_N=$((PASS_N + 1)) ;;
    FAIL) FAIL_N=$((FAIL_N + 1)); EXIT_CODE=1 ;;
    TIMEOUT) TIMEOUT_N=$((TIMEOUT_N + 1)); EXIT_CODE=1 ;;
    QUARANTINED) QUAR_N=$((QUAR_N + 1)) ;;
    SKIP) SKIP_N=$((SKIP_N + 1)) ;;
  esac

  if [ -n "$detail" ]; then
    printf '%s %s (%s)\n' "$status" "$suite" "$detail"
  else
    printf '%s %s\n' "$status" "$suite"
  fi

  case "$status" in
    FAIL|TIMEOUT|QUARANTINED)
      tail -n 20 "$OUTFILE" | sed 's/^/    | /'
      ;;
  esac
done < "$SUITES_FILE"

TOTAL=$((PASS_N + FAIL_N + TIMEOUT_N + QUAR_N + SKIP_N))
printf '%s suites: %s passed, %s failed, %s timed out, %s quarantined, %s skipped\n' \
  "$TOTAL" "$PASS_N" "$FAIL_N" "$TIMEOUT_N" "$QUAR_N" "$SKIP_N"

exit "$EXIT_CODE"
