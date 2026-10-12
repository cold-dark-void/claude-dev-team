#!/usr/bin/env bash
# SPEC-030 R1-R17: one discovering runner for every bash test suite in the
# repo (test.sh, test-*.sh, *-test.sh). Pure subprocess CLI: bash, git and
# POSIX utilities only (no python3/node in the runner itself; suites MAY need
# them). Runs suites in the repo-root cwd -- serially by default, or in an
# opt-in --jobs worker pool (CDT-534) -- with a per-suite wall-clock
# timeout and a dirty-tree guard, and reports a reasoned quarantine list
# (tools/test-quarantine.txt) separately from real failures.
#
# bash 3.2 portable (macOS lane, CDT-271): no associative arrays, no
# mapfile, and none of the R32-banned concurrency helpers. Quarantine lookup
# uses a TSV temp file + awk, not an associative array.
#
# CDT-502 (SPEC-030 R11/R12/R32): quarantine lines carry a scope column
# (<path> <scope: all|macos> <reason>); a macos-scoped entry applies only on
# the --platform macos lane and is validated-then-ignored on the default lane.
#
# CDT-534 (SPEC-030 R36): parses --jobs / RUN_ALL_TESTS_JOBS (positive
# integer or auto; default 1). jobs=1 keeps the serial path below exactly
# as-is. jobs>1 (R37) runs every suite in a private `git clone --local`
# scratch under --root's git-common-dir -- seeded with HEAD, the staged and
# worktree bytes of every cached path (including staged deletions and
# renames: seed paths not in --root's cached list are git-rm'd), and the
# untracked-not-ignored files -- restored from the seed after each suite
# and removed on exit. The pool (R38) keeps at most N suite+watchdog
# process groups in flight: poll rc.<k> and dispatch onto any free worker;
# finished output is held until R10 can print it in R4 order. Each suite
# gets a per-worker HOME and TMPDIR under WORKDIR, outside the clone (R39).
#
# CDT-545: when a pool suite comes back red (FAIL/TIMEOUT/QUARANTINED), its
# full out.$k is moved to ${TMPDIR:-/tmp}/run-all-tests-failed.<ts>.<pid>/
# and the path is printed on stderr -- the failure tail is only 20 lines.
# The keep-dir is created lazily, so a green run leaves nothing behind, and
# it lives outside the scratch, so cleanup() never deletes it. jobs=1 is
# unchanged.
set -uo pipefail

PROG="tools/run-all-tests.sh"

platform_usage_error() { # platform_usage_error <message> -- R32 wants a
                         # usage line on stderr with the 64
  echo "$PROG: $1" >&2
  echo "Usage: bash tools/run-all-tests.sh [--root DIR] [--list] [--portable] [--platform linux|macos] [--jobs N|auto] [-h|--help]" >&2
  exit 64
}

usage() {
  cat <<'USAGE'
Usage: bash tools/run-all-tests.sh [--root DIR] [--list] [--portable] [--platform linux|macos] [--jobs N|auto] [-h|--help]

Discovers every test.sh, test-*.sh and *-test.sh suite under --root (default:
git rev-parse --show-toplevel of the cwd) via `git ls-files --cached --others
--exclude-standard`, excluding any path with a fixtures, .worktrees or
node_modules segment and the runner itself. Runs each suite in sorted
order as `bash <repo-relative-path>` with cwd = root -- serially by
default, or in a worker pool of N suites with --jobs N (N > 1).

  --root DIR    Repo root to scan and run from. MUST be a directory and a
                git work tree.
  --list        Print the discovered suite paths, one per line. Run nothing.
  --portable    Keep only suites whose code is bash 3.2 / BSD-safe (CDT-271).
                A comment that names a GNU tool does not exclude the suite.
  --platform P  Lane for quarantine scoping (CDT-502): linux (default) or
                macos. A macos-scoped quarantine entry quarantines only with
                --platform macos; on the default lane the entry is validated
                and ignored.
  --jobs N      Worker-pool size (CDT-534, R36). N is a positive integer or
                the token auto (= min(processors, 8)). Default: 1, the
                serial loop. jobs=1 runs no worker scratch. jobs>1 runs
                each suite in a private clone under the git-common-dir
                (R37), at most N at a time (R38), with HOME and TMPDIR
                under the runner WORKDIR, outside the clone (R39).
                Result lines always print in sorted-suite order (R10).
                The flag overrides RUN_ALL_TESTS_JOBS.
  -h, --help    Show this help and exit.

Environment:
  RUN_ALL_TESTS_TIMEOUT   Per-suite wall-clock timeout in seconds. MUST be a
                          positive integer. Default: 300.
  RUN_ALL_TESTS_JOBS      Default pool size when --jobs is omitted
                          (CDT-534, R36). Positive integer or auto; empty
                          counts as omitted.

Quarantine file: tools/test-quarantine.txt (repo-relative to --root). Each
non-comment line is <path> <scope> <reason>, scope all or macos. A
quarantined suite still runs; a FAIL/TIMEOUT/dirty-tree outcome is reported
as QUARANTINED and does not affect the exit code. A quarantined suite that
passes is reported as PASS plus a stderr warn: line (stale entry).

Exit codes: 0 every non-quarantined suite passed; 1 at least one failed or
timed out; 64 usage error (bad flag, bad --root, bad --platform, bad
--jobs / RUN_ALL_TESTS_JOBS, bad timeout, malformed quarantine file).
USAGE
}

