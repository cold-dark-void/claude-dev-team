#!/usr/bin/env bash
# test-signing-sandbox.sh — CDT-211 GPG/SSH/x509 commit-signing sandbox allowlist
# Machine-check: bash skills/init-orchestration/test-signing-sandbox.sh  (exit 0)
# THIS SCRIPT IS A SUBPROCESS CLI — NEVER SOURCE IT.

set -u

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
HELPER="$SCRIPT_DIR/signing-sandbox.sh"
DISCLOSE="$SCRIPT_DIR/disclose-force-overwrite.sh"
SKILL="$SCRIPT_DIR/SKILL.md"
SETUP="$SCRIPT_DIR/../../commands/setup.md"
DOCS_SETUP="$SCRIPT_DIR/../../docs/setup.md"

PASS=0
FAIL=0

# Isolate git config stack from the developer host (full-stack detect).
export GIT_CONFIG_NOSYSTEM=1
export GIT_CONFIG_SYSTEM=/dev/null
export GIT_CONFIG_GLOBAL=/dev/null
unset SSH_AUTH_SOCK || true

assert_eq() {
  local name="$1" got="$2" want="$3"
  if [ "$got" = "$want" ]; then
    PASS=$((PASS + 1)); echo "  ok  $name"
  else
    FAIL=$((FAIL + 1)); echo "  FAIL $name: got=[$got] want=[$want]"
  fi
}

assert_contains() {
  local name="$1" hay="$2" needle="$3"
  if printf '%s' "$hay" | grep -qF -- "$needle"; then
    PASS=$((PASS + 1)); echo "  ok  $name"
  else
    FAIL=$((FAIL + 1)); echo "  FAIL $name: missing [$needle]"
  fi
}

assert_not_contains() {
  local name="$1" hay="$2" needle="$3"
  if printf '%s' "$hay" | grep -qF -- "$needle"; then
    FAIL=$((FAIL + 1)); echo "  FAIL $name: unexpectedly has [$needle]"
  else
    PASS=$((PASS + 1)); echo "  ok  $name"
  fi
}

assert_rc() {
  local name="$1" got="$2" want="$3"
  if [ "$got" -eq "$want" ]; then
    PASS=$((PASS + 1)); echo "  ok  $name"
  else
    FAIL=$((FAIL + 1)); echo "  FAIL $name: rc=$got want=$want"
  fi
}

assert_file() {
  local name="$1" path="$2"
  if [ -f "$path" ]; then
    PASS=$((PASS + 1)); echo "  ok  $name"
  else
    FAIL=$((FAIL + 1)); echo "  FAIL $name: missing $path"
  fi
}

json_get() {
  python3 -c '
import json, sys
d = json.load(open(sys.argv[1], encoding="utf-8"))
cur = d
for p in sys.argv[2].split("."):
    if not isinstance(cur, dict) or p not in cur:
        print("")
        sys.exit(0)
    cur = cur[p]
if cur is None:
    print("")
elif isinstance(cur, bool):
    print("true" if cur else "false")
elif isinstance(cur, (dict, list)):
    print(json.dumps(cur, separators=(",", ":")))
else:
    print(cur)
' "$1" "$2"
}

json_count() {
  python3 -c '
import json, sys
d = json.load(open(sys.argv[1], encoding="utf-8"))
cur = d
for p in sys.argv[2].split("."):
    if not isinstance(cur, dict) or p not in cur:
        print(0)
        sys.exit(0)
    cur = cur[p]
item = sys.argv[3]
if not isinstance(cur, list):
    print(0)
    sys.exit(0)
print(sum(1 for x in cur if x == item))
' "$1" "$2" "$3"
}

echo "=== test-signing-sandbox (CDT-211) ==="

assert_file "helper exists" "$HELPER"
assert_file "disclose helper exists" "$DISCLOSE"
assert_file "SKILL.md exists" "$SKILL"
assert_file "commands/setup.md exists" "$SETUP"
assert_file "docs/setup.md exists" "$DOCS_SETUP"

TMP=$(mktemp -d "${TMPDIR:-/tmp}/signing-sandbox-test.XXXXXX")
trap 'rm -rf "$TMP"' EXIT

make_repo() {
  local d="$1"
  mkdir -p "$d"
  git -C "$d" init -q
  git -C "$d" config user.email "t@t.test"
  git -C "$d" config user.name "t"
}

