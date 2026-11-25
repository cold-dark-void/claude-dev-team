#!/usr/bin/env bash
# skills/control-plane/units.sh — the chiefd systemd user unit + install/uninstall
# (CDT-658 T2/T8, SPEC-043 M3/M4/M5/M9/M12).
# SOURCE-ONLY — never run this file as a subprocess. The CLI that wires it is
# skills/control-plane/setup.sh (/setup control-plane, SPEC-043 M1).
#
# Exit-code contract (SPEC-043 M7), returned — never exit()ed, so the driver
# owns the process exit:
#   cp_install     0 ok | 63 unsupported environment shape | 2 FAIL
#   cp_uninstall   0 (SPEC-043 M9); 2 only from the AC4 sudo guard
# Both print their phase banners.
#
# Function inventory:
#   cp_install / cp_uninstall      the two modes
#   cp_build                       the M4 build inside the approved digest
#   cp_unit_name/cp_unit_path      dev-team-<service>.service, in the user unit dir
#   cp_unit_text                   the M5 unit template (chiefd only) — it stamps
#                                  WorkingDirectory, DEVTEAM_MROOT and the probed
#                                  service PATH (CDT-666)
#   cp_user_cli_dirs/cp_service_path the user CLI dirs that exist + the systemd
#                                  default PATH, in stamp order
#   cp_bin_path                    %h/.local/bin/<binary> (M3)
#   cp_publish / cp_publish_fn     write only when content differs (M12), atomically
#   cp_shape_guard                 last-line environment check for standalone use
#   cp_targets_ready               M3: every write target user-writable
#   cp_run                         command funnel: refuses privilege-elevation tokens
#   cp_sudo_guard                  AC4: refuse an elevated shell
#   cp_remove                      removal with the M9 outcome line
#   cp_systemctl_soft              a removal verb whose failure is a note, not a halt
#   cp_windows_steps               the M9 Windows operator steps (printed only)
#
# The ordered M2 preflight is NOT here: skills/control-plane/preflight.sh
# (SPEC-043 T1) owns it. cp_shape_guard is this module's own guard so an
# install can never run on a machine that cannot host a user unit.
#
# One unit ships (SPEC-043 M5, T8 replan D1): the node agent has no long-lived
# verb, so a supervised ExecStart of it exits at once and restart-loops. The
# machine supervises chiefd; the agent stays a by-path CLI. cp_uninstall still
# removes the node-agent binary — install installs it as a CLI.
#
# Never sudo, never su, never pkexec (SPEC-043 AC4 / MUST NOT). Every write
# target is under $HOME (M3).
#
# Environment overrides (hermetic tests, advanced operators):
#   CP_CHECKOUT_ROOT  checkout root (default: the git main checkout root, $MROOT)
#   CP_BIN_DIR        binary install dir (default $HOME/.local/bin)
#   CP_UNIT_DIR       user unit dir (default $HOME/.config/systemd/user)
#   CP_IMAGE          build image; must equal CP_APPROVED_IMAGE (AC4)

set -u

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  printf 'error: units.sh is source-only — source it from skills/control-plane/setup.sh\n' >&2
  exit 64
fi

CP_LIB_DIR=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../lib" && pwd)
# shellcheck source=../lib/portable.sh
. "$CP_LIB_DIR/portable.sh"

# The G-02-approved Go build image (SPEC-043 M2(f); the approval record is
# docs/internal/control-plane/node-agent-build-probe.md § "The Go build image —
# approval record"). This digest is the only acceptable reference.
CP_APPROVED_IMAGE='docker.io/library/golang:1.27-bookworm@sha256:4fa7c968ba93f1635670522dbb01a2c78150443e1385746924566079f36570ea'
CP_IMAGE="${CP_IMAGE:-$CP_APPROVED_IMAGE}"

CP_BIN_MODE='755' # binaries, SPEC-043 M3
CP_UNIT_MODE='644' # unit files, SPEC-043 M3
CP_SERVICES='node-agent chiefd' # the two phase-1 binaries (M1/M3)
CP_UNIT_SERVICES='chiefd' # the one supervised service (M5) — no node-agent unit
# Unit files an earlier install shipped and SPEC-043 M5 (the T8 replan) drops.
# A surviving one is enabled, its binary is gone, and Restart=on-failure
# restart-loops it, so both modes stop, disable, and remove it.
CP_LEGACY_UNITS='dev-team-node-agent.service'
# Command words this module must never execute (SPEC-043 MUST NOT).
CP_DENY_TOKENS='sudo su pkexec'

