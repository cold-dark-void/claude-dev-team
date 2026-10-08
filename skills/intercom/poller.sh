#!/usr/bin/env bash
# poller.sh — single-consumer Telegram↔spool bridge (SPEC-038). One cycle per
# invocation; a scheduler calls it every 30–60 s. Never sourced, never a
# daemon: no resident loop, no crontab.
#
# Cycle: flock (75 if held) → validate state/offset (exit 2 if invalid, fetch
# nothing) → stale-heartbeat detection → drain spool/*/outbox → getUpdates
# long-poll (409 → exit 4; 429 → sleep retry_after, exit 0) → process updates
# ascending update_id with seen.tsv dedupe → escalation sweep → offset/seen
# advance + prune.
#
# Update-type allowlist (c8-council-finding fix): ONLY the `message` type is
# processed, and only from allowlisted chat ids (config.json members keys).
# `edited_message`, `channel_post`, and `callback_query` are explicitly
# ignored with zero artifacts — as is every other type (an update lacking a
# chat object never relays). Phase 1 produces no inline keyboards, so there
# is nothing a callback_query could safely do; the client-side filter is
# deliberate and is not a catch-all relayer.
#
# Exit codes: 0 success (also 429 reschedule, unpaired no-op, and getUpdates
# transport failure — SPEC-038 § Poller cycle), 2 invalid/missing offset, 4
# getUpdates 409 Conflict, 75 lock held by another consumer.
#
# Token hygiene (AC4): the token travels only through tg_api's curl `-K -`
# stdin config; it never appears in argv, logs, spool files, or error text.
set -u

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=common.sh
. "$SCRIPT_DIR/common.sh"

if [ "${BASH_SOURCE[0]}" != "$0" ]; then
  echo "poller.sh is a subprocess CLI (SPEC-038); source common.sh for the library." >&2
  return 1
fi

ir_require_tools jq curl flock || exit 1

# ---- cycle state --------------------------------------------------------------

STATE_DIR=$(ir_state_dir) || exit 1
ROOT=$(ir_state_root)
OFFSET_FILE="$STATE_DIR/offset"
HEARTBEAT_FILE="$STATE_DIR/heartbeat"
SEEN_FILE="$STATE_DIR/seen.tsv"
AWAY_FILE="$STATE_DIR/away"
TOPICS_FILE="$ROOT/topics.json"
CONFIG_FILE="$ROOT/config.json"

# seen.tsv dedupe window (AC13): update_id set, loaded from seen.tsv. bash-3
# port of `declare -A` (CDT-285): every value is the constant 1, so the keys
# live in a space-padded string; membership is an exact *" id "* glob (ids
# are numeric, so a key cannot carry glob metacharacters).
SEEN=" "
CUR_OFFSET=0        # monotonic next-offset (only advances upward)
WAS_STALE=0
OWNER_CHAT=""    # phase 1: the single allowlisted member chat id
DEFAULT_SESSION=""
DEFAULT_SESSION_OK=0

warn() { printf 'poller: %s\n' "$*" >&2; }

die() { warn "$*"; exit 1; }

# ir_set_has SET KEY — rc 0 when space-padded SET contains KEY exactly.
ir_set_has() {
  case "$1" in
    *" $2 "*) return 0 ;;
  esac
  return 1
}

# ir_set_count SET — print the number of keys in space-padded SET.
ir_set_count() {
  set -- $1
  printf '%s\n' "$#"
}

# ---- step 1: single consumer (AC22) --------------------------------------------

exec 9>"$STATE_DIR/poller.lock" || die "cannot open $STATE_DIR/poller.lock"
if ! flock -n 9; then
  warn "another poller holds the lock — exiting"
  exit 75
fi

# ---- step 2: offset validation (fail-closed; fetch nothing) ---------------------

offset_raw=$(cat "$OFFSET_FILE" 2>/dev/null) || offset_raw=""
case "$offset_raw" in
  ''|*[!0-9]*)
    echo "poller: $OFFSET_FILE is missing or not a non-negative integer — refusing to fetch. Run /setup telegram (pairing writes the initial offset) or write the integer max(update_id)+1 into it." >&2
    exit 2
    ;;
esac
CUR_OFFSET=$offset_raw

# ---- config: allowlist + defaults (unpaired → silent no-op, AC2/AC3) -----------

