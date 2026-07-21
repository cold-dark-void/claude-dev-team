#!/usr/bin/env bash
# Optional host SAST feed for council security / review-and-commit.
# Fail-open: missing tools → exit 0 with a SKIP line (never blocks the caller).
# Usage: scan.sh [PATH...]   (default: git diff paths vs merge-base, or .)
set -euo pipefail

OUT_DIR="${SECURITY_SCAN_OUT:-${TMPDIR:-/tmp}/dev-team-security-scan-$$}"
mkdir -p "$OUT_DIR"
SUMMARY="$OUT_DIR/summary.txt"
: >"$SUMMARY"

have() { command -v "$1" >/dev/null 2>&1; }

# Resolve targets
if [ "$#" -gt 0 ]; then
  TARGETS=("$@")
else
  WTROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
  BASE=$(git -C "$WTROOT" merge-base HEAD origin/main 2>/dev/null \
    || git -C "$WTROOT" merge-base HEAD origin/master 2>/dev/null \
    || git -C "$WTROOT" merge-base HEAD main 2>/dev/null \
    || git -C "$WTROOT" merge-base HEAD master 2>/dev/null \
    || true)
  mapfile -t TARGETS < <(
    if [ -n "${BASE:-}" ]; then
      git -C "$WTROOT" diff --name-only --diff-filter=ACMR "$BASE"...HEAD 2>/dev/null || true
      git -C "$WTROOT" diff --name-only --diff-filter=ACMR 2>/dev/null || true
    else
      echo "."
    fi
  )
  # Dedup empty
  if [ "${#TARGETS[@]}" -eq 0 ] || [ -z "${TARGETS[0]:-}" ]; then
    TARGETS=(".")
  fi
fi

# Cap target list for CLI args
MAX_TARGETS=40
if [ "${#TARGETS[@]}" -gt "$MAX_TARGETS" ]; then
  TARGETS=("${TARGETS[@]:0:$MAX_TARGETS}")
fi

RAN=0

# --- Semgrep ---
if have semgrep; then
  RAN=1
  SEM_OUT="$OUT_DIR/semgrep.txt"
  # Prefer SARIF when supported; fall back to text
  if semgrep --help 2>&1 | grep -q -- '--sarif'; then
    SEM_SARIF="$OUT_DIR/semgrep.sarif"
    if semgrep --config=auto --quiet --sarif -o "$SEM_SARIF" "${TARGETS[@]}" 2>"$OUT_DIR/semgrep.err"; then
      echo "SEMGREP: wrote $SEM_SARIF" >>"$SUMMARY"
    else
      # Non-zero often means findings; still keep output if present
      if [ -s "$SEM_SARIF" ]; then
        echo "SEMGREP: findings in $SEM_SARIF (exit non-zero)" >>"$SUMMARY"
      else
        # Retry text mode
        semgrep --config=auto --quiet "${TARGETS[@]}" >"$SEM_OUT" 2>"$OUT_DIR/semgrep.err" || true
        echo "SEMGREP: text $SEM_OUT" >>"$SUMMARY"
      fi
    fi
  else
    semgrep --config=auto --quiet "${TARGETS[@]}" >"$SEM_OUT" 2>"$OUT_DIR/semgrep.err" || true
    echo "SEMGREP: text $SEM_OUT" >>"$SUMMARY"
  fi
else
  echo "SEMGREP: SKIP (semgrep not on PATH)" >>"$SUMMARY"
fi

# --- CodeQL (if database already exists — never create DBs here) ---
if have codeql; then
  # Only run if user pointed at a DB or a conventional path exists
  CODEQL_DB="${CODEQL_DB_PATH:-}"
  if [ -z "$CODEQL_DB" ]; then
    for cand in codeql-db .codeql/db "${WTROOT:-.}/codeql-db"; do
      [ -d "$cand" ] && CODEQL_DB="$cand" && break
    done
  fi
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
  echo "CODEQL: SKIP (codeql not on PATH)" >>"$SUMMARY"
fi

if [ "$RAN" -eq 0 ]; then
  echo "SECURITY-SCAN: SKIP — no host SAST tools available (optional: install semgrep and/or codeql)" >>"$SUMMARY"
fi

echo "OUT_DIR=$OUT_DIR" >>"$SUMMARY"
cat "$SUMMARY"
# Always success — fail-open for orchestrators
exit 0
