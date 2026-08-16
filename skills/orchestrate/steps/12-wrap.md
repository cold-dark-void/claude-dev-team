<!-- /orchestrate phase body. Load via SKILL.md router — current step only. -->

## Step 12: Wrap up

Suggest running `/wrap-ticket <ISSUE-ID>` for worktree removal + learnings.
- **After PR-stop:** Linear should be **In Review**; wrap after **merge** sets **Done**.
- **After master land:** Linear should already be **Done**; wrap re-applies Done
  idempotently (safety net) + local re-close.

Do **not** set Done from preference while code is still off master.

### Ship-history before `Orchestration complete` (SPEC-010 H5/H9; CDT-188)

On **master-land** paths (interactive squash, autopilot `merge` release **or**
land-no-release, resume-ship), **before** printing the `Orchestration complete`
banner:

- Require a clean `check-ship-history.sh --since $SHIP_START` result (same
  install-aware resolve as Step 11 ship-history gate; cite SPEC-010 H — do
  **not** restate D1–D4).
- **Dirty (H8 autopilot / H7 interactive):** print exact
  `history dirty — rewrite needed` (+ evidence). **MUST NOT** print
  `Orchestration complete`. **MUST NOT** claim Linear Done if not already
  blocked at Step 11. Halt; leave rewrite to human confirm (H7) or clean re-check.
- **PR-stop:** may print the banner with Tracking `Linear In Review (PR)` —
  ship-history gate does not apply (no master land).

Print (master-land only when ship-history clean; PR-stop always OK):

```
Orchestration complete for <ISSUE-ID>

Timeline:
  Scope confirmed:    <timestamp>
  Plan approved:      <timestamp>
  Implementation:     <N tasks, N agents>
  Review rounds:      <total across all tasks>
  QA:                 PASS

Artifacts:
  Branch:  <branch>
  PR:      <PR URL or "not created">
  Spec:    <spec path>
  Plan:    <plan path>
  Tracking: <closed N backlog | Linear In Review (PR) | Linear Done (on master) | none (freeform)>

Next: /wrap-ticket <ISSUE-ID> after merge (sets Linear Done if still In Review)
```

---

## Step 12b: Friction check (non-blocking)

Before exiting, check the just-completed orchestration session for friction
signals. Never auto-run `/retro`. Never block.

```bash
# Locate the dev-team plugin root (PDH). Optional CLAUDE_PLUGIN_ROOT (force path / FR #48230), else cwd dev/worktree, else marketplace clone (slug-free agents/pm.md), else installed cache (rank by /dev-team/<VER>/ segment, not full path; CDT-166). CDT-82: marketplace before same-version cache.
# lint-ok: C3 — marketplace */ for-loop + -f guarded (SPEC-021 Q2 residual, CDT-82 PDH)
PDH=$( { [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -f "$CLAUDE_PLUGIN_ROOT/skills/plugin-dir.sh" ] && printf '%s\n' "$CLAUDE_PLUGIN_ROOT"; } || { [ -f skills/plugin-dir.sh ] && pwd; } || { for _mp in "$HOME"/.claude/plugins/marketplaces/*/; do [ -f "${_mp}skills/plugin-dir.sh" ] && [ -f "${_mp}agents/pm.md" ] && printf '%s\n' "${_mp%/}" && break; done; } || find ~/.claude/plugins/cache -path '*/dev-team/*/skills/plugin-dir.sh' 2>/dev/null | awk -F/ '{ver=""; for(i=1;i<=NF;i++) if($i=="dev-team"&&i<NF){ver=$(i+1);break}; if(ver=="") next; m=ver; gsub(/-pre\./,"~pre.",m); p=($0 ~ /\/cache\/cold-dark-void\/dev-team\//)?1:0; print m "\t" p "\t" $0}' | sort -t $'\t' -k1,1V -k2,2n -k3,3 | tail -1 | cut -f3 | xargs -r dirname | xargs -r dirname )
bash "$PDH/skills/retro-gate/hint.sh" 2>/dev/null || true
```

Non-blocking. Silently skipped when gate binary is absent or JSONL is not
found. No user action required.
