#!/usr/bin/env bash
# Fixture: a *-test.sh script that fails `bash -n` (unclosed if).
set -euo pipefail
if true
  echo "unclosed if with no fi"
