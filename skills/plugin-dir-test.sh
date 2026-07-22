#!/usr/bin/env bash
# plugin-dir-test.sh — bite-tests for plugin-dir.sh (CDT-46-C3 Task 15 Phase A)
#
# Machine-check: bash skills/plugin-dir-test.sh  (exit 0)
# THIS SCRIPT IS A SUBPROCESS CLI — NEVER SOURCE IT.
#
# Critical: tilde-mapped sort path is load-bearing. Tests MUST prove the SORT
# path alone (no CLAUDE_PLUGIN_ROOT) picks final 1.0.0 over 1.0.0-pre.N.

set -u

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
LIB="$SCRIPT_DIR/plugin-dir.sh"

PASS=0
FAIL=0

assert_eq() {
  local name="$1" got="$2" want="$3"
  if [ "$got" = "$want" ]; then
    PASS=$((PASS + 1))
    echo "  ok  $name"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL $name: got=[$got] want=[$want]"
  fi
}

assert_contains() {
  local name="$1" hay="$2" needle="$3"
  if printf '%s' "$hay" | grep -qF -- "$needle"; then
    PASS=$((PASS + 1))
    echo "  ok  $name"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL $name: missing [$needle] in: [$hay]"
  fi
}

assert_rc() {
  local name="$1" got="$2" want="$3"
  if [ "$got" -eq "$want" ]; then
    PASS=$((PASS + 1))
    echo "  ok  $name"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL $name: rc=$got want=$want"
  fi
}

# --- pipeline unit (no HOME, no env) ---
echo "== ver_pick pipeline =="
got=$(printf '1.0.0-pre.4\n1.0.0\n' | sed 's/-pre\./~pre./' | sort -V | tail -1 | sed 's/~pre\./-pre./')
assert_eq "pipeline final over pre" "$got" "1.0.0"

got=$(printf '1.0.0-pre.4\n1.0.0-pre.9\n' | sed 's/-pre\./~pre./' | sort -V | tail -1 | sed 's/~pre\./-pre./')
assert_eq "pipeline highest pre when no final" "$got" "1.0.0-pre.9"

got=$(printf '0.80.1\n1.0.0-pre.1\n' | sed 's/-pre\./~pre./' | sort -V | tail -1 | sed 's/~pre\./-pre./')
assert_eq "pipeline pre above older final" "$got" "1.0.0-pre.1"

bare=$(printf '1.0.0-pre.4\n1.0.0\n' | sort -V | tail -1)
assert_eq "hazard: bare sort -V prefers pre" "$bare" "1.0.0-pre.4"

# --- resolve: dev checkout ---
# MROOT is worktree-aware (git-common-dir) — from a linked worktree the
# shared main checkout wins when the relpath exists there.
echo "== dev-checkout =="
_gc=$(git rev-parse --git-common-dir 2>/dev/null) \
  && MROOT=$(cd "$(dirname "$_gc")" && pwd) \
  || MROOT=$(pwd)
out=$(bash "$LIB" file skills/plugin-dir.sh)
rc=$?
assert_rc "dev file rc" "$rc" 0
assert_eq "dev file path" "$out" "$MROOT/skills/plugin-dir.sh"

# --- resolve: synthetic cache, NO CLAUDE_PLUGIN_ROOT (sort path alone) ---
echo "== cache sort path (no CLAUDE_PLUGIN_ROOT) =="
TMP=$(mktemp -d "${TMPDIR:-/tmp}/pdh-test.XXXXXX")
trap 'rm -rf "$TMP"' EXIT

# Foreign cwd so tier-1 (dev MROOT) cannot match the probe relpath.
FOREIGN="$TMP/foreign"
mkdir -p "$FOREIGN"
# Synthetic HOME cache: both final and pre under the marketplace slug.
CACHE_ROOT="$TMP/home/.claude/plugins/cache/cold-dark-void/dev-team"
PROBE="skills/.pdh-sort-probe"
for VER in 1.0.0-pre.4 1.0.0 0.99.0; do
  mkdir -p "$CACHE_ROOT/$VER/skills"
  printf 'probe-%s\n' "$VER" > "$CACHE_ROOT/$VER/$PROBE"
