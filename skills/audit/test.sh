#!/usr/bin/env bash
# skills/audit/test.sh — SPEC-035 bite-tests for /audit (CDT-200)
#
# Machine-check: bash skills/audit/test.sh  (exit 0)
# THIS SCRIPT IS A SUBPROCESS CLI — NEVER SOURCE IT.
# Revert pattern: rm fixtures under $TMPDIR — never git checkout.
set -u

HERE=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(CDPATH= cd -- "$HERE/../.." && pwd)
AUDIT="$HERE/audit.sh"
APPLY_PY="$HERE/apply.py"
FROM_SESS="$HERE/from-session.sh"
CMD="$ROOT/commands/audit.md"
SKILL="$HERE/SKILL.md"
SPEC="$ROOT/specs/core/SPEC-035-context-audit.md"
DOCS="$ROOT/docs/commands/audit.md"
DOCTOR_CMD="$ROOT/commands/doctor.md"
FMT="$ROOT/skills/spec-tooling/check-format.sh"
LINT="$ROOT/skills/skill-lint/check-skill-bash.sh"

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); echo "PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "FAIL: $1" >&2; }

TMP=$(mktemp -d "${TMPDIR:-/tmp}/audit-test.XXXXXX")
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

audit() {
  bash "$AUDIT" "$@"
}

# ---- T-pre: surfaces --------------------------------------------------------
if [ -f "$CMD" ]; then pass "T-pre commands/audit.md exists"; else fail "T-pre commands/audit.md missing"; fi
if [ -f "$SKILL" ]; then pass "T-pre skills/audit/SKILL.md exists"; else fail "T-pre SKILL.md missing"; fi
if [ -f "$AUDIT" ]; then pass "T-pre audit.sh exists"; else fail "T-pre audit.sh missing"; fi
if [ -f "$SPEC" ]; then pass "T-pre SPEC-035 exists"; else fail "T-pre SPEC-035 missing"; fi
if [ -f "$DOCS" ]; then pass "T-pre docs/commands/audit.md exists"; else fail "T-pre docs page missing"; fi

fm_ok() {
  local f="$1" label="$2"
  [ -f "$f" ] || { fail "$label missing (frontmatter)"; return; }
  if awk '
    BEGIN { in_fm=0; has_name=0; has_desc=0; closed=0 }
    NR==1 && $0=="---" { in_fm=1; next }
    in_fm && $0=="---" { closed=1; exit }
    in_fm && /^name:[[:space:]]/ { has_name=1 }
    in_fm && /^description:[[:space:]]/ { has_desc=1 }
    END { exit (closed && has_name && has_desc) ? 0 : 1 }
  ' "$f"; then
    pass "$label frontmatter name+description"
  else
    fail "$label missing YAML frontmatter (name/description)"
  fi
}
fm_ok "$CMD" "command"
fm_ok "$SKILL" "skill"

# ---- T-size: SKILL.md < 40KB; WARN 30KB documented --------------------------
if [ -f "$SKILL" ]; then
  SKILL_BYTES=$(wc -c < "$SKILL" | tr -d ' ')
  if [ "$SKILL_BYTES" -lt 40960 ]; then
    pass "T-size SKILL.md ${SKILL_BYTES}B < 40KB hard"
  else
    fail "T-size SKILL.md ${SKILL_BYTES}B >= 40960 hard cap"
  fi
  if grep -qE '30[[:space:]]*Ki?B|30720' "$SKILL"; then
    pass "T-size WARN 30KB / 30720 documented in SKILL.md"
  else
    fail "T-size WARN threshold not documented in SKILL.md"
  fi
else
  fail "T-size SKILL.md missing"
  fail "T-size WARN threshold undocumented"
fi

# ---- T-noreinit: token absent from Surface text -----------------------------
NOREINIT_HITS=0
for f in "$CMD" "$SKILL" "$DOCS" "$AUDIT" "$APPLY_PY" "$FROM_SESS"; do
  [ -f "$f" ] || continue
  if grep -qiE 'reinit' "$f"; then
    fail "T-noreinit token present in $f"
    NOREINIT_HITS=$((NOREINIT_HITS + 1))
  fi
done
if [ "$NOREINIT_HITS" -eq 0 ]; then
  pass "T-noreinit no token in command/skill/docs/cli"
fi

