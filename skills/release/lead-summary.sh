#!/usr/bin/env bash
# SPEC-010 R4 / CDT-533: D2 CHANGELOG lead extraction + fold-subject --check.
# Pure subprocess — no LLM, no network, no index or ref mutation.
#
# Usage:
#   lead-summary.sh [--changelog PATH | --cached | --from-commit REV] VERSION
#   lead-summary.sh --check [--changelog PATH | --cached | --from-commit REV] \
#                   VERSION SUBJECT
#
# Exit: 0 ok · 1 missing/empty lead or --check mismatch · 64 usage
# THIS SCRIPT IS A SUBPROCESS CLI — NEVER SOURCE IT.
set -euo pipefail

usage() {
  cat >&2 <<'EOF'
Usage: lead-summary.sh [--changelog PATH | --cached | --from-commit REV] VERSION
       lead-summary.sh --check [source flags] VERSION SUBJECT

Print the D2-normalized lead of ### vVERSION / ### VERSION in CHANGELOG.md
(strip leading - / **, trailing " — …" detail). VERSION is X.Y.Z or vX.Y.Z.

--cached         read git show :CHANGELOG.md (index)
--from-commit R  read git show R:CHANGELOG.md
--changelog PATH override the path (default CHANGELOG.md)
--check          exit 0 iff SUBJECT matches ^(feat|fix): v?VERSION — <lead>

Exit 0 ok; 1 missing/empty section or --check mismatch; 64 usage.
Does not mutate the index or refs.
EOF
}

CHANGELOG="CHANGELOG.md"
SOURCE="file"
FROM_COMMIT=""
CHECK=0
has_cached=0
has_from=0

need_arg() {
  if [ $# -lt 2 ] || [ -z "${2:-}" ]; then
    echo "lead-summary.sh: $1 requires a value" >&2
    usage
    exit 64
  fi
}

while [ $# -gt 0 ]; do
  case "$1" in
    --changelog)
      need_arg "$@"
      CHANGELOG="$2"
      shift 2
      ;;
    --cached)
      SOURCE="cached"
      has_cached=1
      shift
      ;;
    --from-commit)
      need_arg "$@"
      SOURCE="commit"
      has_from=1
      FROM_COMMIT="$2"
      shift 2
      ;;
    --check)
      CHECK=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    --*)
      echo "lead-summary.sh: unknown flag: $1" >&2
      usage
      exit 64
      ;;
    *)
      break
      ;;
  esac
done

if [ "$has_cached" -eq 1 ] && [ "$has_from" -eq 1 ]; then
  echo "lead-summary.sh: --cached and --from-commit are mutually exclusive" >&2
  usage
  exit 64
fi

