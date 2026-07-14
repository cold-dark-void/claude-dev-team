#!/usr/bin/env bash
# seed-common.sh — shared helpers for memory seed pack export/import (SPEC-024).
# Source only (never execute as a CLI):
#   SCRIPT_DIR=...; # shellcheck source=seed-common.sh
#   . "$SCRIPT_DIR/seed-common.sh"
#
# Functions:
#   seed_agents
#   seed_normalize_content <text>
#   seed_content_hash <text>          # 12-char sha256 of normalized content (no trailer)
#   seed_trailer project date tier agent hash
#   seed_parse_trailer <line>         # exports SEED_*; rc=1 on failure
#   seed_sanitize_entry <text> <project_root>
#   ensure_seed_gitignore <project_root>
#   seed_file_sha256 <path>           # full sha256 hex of file contents
#   seed_strip_trailer <text>         # content without trailing [seed: …] line

set -u

seed_agents() {
  printf '%s\n' "pm tech-lead ic5 ic4 devops qa ds"
}

# Normalize: strip CR, rstrip each line, drop trailing blank lines, single trailing NL.
seed_normalize_content() {
  local text="${1-}"
  printf '%s' "$text" | python3 -c '
import sys
text = sys.stdin.read().replace("\r\n", "\n").replace("\r", "\n")
lines = [ln.rstrip() for ln in text.split("\n")]
while lines and lines[-1] == "":
    lines.pop()
sys.stdout.write("\n".join(lines) + "\n")
'
}

# 12-char sha256 hex of normalized content (caller passes text WITHOUT trailer).
seed_content_hash() {
  local normalized
  normalized=$(seed_normalize_content "${1-}")
  printf '%s' "$normalized" | sha256sum | awk '{print substr($1,1,12)}'
}

seed_trailer() {
  local project="$1" date="$2" tier="$3" agent="$4" hash="$5"
  printf '[seed: project=%s date=%s tier=%s agent=%s hash=%s]' \
    "$project" "$date" "$tier" "$agent" "$hash"
}