# ---- phase banners -----------------------------------------------------------

cp_banner() { # SPEC-043 SHOULD: a failure names its phase
  printf '\n== %s ==\n' "$1"
}

# ---- paths -------------------------------------------------------------------

cp_checkout_root() {
  # The checkout the build runs against: $MROOT (the git main checkout root, so
  # a linked worktree shares the plugin's module). CP_CHECKOUT_ROOT overrides.
  local gc
  if [ -n "${CP_CHECKOUT_ROOT:-}" ]; then
    printf '%s\n' "$CP_CHECKOUT_ROOT"
    return 0
  fi
  gc=$(git rev-parse --git-common-dir 2>/dev/null) || return 1
  [ -n "$gc" ] || return 1
  gc=$(CDPATH= cd -- "$gc" && pwd) || return 1
  dirname -- "$gc"
}

cp_bin_dir() {
  printf '%s\n' "${CP_BIN_DIR:-$HOME/.local/bin}"
}

cp_unit_dir() {
  printf '%s\n' "${CP_UNIT_DIR:-$HOME/.config/systemd/user}"
}

cp_bin_path() { # cp_bin_path <service>
  case "$1" in
    node-agent | chiefd) ;;
    *) return 1 ;;
  esac
  printf '%s/%s\n' "$(cp_bin_dir)" "$1"
}

cp_unit_name() { # cp_unit_name <service> -> dev-team-<service>.service
  case "$1" in
    chiefd) printf 'dev-team-%s.service\n' "$1" ;;
    node-agent)
      printf 'control-plane: the node agent has no unit in phase 1 — it is invoked by path (SPEC-043 M5).\n' >&2
      return 1
      ;;
    *) return 1 ;;
  esac
}

cp_unit_path() { # cp_unit_path <service>
  local unit
  unit=$(cp_unit_name "$1") || return 1
  printf '%s/%s\n' "$(cp_unit_dir)" "$unit"
}

# ---- the M5 unit template ----------------------------------------------------

CP_SYSTEM_DEFAULT_PATH='/usr/local/bin:/usr/bin' # the systemd user-manager default

cp_user_cli_dirs() {
  # The user CLI dirs the service PATH needs, probed at install: the host CLI
  # the native runner spawns lives in ~/.grok/bin, and the installed service
  # CLIs live in the binary dir. A dir that does not exist is not stamped
  # (systemd keeps the unit startable), so the PATH degrades to the defaults.
  local d
  for d in "$HOME/.grok/bin" "$(cp_bin_dir)"; do
    [ -d "$d" ] || continue
    printf '%s\n' "$d"
  done
}

cp_service_path() {
  # The PATH value the unit stamps: every existing user CLI dir, then the
  # systemd user defaults (SPEC-043 M5, CDT-666).
  local out='' d
  while IFS= read -r d; do
    [ -n "$d" ] || continue
    out="${out:+$out:}$d"
  done <<DIRS
$(cp_user_cli_dirs)
DIRS
  printf '%s\n' "${out:+$out:}$CP_SYSTEM_DEFAULT_PATH"
}

cp_unit_text() { # cp_unit_text <service> [checkout-root] — unit file bytes on stdout
  local svc="$1" desc exec_line mroot
  case "$svc" in
    node-agent)
      # SPEC-043 M5 (T8 replan D1): the agent verbs are start|stop|status|steer|
      # status-node, so a supervised ExecStart of the binary exits at once and
      # Restart=on-failure restart-loops. No unit ships until the agent grows a
      # daemon verb (control-plane follow-up ticket).
      printf 'control-plane: the node agent has no unit in phase 1 — it is invoked by path (SPEC-043 M5).\n' >&2
      return 1
      ;;
    chiefd)
      desc='dev-team chiefd — the Chief API and web UI (CDT-650, CDT-652)'
      # The bind stays loopback: chiefd refuses any other address (CDT-652) and
      # SPEC-043 M5 forbids widening it, so ExecStart names 127.0.0.1 explicitly.
      exec_line='ExecStart=%h/.local/bin/chiefd --addr 127.0.0.1:8090'
      ;;
    *)
      printf 'control-plane: unknown service: %s\n' "$svc" >&2
      return 1
      ;;
  esac
  # The env the service needs (CDT-666): chiefd resolves its journal as
  # $DEVTEAM_MROOT/.claude/runs/run.db and the plugin root from the same anchor,
  # so an unstamped unit falls back to $HOME, serves an empty store beside the
  # project's, and refuses every route. The caller passes the checkout root it
  # resolved; with no argument cp_checkout_root resolves it.
  mroot="${2:-}"
  if [ -z "$mroot" ]; then
    mroot=$(cp_checkout_root) || mroot=''
  fi
  if [ -z "$mroot" ] || [ ! -d "$mroot" ]; then
    printf 'control-plane: cannot stamp the unit — the checkout root is not a directory: %s\n' "${mroot:-unset}" >&2
    printf 'fix: run /setup control-plane inside a dev-team checkout (SPEC-043 AC5).\n' >&2
    return 63
  fi
  # stdout/stderr need no directive — journald capture is the systemd default.
  cat <<EOF
