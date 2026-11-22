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
> | `master` (sentinel) | **§5-land-no-release** | interactive-shape `git commit` on a new `land/<ticket>` branch → non-force `git push` that branch → `train-lib.sh register` — **no** `/release`, default branch unmoved |
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
- **§5-land-no-release (CDT-195; CDT-597):** this procedure itself commits (interactive squash
  message shape) and non-force-pushes a **new `land/<ticket>` branch** cut at the worktree
  baseline, then registers it in the release-train queue — **MUST NOT** invoke `/release`, touch
  version files, tag, or CHANGELOG. Land target = `land/<ticket>`, never the default branch: the
  default-branch tip must equal a release tag at every pushed state (SPEC-033 M2), so an untagged
  fold never moves it. The land target is still never a hard-coded ref named `master`.

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
  **halted (failed / unaudited AC), degraded, or total-failed** (that pass
  forced `halt`/BC7; `ship-gate-council.md`
  §4–§5). No council agreement ⇒ no land.
- It fires **exactly once** per shipped ticket — one squash-stage, one land path
  (one `/release` **or** one land-no-release commit+push).

## 2.5 Epic release=end precheck (CDT-141-C4)

**Before** BC3 / squash / any land (release **or** land-no-release), forbid mid-epic land when
durable epic state has `release_bump` set and seal is not done. **Land-no-release is included** —
`assert-release-allowed` still runs first; mid-epic `bump=master` must not land either.

```bash
# lint-ok: C3 — marketplace */ for-loop + -f guarded (SPEC-021 Q2 residual, CDT-82 PDH)
PDH=$( { [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -f "$CLAUDE_PLUGIN_ROOT/skills/plugin-dir.sh" ] && printf '%s\n' "$CLAUDE_PLUGIN_ROOT"; } || { [ -f skills/plugin-dir.sh ] && [ -f agents/pm.md ] && grep -qF '"name": "dev-team"' .claude-plugin/plugin.json 2>/dev/null && pwd; } || { _pr='${CLAUDE_PLUGIN_ROOT}'; [ "${_pr#\$}" = "$_pr" ] && [ -f "$_pr/skills/plugin-dir.sh" ] && printf '%s\n' "$_pr"; } || { for _mp in "$HOME"/.claude/plugins/marketplaces/*/; do [ -f "${_mp}skills/plugin-dir.sh" ] && [ -f "${_mp}agents/pm.md" ] && grep -qF '"name": "dev-team"' "${_mp}.claude-plugin/plugin.json" 2>/dev/null && printf '%s\n' "${_mp%/}" && break; done; } || find ~/.claude/plugins/cache \( -path '*/dev-team/*/skills/plugin-dir.sh' -o -path '*/dev-team-edge/*/skills/plugin-dir.sh' \) 2>/dev/null | awk -F/ '{ver=""; for(i=1;i<=NF;i++) if(($i=="dev-team"||$i=="dev-team-edge")&&i<NF){ver=$(i+1);break}; if(ver=="") next; m=ver; gsub(/-pre\./,"~pre.",m); p=($0 ~ /\/cache\/cold-dark-void\/dev-team\//)?2:(($0 ~ /\/cache\/cold-dark-void\/dev-team-edge\//)?1:0); print m "\t" p "\t" $0}' | sort -t $'\t' -k1,1V -k2,2n -k3,3 | tail -1 | cut -f3 | xargs -r dirname | xargs -r dirname )
printf 'PDH=%s\n' "$PDH" >&2
EPIC_LIB=$(bash "$PDH/skills/plugin-dir.sh" file skills/epic/epic-lib.sh)
bash "$EPIC_LIB" assert-release-allowed "<ISSUE-ID>" || {
  # stderr: epic <ID> is in release=end mode until seal (CDT-141)
  # HALT: no squash, no /release, no land-no-release commit/push, baseline unchanged
  exit 1
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
# Baseline: main-repo HEAD. Release path — the baseline branch /release pushes.
# Land-no-release (CDT-597) — a NEW land/<ticket> branch cut at the baseline:
# the default branch is never the land target under the sentinel, because the
# default-branch tip must equal a release tag (SPEC-033 M2). The branch name is
# not hard-coded "master" on either path.
BASELINE=$(git -C "<main-repo-path>" rev-parse --abbrev-ref HEAD 2>/dev/null)
LAND_TARGET="$BASELINE"
if [ "<AUTOPILOT_BUMP>" = "master" ]; then
  LAND_TARGET="land/<ISSUE-ID>"
fi
# Land anchor for the ancestry clause: an existing land/<ticket> (a resume) is
# measured on its own tip; a new one is measured at its recorded base, which is
# the baseline HEAD it will be cut from in §5.
LAND_ANCHOR="$LAND_TARGET"
if [ "<AUTOPILOT_BUMP>" = "master" ] \
  && ! git -C "<main-repo-path>" show-ref --verify --quiet "refs/heads/$LAND_TARGET"; then
  LAND_ANCHOR=$(git -C "<main-repo-path>" rev-parse HEAD)
fi
# Fetch BEFORE the ancestor check so origin/$DEFAULT_BRANCH reflects the
# remote's current tip, not a stale local cache (N3a). Empty DEFAULT_BRANCH
# short-circuits the fetch (nothing to fetch); a fetch failure is itself a
# BC3 halt clause below — fail-closed, never a network guess.
FETCH_OK=0
if [ -n "$DEFAULT_BRANCH" ] && git -C "<main-repo-path>" fetch --no-tags origin "$DEFAULT_BRANCH"; then
  FETCH_OK=1
fi
# BC3 halt (fail-closed) iff ANY clause holds — origin/HEAD unresolvable, the
# fetch above failed, the land target is the default branch under the sentinel
# (release path: land target != resolved default branch), OR local history has
# diverged from origin (origin default is NOT an ancestor of the land anchor =>
# the push would need --force):
if [ -z "$DEFAULT_BRANCH" ] || [ "$FETCH_OK" -ne 1 ] \
  || { [ "<AUTOPILOT_BUMP>" = "master" ] && [ "$LAND_TARGET" = "$DEFAULT_BRANCH" ]; } \
  || { [ "<AUTOPILOT_BUMP>" != "master" ] && [ "$DEFAULT_BRANCH" != "$LAND_TARGET" ]; } \
  || ! git -C "<main-repo-path>" merge-base --is-ancestor "origin/$DEFAULT_BRANCH" "$LAND_ANCHOR"; then
  echo "ship-choice halt: BC3 push-target check failed — card: <card-path>"
  exit 1
fi
```

