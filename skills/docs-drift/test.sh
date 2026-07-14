#!/usr/bin/env bash
# SPEC-010 D7 bite-test harness. Run: bash skills/docs-drift/test.sh
# Live inject + cp restore ONLY — never git checkout.
set -u
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
CHECK="$HERE/check-docs-drift.sh"
REPO_ROOT=$(cd "$HERE/../.." && pwd)
PASS=0; FAIL=0
OUT=""; RC=0
SCRATCH=$(mktemp -d)
trap 'rm -rf "$SCRATCH"' EXIT

run_check() { # run_check <expected_exit> [args...]
  local want="$1"; shift
  OUT=$(bash "$CHECK" "$@" 2>&1); RC=$?
  if [ "$RC" -eq "$want" ]; then PASS=$((PASS+1)); else
    FAIL=$((FAIL+1)); echo "FAIL: exit $RC != $want for: $*"; echo "$OUT" | head -8
  fi
}

expect_finding() { # expect_finding <check-id>
  if echo "$OUT" | grep -q "\[$1\]"; then PASS=$((PASS+1)); else
    FAIL=$((FAIL+1)); echo "FAIL: no [$1] finding in:"; echo "$OUT" | head -8
  fi
}

expect_no_finding() { # expect_no_finding <check-id>
  if echo "$OUT" | grep -q "\[$1\]"; then
    FAIL=$((FAIL+1)); echo "FAIL: unexpected [$1]:"; echo "$OUT" | grep "\[$1\]" | head -3
  else PASS=$((PASS+1)); fi
}

backup() { # backup <path> → sets BAK
  local src="$1"
  BAK="$SCRATCH/$(echo "$src" | tr '/' '_').bak"
  cp -a "$src" "$BAK"
}

restore() { # restore <path>
  cp -a "$BAK" "$1"
}

# ---------------------------------------------------------------------------
# T0: CLI edges
# ---------------------------------------------------------------------------
run_check 64 --no-such-flag
run_check 64 --root /no/such/docs-drift-root-$$

# ---------------------------------------------------------------------------
# Minimal synthetic tree — clean baseline for isolated bites
# ---------------------------------------------------------------------------
MINI=$(mktemp -d)
trap 'rm -rf "$SCRATCH" "$MINI"' EXIT

mkdir -p "$MINI/commands" "$MINI/agents" "$MINI/skills/hello" \
         "$MINI/docs/commands" "$MINI/.claude-plugin"

# agents
for a in pm ic4; do
  printf '%s\n' "---" "name: $a" "description: test" "---" > "$MINI/agents/$a.md"
done

# commands + skills-backed
printf '%s\n' "---" "name: demo" "description: d" "---" > "$MINI/commands/demo.md"
printf '%s\n' "---" "name: hello" "description: skill" "---" > "$MINI/skills/hello/SKILL.md"

# docs page linked from docs/README
printf '%s\n' "# demo" > "$MINI/docs/commands/demo.md"
cat > "$MINI/docs/README.md" << 'EOF'
# docs
| Command | Docs |
|---------|------|
| `/demo` | [demo](commands/demo.md) |
EOF

# README with Commands + Agents sections
cat > "$MINI/README.md" << 'EOF'
## What You Get

### Agents

| Agent | Model | Role |
|-------|-------|------|
| `pm` | Sonnet | PM |
| `ic4` | Sonnet | IC |

## Commands

| Command | What it does |
|---------|-------------|
| `/demo` | Demo command |
| `/hello` | Skills-backed command |

## Other
EOF

# AGENTS.md roster
cat > "$MINI/AGENTS.md" << 'EOF'
## Agent Roster

| Agent | Model | Role |
|-------|-------|------|
| `pm` | Sonnet | PM |
| `ic4` | Sonnet | IC |
EOF

# matching manifests
DESC='A test plugin description for docs-drift.'
python3 -c "
import json
json.dump({'name':'t','description':'''$DESC''','version':'0.0.1'}, open('$MINI/.claude-plugin/plugin.json','w'))
json.dump({'plugins':[{'name':'t','description':'''$DESC'''}]}, open('$MINI/.claude-plugin/marketplace.json','w'))
"

