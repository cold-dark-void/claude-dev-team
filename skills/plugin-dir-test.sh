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

# --- CDT-234: cache-resolver coverage gate (T5a discovery + extraction) ----
# SPEC-002 "Cache-resolver coverage gate" / "Resolver uniformity" (AC7). This
# is a COVERAGE gate, not a checklist of known sites: it enumerates every
# non-stanza cache resolver in the tree mechanically so a new (unported) site
# fails the gate instead of shipping silently defective. Bash+awk/sed only
# (R4 ruling) — the existing python3 tree-gate block above is untouched.
echo "== CDT-234 cache-resolver discovery (coverage gate) =="

# Recorded expected count (v1.18.x): 9 single-line embed-one.sh locators + 3
# multiline hook-runtime bootstraps = 12. A mismatch in EITHER direction MUST
# fail loudly and print the discovered set — a 13th site is a gate failure
# until a human ports it or names it, not a silent pass.
EXPECTED_RESOLVER_COUNT=12

# Named exclusions — `path:line|rationale`. A site the predicate legitimately
# catches but which cannot be extracted and executed standalone. SPEC-002
# requires each one to be named WITH its rationale in the harness OUTPUT (not
# only in a comment): an exclusion a reader cannot see applied is not
# auditable, which is the same over-claim class as a predicate with a blind
# spot. A named exclusion that no longer matches the predicate is a stale
# exclusion (a hole) and MUST fail the gate.
NAMED_EXCLUSIONS=(
  "skills/plugin-dir.sh:278|canonical path_ver_pick ranker, not a copy of it: \$cache and \$rel are function-scope locals and path_ver_pick is a shell function at skills/plugin-dir.sh:47, so the line cannot be extracted and executed standalone; its behaviour is gated directly through the plugin-dir.sh CLI tier-4 fixtures above"
)

# Discovery: anchored on the SPEC-002 structural invariant — a slug-free
# `-path '*/dev-team/*'` (or double-quoted) glob — not on a `.claude/plugins/
# cache` literal spelling. CDT-232 proved the literal-path anchor vacuous: a
# variable-rooted `find "$cache" -path '*/dev-team/*/...'` never puts the
# literal cache path on the `find` line, so it was invisible to the old
# predicate while still being a live CDT-166-defective resolver shape (see
# skills/plugin-dir.sh:278 for the prevailing variable-rooted idiom in this
# tree). The glob may sit on the `find` line itself (single-line family, the
# plugin-dir.sh tier-4 idiom, and any other variable-rooted spelling) or on
# the very next physical line (the multiline hook-runtime family, whose
# `_pdh_hit=$(find ... \` wraps its arguments before `-path`); a site is
# resolved by walking one line back from the glob when the glob's own line
# has no `find`. The leading backslash on \-path keeps the pattern from
# being parsed as an option by grep implementations that reject a leading
# '-' in PATTERN (same rationale as derive_target below).
#
# Exclusions: canonical stanza emissions (`PDH=$( {`), skill-lint fixtures
# (deliberately drifted copies), this harness's own file (hosts the
# CDT-53-13 hazard assertion plus this gate), comment/prose lines (a line
# merely describing the shape — e.g. plugin-dir.sh's own header comment at
# line 26, "Find fallback: find ... -path '*/dev-team/*/<relpath>'" — is not
# a resolver), and the NAMED_EXCLUSIONS declared above. specs/ is prose, out
# of scope. A broad pattern exclusion would risk hiding a future genuine
# blind spot; naming the one file+line that cannot be extracted does not.
#
# The stages below are kept SEPARATE (rather than collapsed into one grep
# pipeline) so the harness can print the full audit chain:
#   predicate matches - mechanical (shape) exclusions - named exclusions
#     = extracted and executed
predicate_matches=$(
  cd "$REPO_ROOT" &&
  grep -rn --include='*.md' --include='*.sh' -E "\-path[[:space:]]+[\"']\*/dev-team/\*" \
    agents skills commands docs 2>/dev/null
)
predicate_count=$(printf '%s\n' "$predicate_matches" | grep -c . || true)

# Mechanical (shape) exclusions, applied in a fixed order so every excluded
# line is counted exactly once, in its first matching category.
excl_fixtures=$(printf '%s\n' "$predicate_matches" | grep -c 'skill-lint/fixtures/' || true)
stage_a=$(printf '%s\n' "$predicate_matches" | grep -v 'skill-lint/fixtures/' || true)
excl_self=$(printf '%s\n' "$stage_a" | grep -c '^skills/plugin-dir-test\.sh:' || true)
stage_b=$(printf '%s\n' "$stage_a" | grep -v '^skills/plugin-dir-test\.sh:' || true)
excl_stanza=$(printf '%s\n' "$stage_b" | grep -cF 'PDH=$( {' || true)
glob_lines=$(printf '%s\n' "$stage_b" | grep -vF 'PDH=$( {' || true)