base_settings() {
  cat > "$1" <<'JSON'
{
  "sandbox": {
    "enabled": true,
    "autoAllowBashIfSandboxed": true,
    "excludedCommands": ["docker", "docker-compose"],
    "network": {
      "allowedDomains": ["github.com"]
    },
    "filesystem": {
      "allowRead": ["~/.cache"]
    }
  }
}
JSON
}

# ---------- detect ----------
echo "-- detect"

REPO_ON="$TMP/repo-on"
make_repo "$REPO_ON"
git -C "$REPO_ON" config --local commit.gpgsign true
OUT=$(bash "$HELPER" detect --repo "$REPO_ON" 2>&1)
RC=$?
assert_rc "detect commit.gpgsign true rc 0" "$RC" 0
assert_contains "detect on" "$OUT" "signing=on"
assert_contains "detect default format openpgp" "$OUT" "format=openpgp"

REPO_TAG="$TMP/repo-tag"
make_repo "$REPO_TAG"
git -C "$REPO_TAG" config --local tag.gpgsign true
OUT=$(bash "$HELPER" detect --repo "$REPO_TAG" 2>&1)
RC=$?
assert_rc "detect tag.gpgsign true rc 0" "$RC" 0
assert_contains "detect tag on" "$OUT" "signing=on"

REPO_FALSE="$TMP/repo-false"
make_repo "$REPO_FALSE"
git -C "$REPO_FALSE" config --local commit.gpgsign false
git -C "$REPO_FALSE" config --local tag.gpgsign false
OUT=$(bash "$HELPER" detect --repo "$REPO_FALSE" 2>&1)
RC=$?
assert_rc "detect explicit false rc 1" "$RC" 1
assert_contains "detect off (false)" "$OUT" "signing=off"

REPO_ABSENT="$TMP/repo-absent"
make_repo "$REPO_ABSENT"
OUT=$(bash "$HELPER" detect --repo "$REPO_ABSENT" 2>&1)
RC=$?
assert_rc "detect absent rc 1" "$RC" 1
assert_contains "detect off (absent)" "$OUT" "signing=off"

REPO_FMT="$TMP/repo-fmt"
make_repo "$REPO_FMT"
git -C "$REPO_FMT" config --local gpg.format ssh
OUT=$(bash "$HELPER" detect --repo "$REPO_FMT" 2>&1)
RC=$?
assert_rc "detect format-only does not trigger rc 1" "$RC" 1
assert_contains "detect format-only off" "$OUT" "signing=off"
assert_contains "detect format-only still ssh" "$OUT" "format=ssh"

REPO_SSH="$TMP/repo-ssh"
make_repo "$REPO_SSH"
git -C "$REPO_SSH" config --local commit.gpgsign true
git -C "$REPO_SSH" config --local gpg.format ssh
OUT=$(bash "$HELPER" detect --repo "$REPO_SSH" 2>&1)
RC=$?
assert_rc "detect ssh + gpgsign rc 0" "$RC" 0
assert_contains "detect ssh on" "$OUT" "signing=on"
assert_contains "detect ssh format" "$OUT" "format=ssh"

# OFF → apply must not mutate settings (AC2)
echo "-- skip when off"
SKIP_SET="$TMP/skip-settings.json"
base_settings "$SKIP_SET"
BEFORE=$(cat "$SKIP_SET")
OUT=$(bash "$HELPER" apply --option 1 --settings "$SKIP_SET" --platform linux \
  --repo "$REPO_ABSENT" --run-user-dir '' 2>&1)
RC=$?
assert_rc "apply while off rc 0 (skip)" "$RC" 0
assert_contains "apply skip marker" "$OUT" "skipped=off"
AFTER=$(cat "$SKIP_SET")
assert_eq "apply while off no mutation" "$AFTER" "$BEFORE"

# ---------- option 1 linux ----------
echo "-- option 1 linux"
SET1="$TMP/opt1-settings.json"
LOCAL1="$TMP/opt1-local.json"
base_settings "$SET1"
mkdir -p "$TMP/run/user/4242"
OUT=$(bash "$HELPER" apply --option 1 --settings "$SET1" --settings-local "$LOCAL1" \
  --platform linux --format openpgp --repo "$REPO_ON" \
  --run-user-dir "$TMP/run/user/4242" 2>&1)
