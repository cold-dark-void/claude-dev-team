#!/usr/bin/env bash
# trial-review.sh — evidence comparison for directive trials (CDV-200 / SPEC-001 M4–M7)
#
# Pure CLI — never sourced. Does NOT write directives.md.
#
# Usage (review):
#   trial-review.sh --mroot PATH \
#     [--today YYYY-MM-DD] \
#     [--projects-root PATH] \
#     [--scope current|all] \
#     [--gate PATH] \
#     [--session-scores-file PATH] \
#     [--freshness-secs N]
#
# stdout TSV (KEEP|REVERT only; one row per decision):
#   action\tagent\tdirective_text\tsource\ttrial_start\tbaseline_mean\tbaseline_n\
#   in_trial_mean\tin_trial_n\tbaseline_ids\tin_trial_ids\treview_after
#
# DEFER (n_baseline < 2 OR n_in_trial < 2, or window not elapsed) → stderr only:
#   # trial-review: defer agent=… reason=…
#
# Usage (audit append — call AFTER successful /adjust-agent apply):
#   trial-review.sh --record-decision --mroot PATH \
#     --agent A --directive D --source S --trial-start T \
#     --baseline-mean M --baseline-n N --baseline-ids IDS \
#     --in-trial-mean M --in-trial-n N --in-trial-ids IDS \
#     --decision KEEP|REVERT --decided-by user|auto
#
# Session discovery (when --session-scores-file absent) — keep in sync with
# commands/retro.md Step 2: ~/.claude/projects/, skip mtime < freshness-secs (60),
# score via gate.sh. MVP = project-level scores (not agent-filtered; OQ-2).
set -u

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
META_SH="$SCRIPT_DIR/trial-meta.sh"
DEFAULT_GATE="$SCRIPT_DIR/gate.sh"
AGENTS="pm tech-lead ic5 ic4 devops qa ds"

MROOT=""
TODAY=""
PROJECTS_ROOT="${HOME}/.claude/projects"
SCOPE="current"
GATE_SH=""
SCORES_FILE=""
FRESHNESS_SECS=60
RECORD=0

# record-decision fields
R_AGENT="" R_DIRECTIVE="" R_SOURCE="" R_TRIAL_START=""
R_B_MEAN="" R_B_N="" R_B_IDS=""
R_T_MEAN="" R_T_N="" R_T_IDS=""
R_DECISION="" R_BY=""

usage() {
  echo "usage: trial-review.sh --mroot PATH [review opts] | --record-decision ..." >&2
  exit 1
}

while [ $# -gt 0 ]; do
  case "$1" in
    --mroot) MROOT=${2:-}; shift 2 ;;
    --today) TODAY=${2:-}; shift 2 ;;
    --projects-root) PROJECTS_ROOT=${2:-}; shift 2 ;;
    --scope) SCOPE=${2:-}; shift 2 ;;
    --gate) GATE_SH=${2:-}; shift 2 ;;
    --session-scores-file) SCORES_FILE=${2:-}; shift 2 ;;
    --freshness-secs) FRESHNESS_SECS=${2:-60}; shift 2 ;;
    --record-decision) RECORD=1; shift ;;
    --agent) R_AGENT=${2:-}; shift 2 ;;
    --directive) R_DIRECTIVE=${2:-}; shift 2 ;;
    --source) R_SOURCE=${2:-}; shift 2 ;;
    --trial-start) R_TRIAL_START=${2:-}; shift 2 ;;
    --baseline-mean) R_B_MEAN=${2:-}; shift 2 ;;
    --baseline-n) R_B_N=${2:-}; shift 2 ;;
    --baseline-ids) R_B_IDS=${2:-}; shift 2 ;;
    --in-trial-mean) R_T_MEAN=${2:-}; shift 2 ;;
    --in-trial-n) R_T_N=${2:-}; shift 2 ;;
    --in-trial-ids) R_T_IDS=${2:-}; shift 2 ;;
    --decision) R_DECISION=${2:-}; shift 2 ;;
    --decided-by) R_BY=${2:-}; shift 2 ;;
    -h|--help) usage ;;
    *)
      echo "trial-review: unknown arg: $1" >&2
      usage
      ;;
  esac