# Remaining shape exclusion: comment/prose lines — a line that merely
# DESCRIBES the glob (plugin-dir.sh:26 documents the tier-4 fallback) and any
# glob line with no `find` on it or on the line immediately above it.
excl_prose=0
resolver_hits=""
if [ -n "$glob_lines" ]; then
  while IFS= read -r glob_line; do
    [ -n "$glob_line" ] || continue
    g_file=$(printf '%s' "$glob_line" | cut -d: -f1)
    g_line=$(printf '%s' "$glob_line" | cut -d: -f2)
    g_content=$(printf '%s' "$glob_line" | cut -d: -f3-)
    if printf '%s' "$g_content" | grep -q '\bfind\b'; then
      if printf '%s' "$g_content" | grep -qE '^[[:space:]]*(#|<!--)'; then
        excl_prose=$((excl_prose + 1))
      else
        resolver_hits="${resolver_hits:+$resolver_hits
}$glob_line"
      fi
      continue
    fi
    p_line=$((g_line - 1))
    p_content=$(sed -n "${p_line}p" "$REPO_ROOT/$g_file")
    if printf '%s' "$p_content" | grep -q '\bfind\b' \
       && ! printf '%s' "$p_content" | grep -qE '^[[:space:]]*(#|<!--)'; then
      resolver_hits="${resolver_hits:+$resolver_hits
}$g_file:$p_line:$p_content"
    else
      excl_prose=$((excl_prose + 1))
    fi
  done <<< "$glob_lines"
fi
excl_mechanical=$((excl_fixtures + excl_self + excl_stanza + excl_prose))

# Named exclusions — subtracted LAST, from the resolver set, and reported by
# path:line with the rationale. A named exclusion that no longer matches the
# predicate is stale (it may be hiding a real hole) and fails the gate.
excl_named=0
named_report=""
for _ne in "${NAMED_EXCLUSIONS[@]}"; do
  ne_site="${_ne%%|*}"
  ne_why="${_ne#*|}"
  if printf '%s\n' "$resolver_hits" | grep -q "^${ne_site}:"; then
    resolver_hits=$(printf '%s\n' "$resolver_hits" | grep -v "^${ne_site}:" || true)
    excl_named=$((excl_named + 1))
    named_report="${named_report:+$named_report
}      $ne_site — $ne_why"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL stale named exclusion: $ne_site no longer matches the discovery predicate"
    echo "       (a named exclusion that stops matching may be hiding a real hole — re-derive or remove it)"
  fi
done

if [ -z "$resolver_hits" ]; then
  resolver_count=0
else
  resolver_count=$(printf '%s\n' "$resolver_hits" | grep -c .)
fi
mapfile -t resolver_lines <<< "$resolver_hits"

# Full audit chain on stdout: a reader of the output can see that a named
# exclusion was applied, and which one.
echo "  predicate matches (-path '*/dev-team/*' under agents skills commands docs): $predicate_count"
echo "  - mechanical (shape) exclusions: $excl_mechanical"
echo "      canonical stanza emissions (line contains 'PDH=\$( {'): $excl_stanza"
echo "      harness self (skills/plugin-dir-test.sh): $excl_self"
echo "      skill-lint fixtures (deliberately drifted copies): $excl_fixtures"
echo "      comment/prose lines (describe the glob, do not run it): $excl_prose"
echo "  - named exclusions: $excl_named"
if [ -n "$named_report" ]; then
  printf '%s\n' "$named_report"
fi
echo "  = discovered $resolver_count non-stanza cache-resolver site(s) extracted and executed"

if [ "$resolver_count" -eq 0 ]; then
  FAIL=$((FAIL + 1))
  echo "  FAIL coverage discovery found ZERO resolvers — discovery predicate rotted (vacuity guard)"
elif [ "$resolver_count" -ne "$EXPECTED_RESOLVER_COUNT" ]; then
  FAIL=$((FAIL + 1))
  echo "  FAIL coverage count mismatch: found=$resolver_count want=$EXPECTED_RESOLVER_COUNT"
  echo "  discovered sites:"
  printf '%s\n' "$resolver_hits" | sed 's/^/    /'
else
  PASS=$((PASS + 1))
  echo "  ok  coverage count matches expected ($EXPECTED_RESOLVER_COUNT)"
fi

# Extraction — single-line family (embed-one.sh locators): the physical line
# carries the whole `find ... | cut -f3` pipeline. Extract from the first
# `find` token to end-of-line, stripping one optional trailing " )" (the
# enclosing command substitution's closer).
extract_single_line_resolver() {
  local file="$1" lineno="$2" out
  out=$(sed -n "${lineno}p" "$REPO_ROOT/$file" | grep -oE 'find .*') || out=""
  if [ -z "$out" ]; then
    echo "FATAL: extraction failed (no 'find' token) at $file:$lineno" >&2
    return 1
  fi
  out="${out%" )"}"
  printf '%s' "$out"
}

