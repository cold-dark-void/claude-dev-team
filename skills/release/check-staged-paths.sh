#!/usr/bin/env bash
# SPEC-010 staged-path hard gate (CDT-189 S1–S6).
# Fail-closed: every staged path must be in the allowed set.
# Pure subprocess — no LLM, no network, no index mutation.
#
# Usage:
#   check-staged-paths.sh --intended PATH [PATH...] [--allow-extra PATH...]
#
# Exit codes:
#   0  — staged ⊆ allowed (empty staged is OK)
#   1  — foreign staged path(s)
#  64  — usage error / not a git repo
set -euo pipefail

usage() {
  cat >&2 <<'EOF'
Usage: check-staged-paths.sh --intended PATH [PATH...] [--allow-extra PATH...]

Allowed set = CHANGELOG.md + .claude-plugin/plugin.json
              + all --intended paths + all --allow-extra paths.

Exit 0 if every staged path is in allowed; exit 1 on foreign staged path(s);
exit 64 on usage errors. Does not mutate the index or worktree.
EOF
}

intended=()
allow_extra=()
mode=""
saw_intended=0

while [ $# -gt 0 ]; do
  case "$1" in
    --intended)
      saw_intended=1
      mode=intended
      shift
      ;;
    --allow-extra)
      mode=allow_extra
      shift
      ;;
    -h|--help)
      usage
      exit 64
      ;;
    --*)
      echo "check-staged-paths.sh: unknown flag: $1" >&2
      usage
      exit 64
      ;;
    *)
      if [ "$mode" = "intended" ]; then
        intended+=("$1")
      elif [ "$mode" = "allow_extra" ]; then
        allow_extra+=("$1")
      else
        echo "check-staged-paths.sh: unexpected argument before flags: $1" >&2
        usage
        exit 64
      fi
      shift
      ;;
  esac
done

if [ "$saw_intended" -eq 0 ]; then
  echo "check-staged-paths.sh: --intended is required" >&2
  usage
  exit 64
fi

if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "check-staged-paths.sh: not a git repository" >&2
  exit 64
fi

ROOT=$(git rev-parse --show-toplevel)

# Always-allowed version pair (S2 / AC-3)
allowed=("CHANGELOG.md" ".claude-plugin/plugin.json")
if [ ${#intended[@]} -gt 0 ]; then
  allowed+=("${intended[@]}")
fi
if [ ${#allow_extra[@]} -gt 0 ]; then
  allowed+=("${allow_extra[@]}")
fi

is_allowed() {
  local p="$1" a
  for a in "${allowed[@]}"; do
    if [ "$p" = "$a" ]; then
      return 0
    fi
  done
  return 1
}

foreign=()
# S3: staged set only — never unstaged/untracked
while IFS= read -r path; do
  [ -z "$path" ] && continue
  if ! is_allowed "$path"; then
    foreign+=("$path")
  fi
done < <(git -C "$ROOT" diff --cached --name-only)

if [ ${#foreign[@]} -eq 0 ]; then
  exit 0
fi

# S5 / AC-10: name the gate, list every foreign path, forbid commit/tag/push
{
  echo "staged-path hard gate: foreign staged path(s); commit/tag/push MUST NOT proceed"
  for p in "${foreign[@]}"; do
    echo "$p"
  done
} >&2

exit 1