load_config() {
  local k
  if [ ! -f "$CONFIG_FILE" ]; then
    return 1
  fi
  while IFS= read -r k || [ -n "$k" ]; do
    [ -n "$k" ] || continue
    case "$k" in
      *[!0-9]*)
        warn "config.json member key is not numeric and is ignored (fail-closed): $k"
        ;;
      *) SEEN_ALLOW="$SEEN_ALLOW$k " ;;
    esac
  done < <(jq -r '(.members // {}) | keys[]' "$CONFIG_FILE" 2>/dev/null)
  return 0
}

SEEN_ALLOW=" "
if ! load_config || [ "$(ir_set_count "$SEEN_ALLOW")" -eq 0 ]; then
  # Unpaired: no allowlisted chat exists, so nothing may be relayed and no
  # artifact (spool, topic, heartbeat) may be created. Offset stays untouched.
  exit 0
fi
# Deterministic outbound target: phase 1 pins exactly one member; later members
# are tolerated in shape (AC25) but outbound delivery needs one owner chat.
OWNER_CHAT=$(printf '%s\n' $SEEN_ALLOW | sort -n | head -n 1)
[ "$(ir_set_count "$SEEN_ALLOW")" -gt 1 ] && warn "multiple members present; outbound uses the lowest chat id (phase 1 pins one)"

DEFAULT_SESSION=$(ir_config_field default_session "main")
if ir_sane_sid "$DEFAULT_SESSION"; then
  DEFAULT_SESSION_OK=1
else
  warn "config default_session is not a usable sid; unroutable traffic is ignored"
fi

# Bot self-echo uses the member chat id, so the allowlist cannot catch it.
# One getMe per cycle; miss → empty BOT_ID (do not drop member traffic).
BOT_ID=""
if me=$(tg_api getMe --max-time 15) \
  && jq -e '.ok == true' <<<"$me" >/dev/null 2>&1; then
  BOT_ID=$(jq -r '.result.id // empty' <<<"$me" 2>/dev/null) || BOT_ID=""
fi
case "$BOT_ID" in
  ''|*[!0-9]*) BOT_ID="" ;;
esac

# ---- staleness (AC12) + heartbeat touch ----------------------------------------

stale_heartbeat_s=$(ir_config_field stale_heartbeat_s 180)
case "$stale_heartbeat_s" in ''|*[!0-9]*) stale_heartbeat_s=180 ;; esac

hb_age=""
if [ -f "$HEARTBEAT_FILE" ]; then
  hb_mtime=$(stat -c %Y "$HEARTBEAT_FILE" 2>/dev/null || stat -f %m "$HEARTBEAT_FILE" 2>/dev/null) || hb_mtime=""
  case "$hb_mtime" in
    ''|*[!0-9]*) hb_age="" ;;
    *) hb_age=$(( $(date +%s) - hb_mtime )) ;;
  esac
fi
case "$hb_age" in
  ''|*[!0-9]*) WAS_STALE=0 ;;
  *) [ "$hb_age" -gt "$stale_heartbeat_s" ] && WAS_STALE=1 ;;
esac

ir_touch_heartbeat() {
  atomic_write "$HEARTBEAT_FILE" date +%s \
    || warn "cannot touch $HEARTBEAT_FILE (staleness detection degrades)"
}
ir_touch_heartbeat

# ---- outbound plumbing ----------------------------------------------------------

# ir_ok_or_warn RESP LABEL — rc 0 when the Telegram response body is ok:true.
ir_ok_or_warn() {
  local resp="$1" label="$2" ok
  ok=$(jq -r '.ok // false' <<<"$resp" 2>/dev/null) || ok=false
  if [ "$ok" = "true" ]; then
    return 0
  fi
  warn "$label rejected: $(jq -r '(.description // "unknown error") | .[0:200]' <<<"$resp" 2>/dev/null || echo 'unparseable response')"
  return 1
}

