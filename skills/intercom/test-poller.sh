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
WATCH="$HERE/watch.sh"
INTERCOM="$HERE/intercom.sh"
FIXTURES="$HERE/fixtures"
TEST_TOKEN="123456789:TEST-TOKEN-NOT-REAL"
SENTINEL="123456789:TEST-SENTINEL-TOKEN"

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
  && [ "$(calls_count sendChatAction)" = "1" ] \
  && typing_before_each_send \
  && grep -Fq 'text=drain me' "$ARGV_LOG" \
  && [ "$(find "$STATE_ROOT/spool/main/outbox" -name '*.json' 2>/dev/null | wc -l | tr -d ' ')" = "0" ]; then
  ok "drain: 2xx send deletes the outbox record (at-least-once); typing immediately before sendMessage"
else
  bad "drain 2xx: rc=$P_RC sends=$(calls_count sendMessage) action=$(calls_count sendChatAction)"
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

# ---- CDT-528: BusyBox mktemp — the materialize template must be suffix-free --------

install_busybox_mktemp() { # PATH stub mimicking BusyBox: a suffix after the X run is rejected
  BB_BIN="$HERMETIC_ROOT/busybox-bin"
  local real
  real=$(command -v mktemp)
  mkdir -p "$BB_BIN"
  cat > "$BB_BIN/mktemp" <<EOF
#!/usr/bin/env bash
# BusyBox-shaped mktemp: any argument carrying an X run with a suffix after it
# fails with "Invalid argument"; suffix-free templates delegate to real mktemp.
for a in "\$@"; do
  case "\$a" in
    *XXXXXX?*)
      printf 'mktemp: %s: Invalid argument\n' "\$a" >&2
      exit 1
      ;;
  esac
done
exec '$real' "\$@"
EOF
  chmod +x "$BB_BIN/mktemp"
}

seed_paired "197372681"
install_busybox_mktemp
put_outbox "main" "long body without file" "busybox summary"
ok_empty_result
PATH="$BB_BIN:$PATH"
run_poller
PATH="${PATH#"$BB_BIN:"}"
doc_line=$(grep -F 'document=@' "$ARGV_LOG" | head -n 1)
if [ "$P_RC" -eq 0 ] && [ "$(calls_count sendMessage)" = "1" ] \
  && [ "$(calls_count sendDocument)" = "1" ] \
  && case "$doc_line" in *document=@*intercom-longread-*/longread.md) true ;; *) false ;; esac \
  && [ "$(find "$STATE_ROOT/spool/main/outbox" -name '*.json' 2>/dev/null | wc -l | tr -d ' ')" = "0" ]; then
  ok "CDT-528: BusyBox mktemp stub — materialized longread.md uploads and the record is deleted"
else
  bad "CDT-528 materialize: rc=$P_RC doc=[$doc_line]"
fi

seed_paired "197372681"
install_busybox_mktemp
put_outbox "main" "long body without file" "busybox failing send"
ok_empty_result
put_resp "sendDocument" '__CURL_FAIL__'
PATH="$BB_BIN:$PATH"
run_poller
PATH="${PATH#"$BB_BIN:"}"
if [ "$P_RC" -eq 0 ] \
  && [ "$(find "$HERMETIC_ROOT/tmp" -maxdepth 1 -name 'intercom-longread-*' 2>/dev/null | wc -l | tr -d ' ')" = "0" ] \
  && [ "$(find "$STATE_ROOT/spool/main/outbox" -name '*.json' 2>/dev/null | wc -l | tr -d ' ')" = "1" ] \
  && printf '%s' "$P_ERR" | grep -q "record kept"; then
  ok "CDT-528: failing sendDocument removes the temp dir and keeps the record for retry"
else
  bad "CDT-528 fail path: rc=$P_RC err=$P_ERR"
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

# ---- CDT-530 AC3: a delivered summary is not re-sent on the retry cycle --------

seed_paired "197372681"
printf 'attachment body\n' > "$HERMETIC_ROOT/att530.md"
put_outbox "main" "long body text" "concise summary" "$HERMETIC_ROOT/att530.md"
ok_empty_result
put_resp "sendDocument" '__CURL_FAIL__'
ACC="$HERMETIC_ROOT/argv-530.log"
: > "$ACC"
run_poller
cat "$ARGV_LOG" >> "$ACC"
if [ "$(find "$STATE_ROOT/spool/main/outbox" -name '*.json' 2>/dev/null | wc -l | tr -d ' ')" = "1" ] \
  && [ "$(jq -r '.summary_sent // false' "$STATE_ROOT/spool/main/outbox"/*.json 2>/dev/null)" = "true" ]; then
  ok "CDT-530 AC3: failed sendDocument keeps the record with summary_sent marked"
else
  bad "CDT-530 AC3 mark: rec=$(jq -c . "$STATE_ROOT/spool/main/outbox"/*.json 2>/dev/null)"
fi
run_poller
cat "$ARGV_LOG" >> "$ACC"
put_resp "sendDocument" '{"ok":true,"result":true}'
run_poller
cat "$ARGV_LOG" >> "$ACC"
# The shim logs argv before failing, so each retry cycle contributes one
# sendDocument line: assert one attempt per cycle (3), not a re-send within one.
if [ "$P_RC" -eq 0 ] \
  && [ "$(grep -Fc 'text=concise summary' "$ACC")" = "1" ] \
  && [ "$(grep -Fc "document=@$HERMETIC_ROOT/att530.md" "$ACC")" = "3" ] \
  && [ "$(find "$STATE_ROOT/spool/main/outbox" -name '*.json' 2>/dev/null | wc -l | tr -d ' ')" = "0" ]; then
  ok "CDT-530 AC3: summary exactly once across three cycles, sendDocument once per cycle and delivered on the success cycle, record deleted"
