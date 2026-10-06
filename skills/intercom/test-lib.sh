#!/usr/bin/env bash
# test-lib.sh — shared hermetic scaffolding for the intercom suites (SPEC-038).
# Source-only: test.sh and test-poller.sh source it after tests/lib/hermetic.sh.
# It owns the no-network curl shim and the state/fixture/spool helpers both
# suites use. Suite-specific setup (EMPTY_BIN, TRANSCRIPT_MIRROR_ROOT,
# run_cli_env, ok_empty_result, the fixtures/ dir) and the test bodies stay in
# the suites. The suites define TEST_TOKEN, fresh_case, and fresh_state before
# the helpers that reference them are called.

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  echo "test-lib.sh is a source-only library, not a suite — source it from skills/intercom/test.sh or test-poller.sh." >&2
  exit 77
fi

hermetic_curl_shim() { # install the no-network curl shim on PATH; sets SHIM_DIR, STATE_ROOT,
                       # RESP_DIR, CALLS_LOG, ARGV_LOG, ERRF (test.sh adds EMPTY_BIN + transcript mirror)
  SHIM_DIR="$HERMETIC_ROOT/shim"
  STATE_ROOT="$HERMETIC_ROOT/intercom-state"
  RESP_DIR="$HERMETIC_ROOT/resp"
  CALLS_LOG="$HERMETIC_ROOT/calls.log"
  ARGV_LOG="$HERMETIC_ROOT/argv.log"
  ERRF="$HERMETIC_ROOT/last.err"
  mkdir -p "$SHIM_DIR" "$STATE_ROOT" "$RESP_DIR"
  export INTERCOM_STATE_ROOT="$STATE_ROOT"
  unset INTERCOM_SID CLAUDE_SESSION_ID
  cat > "$SHIM_DIR/curl" <<'EOF'
#!/usr/bin/env bash
# Hermetic curl: no network. Consumes the -K - stdin config, records argv and
# the request method, and answers from $CURL_RESPONSES/<method>. A response
# body of __CURL_FAIL__ makes the shim exit 7 (curl transport failure).
for a in "$@"; do
  printf 'argv: %s\n' "$a" >> "$CURL_ARGV_LOG"
done
cfg=$(cat)
via=none
tok=""
method=""
while IFS= read -r line; do
  case "$line" in
    url*api.telegram.org/bot*)
      via=stdin-config
      rest=${line#*api.telegram.org/bot}
      rest=${rest%\"}
      tok=${rest%%/*}
      method=${rest#*/}
      ;;
  esac
done <<< "$cfg"
key=${method%%\?*}
printf '%s %s\n' "$key" "$via" >> "$CURL_CALLS_LOG"
if [ -n "$tok" ] && [ -n "${CURL_STDERR_ECHO:-}" ]; then
  printf 'curl: (7) simulated connect failure for https://api.telegram.org/bot%s/%s\n' "$tok" "$key" >&2
fi
if [ -n "${CURL_DELAY:-}" ] && [ "$key" = "getUpdates" ]; then
  sleep "$CURL_DELAY"
fi
for cand in "$CURL_RESPONSES/$method" "$CURL_RESPONSES/$key" "$CURL_RESPONSES/default"; do
  if [ -f "$cand" ]; then
    body=$(cat "$cand")
    if [ "$body" = "__CURL_FAIL__" ]; then
      exit 7
    fi
    printf '%s\n' "$body"
    exit 0
  fi
done
[ -n "${CURL_DEFAULT:-}" ] || CURL_DEFAULT='{"ok":true,"result":true}'
printf '%s\n' "$CURL_DEFAULT"
EOF
  chmod +x "$SHIM_DIR/curl"
  export PATH="$SHIM_DIR:$PATH"
  export CURL_CALLS_LOG="$CALLS_LOG" CURL_ARGV_LOG="$ARGV_LOG" CURL_RESPONSES="$RESP_DIR"
}

# ---- shared helpers ------------------------------------------------------------

seed_token() { # [TOKEN] — token file 0600 under the hermetic HOME
  mkdir -m 700 -p "$HOME/.config/telegram"
  printf '%s\n' "${1:-$TEST_TOKEN}" > "$HOME/.config/telegram/bot_token"
  chmod 600 "$HOME/.config/telegram/bot_token"
}

base_config() { # CHAT_ID — schema-1 config with one member
  jq -n --arg c "$1" '{schema: 1, transport: "telegram",
    members: {($c): {name: "Alexander", role: "owner"}},
    default_session: "main", concise_threshold: 1024,
    escalation_timeout_s: 900, stale_heartbeat_s: 180, poll_timeout_s: 1}'
}

cfg_edit() { # FILE FILTER — edit a config fixture in place
  jq "$2" "$1" > "$1.tmp" || { rm -f "$1.tmp"; return 1; }
  mv -f "$1.tmp" "$1"
}

