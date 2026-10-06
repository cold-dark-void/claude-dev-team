#!/usr/bin/env bash
# CDT-360: --blind file list is the linked worktree, not MROOT.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HELPER="$ROOT/skills/council/blind-file-list.sh"
# shellcheck source=../../tests/lib/hermetic.sh
. "$ROOT/tests/lib/hermetic.sh"
# shellcheck source=../../tests/lib/path.sh
. "$ROOT/tests/lib/path.sh"
hermetic_init

fail=0
ok() { echo "OK: $*"; }
bad() { echo "FAIL: $*"; fail=1; }

# Canon-list: canonicalize every path of a helper output block, so needle
# and list are compared in one form (TMPDIR trailing-slash `//`, /var prefix).
canon_list() {
  local p
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    path_canon "$p"
  done
}

# Linked worktree: paths must sit under WTROOT, not the main checkout.
cd "$ROOT"
WTROOT=$(git rev-parse --show-toplevel)
_gc=$(git rev-parse --git-common-dir)
MROOT=$(cd "$(dirname "$_gc")" && pwd)

if [ "$WTROOT" = "$MROOT" ]; then
  echo "NOTE: this checkout toplevel is MROOT; temp worktree case is the proof"
else
  list=$(bash "$HELPER") || { bad "helper failed in linked worktree"; list=""; }
  if [ -z "$list" ]; then
    bad "linked worktree file list empty"
  else
    ok "linked worktree file list non-empty"
  fi
  # Here-string, not a pipe: grep -q under pipefail dies on SIGPIPE.
  if grep -qxF "$WTROOT/AGENTS.md" <<<"$list"; then
    ok "list contains worktree AGENTS.md"
  else
    bad "list missing $WTROOT/AGENTS.md"
  fi
  if grep -qxF "$MROOT/AGENTS.md" <<<"$list"; then
    bad "list contains main-checkout AGENTS.md ($MROOT/AGENTS.md)"
  else
    ok "list does not contain main-checkout AGENTS.md"
  fi
  outside=0
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    case "$p" in
      "$WTROOT"/*) ;;
      *) outside=1; echo "outside WTROOT: $p" ;;
    esac
  done <<EOF
$list
EOF
  if [ "$outside" -eq 0 ]; then
    ok "every linked-worktree path is under WTROOT"
  else
    bad "a path escaped WTROOT"
  fi
fi

# Temp repo + worktree. A helper that lists MROOT fails this case:
# wt-only.txt is only in the worktree index.
MAIN="$TMPDIR/blind-main"
WT="$TMPDIR/blind-wt"
mkdir -p "$MAIN"
git init -q -b main "$MAIN"
printf 'main\n' >"$MAIN/main-only.txt"
printf 'lock\n' >"$MAIN/pkg.lock"
mkdir -p "$MAIN/vendor"
printf 'v\n' >"$MAIN/vendor/v.txt"
git -C "$MAIN" add main-only.txt pkg.lock vendor/v.txt
git -C "$MAIN" commit -q -m main
git -C "$MAIN" worktree add -q "$WT" HEAD
printf 'wt\n' >"$WT/wt-only.txt"
git -C "$WT" add wt-only.txt
git -C "$WT" commit -q -m wt

# Both sides canonical: the helper prints git-resolved paths; the fixture
# strings may carry TMPDIR's trailing-slash `//` (macOS lane).
WT=$(path_canon "$WT")
MAIN=$(path_canon "$MAIN")

wt_list=$(cd "$WT" && bash "$HELPER" | canon_list) || { bad "helper failed in temp worktree"; wt_list=""; }
if grep -qxF "$WT/wt-only.txt" <<<"$wt_list"; then
  ok "temp worktree lists wt-only.txt"
else
  bad "temp worktree missing $WT/wt-only.txt (MROOT list would omit it)"
fi
if grep -qxF "$WT/main-only.txt" <<<"$wt_list"; then
  ok "temp worktree lists main-only.txt under WTROOT"
else
  bad "temp worktree missing $WT/main-only.txt"
fi
if grep -qxF "$MAIN/main-only.txt" <<<"$wt_list"; then
  bad "helper listed MROOT path $MAIN/main-only.txt"
else
  ok "helper did not list the main checkout path"
fi
if grep -qE 'pkg\.lock|/vendor/' <<<"$wt_list"; then
  bad "full-tree list kept a lockfile or vendor path"
else
  ok "full-tree excludes lockfile and vendor"
fi

# Same excludes on --target. vendor/ is tracked, so the list is empty after
# the filter and the helper must fail loud.
set +e
vendor_out=$(cd "$WT" && bash "$HELPER" vendor 2>"$TMPDIR/vendor.err")
vendor_ec=$?
set -e
if [ "$vendor_ec" -ne 0 ] && [ -z "$vendor_out" ] && grep -q 'empty' "$TMPDIR/vendor.err"; then
  ok "target vendor/ is excluded and fails loud"
else
  bad "target vendor/ ec=$vendor_ec out=$(printf %s "$vendor_out")"
fi

# Untracked target: git ls-files exits 0 with an empty list. Fall through to find.
mkdir -p "$WT/loose"
printf 'z\n' >"$WT/loose/z.txt"
loose=$(cd "$WT" && bash "$HELPER" loose | canon_list) || { bad "untracked target failed"; loose=""; }
if grep -qxF "$WT/loose/z.txt" <<<"$loose"; then
  ok "untracked target fell through to find"
else
  bad "untracked target did not list z.txt"
fi

# An unescaped regex '.git/' matches 'Xgit/'. Fixed string must keep this path.
mkdir -p "$WT/loose/fooXgit"
printf 'g\n' >"$WT/loose/fooXgit/bar.txt"
loose2=$(cd "$WT" && bash "$HELPER" loose | canon_list) || loose2=""
if grep -qF 'fooXgit/bar.txt' <<<"$loose2"; then
  ok "fixed-string .git filter kept fooXgit/bar.txt"
else
  bad "filter dropped fooXgit/bar.txt"
fi

set +e
miss=$(cd "$WT" && bash "$HELPER" no-such-dir 2>"$TMPDIR/miss.err")
miss_ec=$?
set -e
if [ "$miss_ec" -ne 0 ] && grep -q 'not found' "$TMPDIR/miss.err"; then
  ok "missing target fails loud"
else
  bad "missing target ec=$miss_ec"
fi

if [ "$fail" -eq 0 ]; then
  echo "PASS: test-blind-file-list.sh"
  exit 0
fi
echo "FAIL: test-blind-file-list.sh"
exit 1
