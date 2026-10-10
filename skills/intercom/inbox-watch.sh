#!/usr/bin/env bash
# inbox-watch.sh — session-driven away monitor (CDT-535). Subprocess CLI:
# never sourced. While state/away is present it watches spool/<away_sid>/inbox/
# and prints the § Host adapter wake grammar once per new-record batch, so the
# away session can drain its inbox each turn (pickup protocol). It is not a
# bridge or adapter cycle: the away-gated loop is session-driven and out of
# scope of the one-shot rule (SPEC-038 CDT-535 AC8). It never starts a second
# updates consumer, never reads the bot token, never touches the adapter
# watermark, and never creates or takes the sole-consumer lock (AC22).
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

# Watch cadence: fixed interval, 1–60 s (default 2).
INTERVAL_S="${WATCH_INTERVAL_S:-2}"
case "$INTERVAL_S" in ''|*[!0-9]*) INTERVAL_S=2 ;; esac
[ "$INTERVAL_S" -ge 1 ] || INTERVAL_S=1
[ "$INTERVAL_S" -le 60 ] || INTERVAL_S=60

mkdir -m 700 -p "$STATE_DIR" 2>/dev/null || true

# First run: create the stamp, then observe (pre-existing records do not wake).
if [ ! -f "$STAMP" ]; then
  : > "$STAMP" 2>/dev/null || true
fi

while [ -f "$AWAY_FILE" ]; do
  sid=$(ir_away_sid_read 2>/dev/null) || sid=""
  if ! ir_sane_sid "$sid"; then
    # Nothing sane to watch; the next session turn re-runs the monitor.
    exit 0
  fi
  inbox="$ROOT/spool/$sid/inbox"
  new=""
  if [ -d "$inbox" ] && [ -f "$STAMP" ]; then
    new=$(find "$inbox" -name '*.json' -type f -newer "$STAMP" 2>/dev/null | head -n 1) || new=""
  fi
  if [ -n "$new" ]; then
    # Wake grammar (SPEC-038 § Host adapter): token-free, no message body.
    printf 'intercom: inbound sid=%s path=%s\n' "$sid" "$inbox"
    touch "$STAMP" 2>/dev/null || true
  fi
  sleep "$INTERVAL_S"
done

touch "$STAMP" 2>/dev/null || true
exit 0
