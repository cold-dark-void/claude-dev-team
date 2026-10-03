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
# chmod and stat: sidecar publishes through atomic_write, which keeps the file mode.
path_farm "$FARM" bash git jq sed awk date mkdir head rm dirname cat mv mktemp tr basename printf flock chmod stat
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

# ---- AC-E: perl present (no timeout/gtimeout) → with_timeout perl fallback --
# CDT-284: poll_local_test must RUN the test under the perl supervisor instead
# of logging timeout_missing. The farm PATH holds no perl, so this adds it.
reset_sidecar_local
PERL_BIN=$(command -v perl) || die "perl not found on host (needed for the fallback test)"
PL_DIR="$TMP/perl-bin"
mkdir -p "$PL_DIR"
ln -sf "$PERL_BIN" "$PL_DIR/perl"
E_PATH3="$E_MOCK_BIN:$PL_DIR:$FARM"
if PATH="$E_PATH3" command -v timeout >/dev/null 2>&1 || PATH="$E_PATH3" command -v gtimeout >/dev/null 2>&1; then
  die "perl-fallback PATH unexpectedly resolves timeout/gtimeout"
fi
if ! PATH="$E_PATH3" command -v perl >/dev/null 2>&1; then
  die "perl-fallback PATH does not resolve perl"
fi

E_OUT3="$TMP/e-out3.txt"
E_ERR3="$TMP/e-err3.txt"
"$REAL_TIMEOUT" 30 env PATH="$E_PATH3" "$BASH_BIN" "$POLL_CLI" "$TICKET" >"$E_OUT3" 2>"$E_ERR3"
e3_rc=$?
e3_out=$(cat "$E_OUT3")

e3_ok=1
if [ "$e3_rc" -ne 0 ]; then
  echo "  FAIL [AC-E perl-fallback]: rc=$e3_rc (want 0)"
  e3_ok=0
fi
if [ "$e3_out" != "wait" ]; then
  echo "  FAIL [AC-E perl-fallback]: stdout='$e3_out' (want 'wait')"
  e3_ok=0
fi
if grep -q 'outcome=timeout_missing' ".claude/ci-watch/${TICKET}.log" 2>/dev/null; then
  echo "  FAIL [AC-E perl-fallback]: log has timeout_missing (perl fallback must run the test)"
  e3_ok=0
fi
if [ "$e3_ok" -eq 1 ]; then
  echo "  PASS [AC-E perl-fallback]: no timeout_missing when only perl is present exit=0"
  PASS=$((PASS + 1))
else
  FAIL=$((FAIL + 1))
fi

# ---- CDT-282 [09 F23]: private temp files (mktemp), not a name per ticket ----
# poll.sh wrote ${TMPDIR:-/tmp}/ci-watch-{out,err}-<TICKET>.txt: a fixed name an
# attacker can plant a symlink on (CWE-377). The mock gh lists TMPDIR while the
# poll runs, when both temp files exist.
echo ""
echo "Temp files: mktemp names, removed on exit"
LS_MOCK="$TMP/ls-mock-bin"
mkdir -p "$LS_MOCK"
cat > "$LS_MOCK/gh" << 'LSMOCK'
#!/bin/sh
case " $* " in
  *" checks "*) ls "$TMPDIR" > "$GH_MOCK_LS" 2>/dev/null; printf '%s' "${GH_MOCK_JSON-}"; exit 0 ;;
  *" view "*) echo OPEN; exit 0 ;;
esac
exit 99
LSMOCK
chmod +x "$LS_MOCK/gh"
reset_sidecar 0
T_LS="$TMP/ls.log"
: > "$T_LS"
t_out=$(PATH="$LS_MOCK:$PATH" GH_MOCK_LS="$T_LS" GH_MOCK_JSON='[]' bash "$POLL_CLI" "$TICKET" 2>/dev/null)
if [ "$t_out" = "done" ] && grep -Eq '^ci-watch-err\.[A-Za-z0-9]{6}$' "$T_LS" \
   && ! grep -q "^ci-watch-err-${TICKET}\.txt$" "$T_LS"; then
  echo "  PASS [temp names]: the err file is ci-watch-err.<random>, not a per-ticket name"
  PASS=$((PASS + 1))
