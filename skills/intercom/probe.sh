#!/usr/bin/env bash
# probe.sh — operator-invoked live check of the Bot API behaviors SPEC-038 §
# "Verified vs assumed" lists as unverified. NEVER call it from tests or from
# setup-telegram.sh (SPEC-038:204): it hits the live API by design.
#
# Stop the harness poller before running: probe's own concurrent getUpdates
# would 409-terminate a live cycle (the harness reschedules it).
#
# Checks (PASS/FAIL per behavior; cleanup after each; messages go to the
# operator's own chat only, taken from config.json members):
#   getMe identity; getUpdates offset/timeout long-poll semantics; 409 Conflict
#   shape on a simulated second consumer (probe starts a background long-poll,
#   then issues a second one — equivalently, run two probe.sh instances at
#   once); sendMessage 4096-char limit + parse_mode=HTML + link-preview
#   suppression; createForumTopic + message_thread_id routing (topics chats
#   only); sendChatAction typing; sendDocument field name; 429 retry_after
#   shape (bounded burst; SKIP when flood limits are not reached); operator
#   chat topics status. Exit nonzero on any FAIL.
set -u

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=common.sh
. "$SCRIPT_DIR/common.sh"

if [ "${BASH_SOURCE[0]}" != "$0" ]; then
  echo "probe.sh is an operator CLI (SPEC-038:204); never source it." >&2
  return 1
fi

# Hermetic guard: probe is the one live-API tool; refuse under test overrides.
if [ -n "${INTERCOM_STATE_ROOT:-}" ]; then
  echo "probe: refusing to run with INTERCOM_STATE_ROOT set — probe hits the live API and is operator-invoked only (SPEC-038:204)." >&2
  exit 2
fi

ir_require_tools jq curl || exit 1

PASS=0
FAIL=0
SKIP=0
TMPS=""
cleanup() { [ -n "$TMPS" ] && rm -f $TMPS; return 0; }
trap cleanup EXIT

tmpf() {
  # Sets $TMPF to a new tracked temp file (removed on EXIT).
  TMPF=$(mktemp "${TMPDIR:-/tmp}/probe.XXXXXX") || return 1
  TMPS="$TMPS $TMPF"
}

report() {
  # report STATUS NAME DETAIL
  case "$1" in
    PASS) PASS=$((PASS + 1)) ;;
    FAIL) FAIL=$((FAIL + 1)) ;;
    SKIP) SKIP=$((SKIP + 1)) ;;
  esac
  printf '%-4s %-38s %s\n' "$1" "$2" "$3"
}

# JSON POST body for a method call; text travels as argv, never the token (AC4).
tg_post() { # tg_post METHOD JSON [curl-args...]
  local method="$1" body="$2"
  shift 2
  tg_api "$method" -H 'Content-Type: application/json' --data-binary "$body" "$@"
}

tg_del() { # tg_del CHAT MESSAGE_ID — best-effort message cleanup
  [ "$2" = 0 ] && return 0
  local body
  body=$(jq -n --arg chat "$1" --argjson mid "$2" '{chat_id: $chat, message_id: $mid}') || return 0
  tg_post deleteMessage "$body" --max-time 15 >/dev/null 2>&1 || true
}

# ---- preconditions -------------------------------------------------------------

ir_token_read >/dev/null || exit 1

root=$(ir_state_root)
cfg="$root/config.json"
if [ ! -f "$cfg" ]; then
  echo "probe: no $cfg — run /setup telegram first (the operator chat id comes from config.json members)." >&2
  exit 2
fi
chat_id=$(jq -r '[.members | keys[] | select(test("^[0-9]+$"))][0] // empty' "$cfg" 2>/dev/null)
case "$chat_id" in
  ''|*[!0-9]*)
    echo "probe: no numeric member chat id in $cfg" >&2
    exit 2
    ;;
esac
echo "probe: live check against api.telegram.org for chat $chat_id (stop the poller first)."
echo

# ---- 1. getMe ------------------------------------------------------------------

