#!/usr/bin/env bash
# import-seed-pack.sh — import sanitized seed pack into memory (SPEC-024).
#
# Usage: import-seed-pack.sh [MROOT]
#
# Always exits 0 for bootstrap safety (errors → warnings + counts).
# Missing pack → silent exit 0 (M11 graceful absence).

set -u

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=seed-common.sh
. "$SCRIPT_DIR/seed-common.sh"

MROOT="${1:-}"
if [ -z "$MROOT" ]; then
  _gc=$(git rev-parse --git-common-dir 2>/dev/null) \
    && MROOT=$(cd "$(dirname "$_gc")" && pwd) \
    || MROOT=$(pwd)
fi
MROOT=$(cd "$MROOT" 2>/dev/null && pwd) || {
  echo "WARNING: import-seed-pack: invalid MROOT" >&2
  exit 0
}

MEMDB="$MROOT/.claude/memory/memory.db"
SEED_DIR="$MROOT/.claude/memory/seed"
MANIFEST="$SEED_DIR/manifest.json"

# M11: no pack → silent
if [ ! -f "$MANIFEST" ]; then
  exit 0
fi

USE_DB=false
if [ -f "$MEMDB" ] && command -v sqlite3 &>/dev/null; then
  USE_DB=true
fi

IMPORTED=0
SKIPPED_DUP=0
SKIPPED_ARCH=0
REJECTED=0
AGENTS_TOUCHED=0
PACK_DATE=""
PACK_PROJECT=""

warn() { echo "WARNING: import-seed-pack: $*" >&2; }

# Parse manifest; print "agent.md\thash\tcount" lines; set PACK_* via side channel file.
META_FILE=$(mktemp "${TMPDIR:-/tmp}/seed-import-meta.XXXXXX")
FILE_LIST=$(mktemp "${TMPDIR:-/tmp}/seed-import-files.XXXXXX")
trap 'rm -f "$META_FILE" "$FILE_LIST"' EXIT

if ! python3 - "$MANIFEST" "$META_FILE" "$FILE_LIST" <<'PY'
import json, sys
manifest_path, meta_path, files_path = sys.argv[1], sys.argv[2], sys.argv[3]
try:
    with open(manifest_path, encoding="utf-8") as f:
        m = json.load(f)
except Exception as e:
    print(e, file=sys.stderr)
    sys.exit(1)
if not isinstance(m, dict) or "files" not in m or not isinstance(m["files"], dict):
    print("missing files map", file=sys.stderr)
    sys.exit(1)
with open(meta_path, "w", encoding="utf-8") as mf:
    mf.write(f"date={m.get('export_date','')}\n")
    mf.write(f"project={m.get('project','')}\n")
    mf.write(f"format_version={m.get('format_version','')}\n")
with open(files_path, "w", encoding="utf-8") as ff:
    for fname, info in sorted(m["files"].items()):
        if not isinstance(info, dict):
            continue
        h = info.get("content_hash", "")
        c = info.get("count", 0)
        ff.write(f"{fname}\t{h}\t{c}\n")
PY
then
  warn "malformed manifest.json — skipping pack"
  exit 0
fi

# shellcheck disable=SC1090
. /dev/null
while IFS= read -r line; do
  case "$line" in
    date=*) PACK_DATE="${line#date=}" ;;
    project=*) PACK_PROJECT="${line#project=}" ;;
  esac
done < "$META_FILE"

