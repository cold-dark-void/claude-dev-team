---
name: review-and-commit
description: |
    Use when about to commit — brutally honest review of staged/modified files,
    no sugar-coating. Thin wrapper over the council engine with preset
    `diff-mode`: 5 specialist investigators (logic, security, compliance,
    quality, simplification) run in parallel, filtered at confidence 80. Blocks
    commit on critical or compliance findings. Optional path argument saves the
    review to a file.
---

# Review and Commit

This command is `/council --diff --tier full` plus optional pre-steps and a
commit-gate post-step. It is not a second tribunal. The engine owns the
adversarial pipeline (`preset: diff-mode`). User-facing review text comes
only from `skills/council/templates/legacy-review.md`.

## Arguments

- No argument: print review as text only
- `/review-and-commit <path>`: also save the rendered review to that file
- `/review-and-commit --impact`: run blast radius analysis before review (adds affected callers as supplementary context for reviewers)
- `/review-and-commit --impact <path>`: both impact analysis and save to file
- `/review-and-commit --external` / `--external=codex|gemini`: optional external
  investigator slot (CDV-207; passthrough to council preflight). Detection
  order codex → gemini; graceful skip if none installed. Never replaces the
  5 internal specialists.

## Step 1: Stage and inspect

```bash
# lint-ok: C3 — marketplace */ for-loop + -f guarded (SPEC-021 Q2 residual, CDT-82 PDH)
PDH=$( { [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -f "$CLAUDE_PLUGIN_ROOT/skills/plugin-dir.sh" ] && printf '%s\n' "$CLAUDE_PLUGIN_ROOT"; } || { [ -f skills/plugin-dir.sh ] && [ -f agents/pm.md ] && grep -qF '"name": "dev-team"' .claude-plugin/plugin.json 2>/dev/null && pwd; } || { _pr='${CLAUDE_PLUGIN_ROOT}'; [ "${_pr#\$}" = "$_pr" ] && [ -f "$_pr/skills/plugin-dir.sh" ] && printf '%s\n' "$_pr"; } || { for _mp in "$HOME"/.claude/plugins/marketplaces/*/; do [ -f "${_mp}skills/plugin-dir.sh" ] && [ -f "${_mp}agents/pm.md" ] && printf '%s\n' "${_mp%/}" && break; done; } || find ~/.claude/plugins/cache -path '*/dev-team/*/skills/plugin-dir.sh' 2>/dev/null | awk -F/ '{ver=""; for(i=1;i<=NF;i++) if($i=="dev-team"&&i<NF){ver=$(i+1);break}; if(ver=="") next; m=ver; gsub(/-pre\./,"~pre.",m); p=($0 ~ /\/cache\/cold-dark-void\/dev-team\//)?1:0; print m "\t" p "\t" $0}' | sort -t $'\t' -k1,1V -k2,2n -k3,3 | tail -1 | cut -f3 | xargs -r dirname | xargs -r dirname )
printf 'PDH=%s\n' "$PDH" >&2
CHANGED=$(bash "$PDH/skills/plugin-dir.sh" file skills/lib/changed-set.sh)
bash "$CHANGED" paths
git diff --cached
git diff
```

The path list is the reviewed set: committed range, staged, unstaged, and
untracked files. Save it. If it is empty, stop. Read every path in full,
including untracked files — do not review hunks in isolation.

## Step 1b: Blast radius analysis (only when `--impact` is passed)

Skip this step entirely if `--impact` was not passed. When enabled:

1. **Extract changed symbols** — parse the diff hunks for function, method,
   and class names that were modified (added, removed, or changed signature).
   Use simple regex heuristics, not a full parser:
   - Python: `def <name>`, `class <name>`
   - JS/TS: `function <name>`, `<name>(`, `class <name>`, `export.*<name>`
   - Go: `func <name>`, `func (.*) <name>`
   - Rust: `fn <name>`, `struct <name>`, `impl <name>`
   - Shell: `<name>()`, `function <name>`
   - Fallback: any line matching `^\+.*\b(def|func|fn|function|class|struct|impl)\s+(\w+)`

2. **Find callers** — for each extracted symbol, grep the codebase for
   references (exclude the changed files themselves, test files, and
   vendor/node_modules directories):
   ```bash
   # One --include per extension: grep does not brace-expand a pattern.
   grep -rl --include='*.py' --include='*.js' --include='*.ts' --include='*.go' \
     --include='*.rs' --include='*.sh' '<symbol>' . \
     | grep -v node_modules | grep -v vendor | grep -v __pycache__
   ```
   Cap at 20 caller files total to avoid context blowout.

3. **Build impact context** — produce a concise summary:
   ```
   ## Impact Analysis (--impact)

   Changed symbols: <list>
   Affected files (callers): <N files>
   - path/to/caller1.py:42 — calls <symbol>
   - path/to/caller2.go:18 — references <symbol>
   ...

   Reviewers: check these callers for compatibility with the changes above.
   ```

