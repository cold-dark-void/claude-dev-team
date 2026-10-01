#!/usr/bin/env bash
# reconcile-lib.sh — Candidate pair generation for /memory validate --reconcile
#
# Usage (subprocess only — never source):
#   bash reconcile-lib.sh candidates <MEMDB> [--agent NAME] [--cap N] [--out PATH]
#   bash reconcile-lib.sh resolve-pick <MEMDB> <winner_id> <loser_id> <agent_a> <agent_b> \
#        <claim_a> <claim_b> <confidence> <reason>
#   bash reconcile-lib.sh resolve-both-stale <MEMDB> <id_a> <id_b> <agent_a> <agent_b> \
#        <claim_a> <claim_b> <confidence> <reason>
#   bash reconcile-lib.sh resolve-merge <MEMDB> <winner_id> <loser_id> <agent_a> <agent_b> \
#        <claim_a> <claim_b> <confidence> <merged_content> <reason>
#   bash reconcile-lib.sh resolve-skip <MEMDB> <id_a> <id_b> <agent_a> <agent_b> \
#        <claim_a> <claim_b> <confidence> <reason>
#   bash reconcile-lib.sh resolve-deep-audit <MEMDB> <id_a> <id_b> <agent_a> <agent_b> \
#        <claim_a> <claim_b> <confidence> <reason>
#
# candidates writes JSONL pairs to --out (default stdout). method=keyword|embed.
# Pair text is passed through reconcile-pass.py with bound parameters.
# Never auto-archives. report-only path must not call resolve-* subcommands.
#
# Governing: SPEC-011 (CDV-195). THIS SCRIPT IS A SUBPROCESS CLI — NEVER SOURCE IT.

set -euo pipefail

usage() {
  cat <<'EOF' >&2
Usage:
  reconcile-lib.sh candidates <MEMDB> [--agent NAME] [--cap N] [--out PATH]
  reconcile-lib.sh resolve-pick|resolve-both-stale|resolve-merge|resolve-skip|resolve-deep-audit ...
EOF
  exit 64
}

HERE=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
PASS="$HERE/reconcile-pass.py"

run_pass() {
  if [ ! -f "$PASS" ]; then
    echo "reconcile-lib.sh: missing reconcile-pass.py" >&2
    exit 1
  fi
  python3 "$PASS" "$@"
}

# ---- main dispatch ----
[ $# -lt 1 ] && usage
CMD=$1
shift

case "$CMD" in
  candidates)
    [ $# -lt 1 ] && usage
    run_pass candidates "$@"
    ;;
  resolve-pick|resolve-both-stale|resolve-skip|resolve-deep-audit)
    [ $# -lt 9 ] && usage
    run_pass "$CMD" "$@"
    ;;
  resolve-merge)
    [ $# -lt 10 ] && usage
    run_pass resolve-merge "$@"
    ;;
  *)
    usage
    ;;
esac
