#!/usr/bin/env bash
# theme-status.sh — SPEC-029 reopen detector (best-effort, fail-open)
# Usage:
#   theme-status.sh derive "bug description words..."
#   theme-status.sh status <theme-key> [project-root]
#   theme-status.sh append <theme-key> [project-root]          # JSON line on stdin
#   theme-status.sh append <theme-key> <project-root> --       # JSON line on stdin (explicit)
#   theme-status.sh append <theme-key> <project-root> '<json>' # JSON line as argv
#   theme-status.sh force-check <theme-key> "<desc>" [project-root]
#   theme-status.sh count-prior <theme-key> [project-root]  # prints integer only
set -euo pipefail

STOP='^(a|an|the|to|of|in|on|for|and|or|is|not|does|do|with|from|when|while|this|that|it|my|i|we|you|as|be|by|at|so|if|bug|issue|broken|still|fix|the|after)$'

derive_theme() {
  local desc="$*"
  local key
  # pipefail-safe: empty grep must not kill the script
  key=$(set +o pipefail
    echo "$desc" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9' ' ' | tr -s ' ' '\n' \
      | grep -E '^[a-z0-9]{3,}$' | grep -Ev "$STOP" | head -6 | paste -sd'-' - || true
  )
  if [[ -z "${key//-/}" ]]; then
    # All-stopword / empty: stable non-empty key (never empty .jsonl name)
    key="unthemed"
  fi
  printf '%s\n' "$key"
}

theme_dir() {
  local root="${1:-.}"
  echo "$root/.claude/debug/themes"
}

# Count PRIOR debug runs as distinct calendar days (SPEC-029 MUST).
# Sources: theme jsonl (ts fields) + history fallback (session-days with /debug).
count_prior_days() {
  local key="$1"
  local root="${2:-.}"
  local dir log
  dir=$(theme_dir "$root")
  log="$dir/${key}.jsonl"
  local hist="${HOME}/.claude/history.jsonl"

  python3 - "$log" "$hist" "$root" "$key" <<'PY' 2>/dev/null || echo 0
import json, sys, time
from datetime import datetime, timezone
from pathlib import Path

log_path, hist_path, root, key = sys.argv[1:5]
tokens = [t for t in key.split("-") if t]
now = time.time()
cutoff = now - 14 * 86400
days = set()

def day_of(ts):
    if ts is None:
        return None
    try:
        ts = float(ts)
    except (TypeError, ValueError):
        return None
    if ts > 1e12:
        ts /= 1000.0
    if ts < cutoff:
        return None
    return datetime.fromtimestamp(ts, tz=timezone.utc).strftime("%Y-%m-%d")

# Theme log: one day per entry that is not a pure override-only noise;
# count all outcomes except explicit "override" without a debug run? count all.
p = Path(log_path)
if p.is_file():
    for line in p.open(errors="replace"):
        line = line.strip()
        if not line:
            continue
        try:
            o = json.loads(line)
        except json.JSONDecodeError:
            # legacy bare lines → treat as one unknown day bucket
            days.add("log-undated")
            continue
        d = day_of(o.get("ts"))
        if d:
            days.add(d)

# History: distinct days with /debug matching theme tokens
hp = Path(hist_path)
if hp.is_file() and tokens:
    root_n = root.rstrip("/")
    for line in hp.open(errors="replace"):
        try:
            o = json.loads(line)
        except json.JSONDecodeError:
            continue
        pth = (o.get("project") or "").rstrip("/")
        if root_n not in pth and pth not in root_n:
            continue
        d = day_of(o.get("timestamp"))
        if not d:
            continue
        text = (o.get("display") or "").lower()
        if "/debug" not in text and "dev-team:debug" not in text:
            continue
        hits = sum(1 for t in tokens if t in text)
        if hits >= min(2, len(tokens)):
            days.add(d)

print(len(days))
PY
}

status() {
  local key="$1"
  local root="${2:-.}"
  # empty/invalid key hard-fail soft
  if [[ -z "$key" || "$key" == *"/"* ]]; then
    key="unthemed"
  fi
  local prior
  prior=$(count_prior_days "$key" "$root")
  prior=${prior//[^0-9]/}
  prior=${prior:-0}
  local force=no
  # ≥2 prior *days* → third calendar day forces redesign
  if [[ "$prior" -ge 2 ]]; then force=yes; fi
  echo "Theme: $key"
  echo "Prior debug days (14d): $prior"
  echo "Forced redesign: $force"
  echo "THEME_KEY=$key"
  echo "REOPEN_COUNT=$prior"
  echo "FORCED_REDESIGN=$force"
}

append() {
  # Usage:
  #   append <key> [root]           → JSON line from stdin
  #   append <key> <root> --        → JSON line from stdin
  #   append <key> <root> '<json>'  → JSON line from argv (one record)
  local key="$1"
  local root="${2:-.}"
  shift 2 || true
  local dir
  dir=$(theme_dir "$root")
  mkdir -p "$dir"
  if [[ -z "$key" ]]; then key="unthemed"; fi
  local log="$dir/${key}.jsonl"
  if [[ $# -eq 0 ]] || [[ "${1:-}" == "--" ]]; then
    cat >>"$log"
  else
    # Single JSON object/line as remaining args joined (usually one arg)
    printf '%s\n' "$*" >>"$log"
  fi
}

force_check() {
  local key="$1"
  local desc="$2"
  local root="${3:-.}"
  local out
  out=$(status "$key" "$root")
  local dl force_reason=""
  dl=$(echo "$desc" | tr '[:upper:]' '[:lower:]')
  # Prefer multi-word isolation phrases first to reduce false positives
  for sig in "no isolation" "missing isolation" "wrong abstraction" \
    "same fix everywhere" "every backend" "all three backends" \
    "state machine" "architecture" "redesign"; do
    if [[ "$dl" == *"$sig"* ]]; then
      force_reason="isolation-keyword:$sig"
      break
    fi
  done
  if [[ -n "$force_reason" ]]; then
    echo "$out" | sed 's/^Forced redesign: no$/Forced redesign: yes/;s/^FORCED_REDESIGN=no$/FORCED_REDESIGN=yes/'
    echo "FORCE_REASON=$force_reason"
  else
    echo "$out"
  fi
}

cmd="${1:-}"
shift || true
case "$cmd" in
  derive) derive_theme "$*" ;;
  status) status "${1:-unthemed}" "${2:-.}" ;;
  count-prior) count_prior_days "${1:-unthemed}" "${2:-.}" ;;
  # Do NOT pass an empty $3 — that used to force echo "" and drop stdin (C1-class).
  append)
    if [[ $# -ge 3 ]]; then
      append "${1:?theme}" "${2:-.}" "$3"
    else
      append "${1:?theme}" "${2:-.}"
    fi
    ;;
  force-check) force_check "${1:?theme}" "${2:-}" "${3:-.}" ;;
  *)
    echo "Usage: $0 derive|status|count-prior|append|force-check ..." >&2
    exit 2
    ;;
esac
