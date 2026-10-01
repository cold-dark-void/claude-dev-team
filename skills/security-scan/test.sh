#!/usr/bin/env bash
# skills/security-scan/test.sh — scan.sh contract (WP 2-02; CDT-282 [09 F23],
# rv-bh-c001).
#
#   - Its output directory is a private mktemp -d directory (mode 700, random
#     name), not ${TMPDIR:-/tmp}/dev-team-security-scan-$$ (a predictable path,
#     CWE-377).
#   - SECURITY_SCAN_OUT still names the output directory.
#   - More than 40 targets are cut to 40 (CLI argument cap) and the summary
#     says so, with both counts. 40 targets or fewer print no such line.
#   - The scan never fails the caller: exit 0 with no scanner installed.
#
# The PATH holds only the commands scan.sh needs, so a host semgrep or codeql
# is never run. Hermetic: private TMPDIR/HOME (tests/lib/hermetic.sh).
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCAN="$ROOT/skills/security-scan/scan.sh"

# shellcheck source=../../tests/lib/hermetic.sh
. "$ROOT/tests/lib/hermetic.sh"
# shellcheck source=../../tests/lib/check.sh
. "$ROOT/tests/lib/check.sh"
# shellcheck source=../../tests/lib/path-farm.sh
. "$ROOT/tests/lib/path-farm.sh"
hermetic_init
pass=0
fail=0

BASH_BIN=$(command -v bash)
FARM="$HERMETIC_ROOT/farm"
path_farm "$FARM" git mkdir mktemp cat rm dirname basename chmod sed sort grep
REPO="$HERMETIC_ROOT/repo"
mkdir -p "$REPO"
git -C "$REPO" init -q .
cd "$REPO" || exit 1

# scan <args...> — sets OUT, RC
scan() {
  RC=0
  OUT=$(PATH="$FARM" "$BASH_BIN" "$SCAN" "$@" 2>&1) || RC=$?
}
out_dir() { printf '%s\n' "$OUT" | sed -n 's/^OUT_DIR=//p' | tail -1; }

