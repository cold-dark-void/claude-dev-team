#!/usr/bin/env bash
# test-daemon.sh — hermetic CDT-509 phase-2 daemon/compose suite (SPEC-038).
# No network and no real container: never docker-pull or docker-run an image.
# Loop cases drive daemon.sh with INTERCOM_POLLER=mock. Compose/Dockerfile
# cases are static text. poller.sh and watch.sh stay one-shot (lock-in).
set -u

HERE=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
PLUGIN_ROOT=$(CDPATH= cd -- "$HERE/../.." && pwd)

for _t in jq curl flock; do
  command -v "$_t" >/dev/null 2>&1 || {
    echo "SKIP: $_t missing — daemon suite requires bash/jq/curl/flock (SPEC-038 AC21/AC22)"
    exit 77
  }
done

# shellcheck source=../../tests/lib/hermetic.sh
. "$PLUGIN_ROOT/tests/lib/hermetic.sh"

DAEMON="$HERE/daemon.sh"
POLLER="$HERE/poller.sh"
WATCH="$HERE/watch.sh"
COMPOSE="$HERE/docker-compose.yml"
DOCKERFILE="$HERE/Dockerfile"
TEST_TOKEN="123456789:TEST-TOKEN-NOT-REAL"
SENTINEL="123456789:TEST-SENTINEL-TOKEN"

hermetic_init

PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); echo "PASS: $1"; }
bad() { FAIL=$((FAIL + 1)); echo "FAIL: $1" >&2; }

# shellcheck source=test-lib.sh
. "$HERE/test-lib.sh"
hermetic_curl_shim

fresh_state() { rm -rf "$STATE_ROOT"; mkdir -m 700 -p "$STATE_ROOT"; }
fresh_case() {
  fresh_state
  rm -rf "$RESP_DIR"
  mkdir -p "$RESP_DIR"
  : > "$CALLS_LOG"
  : > "$ARGV_LOG"
}

# Hide host docker without dropping /usr/bin (docker lives next to grep).
# SHIM_DIR stays first so a refusing docker mock wins command -v.
nodocker_bin() {
  local tools="$HERMETIC_ROOT/nodocker-bin" cmd p
  mkdir -p "$tools"
  if [ ! -x "$tools/grep" ]; then
    for cmd in bash jq curl flock grep sed awk cat chmod mkdir date stat \
      touch wc tr mktemp rm ls head find mv cp basename dirname uname \
      sleep kill env id ps tail cmp diff file ln git sort uniq cut tee \
      true false test timeout stty readlink realpath; do
      p=$(command -v "$cmd" 2>/dev/null) || continue
      ln -sf "$p" "$tools/$cmd"
    done
  fi
  printf '%s\n' "$tools"
}
SAFE_BIN=$(nodocker_bin)
export PATH="$SHIM_DIR:$SAFE_BIN"
cat > "$SHIM_DIR/docker" <<'EOF'
#!/usr/bin/env bash
echo "docker-mock: refused (hermetic test-daemon.sh never talks to a daemon)" >&2
exit 64
EOF
chmod +x "$SHIM_DIR/docker"

prod_script() { # rc 0 when FILE is a shipped (non-test) skills/intercom *.sh
  case "$(basename "$1")" in
    test.sh|test-*.sh|test-lib.sh) return 1 ;;
  esac
  return 0
}

MOCK_COUNT="$HERMETIC_ROOT/poller.count"
MOCK_TIMES="$HERMETIC_ROOT/poller.times"
MOCK_LOCKLOG="$HERMETIC_ROOT/poller.locklog"
MOCK_ARGV="$HERMETIC_ROOT/poller.argv"
MOCK_ENV="$HERMETIC_ROOT/poller.env"

write_mock_poller() { # body on stdin; exports INTERCOM_POLLER
  INTERCOM_POLLER="$HERMETIC_ROOT/mock-poller.sh"
  export INTERCOM_POLLER INTERCOM_MOCK_COUNT="$MOCK_COUNT" \
    INTERCOM_MOCK_TIMES="$MOCK_TIMES" INTERCOM_MOCK_ARGV="$MOCK_ARGV" \
    INTERCOM_MOCK_ENV="$MOCK_ENV" INTERCOM_MOCK_LOCKLOG="$MOCK_LOCKLOG" \
    INTERCOM_MOCK_LOCK="$STATE_ROOT/state/poller.lock"
  cat > "$INTERCOM_POLLER"
  chmod +x "$INTERCOM_POLLER"
  : > "$MOCK_COUNT"
  : > "$MOCK_TIMES"
  : > "$MOCK_LOCKLOG"
  : > "$MOCK_ARGV"
  : > "$MOCK_ENV"
}

