#!/usr/bin/env bash
# skills/control-plane/setup.sh — /setup control-plane: one command, three modes
# (CDT-658 T3; SPEC-043 M1/M6/M7/M10/M11/M12, AC1/AC2/AC3/AC6/AC7/AC10/AC11/AC12/AC13).
#
# SUBPROCESS CLI — never source it. It composes the two modules that own the
# mechanics: skills/control-plane/preflight.sh (SPEC-043 M2, `cp_preflight`) and
# skills/control-plane/units.sh (M3/M4/M5/M9/M12, `cp_install`/`cp_uninstall`).
# This file owns the dispatch, the probe, and the verify table.
#
# Modes (SPEC-043 M1):
#   (bare)       preflight → build → install + enable → verify table
#   --status     the verify table alone: zero writes, no build, no probe start
#   --uninstall  cp_uninstall (M9) plus the Windows operator steps
#   --help       usage
#
# Exit (SPEC-043 M7 / AC12, the /doctor scheme with one reserved code):
#   0  the table has PASS/WARN rows only (and for the SKIP rows they imply)
#   2  the table has at least one FAIL row, or a build/install FAIL
#   63 unsupported platform or environment shape (M2(a)-(d), macOS, non-checkout)
#   64 usage error
#
# The table body and footer come from skills/lib/record-status.sh — the same
# home /doctor renders from (SPEC-043 M6 footer: `N pass / N warn / N fail / N skip`).
#
# The probe (SPEC-043 M11 as ruled by the T0 spike, spec § Q1a/Q1b/Q1c):
#   - run id `devteam-setup-probe`, one `node-agent start --command <no-op>`;
#   - the start invocation carries the M2(g) resolved selection as the
#     per-invocation `$DEVTEAM_RUNNER` override on the child (`native` when the
#     node names none) — the agent starts no run on a node with no selection,
#     so an unoverridden probe can never pass on a fresh node (T8 replan D2);
#   - `node-agent stop` is NEVER run against that id: a stop of a live probe
#     lands it in `halted:operator_halt`, which the agent never resumes, so it
#     would poison the fixed id for every later install (spec § Q1b ruling);
#   - the driver branches on the JOURNAL state, read by dist path
#     (`control-plane/dist/journalctl`, never a PATH name — AC11), because
#     `node-agent status` exits 0 even for a run id with no rows (spec § Q1a);
#     a node with no journal database skips the read (the CLI creates a database
#     it is asked to read), so the row is a WARN `no journal` (M1);
#   - a `running` probe is a WARN until its lease expires (last heartbeat +
#     `stall_limit_s`); past the expiry the driver runs exactly one takeover
#     `start` (spec § Q1a, M12);
#   - the probe proves agent + journal + spawn only. The probe command's own
#     exit code is not journaled (spec § Q1c, a control-plane follow-up), so the
#     driver never parses probe-command output.
#
# Never sudo, never su, never pkexec (AC4). units.sh owns that guard and the
# command funnel (`cp_run`) every external command goes through here.
#
# Environment:
#   CP_CHECKOUT_ROOT / CP_BIN_DIR / CP_UNIT_DIR / CP_IMAGE  units.sh knobs
#   DEVTEAM_CP_MROOT / DEVTEAM_CP_WSLCONF / DEVTEAM_CP_NODE_JSON
#   DEVTEAM_CP_IMAGE / DEVTEAM_CP_DOCKER_TIMEOUT            preflight.sh knobs
#   DEVTEAM_RUN_DB / DEVTEAM_MROOT / DEVTEAM_RUNNER         the service's own
#               (DEVTEAM_RUNNER is read by preflight and set on the probe child
#               only — never exported, never written to node.json)
#   CP_PROBE_COMMAND      the no-op the probe spawns (default `true`)
#   CP_HTTP_URL / CP_HTTP_TIMEOUT / CP_HTTP_WAIT            the chiefd API row
#   CP_DOCKER_PS_TIMEOUT  the leftover-container probe
#
# Hermetic suite: skills/control-plane/test.sh.

set -euo pipefail

CP_SETUP_DIR=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
CP_SETUP_LIB=$(CDPATH= cd -- "$CP_SETUP_DIR/../lib" && pwd)
# shellcheck source=../lib/portable.sh
. "$CP_SETUP_LIB/portable.sh"
# shellcheck source=../lib/record-status.sh
. "$CP_SETUP_LIB/record-status.sh"
# shellcheck source=preflight.sh
. "$CP_SETUP_DIR/preflight.sh"
# shellcheck source=units.sh
. "$CP_SETUP_DIR/units.sh"

# The fixed probe run id (SPEC-043 M11). Every branch of the probe flow keys on
# it; a second run id would spawn a second supervised run on the node.
CP_PROBE_RUN_ID='devteam-setup-probe'
CP_PROBE_COMMAND="${CP_PROBE_COMMAND:-true}"
# T0 § Q1a: an expired lease is the only state a re-start may act on, and the
# default tier's stall limit is the 108 s the WARN row quotes.
CP_PROBE_LEASE_LIMIT_DEFAULT=108
CP_HTTP_URL="${CP_HTTP_URL:-http://127.0.0.1:8090/v1/runs}"
CP_HTTP_TIMEOUT="${CP_HTTP_TIMEOUT:-5}"
CP_HTTP_WAIT="${CP_HTTP_WAIT:-10}"
CP_DOCKER_PS_TIMEOUT="${CP_DOCKER_PS_TIMEOUT:-10}"

CP_MODE='install'
CP_VERIFY_MODE='install'
CP_VERIFY_STOP=0
# The probe state the rows branch on, filled by cp_state_read.
CP_STATE_STATUS=''
CP_STATE_TERMINAL=0
CP_STATE_ERR=''
CP_STATE_OWNER=''
CP_STATE_TOKEN=''
CP_STATE_HEARTBEAT=''
CP_STATE_LIMIT=''
# cp_probe_start fills these for the hygiene row.
CP_PROBE_START_RC=''
CP_PROBE_START_OUT=''

# ---------------------------------------------------------------------------
# Usage and dispatch (SPEC-043 M1)
# ---------------------------------------------------------------------------

