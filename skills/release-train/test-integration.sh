#!/usr/bin/env bash
# Integration: freeze → squash-merge simulation → M5 → renumber; conflict → restore+blocked.
# Does NOT invoke real /release. Run: bash skills/release-train/test-integration.sh
set -euo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
LIB="$HERE/train-lib.sh"
PASS=0; FAIL=0
pass() { PASS=$((PASS+1)); }
fail() { FAIL=$((FAIL+1)); echo "FAIL: $*"; }

TMP=$(mktemp -d "${TMPDIR:-/tmp}/rt-int.XXXXXX")
trap 'rm -rf "$TMP"' EXIT

REPO="$TMP/repo"
mkdir -p "$REPO"
git -C "$REPO" init -q -b master
git -C "$REPO" config user.email t@ex.com
git -C "$REPO" config user.name T
mkdir -p "$REPO/.claude-plugin" "$REPO/specs" "$REPO/skills"
printf '%s\n' '{"name":"dev-team","version":"0.39.0"}' > "$REPO/.claude-plugin/plugin.json"
printf '%s\n' '{"plugins":[{"name":"dev-team","version":"0.39.0"}]}' > "$REPO/.claude-plugin/marketplace.json"
cat > "$REPO/CHANGELOG.md" <<'EOF'
# Changelog

### v0.39.0
- base
EOF
cat > "$REPO/specs/TDD.md" <<'EOF'
# Behavioral Specifications

## Spec Index

| ID | Title | Status | Coverage |
|----|-------|--------|----------|
| SPEC-001 | A | ACTIVE | x |

## Version History

| Date | Change |
|------|--------|
| 2026-03-16 | init |
EOF
echo 'master-skill' > "$REPO/skills/foo.sh"
git -C "$REPO" add -A && git -C "$REPO" commit -q -m "master 0.39.0"
MASTER_SHA=$(git -C "$REPO" rev-parse HEAD)

# feat/a: minor, assume 0.40.0, adds SPEC-023 row + VH + changelog + versions
git -C "$REPO" checkout -q -b feat/a
cat > "$REPO/specs/TDD.md" <<'EOF'
# Behavioral Specifications

## Spec Index

| ID | Title | Status | Coverage |
|----|-------|--------|----------|
| SPEC-001 | A | ACTIVE | x |
| SPEC-023 | Release Train | DRAFT | skills/release-train |

## Version History

| Date | Change |
|------|--------|
| 2026-03-16 | init |
| 2026-07-13 | SPEC-023 draft |
EOF
cat > "$REPO/CHANGELOG.md" <<'EOF'
# Changelog

### v0.40.0
- **feat: train a** — entry A.

### v0.39.0
- base
EOF
printf '%s\n' '{"name":"dev-team","version":"0.40.0"}' > "$REPO/.claude-plugin/plugin.json"
printf '%s\n' '{"plugins":[{"name":"dev-team","version":"0.40.0"}]}' > "$REPO/.claude-plugin/marketplace.json"
git -C "$REPO" add -A && git -C "$REPO" commit -q -m "feat a"
SHA_A=$(git -C "$REPO" rev-parse HEAD)

# feat/b: patch, assume 0.40.0, adds SPEC-021 row
git -C "$REPO" checkout -q master
git -C "$REPO" checkout -q -b feat/b
cat > "$REPO/specs/TDD.md" <<'EOF'
# Behavioral Specifications

## Spec Index

| ID | Title | Status | Coverage |
|----|-------|--------|----------|
| SPEC-001 | A | ACTIVE | x |
| SPEC-021 | Skill Lint | ACTIVE | skills/skill-lint |

## Version History

| Date | Change |
|------|--------|
| 2026-03-16 | init |
| 2026-07-13 | SPEC-021 active |
EOF
cat > "$REPO/CHANGELOG.md" <<'EOF'
# Changelog

### v0.40.0
- **feat: train b** — entry B.

### v0.39.0
- base
EOF
printf '%s\n' '{"name":"dev-team","version":"0.40.0"}' > "$REPO/.claude-plugin/plugin.json"
printf '%s\n' '{"plugins":[{"name":"dev-team","version":"0.40.0"}]}' > "$REPO/.claude-plugin/marketplace.json"
git -C "$REPO" add -A && git -C "$REPO" commit -q -m "feat b"
SHA_B=$(git -C "$REPO" rev-parse HEAD)

git -C "$REPO" checkout -q master
export RELEASE_TRAIN_ROOT="$REPO"
cd "$REPO"

bash "$LIB" init >/dev/null
bash "$LIB" register feat/a --bump minor --assumed 0.40.0 >/dev/null
bash "$LIB" register feat/b --bump patch --assumed 0.40.0 >/dev/null
PLAN=$(bash "$LIB" freeze)
echo "$PLAN" | jq -e '.entries[0].assigned_version=="0.40.0"' >/dev/null && pass || fail "slot0"
echo "$PLAN" | jq -e '.entries[1].assigned_version=="0.40.1"' >/dev/null && pass || fail "slot1"