# Clean mini → exit 0
run_check 0 --root "$MINI"
expect_no_finding cmd-index
expect_no_finding agent-roster
expect_no_finding docs-hub
expect_no_finding manifest-desc

# ---------------------------------------------------------------------------
# T1 cmd-index — both directions + skills-backed ok
# ---------------------------------------------------------------------------
# (a) undocumented command
printf '%s\n' "---" "name: zz-test" "description: t" "---" > "$MINI/commands/zz-test.md"
run_check 1 --root "$MINI"
expect_finding cmd-index
echo "$OUT" | grep -q "zz-test" && PASS=$((PASS+1)) || {
  FAIL=$((FAIL+1)); echo "FAIL: cmd-index should name zz-test"
}
rm -f "$MINI/commands/zz-test.md"

# (b) ghost index row
backup "$MINI/README.md"
# insert ghost after /demo row
python3 - <<PY
from pathlib import Path
p = Path("$MINI/README.md")
lines = p.read_text().splitlines(True)
out = []
for line in lines:
    out.append(line)
    if "| \`/demo\`" in line:
        out.append("| \`/no-such-cmd\` | Ghost |\n")
p.write_text("".join(out))
PY
run_check 1 --root "$MINI"
expect_finding cmd-index
echo "$OUT" | grep -q "no-such-cmd" && PASS=$((PASS+1)) || {
  FAIL=$((FAIL+1)); echo "FAIL: cmd-index should name no-such-cmd"
}
restore "$MINI/README.md"

# skills-backed /hello → no cmd-index finding on clean tree
run_check 0 --root "$MINI"
expect_no_finding cmd-index

# ---------------------------------------------------------------------------
# T2 agent-roster
# ---------------------------------------------------------------------------
# remove one AGENTS.md roster row
backup "$MINI/AGENTS.md"
python3 - <<PY
from pathlib import Path
p = Path("$MINI/AGENTS.md")
p.write_text("".join(l for l in p.read_text().splitlines(True) if "\`ic4\`" not in l))
PY
run_check 1 --root "$MINI"
expect_finding agent-roster
restore "$MINI/AGENTS.md"

# ghost README agent row
backup "$MINI/README.md"
python3 - <<PY
from pathlib import Path
p = Path("$MINI/README.md")
lines = p.read_text().splitlines(True)
out = []
for line in lines:
    out.append(line)
    if "| \`ic4\`" in line and "Sonnet" in line:
        out.append("| \`ghost-agent\` | Sonnet | nope |\n")
p.write_text("".join(out))
PY
run_check 1 --root "$MINI"
expect_finding agent-roster
echo "$OUT" | grep -q "ghost-agent" && PASS=$((PASS+1)) || {
  FAIL=$((FAIL+1)); echo "FAIL: agent-roster should name ghost-agent"
}
restore "$MINI/README.md"

# ---------------------------------------------------------------------------
# T3 docs-hub
# ---------------------------------------------------------------------------
# dead link in docs/README
backup "$MINI/docs/README.md"
python3 - <<PY
from pathlib import Path
p = Path("$MINI/docs/README.md")
p.write_text(p.read_text() + "\n| \`/x\` | [x](commands/nope.md) |\n")
PY
run_check 1 --root "$MINI"
expect_finding docs-hub
restore "$MINI/docs/README.md"

# orphan page
printf '%s\n' "# orphan" > "$MINI/docs/commands/orphan.md"
run_check 1 --root "$MINI"
expect_finding docs-hub
echo "$OUT" | grep -q "orphan" && PASS=$((PASS+1)) || {
  FAIL=$((FAIL+1)); echo "FAIL: docs-hub should name orphan"
}
rm -f "$MINI/docs/commands/orphan.md"

# index-only command without docs page → no docs-hub finding
# ( /hello is skills-backed, not a docs page — already clean)
run_check 0 --root "$MINI"
expect_no_finding docs-hub

