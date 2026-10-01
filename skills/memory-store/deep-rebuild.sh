#!/usr/bin/env bash
# Rebuild one digest. Take the lock, write the new digest, then archive the
# old row. A failure leaves the old digest live.
# usage: deep-rebuild.sh <db> <digest_id> fail
#        deep-rebuild.sh <db> <digest_id> content <text>
set -euo pipefail

db=${1:-}
digest_id=${2:-}
mode=${3:-}
text=${4:-}
HERE=$(cd "$(dirname "$0")" && pwd)

if [ -z "$db" ] || [ -z "$digest_id" ] || [ -z "$mode" ]; then
  echo "usage: deep-rebuild.sh <db> <digest_id> fail|content <text>" >&2
  exit 64
fi
case "$digest_id" in
  ''|*[!0-9]*) echo "deep-rebuild: digest id must be an integer" >&2; exit 64 ;;
esac

token=$(bash "$HERE/distill-lock.sh" acquire "$db") || exit $?
release() { bash "$HERE/distill-lock.sh" release "$db" "$token" || true; }
trap release EXIT

if [ "$mode" = "fail" ]; then
  echo "deep-rebuild: distiller failed; digest $digest_id left live" >&2
  exit 1
fi
if [ "$mode" != "content" ] || [ -z "$text" ]; then
  echo "usage: deep-rebuild.sh <db> <digest_id> content <text>" >&2
  exit 64
fi

row=$(sqlite3 -cmd ".timeout 5000" "$db" \
  "SELECT agent || '|' || distilled_from FROM memories WHERE id=$digest_id AND archived=0;")
if [ -z "$row" ]; then
  echo "deep-rebuild: digest $digest_id is not a live row" >&2
  exit 1
fi
agent=${row%%|*}
ids_json=${row#*|}
in_list=$(printf '%s' "$ids_json" | tr -d '[] ')
case "$in_list" in
  ''|*[!0-9,]*) echo "deep-rebuild: distilled_from is not an id list" >&2; exit 1 ;;
esac
ids=$(sqlite3 -cmd ".timeout 5000" "$db" \
  "SELECT id FROM memories WHERE id IN ($in_list) AND (archive_reason IS NULL OR archive_reason='' OR archive_reason='distilled') ORDER BY id;")
if [ -z "$ids" ]; then
  echo "deep-rebuild: no live sources; digest $digest_id left live" >&2
  exit 1
fi
# shellcheck disable=SC2086
bash "$HERE/distill-commit.sh" "$db" "$agent" "$text" $ids
sqlite3 -cmd ".timeout 5000" "$db" \
  "UPDATE memories SET archived=1, archive_reason='stale' WHERE id=$digest_id;"