if [ "$CHECK" -eq 1 ]; then
  if [ $# -ne 2 ]; then
    echo "lead-summary.sh: --check requires VERSION SUBJECT" >&2
    usage
    exit 64
  fi
  VERSION="$1"
  SUBJECT="$2"
else
  if [ $# -ne 1 ]; then
    echo "lead-summary.sh: VERSION is required" >&2
    usage
    exit 64
  fi
  VERSION="$1"
  SUBJECT=""
fi

if ! [[ "$VERSION" =~ ^v?[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "lead-summary.sh: VERSION must be X.Y.Z or vX.Y.Z (got: $VERSION)" >&2
  exit 64
fi
VER_PLAIN="${VERSION#v}"

if [ "$SOURCE" = "cached" ] || [ "$SOURCE" = "commit" ]; then
  if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    echo "lead-summary.sh: not a git repository" >&2
    exit 64
  fi
fi

if [ "$SOURCE" = "commit" ]; then
  if ! git rev-parse --verify "${FROM_COMMIT}^{commit}" >/dev/null 2>&1; then
    echo "lead-summary.sh: unresolvable --from-commit: $FROM_COMMIT" >&2
    exit 64
  fi
fi

# Normalize CHANGELOG lead bullet text (SPEC-010 D2):
# strip leading "- ", surrounding **, trailing " — …" detail
normalize_lead() {
  local line="$1"
  line="${line#"${line%%[![:space:]]*}"}"
  if [[ "$line" == -* ]]; then
    line="${line#-}"
    line="${line# }"
  fi
  line="${line//\*\*/}"
  if [[ "$line" == *" — "* ]]; then
    line="${line%% — *}"
  elif [[ "$line" == *" -- "* ]]; then
    line="${line%% -- *}"
  fi
  line="${line%"${line##*[![:space:]]}"}"
  printf '%s\n' "$line" || return 1
}

# Extract lead bullet from CHANGELOG body for version X.Y.Z
changelog_lead_for() {
  local body="$1" ver="$2"
  local section_found=0 line lead=""
  while IFS= read -r line || [ -n "$line" ]; do
    if [[ "$line" =~ ^###[[:space:]]+v?([0-9]+\.[0-9]+\.[0-9]+)[[:space:]]*$ ]]; then
      if [ "$section_found" -eq 1 ]; then
        break
      fi
      if [ "${BASH_REMATCH[1]}" = "$ver" ]; then
        section_found=1
      fi
      continue
    fi
    if [ "$section_found" -eq 1 ]; then
      if [[ "$line" =~ ^[[:space:]]*-[[:space:]] ]]; then
        lead=$(normalize_lead "$line") || return 1
        break
      fi
      if [[ "$line" =~ ^[[:space:]]*$ ]]; then
        continue
      fi
      break
    fi
  done <<<"$body"
  if [ "$section_found" -eq 0 ] || [ -z "$lead" ]; then
    return 1
  fi
  printf '%s\n' "$lead" || return 1
}

read_body() {
  case "$SOURCE" in
    file)
      [ -r "$CHANGELOG" ] || return 1
      cat "$CHANGELOG" || return 1
      ;;
    cached)
      git show ":${CHANGELOG}" 2>/dev/null || return 1
      ;;
    commit)
      git show "${FROM_COMMIT}:${CHANGELOG}" 2>/dev/null || return 1
      ;;
    *)
      return 1
      ;;
  esac
}

expected_prefix() {
  local s="$1"
  if [[ "$s" =~ ^(feat|fix): ]]; then
    printf '%s\n' "${BASH_REMATCH[1]}" || return 1
  else
    printf '%s\n' "fix" || return 1
  fi
}

d2_fail() {
  local prefix
  prefix=$(expected_prefix "$SUBJECT") || prefix=fix
  printf 'D2: %s: v%s — %s\n' "$prefix" "$VER_PLAIN" "$LEAD_TEXT"
  exit 1
}

BODY=""
LEAD_TEXT=""
if BODY=$(read_body); then
  LEAD_TEXT=$(changelog_lead_for "$BODY" "$VER_PLAIN") || LEAD_TEXT=""
else
  LEAD_TEXT=""
fi

if [ "$CHECK" -eq 0 ]; then
  if [ -z "$LEAD_TEXT" ]; then
    echo "lead-summary.sh: missing or empty CHANGELOG section for v${VER_PLAIN}" >&2
    exit 1
  fi
  printf '%s\n' "$LEAD_TEXT"
  exit 0
fi

# --check
if [ -z "$LEAD_TEXT" ]; then
  d2_fail
fi

if [[ "$SUBJECT" =~ ^(feat|fix):[[:space:]]+v?([0-9]+\.[0-9]+\.[0-9]+)[[:space:]]+—[[:space:]]+(.*)$ ]]; then
  subj_ver="${BASH_REMATCH[2]}"
  summary="${BASH_REMATCH[3]}"
  if [ "$subj_ver" = "$VER_PLAIN" ] && [ "$summary" = "$LEAD_TEXT" ]; then
    exit 0
  fi
fi
d2_fail