# ---------------------------------------------------------------------------
# T4 manifest-desc
# ---------------------------------------------------------------------------
backup "$MINI/.claude-plugin/marketplace.json"
python3 - <<PY
import json
from pathlib import Path
p = Path("$MINI/.claude-plugin/marketplace.json")
data = json.loads(p.read_text())
data["plugins"][0]["description"] = data["plugins"][0]["description"] + "X"
p.write_text(json.dumps(data))
PY
run_check 1 --root "$MINI"
expect_finding manifest-desc
# version-only mutate → no finding from THIS gate
restore "$MINI/.claude-plugin/marketplace.json"
backup "$MINI/.claude-plugin/plugin.json"
python3 - <<PY
import json
from pathlib import Path
p = Path("$MINI/.claude-plugin/plugin.json")
data = json.loads(p.read_text())
data["version"] = "9.9.9"
p.write_text(json.dumps(data))
PY
# marketplace version untouched; descriptions still match
run_check 0 --root "$MINI"
expect_no_finding manifest-desc
restore "$MINI/.claude-plugin/plugin.json"

# ---------------------------------------------------------------------------
# T5 waiver (D6)
# ---------------------------------------------------------------------------
backup "$MINI/README.md"
python3 - <<PY
from pathlib import Path
p = Path("$MINI/README.md")
lines = p.read_text().splitlines(True)
out = []
for line in lines:
    out.append(line)
    if "| \`/demo\`" in line:
        out.append("| \`/no-such-cmd\` | Ghost | <!-- drift-ok: cmd-index -->\n")
p.write_text("".join(out))
PY
run_check 0 --root "$MINI"
echo "$OUT" | grep -q "1 findings, 1 waived" && PASS=$((PASS+1)) || {
  FAIL=$((FAIL+1)); echo "FAIL: expected '1 findings, 1 waived', got: $(echo "$OUT" | tail -1)"
}
# wrong waiver id does not suppress
python3 - <<PY
from pathlib import Path
p = Path("$MINI/README.md")
lines = p.read_text().splitlines(True)
out = []
for line in lines:
    if "no-such-cmd" in line:
        out.append("| \`/no-such-cmd\` | Ghost | <!-- drift-ok: docs-hub -->\n")
    else:
        out.append(line)
p.write_text("".join(out))
PY
run_check 1 --root "$MINI"
expect_finding cmd-index
restore "$MINI/README.md"

# manifest-desc unwaivable — mutate desc, ensure still reported
backup "$MINI/.claude-plugin/marketplace.json"
python3 - <<PY
import json
from pathlib import Path
p = Path("$MINI/.claude-plugin/marketplace.json")
data = json.loads(p.read_text())
data["plugins"][0]["description"] = "mutated"
p.write_text(json.dumps(data))
PY
run_check 1 --root "$MINI"
expect_finding manifest-desc
restore "$MINI/.claude-plugin/marketplace.json"

# ---------------------------------------------------------------------------
# T6 live-tree inject (real repo) — each check-id + cp restore
# NEVER git checkout
# ---------------------------------------------------------------------------
LIVE_STATUS_BEFORE=$(cd "$REPO_ROOT" && git status --porcelain)

# cmd-index: inject undocumented command file
printf '%s\n' "---" "name: zz-docs-drift-bite" "description: bite" "---" \
  > "$REPO_ROOT/commands/zz-docs-drift-bite.md"
OUT=$(bash "$CHECK" --root "$REPO_ROOT" 2>&1); RC=$?
[ "$RC" -eq 1 ] && echo "$OUT" | grep -q '\[cmd-index\]' && echo "$OUT" | grep -q 'zz-docs-drift-bite' \
  && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); echo "FAIL: live cmd-index inject"; echo "$OUT" | head -5; }
rm -f "$REPO_ROOT/commands/zz-docs-drift-bite.md"

