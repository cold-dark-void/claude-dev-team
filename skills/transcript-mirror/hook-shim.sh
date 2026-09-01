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
  PDH=$(pwd)  # lint-ok: C5 (hook-runtime bootstrap, not the caller-site stanza; byte-identity waiver only — does not exempt this site from the CDT-166 version-segment ranking rule)
else
  _pdh_hit=$(find "${HOME:-}/.claude/plugins/cache" \
    -path '*/dev-team/*/skills/plugin-dir.sh' 2>/dev/null \
    | awk -F/ '
        {
          ver = ""
          for (i = 1; i <= NF; i++)
            if ($i == "dev-team" && i < NF) { ver = $(i + 1); break }
          if (ver == "") next
          m = ver
          gsub(/-pre\./, "~pre.", m)
          p = ($0 ~ "/cache/cold-dark-void/dev-team/") ? 1 : 0
          print m "\t" p "\t" $0
        }
      ' | sort -t $'\t' -k1,1V -k2,2n -k3,3 | tail -1 | cut -f3) || _pdh_hit=""
  if [ -n "$_pdh_hit" ]; then
    # lint-ok: C5 (hook-runtime bootstrap, not the caller-site stanza; byte-identity waiver only — does not exempt this site from the CDT-166 version-segment ranking rule)
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
