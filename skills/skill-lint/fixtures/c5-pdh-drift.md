# C5 fixture (SPEC-021): PDH bootstrap-stanza drift.

Block 1 mutates `sort -V` to a bare `sort` — the real historical defect (bare
`sort` ranks pre-releases above finals). The `# lint-ok: C3` waiver above it is
genuine (the marketplace `*/` for-loop is `-f` guarded) and MUST NOT suppress C5.

```bash
# lint-ok: C3 — marketplace */ for-loop + -f guarded; must not suppress C5
PDH=$( { [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -f "$CLAUDE_PLUGIN_ROOT/skills/plugin-dir.sh" ] && printf '%s\n' "$CLAUDE_PLUGIN_ROOT"; } || { [ -f skills/plugin-dir.sh ] && pwd; } || { for _mp in "$HOME"/.claude/plugins/marketplaces/*/; do [ -f "${_mp}skills/plugin-dir.sh" ] && [ -f "${_mp}agents/pm.md" ] && printf '%s\n' "${_mp%/}" && break; done; } || find ~/.claude/plugins/cache -path '*/dev-team/*/skills/plugin-dir.sh' 2>/dev/null | sed 's/-pre\./~pre./' | sort | tail -1 | sed 's/~pre\./-pre./' | xargs -r dirname | xargs -r dirname )
```

Block 2 carries the same drift with an explicit C5 waiver — counted, never silent.

```bash
# lint-ok: C3,C5 — deliberate drift, waived
PDH=$( { [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -f "$CLAUDE_PLUGIN_ROOT/skills/plugin-dir.sh" ] && printf '%s\n' "$CLAUDE_PLUGIN_ROOT"; } || { [ -f skills/plugin-dir.sh ] && pwd; } || { for _mp in "$HOME"/.claude/plugins/marketplaces/*/; do [ -f "${_mp}skills/plugin-dir.sh" ] && [ -f "${_mp}agents/pm.md" ] && printf '%s\n' "${_mp%/}" && break; done; } || find ~/.claude/plugins/cache -path '*/dev-team/*/skills/plugin-dir.sh' 2>/dev/null | sed 's/-pre\./~pre./' | sort | tail -1 | sed 's/~pre\./-pre./' | xargs -r dirname | xargs -r dirname )
```
