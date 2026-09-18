#!/usr/bin/env bash
# SPEC-010 bump-class gate: a new commands/*.md or unflagged
# skills/<name>/SKILL.md requires minor or major.
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

A newly added commands/*.md file, or a newly added skills/<name>/SKILL.md
whose YAML frontmatter lacks user-invocable: false, requires plugin.json to
bump minor or major (not patch, not unchanged). Exception: commands/<name>.md
is not a new Surface when skills/<name>/SKILL.md already exists on the old
ref (thin host door over a pre-existing engine). Edits to existing commands
or skills are not a new Surface. Flagged skills (user-invocable: false)
stay patch-eligible. Missing or unreadable frontmatter counts as unflagged.

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

# YAML frontmatter only. Whitespace-tolerant user-invocable: false
# (optional quotes). Missing/unreadable/no-match → unflagged (exit 1).
fm_has_user_invocable_false() {
  local line first=1
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%$'\r'}"
    if [ "$first" -eq 1 ]; then
      first=0
      [ "$line" = "---" ] || return 1
      continue
    fi
    [ "$line" = "---" ] && return 1
    printf '%s\n' "$line" | grep -Eq '^[ 	]*user-invocable:[ 	]*(false|"false"|'\''false'\'')[ 	]*$' && return 0
  done
  return 1
}

read_path_text() {
  local p="$1"
  case "$MODE" in
    commit)
      git show "${COMMIT}:$p" 2>/dev/null || return 1
      ;;
    cached)
      git show ":$p" 2>/dev/null || return 1
      ;;
    *)
      cat "$p" 2>/dev/null || return 1
      ;;
  esac
}

# 0 = flagged (patch-eligible); 1 = unflagged surface
path_is_flagged_skill() {
  local p="$1" text
  text=$(read_path_text "$p") || return 1
  # Here-string, not a pipe. `printf | fn` SIGPIPEs (141) under pipefail when
  # fn returns at `user-invocable: false` before consuming a large SKILL.md
  # (protocol engines). Missing the flag would false-promote a flagged skill
  # to a new Surface.
  fm_has_user_invocable_false <<< "$text"
}

baseline_ref() {
  if [ "$MODE" = "commit" ]; then
    printf '%s\n' "${COMMIT}^"
  else
    printf '%s\n' "${AGAINST:-HEAD}"
  fi
}

# commands/<name>.md wrapping a skill already on the old ref is a host
# adapter (opencode et al. load commands/ only), not a new Surface.
command_wraps_existing_skill() {
  local cmd="$1" name skill
  name="${cmd#commands/}"
  name="${name%.md}"
  [ -n "$name" ] || return 1
  skill="skills/${name}/SKILL.md"
  git cat-file -e "$(baseline_ref):$skill" 2>/dev/null
}

maybe_add_surface() {
  local p="$1"
  case "$p" in
    commands/*.md)
      if command_wraps_existing_skill "$p"; then
        return 0
      fi
      added+=("$p")
      ;;
    skills/*/SKILL.md)
      if ! path_is_flagged_skill "$p"; then
        added+=("$p")
      fi
      ;;
  esac
}

collect_added() {
  local p
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    maybe_add_surface "$p"
  done
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
  collect_added < <(git diff-tree --no-commit-id --name-only --diff-filter=A -r "$COMMIT^" "$COMMIT" -- commands/ skills/)
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
    collect_added < <(git diff --cached --name-only --diff-filter=A "$AGAINST" -- commands/ skills/)
    if git diff --cached --name-only -- .claude-plugin/plugin.json | grep -qx '.claude-plugin/plugin.json'; then
      new_ver=$(git show ":.claude-plugin/plugin.json" | json_ver || true)
    elif [ -f .claude-plugin/plugin.json ]; then
      new_ver=$(json_ver < .claude-plugin/plugin.json || true)
    fi
  else
    collect_added < <(git diff --name-only --diff-filter=A "$AGAINST" -- commands/ skills/)
    # Untracked commands/*.md / skills/*/SKILL.md (/release runs this before git add)
    collect_added < <(git ls-files --others --exclude-standard -- commands/ skills/)
    if [ -f .claude-plugin/plugin.json ]; then
      new_ver=$(json_ver < .claude-plugin/plugin.json || true)
    fi
  fi
  old_ver=$(git show "${AGAINST}:.claude-plugin/plugin.json" 2>/dev/null | json_ver || true)
fi

if [ "${#added[@]}" -eq 0 ]; then
  echo "bump-class: no new Surfaces — ok"
  exit 0
fi

old_ver=${old_ver:-0.0.0}
new_ver=${new_ver:-}
if [ -z "$new_ver" ]; then
  echo "bump-class: new Surface(s) but plugin.json version unreadable" >&2
  printf '  %s\n' "${added[@]}" >&2
  echo "  new command/unflagged-skill surfaces require a minor or major bump (AGENTS.md)" >&2
  echo "  MUST NOT commit/tag/push" >&2
  exit 1
fi

klass=$(bump_class "$old_ver" "$new_ver")
case "$klass" in
  minor|major)
    echo "bump-class: ${#added[@]} new Surface(s), $old_ver -> $new_ver ($klass) — ok"
    exit 0
    ;;
esac

echo "bump-class: new Surface(s) require a minor or major bump, not ${klass}" >&2
printf '  %s\n' "${added[@]}" >&2
echo "  plugin.json: $old_ver -> $new_ver ($klass)" >&2
echo "  AGENTS.md: new command/unflagged-skill surfaces = minor" >&2
echo "  MUST NOT commit/tag/push" >&2
exit 1
