#!/usr/bin/env bash
# common.sh — shared library for the intercom spool protocol (SPEC-038).
# Sourced by intercom.sh, poller.sh, watch.sh, setup-telegram.sh, probe.sh and the
# hermetic suites. It is a library: it defines functions and exits; it never
# performs I/O on its own. The two CLIs (intercom.sh, poller.sh) are never
# sourced.
#
# Responsibilities:
#   ir_state_root      state root (~/.claude/telegram-router, INTERCOM_STATE_ROOT override)
#   ir_token_read      token from ~/.config/telegram/bot_token (0600)
#   tg_api             the single curl funnel (token via `-K -` stdin config, never argv)
#   ir_resolve_sid     sid resolution (--sid > INTERCOM_SID > CLAUDE_SESSION_ID > newest transcript dir)
#   ir_spool_dir       spool/<sid>/<bucket> path + creation
#   ir_record_tmp / ir_record_publish   atomic spool record writes (tmp + mv)
#   ir_outbox_write / ir_pending_write  record builders
#   ir_config_field    read config.json (schema 1); never creates it
#   ir_away_sid_read   first-line, edge-trimmed state/away_sid read (CDT-535)
#   ir_away_sid_write  state/away_sid atomic bare-sid publish (CDT-535)
#   ir_require_tools   graceful jq/curl absence (AC21)
#   ir_daemon_running  heartbeat fresh AND compose project intercom up (CDT-509 AC10)
#   ir_docker_available  CLI + compose v2 + engine (CDT-527 AC1; inspect only)
#   ir_daemon_identity_running  compose/label only, no heartbeat (CDT-527 AC3)
#   ir_lock_held       poller.lock exists and flock -n fails (CDT-527 AC6)
#
# Exit-code contract for the CLIs: 0 success, 1 operational failure, 2
# usage/sid failure. Library helpers return nonzero on their own failure.
set -u
# Spool records carry member conversations. Same sensitivity as ~/.claude/projects.
umask 077

# Reuse the plugin's portability helpers (atomic_write, sha256, lock, timeout).
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=../lib/portable.sh
. "$SCRIPT_DIR/../lib/portable.sh"

# ---- state root ---------------------------------------------------------------

ir_state_root() {
  # Runtime state is box-level (AC23). INTERCOM_STATE_ROOT reroutes it for tests.
  printf '%s\n' "${INTERCOM_STATE_ROOT:-$HOME/.claude/telegram-router}"
}

# ---- tools --------------------------------------------------------------------

ir_require_tools() {
  # ir_require_tools TOOL... — actionable one-liner instead of a stack trace (AC21).
  local t missing=""
  for t in "$@"; do
    command -v "$t" >/dev/null 2>&1 || missing="$missing $t"
  done
  if [ -n "$missing" ]; then
    printf 'intercom: missing required tool(s):%s — install jq and curl (SPEC-038 AC21: bash/jq/curl only).\n' "$missing" >&2
    return 1
  fi
  return 0
}

# ---- token --------------------------------------------------------------------

ir_token_read() {
  # Token comes only from ~/.config/telegram/bot_token (0600). HOME is the
  # override seam: hermetic suites point HOME at a temp root. Prints the token;
  # never logs it.
  local f="$HOME/.config/telegram/bot_token" tok mode
  if [ ! -f "$f" ]; then
    echo "intercom: no bot token at $f — run /setup telegram first." >&2
    return 1
  fi
  mode=$(stat -c %a "$f" 2>/dev/null || stat -f %Lp "$f" 2>/dev/null) || mode=""
  case "$mode" in
    600|0600) ;;
    *)
      # WARN and continue: the doctor check (SPEC-037 posture) owns the finding;
      # refusing here would only break the member's intercom without fixing mode.
      echo "intercom: warning: $f is mode ${mode:-unknown}, expected 600 — fix with chmod 600." >&2
      ;;
  esac
  tok=$(tr -d ' \t\r\n' < "$f")
  if [ -z "$tok" ]; then
    echo "intercom: token file $f is empty — run /setup telegram." >&2
    return 1
  fi
  printf '%s\n' "$tok"
}

ir_scrub_token() {
  # ir_scrub_token FILE TOKEN — literal (non-regex) token scrub on stderr text.
  # Council finding: curl can echo the request URL, which embeds the token, so
  # captured stderr is scrubbed before it is re-emitted.
  local file="$1" token="$2"
  awk -v tok="$token" '
    {
      line = $0
      while ((i = index(line, tok)) > 0) {
        line = substr(line, 1, i - 1) "[scrubbed]" substr(line, i + length(tok))
      }
      print line
    }' "$file"
}

