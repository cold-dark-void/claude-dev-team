#!/usr/bin/env bash
# test-orch-allowlist.sh — CDT-51 TL P0: greenfield template allow ⊇ matrix set
#   + CDT-608: plugin self-edit allow set (ACs A/B) and the live self-edit probe (AC C)
# Machine-check: bash skills/init-orchestration/test-orch-allowlist.sh  (exit 0)
# THIS SCRIPT IS A SUBPROCESS CLI — NEVER SOURCE IT.

set -u

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SKILL="$SCRIPT_DIR/SKILL.md"
PROJECT_INIT="$SCRIPT_DIR/../../agents/project-init.md"

# Matrix probe allow set (docs/runbooks/permission-posture-matrix.md Cell C)
MATRIX_ALLOW=(
  'Bash(*)'
  'Read'
  'Write'
  'Edit'
  'Glob'
  'Grep'
  'Agent'
  'Task'
)

PASS=0
FAIL=0

assert_file() {
  local name="$1" path="$2"
  if [ -f "$path" ]; then
    PASS=$((PASS + 1)); echo "  ok  $name"
  else
    FAIL=$((FAIL + 1)); echo "  FAIL $name: missing $path"
  fi
}

echo "=== test-orch-allowlist (CDT-51 TL P0 matrix allow) ==="

assert_file "SKILL.md exists" "$SKILL"
assert_file "project-init.md exists" "$PROJECT_INIT"

# ---------- Extract greenfield permissions.allow block from SKILL.md ----------
# Pull the first fenced ```json ... ``` that contains "defaultMode": "auto" (Cell D)
# and collect quoted allow entries between "allow": [ and the closing ].
echo "-- greenfield template ⊇ matrix set"

template_allow_py() { python3 - "$SKILL" <<'PY'
import re, sys
text = open(sys.argv[1], encoding="utf-8").read()
# Find json fence containing auto defaultMode (greenfield orch template, CDT-75)
blocks = re.findall(r"```json\n(.*?)```", text, flags=re.S)
chosen = None
for b in blocks:
    if '"defaultMode": "auto"' in b and '"allow"' in b:
        chosen = b
        break
if not chosen:
    print("NO_TEMPLATE", file=sys.stderr)
    sys.exit(2)
# Collect string entries under allow array
m = re.search(r'"allow"\s*:\s*\[(.*?)\]', chosen, flags=re.S)
if not m:
    print("NO_ALLOW", file=sys.stderr)
    sys.exit(2)
entries = re.findall(r'"([^"]+)"', m.group(1))
for e in entries:
    print(e)
PY
}
TEMPLATE_ALLOW=$(template_allow_py)
RC=$?
if [ "$RC" -ne 0 ] || [ -z "$TEMPLATE_ALLOW" ]; then
  FAIL=$((FAIL + 1)); echo "  FAIL extract greenfield allow from SKILL.md"
else
  PASS=$((PASS + 1)); echo "  ok  extracted greenfield allow"
fi

for entry in "${MATRIX_ALLOW[@]}"; do
  if printf '%s\n' "$TEMPLATE_ALLOW" | grep -qxF -- "$entry"; then
    PASS=$((PASS + 1)); echo "  ok  template has [$entry]"
  else
    FAIL=$((FAIL + 1)); echo "  FAIL template missing [$entry]"
  fi
done

# ---------- Brownfield merge protocol must require full matrix set ----------
echo "-- brownfield merge protocol"
for needle in \
  'Read' \
  'Write' \
  'Edit' \
  'Glob' \
  'Grep' \
  'Agent' \
  'Task' \
  'matrix set'
do
  if grep -qF -- "$needle" "$SKILL"; then
    PASS=$((PASS + 1)); echo "  ok  skill merge/docs mention [$needle]"
  else
    FAIL=$((FAIL + 1)); echo "  FAIL skill missing merge mention [$needle]"
  fi
done

# Explicit: brownfield line must not be Bash(*)-only
if grep -qE 'permissions\.allow.*contains.*"Bash\(\*\)"' "$SKILL" \
  && ! grep -qF 'every entry from the greenfield template allow list' "$SKILL"; then
  FAIL=$((FAIL + 1)); echo "  FAIL brownfield still Bash(*)-only"
