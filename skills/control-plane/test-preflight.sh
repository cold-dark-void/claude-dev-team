#!/usr/bin/env bash
# skills/control-plane/test-preflight.sh — SPEC-043 M2 bite-tests for preflight.sh
#
# Machine-check: bash skills/control-plane/test-preflight.sh  (exit 0)
# THIS SCRIPT IS A SUBPROCESS CLI — NEVER SOURCE IT.
#
# Hermetic: PATH fakes for uname / systemctl / docker, knob paths for
# wsl.conf, build.sh, node.json and $MROOT. No network, no container, no
# daemon, no LLM. A non-executable fake reads as "not installed", which is
# how the missing-command branches are reached.

set -u

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
PREFLIGHT="$SCRIPT_DIR/preflight.sh"
PORTABLE_SH="$SCRIPT_DIR/../lib/portable.sh"
APPROVED_IMAGE='docker.io/library/golang:1.27-bookworm@sha256:4fa7c968ba93f1635670522dbb01a2c78150443e1385746924566079f36570ea'

PASS=0
FAIL=0
SKIPN=0
pass() { PASS=$((PASS + 1)); printf 'PASS: %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf 'FAIL: %s\n' "$1" >&2; }
skip() { SKIPN=$((SKIPN + 1)); printf 'SKIP: %s\n' "$1"; }

TMP=$(mktemp -d "${TMPDIR:-/tmp}/cp-preflight.XXXXXX")
SRC_CASE=""
cleanup() { rm -rf "$TMP"; [ -n "$SRC_CASE" ] && rm -f "$SRC_CASE"; return 0; }
trap cleanup EXIT
export TMPDIR="$TMP/tmp"
mkdir -p "$TMPDIR"

BIN="$TMP/bin"
mkdir -p "$BIN"

mkfake() {
  # mkfake <name> <mode> — script body on stdin
  local path="$BIN/$1"
  cat > "$path" || return 1
  chmod "$2" "$path" || return 1
}

mkfake uname 755 <<'FAKE'
#!/bin/sh
case "${1-}" in
  -r) printf '%s\n' "${FAKE_UNAME_R:-5.15.0-generic}" ;;
  -s) printf '%s\n' "${FAKE_UNAME_S:-Linux}" ;;
  *)  printf '%s\n' "${FAKE_UNAME_S:-Linux}" ;;
esac
FAKE

mkfake systemctl 755 <<'FAKE'
#!/bin/sh
# Controlled by FAKE_SYSTEMCTL_OUT / FAKE_SYSTEMCTL_RC.
if [ "${1-}" != "--user" ]; then
  printf 'mock systemctl: expected --user argv, got: %s\n' "$*" >&2
  exit 64
fi
printf '%s\n' "${FAKE_SYSTEMCTL_OUT:-running}"
exit "${FAKE_SYSTEMCTL_RC:-0}"
FAKE

mkfake docker 755 <<'FAKE'
#!/bin/sh
# Controlled by FAKE_DOCKER_RC / FAKE_DOCKER_ERR.
case " $* " in
  *" info "*)
    [ -n "${FAKE_DOCKER_SLEEP:-}" ] && sleep "$FAKE_DOCKER_SLEEP"
    printf 'Server Version: 27.0.0-fake\n'
    [ -n "${FAKE_DOCKER_ERR:-}" ] && printf '%s\n' "$FAKE_DOCKER_ERR" >&2
    exit "${FAKE_DOCKER_RC:-0}"
    ;;
  *)
    printf 'mock docker: unexpected argv: %s\n' "$*" >&2
    exit 99
    ;;
esac
FAKE

export PATH="$BIN:$PATH"

# ---- Fixture + runner helpers ----------------------------------------------

reset_env() {
  local v
  for v in DEVTEAM_RUNNER DEVTEAM_CP_MROOT DEVTEAM_CP_WSLCONF DEVTEAM_CP_BUILDSH \
           DEVTEAM_CP_IMAGE DEVTEAM_CP_NODE_JSON \
           FAKE_UNAME_S FAKE_UNAME_R FAKE_SYSTEMCTL_OUT FAKE_SYSTEMCTL_RC \
           FAKE_DOCKER_RC FAKE_DOCKER_ERR FAKE_DOCKER_SLEEP DEVTEAM_CP_DOCKER_TIMEOUT; do
    unset "$v"
  done
  export FAKE_UNAME_S=Linux FAKE_UNAME_R='5.15.0-generic'
  export FAKE_SYSTEMCTL_OUT=running FAKE_SYSTEMCTL_RC=0 FAKE_DOCKER_RC=0
  RUN_CWD="$TMP"
}

