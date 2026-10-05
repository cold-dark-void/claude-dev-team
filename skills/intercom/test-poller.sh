#!/usr/bin/env bash
# test-poller.sh — hermetic poller-cycle suite for skills/intercom/poller.sh
# (SPEC-038). No network: curl is a PATH shim that records argv and answers
# from fixture JSON; INTERCOM_STATE_ROOT and HOME live under one mktemp root.
#
# Covers the AC subsets SPEC-038 routes here: AC12-AC16, AC18, AC19, AC22,
# plus the shared-cycle behaviors (inbound relay, dedupe, outbox drain and
# the c8 update-type allowlist). Token-sentinel and setup ACs live in
# test.sh. The poller hard-requires flock (AC22 single consumer), so the
# suite skips on systems without it.
set -u

HERE=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
PLUGIN_ROOT=$(CDPATH= cd -- "$HERE/../.." && pwd)

for _t in jq curl flock; do
  command -v "$_t" >/dev/null 2>&1 || {
    echo "SKIP: $_t missing — poller.sh requires bash/jq/curl/flock (SPEC-038 AC21/AC22)"
    exit 77
  }
done

# shellcheck source=../../tests/lib/hermetic.sh
. "$PLUGIN_ROOT/tests/lib/hermetic.sh"
# shellcheck source=../../tests/lib/mtimes.sh
. "$PLUGIN_ROOT/tests/lib/mtimes.sh"

POLLER="$HERE/poller.sh"
INTERCOM="$HERE/intercom.sh"
FIXTURES="$HERE/fixtures"
TEST_TOKEN="123456789:TEST-TOKEN-NOT-REAL"

PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); echo "PASS: $1"; }
bad() { FAIL=$((FAIL + 1)); echo "FAIL: $1" >&2; }

hermetic_init

# ---- hermetic curl shim + state root (shared scaffolding: test-lib.sh) ---------

# shellcheck source=test-lib.sh
. "$HERE/test-lib.sh"
hermetic_curl_shim

# ---- suite-local helpers (the shared ones live in test-lib.sh) ------------------

fresh_state() { rm -rf "$STATE_ROOT"; mkdir -m 700 -p "$STATE_ROOT"; }

fresh_case() {
  fresh_state
  rm -rf "$RESP_DIR"
  mkdir -p "$RESP_DIR"
  : > "$CALLS_LOG"
  : > "$ARGV_LOG"
}

ok_empty_result() { put_resp "getUpdates" '{"ok":true,"result":[]}'; }

# ---- AC22: a second concurrent start exits 75 and mutates nothing ---------------

seed_paired "197372681"
ok_empty_result
env CURL_DELAY=3 bash "$POLLER" > "$HERMETIC_ROOT/a.out" 2>&1 &
APA=$!
sleep 1
run_poller
if [ "$P_RC" -eq 75 ] && printf '%s' "$P_ERR" | grep -q "another poller holds the lock" \
  && [ "$(offset_val)" = "100" ]; then
  ok "AC22 second concurrent start exits 75 without state mutation"
else
  bad "AC22 double start: rc=$P_RC err=$P_ERR offset=$(offset_val)"
fi
wait "$APA"
ARC=$?
if [ "$ARC" -eq 0 ]; then
  ok "AC22 first poller completes its delayed cycle with exit 0"
else
  bad "AC22 first poller rc=$ARC out=$(cat "$HERMETIC_ROOT/a.out" 2>/dev/null)"
fi

# ---- AC22: junk offset refuses to fetch -----------------------------------------

fresh_case
seed_token
mkdir -m 700 -p "$STATE_ROOT/state"
printf 'abc\n' > "$STATE_ROOT/state/offset"
run_poller
if [ "$P_RC" -eq 2 ] && printf '%s' "$P_ERR" | grep -q "refusing to fetch" \
  && [ ! -s "$CALLS_LOG" ] && [ "$(offset_val)" = "abc" ]; then
  ok "AC22 non-numeric offset: exit 2, no fetch, no state advance"
