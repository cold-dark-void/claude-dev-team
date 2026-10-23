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

On **stamp pass**, continue to §2b. Process is pre-cleared; the claim under audit is
**technical-only** (M14(a) CDT-185 narrow claim — §3b).

This pre-flight and the verdict mapper's own guard 3 check (SPEC-033 M14(h)) are two
independent fail-closed layers, not duplicates to reconcile: the mapper
(`skills/autopilot/ship-gate-verdict.sh`) re-reads this same card #1 stamp shape against
`plan.process_acs[]` at mapping time, after the council has already run.

### 2b. Grok nest deferral (CDT-512-C6 / SPEC-033 M14(l))

After §2a stamp pass and **before** §3 tier selection, detect whether this session
can spawn `/council`. Resolve `skills/autopilot/nest-host.sh` through plugin-dir
and run it with `--ticket <ticket_id>`:

```bash
# Fresh shell — re-resolve PDH (SPEC-021 C1); managed later fence (SPEC-002 § Caller integration).
# lint-ok: C3 — marketplace */ for-loop + -f guarded (SPEC-021 Q2 residual, CDT-82 PDH)
PDH="${PDH:-$( { [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -f "$CLAUDE_PLUGIN_ROOT/skills/plugin-dir.sh" ] && printf '%s\n' "$CLAUDE_PLUGIN_ROOT"; } || { [ -f skills/plugin-dir.sh ] && [ -f agents/pm.md ] && grep -qF '"name": "dev-team"' .claude-plugin/plugin.json 2>/dev/null && pwd; } || { _pr='${CLAUDE_PLUGIN_ROOT}'; [ "${_pr#\$}" = "$_pr" ] && [ -f "$_pr/skills/plugin-dir.sh" ] && printf '%s\n' "$_pr"; } || { for _mp in "$HOME"/.claude/plugins/marketplaces/*/; do [ -f "${_mp}skills/plugin-dir.sh" ] && [ -f "${_mp}agents/pm.md" ] && grep -qF '"name": "dev-team"' "${_mp}.claude-plugin/plugin.json" 2>/dev/null && printf '%s\n' "${_mp%/}" && break; done; } || find ~/.claude/plugins/cache \( -path '*/dev-team/*/skills/plugin-dir.sh' -o -path '*/dev-team-edge/*/skills/plugin-dir.sh' \) 2>/dev/null | awk -F/ '{ver=""; for(i=1;i<=NF;i++) if(($i=="dev-team"||$i=="dev-team-edge")&&i<NF){ver=$(i+1);break}; if(ver=="") next; m=ver; gsub(/-pre\./,"~pre.",m); p=($0 ~ /\/cache\/cold-dark-void\/dev-team\//)?2:(($0 ~ /\/cache\/cold-dark-void\/dev-team-edge\//)?1:0); print m "\t" p "\t" $0}' | sort -t $'\t' -k1,1V -k2,2n -k3,3 | tail -1 | cut -f3 | xargs -r dirname | xargs -r dirname )}"
NEST_HOST=$(bash "$PDH/skills/plugin-dir.sh" file skills/autopilot/nest-host.sh)
NEST_JSON=$(bash "$NEST_HOST" --ticket "<ticket_id>")
CAN=$(jq -r .can_spawn_council <<<"$NEST_JSON")
```

`can_spawn_council=false` means **Grok nest** (`host=grok` and `nest_depth>=1`).
The child is already depth 1; the harness cannot spawn `/council`. This is a
harness adapter, not an away-flag path, and not a ninth BC. There is **no resident daemon**.

When `can_spawn_council` is false:

1. MUST NOT invoke `/council`.
2. MUST NOT write a BC7 halt (do not take §5 total-fail / mapper `--no-report`).
3. MUST NOT write card #2. The pass is **deferred**, not fired. Parent at
   `nest_depth` 0 fires M14 later against this card #1 (`exactly two` cards
   still hold for the attempt that actually fires).
4. MUST NOT print the CDT-135 resume-ship y hint. MUST NOT ping intercom /
   Telegram for a nest-depth y.
5. Print exactly:
   `needs-parent-M14 SHA=<git rev-parse HEAD> branch=<git rev-parse --abbrev-ref HEAD>`
