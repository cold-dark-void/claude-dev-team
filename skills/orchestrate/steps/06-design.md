<!-- /orchestrate phase body. Load via SKILL.md router — current step only. -->

## Step 6: Tech Lead designs approach

When `[ "$ORCH_TIER" = "light" ]`: do not spawn Tech Lead for a second design pass. The scoper-planner already wrote `$MROOT/.claude/plans/<YYYY-MM-DD>-<ISSUE-ID>-<slug>.md` with Tracking (Step 4). Skip the `@tech-lead — ACs are confirmed` spawn below. Present that plan summary. SPEC-033 `plan-approve` still fires — the Autopilot self-answer block below stays. Run the Step 6 spec commit fence, then Step 6b, then Step 6c.

Otherwise (omit / `standard` / `full`):

Feed confirmed ACs + Tech Lead's orientation to Tech Lead:

Before spawning @tech-lead:
```bash
ITER=$((ITER+1))   # one M9 stint (SPEC-033 M9)
# lint-ok: C3 — marketplace */ for-loop + -f guarded (SPEC-021 Q2 residual, CDT-82 PDH)
PDH=$( { [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -f "$CLAUDE_PLUGIN_ROOT/skills/plugin-dir.sh" ] && printf '%s\n' "$CLAUDE_PLUGIN_ROOT"; } || { [ -f skills/plugin-dir.sh ] && [ -f agents/pm.md ] && grep -qF '"name": "dev-team"' .claude-plugin/plugin.json 2>/dev/null && pwd; } || { _pr='${CLAUDE_PLUGIN_ROOT}'; [ "${_pr#\$}" = "$_pr" ] && [ -f "$_pr/skills/plugin-dir.sh" ] && printf '%s\n' "$_pr"; } || { for _mp in "$HOME"/.claude/plugins/marketplaces/*/; do [ -f "${_mp}skills/plugin-dir.sh" ] && [ -f "${_mp}agents/pm.md" ] && grep -qF '"name": "dev-team"' "${_mp}.claude-plugin/plugin.json" 2>/dev/null && printf '%s\n' "${_mp%/}" && break; done; } || find ~/.claude/plugins/cache \( -path '*/dev-team/*/skills/plugin-dir.sh' -o -path '*/dev-team-edge/*/skills/plugin-dir.sh' \) 2>/dev/null | awk -F/ '{ver=""; for(i=1;i<=NF;i++) if(($i=="dev-team"||$i=="dev-team-edge")&&i<NF){ver=$(i+1);break}; if(ver=="") next; m=ver; gsub(/-pre\./,"~pre.",m); p=($0 ~ /\/cache\/cold-dark-void\/dev-team\//)?2:(($0 ~ /\/cache\/cold-dark-void\/dev-team-edge\//)?1:0); print m "\t" p "\t" $0}' | sort -t $'\t' -k1,1V -k2,2n -k3,3 | tail -1 | cut -f3 | xargs -r dirname | xargs -r dirname )
printf 'PDH=%s\n' "$PDH" >&2
RESOLVE=$(bash "$PDH/skills/plugin-dir.sh" file skills/model-map/resolve-model.sh)
MODEL=$(bash "$RESOLVE" tech-lead)
printf '%s\n' "$MODEL"
EFFORT=$(bash "$RESOLVE" --effort tech-lead)
printf '%s\n' "$EFFORT"
```
Bash stdout = model string; empty → omit model.
Then `resolve-model.sh --effort` (same agent). Non-empty EFFORT → pass as Agent `effort` param; empty → omit (MUST NOT pass `""`).
Surface resolver stderr to the user. Do not swallow.
If MODEL is non-empty: pass it as the Agent model param.
If MODEL is empty: omit model. MUST NOT pass "".
If spawn fails attributed to the model param (invalid/unknown/unsupported model): retry once with model omitted; warn `model-map: host rejected model '<string>' for tech-lead; retrying with Tier default`.
If spawn fails attributed to the `effort` param (invalid/unknown/unsupported effort): retry once omitting effort; warn `model-map: host rejected effort '<token>' for tech-lead; retrying with inherited effort`.
Model host-reject stays independent. Ambiguous failure: do not guess; do not combinatorial-retry both params.
Other spawn failures MUST NOT be retried as a model or effort fallback.