RC=$?
assert_rc "option 1 linux rc 0" "$RC" 0
assert_contains "option 1 linux blast radius" "$OUT" "allowAllUnixSockets"
assert_eq "option 1 allowWrite ~/.gnupg once" "$(json_count "$SET1" sandbox.filesystem.allowWrite '~/.gnupg')" "1"
assert_eq "option 1 linux allowAllUnixSockets true" "$(json_get "$SET1" sandbox.network.allowAllUnixSockets)" "true"
assert_eq "option 1 linux no allowUnixSockets key" "$(json_get "$SET1" sandbox.network.allowUnixSockets)" ""
assert_eq "option 1 preserves allowRead" "$(json_get "$SET1" sandbox.filesystem.allowRead)" '["~/.cache"]'
assert_eq "option 1 preserves docker" "$(json_count "$SET1" sandbox.excludedCommands docker)" "1"
assert_not_contains "option 1 no UID in settings.json" "$(cat "$SET1")" "/run/user/"
assert_contains "option 1 UID only in settings.local.json" "$(cat "$LOCAL1")" "/gnupg"
assert_contains "option 1 local has run-user path" "$(cat "$LOCAL1")" "4242"
assert_not_contains "option 1 local is not settings.json dump" "$(cat "$LOCAL1")" "docker-compose"

# idempotent
OUT2=$(bash "$HELPER" apply --option 1 --settings "$SET1" --settings-local "$LOCAL1" \
  --platform linux --format openpgp --repo "$REPO_ON" \
  --run-user-dir "$TMP/run/user/4242" 2>&1)
RC=$?
assert_rc "option 1 re-run rc 0" "$RC" 0
assert_contains "option 1 re-run no-op mitigated" "$OUT2" "noop=mitigated"
assert_eq "option 1 idempotent ~/.gnupg still once" "$(json_count "$SET1" sandbox.filesystem.allowWrite '~/.gnupg')" "1"

# false→true MUST disclose (CDT-51 AC5)
echo "-- option 1 linux false→true disclose"
SETF="$TMP/opt1-flip.json"
base_settings "$SETF"
python3 -c '
import json
p=json.load(open("'"$SETF"'"))
p["sandbox"]["network"]["allowAllUnixSockets"]=False
json.dump(p, open("'"$SETF"'","w"), indent=2)
open("'"$SETF"'","a").write("\n")
'
OUT=$(bash "$HELPER" apply --option 1 --settings "$SETF" --platform linux \
  --format openpgp --repo "$REPO_ON" --run-user-dir '' --disclose "$DISCLOSE" 2>&1)
RC=$?
assert_rc "flip rc 0" "$RC" 0
assert_contains "flip FORCE-OVERWRITE" "$OUT" "FORCE-OVERWRITE"
assert_contains "flip key" "$OUT" "sandbox.network.allowAllUnixSockets"
assert_contains "flip old false" "$OUT" "old:     false"
assert_contains "flip new true" "$OUT" "new:     true"
assert_eq "flip now true" "$(json_get "$SETF" sandbox.network.allowAllUnixSockets)" "true"

# missing key is not force-overwrite
echo "-- option 1 missing key not force-overwrite"
SETM="$TMP/opt1-missing.json"
base_settings "$SETM"
OUT=$(bash "$HELPER" apply --option 1 --settings "$SETM" --platform linux \
  --format openpgp --repo "$REPO_ON" --run-user-dir '' --disclose "$DISCLOSE" 2>&1)
assert_not_contains "missing key no FORCE-OVERWRITE" "$OUT" "FORCE-OVERWRITE"
assert_contains "missing key still blast note" "$OUT" "allowAllUnixSockets"

# ---------- option 1 macOS / ssh / x509 ----------
echo "-- option 1 macOS"
SETMAC="$TMP/opt1-mac.json"
base_settings "$SETMAC"
OUT=$(bash "$HELPER" apply --option 1 --settings "$SETMAC" --platform macos \
  --format openpgp --repo "$REPO_ON" --run-user-dir '' 2>&1)
RC=$?
assert_rc "option 1 mac rc 0" "$RC" 0
assert_eq "mac allowWrite ~/.gnupg" "$(json_count "$SETMAC" sandbox.filesystem.allowWrite '~/.gnupg')" "1"
assert_eq "mac allowUnixSockets agent" "$(json_count "$SETMAC" sandbox.network.allowUnixSockets '~/.gnupg/S.gpg-agent')" "1"
assert_eq "mac no allowAllUnixSockets" "$(json_get "$SETMAC" sandbox.network.allowAllUnixSockets)" ""

