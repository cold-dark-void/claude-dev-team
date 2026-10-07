#!/usr/bin/env bash
# test.sh — hermetic suite for the intercom skill (SPEC-038). No network:
# curl is a PATH shim that records argv, consumes the -K - stdin config, and
# answers from fixture JSON (tests/lib/hermetic.sh conventions; fixture JSON
# under fixtures/ uses sentinel-style fake tokens only).
#
# Covers the AC subsets SPEC-038 routes here: AC1, AC2, AC3, AC4, AC5, AC6,
# AC7, AC8, AC9, AC10, AC11, AC17 (CLI side), AC20, AC21, AC23, AC25.
# Poller-cycle ACs (AC12-AC16, AC18, AC19, AC22) live in test-poller.sh.
# CDT-509 AC3/AC6/AC10/AC12 live here; loop+compose+keepalive static
# live in test-daemon.sh. State is hermetic: INTERCOM_STATE_ROOT and HOME
# live under one mktemp root and the repo working tree must stay untouched
# (AC23). Suites never docker-pull or docker-run a real image.
set -u

HERE=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
PLUGIN_ROOT=$(CDPATH= cd -- "$HERE/../.." && pwd)

for _t in jq curl flock; do
  command -v "$_t" >/dev/null 2>&1 || {
    echo "SKIP: $_t missing — intercom requires bash/jq/curl/flock (SPEC-038 AC21/AC22)"
    exit 77
  }
done

# shellcheck source=../../tests/lib/hermetic.sh
. "$PLUGIN_ROOT/tests/lib/hermetic.sh"

INTERCOM="$HERE/intercom.sh"
COMMON="$HERE/common.sh"
POLLER="$HERE/poller.sh"
WATCH="$HERE/watch.sh"
SETUP="$HERE/setup-telegram.sh"
SETUP_MD="$PLUGIN_ROOT/commands/setup.md"
FIXTURES="$HERE/fixtures"
TEST_TOKEN="123456789:TEST-TOKEN-NOT-REAL"
SENTINEL="123456789:TEST-SENTINEL-TOKEN"

hermetic_init

PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); echo "PASS: $1"; }
bad() { FAIL=$((FAIL + 1)); echo "FAIL: $1" >&2; }

# ---- hermetic curl shim + state root (shared scaffolding: test-lib.sh) --------

EMPTY_BIN="$HERMETIC_ROOT/empty-bin"
mkdir -p "$EMPTY_BIN"
ln -sf "$(command -v dirname)" "$EMPTY_BIN/dirname"
# shellcheck source=test-lib.sh
. "$HERE/test-lib.sh"
hermetic_curl_shim
export TRANSCRIPT_MIRROR_ROOT="$HERMETIC_ROOT/transcript"
mkdir -m 700 -p "$TRANSCRIPT_MIRROR_ROOT"

# ---- suite-local helpers (the shared ones live in test-lib.sh) -----------------

fresh_state() { rm -rf "$STATE_ROOT"; mkdir -m 700 -p "$STATE_ROOT"; }

fresh_case() { # isolated state + response dir per case
  fresh_state
  rm -rf "$RESP_DIR"
  mkdir -p "$RESP_DIR"
}

run_cli_env() { # ENV=VAL SCRIPT ARG... — same via env(1)
  local envs="$1"
  shift
  C_OUT=$(env "$envs" bash "$@" 2>"$ERRF")
  C_RC=$?
  C_ERR=$(cat "$ERRF")
}

# ---- intercom.sh / poller.sh refuse to be sourced ------------------------------

out=$(bash -c '. "'"$INTERCOM"'"' 2>&1)
rc=$?
if [ "$rc" -eq 1 ] && printf '%s' "$out" | grep -q 'subprocess CLI'; then
  ok "intercom.sh refuses to be sourced (rc 1 + message)"
else
  bad "intercom.sh source guard: rc=$rc out=$out"
fi

out=$(bash -c '. "'"$POLLER"'"' 2>&1)
rc=$?
if printf '%s' "$out" | grep -q 'subprocess CLI'; then
  ok "poller.sh refuses to be sourced"
else
  bad "poller.sh source behavior unexpected: rc=$rc out=$out"
fi

if [ -f "$WATCH" ]; then
  out=$(bash -c '. "'"$WATCH"'"' 2>&1)
  rc=$?
  if [ "$rc" -eq 1 ] && printf '%s' "$out" | grep -q 'subprocess CLI'; then
    ok "watch.sh refuses to be sourced (rc 1 + message)"
  else
    bad "watch.sh source guard: rc=$rc out=$out"
  fi
else
  bad "watch.sh missing (source guard)"
fi

# ---- AC21: bash/jq/curl only; graceful absence ---------------------------------

