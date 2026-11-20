# controlplane.sh — the doctor row for the control-plane systemd user unit
# (CDT-658 T5/T8, SPEC-043 § Test; the check semantics are SPEC-022 M3).
#
# WARN-never-FAIL: the control plane is an opt-in service, so an absent
# install is an optional-dependency finding, never a broken hard invariant.
# No branch of this file records FAIL.
#
# Sourced by doctor.sh like every checks/*.sh. Registration lives in the
# doctor.sh registry (the dominant convention; only intercom.sh self-registers).
# Read-only: it reads the unit file, asks systemctl, and issues one loopback
# GET. `--fix` never repairs this id (SPEC-043 M7 — the closed allowlist is
# untouched).
#
# Paths and unit names come from skills/control-plane/units.sh (sourced, never
# run), so the row reads exactly what /setup control-plane writes:
# %h/.config/systemd/user/dev-team-<service>.service (CP_UNIT_SERVICES — the
# chiefd unit; the node agent ships no unit, SPEC-043 M5) and %h/.local/bin.
# Hermetic seams (the same knobs the setup driver documents): CP_UNIT_DIR,
# CP_BIN_DIR, CP_HTTP_URL, CP_HTTP_TIMEOUT.

CP_DOCTOR_HTTP_DEFAULT='http://127.0.0.1:8090/v1/runs'
CP_DOCTOR_HTTP_TIMEOUT='3'

_controlplane_loopback_url() {
  # Doctor probes loopback only. chiefd binds 127.0.0.1:8090 and SPEC-043 AC13
  # forbids widening the bind, so a CP_HTTP_URL that names another host is a
  # misconfiguration to report — never a host for doctor to dial.
  local url="${1-}" host
  host=${url#*://}
  host=${host%%/*}
  host=${host%%:*}
  case "$host" in
    127.0.0.1 | localhost | ::1 | '[::1]') return 0 ;;
  esac
  return 1
}

check_controlplane_units() {
  # One row: the unit file present, the unit is-enabled + is-active, and chiefd
  # answering on the loopback API. A partial install, an unreadable unit state,
  # an inactive unit, and a silent port are all WARN with the same fix.
  local id='controlplane.units' group='controlplane'
  local lib="$PLUGIN_ROOT/skills/control-plane/units.sh"
  local svc unit unit_dir url problems='' present=0 absent=0 absent_units=''
  local state enabled rc http_timeout
  if [ ! -f "$lib" ]; then
    record "$id" "$group" 'SKIP' \
      'skills/control-plane/units.sh absent — no control-plane install to read' '' || return 0
    return 0
  fi
  # shellcheck source=../../control-plane/units.sh
  . "$lib"
  unit_dir=$(cp_unit_dir)
  for svc in $CP_UNIT_SERVICES; do
    unit=$(cp_unit_path "$svc")
    # Probe-only read; a unit file that vanishes after this test is a benign
    # mislabel on a row that never acts on the answer.
    if [ -f "$unit" ]; then
      present=$((present + 1))
    else
      absent=$((absent + 1))
      absent_units="$absent_units ${unit##*/}"
    fi
  done
  if [ "$present" -eq 0 ]; then
    record "$id" "$group" 'WARN' \
      "control plane not installed — no $(cp_unit_name chiefd) in $unit_dir (the service is opt-in)" \
      '/setup control-plane' || return 0
    return 0
  fi
  if [ "$absent" -gt 0 ]; then
    record "$id" "$group" 'WARN' \
      "partial control-plane install —$absent_units missing from $unit_dir" \
      '/setup control-plane' || return 0
    return 0
  fi
  if ! have_cmd systemctl; then
    record "$id" "$group" 'WARN' \
      'systemctl is not on PATH — the unit state is unreadable' \
      'Linux with a systemd user manager is the only supported platform (SPEC-043 M2(b)), then run: /setup control-plane' || return 0
    return 0
  fi
  for svc in $CP_UNIT_SERVICES; do
    unit=$(cp_unit_name "$svc")
    # is-active exits non-zero for a unit that is not active, so the read keeps
    # the answer and the code (an unguarded `|| state=''` loses the state word).
    rc=0
    state=$(cp_systemctl is-active "$unit" 2>/dev/null) || rc=$?
    state=$(trim_ws "$state")
    # is-enabled exits non-zero for a disabled unit, so the read is guarded —
    # an unguarded assignment trips errexit on the answer this row expects.
    enabled=$(cp_systemctl is-enabled "$unit" 2>/dev/null) || enabled=''
    enabled=$(trim_ws "${enabled%%$'\n'*}")
    if [ "$state" = 'active' ] && [ "$enabled" = 'enabled' ]; then
      continue
    fi
    if [ "$state" = 'active' ]; then
      problems="${problems:+$problems; }unit $unit is active but ${enabled:-not enabled} — it will not return after a reboot"
    else
      problems="${problems:+$problems; }unit $unit is ${state:-unreadable} (is-active exit $rc)"
    fi
  done
  # A unit for a service SPEC-043 M5 dropped (the pre-T8 node-agent unit) is a
  # stale install: its supervised binary is gone, so the manager restart-loops
  # it. /setup control-plane removes it.
  for unit in $CP_LEGACY_UNITS; do
    if [ -f "$unit_dir/$unit" ]; then
      problems="${problems:+$problems; }stale unit $unit is present — phase 1 ships no node-agent unit (SPEC-043 M5)"
    fi
  done
  url="${CP_HTTP_URL:-$CP_DOCTOR_HTTP_DEFAULT}"
  http_timeout="${CP_HTTP_TIMEOUT:-$CP_DOCTOR_HTTP_TIMEOUT}"
  case "$http_timeout" in
    '' | *[!0-9]*) http_timeout=$CP_DOCTOR_HTTP_TIMEOUT ;;
  esac
  if ! _controlplane_loopback_url "$url"; then
    problems="${problems:+$problems; }chiefd probe URL $url is not loopback (SPEC-043 AC13)"
  elif have_cmd curl; then
    rc=0
    curl -fsS -m "$http_timeout" -o /dev/null "$url" >/dev/null 2>&1 || rc=$?
    [ "$rc" -eq 0 ] || problems="${problems:+$problems; }chiefd does not answer on $url (curl exit $rc)"
  elif have_cmd wget; then
    rc=0
    wget -q -T "$http_timeout" -t 1 -O /dev/null "$url" >/dev/null 2>&1 || rc=$?
    [ "$rc" -eq 0 ] || problems="${problems:+$problems; }chiefd does not answer on $url (wget exit $rc)"
  else
    problems="${problems:+$problems; }no HTTP client on PATH — $url is unreadable"
  fi
  if [ -z "$problems" ]; then
    record "$id" "$group" 'PASS' \
      "unit $(cp_unit_name chiefd) is active and enabled; chiefd answers on $url — loopback only (SPEC-043 M5/AC13)" '' || return 0
    return 0
  fi
  record "$id" "$group" 'WARN' "control plane: $problems" '/setup control-plane' || return 0
  return 0
}