# ir_resolve_outbound SID — sets IR_OUT_CHAT / IR_OUT_THREAD ("" = plain chat,
# i.e. General delivery when topics are unavailable). Auto-creates the session
# topic (AC11). rc 1 only on transport failure; an API rejection degrades to
# plain-chat delivery.
ir_resolve_outbound() {
  local sid="$1" t resp
  IR_OUT_CHAT=$OWNER_CHAT
  IR_OUT_THREAD=""
  if [ -f "$TOPICS_FILE" ]; then
    t=$(jq -r --arg sid "$sid" '(.[$sid].thread_id // empty)' "$TOPICS_FILE" 2>/dev/null) || t=""
    if [ -n "$t" ]; then
      IR_OUT_THREAD=$t
      return 0
    fi
  fi
  if [ "$sid" = "$DEFAULT_SESSION" ]; then
    # The default session replies to the walkie-talkie: the general topic, or
    # plain chat when no general topic is recorded (AC8).
    if [ -f "$TOPICS_FILE" ]; then
      t=$(jq -r '(.general.thread_id // empty)' "$TOPICS_FILE" 2>/dev/null) || t=""
      IR_OUT_THREAD=$t
    fi
    return 0
  fi
  # Auto-create the session topic; record it so later lookups hit (AC11).
  resp=$(tg_api createForumTopic -F "chat_id=$OWNER_CHAT" -F "title=$sid") || return 1
  if ir_ok_or_warn "$resp" "createForumTopic"; then
    t=$(jq -r '.result.message_thread_id // empty' <<<"$resp" 2>/dev/null) || t=""
    case "$t" in
      ''|*[!0-9]*)
        warn "createForumTopic returned no usable thread; delivering to plain chat"
        ;;
      *)
        IR_OUT_THREAD=$t
        local tmp
        tmp=$(mktemp "${TMPDIR:-/tmp}/poller.topics.XXXXXX") || return 0
        if [ -f "$TOPICS_FILE" ]; then
          jq --arg sid "$sid" --arg tid "$t" --arg title "$sid" \
            '.[$sid] = {thread_id: ($tid | tonumber), title: $title}' \
            "$TOPICS_FILE" > "$tmp" 2>/dev/null \
            || { warn "cannot update $TOPICS_FILE"; rm -f "$tmp"; return 0; }
        else
          jq -n --arg sid "$sid" --arg tid "$t" --arg title "$sid" \
            '{($sid): {thread_id: ($tid | tonumber), title: $title}}' > "$tmp" \
            || { warn "cannot write $TOPICS_FILE"; rm -f "$tmp"; return 0; }
        fi
        mv -f "$tmp" "$TOPICS_FILE" || { warn "cannot publish $TOPICS_FILE"; rm -f "$tmp"; }
        ;;
    esac
  fi
  return 0
}

# ir_send_text CHAT THREAD TEXT — typing once, then sendMessage. Typing
# failure does not skip the send (AC10). rc 0 on ok:true.
ir_send_text() {
  local chat="$1" thread="$2" text="$3" resp
  local -a typing=(-F "chat_id=$chat" -F "action=typing")
  [ -n "$thread" ] && typing+=(-F "message_thread_id=$thread")
  tg_api sendChatAction "${typing[@]}" >/dev/null 2>&1 || warn "sendChatAction failed"
  local -a args=(-F "chat_id=$chat")
  [ -n "$thread" ] && args+=(-F "message_thread_id=$thread")
  args+=(-F "text=$text")
  resp=$(tg_api sendMessage "${args[@]}") || return 1
  ir_ok_or_warn "$resp" "sendMessage"
}

# ir_send_document CHAT THREAD PATH — rc 0 on ok:true.
ir_send_document() {
  local chat="$1" thread="$2" path="$3" resp
  local -a args=(-F "chat_id=$chat")
  [ -n "$thread" ] && args+=(-F "message_thread_id=$thread")
  args+=(-F "document=@$path")
  resp=$(tg_api sendDocument "${args[@]}") || return 1
  ir_ok_or_warn "$resp" "sendDocument"
}

# ir_mark_outbox_part PATH FLAG — set summary_sent/text_sent after a successful
# message-part send (CDT-530). jq to a tmp file, atomic mv publish, same rule
# as ir_mark_escalated. rc 1 keeps the record for a redelivery (at-least-once).
ir_mark_outbox_part() {
  local rec="$1" flag="$2" tmp
  tmp=$(mktemp "${TMPDIR:-/tmp}/poller.ob.XXXXXX") || return 1
  jq --arg f "$flag" '.[$f] = true' "$rec" > "$tmp" 2>/dev/null \
    || { warn "cannot rewrite outbox record: $rec"; rm -f "$tmp"; return 1; }
  mv -f "$tmp" "$rec" || { warn "cannot publish outbox record: $rec"; rm -f "$tmp"; return 1; }
}

