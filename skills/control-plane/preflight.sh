#!/usr/bin/env bash
# skills/control-plane/preflight.sh — /setup control-plane preflight (SPEC-043 M2)
#
# The ordered, fail-closed gate in front of the control-plane install. It runs
# SPEC-043 M2 (a)–(g) in order and stops at the first failure, naming the check
# and printing its fix line. It reads the node and writes nothing: no binary,
# no unit, no journal row, no `node.json`, no `$DEVTEAM_RUNNER` (AC6, AC9).
#
# Source (setup.sh, SPEC-043 SHOULD "small registered functions"):
#   CP_SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
#   . "$CP_SCRIPT_DIR/preflight.sh"
#   cp_preflight || return 1
# On success cp_preflight sets CP_PLATFORM, CP_RUNNER, CP_RUNNER_SOURCE,
# CP_IMAGE and CP_MROOT for the caller.
#
# Subprocess CLI:
#   bash skills/control-plane/preflight.sh
#
# Exit (SPEC-043 M7): 0 ok · 2 FAIL (docker, image pin, runner selection) ·
# 63 unsupported platform/environment shape (macOS, systemd, WSL2 systemd off,
# non-checkout).
#
# Stdout on success carries the resolved platform kind and runner selection:
#   platform=wsl2
#   runner=native
#   runner_source=none
#
# Test hooks (hermetic suite: skills/control-plane/test-preflight.sh). Every
# host probe is a PATH command or a path knob, so fakes need no root:
#   PATH            fake uname, systemctl, docker (a non-executable file reads
#                   as "not installed")
#   DEVTEAM_CP_MROOT        checkout root (default: git common-dir parent)
#   DEVTEAM_CP_WSLCONF      wsl.conf path (default: /etc/wsl.conf)
#   DEVTEAM_CP_BUILDSH      build script (default: $CP_MROOT/control-plane/build.sh)
#   DEVTEAM_CP_IMAGE        image reference to validate (default: the IMAGE=
#                           literal in the build script)
#   DEVTEAM_CP_NODE_JSON    node config (default: $CP_MROOT/.claude/dev-team/node.json)
#   DEVTEAM_CP_DOCKER_TIMEOUT  seconds for the docker reachability probe (default 20)
#   DEVTEAM_RUNNER          runner selection override — read only, never written
#
# THIS MODULE WRITES NOTHING. It has no side effect to undo, so a failed
# preflight leaves zero partial state by construction (SPEC-043 AC9).

CP_APPROVED_IMAGE='docker.io/library/golang:1.27-bookworm@sha256:4fa7c968ba93f1635670522dbb01a2c78150443e1385746924566079f36570ea'
CP_DOCKER_TIMEOUT=20
CP_RUNNER_SET='native container'

CP_PREFLIGHT_DIR=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=../lib/portable.sh
. "$CP_PREFLIGHT_DIR/../lib/portable.sh"

# ---------------------------------------------------------------------------
# Report helpers
# ---------------------------------------------------------------------------

cp_pf_trim() {
  local s=${1-}
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

cp_pf_lower() {
  printf '%s' "${1-}" | LC_ALL=C tr '[:upper:]' '[:lower:]'
}

cp_pf_ok() {
  printf 'preflight ok: %s\n' "$1" || return 1
}

cp_pf_report() {
  # cp_pf_report <exit-code> <check> <detail> [fix line...]
  local code="$1" check="$2" detail="$3" fix
  shift 3
  printf 'preflight FAIL: %s — %s\n' "$check" "$detail" || return 1
  for fix in "$@"; do
    printf '  fix: %s\n' "$fix" || return 1
  done
  return "$code"
}

# ---------------------------------------------------------------------------
# (a) platform — Linux or WSL2
# ---------------------------------------------------------------------------

cp_pf_platform() {
  local sys rel
  if ! command -v uname >/dev/null 2>&1; then
    cp_pf_report 63 platform 'uname is not available' \
      'install coreutils so the platform can be detected'
    return $?
  fi
  sys=$(cp_pf_trim "$(uname -s 2>/dev/null)")
  rel=$(cp_pf_lower "$(uname -r 2>/dev/null)")
  case "$sys" in
    Linux)
      # WSL2 kernels carry the microsoft-standard-WSL2 marker in `uname -r`.
      case "$rel" in
        *wsl2*) CP_PLATFORM='wsl2' ;;
        *) CP_PLATFORM='linux' ;;
      esac
      ;;
    Darwin)
      cp_pf_report 63 platform 'macOS is not a supported node' \
        'run this on Linux, or on WSL2 with systemd on — macOS is out of scope (CDT-631)'
      return $?
      ;;
    *)
      cp_pf_report 63 platform "unrecognised system: '${sys:-no answer}'" \
        'Linux with a systemd user manager is the only supported platform'
      return $?
      ;;
  esac
  cp_pf_ok "platform — $CP_PLATFORM"
  return 0
}

