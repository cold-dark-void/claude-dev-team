#!/usr/bin/env bash
# timeline.sh — append-only incident timeline (SPEC-027 / CDV-193)
#
# Canonical store: timeline.jsonl (one JSON object per line).
# timeline.md is a full re-render after each append — never hand-edit either.
#
# Usage:
#   timeline.sh append <id> --actor A --type T --summary S [--detail D] [--refs r1,r2]
#   timeline.sh render <id>
#   timeline.sh validate <id>
#
# THIS SCRIPT IS A SUBPROCESS CLI — NEVER SOURCE IT.
# Env: INCIDENT_ROOT overrides $MROOT/.claude/incidents (tests).

set -euo pipefail

usage() {
  cat <<'EOF' >&2
Usage: timeline.sh <command> [args]

  append <id> --actor A --type T --summary S [--detail D] [--refs r1,r2]
      Append one jsonl entry (auto eNNN id + UTC ts); re-render timeline.md.
      Prints the new entry id on stdout.

  render <id>
      Regenerate timeline.md from timeline.jsonl.

  validate <id>
      Check each line is valid JSON with required fields + type enum.

Exit: 0 ok · 1 error · 64 usage
EOF
}

resolve_dir() {
  local id="${1:-}"
  if [ -z "$id" ]; then
    echo "timeline.sh: missing <id>" >&2
    exit 64
  fi
  local mroot incidents
  if [ -n "${INCIDENT_ROOT:-}" ]; then
    incidents="$INCIDENT_ROOT"
  else
    local _gc
    if _gc=$(git rev-parse --git-common-dir 2>/dev/null); then
      mroot=$(CDPATH= cd -- "$(dirname -- "$_gc")" && pwd)
    else
      mroot=$(pwd)
    fi
    incidents="$mroot/.claude/incidents"
  fi
  DIR="$incidents/$id"
  if [ ! -d "$DIR" ]; then
    echo "timeline.sh: incident not found: $id" >&2
    exit 1
  fi
  JSONL="$DIR/timeline.jsonl"
  MD="$DIR/timeline.md"
  if [ ! -f "$JSONL" ]; then
    : >"$JSONL"
  fi
}

utc_now() {
  date -u +%Y-%m-%dT%H:%M:%SZ
}

# next_entry_id — e001, e002, ... based on existing lines
next_entry_id() {
  local n=0 last
  if [ -s "$JSONL" ]; then
    n=$(wc -l <"$JSONL" | tr -d ' ')
  fi
  n=$((n + 1))
  printf 'e%03d' "$n"
}

cmd_render() {
  local id="${1:-}"
  resolve_dir "$id"
  if command -v python3 >/dev/null 2>&1; then
    python3 - "$JSONL" "$MD" "$id" <<'PY'
import json, sys
jsonl_path, md_path, iid = sys.argv[1:4]
lines = []
if open(jsonl_path, "rb").read(1):
    with open(jsonl_path, encoding="utf-8") as f:
        for raw in f:
            raw = raw.strip()
            if not raw:
                continue
            lines.append(json.loads(raw))

out = []
out.append(f"# Incident timeline — `{iid}`\n")
if not lines:
    out.append("\n_No entries yet._\n")
else:
    out.append("")
    for e in lines:
        eid = e.get("id", "?")
        ts = e.get("ts", "?")
        actor = e.get("actor", "?")
        etype = e.get("type", "?")
        summary = e.get("summary", "")
        out.append(f"## {eid} · {ts} · `{etype}` · {actor}\n")
        out.append(f"**{summary}**\n")
        detail = e.get("detail") or ""
        if detail:
            out.append(f"\n{detail}\n")
        refs = e.get("refs") or []
        if refs:
            out.append("\nRefs: " + ", ".join(f"`{r}`" for r in refs) + "\n")
        out.append("\n")

with open(md_path, "w", encoding="utf-8") as f:
    f.write("".join(out))
PY
  else
    {
      echo "# Incident timeline — \`$id\`"
      echo
      if [ ! -s "$JSONL" ]; then
        echo "_No entries yet._"
      else
        cat "$JSONL"
      fi
    } >"$MD"
  fi
}

