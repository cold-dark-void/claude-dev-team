#!/usr/bin/env bash
# embed-resolver-test.sh — rv-w2-10: the agent embed resolver resolves the literal
# CLAUDE_PLUGIN_ROOT token as tier 0, with PDH and cwd/cache fallbacks (SPEC-002
# tier 1b + CDT-234). Static checks on the partial + every managed agent copy,
# plus a functional probe of the extracted resolver snippet.
#
# Marketplace-only layout simulation: no cwd skills/, empty HOME (no cache) —
# only the substituted token can resolve. Run: bash skills/agent-memory/embed-resolver-test.sh
set -u

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
PARTIAL="$HERE/protocol.md"
AGENTS="pm devops ds ic4 ic5 qa tech-lead"

PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); echo "PASS: $*"; }
bad() { FAIL=$((FAIL + 1)); echo "FAIL: $*"; }

TIER0="if [ \"\${_emb_pr#\\\$}\" = \"\$_emb_pr\" ] && [ -f \"\$_emb_pr/skills/memory-store/embed-one.sh\" ]; then"
TOKEN_LINE="_emb_pr='\${CLAUDE_PLUGIN_ROOT}'"
OLD_LINE='  EMB=$(bash "$PDH/skills/plugin-dir.sh" file skills/memory-store/embed-one.sh 2>/dev/null || true)'

# --- 1. The partial carries the tier-0 token arm ------------------------------
if grep -qF "$TIER0" "$PARTIAL" && grep -qF "$TOKEN_LINE" "$PARTIAL"; then
  ok "protocol.md embed resolver has the CLAUDE_PLUGIN_ROOT tier-0 arm"
else
  bad "protocol.md missing embed tier-0 arm"
fi

# --- 2. Every managed agent copy carries it too (drift is also caught by
#        sync-includes check; this asserts the behavior directly) --------------
for a in $AGENTS; do
  if grep -qF "$TIER0" "$ROOT/agents/$a.md"; then
    ok "agents/$a.md embed tier-0 arm present"
  else
    bad "agents/$a.md missing embed tier-0 arm"
  fi
done

# --- 3. The MROOT derivation is the collapsed one-liner (rv-w2-10), 4x per copy,
#        and the old 3-line form is gone ---------------------------------------
ONE_LINER='MROOT=$(cd "$(dirname "$(git rev-parse --git-common-dir 2>/dev/null)")" && pwd || pwd)'
OLD_FIRST='_gc=$(git rev-parse --git-common-dir 2>/dev/null) \'
n=$(grep -cF "$ONE_LINER" "$PARTIAL")
[ "$n" -eq 4 ] && ok "protocol.md has 4 one-line MROOT derivations" \
  || bad "protocol.md MROOT one-liner count $n (want 4)"
if grep -qF "$OLD_FIRST" "$PARTIAL"; then
  bad "protocol.md still has the 3-line MROOT derivation"
else
  ok "protocol.md 3-line MROOT derivation removed"
fi
for a in $AGENTS; do
  if grep -qF "$OLD_FIRST" "$ROOT/agents/$a.md"; then
    bad "agents/$a.md still has the 3-line MROOT derivation"
  else
    ok "agents/$a.md MROOT collapsed"
  fi
done

# --- 4. Functional: marketplace-only layout -----------------------------------
FIX=$(mktemp -d "${TMPDIR:-/tmp}/embed-resolver.XXXXXX")
trap 'rm -rf "$FIX"' EXIT
FAKE_PLUGIN="$FIX/substituted-plugin"
mkdir -p "$FAKE_PLUGIN/skills/memory-store" "$FIX/home" "$FIX/cwd"
: > "$FAKE_PLUGIN/skills/memory-store/embed-one.sh"

# Extract the resolver snippet (tier-0 arm through the tier-1 PDH line) and run
# it twice: once with the token substituted (as Claude Code does per SPEC-002
# tier 1b), once unsubstituted. No cwd skills/, empty HOME, PDH empty in both.
extract_snippet() { # extract_snippet <dest>
  awk '
    /^  # Embed resolver tiers:/ { f = 1 }
    f { print }
    f && /^  \[ -n "\$EMB" \] \|\| EMB=/ { exit }
  ' "$PARTIAL" > "$1"
  [ -s "$1" ]
}

run_snippet() { # run_snippet <snippet> ; echoes EMB value
  # Marketplace-only layout: cwd has no skills/, HOME has no cache, PDH empty.
  cat > "$FIX/runner.sh" <<RUNNER
cd "$FIX/cwd" || exit 9
HOME="$FIX/home"
PDH=""
EMB=""
. "$1"
printf '%s' "\$EMB"
RUNNER
  timeout 30 bash "$FIX/runner.sh"
}

if extract_snippet "$FIX/tier0.sh"; then
  ok "resolver snippet extracted from protocol.md"
else
  bad "resolver snippet extraction failed"
fi

# 4a. Substituted token resolves in a marketplace-only layout.
sed_ok=1
awk -v rep="$FAKE_PLUGIN" '{ gsub(/\$\{CLAUDE_PLUGIN_ROOT\}/, rep); print }' \
  "$FIX/tier0.sh" > "$FIX/tier0-substituted.sh" || sed_ok=0
if [ "$sed_ok" -eq 1 ]; then
  EMB=$(run_snippet "$FIX/tier0-substituted.sh")
  if [ "$EMB" = "$FAKE_PLUGIN/skills/memory-store/embed-one.sh" ]; then
    ok "substituted token resolves in marketplace-only layout"
  else
    bad "marketplace-only lookup got '$EMB'"
  fi
else
  bad "token substitution failed"
fi

# 4b. Unsubstituted token + no PDH + no cwd copy + empty HOME cache: EMB stays
#     empty — the pre-existing fail-mode is preserved (SPEC-002 CDT-234).
EMB=$(run_snippet "$FIX/tier0.sh")
if [ -z "$EMB" ]; then
  ok "unsubstituted token falls through to empty EMB (fail-mode preserved)"
else
  bad "unsubstituted token unexpectedly resolved '$EMB'"
fi

# 4c. Old resolver (PDH line only, no tier 0) would have missed here — the
#     negative control that fails on the pre-rv-w2-10 code.
if ! grep -qF "$TIER0" "$FIX/tier0.sh" ; then
  bad "snippet lost the tier-0 arm"
else
  ok "tier-0 arm is the resolving tier in the marketplace-only layout"
fi

echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
