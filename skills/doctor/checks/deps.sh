# deps.sh — sourced by doctor.sh (rv-w3-39 doctor split); pure definitions, no top-level side effects.
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
  _dep_check "deps.python3" "python3" \
    "skill-lint, handoff prepass, docs-drift unavailable; transcript.mirror_lag SKIP"
}
check_deps_gh() {
  _dep_check "deps.gh" "gh" "ci-watch / gh-backed release steps unavailable"
}

# CDT-287 — tool prerequisites beyond tool presence: bash version, lock
# support, ripgrep, timeout. Presence checks live in _dep_check; these add
# version/fallback semantics because skills run under this bash and lock /
# bound subprocesses through skills/lib/portable.sh (CDT-284).
check_deps_bash() {
  # Test knob (same pattern as MATRIX_CC_VERSION_FILE): raise the floor to
  # prove the comparison is live.
  local min_major="${DOCTOR_MIN_BASH_MAJOR:-3}" min_minor="${DOCTOR_MIN_BASH_MINOR:-2}"
  local ver="${BASH_VERSION:-}" maj rest min
  if [ -z "$ver" ]; then
    record "deps.bash" "deps" "SKIP" "BASH_VERSION unset — cannot check bash version" ""
    return 0
  fi
  maj=${ver%%.*}
  rest=${ver#*.}
  min=${rest%%.*}
  case "$maj" in
    ''|*[!0-9]*)
      record "deps.bash" "deps" "SKIP" "unparseable BASH_VERSION=$ver" ""
      return 0
      ;;
  esac
  case "$min" in ''|*[!0-9]*) min=0 ;; esac
  case "$min_major" in ''|*[!0-9]*) min_major=3 ;; esac
  case "$min_minor" in ''|*[!0-9]*) min_minor=2 ;; esac
  if [ "$maj" -gt "$min_major" ] \
    || { [ "$maj" -eq "$min_major" ] && [ "$min" -ge "$min_minor" ]; }; then
    record "deps.bash" "deps" "PASS" "bash $ver >= $min_major.$min_minor" ""
  else
    record "deps.bash" "deps" "WARN" \
      "bash $ver < $min_major.$min_minor — skills assume bash 3.2+ (indexed arrays only, no declare -A/mapfile)" \
      "Install bash >= $min_major.$min_minor (system package manager)"
  fi
}

check_deps_flock() {
  if have_cmd flock; then
    record "deps.flock" "deps" "PASS" "flock present" ""
    return 0
  fi
  if [ -f "$PLUGIN_ROOT/skills/lib/portable.sh" ]; then
    record "deps.flock" "deps" "PASS" \
      "flock absent — skills/lib/portable.sh mkdir lock covers lock support (CDT-284)" ""
    return 0
  fi
  record "deps.flock" "deps" "WARN" \
    "no flock and no skills/lib/portable.sh — state RMW lock support unavailable" \
    "Reinstall the dev-team plugin (skills/lib/portable.sh ships the mkdir lock)"
}

check_deps_rg() {
  if have_cmd rg; then
    record "deps.rg" "deps" "PASS" "rg present" ""
  else
    record "deps.rg" "deps" "WARN" \
      "rg absent — scan/probe surfaces degrade to grep or skip (tools/permission-matrix-probe.sh, ci-watch)" \
      "Install ripgrep (system package manager)"
  fi
}

check_deps_timeout() {
  if have_cmd timeout || have_cmd gtimeout; then
    record "deps.timeout" "deps" "PASS" "timeout present" ""
    return 0
  fi
  if have_cmd perl && [ -f "$PLUGIN_ROOT/skills/lib/portable.sh" ]; then
    record "deps.timeout" "deps" "PASS" \
      "no timeout/gtimeout — portable_with_timeout perl supervisor covers timeouts (CDT-284)" ""
    return 0
  fi
  record "deps.timeout" "deps" "WARN" \
    "no timeout/gtimeout and no portable perl fallback — hung subprocesses cannot be bounded" \
    "Install coreutils (gtimeout) or perl, or reinstall the plugin (skills/lib/portable.sh)"
}

