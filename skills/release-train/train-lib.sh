#!/usr/bin/env bash
# train-lib.sh — mechanical release-train CLI (SPEC-023).
#
# Subprocess-only — NEVER source this file.
# Owns: queue.json, lock, slot math, renumber, M5a–d resolvers, restore helpers.
# MUST NOT implement release internals (tagging, pushing, committing, changelog
# generation, or drift gates) — those stay in skills/release/SKILL.md.
#
# Exit codes: 0 ok, 1 operational fail, 2 blocked/conflict, 64 usage.
# Stdout: data only. Diagnostics: stderr.

set -euo pipefail

usage() {
  cat >&2 <<'EOF'
Usage: bash skills/release-train/train-lib.sh <cmd> …

Commands:
  init
  register <branch> [--bump minor|patch] [--assumed <ver>|null]
  list
  drop <branch>
  freeze [--order b1,b2,…] [--print-only]
  show-plan
  set-status <branch> <pending|landing|landed|blocked>
             [--base-sha S] [--tag T] [--paths p1,p2]
  detect-assumed <branch>
  renumber <assumed> <assigned>
  resolve-tdd-index [--ours F --theirs F --out F] [path]
  resolve-vh [--ours F --theirs F --out F] [path]
  resolve-changelog <assigned> [--branch-file F --master-file F --out F]
  resolve-json <assigned> [--plugin P] [--market M]
  restore <base_sha>
  verify-tag <tag>
  acquire-lock
  release-lock
  preflight
EOF
  exit 64
}

die() { # die <rc> <msg>
  local rc="$1"; shift
  printf 'error: %s\n' "$*" >&2
  exit "$rc"
}

# ---- deps -------------------------------------------------------------------
if ! command -v jq >/dev/null 2>&1; then
  die 1 "jq is required but not found in PATH"
fi

# ---- paths ------------------------------------------------------------------
resolve_mroot() {
  # Allow test override first
  if [ -n "${RELEASE_TRAIN_ROOT:-}" ]; then
    MROOT="$RELEASE_TRAIN_ROOT"
    return 0
  fi
  local _gc
  if _gc=$(git rev-parse --git-common-dir 2>/dev/null); then
    # common-dir is .git (or absolute …/.git); parent is shared project root
    MROOT=$(cd "$(dirname "$_gc")" && pwd)
  else
    MROOT=$(pwd)
  fi
}

queue_paths() {
  resolve_mroot
  RT_DIR="$MROOT/.claude/release-train"
  QUEUE="$RT_DIR/queue.json"
  LOCK="$RT_DIR/train.lock"
}

empty_queue_json() {
  printf '%s\n' '{"version":1,"frozen":false,"master_version_at_freeze":null,"order":[],"entries":[]}'
}

read_queue() {
  queue_paths
  if [ ! -f "$QUEUE" ]; then
    empty_queue_json
  else
    cat "$QUEUE"
  fi
}

write_queue() {
  # write_queue <json-string>
  queue_paths
  mkdir -p "$RT_DIR"
  local tmp
  tmp=$(mktemp "${TMPDIR:-/tmp}/rt-queue.XXXXXX")
  printf '%s\n' "$1" > "$tmp"
  # validate JSON before install
  if ! jq -e . "$tmp" >/dev/null 2>&1; then
    rm -f "$tmp"
    die 1 "refusing to write invalid queue JSON"
  fi
  mv "$tmp" "$QUEUE"
}

normalize_ver() {
  # strip optional leading v
  local v="$1"
  v="${v#v}"
  printf '%s' "$v"
}

bump_version() {
  # bump_version <x.y.z> <minor|patch>
  local ver bump
  ver=$(normalize_ver "$1")
  bump="$2"
  local x y z
  IFS=. read -r x y z <<EOF
$ver
EOF
  x=${x:-0}; y=${y:-0}; z=${z:-0}
  case "$bump" in
    minor) printf '%s.%s.0\n' "$x" "$((y + 1))" ;;
    patch) printf '%s.%s.%s\n' "$x" "$y" "$((z + 1))" ;;
    *) die 64 "invalid bump: $bump (minor|patch)" ;;
  esac
}

read_master_version() {
  # from cwd plugin.json
  local pj=".claude-plugin/plugin.json"
  if [ ! -f "$pj" ]; then
    die 1 "missing $pj (need master version for freeze)"
  fi
  jq -r '.version // empty' "$pj"
}

