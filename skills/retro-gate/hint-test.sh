#!/usr/bin/env bash
# hint-test.sh — hint.sh against a fake Claude project dir (CDT-279 E5)
set -u

HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
HINT="$HERE/hint.sh"
PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); echo "PASS: $*"; }
bad() { FAIL=$((FAIL + 1)); echo "FAIL: $*"; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
unset GIT_DIR GIT_WORK_TREE

REPO="$TMP/repo"
mkdir -p "$REPO"
env -u GIT_DIR -u GIT_WORK_TREE git -C "$REPO" init -q .
env -u GIT_DIR -u GIT_WORK_TREE git -C "$REPO" -c user.email=t@example.com -c user.name=t commit --allow-empty -q -m init

HOME_DIR="$TMP/home"
mkdir -p "$HOME_DIR"
MROOT=$(env -u GIT_DIR -u GIT_WORK_TREE git -C "$REPO" rev-parse --show-toplevel)
ENC=$(printf '%s\n' "$MROOT" | sed 's|[^A-Za-z0-9]|-|g')
PROJ="$HOME_DIR/.claude/projects/$ENC"
mkdir -p "$PROJ"
printf '%s\n' '{}' > "$PROJ/sess-abc.jsonl"

cat > "$TMP/gate-pass.sh" <<'EOF'
#!/bin/bash
printf '%s\n' '{"passed":true,"score":9}'
EOF
cat > "$TMP/gate-fail.sh" <<'EOF'
#!/bin/bash
printf '%s\n' '{"passed":false,"score":1}'
EOF
chmod +x "$TMP/gate-pass.sh" "$TMP/gate-fail.sh"

out=$(cd "$REPO" && HOME="$HOME_DIR" bash "$HINT" "$TMP/gate-pass.sh")
printf '%s\n' "$out" | grep -q 'Consider: /retro sess-abc' \
  && ok "a passing gate prints the retro hint" || bad "pass hint: ${out:-empty}"

out=$(cd "$REPO" && HOME="$HOME_DIR" bash "$HINT" "$TMP/gate-fail.sh")
if [ -z "$out" ]; then
  ok "a failing gate prints nothing"
else
  bad "fail hint: $out"
fi

out=$(cd "$REPO" && HOME="$TMP/empty-home" bash "$HINT" "$TMP/gate-pass.sh")
rc=$?
if [ "$rc" -eq 0 ] && [ -z "$out" ]; then
  ok "no session exits 0 with no hint"
else
  bad "no session rc=$rc out=${out:-empty}"
fi

echo "---"
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
