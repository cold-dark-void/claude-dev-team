#!/usr/bin/env bash
# ask.sh — advisor two-phase spawn seam (SPEC-039 T6 / epic child CDT-556-C4).
#
# THIS SCRIPT IS A SUBPROCESS CLI — NEVER SOURCE IT.
#
# Bash cannot spawn agents. The orchestrator (or any caller) runs:
#
#   bash skills/advisor/ask.sh probe \
#     --trigger a|b|c --question TEXT [--evidence-dir PATH]
#     [--run-id ID] [--epic-id ID] [--bc N]
#
#   probe NEVER spawns an agent. On action=spawn the CALLER spawns the advisor
#   Agent natively and then runs finalize. On action=cache-hit the caller reads
#   the cached ruling and spawns nothing. On refuse/cap the caller stops.
#
#   bash skills/advisor/ask.sh finalize --run-id ID \
#     ( --ruling-file PATH | --timeout | --spawn-fail | --refuse )
#
# probe stdout: exactly one JSON object
#   {"action":"spawn|cache-hit|refuse|cap",
#    "model":<string|null>,"spawn_request_path":<string|null>,
#    "cached_ruling_path":<string|null>,"reason":<string|null>}
# exit: 0 on any emitted action; 64 on usage errors or a re-entrant probe
#       (lock already held).
#
# State (all under $MROOT/.claude/advisor/, gitignored):
#   lock                                  flock target — re-entrant probe = 64
#   runs/<run_id>/spawn-request.json      written on spawn (probe)
#   runs/<run_id>/counters.json           per-run cap counters (M26)
#   runs/<run_id>/status.json             finalize --timeout/--spawn-fail/--refuse
#   runs/<run_id>/ruling.json             finalize --ruling-file copy
#   cache/<question_hash>.json            cached ruling (written by finalize only)
#   epic/<epic_id>/counters.json          epic-level total (default limit 8, M26)
#
# Caps (M26): per-trigger reserves a=3, b=4, c=2; global per-run total 5;
# ADVISOR_MAX_CALLS only lowers the global 5 (integer >= 1, else ignored);
# retries count; dedupe by question hash; cache hits are free and never
# increment caps. Cap exhaustion -> action=cap, no spawn (the CALLER maps
# unavailable-under-autopilot to BC8, M27 — this CLI only reports).
#
# Question hash: sha256 of trigger + normalized question (whitespace
# collapsed) + evidence-dir content hash (sorted rel paths + file sha256s).
# Same inputs -> same hash -> cache-hit; a changed evidence dir is a new
# question. finalize --timeout/--spawn-fail/--refuse never write the cache —
# a timeout is not a partial ruling (SPEC-039 T6 Verify).
#
# Model resolution (SPEC-039 M36/T6): resolve-model.sh --mapped advisor first;
# unmapped -> action=refuse, reason "advisor not configured" — never a tier
# default. resolve-model.sh advisor (plain) runs only when mapped.
#
# Card writes (SPEC-039 M28/M29/M30, C4 seam + C8 integration): finalize is
# the only place decision cards are written. With --ruling-file plus the
# card-context flags (all five of --card-workflow --card-ticket --card-gate
# --card-iteration --card-run-start-epoch), finalize applies the M29 decision
# map and writes the advisor card via skills/autopilot/append-card.sh
# --advisor-json (actor advisor, decided_by auto, bump null, rationale
# `trigger=<t> ruling=<r> model=<m>`); the M30 advisor object is written to
# runs/<run_id>/advisor-object.json and handed over as a file path. A card
# write failure exits 64 BEFORE the ruling is cached, so a retry re-spawns
# instead of silently losing the card. Without card context, finalize records
# outcomes under runs/<run_id>/ and the cache and writes no card. The BC8
# unavailable card is written by the CALLER under autopilot (M27 — this seam
# only reports; see skills/autopilot/self-answer.md §3g).

set -u

