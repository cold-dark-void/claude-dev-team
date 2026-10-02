#!/usr/bin/env bash
# ticket-class.sh — word-boundary auth-secrets classifier (CDT-278 T-06design).
#
# THIS SCRIPT IS A SUBPROCESS CLI — NEVER SOURCE IT.
#
# Usage:
#   ticket-class.sh              # read the ticket text on stdin
#   ticket-class.sh --text TEXT  # TEXT is one argument
#
# stdout: auth-secrets | none
# A substring hit is not enough. "author" does not match "auth".
# "tokenizer" does not match "token".
#
# Exit: 0 classified, 64 usage.

set -euo pipefail

if [ "${1:-}" = "--text" ]; then
  [ $# -eq 2 ] || { echo "usage: ticket-class.sh [--text TEXT]" >&2; exit 64; }
  TEXT=$2
elif [ $# -eq 0 ]; then
  TEXT=$(cat)
else
  echo "usage: ticket-class.sh [--text TEXT]" >&2
  exit 64
fi

LOW=$(printf '%s' "$TEXT" | tr '[:upper:]' '[:lower:]')

# Multi-word phrases, then single tokens. Longer tokens are listed before
# "auth" so the alternation is obvious; the boundary still rejects "author".
PHRASE='(^|[^[:alnum:]_])(api[- ]key|private[- ]key)([^[:alnum:]_]|$)'
WORD='(^|[^[:alnum:]_])(authentication|authorization|apikey|oauth|oidc|jwt|session|credential|secret|token|password|auth|pii|ssn|csrf)([^[:alnum:]_]|$)'

if printf '%s' "$LOW" | grep -Eq "$PHRASE"; then
  printf '%s\n' auth-secrets
  exit 0
fi
if printf '%s' "$LOW" | grep -Eq "$WORD"; then
  printf '%s\n' auth-secrets
  exit 0
fi
printf '%s\n' none
exit 0