echo "-- option 1 ssh"
SETSSH="$TMP/opt1-ssh.json"
base_settings "$SETSSH"
SOCK="$TMP/ssh-agent.sock"
OUT=$(bash "$HELPER" apply --option 1 --settings "$SETSSH" --platform macos \
  --format ssh --repo "$REPO_SSH" --run-user-dir '' --ssh-auth-sock "$SOCK" 2>&1)
RC=$?
assert_rc "ssh mac rc 0" "$RC" 0
assert_eq "ssh MUST NOT add ~/.ssh" "$(json_count "$SETSSH" sandbox.filesystem.allowWrite '~/.ssh')" "0"
assert_eq "ssh mac adds SSH_AUTH_SOCK" "$(json_count "$SETSSH" sandbox.network.allowUnixSockets "$SOCK")" "1"
assert_eq "ssh mac still has gpg-agent socket" "$(json_count "$SETSSH" sandbox.network.allowUnixSockets '~/.gnupg/S.gpg-agent')" "1"

SETSSH_L="$TMP/opt1-ssh-linux.json"
base_settings "$SETSSH_L"
OUT=$(bash "$HELPER" apply --option 1 --settings "$SETSSH_L" --platform linux \
  --format ssh --repo "$REPO_SSH" --run-user-dir '' --ssh-auth-sock "$SOCK" 2>&1)
RC=$?
assert_rc "ssh linux rc 0" "$RC" 0
assert_eq "ssh linux no ~/.ssh" "$(json_count "$SETSSH_L" sandbox.filesystem.allowWrite '~/.ssh')" "0"
assert_eq "ssh linux allowAllUnixSockets" "$(json_get "$SETSSH_L" sandbox.network.allowAllUnixSockets)" "true"
assert_eq "ssh linux no allowUnixSockets" "$(json_get "$SETSSH_L" sandbox.network.allowUnixSockets)" ""

echo "-- option 1 x509 = openpgp paths"
SETX="$TMP/opt1-x509.json"
base_settings "$SETX"
OUT=$(bash "$HELPER" apply --option 1 --settings "$SETX" --platform linux \
  --format x509 --repo "$REPO_ON" --run-user-dir '' 2>&1)
RC=$?
assert_rc "x509 rc 0" "$RC" 0
assert_eq "x509 allowWrite ~/.gnupg" "$(json_count "$SETX" sandbox.filesystem.allowWrite '~/.gnupg')" "1"
assert_eq "x509 no ~/.ssh" "$(json_count "$SETX" sandbox.filesystem.allowWrite '~/.ssh')" "0"

# ---------- option 2 ----------
echo "-- option 2 unique git"
SET2="$TMP/opt2-settings.json"
base_settings "$SET2"
OUT=$(bash "$HELPER" apply --option 2 --settings "$SET2" --platform linux \
  --repo "$REPO_ON" 2>&1)
RC=$?
assert_rc "option 2 rc 0" "$RC" 0
assert_eq "option 2 git once" "$(json_count "$SET2" sandbox.excludedCommands git)" "1"
assert_eq "option 2 keeps docker" "$(json_count "$SET2" sandbox.excludedCommands docker)" "1"
OUT=$(bash "$HELPER" apply --option 2 --settings "$SET2" --platform linux \
  --repo "$REPO_ON" 2>&1)
RC=$?
assert_rc "option 2 re-run rc 0" "$RC" 0
assert_contains "option 2 re-run no-op" "$OUT" "noop=mitigated"
assert_eq "option 2 git still once" "$(json_count "$SET2" sandbox.excludedCommands git)" "1"
assert_eq "option 2 no filesystem gnupg" "$(json_count "$SET2" sandbox.filesystem.allowWrite '~/.gnupg')" "0"

# ---------- option 3 local-only ----------
echo "-- option 3 local-only"
REPO3="$TMP/repo-opt3"
make_repo "$REPO3"
git -C "$REPO3" config --local commit.gpgsign true
GLOBAL_CFG="$TMP/global.gitconfig"
cat > "$GLOBAL_CFG" <<'EOF'
[commit]
	gpgsign = true