`LAND_TARGET` is the ref the action will land on: the baseline on the release path, and a new
`land/<ticket>` branch under the `master` sentinel (CDT-597). `LAND_ANCHOR` is what the ancestry
clause measures that target against — the land branch's own tip when it already exists (a
`--resume-ship=master` run), and the recorded base (baseline HEAD) when it does not. A
`land/<ticket>` branch that has fallen behind `origin/<default>` fails the same ancestry clause,
so any history that would need `--force` still halts fail-closed; under the sentinel the default
branch itself never satisfies the land target. The disjunction above is BC3 evaluated
mechanically; the **semantics** of each clause — including why an unresolvable `origin/HEAD` is
fail-closed (halt, never a network guess) and the protected-branch framing — live in **N3a** and
are not re-derived here.

On a BC3 halt: the fence above prints `ship-choice halt: <rationale> — card: <path>` and exits
`1` — **no squash, no `/release`, no land-no-release commit/push**. Write the BC3 halt card via
`append-card.sh` (call shape per `self-answer.md` §3f — not restated) for that halt. A passing
check (exit `0`) is the ship-*safety* guarantee of the intent/safety/assurance triad N3a defines;
all three must hold before the sequence continues.

## 3.5 Capture ship-start SHA (SPEC-010 H6 / H9; CDT-188)

**Before** squash-stage (§4), open ship window W on the main-repo path. For §5-release, pass this
SHA into `/release` as ambient `SHIP_START_SHA` so Step 0.5 does not re-open W after the fold.
For §5-land-no-release, the same SHA feeds §5.5 `check-ship-history --since`. Cite SPEC-010 H —
do **not** restate D1–D4.

```bash template
cd <main-repo-path>
SHIP_START_SHA=$(git rev-parse HEAD)
export SHIP_START_SHA
# /release Step 0.5 honors ambient SHIP_START_SHA (same value for check-ship-history
# --since). Do not re-record after squash-stage or fold commit.
if [ "<AUTOPILOT_BUMP>" = "master" ]; then
  PDH="${PDH:-$( { [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -f "$CLAUDE_PLUGIN_ROOT/skills/plugin-dir.sh" ] && printf '%s\n' "$CLAUDE_PLUGIN_ROOT"; } || { [ -f skills/plugin-dir.sh ] && [ -f agents/pm.md ] && grep -qF '"name": "dev-team"' .claude-plugin/plugin.json 2>/dev/null && pwd; } || { _pr='${CLAUDE_PLUGIN_ROOT}'; [ "${_pr#\$}" = "$_pr" ] && [ -f "$_pr/skills/plugin-dir.sh" ] && printf '%s\n' "$_pr"; } || { for _mp in "$HOME"/.claude/plugins/marketplaces/*/; do [ -f "${_mp}skills/plugin-dir.sh" ] && [ -f "${_mp}agents/pm.md" ] && grep -qF '"name": "dev-team"' "${_mp}.claude-plugin/plugin.json" 2>/dev/null && printf '%s\n' "${_mp%/}" && break; done; } || find ~/.claude/plugins/cache \( -path '*/dev-team/*/skills/plugin-dir.sh' -o -path '*/dev-team-edge/*/skills/plugin-dir.sh' \) 2>/dev/null | awk -F/ '{ver=""; for(i=1;i<=NF;i++) if(($i=="dev-team"||$i=="dev-team-edge")&&i<NF){ver=$(i+1);break}; if(ver=="") next; m=ver; gsub(/-pre\./,"~pre.",m); p=($0 ~ /\/cache\/cold-dark-void\/dev-team\//)?2:(($0 ~ /\/cache\/cold-dark-void\/dev-team-edge\//)?1:0); print m "\t" p "\t" $0}' | sort -t $'\t' -k1,1V -k2,2n -k3,3 | tail -1 | cut -f3 | xargs -r dirname | xargs -r dirname )}"
  SHIP_START=$(bash "$PDH/skills/plugin-dir.sh" file skills/release/ship-start.sh)
  # Land-no-release only — /release's own Step 0.5 takes this snapshot on
  # the release path (SHIP_START_SHA ambient); do not double-write there.
  bash "$SHIP_START" >/dev/null || { echo "ship-choice halt: ship-start.sh snapshot failed — card: <card-path>"; exit 1; }
fi
```

