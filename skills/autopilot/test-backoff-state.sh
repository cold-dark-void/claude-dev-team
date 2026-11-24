#!/usr/bin/env bash
# CDT-617 AC1 + AC3 — skills/autopilot/backoff-state.sh
#
# The open-decision-card reader a watchdog consults before it re-fires:
#   AC1 — `check` reads the M13 ledger's LAST card: decision "halt" + a hard
#         blocking condition (BC1-BC4, BC6-BC8) is blocked; BC5 (reroute-epic)
#         never blocks; a missing, empty, or malformed ledger is NOT blocked
#         (fail-open). `record` ramps the delay, `reset` clears it, and the
#         state file is the single per-ticket JSON.
#   AC3 — base / max / attempts caps come from AUTOPILOT_BACKOFF_BASE_S,
#         AUTOPILOT_BACKOFF_MAX_S and AUTOPILOT_BACKOFF_MAX_ATTEMPTS (an
#         invalid value falls back to the baked default), and the open halt
#         card's budget.wall_clock_cap_s bounds the delay.
#
# Hermetic: private TMPDIR/HOME (tests/lib/hermetic.sh), one temp git repo as
# fake MROOT, ledger fixtures written with jq. No live autopilot run, no
# network.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# shellcheck source=../../tests/lib/skip.sh
. "$ROOT/tests/lib/skip.sh"
# shellcheck source=../../tests/lib/hermetic.sh
. "$ROOT/tests/lib/hermetic.sh"
require_cmd jq git
hermetic_init

BS="$ROOT/skills/autopilot/backoff-state.sh"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/backoff-state-test.XXXXXX")"
trap 'rm -rf "$TMP"; hermetic_cleanup' EXIT

PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); echo "  PASS: $1"; }
bad() { FAIL=$((FAIL + 1)); echo "  FAIL: $1"; }

if [ ! -f "$BS" ]; then
  echo "FAIL: $BS is missing"
  exit 1
fi

# ---- Fake MROOT -------------------------------------------------------------
REPO="$TMP/repo"
mkdir -p "$REPO/.claude/autopilot"
( cd "$REPO" && git init -q ) || { echo "FAIL: git init"; exit 1; }
cd "$REPO" || { echo "FAIL: cd"; exit 1; }

TICKET="T1"
LEDGER=".claude/autopilot/${TICKET}.jsonl"
STATE=".claude/autopilot/${TICKET}.backoff.json"

# write_card DECISION BC [CAP] — one M13-shaped card as the whole ledger.
# BC is a digit string (the M6 ordinal) or "null"; CAP is budget.wall_clock_cap_s.
write_card() {
  local decision="$1" bc="$2" cap="${3:-}"
  jq -cn --arg d "$decision" --arg b "$bc" --arg cap "$cap" '
    { schema_version: 1, type: "autopilot_decision",
      ts: "2026-11-24T00:00:00Z", run_id: "r", workflow: "orchestrate",
      ticket_id: "T1", gate: "ship-choice",
      decision: $d, decided_by: "auto", bump: null, confidence: 0,
      blocking_condition: (if $b == "null" then null else ($b | tonumber) end),
      council_tier: null, grading_reason: null, max_loc: null,
      rationale: "fixture",
      budget: { iteration: 1, iteration_cap: 25, wall_clock_s: 10,
                wall_clock_cap_s: (if $cap == "" then null else ($cap | tonumber) end),
                tier: null, source: null, signals: null },
      actor: "orchestrator", advisor: null }' > "$LEDGER"
}

# write_card_str DECISION BC_STRING — a card whose blocking_condition is a
# string ("BC3"), the shape a hand-written fixture may carry.
write_card_str() {
  local decision="$1" bc="$2"
  jq -cn --arg d "$decision" --arg b "$bc" '
    { decision: $d, blocking_condition: $b, budget: {} }' > "$LEDGER"
}

# check_state — run `check`, capture rc/stdout/stderr.
check_state() {
  RC=0
  bash "$BS" check "$TICKET" > "$TMP/out.json" 2> "$TMP/err.txt" || RC=$?
}
fld() { jq -r "$1" "$TMP/out.json" 2>/dev/null || echo "<unparseable>"; }