```
@tech-lead — ACs are confirmed:

Output mode: terse

<final AC list>

Your earlier assessment: <affected files, specs, risks>

Produce:
1. Spec (create/update in specs/core/ with MUST/SHOULD/MUST NOT). Follow the
   writer rules in `skills/orchestrate/steps/plan-contract.md`. Write the
   confirmed ACs into a `## Acceptance criteria` section (SPEC-033 M14(g)),
   with the `[process]` tag and the two-space
   `Verify: bash <test file>` continuation. Do not copy that contract here.
   A technical AC MUST NOT carry a clause no command can check (style-only
   prose, e.g. "The text follows ASD-STE100."): a Verify line does not clear
   it — move the sentence to a `[process]` AC or delete it;
   `skills/spec-tooling/check-ac-clauses.sh` flags the known pattern set.
2. Implementation plan with task graph (dependencies, parallelism)
3. For each task: `Recommended agent: <ic4|ic5|qa|devops|ds>` and why.
   Cite agents/tech-lead.md Task-routing table.
   Escalation heuristic: assign ic5 (not ic4) when a task touches >10 files,
   modifies >15 callsites, or involves wide-scope structural deletion/renaming.
   ic4 excels at focused tasks; wide-scope structural work should go to ic5 or be split further.
4. Save the plan to the absolute plan home `$MROOT/.claude/plans/<YYYY-MM-DD>-<ISSUE-ID>-<slug>.md`
   (write-through). Tracking, Copy-extract, ticket_class, and process_acs come from
   `skills/orchestrate/steps/plan-contract.md`. Classify ticket_class with
   `skills/orchestrate/ticket-class.sh` (word boundary). Do not substring-match
   (`author` is not `auth`). Scan input is the ticket title, body, and ACs;
   the plan's own `ticket_class:` section is excluded when a plan file is
   re-scanned.
```

Present the plan summary to user:

```
Tech Lead's plan for <ISSUE-ID>:

Tasks:
1. <task> → ic4 (extends existing pattern)
2. <task> → ic5 (new module, needs design)
3. <task> → qa (acceptance tests from spec)
4. <task> → devops (Task-class: infra)

Dependencies: Task 3 blocked by Task 1+2
process_acs: <ids|none>

Approve this plan? Want changes?
```

### Step 6 trigger-(b) classifier at the wave-plan write (SPEC-039 M13.1; CDT-564)

When the advisor is enabled for this run (`ADVISOR_ON=true`, Step 0) and
`ADVISOR_SKIP_TRIGGER` is not `1` (interactive bypass), classify the composed
plan — including any mid-run rewrite of its `## Waves` / Task Map sections —
BEFORE persisting it or answering `plan-approve`. A zero-hit scan is a silent
skip (M17 miss sampling runs inside `classify.sh` under `--run-id`); advisor
off or bypassed, skip silently.

