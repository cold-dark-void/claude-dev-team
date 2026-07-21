#!/usr/bin/env bash
# SPEC-030: deterministic load-only smoke harness for plugin Surfaces + engine scripts.
# Pure subprocess CLI — no LLM, no network. See tools/smoke/README.md.
set -euo pipefail
# -B: never write .pyc / __pycache__ (keeps tools/smoke/ clean; repo .gitignore
# also covers __pycache__/, so it can never be committed either way).
exec python3 -B "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/smoke.py" "$@"