cp_usage() {
  cat <<'EOF'
Usage: setup.sh [--status | --uninstall] [-h|--help]      (bare = install)

  (bare)        preflight, build in the approved image, install both binaries
                and the chiefd systemd user unit, enable it, print the verify
                table
  --status      the verify table only: read-only, no build, no probe start
  --uninstall   stop, disable, and remove the unit, remove both binaries,
                reload and reset failed units (Linux side only); the run
                journal is never touched; the Windows-side removal steps are
                printed for the operator
  -h, --help    this text

Exit: 0 = PASS/WARN rows only · 2 = any FAIL row · 63 = unsupported platform
(only Linux with a systemd user manager; WSL2 needs [boot] systemd=true) ·
64 = usage error. Never sudo: every write target is under $HOME.
EOF
}

cp_parse_args() {
  local seen=''
  while [ $# -gt 0 ]; do
    case "$1" in
      --status | --uninstall)
        if [ -n "$seen" ]; then
          printf 'control-plane: %s cannot be combined with %s — one mode per run (SPEC-043 M1)\n' "$seen" "$1" >&2
          return 64
        fi
        seen="$1"
        [ "$1" = '--status' ] && CP_MODE='status'
        [ "$1" = '--uninstall' ] && CP_MODE='uninstall'
        shift
        ;;
      -h | --help)
        CP_MODE='help'
        shift
        ;;
      *)
        printf 'control-plane: unknown argument: %s\n' "$1" >&2
        return 64
        ;;
    esac
  done
  return 0
}

# ---------------------------------------------------------------------------
# Small shared helpers
# ---------------------------------------------------------------------------
# Trim and lowercase have one home: cp_pf_trim / cp_pf_lower in preflight.sh
# (sourced above), the same process this driver runs in.

cp_row_guard() {
  # cp_row_guard <id> — rc 1 when the operator answered skip (SPEC-043 M10);
  # the row is recorded as SKIP by this helper.
  if [ "$CP_VERIFY_STOP" -eq 1 ]; then
    record_status "$1" 'controlplane' 'SKIP' 'skipped by the operator (SPEC-043 M10)' '' || return 1
    return 1
  fi
  return 0
}

cp_row_absent() {
  # cp_row_absent <id> <detail> <fixit> — "the service is not there" readings.
  # FAIL after an install (the install promised it); WARN for --status, where an
  # uninstalled node is a supported state — the service is opt-in (SPEC-022 M3).
  local st='FAIL'
  if [ "$CP_VERIFY_MODE" = 'status' ]; then
    st='WARN'
  fi
  record_status "$1" 'controlplane' "$st" "$2" "$3" || return 1
  return 0
}

cp_json_field() {
  # cp_json_field <key> <json> — the first scalar value stored under "key".
  # jq when present; the awk fallback scans for the key and stops at the first
  # hit, so a nested key of the same name never wins.
  local key="$1" json="${2-}"
  [ -n "$json" ] || return 0
  if command -v jq >/dev/null 2>&1; then
    printf '%s' "$json" | jq -r --arg k "$key" '.[$k] | if . == null then "" else . end' 2>/dev/null \
      || printf ''
    return 0
  fi
  printf '%s' "$json" | awk -v key="$key" '
    {
      pat = "\"" key "\":"
      p = index($0, pat)
      if (p == 0) next
      rest = substr($0, p + length(pat))
      sub(/^[ \t]*/, "", rest)
      if (substr(rest, 1, 1) == "\"") {
        rest = substr(rest, 2)
        q = index(rest, "\"")
        if (q == 0) next
        print substr(rest, 1, q - 1)
      } else {
        e = length(rest) + 1
        c = index(rest, ",")
        if (c > 0 && c < e) e = c
        c = index(rest, "}")
        if (c > 0 && c < e) e = c
        c = index(rest, " ")
        if (c > 0 && c < e) e = c
        v = substr(rest, 1, e - 1)
        gsub(/[ \t\r]/, "", v)
        print v
      }
      exit
    }'
}

# ---------------------------------------------------------------------------
# The preflight walk (SPEC-043 M2)
# ---------------------------------------------------------------------------

cp_preflight_readonly() {
  # The read-only half of M2 — (a)(b)(c)(d)(g) — for --status. The build gates
  # (e) docker and (f) the image pin are refused by an install only: a status
  # read starts no build. The checks themselves are T1's registered functions,
  # in T1's order.
  CP_PLATFORM=''
  CP_RUNNER=''
  CP_RUNNER_SOURCE=''
  CP_IMAGE=''
  CP_MROOT=''
  cp_pf_platform || return $?
  cp_pf_systemd || return $?
  if [ "$CP_PLATFORM" = 'wsl2' ]; then
    cp_pf_wsl_conf || return $?
  fi
  cp_pf_checkout || return $?
  cp_pf_runner || return $?
  return 0
}

# ---------------------------------------------------------------------------
# The journal CLI and the probe (SPEC-043 M11/M12, AC11/AC13)
# ---------------------------------------------------------------------------

cp_dist_bin() {
  # cp_dist_bin <service> — the ONLY way this driver names a service CLI:
  # control-plane/dist/<name>, never a PATH name (SPEC-043 AC11/M11).
  printf '%s/control-plane/dist/%s\n' "$CP_MROOT" "$1"
}

cp_probe_db() {
  printf '%s\n' "${DEVTEAM_RUN_DB:-$CP_MROOT/.claude/runs/run.db}"
}

cp_probe_pidfile() {
  # The agent writes its pidfile under $MROOT/.claude/runs/agent/, and the
  # service resolves $MROOT as $DEVTEAM_MROOT, else the git parent.
  printf '%s/.claude/runs/agent/%s.pid\n' "${DEVTEAM_MROOT:-$CP_MROOT}" "$CP_PROBE_RUN_ID"
}

cp_build_journal() {
  # journalctl is verify plumbing, never an install target (AC11), so it is not
  # in CP_SERVICES. Build it on demand; a present binary is left alone (M12:
  # the second run rebuilds nothing and stays silent).
  local root="$CP_MROOT" saved rc=0
  if [ -x "$root/control-plane/dist/journalctl" ]; then
    printf 'built: control-plane/dist/journalctl (present — not rebuilt, SPEC-043 M12)\n'
    return 0
  fi
  if [ ! -d "$root/control-plane/cmd/journalctl" ]; then
    printf 'control-plane: no control-plane/cmd/journalctl — the journal CLI cannot be built (SPEC-043 AC5).\n' >&2
    return 2
  fi
  saved=$CP_SERVICES
  CP_SERVICES='journalctl'
  if cp_build "$root"; then rc=0; else rc=$?; fi
  CP_SERVICES=$saved
  return "$rc"
}

