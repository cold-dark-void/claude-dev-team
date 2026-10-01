#!/usr/bin/env bash
# Print a /recall topic literally, then a LIKE pattern with \ % _ escaped.
# Usage: bash skills/lib/recall-topic.sh <topic>
# Empty topic exits 64. The topic is never eval'd.
set -euo pipefail

TOPIC=${1-}
if [ -z "$TOPIC" ]; then
  echo "Usage: /recall <topic>" >&2
  exit 64
fi
printf '%s\n' "$TOPIC"
# LIKE escapes first, then SQL single quotes. Line 1 stays literal for grep -F.
printf '%s\n' "$TOPIC" | sed -e 's/\\/\\\\/g' -e 's/%/\\%/g' -e 's/_/\\_/g' -e "s/'/''/g"