# ir_send_longread CHAT THREAD TEXT SUMMARY FILE [RECORD] — SPEC-038 delivery
# rule: a summary means sendMessage(summary) + sendDocument(file, else
# materialized text); no summary means sendMessage(text) + sendDocument(file)
# when present. With RECORD (CDT-530), a part already marked delivered is not
# re-sent (the retry cycle sends only the remaining part) and a successful
# message part is marked on the record; a failed mark keeps the record, so a
# redelivered part stays possible (at-least-once, no exactly-once claim).
# Never chunk-split (AC9). rc 1 when a required send fails (record is kept).
ir_send_longread() {
  local chat="$1" thread="$2" text="$3" summary="$4" file="$5" rec="${6:-}" tdir doc
  if [ -n "$summary" ]; then
    if [ -z "$rec" ] \
      || [ "$(jq -r '.summary_sent // false' "$rec" 2>/dev/null)" != "true" ]; then
      ir_send_text "$chat" "$thread" "$summary" || return 1
      if [ -n "$rec" ]; then
        ir_mark_outbox_part "$rec" summary_sent || return 1
      fi
    fi
    if [ -n "$file" ] && [ -f "$file" ]; then
      ir_send_document "$chat" "$thread" "$file" || return 1
    else
      [ -n "$file" ] && warn "longread file vanished, materializing text: $file"
      # Suffix-free template: BusyBox mktemp rejects a suffix after the X run.
      tdir=$(mktemp -d "${TMPDIR:-/tmp}/intercom-longread-XXXXXX") || return 1
      doc="$tdir/longread.md"
      printf '%s' "$text" > "$doc" || { rm -rf "$tdir"; return 1; }
      if ! ir_send_document "$chat" "$thread" "$doc"; then
        rm -rf "$tdir"
        return 1
      fi
      rm -rf "$tdir"
    fi
  else
    if [ -z "$rec" ] \
      || [ "$(jq -r '.text_sent // false' "$rec" 2>/dev/null)" != "true" ]; then
      ir_send_text "$chat" "$thread" "$text" || return 1
      if [ -n "$rec" ]; then
        ir_mark_outbox_part "$rec" text_sent || return 1
      fi
    fi
    if [ -n "$file" ]; then
      if [ -f "$file" ]; then
        ir_send_document "$chat" "$thread" "$file" || return 1
      else
        warn "outbox file missing, text already delivered: $file"
      fi
    fi
  fi
  return 0
}

# ---- step 4: outbox drain (oldest first; delete only on success) ----------------

