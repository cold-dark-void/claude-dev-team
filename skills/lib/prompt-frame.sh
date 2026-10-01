#!/usr/bin/env bash
# prompt-frame.sh — per-run nonce wrapper for untrusted prompt data.
# Usage: prompt-frame.sh nonce
#        prompt-frame.sh wrap <nonce>   # stdin is the untrusted body
set -u

cmd="${1:-}"
nonce="${2:-}"

case "$cmd" in
  nonce)
    openssl rand -hex 16
    ;;
  wrap|strip)
    if ! printf '%s' "$nonce" | grep -Eq '^[0-9a-f]{32}$'; then
      echo "prompt-frame: nonce must be 32 hex chars" >&2
      exit 2
    fi
    begin="<<<BEGIN_${nonce}>>>"
    end="<<<END_${nonce}>>>"
    body=$(cat)
    # A payload that copies this run's sentinels must not add a closer.
    body=${body//"$begin"/}
    body=${body//"$end"/}
    if [ "$cmd" = "strip" ]; then
      printf '%s' "$body"
    else
      printf '%s\n%s\n%s\n' "$begin" "$body" "$end"
    fi
    ;;
  *)
    echo "usage: prompt-frame.sh nonce | wrap <nonce> | strip <nonce>" >&2
    exit 64
    ;;
esac