else
  bad "AC22 junk offset: rc=$P_RC calls=[$(cat "$CALLS_LOG")]"
fi

fresh_case
seed_token
mkdir -m 700 -p "$STATE_ROOT/state"
printf -- '-5\n' > "$STATE_ROOT/state/offset"
run_poller
if [ "$P_RC" -eq 2 ] && [ ! -s "$CALLS_LOG" ]; then
  ok "AC22 negative offset refused"
else
  bad "AC22 negative offset: rc=$P_RC"
fi

fresh_case
seed_token
mkdir -m 700 -p "$STATE_ROOT/state"
run_poller
if [ "$P_RC" -eq 2 ] && [ ! -s "$CALLS_LOG" ]; then
  ok "AC22 missing offset refused before any fetch"
else
  bad "AC22 missing offset: rc=$P_RC"
fi

# ---- AC2/AC3: unpaired bot is a silent no-op -------------------------------------

fresh_case
seed_token
mkdir -m 700 -p "$STATE_ROOT/state"
printf '100\n' > "$STATE_ROOT/state/offset"
run_poller
if [ "$P_RC" -eq 0 ] && [ ! -d "$STATE_ROOT/spool" ] && [ ! -f "$STATE_ROOT/topics.json" ] \
  && [ ! -f "$STATE_ROOT/state/heartbeat" ] && [ ! -f "$STATE_ROOT/state/seen.tsv" ] \
  && [ "$(offset_val)" = "100" ] && [ ! -s "$CALLS_LOG" ]; then
  ok "AC2 unpaired cycle: zero spool/topic/heartbeat/seen artifacts, no fetch"
else
  bad "AC2 unpaired: rc=$P_RC spool=$([ -d "$STATE_ROOT/spool" ] && echo yes || echo no)"
fi

fresh_case
seed_token
printf '{"schema": 1, "members": {}}\n' > "$STATE_ROOT/config.json"
mkdir -m 700 -p "$STATE_ROOT/state"
printf '100\n' > "$STATE_ROOT/state/offset"
run_poller
if [ "$P_RC" -eq 0 ] && [ ! -d "$STATE_ROOT/spool" ]; then
  ok "AC2 empty-members config: silent no-op"
else
  bad "AC2 empty members: rc=$P_RC"
fi

# ---- allowlisted inbound: inbox record, offset, seen.tsv ---------------------------

seed_paired "197372681"
put_resp "getUpdates" "$(result_body "$(upd_msg 100 197372681 "hello there")")"
run_poller
inbox_rec=$(inbox_files main)
if [ "$P_RC" -eq 0 ] && [ "$(inbox_n main)" = "1" ] && [ -f "$inbox_rec" ] \
  && [ "$(jq -r '.sid' "$inbox_rec")" = "main" ] \
  && [ "$(jq -r '.dir' "$inbox_rec")" = "in" ] \
  && [ "$(jq -r '.kind' "$inbox_rec")" = "message" ] \
  && [ "$(jq -r '.text' "$inbox_rec")" = "hello there" ] \
  && [ "$(jq -r '.from_id' "$inbox_rec")" = "197372681" ] \
  && [ "$(jq -r '.update_id' "$inbox_rec")" = "100" ] \
  && [ "$(jq -r '.thread_id' "$inbox_rec")" = "0" ] \
  && [ "$(offset_val)" = "101" ] \
  && grep -q $'^100\t' "$STATE_ROOT/state/seen.tsv"; then
  ok "allowlisted message relays to the inbox with offset advanced and a seen.tsv row"
else
  bad "inbound relay: rc=$P_RC rec=[$inbox_rec] offset=$(offset_val)"
fi

# ---- AC13: backlog sent while down is relayed in one cycle ------------------------

seed_paired "197372681"
put_resp "getUpdates" "$(result_body \
  "$(upd_msg 100 197372681 "one")" \
  "$(upd_msg 101 197372681 "two")" \
  "$(upd_msg 102 197372681 "three")")"