ir_drain_outbox() {
  local rec sid text summary file
  for rec in "$ROOT"/spool/*/outbox/*.json; do
    [ -f "$rec" ] || continue
    sid=$(jq -r '.sid // empty' "$rec" 2>/dev/null) || sid=""
    text=$(jq -r '.text // ""' "$rec" 2>/dev/null) || text=""
    summary=$(jq -r '(.summary // empty)' "$rec" 2>/dev/null) || summary=""
    file=$(jq -r '(.file // empty)' "$rec" 2>/dev/null) || file=""
    if ! ir_sane_sid "$sid"; then
      warn "outbox record has an unusable sid; dropping: $rec"
      rm -f "$rec" || warn "cannot drop $rec"
      continue
    fi
    ir_resolve_outbound "$sid" || { warn "cannot reach Telegram for outbox; record kept: $rec"; return 1; }
    if ! ir_send_longread "$IR_OUT_CHAT" "$IR_OUT_THREAD" "$text" "$summary" "$file" "$rec"; then
      warn "outbox send failed; record kept for retry: $rec"
      return 1
    fi
    rm -f "$rec" || warn "cannot delete delivered record: $rec"
  done
  return 0
}

# ---- step 8: escalation sweep (timestamp-based; catches up after downtime) ------

# ir_mark_escalated PATH [THREAD_ID] — set escalated/escalated_at after a
# successful send. A non-empty THREAD_ID (the delivered topic) is back-filled
# into route.thread_id in the same rewrite (CDT-529 AC4/AC6); plain-chat
# escalation leaves it null.
ir_mark_escalated() {
  local pend="$1" tid="${2:-}" tmp
  tmp=$(mktemp "${TMPDIR:-/tmp}/poller.esc.XXXXXX") || return 1
  jq --arg now "$(date +%s)" --arg tid "$tid" \
    '.escalated = true
     | .escalated_at = ($now | tonumber)
     | if $tid != "" then .route.thread_id = ($tid | tonumber) else . end' \
    "$pend" > "$tmp" 2>/dev/null \
    || { warn "cannot rewrite pending question: $pend"; rm -f "$tmp"; return 1; }
  mv -f "$tmp" "$pend" || { warn "cannot publish pending question: $pend"; rm -f "$tmp"; return 1; }
}

ir_escalation_sweep() {
  local pend sid text asked escalated now
  now=$(date +%s)
  local escalation_timeout_s
  escalation_timeout_s=$(ir_config_field escalation_timeout_s 900)
  case "$escalation_timeout_s" in ''|*[!0-9]*) escalation_timeout_s=900 ;; esac
  for pend in "$ROOT"/spool/*/pending/*.json; do
    [ -f "$pend" ] || continue
    escalated=$(jq -r '.escalated // false' "$pend" 2>/dev/null) || escalated=false
    [ "$escalated" = "true" ] && continue
    sid=$(jq -r '.sid // empty' "$pend" 2>/dev/null) || sid=""
    ir_sane_sid "$sid" || { warn "pending question has an unusable sid; skipping: $pend"; continue; }
    asked=$(jq -r '.asked_at // 0' "$pend" 2>/dev/null) || asked=0
    case "$asked" in ''|*[!0-9]*) asked=0 ;; esac
    # Away ON escalates everything immediately (AC19); otherwise the timer.
    # The sweep compares timestamps, so an expiry missed while the poller was
    # down fires on the next poll (AC15). Escalated stays false until the send
    # succeeds, so a failed notice retries next cycle.
    if [ ! -f "$AWAY_FILE" ] && [ $(( now - asked )) -le "$escalation_timeout_s" ]; then
      continue
    fi
    text=$(jq -r '.text // ""' "$pend" 2>/dev/null) || text=""
    if ! ir_resolve_outbound "$sid"; then
      warn "cannot reach Telegram for escalation; will retry: $pend"
      continue
    fi
    if ir_send_text "$IR_OUT_CHAT" "$IR_OUT_THREAD" "$text"; then
      ir_mark_escalated "$pend" "$IR_OUT_THREAD" || true
    else
      warn "escalation send failed; will retry: $pend"
    fi
  done
}

# ---- offset / seen advance ------------------------------------------------------

# ir_advance_offset UPDATE_ID — records the update in seen.tsv (once) and
# advances the offset monotonically. Called only after the update has been
# handled (relayed, ignored, or deduped) so a crash re-fetches, and the
# seen.tsv window prevents double-processing (AC13).
ir_advance_offset() {
  local nid=$(( $1 + 1 ))
  if ! ir_set_has "$SEEN" "$1"; then
    SEEN="$SEEN$1 "
    ir_seen_append "$1"
  fi
  [ "$nid" -gt "$CUR_OFFSET" ] || return 0
  CUR_OFFSET=$nid
  atomic_write "$OFFSET_FILE" printf '%s\n' "$CUR_OFFSET" \
    || warn "cannot persist $OFFSET_FILE (next cycle refetches; seen.tsv dedupes)"
}

ir_seen_append() {
  printf '%s\t%s\n' "$1" "$(date +%s)" >> "$SEEN_FILE" \
    || warn "cannot append $SEEN_FILE (dedupe window weakens)"
}

ir_seen_prune() {
  local n tmp
  n=$(wc -l < "$SEEN_FILE" 2>/dev/null) || n=0
  case "$n" in ''|*[!0-9]*) return 0 ;; esac
  [ "$n" -gt 1000 ] || return 0
  tmp=$(mktemp "${TMPDIR:-/tmp}/poller.seen.XXXXXX") || return 0
  tail -n 1000 "$SEEN_FILE" > "$tmp" || { rm -f "$tmp"; return 0; }
  mv -f "$tmp" "$SEEN_FILE" || { warn "cannot prune $SEEN_FILE"; rm -f "$tmp"; }
}

# ---- inbound helpers -------------------------------------------------------------

# ir_active_sessions — prints space-separated sane sids whose spool
# pending/ holds ≥1 unanswered question file. CDT-529 defines an *active*
# session this way ("currently orchestrating"); it is independent of the
# topics_enabled setup flag. No dirs are created here (read-only probe).
ir_active_sessions() {
  local d sid out=""
  for d in "$ROOT"/spool/*/pending; do
    [ -d "$d" ] || continue
    sid=${d%/*}
    sid=${sid##*/}
    ir_sane_sid "$sid" || continue
    set -- "$d"/*.json
    [ -f "$1" ] || continue
    out="$out$sid "
  done
  printf '%s\n' "$out"
}

# ir_route_inbound THREAD_ID — prints the sid; rc 1 = ignore-with-zero-
# artifacts (only an unusable default_session or an insane final sid).
# CDT-529 resolution order, first hit wins:
#   (a) no thread_id (plain chat) → default_session; one Q3 warn when a
#       non-default session holds an unanswered question (correlation miss);
#       plain chat is never re-routed to a session.
#   (b) thread mapped to an active session → that sid (AC1).
#   (c) thread unmapped, or mapped to a sid with no unanswered pending →
#       the single active session (AC2); zero or ≥2 active → default_session
#       with one warn naming the thread id (AC3). Supersedes the
#       CDT-512-C3 zero-artifacts ignore for unmapped thread ids.
ir_route_inbound() {
  local tid="$1" sid="" active s n_active=0
  if [ "$DEFAULT_SESSION_OK" -ne 1 ]; then
    warn "default_session unusable; ignoring inbound"
    return 1
  fi
  active=$(ir_active_sessions) || active=""
  set -- $active
  n_active=$#
  if [ -z "$tid" ]; then
    for s in $active; do
      [ "$s" != "$DEFAULT_SESSION" ] || continue
      warn "plain chat arrived while session $s has an unanswered question (correlation miss)"
      break
    done
    sid=$DEFAULT_SESSION
  else
    if [ -f "$TOPICS_FILE" ]; then
      sid=$(jq -r --arg tid "$tid" \
        'to_entries[] | select((.value.thread_id? // 0 | tostring) == $tid) | .key' \
        "$TOPICS_FILE" 2>/dev/null | head -n 1) || sid=""
    fi
    if [ "$sid" = "general" ]; then
      sid=$DEFAULT_SESSION
    elif [ -n "$sid" ]; then
      # (b) mapped to an active session (AC1); an inactive mapped sid falls
      # through to (c) (AC5).
      case " $active " in
        *" $sid "*) printf '%s\n' "$sid" || return 1; return 0 ;;
      esac
      sid=""
    fi
    if [ -z "$sid" ]; then
      if [ "$n_active" -eq 1 ]; then
        sid=${active%% *}
      else
        sid=$DEFAULT_SESSION
        warn "thread $tid is unmapped or its session is inactive; $n_active active sessions — routed to $DEFAULT_SESSION"
      fi
    fi
  fi
  ir_sane_sid "$sid" || { warn "routed sid is unusable; ignored"; return 1; }
  printf '%s\n' "$sid"
}

# ir_mark_answered SID — move every unanswered pending question of SID to
# answered/ (AC16); an escalation already sent or pending is cancelled by the
# escalated check in the sweep.
ir_mark_answered() {
  local pdir adir q moved=0
  pdir=$(ir_spool_dir "$1" pending) || return 1
  adir=$(ir_spool_dir "$1" answered) || return 1
  for q in "$pdir"/*.json; do
    [ -f "$q" ] || continue
    if mv -f "$q" "$adir/"; then
      moved=1
    else
      warn "cannot move to answered: $q"
    fi
  done
  return 0
}

# ir_inbox_write SID KIND TEXT FROM_ID UPDATE_ID THREAD_ID
ir_inbox_write() {
  local sid="$1" kind="$2" text="$3" from_id="$4" uid="$5" tid="$6" dir tmp name json
  dir=$(ir_spool_dir "$sid" inbox) || return 1
  tmp=$(ir_record_tmp "$dir" in) || return 1
  name="$(ir_epoch_ms)_${uid}.json"
  if ! json=$(jq -n \
      --arg sid "$sid" --arg kind "$kind" --arg text "$text" \
      --arg from_id "$from_id" --arg uid "$uid" --arg tid "$tid" \
      --arg ts "$(date +%s)" '
      {ts: ($ts|tonumber), sid: $sid, dir: "in", kind: $kind, text: $text,
       from_id: (if $from_id == "" then 0 else ($from_id|tonumber) end),
       update_id: ($uid|tonumber),
       thread_id: (if $tid == "" then 0 else ($tid|tonumber) end)}'); then
    rm -f "$tmp"
    warn "cannot build inbox record"
    return 1
  fi
  printf '%s\n' "$json" > "$tmp" || { rm -f "$tmp"; warn "cannot write inbox record"; return 1; }
  ir_record_publish "$tmp" "$dir/$name" >/dev/null || { warn "cannot publish inbox record"; return 1; }
}

# ir_process_update UPDATE_JSON — one update: dedupe, type allowlist, chat
# allowlist, reserved commands, route, relay. Always advances the offset past
# the update (an ignored update is still consumed; refetching it forever would
# stall the stream).
ir_process_update() {
  local u="$1" uid utype chat_id text thread_id from_id sid kind
  uid=$(jq -r '.update_id // empty' <<<"$u" 2>/dev/null) || uid=""
  case "$uid" in
    ''|*[!0-9]*) warn "update without a numeric update_id; ignored"; return 0 ;;
  esac
  if ir_set_has "$SEEN" "$uid"; then
    ir_advance_offset "$uid"
    return 0
  fi
  # Explicit update-type allowlist (c8-council-finding fix, see header).
  utype=$(jq -r '
    if has("message") then "message"
    elif has("edited_message") then "edited_message"
    elif has("channel_post") then "channel_post"
    elif has("callback_query") then "callback_query"
    else "unknown" end' <<<"$u" 2>/dev/null) || utype="unknown"
  case "$utype" in
    message) ;;
    *)
      # edited_message / channel_post / callback_query / anything else: zero
      # artifacts, offset still advances so the update is not re-fetched.
      ir_advance_offset "$uid"
      return 0
      ;;
  esac
  chat_id=$(jq -r '.message.chat.id // empty' <<<"$u" 2>/dev/null) || chat_id=""
  case "$chat_id" in
    # No chat object (or a non-numeric id) → fail-closed ignore (AC2, AC3).
    ''|*[!0-9]*) ir_advance_offset "$uid"; return 0 ;;
  esac
  ir_set_has "$SEEN_ALLOW" "$chat_id" || { ir_advance_offset "$uid"; return 0; }

  text=$(jq -r '.message.text // .message.caption // ""' <<<"$u" 2>/dev/null) || text=""
  thread_id=$(jq -r '.message.message_thread_id // empty' <<<"$u" 2>/dev/null) || thread_id=""
  case "$thread_id" in ''|*[!0-9]*) thread_id="" ;; esac
  from_id=$(jq -r '.message.from.id // empty' <<<"$u" 2>/dev/null) || from_id=""
  case "$from_id" in ''|*[!0-9]*) from_id="" ;; esac

  # Bot self-echo (same chat as the member) must not answer pending questions.
  if [ -n "$BOT_ID" ] && [ "$from_id" = "$BOT_ID" ]; then
    ir_advance_offset "$uid"
    return 0
  fi
  # Empty-text forum service messages (topic rename, etc.).
  if [ -z "$text" ] \
    && jq -e '.message | (has("forum_topic_edited") or has("forum_topic_created")
      or has("forum_topic_closed") or has("forum_topic_reopened"))' \
      <<<"$u" >/dev/null 2>&1; then
    ir_advance_offset "$uid"
    return 0
  fi

  # Reserved phone commands: toggle state/away, confirm in place, relay
  # nothing (AC17). The optional @botname suffix is how Telegram renders
  # commands in groups.
  if [[ "$text" =~ ^/(away|afk)(@[A-Za-z0-9_]*)?$ ]]; then
    if [ -f "$AWAY_FILE" ]; then
      rm -f "$AWAY_FILE" || warn "cannot remove $AWAY_FILE"
      ir_send_text "$chat_id" "$thread_id" "away: off" || warn "away confirmation send failed"
    else
      atomic_write "$AWAY_FILE" date +%s || warn "cannot write $AWAY_FILE"
      ir_send_text "$chat_id" "$thread_id" "away: on" || warn "away confirmation send failed"
    fi
    ir_advance_offset "$uid"
    return 0
  fi

  if ! sid=$(ir_route_inbound "$thread_id"); then
    ir_advance_offset "$uid"
    return 0
  fi

  # An allowlisted reply cancels escalation for the session and relays as an
  # answer (AC16). A pending dir only ever holds unanswered questions. The
  # kind is derived before any mutation and the move happens only after the
  # record is durable: a failed write leaves pending/ untouched, so the
  # at-least-once retry re-derives the same kind instead of degrading to
  # "message".
  local pdir kind="message" has_pending=0
  if pdir=$(ir_spool_dir "$sid" pending) && [ -n "$(ls "$pdir"/*.json 2>/dev/null)" ]; then
    has_pending=1
    kind="answer"
  fi

  if ! ir_inbox_write "$sid" "$kind" "$text" "$from_id" "$uid" "$thread_id"; then
    # No record written: do NOT advance, so the next cycle re-fetches and
    # retries this update (at-least-once; seen.tsv has not been touched).
    return 1
  fi
  if [ "$has_pending" -eq 1 ] && ! ir_mark_answered "$sid"; then
    warn "could not mark questions answered for $sid; escalation continues"
  fi

  # Pickup writes inbox only. Typing is on the send path (AC10), not here.
  [ "$WAS_STALE" -eq 1 ] || { ir_advance_offset "$uid"; return 0; }
  # Resume notice after a stale heartbeat: confirm queuing in the routed
  # topic (AC12). Delivery failure still counts as picked up (the record
  # exists), so the offset advances either way.
  ir_resolve_outbound "$sid" \
    && ir_send_text "$IR_OUT_CHAT" "$IR_OUT_THREAD" "offline, queued" \
    || warn "offline-queued notice failed for update $uid"
  ir_advance_offset "$uid"
  return 0
}

# ---- main cycle ------------------------------------------------------------------

ir_drain_outbox || true

# seen.tsv dedupe window (AC13): load once, check in memory.
if [ -f "$SEEN_FILE" ]; then
  while IFS=$'\t' read -r uid _ep || [ -n "$uid" ]; do
    [ -n "$uid" ] && SEEN="$SEEN$uid "
  done < "$SEEN_FILE"
fi

poll_timeout_s=$(ir_config_field poll_timeout_s 30)
case "$poll_timeout_s" in ''|*[!0-9]*) poll_timeout_s=30 ;; esac
[ "$poll_timeout_s" -ge 1 ] || poll_timeout_s=30

rc=0
resp=$(tg_api "getUpdates" \
  --max-time $(( poll_timeout_s + 10 )) \
  -d "offset=$CUR_OFFSET" \
  -d "timeout=$poll_timeout_s" \
  -d "limit=100") || rc=$?
if [ "$rc" -ne 0 ]; then
  # SPEC-038 § Poller cycle: a getUpdates network error exits 0 and mutates
  # nothing; the scheduler reschedules anyway.
  warn "getUpdates transport failure (curl rc $rc); no state advanced — exiting 0 for reschedule"
  exit 0
fi

ok=$(jq -r '.ok // false' <<<"$resp" 2>/dev/null) || ok=false
if [ "$ok" != "true" ]; then
  err_code=$(jq -r '.error_code // 0' <<<"$resp" 2>/dev/null) || err_code=0
  case "$err_code" in
    409)
      # A second consumer holds the token; never advance state (AC22).
      warn "getUpdates 409 Conflict: another getUpdates consumer is active"
      exit 4
      ;;
    429)
      retry_after=$(jq -r '.parameters.retry_after // 1' <<<"$resp" 2>/dev/null) || retry_after=1
      case "$retry_after" in ''|*[!0-9]*) retry_after=1 ;; esac
      # Deadline-capped: a hostile/absent retry_after cannot hang the cycle.
      [ "$retry_after" -gt 3600 ] && retry_after=3600
      warn "getUpdates 429: honoring retry_after=${retry_after}s, exiting for reschedule"
      ir_touch_heartbeat
      exit 0
      ;;
    *)
      die "getUpdates rejected (error_code ${err_code:-?}): $(jq -r '(.description // "no description") | .[0:200]' <<<"$resp" 2>/dev/null || echo 'unparseable response')"
      ;;
  esac
fi

while IFS= read -r u || [ -n "$u" ]; do
  [ -n "$u" ] || continue
  if ! ir_process_update "$u"; then
    die "update processing failed; offset not advanced past the failed update"
  fi
done < <(jq -c '.result | sort_by(.update_id) | .[]?' <<<"$resp" 2>/dev/null)

ir_escalation_sweep
ir_seen_prune
ir_touch_heartbeat
exit 0