else
  PASS=$((PASS + 1)); echo "  ok  brownfield requires full greenfield allow set"
fi

# ---------- AC J: single-line "Ensure permissions.allow contains" check ----------
echo "-- Ensure permissions.allow contains: single-line check"

check_allow_line() {
  # $1: file to check. Returns 0 if the "Ensure `permissions.allow` contains"
  # line names every matrix entry; 1 if the line is missing or incomplete.
  local file="$1" line item needle rc=0
  line=$(grep -F -- 'Ensure `permissions.allow` contains' "$file" 2>/dev/null | head -n1)
  [ -n "$line" ] || return 1
  for item in "${MATRIX_ALLOW[@]}"; do
    needle='`'"$item"'`'
    if ! printf '%s\n' "$line" | grep -qF -- "$needle"; then
      rc=1
    fi
  done
  return "$rc"
}

if check_allow_line "$SKILL"; then
  PASS=$((PASS + 1)); echo "  ok  allow-contains line names every matrix entry"
else
  FAIL=$((FAIL + 1)); echo "  FAIL allow-contains line missing a matrix entry"
fi

TMP=$(mktemp -d "${TMPDIR:-/tmp}/orch-allowlist-test.XXXXXX")
trap 'rm -rf "$TMP"' EXIT
NO_GLOB="$TMP/SKILL-no-glob.md"
sed '/Ensure `permissions.allow` contains/ s/, `Glob`//' "$SKILL" > "$NO_GLOB"

if check_allow_line "$NO_GLOB"; then
  FAIL=$((FAIL + 1)); echo "  FAIL bite check: temp copy missing Glob should FAIL but passed"
else
  PASS=$((PASS + 1)); echo "  ok  bite check: temp copy missing Glob reports FAIL"
fi

# ---------- P1: project-init must not claim to BE the orchestration posture ----------
echo "-- project-init Step 1b (P1)"
# Old mislabel: "This is the orchestration posture" — negation "NOT the orchestration posture" is OK
if grep -qE 'This is the orchestration posture' "$PROJECT_INIT"; then
  FAIL=$((FAIL + 1)); echo "  FAIL project-init still claims to be orchestration posture"
else
  PASS=$((PASS + 1)); echo "  ok  project-init does not claim to be orchestration posture"
fi
if grep -qF 'team-bootstrap' "$PROJECT_INIT"; then
  PASS=$((PASS + 1)); echo "  ok  project-init labels team-bootstrap"
else
  FAIL=$((FAIL + 1)); echo "  FAIL project-init missing team-bootstrap label"
fi
if grep -qF 'never clobber' "$PROJECT_INIT" || grep -qF 'leave it' "$PROJECT_INIT"; then
  PASS=$((PASS + 1)); echo "  ok  project-init preserves existing defaultMode"
else
  FAIL=$((FAIL + 1)); echo "  FAIL project-init missing defaultMode preserve rule"
fi
if grep -qF 'orchestration markers' "$PROJECT_INIT"; then
  PASS=$((PASS + 1)); echo "  ok  project-init has orch-marker guard"
else
  FAIL=$((FAIL + 1)); echo "  FAIL project-init missing orch-marker guard"
fi

# ---------- CDT-608: plugin self-edit allow set (AC A) ----------
echo "-- CDT-608 self-edit allow set (AC A)"

SELF_EDIT_ALLOW=(
  'Edit(/CHANGELOG.md)'
  'Edit(/.claude-plugin/plugin.json)'
  'Edit(/.claude/hooks/**)'
)

template_allow_block() { # quoted entries of the greenfield template allow array
  awk '/^    "allow": \[/ {grab=1; next}
       /^    \],/ {if (grab) exit}
       grab {print}' "$1"
}

merge_section() { # Step 3 brownfield merge bullets + self-edit merge fence
  awk '/^\*\*If `settings\.json` already exists\*\*/ {grab=1; print; next}
       /^#### / {if (grab) exit}
       grab {print}' "$1"
}

