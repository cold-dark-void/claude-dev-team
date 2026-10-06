#!/usr/bin/env bash
# common.sh — shared library for the intercom spool protocol (SPEC-038).
# Sourced by intercom.sh, poller.sh, setup-telegram.sh, probe.sh and the
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
#   ir_require_tools   graceful jq/curl absence (AC21)
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
  local sid="$1" bucket="$2" root
  case "$bucket" in
    inbox|outbox|pending|answered) ;;
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
  local root
  root=$(ir_state_root)
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
  # Empty summary/file are omitted from the JSON (optional fields). Filename is
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
  # <qid>.json: {"qid","sid","text","asked_at","escalated":false,"escalated_at":null}
  local sid="$1" text="$2" dir tmp qid json
  dir=$(ir_spool_dir "$sid" pending) || return 1
  tmp=$(ir_record_tmp "$dir" q) || return 1
  qid="q_$(date +%s)_${tmp##*.q.}"
  if ! json=$(jq -n \
      --arg qid "$qid" --arg sid "$sid" --arg text "$text" --arg asked_at "$(date +%s)" '
      {qid: $qid, sid: $sid, text: $text, asked_at: ($asked_at|tonumber),
       escalated: false, escalated_at: null}'); then
    rm -f "$tmp"
    echo "intercom: cannot build pending record" >&2
    return 1
  fi
  printf '%s\n' "$json" > "$tmp" || { rm -f "$tmp"; echo "intercom: cannot write pending record" >&2; return 1; }
  ir_record_publish "$tmp" "$dir/$qid.json" >/dev/null || return 1
  printf '%s\n' "$qid"
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

# ---- longread -----------------------------------------------------------------

ir_gen_summary() {
  # First paragraph, capped at 280 chars (SPEC-038 Longread). jq length counts
  # Unicode codepoints, so the cap cannot split a multibyte character.
  local text="$1"
  jq -rn --arg text "$text" \
    '($text | split("\n\n") | map(select(length > 0)) | .[0]) // "" | if length > 280 then .[0:280] else . end'
}
