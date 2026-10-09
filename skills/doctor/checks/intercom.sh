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

_intercom_unconfigured() { # _intercom_unconfigured "$id" "$group" && return 0
  local cfg
  cfg="$(intercom_state_root)/config.json"
  if [ ! -f "$cfg" ]; then
    record "$1" "$2" "SKIP" "config.json absent — intercom not configured" ""
    return 0
  fi
  return 1
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
  _intercom_unconfigured "$id" "$group" && return 0
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
# CDT-532 / SPEC-022 M2k — Intercom/away surface. WARN-never-FAIL. Read-only.
# State root is INTERCOM_STATE_ROOT (default ~/.claude/telegram-router), never
# $MROOT/.claude/telegram-router. --fix MUST NOT repair these ids.
# ---------------------------------------------------------------------------

check_intercom_away() {
  local id="intercom.away" group="intercom" root away val now age
  _intercom_unconfigured "$id" "$group" && return 0
  root=$(intercom_state_root)
  away="$root/state/away"
  if [ ! -f "$away" ]; then
    record "$id" "$group" "PASS" "away: off" ""
    return 0
  fi
  IFS= read -r val < "$away" || true
  val=$(trim_ws "$val")
  case "$val" in
    ''|*[!0-9]*)
      record "$id" "$group" "WARN" \
        "state/away is not a numeric epoch: ${val:0:40}" \
        "/away off"
      return 0
      ;;
  esac
  now=$(date +%s)
  age=$((now - val))
  if wt_status_has FRESH; then
    record "$id" "$group" "WARN" \
      "away: on (age ${age}s) — routing-mismatch risk (FRESH .wt-lock under .worktrees/)" \
      "/away off"
  else
    record "$id" "$group" "PASS" "away: on (age ${age}s)" ""
  fi
}

check_intercom_topics() {
  local id="intercom.topics" group="intercom" root topics typ
  _intercom_unconfigured "$id" "$group" && return 0
  root=$(intercom_state_root)
  if ! have_cmd jq; then
    record "$id" "$group" "SKIP" "jq absent — cannot validate topics.json" ""
    return 0
  fi
  topics="$root/topics.json"
  if [ ! -f "$topics" ]; then
    record "$id" "$group" "WARN" "topics.json absent" "/setup telegram"
    return 0
  fi
  if ! jq empty "$topics" >/dev/null 2>&1; then
    record "$id" "$group" "WARN" "topics.json is not valid JSON" "/setup telegram"
    return 0
  fi
  typ=$(jq -r 'type' "$topics" 2>/dev/null) || typ=""
  if [ "$typ" != "object" ]; then
    record "$id" "$group" "WARN" \
      "topics.json is not a JSON object (type ${typ:-unknown})" \
      "/setup telegram"
    return 0
  fi
  record "$id" "$group" "PASS" "topics.json is a JSON object" ""
}

check_intercom_spool() {
  local id="intercom.spool" group="intercom" root spool
  _intercom_unconfigured "$id" "$group" && return 0
  root=$(intercom_state_root)
  spool="$root/spool"
  if [ ! -d "$spool" ]; then
    record "$id" "$group" "WARN" "spool/ missing" "/setup telegram"
    return 0
  fi
  if [ ! -w "$spool" ]; then
    record "$id" "$group" "WARN" "spool/ not writable by the current uid" \
      "/setup telegram"
    return 0
  fi
  record "$id" "$group" "PASS" "spool/ present and writable" ""
}

check_intercom_poller_stale() {
  # Inspect-only: docker inspect for /plugin bind-mount Source, then cmp on
  # the host. Never invoke pull, run, or exec. Identity via common.sh.
  local id="intercom.poller_stale" group="intercom"
  local common plugin_poller cid src mount_poller
  _intercom_unconfigured "$id" "$group" && return 0
  if ! have_cmd docker; then
    record "$id" "$group" "SKIP" \
      "docker CLI absent — cannot inspect compose project intercom" ""
    return 0
  fi
  common="$PLUGIN_ROOT/skills/intercom/common.sh"
  plugin_poller="$PLUGIN_ROOT/skills/intercom/poller.sh"
  if [ ! -f "$common" ]; then
    record "$id" "$group" "SKIP" "skills/intercom/common.sh absent" ""
    return 0
  fi
  if [ ! -f "$plugin_poller" ]; then
    record "$id" "$group" "SKIP" "skills/intercom/poller.sh absent" ""
    return 0
  fi
  if ! ( . "$common"; ir_daemon_identity_running ); then
    record "$id" "$group" "SKIP" \
      "compose project intercom identity not running" ""
    return 0
  fi
  cid=$(docker ps -q --filter "label=dev-team.intercom=daemon" \
    --filter "status=running" 2>/dev/null | head -n 1) || true
  cid=$(trim_ws "$cid")
  if [ -z "$cid" ]; then
    cid=$(docker compose -p intercom ps -q daemon 2>/dev/null | head -n 1) || true
    cid=$(trim_ws "$cid")
  fi
  if [ -z "$cid" ]; then
    record "$id" "$group" "SKIP" \
      "compose project intercom identity not running" ""
    return 0
  fi
  src=$(docker inspect --format \
    '{{range .Mounts}}{{if eq .Destination "/plugin"}}{{.Source}}{{end}}{{end}}' \
    "$cid" 2>/dev/null) || src=""
  src=$(trim_ws "$src")
  if [ -z "$src" ]; then
    record "$id" "$group" "SKIP" \
      "no /plugin bind-mount on compose project intercom" ""
    return 0
  fi
  mount_poller="$src/skills/intercom/poller.sh"
  if [ ! -f "$mount_poller" ]; then
    record "$id" "$group" "WARN" \
      "stale poller — /plugin bind-mount poller.sh missing at Source" \
      "/setup telegram"
    return 0
  fi
  if ! have_cmd cmp; then
    record "$id" "$group" "SKIP" "cmp absent — cannot compare poller.sh" ""
    return 0
  fi
  if cmp -s "$mount_poller" "$plugin_poller"; then
    record "$id" "$group" "PASS" \
      "poller.sh at /plugin bind-mount Source matches PLUGIN_ROOT" ""
  else
    record "$id" "$group" "WARN" \
      "stale poller — /plugin bind-mount poller.sh differs from PLUGIN_ROOT" \
      "/setup telegram"
  fi
}

check_intercom_slack() {
  # Stub posture only. Do not probe a Slack sidecar or compose project.
  # Reads commands/setup.md only.
  local id="intercom.slack" group="intercom"
  local setup="$PLUGIN_ROOT/commands/setup.md"
  if [ ! -f "$setup" ]; then
    record "$id" "$group" "WARN" \
      "commands/setup.md absent — cannot confirm /setup slack stub" \
      "restore commands/setup.md Slack stub (Slack ships in v1.1/v2.)"
    return 0
  fi
  if grep -qF 'Slack ships in v1.1/v2.' "$setup"; then
    record "$id" "$group" "PASS" "Slack ships in v1.1/v2." ""
  else
    record "$id" "$group" "WARN" \
      "commands/setup.md missing /setup slack stub sentence" \
      "restore commands/setup.md Slack stub (Slack ships in v1.1/v2.)"
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
register_check "intercom.away" "intercom" check_intercom_away
register_check "intercom.topics" "intercom" check_intercom_topics
register_check "intercom.spool" "intercom" check_intercom_spool
register_check "intercom.poller_stale" "intercom" check_intercom_poller_stale
register_check "intercom.slack" "intercom" check_intercom_slack