# record_state [BC] [ENV=VAL...] — run `record`, capture rc + stdout.
run_record() {
  RC=0
  ( cd "$REPO" && env "$@" bash "$BS" record "$TICKET" "$BC_ARG" ) > "$TMP/rec.json" 2> "$TMP/err.txt" || RC=$?
}
BC_ARG="BC1"
state_fld() { jq -r "$1" "$TMP/rec.json" 2>/dev/null || echo "<unparseable>"; }

echo "backoff-state.sh — open-decision-card reader (CDT-617 AC1/AC3)"

# ---- AC1: open hard blocker -------------------------------------------------
echo ""
echo "AC1 — open hard blocker from the last ledger card"

rm -f "$LEDGER" "$STATE"
check_state
if [ "$RC" = "0" ] && [ "$(fld .blocked)" = "false" ]; then
  ok "missing ledger -> blocked=false, exit 0 (fail-open)"
else
  bad "missing ledger: rc=$RC out=$(cat "$TMP/out.json")"
fi

: > "$LEDGER"
check_state
if [ "$RC" = "0" ] && [ "$(fld .blocked)" = "false" ]; then
  ok "empty ledger -> blocked=false, exit 0"
else
  bad "empty ledger: rc=$RC out=$(cat "$TMP/out.json")"
fi

printf 'this is not json\n' > "$LEDGER"
check_state
if [ "$RC" = "0" ] && [ "$(fld .blocked)" = "false" ]; then
  ok "malformed ledger -> blocked=false, exit 0 (fail-open)"
else
  bad "malformed ledger: rc=$RC out=$(cat "$TMP/out.json")"
fi

write_card "halt" "1"
check_state
if [ "$RC" = "0" ] && [ "$(fld .blocked)" = "true" ] && [ "$(fld .bc)" = "BC1" ]; then
  ok "last card halt + BC1 -> blocked=true bc=BC1"
else
  bad "halt BC1: rc=$RC out=$(cat "$TMP/out.json")"
fi

write_card_str "halt" "BC3"
check_state
if [ "$(fld .blocked)" = "true" ] && [ "$(fld .bc)" = "BC3" ]; then
  ok "string blocking_condition \"BC3\" is accepted"
else
  bad "string BC3: rc=$RC out=$(cat "$TMP/out.json")"
fi

for bc in 2 3 4 6 7 8; do
  write_card "halt" "$bc"
  check_state
  if [ "$(fld .blocked)" = "true" ] && [ "$(fld .bc)" = "BC$bc" ]; then
    ok "halt + BC$bc is a hard blocker"
  else
    bad "halt BC$bc: out=$(cat "$TMP/out.json")"
  fi
done

write_card "reroute-epic" "5"
check_state
if [ "$(fld .blocked)" = "false" ]; then
  ok "BC5 reroute-epic is not a blocker (SPEC-033 M6/M7)"
else
  bad "BC5 reroute-epic: out=$(cat "$TMP/out.json")"
fi

write_card "halt" "5"
check_state
if [ "$(fld .blocked)" = "false" ]; then
  ok "BC5 never blocks, even on a halt card"
else
  bad "halt BC5: out=$(cat "$TMP/out.json")"
fi

write_card "approve" "null"
check_state
if [ "$(fld .blocked)" = "false" ] && [ "$(fld .bc)" = "null" ]; then
  ok "a clean last card (approve, blocking_condition null) is not blocked"
else
  bad "clean card: out=$(cat "$TMP/out.json")"
fi

# Only the LAST card decides: a halt followed by a clean card is closed.
write_card "halt" "1"
jq -cn '{decision: "proceed", blocking_condition: null, budget: {}}' >> "$LEDGER"
check_state
if [ "$(fld .blocked)" = "false" ]; then
  ok "a halt card followed by a clean card is not open"
else
  bad "closed halt: out=$(cat "$TMP/out.json")"
fi

# Frozen output key set
write_card "halt" "7"
check_state
keys=$(jq -r 'keys | sort | join(",")' "$TMP/out.json" 2>/dev/null || echo "<none>")
if [ "$keys" = "attempts,bc,blocked,delay_s,next_fire_ts" ]; then
  ok "check prints exactly {blocked, bc, attempts, delay_s, next_fire_ts}"
