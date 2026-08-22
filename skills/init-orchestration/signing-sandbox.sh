#!/usr/bin/env bash
# signing-sandbox.sh — CDT-211 commit-signing sandbox allowlist
#
# Detect commit/tag GPG (or ssh/x509) signing and merge sandbox allowlist
# options. gpg.format selects path set only; it does not trigger detect.
#
# Usage:
#   signing-sandbox.sh detect [--repo DIR]
#   signing-sandbox.sh apply --option 1|2|3 --settings FILE
#       [--settings-local FILE] [--platform macos|linux|wsl2]
#       [--format openpgp|ssh|x509] [--repo DIR] [--run-user-dir DIR]
#       [--ssh-auth-sock PATH] [--disclose PATH]
#
# Exit:
#   detect: 0 ON, 1 OFF, 2 usage/error
#   apply:  0 applied / no-op mitigated / skipped=off, 2 usage/error
#
# THIS SCRIPT IS A SUBPROCESS CLI — NEVER SOURCE IT.

set -euo pipefail

usage() {
  cat >&2 <<'EOF'
Usage:
  signing-sandbox.sh detect [--repo DIR]
  signing-sandbox.sh apply --option 1|2|3 --settings FILE
      [--settings-local FILE] [--platform macos|linux|wsl2]
      [--format openpgp|ssh|x509] [--repo DIR] [--run-user-dir DIR]
      [--ssh-auth-sock PATH] [--disclose PATH]
EOF
  exit 2
}

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)

CMD="${1:-}"
[ -n "$CMD" ] || usage
shift

REPO=""
OPTION=""
SETTINGS=""
SETTINGS_LOCAL=""
PLATFORM=""
FORMAT=""
FORMAT_SET=0
RUN_USER_DIR=""
RUN_USER_SET=0
SSH_AUTH_SOCK_VAL="${SSH_AUTH_SOCK:-}"
DISCLOSE=""

while [ $# -gt 0 ]; do
  case "$1" in
    --repo)           REPO="${2:-}"; shift 2 ;;
    --option)         OPTION="${2:-}"; shift 2 ;;
    --settings)       SETTINGS="${2:-}"; shift 2 ;;
    --settings-local) SETTINGS_LOCAL="${2:-}"; shift 2 ;;
    --platform)       PLATFORM="${2:-}"; shift 2 ;;
    --format)         FORMAT="${2:-}"; FORMAT_SET=1; shift 2 ;;
    --run-user-dir)   RUN_USER_DIR="${2:-}"; RUN_USER_SET=1; shift 2 ;;
    --ssh-auth-sock)  SSH_AUTH_SOCK_VAL="${2:-}"; shift 2 ;;
    --disclose)       DISCLOSE="${2:-}"; shift 2 ;;
    -h|--help)        usage ;;
    *) echo "signing-sandbox: unknown arg: $1" >&2; usage ;;
  esac
done

git_c() {
  if [ -n "$REPO" ]; then
    git -C "$REPO" "$@"
  else
    git "$@"
  fi
}

normalize_platform() {
  case "$1" in
    macos|Darwin|darwin) printf '%s\n' "macos" ;;
    linux|Linux|wsl2|WSL2|wsl) printf '%s\n' "linux" ;;
    "") ;;
    *) printf '%s\n' "linux" ;;
  esac
}

if [ -z "$PLATFORM" ]; then
  case "$(uname -s 2>/dev/null || echo Linux)" in
    Darwin) PLATFORM=macos ;;
    *) PLATFORM=linux ;;
  esac
else
  PLATFORM=$(normalize_platform "$PLATFORM")
fi

read_format() {
  local f
  f=$(git_c config --get gpg.format 2>/dev/null || true)
  f=$(printf '%s' "$f" | tr '[:upper:]' '[:lower:]')
  case "$f" in
    ssh) printf '%s\n' "ssh" ;;
    x509) printf '%s\n' "x509" ;;
    openpgp|"") printf '%s\n' "openpgp" ;;
    *) printf '%s\n' "openpgp" ;;
  esac
}

detect_signing() {
  local c t
  c=$(git_c config --bool --get commit.gpgsign 2>/dev/null || true)
  t=$(git_c config --bool --get tag.gpgsign 2>/dev/null || true)
  if [ "$c" = "true" ] || [ "$t" = "true" ]; then
    return 0
  fi
  return 1
}

cmd_detect() {
  local fmt
  fmt=$(read_format)
  if detect_signing; then
    printf '%s\n' "signing=on"
    printf '%s\n' "format=${fmt}"
    exit 0
  fi
  printf '%s\n' "signing=off"
  printf '%s\n' "format=${fmt}"
  exit 1
}