# ---- commands ---------------------------------------------------------------

cmd_init() {
  queue_paths
  mkdir -p "$RT_DIR"
  if [ ! -f "$QUEUE" ]; then
    write_queue "$(empty_queue_json)"
  fi
  printf '%s\n' "$QUEUE"
}

cmd_register() {
  local branch="" bump="minor" assumed=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --bump)
        bump="${2:-}"; shift 2 || die 64 "register: --bump needs value"
        ;;
      --assumed)
        assumed="${2:-}"; shift 2 || die 64 "register: --assumed needs value"
        ;;
      -*)
        die 64 "register: unknown flag $1"
        ;;
      *)
        if [ -z "$branch" ]; then branch="$1"; shift
        else die 64 "register: unexpected arg $1"
        fi
        ;;
    esac
  done
  [ -n "$branch" ] || die 64 "register: missing <branch>"
  case "$bump" in minor|patch) ;; *) die 64 "register: --bump must be minor|patch" ;; esac

  if ! git rev-parse --verify "$branch" >/dev/null 2>&1; then
    die 1 "register: branch ref not found: $branch"
  fi

  local assumed_json="null"
  if [ -n "$assumed" ] && [ "$assumed" != "null" ]; then
    assumed_json=$(jq -cn --arg v "$(normalize_ver "$assumed")" '$v')
  fi

  local q ts
  q=$(read_queue)
  if echo "$q" | jq -e --arg b "$branch" '.entries[] | select(.branch==$b)' >/dev/null 2>&1; then
    die 1 "register: branch already queued: $branch"
  fi
  ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  local entry
  entry=$(jq -cn \
    --arg branch "$branch" \
    --arg bump "$bump" \
    --argjson assumed "$assumed_json" \
    --arg ts "$ts" \
    '{branch:$branch,bump:$bump,assumed_version:$assumed,assigned_version:null,status:"pending",base_sha:null,tag:null,blocked_paths:[],registered_at:$ts}')
  q=$(echo "$q" | jq --argjson e "$entry" '.entries += [$e] | .frozen = false | .order = [] | .master_version_at_freeze = null')
  write_queue "$q"
  echo "$q" | jq -c --arg b "$branch" '.entries[] | select(.branch==$b)'
}

cmd_list() {
  read_queue | jq .
}

