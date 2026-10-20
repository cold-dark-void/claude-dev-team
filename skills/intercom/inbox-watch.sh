#!/usr/bin/env bash
# inbox-watch.sh — session-driven away monitor (CDT-535). Subprocess CLI:
# never sourced. While state/away is present it watches spool/<away_sid>/inbox/
# and prints the § Host adapter wake grammar once per new-record batch, so the
# away session can drain its inbox each turn (pickup protocol). It is not a
# bridge or adapter cycle: the away-gated loop is session-driven and out of
# scope of the one-shot rule (SPEC-038 CDT-535 AC8). It never starts a second
# updates consumer, never reads the bot token, never touches the adapter
# watermark, and never creates or takes the sole-consumer lock (AC22).
# state/inbox-watch.stamp is the persisted last-seen watermark (CDT-568):
# first-ever run wakes ONCE on the oldest existing record, restarts wake on
# records newer than the watermark, spool/<sid>/consumed/ records never wake,
# and the watermark never moves backwards.
# state/away gone → touch the stamp, exit 0. Absent/insane away_sid → exit 0
# silently (fail open; the next session turn re-runs the monitor).
set -u

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=common.sh
. "$SCRIPT_DIR/common.sh"

if [ "${BASH_SOURCE[0]}" != "$0" ]; then
  echo "inbox-watch.sh is a subprocess CLI (SPEC-038); source common.sh for the library." >&2
  return 1
fi

ROOT=$(ir_state_root)
if [ -d "$ROOT" ]; then
  ROOT=$(CDPATH= cd -- "$ROOT" && pwd) || ROOT=$(ir_state_root)
fi
STATE_DIR="$ROOT/state"
STAMP="$STATE_DIR/inbox-watch.stamp"
AWAY_FILE="$STATE_DIR/away"

# Watch cadence: fixed interval, 1–60 s (default 2) via ir_watch_clamp_interval
# (CDT-568 AC11).
INTERVAL_S=$(ir_watch_clamp_interval "${WATCH_INTERVAL_S:-2}" 2)

mkdir -m 700 -p "$STATE_DIR" 2>/dev/null || true

# One unacked record path. MODE=new keeps only records newer than the
# watermark; MODE=all keeps every record. A basename already under
# spool/<sid>/consumed/ is the acked signal and never qualifies (CDT-568).
watch_candidates() { # MODE SID INBOX — print record paths, sorted
  local mode="$1" sid="$2" inbox="$3" r
  [ -d "$inbox" ] || return 0
  case "$mode" in
    new) find "$inbox" -name '*.json' -type f -newer "$STAMP" 2>/dev/null ;;
    *)   find "$inbox" -name '*.json' -type f 2>/dev/null ;;
  esac | LC_ALL=C sort | while IFS= read -r r; do
    [ -n "$r" ] || continue
    if [ -e "$ROOT/spool/$sid/consumed/${r##*/}" ]; then
      continue
    fi
    printf '%s\n' "$r"
  done
}

# Move the watermark to REF's mtime; never move it backwards (CDT-568 AC10).
stamp_advance() { # REF
  [ -n "$1" ] || return 0
  if [ "$STAMP" -nt "$1" ]; then
    return 0
  fi
  touch -r "$1" "$STAMP" 2>/dev/null || true
  return 0
}

seeded=0
while [ -f "$AWAY_FILE" ]; do
  sid=$(ir_away_sid_read 2>/dev/null) || sid=""
  if ! ir_sane_sid "$sid"; then
    # Nothing sane to watch; the next session turn re-runs the monitor.
    exit 0
  fi
  inbox="$ROOT/spool/$sid/inbox"
  if [ "$seeded" -eq 0 ] && [ ! -f "$STAMP" ]; then
    # First-ever watch: wake ONCE on the oldest existing record (OQ3), then
    # seed the watermark past the whole unacked backlog so it cannot re-wake.
    # One find snapshot: a record landing mid-scan stays newer than the seed
    # and wakes on the next pass.
    seeded=1
    cands=$(watch_candidates all "$sid" "$inbox")
    newest=$(printf '%s' "$cands" | tail -n 1)
    if [ -n "$(printf '%s' "$cands" | head -n 1)" ]; then
      # Wake grammar (SPEC-038 § Host adapter): token-free, no message body.
      printf 'intercom: inbound sid=%s path=%s\n' "$sid" "$inbox"
      stamp_advance "$newest"
    else
      touch "$STAMP" 2>/dev/null || true
    fi
  else
    cands=$(watch_candidates new "$sid" "$inbox")
    if [ -n "$(printf '%s' "$cands" | head -n 1)" ]; then
      # Wake grammar (SPEC-038 § Host adapter): token-free, no message body.
      printf 'intercom: inbound sid=%s path=%s\n' "$sid" "$inbox"
      stamp_advance "$(printf '%s' "$cands" | tail -n 1)"
    fi
  fi
  sleep "$INTERVAL_S"
done

touch "$STAMP" 2>/dev/null || true
exit 0
