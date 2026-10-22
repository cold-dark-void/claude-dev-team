#!/usr/bin/env bash
#
# model-map/concurrency-test.sh — SPEC-037 M30–M33 / SPEC-013 CDT-573 AC4 bite-tests
# for resolve-model.sh --concurrency and resolve-concurrency.sh.
#
# Machine-check: bash skills/model-map/concurrency-test.sh  (exit 0)
# THIS SCRIPT IS A SUBPROCESS CLI — NEVER SOURCE IT.

set -u

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
RESOLVE="$SCRIPT_DIR/resolve-model.sh"
MERGE="$SCRIPT_DIR/resolve-concurrency.sh"

PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); echo "PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "FAIL: $1" >&2; }

TMP=$(mktemp -d "${TMPDIR:-/tmp}/model-map-concurrency-test.XXXXXX")
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

git init -q "$TMP" || { echo "FAIL: git init" >&2; exit 1; }
cd "$TMP" || { echo "FAIL: cd $TMP" >&2; exit 1; }

OUTF="$TMP/stdout.txt"
ERRF="$TMP/stderr.txt"
MAP=".claude/dev-team/models.local.json"
REPO_MAP=".claude/dev-team/models.json"
FAKE_HOME="$TMP/home"
GLOBAL_MAP="$FAKE_HOME/.claude/dev-team/models.json"
mkdir -p "$FAKE_HOME"

UNSET_MARK="__UNSET__"

# run — resolve-model.sh; COUNCIL_CONCURRENCY is never consumed by it,
# but scrub it so the two runners share one fixture state.
run() {
  RC=0
  : >"$OUTF"
  : >"$ERRF"
  env -u COUNCIL_CONCURRENCY HOME="$FAKE_HOME" bash "$RESOLVE" "$@" >"$OUTF" 2>"$ERRF" || RC=$?
}

# runm — resolve-concurrency.sh with COUNCIL_CONCURRENCY set to $MCAP
# (empty string = set-empty; MCAP unset = env -u).
runm() {
  RC=0
  : >"$OUTF"
  : >"$ERRF"
  if [ "${MCAP-$UNSET_MARK}" = "$UNSET_MARK" ]; then
    env -u COUNCIL_CONCURRENCY HOME="$FAKE_HOME" bash "$MERGE" "$@" >"$OUTF" 2>"$ERRF" || RC=$?
  else
    env HOME="$FAKE_HOME" COUNCIL_CONCURRENCY="$MCAP" bash "$MERGE" "$@" >"$OUTF" 2>"$ERRF" || RC=$?
  fi
}

check() {
  local id=$1 want_rc=$2 want_out=$3 want_err=${4-}
  local got_out got_err ok=1
  got_out=$(cat "$OUTF")
  got_err=$(cat "$ERRF")
  [ "$RC" -eq "$want_rc" ] || ok=0
  [ "$got_out" = "$want_out" ] || ok=0
  if [ -z "$want_err" ]; then
    [ -z "$got_err" ] || ok=0
  else
    printf '%s\n' "$got_err" | grep -F -q -- "$want_err" || ok=0
  fi
  if [ "$ok" -eq 1 ]; then
    pass "$id"
  else
    fail "$id rc=$RC (want $want_rc) out='$got_out' (want '$want_out') err='$got_err' (need '$want_err')"
  fi
}

write_map() {
  mkdir -p .claude/dev-team
  cat >"$MAP"
}

write_repo() {
  mkdir -p .claude/dev-team
  cat >"$REPO_MAP"
}

write_global() {
  mkdir -p "$(dirname "$GLOBAL_MAP")"
  cat >"$GLOBAL_MAP"
}

clear_layers() {
  rm -rf "$TMP/.claude" "$FAKE_HOME/.claude"
}

NOJQ_BIN="$TMP/nojq-bin"
mkdir -p "$NOJQ_BIN"
BASH_ABS=$(command -v bash)
for c in bash git dirname pwd; do
  p=$(command -v "$c" 2>/dev/null) || continue
  ln -sf "$p" "$NOJQ_BIN/$(basename "$p")"
done

# =============================================================================
# M30/M32 — unset: empty stdout, exit 0, no warn
# =============================================================================
clear_layers
run --concurrency
check "M30-no-layers" 0 "" ""
if [ ! -e "$TMP/.claude" ] && [ ! -e "$FAKE_HOME/.claude" ]; then
  pass "M30-readonly"
else
  fail "M30-readonly created path under $TMP/.claude or $FAKE_HOME/.claude"
fi

write_map <<'EOF'
{"version":1,"agents":{"ic4":"haiku"}}
EOF
run --concurrency
check "M30-key-absent" 0 "" ""

