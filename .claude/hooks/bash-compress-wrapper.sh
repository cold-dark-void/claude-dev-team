#!/usr/bin/env bash
# Runs a command and compresses output if it exceeds a threshold.
# Preserves exit code. Shows first/last N lines with omitted count.

THRESHOLD=50
HEAD_LINES=20
TAIL_LINES=20

OUTPUT=$("$@" 2>&1)
EXIT_CODE=$?

TMPF="${TMPDIR:-/tmp}/bcompress-out-$$"
printf '%s\n' "$OUTPUT" > "$TMPF"
LINE_COUNT=$(awk 'END{print NR}' "$TMPF")

if [ "$LINE_COUNT" -le "$THRESHOLD" ]; then
  cat "$TMPF"
else
  OMITTED=$(( LINE_COUNT - HEAD_LINES - TAIL_LINES ))
  printf '[compressed: %d lines -> %d lines]\n' "$LINE_COUNT" $(( HEAD_LINES + TAIL_LINES ))
  head -"$HEAD_LINES" "$TMPF"
  printf '\n... %d lines omitted ...\n\n' "$OMITTED"
  tail -"$TAIL_LINES" "$TMPF"
fi

rm -f "$TMPF"
exit $EXIT_CODE
