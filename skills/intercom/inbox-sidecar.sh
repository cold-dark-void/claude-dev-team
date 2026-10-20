#!/usr/bin/env bash
# inbox-sidecar.sh — notify-only inbox sidecar (SPEC-038 CDT-568). Container-
# resident (compose service `sidecar`): without arguments it loops on a fixed
# sleep (SIDECAR_INTERVAL_S, default 60). With INTERCOM_SIDECAR_CYCLE=1 or
# `--cycle` it runs exactly one cycle and exits (tests, harness).
#
# Each cycle scans every spool/*/inbox/*.json — all sids, not just away_sid.
# For a sid whose per-session heartbeat (state/session/<sid>.heartbeat, T1) is
# older than session_stale_heartbeat_s (default 900; missing = stale) it sends
# ONE Telegram notice per sid per cycle — `reply received, queued to session
# <sid>` with the record count and the record qids (qid field, falling back to
# update_id) — to the operator chat (lowest numeric member id, the poller's
# deterministic outbound target) through the common tg_api `-K -` funnel: the
# token travels only via the stdin config, never argv/env/logs (AC13).
#
# Dedup (AC7): a record basename is notified at-most-once, persisted in
# state/session/<sid>.notify.seen (record filenames, one per line, tmp +
# rename) after a successful send. A record already watermarked, or already
# present in spool/<sid>/consumed/, is never notified — and inbox membership
# is re-checked immediately before the send, so a live `read --ack` wins the
# race.
#
# Fail-soft (AC8): missing token, absent spool dirs, malformed record JSON,
# and docker-down (the sidecar calls no docker at all — an engine-down state
# is fail-soft by absence) are logged to stderr and skipped; a cycle always
# exits 0.
#
# MUST NOT: move, rename, or write anything under spool/ (notify-only, never
# acks); start a second getUpdates consumer; take state/poller.lock; touch
# state/offset, state/seen.tsv, state/away, state/away_sid, or
# state/inbox.stamp (AC9). bash+jq+curl only (AC21).
set -u

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=common.sh
. "$SCRIPT_DIR/common.sh"

if [ "${BASH_SOURCE[0]}" != "$0" ]; then
  echo "inbox-sidecar.sh is a subprocess CLI (SPEC-038); source common.sh for the library." >&2
  return 1
fi

ir_require_tools jq curl || exit 1

ROOT=$(ir_state_root)
if [ -d "$ROOT" ]; then
  ROOT=$(CDPATH= cd -- "$ROOT" && pwd) || ROOT=$(ir_state_root)
fi

# Container cadence: fixed sleep, minimum 1 s (default 60).
INTERVAL_S="${SIDECAR_INTERVAL_S:-60}"
case "$INTERVAL_S" in ''|*[!0-9]*) INTERVAL_S=60 ;; esac
[ "$INTERVAL_S" -ge 1 ] || INTERVAL_S=60

warn() { printf 'sidecar: %s\n' "$*" >&2; }

# operator_chat — lowest numeric member chat id, the same deterministic
# outbound target as the poller (AC25). Unpaired (no config, no numeric
# member) is fail-soft: warn and rc 1 — nothing may be notified anywhere.
operator_chat() {
  local cfg chat
  cfg="$ROOT/config.json"
  if [ ! -f "$cfg" ]; then
    warn "no config.json at $cfg — run /setup telegram; nothing to notify"
    return 1
  fi
  chat=$(jq -r '[.members // {} | keys[] | select(test("^[0-9]+$")) | tonumber] | min // empty' "$cfg" 2>/dev/null) || chat=""
  case "$chat" in
    ''|*[!0-9]*)
      warn "no numeric member chat id in $cfg — unpaired; nothing to notify"
      return 1
      ;;
  esac
  printf '%s\n' "$chat"
}

# publish_seen SID NAME... — append the notified record basenames to
# state/session/<sid>.notify.seen via tmp + rename. rc 1 keeps the record
# unwatermarked, so the next cycle retries (at-least-once until persisted).
publish_seen() {
  local sid="$1" sessdir tmp name
  shift
  sessdir="$ROOT/state/session"
  mkdir -m 700 -p "$sessdir" 2>/dev/null \
    || { warn "cannot create $sessdir; watermark not persisted"; return 1; }
  tmp=$(mktemp "$sessdir/.seen.XXXXXX") \
    || { warn "cannot create watermark temp for $sid"; return 1; }
  if [ -f "$sessdir/$sid.notify.seen" ]; then
    cat "$sessdir/$sid.notify.seen" > "$tmp" \
      || { rm -f "$tmp"; warn "cannot read watermark for $sid"; return 1; }
  fi
  for name in "$@"; do
    printf '%s\n' "$name" >> "$tmp" \
      || { rm -f "$tmp"; warn "cannot write watermark for $sid"; return 1; }
  done
  chmod 600 "$tmp" 2>/dev/null || true
  mv -f "$tmp" "$sessdir/$sid.notify.seen" \
    || { rm -f "$tmp"; warn "cannot publish watermark for $sid"; return 1; }
  return 0
}

