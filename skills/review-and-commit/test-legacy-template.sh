#!/usr/bin/env bash
# WP 3-05 — one user-facing review template for /council --diff and
# /review-and-commit. The review-and-commit dispatch is council --diff
# --tier full plus the commit gate. Bucket output for the fixture stays
# the same.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SKILL="$ROOT/skills/review-and-commit/SKILL.md"
COUNCIL="$ROOT/commands/council.md"
DOCS="$ROOT/docs/commands/council.md"
SPEC="$ROOT/specs/core/SPEC-010-code-review-release.md"
TMPL="$ROOT/skills/council/templates/legacy-review.md"
BUCKET="$ROOT/skills/review-and-commit/bucket.sh"
fail=0
pass=0
ok() { echo "OK: $1"; pass=$((pass + 1)); }
bad() { echo "FAIL: $1"; fail=$((fail + 1)); }

HEADING='## Critical Issues (Must Fix) [confidence 95-100]'

# one_home DIR — files under DIR that contain HEADING, one path per line.
one_home() {
  grep -R -l -F --include='*.md' -e "$HEADING" "$1" 2>/dev/null || true
}

live=$( { one_home "$ROOT/skills/review-and-commit"; one_home "$ROOT/skills/council"; one_home "$ROOT/commands"; } | sort )
if [ "$live" = "$TMPL" ]; then
  ok "the Step 6 heading lives only in the council template"
else
  bad "the Step 6 heading is not only in the template: ${live:-<none>}"
fi

# Planted negative: a second copy makes the predicate fail.
NEG=$(mktemp -d "${TMPDIR:-/tmp}/rc-legacy-neg.XXXXXX")
mkdir -p "$NEG/skills/council/templates" "$NEG/skills/review-and-commit"
printf '%s\n' "$HEADING" > "$NEG/skills/council/templates/legacy-review.md"
printf '%s\n' "$HEADING" > "$NEG/skills/review-and-commit/SKILL.md"
neg_live=$( { one_home "$NEG/skills"; } | sort )
if [ "$(printf '%s\n' "$neg_live" | wc -l | tr -d ' ')" -eq 2 ]; then
  ok "control: a second copy of the heading fails the one-home predicate"
else
  bad "control: second copy was not detected: ${neg_live:-<none>}"
fi
rm -rf "$NEG"

if [ -f "$TMPL" ] && grep -qF '## Overall Assessment' "$TMPL" \
  && grep -qF '## Compliance Violations' "$TMPL" \
  && grep -qF 'Review stats:' "$TMPL"; then
  ok "the template carries the load-bearing review sections"
else
  bad "the template is missing load-bearing sections"
fi

if grep -qF 'equivalent to /review-and-commit' "$COUNCIL"; then
  bad "commands/council.md still calls --diff equivalent to review-and-commit"
else
  ok "commands/council.md does not call the commands equivalent"
fi
if printf '%s\n' 'equivalent to /review-and-commit' | grep -qF 'equivalent to /review-and-commit'; then
  ok "control: the equivalent-phrase probe matches the old wording"
else
  bad "control: the equivalent-phrase probe is dead"
fi

for f in "$SKILL" "$COUNCIL" "$DOCS" "$SPEC"; do
  if [ -f "$f" ] && grep -qF 'skills/council/templates/legacy-review.md' "$f"; then
    ok "cites the shared template: ${f#"$ROOT"/}"
  else
    bad "missing shared-template cite: ${f#"$ROOT"/}"
  fi
done

if grep -qF 'council --diff --tier full' "$SKILL"; then
  ok "review-and-commit is council --diff --tier full"
else
  bad "SKILL.md does not name council --diff --tier full"
fi

