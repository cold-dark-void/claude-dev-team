#!/usr/bin/env bash
# workspace.sh — incident workspace CLI (SPEC-027 / CDV-193)
#
# Usage:
#   workspace.sh ensure <slug-or-desc>
#   workspace.sh list
#   workspace.sh resume-dump <id>
#   workspace.sh path <id>
#   workspace.sh meta-set <id> <json-object-or-file>
#
# THIS SCRIPT IS A SUBPROCESS CLI — NEVER SOURCE IT.
# Env: INCIDENT_ROOT overrides $MROOT/.claude/incidents (tests).

set -euo pipefail

usage() {
  cat <<'EOF' >&2
Usage: workspace.sh <command> [args]

  ensure <slug-or-desc>   Create incident dir; print id then path
  list                    List incident ids (newest first)
  resume-dump <id>        Print meta + last 20 timeline lines + pending
  path <id>               Print absolute path to incident dir
  meta-get <id>           Print meta.json
  meta-set <id> <json>    Replace meta.json (must be valid JSON object)

Exit: 0 ok · 1 error · 64 usage
EOF
}

resolve_mroot() {
  local _gc
  if [ -n "${INCIDENT_ROOT:-}" ]; then
    # Test/override: INCIDENT_ROOT is the incidents parent (.../.claude/incidents)
    MROOT=""
    INCIDENTS_DIR="$INCIDENT_ROOT"
    return 0
  fi
  if _gc=$(git rev-parse --git-common-dir 2>/dev/null); then
    MROOT=$(CDPATH= cd -- "$(dirname -- "$_gc")" && pwd)
  else
    MROOT=$(pwd)
  fi
  INCIDENTS_DIR="$MROOT/.claude/incidents"
}

# slugify <text> → lower alnum/hyphen, max 40, no leading/trailing hyphen
slugify() {
  local s
  s=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//; s/-+/-/g')
  s="${s:0:40}"
  s=$(printf '%s' "$s" | sed -E 's/-+$//')
  if [ -z "$s" ]; then
    s="incident"
  fi
  printf '%s' "$s"
}

utc_now() {
  date -u +%Y-%m-%dT%H:%M:%SZ
}

utc_date() {
  date -u +%Y-%m-%d
}

cmd_ensure() {
  local desc="${1:-}"
  if [ -z "$desc" ]; then
    echo "workspace.sh ensure: missing <slug-or-desc>" >&2
    exit 64
  fi
  resolve_mroot
  mkdir -p "$INCIDENTS_DIR"

  local slug date_part base id dir n
  slug=$(slugify "$desc")
  date_part=$(utc_date)
  base="${date_part}-${slug}"
  id="$base"
  n=2
  while [ -e "$INCIDENTS_DIR/$id" ]; do
    id="${base}-${n}"
    n=$((n + 1))
  done

  dir="$INCIDENTS_DIR/$id"
  mkdir -p "$dir/comms"
  : >"$dir/timeline.jsonl"
  # empty render
  cat >"$dir/timeline.md" <<EOF
# Incident timeline — \`$id\`

_No entries yet._
EOF

  local opened
  opened=$(utc_now)
  # meta.json — description preserved as given (not slug)
  if command -v python3 >/dev/null 2>&1; then
    python3 - "$dir/meta.json" "$id" "$opened" "$desc" <<'PY'
import json, sys
path, iid, opened, desc = sys.argv[1:5]
meta = {
    "id": iid,
    "severity": None,
    "status": "open",
    "opened_at": opened,
    "description": desc,
    "pending_proposal": None,
}
with open(path, "w", encoding="utf-8") as f:
    json.dump(meta, f, indent=2, ensure_ascii=False)
    f.write("\n")
PY
  else
    # minimal fallback without python — escape " in desc
    local esc
    esc=$(printf '%s' "$desc" | sed 's/\\/\\\\/g; s/"/\\"/g')
    cat >"$dir/meta.json" <<EOF
{
  "id": "$id",
  "severity": null,
  "status": "open",
  "opened_at": "$opened",
  "description": "$esc",
  "pending_proposal": null
}
EOF
  fi

  # stdout contract: path only (plan: "stdout path on ensure")
  # also emit id on stderr for agents that need it, or first line id
  # Plan says: "stdout path on ensure". Skill can basename.
  printf '%s\n' "$dir"
}

cmd_list() {
  resolve_mroot
  if [ ! -d "$INCIDENTS_DIR" ]; then
    return 0
  fi
  # newest first by directory mtime, then name
  find "$INCIDENTS_DIR" -mindepth 1 -maxdepth 1 -type d -printf '%T@ %f\n' 2>/dev/null \
    | LC_ALL=C sort -rn \
    | awk '{print $2}'
}