```bash
# Fresh shell — re-resolve PDH (SPEC-021 C1). CDT-564 trigger-(b) classifier.
# lint-ok: C3 — marketplace */ for-loop + -f guarded (SPEC-021 Q2 residual, CDT-82 PDH)
# Later fence: the single-line PDH wrapper (skills/lib/pdh-later-fence.sh,
# CDT-502-C5) — the file's first fence already carries the full stanza.
PDH="${PDH:-$( { [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -f "$CLAUDE_PLUGIN_ROOT/skills/plugin-dir.sh" ] && printf '%s\n' "$CLAUDE_PLUGIN_ROOT"; } || { [ -f skills/plugin-dir.sh ] && [ -f agents/pm.md ] && grep -qF '"name": "dev-team"' .claude-plugin/plugin.json 2>/dev/null && pwd; } || { _pr='${CLAUDE_PLUGIN_ROOT}'; [ "${_pr#\$}" = "$_pr" ] && [ -f "$_pr/skills/plugin-dir.sh" ] && printf '%s\n' "$_pr"; } || { for _mp in "$HOME"/.claude/plugins/marketplaces/*/; do [ -f "${_mp}skills/plugin-dir.sh" ] && [ -f "${_mp}agents/pm.md" ] && grep -qF '"name": "dev-team"' "${_mp}.claude-plugin/plugin.json" 2>/dev/null && printf '%s\n' "${_mp%/}" && break; done; } || find ~/.claude/plugins/cache \( -path '*/dev-team/*/skills/plugin-dir.sh' -o -path '*/dev-team-edge/*/skills/plugin-dir.sh' \) 2>/dev/null | awk -F/ '{ver=""; for(i=1;i<=NF;i++) if(($i=="dev-team"||$i=="dev-team-edge")&&i<NF){ver=$(i+1);break}; if(ver=="") next; m=ver; gsub(/-pre\./,"~pre.",m); p=($0 ~ /\/cache\/cold-dark-void\/dev-team\//)?2:(($0 ~ /\/cache\/cold-dark-void\/dev-team-edge\//)?1:0); print m "\t" p "\t" $0}' | sort -t $'\t' -k1,1V -k2,2n -k3,3 | tail -1 | cut -f3 | xargs -r dirname | xargs -r dirname )}"
if [ "${ADVISOR_ON:-}" = "true" ] && [ "${ADVISOR_SKIP_TRIGGER:-}" != "1" ]; then
  CLASSIFY=$(bash "$PDH/skills/plugin-dir.sh" file skills/advisor/classify.sh)
  HITS=$(bash "$CLASSIFY" --kind wave-plan --file "<plan-path>" --run-id "<RUN_ID>") || exit $?
  if [ "$HITS" != "[]" ]; then
    # One probe per hit (reserve b=4, M26): static-check.sh first (M19), then
    # ask.sh probe --trigger b --question <hit span> --evidence-dir <plan dir>
    # [--model "<ADVISOR_MODEL>" when Step 0 set one — SPEC-039 M37]
    # -> native spawn -> finalize, per skills/advisor/SKILL.md. A halt outcome
    # (BC7/BC8) MUST NOT persist the plan: emit task_blocked per
    # cross-cutting.md Tier B and return control.
    echo "advisor trigger-(b) hits at the wave-plan write: $HITS" >&2
  fi
fi
```

**Autopilot:** if `AUTOPILOT_ON` (Step 0), do NOT wait for the user here — this is the
autopilot-only `plan-approve` branch; when autopilot is off nothing changes and the
existing approval gate below fires as the sole gate. Compute AC9 freeze signals from
the plan (cite SPEC-033 AC9 / M9b; do **not** restate the tier table):
- `tasks` — plan task count (non-negative integer).
- `projected_loc` — projected **counted** LOC. For each plan path run
  `loc-exclude.sh is-excluded <path>` (exit 0 exclude / 1 count; MUST NOT exit 2).
  Caller applies M15 arm 3 (SPEC-009 specs/tests — the helper does not classify
  tests). `--max-loc=unbound` MUST NOT zero this signal.
- `waves` — `1` when the plan has no `depends_on` and no wave labels; else count
  topological ranks (independent tasks at the same depth share one rank).
Omit a missing signal (engine fallback `0,0,1`). Build the C3 §2 envelope
`{ workflow:"orchestrate", ticket_id:<ISSUE-ID>, gate:"plan-approve", run_id:RUN_ID,
iteration:ITER, run_start_epoch:RUN_START_EPOCH, autopilot_bump:AUTOPILOT_BUMP,
max_loc:MAX_LOC, tasks:<task count>, projected_loc:<counted LOC>, waves:<wave count>,
<per-task {file paths present?, verification step present?},
projected counted LOC / per-file size (`loc-exclude.sh is-excluded`; M15),
task-graph shape, destructive-op flags> }` and call
`skills/autopilot/self-answer.md`'s procedure. Act on `decision`:
- `approve` → continue to Step 6b then Step 6c then Step 7 exactly as the user's approval would.
- `reroute-epic` → print the one-line message below, hand off to `/epic` decompose, and
  return control.
  The `/epic` decompose invocation MUST carry the autopilot state forward — pass
  `--autopilot[=<bump>]` (or `AUTOPILOT=1`). When `<bump>` ∈ {patch,minor,major},
  also pass `--worktree --release <bump>` (seal-intent; MUST NOT land each child
  on master). `/epic` persists that bump as `release_bump` (SPEC-033 M11a / CDT-196).
  When the advisor is enabled for this run (Step 0 `ADVISOR_ON=true`,
  SPEC-039 M10/M37), also run `epic-lib set-with-advisor <EPIC-ID> true` before
  the handoff; append `"$ADVISOR_MODEL"` as the third argument when
  `[ -n "$ADVISOR_MODEL" ]`. Pass `ADVISOR=1`, plus `ADVISOR_MODEL="<model>"`
  when non-empty, into the `/epic` child environment.
  Advisor off: nothing persisted, no env exported (byte-identical off, M11).