usage() {
  cat >&2 <<'EOF'
usage: ask.sh probe --trigger a|b|c --question TEXT [--evidence-dir PATH]
                    [--run-id ID] [--epic-id ID] [--bc N]
       ask.sh finalize --run-id ID (--ruling-file PATH | --timeout | --spawn-fail | --refuse)
                       [--card-workflow W --card-ticket T --card-gate G
                        --card-iteration N --card-run-start-epoch E]
EOF
  exit 64
}

die64() { echo "ask.sh: $1" >&2; exit 64; }

# require_nnint <label> <value> — AC9 pattern check (non-negative integer, no
# leading zero except literal 0, at most 15 digits) before any arithmetic.
# Defined before arg parsing: the finalize flag validation calls it there.
require_nnint() {
  case "$2" in
    0) return 0 ;;
    [1-9]*) ;;
    *) die64 "finalize: $1 must be a non-negative integer" ;;
  esac
  case "$2" in
    *[!0-9]*) die64 "finalize: $1 must be a non-negative integer" ;;
  esac
  [ "${#2}" -le 15 ] || die64 "finalize: $1 must be a non-negative integer (at most 15 digits)"
}

CMD="${1:-}"
[ -n "$CMD" ] || usage
shift

# ---- PDH (SPEC-002 canonical stanza; later-fence wrapper variant) -----------
PDH="${PDH:-$( { [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -f "$CLAUDE_PLUGIN_ROOT/skills/plugin-dir.sh" ] && printf '%s\n' "$CLAUDE_PLUGIN_ROOT"; } || { [ -f skills/plugin-dir.sh ] && [ -f agents/pm.md ] && grep -qF '"name": "dev-team"' .claude-plugin/plugin.json 2>/dev/null && pwd; } || { _pr='${CLAUDE_PLUGIN_ROOT}'; [ "${_pr#\$}" = "$_pr" ] && [ -f "$_pr/skills/plugin-dir.sh" ] && printf '%s\n' "$_pr"; } || { for _mp in "$HOME"/.claude/plugins/marketplaces/*/; do [ -f "${_mp}skills/plugin-dir.sh" ] && [ -f "${_mp}agents/pm.md" ] && grep -qF '"name": "dev-team"' "${_mp}.claude-plugin/plugin.json" 2>/dev/null && printf '%s\n' "${_mp%/}" && break; done; } || find ~/.claude/plugins/cache \( -path '*/dev-team/*/skills/plugin-dir.sh' -o -path '*/dev-team-edge/*/skills/plugin-dir.sh' \) 2>/dev/null | awk -F/ '{ver=""; for(i=1;i<=NF;i++) if(($i=="dev-team"||$i=="dev-team-edge")&&i<NF){ver=$(i+1);break}; if(ver=="") next; m=ver; gsub(/-pre\./,"~pre.",m); p=($0 ~ /\/cache\/cold-dark-void\/dev-team\//)?2:(($0 ~ /\/cache\/cold-dark-void\/dev-team-edge\//)?1:0); print m "\t" p "\t" $0}' | sort -t $'\t' -k1,1V -k2,2n -k3,3 | tail -1 | cut -f3 | xargs -r dirname | xargs -r dirname )}"

# ---- state root -------------------------------------------------------------
_gc=$(git rev-parse --git-common-dir 2>/dev/null) \
  && MROOT=$(cd "$(dirname "$_gc")" && pwd) \
  || MROOT=$(pwd)
# ADVISOR_STATE_ROOT reroutes the state root for tests (same pattern as
# INTERCOM_STATE_ROOT); production state lives under $MROOT/.claude/advisor/.
ADVISOR_DIR="${ADVISOR_STATE_ROOT:-$MROOT/.claude/advisor}"

TRIGGER="" QUESTION="" EVIDENCE_DIR="" RUN_ID="" EPIC_ID="" BC=""
RULING_FILE="" FIN_MODE=""
CARD_WORKFLOW="" CARD_TICKET="" CARD_GATE="" CARD_ITERATION="" CARD_RUN_START_EPOCH=""
case "$CMD" in
  probe)
    while [ $# -gt 0 ]; do
      case "$1" in
        --trigger) [ $# -ge 2 ] || usage; TRIGGER="$2"; shift 2 ;;
        --trigger=*) TRIGGER="${1#*=}"; shift ;;
        --question) [ $# -ge 2 ] || usage; QUESTION="$2"; shift 2 ;;
        --question=*) QUESTION="${1#*=}"; shift ;;
        --evidence-dir) [ $# -ge 2 ] || usage; EVIDENCE_DIR="$2"; shift 2 ;;
        --evidence-dir=*) EVIDENCE_DIR="${1#*=}"; shift ;;
        --run-id) [ $# -ge 2 ] || usage; RUN_ID="$2"; shift 2 ;;
        --run-id=*) RUN_ID="${1#*=}"; shift ;;
        --epic-id) [ $# -ge 2 ] || usage; EPIC_ID="$2"; shift 2 ;;
        --epic-id=*) EPIC_ID="${1#*=}"; shift ;;
        --bc) [ $# -ge 2 ] || usage; BC="$2"; shift 2 ;;
        --bc=*) BC="${1#*=}"; shift ;;
        *) usage ;;
      esac
    done
    [ -n "$TRIGGER" ] || usage
    case "$TRIGGER" in a|b|c) ;; *) die64 "probe: --trigger must be a|b|c" ;; esac
    [ -n "$QUESTION" ] || usage
    ;;
  finalize)
    while [ $# -gt 0 ]; do
      case "$1" in
        --run-id) [ $# -ge 2 ] || usage; RUN_ID="$2"; shift 2 ;;
        --run-id=*) RUN_ID="${1#*=}"; shift ;;
        --ruling-file) [ $# -ge 2 ] || usage; RULING_FILE="$2"; shift 2 ;;
        --ruling-file=*) RULING_FILE="${1#*=}"; shift ;;
        --timeout) FIN_MODE="timeout"; shift ;;
        --spawn-fail) FIN_MODE="spawn-fail"; shift ;;
        --refuse) FIN_MODE="refuse"; shift ;;
        --card-workflow) [ $# -ge 2 ] || usage; CARD_WORKFLOW="$2"; shift 2 ;;
        --card-workflow=*) CARD_WORKFLOW="${1#*=}"; shift ;;
        --card-ticket) [ $# -ge 2 ] || usage; CARD_TICKET="$2"; shift 2 ;;
        --card-ticket=*) CARD_TICKET="${1#*=}"; shift ;;
        --card-gate) [ $# -ge 2 ] || usage; CARD_GATE="$2"; shift 2 ;;
        --card-gate=*) CARD_GATE="${1#*=}"; shift ;;
        --card-iteration) [ $# -ge 2 ] || usage; CARD_ITERATION="$2"; shift 2 ;;
        --card-iteration=*) CARD_ITERATION="${1#*=}"; shift ;;
        --card-run-start-epoch) [ $# -ge 2 ] || usage; CARD_RUN_START_EPOCH="$2"; shift 2 ;;
        --card-run-start-epoch=*) CARD_RUN_START_EPOCH="${1#*=}"; shift ;;
        *) usage ;;
      esac
    done
    [ -n "$RUN_ID" ] || usage
    MODES=0
    [ -n "$RULING_FILE" ] && MODES=$((MODES + 1))
    [ -n "$FIN_MODE" ] && MODES=$((MODES + 1))
    [ "$MODES" -eq 1 ] || die64 "finalize: exactly one of --ruling-file | --timeout | --spawn-fail | --refuse"
    # Card context (CDT-565 / M28-M30): all five flags or none. Only a ruling
    # finalize writes a card; a status finalize (--timeout etc.) never does
    # (the CALLER maps unavailable-under-autopilot to BC8, M27).
    CARD_CTX=0
    for _cv in "$CARD_WORKFLOW" "$CARD_TICKET" "$CARD_GATE" "$CARD_ITERATION" "$CARD_RUN_START_EPOCH"; do
      [ -n "$_cv" ] && CARD_CTX=$((CARD_CTX + 1))
    done
    if [ "$CARD_CTX" -ne 0 ] && [ "$CARD_CTX" -ne 5 ]; then
      die64 "finalize: card writing requires all of --card-workflow --card-ticket --card-gate --card-iteration --card-run-start-epoch"
    fi
    if [ "$CARD_CTX" -eq 5 ] && [ -n "$FIN_MODE" ]; then
      die64 "finalize: card context applies only to --ruling-file finalize"
    fi
    if [ "$CARD_CTX" -eq 5 ]; then
      require_nnint "--card-iteration" "$CARD_ITERATION"
      require_nnint "--card-run-start-epoch" "$CARD_RUN_START_EPOCH"
    fi
    ;;
  *) usage ;;
