#!/usr/bin/env bash
# SPEC-030 R22: static hygiene gate for .github/workflows/smoke.yml.
#
# check_workflow FILE prints one "FAIL: <rule>: <detail>" line per violation:
#   G1 — top-level `permissions: contents: read`, no job-level permissions,
#        no `write` anywhere in the file.
#   G2 — every job under `jobs:` sets timeout-minutes (all-tests=20,
#        macos=20, rest=10).
#   G3 — every `uses:` line pins a full 40-hex SHA with a `# vX.Y.Z` comment.
#   B4 — the bump-class job has fetch-depth: 0, uses check-bump-class.sh
#        with --range, and never --commit HEAD.
#   B5 — the all-tests job has fetch-depth: 0 (suites read pinned base commits).
#   B6 — the fence-exec job runs `bash tools/fence-exec/run.sh` (CDT-272).
#   B7 — the spec-lint job runs `bash tools/spec-lint.sh` (CDT-273).
#   B8 — the macos job is a required gate: macos-latest, no
#        continue-on-error, and `bash tools/run-all-tests.sh --portable
#        --platform macos` (CDT-502, SPEC-030 R32/R34).
#   B9 — the hook-templates job runs check-hook-templates.sh (CDT-502).
#
# Bash + grep/awk only. Hermetic: no writes outside mktemp.
set -u

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$HERE/.." && pwd)

# shellcheck source=../tests/lib/hermetic.sh
. "$REPO_ROOT/tests/lib/hermetic.sh"
hermetic_init

FAIL_COUNT=0

