#!/usr/bin/env bash
#
# resolve-root.sh — handoff write root from TARGET session project (CDT-80).
#
# Packet / M8 cache / git appendix MUST use the target session's project, never
# the invoker's cwd. Cold `/handoff <uuid>` from ~/.claude or /tmp for a
# claude-dev-team session writes under that repo's `.claude/handoff/`, not
# `~/.claude/.claude/handoff/`.
#
# Usage:
#   resolve-root.sh --transcript <path>
#   resolve-root.sh --project <dir>
#   resolve-root.sh --uuid <uuid>   # locate via transcript-parse, then resolve
#
# Stdout (3 lines):
#   PROJECT_DIR   — session project cwd (worktree path when applicable)
#   MROOT         — git-common-dir root (shared across worktrees); else PROJECT_DIR
#   HANDOFF_DIR   — $MROOT/.claude/handoff
#
# Exit 1 if undetermined — fail hard, never fall back to invoker cwd (AC4).
#
# Env:
#   CLAUDE_PROJECTS_DIR  — only used indirectly via assemble locate for --uuid
#   RESOLVE_ROOT_ASSEMBLE — override path to assemble.py (tests)
#
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PARSE_DIR=$(CDPATH= cd -- "$SCRIPT_DIR/../transcript-parse" 2>/dev/null && pwd || true)
ASSEMBLE="${RESOLVE_ROOT_ASSEMBLE:-$PARSE_DIR/assemble.py}"

usage() {
  cat >&2 <<'EOF'
Usage: resolve-root.sh --transcript <path>
       resolve-root.sh --project <dir>
       resolve-root.sh --uuid <uuid>
Prints PROJECT_DIR, MROOT, HANDOFF_DIR (one per line). Exit 1 if undetermined.
EOF
  exit 1
}

TRANSCRIPT=""
PROJECT=""
UUID=""
while [ $# -gt 0 ]; do
  case "$1" in
    --transcript)
      [ $# -ge 2 ] || usage
      TRANSCRIPT="$2"; shift 2 ;;
    --transcript=*)
      TRANSCRIPT="${1#--transcript=}"; shift ;;
    --project)
      [ $# -ge 2 ] || usage
      PROJECT="$2"; shift 2 ;;
    --project=*)
      PROJECT="${1#--project=}"; shift ;;
    --uuid)
      [ $# -ge 2 ] || usage
      UUID="$2"; shift 2 ;;
    --uuid=*)
      UUID="${1#--uuid=}"; shift ;;
    -h|--help) usage ;;
    *)
      echo "resolve-root.sh: unknown argument: $1" >&2
      usage ;;
  esac
done

if [ -n "$PROJECT" ] && [ -n "$TRANSCRIPT" ]; then
  echo "resolve-root.sh: pass only one of --project / --transcript" >&2
  exit 1
fi
if [ -n "$UUID" ] && { [ -n "$PROJECT" ] || [ -n "$TRANSCRIPT" ]; }; then
  echo "resolve-root.sh: --uuid is exclusive of --project / --transcript" >&2
  exit 1
fi
if [ -z "$PROJECT" ] && [ -z "$TRANSCRIPT" ] && [ -z "$UUID" ]; then
  usage
fi

# Locate transcript for --uuid
if [ -n "$UUID" ]; then
  if [ ! -f "$ASSEMBLE" ]; then
    echo "resolve-root.sh: assemble.py not found at $ASSEMBLE" >&2
    exit 1
  fi
  set +e
  TRANSCRIPT=$(python3 "$ASSEMBLE" locate "$UUID" 2>/dev/null)
  loc_rc=$?
  set -e
  if [ "$loc_rc" -ne 0 ] || [ -z "$TRANSCRIPT" ] || [ ! -f "$TRANSCRIPT" ]; then
    echo "resolve-root.sh: cannot locate transcript for uuid $UUID" >&2
    exit 1
  fi
fi

# Resolve PROJECT_DIR from --project or transcript cwd / project-dir decode
if [ -n "$PROJECT" ]; then
  if [ ! -d "$PROJECT" ]; then
    echo "resolve-root.sh: --project is not a directory: $PROJECT" >&2
    exit 1
  fi
  PROJECT_DIR=$(CDPATH= cd -- "$PROJECT" && pwd)
