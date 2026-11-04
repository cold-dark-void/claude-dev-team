<!-- /autopilot stage body — the one ship pipeline. Cites the stage
     procedures; it restates no contract. Loaded by /orchestrate Step 11. -->

# One ship pipeline (classify → self-answer → ship-gate-council → end-state)

The clean `ship-choice` path is **one ordered pipeline**, not ad-hoc jumps.
`/orchestrate` Step 11 enters here; each stage keeps its own contract home and
is cited, never forked:

| Stage | Contract home (cite) | Produces |
|-------|----------------------|----------|
| 0. Classify — **`--autopilot=auto` only** (SPEC-041 M5–M11) | `skills/autopilot/classify.md` | this item's concrete ship-gate bump ∈ `{patch, minor}` — or a `no-code` skip / `halt` card that ends the pipeline here |
| 1. Decide | `skills/autopilot/self-answer.md` | card #1 — the clean `pr`/`merge` (+ `bump`) decision, `decided_by=auto` |
| 2. Audit | `skills/autopilot/ship-gate-council.md` | card #2 (same `run_id`) — the post-council **effective decision** |
| 3. Execute | `skills/autopilot/end-state.md` | the land: shared preflight → §5-release **or** §5-land-no-release → §5.5 ship-history → §6 closeout |

Run the stages **in order**; a stage runs only after the previous one returned
its artifact. Stage 2 is skipped **only** for the case `ship-gate-council.md §2`
already defines (card #1 is `halt`/`reroute-epic` — then the effective decision
is card #1's). Stage 2 is **deferred** (not fired) when `nest-host.sh` reports
`can_spawn_council=false`: print `needs-parent-M14` and return; parent at
`nest_depth` 0 runs Stage 2. That is not a BC7 halt. Stage 3 runs only on an
effective `merge` under a non-null `--autopilot=<token>`; an effective `pr`
takes Step 11 Option 1 and stops. Stage 0 runs only under the `auto`
ship-intent token and is **pre-ship-choice**: it decides the bump the later
stages see, before any of them answers the gate.

```bash
# Fresh shell — resolve the stage docs through the plugin root.
# lint-ok: C3 — marketplace */ for-loop + -f guarded (SPEC-021 Q2 residual, CDT-82 PDH)
PDH=$( { [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -f "$CLAUDE_PLUGIN_ROOT/skills/plugin-dir.sh" ] && printf '%s\n' "$CLAUDE_PLUGIN_ROOT"; } || { [ -f skills/plugin-dir.sh ] && [ -f agents/pm.md ] && grep -qF '"name": "dev-team"' .claude-plugin/plugin.json 2>/dev/null && pwd; } || { _pr='${CLAUDE_PLUGIN_ROOT}'; [ "${_pr#\$}" = "$_pr" ] && [ -f "$_pr/skills/plugin-dir.sh" ] && printf '%s\n' "$_pr"; } || { for _mp in "$HOME"/.claude/plugins/marketplaces/*/; do [ -f "${_mp}skills/plugin-dir.sh" ] && [ -f "${_mp}agents/pm.md" ] && grep -qF '"name": "dev-team"' "${_mp}.claude-plugin/plugin.json" 2>/dev/null && printf '%s\n' "${_mp%/}" && break; done; } || find ~/.claude/plugins/cache \( -path '*/dev-team/*/skills/plugin-dir.sh' -o -path '*/dev-team-edge/*/skills/plugin-dir.sh' \) 2>/dev/null | awk -F/ '{ver=""; for(i=1;i<=NF;i++) if(($i=="dev-team"||$i=="dev-team-edge")&&i<NF){ver=$(i+1);break}; if(ver=="") next; m=ver; gsub(/-pre\./,"~pre.",m); p=($0 ~ /\/cache\/cold-dark-void\/dev-team\//)?2:(($0 ~ /\/cache\/cold-dark-void\/dev-team-edge\//)?1:0); print m "\t" p "\t" $0}' | sort -t $'\t' -k1,1V -k2,2n -k3,3 | tail -1 | cut -f3 | xargs -r dirname | xargs -r dirname )
printf 'PDH=%s\n' "$PDH" >&2
STAGE_CLASSIFY=$(bash "$PDH/skills/plugin-dir.sh" file skills/autopilot/classify.md)
STAGE_DECIDE=$(bash "$PDH/skills/plugin-dir.sh" file skills/autopilot/self-answer.md)
STAGE_AUDIT=$(bash "$PDH/skills/plugin-dir.sh" file skills/autopilot/ship-gate-council.md)
STAGE_EXECUTE=$(bash "$PDH/skills/plugin-dir.sh" file skills/autopilot/end-state.md)
```

## Stage 0 — Classify (`--autopilot=auto` only, SPEC-041 M5–M11)

Under the `auto` ship-intent token, Stage 0 runs **before** Stage 1 and decides
this item's concrete bump: in-session two-stage LLM judgment on the diff
against the N3a worktree baseline — the **resolved push target** (resolve it
per `end-state.md` §3, fetch included) — exactly once per item, pre-fold, no
spawned agent. Stage 0's code-bearing judgment carries no deterministic path
filter (M8); the deterministic Surface veto applies only after the stage-1
answer (M9). Follow `classify.md`; its fence prints the outcome:

- **`no-code`** — the baseline diff has no code-bearing change: journal from
  the closed M20 enum via `sweep.sh walk-outcome --halt auto-stage-0-no-code`
  (the walk's non-shipped outcome; the condition name rides `evidence` —
  sweep.md Step 9e), then return before Stage 1. Zero cards, zero tags, no
  fold; the walk continues with the next item.
- **`decided`** (`patch` | `minor`, veto already applied) — substitute the
  decided token as the Stage-1 envelope's `autopilot_bump` and compose
  `CLASSIFY_EVIDENCE` + the veto result into card #1's `rationale` (the
  evidence rides the ship-choice card, M10 — Stage 0 itself writes no card).
  Stage 3 then reaches **`/release <decided bump>`** with that explicit token
  (§5-release): the bump is never re-classified at fold, and `major` is
  unreachable.
