#!/usr/bin/env bash
# skills/retro/characterisation-test.sh — CDT-252
# Lock /retro gate-path stdout/stderr against fixture sessions.
# Extracts fenced bash Steps 0–3c from the protocol (commands/retro.md
# before the extract; skills/retro/SKILL.md after) and runs them in one
# shell so output is byte-comparable before and after the move.
# Run: bash skills/retro/characterisation-test.sh
set -u

HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT=$(CDPATH= cd -- "$HERE/../.." && pwd)
GATE_FIX="$ROOT/skills/retro-gate/fixtures"
CMD="$ROOT/commands/retro.md"
SKILL="$HERE/SKILL.md"

PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); echo "PASS: $*"; }
bad() { FAIL=$((FAIL + 1)); echo "FAIL: $*"; }

# Protocol source: skill after extract (has Phase-1 gate), else the command.
PROTO="$CMD"
if [ -f "$SKILL" ] && grep -qF '## Step 3: Phase-1 gate' "$SKILL"; then
  PROTO="$SKILL"
fi
if [ ! -f "$PROTO" ]; then
  echo "error: protocol not found (looked at $SKILL and $CMD)" >&2
  exit 1
fi

# First 10 ```bash fences = Step 0 through Step 3c (early-exit). Spawn is 11+.
GATE_FENCES=10

extract_fences() {
  local src="$1" dest="$2" max="$3"
  awk -v max="$max" '
    BEGIN { n=0; inb=0 }
    /^```bash[[:space:]]*$/ {
      n++
      if (max > 0 && n > max) exit
      inb=1
      printf "# --- fence %d ---\n", n
      next
    }
    /^```[[:space:]]*$/ { if (inb) { inb=0; print ""; next } }
    inb { print }
  ' "$src" > "$dest"
}

cmp_file() {
  local got="$1" want="$2" label="$3"
  if cmp -s "$got" "$want"; then
    ok "$label"
  else
    bad "$label"
    echo "  --- want ---"; cat -A "$want" | sed 's/^/  /'
    echo "  --- got ---"; cat -A "$got" | sed 's/^/  /'
  fi
}

# Isolated HOME so assemble.locate / hosts.py never touch the real ~/.claude.
FAKE_HOME=$(mktemp -d "${TMPDIR:-/tmp}/retro-char-home.XXXXXX")
FAKE_GROK=$(mktemp -d "${TMPDIR:-/tmp}/retro-char-grok.XXXXXX")
WORKDIR=$(mktemp -d "${TMPDIR:-/tmp}/retro-char-work.XXXXXX")
cleanup() {
  rm -rf "$FAKE_HOME" "$FAKE_GROK" "$WORKDIR"
}
trap cleanup EXIT

PROJ="$FAKE_HOME/.claude/projects/char"
mkdir -p "$PROJ"

plant() {
  # plant <sid> <fixture-basename>
  local sid="$1" fix="$2"
  local dest="$PROJ/${sid}.jsonl"
  cp "$GATE_FIX/$fix" "$dest"
  # Freshness guard is 60s; age past it.
  touch -d '5 minutes ago' "$dest"
}

SID_SMOOTH='aaaaaaaa-0000-4000-8000-000000000001'
SID_FLAGGED='aaaaaaaa-0000-4000-8000-000000000002'
SID_LOOP='aaaaaaaa-0000-4000-8000-000000000003'
SID_MISSING='aaaaaaaa-0000-4000-8000-000000000099'

plant "$SID_SMOOTH" "ac1-clean-draft-polish.jsonl"
plant "$SID_FLAGGED" "ac5-write-then-s1.jsonl"

# Filter-2 skip: same smooth body plus a /retro command-name marker.
cp "$GATE_FIX/ac1-clean-draft-polish.jsonl" "$PROJ/${SID_LOOP}.jsonl"
printf '%s\n' '{"type":"user","uuid":"aaaaaaaa-0000-4000-8000-00000000loop","message":{"role":"user","content":[{"type":"text","text":"<command-name>/retro</command-name>"}]}}' \
  >> "$PROJ/${SID_LOOP}.jsonl"
touch -d '5 minutes ago' "$PROJ/${SID_LOOP}.jsonl"

SCRIPT="$WORKDIR/gate-path.sh"
extract_fences "$PROTO" "$SCRIPT" "$GATE_FENCES"
if [ ! -s "$SCRIPT" ]; then
  echo "error: extracted no bash from $PROTO" >&2
  exit 1
fi
n_fences=$(grep -c '^# --- fence ' "$SCRIPT" || echo 0)
if [ "$n_fences" -ne "$GATE_FENCES" ]; then
  echo "error: expected $GATE_FENCES fences, extracted $n_fences from $PROTO" >&2
  exit 1
fi

run_gate() {
  local args="$1" out="$2" err="$3"
  local rcfile="$WORKDIR/rc"
  : >"$out"
  : >"$err"
  (
    export ARGUMENTS="$args"
    export CLAUDE_PLUGIN_ROOT="$ROOT"
    export HOME="$FAKE_HOME"
    export GROK_SESSIONS_DIR="$FAKE_GROK"
    export RETRO_FORCE_TRANSCRIPT_S2=1
    cd "$ROOT" || exit 1
    bash "$SCRIPT"
  ) >"$out" 2>"$err"
  echo $? >"$rcfile"
}