## 4. Squash-stage — NO commit yet (shared preflight)

With BC3 clear **and** `SHIP_START_SHA` recorded (§3.5), stage the squash on the
main-repo path **without committing**, and treat an unresolved merge conflict as
a hard stop. Shared by **both** land paths — the commit (if any) happens in §5.

```bash template
cd <main-repo-path>
PDH="${PDH:-$( { [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -f "$CLAUDE_PLUGIN_ROOT/skills/plugin-dir.sh" ] && printf '%s\n' "$CLAUDE_PLUGIN_ROOT"; } || { [ -f skills/plugin-dir.sh ] && [ -f agents/pm.md ] && grep -qF '"name": "dev-team"' .claude-plugin/plugin.json 2>/dev/null && pwd; } || { _pr='${CLAUDE_PLUGIN_ROOT}'; [ "${_pr#\$}" = "$_pr" ] && [ -f "$_pr/skills/plugin-dir.sh" ] && printf '%s\n' "$_pr"; } || { for _mp in "$HOME"/.claude/plugins/marketplaces/*/; do [ -f "${_mp}skills/plugin-dir.sh" ] && [ -f "${_mp}agents/pm.md" ] && grep -qF '"name": "dev-team"' "${_mp}.claude-plugin/plugin.json" 2>/dev/null && printf '%s\n' "${_mp%/}" && break; done; } || find ~/.claude/plugins/cache \( -path '*/dev-team/*/skills/plugin-dir.sh' -o -path '*/dev-team-edge/*/skills/plugin-dir.sh' \) 2>/dev/null | awk -F/ '{ver=""; for(i=1;i<=NF;i++) if(($i=="dev-team"||$i=="dev-team-edge")&&i<NF){ver=$(i+1);break}; if(ver=="") next; m=ver; gsub(/-pre\./,"~pre.",m); p=($0 ~ /\/cache\/cold-dark-void\/dev-team\//)?2:(($0 ~ /\/cache\/cold-dark-void\/dev-team-edge\//)?1:0); print m "\t" p "\t" $0}' | sort -t $'\t' -k1,1V -k2,2n -k3,3 | tail -1 | cut -f3 | xargs -r dirname | xargs -r dirname )}"
GIT_SAFETY=$(bash "$PDH/skills/plugin-dir.sh" file skills/lib/git-safety.sh)
if ! bash "$GIT_SAFETY" is-clean --tracked-only; then
  # write a halt card naming the dirty tracked tree (append-card.sh call shape
  # per self-answer.md §3f — not restated), then halt WITHOUT reaching §5.
  echo "ship-choice halt: main-repo checkout has uncommitted tracked edits — squash refused — card: <card-path>"
  exit 1
fi
SQUASH_BASE=$(git rev-parse HEAD)
if ! git merge --squash <branch>; then
  # Unresolved squash conflict: restore the pre-squash tree (stages nothing,
  # moves no ref) via the shared safety primitive. NOTE: git merge --abort
  # does NOT work here — --squash records no MERGE_HEAD, so abort exits 128
  # and leaves conflict markers. Then write a halt card naming the squash
  # conflict explicitly (append-card.sh call shape per self-answer.md §3f —
  # not restated), print the ship-choice halt line, and exit 1 WITHOUT
  # reaching §5 on this path.
  bash "$GIT_SAFETY" safe-reset --clean-at "$SQUASH_BASE" || echo "end-state: safe-reset refused — halt for human" >&2
  echo "ship-choice halt: squash conflict on <branch> — card: <card-path>"
  exit 1
fi
# CDT-543: fingerprint the squash-staged index NOW, immediately after the
# squash and while the prior-clean attestation still holds. §6.5 passes this
# tree to safe-reset --clean-at, which refuses to reset when the index or the
# working tree has since drifted from it — a tracked edit a user lands on
# main during the run is never discarded by the cleanup.
STAGED_TREE=$(git write-tree) || {
  echo "ship-choice halt: cannot record the squash-staged tree — card: <card-path>"
  exit 1
}
export STAGED_TREE
```

