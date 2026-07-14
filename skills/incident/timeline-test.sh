#!/usr/bin/env bash
# timeline-test.sh — bite-tests for workspace.sh + timeline.sh (SPEC-027)
#
# Machine-check: bash skills/incident/timeline-test.sh  (exit 0)
# THIS SCRIPT IS A SUBPROCESS CLI — NEVER SOURCE IT.

set -u

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
WS="$SCRIPT_DIR/workspace.sh"
TL="$SCRIPT_DIR/timeline.sh"

PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); echo "PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "FAIL: $1" >&2; }

TMP=$(mktemp -d "${TMPDIR:-/tmp}/incident-test.XXXXXX")
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

export INCIDENT_ROOT="$TMP/incidents"
mkdir -p "$INCIDENT_ROOT"

# --- ensure creates dir + artifacts ---------------------------------------
DIR1=$(bash "$WS" ensure "checkout 500s")
RC=$?
if [ "$RC" -eq 0 ] && [ -d "$DIR1" ] && [ -f "$DIR1/timeline.jsonl" ] && [ -d "$DIR1/comms" ] && [ -f "$DIR1/meta.json" ]; then
  pass "ensure creates dir + timeline.jsonl + comms + meta.json"
else
  fail "ensure creates artifacts (rc=$RC dir=$DIR1)"
fi

ID1=$(basename "$DIR1")
case "$ID1" in
  *[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]-checkout-500s) pass "id shape YYYY-MM-DD-slug" ;;
  *) fail "id shape: got $ID1" ;;
esac

# slug sanitized
DIR_BAD=$(bash "$WS" ensure 'Foo/Bar!! Baz')
ID_BAD=$(basename "$DIR_BAD")
case "$ID_BAD" in
  *[!a-z0-9-]*) fail "slug not sanitized: $ID_BAD" ;;
  *-foo-bar-baz) pass "slug sanitized alnum/hyphen" ;;
  *)
    # allow date-prefix only check
    if printf '%s' "$ID_BAD" | grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2}-foo-bar-baz$'; then
      pass "slug sanitized alnum/hyphen"
    else
      fail "slug expected *-foo-bar-baz got $ID_BAD"
    fi
    ;;
esac

# collision suffix
DIR2=$(bash "$WS" ensure "checkout 500s")
ID2=$(basename "$DIR2")
if [ "$ID2" != "$ID1" ] && printf '%s' "$ID2" | grep -qE -- '-2$'; then
  pass "collision suffix -2"
else
  fail "collision: id1=$ID1 id2=$ID2"
fi

# path
P=$(bash "$WS" path "$ID1")
if [ "$P" = "$DIR1" ]; then
  pass "path returns absolute dir"
else
  fail "path: expected $DIR1 got $P"
fi

# missing path
if bash "$WS" path "no-such-incident" >/dev/null 2>&1; then
  fail "path missing should fail"
else
  pass "path missing exits non-zero"
fi

# --- append + validate ----------------------------------------------------
E1=$(bash "$TL" append "$ID1" --actor devops --type decision --summary "severity SEV2 confirmed" --detail "user override" --refs "sev:SEV2")
if [ "$E1" = "e001" ]; then
  pass "first append id e001"
else
  fail "first append id: got $E1"
fi

# snapshot first line
LINE1=$(head -n 1 "$DIR1/timeline.jsonl")
HASH1=$(printf '%s' "$LINE1" | sha256sum | awk '{print $1}')

E2=$(bash "$TL" append "$ID1" --actor devops --type observation --summary "git log shows recent deploy" --refs "commit:abc123")
if [ "$E2" = "e002" ]; then
  pass "second append id e002"
else
  fail "second append id: got $E2"
fi

LINE1_AFTER=$(head -n 1 "$DIR1/timeline.jsonl")
HASH1_AFTER=$(printf '%s' "$LINE1_AFTER" | sha256sum | awk '{print $1}')
if [ "$HASH1" = "$HASH1_AFTER" ] && [ "$LINE1" = "$LINE1_AFTER" ]; then
  pass "prior jsonl line byte-identical after second append"
else
  fail "prior line mutated"
fi

if bash "$TL" validate "$ID1" >/dev/null; then
  pass "validate ok after 2 entries"
else
  fail "validate failed"
fi

# md render has both
if grep -q 'e001' "$DIR1/timeline.md" && grep -q 'e002' "$DIR1/timeline.md" \
  && grep -q 'severity SEV2 confirmed' "$DIR1/timeline.md" \
  && grep -q 'git log shows recent deploy' "$DIR1/timeline.md"; then
  pass "timeline.md render contains both entries"
else
  fail "timeline.md missing entries"
fi

# bad type rejected
if bash "$TL" append "$ID1" --actor user --type note --summary "x" >/dev/null 2>&1; then
  fail "bad type should be rejected"
else
  pass "bad type rejected"
fi

# missing required
if bash "$TL" append "$ID1" --actor user --type action >/dev/null 2>&1; then
  fail "missing summary should be rejected"
else
  pass "missing summary rejected"
fi

# resume-dump
DUMP=$(bash "$WS" resume-dump "$ID1")
if printf '%s' "$DUMP" | grep -q '"status": "open"' \
  && printf '%s' "$DUMP" | grep -q 'e001' \
  && printf '%s' "$DUMP" | grep -q 'e002'; then
  pass "resume-dump shows meta + timeline tail"
else
  fail "resume-dump incomplete"
fi

# list
LIST=$(bash "$WS" list)
if printf '%s\n' "$LIST" | grep -qx "$ID1" && printf '%s\n' "$LIST" | grep -qx "$ID2"; then
  pass "list includes both incidents"
else
  fail "list missing ids: $LIST"
fi

# validate empty ok
DIR3=$(bash "$WS" ensure "empty-timeline")
ID3=$(basename "$DIR3")
if bash "$TL" validate "$ID3" | grep -q 'ok'; then
  pass "validate empty timeline ok"
else
  fail "validate empty failed"
fi

# corrupt line fails validate
printf '%s\n' 'not-json' >>"$DIR3/timeline.jsonl"
if bash "$TL" validate "$ID3" >/dev/null 2>&1; then
  fail "validate should fail on corrupt line"
else
  pass "validate fails on corrupt JSON"
fi

# meta-set
bash "$WS" meta-set "$ID1" '{"id":"'"$ID1"'","severity":"SEV2","status":"investigating","opened_at":"2026-07-14T00:00:00Z","description":"x","pending_proposal":{"cmd":"git revert abc"}}'
META=$(bash "$WS" meta-get "$ID1")
if printf '%s' "$META" | grep -q 'SEV2' && printf '%s' "$META" | grep -q 'git revert'; then
  pass "meta-set/get round-trip"
else
  fail "meta-set/get failed"
fi

DUMP2=$(bash "$WS" resume-dump "$ID1")
if printf '%s' "$DUMP2" | grep -q 'git revert'; then
  pass "resume-dump pending_proposal"
else
  fail "resume-dump missing pending"
fi

echo
echo "Results: PASS=$PASS FAIL=$FAIL"
if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
exit 0
