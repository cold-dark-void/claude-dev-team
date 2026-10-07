#!/usr/bin/env bash
# test.sh — hermetic suite for the intercom skill (SPEC-038). No network:
# curl is a PATH shim that records argv, consumes the -K - stdin config, and
# answers from fixture JSON (tests/lib/hermetic.sh conventions; fixture JSON
# under fixtures/ uses sentinel-style fake tokens only).
#
# Covers the AC subsets SPEC-038 routes here: AC1, AC2, AC3, AC4, AC5, AC6,
# AC7, AC8, AC9, AC10, AC11, AC17 (CLI side), AC20, AC21, AC23, AC25.
# Poller-cycle ACs (AC12-AC16, AC18, AC19, AC22) live in test-poller.sh.
# State is hermetic: INTERCOM_STATE_ROOT and HOME live under one mktemp root
# and the repo working tree must stay untouched (AC23).
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

# ---- AC21: bash/jq/curl only; graceful absence ---------------------------------

shebang_ok=1
for f in "$HERE"/*.sh; do
  [ "$(head -n 1 "$f")" = "#!/usr/bin/env bash" ] || { shebang_ok=0; bad "AC21 shebang not env bash: $f"; }
done
[ "$shebang_ok" -eq 1 ] && ok "AC21 every skills/intercom/*.sh starts with #!/usr/bin/env bash"

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
  && [ -f "$STATE_ROOT/topics.json" ] && [ -f "$STATE_ROOT/state/seen.tsv" ] \
  && case "$(offset_val)" in ''|*[!0-9]*) false ;; *) true ;; esac \
  && ! printf '%s' "$out" | grep -qF "$TEST_TOKEN"; then
  ok "AC1 pairing completes: one-member config, topics/seen/offset written, harness prompt token-free"
else
  bad "AC1 pairing completion: rc=$rc out=$out"
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

# ---- AC6/AC7/AC10: thread-mapped delivery, no cross-delivery, typing once ---------

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
if [ "$(calls_count sendChatAction)" = "4" ]; then
  ok "AC10 sendChatAction typing sent once per inbound pickup"
else
  bad "AC10 sendChatAction count: $(calls_count sendChatAction)"
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

echo
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
