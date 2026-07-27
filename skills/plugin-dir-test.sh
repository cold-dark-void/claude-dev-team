#!/usr/bin/env bash
# plugin-dir-test.sh — bite-tests for plugin-dir.sh (CDT-46-C3 Task 15 Phase A)
#
# Machine-check: bash skills/plugin-dir-test.sh  (exit 0)
# THIS SCRIPT IS A SUBPROCESS CLI — NEVER SOURCE IT.
#
# Critical: tilde-mapped sort path is load-bearing. Tests MUST prove the SORT
# path alone (no CLAUDE_PLUGIN_ROOT) picks final 1.0.0 over 1.0.0-pre.N.
# CDT-53-13: also greps the plugin tree for bare product `sort -V | tail` sites.

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
# CDT-82: prefer show-toplevel (worktree) so feat/* dogfood is not shadowed
# by the main checkout via git-common-dir (master may still be legacy handoff).
echo "== dev-checkout =="
WTROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
out=$(bash "$LIB" file skills/plugin-dir.sh)
rc=$?
assert_rc "dev file rc" "$rc" 0
assert_eq "dev file path" "$out" "$WTROOT/skills/plugin-dir.sh"

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
# Canonical stanza (CDT-82): force → cwd → marketplace clone → cache ver_pick
PDH_STANZA='PDH=$( { [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -f "$CLAUDE_PLUGIN_ROOT/skills/plugin-dir.sh" ] && printf "%s\n" "$CLAUDE_PLUGIN_ROOT"; } || { [ -f skills/plugin-dir.sh ] && pwd; } || { for _mp in "$HOME"/.claude/plugins/marketplaces/*/; do [ -f "${_mp}skills/plugin-dir.sh" ] && [ -f "${_mp}agents/pm.md" ] && printf "%s\n" "${_mp%/}" && break; done; } || find ~/.claude/plugins/cache -path "*/dev-team/*/skills/plugin-dir.sh" 2>/dev/null | sed "s/-pre\./~pre./" | sort -V | tail -1 | sed "s/~pre\./-pre./" | xargs -r dirname | xargs -r dirname )'
pdh=$(
  cd "$FOREIGN" &&
  env -u CLAUDE_PLUGIN_ROOT HOME="$TMP/home" bash -c "
    $PDH_STANZA
    printf '%s\n' \"\$PDH\"
  "
)
assert_contains "stanza picks final PDH" "$pdh" "/1.0.0"
if printf '%s' "$pdh" | grep -qF '1.0.0-pre'; then
  FAIL=$((FAIL + 1))
  echo "  FAIL stanza must not pick pre: [$pdh]"
else
  PASS=$((PASS + 1))
  echo "  ok  stanza not a pre path"
fi

# --- CDT-82: same-version marketplace STM vs cache legacy ---
echo "== CDT-82 same-version STM over legacy cache =="
# Fresh HOME so leftover 1.0.0-pre dirs do not interfere.
rm -rf "$TMP/home"
CACHE_ROOT="$TMP/home/.claude/plugins/cache/cold-dark-void/dev-team"
MP_ROOT="$TMP/home/.claude/plugins/marketplaces/cold-dark-void"
mkdir -p "$CACHE_ROOT/1.0.3/skills/handoff" "$CACHE_ROOT/1.0.3/.claude-plugin"
mkdir -p "$MP_ROOT/skills/handoff" "$MP_ROOT/.claude-plugin" "$MP_ROOT/agents" "$MP_ROOT/skills"

# Marketplace signature files (slug-free bootstrap discovery).
: > "$MP_ROOT/skills/plugin-dir.sh"
: > "$MP_ROOT/agents/pm.md"
printf '%s\n' '{"name":"dev-team","version":"1.0.3"}' > "$MP_ROOT/.claude-plugin/plugin.json"
printf '%s\n' '{"name":"dev-team","version":"1.0.3"}' > "$CACHE_ROOT/1.0.3/.claude-plugin/plugin.json"

# Legacy cache: --sections only (five-extractor).
cat > "$CACHE_ROOT/1.0.3/skills/handoff/prepass.sh" <<'LEG'
#!/usr/bin/env bash
# prepass.sh finalize --uuid <u> --sections <dir>
case "$1" in
  --sections) ;;
esac
LEG
# Marketplace STM: --events (CDT-79).
cat > "$MP_ROOT/skills/handoff/prepass.sh" <<'STM'
#!/usr/bin/env bash
# prepass.sh finalize --uuid <u> --events <dir|file>
case "$1" in
  --events) ;;