cmd_drop() {
  local branch="${1:-}"
  [ -n "$branch" ] || die 64 "drop: missing <branch>"
  local q status
  q=$(read_queue)
  status=$(echo "$q" | jq -r --arg b "$branch" '.entries[] | select(.branch==$b) | .status' | head -1)
  [ -n "$status" ] || die 1 "drop: branch not in queue: $branch"
  [ "$status" = "pending" ] || die 1 "drop: only pending entries may be dropped (status=$status)"
  q=$(echo "$q" | jq --arg b "$branch" '
    .entries |= map(select(.branch != $b))
    | .order |= map(select(. != $b))
    | if (.entries | length) == 0 then .frozen=false | .master_version_at_freeze=null else . end
  ')
  write_queue "$q"
  printf 'dropped %s\n' "$branch"
}

cmd_freeze() {
  local order_csv="" print_only=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --order) order_csv="${2:-}"; shift 2 || die 64 "freeze: --order needs value" ;;
      --print-only) print_only=1; shift ;;
      *) die 64 "freeze: unknown arg $1" ;;
    esac
  done

  local q
  q=$(read_queue)
  local n
  n=$(echo "$q" | jq '.entries | length')
  [ "$n" -gt 0 ] || die 1 "freeze: queue is empty"

  local master_ver
  master_ver=$(read_master_version)
  [ -n "$master_ver" ] || die 1 "freeze: could not read master version"

  # Build order list
  local order_json
  if [ -n "$order_csv" ]; then
    order_json=$(printf '%s' "$order_csv" | jq -Rc 'split(",") | map(select(length>0))')
    # --order must be a permutation of all non-landed queue branches (no silent drops)
    local o_len u_len
    o_len=$(echo "$order_json" | jq 'length')
    u_len=$(echo "$order_json" | jq 'unique | length')
    [ "$o_len" -eq "$u_len" ] || die 1 "freeze: --order has duplicate branches"
    local b st
    for b in $(echo "$order_json" | jq -r '.[]'); do
      st=$(echo "$q" | jq -r --arg b "$b" '
        (.entries[] | select(.branch==$b) | .status) // empty')
      [ -n "$st" ] || die 1 "freeze: branch not in queue: $b"
      [ "$st" != "landed" ] || die 1 "freeze: --order must not include landed branch: $b"
    done
    while IFS= read -r b; do
      [ -n "$b" ] || continue
      echo "$order_json" | jq -e --arg b "$b" 'index($b) != null' >/dev/null \
        || die 1 "freeze: --order missing non-landed branch: $b (must list every non-landed entry exactly once)"
    done < <(echo "$q" | jq -r '.entries[] | select(.status != "landed") | .branch')
  else
    # registration order
    order_json=$(echo "$q" | jq '[.entries[].branch]')
  fi

  # If already frozen and not print-only and no order override: idempotent return
  if [ "$print_only" -eq 0 ] && [ -z "$order_csv" ]; then
    if echo "$q" | jq -e '.frozen == true' >/dev/null 2>&1; then
      echo "$q" | jq '{frozen,master_version_at_freeze,order,entries:[.entries[]|{branch,bump,assumed_version,assigned_version,status}]}'
      return 0
    fi
  fi

  # Assign slots sequentially for entries in order
  local cur="$master_ver"
  local plan_entries="[]"
  local branch bump assigned assumed status
  while IFS= read -r branch; do
    [ -n "$branch" ] || continue
    bump=$(echo "$q" | jq -r --arg b "$branch" '.entries[] | select(.branch==$b) | .bump')
    assumed=$(echo "$q" | jq -r --arg b "$branch" '.entries[] | select(.branch==$b) | .assumed_version // empty')
    status=$(echo "$q" | jq -r --arg b "$branch" '.entries[] | select(.branch==$b) | .status')
    if [ "$status" = "landed" ]; then
      assigned=$(echo "$q" | jq -r --arg b "$branch" '.entries[] | select(.branch==$b) | .assigned_version // empty')
      [ -n "$assigned" ] && cur="$assigned"
    else
      assigned=$(bump_version "$cur" "$bump")
      cur="$assigned"
    fi
    plan_entries=$(echo "$plan_entries" | jq \
      --arg b "$branch" --arg bump "$bump" --arg av "$assigned" \
      --argjson assumed "$(echo "$q" | jq -c --arg b "$branch" '.entries[] | select(.branch==$b) | .assumed_version')" \
      --arg st "$status" \
      '. + [{branch:$b,bump:$bump,assumed_version:$assumed,assigned_version:$av,status:$st}]')
  done < <(echo "$order_json" | jq -r '.[]')

  local plan
  plan=$(jq -n \
    --arg mv "$master_ver" \
    --argjson order "$order_json" \
    --argjson entries "$plan_entries" \
    '{frozen:true,master_version_at_freeze:$mv,order:$order,entries:$entries}')

  if [ "$print_only" -eq 1 ]; then
    echo "$plan" | jq .
    return 0
  fi

  # Write assignments into queue (never drop entries not in order — e.g. landed)
  q=$(echo "$q" | jq \
    --arg mv "$master_ver" \
    --argjson order "$order_json" \
    --argjson plan_entries "$plan_entries" '
    .frozen = true
    | .master_version_at_freeze = $mv
    | .order = $order
    | .entries = [
        .entries[] as $e
        | (($plan_entries | map(select(.branch == $e.branch)) | .[0]) // null) as $p
        | if $p != null then $e + {assigned_version: $p.assigned_version} else $e end
      ]
  ')
  # Reorder: order list first, then any remaining entries (landed etc.) preserved
  q=$(echo "$q" | jq --argjson order "$order_json" '
    .entries as $ents
    | .entries = (
        [ $order[] as $b | ($ents[] | select(.branch == $b)) ]
        + [ $ents[] | select(.branch as $b | ($order | index($b) | not)) ]
      )
  ')
  write_queue "$q"
  echo "$q" | jq '{frozen,master_version_at_freeze,order,entries:[.entries[]|{branch,bump,assumed_version,assigned_version,status}]}'
}

cmd_show_plan() {
  local q
  q=$(read_queue)
  if ! echo "$q" | jq -e '.frozen == true' >/dev/null 2>&1; then
    die 1 "show-plan: queue not frozen (run freeze first)"
  fi
  echo "$q" | jq '{frozen,master_version_at_freeze,order,entries:[.entries[]|{branch,bump,assumed_version,assigned_version,status,tag}]}'
}

# Legal transitions: pending→landing, landing→landed, landing→blocked
cmd_set_status() {
  local branch="" status="" base_sha="" tag="" paths=""
  branch="${1:-}"; status="${2:-}"
  [ -n "$branch" ] && [ -n "$status" ] || die 64 "set-status: need <branch> <status>"
  shift 2 || true
  while [ $# -gt 0 ]; do
    case "$1" in
      --base-sha) base_sha="${2:-}"; shift 2 || die 64 "set-status: --base-sha needs value" ;;
      --tag) tag="${2:-}"; shift 2 || die 64 "set-status: --tag needs value" ;;
      --paths) paths="${2:-}"; shift 2 || die 64 "set-status: --paths needs value" ;;
      *) die 64 "set-status: unknown arg $1" ;;
    esac
  done
  case "$status" in pending|landing|landed|blocked) ;; *) die 64 "set-status: invalid status $status" ;; esac

  local q cur
  q=$(read_queue)
  cur=$(echo "$q" | jq -r --arg b "$branch" '.entries[] | select(.branch==$b) | .status' | head -1)
  [ -n "$cur" ] || die 1 "set-status: branch not in queue: $branch"

  local ok=0
  case "$cur:$status" in
    pending:landing) ok=1 ;;
    landing:landed) ok=1 ;;
    landing:blocked) ok=1 ;;
    *)
      if [ "$cur" = "$status" ]; then ok=1
      else die 1 "set-status: illegal transition $cur → $status (M15)"
      fi
      ;;
  esac
  [ "$ok" -eq 1 ]

  local paths_json="null"
  if [ -n "$paths" ]; then
    paths_json=$(printf '%s' "$paths" | jq -Rc 'split(",") | map(select(length>0))')
  fi

  q=$(echo "$q" | jq \
    --arg b "$branch" --arg st "$status" \
    --arg bs "$base_sha" --arg tg "$tag" \
    --argjson paths "$paths_json" '
    .entries |= map(
      if .branch == $b then
        .status = $st
        | if $bs != "" then .base_sha = $bs else . end
        | if $tg != "" then .tag = $tg else . end
        | if $paths != null then .blocked_paths = $paths else . end
      else . end
    )
  ')
  write_queue "$q"
  echo "$q" | jq -c --arg b "$branch" '.entries[] | select(.branch==$b)'
}