else
  bad "CDT-530 AC3 retry: rc=$P_RC summary=$(grep -Fc 'text=concise summary' "$ACC") docs=$(grep -Fc "document=@$HERMETIC_ROOT/att530.md" "$ACC") recs=$(find "$STATE_ROOT/spool/main/outbox" -name '*.json' 2>/dev/null | wc -l | tr -d ' ')"
fi

# ---- CDT-530 AC4: the full-text part of a no-summary record is not re-sent -----

seed_paired "197372681"
printf 'attachment body\n' > "$HERMETIC_ROOT/att530b.md"
put_outbox "main" "plain text body" "" "$HERMETIC_ROOT/att530b.md"
ok_empty_result
put_resp "sendDocument" '__CURL_FAIL__'
ACC="$HERMETIC_ROOT/argv-530b.log"
: > "$ACC"
run_poller
cat "$ARGV_LOG" >> "$ACC"
if [ "$(find "$STATE_ROOT/spool/main/outbox" -name '*.json' 2>/dev/null | wc -l | tr -d ' ')" = "1" ] \
  && [ "$(jq -r '.text_sent // false' "$STATE_ROOT/spool/main/outbox"/*.json 2>/dev/null)" = "true" ]; then
  ok "CDT-530 AC4: failed sendDocument keeps the record with text_sent marked"
else
  bad "CDT-530 AC4 mark: rec=$(jq -c . "$STATE_ROOT/spool/main/outbox"/*.json 2>/dev/null)"
fi
run_poller
cat "$ARGV_LOG" >> "$ACC"
put_resp "sendDocument" '{"ok":true,"result":true}'
run_poller
cat "$ARGV_LOG" >> "$ACC"
if [ "$P_RC" -eq 0 ] \
  && [ "$(grep -Fc 'text=plain text body' "$ACC")" = "1" ] \
  && [ "$(grep -Fc "document=@$HERMETIC_ROOT/att530b.md" "$ARGV_LOG")" = "1" ] \
  && [ "$(find "$STATE_ROOT/spool/main/outbox" -name '*.json' 2>/dev/null | wc -l | tr -d ' ')" = "0" ]; then
  ok "CDT-530 AC4: full text exactly once across three cycles, record deleted after the file lands"
else
  bad "CDT-530 AC4 retry: rc=$P_RC text=$(grep -Fc 'text=plain text body' "$ACC") docs=$(grep -Fc 'document=@' "$ARGV_LOG") recs=$(find "$STATE_ROOT/spool/main/outbox" -name '*.json' 2>/dev/null | wc -l | tr -d ' ')"
fi

# ---- CDT-530 AC2: a failed flag rewrite keeps the record -----------------------
# An invalid-JSON record is dropped at the sid check, so force the rewrite to
# fail at publish time: read-only outbox makes the atomic mv fail after the
# summary sendMessage succeeded. The record must survive unmarked.

seed_paired "197372681"
put_resp "getUpdates" '{"ok":true,"result":[]}'
put_outbox "main" "long body text" "concise summary"
chmod 555 "$STATE_ROOT/spool/main/outbox"
run_poller
chmod 700 "$STATE_ROOT/spool/main/outbox"
if [ "$P_RC" -eq 0 ] \
  && [ -f "$STATE_ROOT/spool/main/outbox/900000000_0_test.json" ] \
  && [ "$(jq -r '.summary_sent // false' "$STATE_ROOT/spool/main/outbox/900000000_0_test.json" 2>/dev/null)" != "true" ]; then
  ok "CDT-530 AC2: failed flag rewrite keeps the record (unpublishable rewrite)"
else
  bad "CDT-530 AC2 failed-mark: rc=$P_RC rec=$(find "$STATE_ROOT/spool/main/outbox" -name '*.json' 2>/dev/null | wc -l | tr -d ' ')"
fi

# ---- CDT-530 compat: a flag-absent (old-shape) record drains unchanged ----------

seed_paired "197372681"
printf 'attachment body\n' > "$HERMETIC_ROOT/att530c.md"
mkdir -m 700 -p "$STATE_ROOT/spool/main/outbox"
jq -n --arg sid "main" --arg text "old record body" --arg summary "old summary" \
  --arg file "$HERMETIC_ROOT/att530c.md" --arg ts "$(date +%s)" \
  '{ts: ($ts|tonumber), sid: $sid, dir: "out", kind: "message", text: $text,
    from_id: 0, update_id: 0, thread_id: 0, summary: $summary, file: $file}' \
  > "$STATE_ROOT/spool/main/outbox/900000001_0_old.json"
ok_empty_result
run_poller
if [ "$P_RC" -eq 0 ] && [ "$(calls_count sendMessage)" = "1" ] && [ "$(calls_count sendDocument)" = "1" ] \
  && grep -Fq 'text=old summary' "$ARGV_LOG" \
  && grep -Fq "document=@$HERMETIC_ROOT/att530c.md" "$ARGV_LOG" \
  && [ "$(find "$STATE_ROOT/spool/main/outbox" -name '*.json' 2>/dev/null | wc -l | tr -d ' ')" = "0" ]; then
  ok "CDT-530 compat: flag-absent record sends both parts in one cycle and is deleted"
else
  bad "CDT-530 compat: rc=$P_RC sends=$(calls_count sendMessage) docs=$(calls_count sendDocument)"
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
ok "CDT-509 AC7 escalation sweep unchanged (AC14/15/16/19)"

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
ok "CDT-509 AC8 away is state/away (AC17/18/19)"

# ---- CDT-512-C1: host adapter watch.sh ------------------------------------------

plant_inbox() { # SID FROM_ID [TEXT] [STEM]
  mkdir -m 700 -p "$STATE_ROOT/spool/$1/inbox"
  jq -n --arg sid "$1" --argjson from "$2" --arg text "${3:-planted secret}" \
    '{ts: 0, sid: $sid, dir: "in", kind: "message", text: $text,
      from_id: $from, update_id: 0, thread_id: 0}' \
    > "$STATE_ROOT/spool/$1/inbox/${4:-900000000_0_plant}.json"
}

