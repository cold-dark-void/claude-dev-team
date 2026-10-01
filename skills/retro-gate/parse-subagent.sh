#!/usr/bin/env bash
# parse-subagent.sh — validate subagent JSON into RAW TSV and persist anchors.
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
export RETRO_GATE_DIR="${RETRO_GATE_DIR:-$SCRIPT_DIR}"
ALLOWED_TARGETS="pm tech-lead ic5 ic4 devops qa ds claude plugin"
if [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -d "$CLAUDE_PLUGIN_ROOT/skills/retro-gate" ]; then
  export RETRO_GATE_DIR="$CLAUDE_PLUGIN_ROOT/skills/retro-gate"
elif [ -d skills/retro-gate ]; then
  export RETRO_GATE_DIR="$(pwd)/skills/retro-gate"
fi

parse_one() {
  # Caller sets RETRO_JSON and RETRO_SRC before invoking.
  # No function parameters — avoids Claude Code $1/$2 arg substitution in skill text.
  python3 - <<'PY'
import json, os, sys
_gate = os.environ.get("RETRO_GATE_DIR", "")
if _gate and _gate not in sys.path:
    sys.path.insert(0, _gate)
from parse_results import anchor_id, sanitize
src = os.environ.get("RETRO_SRC", "")
raw = os.environ.get("RETRO_JSON", "")
try:
    d = json.loads(raw)
except Exception:
    raise SystemExit(0)
for p in d.get("proposals", []) or []:
    cites = p.get("citations") or []
    # Keep BOTH: the count (for the confidence*citation_count rank key) and the
    # actual {message_id, excerpt} pairs (for the Step 6 Evidence: display). The
    # JSON array is one TSV-safe field — json.dumps escapes any tab/newline in
    # the excerpt text, so it cannot break the column structure.
    # Validation rule 2 (SKILL.md:225): drop any citation missing message_id or
    # excerpt, or with empty values, BEFORE counting. len(norm) then feeds the
    # rank key and the Rule-1 count gate (Step 4d), so a proposal whose only
    # citation is empty drops to zero valid citations and fails Rule 1.
    norm = []
    for c in cites:
        if not isinstance(c, dict):
            continue
        mid = c.get("message_id", "")
        exc = c.get("excerpt", "")
        if not isinstance(mid, str) or not isinstance(exc, str):
            continue
        if mid == "" or exc == "":
            continue
        norm.append({"message_id": mid, "excerpt": exc})
    cites_json = json.dumps(norm, separators=(",", ":"))
    print("proposal\t%s\t%s\t%s\t%d\t%s\t%s\t%s" % (
        sanitize(p.get("target","")),
        sanitize(p.get("proposed_text","") or ""),
        p.get("confidence",0), len(norm), cites_json,
        sanitize(p.get("pattern_summary","")), src))
for o in d.get("observations", []) or []:
    print("observation\t%s\t%s" % (
        sanitize(o.get("description","") or ""), src))
# fabrication_anchors (SPEC-012 §Phase 2 / SPEC-013 §Integration Hooks)
# Columns: aid, tid, claim, evid, source_jsonl (src from outer SUBAGENT_RESULTS)
# anchor_id is recomputed here. The model value is not trusted.
for fa in d.get("fabrication_anchors", []) or []:
    tid   = sanitize(fa.get("turn_id","") or "")
    claim = sanitize(fa.get("fabricated_claim_text","") or "")
    evid  = sanitize(fa.get("evidence_for_fabrication","") or "")
    aid   = anchor_id(tid, claim, src)
    # Drop records missing required fields (SKILL.md validation contract)
    if not tid or not evid or not aid or not claim:
        continue
    print("fabrication_anchor\t%s\t%s\t%s\t%s\t%s" % (aid, tid, claim, evid, src))
PY
}

RAW_PROPOSALS=""
OBSERVATIONS=""
RAW_FABRICATION_ANCHORS=""   # newline-separated: anchor_id<TAB>turn_id<TAB>claim<TAB>evidence<TAB>source_jsonl

while IFS= read -r LINE; do
  [ -z "$LINE" ] && continue
  # Each line in SUBAGENT_RESULTS is "<src-jsonl>\t<json>" (see Step 4c).
  SRC=$(printf '%s' "$LINE" | cut -f1)
  JSON=$(printf '%s' "$LINE" | cut -f2-)

  while IFS=$'\t' read -r KIND F1 F2 F3 F4 F5 F6 F7; do
    case "$KIND" in
      fabrication_anchor)
        AID="$F1"; TID="$F2"; CLAIM="$F3"; EVID="$F4"; SRCJ="${F5:-$SRC}"
        [ -z "$AID" ] || [ -z "$TID" ] || [ -z "$EVID" ] && continue
        RAW_FABRICATION_ANCHORS="$RAW_FABRICATION_ANCHORS
