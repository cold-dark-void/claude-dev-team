# Gate self-answer engine — acceptance-test scenario fixtures (CDT-111-C3)

> **Companion acceptance bar for `skills/autopilot/self-answer.md`.** Authored by QA,
> **independently** of the engine's implementer (ic5), per the plan's authoring-ownership
> separation. Each fixture is a concrete input envelope + gate-specific signals mapped to an
> expected `{decision, blocking_condition}` and the exact `append-card.sh` call the engine must
> emit. Every fixture was **walked against the actual procedure text** in `self-answer.md` and
> the actual behavior of `budget-check.sh` / `append-card.sh` — not asserted. See
> **§ Walkthrough results** for the live-run evidence and **§ Gaps found** for what the walk
> surfaced.

## How to read a fixture

- **Envelope** — the §2 input the caller supplies.
- **Gate signals** — the §2 gate-specific signals the caller supplies (never disk-read).
- **BC walk** — the BC1→BC8 canonical-ordinal, first-match-wins evaluation of `self-answer.md`
  §3d, listing why each earlier BC drops (out-of-gate) or clears (evaluated, no match) so the
  target BC is genuinely the first match.
- **Expected** — `{decision, blocking_condition, confidence, bump}` per §3e.
- **Card** — the exact `append-card.sh` call shape (§3f) the engine must emit. `decided_by` is
  **always `auto`** (§3f), including when `max_loc` is non-null. Arg order:
  `<workflow> <ticket_id> <gate> <decision> <decided_by> <bump|null> <confidence>
  <blocking_condition|null> <run_id> <iteration> <wall_clock_s> <actor> <rationale>
  [<max_loc>]`.
  Omit / `max_loc` null → **argc 13** (writer records `max_loc: null`). Non-null override →
  **argc 14** (`<max_loc>` after rationale; council pair null). Argc 15/16 (council pair)
  belong to the M14 council card alone (`ship-gate-council.md` §6), which this engine never
  writes. When `max_loc` is non-null, `rationale` MUST mention the override (M13).

**Shared symbols.** `NOW` = wall-clock epoch at engine run. `RS` = `run_start_epoch`. Where a
fixture is within budget it uses `RS = NOW-60` (`wall_clock_s = 60`); `run_id = ap-<RS>`;
`actor = orchestrator`; `ticket_id = CDT-200`. `wall_clock_s` is a pass-through from
`budget-check.sh` (§3b), so its literal value is whatever `NOW - RS` yields at run time — the
fixtures pin the **relative** offset, not an absolute epoch.

**Ordinal vs. checklist-index note.** The M4 per-gate checklists are written in canonical
BC-ordinal order already, but they *skip* BCs that don't apply to that gate (e.g. plan-approve
has no BC2). "First match in canonical ordinal order, dropping inapplicable BCs" (§3d) is the
governing rule; the checklist steps are that same order with the gaps removed.

---

## Group A — one fixture per blocking condition (BC1–BC8)

### F1 — BC1 genuine ambiguity → halt

- **Envelope**: `workflow=orchestrate, gate=scope-confirm, iteration=2, RS=NOW-60,
  autopilot_bump=null`.
- **Gate signals**: issue-text sufficiency = **insufficient** — an honest resolution attempt
  (repo → specs → memory, per S2) left a scope question genuinely unresolved; destructive-op
  flags = none; complexity = fits one ticket.
- **BC walk** (scope-confirm applies {1,3,5,6,7}): **BC1 (ordinal 1) matches** — unresolved
  scope question after honest attempt. First match wins; 3/5/6/7 never reached.
- **Expected**: `decision=halt, blocking_condition=1, confidence=30, bump=null`.
  (confidence unconstrained for a non-BC7 halt.)
- **Card**:
  `append-card.sh orchestrate CDT-200 scope-confirm halt auto null 30 1 ap-<RS> 2 <NOW-RS> orchestrator "<rationale: scope Q unresolved after repo/spec/memory attempt>"`

### F2 — BC2 qa_bounces ≥ 3 → halt

- **Envelope**: `workflow=orchestrate, gate=ship-choice, iteration=8, RS=NOW-60,
  autopilot_bump=null`.
- **Gate signals**: Step-10b spec-alignment = **PASS** (so no BC1 at ship-choice step 1);
  QA = FAIL with `qa_bounces=3` (caller-supplied session-local count, §3c); ship-action
  irreversibility = PR-level (none).
- **BC walk** (ship-choice applies {1,2,3,6,7}): BC1 (ordinal 1) **clears** — spec-alignment
  passed, no now-provable scope/plan question. **BC2 (ordinal 2) matches** — supplied numeric
  compare `qa_bounces (3) >= 3` (§3d BC2 row). First match wins; 3/6/7 never reached.
- **Expected**: `decision=halt, blocking_condition=2, confidence=80, bump=null`.
- **Card**:
  `append-card.sh orchestrate CDT-200 ship-choice halt auto null 80 2 ap-<RS> 8 <NOW-RS> orchestrator "<rationale: qa_bounces reached 3>"`