run_poller
if [ "$P_RC" -eq 0 ] && [ "$(inbox_n main)" = "3" ] \
  && [ "$(offset_val)" = "103" ] && [ "$(seen_n)" = "3" ]; then
  ok "AC13 backlog of three updates relays in one cycle; offset lands past the last"
else
  bad "AC13 backlog: rc=$P_RC inbox=$(inbox_n main) offset=$(offset_val)"
fi

# ---- AC13: a replayed update_id is deduped ----------------------------------------

seed_paired "197372681"
printf '100\t%s\n' "$(date +%s)" > "$STATE_ROOT/state/seen.tsv"
put_resp "getUpdates" "$(result_body "$(upd_msg 100 197372681 "hello again")")"
run_poller
if [ "$P_RC" -eq 0 ] && [ "$(inbox_n main)" = "0" ] \
  && [ "$(offset_val)" = "101" ] && [ "$(seen_n)" = "1" ]; then
  ok "AC13 replayed update_id: no new record, offset still advances, seen window holds"
else
  bad "AC13 replay: rc=$P_RC inbox=$(inbox_n main) seen=$(seen_n)"
fi

# ---- AC22: getUpdates 409 exits 4 without advancing state -------------------------

seed_paired "197372681"
put_resp_file "getUpdates" "$FIXTURES/conflict-409.json"
run_poller
if [ "$P_RC" -eq 4 ] && [ "$(offset_val)" = "100" ] && [ "$(inbox_n main)" = "0" ] \
  && [ "$(seen_n)" = "0" ]; then
  ok "AC22 409 Conflict: exit 4, offset and seen.tsv untouched"
else
  bad "AC22 409: rc=$P_RC offset=$(offset_val)"
fi

# ---- SPEC-038 § Poller cycle 5: getUpdates network error exits 0, mutates nothing ----

seed_paired "197372681"
put_resp "getUpdates" '__CURL_FAIL__'
run_poller
if [ "$P_RC" -eq 0 ] && [ "$(offset_val)" = "100" ] && [ "$(seen_n)" = "0" ] \
  && [ "$(inbox_n main)" = "0" ] && [ ! -d "$STATE_ROOT/spool" ]; then
  ok "getUpdates curl failure (rc 7): exit 0; offset, seen.tsv and spool untouched"
else
  bad "network error: rc=$P_RC offset=$(offset_val) spool=$([ -d "$STATE_ROOT/spool" ] && echo yes || echo no)"
fi

# ---- 429: retry_after honored, exit 0 for reschedule -------------------------------

seed_paired "197372681"
put_resp_file "getUpdates" "$FIXTURES/ratelimited-429.json"
run_poller
hb_age=$(( $(date +%s) - $(stat -c %Y "$STATE_ROOT/state/heartbeat" 2>/dev/null || echo 0) ))
if [ "$P_RC" -eq 0 ] && printf '%s' "$P_ERR" | grep -q "retry_after=2" \
  && [ "$(offset_val)" = "100" ] && [ "$hb_age" -le 5 ]; then
  ok "429 response: retry_after honored in the log, exit 0, offset unchanged, heartbeat touched"
else
  bad "429: rc=$P_RC err=$P_ERR hb_age=$hb_age"
fi

# ---- c8 update-type allowlist: non-message types leave zero artifacts --------------

seed_paired "197372681"
put_resp "getUpdates" "$(result_body \
  "$(upd_edited 200 197372681)" \
  "$(upd_channel 201 197372681)" \
  "$(upd_callback 202)" \
  "$(upd_nochat 203)")"
run_poller
if [ "$P_RC" -eq 0 ] && [ ! -d "$STATE_ROOT/spool" ] \
  && [ "$(calls_count sendChatAction)" = "0" ] && [ "$(calls_count sendMessage)" = "0" ] \
  && [ "$(offset_val)" = "204" ] && [ "$(seen_n)" = "4" ]; then
  ok "c8 edited_message/channel_post/callback_query/no-chat: zero artifacts, offset consumed"
else
  bad "c8 types: rc=$P_RC spool=$([ -d "$STATE_ROOT/spool" ] && echo yes || echo no) offset=$(offset_val)"