esac

mkdir -m 700 -p "$ADVISOR_DIR" 2>/dev/null || mkdir -p "$ADVISOR_DIR"
touch "$ADVISOR_DIR/lock"

# ---- helpers ----------------------------------------------------------------

emit() { # emit <action> <model> <spawn_request_path> <cached_ruling_path> <reason>
  jq -cn --arg action "$1" --arg model "${2:-}" --arg srp "${3:-}" \
         --arg crp "${4:-}" --arg reason "${5:-}" \
    '{action:$action,
      model:(if $model=="" then null else $model end),
      spawn_request_path:(if $srp=="" then null else $srp end),
      cached_ruling_path:(if $crp=="" then null else $crp end),
      reason:(if $reason=="" then null else $reason end)}'
}

# normalized question: trim + collapse all whitespace runs to single spaces
norm_question() { printf '%s' "$1" | tr -s '[:space:]' ' ' | sed -e 's/^ //' -e 's/ $//'; }

# evidence content hash: sha256 over sorted "relpath sha256(file)" lines
evidence_hash() {
  local dir="$1"
  if [ -z "$dir" ] || [ ! -d "$dir" ]; then printf 'none' | sha256sum | cut -d" " -f1; return; fi
  ( cd "$dir" && find . -type f ! -name '.*' -print0 2>/dev/null | sort -z \
      | xargs -0 -r sha256sum ) | sha256sum | cut -d" " -f1
}

