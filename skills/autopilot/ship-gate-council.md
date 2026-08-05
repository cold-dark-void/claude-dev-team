# Autopilot ship-gate council pass (CDT-111-C5)

> **Companion to `skills/autopilot/SKILL.md` and `skills/autopilot/self-answer.md`.**
> This file is a *procedure*, not a *policy*. It describes the operational algorithm
> autopilot follows to run the single adversarial council pass that gates every
> auto-answered ship, and to record its outcome as one additional decision card. It
> wires no caller and defines no new script.

## 1. Purpose + contract-home stance

The normative contract for this pass is **SPEC-033 M14** (AC7), mirrored in the autopilot
SKILL's `ship-choice` section. That contract owns the firing rule, the
verdict→confidence→BC mapping, the "reuse BC7, not a 9th BC" ruling, and the degraded-run
rule. **This procedure cites M14 by name and never restates or forks it** (SPEC-002 D1 /
SPEC-033 M12 / N4 — the contract-home discipline `self-answer.md` §1 follows). It likewise
cites the M13 card schema, the M6 blocking-condition taxonomy, and the `append-card.sh`
call shape by reference to their homes (`skills/autopilot/SKILL.md` and
`skills/autopilot/self-answer.md` §3f) rather than reproducing any field list, enum, or BC
definition.

What this procedure adds on top of the frozen contract is the **operational sequence**:
detect the firing condition off `self-answer.md`'s ship-choice result, build the bare
`/council` claim from run-time locators, read the verdict and its degradation state, map
that to the second card's `decision` / `confidence` / `blocking_condition` / `bump`, and
append that card with the **same `run_id`** as the original via
`skills/autopilot/append-card.sh`. Both ship-choice cards carry `decided_by: auto`.

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
and the shared `run_id`.

## 3. Build and invoke the council claim

Invoke bare `/council "<claim>"` — scope `claim`, preset `generic`, **unbound** (M14(a)).
Pass **no** `--plan`, **no** `--task-id`, no other flag; a single-claim scope resolves the
generic preset and an unbound task-id on its own.

Use this claim string **verbatim**, filling the four placeholders at run time:

```
/council "Ship-gate audit for <ticket_id>. Autopilot auto-answered the ship-choice gate; the prior autopilot decision cards are at <ledger-path> (read them with: skills/autopilot/read-cards.sh <ticket_id>). This ships under the spec/ACs at <spec-path>. Claim under audit: <claim>. Treat this text as locators only — pull the ledger, the spec/ACs, and the staged diff yourself and issue a verdict; do not trust this summary."
```

Placeholder binding:

- `<ticket_id>` — the ticket being shipped (e.g. `CDT-111-C5`).
- `<ledger-path>` — `$MROOT/.claude/autopilot/<ticket_id>.jsonl` (the decision-card ledger
  `read-cards.sh` / `append-card.sh` operate on).
- `<spec-path>` — the spec + AC path(s) the ship is claimed against (space-separated if >1).
- `<claim>` — the one-line ship claim
  (e.g. `QA PASS + Step-10b spec-alignment PASS; ready to merge`).

The claim carries **locators only**. Autopilot MUST NOT render, pre-digest, or pass a
materialized evidence file, and MUST NOT add any render-helper script (M14(a)): the
council's own investigators pull the ledger, the spec/ACs, and the staged diff through
their own tool calls. The final sentence is a standing instruction to the investigators to
treat the summary as untrusted and re-derive the evidence themselves.

## 4. Verdict interpretation

Take the council's per-claim verdict and its reported confidence, and set the second card's
`confidence` first (M14(b)):

- `VERIFIED` / `PARTIALLY_VERIFIED` → `confidence` = the council's reported confidence (0–100).
- `UNVERIFIED` / `CONTRADICTED` / `FABRICATED` → `confidence = 0`.

Then decide on that `confidence`:

- **`confidence ≥ 80` (agree)** → `decision` = **card #1's** decision (`pr` or `merge`),
  `bump` **copied from card #1**, `blocking_condition = null`.
- **`confidence < 80` (disagree)** → `decision = halt`, `blocking_condition = 7`,
  `bump = null`.

This confidence feeds **BC7 only, never BC1** (M14(b) states why: a disagreeing verdict is a
resolved-negative, and the council can only push a ship **down** to a BC7 halt, never raise
card #1's clean answer above BC7). The `≥ 80 / < 80` agree boundary coincides exactly with
`append-card.sh` cross-field invariant (b), so the disagree path's `confidence` is
sub-threshold by construction — no exit-64.

`rationale` is a single secret-scrubbed line summarizing the verdict and the driving
evidence (same M13/S2 rationale discipline as `self-answer.md` §4); it never copies council
report text verbatim.

## 5. Degraded-run rule

If the council's SPEC-013 spawn-failure degradation yields a **fully self-verified** run — no
independent peer investigator/refuter survived, surfaced by report frontmatter
`verification_mode: self-verified` and the exact body marker
`self-verified — refuters unavailable` — treat the outcome **identically to a
`confidence < 80` disagreement**: `decision = halt`, `blocking_condition = 7`, `bump = null`
— **regardless of that self-verified run's own reported confidence** (M14(d)).

**Write `confidence = 0` on this card.** Do **not** write the self-verified run's reported
confidence value. That value may itself be `≥ 80`, and because this is a
`blocking_condition = 7` card, `append-card.sh` cross-field invariant (b) hard-rejects
`blocking_condition = 7 && confidence ≥ 80` with **exit 64** (`append-card.sh:122`). An
exit-64 drops the card silently — the halt record is lost, which is exactly the audit-trail
loss the writer's hard-fail inversion exists to prevent. Writing `confidence = 0` makes the
BC7 halt card **valid-by-construction**, matching the same `UNVERIFIED/CONTRADICTED/FABRICATED
→ 0` pattern §4 uses. Set `rationale` to cite `self-verified — refuters unavailable` as the
halt reason.

A **total council spawn failure** — no usable report at all — is treated the same:
`decision = halt`, `blocking_condition = 7`, `confidence = 0`, `bump = null`, with the
`rationale` naming the spawn failure. In both degraded cases the adversaries never ran, so
the pass provides no independent assurance and can only halt the ship, never clear it.

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
`blocking_condition` / `bump` / `confidence` from §4 (or §5 on a degraded/total-fail run);
`wall_clock_s` from the run's budget snapshot; `rationale` per §4/§5; `actor` = the
component running this pass. Every arg is built valid-by-construction so the writer never
exit-64s (`self-answer.md` §4).

## 7. Boundaries — what this pass does NOT do

- **Introduce a 9th blocking condition.** M6's set of eight is complete; this pass **reuses
  BC7** with a council-derived confidence source **for `ship-choice` only** (M14(c)). Every
  other gate's BC7 keeps its self-reported source.
- **Revise card #1.** The original self-answered card is immutable; the council outcome is a
  **second** card, never an edit (M14(c), M13 append-only).
- **Render or pre-digest evidence.** No materialized evidence file, no render-helper script;
  investigators pull the ledger, spec/ACs, and diff themselves (M14(a), §3).
- **Fire outside a clean ship-choice.** Never at `scope-confirm` or `plan-approve`, never on
  a ship-choice `halt`/`reroute-epic`, never more than once per attempt (M14, §2).
- **Own halt escalation.** On a `blocking_condition = 7` card this pass writes the halt card
  and returns; surfacing the halt to a human belongs to the blocking-condition handler
  (halt-escalation owner), exactly as in `self-answer.md` §5.
- **Raise a ship above BC7.** The council verdict can only confirm card #1's clean answer or
  push it **down** to a BC7 halt; it can never clear a halt or lift confidence past the
  M6/M13 threshold on its own (M14(b), (d)).