fi

# ---- outbox drain: delete on 2xx, keep on failure, retry next cycle ----------------

seed_paired "197372681"
put_outbox "main" "drain me"
ok_empty_result
run_poller
if [ "$P_RC" -eq 0 ] && [ "$(calls_count sendMessage)" = "1" ] \
  && grep -Fq 'text=drain me' "$ARGV_LOG" \
  && [ "$(find "$STATE_ROOT/spool/main/outbox" -name '*.json' 2>/dev/null | wc -l | tr -d ' ')" = "0" ]; then
  ok "drain: 2xx send deletes the outbox record (at-least-once)"
else
  bad "drain 2xx: rc=$P_RC sends=$(calls_count sendMessage)"
fi

seed_paired "197372681"
put_outbox "main" "keep me"
put_resp "getUpdates" '{"ok":true,"result":[]}'
put_resp "sendMessage" '__CURL_FAIL__'
run_poller
if [ "$P_RC" -eq 0 ] && printf '%s' "$P_ERR" | grep -q "record kept" \
  && [ "$(find "$STATE_ROOT/spool/main/outbox" -name '*.json' 2>/dev/null | wc -l | tr -d ' ')" = "1" ]; then
  ok "drain: failed send keeps the record and the cycle still exits 0"
else
  bad "drain keep: rc=$P_RC err=$P_ERR"
fi
put_resp "sendMessage" '{"ok":true,"result":true}'
run_poller
if [ "$(find "$STATE_ROOT/spool/main/outbox" -name '*.json' 2>/dev/null | wc -l | tr -d ' ')" = "0" ]; then
  ok "drain: the kept record is delivered on the next cycle"
else
  bad "drain retry: record still present"
fi

# ---- delivery matrix: summary/sendDocument combinations -----------------------------

seed_paired "197372681"
printf 'attachment body\n' > "$HERMETIC_ROOT/att.md"
put_outbox "main" "long body text" "concise summary" "$HERMETIC_ROOT/att.md"
ok_empty_result
run_poller
if [ "$P_RC" -eq 0 ] && [ "$(calls_count sendMessage)" = "1" ] && [ "$(calls_count sendDocument)" = "1" ] \
  && grep -Fq 'text=concise summary' "$ARGV_LOG" \
  && grep -Fq "document=@$HERMETIC_ROOT/att.md" "$ARGV_LOG"; then
  ok "matrix: summary record sends one summary message plus the attached file"
else
  bad "matrix a: rc=$P_RC sends=$(calls_count sendMessage) docs=$(calls_count sendDocument)"
fi

seed_paired "197372681"
put_outbox "main" "long body without file" "summary only"
ok_empty_result
run_poller
doc_line=$(grep -F 'document=@' "$ARGV_LOG" | head -n 1)
if [ "$P_RC" -eq 0 ] && [ "$(calls_count sendDocument)" = "1" ] \
  && case "$doc_line" in *intercom-longread-*.md*) true ;; *) false ;; esac; then
  ok "matrix: summary without file materializes the text as a UTF-8 .md upload"
else
  bad "matrix b: rc=$P_RC doc=[$doc_line]"
fi

seed_paired "197372681"
printf 'attachment body\n' > "$HERMETIC_ROOT/att2.md"
put_outbox "main" "plain text body" "" "$HERMETIC_ROOT/att2.md"
ok_empty_result
run_poller
if [ "$P_RC" -eq 0 ] && [ "$(calls_count sendMessage)" = "1" ] && [ "$(calls_count sendDocument)" = "1" ] \
  && grep -Fq 'text=plain text body' "$ARGV_LOG" \
  && grep -Fq "document=@$HERMETIC_ROOT/att2.md" "$ARGV_LOG"; then
  ok "matrix: no-summary record sends the full text plus the file (never dropped)"
else
  bad "matrix c: rc=$P_RC sends=$(calls_count sendMessage) docs=$(calls_count sendDocument)"
fi