<!-- include: skills/autopilot/halt-verdict.md agent=plan-approve -->
- `halt` → emit `task_blocked` (detail = the one-line message below) via **Passive
  notifications → Tier B** (fail-open; § in `cross-cutting.md`), then print the one-line message below and
  return control:
```
plan-approve <decision>: <rationale> — card: <card-file-path>
<!-- /include -->
```
Otherwise (autopilot off), the user-approval gate below applies unchanged.

Wait for user approval. This is the second escalation gate.

### Step 6 spec commit

This is the Step 6 spec commit that Step 6b couples to. Run it on the light path and on the standard/full path, after the spec exists and before Step 6b. Specs land on the feature branch. The plan stays on `$MROOT/.claude/plans` and is not committed.

```bash
# Step 6 spec commit — fresh shell (SPEC-021 C1)
PDH="${PDH:-$( { [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -f "$CLAUDE_PLUGIN_ROOT/skills/plugin-dir.sh" ] && printf '%s\n' "$CLAUDE_PLUGIN_ROOT"; } || { [ -f skills/plugin-dir.sh ] && [ -f agents/pm.md ] && grep -qF '"name": "dev-team"' .claude-plugin/plugin.json 2>/dev/null && pwd; } || { _pr='${CLAUDE_PLUGIN_ROOT}'; [ "${_pr#\$}" = "$_pr" ] && [ -f "$_pr/skills/plugin-dir.sh" ] && printf '%s\n' "$_pr"; } || { for _mp in "$HOME"/.claude/plugins/marketplaces/*/; do [ -f "${_mp}skills/plugin-dir.sh" ] && [ -f "${_mp}agents/pm.md" ] && grep -qF '"name": "dev-team"' "${_mp}.claude-plugin/plugin.json" 2>/dev/null && printf '%s\n' "${_mp%/}" && break; done; } || find ~/.claude/plugins/cache \( -path '*/dev-team/*/skills/plugin-dir.sh' -o -path '*/dev-team-edge/*/skills/plugin-dir.sh' \) 2>/dev/null | awk -F/ '{ver=""; for(i=1;i<=NF;i++) if(($i=="dev-team"||$i=="dev-team-edge")&&i<NF){ver=$(i+1);break}; if(ver=="") next; m=ver; gsub(/-pre\./,"~pre.",m); p=($0 ~ /\/cache\/cold-dark-void\/dev-team\//)?2:(($0 ~ /\/cache\/cold-dark-void\/dev-team-edge\//)?1:0); print m "\t" p "\t" $0}' | sort -t $'\t' -k1,1V -k2,2n -k3,3 | tail -1 | cut -f3 | xargs -r dirname | xargs -r dirname )}"
EPIC_LIB=$(bash "$PDH/skills/plugin-dir.sh" file skills/epic/epic-lib.sh)
WT_PATH=$(bash "$EPIC_LIB" ensure-ticket-worktree "<ISSUE-ID>") || {
  echo "orchestrate requires a git repository for worktree isolation." >&2
  exit 1
}
git -C "$WT_PATH" add specs/
git -C "$WT_PATH" diff --cached --quiet && exit 0
git -C "$WT_PATH" commit -m "spec: <ISSUE-ID> — add/update <feature area> spec"
```

