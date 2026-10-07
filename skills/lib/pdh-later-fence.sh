# pdh-later-fence.sh — the SECOND canonical PDH text (SPEC-002 § Caller
# integration, CDT-502-C5): the one line every LATER fence of a caller file
# expands, replacing the retired carry-line form.
#
# Who extracts this file:
#   - skills/skill-lint/lint.py (C5, second emission class): the single
#     `PDH="${PDH:-…}"` line below is the byte SoT every later-fence carrier
#     is compared against (leading whitespace aside).
#   - skills/plugin-dir-test.sh (CDT-508 regression): executes this file's
#     text with `printf '%s' "$PDH"` appended.
#   - the CDT-502 T2 rewrite: expands it into every later fence.
#
# Edit HERE, then re-run the rewrite — never hand-edit a carrier. The line's
# command-substitution body is byte-identical to SPEC-002's canonical
# first-fence stanza body (the CDT-508 tier-3 fix is applied to both texts
# together). No stderr printf: later fences do not announce. POSIX and
# bash-3.2-parseable; macOS evidence is CI-only (SPEC-030 R32).
#
# C8 note: the wrapper trips C8(d)'s ${X:-{}} heuristic as a bash-verified
# false positive — the { opens a brace group inside the $( … ) in the default,
# so the expansion does NOT end at that } (bash -n + the CDT-508 suite prove
# it). The single-line waiver below must stay immediately above the PDH line:
# SPEC-021 apply_waivers reads only the finding line and the one above it.
# lint-ok: C3,C8 — marketplace */ for-loop + -f guarded (SPEC-021 Q2 residual, CDT-82 PDH); C8(d) on this wrapper is a bash-verified false positive ({ opens a brace group inside the $( … ) in the default)
PDH="${PDH:-$( { [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -f "$CLAUDE_PLUGIN_ROOT/skills/plugin-dir.sh" ] && printf '%s\n' "$CLAUDE_PLUGIN_ROOT"; } || { [ -f skills/plugin-dir.sh ] && [ -f agents/pm.md ] && grep -qF '"name": "dev-team"' .claude-plugin/plugin.json 2>/dev/null && pwd; } || { _pr='${CLAUDE_PLUGIN_ROOT}'; [ "${_pr#\$}" = "$_pr" ] && [ -f "$_pr/skills/plugin-dir.sh" ] && printf '%s\n' "$_pr"; } || { for _mp in "$HOME"/.claude/plugins/marketplaces/*/; do [ -f "${_mp}skills/plugin-dir.sh" ] && [ -f "${_mp}agents/pm.md" ] && printf '%s\n' "${_mp%/}" && break; done; } || find ~/.claude/plugins/cache \( -path '*/dev-team/*/skills/plugin-dir.sh' -o -path '*/dev-team-edge/*/skills/plugin-dir.sh' \) 2>/dev/null | awk -F/ '{ver=""; for(i=1;i<=NF;i++) if(($i=="dev-team"||$i=="dev-team-edge")&&i<NF){ver=$(i+1);break}; if(ver=="") next; m=ver; gsub(/-pre\./,"~pre.",m); p=($0 ~ /\/cache\/cold-dark-void\/dev-team\//)?2:(($0 ~ /\/cache\/cold-dark-void\/dev-team-edge\//)?1:0); print m "\t" p "\t" $0}' | sort -t $'\t' -k1,1V -k2,2n -k3,3 | tail -1 | cut -f3 | xargs -r dirname | xargs -r dirname )}"