# Parse a trailer line; exports SEED_PROJECT SEED_DATE SEED_TIER SEED_AGENT SEED_HASH.
seed_parse_trailer() {
  local line="$1"
  # Trim surrounding whitespace
  line="${line#"${line%%[![:space:]]*}"}"
  line="${line%"${line##*[![:space:]]}"}"
  if [[ "$line" =~ ^\[seed:\ project=([^[:space:]]+)\ date=([0-9]{4}-[0-9]{2}-[0-9]{2})\ tier=([0-9]+)\ agent=([^[:space:]]+)\ hash=([a-f0-9]{12})\]$ ]]; then
    SEED_PROJECT="${BASH_REMATCH[1]}"
    SEED_DATE="${BASH_REMATCH[2]}"
    SEED_TIER="${BASH_REMATCH[3]}"
    SEED_AGENT="${BASH_REMATCH[4]}"
    SEED_HASH="${BASH_REMATCH[5]}"
    return 0
  fi
  return 1
}

# Strip a trailing [seed: …] line (and blank lines before it) from normalized content.
seed_strip_trailer() {
  local text="${1-}"
  printf '%s' "$text" | python3 -c '
import sys, re
text = sys.stdin.read()
lines = text.split("\n")
# drop trailing empties
while lines and lines[-1] == "":
    lines.pop()
if lines and re.match(r"^\[seed:\s", lines[-1]):
    lines.pop()
while lines and lines[-1] == "":
    lines.pop()
sys.stdout.write("\n".join(lines) + ("\n" if lines else ""))
'
}

# Full-file sha256 hex (for manifest content_hash).
seed_file_sha256() {
  local path="$1"
  sha256sum "$path" | awk '{print $1}'
}

# Sanitize one entry. On success: rewritten text on stdout, rc=0.
# On failure: reason on stderr, rc=1. Deny-by-default (SPEC-024 M2).
seed_sanitize_entry() {
  local text="${1-}"
  local project_root="${2-}"
  if [ -z "$project_root" ] || [ ! -d "$project_root" ]; then
    echo "invalid project_root" >&2
    return 1
  fi
  project_root=$(cd "$project_root" && pwd)

  local result errf
  errf=$(mktemp "${TMPDIR:-/tmp}/seed-sanitize.XXXXXX")
  if result=$(PROJECT_ROOT="$project_root" python3 -c '
import os, re, sys

text = sys.stdin.read()
root = os.environ["PROJECT_ROOT"].rstrip("/")

def rewrite_paths(s: str) -> str:
    # root/foo/bar → foo/bar (repo-relative, no leading slash)
    esc = re.escape(root)
    s = re.sub(esc + r"/", "", s)
    # bare root token → .
    s = re.sub(r"(?<![\w.-])" + esc + r"(?![\w.-/])", ".", s)
    return s

text = rewrite_paths(text)
reasons = []

abs_re = re.compile(
    r"(?<![\w])(/(?:home|Users|var|tmp|opt|usr|etc|private|root|mnt|data)(?:/[\w./+@~-]*)?|/[a-zA-Z0-9._-]+(?:/[a-zA-Z0-9._+-]+)+)"
)
for m in abs_re.finditer(text):
    frag = m.group(0)
    if frag.startswith("//"):
        continue
    reasons.append(f"absolute path: {frag[:80]}")
    break

if re.search(r"(?<![\w])~(?:/[\w./+-]*)?", text):
    reasons.append("home-directory path (~)")

if re.search(r"\b[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}\b", text):
    reasons.append("email address")

if re.search(r"\b[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\b", text):
    reasons.append("UUID")

if re.search(r"[a-zA-Z][a-zA-Z0-9+.-]*://[^/\s]*:[^/\s]*@", text):
    reasons.append("credentialed URL")

secret_pats = [
    (r"\bAKIA[0-9A-Z]{16}\b", "AWS access key"),
    (r"\bASIA[0-9A-Z]{16}\b", "AWS temp key"),
    (r"\bsk-[A-Za-z0-9]{20,}\b", "API key (sk-)"),
    (r"\bghp_[A-Za-z0-9]{20,}\b", "GitHub token"),
    (r"\bgithub_pat_[A-Za-z0-9_]{20,}\b", "GitHub PAT"),
    (r"\bxox[baprs]-[A-Za-z0-9-]{10,}\b", "Slack token"),
    (r"(?i)\bBearer\s+[A-Za-z0-9\-._~+/]+=*\b", "Bearer token"),
    (r"(?i)(api[_-]?key|secret[_-]?key|access[_-]?token|private[_-]?key)\s*[:=]\s*\S+", "secret assignment"),
    (r"-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----", "private key block"),
]
for pat, label in secret_pats:
    if re.search(pat, text):
        reasons.append(label)
        break

if re.search(r"(?i)\b(?:hostname|host)\s*[:=]\s*[A-Za-z0-9.-]+\b", text):
    reasons.append("hostname")
elif re.search(r"\b(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.){2,}[a-z]{2,}\b", text):
    m = re.search(r"\b(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.){2,}[a-z]{2,}\b", text)
    if m:
        host = m.group(0).lower()
        allow = {
            "example.com", "example.org", "localhost.localdomain",
            "github.com", "raw.githubusercontent.com", "api.github.com",
            "pypi.org", "registry.npmjs.org", "crates.io",
        }
        parts = host.split(".")
        tail2 = ".".join(parts[-2:]) if len(parts) >= 2 else host
        if host not in allow and tail2 not in allow:
            reasons.append(f"hostname: {host}")

if reasons:
    sys.stderr.write(reasons[0] + "\n")
    sys.exit(1)

sys.stdout.write(text)
sys.exit(0)
' <<<"$text" 2>"$errf"); then
    rm -f "$errf"
    printf '%s' "$result"
    return 0
  else
    cat "$errf" >&2
    rm -f "$errf"
    return 1
  fi
}

# Make .claude/memory/seed/ committable (SPEC-024 M9).
# - Replace bare `.claude/memory/` with `.claude/memory/*`
# - Ensure seed negations exist
# - Preserve other memory ignore lines
ensure_seed_gitignore() {
  local root="${1:-.}"
  local gi="$root/.gitignore"
  local tmp
  tmp=$(mktemp "${TMPDIR:-/tmp}/seed-gitignore.XXXXXX")

  if [ -f "$gi" ]; then
    # Replace bare directory excludes with child-glob form
    sed -E \
      -e 's|^[[:space:]]*\.claude/memory/[[:space:]]*$|.claude/memory/*|' \
      -e 's|^[[:space:]]*\.claude/memory[[:space:]]*$|.claude/memory/*|' \
      "$gi" > "$tmp"
  else
    : > "$tmp"
  fi

  if ! grep -qE '^[[:space:]]*\.claude/memory/\*[[:space:]]*$' "$tmp"; then
    printf '%s\n' '.claude/memory/*' >> "$tmp"
  fi

  # Ensure seed negations immediately after .claude/memory/*
  if ! grep -qE '^[[:space:]]*!\.claude/memory/seed/[[:space:]]*$' "$tmp"; then
    local tmp2
    tmp2=$(mktemp "${TMPDIR:-/tmp}/seed-gitignore2.XXXXXX")
    awk '
      { print }
      /^[[:space:]]*\.claude\/memory\/\*[[:space:]]*$/ && !done {
        print "!.claude/memory/seed/"
        print "!.claude/memory/seed/**"
        done=1
      }
      END {
        if (!done) {
          print "!.claude/memory/seed/"
          print "!.claude/memory/seed/**"
        }
      }
    ' "$tmp" > "$tmp2"
    mv "$tmp2" "$tmp"
  elif ! grep -qE '^[[:space:]]*!\.claude/memory/seed/\*\*[[:space:]]*$' "$tmp"; then
    printf '%s\n' '!.claude/memory/seed/**' >> "$tmp"
  fi

  if [ -f "$gi" ] && cmp -s "$tmp" "$gi"; then
    rm -f "$tmp"
  else
    mv "$tmp" "$gi"
  fi

  # Verify seed is not ignored by the *repo* gitignore (ignore global excludesFile —
  # users may have ~/.gitignore with .claude/ which is outside this feature's control).
  if git -C "$root" rev-parse --git-dir >/dev/null 2>&1; then
    mkdir -p "$root/.claude/memory/seed"
    # check-ignore -q: 0=ignored, 1=not ignored. Do NOT use -v (negation patterns
    # match and flip exit status). Disable global excludes for this probe.
    if git -C "$root" -c core.excludesFile=/dev/null check-ignore -q -- .claude/memory/seed/probe.md 2>/dev/null; then
      echo "WARNING: ensure_seed_gitignore: seed still ignored by git — check .gitignore order" >&2
      return 1
    fi
  fi
  return 0
}
