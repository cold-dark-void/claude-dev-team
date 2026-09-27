#!/usr/bin/env bash
# Positive control for test-m14-suite-hygiene.sh's live-council rule: this
# file sources tests/lib/hermetic.sh and calls hermetic_init (so it must
# pass the hermetic rule) but also has a bare, executed council spawn (so
# it must fail the live-council rule). check_hygiene never runs this file;
# it only inspects its source text, so the lines below are never invoked.
set -uo pipefail
# shellcheck source=../../../tests/lib/hermetic.sh
. "$(cd "$(dirname "$0")/../.." && pwd)/tests/lib/hermetic.sh"
hermetic_init
/council "audit the diff" --council-tier=full
claude -p "run this prompt"
exit 0