check_self_edit_entries() { # <file> — 0 when template + merge line name every entry
  local file="$1" entry line rc=0
  local block
  block=$(template_allow_block "$file")
  for entry in "${SELF_EDIT_ALLOW[@]}"; do
    if ! printf '%s\n' "$block" | grep -qF -- "\"$entry\""; then
      rc=1
    fi
  done
  line=$(grep -F -- 'Ensure `permissions.allow` contains' "$file" 2>/dev/null | head -n1)
  [ -n "$line" ] || return 1
  for entry in "${SELF_EDIT_ALLOW[@]}"; do
    if ! printf '%s\n' "$line" | grep -qF -- '`'"$entry"'`'; then
      rc=1
    fi
  done
  return "$rc"
}

if check_self_edit_entries "$SKILL"; then
  PASS=$((PASS + 1)); echo "  ok  template + merge line name every self-edit entry"
else
  FAIL=$((FAIL + 1)); echo "  FAIL template allow block or merge line missing a self-edit entry"
fi

TMP608=$(mktemp -d "${TMPDIR:-/tmp}/orch-allowlist-608.XXXXXX")
trap 'rm -rf "$TMP" "$TMP608"' EXIT
NO_CHANGELOG="$TMP608/SKILL-no-changelog.md"
sed '/^      "Edit(\/CHANGELOG\.md)",$/d' "$SKILL" > "$NO_CHANGELOG"

if check_self_edit_entries "$NO_CHANGELOG"; then
  FAIL=$((FAIL + 1)); echo "  FAIL bite check (AC A): copy without Edit(/CHANGELOG.md) should FAIL but passed"
else
  PASS=$((PASS + 1)); echo "  ok  bite check (AC A): copy without Edit(/CHANGELOG.md) reports FAIL"
fi

# Edit-scoped only: a Write(<path>) rule does not match (Claude Code permissions)
if printf '%s\n' "$TEMPLATE_ALLOW" | grep -qE '^Write\('; then
  FAIL=$((FAIL + 1)); echo "  FAIL template carries a Write(<path>) rule (does not match)"
else
  PASS=$((PASS + 1)); echo "  ok  template carries no Write(<path>) rule"
fi

# ---------- CDT-608 AC B: marker gating, idempotency, settings.local ----------
echo "-- CDT-608 marker gating + idempotency (AC B)"

MERGE=$(merge_section "$SKILL")
for needle in \
  '.claude-plugin/marketplace.json' \
  'unconditionally' \
  'idempotent' \
  '.claude/settings.local.json' \
  'never-managed'
do
  if printf '%s\n' "$MERGE" | grep -qF -- "$needle"; then
    PASS=$((PASS + 1)); echo "  ok  merge section holds [$needle]"
  else
    FAIL=$((FAIL + 1)); echo "  FAIL merge section missing [$needle]"
  fi
done

MERGE_FENCE=$(awk '/^# Merge the self-edit set/{grab=1} /^```$/ {if (grab) exit} grab {print}' "$SKILL")
if [ -n "$MERGE_FENCE" ]; then
  PASS=$((PASS + 1)); echo "  ok  merge fence is extractable"
else
  FAIL=$((FAIL + 1)); echo "  FAIL merge fence (self-edit set) not found"
fi