done

[ -n "$MROOT" ] || usage
TODAY=${TODAY:-$(date -u +%Y-%m-%d)}
GATE_SH=${GATE_SH:-$DEFAULT_GATE}

# ── record-decision ──────────────────────────────────────────────────────────
if [ "$RECORD" -eq 1 ]; then
  if [ -z "$R_AGENT" ] || [ -z "$R_DIRECTIVE" ] || [ -z "$R_DECISION" ] || [ -z "$R_BY" ]; then
    echo "trial-review --record-decision: --agent --directive --decision --decided-by required" >&2
    exit 1
  fi
  case "$R_DECISION" in KEEP|REVERT) ;; *)
    echo "trial-review --record-decision: --decision must be KEEP|REVERT" >&2
    exit 1
    ;;
  esac
  case "$R_BY" in user|auto) ;; *)
    echo "trial-review --record-decision: --decided-by must be user|auto" >&2
    exit 1
    ;;
  esac
  RETRO_DIR="$MROOT/.claude/retro"
  mkdir -p "$RETRO_DIR" || {
    echo "trial-review: cannot create $RETRO_DIR" >&2
    exit 1
  }
  AUDIT="$RETRO_DIR/directive-history.jsonl"
  TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  # JSON via python3 for safe escaping (write direct to audit; no command-sub + heredoc)
  export TR_TS="$TS" TR_AGENT="$R_AGENT" TR_DIR="$R_DIRECTIVE" TR_SRC="${R_SOURCE:-}" \
    TR_START="${R_TRIAL_START:-}" TR_BM="${R_B_MEAN:-0}" TR_BN="${R_B_N:-0}" TR_BI="${R_B_IDS:-}" \
    TR_TM="${R_T_MEAN:-0}" TR_TN="${R_T_N:-0}" TR_TI="${R_T_IDS:-}" \
    TR_DEC="$R_DECISION" TR_BY="$R_BY" TR_AUDIT="$AUDIT"
  if ! command -v python3 >/dev/null 2>&1; then
    echo "trial-review: python3 required for --record-decision" >&2
    exit 1
  fi
  python3 - <<'PY'
import json, os
def ids(s):
    s = (s or "").strip()
    if not s:
        return []
    return [x for x in s.split(",") if x]

def num(s, default=0.0):
    try:
        return float(s)
    except Exception:
        return default

def nint(s, default=0):
    try:
        return int(float(s))
    except Exception:
        return default

rec = {
    "ts": os.environ.get("TR_TS", ""),
    "agent": os.environ.get("TR_AGENT", ""),
    "directive": os.environ.get("TR_DIR", ""),
    "source": os.environ.get("TR_SRC", ""),
    "trial_start": os.environ.get("TR_START", ""),
    "baseline": {
        "mean": num(os.environ.get("TR_BM")),
        "n": nint(os.environ.get("TR_BN")),
        "sessions": ids(os.environ.get("TR_BI")),
    },
    "in_trial": {
        "mean": num(os.environ.get("TR_TM")),
        "n": nint(os.environ.get("TR_TN")),
        "sessions": ids(os.environ.get("TR_TI")),
    },
    "decision": os.environ.get("TR_DEC", ""),
    "decided_by": os.environ.get("TR_BY", ""),
}
path = os.environ["TR_AUDIT"]
with open(path, "a", encoding="utf-8") as f:
    f.write(json.dumps(rec, separators=(",", ":")) + "\n")
PY
  if [ $? -ne 0 ]; then
    echo "trial-review: cannot append audit record" >&2
    exit 1
  fi
  exit 0
fi

# ── review ───────────────────────────────────────────────────────────────────
[ -x "$META_SH" ] || [ -f "$META_SH" ] || {
  echo "trial-review: trial-meta.sh missing at $META_SH" >&2
  exit 1
}

# Build SCORES_TSV: session_id \t score \t mtime_epoch
# Either from --session-scores-file or by scanning projects + gate.sh
SCORES_TSV=""
MTIMES_TMP=$(mktemp "${TMPDIR:-/tmp}/trial-review-mtimes.XXXXXX")
trap 'rm -f "$MTIMES_TMP"' EXIT