If `specs/` has no staged change, the fence exits 0 and does not create an empty commit. Step 6b uses the dedicated context message when this fence already committed the spec.

### Step 6b: Domain glossary write-back on the worktree (conditional)

Mirror `/kickoff` Step 7b. After the plan is approved (or auto-approved), if this
run crystallized **user-confirmed** domain terms (AC resolution, design choices,
or Step 3b-missed plan delta):

1. Write into **`$WT_PATH/CONTEXT.md`** (never `$MROOT/CONTEXT.md`) per
   `skills/domain-glossary/SKILL.md`
2. Commit on `feat/<ISSUE-ID>` (or shared epic branch) — couple with the Step 6
   spec commit when both change in the same turn:
   ```bash
   # Fresh shell — re-derive WT (SPEC-021 C1)
   PDH="${PDH:-$( { [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -f "$CLAUDE_PLUGIN_ROOT/skills/plugin-dir.sh" ] && printf '%s\n' "$CLAUDE_PLUGIN_ROOT"; } || { [ -f skills/plugin-dir.sh ] && [ -f agents/pm.md ] && grep -qF '"name": "dev-team"' .claude-plugin/plugin.json 2>/dev/null && pwd; } || { _pr='${CLAUDE_PLUGIN_ROOT}'; [ "${_pr#\$}" = "$_pr" ] && [ -f "$_pr/skills/plugin-dir.sh" ] && printf '%s\n' "$_pr"; } || { for _mp in "$HOME"/.claude/plugins/marketplaces/*/; do [ -f "${_mp}skills/plugin-dir.sh" ] && [ -f "${_mp}agents/pm.md" ] && grep -qF '"name": "dev-team"' "${_mp}.claude-plugin/plugin.json" 2>/dev/null && printf '%s\n' "${_mp%/}" && break; done; } || find ~/.claude/plugins/cache \( -path '*/dev-team/*/skills/plugin-dir.sh' -o -path '*/dev-team-edge/*/skills/plugin-dir.sh' \) 2>/dev/null | awk -F/ '{ver=""; for(i=1;i<=NF;i++) if(($i=="dev-team"||$i=="dev-team-edge")&&i<NF){ver=$(i+1);break}; if(ver=="") next; m=ver; gsub(/-pre\./,"~pre.",m); p=($0 ~ /\/cache\/cold-dark-void\/dev-team\//)?2:(($0 ~ /\/cache\/cold-dark-void\/dev-team-edge\//)?1:0); print m "\t" p "\t" $0}' | sort -t $'\t' -k1,1V -k2,2n -k3,3 | tail -1 | cut -f3 | xargs -r dirname | xargs -r dirname )}"
   EPIC_LIB=$(bash "$PDH/skills/plugin-dir.sh" file skills/epic/epic-lib.sh)
   WT_PATH=$(bash "$EPIC_LIB" ensure-ticket-worktree "<ISSUE-ID>")
   git -C "$WT_PATH" add CONTEXT.md specs/
   git -C "$WT_PATH" commit -m "spec+context: <ISSUE-ID> — <feature area> + glossary"
   ```
   or a dedicated `context: <ISSUE-ID> — crystallized glossary terms` if specs
   already committed.
3. If no new terms, skip silently.

**MUST NOT** leave glossary as uncommitted dirt on the main tree while the
feature branch carries only specs/code.

### Step 6c: Security council on the approved plan (conditional)

Runs on light and on omit/`standard`/`full`. Independent of `--council-tier=skip`
(that skip is the Step 9 task-gate only — it MUST NOT short-circuit 6c).

Read `ticket_class:` from the approved plan. If missing, classify now with
`skills/orchestrate/ticket-class.sh` (word boundary; `author` is not auth-secrets).
Scan input is the ticket title, body, and ACs; the plan's own `ticket_class:`
section is excluded when a plan file is re-scanned. If the script cannot run,
use `auth-secrets`.