$AID	$TID	$CLAIM	$EVID	$SRCJ"
        ;;
      proposal)
        TARGET="$F1"; TEXT="$F2"; CONF="$F3"; CITES="$F4"; CITESJSON="$F5"; PSUM="$F6"; SRCJ="$F7"
        # Rule 1: citations.length > 0
        if [ "${CITES:-0}" -lt 1 ]; then
          echo "# retro: dropped proposal (reason: zero citations) target=$TARGET summary=$PSUM" >&2
          continue
        fi
        # Rule 2: target in allowlist (pure string match, not regex — TARGET may
        # contain metacharacters from an adversarial subagent).
        case " $ALLOWED_TARGETS " in
          *" $TARGET "*) ;;
          *)
            echo "# retro: dropped proposal (reason: disallowed target=$TARGET) summary=$PSUM" >&2
            continue
            ;;
        esac
        # Rule 3: proposed_text non-empty and <= 200 chars
        LEN=${#TEXT}
        if [ -z "$TEXT" ] || [ "$LEN" -gt 200 ]; then
          echo "# retro: dropped proposal (reason: bad text length=$LEN) target=$TARGET" >&2
          continue
        fi
        # Rule 3b: reject control characters (tab/newline corrupt the downstream
        # TSV and ANSI escapes would injure the operator terminal).
        case "$TEXT" in
          *[$'\t\n\r'$'\001'-$'\037'$'\177']*)
            echo "# retro: dropped proposal (control chars in text) target=$TARGET" >&2
            continue
            ;;
        esac
        # Rule 3c: reject obvious prompt-injection / exfil strings.
        case "$TEXT" in
          *http://*|*https://*|*"curl "*|*"wget "*|*"sudo "*|*"ignore previous"*|*"<command-name>"*|*'`'*)
            echo "# retro: dropped proposal (suspicious content) target=$TARGET" >&2
            continue
            ;;
        esac
        # Rule 5 (SKILL.md): pattern_summary non-empty.
        if [ -z "$PSUM" ]; then
          echo "# retro: dropped proposal (reason: empty pattern_summary) target=$TARGET" >&2
          continue
        fi
        # Rule 6 (SKILL.md:225): confidence present, numeric, and within [0.0, 1.0].
        # MUST run BEFORE the rank multiply — an out-of-range or non-numeric
        # confidence would otherwise inflate RANK=confidence*citation_count and
        # float a bogus proposal into the top-5 (Step 4e sort). The awk regex
        # rejects non-numeric / empty CONF; the range check rejects <0 or >1. awk
        # exits 0 only when CONF is a valid in-range number (avoid `!` here so the
        # gate is copy-paste safe under zsh).
        if awk -v c="$CONF" 'BEGIN{ if (c ~ /^-?[0-9]+(\.[0-9]+)?$/) { v=c+0; if (v >= 0.0 && v <= 1.0) exit 0 } exit 1 }'; then
          : # confidence valid — fall through to ranking
        else
          echo "# retro: dropped proposal (reason: confidence not in [0.0,1.0]) target=$TARGET conf=$CONF" >&2
          continue
        fi
        # Compute rank key = confidence * citation_count (awk for float math).
        # CONF is validated numeric+in-range above, so the multiply cannot inflate.
        RANK=$(awk -v c="$CONF" -v n="$CITES" 'BEGIN{printf "%.6f", c*n}')
        # RAW_PROPOSALS columns (TSV): 1 rank, 2 target, 3 confidence,
        # 4 citation_count, 5 pattern_summary, 6 proposed_text, 7 source_jsonl,
        # 8 citations_json. col8 (JSON array) is TSV-safe (see Step 4d parser).
        RAW_PROPOSALS="$RAW_PROPOSALS
$RANK	$TARGET	$CONF	$CITES	$PSUM	$TEXT	$SRCJ	$CITESJSON"
        ;;
      observation)
        DESC="$F1"; SRCJ="$F2"
        [ -z "$DESC" ] && continue
        OBSERVATIONS="$OBSERVATIONS
$DESC	$SRCJ"
        ;;
    esac
  done < <(RETRO_JSON="$JSON" RETRO_SRC="$SRC" parse_one)
done <<< "$SUBAGENT_RESULTS"  # lint-ok: C1