else
  echo "  FAIL [temp names]: out='$t_out' TMPDIR listing during the poll: $(tr '\n' ' ' < "$T_LS")"
  FAIL=$((FAIL + 1))
fi
left=$(ls "$TMPDIR" 2>/dev/null | grep -c '^ci-watch-' || true)
if [ "${left:-0}" = "0" ]; then
  echo "  PASS [temp cleanup]: no ci-watch-* file is left in TMPDIR"
  PASS=$((PASS + 1))
else
  echo "  FAIL [temp cleanup]: $left ci-watch-* file(s) left in TMPDIR"
  FAIL=$((FAIL + 1))
fi

# ---- CDT-282 [09 F23]: local-test mode in a shared epic integration tree ----
# A child of a shared epic tree has no .worktrees/<TICKET>; its tree is the epic
# integration path (epic-lib resolve-child-worktree). poll.sh used to look only
# at .worktrees/<TICKET> and answered wait for ever.
echo ""
echo "Local-test mode: slug is not always the ticket (shared epic tree)"
NPM_MOCK="$TMP/npm-mock-bin"
mkdir -p "$NPM_MOCK"
printf '#!/bin/sh\nexit "${NPM_MOCK_RC:-0}"\n' > "$NPM_MOCK/npm"
chmod +x "$NPM_MOCK/npm"
INT_WT="$TMP/int-wt"
mkdir -p "$INT_WT"
printf '{"scripts":{"test":"x"}}\n' > "$INT_WT/package.json"
reset_sidecar_local
s_out=$(PATH="$NPM_MOCK:$PATH" EPIC_INTEGRATION_PATH="$INT_WT" bash "$POLL_CLI" "$TICKET" 2>/dev/null)
s_out_fail=$(PATH="$NPM_MOCK:$PATH" EPIC_INTEGRATION_PATH="$INT_WT" NPM_MOCK_RC=1 bash "$POLL_CLI" "$TICKET" 2>/dev/null)
# control: no shared tree and no .worktrees/<TICKET> → nothing to test → wait
s_out_none=$(PATH="$NPM_MOCK:$PATH" bash "$POLL_CLI" "$TICKET" 2>/dev/null)
if [ "$s_out" = "done" ] && [ "$s_out_fail" = "fail" ] && [ "$s_out_none" = "wait" ]; then
  echo "  PASS [shared tree]: passing tests → done, failing tests → fail, no tree → wait"
  PASS=$((PASS + 1))
else
  echo "  FAIL [shared tree]: pass='$s_out' (want done) fail='$s_out_fail' (want fail) none='$s_out_none' (want wait)"
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
# ---- WP 5-04: poll-error cap, empty debounce, stale fixer, sidecar, detect-mode ----
echo ""
echo "WP 5-04: poll_error cap, empty checks, stale fixer"

reset_sidecar 0
export GH_MOCK_JSON='not-json'
export GH_MOCK_RC=1
export GH_MOCK_STATE=OPEN
cap_last=""
cap_i=1
while [ "$cap_i" -le 9 ]; do
  cap_last=$(bash "$POLL_CLI" "$TICKET" 2>/dev/null)
  cap_i=$((cap_i + 1))
done
cap_tenth=$(bash "$POLL_CLI" "$TICKET" 2>/dev/null)
if [ "$cap_last" = "wait" ] && [ "$cap_tenth" = "cap" ]; then
  echo "  PASS [poll_error cap]: 9 errors wait, 10th emits cap"
  PASS=$((PASS + 1))
else
  echo "  FAIL [poll_error cap]: 9th='$cap_last' (want wait) 10th='$cap_tenth' (want cap)"
  FAIL=$((FAIL + 1))
