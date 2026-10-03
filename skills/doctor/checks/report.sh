# report.sh — sourced by doctor.sh (rv-w3-39 doctor split); pure definitions, no top-level side effects.
# ---------------------------------------------------------------------------
# Render
# ---------------------------------------------------------------------------
render_human() {
  echo "dev-team doctor  plugin=${PLUGIN_VERSION:-unknown}  tier=${RESOLVED_TIER}  mroot=$MROOT${GATE:+  gate=$GATE}"
  echo "----------------------------------------------------------------"
  local i=0
  while [ $i -lt ${#CHECK_IDS[@]} ]; do
    printf '%-4s | %s | %s\n' \
      "${CHECK_STATUSES[$i]}" "${CHECK_IDS[$i]}" "${CHECK_DETAILS[$i]}"
    if [ "${CHECK_STATUSES[$i]}" = "WARN" ] || [ "${CHECK_STATUSES[$i]}" = "FAIL" ]; then
      if [ -n "${CHECK_FIXITS[$i]}" ]; then
        printf '       fix-it: %s\n' "${CHECK_FIXITS[$i]}"
      fi
    fi
    i=$((i + 1))
  done
  echo "----------------------------------------------------------------"
  if [ -n "$GATE" ] && [ "$N_FAIL_WAIVED" -gt 0 ]; then
    printf '%d pass / %d warn / %d fail (%d self-remediating under --gate=%s) / %d skip\n' \
      "$N_PASS" "$N_WARN" "$N_FAIL" "$N_FAIL_WAIVED" "$GATE" "$N_SKIP"
  else
    printf '%d pass / %d warn / %d fail / %d skip\n' "$N_PASS" "$N_WARN" "$N_FAIL" "$N_SKIP"
  fi
}

render_json() {
  # Pure-bash JSON for AC18 (no jq required); additive fields under --gate only
  local i first=1
  printf '{'
  printf '"doctor_schema":"%s",' "$(json_escape "$DOCTOR_SCHEMA")"
  printf '"plugin_version":"%s",' "$(json_escape "${PLUGIN_VERSION:-}")"
  printf '"resolved_tier":"%s",' "$(json_escape "$RESOLVED_TIER")"
  if [ -n "$GATE" ]; then
    printf '"gate":"%s",' "$(json_escape "$GATE")"
  fi
  printf '"checks":['
  i=0
  while [ $i -lt ${#CHECK_IDS[@]} ]; do
    [ "$first" -eq 1 ] || printf ','
    first=0
    printf '{'
    printf '"id":"%s",' "$(json_escape "${CHECK_IDS[$i]}")"
    printf '"group":"%s",' "$(json_escape "${CHECK_GROUPS[$i]}")"
    printf '"status":"%s",' "$(json_escape "${CHECK_STATUSES[$i]}")"
    printf '"detail":"%s",' "$(json_escape "${CHECK_DETAILS[$i]}")"
    if [ -z "${CHECK_FIXITS[$i]}" ]; then
      printf '"fixit":null'
    else
      printf '"fixit":"%s"' "$(json_escape "${CHECK_FIXITS[$i]}")"
    fi
    # Additive: gate_waived only when --gate is active
    if [ -n "$GATE" ]; then
      if [ "${CHECK_GATE_WAIVED[$i]:-0}" -eq 1 ]; then
        printf ',"gate_waived":true'
      else
        printf ',"gate_waived":false'
      fi
    fi
    printf '}'
    i=$((i + 1))
  done
  printf '],'
  if [ -n "$GATE" ]; then
    printf '"summary":{"pass":%d,"warn":%d,"fail":%d,"fail_waived":%d,"fail_blocking":%d,"skip":%d}' \
      "$N_PASS" "$N_WARN" "$N_FAIL" "$N_FAIL_WAIVED" "$N_FAIL_BLOCK" "$N_SKIP"
  else
    printf '"summary":{"pass":%d,"warn":%d,"fail":%d,"skip":%d}' \
      "$N_PASS" "$N_WARN" "$N_FAIL" "$N_SKIP"
  fi
  printf '}\n'
}

