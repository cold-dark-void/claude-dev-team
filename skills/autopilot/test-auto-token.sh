#!/usr/bin/env bash
# skills/autopilot/test-auto-token.sh — SPEC-041 M1/AC2 (token half).
#
# Covers:
#   - skills/autopilot/parse-flags.sh accepts --autopilot=auto and reports
#     bump:"auto" in the status JSON (flag-only ship intent, like master).
#   - Illegal and empty --autopilot= values exit 64 with zero side effects
#     (stdout empty, nothing written to the fixture tree).
#   - AUTOPILOT env (1 or "auto") NEVER carries a bump — bump stays null
#     (SPEC-033 M2). Flag wins over env.
#   - Card invariant (AC6, M3): append-card.sh rejects bump:"auto" — the
#     SPEC-033 AC6 bump enum stays patch|minor|major|master|null and no
#     ledger line is appended.
#
# Runs no live gates; writes only under a hermetic TMPDIR (never the real
# .claude/autopilot/). THIS SCRIPT IS A SUBPROCESS CLI — NEVER SOURCE IT.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck source=../../tests/lib/hermetic.sh
. "$ROOT/tests/lib/hermetic.sh"
# shellcheck source=../../tests/lib/fence.sh
. "$ROOT/tests/lib/fence.sh"
hermetic_init

SCRIPT_DIR="$ROOT/skills/autopilot"
PARSE="$SCRIPT_DIR/parse-flags.sh"
APPEND="$SCRIPT_DIR/append-card.sh"

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); echo "PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "FAIL: $1" >&2; }

if ! command -v jq >/dev/null 2>&1; then
  fail "jq not found; cannot run this suite"
  echo "PASS=$PASS FAIL=$FAIL"
  exit 1
fi

# ---- Hermetic fixture git repo (fake MROOT via git-common-dir) -------------
FX="$HERMETIC_ROOT/mroot"
mkdir -p "$FX"
git init -q "$FX" || { echo "FAIL: git init" >&2; exit 1; }
cd "$FX" || { echo "FAIL: cd $FX" >&2; exit 1; }
AUTODIR="$FX/.claude/autopilot"

# run_capture <cmd...> -> sets G_OUT, G_ERR, G_RC. Never trips anything.
run_capture() {
  local errfile
  errfile=$(mktemp "${TMPDIR:-/tmp}/tat-err.XXXXXX")
  G_OUT=$("$@" 2>"$errfile")
  G_RC=$?
  G_ERR=$(cat "$errfile")
  rm -f "$errfile"
}

# side_effects <dir> — prints a stable fingerprint of every file under <dir>.
side_effects() {
  (cd "$1" && find . -type f | LC_ALL=C sort)
}

# =============================================================================
# parse-flags.sh — --autopilot=auto accepted, bump reports auto (M1)
# =============================================================================

run_capture bash "$PARSE" --autopilot=auto
if [ "$G_RC" -eq 0 ] && printf '%s' "$G_OUT" | jq -e \
  '.enabled == true and .bump == "auto" and .source == "flag"' >/dev/null 2>&1; then
  pass "auto1 --autopilot=auto -> enabled/bump=auto/source=flag"
else
  fail "auto1 --autopilot=auto rc=$G_RC out=$G_OUT"
fi

# auto alongside the other independent flags — full six-key status JSON.
run_capture bash "$PARSE" --autopilot=auto --council-tier=light --tier=standard --max-loc=250
if [ "$G_RC" -eq 0 ] && printf '%s' "$G_OUT" | jq -e \
  '.bump == "auto" and .council_tier == "light" and .tier == "standard" and .max_loc == 250' \
  >/dev/null 2>&1; then
  pass "auto2 --autopilot=auto composes with council-tier/tier/max-loc"
else
  fail "auto2 composition rc=$G_RC out=$G_OUT"
fi

# Bare --autopilot still reports a null bump (auto is '='-form only).
run_capture bash "$PARSE" --autopilot
if [ "$G_RC" -eq 0 ] && printf '%s' "$G_OUT" | jq -e \
  '.enabled == true and .bump == null and .source == "flag"' >/dev/null 2>&1; then
  pass "auto3 bare --autopilot still bump=null"
else
  fail "auto3 bare --autopilot rc=$G_RC out=$G_OUT"
fi