cp_state_read() {
  # Reads the fixed probe run's state through the journal CLI.
  # rc 0 = state read · rc 1 = the run has no rows · rc 2 = unreadable
  # rc 3 = no journal database at all (the file is absent, so the read is
  # skipped: journalctl.OpenPath creates a database it is only asked to read,
  # and --status MUST NOT write — SPEC-043 M1)
  local bin err db rc=0 val
  CP_STATE_STATUS=''
  CP_STATE_TERMINAL=0
  CP_STATE_ERR=''
  CP_STATE_OWNER=''
  CP_STATE_TOKEN=''
  CP_STATE_HEARTBEAT=''
  CP_STATE_LIMIT=''
  bin=$(cp_dist_bin journalctl)
  if [ ! -x "$bin" ]; then
    CP_STATE_ERR="no journal CLI at $bin"
    return 2
  fi
  db=$(cp_probe_db)
  if [ ! -f "$db" ]; then
    CP_STATE_ERR="no journal database at $db"
    return 3
  fi
  err=$(mktemp "${TMPDIR:-/tmp}/cp-journal-err.XXXXXX") || return 2
  val=''
  if val=$(cp_run "$bin" read --run-id "$CP_PROBE_RUN_ID" --state --db "$db" 2>"$err"); then
    rc=0
  else
    rc=$?
  fi
  if [ "$rc" -ne 0 ]; then
    if grep -qF -e 'no events for run' "$err" 2>/dev/null; then
      rm -f -- "$err"
      return 1
    fi
    CP_STATE_ERR=$(head -n 1 "$err" 2>/dev/null) || CP_STATE_ERR=''
    rm -f -- "$err"
    return 2
  fi
  rm -f -- "$err"
  CP_STATE_STATUS=$(cp_json_field status "$val")
  if [ "$(cp_json_field terminal "$val")" = 'true' ]; then
    CP_STATE_TERMINAL=1
  fi
  CP_STATE_OWNER=$(cp_json_field owner "$val")
  CP_STATE_TOKEN=$(cp_json_field token "$val")
  CP_STATE_HEARTBEAT=$(cp_json_field last_heartbeat_ts "$val")
  CP_STATE_LIMIT=$(cp_json_field stall_limit_s "$val")
  return 0
}

cp_probe_runner() {
  # The M11 override value: the M2(g) resolved selection, `native` when the node
  # names none — the agent's fail-closed read starts no run on a node with no
  # selection, so an unoverridden probe can never pass on a fresh node.
  case "${CP_RUNNER:-}" in
    native | container) printf '%s\n' "$CP_RUNNER" ;;
    *) printf 'native\n' ;;
  esac
}

cp_probe_start() {
  # SPEC-043 M11 (T0 ruling Q1b): `start` only. There is deliberately no
  # `stop --run-id devteam-setup-probe` anywhere in this driver, and there must
  # never be one: it poisons the fixed id (spec § Q1b).
  local bin rc=0 runner
  bin=$(cp_dist_bin node-agent)
  CP_PROBE_START_RC=''
  CP_PROBE_START_OUT=''
  if [ ! -x "$bin" ]; then
    CP_PROBE_START_OUT="no node agent at $bin"
    CP_PROBE_START_RC=127
    return 1
  fi
  runner=$(cp_probe_runner)
  # The assignment lives inside the command substitution's subshell, so
  # $DEVTEAM_RUNNER reaches this child process and nothing else: the driver
  # never exports it and never writes node.json (SPEC-043 M11, AC6, MUST NOT).
  if CP_PROBE_START_OUT=$(
    DEVTEAM_RUNNER="$runner"
    export DEVTEAM_RUNNER
    cp_run "$bin" start \
      --run-id "$CP_PROBE_RUN_ID" --command "$CP_PROBE_COMMAND" --db "$(cp_probe_db)" 2>&1
  ); then
    rc=0
  else
    rc=$?
  fi
  CP_PROBE_START_RC=$rc
  return "$rc"
}

cp_probe_lease_line() {
  # The WARN detail for a running probe: the fixed id is claimed, so the driver
  # waits for the lease (last heartbeat + stall limit) instead of a second
  # start (SPEC-043 M12, spec § Q1a).
  local limit="$CP_STATE_LIMIT" owner="$CP_STATE_OWNER"
  case "$limit" in
    '' | *[!0-9]*) limit=$CP_PROBE_LEASE_LIMIT_DEFAULT ;;
  esac
  printf 'the probe run is already running (lease owner %s token %s, last heartbeat %s): the driver never runs a second start. retry after lease expiry ~%s s (SPEC-043 M12)\n' \
    "${owner:-unknown}" "${CP_STATE_TOKEN:-0}" "${CP_STATE_HEARTBEAT:-unknown}" "$limit"
}

cp_epoch_from_ts() {
  # cp_epoch_from_ts <rfc3339> -> epoch seconds on stdout. GNU date first, then
  # the BSD/macOS form (host portability). rc 1 = this shape cannot be dated.
  # CDT-620 T4: BSD `-j -f FMT INPUT` matches INPUT against FMT literally, so the
  # format must carry the trailing Z only when the input keeps it. The old form
  # stripped the Z from the input and kept it in the format, so every journal
  # timestamp read as undatable on macOS — and an undatable lease is an expired
  # lease (cp_probe_lease_expired), which started a second probe.
  local ts="$1" base fmt
  case "$1" in
    '' | *[!0-9T:.Z+-]*) return 1 ;;
  esac
  if date -u -d "$ts" +%s 2>/dev/null; then
    return 0
  fi
  base="$ts"
  fmt='%Y-%m-%dT%H:%M:%SZ'
  case "$base" in
    *Z)
      base="${base%Z}"
      case "$base" in
        *.*) base="${base%%.*}" ;;
      esac
      base="$base"Z
      ;;
    *[+-][0-9][0-9]:[0-9][0-9])
      base=${base%%[+-][0-9][0-9]:[0-9][0-9]}
      case "$base" in
        *.*) base=${base%%.*} ;;
      esac
      fmt='%Y-%m-%dT%H:%M:%S'
      ;;
    *) return 1 ;;
  esac
  if date -u -j -f "$fmt" "$base" +%s 2>/dev/null; then
    return 0
  fi
  return 1
}