# Extraction — multiline family (hook-runtime `_pdh_hit=$(find ...)`
# bootstraps): start at the `_pdh_hit=$(find ` line, accumulate every
# following physical line, stop at (and include) the terminator line
# containing `) || _pdh_hit=""`. Deliberately NOT "chain only while the
# previous line ends in a backslash": skills/transcript-mirror/hook-shim.sh
# embeds a multi-line awk PROGRAM inside an unterminated single-quoted
# string, so intermediate lines carry no trailing backslash. Scanning to the
# terminator text is the only anchor correct for all three real sites. An
# unterminated block (no terminator found before EOF) is a loud failure,
# never a silent skip.
extract_multiline_resolver() {
  local file="$1" start="$2"
  local path="$REPO_ROOT/$file"
  local total end lineno line block=""
  total=$(wc -l < "$path")
  end=""
  lineno="$start"
  while [ "$lineno" -le "$total" ]; do
    line=$(sed -n "${lineno}p" "$path")
    if [ -z "$block" ]; then block="$line"; else block="$block
$line"; fi
    if printf '%s' "$line" | grep -qF ') || _pdh_hit=""'; then
      end="$lineno"
      break
    fi
    lineno=$((lineno + 1))
  done
  if [ -z "$end" ]; then
    echo "FATAL: unterminated multiline resolver block at $file:$start (no ') || _pdh_hit=\"\"' terminator found before EOF)" >&2
    return 1
  fi
  printf '%s' "$block"
}

# Derive <target> from the site's own `-path` glob (shape:
# '*/dev-team/*/<target>') rather than hard-coding it per site. The leading
# backslash on \-path keeps the pattern from being parsed as an option by
# grep implementations that reject a leading '-' in PATTERN.
derive_target() {
  local resolver_text="$1" glob target
  glob=$(printf '%s' "$resolver_text" | grep -oE "\-path '[^']*'" | head -1 | sed -E "s/^-path '//; s/'\$//")
  if [ -z "$glob" ]; then
    return 1
  fi
  target="${glob#\*/dev-team/\*/}"
  printf '%s' "$target"
}

# Execute an extracted resolver under a synthetic $HOME. Writes to a scratch
# file under $TMP and runs it with a fresh bash process (never `bash -c` on
# raw extracted text — the embedded single quotes / $'\t' ANSI-C quoting
# would need a second escaping pass to survive as one shell argument). Sets
# globals RESOLVE_OUT / RESOLVE_RC. $FOREIGN (established above, for the
# branch-1-bypass proof) has neither skills/memory-store/embed-one.sh nor
# skills/plugin-dir.sh, so the dev-checkout fast path in the ORIGINAL site
# expression cannot short-circuit here — moot in practice since extraction
# already excludes that guard, kept as a belt-and-braces fixture property.
resolver_exec() {
  local family="$1" text="$2" home="$3" script
  script="$TMP/cdt234-resolver-exec.sh"
  {
    printf '%s\n' "$text"
    if [ "$family" = "multiline" ]; then
      printf 'printf %%s "$_pdh_hit"\n'
    fi
  } > "$script"
  RESOLVE_OUT=$(cd "$FOREIGN" && env -u CLAUDE_PLUGIN_ROOT HOME="$home" bash "$script" 2>/dev/null)
  RESOLVE_RC=$?
  rm_under_tmp "$script"
}