# Existing tokens still accepted after the enum grows (no regression).
run_capture bash "$PARSE" --autopilot=master
if [ "$G_RC" -eq 0 ] && printf '%s' "$G_OUT" | jq -e '.bump == "master"' >/dev/null 2>&1; then
  pass "auto4 --autopilot=master still accepted"
else
  fail "auto4 --autopilot=master rc=$G_RC out=$G_OUT"
fi

# =============================================================================
# parse-flags.sh — illegal/empty values exit 64 with zero side effects
# =============================================================================

BEFORE=$(side_effects "$FX")
for bad in autoo Auto AUTO "auto " "auto=" "auto,master"; do
  run_capture bash "$PARSE" "--autopilot=$bad"
  if [ "$G_RC" -ne 64 ]; then
    fail "auto-illegal '--autopilot=$bad' rc=$G_RC (want 64)"
  elif [ -n "$G_OUT" ]; then
    fail "auto-illegal '--autopilot=$bad' wrote stdout: $G_OUT"
  else
    pass "auto-illegal --autopilot=$bad -> 64, no stdout"
  fi
done
run_capture bash "$PARSE" --autopilot=
if [ "$G_RC" -eq 64 ] && [ -z "$G_OUT" ]; then
  pass "auto-empty --autopilot= -> 64, no stdout"
else
  fail "auto-empty --autopilot= rc=$G_RC out=$G_OUT"
fi
if [ "$(side_effects "$FX")" = "$BEFORE" ]; then
  pass "auto-side-effect failing parses wrote nothing under the fixture"
else
  fail "auto-side-effect fixture tree changed after failing parses"
fi

# =============================================================================
# parse-flags.sh — env NEVER carries a bump (SPEC-033 M2 / SPEC-041 M1)
# =============================================================================

run_capture env AUTOPILOT=1 bash "$PARSE"
if [ "$G_RC" -eq 0 ] && printf '%s' "$G_OUT" | jq -e \
  '.enabled == true and .bump == null and .source == "env"' >/dev/null 2>&1; then
  pass "auto-env1 AUTOPILOT=1 -> enabled, bump=null"
else
  fail "auto-env1 AUTOPILOT=1 rc=$G_RC out=$G_OUT"
fi

# auto IS a bump, so env cannot carry it either.
run_capture env AUTOPILOT=auto bash "$PARSE"
if [ "$G_RC" -eq 0 ] && printf '%s' "$G_OUT" | jq -e '.bump == null' >/dev/null 2>&1; then
  pass "auto-env2 AUTOPILOT=auto does not carry a bump"
else
  fail "auto-env2 AUTOPILOT=auto rc=$G_RC out=$G_OUT"
fi

# Flag wins over env; auto reaches the status only via the flag.
run_capture env AUTOPILOT=1 bash "$PARSE" --autopilot=auto
if [ "$G_RC" -eq 0 ] && printf '%s' "$G_OUT" | jq -e \
  '.bump == "auto" and .source == "flag"' >/dev/null 2>&1; then
  pass "auto-env3 --autopilot=auto wins over AUTOPILOT=1"
else
  fail "auto-env3 flag-vs-env rc=$G_RC out=$G_OUT"
fi

# Duplicate still 64 with auto in the vocabulary (SPEC-033 M16 holds).
run_capture bash "$PARSE" --autopilot=auto --autopilot=patch
if [ "$G_RC" -eq 64 ] && [ -z "$G_OUT" ]; then
  pass "auto-dup second --autopilot -> 64"
else
  fail "auto-dup rc=$G_RC out=$G_OUT"
fi

# =============================================================================
# Card invariant (AC6/M3): append-card.sh rejects bump:"auto", no ledger line
# =============================================================================

TICKET="SPEC041-T1"
LEDGER="$AUTODIR/$TICKET.jsonl"

run_capture bash "$APPEND" \
  orchestrate "$TICKET" ship-choice proceed auto auto 90 null run-1 1 10 claude "bump:auto is invalid"
if [ "$G_RC" -eq 64 ]; then
  if printf '%s' "$G_ERR" | grep -q "^error: .*bump"; then
    pass "auto-card append-card rejects bump=auto (rc=64, names bump)"
  else
    fail "auto-card rc=64 but stderr does not name bump: $G_ERR"
  fi
else
  fail "auto-card append-card bump=auto rc=$G_RC (want 64)"
fi
if [ ! -s "$LEDGER" ]; then
  pass "auto-card no ledger line appended for bump=auto"
else
  fail "auto-card ledger exists despite rc=64: $LEDGER"
