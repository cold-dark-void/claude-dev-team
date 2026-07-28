#!/usr/bin/env bash
# light-preset-test.sh — CDT-91 T9a critical AC proof for M10c light preset.
# Uses real prepass.sh finalize + assemble.py (via finalize). Fixtures from
# finalize-test.sh patterns (events-thrash + git-state).
# Run: bash skills/handoff/light-preset-test.sh
set -u

HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PREPASS="$HERE/prepass.sh"
FIX="$HERE/fixtures"
THRASH="$FIX/events-thrash.json"
GITBLOB="$FIX/git-state.txt"
LIGHT_HONESTY='light preset: reduced-cost mine, no annotation; not AC-16-scored.'

# Step-4 PRIOR_LEAF reader — must match commands/handoff.md defense exactly
# (light:true cache → no-prior; events present + no light → print leaf).
read_prior_leaf() {
  PRIOR_CACHE="$1" python3 - <<'PYDELTA'
import json, os, sys
path = os.environ["PRIOR_CACHE"]
try:
    with open(path, "r", encoding="utf-8") as fh:
        data = json.load(fh)
except (OSError, ValueError):
    sys.exit(0)
if not isinstance(data, dict):
    sys.exit(0)
leaf = data.get("leaf_uuid") or ""
if not isinstance(leaf, str) or not leaf.strip():
    sys.exit(0)
ev = data.get("events")
if not isinstance(ev, dict) or not ev:
    sys.exit(0)
# M10c defense (CDT-91): light:true cache → no-prior (primary path never writes this)
if data.get("light") in (True, 1, "true", "1"):
    sys.exit(0)
has = False
for v in ev.values():
    if isinstance(v, list) and v:
        has = True
        break
if has:
    print(leaf.strip())
PYDELTA
}

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $*"; }

WORK=$(mktemp -d "${TMPDIR:-/tmp}/light-preset-test.XXXXXX")
trap 'rm -rf "$WORK"' EXIT

export HANDOFF_DIR="$WORK/handoff"
mkdir -p "$HANDOFF_DIR"

# ---- T0: fixtures ----
if [ -f "$THRASH" ] && [ -f "$GITBLOB" ] && [ -x "$PREPASS" ]; then ok
else bad "T0 missing fixtures or prepass"; fi

# =====================================================================
# AC1: light finalize → *-draft.md with mode:warm + light:true + honesty;
#      no cache file created
# =====================================================================
AC1_SID="cdt91-light-ac1"
AC1_LEAF="leaf-light-ac1"
set +e
bash "$PREPASS" finalize \
  --uuid "$AC1_SID" \
  --events "$THRASH" \
  --git-state "$GITBLOB" \
  --leaf "$AC1_LEAF" \
  --slug light-ac1 \
  --mode warm \
  --light \
  >"$WORK/ac1.stdout" 2>"$WORK/ac1.stderr"
RC=$?
set -e

