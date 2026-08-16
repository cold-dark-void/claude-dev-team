<!-- /orchestrate phase body. Load via SKILL.md router — current step only. -->

## Step 3: Create branch and worktree

A git worktree is an additional working tree linked to the same repository — it lets
agents work on the issue branch in isolation without disturbing the main checkout.

**CDT-141-C3 / epic shared integration:** when this ticket is an epic child of a
`--worktree` epic (or `EPIC_INTEGRATION_PATH` is set to an existing integration
tree), do **not** open a per-child worktree off master. Route through
`epic-lib ensure-ticket-worktree` — it prints the shared path and skips
`worktree-lib ensure <child-slug>`. Default (no epic shared tree): same as today.

```bash
# lint-ok: C3 — marketplace */ for-loop + -f guarded (SPEC-021 Q2 residual, CDT-82 PDH)
PDH=$( { [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -f "$CLAUDE_PLUGIN_ROOT/skills/plugin-dir.sh" ] && printf '%s\n' "$CLAUDE_PLUGIN_ROOT"; } || { [ -f skills/plugin-dir.sh ] && pwd; } || { for _mp in "$HOME"/.claude/plugins/marketplaces/*/; do [ -f "${_mp}skills/plugin-dir.sh" ] && [ -f "${_mp}agents/pm.md" ] && printf '%s\n' "${_mp%/}" && break; done; } || find ~/.claude/plugins/cache -path '*/dev-team/*/skills/plugin-dir.sh' 2>/dev/null | awk -F/ '{ver=""; for(i=1;i<=NF;i++) if($i=="dev-team"&&i<NF){ver=$(i+1);break}; if(ver=="") next; m=ver; gsub(/-pre\./,"~pre.",m); p=($0 ~ /\/cache\/cold-dark-void\/dev-team\//)?1:0; print m "\t" p "\t" $0}' | sort -t $'\t' -k1,1V -k2,2n -k3,3 | tail -1 | cut -f3 | xargs -r dirname | xargs -r dirname )
SLUG="<ISSUE-ID>"   # bare issue ID (e.g. "CDV-42" or "CDT-141-C3")
EPIC_LIB=$(bash "$PDH/skills/plugin-dir.sh" file skills/epic/epic-lib.sh)
# Prefer ensure-ticket-worktree: shared integration when epic child + worktree_enabled,
# else worktree-lib ensure <SLUG>. Honors EPIC_INTEGRATION_PATH from epic B.4 handoff.
WT_PATH=$(bash "$EPIC_LIB" ensure-ticket-worktree "$SLUG") || {
  EXIT=$?
  if [ "$EXIT" -eq 2 ]; then
    echo "Worktree setup aborted by user." >&2
  elif [ "$EXIT" -eq 64 ]; then
    echo "ensure-ticket-worktree / worktree-lib usage error, check slug" >&2
  fi
  exit "$EXIT"
}
# Record whether this run is on a shared epic tree (for cleanup + re-derive).
CHILD_WT=$(bash "$EPIC_LIB" resolve-child-worktree "$SLUG")
USE_SHARED=$(jq -r '.use_shared // false' <<<"$CHILD_WT")
INT_SLUG=$(jq -r '.integration_slug // empty' <<<"$CHILD_WT")
```

When `USE_SHARED=true`: `$WT_PATH` is the epic integration path
(`.worktrees/epic-<EPIC-ID>`), branch `feat/epic-<EPIC-ID>`. **Zero** new
per-child trees. Child commits land on the integration branch.

When `USE_SHARED=false`: same as pre-C3 — `worktree-lib` creates `feat/<SLUG>`
and prints `.worktrees/<SLUG>`.

- **Exit 1** (unexpected error): git or filesystem failure; stderr will have details; halt.
- **Exit 2** (user aborted): halt cleanly.
- **Exit 64** (usage error): surface usage error to stderr.

Use `$WT_PATH` everywhere downstream. On later fences, re-derive:

```bash
# Shared epic child: resolve again (do NOT hardcode .worktrees/<ISSUE-ID>)
# lint-ok: C3 — marketplace */ for-loop + -f guarded (SPEC-021 Q2 residual, CDT-82 PDH)
PDH=$( { [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -f "$CLAUDE_PLUGIN_ROOT/skills/plugin-dir.sh" ] && printf '%s\n' "$CLAUDE_PLUGIN_ROOT"; } || { [ -f skills/plugin-dir.sh ] && pwd; } || { for _mp in "$HOME"/.claude/plugins/marketplaces/*/; do [ -f "${_mp}skills/plugin-dir.sh" ] && [ -f "${_mp}agents/pm.md" ] && printf '%s\n' "${_mp%/}" && break; done; } || find ~/.claude/plugins/cache -path '*/dev-team/*/skills/plugin-dir.sh' 2>/dev/null | awk -F/ '{ver=""; for(i=1;i<=NF;i++) if($i=="dev-team"&&i<NF){ver=$(i+1);break}; if(ver=="") next; m=ver; gsub(/-pre\./,"~pre.",m); p=($0 ~ /\/cache\/cold-dark-void\/dev-team\//)?1:0; print m "\t" p "\t" $0}' | sort -t $'\t' -k1,1V -k2,2n -k3,3 | tail -1 | cut -f3 | xargs -r dirname | xargs -r dirname )
EPIC_LIB=$(bash "$PDH/skills/plugin-dir.sh" file skills/epic/epic-lib.sh)
WT_PATH=$(bash "$EPIC_LIB" ensure-ticket-worktree "<ISSUE-ID>")
# or, if USE_SHARED was true: WT_PATH=$(jq -r .integration_path <<<"$(bash "$EPIC_LIB" resolve-child-worktree "<ISSUE-ID>")")
```