ROOT=""
ROOT_GIVEN=false
LIST_ONLY=false
PORTABLE_ONLY=false
PLATFORM=""   # lane for quarantine scoping (R32): ""/linux = default, macos
JOBS_RAW=""
JOBS_GIVEN=false

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
    --portable)
      PORTABLE_ONLY=true
      shift
      ;;
    --platform)
      if [ $# -lt 2 ]; then
        platform_usage_error "--platform requires an argument (linux or macos)"
      fi
      case "$2" in
        linux|macos) ;;
        *) platform_usage_error "--platform must be linux or macos, got '$2'" ;;
      esac
      PLATFORM="$2"
      shift 2
      ;;
    --platform=*)
      PVAL="${1#--platform=}"
      case "$PVAL" in
        linux|macos) ;;
        *) platform_usage_error "--platform must be linux or macos, got '$PVAL'" ;;
      esac
      PLATFORM="$PVAL"
      shift
      ;;
    --jobs)
      if [ $# -lt 2 ]; then
        echo "$PROG: --jobs requires an argument (positive integer or auto)" >&2
        exit 64
      fi
      JOBS_RAW="$2"
      JOBS_GIVEN=true
      shift 2
      ;;
    --jobs=*)
      JOBS_RAW="${1#--jobs=}"
      JOBS_GIVEN=true
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

# --- Resolve --jobs (CDT-534, R36) -------------------------------------------
# The flag wins over the env; an empty env value counts as omitted. `auto`
# is min(processors, 8): processors via getconf _NPROCESSORS_ONLN, then
# sysctl -n hw.ncpu, else 1 (never the GNU coreutils cpu-count tool; R32).
# jobs=1 keeps the serial
# loop below unchanged -- no worker scratch.

resolve_jobs_auto() {
  local n
  n=$(getconf _NPROCESSORS_ONLN 2>/dev/null) || n=""
  case "$n" in
    ''|*[!0-9]*) n=$(sysctl -n hw.ncpu 2>/dev/null) || n="" ;;
  esac
  case "$n" in
    ''|*[!0-9]*) n=1 ;;
  esac
  if [ "$n" -le 0 ]; then n=1; fi
  if [ "$n" -gt 8 ]; then n=8; fi
  echo "$n"
}

jobs_usage_error() { # jobs_usage_error <got> -- R36 wants exit 64 before
                     # any suite runs
  echo "$PROG: --jobs must be a positive integer or 'auto', got '$1'" >&2
  exit 64
}

if [ "$JOBS_GIVEN" = true ]; then
  JOBS_VAL="$JOBS_RAW"
else
  JOBS_VAL="${RUN_ALL_TESTS_JOBS:-}"
fi

case "$JOBS_VAL" in
  '')
    if [ "$JOBS_GIVEN" = true ]; then
      echo "$PROG: --jobs requires a non-empty value (positive integer or 'auto')" >&2
      exit 64
    fi
    JOBS=1
    ;;
  auto)
    JOBS=$(resolve_jobs_auto)
    ;;
  *[!0-9]*)
    jobs_usage_error "$JOBS_VAL"
    ;;
  *)
    if [ "$JOBS_VAL" -le 0 ]; then
      jobs_usage_error "$JOBS_VAL"
    fi
    JOBS="$JOBS_VAL"
    ;;
esac

# --- Scratch workdir (never hardcode /tmp; mktemp honors $TMPDIR) ----------

