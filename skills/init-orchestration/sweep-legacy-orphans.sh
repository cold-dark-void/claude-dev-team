#!/usr/bin/env bash
# sweep-legacy-orphans.sh — CDT-76 known-legacy-orphan sweep for /setup orchestration
#
# Remove ONLY basenames on an explicit finite known-legacy-orphan list under
# .claude/hooks/, subject to reference checks (settings commands + sibling
# hooks). FORCE-OVERWRITE disclosure + .bak-force-<ts> before delete.
# Not free-form GC.
#
# Usage:
#   bash sweep-legacy-orphans.sh --project-root DIR \
#       [--settings FILE] [--hooks-dir DIR] [--disclose PATH] [--dry-run]
#
# Defaults:
#   --settings   $project-root/.claude/settings.json
#   --hooks-dir  $project-root/.claude/hooks
#   --disclose   sibling disclose-force-overwrite.sh if present
#
# Exit:
#   0  success (removed / WARN-kept / absent no-op)
#   2  usage / unreadable settings when present / backup or delete failure
#
# Stdout machine lines (Step 9):
#   LEGACY-ORPHAN: <name> removed restore=<bak>
#   LEGACY-ORPHAN: <name> left still-referenced
#   LEGACY-ORPHAN: <name> absent no-op
#
# THIS SCRIPT IS A SUBPROCESS CLI — NEVER SOURCE IT.

set -u

# v1 finite list — add names only with SPEC + list update together (AC1)
LEGACY_ORPHANS=( bash-compress-wrapper.sh )

usage() {
  cat >&2 <<'EOF'
Usage:
  sweep-legacy-orphans.sh --project-root DIR \
      [--settings FILE] [--hooks-dir DIR] [--disclose PATH] [--dry-run]
EOF
  exit 2
}

PROJECT_ROOT=""
SETTINGS=""
HOOKS_DIR=""
DISCLOSE=""
DRY_RUN=0

while [ $# -gt 0 ]; do
  case "$1" in
    --project-root) PROJECT_ROOT="${2:-}"; shift 2 ;;
    --settings)     SETTINGS="${2:-}"; shift 2 ;;
    --hooks-dir)    HOOKS_DIR="${2:-}"; shift 2 ;;
    --disclose)     DISCLOSE="${2:-}"; shift 2 ;;
    --dry-run)      DRY_RUN=1; shift ;;
    -h|--help)      usage ;;
    *) echo "sweep-legacy-orphans: unknown arg: $1" >&2; usage ;;
  esac
done

[ -n "$PROJECT_ROOT" ] || usage

PROJECT_ROOT=$(CDPATH= cd -- "$PROJECT_ROOT" && pwd) || {
  echo "sweep-legacy-orphans: cannot resolve project root" >&2
  exit 2
}

if [ -z "$SETTINGS" ]; then
  SETTINGS="$PROJECT_ROOT/.claude/settings.json"
fi
if [ -z "$HOOKS_DIR" ]; then
  HOOKS_DIR="$PROJECT_ROOT/.claude/hooks"
fi

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
if [ -z "$DISCLOSE" ]; then
  DISCLOSE="$SCRIPT_DIR/disclose-force-overwrite.sh"
fi

# Collect settings command strings that contain basename (fixed-string).
# Missing settings → empty (no refs). Present but unparseable → exit 2.
# Prints one "settings.json command: <snippet>" line per match on stdout.
settings_refs_for() {
  local basename="$1"
  if [ ! -f "$SETTINGS" ]; then
    return 0
  fi
  if ! command -v python3 >/dev/null 2>&1; then
    echo "sweep-legacy-orphans: python3 required to parse settings" >&2
    return 2
  fi
  SETTINGS_FILE="$SETTINGS" BASENAME="$basename" python3 - <<'PY'
import json, os, sys

path = os.environ["SETTINGS_FILE"]
basename = os.environ["BASENAME"]

try:
    with open(path, encoding="utf-8") as fh:
        data = json.load(fh)
except Exception as e:
    sys.stderr.write("sweep-legacy-orphans: cannot parse %s: %s\n" % (path, e))
    sys.exit(2)

def walk_commands(node, path_parts, out):
    if isinstance(node, dict):
        for k, v in node.items():
            if k == "command" and isinstance(v, str) and basename in v:
                snippet = v if len(v) <= 120 else v[:117] + "..."
                out.append("settings.json command: %s" % snippet)
            else:
                walk_commands(v, path_parts + [k], out)
    elif isinstance(node, list):
        for i, item in enumerate(node):
            walk_commands(item, path_parts + [str(i)], out)

refs = []
hooks = data.get("hooks") if isinstance(data, dict) else None
if isinstance(hooks, dict):
    walk_commands(hooks, ["hooks"], refs)
# Also walk entire tree under hooks only (above). Done.

for r in refs:
    sys.stdout.write(r + "\n")
sys.exit(0)
PY
}