### F3 — BC3 destructive/irreversible ship → halt (bump supplied, still halts)

- **Envelope**: `workflow=orchestrate, gate=ship-choice, iteration=6, RS=NOW-60,
  autopilot_bump=minor`.
- **Gate signals**: Step-10b = PASS, `qa_bounces=0`; ship-action irreversibility = **direct
  squash-merge to a protected branch** (M6.3 destructive class).
- **BC walk** (ship-choice applies {1,2,3,6,7}): BC1 clears (spec-aligned), BC2 clears
  (`qa_bounces=0 < 3`). **BC3 (ordinal 3) matches** — protected-branch merge. Per M4
  ship-choice step 2 / N3, **BC3 is evaluated unconditionally even though `autopilot_bump=minor`
  was supplied** — the bump flag never exempts BC3. First match wins.
- **Expected**: `decision=halt, blocking_condition=3, confidence=85, bump=minor`.
  (bump travels on the ship-choice card per S4; writer invariant (a) is satisfied because
  `gate=ship-choice`.)
- **Card**:
  `append-card.sh orchestrate CDT-200 ship-choice halt auto minor 85 3 ap-<RS> 6 <NOW-RS> orchestrator "<rationale: protected-branch merge is irreversible>"`
- **Doubles as**: proof that `bump` may be non-null on a *halt* card (writer only requires
  `gate=ship-choice`, not `decision=merge`) — see § Gaps found item 2.

### F4 — BC4 LOC/file-size breach → halt (rewritten: counted hand-written file)

- **Envelope**: `workflow=orchestrate, gate=plan-approve, iteration=4, RS=NOW-60,
  autopilot_bump=null, max_loc=null`.
- **Gate signals**: every task has file paths **and** a verification step (no BC1); no
  destructive op (no BC3); projected change includes **one hand-written implementation
  file at 1,400 lines** (`loc-exclude.sh is-excluded` exit 1 → **counted**). Total counted
  ≈ 1,500 LOC (**under** the 2,000-LOC hard cap, so **not** an M10.1 overflow). Generated /
  lockfile / snap at 1400 MUST NOT be this fixture (see F4-gen). One subsystem, one spec,
  4 tasks (no M10 overflow).
- **BC walk** (plan-approve applies {1,3,4,5,6,7}): BC1 clears (paths+verify present), BC3
  clears (non-destructive). **BC4 (ordinal 4) matches** — counted per-file cap (1000)
  breached (M16 `max_loc=null`). BC4 precedes BC5; no M10 overflow criterion is met, so
  the reroute path is not taken. First match wins.
- **Expected**: `decision=halt, blocking_condition=4, confidence=85, bump=null, max_loc=null`.
- **Card** (argc 13):
  `append-card.sh orchestrate CDT-200 plan-approve halt auto null 85 4 ap-<RS> 4 <NOW-RS> orchestrator "<rationale: one counted hand-written file 1400 lines exceeds per-file cap>"`

#### F4-* — AC8 / M16 counted-LOC + `--max-loc` (CDT-223)

Cite SPEC-033 M16 fixture table. Counted LOC = `loc-exclude.sh is-excluded` on plan paths,
then caller M15 arm 3, then the M16 effects table.

| Fixture | Signal | Expected |
|---|---|---|
| F4 (rewritten) | one counted file 1400 lines; total under hard cap | BC4 halt (per-file) |
| F4-gen | lockfile/snap/linguist-generated file 1400 lines | **no** BC4 |
| F4-file | `--max-loc=<n>` with `n>2000`; one counted file >1000 | BC4 halt (per-file unchanged) |
| F4-n-ok | `--max-loc=<n>`; counted LOC in `(2000, n]` | clean `approve` (no BC4, no M10.1) |
| F4-n-file | `--max-loc=<n>`; one counted file >1000 | BC4 halt (per-file) |
| F4-n-tight | `--max-loc=<n>` with `n<2000`; counted LOC in `(n, 2000)` | plan-approve BC4 halt; scope-confirm M10.1 reroute |
| F4-unbound | `--max-loc=unbound`; counted >2000 **and** file >1000 | **no** BC4, **no** M10.1 |
| F4-unbound-m10 | `--max-loc=unbound`; M10.2 workstream overflow | BC5 `reroute-epic` (M10.2 still live) |

##### F4-gen — excluded 1400-line file → no BC4

- **Envelope**: `workflow=orchestrate, gate=plan-approve, iteration=4, RS=NOW-60,
  autopilot_bump=null, max_loc=null`.
- **Gate signals**: paths+verify present; non-destructive; projected change includes
  **`package-lock.json` at 1,400 lines** (`loc-exclude.sh is-excluded` exit 0 — built-in
  lockfile). Same class: basename `*.snap`, or `linguist-generated=true`. Remaining
  counted ≈ 100 LOC, every counted file ≤ 1000. One subsystem, one spec, 4 tasks.
- **BC walk** (plan-approve {1,3,4,5,6,7}): BC1/BC3 clear. **BC4 does not match** — the
  1400-line path is excluded (M15); counted per-PR and per-file are inside default
  caps. BC5/BC6/BC7 clear. No match → default `approve`.