WORKDIR=$(mktemp -d "${TMPDIR:-/tmp}/run-all-tests.XXXXXX")
SCRATCH=""
SEED_SHA=""
KEEP_DIR=""   # CDT-545: persistent dir holding failed pool suites' full output

# CDT-554: a suite's orphaned child (watchdog sleep, backgrounded fixture)
# can hold cwd inside the scratch and keep files appearing in it, so a plain
# rm -rf can fail silently and leave a full .git/run-all-tests.* behind
# (observed 2026-10-12). Verify the removal: retry briefly, then warn on
# stderr naming the path -- hygiene never changes the run's exit code.
# No kill pass: only the suite wrapper and watchdog pids are tracked, not
# the suites' own grandchildren, so there is no safe target list to signal.
remove_dir_verified() { # remove_dir_verified <dir> -- rm -rf with a short
                        # retry; warn on stderr when it still exists
  local dir="$1" i=0
  rm -rf "$dir" || :
  while [ -d "$dir" ] && [ "$i" -lt 3 ]; do
    sleep 1
    rm -rf "$dir" || :
    i=$((i + 1))
  done
  if [ -d "$dir" ]; then
    echo "$PROG: warn: scratch directory not removed (a suite child may still hold cwd or files in it): $dir" >&2
  fi
  return 0
}

cleanup() { # rm -rf "$WORKDIR", plus the R37 worker scratch once one exists
  remove_dir_verified "$WORKDIR"
  if [ -n "$SCRATCH" ]; then
    remove_dir_verified "$SCRATCH"
  fi
  return 0
}
trap cleanup EXIT

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

