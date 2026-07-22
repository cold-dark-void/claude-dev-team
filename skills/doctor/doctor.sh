#!/usr/bin/env bash
# doctor.sh — install & config diagnostics (SPEC-022 / CDV-191)
#
# Usage: doctor.sh [--json] [--fix] [--only <id|group>] [-h|--help]
# Exit: 0 all PASS · 1 ≥1 WARN no FAIL · 2 ≥1 FAIL · 64 usage
#
# THIS SCRIPT IS A SUBPROCESS CLI — NEVER SOURCE IT.
# Read-only by default. --fix applies only the allowlisted repairs.

set -euo pipefail

DOCTOR_SCHEMA="1"
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
PLUGIN_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/../.." && pwd)

JSON_MODE=0
FIX_MODE=0
ONLY_FILTER=""
USAGE_ERR=0

# ---------------------------------------------------------------------------
# Arg parse
# ---------------------------------------------------------------------------
usage() {
  cat <<'EOF' >&2
Usage: doctor.sh [--json] [--fix] [--only <check-id|group>] [-h|--help]

  --json              Emit single JSON document on stdout (diagnostics on stderr)
  --fix               Apply allowlisted repairs only (distilling_lock, STALE .wt-lock, handoff *.tmp)
  --only <id|group>   Run a subset of checks
  -h, --help          Show this help

Exit codes: 0=all PASS  1=WARN only  2=FAIL  64=usage
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --json) JSON_MODE=1; shift ;;
    --fix) FIX_MODE=1; shift ;;
    --only)
      if [ $# -lt 2 ] || [ -z "${2:-}" ]; then
        echo "doctor: --only requires an argument" >&2
        USAGE_ERR=1
        break
      fi
      ONLY_FILTER="$2"
      shift 2
      ;;
    -h|--help) usage; exit 0 ;;
    --) shift; break ;;
    -*)
      echo "doctor: unknown flag: $1" >&2
      USAGE_ERR=1
      break
      ;;
    *)
      echo "doctor: unexpected argument: $1" >&2
      USAGE_ERR=1
      break
      ;;
  esac
done

if [ "$USAGE_ERR" -eq 1 ]; then
  usage
  exit 64
fi

# ---------------------------------------------------------------------------
# Roots
# ---------------------------------------------------------------------------
resolve_mroot() {
  local _gc
  if _gc=$(git rev-parse --git-common-dir 2>/dev/null); then
    MROOT=$(CDPATH= cd -- "$(dirname -- "$_gc")" && pwd)
  else
    MROOT=$(pwd)
  fi
}

resolve_mroot
MEMDB="$MROOT/.claude/memory/memory.db"
SETTINGS="$MROOT/.claude/settings.json"
PLUGIN_DIR_SH="$PLUGIN_ROOT/skills/plugin-dir.sh"
WT_LIB="$PLUGIN_ROOT/skills/worktree-lib.sh"
INIT_ORCH_SKILL="$PLUGIN_ROOT/skills/init-orchestration/SKILL.md"
SCHEMA_SQL="$PLUGIN_ROOT/skills/memory-store/schema.sql"
CHECK_HOOK_TEMPLATES="$PLUGIN_ROOT/skills/init-orchestration/check-hook-templates.sh"

# ---------------------------------------------------------------------------
# Result registry
# ---------------------------------------------------------------------------
# Parallel arrays (bash 4+)
CHECK_IDS=()
CHECK_GROUPS=()
CHECK_STATUSES=()
CHECK_DETAILS=()
CHECK_FIXITS=()

# Registration table: id|group|fn  (populated then filtered/run)
REG_IDS=()
REG_GROUPS=()
REG_FNS=()

register_check() {
  REG_IDS+=("$1")
  REG_GROUPS+=("$2")
  REG_FNS+=("$3")
}