# simulate land feat/a: merge --squash, M5, renumber
BASE=$(git rev-parse HEAD)
bash "$LIB" set-status feat/a landing --base-sha "$BASE" >/dev/null
git merge --squash feat/a >/dev/null 2>&1 || true
# if clean squash, tree has feat/a content uncommitted
ASSIGNED=0.40.0
# extract ours/theirs for TDD via git show
OURS=$(mktemp "${TMPDIR:-/tmp}/rt-o.XXXXXX")
THEIRS=$(mktemp "${TMPDIR:-/tmp}/rt-t.XXXXXX")
git show "$BASE:specs/TDD.md" > "$OURS"
git show feat/a:specs/TDD.md > "$THEIRS"
bash "$LIB" resolve-tdd-index --ours "$OURS" --theirs "$THEIRS" --out specs/TDD.md
bash "$LIB" resolve-vh --ours "$OURS" --theirs "$THEIRS" --out specs/TDD.md
# wait - resolve-vh overwrites with only VH merge from those files; resolve-tdd already wrote combined index with ours suffix VH.
# Re-run properly: first tdd-index into tmp, then vh
bash "$LIB" resolve-tdd-index --ours "$OURS" --theirs "$THEIRS" --out specs/TDD.md
# For VH, need post-index file as base... use merge of VH only into current
CUR=$(mktemp "${TMPDIR:-/tmp}/rt-c.XXXXXX")
cp specs/TDD.md "$CUR"
bash "$LIB" resolve-vh --ours "$CUR" --theirs "$THEIRS" --out specs/TDD.md

MB=$(mktemp "${TMPDIR:-/tmp}/rt-mb.XXXXXX")
BB=$(mktemp "${TMPDIR:-/tmp}/rt-bb.XXXXXX")
git show "$BASE:CHANGELOG.md" > "$MB"
git show feat/a:CHANGELOG.md > "$BB"
bash "$LIB" resolve-changelog "$ASSIGNED" --branch-file "$BB" --master-file "$MB" --out CHANGELOG.md
bash "$LIB" resolve-json "$ASSIGNED"
# renumber no-op if already assigned==assumed
bash "$LIB" renumber 0.40.0 0.40.0 >/dev/null || true

grep -q 'SPEC-023' specs/TDD.md && pass || fail "SPEC-023 row missing"
grep -q '### v0.40.0' CHANGELOG.md && pass || fail "changelog heading"
[ "$(jq -r .version .claude-plugin/plugin.json)" = "0.40.0" ] && pass || fail "plugin version"

# tree ready for /release — do not commit/tag via train-lib
! grep -nE 'git (tag|push|commit)\b' "$LIB" >/dev/null && pass || fail "M10"

# source branch untouched
[ "$(git rev-parse feat/a)" = "$SHA_A" ] && pass || fail "feat/a mutated"
[ "$(git rev-parse feat/b)" = "$SHA_B" ] && pass || fail "feat/b mutated"

# restore clean
bash "$LIB" restore "$BASE" >/dev/null
[ -z "$(git status --porcelain)" ] && pass || fail "restore dirty"
[ "$(git rev-parse HEAD)" = "$BASE" ] && pass || fail "restore sha"

# conflict outside allowlist → blocked simulation
bash "$LIB" set-status feat/a pending 2>/dev/null || {
  # already landing was set; reset queue for conflict branch
  :
}
# create feat/conflict that edits skills/foo.sh differently
git checkout -q -b feat/conflict
echo 'branch-skill' > skills/foo.sh
git add skills/foo.sh && git commit -q -m "conflict skill"
git checkout -q master
echo 'master-skill-v2' > skills/foo.sh
git add skills/foo.sh && git commit -q -m "master skill v2"
BASE2=$(git rev-parse HEAD)

rm -rf .claude/release-train
bash "$LIB" init >/dev/null
bash "$LIB" register feat/conflict --bump minor >/dev/null
bash "$LIB" freeze >/dev/null
bash "$LIB" set-status feat/conflict landing --base-sha "$BASE2" >/dev/null
set +e
git merge --squash feat/conflict >/dev/null 2>&1
MERGE_RC=$?
set -e
# expect conflict
if [ -n "$(git diff --name-only --diff-filter=U 2>/dev/null)" ] || [ "$MERGE_RC" -ne 0 ]; then
  bash "$LIB" restore "$BASE2" >/dev/null
  bash "$LIB" set-status feat/conflict blocked --paths skills/foo.sh >/dev/null
  ST=$(bash "$LIB" list | jq -r '.entries[]|select(.branch=="feat/conflict")|.status')
  [ "$ST" = "blocked" ] && pass || fail "status blocked got $ST"
  [ -z "$(git status --porcelain)" ] && pass || fail "blocked restore not clean"
else
  fail "expected conflict on skills/foo.sh"
fi

# dry-run / print-only inert
Q_BEFORE=$(cat .claude/release-train/queue.json)
bash "$LIB" freeze --print-only >/dev/null
Q_AFTER=$(cat .claude/release-train/queue.json)
[ "$Q_BEFORE" = "$Q_AFTER" ] && pass || fail "print-only mutated queue"

echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