write_map <<'EOF'
{"version":1,"concurrency":null}
EOF
run --concurrency
check "M30-null" 0 "" ""

write_map <<'EOF'
{"version":1,"concurrency":""}
EOF
run --concurrency
check "M30-empstring" 0 "" ""

write_map <<'EOF'
{"version":1,"concurrency":4}
EOF
run --concurrency
check "M30-empstring-then-valid" 0 "4" ""
clear_layers

# =============================================================================
# M31/M32 — valid caps
# =============================================================================
write_map <<'EOF'
{"version":1,"concurrency":1}
EOF
run --concurrency
check "M31-one" 0 "1" ""

write_map <<'EOF'
{"version":1,"concurrency":4}
EOF
run --concurrency
check "M31-valid" 0 "4" ""

write_map <<'EOF'
{"version":1,"concurrency":1000000}
EOF
run --concurrency
check "M31-no-ceiling" 0 "1000000" ""

# extra argv after the flag is ignored (M31)
write_map <<'EOF'
{"version":1,"concurrency":4}
EOF
run --concurrency ic4
check "M31-extra-argv" 0 "4" ""

# =============================================================================
# M33 — invalid stored values: exit 64 + stderr, fail-closed (no fall-through)
# =============================================================================
clear_layers
write_map <<'EOF'
{"version":1,"concurrency":0}
EOF
run --concurrency
check "M33-zero" 64 "" "concurrency is not an integer"

write_map <<'EOF'
{"version":1,"concurrency":-1}
EOF
run --concurrency
check "M33-neg" 64 "" "concurrency is not an integer"

write_map <<'EOF'
{"version":1,"concurrency":"2"}
EOF
run --concurrency
check "M33-string" 64 "" "concurrency is not an integer"

write_map <<'EOF'
{"version":1,"concurrency":true}
EOF
run --concurrency
check "M33-bool" 64 "" "concurrency is not an integer"

write_map <<'EOF'
{"version":1,"concurrency":[]}
EOF
run --concurrency
check "M33-array" 64 "" "concurrency is not an integer"

write_map <<'EOF'
{"version":1,"concurrency":{}}
EOF
run --concurrency
check "M33-object" 64 "" "concurrency is not an integer"

write_map <<'EOF'
{"version":1,"concurrency":2.5}
EOF
run --concurrency
check "M33-float" 64 "" "concurrency is not an integer"

# fail-closed: an invalid local cap does not fall through to a valid repo cap
write_repo <<'EOF'
{"version":1,"concurrency":3}
EOF
run --concurrency
check "M33-no-fallthrough" 64 "" "concurrency is not an integer"
clear_layers

# =============================================================================
# M32 — layer precedence local > repo > global; unparseable layer skips
# =============================================================================
write_map <<'EOF'
{"version":1,"concurrency":4}
EOF
write_repo <<'EOF'
{"version":1,"concurrency":2}
EOF
write_global <<'EOF'
{"version":1,"concurrency":8}
EOF
run --concurrency
check "M32-prec-local" 0 "4" ""
rm -f "$MAP"
run --concurrency
check "M32-prec-repo" 0 "2" ""
rm -f "$REPO_MAP"
run --concurrency
check "M32-prec-global" 0 "8" ""
clear_layers