# ---- Fixture tree: user-global + parent + project + directives --------------
HOME_F="$TMP/home"
PROJ="$TMP/parent/proj"
PLUGIN_F="$TMP/plugin"
mkdir -p "$HOME_F/.claude/memory/ic5"
mkdir -p "$HOME_F/.grok"
mkdir -p "$PROJ/.claude/memory/pm"
mkdir -p "$PLUGIN_F/skills/ok" "$PLUGIN_F/skills/fat"
printf '%s\n' 'user-global CLAUDE rules' > "$HOME_F/.claude/CLAUDE.md"
printf '%s\n' 'grok user-global AGENTS' > "$HOME_F/.grok/AGENTS.md"
printf '%s\n' 'grok user-global CLAUDE' > "$HOME_F/.grok/CLAUDE.md"
printf '%s\n' 'user directive: be terse' > "$HOME_F/.claude/memory/ic5/directives.md"
printf '%s\n' 'parent AGENTS layer' > "$TMP/parent/AGENTS.md"
printf '%s\n' 'project AGENTS freeze-me' > "$PROJ/AGENTS.md"
printf '%s\n' 'project CLAUDE pointer' > "$PROJ/CLAUDE.md"
printf '%s\n' 'project directive: tdd' > "$PROJ/.claude/memory/pm/directives.md"
git init -q "$PROJ"
# small + oversized SKILL.md for size WARN
printf '%s\n' '# ok skill' > "$PLUGIN_F/skills/ok/SKILL.md"
# 31 KiB of 'x' (no python)
dd if=/dev/zero bs=1024 count=31 2>/dev/null | tr '\0' 'x' > "$PLUGIN_F/skills/fat/SKILL.md"

if [ ! -x "$AUDIT" ] && [ ! -f "$AUDIT" ]; then
  fail "T1 inventory skipped (no audit.sh)"
  fail "T2 skill-size skipped"
  fail "T3 read-only skipped"
else
  # ---- T1: inventory finds layers ------------------------------------------
  OUT=""
  RC=0
  OUT=$(audit --json --home "$HOME_F" --cwd "$PROJ" --plugin-root "$PLUGIN_F" 2>"$TMP/t1.err") || RC=$?
  printf '%s\n' "$OUT" > "$TMP/t1.json"
  if printf '%s' "$OUT" | grep -q 'user-global' \
     && printf '%s' "$OUT" | grep -Fq "$HOME_F/.claude/CLAUDE.md" \
     && printf '%s' "$OUT" | grep -q '"layer": "parent"' \
     && printf '%s' "$OUT" | grep -Fq "$TMP/parent/AGENTS.md" \
     && printf '%s' "$OUT" | grep -q '"layer": "project"' \
     && printf '%s' "$OUT" | grep -Fq "$PROJ/AGENTS.md" \
     && printf '%s' "$OUT" | grep -Fq "$PROJ/CLAUDE.md" \
     && printf '%s' "$OUT" | grep -q 'directives' \
     && printf '%s' "$OUT" | grep -Fq "$PROJ/.claude/memory/pm/directives.md" \
     && printf '%s' "$OUT" | grep -Fq "$HOME_F/.claude/memory/ic5/directives.md"; then
    pass "T1 inventory finds user-global + parent + project + directives"
  else
    fail "T1 inventory layers incomplete rc=$RC out=$(printf '%s' "$OUT" | head -c 400)"
  fi
  if printf '%s' "$OUT" | grep -q 'claude+grok' \
     && printf '%s' "$OUT" | grep -q '"claude"' \
     && printf '%s' "$OUT" | grep -q '"grok"'; then
    pass "T1b dual-host claude+grok advertised"
  else
    fail "T1b dual-host labels missing"
  fi
  if printf '%s' "$OUT" | grep -Fq "$HOME_F/.grok/AGENTS.md" \
     && printf '%s' "$OUT" | grep -Fq "$HOME_F/.grok/CLAUDE.md" \
     && printf '%s' "$OUT" | grep -q '"hosts": "grok"'; then
    pass "T1c inventory includes ~/.grok/AGENTS.md + CLAUDE.md (hosts=grok)"
  else
    fail "T1c ~/.grok user-global missing from inventory"
  fi

  # ---- T2: skill-size WARN -------------------------------------------------
  if printf '%s' "$OUT" | grep -q 'SS-fat' \
     && printf '%s' "$OUT" | grep -q 'plugin-surface' \
     && printf '%s' "$OUT" | grep -q '"status": "WARN"'; then
    pass "T2 skill-size WARN for >30KB SKILL.md"
  else
    fail "T2 skill-size WARN missing (want SS-fat / plugin-surface / WARN)"
  fi
  if [ "$RC" -eq 1 ]; then
    pass "T2b inventory exit 1 on skill-size WARN"
  else
    fail "T2b inventory rc=$RC (want 1 for WARN)"
  fi

  # ---- T3: bare inventory is zero writes -----------------------------------
  SNAP1=$(find "$HOME_F" "$PROJ" "$PLUGIN_F" -type f | sort | cksum)
  LIST1=$(find "$HOME_F" "$PROJ" "$PLUGIN_F" -type f | sort)
  audit --json --home "$HOME_F" --cwd "$PROJ" --plugin-root "$PLUGIN_F" >/dev/null 2>&1 || true
  SNAP2=$(find "$HOME_F" "$PROJ" "$PLUGIN_F" -type f | sort | cksum)
  LIST2=$(find "$HOME_F" "$PROJ" "$PLUGIN_F" -type f | sort)
  if [ "$SNAP1" = "$SNAP2" ] && [ "$LIST1" = "$LIST2" ]; then
    pass "T3 inventory zero writes (paths+cksum unchanged)"
  else
    fail "T3 inventory mutated fixture tree"
  fi
