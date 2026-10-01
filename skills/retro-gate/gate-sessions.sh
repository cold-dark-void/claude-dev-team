#!/usr/bin/env bash
# gate-sessions.sh — score each session with a per-file cap. Honors GATE_SH when set.
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
if [ -z "${GATE_SH:-}" ]; then
  GATE_SH="$SCRIPT_DIR/gate.sh"
fi
FLAGGED_SESSIONS=""
ANCHOR_IDS=""        # newline-separated "<jsonl-path> <id>" pairs for Step 4
GATE_START=$(date +%s)
TOTAL=$(echo "$SESSIONS" | wc -l)  # lint-ok: C1
N=0

# Step 4b reads gate stdout from this directory. Do not re-run gate.sh.
if [ -z "${GATE_CACHE:-}" ]; then  # lint-ok: C1
  GATE_CACHE=$(mktemp -d "${TMPDIR:-/tmp}/retro-gate-cache.XXXXXX")
  echo "GATE_CACHE=$GATE_CACHE"
fi

# Total budget: 5s for single/explicit mode; unlimited for --all (per-file cap applies instead).
TOTAL_BUDGET=5

while IFS= read -r JSONL; do
  [ -z "$JSONL" ] && continue
  N=$(( N + 1 ))

  # Total-budget check — only enforce in single/explicit mode.
  if [ "$MODE" != "all" ]; then  # lint-ok: C1
    ELAPSED=$(( $(date +%s) - GATE_START ))
    if [ "$ELAPSED" -ge $TOTAL_BUDGET ]; then
      REMAINING=$(( TOTAL - N + 1 ))
      echo "# retro: gate budget exceeded after $(( N - 1 ))/$TOTAL sessions (${ELAPSED}s >= ${TOTAL_BUDGET}s) — skipping remaining $REMAINING"
      break
    fi
  fi

  # Per-file cap: timeout 2 when timeout(1) exists. Otherwise measure after the gate.
  if [ "$MODE" = "all" ]; then  # lint-ok: C1
    if command -v timeout >/dev/null 2>&1; then
      GATE_OUT=$(timeout 2 bash "$GATE_SH" "$JSONL" 2>/dev/null)
      FILE_RC=$?
      if [ "$FILE_RC" -eq 124 ]; then
        echo "# retro: gate timed out on $(basename "$JSONL" .jsonl) (timeout 2s per-file cap) — skipping" >&2
        continue
      fi
    else
      FILE_START=$(date +%s)
      GATE_OUT=$(bash "$GATE_SH" "$JSONL" 2>/dev/null)
      FILE_ELAPSED=$(( $(date +%s) - FILE_START ))
      if [ "$FILE_ELAPSED" -ge 2 ]; then
        echo "# retro: gate timed out on $(basename "$JSONL" .jsonl) (${FILE_ELAPSED}s >= 2s per-file cap) — skipping" >&2
        continue
      fi
    fi
  else
    GATE_OUT=$(bash "$GATE_SH" "$JSONL" 2>/dev/null)
  fi
  # Step 4b reads this file. Do not run gate.sh again for the same JSONL.
  if [ -n "${GATE_CACHE:-}" ]; then  # lint-ok: C1
    mkdir -p "$GATE_CACHE"
    _gsid=$(basename "$JSONL" .jsonl)
    printf '%s\n' "$GATE_OUT" > "$GATE_CACHE/${_gsid}.out"
  fi
  PASSED=$(echo "$GATE_OUT" | grep -o '"passed": *true' | head -1)
  SCORE=$(echo "$GATE_OUT" | grep -o '"score": *[0-9][0-9.]*' | head -1 | grep -o '[0-9][0-9.]*')
  THRESHOLD=$(echo "$GATE_OUT" | grep -o '"threshold": *[0-9][0-9.]*' | head -1 | grep -o '[0-9][0-9.]*')

  if [ -n "$PASSED" ]; then
    GATED_PASS=$(( ${GATED_PASS:-0} + 1 ))
    DEEP_READ=$(( ${DEEP_READ:-0} + 1 ))
    FLAGGED_SESSIONS="$FLAGGED_SESSIONS
$JSONL"
    # Collect anchor message IDs from signals[].ids[] for Step 4.
    # gate.sh emits real Claude Code UUIDs (not `msg_*` prefixed), so parse JSON
    # directly rather than regex-matching a prefix.
    IDS=$(echo "$GATE_OUT" | python3 -c 'import json,sys
try:
    d = json.load(sys.stdin)
    for s in d.get("signals", []):
        for i in s.get("ids", []):
            print(i)
except Exception:
    pass')
    while IFS= read -r ID; do
      [ -z "$ID" ] && continue
      ANCHOR_IDS="$ANCHOR_IDS
$JSONL $ID"
    done <<< "$IDS"
  fi

  # --why output: per-session signal table
  if [ "$WHY" = "1" ]; then  # lint-ok: C1
    SID=$(basename "$JSONL" .jsonl)
    PASSED_LABEL="passed"
    [ -z "$PASSED" ] && PASSED_LABEL="not passed"
    echo "Session: $SID"
    echo "Score: ${SCORE:-?} / ${THRESHOLD:-5.0} ($PASSED_LABEL)"

    echo "$GATE_OUT" | python3 -c '
import json, sys
d = json.load(sys.stdin)
matched = {s["name"]: s["count"] for s in d.get("signals", [])}
if matched:
    print("Matched signals:")
    for name, count in sorted(matched.items()):
        print("  %s x%s" % (name, count))
else:
    print("Matched signals: (none)")
not_matched = [s for s in ("S1","S2","S3","S4","S5") if s not in matched]
if not_matched:
    print("Not matched: " + ", ".join(not_matched))
'
    echo ""
  fi

done <<< "$SESSIONS"

FLAGGED_SESSIONS=$(echo "$FLAGGED_SESSIONS" | sed '/^[[:space:]]*$/d')
ANCHOR_IDS=$(echo "$ANCHOR_IDS" | sed '/^[[:space:]]*$/d')

printf "FLAGGED_SESSIONS<<RETRO_END\n%s\nRETRO_END\n" "${FLAGGED_SESSIONS:-}"

printf "ANCHOR_IDS<<RETRO_END\n%s\nRETRO_END\n" "${ANCHOR_IDS:-}"

printf "GATE_CACHE=%s\n" "${GATE_CACHE:-}"

printf "GATED_PASS=%s\n" "${GATED_PASS:-0}"

printf "DEEP_READ=%s\n" "${DEEP_READ:-0}"
