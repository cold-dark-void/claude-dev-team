# Autopilot release end-state sequence (CDT-111-C9)

> **Companion to `skills/autopilot/SKILL.md`, `skills/autopilot/self-answer.md`, and
> `skills/autopilot/ship-gate-council.md`.** This file is a *procedure*, not a *policy*.
> It describes the operational sequence autopilot follows to execute the **release end
> state** — a squash-stage plus `/release` — once a ship-choice answer has been auto-decided
> and audited. It wires no caller and defines no new script; `/orchestrate` Step 11 invokes
> it. The clean triad is `self-answer.md` (answer the gate) → `ship-gate-council.md` (audit
> the answer) → `end-state.md` (execute the ship).

## 1. Purpose + contract-home stance

The normative contract for this end state is **SPEC-033 N3/N3a** (the deterministic BC3
push-target check) together with **M14** (the council pass that must have agreed) and **M2/N3**
(the `--autopilot=<bump>` ship token that authorizes `merge`). The single ship-of-record for
the ref-mutating step is **`/release`** (`skills/release/SKILL.md`) with its own one-commit
contract and pre-commit gates. **This procedure cites those homes by name/ordinal and never
restates or forks them** (SPEC-002 D1 / SPEC-033 M12 / N4 — the same contract-home discipline
`self-answer.md` §1 and `ship-gate-council.md` §1 follow). In particular it does **not**
reproduce the BC3 definition, the M6 blocking-condition taxonomy, `/release`'s step list or
version-sync gates, or the interactive squash block's commit shape — it points at each home.

What this procedure adds on top of the frozen contract is the **operational sequence**: fire on
a post-council effective `merge`, run the mechanical BC3 push-target check, squash-stage without
committing, delegate the sole ref-mutating step to `/release`, and reorder the tracking closeout
to run after `/release` succeeds.

## 2. Firing check

