#!/usr/bin/env bash
# transcript-sync.sh — catch-up CLI (SPEC-036 M10–M11).
# Fail-open: always exit 0. Python helper does locate + freshness + recorder.
set -u

# Locate the dev-team plugin root (PDH). Optional CLAUDE_PLUGIN_ROOT (force path / FR #48230), else cwd dev/worktree, else marketplace clone (slug-free agents/pm.md), else installed cache (rank by /dev-team/<VER>/ segment, not full path; CDT-166). CDT-82: marketplace before same-version cache.
# lint-ok: C3 — marketplace */ for-loop + -f guarded (SPEC-021 Q2 residual, CDT-82 PDH)
PDH=$( { [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -f "$CLAUDE_PLUGIN_ROOT/skills/plugin-dir.sh" ] && printf '%s\n' "$CLAUDE_PLUGIN_ROOT"; } || { [ -f skills/plugin-dir.sh ] && pwd; } || { for _mp in "$HOME"/.claude/plugins/marketplaces/*/; do [ -f "${_mp}skills/plugin-dir.sh" ] && [ -f "${_mp}agents/pm.md" ] && printf '%s\n' "${_mp%/}" && break; done; } || find ~/.claude/plugins/cache -path '*/dev-team/*/skills/plugin-dir.sh' 2>/dev/null | awk -F/ '{ver=""; for(i=1;i<=NF;i++) if($i=="dev-team"&&i<NF){ver=$(i+1);break}; if(ver=="") next; m=ver; gsub(/-pre\./,"~pre.",m); p=($0 ~ /\/cache\/cold-dark-void\/dev-team\//)?1:0; print m "\t" p "\t" $0}' | sort -t $'\t' -k1,1V -k2,2n -k3,3 | tail -1 | cut -f3 | xargs -r dirname | xargs -r dirname )

if [ -z "${PDH:-}" ] || [ ! -f "$PDH/skills/plugin-dir.sh" ]; then
  echo "transcript-sync: dev-team plugin not found — skipping" >&2
  exit 0
fi

SYNC_PY=$(bash "$PDH/skills/plugin-dir.sh" file skills/transcript-mirror/transcript-sync.py 2>/dev/null) || SYNC_PY=""
if [ -z "$SYNC_PY" ] || [ ! -f "$SYNC_PY" ]; then
  echo "transcript-sync: transcript-sync.py not found — skipping" >&2
  exit 0
fi

if ! command -v python3 >/dev/null 2>&1; then
  echo "transcript-sync: python3 not found — skipping" >&2
  exit 0
fi

python3 "$SYNC_PY" "$@" || true
exit 0