4. **Pass to specialists** — include the impact context as supplementary
   material in the Phase 1 investigator prompts (alongside the diff and
   changed-file contents). Specialists should flag callers that may break
   due to signature changes, removed functions, or altered behavior.

5. **Optional Graphify path** (companion only) — if `command -v graphify`
   succeeds and `graphify-out/graph.json` exists (or user just ran
   `/graphify .`), for up to 5 high-degree changed symbols try:
   ```bash
   graphify path "<SymbolA>" "<SymbolB>" 2>/dev/null || true
   graphify explain "<Symbol>" 2>/dev/null || true
   ```
   Append any useful path/explain lines under the Impact Analysis block.
   If `graphify` is missing or the graph is absent, skip silently — never
   install Graphify for the user. See `docs/setup.md` optional companions.

If no symbols are extracted (e.g., only config/doc changes), skip silently
and proceed without impact context.

## Step 1c: Optional host SAST (fail-open)

Skip entirely when `SECURITY_SCAN=0`. Otherwise run:

```bash
PDH="${PDH:-<PDH>}"   # session root carried from the stanza fence above — re-run that fence first when not held
SCAN=$(bash "$PDH/skills/plugin-dir.sh" file skills/security-scan/scan.sh)
SCAN_LOG=$(bash "$SCAN" 2>&1) || true
printf '%s\n' "$SCAN_LOG"
```

`scan.sh` always exits 0. When tools are missing it prints SKIP. When Semgrep
or CodeQL produce artifacts, pass the summary (and paths) as supplementary
context for the **security** investigator only. Never block commit because
tools are absent. See `skills/security-scan/SKILL.md`.

## Step 2: Locate the council engine

Same resolution pattern as `commands/council.md`:

```bash
PDH="${PDH:-<PDH>}"   # session root carried from the stanza fence above — re-run that fence first when not held
ENGINE_SH=$(bash "$PDH/skills/plugin-dir.sh" file skills/council/engine.sh)
[ -x "$ENGINE_SH" ] || { echo "error: council engine.sh not found" >&2; exit 1; }
```

## Step 3: Preflight (diff-mode preset)

```bash
PDH="${PDH:-<PDH>}"   # session root carried from the stanza fence above — re-run that fence first when not held
ENGINE_SH=$(bash "$PDH/skills/plugin-dir.sh" file skills/council/engine.sh)
PLAN_FILE=$(mktemp "${TMPDIR:-/tmp}/review-and-commit-plan.XXXXXX.json") \
  || { echo "review-and-commit error: mktemp failed for PLAN_FILE"; exit 1; }
# Pass --external / --external=codex|gemini through when the user supplied it.
EXT_ARGS=()
# set EXT_ARGS=(--external) or (--external=codex) etc. from user CLI
"$ENGINE_SH" preflight --scope diff --preset diff-mode --tier full "${EXT_ARGS[@]}" > "$PLAN_FILE"
# Every fence is a separate shell: print the path so the Step 5 fence can be given it.
printf 'PLAN_FILE=%s\n' "$PLAN_FILE"
```

Keep the printed `PLAN_FILE=<path>` line. The Step 5 fence runs in a new shell and does
not see `$PLAN_FILE`; you paste the path into it.

Preflight runs Phase 0 intake including spec-grep enrichment over
`$MROOT/specs/**/*.md` for MUSTs matching changed paths. The plan declares
`output_shape: finding[]`, flavor list (logic, security, compliance, quality,
simplification), `spec_grep: true`, `feedback_memory_enabled: false`,
`confidence_filter_threshold: 80`. When `--external` was passed,
`plan.external` carries detection status (available|skipped); missing CLI is
never a hard fail.

## Step 3.5: Workflow opt-in (CDV-196)

Same opt-in as `/council`: `--workflow` **or** `COUNCIL_WORKFLOW=1`. When set,
run capability probe (`skills/council/workflow-probe.sh`); on fail print
`council: Workflow unavailable; falling back to engine.sh` and continue with
the Task path below (`verification_mode: full` — not degraded). On success,
dispatch `skills/council/workflow.js` with `scope: diff`, `preset: diff-mode`,
and `council_tier: full`. Do not omit `council_tier`. The script forwards it
as `--tier`. Then skip Steps 4–5 Task spawns (script owns preflight→finalize). Full dual-path
protocol: `skills/council/SKILL.md` § Workflow execution path — do not restate.

## Step 4: Drive `/council --diff --tier full`

Follow `commands/council.md` for `/council --diff`. Do not restate the phase
list here. Call-site deltas:

- Step 3 already passed `--tier full`. Do not grade a lighter tier at this call site.
- Pass impact context from Step 1b when `--impact` was used. Pass the Step 1c
  SAST summary to the security investigator only.