new_checkout() {
  # new_checkout <slug> — minimal dev-team checkout with control-plane/
  local root="$TMP/$1"
  mkdir -p "$root/control-plane" || return 1
  printf 'module github.com/cold-dark-void/claude-dev-team/control-plane\n\ngo 1.27\n' \
    > "$root/control-plane/go.mod" || return 1
  printf "#!/usr/bin/env bash\nIMAGE='%s'\n" "$APPROVED_IMAGE" \
    > "$root/control-plane/build.sh" || return 1
  printf '%s\n' "$root"
}

base() {
  # base <slug> — a supported Linux node inside a good checkout
  local root
  reset_env
  root=$(new_checkout "$1") || fail "fixture $1"
  export DEVTEAM_CP_MROOT="$root"
  export DEVTEAM_CP_WSLCONF="$TMP/no-wsl.conf"
  FIXTURE="$root"
}

run_pf() {
  OUT=$(CDPATH= cd -- "$RUN_CWD" && bash "$PREFLIGHT" 2>&1)
  RC=$?
}

path_without() {
  # path_without <cmd> — PATH with the fakes plus the tools the module needs,
  # minus <cmd>, so that command reads as "not installed". MIN_PATH carries it.
  local drop="$1" t
  local d="$TMP/path-without-$drop"
  mkdir -p "$d" || return 1
  for t in sh bash dirname tr head sed awk jq git timeout cksum cat; do
    [ "$t" = "$drop" ] && continue
    if command -v "$t" >/dev/null 2>&1; then
      ln -sf "$(command -v "$t")" "$d/$t" || return 1
    fi
  done
  for t in uname systemctl docker; do
    [ "$t" = "$drop" ] && continue
    ln -sf "$BIN/$t" "$d/$t" || return 1
  done
  MIN_PATH="$d"
  return 0
}

run_pf_path() {
  OUT=$(CDPATH= cd -- "$RUN_CWD" && env PATH="$MIN_PATH" bash "$PREFLIGHT" 2>&1)
  RC=$?
}

expect_rc() {
  if [ "$RC" -eq "$1" ]; then
    pass "$2 (rc $RC)"
  else
    fail "$2: want rc $1, got $RC"
    printf -- '--- output ---\n%s\n--------------\n' "$OUT" >&2
  fi
}

expect_out() {
  case "$OUT" in
    *"$1"*) pass "$2" ;;
    *)
      fail "$2: no '$1' in output"
      printf -- '--- output ---\n%s\n--------------\n' "$OUT" >&2
      ;;
  esac
}

expect_no_out() {
  case "$OUT" in
    *"$1"*) fail "$2: unexpected '$1' in output" ;;
    *) pass "$2" ;;
  esac
}

ok_seq() {
  # ok_seq — space-joined preflight ok labels, in the order they printed
  printf '%s\n' "$OUT" | sed -n 's/^preflight ok: \([a-z0-9-]*\).*/\1/p' | tr '\n' ' '
}

tree_state() {
  # tree_state <root> — sorted file list + content checksums (AC9 snapshot diff)
  (
    CDPATH= cd -- "$1" &&
      find . -type f -print | LC_ALL=C sort |
      while IFS= read -r f || [ -n "$f" ]; do
        [ -n "$f" ] || continue
        printf '%s\n' "$f"
        cksum < "$f"
      done
  )
}

# ---- M2(a) platform ---------------------------------------------------------

base pf-linux
run_pf
expect_rc 0 'linux node passes preflight'
expect_out 'platform=linux' 'pass path reports platform=linux'
expect_out 'runner=native' 'pass path reports runner=native'
expect_out 'runner_source=none' 'no selection reports runner_source=none'
expect_out 'preflight skip: wsl2-systemd (not WSL2)' 'non-WSL2 skips the wsl2 row'
[ "$(ok_seq)" = 'platform systemd-user checkout docker image-pin runner-selection all ' ] \
  && pass 'checks run in M2 (a)(b)(d)(e)(f)(g) order' \
  || fail 'M2 order: got ok-sequence: '"$(ok_seq)"

