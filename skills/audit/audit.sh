#!/usr/bin/env bash
# audit.sh — instruction-stack inventory + approve-then-apply (SPEC-035 / CDT-200)
#
# Usage:
#   audit.sh [inventory] [--json] [--home DIR] [--cwd DIR] [--plugin-root DIR]
#   audit.sh apply <id|batch> --from-json FILE [--judgment] [--yes] [--dry-run] [--home DIR]
#   audit.sh --from-session ID [--json] [--cwd DIR] …
#
# Exit: 0 clean inventory / apply ok · 1 inventory WARN · 2 apply rejected · 64 usage
# Bare inventory is read-only (scratch under $TMPDIR only).
# THIS SCRIPT IS A SUBPROCESS CLI — NEVER SOURCE IT.
set -euo pipefail

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
PLUGIN_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/../.." && pwd)
APPLY_PY="$SCRIPT_DIR/apply.py"
FROM_SESS="$SCRIPT_DIR/from-session.sh"

SKILL_WARN_BYTES=30720
SKILL_HARD_BYTES=40960

CMD=inventory
JSON_MODE=0
HOME_OPT="${HOME:-}"
CWD_OPT=""
PLUGIN_OPT=""
FROM_SESSION=""
FROM_JSON=""
APPLY_IDS=""
JUDGMENT=0
YES=0
DRY=0

usage() {
  cat <<'EOF' >&2
Usage:
  audit.sh [inventory] [--json] [--home DIR] [--cwd DIR] [--plugin-root DIR]
  audit.sh apply <id[,id…]> --from-json FILE [--judgment] [--yes] [--dry-run] [--home DIR]
  audit.sh --from-session ID [--json] [--cwd DIR] [--home DIR] [--plugin-root DIR]

  inventory     Walk-up CLAUDE.md / AGENTS.md / directives + skill-size WARN (default)
  apply         Instruction-stack files only; mechanical evidence required
  --from-session
                Locate session via skills/transcript-parse/hosts.py, then inventory
  --json        JSON document on stdout
  --judgment    Allow class=judgment in apply
  --yes         Extra confirm for writes under ~/.claude or ~/.grok
  --dry-run     Validate apply; do not write
  --all         Not supported (exit 64)

Exit: 0 ok · 1 inventory WARN · 2 apply rejected · 64 usage
EOF
}

USAGE_ERR=0
while [ $# -gt 0 ]; do
  case "$1" in
    inventory) CMD=inventory; shift ;;
    apply)
      CMD=apply
      shift
      if [ $# -lt 1 ] || [ -z "${1:-}" ] || [ "${1#-}" != "$1" ]; then
        echo "audit: apply requires <id|batch>" >&2
        USAGE_ERR=1
        break
      fi
      APPLY_IDS="$1"
      shift
      ;;
    --from-session)
      if [ $# -lt 2 ] || [ -z "${2:-}" ]; then
        echo "audit: --from-session requires an id" >&2
        USAGE_ERR=1
        break
      fi
      FROM_SESSION="$2"
      shift 2
      ;;
    --from-json)
      if [ $# -lt 2 ] || [ -z "${2:-}" ]; then
        echo "audit: --from-json requires a file" >&2
        USAGE_ERR=1
        break
      fi
      FROM_JSON="$2"
      shift 2
      ;;
    --json) JSON_MODE=1; shift ;;
    --judgment) JUDGMENT=1; shift ;;
    --yes) YES=1; shift ;;
    --dry-run) DRY=1; shift ;;
    --home)
      if [ $# -lt 2 ] || [ -z "${2:-}" ]; then
        echo "audit: --home requires a directory" >&2
        USAGE_ERR=1
        break
      fi
      HOME_OPT="$2"
      shift 2
      ;;
    --cwd)
      if [ $# -lt 2 ] || [ -z "${2:-}" ]; then
        echo "audit: --cwd requires a directory" >&2
        USAGE_ERR=1
        break
      fi
      CWD_OPT="$2"
      shift 2
      ;;
    --plugin-root)
      if [ $# -lt 2 ] || [ -z "${2:-}" ]; then
        echo "audit: --plugin-root requires a directory" >&2
        USAGE_ERR=1
        break
      fi
      PLUGIN_OPT="$2"
      shift 2
      ;;
    --all)
      echo "audit: --all is not supported (scope is user-global + current project)" >&2
      usage
      exit 64
      ;;
    -h|--help) usage; exit 0 ;;
    --)
      shift
      break
      ;;
    -*)
      echo "audit: unknown flag: $1" >&2
      USAGE_ERR=1
      break
      ;;
    *)
      echo "audit: unexpected argument: $1" >&2
      USAGE_ERR=1
      break
      ;;
  esac
