#!/usr/bin/env bash
#
# council/tier-grade.sh — CDT-126 council tiering grader (SPEC-013 "Council tiering").
#
# Bands an ALREADY-RESOLVED diff into light | full | middle. Diff *resolution* is the
# caller's job — SPEC-013's Grading table names the mechanism per call site (task gate:
# staged-then-unstaged `git diff [--cached] --numstat`; autopilot ship gate: merge-base
# range via SPEC-033 N3a). This script only grades, so both call sites share one
# implementation of the bands and the 5 structural critical-area signals.
#
# Usage:
#   tier-grade.sh --numstat <file|-> [--raw <file>]
#
#   --numstat  `git diff [...] --numstat` output over the resolved diff. `-` reads stdin.
#              Required. Supplies `files`, `loc`, per-file add/delete, and the path set.
#   --raw      `git diff [...] --raw` output over the SAME diff. Nominally optional, but
#              every call site should pass it. It supplies the file modes for signal 2,
#              the post-image blob SHAs used by signals 1 and 2, and the status letter
#              that tells rename notation apart from a literal filename containing
#              " => ". Without it: signal 2 loses its `mode 100755` half, post-images
#              resolve from the working tree rather than the graded blob, the
#              raw/numstat consistency check cannot run, and any " => " path fails
#              closed because it cannot be disambiguated.
#
# Output: exactly one JSON object on stdout:
#   { tier, band, files, loc, added, deleted, grading_reason, critical_signals[], fanin_probed }
#
#   tier ∈ light | full | middle. `middle` is NOT a `council_tier` value — it means the
#   ambiguous middle band was reached and the caller MUST resolve it with exactly one
#   haiku-tier triage call. `skip` is never returned: SPEC-013 forbids grading from
#   selecting it.
#
# Exit: ALWAYS 0 with JSON on stdout, except a usage error (exit 2, no JSON). Internal
# failures — missing jq, git failure, empty/unresolvable diff, unparseable input — fail
# CLOSED to tier=full with a `fail-closed:` grading_reason. This deliberately inverts
# SPEC-026 M9's fail-open precedent (SPEC-013 "Fail-closed contract"): failing open here
# would silently weaken a verification gate. Callers MUST additionally treat any non-zero
# exit or unparseable stdout as `full`.

set -euo pipefail

# SPEC-013 grading bands. Every threshold is declared exactly once here and interpolated
# everywhere else — comparisons, fan-in caps, and grading_reason strings — so a band
# retune cannot leave a stale digit behind.
BAND_LOW_FILES=5      # clear-low: files <= this AND loc <= BAND_LOW_LOC AND no signal
BAND_LOW_LOC=100
BAND_HIGH_FILES=20    # clear-high: files > this OR loc > BAND_HIGH_LOC OR any signal
BAND_HIGH_LOC=600

FANIN_MIN=5                          # signal 3: basename referenced by >= this many
                                     # OTHER tracked files
FANIN_CAP_LOW="$BAND_LOW_FILES"      # each band's probe cap is its own file ceiling;
FANIN_CAP_MIDDLE="$BAND_HIGH_FILES"  # exceeding it is a critical-area hit (fail-closed)

FILES=0; LOC=0; ADDED=0; DELETED=0
FANIN_PROBED=false