if resp=$(tg_api getMe --max-time 15) \
  && jq -e '.ok == true and (.result.id | type == "number")' <<<"$resp" >/dev/null 2>&1; then
  report PASS "getMe identity" \
    "bot @$(jq -r '.result.username // "?"' <<<"$resp") id $(jq -r '.result.id' <<<"$resp")"
else
  report FAIL "getMe identity" "call failed or ok != true — cannot probe further"
  printf '\nSUM: PASS=%d FAIL=%d SKIP=%d\n' "$PASS" "$FAIL" "$SKIP"
  exit 1
fi

# ---- 2. getUpdates long-poll semantics -----------------------------------------
# offset=-1 reads without confirming; probe never advances the poller's offset.

last_id=""
shape_ok=""
if resp=$(tg_api "getUpdates?timeout=0&offset=-1" --max-time 15) \
  && jq -e '.result | type == "array"' <<<"$resp" >/dev/null 2>&1; then
  shape_ok=yes
  last_id=$(jq -r '[.result[] | .update_id] | max // empty' <<<"$resp")
fi

t0=$(date +%s)
held=""
if resp=$(tg_api "getUpdates?timeout=5&offset=-1" --max-time 15) \
  && jq -e '.result | type == "array"' <<<"$resp" >/dev/null 2>&1; then
  if jq -e '.result | length == 0' <<<"$resp" >/dev/null 2>&1; then
    t1=$(date +%s)
    [ $((t1 - t0)) -ge 4 ] && held=yes
  else
    held=pending
  fi
fi

case "$held" in
  yes)
    [ -n "$shape_ok" ] || shape_ok=yes
    report PASS "getUpdates long-poll" "idle long-poll held open ~timeout s before answering []; offset=-1 shape ok"
    ;;
  pending)
    case "$last_id" in
      ''|*[!0-9]*)
        # No pending traffic: verify offset honoring against the poller's own
        # offset — a replay of anything below it would mean the param is ignored.
        o=$(cat "$root/state/offset" 2>/dev/null || true)
        case "$o" in
          ''|*[!0-9]*)
            report SKIP "getUpdates long-poll" "state/offset unreadable and no measurable hold; semantics partially unverified"
            ;;
          *)
            if resp=$(tg_api "getUpdates?timeout=0&offset=$o" --max-time 15) \
              && jq -e --argjson o "$o" '[.result[] | select(.update_id < $o)] | length == 0' <<<"$resp" >/dev/null 2>&1; then
              report PASS "getUpdates long-poll" "offset=$o honored: nothing below it replayed (hold not measurable while idle-vs-pending raced)"
            else
              report FAIL "getUpdates long-poll" "replayed already-confirmed updates at offset $o"
            fi
            ;;
        esac
        ;;
      *)
        report SKIP "getUpdates long-poll" "unprocessed updates pending; probe never confirms them — re-run when the queue is drained"
        ;;
    esac
    ;;
  *)
    report FAIL "getUpdates long-poll" "long-poll returned early or .result not an array"
    ;;
esac

# ---- 3. 409 Conflict on a second consumer ---------------------------------------
# Consumer #1 is probe's own background long-poll; consumer #2 arrives while it
# holds the poll — Telegram terminates #1 with 409 and serves #2.

tmpf || exit 1
f409=$TMPF
tg_api "getUpdates?timeout=30&offset=-1" --max-time 40 > "$f409" 2>/dev/null &
pid1=$!
sleep 2
resp2=$(tg_api "getUpdates?timeout=2&offset=-1" --max-time 15)
sleep 1
kill "$pid1" 2>/dev/null
wait "$pid1" 2>/dev/null
body1=$(cat "$f409")
if jq -e '.ok == false and .error_code == 409' <<<"$body1" >/dev/null 2>&1; then
  report PASS "409 second consumer" \
    "background long-poll terminated with error_code 409: $(jq -r '.description // "no description"' <<<"$body1" | head -c 120)"
else
  report FAIL "409 second consumer" "no 409 shape captured (got: $(printf '%s' "$body1" | head -c 120))"
fi

# ---- 4. sendMessage: 4096 limit, parse_mode=HTML, link-preview suppression ------

