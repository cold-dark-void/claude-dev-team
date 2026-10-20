#!/usr/bin/env bash
# test-sidecar.sh — hermetic suite for the inbox sidecar (SPEC-038 CDT-568).
# No network: curl is a PATH shim that records argv, consumes the -K - stdin
# config, and answers from a canned body (tests/lib/hermetic.sh conventions;
# tests/lib/mtimes.sh helpers for every mtime pin). State is hermetic:
# INTERCOM_STATE_ROOT and HOME live under one mktemp root and the repo
# working tree stays untouched. The suite never docker-pulls or docker-runs.
#
# Covers the CDT-568 sidecar AC subsets routed here: AC5 (scan-all-sids
# batching, notice grammar, spool immutability, *.ack* skip), AC6 (per-session
# heartbeat staleness gate, poller heartbeat untouched, config override),
# AC7 (at-most-once watermark across cycles + restart, consumed/ rule, ack
# race), AC8 (fail-soft matrix), AC9 (no second consumer, no poller-surface
# contact), AC13 (token sentinel). AC25 (operator chat is the lowest NUMERIC
# member id — jq min on raw string keys is lexicographic, so keys are
# converted with tonumber before min, matching the poller's sort -n outbound
# target). Each AC prints the actual run output as
# its exhibit; the bundle ends with a literal VERIFY exit= marker line.
set -u

HERE=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
PLUGIN_ROOT=$(CDPATH= cd -- "$HERE/../.." && pwd)

for _t in jq curl; do
  command -v "$_t" >/dev/null 2>&1 || {
    echo "SKIP: $_t missing — the sidecar requires bash/jq/curl (SPEC-038 AC21)"
    exit 77
  }
done

# shellcheck source=../../tests/lib/hermetic.sh
. "$PLUGIN_ROOT/tests/lib/hermetic.sh"
# shellcheck source=../../tests/lib/mtimes.sh
. "$PLUGIN_ROOT/tests/lib/mtimes.sh"

SIDECAR="$HERE/inbox-sidecar.sh"
COMMON="$HERE/common.sh"
TEST_TOKEN="123456789:TEST-SIDECAR-TOKEN"

hermetic_init

PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); echo "PASS: $1"; }
bad() { FAIL=$((FAIL + 1)); echo "FAIL: $1" >&2; }

# ---- hermetic curl shim + state root (shared scaffolding: test-lib.sh) --------

# shellcheck source=test-lib.sh
. "$HERE/test-lib.sh"
hermetic_curl_shim

# ---- suite-local helpers -------------------------------------------------------

fresh_case() { # paired state root + token + empty logs; no spool, no session state
  rm -rf "$STATE_ROOT" "$RESP_DIR"
  mkdir -p "$STATE_ROOT" "$RESP_DIR"
  : > "$CALLS_LOG"
  : > "$ARGV_LOG"
  : > "$ERRF"
  seed_token
  base_config 197372681 > "$STATE_ROOT/config.json"
}

put_inbox() { # SID NAME UPDATE_ID [TEXT] — one inbox record (poller record shape)
  mkdir -m 700 -p "$STATE_ROOT/spool/$1/inbox"
  jq -n --arg sid "$1" --argjson uid "$3" --arg text "${4:-hello there}" \
    '{ts: 1700000000, sid: $sid, dir: "in", kind: "message", text: $text,
      from_id: 197372681, update_id: $uid, thread_id: 0}' \
    > "$STATE_ROOT/spool/$1/inbox/$2"
}

put_consumed() { # SID NAME — the acked signal: same basename under consumed/
  mkdir -m 700 -p "$STATE_ROOT/spool/$1/consumed"
  cp "$STATE_ROOT/spool/$1/inbox/$2" "$STATE_ROOT/spool/$1/consumed/$2"
}

run_cycle() { # [ARGV...] — one sidecar cycle via INTERCOM_SIDECAR_CYCLE=1; sets S_OUT/S_ERR/S_RC
  : > "$CALLS_LOG"
  : > "$ARGV_LOG"
  S_OUT=$(INTERCOM_SIDECAR_CYCLE=1 bash "$SIDECAR" "$@" 2>"$ERRF")
  S_RC=$?
  S_ERR=$(cat "$ERRF")
}