cp_probe_lease_expired() {
  # SPEC-043 M12: expired = more than stall_limit_s passed since the last
  # heartbeat. A lease the state read cannot date counts as expired, matching
  # run.Lease.Expired (control-plane/run/lease.go) — an owner that cannot prove
  # liveness never blocks the takeover.
  local hb limit now
  hb=$(cp_epoch_from_ts "${CP_STATE_HEARTBEAT:-}") || return 0
  limit="$CP_STATE_LIMIT"
  case "$limit" in
    '' | *[!0-9]*) limit=$CP_PROBE_LEASE_LIMIT_DEFAULT ;;
  esac
  now=$(date +%s)
  [ $((now - hb)) -gt "$limit" ]
}

# ---------------------------------------------------------------------------
# The verify rows (SPEC-043 M6)
# ---------------------------------------------------------------------------

cp_row_unit() {
  # cp_row_unit <service> — the unit is-active row (AC1). Phase 1 ships the
  # chiefd unit only (SPEC-043 M5), so this row has one caller.
  local svc="$1" id="controlplane.units" unit state enabled rc=0
  unit=$(cp_unit_name "$svc")
  id="$id.$svc"
  cp_row_guard "$id" || return 0
  if ! command -v systemctl >/dev/null 2>&1; then
    record_status "$id" 'controlplane' 'WARN' \
      'systemctl is not on PATH — the unit state is unreadable' \
      'Linux with a systemd user manager is the only supported platform (SPEC-043 M2(b))' || return 0
    return 0
  fi
  if state=$(cp_systemctl is-active "$unit" 2>/dev/null); then rc=0; else rc=$?; fi
  state=$(cp_pf_trim "$state")
  # is-enabled exits non-zero for a disabled unit, so the read is guarded: an
  # unguarded assignment would trip errexit on the answer the row expects.
  enabled=$(cp_systemctl is-enabled "$unit" 2>/dev/null) || enabled=''
  enabled=$(cp_pf_trim "${enabled%%$'\n'*}")
  case "$state" in
    active)
      if [ "$enabled" = 'enabled' ]; then
        record_status "$id" 'controlplane' 'PASS' \
          "unit $unit is active and enabled (SPEC-043 M5)" '' || return 0
      else
        record_status "$id" 'controlplane' 'WARN' \
          "unit $unit is active but ${enabled:-not enabled} — it will not return after a reboot" \
          "systemctl --user enable --now $unit" || return 0
      fi
      return 0
      ;;
    activating)
      cp_row_absent "$id" "unit $unit is still activating" "systemctl --user status $unit" || return 0
      return 0
      ;;
  esac
  cp_row_absent "$id" \
    "unit $unit is ${state:-unreadable} (is-active exit $rc)" \
    "systemctl --user status $unit — then run: /setup control-plane" || return 0
  return 0
}

cp_row_node_agent() {
  # The node agent binary row (SPEC-043 M6, AC1): the INSTALLED binary
  # (%h/.local/bin/node-agent, M3) answers `status-node` with exit 0. Phase 1
  # gives it no unit (M5 — the T8 replan: the verbs are
  # start|stop|status|steer|status-node, so a supervised ExecStart exits at
  # once), so the row invokes the binary by path and never asks systemd about
  # it. control-plane/dist/ is build output, never an install target, so a node
  # that has only that copy is a WARN that names the install path.
  local id='controlplane.node-agent' bin dist out rc=0
  cp_row_guard "$id" || return 0
  bin=$(cp_bin_path node-agent)
  if [ ! -x "$bin" ]; then
    dist=$(cp_dist_bin node-agent)
    if [ -x "$dist" ]; then
      cp_row_absent "$id" \
        "the installed node agent is absent: $bin (the build output $dist is not the install target, SPEC-043 M3/M6)" \
        "run: /setup control-plane (it installs the binary at $bin)" || return 0
      return 0
    fi
    cp_row_absent "$id" \
      "no node agent binary at $bin — nothing to invoke (SPEC-043 M6)" \
      'run: /setup control-plane (it builds and installs the node agent)' || return 0
    return 0
  fi
  if out=$(cp_run "$bin" status-node 2>&1); then rc=0; else rc=$?; fi
  if [ "$rc" -eq 0 ]; then
    record_status "$id" 'controlplane' 'PASS' \
      "node-agent status-node answers 0 (the installed binary, invoked by path, no unit — SPEC-043 M5/M6)" '' || return 0
    return 0
  fi
  cp_row_absent "$id" \
    "node-agent status-node exited $rc: $(cp_pf_trim "${out%%$'\n'*}")" \
    "read the node: $bin status-node — then run: /setup control-plane" || return 0
  return 0
}

cp_row_chiefd_http() {
  # The chiefd API row: an HTTP GET against the /v1 API on loopback
  # (SPEC-043 M6). A fresh unit needs a moment, so the probe retries inside a
  # deadline; --status reads once. Verify never restarts a unit (plan Risk).
  local deadline tool='' body rc=0 tries=1 i=0
  cp_row_guard 'controlplane.chiefd.api' || return 0
  if command -v curl >/dev/null 2>&1; then
    tool='curl'
  elif command -v wget >/dev/null 2>&1; then
    tool='wget'
  else
    record_status 'controlplane.chiefd.api' 'controlplane' 'WARN' \
      "no HTTP client on PATH — $CP_HTTP_URL is unreadable" \
      'install curl (this command never elevates), then re-run' || return 0
    return 0
  fi
  if [ "$CP_VERIFY_MODE" = 'install' ]; then
    tries=$CP_HTTP_WAIT
  fi
  deadline=$(( $(date +%s) + CP_HTTP_WAIT ))
  while [ "$i" -lt "$tries" ]; do
    i=$((i + 1))
    if [ "$tool" = 'curl' ]; then
      if body=$(curl -fsS -m "$CP_HTTP_TIMEOUT" -o /dev/null -w '%{http_code}' "$CP_HTTP_URL" 2>&1); then rc=0; else rc=$?; fi
    else
      if body=$(wget -q -T "$CP_HTTP_TIMEOUT" -t 1 -O /dev/null "$CP_HTTP_URL" 2>&1); then rc=0; else rc=$?; fi
    fi
    if [ "$rc" -eq 0 ]; then
      record_status 'controlplane.chiefd.api' 'controlplane' 'PASS' \
        "chiefd answers on $CP_HTTP_URL (HTTP ${body:-200}) — loopback only (SPEC-043 AC13)" '' || return 0
      return 0
    fi
    if [ "$(date +%s)" -ge "$deadline" ]; then
      break
    fi
    sleep 1
  done
  cp_row_absent 'controlplane.chiefd.api' \
    "chiefd does not answer on $CP_HTTP_URL (exit $rc: $(cp_pf_trim "${body%%$'\n'*}"))" \
    "systemctl --user status $(cp_unit_name chiefd) — then run: /setup control-plane" || return 0
  return 0
}