cmd_append() {
  local id="" actor="" etype="" summary="" detail="" refs_csv=""
  # first positional is id; then flags
  if [ $# -lt 1 ]; then
    echo "timeline.sh append: missing <id>" >&2
    exit 64
  fi
  id="$1"
  shift
  while [ $# -gt 0 ]; do
    case "$1" in
      --actor)
        [ $# -ge 2 ] || { echo "timeline.sh append: --actor needs value" >&2; exit 64; }
        actor="$2"; shift 2 ;;
      --type)
        [ $# -ge 2 ] || { echo "timeline.sh append: --type needs value" >&2; exit 64; }
        etype="$2"; shift 2 ;;
      --summary)
        [ $# -ge 2 ] || { echo "timeline.sh append: --summary needs value" >&2; exit 64; }
        summary="$2"; shift 2 ;;
      --detail)
        [ $# -ge 2 ] || { echo "timeline.sh append: --detail needs value" >&2; exit 64; }
        detail="$2"; shift 2 ;;
      --refs)
        [ $# -ge 2 ] || { echo "timeline.sh append: --refs needs value" >&2; exit 64; }
        refs_csv="$2"; shift 2 ;;
      -h|--help) usage; exit 0 ;;
      *)
        echo "timeline.sh append: unknown arg: $1" >&2
        exit 64 ;;
    esac
  done

  if [ -z "$actor" ] || [ -z "$etype" ] || [ -z "$summary" ]; then
    echo "timeline.sh append: --actor, --type, and --summary are required" >&2
    exit 64
  fi
  case "$etype" in
    observation|action|decision) ;;
    *)
      echo "timeline.sh append: --type must be observation|action|decision (got: $etype)" >&2
      exit 64 ;;
  esac

  resolve_dir "$id"

  # Snapshot prior jsonl bytes for append-only assertion path (callers/tests)
  local before_hash=""
  if [ -s "$JSONL" ] && command -v sha256sum >/dev/null 2>&1; then
    before_hash=$(sha256sum "$JSONL" | awk '{print $1}')
  fi

  local eid ts
  eid=$(next_entry_id)
  ts=$(utc_now)

  if ! command -v python3 >/dev/null 2>&1; then
    echo "timeline.sh append: python3 required" >&2
    exit 1
  fi

  python3 - "$JSONL" "$eid" "$ts" "$actor" "$etype" "$summary" "$detail" "$refs_csv" <<'PY'
import json, sys, os
path, eid, ts, actor, etype, summary, detail, refs_csv = sys.argv[1:9]
refs = [r for r in refs_csv.split(",") if r] if refs_csv else []
entry = {
    "id": eid,
    "ts": ts,
    "actor": actor,
    "type": etype,
    "summary": summary,
    "detail": detail if detail else "",
    "refs": refs,
}
# Refuse if this id already exists (collision / rewrite)
if os.path.isfile(path) and os.path.getsize(path) > 0:
    with open(path, encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                obj = json.loads(line)
            except json.JSONDecodeError:
                continue
            if obj.get("id") == eid:
                sys.stderr.write(f"timeline.sh append: refuse overwrite of existing id {eid}\n")
                sys.exit(1)
with open(path, "a", encoding="utf-8") as f:
    f.write(json.dumps(entry, ensure_ascii=False, separators=(",", ":")))
    f.write("\n")
print(eid)
PY

  # Re-render md
  cmd_render "$id"
}

cmd_validate() {
  local id="${1:-}"
  resolve_dir "$id"
  if ! command -v python3 >/dev/null 2>&1; then
    echo "timeline.sh validate: python3 required" >&2
    exit 1
  fi
  python3 - "$JSONL" <<'PY'
import json, sys
path = sys.argv[1]
required = ("id", "ts", "actor", "type", "summary")
allowed_types = {"observation", "action", "decision"}
ok = True
n = 0
seen_ids = set()
if not open(path, "rb").read(1):
    # empty is valid
    print("validate: ok (0 entries)")
    sys.exit(0)
with open(path, encoding="utf-8") as f:
    for i, raw in enumerate(f, 1):
        raw = raw.strip()
        if not raw:
            continue
        n += 1
        try:
            obj = json.loads(raw)
        except json.JSONDecodeError as e:
            print(f"line {i}: invalid JSON: {e}", file=sys.stderr)
            ok = False
            continue
        if not isinstance(obj, dict):
            print(f"line {i}: not an object", file=sys.stderr)
            ok = False
            continue
        for k in required:
            if k not in obj or obj[k] in (None, ""):
                # detail/refs may be empty; summary must be non-empty
                print(f"line {i}: missing/empty required field: {k}", file=sys.stderr)
                ok = False
        t = obj.get("type")
        if t not in allowed_types:
            print(f"line {i}: type not in enum: {t!r}", file=sys.stderr)
            ok = False
        eid = obj.get("id")
        if eid in seen_ids:
            print(f"line {i}: duplicate id: {eid}", file=sys.stderr)
            ok = False
        seen_ids.add(eid)
        if "refs" in obj and not isinstance(obj["refs"], list):
            print(f"line {i}: refs must be array", file=sys.stderr)
            ok = False
if not ok:
    sys.exit(1)
print(f"validate: ok ({n} entries)")
PY
}

main() {
  local cmd="${1:-}"
  if [ -z "$cmd" ]; then
    usage
    exit 64
  fi
  shift || true
  case "$cmd" in
    append) cmd_append "$@" ;;
    render) cmd_render "$@" ;;
    validate) cmd_validate "$@" ;;
    -h|--help|help) usage; exit 0 ;;
    *)
      echo "timeline.sh: unknown command: $cmd" >&2
      usage
      exit 64
      ;;
  esac
}

main "$@"
