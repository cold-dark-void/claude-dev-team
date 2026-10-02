#!/usr/bin/env bash
# ticket-class-test.sh — word-boundary classifier. Fails on a substring "auth" match.
set -u
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
CLASS="$HERE/ticket-class.sh"
PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); }
bad() { FAIL=$((FAIL + 1)); echo "FAIL: $*" >&2; }

check() {
  local want=$1 text=$2 got
  got=$(bash "$CLASS" --text "$text") || { bad "rc non-zero for [$text]"; return; }
  if [ "$got" = "$want" ]; then ok
  else bad "text [$text] got [$got] want [$want]"; fi
}

# Planted negative control: "author" contains "auth" and must NOT classify.
check none "author"
check none "The author wrote the design note."
check none "tokenizer"
check auth-secrets "auth"
check auth-secrets "Add authentication to the session"
check auth-secrets "store the API key"
check auth-secrets "private-key rotation"
check none "rename the public helper"

echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
