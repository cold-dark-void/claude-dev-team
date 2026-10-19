#!/usr/bin/env bash
# Reject an --agent value that is not a roster name.
# Usage: bash skills/lib/require-agent.sh <name>            — behavioral 7 (SPEC-033 default)
#        bash skills/lib/require-agent.sh --memory <name>   — the 7 + advisor (SPEC-039 M33)
set -euo pipefail

mode=default
if [ "${1:-}" = "--memory" ]; then
  mode=memory
  shift
fi

name=${1-}
case "$name" in
  pm|tech-lead|ic5|ic4|devops|qa|ds)
    exit 0
    ;;
  advisor)
    if [ "$mode" = "memory" ]; then
      exit 0
    fi
    echo "Error: --agent must match ^(pm|tech-lead|ic5|ic4|devops|qa|ds)$ (advisor rows join only via require-agent.sh --memory)" >&2
    exit 64
    ;;
  *)
    echo "Error: --agent must match ^(pm|tech-lead|ic5|ic4|devops|qa|ds)$" >&2
    exit 64
    ;;
esac