[Unit]
Description=$desc
Documentation=https://linear.app/cold-dark-void/issue/CDT-626
Wants=network-online.target
After=network-online.target
StartLimitIntervalSec=60
StartLimitBurst=10

[Service]
WorkingDirectory=$mroot
Environment="DEVTEAM_MROOT=$mroot"
Environment="PATH=$(cp_service_path)"
$exec_line
Restart=on-failure
RestartSec=2s

[Install]
WantedBy=default.target
EOF
}

# ---- host build target -------------------------------------------------------

cp_host_goos() {
  local k
  k=$(uname -s 2>/dev/null) || k=''
  case "$k" in
    Linux) printf 'linux\n' ;;
    Darwin) printf 'darwin\n' ;;
    *) return 1 ;;
  esac
}

cp_host_goarch() {
  local m
  m=$(uname -m 2>/dev/null) || m=''
  case "$m" in
    x86_64 | amd64) printf 'amd64\n' ;;
    aarch64 | arm64) printf 'arm64\n' ;;
    *) return 1 ;;
  esac
}

# ---- AC4: never elevate ------------------------------------------------------

cp_deny_token() {
  # cp_deny_token <argv...> — rc 0 when a word is a privilege-elevation tool.
  local word base token
  for word in "$@"; do
    base=${word##*/}
    for token in $CP_DENY_TOKENS; do
      if [ "$base" = "$token" ]; then
        return 0
      fi
    done
  done
  return 1
}

cp_run() {
  # The single command funnel: no command runs unguarded (SPEC-043 AC4).
  if cp_deny_token "$@"; then
    printf 'control-plane: refused to run a privilege-elevation command: %s\n' "$*" >&2
    printf 'fix: run install as the invoking user; every target is under $HOME (SPEC-043 M3).\n' >&2
    return 2
  fi
  "$@"
}

cp_sudo_guard() {
  # AC4: an elevated shell means the install targets are not the user's own.
  # A privilege-elevated shell exports the SUDO_* names (user, command, uid,
  # gid, askpass), so any one of them is a refusal. The heredoc drains `env`
  # fully, so no early exit closes the pipe (pipefail).
  local name
  while IFS= read -r name; do
    case "$name" in
      SUDO_*)
        printf 'control-plane: refused — this shell is elevated (%s is set).\n' "$name" >&2
        printf 'fix: run /setup control-plane as the user who owns $HOME (SPEC-043 AC4).\n' >&2
        return 1
        ;;
    esac
  done <<ENVS
$(env | sed -e 's/=.*$//')
ENVS
  # The heredoc terminator ends the last line, so `read` never sees a partial
  # line here (the hazard a `while read` loop normally needs a tail guard for).
  return 0
}

cp_assert_image_pin() {
  # M2(f): the approved digest is the only acceptable image reference.
  if [ "$CP_IMAGE" != "$CP_APPROVED_IMAGE" ]; then
    printf 'control-plane: refused — image is not the approved digest: %s\n' "$CP_IMAGE" >&2
    printf 'approved: %s (SPEC-043 M2(f))\n' "$CP_APPROVED_IMAGE" >&2
    return 1
  fi
  return 0
}

# ---- environment shape -------------------------------------------------------

