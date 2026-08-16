<!-- /orchestrate phase body. Load via SKILL.md router — current step only. -->

## Step 11: Ship (present to user)

When all tasks are complete, reviewed, and QA-validated:

```
<ISSUE-ID> is ready to ship.

Summary of changes:
<high-level diff summary — files changed, what each does>

Spec:    <spec path>
Plan:    <plan path>
Branch:  <branch name>
Tasks:   N/N completed
Closes:  <from plan Tracking, or "none (freeform)">

Options:
1. Create PR (I'll draft title + description)
2. Just show me the diff
3. I need to review manually first
```

### Epic release=end ship guard (CDT-141-C4)

When this ticket is under an epic with durable `release_bump` set (release=end)
and seal is not done, **forbid** mid-child land onto the baseline — including
`/release` **and** land-no-release (`--autopilot=master` / end-state §5b).
`assert-release-allowed` still runs first. Baseline must stay clean until
end-of-epic seal (C5).

```bash
# Re-resolve PDH (fresh shell)
# lint-ok: C3 — marketplace */ for-loop + -f guarded (SPEC-021 Q2 residual, CDT-82 PDH)
PDH=$( { [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -f "$CLAUDE_PLUGIN_ROOT/skills/plugin-dir.sh" ] && printf '%s\n' "$CLAUDE_PLUGIN_ROOT"; } || { [ -f skills/plugin-dir.sh ] && pwd; } || { for _mp in "$HOME"/.claude/plugins/marketplaces/*/; do [ -f "${_mp}skills/plugin-dir.sh" ] && [ -f "${_mp}agents/pm.md" ] && printf '%s\n' "${_mp%/}" && break; done; } || find ~/.claude/plugins/cache -path '*/dev-team/*/skills/plugin-dir.sh' 2>/dev/null | awk -F/ '{ver=""; for(i=1;i<=NF;i++) if($i=="dev-team"&&i<NF){ver=$(i+1);break}; if(ver=="") next; m=ver; gsub(/-pre\./,"~pre.",m); p=($0 ~ /\/cache\/cold-dark-void\/dev-team\//)?1:0; print m "\t" p "\t" $0}' | sort -t $'\t' -k1,1V -k2,2n -k3,3 | tail -1 | cut -f3 | xargs -r dirname | xargs -r dirname )
EPIC_LIB=$(bash "$PDH/skills/plugin-dir.sh" file skills/epic/epic-lib.sh)
RELEASE_END_BLOCKED=false
_ASSERT_ERR=$(mktemp "${TMPDIR:-/tmp}/epic-assert-rel.XXXXXX")
if ! bash "$EPIC_LIB" assert-release-allowed "<ISSUE-ID>" 2>"$_ASSERT_ERR"; then
  RELEASE_END_BLOCKED=true
  cat "$_ASSERT_ERR" >&2 || true
fi
rm -f "$_ASSERT_ERR"
```

When `RELEASE_END_BLOCKED=true`:

- **Allowed:** Option 1 Create PR (PR-stop); Option 2/3 review; work stays on
  the integration branch (`feat/epic-<EPIC-ID>`). Child wrap via `/wrap-ticket`
  (does not release the integration tree — C3).
- **Forbidden:** autopilot `merge` → end-state (release **or** land-no-release);
  interactive "If squash merge requested"; `--resume-ship` any land path; any
  land onto master/main. Print the assert message and **halt** those paths —
  baseline unchanged, no version bump/tag/push, no land-no-release commit.
- Without `--release` on the parent epic (`release_bump` null/absent): assert
  exits 0 — per-child release/merge/land-no-release unchanged.

**Autopilot:** if `AUTOPILOT_ON` (Step 0), do NOT wait for the user here. Build the C3 §2
envelope `{ workflow:"orchestrate", ticket_id:<ISSUE-ID>, gate:"ship-choice",
run_id:RUN_ID, iteration:ITER, run_start_epoch:RUN_START_EPOCH,
autopilot_bump:AUTOPILOT_BUMP, <the Step-10b spec-alignment result, QA PASS/FAIL, the
session-local `qa_bounces` count (BC2), and ship-action irreversibility (protected-branch
merge / force-push)> }` and call `skills/autopilot/self-answer.md`'s procedure — it records
the clean answer as **card #1** (`blocking_condition = null` on a clean `pr`/`merge`).