`git merge --squash` moves **no** ref and creates **no** commit — it only stages the branch's
net change into the index. The `is-clean --tracked-only` gate above refuses first when the
main-repo checkout already carries uncommitted tracked edits, so a squash never has to overwrite
uncommitted work that isn't this sequence's to clobber. On a **conflict** it exits nonzero and
leaves conflict markers staged; the clean-up is the shared `safe-reset --clean-at` primitive
(`skills/lib/git-safety.sh` — SPEC-025 M17), which refuses instead of acting when HEAD has moved
off `$SQUASH_BASE` (not `git merge --abort`, which would exit 128), after which the sequence
writes a squash-conflict **halt** card and returns — it does **not** fall through to §5.


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

**CDT-655 pre-keyword guard — runs BEFORE `/release`.** A release token on a
pre-release version refuses: `patch` on `2.0.0-pre.N` would compute the final
`X.Y.Z` and cut the arc mid-flight (SPEC-010 § Pre-release arc scheme P1 — the
CDT-628 failure). The autopilot land step must not compute a version from a
keyword while `plugin.json` carries a pre-release suffix; an explicit-version
release is the only way forward there.

```bash
# Fresh shell — carry PDH from the stanza fence above (SPEC-021 C1)
PDH="${PDH:-$( { [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -f "$CLAUDE_PLUGIN_ROOT/skills/plugin-dir.sh" ] && printf '%s\n' "$CLAUDE_PLUGIN_ROOT"; } || { [ -f skills/plugin-dir.sh ] && [ -f agents/pm.md ] && grep -qF '"name": "dev-team"' .claude-plugin/plugin.json 2>/dev/null && pwd; } || { _pr='${CLAUDE_PLUGIN_ROOT}'; [ "${_pr#\$}" = "$_pr" ] && [ -f "$_pr/skills/plugin-dir.sh" ] && printf '%s\n' "$_pr"; } || { for _mp in "$HOME"/.claude/plugins/marketplaces/*/; do [ -f "${_mp}skills/plugin-dir.sh" ] && [ -f "${_mp}agents/pm.md" ] && grep -qF '"name": "dev-team"' "${_mp}.claude-plugin/plugin.json" 2>/dev/null && printf '%s\n' "${_mp%/}" && break; done; } || find ~/.claude/plugins/cache \( -path '*/dev-team/*/skills/plugin-dir.sh' -o -path '*/dev-team-edge/*/skills/plugin-dir.sh' \) 2>/dev/null | awk -F/ '{ver=""; for(i=1;i<=NF;i++) if(($i=="dev-team"||$i=="dev-team-edge")&&i<NF){ver=$(i+1);break}; if(ver=="") next; m=ver; gsub(/-pre\./,"~pre.",m); p=($0 ~ /\/cache\/cold-dark-void\/dev-team\//)?2:(($0 ~ /\/cache\/cold-dark-void\/dev-team-edge\//)?1:0); print m "\t" p "\t" $0}' | sort -t $'\t' -k1,1V -k2,2n -k3,3 | tail -1 | cut -f3 | xargs -r dirname | xargs -r dirname )}"
PRE_KEYWORD_GUARD=$(bash "$PDH/skills/plugin-dir.sh" file skills/release/refuse-pre-keyword.sh)
if ! bash "$PRE_KEYWORD_GUARD" "<AUTOPILOT_BUMP>"; then
  echo "ship-choice halt: bump keyword refused on a pre-release version — explicit version required (CDT-655) — card: <card-path>"
  exit 1
fi
```

On refusal: no squash invoke, no `/release`, no land — write the halt card
(append-card shape per `self-answer.md` §3f) and stop. Land-no-release
(`bump=master`) is out of scope: the sentinel never computes a version.

Invoke `/release` with the bump. Ensure `SHIP_START_SHA` from §3.5 is exported so
`/release` Step 0.5 reuses W:

```
SHIP_START_SHA=<from §3.5> /release <AUTOPILOT_BUMP>
```

`/release` is the repo's **single ship-of-record** on this path: it folds the squash-staged
working tree **and** the three version files into **one** `feat|fix: vX.Y.Z — <summary>`
commit, tags it, and pushes to the origin default branch (`skills/release/SKILL.md`
Step 5 one commit per release, Step 5.5 ship-history, and Step 6 tag and push — the
one-commit-per-release contract). This procedure adds **no** second commit, tag, or push and does **not** duplicate
`/release`'s pre-commit gates (Steps 4.5–4.10) or its ship-history gate (Step 5.5 / SPEC-010 H).
Those gates are `/release`'s own; if any fails, `/release` aborts before claiming success and
nothing ships as Done (§6), and this sequence runs the §6.5 block on a pre-commit
abort path.