if command -v jq >/dev/null 2>&1 && [ -n "$MERGE_FENCE" ]; then
  run_merge_fence() { # run_merge_fence <dir> — runs the extracted fence in <dir>
    ( cd "$1" && printf '%s\n' "$MERGE_FENCE" | bash )
  }
  # Plugin-marker repo
  REPO608="$TMP608/plugin-repo"
  mkdir -p "$REPO608/.claude" "$REPO608/.claude-plugin"
  printf '%s\n' '{"name":"x"}' > "$REPO608/.claude-plugin/plugin.json"
  printf '%s\n' '{"name":"m"}' > "$REPO608/.claude-plugin/marketplace.json"
  printf '%s\n' '{"permissions":{"allow":["Bash(*)"],"defaultMode":"auto"}}' > "$REPO608/.claude/settings.json"
  run_merge_fence "$REPO608" >/dev/null 2>&1
  ALLOW1=$(jq -c '.permissions.allow' "$REPO608/.claude/settings.json" 2>/dev/null)
  for entry in "${SELF_EDIT_ALLOW[@]}"; do
    if printf '%s' "$ALLOW1" | grep -qF -- "$entry"; then
      PASS=$((PASS + 1)); echo "  ok  marker repo merged [$entry]"
    else
      FAIL=$((FAIL + 1)); echo "  FAIL marker repo missing [$entry]: $ALLOW1"
    fi
  done
  if printf '%s' "$ALLOW1" | grep -qF -- '"Bash(*)"'; then
    PASS=$((PASS + 1)); echo "  ok  merge preserved the existing allow entry"
  else
    FAIL=$((FAIL + 1)); echo "  FAIL merge dropped an existing allow entry: $ALLOW1"
  fi
  run_merge_fence "$REPO608" >/dev/null 2>&1
  ALLOW2=$(jq -c '.permissions.allow' "$REPO608/.claude/settings.json" 2>/dev/null)
  if [ "$ALLOW1" = "$ALLOW2" ]; then
    PASS=$((PASS + 1)); echo "  ok  merge is idempotent (second run adds nothing)"
  else
    FAIL=$((FAIL + 1)); echo "  FAIL merge not idempotent: $ALLOW1 -> $ALLOW2"
  fi
  # Non-plugin repo: version-file entries are not seeded, hooks entry is
  PLAIN608="$TMP608/plain-repo"
  mkdir -p "$PLAIN608/.claude"
  printf '%s\n' '{}' > "$PLAIN608/.claude/settings.json"
  run_merge_fence "$PLAIN608" >/dev/null 2>&1
  ALLOW3=$(jq -c '.permissions.allow' "$PLAIN608/.claude/settings.json" 2>/dev/null)
  if printf '%s' "$ALLOW3" | grep -qF -- 'Edit(/.claude/hooks/**)'; then
    PASS=$((PASS + 1)); echo "  ok  markerless repo still seeds the hooks entry"
  else
    FAIL=$((FAIL + 1)); echo "  FAIL markerless repo missing hooks entry: $ALLOW3"
  fi
  if printf '%s' "$ALLOW3" | grep -qF -- 'Edit(/CHANGELOG.md)'; then
    FAIL=$((FAIL + 1)); echo "  FAIL markerless repo seeded a version-file entry: $ALLOW3"
  else
    PASS=$((PASS + 1)); echo "  ok  markerless repo skips the version-file entries"
  fi
  # Bite check (AC B): a root-level marketplace.json alone is not a plugin marker —
  # both markers must sit under .claude-plugin/.
  ROOT608="$TMP608/root-marketplace-repo"
  mkdir -p "$ROOT608/.claude"
  printf '%s\n' '{"name":"m"}' > "$ROOT608/marketplace.json"
  printf '%s\n' '{}' > "$ROOT608/.claude/settings.json"
  run_merge_fence "$ROOT608" >/dev/null 2>&1
  ALLOW4=$(jq -c '.permissions.allow' "$ROOT608/.claude/settings.json" 2>/dev/null)
  if printf '%s' "$ALLOW4" | grep -qF -- 'Edit(/.claude/hooks/**)'; then
    PASS=$((PASS + 1)); echo "  ok  root-marketplace repo seeds the hooks entry"
  else
    FAIL=$((FAIL + 1)); echo "  FAIL root-marketplace repo missing hooks entry: $ALLOW4"
  fi
  if printf '%s' "$ALLOW4" | grep -qE -- 'Edit\(/CHANGELOG\.md\)|Edit\(/\.claude-plugin/plugin\.json\)'; then
    FAIL=$((FAIL + 1)); echo "  FAIL bite check (AC B): root-level marketplace.json alone seeded a version-file entry: $ALLOW4"
  else
    PASS=$((PASS + 1)); echo "  ok  bite check (AC B): root-level marketplace.json alone seeds no version-file entry"
  fi
  if [ -f "$REPO608/.claude/settings.local.json" ] || [ -f "$PLAIN608/.claude/settings.local.json" ] || [ -f "$ROOT608/.claude/settings.local.json" ]; then
    FAIL=$((FAIL + 1)); echo "  FAIL merge wrote .claude/settings.local.json"
  else
    PASS=$((PASS + 1)); echo "  ok  merge wrote no .claude/settings.local.json"
  fi
else
  echo "  skip  jq/self-edit fence unavailable — functional AC B checks skipped"
fi

# ---------- CDT-608 AC C: live self-edit probe ----------
echo "-- CDT-608 live self-edit probe (AC C)"

