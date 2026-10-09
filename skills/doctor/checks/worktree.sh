# worktree.sh — sourced by doctor.sh (rv-w3-39 doctor split); pure definitions, no top-level side effects.
check_worktree_locks() {
  local base="$MROOT/.worktrees"
  local stale_list="" orphan_lock="" orphan_wt=""

  if [ ! -d "$base" ]; then
    record "worktree.locks" "worktree" "PASS" "no .worktrees/ directory" ""
    return 0
  fi

  # FRESH/STALE is decided by worktree-lib `status` — the single TTL
  # implementation (rv-w3-39). Without the lib, staleness is unknowable here;
  # SKIP rather than fork the TTL math a second time.
  if [ ! -f "$WT_LIB" ]; then
    record "worktree.locks" "worktree" "SKIP" \
      "worktree-lib.sh unavailable — lock staleness (TTL) is decided only there" ""
    return 0
  fi

  local slug stale_slugs=""
  if wt_status_has STALE; then
    stale_slugs=$(wt_status_slugs STALE) || true
    while IFS= read -r slug || [ -n "$slug" ]; do
      [ -n "$slug" ] || continue
      stale_list="${stale_list:+$stale_list }$slug"
    done <<< "$stale_slugs"
  fi

  # Orphan: lock without registered git worktree; worktree dir without lock
  local git_wts=""
  git_wts=$(git -C "$MROOT" worktree list --porcelain 2>/dev/null \
    | awk '/^worktree /{sub(/^worktree /,""); print}' || true)

  local d lock
  for d in "$base"/*; do
    [ -d "$d" ] || continue
    slug=$(basename "$d")
    lock="$d/.wt-lock"
    if [ -f "$lock" ]; then
      # Is this path a registered git worktree? Read porcelain line-wise so
      # a path with a space stays one path.
      local reg=0 wt
      while IFS= read -r wt || [ -n "$wt" ]; do
        [ -n "$wt" ] || continue
        if [ "$wt" = "$d" ]; then reg=1; break; fi
      done <<< "$git_wts"
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
      "bash skills/worktree-lib.sh release <slug> (or doctor --fix = worktree-lib gc --stale)"
  else
    record "worktree.locks" "worktree" "PASS" \
      "worktree locks ok (TTL per worktree-lib status)" ""
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
    local fixit
    if distill_lock_stale "$holder"; then
      fixit="/memory distill --force  (or doctor --fix)"
    else
      fixit="doctor --fix --force (a fresh lock; doctor --fix leaves it)"
    fi
    record "worktree.distill_lock" "worktree" "WARN" \
      "distilling_lock held by '$holder'" \
      "$fixit"
  else
    record "worktree.distill_lock" "worktree" "PASS" "distilling_lock clear" ""
  fi
}