- **Expected**: `decision=approve, blocking_condition=null, confidence=88, bump=null, max_loc=null`.
- **Card** (argc 13):
  `append-card.sh orchestrate CDT-200 plan-approve approve auto null 88 null ap-<RS> 4 <NOW-RS> orchestrator "<rationale: lockfile 1400 excluded; counted LOC within caps>"`

##### F4-file — `n>2000`; counted file >1000 → BC4 per-file (unchanged)

- **Envelope**: `workflow=orchestrate, gate=plan-approve, iteration=4, RS=NOW-60,
  autopilot_bump=null, max_loc=4000`.
- **Gate signals**: paths+verify; non-destructive; **one counted hand-written file at
  1,400 lines**; total counted ≈ 1,500 (`< 4000`, so per-PR under `n`). One subsystem,
  one spec, 4 tasks.
- **BC walk** (plan-approve {1,3,4,5,6,7}): BC1/BC3 clear. **BC4 matches** — per-file
  cap stays **1000** when `max_loc` is a number (M16); `n>2000` raises per-PR only.
  First match wins.
- **Expected**: `decision=halt, blocking_condition=4, confidence=85, bump=null, max_loc=4000`.
- **Card** (argc 14; rationale mentions override):
  `append-card.sh orchestrate CDT-200 plan-approve halt auto null 85 4 ap-<RS> 4 <NOW-RS> orchestrator "<rationale: max-loc=4000 raises per-PR; counted file 1400 still exceeds per-file 1000>" 4000`

##### F4-n-ok — counted in `(2000, n]` → clean approve

- **Envelope**: `workflow=orchestrate, gate=plan-approve, iteration=4, RS=NOW-60,
  autopilot_bump=null, max_loc=4000`.
- **Gate signals**: paths+verify; non-destructive; counted LOC **2500** (in `(2000,
  4000]`); every counted file ≤ 1000; one subsystem, one spec, 4 tasks (M10.2–6 clear).
- **BC walk** (plan-approve {1,3,4,5,6,7}): BC1/BC3 clear. **BC4 does not match** —
  per-PR cap is `n=4000` (2500 ≤ 4000) and per-file holds. **M10.1 does not match**
  (threshold `n`, 2500 ≤ 4000). BC5/BC6/BC7 clear. No match → default `approve`.
- **Expected**: `decision=approve, blocking_condition=null, confidence=88, bump=null, max_loc=4000`.
- **Card** (argc 14; rationale mentions override):
  `append-card.sh orchestrate CDT-200 plan-approve approve auto null 88 null ap-<RS> 4 <NOW-RS> orchestrator "<rationale: max-loc=4000; counted 2500 within n and per-file>" 4000`

##### F4-n-file — `--max-loc=<n>`; counted file >1000 → BC4 per-file

- **Envelope**: `workflow=orchestrate, gate=plan-approve, iteration=4, RS=NOW-60,
  autopilot_bump=null, max_loc=3000`.
- **Gate signals**: paths+verify; non-destructive; **one counted hand-written file at
  1,100 lines**; total counted ≈ 1,500 (`< n`). One subsystem, one spec, 4 tasks.
- **BC walk** (plan-approve {1,3,4,5,6,7}): BC1/BC3 clear. **BC4 matches** — per-file
  1000 unchanged by `n`. First match wins.
- **Expected**: `decision=halt, blocking_condition=4, confidence=85, bump=null, max_loc=3000`.
- **Card** (argc 14; rationale mentions override):
  `append-card.sh orchestrate CDT-200 plan-approve halt auto null 85 4 ap-<RS> 4 <NOW-RS> orchestrator "<rationale: max-loc=3000; counted file 1100 exceeds per-file 1000>" 3000`

##### F4-n-tight — `n<2000`; counted in `(n, 2000)` → BC4 at plan-approve, M10.1 at scope-confirm

Two envelopes, same counted LOC **1800** (in `(1500, 2000)`); every counted file ≤ 1000;
`max_loc=1500`.

###### plan-approve → BC4 halt

- **Envelope**: `workflow=orchestrate, gate=plan-approve, iteration=4, RS=NOW-60,
  autopilot_bump=null, max_loc=1500`.
- **Gate signals**: paths+verify; non-destructive; counted 1800; 4 tasks, one spec, one
  subsystem.
- **BC walk** (plan-approve {1,3,4,5,6,7}): BC1/BC3 clear. **BC4 matches** — counted
  1800 > per-PR `n=1500`. M10.1 would also match but BC4 precedes BC5. First match wins
  → **halt**, not reroute.
- **Expected**: `decision=halt, blocking_condition=4, confidence=85, bump=null, max_loc=1500`.
- **Card** (argc 14; rationale mentions override):
  `append-card.sh orchestrate CDT-200 plan-approve halt auto null 85 4 ap-<RS> 4 <NOW-RS> orchestrator "<rationale: max-loc=1500 tightens per-PR; counted 1800 exceeds n>" 1500`

###### scope-confirm → M10.1 reroute

