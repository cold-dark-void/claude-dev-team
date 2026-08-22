# Autopilot land end-state sequence (CDT-111-C9; CDT-195)

> **Companion to `skills/autopilot/SKILL.md`, `skills/autopilot/self-answer.md`, and
> `skills/autopilot/ship-gate-council.md`.** This file is a *procedure*, not a *policy*.
> It describes the operational sequence autopilot follows to execute a **post-council
> `merge` land** — once a ship-choice answer has been auto-decided and audited. Two land
> paths share preflight and diverge at the ref-mutating step by card bump:
>
> | Bump | Path | Ref-mutating step |
> |------|------|-------------------|
> | `patch` \| `minor` \| `major` | **§5-release** | stage only → `/release <bump>` (sole commit+tag+push) |
> | `master` (sentinel) | **§5-land-no-release** | interactive-shape `git commit` → non-force `git push` baseline — **no** `/release` |
>
> It wires no caller and defines no new script; `/orchestrate` Step 11 invokes it. The clean
> triad is `self-answer.md` (answer the gate) → `ship-gate-council.md` (audit the answer) →
> `end-state.md` (execute the ship).

## 1. Purpose + contract-home stance

The normative contract for either land path is **SPEC-033 N3/N3a** (the deterministic BC3
push-target check) together with **M14** (the council pass that must have agreed) and **M2/N3**
(the `--autopilot=<token>` ship-intent that authorizes `merge`). Token class selects the land
branch (release vs land-no-release) — cite SPEC-033 M2/M4/N3a; **do not fork**.

- **§5-release:** the single ship-of-record for the ref-mutating step is **`/release`**
  (`skills/release/SKILL.md`) with its own one-commit contract and pre-commit gates.
- **§5-land-no-release (CDT-195):** this procedure itself commits (interactive squash message
  shape) and non-force-pushes the worktree baseline — **MUST NOT** invoke `/release`, touch
  version files, tag, or CHANGELOG. Land target = worktree baseline / `origin/HEAD` default
  branch name — **not** a hard-coded ref named `master`.