fi

# Sanity: the same argv with a concrete bump succeeds — the rejection is the
# bump value, not the shape (negative control for the invariant test).
run_capture bash "$APPEND" \
  orchestrate "$TICKET" ship-choice proceed auto patch 90 null run-1 1 10 claude "sanity"
if [ "$G_RC" -eq 0 ] && [ -s "$LEDGER" ] && \
  jq -e 'select(.bump == "patch")' "$LEDGER" >/dev/null 2>&1; then
  pass "auto-card same argv with bump=patch appends one card"
else
  fail "auto-card bump=patch sanity rc=$G_RC ledger=$LEDGER"
fi

# =============================================================================
# AC2 gap — /kickoff's own parse path: the Step 0 "Autopilot detection" fence
# (skills/kickoff/SKILL.md) shells out to skills/autopilot/parse-flags.sh and
# consumes .enabled/.bump itself. Run the real fence and observe the values.
# =============================================================================

KICKOFF_MD="$ROOT/skills/kickoff/SKILL.md"
KFENCE=$(fence_nth "$KICKOFF_MD" "### Autopilot detection" 1)
if [ -n "$KFENCE" ]; then
  pass "kickoff-path Step 0 fence extracted from skills/kickoff/SKILL.md"
else
  fail "kickoff-path: no bash fence under '### Autopilot detection' in skills/kickoff/SKILL.md"
fi

if [ -n "$KFENCE" ]; then
  # <TICKET-ID> substituted per §2 discipline; a read-only probe is appended
  # AFTER the fence body so the fence's own consumed values reach stdout —
  # the fence body itself is untouched.
  KSUB=$(printf '%s\n' \
    "$(printf '%s' "$KFENCE" | sed 's|<TICKET-ID>|SPEC041-K1|g')" \
    'printf "KICKOFF_AUTOPILOT_ON=%s KICKOFF_BUMP=%s\n" "$AUTOPILOT_ON" "$AUTOPILOT_BUMP"')

  kf_run() { # kf_run <args...> -> K_OUT, K_RC (fence cwd: the hermetic fixture)
    local f
    f=$(mktemp "${TMPDIR:-/tmp}/kf-auto.XXXXXX")
    printf '%s\n' "$KSUB" > "$f.sh"
    K_OUT=$(cd "$HERMETIC_ROOT" && CLAUDE_PLUGIN_ROOT="$ROOT" bash "$f.sh" "$@" 2>/dev/null)
    K_RC=$?
    rm -f "$f" "$f.sh"
  }

  kf_run --autopilot=auto
  if [ "$K_RC" -eq 0 ] && [ "$K_OUT" = "KICKOFF_AUTOPILOT_ON=true KICKOFF_BUMP=auto" ]; then
    pass "kickoff-path --autopilot=auto: Step 0 fence consumes enabled=true bump=auto"
  else
    fail "kickoff-path --autopilot=auto rc=$K_RC out=$K_OUT"
  fi

  kf_run --autopilot=bogus
  if [ "$K_RC" -eq 64 ]; then
    pass "kickoff-path --autopilot=bogus: fence exits 64 (parse-flags rejection honored)"
  else
    fail "kickoff-path --autopilot=bogus rc=$K_RC (want 64)"
  fi
fi

# =============================================================================
# AC2 gap — /epic's own parser (skills/epic/parse-flags.sh) accepts the auto
# token as an orthogonal flag: rc 0, release_bump untouched (the bump grammar
# is owned by skills/autopilot/parse-flags.sh; epic never copies it).
# =============================================================================

run_capture bash "$ROOT/skills/epic/parse-flags.sh" --worktree --autopilot=auto
if [ "$G_RC" -eq 0 ] && printf '%s' "$G_OUT" | jq -e \
  '.worktree_enabled == true and .release_bump == null' >/dev/null 2>&1; then
  pass "epic-path --autopilot=auto: epic parse-flags rc 0, release_bump untouched"
else
  fail "epic-path --autopilot=auto rc=$G_RC out=$G_OUT"
fi

# =============================================================================
# AC2 gap — unchanged gates (contract prose): all gates other than the ship
# gate self-answer per SPEC-033 unchanged. The M13 gate enum must stay the
# byte-identical canonical triad (no fourth gate, no `auto`), self-answer.md's
# envelope enum must match, and classify.md must answer no gate but
# ship-choice.
# =============================================================================

