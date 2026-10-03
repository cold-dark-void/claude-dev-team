#!/usr/bin/env bash
# Optional host SAST feed for council security / review-and-commit.
# Fail-open: missing tools → exit 0 with a SKIP line (never blocks the caller).
# Usage: scan.sh [PATH...]   (default: git diff paths vs merge-base, or .)
set -euo pipefail

# Callers skip the script when SECURITY_SCAN=0. Honor it here too, before any
# temp directory or scanner runs, so a direct invocation sends nothing.
if [ "${SECURITY_SCAN:-}" = "0" ]; then
  echo "SECURITY-SCAN: SKIP (SECURITY_SCAN=0)"
  exit 0
fi

# Private output directory: mktemp -d (mode 700, random name). A name built
# from $$ is predictable (CWE-377). SECURITY_SCAN_OUT overrides it.
OUT_DIR="${SECURITY_SCAN_OUT:-}"
if [ -z "$OUT_DIR" ]; then
  OUT_DIR=$(mktemp -d "${TMPDIR:-/tmp}/dev-team-security-scan.XXXXXX" 2>/dev/null) || {
    echo "SECURITY-SCAN: SKIP — cannot create a temp directory (fail-open)"
    exit 0
  }
fi
mkdir -p "$OUT_DIR"
SUMMARY="$OUT_DIR/summary.txt"
: >"$SUMMARY"

have() { command -v "$1" >/dev/null 2>&1; }

# Resolve targets from the repo root. Paths are root-relative, so a scan
# started in a subdirectory still names the files git sees.
HERE=$(cd "$(dirname "$0")" && pwd)
CHANGED="$HERE/../lib/changed-set.sh"
unset GIT_DIR GIT_WORK_TREE
WTROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
cd "$WTROOT"
if [ "$#" -gt 0 ]; then
  TARGETS=("$@")
else
  # bash 3.2: no mapfile (CDT-285) — read one path per line.
  TARGETS=()
  while IFS= read -r _scan_t; do
    TARGETS+=("$_scan_t")
  done < <("${BASH:-/bin/bash}" "$CHANGED" -C "$WTROOT" paths)
  if [ "${#TARGETS[@]}" -eq 0 ] || [ -z "${TARGETS[0]:-}" ]; then
    TARGETS=(".")
  fi
fi

# Cap target list for CLI args
MAX_TARGETS=40
TARGETS_TOTAL="${#TARGETS[@]}"
if [ "$TARGETS_TOTAL" -gt "$MAX_TARGETS" ]; then
  TARGETS=("${TARGETS[@]:0:$MAX_TARGETS}")
  # Never cut the list in silence: the summary says how much was not scanned.
  echo "TRUNCATED $MAX_TARGETS/$TARGETS_TOTAL" >>"$SUMMARY"
  echo "TARGETS: truncated to the first $MAX_TARGETS of $TARGETS_TOTAL (CLI argument cap) — the rest were not scanned" >>"$SUMMARY"
fi

RAN=0

# --- Semgrep ---
if have semgrep; then
  RAN=1
  SEM_OUT="$OUT_DIR/semgrep.txt"
  # Prefer SARIF when supported; fall back to text
  sem_rc=0
  if semgrep --help 2>&1 | grep -q -- '--sarif'; then
    SEM_SARIF="$OUT_DIR/semgrep.sarif"
    semgrep --config=auto --quiet --sarif -o "$SEM_SARIF" "${TARGETS[@]}" 2>"$OUT_DIR/semgrep.err" || sem_rc=$?
    if [ "$sem_rc" -eq 0 ]; then
      echo "SEMGREP: wrote $SEM_SARIF" >>"$SUMMARY"
    elif [ -s "$SEM_SARIF" ]; then
      echo "SEMGREP: findings in $SEM_SARIF (exit $sem_rc)" >>"$SUMMARY"
    else
      echo "SEMGREP: FAILED (exit $sem_rc)" >>"$SUMMARY"
    fi
  else
    semgrep --config=auto --quiet "${TARGETS[@]}" >"$SEM_OUT" 2>"$OUT_DIR/semgrep.err" || sem_rc=$?
    if [ "$sem_rc" -eq 0 ] || [ -s "$SEM_OUT" ]; then
      echo "SEMGREP: text $SEM_OUT (exit $sem_rc)" >>"$SUMMARY"
    else
      echo "SEMGREP: FAILED (exit $sem_rc)" >>"$SUMMARY"
    fi
  fi
else
  echo "SEMGREP: SKIP (semgrep not on PATH)" >>"$SUMMARY"
fi

# --- CodeQL (if database already exists — never create DBs here) ---
if have codeql; then
  # Only run if user pointed at a DB or a conventional path exists
  # Only an explicit CODEQL_DB_PATH. Do not reuse a stale database found on disk.
  CODEQL_DB="${CODEQL_DB_PATH:-}"
  if [ -n "${CODEQL_DB:-}" ] && [ -d "$CODEQL_DB" ]; then
    RAN=1
    CQ_OUT="$OUT_DIR/codeql.sarif"
    if codeql database analyze "$CODEQL_DB" --format=sarif-latest --output="$CQ_OUT" 2>"$OUT_DIR/codeql.err"; then
      echo "CODEQL: wrote $CQ_OUT" >>"$SUMMARY"
    else
      echo "CODEQL: analyze failed (see $OUT_DIR/codeql.err) — fail-open" >>"$SUMMARY"
    fi
  else
    echo "CODEQL: SKIP (no CODEQL_DB_PATH / codeql-db; install+create DB separately)" >>"$SUMMARY"
  fi
else
  echo "CODEQL: SKIP (codeql not on PATH or CODEQL_DB_PATH unset)" >>"$SUMMARY"
fi

# Optional secret scan. Missing binary is a skip, never a failure.
if have gitleaks; then
  RAN=1
  gl_rc=0
  gitleaks detect --no-git --redact -s "$WTROOT" >"$OUT_DIR/gitleaks.txt" 2>"$OUT_DIR/gitleaks.err" || gl_rc=$?
  if [ "$gl_rc" -eq 0 ]; then
    echo "GITLEAKS: clean" >>"$SUMMARY"
  else
    echo "GITLEAKS: FAILED (exit $gl_rc)" >>"$SUMMARY"
  fi
else
  echo "GITLEAKS: SKIP (gitleaks not on PATH)" >>"$SUMMARY"
fi

if [ "$RAN" -eq 0 ]; then
  echo "SECURITY-SCAN: SKIP — no host SAST tools available (optional: install semgrep and/or codeql)" >>"$SUMMARY"
fi

echo "OUT_DIR=$OUT_DIR" >>"$SUMMARY"
cat "$SUMMARY"
# SECURITY_SCAN_CLEAN=1 removes the private temp dir after the summary is
# printed. A caller-supplied SECURITY_SCAN_OUT is never removed.
if [ "${SECURITY_SCAN_CLEAN:-}" = "1" ] && [ -z "${SECURITY_SCAN_OUT:-}" ]; then
  rm -rf "$OUT_DIR"
fi
# Always success — fail-open for orchestrators
exit 0