question_hash() { # question_hash <trigger> <question> <evidence_dir>
  local eh
  eh=$(evidence_hash "$3")
  printf '%s' "$1|$2|$eh" | sha256sum | cut -d" " -f1
}

json_get() { jq -r "$2 // empty" "$1" 2>/dev/null; }

# ---- finalize ---------------------------------------------------------------
if [ "$CMD" = "finalize" ]; then
  RUN_DIR="$ADVISOR_DIR/runs/$RUN_ID"
  SRP="$RUN_DIR/spawn-request.json"
  [ -f "$SRP" ] || die64 "finalize: no spawn-request for run $RUN_ID (probe first)"
  HASH=$(json_get "$SRP" ".question_hash")
  [ -n "$HASH" ] || die64 "finalize: spawn-request missing question_hash"

  (
    exec 9>>"$ADVISOR_DIR/lock" || die64 "finalize: cannot open advisor lock"
    flock -w 10 9 || die64 "finalize: could not acquire advisor lock"
    if [ -n "$FIN_MODE" ]; then
      # --timeout/--spawn-fail/--refuse record status only; never the cache
      # (a timeout is not a partial ruling — SPEC-039 T6 Verify).
      jq -cn --arg s "$FIN_MODE" --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        '{status:$s, ts:$ts}' > "$RUN_DIR/status.json"
      exit 0
    fi
    [ -f "$RULING_FILE" ] || die64 "finalize: ruling file not found: $RULING_FILE"
    RULING=$(json_get "$RULING_FILE" ".ruling")
    case "$RULING" in
      AGREE|CONTRADICT|INSUFFICIENT) ;;
      *) die64 "finalize: ruling must be AGREE|CONTRADICT|INSUFFICIENT (got '$RULING')" ;;
    esac
    CONF=$(json_get "$RULING_FILE" ".confidence")
    case "$CONF" in
      ''|*[!0-9]*) die64 "finalize: confidence must be an integer 0-100" ;;
    esac
    [ "$CONF" -ge 0 ] && [ "$CONF" -le 100 ] || die64 "finalize: confidence must be an integer 0-100"
    BAD=$(jq -r '[.evidence[]? | select((.locator // "") | test("^[^[:space:]]+:[0-9]+$") | not)] | length' "$RULING_FILE" 2>/dev/null)
    [ "$BAD" = "0" ] || die64 "finalize: evidence[].locator must be path:line (M18)"
    # M18: a ruling must carry at least one evidence item — .evidence[]? on a
    # missing/empty array would pass vacuously and cache an evidence-free ruling.
    NEV=$(jq -r '(.evidence // []) | length' "$RULING_FILE" 2>/dev/null)
    case "$NEV" in ''|*[!0-9]*|0) die64 "finalize: evidence[] must be a non-empty array (M18)" ;; esac
    if [ "$CARD_CTX" -eq 5 ]; then
      # M29 decision map: AGREE + confidence >= 80 -> proceed/null; CONTRADICT
      # or INSUFFICIENT, or confidence < 80 regardless of ruling, -> halt/BC7.
      # M29 says the card confidence is the ruling's 0-100, but append-card
      # cross-field invariant (b) (SPEC-033 M13) hard-rejects a BC7 card with
      # confidence >= 80 — a high-confidence CONTRADICT/INSUFFICIENT (the C4
      # fixture itself rules CONTRADICT at 92) would be unwritable. Fail closed
      # to 0 there, the M14(b) CONTRADICTED->BC7->confidence-0 precedent.
      case "$RULING" in
        AGREE)
          if [ "$CONF" -ge 80 ]; then CARD_DECISION="proceed"; CARD_BC="null"; CARD_CONF="$CONF"
          else CARD_DECISION="halt"; CARD_BC="7"; CARD_CONF="$CONF"; fi ;;
        *)
          CARD_DECISION="halt"; CARD_BC="7"
          if [ "$CONF" -ge 80 ]; then CARD_CONF=0; else CARD_CONF="$CONF"; fi ;;
      esac
      SRP_MODEL=$(json_get "$SRP" ".model"); SRP_MODEL=${SRP_MODEL:-}
      SRP_TRIGGER=$(json_get "$SRP" ".trigger"); SRP_TRIGGER=${SRP_TRIGGER:-}
      # wall_clock_s measured at write time via budget-check.sh argc=2 (the
      # self-answer §3f C5 discipline); a breach (6) is an outcome — only a
      # validation failure (64) aborts the card.
      BUDGET_CHECK=$(bash "$PDH/skills/plugin-dir.sh" file skills/autopilot/budget-check.sh)
      BC_RC=0
      BC_OUT=$(bash "$BUDGET_CHECK" "$CARD_ITERATION" "$CARD_RUN_START_EPOCH" 2>/dev/null)
      BC_RC=$?
      # CDT-568 fix: $? after `!` is always 0 - capture the raw rc instead.
      if [ "$BC_RC" != 0 ] && [ "$BC_RC" != 6 ]; then
        die64 "finalize: budget-check.sh failed (rc $BC_RC) — no decision card written"
      fi
      WALL_CLOCK_S=$(printf '%s' "$BC_OUT" | jq -r '.wall_clock_s')
      # The advisor object rides on disk (M30: argv/file-path only, never
      # embedded in shell interpolation) and stays as the run's audit artifact.
      ADVISOR_OBJ="$RUN_DIR/advisor-object.json"
      jq -cn --slurpfile r "$RULING_FILE" \
        --arg model "$SRP_MODEL" --arg qhash "$HASH" --arg trigger "$SRP_TRIGGER" \
        '{ruling: $r[0].ruling,
          corrected_claim: ($r[0].corrected_claim // null),
          evidence: ($r[0].evidence),
          model: $model,
          evidence_over_memory: (if ($r[0] | has("evidence_over_memory")) and ($r[0].evidence_over_memory | type == "boolean") then $r[0].evidence_over_memory else true end),
          question_hash: $qhash,
          trigger: $trigger,
          cache_hit: false,
          timeout: false,
          marker: null}' > "$ADVISOR_OBJ" \
        || die64 "finalize: cannot write the advisor object to $ADVISOR_OBJ"
      RATIONALE="trigger=$SRP_TRIGGER ruling=$RULING model=$SRP_MODEL"
      APPEND_CARD=$(bash "$PDH/skills/plugin-dir.sh" file skills/autopilot/append-card.sh)
      bash "$APPEND_CARD" "$CARD_WORKFLOW" "$CARD_TICKET" "$CARD_GATE" \
        "$CARD_DECISION" auto null "$CARD_CONF" "$CARD_BC" "$RUN_ID" \
        "$CARD_ITERATION" "$WALL_CLOCK_S" advisor "$RATIONALE" \
        --advisor-json "$ADVISOR_OBJ" \
        || die64 "finalize: append-card.sh rejected the decision card — ruling not cached"
    fi
    jq -cn --arg hash "$HASH" --arg run_id "$RUN_ID" --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        --slurpfile ruling "$RULING_FILE" \
      '{question_hash:$hash, run_id:$run_id, ts:$ts, ruling:$ruling[0]}' \
      > "$ADVISOR_DIR/cache/$HASH.json"
    cp "$RULING_FILE" "$RUN_DIR/ruling.json"
    jq -cn --arg s "ruled" --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      '{status:$s, ts:$ts}' > "$RUN_DIR/status.json"
  ) || exit $?
  exit 0
