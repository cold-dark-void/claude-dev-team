#!/usr/bin/env bash
# skills/control-plane/test-units.sh — CDT-658 T2/T8 suite for units.sh.
#
# Hermetic (SPEC-043 Test): fake `docker`, fake `systemctl`, fake `uname`, a
# scratch $HOME (tests/lib/hermetic.sh), and a scratch checkout fixture. No
# network, no real container, no LLM, no systemd. bash + coreutils only; no
# bash-4/GNU-only constructs (SPEC-021 C1-C7).
#
# Coverage: the M5 chiefd template and the D1 rule (no node-agent unit), M3
# paths + modes, M4 build argv, M5 reload + enable, the legacy-unit purge,
# M12 write-only-when-differs, M9 uninstall + reset-failed + Windows steps +
# journal intact, AC4 sudo-deny and the approved-digest-only pin, M7 exit
# codes (0/2/63), AC11 nothing new on PATH, AC5 checkout guard.
#
# Run: bash skills/control-plane/test-units.sh   (exit 0 clean, 1 on any FAIL)
set -u

HERE=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
PLUGIN_ROOT=$(CDPATH= cd -- "$HERE/../.." && pwd)
UNITS="$HERE/units.sh"

# The AC4 guard cases need a non-elevated shell of our own.
if env | grep -q '^SUDO_'; then
  echo "SKIP: this suite runs under sudo — the AC4 guard cases need a clean env"
  exit 77
fi

# shellcheck source=../../tests/lib/hermetic.sh
. "$PLUGIN_ROOT/tests/lib/hermetic.sh"
# shellcheck source=../../tests/lib/mtimes.sh
. "$PLUGIN_ROOT/tests/lib/mtimes.sh"
hermetic_init

PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); printf 'PASS: %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf 'FAIL: %s\n' "$1" >&2; }

OUT=''
RC=0

has() { # has <needle> — OUT contains it
  case "$OUT" in
    *"$1"*) return 0 ;;
  esac
  return 1
}

# ---- fixtures ----------------------------------------------------------------

SCRATCH=$(mktemp -d "$TMPDIR/cp-units.XXXXXX")
FAKE_BIN="$SCRATCH/fakebin"
CHECKOUT="$SCRATCH/checkout"
DOCKER_LOG="$SCRATCH/docker.log"
SYSTEMCTL_LOG="$SCRATCH/systemctl.log"
mkdir -p "$FAKE_BIN" "$CHECKOUT/control-plane/cmd/node-agent" "$CHECKOUT/control-plane/cmd/chiefd"
printf 'module github.com/cold-dark-void/claude-dev-team/control-plane\n' >"$CHECKOUT/control-plane/go.mod"
: >"$DOCKER_LOG"
: >"$SYSTEMCTL_LOG"

# The journal the plugin must never touch (SPEC-043 M9; ADR 0001 boundary).
JOURNAL="$CHECKOUT/.claude/runs/run.db"
mkdir -p "$(dirname -- "$JOURNAL")"
printf 'journal row: run devteam-setup-probe completed\n' >"$JOURNAL"
cp -- "$JOURNAL" "$SCRATCH/journal.copy"

cat >"$FAKE_BIN/docker" <<'FAKE'
#!/usr/bin/env bash
# fake docker — logs argv; emulates `go build -o <rel> ./cmd/<pkg>` on the mount.
printf '%s\n' "$*" >>"${CP_FAKE_DOCKER_LOG:-/dev/null}"
if [ "${CP_FAKE_DOCKER_FAIL:-0}" = "1" ]; then
  echo "fake docker: compile error" >&2
  exit 1