# notify_sid CHAT SID STALE_S INBOX — at most one notice for SID this cycle.
notify_sid() {
  local chat="$1" sid="$2" stale="$3" inbox="$4"
  local age rec base qid qid_list n i resp ok
  age=$(ir_session_heartbeat_age "$sid" 2>/dev/null) || age=""
  # Missing/unreadable heartbeat counts as stale (fail-notify, CDT-568).
  if [ -n "$age" ] && [ "$age" -le "$stale" ]; then
    return 0
  fi
  local seen="$ROOT/state/session/$sid.notify.seen"
  local -a names=() qids=() live_names=() live_qids=()
  for rec in "$inbox"/*.json; do
    [ -f "$rec" ] || continue
    base=${rec##*/}
    case $base in
      *.ack*) continue ;;
    esac
    # A basename under spool/<sid>/consumed/ is the acked signal (CDT-568).
    [ -e "$ROOT/spool/$sid/consumed/$base" ] && continue
    # Already notified: the persisted watermark is the at-most-once guarantee.
    if [ -f "$seen" ] && grep -Fxq -- "$base" "$seen"; then
      continue
    fi
    qid=$(jq -r '(.qid // .update_id // empty)' "$rec" 2>/dev/null) || qid=""
    if [ -z "$qid" ]; then
      warn "record is malformed or carries no qid/update_id; skipped: $rec"
      continue
    fi
    names+=("$base")
    qids+=("qid=$qid")
  done
  [ ${#names[@]} -gt 0 ] || return 0
  # Re-check inbox membership right before the send: a live `read --ack` that
  # moves a record to consumed/ wins the race (SPEC-038 § Inbox sidecar).
  for i in "${!names[@]}"; do
    [ -f "$inbox/${names[$i]}" ] || continue
    live_names+=("${names[$i]}")
    live_qids+=("${qids[$i]}")
  done
  [ ${#live_names[@]} -gt 0 ] || return 0
  n=${#live_names[@]}
  qid_list=$(printf '%s, ' "${live_qids[@]}")
  qid_list=${qid_list%, }
  if ! resp=$(tg_api sendMessage \
      -F "chat_id=$chat" \
      -F "text=reply received, queued to session $sid: $n record(s) ($qid_list)" \
      --max-time 15); then
    warn "sendMessage transport failure for session $sid; will retry next cycle"
    return 0
  fi
  ok=$(jq -r '.ok // false' <<<"$resp" 2>/dev/null) || ok=false
  if [ "$ok" != "true" ]; then
    warn "sendMessage rejected for session $sid: $(jq -r '(.description // "unknown error") | .[0:200]' <<<"$resp" 2>/dev/null || echo 'unparseable response')"
    return 0
  fi
  publish_seen "$sid" "${live_names[@]}" || warn "notify dedupe for $sid degrades this cycle"
  return 0
}

# sidecar_cycle — one full scan; every failure is logged and skipped, and the
# cycle exits 0 (AC8).
sidecar_cycle() {
  local chat stale inbox sid
  chat=$(operator_chat) || return 0
  stale=$(ir_session_stale_s)
  for inbox in "$ROOT"/spool/*/inbox; do
    [ -d "$inbox" ] || continue
    sid=${inbox%/}
    sid=${sid%/*}
    sid=${sid##*/}
    if ! ir_sane_sid "$sid"; then
      warn "spool directory is not a usable sid; skipped: $inbox"
      continue
    fi
    notify_sid "$chat" "$sid" "$stale" "$inbox"
  done
  return 0
}

one_shot=0
for arg in "$@"; do
  case $arg in
    --cycle) one_shot=1 ;;
    *)
      echo "inbox-sidecar: unknown argument: $arg (usage: inbox-sidecar.sh [--cycle])" >&2
      exit 2
      ;;
  esac
done
[ "${INTERCOM_SIDECAR_CYCLE:-}" = "1" ] && one_shot=1

if [ "$one_shot" -eq 1 ]; then
  sidecar_cycle
  exit 0
fi

while :; do
  sidecar_cycle || true
  sleep "$INTERVAL_S"
done