cmd_detect_assumed() {
  local branch="${1:-}"
  [ -n "$branch" ] || die 64 "detect-assumed: missing <branch>"
  git rev-parse --verify "$branch" >/dev/null 2>&1 || die 1 "detect-assumed: branch not found: $branch"

  local cl_ver="" pj_ver=""
  local cl
  cl=$(git show "$branch:CHANGELOG.md" 2>/dev/null || true)
  if [ -n "$cl" ]; then
    cl_ver=$(printf '%s\n' "$cl" | grep -E '^### v?[0-9]+\.[0-9]+\.[0-9]+' | head -1 | sed -E 's/^### v?//' | tr -d '[:space:]' || true)
  fi
  local pj
  pj=$(git show "$branch:.claude-plugin/plugin.json" 2>/dev/null || true)
  if [ -n "$pj" ]; then
    pj_ver=$(printf '%s\n' "$pj" | jq -r '.version // empty' 2>/dev/null || true)
  fi
  cl_ver=$(normalize_ver "${cl_ver:-}")
  pj_ver=$(normalize_ver "${pj_ver:-}")

  if [ -n "$cl_ver" ] && [ -n "$pj_ver" ]; then
    if [ "$cl_ver" != "$pj_ver" ]; then
      die 1 "detect-assumed: CHANGELOG ($cl_ver) != plugin.json ($pj_ver) on $branch"
    fi
    printf '%s\n' "$cl_ver"
    return 0
  fi
  if [ -n "$cl_ver" ]; then printf '%s\n' "$cl_ver"; return 0; fi
  if [ -n "$pj_ver" ]; then printf '%s\n' "$pj_ver"; return 0; fi
  # empty = no assumed version
  return 0
}

