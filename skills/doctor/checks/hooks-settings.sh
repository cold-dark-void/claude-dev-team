# hooks-settings.sh — sourced by doctor.sh (rv-w3-39 doctor split); pure definitions, no top-level side effects.
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
    # Managed-only (CDT-77 / M2c″): skip user-owned pathless/custom hooks
    is_managed_hook_cmd "$cmd" || continue
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

  # Multi-event registration can list the same path N times — unique before record (CDT-70)
  # Intentional word-split: tokens are space-joined relative paths (no spaces in paths).
  if [ -n "$missing_script" ]; then
    # shellcheck disable=SC2086
    missing_script=$(printf '%s\n' $missing_script | sort -u | tr '\n' ' ')
    missing_script=${missing_script% }
  fi
  if [ -n "$nonexec" ]; then
    # shellcheck disable=SC2086
    nonexec=$(printf '%s\n' $nonexec | sort -u | tr '\n' ' ')
    nonexec=${nonexec% }
  fi

  # Severity: missing script = FAIL; nonexec = WARN (bash runs the script); pipe/unanchored = WARN
  if [ -n "$missing_script" ]; then
    record "hooks.hygiene" "hooks" "FAIL" \
      "hook script(s) missing: $missing_script" \
      "/setup orchestration"
    return 0
  fi
  if [ -n "$nonexec" ]; then
    # Hooks run as `bash <script>`, so a missing exec bit is not a hard fail.
    record "hooks.hygiene" "hooks" "WARN" \
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
  record "hooks.hygiene" "hooks" "PASS" "hook commands anchored, no pipes, scripts present" ""
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
  # dontAsk / auto (Cell C/D) still need the OS boundary for Bash(*).
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
          "Enable sandbox via /setup orchestration (Cell C posture requires sandbox)"
        return 0
        ;;
      auto)
        record "settings.sandbox_coherence" "settings" "WARN" \
          "defaultMode=auto with sandbox disabled/absent (policy evaluation without OS boundary)" \
          "Enable sandbox via /setup orchestration (shipped Cell D / CDT-75 requires sandbox)"
        return 0
        ;;
    esac
  fi
  record "settings.sandbox_coherence" "settings" "PASS" \
    "defaultMode=${mode:-unset} sandbox.enabled=${sandbox_enabled}" ""
}

# CDT-78: functional OS-sandbox runtime probe (WARN never FAIL).
# Config coherence stays in settings.sandbox_coherence; this checks host init.
check_settings_sandbox_runtime() {
  if [ ! -f "$SETTINGS" ]; then
    record "settings.sandbox_runtime" "settings" "SKIP" "settings.json absent" ""
    return 0
  fi
  if ! settings_json_valid; then
    record "settings.sandbox_runtime" "settings" "SKIP" "settings.json unparseable" ""
    return 0
  fi
  local sandbox_enabled mode
  sandbox_enabled=$(settings_get '
sb=d.get("sandbox")
if sb is None:
  print("absent")
elif isinstance(sb, dict):
  print("true" if sb.get("enabled") else "false")
else:
  print("absent")
')
  mode=$(settings_get 'print((d.get("permissions") or {}).get("defaultMode",""))')
  if [ "$sandbox_enabled" != "true" ]; then
    record "settings.sandbox_runtime" "settings" "SKIP" \
      "sandbox.enabled=${sandbox_enabled} — runtime probe skipped" ""
    return 0
  fi

  local result nested=0
  result=$(_doctor_bwrap_probe)
  if _doctor_nested_sandbox_p; then nested=1; else nested=0; fi

  case "$result" in
    unsupported)
      record "settings.sandbox_runtime" "settings" "SKIP" \
        "bwrap probe Linux-only; host=$(uname -s 2>/dev/null || echo unknown)" ""
      return 0
      ;;
    ok)
      record "settings.sandbox_runtime" "settings" "PASS" \
        "bwrap init ok (unshare-user+pid); defaultMode=${mode:-unset}" ""
      return 0
      ;;
  esac

  # WARN paths only below (never FAIL — M3-aligned host capability)
  local high=0 detail fixit
  case "$mode" in bypassPermissions|dontAsk|auto) high=1 ;; esac
  fixit="Install/fix bubblewrap + unprivileged user namespaces; re-run: bash skills/doctor/doctor.sh --only settings.sandbox_runtime (outside nested session if cited)"

  if [ "$result" = "absent" ]; then
    if [ "$high" -eq 1 ]; then
      detail="sandbox.enabled=true but bwrap absent; defaultMode=${mode} — Cell D / high-autonomy containment guarantees do not hold"
    else
      detail="sandbox.enabled=true but bwrap absent; OS sandbox cannot initialize"
    fi
  else
    # fail:* or timeout
    if [ "$high" -eq 1 ]; then
      detail="sandbox.enabled=true but runtime probe failed (${result}); defaultMode=${mode} — Cell D / high-autonomy containment and zero-prompt guarantees do not hold; commands may run unsandboxed or fail init"
    else
      detail="sandbox.enabled=true but runtime probe failed (${result}); OS sandbox may not initialize on this host"
    fi
  fi
  if [ "$nested" -eq 1 ]; then
    detail="${detail}; nested-sandbox caveat: this shell may already be confined — re-run doctor outside the Claude Code session to confirm host health"
  fi
  record "settings.sandbox_runtime" "settings" "WARN" "$detail" "$fixit"
}

# CDT-74 residual: Cell C (dontAsk) without any mcp__* allow entry cannot reach
# Linear-first surfaces. Ship default is Cell D (auto); this WARNs brownfield C.
check_settings_mcp_allow() {
  if [ ! -f "$SETTINGS" ]; then
    record "settings.mcp_allow" "settings" "SKIP" "settings.json absent" ""
    return 0
  fi
  if ! settings_json_valid; then
    record "settings.mcp_allow" "settings" "SKIP" "settings.json unparseable" ""
    return 0
  fi
  local mode has_mcp
  mode=$(settings_get 'print((d.get("permissions") or {}).get("defaultMode",""))')
  has_mcp=$(settings_get '
allow=(d.get("permissions") or {}).get("allow") or []
print("yes" if any(isinstance(x,str) and x.startswith("mcp__") for x in allow) else "no")
')
  if [ "$mode" = "dontAsk" ] && [ "$has_mcp" = "no" ]; then
    record "settings.mcp_allow" "settings" "WARN" \
      "defaultMode=dontAsk with zero mcp__* allow entries — Linear MCP is silent-deny (CDT-74)" \
      "Re-run /setup orchestration to adopt Cell D (auto), or add mcp__<server>__* to permissions.allow"
    return 0
  fi
  record "settings.mcp_allow" "settings" "PASS" \
    "defaultMode=${mode:-unset} mcp_allow=${has_mcp}" ""
}

