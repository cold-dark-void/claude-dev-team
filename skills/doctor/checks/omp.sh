# omp.sh — omp (oh-my-pi) host checks (CDT-551). Sourced by doctor.sh;
# pure definitions, no top-level side effects. Print-only: never writes omp
# config or any host state. Test hooks (env): OMP_BIN ("none"/"present" or a
# binary path), OMP_CONFIG_FILE, OMP_MARKETPLACE_DIR, OMP_CACHE_DIR.

omp_present() {
  # OMP_BIN=none → omp-less host; OMP_BIN=present → deterministic omp host
  # (tests); empty → probe PATH.
  local bin="${OMP_BIN:-}"
  if [ "$bin" = "none" ]; then return 1; fi
  if [ "$bin" = "present" ]; then return 0; fi
  if [ -n "$bin" ]; then [ -x "$bin" ]; return $?; fi
  have_cmd omp
}

omp_config_file() { printf '%s' "${OMP_CONFIG_FILE:-$HOME/.omp/agent/config.yml}"; }

omp_providers_has_claude_plugins() {
  # Read omp YAML config: rc 0 when enabledProviders lists claude-plugins
  # (inline `enabledProviders: ["…"]` or block `- claude-plugins` form).
  awk '
    /^[[:space:]]*enabledProviders:/ {
      inline = $0
      sub(/^[^:]*:[[:space:]]*/, "", inline)
      if (index(inline, "claude-plugins")) { found = 1; exit }
      block = 1; next
    }
    block && /^[[:space:]]*-/ {
      if (index($0, "claude-plugins")) { found = 1; exit }
      next
    }
    block && /^[[:space:]]*[^-[:space:]#]/ { block = 0 }
    END { exit found ? 0 : 1 }
  ' "$1"
}

check_omp_enabled_providers() {
  if ! omp_present; then
    record "omp.enabled_providers" "omp" "SKIP" \
      "omp CLI absent — not an omp host; provider check not applicable" ""
    return 0
  fi
  local cfg
  cfg=$(omp_config_file)
  if [ ! -f "$cfg" ]; then
    record "omp.enabled_providers" "omp" "WARN" \
      "omp present but no config at $cfg — enabledProviders unset, plugin skills silently fail to load (Unknown skill)" \
      "omp config set enabledProviders '[\"claude-plugins\"]'"
    return 0
  fi
  if omp_providers_has_claude_plugins "$cfg"; then
    record "omp.enabled_providers" "omp" "PASS" \
      "omp enabledProviders includes claude-plugins ($cfg)" ""
  else
    record "omp.enabled_providers" "omp" "WARN" \
      "omp config at $cfg does not enable claude-plugins — plugin skills silently fail to load (Unknown skill)" \
      "omp config set enabledProviders '[\"claude-plugins\"]'"
  fi
}

omp_marketplace_plugin_json() {
  # Newest dev-team(-edge) marketplace clone under $1; prints its
  # .claude-plugin/plugin.json path, empty when absent.
  local root="$1" dir name
  [ -d "$root" ] || return 1
  for dir in "$root"/*/; do
    [ -f "${dir}.claude-plugin/plugin.json" ] || continue
    name=$(grep -oE '"name"[[:space:]]*:[[:space:]]*"[^"]+"' "${dir}.claude-plugin/plugin.json" | head -1 || true)
    case "$name" in
      *dev-team*) printf '%s' "${dir}.claude-plugin/plugin.json"; return 0 ;;
    esac
  done
  return 1
}

omp_max_cache_version() {
  # Highest dev-team(-edge) version dir under $1 (cache/<…>/dev-team*/<VER>/).
  local root="$1" dd vd v best=""
  [ -d "$root" ] || { printf ''; return 0; }
  for dd in "$root"/*/dev-team*/; do
    [ -d "$dd" ] || continue
    for vd in "$dd"*/; do
      [ -d "$vd" ] || continue
      v=$(basename "$vd")
      if [ -z "$best" ] || [ "$v" != "$(printf '%s\n%s\n' "$v" "$best" | sort -V | head -1)" ]; then
        best=$v
      fi
    done
  done
  printf '%s' "$best"
}

check_omp_marketplace() {
  if ! omp_present; then
    record "omp.marketplace" "omp" "SKIP" \
      "omp CLI absent — not an omp host; marketplace freshness check not applicable" ""
    return 0
  fi
  local mp_dir cache_dir mp_json mp_ver cache_ver
  mp_dir="${OMP_MARKETPLACE_DIR:-$HOME/.claude/plugins/marketplaces}"
  cache_dir="${OMP_CACHE_DIR:-$HOME/.claude/plugins/cache}"
  if ! mp_json=$(omp_marketplace_plugin_json "$mp_dir"); then
    record "omp.marketplace" "omp" "SKIP" \
      "no dev-team marketplace clone under $mp_dir — omp loads the plugin from an install cache; nothing to go stale" ""
    return 0
  fi
  mp_ver=$(parse_plugin_json_version "$mp_json")
  if [ -z "$mp_ver" ] || [ "$mp_ver" = "__PARSE_ERROR__" ]; then
    record "omp.marketplace" "omp" "WARN" \
      "marketplace copy at $(dirname "$(dirname "$mp_json")") has an unparseable plugin version — omp may load a broken copy" \
      "Update the dev-team marketplace clone"
    return 0
  fi
  cache_ver=$(omp_max_cache_version "$cache_dir")
  if [ -z "$cache_ver" ]; then
    record "omp.marketplace" "omp" "PASS" \
      "marketplace copy v$mp_ver; no install-cache copies found to compare ($cache_dir)" ""
    return 0
  fi
  if [ "$mp_ver" = "$cache_ver" ]; then
    record "omp.marketplace" "omp" "PASS" \
      "marketplace copy v$mp_ver matches the newest install-cache copy" ""
  elif [ "$mp_ver" = "$(printf '%s\n%s\n' "$mp_ver" "$cache_ver" | sort -V | head -1)" ]; then
    record "omp.marketplace" "omp" "WARN" \
      "stale omp marketplace copy at $(dirname "$(dirname "$mp_json")") (v$mp_ver) vs newest install-cache copy (v$cache_ver) — omp loads the older clone" \
      "Update the dev-team marketplace clone"
  else
    record "omp.marketplace" "omp" "PASS" \
      "marketplace copy v$mp_ver is newer than cache v$cache_ver" ""
  fi
}
