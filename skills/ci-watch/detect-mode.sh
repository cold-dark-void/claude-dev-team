#!/usr/bin/env bash
# detect-mode.sh <worktree-path>
# Subprocess CLI — never sourced. Always exits 0.
#
# Output:
#   Line 1: ci | local-test | none
#   Line 2: test command (only when mode=local-test)

set -euo pipefail

WT="${1:-}"

if [ -z "$WT" ]; then
  echo "none"
  exit 0
fi

# 1. ci: .github/workflows/ exists AND gh pr checks --help exits 0
if [ -d "$WT/.github/workflows" ] && gh pr checks --help >/dev/null 2>&1; then
  echo "ci"
  exit 0
fi

# 2. local-test: probe in priority order

# 2a. package.json with "scripts"."test"
if [ -f "$WT/package.json" ]; then
  if command -v jq >/dev/null 2>&1; then
    if jq -e '.scripts.test' "$WT/package.json" >/dev/null 2>&1; then
      echo "local-test"
      echo "npm test"
      exit 0
    fi
  else
    # fallback: two-stage grep — scripts section exists AND has a "test" key
    if grep -qE '"scripts"' "$WT/package.json" && \
       grep -qE '"test"[[:space:]]*:' "$WT/package.json"; then
      echo "local-test"
      echo "npm test"
      exit 0
    fi
  fi
fi

# 2b. Makefile with ^test: target
if [ -f "$WT/Makefile" ] && grep -q "^test:" "$WT/Makefile"; then
  echo "local-test"
  echo "make test"
  exit 0
fi

# 2c. go.mod
if [ -f "$WT/go.mod" ]; then
  echo "local-test"
  echo "go test ./..."
  exit 0
fi

# 2d. pytest markers
if [ -f "$WT/pytest.ini" ] || [ -f "$WT/setup.py" ]; then
  echo "local-test"
  echo "pytest"
  exit 0
fi
if [ -f "$WT/pyproject.toml" ] && grep -q '\[tool\.pytest\.ini_options\]' "$WT/pyproject.toml"; then
  echo "local-test"
  echo "pytest"
  exit 0
fi

# 3. none
echo "none"
exit 0
