#!/usr/bin/env bash
# WP 5-06 contract: ticket-mode home, status pass, append-only memory write,
# land-no-release stays a real parse-flags token, effort list is 10 names.
set -u
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT=$(CDPATH= cd -- "$HERE/../.." && pwd)
PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); printf 'PASS %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf 'FAIL %s — %s\n' "$1" "$2"; }

status_of() {
  sed -n 's/^\*\*Status\*\*: //p' "$1" | head -n 1
}

expect_status() {
  local file="$1" want="$2" got
  got=$(status_of "$ROOT/specs/core/$file")
  [ "$got" = "$want" ] && pass "$file is $want" || fail "$file status" "got=$got want=$want"
}

expect_status SPEC-012-session-retrospective.md ACTIVE
expect_status SPEC-014-debug-workflow.md ACTIVE
expect_status SPEC-015-refactor-workflow.md ACTIVE
expect_status SPEC-031-escalation-gate.md ACTIVE
expect_status SPEC-033-autopilot-policy.md ACTIVE
expect_status SPEC-034-bug-hunt-workflow.md DRAFT
expect_status SPEC-035-context-audit.md ACTIVE
expect_status SPEC-036-transcript-mirror.md ACTIVE
expect_status SPEC-037-per-agent-model-map.md ACTIVE

index_status() {
  awk -F'|' -v id="$1" '
    $2 ~ "^ " id " " { gsub(/ /,"",$4); print $4; exit }
  ' "$ROOT/specs/TDD.md"
}

for pair in \
  SPEC-012:ACTIVE SPEC-014:ACTIVE SPEC-015:ACTIVE SPEC-028:DEPRECATED \
  SPEC-031:ACTIVE SPEC-033:ACTIVE SPEC-034:DRAFT SPEC-035:ACTIVE \
  SPEC-036:ACTIVE SPEC-037:ACTIVE
do
  id=${pair%%:*}
  want=${pair#*:}
  got=$(index_status "$id")
  [ "$got" = "$want" ] && pass "index $id $want" || fail "index $id" "got=$got want=$want"
done

if grep -q 'superseded by SPEC-014' "$ROOT/specs/core/SPEC-028-fix-ticket-workflow.md" \
   && ! grep -q 'remain authoritative' "$ROOT/specs/core/SPEC-028-fix-ticket-workflow.md" \
   && ! grep -q 'deferred to v1.1' "$ROOT/specs/core/SPEC-014-debug-workflow.md" \
   && grep -q 'self-verified — refuters unavailable' "$ROOT/specs/core/SPEC-014-debug-workflow.md"; then
  pass "ticket protocol home is SPEC-014"
else
  fail "ticket fold" "SPEC-014/028 wording"
fi

if grep -q 'MUST append when writing back to DB memory' "$ROOT/specs/core/SPEC-009-ticket-workflow.md" \
   && ! grep -q 'MUST use `INSERT OR REPLACE` when writing back to DB memory' "$ROOT/specs/core/SPEC-009-ticket-workflow.md"; then
  pass "memory write is append"
else
  fail "SPEC-009 memory write" "old INSERT OR REPLACE sentence still required"
fi

if grep -q '10 M8 names' "$ROOT/specs/core/SPEC-037-per-agent-model-map.md" \
   && ! grep -q '8 M8 names' "$ROOT/specs/core/SPEC-037-per-agent-model-map.md" \
   && grep -q 'resolve-model.sh --effort' "$ROOT/skills/model-map/resolve-model.sh"; then
  pass "effort list is 10 and the resolver still accepts --effort"
else
  fail "effort contract" "count or resolver"
fi

if grep -q 'non-epic `--autopilot=master` is land-no-release' "$ROOT/AGENTS.md" \
   && grep -q 'epic children' "$ROOT/specs/core/SPEC-033-autopilot-policy.md" \
   && grep -q 'untagged land-no-release commit is not a dirty finding' "$ROOT/specs/core/SPEC-010-code-review-release.md"; then
  pass "land-no-release is documented on both sides"
else
  fail "land-no-release docs" "missing cross-ref"
fi

OUT=$(bash "$ROOT/skills/autopilot/parse-flags.sh" --autopilot=master 2>/dev/null) || true
if printf '%s' "$OUT" | jq -e '.enabled == true and .bump == "master" and .source == "flag"' >/dev/null 2>&1; then
  pass "parse-flags --autopilot=master is still land-no-release"
else
  fail "parse-flags" "out=$OUT"
fi

if grep -q 'must not cite a DRAFT spec' "$ROOT/specs/core/SPEC-008-spec-management.md" \
   && grep -q 'CDT-292' "$ROOT/specs/core/SPEC-034-bug-hunt-workflow.md"; then
  pass "ACTIVE must not cite a DRAFT; SPEC-034 records why it stays DRAFT"
else
  fail "status rule" "SPEC-008 or SPEC-034"
fi

m1=$(awk '/^\- \*\*M1 /,/^\- \*\*M2 /' "$ROOT/specs/core/SPEC-028-fix-ticket-workflow.md")
if printf '%s\n' "$m1" | grep -q 'commands/debug.md' \
   && ! printf '%s\n' "$m1" | grep -q 'MUST be a Deprecation stub'; then
  pass "SPEC-028 M1 does not require a deprecation stub"
else
  fail "SPEC-028 M1" "still requires a deprecation stub file"
fi

if grep -q 'ticket contract: SPEC-014' "$ROOT/docs/commands/debug.md" \
   && ! grep -q 'ticket pipeline (SPEC-028)' "$ROOT/docs/commands/debug.md" \
   && ! grep -q 'ticket contract: SPEC-028' "$ROOT/docs/commands/debug.md"; then
  pass "docs/commands/debug.md ticket contract is SPEC-014"
else
  fail "docs debug page" "still names SPEC-028 as the ticket contract"
fi

printf '%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
