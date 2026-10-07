# intercom.sh — doctor check for the intercom spool protocol (SPEC-038 §
# Doctor). WARN-never-FAIL per the SPEC-037 models.map precedent: it reports
# posture and never emits FAIL. Sourced by doctor.sh like every checks/*.sh;
# the one top-level action is the registration block at the bottom (doctor.sh
# sources all checks after lib.sh, so no dispatcher edit is needed — do NOT
# also register these in doctor.sh, that would duplicate rows). Read-only:
# honors INTERCOM_STATE_ROOT, no network calls, no writes.

intercom_state_root() {
  # Mirrors common.sh ir_state_root (INTERCOM_STATE_ROOT > ~/.claude/telegram-router).
  printf '%s\n' "${INTERCOM_STATE_ROOT:-${HOME:-}/.claude/telegram-router}"
}

check_intercom_deps() {
  # Council finding: degrade gracefully with an install hint, never fail.
  local id="intercom.deps" group="intercom" mjq="" mcur="" missing
  have_cmd jq || mjq="jq"
  have_cmd curl || mcur="curl"
  missing="$mjq${mjq:+ and }$mcur"
  if [ -z "$missing" ]; then
    record "$id" "$group" "PASS" "jq and curl present" ""
  else
    record "$id" "$group" "WARN" \
      "$missing absent — intercom cannot call the Bot API" \
      "Install $missing (system package manager)"
  fi
}

check_intercom_token() {
  # Token path is fixed (SPEC-038 Security) — not under INTERCOM_STATE_ROOT.
  local id="intercom.token" group="intercom" tok="${HOME:-}/.config/telegram/bot_token" mode
  if [ ! -f "$tok" ]; then
    record "$id" "$group" "WARN" "bot_token absent — intercom not configured" "/setup telegram"
    return 0
  fi
  mode=$(stat -c %a "$tok" 2>/dev/null || stat -f %Lp "$tok" 2>/dev/null) || mode=""
  case "$mode" in
    600|0600)
      record "$id" "$group" "PASS" "bot_token mode 600" ""
      ;;
    *)
      record "$id" "$group" "WARN" \
        "bot_token is mode ${mode:-unknown}, expected 600" \
        "chmod 600 $tok"
      ;;
  esac
}

check_intercom_config() {
  local id="intercom.config" group="intercom" cfg problems="" schema members
  cfg="$(intercom_state_root)/config.json"
  if [ ! -f "$cfg" ]; then
    record "$id" "$group" "WARN" "config.json absent — intercom not configured" "/setup telegram"
    return 0
  fi
  if ! have_cmd jq; then
    record "$id" "$group" "SKIP" "jq absent — cannot validate config.json" ""
    return 0
  fi
  if ! jq empty "$cfg" >/dev/null 2>&1; then
    record "$id" "$group" "WARN" "config.json is not valid JSON" "/setup telegram"
    return 0
  fi
  # -c (not -r): keeps the JSON type, so "schema":"1" (string) is not 1.
  schema=$(jq -c '.schema' "$cfg" 2>/dev/null) || schema=""
  [ "$schema" = "1" ] || problems="schema is ${schema:-missing}, want 1"
  members=$(jq -r 'if has("members") and (.members | type == "object")
                    then (.members | length) else "bad" end' "$cfg" 2>/dev/null) || members=""
  case "$members" in
    bad|"")
      problems="${problems:+$problems; }members map missing or not an object"
      ;;
    0)
      problems="${problems:+$problems; }members map empty — allowlist is empty (nothing relays)"
      ;;
  esac
  if [ -n "$problems" ]; then
    record "$id" "$group" "WARN" "config.json: $problems" "/setup telegram"
  else
    record "$id" "$group" "PASS" "config.json parses (schema 1, members configured)" ""
  fi
}

check_intercom_offset() {
  local id="intercom.offset" group="intercom" off val=""
  off="$(intercom_state_root)/state/offset"
  if [ ! -f "$off" ]; then
    record "$id" "$group" "WARN" "state/offset absent — poller has never run" "/setup telegram"
    return 0
  fi
  IFS= read -r val < "$off" || true
  val=$(trim_ws "$val")
  case "$val" in
    '')
      record "$id" "$group" "WARN" "state/offset is empty" "/setup telegram"
      ;;
    *[!0-9]*)
      record "$id" "$group" "WARN" \
        "state/offset is not a non-negative integer: ${val:0:40}" \
        "/setup telegram"
      ;;
    *)
      record "$id" "$group" "PASS" "state/offset is $val" ""
      ;;
  esac
}

