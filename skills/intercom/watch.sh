#!/usr/bin/env bash
# watch.sh — host adapter for poller.sh (SPEC-038 CDT-512-C1). One cycle per
# invocation. Never sourced. Never a resident loop. Always exits 0.
#
# Session-facing stdout only on inbound wake or edge-triggered failure wake.
# Never reads, passes, or prints the bot token. Never copies poller stderr
# onto stdout. Sources common.sh for the state root only.
set -u

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=common.sh
. "$SCRIPT_DIR/common.sh"

if [ "${BASH_SOURCE[0]}" != "$0" ]; then
  echo "watch.sh is a subprocess CLI (SPEC-038); source common.sh for the library." >&2
  return 1
fi

ROOT=$(ir_state_root)
if [ -d "$ROOT" ]; then
  ROOT=$(CDPATH= cd -- "$ROOT" && pwd) || ROOT=$(ir_state_root)
fi
STATE_DIR="$ROOT/state"
STAMP="$STATE_DIR/inbox.stamp"
LATCH="$STATE_DIR/last_wake_exit"
CONFIG="$ROOT/config.json"
POLLER="$SCRIPT_DIR/poller.sh"

mkdir -m 700 -p "$STATE_DIR" 2>/dev/null || mkdir -p "$STATE_DIR" 2>/dev/null || true

# Stamp missing → create, then run poller (pre-existing inbox does not wake).
if [ ! -f "$STAMP" ]; then
  : > "$STAMP" 2>/dev/null || true
fi

errfile=$(mktemp "${TMPDIR:-/tmp}/intercom-watch.err.XXXXXX") || errfile=""
POLLER_RC=0
if [ -n "$errfile" ]; then
  bash "$POLLER" >/dev/null 2>"$errfile" || POLLER_RC=$?
  rm -f "$errfile"
else
  bash "$POLLER" >/dev/null 2>/dev/null || POLLER_RC=$?
fi

# Members keys from config.json (never a hardcoded chat id).
MEMBERS=" "
if [ -f "$CONFIG" ] && command -v jq >/dev/null 2>&1; then
  while IFS= read -r k || [ -n "$k" ]; do
    [ -n "$k" ] || continue
    MEMBERS="$MEMBERS$k "
  done <<EOF
$(jq -r '(.members // {}) | keys[]' "$CONFIG" 2>/dev/null)
EOF
fi

SID_SET=" "
if [ -d "$ROOT/spool" ] && [ -f "$STAMP" ]; then
  while IFS= read -r f || [ -n "$f" ]; do
    [ -n "$f" ] && [ -f "$f" ] || continue
    from=$(jq -r '.from_id // empty' "$f" 2>/dev/null) || from=""
    [ -n "$from" ] || continue
    case "$MEMBERS" in
      *" $from "*) ;;
      *) continue ;;
    esac
    rel=${f#"$ROOT/spool/"}
    sid=${rel%%/*}
    case "$sid" in
      ''|.|..|inbox) continue ;;
    esac
    case "$SID_SET" in
      *" $sid "*) ;;
      *) SID_SET="$SID_SET$sid " ;;
    esac
  done <<EOF
$(find "$ROOT/spool" -path '*/inbox/*.json' -type f -newer "$STAMP" 2>/dev/null)
EOF
fi

if [ "$SID_SET" != " " ]; then
  sid_csv=""
  path_list=""
  # Unquoted $SID_SET is safe: sids match [A-Za-z0-9._-]+ (spool path segment).
  for sid in $(printf '%s\n' $SID_SET | LC_ALL=C sort); do
    [ -n "$sid" ] || continue
    if [ -z "$sid_csv" ]; then
      sid_csv="$sid"
      path_list="$ROOT/spool/$sid/inbox"
    else
      sid_csv="$sid_csv,$sid"
      path_list="$path_list $ROOT/spool/$sid/inbox"
    fi
  done
  if [ -n "$sid_csv" ]; then
    printf 'intercom: inbound sid=%s path=%s\n' "$sid_csv" "$path_list"
  fi
fi

case "$POLLER_RC" in
  0|75)
    rm -f "$LATCH"
    ;;
  *)
    last=""
    if [ -f "$LATCH" ]; then
      last=$(tr -d ' \t\r\n' < "$LATCH" 2>/dev/null) || last=""
    fi
    if [ "$last" != "$POLLER_RC" ]; then
      printf 'intercom: poller exit %s\n' "$POLLER_RC"
      printf '%s\n' "$POLLER_RC" > "$LATCH" 2>/dev/null || true
    fi
    ;;
esac

touch "$STAMP" 2>/dev/null || true
exit 0