cp_service_cli() {
  # The host CLI the native runner spawns: node.json's command key when the node
  # names one, else the probe command (the driver's no-op default). A value with
  # whitespace is not a CLI name and falls back the same way.
  local json="${DEVTEAM_CP_NODE_JSON:-$CP_MROOT/.claude/dev-team/node.json}" name=''
  if [ -r "$json" ]; then
    name=$(cp_json_field command "$(cat "$json" 2>/dev/null)")
  fi
  name=$(cp_pf_trim "$name")
  case "$name" in
    '' | *[[:space:]]*) name="$CP_PROBE_COMMAND" ;;
  esac
  printf '%s\n' "$name"
}

cp_row_chiefd_journal() {
  # CDT-666: the board chiefd serves is the project's journal. chiefd opens
  # $DEVTEAM_MROOT/.claude/runs/run.db; an unstamped unit resolves $HOME and
  # serves an empty store beside the project's (the CDT-659 validation shape).
  # The proof is the fixed probe run: the install journaled it into
  # $MROOT/.claude/runs/run.db, so a board that names it is that journal.
  local id='controlplane.chiefd.journal' tool='' body='' rc=0 db
  cp_row_guard "$id" || return 0
  if command -v curl >/dev/null 2>&1; then
    tool='curl'
  elif command -v wget >/dev/null 2>&1; then
    tool='wget'
  else
    record_status "$id" 'controlplane' 'WARN' \
      "no HTTP client on PATH — $CP_HTTP_URL is unreadable" \
      'install curl (this command never elevates), then re-run' || return 0
    return 0
  fi
  db="${DEVTEAM_MROOT:-$CP_MROOT}/.claude/runs/run.db"
  if [ "$tool" = 'curl' ]; then
    if body=$(curl -fsS -m "$CP_HTTP_TIMEOUT" "$CP_HTTP_URL" 2>&1); then rc=0; else rc=$?; fi
  else
    if body=$(wget -q -T "$CP_HTTP_TIMEOUT" -t 1 -O - "$CP_HTTP_URL" 2>&1); then rc=0; else rc=$?; fi
  fi
  if [ "$rc" -ne 0 ]; then
    cp_row_absent "$id" \
      "GET $CP_HTTP_URL failed (exit $rc): $(cp_pf_trim "${body%%$'\n'*}")" \
      "systemctl --user status $(cp_unit_name chiefd) — then run: /setup control-plane" || return 0
    return 0
  fi
  if printf '%s' "$body" | grep -qF -e "\"run_id\":\"$CP_PROBE_RUN_ID\""; then
    record_status "$id" 'controlplane' 'PASS' \
      "the served journal is the project's — GET $CP_HTTP_URL answers the probe run from $db (SPEC-043 M5, CDT-666)" '' || return 0
    return 0
  fi
  cp_row_absent "$id" \
    "GET $CP_HTTP_URL answers no $CP_PROBE_RUN_ID row — chiefd serves a journal that is not $db" \
    "the unit must carry Environment=\"DEVTEAM_MROOT=$CP_MROOT\" and WorkingDirectory=$CP_MROOT — then run: /setup control-plane" || return 0
  return 0
}

cp_row_service_env() {
  # CDT-666: the env the unit stamped. chiefd resolves its journal and its plugin
  # root from $DEVTEAM_MROOT, and the native runner spawns the host CLI by name
  # through the service PATH — the systemd user default misses the user CLI dirs,
  # so an unstamped unit refuses with `executable file not found in $PATH`.
  local id='controlplane.chiefd.env' unit envline='' rc=0 mroot_want pathval='' cli resolved=''
  cp_row_guard "$id" || return 0
  if ! command -v systemctl >/dev/null 2>&1; then
    record_status "$id" 'controlplane' 'WARN' \
      'systemctl is not on PATH — the service env is unreadable' \
      'Linux with a systemd user manager is the only supported platform (SPEC-043 M2(b))' || return 0
    return 0
  fi
  unit=$(cp_unit_name chiefd)
  if envline=$(cp_systemctl show "$unit" -p Environment 2>&1); then rc=0; else rc=$?; fi
  if [ "$rc" -ne 0 ]; then
    cp_row_absent "$id" \
      "systemctl --user show $unit -p Environment failed (exit $rc): $(cp_pf_trim "${envline%%$'\n'*}")" \
      "systemctl --user status $unit — then run: /setup control-plane" || return 0
    return 0
  fi
  envline=$(printf '%s\n' "$envline" | sed -n 's/^Environment=//p' | head -n 1)
  mroot_want="${DEVTEAM_MROOT:-$CP_MROOT}"
  case "$envline" in
    *"DEVTEAM_MROOT=$mroot_want"*) ;;
    *)
      cp_row_absent "$id" \
        "the service env carries no DEVTEAM_MROOT=$mroot_want (Environment=${envline:-empty}) — the journal and the plugin root resolve outside the project" \
        'run: /setup control-plane — the unit stamps WorkingDirectory and Environment="DEVTEAM_MROOT" (SPEC-043 M5, CDT-666)' || return 0
      return 0
      ;;
  esac
  pathval=$(printf '%s' "$envline" | sed -n 's/.*PATH=\([^ ]*\).*/\1/p')
  if [ -z "$pathval" ]; then
    cp_row_absent "$id" \
      'the service env carries no PATH — the runner spawn gets the systemd user default' \
      'run: /setup control-plane — the unit stamps the user CLI dirs that exist (CDT-666)' || return 0
    return 0
  fi
  cli=$(cp_service_cli)
  # The CLI name reaches bash as argv, never as code (AGENTS.md: untrusted input
  # is never code), so the lookup reads the way the service's exec does.
  if resolved=$(cp_run env "PATH=$pathval" bash -c 'command -v -- "$1"' _ "$cli" 2>/dev/null) && [ -n "$resolved" ]; then
    record_status "$id" 'controlplane' 'PASS' \
      "the service env carries DEVTEAM_MROOT and PATH=$pathval — the host CLI $cli resolves at $resolved (SPEC-043 M5, CDT-666)" '' || return 0
    return 0
  fi
  cp_row_absent "$id" \
    "the host CLI $cli does not resolve in the service PATH ($pathval) — the native spawn refuses with: executable file not found in \$PATH" \
    'run: /setup control-plane — it stamps every user CLI dir that exists into the unit PATH (CDT-666)' || return 0
  return 0
}

