#!/usr/bin/env bash
# gates.sh — trigger-(a) restricted gate + shadow recorder (SPEC-039 M23/M24/M25,
# epic child CDT-563-C7).
#
# THIS SCRIPT IS A SUBPROCESS CLI — NEVER SOURCE IT. It is deterministic:
# no LLM call, no spawn, no network, no advisor invocation.
#
#   bash skills/advisor/gates.sh allow  --bc <gate-id>
#   bash skills/advisor/gates.sh ruling --bc <gate-id> --ruling <ruling>
#   bash skills/advisor/gates.sh shadow --run-id ID --bc <gate-id> --ruling <ruling>
#                                       [--question TEXT] [--card-context FILE]
#   bash skills/advisor/gates.sh mode   --run-id ID
#   bash skills/advisor/gates.sh apply  --run-id ID --bc <gate-id>
#                                       --ruling <ruling> --confidence <0-100>
#
# Allowed gate ids (M24): bc7 | bc2-diagnosis | bc6-diagnosis | bc1-mis-fire,
# plus class-verify (CDT-589-C3 trigger-d fence; M24 set extension, M39).
# The M23 denylist — bc3 | bc8 | bc6-extension | bc1-as-human-preference — is
# structurally unreachable: `allow`/`shadow` exit 64 with a stable refusal
# reason on stderr. Unknown ids exit 64 too (an unmapped id can never pass).
#
# M24 vocabularies (the `ruling` subcommand): bc2-diagnosis and bc6-diagnosis
# accept ONLY halt|decompose (proceed can never be emitted); bc1-mis-fire
# accepts ONLY halt-stands|mis-fire; bc7 accepts the M18
# AGREE|CONTRADICT|INSUFFICIENT.
#
# M25 shadow: `shadow` records an ALLOWED gate ruling as SHADOW — one
# class=gate-shadow row (bc, ruling, question, card context, ts) appended to
# $ADVISOR_STATE_ROOT/runs/<run_id>/shadow.jsonl (default
# $MROOT/.claude/advisor/). The ruling is logged, never auto-applied — the
# human decides. The first N=5 runs (ADVISOR_SHADOW_N, only lowers) are the
# measured window; the mode STAYS shadow at and after the boundary. Growing
# past shadow is a human config edit: NO code path in this file writes any
# mode other than the literal "shadow".
#
# CDT-589-C5 opt-in enforce: ADVISOR_ENFORCE is a HUMAN config (default
# off/absent). `1|true|on` enable; `0|false|off` are explicit off; any other
# value is junk -> one stderr line and off (never parsed as code). The mode
# value comes from this config only — no code path computes a mode from
# state. `apply` is the deterministic clear decision for the Step 6c BC1
# halt ONLY: it exits 0 with applied:false (halt stands) unless the config
# is on, the gate is bc1-mis-fire, the ruling is mis-fire, and the
# confidence is >= 80. Usage/validation failures exit 64 — the caller fails
# closed to the halt.

if [ "${BASH_SOURCE[0]:-}" != "$0" ]; then
  echo "gates.sh is a subprocess CLI — never source it (SPEC-039 M23)" >&2
  return 64 2>/dev/null || exit 64
fi

set -u

usage() {
  cat >&2 <<'EOF'
usage: gates.sh allow  --bc bc7|bc2-diagnosis|bc6-diagnosis|bc1-mis-fire
       gates.sh ruling --bc <gate-id> --ruling <ruling>
       gates.sh shadow --run-id ID --bc <gate-id> --ruling <ruling>
                       [--question TEXT] [--card-context FILE]
       gates.sh mode   --run-id ID
       gates.sh apply  --run-id ID --bc bc1-mis-fire
                       --ruling mis-fire --confidence <0-100>
EOF
  exit 64
}

die64() { echo "gates.sh: $1" >&2; exit 64; }

