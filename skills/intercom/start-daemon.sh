#!/usr/bin/env bash
# start-daemon.sh — start the Intercom compose sidecar (SPEC-038 CDT-527).
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
INTERCOM_PLUGIN_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/../.." && pwd) || exit 1
COMPOSE_FILE="$SCRIPT_DIR/docker-compose.yml"

miss=""
if ! miss=$(ir_docker_available); then
  printf 'intercom: docker unavailable (%s)\n' "${miss:-unknown}" >&2
  exit 1
fi

if ir_daemon_identity_running; then
  exit 0
fi

if ir_lock_held; then
  echo "intercom: poller.lock is held — stop host watch.sh first" >&2
  exit 75
fi

export INTERCOM_UID INTERCOM_GID INTERCOM_TOKEN_FILE INTERCOM_STATE_DIR INTERCOM_PLUGIN_ROOT
docker compose -p intercom -f "$COMPOSE_FILE" up -d --build >/dev/null || exit 1
exit 0