fi

mkdir -p .github/workflows
reset_sidecar 0
export GH_MOCK_JSON='[]'
export GH_MOCK_RC=0
e1=$(bash "$POLL_CLI" "$TICKET" 2>/dev/null)
e2=$(bash "$POLL_CLI" "$TICKET" 2>/dev/null)
e3=$(bash "$POLL_CLI" "$TICKET" 2>/dev/null)
if [ "$e1" = "wait" ] && [ "$e2" = "wait" ] && [ "$e3" = "done" ]; then
  echo "  PASS [empty debounce]: workflows present, 3rd consecutive [] is done"
  PASS=$((PASS + 1))
else
  echo "  FAIL [empty debounce]: '$e1' '$e2' '$e3' (want wait wait done)"
  FAIL=$((FAIL + 1))
fi

reset_sidecar 0
export GH_MOCK_JSON='[]'
bash "$POLL_CLI" "$TICKET" >/dev/null 2>&1
export GH_MOCK_JSON="$PENDING_JSON"
export GH_MOCK_RC=8
mid=$(bash "$POLL_CLI" "$TICKET" 2>/dev/null)
export GH_MOCK_JSON='[]'
export GH_MOCK_RC=0
again=$(bash "$POLL_CLI" "$TICKET" 2>/dev/null)
again_n=$(bash "$SIDECAR_CLI" get "$TICKET" empty_poll_count 2>/dev/null || echo missing)
if [ "$mid" = "wait" ] && [ "$again" = "wait" ] && [ "$again_n" = "1" ]; then
  echo "  PASS [empty reset]: a non-empty poll resets the empty count"
  PASS=$((PASS + 1))
else
  echo "  FAIL [empty reset]: mid='$mid' again='$again' count='$again_n' (want wait wait 1)"
  FAIL=$((FAIL + 1))
fi
rm -rf .github/workflows

reset_sidecar 0
old_epoch=$(( $(date +%s) - 1801 ))
bash "$SIDECAR_CLI" set "$TICKET" fixer_active true >/dev/null
bash "$SIDECAR_CLI" set "$TICKET" fixer_started_at "$old_epoch" >/dev/null
export GH_MOCK_JSON="$FAIL_JSON"
export GH_MOCK_RC=1
stale_out=$(bash "$POLL_CLI" "$TICKET" 2>/dev/null)
stale_retry=$(bash "$SIDECAR_CLI" get "$TICKET" retry_count 2>/dev/null || echo missing)
if [ "$stale_out" = "fail" ] && [ "$stale_retry" = "1" ] \
   && grep -q 'outcome=fixer_stale' ".claude/ci-watch/${TICKET}.log"; then
  echo "  PASS [fixer stale]: old fixer_started_at logs fixer_stale, counts a retry, emits fail"
  PASS=$((PASS + 1))
else
  echo "  FAIL [fixer stale]: out='$stale_out' (want fail) retry='$stale_retry' (want 1)"
  FAIL=$((FAIL + 1))
fi

reset_sidecar 0
bash "$SIDECAR_CLI" set "$TICKET" fixer_active true >/dev/null
bash "$SIDECAR_CLI" set "$TICKET" fixer_started_at "$(date +%s)" >/dev/null
fresh_out=$(bash "$POLL_CLI" "$TICKET" 2>/dev/null)
if [ "$fresh_out" = "wait" ] && ! grep -q 'outcome=fixer_stale' ".claude/ci-watch/${TICKET}.log"; then
  echo "  PASS [fixer fresh]: a new fixer_started_at still emits wait"
  PASS=$((PASS + 1))
else
  echo "  FAIL [fixer fresh]: out='$fresh_out' (want wait)"
  FAIL=$((FAIL + 1))
fi