esac
STM
# Mirror probe into both so file resolve can hit either.
printf 'legacy\n' > "$CACHE_ROOT/1.0.3/skills/handoff/prepass.sh.tag"
printf 'stm\n' > "$MP_ROOT/skills/handoff/prepass.sh.tag"
# Also need plugin-dir.sh under cache for bootstrap cache tier.
mkdir -p "$CACHE_ROOT/1.0.3/skills"
: > "$CACHE_ROOT/1.0.3/skills/plugin-dir.sh"

out=$(
  cd "$FOREIGN" &&
  env -u CLAUDE_PLUGIN_ROOT HOME="$TMP/home" bash "$LIB" file skills/handoff/prepass.sh 2>"$TMP/stderr-shadow"
)
rc=$?
assert_rc "CDT-82 same-ver prefer STM rc" "$rc" 0
assert_contains "CDT-82 path is marketplace" "$out" "/marketplaces/cold-dark-void/"
if printf '%s' "$out" | grep -qF '/cache/'; then
  FAIL=$((FAIL + 1))
  echo "  FAIL CDT-82 must not pick cache: [$out]"
else
  PASS=$((PASS + 1))
  echo "  ok  CDT-82 not a cache path"
fi
assert_contains "CDT-82 stderr names shadow" "$(cat "$TMP/stderr-shadow")" "same-version shadow"
if grep -q -- '--events' "$out" && ! grep -q -- '--sections' "$out"; then
  PASS=$((PASS + 1))
  echo "  ok  CDT-82 content is STM file"
else
  FAIL=$((FAIL + 1))
  echo "  FAIL CDT-82 content is STM file: $(head -3 "$out" | tr '\n' ' ')"
fi

# verify subcommand: marketplace STM → OK
v_out=$(
  cd "$FOREIGN" &&
  env -u CLAUDE_PLUGIN_ROOT HOME="$TMP/home" bash "$LIB" verify 2>/dev/null
)
v_rc=$?
assert_rc "CDT-82 verify STM rc" "$v_rc" 0
assert_contains "CDT-82 verify marker stm" "$v_out" "stm_marker=stm"
assert_contains "CDT-82 verify OK STM" "$v_out" "OK STM"

# Force path: CLAUDE_PLUGIN_ROOT wins even if it is the legacy cache (operator choice).
out=$(
  cd "$FOREIGN" &&
  env CLAUDE_PLUGIN_ROOT="$CACHE_ROOT/1.0.3" HOME="$TMP/home" bash "$LIB" file skills/handoff/prepass.sh 2>/dev/null
)
rc=$?
assert_rc "CDT-82 force root rc" "$rc" 0
assert_contains "CDT-82 force uses cache root" "$out" "/cache/cold-dark-void/dev-team/1.0.3/"

# Bootstrap stanza prefers marketplace over same-version cache.
pdh=$(
  cd "$FOREIGN" &&
  env -u CLAUDE_PLUGIN_ROOT HOME="$TMP/home" bash -c "
    $PDH_STANZA
    printf '%s\n' \"\$PDH\"
  "
)
assert_contains "CDT-82 stanza marketplace" "$pdh" "/marketplaces/cold-dark-void"

# Higher cache version still beats older marketplace (not a same-version shadow).
mkdir -p "$CACHE_ROOT/1.0.4/skills/handoff" "$CACHE_ROOT/1.0.4/.claude-plugin" "$CACHE_ROOT/1.0.4/skills"
printf '%s\n' '{"name":"dev-team","version":"1.0.4"}' > "$CACHE_ROOT/1.0.4/.claude-plugin/plugin.json"
cat > "$CACHE_ROOT/1.0.4/skills/handoff/prepass.sh" <<'C14'
#!/usr/bin/env bash
# 1.0.4 cache also STM
# --events
C14
: > "$CACHE_ROOT/1.0.4/skills/plugin-dir.sh"
out=$(
  cd "$FOREIGN" &&
  env -u CLAUDE_PLUGIN_ROOT HOME="$TMP/home" bash "$LIB" file skills/handoff/prepass.sh 2>/dev/null
)
rc=$?
assert_rc "CDT-82 higher cache wins rc" "$rc" 0
assert_contains "CDT-82 higher cache path" "$out" "/1.0.4/"