cp_row_probe() {
  # The probe row: the journal state of the fixed run id, never
  # `node-agent status` rc alone (spec § Q1a — status answers 0 for a run that
  # never existed).
  local rc=0 st
  cp_row_guard 'controlplane.probe' || return 0
  if cp_state_read; then
    rc=0
  else
    rc=$?
  fi
  case "$rc" in
    2)
      cp_row_absent 'controlplane.probe' \
        "the probe state is unreadable: ${CP_STATE_ERR:-the journal CLI failed}" \
        'run: /setup control-plane (it builds control-plane/dist/journalctl)' || return 0
      CP_PROBE_START_RC='unreadable'
      return 0
      ;;
    1 | 3)
      # rc 1: the fixed id has no rows. rc 3: there is no journal database, so
      # the read was skipped — the journal CLI creates a database on open and
      # --status writes nothing (SPEC-043 M1).
      if [ "$CP_VERIFY_MODE" = 'status' ]; then
        if [ "$rc" -eq 3 ]; then
          cp_row_absent 'controlplane.probe' \
            "${CP_STATE_ERR:-no journal database} — a fresh node has no probe to report (--status creates nothing, SPEC-043 M1)" \
            'run: /setup control-plane (the install runs the probe)' || return 0
        else
          cp_row_absent 'controlplane.probe' \
            "no probe run in the journal — the fixed id $CP_PROBE_RUN_ID has no rows" \
            'run: /setup control-plane (the install runs the probe)' || return 0
        fi
        CP_PROBE_START_RC='not-run'
        return 0
      fi
      cp_probe_start || :
      if [ "$CP_PROBE_START_RC" != '0' ]; then
        cp_row_absent 'controlplane.probe' \
          "node-agent start refused (exit ${CP_PROBE_START_RC:-?}): $(cp_pf_trim "${CP_PROBE_START_OUT%%$'\n'*}")" \
          'a terminal id, a live lease, and a halt state each refuse a start — read it: control-plane/dist/journalctl read --run-id --state' \
          || return 0
        record_status 'controlplane.probe.fix' 'controlplane' 'WARN' \
          'never run node-agent stop against the fixed probe id' \
          'a stop lands the id in halted:operator_halt, which the agent never resumes (SPEC-043 M11, spec § Q1b)' || return 0
        return 0
      fi
      # start finished: the trivial command completes inside start (spec § Q1).
      if cp_state_read; then
        rc=0
      else
        rc=$?
      fi
      if [ "$rc" -ne 0 ]; then
        cp_row_absent 'controlplane.probe' \
          "the probe started, but its journal state is unreadable: ${CP_STATE_ERR:-no answer}" \
          'run: /setup control-plane' || return 0
        return 0
      fi
      ;;
  esac
  st="$CP_STATE_STATUS"
  if [ "$st" = 'running' ] && [ "$CP_VERIFY_MODE" = 'install' ] && cp_probe_lease_expired; then
    # SPEC-043 M12, spec § Q1a: the lease is past last heartbeat +
    # stall_limit_s, so its owner is dead and the takeover start is allowed —
    # exactly one, which acquires the lease and closes the pending intent
    # (one run, not two). There is still no `stop` (spec § Q1b).
    record_status 'controlplane.probe.lease' 'controlplane' 'WARN' \
      "the probe lease is dead (owner ${CP_STATE_OWNER:-unknown}, last heartbeat ${CP_STATE_HEARTBEAT:-unreadable}, stall limit ${CP_STATE_LIMIT:-$CP_PROBE_LEASE_LIMIT_DEFAULT} s) — running the takeover start (SPEC-043 M12)" \
      'read it: control-plane/dist/journalctl read --run-id devteam-setup-probe --events' || return 0
    cp_probe_start || :
    if [ "$CP_PROBE_START_RC" = '0' ] && ! cp_state_read; then
      cp_row_absent 'controlplane.probe' \
        "the takeover start ran, but its journal state is unreadable: ${CP_STATE_ERR:-no answer}" \
        'run: /setup control-plane' || return 0
      return 0
    fi
    st="$CP_STATE_STATUS"
  fi
  if [ "$CP_STATE_TERMINAL" -eq 1 ]; then
    if [ "$st" = 'completed' ]; then
      record_status 'controlplane.probe' 'controlplane' 'PASS' \
        "probe run $CP_PROBE_RUN_ID: journal state completed (agent + journal + spawn proven; no second start — SPEC-043 M12)" '' || return 0
      return 0
    fi
    cp_row_absent 'controlplane.probe' \
      "probe run $CP_PROBE_RUN_ID is terminal in state '${st:-unknown}'" \
      'read the run: control-plane/dist/journalctl read --run-id --events' || return 0
    return 0
  fi
  if [ "$st" = 'running' ]; then
    record_status 'controlplane.probe' 'controlplane' 'WARN' \
      "$(cp_probe_lease_line)" \
      "read it: control-plane/dist/journalctl read --run-id $CP_PROBE_RUN_ID --state" || return 0
    CP_PROBE_START_RC='not-started'
    return 0
  fi
  cp_row_absent 'controlplane.probe' \
    "probe run $CP_PROBE_RUN_ID reads journal state '${st:-unknown}', not completed" \
    'read it: control-plane/dist/journalctl read --run-id --state' || return 0
  return 0
}

