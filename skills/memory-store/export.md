# /memory export

Protocol for `/memory export` (SPEC-024). Thin command host: `commands/memory.md`.
Engine: `export-seed-pack.sh` in this directory.

Write a sanitized, provenance-tagged seed pack from distilled **tier-2/core** memories
(or fallback cortex/lessons highlights) to `.claude/memory/seed/`. The pack is for
human PR review and commit — this command **never** git-adds, commits, or pushes.

## Arguments

- `/memory export` — export all 7 behavioral agents (default cap 40 entries/agent)
- `/memory export --agent <name>` — one agent only (`pm|tech-lead|ic5|ic4|devops|qa|ds`)
- `/memory export --limit N` — override per-agent entry cap
- `/memory export --dry-run` — print what would be written (including exclusions) without writing

## Step 1: Export seed pack

```bash
_gc=$(git rev-parse --git-common-dir 2>/dev/null) \
  && MROOT=$(cd "$(dirname "$_gc")" && pwd) \
  || MROOT=$(pwd)
# lint-ok: C3 — marketplace */ for-loop + -f guarded (SPEC-021 Q2 residual, CDT-82 PDH)
PDH=$( { [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -f "$CLAUDE_PLUGIN_ROOT/skills/plugin-dir.sh" ] && printf '%s\n' "$CLAUDE_PLUGIN_ROOT"; } || { [ -f skills/plugin-dir.sh ] && pwd; } || { _pr='${CLAUDE_PLUGIN_ROOT}'; [ -f "$_pr/skills/plugin-dir.sh" ] && printf '%s\n' "$_pr"; } || { for _mp in "$HOME"/.claude/plugins/marketplaces/*/; do [ -f "${_mp}skills/plugin-dir.sh" ] && [ -f "${_mp}agents/pm.md" ] && printf '%s\n' "${_mp%/}" && break; done; } || find ~/.claude/plugins/cache -path '*/dev-team/*/skills/plugin-dir.sh' 2>/dev/null | awk -F/ '{ver=""; for(i=1;i<=NF;i++) if($i=="dev-team"&&i<NF){ver=$(i+1);break}; if(ver=="") next; m=ver; gsub(/-pre\./,"~pre.",m); p=($0 ~ /\/cache\/cold-dark-void\/dev-team\//)?1:0; print m "\t" p "\t" $0}' | sort -t $'\t' -k1,1V -k2,2n -k3,3 | tail -1 | cut -f3 | xargs -r dirname | xargs -r dirname )
EXPORT_SH=$(bash "$PDH/skills/plugin-dir.sh" file skills/memory-store/export-seed-pack.sh)
if [ -z "$EXPORT_SH" ] || [ ! -f "$EXPORT_SH" ]; then
  echo "ERROR: could not resolve export-seed-pack.sh"
  exit 1
fi
# Pass through user flags from $ARGUMENTS (agent may substitute parsed flags)
bash "$EXPORT_SH" $ARGUMENTS "$MROOT"
```

## After export

1. Skim `.claude/memory/seed/*.md` for residual secrets/paths (sanitization is a floor).
2. Commit via a **reviewed PR** — do not push unreviewed packs.
3. On a fresh clone, `/setup team` imports the pack before project-init (warm start).

See SPEC-024 for layout, sanitization rules, and import semantics.

---
