#!/usr/bin/env bash
# export-seed-pack.sh — write sanitized tier-2 seed pack under .claude/memory/seed/ (SPEC-024).
#
# Usage: export-seed-pack.sh [--agent NAME] [--limit N] [--dry-run] [MROOT]
#
# MUST NOT git add / commit / push. User reviews and commits deliberately.

set -uo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=seed-common.sh
. "$SCRIPT_DIR/seed-common.sh"

AGENT_FILTER=""
LIMIT=40
DRY_RUN=0
MROOT=""

usage() {
  echo "Usage: export-seed-pack.sh [--agent NAME] [--limit N] [--dry-run] [MROOT]" >&2
}

while [ $# -gt 0 ]; do
  case "$1" in
    --agent)
      AGENT_FILTER="${2:-}"; shift 2 || { usage; exit 64; }
      ;;
    --limit)
      LIMIT="${2:-}"; shift 2 || { usage; exit 64; }
      ;;
    --dry-run)
      DRY_RUN=1; shift
      ;;
    -h|--help)
      usage; exit 0
      ;;
    -*)
      echo "Unknown flag: $1" >&2; usage; exit 64
      ;;
    *)
      MROOT="$1"; shift
      ;;
  esac
done

if [ -z "$MROOT" ]; then
  _gc=$(git rev-parse --git-common-dir 2>/dev/null) \
    && MROOT=$(cd "$(dirname "$_gc")" && pwd) \
    || MROOT=$(pwd)
fi
MROOT=$(cd "$MROOT" && pwd)

if ! [[ "$LIMIT" =~ ^[0-9]+$ ]] || [ "$LIMIT" -lt 1 ]; then
  echo "Error: --limit must be a positive integer" >&2
  exit 64
fi

MEMDB="$MROOT/.claude/memory/memory.db"
SEED_DIR="$MROOT/.claude/memory/seed"
USE_DB=false
if [ -f "$MEMDB" ] && command -v sqlite3 &>/dev/null; then
  USE_DB=true
fi

PROJECT_NAME=$(basename "$MROOT")
EXPORT_DATE=$(date -u +%Y-%m-%d)

AGENTS=$(seed_agents)
if [ -n "$AGENT_FILTER" ]; then
  found=0
  for a in $AGENTS; do
    if [ "$a" = "$AGENT_FILTER" ]; then found=1; break; fi
  done
  if [ "$found" -eq 0 ]; then
    echo "Error: unknown agent '$AGENT_FILTER' (expected one of: $AGENTS)" >&2
    exit 64
  fi
  AGENTS="$AGENT_FILTER"
fi

WORK=$(mktemp -d "${TMPDIR:-/tmp}/seed-export.XXXXXX")
trap 'rm -rf "$WORK"' EXIT

TOTAL_INCLUDED=0
TOTAL_EXCLUDED=0
TOTAL_OMITTED=0
declare -A AGENT_COUNTS=()
declare -A FILE_HASHES=()
declare -A FILE_COUNTS=()

include_entry() {
  local agent="$1" mid="$2" mtype="$3" content="$4" source_tier="$5"
  local sanitized reason_file hash trailer body entry_path n

  reason_file=$(mktemp "${TMPDIR:-/tmp}/seed-reason.XXXXXX")
  if ! sanitized=$(seed_sanitize_entry "$content" "$MROOT" 2>"$reason_file"); then
    local reason
    reason=$(cat "$reason_file" 2>/dev/null || echo "sanitize failed")
    rm -f "$reason_file"
    echo "  exclude id=$mid agent=$agent: $reason"
    TOTAL_EXCLUDED=$((TOTAL_EXCLUDED + 1))
    return 1
  fi
  rm -f "$reason_file"

  # Command substitution strips trailing newlines — normalize then restore
  # content as NL-terminated body lines without relying on trailing NL in $sanitized.
  sanitized=$(seed_normalize_content "$sanitized")
  # Drop the trailing NL that normalize wrote (already stripped by $()) — content
  # is now bare lines joined by \n with no final NL.
  if [ -z "$(printf '%s' "$sanitized" | tr -d '[:space:]')" ]; then
    echo "  exclude id=$mid agent=$agent: empty after sanitize"
    TOTAL_EXCLUDED=$((TOTAL_EXCLUDED + 1))
    return 1
  fi

  hash=$(seed_content_hash "$sanitized")
  trailer=$(seed_trailer "$PROJECT_NAME" "$EXPORT_DATE" "$source_tier" "$agent" "$hash")
  # Always put trailer on its own line after content
  body=$(printf '%s\n%s\n' "$sanitized" "$trailer")

  mkdir -p "$WORK/$agent"
  n=$(find "$WORK/$agent" -maxdepth 1 -type f -name '*.entry' 2>/dev/null | wc -l | tr -d ' ')
  n=$((n + 1))
  entry_path=$(printf '%s/%s/%04d.entry' "$WORK" "$agent" "$n")
  printf '%s' "$body" > "$entry_path"
  TOTAL_INCLUDED=$((TOTAL_INCLUDED + 1))
  AGENT_COUNTS[$agent]=$(( ${AGENT_COUNTS[$agent]:-0} + 1 ))
  return 0
}

