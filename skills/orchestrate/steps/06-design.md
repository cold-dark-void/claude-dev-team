<!-- /orchestrate phase body. Load via SKILL.md router — current step only. -->

## Step 6: Tech Lead designs approach

When `[ "$ORCH_TIER" = "light" ]`: do not spawn Tech Lead for a second design pass. The scoper-planner already wrote `.claude/plans/<YYYY-MM-DD>-<ISSUE-ID>-<slug>.md` with Tracking (Step 4). Skip the `@tech-lead — ACs are confirmed` spawn below. Present that plan summary. SPEC-033 `plan-approve` still fires — the Autopilot self-answer block below stays. Then Step 6b, then Step 6c.

Otherwise (omit / `standard` / `full`):

Feed confirmed ACs + Tech Lead's orientation to Tech Lead:

Before spawning @tech-lead:
```bash
# lint-ok: C3 — marketplace */ for-loop + -f guarded (SPEC-021 Q2 residual, CDT-82 PDH)
PDH=$( { [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -f "$CLAUDE_PLUGIN_ROOT/skills/plugin-dir.sh" ] && printf '%s\n' "$CLAUDE_PLUGIN_ROOT"; } || { [ -f skills/plugin-dir.sh ] && pwd; } || { for _mp in "$HOME"/.claude/plugins/marketplaces/*/; do [ -f "${_mp}skills/plugin-dir.sh" ] && [ -f "${_mp}agents/pm.md" ] && printf '%s\n' "${_mp%/}" && break; done; } || find ~/.claude/plugins/cache -path '*/dev-team/*/skills/plugin-dir.sh' 2>/dev/null | awk -F/ '{ver=""; for(i=1;i<=NF;i++) if($i=="dev-team"&&i<NF){ver=$(i+1);break}; if(ver=="") next; m=ver; gsub(/-pre\./,"~pre.",m); p=($0 ~ /\/cache\/cold-dark-void\/dev-team\//)?1:0; print m "\t" p "\t" $0}' | sort -t $'\t' -k1,1V -k2,2n -k3,3 | tail -1 | cut -f3 | xargs -r dirname | xargs -r dirname )
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
1. Spec (create/update in specs/core/ with MUST/SHOULD/MUST NOT)
2. Implementation plan with task graph (dependencies, parallelism)
3. For each task: `Recommended agent: <ic4|ic5|qa|devops|ds>` and why.
   Cite agents/tech-lead.md Task-routing table.
   Escalation heuristic: assign ic5 (not ic4) when a task touches >10 files,
   modifies >15 callsites, or involves wide-scope structural deletion/renaming.
   ic4 excels at focused tasks; wide-scope structural work should go to ic5 or be split further.
4. Save plan to .claude/plans/<YYYY-MM-DD>-<ISSUE-ID>-<slug>.md
5. Include a Tracking section on the plan (from Step 1; edit if multi-item):

## Tracking
- source: linear | backlog | freeform
- ticket_id: <ISSUE-ID>
- closes:
  - backlog/<slug>.md
  - linear:<ID>
- autopilot_on: <true|false>
- autopilot_bump: <patch|minor|major|master|null>
6. Optional plan-level Copy-extract field (SPEC-003 Role Boundaries — cite that enum; do not invent a second vocabulary). Not a Tracking key. Not per-task. Heading then 0 or 1 token (`COPY-ACCEPTED: divergence-expected` or `EXTRACT-DEFERRED: pre-existing-dup`):

## Copy-extract
<0 or 1 canonical token>

Omit heading/line = default extract. Both lines, extra suffix, synonym, or Simplest/Rejected prose = unknown = not a waiver. False reason still fails.
7. Ticket-class (not a Tracking key). Case-insensitive substring match on title|body|ACs|plan against any of: auth, authentication, authorization, oauth, oidc, jwt, session, credential, secret, token, password, api key / api-key / apikey, private key / private-key, pii, ssn, csrf. Match → `ticket_class: auth-secrets`. Else `ticket_class: none`. Unsure → `ticket_class: auth-secrets`. Dual-home with kickoff Step 6. Emit a plan line:

ticket_class: auth-secrets|none

Many-to-one is allowed (one ticket closes multiple backlog items). Empty closes
only for freeform. `autopilot_on`/`autopilot_bump` MUST always be written, on
autopilot and non-autopilot runs alike — substitute the Step-0 resolved
`AUTOPILOT_ON`/`AUTOPILOT_BUMP` values (recording `autopilot_on: false`
explicitly on a non-autopilot run is a symmetric "remember it was NOT
autopilot" record, not just a true-case field). `autopilot_bump` is `null`
when autopilot is off, or when on in bare/pr-mode; may be `master` (land-no-release
sentinel, CDT-195) or a release token. pr-vs-merge is always derived from bump
(null→pr, else→merge — includes `master`) — do NOT record a separate field
(SPEC-033 M9a / CDT-111-C8 AC1). This is `resume-state.sh`'s Step-0 resume
detection read surface (CDT-111-C8).
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

Approve this plan? Want changes?
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
- `halt` → emit `task_blocked` (detail = the one-line message below) via **Passive
  notifications → Tier B** (fail-open; § below), then print the one-line message below and
  return control:
```
plan-approve <decision>: <rationale> — card: <card-file-path>
```
Otherwise (autopilot off), the user-approval gate below applies unchanged.

Wait for user approval. This is the second escalation gate.

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
   # lint-ok: C3 — marketplace */ for-loop + -f guarded (SPEC-021 Q2 residual, CDT-82 PDH)
   PDH=$( { [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -f "$CLAUDE_PLUGIN_ROOT/skills/plugin-dir.sh" ] && printf '%s\n' "$CLAUDE_PLUGIN_ROOT"; } || { [ -f skills/plugin-dir.sh ] && pwd; } || { for _mp in "$HOME"/.claude/plugins/marketplaces/*/; do [ -f "${_mp}skills/plugin-dir.sh" ] && [ -f "${_mp}agents/pm.md" ] && printf '%s\n' "${_mp%/}" && break; done; } || find ~/.claude/plugins/cache -path '*/dev-team/*/skills/plugin-dir.sh' 2>/dev/null | awk -F/ '{ver=""; for(i=1;i<=NF;i++) if($i=="dev-team"&&i<NF){ver=$(i+1);break}; if(ver=="") next; m=ver; gsub(/-pre\./,"~pre.",m); p=($0 ~ /\/cache\/cold-dark-void\/dev-team\//)?1:0; print m "\t" p "\t" $0}' | sort -t $'\t' -k1,1V -k2,2n -k3,3 | tail -1 | cut -f3 | xargs -r dirname | xargs -r dirname )
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

Read `ticket_class:` from the approved plan. If missing, classify now with the
same token list as item 7 above; unsure → `auth-secrets`.

If `ticket_class` is not `auth-secrets`, print one skip line and continue to
Step 7:
```
Step 6c (security council): skipped — ticket_class: none
```

If `ticket_class: auth-secrets`, invoke `/council --plan <approved-plan-path>`
unbound: no `--task-id`, no `--diff`, no `--preset diff-mode` (plan scope infers
`generic`). Do not export `CLAUDE_TASK_ID` for this invoke.

Honor `light|full` on the `/council` invoke: when `COUNCIL_TIER_OVERRIDE` is
`light` or `full`, pass `--council-tier=<that value>`. When it is `skip` or the
string `"null"`, omit `--council-tier` (commands/council.md omit → full).

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

