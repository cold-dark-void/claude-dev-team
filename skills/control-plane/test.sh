#!/usr/bin/env bash
# skills/control-plane/test.sh — CDT-658 T3/T8 suite for the setup driver.
#
# Hermetic end-to-end (SPEC-043 Test): fakes for `docker`, `systemctl`,
# `loginctl`, `uname`, `curl`, and BOTH service CLIs (the driver calls them by
# their control-plane/dist/ path, so the build fake plants an executable fake
# in dist/ and the real dist-path call is exercised — AC11). Scratch $HOME and
# TMPDIR via tests/lib/hermetic.sh. No network, no real container, no systemd,
# no LLM. bash + coreutils only; no bash-4/GNU-only constructs (SPEC-021 C1-C7).
#
# Coverage: M1 dispatch, M6 table + footer, M7/AC12 exit-code matrix, M11/M12
# probe flow with the T0 rulings (start only, journal-state branch, hygiene)
# and the M11 runner override, AC1/AC2/AC3 (one unit + reset-failed), AC6
# read-only runner, AC7 WSL2 rows, AC8/AC9 fail-closed, AC10 linger, AC11 dist
# path, AC13 hygiene, the M5 ExecStart target run for real by the fake manager,
# and the record-status single home.
#
# Run: bash skills/control-plane/test.sh   (exit 0 clean, 1 on any FAIL)
set -u

HERE=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
PLUGIN_ROOT=$(CDPATH= cd -- "$HERE/../.." && pwd)
SETUP="$HERE/setup.sh"
RECORD="$PLUGIN_ROOT/skills/lib/record-status.sh"
APPROVED='docker.io/library/golang:1.27-bookworm@sha256:4fa7c968ba93f1635670522dbb01a2c78150443e1385746924566079f36570ea'
PROBE_ID='devteam-setup-probe'

# The AC4 cases need a non-elevated shell of our own.
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
# CDT-620 T2 (CDT-646 pattern, as skills/council/test-tier-grade.sh does it):
# collect the failing check labels and print them as a block at the end, so
# every failing name lands inside the runner's 20-line failure tail (the
# inline FAIL lines scroll far above it). Additive: checks, order and counters
# are unchanged (141).
FAILED_LABELS=""
record_fail() { FAILED_LABELS="$FAILED_LABELS$1\n"; }
ok() { PASS=$((PASS + 1)); printf 'PASS: %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf 'FAIL: %s\n' "$1" >&2; record_fail "$1"; }

OUT=''
RC=0

has() { # has <needle> — OUT contains it
  case "$OUT" in
    *"$1"*) return 0 ;;
  esac
  return 1
}

count_lines() { # count_lines <regex> <file>
  local n
  n=$(grep -c -e "$1" "$2" 2>/dev/null || true)
  printf '%s\n' "${n:-0}"
}

mode_of() { stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1" 2>/dev/null; }

mtime_of() { stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null; }

# ---- fixtures ----------------------------------------------------------------

SCRATCH=$(mktemp -d "$TMPDIR/cp-setup.XXXXXX")
FAKE_BIN="$SCRATCH/fakebin"
SVC_FAKE="$SCRATCH/svcfake"
STATE="$SCRATCH/state"
CHECKOUT="$SCRATCH/checkout"
mkdir -p "$FAKE_BIN" "$SVC_FAKE" "$STATE" \
  "$CHECKOUT/control-plane/cmd/node-agent" "$CHECKOUT/control-plane/cmd/chiefd" \
  "$CHECKOUT/control-plane/cmd/journalctl" "$CHECKOUT/.claude/runs/agent"

printf 'module github.com/cold-dark-void/claude-dev-team/control-plane\n' >"$CHECKOUT/control-plane/go.mod"
printf "IMAGE='%s'\n" "$APPROVED" >"$CHECKOUT/control-plane/build.sh"

# The journal the plugin must never touch (SPEC-043 M9; ADR 0001).
JOURNAL="$CHECKOUT/.claude/runs/run.db"
printf 'journal row: devteam-setup-probe run_started\njournal row: devteam-setup-probe run_completed\n' >"$JOURNAL"
cp -- "$JOURNAL" "$SCRATCH/journal.copy"

DOCKER_LOG="$STATE/docker.log"
SYSTEMCTL_LOG="$STATE/systemctl.log"
JOURNAL_LOG="$STATE/journalctl.log"
AGENT_LOG="$STATE/agent.log"
CURL_LOG="$STATE/curl.log"
LOGINCTL_LOG="$STATE/loginctl.log"
JOURNAL_STATE="$STATE/journal-state"
STOP_FLAG="$STATE/stop-called"
EXEC_LOG="$STATE/execstart.log"
DB_CREATE_LOG="$STATE/journal-db-created.log"
NODE_JSON="$CHECKOUT/.claude/dev-team/node.json"
: >"$DOCKER_LOG"; : >"$SYSTEMCTL_LOG"; : >"$JOURNAL_LOG"
: >"$AGENT_LOG"; : >"$CURL_LOG"; : >"$LOGINCTL_LOG"; : >"$EXEC_LOG"
: >"$STOP_FLAG"
printf 'norows\n' >"$JOURNAL_STATE"

# ---- the service-CLI fakes (planted into control-plane/dist by the build) ----

cat >"$SVC_FAKE/journalctl" <<'FAKE'
#!/usr/bin/env bash
# fake control-plane/dist/journalctl — argv is logged with $0 so the suite can
# prove the driver called it by its dist path (SPEC-043 AC11).
printf '%s %s\n' "$0" "$*" >>"${CP_FAKE_JOURNAL_LOG:-/dev/null}"
if [ "${1:-}" != "read" ]; then
  printf 'fake journalctl: unknown verb\n' >&2
  exit 64
fi
if [ "${CP_FAKE_JOURNAL_ERR:-0}" = "1" ]; then
  printf 'journalctl read: unable to open database file: disk full\n' >&2
  exit 1
fi
# The real CLI opens the database it is asked to read, and journal.OpenPath
# creates it (MkdirAll + schema) when it is absent. The fake models that, so a
# driver that skips the read is provably the reason no database appears
# (SPEC-043 M1: --status writes nothing on a fresh node).
shift
fdb=''
while [ $# -gt 0 ]; do
  case "$1" in
    --db)
      fdb="${2:-}"
      shift 2 2>/dev/null || shift $#
      ;;
    *) shift ;;
  esac
done
if [ -n "$fdb" ] && [ ! -f "$fdb" ]; then
  mkdir -p "$(dirname -- "$fdb")"
  : >"$fdb"
  printf 'created %s\n' "$fdb" >>"${CP_FAKE_DB_CREATE_LOG:-/dev/null}"
fi
st=''
if [ -f "${CP_FAKE_STATE_FILE:-}" ]; then
  st=$(head -n 1 "$CP_FAKE_STATE_FILE" 2>/dev/null)
fi
if [ -z "$st" ] || [ "$st" = "norows" ]; then
  printf 'journalctl read: no events for run "devteam-setup-probe" in %s\n' "${DEVTEAM_RUN_DB:-run.db}" >&2
  exit 1
fi
printf '%s\n' "$st"
exit 0
FAKE

cat >"$SVC_FAKE/node-agent" <<'FAKE'
#!/usr/bin/env bash
# fake control-plane/dist/node-agent — the T0 behaviours:
#   start on a run with no rows spawns, journals completed, removes the pidfile
#   start on a terminal run REFUSES (exit 1, "run is terminal") — spec § Q1a
#   stop is a suite failure: the probe flow must never call it — spec § Q1b
# The log line carries $DEVTEAM_RUNNER so the suite can prove the M11
# per-invocation override lands on the child.
printf '%s %s [DEVTEAM_RUNNER=%s]\n' "$0" "$*" "${DEVTEAM_RUNNER:-}" >>"${CP_FAKE_AGENT_LOG:-/dev/null}"
verb="${1:-}"
shift 2>/dev/null || true
runid=''
cmd=''
while [ $# -gt 0 ]; do
  case "$1" in
    --run-id) runid=${2:-}; shift 2 ;;
    --command) cmd=${2:-}; shift 2 ;;
    --db) shift 2 ;;
    *) shift ;;
  esac
done
pf="${DEVTEAM_MROOT:-.}/.claude/runs/agent/${runid:-unknown}.pid"
st=''
if [ -f "${CP_FAKE_STATE_FILE:-}" ]; then
  st=$(head -n 1 "$CP_FAKE_STATE_FILE" 2>/dev/null)
fi
case "$verb" in
  start)
    case "${CP_FAKE_NA_START_FAIL:-}" in
      lease)
        printf 'node-agent start: journal: lease held by another owner: host:4242 (token 1, heartbeat 2026-11-19T17:00:00Z, limit 108s)\n' >&2
        exit 1 ;;
      terminal)
        printf 'node-agent start: journal: run is terminal: run %s is completed\n' "$runid" >&2
        exit 1 ;;
      boom)
        printf 'agent: spawn %s: executable file not found in $PATH\n' "$cmd" >&2
        exit 1 ;;
    esac
    case "$st" in
      *'"terminal":true'*)
        printf 'node-agent start: journal: run is terminal: run %s is completed\n' "$runid" >&2
        exit 1 ;;
    esac
    mkdir -p "$(dirname -- "$pf")"
    printf '%s\n' "$$" >"$pf"
    case "${CP_FAKE_NA_PIDFILE:-none}" in
      live) printf '%s\n' "${CP_FAKE_NA_PIDFILE_PID:-1}" >"$pf" ;;
      dead) printf '%s\n' "${CP_FAKE_NA_PIDFILE_PID:-1}" >"$pf" ;;
      *) rm -f -- "$pf" ;;
    esac
    printf '{"run_id":"%s","status":"completed","terminal":true,"stall_limit_s":108,"last_heartbeat_ts":"2026-11-19T17:00:00Z"}\n' "$runid" >"$CP_FAKE_STATE_FILE"
    printf 'ok\n'
    exit 0 ;;
  stop)
    printf 'STOP-CALLED\n' >>"${CP_FAKE_STOP_FLAG:-/dev/null}"
    printf 'agent: run has no live runner process: %s is completed\n' "$runid" >&2
    exit 1 ;;
  status)
    printf '{"run_id":"%s","state":"completed"}\n' "$runid"
    exit 0 ;;
  status-node)
    printf '{"runner":"native","source":"none"}\n'
    exit 0 ;;