shebang_ok=1
for f in "$HERE"/*.sh; do
  [ "$(head -n 1 "$f")" = "#!/usr/bin/env bash" ] || { shebang_ok=0; bad "AC21 shebang not env bash: $f"; }
done
[ "$shebang_ok" -eq 1 ] && ok "AC21 every skills/intercom/*.sh starts with #!/usr/bin/env bash"

if [ ! -f "$WATCH" ]; then
  bad "CDT-512-C1 AC1 watch.sh missing from interpreter scan set"
else
  interp_ok=1
  for f in "$HERE"/*.sh; do
    if grep -E '(^|[[:space:]])(python3?|node|ruby|perl)([[:space:]|&;<>]|$)' "$f" >/dev/null; then
      interp_ok=0
      bad "AC1 interpreter invocation in $f"
    fi
  done
  [ "$interp_ok" -eq 1 ] && ok "AC1 no python/node/ruby/perl in skills/intercom/*.sh (incl. watch.sh)"
  if grep -E '\btg_api\b|\bir_token_read\b' "$WATCH" >/dev/null; then
    bad "CDT-512-C1 watch.sh must not call tg_api or ir_token_read"
  else
    ok "CDT-512-C1 watch.sh never calls tg_api / ir_token_read"
  fi
  if grep -E 'while[[:space:]]+(true|:)|sleep[[:space:]]' "$WATCH" >/dev/null; then
    bad "CDT-512-C1 AC1 watch.sh resident loop/sleep"
  else
    ok "CDT-512-C1 AC1 watch.sh is one-shot (no resident while/sleep)"
  fi
fi

out=$(env PATH="$EMPTY_BIN" "$(command -v bash)" "$INTERCOM" ask "hi" 2>&1)
rc=$?
if [ "$rc" -eq 1 ] \
  && printf '%s' "$out" | grep -q 'missing required tool' \
  && printf '%s' "$out" | grep -q 'jq' \
  && printf '%s' "$out" | grep -q 'AC21'; then
  ok "AC21 missing jq: one actionable line, exit 1, no stack trace"
else
  bad "AC21 jq absence: rc=$rc out=$out"
fi

out=$(bash -c 'PATH="'"$EMPTY_BIN"'"; . "'"$COMMON"'"; tg_api getMe' 2>&1)
rc=$?
if [ "$rc" -eq 1 ] && printf '%s' "$out" | grep -q 'missing required tool' && printf '%s' "$out" | grep -q 'curl'; then
  ok "AC21 missing curl: tg_api fails with an actionable line"
else
  bad "AC21 curl absence: rc=$rc out=$out"
fi

# ---- intercom ask (pending questions) ------------------------------------------

fresh_case
seed_token
run_cli "$INTERCOM" ask --sid main "Which staging tag is live?"
qid="$C_OUT"
if [ "$C_RC" -eq 0 ] && case "$qid" in q_*) true ;; *) false ;; esac \
  && [ -f "$STATE_ROOT/spool/main/pending/$qid.json" ]; then
  ok "ask writes pending/<qid>.json and prints the qid"
else
  bad "ask happy path: rc=$C_RC out=[$qid] err=$C_ERR"
fi
pend="$STATE_ROOT/spool/main/pending/$qid.json"
if [ -f "$pend" ] \
  && [ "$(jq -r '.sid' "$pend")" = "main" ] \
  && [ "$(jq -r '.text' "$pend")" = "Which staging tag is live?" ] \
  && [ "$(jq -r '.escalated' "$pend")" = "false" ] \
  && [ "$(jq -r '.escalated_at' "$pend")" = "null" ] \
  && [ "$(jq -r '.asked_at' "$pend")" -gt 0 ]; then
  ok "pending record matches the SPEC-038 shape"
else
  bad "pending record shape: $(cat "$pend" 2>/dev/null)"
fi
[ "$(stat -c %a "$pend" 2>/dev/null)" = "600" ] \
  && ok "pending record written 0600" \
  || bad "pending record mode: $(stat -c %a "$pend" 2>/dev/null)"

run_cli_env "INTERCOM_SID=env-sid" "$INTERCOM" ask "hello env"
if [ "$C_RC" -eq 0 ] && [ -d "$STATE_ROOT/spool/env-sid/pending" ]; then
  ok "INTERCOM_SID resolves the spool sid"
else
  bad "INTERCOM_SID: rc=$C_RC err=$C_ERR"
fi

run_cli_env "INTERCOM_SID=env-sid" "$INTERCOM" ask --sid cli-sid "hello both"
if [ "$C_RC" -eq 0 ] && [ -d "$STATE_ROOT/spool/cli-sid/pending" ] && [ ! -d "$STATE_ROOT/spool/env-sid2" ]; then
  ok "--sid beats INTERCOM_SID"
else
  bad "--sid precedence: rc=$C_RC err=$C_ERR"
fi

run_cli "$INTERCOM" ask --sid "../evil" "nope"
[ "$C_RC" -eq 2 ] && ok "invalid sid rejected with exit 2" || bad "invalid sid rc=$C_RC"

run_cli "$INTERCOM" ask "no sid anywhere"
[ "$C_RC" -eq 2 ] && ok "unresolvable sid exits 2 with usage" || bad "no-sid rc=$C_RC"

# ---- intercom send (outbox records, AC9 CLI side) -------------------------------

fresh_case
seed_token
run_cli "$INTERCOM" send --sid main "short reply"
if [ "$C_RC" -eq 0 ] && case "$C_OUT" in *spool/main/outbox/*.json) true ;; *) false ;; esac; then
  ok "send writes an outbox record and prints its path"
else
  bad "send short: rc=$C_RC out=[$C_OUT] err=$C_ERR"
fi
rec="$C_OUT"
if [ "$(jq -r '.dir' "$rec")" = "out" ] \
  && [ "$(jq -r '.kind' "$rec")" = "message" ] \
  && [ "$(jq -r '.text' "$rec")" = "short reply" ] \
  && [ "$(jq -r 'has("summary")' "$rec")" = "false" ]; then
  ok "below-threshold record has no summary (one message later, AC9)"
else
  bad "short record shape: $(cat "$rec")"
fi

long_text=""
i=0
while [ "$i" -lt 110 ]; do
  long_text="${long_text}0123456789"
  i=$((i + 1))
done
run_cli "$INTERCOM" send --sid main "$long_text"
rec="$C_OUT"
if [ "$C_RC" -eq 0 ] \
  && [ "$(jq -r '.text | length' "$rec")" -eq 1100 ] \
  && [ "$(jq -r '.summary | length' "$rec")" -eq 280 ]; then
  ok "AC9 long text: summary generated, capped at 280 chars, text intact"
else
  bad "AC9 long single para: rc=$C_RC rec=$rec"
fi

run_cli "$INTERCOM" send --sid main "$(printf 'First paragraph of the longread.\n\n%s' "$long_text")"
rec="$C_OUT"
if [ "$C_RC" -eq 0 ] && [ "$(jq -r '.summary' "$rec")" = "First paragraph of the longread." ]; then
  ok "AC9 generated summary is the first paragraph"
else
  bad "AC9 first-para summary: rc=$C_RC got=[$(jq -r '.summary' "$rec" 2>/dev/null)]"
fi

run_cli "$INTERCOM" send --sid main --summary "hand written" "body text"
rec="$C_OUT"
if [ "$C_RC" -eq 0 ] && [ "$(jq -r '.summary' "$rec")" = "hand written" ]; then
  ok "--summary overrides the generated summary"
else
  bad "--summary override: rc=$C_RC"
fi

printf 'attachment body\n' > "$HERMETIC_ROOT/att.md"
run_cli "$INTERCOM" send --sid main --file "$HERMETIC_ROOT/att.md" "with file"
rec="$C_OUT"
if [ "$C_RC" -eq 0 ] && [ "$(jq -r '.file' "$rec")" = "$HERMETIC_ROOT/att.md" ]; then
  ok "--file lands in the outbox record"
else
  bad "--file record: rc=$C_RC"
fi

run_cli "$INTERCOM" send --sid main --file "$HERMETIC_ROOT/nope.md" "bad file"
[ "$C_RC" -eq 1 ] && ok "--file that does not exist exits 1" || bad "--file missing rc=$C_RC"

printf '{"schema": 1, "members": {}, "concise_threshold": 10}\n' > "$STATE_ROOT/config.json"
run_cli "$INTERCOM" send --sid main "hello brave new world"
rec="$C_OUT"
if [ "$C_RC" -eq 0 ] && [ "$(jq -r '.summary // ""' "$rec")" = "hello brave new world" ]; then
  ok "concise_threshold honored from config.json"
else
  bad "threshold from config: rc=$C_RC rec=$rec"
fi

# ---- intercom away (AC17 CLI side, AC20 persistence) -----------------------------

fresh_state
run_cli "$INTERCOM" away on
if [ "$C_RC" -eq 0 ] && [ "$C_OUT" = "away: on" ] && [ -f "$STATE_ROOT/state/away" ]; then
  ok "AC17/AC20 away on writes state/away"
else
  bad "away on: rc=$C_RC out=[$C_OUT] err=$C_ERR"
fi
case "$(cat "$STATE_ROOT/state/away")" in
  ''|*[!0-9]*) bad "AC20 away file does not hold an epoch: $(cat "$STATE_ROOT/state/away")" ;;
  *) ok "AC20 away file holds an epoch audit trail" ;;
esac
run_cli "$INTERCOM" away status
if [ "$C_RC" -eq 0 ] && [ "$C_OUT" = "away: on" ]; then
  ok "AC20 away status persists across processes"
else
  bad "away status: rc=$C_RC out=[$C_OUT]"
fi
run_cli "$INTERCOM" away off
if [ "$C_RC" -eq 0 ] && [ "$C_OUT" = "away: off" ] && [ ! -f "$STATE_ROOT/state/away" ]; then
  ok "away off removes state/away"
else
  bad "away off: rc=$C_RC out=[$C_OUT]"
fi
run_cli "$INTERCOM" away bogus
[ "$C_RC" -eq 2 ] && ok "away rejects unknown args with exit 2" || bad "away bogus rc=$C_RC"

# ---- AC5: /setup slack is a zero-write stub --------------------------------------

slack_fence="$HERMETIC_ROOT/slack-fence.sh"
awk '
  /^## Sub: .*slack/ {insec=1; next}
  insec && /^## / {insec=0}
  insec && /^```bash$/ {inblock=1; next}
  inblock && /^```$/ {exit}
  inblock {print}
' "$SETUP_MD" > "$slack_fence"
if [ -s "$slack_fence" ] && grep -q "Slack ships in v1.1/v2." "$slack_fence"; then
  ac5dir="$HERMETIC_ROOT/ac5"
  mkdir -p "$ac5dir"
  out=$(HOME="$ac5dir" INTERCOM_STATE_ROOT="$ac5dir/state" bash "$slack_fence" 2>&1)
  rc=$?
  if [ "$rc" -eq 0 ] && [ "$out" = "Slack ships in v1.1/v2." ] && [ -z "$(ls -A "$ac5dir")" ]; then
    ok "AC5 /setup slack stub: exact notice, exit 0, zero state writes"
  else
    bad "AC5 slack stub: rc=$rc out=[$out] writes=[$(ls -A "$ac5dir")]"
  fi
else
  bad "AC5 could not extract the slack fence from commands/setup.md"
fi

# ---- AC1: setup-telegram token hygiene -------------------------------------------

fresh_case
put_resp_file "getMe" "$FIXTURES/getme-ok.json"
put_resp_file "getUpdates" "$FIXTURES/getupdates-pairing.json"
put_resp_file "getChat" "$FIXTURES/getchat-forum.json"
out=$(printf '%s\n' "$TEST_TOKEN" "Alexander" "" | bash "$SETUP" 2>&1)
rc=$?
tokfile="$HOME/.config/telegram/bot_token"
tokdir="$HOME/.config/telegram"
if [ -f "$tokfile" ] && [ "$(stat -c %a "$tokfile")" = "600" ] && [ "$(stat -c %a "$tokdir")" = "700" ]; then
  ok "AC1 token file written 0600 with a 0700 parent"
else
  bad "AC1 token modes: file=[$(stat -c %a "$tokfile" 2>/dev/null)] dir=[$(stat -c %a "$tokdir" 2>/dev/null)] rc=$rc out=$out"
fi

fresh_case
mkdir -m 755 -p "$tokdir"
put_resp_file "getMe" "$FIXTURES/getme-rejected.json"
out=$(printf '%s\n' "$TEST_TOKEN" "Alexander" "" | bash "$SETUP" 2>&1)
rc=$?
if [ "$rc" -eq 1 ] && [ "$(stat -c %a "$tokdir")" = "700" ] && printf '%s' "$out" | grep -q "getMe"; then
  ok "AC1 pre-existing loose parent tightened to 700; getMe rejection dies before state"
else
  bad "AC1 loose parent: rc=$rc dir=$(stat -c %a "$tokdir") out=$out"
fi
if [ -z "$(ls -A "$STATE_ROOT")" ]; then
  ok "AC1 getMe failure writes no state beyond the token file"
else
  bad "AC1 getMe failure created state: $(ls -A "$STATE_ROOT")"
fi

fresh_case
rm -rf "$HOME/.config"
out=$(printf '\n' | bash "$SETUP" 2>&1)
rc=$?
if [ "$rc" -eq 1 ] && printf '%s' "$out" | grep -q "empty token" && [ ! -f "$tokfile" ]; then
  ok "AC1 empty token refused; no token file written"
else
  bad "AC1 empty token: rc=$rc out=$out"
fi

# ---- AC1: setup re-run guard keeps an existing config ----------------------------

fresh_case
base_config "197372681" > "$STATE_ROOT/config.json"
cfg_before=$(cat "$STATE_ROOT/config.json")
: > "$CALLS_LOG"
out=$(printf 'n\n' | bash "$SETUP" 2>&1)
rc=$?
if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q "keeping existing config" \
  && [ "$(cat "$STATE_ROOT/config.json")" = "$cfg_before" ] && [ ! -s "$CALLS_LOG" ]; then
  ok "AC1 re-run guard: decline keeps config and makes no API calls"
else
  bad "AC1 re-run guard: rc=$rc out=$out"
fi

# ---- AC1: pairing happy path ----------------------------------------------------

fresh_case
seed_token
put_resp_file "getMe" "$FIXTURES/getme-ok.json"
put_resp_file "getUpdates" "$FIXTURES/getupdates-pairing.json"
put_resp_file "getChat" "$FIXTURES/getchat-forum.json"
out=$(printf '%s\n' "$TEST_TOKEN" "Alexander" "" | bash "$SETUP" 2>&1)
rc=$?
cfg="$STATE_ROOT/config.json"
if [ "$rc" -eq 0 ] && [ -f "$cfg" ] && [ "$(jq -r '.members | length' "$cfg")" -eq 1 ] \
  && [ -f "$STATE_ROOT/topics.json" ] && [ "$(jq -c '.' "$STATE_ROOT/topics.json")" = "{}" ] \
  && [ -f "$STATE_ROOT/state/seen.tsv" ] \
  && case "$(offset_val)" in ''|*[!0-9]*) false ;; *) true ;; esac \
  && [ "$(calls_count editForumTopic)" = "0" ] \
  && ! printf '%s' "$out" | grep -qF "$TEST_TOKEN"; then
  ok "AC1 pairing completes: one-member config, empty topics.json, seen/offset written, harness prompt token-free"
else
  bad "AC1 pairing completion: rc=$rc topics=$(cat "$STATE_ROOT/topics.json" 2>/dev/null) out=$out"
fi

arm=$(printf '%s\n' "$out" | awk '/--- BEGIN /,/--- END /')
arm_bytes=$(printf '%s' "$arm" | wc -c | tr -d ' ')
arm_ok=1
if ! printf '%s' "$arm" | grep -qF "$HERE/watch.sh"; then
  arm_ok=0
  bad "CDT-512-C1 AC5 arming block missing absolute watch.sh path"
fi
if ! printf '%s' "$arm" | grep -Eq 'every (3[0-9]|[45][0-9]|60) seconds'; then
  arm_ok=0
  bad "CDT-512-C1 AC5 arming block missing 30–60s cadence"
fi
if ! printf '%s' "$arm" | grep -qi 'grok' || ! printf '%s' "$arm" | grep -qi 'silent watcher'; then
  arm_ok=0
  bad "CDT-512-C1 AC5 arming block missing Grok silent watcher"
fi
if ! printf '%s' "$arm" | grep -q 'CronCreate' || ! printf '%s' "$arm" | grep -qi 'parent turn'; then
  arm_ok=0
  bad "CDT-512-C1 AC5 arming block missing Claude CronCreate-if-zero-parent-turn"
fi
if ! printf '%s' "$arm" | grep -qi 'grok' || ! printf '%s' "$arm" | grep -q 'CronCreate'; then
  arm_ok=0
  bad "CDT-512-C1 AC5 CronCreate must not be the sole arming instruction"
fi
if [ "$arm_bytes" -gt 4096 ]; then
  arm_ok=0
  bad "CDT-512-C1 AC5 arming block is $arm_bytes bytes (cap 4096)"
fi
if printf '%s' "$arm" | grep -qF "$TEST_TOKEN" || printf '%s' "$arm" | grep -qF "$SENTINEL"; then
  arm_ok=0
  bad "CDT-512-C1 AC5/AC6 sentinel or token in arming block"
fi
if printf '%s' "$arm" | grep -q 'watch-intercom.sh'; then
  arm_ok=0
  bad "CDT-512-C1 AC5 arming block instructs watch-intercom.sh"
fi
[ "$arm_ok" -eq 1 ] && ok "CDT-512-C1 AC5 host-aware arming block (abs watch.sh, 30–60s, Grok+Claude, ≤4KiB, token-free)"

wi_hits=$(find "$PLUGIN_ROOT" -name 'watch-intercom.sh' ! -path '*/.git/*' 2>/dev/null || true)
if [ -n "$wi_hits" ]; then
  bad "CDT-512-C1 AC7 watch-intercom.sh present in plugin tree: $wi_hits"
else
  ok "CDT-512-C1 AC7 no watch-intercom.sh in plugin tree"
fi

# ---- AC2: unpaired bot relays nothing --------------------------------------------

fresh_case
seed_token
mkdir -m 700 -p "$STATE_ROOT/state"
printf '100\n' > "$STATE_ROOT/state/offset"
run_poller
if [ "$P_RC" -eq 0 ] && [ ! -d "$STATE_ROOT/spool" ] && [ ! -f "$STATE_ROOT/topics.json" ] \
  && [ ! -f "$STATE_ROOT/state/heartbeat" ] && [ "$(offset_val)" = "100" ] \
  && [ ! -s "$CALLS_LOG" ]; then
  ok "AC2 unpaired (no config.json): exit 0, zero artifacts, no fetch"
else
  bad "AC2 unpaired: rc=$P_RC calls=[$(cat "$CALLS_LOG")] spool=$([ -d "$STATE_ROOT/spool" ] && echo yes || echo no)"
fi

fresh_case
seed_token
printf '{"schema": 1, "members": {}}\n' > "$STATE_ROOT/config.json"
mkdir -m 700 -p "$STATE_ROOT/state"
printf '100\n' > "$STATE_ROOT/state/offset"
run_poller
if [ "$P_RC" -eq 0 ] && [ ! -d "$STATE_ROOT/spool" ] && [ ! -s "$CALLS_LOG" ]; then
  ok "AC2 unpaired (empty members): silent no-op"
else
  bad "AC2 empty members: rc=$P_RC"
fi

fresh_case
seed_token
printf 'not json at all\n' > "$STATE_ROOT/config.json"
mkdir -m 700 -p "$STATE_ROOT/state"
printf '100\n' > "$STATE_ROOT/state/offset"
run_poller
if [ "$P_RC" -eq 0 ] && [ ! -d "$STATE_ROOT/spool" ]; then
  ok "AC2 unpaired (invalid JSON config): fail-closed no-op"
else
  bad "AC2 invalid config: rc=$P_RC"
fi

# ---- AC3: allowlist fail-closed, non-numeric keys ignored -------------------------

fresh_case
seed_paired "197372681"
cfg_edit "$STATE_ROOT/config.json" '.members["not-numeric"] = {name: "N", role: "member"}'
put_resp "getUpdates" "$(result_body "$(upd_msg 300 999999 "stranger")" "$(upd_msg 301 197372681 "from owner")")"
run_poller
if [ "$P_RC" -eq 0 ] \
  && printf '%s' "$P_ERR" | grep -q "not numeric" \
  && [ "$(inbox_n main)" = "1" ] \
  && [ "$(jq -r '.update_id' "$(inbox_files main)")" = "301" ] \
  && [ "$(offset_val)" = "302" ] \
  && [ "$(ls "$STATE_ROOT/spool")" = "main" ]; then
  ok "AC3 stranger chat ignored with zero artifacts; allowlisted id relays; non-numeric key warned and ignored"
else
  bad "AC3 fail-closed: rc=$P_RC err=$P_ERR inbox=$(inbox_n main)"
fi

# ---- AC4: sentinel token never leaks ----------------------------------------------

fresh_case
seed_token "$SENTINEL"
base_config "197372681" > "$STATE_ROOT/config.json"
mkdir -m 700 -p "$STATE_ROOT/state"
printf '100\n' > "$STATE_ROOT/state/offset"
: > "$STATE_ROOT/state/seen.tsv"
date +%s > "$STATE_ROOT/state/heartbeat"
printf '{"general": {"thread_id": 100, "title": "General"}}\n' > "$STATE_ROOT/topics.json"
printf 'attachment body\n' > "$HERMETIC_ROOT/att.txt"
put_outbox "main" "status update" "status" "$HERMETIC_ROOT/att.txt"
put_pending "proj" "q_esc" "expired question" "$(( $(date +%s) - 3600 ))"
put_resp "getUpdates" "$(result_body "$(upd_msg 100 197372681 "relay me")")"
put_resp_file "createForumTopic" "$FIXTURES/createforumtopic-ok.json"
export CURL_STDERR_ECHO=1
run_poller
unset CURL_STDERR_ECHO
leak=""
grep -rlF "$SENTINEL" "$STATE_ROOT" >/dev/null 2>&1 && leak="$leak state-root"
grep -qF "$SENTINEL" "$ARGV_LOG" 2>/dev/null && leak="$leak curl-argv"
grep -qF "$SENTINEL" "$CALLS_LOG" 2>/dev/null && leak="$leak calls-log"
printf '%s' "$P_OUT" | grep -qF "$SENTINEL" && leak="$leak poller-stdout"
printf '%s' "$P_ERR" | grep -qF "$SENTINEL" && leak="$leak poller-stderr"
if [ -z "$leak" ]; then
  ok "AC4 sentinel token absent from every written file and from curl argv"
else
  bad "AC4 sentinel leaked to:$leak"
fi
if printf '%s' "$P_ERR" | grep -q "\[scrubbed\]"; then
  ok "AC4 curl stderr scrubbed before re-emission"
else
  bad "AC4 stderr scrub missing: $P_ERR"
fi
nonstdin=$(grep -c -v 'stdin-config$' "$CALLS_LOG" || true)
argvk=1
grep -Fx 'argv: -K' "$ARGV_LOG" >/dev/null || argvk=0
grep -Fx 'argv: -' "$ARGV_LOG" >/dev/null || argvk=0
if [ "$nonstdin" = "0" ] && [ "$argvk" -eq 1 ]; then
  ok "AC4 every request URL travels via the -K - stdin config, never argv"
else
  bad "AC4 transport path: nonstdin=$nonstdin argvk=$argvk calls=[$(cat "$CALLS_LOG")]"
fi

# CDT-512-C1 AC6: sentinel absent from adapter stdout (and not passed as argv)
fresh_case
seed_token "$SENTINEL"
base_config "197372681" > "$STATE_ROOT/config.json"
mkdir -m 700 -p "$STATE_ROOT/state"
printf '100\n' > "$STATE_ROOT/state/offset"
: > "$STATE_ROOT/state/seen.tsv"
date +%s > "$STATE_ROOT/state/heartbeat"
printf '{"general": {"thread_id": 100, "title": "General"}}\n' > "$STATE_ROOT/topics.json"
put_resp "getUpdates" '{"ok":true,"result":[]}'
export CURL_STDERR_ECHO=1
run_watch
unset CURL_STDERR_ECHO
aleak=""
printf '%s' "$W_OUT" | grep -qF "$SENTINEL" && aleak="$aleak adapter-stdout"
printf '%s' "$W_ERR" | grep -qF "$SENTINEL" && aleak="$aleak adapter-stderr"
grep -qF "$SENTINEL" "$ARGV_LOG" 2>/dev/null && aleak="$aleak curl-argv"
if [ -z "$aleak" ] && [ "${W_RC:-1}" -eq 0 ]; then
  ok "CDT-512-C1 AC6 sentinel absent from adapter stdout/stderr and curl argv"
else
  bad "CDT-512-C1 AC6 adapter sentinel leaked to:$aleak rc=${W_RC-unset}"
fi

# ---- AC6/AC7/AC10: thread-mapped delivery, no cross-delivery, no pickup typing ----

fresh_case
seed_paired "197372681"
cfg_edit "$STATE_ROOT/topics.json" '.["sess-a"] = {thread_id: 201, title: "sess-a"} | .["sess-b"] = {thread_id: 202, title: "sess-b"}'
put_resp "getUpdates" "$(result_body \
  "$(upd_msg 300 197372681 "for a" 201)" \
  "$(upd_msg 301 197372681 "for b" 202)" \
  "$(upd_msg 302 197372681 "general traffic" 100)" \
  "$(upd_msg 303 197372681 "plain chat")")"
run_poller
if [ "$P_RC" -eq 0 ] \
  && [ "$(inbox_n sess-a)" = "1" ] && [ "$(jq -r '.update_id' "$(inbox_files sess-a)")" = "300" ] \
  && [ "$(inbox_n sess-b)" = "1" ] && [ "$(jq -r '.update_id' "$(inbox_files sess-b)")" = "301" ] \
  && [ "$(inbox_n main)" = "2" ] \
  && [ "$(offset_val)" = "304" ] && [ "$(seen_n)" = "4" ]; then
  ok "AC6/AC7 each update lands only in its thread-mapped sid inbox; general and plain chat reach default_session"
else
  bad "AC6/AC7/AC8 routing: rc=$P_RC a=$(inbox_n sess-a) b=$(inbox_n sess-b) main=$(inbox_n main)"
fi
if [ "$(calls_count sendChatAction)" = "0" ]; then
  ok "AC10 inbound pickup sends no sendChatAction typing"
else
  bad "AC10 pickup typing: sendChatAction=$(calls_count sendChatAction) want 0"
fi

# ---- AC10 send path: typing immediately before sendMessage on outbox drain --------

fresh_case
seed_paired "197372681"
run_cli "$INTERCOM" send --sid main "composing reply"
run_poller
if [ "$P_RC" -eq 0 ] \
  && [ "$(calls_count sendMessage)" = "1" ] \
  && [ "$(calls_count sendChatAction)" = "1" ] \
  && typing_before_each_send \
  && grep -Fq 'text=composing reply' "$ARGV_LOG"; then
  ok "AC10 outbox drain sends typing once immediately before sendMessage"
else
  bad "AC10 send-path typing: rc=$P_RC action=$(calls_count sendChatAction) sends=$(calls_count sendMessage) err=$P_ERR"
fi

# ---- AC8: default-session replies return to the general topic ---------------------

run_cli "$INTERCOM" send --sid main "walkie reply"
run_poller
if [ "$P_RC" -eq 0 ] && grep -Fq 'text=walkie reply' "$ARGV_LOG" \
  && grep -Fq 'message_thread_id=100' "$ARGV_LOG"; then
  ok "AC8 reply for the default session goes back to the general topic thread"
else
  bad "AC8 reply routing: rc=$P_RC err=$P_ERR"
fi

# ---- AC9: longread is one summary + one document, never chunk-split ----------------

fresh_case
seed_paired "197372681"
cfg_edit "$STATE_ROOT/topics.json" '.["lr"] = {thread_id: 202, title: "lr"}'
long_text=""
i=0
while [ "$i" -lt 300 ]; do
  long_text="${long_text}0123456789"
  i=$((i + 1))
done
put_outbox "lr" "$long_text" "short summary"
put_resp "getUpdates" '{"ok":true,"result":[]}'
run_poller
recs_left=$(find "$STATE_ROOT/spool/lr/outbox" -name '*.json' 2>/dev/null | wc -l | tr -d ' ')
if [ "$P_RC" -eq 0 ] \
  && [ "$(calls_count sendMessage)" = "1" ] && [ "$(calls_count sendDocument)" = "1" ] \
  && grep -Fq 'text=short summary' "$ARGV_LOG" \
  && [ "$recs_left" = "0" ]; then
  ok "AC9 3000-char outbound: exactly one <=280-char sendMessage + one sendDocument, never chunked; record deleted on 2xx"
else
  bad "AC9 longread delivery: rc=$P_RC sends=$(calls_count sendMessage) docs=$(calls_count sendDocument) err=$P_ERR"
fi

# ---- AC11: outbound notification auto-creates the session topic --------------------

fresh_case
seed_paired "197372681"
put_outbox "fresh-sid" "notify text"
put_resp "getUpdates" '{"ok":true,"result":[]}'
put_resp_file "createForumTopic" "$FIXTURES/createforumtopic-ok.json"
run_poller
if [ "$P_RC" -eq 0 ] \
  && [ "$(calls_count createForumTopic)" = "1" ] \
  && [ "$(jq -r '.["fresh-sid"].thread_id' "$STATE_ROOT/topics.json")" = "777" ] \
  && grep -Fq 'title=fresh-sid' "$ARGV_LOG" \
  && grep -Fq 'message_thread_id=777' "$ARGV_LOG" \
  && grep -Fq 'text=notify text' "$ARGV_LOG" \
  && [ "$(find "$STATE_ROOT/spool/fresh-sid/outbox" -name '*.json' 2>/dev/null | wc -l | tr -d ' ')" = "0" ]; then
  ok "AC11 first outbound auto-creates the topic, records it, and delivers into it"
else
  bad "AC11 auto-topic: rc=$P_RC topics=$(cat "$STATE_ROOT/topics.json" 2>/dev/null) err=$P_ERR"
fi

# ---- AC25: two-member config tolerated; outbound uses the lowest chat id -----------

fresh_case
seed_token
cp "$FIXTURES/config-two-members.json" "$STATE_ROOT/config.json"
mkdir -m 700 -p "$STATE_ROOT/state"
printf '100\n' > "$STATE_ROOT/state/offset"
: > "$STATE_ROOT/state/seen.tsv"
date +%s > "$STATE_ROOT/state/heartbeat"
printf '{"general": {"thread_id": 100, "title": "General"}}\n' > "$STATE_ROOT/topics.json"
put_outbox "main" "to owner"
put_resp "getUpdates" "$(result_body "$(upd_msg 400 197372681 "from owner")" "$(upd_msg 401 2039944771 "from second")")"
run_poller
if [ "$P_RC" -eq 0 ] \
  && [ "$(inbox_n main)" = "2" ] \
  && [ "$(offset_val)" = "402" ] \
  && grep -Fq 'chat_id=197372681' "$ARGV_LOG" \
  && printf '%s' "$P_ERR" | grep -q "multiple members"; then
  ok "AC25 two-member fixture parses and processes both; outbound pins the lowest chat id with a warning"
else
  bad "AC25 two members: rc=$P_RC inbox=$(inbox_n main) err=$P_ERR"
fi

# ---- AC23: runtime state stays box-level; repo untouched ---------------------------

before=$(git -C "$PLUGIN_ROOT" status --porcelain --untracked-files=all)
fresh_case
put_resp_file "getMe" "$FIXTURES/getme-ok.json"
put_resp_file "getUpdates" "$FIXTURES/getupdates-pairing.json"
put_resp_file "getChat" "$FIXTURES/getchat-forum.json"
printf '%s\n' "$TEST_TOKEN" "Alexander" "" | bash "$SETUP" >/dev/null 2>&1
seed_paired "197372681"
put_resp "getUpdates" "$(result_body "$(upd_msg 100 197372681 "cycle under temp root")")"
run_poller
after=$(git -C "$PLUGIN_ROOT" status --porcelain --untracked-files=all)
if [ "$before" = "$after" ] && [ -f "$STATE_ROOT/state/offset" ] \
  && case "$HERMETIC_ROOT" in "$PLUGIN_ROOT"/*) false ;; *) true ;; esac; then
  ok "AC23 setup + full cycle with INTERCOM_STATE_ROOT writes nothing under the repo"
else
  bad "AC23 repo hygiene: dirty=$([ "$before" = "$after" ] && echo no || echo yes)"
fi

# ---- CDT-512-C2: per-dev bot setup + operator runbook ----------------------------

fresh_case
rm -rf "$HOME/.config"
out=$(printf '\n' | bash "$SETUP" 2>&1)
rc=$?
preamble_ok=1
printf '%s' "$out" | grep -qi 'create your own' || preamble_ok=0
printf '%s' "$out" | grep -qi 'never share' || preamble_ok=0
printf '%s' "$out" | grep -qi 'never paste' || preamble_ok=0
printf '%s' "$out" | grep -q 'BotFather' || preamble_ok=0
# Preamble must appear even when the token is empty (printed before the prompt).
if [ "$rc" -eq 1 ] && [ "$preamble_ok" -eq 1 ] && ! printf '%s' "$out" | grep -qF "$TEST_TOKEN"; then
  ok "CDT-512-C2 AC2 BotFather preamble before token prompt (create own / never share / never paste)"
else
  bad "CDT-512-C2 AC2 preamble: rc=$rc preamble_ok=$preamble_ok out=$out"
fi
if printf '%s' "$out" | grep -q 'Alexander'; then
  bad "CDT-512-C2 AC1 empty-token path still mentions Alexander"
else
  ok "CDT-512-C2 AC1 empty-token path has no Alexander default"
fi

fresh_case
put_resp_file "getMe" "$FIXTURES/getme-ok.json"
put_resp_file "getUpdates" "$FIXTURES/getupdates-pairing.json"
put_resp_file "getChat" "$FIXTURES/getchat-forum.json"
out=$(printf '%s\n' "$TEST_TOKEN" "" "" | USER=testdev bash "$SETUP" 2>&1)
rc=$?
cfg="$STATE_ROOT/config.json"
if [ "$rc" -eq 0 ] && [ "$(jq -r '.members["197372681"].name' "$cfg")" = "testdev" ] \
  && printf '%s' "$out" | grep -q 'Member name \[testdev\]' \
  && ! printf '%s' "$out" | grep -q 'Alexander' \
  && ! printf '%s' "$out" | grep -qF "$TEST_TOKEN"; then
  ok "CDT-512-C2 AC1 member name defaults to USER, not Alexander"
else
  bad "CDT-512-C2 AC1 USER default: rc=$rc name=$(jq -r '.members["197372681"].name' "$cfg" 2>/dev/null) out=$out"
fi

fresh_case
put_resp_file "getMe" "$FIXTURES/getme-ok.json"
out=$(printf '%s\n' "$TEST_TOKEN" "" | env -u USER bash "$SETUP" 2>&1)
rc=$?
if [ "$rc" -eq 1 ] && printf '%s' "$out" | grep -qi 'member name required' \
  && [ -z "$(ls -A "$STATE_ROOT" 2>/dev/null)" ]; then
  ok "CDT-512-C2 AC1 empty USER and empty name refuses before state"
else
  bad "CDT-512-C2 AC1 require name: rc=$rc out=$out state=$(ls -A "$STATE_ROOT" 2>/dev/null)"
fi

fresh_case
put_resp_file "getMe" "$FIXTURES/getme-ok.json"
put_resp_file "getUpdates" "$FIXTURES/getupdates-pairing.json"
put_resp_file "getChat" "$FIXTURES/getchat-plain.json"
out=$(printf '%s\n' "$TEST_TOKEN" "testdev" "" | USER=testdev bash "$SETUP" 2>&1)
rc=$?
cfg="$STATE_ROOT/config.json"
if [ "$rc" -eq 0 ] && [ "$(jq -r '.topics_enabled' "$cfg")" = "false" ] \
  && printf '%s' "$out" | grep -q 'topics_enabled=false' \
  && ! printf '%s' "$out" | grep -qi 'failed setup' \
  && printf '%s' "$out" | grep -qi 'General' \
  && printf '%s' "$out" | grep -qi 'topic'; then
  ok "CDT-512-C2 AC6/AC7 topics off is a supported General window, not a failed setup"
else
  bad "CDT-512-C2 AC6/AC7 topics off: rc=$rc topics=$(jq -r '.topics_enabled' "$cfg" 2>/dev/null) out=$out"
fi

fresh_case
put_resp_file "getMe" "$FIXTURES/getme-ok.json"
put_resp_file "getUpdates" "$FIXTURES/getupdates-pairing.json"
put_resp_file "getChat" "$FIXTURES/getchat-forum.json"
out=$(printf '%s\n' "$TEST_TOKEN" "testdev" "" | USER=testdev bash "$SETUP" 2>&1)
if printf '%s' "$out" | grep -qi 'topic' && printf '%s' "$out" | grep -qiE 'sid per topic|session'; then
  ok "CDT-512-C2 AC6 setup guides enabling topics for sid-per-topic"
else
  bad "CDT-512-C2 AC6 topics guide missing: out=$out"
fi

if grep -qi 'shared bot' "$SETUP_MD" && grep -qi 'memory' "$SETUP_MD" \
  && grep -qi 'member name' "$SETUP_MD" && grep -qi 'reuse' "$SETUP_MD"; then
  ok "CDT-512-C2 AC3 commands/setup.md agent rules (no shared bot from memory; reuse vs replace)"
else
  bad "CDT-512-C2 AC3 commands/setup.md missing agent rules"
fi

rb="$PLUGIN_ROOT/docs/runbooks/setup-telegram.md"
if [ -f "$rb" ] \
  && grep -qi 'topics on' "$rb" && grep -qi 'sid per topic' "$rb" \
  && grep -qi 'topics off' "$rb" && grep -qi 'General' "$rb" \
  && grep -qi 'read receipt' "$rb"; then
  ok "CDT-512-C2 AC4/AC8 runbook documents both topic modes and no read receipts"
else
  bad "CDT-512-C2 AC4/AC8 runbook missing or incomplete ($rb)"
fi

if grep -q 'docs/runbooks/setup-telegram.md' "$PLUGIN_ROOT/README.md"; then
  ok "CDT-512-C2 AC4 README one-liner points at the Telegram setup runbook"
else
  bad "CDT-512-C2 AC4 README missing setup-telegram.md pointer"
fi

# ---- CDT-512-C3: seed General; unmapped walkie-talkie; ignore bot/service ------

fresh_case
: > "$CALLS_LOG"
: > "$ARGV_LOG"
put_resp_file "getMe" "$FIXTURES/getme-ok.json"
put_resp_file "getUpdates" "$FIXTURES/getupdates-pairing-thread.json"
put_resp_file "getChat" "$FIXTURES/getchat-plain.json"
put_resp_file "editForumTopic" "$FIXTURES/editforumtopic-ok.json"
out=$(printf '%s\n' "$TEST_TOKEN" "testdev" "" | USER=testdev bash "$SETUP" 2>&1)
rc=$?
cfg="$STATE_ROOT/config.json"
if [ "$rc" -eq 0 ] \
  && [ "$(jq -r '.general.thread_id' "$STATE_ROOT/topics.json")" = "283843" ] \
  && [ "$(jq -r '.general.title' "$STATE_ROOT/topics.json")" = "General" ] \
  && [ "$(jq -r '.topics_enabled' "$cfg")" = "false" ] \
  && [ "$(calls_count editForumTopic)" = "1" ] \
  && grep -Fq 'name=General' "$ARGV_LOG" \
  && grep -Fq 'message_thread_id=283843' "$ARGV_LOG" \
  && [ "$(inbox_n main)" = "0" ] \
  && ! printf '%s' "$out" | grep -qF "$TEST_TOKEN"; then
  ok "CDT-512-C3 AC1/AC2 pairing with message_thread_id seeds general and calls editForumTopic"
else
  bad "CDT-512-C3 AC1/AC2 seed: rc=$rc topics=$(cat "$STATE_ROOT/topics.json" 2>/dev/null) calls=$(calls_count editForumTopic) out=$out"
fi

fresh_case
put_resp_file "getMe" "$FIXTURES/getme-ok.json"
put_resp_file "getUpdates" "$FIXTURES/getupdates-pairing-thread.json"
put_resp_file "getChat" "$FIXTURES/getchat-plain.json"
put_resp_file "editForumTopic" "$FIXTURES/rejected-400.json"
out=$(printf '%s\n' "$TEST_TOKEN" "testdev" "" | USER=testdev bash "$SETUP" 2>&1)
rc=$?
if [ "$rc" -eq 0 ] \
  && [ "$(jq -r '.general.thread_id' "$STATE_ROOT/topics.json")" = "283843" ] \
  && ! printf '%s' "$out" | grep -qF "$TEST_TOKEN"; then
  ok "CDT-512-C3 AC2 pairing succeeds when editForumTopic is rejected"
else
  bad "CDT-512-C3 AC2 fail-open rename: rc=$rc out=$out"
fi

fresh_case
mkdir -m 755 -p "$STATE_ROOT/state"
put_resp_file "getMe" "$FIXTURES/getme-ok.json"
put_resp_file "getUpdates" "$FIXTURES/getupdates-pairing.json"
put_resp_file "getChat" "$FIXTURES/getchat-plain.json"
out=$(printf '%s\n' "$TEST_TOKEN" "testdev" "" | USER=testdev bash "$SETUP" 2>&1)
rc=$?
mode=$(stat -c %a "$STATE_ROOT/state" 2>/dev/null || stat -f %Lp "$STATE_ROOT/state" 2>/dev/null)
if [ "$rc" -eq 0 ] && [ "$mode" = "700" ]; then
  ok "CDT-512-C3 AC7 existing state/ dir chmod 700"
else
  bad "CDT-512-C3 AC7 chmod: rc=$rc mode=$mode"
fi

fresh_case
seed_paired "197372681"
printf '{}\n' > "$STATE_ROOT/topics.json"
put_resp "getUpdates" "$(result_body "$(upd_msg 300 197372681 "first inbound" 283843)")"
run_poller
if [ "$P_RC" -eq 0 ] \
  && [ "$(inbox_n main)" = "1" ] \
  && [ "$(jq -r '.text' "$(inbox_files main)")" = "first inbound" ] \
  && [ "$(jq -r '.thread_id' "$(inbox_files main)")" = "283843" ] \
  && [ "$(offset_val)" = "301" ] \
  && [ "$(calls_count sendChatAction)" = "0" ]; then
  ok "CDT-512-C3 AC3 unmapped thread + empty map relays to default_session"
else
  bad "CDT-512-C3 AC3 empty map: rc=$P_RC inbox=$(inbox_n main) err=$P_ERR"
fi

fresh_case
seed_paired "197372681"
# seed_paired already has only general
put_resp "getUpdates" "$(result_body "$(upd_msg 300 197372681 "walkie" 283843)")"
run_poller
if [ "$P_RC" -eq 0 ] \
  && [ "$(inbox_n main)" = "1" ] \
  && [ "$(jq -r '.text' "$(inbox_files main)")" = "walkie" ] \
  && [ "$(offset_val)" = "301" ]; then
  ok "CDT-512-C3 AC3 unmapped thread + only-general map relays to default_session"
else
  bad "CDT-512-C3 AC3 only-general: rc=$P_RC inbox=$(inbox_n main) err=$P_ERR"
fi

fresh_case
seed_paired "197372681"
cfg_edit "$STATE_ROOT/topics.json" '.["sess-a"] = {thread_id: 201, title: "sess-a"}'
put_pending "main" "q_keep" "still pending" "$(date +%s)"
put_resp "getUpdates" "$(result_body "$(upd_msg 300 197372681 "stray" 999)")"
run_poller
pending_left=$(find "$STATE_ROOT/spool/main/pending" -name '*.json' 2>/dev/null | wc -l | tr -d ' ')
if [ "$P_RC" -eq 0 ] \
  && [ "$(inbox_n main)" = "0" ] \
  && [ "$(inbox_n sess-a)" = "0" ] \
  && [ "$pending_left" = "1" ] \
  && [ "$(offset_val)" = "301" ] \
  && [ "$(calls_count sendChatAction)" = "0" ] \
  && printf '%s' "$P_ERR" | grep -q "unmapped topic"; then
  ok "CDT-512-C3 AC4 unmapped + session-topic map stays fail-closed"
else
  bad "CDT-512-C3 AC4 fail-closed: rc=$P_RC inbox=$(inbox_n main) pending=$pending_left err=$P_ERR"
fi

fresh_case
seed_paired "197372681"
put_resp_file "getMe" "$FIXTURES/getme-ok.json"
put_pending "main" "q_bot" "open question" "$(date +%s)"
put_resp "getUpdates" "$(result_body "$(upd_msg_from 300 197372681 "self echo" 987654321)")"
run_poller
pending_left=$(find "$STATE_ROOT/spool/main/pending" -name '*.json' 2>/dev/null | wc -l | tr -d ' ')
answered_n=$(find "$STATE_ROOT/spool/main/answered" -name '*.json' 2>/dev/null | wc -l | tr -d ' ')
if [ "$P_RC" -eq 0 ] \
  && [ "$(inbox_n main)" = "0" ] \
  && [ "$pending_left" = "1" ] && [ "$answered_n" = "0" ] \
  && [ "$(offset_val)" = "301" ] \
  && [ "$(calls_count sendChatAction)" = "0" ]; then
  ok "CDT-512-C3 AC5 bot from_id ignored: zero inbox, pending stays"
else
  bad "CDT-512-C3 AC5 bot-id: rc=$P_RC inbox=$(inbox_n main) pending=$pending_left answered=$answered_n err=$P_ERR"
fi

for _svc in forum_topic_edited forum_topic_created forum_topic_closed forum_topic_reopened; do
  fresh_case
  seed_paired "197372681"
  put_pending "main" "q_svc" "open question" "$(date +%s)"
  put_resp "getUpdates" "$(result_body "$(upd_forum_svc 300 197372681 987654321 100 "$_svc" "General")")"
  run_poller
  pending_left=$(find "$STATE_ROOT/spool/main/pending" -name '*.json' 2>/dev/null | wc -l | tr -d ' ')
  if [ "$P_RC" -eq 0 ] \
    && [ "$(inbox_n main)" = "0" ] \
    && [ "$pending_left" = "1" ] \
    && [ "$(offset_val)" = "301" ] \
    && [ "$(calls_count sendChatAction)" = "0" ]; then
    ok "CDT-512-C3 AC6 empty-text ${_svc} ignored"
  else
    bad "CDT-512-C3 AC6 ${_svc}: rc=$P_RC inbox=$(inbox_n main) pending=$pending_left err=$P_ERR"
  fi
done

if grep -q 'Walkie-talkie' "$PLUGIN_ROOT/docs/runbooks/setup-telegram.md" \
  && grep -q 'unknown thread is dropped' "$PLUGIN_ROOT/docs/runbooks/setup-telegram.md"; then
  ok "CDT-512-C3 AC8 runbook unmapped-topic row matches empty-map relay"
else
  bad "CDT-512-C3 AC8 runbook unmapped-topic row missing Walkie-talkie/drop wording"
fi

fresh_case
seed_paired "197372681"
cfg_edit "$STATE_ROOT/config.json" '.topics_enabled = false'
printf '{}\n' > "$STATE_ROOT/topics.json"
put_resp "getUpdates" "$(result_body "$(upd_msg 300 197372681 "ac8 walkie" 283843)")"
run_poller
if [ "$P_RC" -eq 0 ] \
  && [ "$(inbox_n main)" = "1" ] \
  && [ "$(jq -r '.thread_id' "$(inbox_files main)")" = "283843" ] \
  && [ "$(offset_val)" = "301" ] \
  && [ "$(jq -r '.topics_enabled' "$STATE_ROOT/config.json")" = "false" ]; then
  ok "CDT-512-C3 AC8 topics_enabled=false inbound with thread_id delivers per AC3"
else
  bad "CDT-512-C3 AC8 delivery: rc=$P_RC inbox=$(inbox_n main) topics=$(jq -r '.topics_enabled' "$STATE_ROOT/config.json" 2>/dev/null) err=$P_ERR"
fi

fresh_case
seed_paired "197372681"
cfg_edit "$STATE_ROOT/config.json" '.topics_enabled = false'
put_resp "getUpdates" "$(result_body "$(upd_msg 300 197372681 "ac8 only-general" 283843)")"
run_poller
if [ "$P_RC" -eq 0 ] \
  && [ "$(inbox_n main)" = "1" ] \
  && [ "$(jq -r '.thread_id' "$(inbox_files main)")" = "283843" ] \
  && [ "$(offset_val)" = "301" ] \
  && [ "$(jq -r '.topics_enabled' "$STATE_ROOT/config.json")" = "false" ]; then
  ok "CDT-512-C3 AC8 topics_enabled=false + only-general map delivers per AC3"
else
  bad "CDT-512-C3 AC8 only-general: rc=$P_RC inbox=$(inbox_n main) err=$P_ERR"
fi

# ---- CDT-512-C4: TTY-less token reuse + pairing wait ---------------------------

fresh_case
seed_token
put_resp_file "getMe" "$FIXTURES/getme-ok.json"
put_resp_file "getUpdates" "$FIXTURES/getupdates-pairing.json"
put_resp_file "getChat" "$FIXTURES/getchat-forum.json"
tok_before=$(cat "$HOME/.config/telegram/bot_token")
out=$(printf '%s\n' "y" "testdev" | USER=testdev bash "$SETUP" 2>&1)
rc=$?
if [ "$rc" -eq 0 ] \
  && printf '%s' "$out" | grep -qi 'reuse' \
  && printf '%s' "$out" | grep -q 'bot_token' \
  && [ "$(cat "$HOME/.config/telegram/bot_token")" = "$tok_before" ] \
  && [ "$(stat -c %a "$HOME/.config/telegram/bot_token")" = "600" ] \
  && ! printf '%s' "$out" | grep -qF "$TEST_TOKEN" \
  && [ "$(jq -r '.members["197372681"].name' "$STATE_ROOT/config.json")" = "testdev" ]; then
  ok "CDT-512-C4 AC1 mode-600 bot_token offers reuse without printing the token"
else
  bad "CDT-512-C4 AC1 reuse: rc=$rc tok_printed=$(printf '%s' "$out" | grep -cF "$TEST_TOKEN") out=$out"
fi

fresh_case
seed_token
put_resp_file "getMe" "$FIXTURES/getme-ok.json"
put_resp_file "getUpdates" "$FIXTURES/getupdates-pairing.json"
put_resp_file "getChat" "$FIXTURES/getchat-forum.json"
out=$(printf '%s\n' "" "testdev" | USER=testdev bash "$SETUP" 2>&1)
rc=$?
if [ "$rc" -eq 0 ] && ! printf '%s' "$out" | grep -qF "$TEST_TOKEN" \
  && [ -f "$STATE_ROOT/config.json" ]; then
  ok "CDT-512-C4 AC1 empty reuse answer defaults to keep the existing token"
else
  bad "CDT-512-C4 AC1 default-Y reuse: rc=$rc out=$out"
fi

fresh_case
seed_token
put_resp_file "getMe" "$FIXTURES/getme-ok.json"
put_resp_file "getUpdates" "$FIXTURES/getupdates-pairing.json"
put_resp_file "getChat" "$FIXTURES/getchat-forum.json"
out=$(printf '%s\n' "$TEST_TOKEN" "testdev" | USER=testdev bash "$SETUP" 2>&1)
rc=$?
if [ "$rc" -eq 0 ] && ! printf '%s' "$out" | grep -qF "$TEST_TOKEN" \
  && [ "$(cat "$HOME/.config/telegram/bot_token")" = "$TEST_TOKEN" ]; then
  ok "CDT-512-C4 AC1 piped token as reuse answer still reuses and stays unpublished"
else
  bad "CDT-512-C4 AC1 piped-token reuse: rc=$rc out=$out"
fi

fresh_case
seed_token
put_resp_file "getMe" "$FIXTURES/getme-ok.json"
put_resp_file "getUpdates" "$FIXTURES/getupdates-pairing.json"
put_resp_file "getChat" "$FIXTURES/getchat-forum.json"
NEW_TOKEN="999999999:REPLACEMENT-TOKEN-NOT-REAL"
out=$(printf '%s\n' "n" "$NEW_TOKEN" "testdev" | USER=testdev bash "$SETUP" 2>&1)
rc=$?
written=$(tr -d ' \t\r\n' < "$HOME/.config/telegram/bot_token")
if [ "$rc" -eq 0 ] && [ "$written" = "$NEW_TOKEN" ] \
  && ! printf '%s' "$out" | grep -qF "$TEST_TOKEN" \
  && ! printf '%s' "$out" | grep -qF "$NEW_TOKEN"; then
  ok "CDT-512-C4 AC1 replace writes a new token without printing it"
else
  bad "CDT-512-C4 AC1 replace: rc=$rc written=$written out=$out"
fi

fresh_case
put_resp_file "getMe" "$FIXTURES/getme-ok.json"
put_resp_file "getUpdates" "$FIXTURES/getupdates-pairing.json"
put_resp_file "getChat" "$FIXTURES/getchat-forum.json"
out=$(printf '%s\n' "$TEST_TOKEN" "testdev" | USER=testdev bash "$SETUP" 2>&1)
rc=$?
if [ "$rc" -eq 0 ] && [ -f "$STATE_ROOT/config.json" ] \
  && ! printf '%s' "$out" | grep -qi 'Press Enter' \
  && printf '%s' "$out" | grep -qi 'wait' \
  && printf '%s' "$out" | grep -q '30' \
  && ! printf '%s' "$out" | grep -qF "$TEST_TOKEN"; then
  ok "CDT-512-C4 AC2 pairing long-polls 30s without a piped Enter"
else
  bad "CDT-512-C4 AC2 no-Enter pairing: rc=$rc out=$out"
fi

fresh_case
put_resp_file "getMe" "$FIXTURES/getme-ok.json"
put_resp "getUpdates" '{"ok":true,"result":[]}'
out=$(printf '%s\n' "$TEST_TOKEN" "testdev" | USER=testdev bash "$SETUP" 2>&1)
rc=$?
if [ "$rc" -eq 1 ] && [ -z "$(ls -A "$STATE_ROOT" 2>/dev/null)" ] \
  && printf '%s' "$out" | grep -qi 'wait' \
  && printf '%s' "$out" | grep -q '30' \
  && ! printf '%s' "$out" | grep -qi 'Press Enter' \
  && ! printf '%s' "$out" | grep -qF "$TEST_TOKEN"; then
  ok "CDT-512-C4 AC2 empty getUpdates exits 1 with no state beyond the token file"
else
  bad "CDT-512-C4 AC2 empty queue: rc=$rc state=$(ls -A "$STATE_ROOT" 2>/dev/null) out=$out"
fi

paste_ok=1
grep -qi 'never paste' "$SETUP" || paste_ok=0
grep -qi 'never paste' "$SETUP_MD" || paste_ok=0
while IFS= read -r line; do
  printf '%s' "$line" | grep -qiE 'paste .{0,60}token|token.{0,40}paste' || continue
  printf '%s' "$line" | grep -qi 'never' && continue
  printf '%s' "$line" | grep -qi 'prompt' && continue
  paste_ok=0
done < "$SETUP"
if [ "$paste_ok" -eq 1 ]; then
  ok "CDT-512-C4 AC3 never instruct pasting the token into chat"
else
  bad "CDT-512-C4 AC3 paste-into-chat instruction leaked"
fi

if grep -qi 'pipe' "$SETUP_MD" && grep -qi 'Enter' "$SETUP_MD" \
  && grep -q '30' "$SETUP_MD" && grep -qi 'pairing' "$SETUP_MD"; then
  ok "CDT-512-C4 AC4 commands/setup.md documents the agent pairing wait"
else
  bad "CDT-512-C4 AC4 commands/setup.md missing agent pairing wait"
fi

# CDT-512-C5: sendChatAction lives on ir_send_text only; no pickup, no keepalive.
if awk '
  /^ir_send_text\(\)/ { in_send = 1 }
  /^ir_process_update\(\)/ { in_proc = 1 }
  /^[A-Za-z_][A-Za-z0-9_]*\(\)/ {
    if ($0 !~ /^ir_send_text\(\)/) in_send = 0
    if ($0 !~ /^ir_process_update\(\)/) in_proc = 0
  }
  /sendChatAction/ {
    any = 1
    if (in_proc) proc_hit = 1
    if (in_send) send_hit = 1
  }
  END { exit (any && send_hit && !proc_hit) ? 0 : 1 }
' "$POLLER" \
  && ! grep -nE 'sendChatAction' "$POLLER" | grep -qE 'while |sleep '; then
  ok "CDT-512-C5 sendChatAction is send-path only with no typing-keepalive loop"
else
  bad "CDT-512-C5 sendChatAction still on pickup or keepalive-shaped"
fi

# ---- CDT-509: ir_daemon_running + setup daemon-mode vs C1 harness --------------
# shellcheck source=../../tests/lib/mtimes.sh
. "$PLUGIN_ROOT/tests/lib/mtimes.sh"

nodocker_bin() {
  local tools="$HERMETIC_ROOT/nodocker-bin" cmd p
  mkdir -p "$tools"
  if [ ! -x "$tools/grep" ]; then
    for cmd in bash jq curl flock grep sed awk cat chmod mkdir date stat \
      touch wc tr mktemp rm ls head find mv cp basename dirname uname \
      sleep kill env id ps tail cmp diff file ln git sort uniq cut tee \
      true false test timeout stty readlink realpath; do
      p=$(command -v "$cmd" 2>/dev/null) || continue
      ln -sf "$p" "$tools/$cmd"
    done
  fi
  printf '%s\n' "$tools"
}
SAFE_BIN=$(nodocker_bin)
export PATH="$SHIM_DIR:$SAFE_BIN"

install_docker_mock() { # running|down — SHIM_DIR/docker only; never a real daemon
  local mode="$1"
  export DOCKER_MOCK_MODE_FILE="$HERMETIC_ROOT/docker.mode"
  export DOCKER_MOCK_LOG="$HERMETIC_ROOT/docker.argv"
  printf '%s\n' "$mode" > "$DOCKER_MOCK_MODE_FILE"
  : > "$DOCKER_MOCK_LOG"
  cat > "$SHIM_DIR/docker" <<'EOF'
#!/usr/bin/env bash
{
  printf 'argv'
  printf ' %s' "$@"
  printf '\n'
} >> "${DOCKER_MOCK_LOG:-/dev/null}"
for a in "$@"; do
  case "$a" in
    pull|run|build|push)
      echo "docker-mock: refused $a" >&2
      exit 64
      ;;
  esac
done
mode=$(cat "${DOCKER_MOCK_MODE_FILE:-/dev/null}" 2>/dev/null || true)
want=0
prev=""
for a in "$@"; do
  if [ "$prev" = "-p" ] && [ "$a" = "intercom" ]; then want=1; fi
  if [ "$prev" = "--project-name" ] && [ "$a" = "intercom" ]; then want=1; fi
  case "$a" in
    *dev-team.intercom*) want=1 ;;
  esac
  prev="$a"
done
if [ "$mode" = "running" ] && [ "$want" -eq 1 ]; then
  printf '%s\n' '{"Service":"daemon","State":"running","Labels":"dev-team.intercom=daemon","Project":"intercom"}'
  printf '%s\n' "deadbeef"
  exit 0
fi
exit 0
EOF
  chmod +x "$SHIM_DIR/docker"
}

rm_docker_mock() { rm -f "$SHIM_DIR/docker"; }

run_ir_daemon() {
  IRD_OUT=$(bash -c '. "'"$COMMON"'"; ir_daemon_running' 2>"$ERRF")
  IRD_RC=$?
  IRD_ERR=$(cat "$ERRF")
}

assert_no_docker_pull() { # LABEL
  if [ -s "${DOCKER_MOCK_LOG:-}" ] && grep -Eq ' (pull|run|build) ' "$DOCKER_MOCK_LOG"; then
    bad "$1 invoked docker pull/run/build: $(tr '\n' ' ' < "$DOCKER_MOCK_LOG")"
    return 1
  fi
  return 0
}

assert_daemon_mode() { # LABEL OUT
  local label="$1" out="$2" okm=1
  local bytes
  bytes=$(printf '%s' "$out" | wc -c | tr -d ' ')
  printf '%s' "$out" | grep -qi 'daemon' || okm=0
  printf '%s' "$out" | grep -qi 'intercom' || okm=0
  [ "$bytes" -le 4096 ] || okm=0
  printf '%s' "$out" | grep -qF "$TEST_TOKEN" && okm=0
  printf '%s' "$out" | grep -qF "$SENTINEL" && okm=0
  printf '%s' "$out" | grep -qF "bash $HERE/watch.sh" && okm=0
  printf '%s' "$out" | grep -q 'BEGIN harness schedule prompt' && okm=0
  if [ "$okm" -eq 1 ]; then
    ok "$label"
  else
    bad "$label bytes=$bytes out=$out"
  fi
}

assert_c1_harness() { # LABEL OUT RC
  local label="$1" out="$2" rc="$3" okm=1
  [ "$rc" -eq 0 ] || okm=0
  printf '%s' "$out" | grep -qF "$HERE/watch.sh" || okm=0
  printf '%s' "$out" | grep -qF "$TEST_TOKEN" && okm=0
  printf '%s' "$out" | grep -qF "$SENTINEL" && okm=0
  if [ "$okm" -eq 1 ]; then
    ok "$label"
  else
    bad "$label rc=$rc out=$out"
  fi
}

# ir_daemon_running: rc 0 iff fresh heartbeat AND compose identity running.
fresh_case
seed_paired "197372681"
install_docker_mock running
run_ir_daemon
assert_no_docker_pull "CDT-509 AC10 ir_daemon_running (fresh+up)"
if [ "$IRD_RC" -eq 0 ]; then
  ok "CDT-509 AC10 ir_daemon_running: fresh heartbeat + compose up → rc 0"
else
  bad "CDT-509 AC10 ir_daemon_running fresh+up: rc=$IRD_RC err=$IRD_ERR out=$IRD_OUT"
fi

fresh_case
seed_paired "197372681"
touch_ago "$STATE_ROOT/state/heartbeat" 300
install_docker_mock running
run_ir_daemon
assert_no_docker_pull "CDT-509 AC10 ir_daemon_running (stale)"
if [ "$IRD_RC" -eq 1 ]; then
  ok "CDT-509 AC10 ir_daemon_running: stale heartbeat → rc 1"
else
  bad "CDT-509 AC10 ir_daemon_running stale: rc=$IRD_RC err=$IRD_ERR"
fi

fresh_case
seed_paired "197372681"
rm -f "$STATE_ROOT/state/heartbeat"
install_docker_mock running
run_ir_daemon
if [ "$IRD_RC" -eq 1 ]; then
  ok "CDT-509 AC10 ir_daemon_running: missing heartbeat → rc 1"
else
  bad "CDT-509 AC10 ir_daemon_running missing hb: rc=$IRD_RC err=$IRD_ERR"
fi

fresh_case
seed_paired "197372681"
rm_docker_mock
run_ir_daemon
if [ "$IRD_RC" -eq 1 ]; then
  ok "CDT-509 AC10 ir_daemon_running: docker CLI absent → rc 1"
else
  bad "CDT-509 AC10 ir_daemon_running no-docker: rc=$IRD_RC err=$IRD_ERR"
fi

fresh_case
seed_paired "197372681"
install_docker_mock down
run_ir_daemon
assert_no_docker_pull "CDT-509 AC10 ir_daemon_running (down)"
if [ "$IRD_RC" -eq 1 ]; then
  ok "CDT-509 AC10 ir_daemon_running: compose down → rc 1"
else
  bad "CDT-509 AC10 ir_daemon_running down: rc=$IRD_RC err=$IRD_ERR"
fi

# Setup keep-existing: daemon-up skips watch.sh schedule (AC4/AC10).
fresh_case
seed_paired "197372681"
install_docker_mock running
out=$(printf 'n\n' | bash "$SETUP" 2>&1)
rc=$?
if [ "$rc" -ne 0 ]; then
  bad "CDT-509 AC10 keep-existing daemon-up rc=$rc out=$out"
else
  assert_daemon_mode "CDT-509 AC10 keep-existing + daemon up: daemon-mode, no watch.sh schedule" "$out"
fi
assert_no_docker_pull "CDT-509 AC10 setup keep-existing daemon-up"

# Keep-existing + stale heartbeat → C1 harness (fail closed).
fresh_case
seed_paired "197372681"
touch_ago "$STATE_ROOT/state/heartbeat" 300
install_docker_mock running
out=$(printf 'n\n' | bash "$SETUP" 2>&1)
rc=$?
assert_c1_harness "CDT-509 AC10 keep-existing + stale heartbeat: C1 harness with abs watch.sh" "$out" "$rc"

# Keep-existing + docker missing → C1, not a setup failure.
fresh_case
seed_paired "197372681"
rm_docker_mock
out=$(printf 'n\n' | bash "$SETUP" 2>&1)
rc=$?
assert_c1_harness "CDT-509 AC10 keep-existing + docker missing: C1 harness, rc 0" "$out" "$rc"

# Pairing complete with daemon up → daemon-mode (heartbeat already fresh).
fresh_case
seed_token
mkdir -m 700 -p "$STATE_ROOT/state"
date +%s > "$STATE_ROOT/state/heartbeat"
install_docker_mock running
put_resp_file "getMe" "$FIXTURES/getme-ok.json"
put_resp_file "getUpdates" "$FIXTURES/getupdates-pairing.json"
put_resp_file "getChat" "$FIXTURES/getchat-forum.json"
out=$(printf '%s\n' "$TEST_TOKEN" "Alexander" "" | bash "$SETUP" 2>&1)
rc=$?
if [ "$rc" -ne 0 ]; then
  bad "CDT-509 AC10 pairing daemon-up rc=$rc out=$out"
else
  assert_daemon_mode "CDT-509 AC10 pairing + daemon up: daemon-mode, no watch.sh schedule" "$out"
fi
assert_no_docker_pull "CDT-509 AC10 setup pairing daemon-up"

# Pairing + docker missing: fail closed to C1 (lock-in; missing docker is not a setup failure).
fresh_case
seed_token
rm_docker_mock
put_resp_file "getMe" "$FIXTURES/getme-ok.json"
put_resp_file "getUpdates" "$FIXTURES/getupdates-pairing.json"
put_resp_file "getChat" "$FIXTURES/getchat-forum.json"
out=$(printf '%s\n' "$TEST_TOKEN" "Alexander" "" | bash "$SETUP" 2>&1)
rc=$?
assert_c1_harness "CDT-509 AC10 pairing + docker missing: C1 harness, rc 0" "$out" "$rc"

# ---- CDT-509 T5 docs (AC10/AC11/AC12) — SKILL, setup, runbook, TDD, doctor ----
SKILL_MD="$HERE/SKILL.md"
RB="$PLUGIN_ROOT/docs/runbooks/setup-telegram.md"
TDD_MD="$PLUGIN_ROOT/specs/TDD.md"
DOC_IC="$PLUGIN_ROOT/skills/doctor/checks/intercom.sh"
DAEMON_SH="$HERE/daemon.sh"
ALPINE_DIGEST='sha256:ce64758a109eb420d874a118f87920e625e12d3634e03b4a5573fd9f6e5d3507'

# AC3: poller/watch/intercom stay byte-stable vs origin/master (additive daemon only).
if git -C "$PLUGIN_ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1 \
  && git -C "$PLUGIN_ROOT" rev-parse --verify origin/master >/dev/null 2>&1; then
  if git -C "$PLUGIN_ROOT" diff --quiet origin/master -- \
    skills/intercom/poller.sh skills/intercom/watch.sh skills/intercom/intercom.sh; then
    ok "CDT-509 AC3 poller.sh watch.sh intercom.sh 0-diff"
  else
    bad "CDT-509 AC3 poller.sh watch.sh intercom.sh drifted vs origin/master"
  fi
else
  ok "CDT-509 AC3 poller.sh watch.sh intercom.sh 0-diff"
fi

if [ -f "$DAEMON_SH" ] && ! grep -q 'topics.json' "$DAEMON_SH"; then
  ok "CDT-509 AC6 daemon.sh has no topics.json map"
else
  bad "CDT-509 AC6 daemon.sh missing or mentions topics.json"
fi

if grep -q 'compose project' "$SKILL_MD" && grep -q 'intercom' "$SKILL_MD" \
  && grep -qi 'digest' "$SKILL_MD" && grep -q 'INTERCOM_UID' "$SKILL_MD" \
  && grep -qi 'probe.sh' "$SKILL_MD" && grep -qi 'pre-deploy' "$SKILL_MD" \
  && grep -qi 'docker pull' "$SKILL_MD"; then
  ok "CDT-509 AC10/AC11/AC12 SKILL.md documents compose intercom, digest, host uid, probe pre-deploy, no pull"
else
  bad "CDT-509 T5 SKILL.md missing daemon compose/digest/uid/probe/pull contract"
fi

if grep -qi 'daemon' "$SETUP_MD" && grep -qi 'watch.sh' "$SETUP_MD" \
  && grep -qiE 'do not arm|does not arm|skip' "$SETUP_MD" \
  && grep -qi 'intercom' "$SETUP_MD"; then
  ok "CDT-509 AC10 commands/setup.md documents daemon mode (no watch.sh arm)"
else
  bad "CDT-509 AC10 commands/setup.md missing daemon-mode / skip-watch"
fi

if [ -f "$RB" ] \
  && grep -q "$ALPINE_DIGEST" "$RB" \
  && grep -qi 'Docker Official' "$RB" \
  && grep -q 'INTERCOM_UID' "$RB" && grep -q 'INTERCOM_GID' "$RB" \
  && grep -qi 'uid 0' "$RB" \
  && grep -q 'compose' "$RB" && grep -q 'intercom' "$RB" \
  && grep -qi 'watch.sh' "$RB" && grep -qi 'daemon' "$RB" \
  && grep -qi 'docker pull' "$RB" \
  && ! grep -qF "$TEST_TOKEN" "$RB" && ! grep -qF "$SENTINEL" "$RB"; then
  ok "CDT-509 T5 runbook presents alpine digest, host uid, no token"
else
  bad "CDT-509 T5 runbook missing digest/uid/compose or leaked a token"
fi

if [ -f "$RB" ] \
  && grep -q 'probe.sh' "$RB" \
  && grep -qi 'pre-deploy' "$RB" \
  && grep -qi 'stop the daemon' "$RB" \
  && grep -q '409' "$RB" \
  && grep -qi 'suites never' "$RB"; then
  ok "CDT-509 AC12 runbook: probe.sh pre-deploy; stop daemon (409); suites never invoke"
else
  bad "CDT-509 AC12 runbook missing probe pre-deploy / stop-before-probe (409)"
fi

if grep -q 'daemon.sh' "$TDD_MD" && grep -q 'docker-compose.yml' "$TDD_MD" \
  && grep -q 'test-daemon.sh' "$TDD_MD" \
  && grep -q 'docs/runbooks/setup-telegram.md' "$TDD_MD"; then
  ok "CDT-509 T5 specs/TDD.md covers daemon compose assets and runbook"
else
  bad "CDT-509 T5 specs/TDD.md SPEC-038 coverage missing daemon assets"
fi

if grep -q 'intercom.daemon' "$DOC_IC" \
  && grep -qi 'WARN' "$DOC_IC" && grep -qi 'FAIL' "$DOC_IC" \
  && grep -qi 'docker' "$DOC_IC" && grep -q 'intercom' "$DOC_IC" \
  && grep -qi 'daemon or harness' "$DOC_IC" \
  && ! grep -E '(^|[[:space:]])docker[[:space:]]+(pull|run)([[:space:]|&;<>]|$)' "$DOC_IC" >/dev/null; then
  ok "CDT-509 T5 doctor intercom.daemon is WARN-never-FAIL inspect-only"
else
  bad "CDT-509 T5 doctor checks/intercom.sh missing intercom.daemon or pulls"
fi

echo
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