Glossary carve-out: before the PHRASE-then-WORD scan, mask every maximal [A-Za-z0-9-] token that lowercases to a hyphenated ## Terms column-1 compound. Mask char is x (length-preserving). Glossary path: first hit $WTROOT/CONTEXT.md → $WTROOT/docs/domain/CONTEXT.md → $MROOT/CONTEXT.md → $MROOT/docs/domain/CONTEXT.md (never the plugin install dir). TICKET_CLASS_GLOSSARY overrides that path; sentinel off disables. A missing or unreadable path is fail-closed (no carve-out).

If `ticket_class` is not `auth-secrets`, print one skip line and continue to
Step 7:
```
Step 6c (security council): skipped — ticket_class: none
```

#### Step 6c class-verify probe — advisor stage-2 demotion (CDT-589-C3; SPEC-039 trigger d)

When `ticket_class` is `auth-secrets` and the advisor is enabled for this run
(`ADVISOR_ON=true`, Step 0) and `ADVISOR_SKIP_TRIGGER` is not `1`, run AT MOST
ONE class-verify probe per run, BEFORE any `/council` invoke below
(SPEC-039 trigger d; reserve d=1, global cap 5 unchanged). Export
`TICKET_CLASS=<the plan's ticket_class value>` and stage the classifier
evidence — the ticket title, body, and ACs — into a fresh directory exported
as `CV_EVIDENCE_DIR` (M18 directory travel). The fixed question text lives
only in the advisor SKILL trigger table (`CLASS_VERIFY_QUESTION=`); the fence
reads it from there. Advisor off, bypassed, or `ticket_class: none`: zero
advisor calls, zero cards, zero added lines — byte-identical to the 6c path
without this child.

```bash
# Fresh shell — re-resolve PDH (SPEC-021 C1). CDT-589-C3 class-verify probe
# (SPEC-039 trigger d). At most ONE per run (reserve d=1, M26), BEFORE any
# /council invoke. Advisor off, bypassed, or ticket_class not auth-secrets:
# silent skip — byte-identical to today (no probe line, no card). A refused
# gate id fails closed to the council below; never a halt, never BC8.
# lint-ok: C3 — marketplace */ for-loop + -f guarded (SPEC-021 Q2 residual, CDT-82 PDH)
PDH="${PDH:-$( { [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -f "$CLAUDE_PLUGIN_ROOT/skills/plugin-dir.sh" ] && printf '%s\n' "$CLAUDE_PLUGIN_ROOT"; } || { [ -f skills/plugin-dir.sh ] && [ -f agents/pm.md ] && grep -qF '"name": "dev-team"' .claude-plugin/plugin.json 2>/dev/null && pwd; } || { _pr='${CLAUDE_PLUGIN_ROOT}'; [ "${_pr#\$}" = "$_pr" ] && [ -f "$_pr/skills/plugin-dir.sh" ] && printf '%s\n' "$_pr"; } || { for _mp in "$HOME"/.claude/plugins/marketplaces/*/; do [ -f "${_mp}skills/plugin-dir.sh" ] && [ -f "${_mp}agents/pm.md" ] && grep -qF '"name": "dev-team"' "${_mp}.claude-plugin/plugin.json" 2>/dev/null && printf '%s\n' "${_mp%/}" && break; done; } || find ~/.claude/plugins/cache \( -path '*/dev-team/*/skills/plugin-dir.sh' -o -path '*/dev-team-edge/*/skills/plugin-dir.sh' \) 2>/dev/null | awk -F/ '{ver=""; for(i=1;i<=NF;i++) if(($i=="dev-team"||$i=="dev-team-edge")&&i<NF){ver=$(i+1);break}; if(ver=="") next; m=ver; gsub(/-pre\./,"~pre.",m); p=($0 ~ /\/cache\/cold-dark-void\/dev-team\//)?2:(($0 ~ /\/cache\/cold-dark-void\/dev-team-edge\//)?1:0); print m "\t" p "\t" $0}' | sort -t $'\t' -k1,1V -k2,2n -k3,3 | tail -1 | cut -f3 | xargs -r dirname | xargs -r dirname )}"
if [ "${ADVISOR_ON:-}" = "true" ] && [ "${ADVISOR_SKIP_TRIGGER:-}" != "1" ] && [ "${TICKET_CLASS:-}" = "auth-secrets" ]; then
  GATES=$(bash "$PDH/skills/plugin-dir.sh" file skills/advisor/gates.sh)
  ASK=$(bash "$PDH/skills/plugin-dir.sh" file skills/advisor/ask.sh)
  SKILL=$(bash "$PDH/skills/plugin-dir.sh" file skills/advisor/SKILL.md)
  if bash "$GATES" allow --bc class-verify >/dev/null 2>&1; then
    # One home for the question text: the advisor SKILL trigger table.
    CV_QUESTION=$(sed -n 's/^CLASS_VERIFY_QUESTION=//p' "$SKILL" | head -n 1)
    bash "$ASK" probe --trigger d --question "$CV_QUESTION" \
      --evidence-dir "${CV_EVIDENCE_DIR:?stage the ticket evidence dir first (M18)}" \
      --run-id "<RUN_ID>" ${ADVISOR_MODEL:+--model "$ADVISOR_MODEL"}
  fi
fi
```