else
  bad "check keys: $keys"
fi

# ---- AC1: record / reset ----------------------------------------------------
echo ""
echo "AC1 — record ramps the delay, reset clears it"

rm -f "$STATE"
write_card "halt" "1"
now=$(date +%s)
BC_ARG="BC1"
run_record
nft=$(state_fld .next_fire_ts)
if [ "$RC" = "0" ] && [ -f "$STATE" ] && [ "$(state_fld .attempts)" = "1" ] \
   && [ "$(state_fld .delay_s)" = "1800" ] \
   && [ "$nft" -ge $((now + 1795)) ] && [ "$nft" -le $((now + 1805)) ]; then
  ok "first record: attempts=1, delay=1800 s, next_fire_ts=now+1800"
else
  bad "first record: rc=$RC out=$(cat "$TMP/rec.json") state=$(cat "$STATE" 2>/dev/null)"
fi

BC_ARG="BC1"
run_record
if [ "$RC" = "0" ] && [ "$(state_fld .attempts)" = "2" ] && [ "$(state_fld .delay_s)" = "3600" ]; then
  ok "second identical record: attempts=2, delay doubles to 3600"
else
  bad "second record: rc=$RC out=$(cat "$TMP/rec.json")"
fi

BC_ARG="BC1"
run_record
if [ "$(state_fld .attempts)" = "3" ] && [ "$(state_fld .delay_s)" = "7200" ]; then
  ok "third identical record: attempts=3, delay 7200"
else
  bad "third record: out=$(cat "$TMP/rec.json")"
fi

BC_ARG="BC3"
run_record
if [ "$(state_fld .attempts)" = "1" ] && [ "$(state_fld .delay_s)" = "1800" ]; then
  ok "a new blocking condition restarts the ramp"
else
  bad "BC change: out=$(cat "$TMP/rec.json")"
fi

# The ledger names the open blocker; the state names the ramp. Align them.
write_card "halt" "3"
check_state
if [ "$(fld .blocked)" = "true" ] && [ "$(fld .bc)" = "BC3" ] \
   && [ "$(fld .attempts)" = "1" ] && [ "$(fld .delay_s)" = "1800" ]; then
  ok "check reflects the recorded state"
else
  bad "check after record: out=$(cat "$TMP/out.json")"
fi

leftover=$(ls -A .claude/autopilot | grep -c 'backoff\.json\.tmp\.' || true)
if [ "${leftover:-0}" = "0" ]; then
  ok "atomic write leaves no temp file next to the state"
else
  bad "atomic write left $leftover temp file(s)"
fi

rm -f "$LEDGER"
BC_ARG="BC7"
run_record
if [ "$RC" = "0" ] && [ "$(state_fld .blocked)" = "false" ] && [ ! -f "$STATE" ]; then
  ok "record with no ledger: no-op (no open episode), no state written"
else
  bad "record, no ledger: rc=$RC out=$(cat "$TMP/rec.json") state=$(ls "$STATE" 2>/dev/null || echo absent)"
fi

RC=0
bash "$BS" reset "$TICKET" >/dev/null 2>"$TMP/err.txt" || RC=$?
check_state
if [ "$RC" = "0" ] && [ ! -f "$STATE" ] && [ "$(fld .attempts)" = "0" ]; then
  ok "reset clears the state; check then reports attempts=0"
else
  bad "reset: rc=$RC state exists=$([ -f "$STATE" ] && echo yes || echo no) out=$(cat "$TMP/out.json")"
fi

RC=0
bash "$BS" reset "$TICKET" >/dev/null 2>&1 || RC=$?
if [ "$RC" = "0" ]; then
  ok "reset is idempotent on a missing state"
else
  bad "second reset: rc=$RC"
fi

# Blocked with no state yet: the watchdog is due now (no delay to honour).
write_card "halt" "1"
check_state
if [ "$(fld .blocked)" = "true" ] && [ "$(fld .attempts)" = "0" ] \
   && [ "$(fld .delay_s)" = "0" ] && [ "$(fld .next_fire_ts)" = "0" ]; then
  ok "open blocker + no state -> attempts 0, next_fire_ts 0 (due now)"