cp_shape_guard() {
  # rc 63 when this machine cannot host a systemd user unit (SPEC-043 M7/AC8).
  # T1's cp_preflight is the authoritative ordered M2 preflight; this guard
  # keeps a standalone cp_install from writing units the manager cannot load.
  local kern ans rc=0
  kern=$(uname -s 2>/dev/null) || kern=''
  if [ "$kern" != 'Linux' ]; then
    printf 'control-plane: unsupported platform: %s — Linux/WSL2 with systemd only (SPEC-043 M7).\n' "$kern" >&2
    return 63
  fi
  if ! command -v systemctl >/dev/null 2>&1; then
    printf 'control-plane: no systemctl on PATH — a systemd user manager is required.\n' >&2
    return 63
  fi
  # `is-system-running` exits non-zero on degraded, so read the answer, not the code.
  ans=$(cp_run systemctl --user is-system-running 2>/dev/null) || rc=$?
  case "$ans" in
    running | degraded) return 0 ;;
  esac
  printf 'control-plane: the systemd user manager is not usable (answered: %s, rc %s).\n' "${ans:-none}" "$rc" >&2
  printf 'fix: on WSL2 set [boot] systemd=true in /etc/wsl.conf and restart WSL (SPEC-043 M2(b)/(c)).\n' >&2
  return 63
}

cp_targets_ready() {
  # M3: every write target must be writable by the invoking user.
  local d
  for d in "$(cp_bin_dir)" "$(cp_unit_dir)"; do
    if ! mkdir -p -- "$d" 2>/dev/null; then
      printf 'control-plane: cannot create the install directory: %s\n' "$d" >&2
      return 1
    fi
    if [ ! -w "$d" ]; then
      printf 'control-plane: install directory is not user-writable: %s\n' "$d" >&2
      printf 'fix: chown it to the invoking user; this command never uses elevated privileges (SPEC-043 M3).\n' >&2
      return 1
    fi
  done
  return 0
}

cp_systemctl() {
  # Every systemctl call is a --user call through the funnel (M3/M5).
  if ! command -v systemctl >/dev/null 2>&1; then
    printf 'control-plane: systemctl is not on PATH — skipped: --user %s\n' "$*" >&2
    return 1
  fi
  cp_run systemctl --user "$@"
}

# ---- the M4 build ------------------------------------------------------------

cp_build() { # cp_build <checkout-root> — node-agent + chiefd into control-plane/dist
  local root="$1" goos goarch pkg out rc=0
  goos=$(cp_host_goos) || {
    printf 'control-plane: unknown GOOS for this kernel — cannot build (SPEC-043 M4).\n' >&2
    return 2
  }
  goarch=$(cp_host_goarch) || {
    printf 'control-plane: unknown GOARCH for this machine — cannot build (SPEC-043 M4).\n' >&2
    return 2
  }
  if [ ! -w "$root/control-plane" ]; then
    printf 'control-plane: %s is not writable — the build output has nowhere to land.\n' "$root/control-plane" >&2
    return 2
  fi
  if ! mkdir -p -- "$root/control-plane/dist"; then
    printf 'control-plane: cannot create control-plane/dist in %s\n' "$root" >&2
    return 2
  fi
  for pkg in $CP_SERVICES; do
    out="dist/$pkg"
    # --user keeps the outputs owned by the invoking user. The caches live under
    # container /tmp, so no build cache lands on the checkout (M4).
    cp_run docker run --rm \
      --user "$(id -u):$(id -g)" \
      -e HOME=/tmp/gohome \
      -v "$root":/src -w /src/control-plane \
      -e GOOS="$goos" -e GOARCH="$goarch" -e CGO_ENABLED=0 \
      -e GOCACHE=/tmp/gocache -e GOMODCACHE=/tmp/gomodcache \
      -e GOFLAGS=-buildvcs=false \
      "$CP_IMAGE" \
      go build -o "$out" "./cmd/$pkg" || rc=$?
    if [ "$rc" -ne 0 ]; then
      printf 'control-plane: build FAILED for %s (rc %s, SPEC-043 M4)\n' "$pkg" "$rc" >&2
      return 2
    fi
    if [ ! -s "$root/control-plane/$out" ]; then
      printf 'control-plane: build produced no binary at control-plane/%s (SPEC-043 M4)\n' "$out" >&2
      return 2
    fi
    printf 'built: control-plane/%s (%s/%s)\n' "$out" "$goos" "$goarch"
  done
  return 0
}

# ---- M12: publish only when content differs ----------------------------------

