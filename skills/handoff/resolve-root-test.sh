#!/usr/bin/env bash
# resolve-root-test.sh — CDT-80 target-session handoff root (not invoker cwd).
# ACs: AC1–AC4, AC6–AC9 (unit). Run: bash skills/handoff/resolve-root-test.sh
set -u

HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
RESOLVE="$HERE/resolve-root.sh"
PREPASS="$HERE/prepass.sh"
FIX="$HERE/fixtures"
THRASH="$FIX/events-thrash.json"
GITBLOB="$FIX/git-state.txt"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $*"; }

WORK=$(mktemp -d "${TMPDIR:-/tmp}/resolve-root-test.XXXXXX")
trap 'rm -rf "$WORK"' EXIT

# ---- T0: helper present ----
if [ -x "$RESOLVE" ]; then ok; else bad "T0 resolve-root.sh missing/not executable"; fi

# Fake target git repo (simulates claude-dev-team)
TARGET="$WORK/target-repo"
mkdir -p "$TARGET"
git -C "$TARGET" init -q
git -C "$TARGET" config user.email "t@example.com"
git -C "$TARGET" config user.name "t"
echo x >"$TARGET/README"
git -C "$TARGET" add README
git -C "$TARGET" commit -q -m "init"
TARGET=$(cd "$TARGET" && pwd)

# Worktree under target (AC7)
WT="$TARGET/.worktrees/fake-wt"
mkdir -p "$WT"
git -C "$TARGET" worktree add -q "$WT" HEAD 2>/dev/null \
  || { # older git: manual linked worktree not required — symlink .git file
      mkdir -p "$WT"
      echo "gitdir: $(cd "$TARGET/.git" && pwd)" >"$WT/.git"
    }
WT=$(cd "$WT" && pwd)

# Non-git project (AC non-git)
NONGIT="$WORK/nongit-project"
mkdir -p "$NONGIT/src"
NONGIT=$(cd "$NONGIT" && pwd)

# Invoker dirs that must NOT receive writes (AC1, AC9)
INV_CLAUDE="$WORK/fake-home/.claude"
INV_TMP="$WORK/invoker-tmp"
mkdir -p "$INV_CLAUDE" "$INV_TMP"

# Transcript with cwd = target (cold session for target-repo)
TR_TARGET="$WORK/projects/enc-target/sess-target-001.jsonl"
mkdir -p "$(dirname "$TR_TARGET")"
printf '%s\n' \
  '{"type":"user","uuid":"u1","cwd":"'"$TARGET"'","timestamp":"2026-07-01T00:00:00.000Z"}' \
  '{"type":"assistant","uuid":"u2","cwd":"'"$TARGET"'","timestamp":"2026-07-01T00:00:01.000Z"}' \
  >"$TR_TARGET"

# Transcript with cwd = worktree
TR_WT="$WORK/projects/enc-target/sess-wt-001.jsonl"
printf '%s\n' \
  '{"type":"user","uuid":"w1","cwd":"'"$WT"'","timestamp":"2026-07-01T00:00:00.000Z"}' \
  >"$TR_WT"

# Transcript with cwd = non-git
TR_NG="$WORK/projects/enc-ng/sess-ng-001.jsonl"
mkdir -p "$(dirname "$TR_NG")"
printf '%s\n' \
  '{"type":"user","uuid":"n1","cwd":"'"$NONGIT"'","timestamp":"2026-07-01T00:00:00.000Z"}' \
  >"$TR_NG"

# Transcript with no cwd and not under ~/.claude/projects (undetermined)
TR_EMPTY="$WORK/orphan/no-cwd.jsonl"
mkdir -p "$(dirname "$TR_EMPTY")"
printf '%s\n' '{"type":"user","uuid":"e1","timestamp":"2026-07-01T00:00:00.000Z"}' >"$TR_EMPTY"

# ---- T1: --transcript → target MROOT + HANDOFF_DIR (AC1/AC3/AC6) ----
set +e
OUT=$(bash "$RESOLVE" --transcript "$TR_TARGET" 2>"$WORK/t1.err")
RC=$?
set -e
PDIR=$(printf '%s\n' "$OUT" | sed -n '1p')
MROOT=$(printf '%s\n' "$OUT" | sed -n '2p')
HDIR=$(printf '%s\n' "$OUT" | sed -n '3p')
if [ "$RC" -eq 0 ] && [ "$MROOT" = "$TARGET" ] \
   && [ "$HDIR" = "$TARGET/.claude/handoff" ]; then ok
