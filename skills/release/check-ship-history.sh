#!/usr/bin/env bash
# SPEC-010 ship-history cleanliness gate (CDT-188 H1–H4 / D1–D4).
# Fail-closed one-commit-per-tag policy for ship window W.
# Pure subprocess — no LLM, no network, no ref mutation.
#
# Usage:
#   check-ship-history.sh --since <ship-start-sha> \
#     [--changelog PATH] [--expect-tag TAG=SHA ...] [--tag-snapshot FILE]
#
# Exit codes:
#   0  — clean (none of D1–D4 in W)
#   1  — dirty (history dirty — rewrite needed)
#  64  — usage / not a git repo / unresolvable --since / unreadable --tag-snapshot
#
# Release tags only: names matching v?X.Y.Z (optional leading v).
# Non-release tags are ignored.
#
# Tags are read by full refname under refs/tags/ (SPEC-010 D4/R2). D4's
# remote half reads only refs/remotes/origin/tags/<name> (no network); its
# snapshot half compares against --tag-snapshot FILE (one
# <refname><TAB><peeled-commit-sha> line per tag, written by
# skills/release/ship-start.sh). The checker never reads tag ref history.
set -euo pipefail

usage() {
  cat >&2 <<'EOF'
Usage: check-ship-history.sh --since <ship-start-sha> \
         [--changelog PATH] [--expect-tag TAG=SHA ...] [--tag-snapshot FILE]

Ship window W = commits and release tags (v?X.Y.Z) whose targets are
strictly after --since and ancestor-of-or-equal HEAD.

Dirty classes D1–D4 (SPEC-010 H): multi-commit-per-tag, subject/CHANGELOG
mismatch, repair-class commits, tag retarget (--expect-tag / remote-tracking
tag / --tag-snapshot). Never inspects a tag's ref-log history.

Exit 0 clean; exit 1 dirty; exit 64 usage. Does not mutate refs.
EOF
}

SINCE_ARG=""
CHANGELOG="CHANGELOG.md"
TAG_SNAPSHOT=""
# parallel arrays: expect_tag_names[i] / expect_tag_shas[i]
expect_tag_names=()
expect_tag_shas=()

while [ $# -gt 0 ]; do
  case "$1" in
    --since)
      if [ $# -lt 2 ] || [ -z "${2:-}" ]; then
        echo "check-ship-history.sh: --since requires a SHA" >&2
        usage
        exit 64
      fi
      SINCE_ARG="$2"
      shift 2
      ;;
    --changelog)
      if [ $# -lt 2 ] || [ -z "${2:-}" ]; then
        echo "check-ship-history.sh: --changelog requires a PATH" >&2
        usage
        exit 64
      fi
      CHANGELOG="$2"
      shift 2
      ;;
    --expect-tag)
      if [ $# -lt 2 ] || [ -z "${2:-}" ]; then
        echo "check-ship-history.sh: --expect-tag requires TAG=SHA" >&2
        usage
        exit 64
      fi
      _et="$2"
      if [[ "$_et" != *=* ]]; then
        echo "check-ship-history.sh: --expect-tag must be TAG=SHA (got: $_et)" >&2
        usage
        exit 64
      fi
      _et_name="${_et%%=*}"
      _et_sha="${_et#*=}"
      if [ -z "$_et_name" ] || [ -z "$_et_sha" ]; then
        echo "check-ship-history.sh: --expect-tag must be TAG=SHA (got: $_et)" >&2
        usage
        exit 64
      fi
      expect_tag_names+=("$_et_name")
      expect_tag_shas+=("$_et_sha")
      shift 2
      ;;
    --tag-snapshot)
      if [ $# -lt 2 ] || [ -z "${2:-}" ]; then
        echo "check-ship-history.sh: --tag-snapshot requires FILE" >&2
        usage
        exit 64
      fi
      TAG_SNAPSHOT="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 64
      ;;
    --*)
      echo "check-ship-history.sh: unknown flag: $1" >&2
      usage
      exit 64
      ;;
    *)
      echo "check-ship-history.sh: unexpected argument: $1" >&2
      usage
      exit 64
      ;;
  esac
done

if [ -z "$SINCE_ARG" ]; then
  echo "check-ship-history.sh: --since is required" >&2
  usage
  exit 64
fi

if [ -n "$TAG_SNAPSHOT" ] && [ ! -r "$TAG_SNAPSHOT" ]; then
  echo "check-ship-history.sh: unreadable --tag-snapshot: $TAG_SNAPSHOT" >&2
  exit 64