- **Envelope**: `workflow=orchestrate, gate=scope-confirm, iteration=2, RS=NOW-60,
  autopilot_bump=null, max_loc=1500`.
- **Gate signals**: issue text sufficient; non-destructive; projected counted 1800;
  one workstream / one spec / one subsystem otherwise.
- **BC walk** (scope-confirm {1,3,5,6,7}): BC1/BC3 clear. **BC4 dropped** (plan-approve
  only). **BC5 matches via M10.1** — counted 1800 > `n=1500`. M10.2–6 not required.
  First match wins → `reroute-epic`.
- **Expected**: `decision=reroute-epic, blocking_condition=5, confidence=85, bump=null, max_loc=1500`.
- **Card** (argc 14; rationale mentions override):
  `append-card.sh orchestrate CDT-200 scope-confirm reroute-epic auto null 85 5 ap-<RS> 2 <NOW-RS> orchestrator "<rationale: max-loc=1500; counted 1800 trips M10.1>" 1500`

##### F4-unbound — unbound; counted >2000 and file >1000 → no BC4, no M10.1

- **Envelope**: `workflow=orchestrate, gate=plan-approve, iteration=4, RS=NOW-60,
  autopilot_bump=null, max_loc=unbound`.
- **Gate signals**: paths+verify; non-destructive; counted LOC **2500** **and** one
  counted hand-written file **1400** lines; one subsystem, one spec, 4 tasks (M10.2–6
  clear).
- **BC walk** (plan-approve {1,3,4,5,6,7}): BC1/BC3 clear. **BC4 does not fire**
  (`unbound` disables per-PR **and** per-file). **M10.1 does not fire** (unbound-off).
  BC5/BC6/BC7 clear. No match → default `approve`.
- **Expected**: `decision=approve, blocking_condition=null, confidence=88, bump=null, max_loc="unbound"`.
- **Card** (argc 14; rationale mentions override):
  `append-card.sh orchestrate CDT-200 plan-approve approve auto null 88 null ap-<RS> 4 <NOW-RS> orchestrator "<rationale: max-loc=unbound disables BC4 and M10.1; M10.2-6 clear>" unbound`

##### F4-unbound-m10 — unbound; M10.2 still live → BC5 reroute-epic

- **Envelope**: `workflow=orchestrate, gate=scope-confirm, iteration=1, RS=NOW-60,
  autopilot_bump=null, max_loc=unbound`.
- **Gate signals**: issue text sufficient; non-destructive; complexity = **overflow**
  — **4 independently shippable workstreams** (M10.2). Counted LOC may exceed 2000;
  unbound is irrelevant to M10.2. Within budget.
- **BC walk** (scope-confirm {1,3,5,6,7}): BC1/BC3 clear. M10.1 does **not** fire
  (unbound-off). **BC5 matches via M10.2** — workstream overflow still live. Maps to
  `reroute-epic` (non-blocking). First match wins.
- **Expected**: `decision=reroute-epic, blocking_condition=5, confidence=85, bump=null, max_loc="unbound"`.
- **Card** (argc 14; rationale mentions override):
  `append-card.sh orchestrate CDT-200 scope-confirm reroute-epic auto null 85 5 ap-<RS> 1 <NOW-RS> orchestrator "<rationale: max-loc=unbound; 4 workstreams still M10.2 overflow>" unbound`

### F5 — BC5 complexity overflow → reroute-epic (the non-blocking BC)

- **Envelope**: `workflow=orchestrate, gate=scope-confirm, iteration=1, RS=NOW-60,
  autopilot_bump=null`.
- **Gate signals**: issue text sufficient (no BC1); no destructive op (no BC3); complexity
  assessment = **overflow** — decomposes into **4 independently shippable workstreams**
  (M10.2) touching **3+ independent subsystems** (M10.5). Within budget.
- **BC walk** (scope-confirm applies {1,3,5,6,7}): BC1 clears, BC3 clears. **BC5 (ordinal 5)
  matches** — M10 overflow criteria met. BC5 is the **only non-blocking** condition (§3e): it
  maps to `reroute-epic`, hands to `/epic` decompose, and continues autonomously — **no halt**.
  First match wins; 6/7 never reached.
- **Expected**: `decision=reroute-epic, blocking_condition=5, confidence=85, bump=null`.
- **Card**:
  `append-card.sh orchestrate CDT-200 scope-confirm reroute-epic auto null 85 5 ap-<RS> 1 <NOW-RS> orchestrator "<rationale: 4 workstreams / 3+ subsystems -> epic overflow>"`
- **Required case**: this is the mandated BC5→reroute-epic fixture.

### F6 — BC6 run-budget breach → halt

- **Envelope**: `workflow=orchestrate, gate=plan-approve, iteration=25, RS=NOW-60,
  autopilot_bump=null` (default `AUTOPILOT_ITERATION_CAP=25`).
- **Gate signals**: paths+verify present (no BC1); non-destructive (no BC3); LOC within caps
  (no BC4); single-ticket task graph (no BC5).
