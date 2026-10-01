#!/usr/bin/env bash
# Stage exactly the reviewed paths. Refuse, and do not git add, when the
# worktree has a dirty or untracked path outside that list.
#   stage-reviewed.sh [-C dir] --list <file>
# The list is one repo-root-relative path per line.
set -eu
cd_dir=""
list=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    -C) cd_dir="$2"; shift 2 ;;
    --list) list="$2"; shift 2 ;;
    *) printf 'stage-reviewed: unknown argument: %s\n' "$1" >&2; exit 64 ;;
  esac
done
[ -n "$list" ] && [ -f "$list" ] || { printf 'stage-reviewed: --list file required\n' >&2; exit 64; }
unset GIT_DIR GIT_WORK_TREE
if [ -n "$cd_dir" ]; then
  root=$(git -C "$cd_dir" rev-parse --show-toplevel 2>/dev/null) || exit 2
else
  root=$(git rev-parse --show-toplevel 2>/dev/null) || exit 2
fi

allowed=$(mktemp "${TMPDIR:-/tmp}/stage-reviewed.XXXXXX")
trap 'rm -f "$allowed"' EXIT
sed '/^$/d' "$list" | sort -u >"$allowed"

# The dirty set is the changed set (files, including deletions and files
# inside a new directory). Porcelain would collapse a new directory to
# "?? dir/" and quote spaces, which does not match that list.
CHANGED=$(cd "$(dirname "$0")/../lib" && pwd)/changed-set.sh
dirty=$(bash "$CHANGED" -C "$root" paths)
extra=""
while IFS= read -r path; do
  [ -n "$path" ] || continue
  if ! grep -Fxq -- "$path" "$allowed"; then
    extra="${extra}${path}"$'\n'
  fi
done <<EOF
$dirty
EOF

if [ -n "$extra" ]; then
  printf 'stage-reviewed: refusing; paths outside the reviewed set:\n%s' "$extra" >&2
  exit 1
fi

if [ ! -s "$allowed" ]; then
  exit 0
fi
while IFS= read -r path; do
  [ -n "$path" ] || continue
  if [ -e "$root/$path" ] || [ -L "$root/$path" ]; then
    git -C "$root" add -- "$path"
  elif git -C "$root" diff --cached --name-only -- "$path" | grep -Fxq -- "$path"; then
    : # deletion is already staged
  else
    git -C "$root" add -u -- "$path"
  fi
done <"$allowed"