else bad "T1 target root rc=$RC mroot=$MROOT hdir=$HDIR err=$(cat "$WORK/t1.err")"; fi

# ---- T2: worktree cwd → shared MROOT via git-common-dir (AC7) ----
set +e
OUT=$(bash "$RESOLVE" --transcript "$TR_WT" 2>"$WORK/t2.err")
RC=$?
set -e
MROOT=$(printf '%s\n' "$OUT" | sed -n '2p')
HDIR=$(printf '%s\n' "$OUT" | sed -n '3p')
if [ "$RC" -eq 0 ] && [ "$MROOT" = "$TARGET" ] \
   && [ "$HDIR" = "$TARGET/.claude/handoff" ]; then ok
else bad "T2 worktree MROOT rc=$RC mroot=$MROOT hdir=$HDIR err=$(cat "$WORK/t2.err")"; fi

# ---- T3: non-git project → project-dir/.claude/handoff (non-git rule) ----
set +e
OUT=$(bash "$RESOLVE" --transcript "$TR_NG" 2>"$WORK/t3.err")
RC=$?
set -e
PDIR=$(printf '%s\n' "$OUT" | sed -n '1p')
MROOT=$(printf '%s\n' "$OUT" | sed -n '2p')
HDIR=$(printf '%s\n' "$OUT" | sed -n '3p')
if [ "$RC" -eq 0 ] && [ "$PDIR" = "$NONGIT" ] && [ "$MROOT" = "$NONGIT" ] \
   && [ "$HDIR" = "$NONGIT/.claude/handoff" ]; then ok
else bad "T3 nongit rc=$RC pdir=$PDIR mroot=$MROOT hdir=$HDIR"; fi

# ---- T4: undetermined → fail hard (AC4) ----
set +e
OUT=$(bash "$RESOLVE" --transcript "$TR_EMPTY" 2>"$WORK/t4.err")
RC=$?
set -e
if [ "$RC" -ne 0 ]; then ok
else bad "T4 expected fail on no-cwd orphan, got rc=0 out=$OUT"; fi

# ---- T5: --project explicit ----
set +e
OUT=$(bash "$RESOLVE" --project "$TARGET" 2>"$WORK/t5.err")
RC=$?
set -e
MROOT=$(printf '%s\n' "$OUT" | sed -n '2p')
if [ "$RC" -eq 0 ] && [ "$MROOT" = "$TARGET" ]; then ok
else bad "T5 --project rc=$RC mroot=$MROOT"; fi

# ---- T6: invoker cwd ignored — resolve still target (AC1/AC8) ----
set +e
OUT=$(
  cd "$INV_CLAUDE" && bash "$RESOLVE" --transcript "$TR_TARGET" 2>"$WORK/t6.err"
)
RC=$?
set -e
MROOT=$(printf '%s\n' "$OUT" | sed -n '2p')
HDIR=$(printf '%s\n' "$OUT" | sed -n '3p')
case "$HDIR" in
  *"/.claude/.claude/"*) bad "T6 nested .claude/.claude path: $HDIR" ;;
  *)
    if [ "$RC" -eq 0 ] && [ "$MROOT" = "$TARGET" ] \
       && [ "$HDIR" = "$TARGET/.claude/handoff" ]; then ok
    else bad "T6 from invoker rc=$RC mroot=$MROOT hdir=$HDIR"; fi
    ;;
esac