**Council interposition (AC1 — SPEC-033 M14).** On a clean `pr` **or** `merge` card #1, run
`skills/autopilot/ship-gate-council.md`'s procedure **before any ship action** — on **both**
branches, not merge-only. That pass appends **card #2** (same `run_id`) and yields the
**post-council effective decision**: council **agree** (conf ≥ 80, non-degraded) keeps card #1's
`pr`/`merge`; **disagree / degraded / total-fail** forces `halt` (BC7). On a card #1 already
`halt`/`reroute-epic`, the council pass is **skipped** (ship-gate-council.md §2) and the
effective decision is card #1's.

Act on the **post-council effective decision**:
- `pr` → take Option 1 (Create PR) above exactly as the user's choice would; emit `task_complete`
  (detail = `shipped (PR): <PR URL>`) via **Passive notifications → Tier B** (fail-open; § below),
  then STOP — no `/release` (Tracking close-out below runs in its existing pre-delivery order).
  [PR-stop]
- `merge` → **CDT-141-C4:** if `RELEASE_END_BLOCKED=true`, do **not** run end-state;
  print `epic <ID> is in release=end mode until seal (CDT-141)` (from assert stderr),
  emit `task_blocked` via Tier B (fail-open), and return — baseline unchanged
  (release **and** land-no-release forbidden mid-epic). Else run
  `skills/autopilot/end-state.md` (shared preflight then branch on
  `AUTOPILOT_BUMP` — SPEC-033 N3a / CDT-195):
  deterministic BC3 push-target check (N3a) → record `SHIP_START_SHA` →
  `git merge --squash <branch>` (stage only) → then:
  - **`AUTOPILOT_BUMP` ∈ {patch, minor, major}** → **§5-release:** still **no**
    `git commit` here → `/release <AUTOPILOT_BUMP>` (sole commit + tag + push).
    **NEVER** pass `master` to `/release`.
  - **`AUTOPILOT_BUMP` = master** → **§5-land-no-release:** interactive-shape
    `git commit` + non-force `git push origin <baseline>` — **MUST NOT** invoke
    `/release`, version files, tag, or CHANGELOG.
  Then §5.5 ship-history clean check (SPEC-010 H; cite, do not restate D1–D4)
  and §6 closeout. Does **not** route through the interactive "If squash merge
  requested" block below (`autopilot_bump != null` is engine-guaranteed).
  On land success **and** end-state §5.5 clean (§6 closeout done), emit
  `task_complete` via **Passive notifications → Tier B** (fail-open; § below):
  - release path: detail = `released <bump>/<tag>`
  - land-no-release: detail = `landed master (no release)`
  On dirty ship-history (H8): halt with exact `history dirty — rewrite needed`;
  **MUST NOT** Linear/backlog Done, **MUST NOT** print Orchestration complete /
  ship success.
- `halt` / `reroute-epic` → print the one-line message below and return control; on `halt`
  **only**, first emit `task_blocked` (detail = the one-line message below) via **Passive
  notifications → Tier B** (fail-open; § below) — `reroute-epic` does NOT notify-blocked;
  `reroute-epic` additionally hands off to `/epic` decompose:
  The `/epic` decompose invocation MUST carry the autopilot state forward — pass
  `--autopilot[=<bump>]` (or `AUTOPILOT=1`); `/epic` Step 0.5 resolves its OWN autopilot state
  independently and does NOT inherit the caller's (SPEC-033 M11a).
```
ship-choice <decision>: <rationale> — card: <card-file-path>
```
On a **BC7 / ship-choice `halt`**, also print the resume hint (CDT-135; CDT-195):
```
Ship halted (BC7). To finish shipping after human review without re-running the
full ticket, use:
  /orchestrate <ISSUE-ID> --resume-ship=<patch|minor|major|master>
or reply "resume ship <patch|minor|major|master>" in this session (same sequence).
Bare --resume-ship re-reads plan/card mode. Does NOT auto-bypass BC7 — you must
explicitly confirm (path-aware: release vs land-no-release).
```
Otherwise (autopilot off), the user-choice gate below applies unchanged.

Wait for user choice.