# paired idle: empty stdout, rc 0, heartbeat advances, offset unchanged, no poller stderr
seed_paired "197372681"
ok_empty_result
touch_ago "$STATE_ROOT/state/heartbeat" 5
hb_aged=$(stat -c %Y "$STATE_ROOT/state/heartbeat")
off_before=$(offset_val)
export CURL_STDERR_ECHO=1
run_watch
unset CURL_STDERR_ECHO
hb_after=$(stat -c %Y "$STATE_ROOT/state/heartbeat" 2>/dev/null || echo 0)
if [ "$W_RC" -eq 0 ] && [ -z "$W_OUT" ] \
  && [ "$hb_after" -gt "$hb_aged" ] && [ "$(offset_val)" = "$off_before" ] \
  && ! printf '%s' "$W_OUT" | grep -q 'poller:' \
  && ! printf '%s' "$W_OUT" | grep -q 'curl:' \
  && ! printf '%s' "$W_OUT" | grep -q '\[scrubbed\]'; then
  ok "CDT-512-C1 AC2 paired idle: empty stdout, rc 0, heartbeat advances, offset unchanged, no poller stderr"
else
  bad "CDT-512-C1 idle: rc=$W_RC out=[$W_OUT] hb $hb_aged->$hb_after off=$(offset_val)"
fi

# unpaired: rc 0, no heartbeat, no fetch, empty stdout
fresh_case
seed_token
mkdir -m 700 -p "$STATE_ROOT/state"
printf '100\n' > "$STATE_ROOT/state/offset"
run_watch
if [ "$W_RC" -eq 0 ] && [ -z "$W_OUT" ] && [ ! -f "$STATE_ROOT/state/heartbeat" ] \
  && [ ! -s "$CALLS_LOG" ]; then
  ok "CDT-512-C1 AC2 unpaired: rc 0, empty stdout, no heartbeat, no fetch"
else
  bad "CDT-512-C1 unpaired: rc=$W_RC out=[$W_OUT] calls=[$(cat "$CALLS_LOG")]"
fi

# inbound one sid: exact grammar, no message text
seed_paired "197372681"
put_resp "getUpdates" "$(result_body "$(upd_msg 100 197372681 "hello there secret")")"
run_watch
want="intercom: inbound sid=main path=$STATE_ROOT/spool/main/inbox"
if [ "$W_RC" -eq 0 ] && [ "$W_OUT" = "$want" ] \
  && ! printf '%s' "$W_OUT" | grep -q 'hello there secret'; then
  ok "CDT-512-C1 AC3 inbound one sid: exact wake grammar, no message text"
else
  bad "CDT-512-C1 inbound one: rc=$W_RC out=[$W_OUT] want=[$want]"
fi

# CDT-529 supersedes the old mapped-always rule: sess-a/sess-b are mapped but
# inactive (no unanswered pending), so both updates fall back to default_session.
seed_paired "197372681"
cfg_edit "$STATE_ROOT/topics.json" '.["sess-a"] = {thread_id: 201, title: "sess-a"} | .["sess-b"] = {thread_id: 202, title: "sess-b"}'
put_resp "getUpdates" "$(result_body \
  "$(upd_msg 300 197372681 "for a secret" 201)" \
  "$(upd_msg 301 197372681 "for b secret" 202)")"
run_watch
want="intercom: inbound sid=main path=$STATE_ROOT/spool/main/inbox"
if [ "$W_RC" -eq 0 ] && [ "$W_OUT" = "$want" ] \
  && [ "$(inbox_n main)" = "2" ] \
  && [ "$(inbox_n sess-a)" = "0" ] && [ "$(inbox_n sess-b)" = "0" ] \
  && ! printf '%s' "$W_OUT" | grep -q 'secret'; then
  ok "CDT-512-C1 (CDT-529 AC5/AC3) inbound two sids: inactive mapped topics fall back to default_session, no body dump"
else
  bad "CDT-512-C1 inbound two: rc=$W_RC out=[$W_OUT] want=[$want]"
fi

# pre-existing inbox does not wake (stamp created first)
seed_paired "197372681"
plant_inbox "main" 197372681 "pre-existing body"
ok_empty_result
run_watch
if [ "$W_RC" -eq 0 ] && [ -z "$W_OUT" ]; then
  ok "CDT-512-C1 AC3 pre-existing inbox: no wake on first stamp"
else
  bad "CDT-512-C1 pre-existing: rc=$W_RC out=[$W_OUT]"
fi

# silent: phone /away
seed_paired "197372681"
put_resp "getUpdates" "$(result_body "$(upd_msg 100 197372681 "/away")")"
run_watch
if [ "$W_RC" -eq 0 ] && [ -z "$W_OUT" ]; then
  ok "CDT-512-C1 AC3 silent phone /away"
else
  bad "CDT-512-C1 /away: rc=$W_RC out=[$W_OUT]"
fi

# silent: phone /afk
seed_paired "197372681"
put_resp "getUpdates" "$(result_body "$(upd_msg 100 197372681 "/afk")")"
run_watch
if [ "$W_RC" -eq 0 ] && [ -z "$W_OUT" ]; then
  ok "CDT-512-C1 AC3 silent phone /afk"
else
  bad "CDT-512-C1 /afk: rc=$W_RC out=[$W_OUT]"
fi

# silent: outbox drain only
seed_paired "197372681"
put_outbox "main" "drain me"
ok_empty_result
run_watch
if [ "$W_RC" -eq 0 ] && [ -z "$W_OUT" ]; then
  ok "CDT-512-C1 AC3 silent outbox drain"
else
  bad "CDT-512-C1 drain: rc=$W_RC out=[$W_OUT]"
