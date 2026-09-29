#!/usr/bin/env bash
# skills/council/test-m14-suite-hygiene.sh — SPEC-033 AC N (WP 1-15
# wp-1-15-m14-verify-evidence). Audits every Verify file named by the WP's
# own SPEC-033 AC subsection: it must be discovered by
# `tools/run-all-tests.sh --list`, source tests/lib/hermetic.sh and call
# hermetic_init, and never spawn a live council.
#
# Hermetic: private TMPDIR/HOME (tests/lib/hermetic.sh); the repo audited is
# a `git clone -q` of this worktree's HEAD, not the live tree (the live tree
# may be dirty — SPEC-033 M14(g) case 11 would fail closed on a dirty tree
# with a Verify line, which is not what this suite checks).
# Limit: the live-council check only reads a Verify file's source text; it
# does not evaluate what a wrapped shell (bash -c, eval, a variable holding
# the command) would run, so an indirected spawn can hide from it.
# Fixtures: skills/council/fixtures/m14-suite-hygiene/.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
FIX="$ROOT/skills/council/fixtures/m14-suite-hygiene"

# shellcheck source=../../tests/lib/hermetic.sh
. "$ROOT/tests/lib/hermetic.sh"
hermetic_init

fail=0
pass=0
ok() { echo "OK: $1"; pass=$((pass + 1)); }
fail_msg() { echo "FAIL: $1"; fail=$((fail + 1)); }

# check_hygiene <repo_dir> <ticket_id> <spec_relpath>
# Prints one OK/FAIL line per verify path per rule to stdout. Returns 0 if
# every rule for every discovered verify path passed, 1 otherwise. Never
# executes a verify file; every rule is static (git ls-files discovery,
# grep on source text).
check_hygiene() {
  local dir="$1" ticket="$2" spec="$3"
  local split_out split_rc
  if split_out="$(cd "$dir" && bash "$ROOT/skills/council/m14-ac-split.sh" "$ticket" "$spec" 2>&1)"; then
    split_rc=0
  else
    split_rc=$?
  fi
  if [ "$split_rc" -ne 0 ]; then
    echo "FAIL: split of '$ticket' in '$spec' exited $split_rc: $split_out"
    return 1
  fi

  local paths
  paths="$(printf '%s\n' "$split_out" | jq -r \
    '[.acs[].verify] | map(select(. != null)) | map(split(" ")[1]) | unique[]' \
    2>/dev/null)" || paths=""
  if [ -z "$paths" ]; then
    echo "FAIL: no non-null verify path found for '$ticket' in '$spec'"
    return 1
  fi

  local list_out
  list_out="$(bash "$ROOT/tools/run-all-tests.sh" --root "$dir" --list 2>&1)" || true

  local overall=0
  local p
  while IFS= read -r p || [ -n "$p" ]; do
    [ -n "$p" ] || continue

    if printf '%s\n' "$list_out" | grep -qxF "$p"; then
      echo "OK: $p — listed by tools/run-all-tests.sh --list"
    else
      echo "FAIL: $p — not listed by tools/run-all-tests.sh --list"
      overall=1
    fi

    if [ -f "$dir/$p" ] \
       && grep -q 'hermetic\.sh' "$dir/$p" \
       && grep -q 'hermetic_init' "$dir/$p"
    then
      echo "OK: $p — sources tests/lib/hermetic.sh and calls hermetic_init"
    else
      echo "FAIL: $p — does not source tests/lib/hermetic.sh and call hermetic_init"
      overall=1
    fi

    # A "live-council call" is a council-invocation or claude-CLI string
    # appearing as an executed, unquoted command -- not as data: a test MAY
    # grep or sed a fixture/spec/prose file for that literal invocation text
    # (e.g. skills/autopilot/test-ship-gate-guardrails.sh checks that
    # skills/autopilot/ship-gate-council.md names exactly one flag on its
    # own §3b invocation line) without ever running it. Distinguish
    # the two by stripping every single- and double-quoted substring on the
    # SAME candidate line: a quoted grep/sed pattern argument holding the
    # whole trigger disappears once its enclosing quotes are stripped,
    # because the trigger sat inside them; a real, executed invocation keeps
    # its bare command word after that same stripping, because only its own
    # quoted argument text is removed. So: find every raw candidate line,
    # strip it, and count it only if the bare trigger survives.
    if [ -f "$dir/$p" ]; then
      local hits lineno linetext stripped
      hits=""
      while IFS=: read -r lineno linetext; do
        [ -n "$lineno" ] || continue
        stripped="$(printf '%s' "$linetext" | sed -E "s/'[^']*'//g; s/\"[^\"]*\"//g")"
        if printf '%s' "$stripped" | grep -qE 'claude[[:space:]]*-p|claude[[:space:]]*--|/council'; then
          hits="${hits}${hits:+$'\n'}${lineno}:${linetext}"
        fi
      done < <(grep -nE 'claude[[:space:]]+-p|claude[[:space:]]+--|/council "' "$dir/$p" 2>/dev/null || true)
      if [ -n "$hits" ]; then
        echo "FAIL: $p — has a live-council call:"
        printf '%s\n' "$hits" | sed 's/^/    /'
        overall=1
      else
        echo "OK: $p — no live-council call"
      fi
    fi
  done <<EOF_PATHS
