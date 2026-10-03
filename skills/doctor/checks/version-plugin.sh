# version-plugin.sh — sourced by doctor.sh (rv-w3-39 doctor split); pure definitions, no top-level side effects.
# ---------------------------------------------------------------------------
# Checks
# ---------------------------------------------------------------------------

# CDT-131: version pair (plugin.json ↔ CHANGELOG). Check id stays
# version.triplet for --only / caller stability; semantics are pair-only.
# marketplace.json is not version-synced (git-ref install channels).
check_version_triplet() {
  local pj="$PLUGIN_ROOT/.claude-plugin/plugin.json"
  local cl="$PLUGIN_ROOT/CHANGELOG.md"
  local v_p v_c

  if [ ! -f "$pj" ]; then
    record "version.triplet" "version" "FAIL" \
      "plugin.json missing at $pj" \
      "Install or update the dev-team plugin"
    return 0
  fi

  v_p=$(parse_plugin_json_version "$pj")
  v_c=$(parse_changelog_version "$cl")

  if [ "$v_p" = "__PARSE_ERROR__" ]; then
    record "version.triplet" "version" "FAIL" \
      "unparseable plugin.json (plugin=$v_p)" \
      "Fix JSON in .claude-plugin/plugin.json"
    return 0
  fi

  if [ -z "$v_p" ] || [ -z "$v_c" ]; then
    record "version.triplet" "version" "FAIL" \
      "version missing: plugin.json='$v_p' CHANGELOG='$v_c'" \
      "Run /release (dev) or update the plugin (consumer)"
    return 0
  fi

  if [ "$v_p" = "$v_c" ]; then
    record "version.triplet" "version" "PASS" \
      "plugin.json=CHANGELOG=$v_p (version pair)" ""
  else
    record "version.triplet" "version" "FAIL" \
      "version drift: plugin.json=$v_p CHANGELOG=$v_c" \
      "Run /release (dev checkout) or update the plugin (consumer)"
  fi
}

# CDT-59 — WARN when installed Claude Code ≠ last matrix-probed version.
# SoT: tools/permission-matrix-cc-version (updated by permission-matrix-probe.sh).
# Override path via MATRIX_CC_VERSION_FILE (tests).
check_matrix_cc_version() {
  local ver_file="${MATRIX_CC_VERSION_FILE:-$PLUGIN_ROOT/tools/permission-matrix-cc-version}"
  local probed raw installed

  if ! have_cmd claude; then
    record "matrix.cc_version" "version" "SKIP" \
      "claude CLI absent — cannot compare to last-probed matrix version" ""
    return 0
  fi

  if [ ! -f "$ver_file" ]; then
    record "matrix.cc_version" "version" "SKIP" \
      "last-probed version file missing ($ver_file)" ""
    return 0
  fi

  probed=$(sed -n '/^[[:space:]]*#/d;/^[[:space:]]*$/d;s/^[[:space:]]*//;s/[[:space:]]*$//;p;q' "$ver_file")
  if [ -z "$probed" ]; then
    record "matrix.cc_version" "version" "WARN" \
      "last-probed CC version file empty — re-run tools/permission-matrix-probe.sh" \
      "bash tools/permission-matrix-probe.sh"
    return 0
  fi

  raw=$(claude --version 2>&1 | head -1 || true)
  installed=$(printf '%s' "$raw" | awk '{print $1}' | tr -d '\r')
  if [ -z "$installed" ]; then
    record "matrix.cc_version" "version" "SKIP" \
      "claude --version unparseable: ${raw:-empty}" ""
    return 0
  fi

  if [ "$installed" = "$probed" ]; then
    record "matrix.cc_version" "version" "PASS" \
      "claude $installed matches last-probed matrix version" ""
  else
    record "matrix.cc_version" "version" "WARN" \
      "permission posture matrix evidence is from CC $probed; you are on $installed — re-run tools/permission-matrix-probe.sh (it rewrites the tracked tools/permission-matrix-cc-version on its next successful run; until then the stale pin stands)" \
      "bash tools/permission-matrix-probe.sh"
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