probe_section() {
  awk '/^#### Live self-edit probe \(CDT-608\)/ {grab=1; print; next}
       /^#### |^### / {if (grab) exit}
       grab {print}' "$1"
}

PROBE=$(probe_section "$SKILL")
if [ -n "$PROBE" ]; then
  PASS=$((PASS + 1)); echo "  ok  probe section exists"
else
  FAIL=$((FAIL + 1)); echo "  FAIL probe section 'Live self-edit probe (CDT-608)' missing"
fi
for needle in \
  'self-edit probe: pass (' \
  'self-edit probe: unverified (' \
  'byte-identical' \
  'skills/release/SKILL.md' \
  'Step 3e' \
  'verbatim' \
  'expected, not proven' \
  'non-fatal' \
  '.claude/settings.local.json' \
  '.claude-plugin/marketplace.json'
do
  if printf '%s\n' "$PROBE" | grep -qF -- "$needle"; then
    PASS=$((PASS + 1)); echo "  ok  probe section holds [$needle]"
  else
    FAIL=$((FAIL + 1)); echo "  FAIL probe section missing [$needle]"
  fi
done

# Functional AC C: the probe target loop is gated on the same plugin-marker
# condition as the merge fence, so unseeded scopes are skipped.
run_fence() { # run_fence <dir> <fence> — run <fence> inside <dir>
  ( cd "$1" && printf '%s\n' "$2" | bash )
}

PROBE_FENCE=$(awk '/^# Fresh shell \(skill-lint C1\)\. Targets stay inside/{grab=1}
                   /^```$/ {if (grab) exit}
                   grab {print}' "$SKILL")
if [ -n "$PROBE_FENCE" ] && command -v openssl >/dev/null 2>&1; then
  P608="$TMP608/probe-plugin"
  mkdir -p "$P608/.claude-plugin"
  printf '%s\n' '{"name":"x"}' > "$P608/.claude-plugin/plugin.json"
  printf '%s\n' '{"name":"m"}' > "$P608/.claude-plugin/marketplace.json"
  printf '%s\n' '# changelog' > "$P608/CHANGELOG.md"
  P_COUNT=$(run_fence "$P608" "$PROBE_FENCE" 2>/dev/null | grep -c '^probe-before:')
  if [ "$P_COUNT" = "3" ]; then
    PASS=$((PASS + 1)); echo "  ok  plugin repo probes all three scopes"
  else
    FAIL=$((FAIL + 1)); echo "  FAIL plugin repo probed $P_COUNT scopes, expected 3"
  fi
  # Bite check (AC C): no .claude-plugin/ markers → hooks scope only
  Q608="$TMP608/probe-plain"
  mkdir -p "$Q608/.claude"
  printf '%s\n' '{"name":"m"}' > "$Q608/marketplace.json"
  printf '%s\n' '# changelog' > "$Q608/CHANGELOG.md"
  Q_COUNT=$(run_fence "$Q608" "$PROBE_FENCE" 2>/dev/null | grep -c '^probe-before:')
  if [ "$Q_COUNT" = "1" ]; then
    PASS=$((PASS + 1)); echo "  ok  bite check (AC C): unmarked repo probes the hooks scope only"
  else
    FAIL=$((FAIL + 1)); echo "  FAIL bite check (AC C): unmarked repo probed $Q_COUNT scopes, expected 1"
  fi
else
  echo "  skip  openssl/probe fence unavailable — functional AC C checks skipped"
fi

NO_PROBE="$TMP608/SKILL-no-probe.md"
awk '/^#### Live self-edit probe \(CDT-608\)/ {skip=1}
     /^### / {if (skip && $0 !~ /Live self-edit probe/) skip=0}
     skip {next} {print}' "$SKILL" > "$NO_PROBE"
if [ -n "$(probe_section "$NO_PROBE")" ]; then
  FAIL=$((FAIL + 1)); echo "  FAIL bite check (AC C): copy without the probe section should FAIL but passed"
else
  PASS=$((PASS + 1)); echo "  ok  bite check (AC C): copy without the probe section reports FAIL"
fi

echo "=== results: PASS=$PASS FAIL=$FAIL ==="
if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
exit 0