esac
printf 'fake node-agent: unknown verb\n' >&2
exit 64
FAKE

chmod 755 "$SVC_FAKE/journalctl" "$SVC_FAKE/node-agent"

# ---- the host-command fakes -------------------------------------------------

cat >"$FAKE_BIN/docker" <<'FAKE'
#!/usr/bin/env bash
# fake docker — logs argv; emulates `go build -o <rel> ./cmd/<pkg>` on the
# mount, planting the service fakes so the dist-path calls are real, and
# answers `docker ps` from the env.
printf '%s\n' "$*" >>"${CP_FAKE_DOCKER_LOG:-/dev/null}"
if [ "${1:-}" = "ps" ]; then
  if [ "${CP_FAKE_DOCKER_PS_FAIL:-0}" = "1" ]; then
    printf 'fake docker: cannot connect to the daemon\n' >&2
    exit 1
  fi
  printf '%s\n' "${CP_FAKE_DOCKER_PS:-}" | sed '/^$/d'
  exit 0
fi
# CP_FAKE_DOCKER_FAIL is a compile failure: `docker info` stays healthy, so the
# case lands in the build phase, not in preflight.
if [ "${CP_FAKE_DOCKER_FAIL:-0}" = "1" ] && [ "${1:-}" = "run" ]; then
  printf 'fake docker: compile error\n' >&2
  exit 1
