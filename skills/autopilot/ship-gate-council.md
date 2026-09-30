# Autopilot ship-gate council pass (CDT-111-C5)

> **Companion to `skills/autopilot/SKILL.md` and `skills/autopilot/self-answer.md`.**
> This file is a *procedure*, not a *policy*. It describes the operational algorithm
> autopilot follows to run the single adversarial council pass that gates every
> auto-answered ship, and to record its outcome as one additional decision card. It
> wires no caller. §4 hands the verdict off to `skills/autopilot/ship-gate-verdict.sh`
> (SPEC-033 M14(i)) — that script is not a render helper.

## 1. Purpose + contract-home stance

The normative contract for this pass is **SPEC-033 M14** (AC7), mirrored in the autopilot
SKILL's `ship-choice` section. That contract owns the firing rule, the per-AC
verdict→confidence→BC mapping (M14(b)), the AC source and per-AC split (M14(g)), the
`[process]` AC guards (M14(h)), the verdict mapper (M14(i)), the claim budget (M14(j)), the
"reuse BC7, not a 9th BC" ruling, and the degraded-run
rule. **This procedure cites M14 by name and never restates or forks it** (SPEC-002 D1 /
SPEC-033 M12 / N4 — the contract-home discipline `self-answer.md` §1 follows). It likewise
cites the M13 card schema, the M6 blocking-condition taxonomy, and the `append-card.sh`
call shape by reference to their homes (`skills/autopilot/SKILL.md` and
`skills/autopilot/self-answer.md` §3f) rather than reproducing any field list, enum, or BC
definition.

What this procedure adds on top of the frozen contract is the **operational sequence**:
detect the firing condition off `self-answer.md`'s ship-choice result, grade the council
tier (M14(e)), build the `/council` claim from run-time locators, read the verdict and its
degradation state, map that to the second card's `decision` / `confidence` /
`blocking_condition` / `bump`, and append that card with the **same `run_id`** as the
original via `skills/autopilot/append-card.sh`. Both ship-choice cards carry
`decided_by: auto`.

The tier vocabulary, the grading bands, the five structural critical-area signals, and the
fail-closed contract are **SPEC-013's** ("Council tiering"); M14(e)/M14(f) are SPEC-033's.
This procedure cites both and restates neither.

## 2. Firing check

This pass fires **only** when `self-answer.md`'s `ship-choice` checklist reaches a **clean
`pr`/`merge` answer** — `decision ∈ {pr, merge}` and `blocking_condition = null` (M14; the
ship-choice checklist lives in the SKILL). That clean answer is recorded as the **original**
ship-choice card (**card #1**, `decided_by: auto`, `blocking_condition: null`) by the
self-answer engine.

- On **any** non-clean ship-choice outcome — the self-answer engine returned a `halt`
  (any of BC1–BC8) or a `reroute-epic` (BC5) — this pass is **skipped entirely**. There is
  nothing to audit: the ship was already stopped or rerouted, and card #1 already carries
  the blocking condition.
- It **never** fires at `scope-confirm` or `plan-approve` (M14). Those gates keep OQ3's
  self-reported confidence; only `ship-choice` is council-derived.
- It fires **exactly once** per ship-choice attempt — one `/council` invocation, producing
  exactly one second card.

Read card #1 back with `skills/autopilot/read-cards.sh <ticket_id>` to recover the fields
this pass copies forward on the agree path: its `decision` (`pr` or `merge`), its `bump`,
its `max_loc`, and the shared `run_id`.

Save that card #1 JSON to a file under this run's `TMPDIR` (for example
`$TMPDIR/card1.json`) — §4 passes that path to the verdict mapper's `--card1`
argument (SPEC-033 M14(i)).

### 2a. Process-stamp pre-flight (SPEC-033 M14(a) CDT-185)