# --- T5b: per-site behavioural fixtures (AC1 / AC1a / AC4 / AC8) -----------
echo "== CDT-234 per-site behavioural coverage =="
CACHE_BASE_234="$TMP/home/.claude/plugins/cache"
if [ "$resolver_count" -gt 0 ]; then
  for hit in "${resolver_lines[@]}"; do
    [ -n "$hit" ] || continue
    r_file=$(printf '%s' "$hit" | cut -d: -f1)
    r_line=$(printf '%s' "$hit" | cut -d: -f2)
    site_label="$r_file:$r_line"
    if printf '%s' "$hit" | grep -q '_pdh_hit=\$(find'; then
      family="multiline"
    else
      family="single"
    fi

    if [ "$family" = "single" ]; then
      resolver_text=$(extract_single_line_resolver "$r_file" "$r_line")
      ext_rc=$?
    else
      resolver_text=$(extract_multiline_resolver "$r_file" "$r_line")
      ext_rc=$?
    fi
    if [ "$ext_rc" -ne 0 ] || [ -z "$resolver_text" ]; then
      FAIL=$((FAIL + 1))
      echo "  FAIL extraction failed for $site_label ($family)"
      continue
    fi
    PASS=$((PASS + 1))
    echo "  ok  extracted resolver at $site_label ($family)"

    target=$(derive_target "$resolver_text")
    if [ -z "$target" ]; then
      FAIL=$((FAIL + 1))
      echo "  FAIL could not derive <target> for $site_label"
      continue
    fi
    target_dir=$(dirname "$target")

    # (a) numeric-not-lexical: cold-dark-void/10.0.0 must beat zzz-other/2.0.0
    rm_under_tmp "$TMP/home"
    mkdir -p "$CACHE_BASE_234/zzz-other/dev-team/2.0.0/$target_dir"
    mkdir -p "$CACHE_BASE_234/cold-dark-void/dev-team/10.0.0/$target_dir"
    printf 'zzz-2\n' > "$CACHE_BASE_234/zzz-other/dev-team/2.0.0/$target"
    printf 'cdv-10\n' > "$CACHE_BASE_234/cold-dark-void/dev-team/10.0.0/$target"
    resolver_exec "$family" "$resolver_text" "$TMP/home"
    assert_rc "$site_label (a) numeric-not-lexical rc" "$RESOLVE_RC" 0
    assert_contains "$site_label (a) resolves /10.0.0/ not /2.0.0/" "$RESOLVE_OUT" "/10.0.0/"

    # (b) 1.0.0 beats 1.0.0-pre.4 (tilde map still load-bearing)
    rm_under_tmp "$TMP/home"
    mkdir -p "$CACHE_BASE_234/zzz-other/dev-team/1.0.0/$target_dir"
    mkdir -p "$CACHE_BASE_234/zzz-other/dev-team/1.0.0-pre.4/$target_dir"
    printf 'final\n' > "$CACHE_BASE_234/zzz-other/dev-team/1.0.0/$target"
    printf 'pre\n' > "$CACHE_BASE_234/zzz-other/dev-team/1.0.0-pre.4/$target"
    resolver_exec "$family" "$resolver_text" "$TMP/home"
    assert_rc "$site_label (b) final-over-pre rc" "$RESOLVE_RC" 0
    if printf '%s' "$RESOLVE_OUT" | grep -qF '/1.0.0/' && ! printf '%s' "$RESOLVE_OUT" | grep -qF '1.0.0-pre'; then
      PASS=$((PASS + 1)); echo "  ok  $site_label (b) final outranks pre"
    else
      FAIL=$((FAIL + 1)); echo "  FAIL $site_label (b) final must outrank pre: [$RESOLVE_OUT]"
    fi

    # (c) equal <VER> across slugs prefers cold-dark-void (AC1a)
    rm_under_tmp "$TMP/home"
    mkdir -p "$CACHE_BASE_234/zzz-other/dev-team/1.2.3/$target_dir"
    mkdir -p "$CACHE_BASE_234/cold-dark-void/dev-team/1.2.3/$target_dir"
    printf 'zzz\n' > "$CACHE_BASE_234/zzz-other/dev-team/1.2.3/$target"
    printf 'cdv\n' > "$CACHE_BASE_234/cold-dark-void/dev-team/1.2.3/$target"
    resolver_exec "$family" "$resolver_text" "$TMP/home"
    assert_rc "$site_label (c) equal-VER rc" "$RESOLVE_RC" 0
    assert_contains "$site_label (c) prefers cold-dark-void" "$RESOLVE_OUT" "/cache/cold-dark-void/dev-team/1.2.3/"

    # (d) empty cache -> empty stdout, not a bare '/', not a non-zero exit (AC8)
    rm_under_tmp "$TMP/home"
    mkdir -p "$CACHE_BASE_234"
    resolver_exec "$family" "$resolver_text" "$TMP/home"
    assert_rc "$site_label (d) empty-cache rc" "$RESOLVE_RC" 0
    assert_eq "$site_label (d) empty-cache stdout empty" "$RESOLVE_OUT" ""
  done
else
  FAIL=$((FAIL + 1))
  echo "  FAIL per-site behavioural gate skipped — coverage discovery found 0 sites"
fi

# --- T5c: permanent negative proof (AC3) ------------------------------------
# The tilde-mapped FULL-PATH sort -V arm (the CDT-166 defect) MUST still lose
# to fixture (a): this proves the hazard is real AND that the tilde map alone
# is not the fix. A bare (non-tilde-mapped) sort -V would only re-exercise
# the pre-existing CDT-53-13 hazard and does NOT satisfy this proof.
echo "== CDT-234 permanent negative proof (AC3) =="
rm_under_tmp "$TMP/home"
mkdir -p "$CACHE_BASE_234/zzz-other/dev-team/2.0.0/skills"
mkdir -p "$CACHE_BASE_234/cold-dark-void/dev-team/10.0.0/skills"
: > "$CACHE_BASE_234/zzz-other/dev-team/2.0.0/skills/plugin-dir.sh"
: > "$CACHE_BASE_234/cold-dark-void/dev-team/10.0.0/skills/plugin-dir.sh"
naive=$(
  find "$CACHE_BASE_234" -path '*/dev-team/*/skills/plugin-dir.sh' 2>/dev/null \
    | sed 's/-pre\./~pre./' | sort -V | tail -1 | sed 's/~pre\./-pre./'
)
assert_contains "CDT-234 negative proof: tilde-mapped full-path sort -V still picks /2.0.0/" "$naive" "/2.0.0/"
if printf '%s' "$naive" | grep -qF '/10.0.0/'; then
  FAIL=$((FAIL + 1))
  echo "  FAIL negative proof is vacuous — tilde map alone must NOT fix full-path ranking: [$naive]"