if [ -n "$SCORES_FILE" ]; then
  if [ ! -f "$SCORES_FILE" ]; then
    echo "trial-review: session-scores-file not found: $SCORES_FILE" >&2
    exit 1
  fi
  # Accept: session_id \t score \t mtime_epoch
  while IFS= read -r row || [ -n "$row" ]; do
    [ -z "$row" ] && continue
    case "$row" in \#*) continue ;; esac
    sid=$(printf '%s' "$row" | cut -f1)
    score=$(printf '%s' "$row" | cut -f2)
    mt=$(printf '%s' "$row" | cut -f3)
    [ -n "$sid" ] || continue
    SCORES_TSV="${SCORES_TSV}${sid}"$'\t'"${score}"$'\t'"${mt}"$'\n'
    printf '%s\n' "$mt" >>"$MTIMES_TMP"
  done <"$SCORES_FILE"
else
  # Discover JSONLs under projects-root (keep in sync with commands/retro.md Step 2)
  NOW=$(date +%s)
  # Encode MROOT for current-project scope: / → -
  ENC_PROJ=$(printf '%s' "$MROOT" | sed 's|/|-|g')
  SEARCH_ROOTS=""
  if [ "$SCOPE" = "all" ]; then
    if [ -d "$PROJECTS_ROOT" ]; then
      # shellcheck disable=SC2044
      for d in "$PROJECTS_ROOT"/*; do
        [ -d "$d" ] || continue
        SEARCH_ROOTS="${SEARCH_ROOTS}${d}"$'\n'
      done
    fi
  else
    CAND="$PROJECTS_ROOT/$ENC_PROJ"
    if [ -d "$CAND" ]; then
      SEARCH_ROOTS="$CAND"
    fi
  fi

  if [ -n "$SEARCH_ROOTS" ] && [ -f "$GATE_SH" ]; then
    while IFS= read -r projdir || [ -n "$projdir" ]; do
      [ -z "$projdir" ] && continue
      [ -d "$projdir" ] || continue
      # find jsonl files (no -print0 for portability; paths with newlines are rare)
      # shellcheck disable=SC2044
      for f in "$projdir"/*.jsonl; do
        [ -f "$f" ] || continue
        # Freshness guard: skip mtime < FRESHNESS_SECS
        mt=$(stat -c %Y "$f" 2>/dev/null || stat -f %m "$f" 2>/dev/null || echo 0)
        age=$((NOW - mt))
        if [ "$age" -lt "$FRESHNESS_SECS" ]; then
          continue
        fi
        # Score via gate.sh (always exit 0; JSON on stdout)
        verdict=$(bash "$GATE_SH" "$f" 2>/dev/null | head -1)
        score=$(printf '%s' "$verdict" | python3 -c 'import json,sys
try:
  print(json.load(sys.stdin).get("score", 0))
except Exception:
  print(0)' 2>/dev/null || echo 0)
        sid=$(basename "$f" .jsonl)
        SCORES_TSV="${SCORES_TSV}${sid}"$'\t'"${score}"$'\t'"${mt}"$'\n'
        printf '%s\n' "$mt" >>"$MTIMES_TMP"
      done
    done <<EOF
$SEARCH_ROOTS
EOF
  fi
fi

# date → epoch helper
_date_to_epoch() {
  local d=$1
  date -u -d "${d} 00:00:00" +%s 2>/dev/null || \
    date -u -j -f "%Y-%m-%d %H:%M:%S" "${d} 00:00:00" +%s 2>/dev/null
}

# Bucket stats from TSV blob (score\tsid\n...). Output: mean\tn\tcomma_ids
# Data via env (not stdin) so callers can pipe freely.
_bucket_stats() {
  # $1 = blob of score\tsid lines
  BUCKET_BLOB=${1:-} python3 - <<'PY'
import os
rows = []
for line in (os.environ.get("BUCKET_BLOB") or "").splitlines():
    line = line.strip()
    if not line:
        continue
    parts = line.split("\t")
    if len(parts) < 2:
        continue
    try:
        s = float(parts[0])
    except Exception:
        continue
    sid = parts[1]
    rows.append((s, sid))
n = len(rows)
if n == 0:
    print("0\t0\t")
else:
    mean = sum(r[0] for r in rows) / n
    ids = ",".join(r[1] for r in rows)
    print(f"{mean:.4f}\t{n}\t{ids}")
PY
}

# Review each agent directives.md
for agent in $AGENTS; do
  dfile="$MROOT/.claude/memory/$agent/directives.md"
  [ -s "$dfile" ] || continue
  while IFS= read -r line || [ -n "$line" ]; do
    [ -z "$line" ] && continue
    # Only numbered directive lines
    case "$line" in
      [0-9]*|*[0-9].*) ;;
      *) continue ;;
    esac
    # parse trial meta — exit 1 if absent (plain permanent)
    parsed=$(bash "$META_SH" parse "$line" 2>/dev/null) || continue
    text=$(printf '%s' "$parsed" | cut -f1)
    start=$(printf '%s' "$parsed" | cut -f2)
    source=$(printf '%s' "$parsed" | cut -f3)
    review_after=$(printf '%s' "$parsed" | cut -f4)

    elapsed=$(bash "$META_SH" is-elapsed \
      --start "$start" \
      --review-after "$review_after" \
      --session-mtimes-file "$MTIMES_TMP" \
      --today "$TODAY" 2>/dev/null || echo false)
    if [ "$elapsed" != "true" ]; then
      echo "# trial-review: defer agent=$agent reason=window-not-elapsed start=$start review-after=$review_after" >&2
      continue
    fi

    start_epoch=$(_date_to_epoch "$start") || start_epoch=0

    # Split SCORES_TSV into baseline (mtime < start) and in-trial (mtime >= start)
    base_in=""
    trial_in=""
    while IFS= read -r srow || [ -n "$srow" ]; do
      [ -z "$srow" ] && continue
      sid=$(printf '%s' "$srow" | cut -f1)
      score=$(printf '%s' "$srow" | cut -f2)
      mt=$(printf '%s' "$srow" | cut -f3)
      case "$mt" in ''|*[!0-9]*) continue ;; esac
      if [ "$mt" -ge "$start_epoch" ]; then
        trial_in="${trial_in}${score}"$'\t'"${sid}"$'\n'
      else
        base_in="${base_in}${score}"$'\t'"${sid}"$'\n'
      fi
    done <<EOF
$SCORES_TSV
EOF

    bstats=$(_bucket_stats "$base_in")
    tstats=$(_bucket_stats "$trial_in")
    b_mean=$(printf '%s' "$bstats" | cut -f1)
    b_n=$(printf '%s' "$bstats" | cut -f2)
    b_ids=$(printf '%s' "$bstats" | cut -f3)
    t_mean=$(printf '%s' "$tstats" | cut -f1)
    t_n=$(printf '%s' "$tstats" | cut -f2)
    t_ids=$(printf '%s' "$tstats" | cut -f3)

    # D5: DEFER if either side n < 2
    if [ "${b_n:-0}" -lt 2 ] || [ "${t_n:-0}" -lt 2 ]; then
      echo "# trial-review: defer agent=$agent reason=insufficient-sample baseline_n=$b_n in_trial_n=$t_n directive=$(printf '%s' "$text" | cut -c1-60)" >&2
      continue
    fi

    # D5: mean(in_trial) < mean(baseline) → KEEP; else REVERT (ties → REVERT)
    action=$(python3 -c "import sys; b=float(sys.argv[1]); t=float(sys.argv[2]); print('KEEP' if t < b else 'REVERT')" "$b_mean" "$t_mean")

    # directive_text = stripped (no number? keep text as parse returned, strip number for adjust-agent)
    # Emit full parse text (includes "N. " prefix if present)
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$action" "$agent" "$text" "$source" "$start" \
      "$b_mean" "$b_n" "$t_mean" "$t_n" \
      "$b_ids" "$t_ids" "$review_after"
  done <"$dfile"
done

exit 0