diff_review=$(awk '
  /^### Diff user-facing review/ { insec = 1; next }
  insec && /^### / { exit }
  insec { print }
' "$COUNCIL")
if printf '%s\n' "$diff_review" | grep -qF 'skills/review-and-commit/bucket.sh' \
  && printf '%s\n' "$diff_review" | grep -qF 'skills/council/templates/legacy-review.md'; then
  ok "council --diff prints the shared template via bucket.sh"
else
  bad "council --diff has no shared-template render step"
fi
if grep -qF 'council_tier: full' "$SKILL"; then
  ok "the workflow dispatch passes council_tier full"
else
  bad "the workflow dispatch omits council_tier full"
fi

# The Step 3 preflight fence must pass --tier full. Bound the section so a
# later mention cannot satisfy the check.
s3=$(awk '
  /^## Step 3: Preflight/ { insec = 1; next }
  insec && /^## / { exit }
  insec { print }
' "$SKILL")
if printf '%s\n' "$s3" | grep -qF -- '--tier full'; then
  ok "the preflight fence passes --tier full"
else
  bad "the preflight fence does not pass --tier full"
fi

FIX=$(mktemp "${TMPDIR:-/tmp}/rc-legacy-fix.XXXXXX.json")
GOLD=$(mktemp "${TMPDIR:-/tmp}/rc-legacy-gold.XXXXXX.txt")
trap 'rm -f -- "$FIX" "$GOLD"' EXIT
cat > "$FIX" <<'JSON'
[{"file":"a.js","line":4,"severity":"critical","category":"logic","description":"nil deref","suggestion":"return empty","confidence":97,"tool_use_id":"t1"},{"file":"b.md","line":1,"severity":"warning","category":"compliance","description":"missing frontmatter","suggestion":"add name","confidence":99,"tool_use_id":"t2"},{"file":"c.js","line":8,"severity":"warning","category":"design","description":"one-impl interface","suggestion":"delete it","confidence":88,"tool_use_id":"t3"},{"file":"d.js","line":2,"severity":"warning","category":"security","description":"secret in log","suggestion":"redact","confidence":91,"tool_use_id":"t4"},{"file":"e.js","line":3,"severity":"nitpick","category":"simplification","description":"dead helper","suggestion":"delete helper","confidence":84,"tool_use_id":"t5"},{"file":"f.js","line":9,"severity":"nitpick","category":"logic","description":"name lies","suggestion":"rename","confidence":80,"tool_use_id":"t6"}]
JSON
cat > "$GOLD" <<'GOLD'
## Compliance Violations
- b.md:1 — missing frontmatter [compliance, warning]

## Critical Issues (Must Fix) [confidence 95-100]
- a.js:4 — nil deref [logic, critical]

## Design Problems [confidence 80-94]
- c.js:8 — one-impl interface [design, warning]

## Nitpicks (Yes, They Matter) [confidence 80-94]
- f.js:9 — name lies [logic, nitpick]

## Security & PII [confidence 80-94]
- d.js:2 — secret in log [security, warning]

## Simplification Opportunities
- e.js:3 — dead helper [simplification, nitpick]
GOLD
got=$(bash "$BUCKET" < "$FIX")
if [ "$got" = "$(cat "$GOLD")" ]; then
  ok "bucket output for the fixture is unchanged"
else
  bad "bucket output changed: $got"
fi

# Real finalize path: scope diff prints bucket.sh over unstruck findings.
# A struck row must not appear. A claim-scope run must not print the review.
ENG="$ROOT/skills/council/engine.sh"
FIXDIR="$ROOT/skills/council/fixtures/finalize-missing-tid"
FIN=$(mktemp -d "${TMPDIR:-/tmp}/rc-legacy-fin.XXXXXX")
jq --arg rp "$FIN/report.md" 'del(.task_id) | .report_path=$rp' \
  "$FIXDIR/plan-finding.json" > "$FIN/plan.json"
set +e
fin_out=$(bash "$ENG" finalize --plan-file "$FIN/plan.json" \
  --evidence-file "$FIXDIR/evidence-mixed.json" \
  --judge-output "$FIXDIR/judge-mixed.json" --report-out "$FIN/report.md" 2>"$FIN/err")
fin_rc=$?
set -e
if [ "$fin_rc" -eq 0 ] \
  && printf '%s\n' "$fin_out" | grep -qF '## Other' \
  && printf '%s\n' "$fin_out" | grep -qF 'must remain unstruck' \
  && ! printf '%s\n' "$fin_out" | grep -qF 'must be struck and must not block'; then
  ok "diff finalize prints the unstruck legacy review"
else
  bad "diff finalize review rc=$fin_rc err=$(head -c 200 "$FIN/err") out=$(printf '%s' "$fin_out" | head -c 300)"
fi
jq --arg rp "$FIN/claim.md" '.scope="claim" | .preset="generic" | .output_shape="verdict[]" | del(.task_id) | .report_path=$rp' \
  "$FIXDIR/plan-finding.json" > "$FIN/claim-plan.json"
# claim scope uses the same files only to prove the review is not appended.
# The engine may reject the shape mismatch. That still must not print the heading
# from a successful diff render. Skip when finalize itself rejects the plan.
set +e
claim_out=$(bash "$ENG" finalize --plan-file "$FIN/claim-plan.json" \
  --evidence-file "$FIXDIR/evidence-mixed.json" \
  --judge-output "$FIXDIR/judge-mixed.json" --report-out "$FIN/claim.md" 2>"$FIN/claim.err")
claim_rc=$?
set -e
if printf '%s\n' "$claim_out" | grep -qF '## Other'; then
  bad "claim finalize printed the diff review (rc=$claim_rc)"
else
  ok "claim finalize does not print the diff review"
fi
rm -rf "$FIN"

echo
echo "PASS=$pass FAIL=$fail"
[ "$fail" -eq 0 ]