RAW_PROPOSALS=$(echo "$RAW_PROPOSALS" | sed '/^[[:space:]]*$/d')
OBSERVATIONS=$(echo "$OBSERVATIONS"  | sed '/^[[:space:]]*$/d')
RAW_FABRICATION_ANCHORS=$(echo "$RAW_FABRICATION_ANCHORS" | sed '/^[[:space:]]*$/d')

# Dedup fabrication anchors by anchor_id — per SPEC-012 §Integration Hooks,
# surface at most one hint per distinct anchor_id within a single retro run.
# Cross-run dedup is automatic via the deterministic hash in anchor_id.
FABRICATION_ANCHORS=""
SEEN_ANCHOR_IDS=""
while IFS= read -r row; do
  [ -z "$row" ] && continue
  AID=$(printf '%s' "$row" | cut -f1)
  if printf '%s\n' "$SEEN_ANCHOR_IDS" | grep -Fxq -- "$AID"; then
    echo "# retro: dedup fabrication_anchor anchor_id=$AID (already seen in this run)" >&2
    continue
  fi
  SEEN_ANCHOR_IDS="$SEEN_ANCHOR_IDS
$AID"
  FABRICATION_ANCHORS="$FABRICATION_ANCHORS
$row"
done <<< "$RAW_FABRICATION_ANCHORS"
FABRICATION_ANCHORS=$(echo "$FABRICATION_ANCHORS" | sed '/^[[:space:]]*$/d')

# Persist anchors to $MROOT/.claude/retro/anchors/<id>.json (CDV-212 design a).
# Single writer: this command after validation/dedup — NOT the subagent.
# Idempotent overwrite OK (deterministic anchor_id). Shared across worktrees.
if [ -n "$FABRICATION_ANCHORS" ]; then  # lint-ok: C1
  _gc=$(git rev-parse --git-common-dir 2>/dev/null) \
    && MROOT=$(cd "$(dirname "$_gc")" && pwd) \
    || MROOT=$(pwd)
  ANCHOR_DIR="$MROOT/.claude/retro/anchors"
  mkdir -p "$ANCHOR_DIR"
  while IFS= read -r row; do
    [ -z "$row" ] && continue
    AID=$(printf '%s' "$row" | cut -f1)
    TID=$(printf '%s' "$row" | cut -f2)
    CLAIM=$(printf '%s' "$row" | cut -f3)
    EVID=$(printf '%s' "$row" | cut -f4)
    SRCJ=$(printf '%s' "$row" | cut -f5)
    # Path-safe id only (reject traversal)
    case "$AID" in
      *[!a-zA-Z0-9._-]*|"") 
        echo "# retro: skip persist anchor (invalid anchor_id=$AID)" >&2
        continue
        ;;
    esac
    SESSION_ID=$(basename -- "${SRCJ:-unknown}" .jsonl)
    CREATED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    TMPA=$(mktemp "${TMPDIR:-/tmp}/retro-anchor.XXXXXX.json") \
      || { echo "# retro: mktemp failed for anchor $AID" >&2; continue; }
    if jq -n \
      --arg anchor_id "$AID" \
      --arg session_id "$SESSION_ID" \
      --arg turn_id "$TID" \
      --arg fabricated_claim_text "$CLAIM" \
      --arg evidence_for_fabrication "$EVID" \
      --arg source_jsonl_path "$SRCJ" \
      --arg created_at "$CREATED_AT" \
      '{
        anchor_id: $anchor_id,
        session_id: $session_id,
        turn_id: $turn_id,
        fabricated_claim_text: $fabricated_claim_text,
        evidence_for_fabrication: $evidence_for_fabrication,
        source_jsonl_path: $source_jsonl_path,
        created_at: $created_at
      }' > "$TMPA"; then
      mv -f "$TMPA" "$ANCHOR_DIR/${AID}.json"
      echo "# retro: persisted fabrication anchor $AID → $ANCHOR_DIR/${AID}.json" >&2
    else
      rm -f "$TMPA"
      echo "# retro: failed to write anchor JSON for $AID" >&2
    fi
  done <<< "$FABRICATION_ANCHORS"
fi

printf "RAW_PROPOSALS<<RETRO_END\n%s\nRETRO_END\n" "${RAW_PROPOSALS:-}"

printf "OBSERVATIONS<<RETRO_END\n%s\nRETRO_END\n" "${OBSERVATIONS:-}"

printf "FABRICATION_ANCHORS<<RETRO_END\n%s\nRETRO_END\n" "${FABRICATION_ANCHORS:-}"