EOF
SET3="$TMP/opt3-settings.json"
base_settings "$SET3"
BEFORE=$(cat "$SET3")
OUT=$(GIT_CONFIG_GLOBAL="$GLOBAL_CFG" bash "$HELPER" apply --option 3 \
  --settings "$SET3" --repo "$REPO3" 2>&1)
RC=$?
assert_rc "option 3 rc 0" "$RC" 0
assert_contains "option 3 remote-signature warning" "$OUT" "signature"
LOCAL_VAL=$(GIT_CONFIG_GLOBAL="$GLOBAL_CFG" git -C "$REPO3" config --local --bool --get commit.gpgsign)
GLOBAL_VAL=$(GIT_CONFIG_GLOBAL="$GLOBAL_CFG" git -C "$REPO3" config --global --bool --get commit.gpgsign)
assert_eq "option 3 local gpgsign false" "$LOCAL_VAL" "false"
assert_eq "option 3 global still true" "$GLOBAL_VAL" "true"
AFTER=$(cat "$SET3")
assert_eq "option 3 does not mutate settings" "$AFTER" "$BEFORE"
assert_contains "option 3 global file still true" "$(cat "$GLOBAL_CFG")" "true"

# ---------- SKILL protocol ----------
echo "-- SKILL protocol grep"
for needle in \
  "signing-sandbox.sh" \
  "commit.gpgsign" \
  "sandbox.filesystem.allowWrite" \
  "sandbox.network.allowAllUnixSockets" \
  "sandbox.network.allowUnixSockets" \
  "sandbox.excludedCommands" \
  "settings.local.json" \
  "~/.gnupg"
do
  if grep -qF -- "$needle" "$SKILL"; then
    PASS=$((PASS + 1)); echo "  ok  skill has [$needle]"
  else
    FAIL=$((FAIL + 1)); echo "  FAIL skill missing [$needle]"
  fi
done

if grep -qF -- "write.allowOnly" "$SKILL" || grep -qF -- '"allowOnly"' "$SKILL"; then
  FAIL=$((FAIL + 1)); echo "  FAIL skill still has stale write.allowOnly / allowOnly"
else
  PASS=$((PASS + 1)); echo "  ok  skill has no write.allowOnly"
fi

if grep -qF -- '"allowWrite": ["~/.cache/go-build"]' "$SKILL"; then
  PASS=$((PASS + 1)); echo "  ok  SKILL Go snippet uses filesystem.allowWrite"
else
  FAIL=$((FAIL + 1)); echo "  FAIL SKILL Go snippet missing allowWrite go-build"
fi

# Greenfield template (defaultMode auto + excludedCommands) must not contain ~/.gnupg
GF=$(python3 - "$SKILL" <<'PY'
import re, sys
text = open(sys.argv[1], encoding="utf-8").read()
blocks = re.findall(r"```json\n(.*?)```", text, flags=re.S)
chosen = None
for b in blocks:
    if '"defaultMode": "auto"' in b and '"excludedCommands"' in b:
        chosen = b
        break
if not chosen:
    print("NO_TEMPLATE")
    sys.exit(0)
print(chosen)
PY
)
assert_not_contains "greenfield template has no ~/.gnupg" "$GF" "~/.gnupg"
assert_contains "greenfield still has docker excludedCommands" "$GF" "docker"
assert_not_contains "greenfield excludedCommands has no git" "$GF" '"git"'

# setup docs one sentence
if grep -qiE 'Step 2.*sign' "$SETUP" || grep -qiE 'detects commit signing' "$SETUP"; then
  PASS=$((PASS + 1)); echo "  ok  commands/setup.md mentions Step 2 commit signing"
else
  FAIL=$((FAIL + 1)); echo "  FAIL commands/setup.md missing Step 2 commit-signing sentence"
fi
if grep -qiE 'Step 2.*sign' "$DOCS_SETUP" || grep -qiE 'detects commit signing' "$DOCS_SETUP"; then
  PASS=$((PASS + 1)); echo "  ok  docs/setup.md mentions Step 2 commit signing"
else
  FAIL=$((FAIL + 1)); echo "  FAIL docs/setup.md missing Step 2 commit-signing sentence"
fi

echo
echo "=== results: PASS=$PASS FAIL=$FAIL ==="
if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
exit 0