write_map <<'EOF'
{
EOF
write_repo <<'EOF'
{"version":1,"concurrency":3}
EOF
run --concurrency
check "M32-unparseable-skip" 0 "3" "unparseable JSON at"
clear_layers

# null local falls through to a valid repo cap (absent/null/"" = skip layer)
write_map <<'EOF'
{"version":1,"concurrency":null}
EOF
write_repo <<'EOF'
{"version":1,"concurrency":5}
EOF
run --concurrency
check "M32-null-fallthrough" 0 "5" ""
clear_layers

# =============================================================================
# M32 — jq absent: empty stdout + existing Tier default warn; layers unread
# =============================================================================
write_map <<'EOF'
{"version":1,"concurrency":4}
EOF
RC=0
: >"$OUTF"
: >"$ERRF"
env -u COUNCIL_CONCURRENCY HOME="$FAKE_HOME" PATH="$NOJQ_BIN" "$BASH_ABS" "$RESOLVE" --concurrency >"$OUTF" 2>"$ERRF" || RC=$?
check "M32-jq-absent" 0 "" "jq not found; using Tier default"
clear_layers

# =============================================================================
# M31/AC5 — isolation: the named-roster paths ignore the concurrency key,
# including an invalid stored cap (exit 0, model emit)
# =============================================================================
write_map <<'EOF'
{"version":1,"agents":{"ic4":"haiku"},"effort":{"ic4":"high"},"concurrency":4}
EOF
run ic4
check "ISO-model-valid-cap" 0 "haiku" ""
run --effort ic4
check "ISO-effort-valid-cap" 0 "high" ""
run --mapped ic4
check "ISO-mapped-valid-cap" 0 "mapped" ""

write_map <<'EOF'
{"version":1,"agents":{"ic4":"haiku"},"concurrency":0}
EOF
run ic4
check "ISO-model-bad-cap" 0 "haiku" ""
run --mapped ic4
check "ISO-mapped-bad-cap" 0 "mapped" ""

write_map <<'EOF'
{"version":1,"agents":{"ic4":"haiku"},"concurrency":{"a":1}}
EOF
run ic4
check "ISO-model-obj-cap" 0 "haiku" ""

# trailing --concurrency on the agent path is extra argv, not a mode switch
write_map <<'EOF'
{"version":1,"agents":{"ic4":"haiku"},"concurrency":4}
EOF
run ic4 --concurrency
check "ISO-agent-then-flag" 0 "haiku" ""
clear_layers

# =============================================================================
# AC4 — merge helper: unset everywhere → empty, exit 0
# =============================================================================
runm
check "AC4-merge-unset" 0 "" ""

# =============================================================================
# AC4 — merge precedence: flag > env > map
# =============================================================================
write_map <<'EOF'
{"version":1,"concurrency":4}
EOF
runm
check "AC4-merge-map-only" 0 "4" ""
MCAP=3 runm
check "AC4-merge-env-beats-map" 0 "3" ""
MCAP=3 runm --flag 2
check "AC4-merge-flag-beats-env" 0 "2" ""
MCAP=__UNSET__ runm --flag 2
check "AC4-merge-flag-beats-map" 0 "2" ""
runm --flag 2
check "AC4-merge-flag-invalid-beats-map" 0 "2" ""
clear_layers
MCAP=3 runm
check "AC4-merge-env-only" 0 "3" ""
MCAP="" runm
check "AC4-merge-empty-env-is-unset" 0 "" ""
write_map <<'EOF'
{"version":1,"concurrency":4}
EOF
MCAP="" runm
check "AC4-merge-empty-env-falls-to-map" 0 "4" ""
clear_layers

# =============================================================================
# AC5 — merge helper invalid flag/env → 64 + usage; map 64 propagates
# =============================================================================
runm --flag
check "AC5-flag-missing" 64 "" "usage: resolve-concurrency.sh [--flag <N>]"
runm --flag abc
check "AC5-flag-noninteger" 64 "" "usage: resolve-concurrency.sh [--flag <N>]"
runm --flag 0
check "AC5-flag-zero" 64 "" "usage: resolve-concurrency.sh"
runm --flag -2
check "AC5-flag-neg" 64 "" "usage: resolve-concurrency.sh"
runm --flag 2.5
check "AC5-flag-float" 64 "" "usage: resolve-concurrency.sh"

MCAP=two runm
check "AC5-env-noninteger" 64 "" "usage: resolve-concurrency.sh"
MCAP=0 runm
check "AC5-env-zero" 64 "" "usage: resolve-concurrency.sh"

# a valid flag short-circuits before the env and the map are consulted
write_map <<'EOF'
{"version":1,"concurrency":0}
EOF
MCAP=9 runm --flag 2
check "AC5-flag-wins-over-invalid-map" 0 "2" ""

# an invalid flag exits 64 even when the map is valid
write_map <<'EOF'
{"version":1,"concurrency":4}
EOF
runm --flag x
check "AC5-invalid-flag-64-valid-map" 64 "" "usage: resolve-concurrency.sh"

# map 64 propagates: invalid stored value, no flag/env
write_map <<'EOF'
{"version":1,"concurrency":"4"}
EOF
MCAP=__UNSET__ runm
check "AC5-map-64-propagates" 64 "" "concurrency is not an integer"

# valid env shields an invalid map
MCAP=3 runm
check "AC5-env-shields-invalid-map" 0 "3" ""
clear_layers

# =============================================================================
# AC14/M10 — merge helper is read-only: no map paths created
# =============================================================================
if [ ! -e "$TMP/.claude" ] && [ ! -e "$FAKE_HOME/.claude" ]; then
  pass "M10-merge-readonly"
else
  fail "M10-merge-readonly created path under $TMP/.claude or $FAKE_HOME/.claude"
fi

# =============================================================================
# Summary
# =============================================================================
RC_SUM=0
if [ "$FAIL" -ne 0 ]; then
  RC_SUM=1
fi
echo ""
echo "PASS=$PASS FAIL=$FAIL"
echo "VERIFY exit=$RC_SUM"
exit "$RC_SUM"
