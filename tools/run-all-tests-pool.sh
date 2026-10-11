# Sourced by tools/run-all-tests.sh when jobs>1 (CDT-534 R37/R39). Not a CLI.
# Caller owns set -u / pipefail and the globals ROOT, SEED, SEED_SHA, SCRATCH,
# WORKDIR, FREELIST, PROG.

copy_tree_bytes() { # copy_tree_bytes <list> <src> <dst> [<present-list>] --
                    # copy the bytes of every NUL-listed repo-relative path
                    # from <src> into <dst>, creating parent dirs. Symlinks
                    # stay symlinks (cp -a). A source path that is a
                    # directory is a gitlink (submodule): nothing to copy.
                    # A missing source path becomes a plain deletion in
                    # <dst>, which is exactly an unstaged deletion. Paths
                    # actually copied are appended NUL-delimited to
                    # <present-list> so the caller can batch one `git add`
                    # (per-path adds would be thousands of index writes).
  local list="$1" src="$2" dst="$3" present="${4:-}" p rc=0
  while IFS= read -r -d '' p || [ -n "$p" ]; do
    if [ -L "$src/$p" ]; then
      :
    elif [ -d "$src/$p" ]; then
      continue
    elif [ ! -e "$src/$p" ]; then
      rm -f "$dst/$p" || rc=1
      continue
    fi
    case "$p" in
      */*) mkdir -p "$dst/${p%/*}" || rc=1 ;;
    esac
    cp -a "$src/$p" "$dst/$p" || rc=1
    if [ -n "$present" ]; then
      printf '%s\0' "$p" >> "$present" || rc=1
    fi
  done < "$list"
  return "$rc"
}

stage_paths() { # stage_paths <present-list> <repo> -- ONE batched `git add`
                # over the NUL list. An empty list must not reach xargs: GNU
                # xargs runs its command once even on empty input, and a
                # bare `git add` would stage every worktree change.
  [ -s "$1" ] || return 0
  GIT_LITERAL_PATHSPECS=1 xargs -0 git -C "$2" add -- < "$1"
}

drop_seed_paths_not_cached() { # drop_seed_paths_not_cached -- R37: after
                               # overlaying --root's cached bytes, drop every
                               # path still in the seed index that is not in
                               # that cached list (staged git rm, or the old
                               # side of git mv). Source index is never copied.
  local p rc=0
  git -C "$SEED" ls-files -z > "$WORKDIR/seed-cached.lst" || return 1
  tr '\0' '\n' < "$WORKDIR/cached.lst" > "$WORKDIR/cached.nl" || return 1
  while IFS= read -r -d '' p || [ -n "$p" ]; do
    [ -n "$p" ] || continue
    if grep -Fxq -- "$p" "$WORKDIR/cached.nl"; then
      continue
    fi
    git -C "$SEED" rm -q --cached -- "$p" || rc=1
    rm -f "$SEED/$p" || rc=1
  done < "$WORKDIR/seed-cached.lst"
  return "$rc"
}

restore_worker() { # restore_worker <worker> -- R39: clean -qfdx, reset HEAD
                   # to the seed SHA, replace refs + packed-refs from the
                   # seed (drops refs created since the seed; restores
                   # moved seed refs and symbolic refs), restore .git/config,
                   # then the R37 index + checkout-index + cached overlay +
                   # clean -fd + others recopy. A suite that commits, checks
                   # out, or writes ignored files must not change the next
                   # suite's view. Seed has no ignored files (clone + cached
                   # overlay + others --exclude-standard); -x is safe.
                   # HOME/TMPDIR live under WORKDIR, not the clone.
  local w="$1"
  git -C "$w" clean -qfdx >/dev/null 2>&1 || return 1
  rm -rf "$w/.git/refs" || return 1
  cp -a "$SEED/.git/refs" "$w/.git/refs" || return 1
  if [ -f "$SEED/.git/packed-refs" ]; then
    cp "$SEED/.git/packed-refs" "$w/.git/packed-refs" || return 1
  else
    rm -f "$w/.git/packed-refs" || return 1
  fi
  cp "$WORKDIR/seed.HEAD" "$w/.git/HEAD" || return 1
  if [ -n "$SEED_SHA" ]; then
    git -C "$w" reset --hard "$SEED_SHA" >/dev/null 2>&1 || return 1
  fi
  cp "$WORKDIR/seed.gitconfig" "$w/.git/config" || return 1
  if [ -f "$SEED/.git/info/exclude" ]; then
    mkdir -p "$w/.git/info" || return 1
    cp "$SEED/.git/info/exclude" "$w/.git/info/exclude" || return 1
  fi
  if [ -f "$SEED/.git/index" ]; then
    cp "$SEED/.git/index" "$w/.git/index" || return 1
  else
    rm -f "$w/.git/index" || return 1
  fi
  git -C "$w" checkout-index -a -f >/dev/null 2>&1 || return 1
  # checkout-index -a -f puts back paths the seed worktree carries as an
  # unstaged deletion (path in --root's index, absent on its disk): re-run
  # the cached overlay so seed-missing paths are deleted from the worker
  # again, regardless of worker assignment.
  copy_tree_bytes "$WORKDIR/cached.lst" "$SEED" "$w" || return 1
  git -C "$w" clean -qfd >/dev/null 2>&1 || return 1
  copy_tree_bytes "$WORKDIR/others.lst" "$SEED" "$w" || return 1
  return 0
}

release_worker() { # release_worker <n> -- restore worker n's tree and return
                   # it to the free list (also the dispatch-failure path).
  local worker="$1" w
  w="$SCRATCH/worker.$worker"
  if ! restore_worker "$w"; then
    echo "$PROG: warn: could not restore worker $w; later suites in it may report false dirt" >&2
  fi
  printf '%s\n' "$worker" >> "$FREELIST"
}