fi

# silent: escalation sweep
seed_paired "197372681"
put_pending "main" "q_esc" "expired question" "$(( $(date +%s) - 3600 ))"
ok_empty_result
run_watch
if [ "$W_RC" -eq 0 ] && [ -z "$W_OUT" ]; then
  ok "CDT-512-C1 AC3 silent escalation sweep"
else
  bad "CDT-512-C1 escalation: rc=$W_RC out=[$W_OUT]"
fi

# silent: ignored update types
seed_paired "197372681"
put_resp "getUpdates" "$(result_body \
  "$(upd_edited 200 197372681)" \
  "$(upd_channel 201 197372681)" \
  "$(upd_callback 202)" \
  "$(upd_nochat 203)")"
run_watch
if [ "$W_RC" -eq 0 ] && [ -z "$W_OUT" ]; then
  ok "CDT-512-C1 AC3 silent ignored update types"
else
  bad "CDT-512-C1 ignored types: rc=$W_RC out=[$W_OUT]"
fi

# silent: 429 exit 0
seed_paired "197372681"
put_resp_file "getUpdates" "$FIXTURES/ratelimited-429.json"
run_watch
if [ "$W_RC" -eq 0 ] && [ -z "$W_OUT" ]; then
  ok "CDT-512-C1 AC3 silent 429 (poller exit 0)"
else
  bad "CDT-512-C1 429: rc=$W_RC out=[$W_OUT]"
fi

# silent: getUpdates transport fail exit 0
seed_paired "197372681"
put_resp "getUpdates" '__CURL_FAIL__'
run_watch
if [ "$W_RC" -eq 0 ] && [ -z "$W_OUT" ]; then
  ok "CDT-512-C1 AC3 silent getUpdates transport fail"
else
  bad "CDT-512-C1 transport: rc=$W_RC out=[$W_OUT]"
fi

# silent: lock-held 75
seed_paired "197372681"
ok_empty_result
env CURL_DELAY=3 bash "$POLLER" > "$HERMETIC_ROOT/wlock.out" 2>&1 &
WLP=$!
sleep 1
run_watch
if [ "$W_RC" -eq 0 ] && [ -z "$W_OUT" ]; then
  ok "CDT-512-C1 AC3 silent lock-held 75"
else
  bad "CDT-512-C1 lock-75: rc=$W_RC out=[$W_OUT]"
fi
wait "$WLP" || true

# failure latch: first 4 wakes, identical 4 silent, 0 clears, 4 wakes again, 2 vs 4 wakes
seed_paired "197372681"
put_resp_file "getUpdates" "$FIXTURES/conflict-409.json"
run_watch
if [ "$W_RC" -eq 0 ] && [ "$W_OUT" = "intercom: poller exit 4" ] \
  && [ "$(tr -d ' \t\r\n' < "$STATE_ROOT/state/last_wake_exit")" = "4" ]; then
  ok "CDT-512-C1 AC4 first poller exit 4 wakes"
else
  bad "CDT-512-C1 first 4: rc=$W_RC out=[$W_OUT] latch=$(cat "$STATE_ROOT/state/last_wake_exit" 2>/dev/null)"
fi
run_watch
if [ "$W_RC" -eq 0 ] && [ -z "$W_OUT" ]; then
  ok "CDT-512-C1 AC4 identical exit 4 stays silent"
else
  bad "CDT-512-C1 second 4: rc=$W_RC out=[$W_OUT]"
fi
ok_empty_result
run_watch
if [ "$W_RC" -eq 0 ] && [ -z "$W_OUT" ] && [ ! -f "$STATE_ROOT/state/last_wake_exit" ]; then
  ok "CDT-512-C1 AC4 exit 0 clears the failure latch"
else
  bad "CDT-512-C1 clear latch: rc=$W_RC out=[$W_OUT] latch=$([ -f "$STATE_ROOT/state/last_wake_exit" ] && echo yes || echo no)"
fi
put_resp_file "getUpdates" "$FIXTURES/conflict-409.json"
run_watch
if [ "$W_RC" -eq 0 ] && [ "$W_OUT" = "intercom: poller exit 4" ]; then
  ok "CDT-512-C1 AC4 exit 4 wakes again after a 0 cycle"
else
  bad "CDT-512-C1 4 after 0: rc=$W_RC out=[$W_OUT]"
fi
printf 'abc\n' > "$STATE_ROOT/state/offset"
run_watch
if [ "$W_RC" -eq 0 ] && [ "$W_OUT" = "intercom: poller exit 2" ]; then
  ok "CDT-512-C1 AC4 different exit 2 vs 4 wakes"
else
  bad "CDT-512-C1 2 vs 4: rc=$W_RC out=[$W_OUT]"
fi

# inbound every new-inbox cycle even when failure latch is silent; combined inbound then failure
seed_paired "197372681"
ok_empty_result
run_watch
plant_inbox "main" 197372681 "combined secret" "900000001_0_plant"
put_resp_file "getUpdates" "$FIXTURES/conflict-409.json"
run_watch
want_in="intercom: inbound sid=main path=$STATE_ROOT/spool/main/inbox"
want_both="$want_in
intercom: poller exit 4"
if [ "$W_RC" -eq 0 ] && [ "$W_OUT" = "$want_both" ] \
  && ! printf '%s' "$W_OUT" | grep -q 'combined secret'; then
  ok "CDT-512-C1 AC4 combined: inbound then failure"
else
  bad "CDT-512-C1 combined: rc=$W_RC out=[$W_OUT] want=[$want_both]"
fi
plant_inbox "main" 197372681 "again secret" "900000002_0_plant"
put_resp_file "getUpdates" "$FIXTURES/conflict-409.json"
run_watch
if [ "$W_RC" -eq 0 ] && [ "$W_OUT" = "$want_in" ]; then
  ok "CDT-512-C1 AC4 inbound still prints every new-inbox cycle (failure latch silent)"