fi

# ---- probe ------------------------------------------------------------------

# Re-entrant probe: the advisor lock is already held -> 64 (T6). The fd is
# held for the probe's lifetime, so a concurrent probe fails to acquire.
exec 9>>"$ADVISOR_DIR/lock" || die64 "probe: cannot open advisor lock"
flock -n 9 || die64 "probe: advisor lock held — probe already in progress"

# Model resolution (M36/T6): mapped probe first; never a tier default.
RESOLVE=$(bash "$PDH/skills/plugin-dir.sh" file skills/model-map/resolve-model.sh)
if [ "$(bash "$RESOLVE" --mapped advisor)" != "mapped" ]; then
  emit refuse "" "" "" "advisor not configured"
  exit 0
fi
MODEL=$(bash "$RESOLVE" advisor)

HASH=$(question_hash "$TRIGGER" "$(norm_question "$QUESTION")" "$EVIDENCE_DIR")

mkdir -p "$ADVISOR_DIR/cache" "$ADVISOR_DIR/runs"

# Cache: same question hash -> free ruling, no spawn, no cap increment (M26).
CACHED="$ADVISOR_DIR/cache/$HASH.json"
if [ -f "$CACHED" ]; then
  emit cache-hit "$MODEL" "" "$CACHED" ""
  exit 0
