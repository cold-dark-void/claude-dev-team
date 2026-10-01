#!/usr/bin/env bash
# theme-status-test.sh — derive, force-check, append, count-prior (CDT-279 E5, F24)
set -u

HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
TS="$HERE/theme-status.sh"
PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); echo "PASS: $*"; }
bad() { FAIL=$((FAIL + 1)); echo "FAIL: $*"; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home"
mkdir -p "$HOME/.claude"

key=$(bash "$TS" derive "the bug is still broken")
[ "$key" = "unthemed" ] && ok "stopword description derives unthemed" || bad "stopword key=$key"

key=$(bash "$TS" derive "nil pointer in auth handler")
[ "$key" = "nil-pointer-auth-handler" ] && ok "derive keeps content words" || bad "derive key=$key"

out=$(bash "$TS" force-check auth "no isolation in the save path" "$TMP/proj")
printf '%s\n' "$out" | grep -q 'FORCED_REDESIGN=yes' \
  && ok "force-check sets redesign" || bad "force-check missed redesign"
printf '%s\n' "$out" | grep -q 'FORCE_REASON=isolation-keyword:no isolation' \
  && ok "force-check names the isolation phrase" || bad "force-check reason"

bash "$TS" append auth "$TMP/proj" '{"ts":1,"outcome":"fixed"}'
grep -q '"outcome":"fixed"' "$TMP/proj/.claude/debug/themes/auth.jsonl" \
  && ok "append argv writes the json line" || bad "append argv"
printf '%s\n' '{"ts":2,"outcome":"aborted"}' | bash "$TS" append auth "$TMP/proj"
grep -q '"outcome":"aborted"' "$TMP/proj/.claude/debug/themes/auth.jsonl" \
  && ok "append stdin writes the json line" || bad "append stdin"

bash "$TS" append >"$TMP/out" 2>"$TMP/err"
rc=$?
if [ "$rc" -eq 2 ] && grep -q 'Usage:' "$TMP/err" && ! grep -q '1: theme' "$TMP/err"; then
  ok "append with no key exits 2 with usage"
else
  bad "append with no key rc=$rc err=$(cat "$TMP/err")"
fi

# Two calendar days in the theme log count as 2. The same timestamp counts as 1.
now=$(date +%s)
ago=$((now - 86400))
dayroot="$TMP/days"
bash "$TS" append days "$dayroot" "$(printf '{"ts":%s,"outcome":"fixed"}' "$now")"
bash "$TS" append days "$dayroot" "$(printf '{"ts":%s,"outcome":"fixed"}' "$now")"
one=$(bash "$TS" count-prior days "$dayroot")
[ "$one" = "1" ] && ok "same timestamp is one prior day" || bad "same-day count=$one"
bash "$TS" append days "$dayroot" "$(printf '{"ts":%s,"outcome":"fixed"}' "$ago")"
two=$(bash "$TS" count-prior days "$dayroot")
[ "$two" = "2" ] && ok "a second UTC day counts" || bad "two-day count=$two"

# History: exact project and a child count. An ancestor and an empty project do not.
hroot="$TMP/histproj"
mkdir -p "$hroot"
older=$((now - 172800))
oldest=$((now - 259200))
child=$((now - 86400))
cat > "$HOME/.claude/history.jsonl" <<EOF
{"timestamp":$now,"project":"$hroot","display":"/debug nil pointer"}
{"timestamp":$child,"project":"$hroot/child","display":"/debug nil pointer"}
{"timestamp":$older,"project":"/tmp","display":"/debug nil pointer"}
{"timestamp":$oldest,"project":"","display":"/debug nil pointer"}
EOF
hist=$(bash "$TS" count-prior nil-pointer "$hroot")
[ "$hist" = "2" ] && ok "history matches the project and a child only" || bad "history count=$hist want 2"

echo "---"
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