done

# Unset CLAUDE_PLUGIN_ROOT explicitly; override HOME only.
unset CLAUDE_PLUGIN_ROOT || true
out=$(
  cd "$FOREIGN" &&
  env -u CLAUDE_PLUGIN_ROOT HOME="$TMP/home" bash "$LIB" file "$PROBE"
)
rc=$?
assert_rc "cache final-over-pre rc" "$rc" 0
assert_contains "cache final-over-pre path has /1.0.0/" "$out" "/1.0.0/"
if printf '%s' "$out" | grep -qF '1.0.0-pre'; then
  FAIL=$((FAIL + 1))
  echo "  FAIL cache final-over-pre must not pick pre: [$out]"
else
  PASS=$((PASS + 1))
  echo "  ok  cache final-over-pre not a pre path"
fi
assert_eq "cache final-over-pre content" "$(cat "$out")" "probe-1.0.0"

# Pre-only: highest pre wins when no final present.
rm -rf "$CACHE_ROOT/1.0.0"
out=$(
  cd "$FOREIGN" &&
  env -u CLAUDE_PLUGIN_ROOT HOME="$TMP/home" bash "$LIB" file "$PROBE"
)
rc=$?
assert_rc "cache pre-only rc" "$rc" 0
assert_contains "cache pre-only path" "$out" "/1.0.0-pre.4/"

# Not found
out=$(
  cd "$FOREIGN" &&
  env -u CLAUDE_PLUGIN_ROOT HOME="$TMP/home" bash "$LIB" file skills/no-such-file-xyz 2>/dev/null
)
rc=$?
assert_rc "not-found rc" "$rc" 3
assert_eq "not-found stdout empty" "$out" ""

# Slug defined once
slug_count=$(grep -cF 'cold-dark-void' "$LIB" || true)
assert_eq "slug literal once" "$slug_count" "1"

# Bootstrap stanza sort path (inline, no env) — same pipeline as SPEC-002
echo "== bootstrap stanza sort path =="
mkdir -p "$CACHE_ROOT/1.0.0/skills" "$CACHE_ROOT/1.0.0-pre.9/skills"
: > "$CACHE_ROOT/1.0.0/skills/plugin-dir.sh"
: > "$CACHE_ROOT/1.0.0-pre.9/skills/plugin-dir.sh"
pdh=$(
  cd "$FOREIGN" &&
  env -u CLAUDE_PLUGIN_ROOT HOME="$TMP/home" bash -c '
    PDH=$( { [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -f "$CLAUDE_PLUGIN_ROOT/skills/plugin-dir.sh" ] && printf "%s\n" "$CLAUDE_PLUGIN_ROOT"; } || { [ -f skills/plugin-dir.sh ] && pwd; } || find ~/.claude/plugins/cache -path "*/dev-team/*/skills/plugin-dir.sh" 2>/dev/null | sed "s/-pre\./~pre./" | sort -V | tail -1 | sed "s/~pre\./-pre./" | xargs -r dirname | xargs -r dirname )
    printf "%s\n" "$PDH"
  '
)
assert_contains "stanza picks final PDH" "$pdh" "/1.0.0"
if printf '%s' "$pdh" | grep -qF '1.0.0-pre'; then
  FAIL=$((FAIL + 1))
  echo "  FAIL stanza must not pick pre: [$pdh]"
else
  PASS=$((PASS + 1))
  echo "  ok  stanza not a pre path"
fi

echo
echo "PASS=$PASS FAIL=$FAIL"
if [ "$FAIL" -ne 0 ]; then
  exit 1
fi
exit 0