fi

RUN_ID="${RUN_ID:-advisor-$(date -u +%Y%m%dT%H%M%SZ)-$HASH}"
RUN_DIR="$ADVISOR_DIR/runs/$RUN_ID"
mkdir -p "$RUN_DIR"

# Caps (M26): per-trigger reserves (a)=3 (b)=4 (c)=2; global per-run 5;
# ADVISOR_MAX_CALLS only lowers the global (integer >= 1, else ignored).
GLOBAL_LIMIT=5
case "${ADVISOR_MAX_CALLS:-}" in
  ''|*[!0-9]*) : ;;
  *) [ "${ADVISOR_MAX_CALLS}" -ge 1 ] && [ "${ADVISOR_MAX_CALLS}" -lt "$GLOBAL_LIMIT" ] && GLOBAL_LIMIT="${ADVISOR_MAX_CALLS}" ;;
esac
case "$TRIGGER" in a) RESERVE=3 ;; b) RESERVE=4 ;; c) RESERVE=2 ;; esac

COUNTERS="$RUN_DIR/counters.json"
[ -f "$COUNTERS" ] || echo '{"a":0,"b":0,"c":0,"total":0}' > "$COUNTERS"
CNT_A=$(json_get "$COUNTERS" ".a"); CNT_A=${CNT_A:-0}
CNT_B=$(json_get "$COUNTERS" ".b"); CNT_B=${CNT_B:-0}
CNT_C=$(json_get "$COUNTERS" ".c"); CNT_C=${CNT_C:-0}
CNT_T=$(json_get "$COUNTERS" ".total"); CNT_T=${CNT_T:-0}

