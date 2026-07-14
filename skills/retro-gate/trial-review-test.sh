#!/usr/bin/env bash
# trial-review-test.sh — unit tests for trial-review.sh (CDV-200 M2/M4/M7)
set -u

HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REVIEW="$HERE/trial-review.sh"
PASS=0
FAIL=0

ok()  { PASS=$((PASS + 1)); echo "PASS: $*"; }
bad() { FAIL=$((FAIL + 1)); echo "FAIL: $*"; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
MROOT="$TMP/proj"
mkdir -p "$MROOT/.claude/memory/ic5"
mkdir -p "$MROOT/.claude/memory/pm"

# epoch helpers
start_ep=$(date -u -d "2026-07-01 00:00:00" +%s 2>/dev/null || date -u -j -f "%Y-%m-%d %H:%M:%S" "2026-07-01 00:00:00" +%s)
b1=$((start_ep - 86400 * 3))
b2=$((start_ep - 86400 * 2))
t1=$((start_ep + 86400))
t2=$((start_ep + 86400 * 2))
t3=$((start_ep + 86400 * 3))

# ── M2: no annotations → zero proposals, zero warnings-as-failures ───────────
printf '1. Always use Gherkin\n2. Prefer small PRs\n' >"$MROOT/.claude/memory/ic5/directives.md"
printf '1. Ship specs first\n' >"$MROOT/.claude/memory/pm/directives.md"
# scores file still provided
printf 's1\t10\t%s\ns2\t8\t%s\ns3\t2\t%s\ns4\t1\t%s\n' "$b1" "$b2" "$t1" "$t2" >"$TMP/scores.tsv"
out=$(bash "$REVIEW" --mroot "$MROOT" --session-scores-file "$TMP/scores.tsv" --today 2026-07-20 2>"$TMP/err")
rc=$?
[ "$rc" -eq 0 ] && ok "M2 exit 0" || bad "M2 exit want 0 got $rc"
[ -z "$out" ] && ok "M2 no stdout proposals" || bad "M2 unexpected stdout: $out"
# stderr may be empty (no trials to defer)
ok "M2 plain directives untouched"

# ── M4 KEEP: high baseline, low in-trial ─────────────────────────────────────
printf '1. Always run bash -n <!-- trial start=2026-07-01 source=sess#a1 review-after=2-sessions -->\n' \
  >"$MROOT/.claude/memory/ic5/directives.md"
# baseline scores 10,8 ; in-trial 2,1 → KEEP
printf 'base-a\t10\t%s\nbase-b\t8\t%s\ntrial-a\t2\t%s\ntrial-b\t1\t%s\n' \
  "$b1" "$b2" "$t1" "$t2" >"$TMP/scores.tsv"
out=$(bash "$REVIEW" --mroot "$MROOT" --session-scores-file "$TMP/scores.tsv" --today 2026-07-20 2>"$TMP/err")
action=$(printf '%s' "$out" | head -1 | cut -f1)
agent=$(printf '%s' "$out" | head -1 | cut -f2)
bmean=$(printf '%s' "$out" | head -1 | cut -f6)
tmean=$(printf '%s' "$out" | head -1 | cut -f8)
[ "$action" = "KEEP" ] && ok "M4 KEEP action" || bad "M4 KEEP want KEEP got '$action' out='$out' err=$(cat "$TMP/err")"
[ "$agent" = "ic5" ] && ok "M4 KEEP agent" || bad "M4 KEEP agent got $agent"
# mean baseline = 9, in-trial = 1.5
python3 -c "import sys; b=float(sys.argv[1]); t=float(sys.argv[2]); sys.exit(0 if b>t else 1)" "$bmean" "$tmean" \
  && ok "M4 KEEP means ordered" || bad "M4 KEEP means b=$bmean t=$tmean"

# ── M4 REVERT: invert scores ─────────────────────────────────────────────────
printf 'base-a\t1\t%s\nbase-b\t2\t%s\ntrial-a\t10\t%s\ntrial-b\t12\t%s\n' \
  "$b1" "$b2" "$t1" "$t2" >"$TMP/scores.tsv"
out=$(bash "$REVIEW" --mroot "$MROOT" --session-scores-file "$TMP/scores.tsv" --today 2026-07-20 2>"$TMP/err")
action=$(printf '%s' "$out" | head -1 | cut -f1)
[ "$action" = "REVERT" ] && ok "M4 REVERT action" || bad "M4 REVERT want REVERT got '$action' out='$out' err=$(cat "$TMP/err")"

# ── M4 tie → REVERT ──────────────────────────────────────────────────────────
printf 'base-a\t5\t%s\nbase-b\t5\t%s\ntrial-a\t5\t%s\ntrial-b\t5\t%s\n' \
  "$b1" "$b2" "$t1" "$t2" >"$TMP/scores.tsv"
out=$(bash "$REVIEW" --mroot "$MROOT" --session-scores-file "$TMP/scores.tsv" --today 2026-07-20 2>"$TMP/err")
action=$(printf '%s' "$out" | head -1 | cut -f1)
[ "$action" = "REVERT" ] && ok "M4 tie REVERT" || bad "M4 tie want REVERT got '$action'"

# ── DEFER n<2 (window elapsed via days; only 1 sample each side) ─────────────
printf '1. Always run bash -n <!-- trial start=2026-07-01 source=sess#a1 review-after=5-days -->\n' \
  >"$MROOT/.claude/memory/ic5/directives.md"
printf 'base-a\t10\t%s\ntrial-a\t1\t%s\n' "$b1" "$t1" >"$TMP/scores.tsv"
out=$(bash "$REVIEW" --mroot "$MROOT" --session-scores-file "$TMP/scores.tsv" --today 2026-07-20 2>"$TMP/err")
[ -z "$out" ] && ok "DEFER n<2 no stdout" || bad "DEFER n<2 unexpected out='$out'"
grep -q 'insufficient-sample' "$TMP/err" && ok "DEFER n<2 stderr" || bad "DEFER n<2 missing stderr: $(cat "$TMP/err")"

# ── DEFER window not elapsed (review-after=10-sessions, only 2 in-trial) ─────
printf '1. trial line <!-- trial start=2026-07-01 source=s#a review-after=10-sessions -->\n' \
  >"$MROOT/.claude/memory/ic5/directives.md"
printf 'base-a\t10\t%s\nbase-b\t8\t%s\ntrial-a\t2\t%s\ntrial-b\t1\t%s\n' \
  "$b1" "$b2" "$t1" "$t2" >"$TMP/scores.tsv"
out=$(bash "$REVIEW" --mroot "$MROOT" --session-scores-file "$TMP/scores.tsv" --today 2026-07-20 2>"$TMP/err")
[ -z "$out" ] && ok "DEFER window no stdout" || bad "DEFER window out='$out'"
grep -q 'window-not-elapsed' "$TMP/err" && ok "DEFER window stderr" || bad "DEFER window err=$(cat "$TMP/err")"

# ── days-based window elapsed + KEEP ─────────────────────────────────────────
printf '1. days trial <!-- trial start=2026-07-01 source=s#a review-after=5-days -->\n' \
  >"$MROOT/.claude/memory/ic5/directives.md"
printf 'base-a\t10\t%s\nbase-b\t8\t%s\ntrial-a\t2\t%s\ntrial-b\t1\t%s\n' \
  "$b1" "$b2" "$t1" "$t2" >"$TMP/scores.tsv"
out=$(bash "$REVIEW" --mroot "$MROOT" --session-scores-file "$TMP/scores.tsv" --today 2026-07-10 2>"$TMP/err")
action=$(printf '%s' "$out" | head -1 | cut -f1)
[ "$action" = "KEEP" ] && ok "days-window KEEP" || bad "days-window want KEEP got '$action' err=$(cat "$TMP/err")"

# ── audit append (M7) ────────────────────────────────────────────────────────
bash "$REVIEW" --record-decision --mroot "$MROOT" \
  --agent ic5 --directive "Always run bash -n" --source "sess#a1" --trial-start 2026-07-01 \
  --baseline-mean 9 --baseline-n 2 --baseline-ids "base-a,base-b" \
  --in-trial-mean 1.5 --in-trial-n 2 --in-trial-ids "trial-a,trial-b" \
  --decision KEEP --decided-by user
rc=$?
[ "$rc" -eq 0 ] && ok "record-decision exit 0" || bad "record-decision rc=$rc"
AUDIT="$MROOT/.claude/retro/directive-history.jsonl"
[ -f "$AUDIT" ] && ok "audit file created" || bad "audit file missing"
n1=$(wc -l <"$AUDIT" | tr -d ' ')
[ "$n1" -eq 1 ] && ok "audit 1 line" || bad "audit want 1 got $n1"

bash "$REVIEW" --record-decision --mroot "$MROOT" \
  --agent ic5 --directive "Always run bash -n" --source "sess#a1" --trial-start 2026-07-01 \
  --baseline-mean 1 --baseline-n 2 --baseline-ids "base-a,base-b" \
  --in-trial-mean 11 --in-trial-n 2 --in-trial-ids "trial-a,trial-b" \
  --decision REVERT --decided-by auto
n2=$(wc -l <"$AUDIT" | tr -d ' ')
[ "$n2" -eq 2 ] && ok "audit 2 lines append" || bad "audit want 2 got $n2"

# Validate JSON fields
python3 - "$AUDIT" <<'PY'
import json, sys
path = sys.argv[1]
rows = [json.loads(l) for l in open(path) if l.strip()]
assert len(rows) == 2
assert rows[0]["decision"] == "KEEP" and rows[0]["decided_by"] == "user"
assert rows[1]["decision"] == "REVERT" and rows[1]["decided_by"] == "auto"
assert "mean" in rows[0]["baseline"] and "sessions" in rows[0]["baseline"]
assert "mean" in rows[0]["in_trial"]
assert rows[0]["agent"] == "ic5"
assert rows[0]["directive"] == "Always run bash -n"
print("ok")
PY
[ $? -eq 0 ] && ok "audit JSON fields" || bad "audit JSON invalid"

# ── no silent mutation of directives.md ──────────────────────────────────────
cp "$MROOT/.claude/memory/ic5/directives.md" "$TMP/before.md"
bash "$REVIEW" --mroot "$MROOT" --session-scores-file "$TMP/scores.tsv" --today 2026-07-20 >/dev/null 2>&1
cmp -s "$MROOT/.claude/memory/ic5/directives.md" "$TMP/before.md" \
  && ok "review does not mutate directives" || bad "review mutated directives.md"

echo "---"
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