want_stdout="$WORKDIR/want-out"
want_stderr="$WORKDIR/want-err"
got_out="$WORKDIR/got-out"
got_err="$WORKDIR/got-err"
got_rc="$WORKDIR/rc"

# ---- T1 parse: --all and session-id are mutually exclusive ----
run_gate "--all $SID_SMOOTH" "$got_out" "$got_err"
printf '%s\n' 'error: --all and <session-id> are mutually exclusive' >"$want_stderr"
: >"$want_stdout"
cmp_file "$got_out" "$want_stdout" "T1 stdout empty"
cmp_file "$got_err" "$want_stderr" "T1 stderr mutual-exclusion"
if [ "$(cat "$got_rc")" = "1" ]; then ok "T1 exit 1"; else bad "T1 exit $(cat "$got_rc") want 1"; fi

# ---- T2 parse: --host bad token ----
run_gate "--host foo" "$got_out" "$got_err"
printf '%s\n' 'error: --host expects claude|grok|all, got: foo' >"$want_stderr"
: >"$want_stdout"
cmp_file "$got_out" "$want_stdout" "T2 stdout empty"
cmp_file "$got_err" "$want_stderr" "T2 stderr bad --host"
if [ "$(cat "$got_rc")" = "1" ]; then ok "T2 exit 1"; else bad "T2 exit $(cat "$got_rc") want 1"; fi

# ---- T3 parse: --host missing value ----
run_gate "--host" "$got_out" "$got_err"
printf '%s\n' 'error: --host requires a value (claude|grok|all)' >"$want_stderr"
: >"$want_stdout"
cmp_file "$got_out" "$want_stdout" "T3 stdout empty"
cmp_file "$got_err" "$want_stderr" "T3 stderr --host needs value"
if [ "$(cat "$got_rc")" = "1" ]; then ok "T3 exit 1"; else bad "T3 exit $(cat "$got_rc") want 1"; fi

# ---- T4 missing session ----
run_gate "--host claude $SID_MISSING" "$got_out" "$got_err"
printf '%s\n' "Session not found (host=claude): $SID_MISSING" >"$want_stderr"
: >"$want_stdout"
cmp_file "$got_out" "$want_stdout" "T4 stdout empty"
cmp_file "$got_err" "$want_stderr" "T4 stderr session not found"
if [ "$(cat "$got_rc")" = "1" ]; then ok "T4 exit 1"; else bad "T4 exit $(cat "$got_rc") want 1"; fi

# ---- T5 smooth fixture: no friction ----
run_gate "--host claude $SID_SMOOTH" "$got_out" "$got_err"
printf '%s\n' 'No friction detected — nothing to retro.' >"$want_stdout"
: >"$want_stderr"
cmp_file "$got_out" "$want_stdout" "T5 smooth stdout"
cmp_file "$got_err" "$want_stderr" "T5 smooth stderr empty"
if [ "$(cat "$got_rc")" = "0" ]; then ok "T5 exit 0"; else bad "T5 exit $(cat "$got_rc") want 0"; fi

# ---- T6 flagged fixture + --why (byte-identical signal table) ----
run_gate "--host claude --why $SID_FLAGGED" "$got_out" "$got_err"
cat >"$want_stdout" <<EOF
Session: $SID_FLAGGED
Score: 5.5 / 5.0 (passed)
Matched signals:
  S1 x1
  S3 x1
Not matched: S2, S4, S5

EOF
: >"$want_stderr"
cmp_file "$got_out" "$want_stdout" "T6 flagged --why stdout"
cmp_file "$got_err" "$want_stderr" "T6 flagged --why stderr empty"
if [ "$(cat "$got_rc")" = "0" ]; then ok "T6 exit 0"; else bad "T6 exit $(cat "$got_rc") want 0"; fi

# ---- T7 smooth + --why ----
run_gate "--host claude --why $SID_SMOOTH" "$got_out" "$got_err"
cat >"$want_stdout" <<EOF
Session: $SID_SMOOTH
Score: 0.0 / 5.0 (not passed)
Matched signals: (none)
Not matched: S1, S2, S3, S4, S5

No friction detected — nothing to retro.
EOF
: >"$want_stderr"
cmp_file "$got_out" "$want_stdout" "T7 smooth --why stdout"
cmp_file "$got_err" "$want_stderr" "T7 smooth --why stderr empty"
if [ "$(cat "$got_rc")" = "0" ]; then ok "T7 exit 0"; else bad "T7 exit $(cat "$got_rc") want 0"; fi

# ---- T8 Filter-2: session that contains /retro is skipped ----
run_gate "--host claude --why $SID_LOOP" "$got_out" "$got_err"
cat >"$want_stdout" <<EOF
[skip] $SID_LOOP  (host=claude; contains /retro invocation — loop prevention)
No sessions to retro.
EOF
: >"$want_stderr"
cmp_file "$got_out" "$want_stdout" "T8 loop-prevention stdout"
cmp_file "$got_err" "$want_stderr" "T8 loop-prevention stderr empty"
if [ "$(cat "$got_rc")" = "0" ]; then ok "T8 exit 0"; else bad "T8 exit $(cat "$got_rc") want 0"; fi

echo ""
echo "characterisation: protocol=$PROTO"
echo "characterisation tests: $PASS pass / $FAIL fail"
if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
exit 0