# ---- Fail-closed emitter ----------------------------------------------------
# Must not depend on jq (missing jq is itself a fail-closed cause) or on any external
# command, so it stays usable with an empty PATH.
fail_closed() {
  trap - ERR
  # JSON-safe reason with builtins only (must work with empty PATH).
  # Strip \ and " for the printf template; strip all [[:cntrl:]] (CR/LF/TAB/NUL/…)
  # so a numstat/raw path cannot break the emitted object (CDT-128).
  local reason="$1" out="" i c
  reason="${reason//\\/ }"
  reason="${reason//\"/ }"
  for ((i = 0; i < ${#reason}; i++)); do
    c="${reason:i:1}"
    if [[ "$c" =~ [[:cntrl:]] ]]; then
      out+=" "
    else
      out+="$c"
    fi
  done
  reason="$out"
  printf '{"tier":"full","band":"fail-closed","files":%d,"loc":%d,"added":%d,"deleted":%d,"grading_reason":"fail-closed: %s","critical_signals":[],"fanin_probed":%s}\n' \
    "$FILES" "$LOC" "$ADDED" "$DELETED" "$reason" "$FANIN_PROBED"
  exit 0
}

usage() {
  echo "Usage: tier-grade.sh --numstat <file|-> [--raw <file>]" >&2
  exit 2
}

# ---- Args (builtins only — must run before the jq check) ---------------------
NUMSTAT_SRC=""
RAW_SRC=""
while [ $# -gt 0 ]; do
  case "$1" in
    --numstat) [ $# -ge 2 ] || usage; NUMSTAT_SRC="$2"; shift 2 ;;
    --raw)     [ $# -ge 2 ] || usage; RAW_SRC="$2"; shift 2 ;;
    -h|--help) usage ;;
    *)         usage ;;
  esac
done
[ -n "$NUMSTAT_SRC" ] || usage

trap 'fail_closed "grader internal error at line $LINENO"' ERR

# ---- Dependency check -------------------------------------------------------
command -v jq >/dev/null 2>&1 || fail_closed "jq not found in PATH"
command -v git >/dev/null 2>&1 || fail_closed "git not found in PATH"

# ---- Read inputs before cd (paths are relative to the caller's cwd) ----------
if [ "$NUMSTAT_SRC" = "-" ]; then
  NUMSTAT="$(cat)"
else
  [ -r "$NUMSTAT_SRC" ] || fail_closed "numstat input not readable: $NUMSTAT_SRC"
  NUMSTAT="$(cat -- "$NUMSTAT_SRC")"
fi
RAW=""
if [ -n "$RAW_SRC" ]; then
  [ -r "$RAW_SRC" ] || fail_closed "raw input not readable: $RAW_SRC"
  RAW="$(cat -- "$RAW_SRC")"
fi

[ -n "${NUMSTAT//[[:space:]]/}" ] || fail_closed "empty or unresolvable diff (no numstat rows)"

# ---- Repo root --------------------------------------------------------------
TOPLEVEL="$(git rev-parse --show-toplevel 2>/dev/null)" \
  || fail_closed "git failure: not inside a work tree"
cd "$TOPLEVEL" || fail_closed "git failure: cannot enter work tree $TOPLEVEL"

# ---- Parse `git diff --raw` -------------------------------------------------
# --raw is the only input that says whether a row is a rename: its status letter. The
# post-image path in --raw is always literal, never rename notation.
declare -A SRCMODE=() DSTMODE=() DSTSHA=() STATUS=()
if [ -n "$RAW" ]; then
  while IFS= read -r line; do
    case "$line" in ':'*) ;; *) continue ;; esac
    meta="${line%%$'\t'*}"
    paths="${line#*$'\t'}"
    post="${paths##*$'\t'}"
    read -r smode dmode _ssha dsha status <<<"${meta#:}"
    SRCMODE["$post"]="$smode"
    DSTMODE["$post"]="$dmode"
    DSTSHA["$post"]="$dsha"
    STATUS["$post"]="$status"
  done <<<"$RAW"
fi

# ---- Parse `git diff --numstat` ---------------------------------------------
# Resolves git's rename notation to the post-image path:
#   "old.txt => new.txt"   -> new.txt
#   "dir/{a => b}/f.txt"   -> dir/b/f.txt
#   "dir/{b => }/f.txt"    -> dir/f.txt   (segment removed; see below)
postimage_path() {
  local p="$1"
  case "$p" in
    *' => '*)
      if [[ "$p" == *'{'*' => '*'}'* ]]; then
        local prefix rest new_suffix new suffix out
        prefix="${p%%\{*}"
        rest="${p#*\{}"
        new_suffix="${rest#* => }"
        new="${new_suffix%%\}*}"
        suffix="${new_suffix#*\}}"
        # `git mv a/b/tool a/tool` emits "a/{b => }/tool": git keeps the prefix's
        # trailing "/" AND the suffix's leading "/", so an empty replacement leaves
        # both separators behind. Concatenating them raw yields "a//tool", which then
        # misses every --raw lookup keyed on the real path.
        if [ -z "$new" ]; then suffix="${suffix#/}"; fi
        out="$prefix$new$suffix"
        printf '%s' "$out"
      else
        printf '%s' "${p#* => }"
      fi
      ;;
    *) printf '%s' "$p" ;;
  esac
}