# ---- T7: prepass finalize from invoker writes under TARGET (AC1/AC3/AC6/AC9) ----
if [ -x "$PREPASS" ] && [ -f "$THRASH" ]; then
  SID="cdt80-root-sess"
  # Seed a locate-able path: resolve-root via --transcript is not on finalize CLI,
  # so we export nothing and instead plant HANDOFF via resolve then verify prepass
  # uses resolve when HANDOFF_DIR unset + transcript discoverable.
  # Integration: call ensure path by exporting nothing; use resolve output as oracle
  # and run finalize with HANDOFF_DIR only after checking resolve — then a second
  # path: run prepass with env cleared from INV, after monkeypatching via
  # RESOLVE_ROOT_TRANSCRIPT if supported. Prefer: finalize after `export` from resolve.
  EVAL=$(bash "$RESOLVE" --transcript "$TR_TARGET")
  EXP_HDIR=$(printf '%s\n' "$EVAL" | sed -n '3p')
  # Direct finalize without HANDOFF_DIR: prepass must self-resolve from locate.
  # Plant transcript under a projects dir and point assemble via... if no env,
  # pass leaf + git-state and rely on prepass locate failing → must fail hard (AC4)
  # unless we feed transcript. Test AC4 fail path first:
  set +e
  (
    cd "$INV_TMP"
    unset HANDOFF_DIR
    # uuid that will not locate
    bash "$PREPASS" finalize \
      --uuid "cdt80-missing-uuid-zzz" \
      --events "$THRASH" \
      --git-state "$GITBLOB" \
      --leaf "leaf-1" \
      --slug root-test \
      --mode cold \
      --packet-out "" 2>"$WORK/t7a.err"
  )
  RC=$?
  set -e
  # Without packet-out empty string may still try auto path — expect non-zero fail hard
  if [ "$RC" -ne 0 ]; then ok
  else bad "T7a finalize without target must fail hard rc=$RC"; fi
  # No write under invoker
  if find "$INV_TMP" -path '*/.claude/handoff/*' 2>/dev/null | grep -q .; then
    bad "T7a wrote under invoker tmp"
  else ok
  fi
  if find "$INV_CLAUDE" -path '*/.claude/handoff/*' 2>/dev/null | grep -q .; then
    bad "T7a wrote under fake ~/.claude"
  else ok
  fi

  # Happy path: HANDOFF_DIR from resolve (simulates command Step 0 export)
  unset HANDOFF_DIR
  export HANDOFF_DIR="$EXP_HDIR"
  PACKET_GLOB=""
  set +e
  (
    cd "$INV_TMP"
    bash "$PREPASS" finalize \
      --uuid "$SID" \
      --events "$THRASH" \
      --git-state "$GITBLOB" \
      --leaf "leaf-cdt80" \
      --slug root-test \
      --mode cold \
      >"$WORK/t7.out" 2>"$WORK/t7.err"
  )
  RC=$?
  set -e
  unset HANDOFF_DIR
  FOUND=$(find "$TARGET/.claude/handoff" -name "*-${SID}-root-test.md" 2>/dev/null | head -1)
  CACHE="$TARGET/.claude/handoff/cache/${SID}.json"
  if [ "$RC" -eq 0 ] && [ -n "$FOUND" ] && [ -f "$FOUND" ]; then ok
  else bad "T7b packet under target rc=$RC found=$FOUND err=$(head -c 300 "$WORK/t7.err")"; fi
  if [ -f "$CACHE" ]; then ok; else bad "T7b M8 cache missing under target: $CACHE"; fi
  # Printed path equals write path (AC6)
  if grep -q "Full packet (appendix): $FOUND" "$WORK/t7.out" \
     || grep -qF "$FOUND" "$WORK/t7.out"; then ok
  else
    # path cite may use abspath
    ABS=$(cd "$(dirname "$FOUND")" && pwd)/$(basename "$FOUND")
    if grep -qF "$ABS" "$WORK/t7.out"; then ok
    else bad "T7b printed path mismatch out=$(head -c 400 "$WORK/t7.out")"; fi
  fi
  # Must not nest under invoker .claude/.claude
  if find "$INV_CLAUDE" "$INV_TMP" -path '*/.claude/handoff/*' 2>/dev/null | grep -q .; then
    bad "T7b wrote under invoker"
  else ok
  fi
else
  bad "T7 skipped — prepass/fixtures missing"
fi

# ---- T8: --project from worktree path ----
set +e
OUT=$(bash "$RESOLVE" --project "$WT" 2>"$WORK/t8.err")
RC=$?
set -e
MROOT=$(printf '%s\n' "$OUT" | sed -n '2p')
if [ "$RC" -eq 0 ] && [ "$MROOT" = "$TARGET" ]; then ok
else bad "T8 project=worktree rc=$RC mroot=$MROOT err=$(cat "$WORK/t8.err")"; fi

echo
echo "resolve-root-test: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