done

if [ "$USAGE_ERR" -eq 1 ]; then
  usage
  exit 64
fi

if [ -z "$HOME_OPT" ]; then
  HOME_OPT=$(printf '%s\n' "${HOME:-}")
fi
if [ -z "$CWD_OPT" ]; then
  CWD_OPT=$(pwd)
fi
CWD_OPT=$(CDPATH= cd -- "$CWD_OPT" && pwd) || {
  echo "audit: cannot cd to --cwd" >&2
  exit 64
}
HOME_OPT=$(CDPATH= cd -- "$HOME_OPT" && pwd) || {
  echo "audit: cannot cd to --home" >&2
  exit 64
}
if [ -n "$PLUGIN_OPT" ]; then
  PLUGIN_ROOT=$(CDPATH= cd -- "$PLUGIN_OPT" && pwd) || {
    echo "audit: cannot cd to --plugin-root" >&2
    exit 64
  }
fi

if [ "$CMD" = "apply" ]; then
  if [ -z "$FROM_JSON" ]; then
    echo "audit: apply requires --from-json (inventory is read-only)" >&2
    usage
    exit 64
  fi
  if [ ! -f "$APPLY_PY" ]; then
    echo "audit: apply.py not found" >&2
    exit 2
  fi
  if ! command -v python3 >/dev/null 2>&1; then
    echo "audit: python3 required for apply" >&2
    exit 2
  fi
  set -- python3 "$APPLY_PY" --from-json "$FROM_JSON" --id "$APPLY_IDS" --home "$HOME_OPT"
  [ "$JUDGMENT" -eq 1 ] && set -- "$@" --judgment
  [ "$YES" -eq 1 ] && set -- "$@" --yes
  [ "$DRY" -eq 1 ] && set -- "$@" --dry-run
  exec "$@"
fi

if [ -n "$FROM_SESSION" ]; then
  # Locate line is stderr so --json stdout stays a single JSON document (CDT-201).
  bash "$FROM_SESS" --session-id "$FROM_SESSION" --cwd "$CWD_OPT" >&2 || exit $?
fi

# ---------------------------------------------------------------------------
# Inventory (read-only vs project/home trees)
# ---------------------------------------------------------------------------
WORK=$(mktemp -d "${TMPDIR:-/tmp}/audit-run.XXXXXX")
cleanup_work() { rm -rf "$WORK"; }
trap cleanup_work EXIT

LAYERS="$WORK/layers.tsv"
SKILLS="$WORK/skills.tsv"
SEEN="$WORK/seen"
: >"$LAYERS"
: >"$SKILLS"
: >"$SEEN"

mtime_iso() {
  local f="$1" epoch
  epoch=$(stat -c %Y "$f" 2>/dev/null || stat -f %m "$f")
  date -u -d "@$epoch" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
    || date -u -r "$epoch" +%Y-%m-%dT%H:%M:%SZ
}

add_file() {
  local path="$1" layer="$2" kind="$3" hosts="${4:-claude+grok}"
  local abs bytes mt
  [ -f "$path" ] || return 0
  abs=$(CDPATH= cd -- "$(dirname -- "$path")" && pwd)/$(basename -- "$path")
  if grep -Fxq -- "$abs" "$SEEN"; then
    return 0
  fi
  printf '%s\n' "$abs" >>"$SEEN"
  bytes=$(wc -c <"$abs" | tr -d ' ')
  mt=$(mtime_iso "$abs")
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$abs" "$layer" "$kind" "$hosts" "$bytes" "$mt" >>"$LAYERS"
}