check_intercom_heartbeat() {
  local id="intercom.heartbeat" group="intercom" root hb mt="" stale_s now age
  root=$(intercom_state_root)
  hb="$root/state/heartbeat"
  if [ ! -f "$hb" ]; then
    record "$id" "$group" "WARN" "state/heartbeat absent — poller has never run" "/setup telegram"
    return 0
  fi
  mt=$(stat -c %Y "$hb" 2>/dev/null || stat -f %m "$hb" 2>/dev/null) || mt=""
  case "$mt" in
    ''|*[!0-9]*)
      record "$id" "$group" "WARN" "cannot stat state/heartbeat mtime" ""
      return 0
      ;;
  esac
  stale_s=180
  if have_cmd jq && [ -f "$root/config.json" ]; then
    stale_s=$(jq -r '.stale_heartbeat_s // 180' "$root/config.json" 2>/dev/null) || stale_s=180
    case "$stale_s" in
      ''|*[!0-9]*) stale_s=180 ;;
    esac
  fi
  now=$(date +%s)
  age=$((now - mt))
  if [ "$age" -gt "$stale_s" ]; then
    record "$id" "$group" "WARN" \
      "heartbeat stale — last poller cycle ${age}s ago (threshold ${stale_s}s); daemon or harness may be down" \
      "/setup telegram"
  else
    record "$id" "$group" "PASS" \
      "heartbeat fresh (age ${age}s, threshold ${stale_s}s)" ""
  fi
}

check_intercom_daemon() {
  # Informational: compose project intercom + heartbeat freshness (CDT-509).
  # WARN-never-FAIL. Docker absent is SKIP, never FAIL. Inspect only.
  local id="intercom.daemon" group="intercom"
  local common="$PLUGIN_ROOT/skills/intercom/common.sh"
  local cfg
  cfg="$(intercom_state_root)/config.json"
  if [ ! -f "$cfg" ]; then
    record "$id" "$group" "SKIP" "config.json absent — intercom not configured" ""
    return 0
  fi
  if [ ! -f "$common" ]; then
    record "$id" "$group" "SKIP" "skills/intercom/common.sh absent" ""
    return 0
  fi
  if ! have_cmd docker; then
    record "$id" "$group" "SKIP" \
      "docker CLI absent — cannot inspect compose project intercom" ""
    return 0
  fi
  if ( . "$common"; ir_daemon_running ); then
    record "$id" "$group" "PASS" \
      "compose project intercom / service daemon running; heartbeat fresh" ""
  else
    record "$id" "$group" "WARN" \
      "intercom daemon not running — compose project intercom down or heartbeat stale (daemon or harness)" \
      "/setup telegram"
  fi
}

check_intercom_lock() {
  # Informational: held = a poller cycle is running right now (AC22). Probed
  # read-only — `exec 9<` cannot create the file. A lock that vanishes between
  # the -f probe and the open reads as held: a benign info-line mislabel.
  local id="intercom.lock" group="intercom" lock
  lock="$(intercom_state_root)/state/poller.lock"
  if [ ! -f "$lock" ]; then
    record "$id" "$group" "PASS" "no poller.lock — poller idle" ""
    return 0
  fi
  if ! have_cmd flock; then
    record "$id" "$group" "PASS" "poller.lock present; held state unknown (flock absent)" ""
    return 0
  fi
  if ( exec 9<"$lock" && flock -n 9 ) 2>/dev/null; then
    record "$id" "$group" "PASS" "poller.lock not held — poller idle" ""
  else
    record "$id" "$group" "PASS" "poller.lock held — poller cycle running" ""
  fi
}

# ---------------------------------------------------------------------------
# Registration (source-time). doctor.sh sources every checks/*.sh after
# lib.sh, so this file carries its own register_check calls — keeps SPEC-038's
# doctor deliverable a single file. Do NOT duplicate these in doctor.sh.
# ---------------------------------------------------------------------------
register_check "intercom.deps" "intercom" check_intercom_deps
register_check "intercom.token" "intercom" check_intercom_token
register_check "intercom.config" "intercom" check_intercom_config
register_check "intercom.offset" "intercom" check_intercom_offset
register_check "intercom.heartbeat" "intercom" check_intercom_heartbeat
register_check "intercom.lock" "intercom" check_intercom_lock
register_check "intercom.daemon" "intercom" check_intercom_daemon
