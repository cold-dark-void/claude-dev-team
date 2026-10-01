#!/usr/bin/env bash
# skills/skill-lint/test-command-fences.sh — WP 2-02 (CDT-297, CDT-362,
# rv-w1-46, rv-w1-20): runs the command fences that C8 and C9 guard, in fresh
# shells, the way the host does (tests/lib/fence.sh fence_exec).
#
#   Argument pass-through. Claude Code writes the user's text into the command
#   text at $ARGUMENTS and a Bash-tool fence has no positional arguments. Each
#   fence below reads $ARGUMENTS through a quoted heredoc and splits it with
#   globbing off. This suite puts a sample into the heredoc and checks that the
#   words arrive intact: a * stays a *, and text with $( ) or a backtick is
#   data. The last command of a pass-through fence is swapped for a stub that
#   prints its arguments, so no real script runs.
#   Counts. A grep -c that finds nothing prints 0 and exits 1, so "|| echo 0"
#   gives "0" newline "0". The adjust-agent dashboard prints one count for an
#   empty directives file, and /retro --all --host grok with no Grok session
#   prints its error. Each count case runs the fixed text and a planted copy of
#   the old text (negative control) and the old text must fail.
#
# Hermetic: private TMPDIR/HOME (tests/lib/hermetic.sh). COMMANDS_DIR may name
# another copy of commands/ (default: this checkout).
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CMD="${COMMANDS_DIR:-$ROOT/commands}"

# shellcheck source=../../tests/lib/hermetic.sh
. "$ROOT/tests/lib/hermetic.sh"
# shellcheck source=../../tests/lib/fence.sh
. "$ROOT/tests/lib/fence.sh"
# shellcheck source=../../tests/lib/check.sh
. "$ROOT/tests/lib/check.sh"
hermetic_init
pass=0
fail=0
WORK="$HERMETIC_ROOT/work"
mkdir -p "$WORK"
N=0

# subst_args <fence-text> <sample> — put <sample> where the host puts $ARGUMENTS
# (the body line of the quoted heredoc). Fails when the fence has no such line.
subst_args() {
  local t="$1" s="$2"
  case "$t" in *$'\n''$ARGUMENTS'$'\n'*) ;; *) return 1 ;; esac
  printf '%s\n' "${t/$'\n''$ARGUMENTS'$'\n'/$'\n'$s$'\n'}"
}

# swap <fence-text> <from> <to> — replace the first literal <from>; fails when absent.
swap() {
  local t="$1" from="$2" to="$3"
  case "$t" in *"$from"*) ;; *) return 1 ;; esac
  printf '%s\n' "${t/"$from"/$to}"
}

# run_fence <text> <cwd> [NAME=value...] — sets OUT (stdout), ERR, RC
run_fence() {
  local text="$1" cwd="$2"
  shift 2
  N=$((N + 1))
  fence_exec "$WORK/f$N" "$cwd" "$text" "$@"
  RC=$RUN_RC
  OUT=$(cat "$WORK/f$N.out")
  ERR=$(cat "$WORK/f$N.err")
}

# args_of <stdout> — the ARG: lines joined with |
args_of() { printf '%s\n' "$1" | sed -n 's/^ARG://p' | paste -sd'|' -; }

# pass_through <label> <md> <heading> <n> <stub-from> <stub-to> <sample> <want>
# The fence runs in the repo root (so PDH resolves to this checkout).
pass_through() {
  local label="$1" md="$2" heading="$3" n="$4" from="$5" to="$6" sample="$7" want="$8" text
  text=$(fence_nth "$md" "$heading" "$n") || { fail_line "$label: no fence $n under '$heading'"; return; }
  text=$(subst_args "$text" "$sample") || { fail_line "$label: the fence has no \$ARGUMENTS heredoc line"; return; }
  text=$(swap "$text" "$from" "$to") || { fail_line "$label: the fence no longer holds: $from"; return; }
  run_fence "$text" "$ROOT"
  if [ "$RC" -eq 0 ] && [ "$(args_of "$OUT")" = "$want" ]; then
    pass_line "$label"
  else
    fail_line "$label: rc=$RC args=[$(args_of "$OUT")] want=[$want] err=[$(printf '%s' "$ERR" | head -c 200)]"
  fi
}