AC1_DRAFT=""
for f in "$HANDOFF_DIR"/*-"${AC1_SID}"-*-draft.md; do
  [ -f "$f" ] && AC1_DRAFT="$f" && break
done
AC1_CACHE="$HANDOFF_DIR/cache/${AC1_SID}.json"

if [ "$RC" -eq 0 ] && [ -n "$AC1_DRAFT" ] && [ -f "$AC1_DRAFT" ]; then ok
else bad "AC1 finalize/draft rc=$RC draft=${AC1_DRAFT:-none} err=$(head -c 300 "$WORK/ac1.stderr")"; fi

if [ -n "$AC1_DRAFT" ] && basename -- "$AC1_DRAFT" | grep -qE -- '-draft\.md$'; then ok
else bad "AC1 basename not *-draft.md: $(basename -- "${AC1_DRAFT:-}")"; fi

if [ ! -e "$AC1_CACHE" ]; then ok
else bad "AC1 cache must not exist: $AC1_CACHE"; fi

if [ -n "$AC1_DRAFT" ] && [ -f "$AC1_DRAFT" ] \
   && grep -qE '^_mode: warm · light: true' "$AC1_DRAFT" \
   && grep -qE '^mode: warm$' "$AC1_DRAFT" \
   && grep -qE '^light: true$' "$AC1_DRAFT" \
   && grep -qF "$LIGHT_HONESTY" "$AC1_DRAFT"; then ok
else bad "AC1 packet missing mode:warm / light:true / honesty (draft=${AC1_DRAFT:-none})"; fi

if grep -q 'light=1' "$WORK/ac1.stderr" && grep -q 'cached=NO' "$WORK/ac1.stderr"; then ok
else bad "AC1 stderr missing light=1/cached=NO: $(head -c 200 "$WORK/ac1.stderr")"; fi

# =====================================================================
# AC2: full finalize → cache A; light finalize same session → cache
#      byte-identical to A (sha256 + cmp)
# =====================================================================
AC2_SID="cdt91-light-ac2"
AC2_LEAF_FULL="leaf-full-ac2"
AC2_LEAF_LIGHT="leaf-light-ac2"
AC2_CACHE="$HANDOFF_DIR/cache/${AC2_SID}.json"

set +e
bash "$PREPASS" finalize \
  --uuid "$AC2_SID" \
  --events "$THRASH" \
  --git-state "$GITBLOB" \
  --leaf "$AC2_LEAF_FULL" \
  --slug full-ac2 \
  --mode warm \
  --packet-out "$WORK/ac2-full.md" \
  >"$WORK/ac2-full.stdout" 2>"$WORK/ac2-full.stderr"
RC_FULL=$?
set -e

if [ "$RC_FULL" -eq 0 ] && [ -f "$AC2_CACHE" ] && [ -f "$WORK/ac2-full.md" ]; then ok
else bad "AC2 full finalize rc=$RC_FULL cache=$([ -f "$AC2_CACHE" ] && echo y || echo n) err=$(head -c 200 "$WORK/ac2-full.stderr")"; fi

cp -a -- "$AC2_CACHE" "$WORK/cache-A.json"
SHA_A=$(sha256sum "$WORK/cache-A.json" | awk '{print $1}')

set +e
bash "$PREPASS" finalize \
  --uuid "$AC2_SID" \
  --events "$THRASH" \
  --git-state "$GITBLOB" \
  --leaf "$AC2_LEAF_LIGHT" \
  --slug light-ac2 \
  --mode warm \
  --light \
  >"$WORK/ac2-light.stdout" 2>"$WORK/ac2-light.stderr"
RC_LIGHT=$?
set -e

AC2_DRAFT=""
for f in "$HANDOFF_DIR"/*-"${AC2_SID}"-*-draft.md; do
  [ -f "$f" ] && AC2_DRAFT="$f" && break
done

if [ "$RC_LIGHT" -eq 0 ] && [ -n "$AC2_DRAFT" ] && [ -f "$AC2_DRAFT" ]; then ok
else bad "AC2 light finalize rc=$RC_LIGHT draft=${AC2_DRAFT:-none} err=$(head -c 200 "$WORK/ac2-light.stderr")"; fi

if [ -f "$AC2_CACHE" ]; then ok
else bad "AC2 cache missing after light (should still be full cache A)"; fi

SHA_B=$(sha256sum "$AC2_CACHE" | awk '{print $1}')
if [ "$SHA_A" = "$SHA_B" ] && cmp -s "$WORK/cache-A.json" "$AC2_CACHE"; then ok
else bad "AC2 cache not byte-identical after light shaA=$SHA_A shaB=$SHA_B"; fi

# light must not stamp light:true onto existing cache
LIGHT_KEY=$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(d.get("light","__absent__"))' "$AC2_CACHE")
if [ "$LIGHT_KEY" = "__absent__" ] || [ "$LIGHT_KEY" = "None" ]; then ok
else bad "AC2 cache must not gain light key after light finalize: light=$LIGHT_KEY"; fi

# leaf must remain full capture's leaf (not light leaf)
CACHE_LEAF=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("leaf_uuid",""))' "$AC2_CACHE")
if [ "$CACHE_LEAF" = "$AC2_LEAF_FULL" ]; then ok
else bad "AC2 cache leaf_uuid changed: got=$CACHE_LEAF want=$AC2_LEAF_FULL"; fi

# =====================================================================
# AC3: after full cache present (light did not touch), Step-4 PRIOR_LEAF
#      reader still returns full leaf when events present and light not set
# =====================================================================
PRIOR_LEAF=$(read_prior_leaf "$AC2_CACHE")
if [ "$PRIOR_LEAF" = "$AC2_LEAF_FULL" ]; then ok
else bad "AC3 PRIOR_LEAF reader expected $AC2_LEAF_FULL got='${PRIOR_LEAF:-}'"; fi

# Defense still fires when light:true is planted (anti-poison) — not required
# for primary path, but proves the exact handoff.md snippet.
python3 -c '
import json, sys
src, dst = sys.argv[1], sys.argv[2]
d = json.load(open(src))
d["light"] = True
json.dump(d, open(dst, "w"))
' "$AC2_CACHE" "$WORK/cache-poison-light.json"
POISON_LEAF=$(read_prior_leaf "$WORK/cache-poison-light.json")
if [ -z "$POISON_LEAF" ]; then ok
else bad "AC3 light:true cache must yield empty PRIOR_LEAF got='$POISON_LEAF'"; fi

# empty events → no prior
python3 -c '
import json, sys
src, dst = sys.argv[1], sys.argv[2]
d = json.load(open(src))
d["events"] = {}
json.dump(d, open(dst, "w"))
' "$AC2_CACHE" "$WORK/cache-empty-ev.json"
EMPTY_LEAF=$(read_prior_leaf "$WORK/cache-empty-ev.json")
if [ -z "$EMPTY_LEAF" ]; then ok
else bad "AC3 empty events must yield empty PRIOR_LEAF got='$EMPTY_LEAF'"; fi

echo
echo "light-preset-test: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