fi
[ "${1:-}" = "run" ] || exit 0
mnt='' out='' pkg=''
prev=''
for a in "$@"; do
  case "$prev" in
    -v) mnt=${a%%:/src} ;;
    -o) out=$a ;;
  esac
  case "$a" in
    ./cmd/*) pkg=${a#./cmd/} ;;
  esac
  prev=$a
done
[ -n "$mnt" ] && [ -n "$out" ] && [ -n "$pkg" ] || exit 0
f="$mnt/control-plane/$out"
mkdir -p "$(dirname -- "$f")"
case "$pkg" in
  node-agent | journalctl) cp -- "$CP_FAKE_SVC_DIR/$pkg" "$f" ;;
  chiefd)
    if [ "${CP_FAKE_EXECUTABLE:-0}" = "1" ]; then
      # An executable chiefd: the ExecStart case runs the installed binary the
      # way systemd does, so it must be a real program that reports its argv.
      cat >"$f" <<'STUB'
#!/usr/bin/env bash
printf '%s %s\n' "$0" "$*" >>"${CP_FAKE_EXEC_LOG:-/dev/null}"
exit "${CP_FAKE_EXEC_RC:-0}"
STUB
    else
      printf 'fake-binary %s\n' chiefd >"$f"
    fi
    chmod 755 "$f"
    exit 0 ;;
  *) printf 'fake-binary %s\n' "$pkg" >"$f" ;;
esac
chmod 755 "$f"
exit 0
FAKE

cat >"$FAKE_BIN/systemctl" <<'FAKE'
#!/usr/bin/env bash
# fake systemctl — logs argv; answers the state verbs from env.
printf '%s\n' "$*" >>"${CP_FAKE_SYSTEMCTL_LOG:-/dev/null}"
shift 1 2>/dev/null || true
verb="${1:-}"
unit=''
for a in "$@"; do
  case "$a" in *.service) unit="$a" ;; esac
done
state="${CP_FAKE_SYSTEM_STATE:-running}"
case "$verb" in
  is-system-running)
    printf '%s\n' "$state"
    if [ "$state" = "degraded" ]; then exit 1; fi
    exit 0 ;;
  is-active)
    printf '%s\n' "${CP_FAKE_UNIT_ACTIVE:-active}"
    if [ "${CP_FAKE_UNIT_ACTIVE:-active}" = "active" ]; then exit 0; fi
    exit 3 ;;
  is-enabled)
    printf '%s\n' "${CP_FAKE_UNIT_ENABLED:-enabled}"
    if [ "${CP_FAKE_UNIT_ENABLED:-enabled}" = "enabled" ]; then exit 0; fi
    exit 1 ;;
esac
if [ "${CP_FAKE_SYSTEMCTL_FAIL:-0}" = "1" ]; then exit 1; fi
if { [ "$verb" = "enable" ] || [ "$verb" = "start" ]; } &&
  [ "${CP_FAKE_SYSTEMCTL_EXEC:-0}" = "1" ] && [ -n "$unit" ]; then
  # Run the unit the way the manager does: read ExecStart, expand %h, exec it,
  # answer with its exit code (SPEC-043 M5, the T7 real-node shape).
  uf="${CP_FAKE_UNIT_DIR:-$HOME/.config/systemd/user}/$unit"
  line=$(sed -n 's/^ExecStart=//p' "$uf" 2>/dev/null | head -n 1)
  if [ -z "$line" ]; then
    printf 'fake systemctl: no ExecStart in %s\n' "$uf" >&2
    exit 1
  fi
  line=${line//%h/$HOME}
  # The scratch unit paths this suite writes carry no spaces, so the split is
  # the argv systemd passes.
  set -- $line
  "$@"
  rc=$?
  printf 'execstart %s rc=%s\n' "$unit" "$rc" >>"${CP_FAKE_EXEC_LOG:-/dev/null}"
  exit "$rc"
fi
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

cat >"$FAKE_BIN/loginctl" <<'FAKE'
#!/usr/bin/env bash
# fake loginctl — `show-user <name> -p Linger` answers one Key=value line
# (the T0 § Q2 shape).
printf '%s\n' "$*" >>"${CP_FAKE_LOGINCTL_LOG:-/dev/null}"
if [ "${CP_FAKE_LOGINCTL_FAIL:-0}" = "1" ]; then
  printf 'FakeUser1000\n' >&2
  exit 1
fi
printf 'Linger=%s\n' "${CP_FAKE_LINGER:-no}"
exit 0
FAKE

cat >"$FAKE_BIN/curl" <<'FAKE'
#!/usr/bin/env bash
# fake curl — logs argv, answers the chiefd API GET from env.
printf '%s\n' "$*" >>"${CP_FAKE_CURL_LOG:-/dev/null}"
if [ "${CP_FAKE_CURL_FAIL:-0}" = "1" ]; then
  printf 'curl: (7) Failed to connect to 127.0.0.1 port 8090\n' >&2
  exit 7
fi
printf '200\n'
exit 0
FAKE

chmod 755 "$FAKE_BIN/docker" "$FAKE_BIN/systemctl" "$FAKE_BIN/uname" \
  "$FAKE_BIN/loginctl" "$FAKE_BIN/curl"

PATH="$FAKE_BIN:$PATH"
export PATH CP_FAKE_SVC_DIR="$SVC_FAKE"

# Safety: every host command the driver can reach is a fake, so no case can
# build a real container, touch a real unit, or hide WSL2.
for _f in docker systemctl uname loginctl curl; do
  if [ "$(command -v "$_f")" != "$FAKE_BIN/$_f" ]; then
    printf 'SETUP FAIL: %s does not resolve to the fake (%s)\n' "$_f" "$(command -v "$_f" 2>/dev/null || echo none)" >&2
    exit 1
  fi
done

# A PATH with jq hidden: the journal-state parser falls back to awk (SPEC-043
# M12 branch), so the fallback needs its own coverage.
NO_JQ="$SCRATCH/nojq"
mkdir -p "$NO_JQ"
for _t in awk basename bash cat chmod cmp cp cut date dirname env grep head id \
  ln mkdir mv mktemp rm sed sleep stat touch tr uname wc; do
  _p=$(command -v "$_t" 2>/dev/null || true)
  [ -n "$_p" ] && ln -s "$_p" "$NO_JQ/$_t"
done
for _f in docker systemctl uname loginctl curl; do
  ln -s "$FAKE_BIN/$_f" "$NO_JQ/$_f"
done

BIN_DIR="$HOME/.local/bin"
UNIT_DIR="$HOME/.config/systemd/user"
UL="$UNIT_DIR/dev-team-node-agent.service"  # the pre-T8 unit SPEC-043 M5 drops
UC="$UNIT_DIR/dev-team-chiefd.service"
BA="$BIN_DIR/node-agent"
BC="$BIN_DIR/chiefd"
PIDFILE="$CHECKOUT/.claude/runs/agent/$PROBE_ID.pid"
WSLCONF="$SCRATCH/wsl.conf"

# A live process for the AC13 hygiene FAIL fixture.
sleep 300 >/dev/null 2>&1 &
LIVED=$!

reset_state() { # fresh install targets, fresh logs, WSL2-with-systemd node
  rm -rf "$HOME/.local" "$HOME/.config" "$CHECKOUT/control-plane/dist"
  rm -f -- "$PIDFILE"
  mkdir -p "$CHECKOUT/.claude/runs/agent"
  printf 'journal row: devteam-setup-probe run_started\njournal row: devteam-setup-probe run_completed\n' >"$JOURNAL"
  cp -- "$JOURNAL" "$SCRATCH/journal.copy"
  : >"$DOCKER_LOG"; : >"$SYSTEMCTL_LOG"; : >"$JOURNAL_LOG"
  : >"$AGENT_LOG"; : >"$CURL_LOG"; : >"$LOGINCTL_LOG"; : >"$STOP_FLAG"
  : >"$DB_CREATE_LOG"
  printf 'norows\n' >"$JOURNAL_STATE"
  printf '[boot]\nsystemd=true\n' >"$WSLCONF"
  export CP_FAKE_DOCKER_FAIL=0 CP_FAKE_SYSTEMCTL_FAIL=0 CP_FAKE_SYSTEM_STATE=running
  export CP_FAKE_UNIT_ACTIVE=active CP_FAKE_UNIT_ENABLED=enabled
  export CP_FAKE_UNAME_S=Linux CP_FAKE_UNAME_M=x86_64
  export CP_FAKE_UNAME_R='6.18.58.1-microsoft-standard-WSL2'
  export CP_FAKE_LINGER=no CP_FAKE_LOGINCTL_FAIL=0
  export CP_FAKE_CURL_FAIL=0 CP_FAKE_DOCKER_PS='' CP_FAKE_DOCKER_PS_FAIL=0
  export CP_FAKE_NA_START_FAIL='' CP_FAKE_NA_PIDFILE=none CP_FAKE_NA_PIDFILE_PID="$LIVED"
  export CP_FAKE_JOURNAL_ERR=0
  export CP_FAKE_STATE_FILE="$JOURNAL_STATE" DEVTEAM_MROOT="$CHECKOUT"
  export DEVTEAM_CP_MROOT="$CHECKOUT" DEVTEAM_CP_WSLCONF="$WSLCONF"
  export CP_FAKE_DOCKER_LOG="$DOCKER_LOG" CP_FAKE_SYSTEMCTL_LOG="$SYSTEMCTL_LOG"
  export CP_FAKE_JOURNAL_LOG="$JOURNAL_LOG" CP_FAKE_AGENT_LOG="$AGENT_LOG"
  export CP_FAKE_CURL_LOG="$CURL_LOG" CP_FAKE_LOGINCTL_LOG="$LOGINCTL_LOG"
  export CP_FAKE_STOP_FLAG="$STOP_FLAG"
  export CP_FAKE_DB_CREATE_LOG="$DB_CREATE_LOG"
  export CP_HTTP_TIMEOUT=1 CP_HTTP_WAIT=1 CP_DOCKER_PS_TIMEOUT=2 CP_ASSUME_TTY=0
  export CP_FAKE_EXECUTABLE=0 CP_FAKE_SYSTEMCTL_EXEC=0 CP_FAKE_EXEC_RC=0
  export CP_FAKE_EXEC_LOG="$EXEC_LOG" CP_FAKE_UNIT_DIR="$UNIT_DIR"
  rm -f -- "$NODE_JSON"
  unset CP_IMAGE DEVTEAM_RUN_DB DEVTEAM_RUNNER DEVTEAM_CP_IMAGE
}

run_setup() { # run_setup [args...] -> OUT (combined), RC
  OUT=$(bash "$SETUP" "$@" 2>&1)
  RC=$?
}

set_journal() { # set_journal <json|norows>
  printf '%s\n' "$1" >"$JOURNAL_STATE"
}

fmt_ts() { # fmt_ts <epoch-offset> -> RFC 3339 UTC, the journal's own shape
  local at
  at=$(( $(date +%s) + ${1:-0} ))
  date -u -d "@$at" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null ||
    date -u -r "$at" +%Y-%m-%dT%H:%M:%SZ
}

footer_of() { printf '%s\n' "$OUT" | grep -E '^[0-9]+ pass / [0-9]+ warn / [0-9]+ fail / [0-9]+ skip$' | tail -n 1; }

row_of() { # row_of <id> -> the whole row line, empty when absent
  printf '%s\n' "$OUT" | grep -E "^[A-Z]+ \| $1 \|" | head -n 1
}

status_of() { # status_of <id> -> PASS|WARN|FAIL|SKIP|''
  row_of "$1" | cut -d'|' -f1 | tr -d '[:space:]'
}

row_with_fixit() { # row_with_fixit <id> -> the row plus its fix-it line
  printf '%s\n' "$OUT" | awk -v id="$1" '
    {
      n = split($0, a, "|")
      if (n >= 3 && a[2] == " " id " ") {
        print $0
        if ((getline nl) > 0 && index(nl, "fix-it:") > 0) print nl
        exit
      }
    }'
}

snapshot_tree() { # snapshot_tree <root> <out> — path|mode|mtime|cksum per file
  (
    cd "$1" || exit 1
    find . \( -type f -o -type l \) 2>/dev/null | LC_ALL=C sort | while IFS= read -r f || [ -n "$f" ]; do
      [ -n "$f" ] || continue
      printf '%s|%s|%s|%s\n' "$f" "$(mode_of "$f" 2>/dev/null)" \
        "$(mtime_of "$f" 2>/dev/null)" "$(cksum "$f" 2>/dev/null | awk '{print $2 "-" $3}')"
    done
  ) >"$2"
}

journal_intact() { [ -f "$JOURNAL" ] && cmp -s "$JOURNAL" "$SCRATCH/journal.copy"; }

# ---- 1. the module contract and dispatch (SPEC-043 M1, AC12) -----------------

if bash "$SETUP" --help >/dev/null 2>&1; then
  ok "--help exits 0"
else
  bad "--help did not exit 0"
fi
OUT=$(bash "$SETUP" --help 2>&1)
if has 'Usage:' && has '--status' && has '--uninstall' && has '63'; then
  ok "the usage block names every mode and the exit-code contract"
else
  bad "the usage block is incomplete: $OUT"
fi

run_setup --bogus
if [ "$RC" -eq 64 ]; then
  ok "an unknown flag exits 64 (SPEC-043 M7 usage error)"
else
  bad "unknown flag rc=$RC, expected 64"
fi
run_setup --status --uninstall
if [ "$RC" -eq 64 ]; then
  ok "two modes in one run exit 64 (SPEC-043 M1 is one mode per run)"
else
  bad "combined modes rc=$RC, expected 64"
fi
run_setup --status extra
if [ "$RC" -eq 64 ]; then
  ok "a positional argument exits 64"
else
  bad "positional argument rc=$RC, expected 64"
fi

# ---- 2. static guards (AC4, AC11, M11 ruling, single home) -------------------

CODE=$(sed -e 's/#.*$//' "$SETUP")
if printf '%s\n' "$CODE" | grep -Eq -e '(^|[;&|(`$])[[:space:]]*(sudo|pkexec)([[:space:]]|$)'; then
  bad "setup.sh runs an elevation command in code position (AC4 static)"
else
  ok "setup.sh has no elevation command in code position (AC4 static)"
fi
STOP_RE='(^|[;&|(`$])[[:space:]]*[A-Za-z0-9_./$-]*node-agent[A-Za-z0-9_./$-]*[[:space:]]+stop([[:space:]]|$)'
if printf '%s\n' "$CODE" | grep -Eq -e "$STOP_RE" -e 'stop[[:space:]]+--run-id'; then
  bad "setup.sh stops the probe run — the T0 § Q1b ruling forbids it"
else
  ok "setup.sh contains no node-agent stop (the fixed probe id stays usable)"
fi
if [ "$(count_lines 'docker\.io/' "$SETUP")" = '0' ] && [ "$(count_lines 'golang:' "$SETUP")" = '0' ]; then
  ok "setup.sh references no image — the pin lives in units.sh (AC4)"
else
  bad "setup.sh carries an image reference of its own (AC4)"
fi
if grep -qF -e 'control-plane/dist/' "$SETUP"; then
  ok "setup.sh names the service CLIs by their control-plane/dist/ path (AC11)"
else
  bad "setup.sh has no control-plane/dist/ path"
fi
if grep -Eq -e 'PATH=.*\$BIN_DIR' -e 'ln -s.*bin' "$SETUP"; then
  bad "setup.sh puts a service CLI on PATH (AC11)"
else
  ok "setup.sh never puts a service CLI on PATH (AC11 static)"
fi

# One home for the table body and footer: no second renderer in the shipped
# tree. A suite that quotes the format string in a pattern is not a renderer.
renderer_homes() {
  grep -rl -- '%-4s | %s | %s' "$PLUGIN_ROOT/skills" "$PLUGIN_ROOT/commands" "$PLUGIN_ROOT/agents" 2>/dev/null |
    grep -v -e '/test\.sh$' -e '/test-' -e '-test\.sh$' || true
}
HOMES=$(renderer_homes)
if [ "$(printf '%s\n' "$HOMES" | grep -c . || true)" = '1' ] &&
  [ "$HOMES" = "$RECORD" ]; then
  ok "the PASS/WARN/FAIL table body has exactly one home: skills/lib/record-status.sh"
else
  bad "the table renderer is duplicated: $(printf '%s\n' "$HOMES" | tr '\n' ' ')"
fi
if grep -qF -e 'skills/lib/record-status.sh' "$PLUGIN_ROOT/skills/doctor/checks/lib.sh" &&
  grep -qF -e 'render_status_rows' "$PLUGIN_ROOT/skills/doctor/checks/report.sh" &&
  grep -qF -e 'status_footer' "$PLUGIN_ROOT/skills/doctor/checks/report.sh"; then
  ok "doctor sources the shared pair (record_status + render_status_rows + status_footer)"
else
  bad "doctor no longer renders through skills/lib/record-status.sh"
fi
SRC=$(mktemp -d "$TMPDIR/rs-src.XXXXXX")
( cd "$SRC" && bash -c ". \"$RECORD\"" >"$SRC/out" 2>&1 )
RS_RC=$?
if [ "$RS_RC" -eq 0 ] && [ ! -s "$SRC/out" ] &&
  [ "$(ls -A "$SRC" | grep -c . || true)" = '1' ]; then
  ok "record-status.sh is side-effect-free: no output, no file, rc 0"
else
  bad "sourcing record-status.sh produced output/files (rc $RS_RC): $(cat "$SRC/out" 2>/dev/null)"
fi
UNIT=$(bash -c ". \"$RECORD\"
record_status a g PASS 'is fine' ''
record_status b g WARN 'is shaky' 'do this'
record_status c g SKIP 'n/a' ''
render_status_rows
status_footer
status_exit_code; echo \"exitcode=\$?\"
record_status d g FAIL 'is broken' 'fix this'
status_exit_code; echo \"exitcode=\$?\"" 2>&1)
if printf '%s\n' "$UNIT" | grep -qF -e 'WARN | b | is shaky' &&
  printf '%s\n' "$UNIT" | grep -qF -e '       fix-it: do this' &&
  ! printf '%s\n' "$UNIT" | grep -qF -e 'fix-it: n/a' &&
  printf '%s\n' "$UNIT" | grep -qF -e '1 pass / 1 warn / 0 fail / 1 skip' &&
  printf '%s\n' "$UNIT" | grep -qF -e 'exitcode=0' &&
  printf '%s\n' "$UNIT" | grep -qF -e 'exitcode=2'; then
  ok "record-status: render, fix-it rule, footer, and the 0/2 exit code (SPEC-043 M6/M7)"
else
  bad "record-status unit behaviour: $UNIT"
fi

# ---- 3. fresh install reaches the verify table (AC1) -------------------------

reset_state
run_setup
if [ "$RC" -eq 0 ]; then
  ok "fresh install exits 0 (SPEC-043 M7: PASS/WARN rows only)"
else
  bad "fresh install rc=$RC — out: $OUT"
fi
for b in '== preflight ==' '== build ==' '== install ==' '== verify =='; do
  if has "$b"; then
    ok "install prints the phase banner: $b"
  else
    bad "install printed no banner for: $b"
  fi
done
if [ "$(footer_of)" = '7 pass / 3 warn / 0 fail / 0 skip' ]; then
  ok "AC1 table: every row PASS except linger and the two Windows-side rows"
else
  bad "AC1 footer is $(footer_of), expected '7 pass / 3 warn / 0 fail / 0 skip' — out: $OUT"
fi
for pair in 'controlplane.units.chiefd:PASS' 'controlplane.node-agent:PASS' \
  'controlplane.chiefd.api:PASS' 'controlplane.probe:PASS' 'controlplane.probe.hygiene:PASS' \
  'controlplane.runner:PASS' 'controlplane.wsl2.systemd:PASS' \
  'controlplane.linger:WARN' 'controlplane.wsl2.autostart:WARN' 'controlplane.wsl2.idletimeout:WARN'; do
  id=${pair%:*}
  want=${pair#*:}
  got=$(status_of "$id")
  if [ "$got" = "$want" ]; then
    ok "row $id = $want"
  else
    bad "row $id = '${got:-absent}', expected $want"
  fi
done
if [ -x "$BA" ] && [ -x "$BC" ]; then
  ok "install placed both binaries under \$HOME/.local/bin (M3)"
else
  bad "install placed no binaries"
fi
if [ -f "$UC" ] && [ "$(mode_of "$UC")" = '644' ] && [ ! -e "$UL" ]; then
  ok "install wrote the chiefd unit at mode 644 and no node-agent unit (M3/M5, D1)"
else
  bad "unit files are wrong (chiefd mode $(mode_of "$UC" 2>/dev/null), node-agent unit present: $([ -e "$UL" ] && echo yes || echo no))"
fi
if [ -z "$(ls -A "$BIN_DIR" | grep -v -e '^node-agent$' -e '^chiefd$' || true)" ]; then
  ok "install puts no journalctl in ~/.local/bin (AC11)"
else
  bad "~/.local/bin holds more than the two binaries: $(ls -A "$BIN_DIR" | tr '\n' ' ')"
fi
if grep -qF -e '--user daemon-reload' "$SYSTEMCTL_LOG" &&
  grep -qF -e '--user enable --now dev-team-chiefd.service' "$SYSTEMCTL_LOG" &&
  ! grep -qF -e 'dev-team-node-agent.service' "$SYSTEMCTL_LOG"; then
  ok "install enabled the chiefd unit and no node-agent unit (SPEC-043 M5, D1)"
else
  bad "install did not enable the units: $(tr '\n' '|' <"$SYSTEMCTL_LOG")"
fi
if [ "$(count_lines "$APPROVED" "$DOCKER_LOG")" = '3' ]; then
  ok "the build ran three times on the approved digest (node-agent, chiefd, journalctl)"
else
  bad "approved-digest build count is $(count_lines "$APPROVED" "$DOCKER_LOG"), expected 3"
fi
if [ -x "$CHECKOUT/control-plane/dist/journalctl" ]; then
  ok "the journal CLI is built into control-plane/dist (SPEC-043 M11)"
else
  bad "control-plane/dist/journalctl is missing"
fi
if grep -qF -e "$CHECKOUT/control-plane/dist/journalctl read --run-id $PROBE_ID --state" "$JOURNAL_LOG"; then
  ok "the probe state is read through the dist path with --state (AC11, M12 branch)"
else
  bad "the journal state read is not the dist-path call: $(tr '\n' '|' <"$JOURNAL_LOG")"
fi
if grep -qF -e "--db $CHECKOUT/.claude/runs/run.db" "$JOURNAL_LOG"; then
  ok "the journal read names the shared run.db path (T0 probe setup)"
else
  bad "the journal read carries no --db path"
fi
if grep -qF -e "$CHECKOUT/control-plane/dist/node-agent start --run-id $PROBE_ID --command true" "$AGENT_LOG"; then
  ok "the probe starts with start --command <no-op> only (SPEC-043 M11, AC13)"
else
  bad "the probe start is not the expected call: $(tr '\n' '|' <"$AGENT_LOG")"
fi
if grep -F -e "start --run-id $PROBE_ID" "$AGENT_LOG" | grep -qF -e '[DEVTEAM_RUNNER=native]'; then
  ok "M11/D2: a node with no selection carries DEVTEAM_RUNNER=native on the start child"
else
  bad "the probe start carried no runner override: $(tr '\n' '|' <"$AGENT_LOG")"
fi
if [ ! -e "$NODE_JSON" ]; then
  ok "M11/D2: the override wrote no node.json (record-ownership row 14 stays untouched)"
else
  bad "the probe wrote $NODE_JSON — SPEC-043 MUST NOT"
fi
if [ -n "$(printf '%s\n' "$OUT" | grep '^DEVTEAM_RUNNER=' || true)" ]; then
  bad "the driver leaked its own DEVTEAM_RUNNER into a report line"
else
  ok "the driver reports no DEVTEAM_RUNNER of its own (the override is child-only)"
fi
if [ "$(count_lines ' start ' "$AGENT_LOG")" = '1' ] && [ ! -s "$STOP_FLAG" ]; then
  ok "exactly one start and zero stop calls against the fixed probe id (spec § Q1b)"
else
  bad "probe verb count wrong: starts=$(count_lines ' start ' "$AGENT_LOG"), stop flag $(wc -c <"$STOP_FLAG") bytes"
fi
if has 'journal state completed'; then
  ok "the probe row reads the journal state, not node-agent status (spec § Q1a)"
else
  bad "the probe row does not quote the journal state"
fi
if has 'no leftover runner process, pidfile, or container'; then
  ok "AC13 hygiene: pidfile absent, no runner, no container (start rc 0)"
else
  bad "AC13 hygiene row is wrong: $(row_of controlplane.probe.hygiene)"
fi
if grep -qF -e 'ps --format' "$DOCKER_LOG"; then
  ok "the hygiene probe inspects containers with docker ps (M11: no leftover container)"
else
  bad "the hygiene probe ran no container scan"
fi
if journal_intact; then
  ok "install leaves the run journal byte-identical (M9 / ADR 0001)"
else
  bad "install touched the journal"
fi
if grep -qF -e '127.0.0.1:8090/v1/runs' "$CURL_LOG"; then
  ok "the chiefd row GETs the /v1 API on loopback:8090 (SPEC-043 M6)"
else
  bad "the chiefd row did not GET loopback: $(tr '\n' '|' <"$CURL_LOG")"
fi
if ! grep -Eq -e 'http://(0\.0\.0\.0|\[::\])' "$CURL_LOG"; then
  ok "no probe widens the bind beyond loopback (AC13)"
else
  bad "a probe reached a non-loopback address"
fi

# ---- 4. the linger row (AC10) ------------------------------------------------

if has 'sudo loginctl enable-linger "'; then
  ok "AC10: the exact sudo loginctl enable-linger line is printed"
else
  bad "AC10: no enable-linger line: $(row_of controlplane.linger)"
fi
if has 'no terminal for the M10 answer'; then
  ok "AC10: a driver with no terminal never blocks on the answer"
else
  bad "AC10: the no-terminal path did not report itself"
fi
reset_state
export CP_FAKE_LINGER=yes
run_setup
if [ "$(status_of controlplane.linger)" = 'PASS' ] && [ "$RC" -eq 0 ]; then
  ok "AC10: a later run reports PASS once linger is on"
else
  bad "AC10 linger=yes gave $(status_of controlplane.linger) rc $RC"
fi
reset_state
export CP_ASSUME_TTY=1
OUT=$(printf 'y\n' | bash "$SETUP" 2>&1); RC=$?
if has 'continuing without linger' && [ "$(status_of controlplane.wsl2.idletimeout)" = 'WARN' ] && [ "$RC" -eq 0 ]; then
  ok "AC10: the documented continue answer finishes the table (rc 0)"
else
  bad "AC10 continue path: rc=$RC — $(footer_of)"
fi
OUT=$(printf 's\n' | bash "$SETUP" 2>&1); RC=$?
if has 'skipping the remaining rows' && [ "$(status_of controlplane.wsl2.autostart)" = 'SKIP' ] &&
  [ "$(status_of controlplane.wsl2.idletimeout)" = 'SKIP' ] && [ "$RC" -eq 0 ]; then
  ok "AC10: the documented skip answer records SKIP rows and keeps the exit code"
else
  bad "AC10 skip path: rc=$RC, autostart=$(status_of controlplane.wsl2.autostart)"
fi
export CP_ASSUME_TTY=0
reset_state
# The answer with no trailing newline (a wrapper that pipes it).
OUT=$(printf 'y' | CP_ASSUME_TTY=1 bash "$SETUP" 2>&1); RC=$?
if has 'continuing without linger' && [ "$RC" -eq 0 ]; then
  ok "AC10: an answer with no trailing newline is read, not treated as EOF"
else
  bad "AC10 no-newline answer: rc=$RC — out: $(printf '%s\n' "$OUT" | tail -n 2)"
fi
reset_state
export CP_FAKE_LOGINCTL_FAIL=1
run_setup
if [ "$(status_of controlplane.linger)" = 'WARN' ] && [ "$RC" -eq 0 ]; then
  ok "AC10: an unreadable linger answer is WARN, never FAIL"
else
  bad "AC10 loginctl-fail gave $(status_of controlplane.linger) rc $RC"
fi
reset_state

# ---- 5. M12 idempotent second run (AC2) --------------------------------------

reset_state
run_setup
if [ "$RC" -ne 0 ]; then
  bad "the install that sets up the idempotency case failed (rc $RC)"
fi
touch_ago "$UC" 300; touch_ago "$BA" 300; touch_ago "$BC" 300
UC_M=$(mtime_of "$UC"); UC_B=$(cksum "$UC" | awk '{print $2}')
: >"$JOURNAL_LOG"
: >"$DOCKER_LOG"
run_setup
if [ "$RC" -eq 0 ]; then
  ok "M12: the second immediate run exits 0 with the same verdict"
else
  bad "M12: second run rc=$RC — out: $OUT"
fi
if [ "$(footer_of)" = '7 pass / 3 warn / 0 fail / 0 skip' ]; then
  ok "M12: the second run reproduces the same footer (AC2 same verdict)"
else
  bad "M12: second footer is $(footer_of)"
fi
if [ "$(printf '%s\n' "$OUT" | grep -c '^unchanged:' || true)" = '3' ]; then
  ok "M12: all three targets report unchanged (byte-identical unit file)"
else
  bad "M12: unchanged count is $(printf '%s\n' "$OUT" | grep -c '^unchanged:' || true), expected 3"
fi
if [ "$(mtime_of "$UC")" = "$UC_M" ] && [ "$(cksum "$UC" | awk '{print $2}')" = "$UC_B" ]; then
  ok "AC2: the unit file is untouched — same mtime, same bytes"
else
  bad "AC2: the unit file was rewritten on the second run"
fi
if grep -qF -e 'is-active' "$SYSTEMCTL_LOG" && ! grep -qF -e ' restart' "$SYSTEMCTL_LOG"; then
  ok "M12: verify reads is-active and never restarts a unit"
else
  bad "M12: verify restarted a unit: $(tr '\n' '|' <"$SYSTEMCTL_LOG")"
fi
if [ "$(count_lines ' start ' "$AGENT_LOG")" = '1' ]; then
  ok "AC2: no duplicate probe run — one start across both runs (spec § Q1a)"
else
  bad "AC2: probe starts across two runs = $(count_lines ' start ' "$AGENT_LOG")"
fi
if has 'journal state completed'; then
  ok "M12: the driver re-used the recorded outcome of the completed probe"
else
  bad "M12: the re-run did not report the recorded outcome"
fi
if has 'not rebuilt'; then
  ok "M12: the journal CLI is not rebuilt when it is present"
else
  bad "M12: the journal CLI rebuilt on every run"
fi

# ---- 6. --status writes nothing (SPEC-043 M1) --------------------------------

reset_state
run_setup
if [ "$RC" -ne 0 ]; then
  bad "the install that sets up the --status case failed (rc $RC)"
fi
: >"$DOCKER_LOG"; : >"$AGENT_LOG"; : >"$SYSTEMCTL_LOG"
snap_a="$SCRATCH/snap-a"; snap_b="$SCRATCH/snap-b"
snapshot_tree "$CHECKOUT" "$snap_a"
snapshot_tree "$HOME" "$SCRATCH/snap-home-a"
run_setup --status
if [ "$RC" -eq 0 ]; then
  ok "--status exits 0 on an installed node"
else
  bad "--status rc=$RC — out: $OUT"
fi
snapshot_tree "$CHECKOUT" "$snap_b"
snapshot_tree "$HOME" "$SCRATCH/snap-home-b"
if cmp -s "$snap_a" "$snap_b" && cmp -s "$SCRATCH/snap-home-a" "$SCRATCH/snap-home-b"; then
  ok "M1: --status wrote nothing (checkout and \$HOME snapshots identical)"
else
  bad "--status wrote: $(diff "$snap_a" "$snap_b" 2>&1 | head -n 4)"
fi
if ! grep -qF -e 'run --rm' "$DOCKER_LOG" && ! grep -qF -e ' start --run-id' "$AGENT_LOG"; then
  ok "M1: --status builds nothing (no container run) and starts no probe"
else
  bad "--status built or spawned: docker=$(tr '\n' '|' <"$DOCKER_LOG") agent=$(tr '\n' '|' <"$AGENT_LOG")"
fi
if grep -qF -e "$BA status-node" "$AGENT_LOG"; then
  ok "M6: --status reads the INSTALLED node agent with the read-only status-node verb (AC1)"
else
  bad "--status ran no installed-binary status-node read: $(tr '\n' '|' <"$AGENT_LOG")"
fi
if grep -qF -e 'is-active' "$SYSTEMCTL_LOG" &&
  ! grep -Eq -e '(^|[[:space:]])enable([[:space:]]|$)' -e 'daemon-reload' -e '(^|[[:space:]])stop([[:space:]]|$)' "$SYSTEMCTL_LOG"; then
  ok "M1: --status reads unit state only (no enable, reload, or stop)"
else
  bad "--status changed units: $(tr '\n' '|' <"$SYSTEMCTL_LOG")"
fi
if has '== preflight ==' && ! has '== build ==' && ! has '== install =='; then
  ok "M1: --status prints the read-only preflight only"
else
  bad "--status printed an install phase"
fi
# A node with no journal at all. journal.OpenPath creates the database a read
# asks for, so the driver MUST skip the read: --status leaves nothing behind.
reset_state
rm -f -- "$JOURNAL"
run_setup --status
if [ "$RC" -eq 0 ] && [ "$(status_of controlplane.probe)" = 'WARN' ]; then
  ok "M1: --status on a node with no journal is a WARN probe row and exits 0"
else
  bad "M1 no-journal: rc=$RC probe=$(status_of controlplane.probe) — out: $OUT"
fi
if [ ! -e "$JOURNAL" ] && [ ! -s "$DB_CREATE_LOG" ]; then
  ok "M1: the journal read was skipped — no database appeared at $JOURNAL"
else
  bad "M1: --status created the journal database: $(tr '\n' '|' <"$DB_CREATE_LOG")"
fi
if ! grep -qF -e ' read --run-id' "$JOURNAL_LOG"; then
  ok "M1: no journal CLI call runs on a node with no journal"
else
  bad "M1: the journal CLI ran with no journal present: $(tr '\n' '|' <"$JOURNAL_LOG")"
fi
# The same node shape with the journal CLI already built: the M1 guard, not a
# missing CLI, is what keeps the read away.
reset_state
run_setup
if [ "$RC" -ne 0 ]; then
  bad "the install that sets up the built-no-journal case failed (rc $RC)"
fi
rm -f -- "$JOURNAL"
: >"$JOURNAL_LOG"; : >"$DB_CREATE_LOG"
snapshot_tree "$CHECKOUT/.claude" "$SCRATCH/snap-nj-a"
run_setup --status
snapshot_tree "$CHECKOUT/.claude" "$SCRATCH/snap-nj-b"
if [ "$(status_of controlplane.probe)" = 'WARN' ] &&
  row_of controlplane.probe | grep -qF -e "no journal database at $JOURNAL" &&
  [ ! -e "$JOURNAL" ] && [ ! -s "$DB_CREATE_LOG" ] &&
  cmp -s "$SCRATCH/snap-nj-a" "$SCRATCH/snap-nj-b" &&
  ! grep -qF -e ' read --run-id' "$JOURNAL_LOG"; then
  ok "M1: a built node with no journal file names it, reads nothing, and recreates nothing"
else
  bad "M1 built-no-journal: probe=$(status_of controlplane.probe) row=$(row_of controlplane.probe) db=$([ -e "$JOURNAL" ] && echo present || echo absent) diff=$(diff "$SCRATCH/snap-nj-a" "$SCRATCH/snap-nj-b" 2>&1 | head -n 3)"
fi
reset_state
# An uninstalled node: the fake unit state and the fake API both say "absent".
export CP_FAKE_UNIT_ACTIVE=inactive CP_FAKE_UNIT_ENABLED=not-found CP_FAKE_CURL_FAIL=1
run_setup --status
if [ "$RC" -eq 0 ] && [ "$(footer_of)" = '2 pass / 7 warn / 0 fail / 1 skip' ]; then
  ok "--status on an uninstalled node stays WARN-only and exits 0 (the service is opt-in)"
else
  bad "--status uninstalled: rc=$RC footer=$(footer_of) — out: $OUT"
fi
if [ "$(status_of controlplane.probe)" = 'WARN' ]; then
  ok "--status never starts the probe: an absent probe is WARN with the fix line"
else
  bad "--status probe row is $(status_of controlplane.probe), expected WARN"
fi
# The build output is not an install (SPEC-043 M3/M6): with the dist/ copy
# present and the installed binary removed, the row is a WARN that names the
# install path, and the driver never invokes the dist copy.
reset_state
run_setup
if [ "$RC" -ne 0 ]; then
  bad "the install that sets up the dist-only case failed (rc $RC)"
fi
rm -f -- "$BA"
: >"$AGENT_LOG"
export CP_FAKE_UNIT_ACTIVE=inactive CP_FAKE_UNIT_ENABLED=not-found CP_FAKE_CURL_FAIL=1
run_setup --status
if [ "$(status_of controlplane.node-agent)" = 'WARN' ] &&
  row_with_fixit controlplane.node-agent | grep -qF -e "$BA" &&
  ! grep -qF -e "$CHECKOUT/control-plane/dist/node-agent status-node" "$AGENT_LOG"; then
  ok "M6: a node with only the control-plane/dist/ copy is WARN naming $BA — build output never reads as installed"
else
  bad "M6 dist-only node: status=$(status_of controlplane.node-agent) row=$(row_of controlplane.node-agent)"
fi

# ---- 7. uninstall: journal intact (AC3, M9) ----------------------------------

reset_state
run_setup
if [ "$RC" -ne 0 ]; then
  bad "the install that sets up the uninstall case failed (rc $RC)"
fi
: >"$SYSTEMCTL_LOG"; : >"$AGENT_LOG"; : >"$JOURNAL_LOG"; : >"$DOCKER_LOG"
run_setup --uninstall
if [ "$RC" -eq 0 ]; then
  ok "AC3: --uninstall exits 0 (SPEC-043 M9)"
else
  bad "--uninstall rc=$RC — out: $OUT"
fi
if [ ! -e "$BA" ] && [ ! -e "$BC" ] && [ ! -e "$UL" ] && [ ! -e "$UC" ]; then
  ok "AC3: --uninstall removed the chiefd unit and both binaries (the agent CLI too)"
else
  bad "--uninstall left an install target behind"
fi
for needle in '--user stop dev-team-chiefd.service' '--user disable dev-team-chiefd.service' \
  '--user daemon-reload' '--user reset-failed'; do
  if grep -qF -e "$needle" "$SYSTEMCTL_LOG"; then
    ok "AC3: uninstall ran systemctl $needle (M9)"
  else
    bad "AC3: uninstall did not run systemctl $needle: $(tr '\n' '|' <"$SYSTEMCTL_LOG")"
  fi
done
dr_line=$(grep -n -F -e '--user daemon-reload' "$SYSTEMCTL_LOG" | head -n 1 | cut -d: -f1)
rf_line=$(grep -n -F -e '--user reset-failed' "$SYSTEMCTL_LOG" | head -n 1 | cut -d: -f1)
if [ -n "$dr_line" ] && [ -n "$rf_line" ] && [ "$dr_line" -lt "$rf_line" ]; then
  ok "AC3: reset-failed runs after daemon-reload — the manager leaves the failed state (M9)"
else
  bad "AC3: reset-failed did not follow daemon-reload (dr=${dr_line:-none} rf=${rf_line:-none})"
fi
if journal_intact; then
  ok "AC3: the journal is untouched and present after uninstall"
else
  bad "--uninstall touched the journal"
fi
if has 'Windows-side steps' && has 'Task Scheduler' && has '.wslconfig'; then
  ok "AC3: the Windows-side removal steps are printed, Windows is never touched"
else
  bad "--uninstall printed no Windows steps"
fi
if [ ! -s "$DOCKER_LOG" ] && [ ! -s "$AGENT_LOG" ] && [ ! -s "$JOURNAL_LOG" ]; then
  ok "uninstall runs no build and no service CLI (M9 is removal only)"
else
  bad "uninstall ran a build or a service CLI"
fi
export CP_FAKE_UNIT_ACTIVE=inactive CP_FAKE_UNIT_ENABLED=not-found CP_FAKE_CURL_FAIL=1
run_setup --status
if [ "$RC" -eq 0 ] && [ "$(status_of controlplane.units.chiefd)" = 'WARN' ]; then
  ok "AC3: --status after uninstall reads the journal and stays WARN-only"
else
  bad "post-uninstall --status: rc=$RC chiefd=$(status_of controlplane.units.chiefd)"
fi
reset_state
run_setup
if [ "$RC" -eq 0 ]; then
  ok "AC3: a subsequent install reaches the PASS table again"
else
  bad "reinstall after uninstall rc=$RC — out: $OUT"
fi

# ---- 8. the exit-code matrix (AC12) ------------------------------------------

reset_state
export CP_FAKE_UNIT_ACTIVE=inactive
run_setup
if [ "$RC" -eq 2 ] && [ "$(status_of controlplane.units.chiefd)" = 'FAIL' ]; then
  ok "AC12: an inactive unit after install is a FAIL row and exit 2"
else
  bad "AC12 inactive-unit: rc=$RC chiefd=$(status_of controlplane.units.chiefd)"
fi
reset_state
export CP_FAKE_CURL_FAIL=1
run_setup
if [ "$RC" -eq 2 ] && [ "$(status_of controlplane.chiefd.api)" = 'FAIL' ]; then
  ok "AC12: chiefd not answering loopback:8090 is a FAIL row and exit 2"
else
  bad "AC12 curl-fail: rc=$RC api=$(status_of controlplane.chiefd.api)"
fi
reset_state
export CP_FAKE_UNAME_S=Darwin
run_setup
if [ "$RC" -eq 63 ] && [ ! -s "$DOCKER_LOG" ] && [ ! -e "$BA" ] && [ ! -e "$UL" ]; then
  ok "AC8: macOS exits 63 with zero side effects"
else
  bad "AC8 macOS: rc=$RC"
fi
reset_state
export CP_FAKE_SYSTEM_STATE=offline
run_setup
if [ "$RC" -eq 63 ] && [ ! -s "$DOCKER_LOG" ] && [ ! -e "$BA" ] && [ ! -e "$UL" ]; then
  ok "AC8: an unusable systemd user manager exits 63 with zero side effects"
else
  bad "AC8 systemd-offline: rc=$RC"
fi
reset_state
printf '[boot]\nsystemd=false\n' >"$WSLCONF"
run_setup
if [ "$RC" -eq 63 ] && [ ! -s "$DOCKER_LOG" ]; then
  ok "AC8: WSL2 with systemd off exits 63 with zero side effects"
else
  bad "AC8 wsl2 systemd=false: rc=$RC"
fi
reset_state
mkdir -p "$SCRATCH/no-gomod/control-plane"
export DEVTEAM_CP_MROOT="$SCRATCH/no-gomod"
run_setup
if [ "$RC" -eq 63 ] && [ ! -e "$BA" ]; then
  ok "AC5: a checkout without control-plane/go.mod exits 63 and writes nothing"
else
  bad "AC5 no-go.mod: rc=$RC"
fi
export DEVTEAM_CP_MROOT="$CHECKOUT"
reset_state
export CP_FAKE_DOCKER_FAIL=1
run_setup
if [ "$RC" -eq 2 ] && has 'build FAILED' && [ ! -e "$UL" ]; then
  ok "AC9: a build failure exits 2, names the phase, and enables nothing"
else
  bad "AC9 build-fail: rc=$RC — out: $OUT"
fi
reset_state
mv "$CHECKOUT/control-plane/cmd/journalctl" "$SCRATCH/journalctl-cmd"
run_setup
if [ "$RC" -eq 2 ] && has 'the journal CLI cannot be built' && [ ! -e "$BA" ] && [ ! -e "$UL" ]; then
  ok "AC5: a checkout with no cmd/journalctl stops before install (rc 2, nothing installed)"
else
  bad "AC5 no-cmd/journalctl: rc=$RC — out: $OUT"
fi
mv "$SCRATCH/journalctl-cmd" "$CHECKOUT/control-plane/cmd/journalctl" 2>/dev/null || true
reset_state
export CP_FAKE_SYSTEM_STATE=degraded
run_setup
if [ "$RC" -eq 0 ]; then
  ok "M2(b): a degraded user manager is a supported shape (rc 0)"
else
  bad "M2(b) degraded: rc=$RC — out: $OUT"
fi
reset_state
export CP_FAKE_UNIT_ENABLED=disabled
run_setup
if [ "$RC" -eq 0 ] && [ "$(status_of controlplane.units.chiefd)" = 'WARN' ]; then
  ok "M5: an active unit that is not enabled is a WARN with the enable fix-it"
else
  bad "M5 not-enabled: rc=$RC chiefd=$(status_of controlplane.units.chiefd)"
fi
reset_state
OUT=$(SUDO_USER=root bash "$SETUP" 2>&1); RC=$?
if [ "$RC" -eq 2 ] && [ ! -s "$DOCKER_LOG" ] && [ ! -e "$BA" ]; then
  ok "AC4: an elevated shell is refused with rc 2 and zero side effects"
else
  bad "AC4 SUDO_USER: rc=$RC"
fi
reset_state

# ---- 9. the WSL2 rows (AC7) --------------------------------------------------

reset_state
run_setup
for id in controlplane.wsl2.systemd controlplane.wsl2.autostart controlplane.wsl2.idletimeout; do
  if [ -n "$(row_of "$id")" ]; then
    ok "AC7: the WSL2 node carries the $id row"
  else
    bad "AC7: no $id row on WSL2"
  fi
done
if [ "$(status_of controlplane.wsl2.systemd)" = 'PASS' ]; then
  ok "AC7(a): systemd=true in /etc/wsl.conf verifies from inside WSL"
else
  bad "AC7(a): row is $(status_of controlplane.wsl2.systemd)"
fi
AUTOSTART=$(row_with_fixit controlplane.wsl2.autostart)
case "$AUTOSTART" in
  *schtasks*dev-team-wsl-start*) ok "AC7(b): the logon-task row prints the exact schtasks step" ;;
  *) bad "AC7(b): the row has no exact step: $AUTOSTART" ;;
esac
case "$AUTOSTART" in
  *'/SC ONLOGON'*) ok "AC7(b): the operator step schedules it at logon" ;;
  *) bad "AC7(b): the operator step has no ONLOGON schedule" ;;
esac
case "$AUTOSTART" in
  *wsl.exe*) ok "AC7(b): the operator step names wsl.exe at logon" ;;
  *) bad "AC7(b): the operator step omits wsl.exe" ;;
esac
IDLE=$(row_with_fixit controlplane.wsl2.idletimeout)
case "$IDLE" in
  *instanceIdleTimeout*) ok "AC7(c): the distro key instanceIdleTimeout is the primary step" ;;
  *) bad "AC7(c): no instanceIdleTimeout in $IDLE" ;;
esac
case "$IDLE" in
  *vmIdleTimeout*) ok "AC7(c): vmIdleTimeout is named as the second key" ;;
  *) bad "AC7(c): vmIdleTimeout not named in $IDLE" ;;
esac
case "$IDLE" in
  *'Windows 11'*) ok "AC7(c): vmIdleTimeout is scoped to Windows 11" ;;
  *) bad "AC7(c): the Windows 11 scope is missing in $IDLE" ;;
esac
case "$IDLE" in
  *'-1'*) ok "AC7(c): the -1 disable value is stated" ;;
  *) bad "AC7(c): the -1 disable value is missing" ;;
esac
reset_state
export CP_FAKE_UNAME_R='6.6.87-standard'
export CP_FAKE_LINGER=yes
run_setup
if [ "$(status_of controlplane.wsl2.systemd)" = 'SKIP' ] &&
  [ "$(status_of controlplane.wsl2.autostart)" = 'SKIP' ] &&
  [ "$(status_of controlplane.wsl2.idletimeout)" = 'SKIP' ] && [ "$RC" -eq 0 ]; then
  ok "AC7: on native Linux the three Windows rows are SKIP and the exit code is 0"
else
  bad "AC7 native-Linux skips: $(footer_of)"
fi
if printf '%s\n' "$OUT" | grep -qE '^7 pass / 0 warn / 0 fail / 3 skip$'; then
  ok "AC7: native Linux reaches the all-PASS table (7 pass, 3 skip)"
else
  bad "AC7 native-Linux footer is $(footer_of)"
fi
reset_state

# ---- 10. the probe branches (M11/M12, spec § Q1a) ----------------------------

reset_state
set_journal "{\"run_id\":\"devteam-setup-probe\",\"status\":\"running\",\"terminal\":false,\"owner\":\"host:4242\",\"token\":1,\"stall_limit_s\":108,\"last_heartbeat_ts\":\"$(fmt_ts -20)\"}"
run_setup
if [ "$(status_of controlplane.probe)" = 'WARN' ] && [ "$RC" -eq 0 ] &&
  ! grep -qF -e ' start ' "$AGENT_LOG"; then
  ok "M12: a running probe with a live lease is a WARN row and never a second start"
else
  bad "M12 running-lease: $(status_of controlplane.probe) rc=$RC starts=$(count_lines ' start ' "$AGENT_LOG")"
fi
case "$(row_of controlplane.probe)" in
  *'retry after lease expiry ~108 s'*) ok "M12: the WARN row quotes the lease expiry (~108 s, spec § Q1a)" ;;
  *) bad "M12: the WARN row has no lease line: $(row_of controlplane.probe)" ;;
esac
if [ "$(status_of controlplane.probe.hygiene)" = 'SKIP' ]; then
  ok "AC13: hygiene is SKIPped when this run started no probe"
else
  bad "AC13: hygiene row is $(status_of controlplane.probe.hygiene), expected SKIP"
fi
# BSD-date arm of the same live-lease case (CDT-620 T4 — the three macOS reds).
# On macOS `date` is BSD: `-d` is a Daylight-Savings spec (never a date string)
# and `-j -f FMT INPUT` matches INPUT against FMT literally, so a Z-stripped
# input cannot be dated by a format that ends in a literal Z. An undatable lease
# reads as EXPIRED (SPEC-043 M12 mirrors run.Lease.Expired), which turned this
# WARN into a takeover start: probe PASS, one start, hygiene PASS. The shim
# below is the hermetic macOS `date` (real `date` answers everything else).
BSD_BIN="$SCRATCH/bsd-bin"
mkdir -p "$BSD_BIN"
cat >"$BSD_BIN/date" <<'SHIM'
#!/usr/bin/env bash
# fake BSD/macOS date (CDT-620 T4): -d is a DST spec, -j -f needs a literal
# format match, -r takes seconds since the epoch. Everything else delegates.
REAL=$(command -v -p date 2>/dev/null || true)
[ -n "$REAL" ] || REAL=/bin/date
BSD_UTC=''
[ "${1:-}" = "-u" ] && { BSD_UTC=1; shift; }
case "${1:-}" in
  -d)
    case "${2:-}" in
      yes | on | 1 | no | off | 0 | summer | winter)
        if [ -n "$BSD_UTC" ]; then exec "$REAL" -u "$@"; fi
        exec "$REAL" "$@" ;;
    esac
    printf 'date: %s: Invalid date/offset argument\n' "${2:-}" >&2
    exit 1 ;;
  -j)
    shift
    [ "${1:-}" = "-f" ] || { printf 'date: illegal option -- j\n' >&2; exit 1; }
    fmt="${2:-}"; inp="${3:-}"; shift 3
    case "$fmt" in
      '%Y-%m-%dT%H:%M:%SZ')
        case "$inp" in
          [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z) ;;
          *) printf 'date: %s: illegal input format\n' "$inp" >&2; exit 1 ;;
        esac ;;
      '%Y-%m-%dT%H:%M:%S')
        case "$inp" in
          [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]) ;;
          *) printf 'date: %s: illegal input format\n' "$inp" >&2; exit 1 ;;
        esac ;;
      *) printf 'date: unsupported format %s\n' "$fmt" >&2; exit 1 ;;
    esac
    src="$inp"
    case "$src" in *Z) ;; *) src="$src+00:00" ;; esac
    if [ -n "$BSD_UTC" ]; then exec "$REAL" -u -d "$src" "${1:-+%s}"; fi
    exec "$REAL" -u -d "$src" "${1:-+%s}" ;;
  -r)
    shift
    exec "$REAL" -u -d "@${1:-0}" "${2:-+%s}" ;;
esac
if [ -n "$BSD_UTC" ]; then exec "$REAL" -u "$@"; fi
exec "$REAL" "$@"
SHIM
chmod +x "$BSD_BIN/date"
reset_state
set_journal "{\"run_id\":\"devteam-setup-probe\",\"status\":\"running\",\"terminal\":false,\"owner\":\"host:4242\",\"token\":1,\"stall_limit_s\":108,\"last_heartbeat_ts\":\"$(fmt_ts -20)\"}"
PATH_SAVE=$PATH
PATH="$BSD_BIN:$PATH"
run_setup
PATH=$PATH_SAVE
if [ "$(status_of controlplane.probe)" = 'WARN' ] && [ "$RC" -eq 0 ] &&
  ! grep -qF -e ' start ' "$AGENT_LOG"; then
  ok "M12 BSD date: a live lease is a WARN under BSD date, never a takeover start"
else
  bad "M12 BSD date running-lease: $(status_of controlplane.probe) rc=$RC starts=$(count_lines ' start ' "$AGENT_LOG")"
fi
case "$(row_of controlplane.probe)" in
  *'retry after lease expiry ~108 s'*) ok "M12 BSD date: the WARN row quotes the lease expiry" ;;
  *) bad "M12 BSD date: the WARN row has no lease line: $(row_of controlplane.probe)" ;;
esac
if [ "$(status_of controlplane.probe.hygiene)" = 'SKIP' ]; then
  ok "AC13 BSD date: hygiene stays SKIPped under BSD date"
else
  bad "AC13 BSD date: hygiene row is $(status_of controlplane.probe.hygiene), expected SKIP"
fi
reset_state
# M12 arm 2: the lease is past last heartbeat + stall_limit_s, so its owner is
# dead — the driver runs exactly one takeover start and the run closes
# (spec § Q1a: the takeover start exits 0 and writes one run, not two).
reset_state
set_journal "{\"run_id\":\"devteam-setup-probe\",\"status\":\"running\",\"terminal\":false,\"owner\":\"host:4242\",\"token\":1,\"stall_limit_s\":108,\"last_heartbeat_ts\":\"$(fmt_ts -600)\"}"
run_setup
if [ "$RC" -eq 0 ] && [ "$(status_of controlplane.probe)" = 'PASS' ] &&
  [ "$(count_lines ' start --run-id' "$AGENT_LOG")" = '1' ]; then
  ok "M12: an expired lease runs exactly one takeover start and the probe completes"
else
  bad "M12 takeover: rc=$RC probe=$(status_of controlplane.probe) starts=$(count_lines ' start --run-id' "$AGENT_LOG") — out: $OUT"
fi
if [ "$(status_of controlplane.probe.lease)" = 'WARN' ] && has 'running the takeover start'; then
  ok "M12: the takeover is reported on its own WARN row (owner, heartbeat, limit)"
else
  bad "M12 takeover row: lease=$(status_of controlplane.probe.lease) — out: $OUT"
fi
if [ "$(status_of controlplane.probe.hygiene)" = 'PASS' ]; then
  ok "AC13: the takeover run gets the hygiene check — this run started the probe"
else
  bad "AC13 takeover hygiene: $(status_of controlplane.probe.hygiene)"
fi
# An undatable heartbeat dates as expired, matching run.Lease.Expired.
reset_state
set_journal '{"run_id":"devteam-setup-probe","status":"running","terminal":false,"owner":"host:4242","token":1,"stall_limit_s":108,"last_heartbeat_ts":"not-a-timestamp"}'
run_setup
if [ "$(count_lines ' start --run-id' "$AGENT_LOG")" = '1' ] &&
  [ "$(status_of controlplane.probe)" = 'PASS' ]; then
  ok "M12: an undatable lease dates as expired (run.Lease.Expired) and takes the run over"
else
  bad "M12 undatable lease: probe=$(status_of controlplane.probe) starts=$(count_lines ' start --run-id' "$AGENT_LOG")"
fi
reset_state
set_journal '{"run_id":"devteam-setup-probe","status":"failed","terminal":true,"failure":{"reason":"spawn_failed"}}'
run_setup
if [ "$RC" -eq 2 ] && [ "$(status_of controlplane.probe)" = 'FAIL' ]; then
  ok "M12: a terminal run in a non-completed state is a FAIL row (exit 2)"
else
  bad "M12 terminal-failed: rc=$RC probe=$(status_of controlplane.probe)"
fi
if ! grep -qF -e ' start ' "$AGENT_LOG"; then
  ok "M12: a terminal id skips start — the recorded outcome is reported (spec § Q1)"
else
  bad "M12: start ran against a terminal id"
fi
reset_state
export CP_FAKE_NA_START_FAIL=lease
run_setup
if [ "$RC" -eq 2 ] && [ "$(status_of controlplane.probe)" = 'FAIL' ] &&
  has 'lease held by another owner' && [ "$(status_of controlplane.probe.fix)" = 'WARN' ]; then
  ok "spec § Q1a: a start refusal is FAIL with the refusal text and the never-stop advisory"
else
  bad "Q1a start-refusal: rc=$RC probe=$(status_of controlplane.probe) — out: $OUT"
fi
export CP_FAKE_NA_START_FAIL=''
reset_state
export CP_FAKE_NA_PIDFILE=live
run_setup
if [ "$RC" -eq 2 ] && [ "$(status_of controlplane.probe.hygiene)" = 'FAIL' ]; then
  ok "AC13: a live runner pidfile after start is a FAIL row (exit 2)"
else
  bad "AC13 live-pidfile: rc=$RC hygiene=$(status_of controlplane.probe.hygiene)"
fi
# A pid the suite started and reaped: the pidfile is stale, so the row is WARN.
true &
DEADS=$!
wait "$DEADS" 2>/dev/null || true
reset_state
export CP_FAKE_NA_PIDFILE=dead CP_FAKE_NA_PIDFILE_PID="$DEADS"
run_setup
if [ "$RC" -eq 0 ] && [ "$(status_of controlplane.probe.hygiene)" = 'WARN' ]; then
  ok "AC13: a stale pidfile (dead pid) is a WARN, not a FAIL"
else
  bad "AC13 dead-pidfile: rc=$RC hygiene=$(status_of controlplane.probe.hygiene)"
fi
export CP_FAKE_NA_PIDFILE=none CP_FAKE_NA_PIDFILE_PID="$LIVED"
reset_state
export CP_FAKE_DOCKER_PS="agent-$PROBE_ID-idle"
run_setup
if [ "$RC" -eq 2 ] && [ "$(status_of controlplane.probe.hygiene)" = 'FAIL' ]; then
  ok "M11: a leftover container named for the probe run is a FAIL row"
else
  bad "M11 leftover-container: rc=$RC hygiene=$(status_of controlplane.probe.hygiene)"
fi
export CP_FAKE_DOCKER_PS=''
reset_state
export CP_FAKE_DOCKER_PS_FAIL=1
run_setup
if [ "$RC" -eq 0 ] && [ "$(status_of controlplane.probe.hygiene)" = 'WARN' ]; then
  ok "M11: an unreadable docker ps is a WARN (the container set is unverifiable)"
else
  bad "M11 docker-ps-fail: rc=$RC hygiene=$(status_of controlplane.probe.hygiene)"
fi
export CP_FAKE_DOCKER_PS_FAIL=0
reset_state
export CP_FAKE_JOURNAL_ERR=1
run_setup
if [ "$RC" -eq 2 ] && [ "$(status_of controlplane.probe)" = 'FAIL' ] && has 'disk full'; then
  ok "M11: an unreadable journal state is FAIL with the CLI's own reason, never a guess"
else
  bad "M11 journal-error: rc=$RC probe=$(status_of controlplane.probe) — out: $OUT"
fi
export CP_FAKE_JOURNAL_ERR=0
reset_state
# No jq on PATH: the awk state parser carries the M12 branch.
if command -v jq >/dev/null 2>&1; then
  export PATH="$NO_JQ:$PATH"
  export PATH_NOJQ_TEST=1
  run_setup
  if [ "$RC" -eq 0 ] && [ "$(status_of controlplane.probe)" = 'PASS' ]; then
    ok "M12: the journal state parses without jq (awk fallback path)"
  else
    bad "M12 awk fallback: rc=$RC probe=$(status_of controlplane.probe) — out: $OUT"
  fi
  PATH=${PATH#"$NO_JQ":}
  unset PATH_NOJQ_TEST
else
  ok "M12 awk fallback: skipped, jq is absent on this host (the fallback ran above)"
fi
reset_state

# ---- 11. the M11 runner override (D2) and the real ExecStart target (M5) -----

reset_state
mkdir -p "$(dirname -- "$NODE_JSON")"
printf '{"runner":"container"}\n' >"$NODE_JSON"
NODE_JSON_SUM=$(cksum "$NODE_JSON" | awk '{print $2"-"$3}')
run_setup
if [ "$RC" -eq 0 ] &&
  grep -F -e "start --run-id $PROBE_ID" "$AGENT_LOG" | grep -qF -e '[DEVTEAM_RUNNER=container]'; then
  ok "M11/D2: a node.json selection rides the start child as DEVTEAM_RUNNER=container"
else
  bad "M11/D2 node.json: rc=$RC agent=$(tr '\n' '|' <"$AGENT_LOG")"
fi
if [ "$(cksum "$NODE_JSON" | awk '{print $2"-"$3}')" = "$NODE_JSON_SUM" ]; then
  ok "M11/D2: node.json is byte-identical after the probe (read-only, AC6)"
else
  bad "M11/D2: the probe wrote node.json — SPEC-043 MUST NOT"
fi
case "$(row_of controlplane.runner)" in
  *'runner=container'*) ok "AC6: the runner row reports the resolved node.json selection" ;;
  *) bad "AC6 runner row on a container node: $(row_of controlplane.runner)" ;;
esac
reset_state
export DEVTEAM_RUNNER=container
run_setup
if [ "$RC" -eq 0 ] &&
  grep -F -e "start --run-id $PROBE_ID" "$AGENT_LOG" | grep -qF -e '[DEVTEAM_RUNNER=container]'; then
  ok "M11/D2: an operator's \$DEVTEAM_RUNNER selection rides the start child unchanged"
else
  bad "M11/D2 env: rc=$RC agent=$(tr '\n' '|' <"$AGENT_LOG")"
fi
reset_state

# The shipped unit, executed: the fake systemctl expands %h and execs the
# ExecStart argv of the installed binary, so the M5 template is proven in the
# shape systemd runs it (the T7 real-node blind spot).
: >"$EXEC_LOG"
export CP_FAKE_EXECUTABLE=1 CP_FAKE_SYSTEMCTL_EXEC=1 CP_FAKE_EXEC_RC=0
run_setup
if [ "$RC" -eq 0 ]; then
  ok "M5 acceptance: installing and enabling runs the ExecStart target, rc 0"
else
  bad "M5 acceptance: rc=$RC — out: $OUT"
fi
if grep -qF -e "$BC --addr 127.0.0.1:8090" "$EXEC_LOG"; then
  ok "M5 acceptance: ExecStart ran %h/.local/bin/chiefd --addr 127.0.0.1:8090 (loopback)"
else
  bad "M5 acceptance: ExecStart argv is wrong: $(tr '\n' '|' <"$EXEC_LOG")"
fi
if grep -qF -e 'execstart dev-team-chiefd.service rc=0' "$EXEC_LOG"; then
  ok "M5 acceptance: the chiefd target exits clean under the manager (AC1)"
else
  bad "M5 acceptance: no clean ExecStart record: $(tr '\n' '|' <"$EXEC_LOG")"
fi
if [ "$(status_of controlplane.units.chiefd)" = 'PASS' ] &&
  [ "$(status_of controlplane.node-agent)" = 'PASS' ]; then
  ok "M6: the chiefd unit row and the node-agent binary row both PASS (AC1)"
else
  bad "M6 rows: chiefd=$(status_of controlplane.units.chiefd) node-agent=$(status_of controlplane.node-agent)"
fi
if ! grep -qF -e 'node-agent' "$EXEC_LOG"; then
  ok "M5 acceptance: nothing ran a node-agent ExecStart — the agent has no unit"
else
  bad "a node-agent ExecStart ran: $(tr '\n' '|' <"$EXEC_LOG")"
fi
reset_state
: >"$EXEC_LOG"
export CP_FAKE_EXECUTABLE=1 CP_FAKE_SYSTEMCTL_EXEC=1 CP_FAKE_EXEC_RC=64
run_setup
if [ "$RC" -eq 2 ] && has 'enable --now FAILED'; then
  ok "AC12: an ExecStart target that exits at once is a FAIL, not a PASS table (the T7 P0)"
else
  bad "the dying-ExecStart shape returned rc=$RC — out: $OUT"
fi
reset_state

# ---- 12. the record-and-render pair is shared, not copied -------------------

if bash "$PLUGIN_ROOT/skills/doctor/doctor.sh" --only version.triplet >/dev/null 2>&1; then
  ok "doctor renders through the shared pair after the extract (rc 0)"
else
  RC=$?
  if [ "$RC" -eq 1 ]; then
    ok "doctor renders through the shared pair after the extract (rc 1 = WARN)"
  else
    bad "doctor --only version.triplet rc=$RC after the record-status extract"
  fi
fi
DOCT=$(bash "$PLUGIN_ROOT/skills/doctor/doctor.sh" --only version.triplet 2>&1)
case "$DOCT" in
  *'pass /'*'warn /'*'fail /'*'skip'*) ok "the doctor footer keeps the shared format" ;;
  *) bad "the doctor footer changed: $(printf '%s\n' "$DOCT" | tail -n 1)" ;;
esac

echo
echo "Results: $PASS passed, $FAIL failed"
# The labels print last so a red run is self-diagnosing inside the runner's
# 20-line tail (CDT-620 T2). Nothing prints on a green run.
if [ "$FAIL" -ne 0 ]; then printf 'FAILED CHECKS:\n%b' "$FAILED_LABELS"; fi
[ "$FAIL" -eq 0 ]
RC=$?
echo "VERIFY exit=$RC"
kill "$LIVED" 2>/dev/null || true
exit "$RC"