cap_reason=""
case "$TRIGGER" in
  a) [ "$CNT_A" -ge "$RESERVE" ] && cap_reason="trigger a reserve exhausted (3)" ;;
  b) [ "$CNT_B" -ge "$RESERVE" ] && cap_reason="trigger b reserve exhausted (4)" ;;
  c) [ "$CNT_C" -ge "$RESERVE" ] && cap_reason="trigger c reserve exhausted (2)" ;;
esac
if [ -z "$cap_reason" ] && [ "$CNT_T" -ge "$GLOBAL_LIMIT" ]; then
  cap_reason="global per-run cap exhausted ($GLOBAL_LIMIT)"
fi

# Epic-level total (M26): default limit 8, stored under
# .claude/advisor/epic/<epic_id>/counters.json.
if [ -z "$cap_reason" ] && [ -n "$EPIC_ID" ]; then
  EPIC_DIR="$ADVISOR_DIR/epic/$EPIC_ID"
  mkdir -p "$EPIC_DIR"
  EPIC_COUNTERS="$EPIC_DIR/counters.json"
  [ -f "$EPIC_COUNTERS" ] || echo '{"total":0}' > "$EPIC_COUNTERS"
  EPIC_CNT=$(json_get "$EPIC_COUNTERS" ".total"); EPIC_CNT=${EPIC_CNT:-0}
  if [ "$EPIC_CNT" -ge 8 ]; then
    cap_reason="epic total cap exhausted (8)"
  else
    jq --argjson v "$((EPIC_CNT + 1))" '.total = $v' "$EPIC_COUNTERS" > "$EPIC_COUNTERS.tmp" \
      && mv "$EPIC_COUNTERS.tmp" "$EPIC_COUNTERS"
  fi
fi

if [ -n "$cap_reason" ]; then
  emit cap "" "" "" "$cap_reason"
  exit 0
fi

# Increment (retries count; cache hits never reach here).
jq --argjson a "$((CNT_A + 1))" --argjson b "$((CNT_B + 1))" \
   --argjson c "$((CNT_C + 1))" --argjson t "$((CNT_T + 1))" \
   '.a=$a | .b=$b | .c=$c | .total=$t' "$COUNTERS" > "$COUNTERS.tmp" \
  && mv "$COUNTERS.tmp" "$COUNTERS"

# Spawn request for the CALLER to act on — probe itself never spawns.
SRP="$RUN_DIR/spawn-request.json"
jq -cn --arg run_id "$RUN_ID" --arg trigger "$TRIGGER" --arg question "$QUESTION" \
       --arg hash "$HASH" --arg model "$MODEL" --arg evidence "${EVIDENCE_DIR:-}" \
       --arg bc "${BC:-}" --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  '{run_id:$run_id, trigger:$trigger, question:$question, question_hash:$hash,
    model:$model, evidence_dir:(if $evidence=="" then null else $evidence end),
    bc:(if $bc=="" then null else $bc end), ts:$ts, status:"awaiting-spawn"}' > "$SRP"

emit spawn "$MODEL" "$SRP" "" ""
exit 0