tg_api() {
  # tg_api METHOD [curl-args...] — the single funneled Telegram API call.
  # The URL (bot<TOKEN>/METHOD) is passed to curl via a `-K -` stdin config, so
  # the token never appears in argv (AC4). Body/form options travel as argv —
  # they carry message text, never the token. Callers pass their own
  # `--max-time`; the funnel never retries. Response body on stdout; curl rc is
  # the function rc. Callers MUST NOT pass `-K`.
  if [ $# -lt 1 ]; then
    echo "tg_api: usage: tg_api METHOD [curl-args...]" >&2
    return 1
  fi
  ir_require_tools curl || return 1
  local method="$1"
  shift
  local token errfile rc=0
  token=$(ir_token_read) || return $?
  errfile=$(mktemp "${TMPDIR:-/tmp}/tg_api.err.XXXXXX") || return 1
  printf 'url = "https://api.telegram.org/bot%s/%s"\n' "$token" "$method" \
    | curl -sS -K - "$@" 2> "$errfile"
  rc=$?
  if [ -s "$errfile" ]; then
    ir_scrub_token "$errfile" "$token" >&2
  fi
  rm -f "$errfile"
  return "$rc"
}

# ---- sid ----------------------------------------------------------------------

ir_sane_sid() {
  # sid becomes a path segment under spool/. Reject traversal and metacharacters.
  local sid="$1"
  case "$sid" in
    ''|.|..|.*) return 1 ;;
    *..*) return 1 ;;
  esac
  case "$sid" in
    *[!A-Za-z0-9._-]*) return 1 ;;
  esac
  [ ${#sid} -le 128 ] || return 1
  return 0
}

ir_epoch_ms() {
  # Filename ordering key. GNU date gives real milliseconds; BSD date falls
  # back to second precision padded to ms width (suffixes still disambiguate).
  local probe
  probe=$(date +%N 2>/dev/null)
  case "$probe" in
    ''|*[!0-9]*) printf '%s000\n' "$(date +%s)" ;;
    *) date +%s%3N ;;
  esac
}

ir_resolve_sid() {
  # ir_resolve_sid EXPLICIT_OR_EMPTY — prints the sid or fails.
  # Order (SPEC-038): --sid > INTERCOM_SID > CLAUDE_SESSION_ID > newest dir
  # under ~/.claude/transcript/ (best-effort). Unresolvable -> rc 1.
  local explicit="${1:-}" sid="" best="" d root
  if [ -n "$explicit" ]; then
    if ir_sane_sid "$explicit"; then
      printf '%s\n' "$explicit"
      return 0
    fi
    echo "intercom: invalid --sid '$explicit' (allowed: letters, digits, dot, dash, underscore)" >&2
    return 1
  fi
  sid="${INTERCOM_SID:-}"
  if [ -n "$sid" ]; then
    if ! ir_sane_sid "$sid"; then
      echo "intercom: INTERCOM_SID is not a usable sid" >&2
      return 1
    fi
    printf '%s\n' "$sid"
    return 0
  fi
  sid="${CLAUDE_SESSION_ID:-}"
  if [ -n "$sid" ]; then
    if ! ir_sane_sid "$sid"; then
      echo "intercom: CLAUDE_SESSION_ID is not a usable sid" >&2
      return 1
    fi
    printf '%s\n' "$sid"
    return 0
  fi
  # Best-effort: the active session owns the newest transcript-mirror dir.
  # TRANSCRIPT_MIRROR_ROOT is the transcript-mirror harness override; honoring
  # it keeps suites hermetic without a second knob.
  root="${TRANSCRIPT_MIRROR_ROOT:-$HOME/.claude/transcript}"
  if [ -d "$root" ]; then
    for d in "$root"/*/; do
      [ -d "$d" ] || continue
      d="${d%/}"
      if [ -z "$best" ] || [ "$d" -nt "$best" ]; then
        best="$d"
      fi
    done
  fi
  if [ -n "$best" ]; then
    sid="${best##*/}"
    if ir_sane_sid "$sid"; then
      printf '%s\n' "$sid"
      return 0
    fi
  fi
  echo "intercom: no session id — pass --sid S, or set INTERCOM_SID / CLAUDE_SESSION_ID (no transcript dir found)" >&2
  return 1
}

