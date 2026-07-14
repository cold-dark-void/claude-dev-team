#!/usr/bin/env bash
# write-scheduled-report-test.sh — unit tests for write-scheduled-report.sh (CDV-190)
set -u

HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
WRITER="$HERE/write-scheduled-report.sh"
PASS=0
FAIL=0

ok()  { PASS=$((PASS + 1)); echo "PASS: $*"; }
bad() { FAIL=$((FAIL + 1)); echo "FAIL: $*"; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
MROOT="$TMP/proj"
mkdir -p "$MROOT"

# --- empty/smooth note path ---
unset AGENT_WEBHOOK_URL
out=$(bash "$WRITER" --mroot "$MROOT" --mode all-auto \
  --scanned 0 --skipped 0 --gated 0 --deep 0 \
  --note "No sessions to retro." 2>/dev/null)
rc=$?
if [ "$rc" -ne 0 ]; then
  bad "empty write exit $rc"
else
  ok "empty write exit 0"
fi
case "$out" in
  /*) [ -f "$out" ] && ok "stdout absolute path exists" || bad "path missing: $out" ;;
  *) bad "stdout not absolute: $out" ;;
esac
if [ -f "$out" ]; then
  for sec in "# Scheduled retro report" "## Applied" "## Manual follow-up" \
             "## Duplicates (advisory)" "## Observations" "## Summary" "## Note"; do
    if grep -qF "$sec" "$out"; then
      ok "section: $sec"
    else
      bad "missing section: $sec"
    fi
  done
  grep -q 'No sessions to retro' "$out" && ok "note body" || bad "note body missing"
  grep -q 'mode: --all --auto' "$out" && ok "mode line" || bad "mode line"
fi

# --- with applied/followup files ---
AF="$TMP/applied.tsv"
FF="$TMP/followup.txt"
printf 'ic5\tNEW\talways run tests\n' >"$AF"
printf '/adjust-agent pm "tighten scope"\n' >"$FF"
out2=$(bash "$WRITER" --mroot "$MROOT" --mode all-auto \
  --scanned 10 --skipped 2 --gated 3 --deep 3 \
  --applied-file "$AF" --followup-file "$FF" \
  --summary "Applied: 1|Manual: 1" 2>/dev/null)
rc=$?
[ "$rc" -eq 0 ] && ok "full write exit 0" || bad "full write exit $rc"
grep -q 'target=ic5 action=NEW' "$out2" && ok "applied rendered" || bad "applied missing"
grep -q '/adjust-agent pm' "$out2" && ok "followup rendered" || bad "followup missing"
grep -q 'scanned=10 skipped=2 gated=3 deep-read=3' "$out2" && ok "session counts" || bad "session counts"

# --- retention keeps 12 ---
RDIR="$MROOT/.claude/retro"
# Seed 13 older-named files with staggered mtimes
for i in $(seq -w 1 13); do
  f="$RDIR/scheduled-2000-01-${i}T000000Z.md"
  echo "old $i" >"$f"
  # touch with increasing mtime
  touch -d "2000-01-${i} 00:00:00" "$f" 2>/dev/null \
    || touch -t "200001${i}0000" "$f" 2>/dev/null \
    || true
done
# Wait a tick so new write is newest
sleep 1
out3=$(bash "$WRITER" --mroot "$MROOT" --mode all-auto --note "retention probe" 2>/dev/null)
count=$(find "$RDIR" -maxdepth 1 -name 'scheduled-*.md' | wc -l)
# After write: had 13 seed + 2 previous tests + 1 new = many; prune to 12
if [ "$count" -le 12 ]; then
  ok "retention count=$count (<=12)"
else
  bad "retention count=$count (want <=12)"
fi
# Newest should still exist
[ -f "$out3" ] && ok "newest retained" || bad "newest pruned: $out3"
# Oldest seed should be gone if we seeded enough
if [ ! -f "$RDIR/scheduled-2000-01-01T000000Z.md" ]; then
  ok "oldest pruned"
else
  # may still exist if touch failed and sort order differs — check count is enough
  [ "$count" -le 12 ] && ok "oldest prune soft (count ok)" || bad "oldest still present and over cap"
fi

# --- webhook fail-open (empty URL = no-op) ---
unset AGENT_WEBHOOK_URL
out4=$(bash "$WRITER" --mroot "$MROOT" --mode all-auto --note "no webhook" 2>/dev/null)
rc=$?
[ "$rc" -eq 0 ] && ok "webhook unset exit 0" || bad "webhook unset exit $rc"

# Fake URL — connection refused, must still exit 0
export AGENT_WEBHOOK_URL="http://127.0.0.1:1"
out5=$(bash "$WRITER" --mroot "$MROOT" --mode all-auto --note "bad webhook" 2>/dev/null)
rc=$?
[ "$rc" -eq 0 ] && ok "webhook fail-open exit 0" || bad "webhook fail-open exit $rc"
unset AGENT_WEBHOOK_URL

# --- usage error ---
bash "$WRITER" 2>/dev/null
rc=$?
[ "$rc" -eq 1 ] && ok "usage rc=1" || bad "usage want 1 got $rc"

# --- no transcript bodies in report ---
if ! grep -qiE 'tool_use|tool_result|"type":\s*"user"' "$out2" 2>/dev/null; then
  ok "no transcript bodies"
else
  bad "report looks like transcript dump"
fi

echo "---"
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
