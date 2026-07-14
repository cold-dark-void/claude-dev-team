#!/usr/bin/env bash
# SPEC-021: deterministic linter for fenced bash blocks in plugin .md files.
# Pure subprocess CLI — no LLM, no network. See skills/skill-lint/SKILL.md.
set -euo pipefail
exec python3 "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lint.py" "$@"