# ---------------------------------------------------------------------------
# (b) systemd user manager usable
# ---------------------------------------------------------------------------

cp_pf_systemd() {
  local st rc
  if ! command -v systemctl >/dev/null 2>&1; then
    cp_pf_report 63 systemd-user 'systemctl is not installed' \
      'Linux with systemd is the only supported platform — install systemd' \
      'on WSL2, enable systemd in /etc/wsl.conf (the wsl2-systemd check)'
    return $?
  fi
  st=$(systemctl --user is-system-running 2>/dev/null)
  rc=$?
  st=$(cp_pf_trim "${st%%$'\n'*}")
  case "$st" in
    running|degraded)
      cp_pf_ok "systemd-user — $st"
      return 0
      ;;
  esac
  cp_pf_report 63 systemd-user "the systemd user manager is not usable (is-system-running: '${st:-no answer}', exit $rc)" \
    'start a systemd user session, then log out and back in' \
    'on WSL2 set [boot] systemd=true in /etc/wsl.conf, then run wsl.exe --shutdown from Windows'
  return $?
}

# ---------------------------------------------------------------------------
# (c) WSL2 only — /etc/wsl.conf carries [boot] systemd=true
# ---------------------------------------------------------------------------

cp_pf_wsl_conf() {
  local conf val
  conf=${DEVTEAM_CP_WSLCONF:-/etc/wsl.conf}
  if [ ! -f "$conf" ]; then
    cp_pf_report 63 wsl2-systemd "no $conf — WSL2 cannot start systemd" \
      'create /etc/wsl.conf carrying:' \
      '  [boot]' \
      '  systemd=true' \
      'then run: wsl.exe --shutdown  (from Windows) and reopen the distro'
    return $?
  fi
  if [ ! -r "$conf" ]; then
    cp_pf_report 63 wsl2-systemd "$conf is not readable" \
      'restore read permission on /etc/wsl.conf (this command never elevates)'
    return $?
  fi
  val=$(awk '
    BEGIN { inboot = 0; val = "" }
    {
      line = $0
      sub(/[;#].*$/, "", line)
      if (line ~ /^[[:space:]]*\[/) {
        inboot = (line ~ /^[[:space:]]*\[boot[[:space:]]*\]/)
        next
      }
      if (!inboot) next
      if (line ~ /^[[:space:]]*systemd[[:space:]]*=/) {
        sub(/^[[:space:]]*systemd[[:space:]]*=[[:space:]]*/, "", line)
        sub(/[[:space:]]*$/, "", line)
        val = line
      }
    }
    END { print val }
  ' "$conf")
  val=$(cp_pf_lower "$(cp_pf_trim "$val")")
  case "$val" in
    true|1|yes)
      cp_pf_ok 'wsl2-systemd — systemd=true'
      return 0
      ;;
  esac
  cp_pf_report 63 wsl2-systemd "'[boot] systemd=true' is not set in $conf (found: '${val:-no systemd key}')" \
    'add to /etc/wsl.conf:' \
    '  [boot]' \
    '  systemd=true' \
    'then run: wsl.exe --shutdown  (from Windows) and reopen the distro'
  return $?
}

# ---------------------------------------------------------------------------
# (d) checkout — control-plane/go.mod under $MROOT
# ---------------------------------------------------------------------------

cp_pf_checkout() {
  local _gc
  if [ -n "${DEVTEAM_CP_MROOT:-}" ]; then
    CP_MROOT=$DEVTEAM_CP_MROOT
  elif ! command -v git >/dev/null 2>&1; then
    cp_pf_report 63 checkout 'git is not available, so $MROOT cannot be resolved' \
      'run from inside a dev-team git checkout'
    return $?
  else
    if ! _gc=$(git rev-parse --git-common-dir 2>/dev/null); then
      cp_pf_report 63 checkout 'not a git checkout — $MROOT is unresolvable' \
        'run /setup control-plane from inside a dev-team checkout'
      return $?
    fi
    CP_MROOT=$(CDPATH= cd -- "$(dirname -- "$_gc")" && pwd)
  fi
  if [ -z "$CP_MROOT" ] || [ ! -d "$CP_MROOT" ]; then
    cp_pf_report 63 checkout 'the checkout root is not a directory' \
      'run /setup control-plane from inside a dev-team checkout'
    return $?
  fi
  if [ ! -f "$CP_MROOT/control-plane/go.mod" ]; then
    cp_pf_report 63 checkout "no control-plane/go.mod under $CP_MROOT" \
      'use a dev-team checkout that ships the control-plane service' \
      'prebuilt release binaries are out of scope for phase 1 (CDT-631)'
    return $?
  fi
  cp_pf_ok "checkout — $CP_MROOT"
  return 0
}

# ---------------------------------------------------------------------------
# (e) docker on PATH and reachable
# ---------------------------------------------------------------------------

cp_pf_docker() {
  local out rc reason timeout_s
  timeout_s=$CP_DOCKER_TIMEOUT
  case "${DEVTEAM_CP_DOCKER_TIMEOUT:-}" in
    ''|*[!0-9]*) ;;
    *)
      [ "$DEVTEAM_CP_DOCKER_TIMEOUT" -ge 1 ] && timeout_s=$DEVTEAM_CP_DOCKER_TIMEOUT
      ;;
  esac
  if ! command -v docker >/dev/null 2>&1; then
    cp_pf_report 2 docker 'docker is not on PATH' \
      'install Docker Engine (Linux) or Docker Desktop with the WSL2 integration, then re-run'
    return $?
  fi
  out=$(portable_with_timeout "$timeout_s" docker info 2>&1 >/dev/null)
  rc=$?
  if [ "$rc" -eq 0 ]; then
    cp_pf_ok 'docker'
    return 0
  fi
  if [ "$rc" -eq 124 ]; then
    reason="no answer within ${timeout_s}s"
  else
    reason=$(printf '%s\n' "$out" | head -n 1)
  fi
  cp_pf_report 2 docker "docker info failed (exit $rc): ${reason:-no reason reported}" \
    'start the Docker daemon (operator step — this command never elevates), then re-run' \
    'on WSL2, enable the Docker Desktop integration for this distro, then re-run'
  return $?
}

# ---------------------------------------------------------------------------
# (f) the approved image pin — the M2(f) literal, nothing else, pre-pull
# ---------------------------------------------------------------------------

cp_pf_image() {
  local ref bs
  ref=$(cp_pf_trim "${DEVTEAM_CP_IMAGE:-}")
  if [ -z "$ref" ]; then
    bs=${DEVTEAM_CP_BUILDSH:-$CP_MROOT/control-plane/build.sh}
    if [ ! -r "$bs" ]; then
      cp_pf_report 2 image-pin "no readable build script at $bs" \
        'restore control-plane/build.sh — it carries the approved image pin'
      return $?
    fi
    ref=$(sed -n 's/^IMAGE=//p' "$bs" | head -n 1)
    ref=$(cp_pf_trim "$ref")
    ref="${ref%\"}"; ref="${ref#\"}"
    ref="${ref%\'}"; ref="${ref#\'}"
    if [ -z "$ref" ]; then
      cp_pf_report 2 image-pin "no IMAGE= pin in $bs" \
        "restore the approved pin: IMAGE=$CP_APPROVED_IMAGE"
      return $?
    fi
  fi
  if [ "$ref" = "$CP_APPROVED_IMAGE" ]; then
    CP_IMAGE=$ref
    cp_pf_ok 'image-pin — approved digest'
    return 0
  fi
  cp_pf_report 2 image-pin "unapproved image reference: $ref" \
    "the only approved build image is $CP_APPROVED_IMAGE" \
    'approval record: docs/internal/control-plane/node-agent-build-probe.md (G-02)' \
    "restore that pin in ${DEVTEAM_CP_BUILDSH:-$CP_MROOT/control-plane/build.sh} — this check stops the run before any pull"
  return $?
}

# ---------------------------------------------------------------------------
# (g) runner selection — closed set, read-only (AC6)
# ---------------------------------------------------------------------------

cp_pf_valid_runner() {
  case "${1-}" in
    native|container) return 0 ;;
  esac
  return 1
}