cp_publish() { # cp_publish <src-file> <dest> <mode>
  local src="$1" dest="$2" mode="$3" dir cur rc=0
  if [ ! -f "$src" ]; then
    printf 'control-plane: nothing to install from: %s\n' "$src" >&2
    return 1
  fi
  dir=$(dirname -- "$dest") || return 1
  if [ ! -d "$dir" ]; then
    printf 'control-plane: install directory is missing: %s\n' "$dir" >&2
    return 1
  fi
  if [ -L "$dest" ]; then
    printf 'control-plane: refusing to write through a symlink: %s\n' "$dest" >&2
    return 1
  fi
  if [ -f "$dest" ] && cmp -s -- "$src" "$dest"; then
    cur=$(stat -c %a "$dest" 2>/dev/null || stat -f %Lp "$dest" 2>/dev/null) || cur=''
    if [ "$cur" = "$mode" ]; then
      printf 'unchanged: %s\n' "$dest"
      return 0
    fi
    if ! chmod "$mode" "$dest"; then
      printf 'control-plane: chmod %s FAILED: %s\n' "$mode" "$dest" >&2
      return 1
    fi
    printf 'mode -> %s: %s\n' "$mode" "$dest"
    return 0
  fi
  # tmp + rename: a reader never sees a half-written binary or unit (M12).
  atomic_write "$dest" cat -- "$src" || rc=$?
  if [ "$rc" -ne 0 ]; then
    printf 'control-plane: write FAILED: %s\n' "$dest" >&2
    return 1
  fi
  if ! chmod "$mode" "$dest"; then
    printf 'control-plane: chmod %s FAILED: %s\n' "$mode" "$dest" >&2
    return 1
  fi
  printf 'installed: %s (mode %s)\n' "$dest" "$mode"
  return 0
}

cp_publish_fn() { # cp_publish_fn <dest> <mode> <producer> [args...]
  # The write target is <dest> alone: an operator drop-in directory
  # (<dest>.d/override.conf) is never touched, so a hand-wired node keeps its
  # overrides across an install (CDT-666).
  local dest="$1" mode="$2" tmp rc=0
  shift 2
  tmp=$(mktemp "${TMPDIR:-/tmp}/dev-team-render.XXXXXX") || return 1
  if "$@" >"$tmp"; then
    :
  else
    rc=$?
    rm -f -- "$tmp"
    return "$rc"
  fi
  cp_publish "$tmp" "$dest" "$mode" || rc=$?
  rm -f -- "$tmp"
  return "$rc"
}

# ---- the two modes -----------------------------------------------------------

cp_install() {
  local root svc rc=0 unit
  if ! cp_sudo_guard; then
    return 2
  fi
  cp_shape_guard || return $?
  root=$(cp_checkout_root) || {
    printf 'control-plane: cannot resolve the checkout root — run this inside a dev-team checkout (SPEC-043 AC5).\n' >&2
    return 63
  }
  if [ ! -f "$root/control-plane/go.mod" ]; then
    printf 'control-plane: not a control-plane checkout: %s/control-plane/go.mod is absent.\n' "$root" >&2
    printf 'fix: run this from a dev-team checkout; prebuilt binaries are CDT-631 scope (SPEC-043 AC5).\n' >&2
    return 63
  fi
  if ! cp_assert_image_pin; then
    return 2
  fi
  if ! command -v docker >/dev/null 2>&1; then
    printf 'control-plane: docker is not on PATH — the build runs in the approved image (SPEC-043 M2(e)).\n' >&2
    return 2
  fi
  if ! cp_targets_ready; then
    return 2
  fi

  cp_banner build
  if ! cp_build "$root"; then
    return 2
  fi

  cp_banner install
  for svc in $CP_SERVICES; do
    if ! cp_publish "$root/control-plane/dist/$svc" "$(cp_bin_path "$svc")" "$CP_BIN_MODE"; then
      rc=2
    fi
  done
  if [ "$rc" -ne 0 ]; then
    printf 'control-plane: install FAILED — no units are enabled without their binaries (SPEC-043 M3).\n' >&2
    return 2
  fi
  for svc in $CP_UNIT_SERVICES; do
    if ! cp_publish_fn "$(cp_unit_path "$svc")" "$CP_UNIT_MODE" cp_unit_text "$svc" "$root"; then
      printf 'control-plane: unit write FAILED for %s (SPEC-043 M5)\n' "$svc" >&2
      return 2
    fi
  done
  cp_purge_legacy_units
  if ! cp_systemctl daemon-reload; then
    printf 'control-plane: systemctl --user daemon-reload FAILED (SPEC-043 M5)\n' >&2
    return 2
  fi
  for svc in $CP_UNIT_SERVICES; do
    unit=$(cp_unit_name "$svc")
    if cp_systemctl enable --now "$unit"; then
      printf 'enabled: %s\n' "$unit"
    else
      printf 'control-plane: enable --now FAILED for %s (SPEC-043 M5)\n' "$unit" >&2
      rc=2
    fi
  done
  if [ "$rc" -ne 0 ]; then
    return 2
  fi
  printf 'install: %s installed, reloaded, and enabled --now; the node agent ships as a CLI with no unit (SPEC-043 M3/M5)\n' \
    "$(cp_unit_name chiefd)"
  return 0
}

