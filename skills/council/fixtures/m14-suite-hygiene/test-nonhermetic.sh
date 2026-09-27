#!/usr/bin/env bash
# Fixture stub for test-m14-suite-hygiene.sh's bite test: a "test-*.sh" file
# that tools/run-all-tests.sh --list discovers but that has no shared setup
# helper and no private-temp-root init call. It must fail the hygiene
# check's hermetic requirement.
set -uo pipefail
echo "OK: fixture stub"
exit 0