run_cycle_argv() { # one cycle via the --cycle argv variant (env unset); sets S_OUT/S_ERR/S_RC
  : > "$CALLS_LOG"
  : > "$ARGV_LOG"
  S_OUT=$(env -u INTERCOM_SIDECAR_CYCLE bash "$SIDECAR" --cycle 2>"$ERRF")
  S_RC=$?
  S_ERR=$(cat "$ERRF")
}

sends() { # sendMessage call count from the shim's calls log
  _s=$(grep -c '^sendMessage ' "$CALLS_LOG" 2>/dev/null || true)
  printf '%s\n' "${_s:-0}"
}

notices() { # recorded notice lines from the shim's argv log
  grep -F 'reply received, queued to session' "$ARGV_LOG" 2>/dev/null || true
}

spool_fingerprint() { # byte identity + mtime signature of the whole spool tree
  ( cd "$STATE_ROOT" 2>/dev/null || exit 0
    find spool -type f -print 2>/dev/null | LC_ALL=C sort | xargs -r cksum
    find_mtimes spool 2>/dev/null | LC_ALL=C sort )
}

# ---- ack-race harness (AC7): a jq wrapper that moves the record to consumed/
# the moment the sidecar first parses it — a live `read --ack` between scan
# and send. Armed per run via RACE_MOVE; real jq resolved before the shim path.
RACE_JQ=$(command -v jq)
export RACE_JQ
RACE_BIN="$HERMETIC_ROOT/race-bin"
mkdir -p "$RACE_BIN"
cat > "$RACE_BIN/jq" <<'EOF'
#!/usr/bin/env bash
out=$("$RACE_JQ" "$@")
rc=$?
armed=0
for a in "$@"; do
  case $a in */inbox/*.json) armed=1 ;; esac
done
if [ "$armed" -eq 1 ] && [ -n "${RACE_MOVE:-}" ] && [ -f "$RACE_MOVE" ]; then
  mkdir -m 700 -p "${RACE_MOVE%/*}/../consumed" 2>/dev/null
  mv -f "$RACE_MOVE" "${RACE_MOVE%/*}/../consumed/${RACE_MOVE##*/}" 2>/dev/null
fi
printf '%s\n' "$out"
exit $rc
EOF
chmod +x "$RACE_BIN/jq"

# ---- AC5: scan-all-sids, ONE notice per stale sid per cycle, notice grammar
# (reply received, queued to session <sid> + record count + qids), spool tree
# byte-identical, *.ack* records skipped -----------------------------------------

echo
echo "=== AC5: scan-all-sids batching, notice text, spool immutability, ack skip ==="

fresh_case
put_inbox main 0000000001_11.json 11
put_inbox main 0000000002_12.json 12
printf '%s\n' '{"ts": 1700000000, "sid": "main", "dir": "in", "kind": "message",
  "text": "ack me", "from_id": 197372681, "update_id": 13, "thread_id": 0}' \
  > "$STATE_ROOT/spool/main/inbox/0000000003_13.ack.json"
put_inbox beta 0000000004_21.json 21
AC5_BEFORE=$(spool_fingerprint)

run_cycle
AC5_SENDS=$(sends)
echo "--- exhibit AC5 cycle run: rc=$S_RC sendMessage calls=$AC5_SENDS stderr=[$S_ERR] ---"
echo "--- exhibit AC5 recorded notices ---"
notices
AC5_AFTER=$(spool_fingerprint)

if [ "$S_RC" -eq 0 ] && [ "$AC5_SENDS" -eq 2 ]; then
  ok "AC5 one notice per stale sid per cycle (2 sids -> exactly 2 sendMessage)"
else
  bad "AC5 send count: rc=$S_RC sends=$AC5_SENDS"
fi

