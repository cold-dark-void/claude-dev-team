#!/usr/bin/env bash
# CDT-602 AC1/AC2/AC7 — skills/council/verify-verbatim-dispatch.sh
#
# The dispatch-side verifier re-renders the expected council prompt from
# template + flavor + vardump with the skills/council/workflow.js loadPrompt
# semantics, then byte-compares (cmp) the hand-render a run is about to spawn
# with. This suite pins:
#   AC1 — exit 0 identical / 1 mismatch (first differing byte offset named on
#         stderr, ±1 line of context) / 2 usage and structural errors, and the
#         rule that the verifier never writes the rendered file
#   AC2 — byte-identity with the REAL loadPrompt (a temp copy of workflow.js,
#         test-verify-prompts.sh M5 precedent) on the goldens: a section block
#         dropped on an empty var, a kept block with only its marker lines
#         removed, {{FLAVOR_DELTA}} extraction (`## Delta body` cut + `[//]: #`
#         strip + trim, plus the no-marker path), one-pass substitution (a value
#         carrying {{A}} never re-expands), a missing var left literal, the
#         fenced-path render with NO trailing newline, and the no-fence path
#         that keeps its trailing newlines
#   AC7 — the CDT-613 live failure classes (spliced section, dropped evidence
#         bundle block, mangled content quotes, truncated render) all fail 1
#
# Hermetic: no network, writes only under $TMPDIR (hermetic_init), no live
# council run. Node is used ONLY here (never in the deliverable script) so the
# goldens come from the real renderer, not a second implementation; the golden
# block skips when node is unavailable.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

# shellcheck source=../../tests/lib/skip.sh
. "$ROOT/tests/lib/skip.sh"
# shellcheck source=../../tests/lib/hermetic.sh
. "$ROOT/tests/lib/hermetic.sh"
hermetic_init