# A numstat path containing " => " is AMBIGUOUS: it is either rename notation, or the
# literal name of a file that happens to contain that substring — numstat carries no
# marker to tell them apart. A crafted pair (a real executable under a directory
# literally named "{a => b}", plus a decoy at the collapsed path "b/") therefore aimed
# the executable's row at the decoy's mode and content, and graded light.
#
# Only --raw's status letter distinguishes them, so the collapse is applied ONLY when
# --raw confirms a rename (R) or copy (C) at the collapsed path. Anything else resolves
# verbatim, and a path that could legitimately be read both ways fails closed.
RESOLVED=""
resolve_postimage() {
  local np="$1" cp literal_ok=0 rename_ok=0
  case "$np" in
    *' => '*) ;;
    *) RESOLVED="$np"; return 0 ;;
  esac
  [ -n "$RAW" ] || fail_closed "numstat path needs --raw to tell rename notation from a literal name: $np"
  if [ -n "${STATUS[$np]+set}" ]; then
    case "${STATUS[$np]}" in R*|C*) ;; *) literal_ok=1 ;; esac
  fi
  cp="$(postimage_path "$np")"
  if [ "$cp" != "$np" ] && [ -n "${STATUS[$cp]+set}" ]; then
    case "${STATUS[$cp]}" in R*|C*) rename_ok=1 ;; esac
  fi
  if [ "$literal_ok" -eq 1 ] && [ "$rename_ok" -eq 1 ]; then
    fail_closed "ambiguous numstat path — matches both a literal file and a rename post-image: $np"
  elif [ "$literal_ok" -eq 1 ]; then
    RESOLVED="$np"
  elif [ "$rename_ok" -eq 1 ]; then
    RESOLVED="$cp"
  else
    fail_closed "numstat path matches no --raw row as either a literal name or a rename post-image: $np"
  fi
}

PATHS=(); ADD=(); DEL=()
LOC_UNAVAILABLE=0
while IFS= read -r line; do
  [ -n "${line//[[:space:]]/}" ] || continue
  a="${line%%$'\t'*}"
  rest="${line#*$'\t'}"
  [ "$rest" != "$line" ] || fail_closed "malformed numstat line: $line"
  d="${rest%%$'\t'*}"
  p="${rest#*$'\t'}"
  [ "$p" != "$rest" ] || fail_closed "malformed numstat line: $line"
  [[ "$a" =~ ^([0-9]+|-)$ && "$d" =~ ^([0-9]+|-)$ ]] || fail_closed "malformed numstat line: $line"
  case "$p" in
    '"'*) fail_closed "unsupported C-quoted path in numstat: $p" ;;
  esac
  resolve_postimage "$p"
  p="$RESOLVED"
  [ -n "$p" ] || fail_closed "malformed numstat line: $line"
  # `-` means "no line count available" — a binary file, or any path marked `-diff`
  # in .gitattributes (vendored deps, generated protobuf, minified assets). Such a
  # file's real size is UNKNOWN, not zero, so it must never be counted as 0 toward a
  # clear-low grade; see the band chain.
  if [ "$a" = "-" ] || [ "$d" = "-" ]; then
    LOC_UNAVAILABLE=$((LOC_UNAVAILABLE + 1))
    [ "$a" != "-" ] || a=0
    [ "$d" != "-" ] || d=0
  fi
  PATHS+=("$p"); ADD+=("$a"); DEL+=("$d")
  ADDED=$((ADDED + a)); DELETED=$((DELETED + d))
done <<<"$NUMSTAT"