**Before** §3 tier selection and **before** any `/council` invocation, run the **process-stamp
pre-flight** against the M14(a) stamp shape (SPEC-033 owns the shape — cite-not-fork; do not
restate enums as a second home). Re-read the ledger with `read-cards.sh` and verify card #1
matches the stamp shape in **SPEC-033 M14(a)** (CDT-185).

On **stamp fail** (missing/empty ledger, `read-cards.sh` exit ≠ 0, no matching card #1, or any
shape-field mismatch):

1. **Skip `/council` entirely** — no rubber-stamp of a missing process trail.
2. **Do not take the agree path.**
3. Append card #2 via `append-card.sh` as a BC7 halt: `decision = halt`,
   `blocking_condition = 7`, `confidence = 0`, `bump = null`,
   `council_tier = null`, `grading_reason = null` (no council ran — stamp fail
   skips `/council`), **`max_loc` copied from card #1**, same `run_id` as card #1
   (or a fresh halt card if card #1 is unreadable — still BC7, conf=0, tiers
   null, `max_loc` from the unreadable card #1 when recoverable else `null`,
   `run_id` = `orchestrate-<ISSUE-ID>-<RUN_START_EPOCH>` per the `/orchestrate`
   Step 0 formula, using the run's current `RUN_START_EPOCH` (SPEC-033 M13)),
   with `rationale` naming the stamp failure (e.g. `process-stamp fail: <cause>`).
   Non-null parse → **argc 16** (council pair null + copied `max_loc`); omit/`null`
   parse → argc 15 (council pair null, `max_loc` null) or argc 13 (all optionals
   null). Stamp-fail halt with override uses the same argc-16 path as a healthy
   card #2 on that parse.
4. Return; halt escalation is the BC handler's job (§7).

On **stamp pass**, continue to §3. Process is pre-cleared; the claim under audit is
**technical-only** (M14(a) CDT-185 narrow claim — §3b).

This pre-flight and the verdict mapper's own guard 3 check (SPEC-033 M14(h)) are two
independent fail-closed layers, not duplicates to reconcile: the mapper
(`skills/autopilot/ship-gate-verdict.sh`) re-reads this same card #1 stamp shape against
`plan.process_acs[]` at mapping time, after the council has already run.

## 3. Select the tier, then build and invoke the council claim

### 3a. Tier selection (M14(e))

Grading runs **immediately before** the `/council` invocation below — never earlier, and
never at TaskCreate time (M14(e)).

**Resolve the graded diff.** M14 has no diff of its own, and **nothing is staged** at
firing time: the `git merge --squash` staging happens *after* this gate (N3a, `/orchestrate`
Step 11). The graded input is therefore the merge-base range M14(e) names, resolved through
**N3a's own** `origin/HEAD` probe. Reuse that probe as-is; M14(e) forbids inventing a second
diff-resolution or default-branch-resolution path:

```bash
DEFAULT_REF=$(git symbolic-ref refs/remotes/origin/HEAD)  # e.g. refs/remotes/origin/master
DEFAULT="${DEFAULT_REF#refs/remotes/}"                    # e.g. origin/master
MERGE_BASE=$(git merge-base "$DEFAULT" HEAD)
NUMSTAT=$(git diff --numstat "$MERGE_BASE"..HEAD)
RAW=$(git diff --raw "$MERGE_BASE"..HEAD)                 # optional grader input
```

> **The same probe, two different consequences — do not conflate them.**
> `git symbolic-ref refs/remotes/origin/HEAD` is run at two points in the same M14 flow, and
> an unresolvable `origin/HEAD` means something different at each:
>
> | Where | What it establishes | Unresolvable `origin/HEAD` ⇒ |
> |---|---|---|
> | N3a's BC3 push-target check (`end-state.md`, before `/release`) | ship **safety** | **halts the ship** under BC3 — autopilot MUST NOT guess a push target |
> | §3a here (M14(e)) | council **tier** | **grades the tier to `full`** — the pass still runs; nothing halts |
>
> Neither stands in for the other. A fail-closed `full` here does **not** pre-clear N3a's
> BC3 check, and a BC3 halt is **not** reachable from a grading failure. Grading failure
> MUST NOT skip, defer, or downgrade the council pass itself (M14(e)).

**Grade.** Feed that diff to `skills/council/tier-grade.sh` — the one grader both gated call
sites share, so the bands and the five critical-area signals have a single implementation:

```
skills/council/tier-grade.sh --numstat <(printf '%s' "$NUMSTAT") [--raw <(printf '%s' "$RAW")]
```

Its exit contract, output fields, and the `light` / `full` / `middle` semantics are stated
once at `commands/council.md` § 1.5.2 and are not repeated here. Resolve the outcome the same
way that step does:

- `tier == "light"` or `tier == "full"` → done. Record `council_tier` and the grader's own
  `grading_reason` (this includes a grader-self-reported `fail-closed: …` `full`).
- `tier == "middle"` → resolve with **exactly one** haiku-tier triage call, per
  `commands/council.md` § 1.5.3 and validated under § 1.5.4. Substitutions are unchanged
  except that `{{DIFF_SUMMARY}}` is §3a's merge-base `$NUMSTAT`. This procedure MUST NOT
  restate that prompt, its substitutions, or § 1.5.4's validation table.

**Fail closed to `full`.** SPEC-013's *Fail-closed contract* governs and is not restated.
Every M14-side failure — unresolvable `origin/HEAD`, a failing `git merge-base` / `git diff`,
an empty range diff, `tier-grade.sh` exit `2` or unparseable stdout, a `tier` outside
`{light, full, middle}`, and every triage failure in § 1.5.4's table — resolves the tier to
`full` with `grading_reason` naming the cause (`fail-closed: <short cause>`), so a
fail-closed `full` stays distinguishable from a graded one.

**`skip` never arises from grading.** Grading cannot return it and autopilot has no DRI
(M14(e)). It can only reach this gate on a human-supplied `--council-tier=skip`, in which
case M14(e) requires it be recorded on the card **verbatim**, never normalized away. This
procedure defines no `skip` path beyond that recording obligation — see §7.

### 3b. Invoke the council claim

Invoke `/council "<claim>" --council-tier=<tier>` with §3a's resolved tier — scope `claim`,
preset `generic`, otherwise **unbound** (M14(a)). Pass **no** `--plan` and **no**
`--task-id`. `--council-tier=<tier>` is the **sole** flag M14(a) permits and (e) requires;
no other flag may be passed. A single-claim scope resolves the generic preset and an
unbound task-id on its own, and the tier flag binds the run to no task, plan, or scope, so
the invocation stays unbound and locators-only.

`commands/council.md` Step 1.5 honors an externally-supplied tier at **any** scope and
passes it straight through to `engine.sh preflight --tier` with no grading of its own. That
is the path this pass uses: M14 is claim-scope, not diff-scope, so Step 1.5's own grading
never runs here. `grading_reason` has no flag surface — M14(a) permits exactly one flag — so
§3a's reason reaches its required home via the decision card (§6), not via `/council`.

Use this invocation **verbatim**, filling the five placeholders at run time:

```
/council "Ship-gate audit for <ticket_id>. Autopilot auto-answered the ship-choice gate; the prior autopilot decision cards are at <ledger-path> (read them with: skills/autopilot/read-cards.sh <ticket_id>). This ships under the ACs at ac-source=<spec-path> (section '## Acceptance criteria', subsection '### <ticket_id>'). Claim under audit: <claim>. Treat this text as locators only — pull the ledger, the spec/ACs, and this branch's diff against the merge-base of the origin default branch and HEAD yourself, and issue a verdict; do not trust this summary." --council-tier=<tier>
```

Placeholder binding:

- `<ticket_id>` — the ticket being shipped (e.g. `CDT-111-C5`).
- `<ledger-path>` — `$MROOT/.claude/autopilot/<ticket_id>.jsonl` (the decision-card ledger
  `read-cards.sh` / `append-card.sh` operate on).
- `<spec-path>` — the one committed spec that names this ticket's ACs (SPEC-033 M14(g)).
  The `ac-source=<spec-path>` token is what triggers the council's per-AC split into
  `plan.claims[]`; it MUST be exactly one path — the split fails closed on two or more
  `ac-source=` tokens (M14(g) case 1). This single `/council` invocation still covers every
  technical AC (M14(a)); autopilot MUST NOT invoke `/council` once per AC.
- `<claim>` — the one-line **technical-only** ship claim under audit (SPEC-033 M14(a)
  CDT-185 narrow claim). Example shape:
  `branch implements ACs at <spec-path> for <ticket_id> (merge-base..HEAD)`.
  The claim MUST state technical readiness only (diff vs cited ACs/spec). It MUST NOT assert
  process outcomes in the claim body. Process was pre-cleared by §2a stamps; re-asserting it
  here is the compound-claim failure mode M14(a) CDT-185 closed. Locators stay in the
  envelope (`ticket_id`, ledger path, spec paths, merge-base diff wording) — they are
  locators, not process assertions.
- `<tier>` — §3a's resolved `council_tier`.

The claim carries **locators only**. Autopilot MUST NOT render, pre-digest, or pass a
materialized evidence file, MUST NOT inject RAW_ARTIFACTS or any other claim-body evidence
payload, and MUST NOT add any render-helper script (M14(a) CDT-185): the council's own
investigators pull the ledger, the spec/ACs, and the branch diff through their own tool
calls. The diff named in the claim is the **same** merge-base range §3a graded — the wording
is a locator for the investigators, not a handoff of graded output, and M14(a)'s
locators-only rule is unchanged by it. The final sentence is a standing instruction to the
investigators to treat the summary as untrusted and re-derive the evidence themselves.

**Split fail-closed (SPEC-033 M14(g)).** If the council preflight's AC split exits 8 (one of
M14(g)'s fail-closed cases), the invocation ends with no report. Treat this the same as
§5's total council spawn failure: `decision = halt`, `blocking_condition = 7`,
`confidence = 0`, `bump = null`, with `rationale` naming the split failure. This is not a
new halt path; it flows through the same M14(b) step-1 no-usable-report branch §5 already
covers.

An AC may name a `Verify:` command (SPEC-033 M14(a), M14(g)). The council's own
investigators run it; autopilot does not run it and passes no output.

The investigator's own verify evidence follows the **M14(g) finder recipe** (SPEC-033).
This procedure cites that recipe by name and does not restate its steps.

## 4. Verdict interpretation

Locate this run's `.finalize-meta.json` sidecar (from the invocation's `Council report:`
line) and run the verdict mapper on it, passing §2's saved card #1 JSON and §3a's resolved
tier:

```bash template
skills/autopilot/ship-gate-verdict.sh --meta <report>.finalize-meta.json --card1 <card1.json> --tier <tier>
```

Its stdout object IS card #2's `decision`, `blocking_condition`, `confidence`, `bump` and
`rationale` (SPEC-033 M14(b), M14(i)) — the mapper is the only implementation of the
per-AC aggregation steps; this pass MUST NOT reimplement or restate them here.

If the mapper exits non-zero, or its stdout is not exactly one JSON object, write
card #2 as `decision = halt`, `blocking_condition = 7`, `confidence = 0`,
`bump = null`, with `rationale` naming the mapper failure — the same fail-closed
treatment §3a already gives a `tier-grade.sh` exit or unparseable-stdout failure
(cited, not restated).

That confidence feeds **BC7 only, never BC1** (M14(b) states why: a disagreeing verdict is a
resolved-negative, and the council can only push a ship **down** to a BC7 halt, never raise
card #1's clean answer above BC7). The `≥ 80 / < 80` agree boundary coincides exactly with
`append-card.sh` cross-field invariant (b), so a disagree output's `confidence` is
sub-threshold by construction — no exit-64.

The mapper's `rationale` is already a single secret-scrubbed line naming the driving AC ids
(M14(b), M14(i)); this pass passes it through to `append-card.sh` verbatim (same M13/S2
rationale discipline as `self-answer.md` §4) — it never copies council report text itself.

**Tier-aware BC7 (M14(f)).** Every BC7 halt card this pass writes — from the mapper's
disagree output **or** from §5's degraded / total-failure path — carries §3a's
`council_tier` (§6) and its one-line `rationale` **names that tier** (e.g.
`… ; council_tier=light`).

The escalation the blocking-condition handler surfaces to the human (S1) offers a
full-council re-run — *"this ran light and came back under threshold — re-run at full?"* —
**only** when `council_tier == light`. A `full`-run halt MUST NOT make that offer: there is
no escalation left to offer. The tier on the card is what makes that call decidable, which
is why it is recorded rather than re-derived.

This adds **no** ninth blocking condition and **no** new halt path — it is one recorded field
plus one clause of rationale text on the **existing** BC7 card. §4's verdict→confidence
mapping, §5's degraded-run rule, and the reuse-BC7 ruling are identical at both tiers
(M14(f); (b)/(c)/(d) unchanged). The re-offer is an **escalation affordance, not an
auto-action**: autopilot MUST NOT self-answer it, auto-re-run the council at `full`, or
otherwise proceed past the halt (M14(f), N2 / M7).

## 5. Degraded-run rule

The verdict mapper (`skills/autopilot/ship-gate-verdict.sh`) detects a degraded or
total-failure run itself and produces card #2 directly (M14(d), M14(i)) — this pass does not
re-derive the SPEC-013 spawn-failure degradation logic; §4's invocation is the same one used
here.

- **Self-verified run.** When this run's `.finalize-meta.json` sidecar reports
  `verification_mode: self-verified` (report frontmatter, no independent peer
  investigator/refuter survived, exact body marker `self-verified — refuters unavailable`),
  the mapper treats the outcome **identically to a `confidence < 80` disagreement**:
  `decision = halt`, `blocking_condition = 7`, `bump = null`, `confidence = 0` —
  **regardless of that self-verified run's own reported confidence** (M14(d)). Its
  `rationale` cites `self-verified — refuters unavailable` as the halt reason.
- **Total council spawn failure.** When there is no usable report at all, invoke the mapper
  with `--no-report "<cause>"` in place of `--meta`; its output is the same halt shape
  (`decision = halt`, `blocking_condition = 7`, `confidence = 0`, `bump = null`), with
  `rationale` naming the spawn failure.

### Open design — infra vs evidentiary (CDT-134)

M14(d) currently cannot distinguish pure spawn/infra flakiness (early investigator
returned strong tool-backed bundles; later roles never spawned) from genuine
evidentiary gaps. **Do not implement a ship-clearing “infra-degraded” path here
without a SPEC-033 revision and adversarial review.** Safe interim:

- Keep the halt + `confidence = 0` (this section).
- Prefer reducing spawn flakiness (CDT-133 named-agent preference).
- After human review, resume shipping only via explicit human override
  (`/orchestrate <id> --resume-ship=<bump>` — CDT-135), never by auto-clearing BC7.

Any future “infra-degraded” classification MUST still require: ≥1 independent
investigator with usable bundles; spawn-fail markers only on later roles; **human
confirm** before ship — never self-answer past BC7.

In both degraded cases the adversaries never ran, so the pass provides no independent
assurance and can only halt the ship, never clear it. The mapper always writes
`confidence = 0` on these cards (never the self-verified run's own reported value, which may
be `≥ 80`) — its output contract (SPEC-033 M14(i)) guarantees the card stays
**valid-by-construction** against `append-card.sh` cross-field invariant (b), which
hard-rejects `blocking_condition = 7 && confidence ≥ 80` with **exit 64**
(`append-card.sh:140`); an exit-64 would drop the halt record silently, exactly the
audit-trail loss the writer's hard-fail inversion exists to prevent.

Tier and degradation state are **orthogonal** (SPEC-013's Council tiering section owns that
ruling): a degraded `light` run is *both* `light` and `self-verified`. It therefore still
takes this section's path **and** still carries `council_tier: light`, so §4's tier-aware
BC7 re-offer remains available on it. A healthy `light` run sets neither
`verification_mode: self-verified` nor the marker, so it never reaches this section at all.

## 6. Card-append sequencing

A ship-choice attempt that reaches the firing condition records **exactly two** ship-choice
cards, in order:

1. **Card #1** — the self-answered clean `pr`/`merge` answer, written by the self-answer
   engine (`decided_by: auto`, `blocking_condition: null`).
2. **Card #2** — this council-derived outcome, appended here via
   `skills/autopilot/append-card.sh` (call shape per `self-answer.md` §3f — not restated),
   with **the same `run_id` as card #1** so the two correlate, `gate = ship-choice`, and
   `decided_by: auto`.

Both cards are `decided_by: auto` — card #2 records autopilot's own council-gated decision
to ship or halt, not a human's answer (this pass never writes a `decided_by: user` card;
those come later from the halt-resume owner). The original card is **never revised** (M13 is
append-only, M14(c)); card #2 is strictly additive.