# bash 3.2 / BSD userland (CDT-271). Full-line comments are ignored so a
# suite that only names a forbidden tool in a comment still runs.
suite_portable() {
  awk '
    /^[[:space:]]*#/ { next }
    /declare[[:space:]]+-A/ { bad=1 }
    /declare[[:space:]]+-n/ { bad=1 }
    /local[[:space:]]+-n/ { bad=1 }
    /(^|[[:space:];|&(])mapfile([[:space:]]|$)/ { bad=1 }
    /(^|[[:space:];|&(])readarray([[:space:]]|$)/ { bad=1 }
    /(^|[[:space:];|&(])flock([[:space:]]|$)/ { bad=1 }
    /(^|[[:space:];|&(])sha256sum([[:space:]]|$)/ { bad=1 }
    /(^|[[:space:];|&(])gtimeout([[:space:]]|$)/ { bad=1 }
    /(^|[[:space:];|&(])timeout([[:space:]]|$)/ { bad=1 }
    /grep[[:space:]]+-[A-Za-z]*P/ { bad=1 }
    /touch[[:space:]]+-d/ { bad=1 }
    /-printf([[:space:]]|$)/ { bad=1 }
    /\$\{[A-Za-z_][A-Za-z0-9_]*,,/ { bad=1 }
    /\$\{[A-Za-z_][A-Za-z0-9_]*\^\^/ { bad=1 }
    END { exit bad ? 1 : 0 }
  ' "$ROOT/$1"
}

# --- Quarantine-path reference list (R11) ------------------------------------
# SUITES_FILE stays the FULL R4 discovery list; the run list (below) may be
# narrowed by --portable. Quarantine paths validate against the full list, so
# an entry for a portable-excluded suite is valid data that can never apply
# (the suite is not run).

discover_suites > "$SUITES_FILE"

RUNLIST="$WORKDIR/runlist.txt"

if [ "$PORTABLE_ONLY" = true ]; then
  skipped=0
  while IFS= read -r suite; do
    [ -n "$suite" ] || continue
    if suite_portable "$suite"; then
      printf '%s\n' "$suite" >> "$RUNLIST"
    else
      skipped=$((skipped + 1))
    fi
  done < "$SUITES_FILE"
  if [ "$skipped" -gt 0 ]; then
    echo "warn: portable: skipped $skipped non-portable suite(s)" >&2
  fi
else
  cp "$SUITES_FILE" "$RUNLIST"
fi

if [ "$LIST_ONLY" = true ]; then
  cat "$RUNLIST"
  exit 0
fi

# --- Quarantine: validate + load (R11, CDT-502 scope column) -----------------
# MUST validate the whole file before running any suite -- 64 is a pre-run
# failure, never a mid-run one. Each non-comment line is
# <path> <scope> <reason>; scope is all or macos. Paths validate against the
# FULL discovery list (SUITES_FILE), not the --portable-filtered run list.

QFILE="$ROOT/tools/test-quarantine.txt"
QSEEN="$WORKDIR/quarantine-seen.txt"
: > "$QSEEN"

if [ -f "$QFILE" ]; then
  lineno=0
  while IFS= read -r qline || [ -n "$qline" ]; do
    lineno=$((lineno + 1))

    qpath=""
    qscope=""
    qreason=""
    read -r qpath qscope qreason <<< "$qline"

    [ -z "$qpath" ] && continue
    case "$qpath" in
      '#'*) continue ;;
    esac

    if [ -z "$qscope" ]; then
      echo "$PROG: $QFILE:$lineno: missing scope for $qpath" >&2
      exit 64
    fi
    case "$qscope" in
      all|macos) ;;
      *)
        echo "$PROG: $QFILE:$lineno: scope must be all or macos, got '$qscope'" >&2
        exit 64
        ;;
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
    printf '%s\t%s\t%s\n' "$qpath" "$qscope" "$qreason" >> "$QTSV"
  done < "$QFILE"
fi

# --- Worker scratch (CDT-534, R37) -------------------------------------------
# When jobs>1 every suite runs in a private clone under --root's
# git-common-dir: same filesystem as the object store, so `git clone --local`
# can hardlink ($TMPDIR is often another device and --local then fails with
# "Invalid cross-device link"). jobs=1 creates no scratch at all (R36).
# Overlay/restore helpers live in tools/run-all-tests-pool.sh (CLI cap 900).

if [ "$JOBS" -gt 1 ]; then
  POOL_SH="$(cd "$(dirname "$0")" && pwd)/run-all-tests-pool.sh"
  if [ ! -f "$POOL_SH" ]; then
    echo "$PROG: missing worker-pool helper $POOL_SH" >&2
    exit 1
  fi
  # Sourced, not exec'd: copy_tree_bytes / stage_paths /
  # drop_seed_paths_not_cached / restore_worker / release_worker.
  . "$POOL_SH"
  GCD=$(git -C "$ROOT" rev-parse --git-common-dir 2>/dev/null) || {
    echo "$PROG: cannot resolve the git-common-dir of $ROOT" >&2
    exit 1
  }
  case "$GCD" in
    /*) ;;
    *) GCD="$ROOT/$GCD" ;;
  esac
  SCRATCH=$(mktemp -d "$GCD/run-all-tests.XXXXXX") || {
    echo "$PROG: cannot create a scratch dir under $GCD" >&2
    exit 1
  }
  SEED="$SCRATCH/seed"

  # One seed clone of --root. It checks out --root's HEAD; the staged and
  # untracked-not-ignored bytes are overlaid below. The source index file
  # itself is never copied -- a worktree index is not a clone index (R37).
  if ! git clone --local --quiet "$ROOT" "$SEED" >/dev/null 2> "$WORKDIR/clone.err"; then
    echo "$PROG: cannot seed a worker clone from $ROOT:" >&2
    cat "$WORKDIR/clone.err" >&2
    exit 1
  fi

  git -C "$ROOT" ls-files -z --cached > "$WORKDIR/cached.lst" 2>/dev/null || {
    echo "$PROG: cannot list cached paths of $ROOT" >&2
    exit 1
  }
  git -C "$ROOT" ls-files -z --others --exclude-standard > "$WORKDIR/others.lst" 2>/dev/null || {
    echo "$PROG: cannot list untracked paths of $ROOT" >&2
    exit 1
  }

  copy_tree_bytes "$WORKDIR/cached.lst" "$ROOT" "$SEED" "$WORKDIR/cached-present.lst" || {
    echo "$PROG: cannot overlay cached bytes into the seed" >&2
    exit 1
  }
  stage_paths "$WORKDIR/cached-present.lst" "$SEED" || {
    echo "$PROG: cannot stage cached paths in the seed" >&2
    exit 1
  }
  drop_seed_paths_not_cached || {
    echo "$PROG: cannot drop staged deletions from the seed" >&2
    exit 1
  }
  copy_tree_bytes "$WORKDIR/others.lst" "$ROOT" "$SEED" || {
    echo "$PROG: cannot copy untracked bytes into the seed" >&2
    exit 1
  }

  # R39 snapshots: HEAD SHA (empty when unborn), HEAD file, config. Refs
  # restore copies the seed .git/refs + packed-refs (for-each-ref extras
  # cannot survive). Seed has no ignored files -- clone does not copy them,
  # overlay is cached + others --exclude-standard -- so restore's clean
  # -qfdx cannot drop a seed-build artifact. HOME/TMPDIR live under WORKDIR,
  # not the clone.
  SEED_SHA=$(git -C "$SEED" rev-parse HEAD 2>/dev/null) || SEED_SHA=""
  cp "$SEED/.git/HEAD" "$WORKDIR/seed.HEAD" || {
    echo "$PROG: cannot snapshot seed HEAD" >&2
    exit 1
  }
  cp "$SEED/.git/config" "$WORKDIR/seed.gitconfig" || {
    echo "$PROG: cannot snapshot seed config" >&2
    exit 1
  }

  i=1
  while [ "$i" -le "$JOBS" ]; do
    cp -a "$SEED" "$SCRATCH/worker.$i" || {
      echo "$PROG: cannot copy worker $i from the seed" >&2
      exit 1
    }
    i=$((i + 1))
  done
fi

# --- Execution (R6-R9) -------------------------------------------------------
# jobs=1 keeps the serial identity path; jobs>1 takes the R38 pool below it.
# Both share finalize_result/emit_result so status words, tails and counters
# are identical.

PASS_N=0
FAIL_N=0
TIMEOUT_N=0
QUAR_N=0
SKIP_N=0
EXIT_CODE=0

R_SUITE=""
R_RC=0
R_TIMED_OUT=false
R_DIRTIED=false
R_DISPATCH_FAILED=false
R_STATUS=""
R_DETAIL=""

finalize_result() { # finalize_result -- classify R_RC/R_TIMED_OUT/R_DIRTIED
                    # for R_SUITE (R6/R7/R9), apply the quarantine (R12,
                    # CDT-502 scope column), and bump the counters. Sets
                    # R_STATUS/R_DETAIL for emit_result. Shared by the
                    # serial and pool paths so both report identically.
  if [ "$R_DISPATCH_FAILED" = true ]; then
    R_STATUS="FAIL"
    R_DETAIL="could not prepare worker"
  elif [ "$R_TIMED_OUT" = true ]; then
    R_STATUS="TIMEOUT"
    R_DETAIL="timed out after ${TIMEOUT_SECS}s"
  elif [ "$R_DIRTIED" = true ]; then
    R_STATUS="FAIL"
    R_DETAIL="modified the working tree"
  elif [ "$R_RC" -eq 77 ]; then
    R_STATUS="SKIP"
    R_DETAIL=""
  elif [ "$R_RC" -eq 0 ]; then
    R_STATUS="PASS"
    R_DETAIL=""
  else
    R_STATUS="FAIL"
    R_DETAIL="exit $R_RC"
  fi

  # R12/CDT-502: an entry applies on this lane iff scope is all, or scope is
  # macos and the runner was started with --platform macos. A non-applying
  # (validated) entry is ignored: the suite counts like an unquarantined one.
  qscope=$(awk -F'\t' -v p="$R_SUITE" '$1==p{print $2; exit}' "$QTSV")
  if [ -n "$qscope" ]; then
    applies=false
    case "$qscope" in
      all) applies=true ;;
      macos)
        if [ "$PLATFORM" = "macos" ]; then applies=true; fi
        ;;
    esac
    if [ "$applies" = true ]; then
      case "$R_STATUS" in
        SKIP) : ;;
        PASS)
          echo "$PROG: warn: $R_SUITE is quarantined (tools/test-quarantine.txt) but passed; remove the entry" >&2
          ;;
        *)
          R_STATUS="QUARANTINED"
          ;;
      esac
    fi
  fi

  case "$R_STATUS" in
    PASS) PASS_N=$((PASS_N + 1)) ;;
    FAIL) FAIL_N=$((FAIL_N + 1)); EXIT_CODE=1 ;;
    TIMEOUT) TIMEOUT_N=$((TIMEOUT_N + 1)); EXIT_CODE=1 ;;
    QUARANTINED) QUAR_N=$((QUAR_N + 1)) ;;
    SKIP) SKIP_N=$((SKIP_N + 1)) ;;
  esac
}

emit_result() { # emit_result <outfile> -- one R10 line for R_STATUS/R_SUITE,
                # plus the last 20 lines of <outfile> after a red status.
  if [ -n "$R_DETAIL" ]; then
    printf '%s %s (%s)\n' "$R_STATUS" "$R_SUITE" "$R_DETAIL"
  else
    printf '%s %s\n' "$R_STATUS" "$R_SUITE"
  fi
  case "$R_STATUS" in
    FAIL|TIMEOUT|QUARANTINED)
      tail -n 20 "$1" | sed 's/^/    | /'
      ;;
  esac
}

keep_failed_output() { # keep_failed_output <k> -- CDT-545: a red pool
                       # suite's out.<k> dies with WORKDIR in cleanup() and
                       # only the 20-line tail was printed, so a flake
                       # leaves nothing to hunt with. Move the full output
                       # into a persistent keep-dir under TMPDIR (outside
                       # the scratch, so cleanup() never touches it). The
                       # dir is created lazily on the first red suite: a
                       # green run leaves no keep-dir behind. Pool path
                       # only -- jobs=1 must stay byte-identical (R10/AC2).
  local k="$1" dest
  if [ -z "$KEEP_DIR" ]; then
    KEEP_DIR="${TMPDIR:-/tmp}/run-all-tests-failed.$(date +%Y%m%d-%H%M%S).$$"
    if ! mkdir -p "$KEEP_DIR"; then
      echo "$PROG: warn: cannot create $KEEP_DIR; $R_SUITE's full output is lost" >&2
      KEEP_DIR=""
      return 0
    fi
  fi
  dest="$KEEP_DIR/${R_SUITE//\//__}.out"
  if mv "$WORKDIR/out.$k" "$dest"; then
    echo "$PROG: info: kept full output for $R_SUITE: $dest" >&2
  else
    echo "$PROG: warn: could not keep $R_SUITE's full output in $KEEP_DIR" >&2
  fi
  return 0
}

if [ "$JOBS" -gt 1 ]; then
  # --- Pool (CDT-534, R38): free-worker dispatch, buffered R4 emit ---------
  # At most JOBS suite+watchdog process groups in flight (in_flight =
  # dispatched-not-reaped). Dispatch onto any free worker as soon as rc.<k>
  # (or dispatch-failed / finished watchdog) shows a slot is done -- do not
  # wait on the oldest pid before filling a free slot. Reap collects the
  # worker and buffers the result; flush_emit prints in R4 order. Per-suite
  # slot state lives in files (bash 3.2 has no associative arrays).
  set -m

  FREELIST="$WORKDIR/freelist.txt"
  : > "$FREELIST"
  i=1
  while [ "$i" -le "$JOBS" ]; do
    printf '%s\n' "$i" >> "$FREELIST"
    i=$((i + 1))
  done

  N_SUITES=0
  while IFS= read -r _rl || [ -n "$_rl" ]; do
    N_SUITES=$((N_SUITES + 1))
  done < "$RUNLIST"

  dispatch_suite() { # dispatch_suite <k> <worker> -- launch suite k
                     # (0-based) in <worker>. A setup failure records a
                     # dispatch-failed marker that reap_suite turns into a
                     # FAIL; in_flight / freelist stay consistent.
    local k="$1" worker="$2" suite w home tmp
    suite=$(sed -n "$((k + 1))p" "$RUNLIST")
    w="$SCRATCH/worker.$worker"
    printf '%s\n' "$worker" > "$WORKDIR/worker.for.$k"

    # Fresh per-suite HOME/TMPDIR under WORKDIR, outside the clone (R39):
    # wiped per dispatch so suites sharing a worker cannot see each
    # other's temp state. Not inside the worker worktree or its .git, so
    # R9 snapshots stay clean without a seed exclude.
    home="$WORKDIR/w.$worker.home"
    tmp="$WORKDIR/w.$worker.tmp"
    if ! rm -rf "$home" "$tmp" || ! mkdir -p "$home" "$tmp"; then
      : > "$WORKDIR/dispatch-failed.$k"
      : > "$WORKDIR/inflight.$k"
      return 0
    fi
    if ! git -C "$w" status --porcelain --untracked-files=all > "$WORKDIR/before.$k"; then
      : > "$WORKDIR/dispatch-failed.$k"
      : > "$WORKDIR/inflight.$k"
      return 0
    fi

    : > "$WORKDIR/out.$k"
    rm -f "$WORKDIR/flag.$k" "$WORKDIR/rc.$k"

    # The suite and its watchdog each get their own process group (set -m),
    # so TERM/KILL targeting -"$pid" never touches the runner or another
    # in-flight suite. The per-suite override is exactly HOME/TMPDIR (R6);
    # everything else is inherited. The wrapper records the suite's own
    # return in rc.<k> so the watchdog can tell "finished before the
    # deadline" from "still running" -- a deferred reap of a fast suite
    # must not inherit a stale timeout flag.
    ( cd "$w" && HOME="$home" TMPDIR="$tmp" bash "$suite" </dev/null >"$WORKDIR/out.$k" 2>&1; rc=$?; printf '%s\n' "$rc" > "$WORKDIR/rc.$k" || true; exit "$rc" ) &
    pid=$!
    ( sleep "$TIMEOUT_SECS"; [ -f "$WORKDIR/rc.$k" ] && exit 0; : > "$WORKDIR/flag.$k"; kill -TERM -- -"$pid" 2>/dev/null; sleep 5; kill -KILL -- -"$pid" 2>/dev/null ) &
    printf '%s\n' "$pid" > "$WORKDIR/pid.$k"
    printf '%s\n' "$!" > "$WORKDIR/wd.$k"
    : > "$WORKDIR/inflight.$k"
  }

  suite_ready() { # suite_ready <k> -- 0 when slot k can be reaped without
                  # blocking the scheduler. rc.<k> means the wrapper exited;
                  # dispatch-failed needs no wait; a finished watchdog means
                  # the R7 KILL already ran (do not reap during the 5s grace
                  # -- that would wait-on-that-pid and stall dispatch).
    local k="$1" wd
    if [ -f "$WORKDIR/dispatch-failed.$k" ]; then
      return 0
    fi
    if [ -f "$WORKDIR/rc.$k" ]; then
      return 0
    fi
    if [ -f "$WORKDIR/flag.$k" ] && [ -f "$WORKDIR/wd.$k" ]; then
      wd=$(cat "$WORKDIR/wd.$k")
      if ! kill -0 "$wd" 2>/dev/null; then
        return 0
      fi
    fi
    return 1
  }

  reap_suite() { # reap_suite <k> -- wait pid (instant: suite_ready already
                 # saw it done), resolve watchdog, snapshot + restore + free
                 # the worker, buffer the result. Does not emit (R10).
    local k="$1" suite pid wd rc worker w after before
    suite=$(sed -n "$((k + 1))p" "$RUNLIST")

    R_SUITE="$suite"
    R_DISPATCH_FAILED=false
    if [ -f "$WORKDIR/dispatch-failed.$k" ] || [ ! -f "$WORKDIR/pid.$k" ]; then
      R_DISPATCH_FAILED=true
      R_RC=1
      R_TIMED_OUT=false
      R_DIRTIED=false
      : > "$WORKDIR/out.$k"
      worker=$(cat "$WORKDIR/worker.for.$k" 2>/dev/null)
      if [ -n "$worker" ]; then
        release_worker "$worker"
      fi
    else
      pid=$(cat "$WORKDIR/pid.$k")
      wait "$pid" 2>/dev/null
      rc=$?

      wd=$(cat "$WORKDIR/wd.$k")
      if [ -f "$WORKDIR/flag.$k" ]; then
        wait "$wd" 2>/dev/null
      else
        kill -- -"$wd" 2>/dev/null
        wait "$wd" 2>/dev/null
      fi

      worker=$(cat "$WORKDIR/worker.for.$k")
      w="$SCRATCH/worker.$worker"
      after=$(git -C "$w" status --porcelain --untracked-files=all)
      before=$(cat "$WORKDIR/before.$k")
      R_RC=$rc
      if [ -f "$WORKDIR/flag.$k" ]; then R_TIMED_OUT=true; else R_TIMED_OUT=false; fi
      if [ "$before" = "$after" ]; then R_DIRTIED=false; else R_DIRTIED=true; fi

      release_worker "$worker"
    fi

    printf '%s\n' "$R_SUITE" > "$WORKDIR/saved.suite.$k" || exit 1
    printf '%s\n' "$R_RC" > "$WORKDIR/saved.rc.$k" || exit 1
    printf '%s\n' "$R_TIMED_OUT" > "$WORKDIR/saved.timed.$k" || exit 1
    printf '%s\n' "$R_DIRTIED" > "$WORKDIR/saved.dirty.$k" || exit 1
    printf '%s\n' "$R_DISPATCH_FAILED" > "$WORKDIR/saved.df.$k" || exit 1
    : > "$WORKDIR/done.$k"

    rm -f "$WORKDIR/pid.$k" "$WORKDIR/wd.$k" "$WORKDIR/worker.for.$k" \
      "$WORKDIR/before.$k" "$WORKDIR/flag.$k" \
      "$WORKDIR/rc.$k" "$WORKDIR/dispatch-failed.$k" "$WORKDIR/inflight.$k"
  }

  flush_emit() { # print every buffered result whose R4 predecessors have
                 # already been printed (R10). FAIL tails stay verbatim.
    while [ "$next_emit" -lt "$N_SUITES" ] && [ -f "$WORKDIR/done.$next_emit" ]; do
      R_SUITE=$(cat "$WORKDIR/saved.suite.$next_emit")
      R_RC=$(cat "$WORKDIR/saved.rc.$next_emit")
      R_TIMED_OUT=$(cat "$WORKDIR/saved.timed.$next_emit")
      R_DIRTIED=$(cat "$WORKDIR/saved.dirty.$next_emit")
      R_DISPATCH_FAILED=$(cat "$WORKDIR/saved.df.$next_emit")
      finalize_result
      emit_result "$WORKDIR/out.$next_emit"
      case "$R_STATUS" in
        # CDT-545: preserve the full output of red suites (the tail above is
        # truncated); out.<k> would otherwise be deleted with the WORKDIR.
        FAIL|TIMEOUT|QUARANTINED) keep_failed_output "$next_emit" ;;
      esac
      rm -f "$WORKDIR/saved.suite.$next_emit" "$WORKDIR/saved.rc.$next_emit" \
        "$WORKDIR/saved.timed.$next_emit" "$WORKDIR/saved.dirty.$next_emit" \
        "$WORKDIR/saved.df.$next_emit" "$WORKDIR/out.$next_emit" \
        "$WORKDIR/done.$next_emit"
      next_emit=$((next_emit + 1))
    done
  }

  next_dispatch=0
  next_emit=0
  in_flight=0
  idle_s=0
  while [ "$next_emit" -lt "$N_SUITES" ]; do
    while [ "$next_dispatch" -lt "$N_SUITES" ] && [ "$in_flight" -lt "$JOBS" ]; do
      worker=$(head -n 1 "$FREELIST")
      if [ -z "$worker" ]; then
        echo "$PROG: internal error: no free worker" >&2
        exit 1
      fi
      if ! { tail -n +2 "$FREELIST" > "$WORKDIR/freelist.tmp" && mv "$WORKDIR/freelist.tmp" "$FREELIST"; }; then
        echo "$PROG: internal error: cannot update the free-worker list" >&2
        exit 1
      fi
      dispatch_suite "$next_dispatch" "$worker"
      next_dispatch=$((next_dispatch + 1))
      in_flight=$((in_flight + 1))
      idle_s=0
    done

    reaped_this=0
    k=0
    while [ "$k" -lt "$next_dispatch" ]; do
      if [ -f "$WORKDIR/inflight.$k" ] && suite_ready "$k"; then
        reap_suite "$k"
        in_flight=$((in_flight - 1))
        reaped_this=1
        idle_s=0
      fi
      k=$((k + 1))
    done
    flush_emit

    if [ "$next_emit" -ge "$N_SUITES" ]; then
      break
    fi
    if [ "$reaped_this" -eq 1 ]; then
      continue
    fi
    if [ "$in_flight" -eq 0 ]; then
      echo "$PROG: internal error: pool stalled with nothing in flight" >&2
      exit 1
    fi
    sleep 1
    idle_s=$((idle_s + 1))
    if [ "$idle_s" -gt $((TIMEOUT_SECS + 10)) ]; then
      echo "$PROG: internal error: pool idle for ${idle_s}s with $in_flight in flight" >&2
      exit 1
    fi
  done
  set +m
else
  # --- Serial (R6): the jobs=1 identity path -------------------------------
  # Byte-identical with the pre-CDT-534 runner: cwd = --root, no worker
  # scratch, no per-suite env override, R4 order trivially.
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

    R_SUITE="$suite"
    R_RC=$rc
    R_TIMED_OUT=$timed_out
    R_DIRTIED=$dirtied
    R_DISPATCH_FAILED=false
    finalize_result
    emit_result "$OUTFILE"
  done < "$RUNLIST"
fi

TOTAL=$((PASS_N + FAIL_N + TIMEOUT_N + QUAR_N + SKIP_N))
printf '%s suites: %s passed, %s failed, %s timed out, %s quarantined, %s skipped\n' \
  "$TOTAL" "$PASS_N" "$FAIL_N" "$TIMEOUT_N" "$QUAR_N" "$SKIP_N"

exit "$EXIT_CODE"