big4096=$(jq -rn '"a" * 4096')
big4097=$(jq -rn '"a" * 4097')

body=$(jq -n --arg chat "$chat_id" --arg t "$big4096" '{chat_id: $chat, text: $t}')
if resp=$(tg_post sendMessage "$body" --max-time 15) && jq -e '.ok == true' <<<"$resp" >/dev/null 2>&1; then
  report PASS "sendMessage 4096 accepted" "exactly 4096 chars delivered"
  tg_del "$chat_id" "$(jq -r '.result.message_id // 0' <<<"$resp")"
else
  report FAIL "sendMessage 4096 accepted" "4096-char message rejected"
fi

body=$(jq -n --arg chat "$chat_id" --arg t "$big4097" '{chat_id: $chat, text: $t}')
if resp=$(tg_post sendMessage "$body" --max-time 15) \
  && jq -e '.ok == false' <<<"$resp" >/dev/null 2>&1 \
  && jq -r '(.description // "")' <<<"$resp" | grep -qi 'too long'; then
  report PASS "sendMessage >4096 rejected" "$(jq -r '.description' <<<"$resp" | head -c 90)"
else
  report FAIL "sendMessage >4096 rejected" "4097-char message was not rejected with 'too long'"
fi

body=$(jq -n --arg chat "$chat_id" '{chat_id: $chat, text: "<b>intercom-probe</b>", parse_mode: "HTML"}')
if resp=$(tg_post sendMessage "$body" --max-time 15) \
  && jq -e '.ok == true and .result.entities[0].type == "bold"' <<<"$resp" >/dev/null 2>&1; then
  report PASS "parse_mode=HTML" "bold entity parsed"
  tg_del "$chat_id" "$(jq -r '.result.message_id // 0' <<<"$resp")"
else
  report FAIL "parse_mode=HTML" "HTML not parsed or call rejected"
fi

body=$(jq -n --arg chat "$chat_id" \
  '{chat_id: $chat, text: "https://example.com/intercom-probe", link_preview_options: {is_disabled: true}}')
if resp=$(tg_post sendMessage "$body" --max-time 15) && jq -e '.ok == true' <<<"$resp" >/dev/null 2>&1; then
  report PASS "link-preview suppression" "link_preview_options.is_disabled accepted"
  tg_del "$chat_id" "$(jq -r '.result.message_id // 0' <<<"$resp")"
else
  body=$(jq -n --arg chat "$chat_id" \
    '{chat_id: $chat, text: "https://example.com/intercom-probe", disable_web_page_preview: true}')
  if resp=$(tg_post sendMessage "$body" --max-time 15) && jq -e '.ok == true' <<<"$resp" >/dev/null 2>&1; then
    report PASS "link-preview suppression" "legacy disable_web_page_preview accepted (link_preview_options rejected)"
    tg_del "$chat_id" "$(jq -r '.result.message_id // 0' <<<"$resp")"
  else
    report FAIL "link-preview suppression" "neither link_preview_options nor disable_web_page_preview accepted"
  fi
fi

# ---- 5. createForumTopic + message_thread_id routing (topics chats only) -------