**R5:** this path stages only in §4 — the only commit is `/release`'s fold-commit.

On success → §5.5.

### 5-land-no-release — commit + push a `land/<ticket>` branch when `AUTOPILOT_BUMP` = `master` (CDT-195; CDT-597)

**Guard:** only when bump is the land-no-release sentinel `master`. **MUST NOT** invoke
`/release`, bump version files, create a tag, or edit CHANGELOG.

**Land target (CDT-597):** a new `land/<ticket>` branch cut at the baseline. The default branch
stays put — its tip must equal a release tag at every pushed state (SPEC-033 M2), and an untagged
fold commit is not a tag. After the push, the branch is **registered** in the release-train queue
(`train-lib.sh register … --bump patch`) and the registered order is printed. Registration is
**queue-only**: no `/release`, no `order`/`freeze`/`set-status`, no landing loop — the next
`/release` folds the branch through SPEC-023 and its fold commit is the tag.

After §4 squash-stage succeeds on the main-repo path:

```bash template
cd <main-repo-path>
BASELINE_BRANCH=$(git rev-parse --abbrev-ref HEAD)

# 1) Cut the land branch AT the baseline (CDT-597). The default branch does not
#    move: its tip must equal a release tag, so an untagged fold lands on
#    land/<ticket> and folds through the release train (SPEC-033 M2). The §4
#    squash-staged index carries onto the new branch.
git checkout -q -b "land/<ISSUE-ID>"

# 2) Commit with interactive squash message shape (orchestrate Step 11 "If squash merge
#    requested" — cite, do not fork). Honest Co-Authored-By identity (agent/model actually
#    performing the commit — not hard-coded Claude when the actor is Grok/etc.).
git commit -m "<ISSUE-ID>: <title>

<bullet summary>

Co-Authored-By: <Agent> <noreply@…>"

# 3) Non-force push of the land branch (LAND_TARGET from §3). BC3 already cleared
#    the force-push need. The default branch is never pushed on this path.
git push origin "land/<ISSUE-ID>"
# MUST NOT: git push --force / --force-with-lease

# 4) Register the land branch in the release-train queue — queue-only (CDT-597):
#    no /release, no order/freeze/set-status, no landing loop here. The next
#    /release folds the branch and that fold commit is the tag (SPEC-023).
# Fresh shell — carry PDH from the stanza fence above (SPEC-021 C1)
PDH="${PDH:-$( { [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -f "$CLAUDE_PLUGIN_ROOT/skills/plugin-dir.sh" ] && printf '%s\n' "$CLAUDE_PLUGIN_ROOT"; } || { [ -f skills/plugin-dir.sh ] && [ -f agents/pm.md ] && grep -qF '"name": "dev-team"' .claude-plugin/plugin.json 2>/dev/null && pwd; } || { _pr='${CLAUDE_PLUGIN_ROOT}'; [ "${_pr#\$}" = "$_pr" ] && [ -f "$_pr/skills/plugin-dir.sh" ] && printf '%s\n' "$_pr"; } || { for _mp in "$HOME"/.claude/plugins/marketplaces/*/; do [ -f "${_mp}skills/plugin-dir.sh" ] && [ -f "${_mp}agents/pm.md" ] && grep -qF '"name": "dev-team"' "${_mp}.claude-plugin/plugin.json" 2>/dev/null && printf '%s\n' "${_mp%/}" && break; done; } || find ~/.claude/plugins/cache \( -path '*/dev-team/*/skills/plugin-dir.sh' -o -path '*/dev-team-edge/*/skills/plugin-dir.sh' \) 2>/dev/null | awk -F/ '{ver=""; for(i=1;i<=NF;i++) if(($i=="dev-team"||$i=="dev-team-edge")&&i<NF){ver=$(i+1);break}; if(ver=="") next; m=ver; gsub(/-pre\./,"~pre.",m); p=($0 ~ /\/cache\/cold-dark-void\/dev-team\//)?2:(($0 ~ /\/cache\/cold-dark-void\/dev-team-edge\//)?1:0); print m "\t" p "\t" $0}' | sort -t $'\t' -k1,1V -k2,2n -k3,3 | tail -1 | cut -f3 | xargs -r dirname | xargs -r dirname )}"
TRAIN_LIB=$(bash "$PDH/skills/plugin-dir.sh" file skills/release-train/train-lib.sh)
if ! bash "$TRAIN_LIB" register "land/<ISSUE-ID>" --bump patch; then
  echo "ship-choice halt: release-train register failed for land/<ISSUE-ID> — card: <card-path>"
  exit 1
fi

# 5) Print the registered order, then hand the main-repo path back its baseline.
bash "$TRAIN_LIB" list | jq -r --arg b "land/<ISSUE-ID>" '
  (.entries | map(.branch)) as $names
  | "land-no-release: registered \($b) — queue position \(((($names | index($b)) // -1) + 1)) of \($names | length) — queue: \($names | join(", ")) — the train folds it (SPEC-023)"'
git checkout -q "$BASELINE_BRANCH"
```