SPEC033="$ROOT/specs/core/SPEC-033-autopilot-policy.md"
SELFANS="$SCRIPT_DIR/self-answer.md"
CLASSIFY_MD="$SCRIPT_DIR/classify.md"
if grep -qF '"gate": "scope-confirm | plan-approve | ship-choice"' "$SPEC033"; then
  pass "AC2-unchanged-gates SPEC-033 M13 gate enum is the canonical triad (byte-identical, no auto)"
else
  fail "AC2-unchanged-gates: SPEC-033 M13 gate enum changed"
fi
if grep -qF '"scope-confirm" | "plan-approve" | "ship-choice"' "$SELFANS"; then
  pass "AC2-unchanged-gates self-answer.md envelope gate enum unchanged"
else
  fail "AC2-unchanged-gates: self-answer.md gate enum changed"
fi
if [ "$(grep -cE 'scope-confirm|plan-approve' "$CLASSIFY_MD" || true)" = "0" ]; then
  pass "AC2-unchanged-gates classify.md answers no gate other than ship-choice"
else
  fail "AC2-unchanged-gates: classify.md names scope-confirm/plan-approve"
fi

# =============================================================================
# AC2 bite (attempt-2 M14 strike closure) — /orchestrate accepts
# --autopilot=auto: drive orchestrate's own Step-0 fence (steps/00-resolve.md,
# "Autopilot detection") exactly like the kickoff-path case above, with a
# read-only probe appended AFTER the fence body so the consumed values reach
# stdout. The fence body itself is untouched.
# =============================================================================

ORCH_MD="$ROOT/skills/orchestrate/steps/00-resolve.md"
OFENCE=$(fence_nth "$ORCH_MD" "### Autopilot detection" 1)
if [ -n "$OFENCE" ]; then
  pass "orchestrate-path Step 0 fence extracted from skills/orchestrate/steps/00-resolve.md"
else
  fail "orchestrate-path: no bash fence under '### Autopilot detection' in steps/00-resolve.md"
fi

if [ -n "$OFENCE" ]; then
  OSUB=$(printf '%s\n' \
    "$OFENCE" \
    'printf "ORCH_AUTOPILOT_ON=%s ORCH_BUMP=%s ORCH_SOURCE=%s\n" "$AUTOPILOT_ON" "$AUTOPILOT_BUMP" "$AP_SOURCE"')
  of_run() { # of_run <args...> -> O_OUT, O_RC (fence cwd: the hermetic fixture)
    local f
    f=$(mktemp "${TMPDIR:-/tmp}/of-auto.XXXXXX")
    printf '%s\n' "$OSUB" > "$f.sh"
    O_OUT=$(cd "$HERMETIC_ROOT" && CLAUDE_PLUGIN_ROOT="$ROOT" bash "$f.sh" "$@" 2>/dev/null)
    O_RC=$?
    rm -f "$f" "$f.sh"
  }

  of_run --autopilot=auto
  if [ "$O_RC" -eq 0 ] && [ "$O_OUT" = "ORCH_AUTOPILOT_ON=true ORCH_BUMP=auto ORCH_SOURCE=flag" ]; then
    pass "orchestrate-path /orchestrate accepts --autopilot=auto: Step 0 fence consumes enabled=true bump=auto source=flag"
  else
    fail "orchestrate-path --autopilot=auto rc=$O_RC out=$O_OUT"
  fi

  of_run --autopilot=bogus
  if [ "$O_RC" -eq 64 ]; then
    pass "orchestrate-path --autopilot=bogus: Step 0 fence exits 64 (parse-flags rejection honored)"
  else
    fail "orchestrate-path --autopilot=bogus rc=$O_RC (want 64)"
  fi
fi

# =============================================================================
# AC2 bite — a BC5 reroute under auto persists release_bump: auto. Drive the
# epic-lib state-persist path (init) with the auto seal-intent token in a
# hermetic fixture (EPIC_ROOT), then exhibit the persisted state, plus the
# resume path honoring the stored value.
# =============================================================================

