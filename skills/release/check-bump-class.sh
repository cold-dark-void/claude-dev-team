#!/usr/bin/env bash
# SPEC-010 bump-class gate: a new commands/*.md requires minor or major.
# Pure subprocess — no LLM, no network, no index mutation.
#
# Usage:
#   check-bump-class.sh                 # worktree+index vs HEAD (/release)
#   check-bump-class.sh --cached        # index vs HEAD (pre-commit)
#   check-bump-class.sh --against REF   # same as default but vs REF
#   check-bump-class.sh --commit REV    # REV vs its parent (CI)
#   check-bump-class.sh --range BASE..TIP  # each non-merge commit in the range (CI)
#
# Exit: 0 ok · 1 new Surface with patch/none · 64 usage
# THIS SCRIPT IS A SUBPROCESS CLI — NEVER SOURCE IT.
set -euo pipefail

usage() {
  cat >&2 <<'EOF'
Usage: check-bump-class.sh [--cached] [--against REF] [--commit REV] [--range BASE..TIP]

A newly added top-level commands/*.md file requires plugin.json to bump minor
or major (not patch, not unchanged). Edits to existing commands, and files
under commands/*/, are not a new Surface.

Version classification uses the X.Y.Z core. Equal cores with a different
full string classify on the core's own shape (X.0.0 major, X.Y.0 minor,
else patch). A release followed by a pre-release of the same core is
invalid.

--range BASE..TIP runs commit mode (self-invoked) over every non-merge
commit in the range and reports each failing commit.

Exit 0 ok; 1 bump-class violation; 64 usage. Does not mutate the index.
EOF
}

MODE=worktree
AGAINST=""
COMMIT=""
RANGE=""
has_cached=0
has_against=0
has_commit=0
has_range=0

while [ $# -gt 0 ]; do
  case "$1" in
    --cached) MODE=cached; has_cached=1; shift ;;
    --against)
      [ $# -ge 2 ] && [ -n "${2:-}" ] || { echo "check-bump-class.sh: --against requires a ref" >&2; usage; exit 64; }
      AGAINST="$2"
      has_against=1
      shift 2
      ;;
    --commit)
      [ $# -ge 2 ] && [ -n "${2:-}" ] || { echo "check-bump-class.sh: --commit requires a rev" >&2; usage; exit 64; }
      MODE=commit
      COMMIT="$2"
      has_commit=1
      shift 2
      ;;
    --range)
      [ $# -ge 2 ] && [ -n "${2:-}" ] || { echo "check-bump-class.sh: --range requires BASE..TIP" >&2; usage; exit 64; }
      MODE=range
      RANGE="$2"
      has_range=1
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

if [ "$has_range" -eq 1 ] && { [ "$has_cached" -eq 1 ] || [ "$has_against" -eq 1 ] || [ "$has_commit" -eq 1 ]; }; then
  echo "check-bump-class.sh: --range is mutually exclusive with --commit/--cached/--against" >&2
  usage
  exit 64
fi

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

split_core_pre() {
  # $1 = v-stripped version. Sets CORE_OUT (before -pre, after stripping +build)
  # and PRE_OUT (the -pre... tail, without the leading '-'; empty if none).
  local v="$1"
  v="${v%%+*}"
  case "$v" in
    *-*) CORE_OUT="${v%%-*}"; PRE_OUT="${v#*-}" ;;
    *)   CORE_OUT="$v"; PRE_OUT="" ;;
  esac
}

parse_core() {
  # $1 = core string. On success prints "M m p" and returns 0; else returns 1.
  local core="$1" parts
  case "$core" in
    ''|*[!0-9.]*) return 1 ;;
  esac
  IFS=. read -ra parts <<<"$core"
  [ "${#parts[@]}" -eq 3 ] || return 1
  local M="${parts[0]}" m="${parts[1]}" p="${parts[2]}"
  [ -n "$M" ] && [ -n "$m" ] && [ -n "$p" ] || return 1
  printf '%s %s %s\n' "$M" "$m" "$p"
}

