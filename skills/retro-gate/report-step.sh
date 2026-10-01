#!/usr/bin/env bash
# report-step.sh — scheduled report from apply state. Step 6i body.
if [ "$MODE" = "all" ] && [ "$AUTO" = "1" ]; then  # lint-ok: C1
  _gc=$(git rev-parse --git-common-dir 2>/dev/null) \
    && MROOT=$(cd "$(dirname "$_gc")" && pwd) \
    || MROOT=$(pwd)
  SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
  INVOKER="$SCRIPT_DIR/invoke-scheduled-report.sh"

  APPLIED_FILE=$(mktemp "${TMPDIR:-/tmp}/retro-applied.XXXXXX")
  FOLLOWUP_FILE=$(mktemp "${TMPDIR:-/tmp}/retro-followup.XXXXXX")
  DUP_FILE=$(mktemp "${TMPDIR:-/tmp}/retro-dup.XXXXXX")
  OBS_FILE=$(mktemp "${TMPDIR:-/tmp}/retro-obs.XXXXXX")

  # Applied rows: best-effort from ACTIONABLE that were counted in APPLIED.
  # TSV target\taction\tsummary — orchestrating Claude fills from apply loop state.
  : >"$APPLIED_FILE"
  if [ -n "${ACTIONABLE_PROPOSALS:-}" ]; then
    printf '%s\n' "$ACTIONABLE_PROPOSALS" | while IFS= read -r row; do
      [ -z "$row" ] && continue
      t=$(printf '%s' "$row" | cut -f1)
      a=$(printf '%s' "$row" | cut -f2)
      s=$(printf '%s' "$row" | cut -f4)
      # Only NEW/TIGHTEN whose text is not parked in MANUAL_FOLLOWUP.
      case "$a" in NEW|TIGHTEN)
        parked=0
        if [ -n "$s" ] && [ -n "${MANUAL_FOLLOWUP:-}" ]; then  # lint-ok: C1
          if printf '%s\n' "$MANUAL_FOLLOWUP" | grep -qF -- "$s"; then  # lint-ok: C1
            parked=1
          fi
        fi
        if [ "$parked" = "0" ]; then
          printf '%s\t%s\t%s\n' "$t" "$a" "$s" >>"$APPLIED_FILE"
        fi
        ;;
      esac
    done
  fi

  : >"$FOLLOWUP_FILE"
  if [ -n "${MANUAL_FOLLOWUP:-}" ]; then  # lint-ok: C1
    printf '%s\n' "$MANUAL_FOLLOWUP" >>"$FOLLOWUP_FILE"  # lint-ok: C1
  fi

  : >"$DUP_FILE"
  if [ -n "${DUPLICATE_PROPOSALS:-}" ]; then  # lint-ok: C1
    printf '%s\n' "$DUPLICATE_PROPOSALS" | while IFS= read -r row; do  # lint-ok: C1
      [ -z "$row" ] && continue
      t=$(printf '%s' "$row" | cut -f1)
      s=$(printf '%s' "$row" | cut -f4)
      ref=$(printf '%s' "$row" | cut -f6)
      printf 'target=%s existing=%s proposed=%s\n' "$t" "$ref" "$s" >>"$DUP_FILE"
    done
  fi

  : >"$OBS_FILE"
  if [ -n "${OBSERVATIONS:-}" ]; then  # lint-ok: C1
    printf '%s\n' "$OBSERVATIONS" | while IFS= read -r row; do  # lint-ok: C1
      [ -z "$row" ] && continue
      printf '%s\n' "$(printf '%s' "$row" | cut -f1)" >>"$OBS_FILE"
    done
  fi

  DUP_N=$(grep -c . "$DUP_FILE" 2>/dev/null || true); DUP_N=${DUP_N:-0}
  MF_N=$(grep -c . "$FOLLOWUP_FILE" 2>/dev/null || true); MF_N=${MF_N:-0}
  OBS_N=$(grep -c . "$OBS_FILE" 2>/dev/null || true); OBS_N=${OBS_N:-0}
  APPLIED_N=$(grep -c . "$APPLIED_FILE" 2>/dev/null || true); APPLIED_N=${APPLIED_N:-0}
  APPLIED_N=$(printf '%s' "$APPLIED_N" | head -1 | tr -cd '0-9')
  APPLIED_N=${APPLIED_N:-0}
  SUMMARY="Applied: ${APPLIED_N} | Rejected: ${REJECTED:-0} | Suggested: ${SUGGESTED:-0} | Duplicates: ${DUP_N} | Manual follow-up: ${MF_N} | Observations: ${OBS_N}"  # lint-ok: C1
  NOTE=""
  if [ -x "$INVOKER" ]; then
    # Session counters are set in earlier fences. Copy them here so this shell has them.
    SCANNED=${SCANNED:-0}  # lint-ok: C1
    SKIPPED_INPROG=${SKIPPED_INPROG:-0}  # lint-ok: C1
    SKIPPED_FILTER2=${SKIPPED_FILTER2:-0}  # lint-ok: C1
    GATED_PASS=${GATED_PASS:-0}  # lint-ok: C1
    DEEP_READ=${DEEP_READ:-0}  # lint-ok: C1
    SCHEDULED_LOCK_TOKEN=${SCHEDULED_LOCK_TOKEN:-}  # lint-ok: C1
    # lint-ok: C1 — MODE and AUTO come from earlier fences
    bash "$INVOKER" \
      --mode "$MODE" --auto "$AUTO" \
      --token "$SCHEDULED_LOCK_TOKEN" \
      --mroot "$MROOT" \
      --note "$NOTE" --summary "$SUMMARY" \
      --scanned "$SCANNED" \
      --skipped-inprog "$SKIPPED_INPROG" \
      --skipped-filter2 "$SKIPPED_FILTER2" \
      --gated "$GATED_PASS" --deep "$DEEP_READ" \
      --applied-file "$APPLIED_FILE" \
      --followup-file "$FOLLOWUP_FILE" \
      --duplicate-file "$DUP_FILE" \
      --observations-file "$OBS_FILE"
  fi
  rm -f "$APPLIED_FILE" "$FOLLOWUP_FILE" "$DUP_FILE" "$OBS_FILE"
fi
