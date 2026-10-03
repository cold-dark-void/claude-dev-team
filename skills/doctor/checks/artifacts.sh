# artifacts.sh — sourced by doctor.sh (rv-w3-39 doctor split); pure definitions, no top-level side effects.
check_handoff_tmp() {
  local hdir="$MROOT/.claude/handoff/cache" n=0 f
  if [ ! -d "$hdir" ]; then
    record "handoff.tmp" "handoff" "PASS" "no handoff cache" ""
    return 0
  fi
  for f in "$hdir"/*.tmp; do
    [ -f "$f" ] || continue
    n=$((n + 1))
  done
  if [ "$n" -gt 0 ]; then
    record "handoff.tmp" "handoff" "WARN" \
      "$n orphaned *.tmp under .claude/handoff/cache/" \
      "doctor --fix --only handoff.tmp"
  else
    record "handoff.tmp" "handoff" "PASS" "no handoff *.tmp" ""
  fi
}

# CDT-221 / SPEC-022 M2h — WARN-never-FAIL. SoT is transcript-sync --check stdout.
# SKIP python3-absent before walking settings. Never treat --check rc as FAIL.
check_transcript_mirror_lag() {
  local id="transcript.mirror_lag" group="transcript"
  if ! have_cmd python3; then
    record "$id" "$group" "SKIP" "python3 absent" ""
    return 0
  fi

  local opted
  opted=$(python3 -c '
import json, os, sys
needle = "transcript-mirror.sh"

def walk(obj):
    if isinstance(obj, dict):
        cmd = obj.get("command")
        if isinstance(cmd, str) and needle in cmd:
            return True
        return any(walk(v) for v in obj.values())
    if isinstance(obj, list):
        return any(walk(x) for x in obj)
    return False

for p in sys.argv[1:]:
    if not p or not os.path.isfile(p):
        continue
    try:
        d = json.load(open(p))
    except Exception:
        continue
    if isinstance(d, dict) and walk(d.get("hooks")):
        print("yes")
        raise SystemExit(0)
print("no")
' \
    "$MROOT/.claude/settings.json" \
    "$MROOT/.claude/settings.local.json" \
    "$WTROOT/.claude/settings.json" \
    "$WTROOT/.claude/settings.local.json" 2>/dev/null) || opted="no"

  if [ "$opted" != "yes" ]; then
    record "$id" "$group" "SKIP" "transcript-mirror not opted-in" ""
    return 0
  fi

  local sync_sh="$PLUGIN_ROOT/skills/transcript-mirror/transcript-sync.sh"
  if [ ! -f "$sync_sh" ]; then
    record "$id" "$group" "SKIP" "transcript-sync.sh missing" ""
    return 0
  fi

  local check_out
  check_out=$(mktemp "${TMPDIR:-/tmp}/doctor-tmlag.XXXXXX") || {
    record "$id" "$group" "SKIP" "cannot capture transcript-sync --check" ""
    return 0
  }
  # HOME / TRANSCRIPT_MIRROR_ROOT / GROK_SESSIONS_DIR inherit. Pin plugin root
  # so --check uses this install when cwd is a consumer/fixture project.
  CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" \
    bash "$sync_sh" --check --cwd "$WTROOT" >"$check_out" 2>/dev/null || true

  local line sid st rest lag_list="" n=0
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      sid=*)
        n=$((n + 1))
        sid=${line#sid=}
        sid=${sid%% *}
        rest=${line#*status=}
        if [ "$rest" = "$line" ]; then
          continue
        fi
        st=${rest%% *}
        case "$st" in
          missing|lag)
            lag_list="${lag_list:+$lag_list }$sid:$st"
            ;;
        esac
        ;;
    esac
  done < "$check_out"
  rm -f "$check_out"

  if [ -n "$lag_list" ]; then
    record "$id" "$group" "WARN" \
      "cwd transcript mirror missing/lag: $lag_list" \
      "bash skills/transcript-mirror/transcript-sync.sh"
  else
    record "$id" "$group" "PASS" \
      "cwd transcript mirror ok ($n sessions)" ""
  fi
}

# SPEC-037 M19 / CDT-228: Model map layers. WARN never FAIL.