cp_windows_steps() {
  # M9: this command never touches Windows; it prints the operator steps.
  cat <<'EOF'
Windows-side steps (this command never touches Windows):
  1. Task Scheduler: delete the logon task that starts WSL at logon.
     In an elevated PowerShell:  schtasks /Delete /TN <task-name> /F
  2. .wslconfig: the [wsl2] vmIdleTimeout line stays or goes — your choice.
  3. /etc/wsl.conf: the [boot] systemd=true line stays or goes — your choice.
     Remove it only if nothing else on this node needs systemd.
EOF
}

cp_remove() { # cp_remove <path> — M9 removal with the outcome line
  local path="$1"
  if [ -e "$path" ] || [ -L "$path" ]; then
    if rm -f -- "$path"; then
      printf 'removed: %s\n' "$path"
    else
      printf 'WARN: could not remove %s (SPEC-043 M9)\n' "$path" >&2
      return 1
    fi
  else
    printf 'absent: %s\n' "$path"
  fi
  return 0
}

cp_systemctl_soft() {
  # A removal verb whose failure is a note, never a halt — M9 exits 0.
  local rc=0
  cp_systemctl "$@" || rc=$?
  if [ "$rc" -ne 0 ]; then
    printf 'note: systemctl --user %s returned %s — continuing (SPEC-043 M9)\n' "$*" "$rc"
  fi
  return 0
}

cp_purge_legacy_units() {
  # A unit a pre-T8 install left behind is enabled with nothing left to run:
  # its binary is gone, so Restart=on-failure restart-loops it and the manager
  # answers `degraded`. Stop, disable, and remove it (SPEC-043 M5/M9).
  local unit path purged=0
  for unit in $CP_LEGACY_UNITS; do
    path="$(cp_unit_dir)/$unit"
    if [ ! -e "$path" ] && [ ! -L "$path" ]; then
      continue
    fi
    cp_systemctl_soft stop "$unit"
    cp_systemctl_soft disable "$unit"
    if cp_remove "$path"; then
      purged=1
    fi
  done
  # The purged unit leaves `failed` state in the manager, which is what keeps
  # it answering `degraded` (M2(b) reads that answer). Install runs this purge
  # too, so the reset rides a purge in both modes (SPEC-043 M5).
  if [ "$purged" -ne 0 ]; then
    cp_systemctl_soft reset-failed
  fi
  return 0
}

cp_uninstall() {
  local svc path unit
  if ! cp_sudo_guard; then
    return 2
  fi
  cp_banner uninstall
  for svc in $CP_UNIT_SERVICES; do
    unit=$(cp_unit_name "$svc")
    cp_systemctl_soft stop "$unit"
    cp_systemctl_soft disable "$unit"
    cp_remove "$(cp_unit_path "$svc")" || :
  done
  cp_purge_legacy_units
  # The node agent is an installed CLI (M3), so removal takes its binary too,
  # even though phase 1 ships no unit for it (M5).
  for svc in $CP_SERVICES; do
    cp_remove "$(cp_bin_path "$svc")" || :
  done
  cp_systemctl_soft daemon-reload
  # T7 P3: a unit that stop left in `failed` state keeps the user manager
  # answering `degraded` (and M2(b) reads that answer). The reset clears it so
  # the next install starts from a clean manager.
  cp_systemctl_soft reset-failed
  # The run journal is never read, moved, or deleted (SPEC-043 M9; ADR 0001).
  printf 'journal: untouched — control-plane/dist/journalctl still reads it (SPEC-043 M9)\n'
  cp_windows_steps
  return 0
}