fi

# ---- Finding JSON helpers ---------------------------------------------------
write_finding() {
  # write_finding FILE id class path old new evidence_mode
  # evidence_mode: full | none | passages-only
  local dest="$1" id="$2" class="$3" path="$4" old="$5" new="$6" mode="$7"
  local ev
  case "$mode" in
    none) ev='{}' ;;
    passages-only)
      ev=$(cat <<EOF
{"passages":[{"path":"$path","quote":"$old","line":1},{"path":"$path","quote":"layer","line":1}]}
EOF
      )
      ;;
    full)
      ev=$(cat <<EOF
{"passages":[{"path":"$path","quote":"$old","line":1},{"path":"$SPEC","quote":"Mechanical evidence","line":1}],"counts":{"bytes":20,"lines":1},"mtime":"2026-08-16T00:00:00Z","tag":{"name":"v1.0.0","date":"2026-07-01"},"spec":{"id":"SPEC-035","path":"specs/core/SPEC-035-context-audit.md","quote":"Mechanical evidence"}}
EOF
      )
      ;;
    *) ev='{}' ;;
  esac
  cat > "$dest" <<EOF
{"id":"$id","class":"$class","layer":"project","path":"$path","impact":"test impact","confidence":0.9,"evidence":$ev,"action":{"type":"replace-span","old":"$old","new":"$new"}}
EOF
}