- **BC walk** (plan-approve applies {1,3,4,5,6,7}): BC1/BC3/BC4/BC5 all clear. **BC6 (ordinal 6)
  matches** — `budget-check.sh 25 <RS>` returns `breached:true, reason:"iteration",
  blocking_condition:6, exit 6` (verified live, § Walkthrough B). First match wins.
- **Expected**: `decision=halt, blocking_condition=6, confidence=90, bump=null`.
- **Card**:
  `append-card.sh orchestrate CDT-200 plan-approve halt auto null 90 6 ap-<RS> 25 <NOW-RS> orchestrator "<rationale: iteration cap 25 reached>"`
- **Wall-clock variant**: identical but `iteration=3, RS=NOW-3000` → `budget-check.sh 3 <RS>`
  returns `reason:"wall_clock", exit 6`; `iteration=25, RS=NOW-3000` → `reason:"both"`. All
  three map to the same `blocking_condition=6` card (only the rationale differs).

### F7 — BC7 self-uncertainty → halt (writer cross-field invariant (b))

- **Envelope**: `workflow=orchestrate, gate=scope-confirm, iteration=2, RS=NOW-60,
  autopilot_bump=null`.
- **Gate signals**: issue text sufficient (no BC1); non-destructive (no BC3); fits one ticket
  (no BC5); within budget (no BC6); but the answering agent's **confidence in `proceed` is 65
  (< 80)** — an honest "I'm not sure" (M6.7).
- **BC walk** (scope-confirm applies {1,3,5,6,7}): BC1/BC3/BC5/BC6 all clear. **BC7 (ordinal 7)
  matches** — confidence below the M6/M13 threshold. First match wins.
- **Expected**: `decision=halt, blocking_condition=7, confidence=65, bump=null`.
- **Writer precondition exercised**: invariant (b) — `blocking_condition=7 ⇒ confidence < 80`.
  The engine routes to BC7 **only** when confidence is genuinely sub-threshold, so the card is
  valid-by-construction. A `bc=7` card carrying `confidence≥80` is a **construction bug** and
  the writer hard-fails it (verified live, § Walkthrough C — `confidence=85, bc=7 → exit 64`).
- **Card**:
  `append-card.sh orchestrate CDT-200 scope-confirm halt auto null 65 7 ap-<RS> 2 <NOW-RS> orchestrator "<rationale: confidence below threshold on proceed>"`

### F8 — BC8 unverified external dependency → halt (`/kickoff` pre-spec)

- **Envelope**: `workflow=kickoff, gate=scope-confirm, iteration=3, RS=NOW-60,
  autopilot_bump=null`.
  - **Gate recording**: `/kickoff` Step 4b "GATE 1 (API verification)" is off-triad; per M13 +
    the M5 mapping table, an off-triad `/kickoff` pre-spec halt records the **closest** canonical
    gate = **`scope-confirm`** (the only `/kickoff` row with any analog). The enum stays the
    frozen 3-value set.
- **Gate signals**: a **confirmed AC depends on** an external API capability whose Step-4b
  verification returned **`DECORATIVE`** (a resolved-negative, M6.8). Non-destructive; within
  budget; the agent is **certain** the capability failed (not self-uncertain).
- **BC walk** (`/kickoff` pre-spec applies {1,6,7,8}; BC2 ship-only dropped, BC3 not triggered,
  BC4 plan-approve-only dropped, BC5 no overflow): BC1 **clears by design** — M6.8 is explicit
  that a `DECORATIVE`/`IGNORED` resolved-negative is **distinct from BC1** (BC1 would mis-classify
  it as "specs answer it → proceed", the exact wrong outcome); BC6 clears (within budget); BC7
  clears (agent is certain). **BC8 (ordinal 8) matches**. First match wins.
- **Expected**: `decision=halt, blocking_condition=8, confidence=85, bump=null`.
- **Card**:
  `append-card.sh kickoff CDT-200 scope-confirm halt auto null 85 8 ap-<RS> 3 <NOW-RS> orchestrator "<rationale: AC-dependent API capability verified DECORATIVE>"`

---

## Group B — clean-path default per applicable `/orchestrate` gate

### F9 — clean scope-confirm → proceed

- **Envelope**: `workflow=orchestrate, gate=scope-confirm, iteration=2, RS=NOW-60,
  autopilot_bump=null`.
- **Gate signals**: issue text sufficient; non-destructive; fits one ticket; within budget;
  confidence 90 (≥ 80).
- **BC walk** (scope-confirm {1,3,5,6,7}): **all clear, no match** → default answer.
- **Expected**: `decision=proceed, blocking_condition=null, confidence=90, bump=null`.
- **Card**:
  `append-card.sh orchestrate CDT-200 scope-confirm proceed auto null 90 null ap-<RS> 2 <NOW-RS> orchestrator "<rationale: scope clear, in budget, confident>"`

### F10 — clean plan-approve → approve

- **Envelope**: `workflow=orchestrate, gate=plan-approve, iteration=4, RS=NOW-60,
  autopilot_bump=null`.
