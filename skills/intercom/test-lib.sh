#!/usr/bin/env bash
# test-lib.sh — shared hermetic scaffolding for the intercom suites (SPEC-038).
# Source-only: test.sh, test-poller.sh, and test-daemon.sh source it after
# tests/lib/hermetic.sh. It owns the no-network curl shim, the docker mock
# (never a real daemon), and the state/fixture/spool helpers the suites use.
# Suite-specific setup (EMPTY_BIN, TRANSCRIPT_MIRROR_ROOT, run_cli_env,
# ok_empty_result, the fixtures/ dir) and the test bodies stay in the suites.
# The suites define TEST_TOKEN, fresh_case, and fresh_state before the
# helpers that reference them are called.

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  echo "test-lib.sh is a source-only library, not a suite — source it from skills/intercom/test.sh, test-poller.sh, or test-daemon.sh." >&2
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

upd_msg_from() { # ID CHAT TEXT FROM [THREAD] — from.id independent of chat.id
  jq -n --argjson id "$1" --argjson chat "$2" --arg text "$3" --argjson from "$4" --argjson thread "${5:-0}" '
    {update_id: $id, message: (
      {message_id: $id,
       from: {id: $from, is_bot: ($from != $chat), first_name: "Who"},
       chat: {id: $chat, type: "private"}, date: 1700000000, text: $text}
      + (if $thread == 0 then {} else {message_thread_id: $thread} end)
    )}'
}

upd_forum_edited() { # ID CHAT FROM THREAD NAME — empty-text forum_topic_edited
  upd_forum_svc "$1" "$2" "$3" "$4" forum_topic_edited "$5"
}

upd_forum_svc() { # ID CHAT FROM THREAD KEY [NAME] — empty-text forum service
  jq -n --argjson id "$1" --argjson chat "$2" --argjson from "$3" --argjson thread "$4" \
    --arg key "$5" --arg name "${6:-x}" '
    {update_id: $id, message: (
      {message_id: $id,
       from: {id: $from, is_bot: true, first_name: "Bot"},
       chat: {id: $chat, type: "private"}, date: 1700000000,
       message_thread_id: $thread}
      + {($key): {name: $name}}
    )}'
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

run_watch() { # one host-adapter cycle; sets W_OUT W_ERR W_RC
  : > "$CALLS_LOG"
  : > "$ARGV_LOG"
  W_OUT=$(bash "$WATCH" 2>"$ERRF")
  W_RC=$?
  W_ERR=$(cat "$ERRF")
}

run_daemon() { # one daemon.sh invocation until it exits; sets D_OUT D_ERR D_RC
  # Poller override: INTERCOM_POLLER (T2) or PATH. Never call a real container.
  D_OUT=$(bash "${DAEMON:?}" 2>"$ERRF")
  D_RC=$?
  D_ERR=$(cat "$ERRF")
}

run_cli() { # SCRIPT ARG... — sets C_OUT C_ERR C_RC
  C_OUT=$(bash "$@" 2>"$ERRF")
  C_RC=$?
  C_ERR=$(cat "$ERRF")
}

calls_count() { grep -c "^$1 " "$CALLS_LOG" 2>/dev/null || true; }

# True when every sendMessage in CALLS_LOG is immediately preceded by
# sendChatAction (CDT-512-C5 / SPEC-038 AC10 send path).
typing_before_each_send() {
  awk '
    $1 == "sendChatAction" { armed = 1; next }
    $1 == "sendMessage" {
      if (!armed) { exit 1 }
      armed = 0
    }
  ' "$CALLS_LOG"
}

inbox_files() { find "$STATE_ROOT/spool/$1/inbox" -name '*.json' 2>/dev/null; }
inbox_n() { inbox_files "$1" | wc -l | tr -d ' '; }
seen_n() { wc -l < "$STATE_ROOT/state/seen.tsv" 2>/dev/null | tr -d ' '; }
offset_val() { cat "$STATE_ROOT/state/offset" 2>/dev/null; }

# ---- docker mock (CDT-509 / CDT-527). Never talks to a real daemon. ------------
# Modes (DOCKER_MOCK_MODE_FILE): no-compose, no-engine, down, running, up-ok,
# up-fail. CLI-absent = nodocker_bin PATH + rm_docker_mock (no shim).
# assert_no_docker_pull flags docker verbs `pull`/`run` only — not `--build`
# on `compose … up -d --build`.

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

install_docker_mock() { # no-compose|no-engine|down|running|up-ok|up-fail
  local mode="$1"
  case "$mode" in
    no-compose|no-engine|down|running|up-ok|up-fail) ;;
    *)
      echo "install_docker_mock: unknown mode $mode" >&2
      return 2
      ;;
  esac
  [ -n "${SHIM_DIR:-}" ] || { echo "install_docker_mock: SHIM_DIR unset" >&2; return 2; }
  [ -n "${HERMETIC_ROOT:-}" ] || { echo "install_docker_mock: HERMETIC_ROOT unset" >&2; return 2; }
  export DOCKER_MOCK_MODE_FILE="$HERMETIC_ROOT/docker.mode"
  export DOCKER_MOCK_LOG="$HERMETIC_ROOT/docker.argv"
  export DOCKER_MOCK_ENV="$HERMETIC_ROOT/docker.env"
  printf '%s\n' "$mode" > "$DOCKER_MOCK_MODE_FILE"
  : > "$DOCKER_MOCK_LOG"
  : > "$DOCKER_MOCK_ENV"
  cat > "$SHIM_DIR/docker" <<'EOF'