# ---- T4: apply rejects finding without mechanical evidence ------------------
if [ -f "$AUDIT" ]; then
  write_finding "$TMP/f-none.json" "IS-NONE" "instruction-stack" "$PROJ/AGENTS.md" "freeze-me" "historical" none
  HASH_BEFORE=$(cksum < "$PROJ/AGENTS.md")
  RC=0
  OUT=$(audit apply IS-NONE --from-json "$TMP/f-none.json" --yes 2>&1) || RC=$?
  HASH_AFTER=$(cksum < "$PROJ/AGENTS.md")
  if [ "$RC" -eq 2 ] && [ "$HASH_BEFORE" = "$HASH_AFTER" ] \
     && printf '%s' "$OUT" | grep -qiE 'mechanical evidence'; then
    pass "T4 apply rejects missing mechanical evidence (rc=2, no write)"
  else
    fail "T4 apply no-evidence rc=$RC out=$OUT"
  fi

  write_finding "$TMP/f-pass.json" "IS-PASS" "instruction-stack" "$PROJ/AGENTS.md" "freeze-me" "historical" passages-only
  RC=0
  OUT=$(audit apply IS-PASS --from-json "$TMP/f-pass.json" --yes 2>&1) || RC=$?
  HASH_AFTER=$(cksum < "$PROJ/AGENTS.md")
  if [ "$RC" -eq 2 ] && [ "$HASH_BEFORE" = "$HASH_AFTER" ]; then
    pass "T4b apply rejects passages-only (need counts + mtime/spec)"
  else
    fail "T4b passages-only rc=$RC file_changed=$([ "$HASH_BEFORE" = "$HASH_AFTER" ] && echo n || echo y)"
  fi

  # ---- T5: apply refuses skill paths ----------------------------------------
  write_finding "$TMP/f-skill.json" "IS-SKILL" "instruction-stack" "$PLUGIN_F/skills/ok/SKILL.md" "ok" "nope" full
  RC=0
  OUT=$(audit apply IS-SKILL --from-json "$TMP/f-skill.json" --yes 2>&1) || RC=$?
  if [ "$RC" -eq 2 ] && printf '%s' "$OUT" | grep -qiE 'skills/|instruction-stack'; then
    pass "T5 apply refuses skills/** path"
  else
    fail "T5 apply skill path rc=$RC out=$OUT"
  fi

  # ---- T6: apply refuses command paths --------------------------------------
  write_finding "$TMP/f-cmd.json" "IS-CMD" "instruction-stack" "$ROOT/commands/audit.md" "audit" "nope" full
  RC=0
  OUT=$(audit apply IS-CMD --from-json "$TMP/f-cmd.json" --yes 2>&1) || RC=$?
  if [ "$RC" -eq 2 ] && printf '%s' "$OUT" | grep -qiE 'commands/|instruction-stack'; then
    pass "T6 apply refuses commands/** path"
  else
    fail "T6 apply command path rc=$RC out=$OUT"
  fi

  # ---- T7: judgment requires --judgment -------------------------------------
  write_finding "$TMP/f-judge.json" "IS-JUDGE" "judgment" "$PROJ/AGENTS.md" "freeze-me" "historical" full
  RC=0
  OUT=$(audit apply IS-JUDGE --from-json "$TMP/f-judge.json" --yes 2>&1) || RC=$?
  HASH_AFTER=$(cksum < "$PROJ/AGENTS.md")
  if [ "$RC" -eq 2 ] && [ "$HASH_BEFORE" = "$HASH_AFTER" ] \
     && printf '%s' "$OUT" | grep -qiE 'judgment'; then
    pass "T7 apply rejects judgment without --judgment"
  else
    fail "T7 judgment rc=$RC out=$OUT"
  fi

  # ---- T8: extra confirm for ~/.claude --------------------------------------
  write_finding "$TMP/f-home.json" "IS-HOME" "instruction-stack" "$HOME_F/.claude/CLAUDE.md" "user-global" "still-global" full
  HOME_BEFORE=$(cksum < "$HOME_F/.claude/CLAUDE.md")
  RC=0
  OUT=$(audit apply IS-HOME --from-json "$TMP/f-home.json" --home "$HOME_F" 2>&1) || RC=$?
  HOME_AFTER=$(cksum < "$HOME_F/.claude/CLAUDE.md")
  if [ "$RC" -eq 2 ] && [ "$HOME_BEFORE" = "$HOME_AFTER" ] \
     && printf '%s' "$OUT" | grep -qiE 'confirm|~/.claude'; then
    pass "T8 apply requires extra confirm for ~/.claude"
  else
    fail "T8 home-confirm rc=$RC out=$OUT"
  fi

  # ---- T9: apply success on project AGENTS.md -------------------------------
  write_finding "$TMP/f-ok.json" "IS-OK" "instruction-stack" "$PROJ/AGENTS.md" "freeze-me" "historical" full
  RC=0
  OUT=$(audit apply IS-OK --from-json "$TMP/f-ok.json" 2>&1) || RC=$?
  if [ "$RC" -eq 0 ] && grep -q 'historical' "$PROJ/AGENTS.md" \
     && ! grep -q 'freeze-me' "$PROJ/AGENTS.md"; then
    pass "T9 apply writes instruction-stack replace-span"
  else
    fail "T9 apply success rc=$RC out=$OUT file=$(cat "$PROJ/AGENTS.md")"
  fi

  # restore for later
  printf '%s\n' 'project AGENTS freeze-me' > "$PROJ/AGENTS.md"

  # ---- T10: plugin-surface class refused even with evidence -----------------
  write_finding "$TMP/f-ps.json" "SS-fat" "plugin-surface" "$PROJ/AGENTS.md" "freeze-me" "historical" full
  RC=0
  OUT=$(audit apply SS-fat --from-json "$TMP/f-ps.json" 2>&1) || RC=$?
  if [ "$RC" -eq 2 ] && grep -q 'freeze-me' "$PROJ/AGENTS.md"; then
    pass "T10 apply refuses plugin-surface class"
  else
    fail "T10 plugin-surface rc=$RC out=$OUT"
  fi

  # ---- T8b: extra confirm for ~/.grok --------------------------------------
  write_finding "$TMP/f-grok.json" "IS-GROK" "instruction-stack" "$HOME_F/.grok/AGENTS.md" "grok user-global" "still-grok" full
  GROK_BEFORE=$(cksum < "$HOME_F/.grok/AGENTS.md")
  RC=0
  OUT=$(audit apply IS-GROK --from-json "$TMP/f-grok.json" --home "$HOME_F" 2>&1) || RC=$?
  GROK_AFTER=$(cksum < "$HOME_F/.grok/AGENTS.md")
  if [ "$RC" -eq 2 ] && [ "$GROK_BEFORE" = "$GROK_AFTER" ] \
     && printf '%s' "$OUT" | grep -qiE 'confirm|~/.grok'; then
    pass "T8b apply requires extra confirm for ~/.grok"
  else
    fail "T8b grok-confirm rc=$RC out=$OUT"
  fi

  # ---- T8c: --yes writes ~/.grok --------------------------------------------
  RC=0
  OUT=$(audit apply IS-GROK --from-json "$TMP/f-grok.json" --home "$HOME_F" --yes 2>&1) || RC=$?
  if [ "$RC" -eq 0 ] && grep -q 'still-grok' "$HOME_F/.grok/AGENTS.md"; then
    pass "T8c apply --yes writes ~/.grok/AGENTS.md"
  else
    fail "T8c grok --yes rc=$RC out=$OUT file=$(cat "$HOME_F/.grok/AGENTS.md")"
  fi
  printf '%s\n' 'grok user-global AGENTS' > "$HOME_F/.grok/AGENTS.md"

  # ---- T11: --all rejected --------------------------------------------------
  RC=0
  OUT=$(audit --all --home "$HOME_F" --cwd "$PROJ" --plugin-root "$PLUGIN_F" 2>&1) || RC=$?
  if [ "$RC" -eq 64 ]; then
    pass "T11 --all exits 64"
  else
    fail "T11 --all rc=$RC (want 64) out=$OUT"
  fi

  # ---- T12: unknown flag ----------------------------------------------------
  RC=0
  OUT=$(audit --nope 2>&1) || RC=$?
  if [ "$RC" -eq 64 ]; then
    pass "T12 unknown flag exits 64"
  else
    fail "T12 unknown flag rc=$RC"
  fi