- Pass `--external` through. A skipped external CLI does not drop an internal flavor.
- Phase 4 is skipped in diff-mode. Do not run prosecution or defense from this command.
- Spawn failure: the orchestrator self-verifies the missing lens and sets
  `degraded=true`. The marker is `self-verified — refuters unavailable`.
  The actor is the orchestrator. Protocol: `skills/council/SKILL.md`
  § Spawn-failure degradation.

## Step 5: Finalize

```bash
PDH="${PDH:-<PDH>}"   # session root carried from the stanza fence above — re-run that fence first when not held
ENGINE_SH=$(bash "$PDH/skills/plugin-dir.sh" file skills/council/engine.sh)
# Replace <PLAN_FILE> with the plan path that the Step 3 fence printed (PLAN_FILE=<path>).
PLAN_FILE="<PLAN_FILE>"
[ -f "$PLAN_FILE" ] || { echo "review-and-commit error: set PLAN_FILE to the plan path from Step 3" >&2; exit 1; }
# Replace <DEGRADED> with true when any spawn failed and you self-verified the lens, else false.
DEGRADED="<DEGRADED>"
case "$DEGRADED" in
  true)  FINALIZE_MODE=(--verification-mode self-verified) ;;
  false) FINALIZE_MODE=() ;;
  *) echo "review-and-commit error: set DEGRADED to true or false" >&2; exit 1 ;;
esac
EVIDENCE_FILE=$(mktemp "${TMPDIR:-/tmp}/rc-evidence.XXXXXX.json") \
  || { echo "review-and-commit error: mktemp failed for EVIDENCE_FILE"; exit 1; }
JUDGE_FILE=$(mktemp "${TMPDIR:-/tmp}/rc-judge.XXXXXX.json") \
  || { echo "review-and-commit error: mktemp failed for JUDGE_FILE"; exit 1; }
# populate from Phase 1 / Phase 5 outputs, then:
"$ENGINE_SH" finalize --plan-file "$PLAN_FILE" \
  --evidence-file "$EVIDENCE_FILE" --judge-output "$JUDGE_FILE" \
  ${FINALIZE_MODE[@]+"${FINALIZE_MODE[@]}"}
```

This fence runs in a new shell. It does not see variables from the Step 3 fence, so you
fill in `<PLAN_FILE>` and `<DEGRADED>` yourself. The fence exits 1 until both are filled
(`DEGRADED` must be exactly `true` or `false`), so a skipped edit never reads as a
non-degraded run. With `DEGRADED=true` the engine gets `--verification-mode self-verified`
and the canonical report includes marker `self-verified — refuters unavailable`.
See `skills/council/SKILL.md` § Spawn-failure degradation.

Engine renders the canonical report via
`skills/council/templates/report-finding.md` to
`$MROOT/.claude/council/<YYYY-MM-DD>-diff-staged.md`.

## Step 6: Output the Review

Render the judge's finding[] with `skills/review-and-commit/bucket.sh`.
Print the sections from `skills/council/templates/legacy-review.md`.
That file is the only copy of the headings. Do not paste them here.

Run `skills/review-and-commit/stats-line.sh` for the `Review stats:` line.
`bucket.sh` is the section assigner: a logic warning stays in Critical Issues;
`design` and legacy `quality` share Design Problems; anything else that is
not a known bucket lands in Other.

If spec-grep detected drift, add `## Spec Alignment` listing affected specs.
If a path argument was given, also write this rendered review there.
The engine still writes the canonical report under `.claude/council/`.

## Step 7: Commit Gate

Commit mechanics only — Steps 1-6 (review logic, specialists, confidence
filtering) are unaffected. Cites `skills/refactor/SKILL.md` § 2.2a
Escalation gate; per SPEC-031 D1 contract-home doctrine, that logic is not
restated here.

### 7.1 Findings block

- Any **Critical Issues** or **Compliance Violations** → do NOT commit; tell
  the user exactly what must be fixed. (Matches diff-mode preset
  `commit_gate_blocks_on: [critical, compliance]`.) Halt here — do not
  continue to 7.2-7.4.

### 7.2 Worktree check [CHECK ONLY — NEVER CREATE]

Same destination requirement as `skills/refactor/SKILL.md` § 2.2a.4 — all
commits happen inside `$MROOT/.worktrees/<slug>`, there is no current-branch
direct-commit path — but the *mechanism* differs and does not transfer.
§ 2.2a.4 creates a worktree **before** any editing, so a fresh checkout is
correct there. This command runs **after** editing: Step 1 read the diff of
whatever is checked out right now, and Steps 2-6 reviewed *that* diff.
`worktree-lib.sh ensure` produces a clean checkout at the branch point, which
would not contain the reviewed changes at all. So this step never creates a
worktree — it only checks where the reviewed diff already lives:

- **cwd is already inside `$MROOT/.worktrees/`** → check passes. The reviewed
  diff already lives under worktree isolation and nothing needs migrating.
  Continue to 7.3.
- **cwd is not inside `$MROOT/.worktrees/`** → **HALT**. Do not create a
  worktree, do not commit, do not continue to 7.3-7.4. Report that the
  reviewed changes were made outside worktree isolation and give the user
  this recovery path, then stop and let them run it:

  1. `git stash push -u` here, to save the reviewed changes.
  2. Create or reuse the worktree via `worktree-lib.sh ensure <slug>` in the
     SPEC-016 caller-integration form — run the wiring block in
     `skills/refactor/SKILL.md` § 2.4 § Worktree wiring as-is (the single
     operational copy of the `plugin-dir.sh` resolution, slug sanitization,
     and `ensure` exit-code handling; not restated here). That block derives
     `$SLUG` from `$DESC`, which this command does not have; supply `$DESC`
     here as the ticket ID when the reviewed change has one, else the current
     branch name, else a 3-5 word description of the reviewed change. The
     block's own sanitization then applies unchanged.
  3. `git stash pop` inside that worktree, to restore the changes there.
  4. Re-run `/review-and-commit` from inside the worktree.

  The re-run reviews the same diff in its isolated home and reaches 7.2 with
  the check passing.

### 7.3 Ticket-weight routing

Test the reviewed diff against the same `WHY INLINE REJECTED` reasons used
by `skills/refactor/SKILL.md` § 2.2a.1 — do not invent new reasons. Any one
reason applies → do not commit here; emit the 4-field handoff verbatim
(see `## Escalation handoff format` in `skills/refactor/SKILL.md`) and
route to `/kickoff` with a real ticket. No reason applies → bounded,
continue to 7.4.

### 7.4 Commit confirm [ALWAYS ASK]

Ask the user before ANY commit, then stop and wait:

> Commit gate — routing: `<bounded | /kickoff>`. Findings: `<N critical, M
> design, K nitpick>`. May I commit?

The always-ask discipline is `skills/refactor/SKILL.md` § 2.2a.3's — asked on
every run with no auto-satisfied branch, no earlier-run/earlier-ticket/upstream
go-ahead satisfies it, and anything other than an affirmative halts the run
(SPEC-031 owns these rules per D1 contract-home; not restated here).
`/orchestrate` and `/wrap-ticket` do not call this command. An edit grant from
another workflow does not cover this commit. Always ask here.

- On affirmative and bounded routing → stage exactly the reviewed path list
  from Step 1, then `git commit` with a conventional message explaining *why*
  the change was made. Run `skills/review-and-commit/stage-reviewed.sh --list`
  on that list. If the worktree has a dirty or untracked path outside the
  list, the script exits 1 and stages nothing — stop and do not commit.

No escalation-gate disarm runs here: under SPEC-031's arm-on-escalate model the
worktree this command operates in is never armed (bounded runs don't arm;
escalate runs release their worktree and hand off before review-and-commit would
run), so there is no marker to disarm.

## Step 8: Action Items

Always print — even if the commit proceeds. Summary line first:

```
Action Items: N BLOCKERs, M DESIGN, K NITPICK — [commit blocked | commit proceeded]
```

Then the checklist:

```
## Action Items
- [ ] BLOCKER `file:line` — what is wrong — exactly what to do [confidence: N]
- [ ] COMPLIANCE `file:line` — rule violated — exactly what to do [confidence: N]
- [ ] DESIGN  `file:line` — what is wrong — exactly what to do [confidence: N]
- [ ] NITPICK `file:line` — what is wrong — exactly what to do [confidence: N]
```

Rules: every review item appears here; one line each; no vague items
("refactor this" is not acceptable — "delete QueueInterface, use
ConcreteQueue directly" is); ordered BLOCKER → COMPLIANCE → DESIGN → NITPICK.

## Step 9: Verify

`git status` to confirm clean state (if the commit proceeded).

## Notes

- This command is `/council --diff --tier full`. Step 3 passes `--tier full`.
  `/council --diff` may still be graded. The full-tier flavor set loads from
  `skills/council/flavors/{logic,security,compliance,quality,simplification}.md`.
- **Phase 7 is DEFERRED** (CDT-325). The engine does not run it and does not
  write lessons.md. `feedback_memory_enabled: false` is reserved and has no
  effect until Phase 7 is implemented. A code bug is not a claim fabrication.
  See SPEC-013 § Council tiering, SPEC-010 § Code Review (review-and-commit).
- Engine always writes the canonical report to
  `$MROOT/.claude/council/<date>-diff-staged.md`. An optional path argument
  writes an ADDITIONAL copy rendered from `skills/council/templates/legacy-review.md`.