6. Return that token as the Stage 2 outcome. Parent walker runs M14
   (`DEVTEAM_NEST_DEPTH=0` or unset) then Stage 3.

When `can_spawn_council` is true, continue to §3. Claude nested spawn remains
allowed. Depth-0 Grok still runs M14 here.

If `/council` is attempted and spawn fails, run
`nest-host.sh classify-spawn-fail`: `needs-parent-M14` takes this §2b path;
`bc7-spawn-fail` takes §5 (depth-0 M14(d) unchanged).

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

**Spawn concurrency cap passthrough (SPEC-013 § Spawn concurrency cap, CDT-573).** When the
parent `/orchestrate` run captured `--concurrency N` (its Step 0 `ORCH_CONCURRENCY` is
non-empty), append the two tokens ` --concurrency <N>` after `--council-tier=<tier>` in the
invocation below. `--council-tier=<tier>` stays the sole flag M14(a) permits: it is the only
flag that shapes the tribunal. The cap schedules fleet spawns — it adds no claim, plan, task,
or scope binding, so the pass stays unbound and locators-only. When `ORCH_CONCURRENCY` is
empty, append nothing: the engine resolves `COUNCIL_CONCURRENCY` and the Model map. Resolve
and validate nothing here; a bad value exits 64 at the engine's preflight and its stderr
surfaces verbatim. Overflow spawns queue into later batches — queueing is not a spawn failure
and never routes to §5's total-council-spawn-failure mapper (CDT-573 AC3).

Use this invocation **verbatim**, filling the five placeholders at run time and appending the
cap token only when `ORCH_CONCURRENCY` is set:

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
tier. One invocation is the normal case, and that one sidecar is the whole input. When the
pass was **split** across invocations, build one merged meta first (§4b): the mapper signature
below takes exactly one `--meta` argument (M14(i)), and a single run's sidecar is not a valid
input for a split pass:

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

### 4a. Trigger-(c) advisor appeal on residue (SPEC-039 M20–M22; CDT-561)

After §4's verdict mapper has produced its outcome and **before** §6 records card #2, this
pass MAY ask the advisor for a second opinion — **only** when the verdict carries residue
(any AC/finding below the pass threshold, `CONTRADICTED`/`UNVERIFIED`/`FABRICATED` splits,
or a degraded/`self-verified` run, per SPEC-039 M20). `skills/advisor/appeal.sh gate` is the
deterministic seam: a **clean pass** (no residue) writes nothing, prints nothing, and
reaches no advisor spawn path — zero advisor calls (M20). Advisor off or bypassed
(`ADVISOR_SKIP_TRIGGER=1`, interactive), the gate exits 0 without a probe (silent skip).