else
  bad "open, no state: out=$(cat "$TMP/out.json")"
fi

# Corrupt state file is fail-open.
printf 'not json\n' > "$STATE"
check_state
if [ "$RC" = "0" ] && [ "$(fld .attempts)" = "0" ] && [ "$(fld .blocked)" = "true" ]; then
  ok "corrupt state file -> attempts 0, exit 0 (fail-open)"
else
  bad "corrupt state: rc=$RC out=$(cat "$TMP/out.json")"
fi
rm -f "$STATE"

# ---- AC1: usage guards ------------------------------------------------------
echo ""
echo "AC1 — usage + argv guards"

usage_case() {
  local desc="$1"; shift
  RC=0
  bash "$BS" "$@" >/dev/null 2>"$TMP/err.txt" || RC=$?
  if [ "$RC" = "64" ]; then
    ok "$desc -> exit 64"
  else
    bad "$desc: rc=$RC (want 64) stderr=$(head -1 "$TMP/err.txt")"
  fi
}

usage_case "no arguments"
usage_case "unknown subcommand" frobnicate "$TICKET"
usage_case "check with 2 args" check "$TICKET" extra
usage_case "record with 1 arg" record "$TICKET"
usage_case "reset with 2 args" reset "$TICKET" extra
usage_case "ticket id with a slash" check "a/b"
usage_case "ticket id with dots" check "a.b"
usage_case "record BC5 (reroute-epic is not a blocker)" record "$TICKET" BC5
usage_case "record a bogus BC" record "$TICKET" BC9
usage_case "record a bare-word BC" record "$TICKET" banana

# ---- AC3: caps ---------------------------------------------------------------
echo ""
echo "AC3 — env caps + the halt card's wall_clock_cap_s"

rm -f "$STATE"
write_card "halt" "1"
now=$(date +%s)
BC_ARG="BC1"
run_record AUTOPILOT_BACKOFF_BASE_S=60
d1=$(state_fld .delay_s)
BC_ARG="BC1"
run_record AUTOPILOT_BACKOFF_BASE_S=60
if [ "$d1" = "60" ] && [ "$(state_fld .delay_s)" = "120" ]; then
  ok "AUTOPILOT_BACKOFF_BASE_S=60 -> 60 then 120"
else
  bad "BASE_S=60: d1=$d1 d2=$(state_fld .delay_s)"
fi

rm -f "$STATE"
BC_ARG="BC1"
run_record AUTOPILOT_BACKOFF_BASE_S=60 AUTOPILOT_BACKOFF_MAX_S=100
d1=$(state_fld .delay_s)
BC_ARG="BC1"
run_record AUTOPILOT_BACKOFF_BASE_S=60 AUTOPILOT_BACKOFF_MAX_S=100
d2=$(state_fld .delay_s)
BC_ARG="BC1"
run_record AUTOPILOT_BACKOFF_BASE_S=60 AUTOPILOT_BACKOFF_MAX_S=100
if [ "$d1" = "60" ] && [ "$d2" = "100" ] && [ "$(state_fld .delay_s)" = "100" ]; then
  ok "AUTOPILOT_BACKOFF_MAX_S=100 bounds the doubling"
else
  bad "MAX_S=100: d1=$d1 d2=$d2 d3=$(state_fld .delay_s)"
fi

rm -f "$STATE"
BC_ARG="BC1"
run_record AUTOPILOT_BACKOFF_BASE_S=60 AUTOPILOT_BACKOFF_MAX_ATTEMPTS=2
d1=$(state_fld .delay_s)
BC_ARG="BC1"
run_record AUTOPILOT_BACKOFF_BASE_S=60 AUTOPILOT_BACKOFF_MAX_ATTEMPTS=2
d2=$(state_fld .delay_s)
BC_ARG="BC1"
run_record AUTOPILOT_BACKOFF_BASE_S=60 AUTOPILOT_BACKOFF_MAX_ATTEMPTS=2
d3=$(state_fld .delay_s)
if [ "$d1" = "60" ] && [ "$d2" = "120" ] && [ "$d3" = "120" ]; then
  ok "AUTOPILOT_BACKOFF_MAX_ATTEMPTS=2 stops the doubling after 2 attempts"