else
  bad "CDT-512-C1 inbound-while-latched: rc=$W_RC out=[$W_OUT]"
fi

# sentinel absent from W_OUT
seed_paired "197372681"
seed_token "$SENTINEL"
ok_empty_result
export CURL_STDERR_ECHO=1
run_watch
unset CURL_STDERR_ECHO
if [ "$W_RC" -eq 0 ] && ! printf '%s' "$W_OUT" | grep -qF "$SENTINEL" \
  && ! printf '%s' "$W_ERR" | grep -qF "$SENTINEL" \
  && ! grep -qF "$SENTINEL" "$ARGV_LOG" 2>/dev/null; then
  ok "CDT-512-C1 AC6 sentinel absent from adapter stdout/stderr/argv"
else
  bad "CDT-512-C1 adapter sentinel: rc=$W_RC out=[$W_OUT]"
fi

# CDT-512-C3 AC5: bot-id-only cycle must not wake the adapter
fresh_case
seed_paired "197372681"
put_resp_file "getMe" "$FIXTURES/getme-ok.json"
put_resp "getUpdates" "$(result_body "$(upd_msg_from 300 197372681 "self echo" 987654321)")"
run_watch
if [ "$W_RC" -eq 0 ] && [ -z "$W_OUT" ] && [ "$(inbox_n main)" = "0" ]; then
  ok "CDT-512-C3 AC5 watch stdout empty when cycle consumed only bot-id updates"
else
  bad "CDT-512-C3 AC5 watch bot-id: rc=$W_RC out=[$W_OUT] inbox=$(inbox_n main)"
fi

# ---- CDT-529: inbound routing resolution order (AC1/AC2/AC3/AC5) ----------------

# AC1: mapped thread + active sid routes to that sid's inbox (record shape unchanged)
seed_paired "197372681"
cfg_edit "$STATE_ROOT/topics.json" '.["sess-a"] = {thread_id: 201, title: "sess-a"}'
put_pending "sess-a" "q_a1" "is the staging tag live?" "$(date +%s)"
put_resp "getUpdates" "$(result_body "$(upd_msg 300 197372681 "here you go" 201)")"
run_poller
if [ "$P_RC" -eq 0 ] && [ "$(inbox_n sess-a)" = "1" ] && [ "$(inbox_n main)" = "0" ] \
  && [ "$(jq -r '.update_id' "$(inbox_files sess-a)")" = "300" ] \
  && [ "$(jq -r '.thread_id' "$(inbox_files sess-a)")" = "201" ] \
  && [ -f "$STATE_ROOT/spool/sess-a/answered/q_a1.json" ]; then
  ok "CDT-529 AC1 mapped thread + active sid routes to that sid's inbox"
else
  bad "CDT-529 AC1: rc=$P_RC a=$(inbox_n sess-a) main=$(inbox_n main) err=$P_ERR"
fi

# AC2: unmapped thread + exactly one active session routes there (no warn, no topic)
seed_paired "197372681"
put_pending "solo" "q_s1" "orchestrating" "$(date +%s)"
put_resp "getUpdates" "$(result_body "$(upd_msg 300 197372681 "stray reply" 999)")"
run_poller
if [ "$P_RC" -eq 0 ] && [ "$(inbox_n solo)" = "1" ] && [ "$(inbox_n main)" = "0" ] \
  && [ "$(jq -r '.text' "$(inbox_files solo)")" = "stray reply" ] \
  && [ "$(offset_val)" = "301" ] \
  && [ "$(calls_count createForumTopic)" = "0" ] \
  && ! printf '%s' "$P_ERR" | grep -q "unmapped"; then
  ok "CDT-529 AC2 unmapped thread + exactly one active session routes to that sid"
else
  bad "CDT-529 AC2: rc=$P_RC solo=$(inbox_n solo) main=$(inbox_n main) err=$P_ERR"
fi

# AC3 zero active: default_session inbox + exactly one warn line naming the thread id
seed_paired "197372681"
put_resp "getUpdates" "$(result_body "$(upd_msg 300 197372681 "no target" 999)")"
run_poller
warn_lines=$(printf '%s\n' "$P_ERR" | grep -c '^poller: thread 999 ' || true)
if [ "$P_RC" -eq 0 ] && [ "$(inbox_n main)" = "1" ] && [ "$warn_lines" -eq 1 ] \
  && [ "$(jq -r '.text' "$(inbox_files main)")" = "no target" ] \
  && [ "$(offset_val)" = "301" ] \
  && [ "$(calls_count createForumTopic)" = "0" ]; then
  ok "CDT-529 AC3 zero active: default_session + exactly one warn naming thread 999"
else
  bad "CDT-529 AC3 zero: rc=$P_RC main=$(inbox_n main) warns=$warn_lines err=$P_ERR"
fi

# AC3 two active: default_session + one warn; no cross-delivery, pending untouched
seed_paired "197372681"
cfg_edit "$STATE_ROOT/topics.json" '.["sess-a"] = {thread_id: 201, title: "sess-a"} | .["sess-b"] = {thread_id: 202, title: "sess-b"}'
put_pending "sess-a" "q_a2" "a active" "$(date +%s)"
put_pending "sess-b" "q_b2" "b active" "$(date +%s)"
put_resp "getUpdates" "$(result_body "$(upd_msg 300 197372681 "two active" 999)")"
run_poller
warn_lines=$(printf '%s\n' "$P_ERR" | grep -c '^poller: thread 999 ' || true)
if [ "$P_RC" -eq 0 ] && [ "$(inbox_n main)" = "1" ] && [ "$warn_lines" -eq 1 ] \
  && [ "$(inbox_n sess-a)" = "0" ] && [ "$(inbox_n sess-b)" = "0" ] \
  && [ "$(find "$STATE_ROOT/spool/sess-a/pending" -name '*.json' 2>/dev/null | wc -l | tr -d ' ')" = "1" ] \
  && [ "$(find "$STATE_ROOT/spool/sess-b/pending" -name '*.json' 2>/dev/null | wc -l | tr -d ' ')" = "1" ] \
  && [ "$(offset_val)" = "301" ]; then
  ok "CDT-529 AC3 two active: default_session + one warn; no cross-delivery, pending untouched"