fi

if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "check-ship-history.sh: not a git repository" >&2
  exit 64
fi

ROOT=$(git rev-parse --show-toplevel)
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SHIP_START_SH="$HERE/ship-start.sh"

# Resolve --since (full or abbrev SHA / ref)
if ! SINCE=$(git -C "$ROOT" rev-parse --verify "${SINCE_ARG}^{commit}" 2>/dev/null); then
  echo "check-ship-history.sh: unresolvable --since: $SINCE_ARG" >&2
  exit 64
fi

if ! HEAD=$(git -C "$ROOT" rev-parse --verify HEAD 2>/dev/null); then
  echo "check-ship-history.sh: cannot resolve HEAD" >&2
  exit 64
fi

# --- helpers ---

# True if name is a release tag: optional v + X.Y.Z (numeric components)
is_release_tag() {
  [[ "$1" =~ ^v?[0-9]+\.[0-9]+\.[0-9]+$ ]]
}

# Strip optional leading v → X.Y.Z
tag_version() {
  local t="$1"
  t="${t#v}"
  printf '%s\n' "$t"
}

# Non-merge commits in (base, tip] — git rev-list base..tip
count_non_merges() {
  local base="$1" tip="$2"
  git -C "$ROOT" rev-list --count --no-merges "${base}..${tip}"
}

list_non_merges() {
  local base="$1" tip="$2"
  git -C "$ROOT" rev-list --no-merges "${base}..${tip}"
}

