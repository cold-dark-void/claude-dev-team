#!/usr/bin/env bash
# skills/lib/git-safety.sh — shared git safety primitive (SPEC-025 M17).
#
# THIS SCRIPT IS A SUBPROCESS CLI — NEVER SOURCE IT.
#
#   bash skills/lib/git-safety.sh [-C <dir>] <sub> [args...]
#
# Subcommands:
#   is-clean [--tracked-only] [--ignore-staged] [-- <exclude-path>...]
#   is-merged <ref> <base>
#   is-pushed <ref>
#   safe-delete-branch <branch> <base>
#   safe-reset --stage <base_sha> <staged_tree>
#   safe-reset --clean-at <sha>
#   resolve-base
#
# Exit codes: 0 holds/done; 1 fails/refused (no change); 2 git error;
# 64 usage error (unknown sub, missing args, bad exclude path, extra args).
# Diagnostics go to stderr only; stdout is empty except for `resolve-base`,
# which prints the resolved base ref on a match.
#
# bash 3.2 portable: no mapfile, no declare -A, no ${var,,}, no local -n.
# Path lists that can hold arbitrary bytes are NUL-separated and read with
# `while IFS= read -r -d ''`.

set -u

usage_error() {
  printf 'git-safety: usage error: %s\n' "$1" >&2
  exit 64
}

# --- is-clean ----------------------------------------------------------