On **commit, push, or register failure**: write a halt card (append-card shape per
`self-answer.md` §3f), print `ship-choice halt: <rationale> — card: <path>`, run the §6.5 block
as needed, and return — **no** Done, **no** ship success claim. If commit succeeded but push failed, do
**not** force-push; halt for human (history may need rewrite — SPEC-010 H). A register failure
(already-queued branch, missing `jq`, unwritable queue) leaves the pushed land branch in place for
a human to re-register — the queue is the only writer of the fold, so nothing ships unregistered.

On success (commit + push + register) → §5.5 (same as release path).

## 5.5 Post-land ship-history re-check (SPEC-010 H5/H8/H9; CDT-188)

**After** the chosen land path reports success (release: committed/tagged/pushed; land-no-release:
committed/pushed) and **before** §6 tracking closeout (Linear **Done**, local backlog close,
`task_complete` ship success): require a clean `check-ship-history.sh` for W. Applies to
**both** land paths. Cite SPEC-010 H1–H12 — **do not** fork D1–D4 here.

```bash
# Fresh shell — carry PDH from the stanza fence above (SPEC-021 C1). Cross-block env does not carry:
# substitute the literal SHA recorded in §3.5 (same discipline as orchestrate <RUN_ID>).
PDH="${PDH:-$( { [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -f "$CLAUDE_PLUGIN_ROOT/skills/plugin-dir.sh" ] && printf '%s\n' "$CLAUDE_PLUGIN_ROOT"; } || { [ -f skills/plugin-dir.sh ] && [ -f agents/pm.md ] && grep -qF '"name": "dev-team"' .claude-plugin/plugin.json 2>/dev/null && pwd; } || { _pr='${CLAUDE_PLUGIN_ROOT}'; [ "${_pr#\$}" = "$_pr" ] && [ -f "$_pr/skills/plugin-dir.sh" ] && printf '%s\n' "$_pr"; } || { for _mp in "$HOME"/.claude/plugins/marketplaces/*/; do [ -f "${_mp}skills/plugin-dir.sh" ] && [ -f "${_mp}agents/pm.md" ] && grep -qF '"name": "dev-team"' "${_mp}.claude-plugin/plugin.json" 2>/dev/null && printf '%s\n' "${_mp%/}" && break; done; } || find ~/.claude/plugins/cache \( -path '*/dev-team/*/skills/plugin-dir.sh' -o -path '*/dev-team-edge/*/skills/plugin-dir.sh' \) 2>/dev/null | awk -F/ '{ver=""; for(i=1;i<=NF;i++) if(($i=="dev-team"||$i=="dev-team-edge")&&i<NF){ver=$(i+1);break}; if(ver=="") next; m=ver; gsub(/-pre\./,"~pre.",m); p=($0 ~ /\/cache\/cold-dark-void\/dev-team\//)?2:(($0 ~ /\/cache\/cold-dark-void\/dev-team-edge\//)?1:0); print m "\t" p "\t" $0}' | sort -t $'\t' -k1,1V -k2,2n -k3,3 | tail -1 | cut -f3 | xargs -r dirname | xargs -r dirname )}"
CHECK_SHIP=$(bash "$PDH/skills/plugin-dir.sh" file skills/release/check-ship-history.sh)
SHIP_START_SHA="<SHIP_START_SHA>"   # literal from §3.5 — required
[ -n "$SHIP_START_SHA" ] && [ "$SHIP_START_SHA" != "<SHIP_START_SHA>" ] || {
  echo "end-state: SHIP_START_SHA unset — re-run §3.5" >&2
  exit 1
}
if [ "<AUTOPILOT_BUMP>" = "master" ]; then
  # Land-no-release: also check the D4 tag-retarget snapshot half, via the
  # §3.5 snapshot recomputed deterministically from the same SHA (cross-block
  # env does not carry, so this is --path, never the printed TAG_SNAPSHOT=
  # line from a different shell).
  SHIP_START=$(bash "$PDH/skills/plugin-dir.sh" file skills/release/ship-start.sh)
  SNAP=$(bash "$SHIP_START" --path "$SHIP_START_SHA") || {
    echo "end-state: ship-start.sh --path failed — halt" >&2
    exit 1
  }
  [ -r "$SNAP" ] || {
    echo "end-state: tag snapshot missing ($SNAP) — halt" >&2
    exit 1
  }
  if bash "$CHECK_SHIP" --since "$SHIP_START_SHA" --tag-snapshot "$SNAP"; then
    bash "$SHIP_START" --clear || echo "end-state: ship-start.sh --clear failed (non-fatal)" >&2
  else
    # Autopilot path (H8): exact halt; no Done / trackers / success claim
    echo "history dirty — rewrite needed"
    exit 1
  fi
else
  # Release: /release Step 5.5 (post-fold, pre-tag) and Step 6 (post-tag,
  # post-push) already own the ship-history authority for this path,
  # including the D4 tag-retarget snapshot half — this --since check is a
  # pre-fold sanity re-check only, not a second authority.
  bash "$CHECK_SHIP" --since "$SHIP_START_SHA" || {
    # Autopilot path (H8): exact halt; no Done / trackers / success claim
    echo "history dirty — rewrite needed"
    exit 1
  }
fi
```