core_line_class() {
  # $1 $2 $3 = M m p of a core. Echoes the core's own line class.
  if [ "$2" -eq 0 ] && [ "$3" -eq 0 ]; then
    printf '%s\n' major
  elif [ "$3" -eq 0 ]; then
    printf '%s\n' minor
  else
    printf '%s\n' patch
  fi
}

bump_class() {
  local old new ocore opre ncore npre oparts nparts oM om op nM nm np
  old=$(strip_v "$1")
  new=$(strip_v "$2")
  if [ "$old" = "$new" ]; then
    printf '%s\n' none
    return 0
  fi
  split_core_pre "$old"; ocore="$CORE_OUT"; opre="$PRE_OUT"
  split_core_pre "$new"; ncore="$CORE_OUT"; npre="$PRE_OUT"
  oparts=$(parse_core "$ocore") || { printf '%s\n' invalid; return 0; }
  nparts=$(parse_core "$ncore") || { printf '%s\n' invalid; return 0; }
  read -r oM om op <<<"$oparts"
  read -r nM nm np <<<"$nparts"
  if [ "$ocore" = "$ncore" ]; then
    if [ -z "$opre" ] && [ -n "$npre" ]; then
      printf '%s\n' invalid
      return 0
    fi
    core_line_class "$nM" "$nm" "$np"
    return 0
  fi
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

if [ "$MODE" = "range" ]; then
  case "$RANGE" in
    *..*) RBASE="${RANGE%%..*}"; RTIP="${RANGE#*..}" ;;
    *)
      echo "check-bump-class.sh: --range requires BASE..TIP" >&2
      exit 64
      ;;
  esac
  if [ -z "$RBASE" ] || [ -z "$RTIP" ]; then
    echo "check-bump-class.sh: --range requires BASE..TIP" >&2
    exit 64
  fi
  git rev-parse --verify "${RBASE}^{commit}" >/dev/null 2>&1 || {
    echo "check-bump-class.sh: unresolvable --range base: $RBASE" >&2
    exit 64
  }
  git rev-parse --verify "${RTIP}^{commit}" >/dev/null 2>&1 || {
    echo "check-bump-class.sh: unresolvable --range tip: $RTIP" >&2
    exit 64
  }
  range_commits=()
  while IFS= read -r rc_line; do
    [ -n "$rc_line" ] || continue
    range_commits+=("$rc_line")
  done < <(git rev-list --no-merges --reverse "${RBASE}..${RTIP}")
  if [ "${#range_commits[@]}" -eq 0 ]; then
    echo "bump-class: empty range — ok"
    exit 0
  fi
  range_failed=0
  for rc_commit in "${range_commits[@]}"; do
    rc_out=$(bash "$0" --commit "$rc_commit" 2>&1) && rc_rc=0 || rc_rc=$?
    if [ "$rc_rc" -ne 0 ]; then
      range_failed=1
      rc_short=$(git rev-parse --short "$rc_commit")
      echo "bump-class: ${rc_short}: ${rc_out}" >&2
    fi
  done
  if [ "$range_failed" -eq 1 ]; then
    exit 1
  fi
  exit 0
fi

# True if p is a new top-level command surface: commands/<name>.md (not
# commands/<sub>/<name>.md — nested paths are not a new Surface).
is_surface_path() {
  [[ "$1" =~ ^commands/[^/]+\.md$ ]]
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
    if is_surface_path "$p"; then
      added+=("$p")
    fi
  done < <(git diff-tree --no-commit-id --no-renames --name-only --diff-filter=A -r "$COMMIT^" "$COMMIT" -- commands/)
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
      if is_surface_path "$p"; then
        added+=("$p")
      fi
    done < <(git diff --cached --no-renames --name-only --diff-filter=A "$AGAINST" -- commands/)
    new_ver=$(git show ":.claude-plugin/plugin.json" 2>/dev/null | json_ver || true)
  else
    while IFS= read -r p; do
      [ -n "$p" ] || continue
      if is_surface_path "$p"; then
        added+=("$p")
      fi
    done < <(git diff --no-renames --name-only --diff-filter=A "$AGAINST" -- commands/)
    # Untracked commands/*.md ( /release runs this before git add )
    while IFS= read -r p; do
      [ -n "$p" ] || continue
      if is_surface_path "$p"; then
        added+=("$p")
      fi
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