if notices | grep -qF 'reply received, queued to session main: 2 record(s) (qid=11, qid=12)' \
  && notices | grep -qF 'reply received, queued to session beta: 1 record(s) (qid=21)'; then
  ok "AC5 notice grammar carries sid, record count and qids for each stale sid"
else
  bad "AC5 notice text mismatch: $(notices | tr '\n' '|')"
fi

if [ -n "$AC5_BEFORE" ] && [ "$AC5_BEFORE" = "$AC5_AFTER" ]; then
  ok "AC5 spool tree byte-identical before/after (cksum + mtimes, notify-only)"
else
  bad "AC5 spool mutated: before=[$(printf '%s' "$AC5_BEFORE" | tr '\n' '|')] after=[$(printf '%s' "$AC5_AFTER" | tr '\n' '|')]"
fi

if ! grep -qF 'qid=13' "$ARGV_LOG" && ! grep -qF '13.ack' "$ARGV_LOG" \
  && ! printf '%s' "$S_ERR" | grep -qF '13.ack'; then
  ok "AC5 *.ack* record skipped (no notice, no mention)"
else
  bad "AC5 ack-suffixed record reached the notice path: $(cat "$ARGV_LOG")"
fi

# ---- AC6: per-session heartbeat staleness gate (T1 helpers); the poller's
# state/heartbeat is never read or written; session_stale_heartbeat_s default
# 900 + config override; schema stays 1 ------------------------------------------

echo
echo "=== AC6: heartbeat touch/age/staleness gate (T1 helpers) ==="

fresh_case
mkdir -m 700 -p "$STATE_ROOT/state" "$STATE_ROOT/state/session"
printf '1700000000\n' > "$STATE_ROOT/state/heartbeat" # poller liveness, NOT the session signal
chmod 600 "$STATE_ROOT/state/heartbeat"
touch_ago "$STATE_ROOT/state/heartbeat" 10
: > "$STATE_ROOT/state/session/main.heartbeat"
touch_ago "$STATE_ROOT/state/session/main.heartbeat" 100
put_inbox main 0000000001_31.json 31
AC6_AGE=$(INTERCOM_STATE_ROOT="$STATE_ROOT" bash -c '. "'"$COMMON"'" >/dev/null 2>&1; ir_session_heartbeat_age main')
AC6_HB_BEFORE=$(find_mtimes "$STATE_ROOT/state/heartbeat")

run_cycle # default 900: age 100 <= 900 -> live session -> no notice
echo "--- exhibit AC6 default-threshold cycle: rc=$S_RC sends=$(sends) hb_age=${AC6_AGE:-unreadable}s stderr=[$S_ERR] ---"
if [ "$S_RC" -eq 0 ] && [ "$(sends)" -eq 0 ]; then
  ok "AC6 fresh per-session heartbeat (age ${AC6_AGE}s <= 900) gates the notice off"
else
  bad "AC6 default threshold: rc=$S_RC sends=$(sends) age=$AC6_AGE"
fi

put_inbox ghost 0000000002_32.json 32 # no ghost.heartbeat at all: missing = stale
run_cycle
echo "--- exhibit AC6 missing-heartbeat cycle: sends=$(sends) notices=[$(notices | tr '\n' '|')] ---"
if [ "$(sends)" -eq 1 ] && notices | grep -qF 'reply received, queued to session ghost'; then
  ok "AC6 missing heartbeat counts as stale (fail-notify)"
else
  bad "AC6 fail-notify: sends=$(sends) notices=[$(notices | tr '\n' '|')]"
fi

cfg_edit "$STATE_ROOT/config.json" '. + {session_stale_heartbeat_s: 50}'
touch_ago "$STATE_ROOT/state/session/main.heartbeat" 100
run_cycle
echo "--- exhibit AC6 override cycle (threshold 50): sends=$(sends) notices=[$(notices | tr '\n' '|')] ---"
if [ "$(sends)" -eq 1 ] && notices | grep -qF 'reply received, queued to session main'; then
  ok "AC6 session_stale_heartbeat_s config override honored (age 100s > 50s -> notice)"
