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
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)

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
if [ -z "${TMP:-}" ] || [ ! -d "$TMP" ]; then
  echo "FATAL: mktemp -d failed — refusing to run (every rm -rf below is anchored on \$TMP)" >&2
  exit 70
fi
trap 'rm -rf "$TMP"' EXIT

# Every destructive path in this harness must be inside $TMP. Never rm a bare
# "$VAR/..." — an empty VAR turns "$VAR/home" into /home (CDT-232).
rm_under_tmp() {
  local target="$1"
  case "$target" in
    "$TMP"/*) ;;
    *) echo "FATAL: refusing rm -rf outside \$TMP: [$target]" >&2; exit 70 ;;
  esac
  rm -rf "$target"
}

# Foreign cwd so tier-1 (dev MROOT) cannot match the probe relpath.
FOREIGN="$TMP/foreign"
mkdir -p "$FOREIGN"

# CDT-232: prove branch 1 (cwd dev checkout) is bypassed, not just assumed.
if [ -f "$FOREIGN/skills/plugin-dir.sh" ]; then
  FAIL=$((FAIL + 1)); echo "  FAIL branch-1 not bypassed: dev checkout visible at \$FOREIGN"
else
  PASS=$((PASS + 1)); echo "  ok  branch 1 (cwd dev checkout) is bypassed"
fi

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
rm_under_tmp "$CACHE_ROOT/1.0.0"
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

# CDT-232: execute SPEC-002's canonical text, never a hand-copy. Two quoting
# layers (shell + bash -c) are what let the old re-quoted copy drift silently,
# and SPEC-021 C5 exempts this file, so no gate covered it.
SPEC002="$REPO_ROOT/specs/core/SPEC-002-plugin-infrastructure.md"
STANZA_SH="$TMP/canonical-stanza.sh"
awk '
  /^#{1,6}[[:space:]]+Locating `?plugin-dir\.sh`? itself[[:space:]]*$/ { h=1; next }
  h && /^```bash$/ { c=1; next }
  c && /^```$/ { exit }
  c { print }
' "$SPEC002" > "$STANZA_SH"
printf 'printf %s\\\\n "$PDH"\n' '%s' >> "$STANZA_SH"

# Vacuity guard — mirrors SPEC-021 C5's VACUOUS rule. A missing or unparseable
# canonical block must fail loudly, never silently pass.
canon_n=$(grep -c '^PDH=\$( {' "$STANZA_SH" || true)
if [ "$canon_n" != "1" ]; then
  FAIL=$((FAIL + 1))
  echo "  FAIL canonical stanza not extractable from SPEC-002 (found $canon_n PDH lines)"
  echo
  echo "PASS=$PASS FAIL=$FAIL"
  exit 1
fi
PASS=$((PASS + 1))
echo "  ok  canonical stanza extracted from SPEC-002 (1 PDH line)"

pdh=$(
  cd "$FOREIGN" &&
  env -u CLAUDE_PLUGIN_ROOT HOME="$TMP/home" bash "$STANZA_SH"
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
rm_under_tmp "$TMP/home"
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
  env -u CLAUDE_PLUGIN_ROOT HOME="$TMP/home" bash "$STANZA_SH"
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
rm_under_tmp "$TMP/home/.claude/plugins/marketplaces"
rm_under_tmp "$CACHE_ROOT/1.0.4"
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

# --- CDT-166: multi-slug / multi-path / stanza path_ver_pick ---
echo "== CDT-166 multi-slug path_ver_pick =="
# Fresh HOME: empty marketplace, two cache slugs where full-path sort -V loses.
rm_under_tmp "$TMP/home"
CACHE_BASE="$TMP/home/.claude/plugins/cache"
PROBE_MS="skills/.pdh-multislug-probe"
# zzz-wins-path: lower VER, wins naïve full-path sort -V (slug lexically high).
# aaa-loses-path: higher VER, loses naïve sort (slug lexically low).
mkdir -p "$CACHE_BASE/zzz-wins-path/dev-team/0.50.0/skills"
mkdir -p "$CACHE_BASE/aaa-loses-path/dev-team/2.0.0/skills"
printf 'probe-0.50.0\n' > "$CACHE_BASE/zzz-wins-path/dev-team/0.50.0/$PROBE_MS"
printf 'probe-2.0.0\n' > "$CACHE_BASE/aaa-loses-path/dev-team/2.0.0/$PROBE_MS"

# Hazard: naïve full-path tilde-map sort -V picks lower VER under zzz-*.
naive=$(
  find "$CACHE_BASE" -path "*/dev-team/*/$PROBE_MS" 2>/dev/null \
    | sed 's/-pre\./~pre./' | sort -V | tail -1 | sed 's/~pre\./-pre./'
)
assert_contains "hazard multi-slug full-path sort picks 0.50.0" "$naive" "/0.50.0/"

out=$(
  cd "$FOREIGN" &&
  env -u CLAUDE_PLUGIN_ROOT HOME="$TMP/home" bash "$LIB" file "$PROBE_MS"
)
rc=$?
assert_rc "CDT-166 multi-slug rc" "$rc" 0
assert_contains "CDT-166 multi-slug path has /2.0.0/" "$out" "/2.0.0/"
if printf '%s' "$out" | grep -qF '/0.50.0/'; then
  FAIL=$((FAIL + 1))
  echo "  FAIL CDT-166 multi-slug must not pick lower VER: [$out]"
else
  PASS=$((PASS + 1))
  echo "  ok  CDT-166 multi-slug not lower VER path"
fi
assert_eq "CDT-166 multi-slug content" "$(cat "$out")" "probe-2.0.0"

# AC-3: multi-path final vs pre across slugs
echo "== CDT-166 multi-path final-over-pre =="
rm_under_tmp "$TMP/home"
mkdir -p "$CACHE_BASE/slug-a/dev-team/1.0.0-pre.9/skills"
mkdir -p "$CACHE_BASE/slug-b/dev-team/1.0.0/skills"
PROBE_FP="skills/.pdh-finalpre-probe"
printf 'pre\n' > "$CACHE_BASE/slug-a/dev-team/1.0.0-pre.9/$PROBE_FP"
printf 'final\n' > "$CACHE_BASE/slug-b/dev-team/1.0.0/$PROBE_FP"
out=$(
  cd "$FOREIGN" &&
  env -u CLAUDE_PLUGIN_ROOT HOME="$TMP/home" bash "$LIB" file "$PROBE_FP"
)
rc=$?
assert_rc "CDT-166 multi-path final rc" "$rc" 0
assert_contains "CDT-166 multi-path path has /1.0.0/" "$out" "/1.0.0/"
if printf '%s' "$out" | grep -qF '1.0.0-pre'; then
  FAIL=$((FAIL + 1))
  echo "  FAIL CDT-166 multi-path must not pick pre: [$out]"
else
  PASS=$((PASS + 1))
  echo "  ok  CDT-166 multi-path not a pre path"
fi
assert_eq "CDT-166 multi-path content" "$(cat "$out")" "final"

# Equal-VER tie: prefer cold-dark-void over lexically later slug
echo "== CDT-166 equal-VER cold-dark-void prefer =="
rm_under_tmp "$TMP/home"
PROBE_EQ="skills/.pdh-eqver-probe"
mkdir -p "$CACHE_BASE/zzz-other/dev-team/1.2.3/skills"
mkdir -p "$CACHE_BASE/cold-dark-void/dev-team/1.2.3/skills"
printf 'zzz\n' > "$CACHE_BASE/zzz-other/dev-team/1.2.3/$PROBE_EQ"
printf 'cdv\n' > "$CACHE_BASE/cold-dark-void/dev-team/1.2.3/$PROBE_EQ"
out=$(
  cd "$FOREIGN" &&
  env -u CLAUDE_PLUGIN_ROOT HOME="$TMP/home" bash "$LIB" file "$PROBE_EQ"
)
rc=$?
assert_rc "CDT-166 equal-VER rc" "$rc" 0
assert_contains "CDT-166 equal-VER prefers cold-dark-void" "$out" "/cache/cold-dark-void/dev-team/1.2.3/"
assert_eq "CDT-166 equal-VER content" "$(cat "$out")" "cdv"

# CDT-232: equal-VER cold-dark-void preference, proven at STANZA level too.
: > "$CACHE_BASE/zzz-other/dev-team/1.2.3/skills/plugin-dir.sh"
: > "$CACHE_BASE/cold-dark-void/dev-team/1.2.3/skills/plugin-dir.sh"
pdh=$( cd "$FOREIGN" && env -u CLAUDE_PLUGIN_ROOT HOME="$TMP/home" bash "$STANZA_SH" )
assert_eq "stanza equal-VER prefers cold-dark-void" "$pdh" "$TMP/home/.claude/plugins/cache/cold-dark-void/dev-team/1.2.3"

# AC-6: stanza alone multi-slug → highest VER PDH
echo "== CDT-166 stanza multi-slug =="
rm_under_tmp "$TMP/home"
mkdir -p "$CACHE_BASE/zzz-wins-path/dev-team/0.50.0/skills"
mkdir -p "$CACHE_BASE/aaa-loses-path/dev-team/2.0.0/skills"
: > "$CACHE_BASE/zzz-wins-path/dev-team/0.50.0/skills/plugin-dir.sh"
: > "$CACHE_BASE/aaa-loses-path/dev-team/2.0.0/skills/plugin-dir.sh"
pdh=$(
  cd "$FOREIGN" &&
  env -u CLAUDE_PLUGIN_ROOT HOME="$TMP/home" bash "$STANZA_SH"
)
assert_contains "CDT-166 stanza multi-slug /2.0.0" "$pdh" "/2.0.0"
if printf '%s' "$pdh" | grep -qF '/0.50.0'; then
  FAIL=$((FAIL + 1))
  echo "  FAIL CDT-166 stanza multi-slug must not pick lower VER: [$pdh]"
else
  PASS=$((PASS + 1))
  echo "  ok  CDT-166 stanza multi-slug not lower VER"
fi

# --- CDT-232: empty-PDH fail-mode (SPEC-002:142 "no new failure path") ---
echo "== empty-PDH fail-mode (SPEC-002:142) =="
rm_under_tmp "$TMP/home"
mkdir -p "$TMP/home"
pdh=$( cd "$FOREIGN" && env -u CLAUDE_PLUGIN_ROOT HOME="$TMP/home" bash "$STANZA_SH" )
assert_eq "empty-PDH stanza yields empty PDH" "$pdh" ""
out=$( cd "$FOREIGN" && env -u CLAUDE_PLUGIN_ROOT HOME="$TMP/home" \
  bash -c 'PDH=""; bash "$PDH/skills/plugin-dir.sh" file skills/anything' 2>/dev/null )
rc=$?
assert_eq "empty-PDH stdout empty" "$out" ""
if [ "$rc" -ne 0 ]; then
  PASS=$((PASS + 1)); echo "  ok  empty-PDH exits non-zero (rc=$rc)"
else
  FAIL=$((FAIL + 1)); echo "  FAIL empty-PDH must exit non-zero"
fi

# --- CDT-53-13: tree-wide bare sort -V tilde-map uniformity gate ---
# Product version-picks MUST use:
#   sed 's/-pre./~pre./' | sort -V | tail -1 | sed 's/~pre./-pre./'
# Bare sort-then-tail without the tilde map is forbidden (final 1.0.0 loses to
# retained 1.0.0-pre.N). Allowlist: this file's intentional hazard assertion.
echo "== tree bare sort -V uniformity =="
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