This sequence fires **only** on a **post-council effective `merge`** decision — i.e.
`self-answer.md`'s ship-choice engine returned a clean `merge` card #1 (`autopilot_bump != null`,
`blocking_condition = null`; §4/§3e of `self-answer.md`) **and** `ship-gate-council.md`'s pass
**agreed** (card #2 kept `merge`; conf ≥ 80, non-degraded). It runs on the main-repo path where
`/orchestrate` Step 11 dispatches the effective decision.

- It **never** fires on `pr` — that is the PR-stop end state (create PR, then stop; no
  `/release`). `pr` and `merge` are mutually exclusive ship-choice terminals.
- It **never** fires on a `halt` / `reroute-epic` answer, nor on a `merge` whose council pass
  **disagreed / degraded / total-failed** (that pass forced `halt`/BC7; `ship-gate-council.md`
  §4–§5). No council agreement ⇒ no release.
- It fires **exactly once** per shipped ticket — one squash-stage, one `/release`.

## 2.5 Epic release=end precheck (CDT-141-C4)

**Before** BC3 / squash / `/release`, forbid mid-epic land when durable epic
state has `release_bump` set and seal is not done:

```bash
# lint-ok: C3 — marketplace */ for-loop + -f guarded (SPEC-021 Q2 residual, CDT-82 PDH)
PDH=$( { [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -f "$CLAUDE_PLUGIN_ROOT/skills/plugin-dir.sh" ] && printf '%s\n' "$CLAUDE_PLUGIN_ROOT"; } || { [ -f skills/plugin-dir.sh ] && pwd; } || { for _mp in "$HOME"/.claude/plugins/marketplaces/*/; do [ -f "${_mp}skills/plugin-dir.sh" ] && [ -f "${_mp}agents/pm.md" ] && printf '%s\n' "${_mp%/}" && break; done; } || find ~/.claude/plugins/cache -path '*/dev-team/*/skills/plugin-dir.sh' 2>/dev/null | awk -F/ '{ver=""; for(i=1;i<=NF;i++) if($i=="dev-team"&&i<NF){ver=$(i+1);break}; if(ver=="") next; m=ver; gsub(/-pre\./,"~pre.",m); p=($0 ~ /\/cache\/cold-dark-void\/dev-team\//)?1:0; print m "\t" p "\t" $0}' | sort -t $'\t' -k1,1V -k2,2n -k3,3 | tail -1 | cut -f3 | xargs -r dirname | xargs -r dirname )
EPIC_LIB=$(bash "$PDH/skills/plugin-dir.sh" file skills/epic/epic-lib.sh)
bash "$EPIC_LIB" assert-release-allowed "<ISSUE-ID>" || {
  # stderr: epic <ID> is in release=end mode until seal (CDT-141)
  # HALT: no squash, no /release, master unchanged
  return
}
```

When the ticket is not under a release=end epic, assert exits 0 (unchanged path).

## 3. Deterministic BC3 push-target check (AC2 — SPEC-033 N3a)

Before any staging, resolve the push target **mechanically** and evaluate BC3. N3a makes BC3's
*evaluation* deterministic here (not judgment); BC3 is still evaluated **unconditionally** (N3
unchanged) and the bump never exempts it — a passing check is a deterministic BC3-*clear*, not a
bump-based exemption.

```bash
DEFAULT_REF=$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null) || DEFAULT_REF=""
DEFAULT_BRANCH=${DEFAULT_REF##refs/remotes/origin/}
RELEASE_TARGET=$(git -C "<main-repo-path>" rev-parse --abbrev-ref HEAD 2>/dev/null)
# BC3 halt (fail-closed) iff ANY clause holds — origin/HEAD unresolvable, release
# target != resolved default branch, OR local history has diverged from origin
# (origin default is NOT an ancestor of the target => the push would need --force):
[ -z "$DEFAULT_BRANCH" ] || [ "$DEFAULT_BRANCH" != "$RELEASE_TARGET" ] \
  || ! git -C "<main-repo-path>" merge-base --is-ancestor "origin/$DEFAULT_BRANCH" "$RELEASE_TARGET"
```

`RELEASE_TARGET` is the branch `/release` will push (`skills/release/SKILL.md` Step 6 pushes
`origin "$BRANCH" --tags`, `BRANCH = git rev-parse --abbrev-ref HEAD` on the main-repo path). The
disjunction above is BC3 evaluated mechanically; the **semantics** of each clause — including why
an unresolvable `origin/HEAD` is fail-closed (halt, never a network guess) and the
protected-branch framing — live in **N3a** and are not re-derived here.

On a BC3 halt: write the BC3 halt card via `append-card.sh` (call shape per `self-answer.md` §3f
— not restated), print `ship-choice halt: <rationale> — card: <path>`, and return — **no squash,
no `/release`**. A passing check is the ship-*safety* guarantee of the intent/safety/assurance
triad N3a defines; all three must hold before the sequence continues.

## 4. Squash-stage — NO commit (AC3/AC4)

With BC3 clear, stage the squash on the main-repo path **without committing**, and treat an
unresolved merge conflict as a hard stop:

```bash
cd <main-repo-path>
if ! git merge --squash <branch>; then
  # Unresolved squash conflict: restore a clean tree (stages nothing, moves no ref).
  # NOTE: git merge --abort does NOT work here — --squash records no MERGE_HEAD, so
  # abort exits 128 and leaves conflict markers; git reset --hard is the correct undo.
  git reset --hard
  # then write a halt card naming the squash conflict explicitly (append-card.sh call
  # shape per self-answer.md §3f — not restated), print the ship-choice halt line, and
  # return WITHOUT reaching the /release invocation in §5 on this path.
  return 1
fi
```

`git merge --squash` moves **no** ref and creates **no** commit — it only stages the branch's
net change into the index, fully reversible with `git reset --hard` (N3a(iii)). On a **conflict**
it exits nonzero and leaves conflict markers staged; because `--squash` records no `MERGE_HEAD`,
the clean-up is `git reset --hard` (not `git merge --abort`, which would exit 128), after which
the sequence writes a squash-conflict **halt** card and returns — it does **not** fall through to
`/release` (§5).
This path **MUST NOT** run the interactive `git commit` from `/orchestrate` Step 11's
"If squash merge requested (no PR)" block. That block's `git merge --squash` **+ `git commit`**
is the **human** delivery path and stays unchanged; the autopilot merge path no longer routes
through it. Adding a `git commit` here would produce a **double commit** (this commit, then
`/release`'s own fold-commit) — the R5 hazard this wiring exists to prevent. The only commit on
this path is `/release`'s single fold-commit (§5).

## 5. Delegate the ship to `/release <bump>` (AC3/AC10)

Invoke `/release` with the bump carried forward from card #1 (copied through the council-agree
path; `ship-gate-council.md` §4):

```
/release <AUTOPILOT_BUMP>
```

`/release` is the repo's **single ship-of-record**: it folds the squash-staged working tree
**and** the three version files into **one** `feat|fix: vX.Y.Z — <summary>` commit, tags it, and
pushes to the origin default branch (`skills/release/SKILL.md` lines 11–19, Step 5 commit + Step
6 tag/push — the one-commit-per-release contract). This procedure adds **no** second commit, tag,
or push and does **not** duplicate `/release`'s pre-commit gates (Steps 4.5–4.10: include-drift,
council template-vars, hook-template hygiene, skill-bash lint, docs-drift, smoke). Those gates
are `/release`'s own; if any fails, `/release` aborts before committing and nothing ships (§6),
and this sequence resets the squash-staged tree on that abort path (§6.5).