Act on the probe `action`:
- `spawn` — spawn the advisor Agent natively with the spawn-request question
  and the `CV_EVIDENCE_DIR` evidence, write the ruling file, then finalize
  with the card context (`--card-workflow orchestrate --card-ticket
  <ISSUE-ID> --card-gate plan-approve --card-iteration <ITER>
  --card-run-start-epoch <RUN_START_EPOCH>`). A demotion card is
  `decision: proceed`, `blocking_condition: null`, `actor: advisor`,
  `gate: plan-approve` — no new gate enum. A finalize exit 64 (bad ruling
  shape) is a council outcome, not a halt.
- `cache-hit` — the ruling is at `cached_ruling_path`; spawn nothing.
- `refuse` or `cap` — no probe is spent; run the `/council` invoke below.
  Cap exhaustion on this trigger NEVER maps to BC8 (the §3g BC8 fence is
  `a|b|c` only) — the council simply runs.
- finalize `--timeout` / `--spawn-fail` — no ruling exists; run the
  `/council` invoke below.

```bash
# CDT-589-C3 demotion decision (SPEC-039 M40/M41): demote ONLY on
# not-auth-relevant at confidence >= 80. Anything else — auth-relevant at any
# confidence, confidence < 80, refuse/cap, timeout/spawn-fail — runs the
# /council invoke below: fail-closed, never a halt, never BC8. The ruling
# never rewrites ticket_class (demotion-only; none is never raised to
# auth-secrets). The demoted path prints the existing skip line with
# class-verify named as the reason and continues to Step 7 — the council is
# NOT run.
if [ "${ADVISOR_ON:-}" = "true" ] && [ "${ADVISOR_SKIP_TRIGGER:-}" != "1" ]; then
  CV_RULING=$(jq -r '.ruling // empty' "<class-verify-ruling-file>" 2>/dev/null)
  CV_CONF=$(jq -r '.confidence // empty' "<class-verify-ruling-file>" 2>/dev/null)
  case "${CV_CONF:-}" in ''|*[!0-9]*) CV_CONF=0 ;; esac
  if [ "$CV_RULING" = "not-auth-relevant" ] && [ "$CV_CONF" -ge 80 ]; then
    echo "Step 6c (security council): skipped — class-verify: not-auth-relevant"
  fi
fi
```

Demoted → continue to Step 7; the council NOT run — skip the
`/council --plan <approved-plan-path>` invoke below. Every other outcome —
`auth-relevant` at any confidence, confidence < 80, advisor off or unmapped,
probe `refuse`/`cap`, finalize `--timeout`/`--spawn-fail` — runs the invoke
below unchanged: fail-closed to the council, never a halt, never BC8.

`<class-verify-ruling-file>` is the finalize's `runs/<RUN_ID>/ruling.json`
(or the `cached_ruling_path` on a cache hit).

If `ticket_class: auth-secrets` and the class-verify probe above did not
demote, invoke `/council --plan <approved-plan-path>`
unbound: no `--task-id`, no `--diff`, no `--preset diff-mode` (plan scope infers
`generic`). Do not export `CLAUDE_TASK_ID` for this invoke.

