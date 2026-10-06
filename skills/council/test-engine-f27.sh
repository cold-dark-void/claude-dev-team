#!/usr/bin/env bash
# F-27: scope is validated with an explicit preset; portable slug sed;
# missing python3; report mode is umask-normal, not mkstemp 0600;
# omitted completion_time uses the finalize timestamp.
set -u

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
ENGINE="$ROOT/skills/council/engine.sh"
FIX="$ROOT/skills/council/fixtures/finalize-task-id"
fail=0

TMP="$(mktemp -d "${TMPDIR:-/tmp}/engine-f27.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

ok() { echo "OK: $1"; }
bad() { echo "FAIL: $1"; fail=1; }

set +e
err="$(bash "$ENGINE" preflight --scope bogus --preset generic 2>&1 >/dev/null)"
rc=$?
set -e
if [ "$rc" -eq 2 ] && printf '%s\n' "$err" | grep -q 'unknown scope: bogus'; then
  ok "explicit --preset does not skip scope validation"
else
  bad "bogus scope rc=$rc err=$err"
fi

if grep -F 's/^-\+' "$ENGINE" >/dev/null 2>&1 || grep -F "s/^-\\\\+" "$ENGINE" >/dev/null 2>&1; then
  bad "engine.sh still uses GNU sed \+"
else
  ok "slug sed is not GNU \+"
fi

planf="$TMP/---Weird--Name.md"
printf '# plan\n' > "$planf"
slug="$(bash "$ENGINE" preflight --scope plan --scope-arg "$planf" --preset generic | jq -r '.slug')"
if [ "$slug" = "plan-Weird-Name" ]; then
  ok "portable slug strips leading dashes: $slug"
else
  bad "slug=$slug want plan-Weird-Name"
fi

BIN="$TMP/bin"
mkdir -p "$BIN"
BASH_BIN="$(command -v bash)"
for c in jq git dirname basename sed date mktemp; do
  src="$(command -v "$c" 2>/dev/null || true)"
  [ -n "$src" ] && ln -s "$src" "$BIN/$c"
done
set +e
err="$(PATH="$BIN" "$BASH_BIN" "$ENGINE" finalize --plan-file "$FIX/plan-unbound.json" 2>&1 >/dev/null)"
rc=$?
set -e
if [ "$rc" -eq 127 ] && printf '%s\n' "$err" | grep -q 'python3 is required'; then
  ok "missing python3 exits 127 with a clear error"
else
  bad "python3 check rc=$rc err=$err"
fi

REPO="$TMP/repo"
mkdir -p "$REPO"
git init -q "$REPO"
# Keep completion_time "0s" on one run; drop it on the other.
jq 'del(.report_path)' "$FIX/plan-unbound.json" > "$TMP/plan-keep.json"
jq 'del(.report_path, .completion_time)' "$FIX/plan-unbound.json" > "$TMP/plan-notime.json"
umask 022
(
  cd "$REPO" || exit 1
  bash "$ENGINE" finalize --plan-file "$TMP/plan-keep.json" \
    --evidence-file "$FIX/evidence.json" --judge-output "$FIX/judge.json" \
    --report-out "$TMP/keep.md" >/dev/null
)
mode="$(stat -c %a "$TMP/keep.md" 2>/dev/null || stat -f %Lp "$TMP/keep.md" 2>/dev/null)"
if [ "$mode" = "644" ]; then
  ok "report mode is 644 under umask 022 (not mkstemp 600)"
else
  bad "report mode=$mode want 644"
fi
if grep -q 'Completion time | 0s' "$TMP/keep.md"; then
  ok "plan completion_time 0s is kept"
else
  bad "kept completion_time missing: $(grep -n 'Completion time' "$TMP/keep.md")"
fi

(
  cd "$REPO" || exit 1
  bash "$ENGINE" finalize --plan-file "$TMP/plan-notime.json" \
    --evidence-file "$FIX/evidence.json" --judge-output "$FIX/judge.json" \
    --report-out "$TMP/notime.md" >/dev/null
)
if grep -q 'Completion time | N/A' "$TMP/notime.md"; then
  bad "omitted completion_time still N/A"
elif grep -E 'Completion time \| [0-9]{4}-' "$TMP/notime.md" >/dev/null; then
  ok "omitted completion_time uses the finalize timestamp"
else
  bad "completion line: $(grep 'Completion time' "$TMP/notime.md")"
fi

if [ "$fail" -eq 0 ]; then echo "ALL PASS"; else echo "FAILURES PRESENT"; fi
exit "$fail"