# Run-id sanitization: empty, '/', or '..' can never reach the runs/ path.
check_run_id() { # check_run_id <run-id>
  case "$1" in
    ''|*..*|*/*) die64 "invalid run-id: empty, '/', or '..' not allowed" ;;
  esac
}

CMD="${1:-}"
[ -n "$CMD" ] || usage
shift

# ---- M24 allowed set / M23 denylist (exact SPEC-039 identifiers) ------------
# `class-verify` (CDT-589-C3, M39) extends the allowed set for the trigger-d
# structural fence; the M23 denylist itself is unchanged.
ALLOWED_IDS="bc7|bc2-diagnosis|bc6-diagnosis|bc1-mis-fire|class-verify"
# Stable M23 refusal reasons: <id> (<spec label>) — SPEC-039 M23 denylist.
deny_reason() {
  case "$1" in
    bc3)                     echo "advisor gate refused: bc3 (destructive) — SPEC-039 M23 denylist" ;;
    bc8)                     echo "advisor gate refused: bc8 (product / unverified-external as a gate question) — SPEC-039 M23 denylist" ;;
    bc6-extension)           echo "advisor gate refused: bc6-extension — SPEC-039 M23 denylist" ;;
    bc1-as-human-preference) echo "advisor gate refused: bc1-as-human-preference — SPEC-039 M23 denylist" ;;
    *)                       echo "advisor gate refused: $1 — unknown gate id (allowed: $ALLOWED_IDS)" ;;
  esac
}

# allow <gate-id> — exit 0 allowed / 64 refused; refusal JSON on stdout plus
# the stable reason on stderr so both scripted and human callers are served.
allow() {
  case "$1" in
    bc7|bc2-diagnosis|bc6-diagnosis|bc1-mis-fire|class-verify)
      jq -cn --arg g "$1" '{gate:$g, allowed:true}'
      return 0 ;;
    bc3|bc8|bc6-extension|bc1-as-human-preference)
      R=$(deny_reason "$1")
      jq -cn --arg g "$1" --arg r "$R" '{gate:$g, allowed:false, reason:$r}'
      echo "$R" >&2
      return 64 ;;
    *)
      R=$(deny_reason "$1")
      jq -cn --arg g "$1" --arg r "$R" '{gate:$g, allowed:false, reason:$r}'
      echo "$R" >&2
      return 64 ;;
  esac
}

# ---- M24 outcome vocabulary per gate class -----------------------------------
vocab_for() {
  case "$1" in
    bc2-diagnosis|bc6-diagnosis) echo "halt|decompose" ;;
    bc1-mis-fire)                echo "halt-stands|mis-fire" ;;
    bc7)                         echo "AGREE|CONTRADICT|INSUFFICIENT" ;;
    class-verify)                echo "auth-relevant|not-auth-relevant" ;;
  esac
}

check_ruling() { # check_ruling <gate-id> <ruling> — exit 0 / 64
  VOCAB=$(vocab_for "$1")
  ok=0
  case "$VOCAB" in
    halt\|decompose)      case "$2" in halt|decompose) ok=1 ;; esac ;;
    halt-stands\|mis-fire) case "$2" in halt-stands|mis-fire) ok=1 ;; esac ;;
    AGREE\|CONTRADICT\|INSUFFICIENT) case "$2" in AGREE|CONTRADICT|INSUFFICIENT) ok=1 ;; esac ;;
    auth-relevant\|not-auth-relevant) case "$2" in auth-relevant|not-auth-relevant) ok=1 ;; esac ;;
  esac
  if [ "$ok" -ne 1 ]; then
    jq -cn --arg g "$1" --arg r "$2" --arg v "$VOCAB" \
      '{gate:$g, ruling:$r, accepted:false, vocabulary:($v | split("|"))}'
    echo "advisor gate ruling rejected: $1 must be $VOCAB (SPEC-039 M24) — got '$2'" >&2
    return 64
  fi
  jq -cn --arg g "$1" --arg r "$2" --arg v "$VOCAB" \
    '{gate:$g, ruling:$r, accepted:true, vocabulary:($v | split("|"))}'
  return 0
}

# ---- state root (same pattern as classify.sh) -------------------------------
_gc=$(git rev-parse --git-common-dir 2>/dev/null) \
  && MROOT=$(cd "$(dirname "$_gc")" && pwd) \
  || MROOT=$(pwd)
ADVISOR_DIR="${ADVISOR_STATE_ROOT:-$MROOT/.claude/advisor}"

# M25 window: default N=5; ADVISOR_SHADOW_N only lowers it (integer; junk
# and values >= 5 are ignored — the default is the ceiling).
shadow_n() {
  local n=5
  case "${ADVISOR_SHADOW_N:-}" in
    ''|*[!0-9]*) : ;;
    *) [ "${ADVISOR_SHADOW_N}" -lt "$n" ] && n="${ADVISOR_SHADOW_N}" ;;
  esac
  echo "$n"
}

# CDT-589-C5 enforce config: the human's opt-in. Valid values 1|true|on
# (enforce), 0|false|off (explicit off); junk -> one stderr line + off.
enforce_on() {
  case "${ADVISOR_ENFORCE:-}" in
    '') return 1 ;;
    1|true|on) return 0 ;;
    0|false|off) return 1 ;;
    *)
      echo "gates.sh: ADVISOR_ENFORCE '${ADVISOR_ENFORCE}' is not 1|true|on|0|false|off — enforce stays off" >&2
      return 1 ;;
  esac
}

# apply_decision <bc> <ruling> <confidence> — the CDT-589-C5 clear decision.
# applied:true ONLY for the Step 6c BC1 halt (bc1-mis-fire) with a mis-fire
# ruling at confidence >= 80 AND a valid on config; every other outcome is
# applied:false (the halt stands, fail-closed).
apply_decision() {
  if ! enforce_on; then
    jq -cn '{applied:false, reason:"ADVISOR_ENFORCE off/absent (default) — the halt stands"}'
    return 0
  fi
  if [ "$1" != "bc1-mis-fire" ]; then
    jq -cn --arg bc "$1" \
      '{applied:false, bc:$bc, reason:"enforce scope is the Step 6c BC1 halt (bc1-mis-fire) only — the halt stands"}'
    return 0
  fi
  if [ "$2" != "mis-fire" ]; then
    jq -cn --arg r "$2" \
      '{applied:false, ruling:$r, reason:"ruling is not mis-fire — the halt stands"}'
    return 0
  fi
  if [ "$3" -lt 80 ]; then
    jq -cn --argjson c "$3" \
      '{applied:false, confidence:$c, reason:"confidence below 80 — the halt stands"}'
    return 0
  fi
  jq -cn --arg bc "$1" --arg r "$2" --argjson c "$3" \
    '{applied:true, bc:$bc, ruling:$r, confidence:$c, reason:"BC1 mis-fire clear (CDT-589-C5)"}'
}

case "$CMD" in
  allow)
    [ "$#" -eq 2 ] && [ "$1" = "--bc" ] || usage
    allow "$2"
    exit $?
    ;;
  ruling)
    [ "$#" -eq 4 ] && [ "$1" = "--bc" ] && [ "$3" = "--ruling" ] || usage
    case "$2" in bc7|bc2-diagnosis|bc6-diagnosis|bc1-mis-fire|class-verify) ;; *) usage ;; esac
    [ -n "$4" ] || usage
    check_ruling "$2" "$4"
    exit $?
    ;;
  shadow)
    RUN_ID="" BC="" RULING="" QUESTION="" CTX_FILE=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --run-id) [ $# -ge 2 ] || usage; RUN_ID="$2"; shift 2 ;;
        --run-id=*) RUN_ID="${1#*=}"; shift ;;
        --bc) [ $# -ge 2 ] || usage; BC="$2"; shift 2 ;;
        --bc=*) BC="${1#*=}"; shift ;;
        --ruling) [ $# -ge 2 ] || usage; RULING="$2"; shift 2 ;;
        --ruling=*) RULING="${1#*=}"; shift ;;
        --question) [ $# -ge 2 ] || usage; QUESTION="$2"; shift 2 ;;
        --question=*) QUESTION="${1#*=}"; shift ;;
        --card-context) [ $# -ge 2 ] || usage; CTX_FILE="$2"; shift 2 ;;
        --card-context=*) CTX_FILE="${1#*=}"; shift ;;
        *) usage ;;
      esac
    done
    check_run_id "$RUN_ID"
    [ -n "$BC" ] && [ -n "$RULING" ] || usage
    # The gate is re-checked here: a denylisted id can never reach the log.
    allow "$BC" >/dev/null || exit 64
    check_ruling "$BC" "$RULING" >/dev/null || exit 64
    CTX=""
    if [ -n "$CTX_FILE" ]; then
      [ -f "$CTX_FILE" ] || die64 "shadow: no such --card-context file: $CTX_FILE"
      CTX=$(cat "$CTX_FILE")
      [ "${#CTX}" -le 100000 ] || die64 "shadow: --card-context exceeds 100000 bytes"
    fi
    RUN_DIR="$ADVISOR_DIR/runs/$RUN_ID"
    mkdir -p "$RUN_DIR"
    # One JSONL row per ruling; untrusted text travels only as jq --arg data.
    ROW=$(jq -cn --arg bc "$BC" --arg ruling "$RULING" --arg q "$QUESTION" \
           --arg ctx "$CTX" --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      '{class:"gate-shadow", bc:$bc, ruling:$ruling,
        question:(if $q == "" then null else $q end),
        card_context:(if $ctx == "" then null else $ctx end), ts:$ts}')
    printf '%s\n' "$ROW" >> "$RUN_DIR/shadow.jsonl"
    # Counter + mode: mode is written ONLY as the literal "shadow" — there is
    # no transition anywhere in this file. Growth past shadow is a human edit.
    MODE_FILE="$RUN_DIR/gate-mode.json"
    USED=0
    [ -f "$MODE_FILE" ] && USED=$(jq -r '.shadow_used // 0' "$MODE_FILE" 2>/dev/null) && case "$USED" in ''|*[!0-9]*) USED=0 ;; esac
    N=$(shadow_n)
    USED=$((USED + 1))
    jq -cn --argjson u "$USED" --argjson n "$N" \
      '{mode:"shadow", shadow_used:$u, shadow_n:$n}' > "$MODE_FILE.tmp" \
      && mv "$MODE_FILE.tmp" "$MODE_FILE"
    jq -cn --argjson u "$USED" --argjson n "$N" --arg p "$RUN_DIR/shadow.jsonl" \
      '{mode:"shadow", shadow_used:$u, shadow_n:$n, applied:false, logged_to:$p}'
    exit 0
    ;;
  mode)
    [ "$#" -eq 2 ] && [ "$1" = "--run-id" ] || usage
    check_run_id "$2"
    MODE_FILE="$ADVISOR_DIR/runs/$2/gate-mode.json"
    USED=0
    [ -f "$MODE_FILE" ] && USED=$(jq -r '.shadow_used // 0' "$MODE_FILE" 2>/dev/null) && case "$USED" in ''|*[!0-9]*) USED=0 ;; esac
    N=$(shadow_n)
    # M25 + CDT-589-C5: the mode value comes from the human config only —
    # "enforce" when ADVISOR_ENFORCE is validly on, else the literal "shadow".
    MODE="shadow"; enforce_on && MODE="enforce"
    jq -cn --arg m "$MODE" --argjson u "$USED" --argjson n "$N" \
      '{mode:$m, shadow_used:$u, shadow_n:$n}'
    exit 0
    ;;
  apply)
    RUN_ID="" BC="" RULING="" CONF=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --run-id) [ $# -ge 2 ] || usage; RUN_ID="$2"; shift 2 ;;
        --run-id=*) RUN_ID="${1#*=}"; shift ;;
        --bc) [ $# -ge 2 ] || usage; BC="$2"; shift 2 ;;
        --bc=*) BC="${1#*=}"; shift ;;
        --ruling) [ $# -ge 2 ] || usage; RULING="$2"; shift 2 ;;
        --ruling=*) RULING="${1#*=}"; shift ;;
        --confidence) [ $# -ge 2 ] || usage; CONF="$2"; shift 2 ;;
        --confidence=*) CONF="${1#*=}"; shift ;;
        *) usage ;;
      esac
    done
    check_run_id "$RUN_ID"
    [ -n "$BC" ] && [ -n "$RULING" ] && [ -n "$CONF" ] || usage
    # A denylisted/unknown bc and an out-of-vocabulary ruling are structurally
    # unreachable (exit 64 first) — the caller fails closed to the halt.
    allow "$BC" >/dev/null || exit 64
    check_ruling "$BC" "$RULING" >/dev/null || exit 64
    case "$CONF" in
      ''|*[!0-9]*) die64 "apply: confidence must be an integer 0-100" ;;
    esac
    [ "$CONF" -ge 0 ] && [ "$CONF" -le 100 ] || die64 "apply: confidence must be an integer 0-100"
    apply_decision "$BC" "$RULING" "$CONF"
    exit 0
    ;;
  *) usage ;;
esac
