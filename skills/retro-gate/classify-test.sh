#!/usr/bin/env bash
# classify-test.sh — repeat filter before the cap, and TIGHTEN merge.
# Run: bash skills/retro-gate/classify-test.sh
set -u
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PY="$HERE/classify.py"
PARSE="$HERE/parse_results.py"
PASS=0; FAIL=0
ok() { PASS=$((PASS + 1)); }
bad() { FAIL=$((FAIL + 1)); echo "FAIL: $*"; }

WORK=$(mktemp -d "${TMPDIR:-/tmp}/classify-test.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/repo/.claude/memory/ic5"
printf '%s\n' '1. Keep the lock file owner line.' > "$WORK/repo/.claude/memory/ic5/directives.md"

# Six high singleton ranks, then a lower cross-session pattern that must survive.
{
  printf '90\tic5\t0.9\t1\tlone alpha\tdo alpha\t/s/a.jsonl\t[]\n'
  printf '80\tic5\t0.9\t1\tlone beta\tdo beta\t/s/b.jsonl\t[]\n'
  printf '70\tic5\t0.9\t1\tlone gamma\tdo gamma\t/s/c.jsonl\t[]\n'
  printf '60\tic5\t0.9\t1\tlone delta\tdo delta\t/s/d.jsonl\t[]\n'
  printf '50\tic5\t0.9\t1\tlone epsilon\tdo epsilon\t/s/e.jsonl\t[]\n'
  printf '40\tic5\t0.9\t1\tsame session twice\tdo same\t/s/one.jsonl\t[]\n'
  printf '39\tic5\t0.9\t1\tsame session twice\tdo same again\t/s/one.jsonl\t[]\n'
  printf '10\tic5\t0.9\t1\tlock file race\tkeep the owner\t/s/p.jsonl\t[]\n'
  printf '9\tic5\t0.9\t1\trace on the lock file\tkeep the owner line\t/s/q.jsonl\t[]\n'
} > "$WORK/raw.tsv"

out=$(python3 "$PY" --mode all --mroot "$WORK/repo" --cap 5 < "$WORK/raw.tsv")
printf '%s\n' "$out" | grep -q 'lock file race' && ok || bad "cross-session pattern was capped away"
printf '%s\n' "$out" | grep -q 'same session twice' && bad "same-session duplicate survived" || ok
printf '%s\n' "$out" | grep -q 'additionally' && ok || bad "TIGHTEN merge text missing"
printf '%s\n' "$out" | awk -F '\t' '$2=="TIGHTEN" && index($4, "Keep the lock file owner line") { found=1 } END { exit !found }' \
  && ok || bad "TIGHTEN column 4 is not the merged sentence"

# Newline and tab are collapsed before a TSV field is written.
san=$(printf 'hello\nworld\tthere' | python3 "$PARSE" sanitize)
case "$san" in
  "hello world there") ok ;;
  *) bad "sanitize left a break: $(printf '%s' "$san" | od -An -tx1)" ;;
esac
printf '1\tic5\t0.5\t1\tclean\t%s\t/s/z.jsonl\t[]\n' "$san" > "$WORK/nl.tsv"
nlines=$(python3 "$PY" --mode single --mroot "$WORK/repo" < "$WORK/nl.tsv" | grep -c .)
[ "$nlines" = "1" ] && ok || bad "sanitized field did not stay one row (lines=$nlines)"

aid1=$(python3 "$PARSE" anchor turn-1 'claim text' /src/a.jsonl)
aid2=$(python3 "$PARSE" anchor turn-1 'claim text' /src/a.jsonl)
aid3=$(python3 "$PARSE" anchor turn-1 'other' /src/a.jsonl)
[ "$aid1" = "$aid2" ] && [ "$aid1" != "$aid3" ] && ok || bad "anchor_id is not stable"

RETRO_MD="$HERE/../../commands/retro.md"
bytes=$(wc -c < "$RETRO_MD")
[ "$bytes" -lt 25000 ] && ok || bad "retro.md is ${bytes} bytes, want < 25000"

echo "classify-test: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