EPIC_FX="$HERMETIC_ROOT/epic-auto-fx"
mkdir -p "$EPIC_FX"
git init -q "$EPIC_FX"
EPI_RUN() { # EPI_RUN <args...> -> E_OUT, E_RC (cwd + EPIC_ROOT = the fixture)
  E_OUT=$(cd "$EPIC_FX" && EPIC_ROOT="$EPIC_FX" bash "$ROOT/skills/epic/epic-lib.sh" "$@" 2>&1)
  E_RC=$?
}
EPI_RUN init EPIC-SPEC041-A --title t --mode orchestrate --worktree-enabled true --release-bump auto
if [ "$E_RC" -eq 0 ] \
  && [ "$(jq -r .release_bump "$EPIC_FX/.claude/epics/EPIC-SPEC041-A/state.json")" = "auto" ] \
  && [ "$(jq -r .worktree_enabled "$EPIC_FX/.claude/epics/EPIC-SPEC041-A/state.json")" = "true" ]; then
  pass "BC5-reroute persist: epic init with the auto token persisted release_bump=\"auto\" (worktree_enabled=true) in state.json"
else
  fail "BC5-reroute persist rc=$E_RC out=$E_OUT"
fi
EPI_RUN resolve-resume-flags EPIC-SPEC041-A --autopilot=auto
if [ "$E_RC" -eq 0 ] && printf '%s' "$E_OUT" | jq -e '.release_bump == "auto" and .worktree_enabled == true' >/dev/null 2>&1; then
  pass "BC5-reroute persist: resume path honors the stored release_bump=auto (no session-only bump)"
else
  fail "BC5-reroute persist resume rc=$E_RC out=$E_OUT"
fi

# =============================================================================
# AC2 bite — the literal token `auto` never appears in a decision-card bump
# field in REAL flows: run the real classify fence (halt path writes a card
# via append-card) plus the concrete-bump card above, then dump every card
# via read-cards and assert every bump value is null or in
# {patch,minor,major,master}.
# =============================================================================

CFENCE=$(fence_nth "$CLASSIFY_MD" "## 4. The one executable fence" 1)
if [ -n "$CFENCE" ]; then
  # The fence's veto needs a resolvable baseline ref in the fixture repo.
  git -C "$FX" config user.email t@t.invalid
  git -C "$FX" config user.name t
  printf 'base\n' > "$FX/README.md"
  git -C "$FX" add README.md
  git -C "$FX" commit -qm base
  git -C "$FX" update-ref refs/remotes/origin/main "$(git -C "$FX" rev-parse HEAD)"
  CSUB=$(printf '%s' "$CFENCE" | sed \
    -e 's|<baseline-ref>|origin/main|g' \
    -e 's|<stage0-code-bearing>|yes|g' \
    -e 's|<stage1-answer>|major|g' \
    -e 's|<stage0-evidence>|breaking change|g' \
    -e 's|<stage1-reason>|would-be major|g' \
    -e 's|<workflow>|orchestrate|g' \
    -e 's|<ticket_id>|'"$TICKET"'|g' \
    -e 's|<run_id>|run-real-1|g' \
    -e 's|<iteration>|3|g' \
    -e 's|<run_start_epoch>|1700000000|g')
  cf=$(mktemp "${TMPDIR:-/tmp}/cf-auto.XXXXXX")
  printf '%s\n' "$CSUB" > "$cf.sh"
  CF_OUT=$(cd "$FX" && CLAUDE_PLUGIN_ROOT="$ROOT" bash "$cf.sh" 2>/dev/null)
  CF_RC=$?
  rm -f "$cf" "$cf.sh"
  if [ "$CF_RC" -eq 0 ] && printf '%s' "$CF_OUT" | grep -q '^CLASSIFY_DECISION=halt$'; then
    pass "auto-card real flow: the classify fence halt path ran (rc 0, decision=halt) and wrote its card via append-card"
  else
    fail "auto-card real flow: classify fence halt rc=$CF_RC out=$(printf '%s' "$CF_OUT" | head -2)"
  fi
  DUMP=$( cd "$FX" && bash "$ROOT/skills/autopilot/read-cards.sh" "$TICKET" 2>/dev/null )
  if [ "$(printf '%s' "$DUMP" | jq 'length')" -ge 2 ] \
    && printf '%s' "$DUMP" | jq -e 'all(.bump == null or .bump == "patch" or .bump == "minor" or .bump == "major" or .bump == "master")' >/dev/null 2>&1; then
    pass "auto-card real-flow dump: every decision-card bump field is null|patch|minor|major|master — no auto ($(printf '%s' "$DUMP" | jq 'length') cards)"
  else
    fail "auto-card real-flow dump: unexpected bump values — $(printf '%s' "$DUMP" | jq -c '[.[].bump]')"
  fi
else
  fail "auto-card real flow: no fence under classify.md §4"
fi

echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
