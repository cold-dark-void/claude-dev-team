<!-- /epic stage body — load via SKILL.md router; read only the current stage. -->

## Mode E — `--redecompose` (M9 + M12)

1. Require explicit `--redecompose` flag.
2. Require user **yes** confirmation. Without confirmation: **no-op**.
3. Preserve completed children records (never delete/alter completed).
4. Re-run PM∥TL for non-completed only (reuse **A.2** Model map fences; no ICs); re-merge; full-graph `check-cycle`.
5. On approve: update/replace non-completed children in state + backlog; do not duplicate backlog for unchanged completed children.
6. **Linear project (M12 / AC9):**
   - If `linear_project_id` is **non-null**: **reuse** it — do not create/list a
     second project; id stays stable. Attach **only new/changed** children to
     that project on dual-write (no re-attach of unchanged/completed children).
   - If `linear_project_id` is **null** and MCP is up after approve: run the
     A.6 M12 create/link path **once**, then
     `set-linear-project`; attach new/changed dual-written children.
   - Project/attach failures → same M5 one-liner; local continues.
7. Linear issues: best-effort only for new/changed children. **M4.1 first:**
   inventory `list_issues(parentId=<EPIC-ID>)`; adopt unique map for children
   that already exist; **create only** for proposed children with no survivor
   match when the overall map is non-ambiguous (or after explicit force-create).
   Never blind-create a full second set when parent already has survivors.
   `save_issue` with `project` when id known + `epic:<EPIC-ID>` labels — AC11.