inv_n() { wc -l < "$MOCK_COUNT" 2>/dev/null | tr -d ' '; }

run_daemon_for() { # SECONDS — kill if still running; sets D_OUT D_ERR D_RC
  local secs="$1"
  local outf="$HERMETIC_ROOT/daemon.out" errf="$HERMETIC_ROOT/daemon.err"
  : > "$outf"
  : > "$errf"
  bash "$DAEMON" >"$outf" 2>"$errf" &
  local pid=$!
  sleep "$secs"
  if kill -0 "$pid" 2>/dev/null; then
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    D_RC=143
  else
    wait "$pid"
    D_RC=$?
  fi
  D_OUT=$(cat "$outf")
  D_ERR=$(cat "$errf")
}

file_has() { # FILE PATTERN
  [ -f "$1" ] && grep -Eq "$2" "$1"
}

# ---- poller.sh / watch.sh stay one-shot (CDT-509 AC5 lock-in) ------------------

oneshot_ok=1
if [ ! -f "$POLLER" ]; then
  oneshot_ok=0
  bad "CDT-509 AC5 poller.sh missing"
elif grep -E 'while[[:space:]]+(true|:)' "$POLLER" >/dev/null \
  || grep -E '^[[:space:]]*sleep[[:space:]]' "$POLLER" >/dev/null; then
  oneshot_ok=0
  bad "CDT-509 AC5 poller.sh gained a resident while/sleep loop"
fi
if [ ! -f "$WATCH" ]; then
  oneshot_ok=0
  bad "CDT-509 AC5 watch.sh missing"
elif grep -E 'while[[:space:]]+(true|:)|sleep[[:space:]]' "$WATCH" >/dev/null; then
  oneshot_ok=0
  bad "CDT-509 AC5 watch.sh gained a resident while/sleep loop"
fi
[ "$oneshot_ok" -eq 1 ] && ok "CDT-509 AC5 poller.sh and watch.sh stay one-shot"

if [ -f "$POLLER" ] && grep -q 'flock -n' "$POLLER"; then
  ok "CDT-509 AC4 poller.sh takes flock -n"
else
  bad "CDT-509 AC4 poller.sh missing flock -n"
fi

# ---- hermetic: shipped scripts never docker-pull / docker-run ------------------

