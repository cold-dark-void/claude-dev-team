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

# Worktree root for cwd-scoped probes (SPEC-022 M2h --cwd).
resolve_wtroot() {
  local _tl
  if _tl=$(git rev-parse --show-toplevel 2>/dev/null); then
    WTROOT=$_tl
  else
    WTROOT=$(pwd)
  fi
}

resolve_mroot
resolve_wtroot
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
# Indexed arrays (bash 3.2+).
CHECK_IDS=()
CHECK_GROUPS=()
CHECK_STATUSES=()
CHECK_DETAILS=()
CHECK_FIXITS=()
CHECK_GATE_WAIVED=()  # parallel: 0|1 when --gate set and FAIL self-remediating

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
  CHECK_GATE_WAIVED+=(0)
}

# Trim leading/trailing whitespace (exact-match gate waive — M6c)
trim_ws() {
  local s=${1-}
  # leading
  s="${s#"${s%%[![:space:]]*}"}"
  # trailing
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

# Exact fixit match for active gate command (no substring/contains)
fixit_matches_gate() {
  local fixit="$1" gate_cmd="$2"
  [ -n "$gate_cmd" ] || return 1
  local t
  t=$(trim_ws "$fixit")
  [ "$t" = "$gate_cmd" ]
}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
json_escape() {
  # Escape a string for a JSON double-quoted value (pure bash).
  # Every C0 control becomes \n, \r, \t, or \u00XX.
  local s=${1-} out="" c hex
  s=${s//\\/\\\\}
  s=${s//\"/\\\"}
  while [ -n "$s" ]; do
    c=${s%"${s#?}"}
    s=${s#?}
    case "$c" in
      $'\n') out="${out}\\n" ;;
      $'\r') out="${out}\\r" ;;
      $'\t') out="${out}\\t" ;;
      [[:cntrl:]])
        hex=$(printf '%02x' "'$c")
        out="${out}\\u00${hex}"
        ;;
      *) out="${out}${c}" ;;
    esac
  done
  printf '%s' "$out"
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
    */.claude/plugins/marketplaces/*) printf 'marketplace' ;;
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
  */.claude/plugins/marketplaces/*) RESOLVED_TIER=marketplace ;;
esac