cmd_is_clean() {
  local tracked_only=0 ignore_staged=0
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --tracked-only) tracked_only=1; shift ;;
      --ignore-staged) ignore_staged=1; shift ;;
      --) shift; break ;;
      -*) usage_error "is-clean: unknown flag: $1" ;;
      *) usage_error "is-clean: unexpected argument (excludes must follow --): $1" ;;
    esac
  done

  local excludes=() e
  while [ "$#" -gt 0 ]; do
    e="$1"
    case "$e" in
      "") usage_error "is-clean: empty exclude path" ;;
      /*) usage_error "is-clean: exclude path must not be absolute: $e" ;;
      :*) usage_error "is-clean: exclude path must not start with ':': $e" ;;
    esac
    excludes+=("$e")
    shift
  done

  local uf="all"
  [ "$tracked_only" -eq 1 ] && uf="no"

  local pathspecs=(":/")
  for e in ${excludes[@]+"${excludes[@]}"}; do
    pathspecs+=(":(top,exclude)$e")
  done

  local status_out git_rc
  status_out=$(git status --porcelain "--untracked-files=$uf" -- "${pathspecs[@]}" 2>/dev/null)
  git_rc=$?
  if [ "$git_rc" -ne 0 ]; then
    printf 'git-safety: is-clean: git status failed (rc=%s)\n' "$git_rc" >&2
    return 2
  fi

  if [ -z "$status_out" ]; then
    return 0
  fi

  if [ "$ignore_staged" -eq 1 ]; then
    status_out=$(printf '%s\n' "$status_out" | awk 'substr($0,2,1) != " "')
  fi

  if [ -z "$status_out" ]; then
    return 0
  fi
  return 1
}

# --- is-merged -----------------------------------------------------------

cmd_is_merged() {
  [ "$#" -eq 2 ] || usage_error "is-merged: need <ref> <base>"
  local ref="$1" base="$2"

  if git merge-base --is-ancestor "$ref" "$base" 2>/dev/null; then
    return 0
  fi

  local cherry_out cherry_rc cherry_plus
  cherry_out=$(git cherry "$base" "$ref" 2>/dev/null)
  cherry_rc=$?
  if [ "$cherry_rc" -eq 0 ]; then
    cherry_plus=$(printf '%s\n' "$cherry_out" | { grep -c '^+' || true; })
    if [ "${cherry_plus:-0}" -eq 0 ]; then
      return 0
    fi
  fi

  local mb
  mb=$(git merge-base "$ref" "$base" 2>/dev/null)
  [ -n "$mb" ] || return 1

  local tree
  tree=$(git rev-parse --verify --quiet "${ref}^{tree}" 2>/dev/null)
  [ -n "$tree" ] || return 1

  local synth
  synth=$(GIT_AUTHOR_NAME=git-safety GIT_AUTHOR_EMAIL=git-safety@invalid \
          GIT_COMMITTER_NAME=git-safety GIT_COMMITTER_EMAIL=git-safety@invalid \
          git commit-tree --no-gpg-sign "$tree" -p "$mb" -m git-safety-synthetic 2>/dev/null)
  [ -n "$synth" ] || return 1

  cherry_out=$(git cherry "$base" "$synth" 2>/dev/null)
  cherry_rc=$?
  if [ "$cherry_rc" -eq 0 ]; then
    cherry_plus=$(printf '%s\n' "$cherry_out" | { grep -c '^+' || true; })
    if [ "${cherry_plus:-0}" -eq 0 ]; then
      return 0
    fi
  fi

  return 1
}

# --- is-pushed -----------------------------------------------------------

cmd_is_pushed() {
  [ "$#" -eq 1 ] || usage_error "is-pushed: need <ref>"
  local ref="$1"

  local origin_head
  origin_head=$(git symbolic-ref -q refs/remotes/origin/HEAD 2>/dev/null)
  if [ -n "$origin_head" ]; then
    if git merge-base --is-ancestor "$ref" "$origin_head" 2>/dev/null; then
      return 0
    fi
  fi

  local upstream
  upstream=$(git rev-parse --verify --quiet "${ref}@{upstream}" 2>/dev/null)
  if [ -n "$upstream" ]; then
    if git merge-base --is-ancestor "$ref" "$upstream" 2>/dev/null; then
      return 0
    fi
  fi

  return 1
}

# --- safe-delete-branch ----------------------------------------------------

cmd_safe_delete_branch() {
  [ "$#" -eq 2 ] || usage_error "safe-delete-branch: need <branch> <base>"
  local branch="$1" base="$2"

  git check-ref-format --branch "$branch" >/dev/null 2>&1 || return 1
  git show-ref --verify --quiet -- "refs/heads/$branch" || return 1

  if cmd_is_merged "refs/heads/$branch" "$base"; then
    git branch -D -- "$branch" >/dev/null 2>&1 || return 1
    return 0
  fi
  return 1
}

# --- safe-reset ------------------------------------------------------------

_safe_reset_remove_squash_msg() {
  local squash_msg
  squash_msg=$(git rev-parse --git-path SQUASH_MSG 2>/dev/null)
  [ -n "$squash_msg" ] && rm -f -- "$squash_msg"
  return 0
}

_safe_reset_stage() {
  local base="$1" tree="$2"
  local head base_full tree_full

  local toplevel
  toplevel=$(git rev-parse --show-toplevel 2>/dev/null)
  [ -n "$toplevel" ] || { printf 'git-safety: safe-reset --stage: cannot resolve top-level (not a work tree)\n' >&2; return 2; }
  cd -- "$toplevel" 2>/dev/null || { printf 'git-safety: safe-reset --stage: cannot cd to top-level: %s\n' "$toplevel" >&2; return 2; }

  head=$(git rev-parse --verify --quiet HEAD 2>/dev/null)
  [ -n "$head" ] || { printf 'git-safety: safe-reset --stage: cannot resolve HEAD\n' >&2; return 2; }

  base_full=$(git rev-parse --verify --quiet "${base}^{commit}" 2>/dev/null)
  if [ -z "$base_full" ]; then
    printf 'git-safety: safe-reset --stage: cannot resolve base_sha: %s\n' "$base" >&2
    return 1
  fi

  tree_full=$(git rev-parse --verify --quiet "${tree}^{tree}" 2>/dev/null)
  if [ -z "$tree_full" ]; then
    printf 'git-safety: safe-reset --stage: cannot resolve staged_tree: %s\n' "$tree" >&2
    return 1
  fi

  if [ "$head" != "$base_full" ]; then
    printf 'git-safety: safe-reset --stage: refused — HEAD (%s) != base_sha (%s)\n' "$head" "$base_full" >&2
    return 1
  fi

  local tmp_list
  tmp_list=$(mktemp "${TMPDIR:-/tmp}/git-safety.XXXXXX") || return 2
  if ! git diff-tree -r -z --name-only "$base_full" "$tree_full" > "$tmp_list" 2>/dev/null; then
    rm -f -- "$tmp_list"
    printf 'git-safety: safe-reset --stage: git diff-tree failed\n' >&2
    return 2
  fi

  local paths=() p
  while IFS= read -r -d '' p || [ -n "$p" ]; do
    [ -n "$p" ] && paths+=("$p")
  done < "$tmp_list"
  rm -f -- "$tmp_list"

  if [ "${#paths[@]}" -eq 0 ]; then
    _safe_reset_remove_squash_msg
    return 0
  fi

  GIT_LITERAL_PATHSPECS=1 git update-index -q --refresh >/dev/null 2>&1

  if ! GIT_LITERAL_PATHSPECS=1 git diff-index --quiet --cached "$tree_full" -- "${paths[@]}" 2>/dev/null; then
    printf 'git-safety: safe-reset --stage: refused — staged content differs from recorded tree\n' >&2
    return 1
  fi
  if ! GIT_LITERAL_PATHSPECS=1 git diff-index --quiet "$tree_full" -- "${paths[@]}" 2>/dev/null; then
    printf 'git-safety: safe-reset --stage: refused — working tree differs from recorded tree\n' >&2
    return 1
  fi

  for p in "${paths[@]}"; do
    if ! git cat-file -e "${tree_full}:${p}" 2>/dev/null; then
      if [ -e "$p" ] || [ -L "$p" ]; then
        printf 'git-safety: safe-reset --stage: refused — %s exists in working tree but not in recorded tree\n' "$p" >&2
        return 1
      fi
    fi
  done

  for p in "${paths[@]}"; do
    if git cat-file -e "${base_full}:${p}" 2>/dev/null; then
      GIT_LITERAL_PATHSPECS=1 git checkout -q "$base_full" -- "$p" || return 2
    else
      GIT_LITERAL_PATHSPECS=1 git rm -q -f -- "$p" >/dev/null 2>&1 || return 2
    fi
  done

  _safe_reset_remove_squash_msg
  return 0
}

_safe_reset_clean_at() {
  local sha="$1"
  local head want

  head=$(git rev-parse --verify --quiet HEAD 2>/dev/null)
  [ -n "$head" ] || { printf 'git-safety: safe-reset --clean-at: cannot resolve HEAD\n' >&2; return 2; }

  want=$(git rev-parse --verify --quiet "${sha}^{commit}" 2>/dev/null)
  if [ -z "$want" ]; then
    printf 'git-safety: safe-reset --clean-at: cannot resolve sha: %s\n' "$sha" >&2
    return 1
  fi

  if [ "$head" != "$want" ]; then
    printf 'git-safety: safe-reset --clean-at: refused — HEAD (%s) != %s (%s)\n' "$head" "$sha" "$want" >&2
    return 1
  fi

  git reset -q --hard "$want" >/dev/null 2>&1 || return 2
  _safe_reset_remove_squash_msg
  return 0
}

cmd_safe_reset() {
  case "${1-}" in
    --stage)
      shift
      [ "$#" -eq 2 ] || usage_error "safe-reset --stage: need <base_sha> <staged_tree>"
      _safe_reset_stage "$1" "$2"
      ;;
    --clean-at)
      shift
      [ "$#" -eq 1 ] || usage_error "safe-reset --clean-at: need <sha>"
      _safe_reset_clean_at "$1"
      ;;
    *) usage_error "safe-reset: need --stage <base_sha> <staged_tree> or --clean-at <sha>" ;;
  esac
}

# --- resolve-base ----------------------------------------------------------

# Prints the first base ref that resolves, in order: the target of
# refs/remotes/origin/HEAD, origin/master, origin/main, master, main. Never
# fetches. Exit 0 with the ref on stdout, or exit 1 with empty stdout.
cmd_resolve_base() {
  [ "$#" -eq 0 ] || usage_error "resolve-base: no arguments expected"
  local ref

  ref=$(git symbolic-ref -q refs/remotes/origin/HEAD 2>/dev/null) || ref=""
  if [ -n "$ref" ] && git rev-parse --verify --quiet "${ref}^{commit}" >/dev/null 2>&1; then
    printf '%s\n' "$ref"
    return 0
  fi

  for ref in origin/master origin/main master main; do
    if git rev-parse --verify --quiet "$ref" >/dev/null 2>&1; then
      printf '%s\n' "$ref"
      return 0
    fi
  done

  return 1
}

# --- dispatch --------------------------------------------------------------

main() {
  if [ "${1-}" = "-C" ]; then
    [ "$#" -ge 2 ] && [ -n "$2" ] || usage_error "-C requires a directory"
    local dir="$2"
    shift 2
    cd -- "$dir" 2>/dev/null || { printf 'git-safety: -C: cannot cd to %s\n' "$dir" >&2; exit 2; }
    unset GIT_DIR GIT_INDEX_FILE GIT_WORK_TREE
  fi

  local sub="${1-}"
  [ -n "$sub" ] || usage_error "missing subcommand"
  shift

  case "$sub" in
    is-clean) cmd_is_clean "$@" ;;
    is-merged) cmd_is_merged "$@" ;;
    is-pushed) cmd_is_pushed "$@" ;;
    safe-delete-branch) cmd_safe_delete_branch "$@" ;;
    safe-reset) cmd_safe_reset "$@" ;;
    resolve-base) cmd_resolve_base "$@" ;;
    *) usage_error "unknown subcommand: $sub" ;;
  esac
  exit $?
}

main "$@"
