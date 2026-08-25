#!/usr/bin/env bash
# transcript-mirror hook shim (SPEC-036 M3).
# Copy this file to .claude/hooks/transcript-mirror.sh in the project.
# Settings command MUST NOT contain pipes:
#   bash "${CLAUDE_PROJECT_DIR}/.claude/hooks/transcript-mirror.sh"
#
# PDH lookup lives here (precompact-rescue pattern). Fail-open: always exit 0.
# Stdin (hook JSON) is drained through to the plugin recorder.
set -u

drain() { cat >/dev/null 2>/dev/null || true; }

# Resolve plugin root (PDH) — hook-runtime bootstrap, not the caller-site stanza.
# Two tiers only: (a) PDH=$(pwd) when skills/plugin-dir.sh exists in cwd (dev
# checkout), else (b) highest-version match under the installed plugin cache.
PDH=""
if [ -f skills/plugin-dir.sh ]; then
  PDH=$(pwd)  # lint-ok: C5 (hook-runtime bootstrap, not the caller-site stanza)
else
  _pdh_hit=$(find "${HOME:-}/.claude/plugins/cache" \
    -path '*/dev-team/*/skills/plugin-dir.sh' 2>/dev/null \
    | sed 's/-pre\./~pre./' | sort -V | tail -1 | sed 's/~pre\./-pre./') || _pdh_hit=""
  if [ -n "$_pdh_hit" ]; then
    # lint-ok: C5 (hook-runtime bootstrap, not the caller-site stanza)
    PDH=$(CDPATH= cd -- "$(dirname -- "$_pdh_hit")/.." && pwd) || PDH=""
  fi
fi

if [ -z "$PDH" ] || [ ! -f "$PDH/skills/plugin-dir.sh" ]; then
  echo "transcript-mirror: dev-team plugin not found — skipping" >&2
  drain
  exit 0
fi

REC=$(bash "$PDH/skills/plugin-dir.sh" file skills/transcript-mirror/transcript-mirror.sh 2>/dev/null) || REC=""
if [ -z "$REC" ] || [ ! -f "$REC" ]; then
  echo "transcript-mirror: transcript-mirror.sh not found — skipping" >&2
  drain
  exit 0
fi

bash "$REC" || true
exit 0