base pf-macos
export FAKE_UNAME_S=Darwin
run_pf
expect_rc 63 'macOS exits 63 (M2a)'
expect_out 'macOS is not a supported node' 'macOS names the check'
expect_out 'CDT-631' 'macOS fix line names the scope owner'

base pf-bsd
export FAKE_UNAME_S=FreeBSD
run_pf
expect_rc 63 'unrecognised system exits 63'
expect_out 'unrecognised system' 'unrecognised system names the check'

# ---- M2(b) systemd user manager --------------------------------------------

base pf-degraded
export FAKE_SYSTEMCTL_OUT=degraded
run_pf
expect_rc 0 'degraded user manager is accepted'
expect_out 'systemd-user — degraded' 'degraded is reported'

base pf-offline
export FAKE_SYSTEMCTL_OUT=offline FAKE_SYSTEMCTL_RC=1
run_pf
expect_rc 63 'systemd user manager offline exits 63 (M2b)'
expect_out 'systemd-user' 'offline names the check'
expect_out 'wsl.exe --shutdown' 'offline fix line carries the WSL2 step'

base pf-no-systemctl
path_without systemctl || fail 'path_without systemctl'
run_pf_path
expect_rc 63 'systemctl absent exits 63'
expect_out 'systemctl is not installed' 'absent systemctl names the fix'

# ---- M2(c) WSL2 /etc/wsl.conf ----------------------------------------------

WSLCONF="$TMP/wsl-on.conf"
printf '[boot]\nsystemd=true\n' > "$WSLCONF"

base pf-wsl-on
export FAKE_UNAME_R='5.15.153.1-microsoft-standard-WSL2'
export DEVTEAM_CP_WSLCONF="$WSLCONF"
run_pf
expect_rc 0 'WSL2 with systemd=true passes'
expect_out 'platform=wsl2' 'WSL2 reports platform=wsl2'
expect_no_out 'preflight skip: wsl2-systemd' 'WSL2 runs the wsl2 check'
[ "$(ok_seq)" = 'platform systemd-user wsl2-systemd checkout docker image-pin runner-selection all ' ] \
  && pass 'WSL2 inserts wsl2-systemd after systemd-user' \
  || fail 'WSL2 order: got ok-sequence: '"$(ok_seq)"

base pf-wsl-off
export FAKE_UNAME_R='6.6.36-microsoft-standard-WSL2'
printf '[boot]\nsystemd=false\n' > "$TMP/wsl-off.conf"
export DEVTEAM_CP_WSLCONF="$TMP/wsl-off.conf"
run_pf
expect_rc 63 'WSL2 with systemd=false exits 63 (M2c)'
expect_out 'wsl2-systemd' 'wsl.conf check is named'
expect_out 'systemd=true' 'fix line carries the key to add'

base pf-wsl-missing
export FAKE_UNAME_R='6.6.36-microsoft-standard-WSL2'
export DEVTEAM_CP_WSLCONF="$TMP/absent-wsl.conf"
run_pf
expect_rc 63 'WSL2 with no /etc/wsl.conf exits 63'
expect_out 'create /etc/wsl.conf' 'missing wsl.conf carries the create step'

base pf-wsl-wrong-section
export FAKE_UNAME_R='6.6.36-microsoft-standard-WSL2'
printf '[network]\nsystemd=true\n' > "$TMP/wsl-other.conf"
export DEVTEAM_CP_WSLCONF="$TMP/wsl-other.conf"
run_pf
expect_rc 63 'systemd=true outside [boot] is not accepted'

# ---- M2(d) checkout ---------------------------------------------------------

base pf-no-gomod
rm -f "$FIXTURE/control-plane/go.mod"
run_pf
expect_rc 63 'no control-plane/go.mod exits 63 (M2d, AC8)'
expect_out 'checkout' 'checkout check is named'
expect_out 'prebuilt release binaries are out of scope' 'checkout fix names the phase-1 scope'