else
  bad "MAX_ATTEMPTS=2: d1=$d1 d2=$d2 d3=$d3"
fi

rm -f "$STATE"
write_card "halt" "1" 300
BC_ARG="BC1"
run_record AUTOPILOT_BACKOFF_BASE_S=1800 AUTOPILOT_BACKOFF_MAX_S=86400
if [ "$(state_fld .delay_s)" = "300" ]; then
  ok "the halt card's budget.wall_clock_cap_s=300 bounds the delay"
else
  bad "card cap: out=$(cat "$TMP/rec.json")"
fi

rm -f "$STATE"
write_card "halt" "1" 100000
BC_ARG="BC1"
run_record AUTOPILOT_BACKOFF_BASE_S=60 AUTOPILOT_BACKOFF_MAX_S=100
if [ "$(state_fld .delay_s)" = "60" ] && [ "$(jq -r .delay_s "$STATE")" = "60" ]; then
  ok "a card cap above the env max does not raise the env max"
else
  bad "cap above env max: state=$(cat "$STATE")"
fi

rm -f "$STATE"
BC_ARG="BC1"
run_record AUTOPILOT_BACKOFF_BASE_S=abc
if [ "$RC" = "0" ] && [ "$(state_fld .delay_s)" = "1800" ] \
   && grep -q 'AUTOPILOT_BACKOFF_BASE_S' "$TMP/err.txt"; then
  ok "a non-integer AUTOPILOT_BACKOFF_BASE_S falls back to 1800 with a stderr note"
else
  bad "bad BASE_S: rc=$RC out=$(cat "$TMP/rec.json") err=$(cat "$TMP/err.txt")"
fi

rm -f "$STATE"
BC_ARG="BC1"
run_record AUTOPILOT_BACKOFF_MAX_ATTEMPTS=07
if [ "$RC" = "0" ] && [ "$(state_fld .delay_s)" = "1800" ]; then
  ok "a leading-zero AUTOPILOT_BACKOFF_MAX_ATTEMPTS falls back to the default"
else
  bad "leading-zero MAX_ATTEMPTS: rc=$RC out=$(cat "$TMP/rec.json")"
fi

# AC2/AC3 boundary: 1800 base and a sane default max with no env set.
rm -f "$STATE"
write_card "halt" "1"
BC_ARG="BC1"
run_record
BC_ARG="BC1"
run_record
BC_ARG="BC1"
run_record
BC_ARG="BC1"
run_record
BC_ARG="BC1"
run_record
BC_ARG="BC1"
run_record
BC_ARG="BC1"
run_record
BC_ARG="BC1"
run_record
d=$(state_fld .delay_s)
if [ "$(state_fld .attempts)" = "8" ] && [ "$d" = "86400" ]; then
  ok "8 baked defaults: attempts=8, delay capped at the 86400 s default max"
else
  bad "baked max: attempts=$(state_fld .attempts) delay=$d"
fi

# TL-review fix: a record call after the halt resolved must no-op AND clear
# the stale state file, so it cannot seed the next halt of the same BC.
rm -f "$STATE"
write_card "halt" "1"
BC_ARG="BC1"
run_record
if [ "$(state_fld .blocked)" = "true" ] && [ -f "$STATE" ]; then
  ok "record inside an open halt writes state"
else
  bad "record open-halt: out=$(cat "$TMP/rec.json")"
fi
write_card "proceed" "null"
run_record
if [ "$RC" = "0" ] && [ "$(state_fld .blocked)" = "false" ] && [ ! -f "$STATE" ]; then
  ok "record after the halt resolved: no-op output, state file cleared"
else
  bad "record closed-halt: rc=$RC out=$(cat "$TMP/rec.json") state=$(ls "$STATE" 2>/dev/null || echo absent)"
fi

echo ""
echo "Results: PASS=$PASS FAIL=$FAIL"
if [ "$FAIL" -ne 0 ]; then
  exit 1
fi
exit 0