# agent-roster: remove one AGENTS.md row
backup "$REPO_ROOT/AGENTS.md"
python3 - <<PY
from pathlib import Path
p = Path("$REPO_ROOT/AGENTS.md")
p.write_text("".join(l for l in p.read_text().splitlines(True) if "\`distiller\`" not in l))
PY
OUT=$(bash "$CHECK" --root "$REPO_ROOT" 2>&1); RC=$?
[ "$RC" -eq 1 ] && echo "$OUT" | grep -q '\[agent-roster\]' \
  && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); echo "FAIL: live agent-roster inject"; echo "$OUT" | head -8; }
restore "$REPO_ROOT/AGENTS.md"

# docs-hub: orphan page
printf '%s\n' "# zz-orphan-bite" > "$REPO_ROOT/docs/commands/zz-orphan-bite.md"
OUT=$(bash "$CHECK" --root "$REPO_ROOT" 2>&1); RC=$?
[ "$RC" -eq 1 ] && echo "$OUT" | grep -q '\[docs-hub\]' && echo "$OUT" | grep -q 'zz-orphan-bite' \
  && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); echo "FAIL: live docs-hub inject"; echo "$OUT" | head -8; }
rm -f "$REPO_ROOT/docs/commands/zz-orphan-bite.md"

# manifest-desc: mutate marketplace description one char
backup "$REPO_ROOT/.claude-plugin/marketplace.json"
python3 - <<PY
import json
from pathlib import Path
p = Path("$REPO_ROOT/.claude-plugin/marketplace.json")
data = json.loads(p.read_text())
for pl in data.get("plugins", []):
    if "description" in pl:
        pl["description"] = pl["description"] + "\u200b"  # zero-width space
        break
p.write_text(json.dumps(data, indent=2) + "\n")
PY
OUT=$(bash "$CHECK" --root "$REPO_ROOT" 2>&1); RC=$?
[ "$RC" -eq 1 ] && echo "$OUT" | grep -q '\[manifest-desc\]' \
  && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); echo "FAIL: live manifest-desc inject"; echo "$OUT" | head -8; }
restore "$REPO_ROOT/.claude-plugin/marketplace.json"

# ---------------------------------------------------------------------------
# T7 restore discipline: no inject artifacts; harness never used git checkout
# ---------------------------------------------------------------------------
LIVE_STATUS_AFTER=$(cd "$REPO_ROOT" && git status --porcelain)
# inject artifacts specifically
if [ -e "$REPO_ROOT/commands/zz-docs-drift-bite.md" ] || [ -e "$REPO_ROOT/docs/commands/zz-orphan-bite.md" ]; then
  FAIL=$((FAIL+1)); echo "FAIL: inject artifacts remain"
else
  PASS=$((PASS+1))
fi
# porcelain for our inject targets must match pre-state (no leftover)
# Allow other dirty files in the worktree; only assert inject paths clean.
INJECT_DIRTY=$(echo "$LIVE_STATUS_AFTER" | grep -E 'zz-docs-drift-bite|zz-orphan-bite' || true)
if [ -n "$INJECT_DIRTY" ]; then
  FAIL=$((FAIL+1)); echo "FAIL: inject paths dirty after restore: $INJECT_DIRTY"
else
  PASS=$((PASS+1))
fi
# AGENTS.md + marketplace.json must be byte-restored
if ! cmp -s "$REPO_ROOT/AGENTS.md" <(cd "$REPO_ROOT" && git show HEAD:AGENTS.md 2>/dev/null || cat "$REPO_ROOT/AGENTS.md"); then
  # if not in git or differs for other reasons, at least ensure distiller row present
  grep -q '`distiller`' "$REPO_ROOT/AGENTS.md" && PASS=$((PASS+1)) || {
    FAIL=$((FAIL+1)); echo "FAIL: AGENTS.md missing distiller after restore"
  }
else
  PASS=$((PASS+1))
fi

# Informational: live-tree findings (T2 will clean cmd-index)
echo "---"
echo "INFO live-tree scan (informational for T2):"
bash "$CHECK" --root "$REPO_ROOT" 2>&1 | tail -20 || true

echo "---"
echo "docs-drift tests: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