# ---- argument pass-through: the four thin commands -------------------------
STUB='printf "ARG:%s\n" "$@"'
pass_through "audit: words and a *.json glob arrive intact" "$CMD/audit.md" "## Step 2: Invoke" 1 \
  'bash "$AUDIT_SH" "$@"' "$STUB" 'apply b1 --from-json *.json --yes' 'apply|b1|--from-json|*.json|--yes'
pass_through "audit: no arguments give no words" "$CMD/audit.md" "## Step 2: Invoke" 1 \
  'bash "$AUDIT_SH" "$@"' "$STUB" '' ''
pass_through "compact-transcript: a * stays a *" "$CMD/compact-transcript.md" "## Step 2: Invoke" 1 \
  'bash "$COMPACT_SH" "$@"' "$STUB" 'sid-1 *' 'sid-1|*'
pass_through "doctor: flags and a * arrive intact" "$CMD/doctor.md" "## Step 2: Invoke doctor" 1 \
  'bash "$DOCTOR_SH" "$@"' "$STUB" '--gate=team --json *' '--gate=team|--json|*'
pass_through "status: a section and a * arrive intact" "$CMD/status.md" "### Step 2: Invoke rollup" 1 \
  'bash "$ROLLUP_SH" "$@"' "$STUB" '--section * --json' '--section|*|--json'
pass_through "audit: \$( ) and a backtick are data" "$CMD/audit.md" "## Step 2: Invoke" 1 \
  'bash "$AUDIT_SH" "$@"' "$STUB" '$(touch PWNED) `touch PWNED2`' '$(touch|PWNED)|`touch|PWNED2`'
check "no command ran from the sample text" test ! -e "$ROOT/PWNED" -a ! -e "$ROOT/PWNED2"

# ---- /setup models and /memory export --------------------------------------
pass_through "setup models: the models word is dropped, a * stays" "$CMD/setup.md" 'Sub: `models`' 1 \
  'bash "$WRITE_MODEL" "${1:-list}" "${@:2}"' 'printf "ARG:%s\n" "${1:-list}" "${@:2}"' 'models set ic5 a*b' 'set|ic5|a*b'
pass_through "setup models: bare models lists" "$CMD/setup.md" 'Sub: `models`' 1 \
  'bash "$WRITE_MODEL" "${1:-list}" "${@:2}"' 'printf "ARG:%s\n" "${1:-list}" "${@:2}"' 'models' 'list'

text=$(fence_nth "$ROOT/skills/memory-store/modes/export.md" "## Step 1: Export seed pack" 1)
text=$(subst_args "$text" 'export --agent pm --limit 5 *') && text=$(swap "$text" 'bash "$EXPORT_SH" "$@" "$MROOT"' 'printf "ARG:%s\n" "$@" "$MROOT"') || text=""
if [ -n "$text" ]; then
  run_fence "$text" "$ROOT"
  # the last ARG line is MROOT; the word before it is the user's last word
  if [ "$RC" -eq 0 ] && [ "$(args_of "$OUT" | cut -d'|' -f1-5)" = '--agent|pm|--limit|5|*' ] && [ "$(args_of "$OUT" | awk -F'|' '{print NF}')" = "6" ]; then
    pass_line "memory export: the export word is dropped and MROOT is the only extra word"
  else
    fail_line "memory export: rc=$RC args=[$(args_of "$OUT")] err=[$ERR]"
  fi
else
  fail_line "memory export: the fence no longer holds the \$ARGUMENTS heredoc or the export call"
fi

# ---- /setup team: --skip-doctor is found in the user's text ----------------
text=$(fence_nth "$CMD/setup.md" "### Step 0: Doctor hard-gate" 1)
text=$(subst_args "$text" '--refresh --skip-doctor *') || text=""
if [ -n "$text" ]; then
  run_fence "$text" "$ROOT"
  if [ "$RC" -eq 0 ] && printf '%s' "$ERR" | grep -q 'WARNING: doctor gate skipped'; then
    pass_line "setup team: --skip-doctor in the user's text skips the gate"
  else
    fail_line "setup team: rc=$RC err=[$(printf '%s' "$ERR" | head -c 200)]"
  fi