else
  bad "CDT-529 AC3 two: rc=$P_RC main=$(inbox_n main) warns=$warn_lines err=$P_ERR"
fi

# AC5 zero active: a mapped-but-inactive sid falls back per AC3 (default + warn)
seed_paired "197372681"
cfg_edit "$STATE_ROOT/topics.json" '.["sess-a"] = {thread_id: 201, title: "sess-a"}'
put_resp "getUpdates" "$(result_body "$(upd_msg 300 197372681 "to a stale topic" 201)")"
run_poller
warn_lines=$(printf '%s\n' "$P_ERR" | grep -c '^poller: thread 201 ' || true)
if [ "$P_RC" -eq 0 ] && [ "$(inbox_n main)" = "1" ] && [ "$warn_lines" -eq 1 ] \
  && [ "$(inbox_n sess-a)" = "0" ]; then
  ok "CDT-529 AC5 mapped-but-inactive sid: default_session + one warn, never silent"
else
  bad "CDT-529 AC5 inactive: rc=$P_RC main=$(inbox_n main) warns=$warn_lines err=$P_ERR"
fi

# AC5 + AC2: an inactive mapped thread follows the single active session (no warn)
seed_paired "197372681"
cfg_edit "$STATE_ROOT/topics.json" '.["sess-a"] = {thread_id: 201, title: "sess-a"}'
put_pending "other" "q_o2" "other active" "$(date +%s)"
put_resp "getUpdates" "$(result_body "$(upd_msg 300 197372681 "to a stale topic" 201)")"
run_poller
if [ "$P_RC" -eq 0 ] && [ "$(inbox_n other)" = "1" ] && [ "$(inbox_n main)" = "0" ] \
  && [ "$(inbox_n sess-a)" = "0" ] \
  && ! printf '%s' "$P_ERR" | grep -q "unmapped"; then
  ok "CDT-529 AC5 inactive mapped thread follows the single active session"
else
  bad "CDT-529 AC5 active-fallback: rc=$P_RC other=$(inbox_n other) main=$(inbox_n main) err=$P_ERR"
fi

# ---- CDT-529: AC7 legacy topics.json, Q3 correlation miss, AC8 failure path ------

# AC7: a legacy map holding only {sid: {thread_id, title}} routes unchanged and
# the cycle never migrates/rewrites the file.
seed_paired "197372681"
printf '{"general": {"thread_id": 100, "title": "General"}, "legacy": {"thread_id": 205, "title": "legacy"}}\n' > "$STATE_ROOT/topics.json"
topics_before=$(cat "$STATE_ROOT/topics.json")
put_pending "legacy" "q_l1" "legacy active" "$(date +%s)"
put_resp "getUpdates" "$(result_body "$(upd_msg 300 197372681 "legacy routing" 205)")"
run_poller
if [ "$P_RC" -eq 0 ] && [ "$(inbox_n legacy)" = "1" ] \
  && [ "$(jq -r '.text' "$(inbox_files legacy)")" = "legacy routing" ] \
  && [ "$(cat "$STATE_ROOT/topics.json")" = "$topics_before" ]; then
  ok "CDT-529 AC7 legacy topics.json routes unchanged; no migration rewrite"
else
  bad "CDT-529 AC7 legacy: rc=$P_RC legacy=$(inbox_n legacy) err=$P_ERR"
fi

# Q3: plain chat + a NON-default sid holding pending -> one correlation-miss warn
seed_paired "197372681"
put_pending "sess-x" "q_x1" "x active" "$(date +%s)"
put_resp "getUpdates" "$(result_body "$(upd_msg 300 197372681 "plain talk")")"
run_poller
warn_lines=$(printf '%s\n' "$P_ERR" | grep -c 'correlation miss' || true)
if [ "$P_RC" -eq 0 ] && [ "$(inbox_n main)" = "1" ] && [ "$warn_lines" -eq 1 ] \
  && printf '%s' "$P_ERR" | grep -q 'session sess-x has an unanswered question'; then
  ok "CDT-529 Q3 plain chat + non-default pending: one correlation-miss warn naming sess-x"
else
  bad "CDT-529 Q3 miss: rc=$P_RC main=$(inbox_n main) warns=$warn_lines err=$P_ERR"
fi

# Q3: plain chat with only the default sid active -> no correlation-miss warn
seed_paired "197372681"
put_pending "main" "q_m1" "main active" "$(date +%s)"
put_resp "getUpdates" "$(result_body "$(upd_msg 300 197372681 "plain again")")"
run_poller
if [ "$P_RC" -eq 0 ] && [ "$(inbox_n main)" = "1" ] \
  && ! printf '%s' "$P_ERR" | grep -q 'correlation miss'; then
  ok "CDT-529 Q3 plain chat + only-default pending: no correlation-miss warn"
else
  bad "CDT-529 Q3 default-pending: rc=$P_RC main=$(inbox_n main) err=$P_ERR"
fi