json_merge() {
  # MODE=check → exit 0 mitigated / 1 not / 2 error
  # MODE=apply → mutate settings (+ optional local UID path)
  if ! command -v python3 >/dev/null 2>&1; then
    echo "signing-sandbox: python3 required" >&2
    exit 2
  fi
  SETTINGS_FILE="$SETTINGS" \
  SETTINGS_LOCAL_FILE="${SETTINGS_LOCAL:-}" \
  OPTION_VAL="$OPTION" \
  PLATFORM_VAL="$PLATFORM" \
  FORMAT_VAL="$FORMAT" \
  SSH_SOCK_VAL="${SSH_AUTH_SOCK_VAL:-}" \
  UID_GNUPG="${UID_GNUPG:-}" \
  python3 - <<'PY'
import json, os, sys

mode = os.environ.get("MODE", "apply")
settings_path = os.environ["SETTINGS_FILE"]
local_path = os.environ.get("SETTINGS_LOCAL_FILE") or ""
option = os.environ.get("OPTION_VAL", "")
platform = os.environ.get("PLATFORM_VAL", "linux")
fmt = (os.environ.get("FORMAT_VAL") or "openpgp").lower()
ssh_sock = os.environ.get("SSH_SOCK_VAL") or ""
uid_gnupg = os.environ.get("UID_GNUPG") or ""

def load(path):
    if not path or not os.path.isfile(path):
        return {}
    try:
        with open(path, encoding="utf-8") as fh:
            data = json.load(fh)
    except Exception as e:
        sys.stderr.write("signing-sandbox: cannot parse %s: %s\n" % (path, e))
        sys.exit(2)
    if not isinstance(data, dict):
        sys.stderr.write("signing-sandbox: %s is not a JSON object\n" % path)
        sys.exit(2)
    return data

def dump(path, data):
    parent = os.path.dirname(path)
    if parent:
        os.makedirs(parent, exist_ok=True)
    tmp = path + ".tmp." + str(os.getpid())
    with open(tmp, "w", encoding="utf-8") as fh:
        json.dump(data, fh, indent=2)
        fh.write("\n")
    os.replace(tmp, path)

def as_list(v):
    if v is None:
        return []
    if isinstance(v, list):
        return list(v)
    return [v]

def unique_append(lst, item):
    if item not in lst:
        lst.append(item)
    return lst

def sandbox_fs_net(data):
    sandbox = data.get("sandbox")
    if not isinstance(sandbox, dict):
        sandbox = {}
    fs = sandbox.get("filesystem")
    if not isinstance(fs, dict):
        fs = {}
    net = sandbox.get("network")
    if not isinstance(net, dict):
        net = {}
    return sandbox, fs, net

def is_mitigated(data):
    sandbox, fs, net = sandbox_fs_net(data)
    if "git" in as_list(sandbox.get("excludedCommands")):
        return True
    if "~/.gnupg" not in as_list(fs.get("allowWrite")):
        return False
    if platform == "linux":
        return net.get("allowAllUnixSockets") is True
    socks = as_list(net.get("allowUnixSockets"))
    if "~/.gnupg/S.gpg-agent" not in socks:
        return False
    if fmt == "ssh" and ssh_sock and ssh_sock not in socks:
        return False
    return True

if not settings_path:
    sys.stderr.write("signing-sandbox: --settings required\n")
    sys.exit(2)
if not os.path.isfile(settings_path):
    sys.stderr.write("signing-sandbox: settings not found: %s\n" % settings_path)
    sys.exit(2)

data = load(settings_path)

if mode == "check":
    sys.exit(0 if is_mitigated(data) else 1)

if is_mitigated(data):
    sys.exit(0)

sandbox = data.setdefault("sandbox", {})
if not isinstance(sandbox, dict):
    sandbox = {}
    data["sandbox"] = sandbox

if option == "2":
    exc = as_list(sandbox.get("excludedCommands"))
    unique_append(exc, "git")
    sandbox["excludedCommands"] = exc
    dump(settings_path, data)
    sys.exit(0)

if option != "1":
    sys.stderr.write("signing-sandbox: unknown option %s\n" % option)
    sys.exit(2)

fs = sandbox.get("filesystem")
if not isinstance(fs, dict):
    fs = {}
    sandbox["filesystem"] = fs
aw = as_list(fs.get("allowWrite"))
unique_append(aw, "~/.gnupg")
# ssh: MUST NOT add ~/.ssh
fs["allowWrite"] = aw

net = sandbox.get("network")
if not isinstance(net, dict):
    net = {}
    sandbox["network"] = net

if platform == "linux":
    net["allowAllUnixSockets"] = True
else:
    socks = as_list(net.get("allowUnixSockets"))
    unique_append(socks, "~/.gnupg/S.gpg-agent")
    if fmt == "ssh" and ssh_sock:
        unique_append(socks, ssh_sock)
    net["allowUnixSockets"] = socks

dump(settings_path, data)

if uid_gnupg and local_path:
    local = load(local_path) if os.path.isfile(local_path) else {}
    lsb = local.setdefault("sandbox", {})
    if not isinstance(lsb, dict):
        lsb = {}
        local["sandbox"] = lsb
    lfs = lsb.get("filesystem")
    if not isinstance(lfs, dict):
        lfs = {}
        lsb["filesystem"] = lfs
    law = as_list(lfs.get("allowWrite"))
    unique_append(law, uid_gnupg)
    lfs["allowWrite"] = law
    dump(local_path, local)

sys.exit(0)
PY
}