else
  fail_line "setup team: the Step 0 fence has no \$ARGUMENTS heredoc"
fi

# ---- /worktree release <slug>: $slug comes from the user's text ------------
worktree_case() { # worktree_case <label> <n> <from> <to> <sample> <want-rc> <want-out>
  local label="$1" n="$2" from="$3" to="$4" sample="$5" want_rc="$6" want_out="$7" text
  text=$(fence_nth "$CMD/worktree.md" 'Step 3:' "$n") || { fail_line "$label: no fence $n"; return; }
  text=$(subst_args "$text" "$sample") || { fail_line "$label: no \$ARGUMENTS heredoc"; return; }
  text=$(swap "$text" "$from" "$to") || { fail_line "$label: the fence no longer holds: $from"; return; }
  run_fence "$text" "$ROOT"
  if [ "$RC" -eq "$want_rc" ] && [ "$(printf '%s' "$OUT" | grep '^SLUG:' || true)" = "$want_out" ]; then
    pass_line "$label"
  else
    fail_line "$label: rc=$RC out=[$OUT] want rc=$want_rc out=[$want_out] err=[$ERR]"
  fi
}
PREVIEW_FROM='bash "$WT_LIB" release --preview "$slug"'
RELEASE_FROM='bash "$WT_LIB" release "$slug"'
SLUG_STUB='printf "SLUG:%s\n" "$slug"'
worktree_case "worktree preview: the slug is read from the user's text" 1 "$PREVIEW_FROM" "$SLUG_STUB" 'release my-slug' 0 'SLUG:my-slug'
worktree_case "worktree release: the slug is read from the user's text" 2 "$RELEASE_FROM" "$SLUG_STUB" 'release my_slug-2' 0 'SLUG:my_slug-2'
worktree_case "worktree preview: a missing slug exits 64" 1 "$PREVIEW_FROM" "$SLUG_STUB" 'release' 64 ''
worktree_case "worktree preview: a path is not a slug" 1 "$PREVIEW_FROM" "$SLUG_STUB" 'release ../evil' 64 ''
worktree_case "worktree release: a * is not a slug" 2 "$RELEASE_FROM" "$SLUG_STUB" 'release a*b' 64 ''

# ---- /adjust-agent Step 7: agent and flags come from the user's text -------
WM_STUB="$WORK/write-model-stub.sh"
cat > "$WM_STUB" <<'EOF'
#!/usr/bin/env bash
printf 'WM:%s\n' "$*" >> "$WM_LOG"
EOF
chmod +x "$WM_STUB"
text=$(fence_nth "$CMD/adjust-agent.md" "## Step 7: Model map" 1)
text=$(subst_args "$text" 'ic5 --model grok-4 --effort high') \
  && text=$(swap "$text" 'WRITE_MODEL=$(bash "$PDH/skills/plugin-dir.sh" file skills/model-map/write-model.sh)' 'WRITE_MODEL=$WM_STUB') || text=""
if [ -n "$text" ]; then
  : > "$WORK/wm.log"
  run_fence "$text" "$ROOT" "WM_STUB=$WM_STUB" "WM_LOG=$WORK/wm.log"
  if [ "$RC" -eq 0 ] && [ "$(paste -sd'|' "$WORK/wm.log")" = 'WM:set ic5 grok-4|WM:set-effort ic5 high' ]; then
    pass_line "adjust-agent Step 7: the agent and both flags reach write-model.sh"
  else
    fail_line "adjust-agent Step 7: rc=$RC log=[$(paste -sd'|' "$WORK/wm.log")] err=[$ERR]"
  fi
else
  fail_line "adjust-agent Step 7: the fence no longer holds the \$ARGUMENTS heredoc or the write-model line"
fi

# ---- retro Step 1: the one parser, words intact ----------------------------
text=$(fence_nth "$CMD/retro.md" "## Step 1: Parse arguments" 1)
text=$(subst_args "$text" '--host grok *') || text=""
if [ -n "$text" ]; then
  text="$text"$'\n''printf "R:%s|%s|%s\n" "$MODE" "$HOST" "$EXPLICIT_SID"'
  run_fence "$text" "$ROOT"
  if [ "$RC" -eq 0 ] && [ "$(printf '%s' "$OUT" | grep '^R:' || true)" = 'R:single|grok|*' ]; then
    pass_line "retro Step 1: --host grok and a * arrive intact"
  else
    fail_line "retro Step 1: rc=$RC out=[$OUT] err=[$ERR]"
  fi