fail=0
ok() { echo "OK: $1"; }
fail_msg() { echo "FAIL: $1"; fail=1; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/verify-verbatim-test.XXXXXX")"
trap 'rm -rf "$TMP"; hermetic_cleanup' EXIT

VVD="$ROOT/skills/council/verify-verbatim-dispatch.sh"
FIX="$ROOT/skills/council/fixtures/verify-verbatim"
INVESTIGATOR="$ROOT/skills/council/prompts/investigator.md"
JUDGE="$ROOT/skills/council/prompts/judge.md"
JADE="$ROOT/skills/council/flavors/jaded-senior.md"

if [ ! -f "$VVD" ]; then
  echo "FAIL: verify-verbatim-dispatch.sh is missing"
  exit 1
fi

# vvd <want-rc> <label> <args...> — run the verifier, assert the exit code,
# and keep stdout+stderr in VVD_OUT for the message-shape checks.
VVD_RC=0
VVD_OUT=""
vvd() {
  local want="$1" label="$2"; shift 2
  VVD_OUT=$(bash "$VVD" "$@" 2>&1); VVD_RC=$?
  if [ "$VVD_RC" = "$want" ]; then
    ok "$label (rc=$VVD_RC)"
    return 0
  fi
  fail_msg "$label (want rc=$want, got $VVD_RC)"
  printf '%s\n' "$VVD_OUT" | sed 's/^/    /'
  return 0
}

# mismatch <label> <offset-limit> <mode> <template> <vars> <rendered> [flavor]
# — exit 1 AND the report names a byte offset that is a real position in the
# shorter of the two files (the `$1` column of `cmp -l`, not an octet value).
mismatch() {
  local label="$1" lim="$2" mode="$3" tpl="$4" vf="$5" ren="$6" fl="${7:-}"
  local off
  if [ -n "$fl" ]; then
    vvd 1 "$label" --mode "$mode" --template "$tpl" --vars "$vf" --rendered "$ren" --flavor "$fl"
  else
    vvd 1 "$label" --mode "$mode" --template "$tpl" --vars "$vf" --rendered "$ren"
  fi
  if ! printf '%s\n' "$VVD_OUT" | grep -qE 'MISMATCH at byte [0-9]+'; then
    fail_msg "$label report names no byte offset"
    return 0
  fi
  off=$(printf '%s\n' "$VVD_OUT" | sed -n 's/.*MISMATCH at byte \([0-9]\{1,\}\).*/\1/p' | head -1)
  if [ -n "$off" ] && [ "$off" -ge 1 ] && [ "$off" -le "$lim" ]; then
    ok "$label offset $off is a byte position (<= $lim)"
  else
    fail_msg "$label offset out of range: '${off:-none}' (limit $lim)"
  fi
}

# ---- AC1: the exit-code contract on the committed fixtures ------------------
vvd 0 "AC1 byte-identical render" \
  --mode investigator --template "$FIX/tmpl-sections.md" \
  --vars "$FIX/vars-sections.json" --rendered "$FIX/rendered-good.md"
vvd 0 "AC1 no-fence render keeps its trailing newlines" \
  --mode investigator --template "$FIX/tmpl-nofence.md" \
  --vars "$FIX/vars-nofence.json" --rendered "$FIX/rendered-nofence.md"
vvd 0 "AC1 env-style vardump (KEY=value, value carries '=')" \
  --mode investigator --template "$FIX/tmpl-nofence.md" \
  --vars "$FIX/vars.env" --rendered "$FIX/rendered-env.md"
VVD_OUT=$(bash "$VVD" --mode investigator --template "$FIX/tmpl-nofence.md" \
  --vars "$FIX/vars.env" --rendered "$FIX/rendered-env.md" 2>&1)
if [ -z "$VVD_OUT" ]; then ok "AC1 exit 0 prints nothing"; else
  fail_msg "AC1 exit 0 printed: $VVD_OUT"; fi

# AC1 mismatches (the fixtures are the CDT-613 classes; AC7 re-checks them).
mismatch "AC1 mismatch: appended trailing newline" 53 investigator \
  "$FIX/tmpl-sections.md" "$FIX/vars-sections.json" "$FIX/rendered-trailing-nl.md"
mismatch "AC1 mismatch: spliced section body" 52 investigator \
  "$FIX/tmpl-sections.md" "$FIX/vars-sections.json" "$FIX/rendered-dropped.md"
mismatch "AC1 mismatch: mangled content quotes" 109 investigator \
  "$FIX/tmpl-flavor.md" "$FIX/vars-flavor.json" "$FIX/rendered-mangled.md" "$FIX/flavor-delta.md"
mismatch "AC1 mismatch: truncated render (size-only difference)" 52 investigator \
  "$FIX/tmpl-sections.md" "$FIX/vars-sections.json" "$FIX/rendered-short.md"

# AC1 structural / usage errors.
vvd 2 "AC1 structural: missing template" \
  --mode investigator --template "$FIX/nope.md" \
  --vars "$FIX/vars-sections.json" --rendered "$FIX/rendered-good.md"
vvd 2 "AC1 structural: vardump is not a JSON object" \
  --mode investigator --template "$FIX/tmpl-sections.md" \
  --vars "$FIX/bad-array.json" --rendered "$FIX/rendered-good.md"
vvd 2 "AC1 structural: env-style vardump line is not KEY=value" \
  --mode investigator --template "$FIX/tmpl-sections.md" \
  --vars "$FIX/bad-env.txt" --rendered "$FIX/rendered-good.md"
vvd 2 "AC1 usage: --mode is not investigator|judge" \
  --mode scribe --template "$FIX/tmpl-sections.md" \
  --vars "$FIX/vars-sections.json" --rendered "$FIX/rendered-good.md"
vvd 2 "AC1 usage: --flavor in judge mode" \
  --mode judge --template "$FIX/tmpl-sections.md" \
  --vars "$FIX/vars-sections.json" --rendered "$FIX/rendered-good.md" \
  --flavor "$FIX/flavor-delta.md"
vvd 2 "AC1 usage: unknown flag" \
  --mode investigator --template "$FIX/tmpl-sections.md" \
  --vars "$FIX/vars-sections.json" --rendered "$FIX/rendered-good.md" --wat

# AC1: the verifier never writes the rendered file.
sum_before=$(cksum "$FIX/rendered-trailing-nl.md")
bash "$VVD" --mode investigator --template "$FIX/tmpl-sections.md" \
  --vars "$FIX/vars-sections.json" --rendered "$FIX/rendered-trailing-nl.md" \
  >/dev/null 2>&1 || true
if [ "$sum_before" = "$(cksum "$FIX/rendered-trailing-nl.md")" ]; then
  ok "AC1 the verifier left the rendered file untouched"
else
  fail_msg "AC1 the verifier wrote the rendered file"
fi

# AC1: no python/node in the deliverable (AC6 shares this guard).
if grep -qE '^[[:space:]]*(python3?|node)[[:space:]]' "$VVD"; then
  fail_msg "AC6 verify-verbatim-dispatch.sh invokes python/node"
else
  ok "AC6 verify-verbatim-dispatch.sh is bash/awk/jq/sed only"
fi

# ---- AC2: goldens rendered by the REAL loadPrompt ---------------------------
if ( require_cmd node jq ); then
  WF="$TMP/wf"
  mkdir -p "$WF/prompts" "$WF/flavors" "$TMP/lib"
  cp "$ROOT/skills/council/workflow.js" "$WF/workflow.js"
  cp "$ROOT/skills/council/workflow-schemas.js" "$WF/workflow-schemas.js"
  cp "$ROOT/skills/lib/chunked-parallel.js" "$TMP/lib/chunked-parallel.js"
  cp "$FIX"/tmpl-*.md "$WF/prompts/"
  cp "$INVESTIGATOR" "$WF/prompts/investigator.md"
  cp "$JUDGE" "$WF/prompts/judge.md"
  # loadFlavor resolves by file name: the fixtures carry their flavor name.
  cp "$FIX/flavor-delta.md" "$WF/flavors/fixture-delta.md"
  cp "$FIX/flavor-nomark.md" "$WF/flavors/fixture-nomark.md"
  cp "$JADE" "$WF/flavors/jaded-senior.md"

  if COUNCIL_VV_WF="$WF/workflow.js" COUNCIL_VV_FIX="$FIX" COUNCIL_VV_OUT="$TMP" \
node --input-type=module <<'JS'
import { readFileSync, writeFileSync } from 'node:fs'
const wf = await import(process.env.COUNCIL_VV_WF)
const OUT = process.env.COUNCIL_VV_OUT
const VARS = (name) => JSON.parse(readFileSync(`${process.env.COUNCIL_VV_FIX}/${name}`, 'utf8'))

const cases = [
  ['sections', 'tmpl-sections', 'vars-sections.json', null],
  ['nonl', 'tmpl-nonl', 'vars-empty.json', null],
  ['nofence', 'tmpl-nofence', 'vars-nofence.json', null],
  ['adjacent', 'tmpl-adjacent', 'vars-adjacent.json', null],
  ['flavor', 'tmpl-flavor', 'vars-flavor.json', 'fixture-delta'],
  ['flavornm', 'tmpl-flavor', 'vars-flavor.json', 'fixture-nomark'],
  ['investigator', 'investigator', 'vars-investigator.json', 'jaded-senior'],
  ['investnonm14', 'investigator', 'vars-investigator-nonm14.json', 'jaded-senior'],
  ['judge', 'judge', 'vars-judge.json', null],
]
for (const [out, tpl, varsFile, flavor] of cases) {
  const vars = VARS(varsFile)
  // The verifier derives FLAVOR_DELTA from --flavor and overrides any key,
  // exactly as loadPrompt callers do (workflow.js always computes it).
  if (flavor) vars.FLAVOR_DELTA = wf.loadFlavor(flavor)
  writeFileSync(`${OUT}/golden-${out}`, wf.loadPrompt(tpl, vars))
}
console.log('OK: goldens rendered through the real loadPrompt')
JS
  then
    ok "AC2 the real loadPrompt rendered the goldens"
  else
    fail_msg "AC2 loadPrompt golden render failed"
  fi

  # Each golden, byte-compared by the verifier against its own re-render.
  gvd() { # gvd <label> <mode> <template> <vars> <golden> [flavor]
    local label="$1" mode="$2" tpl="$3" vf="$4" g="$5" fl="${6:-}"
    if [ ! -f "$g" ]; then
      fail_msg "$label: golden file is missing"
      return 0
    fi
    if [ -n "$fl" ]; then
      vvd 0 "$label vs the real loadPrompt" \
        --mode "$mode" --template "$tpl" --vars "$vf" --rendered "$g" --flavor "$fl"
    else
      vvd 0 "$label vs the real loadPrompt" \
        --mode "$mode" --template "$tpl" --vars "$vf" --rendered "$g"
    fi
  }
  gvd "AC2 sections (kept block, one-pass, missing var)" investigator \
    "$FIX/tmpl-sections.md" "$FIX/vars-sections.json" "$TMP/golden-sections"
  gvd "AC2 fenced path" investigator "$FIX/tmpl-nonl.md" "$FIX/vars-empty.json" "$TMP/golden-nonl"
  gvd "AC2 no-fence path" investigator "$FIX/tmpl-nofence.md" "$FIX/vars-nofence.json" "$TMP/golden-nofence"
  gvd "AC2 adjacent markers + drop at EOF" investigator \
    "$FIX/tmpl-adjacent.md" "$FIX/vars-adjacent.json" "$TMP/golden-adjacent"
  gvd "AC2 FLAVOR_DELTA (marker cut, dropped block)" investigator \
    "$FIX/tmpl-flavor.md" "$FIX/vars-flavor.json" "$TMP/golden-flavor" "$FIX/flavor-delta.md"
  gvd "AC2 FLAVOR_DELTA (no marker)" investigator \
    "$FIX/tmpl-flavor.md" "$FIX/vars-flavor.json" "$TMP/golden-flavornm" "$FIX/flavor-nomark.md"
  gvd "AC2 investigator.md (M14 verify path)" investigator \
    "$INVESTIGATOR" "$FIX/vars-investigator.json" "$TMP/golden-investigator" "$JADE"
  gvd "AC2 investigator.md (VERIFY_COMMAND dropped)" investigator \
    "$INVESTIGATOR" "$FIX/vars-investigator-nonm14.json" "$TMP/golden-investnonm14" "$JADE"
  gvd "AC2 judge.md" judge "$JUDGE" "$FIX/vars-judge.json" "$TMP/golden-judge"

  # Trailing-newline semantics pinned on the real render, not by eyeball.
  if [ -n "$(tail -c 1 "$TMP/golden-nonl" | tr -d '\n')" ]; then
    ok "AC2 the fenced-path golden carries NO trailing newline"
  else
    fail_msg "AC2 the fenced-path golden ends with a newline"
  fi
  if [ "$(tail -c 2 "$TMP/golden-nofence" | od -An -c | tr -d ' \n')" = '\n\n' ]; then
    ok "AC2 the no-fence-path golden keeps both trailing newlines"
  else
    fail_msg "AC2 the no-fence-path golden lost its trailing newlines: $(tail -c 2 "$TMP/golden-nofence" | od -An -c)"
  fi
  # One-pass substitution proven on the real render: the value carried {{A}}.
  if grep -qF 'TAIL {{MISSING}} delta {{A}}' "$TMP/golden-sections"; then
    ok "AC2 real render: value-carrying {{A}} did not re-expand, missing var stayed literal"
  else
    fail_msg "AC2 real render lost the one-pass/missing-var shape"
  fi

  # The committed exit-0 fixtures byte-equal the real render (no fixture drift).
  if cmp -s "$TMP/golden-sections" "$FIX/rendered-good.md"; then
    ok "AC2 fixtures/rendered-good.md byte-equals the real render"
  else
    fail_msg "AC2 fixtures/rendered-good.md drifted from the real render"
  fi
  if cmp -s "$TMP/golden-nofence" "$FIX/rendered-nofence.md"; then
    ok "AC2 fixtures/rendered-nofence.md byte-equals the real render"
  else
    fail_msg "AC2 fixtures/rendered-nofence.md drifted from the real render"
  fi

  # Negative control (L1 precedent): a one-byte mutation of a real golden MUST
  # be reported, so the exit-0 goldens above are not vacuously true.
  cp "$TMP/golden-sections" "$TMP/golden-mut"
  printf 'X' >> "$TMP/golden-mut"
  mismatch "AC2 negative control: one byte appended to a real golden" 53 investigator \
    "$FIX/tmpl-sections.md" "$FIX/vars-sections.json" "$TMP/golden-mut"

  # ---- AC7: the live judge-render classes, mutated from a real golden -------
  if [ ! -f "$TMP/golden-judge" ]; then
    fail_msg "AC7 no judge golden to mutate"
  else
    JUDGE_LIM=$(( $(wc -c <"$TMP/golden-judge") + 1 ))
    # A dropped evidence-bundle block (CDT-613: a bundle vanished from the
    # dispatched judge prompt).
    awk '/^### `t2`/ { skip = 1 }
         skip && /^```$/ { fence = !fence; if (!fence) { skip = 0; next } }
         skip { next }
         { print }' "$TMP/golden-judge" > "$TMP/rendered-dropped-bundle"
    if [ -s "$TMP/rendered-dropped-bundle" ] \
      && ! cmp -s "$TMP/rendered-dropped-bundle" "$TMP/golden-judge"; then
      mismatch "AC7 dropped evidence-bundle block in the judge render" "$JUDGE_LIM" judge \
        "$JUDGE" "$FIX/vars-judge.json" "$TMP/rendered-dropped-bundle"
    else
      fail_msg "AC7 the dropped-bundle mutation changed nothing"
    fi
    # Empty payload where a bundle belongs.
    awk '/^\{"verdicts"/ { print "{}"; next } { print }' \
      "$TMP/golden-judge" > "$TMP/rendered-empty-payload"
    if [ -s "$TMP/rendered-empty-payload" ] \
      && ! cmp -s "$TMP/rendered-empty-payload" "$TMP/golden-judge"; then
      mismatch "AC7 empty payload where a bundle belongs" "$JUDGE_LIM" judge \
        "$JUDGE" "$FIX/vars-judge.json" "$TMP/rendered-empty-payload"
    else
      fail_msg "AC7 the empty-payload mutation changed nothing"
    fi
  fi
else
  echo "SKIP: AC2/AC7 goldens (node unavailable)"
fi

# ---- Summary ----------------------------------------------------------------
if [ "$fail" -eq 0 ]; then
  echo "PASS: test-verify-verbatim-dispatch.sh"
  exit 0
else
  echo "FAIL: test-verify-verbatim-dispatch.sh"
  exit 1
fi