- **`halt`** — stage 1 returned `halt` (e.g. a would-be major) or its response
  was empty / non-enum / malformed / absent (fail-closed, M7): Stage 0's fence
  writes the one `decision:"halt"` ship-choice card with `bump:null` (M13/M10),
  then return before Stage 1. The caller journals via
  `walk-outcome --halt auto-classify-halt` (M20 enum, `pr-stopped`), raises
  the escalation, and the walk continues — no tag, no fold; Stages 1–3 do not
  run.

## Stage 1 — Decide (self-answer)

Build the C3 §2 envelope (workflow `orchestrate`, gate `ship-choice`, the
Step-10b spec-alignment result, QA PASS/FAIL, the session-local `qa_bounces`
count (BC2), and ship-action irreversibility) and follow
`self-answer.md`'s procedure. It records the clean answer as **card #1**
(`blocking_condition = null` on a clean `pr`/`merge`). Under `auto`, card #1's
`rationale` carries Stage 0's `CLASSIFY_EVIDENCE` — the classification
evidence and the veto result (M10). A `halt`/`reroute-epic`
card #1 ends the pipeline after the Step-11 halt/reroute wording — no audit, no
land.

## Stage 2 — Audit (ship-gate-council)

On a clean card #1, run `ship-gate-council.md`'s procedure **before any ship
action** — on **both** `pr` and `merge`. It appends **card #2** (same
`run_id`) and yields the post-council effective decision: council **agree**
(conf ≥ 80, non-degraded) keeps card #1's `pr`/`merge`; **disagree / degraded
/ total-fail** forces `halt` (BC7). Grok nest (§2b) yields `needs-parent-M14`
instead of card #2. Act on the **post-council effective decision** only.

## Stage 3 — Execute (end-state)

On an effective `merge`, run `end-state.md` (shared preflight, then branch on
`AUTOPILOT_BUMP` — SPEC-033 N3a / CDT-195): deterministic BC3 push-target check
(N3a) → record `SHIP_START_SHA` → `git merge --squash <branch>` (stage only) →
`AUTOPILOT_BUMP ∈ {patch,minor,major}` → **§5-release** (`/release <bump>` is
the sole commit+tag+push; never pass `master`). Under `auto`,
`AUTOPILOT_BUMP` is Stage 0's **decided** token: it reaches
`/release <decided bump>` explicitly and is never re-classified at fold (M5);
`auto` and `major` never appear there. `AUTOPILOT_BUMP = master` →
**§5-land-no-release** (interactive-shape commit + non-force push; **MUST
NOT** touch `/release`, version files, tag, or CHANGELOG) → §5.5 ship-history
clean check (SPEC-010 H) → §6 closeout. On an effective `pr`, take Step 11
Option 1 (Create PR) and stop — no land, no `/release`.

Exits that leave the pipeline early are the ones the stage docs and Step 11
already define: CDT-141-C4 `RELEASE_END_BLOCKED=true` (print the assert
message, `task_blocked`, return — baseline unchanged, release **and**
land-no-release forbidden mid-epic), ship-history dirty (`history dirty —
rewrite needed`, H8), the Step-11 resume hint on a BC7 halt, and
`needs-parent-M14` (Grok nest; parent runs M14; no resume-ship y).