else
  fail_line "retro Step 1: the fence has no \$ARGUMENTS heredoc"
fi

# ---- counts: grep -c with no match gives one 0 ------------------------------
# /retro --all --host grok with no Grok session prints its error and exits 1.
# The planted old text ("|| echo 0") must not: [ "0\n0" -eq 0 ] is an error.
retro_grok() { # retro_grok <fence-text> — sets RC, ERR
  local text
  text=$(subst_args "$1" '--all --host grok') || return 1
  run_fence "$text" "$ROOT"
}
if command -v python3 >/dev/null 2>&1; then
  RETRO2=$(fence_nth "$CMD/retro.md" "Step 2a" 1)
  if retro_grok "$RETRO2"; then
    if [ "$RC" -eq 1 ] && printf '%s' "$ERR" | grep -q 'error: no Grok sessions found'; then
      pass_line "retro --all --host grok with no Grok session prints its error"
    else
      fail_line "retro grok no-sessions: rc=$RC err=[$(printf '%s' "$ERR" | head -c 300)]"
    fi
  else
    fail_line "retro grok no-sessions: the Step 2a fence has no \$ARGUMENTS heredoc"
  fi
  DISC="$ROOT/skills/retro-gate/discover.sh"
  OLD2=$(swap "$(cat "$DISC")" 'grep -c . || true); _gc=${_gc:-0}' 'grep -c . || echo 0)') || OLD2=""
  if [ -n "$OLD2" ]; then
    printf '%s\n' "$OLD2" > "$WORK/discover-old.sh"
    chmod +x "$WORK/discover-old.sh"
    MODE=all HOST=grok HOST_EXPLICIT=1 bash "$WORK/discover-old.sh" >"$WORK/old.out" 2>"$WORK/old.err" || true
    if printf '%s' "$(cat "$WORK/old.err")" | grep -q 'error: no Grok sessions found'; then
      fail_line "control: the old '|| echo 0' text still prints the Grok error (the test does not bite)"
    else
      pass_line "control: the old '|| echo 0' text skips the Grok error"
    fi
  else
    fail_line "control: could not plant the old '|| echo 0' text in discover.sh"
  fi
else
  echo "SKIP: retro grok no-sessions (no python3 on PATH)"
fi

# The adjust-agent dashboard prints one count for an empty directives file.
DASH_REPO="$WORK/dash"
mkdir -p "$DASH_REPO/.claude/memory/pm"
git -C "$DASH_REPO" init -q .
: > "$DASH_REPO/.claude/memory/pm/directives.md"
DASH=$(fence_nth "$CMD/adjust-agent.md" "## Step 3: Dashboard mode" 1)
run_fence "$DASH" "$DASH_REPO"
if [ "$RC" -eq 0 ] && printf '%s\n' "$OUT" | grep -Eq '^pm +0 +Tier default +inherited$' && printf '%s\n' "$OUT" | grep -Eq '^tech-lead +0 +Tier default +inherited$'; then
  pass_line "adjust-agent dashboard: an empty file and a missing file each give one 0"
else
  fail_line "adjust-agent dashboard: rc=$RC out=[$OUT] err=[$(printf '%s' "$ERR" | head -c 200)]"
fi
OLD_DASH=$(swap "$DASH" "|| true); COUNT=\${COUNT:-0}" '|| echo 0)') || OLD_DASH=""
if [ -n "$OLD_DASH" ]; then
  run_fence "$OLD_DASH" "$DASH_REPO"
  if printf '%s\n' "$OUT" | grep -Eq '^pm +0 +Tier default +inherited$'; then
    fail_line "control: the old '|| echo 0' dashboard still prints one clean pm row (the test does not bite)"
  else
    pass_line "control: the old '|| echo 0' dashboard breaks the pm row"
  fi
else
  fail_line "control: could not plant the old '|| echo 0' text in the dashboard fence"
fi

echo
echo "PASS=$pass FAIL=$fail"
[ "$fail" -eq 0 ]