seed_paired "197372681"
put_outbox "main" "just a line"
ok_empty_result
run_poller
if [ "$P_RC" -eq 0 ] && [ "$(calls_count sendMessage)" = "1" ] && [ "$(calls_count sendDocument)" = "0" ] \
  && grep -Fq 'text=just a line' "$ARGV_LOG"; then
  ok "matrix: plain short record is one sendMessage with no document"
else
  bad "matrix d: rc=$P_RC sends=$(calls_count sendMessage) docs=$(calls_count sendDocument)"
fi

# ---- AC14/AC11: escalation fires once into the auto-created topic -------------------

seed_paired "197372681"
cfg_edit "$STATE_ROOT/config.json" '.escalation_timeout_s = 0'
put_pending "proj" "q_esc" "Which staging tag is live?" "$(( $(date +%s) - 10 ))"
ok_empty_result
put_resp_file "createForumTopic" "$FIXTURES/createforumtopic-ok.json"
run_poller
pend="$STATE_ROOT/spool/proj/pending/q_esc.json"
if [ "$P_RC" -eq 0 ] && [ "$(calls_count createForumTopic)" = "1" ] \
  && [ "$(calls_count sendMessage)" = "1" ] \
  && grep -Fq 'text=Which staging tag is live?' "$ARGV_LOG" \
  && grep -Fq 'message_thread_id=777' "$ARGV_LOG" \
  && [ "$(jq -r '.["proj"].thread_id' "$STATE_ROOT/topics.json")" = "777" ] \
  && [ "$(jq -r '.escalated' "$pend")" = "true" ] \
  && [ "$(jq -r '.escalated_at' "$pend")" -gt 0 ]; then
  ok "AC14/AC11 escalation: once, into the auto-created topic, flagged escalated"
else
  bad "AC14 fire: rc=$P_RC sends=$(calls_count sendMessage) topics=$(cat "$STATE_ROOT/topics.json" 2>/dev/null)"
fi
run_poller
if [ "$(calls_count createForumTopic)" = "0" ] && [ "$(calls_count sendMessage)" = "0" ]; then
  ok "AC14 escalated question never re-fires on the next cycle"
else
  bad "AC14 re-fire: sends=$(calls_count sendMessage) topics=$(calls_count createForumTopic)"
fi

# ---- AC14: a fresh pending question does not escalate before its timer --------------

seed_paired "197372681"
put_pending "main" "q_now" "fresh question" "$(date +%s)"
ok_empty_result
run_poller
if [ "$(calls_count sendMessage)" = "0" ] \
  && [ "$(jq -r '.escalated' "$STATE_ROOT/spool/main/pending/q_now.json")" = "false" ]; then
  ok "AC14 pending inside escalation_timeout_s is left alone"
else
  bad "AC14 not-due: sends=$(calls_count sendMessage)"
fi

# ---- AC19/AC20: away ON escalates immediately via the CLI-written flag --------------

seed_paired "197372681"
put_pending "main" "q_away" "urgent question" "$(date +%s)"
run_cli "$INTERCOM" away on
[ "$C_RC" -eq 0 ] || bad "away on via CLI failed: $C_ERR"
ok_empty_result
run_poller
if [ "$(calls_count sendMessage)" = "1" ] && grep -Fq 'text=urgent question' "$ARGV_LOG" \
  && [ "$(jq -r '.escalated' "$STATE_ROOT/spool/main/pending/q_away.json")" = "true" ] \
  && [ -f "$STATE_ROOT/state/away" ]; then
  ok "AC19/AC20 away ON (CLI flag) escalates a fresh pending question immediately and the flag survives"
else
  bad "AC19 away-immediate: sends=$(calls_count sendMessage) rc=$P_RC"
fi

# ---- AC15: an expiry missed while down fires on the next poll -----------------------

seed_paired "197372681"
put_pending "main" "q_old" "question from downtime" "$(( $(date +%s) - 7200 ))"
ok_empty_result
run_poller
if [ "$(calls_count sendMessage)" = "1" ] && grep -Fq 'text=question from downtime' "$ARGV_LOG" \
  && [ "$(jq -r '.escalated' "$STATE_ROOT/spool/main/pending/q_old.json")" = "true" ]; then
  ok "AC15 question expired during downtime escalates on the next poll"
