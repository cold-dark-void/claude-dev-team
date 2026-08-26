---
name: compact-transcript
description: >
  Bounded Meaning-channel file (Meaning tail) for the operator to @.
  Not a host /compact replacement.
argument-hint: "[<sid>]"
---

# /compact-transcript

Thin entry over `skills/transcript-mirror/compact-transcript.sh` (SPEC-036 M14).

This Surface writes a bounded Meaning-channel file (Meaning tail).
Stdout is the absolute path of that file.
You `@` the printed path.
This Surface does not truncate store `main.md`.
This Surface is not a host `/compact` replacement.
The Meaning tail is **not** an STM packet and **not** a compact seed — those terms stay with `/handoff`.

The recorder is not a slash Surface.
`/compact-transcript` is the consumer Surface.

## Arguments

| Args | Action |
|------|--------|
| _(none)_ | Use the live session id (`discover-warm.sh` line 1) |
| `<sid>` | Use that sid as given |

Miss is fail-closed. The Surface does not create or update a tail.

## Step 1: Resolve compact-transcript.sh

```bash
# lint-ok: C3 — marketplace */ for-loop + -f guarded (SPEC-021 Q2 residual, CDT-82 PDH)
PDH=$( { [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -f "$CLAUDE_PLUGIN_ROOT/skills/plugin-dir.sh" ] && printf '%s\n' "$CLAUDE_PLUGIN_ROOT"; } || { [ -f skills/plugin-dir.sh ] && pwd; } || { for _mp in "$HOME"/.claude/plugins/marketplaces/*/; do [ -f "${_mp}skills/plugin-dir.sh" ] && [ -f "${_mp}agents/pm.md" ] && printf '%s\n' "${_mp%/}" && break; done; } || find ~/.claude/plugins/cache -path '*/dev-team/*/skills/plugin-dir.sh' 2>/dev/null | awk -F/ '{ver=""; for(i=1;i<=NF;i++) if($i=="dev-team"&&i<NF){ver=$(i+1);break}; if(ver=="") next; m=ver; gsub(/-pre\./,"~pre.",m); p=($0 ~ /\/cache\/cold-dark-void\/dev-team\//)?1:0; print m "\t" p "\t" $0}' | sort -t $'\t' -k1,1V -k2,2n -k3,3 | tail -1 | cut -f3 | xargs -r dirname | xargs -r dirname )
COMPACT_SH=$(bash "$PDH/skills/plugin-dir.sh" file skills/transcript-mirror/compact-transcript.sh)

if [ -z "$COMPACT_SH" ] || [ ! -f "$COMPACT_SH" ]; then
  echo "error: skills/transcript-mirror/compact-transcript.sh not found in the installed plugin" >&2
  exit 1
fi
```

## Step 2: Invoke (pass-through)

```bash
# lint-ok: C3 — marketplace */ for-loop + -f guarded (SPEC-021 Q2 residual, CDT-82 PDH)
PDH=$( { [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -f "$CLAUDE_PLUGIN_ROOT/skills/plugin-dir.sh" ] && printf '%s\n' "$CLAUDE_PLUGIN_ROOT"; } || { [ -f skills/plugin-dir.sh ] && pwd; } || { for _mp in "$HOME"/.claude/plugins/marketplaces/*/; do [ -f "${_mp}skills/plugin-dir.sh" ] && [ -f "${_mp}agents/pm.md" ] && printf '%s\n' "${_mp%/}" && break; done; } || find ~/.claude/plugins/cache -path '*/dev-team/*/skills/plugin-dir.sh' 2>/dev/null | awk -F/ '{ver=""; for(i=1;i<=NF;i++) if($i=="dev-team"&&i<NF){ver=$(i+1);break}; if(ver=="") next; m=ver; gsub(/-pre\./,"~pre.",m); p=($0 ~ /\/cache\/cold-dark-void\/dev-team\//)?1:0; print m "\t" p "\t" $0}' | sort -t $'\t' -k1,1V -k2,2n -k3,3 | tail -1 | cut -f3 | xargs -r dirname | xargs -r dirname )
COMPACT_SH=$(bash "$PDH/skills/plugin-dir.sh" file skills/transcript-mirror/compact-transcript.sh)
bash "$COMPACT_SH" "$@"
```

## Step 3: Present output

Print the script stdout as-is. That line is the Meaning tail path.
You `@` that path.

## See also

- `/handoff` — STM packet / Compact seed (separate Surface)
- Transcript mirror — `docs/commands/transcript-mirror.md`
- Protocol: `skills/transcript-mirror/SKILL.md`
- Spec: `specs/core/SPEC-036-transcript-mirror.md` M14