insert_db() {
  local agent="$1" content="$2" meta_json="$3"
  local escaped meta_esc memory_id rc

  escaped=$(printf '%s' "$content" | sed "s/'/''/g")
  meta_esc=$(printf '%s' "$meta_json" | sed "s/'/''/g")

  # Use -cmd .timeout (not PRAGMA in the same session) so stdout is only the rowid
  # — PRAGMA busy_timeout=N prints N and would corrupt last_insert_rowid capture.
  memory_id=$(sqlite3 -cmd ".timeout 5000" "$MEMDB" "
INSERT INTO memories(agent, type, content, metadata_json, tier, distilled_from)
VALUES ('$agent', 'digest', '$escaped', '$meta_esc', 1, '[]');
SELECT last_insert_rowid();" 2>/dev/null) || memory_id=""

  if [ -z "$memory_id" ] || ! [[ "$memory_id" =~ ^[0-9]+$ ]]; then
    sleep 0.2
    memory_id=$(sqlite3 -cmd ".timeout 5000" "$MEMDB" "
INSERT INTO memories(agent, type, content, metadata_json, tier, distilled_from)
VALUES ('$agent', 'digest', '$escaped', '$meta_esc', 1, '[]');
SELECT last_insert_rowid();" 2>/dev/null) || memory_id=""
  fi

  if [ -z "$memory_id" ] || ! [[ "$memory_id" =~ ^[0-9]+$ ]]; then
    return 1
  fi

  local check
  check=$(sqlite3 -cmd ".timeout 5000" "$MEMDB" "SELECT id FROM memories WHERE id=$memory_id;" 2>/dev/null || true)
  if [ "$check" != "$memory_id" ]; then
    return 1
  fi

  # best-effort embed
  if [ -x "$SCRIPT_DIR/embed-one.sh" ] || [ -f "$SCRIPT_DIR/embed-one.sh" ]; then
    bash "$SCRIPT_DIR/embed-one.sh" "$MEMDB" "$memory_id" "$content" >/dev/null 2>&1 || true
  fi
  return 0
}

# Fallback: append highest-signal entries to lessons.md (SPEC-004 line caps).
FALLBACK_LIMITS_cortex=100
FALLBACK_LIMITS_memory=50
FALLBACK_LIMITS_lessons=80

insert_fallback() {
  local agent="$1" content="$2"
  local dir="$MROOT/.claude/memory/$agent"
  local target="$dir/lessons.md"
  local limit=80
  mkdir -p "$dir"
  local existing=0
  if [ -f "$target" ]; then
    existing=$(wc -l < "$target" | tr -d ' ')
  fi
  # count lines we would add
  local add_lines
  add_lines=$(printf '%s\n' "$content" | wc -l | tr -d ' ')
  if [ $((existing + add_lines)) -gt "$limit" ]; then
    # try to fit a truncated single-line summary
    if [ "$existing" -ge "$limit" ]; then
      warn "fallback line cap for $agent/lessons.md — omitted seed entry"
      return 2
    fi
  fi
  {
    [ -f "$target" ] && [ -s "$target" ] && [ -n "$(tail -c1 "$target" 2>/dev/null)" ] && printf '\n'
    printf '%s\n' "$content"
  } >> "$target"
  return 0
}

dedupe_lookup() {
  # prints: none | live | archived
  local hash="$1"
  if [ "$USE_DB" != true ]; then
    # fallback: grep trailers in agent *.md only — never seed/ pack (would always match)
    local hit=0 a f
    for a in $(seed_agents); do
      for f in cortex.md memory.md lessons.md; do
        if [ -f "$MROOT/.claude/memory/$a/$f" ] && \
           grep -qF "hash=${hash}]" "$MROOT/.claude/memory/$a/$f" 2>/dev/null; then
          hit=1
          break 2
        fi
      done
    done
    if [ "$hit" -eq 1 ]; then
      echo "live"
    else
      echo "none"
    fi
    return 0
  fi
  local row
  # Avoid PRAGMA in the SELECT session (it prints a result row and poisons empty matches).
  row=$(sqlite3 -cmd ".timeout 5000" "$MEMDB" \
    "SELECT id || '|' || archived FROM memories
     WHERE content LIKE '%hash=${hash}]%'
     LIMIT 1;" 2>/dev/null || true)
  if [ -z "$row" ]; then
    echo "none"
    return 0
  fi
  local arch="${row#*|}"
  case "$arch" in
    1|true|TRUE) echo "archived" ;;
    *) echo "live" ;;
  esac
}

# Split agent file into entries on \n---\n
process_agent_file() {
  local fname="$1" expected_hash="$2"
  local fpath="$SEED_DIR/$fname"
  local agent="${fname%.md}"

  if [ ! -f "$fpath" ]; then
    warn "missing file $fname — skipped"
    REJECTED=$((REJECTED + 1))
    return 0
  fi

  local actual
  actual=$(seed_file_sha256 "$fpath")
  if [ -n "$expected_hash" ] && [ "$actual" != "$expected_hash" ]; then
    warn "content hash mismatch for $fname — skipped"
    REJECTED=$((REJECTED + 1))
    return 0
  fi

  local agent_imported=0
  # Parse entries with python for robust --- splitting
  local entries_dir
  entries_dir=$(mktemp -d "${TMPDIR:-/tmp}/seed-entries.XXXXXX")
  python3 - "$fpath" "$entries_dir" <<'PY'
import sys, pathlib
src = pathlib.Path(sys.argv[1])
out = pathlib.Path(sys.argv[2])
text = src.read_text(encoding="utf-8")
# Split on lines that are exactly ---
parts = []
buf = []
for line in text.splitlines(keepends=True):
    if line.rstrip("\r\n") == "---":
        parts.append("".join(buf))
        buf = []
    else:
        buf.append(line)
parts.append("".join(buf))
n = 0
for p in parts:
    body = p.strip("\n")
    if not body.strip():
        continue
    n += 1
    (out / f"{n:04d}.entry").write_text(body + "\n", encoding="utf-8")
PY

  local entry
  for entry in "$entries_dir"/*.entry; do
    [ -f "$entry" ] || continue
    local raw body trailer_line body_no_trailer
    raw=$(cat "$entry")

    # Extract last non-empty line as potential trailer
    trailer_line=$(printf '%s' "$raw" | python3 -c '
import sys
lines=[ln.rstrip("\n") for ln in sys.stdin]
while lines and lines[-1]=="":
    lines.pop()
print(lines[-1] if lines else "")
')
    SEED_PROJECT=""; SEED_DATE=""; SEED_TIER=""; SEED_AGENT=""; SEED_HASH=""
    if ! seed_parse_trailer "$trailer_line"; then
      warn "unparseable trailer in $fname — entry rejected"
      REJECTED=$((REJECTED + 1))
      continue
    fi

    body_no_trailer=$(seed_strip_trailer "$raw")
    body_no_trailer=$(seed_normalize_content "$body_no_trailer")

    # Verify content hash
    local recomputed
    recomputed=$(seed_content_hash "$body_no_trailer")
    if [ "$recomputed" != "$SEED_HASH" ]; then
      warn "entry content hash mismatch in $fname (got $recomputed want $SEED_HASH) — rejected"
      REJECTED=$((REJECTED + 1))
      continue
    fi

    # M8 re-screen
    local sanitized
    if ! sanitized=$(seed_sanitize_entry "$body_no_trailer" "$MROOT" 2>/dev/null); then
      warn "sanitize rejected entry in $fname (hash=$SEED_HASH)"
      REJECTED=$((REJECTED + 1))
      continue
    fi
    sanitized=$(seed_normalize_content "$sanitized")
    # If sanitize rewrote paths, re-hash would change — keep original body+trailer for storage
    # (re-screen only gates; stored content is pack content with trailer)
    local store_content
    store_content=$(printf '%s\n%s\n' "$body_no_trailer" "$trailer_line")

    # Dedupe
    local status
    status=$(dedupe_lookup "$SEED_HASH")
    case "$status" in
      live)
        SKIPPED_DUP=$((SKIPPED_DUP + 1))
        continue
        ;;
      archived)
        SKIPPED_ARCH=$((SKIPPED_ARCH + 1))
        continue
        ;;
    esac

    local imported_at meta_json
    imported_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    meta_json=$(SEED_PROJECT="$SEED_PROJECT" SEED_DATE="$SEED_DATE" SEED_TIER="$SEED_TIER" \
      SEED_HASH="$SEED_HASH" IMPORTED_AT="$imported_at" python3 -c '
import json, os
print(json.dumps({
  "seed": {
    "project": os.environ["SEED_PROJECT"],
    "date": os.environ["SEED_DATE"],
    "source_tier": int(os.environ["SEED_TIER"]),
    "hash": os.environ["SEED_HASH"],
    "imported_at": os.environ["IMPORTED_AT"],
  }
}, sort_keys=True, separators=(",", ":")))
')

    local target_agent="$agent"
    # Prefer trailer agent if present and non-empty
    if [ -n "$SEED_AGENT" ]; then
      target_agent="$SEED_AGENT"
    fi

    if [ "$USE_DB" = true ]; then
      if insert_db "$target_agent" "$store_content" "$meta_json"; then
        IMPORTED=$((IMPORTED + 1))
        agent_imported=$((agent_imported + 1))
      else
        warn "INSERT failed for $fname hash=$SEED_HASH"
        REJECTED=$((REJECTED + 1))
      fi
    else
      insert_fallback "$target_agent" "$store_content"
      fb_rc=$?
      case $fb_rc in
        0)
          IMPORTED=$((IMPORTED + 1))
          agent_imported=$((agent_imported + 1))
          ;;
        *)
          REJECTED=$((REJECTED + 1))
          ;;
      esac
    fi
  done

  rm -rf "$entries_dir"
  if [ "$agent_imported" -gt 0 ]; then
    AGENTS_TOUCHED=$((AGENTS_TOUCHED + 1))
  fi
}

while IFS=$'\t' read -r fname fhash fcount; do
  [ -z "$fname" ] && continue
  process_agent_file "$fname" "$fhash"
done < "$FILE_LIST"

echo "seed-import: imported=$IMPORTED skipped-duplicate=$SKIPPED_DUP skipped-archived=$SKIPPED_ARCH rejected=$REJECTED agents=$AGENTS_TOUCHED pack_date=${PACK_DATE:-unknown} project=${PACK_PROJECT:-unknown}"
exit 0