# Normalize CHANGELOG lead bullet text (SPEC-010 D2):
# strip leading "- ", surrounding **, trailing " — …" detail
normalize_lead() {
  local line="$1"
  # trim leading whitespace
  line="${line#"${line%%[![:space:]]*}"}"
  # strip leading "- " or "-"
  if [[ "$line" == -* ]]; then
    line="${line#-}"
    line="${line# }"
  fi
  # strip surrounding **bold** (leading/trailing ** pairs, and inner **)
  line="${line//\*\*/}"
  # strip trailing em-dash detail (space + em dash + rest) or " -- " fallback
  if [[ "$line" == *" — "* ]]; then
    line="${line%% — *}"
  elif [[ "$line" == *" -- "* ]]; then
    line="${line%% -- *}"
  fi
  # trim trailing whitespace
  line="${line%"${line##*[![:space:]]}"}"
  printf '%s\n' "$line"
}

# Extract lead bullet from CHANGELOG body for version X.Y.Z
# Prints lead text or empty if missing/empty section
changelog_lead_for() {
  local body="$1" ver="$2"
  local heading_re section_found=0 line lead=""
  # Match ### vX.Y.Z or ### X.Y.Z
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
      # first non-empty content line that looks like a bullet
      if [[ "$line" =~ ^[[:space:]]*-[[:space:]] ]]; then
        lead=$(normalize_lead "$line")
        break
      fi
      # blank lines OK before bullet; other headings already handled
      if [[ "$line" =~ ^[[:space:]]*$ ]]; then
        continue
      fi
      # non-bullet content after heading without bullet → empty lead
      break
    fi
  done <<<"$body"
  if [ "$section_found" -eq 0 ]; then
    printf '\n'
    return 1
  fi
  printf '%s\n' "$lead"
  [ -n "$lead" ]
}

# Repair-class subject patterns (D3).
# Bash ERE has no \b — use ([^[:alnum:]]|$) for word boundary.
is_repair_subject() {
  local s="$1"
  [[ "$s" =~ ^fixup! ]] && return 0
  [[ "$s" =~ ^squash! ]] && return 0
  [[ "$s" =~ ^WIP([^[:alnum:]]|$) ]] && return 0
  [[ "$s" =~ ^wip([^[:alnum:]]|$) ]] && return 0
  [[ "$s" =~ ^temp([^[:alnum:]]|$) ]] && return 0
  [[ "$s" =~ ^TMP([^[:alnum:]]|$) ]] && return 0
  [[ "$s" =~ ^chore:[[:space:]]*repair([^[:alnum:]]|$) ]] && return 0
  [[ "$s" =~ ^chore:[[:space:]]*retag([^[:alnum:]]|$) ]] && return 0
  return 1
}

# Release-shaped subject → prints version X.Y.Z or returns 1
# Matches: ^(feat|fix): v?X.Y.Z — <summary>
parse_release_subject() {
  local s="$1"
  if [[ "$s" =~ ^(feat|fix):[[:space:]]+v?([0-9]+\.[0-9]+\.[0-9]+)[[:space:]]+—[[:space:]]+(.*)$ ]]; then
    printf '%s\n' "${BASH_REMATCH[2]}"
    return 0
  fi
  return 1
}

# Extract summary after em-dash from release subject
release_subject_summary() {
  local s="$1"
  if [[ "$s" =~ ^(feat|fix):[[:space:]]+v?[0-9]+\.[0-9]+\.[0-9]+[[:space:]]+—[[:space:]]+(.*)$ ]]; then
    printf '%s\n' "${BASH_REMATCH[2]}"
    return 0
  fi
  return 1
}

findings=()
add_finding() {
  findings+=("$1")
}

# --- enumerate tags: read the shared table (SPEC-010 R2). One
# refname<TAB>peeled-commit-sha line per tag that points at a commit,
# directly (lightweight) or via one annotated tag object (peeled); the
# peeling rule itself lives in ship-start.sh --list (single source, shared
# with the Step 0.5 snapshot writer — no second copy of the for-each-ref
# format/peel logic here). all_names/all_commits hold every such tag
# (release or not), current state — used both to build the in-W
# release-tag list below and as the "still exists locally" side of the D4
# snapshot-half compare.
all_names=()
all_commits=()
# bash 3.2 has no associative arrays (CDT-285): the current commit of a tag is
# looked up by a linear scan of all_names/all_commits, which already hold the
# same name→commit pairs the map did.
_tag_commit() { # _tag_commit <name> → peeled commit, or "" when absent
  local i=0
  while [ "$i" -lt "${#all_names[@]}" ]; do
    [ "${all_names[$i]}" = "$1" ] && { printf '%s' "${all_commits[$i]}"; return 0; }
    i=$((i + 1))
  done
  return 0
}
TAG_TABLE=$(cd "$ROOT" && bash "$SHIP_START_SH" --list) || {
  echo "check-ship-history.sh: tag list failed" >&2
  exit 64
}
while IFS=$'\t' read -r rname commit; do
  [ -z "$rname" ] && continue
  case "$rname" in
    refs/tags/*) name="${rname#refs/tags/}" ;;
    *) continue ;;
  esac
  all_names+=("$name")
  all_commits+=("$commit")
done <<<"$TAG_TABLE"

# --- enumerate release tags in W ---
# Target strictly after SINCE and ancestor-of-or-equal HEAD
tag_names=()
tag_commits=()

n_all=${#all_names[@]}
i=0
while [ "$i" -lt "$n_all" ]; do
  tname="${all_names[$i]}"
  tcommit="${all_commits[$i]}"
  i=$((i + 1))
  is_release_tag "$tname" || continue
  # must be ancestor of HEAD (or equal)
  if ! git -C "$ROOT" merge-base --is-ancestor "$tcommit" "$HEAD" 2>/dev/null; then
    continue
  fi
  # strictly after SINCE
  if [ "$tcommit" = "$SINCE" ]; then
    continue
  fi
  if ! git -C "$ROOT" merge-base --is-ancestor "$SINCE" "$tcommit" 2>/dev/null; then
    continue
  fi
  tag_names+=("$tname")
  tag_commits+=("$tcommit")
done

n_tags=${#tag_names[@]}

# For a tag commit, find the nearest older release-tag ancestor via linear
# `git describe` lookup (plan DD6) — no all-tags rescan. A --match hit
# that is not itself a release tag (e.g. a pre-release) is excluded and
# describe runs again. No hit, or the commit has no parent → SINCE.
prev_for_tag() {
  local this_commit="$1"
  local exclude_args=() desc commit
  while :; do
    # Guarded expansion: bash 3.2 treats "${arr[@]}" on an empty array as an
    # unbound variable under set -u, which would kill the describe and make
    # every tag's prev fall back to $SINCE.
    if ! desc=$(git -C "$ROOT" describe --tags --abbrev=0 \
      --match 'v[0-9]*' --match '[0-9]*' \
      ${exclude_args[@]+"${exclude_args[@]}"} "${this_commit}^" 2>/dev/null); then
      printf '%s\n' "$SINCE"
      return
    fi
    if is_release_tag "$desc"; then
      if commit=$(git -C "$ROOT" rev-parse --verify "refs/tags/${desc}^{commit}" 2>/dev/null); then
        printf '%s\n' "$commit"
      else
        printf '%s\n' "$SINCE"
      fi
      return
    fi
    exclude_args+=(--exclude "$desc")
  done
}

# --- D1 + D2 per tag in W ---
i=0
while [ "$i" -lt "$n_tags" ]; do
  tname="${tag_names[$i]}"
  tcommit="${tag_commits[$i]}"
  ver=$(tag_version "$tname")
  prev=$(prev_for_tag "$tcommit")

  cnt=$(count_non_merges "$prev" "$tcommit")
  if [ "$cnt" -ne 1 ]; then
    add_finding "D1: $tname has $cnt non-merge commit(s) in (${prev:0:7}..${tcommit:0:7}]; want 1"
  fi

  # Fold commit for D2: sole commit if cnt==1, else tag tip
  if [ "$cnt" -eq 1 ]; then
    fold=$(list_non_merges "$prev" "$tcommit" | head -n1)
  else
    fold="$tcommit"
  fi
  subject=$(git -C "$ROOT" log -1 --format=%s "$fold")

  if ! summary=$(release_subject_summary "$subject"); then
    add_finding "D2: $tname fold subject not release-shaped: ${subject}"
  else
    # Version in subject must match tag version (optional v)
    subj_ver=$(parse_release_subject "$subject" || true)
    if [ "$subj_ver" != "$ver" ]; then
      add_finding "D2: $tname subject version $subj_ver != tag $ver: ${subject}"
    fi
    # CHANGELOG at fold tree
    cl_body=""
    if cl_body=$(git -C "$ROOT" show "${fold}:${CHANGELOG}" 2>/dev/null); then
      lead=""
      if lead=$(changelog_lead_for "$cl_body" "$ver"); then
        if [ "$summary" != "$lead" ]; then
          add_finding "D2: $tname subject summary != CHANGELOG lead: got '${summary}' want '${lead}'"
        fi
      else
        add_finding "D2: $tname missing or empty CHANGELOG section for v${ver}"
      fi
    else
      add_finding "D2: $tname no ${CHANGELOG} at fold ${fold:0:7}"
    fi
  fi

  i=$((i + 1))
done

# --- D3: repair-class + double release-shaped for versions tagged in W ---
# Commits in W: (SINCE, HEAD]
tagged_versions=()
i=0
while [ "$i" -lt "$n_tags" ]; do
  tagged_versions+=("$(tag_version "${tag_names[$i]}")")
  i=$((i + 1))
done

# Count release-shaped subjects per version in W. bash 3.2 has no associative
# arrays (CDT-285): version→count is a parallel-array pair with a linear
# lookup (versions are a handful of x.y.z strings).
RS_VER_KEYS=()
RS_VER_COUNTS=()
_rs_count_bump() { # _rs_count_bump <version>
  local i=0
  while [ "$i" -lt "${#RS_VER_KEYS[@]}" ]; do
    [ "${RS_VER_KEYS[$i]}" = "$1" ] && { RS_VER_COUNTS[$i]=$(( ${RS_VER_COUNTS[$i]} + 1 )); return 0; }
    i=$((i + 1))
  done
  RS_VER_KEYS+=("$1")
  RS_VER_COUNTS+=(1)
  return 0
}
_rs_count_get() { # _rs_count_get <version> → count, 0 when absent
  local i=0
  while [ "$i" -lt "${#RS_VER_KEYS[@]}" ]; do
    [ "${RS_VER_KEYS[$i]}" = "$1" ] && { printf '%s' "${RS_VER_COUNTS[$i]}"; return 0; }
    i=$((i + 1))
  done
  printf '0'
}

while IFS= read -r csha; do
  [ -z "$csha" ] && continue
  subj=$(git -C "$ROOT" log -1 --format=%s "$csha")
  if is_repair_subject "$subj"; then
    add_finding "D3: repair-class commit ${csha:0:7}: ${subj}"
  fi
  if ver=$(parse_release_subject "$subj"); then
    # second release-shaped for a version already tagged in W
    already_tagged=0
    for tv in "${tagged_versions[@]+"${tagged_versions[@]}"}"; do
      if [ "$tv" = "$ver" ]; then
        already_tagged=1
        break
      fi
    done
    _rs_count_bump "$ver"
    if [ "$already_tagged" -eq 1 ] && [ "$(_rs_count_get "$ver")" -ge 2 ]; then
      add_finding "D3: second release-shaped subject for v${ver} in W: ${csha:0:7} ${subj}"
    fi
  fi
done < <(list_non_merges "$SINCE" "$HEAD")

# --- D4: --expect-tag mismatch (local + remote-tracking half) ---
i=0
while [ "$i" -lt "$n_tags" ]; do
  tname="${tag_names[$i]}"
  tcommit="${tag_commits[$i]}"

  # --expect-tag
  j=0
  while [ "$j" -lt "${#expect_tag_names[@]}" ]; do
    if [ "${expect_tag_names[$j]}" = "$tname" ]; then
      want_raw="${expect_tag_shas[$j]}"
      if ! want=$(git -C "$ROOT" rev-parse --verify "${want_raw}^{commit}" 2>/dev/null); then
        add_finding "D4: $tname --expect-tag SHA unresolvable: $want_raw"
      elif [ "$tcommit" != "$want" ]; then
        add_finding "D4: $tname local ${tcommit:0:7} != --expect-tag ${want:0:7}"
      fi
    fi
    j=$((j + 1))
  done

  i=$((i + 1))
done

# Also check --expect-tag for tags that were expected but missing / wrong even if not in W
# Spec: "fail if git rev-parse <tag> ≠ recorded expected SHA"
j=0
while [ "$j" -lt "${#expect_tag_names[@]}" ]; do
  et="${expect_tag_names[$j]}"
  # skip if already covered as tag-in-W above
  in_w=0
  i=0
  while [ "$i" -lt "$n_tags" ]; do
    if [ "${tag_names[$i]}" = "$et" ]; then
      in_w=1
      break
    fi
    i=$((i + 1))
  done
  if [ "$in_w" -eq 0 ]; then
    # Tag expected but not in W — still compare if tag exists locally.
    # Resolve strictly under refs/tags/: a bare "${et}^{commit}" falls
    # through git's ref disambiguation to refs/heads/<et> when no tag by
    # that name exists, wrongly comparing a same-named branch's tip.
    if local_c=$(git -C "$ROOT" rev-parse --verify "refs/tags/${et}^{commit}" 2>/dev/null); then
      want_raw="${expect_tag_shas[$j]}"
      if want=$(git -C "$ROOT" rev-parse --verify "${want_raw}^{commit}" 2>/dev/null); then
        if [ "$local_c" != "$want" ]; then
          add_finding "D4: $et local ${local_c:0:7} != --expect-tag ${want:0:7}"
        fi
      fi
    fi
  fi
  j=$((j + 1))
done

# D4 remote half: no network (H1). Only the remote-tracking TAG namespace
# refs/remotes/origin/tags/<name> (SPEC-010 D4(a)) — refs/remotes/origin/<name>
# is a branch namespace and is dropped. Skip when that ref is absent.
if git -C "$ROOT" remote get-url origin >/dev/null 2>&1; then
  i=0
  while [ "$i" -lt "$n_tags" ]; do
    tname="${tag_names[$i]}"
    tcommit="${tag_commits[$i]}"
    if remote_c=$(git -C "$ROOT" rev-parse --verify "refs/remotes/origin/tags/${tname}^{commit}" 2>/dev/null); then
      if [ "$remote_c" != "$tcommit" ]; then
        add_finding "D4: $tname local ${tcommit:0:7} != remote-tracking ${remote_c:0:7} (refs/remotes/origin/tags/${tname})"
      fi
    fi
    i=$((i + 1))
  done
fi

# D4 snapshot half (H2): a release tag listed in --tag-snapshot FILE that
# still exists locally but now peels to a different commit. A deleted tag
# (absent from all_names/_tag_commit) is not a finding. Not limited to W:
# D4(b) covers any release tag in the snapshot, so a retarget away from W is
# still caught.
if [ -n "$TAG_SNAPSHOT" ]; then
  while IFS=$'\t' read -r srefname scommit || [ -n "$srefname" ]; do
    [ -z "$srefname" ] && continue
    case "$srefname" in
      refs/tags/*) sname="${srefname#refs/tags/}" ;;
      *) continue ;;
    esac
    is_release_tag "$sname" || continue
    cur=$(_tag_commit "$sname")
    [ -z "$cur" ] && continue
    if [ "$cur" != "$scommit" ]; then
      add_finding "D4: $sname retargeted since ship start: ${scommit:0:7} -> ${cur:0:7} (tag snapshot)"
    fi
  done < "$TAG_SNAPSHOT"
fi

# --- output ---
if [ ${#findings[@]} -eq 0 ]; then
  echo "ship-history: ${n_tags} release tag(s) in W — clean"
  exit 0
fi

{
  echo "history dirty — rewrite needed"
  for f in "${findings[@]}"; do
    echo "$f"
  done
} >&2

exit 1