cmd_renumber() {
  local assumed="${1:-}" assigned="${2:-}"
  [ -n "$assumed" ] && [ -n "$assigned" ] || die 64 "renumber: need <assumed> <assigned>"
  assumed=$(normalize_ver "$assumed")
  assigned=$(normalize_ver "$assigned")
  [ "$assumed" != "$assigned" ] || { printf 'renumber: no-op (same version)\n' >&2; return 0; }

  # CHANGELOG headings only
  if [ -f CHANGELOG.md ]; then
    python3 - "$assumed" "$assigned" <<'PY'
import re, sys
assumed, assigned = sys.argv[1], sys.argv[2]
path = "CHANGELOG.md"
text = open(path).read()
# replace ### vASSUMED or ### ASSUMED headings only
pat = re.compile(r'^(### )v?' + re.escape(assumed) + r'\s*$', re.M)
text2, n = pat.subn(r'\1v' + assigned, text)
open(path, "w").write(text2)
print(f"renumber: CHANGELOG headings updated ({n})", file=sys.stderr)
PY
  fi
  if [ -f .claude-plugin/plugin.json ]; then
    local tmp
    tmp=$(mktemp "${TMPDIR:-/tmp}/rt-pj.XXXXXX")
    jq --arg a "$assumed" --arg v "$assigned" \
      'if .version == $a then .version = $v else . end' \
      .claude-plugin/plugin.json > "$tmp"
    mv "$tmp" .claude-plugin/plugin.json
  fi
  if [ -f .claude-plugin/marketplace.json ]; then
    local tmp
    tmp=$(mktemp "${TMPDIR:-/tmp}/rt-mp.XXXXXX")
    jq --arg a "$assumed" --arg v "$assigned" '
      if .plugins then
        .plugins |= map(if .version == $a then .version = $v else . end)
      else . end
      | if .version == $a then .version = $v else . end
    ' .claude-plugin/marketplace.json > "$tmp"
    mv "$tmp" .claude-plugin/marketplace.json
  fi
  printf '%s\n' "$assigned"
}

# ---- M5 resolvers -----------------------------------------------------------

cmd_resolve_tdd_index() {
  local ours="" theirs="" out="" path="specs/TDD.md"
  while [ $# -gt 0 ]; do
    case "$1" in
      --ours) ours="${2:-}"; shift 2 ;;
      --theirs) theirs="${2:-}"; shift 2 ;;
      --out) out="${2:-}"; shift 2 ;;
      -*) die 64 "resolve-tdd-index: unknown flag $1" ;;
      *) path="$1"; shift ;;
    esac
  done
  if [ -z "$ours" ] || [ -z "$theirs" ]; then
    # default: path is conflicted file — not supported without markers parse;
    # require file flags for v1 unit path
    die 64 "resolve-tdd-index: require --ours F --theirs F [--out F]"
  fi
  [ -n "$out" ] || out="$path"
  python3 - "$ours" "$theirs" "$out" <<'PY'
import re, sys
ours_p, theirs_p, out_p = sys.argv[1:4]
ours = open(ours_p).read().splitlines(keepends=True)
theirs = open(theirs_p).read().splitlines(keepends=True)

def parse_rows(lines):
    start = None
    for i, l in enumerate(lines):
        if re.match(r'^## Spec Index\s*$', l):
            start = i
            break
    if start is None:
        return None
    header_i = sep_i = None
    for i in range(start + 1, len(lines)):
        if lines[i].startswith('|') and 'ID' in lines[i] and header_i is None:
            header_i = i
            continue
        if header_i is not None and re.match(r'^\|[\s\-|]+\|\s*$', lines[i]):
            sep_i = i
            break
    if header_i is None or sep_i is None:
        return None
    end = sep_i + 1
    while end < len(lines) and lines[end].startswith('|'):
        end += 1
    rows = []
    for i in range(sep_i + 1, end):
        line = lines[i]
        rows.append(line if line.endswith('\n') else line + '\n')
    return {
        'prefix': lines[:sep_i + 1],
        'rows': rows,
        'suffix': lines[end:],
        'header': lines[header_i],
        'sep': lines[sep_i],
    }

def spec_num(row):
    m = re.search(r'SPEC-(\d+)', row)
    return int(m.group(1)) if m else 10**9

o = parse_rows(ours)
t = parse_rows(theirs)
if o is None:
    sys.stderr.write('error: no Spec Index in ours\n')
    sys.exit(1)