$paths
EOF_PATHS

  return $overall
}

# overlay_ship_tree <clone_dir> <ticket_id> <spec_relpath> [<src_root>]
# /release Step 4.13 runs this suite with the WP's diff squash-staged into
# the INDEX but not yet committed, so a plain `git clone` of $ROOT
# (objects only) still has the PRE-squash HEAD and lacks this subsection
# and its Verify files -- the split then fails closed with case 3
# ("subsection is missing"), not because of a real defect. Overlay the
# INDEX's spec and every Verify-named file it lists into the clone, and
# commit them there (a throwaway commit in the clone only), so the
# split's `git show HEAD:`/`git cat-file -e HEAD:` lookups see the tree
# that is about to ship and case 11 (dirty tracked files) stays clean.
#
# Reads from the INDEX (`git show ":<path>"`), not the working tree: a
# `cp` from the working tree would (a) pass an untracked Verify file
# (forgotten `git add`) that the shipped commit will not actually
# contain -- exactly the gap case 10 exists to catch -- and (b) pick up
# unstaged edits that will never ship. In a committed worktree (no
# staged-but-uncommitted diff) the index equals HEAD, so this is a
# no-op change of source, not of result. A path absent from the index
# is simply not written into the clone, so the split sees it as absent
# at HEAD (case 10), matching what will really ship.
#
# <src_root> defaults to $ROOT; a caller MAY point it at another repo
# (this suite's own bite test uses a synthetic one) to exercise the
# untracked-file gap without touching the real worktree.
#
# Bootstrap: the Verify path list comes from the very spec text being
# overlaid, so it is read out of the just-overlaid COPY inside the
# clone (a small awk mirror of the M14(g) subsection/Verify-line shape),
# after the spec itself has been overlaid but before the loop that
# overlays each Verify file.
#
# Path safety: a Verify path is never used to build a filesystem path
# outside the clone. A path shaped `/...`, `../...`, `.../../...` or
# exactly `..` is skipped here and left absent in the clone; the split
# then rejects it on its own terms (case 10, absolute/'..'/absent-at-
# HEAD), never mkdir/cp'd anywhere.
overlay_ship_tree() {
  local dir="$1" ticket="$2" spec="$3" src_root="${4:-$ROOT}"

  case "$spec" in
    /*|../*|*/../*|..) return 0 ;;
  esac
  mkdir -p "$dir/$(dirname "$spec")"
  git -C "$src_root" show ":$spec" > "$dir/$spec" 2>/dev/null || rm -f "$dir/$spec"

  local vpaths
  vpaths="$(awk -v ticket="### $ticket" '
    /^## Acceptance criteria$/ { insec = 1; next }
    insec && !insub && /^## / { insec = 0 }
    insec && !insub && $0 == ticket { insub = 1; next }
    insub && (/^### / || /^## / || /^---$/) { insub = 0 }
    insub && /^  Verify: bash / { print }
  ' "$dir/$spec" 2>/dev/null | sed -E 's/^  Verify: bash ([^ ]+).*/\1/')"

  local vp
  while IFS= read -r vp || [ -n "$vp" ]; do
    [ -n "$vp" ] || continue
    case "$vp" in
      /*|../*|*/../*|..) continue ;;
    esac
    mkdir -p "$dir/$(dirname "$vp")"
    git -C "$src_root" show ":$vp" > "$dir/$vp" 2>/dev/null || rm -f "$dir/$vp"
  done <<<"$vpaths"

  git -C "$dir" add -A
  git -C "$dir" commit -q -m "overlay index for $ticket" --allow-empty
}

# ---- Main: this WP's own SPEC-033 AC subsections, the tree about to ship -
TMP="$HERMETIC_ROOT/clone-root"
mkdir -p "$TMP"
CLONE="$TMP/clone"
git clone -q "$ROOT" "$CLONE"

# hygiene_subsection <ticket> — overlays <ticket>'s subsection (and its
# Verify files) into $CLONE's index, runs check_hygiene against it, and
# reports one ok/fail_msg line. WP 1-16 T3 review fix (TL M6): replaces two
# copy-pasted overlay/check/report blocks (one per WP subsection).
hygiene_subsection() {
  local ticket="$1"
  local spec="specs/core/SPEC-033-autopilot-policy.md"
  local out_file="$HERMETIC_ROOT/main-$ticket.out"
  local rc
  overlay_ship_tree "$CLONE" "$ticket" "$spec"
  if check_hygiene "$CLONE" "$ticket" "$spec" > "$out_file" 2>&1; then
    rc=0
  else
    rc=1
  fi
  cat "$out_file"
  if [ "$rc" -eq 0 ]; then
    ok "every Verify file in the $ticket subsection passes hygiene"
  else
    fail_msg "at least one Verify file in the $ticket subsection fails hygiene (see FAIL lines above)"
  fi
}

for ticket in wp-1-15-m14-verify-evidence wp-1-16-m14-finder-recipe; do
  hygiene_subsection "$ticket"
done

# ---- Fixture repo shared by the bite test and the positive control -------
FIXREPO="$HERMETIC_ROOT/fixrepo"
mkdir -p "$FIXREPO/skills/council" "$FIXREPO/skills/fx"
cp "$ROOT/skills/council/m14-ac-split.sh" "$FIXREPO/skills/council/m14-ac-split.sh"
chmod +x "$FIXREPO/skills/council/m14-ac-split.sh"
cp "$FIX/spec-fx.md" "$FIXREPO/spec-fx.md"
cp "$FIX/test-nonhermetic.sh" "$FIXREPO/skills/fx/test-nonhermetic.sh"
chmod +x "$FIXREPO/skills/fx/test-nonhermetic.sh"
cp "$FIX/test-livecouncil.sh" "$FIXREPO/skills/fx/test-livecouncil.sh"
chmod +x "$FIXREPO/skills/fx/test-livecouncil.sh"
git -C "$FIXREPO" init -q
git -C "$FIXREPO" add -A
git -C "$FIXREPO" commit -q -m fixture

# ---- Bite test: a fixture subsection naming a non-hermetic file fails -----
if check_hygiene "$FIXREPO" fx-hygiene spec-fx.md > "$HERMETIC_ROOT/bite.out" 2>&1
then
  BITE_RC=0
else
  BITE_RC=1
fi
if [ "$BITE_RC" -ne 0 ] \
   && grep -q 'test-nonhermetic.sh — does not source tests/lib/hermetic.sh' "$HERMETIC_ROOT/bite.out"
then
  ok "bite: a non-hermetic Verify file fails the hygiene check"
else
  fail_msg "bite: a non-hermetic Verify file fails the hygiene check (rc=$BITE_RC)"
  cat "$HERMETIC_ROOT/bite.out"
fi

# ---- Positive control: an otherwise-hermetic file with a live council ----
# spawn (a bare, unquoted council- or claude-CLI invocation line) MUST
# fail the live-council rule specifically, not the hermetic rule. This
# guards against the live-council check going permanently silent (e.g. a
# quote-stripping bug that also erases a real invocation's own trigger
# text before it can match).
if check_hygiene "$FIXREPO" fx-livecouncil spec-fx.md > "$HERMETIC_ROOT/posctrl.out" 2>&1
then
  POSCTRL_RC=0
else
  POSCTRL_RC=1
fi
if [ "$POSCTRL_RC" -ne 0 ] \
   && grep -q 'test-livecouncil.sh — has a live-council call' "$HERMETIC_ROOT/posctrl.out" \
   && grep -q 'test-livecouncil.sh — sources tests/lib/hermetic.sh and calls hermetic_init' "$HERMETIC_ROOT/posctrl.out"
then
  ok "positive control: an otherwise-hermetic file with a live council spawn fails the live-council rule"
else
  fail_msg "positive control: an otherwise-hermetic file with a live council spawn fails the live-council rule (rc=$POSCTRL_RC)"
  cat "$HERMETIC_ROOT/posctrl.out"
fi

# ---- Bite test: a split failure (e.g. a missing subsection) is reported --
# as a split failure, not silently treated as success (hazard: "$?" right
# after a "cmd || true" is always 0, which would hide a real split
# failure behind the wrong later message).
if check_hygiene "$FIXREPO" fx-missing-subsection spec-fx.md \
    > "$HERMETIC_ROOT/splitfail.out" 2>&1
then
  SPLITFAIL_RC=0
else
  SPLITFAIL_RC=1
fi
if [ "$SPLITFAIL_RC" -ne 0 ] \
   && grep -q "split of 'fx-missing-subsection' in 'spec-fx.md' exited" "$HERMETIC_ROOT/splitfail.out" \
   && grep -q 'case 3' "$HERMETIC_ROOT/splitfail.out"
then
  ok "bite: a split failure (missing subsection) is reported as a split failure"
else
  fail_msg "bite: a split failure (missing subsection) is reported as a split failure (rc=$SPLITFAIL_RC)"
  cat "$HERMETIC_ROOT/splitfail.out"
fi

# ---- Bite test: overlay_ship_tree reads the INDEX, not the working tree -
# An untracked Verify file (present on disk, never `git add`ed -- e.g. a
# forgotten add before the squash) MUST NOT be picked up by the overlay:
# the shipped commit will not contain it, so the clone must not either,
# and the split must fail closed on it (case 10, absent at HEAD) rather
# than silently passing AC M/N on content that will not ship.
SRCREPO="$HERMETIC_ROOT/srcrepo-untracked"
mkdir -p "$SRCREPO/skills/fx"
git -C "$SRCREPO" init -q
cat > "$SRCREPO/spec-untracked.md" <<'SPEC_EOF'
# Fixture spec (m14-suite-hygiene untracked-verify-file bite test)

## Acceptance criteria

### fx-untracked

- **A.** a fixture AC whose Verify file is never committed to the index
  Verify: bash skills/fx/test-untracked.sh
SPEC_EOF
cat > "$SRCREPO/skills/fx/test-untracked.sh" <<'STUB_EOF'
#!/usr/bin/env bash
# Deliberately left untracked in SRCREPO (never `git add`ed): stands in
# for a forgotten `git add` before a squash. overlay_ship_tree MUST NOT
# copy this into the clone, since the index (what will really ship)
# does not have it either.
set -uo pipefail
exit 0
STUB_EOF
chmod +x "$SRCREPO/skills/fx/test-untracked.sh"
git -C "$SRCREPO" add spec-untracked.md
git -C "$SRCREPO" commit -q -m "spec only; the Verify file stays untracked"

CLONE_UNTRACKED="$HERMETIC_ROOT/clone-untracked"
git clone -q "$SRCREPO" "$CLONE_UNTRACKED"
overlay_ship_tree "$CLONE_UNTRACKED" fx-untracked spec-untracked.md "$SRCREPO"

if [ -e "$CLONE_UNTRACKED/skills/fx/test-untracked.sh" ]; then
  fail_msg "bite: an untracked Verify file is not overlaid into the clone (it was copied)"
else
  ok "bite: an untracked Verify file is not overlaid into the clone"
fi

if check_hygiene "$CLONE_UNTRACKED" fx-untracked spec-untracked.md \
    > "$HERMETIC_ROOT/untracked.out" 2>&1
then
  UNTRACKED_RC=0
else
  UNTRACKED_RC=1
fi
if [ "$UNTRACKED_RC" -ne 0 ] && grep -q 'case 10' "$HERMETIC_ROOT/untracked.out"; then
  ok "bite: an untracked Verify file fails the split closed with case 10"
else
  fail_msg "bite: an untracked Verify file fails the split closed with case 10 (rc=$UNTRACKED_RC)"
  cat "$HERMETIC_ROOT/untracked.out"
fi

echo "---"
echo "pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