scan_dir() {
  local dir="$1" layer="$2"
  [ -d "$dir" ] || return 0
  add_file "$dir/CLAUDE.md" "$layer" "CLAUDE.md"
  add_file "$dir/AGENTS.md" "$layer" "AGENTS.md"
}

scan_directives() {
  local root="$1" layer="$2"
  local f
  [ -d "$root/.claude/memory" ] || return 0
  for f in "$root/.claude/memory/"*/directives.md; do
    [ -f "$f" ] || continue
    add_file "$f" "$layer" "directives.md"
  done
}

# user-global: Claude + shared ~/.claude; Grok also ~/.grok/AGENTS.md (CDT-201)
scan_dir "$HOME_OPT/.claude" "user-global"
add_file "$HOME_OPT/.grok/AGENTS.md" "user-global" "AGENTS.md" "grok"
add_file "$HOME_OPT/.grok/CLAUDE.md" "user-global" "CLAUDE.md" "grok"
scan_directives "$HOME_OPT" "directives"

PROJECT="$CWD_OPT"
if PROJECT=$(git -C "$CWD_OPT" rev-parse --show-toplevel 2>/dev/null); then
  :
else
  PROJECT="$CWD_OPT"
fi

MROOT="$PROJECT"
_gc=""
# Resolve common-dir from --cwd (git -C), never invoker pwd (CDT-201 / TL MROOT).
if _gc=$(git -C "$CWD_OPT" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) \
   && [ -n "$_gc" ]; then
  :
elif _gc=$(git -C "$CWD_OPT" rev-parse --git-common-dir 2>/dev/null) && [ -n "$_gc" ]; then
  case "$_gc" in
    /*) ;;
    *)
      if command -v python3 >/dev/null 2>&1; then
        _gc=$(python3 -c 'import os,sys; p=sys.argv[2]; print(os.path.realpath(p if os.path.isabs(p) else os.path.join(sys.argv[1], p)))' "$CWD_OPT" "$_gc")
      else
        _gc="$CWD_OPT/$_gc"
      fi
      ;;
  esac
else
  _gc=""
fi
if [ -n "$_gc" ]; then
  MROOT=$(CDPATH= cd -- "$(dirname -- "$_gc")" && pwd) || MROOT="$PROJECT"
fi

dir="$CWD_OPT"
while :; do
  layer="parent"
  if [ "$dir" = "$PROJECT" ]; then
    layer="project"
  elif [ "$dir" = "$HOME_OPT" ]; then
    layer="user-home"
  fi
  if [ "$dir" != "$HOME_OPT/.claude" ]; then
    scan_dir "$dir" "$layer"
  fi
  parent=$(dirname -- "$dir")
  if [ "$parent" = "$dir" ]; then
    break
  fi
  dir="$parent"
done

scan_directives "$MROOT" "directives"
if [ "$MROOT" != "$PROJECT" ]; then
  scan_directives "$PROJECT" "directives"
fi

# skill-size (plugin tree only — not --all repos)
for skill_md in "$PLUGIN_ROOT/skills/"*/SKILL.md; do
  [ -f "$skill_md" ] || continue
  name=$(basename -- "$(dirname -- "$skill_md")")
  abs=$(CDPATH= cd -- "$(dirname -- "$skill_md")" && pwd)/$(basename -- "$skill_md")
  bytes=$(wc -c <"$abs" | tr -d ' ')
  status=ok
  if [ "$bytes" -gt "$SKILL_WARN_BYTES" ]; then
    status=WARN
  fi
  printf '%s\t%s\t%s\t%s\n' "$name" "$abs" "$bytes" "$status" >>"$SKILLS"
done

if ! command -v python3 >/dev/null 2>&1; then
  echo "audit: python3 required to render inventory" >&2
  exit 2
fi

