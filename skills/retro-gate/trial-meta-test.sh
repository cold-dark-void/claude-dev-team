#!/usr/bin/env bash
# trial-meta-test.sh — unit tests for trial-meta.sh (CDV-200)
set -u

HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
META="$HERE/trial-meta.sh"
PASS=0
FAIL=0

ok()  { PASS=$((PASS + 1)); echo "PASS: $*"; }
bad() { FAIL=$((FAIL + 1)); echo "FAIL: $*"; }

# ── parse happy ──────────────────────────────────────────────────────────────
LINE='3. Always run bash -n before writing scripts <!-- trial start=2026-07-01 source=sess-abc#anchor-1 review-after=10-sessions -->'
out=$(bash "$META" parse "$LINE") || { bad "parse happy exit"; out=""; }
text=$(printf '%s' "$out" | cut -f1)
start=$(printf '%s' "$out" | cut -f2)
src=$(printf '%s' "$out" | cut -f3)
ra=$(printf '%s' "$out" | cut -f4)
[ "$text" = "3. Always run bash -n before writing scripts" ] && ok "parse text" || bad "parse text got='$text'"
[ "$start" = "2026-07-01" ] && ok "parse start" || bad "parse start got='$start'"
[ "$src" = "sess-abc#anchor-1" ] && ok "parse source" || bad "parse source got='$src'"
[ "$ra" = "10-sessions" ] && ok "parse review-after" || bad "parse review-after got='$ra'"

# ── parse missing ────────────────────────────────────────────────────────────
bash "$META" parse "1. permanent directive only" >/dev/null 2>&1
rc=$?
[ "$rc" -eq 1 ] && ok "parse missing meta rc=1" || bad "parse missing want rc=1 got $rc"

# ── parse malformed (missing required key) ───────────────────────────────────
bash "$META" parse '1. foo <!-- trial start=2026-07-01 source=s#a -->' >/dev/null 2>&1
rc=$?
[ "$rc" -eq 1 ] && ok "parse missing review-after rc=1" || bad "parse incomplete want 1 got $rc"

# ── parse ignores unknown keys ───────────────────────────────────────────────
out=$(bash "$META" parse '1. foo <!-- trial start=2026-07-01 source=s#a review-after=5-sessions extra=zzz -->') || out=""
ra=$(printf '%s' "$out" | cut -f4)
[ "$ra" = "5-sessions" ] && ok "parse ignore unknown key" || bad "parse unknown key ra='$ra'"

# ── annotate ─────────────────────────────────────────────────────────────────
ann=$(bash "$META" annotate \
  --text "Always run bash -n" \
  --start "2026-07-03" \
  --source "uuid#msg" \
  --review-after "10-sessions")
case "$ann" in
  "Always run bash -n <!-- trial start=2026-07-03 source=uuid#msg review-after=10-sessions -->")
    ok "annotate form"
    ;;
  *)
    bad "annotate form got='$ann'"
    ;;
esac

# ── annotate/parse round-trip ────────────────────────────────────────────────
rt=$(bash "$META" parse "$ann") || rt=""
[ "$(printf '%s' "$rt" | cut -f1)" = "Always run bash -n" ] && ok "round-trip text" || bad "round-trip text"
[ "$(printf '%s' "$rt" | cut -f2)" = "2026-07-03" ] && ok "round-trip start" || bad "round-trip start"
[ "$(printf '%s' "$rt" | cut -f3)" = "uuid#msg" ] && ok "round-trip source" || bad "round-trip source"
[ "$(printf '%s' "$rt" | cut -f4)" = "10-sessions" ] && ok "round-trip review-after" || bad "round-trip review-after"

# ── strip ────────────────────────────────────────────────────────────────────
st=$(bash "$META" strip "$LINE")
[ "$st" = "3. Always run bash -n before writing scripts" ] && ok "strip comment" || bad "strip got='$st'"
st2=$(bash "$META" strip "1. plain")
[ "$st2" = "1. plain" ] && ok "strip plain passthrough" || bad "strip plain got='$st2'"

# ── is-elapsed N-sessions ────────────────────────────────────────────────────
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
# start=2026-07-01 → epoch
start_ep=$(date -u -d "2026-07-01 00:00:00" +%s 2>/dev/null || date -u -j -f "%Y-%m-%d %H:%M:%S" "2026-07-01 00:00:00" +%s)
# 3 mtimes after start, 1 before
before=$((start_ep - 86400))
after1=$((start_ep + 100))
after2=$((start_ep + 200))
after3=$((start_ep + 300))
printf '%s\n' "$before" "$after1" "$after2" "$after3" >"$TMP/mtimes"

el=$(bash "$META" is-elapsed --start 2026-07-01 --review-after 3-sessions --session-mtimes-file "$TMP/mtimes")
[ "$el" = "true" ] && ok "is-elapsed 3-sessions true" || bad "is-elapsed 3-sessions want true got $el"

el=$(bash "$META" is-elapsed --start 2026-07-01 --review-after 4-sessions --session-mtimes-file "$TMP/mtimes")
[ "$el" = "false" ] && ok "is-elapsed 4-sessions false" || bad "is-elapsed 4-sessions want false got $el"

el=$(bash "$META" is-elapsed --start 2026-07-01 --review-after 10-sessions --session-mtimes-file "$TMP/mtimes")
[ "$el" = "false" ] && ok "is-elapsed 10-sessions false" || bad "is-elapsed 10-sessions want false got $el"

# ── is-elapsed D-days ────────────────────────────────────────────────────────
el=$(bash "$META" is-elapsed --start 2026-07-01 --review-after 10-days --today 2026-07-11)
[ "$el" = "true" ] && ok "is-elapsed 10-days exact true" || bad "is-elapsed 10-days want true got $el"

el=$(bash "$META" is-elapsed --start 2026-07-01 --review-after 10-days --today 2026-07-10)
[ "$el" = "false" ] && ok "is-elapsed 10-days short false" || bad "is-elapsed 10-days short want false got $el"

el=$(bash "$META" is-elapsed --start 2026-07-01 --review-after 14-days --today 2026-07-20)
[ "$el" = "true" ] && ok "is-elapsed 14-days true" || bad "is-elapsed 14-days want true got $el"

# ── grep -c still counts annotated lines ─────────────────────────────────────
printf '%s\n' "$LINE" "2. plain" >"$TMP/dir.md"
cnt=$(grep -c '^[0-9]' "$TMP/dir.md")
[ "$cnt" -eq 2 ] && ok "grep count annotated" || bad "grep count want 2 got $cnt"

echo "---"
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