- **Exit 0** — clean; continue to §6 closeout.
- **Non-zero / dirty (H8):** halt with the exact phrase `history dirty — rewrite needed`
  plus checker evidence. **MUST NOT** set Linear/backlog **Done**, **MUST NOT** close
  `closes:` trackers, **MUST NOT** claim ship success. No silent force-push / amend / retag.
  Resume only after human confirms a rewrite (interactive H7 via `/release` or manual) or
  history becomes clean on re-check.
- **Release-path authority:** `/release` Step 5.5 and Step 6 (`skills/release/SKILL.md`) are
  the ship-history authority on the release path — post-tag, post-push, and the D4
  tag-retarget snapshot half. This fence's release-path `--since` check is a pre-fold sanity
  re-check only; it does not pass `--tag-snapshot` and does not duplicate that authority.

## 6. Tracking closeout — AFTER land succeeds **and** ship-history is clean (AC5)

For **this autopilot merge path only** (release **or** land-no-release), the "Tracking
close-out (ship DoD)" block in `/orchestrate` Step 11 runs **after** the land path succeeds
**and** §5.5 ship-history is clean — not before the delivery commit. If the land aborts
(§5-release pre-commit gates, §5-land-no-release commit/push fail) or §5.5 is dirty, the
trackers **stay open** (correct — nothing may be claimed Done). Only once the land has
committed and pushed (and tagged, on release) **and**
`check-ship-history.sh --since $SHIP_START_SHA` exits 0 does autopilot close the `closes:`
trackers (local backlog write-through + Linear **Done** — this path lands on a registered
`land/<ticket>` branch that the next `/release` folds, so Done is correct per SPEC-009 Linear
lifecycle) exactly as that block specifies.

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
and re-run until the gate exits 0* — none of them clean the working tree themselves. So
`/release`'s own abort path does **not** guarantee a clean tree: the squash-staged index this
sequence created in §4 is **left in place** on the main-repo tree. On this path this sequence
therefore **MUST run the §6.5 block** below to discard the squash-staged index and restore
HEAD's tree **before returning control**, so a later run does not inherit a half-staged working
tree. (`git merge --abort` is not usable — the §4 `--squash` records no `MERGE_HEAD`.)
**Attestation outcome (CDT-543):** `/release` Step 3 edits the version pair (unstaged) before
the gates run, so on an abort after Step 3 the working tree no longer matches the §4
fingerprint and the attested reset **refuses — halt for a human, not an automatic restore**.
The operator resolves by hand (discard the staged squash and the mechanical version-pair edits,
keep anything they recognize as their own) and re-runs; a tracked edit a user landed during the
run gets the same refusal and is never discarded automatically.

**§5-land-no-release abort:** on commit failure (or pre-push halt with only a staged squash),
run the §6.5 block below to discard the staged index. On the land path the abort leaves the
half-created `land/<ticket>` branch for a human to delete or re-register — this block resets the
working tree only, it never deletes a branch. On push failure after a successful
commit: run the §6.5 block below too — `SHIP_START_SHA` no longer equals HEAD once the delivery
commit has moved it, so the block's own attestation check refuses instead of acting and halts
for human; the commit is never silently discarded and no force-push follows.