else
  bad "AC15 catch-up: sends=$(calls_count sendMessage)"
fi

# ---- AC12: stale heartbeat queues the record and sends the offline notice -----------

seed_paired "197372681"
touch_ago "$STATE_ROOT/state/heartbeat" 600
put_resp "getUpdates" "$(result_body "$(upd_msg 100 197372681 "queued while offline" 100)")"
run_poller
if [ "$P_RC" -eq 0 ] && [ "$(inbox_n main)" = "1" ] \
  && grep -Fq 'text=offline, queued' "$ARGV_LOG" \
  && grep -Fq 'message_thread_id=100' "$ARGV_LOG"; then
  ok "AC12 stale heartbeat: record queued and an offline notice lands in the general topic"
else
  bad "AC12 offline notice: rc=$P_RC inbox=$(inbox_n main) err=$P_ERR"
fi

# ---- AC16: an answer cancels escalation and relays as kind answer -------------------

seed_paired "197372681"
put_pending "main" "q_a" "the question?" "$(( $(date +%s) - 100 ))" true
put_resp "getUpdates" "$(result_body "$(upd_msg 100 197372681 "the answer")")"
run_poller
ans_rec=$(inbox_files main)
if [ "$P_RC" -eq 0 ] && [ "$(inbox_n main)" = "1" ] \
  && [ "$(jq -r '.kind' "$ans_rec")" = "answer" ] \
  && [ "$(jq -r '.text' "$ans_rec")" = "the answer" ] \
  && [ -z "$(ls "$STATE_ROOT/spool/main/pending" 2>/dev/null)" ] \
  && [ -f "$STATE_ROOT/spool/main/answered/q_a.json" ]; then
  ok "AC16 answer relays with kind=answer; the pending question moves to answered/"
else
  bad "AC16 answer: rc=$P_RC kind=[$(jq -r '.kind' "$ans_rec" 2>/dev/null)]"
fi

# ---- AC17: reserved phone commands toggle the same away flag, relaying nothing ------

seed_paired "197372681"
put_resp "getUpdates" "$(result_body "$(upd_msg 100 197372681 "/away")")"
run_poller
if [ "$P_RC" -eq 0 ] && [ -f "$STATE_ROOT/state/away" ] \
  && grep -Fq 'text=away: on' "$ARGV_LOG" \
  && [ "$(inbox_n main)" = "0" ] && [ "$(offset_val)" = "101" ]; then
  ok "AC17 phone /away: flag written, confirmation sent, nothing relayed, offset advanced"
else
  bad "AC17 /away: rc=$P_RC away=$([ -f "$STATE_ROOT/state/away" ] && echo yes || echo no)"
fi
put_resp "getUpdates" "$(result_body "$(upd_msg 101 197372681 "/afk@mybot")")"
run_poller
if [ "$P_RC" -eq 0 ] && [ ! -f "$STATE_ROOT/state/away" ] \
  && grep -Fq 'text=away: off' "$ARGV_LOG" && [ "$(offset_val)" = "102" ]; then
  ok "AC17 phone /afk@bot clears the flag and confirms"
else
  bad "AC17 /afk@bot: rc=$P_RC"
fi

# ---- AC18: away ON keeps draining the outbox every cycle ----------------------------

seed_paired "197372681"
run_cli "$INTERCOM" away on
put_outbox "main" "away status update"
ok_empty_result
run_poller
if [ "$P_RC" -eq 0 ] && [ "$(calls_count sendMessage)" = "1" ] \
  && grep -Fq 'text=away status update' "$ARGV_LOG" \
  && [ "$(find "$STATE_ROOT/spool/main/outbox" -name '*.json' 2>/dev/null | wc -l | tr -d ' ')" = "0" ]; then
  ok "AC18 away ON: outbox drains proactively in the cycle"
else
  bad "AC18 away drain: rc=$P_RC sends=$(calls_count sendMessage)"
fi

echo
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
