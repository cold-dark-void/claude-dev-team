#!/usr/bin/env bash
# spawn-site-test.sh — CDT-222 static contract for SPEC-037 M15/M14/M16/M12/AC2.
# Greps committed templates/docs only (no network, no LLM).
# Run: bash skills/model-map/spawn-site-test.sh
set -u

HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT=$(CDPATH= cd -- "$HERE/../.." && pwd)

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $*"; }

# M13 spawn sites (SPEC-037 M15): must mention resolve-model.sh + host-reject.
SITES='
skills/orchestrate/steps/04-kickoff.md
skills/orchestrate/steps/06-design.md
skills/orchestrate/steps/08-execute.md
skills/orchestrate/steps/09-review.md
skills/orchestrate/steps/10-qa.md
skills/code-simplify/SKILL.md
skills/ci-watch/SKILL.md
'

# M16 negatives: must not mention resolve-model.sh.
NEGATIVES='
skills/kickoff/SKILL.md
skills/epic/SKILL.md
skills/debug/SKILL.md
commands/council.md
'

# M12 roster (SPEC-003 + AGENTS.md internals). Values are YAML tokens.
ROSTER='
pm:sonnet
tech-lead:opus
ic5:opus
ic4:sonnet
devops:sonnet
qa:opus
ds:opus
distiller:haiku
council-judge:opus
project-init:sonnet
'

frontmatter_model() {
  awk '
    BEGIN { n=0 }
    /^---[[:space:]]*$/ {
      n++
      if (n == 2) exit
      next
    }
    n == 1 && $0 ~ /^model:[[:space:]]*/ {
      sub(/^model:[[:space:]]*/, "")
      gsub(/[[:space:]]+$/, "")
      gsub(/^["'\'']|["'\'']$/, "")
      print
      exit
    }
  ' "$1"
}

# Strip full-line comments. Docs/comments may mention the map path.
code_lines() {
  grep -vE '^[[:space:]]*(#|$)' "$1"
}

# resolve-model.sh: > / mkdir targeting $MAP or models.local.json (SPEC-037 M10).
resolve_write_hits() {
  code_lines "$1" | grep -E \
    -e '(>|>>|[[:space:]]tee[[:space:]]+)[[:space:]]*("|'\'')?(\$MAP|\$\{MAP\}|[^[:space:]]*models\.local\.json)' \
    -e 'mkdir.*(\$MAP|\$\{MAP\}|models\.local\.json|\.claude/dev-team)' \
    || true
}

# Other production .sh: redirect onto the literal map filename only ($MAP is
# a common unrelated variable). Test harnesses write temp fixtures — skip.
tree_redirect_hits() {
  code_lines "$1" | grep -E \
    '(>|>>|[[:space:]]tee[[:space:]]+)[[:space:]]*[^[:space:]]*models\.local\.json' \
    || true
}

# ---- M15 + M14: every M13 site has resolve-model.sh and host-reject prose ----
for rel in $SITES; do
  f="$ROOT/$rel"
  if [ ! -f "$f" ]; then
    bad "M15 missing $rel"
    continue
  fi
  if grep -qF 'resolve-model.sh' "$f"; then
    ok
  else
    bad "M15 $rel lacks resolve-model.sh"
  fi
  if grep -qF 'retry once' "$f" && grep -qF 'host rejected' "$f"; then
    ok
  else
    bad "M14 $rel lacks host-reject language (retry once / host rejected)"
  fi
done

# ---- M16: kickoff/epic/debug/council must not wire the resolver ----
for rel in $NEGATIVES; do
  f="$ROOT/$rel"
  if [ ! -f "$f" ]; then
    bad "M16 missing $rel"
    continue
  fi
  if grep -qF 'resolve-model.sh' "$f"; then
    bad "M16 $rel must not contain resolve-model.sh"
  else
    ok
  fi
done

# ---- M12: agents/*.md frontmatter model: matches roster ----
for pair in $ROSTER; do
  name=${pair%%:*}
  want=${pair#*:}
  f="$ROOT/agents/${name}.md"
  if [ ! -f "$f" ]; then
    bad "M12 missing agents/${name}.md"
    continue
  fi
  got=$(frontmatter_model "$f")
  if [ "$got" = "$want" ]; then
    ok
  else
    bad "M12 agents/${name}.md model:'${got}' want '${want}'"
  fi
done

# ---- AC2 / M10: resolve-model.sh must not write or mkdir the map ----
RESOLVE="$HERE/resolve-model.sh"
if [ ! -f "$RESOLVE" ]; then
  bad "AC2 missing resolve-model.sh"
else
  hits=$(resolve_write_hits "$RESOLVE")
  if [ -z "$hits" ]; then
    ok
  else
    bad "AC2 resolve-model.sh writes/mkdirs the map:"$'\n'"$hits"
  fi
fi

# Tree-wide: production skills/**/*.sh (not test harnesses) must not redirect
# onto models.local.json. Fixture tests write a temp map; skip those.
TREE_BAD=""
while IFS= read -r sh; do
  base=$(basename "$sh")
  case "$base" in
    test.sh|*-test.sh|test-*.sh) continue ;;
  esac
  hits=$(tree_redirect_hits "$sh")
  [ -z "$hits" ] && continue
  rel=${sh#"$ROOT/"}
  TREE_BAD="${TREE_BAD}${rel}"$'\n'"${hits}"$'\n'
done < <(find "$ROOT/skills" -name '*.sh' -type f | sort)
if [ -z "$TREE_BAD" ]; then
  ok
else
  bad "AC2 skills/**/*.sh redirect onto models.local.json:"$'\n'"$TREE_BAD"
fi

echo "PASS=$PASS FAIL=$FAIL"
if [ "$FAIL" -eq 0 ]; then
  exit 0
fi
exit 1