Honor `light|full` on the `/council` invoke: when `COUNCIL_TIER_OVERRIDE` is
`light` or `full`, pass `--council-tier=<that value>`. When it is `skip` or the
string `"null"`, omit `--council-tier` (commands/council.md omit → full).

Carry the Spawn concurrency cap on the same invoke (SPEC-013 § Spawn concurrency
cap, CDT-573): when `ORCH_CONCURRENCY` (Step 0) is non-empty, append
`--concurrency "$ORCH_CONCURRENCY"` as the last token of the
`/council --plan <approved-plan-path>` invocation. When it is empty, append nothing.
Resolve and validate nothing here — the engine's preflight owns the merge and its
exit 64 stderr surfaces verbatim. Step 6c is a fleet council run, so it takes the
cap; the cap never reaches a Step 8 IC spawn (SPEC-013 § CDT-573 AC2).

After `commands/council.md` Step 2 preflight writes `$PLAN_FILE`, append
`security` to `plan.flavors` if absent:

```bash
# PLAN_FILE is session-held (council Step 2); not a cross-fence export
PLAN_TMP=$(mktemp "${TMPDIR:-/tmp}/council-flavors.XXXXXX.json") \
  || { echo "orchestrate error: mktemp failed for flavor append"; exit 1; }
jq 'if ((.flavors // []) | index("security")) then . else .flavors = ((.flavors // []) + ["security"]) end' "$PLAN_FILE" > "$PLAN_TMP" && mv "$PLAN_TMP" "$PLAN_FILE"  # lint-ok: C1
```

`{{FLAVOR_DELTA}}` for `security` = body of `skills/council/flavors/security.md`.
`skills/council/prompts/investigator.md` output schema (`evidence_bundles`, later
`verdict[]`) always wins over that flavor's `output_shape_constraint: finding[]`
and "read every changed file". Skip Optional host SAST. MUST NOT add
`skills/council/flavors/*`.

MUST NOT spawn Step 8 ICs when any of:
- unstruck `CONTRADICTED` or `FABRICATED` with confidence ≥ 80
- unstruck `UNVERIFIED` with confidence ≥ 80
- report `verification_mode: self-verified` or marker `self-verified — refuters unavailable`
- no usable report

MUST NOT auto-replan (do not fire the replan gate).

**Autopilot — Step 6c fail:** if `AUTOPILOT_ON` (Step 0), do NOT wait for the user
here. (Off-triad checkpoint; canonical gate = `plan-approve` — SPEC-033 M8
mapping; no new gate enum value.) MUST NOT auto-replan.
- Verdict fail (`CONTRADICTED`|`FABRICATED`|`UNVERIFIED` conf≥80) → BC1 halt
  (expected `blocking_condition = 1`).
- Degraded / total-fail / no usable report → BC7 with confidence 0
  (expected `blocking_condition = 7`).

Build the C3 §2 envelope `{ workflow:"orchestrate", ticket_id:<ISSUE-ID>,
gate:"plan-approve", run_id:RUN_ID, iteration:ITER,
run_start_epoch:RUN_START_EPOCH, autopilot_bump:AUTOPILOT_BUMP, max_loc:MAX_LOC,
<trigger signal: Step 6c security council blocked Step 8> }` and call
`skills/autopilot/self-answer.md`'s procedure. Act on `decision`:
- `halt` → emit `task_blocked` (detail = the one-line message below) via **Passive
  notifications → Tier B** (fail-open; § in `cross-cutting.md`), then print the
  one-line message below and return control:
```
plan-approve <decision>: <rationale> — card: <card-file-path>
```
Otherwise (autopilot off): print the council report and wait. Do not proceed to
Step 7 or spawn Step 8 ICs.

Clean (remaining unstruck verdicts are `VERIFIED` or `PARTIALLY_VERIFIED`, or
claims are empty) → continue to Step 7 then Step 8.
`PARTIALLY_VERIFIED`: print one-line warning; do not block.