cp_row_hygiene() {
  # AC13: after `start` returns, no runner process, no pidfile, no container.
  # The completion path reaps the child and removes the pidfile (spec § Q1b).
  local pf pid rc=0 names s1='PASS' s2='PASS' detail=''
  cp_row_guard 'controlplane.probe.hygiene' || return 0
  # The condition is a property of the node, so it is checked after this run
  # started the probe and on the idempotent path (a terminal probe id) alike —
  # SPEC-043 M12 asks the second run for the same verdict as the first.
  if [ "$CP_PROBE_START_RC" != '0' ] && [ "$CP_STATE_TERMINAL" -ne 1 ]; then
    record_status 'controlplane.probe.hygiene' 'controlplane' 'SKIP' \
      'no hygiene check — this run did not start the probe (SPEC-043 AC13)' '' || return 0
    return 0
  fi
  pf=$(cp_probe_pidfile)
  if [ -e "$pf" ]; then
    pid=$(cp_pf_trim "$(head -n 1 "$pf" 2>/dev/null)")
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
      s1='FAIL'
      detail="the probe runner is still alive (pid $pid, pidfile $pf)"
    else
      s1='WARN'
      detail="a stale pidfile survived the probe: $pf (pid ${pid:-unreadable} is not live)"
    fi
  fi
  if command -v docker >/dev/null 2>&1; then
    if names=$(portable_with_timeout "$CP_DOCKER_PS_TIMEOUT" docker ps --format '{{.Names}}' 2>/dev/null); then
      rc=0
    else
      rc=$?
    fi
    if [ "$rc" -ne 0 ]; then
      s2='WARN'
      detail="${detail:+$detail; }docker ps answered nothing (exit $rc) — no container check"
    elif printf '%s\n' "$names" | grep -qF -- "$CP_PROBE_RUN_ID" 2>/dev/null; then
      s2='FAIL'
      detail="${detail:+$detail; }a container named for the probe run is still up"
    fi
  fi
  if [ "$s1" = 'PASS' ] && [ "$s2" = 'PASS' ]; then
    record_status 'controlplane.probe.hygiene' 'controlplane' 'PASS' \
      "no leftover runner process, pidfile, or container for $CP_PROBE_RUN_ID (SPEC-043 AC13)" '' || return 0
    return 0
  fi
  if [ "$s1" = 'FAIL' ] || [ "$s2" = 'FAIL' ]; then
    cp_row_absent 'controlplane.probe.hygiene' \
      "$detail" \
      "read it: control-plane/dist/journalctl read --run-id $CP_PROBE_RUN_ID --events" || return 0
    return 0
  fi
  # A hygiene condition that only removes evidence (a stale pidfile, an
  # unreadable docker ps) is WARN: the run is not proven dirty (SPEC-022 M3).
  record_status 'controlplane.probe.hygiene' 'controlplane' 'WARN' \
    "$detail" \
    "read it: control-plane/dist/journalctl read --run-id $CP_PROBE_RUN_ID --events" || return 0
  return 0
}

cp_row_runner() {
  # AC6: the resolved runner selection, read-only. This row never writes
  # node.json or $DEVTEAM_RUNNER (SPEC-043 MUST NOT).
  cp_row_guard 'controlplane.runner' || return 0
  if [ -z "$CP_RUNNER" ]; then
    record_status 'controlplane.runner' 'controlplane' 'WARN' \
      'the runner selection is unresolved' \
      'set the runner key to native or container in .claude/dev-team/node.json (SPEC-043 M2(g))' || return 0
    return 0
  fi
  record_status 'controlplane.runner' 'controlplane' 'PASS' \
    "runner=$CP_RUNNER (source: $CP_RUNNER_SOURCE) — read-only, never written (SPEC-043 AC6)" '' || return 0
  return 0
}

cp_row_linger() {
  # SPEC-043 M10 / AC10: print the exact enable-linger line and take the
  # operator answer. This command never executes sudo.
  local user val rc=0 out
  cp_row_guard 'controlplane.linger' || return 0
  user=${USER:-}
  if [ -z "$user" ]; then
    user=$(id -un 2>/dev/null) || user=''
  fi
  if ! command -v loginctl >/dev/null 2>&1; then
    record_status 'controlplane.linger' 'controlplane' 'WARN' \
      'loginctl is not available — the linger state is unreadable' \
      'install systemd, then re-run (SPEC-043 M10)' || return 0
    return 0
  fi
  if out=$(loginctl show-user "${user:-current}" -p Linger 2>/dev/null); then rc=0; else rc=$?; fi
  if [ "$rc" -ne 0 ]; then
    record_status 'controlplane.linger' 'controlplane' 'WARN' \
      "loginctl show-user '${user:-current}' -p Linger failed (exit $rc)" \
      "start the systemd user manager, then re-run (SPEC-043 M10)" || return 0
    return 0
  fi
  # T0 § Q2: one `Key=value` line, no leading whitespace.
  val=$(cp_pf_lower "$(cp_pf_trim "$(printf '%s\n' "$out" | sed -n 's/^Linger=//p' | head -n 1)")")
  case "$val" in
    yes | 1 | true)
      record_status 'controlplane.linger' 'controlplane' 'PASS' \
        'linger is on — the user units outlive the login session (SPEC-043 M10)' '' || return 0
      return 0
      ;;
    no | 0 | false)
      record_status 'controlplane.linger' 'controlplane' 'WARN' \
        "linger is off for ${user:-current}: the user units stop when the login session ends" \
        "sudo loginctl enable-linger \"${user:-current}\" (the operator runs this — SPEC-043 M10)" || return 0
      cp_ask_linger || return 0
      return 0
      ;;
  esac
  record_status 'controlplane.linger' 'controlplane' 'WARN' \
    "linger answered '${val:-nothing}' — the state is unreadable" \
    "loginctl show-user \"${user:-current}\" -p Linger" || return 0
  return 0
}

cp_ask_linger() {
  # M10's documented continue/skip answer. A driver with no terminal never
  # blocks: it continues and leaves the row WARN (host portability, AGENTS.md).
  # CP_ASSUME_TTY=1 asks the question on a pipe — the mode hermetic suites and
  # an operator driving the flow through a wrapper use.
  local ans=''
  if [ ! -t 0 ] && [ "${CP_ASSUME_TTY:-0}" != '1' ]; then
    printf 'no terminal for the M10 answer — continuing, the linger row stays WARN\n'
    return 0
  fi
  printf 'answer: [y] continue the verify table, [s] skip the remaining rows: '
  if ! IFS= read -r ans; then
    # A pipe that closes without a final newline still carries the answer.
    [ -n "$ans" ] || ans='s'
  fi
  case "$ans" in
    y | Y | yes | continue)
      printf 'continuing without linger (SPEC-043 M10)\n'
      ;;
    *)
      CP_VERIFY_STOP=1
      printf 'skipping the remaining rows at the operator request (SPEC-043 M10)\n'
      ;;
  esac
  return 0
}