else
  fail "T4–T12 skipped (no audit.sh)"
fi

# ---- T13: --from-session calls transcript-parse only ------------------------
if [ -f "$FROM_SESS" ]; then
  if grep -q 'transcript-parse/hosts.py' "$FROM_SESS" \
     && grep -q 'locate' "$FROM_SESS"; then
    pass "T13 from-session.sh calls transcript-parse hosts.py locate"
  else
    fail "T13 from-session.sh missing hosts.py locate call"
  fi
  if grep -qE 'assemble\.py|iter_lines|jsonl' "$FROM_SESS"; then
    fail "T13 from-session.sh looks like a second parse engine"
  else
    pass "T13b from-session.sh is locate-only (no second engine)"
  fi
  RC=0
  OUT=$(bash "$FROM_SESS" --session-id "00000000-0000-4000-8000-000000000099" \
    --cwd "$PROJ" 2>&1) || RC=$?
  if [ "$RC" -eq 1 ]; then
    pass "T13c missing session exits 1"
  else
    fail "T13c missing session rc=$RC out=$OUT"
  fi
else
  fail "T13 from-session.sh missing"
  fail "T13b from-session.sh missing"
  fail "T13c from-session.sh missing"
fi

# ---- T17: --from-session --json stdout is a single JSON document ------------
if [ -f "$AUDIT" ] && [ -f "$FROM_SESS" ]; then
  SESS_ROOT="$TMP/grok-sessions"
  ENC=$(CWD_RAW="$PROJ" python3 - <<'PY'
import os, urllib.parse
print(urllib.parse.quote(os.environ["CWD_RAW"], safe=""), end="")
PY
)
  SID="cdt201-json-only"
  mkdir -p "$SESS_ROOT/$ENC/$SID"
  printf '%s\n' '{"type":"user","text":"hi"}' > "$SESS_ROOT/$ENC/$SID/chat_history.jsonl"
  RC=0
  OUT=$(GROK_SESSIONS_DIR="$SESS_ROOT" audit --from-session "$SID" --json \
    --home "$HOME_F" --cwd "$PROJ" --plugin-root "$PLUGIN_F" \
    2>"$TMP/t17.err") || RC=$?
  printf '%s\n' "$OUT" > "$TMP/t17.json"
  JSON_OK=0
  if python3 -c 'import json,sys; json.load(open(sys.argv[1], encoding="utf-8"))' "$TMP/t17.json" 2>/dev/null; then
    JSON_OK=1
  fi
  if [ "$JSON_OK" -eq 1 ] \
     && ! printf '%s' "$OUT" | grep -qE 'host=|from-session:|session_id=' \
     && grep -qE 'host=|from-session:' "$TMP/t17.err"; then
    pass "T17 --from-session --json stdout is JSON-only (locate on stderr)"
  else
    fail "T17 json-only rc=$RC json_ok=$JSON_OK stdout_head=$(printf '%s' "$OUT" | head -c 160) err=$(head -c 160 "$TMP/t17.err")"
  fi

  # ---- T18: apply refuses symlink whose realpath is under skills/** ----------
  ln -s "$PLUGIN_F/skills/ok/SKILL.md" "$TMP/AGENTS.md"
  SKILL_BEFORE=$(cksum < "$PLUGIN_F/skills/ok/SKILL.md")
  write_finding "$TMP/f-symlink.json" "IS-LINK" "instruction-stack" "$TMP/AGENTS.md" "ok" "nope" full
  RC=0
  OUT=$(audit apply IS-LINK --from-json "$TMP/f-symlink.json" --yes 2>&1) || RC=$?
  SKILL_AFTER=$(cksum < "$PLUGIN_F/skills/ok/SKILL.md")
  if [ "$RC" -eq 2 ] && [ "$SKILL_BEFORE" = "$SKILL_AFTER" ] \
     && printf '%s' "$OUT" | grep -qiE 'skills/|instruction-stack'; then
    pass "T18 apply refuses symlink into skills/** (realpath)"
  else
    fail "T18 symlink rc=$RC out=$OUT"
  fi

  # ---- T19: MROOT from --cwd, not invoker cwd --------------------------------
  INV="$TMP/invoker-repo"
  mkdir -p "$INV/.claude/memory/pm"
  printf '%s\n' 'INVOKER-LEAK-DIRECTIVE' > "$INV/.claude/memory/pm/directives.md"
  git init -q "$INV"
  RC=0
  OUT=$(
    CDPATH= cd -- "$INV" && bash "$AUDIT" --json --home "$HOME_F" --cwd "$PROJ" --plugin-root "$PLUGIN_F"
  ) || RC=$?
  if printf '%s' "$OUT" | grep -Fq "$PROJ/.claude/memory/pm/directives.md" \
     && ! printf '%s' "$OUT" | grep -q 'INVOKER-LEAK-DIRECTIVE' \
     && ! printf '%s' "$OUT" | grep -Fq "$INV/.claude/memory/pm/directives.md"; then
    pass "T19 MROOT/directives from --cwd, not invoker repo"
  else
    fail "T19 MROOT leak rc=$RC out=$(printf '%s' "$OUT" | head -c 300)"
  fi
