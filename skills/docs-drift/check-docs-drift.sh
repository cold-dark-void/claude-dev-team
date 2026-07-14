#!/usr/bin/env bash
# SPEC-010: deterministic docs-drift checker (structural index/roster/hub/manifest).
# Pure subprocess CLI — no LLM, no network. See skills/docs-drift/SKILL.md.
set -euo pipefail
exec python3 "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/check.py" "$@"
