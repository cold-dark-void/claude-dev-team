---
name: release-train
description: |
    Multi-branch release queue (SPEC-023). Register ready branches, list/drop
    queue entries, dry-run the frozen plan, or start the landing loop that
    merge-squashes each branch onto master and drives /release with an explicit
    assigned version. Sequencer only — never reimplements /release.
argument-hint: "register <branch> | list | drop <branch> | start | dry-run | status"
---

# /release-train

Thin entrypoint for the release-train skill. Full protocol:
`skills/release-train/SKILL.md`. Mechanical CLI: resolve `train-lib.sh` via
`plugin-dir.sh`, then `bash "$TRAIN_LIB" <cmd> …` (subprocess only).

## Args

| Args | Action |
|------|--------|
| `register <branch> [--bump minor\|patch] [--assumed V]` | Queue a branch (manual only) |
| `list` / `status` | Show queue JSON / human summary |
| `drop <branch>` | Remove a **pending** entry |
| `dry-run` | Print order + slot versions; zero mutation |
| `start` | Freeze (if needed), lock, land each entry via skill loop |

## Routing

1. Resolve plugin/skill paths; prefer cwd repo root (`git rev-parse --show-toplevel`).
2. Ensure queue dir: resolve TRAIN_LIB (below) then `bash "$TRAIN_LIB" init`
3. Dispatch:

```bash
# lint-ok: C3 — marketplace */ for-loop + -f guarded (SPEC-021 Q2 residual, CDT-82 PDH)
PDH=$( { [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -f "$CLAUDE_PLUGIN_ROOT/skills/plugin-dir.sh" ] && printf '%s\n' "$CLAUDE_PLUGIN_ROOT"; } || { [ -f skills/plugin-dir.sh ] && pwd; } || { for _mp in "$HOME"/.claude/plugins/marketplaces/*/; do [ -f "${_mp}skills/plugin-dir.sh" ] && [ -f "${_mp}agents/pm.md" ] && printf '%s\n' "${_mp%/}" && break; done; } || find ~/.claude/plugins/cache -path '*/dev-team/*/skills/plugin-dir.sh' 2>/dev/null | awk -F/ '{ver=""; for(i=1;i<=NF;i++) if($i=="dev-team"&&i<NF){ver=$(i+1);break}; if(ver=="") next; m=ver; gsub(/-pre\./,"~pre.",m); p=($0 ~ /\/cache\/cold-dark-void\/dev-team\//)?1:0; print m "\t" p "\t" $0}' | sort -t $'\t' -k1,1V -k2,2n -k3,3 | tail -1 | cut -f3 | xargs -r dirname | xargs -r dirname )
TRAIN_LIB=$(bash "$PDH/skills/plugin-dir.sh" file skills/release-train/train-lib.sh)

# register
bash "$TRAIN_LIB" register "$BRANCH" --bump "${BUMP:-minor}"

# list / status
bash "$TRAIN_LIB" list

# drop
bash "$TRAIN_LIB" drop "$BRANCH"

# dry-run (no freeze write; no status changes)
bash "$TRAIN_LIB" freeze --print-only

# start — follow skills/release-train/SKILL.md landing loop end-to-end
# including AGENT STEP: /release <assigned_version> per entry
```

4. For `start` and `dry-run`, load and execute the full skill protocol (preflight,
   lock, freeze, merge-squash, M5 resolvers, `/release`, resume rules). Do not
   improvise release internals here.
