# hooks-lib.sh — sourced by doctor.sh (rv-w3-39 doctor split); pure definitions, no top-level side effects.
# ---------------------------------------------------------------------------
# Expected hooks — single-sourced from init-orchestration SKILL.md
# ---------------------------------------------------------------------------
# Populates EXPECTED_HOOK_EVENTS (space-separated) and EXPECTED_HOOK_SCRIPTS
parse_expected_hooks() {
  EXPECTED_HOOK_EVENTS=""
  EXPECTED_HOOK_SCRIPTS=""
  if [ ! -f "$INIT_ORCH_SKILL" ]; then
    return 0
  fi
  if have_cmd python3; then
    local out
    out=$(INIT_ORCH_SKILL="$INIT_ORCH_SKILL" python3 - <<'PY' 2>/dev/null || true
import os, re, json
skill = open(os.environ["INIT_ORCH_SKILL"], encoding="utf-8").read()
# Find the create-settings JSON fence containing "hooks"
m = re.search(r"```json\n(\{\n  \"env\":.*?\n\})\n```", skill, re.DOTALL)
if not m:
    # broader: first json fence with "hooks"
    for m2 in re.finditer(r"```json\n(.*?)\n```", skill, re.DOTALL):
        if '"hooks"' in m2.group(1):
            m = m2
            break
if not m:
    sys_exit = __import__("sys")
    sys_exit.exit(0)
raw = m.group(1)
# Replace placeholder domains so JSON parses if needed — template has
# "<domains from Step 2>" which is invalid JSON. Strip network block value.
raw2 = re.sub(
    r'"allowedDomains"\s*:\s*\[[^\]]*\]',
    '"allowedDomains": []',
    raw,
)
try:
    data = json.loads(raw2)
except Exception:
    # fall back: extract event names by regex from hooks block
    hm = re.search(r'"hooks"\s*:\s*\{', raw)
    if not hm:
        raise SystemExit(0)
    # Collect top-level keys that look like EventNames
    events = re.findall(r'\n    "([A-Za-z]+)"\s*:\s*\[', raw[hm.start():hm.start()+8000])
    scripts = re.findall(r'\.claude/hooks/([a-z0-9-]+)\.sh', raw)
    print("EVENTS=" + " ".join(dict.fromkeys(events)))
    print("SCRIPTS=" + " ".join(dict.fromkeys(scripts)))
    raise SystemExit(0)
hooks = data.get("hooks") or {}
events = list(hooks.keys())
scripts = []
for _ev, entries in hooks.items():
    if not isinstance(entries, list):
        continue
    for ent in entries:
        for h in (ent.get("hooks") or []):
            cmd = h.get("command") or ""
            for s in re.findall(r"\.claude/hooks/([a-z0-9-]+)\.sh", cmd):
                if s not in scripts:
                    scripts.append(s)
print("EVENTS=" + " ".join(events))
print("SCRIPTS=" + " ".join(scripts))
PY
)
    local line
    while IFS= read -r line || [ -n "$line" ]; do
      case "$line" in
        EVENTS=*) EXPECTED_HOOK_EVENTS=${line#EVENTS=} ;;
        SCRIPTS=*) EXPECTED_HOOK_SCRIPTS=${line#SCRIPTS=} ;;
      esac
    done <<< "$out"
    return 0
  fi
  # Pure-bash fallback: event names listed in the merge prose + scripts via grep
  EXPECTED_HOOK_EVENTS="PreToolUse PostToolUse Stop TaskCompleted PreCompact PostCompact SessionStart PostToolUseFailure PermissionDenied StopFailure"
  EXPECTED_HOOK_SCRIPTS=$(grep -oE '\.claude/hooks/[a-z0-9-]+\.sh' "$INIT_ORCH_SKILL" 2>/dev/null \
    | sed 's|.*/||;s|\.sh$||' | sort -u | tr '\n' ' ' | sed 's/[[:space:]]*$//')
}

parse_expected_hooks

# Settings helpers
settings_json_valid() {
  [ -f "$SETTINGS" ] || return 1
  if have_cmd python3; then
    python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$SETTINGS" 2>/dev/null
    return $?
  fi
  if have_cmd jq; then
    jq -e . "$SETTINGS" >/dev/null 2>&1
    return $?
  fi
  # minimal brace check
  grep -q '{' "$SETTINGS" 2>/dev/null
}