# ---- the default output directory is a private mktemp -d directory --------
scan a.txt
D=$(out_dir)
[ "$RC" -eq 0 ] && pass_line "exit 0 with no scanner installed" || fail_line "exit $RC: $OUT"
case "$D" in "$TMPDIR"/*) pass_line "the output directory is under TMPDIR" ;; *) fail_line "output directory [$D] is not under TMPDIR [$TMPDIR]" ;; esac
BASE=$(basename -- "$D")
if printf '%s\n' "$BASE" | grep -Eq '^dev-team-security-scan\.[A-Za-z0-9]{6}$'; then
  pass_line "the output directory has a random mktemp name"
else
  fail_line "output directory name [$BASE] is not dev-team-security-scan.<6 random characters>"
fi
MODE=$(stat -c %a "$D" 2>/dev/null || stat -f %Lp "$D" 2>/dev/null || echo "?")
[ "$MODE" = "700" ] && pass_line "the output directory is mode 700" || fail_line "output directory mode is $MODE, want 700"
scan a.txt
D2=$(out_dir)
[ -n "$D2" ] && [ "$D2" != "$D" ] && pass_line "two runs get two directories" || fail_line "two runs share [$D]"

# ---- SECURITY_SCAN_OUT names the directory --------------------------------
RC=0
OUT=$(SECURITY_SCAN_OUT="$HERMETIC_ROOT/named-out" PATH="$FARM" "$BASH_BIN" "$SCAN" a.txt 2>&1) || RC=$?
[ "$(out_dir)" = "$HERMETIC_ROOT/named-out" ] && [ -f "$HERMETIC_ROOT/named-out/summary.txt" ] \
  && pass_line "SECURITY_SCAN_OUT names the output directory" || fail_line "SECURITY_SCAN_OUT ignored: [$(out_dir)]"

# ---- more than 40 targets: cut to 40 and say so ---------------------------
mk_targets() { # mk_targets <n> — prints n file names t1..tn
  local i=1
  while [ "$i" -le "$1" ]; do printf 't%d\n' "$i"; i=$((i + 1)); done
}
# shellcheck disable=SC2046
scan $(mk_targets 45)
if printf '%s\n' "$OUT" | grep -q '^TARGETS: truncated to the first 40 of 45'; then
  pass_line "45 targets: the summary says 40 of 45 were scanned"
else
  fail_line "45 targets: no truncation line in: $OUT"
fi
# shellcheck disable=SC2046
scan $(mk_targets 41)
printf '%s\n' "$OUT" | grep -q '^TARGETS: truncated to the first 40 of 41' && pass_line "41 targets: 40 of 41" || fail_line "41 targets: no truncation line"
# control: 40 targets fit, so there is nothing to report
# shellcheck disable=SC2046
scan $(mk_targets 40)
if printf '%s\n' "$OUT" | grep -q '^TARGETS:'; then
  fail_line "control: 40 targets printed a truncation line"
else
  pass_line "control: 40 targets print no truncation line"
fi
[ "$RC" -eq 0 ] && pass_line "a truncated scan still exits 0" || fail_line "exit $RC"

# ---- SECURITY_SCAN=0 runs nothing -----------------------------------------
RC=0
OUT=$(SECURITY_SCAN=0 PATH="$FARM" "$BASH_BIN" "$SCAN" 2>&1) || RC=$?
printf '%s\n' "$OUT" | grep -q 'SECURITY_SCAN=0' && [ "$RC" -eq 0 ] \
  && pass_line "SECURITY_SCAN=0 short-circuits" || fail_line "SECURITY_SCAN=0: rc=$RC out=$OUT"

# ---- staged + untracked paths, from a subdirectory, with a failing semgrep -
STUB_LOG="$HERMETIC_ROOT/semgrep.args"
cat >"$FARM/semgrep" <<'EOF'
#!/bin/bash
if [ "${1:-}" = "--help" ]; then
  printf '%s\n' '--sarif'
  exit 0
fi
printf '%s\n' "$@" >>"$SECURITY_SCAN_STUB_LOG"
exit 1
EOF
chmod +x "$FARM/semgrep"
mkdir -p "$REPO/sub"
printf 'keep\n' >"$REPO/staged-file.txt"
env -u GIT_DIR -u GIT_WORK_TREE git -C "$REPO" init -q
env -u GIT_DIR -u GIT_WORK_TREE git -C "$REPO" add staged-file.txt
printf 'new\n' >"$REPO/untracked-file.txt"
RC=0
OUT=$(cd "$REPO/sub" && SECURITY_SCAN_STUB_LOG="$STUB_LOG" PATH="$FARM" "$BASH_BIN" "$SCAN" 2>&1) || RC=$?
[ "$RC" -eq 0 ] && pass_line "stub semgrep scan exits 0 (fail-open)" || fail_line "stub scan exit $RC"
grep -q 'staged-file.txt' "$STUB_LOG" && pass_line "staged file was passed to semgrep" || fail_line "staged file missing from $(cat "$STUB_LOG")"
grep -q 'untracked-file.txt' "$STUB_LOG" && pass_line "untracked file was passed to semgrep" || fail_line "untracked file missing from $(cat "$STUB_LOG")"
printf '%s\n' "$OUT" | grep -q 'SEMGREP: FAILED' && pass_line "offline semgrep shows FAILED" || fail_line "no FAILED status: $OUT"

# ---- clean removes the private temp dir -----------------------------------
RC=0
OUT=$(SECURITY_SCAN_CLEAN=1 PATH="$FARM" "$BASH_BIN" "$SCAN" a.txt 2>&1) || RC=$?
D=$(out_dir)
if [ -n "$D" ] && [ ! -d "$D" ]; then
  pass_line "SECURITY_SCAN_CLEAN removes the private temp dir"
else
  fail_line "SECURITY_SCAN_CLEAN left [$D]"
fi

echo
echo "PASS=$pass FAIL=$fail"
[ "$fail" -eq 0 ]