pull_ok=1
for f in "$HERE"/*.sh; do
  prod_script "$f" || continue
  if grep -E '(^|[[:space:]])docker[[:space:]]+(pull|run)([[:space:]|&;<>]|$)' "$f" >/dev/null; then
    pull_ok=0
    bad "CDT-509 AC11 $f calls docker pull or docker run"
  fi
done
[ "$pull_ok" -eq 1 ] && ok "CDT-509 AC11 shipped skills/intercom/*.sh never docker pull/run"

# ---- daemon.sh loop file (CDT-509 AC4/AC5) -------------------------------------

if [ ! -f "$DAEMON" ]; then
  bad "CDT-509 AC5 daemon.sh missing — source guard"
  bad "CDT-509 AC5 daemon.sh missing — shebang"
  bad "CDT-509 AC5 daemon.sh missing — interpreter scan"
  bad "CDT-509 AC5 daemon.sh missing — long-poll reinvoke"
  bad "CDT-509 AC5 daemon.sh missing — fast-0 backoff"
  bad "CDT-509 AC5 daemon.sh missing — exit 2 terminates"
  bad "CDT-509 AC5 daemon.sh missing — exit 75 continues"
  bad "CDT-509 AC4 daemon.sh missing — must not hold poller.lock"
  bad "CDT-509 AC5 daemon.sh missing — loops INTERCOM_POLLER/poller.sh"
  bad "CDT-509 AC9 daemon.sh missing — no typing-keepalive"
else
  out=$(bash -c '. "'"$DAEMON"'"' 2>&1)
  rc=$?
  if [ "$rc" -eq 1 ] && printf '%s' "$out" | grep -q 'subprocess CLI'; then
    ok "CDT-509 AC5 daemon.sh refuses to be sourced (rc 1 + message)"
  else
    bad "CDT-509 AC5 daemon.sh source guard: rc=$rc out=$out"
  fi

  if [ "$(head -n 1 "$DAEMON")" = "#!/usr/bin/env bash" ]; then
    ok "CDT-509 AC5 daemon.sh shebang is env bash"
  else
    bad "CDT-509 AC5 daemon.sh shebang: $(head -n 1 "$DAEMON")"
  fi

  if grep -E '(^|[[:space:]])(python3?|node|ruby|perl)([[:space:]|&;<>]|$)' "$DAEMON" >/dev/null; then
    bad "CDT-509 AC5 daemon.sh interpreter invocation"
  else
    ok "CDT-509 AC5 daemon.sh has no py/node/rb/pl interpreter"
  fi

  if grep -nE 'sendChatAction' "$DAEMON" | grep -qE 'while |sleep '; then
    bad "CDT-509 AC9 daemon.sh typing-keepalive loop"
  else
    ok "CDT-509 AC9 daemon.sh has no typing-keepalive loop"
  fi

  if grep -Eq 'INTERCOM_POLLER|poller\.sh' "$DAEMON" \
    && grep -E 'while[[:space:]]+(true|:)' "$DAEMON" >/dev/null; then
    ok "CDT-509 AC5 daemon.sh loops INTERCOM_POLLER/poller.sh"
  else
    bad "CDT-509 AC5 daemon.sh must while-loop INTERCOM_POLLER or poller.sh"
  fi

  mkdir -m 700 -p "$STATE_ROOT/state"

  # long-poll success (sleep 2, rc 0) → immediate reinvoke, ≥2 calls
  write_mock_poller <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$INTERCOM_MOCK_ARGV"
printenv >> "$INTERCOM_MOCK_ENV" 2>/dev/null || true
date +%s%N >> "$INTERCOM_MOCK_TIMES"
printf '1\n' >> "$INTERCOM_MOCK_COUNT"
sleep 2
exit 0
EOF
  run_daemon_for 5
  n=$(inv_n)
  if [ "$n" -ge 2 ]; then
    ok "CDT-509 AC5 long-poll exit 0 (>=2s) reinvokes without backoff (n=$n)"
  else
    bad "CDT-509 AC5 long-poll reinvoke: n=$n rc=$D_RC err=$D_ERR"
  fi

  # fast rc 0 → sleep ≥1s between invocations
  write_mock_poller <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$INTERCOM_MOCK_ARGV"
date +%s%N >> "$INTERCOM_MOCK_TIMES"
printf '1\n' >> "$INTERCOM_MOCK_COUNT"
exit 0
EOF
  run_daemon_for 4
  n=$(inv_n)
  delta_ok=0
  if [ "$n" -ge 2 ]; then
    t1=$(sed -n '1p' "$MOCK_TIMES")
    t2=$(sed -n '2p' "$MOCK_TIMES")
    if [ -n "$t1" ] && [ -n "$t2" ] && [ "$t2" -ge "$t1" ]; then
      delta=$((t2 - t1))
      [ "$delta" -ge 1000000000 ] && delta_ok=1
    fi
  fi
  if [ "$delta_ok" -eq 1 ] && [ "$n" -le 8 ]; then
    ok "CDT-509 AC5 fast exit 0 backoffs >=1s (n=$n)"
  else
    bad "CDT-509 AC5 fast-0 backoff: n=$n times=$(tr '\n' ' ' < "$MOCK_TIMES") rc=$D_RC"
  fi

  # poller rc 2 → daemon exits 2 (no loop)
  write_mock_poller <<'EOF'
#!/usr/bin/env bash
printf '1\n' >> "$INTERCOM_MOCK_COUNT"
exit 2
EOF
  run_daemon
  if [ "$D_RC" -eq 2 ] && [ "$(inv_n)" = "1" ]; then
    ok "CDT-509 AC5 poller exit 2 terminates daemon with rc 2"
  else
    bad "CDT-509 AC5 exit 2: rc=$D_RC n=$(inv_n) err=$D_ERR"
  fi

  # rc 75 then rc 0 (long) → continues
  write_mock_poller <<'EOF'
#!/usr/bin/env bash
n=$(wc -l < "$INTERCOM_MOCK_COUNT" | tr -d ' ')
printf '1\n' >> "$INTERCOM_MOCK_COUNT"
if [ "$n" -eq 0 ]; then
  exit 75
fi
sleep 2
exit 0
EOF
  run_daemon_for 5
  n=$(inv_n)
  if [ "$n" -ge 2 ]; then
    ok "CDT-509 AC5 poller exit 75 backoffs and continues (n=$n)"
  else
    bad "CDT-509 AC5 exit 75 continue: n=$n rc=$D_RC err=$D_ERR"
  fi

  # daemon must not hold poller.lock across cycles (mock takes flock -n)
  mkdir -m 700 -p "$STATE_ROOT/state"
  write_mock_poller <<'EOF'
#!/usr/bin/env bash
printf '1\n' >> "$INTERCOM_MOCK_COUNT"
mkdir -p "$(dirname "$INTERCOM_MOCK_LOCK")"
exec 9>"$INTERCOM_MOCK_LOCK" || { echo open-fail >> "$INTERCOM_MOCK_LOCKLOG"; exit 1; }
if flock -n 9; then
  echo got >> "$INTERCOM_MOCK_LOCKLOG"
  exit 0
fi
echo held >> "$INTERCOM_MOCK_LOCKLOG"
exit 75
EOF
  run_daemon_for 4
  got=$(grep -c '^got$' "$MOCK_LOCKLOG" 2>/dev/null || true)
  held=$(grep -c '^held$' "$MOCK_LOCKLOG" 2>/dev/null || true)
  if [ "${got:-0}" -ge 2 ] && [ "${held:-0}" -eq 0 ]; then
    ok "CDT-509 AC4 daemon.sh does not hold poller.lock across cycles (got=$got)"
  else
    bad "CDT-509 AC4 poller.lock: got=$got held=$held n=$(inv_n) log=$(tr '\n' ' ' < "$MOCK_LOCKLOG")"
  fi

  if grep -E 'flock.*poller\.lock|poller\.lock.*flock' "$DAEMON" >/dev/null; then
    bad "CDT-509 AC4 daemon.sh must not flock poller.lock"
  else
    ok "CDT-509 AC4 daemon.sh source does not flock poller.lock"
  fi

  # token never on mock argv / env
  if grep -qF "$TEST_TOKEN" "$MOCK_ARGV" 2>/dev/null \
    || grep -qF "$SENTINEL" "$MOCK_ARGV" 2>/dev/null \
    || grep -qF "$TEST_TOKEN" "$MOCK_ENV" 2>/dev/null; then
    bad "CDT-509 AC1 daemon passed token on poller argv/env"
  else
    ok "CDT-509 AC1 daemon does not pass token on poller argv/env"
  fi
fi

# ---- compose + Dockerfile static (CDT-509 AC11 / AC1 / AC4) --------------------

if [ -f "$COMPOSE" ]; then
  ok "CDT-509 AC11 docker-compose.yml exists"
else
  bad "CDT-509 AC11 docker-compose.yml missing"
fi
if [ -f "$DOCKERFILE" ]; then
  ok "CDT-509 AC11 Dockerfile exists"
else
  bad "CDT-509 AC11 Dockerfile missing"
fi

if file_has "$COMPOSE" '^name:[[:space:]]*["'\'']?intercom["'\'']?[[:space:]]*$'; then
  ok "CDT-509 AC11 compose project name is intercom"
else
  bad "CDT-509 AC11 compose project name intercom missing"
fi

if file_has "$COMPOSE" '^[[:space:]]+daemon:'; then
  ok "CDT-509 AC11 compose service daemon"
else
  bad "CDT-509 AC11 compose service daemon missing"
fi

if file_has "$COMPOSE" 'dev-team\.intercom'; then
  ok "CDT-509 AC11 compose label dev-team.intercom"
else
  bad "CDT-509 AC11 compose label dev-team.intercom missing"
fi

if file_has "$COMPOSE" 'bot_token:ro'; then
  ok "CDT-509 AC1 token volume is :ro"
else
  bad "CDT-509 AC1 token volume :ro missing"
fi

if file_has "$COMPOSE" 'telegram-router:ro'; then
  bad "CDT-509 AC2 state volume must not be :ro"
elif file_has "$COMPOSE" 'telegram-router'; then
  ok "CDT-509 AC2 state volume is rw bind"
else
  bad "CDT-509 AC2 state volume telegram-router missing"
fi

if file_has "$COMPOSE" '/plugin:ro'; then
  ok "CDT-509 AC11 plugin tree bind is :ro"
else
  bad "CDT-509 AC11 plugin :ro bind missing"
fi

if [ -f "$COMPOSE" ] && grep -Eq '^[[:space:]]+ports[[:space:]]*:' "$COMPOSE"; then
  bad "CDT-509 AC5 compose publishes ports"
else
  if [ -f "$COMPOSE" ]; then
    ok "CDT-509 AC5 compose has no ports:"
  else
    bad "CDT-509 AC5 compose has no ports: (file missing)"
  fi
fi

if [ -f "$COMPOSE" ] && file_has "$COMPOSE" 'daemon\.sh'; then
  ok "CDT-509 AC5 compose command runs daemon.sh"
else
  bad "CDT-509 AC5 compose command daemon.sh missing"
fi

if [ -f "$COMPOSE" ] && grep -Eq '^[[:space:]]+user:' "$COMPOSE" \
  && ! grep -Eq '^[[:space:]]+user:[[:space:]]*["'\'']?0([:"'\'' ]|$)' "$COMPOSE"; then
  ok "CDT-509 AC11 compose user: is non-root"
else
  bad "CDT-509 AC11 compose user: missing or uid 0"
fi

if [ -f "$DOCKERFILE" ] && grep -Eq '^[[:space:]]*USER[[:space:]]+0([[:space:]]|$)' "$DOCKERFILE"; then
  bad "CDT-509 AC11 Dockerfile USER 0"
else
  if [ -f "$DOCKERFILE" ]; then
    ok "CDT-509 AC11 Dockerfile does not USER 0"
  else
    bad "CDT-509 AC11 Dockerfile does not USER 0 (file missing)"
  fi
fi

if file_has "$COMPOSE" 'read_only:[[:space:]]*true'; then
  ok "CDT-509 AC11 compose read_only: true"
else
  bad "CDT-509 AC11 compose read_only: true missing"
fi

if file_has "$COMPOSE" 'cap_drop:' && grep -Eq 'ALL' "$COMPOSE"; then
  ok "CDT-509 AC11 compose cap_drop ALL"
else
  bad "CDT-509 AC11 compose cap_drop ALL missing"
fi

if file_has "$COMPOSE" '/tmp'; then
  ok "CDT-509 AC11 compose tmpfs /tmp"
else
  bad "CDT-509 AC11 compose tmpfs /tmp missing"
fi

digest_ok=0
if [ -f "$DOCKERFILE" ] && grep -Eq '@sha256:[0-9a-fA-F]{64}' "$DOCKERFILE"; then
  digest_ok=1
fi
if [ -f "$COMPOSE" ] && grep -Eq '@sha256:[0-9a-fA-F]{64}' "$COMPOSE"; then
  digest_ok=1
fi
if [ "$digest_ok" -eq 1 ]; then
  ok "CDT-509 AC11 image pinned @sha256:<64-hex>"
else
  bad "CDT-509 AC11 FROM/image missing @sha256:<64-hex> pin"
fi

latest_ok=1
if [ ! -f "$COMPOSE" ] || [ ! -f "$DOCKERFILE" ]; then
  latest_ok=0
elif grep -Eqh ':latest([[:space:]"'\'']|$)' "$COMPOSE" "$DOCKERFILE"; then
  latest_ok=0
fi
if [ "$latest_ok" -eq 1 ]; then
  ok "CDT-509 AC11 compose/Dockerfile have no :latest"
else
  bad "CDT-509 AC11 :latest present or compose/Dockerfile missing"
fi

if [ -f "$DOCKERFILE" ] && grep -q 'util-linux' "$DOCKERFILE"; then
  ok "CDT-509 AC11 Dockerfile apk includes util-linux"
else
  bad "CDT-509 AC11 Dockerfile util-linux missing"
fi

tok_leak=0
if [ -f "$COMPOSE" ] && grep -qF "$TEST_TOKEN" "$COMPOSE"; then tok_leak=1; fi
if [ -f "$COMPOSE" ] && grep -qF "$SENTINEL" "$COMPOSE"; then tok_leak=1; fi
if [ -f "$DOCKERFILE" ] && grep -qF "$TEST_TOKEN" "$DOCKERFILE"; then tok_leak=1; fi
if [ -f "$DOCKERFILE" ] && grep -qF "$SENTINEL" "$DOCKERFILE"; then tok_leak=1; fi
if [ -f "$COMPOSE" ] && grep -Eqi 'TELEGRAM_BOT_TOKEN|BOT_TOKEN=' "$COMPOSE"; then tok_leak=1; fi
if [ ! -f "$COMPOSE" ] || [ ! -f "$DOCKERFILE" ]; then tok_leak=1; fi
if [ "$tok_leak" -eq 0 ]; then
  ok "CDT-509 AC1 token string absent from compose/Dockerfile"
else
  bad "CDT-509 AC1 token leaked in compose/Dockerfile (or files missing)"
fi

echo
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
