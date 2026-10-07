#!/usr/bin/env bash
# daemon.sh — resident getUpdates loop (SPEC-038 CDT-509). Container
# entrypoint / compose command. Each iteration runs one-shot poller.sh
# (or INTERCOM_POLLER). Never holds state/poller.lock; poller.sh still
# takes flock -n for one cycle. Never sourced. No typing-keepalive.
set -u

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)

if [ "${BASH_SOURCE[0]}" != "$0" ]; then
  echo "daemon.sh is a subprocess CLI (SPEC-038); source common.sh for the library." >&2
  return 1
fi

POLLER="${INTERCOM_POLLER:-$SCRIPT_DIR/poller.sh}"

# Fast poller exit 0 (wall < 2s) and any nonzero except 2 backoff ≥1s.
# Long-poll success (≥2s, rc 0) reinvokes immediately. Exit 2 terminates.
while true; do
  t0=$(date +%s)
  rc=0
  bash "$POLLER" || rc=$?
  if [ "$rc" -eq 2 ]; then
    exit 2
  fi
  t1=$(date +%s)
  elapsed=$((t1 - t0))
  if [ "$rc" -eq 0 ] && [ "$elapsed" -ge 2 ]; then
    continue
  fi
  sleep 1
done
