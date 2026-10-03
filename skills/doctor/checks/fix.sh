# fix.sh — sourced by doctor.sh (rv-w3-39 doctor split); pure definitions, no top-level side effects.
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

distill_lock_stale() {
  # Value shape from distill-lock.sh: distill-<epoch>-<pid>. Empty and
  # non-numeric tokens are not stale. TTL is the same 1800s literal. That
  # script does not read an env override, so doctor does not either.
  local value="$1" now epoch ttl=1800
  now=$(date +%s)
  case "$value" in
    distill-[0-9]*)
      epoch=${value#distill-}
      epoch=${epoch%%-*}
      case "$epoch" in
        ''|*[!0-9]*) return 1 ;;
      esac
      [ $((now - epoch)) -gt "$ttl" ]
      ;;
    *) return 1 ;;
  esac
}

do_fix() {
  # Each repair runs only when --only selects its check (CDT-407).
  # 1) clear a stale distilling_lock. A fresh lock stays unless --force.
  if should_run "worktree.distill_lock" "worktree" \
     && have_cmd sqlite3 && [ -f "$MEMDB" ]; then
    local holder
    holder=$(sqlite3 -cmd ".timeout 5000" "$MEMDB" \
      "SELECT value FROM config WHERE key='distilling_lock';" 2>/dev/null || true)
    if [ -n "$holder" ]; then
      if [ "$FIX_FORCE" -eq 1 ] || distill_lock_stale "$holder"; then
        if fix_confirm "clear distilling_lock (held by '$holder') → ''"; then
          sqlite3 -cmd ".timeout 5000" "$MEMDB" \
            " UPDATE config SET value='' WHERE key='distilling_lock';" 2>/dev/null || true
          echo "doctor --fix: distilling_lock cleared" >&2
        fi
      else
        echo "doctor --fix: distilling_lock is fresh; left in place" >&2
      fi
    fi
  fi

  # 2) remove STALE .wt-lock files only — worktree-lib gc --stale is the single
  #    TTL implementation (rv-w3-39); doctor confirms, the lib decides staleness.
  if should_run "worktree.locks" "worktree"; then
    if [ -f "$WT_LIB" ]; then
      if fix_confirm "remove STALE .wt-lock files (worktree-lib gc --stale)"; then
        bash "$WT_LIB" gc --stale
      fi
    else
      echo "doctor --fix: worktree-lib.sh unavailable — cannot gc stale locks" >&2
    fi
  fi

  # 3) sweep handoff cache *.tmp (only on a full run or --only handoff.tmp)
  local hdir="$MROOT/.claude/handoff/cache"
  if should_run "handoff.tmp" "handoff" && [ -d "$hdir" ]; then
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