else
  bad "AC6 override: sends=$(sends) notices=[$(notices | tr '\n' '|')]"
fi

AC6_HB_AFTER=$(find_mtimes "$STATE_ROOT/state/heartbeat")
AC6_SCHEMA=$(jq -r '.schema' "$STATE_ROOT/config.json")
if [ -n "$AC6_HB_BEFORE" ] && [ "$AC6_HB_BEFORE" = "$AC6_HB_AFTER" ] \
  && [ "$(cat "$STATE_ROOT/state/heartbeat")" = "1700000000" ]; then
  ok "AC6 state/heartbeat (poller liveness) never read or written by the sidecar"
else
  bad "AC6 poller heartbeat touched: before=[$AC6_HB_BEFORE] after=[$AC6_HB_AFTER]"
fi
[ "$AC6_SCHEMA" = "1" ] \
  && ok "AC6 config schema stays 1 after the override cycle" \
  || bad "AC6 schema drifted: $AC6_SCHEMA"

# ---- AC7: at-most-once across two cycles AND across a restart (persisted
# notify.seen watermark); records in consumed/ never notified; a record
# consumed between scan and send is not notified (ack race) ----------------------

echo
echo "=== AC7: at-most-once watermark, consumed/ rule, ack race ==="

fresh_case
put_inbox main 0000000001_41.json 41
run_cycle
echo "--- exhibit AC7 first cycle: sends=$(sends) notices=[$(notices | tr '\n' '|')] ---"
echo "--- exhibit AC7 watermark file (raw bytes of state/session/main.notify.seen) ---"
cat "$STATE_ROOT/state/session/main.notify.seen" 2>/dev/null
if [ "$(sends)" -eq 1 ] && grep -Fxq '0000000001_41.json' "$STATE_ROOT/state/session/main.notify.seen" 2>/dev/null; then
  ok "AC7 first cycle notifies once and persists the watermark"
else
  bad "AC7 first cycle: sends=$(sends) seen=[$(cat "$STATE_ROOT/state/session/main.notify.seen" 2>/dev/null)]"
fi

run_cycle
AC7_C2=$(sends)
run_cycle_argv # restart: a fresh process re-reads the persisted watermark (also covers --cycle)
echo "--- exhibit AC7 second cycle sends=$AC7_C2, restart (--cycle) sends=$(sends) stderr=[$S_ERR] ---"
if [ "$AC7_C2" -eq 0 ] && [ "$(sends)" -eq 0 ]; then
  ok "AC7 at-most-once across two cycles and across a restart"
else
  bad "AC7 dedupe: cycle2=$AC7_C2 restart=$(sends)"
fi

put_inbox main 0000000002_42.json 42
put_consumed main 0000000002_42.json
run_cycle
echo "--- exhibit AC7 consumed/ move (raw dir listing) ---"
echo "inbox/: $(ls -1 "$STATE_ROOT/spool/main/inbox" 2>/dev/null | tr '\n' ' ')"
echo "consumed/: $(ls -1 "$STATE_ROOT/spool/main/consumed" 2>/dev/null | tr '\n' ' ')"
echo "--- exhibit AC7 consumed cycle: sends=$(sends) stderr=[$S_ERR] ---"
if [ "$(sends)" -eq 0 ]; then
  ok "AC7 record present in consumed/ is never notified"
else
  bad "AC7 consumed notify: sends=$(sends)"
fi

put_inbox main 0000000003_43.json 43
: > "$CALLS_LOG"
: > "$ARGV_LOG"
S_OUT=$(PATH="$RACE_BIN:$PATH" INTERCOM_SIDECAR_CYCLE=1 \
  RACE_MOVE="$STATE_ROOT/spool/main/inbox/0000000003_43.json" \
  bash "$SIDECAR" 2>"$ERRF")