**Asymmetry (R5):** release path **stages only** before `/release` (adding a `git commit`
here would double-commit with `/release`'s fold). Land-no-release **does** commit + push
(one fold commit, no tag) because there is no `/release` ship-of-record.

This procedure cites contract homes by name/ordinal and never restates or forks them
(SPEC-002 D1 / SPEC-033 M12 / N4 — same discipline as `self-answer.md` §1 and
`ship-gate-council.md` §1). In particular it does **not** reproduce the BC3 definition, the
M6 blocking-condition taxonomy, `/release`'s step list or version-sync gates, or the
interactive squash block's commit shape — it points at each home.

What this procedure adds is the **operational sequence**: fire on a post-council effective
`merge`, run shared preflight (epic assert → BC3 → SHIP_START_SHA → squash-stage), **branch
on bump**, then shared ship-history + tracking closeout.

## 2. Firing check

This sequence fires **only** on a **post-council effective `merge`** decision — i.e.
`self-answer.md`'s ship-choice engine returned a clean `merge` card #1 (`autopilot_bump != null`,
`blocking_condition = null`; §4/§3e of `self-answer.md`) **and** `ship-gate-council.md`'s pass
**agreed** (card #2 kept `merge`; conf ≥ 80, non-degraded). It runs on the main-repo path where
`/orchestrate` Step 11 dispatches the effective decision.

**Branch key = card bump** (carried as `AUTOPILOT_BUMP` / card #1 `bump` through council agree):

| `AUTOPILOT_BUMP` | Land path |
|------------------|-----------|
| `patch` \| `minor` \| `major` | §5-release |
| `master` | §5-land-no-release |
| `null` / other | **MUST NOT** fire (engine guarantees non-null on clean `merge`) |

- It **never** fires on `pr` — that is the PR-stop end state (create PR, then stop; no land).
  `pr` and `merge` are mutually exclusive ship-choice terminals.
- It **never** fires on a `halt` / `reroute-epic` answer, nor on a `merge` whose council pass
  **disagreed / degraded / total-failed** (that pass forced `halt`/BC7; `ship-gate-council.md`
  §4–§5). No council agreement ⇒ no land.
- It fires **exactly once** per shipped ticket — one squash-stage, one land path
  (one `/release` **or** one land-no-release commit+push).

## 2.5 Epic release=end precheck (CDT-141-C4)

**Before** BC3 / squash / any land (release **or** land-no-release), forbid mid-epic land when
durable epic state has `release_bump` set and seal is not done. **Land-no-release is included** —
`assert-release-allowed` still runs first; mid-epic `bump=master` must not land either.

```bash
# lint-ok: C3 — marketplace */ for-loop + -f guarded (SPEC-021 Q2 residual, CDT-82 PDH)
PDH=$( { [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -f "$CLAUDE_PLUGIN_ROOT/skills/plugin-dir.sh" ] && printf '%s\n' "$CLAUDE_PLUGIN_ROOT"; } || { [ -f skills/plugin-dir.sh ] && pwd; } || { for _mp in "$HOME"/.claude/plugins/marketplaces/*/; do [ -f "${_mp}skills/plugin-dir.sh" ] && [ -f "${_mp}agents/pm.md" ] && printf '%s\n' "${_mp%/}" && break; done; } || find ~/.claude/plugins/cache -path '*/dev-team/*/skills/plugin-dir.sh' 2>/dev/null | awk -F/ '{ver=""; for(i=1;i<=NF;i++) if($i=="dev-team"&&i<NF){ver=$(i+1);break}; if(ver=="") next; m=ver; gsub(/-pre\./,"~pre.",m); p=($0 ~ /\/cache\/cold-dark-void\/dev-team\//)?1:0; print m "\t" p "\t" $0}' | sort -t $'\t' -k1,1V -k2,2n -k3,3 | tail -1 | cut -f3 | xargs -r dirname | xargs -r dirname )
EPIC_LIB=$(bash "$PDH/skills/plugin-dir.sh" file skills/epic/epic-lib.sh)
bash "$EPIC_LIB" assert-release-allowed "<ISSUE-ID>" || {
  # stderr: epic <ID> is in release=end mode until seal (CDT-141)
  # HALT: no squash, no /release, no land-no-release commit/push, baseline unchanged
  return
}
```

When the ticket is not under a release=end epic, assert exits 0 (unchanged path).

Mid-epic incomplete-child callout (SPEC-025 M16 / CDT-158): `/release` Step 0
after assert succeeds — cite only; this file does not invoke `gap-callout`.
Land-no-release is out of scope for the callout.

## 3. Deterministic BC3 push-target check (AC2 — SPEC-033 N3a)

Before any staging, resolve the push/land target **mechanically** and evaluate BC3. N3a makes
BC3's *evaluation* deterministic here (not judgment); BC3 is still evaluated **unconditionally**
(N3 unchanged) and the token never exempts it — a passing check is a deterministic BC3-*clear*,
not a token-based exemption. Applies to **both** land paths.

```bash
DEFAULT_REF=$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null) || DEFAULT_REF=""
DEFAULT_BRANCH=${DEFAULT_REF##refs/remotes/origin/}
# Land target: main-repo HEAD (release path: branch /release will push;
# land-no-release: worktree baseline — typically origin/HEAD default, not hard-coded "master")
LAND_TARGET=$(git -C "<main-repo-path>" rev-parse --abbrev-ref HEAD 2>/dev/null)
# BC3 halt (fail-closed) iff ANY clause holds — origin/HEAD unresolvable, land
# target != resolved default branch, OR local history has diverged from origin
# (origin default is NOT an ancestor of the target => the push would need --force):
[ -z "$DEFAULT_BRANCH" ] || [ "$DEFAULT_BRANCH" != "$LAND_TARGET" ] \
  || ! git -C "<main-repo-path>" merge-base --is-ancestor "origin/$DEFAULT_BRANCH" "$LAND_TARGET"
```

`LAND_TARGET` is the baseline the action will land on. The disjunction above is BC3 evaluated
mechanically; the **semantics** of each clause — including why an unresolvable `origin/HEAD` is
fail-closed (halt, never a network guess) and the protected-branch framing — live in **N3a** and
are not re-derived here.

On a BC3 halt: write the BC3 halt card via `append-card.sh` (call shape per `self-answer.md` §3f
— not restated), print `ship-choice halt: <rationale> — card: <path>`, and return — **no squash,
no `/release`, no land-no-release commit/push**. A passing check is the ship-*safety* guarantee of
the intent/safety/assurance triad N3a defines; all three must hold before the sequence continues.

## 3.5 Capture ship-start SHA (SPEC-010 H6 / H9; CDT-188)

**Before** squash-stage (§4), open ship window W on the main-repo path. For §5-release, pass this
SHA into `/release` as ambient `SHIP_START_SHA` so Step 0.5 does not re-open W after the fold.
For §5-land-no-release, the same SHA feeds §5.5 `check-ship-history --since`. Cite SPEC-010 H —
do **not** restate D1–D4.

```bash
cd <main-repo-path>
SHIP_START_SHA=$(git rev-parse HEAD)
export SHIP_START_SHA
# /release Step 0.5 honors ambient SHIP_START_SHA (same value for check-ship-history
# --since). Do not re-record after squash-stage or fold commit.
```

## 4. Squash-stage — NO commit yet (shared preflight)

With BC3 clear **and** `SHIP_START_SHA` recorded (§3.5), stage the squash on the
main-repo path **without committing**, and treat an unresolved merge conflict as
a hard stop. Shared by **both** land paths — the commit (if any) happens in §5.

```bash
cd <main-repo-path>
if ! git merge --squash <branch>; then
  # Unresolved squash conflict: restore a clean tree (stages nothing, moves no ref).
  # NOTE: git merge --abort does NOT work here — --squash records no MERGE_HEAD, so
  # abort exits 128 and leaves conflict markers; git reset --hard is the correct undo.
  git reset --hard
  # then write a halt card naming the squash conflict explicitly (append-card.sh call
  # shape per self-answer.md §3f — not restated), print the ship-choice halt line, and
  # return WITHOUT reaching §5 on this path.
  return 1
fi
```

`git merge --squash` moves **no** ref and creates **no** commit — it only stages the branch's
net change into the index, fully reversible with `git reset --hard` (N3a(iii)). On a **conflict**
it exits nonzero and leaves conflict markers staged; because `--squash` records no `MERGE_HEAD`,
the clean-up is `git reset --hard` (not `git merge --abort`, which would exit 128), after which
the sequence writes a squash-conflict **halt** card and returns — it does **not** fall through to
§5.

This path **MUST NOT** run the interactive `git commit` from `/orchestrate` Step 11's
"If squash merge requested (no PR)" block. That block's `git merge --squash` **+ `git commit`**
is the **human** delivery path and stays unchanged; the autopilot merge path no longer routes
through it. Land-no-release lives **only** in this end-state file (not the interactive block).

After a successful stage, **branch on bump** (§5-release vs §5-land-no-release).

## 5. Land paths — branch on `AUTOPILOT_BUMP`

Carry the bump from card #1 (copied through the council-agree path; `ship-gate-council.md` §4).
**NEVER pass `master` to `/release`** (would exit 64 / wrong semantics).

### 5-release — `/release <bump>` when `AUTOPILOT_BUMP` ∈ {patch, minor, major}

**Guard:** only when bump is a release token. Stage-only tree from §4 is the input.

Invoke `/release` with the bump. Ensure `SHIP_START_SHA` from §3.5 is exported so
`/release` Step 0.5 reuses W:

```
SHIP_START_SHA=<from §3.5> /release <AUTOPILOT_BUMP>
```

`/release` is the repo's **single ship-of-record** on this path: it folds the squash-staged
working tree **and** the three version files into **one** `feat|fix: vX.Y.Z — <summary>`
commit, tags it, and pushes to the origin default branch (`skills/release/SKILL.md` lines
11–19, Step 5 commit + Step 5.5 ship-history + Step 6 tag/push — the one-commit-per-release
contract). This procedure adds **no** second commit, tag, or push and does **not** duplicate
`/release`'s pre-commit gates (Steps 4.5–4.10) or its ship-history gate (Step 5.5 / SPEC-010 H).
Those gates are `/release`'s own; if any fails, `/release` aborts before claiming success and
nothing ships as Done (§6), and this sequence resets the squash-staged tree on a pre-commit
abort path (§6.5).

**R5:** this path stages only in §4 — the only commit is `/release`'s fold-commit.

On success → §5.5.

### 5-land-no-release — commit + push when `AUTOPILOT_BUMP` = `master` (CDT-195)

**Guard:** only when bump is the land-no-release sentinel `master`. **MUST NOT** invoke
`/release`, bump version files, create a tag, or edit CHANGELOG.

After §4 squash-stage succeeds on the main-repo path:

```bash
cd <main-repo-path>
# 1) Commit with interactive squash message shape (orchestrate Step 11 "If squash merge
#    requested" — cite, do not fork). Honest Co-Authored-By identity (agent/model actually
#    performing the commit — not hard-coded Claude when the actor is Grok/etc.).
git commit -m "<ISSUE-ID>: <title>

<bullet summary>

Co-Authored-By: <Agent> <noreply@…>"

# 2) Non-force push of the baseline (LAND_TARGET / DEFAULT_BRANCH from §3 — worktree base /
#    origin/HEAD, NOT a hard-coded ref name "master"). BC3 already cleared force-push need.
git push origin "<DEFAULT_BRANCH>"
# MUST NOT: git push --force / --force-with-lease
```

On **commit or push failure**: write a halt card (append-card shape per `self-answer.md` §3f),
print `ship-choice halt: <rationale> — card: <path>`, run §6.5 dirty-tree cleanup as needed,
and return — **no** Done, **no** ship success claim. If commit succeeded but push failed, do
**not** force-push; halt for human (history may need rewrite — SPEC-010 H).

On success → §5.5 (same as release path).

## 5.5 Post-land ship-history re-check (SPEC-010 H5/H8/H9; CDT-188)

**After** the chosen land path reports success (release: committed/tagged/pushed; land-no-release:
committed/pushed) and **before** §6 tracking closeout (Linear **Done**, local backlog close,
`task_complete` ship success): require a clean `check-ship-history.sh` for W. Applies to
**both** land paths. Cite SPEC-010 H1–H12 — **do not** fork D1–D4 here.

```bash
# Fresh shell — re-resolve PDH (SPEC-021 C1). Cross-block env does not carry:
# substitute the literal SHA recorded in §3.5 (same discipline as orchestrate <RUN_ID>).
# lint-ok: C3 — marketplace */ for-loop + -f guarded (SPEC-021 Q2 residual, CDT-82 PDH)
PDH=$( { [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -f "$CLAUDE_PLUGIN_ROOT/skills/plugin-dir.sh" ] && printf '%s\n' "$CLAUDE_PLUGIN_ROOT"; } || { [ -f skills/plugin-dir.sh ] && pwd; } || { for _mp in "$HOME"/.claude/plugins/marketplaces/*/; do [ -f "${_mp}skills/plugin-dir.sh" ] && [ -f "${_mp}agents/pm.md" ] && printf '%s\n' "${_mp%/}" && break; done; } || find ~/.claude/plugins/cache -path '*/dev-team/*/skills/plugin-dir.sh' 2>/dev/null | awk -F/ '{ver=""; for(i=1;i<=NF;i++) if($i=="dev-team"&&i<NF){ver=$(i+1);break}; if(ver=="") next; m=ver; gsub(/-pre\./,"~pre.",m); p=($0 ~ /\/cache\/cold-dark-void\/dev-team\//)?1:0; print m "\t" p "\t" $0}' | sort -t $'\t' -k1,1V -k2,2n -k3,3 | tail -1 | cut -f3 | xargs -r dirname | xargs -r dirname )
CHECK_SHIP=$(bash "$PDH/skills/plugin-dir.sh" file skills/release/check-ship-history.sh)
SHIP_START_SHA="<SHIP_START_SHA>"   # literal from §3.5 — required
[ -n "$SHIP_START_SHA" ] && [ "$SHIP_START_SHA" != "<SHIP_START_SHA>" ] || {
  echo "end-state: SHIP_START_SHA unset — re-run §3.5" >&2
  return 1
}
bash "$CHECK_SHIP" --since "$SHIP_START_SHA" || {
  # Autopilot path (H8): exact halt; no Done / trackers / success claim
  echo "history dirty — rewrite needed"
  # print checker evidence (already on stdout/stderr); write halt card if available
  # MUST NOT: Linear Done, backlog close, Orchestration complete, task_complete ship
  return 1
}
```

- **Exit 0** — clean; continue to §6 closeout.
- **Non-zero / dirty (H8):** halt with the exact phrase `history dirty — rewrite needed`
  plus checker evidence. **MUST NOT** set Linear/backlog **Done**, **MUST NOT** close
  `closes:` trackers, **MUST NOT** claim ship success. No silent force-push / amend / retag.
  Resume only after human confirms a rewrite (interactive H7 via `/release` or manual) or
  history becomes clean on re-check.

## 6. Tracking closeout — AFTER land succeeds **and** ship-history is clean (AC5)

For **this autopilot merge path only** (release **or** land-no-release), the "Tracking
close-out (ship DoD)" block in `/orchestrate` Step 11 runs **after** the land path succeeds
**and** §5.5 ship-history is clean — not before the delivery commit. If the land aborts
(§5-release pre-commit gates, §5-land-no-release commit/push fail) or §5.5 is dirty, the
trackers **stay open** (correct — nothing may be claimed Done). Only once the land has
committed and pushed (and tagged, on release) **and**
`check-ship-history.sh --since $SHIP_START_SHA` exits 0 does autopilot close the `closes:`
trackers (local backlog write-through + Linear **Done** — this path lands on the baseline, so
Done is correct per SPEC-009 Linear lifecycle) exactly as that block specifies.

Every other path keeps the block's **before-commit** ordering for **local** backlog;
**Linear** is path-dependent (SPEC-009 / orchestrate Step 11 lifecycle):
- autopilot **`pr` (PR-stop):** Linear → **In Review** only (MUST NOT Done)
- interactive squash after commit on baseline: Linear → **Done**
- this merge **release** path: Linear → **Done** after `/release` succeeds **and**
  §5.5 ship-history is clean (dirty → halt, trackers stay open)
- this merge **land-no-release** path: Linear → **Done** after commit+push succeeds **and**
  §5.5 ship-history is clean (dirty → halt, trackers stay open)

This procedure reorders the closeout for the autopilot merge path **only** and does not
move or alter the interactive block.

## 6.5 Dirty-tree cleanup on land abort (AC5)

**§5-release abort:** `/release`'s pre-commit gates (Steps 4.5–4.10) each **stop without
committing** and, per `skills/release/SKILL.md`, only instruct the operator to *fix the drift
and re-run until the gate exits 0* — none of them `git reset` or otherwise clean the working
tree. So `/release`'s own abort path does **not** guarantee a clean tree: the squash-staged
index this sequence created in §4 is **left in place** on the main-repo tree. On this path
this sequence therefore **MUST** `git -C <main-repo-path> reset --hard` to discard the
squash-staged index and restore HEAD's tree **before returning control**, so a later run does
not inherit a half-staged working tree. (`git merge --abort` is not usable — the §4 `--squash`
records no `MERGE_HEAD`.)

**§5-land-no-release abort:** on commit failure (or pre-push halt with only a staged squash),
same `git -C <main-repo-path> reset --hard` to discard the staged index. On push failure after
a successful commit: do **not** reset away the commit silently — halt for human; no force-push.

The trackers still stay **open** per §6 — nothing shipped; only the working-tree state is
reset where the land never created a delivery commit.

## 7. Boundaries — what this sequence does NOT do

- **Run for `pr`.** `pr` is the PR-stop end state (create PR, stop, no land); this sequence
  fires only on a post-council effective `merge` (§2).
- **Reuse the interactive `git commit` block.** The Step 11 "If squash merge requested" block
  is the human path and stays byte-unchanged; autopilot land-no-release lives only here (§4/§5b).
- **Call `/release` when bump = `master`.** Land-no-release is commit+push only (§5b).
  **NEVER** `/release master`.
- **Commit/tag/push itself on the release path.** §5-release stages only; sole ref-mutating
  step is `/release` (§5a). Land-no-release **does** commit+push by design (asymmetric).
- **Define the bump vocabulary or re-check the bump.** `merge` is only reachable when
  `autopilot_bump != null` (the self-answer engine is the sole enforcer; `self-answer.md` §4);
  this sequence carries the bump through and branches on token class — it does not re-derive
  the vocabulary.
- **Exempt BC3.** BC3 is evaluated unconditionally and mechanically (§3, N3a); a passing check
  is a BC3-clear, never a token-based exemption.
- **Fire when the council disagreed** or on any non-clean / halted / rerouted answer (§2).
- **Alter the interactive-path or autopilot-`pr` tracking-closeout ordering** — the reorder is
  scoped to the autopilot merge path (§6).
- **Land mid-epic under release=end.** assert-release-allowed forbids **both** release and
  land-no-release until seal (§2.5).