## 6. Tracking closeout — AFTER `/release` succeeds (AC5)

For **this autopilot merge path only**, the "Tracking close-out (ship DoD)" block in
`/orchestrate` Step 11 runs **after** `/release` succeeds — not before the delivery commit. If
`/release` aborts at one of its pre-commit gates (§5), the release never commits, so the trackers
**stay open** (correct — nothing shipped; closing them would falsely mark a ship that never
happened). Only once `/release` has committed, tagged, and pushed does autopilot close the
`closes:` trackers (local backlog write-through + Linear **Done** — this path lands on
master, so Done is correct per SPEC-009 Linear lifecycle) exactly as that block specifies.

Every other path keeps the block's **before-commit** ordering for **local** backlog;
**Linear** is path-dependent (SPEC-009 / orchestrate Step 11 lifecycle):
- autopilot **`pr` (PR-stop):** Linear → **In Review** only (MUST NOT Done)
- interactive squash after commit on master: Linear → **Done**
- this merge/`/release` path: Linear → **Done** after `/release` succeeds

This procedure reorders the closeout for the autopilot merge path **only** and does not
move or alter the interactive block.

## 6.5 Dirty-tree cleanup when `/release` aborts at a gate (AC5)

`/release`'s pre-commit gates (Steps 4.5–4.10) each **stop without committing** and, per
`skills/release/SKILL.md`, only instruct the operator to *fix the drift and re-run until the gate
exits 0* — none of them `git reset` or otherwise clean the working tree. So `/release`'s own
abort path does **not** guarantee a clean tree: the squash-staged index this sequence created in
§4 is **left in place** on the main-repo tree. On this path this sequence therefore **MUST**
`git -C <main-repo-path> reset --hard` to discard the squash-staged index and restore HEAD's tree
**before returning control**, so a later run does not inherit a half-staged working tree. (`git
merge --abort` is not usable — the §4 `--squash` records no `MERGE_HEAD`.) The trackers still stay
**open** per §6 — nothing shipped; only the working-tree state is reset here.

## 7. Boundaries — what this sequence does NOT do

- **Run for `pr`.** `pr` is the PR-stop end state (create PR, stop, no `/release`); this sequence
  fires only on a post-council effective `merge` (§2).
- **Reuse the interactive `git commit`.** The Step 11 "If squash merge requested" commit is the
  human path and stays byte-unchanged; the autopilot path stages-only and defers the commit to
  `/release` (§4).
- **Commit, tag, or push itself.** The sole ref-mutating step is `/release`'s (§5); this sequence
  never adds a second commit/tag/push.
- **Define the bump vocabulary or re-check the bump.** `merge` is only reachable when
  `autopilot_bump != null` (the self-answer engine is the sole enforcer; `self-answer.md` §4);
  this sequence carries the bump through, it does not re-derive or validate it.
- **Exempt BC3.** BC3 is evaluated unconditionally and mechanically (§3, N3a); a passing check is
  a BC3-clear, never a bump-based exemption.
- **Fire when the council disagreed** or on any non-clean / halted / rerouted answer (§2).
- **Alter the interactive-path or autopilot-`pr` tracking-closeout ordering** — the reorder is
  scoped to the autopilot merge path (§6).