S_RC=$?
S_ERR=$(cat "$ERRF")
echo "--- exhibit AC7 ack-race cycle: rc=$S_RC sends=$(sends) record_in_inbox=$([ -f "$STATE_ROOT/spool/main/inbox/0000000003_43.json" ] && echo yes || echo no) record_in_consumed=$([ -f "$STATE_ROOT/spool/main/consumed/0000000003_43.json" ] && echo yes || echo no) ---"
if [ "$S_RC" -eq 0 ] && [ "$(sends)" -eq 0 ] \
  && [ -f "$STATE_ROOT/spool/main/consumed/0000000003_43.json" ] \
  && ! grep -Fxq '0000000003_43.json' "$STATE_ROOT/state/session/main.notify.seen" 2>/dev/null; then
  ok "AC7 record consumed between scan and send is not notified (race re-check)"
else
  bad "AC7 race: rc=$S_RC sends=$(sends) seen=[$(cat "$STATE_ROOT/state/session/main.notify.seen" 2>/dev/null)]"
fi

# ---- AC8: fail-soft matrix — missing token, absent spool dirs, malformed
# record JSON, no operator chat id: logged to stderr, cycle exits 0 ---------------

echo
echo "=== AC8: fail-soft matrix ==="

fresh_case
rm -f "$HOME/.config/telegram/bot_token"
put_inbox main 0000000001_51.json 51
run_cycle
echo "--- exhibit AC8 missing token: rc=$S_RC stderr=[$S_ERR] ---"
if [ "$S_RC" -eq 0 ] && [ -n "$S_ERR" ]; then
  ok "AC8 missing token: logged, cycle exits 0"
else
  bad "AC8 missing token: rc=$S_RC err=[$S_ERR]"
fi

fresh_case # no spool dirs at all
run_cycle
echo "--- exhibit AC8 absent spool dirs: rc=$S_RC stderr=[$S_ERR] ---"
if [ "$S_RC" -eq 0 ]; then
  ok "AC8 absent spool dirs: skipped, cycle exits 0"
else
  bad "AC8 absent spool dirs: rc=$S_RC"
fi

fresh_case
mkdir -m 700 -p "$STATE_ROOT/spool/main/inbox"
printf 'not json at all\n' > "$STATE_ROOT/spool/main/inbox/broken.json"
run_cycle
echo "--- exhibit AC8 malformed record: rc=$S_RC sends=$(sends) stderr=[$S_ERR] ---"
if [ "$S_RC" -eq 0 ] && [ "$(sends)" -eq 0 ] && printf '%s' "$S_ERR" | grep -q 'malformed'; then
  ok "AC8 malformed record JSON: logged and skipped, no send, exit 0"
else
  bad "AC8 malformed: rc=$S_RC sends=$(sends) err=[$S_ERR]"
fi

fresh_case
cfg_edit "$STATE_ROOT/config.json" '.members = {"not-numeric": {name: "X", role: "owner"}}'
put_inbox main 0000000001_52.json 52
run_cycle
echo "--- exhibit AC8 no operator chat id: rc=$S_RC sends=$(sends) stderr=[$S_ERR] ---"
if [ "$S_RC" -eq 0 ] && [ "$(sends)" -eq 0 ] && printf '%s' "$S_ERR" | grep -q 'no numeric member chat id'; then
  ok "AC8 no operator chat id (unpaired): logged, nothing notified, exit 0"
else
  bad "AC8 unpaired: rc=$S_RC sends=$(sends) err=[$S_ERR]"
fi

# docker-down leg: the daemon identity is absent (compose ps empty via the
# hermetic mock) and the token is missing — the cycle still exits 0 and the
# fail-soft line is logged, with zero docker calls (the sidecar calls no
# docker at all; an engine-down state is fail-soft by absence).
fresh_case
rm -f "$HOME/.config/telegram/bot_token"
install_docker_mock down
: > "$DOCKER_MOCK_LOG"
put_inbox main 0000000001_53.json 53
run_cycle
AC8_DOCKER_CALLS=$(wc -l < "$DOCKER_MOCK_LOG" 2>/dev/null | tr -d ' ')
AC8_LINE=$(printf '%s' "$S_ERR" | head -n 1)
echo "--- exhibit AC8 docker-down (daemon identity absent): rc=$S_RC docker_calls=$AC8_DOCKER_CALLS fail-soft-line=[$AC8_LINE] ---"
if [ "$S_RC" -eq 0 ] && [ -n "$AC8_LINE" ] && [ "$AC8_DOCKER_CALLS" = "0" ]; then
  ok "AC8 docker-down: logged '$AC8_LINE', cycle exits 0, no docker call"