cmd_path() {
  local id="${1:-}"
  if [ -z "$id" ]; then
    echo "workspace.sh path: missing <id>" >&2
    exit 64
  fi
  resolve_mroot
  local dir="$INCIDENTS_DIR/$id"
  if [ ! -d "$dir" ]; then
    echo "workspace.sh path: incident not found: $id" >&2
    exit 1
  fi
  printf '%s\n' "$dir"
}

cmd_resume_dump() {
  local id="${1:-}"
  if [ -z "$id" ]; then
    echo "workspace.sh resume-dump: missing <id>" >&2
    exit 64
  fi
  resolve_mroot
  local dir="$INCIDENTS_DIR/$id"
  if [ ! -d "$dir" ]; then
    echo "workspace.sh resume-dump: incident not found: $id" >&2
    exit 1
  fi
  if [ ! -f "$dir/meta.json" ]; then
    echo "workspace.sh resume-dump: meta.json missing in $id" >&2
    exit 1
  fi

  echo "=== meta ==="
  cat "$dir/meta.json"
  echo
  echo "=== timeline_tail (last 20) ==="
  if [ -f "$dir/timeline.jsonl" ] && [ -s "$dir/timeline.jsonl" ]; then
    tail -n 20 "$dir/timeline.jsonl"
  else
    echo "(empty)"
  fi
  echo
  echo "=== pending_proposal ==="
  if command -v python3 >/dev/null 2>&1; then
    python3 - "$dir/meta.json" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as f:
    m = json.load(f)
pp = m.get("pending_proposal")
if pp is None:
    print("null")
else:
    print(json.dumps(pp, indent=2, ensure_ascii=False))
PY
  else
    # crude extract
    grep -A20 '"pending_proposal"' "$dir/meta.json" || echo "null"
  fi
  echo
  echo "=== path ==="
  printf '%s\n' "$dir"
}

cmd_meta_get() {
  local id="${1:-}"
  if [ -z "$id" ]; then
    echo "workspace.sh meta-get: missing <id>" >&2
    exit 64
  fi
  resolve_mroot
  local dir="$INCIDENTS_DIR/$id"
  if [ ! -f "$dir/meta.json" ]; then
    echo "workspace.sh meta-get: meta.json not found for $id" >&2
    exit 1
  fi
  cat "$dir/meta.json"
}

cmd_meta_set() {
  local id="${1:-}"
  local json="${2:-}"
  if [ -z "$id" ] || [ -z "$json" ]; then
    echo "workspace.sh meta-set: usage: meta-set <id> <json-object>" >&2
    exit 64
  fi
  resolve_mroot
  local dir="$INCIDENTS_DIR/$id"
  if [ ! -d "$dir" ]; then
    echo "workspace.sh meta-set: incident not found: $id" >&2
    exit 1
  fi
  if command -v python3 >/dev/null 2>&1; then
    python3 - "$dir/meta.json" "$json" <<'PY'
import json, sys, os, tempfile
path, raw = sys.argv[1], sys.argv[2]
# allow @file
if raw.startswith("@") and os.path.isfile(raw[1:]):
    with open(raw[1:], encoding="utf-8") as f:
        data = json.load(f)
else:
    data = json.loads(raw)
if not isinstance(data, dict):
    sys.stderr.write("meta-set: must be a JSON object\n")
    sys.exit(1)
fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path), prefix=".meta.", suffix=".tmp")
try:
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        json.dump(data, f, indent=2, ensure_ascii=False)
        f.write("\n")
    os.replace(tmp, path)
except Exception:
    try:
        os.unlink(tmp)
    except OSError:
        pass
    raise
PY
  else
    printf '%s\n' "$json" >"$dir/meta.json"
  fi
}

main() {
  local cmd="${1:-}"
  if [ -z "$cmd" ]; then
    usage
    exit 64
  fi
  shift || true
  case "$cmd" in
    ensure) cmd_ensure "$@" ;;
    list) cmd_list "$@" ;;
    resume-dump) cmd_resume_dump "$@" ;;
    path) cmd_path "$@" ;;
    meta-get) cmd_meta_get "$@" ;;
    meta-set) cmd_meta_set "$@" ;;
    -h|--help|help) usage; exit 0 ;;
    *)
      echo "workspace.sh: unknown command: $cmd" >&2
      usage
      exit 64
      ;;
  esac
}

main "$@"