cp_pf_runner_native() {
  # cp_pf_runner_native <ok-detail> — the M2(g) no-selection default:
  # native, source none.
  CP_RUNNER='native'
  CP_RUNNER_SOURCE='none'
  cp_pf_ok "runner-selection — $1"
  return 0
}

cp_pf_runner() {
  local envv nodejson raw keys bad
  envv=$(cp_pf_trim "${DEVTEAM_RUNNER:-}")
  nodejson=${DEVTEAM_CP_NODE_JSON:-$CP_MROOT/.claude/dev-team/node.json}

  if [ -n "$envv" ]; then
    # First hit wins: $DEVTEAM_RUNNER overrides the node config outright.
    if cp_pf_valid_runner "$envv"; then
      CP_RUNNER=$envv
      CP_RUNNER_SOURCE='env'
      cp_pf_ok 'runner-selection — env'
      return 0
    fi
    cp_pf_report 2 runner-selection "\$DEVTEAM_RUNNER='$envv' is not in the closed set ($CP_RUNNER_SET)" \
      'set DEVTEAM_RUNNER=native or DEVTEAM_RUNNER=container, or unset it to read node.json'
    return $?
  fi

  if [ ! -e "$nodejson" ]; then
    cp_pf_runner_native 'absent (native)'
    return 0
  fi
  if [ ! -r "$nodejson" ]; then
    cp_pf_report 2 runner-selection "$nodejson is not readable" \
      'restore read permission on the node config (this command never elevates)'
    return $?
  fi
  if [ ! -s "$nodejson" ]; then
    cp_pf_runner_native 'empty file (native)'
    return 0
  fi

  if command -v jq >/dev/null 2>&1; then
    if ! jq -e . "$nodejson" >/dev/null 2>&1; then
      cp_pf_report 2 runner-selection "$nodejson is not valid JSON" \
        'repair the node config — a node with no valid selection starts no run'
      return $?
    fi
    if ! keys=$(jq -r 'keys[]' "$nodejson" 2>/dev/null); then
      cp_pf_report 2 runner-selection "$nodejson is not a JSON object" \
        'the node config shape is {"runner": "...", "command": "..."}'
      return $?
    fi
    bad=$(printf '%s\n' "$keys" | grep -Ev '^(runner|command)$' | head -n 1)
    if [ -n "$bad" ]; then
      cp_pf_report 2 runner-selection "$nodejson has an unknown key: $bad" \
        'the closed node config shape carries the runner and command keys only'
      return $?
    fi
    raw=$(jq -r '.runner // empty' "$nodejson" 2>/dev/null)
  else
    # No jq: line-scoped read of the runner key. A file this cannot read
    # resolves to no selection, the fail-closed default.
    raw=$(sed -n 's/.*"runner"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$nodejson" | head -n 1)
  fi
  raw=$(cp_pf_trim "$raw")

  if [ -z "$raw" ]; then
    cp_pf_runner_native 'absent (native)'
    return 0
  fi
  if cp_pf_valid_runner "$raw"; then
    CP_RUNNER=$raw
    CP_RUNNER_SOURCE='node.json'
    cp_pf_ok "runner-selection — node.json"
    return 0
  fi
  cp_pf_report 2 runner-selection "node.json runner='$raw' is not in the closed set ($CP_RUNNER_SET)" \
    "set the runner key to native or container in $nodejson"
  return $?
}

# ---------------------------------------------------------------------------
# cp_preflight — the M2 (a)–(g) walk, fail-closed
# ---------------------------------------------------------------------------

cp_preflight() {
  CP_PLATFORM=''
  CP_RUNNER=''
  CP_RUNNER_SOURCE=''
  CP_IMAGE=''
  CP_MROOT=''

  cp_pf_platform || return $?
  cp_pf_systemd || return $?
  if [ "$CP_PLATFORM" = 'wsl2' ]; then
    cp_pf_wsl_conf || return $?
  else
    printf 'preflight skip: wsl2-systemd (not WSL2)\n' || return 1
  fi
  cp_pf_checkout || return $?
  cp_pf_docker || return $?
  cp_pf_image || return $?
  cp_pf_runner || return $?

  printf 'preflight ok: all checks\n' || return 1
  printf 'platform=%s\nrunner=%s\nrunner_source=%s\n' \
    "$CP_PLATFORM" "$CP_RUNNER" "$CP_RUNNER_SOURCE" || return 1
  return 0
}

# Subprocess entry point.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  cp_preflight
  exit $?
fi