else
  bad "AC8 docker-down: rc=$S_RC line=[$AC8_LINE] docker_calls=$AC8_DOCKER_CALLS"
fi
rm -f "$SHIM_DIR/docker" # restore the docker-absent PATH for later legs

# ---- AC9: no getUpdates, no poller.lock / offset / seen.tsv / away /
# away_sid / inbox.stamp touches (source grep + state-tree assert) ---------------

echo
echo "=== AC9: no second consumer, no poller-surface contact ==="

if ! grep -v '^[[:space:]]*#' "$SIDECAR" | grep -q 'getUpdates'; then
  ok "AC9 sidecar source contains no getUpdates call"
else
  bad "AC9 getUpdates found in $SIDECAR"
fi

fresh_case
mkdir -m 700 -p "$STATE_ROOT/state"
printf '100\n' > "$STATE_ROOT/state/offset"
: > "$STATE_ROOT/state/seen.tsv"
printf 'on\n' > "$STATE_ROOT/state/away"
printf 'main\n' > "$STATE_ROOT/state/away_sid"
: > "$STATE_ROOT/state/inbox.stamp"
: > "$STATE_ROOT/state/poller.lock"
chmod 600 "$STATE_ROOT/state/offset" "$STATE_ROOT/state/away_sid"
put_inbox main 0000000001_61.json 61
AC9_SIG() { # cksum of each poller-surface file, absent files marked
  for f in offset seen.tsv away away_sid inbox.stamp poller.lock; do
    if [ -f "$STATE_ROOT/state/$f" ]; then
      cksum "$STATE_ROOT/state/$f"
    else
      printf 'absent %s\n' "$f"
    fi
  done
}
AC9_BEFORE=$(AC9_SIG)
run_cycle
echo "--- exhibit AC9 notify cycle over the poller surface: sends=$(sends) rc=$S_RC ---"
AC9_AFTER=$(AC9_SIG)
if [ "$(sends)" -eq 1 ] && [ "$AC9_BEFORE" = "$AC9_AFTER" ]; then
  ok "AC9 poller.lock/offset/seen.tsv/away/away_sid/inbox.stamp untouched by the cycle"
else
  bad "AC9 poller surface changed or notice lost: sends=$(sends) before=[$(printf '%s' "$AC9_BEFORE" | tr '\n' '|')] after=[$(printf '%s' "$AC9_AFTER" | tr '\n' '|')]"
fi

fresh_case # clean state: none of those files may be created
put_inbox main 0000000002_62.json 62
run_cycle
if [ ! -e "$STATE_ROOT/state/poller.lock" ] && [ ! -e "$STATE_ROOT/state/offset" ] \
  && [ ! -e "$STATE_ROOT/state/seen.tsv" ] && [ ! -e "$STATE_ROOT/state/away" ] \
  && [ ! -e "$STATE_ROOT/state/away_sid" ] && [ ! -e "$STATE_ROOT/state/inbox.stamp" ]; then
  ok "AC9 clean-state cycle creates no poller-surface file"
else
  bad "AC9 poller-surface file created in a clean state"
fi

# ---- AC13: token sentinel — absent from argv capture, stderr, state files,
# and any output -----------------------------------------------------------------

echo
echo "=== AC13: bot token sentinel ==="

