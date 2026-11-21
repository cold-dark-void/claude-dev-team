#!/usr/bin/env bash
# control-plane test suite runner (CDT-656): the one script the ship gate's
# M14(g) Verify grammar admits for the Go lane — SPEC-044's Version History
# records that the 14 per-file Verify lines were dropped because no suite
# script covered the Go lane, and names `control-plane/test.sh` as the
# follow-up that restores the binding.
#
# Usage: bash control-plane/test.sh        # from the repo root (or anywhere)
# Exit: go test's status.
set -euo pipefail

HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)

cd "$HERE"
exec go test ./... -count=1
