---
name: audit
description: >
  Context audit of the instruction stack (CLAUDE.md, AGENTS.md, directives)
  plus skill-size WARN. Bare is read-only. Apply is approve-then-apply on
  instruction-stack files only.
argument-hint: "[apply <id|batch> | --from-session <id>] [--json] [--judgment] [--yes]"
---

# /audit

Thin entry over `skills/audit/SKILL.md` (SPEC-035). Mechanical CLI:
`bash skills/audit/audit.sh`.

**Read-only by default.** Inventory walks the instruction stack (user-global
`~/.claude/CLAUDE.md` + parent → project `AGENTS.md`/`CLAUDE.md` + directives)
and WARNs on `SKILL.md` files over 30KB. Dual-host: Claude + Grok (same
walk-up; Grok also `~/.grok/AGENTS.md` and `~/.claude/CLAUDE.md`).

`/doctor` stays install/config health — use this Surface for stack hygiene.

## Arguments

| Args | Action |
|------|--------|
| _(none)_ | Read-only inventory + skill-size WARN |
| `--json` | JSON document on stdout |
| `apply <id\|batch> --from-json FILE` | Approve-then-apply; instruction-stack files only |
| `--judgment` | Allow class=judgment in apply |
| `--yes` | Extra confirm for writes under `~/.claude` or `~/.grok` |
| `--from-session <id>` | Locate via `skills/transcript-parse` only, then inventory |
| `-h` / `--help` | Usage |

Apply rejects findings without mechanical evidence (two cited passages, counts,
and mtime/tag or spec quote). Apply MUST NOT rewrite `skills/**` or
`commands/**`.

## Step 1: Resolve audit.sh

```bash
# lint-ok: C3 — marketplace */ for-loop + -f guarded (SPEC-021 Q2 residual, CDT-82 PDH)
PDH=$( { [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -f "$CLAUDE_PLUGIN_ROOT/skills/plugin-dir.sh" ] && printf '%s\n' "$CLAUDE_PLUGIN_ROOT"; } || { [ -f skills/plugin-dir.sh ] && pwd; } || { for _mp in "$HOME"/.claude/plugins/marketplaces/*/; do [ -f "${_mp}skills/plugin-dir.sh" ] && [ -f "${_mp}agents/pm.md" ] && printf '%s\n' "${_mp%/}" && break; done; } || find ~/.claude/plugins/cache -path '*/dev-team/*/skills/plugin-dir.sh' 2>/dev/null | awk -F/ '{ver=""; for(i=1;i<=NF;i++) if($i=="dev-team"&&i<NF){ver=$(i+1);break}; if(ver=="") next; m=ver; gsub(/-pre\./,"~pre.",m); p=($0 ~ /\/cache\/cold-dark-void\/dev-team\//)?1:0; print m "\t" p "\t" $0}' | sort -t $'\t' -k1,1V -k2,2n -k3,3 | tail -1 | cut -f3 | xargs -r dirname | xargs -r dirname )
AUDIT_SH=$(bash "$PDH/skills/plugin-dir.sh" file skills/audit/audit.sh)

if [ -z "$AUDIT_SH" ] || [ ! -f "$AUDIT_SH" ]; then
  echo "error: skills/audit/audit.sh not found in the installed plugin" >&2
  exit 1
fi
```

## Step 2: Invoke (pass-through flags)

```bash
# lint-ok: C3 — marketplace */ for-loop + -f guarded (SPEC-021 Q2 residual, CDT-82 PDH)
PDH=$( { [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -f "$CLAUDE_PLUGIN_ROOT/skills/plugin-dir.sh" ] && printf '%s\n' "$CLAUDE_PLUGIN_ROOT"; } || { [ -f skills/plugin-dir.sh ] && pwd; } || { for _mp in "$HOME"/.claude/plugins/marketplaces/*/; do [ -f "${_mp}skills/plugin-dir.sh" ] && [ -f "${_mp}agents/pm.md" ] && printf '%s\n' "${_mp%/}" && break; done; } || find ~/.claude/plugins/cache -path '*/dev-team/*/skills/plugin-dir.sh' 2>/dev/null | awk -F/ '{ver=""; for(i=1;i<=NF;i++) if($i=="dev-team"&&i<NF){ver=$(i+1);break}; if(ver=="") next; m=ver; gsub(/-pre\./,"~pre.",m); p=($0 ~ /\/cache\/cold-dark-void\/dev-team\//)?1:0; print m "\t" p "\t" $0}' | sort -t $'\t' -k1,1V -k2,2n -k3,3 | tail -1 | cut -f3 | xargs -r dirname | xargs -r dirname )
AUDIT_SH=$(bash "$PDH/skills/plugin-dir.sh" file skills/audit/audit.sh)
bash "$AUDIT_SH" "$@"
```

## Step 3: Present output

Print the script's stdout as-is. Do not rewrite skill or command files from
this Surface. Protocol: `skills/audit/SKILL.md`.