### Resume ship after BC7 override (CDT-135; CDT-195)

**When:** A prior ship-choice halt (typically BC7 after M14 council disagree /
degraded / spawn-fail) left the work ready to ship, the human has reviewed and
**explicitly** wants to finish shipping, and re-running full PM/TL/IC is waste.

**Entry (either):**
1. `/orchestrate <ISSUE-ID> --resume-ship[=<patch|minor|major|master>]`
2. In-session after a BC7 halt: user says `resume ship` / `resume ship patch` /
   `resume ship master` (etc.)

**Bump resolution (context-aware):** explicit `=<token>` wins and overrides
recorded mode; else plan Tracking `autopilot_bump` / last ship-choice card bump
if non-null (bare re-read); else ask once (`patch` recommended for fix trains;
`master` only when land-no-release is intentional). Invalid token → error, no
ship actions. Tokens ∈ {patch, minor, major, master}.

**MUST NOT:** re-run scope-confirm / plan-approve / IC implementation / M14
council as if starting fresh; invent a bump; skip the human confirmation line
below; force-push; pass `master` to `/release`; force release path when token
is `master` (or force land-no-release when token is a release bump).

**Confirmed sequence (one orchestrated path — replace ad-hoc land then
`/wrap-ticket`):**

0. **CDT-141-C4:** run `assert-release-allowed <ISSUE-ID>` first. On exit 64
   (release=end mid-flight): print the message, **stop** — no squash, no
   `/release`, no land-no-release, baseline unchanged. (Seal is C5; resume-ship
   is not a seal. Mid-epic land-no-release forbidden too.)
1. Print plan summary: branch, worktree, proposed token, land path name
   (`release <bump>` vs `land-no-release`), last ship-choice card path
   (`$MROOT/.claude/autopilot/<ISSUE-ID>.jsonl` if present).
2. Ask once with **path-aware** confirm (**required**; autopilot MUST NOT
   self-answer this confirmation — human override of a safety halt):
   - release token: `Proceed with release <bump> + wrap-ticket <ISSUE-ID>? (y/n)`
   - `master`: `Proceed with land-no-release (commit+push baseline, no /release)
     + wrap-ticket <ISSUE-ID>? (y/n)`