```bash
# Fresh shell — re-resolve PDH (SPEC-021 C1). CDT-561 trigger-(c) appeal.
# lint-ok: C3 — marketplace */ for-loop + -f guarded (SPEC-021 Q2 residual, CDT-82 PDH)
PDH="${PDH:-$( { [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -f "$CLAUDE_PLUGIN_ROOT/skills/plugin-dir.sh" ] && printf '%s\n' "$CLAUDE_PLUGIN_ROOT"; } || { [ -f skills/plugin-dir.sh ] && [ -f agents/pm.md ] && grep -qF '"name": "dev-team"' .claude-plugin/plugin.json 2>/dev/null && pwd; } || { _pr='${CLAUDE_PLUGIN_ROOT}'; [ "${_pr#\$}" = "$_pr" ] && [ -f "$_pr/skills/plugin-dir.sh" ] && printf '%s\n' "$_pr"; } || { for _mp in "$HOME"/.claude/plugins/marketplaces/*/; do [ -f "${_mp}skills/plugin-dir.sh" ] && [ -f "${_mp}agents/pm.md" ] && grep -qF '"name": "dev-team"' "${_mp}.claude-plugin/plugin.json" 2>/dev/null && printf '%s\n' "${_mp%/}" && break; done; } || find ~/.claude/plugins/cache \( -path '*/dev-team/*/skills/plugin-dir.sh' -o -path '*/dev-team-edge/*/skills/plugin-dir.sh' \) 2>/dev/null | awk -F/ '{ver=""; for(i=1;i<=NF;i++) if(($i=="dev-team"||$i=="dev-team-edge")&&i<NF){ver=$(i+1);break}; if(ver=="") next; m=ver; gsub(/-pre\./,"~pre.",m); p=($0 ~ /\/cache\/cold-dark-void\/dev-team\//)?2:(($0 ~ /\/cache\/cold-dark-void\/dev-team-edge\//)?1:0); print m "\t" p "\t" $0}' | sort -t $'\t' -k1,1V -k2,2n -k3,3 | tail -1 | cut -f3 | xargs -r dirname | xargs -r dirname )}"
APPEAL_META="<report>.finalize-meta.json"
APPEAL_REPORT="<report>"
if [ "${ADVISOR_ON:-}" = "true" ] && [ "${ADVISOR_SKIP_TRIGGER:-}" != "1" ]; then
  APPEAL=$(bash "$PDH/skills/plugin-dir.sh" file skills/advisor/appeal.sh)
  APPEAL_ARGS=(gate --meta "$APPEAL_META" --report "$APPEAL_REPORT" --run-id "<RUN_ID>")
  # SPEC-039 M37: forward the run's model override to the appeal probe.
  [ -z "${ADVISOR_MODEL:-}" ] || APPEAL_ARGS+=(--model "$ADVISOR_MODEL")
  APPEAL_OUT=$(bash "$APPEAL" "${APPEAL_ARGS[@]}") || exit $?
  if [ -n "$APPEAL_OUT" ]; then
    case "$(printf '%s' "$APPEAL_OUT" | jq -r '.action')" in
      spawn|cache-hit)
        # Spawn/finalize per skills/advisor/SKILL.md (probe never spawns; the
        # caller spawns natively), then map the ruling with
        # `appeal.sh authority --ruling-file <ruling> --run-id <RUN_ID>`:
        # `sustain-halt` keeps card #2's halt — the appeal outcome MUST NOT
        # persist any proceed/ship state; `re-council` runs a FRESH council
        # pass with new tool evidence — the appeal's word alone never ships
        # (M21, CONTRADICTED → fresh council pass only). Advisor-gathered
        # evidence stays under the advisor state root (M22);
        # `appeal.sh check-bundle-set --file <bundle set>` rejects any
        # advisor_appeal-labelled object injected into a council bundle set.
        echo "advisor trigger-(c) appeal on council residue: $APPEAL_OUT" >&2 ;;
      *) : ;;  # cap/refuse: no second opinion available; the verdict stands
    esac
  fi
fi
```

On `spawn`, the staged appeal evidence lives at
`runs/<RUN_ID>/appeal-evidence/` under the advisor state root — structurally
outside the council bundle directory (M22). On `cap`/`refuse` under autopilot,
the advisor is unavailable for this optional second opinion: the §4 verdict
stands unchanged (no BC8 card — the appeal is opt-in residue handling, not a
confirmed-AC dependency). `/review-and-commit` follows the same seam after its
own council verdict (`skills/advisor/appeal.sh gate --meta <report>.finalize-meta.json`).

### 4b. Split ship-gate pass: the merged-meta recipe (SPEC-033 M14(b), M14(d), M14(i); CDT-574-C6)

A ship-gate pass is **split** when the M14 evidence is too large for one council run
(observed above roughly 250 KB) and §3b's audit runs as several `/council` invocations, each
covering part of the ticket's AC list. SPEC-013 Phase 6 report no-overwrite collision-suffixes
each report inside one day: `.claude/council/2026-10-22-claim.md`, then `-claim-2.md` …
`-claim-5.md`. Each report writes its own `<report>.finalize-meta.json`. **No single one of
those sidecars is authoritative for the attempt.**

This section builds the mapper's **input**; it decides nothing. M14(b) owns per-AC
aggregation, M14(d) owns the degraded run, and M14(i) owns the mapper — this procedure cites
them and restates none. §4's mapper signature stays `--meta <one json>`: merge first, then
exactly one call. MUST NOT call the mapper once per run, and MUST NOT merge mapper outputs.
`skills/autopilot/ship-gate-verdict.sh` is byte-identical (WP 1-15 G), and this recipe adds
no script.

The firing rule is unchanged. §2's **exactly once** forbids one invocation per AC (M14(a)) and
one card #2 per invocation, not one invocation of a large audit. A split pass is one
ship-choice attempt audited in several runs: it still records **exactly two** cards (§6), and
card #2 comes from the single merged-meta mapper call. MUST NOT write one card #2 per run, and
MUST NOT grade the tier per run — §3a's one resolved tier covers the attempt.

