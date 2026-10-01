#!/usr/bin/env bash
# Reject an --agent value that is not a behavioral roster name.
# Usage: bash skills/lib/require-agent.sh <name>
set -euo pipefail

name=${1-}
case "$name" in
  pm|tech-lead|ic5|ic4|devops|qa|ds)
    exit 0
    ;;
  *)
    echo "Error: --agent must match ^(pm|tech-lead|ic5|ic4|devops|qa|ds)$" >&2
    exit 64
    ;;
esac