else
  PASS=$((PASS + 1))
  echo "  ok  negative proof not vacuous (tilde map alone does not fix full-path ranking)"
fi

# --- T5c: resolver uniformity (AC7) -----------------------------------------
# The 9 single-line embed-one.sh sites MUST be identical to the canonical
# home (skills/agent-memory/protocol.md) after stripping LEADING WHITESPACE
# only — strict byte-identity is explicitly NOT required and MUST NOT be
# gated (indentation legitimately differs by host document). The 3 multiline
# sites are exempt from uniformity (differing host indentation/control
# flow); they are covered by the behavioural gate above only.
echo "== CDT-234 resolver uniformity (AC7) =="
CANON_FILE="skills/agent-memory/protocol.md"
canon_line=""
for hit in "${resolver_lines[@]}"; do
  [ -n "$hit" ] || continue
  r_file=$(printf '%s' "$hit" | cut -d: -f1)
  if [ "$r_file" = "$CANON_FILE" ]; then
    canon_line=$(printf '%s' "$hit" | cut -d: -f2)
    break
  fi
done
if [ -z "$canon_line" ]; then
  FAIL=$((FAIL + 1))
  echo "  FAIL uniformity canonical home not found in discovered set: $CANON_FILE"
else
  canon_text=$(sed -n "${canon_line}p" "$REPO_ROOT/$CANON_FILE" | sed -E 's/^[[:space:]]*//')
  PASS=$((PASS + 1))
  echo "  ok  uniformity canonical text loaded from $CANON_FILE:$canon_line"
  uniform_checked=0
  for hit in "${resolver_lines[@]}"; do
    [ -n "$hit" ] || continue
    if printf '%s' "$hit" | grep -q '_pdh_hit=\$(find'; then
      continue  # multiline sites are exempt from uniformity
    fi
    r_file=$(printf '%s' "$hit" | cut -d: -f1)
    r_line=$(printf '%s' "$hit" | cut -d: -f2)
    site_line=$(sed -n "${r_line}p" "$REPO_ROOT/$r_file" | sed -E 's/^[[:space:]]*//')
    uniform_checked=$((uniform_checked + 1))
    assert_eq "uniformity $r_file:$r_line matches canonical (leading-ws-insensitive)" "$site_line" "$canon_text"
  done
  if [ "$uniform_checked" -eq 0 ]; then
    FAIL=$((FAIL + 1))
    echo "  FAIL uniformity gate checked ZERO single-line sites"
  fi
fi

# --- CDT-237: PDH stanza branch-0 / branch-1 coverage ----------------------
# Every call site in this file runs the stanza via
# `env -u CLAUDE_PLUGIN_ROOT ... bash "$STANZA_SH"` (branch 0 unconditionally
# deleted) with cwd inside $FOREIGN, a synthetic dir with no
# skills/plugin-dir.sh (branch 1 unconditionally defeated). Neither branch
# had a single assertion on the RESOLVED PATH before this section — branch 0
# had zero coverage and branch 1's cwd resolution was never checked. These
# cases run the same extracted $STANZA_SH with fixtures aimed at each branch.
echo "== CDT-237 stanza branch-0 (CLAUDE_PLUGIN_ROOT, guarded) =="

# Branch-0 positive: CLAUDE_PLUGIN_ROOT set to a real directory containing
# skills/plugin-dir.sh (the guard) resolves to that exact root.
PLANTED_ROOT="$TMP/c237-branch0-planted"
mkdir -p "$PLANTED_ROOT/skills"
: > "$PLANTED_ROOT/skills/plugin-dir.sh"
pdh=$(
  cd "$FOREIGN" &&
  env CLAUDE_PLUGIN_ROOT="$PLANTED_ROOT" HOME="$TMP/c237-home-unused1" bash "$STANZA_SH"
)
assert_eq "CDT-237 branch-0 positive resolves planted CLAUDE_PLUGIN_ROOT" "$pdh" "$PLANTED_ROOT"

# Branch-0 guard-negative: CLAUDE_PLUGIN_ROOT set to a directory that does
# NOT contain skills/plugin-dir.sh must not resolve to that bogus root — the
# guard must fail closed and fall through. A populated cache (branch 3)
# below proves genuine fallthrough, not a lucky empty-PDH coincidence.
BOGUS_ROOT="$TMP/c237-branch0-bogus"
mkdir -p "$BOGUS_ROOT"
FALLTHROUGH_HOME="$TMP/c237-home-fallthrough"
FALLTHROUGH_ROOT="$FALLTHROUGH_HOME/.claude/plugins/cache/cold-dark-void/dev-team/3.0.0"
mkdir -p "$FALLTHROUGH_ROOT/skills"
: > "$FALLTHROUGH_ROOT/skills/plugin-dir.sh"
pdh=$(
  cd "$FOREIGN" &&
  env CLAUDE_PLUGIN_ROOT="$BOGUS_ROOT" HOME="$FALLTHROUGH_HOME" bash "$STANZA_SH"
)
assert_eq "CDT-237 branch-0 guard-negative falls through to cache, not bogus root" "$pdh" "$FALLTHROUGH_ROOT"

