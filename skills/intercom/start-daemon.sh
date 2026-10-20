#!/usr/bin/env bash
# start-daemon.sh — start the Intercom compose project (SPEC-038 CDT-527):
# services daemon + sidecar (CDT-568).
# Subprocess CLI. Never sourced. Token file path only (never token bytes).
# Host uid:gid; never uid 0. stdout empty on success (setup prints daemon mode).
set -u

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)

if [ "${BASH_SOURCE[0]}" != "$0" ]; then
  echo "start-daemon.sh is a subprocess CLI (SPEC-038); source common.sh for the library." >&2
  return 1
fi

# shellcheck source=common.sh
. "$SCRIPT_DIR/common.sh"

INTERCOM_UID="${INTERCOM_UID:-$(id -u)}"
INTERCOM_GID="${INTERCOM_GID:-$(id -g)}"
if [ "$INTERCOM_UID" = "0" ]; then
  echo "intercom: refuse to start as uid 0" >&2
  exit 1
fi

INTERCOM_TOKEN_FILE="${INTERCOM_TOKEN_FILE:-$HOME/.config/telegram/bot_token}"
INTERCOM_STATE_DIR="${INTERCOM_STATE_DIR:-$(ir_state_root)}"
COMPOSE_FILE="$SCRIPT_DIR/docker-compose.yml"

miss=""
if ! miss=$(ir_docker_available); then
  printf 'intercom: docker unavailable (%s)\n' "${miss:-unknown}" >&2
  exit 1
fi

# CDT-567: the 75 refuse applies only when identity is down (the holder would
# be a stray host watch.sh). Identity running means the holder is the daemon
# being replaced — its own cycle — so up proceeds and recreates the same
# project/service (never a second getUpdates consumer).
if ! ir_daemon_identity_running; then
  if ir_lock_held; then
    echo "intercom: poller.lock is held — stop host watch.sh first" >&2
    exit 75
  fi
fi

export INTERCOM_UID INTERCOM_GID INTERCOM_TOKEN_FILE INTERCOM_STATE_DIR
# CDT-568: up has no service arg — project-wide, starts daemon AND sidecar.
# The identity check stays sidecar-safe: label dev-team.intercom=sidecar
# matches neither the daemon Service name nor the daemon label filter.
docker compose -p intercom -f "$COMPOSE_FILE" up -d --build --force-recreate >/dev/null || exit 1
exit 0