FILES=${#PATHS[@]}
LOC=$((ADDED + DELETED))
[ "$FILES" -gt 0 ] || fail_closed "empty or unresolvable diff (no numstat rows)"

# When --raw is supplied it must describe the same diff as --numstat. A path present in
# one but not the other means the two inputs disagree, and the post-image we would fall
# back to (the working tree) is then unrelated to what is being graded — at the M14 ship
# gate the graded range is committed history, not the working tree. Fail closed rather
# than sign off on signals computed from the wrong bytes.
if [ -n "$RAW" ]; then
  for p in "${PATHS[@]}"; do
    [ -n "${DSTMODE[$p]+set}" ] \
      || fail_closed "--raw does not describe numstat path: $p"
  done
fi

# ---- Post-image access ------------------------------------------------------
# Prefer the blob named by --raw (authoritative for staged and ref-range diffs); fall
# back to the working-tree file, which is the post-image for an unstaged diff and the
# only option when --raw was not supplied.
post_image_head() {
  # Strip NUL before capture — bash command substitution warns on every binary
  # blob that contains \0 (CDT-128). Prefer blob from --raw when present.
  local p="$1" sha="${DSTSHA[$1]:-}"
  if [ -n "$sha" ] && [ -n "${sha//0/}" ]; then
    git cat-file blob "$sha" 2>/dev/null | tr -d '\0' | head -n 100 || true
  elif [ -f "$p" ]; then
    tr -d '\0' <"$p" 2>/dev/null | head -n 100 || true
  fi
}

# ---- Critical-area signals --------------------------------------------------
SIG_TSV=""
add_signal() {  # <num> <name> <file> <why>
  SIG_TSV+="$1"$'\t'"$2"$'\t'"$3"$'\t'"$4"$'\n'
}

for i in "${!PATHS[@]}"; do
  p="${PATHS[$i]}"; a="${ADD[$i]}"; d="${DEL[$i]}"
  spec_why=""; exec_why=""

  # Signal 1 — spec / contract file (path and basename halves)
  case "$p" in
    specs/*|*/specs/*) spec_why="path contains a specs/ segment" ;;
  esac
  if [ -z "$spec_why" ]; then
    case "${p##*/}" in
      SPEC-*.md) spec_why="basename matches SPEC-*.md" ;;
    esac
  fi

  # Signal 2 — executable (mode half)
  if [ "${DSTMODE[$p]:-}" = "100755" ]; then
    exec_why="git diff --raw dst mode 100755"
  elif [ "${SRCMODE[$p]:-}" = "100755" ]; then
    exec_why="git diff --raw src mode 100755"
  fi

  # Content halves — one post-image fetch, only when a content half can still fire.
  if [ -z "$spec_why" ] || [ -z "$exec_why" ]; then
    body="$(post_image_head "$p")"
    if [ -z "$exec_why" ]; then
      case "$body" in
        '#!'*) exec_why="post-image begins with #!" ;;
      esac
    fi
    if [ -z "$spec_why" ] && [ "${body%%$'\n'*}" = "---" ]; then
      if printf '%s\n' "$body" | sed -n '2,/^---[[:space:]]*$/p' | grep -q '^status:'; then
        spec_why="YAML frontmatter carries a status: key"
      fi
    fi
  fi

  # CDT-132: tiny content-only edits to paths already at mode 100755 must not
  # alone force clear-high full council. Mode flips (chmod), renames (R*),
  # shebang-only signal 2, and material LOC (>= clear-low band) still fire.
  if [ -n "$exec_why" ]; then
    case "$exec_why" in
      *'100755'*)
        _srcm="${SRCMODE[$p]:-}"
        _dstm="${DSTMODE[$p]:-}"
        _st="${STATUS[$p]:-}"
        _floc=$((a + d))
        case "$_st" in
          R*|C*) ;;  # rename/copy of executable stays critical
          *)
            if [ "$_srcm" = "$_dstm" ] && [ "$_floc" -lt "$BAND_LOW_LOC" ]; then
              exec_why=""
            fi
            ;;
        esac
        ;;
    esac
  fi

  [ -z "$spec_why" ] || add_signal 1 spec-contract "$p" "$spec_why"
  [ -z "$exec_why" ] || add_signal 2 executable "$p" "$exec_why"

  # Signal 4 — deletion-heavy executable
  if [ -n "$exec_why" ] && [ "$d" -gt 30 ]; then
    add_signal 4 deletion-heavy-executable "$p" "$d deleted lines in an executable (>30)"
  fi

  # Signal 5 — test removal
  case "$p" in
    *test*|*_test.*|test_*)
      if [ $((a - d)) -lt 0 ]; then
        add_signal 5 test-removal "$p" "net-negative LOC ($a added, $d deleted) in a test-matching path"
      fi
      ;;
  esac
done