python3 - "$LAYERS" "$SKILLS" "$HOME_OPT" "$CWD_OPT" "$PLUGIN_ROOT" \
  "$JSON_MODE" "$SKILL_WARN_BYTES" "$SKILL_HARD_BYTES" <<'PY'
import json
import sys

layers_p, skills_p, home, cwd, plugin, json_mode, warn_b, hard_b = sys.argv[1:]
json_mode = json_mode == "1"
warn_b = int(warn_b)
hard_b = int(hard_b)

def read_tsv(path):
    rows = []
    with open(path, encoding="utf-8") as fh:
        for line in fh:
            line = line.rstrip("\n")
            if line:
                rows.append(line.split("\t"))
    return rows

layers = []
for cols in read_tsv(layers_p):
    path, layer, kind, hosts, bytes_, mtime = cols
    layers.append({
        "layer": layer,
        "kind": kind,
        "path": path,
        "hosts": hosts,
        "bytes": int(bytes_),
        "mtime": mtime,
    })

skills = []
findings = []
for cols in read_tsv(skills_p):
    name, path, bytes_, status = cols
    n = int(bytes_)
    skills.append({"name": name, "path": path, "bytes": n, "status": status})
    if status == "WARN":
        findings.append({
            "id": "SS-%s" % name,
            "class": "plugin-surface",
            "layer": "plugin",
            "path": path,
            "impact": "SKILL.md exceeds 30KB WARN; split via PR (apply will not rewrite skills/**)",
            "action": {"type": "none", "note": "PR only"},
            "confidence": 1.0,
            "evidence": {
                "passages": [
                    {"path": path, "quote": "%d bytes" % n, "line": 1},
                    {"path": "skills/audit/SKILL.md", "quote": "WARN 30KB (30720 bytes)", "line": 1},
                ],
                "counts": {"bytes": n},
                "mtime": "",
                "spec": {"id": "SPEC-035", "quote": "SKILL.md WARN 30KB"},
            },
        })

skills.sort(key=lambda r: r["bytes"], reverse=True)
doc = {
    "audit_schema": "1",
    "scope": {
        "home": home,
        "cwd": cwd,
        "plugin_root": plugin,
        "hosts": ["claude", "grok"],
        "note": "walk-up AGENTS.md/CLAUDE.md; Grok user-global ~/.grok/AGENTS.md + shared ~/.claude/CLAUDE.md",
    },
    "thresholds": {"skill_warn_bytes": warn_b, "skill_hard_bytes": hard_b},
    "layers": layers,
    "skills": skills,
    "findings": findings,
}

if json_mode:
    print(json.dumps(doc, indent=2))
else:
    print("# /audit — instruction stack")
    print()
    print("Hosts: claude+grok (walk-up; Grok also ~/.grok/AGENTS.md + ~/.claude/CLAUDE.md)")
    print("Scope: user-global + current project (parents -> project)")
    print()
    print("## Layers")
    print("| Layer | Kind | Hosts | Bytes | Path |")
    print("|-------|------|-------|-------|------|")
    for row in layers:
        print("| %s | %s | %s | %s | %s |" % (
            row["layer"], row["kind"], row["hosts"], row["bytes"], row["path"]))
    print()
    print("## Skill size")
    print("WARN > %d bytes (30KB); must-split %d bytes (40KB). Top by size:" % (warn_b, hard_b))
    print("| Status | Bytes | Skill |")
    print("|--------|-------|-------|")
    for row in skills[:12]:
        print("| %s | %s | %s |" % (row["status"], row["bytes"], row["name"]))
    print()
    print("## Findings")
    if not findings:
        print("(none mechanical)")
    for f in findings:
        print("- %s [%s] %s" % (f["id"], f["class"], f["impact"]))
    print()
    print("Apply is approve-then-apply on instruction-stack files only.")
PY

WARN=0
if awk -F '\t' '$4=="WARN" { found=1 } END { exit found?0:1 }' "$SKILLS"; then
  WARN=1
fi

if [ "$WARN" -eq 1 ]; then
  exit 1
fi
exit 0