mkdir -p "$TMP/loose"
reset_env
RUN_CWD="$TMP/loose"
if git -C "$TMP/loose" rev-parse --git-common-dir >/dev/null 2>&1; then
  skip 'non-checkout cwd case — TMPDIR sits inside a git checkout'
else
  run_pf
  expect_rc 63 'non-checkout working directory exits 63 (AC8)'
  expect_out 'not a git checkout' 'unresolvable $MROOT names the check'
fi

# ---- M2(e) docker -----------------------------------------------------------

base pf-no-docker
path_without docker || fail 'path_without docker'
run_pf_path
expect_rc 2 'docker absent exits 2 (AC9)'
expect_out 'docker is not on PATH' 'absent docker names the fix'

base pf-docker-down
export FAKE_DOCKER_RC=1 FAKE_DOCKER_ERR='Cannot connect to the Docker daemon at unix:///var/run/docker.sock.'
run_pf
expect_rc 2 'docker unreachable exits 2'
expect_out 'Cannot connect to the Docker daemon' 'the daemon reason is reported'
expect_out 'fix: start the Docker daemon' 'unreachable docker carries a fix line'

base pf-docker-hangs
if ! command -v timeout >/dev/null 2>&1 && ! command -v gtimeout >/dev/null 2>&1 \
   && ! command -v perl >/dev/null 2>&1; then
  skip 'docker hang case — no timeout(1), gtimeout, or perl supervisor on this host'
else
  export FAKE_DOCKER_SLEEP=5 DEVTEAM_CP_DOCKER_TIMEOUT=1
  run_pf
  expect_rc 2 'an unresponsive docker daemon exits 2 on the deadline'
  expect_out 'no answer within 1s' 'the deadline is reported'
fi

# ---- M2(f) the approved image pin ------------------------------------------

base pf-image-tag
export DEVTEAM_CP_IMAGE='docker.io/library/golang:1.27-bookworm'
run_pf
expect_rc 2 'an unpinned tag aborts pre-pull (AC4)'
expect_out 'unapproved image reference' 'the offending reference is named'
expect_out "$APPROVED_IMAGE" 'the fix line names the approved digest'

base pf-image-digest
export DEVTEAM_CP_IMAGE='docker.io/library/golang:1.27-bookworm@sha256:0000000000000000000000000000000000000000000000000000000000000000'
run_pf
expect_rc 2 'a foreign digest aborts pre-pull'

base pf-buildsh-unpinned
printf "#!/usr/bin/env bash\nIMAGE='golang:1.21-bookworm'\n" > "$FIXTURE/control-plane/build.sh"
run_pf
expect_rc 2 'an unpinned build.sh IMAGE aborts (M2f)'
expect_out 'control-plane/build.sh' 'the fix names the file to repair'

base pf-buildsh-nopin
printf '#!/usr/bin/env bash\necho build\n' > "$FIXTURE/control-plane/build.sh"
run_pf
expect_rc 2 'build.sh with no IMAGE= aborts'
expect_out 'no IMAGE= pin' 'the missing pin is named'

base pf-buildsh-missing
rm -f "$FIXTURE/control-plane/build.sh"
run_pf
expect_rc 2 'a missing build.sh aborts the pin check'
expect_out 'no readable build script' 'the missing build.sh is named'

# ---- M2(g) runner selection (AC6, read-only) --------------------------------

base pf-runner-junk-env
export DEVTEAM_RUNNER=docker
run_pf
expect_rc 2 '$DEVTEAM_RUNNER outside the closed set exits 2 (AC9)'
expect_out 'runner-selection' 'the runner check is named'
expect_out 'native container' 'the fix line names the closed set'

base pf-runner-env-container
export DEVTEAM_RUNNER=container
run_pf
expect_rc 0 'DEVTEAM_RUNNER=container is accepted'
expect_out 'runner=container' 'env selection is reported'
expect_out 'runner_source=env' 'env source is reported'

base pf-runner-nodejson
mkdir -p "$FIXTURE/.claude/dev-team"
printf '{ "runner": "container" }\n' > "$FIXTURE/.claude/dev-team/node.json"
run_pf
expect_rc 0 'node.json runner=container is accepted'
expect_out 'runner=container' 'node.json selection is reported'
expect_out 'runner_source=node.json' 'node.json source is reported'