On a split pass, §4a's `appeal.sh gate --meta` argument takes the same merged file, so the
residue probe sees every run.

**Step 1 — identify the sidecars of THIS attempt.** Take the report path that each §3b
`/council` invocation of this attempt printed on its `Council report:` line, and that
report's `<report>.finalize-meta.json` sidecar. That set of pairs is the input — the
invocations that ran this ship-gate attempt, and nothing else. Each invocation's plan file
records its own `run_id` and `cache_dir` (`council-cache-<run_id>`), which ties a report to
the invocation that printed it. MUST NOT glob `.claude/council/<date>-claim*.md`: a day-level
glob admits other passes — an earlier attempt, a non-M14 council, a `/review-and-commit` run —
whose verdicts never audited this ship.

**Step 2 — assert the set is one pass.** Every member MUST report the same `ac_source`. Two
different values mean two passes in one merge: halt BC7 on the M14(b) step-1 shape and name
both paths.

**Step 3 — merge the sidecars, key by key.**

| Sidecar key | Merged value |
|---|---|
| `struck_count`, `unstruck_verdict_count`, `unstruck_finding_count` | Sum across runs. |
| `verdict_counts` | Sum each taxonomy key across runs. |
| `max_verdict_confidence`, `max_verified_confidence` | Maximum across runs. Ignore `null` members; `null` only when every member is `null`. |
| `min_verdict_confidence` | Minimum across runs, same `null` rule. |
| `worst_verdict` | The worst value across runs, on the verdict order M14(b) step 2 defines (cited, not restated). |
| `unstruck_verdicts` | Concatenate every run's array. A re-audited AC keeps one verdict per run — the mapper matches them (M14(b) step 2). |
| `ac_claims` | One entry per audited AC. Dedupe by `claim_id` **within a run**, then drop a claim whose `ac_id` an earlier run already claimed: an AC audited in two runs MUST NOT be double-counted. Re-key each surviving `claim_id` with a run prefix (`r2-c0`) — every invocation numbers its own claims from `c0`, so a raw `claim_id` collides across runs. |
| `ac_source` | The common value from Step 2. |
| `process_acs` | Union of the ids across runs. |
| `verification_mode` | `self-verified` when **any** member is `self-verified`, else `full` (M14(d)). A healthy run never clears a degraded one. |
| `max_finding_confidence`, `finding_counts`, `finding_attention`, `unstruck_findings` | `null`. An M14 run is `verdict[]`-shape, so these are `null` in every member. |

**Step 4 — the conflict rule.** When one AC's claim — the same `claim_id`, matched by its
`[AC-<id>]` tag — carries **two different verdicts** across the merged set, the pass MUST NOT
merge them and MUST NOT pick the higher confidence. It halts BC7 on the M14(b) step-1 shape
(`decision = halt`, `blocking_condition = 7`, `confidence = 0`, `bump = null`) and the
`rationale` names that claim id. Two runs that agree on the verdict merge to one entry.

**Step 5 — the coverage assertion.** The merged `ac_claims[]` MUST name every technical AC of
the ticket's AC-source subsection (M14(g)), and the merged `process_acs[]` MUST name every
`[process]` AC. A per-run sidecar that covers only part of the AC list is **not** a valid
`--meta` input, and neither is a merged set with a gap. Feed §5's no-usable-report path instead
(`--no-report "split ship-gate: <ids> unaudited"`), which halts BC7. The mapper cannot find
this gap itself: it reads the AC list from the sidecar's own `ac_claims[]`, so a partial
sidecar under-reports every AC it omits and reads as a clean run.

**Shape check.** The merged file MUST stay a sidecar the mapper accepts: one JSON object,
`ac_claims[]` entries that are objects with a non-empty string `ac_id`, `process_acs` as a
JSON array, and `verification_mode` as `full` or `self-verified`. Anything else the mapper
reports as a malformed sidecar (M14(i)) — it never guesses.

**Worked example — the observed `dRPDwyJo` shape.** CDT-573 shipped on
`specs/core/SPEC-013-adversarial-council-tribunal.md` § `### CDT-573`: 12 ACs, `AC11` tagged
`[process]`, so **11 technical ACs** (`AC1` … `AC10`, `AC12`). The pass split into five
invocations on 2026-10-22:

| Invocation | Report | `ac_claims` (`claim_id` → `ac_id`) |
|---|---|---|
| 1 | `2026-10-22-claim.md` | `c0→AC1` `c1→AC2` `c2→AC3` `c3→AC4` |
| 2 | `2026-10-22-claim-2.md` | `c0→AC5` `c1→AC6` `c2→AC7` `c3→AC8` |
| 3 | `2026-10-22-claim-3.md` | `c0→AC9` `c1→AC10` |
| 4 | `2026-10-22-claim-4.md` | `c0→AC12` |
| 5 | `2026-10-22-claim-5.md` | `c0→AC12` (re-audit) |

Merge, member by member:

- `ac_claims`: 4 + 4 + 2 + 1 = **11 entries** — `r1-c0` … `r1-c3`, `r2-c0` … `r2-c3`, `r3-c0`,
  `r3-c1`, `r4-c0`. Run 5's `c0→AC12` is dropped: `AC12` is already claimed by run 4, so the
  AC counts once and never twice.
- `process_acs`: `["AC11"]` — the union; every member reported it.
- Coverage (Step 5): 11 technical ACs in, 11 out, `AC11` present → **pass**.
- Counts: `struck_count` `0+1+0+0+0 = 1`; `unstruck_verdict_count` `4+4+2+1+1 = 12`;
  `verdict_counts` sums per key, for example `VERIFIED` `4+3+2+1+1 = 11` and
  `PARTIALLY_VERIFIED` `0+1+0+0+0 = 1`.
- Confidences: `min_verdict_confidence` = min(86, 84, 90, 92, 91) = **84**;
  `max_verdict_confidence` = max(95, 97, 93, 92, 91) = **97**; `max_verified_confidence`
  follows the same maximum rule.
- `worst_verdict`: run 2 reports `PARTIALLY_VERIFIED`, so the merged value is
  `PARTIALLY_VERIFIED`.
- `verification_mode`: all five report `full` → **`full`**. Had run 3 come back
  `self-verified`, the merged value is `self-verified` and M14(d) halts on it whatever the
  other four reported.
- `unstruck_verdicts`: 12 entries. Two carry the `[AC-AC12]` tag (runs 4 and 5). Equal
  verdicts merge to one entry; a split verdict is Step 4's BC7 halt.

Then §4 makes its one call on the merged file:

```bash template
skills/autopilot/ship-gate-verdict.sh --meta "${TMPDIR:-/tmp}/m14-merged-meta.json" --card1 <card1.json> --tier <tier>
```

The defect this closes: feeding `-claim-5.finalize-meta.json` alone. Its `ac_claims` is
`[{c0, AC12}]`, so the mapper audits one AC, sees it clear, and card #2 ships with 10 of 11
technical ACs unaudited and no signal that they were ever in scope.

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
(append-card.sh cross-field invariant (b)); an exit-64 would drop the halt record silently, exactly the
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
- **Feed the mapper one run's sidecar on a split pass, or decide the merge by the day.** A
  split attempt merges the sidecars of its own invocations into one file first (§4b). MUST
  NOT glob `.claude/council/<date>-*.md`, MUST NOT name one run's sidecar authoritative, and
  MUST NOT merge mapper outputs: the mapper takes one `--meta` (M14(i)) and reads its AC
  universe from that file, so a partial input under-reports the rest in silence.
- **Use `max_verdict_confidence`, a mean, or a vote.** Card #2's confidence is the verdict
  mapper's per-AC minimum only (M14(b)); this pass MUST NOT compute or accept any other
  aggregate.
- **Feed the mapper's output back into the council.** `skills/autopilot/ship-gate-verdict.sh`
  runs after the verdict, MUST NOT read evidence, spawn an agent, call `/council`, or write a
  file, and MUST NOT feed anything to the council (M14(i)).
- **BC7-halt a Grok nested child because `/council` cannot spawn.** That is §2b
  `needs-parent-M14` (CDT-512-C6 / M14(l)), not §5. §5 still applies at
  `nest_depth` 0. MUST NOT write a BC7 halt for nest depth. MUST NOT invent a
  ninth BC. There is no resident daemon.