else
  if [ ! -f "$TRANSCRIPT" ]; then
    echo "resolve-root.sh: transcript not found: $TRANSCRIPT" >&2
    exit 1
  fi
  PROJECT_DIR=$(
    TRANSCRIPT="$TRANSCRIPT" python3 - <<'PY'
import json
import os
import sys
from collections import Counter

path = os.environ["TRANSCRIPT"]
counts = Counter()
# Bound scan: cwd is dense in real transcripts; fixtures are tiny.
max_lines = 20000
try:
    with open(path, "r", errors="replace") as fh:
        for i, line in enumerate(fh):
            if i >= max_lines:
                break
            line = line.strip()
            if not line:
                continue
            try:
                obj = json.loads(line)
            except (ValueError, TypeError):
                continue
            if not isinstance(obj, dict):
                continue
            cwd = obj.get("cwd")
            if isinstance(cwd, str) and cwd.startswith("/") and len(cwd) > 1:
                counts[cwd] += 1
except OSError as e:
    sys.stderr.write(f"resolve-root.sh: cannot read transcript: {e}\n")
    sys.exit(1)

if counts:
    # Prefer most common cwd (stable for multi-cwd rare drift).
    best = counts.most_common(1)[0][0]
    sys.stdout.write(best)
    sys.exit(0)

# Fallback: greedy FS decode of ~/.claude/projects/<encoded>/ parent name.
# Encoding: non [A-Za-z0-9] → '-' (so / and . both become -). Lossy; cwd preferred.
projects = os.path.join(os.path.expanduser("~"), ".claude", "projects")
abs_tr = os.path.abspath(path)
proj_root = None
if abs_tr.startswith(projects + os.sep):
    rel = abs_tr[len(projects) + 1 :]
    enc = rel.split(os.sep, 1)[0] if rel else ""
    if enc.startswith("-"):
        rest = enc[1:]
        parts = []
        cur = "/"
        while rest:
            try:
                children = os.listdir(cur)
            except OSError:
                children = []
            best_child = None
            for child in children:
                # Match full segment: rest == child OR rest starts with child + "-"
                if rest == child or rest.startswith(child + "-"):
                    if best_child is None or len(child) > len(best_child):
                        best_child = child
            if best_child is None:
                break
            parts.append(best_child)
            rest = rest[len(best_child) :]
            if rest.startswith("-"):
                rest = rest[1:]
            elif rest:
                # leftover without separator — decode failed
                parts = []
                break
            cur = os.path.join("/", *parts)
        if parts and not rest:
            cand = os.path.join("/", *parts)
            if os.path.isdir(cand):
                proj_root = cand

if proj_root:
    sys.stdout.write(proj_root)
    sys.exit(0)

sys.stderr.write(
    "resolve-root.sh: cannot determine project dir from transcript "
    f"(no cwd, decode failed): {path}\n"
)
sys.exit(1)
PY
  ) || exit 1

  if [ ! -d "$PROJECT_DIR" ]; then
    echo "resolve-root.sh: resolved project dir does not exist: $PROJECT_DIR" >&2
    exit 1
  fi
  PROJECT_DIR=$(CDPATH= cd -- "$PROJECT_DIR" && pwd)
fi

# MROOT: git-common-dir from PROJECT_DIR (worktree → shared main). Non-git → PROJECT_DIR.
mroot_from_project() {
  local dir="$1"
  local gc
  if gc=$(git -C "$dir" rev-parse --git-common-dir 2>/dev/null); then
    # git-common-dir may be relative to dir
    if [ "${gc#/}" != "$gc" ]; then
      ( CDPATH= cd -- "$(dirname -- "$gc")" && pwd )
    else
      ( CDPATH= cd -- "$dir" && CDPATH= cd -- "$(dirname -- "$gc")" && pwd )
    fi
    return 0
  fi
  printf '%s' "$dir"
}

MROOT=$(mroot_from_project "$PROJECT_DIR")
if [ -z "$MROOT" ] || [ ! -d "$MROOT" ]; then
  echo "resolve-root.sh: cannot resolve MROOT from $PROJECT_DIR" >&2
  exit 1
fi

HANDOFF_DIR="$MROOT/.claude/handoff"

# Safety: never silently land under $HOME/.claude/.claude/ when the target
# project is not itself $HOME/.claude (AC1/AC9 anti-pattern).
HOME_CLAUDE="${HOME}/.claude"
NESTED="${HOME_CLAUDE}/.claude"
case "$HANDOFF_DIR" in
  "$NESTED"|"$NESTED"/*)
    if [ "$MROOT" != "$HOME_CLAUDE" ]; then
      echo "resolve-root.sh: refusing nested write path $HANDOFF_DIR (target MROOT=$MROOT)" >&2
      exit 1
    fi
    ;;
esac

printf '%s\n' "$PROJECT_DIR"
printf '%s\n' "$MROOT"
printf '%s\n' "$HANDOFF_DIR"