base pf-runner-env-wins
mkdir -p "$FIXTURE/.claude/dev-team"
printf '{ "runner": "container" }\n' > "$FIXTURE/.claude/dev-team/node.json"
export DEVTEAM_RUNNER=native
run_pf
expect_rc 0 'env overrides node.json (first hit wins)'
expect_out 'runner=native' 'env selection wins over node.json'

base pf-runner-json-junk
mkdir -p "$FIXTURE/.claude/dev-team"
printf 'banana\n' > "$FIXTURE/.claude/dev-team/node.json"
run_pf
expect_rc 2 'a malformed node.json exits 2 (fail-closed)'
expect_out 'not valid JSON' 'the malformed file is named'

base pf-runner-json-scalar
mkdir -p "$FIXTURE/.claude/dev-team"
printf '"container"\n' > "$FIXTURE/.claude/dev-team/node.json"
run_pf
expect_rc 2 'a non-object node.json exits 2'

base pf-runner-json-unknown-key
mkdir -p "$FIXTURE/.claude/dev-team"
printf '{ "runner": "native", "runner_type": "native" }\n' > "$FIXTURE/.claude/dev-team/node.json"
run_pf
expect_rc 2 'an unknown node.json key exits 2'
expect_out 'unknown key' 'the unknown key is named'

base pf-runner-json-junk-value
mkdir -p "$FIXTURE/.claude/dev-team"
printf '{ "runner": "podman" }\n' > "$FIXTURE/.claude/dev-team/node.json"
run_pf
expect_rc 2 'node.json runner=podman exits 2'

base pf-runner-json-empty-object
mkdir -p "$FIXTURE/.claude/dev-team"
printf '{}\n' > "$FIXTURE/.claude/dev-team/node.json"
run_pf
expect_rc 0 'node.json with no runner key resolves to native'
expect_out 'runner=native' 'absent key reports native'
expect_out 'runner_source=none' 'absent key reports source none'

base pf-runner-json-empty-file
mkdir -p "$FIXTURE/.claude/dev-team"
: > "$FIXTURE/.claude/dev-team/node.json"
run_pf
expect_rc 0 'an empty node.json resolves to native'

# ---- AC6 / AC9: zero side effects ------------------------------------------

base pf-side-effects-pass
before=$(tree_state "$FIXTURE")
run_pf
expect_rc 0 'AC9 snapshot case ran the pass path'
[ "$before" = "$(tree_state "$FIXTURE")" ] \
  && pass 'AC9 pass path writes nothing in the checkout' \
  || fail 'AC9 pass path changed the checkout tree'

base pf-side-effects-fail
export FAKE_DOCKER_RC=1
before=$(tree_state "$FIXTURE")
run_pf
expect_rc 2 'AC9 snapshot case ran a failing path'
[ "$before" = "$(tree_state "$FIXTURE")" ] \
  && pass 'AC9 failing preflight leaves zero partial state' \
  || fail 'AC9 failing preflight wrote into the checkout tree'

base pf-readonly-nodejson
mkdir -p "$FIXTURE/.claude/dev-team"
printf '{ "runner": "container" }\n' > "$FIXTURE/.claude/dev-team/node.json"
export DEVTEAM_RUNNER=container
run_pf
expect_rc 0 'AC6 case ran with an env selection'
[ "$(cat "$FIXTURE/.claude/dev-team/node.json")" = '{ "runner": "container" }' ] \
  && pass 'AC6 node.json is untouched by preflight' \
  || fail 'AC6 preflight modified node.json'
[ "${DEVTEAM_RUNNER:-}" = 'container' ] \
  && pass 'AC6 $DEVTEAM_RUNNER is untouched (subprocess cannot write the parent)' \
  || fail 'AC6 $DEVTEAM_RUNNER changed'

# ---- Module contract: sourceable by setup.sh (SPEC-043 SHOULD) --------------

