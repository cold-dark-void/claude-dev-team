<!--
  Canonical "load another agent's tiered cortex" fragment — SINGLE SOURCE OF TRUTH.

  This is the ONE authoritative copy of the Step-0 "read agent <AGENT>'s tiered
  cortex" block shared verbatim by the /debug and /refactor skills. It is expanded
  inline into each consumer's Step-0 context-load section between
  `<!-- include: skills/agent-memory/cortex-load.md agent=X -->` / `<!-- /include -->`
  markers (with `<AGENT>` substituted for X). `/release` Step 4.5 drift-checks that
  every marked region equals this file expanded, so the copies can never drift again.

  Markers are placed OUTSIDE the ```bash fence (this partial CARRIES the fence) — the
  P1-5A leak-safe pattern. Self-contained path/USE_DB resolution (SPEC-021 C1 — each
  fence is a separate shell).

  Scope note (AUDIT-P2.7b): the byte-identical pair is /debug and /refactor only, both
  loading agent='tech-lead'. The six other skills that carry a tiered-cortex query
  (kickoff, wrap-ticket, orchestrate, brainstorm, memory-recall, memory-store) load a
  DIFFERENT agent and/or use a different indentation / line-wrapping, so they are NOT
  byte-identical to this region and are deliberately NOT consumers of this partial.
  The ONLY per-consumer substitution is `<AGENT>`.
-->
**b. Tech Lead cortex (tiered memory)**

```bash
_gc=$(git rev-parse --git-common-dir 2>/dev/null) \
  && MROOT=$(cd "$(dirname "$_gc")" && pwd) \
  || MROOT=$(pwd)
MEMDB="$MROOT/.claude/memory/memory.db"
USE_DB=false
if [ -f "$MEMDB" ] && command -v sqlite3 &>/dev/null; then
  USE_DB=true
fi
if [ "$USE_DB" = "true" ]; then
  # type and content. Non-archived tier-0 stays visible beside tier 1 and 2.
  # .timeout 5000 was already on the previous query (cortex-load.md:34). The
  # ${HAS_DISTILLED:-0} default was already present and left with that branch.
  # lint-ok: C3 — marketplace */ for-loop + -f guarded (SPEC-021 Q2 residual, CDT-82 PDH)
  PDH=$( { [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -f "$CLAUDE_PLUGIN_ROOT/skills/plugin-dir.sh" ] && printf '%s\n' "$CLAUDE_PLUGIN_ROOT"; } || { [ -f skills/plugin-dir.sh ] && [ -f agents/pm.md ] && grep -qF '"name": "dev-team"' .claude-plugin/plugin.json 2>/dev/null && pwd; } || { _pr='${CLAUDE_PLUGIN_ROOT}'; [ "${_pr#\$}" = "$_pr" ] && [ -f "$_pr/skills/plugin-dir.sh" ] && printf '%s\n' "$_pr"; } || { for _mp in "$HOME"/.claude/plugins/marketplaces/*/; do [ -f "${_mp}skills/plugin-dir.sh" ] && [ -f "${_mp}agents/pm.md" ] && printf '%s\n' "${_mp%/}" && break; done; } || find ~/.claude/plugins/cache \( -path '*/dev-team/*/skills/plugin-dir.sh' -o -path '*/dev-team-edge/*/skills/plugin-dir.sh' \) 2>/dev/null | awk -F/ '{ver=""; for(i=1;i<=NF;i++) if(($i=="dev-team"||$i=="dev-team-edge")&&i<NF){ver=$(i+1);break}; if(ver=="") next; m=ver; gsub(/-pre\./,"~pre.",m); p=($0 ~ /\/cache\/cold-dark-void\/dev-team\//)?2:(($0 ~ /\/cache\/cold-dark-void\/dev-team-edge\//)?1:0); print m "\t" p "\t" $0}' | sort -t $'\t' -k1,1V -k2,2n -k3,3 | tail -1 | cut -f3 | xargs -r dirname | xargs -r dirname )
  MEMDB_SH=$(bash "$PDH/skills/plugin-dir.sh" file skills/memory-store/memdb.sh 2>/dev/null || true)
  if [ -n "$MEMDB_SH" ] && [ -f "$MEMDB_SH" ]; then
    bash "$MEMDB_SH" load-session "$MEMDB" "<AGENT>"
  else
    sqlite3 -cmd ".timeout 5000" "$MEMDB" "SELECT type, content FROM memories WHERE agent='<AGENT>' AND archived=FALSE ORDER BY tier DESC, type, updated_at DESC;"
  fi
else
  cat "$MROOT/.claude/memory/<AGENT>/cortex.md" 2>/dev/null
fi
```