3. On `n` / empty: stop; no side effects.
4. On `y`:
   - If worktree still present: run `skills/autopilot/end-state.md` for the
     chosen token (shared preflight → §5-release **or** §5-land-no-release →
     §5.5 → tracking close-out per that file's §6).
   - Else if already on baseline with clean tree after a prior partial land:
     - release token: run `/release <bump>` only if version files still need
       the bump; otherwise skip to wrap.
     - `master`: **MUST NOT** run `/release`; if commit already pushed, skip
       to wrap; if staged-only leftover, halt for human.
   - Then `/wrap-ticket <ISSUE-ID>` (idempotent close-out + worktree release).
5. Emit `task_complete` via Passive notifications Tier B (fail-open):
   - release: detail = `resume-ship released <bump>`
   - land-no-release: detail = `resume-ship landed master (no release)`
6. Append one decision card to the ticket ledger if append-card is available:
   `gate=ship-choice`, `decision=merge`, `decided_by=user`,
   `blocking_condition=null`, `bump=<resolved token>`, rationale notes path
   (`human override of BC7 via --resume-ship` + `release` or `land-no-release`)
   (never rewrite prior halt cards).

**Failure:** any land abort (`/release` pre-commit gate, land-no-release
commit/push fail, ship-history dirty) → stop; leave wrap for later; print the
failing gate / evidence.

### Linear lifecycle (status truth — master is Done)

Linear issue status must match **where the code lives**, not “implementation
finished in a worktree”:

| Phase | Linear status | When |
|-------|---------------|------|
| Work started | **In Progress** | Step 3 (already) |
| PR open / not on master | **In Review** | PR-stop, draft/ready PR, release=end child left on integration branch |
| Landed on master + close-out | **Done** (or team Released) | Squash/merge to baseline succeeds (interactive, release `/release`, **or** land-no-release commit+push), **and** ship-history clean (SPEC-010 H), **or** `/wrap-ticket` after land |

**MUST NOT** set Linear to **Done** when the only ship action was open a PR,
push a feature branch, or finish IC/QA while changes are still off master.
That was a footgun: tickets looked Done while master lacked the code.

**MUST NOT** set Linear to **Done** when ship-history is dirty (SPEC-010 H5/H8/H9):
run `check-ship-history.sh --since $SHIP_START` (or ambient `SHIP_START_SHA`) and
require exit 0 before any master-land Done. Dirty → exact halt
`history dirty — rewrite needed`; trackers stay open. Cite SPEC-010 H — do not
restate D1–D4.

Local backlog write-through (`close.sh`) may still flip **local** COMPLETED at
ship (process cache) only when ship-history is clean on master-land paths.
Linear terminal state is **master-land / wrap**, not PR-open.

### Tracking close-out (ship DoD — orchestrator-owned)

**Before** finalizing the delivery commit (PR tip commit or squash), close every
**local** tracker listed under plan `closes:` (`backlog/<slug>.md`). Do this on
the **feature worktree** (`--root "$WT_PATH"`) so edits land on the branch tree
— not mid-flight by parallel ICs (avoids `backlog.md` races).

**Linear** (`linear:<ID>` / source=linear) is **path-dependent** (see table above):
- **PR-stop / autopilot `pr` / release=end PR-only:** MCP → **In Review** + PR URL
  comment. **MUST NOT** Done.
- **Master land** (interactive squash onto baseline, autopilot `merge` after
  release **or** land-no-release success **and** ship-history clean, resume-ship
  after either land path): MCP → **Done** + PR/SHA comment. **Requires** clean
  `check-ship-history.sh` (SPEC-010 H5/H9) first — see ship-history gate below.
- Fail-open if MCP unavailable: print a warning; do not invent Done or In Review.

**Autopilot land-path exception (AC5, CDT-111-C9; CDT-195):** on the autopilot
`merge` → end-state path (release **or** land-no-release) **only**, this close-out
runs **after** the land succeeds **and** end-state §5.5 ship-history is clean
(per `skills/autopilot/end-state.md` §6) — not before — so trackers stay open if
`/release` aborts at a pre-commit gate, land-no-release commit/push fails, or
history is dirty (nothing claimed Done). Every other path (interactive PR,
interactive squash, autopilot `pr`) keeps the before-commit ordering below for
**local** backlog; Linear follows the lifecycle table. Master-land paths still
require the ship-history gate before Linear **Done**.

```bash
# Re-resolve PDH / MROOT / WT (fresh shell). Parse backlog slugs from plan Tracking.
_gc=$(git rev-parse --git-common-dir 2>/dev/null) \
  && MROOT=$(cd "$(dirname "$_gc")" && pwd) \
  || MROOT=$(pwd)
# lint-ok: C3 — marketplace */ for-loop + -f guarded (SPEC-021 Q2 residual, CDT-82 PDH)
PDH=$( { [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -f "$CLAUDE_PLUGIN_ROOT/skills/plugin-dir.sh" ] && printf '%s\n' "$CLAUDE_PLUGIN_ROOT"; } || { [ -f skills/plugin-dir.sh ] && pwd; } || { for _mp in "$HOME"/.claude/plugins/marketplaces/*/; do [ -f "${_mp}skills/plugin-dir.sh" ] && [ -f "${_mp}agents/pm.md" ] && printf '%s\n' "${_mp%/}" && break; done; } || find ~/.claude/plugins/cache -path '*/dev-team/*/skills/plugin-dir.sh' 2>/dev/null | awk -F/ '{ver=""; for(i=1;i<=NF;i++) if($i=="dev-team"&&i<NF){ver=$(i+1);break}; if(ver=="") next; m=ver; gsub(/-pre\./,"~pre.",m); p=($0 ~ /\/cache\/cold-dark-void\/dev-team\//)?1:0; print m "\t" p "\t" $0}' | sort -t $'\t' -k1,1V -k2,2n -k3,3 | tail -1 | cut -f3 | xargs -r dirname | xargs -r dirname )
CLOSE=$(bash "$PDH/skills/plugin-dir.sh" file skills/backlog/close.sh)
EPIC_LIB=$(bash "$PDH/skills/plugin-dir.sh" file skills/epic/epic-lib.sh)
WT_PATH=$(bash "$EPIC_LIB" ensure-ticket-worktree "<ISSUE-ID>" 2>/dev/null) \
  || WT_PATH="$MROOT/.worktrees/<ISSUE-ID>"
# Prefer worktree root for --root when present (local write-through on branch tree).
[ -d "$WT_PATH" ] || WT_PATH=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
# For each plan closes: entry of form backlog/<slug>.md (or bare slug):
bash "$CLOSE" "<slug>" --root "$WT_PATH" --ticket "<ISSUE-ID>" --status "FIXED/CLOSED"
bash "$CLOSE" verify "<slug>" --root "$WT_PATH" || {
  echo "Ship blocked: backlog/<slug> still open after close" >&2
  exit 1
}
```

- Close local write-through (item Status + index) on disk; **MUST NOT** stage or
  commit `.claude/backlog*` / `.claude/plans*` into the product delivery commit
  (process trackers never upstream — SPEC-009 / CDT-54).
- For each `linear:<ID>` (or source=linear): apply **Linear lifecycle** for this
  ship path (**In Review** on PR-stop; **Done** only after master land). Comment
  with PR URL and/or SHA when known. Fail-open if MCP unavailable.
- Empty `closes:` (freeform): print `Tracking: none (freeform)` — do not block.
- Non-empty closes that fail verify on local write-through: **block ship**.

### If PR requested:

```bash template
cd <worktree-path>
# Tracking close-out already applied on this worktree (above) — status only; do NOT git add .claude/backlog*
git status --short
git push -u origin <branch>
gh pr create --title "<ISSUE-ID>: <title>" --body "$(cat <<'EOF'
## Summary
<bullet points from plan>

## Acceptance Criteria
- [x] <AC 1>
- [x] <AC 2>

## Test Plan
<QA validation results>

## Spec
<link to spec file>

Closes <ISSUE-ID>

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

If `gh` is not available, fall back to `git push -u origin <branch>` and print the
URL for manual PR creation.

If Linear is available: set status to **In Review** (not Done), attach/link the
PR, comment with PR URL. Covered by Tracking close-out PR-stop branch.

### If squash merge requested (no PR):

**CDT-141-C4:** if `RELEASE_END_BLOCKED=true` (or `assert-release-allowed
<ISSUE-ID>` exits 64), **halt** — do not squash onto master; print the
release=end message; master unchanged. Prefer PR-stop or leave work on the
integration branch until epic seal (C5).

Prefer plain git — do NOT require `gh`. Apply Tracking close-out on the feature
worktree first (local write-through; Linear **Done** only after squash commit on
master succeeds — if squash fails, leave Linear at In Progress/In Review):

**Glossary ship gate (before squash):**
1. If this ticket crystallized glossary terms, `CONTEXT.md` (or
   `docs/domain/CONTEXT.md`) **MUST** already be committed on the feature branch
   (`git -C "$WT_PATH" log --oneline "$MERGE_BASE"..HEAD -- CONTEXT.md
   docs/domain/CONTEXT.md`). If missing but terms exist in plan delta / MROOT
   dirt → run Step 3b/6b now, then continue. **Do not** land without them.
2. **MUST NOT** deliberately exclude `CONTEXT.md` from the land (no
   "leave dirty on main" / "grep CONTEXT and unstage" patterns). Squash of the
   feature branch already includes branch commits; uncommitted MROOT dirt is
   **not** a substitute and **must not** be left as the only copy after ship.
3. After a successful land that included glossary commits, main checkout should
   be clean for `CONTEXT.md` (Step 3b already restored MROOT; re-check with a
   fresh shell: resolve MROOT then
   `git -C "$MROOT" status --porcelain -- CONTEXT.md`).

```bash template
# CDT-141-C4 precheck (re-resolve if fresh shell)
# lint-ok: C3 — marketplace */ for-loop + -f guarded (SPEC-021 Q2 residual, CDT-82 PDH)
PDH=$( { [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -f "$CLAUDE_PLUGIN_ROOT/skills/plugin-dir.sh" ] && printf '%s\n' "$CLAUDE_PLUGIN_ROOT"; } || { [ -f skills/plugin-dir.sh ] && pwd; } || { for _mp in "$HOME"/.claude/plugins/marketplaces/*/; do [ -f "${_mp}skills/plugin-dir.sh" ] && [ -f "${_mp}agents/pm.md" ] && printf '%s\n' "${_mp%/}" && break; done; } || find ~/.claude/plugins/cache -path '*/dev-team/*/skills/plugin-dir.sh' 2>/dev/null | awk -F/ '{ver=""; for(i=1;i<=NF;i++) if($i=="dev-team"&&i<NF){ver=$(i+1);break}; if(ver=="") next; m=ver; gsub(/-pre\./,"~pre.",m); p=($0 ~ /\/cache\/cold-dark-void\/dev-team\//)?1:0; print m "\t" p "\t" $0}' | sort -t $'\t' -k1,1V -k2,2n -k3,3 | tail -1 | cut -f3 | xargs -r dirname | xargs -r dirname )
EPIC_LIB=$(bash "$PDH/skills/plugin-dir.sh" file skills/epic/epic-lib.sh)
bash "$EPIC_LIB" assert-release-allowed "<ISSUE-ID>" || exit 64
# Tracking close-out on WT_PATH already done (above) — status flips only; do NOT
# include .claude/backlog* or .claude/plans* in the squash tree.
# Glossary: feature branch CONTEXT.md commits land with the squash — never
# strip them; never rely on uncommitted main-checkout CONTEXT.md instead.
cd <main-repo-path>
git merge --squash <branch>
git commit -m "<ISSUE-ID>: <title>

<bullet summary>

Co-Authored-By: Claude <model> <noreply@anthropic.com>"
```

**Honest identity** — replace `<model>` with the agent/model actually performing this commit. Do **not** hardcode Claude/Anthropic when the agent is something else (e.g. Grok, Codex, a human). Examples:
- `Co-Authored-By: Grok <noreply@x.ai>`
- `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>`

Only use `gh pr merge --squash` if the user explicitly created a PR and `gh` is
available. Plain `git merge --squash` is the default merge path.

### Ship-history gate before master-land Done (SPEC-010 H5/H7–H9; CDT-188)

On **any master-land path** (interactive squash onto baseline, autopilot `merge`
end-state after release **or** land-no-release, resume-ship after either land)
**before** Linear **Done**, local backlog terminal close that implies ship
success, or Step 12 `Orchestration complete`:

1. Ensure `SHIP_START` / `SHIP_START_SHA` is known (end-state §3.5 /
   `/release` Step 0.5; for interactive squash-only or land-no-release without
   `/release`, record `SHIP_START=$(git rev-parse HEAD)` on the main-repo path
   **before** the squash commit).
2. Run the install-aware checker (cite SPEC-010 H — **do not** restate D1–D4):

```bash
# Fresh shell — re-resolve PDH (SPEC-021 C1)
# lint-ok: C3 — marketplace */ for-loop + -f guarded (SPEC-021 Q2 residual, CDT-82 PDH)
PDH=$( { [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -f "$CLAUDE_PLUGIN_ROOT/skills/plugin-dir.sh" ] && printf '%s\n' "$CLAUDE_PLUGIN_ROOT"; } || { [ -f skills/plugin-dir.sh ] && pwd; } || { for _mp in "$HOME"/.claude/plugins/marketplaces/*/; do [ -f "${_mp}skills/plugin-dir.sh" ] && [ -f "${_mp}agents/pm.md" ] && printf '%s\n' "${_mp%/}" && break; done; } || find ~/.claude/plugins/cache -path '*/dev-team/*/skills/plugin-dir.sh' 2>/dev/null | awk -F/ '{ver=""; for(i=1;i<=NF;i++) if($i=="dev-team"&&i<NF){ver=$(i+1);break}; if(ver=="") next; m=ver; gsub(/-pre\./,"~pre.",m); p=($0 ~ /\/cache\/cold-dark-void\/dev-team\//)?1:0; print m "\t" p "\t" $0}' | sort -t $'\t' -k1,1V -k2,2n -k3,3 | tail -1 | cut -f3 | xargs -r dirname | xargs -r dirname )
CHECK_SHIP=$(bash "$PDH/skills/plugin-dir.sh" file skills/release/check-ship-history.sh)
SHIP_START="${SHIP_START:-${SHIP_START_SHA:-}}"
[ -n "$SHIP_START" ] || { echo "orchestrate: SHIP_START unset for master-land gate" >&2; exit 64; }
bash "$CHECK_SHIP" --since "$SHIP_START"
```

3. **Exit 0** — proceed with Linear Done / closeout / Step 12 complete banner.
4. **Exit 1 dirty:**
   - **Autopilot on (H8):** halt with exact `history dirty — rewrite needed`
     plus checker evidence. **MUST NOT** Done, **MUST NOT** `Orchestration
     complete`, **MUST NOT** silent force-push.
   - **Interactive (H7):** print evidence + rewrite plan; require explicit user
     confirm before rewrite/force-push; on decline → halt (refs unchanged).
5. **PR-stop paths** skip this gate (no master land / no Done claim).

---

## Worktree cleanup

**CDT-141-C3:** when this ticket used a **shared epic integration** worktree
(`USE_SHARED=true` / `resolve-child-worktree.skip_release`), **MUST NOT** call
`worktree-lib release` on the child slug **or** the `epic-<EPIC-ID>` integration
slug — other children still need the tree. Prefer `/wrap-ticket <ISSUE-ID>` which
also skips release when shared. Integration tree lifecycle is epic-owned (C5 seal
/ end-of-epic), not per-child wrap.

**Prefer `worktree-lib.sh release <slug>`** only for **non-shared** per-ticket
trees — it handles EBUSY retry, branch deletion, and orphaned config-section
cleanup. Use it instead of running `git worktree remove` + `git branch -D` by hand:

```bash
# lint-ok: C3 — marketplace */ for-loop + -f guarded (SPEC-021 Q2 residual, CDT-82 PDH)
PDH=$( { [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -f "$CLAUDE_PLUGIN_ROOT/skills/plugin-dir.sh" ] && printf '%s\n' "$CLAUDE_PLUGIN_ROOT"; } || { [ -f skills/plugin-dir.sh ] && pwd; } || { for _mp in "$HOME"/.claude/plugins/marketplaces/*/; do [ -f "${_mp}skills/plugin-dir.sh" ] && [ -f "${_mp}agents/pm.md" ] && printf '%s\n' "${_mp%/}" && break; done; } || find ~/.claude/plugins/cache -path '*/dev-team/*/skills/plugin-dir.sh' 2>/dev/null | awk -F/ '{ver=""; for(i=1;i<=NF;i++) if($i=="dev-team"&&i<NF){ver=$(i+1);break}; if(ver=="") next; m=ver; gsub(/-pre\./,"~pre.",m); p=($0 ~ /\/cache\/cold-dark-void\/dev-team\//)?1:0; print m "\t" p "\t" $0}' | sort -t $'\t' -k1,1V -k2,2n -k3,3 | tail -1 | cut -f3 | xargs -r dirname | xargs -r dirname )
EPIC_LIB=$(bash "$PDH/skills/plugin-dir.sh" file skills/epic/epic-lib.sh)
SLUG="<ISSUE-ID>"
CHILD_WT=$(bash "$EPIC_LIB" resolve-child-worktree "$SLUG")
if [ "$(jq -r '.skip_release // false' <<<"$CHILD_WT")" = "true" ]; then
  echo "Shared epic integration worktree — skipping release of $SLUG / integration slug"
else
  WT_LIB=$(bash "$PDH/skills/plugin-dir.sh" file skills/worktree-lib.sh)
  bash "$WT_LIB" release "$SLUG"
fi
```

If you must do it by hand (squash-merge case where the lib refuses on
"uncommitted changes"), run each step as a SEPARATE Bash call — never
chain `worktree remove && branch -D` in a single command. On WSL2 the
second op fires while the first is still releasing `.git/config`, which
produces `error: could not write config file .git/config: Device or
resource busy`. The branch ref still gets deleted but the
`[branch "feat/X"]` config stanza orphans:

```bash template
git worktree remove <path-1>      # call 1
git branch -D <branch-1>          # call 2 (separate Bash invocation)
git worktree prune                # call 3 (reaps leftover admin entries)
```

**Serialize across worktrees** — do NOT remove multiple worktrees in
parallel for the same reason. Drain them one at a time.