if t is None:
    sys.stderr.write('error: no Spec Index in theirs\n')
    sys.exit(1)

# master rows byte-preserved; append branch-only rows; sort by SPEC-ID
master_set = set(r.rstrip('\n') for r in o['rows'])
combined = list(o['rows'])  # preserve master order first
for r in t['rows']:
    key = r.rstrip('\n')
    if key not in master_set:
        combined.append(r if r.endswith('\n') else r + '\n')
combined.sort(key=spec_num)

out_lines = o['prefix'] + combined
# preserve ours suffix (Version History etc.) — but if theirs has extra VH handled separately
# For index-only resolve: use ours suffix (caller may run resolve-vh next)
out_lines = out_lines + o['suffix']
# If prefix ends mid-file and we only rewrote index, ensure single trailing newline
text = ''.join(out_lines)
open(out_p, 'w').write(text)
PY
}

cmd_resolve_vh() {
  local ours="" theirs="" out="" path=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --ours) ours="${2:-}"; shift 2 ;;
      --theirs) theirs="${2:-}"; shift 2 ;;
      --out) out="${2:-}"; shift 2 ;;
      -*) die 64 "resolve-vh: unknown flag $1" ;;
      *) path="$1"; shift ;;
    esac
  done
  [ -n "$ours" ] && [ -n "$theirs" ] || die 64 "resolve-vh: require --ours F --theirs F [--out F]"
  [ -n "$out" ] || out="${path:-$ours}"
  python3 - "$ours" "$theirs" "$out" <<'PY'
import re, sys
ours_p, theirs_p, out_p = sys.argv[1:4]
ours = open(ours_p).read().splitlines(keepends=True)
theirs = open(theirs_p).read().splitlines(keepends=True)

def find_vh(lines):
    start = None
    for i, l in enumerate(lines):
        if re.match(r'^## Version History\s*$', l):
            start = i
            break
    if start is None:
        return None
    header_i = sep_i = None
    for i in range(start + 1, len(lines)):
        if lines[i].startswith('|') and 'Date' in lines[i] and header_i is None:
            header_i = i
            continue
        if header_i is not None and re.match(r'^\|[\s\-|]+\|\s*$', lines[i]):
            sep_i = i
            break
    if header_i is None or sep_i is None:
        return None
    end = sep_i + 1
    while end < len(lines) and lines[end].startswith('|'):
        end += 1
    return start, header_i, sep_i, end

def rows_of(lines):
    loc = find_vh(lines)
    if loc is None:
        return None
    start, header_i, sep_i, end = loc
    rows = []
    for i in range(sep_i + 1, end):
        rows.append(lines[i] if lines[i].endswith('\n') else lines[i] + '\n')
    return {
        'before': lines[:sep_i + 1],
        'rows': rows,
        'after': lines[end:],
    }

def row_date(row):
    m = re.match(r'^\|\s*(\d{4}-\d{2}-\d{2})\s*\|', row)
    return m.group(1) if m else '9999-99-99'

o = rows_of(ours)
t = rows_of(theirs)
if o is None:
    sys.stderr.write('error: no Version History in ours\n')
    sys.exit(1)
if t is None:
    # no VH on branch — keep ours
    open(out_p, 'w').write(''.join(ours))
    sys.exit(0)

master_set = set(r.rstrip('\n') for r in o['rows'])
# stable: master rows first (in order), then branch-only in order
combined = list(o['rows'])
for r in t['rows']:
    if r.rstrip('\n') not in master_set:
        combined.append(r if r.endswith('\n') else r + '\n')

# sort by date ascending; same date: master first (already earlier in list) — use stable sort
# annotate with origin index for stability
annotated = list(enumerate(combined))
annotated.sort(key=lambda iv: (row_date(iv[1]), iv[0]))
sorted_rows = [r for _, r in annotated]

text = ''.join(o['before'] + sorted_rows + o['after'])
open(out_p, 'w').write(text)
PY
}