seed_paired() { # CHAT_ID — paired state: config, offset 100, fresh heartbeat
  fresh_case
  base_config "$1" > "$STATE_ROOT/config.json"
  mkdir -m 700 -p "$STATE_ROOT/state"
  printf '100\n' > "$STATE_ROOT/state/offset"
  : > "$STATE_ROOT/state/seen.tsv"
  date +%s > "$STATE_ROOT/state/heartbeat"
  chmod 600 "$STATE_ROOT/state/offset" "$STATE_ROOT/state/seen.tsv" "$STATE_ROOT/state/heartbeat"
  printf '{"general": {"thread_id": 100, "title": "General"}}\n' > "$STATE_ROOT/topics.json"
  seed_token
}

put_resp() { # METHOD BODY — response the shim returns for that method
  printf '%s\n' "$2" > "$RESP_DIR/$1"
}

put_resp_file() { cp "$2" "$RESP_DIR/$1"; }

upd_msg() { # ID CHAT TEXT [THREAD] — one Telegram message update
  jq -n --argjson id "$1" --argjson chat "$2" --arg text "$3" --argjson thread "${4:-0}" '
    if $thread == 0 then
      {update_id: $id, message: {message_id: $id,
        from: {id: $chat, is_bot: false, first_name: "Member"},
        chat: {id: $chat, type: "supergroup"}, date: 1700000000, text: $text}}
    else
      {update_id: $id, message: {message_id: $id,
        from: {id: $chat, is_bot: false, first_name: "Member"},
        chat: {id: $chat, type: "supergroup"}, date: 1700000000, text: $text,
        message_thread_id: $thread}}
    end'
}

upd_edited()   { jq -n --argjson id "$1" --argjson chat "$2" '{update_id: $id, edited_message: {message_id: 9, chat: {id: $chat}, edit_date: 1700000000}}'; }
upd_channel()  { jq -n --argjson id "$1" --argjson chat "$2" '{update_id: $id, channel_post: {message_id: 9, chat: {id: $chat}, text: "posted"}}'; }
upd_callback() { jq -n --argjson id "$1" '{update_id: $id, callback_query: {id: "cb", from: {id: 1}, data: "x"}}'; }
upd_nochat()   { jq -n --argjson id "$1" '{update_id: $id, message: {message_id: 9, text: "no chat object"}}'; }

result_body() { # UPDATE_JSON... — getUpdates response body
  local list="" u sep=""
  for u in "$@"; do
    list="$list$sep$u"
    sep=","
  done
  jq -n --argjson r "[$list]" '{ok: true, result: $r}'
}

put_pending() { # SID QID TEXT ASKED_AT [ESCALATED]
  mkdir -m 700 -p "$STATE_ROOT/spool/$1/pending"
  jq -n --arg qid "$2" --arg sid "$1" --arg text "$3" --argjson asked "$4" --argjson esc "${5:-false}" \
    '{qid: $qid, sid: $sid, text: $text, asked_at: $asked, escalated: $esc, escalated_at: null}' \
    > "$STATE_ROOT/spool/$1/pending/$2.json"
}

put_outbox() { # SID TEXT [SUMMARY] [FILE]
  mkdir -m 700 -p "$STATE_ROOT/spool/$1/outbox"
  jq -n --arg sid "$1" --arg text "$2" --arg summary "${3:-}" --arg file "${4:-}" --arg ts "$(date +%s)" \
    '{ts: ($ts|tonumber), sid: $sid, dir: "out", kind: "message", text: $text,
      from_id: 0, update_id: 0, thread_id: 0}
     + (if $summary == "" then {} else {summary: $summary} end)
     + (if $file == "" then {} else {file: $file} end)' \
    > "$STATE_ROOT/spool/$1/outbox/900000000_0_test.json"
}

run_poller() { # one poller cycle; sets P_OUT P_ERR P_RC
  : > "$CALLS_LOG"
  : > "$ARGV_LOG"
  P_OUT=$(bash "$POLLER" 2>"$ERRF")
  P_RC=$?
  P_ERR=$(cat "$ERRF")
}

run_cli() { # SCRIPT ARG... — sets C_OUT C_ERR C_RC
  C_OUT=$(bash "$@" 2>"$ERRF")
  C_RC=$?
  C_ERR=$(cat "$ERRF")
}

calls_count() { grep -c "^$1 " "$CALLS_LOG" 2>/dev/null || true; }

inbox_files() { find "$STATE_ROOT/spool/$1/inbox" -name '*.json' 2>/dev/null; }
inbox_n() { inbox_files "$1" | wc -l | tr -d ' '; }
seen_n() { wc -l < "$STATE_ROOT/state/seen.tsv" 2>/dev/null | tr -d ' '; }
offset_val() { cat "$STATE_ROOT/state/offset" 2>/dev/null; }
