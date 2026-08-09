#!/usr/bin/env bash
# SPEC-010 ship-history cleanliness gate (CDT-188 H1–H4 / D1–D4).
# Fail-closed one-commit-per-tag policy for ship window W.
# Pure subprocess — no LLM, no network, no ref mutation.
#
# Usage:
#   check-ship-history.sh --since <ship-start-sha> \
#     [--changelog PATH] [--expect-tag TAG=SHA ...]
#
# Exit codes:
#   0  — clean (none of D1–D4 in W)
#   1  — dirty (history dirty — rewrite needed)
#  64  — usage / not a git repo / unresolvable --since
#
# Release tags only: names matching v?X.Y.Z (optional leading v).
# Non-release tags are ignored.
set -euo pipefail

usage() {
  cat >&2 <<'EOF'
Usage: check-ship-history.sh --since <ship-start-sha> \
         [--changelog PATH] [--expect-tag TAG=SHA ...]

Ship window W = commits and release tags (v?X.Y.Z) whose targets are
strictly after --since and ancestor-of-or-equal HEAD.

Dirty classes D1–D4 (SPEC-010 H): multi-commit-per-tag, subject/CHANGELOG
mismatch, repair-class commits, tag retarget (--expect-tag / local reflog).

Exit 0 clean; exit 1 dirty; exit 64 usage. Does not mutate refs.
EOF
}

SINCE_ARG=""
CHANGELOG="CHANGELOG.md"
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

if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "check-ship-history.sh: not a git repository" >&2
  exit 64
fi

ROOT=$(git rev-parse --show-toplevel)

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

# --- enumerate release tags in W ---
# Target strictly after SINCE and ancestor-of-or-equal HEAD
tag_names=()
tag_commits=()

while IFS= read -r tname; do
  [ -z "$tname" ] && continue
  is_release_tag "$tname" || continue
  tcommit=$(git -C "$ROOT" rev-parse --verify "${tname}^{commit}" 2>/dev/null) || continue
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
done < <(git -C "$ROOT" for-each-ref --format='%(refname:short)' refs/tags)

# Sort tags by commit topology (ancestor order) for prev_release lookup
# Use committer date + name as stable order; prev found via ancestry not list order
n_tags=${#tag_names[@]}

# For a tag commit, find nearest older release-tag ancestor in W ∪ all release tags
# (prev may be outside W — any older v* tag ancestor, else SINCE)
prev_for_tag() {
  local this_commit="$1"
  local best="" best_commit=""
  local tname tcommit
  # Scan ALL release tags (not only W) for ancestors
  while IFS= read -r tname; do
    [ -z "$tname" ] && continue
    is_release_tag "$tname" || continue
    tcommit=$(git -C "$ROOT" rev-parse --verify "${tname}^{commit}" 2>/dev/null) || continue
    [ "$tcommit" = "$this_commit" ] && continue
    if git -C "$ROOT" merge-base --is-ancestor "$tcommit" "$this_commit" 2>/dev/null; then
      if [ -z "$best" ]; then
        best="$tname"
        best_commit="$tcommit"
      else
        # prefer the tip-most ancestor (best is ancestor of candidate → candidate closer)
        if git -C "$ROOT" merge-base --is-ancestor "$best_commit" "$tcommit" 2>/dev/null \
          && [ "$best_commit" != "$tcommit" ]; then
          best="$tname"
          best_commit="$tcommit"
        fi
      fi
    fi
  done < <(git -C "$ROOT" for-each-ref --format='%(refname:short)' refs/tags)
  if [ -n "$best_commit" ]; then
    printf '%s\n' "$best_commit"
  else
    printf '%s\n' "$SINCE"
  fi
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

# Count release-shaped subjects per version in W
# Use temp files for portability (no assoc arrays required in old bash — we have bash)
declare -A release_subj_count=()
declare -A release_subj_seen=()

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
    prev_count="${release_subj_count[$ver]:-0}"
    release_subj_count[$ver]=$((prev_count + 1))
    if [ "$already_tagged" -eq 1 ] && [ "${release_subj_count[$ver]}" -ge 2 ]; then
      add_finding "D3: second release-shaped subject for v${ver} in W: ${csha:0:7} ${subj}"
    fi
    # Also: even without tag, two release-shaped same version in W is hazard when one is tagged
    # Spec: "second feat:|fix: release-shaped subject for a version already tagged in W"
    # So only when tagged — handled above.
  fi
done < <(list_non_merges "$SINCE" "$HEAD")

# --- D4: --expect-tag mismatch + local tag reflog double-move ---
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

  # Local reflog double-move: ≥2 distinct peeled commit SHAs for this tag
  if git -C "$ROOT" rev-parse -q --verify "refs/tags/${tname}" >/dev/null 2>&1; then
    # git reflog show <tag> may fail if no reflog; skip quietly
    if reflog_out=$(git -C "$ROOT" reflog show "$tname" 2>/dev/null); then
      # First field is the object shown; peel to commit when possible
      uniq_targets=$(
        printf '%s\n' "$reflog_out" | awk '{print $1}' | while read -r obj; do
          git -C "$ROOT" rev-parse --verify "${obj}^{commit}" 2>/dev/null || true
        done | sort -u | grep -c . || true
      )
      # Also require those moves relate to ship — if >1 distinct SHA ever, local retarget happened
      if [ "${uniq_targets:-0}" -gt 1 ]; then
        add_finding "D4: $tname local reflog shows ${uniq_targets} distinct targets (retarget)"
      fi
    fi
  fi

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
    # Tag expected but not in W — still compare if tag exists locally
    if local_c=$(git -C "$ROOT" rev-parse --verify "${et}^{commit}" 2>/dev/null); then
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

# D4 remote half: no network (H1). Only local remote-tracking tag refs if present.
# Common layouts rarely cache remote tags; skip when absent (offline-safe).
if git -C "$ROOT" remote get-url origin >/dev/null 2>&1; then
  i=0
  while [ "$i" -lt "$n_tags" ]; do
    tname="${tag_names[$i]}"
    tcommit="${tag_commits[$i]}"
    remote_ref=""
    for cand in \
      "refs/remotes/origin/tags/${tname}" \
      "refs/remotes/origin/${tname}"; do
      if remote_c=$(git -C "$ROOT" rev-parse --verify "${cand}^{commit}" 2>/dev/null); then
        remote_ref="$cand"
        if [ "$remote_c" != "$tcommit" ]; then
          add_finding "D4: $tname local ${tcommit:0:7} != remote-tracking ${remote_c:0:7} ($cand)"
        fi
        break
      fi
    done
    i=$((i + 1))
  done
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
