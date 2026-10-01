#!/usr/bin/env bash
# parse-args-test.sh — unit tests for parse-args.sh, the one /retro argument
# parser (WP 2-02, rv-w1-46). Also checks that commands/retro.md holds no
# second copy of the parser.
# Run: bash skills/retro-gate/parse-args-test.sh
set -u

HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT=$(CDPATH= cd -- "$HERE/../.." && pwd)
PA="$HERE/parse-args.sh"
RETRO_MD="${RETRO_MD:-$ROOT/commands/retro.md}"

# shellcheck source=../../tests/lib/hermetic.sh
. "$ROOT/tests/lib/hermetic.sh"
# shellcheck source=../../tests/lib/check.sh
. "$ROOT/tests/lib/check.sh"
hermetic_init
pass=0
fail=0

# A cwd that holds files a glob could match.
WORK="$HERMETIC_ROOT/work"
mkdir -p "$WORK"
: > "$WORK/alpha.txt"
: > "$WORK/beta.txt"
cd "$WORK" || exit 1

# parsed <args...> — prints MODE|AUTO|WHY|EXPLICIT_SID|HOST|HOST_EXPLICIT after
# the caller's own eval of the output; returns the parser's exit code.
parsed() {
  local out rc=0
  out=$(bash "$PA" "$@" 2>"$HERMETIC_ROOT/err") || rc=$?
  [ "$rc" -eq 0 ] || return "$rc"
  ( eval "$out"; printf '%s|%s|%s|%s|%s|%s' "$MODE" "$AUTO" "$WHY" "$EXPLICIT_SID" "$HOST" "$HOST_EXPLICIT" )
}

expect_parse() { # expect_parse <label> <want> <args...>
  local label="$1" want="$2" got
  shift 2
  got=$(parsed "$@"); got_rc=$?
  if [ "$got_rc" -eq 0 ] && [ "$got" = "$want" ]; then pass_line "$label"; else fail_line "$label: rc=$got_rc got=[$got] want=[$want]"; fi
}

expect_error() { # expect_error <label> <args...> — exit 1, empty stdout, one error line
  local label="$1" out rc=0
  shift
  out=$(bash "$PA" "$@" 2>"$HERMETIC_ROOT/err") || rc=$?
  if [ "$rc" -eq 1 ] && [ -z "$out" ] && grep -q '^error:' "$HERMETIC_ROOT/err"; then pass_line "$label"; else fail_line "$label: rc=$rc out=[$out] err=[$(cat "$HERMETIC_ROOT/err")]"; fi
}

expect_parse "no arguments: defaults" "single|0|0|||0"
expect_parse "--all implies --host all" "all|0|0||all|0" --all
expect_parse "--all --host grok keeps grok" "all|0|0||grok|1" --all --host grok
expect_parse "--host=claude with a session id" "single|0|0|abc|claude|1" --host=claude abc
expect_parse "--auto and --why" "single|1|1|||0" --auto --why
expect_parse "a bare * stays a literal (no glob against the cwd)" "single|0|0|*||0" '*'
expect_parse "one word with a space stays one word" "single|0|0|a b||0" 'a b'
expect_parse "--host grok then a session id" "single|0|0|s1|grok|1" --host grok s1

# shell metacharacters in a value are data, never code
expect_parse 'a $(...) value is kept and not run' 'single|0|0|$(touch PWNED)||0' '$(touch PWNED)'
expect_parse 'a backtick value is kept and not run' 'single|0|0|`touch PWNED`||0' '`touch PWNED`'
expect_parse 'a ; value is kept and not run' 'single|0|0|x;touch PWNED||0' 'x;touch PWNED'
check "no command ran" test ! -e "$WORK/PWNED"

# errors: exit 1, one error line, nothing on stdout
expect_error "--host with no value" --host
expect_error "--host with a bad value" --host foo
expect_error "--host=bad" --host=foo
expect_error "--all with a session id" --all abc
expect_error "--host followed by a flag" --host --all

# an unknown flag is reported and skipped
OUT=$(bash "$PA" --bogus x 2>"$HERMETIC_ROOT/err"); RC=$?
if [ "$RC" -eq 0 ] && grep -qx 'Unknown flag: --bogus' "$HERMETIC_ROOT/err" && printf '%s\n' "$OUT" | grep -q '^EXPLICIT_SID=x$'; then
  pass_line "unknown flag warns on stderr, parse continues"
else
  fail_line "unknown flag: rc=$RC err=[$(cat "$HERMETIC_ROOT/err")] out=[$OUT]"
fi

# ---- commands/retro.md holds the parser call, not a second parser ----------
# The parser appears once (in parse-args.sh). The old copies were a `for arg in
# $ARGUMENTS` loop in Step 1 and a second one in Step 2. The same greps find
# both in a planted copy of the old text (negative control).
OLD_LOOP='for arg in $ARGUMENTS; do
  case "$arg" in
    --host) _PREV_HOST=1 ;;
    *) echo "error: --host expects claude|grok|all, got: $arg" >&2 ;;
  esac
done'
printf '%s\n%s\n' "$OLD_LOOP" "$OLD_LOOP" > "$WORK/old-retro.md"
OLD_N=$(grep -c -F -- '--host expects claude|grok|all' "$WORK/old-retro.md" || true)
[ "$OLD_N" = "2" ] && pass_line "control: the grep finds two planted parser copies" || fail_line "control: planted copies found $OLD_N, want 2"
NEW_N=$(grep -c -F -- '--host expects claude|grok|all' "$RETRO_MD" || true)
[ "$NEW_N" = "0" ] && pass_line "retro.md holds no parser error text ($NEW_N copies)" || fail_line "retro.md still holds $NEW_N copies of the --host parser"
LOOP_N=$(grep -c -E '^for arg in \$ARGUMENTS' "$RETRO_MD" || true)
[ "$LOOP_N" = "0" ] && pass_line "retro.md has no 'for arg in \$ARGUMENTS' loop" || fail_line "retro.md has $LOOP_N 'for arg in \$ARGUMENTS' loops"
CALL_N=$(grep -c -F 'skills/retro-gate/parse-args.sh' "$RETRO_MD" || true)
[ "$CALL_N" -ge 2 ] && pass_line "retro.md calls parse-args.sh in Step 1 and Step 2 ($CALL_N)" || fail_line "retro.md calls parse-args.sh $CALL_N times, want >= 2"

echo
echo "PASS=$pass FAIL=$fail"
[ "$fail" -eq 0 ]