record() {
  # record <id> <group> <status> <detail> [fixit]
  local id="$1" group="$2" status="$3" detail="$4" fixit="${5:-}"
  CHECK_IDS+=("$id")
  CHECK_GROUPS+=("$group")
  CHECK_STATUSES+=("$status")
  CHECK_DETAILS+=("$detail")
  CHECK_FIXITS+=("$fixit")
}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
json_escape() {
  # Escape a string for JSON double-quoted value (pure bash).
  local s=${1-}
  s=${s//\\/\\\\}
  s=${s//\"/\\\"}
  s=${s//$'\n'/\\n}
  s=${s//$'\r'/\\r}
  s=${s//$'\t'/\\t}
  printf '%s' "$s"
}

have_cmd() { command -v "$1" >/dev/null 2>&1; }

# Platform extension suffix for sqlite loadables
ext_suffix() {
  if [ "$(uname -s 2>/dev/null || echo Linux)" = "Darwin" ]; then
    printf 'dylib'
  else
    printf 'so'
  fi
}

parse_changelog_version() {
  # First ### vX.Y.Z or ### X.Y.Z heading
  local f="$1" line ver
  [ -f "$f" ] || { printf ''; return 0; }
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      "### v"[0-9]*)
        ver=${line#\#\#\# v}
        ver=${ver%%[[:space:]]*}
        printf '%s' "$ver"
        return 0
        ;;
      "### "[0-9]*)
        ver=${line#\#\#\# }
        ver=${ver%%[[:space:]]*}
        printf '%s' "$ver"
        return 0
        ;;
    esac
  done < "$f"
  printf ''
}

parse_plugin_json_version() {
  local f="$1"
  [ -f "$f" ] || { printf ''; return 0; }
  if have_cmd python3; then
    python3 -c '
import json,sys
try:
  d=json.load(open(sys.argv[1]))
  print(d.get("version","") or "")
except Exception:
  print("__PARSE_ERROR__")
' "$f" 2>/dev/null || printf '__PARSE_ERROR__'
    return 0
  fi
  if have_cmd jq; then
    jq -r '.version // empty' "$f" 2>/dev/null || printf '__PARSE_ERROR__'
    return 0
  fi
  # bash/grep fallback
  local line
  line=$(grep -E '"version"[[:space:]]*:' "$f" 2>/dev/null | head -1 || true)
  if [ -z "$line" ]; then printf ''; return 0; fi
  line=${line#*\"version\"}
  line=${line#*:}
  line=${line#*\"}
  line=${line%%\"*}
  printf '%s' "$line"
}

parse_marketplace_version() {
  local f="$1"
  [ -f "$f" ] || { printf ''; return 0; }
  if have_cmd python3; then
    python3 -c '
import json,sys
try:
  d=json.load(open(sys.argv[1]))
  plugs=d.get("plugins") or []
  if not plugs:
    print("")
  else:
    print(plugs[0].get("version","") or "")
except Exception:
  print("__PARSE_ERROR__")
' "$f" 2>/dev/null || printf '__PARSE_ERROR__'
    return 0
  fi
  if have_cmd jq; then
    jq -r '.plugins[0].version // empty' "$f" 2>/dev/null || printf '__PARSE_ERROR__'
    return 0
  fi
  local line
  line=$(grep -E '"version"[[:space:]]*:' "$f" 2>/dev/null | head -1 || true)
  if [ -z "$line" ]; then printf ''; return 0; fi
  line=${line#*\"version\"}
  line=${line#*:}
  line=${line#*\"}
  line=${line%%\"*}
  printf '%s' "$line"
}

expected_schema_version() {
  local f="$SCHEMA_SQL" line n
  if [ -f "$f" ]; then
    # Match seed: ('schema_version', 'N')
    line=$(grep -E "\('schema_version'[[:space:]]*,[[:space:]]*'[0-9]+'\)" "$f" 2>/dev/null | head -1 || true)
    if [ -n "$line" ]; then
      n=${line#*\'schema_version\'}
      n=${n#*,}
      n=${n#*\'}
      n=${n%%\'*}
      if [[ "$n" =~ ^[0-9]+$ ]]; then
        printf '%s' "$n"
        return 0
      fi
    fi
  fi
  printf '3'
}

infer_tier() {
  local p="$1"
  if [ -z "$p" ]; then
    printf 'unknown'
    return 0
  fi
  case "$p" in
    "$MROOT"|"$MROOT"/*) printf 'dev' ;;
    */.claude/plugins/cache/*) printf 'cache' ;;
    *) printf 'fallback' ;;
  esac
}

# Resolve plugin version + tier for header (from PLUGIN_ROOT install)
PLUGIN_VERSION=$(parse_plugin_json_version "$PLUGIN_ROOT/.claude-plugin/plugin.json")
[ "$PLUGIN_VERSION" = "__PARSE_ERROR__" ] && PLUGIN_VERSION="unknown"
RESOLVED_TIER=$(infer_tier "$PLUGIN_ROOT")
# When PLUGIN_ROOT is under MROOT, force dev; when under cache path, cache
case "$PLUGIN_ROOT" in
  "$MROOT"|"$MROOT"/*) RESOLVED_TIER=dev ;;
  */.claude/plugins/cache/*) RESOLVED_TIER=cache ;;
esac

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

# ---------------------------------------------------------------------------
# Checks
# ---------------------------------------------------------------------------

check_version_triplet() {
  local pj="$PLUGIN_ROOT/.claude-plugin/plugin.json"
  local mj="$PLUGIN_ROOT/.claude-plugin/marketplace.json"
  local cl="$PLUGIN_ROOT/CHANGELOG.md"
  local v_p v_m v_c

  if [ ! -f "$pj" ]; then
    record "version.triplet" "version" "FAIL" \
      "plugin.json missing at $pj" \
      "Install or update the dev-team plugin"
    return 0
  fi

  v_p=$(parse_plugin_json_version "$pj")
  v_m=$(parse_marketplace_version "$mj")
  v_c=$(parse_changelog_version "$cl")

  if [ "$v_p" = "__PARSE_ERROR__" ] || [ "$v_m" = "__PARSE_ERROR__" ]; then
    record "version.triplet" "version" "FAIL" \
      "unparseable plugin JSON (plugin=$v_p marketplace=$v_m)" \
      "Fix JSON in .claude-plugin/plugin.json and marketplace.json"
    return 0
  fi

  if [ -z "$v_p" ] || [ -z "$v_m" ] || [ -z "$v_c" ]; then
    record "version.triplet" "version" "FAIL" \
      "version missing: plugin.json='$v_p' marketplace.json='$v_m' CHANGELOG='$v_c'" \
      "Run /release (dev) or update the plugin (consumer)"
    return 0
  fi

  if [ "$v_p" = "$v_m" ] && [ "$v_p" = "$v_c" ]; then
    record "version.triplet" "version" "PASS" \
      "plugin.json=marketplace.json=CHANGELOG=$v_p" ""
  else
    record "version.triplet" "version" "FAIL" \
      "version drift: plugin.json=$v_p marketplace.json=$v_m CHANGELOG=$v_c" \
      "Run /release (dev checkout) or update the plugin (consumer)"
  fi
}

check_plugin_resolve() {
  local rel="skills/doctor/doctor.sh"
  local resolved="" rc=0
  if [ ! -f "$PLUGIN_DIR_SH" ]; then
    record "plugin.resolve" "plugin" "FAIL" \
      "plugin-dir.sh missing next to doctor install" \
      "Reinstall the dev-team plugin"
    return 0
  fi
  # Run from MROOT context so tier reflects project-relative resolution
  set +e
  resolved=$(cd "$MROOT" && bash "$PLUGIN_DIR_SH" file "$rel" 2>/dev/null)
  rc=$?
  set -e
  if [ "$rc" -eq 3 ] || [ -z "$resolved" ]; then
    # Fall back: report install path of the running doctor (still a valid resolve)
    resolved="$SCRIPT_DIR/doctor.sh"
    local tier
    tier=$(infer_tier "$PLUGIN_ROOT")
    record "plugin.resolve" "plugin" "PASS" \
      "plugin-dir exit 3 for $rel from MROOT; running install at $PLUGIN_ROOT (tier=$tier)" ""
    return 0
  fi
  local tier
  tier=$(infer_tier "$resolved")
  record "plugin.resolve" "plugin" "PASS" \
    "resolved $rel → $resolved (tier=$tier)" ""
}

check_memory_sqlite3() {
  if have_cmd sqlite3; then
    local ver
    ver=$(sqlite3 -version 2>/dev/null | awk '{print $1}' || echo present)
    record "memory.sqlite3" "memory" "PASS" "sqlite3 present ($ver)" ""
  else
    record "memory.sqlite3" "memory" "WARN" \
      "sqlite3 not on PATH — memory uses .md fallback; schema/ext probes SKIP" \
      "Install sqlite3 (system package manager)"
  fi
}

check_memory_db() {
  if [ -f "$MEMDB" ]; then
    record "memory.db" "memory" "PASS" "memory.db present at $MEMDB" ""
  else
    record "memory.db" "memory" "WARN" \
      "memory.db absent — project not bootstrapped (or .md-only mode)" \
      "/setup team"
  fi
}

check_memory_schema() {
  if ! have_cmd sqlite3; then
    record "memory.schema" "memory" "SKIP" "sqlite3 absent — cannot read schema_version" ""
    return 0
  fi
  if [ ! -f "$MEMDB" ]; then
    record "memory.schema" "memory" "SKIP" "memory.db absent — schema check deferred until /setup team" ""
    return 0
  fi
  local expected actual
  expected=$(expected_schema_version)
  actual=$(sqlite3 -cmd ".timeout 5000" "$MEMDB" \
    "SELECT value FROM config WHERE key='schema_version';" 2>/dev/null || true)
  if [ -z "$actual" ]; then
    record "memory.schema" "memory" "FAIL" \
      "schema_version missing in config (expected $expected)" \
      "Run /setup team or skills/memory-store/migrate.sh"
    return 0
  fi
  if [ "$actual" = "$expected" ]; then
    record "memory.schema" "memory" "PASS" "schema_version=$actual" ""
  else
    record "memory.schema" "memory" "FAIL" \
      "schema_version=$actual expected=$expected" \
      "Run bash skills/memory-store/migrate.sh (or /setup team)"
  fi
}

_probe_ext_load() {
  # _probe_ext_load <libpath-without-or-with-suffix> → 0 if loadable via :memory:
  local lib="$1"
  [ -n "$lib" ] || return 1
  # Strip suffix if present — sqlite .load appends it
  local base="$lib"
  case "$base" in
    *.so|*.dylib) base=${base%.*} ;;
  esac
  [ -f "${base}.$(ext_suffix)" ] || [ -f "$base" ] || return 1
  sqlite3 :memory: ".load $base" "SELECT 1;" >/dev/null 2>&1
}

check_memory_ext_vec() {
  if ! have_cmd sqlite3; then
    record "memory.ext.vec" "memory" "SKIP" "sqlite3 absent" ""
    return 0
  fi
  local ext_dir="$MROOT/.claude/memory/extensions"
  local lib="$ext_dir/vec0"
  if _probe_ext_load "$lib"; then
    record "memory.ext.vec" "memory" "PASS" "vec0 loadable via :memory: probe" ""
  else
    record "memory.ext.vec" "memory" "WARN" \
      "vec0 not loadable — semantic search degraded to keyword" \
      "/setup team (downloads extensions) or install vec0 under .claude/memory/extensions/"
  fi
}

check_memory_ext_lembed() {
  if ! have_cmd sqlite3; then
    record "memory.ext.lembed" "memory" "SKIP" "sqlite3 absent" ""
    return 0
  fi
  local ext_dir="$MROOT/.claude/memory/extensions"
  local lib="$ext_dir/lembed0"
  if _probe_ext_load "$lib"; then
    record "memory.ext.lembed" "memory" "PASS" "lembed0 loadable via :memory: probe" ""
  else
    record "memory.ext.lembed" "memory" "WARN" \
      "lembed0 not loadable — local GGUF embeddings unavailable" \
      "/setup team or install lembed0 under .claude/memory/extensions/"
  fi
}

check_memory_embedding_config() {
  if ! have_cmd sqlite3; then
    record "memory.embedding_config" "memory" "SKIP" "sqlite3 absent" ""
    return 0
  fi
  if [ ! -f "$MEMDB" ]; then
    record "memory.embedding_config" "memory" "SKIP" "memory.db absent" ""
    return 0
  fi
  local mode url model_path
  mode=$(sqlite3 -cmd ".timeout 5000" "$MEMDB" \
    "SELECT value FROM config WHERE key='embedding_mode';" 2>/dev/null || true)
  url=$(sqlite3 -cmd ".timeout 5000" "$MEMDB" \
    "SELECT value FROM config WHERE key='embedding_url';" 2>/dev/null || true)
  # Env overrides URL for remote mode coherence
  if [ -n "${EMBEDDING_URL:-}" ]; then
    url="$EMBEDDING_URL"
  fi
  mode=${mode:-fallback}

  case "$mode" in
    fallback)
      record "memory.embedding_config" "memory" "PASS" \
        "embedding_mode=fallback (keyword only)" ""
      ;;
    remote)
      if [ -z "$url" ]; then
        record "memory.embedding_config" "memory" "WARN" \
          "embedding_mode=remote but embedding_url empty/missing" \
          "Set embedding_url via /memory config or export EMBEDDING_URL"
        return 0
      fi
      # Host in allowedDomains?
      local host
      host=$(printf '%s' "$url" | sed -E 's|^[a-zA-Z][a-zA-Z0-9+.-]*://||; s|/.*||; s|:.*||')
      local domains=""
      if [ -f "$SETTINGS" ] && have_cmd python3; then
        domains=$(python3 -c '
import json,sys
try:
  d=json.load(open(sys.argv[1]))
  nets=(d.get("sandbox") or {}).get("network") or {}
  print(" ".join(nets.get("allowedDomains") or []))
except Exception:
  print("")
' "$SETTINGS" 2>/dev/null || true)
      fi
      local found=0 d
      for d in $domains; do
        # domain entry may include :port
        case "$d" in
          "$host"|"$host":*) found=1; break ;;
        esac
        # also match if entry is suffix
        case "$host" in
          *"$d"*) found=1; break ;;
        esac
      done
      if [ "$found" -eq 0 ]; then
        record "memory.embedding_config" "memory" "WARN" \
          "embedding_mode=remote URL host '$host' not in sandbox.network.allowedDomains" \
          "Add $host to sandbox.network.allowedDomains via /setup orchestration"
      else
        record "memory.embedding_config" "memory" "PASS" \
          "embedding_mode=remote url host '$host' allowlisted" ""
      fi
      ;;
    lembed)
      local ext_dir="$MROOT/.claude/memory/extensions"
      local model_path="$MROOT/.claude/memory/models/all-MiniLM-L6-v2.gguf"
      local ok=1 detail=""
      if ! _probe_ext_load "$ext_dir/lembed0"; then
        ok=0
        detail="lembed0 not loadable"
      fi
      if [ ! -f "$model_path" ]; then
        ok=0
        detail="${detail:+$detail; }GGUF model missing at models/all-MiniLM-L6-v2.gguf"
      fi
      if [ "$ok" -eq 1 ]; then
        record "memory.embedding_config" "memory" "PASS" \
          "embedding_mode=lembed (ext+GGUF present)" ""
      else
        record "memory.embedding_config" "memory" "WARN" \
          "embedding_mode=lembed but $detail" \
          "/setup team (downloads lembed + GGUF model)"
      fi
      ;;
    *)
      record "memory.embedding_config" "memory" "WARN" \
        "unknown embedding_mode='$mode'" \
        "Set embedding_mode to fallback|remote|lembed via /memory config"
      ;;
  esac
}

check_hooks_events() {
  if [ ! -f "$SETTINGS" ]; then
    record "hooks.events" "hooks" "WARN" \
      "settings.json absent — hooks not wired" \
      "/setup orchestration"
    return 0
  fi
  if ! settings_json_valid; then
    record "hooks.events" "hooks" "FAIL" \
      "settings.json unparseable — cannot verify hooks" \
      "Fix JSON in .claude/settings.json then re-run /setup orchestration"
    return 0
  fi

  # If hooks key entirely absent → WARN (never bootstrapped)
  local has_hooks
  has_hooks=$(settings_get 'print("1" if isinstance(d.get("hooks"), dict) and d.get("hooks") else "0")')
  if [ "$has_hooks" != "1" ]; then
    record "hooks.events" "hooks" "WARN" \
      "hooks key absent in settings.json" \
      "/setup orchestration"
    return 0
  fi

  if [ -z "$EXPECTED_HOOK_EVENTS" ]; then
    record "hooks.events" "hooks" "WARN" \
      "could not parse expected hooks from init-orchestration" \
      "Ensure skills/init-orchestration/SKILL.md is present in the plugin install"
    return 0
  fi

  local present missing="" ev
  present=$(list_settings_hook_events)
  for ev in $EXPECTED_HOOK_EVENTS; do
    local found=0 p
    for p in $present; do
      if [ "$p" = "$ev" ]; then found=1; break; fi
    done
    if [ "$found" -eq 0 ]; then
      missing="${missing:+$missing }$ev"
    fi
  done

  if [ -n "$missing" ]; then
    record "hooks.events" "hooks" "FAIL" \
      "missing hook event(s): $missing" \
      "/setup orchestration"
  else
    record "hooks.events" "hooks" "PASS" \
      "all expected hook events present ($(echo "$EXPECTED_HOOK_EVENTS" | wc -w | tr -d ' '))" ""
  fi
}

check_hooks_hygiene() {
  if [ ! -f "$SETTINGS" ]; then
    record "hooks.hygiene" "hooks" "SKIP" "settings.json absent" ""
    return 0
  fi
  if ! settings_json_valid; then
    record "hooks.hygiene" "hooks" "SKIP" "settings.json unparseable" ""
    return 0
  fi

  local cmds unanchored="" piped="" missing_script="" nonexec=""
  cmds=$(extract_hook_commands)
  if [ -z "$cmds" ]; then
    record "hooks.hygiene" "hooks" "PASS" "no hook commands to scan" ""
    return 0
  fi

  local cmd path base
  while IFS= read -r cmd || [ -n "$cmd" ]; do
    [ -n "$cmd" ] || continue
    # Pipe operator hygiene
    case "$cmd" in
      *\|*) piped="${piped:+$piped; }$cmd" ;;
    esac
    # Anchoring
    case "$cmd" in
      *'${CLAUDE_PROJECT_DIR}'*|*"\$CLAUDE_PROJECT_DIR"*|*"\${CLAUDE_PROJECT_DIR}"*)
        ;;
      *)
        unanchored="${unanchored:+$unanchored; }$cmd"
        ;;
    esac
    # Script existence: extract .claude/hooks/foo.sh
    base=$(printf '%s' "$cmd" | grep -oE '\.claude/hooks/[a-zA-Z0-9_.-]+\.sh' | head -1 || true)
    if [ -n "$base" ]; then
      path="$MROOT/$base"
      if [ ! -f "$path" ]; then
        missing_script="${missing_script:+$missing_script }$base"
      elif [ ! -x "$path" ]; then
        nonexec="${nonexec:+$nonexec }$base"
      fi
    fi
  done <<< "$cmds"

  # Severity: missing script = FAIL; unanchored/pipe = WARN; nonexec = FAIL (can't run)
  if [ -n "$missing_script" ]; then
    record "hooks.hygiene" "hooks" "FAIL" \
      "hook script(s) missing: $missing_script" \
      "/setup orchestration"
    return 0
  fi
  if [ -n "$nonexec" ]; then
    record "hooks.hygiene" "hooks" "FAIL" \
      "hook script(s) not executable: $nonexec" \
      "chmod +x $nonexec (or re-run /setup orchestration)"
    return 0
  fi
  if [ -n "$piped" ]; then
    record "hooks.hygiene" "hooks" "WARN" \
      "hook command(s) contain pipe '|': $piped" \
      "Remove pipes from hook commands (sandbox-poisoning); re-run /setup orchestration"
    return 0
  fi
  if [ -n "$unanchored" ]; then
    record "hooks.hygiene" "hooks" "WARN" \
      "hook command(s) not \${CLAUDE_PROJECT_DIR}-anchored" \
      "/setup orchestration (rewrites worktree-unsafe paths)"
    return 0
  fi
  record "hooks.hygiene" "hooks" "PASS" "hook commands anchored, no pipes, scripts present+exec" ""
}

check_hooks_templates_dev() {
  # Dev-checkout only: template-internal hygiene (CDT-54 dual-copy retired).
  # Does NOT require package-tracked live .claude/hooks/*.sh.
  local is_dev=0
  if [ -f "$MROOT/skills/init-orchestration/SKILL.md" ] \
     && [ -f "$MROOT/.claude-plugin/plugin.json" ]; then
    is_dev=1
  fi
  if [ "$is_dev" -eq 0 ]; then
    record "hooks.templates" "hooks" "SKIP" "consumer install — template hygiene check omitted" ""
    return 0
  fi
  if [ ! -f "$CHECK_HOOK_TEMPLATES" ]; then
    record "hooks.templates" "hooks" "SKIP" "check-hook-templates.sh not found" ""
    return 0
  fi
  local rc=0
  set +e
  bash "$CHECK_HOOK_TEMPLATES" >/dev/null 2>&1
  rc=$?
  set -e
  if [ "$rc" -eq 0 ]; then
    record "hooks.templates" "hooks" "PASS" "init-orch hook templates extractable + bash -n clean" ""
  else
    record "hooks.templates" "hooks" "WARN" \
      "hook template hygiene failed (extract/shebang/bash -n)" \
      "Fix fenced templates in skills/init-orchestration/SKILL.md (check-hook-templates.sh)"
  fi
}

check_settings_json() {
  if [ ! -f "$SETTINGS" ]; then
    record "settings.json" "settings" "WARN" \
      "settings.json absent" \
      "/setup orchestration"
    return 0
  fi
  if settings_json_valid; then
    record "settings.json" "settings" "PASS" "settings.json is valid JSON" ""
  else
    record "settings.json" "settings" "FAIL" \
      "settings.json is not valid JSON" \
      "Fix JSON syntax in .claude/settings.json"
  fi
}

check_settings_agent_teams() {
  if [ ! -f "$MEMDB" ]; then
    record "settings.agent_teams" "settings" "SKIP" \
      "memory not initialized — agent_teams env not required yet" ""
    return 0
  fi
  if [ ! -f "$SETTINGS" ]; then
    record "settings.agent_teams" "settings" "WARN" \
      "memory.db exists but settings.json absent (no CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS)" \
      "/setup orchestration"
    return 0
  fi
  if ! settings_json_valid; then
    record "settings.agent_teams" "settings" "SKIP" "settings.json unparseable" ""
    return 0
  fi
  local val
  val=$(settings_get 'print((d.get("env") or {}).get("CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS",""))')
  if [ -n "$val" ]; then
    record "settings.agent_teams" "settings" "PASS" \
      "CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=$val" ""
  else
    record "settings.agent_teams" "settings" "WARN" \
      "CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS absent while memory.db exists" \
      "/setup orchestration"
  fi
}

check_settings_sandbox_coherence() {
  if [ ! -f "$SETTINGS" ]; then
    record "settings.sandbox_coherence" "settings" "SKIP" "settings.json absent" ""
    return 0
  fi
  if ! settings_json_valid; then
    record "settings.sandbox_coherence" "settings" "SKIP" "settings.json unparseable" ""
    return 0
  fi
  local mode sandbox_enabled
  mode=$(settings_get 'print((d.get("permissions") or {}).get("defaultMode",""))')
  sandbox_enabled=$(settings_get '
sb=d.get("sandbox")
if sb is None:
  print("absent")
elif isinstance(sb, dict):
  print("true" if sb.get("enabled") else "false")
else:
  print("absent")
')
  # High-autonomy modes without OS sandbox lose the containment boundary
  # (AGENTS.md: "sandbox is the boundary"). bypassPermissions = unbounded;
  # dontAsk + Bash(*) (shipped Cell C) still auto-runs allowlisted tools.
  if [ "$sandbox_enabled" != "true" ]; then
    case "$mode" in
      bypassPermissions)
        record "settings.sandbox_coherence" "settings" "WARN" \
          "defaultMode=bypassPermissions with sandbox disabled/absent (blast radius unbounded)" \
          "Enable sandbox via /setup orchestration or drop bypassPermissions"
        return 0
        ;;
      dontAsk)
        record "settings.sandbox_coherence" "settings" "WARN" \
          "defaultMode=dontAsk with sandbox disabled/absent (allowlisted tools run without OS boundary)" \
          "Enable sandbox via /setup orchestration (shipped Cell C posture requires sandbox)"
        return 0
        ;;
    esac
  fi
  record "settings.sandbox_coherence" "settings" "PASS" \
    "defaultMode=${mode:-unset} sandbox.enabled=${sandbox_enabled}" ""
}

_dep_check() {
  local id="$1" bin="$2" impact="$3"
  if have_cmd "$bin"; then
    record "$id" "deps" "PASS" "$bin present" ""
  else
    record "$id" "deps" "WARN" "$bin absent — $impact" \
      "Install $bin (system package manager)"
  fi
}

check_deps_jq() {
  _dep_check "deps.jq" "jq" "JSON metrics/council gates degrade or fail-open"
}
check_deps_python3() {
  _dep_check "deps.python3" "python3" "skill-lint, handoff prepass, docs-drift unavailable"
}
check_deps_gh() {
  _dep_check "deps.gh" "gh" "ci-watch / gh-backed release steps unavailable"
}

check_worktree_locks() {
  local base="$MROOT/.worktrees"
  local stale_list="" orphan_lock="" orphan_wt=""
  local ttl="${WT_LOCK_TTL_SECONDS:-21600}"
  [[ "$ttl" =~ ^[0-9]+$ ]] || ttl=21600

  if [ ! -d "$base" ]; then
    record "worktree.locks" "worktree" "PASS" "no .worktrees/ directory" ""
    return 0
  fi

  # Prefer worktree-lib status for authoritative STALE/FRESH
  local status_out=""
  if [ -f "$WT_LIB" ]; then
    set +e
    status_out=$(cd "$MROOT" && WT_LOCK_TTL_SECONDS="$ttl" bash "$WT_LIB" status 2>/dev/null)
    set -e
  fi

  local line slug state
  if [ -n "$status_out" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
      [ -n "$line" ] || continue
      # slug | branch | FRESH|STALE|NONE | age | HEAD
      slug=$(printf '%s' "$line" | awk -F' \\| ' '{print $1}')
      state=$(printf '%s' "$line" | awk -F' \\| ' '{print $3}')
      case "$state" in
        STALE) stale_list="${stale_list:+$stale_list }$slug" ;;
      esac
    done <<< "$status_out"
  else
    # Fallback: same TTL math as worktree-lib (SPEC-016)
    local d lock epoch now age
    now=$(date +%s)
    for d in "$base"/*; do
      [ -d "$d" ] || continue
      slug=$(basename "$d")
      lock="$d/.wt-lock"
      [ -f "$lock" ] || continue
      epoch=$(awk '{print $1}' "$lock" 2>/dev/null || true)
      if [[ "$epoch" =~ ^[0-9]+$ ]]; then
        age=$(( now - epoch ))
        if [ "$age" -ge "$ttl" ]; then
          stale_list="${stale_list:+$stale_list }$slug"
        fi
      else
        stale_list="${stale_list:+$stale_list }$slug"
      fi
    done
  fi

  # Orphan: lock without registered git worktree; worktree dir without lock
  local git_wts=""
  git_wts=$(git -C "$MROOT" worktree list --porcelain 2>/dev/null \
    | awk '/^worktree /{print $2}' || true)

  local d lock
  for d in "$base"/*; do
    [ -d "$d" ] || continue
    slug=$(basename "$d")
    lock="$d/.wt-lock"
    if [ -f "$lock" ]; then
      # Is this path a registered git worktree?
      local reg=0 wt
      for wt in $git_wts; do
        if [ "$wt" = "$d" ]; then reg=1; break; fi
      done
      if [ "$reg" -eq 0 ]; then
        # Bare fixture dirs are not git worktrees — warn as orphan lock only if
        # the dir looks like a real worktree (.git present) OR we only have lock
        if [ -e "$d/.git" ]; then
          orphan_lock="${orphan_lock:+$orphan_lock }$slug"
        fi
      fi
    else
      if [ -e "$d/.git" ]; then
        orphan_wt="${orphan_wt:+$orphan_wt }$slug"
      fi
    fi
  done

  local problems=""
  [ -n "$stale_list" ] && problems="${problems:+$problems; }stale lock(s): $stale_list"
  [ -n "$orphan_lock" ] && problems="${problems:+$problems; }lock without git worktree: $orphan_lock"
  [ -n "$orphan_wt" ] && problems="${problems:+$problems; }git worktree without lock: $orphan_wt"

  if [ -n "$problems" ]; then
    record "worktree.locks" "worktree" "WARN" "$problems" \
      "bash skills/worktree-lib.sh release <slug> (or doctor --fix for STALE .wt-lock only)"
  else
    record "worktree.locks" "worktree" "PASS" \
      "worktree locks ok (TTL=${ttl}s)" ""
  fi
}

check_worktree_distill_lock() {
  if ! have_cmd sqlite3; then
    record "worktree.distill_lock" "worktree" "SKIP" "sqlite3 absent" ""
    return 0
  fi
  if [ ! -f "$MEMDB" ]; then
    record "worktree.distill_lock" "worktree" "SKIP" "memory.db absent" ""
    return 0
  fi
  local holder
  holder=$(sqlite3 -cmd ".timeout 5000" "$MEMDB" \
    "SELECT value FROM config WHERE key='distilling_lock';" 2>/dev/null || true)
  if [ -n "$holder" ]; then
    record "worktree.distill_lock" "worktree" "WARN" \
      "distilling_lock held by '$holder'" \
      "/memory distill --force  (or doctor --fix)"
  else
    record "worktree.distill_lock" "worktree" "PASS" "distilling_lock clear" ""
  fi
}

# ---------------------------------------------------------------------------
# Register all checks
# ---------------------------------------------------------------------------
register_check "version.triplet" "version" check_version_triplet
register_check "plugin.resolve" "plugin" check_plugin_resolve
register_check "memory.sqlite3" "memory" check_memory_sqlite3
register_check "memory.db" "memory" check_memory_db
register_check "memory.schema" "memory" check_memory_schema
register_check "memory.ext.vec" "memory" check_memory_ext_vec
register_check "memory.ext.lembed" "memory" check_memory_ext_lembed
register_check "memory.embedding_config" "memory" check_memory_embedding_config
register_check "hooks.events" "hooks" check_hooks_events
register_check "hooks.hygiene" "hooks" check_hooks_hygiene
register_check "hooks.templates" "hooks" check_hooks_templates_dev
register_check "settings.json" "settings" check_settings_json
register_check "settings.agent_teams" "settings" check_settings_agent_teams
register_check "settings.sandbox_coherence" "settings" check_settings_sandbox_coherence
register_check "deps.jq" "deps" check_deps_jq
register_check "deps.python3" "deps" check_deps_python3
register_check "deps.gh" "deps" check_deps_gh
register_check "worktree.locks" "worktree" check_worktree_locks
register_check "worktree.distill_lock" "worktree" check_worktree_distill_lock

# ---------------------------------------------------------------------------
# --only filter validation
# ---------------------------------------------------------------------------
should_run() {
  local id="$1" group="$2"
  [ -z "$ONLY_FILTER" ] && return 0
  [ "$ONLY_FILTER" = "$id" ] && return 0
  [ "$ONLY_FILTER" = "$group" ] && return 0
  return 1
}

if [ -n "$ONLY_FILTER" ]; then
  known=0
  i=0
  while [ $i -lt ${#REG_IDS[@]} ]; do
    if [ "$ONLY_FILTER" = "${REG_IDS[$i]}" ] || [ "$ONLY_FILTER" = "${REG_GROUPS[$i]}" ]; then
      known=1
      break
    fi
    i=$((i + 1))
  done
  if [ "$known" -eq 0 ]; then
    echo "doctor: unknown check id or group: $ONLY_FILTER" >&2
    echo "Known groups: version memory hooks settings deps worktree plugin" >&2
    echo "Known ids: ${REG_IDS[*]}" >&2
    exit 64
  fi
fi

# ---------------------------------------------------------------------------
# --fix allowlist (before checks so subsequent run reflects repairs)
# ---------------------------------------------------------------------------
fix_confirm() {
  local msg="$1"
  echo "doctor --fix: $msg" >&2
  if [ -t 0 ]; then
    printf 'Apply? [y/N] ' >&2
    local ans
    read -r ans || ans=""
    case "$ans" in
      y|Y|yes|YES) return 0 ;;
      *) echo "doctor --fix: skipped" >&2; return 1 ;;
    esac
  fi
  return 0
}

do_fix() {
  # 1) clear distilling_lock
  if have_cmd sqlite3 && [ -f "$MEMDB" ]; then
    local holder
    holder=$(sqlite3 -cmd ".timeout 5000" "$MEMDB" \
      "SELECT value FROM config WHERE key='distilling_lock';" 2>/dev/null || true)
    if [ -n "$holder" ]; then
      if fix_confirm "clear distilling_lock (held by '$holder') → ''"; then
        sqlite3 -cmd ".timeout 5000" "$MEMDB" \
          "PRAGMA busy_timeout=5000; UPDATE config SET value='' WHERE key='distilling_lock';" 2>/dev/null || true
        echo "doctor --fix: distilling_lock cleared" >&2
      fi
    fi
  fi

  # 2) remove STALE .wt-lock files only
  local base="$MROOT/.worktrees"
  local ttl="${WT_LOCK_TTL_SECONDS:-21600}"
  [[ "$ttl" =~ ^[0-9]+$ ]] || ttl=21600
  if [ -d "$base" ]; then
    local d lock epoch now age slug
    now=$(date +%s)
    for d in "$base"/*; do
      [ -d "$d" ] || continue
      lock="$d/.wt-lock"
      [ -f "$lock" ] || continue
      slug=$(basename "$d")
      epoch=$(awk '{print $1}' "$lock" 2>/dev/null || true)
      local is_stale=0
      if [[ "$epoch" =~ ^[0-9]+$ ]]; then
        age=$(( now - epoch ))
        if [ "$age" -ge "$ttl" ]; then is_stale=1; fi
      else
        is_stale=1
      fi
      if [ "$is_stale" -eq 1 ]; then
        if fix_confirm "remove STALE .wt-lock for $slug (age>=${ttl}s)"; then
          rm -f "$lock"
          echo "doctor --fix: removed $lock" >&2
        fi
      fi
    done
  fi

  # 3) sweep handoff cache *.tmp
  local hdir="$MROOT/.claude/handoff/cache"
  if [ -d "$hdir" ]; then
    local f count=0
    for f in "$hdir"/*.tmp; do
      [ -f "$f" ] || continue
      count=$((count + 1))
    done
    if [ "$count" -gt 0 ]; then
      if fix_confirm "sweep $count orphaned *.tmp under .claude/handoff/cache/"; then
        rm -f "$hdir"/*.tmp
        echo "doctor --fix: swept $count *.tmp" >&2
      fi
    fi
  fi
}

if [ "$FIX_MODE" -eq 1 ]; then
  do_fix
fi

# ---------------------------------------------------------------------------
# Run
# ---------------------------------------------------------------------------
i=0
while [ $i -lt ${#REG_IDS[@]} ]; do
  if should_run "${REG_IDS[$i]}" "${REG_GROUPS[$i]}"; then
    "${REG_FNS[$i]}"
  fi
  i=$((i + 1))
done

# ---------------------------------------------------------------------------
# Summarize
# ---------------------------------------------------------------------------
N_PASS=0 N_WARN=0 N_FAIL=0 N_SKIP=0
i=0
while [ $i -lt ${#CHECK_IDS[@]} ]; do
  case "${CHECK_STATUSES[$i]}" in
    PASS) N_PASS=$((N_PASS + 1)) ;;
    WARN) N_WARN=$((N_WARN + 1)) ;;
    FAIL) N_FAIL=$((N_FAIL + 1)) ;;
    SKIP) N_SKIP=$((N_SKIP + 1)) ;;
  esac
  i=$((i + 1))
done

EXIT_CODE=0
if [ "$N_FAIL" -gt 0 ]; then
  EXIT_CODE=2
elif [ "$N_WARN" -gt 0 ]; then
  EXIT_CODE=1
fi

# ---------------------------------------------------------------------------
# Render
# ---------------------------------------------------------------------------
render_human() {
  echo "dev-team doctor  plugin=${PLUGIN_VERSION:-unknown}  tier=${RESOLVED_TIER}  mroot=$MROOT"
  echo "----------------------------------------------------------------"
  local i=0
  while [ $i -lt ${#CHECK_IDS[@]} ]; do
    printf '%-4s | %s | %s\n' \
      "${CHECK_STATUSES[$i]}" "${CHECK_IDS[$i]}" "${CHECK_DETAILS[$i]}"
    if [ "${CHECK_STATUSES[$i]}" = "WARN" ] || [ "${CHECK_STATUSES[$i]}" = "FAIL" ]; then
      if [ -n "${CHECK_FIXITS[$i]}" ]; then
        printf '       fix-it: %s\n' "${CHECK_FIXITS[$i]}"
      fi
    fi
    i=$((i + 1))
  done
  echo "----------------------------------------------------------------"
  printf '%d pass / %d warn / %d fail / %d skip\n' "$N_PASS" "$N_WARN" "$N_FAIL" "$N_SKIP"
}

render_json() {
  # Pure-bash JSON for AC18 (no jq required)
  local i first=1
  printf '{'
  printf '"doctor_schema":"%s",' "$(json_escape "$DOCTOR_SCHEMA")"
  printf '"plugin_version":"%s",' "$(json_escape "${PLUGIN_VERSION:-}")"
  printf '"resolved_tier":"%s",' "$(json_escape "$RESOLVED_TIER")"
  printf '"checks":['
  i=0
  while [ $i -lt ${#CHECK_IDS[@]} ]; do
    [ "$first" -eq 1 ] || printf ','
    first=0
    printf '{'
    printf '"id":"%s",' "$(json_escape "${CHECK_IDS[$i]}")"
    printf '"group":"%s",' "$(json_escape "${CHECK_GROUPS[$i]}")"
    printf '"status":"%s",' "$(json_escape "${CHECK_STATUSES[$i]}")"
    printf '"detail":"%s",' "$(json_escape "${CHECK_DETAILS[$i]}")"
    if [ "${CHECK_STATUSES[$i]}" = "PASS" ] || [ "${CHECK_STATUSES[$i]}" = "SKIP" ]; then
      # fixit null on PASS; SKIP also null
      if [ -z "${CHECK_FIXITS[$i]}" ]; then
        printf '"fixit":null'
      else
        printf '"fixit":"%s"' "$(json_escape "${CHECK_FIXITS[$i]}")"
      fi
    else
      if [ -z "${CHECK_FIXITS[$i]}" ]; then
        printf '"fixit":null'
      else
        printf '"fixit":"%s"' "$(json_escape "${CHECK_FIXITS[$i]}")"
      fi
    fi
    printf '}'
    i=$((i + 1))
  done
  printf '],'
  printf '"summary":{"pass":%d,"warn":%d,"fail":%d,"skip":%d}' \
    "$N_PASS" "$N_WARN" "$N_FAIL" "$N_SKIP"
  printf '}\n'
}

if [ "$JSON_MODE" -eq 1 ]; then
  render_json
else
  render_human
fi

exit "$EXIT_CODE"