# AC8: createForumTopic failure path unchanged — same warn, plain-chat delivery,
# escalation completes once, route.thread_id is not back-filled.
seed_paired "197372681"
put_pending "fresh-sid" "q_f1" "need an answer" "$(( $(date +%s) - 3600 ))"
ok_empty_result
put_resp_file "createForumTopic" "$FIXTURES/rejected-400.json"
run_poller
if [ "$P_RC" -eq 0 ] && [ "$(calls_count createForumTopic)" = "1" ] \
  && printf '%s' "$P_ERR" | grep -q 'createForumTopic rejected' \
  && [ "$(calls_count sendMessage)" = "1" ] \
  && grep -Fq 'text=need an answer' "$ARGV_LOG" \
  && ! grep -Fq 'message_thread_id=' "$ARGV_LOG" \
  && [ "$(jq -r '.escalated' "$STATE_ROOT/spool/fresh-sid/pending/q_f1.json")" = "true" ] \
  && [ "$(jq -r '.route.thread_id // "absent"' "$STATE_ROOT/spool/fresh-sid/pending/q_f1.json")" = "absent" ]; then
  ok "CDT-529 AC8 createForumTopic failure: warn unchanged, plain-chat send, escalated once, no back-fill"
else
  bad "CDT-529 AC8 failure path: rc=$P_RC sends=$(calls_count sendMessage) err=$P_ERR"
fi

# ---- CDT-531: createForumTopic name= guard + per-sid rejection cache -------------

# AC1/AC7: the auto-create sends the Bot API `name` parameter (never `title`),
# records topics.json, and delivers into the created thread.
seed_paired "197372681"
put_outbox "fresh-sid" "notify fresh"
ok_empty_result
put_resp_file "createForumTopic" "$FIXTURES/createforumtopic-ok.json"
run_poller
if [ "$P_RC" -eq 0 ] && [ "$(calls_count createForumTopic)" = "1" ] \
  && grep -Fq 'name=fresh-sid' "$ARGV_LOG" \
  && ! grep -Fq 'title=fresh-sid' "$ARGV_LOG" \
  && [ "$(jq -r '.["fresh-sid"].thread_id' "$STATE_ROOT/topics.json")" = "777" ] \
  && grep -Fq 'message_thread_id=777' "$ARGV_LOG"; then
  ok "CDT-531 AC1/AC7 auto-create sends name=fresh-sid and records topics.json"
else
  bad "CDT-531 AC1/AC7 name param: rc=$P_RC topics=$(cat "$STATE_ROOT/topics.json" 2>/dev/null) argv=$(grep createForumTopic "$ARGV_LOG" | tr '\n' ' ')"
fi

# AC3/AC7: a 400 rejection is cached per sid (one sid<TAB>epoch line, 0600):
# the rejecting cycle emits exactly one createForumTopic call plus the warn and
# degrades to plain chat; the next cycle emits zero createForumTopic calls,
# still delivers plain chat, and does not repeat the warn.
seed_paired "197372681"
put_outbox "cache-sid" "first try"
put_resp_file "createForumTopic" "$FIXTURES/rejected-400.json"
run_poller
rej="$STATE_ROOT/state/topic-reject.tsv"
if [ "$P_RC" -eq 0 ] && [ "$(calls_count createForumTopic)" = "1" ] \
  && printf '%s' "$P_ERR" | grep -q 'createForumTopic rejected' \
  && [ "$(calls_count sendMessage)" = "1" ] \
  && ! grep -Fq 'message_thread_id=' "$ARGV_LOG" \
  && [ "$(wc -l < "$rej" 2>/dev/null | tr -d ' ')" = "1" ] \
  && [ "$(stat -c %a "$rej" 2>/dev/null || stat -f %Lp "$rej")" = "600" ] \
  && [ "$(cut -f1 "$rej")" = "cache-sid" ] \
  && [ "$(cut -f2 "$rej" | grep -Eq '^[0-9]+$' && echo yes)" = "yes" ]; then
  ok "CDT-531 AC3 first 400 rejection: one call, warn once, cached sid<TAB>epoch 0600, plain chat"
else
  bad "CDT-531 AC3 first rejection: rc=$P_RC calls=$(calls_count createForumTopic) rej=[$(cat "$rej" 2>/dev/null)] mode=$(stat -c %a "$rej" 2>/dev/null) err=$P_ERR"
fi
put_outbox "cache-sid" "second try"
run_poller
if [ "$P_RC" -eq 0 ] && [ "$(calls_count createForumTopic)" = "0" ] \
  && [ "$(calls_count sendMessage)" = "1" ] \
  && ! printf '%s' "$P_ERR" | grep -q 'createForumTopic rejected' \
  && grep -Fq 'text=second try' "$ARGV_LOG" \
  && ! grep -Fq 'message_thread_id=' "$ARGV_LOG"; then
  ok "CDT-531 AC3 cached sid: zero create calls, no re-warn, plain-chat delivery"
else
  bad "CDT-531 AC3 cached cycle: rc=$P_RC calls=$(calls_count createForumTopic) sends=$(calls_count sendMessage) err=$P_ERR"
fi

# AC4: mapping hit short-circuits before the cache is consulted.
jq '.["cache-sid"] = {thread_id: 305, title: "cache-sid"}' \
  "$STATE_ROOT/topics.json" > "$STATE_ROOT/topics.json.tmp" \
  && mv -f "$STATE_ROOT/topics.json.tmp" "$STATE_ROOT/topics.json"
put_outbox "cache-sid" "mapped now"
run_poller
if [ "$P_RC" -eq 0 ] && [ "$(calls_count createForumTopic)" = "0" ] \
  && grep -Fq 'message_thread_id=305' "$ARGV_LOG"; then
  ok "CDT-531 AC4 topics.json hit short-circuits ahead of the rejection cache"
else
  bad "CDT-531 AC4 mapping hit: rc=$P_RC calls=$(calls_count createForumTopic) argv=$(grep sendMessage "$ARGV_LOG" | tr '\n' ' ')"
fi