#!/usr/bin/env bash
# Hermetic docker: no daemon. Logs argv; compose version / info / ps / up
# follow DOCKER_MOCK_MODE_FILE. Refuses pull/run verbs. Allows --build.
{
  printf 'argv'
  printf ' %s' "$@"
  printf '\n'
} >> "${DOCKER_MOCK_LOG:-/dev/null}"
{
  printf 'argv'
  printf ' %s' "$@"
  printf '\n'
  env | grep -E '^(INTERCOM_|TELEGRAM_|BOT_)' || true
  printf '\n'
} >> "${DOCKER_MOCK_ENV:-/dev/null}"
for a in "$@"; do
  case "$a" in
    pull|run)
      echo "docker-mock: refused $a" >&2
      exit 64
      ;;
  esac
done
mode=$(cat "${DOCKER_MOCK_MODE_FILE:-/dev/null}" 2>/dev/null || true)
is_compose=0
sub=""
want=0
skip=0
prev=""
cmd=""
first=1
for a in "$@"; do
  if [ "$first" -eq 1 ]; then
    first=0
    cmd="$a"
  fi
  if [ "$skip" -eq 1 ]; then
    skip=0
    case "$prev" in
      -p|--project-name) [ "$a" = "intercom" ] && want=1 ;;
      --filter) case "$a" in *dev-team.intercom*) want=1 ;; esac ;;
    esac
    prev="$a"
    continue
  fi
  case "$a" in
    compose)
      is_compose=1
      prev="$a"
      continue
      ;;
    -p|--project-name|-f|--file|--format|--filter|--status)
      skip=1
      prev="$a"
      continue
      ;;
    --project-name=intercom)
      want=1
      prev="$a"
      continue
      ;;
    --filter=*|*dev-team.intercom*)
      case "$a" in *dev-team.intercom*) want=1 ;; esac
      prev="$a"
      continue
      ;;
    -*)
      prev="$a"
      continue
      ;;
    *)
      if [ "$is_compose" -eq 1 ] && [ -z "$sub" ]; then
        sub="$a"
      fi
      prev="$a"
      ;;
  esac
done
running_json() {
  printf '%s\n' '{"Service":"daemon","State":"running","Labels":"dev-team.intercom=daemon","Project":"intercom"}'
  printf '%s\n' "deadbeef"
}
if [ "$is_compose" -eq 1 ]; then
  case "$sub" in
    version)
      if [ "$mode" = "no-compose" ]; then
        echo "docker: unknown command: compose" >&2
        exit 1
      fi
      echo "Docker Compose version v2.29.0"
      exit 0
      ;;
    ps)
      if [ "$mode" = "running" ] && [ "$want" -eq 1 ]; then
        running_json
      fi
      exit 0
      ;;
    up)
      case "$mode" in
        up-ok) exit 0 ;;
        up-fail)
          echo "docker-mock: compose up failed" >&2
          exit 1
          ;;
        *)
          echo "docker-mock: compose up not enabled (mode=$mode)" >&2
          exit 1
          ;;
      esac
      ;;
    *)
      if [ "$mode" = "no-compose" ]; then
        echo "docker: unknown command: compose" >&2
        exit 1
      fi
      exit 0
      ;;
  esac
fi
if [ "$cmd" = "info" ]; then
  if [ "$mode" = "no-engine" ]; then
    echo "Cannot connect to the Docker daemon" >&2
    exit 1
  fi
  echo "Server Version: mock"
  exit 0
fi
if [ "$cmd" = "ps" ]; then
  if [ "$mode" = "running" ] && [ "$want" -eq 1 ]; then
    running_json
  fi
  exit 0
fi
case "$cmd" in
  build|push)
    echo "docker-mock: refused $cmd" >&2
    exit 64
    ;;
esac
exit 0
EOF
  chmod +x "$SHIM_DIR/docker"
}

rm_docker_mock() {
  rm -f "${SHIM_DIR:-}/docker"
  [ -n "${DOCKER_MOCK_LOG:-}" ] && : > "$DOCKER_MOCK_LOG"
  [ -n "${DOCKER_MOCK_ENV:-}" ] && : > "$DOCKER_MOCK_ENV"
}

assert_no_docker_pull() { # LABEL — fail on docker verb pull/run, not compose --build
  local log="${DOCKER_MOCK_LOG:-}"
  [ -n "$log" ] && [ -s "$log" ] || return 0
  if awk '{ for (i = 1; i <= NF; i++) if ($i == "pull" || $i == "run") found=1 }
          END { exit found ? 0 : 1 }' "$log"; then
    bad "$1 invoked docker pull/run: $(tr '\n' ' ' < "$log")"
    return 1
  fi
  return 0
}

docker_mock_logged_up() { # rc 0 when log has compose -p intercom -f … up -d --build
  local log="${DOCKER_MOCK_LOG:-}"
  [ -n "$log" ] && [ -f "$log" ] || return 1
  grep -q -- '-p intercom' "$log" || return 1
  awk '
    {
      has_up=0; has_d=0; has_build=0; has_f=0
      for (i = 1; i <= NF; i++) {
        if ($i == "up") has_up=1
        if ($i == "-d") has_d=1
        if ($i == "--build") has_build=1
        if ($i == "-f" || $i == "--file") has_f=1
      }
      if (has_up && has_d && has_build && has_f) found=1
    }
    END { exit found ? 0 : 1 }
  ' "$log"
}

assert_no_compose_up() { # LABEL
  local log="${DOCKER_MOCK_LOG:-}"
  if [ -n "$log" ] && [ -s "$log" ] \
    && awk '{ for (i = 1; i <= NF; i++) if ($i == "up") found=1 }
            END { exit found ? 0 : 1 }' "$log"; then
    bad "$1 compose up logged: $(tr '\n' ' ' < "$log")"
    return 1
  fi
  return 0
}