If Linear is available, update issue status to "In Progress".

### Step 3b: Promote domain glossary into the worktree (mandatory when dirty)

After `$WT_PATH` exists, **before** Step 4 spawns, close the brainstorm→master-dirt
footgun (`CONTEXT.md` written on `$MROOT` while specs/code land on `feat/<id>`):

1. Resolve glossary paths (first hit): `$MROOT/CONTEXT.md` else
   `$MROOT/docs/domain/CONTEXT.md`. Same relative path under `$WT_PATH`.
2. Collect crystallized terms from (any of):
   - uncommitted `$MROOT` glossary dirt (`git -C "$MROOT" status --porcelain` on
     that path)
   - any recent brainstorm plan under `$MROOT/.claude/plans/` with a
     `## Domain glossary delta` section for this ticket/slug
3. If nothing to promote → print `Glossary: none to promote` and continue.
4. If terms exist: merge them into `$WT_PATH/CONTEXT.md` (or
   `$WT_PATH/docs/domain/CONTEXT.md` if that layout is already used). Follow
   `skills/domain-glossary/SKILL.md` merge rules (user-confirmed only, no wipe).
5. Commit **on the feature branch** inside the worktree (same lifecycle as the
   forthcoming spec — CDT-105; never commit glossary on `$MROOT` master here):
   ```bash
   # Re-derive (fresh shell — SPEC-021 C1)
   _gc=$(git rev-parse --git-common-dir 2>/dev/null) \
     && MROOT=$(cd "$(dirname "$_gc")" && pwd) \
     || MROOT=$(pwd)
   # lint-ok: C3 — marketplace */ for-loop + -f guarded (SPEC-021 Q2 residual, CDT-82 PDH)
   PDH=$( { [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -f "$CLAUDE_PLUGIN_ROOT/skills/plugin-dir.sh" ] && printf '%s\n' "$CLAUDE_PLUGIN_ROOT"; } || { [ -f skills/plugin-dir.sh ] && pwd; } || { for _mp in "$HOME"/.claude/plugins/marketplaces/*/; do [ -f "${_mp}skills/plugin-dir.sh" ] && [ -f "${_mp}agents/pm.md" ] && printf '%s\n' "${_mp%/}" && break; done; } || find ~/.claude/plugins/cache -path '*/dev-team/*/skills/plugin-dir.sh' 2>/dev/null | awk -F/ '{ver=""; for(i=1;i<=NF;i++) if($i=="dev-team"&&i<NF){ver=$(i+1);break}; if(ver=="") next; m=ver; gsub(/-pre\./,"~pre.",m); p=($0 ~ /\/cache\/cold-dark-void\/dev-team\//)?1:0; print m "\t" p "\t" $0}' | sort -t $'\t' -k1,1V -k2,2n -k3,3 | tail -1 | cut -f3 | xargs -r dirname | xargs -r dirname )
   EPIC_LIB=$(bash "$PDH/skills/plugin-dir.sh" file skills/epic/epic-lib.sh)
   WT_PATH=$(bash "$EPIC_LIB" ensure-ticket-worktree "<ISSUE-ID>")
   git -C "$WT_PATH" add CONTEXT.md   # or docs/domain/CONTEXT.md
   git -C "$WT_PATH" status --porcelain -- CONTEXT.md docs/domain/CONTEXT.md | grep -q . && \
     git -C "$WT_PATH" commit -m "context: <ISSUE-ID> — crystallized glossary terms"
   ```
6. After a successful worktree commit that absorbed `$MROOT` dirt: restore the
   main checkout so master is not left dirty with the same terms:
   ```bash
   # Fresh shell — re-resolve MROOT (SPEC-021 C1)
   _gc=$(git rev-parse --git-common-dir 2>/dev/null) \
     && MROOT=$(cd "$(dirname "$_gc")" && pwd) \
     || MROOT=$(pwd)
   git -C "$MROOT" checkout -- CONTEXT.md 2>/dev/null || true
   git -C "$MROOT" checkout -- docs/domain/CONTEXT.md 2>/dev/null || true
   ```
   Only when the promoted content was committed on `$WT_PATH`. If promote failed,
   leave MROOT dirt and **halt ship later** until fixed — do not silently drop terms.

Print: `Glossary: promoted to $WT_PATH and committed | none to promote | blocked: <reason>`.