# AC4: a cached entry past the TTL is dropped and the create is retried.
seed_paired "197372681"
mkdir -m 700 -p "$STATE_ROOT/state"
printf 'stale-sid\t%s\n' "$(( $(date +%s) - 90000 ))" > "$STATE_ROOT/state/topic-reject.tsv"
chmod 600 "$STATE_ROOT/state/topic-reject.tsv"
put_outbox "stale-sid" "retry after ttl"
put_resp_file "createForumTopic" "$FIXTURES/createforumtopic-ok.json"
run_poller
if [ "$P_RC" -eq 0 ] && [ "$(calls_count createForumTopic)" = "1" ] \
  && grep -Fq 'name=stale-sid' "$ARGV_LOG" \
  && [ "$(jq -r '.["stale-sid"].thread_id' "$STATE_ROOT/topics.json")" = "777" ]; then
  ok "CDT-531 AC4 expired rejection entry retried and re-recorded"
else
  bad "CDT-531 AC4 TTL retry: rc=$P_RC calls=$(calls_count createForumTopic) topics=$(cat "$STATE_ROOT/topics.json" 2>/dev/null)"
fi

# AC4: 429 is never cached (rate limits stay retry-worthy).
seed_paired "197372681"
put_outbox "rate-sid" "rate limited"
put_resp_file "createForumTopic" "$FIXTURES/ratelimited-429.json"
run_poller
if [ "$P_RC" -eq 0 ] && [ "$(calls_count createForumTopic)" = "1" ] \
  && [ ! -e "$STATE_ROOT/state/topic-reject.tsv" ]; then
  ok "CDT-531 AC4 429 rejection is not cached"
else
  bad "CDT-531 AC4 429: rc=$P_RC calls=$(calls_count createForumTopic) rej=[$(cat "$STATE_ROOT/state/topic-reject.tsv" 2>/dev/null)]"
fi

# AC4: a 5xx rejection is never cached.
seed_paired "197372681"
put_outbox "five-sid" "server error"
put_resp "createForumTopic" '{"ok":false,"error_code":502,"description":"Bad Gateway"}'
run_poller
if [ "$P_RC" -eq 0 ] && [ "$(calls_count createForumTopic)" = "1" ] \
  && [ ! -e "$STATE_ROOT/state/topic-reject.tsv" ]; then
  ok "CDT-531 AC4 5xx rejection is not cached"
else
  bad "CDT-531 AC4 5xx: rc=$P_RC calls=$(calls_count createForumTopic) rej=[$(cat "$STATE_ROOT/state/topic-reject.tsv" 2>/dev/null)]"
fi

# AC4: a transport failure (curl exit 7) is never cached and keeps the record.
seed_paired "197372681"
put_outbox "dead-sid" "transport down"
printf '__CURL_FAIL__\n' > "$RESP_DIR/createForumTopic"
run_poller
if [ "$P_RC" -eq 0 ] && printf '%s' "$P_ERR" | grep -q 'cannot reach Telegram for outbox' \
  && [ -f "$STATE_ROOT/spool/dead-sid/outbox/900000000_0_test.json" ] \
  && [ ! -e "$STATE_ROOT/state/topic-reject.tsv" ]; then
  ok "CDT-531 AC4 transport failure is not cached and the record is kept"
else
  bad "CDT-531 AC4 transport: rc=$P_RC rej=[$(cat "$STATE_ROOT/state/topic-reject.tsv" 2>/dev/null)] err=$P_ERR"
fi
rm -f "$RESP_DIR/createForumTopic"

# ---- CDT-529: AC4 escalation back-fill + AC10 outbound contract ------------------

# AC4: the sweep back-fills route.thread_id in the same rewrite that sets escalated
seed_paired "197372681"
put_pending "main" "q_rt" "back-fill me" "$(( $(date +%s) - 3600 ))"
jq '.route = {sid: "main", thread_id: null}' \
  "$STATE_ROOT/spool/main/pending/q_rt.json" > "$STATE_ROOT/spool/main/pending/q_rt.tmp" \
  && mv -f "$STATE_ROOT/spool/main/pending/q_rt.tmp" "$STATE_ROOT/spool/main/pending/q_rt.json"
ok_empty_result
run_poller
pend="$STATE_ROOT/spool/main/pending/q_rt.json"
if [ "$P_RC" -eq 0 ] && [ "$(calls_count sendMessage)" = "1" ] \
  && grep -Fq 'message_thread_id=100' "$ARGV_LOG" \
  && [ "$(jq -r '.escalated' "$pend")" = "true" ] \
  && [ "$(jq -r '.route.sid' "$pend")" = "main" ] \
  && [ "$(jq -r '.route.thread_id' "$pend")" = "100" ]; then
  ok "CDT-529 AC4 escalation back-fills route.thread_id in the escalated rewrite"
else
  bad "CDT-529 AC4 back-fill: rc=$P_RC route=$(jq -c '.route' "$pend" 2>/dev/null) err=$P_ERR"
fi

# AC10: ir_resolve_outbound contract unchanged — a mapped sid's outbox still
# delivers into its mapped topic (auto-create and general fallback are covered
# by the AC11/AC8 outbound tests in test.sh).
seed_paired "197372681"
cfg_edit "$STATE_ROOT/topics.json" '.["sess-a"] = {thread_id: 201, title: "sess-a"}'
put_outbox "sess-a" "out to a"
ok_empty_result
run_poller
if [ "$P_RC" -eq 0 ] && [ "$(calls_count createForumTopic)" = "0" ] \
  && [ "$(calls_count sendMessage)" = "1" ] \
  && grep -Fq 'text=out to a' "$ARGV_LOG" \
  && grep -Fq 'message_thread_id=201' "$ARGV_LOG" \
  && [ "$(find "$STATE_ROOT/spool/sess-a/outbox" -name '*.json' 2>/dev/null | wc -l | tr -d ' ')" = "0" ]; then
  ok "CDT-529 AC10 ir_resolve_outbound unchanged: mapped sid outbox delivers into its topic"
else
  bad "CDT-529 AC10 outbound: rc=$P_RC sends=$(calls_count sendMessage) err=$P_ERR"
fi

echo
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