- **Gate signals**: every task carries paths + a verification step; non-destructive; LOC within
  soft-cap and per-file cap; task graph within the single-ticket bound; within budget;
  confidence 88.
- **BC walk** (plan-approve {1,3,4,5,6,7}): **all clear** → default answer.
- **Expected**: `decision=approve, blocking_condition=null, confidence=88, bump=null`.
- **Card**:
  `append-card.sh orchestrate CDT-200 plan-approve approve auto null 88 null ap-<RS> 4 <NOW-RS> orchestrator "<rationale: plan complete, within caps, confident>"`

### F11 — clean ship-choice → pr (no bump ⇒ PR, not merge)

- **Envelope**: `workflow=orchestrate, gate=ship-choice, iteration=7, RS=NOW-60,
  autopilot_bump=null`.
- **Gate signals**: Step-10b = PASS; `qa_bounces=0`; ship-action = PR (reversible); within
  budget; confidence 90.
- **BC walk** (ship-choice {1,2,3,6,7}): **all clear** → default answer. §3e: `ship-choice`
  yields `merge` **only** when `autopilot_bump != null`; here `autopilot_bump=null`, so the
  default is **`pr`**.
- **Expected**: `decision=pr, blocking_condition=null, confidence=90, bump=null`.
- **Card**:
  `append-card.sh orchestrate CDT-200 ship-choice pr auto null 90 null ap-<RS> 7 <NOW-RS> orchestrator "<rationale: default reversible PR>"`

### F12 — merge-with-bump variant → merge (clean, non-protected squash)

- **Envelope**: `workflow=orchestrate, gate=ship-choice, iteration=7, RS=NOW-60,
  autopilot_bump=patch`.
- **Gate signals**: Step-10b = PASS; `qa_bounces=0`; ship-action = **squash-merge of the
  approved PR into a NON-protected integration branch, no force-push** (so BC3 does **not**
  fire); within budget; confidence 90.
- **BC walk** (ship-choice {1,2,3,6,7}): BC1/BC2 clear; **BC3 clears** — the merge target is
  not protected and there is no force-push, so the destructive class is not met (BC3 is still
  *evaluated* unconditionally, it simply does not match here); BC6/BC7 clear. No match →
  default answer. §3e: because `autopilot_bump=patch != null`, the ship-choice default resolves
  to **`merge`** (explicit ship intent, M2/N3).
- **Expected**: `decision=merge, blocking_condition=null, confidence=90, bump=patch`.
- **Writer preconditions exercised**: invariant (a) `bump non-null ⇒ gate=ship-choice` (holds);
  engine invariant `merge ⇒ bump supplied` (holds — `patch`). Note the second is **engine-only**
  (see § Gaps found item 2).
- **Required case**: this is the mandated merge-with-bump variant.
- **Card**:
  `append-card.sh orchestrate CDT-200 ship-choice merge auto patch 90 null ap-<RS> 7 <NOW-RS> orchestrator "<rationale: squash-merge to non-protected branch, explicit patch bump>"`

### F13 — clean ship-choice → merge with `autopilot_bump=master` (land-no-release sentinel)

- **Envelope**: `workflow=orchestrate, gate=ship-choice, iteration=7, RS=NOW-60,
  autopilot_bump=master`.
- **Gate signals**: Step-10b = PASS; `qa_bounces=0`; ship-action = **intentional baseline
  land** under the land-no-release sentinel (squash-stage onto the worktree baseline /
  `origin/HEAD` default; **no force-push**). N3a mechanical push-target check would clear —
  not a raw self-selected protected-branch mutation, so BC3 does **not** match merely because
  the default branch is protected (§3e BC3 / N3a). Within budget; confidence 90.
- **BC walk** (ship-choice {1,2,3,6,7}): BC1/BC2 clear; **BC3 clears** (N3a-aligned
  intentional baseline land, no force-push — evaluated unconditionally, no match); BC6/BC7
  clear. No match → default answer. §3e: `autopilot_bump=master != null` ⇒ **`decision=merge`**
  with card `bump=master`. Self-answer does **not** imply `/release` — `master` is a
  land-no-release sentinel (M2); release vs land-no-release is end-state's branch on token
  class, not a different ship-choice decision.
- **Expected**: `decision=merge, blocking_condition=null, confidence=90, bump=master`.
- **Writer preconditions exercised**: invariant (a) `bump non-null ⇒ gate=ship-choice` (holds);
  engine invariant `merge ⇒ bump supplied` (holds — `master`). No release implication on the
  card or decision.
- **Required case**: CDT-195 master sentinel clean path (F11 null→pr and F12 patch→merge stay
  intact).
- **Card**:
  `append-card.sh orchestrate CDT-200 ship-choice merge auto master 90 null ap-<RS> 7 <NOW-RS> orchestrator "<rationale: land-no-release sentinel master, decision=merge, no /release>"`

---

## Group C — edge fixture the procedure does not cover (documents a gap, not a pass)

### FE — `budget-check.sh` exit 64 (malformed budget call)