# ---- spool --------------------------------------------------------------------

ir_spool_dir() {
  # ir_spool_dir SID BUCKET — prints spool/<sid>/<bucket>, creating it 0700.
  # consumed (CDT-535) holds inbox records drained by `intercom read --ack`.
  local sid="$1" bucket="$2" root
  case "$bucket" in
    inbox|outbox|pending|answered|consumed) ;;
    *)
      echo "ir_spool_dir: bad bucket '$bucket'" >&2
      return 1
      ;;
  esac
  ir_sane_sid "$sid" || { echo "ir_spool_dir: bad sid" >&2; return 1; }
  root=$(ir_state_root)
  if ! mkdir -m 700 -p "$root/spool/$sid/$bucket"; then
    echo "intercom: cannot create $root/spool/$sid/$bucket" >&2
    return 1
  fi
  printf '%s\n' "$root/spool/$sid/$bucket"
}

ir_state_dir() {
  # ir_state_dir — prints <root>/state, creating it 0700 (away, offset, heartbeat...).
  # mkdir -m 700 -p does not tighten an existing dir; chmod 700 when present.
  local root
  root=$(ir_state_root)
  if [ -d "$root/state" ]; then
    if ! chmod 700 "$root/state"; then
      echo "intercom: cannot chmod 700 $root/state" >&2
      return 1
    fi
  fi
  if ! mkdir -m 700 -p "$root/state"; then
    echo "intercom: cannot create $root/state" >&2
    return 1
  fi
  printf '%s\n' "$root/state"
}

ir_record_tmp() {
  # ir_record_tmp DIR PREFIX — unique hidden temp file inside DIR; prints the
  # path. The hidden name is invisible to *.json readers; ir_record_publish
  # reuses the mktemp suffix for the final name, so the record appears
  # atomically and uniqueness is by construction (no check-then-act).
  local dir="$1" prefix="$2" tmp
  tmp=$(mktemp "$dir/.${prefix}.XXXXXX") || { echo "intercom: cannot create temp record in $dir" >&2; return 1; }
  printf '%s\n' "$tmp"
}

ir_record_publish() {
  # ir_record_publish TMP FINAL — chmod 600 + atomic rename onto the record name.
  local tmp="$1" final="$2"
  chmod 600 "$tmp" 2>/dev/null || true
  if ! mv -f "$tmp" "$final"; then
    rm -f "$tmp"
    echo "intercom: cannot publish record $final" >&2
    return 1
  fi
  printf '%s\n' "$final"
}

ir_outbox_write() {
  # ir_outbox_write SID TEXT SUMMARY FILE — one outbox record; prints its path.
  # Empty summary/file are omitted from the JSON (optional fields). Optional
  # per-part delivery flags summary_sent / text_sent (CDT-530) are absent on a
  # fresh record: absent = part not yet sent, so records written by earlier
  # versions drain unchanged. The poller adds the flag after that part is
  # delivered; deletion happens only after all parts succeed. Filename is
  # <epoch_ms>_0_<rand>.json: the epoch_ms prefix keeps drain order chronological
  # and _0 marks update_id 0 (not a Telegram update); the random suffix keeps
  # same-millisecond writes unique. Poller-written inbox records use the spec
  # shape <epoch_ms>_<update_id>.json.
  local sid="$1" text="$2" summary="$3" file="$4" dir tmp name json
  dir=$(ir_spool_dir "$sid" outbox) || return 1
  tmp=$(ir_record_tmp "$dir" ob) || return 1
  name="$(ir_epoch_ms)_0_${tmp##*.ob.}.json"
  if ! json=$(jq -n \
      --arg sid "$sid" --arg text "$text" --arg summary "$summary" --arg file "$file" \
      --arg ts "$(date +%s)" '
      {ts: ($ts|tonumber), sid: $sid, dir: "out", kind: "message",
       text: $text, from_id: 0, update_id: 0, thread_id: 0}
      + (if $summary == "" then {} else {summary: $summary} end)
      + (if $file == "" then {} else {file: $file} end)'); then
    rm -f "$tmp"
    echo "intercom: cannot build outbox record" >&2
    return 1
  fi
  printf '%s\n' "$json" > "$tmp" || { rm -f "$tmp"; echo "intercom: cannot write outbox record" >&2; return 1; }
  ir_record_publish "$tmp" "$dir/$name"
}

ir_pending_write() {
  # ir_pending_write SID TEXT — one pending question; prints the qid.
  # <qid>.json: {"qid","sid","text","asked_at","escalated":false,"escalated_at":null,
  #              "route":{"sid":...,"thread_id":...}}
  local sid="$1" text="$2" dir tmp qid json tid root
  dir=$(ir_spool_dir "$sid" pending) || return 1
  tmp=$(ir_record_tmp "$dir" q) || return 1
  qid="q_$(date +%s)_${tmp##*.q.}"
  root=$(ir_state_root)
  tid=$(jq -r --arg sid "$sid" '(.[$sid].thread_id // empty)' "$root/topics.json" 2>/dev/null)
  case "$tid" in ''|*[!0-9]*) tid=null ;; *) tid="$tid" ;; esac
  if ! json=$(jq -n \
      --arg qid "$qid" --arg sid "$sid" --arg text "$text" --arg asked_at "$(date +%s)" \
      --argjson tid "$tid" '
      {qid: $qid, sid: $sid, text: $text, asked_at: ($asked_at|tonumber),
       escalated: false, escalated_at: null,
       route: {sid: $sid, thread_id: $tid}}'); then
    rm -f "$tmp"
    echo "intercom: cannot build pending record" >&2
    return 1
  fi
  printf '%s\n' "$json" > "$tmp" || { rm -f "$tmp"; echo "intercom: cannot write pending record" >&2; return 1; }
  ir_record_publish "$tmp" "$dir/$qid.json" >/dev/null || return 1
  printf '%s\n' "$qid"
}

