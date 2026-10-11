#!/usr/bin/env bash
# tests/lib/run-all-tests-harness.sh — shared helpers for
# tools/run-all-tests-test.sh (SPEC-030 R17). Mechanical extract; the
# semantics encode R17 expectations, keep them byte-identical.
#
# Caller contract: set RUNNER (path to tools/run-all-tests.sh) and TMP
# (a mktemp -d dir the caller cleans up on EXIT) before sourcing, and
# own the PASS/FAIL counters plus OUT/ERR/RC that these helpers write.
# Nothing here runs as root and nothing is installed.

pass() { PASS=$((PASS + 1)); }
fail() { # fail <message>
  FAIL=$((FAIL + 1))
  echo "FAIL: $1"
  [ -n "$OUT" ] && echo "$OUT" | head -20
}

run_runner() { # run_runner <args...> -- captures OUT + RC (stdout+stderr
               # merged). Prefix with VAR=value to set env for this call
               # only, e.g. `RUN_ALL_TESTS_TIMEOUT=2 run_runner --root "$R4"`.
  OUT=$(bash "$RUNNER" "$@" 2>&1)
  RC=$?
}

run_runner_split() { # run_runner_split <args...> -- like run_runner, but
                      # captures stdout (OUT) and stderr (ERR) separately,
                      # so a test can prove a line went to the right stream.
  local errfile
  errfile="$TMP/run_runner_split.stderr.$$"
  OUT=$(bash "$RUNNER" "$@" 2>"$errfile")
  RC=$?
  ERR=$(cat "$errfile" 2>/dev/null)
  rm -f "$errfile"
}

expect_exit() { # expect_exit <want> <label>
  if [ "$RC" -eq "$1" ]; then pass; else
    fail "$2: got exit $RC, want $1"
  fi
}

expect_out() { # expect_out <substring> <label>
  if echo "$OUT" | grep -qF "$1"; then pass; else
    fail "$2: output missing '$1'"
  fi
}

expect_out_line() { # expect_out_line <exact line> <label> -- unlike
                     # expect_out, matches a whole line only (a plain
                     # substring check on e.g. "test.sh" is vacuous: it also
                     # matches "new-test.sh").
  if echo "$OUT" | grep -qFx -- "$1"; then pass; else
    fail "$2: output missing exact line '$1'"
  fi
}

expect_not_out() { # expect_not_out <substring> <label>
  if echo "$OUT" | grep -qF "$1"; then
    fail "$2: output unexpectedly contains '$1'"
  else pass; fi
}

expect_no_process() { # expect_no_process <marker> <label> -- retries pgrep
                       # for up to ~2s to absorb the sub-millisecond
                       # scheduling race between the direct child (bash,
                       # blocked in `wait`) exiting on TERM and the
                       # grandchild -- in the same process group, signalled
                       # at the same instant -- finishing its own exit; a
                       # REAL leftover would still be there well past this
                       # window. Matched by its unique marker (own argv[0],
                       # via `exec -a`), never a bare `sleep 987` -- that
                       # would also match an unrelated host process of the
                       # same name.
  local _try
  for _try in 1 2 3 4 5 6 7 8 9 10; do
    pgrep -f -- "$1" >/dev/null 2>&1 || { pass; return; }
    sleep 0.2
  done
  fail "$2 (marker $1 still running)"
}

new_root() { # new_root -- prints a fresh mktemp git tree (init, no commit)
  local d
  d=$(mktemp -d "$TMP/root.XXXXXX")
  git init -q "$d"
  printf '%s\n' "$d"
}

ok_suite()    { printf '#!/usr/bin/env bash\nexit 0\n'; }
fail_suite()  { printf '#!/usr/bin/env bash\nexit 1\n'; }
skip_suite()  { printf '#!/usr/bin/env bash\nexit 77\n'; }
dirty_suite() { printf '#!/usr/bin/env bash\necho dirty > dirty-file.txt\nexit 0\n'; }

gen_sleep_suite() { # gen_sleep_suite <token> [ignore-term] -- suite whose
                     # grandchild sleeps under a unique marker (its argv[0],
                     # via `exec -a`) so a test can `pgrep -f` this exact
                     # invocation without matching an unrelated host `sleep`
                     # process. With the optional second arg "ignore-term",
                     # the grandchild also ignores TERM: the suite leader
                     # itself does not, so it dies on TERM and `wait "$pid"`
                     # in the runner returns before the grandchild does --
                     # only the watchdog's later KILL (R7) can end it.
  local token="$1" prefix=""
  [ "${2:-}" = "ignore-term" ] && prefix='trap "" TERM; '
  cat <<SUITE
#!/usr/bin/env bash
( ${prefix}exec -a '$token' sleep 987 ) &
wait
SUITE
}