SRC_CASE=$(mktemp "${TMPDIR:-/tmp}/cp-source-case.XXXXXX")
cat > "$SRC_CASE" <<EOSRC
set -u
. "$PREFLIGHT"
cp_preflight >/dev/null || exit \$?
printf '%s|%s|%s\n' "\$CP_PLATFORM" "\$CP_RUNNER" "\$CP_RUNNER_SOURCE"
EOSRC
base pf-sourced
SRC_OUT=$(bash "$SRC_CASE" 2>&1)
SRC_RC=$?
if [ "$SRC_RC" -eq 0 ] && [ "$SRC_OUT" = 'linux|native|none' ]; then
  pass 'cp_preflight is sourceable and exports CP_PLATFORM/CP_RUNNER/CP_RUNNER_SOURCE'
else
  fail "source contract: rc $SRC_RC, out '$SRC_OUT'"
fi

# ---- Static tests (no LLM: every assertion is a grep) -----------------------

if bash -n "$PREFLIGHT" 2>/dev/null; then
  pass 'preflight.sh parses (bash -n)'
else
  fail 'preflight.sh does not parse'
fi
if bash -n "$SCRIPT_DIR/test-preflight.sh" 2>/dev/null; then
  pass 'test-preflight.sh parses (bash -n)'
else
  fail 'test-preflight.sh does not parse'
fi
if [ -f "$PORTABLE_SH" ]; then
  pass 'the sourced skills/lib/portable.sh resolves'
else
  fail 'skills/lib/portable.sh reference does not resolve'
fi

n_approved=$(grep -c 'sha256:4fa7c968ba93f1635670522dbb01a2c78150443e1385746924566079f36570ea' "$PREFLIGHT" || true)
n_sha=$(grep -c 'sha256:' "$PREFLIGHT" || true)
if [ "${n_approved:-0}" = '1' ] && [ "${n_sha:-0}" = '1' ]; then
  pass 'the approved digest is the only image reference in preflight.sh (AC4)'
else
  fail "image literals: approved=$n_approved all=$n_sha (want 1 and 1)"
fi
n_dockerio=$(grep -c 'docker\.io/' "$PREFLIGHT" || true)
[ "${n_dockerio:-0}" = '1' ] \
  && pass 'exactly one docker.io/ literal in preflight.sh' \
  || fail "docker.io/ literals in preflight.sh: $n_dockerio (want 1)"

elev=$(grep -Ewn 'sudo|pkexec|doas|su' "$PREFLIGHT" || true)
[ -z "$elev" ] \
  && pass 'no elevation token in preflight.sh (AC4)' \
  || fail "elevation token in preflight.sh: $elev"

writers=$( {
  grep -nE '^[[:space:]]*(mkdir|touch|chmod|chown|rm|mv|cp|tee|truncate|install|ln)[[:space:]]' "$PREFLIGHT"
  grep -nE '[;&|][[:space:]]*(mkdir|touch|chmod|chown|rm|mv|cp|tee|truncate|install|ln)[[:space:]]' "$PREFLIGHT"
} || true)
[ -z "$writers" ] \
  && pass 'no filesystem-mutating command in preflight.sh (AC9 by construction)' \
  || fail "writer command in preflight.sh: $writers"

redirects=$(sed -e '/^[[:space:]]*#/d' -e 's#2>&1##g' -e 's#2>[[:space:]]*/dev/null##g' -e 's#>[[:space:]]*/dev/null##g' -e 's#>=##g' "$PREFLIGHT" | grep -n '[<>]' || true)
[ -z "$redirects" ] \
  && pass 'no redirect to a file in preflight.sh (AC9 by construction)' \
  || fail "file redirect in preflight.sh: $redirects"

nodejson_writes=$(grep -n 'node\.json.*>' "$PREFLIGHT" || true)
[ -z "$nodejson_writes" ] \
  && pass 'no write target on node.json in preflight.sh (AC6)' \
  || fail "node.json write target: $nodejson_writes"

LLM_PAT="cu""rl|wg""et|anthr""opic|op""enai|cla""ude -p"
llm=$(grep -Ewn "$LLM_PAT" "$SCRIPT_DIR/test-preflight.sh" || true)
[ -z "$llm" ] \
  && pass 'the suite is LLM-free and network-free' \
  || fail "network/LLM call in the suite: $llm"

# ---- Summary ----------------------------------------------------------------

printf '\npreflight suite: %d pass / %d fail / %d skip\n' "$PASS" "$FAIL" "$SKIPN"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