fi
[ "${1:-}" = "run" ] || exit 0
mnt='' out='' pkg='' goos='' goarch='' prev=''
for a in "$@"; do
  case "$prev" in
    -v) mnt=${a%%:/src} ;;
    -o) out=$a ;;
    -e)
      case "$a" in
        GOOS=*) goos=${a#GOOS=} ;;
        GOARCH=*) goarch=${a#GOARCH=} ;;
      esac
      ;;
  esac
  case "$a" in
    ./cmd/*) pkg=${a#./cmd/} ;;
  esac
  prev=$a
done
if [ -z "$mnt" ] || [ -z "$out" ] || [ -z "$pkg" ]; then
  exit 0
fi
f="$mnt/control-plane/$out"
mkdir -p "$(dirname "$f")"
printf 'fake-binary %s %s/%s\n' "$pkg" "$goos" "$goarch" >"$f"
exit 0
FAKE

cat >"$FAKE_BIN/systemctl" <<'FAKE'
#!/usr/bin/env bash
# fake systemctl — logs argv; answers the state verbs from env.
printf '%s\n' "$*" >>"${CP_FAKE_SYSTEMCTL_LOG:-/dev/null}"
# argv is "--user <verb> [args...]"; drop the --user flag only.
shift 1 2>/dev/null || true
verb="${1:-}"
state="${CP_FAKE_SYSTEM_STATE:-running}"
if [ "$verb" = "is-system-running" ]; then
  printf '%s\n' "$state"
  # systemd exits 1 on degraded, 0 on running.
  if [ "$state" = "degraded" ]; then exit 1; fi
  exit 0
fi
if [ "${CP_FAKE_SYSTEMCTL_FAIL:-0}" = "1" ]; then exit 1; fi
exit 0
FAKE

cat >"$FAKE_BIN/uname" <<'FAKE'
#!/usr/bin/env bash
# fake uname — inert by default (this host is Linux/x86_64).
case "${1:-}" in
  -m) printf '%s\n' "${CP_FAKE_UNAME_M:-x86_64}" ;;
  -r) printf '%s\n' "${CP_FAKE_UNAME_R:-6.18.58.1-microsoft-standard-WSL2}" ;;
  *) printf '%s\n' "${CP_FAKE_UNAME_S:-Linux}" ;;
esac
FAKE

chmod 755 "$FAKE_BIN/docker" "$FAKE_BIN/systemctl" "$FAKE_BIN/uname"
PATH="$FAKE_BIN:$PATH"
export PATH CP_CHECKOUT_ROOT="$CHECKOUT" CP_FAKE_DOCKER_LOG="$DOCKER_LOG" \
  CP_FAKE_SYSTEMCTL_LOG="$SYSTEMCTL_LOG"

# Safety: every docker/systemctl/uname the module can reach is a fake, so no
# case can build a real container, touch a real unit, or hide WSL2.
for _f in docker systemctl uname; do
  if [ "$(command -v "$_f")" != "$FAKE_BIN/$_f" ]; then
    printf 'SETUP FAIL: %s does not resolve to the fake (%s)\n' "$_f" "$(command -v "$_f" 2>/dev/null || echo none)" >&2
    exit 1
  fi
done

# A PATH with the fakes and the coreutils cp_install needs, minus docker
# (SPEC-043 M2(e): docker absent is a preflight-shaped refusal).
NO_DOCKER="$SCRATCH/nodocker"
mkdir -p "$NO_DOCKER"
for _t in bash cat chmod cmp cp dirname env grep id ln mkdir mv rm sed stat touch uname; do
  _p=$(command -v "$_t" 2>/dev/null || true)
  [ -n "$_p" ] && ln -s "$_p" "$NO_DOCKER/$_t"
done
ln -s "$FAKE_BIN/systemctl" "$NO_DOCKER/systemctl"

BIN_DIR="$HOME/.local/bin"
UNIT_DIR="$HOME/.config/systemd/user"
UC="$UNIT_DIR/dev-team-chiefd.service"      # the one unit phase 1 ships (M5)
UL="$UNIT_DIR/dev-team-node-agent.service"  # the pre-T8 unit M5 drops
BA="$BIN_DIR/node-agent"
BC="$BIN_DIR/chiefd"

reset_state() { # fresh install targets + fake logs
  rm -rf "$HOME/.local" "$HOME/.config" "$CHECKOUT/control-plane/dist"
  : >"$DOCKER_LOG"
  : >"$SYSTEMCTL_LOG"
  export CP_FAKE_DOCKER_FAIL=0 CP_FAKE_SYSTEMCTL_FAIL=0
  export CP_FAKE_SYSTEM_STATE=running CP_FAKE_UNAME_S=Linux CP_FAKE_UNAME_M=x86_64
  export CP_CHECKOUT_ROOT="$CHECKOUT"
  unset CP_IMAGE
}

run_fn() { # run_fn <fn-name> [VAR=val ...] -> OUT (combined), RC
  local fn="$1"
  shift
  # $0 is `_`, so $1 is the module path. fn is a literal name from this suite.
  OUT=$(env "$@" bash -c ". \"\$1\" >/dev/null 2>&1; $fn" _ "$UNITS" 2>&1)
  RC=$?
}

mode_of() { stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1" 2>/dev/null; }

mtime_of() { stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null; }

count_lines() { # count_lines <regex> <file>
  local n
  n=$(grep -c -e "$1" "$2" 2>/dev/null || true)
  printf '%s\n' "${n:-0}"
}

clean_home() { # rc 0 when no install target exists
  [ ! -e "$BA" ] && [ ! -e "$BC" ] && [ ! -e "$UC" ] && [ ! -e "$UL" ]
}

journal_intact() { # rc 0 when the journal file is byte-identical
  [ -f "$JOURNAL" ] && cmp -s "$JOURNAL" "$SCRATCH/journal.copy"
}

# ---- 1. module contract ------------------------------------------------------

if bash "$UNITS" >/dev/null 2>&1; then
  bad "units.sh direct execution exits 0 (it is source-only)"
else
  RC=$?
  if [ "$RC" -eq 64 ]; then
    ok "units.sh refuses direct execution with exit 64 (source-only)"
  else
    bad "units.sh direct execution rc=$RC, expected 64"
  fi
fi

OUT=$(bash -c '. "$1" >/dev/null 2>&1; for f in cp_install cp_uninstall cp_build cp_banner \
  cp_unit_text cp_unit_name cp_unit_path cp_bin_path cp_bin_dir cp_unit_dir \
  cp_publish cp_publish_fn cp_checkout_root cp_host_goos cp_host_goarch \
  cp_deny_token cp_run cp_sudo_guard cp_assert_image_pin cp_windows_steps \
  cp_shape_guard cp_targets_ready cp_systemctl cp_remove cp_systemctl_soft \
  cp_purge_legacy_units; do \
  type "$f" >/dev/null 2>&1 || exit 1; done' _ "$UNITS" 2>&1)
RC=$?
if [ "$RC" -eq 0 ]; then
  ok "units.sh defines the full cp_* inventory"
else
  bad "units.sh is missing a cp_* function (rc $RC)"
fi

reset_state
if HOME="$HOME" bash -c '. "$1" >/dev/null' _ "$UNITS" && [ ! -e "$HOME/.local" ] && [ ! -e "$HOME/.config" ]; then
  ok "sourcing units.sh writes nothing (AC9 zero side effects)"
else
  bad "sourcing units.sh created install targets"
fi

# ---- 2. the M5 template + the D1 rule (no node-agent unit) -------------------

OUT=$(bash -c '. "$1" >/dev/null 2>&1; cp_unit_text node-agent' _ "$UNITS" 2>&1)
RC=$?
if [ "$RC" -ne 0 ] && ! printf '%s\n' "$OUT" | grep -q 'ExecStart'; then
  ok "cp_unit_text emits no node-agent unit (SPEC-043 M5, D1): rc $RC, no ExecStart"
else
  bad "cp_unit_text emitted a node-agent unit — SPEC-043 M5 ships chiefd only"
fi
if printf '%s\n' "$OUT" | grep -qF -e 'no unit in phase 1'; then
  ok "the node-agent unit refusal names the rule (SPEC-043 M5)"
else
  bad "the node-agent unit refusal is silent: $OUT"
fi
if bash -c '. "$1" >/dev/null 2>&1; cp_unit_name node-agent' _ "$UNITS" >/dev/null 2>&1; then
  bad "cp_unit_name answered for node-agent — a unit name must not exist (M5)"
else
  ok "cp_unit_name refuses node-agent (no unit name, M5)"
fi
if bash -c '. "$1" >/dev/null 2>&1; cp_unit_path node-agent' _ "$UNITS" >/dev/null 2>&1; then
  bad "cp_unit_path answered for node-agent (M5)"
else
  ok "cp_unit_path refuses node-agent (M5)"
fi
UNIT_SVCS=$(bash -c '. "$1" >/dev/null 2>&1; printf %s "$CP_UNIT_SERVICES"' _ "$UNITS" 2>&1)
if [ "$UNIT_SVCS" = 'chiefd' ]; then
  ok "CP_UNIT_SERVICES is chiefd only — one unit ships (SPEC-043 M5)"
else
  bad "CP_UNIT_SERVICES is '$UNIT_SVCS', expected 'chiefd'"
fi
BIN_SVCS=$(bash -c '. "$1" >/dev/null 2>&1; printf %s "$CP_SERVICES"' _ "$UNITS" 2>&1)
if [ "$BIN_SVCS" = 'node-agent chiefd' ]; then
  ok "CP_SERVICES still installs both binaries (SPEC-043 M3)"
else
  bad "CP_SERVICES is '$BIN_SVCS', expected 'node-agent chiefd'"
fi

OUT=$(bash -c '. "$1" >/dev/null 2>&1; cp_unit_text chiefd' _ "$UNITS" 2>&1)
for needle in '[Service]' 'ExecStart=%h/.local/bin/chiefd --addr 127.0.0.1:8090' \
  'Restart=on-failure' 'RestartSec=2s' 'WantedBy=default.target'; do
  if printf '%s\n' "$OUT" | grep -qF -e "$needle"; then
    ok "M5 chiefd unit carries: $needle"
  else
    bad "M5 chiefd unit is missing: $needle"
  fi
done
if printf '%s\n' "$OUT" | grep -Eq -e '--addr[[:space:]]+(0\.0\.0\.0|:|\[::\])' -e '0\.0\.0\.0'; then
  bad "M5 chiefd unit widens the bind beyond loopback"
else
  ok "M5 chiefd bind stays loopback (127.0.0.1:8090)"
fi

OUT=$(bash -c '. "$1" >/dev/null 2>&1; cp_unit_text dashboard' _ "$UNITS" 2>&1)
RC=$?
if [ "$RC" -ne 0 ] && ! printf '%s\n' "$OUT" | grep -q 'ExecStart'; then
  ok "cp_unit_text refuses an unknown service (rc $RC, no unit text)"
else
  bad "cp_unit_text emitted a unit for an unknown service"
fi

NAMES=$(bash -c '. "$1" >/dev/null 2>&1; cp_unit_name chiefd' _ "$UNITS" 2>&1)
if [ "$NAMES" = 'dev-team-chiefd.service' ]; then
  ok "M5 unit names: dev-team-chiefd.service is the only unit (one unit)"
else
  bad "M5 unit names are wrong: $NAMES"
fi

PATHS=$(bash -c '. "$1" >/dev/null 2>&1; cp_bin_path node-agent; cp_bin_path chiefd; cp_unit_path chiefd' _ "$UNITS" 2>&1)
EXPECTED=$(printf '%s\n%s\n%s\n' "$HOME/.local/bin/node-agent" "$HOME/.local/bin/chiefd" "$HOME/.config/systemd/user/dev-team-chiefd.service")
if [ "$PATHS" = "$EXPECTED" ]; then
  ok "M3 install paths are %h/.local/bin/<binary> and %h/.config/systemd/user/<unit>"
else
  bad "M3 install paths are wrong: $PATHS"
fi

# ---- 3. fresh install (AC1 happy path) ---------------------------------------

reset_state
run_fn cp_install
if [ "$RC" -eq 0 ]; then
  ok "install on a supported node exits 0 (SPEC-043 M7)"
else
  bad "install exited $RC, expected 0 — out: $OUT"
fi
if printf '%s\n' "$OUT" | grep -qF '== build ==' && printf '%s\n' "$OUT" | grep -qF '== install =='; then
  ok "install prints its phase banners (build, install)"
else
  bad "install printed no phase banners"
fi
if [ -f "$BA" ] && [ -f "$BC" ]; then
  ok "install places both binaries under \$HOME/.local/bin (M3)"
else
  bad "install did not place both binaries"
fi
MA=$(mode_of "$BA" 2>/dev/null)
MC=$(mode_of "$BC" 2>/dev/null)
if [ "$MA" = '755' ] && [ "$MC" = '755' ]; then
  ok "install sets binaries to mode 755 (M3)"
else
  bad "binary modes are $MA/$MC, expected 755"
fi
if [ -f "$UC" ] && [ ! -e "$UL" ]; then
  ok "install writes the chiefd unit and no node-agent unit (SPEC-043 M5, D1)"
else
  bad "install wrote the wrong unit set (chiefd=$([ -f "$UC" ] && echo yes || echo no), node-agent=$([ -e "$UL" ] && echo yes || echo no))"
fi
if [ "$(mode_of "$UC" 2>/dev/null)" = '644' ]; then
  ok "install sets the unit file to mode 644 (M3)"
else
  bad "unit mode is $(mode_of "$UC" 2>/dev/null), expected 644"
fi
bash -c '. "$1" >/dev/null 2>&1; cp_unit_text chiefd' _ "$UNITS" >"$SCRATCH/expect-c" 2>/dev/null
if cmp -s "$UC" "$SCRATCH/expect-c"; then
  ok "the installed unit is byte-identical to the M5 template"
else
  bad "the installed unit differs from cp_unit_text output"
fi
if grep -qF -e '--user daemon-reload' "$SYSTEMCTL_LOG" &&
  grep -qF -e '--user enable --now dev-team-chiefd.service' "$SYSTEMCTL_LOG"; then
  ok "install runs daemon-reload then enable --now on the chiefd unit (M5)"
else
  bad "install systemctl calls are wrong: $(tr '\n' '|' <"$SYSTEMCTL_LOG")"
fi
if grep -qF -e 'dev-team-node-agent.service' "$SYSTEMCTL_LOG"; then
  bad "install touched a node-agent unit — SPEC-043 M5 ships chiefd only"
else
  ok "install runs no systemctl verb for a node-agent unit (M5)"
fi
reload_line=$(grep -n -F -e '--user daemon-reload' "$SYSTEMCTL_LOG" | head -1 | cut -d: -f1)
enable_line=$(grep -n -F -e '--user enable --now' "$SYSTEMCTL_LOG" | head -1 | cut -d: -f1)
if [ -n "$reload_line" ] && [ -n "$enable_line" ] && [ "$reload_line" -lt "$enable_line" ]; then
  ok "daemon-reload precedes enable --now (M5 order)"
else
  bad "daemon-reload did not precede enable --now"
fi
if [ "$(count_lines 'docker.io/library/golang:1.27-bookworm@sha256:4fa7c968ba93f1635670522dbb01a2c78150443e1385746924566079f36570ea' "$DOCKER_LOG")" = '2' ]; then
  ok "the build uses the approved digest for both binaries (M2(f)/AC4)"
else
  bad "the build did not run twice on the approved digest"
fi
for needle in '--rm' '--user' '-e HOME=/tmp/gohome' '-e GOOS=linux' '-e GOARCH=amd64' \
  'CGO_ENABLED=0' 'GOCACHE=/tmp/gocache' 'GOMODCACHE=/tmp/gomodcache' \
  '-e GOFLAGS=-buildvcs=false' 'go build -o dist/node-agent ./cmd/node-agent' \
  'go build -o dist/chiefd ./cmd/chiefd'; do
  if grep -qF -e "$needle" "$DOCKER_LOG"; then
    ok "build argv carries: $needle (M4)"
  else
    bad "build argv is missing: $needle (M4)"
  fi
done
if grep -qF -e "--user $(id -u):$(id -g)" "$DOCKER_LOG"; then
  ok "build runs as the host user --user \$(id -u):\$(id -g) (M4)"
else
  bad "build did not pass --user \$(id -u):\$(id -g)"
fi
if grep -qF -e 'fake-binary node-agent linux/amd64' "$CHECKOUT/control-plane/dist/node-agent" &&
  grep -qF -e 'fake-binary chiefd linux/amd64' "$CHECKOUT/control-plane/dist/chiefd"; then
  ok "build outputs land in control-plane/dist with the host GOOS/GOARCH (M4)"
else
  bad "build outputs are missing or name the wrong target"
fi
if [ ! -e "$BIN_DIR/journalctl" ]; then
  ok "install puts no journalctl on PATH (AC11)"
else
  bad "install installed a journalctl name into $BIN_DIR"
fi
if [ -d "$BIN_DIR" ] && [ "$(ls -A "$BIN_DIR" | wc -l | tr -d ' ')" = '2' ] &&
  [ -f "$BA" ] && [ -f "$BC" ]; then
  ok "install writes exactly node-agent and chiefd into ~/.local/bin"
else
  bad "~/.local/bin holds the wrong set: $(ls -A "$BIN_DIR" 2>/dev/null | tr '\n' ' ')"
fi
if journal_intact; then
  ok "install leaves the run journal byte-identical (M9 / ADR 0001)"
else
  bad "install touched the run journal"
fi
if [ -z "$(ls -A "$TMPDIR" | grep -e 'dev-team-render' || true)" ]; then
  ok "install removes its render temp files (hazard: temp leak)"
else
  bad "install left a render temp file in TMPDIR"
fi

# ---- 4. M12 idempotent second run --------------------------------------------

touch_ago "$UC" 300
touch_ago "$BA" 300
touch_ago "$BC" 300
UC_M=$(mtime_of "$UC")
run_fn cp_install
if [ "$RC" -eq 0 ]; then
  ok "idempotent second install exits 0 (M12)"
else
  bad "idempotent second install exited $RC — out: $OUT"
fi
if [ "$(printf '%s\n' "$OUT" | grep -c '^unchanged:' || true)" = '3' ]; then
  ok "second install reports all three targets unchanged (M12 write-only-when-differs)"
else
  bad "second install did not report 3 unchanged targets: $(printf '%s\n' "$OUT" | tr '\n' '|')"
fi
NOW=$(date +%s)
for f in "$UC" "$BA" "$BC"; do
  m=$(mtime_of "$f")
  if [ -n "$m" ] && [ $((NOW - m)) -ge 200 ]; then
    ok "second install left the mtime of $(basename "$f") alone (no rewrite)"
  else
    bad "second install rewrote $(basename "$f") (age $((NOW - ${m:-0}))s)"
  fi
done
if cmp -s "$UC" "$SCRATCH/expect-c"; then
  ok "the unit file stays byte-identical across runs (AC2)"
else
  bad "the unit file bytes changed on the second run"
fi
if grep -qF -e '--user daemon-reload' "$SYSTEMCTL_LOG"; then
  ok "second install still reloads and re-enables (M12 state unchanged)"
else
  bad "second install skipped daemon-reload"
fi

printf 'ExecStart=/usr/local/bin/other\n' >"$UC"
run_fn cp_install
if [ "$RC" -eq 0 ] && cmp -s "$UC" "$SCRATCH/expect-c"; then
  ok "a tampered unit file is rewritten from the template (M12 compare is by content)"
else
  bad "a tampered unit file was not restored (rc $RC)"
fi

# ---- 5. AC4 sudo-deny --------------------------------------------------------

reset_state
run_fn cp_install SUDO_USER=root
if [ "$RC" -eq 2 ] && [ ! -s "$DOCKER_LOG" ] && clean_home; then
  ok "install refuses an elevated shell (SUDO_USER) with rc 2 and zero side effects (AC4)"
else
  bad "install ran under SUDO_USER (rc $RC, docker log $(wc -c <"$DOCKER_LOG") bytes)"
fi
if has 'elevated' && has 'AC4'; then
  ok "the sudo refusal names the cause and the fix (AC4)"
else
  bad "the sudo refusal printed no actionable message"
fi
run_fn cp_install SUDO_ASKPASS=/usr/bin/ssh-askpass
if [ "$RC" -eq 2 ] && clean_home; then
  ok "install refuses any SUDO_* name (SUDO_ASKPASS) with rc 2 (AC4)"
else
  bad "install ran with SUDO_ASKPASS set (rc $RC)"
fi
reset_state
OUT=$(bash -c '. "$1" >/dev/null 2>&1; cp_run systemctl --user daemon-reload; echo ran' _ "$UNITS" 2>&1)
RC=$?
if [ "$RC" -eq 0 ] && has 'ran'; then
  ok "cp_run passes a benign command through (no false positive)"
else
  bad "cp_run refused a benign systemctl call (rc $RC)"
fi
: >"$SYSTEMCTL_LOG"
OUT=$(bash -c '. "$1" >/dev/null 2>&1; cp_run sudo systemctl --user daemon-reload' _ "$UNITS" 2>&1)
RC=$?
if [ "$RC" -eq 2 ] && [ ! -s "$SYSTEMCTL_LOG" ]; then
  ok "cp_run refuses a sudo token: rc 2, the command never ran (AC4)"
else
  bad "cp_run executed a sudo token (rc $RC)"
fi
for tok in '/usr/bin/pkexec' 'su' 'pkexec'; do
  OUT=$(bash -c '. "$1" >/dev/null 2>&1; cp_run '"$tok"' true' _ "$UNITS" 2>&1)
  RC=$?
  if [ "$RC" -eq 2 ]; then
    ok "cp_run refuses the elevation token $tok (AC4)"
  else
    bad "cp_run allowed $tok (rc $RC)"
  fi
done

CODE=$(sed -e 's/#.*$//' "$UNITS")
if printf '%s\n' "$CODE" | grep -Eq -e '(^|[;&|(`$])[[:space:]]*(sudo|pkexec)([[:space:]]|$)'; then
  bad "units.sh runs an elevation command in code position (AC4 static)"
else
  ok "units.sh has no elevation command in code position (AC4 static)"
fi
if [ "$(count_lines 'docker\.io/' "$UNITS")" = '1' ] &&
  grep -qF -e 'docker.io/library/golang:1.27-bookworm@sha256:4fa7c968ba93f1635670522dbb01a2c78150443e1385746924566079f36570ea' "$UNITS" &&
  [ "$(count_lines 'golang:' "$UNITS")" = '1' ] &&
  ! printf '%s\n' "$CODE" | grep -Eq -e '(golang|alpine|ubuntu):[A-Za-z0-9._-]+$'; then
  ok "units.sh references exactly one image: the approved digest (AC4 static)"
else
  bad "units.sh carries a second image reference (AC4)"
fi

# ---- 6. preflight-shaped refusals, zero side effects -------------------------

reset_state
run_fn cp_install CP_IMAGE=docker.io/library/golang:1.27-bookworm
if [ "$RC" -eq 2 ] && [ ! -s "$DOCKER_LOG" ] && clean_home; then
  ok "a tag-only image reference is refused before any pull or build (M2(f))"
else
  bad "a tag-only image reference reached docker (rc $RC)"
fi
reset_state
run_fn cp_install CP_IMAGE=alpine:latest
if [ "$RC" -eq 2 ] && [ ! -s "$DOCKER_LOG" ] && clean_home; then
  ok "an unapproved image is refused with rc 2 and zero side effects (AC4)"
else
  bad "an unapproved image reached docker (rc $RC)"
fi
reset_state
run_fn cp_install CP_FAKE_UNAME_S=Darwin
if [ "$RC" -eq 63 ] && [ ! -s "$DOCKER_LOG" ] && clean_home; then
  ok "macOS exits 63 with zero side effects (SPEC-043 M7/AC8)"
else
  bad "the Darwin shape guard returned $RC"
fi
reset_state
run_fn cp_install CP_FAKE_SYSTEM_STATE=offline
if [ "$RC" -eq 63 ] && clean_home && ! grep -qF -e 'daemon-reload' "$SYSTEMCTL_LOG"; then
  ok "an unusable systemd user manager exits 63 with zero side effects (M2(b))"
else
  bad "the systemd shape guard returned $RC for offline"
fi
reset_state
run_fn cp_install CP_FAKE_SYSTEM_STATE=degraded
if [ "$RC" -eq 0 ]; then
  ok "a degraded user manager is a supported shape (M2(b): running|degraded)"
else
  bad "a degraded manager was refused (rc $RC) — out: $OUT"
fi
reset_state
mkdir -p "$SCRATCH/no-gomod/control-plane"
run_fn cp_install CP_CHECKOUT_ROOT="$SCRATCH/no-gomod"
if [ "$RC" -eq 63 ] && clean_home && [ ! -s "$DOCKER_LOG" ]; then
  ok "a checkout without control-plane/go.mod exits 63 with zero writes (AC5/AC8)"
else
  bad "the checkout guard returned $RC"
fi
reset_state
run_fn cp_install PATH="$NO_DOCKER"
if [ "$RC" -eq 2 ] && clean_home; then
  ok "docker absent from PATH exits non-zero before any write (AC9)"
else
  bad "the docker-absent path returned $RC"
fi
reset_state
run_fn cp_install CP_FAKE_DOCKER_FAIL=1
if [ "$RC" -eq 2 ] && clean_home && ! grep -qF -e 'daemon-reload' "$SYSTEMCTL_LOG" && has 'build FAILED'; then
  ok "a build failure exits 2, enables nothing, and names the phase (AC9)"
else
  bad "the build-failure path returned $RC — out: $OUT"
fi
reset_state
run_fn cp_install CP_FAKE_SYSTEMCTL_FAIL=1
if [ "$RC" -eq 2 ] && [ -f "$UC" ] && has 'daemon-reload FAILED'; then
  ok "a failed daemon-reload exits 2 with the fix line (M5 fail mode)"
else
  bad "the daemon-reload failure path returned $RC — out: $OUT"
fi

# ---- 7. M9 uninstall ---------------------------------------------------------

reset_state
run_fn cp_install
if [ "$RC" -ne 0 ]; then
  bad "setup for the uninstall cases failed (rc $RC)"
fi
: >"$SYSTEMCTL_LOG"
: >"$DOCKER_LOG"
run_fn cp_uninstall
if [ "$RC" -eq 0 ]; then
  ok "uninstall exits 0 (SPEC-043 M9)"
else
  bad "uninstall exited $RC — out: $OUT"
fi
if printf '%s\n' "$OUT" | grep -qF '== uninstall =='; then
  ok "uninstall prints its phase banner"
else
  bad "uninstall printed no phase banner"
fi
if clean_home; then
  ok "uninstall removes the unit and both binaries (AC3)"
else
  bad "uninstall left an install target behind"
fi
for needle in '--user stop dev-team-chiefd.service' '--user disable dev-team-chiefd.service' \
  '--user daemon-reload' '--user reset-failed'; do
  if grep -qF -e "$needle" "$SYSTEMCTL_LOG"; then
    ok "uninstall ran: systemctl $needle (M9)"
  else
    bad "uninstall did not run: systemctl $needle"
  fi
done
if grep -qF -e 'dev-team-node-agent.service' "$SYSTEMCTL_LOG"; then
  bad "uninstall ran a verb for a node-agent unit that was never installed (M5)"
else
  ok "uninstall runs no node-agent unit verb on a clean node (M5)"
fi
dr_line=$(grep -n -F -e '--user daemon-reload' "$SYSTEMCTL_LOG" | head -1 | cut -d: -f1)
rf_line=$(grep -n -F -e '--user reset-failed' "$SYSTEMCTL_LOG" | head -1 | cut -d: -f1)
if [ -n "$dr_line" ] && [ -n "$rf_line" ] && [ "$dr_line" -lt "$rf_line" ]; then
  ok "reset-failed follows daemon-reload (M9 / AC3: the manager leaves the failed state)"
else
  bad "reset-failed did not follow daemon-reload (dr=${dr_line:-none} rf=${rf_line:-none})"
fi
if has 'Windows-side steps' && has 'Task Scheduler' && has 'schtasks /Delete' &&
  has '.wslconfig' && has 'wsl.conf'; then
  ok "uninstall prints the Windows operator steps and never touches Windows (M9/AC3)"
else
  bad "uninstall printed no Windows operator steps"
fi
if journal_intact; then
  ok "uninstall leaves the journal byte-identical and present (AC3)"
else
  bad "uninstall touched the journal"
fi
if [ ! -s "$DOCKER_LOG" ]; then
  ok "uninstall runs no docker command (M9 is Linux-side removal)"
else
  bad "uninstall ran docker"
fi

reset_state
run_fn cp_uninstall
if [ "$RC" -eq 0 ] && has 'absent:' && grep -qF -e '--user daemon-reload' "$SYSTEMCTL_LOG"; then
  ok "uninstall on an uninstalled node exits 0 and reports the targets absent (M9)"
else
  bad "the nothing-to-remove uninstall path returned $RC — out: $OUT"
fi
reset_state
run_fn cp_uninstall SUDO_USER=root
if [ "$RC" -eq 2 ]; then
  ok "uninstall refuses an elevated shell with rc 2 (AC4 outranks the M9 0)"
else
  bad "uninstall ran under SUDO_USER (rc $RC)"
fi

# ---- 8. cp_publish (M12 write mechanics) -------------------------------------

reset_state
mkdir -p "$SCRATCH/pub"
printf 'aaa\n' >"$SCRATCH/pub/src"
OUT=$(bash -c '. "$1" >/dev/null 2>&1; cp_publish "$2" "$3" 644' _ "$UNITS" "$SCRATCH/pub/src" "$SCRATCH/pub/dest" 2>&1)
RC=$?
if [ "$RC" -eq 0 ] && [ "$(mode_of "$SCRATCH/pub/dest")" = '644' ]; then
  ok "cp_publish writes mode 644 for a new file"
else
  bad "cp_publish new-file mode is $(mode_of "$SCRATCH/pub/dest" 2>/dev/null) (rc $RC)"
fi
OUT=$(bash -c '. "$1" >/dev/null 2>&1; cp_publish "$2" "$3" 644' _ "$UNITS" "$SCRATCH/pub/src" "$SCRATCH/pub/dest" 2>&1)
RC=$?
if [ "$RC" -eq 0 ] && has 'unchanged:'; then
  ok "cp_publish skips a byte-identical target (M12)"
else
  bad "cp_publish rewrote an identical target (rc $RC)"
fi
printf 'bbb\n' >"$SCRATCH/pub/src"
OUT=$(bash -c '. "$1" >/dev/null 2>&1; cp_publish "$2" "$3" 644' _ "$UNITS" "$SCRATCH/pub/src" "$SCRATCH/pub/dest" 2>&1)
RC=$?
if [ "$RC" -eq 0 ] && has 'installed:' && grep -qF -e 'bbb' "$SCRATCH/pub/dest"; then
  ok "cp_publish replaces a target whose content differs (M12)"
else
  bad "cp_publish did not replace a changed target (rc $RC)"
fi
ln -s "$SCRATCH/pub/src" "$SCRATCH/pub/link"
OUT=$(bash -c '. "$1" >/dev/null 2>&1; cp_publish "$2" "$3" 644' _ "$UNITS" "$SCRATCH/pub/src" "$SCRATCH/pub/link" 2>&1)
RC=$?
if [ "$RC" -ne 0 ] && [ -L "$SCRATCH/pub/link" ] &&
  [ "$(readlink "$SCRATCH/pub/link")" = "$SCRATCH/pub/src" ]; then
  ok "cp_publish refuses to write through a symlink (check-then-act safe)"
else
  bad "cp_publish wrote through a symlink (rc $RC)"
fi
OUT=$(bash -c '. "$1" >/dev/null 2>&1; cp_publish "$2" "$3" 644' _ "$UNITS" "$SCRATCH/pub/nope" "$SCRATCH/pub/dest2" 2>&1)
RC=$?
if [ "$RC" -ne 0 ] && [ ! -e "$SCRATCH/pub/dest2" ]; then
  ok "cp_publish with a missing source writes nothing and fails (rc $RC)"
else
  bad "cp_publish created a target from a missing source"
fi

# ---- 9. the pre-T8 node-agent unit (SPEC-043 M5/M9 purge) -------------------

reset_state
mkdir -p "$UNIT_DIR"
printf '[Unit]\nDescription=pre-T8 node agent\n[Install]\nWantedBy=default.target\n' >"$UL"
: >"$SYSTEMCTL_LOG"
run_fn cp_install
if [ "$RC" -eq 0 ] && [ ! -e "$UL" ] && [ -f "$UC" ]; then
  ok "install stops, disables, and removes a pre-T8 node-agent unit (M5, the T7 P0)"
else
  bad "install left the legacy unit in place (rc $RC, legacy=$([ -e "$UL" ] && echo yes || echo no))"
fi
if grep -qF -e '--user stop dev-team-node-agent.service' "$SYSTEMCTL_LOG" &&
  grep -qF -e '--user disable dev-team-node-agent.service' "$SYSTEMCTL_LOG"; then
  ok "the legacy purge stops and disables the unit before removing it (M5)"
else
  bad "the legacy purge ran no stop/disable: $(tr '\n' '|' <"$SYSTEMCTL_LOG")"
fi
dis_line=$(grep -n -F -e '--user disable dev-team-node-agent.service' "$SYSTEMCTL_LOG" | head -n 1 | cut -d: -f1)
rf_line=$(grep -n -F -e '--user reset-failed' "$SYSTEMCTL_LOG" | head -n 1 | cut -d: -f1)
if [ -n "$rf_line" ] && [ -n "$dis_line" ] && [ "$rf_line" -gt "$dis_line" ]; then
  ok "the install purge resets failed units after the legacy removal (M5, the T9 P3)"
else
  bad "the install purge left the manager in failed state (disable=${dis_line:-none} reset=${rf_line:-none})"
fi
reset_state
run_fn cp_install
if [ "$RC" -eq 0 ] && ! grep -qF -e 'dev-team-node-agent.service' "$SYSTEMCTL_LOG" &&
  ! grep -qF -e '--user reset-failed' "$SYSTEMCTL_LOG"; then
  ok "install with no legacy unit runs no legacy verbs and no reset (no phantom work)"
else
  bad "install ran legacy verbs on a clean node (rc $RC): $(tr '\n' '|' <"$SYSTEMCTL_LOG")"
fi
reset_state
mkdir -p "$UNIT_DIR"
printf '[Unit]\nDescription=pre-T8 node agent\n' >"$UL"
: >"$SYSTEMCTL_LOG"
run_fn cp_uninstall
if [ "$RC" -eq 0 ] && [ ! -e "$UL" ] &&
  grep -qF -e '--user disable dev-team-node-agent.service' "$SYSTEMCTL_LOG"; then
  ok "uninstall removes a pre-T8 node-agent unit too (M9)"
else
  bad "uninstall left the legacy unit (rc $RC) — out: $OUT"
fi

echo
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
RC=$?
echo "VERIFY exit=$RC"
exit "$RC"
