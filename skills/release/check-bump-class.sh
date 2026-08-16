#!/usr/bin/env bash
# SPEC-010 bump-class gate: a new commands/*.md requires minor or major.
# Pure subprocess — no LLM, no network, no index mutation.
#
# Usage:
#   check-bump-class.sh                 # worktree+index vs HEAD (/release)
#   check-bump-class.sh --cached        # index vs HEAD (pre-commit)
#   check-bump-class.sh --against REF   # same as default but vs REF
#   check-bump-class.sh --commit REV    # REV vs its parent (CI)
#
# Exit: 0 ok · 1 new Surface with patch/none · 64 usage
# THIS SCRIPT IS A SUBPROCESS CLI — NEVER SOURCE IT.
set -euo pipefail

usage() {
  cat >&2 <<'EOF'
Usage: check-bump-class.sh [--cached] [--against REF] [--commit REV]

A newly added commands/*.md file requires plugin.json to bump minor or major
(not patch, not unchanged). Edits to existing commands are not a new Surface.

Exit 0 ok; 1 bump-class violation; 64 usage. Does not mutate the index.
EOF
}

MODE=worktree
AGAINST=""
COMMIT=""

while [ $# -gt 0 ]; do
  case "$1" in
    --cached) MODE=cached; shift ;;
    --against)
      [ $# -ge 2 ] && [ -n "${2:-}" ] || { echo "check-bump-class.sh: --against requires a ref" >&2; usage; exit 64; }
      AGAINST="$2"
      shift 2
      ;;
    --commit)
      [ $# -ge 2 ] && [ -n "${2:-}" ] || { echo "check-bump-class.sh: --commit requires a rev" >&2; usage; exit 64; }
      MODE=commit
      COMMIT="$2"
      shift 2
      ;;
    -h|--help) usage; exit 64 ;;
    --*)
      echo "check-bump-class.sh: unknown flag: $1" >&2
      usage
      exit 64
      ;;
    *)
      echo "check-bump-class.sh: unexpected argument: $1" >&2
      usage
      exit 64
      ;;
  esac
done

if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "check-bump-class.sh: not a git repository" >&2
  exit 64
fi

ROOT=$(git rev-parse --show-toplevel)
cd "$ROOT"

json_ver() {
  # stdin → first "version": "x.y.z"
  sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1
}

strip_v() {
  local v="$1"
  v="${v#v}"
  printf '%s\n' "$v"
}

bump_class() {
  local old new oM om op nM nm np
  old=$(strip_v "$1")
  new=$(strip_v "$2")
  if [ "$old" = "$new" ]; then
    printf '%s\n' none
    return 0
  fi
  case "$old" in
    ''|*[!0-9.]*) printf '%s\n' invalid; return 0 ;;
  esac
  case "$new" in
    ''|*[!0-9.]*) printf '%s\n' invalid; return 0 ;;
  esac
  oM=0; om=0; op=0
  nM=0; nm=0; np=0
  IFS=. read -r oM om op _ <<EOF
$old
EOF
  IFS=. read -r nM nm np _ <<EOF
$new
EOF
  oM=${oM:-0}; om=${om:-0}; op=${op:-0}
  nM=${nM:-0}; nm=${nm:-0}; np=${np:-0}
  case "$oM$om$op$nM$nm$np" in
    *[!0-9]*) printf '%s\n' invalid; return 0 ;;
  esac
  if [ "$nM" -gt "$oM" ]; then
    printf '%s\n' major
  elif [ "$nM" -eq "$oM" ] && [ "$nm" -gt "$om" ]; then
    printf '%s\n' minor
  elif [ "$nM" -eq "$oM" ] && [ "$nm" -eq "$om" ] && [ "$np" -gt "$op" ]; then
    printf '%s\n' patch
  else
    printf '%s\n' invalid
  fi
}

added=()
old_ver=""
new_ver=""

if [ "$MODE" = "commit" ]; then
  COMMIT=$(git rev-parse --verify "${COMMIT}^{commit}" 2>/dev/null) || {
    echo "check-bump-class.sh: unresolvable --commit" >&2
    exit 64
  }
  if ! git rev-parse --verify "${COMMIT}^" >/dev/null 2>&1; then
    echo "check-bump-class.sh: --commit has no parent (skip)" >&2
    exit 0
  fi
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    case "$p" in
      commands/*.md) added+=("$p") ;;
    esac
  done < <(git diff-tree --no-commit-id --name-only --diff-filter=A -r "$COMMIT^" "$COMMIT" -- commands/)
  old_ver=$(git show "${COMMIT}^:.claude-plugin/plugin.json" 2>/dev/null | json_ver || true)
  new_ver=$(git show "${COMMIT}:.claude-plugin/plugin.json" 2>/dev/null | json_ver || true)
else
  if [ -z "$AGAINST" ]; then
    AGAINST=HEAD
  fi
  git rev-parse --verify "$AGAINST" >/dev/null 2>&1 || {
    echo "check-bump-class.sh: unresolvable --against $AGAINST" >&2
    exit 64
  }
  if [ "$MODE" = "cached" ]; then
    while IFS= read -r p; do
      [ -n "$p" ] || continue
      case "$p" in
        commands/*.md) added+=("$p") ;;
      esac
    done < <(git diff --cached --name-only --diff-filter=A "$AGAINST" -- commands/)
    if git diff --cached --name-only -- .claude-plugin/plugin.json | grep -qx '.claude-plugin/plugin.json'; then
      new_ver=$(git show ":.claude-plugin/plugin.json" | json_ver || true)
    elif [ -f .claude-plugin/plugin.json ]; then
      new_ver=$(json_ver < .claude-plugin/plugin.json || true)
    fi
  else
    while IFS= read -r p; do
      [ -n "$p" ] || continue
      case "$p" in
        commands/*.md) added+=("$p") ;;
      esac
    done < <(git diff --name-only --diff-filter=A "$AGAINST" -- commands/)
    # Untracked commands/*.md ( /release runs this before git add )
    while IFS= read -r p; do
      [ -n "$p" ] || continue
      case "$p" in
        commands/*.md) added+=("$p") ;;
      esac
    done < <(git ls-files --others --exclude-standard -- commands/)
    if [ -f .claude-plugin/plugin.json ]; then
      new_ver=$(json_ver < .claude-plugin/plugin.json || true)
    fi
  fi
  old_ver=$(git show "${AGAINST}:.claude-plugin/plugin.json" 2>/dev/null | json_ver || true)
fi

if [ "${#added[@]}" -eq 0 ]; then
  echo "bump-class: no new commands/*.md — ok"
  exit 0
fi

old_ver=${old_ver:-0.0.0}
new_ver=${new_ver:-}
if [ -z "$new_ver" ]; then
  echo "bump-class: new command surface(s) but plugin.json version unreadable" >&2
  printf '  %s\n' "${added[@]}" >&2
  echo "  new command surfaces require a minor or major bump (AGENTS.md)" >&2
  echo "  MUST NOT commit/tag/push" >&2
  exit 1
fi

klass=$(bump_class "$old_ver" "$new_ver")
case "$klass" in
  minor|major)
    echo "bump-class: ${#added[@]} new command(s), $old_ver -> $new_ver ($klass) — ok"
    exit 0
    ;;
esac

echo "bump-class: new command surface(s) require a minor or major bump, not ${klass}" >&2
printf '  %s\n' "${added[@]}" >&2
echo "  plugin.json: $old_ver -> $new_ver ($klass)" >&2
echo "  AGENTS.md: new command surfaces = minor" >&2
echo "  MUST NOT commit/tag/push" >&2
exit 1