if resp=$(tg_api "getChat?chat_id=${chat_id}" --max-time 15) \
  && jq -e '.ok == true and .result.is_forum == true' <<<"$resp" >/dev/null 2>&1; then
  report PASS "operator chat topics status" "is_forum=true (topics-dependent routing available)"
  title="intercom-probe-$(date +%s)"
  body=$(jq -n --arg chat "$chat_id" --arg n "$title" '{chat_id: $chat, name: $n}')
  if resp=$(tg_post createForumTopic "$body" --max-time 15) \
    && jq -e '.ok == true and (.result.message_thread_id | type == "number")' <<<"$resp" >/dev/null 2>&1; then
    tid=$(jq -r '.result.message_thread_id' <<<"$resp")
    body=$(jq -n --arg chat "$chat_id" --argjson tid "$tid" \
      '{chat_id: $chat, message_thread_id: $tid, text: "probe routing"}')
    if resp2=$(tg_post sendMessage "$body" --max-time 15) \
      && jq -e --argjson tid "$tid" '.ok == true and .result.message_thread_id == $tid' <<<"$resp2" >/dev/null 2>&1; then
      report PASS "createForumTopic + routing" "topic $tid created; thread-routed message echoed message_thread_id"
      tg_del "$chat_id" "$(jq -r '.result.message_id // 0' <<<"$resp2")"
    else
      report FAIL "createForumTopic + routing" "topic created but thread-routed sendMessage failed"
    fi
    # Cleanup: delete the probe topic (fallback close, so it is at least inert).
    body=$(jq -n --arg chat "$chat_id" --argjson tid "$tid" '{chat_id: $chat, message_thread_id: $tid}')
    if ! tg_post deleteForumTopic "$body" --max-time 15 >/dev/null 2>&1; then
      tg_post closeForumTopic "$body" --max-time 15 >/dev/null 2>&1 \
        && echo "probe: note: could not delete topic $title; closed it instead." >&2
    fi
  else
    report FAIL "createForumTopic + routing" "createForumTopic rejected"
  fi
else
  report SKIP "operator chat topics status" "is_forum != true — plain General delivery (walkie-talkie degrades; per-session topics unavailable)"
  report SKIP "createForumTopic + routing" "not a topics-enabled chat"
fi

# ---- 6. sendChatAction typing ---------------------------------------------------

body=$(jq -n --arg chat "$chat_id" '{chat_id: $chat, action: "typing"}')
if resp=$(tg_post sendChatAction "$body" --max-time 15) && jq -e '.ok == true' <<<"$resp" >/dev/null 2>&1; then
  report PASS "sendChatAction typing" "typing action accepted"
else
  report FAIL "sendChatAction typing" "call rejected"
fi

# ---- 7. sendDocument field name -------------------------------------------------

tmpf || exit 1
fdoc=$TMPF
printf '# intercom probe\n' > "$fdoc"
if resp=$(tg_api sendDocument -F "chat_id=${chat_id}" -F "document=@${fdoc};filename=intercom-probe.md" --max-time 30) \
  && jq -e '.ok == true and .result.document.file_name == "intercom-probe.md"' <<<"$resp" >/dev/null 2>&1; then
  report PASS "sendDocument field name" \
    "'document' multipart field accepted (file_size $(jq -r '.result.document.file_size // "?"' <<<"$resp") B; 50 MiB cap documented, not flooded)"
  tg_del "$chat_id" "$(jq -r '.result.message_id // 0' <<<"$resp")"
else
  report FAIL "sendDocument field name" "'document' upload rejected"
fi

# ---- 8. 429 retry_after shape (bounded burst; SKIP when not triggered) ----------
# Hard deadline: 30 iterations x (5s max-time + 0.2s sleep) ~= 2.5 min worst case.

retry_after=""
n=0
while [ "$n" -lt 30 ]; do
  body=$(jq -n --arg chat "$chat_id" --arg t "p$n" '{chat_id: $chat, text: $t}')
  resp=""
  resp=$(tg_post sendMessage "$body" --max-time 5) || resp=""
  if [ -n "$resp" ] && jq -e '.ok == false and .error_code == 429' <<<"$resp" >/dev/null 2>&1; then
    retry_after=$(jq -r '.parameters.retry_after // ""' <<<"$resp")
    break
  fi
  [ -n "$resp" ] && tg_del "$chat_id" "$(jq -r '.result.message_id // 0' <<<"$resp")"
  n=$((n + 1))
  sleep 0.2
done
case "$retry_after" in
  ''|*[!0-9]*) report SKIP "429 retry_after shape" \
    "not triggered within 30 messages — flood limits unreached; retry_after shape unverified live" ;;
  *) report PASS "429 retry_after shape" "error_code 429 carried parameters.retry_after=$retry_after" ;;
esac

# ---- summary --------------------------------------------------------------------

echo
printf 'SUM: PASS=%d FAIL=%d SKIP=%d\n' "$PASS" "$FAIL" "$SKIP"
[ "$FAIL" -eq 0 ]