# check_workflow FILE — prints FAIL lines for every violation found in FILE.
check_workflow() {
  local file="$1"
  local -a job_ids=()

  # --- G1: top-level permissions: contents: read; no job-level permissions;
  #     no "write" anywhere. ---
  if ! awk '
    /^permissions:$/ { p=1; next }
    p && /^[a-z]/ { p=0 }
    p && /^[[:space:]]+contents:[[:space:]]*read[[:space:]]*$/ { found=1 }
    END { exit !found }
  ' "$file"; then
    echo "FAIL: G1: no top-level permissions: contents: read block"
  fi

  if grep -nE '^[[:space:]]{4}permissions:' "$file" >/dev/null; then
    grep -nE '^[[:space:]]{4}permissions:' "$file" | while IFS=: read -r lineno _; do
      echo "FAIL: G1: job-level permissions: block at line $lineno"
    done
  fi

  if grep -niE 'write' "$file" >/dev/null; then
    grep -niE 'write' "$file" | while IFS=: read -r lineno rest; do
      echo "FAIL: G1: 'write' found at line $lineno: $rest"
    done
  fi

  # --- job ids, in file order, under jobs: (2-space-indented key ending
  #     in ':' immediately under jobs:) ---
  while IFS= read -r id; do
    job_ids+=("$id")
  done < <(awk '
    /^jobs:$/ { in_jobs=1; next }
    in_jobs && /^[^[:space:]]/ { in_jobs=0 }
    in_jobs && /^[[:space:]]{2}[A-Za-z0-9_-]+:[[:space:]]*$/ {
      line=$0
      sub(/^[[:space:]]{2}/, "", line)
      sub(/:[[:space:]]*$/, "", line)
      print line
    }
  ' "$file")

  # --- G2: every job has timeout-minutes; all-tests=20, macos=20, others=10. ---
  local i
  for ((i = 0; i < ${#job_ids[@]}; i++)); do
    local id="${job_ids[$i]}"
    local next_id="${job_ids[$((i + 1))]:-}"
    local block
    if [ -n "$next_id" ]; then
      block=$(awk -v id="  $id:" -v nid="  $next_id:" '
        $0 == id { on=1; next }
        on && $0 == nid { exit }
        on { print }
      ' "$file")
    else
      block=$(awk -v id="  $id:" '
        $0 == id { on=1; next }
        on { print }
      ' "$file")
    fi
    local tm
    tm=$(printf '%s\n' "$block" | grep -oE 'timeout-minutes:[[:space:]]*[0-9]+' | head -1 | grep -oE '[0-9]+$')
    if [ -z "$tm" ]; then
      echo "FAIL: G2: job '$id' has no timeout-minutes"
      continue
    fi
    if [ "$id" = "all-tests" ] || [ "$id" = "macos" ]; then
      if [ "$tm" != "20" ]; then
        echo "FAIL: G2: job '$id' timeout-minutes is $tm, want 20"
      fi
    else
      if [ "$tm" != "10" ]; then
        echo "FAIL: G2: job '$id' timeout-minutes is $tm, want 10"
      fi
    fi
  done

  # --- G3: every uses: line pins a 40-hex SHA + "# vX.Y.Z" comment. ---
  grep -nE '^[[:space:]]*-[[:space:]]*uses:' "$file" | while IFS=: read -r lineno rest; do
    if ! printf '%s\n' "$rest" | grep -qE 'uses:[[:space:]]*[^@[:space:]]+@[0-9a-f]{40}[[:space:]]+# v[0-9]+\.[0-9]+\.[0-9]+[[:space:]]*$'; then
      echo "FAIL: G3: unpinned or malformed uses: at line $lineno: $rest"
    fi
  done

  # --- B4: bump-class job has fetch-depth: 0, --range, no --commit HEAD. ---
  local bc_block
  bc_block=$(awk '
    /^  bump-class:$/ { on=1; next }
    on && /^  [A-Za-z0-9_-]+:$/ { exit }
    on { print }
  ' "$file")
  if [ -z "$bc_block" ]; then
    echo "FAIL: B4: no bump-class job found"
  else
    if ! printf '%s\n' "$bc_block" | grep -qE 'fetch-depth:[[:space:]]*0[[:space:]]*$'; then
      echo "FAIL: B4: bump-class job missing fetch-depth: 0"
    fi
    if ! printf '%s\n' "$bc_block" | grep -qE 'check-bump-class.sh.*--range'; then
      echo "FAIL: B4: bump-class job missing check-bump-class.sh --range"
    fi
    if printf '%s\n' "$bc_block" | grep -qE -- '--commit[[:space:]]+HEAD'; then
      echo "FAIL: B4: bump-class job still uses --commit HEAD"
    fi
  fi

  # --- B5: all-tests job has fetch-depth: 0 (suites read pinned base commits). ---
  local at_block
  at_block=$(awk '
    /^  all-tests:$/ { on=1; next }
    on && /^  [A-Za-z0-9_-]+:$/ { exit }
    on { print }
  ' "$file")
  if [ -z "$at_block" ]; then
    echo "FAIL: B5: no all-tests job found"
  elif ! printf '%s\n' "$at_block" | grep -qE 'fetch-depth:[[:space:]]*0([[:space:]]|$)'; then
    echo "FAIL: B5: all-tests job missing fetch-depth: 0"
  fi

  # --- B6: the fence-exec job runs the harness (CDT-272). ---
  local fe_block
  fe_block=$(awk '
    /^  fence-exec:$/ { on=1; next }
    on && /^  [A-Za-z0-9_-]+:$/ { exit }
    on { print }
  ' "$file")
  if [ -z "$fe_block" ]; then
    echo "FAIL: B6: no fence-exec job found"
  elif ! printf '%s\n' "$fe_block" | grep -qE 'run:[[:space:]]*bash tools/fence-exec/run\.sh[[:space:]]*$'; then
    echo "FAIL: B6: fence-exec job does not run bash tools/fence-exec/run.sh"
  fi

  # --- B7: the spec-lint job runs the spec gate (CDT-273). ---
  local sl_block
  sl_block=$(awk '
    /^  spec-lint:$/ { on=1; next }
    on && /^  [A-Za-z0-9_-]+:$/ { exit }
    on { print }
  ' "$file")
  if [ -z "$sl_block" ]; then
    echo "FAIL: B7: no spec-lint job found"
  elif ! printf '%s\n' "$sl_block" | grep -qE 'run:[[:space:]]*bash tools/spec-lint\.sh[[:space:]]*$'; then
    echo "FAIL: B7: spec-lint job does not run bash tools/spec-lint.sh"
  fi

  # --- B8: required macOS gate (CDT-502, SPEC-030 R32/R34). ---
  local mac_block
  mac_block=$(awk '
    /^  macos:$/ { on=1; next }
    on && /^  [A-Za-z0-9_-]+:$/ { exit }
    on { print }
  ' "$file")
  if [ -z "$mac_block" ]; then
    echo "FAIL: B8: no macos job found"
  elif ! printf '%s\n' "$mac_block" | grep -qE 'runs-on:[[:space:]]*macos-latest[[:space:]]*$'; then
    echo "FAIL: B8: macos job does not run on macos-latest"
  elif printf '%s\n' "$mac_block" | grep -qE '^[[:space:]]*continue-on-error:'; then
    echo "FAIL: B8: macos job is continue-on-error (required gate per CDT-502)"
  elif ! printf '%s\n' "$mac_block" | grep -qE 'run:[[:space:]]*bash tools/run-all-tests\.sh --portable --platform macos[[:space:]]*$'; then
    echo "FAIL: B8: macos job does not run bash tools/run-all-tests.sh --portable --platform macos"
  fi

  # --- B9: the hook-templates job runs the template gate (CDT-502). ---
  local ht_block
  ht_block=$(awk '
    /^  hook-templates:$/ { on=1; next }
    on && /^  [A-Za-z0-9_-]+:$/ { exit }
    on { print }
  ' "$file")
  if [ -z "$ht_block" ]; then
    echo "FAIL: B9: no hook-templates job found"
  elif ! printf '%s\n' "$ht_block" | grep -qE 'run:[[:space:]]*bash skills/init-orchestration/check-hook-templates\.sh[[:space:]]*$'; then
    echo "FAIL: B9: hook-templates job does not run bash skills/init-orchestration/check-hook-templates.sh"
  fi
}

run_check() { # run_check LABEL FILE — runs check_workflow, counts FAILs.
  local label="$1" file="$2"
  local out
  out=$(check_workflow "$file")
  if [ -n "$out" ]; then
    printf '%s\n' "$out" | while IFS= read -r line; do
      echo "$label: $line"
    done
    local n
    n=$(printf '%s\n' "$out" | grep -c '^FAIL:')
    FAIL_COUNT=$((FAIL_COUNT + n))
    return 1
  fi
  return 0
}

LIVE="$REPO_ROOT/.github/workflows/smoke.yml"

# --- Live check: the real workflow must be clean. ---
if run_check "live" "$LIVE"; then
  echo "OK: live smoke.yml has no G1/G2/G3/B4/B5/B6/B7/B8/B9 violations"
else
  echo "FAIL: live smoke.yml has violations (see above)"
fi

# --- Bite tests: each mutation must produce >=1 FAIL naming its rule. ---
WORK="$HERMETIC_ROOT/work"
mkdir -p "$WORK"

bite() { # bite LABEL SED_SCRIPT EXPECT_RULE
  local label="$1" sed_script="$2" expect_rule="$3"
  local f="$WORK/$label.yml"
  sed -E "$sed_script" "$LIVE" > "$f"
  local out
  out=$(check_workflow "$f")
  if printf '%s\n' "$out" | grep -q "FAIL: $expect_rule:"; then
    echo "OK: bite $label triggers $expect_rule"
  else
    echo "FAIL: bite-harness: $label did not trigger $expect_rule"
    FAIL_COUNT=$((FAIL_COUNT + 1))
  fi
}

# Drop the top-level permissions block.
bite "no-permissions" '/^permissions:$/,/^$/d' "G1"

# Drop one timeout-minutes line (the first job's). POSIX `1,/re/` — the GNU
# `0,/re/` first-match address is rejected by BSD sed (CDT-502-C4 AC4).
bite "no-timeout" '1,/timeout-minutes:/{/timeout-minutes:/d;}' "G2"

# Macos timeout regression 20→10 must FAIL G2 (macos gates at 20 like all-tests).
# POSIX form: the macos-block range negate-branches non-range lines, matching the
# all-tests-shallow shape (identical on GNU and BSD sed).
bite "macos-timeout-10" '/^  macos:$/,/^$/!b
s/timeout-minutes: 20/timeout-minutes: 10/' "G2"

# Revert one checkout to a moving major tag.
bite "moving-tag" 's/actions\/checkout@[0-9a-f]{40} # v[0-9.]+/actions\/checkout@v4/' "G3"

# SHA pin present but missing the version comment.
bite "no-comment" 's/(actions\/checkout@[0-9a-f]{40}) # v[0-9.]+/\1/' "G3"

# Restore --commit HEAD in the bump-class job.
bite "commit-head" 's/check-bump-class\.sh --range "\$RANGE"/check-bump-class.sh --commit HEAD/' "B4"

# Drop fetch-depth from the all-tests job (shallow clone breaks pinned-commit reads).
# POSIX form: a top-level negated `anchor,$!b` keeps pre-anchor fetch-depth
# lines, identical on GNU and BSD sed (CDT-502-C4 AC4).
bite "all-tests-shallow" '/^  all-tests:$/,$!b
/fetch-depth:/d' "B5"

# Drop the fence-exec job (the harness would stop running in CI).
bite "no-fence-exec" '/^  fence-exec:$/,/^$/d' "B6"

# Point the fence-exec job at another command.
bite "fence-exec-wrong-command" 's#bash tools/fence-exec/run\.sh#bash tools/smoke/run.sh#' "B6"

# Drop the spec-lint job.
bite "no-spec-lint" '/^  spec-lint:$/,/^$/d' "B7"

# Point the spec-lint job at another command.
bite "spec-lint-wrong-command" 's#bash tools/spec-lint\.sh#bash tools/smoke/run.sh#' "B7"

# Drop the macos job.
bite "no-macos" '/^  macos:$/,/^$/d' "B8"

# Restore the informational skip: continue-on-error present must FAIL B8.
bite "macos-continue-on-error" 's/^    runs-on: macos-latest$/&\
    continue-on-error: true/' "B8"

# Point the macOS lane at an ubuntu runner.
bite "macos-runner" 's/^    runs-on: macos-latest$/    runs-on: ubuntu-latest/' "B8"

# Run the suite without --portable --platform macos.
bite "macos-full" 's#bash tools/run-all-tests\.sh --portable#bash tools/run-all-tests.sh#' "B8"

# Drop the hook-templates job (the gate would stop running in CI).
bite "no-hook-templates" '/^  hook-templates:$/,/^$/d' "B9"

# Point the hook-templates job at another command.
bite "hook-templates-wrong-command" 's#bash skills/init-orchestration/check-hook-templates\.sh#bash tools/smoke/run.sh#' "B9"

if [ "$FAIL_COUNT" -eq 0 ]; then
  echo "PASS: ci-workflow-test"
  exit 0
else
  echo "FAIL: ci-workflow-test ($FAIL_COUNT failure(s))"
  exit 1
fi
