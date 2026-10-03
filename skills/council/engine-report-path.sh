# council/engine-report-path.sh — resolve-task-id + report-path + m14-check, sourced by engine.sh (L-10).

# ---- resolve-task-id --------------------------------------------------------
# Fallback: --task-id flag → CLAUDE_TASK_ID env → empty. Never errors.
cmd_resolve_task_id() {
  local tid=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --task-id) need_val "$1" $#; tid="$2"; shift 2 ;;
      *) shift ;;
    esac
  done
  if [ -z "$tid" ]; then
    tid="${CLAUDE_TASK_ID:-}"
  fi
  printf '%s\n' "$tid"
}

# ---- path-safe validation ----------------------------------------------------
# Reject any value containing path traversal characters.
validate_path_component() {
  local label="$1" value="$2"
  # ".." matches the character class; reject it so a slug or task-id cannot
  # walk out of .claude/council. "/" already fails the class.
  if [[ "$value" == *..* ]] || [[ "$value" == */* ]] || ! [[ "$value" =~ ^[a-zA-Z0-9._-]+$ ]]; then
    echo "engine.sh: invalid $label: must match [a-zA-Z0-9._-]+" >&2
    exit 2
  fi
}

# ---- report-path ------------------------------------------------------------
# $MROOT/.claude/council/<YYYY-MM-DD>-<slug>[--<task_id>][-<N>].md
#
# Report no-overwrite (SPEC-013 Phase 6, WP 1-14). A candidate is free iff
# BOTH the report file and its `.finalize-meta.json` sidecar are absent. The
# base candidate (no `-<N>`) is tried first; on a collision `-2` .. `-99` are
# tried in filename order. `-<N>` sits directly before `.md`, after the
# task-id suffix.
#
# _report_path_candidate/_report_path_free are pure helpers shared by the
# read-only probe (cmd_report_path, used by preflight and the `report-path`
# subcommand — reserves nothing) and the write-time reservation
# (finalize_reserve_report_path, used by finalize only).
_report_path_candidate() {  # <slug> <task-id|""> <date> <n (1..99)>
  local slug="$1" tid="$2" date="$3" n="$4"
  local suffix="" nsuf=""
  [ -n "$tid" ] && suffix="--${tid}"
  [ "$n" -gt 1 ] && nsuf="-${n}"
  printf '%s/%s-%s%s%s.md\n' "$COUNCIL_DIR" "$date" "$slug" "$suffix" "$nsuf"
}

_report_path_free() {  # <candidate report path>
  [ ! -e "$1" ] && [ ! -e "${1}.finalize-meta.json" ]
}

# Scans candidates 1..99 for <slug>/<tid>/<date>, calling <pred-fn> on each
# one. Prints the first candidate <pred-fn> accepts and returns 0. Returns 9
# (no stdout) once every candidate up to -99 is rejected. Shared by the
# read-only probe (_report_path_free) and the write-time reservation
# (_report_path_try_reserve) — same scan order, different predicate (tech-lead
# review r1, B5: was two copies of this loop).
_report_path_scan() {  # <pred-fn> <slug> <tid> <date>
  local pred="$1" slug="$2" tid="$3" date="$4"
  local n cand
  for n in {1..99}; do
    cand=$(_report_path_candidate "$slug" "$tid" "$date" "$n")
    if "$pred" "$cand"; then
      printf '%s\n' "$cand"
      return 0
    fi
  done
  return 9
}

# Probe only — never creates anything. Returns the first free candidate.
cmd_report_path() {
  if [ $# -lt 1 ]; then
    echo "engine.sh: report-path requires <slug>" >&2
    exit 2
  fi
  local slug="$1"; shift
  validate_path_component "slug" "$slug"
  local tid=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --task-id) need_val "$1" $#; tid="$2"; shift 2 ;;
      *) shift ;;
    esac
  done
  if [ -n "$tid" ]; then
    validate_path_component "task-id" "$tid"
  fi
  local date
  date=$(date -u +%Y-%m-%d)  # UTC per SKILL.md report-path contract
  if _report_path_scan _report_path_free "$slug" "$tid" "$date"; then
    return 0
  fi
  echo "engine.sh: report-path: every candidate up to -99 is taken for slug '$slug' (report no-overwrite, SPEC-013 Phase 6)" >&2
  exit 9
}

# ---- report-path reservation (finalize write-time only) ---------------------
# Sequential exclusive creates of the report file then its sidecar — NOT a
# single atomic transaction over the pair (WP 1-14 plan-review finding: bash
# has no cross-file atomic create; "atomic as a pair" was struck as
# unimplementable). Each attempt is two O_EXCL creates (bash `noclobber`)
# with a rollback of the first placeholder when the second create fails.
_report_path_try_reserve() {  # <candidate report path>
  local report="$1" meta="${1}.finalize-meta.json"
  if ( set -C; : > "$report" ) 2>/dev/null; then
    if ( set -C; : > "$meta" ) 2>/dev/null; then
      return 0
    fi
    rm -f -- "$report"
    return 1
  fi
  return 1
}

# Reserves a report path at finalize write time. Tries $3 (plan.report_path,
# already task-id-adjusted by the caller) first; if that candidate is taken,
# scans base .. -99 at TODAY's UTC date (the finalize date, which may differ
# from the plan's original preflight date). Prints the reserved path and
# returns 0. Returns 9 (no stdout) once every candidate up to -99 is taken —
# the caller MUST exit 9 and write no report.
finalize_reserve_report_path() {  # <slug> <task-id|""> <preferred path>
  local slug="$1" tid="$2" preferred="$3"
  mkdir -p "$COUNCIL_DIR"
  if [ -n "$preferred" ] && _report_path_try_reserve "$preferred"; then
    printf '%s\n' "$preferred"
    return 0
  fi
  local date
  date=$(date -u +%Y-%m-%d)
  _report_path_scan _report_path_try_reserve "$slug" "$tid" "$date"
}

# ---- m14_check ---------------------------------------------------------
# Shared implementation of the SPEC-033 M14(g)/(j) split + budget check
# (WP 1-14 review round 2, B-2). ONE function backs both cmd_preflight's
# M14 trigger (in-process call) and the "m14-check" subcommand (direct CLI
# use, e.g. skills/orchestrate/steps/10-qa.md Step 10b) -- never a copy of
# the constant or the ceiling/budget arithmetic.
#
# $1 = ticket_id, $2 = ac_source (path, worktree-relative). On the M14(j)
# ceiling guard or m14-ac-split.sh's case 9 (the claim budget) this prints
# exactly one "m14-ac-split: <cause>" stderr line and exits 8, matching
# m14-ac-split.sh's own case 1-8 contract (C1) so every caller sees one
# uniform failure shape. m14-ac-split.sh's own exit (8 for cases 1-8, 64
# for its argv misuse) propagates unchanged. On success this prints the
# split JSON from m14-ac-split.sh to stdout, unmodified, and returns 0.
m14_check() {
  local ticket_id="$1" ac_source="$2"
  # M14(j): a budget above the ceiling fails every M14 split closed,
  # independent of the actual technical AC count (config-validity guard;
  # unreachable with the constants above, but must fail closed if a
  # future committed change ever violates it).
  if [ "$M14_AC_BUDGET" -gt "$M14_AC_BUDGET_CEILING" ]; then
    echo "m14-ac-split: M14_AC_BUDGET ($M14_AC_BUDGET) exceeds M14_AC_BUDGET_CEILING ($M14_AC_BUDGET_CEILING) -- every M14 split fails closed (SPEC-033 M14(j))" >&2
    exit 8
  fi
  local split_json
  split_json=$(bash "$M14_AC_SPLIT" "$ticket_id" "$ac_source") || exit $?
  local technical_count
  technical_count=$(printf '%s' "$split_json" | jq '[.acs[] | select(.process == false)] | length')
  if [ "$technical_count" -gt "$M14_AC_BUDGET" ]; then
    local over_ids
    over_ids=$(printf '%s' "$split_json" | jq -r --argjson b "$M14_AC_BUDGET" \
      '[.acs[] | select(.process == false)] | .[$b:] | map(.id) | join(", ")')
    echo "m14-ac-split: case 9: technical AC count ($technical_count) exceeds the M14 claim budget ($M14_AC_BUDGET); ids beyond budget: $over_ids" >&2
    exit 8
  fi
  printf '%s\n' "$split_json"
}

# ---- m14-check subcommand ----------------------------------------------
# CLI entry point for m14_check. Argv misuse (wrong arg count) exits 64,
# matching m14-ac-split.sh's own argv-misuse code (C1).
cmd_m14_check() {
  if [ $# -ne 2 ]; then
    echo "engine.sh: usage: engine.sh m14-check <ticket_id> <spec-file>" >&2
    exit 64
  fi
  m14_check "$1" "$2"
}