fresh_case
put_inbox main 0000000001_71.json 71
run_cycle
echo "--- exhibit AC13 sentinel sweep: sends=$(sends) argv_lines=$(wc -l < "$ARGV_LOG" | tr -d ' ') stderr=[$S_ERR] ---"
if [ "$(sends)" -eq 1 ] \
  && ! grep -qF "$TEST_TOKEN" "$ARGV_LOG" "$CALLS_LOG" "$ERRF" 2>/dev/null \
  && ! printf '%s' "$S_OUT" | grep -qF "$TEST_TOKEN" \
  && ! printf '%s' "$S_ERR" | grep -qF "$TEST_TOKEN" \
  && ! grep -rqF "$TEST_TOKEN" "$STATE_ROOT" 2>/dev/null; then
  ok "AC13 token absent from argv capture, calls log, stderr, stdout and state files"
else
  bad "AC13 token leak detected in the sidecar path"
fi

# AC13 env capture: the shim records its own process environment; the test
# token must be absent from it (the token travels only via the -K - stdin
# config). The token value is never passed to the shim, so the dump is honest.
AC13_ENV_LOG="$HERMETIC_ROOT/curl.env"
CURL_ENV_LOG="$AC13_ENV_LOG"
export CURL_ENV_LOG
fresh_case
seed_token
put_inbox main 0000000001_72.json 72
run_cycle
unset CURL_ENV_LOG
echo "--- exhibit AC13 curl process environment captured: $AC13_ENV_LOG token-hits=$(grep -cF "$TEST_TOKEN" "$AC13_ENV_LOG" 2>/dev/null || true) ---"
if [ "$(sends)" -eq 1 ] && [ -f "$AC13_ENV_LOG" ] \
  && ! grep -qF "$TEST_TOKEN" "$AC13_ENV_LOG"; then
  ok "AC13 token absent from the curl process environment"
else
  bad "AC13 token found in the curl process environment (env log redacted, not printed)"
fi

# AC13 static sweep: no hardcoded bot-token pattern in shipped plugin files.
AC13_TOK_PAT='bot[0-9]{6,}:[A-Za-z0-9_-]{30,}'
AC13_HITS=$(grep -rEn "$AC13_TOK_PAT" "$HERE"/*.sh "$HERE/docker-compose.yml" "$HERE/Dockerfile" 2>/dev/null || true)
echo "--- exhibit AC13 hardcoded-token sweep: pattern=[$AC13_TOK_PAT] files=skills/intercom/*.sh+compose+Dockerfile hits=$(printf '%s' "$AC13_HITS" | grep -c . ) ---"
if [ -z "$AC13_HITS" ]; then
  ok "AC13 no hardcoded bot-token pattern in plugin files"
else
  bad "AC13 hardcoded bot-token pattern found (paths only): $(printf '%s' "$AC13_HITS" | cut -d: -f1 | LC_ALL=C sort -u | tr '\n' ' ')"
fi

# ---- AC25: operator_chat is the lowest NUMERIC member id — jq min on raw
# string keys is lexicographic ("10" < "9"), so keys are converted with
# tonumber first. Exhibit: members "9" and "10" -> the notice lands on chat 9.

echo
echo "=== AC25: operator chat is the lowest numeric member id ==="

fresh_case
cfg_edit "$STATE_ROOT/config.json" \
  '.members = {"10": {name: "Ten", role: "owner"}, "9": {name: "Nine", role: "owner"}}'
put_inbox main 0000000001_81.json 81
run_cycle
echo "--- exhibit AC25 numeric minimum: members 9+10, sendMessage argv ---"
grep -F 'chat_id=' "$ARGV_LOG" || true
if [ "$(sends)" -eq 1 ] && grep -qF 'chat_id=9' "$ARGV_LOG" \
  && ! grep -qF 'chat_id=10' "$ARGV_LOG"; then
  ok "AC25 operator chat is the numerically-lowest member id (9 beats 10)"
else
  bad "AC25 numeric minimum: sends=$(sends) argv=[$(cat "$ARGV_LOG" 2>/dev/null)]"
fi

# ---- bundle summary ------------------------------------------------------------

echo
echo "CDT-568 T4 sidecar suite: $PASS passed, $FAIL failed"
rc=0
[ "$FAIL" -eq 0 ] || rc=1
echo "VERIFY exit=$rc"
exit "$rc"