cmd_resolve_changelog() {
  local assigned="" branch_file="" master_file="" out="CHANGELOG.md"
  assigned="${1:-}"
  [ -n "$assigned" ] || die 64 "resolve-changelog: need <assigned>"
  shift || true
  while [ $# -gt 0 ]; do
    case "$1" in
      --branch-file) branch_file="${2:-}"; shift 2 ;;
      --master-file) master_file="${2:-}"; shift 2 ;;
      --out) out="${2:-}"; shift 2 ;;
      *) die 64 "resolve-changelog: unknown arg $1" ;;
    esac
  done
  [ -n "$branch_file" ] && [ -n "$master_file" ] || die 64 "resolve-changelog: require --branch-file F --master-file F"
  assigned=$(normalize_ver "$assigned")
  python3 - "$assigned" "$branch_file" "$master_file" "$out" <<'PY'
import re, sys
assigned, branch_p, master_p, out_p = sys.argv[1:5]
branch = open(branch_p).read()
master = open(master_p).read()

heading_re = re.compile(r'^### (v?[0-9]+\.[0-9]+\.[0-9]+)\s*$', re.M)

def sections(text):
    """Return (preamble, [(ver_norm, heading_line, body), ...])"""
    matches = list(heading_re.finditer(text))
    if not matches:
        return text, []
    preamble = text[:matches[0].start()]
    secs = []
    for i, m in enumerate(matches):
        ver = m.group(1).lstrip('v')
        start = m.end()
        end = matches[i + 1].start() if i + 1 < len(matches) else len(text)
        body = text[start:end]
        # strip leading single newline from body for storage; keep content
        secs.append((ver, m.group(0).rstrip('\n'), body))
    return preamble, secs

b_pre, b_secs = sections(branch)
m_pre, m_secs = sections(master)

# Prefer branch body: first section if any, else empty
body = ''
if b_secs:
    body = b_secs[0][2]
    # normalize body: ensure starts with newline and has content
else:
    body = '\n- (no branch changelog body)\n\n'

# Drop master sections that match assigned (avoid dup)
m_secs = [(v, h, b) for (v, h, b) in m_secs if v != assigned]
# Also drop branch assumed version if different — already taking only body

# Preamble: prefer master preamble (header block)
preamble = m_pre if m_pre.strip() else b_pre
if not preamble.endswith('\n'):
    preamble += '\n'

parts = [preamble, f'### v{assigned}\n']
# body should not duplicate heading; ensure leading newline stripped then re-add cleanly
body_stripped = body.lstrip('\n')
if not body_stripped.endswith('\n'):
    body_stripped += '\n'
parts.append(body_stripped)
if not body_stripped.endswith('\n\n') and m_secs:
    if not parts[-1].endswith('\n'):
        parts[-1] += '\n'

for v, h, b in m_secs:
    parts.append(f'### v{v}\n')
    bs = b.lstrip('\n')
    if not bs.endswith('\n'):
        bs += '\n'
    parts.append(bs)

open(out_p, 'w').write(''.join(parts))
PY
}

cmd_resolve_json() {
  local assigned="${1:-}"
  [ -n "$assigned" ] || die 64 "resolve-json: need <assigned>"
  shift || true
  local plugin=".claude-plugin/plugin.json"
  local market=".claude-plugin/marketplace.json"
  while [ $# -gt 0 ]; do
    case "$1" in
      --plugin) plugin="${2:-}"; shift 2 ;;
      --market) market="${2:-}"; shift 2 ;;
      *) die 64 "resolve-json: unknown arg $1" ;;
    esac
  done
  assigned=$(normalize_ver "$assigned")
  if [ -f "$plugin" ]; then
    local tmp
    tmp=$(mktemp "${TMPDIR:-/tmp}/rt-pj.XXXXXX")
    jq --arg v "$assigned" '.version = $v' "$plugin" > "$tmp"
    mv "$tmp" "$plugin"
  else
    die 1 "resolve-json: missing $plugin"
  fi
  if [ -f "$market" ]; then
    local tmp
    tmp=$(mktemp "${TMPDIR:-/tmp}/rt-mp.XXXXXX")
    jq --arg v "$assigned" '
      if .plugins then .plugins |= map(.version = $v) else . end
      | if has("version") then .version = $v else . end
    ' "$market" > "$tmp"
    mv "$tmp" "$market"
  else
    die 1 "resolve-json: missing $market"
  fi
  printf '%s\n' "$assigned"
}