echo "== CDT-237 stanza branch-1 (cwd dev checkout) =="

# Branch-1 positive: cwd inside a synthetic checkout containing
# skills/plugin-dir.sh, CLAUDE_PLUGIN_ROOT unset, resolves to that cwd.
BRANCH1_CHECKOUT="$TMP/c237-branch1-checkout"
mkdir -p "$BRANCH1_CHECKOUT/skills"
: > "$BRANCH1_CHECKOUT/skills/plugin-dir.sh"
pdh=$(
  cd "$BRANCH1_CHECKOUT" &&
  env -u CLAUDE_PLUGIN_ROOT HOME="$TMP/c237-home-unused2" bash "$STANZA_SH"
)
assert_eq "CDT-237 branch-1 positive resolves cwd" "$pdh" "$BRANCH1_CHECKOUT"

echo "== CDT-237 stanza precedence =="

# Branch 0 beats branch 1 when both are simultaneously satisfiable.
PREC_CWD1="$TMP/c237-prec-cwd1"
mkdir -p "$PREC_CWD1/skills"
: > "$PREC_CWD1/skills/plugin-dir.sh"
PREC_ROOT0="$TMP/c237-prec-root0"
mkdir -p "$PREC_ROOT0/skills"
: > "$PREC_ROOT0/skills/plugin-dir.sh"
pdh=$(
  cd "$PREC_CWD1" &&
  env CLAUDE_PLUGIN_ROOT="$PREC_ROOT0" HOME="$TMP/c237-home-unused3" bash "$STANZA_SH"
)
assert_eq "CDT-237 precedence: branch 0 wins over satisfiable branch 1" "$pdh" "$PREC_ROOT0"

# Branch 1 beats branch 3 (cache) when both are simultaneously satisfiable
# (CLAUDE_PLUGIN_ROOT unset so branch 0 cannot compete).
PREC_CWD2="$TMP/c237-prec-cwd2"
mkdir -p "$PREC_CWD2/skills"
: > "$PREC_CWD2/skills/plugin-dir.sh"
PREC_HOME="$TMP/c237-prec-home"
PREC_CACHE_ROOT="$PREC_HOME/.claude/plugins/cache/cold-dark-void/dev-team/5.0.0"
mkdir -p "$PREC_CACHE_ROOT/skills"
: > "$PREC_CACHE_ROOT/skills/plugin-dir.sh"
pdh=$(
  cd "$PREC_CWD2" &&
  env -u CLAUDE_PLUGIN_ROOT HOME="$PREC_HOME" bash "$STANZA_SH"
)
assert_eq "CDT-237 precedence: branch 1 (cwd) wins over populated cache (branch 3)" "$pdh" "$PREC_CWD2"

# Branch 1 beats branch 2 (marketplace) when both are simultaneously
# satisfiable (CLAUDE_PLUGIN_ROOT unset). Completes AC5 ("branch 1 wins
# over branches 2/3, each asserted"): every OTHER call site in this file
# runs inside $FOREIGN (no skills/plugin-dir.sh, branch 1 unsatisfiable),
# so without this case a stanza that silently swaps branch 1 and branch 2
# order stays green — a feat/* worktree with a marketplace clone in $HOME
# would then silently resolve to the clone instead of the checkout (the
# CDT-82 shadow class).
PREC_CWD3="$TMP/c237-prec-cwd3"
mkdir -p "$PREC_CWD3/skills"
: > "$PREC_CWD3/skills/plugin-dir.sh"
PREC_HOME3="$TMP/c237-prec-home3"
PREC_MP_ROOT="$PREC_HOME3/.claude/plugins/marketplaces/prec-mp-slug"
mkdir -p "$PREC_MP_ROOT/skills" "$PREC_MP_ROOT/agents"
: > "$PREC_MP_ROOT/skills/plugin-dir.sh"
: > "$PREC_MP_ROOT/agents/pm.md"
pdh=$(
  cd "$PREC_CWD3" &&
  env -u CLAUDE_PLUGIN_ROOT HOME="$PREC_HOME3" bash "$STANZA_SH"
)
assert_eq "CDT-237 precedence: branch 1 (cwd) wins over populated marketplace (branch 2)" "$pdh" "$PREC_CWD3"

echo "== CDT-237 stanza branch-0 quoting =="

# Branch-0's entire job is consuming a user-supplied env path (FR #48230),
# so quoting is its highest-value property. CLAUDE_PLUGIN_ROOT containing a
# space must resolve exactly — an unquoted `[ -f $CLAUDE_PLUGIN_ROOT/... ]`
# throws "binary operator expected" and silently falls through instead.
PLANTED_ROOT_SPACE="$TMP/c237-branch0-with space-root"
mkdir -p "$PLANTED_ROOT_SPACE/skills"
: > "$PLANTED_ROOT_SPACE/skills/plugin-dir.sh"
pdh=$(
  cd "$FOREIGN" &&
  env CLAUDE_PLUGIN_ROOT="$PLANTED_ROOT_SPACE" HOME="$TMP/c237-home-unused4" bash "$STANZA_SH"
)
assert_eq "CDT-237 branch-0 quoting: CLAUDE_PLUGIN_ROOT with a space resolves exactly" "$pdh" "$PLANTED_ROOT_SPACE"