Field source for card #2's `append-card.sh` args: `workflow` / `ticket_id` / `run_id` /
`iteration` from card #1's run context; `gate = ship-choice`; `decision` /
`blocking_condition` / `confidence` / `bump` / `rationale` copied verbatim from the verdict
mapper's stdout object (§4; the same mapper invocation covers §5's degraded/total-fail
paths); `wall_clock_s` from the run's budget snapshot; `actor` = the literal
`ship-gate-council` (M13's actor discriminator, CDT-281; card #1 MUST NOT carry
it); `council_tier` / `grading_reason` from §3a; **`max_loc`
copied from card #1** (null / number `n` / `"unbound"`). Every arg is built
valid-by-construction so the writer never exit-64s (`self-answer.md` §4).

`council_tier` and `grading_reason` extend `self-answer.md` §3f's call shape as two
**optional trailing** args; `max_loc` is a further optional (CDT-223 / writer M16).
Writer argc: **13** (all optionals null) · **14** (`max_loc`, council pair null —
**card #1** / self-answer when the override is set; this pass never writes argc 14)
· **15** (council pair, `max_loc` null — **card #2** omit/`null` parse) · **16**
(council pair + parsed `max_loc` — **card #2** on a non-null parse). Card #1 follows
`self-answer.md` §3f (argc 13 omit/`null`, argc 14 when override is set); council
pair stays **null**. Card #2 always supplies the council pair; on a non-null parse
it **MUST be argc 16** and copies `max_loc` from card #1. Stamp-fail halt with a
non-null override is the same argc-16 path (§2a). `grading_reason` carries the same
one-line, secret-redacted obligation as `rationale` (M13); it is grader- or
model-derived text, so scrub it before passing it, and the writer rejects
newlines/control chars.

> **The coded invariant is deliberately weaker than the prose rule — do not read it as the
> whole contract.** M13 scopes `council_tier` / `grading_reason` to the **M14 council card**
> — card #2 alone. What `append-card.sh` cross-field invariant (c) can actually check is
> `non-null ⇒ gate == "ship-choice"`, which *also* admits card #1. That gap is structural,
> not an oversight: cards #1 and #2 share `gate`, `run_id`, and `decided_by`. M13's
> discriminator is `actor` (card #2 carries the literal `ship-gate-council`; card #1
> never does, CDT-281) — but that rule is prose-enforced, here and in SPEC-033, not a
> writer cross-field check (`council_tier` is not a discriminator either: a stamp-fail
> card #2 has `council_tier: null`). `read-cards.sh` re-checks the same invariant on
> read and can do no better for the same reason; a reader of a ledger written before
> this revision falls back to append order within `run_id`. The narrower rule is
> therefore enforced **here**, by this procedure: `null` / `null` on card #1, §3a's
> resolved values only on card #2.

## 7. Boundaries — what this pass does NOT do

- **Introduce a 9th blocking condition.** M6's set of eight is complete; this pass **reuses
  BC7** with a council-derived confidence source **for `ship-choice` only** (M14(c)). Every
  other gate's BC7 keeps its self-reported source.
- **Revise card #1.** The original self-answered card is immutable; the council outcome is a
  **second** card, never an edit (M14(c), M13 append-only).
- **Render or pre-digest evidence.** No materialized evidence file, no render-helper script;
  investigators pull the ledger, spec/ACs, and diff themselves (M14(a), §3b). §3a's grading
  reads the same diff, but it feeds the **grader**, never the claim.
- **Change *whether* the pass fires.** §3a selects *which* council pipeline runs; the firing
  rule — `ship-choice` only, clean `pr`/`merge` only, exactly once, exactly two cards — is
  untouched (M14(e)). A grading failure grades `full`; it never skips, defers, or downgrades
  the pass.
- **Auto-select `skip`, or act on the tier-aware re-offer.** Grading cannot return `skip` and
  autopilot has no DRI (M14(e)); a human-supplied `--council-tier=skip` is recorded verbatim
  on the card, and this procedure defines no further `skip` behavior. Likewise the `light`-only
  full-council re-offer is surfaced to a human, never self-answered or auto-re-run (M14(f),
  N2 / M7).
- **Fire outside a clean ship-choice.** Never at `scope-confirm` or `plan-approve`, never on
  a ship-choice `halt`/`reroute-epic`, never more than once per attempt (M14, §2).
- **Halt on an unresolvable `origin/HEAD`.** That is N3a's BC3 check, evaluated later at a
  different step for a different purpose. Here the same probe only grades the tier (§3a).
- **Own halt escalation.** On a `blocking_condition = 7` card this pass writes the halt card
  and returns; surfacing the halt to a human belongs to the blocking-condition handler
  (halt-escalation owner), exactly as in `self-answer.md` §5.
- **Raise a ship above BC7.** The council verdict can only confirm card #1's clean answer or
  push it **down** to a BC7 halt; it can never clear a halt or lift confidence past the
  M6/M13 threshold on its own (M14(b), (d)).
- **Agree without process stamps.** MUST NOT take the agree path when §2a stamp pre-flight
  fails (SPEC-033 M14(a) CDT-185). Stamp fail → skip `/council`, BC7 halt, conf=0.
- **Put process assertions in the council claim when stamps clear process.** After stamps
  pass, the claim under audit is **technical-only**; MUST NOT re-assert process outcomes in
  the claim body (M14(a) CDT-185 narrow claim).
- **Apply stamp/claim rules outside M14 ship-gate.** Process-stamp + narrow-claim rules are
  **M14 ship-gate only** (M14(a) CDT-185 scope); no other `/council` caller inherits them.
- **Invoke `/council` once per AC.** Every technical AC rides in the single §3b invocation
  as its own claim in `plan.claims[]` (M14(a)); autopilot MUST NOT run one `/council`
  invocation per AC.
- **Pass a QA evidence file, runner log, or AC→evidence map to the council.** M14(a) forbids
  any pre-digested evidence payload beyond the locators §3b names. The card #1 stamp clears
  a `[process]` AC (M14(h)); a runner log never clears one.
- **Use `max_verdict_confidence`, a mean, or a vote.** Card #2's confidence is the verdict
  mapper's per-AC minimum only (M14(b)); this pass MUST NOT compute or accept any other
  aggregate.
- **Feed the mapper's output back into the council.** `skills/autopilot/ship-gate-verdict.sh`
  runs after the verdict, MUST NOT read evidence, spawn an agent, call `/council`, or write a
  file, and MUST NOT feed anything to the council (M14(i)).