settings_get() {
  # settings_get <python-expr-on-d> — prints value or empty
  local expr="$1"
  [ -f "$SETTINGS" ] || { printf ''; return 0; }
  if have_cmd python3; then
    python3 -c "
import json,sys
try:
  d=json.load(open(sys.argv[1]))
except Exception:
  print('')
  raise SystemExit(0)
$expr
" "$SETTINGS" 2>/dev/null || true
    return 0
  fi
  printf ''
}

# CDT-78: best-effort nested sandbox/container heuristic (read-only).
# return 0 if likely already inside a sandbox/container.
_doctor_nested_sandbox_p() {
  [ -d /run/host ] && return 0
  [ -e /.bubblewrap ] && return 0
  if [ -r /proc/self/mountinfo ]; then
    grep -qiE 'bubblewrap|bwrap' /proc/self/mountinfo 2>/dev/null && return 0
  fi
  return 1
}

# CDT-78: functional bwrap init probe (not PATH-only).
# prints: ok | absent | fail:<rc> | timeout | unsupported
# stdout token only; never throws (M10).
_doctor_bwrap_probe() {
  case "$(uname -s 2>/dev/null || echo unknown)" in
    Linux) ;;
    *) printf 'unsupported'; return 0 ;;
  esac
  if ! have_cmd bwrap; then printf 'absent'; return 0; fi
  local rc=0
  if have_cmd timeout; then
    timeout 3 bwrap --ro-bind / / --proc /proc --dev /dev \
      --unshare-user --unshare-pid --die-with-parent -- true \
      >/dev/null 2>&1 || rc=$?
  else
    # bash fallback: background + sleep kill (still ≤3s intent)
    bwrap --ro-bind / / --proc /proc --dev /dev \
      --unshare-user --unshare-pid --die-with-parent -- true \
      >/dev/null 2>&1 &
    local pid=$!
    local i=0
    while kill -0 "$pid" 2>/dev/null && [ "$i" -lt 30 ]; do
      sleep 0.1; i=$((i + 1))
    done
    if kill -0 "$pid" 2>/dev/null; then
      kill "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
      printf 'timeout'; return 0
    fi
    wait "$pid" || rc=$?
  fi
  # timeout(1) uses 124 on timeout
  if [ "$rc" -eq 0 ]; then printf 'ok'
  elif [ "$rc" -eq 124 ]; then printf 'timeout'
  else printf 'fail:%s' "$rc"
  fi
}

list_settings_hook_events() {
  if [ ! -f "$SETTINGS" ]; then
    printf ''
    return 0
  fi
  if have_cmd python3; then
    python3 -c '
import json,sys
try:
  d=json.load(open(sys.argv[1]))
  hooks=d.get("hooks") or {}
  print(" ".join(hooks.keys()))
except Exception:
  print("")
' "$SETTINGS" 2>/dev/null || true
    return 0
  fi
  if have_cmd jq; then
    jq -r '.hooks // {} | keys | join(" ")' "$SETTINGS" 2>/dev/null || true
    return 0
  fi
  printf ''
}

extract_hook_commands() {
  # Prints one command string per line from settings hooks
  if [ ! -f "$SETTINGS" ]; then
    return 0
  fi
  if have_cmd python3; then
    python3 -c '
import json,sys
try:
  d=json.load(open(sys.argv[1]))
except Exception:
  raise SystemExit(0)
for ev, entries in (d.get("hooks") or {}).items():
  if not isinstance(entries, list):
    continue
  for ent in entries:
    for h in (ent.get("hooks") or []):
      cmd = h.get("command")
      if isinstance(cmd, str) and cmd:
        print(cmd)
' "$SETTINGS" 2>/dev/null || true
  fi
}

# is_managed_hook_cmd <command> → 0 if managed (CDT-77 / M2c″)
# Managed iff first .claude/hooks/<base>.sh basename (no .sh) is in
# EXPECTED_HOOK_SCRIPTS from parse_expected_hooks. Empty expected set → all
# user-owned (safe degrade: no false setup fixits).
is_managed_hook_cmd() {
  local cmd="$1" base
  base=$(printf '%s' "$cmd" | grep -oE '\.claude/hooks/[a-zA-Z0-9_.-]+\.sh' | head -1 || true)
  [ -n "$base" ] || return 1
  base=${base##*/}   # foo.sh
  base=${base%.sh}   # foo
  case " $EXPECTED_HOOK_SCRIPTS " in
    *" $base "*) return 0 ;;
    *) return 1 ;;
  esac
}