```bash template
cd <main-repo-path>
PDH="${PDH:-$( { [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -f "$CLAUDE_PLUGIN_ROOT/skills/plugin-dir.sh" ] && printf '%s\n' "$CLAUDE_PLUGIN_ROOT"; } || { [ -f skills/plugin-dir.sh ] && [ -f agents/pm.md ] && grep -qF '"name": "dev-team"' .claude-plugin/plugin.json 2>/dev/null && pwd; } || { _pr='${CLAUDE_PLUGIN_ROOT}'; [ "${_pr#\$}" = "$_pr" ] && [ -f "$_pr/skills/plugin-dir.sh" ] && printf '%s\n' "$_pr"; } || { for _mp in "$HOME"/.claude/plugins/marketplaces/*/; do [ -f "${_mp}skills/plugin-dir.sh" ] && [ -f "${_mp}agents/pm.md" ] && grep -qF '"name": "dev-team"' "${_mp}.claude-plugin/plugin.json" 2>/dev/null && printf '%s\n' "${_mp%/}" && break; done; } || find ~/.claude/plugins/cache \( -path '*/dev-team/*/skills/plugin-dir.sh' -o -path '*/dev-team-edge/*/skills/plugin-dir.sh' \) 2>/dev/null | awk -F/ '{ver=""; for(i=1;i<=NF;i++) if(($i=="dev-team"||$i=="dev-team-edge")&&i<NF){ver=$(i+1);break}; if(ver=="") next; m=ver; gsub(/-pre\./,"~pre.",m); p=($0 ~ /\/cache\/cold-dark-void\/dev-team\//)?2:(($0 ~ /\/cache\/cold-dark-void\/dev-team-edge\//)?1:0); print m "\t" p "\t" $0}' | sort -t $'\t' -k1,1V -k2,2n -k3,3 | tail -1 | cut -f3 | xargs -r dirname | xargs -r dirname )}"
GIT_SAFETY=$(bash "$PDH/skills/plugin-dir.sh" file skills/lib/git-safety.sh)
SHIP_START_SHA="<SHIP_START_SHA>"   # literal from §3.5 — required
[ -n "$SHIP_START_SHA" ] && [ "$SHIP_START_SHA" != "<SHIP_START_SHA>" ] || {
  echo "end-state: SHIP_START_SHA unset — re-run §3.5" >&2
  exit 1
}
STAGED_TREE="<STAGED_TREE>"   # literal from §4 — required (git write-tree after the squash)
[ -n "$STAGED_TREE" ] && [ "$STAGED_TREE" != "<STAGED_TREE>" ] || {
  echo "end-state: STAGED_TREE unset — re-run §4" >&2
  exit 1
}
bash "$GIT_SAFETY" safe-reset --clean-at "$SHIP_START_SHA" "$STAGED_TREE"; RC=$?
if [ "$RC" -ne 0 ]; then
  # git-safety's stderr distinguishes the refusal (HEAD moved / index drift /
  # working-tree drift — e.g. /release Step 3's own version-pair edits, or a
  # tracked edit a user landed during the run). Either way: no reset, halt.
  echo "ship-choice halt: attested cleanup refused (rc=$RC — see git-safety stderr above) — no reset; halt for human — card: <card-path>"
  exit 1
fi
```

The reset is **attested** (CDT-543): §4 fingerprints the squash-staged index with
`git write-tree` immediately after the squash, and `safe-reset --clean-at` refuses (exit 1,
no reset) unless the index **and** the working tree still match that recorded tree. A tracked
edit a user lands on main between the §4 prior-clean gate and this cleanup is therefore never
discarded — the sequence halts for a human instead. The HEAD-equals-`SHIP_START_SHA` check
still refuses when a delivery commit exists (push-failure-after-commit path).

The trackers still stay **open** per §6 — nothing shipped; only the working-tree state is
reset where the land never created a delivery commit.


## 7. Boundaries — what this sequence does NOT do

- **Run for `pr`.** `pr` is the PR-stop end state (create PR, stop, no land); this sequence
  fires only on a post-council effective `merge` (§2).
- **Reuse the interactive `git commit` block.** The Step 11 "If squash merge requested" block
  is the human path and stays byte-unchanged; autopilot land-no-release lives only here (§4/§5-land-no-release).
- **Call `/release` when bump = `master`.** Land-no-release is commit + non-force push of the
  `land/<ticket>` branch + queue registration only (§5-land-no-release).
  **NEVER** `/release master`.
- **Advance the release train on the land-no-release path.** Registration is queue-only: no
  `order`/`freeze`/`set-status`, no landing loop, no `/release` (CDT-597 AC E). The train's own
  landing loop and the next `/release` own the fold and the tag (SPEC-023).
- **Commit/tag/push itself on the release path.** §5-release stages only; sole ref-mutating
  step is `/release` (§5-release). Land-no-release **does** commit+push by design (asymmetric).
- **Define the bump vocabulary or re-check the bump.** `merge` is only reachable when
  `autopilot_bump != null` (the self-answer engine is the sole enforcer; `self-answer.md` §4);
  this sequence carries the bump through and branches on token class — it does not re-derive
  the vocabulary.
- **Exempt BC3.** BC3 is evaluated unconditionally and mechanically (§3, N3a); a passing check
  is a BC3-clear, never a token-based exemption.
- **Fire when the council halted the ship** or on any non-clean / halted / rerouted answer (§2).
- **Alter the interactive-path or autopilot-`pr` tracking-closeout ordering** — the reorder is
  scoped to the autopilot merge path (§6).
- **Land mid-epic under release=end.** assert-release-allowed forbids **both** release and
  land-no-release until seal (§2.5).