else
  fail "T17 --from-session --json skipped"
  fail "T18 symlink apply skipped"
  fail "T19 MROOT isolation skipped"
fi

# ---- T14: doctor pointer ----------------------------------------------------
if [ -f "$DOCTOR_CMD" ] && grep -q '/audit' "$DOCTOR_CMD"; then
  pass "T14 /doctor points at /audit"
else
  fail "T14 /doctor missing /audit pointer"
fi

# ---- T15: spec format -------------------------------------------------------
if [ -f "$SPEC" ] && [ -f "$FMT" ]; then
  RC=0
  OUT=$(bash "$FMT" "$SPEC" 2>&1) || RC=$?
  if [ "$RC" -eq 0 ]; then
    pass "T15 SPEC-035 check-format OK"
  else
    fail "T15 SPEC-035 format rc=$RC out=$OUT"
  fi
else
  fail "T15 SPEC-035 or check-format.sh missing"
fi

# ---- T16: skill-lint on new md ----------------------------------------------
if [ -f "$LINT" ] && [ -f "$CMD" ] && [ -f "$SKILL" ]; then
  RC=0
  OUT=$(bash "$LINT" "$CMD" "$SKILL" "$DOCS" 2>&1) || RC=$?
  if [ "$RC" -eq 0 ]; then
    pass "T16 skill-lint clean on audit md"
  else
    fail "T16 skill-lint rc=$RC out=$OUT"
  fi
else
  fail "T16 skill-lint skipped (missing inputs)"
fi

echo
echo "$PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
exit 0