echo ""
echo "WP 5-04: sidecar set/delete and detect-mode auth"
bash "$SIDECAR_CLI" init TSET ci 7 br >/dev/null
bash "$SIDECAR_CLI" set TSET pr_number 99 >/dev/null
bash "$SIDECAR_CLI" set TSET fixer_active true >/dev/null
bash "$SIDECAR_CLI" set --string TSET note true >/dev/null
pr_type=$(jq -r '.pr_number | type' .claude/ci-watch/TSET.json)
fx_type=$(jq -r '.fixer_active | type' .claude/ci-watch/TSET.json)
note_type=$(jq -r '.note | type' .claude/ci-watch/TSET.json)
if [ "$pr_type" = "string" ] && [ "$fx_type" = "boolean" ] && [ "$note_type" = "string" ]; then
  echo "  PASS [sidecar set]: digit string stays a string; true stays JSON; --string forces a string"
  PASS=$((PASS + 1))
else
  echo "  FAIL [sidecar set]: pr=$pr_type (want string) fixer_active=$fx_type (want boolean) note=$note_type (want string)"
  FAIL=$((FAIL + 1))
fi
echo secret > .claude/ci-watch/TSET.last_failure.txt
echo logline > .claude/ci-watch/TSET.log
echo held > .claude/ci-watch/.lock
bash "$SIDECAR_CLI" delete TSET
del_left=""
[ -f .claude/ci-watch/TSET.json ] && del_left="${del_left}json "
[ -f .claude/ci-watch/TSET.last_failure.txt ] && del_left="${del_left}last_failure "
[ -f .claude/ci-watch/TSET.log ] && del_left="${del_left}log "
if [ -z "$del_left" ] && [ -f .claude/ci-watch/.lock ]; then
  echo "  PASS [sidecar delete]: json, log, and last_failure are gone; the shared lock stays"
  PASS=$((PASS + 1))
else
  echo "  FAIL [sidecar delete]: left='${del_left:-none}' lock=$([ -f .claude/ci-watch/.lock ] && echo yes || echo no)"
  FAIL=$((FAIL + 1))
fi

DET_CLI="$SCRIPT_DIR/detect-mode.sh"
DET_WT="$TMP/det-wt"
mkdir -p "$DET_WT/.github/workflows" "$DET_WT/py-only"
printf 'print("x")\n' > "$DET_WT/py-only/setup.py"
AUTH_BIN="$TMP/auth-bin"
mkdir -p "$AUTH_BIN"
cat > "$AUTH_BIN/gh" << 'AUTH'
#!/bin/sh
case " $* " in
  *" auth "*) exit 1 ;;
  *" checks "*) exit 0 ;;
esac
exit 0
AUTH
chmod +x "$AUTH_BIN/gh"
unauth=$(PATH="$AUTH_BIN:$PATH" bash "$DET_CLI" "$DET_WT" | head -1)
cat > "$AUTH_BIN/gh" << 'AUTH'
#!/bin/sh
case " $* " in
  *" auth "*) exit 0 ;;
  *" checks "*) exit 0 ;;
esac
exit 0
AUTH
chmod +x "$AUTH_BIN/gh"
authed=$(PATH="$AUTH_BIN:$PATH" bash "$DET_CLI" "$DET_WT" | head -1)
local_mode=$(bash "$DET_CLI" "$DET_WT/py-only" | head -1)
if [ "$unauth" = "none" ] && [ "$authed" = "ci" ] && [ "$local_mode" = "local-test" ]; then
  echo "  PASS [detect-mode]: unauthenticated gh is not ci; auth + workflows is ci; setup.py is local-test"
  PASS=$((PASS + 1))
else
  echo "  FAIL [detect-mode]: unauth='$unauth' (want none) authed='$authed' (want ci) local='$local_mode' (want local-test)"
  FAIL=$((FAIL + 1))
fi

echo ""
echo "Results: PASS=$PASS FAIL=$FAIL"
if [ "$FAIL" -ne 0 ]; then
  exit 1
fi
exit 0