# Collect sibling .sh refs (exclude self; ignore *.bak-force-*).
# Prints ".claude/hooks/<other>.sh" lines for each referencer.
sibling_refs_for() {
  local basename="$1"
  local f base
  [ -d "$HOOKS_DIR" ] || return 0
  for f in "$HOOKS_DIR"/*.sh; do
    [ -f "$f" ] || continue
    base=$(basename -- "$f")
    # skip self
    [ "$base" = "$basename" ] && continue
    # skip bak-force backups (defensive)
    case "$base" in
      *.bak-force-*) continue ;;
    esac
    if grep -Fq -- "$basename" "$f" 2>/dev/null; then
      printf '.claude/hooks/%s\n' "$base"
    fi
  done
}

disclose_remove() {
  local key="$1" old="$2" new="$3" restore="$4"
  if [ -n "$DISCLOSE" ] && [ -f "$DISCLOSE" ]; then
    bash "$DISCLOSE" \
      --key "$key" \
      --old "$old" \
      --new "$new" \
      --restore "$restore" || true
  else
    cat <<EOF
FORCE-OVERWRITE: managed value will be replaced
  key:     ${key}
  old:     ${old}
  new:     ${new}
  restore: ${restore}
EOF
  fi
}

for name in "${LEGACY_ORPHANS[@]}"; do
  live="$HOOKS_DIR/$name"

  if [ ! -f "$live" ]; then
    printf 'LEGACY-ORPHAN: %s absent no-op\n' "$name"
    continue
  fi

  # Collect referencers
  REFS=()
  SETTINGS_OUT=$(settings_refs_for "$name")
  SETTINGS_RC=$?
  if [ "$SETTINGS_RC" -eq 2 ]; then
    exit 2
  fi
  if [ -n "${SETTINGS_OUT:-}" ]; then
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      REFS+=("$line")
    done <<< "$SETTINGS_OUT"
  fi

  SIBLING_OUT=$(sibling_refs_for "$name")
  if [ -n "${SIBLING_OUT:-}" ]; then
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      REFS+=("$line")
    done <<< "$SIBLING_OUT"
  fi

  if [ "${#REFS[@]}" -gt 0 ]; then
    printf 'WARN: legacy orphan kept (still referenced): %s\n' "$live"
    for r in "${REFS[@]}"; do
      printf '  referenced-by: %s\n' "$r"
    done
    printf 'LEGACY-ORPHAN: %s left still-referenced\n' "$name"
    continue
  fi

  # Removable: bak → disclose → rm
  ts=$(date -u +%Y%m%dT%H%M%SZ 2>/dev/null || date +%s)
  bak="$HOOKS_DIR/${name}.bak-force-${ts}"
  key=".claude/hooks/${name}"
  old="legacy orphan present (known-legacy list)"
  new="removed (no longer managed)"

  if [ "$DRY_RUN" -eq 1 ]; then
    disclose_remove "$key" "$old" "$new" "$bak"
    printf 'LEGACY-ORPHAN: %s removed restore=%s\n' "$name" "$bak"
    continue
  fi

  cp -p -- "$live" "$bak" 2>/dev/null || cp -p "$live" "$bak" || {
    echo "sweep-legacy-orphans: backup failed for $live" >&2
    exit 2
  }

  disclose_remove "$key" "$old" "$new" "$bak"

  rm -f -- "$live" || {
    echo "sweep-legacy-orphans: delete failed for $live" >&2
    exit 2
  }

  printf 'LEGACY-ORPHAN: %s removed restore=%s\n' "$name" "$bak"
done

exit 0
