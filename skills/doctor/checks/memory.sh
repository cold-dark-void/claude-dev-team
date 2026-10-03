# memory.sh — sourced by doctor.sh (rv-w3-39 doctor split); pure definitions, no top-level side effects.
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
  sqlite3 :memory: ".load \"$base\"" "SELECT 1;" >/dev/null 2>&1
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
      local found=0 d suffix bare
      for d in $domains; do
        case "$d" in
          \*.*)
            suffix=${d#\*.}
            suffix=${suffix%%:*}
            case "$host" in
              *."$suffix") found=1; break ;;
            esac
            ;;
          *)
            # Entry may be host or host:port. Compare the entry to this host,
            # then a label boundary on the entry with its port removed.
            bare=${d%%:*}
            case "$d" in
              "$host"|"$host":*) found=1; break ;;
            esac
            case "$host" in
              *."$bare") found=1; break ;;
            esac
            ;;
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

# memory.embed_errors (CDT-262 / SPEC-022 M2j): embed-one.sh and migrate-md.sh append
# one line per failed embed to <MROOT>/.claude/memory/.errors.log as
# "<UTC ts> embed <site> <detail>". Count the lines whose second field is "embed".
# Read-only (M1). WARN, never FAIL (M3): the memory write itself always succeeded.
check_memory_embed_errors() {
  if [ ! -f "$MEMDB" ]; then
    record "memory.embed_errors" "memory" "SKIP" "memory.db absent" ""
    return 0
  fi
  local errlog="$MROOT/.claude/memory/.errors.log" lib="$PLUGIN_ROOT/skills/memory-store/embed-common.sh" n last
  if [ ! -f "$errlog" ]; then
    record "memory.embed_errors" "memory" "PASS" "no embed errors logged" ""
    return 0
  fi
  # The line format lives in embed-common.sh (embed_error_count / embed_error_last).
  if [ ! -f "$lib" ] || ! have_cmd awk; then
    record "memory.embed_errors" "memory" "SKIP" "embed-common.sh or awk absent — cannot count the embed error log" ""
    return 0
  fi
  # shellcheck source=/dev/null
  if ! . "$lib"; then
    record "memory.embed_errors" "memory" "SKIP" "embed-common.sh could not be loaded — cannot count the embed error log" ""
    return 0
  fi
  n=$(embed_error_count "$MROOT/.claude/memory")
  last=$(embed_error_last "$MROOT/.claude/memory")
  case "$n" in
    ""|*[!0-9]*) n=0 ;;
  esac
  if [ "$n" -eq 0 ]; then
    record "memory.embed_errors" "memory" "PASS" "no embed errors logged" ""
  else
    record "memory.embed_errors" "memory" "WARN" \
      "$n embed error(s) in .claude/memory/.errors.log (last: ${last:-unknown}) — some memories have no vector; semantic search may be incomplete" \
      "Read .claude/memory/.errors.log, fix the cause (for example /setup team --refresh), then run: rm .claude/memory/.errors.log"
  fi
}