cmd_restore() {
  local sha="${1:-}"
  [ -n "$sha" ] || die 64 "restore: missing <base_sha>"
  # abort merge/cherry-pick/rebase if in progress
  if [ -d "$(git rev-parse --git-path MERGE_HEAD 2>/dev/null || echo /dev/null)" ] 2>/dev/null; then
    :
  fi
  if [ -f "$(git rev-parse --git-path MERGE_HEAD 2>/dev/null || true)" ]; then
    git merge --abort 2>/dev/null || true
  fi
  if [ -f "$(git rev-parse --git-path CHERRY_PICK_HEAD 2>/dev/null || true)" ]; then
    git cherry-pick --abort 2>/dev/null || true
  fi
  # also clear squash-merge state
  if [ -f "$(git rev-parse --git-path SQUASH_MSG 2>/dev/null || true)" ]; then
    rm -f "$(git rev-parse --git-path SQUASH_MSG)" "$(git rev-parse --git-path MERGE_MSG)" 2>/dev/null || true
  fi
  git reset --hard "$sha" >/dev/null
  # leave untracked alone (train does not create untracked that need clean -fd)
  printf '%s\n' "$sha"
}

cmd_verify_tag() {
  local tag="${1:-}"
  [ -n "$tag" ] || die 64 "verify-tag: missing <tag>"
  # accept with or without v
  local t="$tag"
  if ! git rev-parse --verify "refs/tags/$t" >/dev/null 2>&1; then
    if [[ "$t" != v* ]] && git rev-parse --verify "refs/tags/v$t" >/dev/null 2>&1; then
      t="v$t"
    else
      die 1 "verify-tag: tag not found: $tag"
    fi
  fi
  local tag_sha head
  tag_sha=$(git rev-parse "$t^{commit}")
  head=$(git rev-parse HEAD)
  if git merge-base --is-ancestor "$tag_sha" "$head"; then
    printf '%s\n' "$tag_sha"
    return 0
  fi
  die 1 "verify-tag: $t ($tag_sha) is not an ancestor of HEAD ($head)"
}

cmd_acquire_lock() {
  queue_paths
  mkdir -p "$RT_DIR"
  if [ -f "$LOCK" ]; then
    die 1 "acquire-lock: lock held ($(cat "$LOCK" 2>/dev/null | head -c 80))"
  fi
  (umask 077; printf '%s %s\n' "$(date +%s)" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$LOCK")
  printf '%s\n' "$LOCK"
}

cmd_release_lock() {
  queue_paths
  if [ -f "$LOCK" ]; then
    rm -f "$LOCK"
    printf 'released\n'
  else
    printf 'no-lock\n'
  fi
}

cmd_preflight() {
  local branch dirty
  branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo UNKNOWN)
  dirty=$(git status --porcelain 2>/dev/null || true)
  local ok=1
  local reason=()
  case "$branch" in
    master|main) ;;
    *) ok=0; reason+=("wrong-branch:$branch") ;;
  esac
  if [ -n "$dirty" ]; then
    ok=0
    reason+=("dirty")
  fi
  if [ "$ok" -eq 1 ]; then
    printf 'ok\n'
    return 0
  fi
  local r
  r=$(IFS=,; echo "${reason[*]}")
  printf '%s\n' "$r"
  return 1
}

# ---- dispatch ---------------------------------------------------------------
[ $# -ge 1 ] || usage
CMD="$1"; shift

case "$CMD" in
  init)              cmd_init "$@" ;;
  register)          cmd_register "$@" ;;
  list)              cmd_list "$@" ;;
  drop)              cmd_drop "$@" ;;
  freeze)            cmd_freeze "$@" ;;
  show-plan)         cmd_show_plan "$@" ;;
  set-status)        cmd_set_status "$@" ;;
  detect-assumed)    cmd_detect_assumed "$@" ;;
  renumber)          cmd_renumber "$@" ;;
  resolve-tdd-index) cmd_resolve_tdd_index "$@" ;;
  resolve-vh)        cmd_resolve_vh "$@" ;;
  resolve-changelog) cmd_resolve_changelog "$@" ;;
  resolve-json)      cmd_resolve_json "$@" ;;
  restore)           cmd_restore "$@" ;;
  verify-tag)        cmd_verify_tag "$@" ;;
  acquire-lock)      cmd_acquire_lock "$@" ;;
  release-lock)      cmd_release_lock "$@" ;;
  preflight)         cmd_preflight "$@" ;;
  -h|--help|help)    usage ;;
  *)                 echo "error: unknown command: $CMD" >&2; usage ;;
esac