export_sqlite() {
  local agent="$1"
  local total_for_agent jsonl

  total_for_agent=$(sqlite3 "$MEMDB" \
    "SELECT COUNT(*) FROM memories WHERE tier=2 AND (archived=0 OR archived=FALSE) AND agent='$(printf '%s' "$agent" | sed "s/'/''/g")';")
  if [ "${total_for_agent:-0}" -gt "$LIMIT" ]; then
    TOTAL_OMITTED=$((TOTAL_OMITTED + total_for_agent - LIMIT))
  fi

  jsonl=$(python3 - "$MEMDB" "$agent" "$LIMIT" <<'PY'
import sqlite3, sys, json
db_path, agent, limit = sys.argv[1], sys.argv[2], int(sys.argv[3])
con = sqlite3.connect(db_path)
con.row_factory = sqlite3.Row
rows = con.execute(
    """SELECT id, type, content, tier, updated_at FROM memories
       WHERE tier=2 AND (archived=0 OR archived=FALSE) AND agent=?
       ORDER BY type ASC, updated_at DESC, id ASC
       LIMIT ?""",
    (agent, limit),
).fetchall()
for r in rows:
    print(json.dumps({
        "id": r["id"], "type": r["type"], "content": r["content"],
        "tier": r["tier"], "updated_at": r["updated_at"],
    }, ensure_ascii=False))
PY
)

  mkdir -p "$WORK/$agent"
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    local id type tier content
    eval "$(python3 -c '
import json,sys,shlex
o=json.loads(sys.argv[1])
print("id="+shlex.quote(str(o["id"])))
print("type="+shlex.quote(o["type"]))
print("tier="+shlex.quote(str(o["tier"])))
print("content="+shlex.quote(o["content"]))
' "$line")"
    include_entry "$agent" "$id" "$type" "$content" "$tier" || true
  done <<< "$jsonl"
}

export_fallback() {
  local agent="$1"
  local memdir="$MROOT/.claude/memory/$agent"
  local f type line n considered
  n=0
  considered=0
  for type in cortex lessons; do
    f="$memdir/$type.md"
    [ -f "$f" ] || continue
    while IFS= read -r line || [ -n "$line" ]; do
      [ -z "$(printf '%s' "$line" | tr -d '[:space:]')" ] && continue
      considered=$((considered + 1))
      if [ "$n" -ge "$LIMIT" ]; then
        TOTAL_OMITTED=$((TOTAL_OMITTED + 1))
        continue
      fi
      if include_entry "$agent" "fallback:$type:$considered" "$type" "$line" 2; then
        n=$((n + 1))
      fi
    done < "$f"
  done
}

echo "=== memory-export (SPEC-024) ==="
echo "MROOT:   $MROOT"
echo "Mode:    $([ "$USE_DB" = true ] && echo sqlite || echo fallback)"
echo "Date:    $EXPORT_DATE"
echo "Limit:   $LIMIT per agent"
[ -n "$AGENT_FILTER" ] && echo "Agent:   $AGENT_FILTER"
[ "$DRY_RUN" -eq 1 ] && echo "Dry-run: yes"
echo ""

for agent in $AGENTS; do
  mkdir -p "$WORK/$agent"
  if [ "$USE_DB" = true ]; then
    export_sqlite "$agent"
  else
    export_fallback "$agent"
  fi
done

OUT="$WORK/out"
mkdir -p "$OUT"
AGENTS_WITH_FILES=0

for agent in $AGENTS; do
  mapfile -t entries < <(find "$WORK/$agent" -maxdepth 1 -type f -name '*.entry' 2>/dev/null | sort)
  if [ "${#entries[@]}" -eq 0 ]; then
    continue
  fi
  AGENTS_WITH_FILES=$((AGENTS_WITH_FILES + 1))
  {
    first=1
    for e in "${entries[@]}"; do
      if [ "$first" -eq 1 ]; then
        first=0
      else
        printf '\n---\n'
      fi
      cat "$e"
      # ensure newline between/after
      if [ -n "$(tail -c1 "$e" 2>/dev/null)" ]; then
        printf '\n'
      fi
    done
  } > "$OUT/$agent.md"
  FILE_HASHES[$agent]=$(seed_file_sha256 "$OUT/$agent.md")
  FILE_COUNTS[$agent]=${#entries[@]}
done

if [ "$TOTAL_INCLUDED" -eq 0 ]; then
  echo "nothing to export"
  if [ -d "$SEED_DIR" ] && [ "$DRY_RUN" -eq 0 ]; then
    rm -f "$SEED_DIR"/*.md "$SEED_DIR/manifest.json" 2>/dev/null || true
    rmdir "$SEED_DIR" 2>/dev/null || true
    echo "pruned prior pack (no exportable sources)"
  fi
  if [ "$DRY_RUN" -eq 0 ]; then
    ensure_seed_gitignore "$MROOT" || true
  fi
  exit 0
fi

MANIFEST_JSON=$(
  {
    for agent in $AGENTS; do
      [ -n "${FILE_COUNTS[$agent]:-}" ] || continue
      printf '%s\t%s\t%s\n' "$agent" "${FILE_COUNTS[$agent]}" "${FILE_HASHES[$agent]}"
    done
  } | EXPORT_DATE="$EXPORT_DATE" PROJECT_NAME="$PROJECT_NAME" python3 -c '
import json, os, sys
files = {}
for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    agent, count, h = line.split("\t")
    files[f"{agent}.md"] = {"count": int(count), "content_hash": h}
manifest = {
    "format_version": 1,
    "project": os.environ["PROJECT_NAME"],
    "export_date": os.environ["EXPORT_DATE"],
    "files": files,
}
print(json.dumps(manifest, sort_keys=True, indent=2))
print()
'
)

if [ "$DRY_RUN" -eq 1 ]; then
  echo "--- dry-run pack preview ---"
  for agent in $AGENTS; do
    [ -f "$OUT/$agent.md" ] || continue
    echo "would write: .claude/memory/seed/$agent.md (${FILE_COUNTS[$agent]} entries, hash=${FILE_HASHES[$agent]:0:12}…)"
  done
  echo "would write: .claude/memory/seed/manifest.json"
  echo ""
  echo "included=$TOTAL_INCLUDED excluded=$TOTAL_EXCLUDED omitted_by_cap=$TOTAL_OMITTED agents=$AGENTS_WITH_FILES"
  echo "Advise: review the pack in a PR before merge (sanitization is a floor, not a guarantee)."
  exit 0
fi

mkdir -p "$SEED_DIR"
for old in "$SEED_DIR"/*.md; do
  [ -f "$old" ] || continue
  base=$(basename "$old")
  agent="${base%.md}"
  if [ -z "${FILE_COUNTS[$agent]:-}" ]; then
    rm -f "$old"
  fi
done

for agent in $AGENTS; do
  [ -f "$OUT/$agent.md" ] || continue
  cp "$OUT/$agent.md" "$SEED_DIR/$agent.md"
done
printf '%s' "$MANIFEST_JSON" > "$SEED_DIR/manifest.json"

ensure_seed_gitignore "$MROOT" || true

echo "Wrote pack to $SEED_DIR"
for agent in $AGENTS; do
  [ -f "$SEED_DIR/$agent.md" ] || continue
  echo "  $agent.md  entries=${FILE_COUNTS[$agent]}  content_hash=${FILE_HASHES[$agent]}"
done
echo "  manifest.json"
echo ""
echo "included=$TOTAL_INCLUDED excluded=$TOTAL_EXCLUDED omitted_by_cap=$TOTAL_OMITTED agents=$AGENTS_WITH_FILES"
echo "Advise: commit via a reviewed PR (do not auto-push). Sanitization is conservative but not perfect."
exit 0