echo "== CDT-237 stanza branch-1 pwd vs pwd -P (symlink) =="

# Bare `pwd` (logical, unresolved) is load-bearing for branch 1, not
# `pwd -P` (physical). A checkout reached through a symlink must resolve
# to the symlink path used to cd there, not the realpath — otherwise a
# compare against the SAME logical path the subshell cd'd to could never
# distinguish the two, which is exactly why this needs its own fixture
# rather than reusing the branch-1-positive case above.
BRANCH1_ACTUAL="$TMP/c237-branch1-actual"
mkdir -p "$BRANCH1_ACTUAL/skills"
: > "$BRANCH1_ACTUAL/skills/plugin-dir.sh"
BRANCH1_SYMLINK="$TMP/c237-branch1-symlink"
ln -s "$BRANCH1_ACTUAL" "$BRANCH1_SYMLINK"
pdh=$(
  cd "$BRANCH1_SYMLINK" &&
  env -u CLAUDE_PLUGIN_ROOT HOME="$TMP/c237-home-unused5" bash "$STANZA_SH"
)
assert_eq "CDT-237 branch-1 resolves logical cwd (pwd, not pwd -P) through a symlink" "$pdh" "$BRANCH1_SYMLINK"

# --- CDT-233 T7 V1: stale-cache delegation falsification (permanent negative
# proof). A pre-CDT-166 build (its whole body is the forbidden full-path
# find|sort-V|tail arm) sits at a lexically-higher slug carrying a STALE
# lower version; the correct root sits at cold-dark-void carrying a HIGHER
# version. This is the honest, executable form of the SPEC-002 CDT-233
# verdict: an old copy resolves itself, a find-any bootstrap can reach it,
# and only the canonical stanza does not.
#
# ORDERING CONSTRAINT: this V1/V2 block (through end of file) wipes
# $TMP/home wholesale and overwrites $STALE_ROOT's plugin-dir.sh in place —
# safe ONLY because nothing after it reads $TMP/home, $STALE_ROOT, or
# $GOOD_ROOT. This block MUST remain the LAST thing in this file. If you add
# a new section below it, either move that section above this one or give
# it its own $TMP subdirectory instead of reusing $TMP/home.
echo "== CDT-233 T7 V1: stale-cache delegation (permanent negative proof) =="
rm_under_tmp "$TMP/home"
CACHE_233="$TMP/home/.claude/plugins/cache"
STALE_ROOT="$CACHE_233/zzz-other/dev-team/1.0.0"
GOOD_ROOT="$CACHE_233/cold-dark-void/dev-team/2.0.0"
mkdir -p "$STALE_ROOT/skills" "$GOOD_ROOT/skills"

# Pre-CDT-166 build. The glob is spelled LITERALLY, inline in the `find`
# invocation below — deliberately NOT composed from variables. SPEC-002's
# glob-in-variable flip test (the B1 falsification) is only meaningful if
# THIS file is never carved out of it: excluding plugin-dir-test.sh, or
# hiding the glob behind a variable to dodge the CDT-234 discovery
# predicate's own count, would be exactly the "loosen the predicate to
# chase a clean number" move SPEC-002 forbids. This literal line is
# therefore also the first in-tree instance of the SPEC-021/SPEC-002
# discovery predicate's shape, moves the audit-chain numbers printed below
# (a dated measurement, not the gated contract — only EXPECTED_RESOLVER_COUNT
# is gated), and is correctly excluded from the resolver count via the
# existing "harness self" mechanical exclusion, not via a new carve-out.
cat > "$STALE_ROOT/skills/plugin-dir.sh" <<'PRECDT166EOF'
#!/usr/bin/env bash
find ~/.claude/plugins/cache -path '*/dev-team/*/skills/plugin-dir.sh' 2>/dev/null | sed 's/-pre\./~pre./' | sort -V | tail -1 | sed 's/~pre\./-pre./' | xargs -r dirname | xargs -r dirname
PRECDT166EOF

# Correct root: a real copy of the current script.
cp "$LIB" "$GOOD_ROOT/skills/plugin-dir.sh"

# Assertion 1: the stale copy answers authoritatively for ITSELF, and it is
# the wrong root (lexically-higher slug beats an actually-higher version —
# the CDT-166 defect this build predates).
out=$(
  cd "$FOREIGN" &&
  env -u CLAUDE_PLUGIN_ROOT HOME="$TMP/home" bash "$STALE_ROOT/skills/plugin-dir.sh"
)
assert_eq "T7-V1.1 stale pre-CDT-166 copy resolves itself (wrong root)" "$out" "$STALE_ROOT"