# ---- away endpoint (CDT-535) ---------------------------------------------------

ir_away_sid_read() {
  # ir_away_sid_read — prints the away endpoint sid from state/away_sid (CDT-535).
  # Reads the FIRST line only and trims leading/trailing whitespace with the
  # doctor's exact edge-trim idiom (skills/doctor/checks/intercom.sh). Internal
  # whitespace survives the trim and fails the callers' sid sanity check — it
  # is never stripped, so "walkie talkie" cannot collapse into a phantom sid.
  local f raw s
  f="$(ir_state_root)/state/away_sid"
  [ -f "$f" ] || return 1
  # `|| true`: a last line without a newline still fills raw (then fails sane).
  IFS= read -r raw < "$f" || true
  # Trim leading whitespace.
  s="${raw#"${raw%%[![:space:]]*}"}"
  # Trim trailing whitespace.
  s="${s%"${s##*[![:space:]]}"}"
  [ -n "$s" ] || return 1
  printf '%s\n' "$s"
}

ir_away_sid_write() {
  # ir_away_sid_write SID — atomically publish the away endpoint sid
  # (state/away_sid, bare sid content) under the tmp+rename rule. Sanity-checked
  # like every sid that becomes a path segment; rc 1 on a bad sid or a failed
  # write. Advisory, last-writer-wins (SPEC-038 § Away mode).
  local sid="$1" statedir
  ir_sane_sid "$sid" || { echo "intercom: not a usable sid: $sid" >&2; return 1; }
  statedir=$(ir_state_dir) || return 1
  atomic_write "$statedir/away_sid" printf '%s\n' "$sid" || {
    echo "intercom: cannot write $statedir/away_sid" >&2
    return 1
  }
}

# ---- config -------------------------------------------------------------------

ir_config_field() {
  # ir_config_field KEY DEFAULT — one top-level config.json value, else DEFAULT.
  # Reads only; never creates config.json (T4 owns setup). Invalid JSON is
  # reported once and degrades to the default.
  local key="$1" def="$2" root cfg v=""
  root=$(ir_state_root)
  cfg="$root/config.json"
  if [ -f "$cfg" ]; then
    if ! v=$(jq -r --arg k "$key" '(.[$k] // empty)' "$cfg" 2>/dev/null); then
      echo "intercom: $cfg is not valid JSON; using default for $key" >&2
      v=""
    fi
  fi
  if [ -n "$v" ]; then
    printf '%s\n' "$v"
  else
    printf '%s\n' "$def"
  fi
}

# ---- docker availability (CDT-527 AC1) ---------------------------------------

ir_docker_available() {
  # rc 0: command -v docker AND `docker compose version` AND `docker info`
  # (stdout+stderr of those commands discarded). rc 0 stdout is empty.
  # rc 1: first miss. stdout is exactly one of: "docker CLI" | "compose v2" | "engine".
  # Inspect only. Never pull, run, or print a token.
  if ! command -v docker >/dev/null 2>&1; then
    printf '%s\n' "docker CLI"
    return 1
  fi
  if ! docker compose version >/dev/null 2>&1; then
    printf '%s\n' "compose v2"
    return 1
  fi
  if ! docker info >/dev/null 2>&1; then
    printf '%s\n' "engine"
    return 1
  fi
  return 0
}

# ---- daemon detect (CDT-509 AC10 / CDT-527 AC3) ------------------------------

_ir_compose_json_up() {
  # stdin: one JSON value (object or array). rc 0 iff a running daemon identity.
  jq -e '
    def running: ((.State // "") | ascii_downcase) == "running";
    def daemon_id:
      (.Service == "daemon")
      or ((.Labels // "") | tostring | contains("dev-team.intercom=daemon"));
    def project:
      (.Project // "") == "intercom"
      or ((.Labels // "") | tostring | contains("dev-team.intercom"));
    if type == "array" then
      any(.[]?; running and daemon_id and project)
    elif type == "object" then
      running and daemon_id and project
    else
      false
    end' >/dev/null 2>&1
}

ir_compose_ps_running() {
  # ir_compose_ps_running BLOB — rc 0 when BLOB names a running compose
  # identity: project intercom, service daemon, label dev-team.intercom=daemon.
  # One JSON object, a JSON array, or NDJSON mixed with non-JSON lines.
  local blob="$1" line
  [ -n "$blob" ] || return 1
  if printf '%s\n' "$blob" | _ir_compose_json_up; then
    return 0
  fi
  while IFS= read -r line || [ -n "$line" ]; do
    [ -n "$line" ] || continue
    printf '%s\n' "$line" | _ir_compose_json_up && return 0
  done < <(printf '%s\n' "$blob")
  return 1
}

ir_daemon_identity_running() {
  # rc 0 iff compose project intercom / service daemon / label
  # dev-team.intercom=daemon is running. No heartbeat conjunct. Reuse
  # ir_compose_ps_running. Fail closed: no docker / compose down → rc 1.
  # Inspect only. Never pull, run, or print a token.
  local out
  command -v docker >/dev/null 2>&1 || return 1
  out=$(docker compose -p intercom ps --format json 2>/dev/null) || out=""
  ir_compose_ps_running "$out" && return 0
  out=$(docker ps --filter "label=dev-team.intercom=daemon" --filter "status=running" --format json 2>/dev/null) || out=""
  ir_compose_ps_running "$out"
}

ir_daemon_running() {
  # rc 0 iff state/heartbeat mtime age <= stale_heartbeat_s (default 180)
  # AND compose project intercom / service daemon / label
  # dev-team.intercom=daemon is running. Fail closed: missing heartbeat,
  # stale heartbeat, missing docker CLI, or compose down → rc 1. Inspect
  # only (compose ps / docker ps). Never pull, run, or print a token.
  local root hb stale mtime now age
  root=$(ir_state_root)
  hb="$root/state/heartbeat"
  [ -f "$hb" ] || return 1
  stale=$(ir_config_field stale_heartbeat_s 180)
  case "$stale" in ''|*[!0-9]*) stale=180 ;; esac
  mtime=$(stat -c %Y "$hb" 2>/dev/null || stat -f %m "$hb" 2>/dev/null) || return 1
  case "$mtime" in ''|*[!0-9]*) return 1 ;; esac
  now=$(date +%s)
  age=$((now - mtime))
  [ "$age" -le "$stale" ] || return 1
  ir_daemon_identity_running
}

ir_lock_held() {
  # rc 0 if $root/state/poller.lock exists AND flock -n fails (held).
  # rc 1 if absent or not held. Read-only open (`exec 9<`); do not create
  # the lock file (flock FILE would).
  local root lock rc
  root=$(ir_state_root)
  lock="$root/state/poller.lock"
  [ -f "$lock" ] || return 1
  exec 9<"$lock" || return 1
  flock -n 9
  rc=$?
  exec 9<&-
  [ "$rc" -ne 0 ]
}

# ---- longread -----------------------------------------------------------------

ir_gen_summary() {
  # First paragraph, capped at 280 chars (SPEC-038 Longread). jq length counts
  # Unicode codepoints, so the cap cannot split a multibyte character.
  local text="$1"
  jq -rn --arg text "$text" \
    '($text | split("\n\n") | map(select(length > 0)) | .[0]) // "" | if length > 280 then .[0:280] else . end'
}
