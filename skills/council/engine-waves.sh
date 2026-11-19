# council/engine-waves.sh — cmd_waves, sourced by engine.sh (CDT-594).
# SPEC-013 § Spawn concurrency cap → waves[] — the post-Phase-1 emitter and the
# blind-form emitter. The slot/partition/merge arithmetic lives in
# skills/council/waves-lib.sh; nothing is re-derived here.

# waves_fail <message> — the emitter's single fail-closed path: stderr + usage +
# exit 64 (SPEC-013 AC7). Callers reach it before any write, so the plan file
# stays byte-unchanged.
waves_fail() {
  echo "engine.sh: waves: $1" >&2
  usage
  exit 64
}

# waves_need_val <flag> <$#> — value flags on this subcommand fail closed 64,
# not 2: every bad input to the emitter is its documented exit code.
waves_need_val() {
  [ "$2" -ge 2 ] || waves_fail "$1 needs a value"
}

# waves_is_cap <value> — a cap is a positive decimal integer, no sign, no
# leading zeros, no spaces.
waves_is_cap() {
  case "$1" in
    '' | *[!0-9]*) return 1 ;;
  esac
  case "$1" in
    [1-9]*) return 0 ;;
    *) return 1 ;;
  esac
}

# waves_resolve_blind_cap <flag-value|''> <given:true|false> — print the cap
# (empty = unbounded). The blind path runs no preflight, so this form resolves
# its own cap through the ONE merge helper, skills/model-map/resolve-concurrency.sh
# (SPEC-013 AC9); it reads no env and no Model map layer here. The plan-file
# form never calls this — it reads plan.concurrency only (AC6).
# A missing helper is 64: a broken install must not fall through to unbounded.
waves_resolve_blind_cap() {
  local value="$1" given="$2"
  local helper="$SCRIPT_DIR/../model-map/resolve-concurrency.sh"
  local cap="" rc=0
  if [ ! -f "$helper" ]; then
    waves_fail "resolve-concurrency.sh not found at $helper — failing closed"
  fi
  if [ "$given" = "true" ]; then
    cap=$(bash "$helper" --flag "$value") || rc=$?
  else
    cap=$(bash "$helper") || rc=$?
  fi
  if [ "$rc" -ne 0 ]; then
    waves_fail "spawn concurrency cap rejected (exit $rc) — nothing emitted (SPEC-013 CDT-573)"
  fi
  printf '%s\n' "$cap"
}

# waves_validate_claims <claims-file> — the claim records arrive as a JSON-array
# FILE path (never inline text, never stdin-as-code: AGENTS.md untrusted-input
# rule). Fail closed 64 on a missing/unreadable file, a file that is not valid
# JSON, an array that is not a JSON array, an empty array, a non-object record,
# and a claim_id that is neither null nor a string (a slot's claim_id must be a
# string, so a numeric id would key the Phase 2.5 / finalize groups wrong).
waves_validate_claims() {
  local file="$1" shape
  if [ ! -f "$file" ] || [ ! -r "$file" ]; then
    waves_fail "claims file not found or not readable: $file"
  fi
  if ! jq -e . "$file" >/dev/null 2>&1; then
    waves_fail "claims file is not valid JSON: $file"
  fi
  shape=$(jq -r '
    if (type != "array") then "not-array"
    elif (length == 0) then "empty"
    elif (any(.[]; type != "object")) then "record-not-object"
    elif (any(.[]; has("claim_id") and ((.claim_id | type) != "string") and (.claim_id != null))) then "claim-id-type"
    else "ok" end' "$file")
  case "$shape" in
    ok) ;;
    not-array)  waves_fail "claims file is not a JSON array: $file" ;;
    empty)      waves_fail "claims file holds an empty claims array: $file" ;;
    *)          waves_fail "claims file holds an unusable claim record ($shape): $file" ;;
  esac
}