# Assertion 2: a find-any-then-delegate bootstrap — the mechanism CDT-232
# rejected — reaches the same stale root. MUST be `sort | tail -1`, NEVER
# `head -1`: `find` order is readdir order, not stable across filesystems
# (observed landing on cold-dark-void FIRST on ext4 here, which would make
# `head -1` pass this assertion for the wrong reason). `sort | tail -1` is
# also the honest model of the forbidden pre-CDT-166 spelling: lexically-
# highest path wins, not highest version.
readdir_order=$(find "$CACHE_233" -name plugin-dir.sh 2>/dev/null)
find_any=$(printf '%s\n' "$readdir_order" | sort | tail -1 | xargs -r dirname | xargs -r dirname)
assert_eq "T7-V1.2 find-any-then-delegate (sort|tail -1) reaches stale root" "$find_any" "$STALE_ROOT"
# Diagnostic only (not counted in PASS/FAIL): shows whether readdir order on
# THIS filesystem would have let a `head -1` model pass for the wrong reason.
if printf '%s\n' "$readdir_order" | head -1 | grep -qF "$GOOD_ROOT"; then
  echo "  info T7-V1.2 readdir order put cold-dark-void first here — head -1 would have been a false pass (this is why sort|tail -1 is required, not order-dependent)"
else
  echo "  info T7-V1.2 readdir order did not put cold-dark-void first this run (still using sort|tail -1, not order-dependent)"
fi

# Assertion 3: the canonical stanza extracted from SPEC-002 at runtime — the
# same $STANZA_SH used throughout this harness, never a hand-copy — resolves
# the CORRECT, higher-versioned root instead.
pdh=$(
  cd "$FOREIGN" &&
  env -u CLAUDE_PLUGIN_ROOT HOME="$TMP/home" bash "$STANZA_SH"
)
assert_eq "T7-V1.3 canonical stanza resolves correct root, not stale" "$pdh" "$GOOD_ROOT"

# Assertion 4 (honest counter-nuance, recorded not hidden): a MODERN copy
# planted at the SAME stale path self-corrects to cold-dark-void. Here VER
# decides outright — path_ver_pick (skills/plugin-dir.sh:47-60) sorts
# `-k1,1V` on the <VER> segment first, and 2.0.0 > 1.0.0 regardless of slug,
# so the SLUG=cold-dark-void tiebreak (`-k2,2n`) never executes in this
# fixture. The load-bearing fact this assertion actually proves is
# LOCATION-INDEPENDENCE: plugin-dir.sh reads no $0/BASH_SOURCE anywhere in
# its resolution logic, so a modern copy answers the same way regardless of
# which path on disk happens to be executing it. This is the strongest
# argument against the verdict: you cannot tell a stale copy from a modern
# one by path alone, only by running it. V2 below is what proves argv
# cannot be trusted to tell them apart either.
cp "$LIB" "$STALE_ROOT/skills/plugin-dir.sh"
out=$(
  cd "$FOREIGN" &&
  env -u CLAUDE_PLUGIN_ROOT HOME="$TMP/home" bash "$STALE_ROOT/skills/plugin-dir.sh" root
)
assert_eq "T7-V1.4 (honest limitation) modern copy at stale path self-corrects to correct root" "$out" "$GOOD_ROOT"

# --- CDT-233 T7 V2: re-open tripwire for Q1(c) (@pm AC-D) -------------------
# This is a TRIPWIRE, not a prohibition: it does not forbid hardening argv
# on `plugin-dir.sh root`; it forbids hardening argv while leaving this
# SPEC-002 CDT-233 verdict standing on the opposite assumption. Today,
# `main()`'s `case "$sub"` matches on $1 only and cmd_root ignores "$@"
# entirely, so an unknown trailing flag is silently accepted and rc stays 0
# — which is the same shape as an older copy silently accepting a version
# tag it does not understand and answering with a stale root.
echo "== CDT-233 T7 V2: re-open tripwire (@pm AC-D) =="
v2_out=$(bash "$REPO_ROOT/skills/plugin-dir.sh" root --pdh-contract=2 2>/dev/null)
v2_rc=$?
if [ "$v2_rc" -eq 0 ] && [ -n "$v2_out" ]; then
  PASS=$((PASS + 1))
  echo "  ok  T7-V2 plugin-dir.sh root --pdh-contract=2 exits 0 with a root (verdict's premise holds)"
else
  FAIL=$((FAIL + 1))
  echo "  FAIL T7-V2 plugin-dir.sh now rejects unknown flags. SPEC-002 CDT-233 Q1(c) rests on the opposite"
  echo "       (an older copy silently accepts a version tag and answers rc 0 with a stale root)."
  echo "       Re-open the versioned-bootstrap-contract question or update the verdict."
fi

echo
echo "PASS=$PASS FAIL=$FAIL"
if [ "$FAIL" -ne 0 ]; then
  exit 1
fi
exit 0
