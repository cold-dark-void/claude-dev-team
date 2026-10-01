#!/usr/bin/env bash
# Untrusted input must not become code (WP 2-06).
# Machine-check: bash skills/validate-memory/test-untrusted-input.sh
set -u

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/../.." && pwd)
PASS=0
FAIL=0

ok() { PASS=$((PASS + 1)); echo "PASS: $1"; }
bad() { FAIL=$((FAIL + 1)); echo "FAIL: $1" >&2; }

MEM="$ROOT/commands/memory.md"
RECALL="$ROOT/commands/recall.md"
RETRO="$ROOT/commands/retro.md"
INIT="$ROOT/agents/project-init.md"
ORCH="$ROOT/skills/init-orchestration/SKILL.md"
STORE="$ROOT/skills/memory-store/SKILL.md"
AGENTS="$ROOT/AGENTS.md"

# CDT-412: path values are argv, not Python source.
if grep -F "os.path.join('\$WTROOT'" "$MEM" >/dev/null 2>&1 || grep -F "os.path.relpath('\$1'" "$MEM" >/dev/null 2>&1; then
  bad "memory.md still interpolates a path into python3 -c"
else
  ok "memory.md path fallback does not interpolate"
fi
if grep -F "sys.argv[1]" "$MEM" >/dev/null 2>&1; then
  MARK=$(mktemp "${TMPDIR:-/tmp}/untrusted-mark.XXXXXX")
  rm -f "$MARK"
  GOT=$(python3 -c 'import os,sys; print(os.path.normpath(os.path.join(sys.argv[1], sys.argv[2])))' /proj "x'); import os; os.system('touch $MARK'); ('" 2>/dev/null || true)
  if [ -f "$MARK" ]; then
    bad "path payload executed"
  elif printf '%s' "$GOT" | grep -qF "touch"; then
    ok "quote-bearing path is printed literally"
  else
    bad "path helper output missing payload: $GOT"
  fi
  rm -f "$MARK"
else
  bad "memory.md path fallback does not pass argv"
fi

# T-1: roster rejection is the shipped require-agent.sh
REQ="$ROOT/skills/lib/require-agent.sh"
if [ -f "$REQ" ] && grep -q 'require-agent.sh' "$MEM"; then
  if bash "$REQ" "x'; DROP TABLE memories; --" >/dev/null 2>&1; then
    bad "require-agent accepted a SQL payload"
  else
    ok "require-agent rejects a SQL payload"
  fi
  if bash "$REQ" pm >/dev/null 2>&1; then
    ok "require-agent accepts pm"
  else
    bad "require-agent rejected pm"
  fi
else
  bad "require-agent.sh is not wired from memory.md"
fi

# sqlq.py binds values
SQLQ="$ROOT/skills/lib/sqlq.py"
if [ -f "$SQLQ" ]; then
  DB=$(mktemp "${TMPDIR:-/tmp}/sqlq.XXXXXX")
  rm -f "$DB"
  sqlite3 "$DB" "CREATE TABLE t(v TEXT); INSERT INTO t VALUES ('keep');"
  python3 "$SQLQ" "$DB" "INSERT INTO t(v) VALUES (?)" "x'; DROP TABLE t; --" >/dev/null
  N=$(sqlite3 "$DB" "SELECT COUNT(*) FROM t;")
  if [ "$N" = "2" ]; then
    ok "sqlq.py binds a quote payload"
  else
    bad "sqlq.py row count=$N"
  fi
  rm -f "$DB"
else
  bad "skills/lib/sqlq.py missing"
fi

# recall: quoted hint, literal grep, LIKE escape
if grep -q 'argument-hint: "\[topic\]"' "$RECALL" && grep -q 'grep -F --' "$RECALL"; then
  ok "recall hint is a string and grep is fixed-string"
else
  bad "recall hint or grep -F missing"
fi
TOPIC_SH="$ROOT/skills/lib/recall-topic.sh"
if [ -f "$TOPIC_SH" ]; then
  MARK=$(mktemp -d "${TMPDIR:-/tmp}/recall-mark.XXXXXX")
  OUT=$(bash "$TOPIC_SH" '$(touch '"$MARK/pwned"')' 2>"$MARK/err") || true
  if [ -e "$MARK/pwned" ]; then
    bad "recall topic executed a command substitution"
  elif printf '%s\n' "$OUT" | head -1 | grep -qF '$(touch'; then
    ok "recall topic stays literal"
  else
    bad "recall topic output unexpected: $OUT"
  fi
  LIKE=$(bash "$TOPIC_SH" '50%' | tail -1)
  if [ "$LIKE" = '50\%' ]; then
    ok "recall escapes LIKE percent"
  else
    bad "recall LIKE got [$LIKE]"
  fi
  LITQ=$(bash "$TOPIC_SH" "O'Brien" | head -1)
  LIKEQ=$(bash "$TOPIC_SH" "O'Brien" | tail -1)
  if [ "$LITQ" = "O'Brien" ] && [ "$LIKEQ" = "O''Brien" ]; then
    ok "recall LIKE doubles a quote and the literal line does not"
  else
    bad "recall quote literal=[$LITQ] like=[$LIKEQ]"
  fi
  rm -rf "$MARK"
else
  bad "recall-topic.sh missing"
fi

# retro and init-orchestration must not paste a path into python source
if grep -F "startswith('\$JSONL" "$RETRO" >/dev/null 2>&1; then
  bad "retro.md still interpolates JSONL into python"
else
  ok "retro.md does not interpolate JSONL"
fi
if grep -F "open('\$f')" "$ORCH" >/dev/null 2>&1 || grep -F "open('\$SETTINGS')" "$ORCH" >/dev/null 2>&1; then
  bad "init-orchestration still interpolates a path into python"
else
  ok "init-orchestration opens paths from argv"
fi

# project-init: no Bash(*) seed, MROOT derived in the CLAUDE.md fence, quoted heredoc
if grep -q '"Bash(\*)"' "$INIT"; then
  bad "project-init still seeds Bash(*)"
else
  ok "project-init does not seed Bash(*)"
fi
if grep -q 'Do not write `defaultMode`' "$INIT"; then
  ok "project-init does not write defaultMode"
else
  bad "project-init still seeds defaultMode"
fi
if grep -q "mkdir -p \"\$MROOT/.claude\"" "$INIT" && grep -B5 'mkdir -p "\$MROOT/.claude"' "$INIT" | grep -q 'git rev-parse --git-common-dir'; then
  ok "project-init derives MROOT before writing CLAUDE.md"
else
  bad "project-init CLAUDE.md fence does not derive MROOT"
fi

# convention recorded
if grep -q 'roster regex' "$AGENTS"; then
  ok "AGENTS.md records the untrusted-input convention"
else
  bad "AGENTS.md convention missing"
fi

# memory-store insert example uses a bound placeholder, not a raw <AGENT> splice in SQL
if grep -q "VALUES ('<AGENT>'" "$STORE"; then
  bad "memory-store SKILL still splices <AGENT> into SQL"
else
  ok "memory-store SKILL does not splice <AGENT>"
fi

echo "---"
echo "untrusted-input: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