- **Setup**: engine step (b) calls `budget-check.sh <iteration> <run_start_epoch>` and the call
  returns **exit 64** — e.g. a non-numeric `iteration`, an argc error, or `run_start_epoch > now`
  (all three verified live, § Walkthrough B). On exit 64 the helper writes to **stderr only** and
  computes **no** `wall_clock_s` on stdout (`die()` at `budget-check.sh:37-41` returns before the
  compute block at :66).
- **Expected per the written procedure**: **UNDEFINED.** `self-answer.md` §3b lists exit 64 as a
  possible outcome but §3d–§3f never consume it — there is **no** "on exit 64, do X" branch, and
  §3b instructs the engine to capture `wall_clock_s` "always, regardless of breach", which is not
  reachable when the helper exits 64 before emitting stdout. With no `wall_clock_s`, `append-card.sh`
  arg 11 cannot be constructed valid-by-construction, so **no card is built on this path**.
- **This is a reported gap, not a fixture that passes** — see § Gaps found item 1. It is included
  deliberately (per the diff-mode council finding, conf 62) to make the blind spot explicit rather
  than silently working around it. The blast radius is capped because `iteration` /
  `run_start_epoch` are session-tracked ints (never external input), so exit 64 signals an internal
  engine bug rather than adversarial input — but the procedure still owes an escalation branch.

---

## Walkthrough results (live-run evidence — verified, not asserted)

**A. Fixture-to-procedure trace.** Each of F1–F13 was walked against `self-answer.md` §3a–§3f:
the input-envelope receipt (§3a), the budget call (§3b), signal gathering (§3c), the BC1→BC8
first-match-wins ordinal walk (§3d), the outcome→decision mapping (§3e), and the one-card side
effect (§3f). Every fixture's target outcome is the **genuine first match** in canonical ordinal
order after dropping inapplicable BCs — confirmed BC-by-BC in each fixture's *BC walk* block
above. `decided_by=auto` on all 13 (clean, halt, and reroute alike) per §3f.

**A2. CDT-223 F4 rewrite + F4-*.** F4's 1400-line file is **hand-written implementation**
(counted). F4-gen / F4-file / F4-n-ok / F4-n-file / F4-n-tight / F4-unbound /
F4-unbound-m10 were walked against `self-answer.md` §3d (counted LOC via
`loc-exclude.sh is-excluded` + M16 table) and §3f (argc 13 omit / argc 14 when
override set; rationale mentions override; `decided_by=auto`). Table matches
SPEC-033 M16.

**T7 live re-walk** (throwaway git repo, real `loc-exclude.sh` + `append-card.sh`):
`package-lock.json` / `foo.snap` exit 0 (excluded); `src/impl.go` / `src/vendor/x`
exit 1 (counted). Every F4 / F4-* card shape exit 0: F4 argc13 halt bc=4
`max_loc:null`; F4-gen argc13 approve; F4-n-tight plan-approve argc14 halt bc=4
`max_loc:1500`; F4-n-tight scope-confirm argc14 `reroute-epic` bc=5; F4-unbound-m10
argc14 `reroute-epic` bc=5 `max_loc:"unbound"`. `decided_by=auto` on all. Override
rationale contains `max-loc=`. See Walkthrough C.

**B. `budget-check.sh` behavior (ran `skills/autopilot/budget-check.sh` directly):**

| Input | stdout `reason` / `breached` / `blocking_condition` | exit | Feeds |
|---|---|---|---|
| `3  NOW-60`   | `none` / `false` / `null` | 0  | F9–F13, clean paths |
| `25 NOW-60`   | `iteration` / `true` / `6` | 6 | **F6** |
| `AUTOPILOT_ITERATION_CAP=2 5 NOW-60` | `iteration` / `true` / `6` | 6 | F6 env-override variant |
| `3  NOW-3000` | `wall_clock` / `true` / `6` | 6 | F6 wall-clock variant |
| `25 NOW-3000` | `both` / `true` / `6` | 6 | F6 both variant |
| `abc NOW-60`  | (stderr `must be a non-negative integer`) | 64 | **FE** |
| `3  NOW+500`  | (stderr `is in the future`) | 64 | FE |
| `3` (1 arg)   | (stderr `requires exactly 2 arguments`) | 64 | FE |

All within/breach rows emit the 7-key JSON on stdout; all exit-64 rows emit **stderr only, no
stdout** — confirming the FE gap. (`jq-1.8.1` present.)

**C. `append-card.sh` accepts every fixture card shape and rejects the two guarded invariants**
(ran the real writer in a throwaway git repo so the project ledger stayed clean):

