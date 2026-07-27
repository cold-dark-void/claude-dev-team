#!/usr/bin/env bash
# disclose-force-overwrite.sh — SPEC-005 / CDT-51 AC5 force-overwrite disclosure
#
# When setup/orchestration force-overwrites a managed setting or file, print
# old value, new value, and a restore key/path BEFORE the write.
# Forced + silent = FAIL.
#
# Usage (print-only):
#   bash disclose-force-overwrite.sh \
#     --key <setting.or.path> --old <old> --new <new> [--restore <handle>]
#
# Usage (settings.json key — read old, disclose if changing):
#   bash disclose-force-overwrite.sh \
#     --settings <path/to/settings.json> --key permissions.defaultMode \
#     --new <new-value> [--backup-dir <dir>]
#
# Stdout: disclosure block (stable labels for protocol greps / tests)
# Exit:
#   0  disclosed (old != new) — caller MUST proceed with force write
#   1  no-op (old == new, or missing key and --new empty) — no force needed
#   2  usage / IO error
#
# THIS SCRIPT IS A SUBPROCESS CLI — NEVER SOURCE IT.

set -u

usage() {
  cat >&2 <<'EOF'
Usage:
  disclose-force-overwrite.sh --key KEY --old OLD --new NEW [--restore HANDLE]
  disclose-force-overwrite.sh --settings FILE --key KEY --new NEW [--backup-dir DIR]
EOF
  exit 2
}

KEY=""
OLD=""
NEW=""
RESTORE=""
SETTINGS=""
BACKUP_DIR=""
MODE="print"   # print | settings

while [ $# -gt 0 ]; do
  case "$1" in
    --key)      KEY="${2:-}"; shift 2 ;;
    --old)      OLD="${2:-}"; shift 2 ;;
    --new)      NEW="${2:-}"; shift 2 ;;
    --restore)  RESTORE="${2:-}"; shift 2 ;;
    --settings) SETTINGS="${2:-}"; MODE="settings"; shift 2 ;;
    --backup-dir) BACKUP_DIR="${2:-}"; shift 2 ;;
    -h|--help)  usage ;;
    *) echo "disclose-force-overwrite: unknown arg: $1" >&2; usage ;;
  esac
done

[ -n "$KEY" ] || usage
[ -n "$NEW" ] || usage

# --- settings mode: read old from JSON via python3 ---
if [ "$MODE" = "settings" ]; then
  [ -n "$SETTINGS" ] || usage
  if [ ! -f "$SETTINGS" ]; then
    # No file → greenfield create, not a force overwrite
    exit 1
  fi
  if ! command -v python3 >/dev/null 2>&1; then
    echo "disclose-force-overwrite: python3 required for --settings mode" >&2
    exit 2
  fi
  OLD=$(SETTINGS_FILE="$SETTINGS" KEY_PATH="$KEY" python3 - <<'PY'
import json, os, sys
path = os.environ["SETTINGS_FILE"]
key = os.environ["KEY_PATH"]
try:
    with open(path, encoding="utf-8") as fh:
        data = json.load(fh)
except Exception as e:
    sys.stderr.write("disclose-force-overwrite: cannot parse %s: %s\n" % (path, e))
    sys.exit(2)
cur = data
parts = key.split(".")
for p in parts:
    if not isinstance(cur, dict) or p not in cur:
        print("")  # missing key → treat as empty old
        sys.exit(0)
    cur = cur[p]
if cur is None:
    print("")
elif isinstance(cur, bool):
    # JSON true/false (not Python True/False) so --new true|false matches
    print("true" if cur else "false")
elif isinstance(cur, (dict, list)):
    print(json.dumps(cur, separators=(",", ":")))
else:
    print(cur)
PY
) || exit 2

  # Optional backup of the whole settings file when value will change
  if [ "$OLD" != "$NEW" ] && [ -n "$BACKUP_DIR" ]; then
    mkdir -p "$BACKUP_DIR" 2>/dev/null || {
      echo "disclose-force-overwrite: cannot create backup dir $BACKUP_DIR" >&2
      exit 2
    }
    ts=$(date -u +%Y%m%dT%H%M%SZ 2>/dev/null || date +%s)
    safe_key=$(printf '%s' "$KEY" | tr './' '__')
    bak="$BACKUP_DIR/settings.force-${safe_key}.${ts}.json"
    cp -p -- "$SETTINGS" "$bak" 2>/dev/null || cp -p "$SETTINGS" "$bak" || {
      echo "disclose-force-overwrite: backup copy failed" >&2
      exit 2
    }
    RESTORE="$bak"
  fi
fi

# Same value → no force overwrite, silent OK
if [ "$OLD" = "$NEW" ]; then
  exit 1
fi

# Default restore handle: exact setting key/path + previous value
if [ -z "$RESTORE" ]; then
  if [ -n "$OLD" ]; then
    RESTORE="${KEY}  (set back to: ${OLD})"
  else
    RESTORE="${KEY}  (was unset; remove key or leave managed value)"
  fi
fi

# Stable labels — tests and agents grep these exact prefixes
cat <<EOF
FORCE-OVERWRITE: managed value will be replaced
  key:     ${KEY}
  old:     ${OLD:-(unset)}
  new:     ${NEW}
  restore: ${RESTORE}
EOF

exit 0
