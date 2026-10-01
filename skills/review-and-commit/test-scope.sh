#!/usr/bin/env bash
# WP 2-09 — reviewed set includes untracked files, commit stages only that
# set, category buckets, and the stats line counts an available external slot.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CHANGED="$ROOT/skills/lib/changed-set.sh"
STAGE="$ROOT/skills/review-and-commit/stage-reviewed.sh"
BUCKET="$ROOT/skills/review-and-commit/bucket.sh"
STATS="$ROOT/skills/review-and-commit/stats-line.sh"
fail=0
pass=0
ok() { echo "OK: $1"; pass=$((pass + 1)); }
bad() { echo "FAIL: $1"; fail=$((fail + 1)); }

TMP=$(mktemp -d "${TMPDIR:-/tmp}/rc-scope.XXXXXX")
trap 'rm -rf "$TMP"' EXIT
git init -q "$TMP/repo"
git -C "$TMP/repo" -c user.email=t@t -c user.name=t commit -qm init --allow-empty
printf 'tracked\n' >"$TMP/repo/tracked.txt"
git -C "$TMP/repo" add tracked.txt
git -C "$TMP/repo" -c user.email=t@t -c user.name=t commit -qm tracked
printf 'staged-edit\n' >>"$TMP/repo/tracked.txt"
git -C "$TMP/repo" add tracked.txt
printf 'unstaged\n' >"$TMP/repo/unstaged.txt"
printf 'brand-new\n' >"$TMP/repo/brand-new.txt"
paths=$(bash "$CHANGED" -C "$TMP/repo" paths)
printf '%s\n' "$paths" | grep -Fxq brand-new.txt && ok "untracked file is in the changed set" || bad "untracked missing: $paths"
printf '%s\n' "$paths" | grep -Fxq tracked.txt && ok "staged file is in the changed set" || bad "staged missing: $paths"

# Refuse when a dirty path is outside the reviewed list. Nothing new is staged.
printf 'tracked.txt\nbrand-new.txt\n' >"$TMP/list-partial"
if bash "$STAGE" -C "$TMP/repo" --list "$TMP/list-partial" >/dev/null 2>"$TMP/refuse.err"; then
  bad "stage-reviewed accepted a set that omitted unstaged.txt"
else
  ok "stage-reviewed refuses a path outside the reviewed set"
fi
if git -C "$TMP/repo" diff --cached --name-only | grep -qx unstaged.txt; then
  bad "refused run still staged unstaged.txt"
else
  ok "refused run did not stage the extra path"
fi

printf 'tracked.txt\nunstaged.txt\nbrand-new.txt\n' >"$TMP/list-all"
if bash "$STAGE" -C "$TMP/repo" --list "$TMP/list-all"; then
  ok "stage-reviewed stages the full reviewed set"
else
  bad "stage-reviewed rejected the full set"
fi
cached=$(git -C "$TMP/repo" diff --cached --name-only | sort)
printf '%s\n' "$cached" | grep -Fxq brand-new.txt && ok "commit index contains the untracked file" || bad "index missing brand-new.txt: $cached"
printf '%s\n' "$cached" | grep -Fxq unstaged.txt && ok "commit index contains the reviewed unstaged file" || bad "index missing unstaged.txt"

printf 'gone\n' >"$TMP/repo/gone.txt"
git -C "$TMP/repo" add gone.txt
git -C "$TMP/repo" -c user.email=t@t -c user.name=t commit -qm gone
git -C "$TMP/repo" rm -q gone.txt
mkdir -p "$TMP/repo/newdir"
printf 'a\n' >"$TMP/repo/newdir/a.txt"
printf 'space\n' >"$TMP/repo/my file.txt"
paths2=$(bash "$CHANGED" -C "$TMP/repo" paths)
printf '%s\n' "$paths2" | grep -Fxq gone.txt && ok "staged deletion is in the changed set" || bad "deletion missing: $paths2"
printf '%s\n' "$paths2" | grep -Fxq newdir/a.txt && ok "file inside a new directory is in the changed set" || bad "nested untracked missing: $paths2"
printf '%s\n' "$paths2" | grep -Fxq 'my file.txt' && ok "untracked path with a space is in the changed set" || bad "spaced path missing: $paths2"
printf '%s\n' "$paths2" >"$TMP/list-del"
if bash "$STAGE" -C "$TMP/repo" --list "$TMP/list-del"; then
  ok "stage-reviewed accepts the changed set, including a deletion and a nested file"
else
  bad "stage-reviewed refused the full changed set"
fi

report=$(printf '%s\n' '[{"file":"a.js","line":4,"severity":"warning","category":"logic","description":"LOGIC_WARNING_MARKER","suggestion":"x","confidence":90,"tool_use_id":"t"}]' | bash "$BUCKET")
printf '%s\n' "$report" | grep -q 'LOGIC_WARNING_MARKER' && ok "logic warning appears in the rendered report" || bad "logic warning missing: $report"
printf '%s\n' "$report" | grep -q '## Critical Issues' && ok "logic warning is in Critical Issues" || bad "logic warning section: $report"
other=$(printf '%s\n' '[{"file":"b.js","line":1,"severity":"warning","category":"nope","description":"OTHER_MARKER","suggestion":"x","confidence":80,"tool_use_id":"t"}]' | bash "$BUCKET")
printf '%s\n' "$other" | grep -q '## Other' && ok "unknown category lands in Other" || bad "Other bucket missing: $other"

# Every category literal the flavors and the external mapper emit has a bucket.
cats=$(grep -h '"category":' "$ROOT"/skills/council/flavors/*.md | sed -n 's/.*"category": *"\([^"]*\)".*/\1/p' | sort -u)
mapcats=$(sed -n '/def category_of:/,/else/p' "$ROOT/skills/council/external-reviewer.sh" | sed -n 's/.*then "\([^"]*\)".*/\1/p' | sort -u)
missing=0
for c in $cats $mapcats; do
  if ! grep -q "\"$c\"" "$BUCKET" && ! grep -q "category == \"$c\"" "$BUCKET"; then
    echo "no bucket for category $c"
    missing=1
  fi
done
[ "$missing" -eq 0 ] && ok "every flavor and mapper category has a Step 6 bucket" || bad "a category has no bucket"

node --input-type=module <<JS
import { FindingSchema } from '$ROOT/skills/council/workflow-schemas.js'
const en = FindingSchema.properties.findings.items.properties.category.enum
if (!Array.isArray(en)) throw new Error('category enum missing')
if (en.includes('nope')) throw new Error('enum accepted nope')
if (en.includes('quality')) throw new Error('enum still has quality; vocabulary is design')
for (const c of ['logic', 'security', 'compliance', 'design', 'simplification']) {
  if (!en.includes(c)) throw new Error('enum missing ' + c)
}
console.log('OK: schema enum rejects unknown categories')
JS

printf '%s\n' '{"flavors":["logic","security","compliance","quality","simplification"],"external":{"status":"available"}}' >"$TMP/plan.json"
line=$(bash "$STATS" "$TMP/plan.json" 3 2 1)
printf '%s\n' "$line" | grep -q 'from 6 agents' && ok "stats line counts the external reviewer" || bad "stats line: $line"
printf '%s\n' '{"flavors":["logic","security"],"external":{"status":"skipped"}}' >"$TMP/plan2.json"
line2=$(bash "$STATS" "$TMP/plan2.json" 1 1 0)
printf '%s\n' "$line2" | grep -q 'from 2 agents' && ok "stats line omits a skipped external slot" || bad "stats line 2: $line2"

echo
echo "PASS=$pass FAIL=$fail"
[ "$fail" -eq 0 ]