| Card | Result |
|---|---|
| F9 `scope-confirm proceed … null 90 null` | exit 0 |
| F10 `plan-approve approve … null 88 null` | exit 0 |
| F11 `ship-choice pr … null 90 null` | exit 0 |
| F12 `ship-choice merge … patch 90 null` | exit 0 |
| F13 `ship-choice merge … master 90 null` | exit 0 (writer accepts `master` bump) |
| F7 `scope-confirm halt … null 65 7` | exit 0 |
| F3 `ship-choice halt … minor 85 3` | exit 0 |
| F6 `plan-approve halt … null 90 6` | exit 0 |
| F8 `kickoff scope-confirm halt … null 85 8` | exit 0 |
| **F4** argc13 `plan-approve halt bc=4` `max_loc:null` `decided_by=auto` | exit 0 |
| **F4-gen** argc13 `plan-approve approve` `max_loc:null` | exit 0 |
| **F4-file** argc14 `halt bc=4` `max_loc:4000` rationale mentions override | exit 0 |
| **F4-n-ok** argc14 `approve` `max_loc:4000` | exit 0 |
| **F4-n-file** argc14 `halt bc=4` `max_loc:3000` | exit 0 |
| **F4-n-tight** plan argc14 `halt bc=4` `max_loc:1500` | exit 0 |
| **F4-n-tight** scope argc14 `reroute-epic bc=5` `max_loc:1500` | exit 0 |
| **F4-unbound** argc14 `approve` `max_loc:"unbound"` | exit 0 |
| **F4-unbound-m10** argc14 `reroute-epic bc=5` `max_loc:"unbound"` | exit 0 |
| **neg** `bc=7` with `confidence=85` | **exit 64** (invariant (b) enforced) |
| **neg** `bump=patch` on `scope-confirm` | **exit 64** (invariant (a) enforced) |
| **probe** `merge` with `bump=null` | **exit 0** (writer has **no** merge⇒bump guard) |

Every positive fixture card is constructible with **no writer exit-64** → the engine's
valid-by-construction claim (§4, R6) holds for all 13 fixtures plus the CDT-223 F4-*
argc 13/14 shapes (T7 live re-walk). The two negatives confirm the writer's
cross-field guards match the two the engine promises to honor. `decided_by=auto`
on every F4-* card; non-null `max_loc` is the cap's user provenance, not a `user`
decision.

---

## Gaps found

1. **`budget-check.sh` exit-64 path is uncovered by the procedure (council diff-mode finding,
   conf 62 — CONFIRMED).** `self-answer.md` §3b enumerates exit 64 but no downstream step
   (§3d–§3f) consumes it, and §3b's "capture `wall_clock_s` always" is unreachable on that path
   (the helper `die()`s before emitting stdout — verified live, § Walkthrough B). Result: **no
   decision card is written** if `budget-check.sh` ever exits 64. Fixture **FE** exercises this
   and documents it as UNDEFINED rather than a pass. Impact is capped (args are session-tracked
   ints, never external input, so exit 64 = internal engine bug), but the procedure still owes an
   explicit branch — e.g. "a `budget-check.sh` exit 64 is an internal-engine-bug signal; treat it
   as an unexpected-error escalation to the blocking-condition handler." **Recommend Tech Lead
   (Task 4) require this one-line branch before commit.** Severity **P2** (blind spot on an audit
   path; low probability, but a dropped card is a lost audit trail — the exact failure mode §4/R6
   exists to prevent).

2. **"`merge` ⇒ bump supplied" is engine-only, not writer-backed (council finding, conf 58 —
   CONFIRMED).** Live probe: `append-card.sh … ship-choice merge … null …` (bump `null`) exits
   **0** — the writer has no cross-field guard tying `merge` to a non-null bump; its only
   invariants are (a) bump⇒ship-choice and (b) bc7⇒conf<80. `self-answer.md` §4 lists
   "`merge` ⇒ bump supplied" under a section framed as writer-enforced guards, but this one is
   enforced **solely by the engine**. Not a fixture failure (F12 supplies `patch`, so it's valid
   either way), but the doc's framing overstates the writer's backstop. **Note for Tech Lead
   (Task 4):** either move this bullet out of the writer-invariant list or annotate it
   "engine-only, no writer backstop." Severity **P3** (doc-accuracy; no runtime defect).

3. **§4 self-contradiction — "do not re-derive the schema" then re-derives it (council finding,
   conf 75 — NOT scenario-testable; flagged for Task 4).** `self-answer.md:147` says "do not
   re-derive the schema — cite it via M13" and is immediately followed by a bulleted restatement
   of the M13 field contract (:149-168), an N4 contract-home concern. This is a static
   doc-fidelity / N4 issue, not reachable by an input-envelope fixture, so no fixture covers it.
   **Explicitly handed to Tech Lead's contract-fidelity review (Task 4).** Severity **P2** for
   contract-home (N4), but it is a documentation edit, not a behavioral defect — the engine's
   runtime outcomes (all 12 fixtures) are unaffected.

## QA verdict on the fixtures

All **13** original functional fixtures (F1–F13) plus **7** CDT-223 F4-* variants
(F4-gen, F4-file, F4-n-ok, F4-n-file, F4-n-tight dual-gate, F4-unbound,
F4-unbound-m10) are **genuinely reachable** per the written procedure. F4 rewritten:
1400-line file is **hand-written**; generated/lockfile/snap at 1400 is F4-gen (**no**
BC4). F4-* argc 14 cards keep `decided_by=auto` and mention the override in
`rationale`. The edge fixture **FE** is an intentionally-documented **gap**, not a
pass. The fixture set is the acceptance bar for `self-answer.md`.