# ---- waves ------------------------------------------------------------------
# cmd_waves — the waves[] emitter. Two forms, one subcommand:
#
#   waves --plan-file P --claims-file C   post-Phase-1: fills the phase2 +
#     phase2.5 waves from plan.flavors and the claim records, reads the cap
#     from plan.concurrency ONLY, merges the wave objects into the plan file
#     through atomic_write (tmp + rename), drops the emitted names from
#     plan.waves_pending, and prints the plan's merged waves[] on stdout
#     (compact, one line — the phase2/phase2.5 objects first in wave order).
#
#   waves --blind --teams N --lenses L1,L2[,…]
#     the blind path has no plan file: it writes NOTHING and prints the
#     partitioned blind wave. Cap through the merge helper.
#
# Zero side effects on every fail-closed path (exit 64). Subprocess CLI.
cmd_waves() {
  require_jq

  local plan_file="" claims_file="" blind="false" teams="" lenses=""
  local conc="" conc_given="false"

  while [ $# -gt 0 ]; do
    case "$1" in
      --plan-file)   waves_need_val "$1" $#; plan_file="$2"; shift 2 ;;
      --claims-file) waves_need_val "$1" $#; claims_file="$2"; shift 2 ;;
      --blind)       blind="true"; shift ;;
      --teams)       waves_need_val "$1" $#; teams="$2"; shift 2 ;;
      --lenses)      waves_need_val "$1" $#; lenses="$2"; shift 2 ;;
      --concurrency)  waves_need_val "$1" $#; conc="$2"; conc_given="true"; shift 2 ;;
      --concurrency=*) conc="${1#--concurrency=}"; conc_given="true"; shift ;;
      *) waves_fail "unknown flag: $1" ;;
    esac
  done

  if [ "$blind" = "true" ]; then
    if [ -n "$plan_file" ] || [ -n "$claims_file" ]; then
      waves_fail "--blind takes no --plan-file/--claims-file (no plan exists on that path)"
    fi
    cmd_waves_blind "$teams" "$lenses" "$conc" "$conc_given"
    return 0
  fi

  if [ -n "$teams" ] || [ -n "$lenses" ]; then
    waves_fail "--teams/--lenses apply to --blind only"
  fi
  # AC6: this form resolves no cap layer of its own — the plan is the carrier.
  if [ "$conc_given" = "true" ]; then
    waves_fail "--concurrency is not read here — the plan-file form reads plan.concurrency only"
  fi
  [ -n "$plan_file" ]   || waves_fail "--plan-file is required"
  [ -n "$claims_file" ] || waves_fail "--claims-file is required"

  if [ ! -f "$plan_file" ] || [ ! -r "$plan_file" ]; then
    waves_fail "plan file not found or not readable: $plan_file"
  fi
  if ! jq -e . "$plan_file" >/dev/null 2>&1; then
    waves_fail "plan file is not valid JSON: $plan_file"
  fi
  if ! jq -e '(.concurrency | type) == "number" and .concurrency >= 1' "$plan_file" >/dev/null 2>&1; then
    waves_fail "plan carries no spawn concurrency cap (plan.concurrency) — nothing written: $plan_file"
  fi
  if ! jq -e '(.flavors | type) == "array" and (.flavors | length) > 0
              and (.flavors | all(.[]; type == "string"))' \
       "$plan_file" >/dev/null 2>&1; then
    waves_fail "plan carries no usable flavors[] array — nothing written: $plan_file"
  fi
  waves_validate_claims "$claims_file"

  local cap_json slots2 slots25 waves merged
  # The plan file is this run's own TMPDIR document (single writer): it is
  # read, merged in memory, then renamed into place. No lock — a concurrent
  # writer of the same plan file is a caller bug, and the rename keeps the
  # file whole either way.
  cap_json=$(jq -c '.concurrency' "$plan_file")
  slots2=$(waves_slots_phase2 "$plan_file" "$claims_file")
  slots25=$(waves_slots_phase25 "$plan_file" "$claims_file")
  waves=$(waves_append \
    "$(waves_partition phase2 "$cap_json" "$slots2")" \
    "$(waves_partition "phase2.5" "$cap_json" "$slots25")")
  [ "$(jq -r 'length' <<<"$waves")" != "0" ] \
    || waves_fail "emitted wave set is empty — nothing written: $plan_file"

  merged=$(waves_merge_plan "$(jq -c '.' "$plan_file")" "$waves")
  # atomic_write (skills/lib/portable.sh, sourced at the point of use so the
  # fail-closed paths above never load it): the producer writes a temp file
  # beside the plan and it is renamed onto the plan only on success, so a
  # failed producer leaves the plan byte-unchanged (AC7).
  . "$SCRIPT_DIR/../lib/portable.sh"
  atomic_write "$plan_file" printf '%s\n' "$merged" \
    || waves_fail "failed to write the merged plan file: $plan_file"

  # stdout == plan.waves, byte for byte (compact): the fences iterate this and
  # the plan file cannot drift from it.
  jq -c '.waves' "$plan_file"
}

# cmd_waves_blind <teams> <lenses> <flag-value> <given:true|false> — the
# `--blind` wave: N unconstrained reviewers (U1..UN) + M lens reviewers
# (L-<lens>), one wave, partitioned by the resolved cap. Writes nothing.
cmd_waves_blind() {
  local teams="$1" lenses="$2" conc="$3" conc_given="$4"
  [ -n "$teams" ] || teams="3"
  [ -n "$lenses" ] || lenses="security,contributor,spec"

  waves_is_cap "$teams" || waves_fail "--teams needs an integer >= 1 (got: $teams)"
  case ",$lenses," in
    *",,"*) waves_fail "--lenses needs comma-separated non-empty lens names (got: $lenses)" ;;
  esac
  # Lens NAME validity is commands/council.md Step 1's hard fail; this emitter
  # partitions whatever names it is given and invents no lens list of its own.

  local cap cap_json="null" slots
  cap=$(waves_resolve_blind_cap "$conc" "$conc_given")
  if [ -n "$cap" ]; then
    cap_json="$cap"
  fi
  slots=$(waves_slots_blind "$teams" "$lenses")
  waves_partition blind "$cap_json" "$slots"
}