# verify fails when only legacy cache is visible (no marketplace STM) — soft WARN OK
rm -rf "$TMP/home/.claude/plugins/marketplaces"
rm -rf "$CACHE_ROOT/1.0.4"
# leave 1.0.3 legacy only
out=$(
  cd "$FOREIGN" &&
  env -u CLAUDE_PLUGIN_ROOT HOME="$TMP/home" bash "$LIB" file skills/handoff/prepass.sh 2>/dev/null
)
assert_contains "CDT-82 legacy-only path cache" "$out" "/1.0.3/"
v_out=$(
  cd "$FOREIGN" &&
  env -u CLAUDE_PLUGIN_ROOT HOME="$TMP/home" bash "$LIB" verify 2>/dev/null
)
v_rc=$?
assert_rc "CDT-82 verify legacy-only rc (warn, not fail)" "$v_rc" 0
assert_contains "CDT-82 verify legacy warn" "$v_out" "legacy"

# verify FAIL when marketplace STM exists but force picks legacy (operator can force;
# verify still reports resolved marker — force is intentional). Rebuild MP + force.
mkdir -p "$MP_ROOT/skills/handoff" "$MP_ROOT/.claude-plugin" "$MP_ROOT/agents" "$MP_ROOT/skills"
: > "$MP_ROOT/skills/plugin-dir.sh"
: > "$MP_ROOT/agents/pm.md"
printf '%s\n' '{"name":"dev-team","version":"1.0.3"}' > "$MP_ROOT/.claude-plugin/plugin.json"
cat > "$MP_ROOT/skills/handoff/prepass.sh" <<'STM'
#!/usr/bin/env bash
# --events
STM
# Without force, verify OK stm
v_rc=$(
  cd "$FOREIGN" &&
  env -u CLAUDE_PLUGIN_ROOT HOME="$TMP/home" bash "$LIB" verify >/dev/null 2>&1
  echo $?
)
assert_eq "CDT-82 verify recovers STM" "$v_rc" "0"

# --- CDT-53-13: tree-wide bare sort -V tilde-map uniformity gate ---
# Product version-picks MUST use:
#   sed 's/-pre./~pre./' | sort -V | tail -1 | sed 's/~pre./-pre./'
# Bare sort-then-tail without the tilde map is forbidden (final 1.0.0 loses to
# retained 1.0.0-pre.N). Allowlist: this file's intentional hazard assertion.
echo "== tree bare sort -V uniformity =="
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
bare_hits=$(
  python3 - "$REPO_ROOT" <<'PY'
import os, re, sys
root = sys.argv[1]
roots = [os.path.join(root, d) for d in ("commands", "skills", "agents")]
# Intentional: prove bare ranks wrong (this test file only).
allow_substr = (
    'bare=$(printf',
    'hazard: bare sort -V prefers pre',
)
pat = re.compile(r'sort\s+-V\s*\|\s*tail')
hits = []
self_name = "plugin-dir-test.sh"
for base in roots:
    for dp, dns, fns in os.walk(base):
        for fn in fns:
            if not (fn.endswith(".md") or fn.endswith(".sh")):
                continue
            # This file hosts the intentional bare hazard + the gate itself.
            if fn == self_name:
                continue
            path = os.path.join(dp, fn)
            try:
                lines = open(path, encoding="utf-8", errors="ignore").read().splitlines()
            except OSError:
                continue
            for i, line in enumerate(lines, 1):
                if not pat.search(line):
                    continue
                # Tilde-mapped pipeline on same line → OK
                if "s/-pre" in line and "~pre" in line:
                    continue
                # Comments / prose (not executable pipeline) → skip
                stripped = line.lstrip()
                if stripped.startswith("#") or stripped.startswith("<!--"):
                    continue
                # Markdown prose mentioning the pipeline without running it
                if line.strip().startswith("`") and "find " not in line and "$(" not in line:
                    continue
                # echo/printf diagnostic strings (not a version pick)
                if re.match(r'''^(echo|printf)\b''', stripped):
                    continue
                if any(a in line for a in allow_substr):
                    continue
                rel = os.path.relpath(path, root)
                hits.append(f"{rel}:{i}:{line.rstrip()}")
if hits:
    print("\n".join(hits))
PY
)
if [ -z "$bare_hits" ]; then
  PASS=$((PASS + 1))
  echo "  ok  no bare product sort -V | tail sites"
else
  FAIL=$((FAIL + 1))
  echo "  FAIL bare product sort -V | tail (need tilde map):"
  printf '%s\n' "$bare_hits" | sed 's/^/    /'
fi

echo
echo "PASS=$PASS FAIL=$FAIL"
if [ "$FAIL" -ne 0 ]; then
  exit 1
fi
exit 0