# ---- Signal 3 — high fan-in (the one costly probe) ---------------------------
# Runs in both non-clear-high bands, because a 3-line edit to a file 11 others depend on
# is exactly the change a light council would under-review. Skipped for clear-high, which
# is already resolved. Each cap is derived from its band's own file ceiling, so no run can
# exceed it and the cap branch cannot fire today — it is kept as the fail-closed guard
# SPEC-013 mandates for the band retune it anticipates, NOT dead code.
probe_fanin() {
  local cap="$1" p base matches rc n m
  FANIN_PROBED=true
  if [ "$FILES" -gt "$cap" ]; then
    add_signal 3 high-fan-in '*' "fan-in probe cap exceeded ($FILES > $cap) — fail-closed"
    return 0
  fi
  for p in "${PATHS[@]}"; do
    base="${p##*/}"
    rc=0
    matches="$(git grep -l -F -- "$base" 2>/dev/null)" || rc=$?
    [ "$rc" -le 1 ] || fail_closed "git failure: git grep exited $rc while probing fan-in for $base"
    n=0
    while IFS= read -r m; do
      [ -n "$m" ] || continue
      [ "$m" != "$p" ] || continue
      n=$((n + 1))
    done <<<"$matches"
    if [ "$n" -ge "$FANIN_MIN" ]; then
      add_signal 3 high-fan-in "$p" "basename '$base' referenced by $n other tracked files (>=$FANIN_MIN)"
    fi
  done
}

# ---- Bands ------------------------------------------------------------------
TIER=""; BAND=""; REASON=""
clear_high() {
  TIER=full; BAND=clear-high
  REASON="clear-high (files=$FILES, loc=$LOC, critical-area signal fired)"
}

if [ -n "$SIG_TSV" ]; then
  clear_high
elif [ "$FILES" -gt "$BAND_HIGH_FILES" ] || [ "$LOC" -gt "$BAND_HIGH_LOC" ]; then
  TIER=full; BAND=clear-high
  breached=""
  if [ "$FILES" -gt "$BAND_HIGH_FILES" ]; then breached="files=$FILES>$BAND_HIGH_FILES"; fi
  if [ "$LOC" -gt "$BAND_HIGH_LOC" ]; then
    if [ -n "$breached" ]; then breached="$breached, "; fi
    breached="${breached}loc=$LOC>$BAND_HIGH_LOC"
  fi
  REASON="clear-high ($breached)"
elif [ "$FILES" -le "$BAND_LOW_FILES" ] && [ "$LOC" -le "$BAND_LOW_LOC" ] \
  && [ "$LOC_UNAVAILABLE" -eq 0 ]; then
  probe_fanin "$FANIN_CAP_LOW"
  if [ -n "$SIG_TSV" ]; then
    clear_high
  else
    TIER=light; BAND=clear-low
    REASON="clear-low (files=$FILES<=$BAND_LOW_FILES, loc=$LOC<=$BAND_LOW_LOC, no critical-area signal)"
  fi
else
  # Reached either by the band arithmetic or because at least one file has no line
  # count. `loc` is then only a lower bound, so clear-low is unprovable and the run
  # drops to triage rather than to light.
  probe_fanin "$FANIN_CAP_MIDDLE"
  if [ -n "$SIG_TSV" ]; then
    clear_high
  else
    TIER=middle; BAND=middle
    REASON="ambiguous-middle (files=$FILES, loc=$LOC) — triage call required"
    if [ "$LOC_UNAVAILABLE" -gt 0 ]; then
      REASON="ambiguous-middle (files=$FILES, loc>=$LOC, $LOC_UNAVAILABLE file(s) with no line count available) — triage call required"
    fi
  fi
fi

# ---- Emit -------------------------------------------------------------------
SIGNALS_JSON="$(printf '%s' "$SIG_TSV" | jq -R -s -c \
  'split("\n") | map(select(length > 0) | split("\t"))
   | map({signal: (.[0] | tonumber), name: .[1], file: .[2], why: .[3]})')" \
  || fail_closed "jq failed to encode critical_signals"

jq -n \
  --arg tier "$TIER" \
  --arg band "$BAND" \
  --arg reason "$REASON" \
  --argjson files "$FILES" \
  --argjson loc "$LOC" \
  --argjson added "$ADDED" \
  --argjson deleted "$DELETED" \
  --argjson signals "$SIGNALS_JSON" \
  --argjson fanin_probed "$FANIN_PROBED" \
  '{tier: $tier, band: $band, files: $files, loc: $loc, added: $added, deleted: $deleted,
    grading_reason: $reason, critical_signals: $signals, fanin_probed: $fanin_probed}' \
  || fail_closed "jq failed to encode grading result"