cp_row_wsl_systemd() {
  # AC7(a): verifiable from inside WSL — T1's registered check answers it.
  cp_row_guard 'controlplane.wsl2.systemd' || return 0
  if [ "$CP_PLATFORM" != 'wsl2' ]; then
    record_status 'controlplane.wsl2.systemd' 'controlplane' 'SKIP' \
      'not WSL2 — the Windows auto-start rows do not apply' '' || return 0
    return 0
  fi
  if cp_pf_wsl_conf >/dev/null 2>&1; then
    record_status 'controlplane.wsl2.systemd' 'controlplane' 'PASS' \
      "[boot] systemd=true is set in ${DEVTEAM_CP_WSLCONF:-/etc/wsl.conf} (SPEC-043 AC7(a))" '' || return 0
    return 0
  fi
  cp_row_absent 'controlplane.wsl2.systemd' \
    "[boot] systemd=true is not set in ${DEVTEAM_CP_WSLCONF:-/etc/wsl.conf}" \
    'add [boot] systemd=true to /etc/wsl.conf, then run: wsl.exe --shutdown (from Windows)' || return 0
  return 0
}

cp_row_wsl_autostart() {
  # AC7(b): the Windows Task Scheduler logon task — never verifiable from
  # inside WSL, so it is WARN with the exact operator step (SPEC-043 M8).
  local distro
  cp_row_guard 'controlplane.wsl2.autostart' || return 0
  if [ "$CP_PLATFORM" != 'wsl2' ]; then
    record_status 'controlplane.wsl2.autostart' 'controlplane' 'SKIP' \
      'not WSL2 — the Windows auto-start rows do not apply' '' || return 0
    return 0
  fi
  distro=${WSL_DISTRO_NAME:-<distro-name>}
  record_status 'controlplane.wsl2.autostart' 'controlplane' 'WARN' \
    'the WSL logon task lives on the Windows side and cannot be read from inside WSL — the node will not start WSL at logon until the operator adds it (SPEC-043 M8(b))' \
    "Windows PowerShell: schtasks /Create /TN dev-team-wsl-start /TR \"wsl.exe -d $distro --exec /bin/true\" /SC ONLOGON" || return 0
  return 0
}

cp_row_wsl_idle() {
  # AC7(c): `.wslconfig` idle shutdown. The distro key is primary (vendor-
  # documented everywhere, T0 § Q3); the VM key is Windows 11 only and its -1
  # value is vendor-undocumented.
  cp_row_guard 'controlplane.wsl2.idletimeout' || return 0
  if [ "$CP_PLATFORM" != 'wsl2' ]; then
    record_status 'controlplane.wsl2.idletimeout' 'controlplane' 'SKIP' \
      'not WSL2 — the Windows auto-start rows do not apply' '' || return 0
    return 0
  fi
  record_status 'controlplane.wsl2.idletimeout' 'controlplane' 'WARN' \
    '%UserProfile%\.wslconfig is on the Windows side and cannot be read from inside WSL: an idle distro is shut down, and with it systemd, the user manager, and the node agent (SPEC-043 M8(c))' \
    'Windows, in %UserProfile%\.wslconfig: add [general] instanceIdleTimeout=-1 (the distro timer, -1 disables auto-shutdown); on Windows 11 also [wsl2] vmIdleTimeout=-1 (the -1 value is vendor-undocumented for that key); then run: wsl.exe --shutdown' || return 0
  return 0
}

# ---------------------------------------------------------------------------
# The verify walk, render, and exit (SPEC-043 M6/M7)
# ---------------------------------------------------------------------------

cp_verify() {
  CP_VERIFY_MODE="$1"
  reset_status
  cp_banner verify
  cp_row_unit chiefd
  cp_row_node_agent
  cp_row_chiefd_http
  cp_row_probe
  cp_row_hygiene
  cp_row_runner
  cp_row_linger
  # The service-env rows sit after the M10 answer, so the documented skip
  # answer SKIPs them like every later row (SPEC-043 M10).
  cp_row_chiefd_journal
  cp_row_service_env
  cp_row_wsl_systemd
  cp_row_wsl_autostart
  cp_row_wsl_idle
  cp_render_table
  status_exit_code || return $?
  return 0
}

cp_render_table() {
  printf 'dev-team /setup control-plane — verify (mode=%s, platform=%s, checkout=%s)\n' \
    "$CP_VERIFY_MODE" "${CP_PLATFORM:-unknown}" "${CP_MROOT:-unknown}"
  printf -- '----------------------------------------------------------------\n'
  render_status_rows || return 1
  printf -- '----------------------------------------------------------------\n'
  status_footer || return 1
  return 0
}

# ---------------------------------------------------------------------------
# The three modes (SPEC-043 M1)
# ---------------------------------------------------------------------------

cp_mode_install() {
  cp_banner preflight
  cp_preflight || return $?
  # One checkout for every phase: the build, the units, and the probe all use
  # the root preflight validated.
  CP_CHECKOUT_ROOT="$CP_MROOT"
  export CP_CHECKOUT_ROOT
  # journalctl is verify plumbing, so it is not an install target (AC11). It is
  # built first: a checkout that cannot build it stops with nothing installed
  # (SPEC-043 AC9 "no partial state").
  cp_banner 'build (journal CLI)'
  cp_build_journal || return 2
  cp_install || return $?
  cp_verify install
}

cp_mode_status() {
  cp_banner preflight
  cp_preflight_readonly || return $?
  CP_CHECKOUT_ROOT="$CP_MROOT"
  export CP_CHECKOUT_ROOT
  cp_verify status
}

main() {
  cp_parse_args "$@" || return $?
  if [ "$CP_MODE" = 'help' ]; then
    cp_usage
    return 0
  fi
  # AC4 first: an elevated shell is a refusal before anything is read or written.
  cp_sudo_guard || return 2
  if [ "$CP_MODE" = 'uninstall' ]; then
    cp_uninstall || return $?
    return 0
  fi
  if [ "$CP_MODE" = 'status' ]; then
    cp_mode_status || return $?
    return 0
  fi
  cp_mode_install || return $?
  return 0
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  main "$@" || exit $?
fi