cmd_apply() {
  case "$OPTION" in
    1|2|3) ;;
    *) echo "signing-sandbox: --option must be 1, 2, or 3" >&2; usage ;;
  esac
  [ -n "$SETTINGS" ] || usage

  if [ "$FORMAT_SET" -eq 0 ]; then
    FORMAT=$(read_format)
  else
    FORMAT=$(printf '%s' "$FORMAT" | tr '[:upper:]' '[:lower:]')
    case "$FORMAT" in
      ssh|x509|openpgp) ;;
      *) FORMAT=openpgp ;;
    esac
  fi

  if detect_signing; then
    :
  else
    printf '%s\n' "skipped=off"
    exit 0
  fi

  if [ "$OPTION" = "3" ]; then
    git_c config --local commit.gpgsign false
    echo "WARNING: local commit.gpgsign set false. Remotes that require commit signatures will still reject unsigned commits." >&2
    printf '%s\n' "applied=option3"
    exit 0
  fi

  [ -f "$SETTINGS" ] || {
    echo "signing-sandbox: settings not found: $SETTINGS" >&2
    exit 2
  }

  if [ -z "$DISCLOSE" ]; then
    DISCLOSE="$SCRIPT_DIR/disclose-force-overwrite.sh"
  fi

  UID_GNUPG=""
  if [ "$OPTION" = "1" ]; then
    if [ "$RUN_USER_SET" -eq 1 ]; then
      if [ -n "$RUN_USER_DIR" ]; then
        case "$RUN_USER_DIR" in
          */gnupg) UID_GNUPG="$RUN_USER_DIR" ;;
          *) UID_GNUPG="${RUN_USER_DIR%/}/gnupg" ;;
        esac
      fi
    else
      _uid_base="/run/user/$(id -u)"
      if [ -d "$_uid_base" ]; then
        UID_GNUPG="${_uid_base}/gnupg"
      fi
    fi
  fi
  export UID_GNUPG

  set +e
  MODE=check json_merge
  _mit_rc=$?
  set -e
  if [ "$_mit_rc" -eq 0 ]; then
    printf '%s\n' "noop=mitigated"
    exit 0
  fi
  if [ "$_mit_rc" -eq 2 ]; then
    exit 2
  fi

  if [ "$OPTION" = "1" ] && [ "$PLATFORM" = "linux" ]; then
    echo "NOTE: Linux/WSL2 sandbox.network.allowAllUnixSockets=true allows ALL unix sockets (seccomp cannot path-filter)." >&2
    _old_all=$(SETTINGS_FILE="$SETTINGS" python3 - <<'PY'
import json, os, sys
path = os.environ["SETTINGS_FILE"]
try:
    with open(path, encoding="utf-8") as fh:
        data = json.load(fh)
except Exception:
    print("")
    sys.exit(0)
net = ((data.get("sandbox") or {}).get("network") or {})
v = net.get("allowAllUnixSockets") if isinstance(net, dict) else None
if v is True:
    print("true")
elif v is False:
    print("false")
else:
    print("")
PY
)
    if [ "$_old_all" = "false" ]; then
      if [ -n "$DISCLOSE" ] && [ -f "$DISCLOSE" ]; then
        bash "$DISCLOSE" \
          --key sandbox.network.allowAllUnixSockets \
          --old false \
          --new true || true
      else
        cat <<EOF
FORCE-OVERWRITE: managed value will be replaced
  key:     sandbox.network.allowAllUnixSockets
  old:     false
  new:     true
  restore: sandbox.network.allowAllUnixSockets  (set back to: false)
EOF
      fi
    fi
  fi

  MODE=apply json_merge
  printf '%s\n' "applied=option${OPTION}"
  exit 0
}

case "$CMD" in
  detect) cmd_detect ;;
  apply)  cmd_apply ;;
  *) echo "signing-sandbox: unknown command: $CMD" >&2; usage ;;
esac
