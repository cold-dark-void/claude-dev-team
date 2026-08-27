---
name: kickoff
description: |
    Orchestrate the full ticket intake and planning phase — parallel PM+Tech Lead
    kickoff, spec creation, implementation plan, and TaskCreate task graph. Replaces
    7 manual prompts with one command. Usage: /kickoff <TICKET-ID> "<ticket text>"
    or /kickoff alone to be prompted.
---

# Kickoff

Collapse Phase 1 (intake) and Phase 2 (planning) of the Linear-to-prod workflow into a
single orchestrated command. Fires PM and Tech Lead in parallel, produces a spec, plan,
and task graph ready for IC agents to claim.

## Arguments

- `/kickoff <TICKET-ID> "<ticket text>"` — ticket ID and full ticket text inline
- `/kickoff <TICKET-ID>` — prompts for ticket text
- `/kickoff` — prompts for both
- `[--autopilot[=<token>]]` — optional, any position: enable autopilot for this run
  (CDT-111-C4 / SPEC-033). Bare `--autopilot` or `AUTOPILOT=1` env = enabled, bump `null`;
  `--autopilot=<patch|minor|major>` = release ship intent; `--autopilot=master` =
  **land-no-release** (token spelling only — land target is worktree baseline / origin
  default, not necessarily a branch named `master`). Flag wins over env. See
  `skills/autopilot/parse-flags.sh` + Step 0 "Autopilot detection".

---

## Accepted escalation handoff (input contract)

When `/kickoff` is reached as an escalation target from `/debug` (scope =
escalate-to-kickoff, or arch mode) or `/refactor` (scope exceeds inline work),
the `<ticket text>` argument is the producer's structured handoff. This is the ONE
canonical contract both producers emit and `/kickoff` consumes — per SPEC-014 §
Escalation and SPEC-015 § Escalation, which each MUST a 4-field structured handoff.

The handoff MUST contain exactly these four fields:

```
ROOT CAUSE: <root-cause statement (/debug) or design-problem statement (/refactor)>
AFFECTED FILES:
  - <file or module>
PROPOSED APPROACH: <2-3 sentences describing the intended fix or structural change>
WHY INLINE REJECTED: <one of the canonical reasons below>
```

**Canonical `WHY INLINE REJECTED` vocabulary** (shared by `/debug` and `/refactor`;
producers MUST emit one of these verbatim, consumers validate against this set):

- `cross-subsystem or multi-directory refactor required`
- `architectural decision required`
- `tech-lead design review required`
- `arch mode — design decision required` (`/debug` arch mode only)
- `callsite count exceeded threshold`

On intake, `/kickoff` treats this 4-field text as the ticket body: ROOT CAUSE and
PROPOSED APPROACH seed the ticket summary, AFFECTED FILES seed the Tech Lead's
affected-files assessment (Step 2), and WHY INLINE REJECTED records why the work
could not be resolved inline. If a field is missing or WHY INLINE REJECTED is not
one of the canonical values, treat the handoff as a malformed ticket and ask the
producer (or user) to re-emit it before planning.

---

## Step 0: Resolve project root and parse args

```bash
_gc=$(git rev-parse --git-common-dir 2>/dev/null) \
  && MROOT=$(cd "$(dirname "$_gc")" && pwd) \
  || MROOT=$(pwd)
```

If TICKET-ID or ticket text are missing, ask:
> "Ticket ID (e.g. POC-123):"
> "Paste the full ticket text (title, description, acceptance criteria):"

### Autopilot detection (CDT-111-C4)

Resolve autopilot enablement once, at run start — every gated checkpoint below
(Step 3, Step 4b, Error Handling) reuses these values by reference. `/kickoff` has
no stint loop, so `ITER` stays `0` for the whole run.

```bash
# Locate the dev-team plugin root (PDH). Optional CLAUDE_PLUGIN_ROOT (force path / FR #48230), else cwd dev/worktree, else marketplace clone (slug-free agents/pm.md), else installed cache (rank by /dev-team/<VER>/ segment, not full path; CDT-166). CDT-82: marketplace before same-version cache.
# lint-ok: C3 — marketplace */ for-loop + -f guarded (SPEC-021 Q2 residual, CDT-82 PDH)
PDH=$( { [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -f "$CLAUDE_PLUGIN_ROOT/skills/plugin-dir.sh" ] && printf '%s\n' "$CLAUDE_PLUGIN_ROOT"; } || { [ -f skills/plugin-dir.sh ] && pwd; } || { for _mp in "$HOME"/.claude/plugins/marketplaces/*/; do [ -f "${_mp}skills/plugin-dir.sh" ] && [ -f "${_mp}agents/pm.md" ] && printf '%s\n' "${_mp%/}" && break; done; } || find ~/.claude/plugins/cache -path '*/dev-team/*/skills/plugin-dir.sh' 2>/dev/null | awk -F/ '{ver=""; for(i=1;i<=NF;i++) if($i=="dev-team"&&i<NF){ver=$(i+1);break}; if(ver=="") next; m=ver; gsub(/-pre\./,"~pre.",m); p=($0 ~ /\/cache\/cold-dark-void\/dev-team\//)?1:0; print m "\t" p "\t" $0}' | sort -t $'\t' -k1,1V -k2,2n -k3,3 | tail -1 | cut -f3 | xargs -r dirname | xargs -r dirname )
AP=$(bash "$PDH/skills/plugin-dir.sh" file skills/autopilot/parse-flags.sh)
AP_JSON=$(bash "$AP" "$@") || { echo "$AP_JSON" >&2; exit 64; }   # 64 = malformed --autopilot=<bump>
AUTOPILOT_ON=$(jq -r .enabled <<<"$AP_JSON")
AUTOPILOT_BUMP=$(jq -r '.bump // "null"' <<<"$AP_JSON")
# CDT-223: bind .max_loc from the same parse-flags.sh call (no env, not resume-seeded).
# Omit records MAX_LOC as the literal string "null".
MAX_LOC=$(jq -r '.max_loc // "null"' <<<"$AP_JSON")
RUN_START_EPOCH=$(date +%s)
RUN_ID="kickoff-<TICKET-ID>-$RUN_START_EPOCH"    # S3-derivable per C3 §2
ITER=0                                              # ++ once per stint
```

Every later reference to `AUTOPILOT_ON` / `AUTOPILOT_BUMP` / `RUN_ID` /
`RUN_START_EPOCH` / `ITER` / `MAX_LOC` below means these values, carried forward from this step.

**N13 isolation (CDT-224):** `/kickoff` envelopes omit `tasks` / `projected_loc` / `waves`; engine argc=2; no budget-cap flag.

---

## Step 1: Load context

Read the following in parallel before doing anything else:

```bash
_gc=$(git rev-parse --git-common-dir 2>/dev/null) \
  && MROOT=$(cd "$(dirname "$_gc")" && pwd) \
  || MROOT=$(pwd)
MEMDB="$MROOT/.claude/memory/memory.db"
```

- Claude memory:
  ```bash
WTROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
MEMDB="$MROOT/.claude/memory/memory.db"
_gc=$(git rev-parse --git-common-dir 2>/dev/null) \
  && MROOT=$(cd "$(dirname "$_gc")" && pwd) \
  || MROOT=$(pwd)
  if [ -f "$MEMDB" ] && command -v sqlite3 &>/dev/null; then
    HAS_DISTILLED=$(sqlite3 "$MEMDB" "SELECT COUNT(*) FROM memories WHERE agent='claude' AND tier > 0 AND archived=FALSE;")
    if [ "$HAS_DISTILLED" -gt 0 ]; then
      sqlite3 "$MEMDB" "SELECT content FROM memories WHERE agent='claude' AND tier=2 AND archived=FALSE ORDER BY type, updated_at DESC;"
      sqlite3 "$MEMDB" "SELECT content FROM memories WHERE agent='claude' AND tier=1 AND archived=FALSE ORDER BY type, updated_at DESC;"
    else
      sqlite3 "$MEMDB" "SELECT content FROM memories WHERE agent='claude' AND tier=0 AND archived=FALSE ORDER BY type, created_at DESC;"
    fi
  else
    cat "$MROOT/.claude/memory/claude/memory.md" 2>/dev/null
  fi
  ```
- Tech Lead cortex:
  ```bash
WTROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
MEMDB="$MROOT/.claude/memory/memory.db"
_gc=$(git rev-parse --git-common-dir 2>/dev/null) \
  && MROOT=$(cd "$(dirname "$_gc")" && pwd) \
  || MROOT=$(pwd)
  if [ -f "$MEMDB" ] && command -v sqlite3 &>/dev/null; then
    HAS_DISTILLED=$(sqlite3 "$MEMDB" "SELECT COUNT(*) FROM memories WHERE agent='tech-lead' AND tier > 0 AND archived=FALSE;")
    if [ "$HAS_DISTILLED" -gt 0 ]; then
      sqlite3 "$MEMDB" "SELECT content FROM memories WHERE agent='tech-lead' AND tier=2 AND archived=FALSE ORDER BY type, updated_at DESC;"
      sqlite3 "$MEMDB" "SELECT content FROM memories WHERE agent='tech-lead' AND tier=1 AND archived=FALSE ORDER BY type, updated_at DESC;"
    else
      sqlite3 "$MEMDB" "SELECT content FROM memories WHERE agent='tech-lead' AND tier=0 AND archived=FALSE ORDER BY type, created_at DESC;"
    fi
  else
    cat "$MROOT/.claude/memory/tech-lead/cortex.md" 2>/dev/null
  fi
  ```
- PM cortex:
  ```bash
WTROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
MEMDB="$MROOT/.claude/memory/memory.db"
_gc=$(git rev-parse --git-common-dir 2>/dev/null) \
  && MROOT=$(cd "$(dirname "$_gc")" && pwd) \
  || MROOT=$(pwd)
  if [ -f "$MEMDB" ] && command -v sqlite3 &>/dev/null; then
    HAS_DISTILLED=$(sqlite3 "$MEMDB" "SELECT COUNT(*) FROM memories WHERE agent='pm' AND tier > 0 AND archived=FALSE;")
    if [ "$HAS_DISTILLED" -gt 0 ]; then
      sqlite3 "$MEMDB" "SELECT content FROM memories WHERE agent='pm' AND tier=2 AND archived=FALSE ORDER BY type, updated_at DESC;"
      sqlite3 "$MEMDB" "SELECT content FROM memories WHERE agent='pm' AND tier=1 AND archived=FALSE ORDER BY type, updated_at DESC;"
    else
      sqlite3 "$MEMDB" "SELECT content FROM memories WHERE agent='pm' AND tier=0 AND archived=FALSE ORDER BY type, created_at DESC;"
    fi
  else
    cat "$MROOT/.claude/memory/pm/cortex.md" 2>/dev/null
  fi
  ```
- `$MROOT/AGENTS.md` (project rules)
- Domain glossary (`skills/domain-glossary/SKILL.md` load protocol):
  ```bash
_gc=$(git rev-parse --git-common-dir 2>/dev/null) \
  && MROOT=$(cd "$(dirname "$_gc")" && pwd) \
  || MROOT=$(pwd)
if [ -f "$MROOT/CONTEXT.md" ]; then
  cat "$MROOT/CONTEXT.md"
elif [ -f "$MROOT/docs/domain/CONTEXT.md" ]; then
  cat "$MROOT/docs/domain/CONTEXT.md"
else
  echo "No domain glossary (CONTEXT.md) yet."
fi
  ```
  Prefer glossary **Term** names in ACs, specs, plans, and task subjects. If the
  ticket uses an **Avoid** alias, map it to the canonical Term and note once.

Scan `specs/` for specs likely related to the ticket (SPEC-008 `### Spec Discovery`):
```bash
_gc=$(git rev-parse --git-common-dir 2>/dev/null) \
  && MROOT=$(cd "$(dirname "$_gc")" && pwd) \
  || MROOT=$(pwd)
ls $MROOT/specs/core/ 2>/dev/null || ls $MROOT/specs/ 2>/dev/null
```

Read any spec whose filename or title matches keywords from the ticket text.
Note which specs are relevant — they constrain the design.

---

## Step 1b: Create branch and worktree

A git worktree is an additional working tree linked to the same repository — it lets
all spec/plan/CONTEXT.md work land on the ticket branch in isolation, never on the
invoking session's branch. This step is **mandatory**: without it, standalone
`/kickoff <TICKET-ID>` commits the spec straight to whatever branch the session is on
(the master-commit defect CDT-105 closes). Mirrors `/orchestrate` Step 3 exactly.

**CDT-141-C3:** epic children under `--worktree` share the epic integration tree —
use `ensure-ticket-worktree` (skips per-child ensure when shared). Default path
unchanged.

```bash
# Locate the dev-team plugin root (PDH). Optional CLAUDE_PLUGIN_ROOT (force path / FR #48230), else cwd dev/worktree, else marketplace clone (slug-free agents/pm.md), else installed cache (rank by /dev-team/<VER>/ segment, not full path; CDT-166). CDT-82: marketplace before same-version cache.
# lint-ok: C3 — marketplace */ for-loop + -f guarded (SPEC-021 Q2 residual, CDT-82 PDH)
PDH=$( { [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -f "$CLAUDE_PLUGIN_ROOT/skills/plugin-dir.sh" ] && printf '%s\n' "$CLAUDE_PLUGIN_ROOT"; } || { [ -f skills/plugin-dir.sh ] && pwd; } || { for _mp in "$HOME"/.claude/plugins/marketplaces/*/; do [ -f "${_mp}skills/plugin-dir.sh" ] && [ -f "${_mp}agents/pm.md" ] && printf '%s\n' "${_mp%/}" && break; done; } || find ~/.claude/plugins/cache -path '*/dev-team/*/skills/plugin-dir.sh' 2>/dev/null | awk -F/ '{ver=""; for(i=1;i<=NF;i++) if($i=="dev-team"&&i<NF){ver=$(i+1);break}; if(ver=="") next; m=ver; gsub(/-pre\./,"~pre.",m); p=($0 ~ /\/cache\/cold-dark-void\/dev-team\//)?1:0; print m "\t" p "\t" $0}' | sort -t $'\t' -k1,1V -k2,2n -k3,3 | tail -1 | cut -f3 | xargs -r dirname | xargs -r dirname )
SLUG="<TICKET-ID>"  # bare ticket ID exactly (e.g. "CDV-42" or "CDT-141-C3")
EPIC_LIB=$(bash "$PDH/skills/plugin-dir.sh" file skills/epic/epic-lib.sh)
# Shared epic integration when applicable; else worktree-lib ensure <SLUG>.
WT_PATH=$(bash "$EPIC_LIB" ensure-ticket-worktree "$SLUG") || {
  EXIT=$?
  if [ "$EXIT" -eq 2 ]; then
    echo "Worktree setup aborted by user." >&2
  elif [ "$EXIT" -eq 64 ]; then
    echo "ensure-ticket-worktree / worktree-lib usage error, check slug" >&2
  fi
  exit "$EXIT"
}
CHILD_WT=$(bash "$EPIC_LIB" resolve-child-worktree "$SLUG")
USE_SHARED=$(jq -r '.use_shared // false' <<<"$CHILD_WT")
```

When `USE_SHARED=true`: path is `.worktrees/epic-<EPIC-ID>` / branch
`feat/epic-<EPIC-ID>` — **no** per-child tree. When false: `feat/<TICKET-ID>` as
before. Use `$WT_PATH` everywhere downstream that WRITES the spec, plan, or CONTEXT.md.

- **Exit 0**: proceed — `$WT_PATH` holds the worktree path.
- **Exit 1** (unexpected error): git/filesystem failure; stderr has details; HALT.
- **Exit 2** (user aborted / no TTY): halt cleanly, no error framing.
- **Exit 64** (usage error): halt; report usage error.

Do **NOT** silently proceed on any non-zero exit — a single downstream path left
pointing at `$MROOT` reintroduces the master-commit defect with no visible error.

Each later `bash` fence is a fresh shell (SPEC-021 C1), so `$WT_PATH` does not survive
across fences. Re-derive via `ensure-ticket-worktree` (handles shared vs per-child):

```bash
# lint-ok: C3 — marketplace */ for-loop + -f guarded (SPEC-021 Q2 residual, CDT-82 PDH)
PDH=$( { [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -f "$CLAUDE_PLUGIN_ROOT/skills/plugin-dir.sh" ] && printf '%s\n' "$CLAUDE_PLUGIN_ROOT"; } || { [ -f skills/plugin-dir.sh ] && pwd; } || { for _mp in "$HOME"/.claude/plugins/marketplaces/*/; do [ -f "${_mp}skills/plugin-dir.sh" ] && [ -f "${_mp}agents/pm.md" ] && printf '%s\n' "${_mp%/}" && break; done; } || find ~/.claude/plugins/cache -path '*/dev-team/*/skills/plugin-dir.sh' 2>/dev/null | awk -F/ '{ver=""; for(i=1;i<=NF;i++) if($i=="dev-team"&&i<NF){ver=$(i+1);break}; if(ver=="") next; m=ver; gsub(/-pre\./,"~pre.",m); p=($0 ~ /\/cache\/cold-dark-void\/dev-team\//)?1:0; print m "\t" p "\t" $0}' | sort -t $'\t' -k1,1V -k2,2n -k3,3 | tail -1 | cut -f3 | xargs -r dirname | xargs -r dirname )
EPIC_LIB=$(bash "$PDH/skills/plugin-dir.sh" file skills/epic/epic-lib.sh)
WT_PATH=$(bash "$EPIC_LIB" ensure-ticket-worktree "<TICKET-ID>")
```

Do **not** hardcode `.worktrees/<TICKET-ID>` when the ticket may be an epic shared child (that path will not exist — use ensure-ticket-worktree).

---

## Step 2: Parallel PM + Tech Lead + Codebase Exploration

Spawn **three** agents simultaneously. Do not wait for one before starting the others.

### PM prompt (send now):

Before spawning @pm:
```bash
# lint-ok: C3 — marketplace */ for-loop + -f guarded (SPEC-021 Q2 residual, CDT-82 PDH)
PDH=$( { [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -f "$CLAUDE_PLUGIN_ROOT/skills/plugin-dir.sh" ] && printf '%s\n' "$CLAUDE_PLUGIN_ROOT"; } || { [ -f skills/plugin-dir.sh ] && pwd; } || { for _mp in "$HOME"/.claude/plugins/marketplaces/*/; do [ -f "${_mp}skills/plugin-dir.sh" ] && [ -f "${_mp}agents/pm.md" ] && printf '%s\n' "${_mp%/}" && break; done; } || find ~/.claude/plugins/cache -path '*/dev-team/*/skills/plugin-dir.sh' 2>/dev/null | awk -F/ '{ver=""; for(i=1;i<=NF;i++) if($i=="dev-team"&&i<NF){ver=$(i+1);break}; if(ver=="") next; m=ver; gsub(/-pre\./,"~pre.",m); p=($0 ~ /\/cache\/cold-dark-void\/dev-team\//)?1:0; print m "\t" p "\t" $0}' | sort -t $'\t' -k1,1V -k2,2n -k3,3 | tail -1 | cut -f3 | xargs -r dirname | xargs -r dirname )
RESOLVE=$(bash "$PDH/skills/plugin-dir.sh" file skills/model-map/resolve-model.sh)
MODEL=$(bash "$RESOLVE" pm)
printf '%s\n' "$MODEL"
EFFORT=$(bash "$RESOLVE" --effort pm)
printf '%s\n' "$EFFORT"
```
Bash stdout = model string; empty → omit model.
Then `resolve-model.sh --effort` (same agent). Non-empty EFFORT → pass as Agent `effort` param; empty → omit (MUST NOT pass `""`).
Surface resolver stderr to the user. Do not swallow.
If MODEL is non-empty: pass it as the Agent model param.
If MODEL is empty: omit model. MUST NOT pass "".
If spawn fails attributed to the model param (invalid/unknown/unsupported model): retry once with model omitted; warn `model-map: host rejected model '<string>' for pm; retrying with Tier default`.
If spawn fails attributed to the `effort` param (invalid/unknown/unsupported effort): retry once omitting effort; warn `model-map: host rejected effort '<token>' for pm; retrying with inherited effort`.
Model host-reject stays independent. Ambiguous failure: do not guess; do not combinatorial-retry both params.
Other spawn failures MUST NOT be retried as a model or effort fallback.

```
You are @pm. Review ticket <TICKET-ID>:

Output mode: terse

<TICKET TEXT>

Your job:
1. Confirm or rewrite each acceptance criterion — make them unambiguous and testable
2. Flag any scope questions that must be resolved before implementation starts
3. Add any missing ACs that the ticket implies but doesn't state
4. Prefer project domain-glossary terms (CONTEXT.md) when naming concepts in ACs
5. Output: revised AC list + list of open questions (if any)

Do NOT start planning implementation. Scope only.
Return your output as this agent's final message — do NOT SendMessage to the
orchestrator; there is no addressable parent.
```

### Tech Lead prompt (send now, in parallel):

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
You are @tech-lead. Orient on ticket <TICKET-ID> while @pm reviews scope.

Output mode: terse

Ticket summary: <first 2 sentences of ticket text>

Your job right now (before ACs are confirmed):
1. Read your cortex.md for architecture context
2. Identify which files/packages this ticket will likely touch
3. Identify any existing specs that constrain the design
4. Note any technical risks or unknowns
5. List any external API parameters, library/SDK flags, model capabilities, or
   endpoint behaviors this ticket would ASSUME work — these feed the verification
   gate before the spec is written. If none, say "no external assumptions".

Do NOT produce a plan yet — wait for confirmed ACs.
Output: affected files, relevant specs, risks, assumed external behaviors.
Return your output as this agent's final message — do NOT SendMessage to the
orchestrator; there is no addressable parent.
```

### Codebase Explorer prompt (send now, in parallel — Sonnet):
```
You are a codebase exploration agent. Deep-dive the codebase to map how
the area related to ticket <TICKET-ID> currently works.

Output mode: terse

Ticket summary: <first 2 sentences of ticket text>
Keywords: <extract 3-5 keywords from ticket text>

Your methodology:
1. DISCOVERY — Grep/Glob for the keywords across the codebase. Find all
   relevant files, types, functions, routes, handlers.
2. FLOW ANALYSIS — For the top 3-5 most relevant entry points, trace the
   execution path: caller → function → dependencies → side effects.
   Read each file fully, do not skim.
3. ARCHITECTURE MAPPING — Identify patterns: what abstractions exist,
   what conventions are followed, what data flows through the system.
4. DEPENDENCY MAP — What does this area depend on? What depends on it?

Output a structured report:
- Entry points: <list with file:line>
- Execution flows: <caller → callee chains>
- Patterns in use: <conventions, abstractions, data flow>
- Dependencies (inbound): <what calls into this area>
- Dependencies (outbound): <what this area calls>
- Landmines: <anything surprising, fragile, or undocumented>
```

Collect all three outputs before proceeding.

Present the codebase exploration findings to the user alongside PM and Tech Lead
outputs — this gives everyone a shared understanding of how the code works today
before any design decisions are made.

---

## Step 3: Resolve open questions

**Autopilot:** if PM has open questions and `AUTOPILOT_ON` (Step 0), skip the
interactive prompt below. Build the C3 §2 envelope
`{ workflow:"kickoff", ticket_id:<TICKET-ID>, gate:"scope-confirm", run_id:RUN_ID,
iteration:ITER, run_start_epoch:RUN_START_EPOCH, autopilot_bump:AUTOPILOT_BUMP,
max_loc:MAX_LOC, <PM's open questions as the issue-text-sufficiency signal> }` and call
`skills/autopilot/self-answer.md`'s procedure (expected: BC1 → `halt`). On `halt`,
emit `task_blocked` (detail = the one-line message) via **Passive notifications →
Tier B** (fail-open; § below), then print the FINAL-#4 one-line message and return
control:
```
scope-confirm halt: <rationale> — card: <card-file-path>
```
Otherwise (autopilot off), continue below unchanged.

Present PM's open questions to the user:

```
@pm found N open questions before ACs can be confirmed:

1. <question>
2. <question>

Please answer each one so we can lock scope.
```

If PM had no open questions, skip to Step 4.

Collect answers. Feed them back to PM (new @pm spawn — resolve model first):

Before spawning @pm:
```bash
# lint-ok: C3 — marketplace */ for-loop + -f guarded (SPEC-021 Q2 residual, CDT-82 PDH)
PDH=$( { [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -f "$CLAUDE_PLUGIN_ROOT/skills/plugin-dir.sh" ] && printf '%s\n' "$CLAUDE_PLUGIN_ROOT"; } || { [ -f skills/plugin-dir.sh ] && pwd; } || { for _mp in "$HOME"/.claude/plugins/marketplaces/*/; do [ -f "${_mp}skills/plugin-dir.sh" ] && [ -f "${_mp}agents/pm.md" ] && printf '%s\n' "${_mp%/}" && break; done; } || find ~/.claude/plugins/cache -path '*/dev-team/*/skills/plugin-dir.sh' 2>/dev/null | awk -F/ '{ver=""; for(i=1;i<=NF;i++) if($i=="dev-team"&&i<NF){ver=$(i+1);break}; if(ver=="") next; m=ver; gsub(/-pre\./,"~pre.",m); p=($0 ~ /\/cache\/cold-dark-void\/dev-team\//)?1:0; print m "\t" p "\t" $0}' | sort -t $'\t' -k1,1V -k2,2n -k3,3 | tail -1 | cut -f3 | xargs -r dirname | xargs -r dirname )
RESOLVE=$(bash "$PDH/skills/plugin-dir.sh" file skills/model-map/resolve-model.sh)
MODEL=$(bash "$RESOLVE" pm)
printf '%s\n' "$MODEL"
EFFORT=$(bash "$RESOLVE" --effort pm)
printf '%s\n' "$EFFORT"
```
Bash stdout = model string; empty → omit model.
Then `resolve-model.sh --effort` (same agent). Non-empty EFFORT → pass as Agent `effort` param; empty → omit (MUST NOT pass `""`).
Surface resolver stderr to the user. Do not swallow.
If MODEL is non-empty: pass it as the Agent model param.
If MODEL is empty: omit model. MUST NOT pass "".
If spawn fails attributed to the model param (invalid/unknown/unsupported model): retry once with model omitted; warn `model-map: host rejected model '<string>' for pm; retrying with Tier default`.
If spawn fails attributed to the `effort` param (invalid/unknown/unsupported effort): retry once omitting effort; warn `model-map: host rejected effort '<token>' for pm; retrying with inherited effort`.
Model host-reject stays independent. Ambiguous failure: do not guess; do not combinatorial-retry both params.
Other spawn failures MUST NOT be retried as a model or effort fallback.

```
@pm — user answers to your open questions:
<answers>

Produce the final confirmed AC list now.
```

---

## Step 4: Check for spec gap

Using Tech Lead's list of affected areas and PM's confirmed ACs, determine:

**Does a spec already exist for this feature area?**
- Yes → read it, check if any confirmed ACs contradict or extend it
- No → a new spec must be written before implementation

Print:
```
Spec status:
- <spec-name>.md — EXISTS, covers <area> [needs update / no changes needed]
- <feature area> — NO SPEC — will create SPEC-NNN
```

---

## Step 4b: Verify external API/behavior assumptions (conditional gate)

Before any spec or plan is written, check whether the ticket depends on an
**external API parameter, library/SDK flag, model capability, endpoint behavior,
or config flag** whose behavior is not already proven in this codebase. Use the
Tech Lead's "assumed external behaviors" (Step 2) plus the confirmed ACs.

**If there are none** (pure UI, internal refactor, docs, etc.), print one line and
continue to Step 5:
```
GATE 1 (API verification): no external assumptions to verify — skipped.
```

**If there are**, spawn a verification agent NOW — before the spec locks in the design:
```
You are a verification agent. Do NOT write production code or a spec.

Output mode: terse

For each assumed external behavior below, empirically determine whether it is real
and honored, in this order of preference:
1. Grep this codebase for existing, proven usage.
2. Run the smallest possible probe and observe the actual result.
3. Cite official docs for the exact parameter/flag and version.

Assumptions to verify:
<one per line, from Tech Lead's list + confirmed ACs>

Output a table — Assumption | Verdict (HONORED / IGNORED / DECORATIVE / UNKNOWN) |
Evidence (command output, file:line, or doc URL). Never guess: UNKNOWN is the
required answer when you cannot prove it. Do not SendMessage the orchestrator;
return the table as your final message.
```

**Autopilot:** if `AUTOPILOT_ON` (Step 0) and any assumption a confirmed AC depends
on returns `IGNORED`, `DECORATIVE`, or `UNKNOWN`, skip the interactive pause below.
Build the C3 §2 envelope
`{ workflow:"kickoff", ticket_id:<TICKET-ID>, gate:"scope-confirm", run_id:RUN_ID,
iteration:ITER, run_start_epoch:RUN_START_EPOCH, autopilot_bump:AUTOPILOT_BUMP,
max_loc:MAX_LOC, <the verification table as the signal> }` and call
`skills/autopilot/self-answer.md`'s procedure (expected: BC8 → `halt`). On `halt`,
emit `task_blocked` (detail = the one-line message) via **Passive notifications →
Tier B** (fail-open; § below), then print the FINAL-#4 one-line message and return
control:
```
scope-confirm halt: <rationale> — card: <card-file-path>
```
Otherwise (autopilot off, or every assumption `HONORED`), continue below unchanged.

Present the table to the user, then gate:
- Every assumption a **confirmed AC depends on** that returns `IGNORED`, `DECORATIVE`,
  or `UNKNOWN` → **pause**. Surface it and ask the user whether to (a) drop/rework
  that AC, or (b) proceed with it explicitly marked unverified. Do NOT silently
  design around an unproven capability.
- `HONORED` assumptions → proceed.

Carry the verified table into Step 5: the spec MUST record what is proven vs. what
is decorative/no-op, so the design never quietly relies on an unverified behavior.

---

## Step 5: Write or update spec (spec-first)

**Spawned-agent path contract (MUST).** The Tech Lead agent runs in its own session
and does NOT inherit `$WT_PATH` — for a standalone `/kickoff` its cwd is `$MROOT` or
the invoking worktree, NOT `.worktrees/<TICKET-ID>`. Before sending any prompt below,
the orchestrator MUST substitute the **resolved absolute path** captured in Step 1b for
every `<WT_PATH>` token (e.g. `/home/you/repo/.worktrees/CDV-42`) — or spawn the agent
with cwd set to that path. The agent MUST save to that absolute path, never relative to
its own cwd. If the spec is written to the wrong tree, the `git -C "$WT_PATH" add specs/`
below finds nothing and commits an empty/failed spec while the real file sits elsewhere
— the exact seam CDT-105 closes.

### If spec needs to be created:

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
@tech-lead Write SPEC-NNN for <feature area> based on:
- Confirmed ACs: <list>
- Affected files: <list from Step 2>
- Relevant cross-refs: <existing specs>

Follow the SPEC-008 format contract (required sections, status taxonomy, index columns).
Save to <WT_PATH>/specs/core/SPEC-NNN-<slug>.md — <WT_PATH> is the absolute worktree
path from Step 1b (on feat/<TICKET-ID>); write to it as an absolute path, not relative
to your cwd.
Cross-reference any specs that constrain this one.
```

Determine the next SPEC number (read from the worktree — same content as master at
branch creation, plus any spec already written on this branch in a prior partial run):
```bash
# Re-derive working root + worktree (fresh shell — SPEC-021 C1)
_gc=$(git rev-parse --git-common-dir 2>/dev/null) \
  && MROOT=$(cd "$(dirname "$_gc")" && pwd) \
  || MROOT=$(pwd)
# CDT-141-C3: shared epic path or per-ticket
# lint-ok: C3 — marketplace */ for-loop + -f guarded (SPEC-021 Q2 residual, CDT-82 PDH)
PDH=$( { [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -f "$CLAUDE_PLUGIN_ROOT/skills/plugin-dir.sh" ] && printf '%s\n' "$CLAUDE_PLUGIN_ROOT"; } || { [ -f skills/plugin-dir.sh ] && pwd; } || { for _mp in "$HOME"/.claude/plugins/marketplaces/*/; do [ -f "${_mp}skills/plugin-dir.sh" ] && [ -f "${_mp}agents/pm.md" ] && printf '%s\n' "${_mp%/}" && break; done; } || find ~/.claude/plugins/cache -path '*/dev-team/*/skills/plugin-dir.sh' 2>/dev/null | awk -F/ '{ver=""; for(i=1;i<=NF;i++) if($i=="dev-team"&&i<NF){ver=$(i+1);break}; if(ver=="") next; m=ver; gsub(/-pre\./,"~pre.",m); p=($0 ~ /\/cache\/cold-dark-void\/dev-team\//)?1:0; print m "\t" p "\t" $0}' | sort -t $'\t' -k1,1V -k2,2n -k3,3 | tail -1 | cut -f3 | xargs -r dirname | xargs -r dirname )
EPIC_LIB=$(bash "$PDH/skills/plugin-dir.sh" file skills/epic/epic-lib.sh)
WT_PATH=$(bash "$EPIC_LIB" ensure-ticket-worktree "<TICKET-ID>")
ls "$WT_PATH/specs/core/" | grep -oP 'SPEC-\K\d+' | sort -n | tail -1
# increment by 1
```

### If spec needs updating:

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
@tech-lead Update <spec-file> to reflect the confirmed ACs for <TICKET-ID>.
Add/modify only what this ticket changes. Do not remove existing requirements
unless they are directly contradicted.
```

Wait for Tech Lead to write/update the spec. Then commit it **inside the worktree** so
it lands on `feat/<TICKET-ID>`, never on the invoking branch:

```bash
# Re-derive working root + worktree (fresh shell — SPEC-021 C1)
_gc=$(git rev-parse --git-common-dir 2>/dev/null) \
  && MROOT=$(cd "$(dirname "$_gc")" && pwd) \
  || MROOT=$(pwd)
# CDT-141-C3: shared epic path or per-ticket
# lint-ok: C3 — marketplace */ for-loop + -f guarded (SPEC-021 Q2 residual, CDT-82 PDH)
PDH=$( { [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -f "$CLAUDE_PLUGIN_ROOT/skills/plugin-dir.sh" ] && printf '%s\n' "$CLAUDE_PLUGIN_ROOT"; } || { [ -f skills/plugin-dir.sh ] && pwd; } || { for _mp in "$HOME"/.claude/plugins/marketplaces/*/; do [ -f "${_mp}skills/plugin-dir.sh" ] && [ -f "${_mp}agents/pm.md" ] && printf '%s\n' "${_mp%/}" && break; done; } || find ~/.claude/plugins/cache -path '*/dev-team/*/skills/plugin-dir.sh' 2>/dev/null | awk -F/ '{ver=""; for(i=1;i<=NF;i++) if($i=="dev-team"&&i<NF){ver=$(i+1);break}; if(ver=="") next; m=ver; gsub(/-pre\./,"~pre.",m); p=($0 ~ /\/cache\/cold-dark-void\/dev-team\//)?1:0; print m "\t" p "\t" $0}' | sort -t $'\t' -k1,1V -k2,2n -k3,3 | tail -1 | cut -f3 | xargs -r dirname | xargs -r dirname )
EPIC_LIB=$(bash "$PDH/skills/plugin-dir.sh" file skills/epic/epic-lib.sh)
WT_PATH=$(bash "$EPIC_LIB" ensure-ticket-worktree "<TICKET-ID>")
git -C "$WT_PATH" add specs/
git -C "$WT_PATH" commit -m "spec: <TICKET-ID> — add/update <feature area> spec"
```

---

## Step 6: Implementation plan + task graph

The Step 5 **Spawned-agent path contract** applies here too: substitute the resolved
absolute Step 1b worktree path for `<WT_PATH>` before sending, or spawn with that cwd.

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
@tech-lead Produce the implementation plan for <TICKET-ID>.

Confirmed ACs: <list>
Spec: <spec file path>
Affected files (your earlier assessment): <list>

Output:
1. Step-by-step plan saved to <WT_PATH>/.claude/plans/<YYYY-MM-DD>-<TICKET-ID>-<slug>.md
   — <WT_PATH> is the absolute worktree path from Step 1b (same branch as the spec,
   feat/<TICKET-ID>); write to it as an absolute path, not relative to your cwd
2. Task graph — which steps are independent (can run in parallel) and which have dependencies
3. For each step: recommended agent (ic4 for well-defined/extending patterns, ic5 for novel/complex),
   and what interface/contract it exposes that other steps depend on.

   Escalation heuristic: assign ic5 (not ic4) when a task:
   - Touches more than 10 files
   - Requires deleting/modifying code across more than 15 callsites
   - Involves wide-scope structural refactoring (e.g. removing a mode, renaming a concept)
   - Has unclear replacement strategy (each removed usage needs a different fix)
   ic4 excels at focused, well-scoped tasks. Wide-scope structural work burns excessive
   ic4 context (300+ messages observed). Either assign ic5, or split the task further.
4. Tracking section on the plan (source + closes) so ship can close trackers with delivery:

## Tracking
- source: linear | backlog | freeform
- ticket_id: <TICKET-ID>
- closes:
  - backlog/<slug>.md    # when ticket came from backlog, or dual-write
  - linear:<ID>          # when Linear issue exists

No schema changes or new dependencies without calling them out explicitly.
For each task, list dependencies as `Depends on: <TaskID>, <TaskID>` or `Depends on: none` so kickoff can extract them programmatically.
```

---

## Step 7: Create task graph via TaskCreate

Before creating any tasks, extract the dependency graph from the Tech Lead plan:
1. For each task in the plan, note its ID (Task 1, Task 2, etc.) and its "Depends on:" list
2. Build a JSON array: `[{"task_id": "TICKET-N", "depends_on": ["TICKET-M", ...]}, ...]`
3. Write the dependency JSON to `$DAG_FILE` and run:
   ```bash
   DAG_FILE="${TMPDIR:-/tmp}/kickoff-dag-$$.json"
   CYCLE_ERR="${TMPDIR:-/tmp}/kickoff-cycle-err-$$.txt"
   # (caller already wrote the dependency JSON into $DAG_FILE)
   # Re-resolve PDH (each bash fence is a fresh shell)
   # lint-ok: C3 — marketplace */ for-loop + -f guarded (SPEC-021 Q2 residual, CDT-82 PDH)
   PDH=$( { [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -f "$CLAUDE_PLUGIN_ROOT/skills/plugin-dir.sh" ] && printf '%s\n' "$CLAUDE_PLUGIN_ROOT"; } || { [ -f skills/plugin-dir.sh ] && pwd; } || { for _mp in "$HOME"/.claude/plugins/marketplaces/*/; do [ -f "${_mp}skills/plugin-dir.sh" ] && [ -f "${_mp}agents/pm.md" ] && printf '%s\n' "${_mp%/}" && break; done; } || find ~/.claude/plugins/cache -path '*/dev-team/*/skills/plugin-dir.sh' 2>/dev/null | awk -F/ '{ver=""; for(i=1;i<=NF;i++) if($i=="dev-team"&&i<NF){ver=$(i+1);break}; if(ver=="") next; m=ver; gsub(/-pre\./,"~pre.",m); p=($0 ~ /\/cache\/cold-dark-void\/dev-team\//)?1:0; print m "\t" p "\t" $0}' | sort -t $'\t' -k1,1V -k2,2n -k3,3 | tail -1 | cut -f3 | xargs -r dirname | xargs -r dirname )
   DAG_LIB=$(bash "$PDH/skills/plugin-dir.sh" file skills/orchestrate/dag-lib.sh)
   bash "$DAG_LIB" check-cycle "$DAG_FILE" 2>"$CYCLE_ERR"
   rc=$?
   if [ "$rc" -eq 1 ]; then
     # $CYCLE_MSG is the detected back-edge ("cycle: <from> -> <to>"), not a full path.
     CYCLE_MSG=$(cat "$CYCLE_ERR" 2>/dev/null || true)
     rm -f "$DAG_FILE" "$CYCLE_ERR"
     echo "Kickoff error: circular dependency detected ($CYCLE_MSG). Revise the task graph."
     # halt — do NOT call TaskCreate for any task
   elif [ "$rc" -ne 0 ]; then
     DIAG=$(cat "$CYCLE_ERR" 2>/dev/null || true)
     rm -f "$DAG_FILE" "$CYCLE_ERR"
     echo "Kickoff error: cycle gate could not run (rc=$rc): $DIAG"
     # halt — do NOT call TaskCreate for any task
   fi
   rm -f "$DAG_FILE" "$CYCLE_ERR"
   ```
   Do NOT call TaskCreate for any task if a cycle is detected or the cycle gate could not run.

Then detect quality-check mode:
```bash
_gc=$(git rev-parse --git-common-dir 2>/dev/null) \
  && MROOT=$(cd "$(dirname "$_gc")" && pwd) \
  || MROOT=$(pwd)
# CDT-141-C3: shared epic path or per-ticket
# lint-ok: C3 — marketplace */ for-loop + -f guarded (SPEC-021 Q2 residual, CDT-82 PDH)
PDH=$( { [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -f "$CLAUDE_PLUGIN_ROOT/skills/plugin-dir.sh" ] && printf '%s\n' "$CLAUDE_PLUGIN_ROOT"; } || { [ -f skills/plugin-dir.sh ] && pwd; } || { for _mp in "$HOME"/.claude/plugins/marketplaces/*/; do [ -f "${_mp}skills/plugin-dir.sh" ] && [ -f "${_mp}agents/pm.md" ] && printf '%s\n' "${_mp%/}" && break; done; } || find ~/.claude/plugins/cache -path '*/dev-team/*/skills/plugin-dir.sh' 2>/dev/null | awk -F/ '{ver=""; for(i=1;i<=NF;i++) if($i=="dev-team"&&i<NF){ver=$(i+1);break}; if(ver=="") next; m=ver; gsub(/-pre\./,"~pre.",m); p=($0 ~ /\/cache\/cold-dark-void\/dev-team\//)?1:0; print m "\t" p "\t" $0}' | sort -t $'\t' -k1,1V -k2,2n -k3,3 | tail -1 | cut -f3 | xargs -r dirname | xargs -r dirname )
EPIC_LIB=$(bash "$PDH/skills/plugin-dir.sh" file skills/epic/epic-lib.sh)
WT_PATH=$(bash "$EPIC_LIB" ensure-ticket-worktree "<TICKET-ID>")
# Re-resolve PDH (each bash fence is a fresh shell)
# lint-ok: C3 — marketplace */ for-loop + -f guarded (SPEC-021 Q2 residual, CDT-82 PDH)
PDH=$( { [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -f "$CLAUDE_PLUGIN_ROOT/skills/plugin-dir.sh" ] && printf '%s\n' "$CLAUDE_PLUGIN_ROOT"; } || { [ -f skills/plugin-dir.sh ] && pwd; } || { for _mp in "$HOME"/.claude/plugins/marketplaces/*/; do [ -f "${_mp}skills/plugin-dir.sh" ] && [ -f "${_mp}agents/pm.md" ] && printf '%s\n' "${_mp%/}" && break; done; } || find ~/.claude/plugins/cache -path '*/dev-team/*/skills/plugin-dir.sh' 2>/dev/null | awk -F/ '{ver=""; for(i=1;i<=NF;i++) if($i=="dev-team"&&i<NF){ver=$(i+1);break}; if(ver=="") next; m=ver; gsub(/-pre\./,"~pre.",m); p=($0 ~ /\/cache\/cold-dark-void\/dev-team\//)?1:0; print m "\t" p "\t" $0}' | sort -t $'\t' -k1,1V -k2,2n -k3,3 | tail -1 | cut -f3 | xargs -r dirname | xargs -r dirname )
DETECT_CLI=$(bash "$PDH/skills/plugin-dir.sh" file skills/ci-watch/detect-mode.sh)
QC_MODE=$(bash "$DETECT_CLI" "$WT_PATH" | head -n1)
```

Read the plan Tech Lead produced. For each step, issue a TaskCreate:

```
TaskCreate:
  subject: "<TICKET-ID> Task N — <step title>"
  description: |
    <step description from plan>
    Recommended agent: <ic4|ic5|qa>
    Depends on: [Task IDs] or "none"
    Exposes: <interface/contract other tasks need, if any>
```

After each TaskCreate, register the task in the task store with its dependencies:
```bash
# Build colon-separated depends_on from plan dep list
# Map to compound keys: replace "Task N" with "<TICKET>-<taskid>"
# e.g. if Task 3 depends on Task 1 and Task 2, and TICKET-ID is CDV-1:
#   DEPS="CDV-1-1:CDV-1-2"
# If no deps:
#   DEPS=""
DEPS=$(echo "<dep task IDs from plan, space/comma-separated>" | tr ', ' ':' | tr -s ':' | sed 's/^://;s/:$//')
# Replace each "Task N" reference with "<TICKET-ID>-N" compound key
# Re-resolve PDH (each bash fence is a fresh shell)
# lint-ok: C3 — marketplace */ for-loop + -f guarded (SPEC-021 Q2 residual, CDT-82 PDH)
PDH=$( { [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -f "$CLAUDE_PLUGIN_ROOT/skills/plugin-dir.sh" ] && printf '%s\n' "$CLAUDE_PLUGIN_ROOT"; } || { [ -f skills/plugin-dir.sh ] && pwd; } || { for _mp in "$HOME"/.claude/plugins/marketplaces/*/; do [ -f "${_mp}skills/plugin-dir.sh" ] && [ -f "${_mp}agents/pm.md" ] && printf '%s\n' "${_mp%/}" && break; done; } || find ~/.claude/plugins/cache -path '*/dev-team/*/skills/plugin-dir.sh' 2>/dev/null | awk -F/ '{ver=""; for(i=1;i<=NF;i++) if($i=="dev-team"&&i<NF){ver=$(i+1);break}; if(ver=="") next; m=ver; gsub(/-pre\./,"~pre.",m); p=($0 ~ /\/cache\/cold-dark-void\/dev-team\//)?1:0; print m "\t" p "\t" $0}' | sort -t $'\t' -k1,1V -k2,2n -k3,3 | tail -1 | cut -f3 | xargs -r dirname | xargs -r dirname )
TASK_STORE=$(bash "$PDH/skills/plugin-dir.sh" file skills/orchestrate/task-store.sh)
bash "$TASK_STORE" create "<TICKET-ID>-<task_id>" "<subject>" <requires_council> "$DEPS"
```

Create all tasks. Note their assigned IDs.

Then update the plan file (in the worktree) to include the task IDs:
```bash
# Re-derive working root + worktree (fresh shell — SPEC-021 C1)
_gc=$(git rev-parse --git-common-dir 2>/dev/null) \
  && MROOT=$(cd "$(dirname "$_gc")" && pwd) \
  || MROOT=$(pwd)
# CDT-141-C3: shared epic path or per-ticket
# lint-ok: C3 — marketplace */ for-loop + -f guarded (SPEC-021 Q2 residual, CDT-82 PDH)
PDH=$( { [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -f "$CLAUDE_PLUGIN_ROOT/skills/plugin-dir.sh" ] && printf '%s\n' "$CLAUDE_PLUGIN_ROOT"; } || { [ -f skills/plugin-dir.sh ] && pwd; } || { for _mp in "$HOME"/.claude/plugins/marketplaces/*/; do [ -f "${_mp}skills/plugin-dir.sh" ] && [ -f "${_mp}agents/pm.md" ] && printf '%s\n' "${_mp%/}" && break; done; } || find ~/.claude/plugins/cache -path '*/dev-team/*/skills/plugin-dir.sh' 2>/dev/null | awk -F/ '{ver=""; for(i=1;i<=NF;i++) if($i=="dev-team"&&i<NF){ver=$(i+1);break}; if(ver=="") next; m=ver; gsub(/-pre\./,"~pre.",m); p=($0 ~ /\/cache\/cold-dark-void\/dev-team\//)?1:0; print m "\t" p "\t" $0}' | sort -t $'\t' -k1,1V -k2,2n -k3,3 | tail -1 | cut -f3 | xargs -r dirname | xargs -r dirname )
EPIC_LIB=$(bash "$PDH/skills/plugin-dir.sh" file skills/epic/epic-lib.sh)
WT_PATH=$(bash "$EPIC_LIB" ensure-ticket-worktree "<TICKET-ID>")
# Append task map to bottom of plan file
echo "\n## Task Map\n" >> $WT_PATH/.claude/plans/<plan-file>.md
# For each task: "- Task N (id:<ID>): <title> [depends on: ...]"
```

---

## Step 7b: Domain glossary write-back (conditional)

After the plan is written (Step 6) and before/with the final summary, if kickoff
crystallized **user-confirmed** domain terms (new names from AC resolution,
design choices, explicit user answers, **or** a prior brainstorm plan's
`## Domain glossary delta` for this ticket):

1. Follow `skills/domain-glossary/SKILL.md` **Update protocol**
2. The **orchestrator itself** writes this back (not a spawned agent), so it already
   holds the resolved Step 1b path — write into the **worktree** at that absolute path:
   prefer `$WT_PATH/CONTEXT.md` (or existing `$WT_PATH/docs/domain/CONTEXT.md`) — never
   `$MROOT/CONTEXT.md`. An immediate `$MROOT` CONTEXT.md commit is itself a
   direct-to-master commit, the exact defect CDT-105 closes. Terms crystallized in a
   kickoff are tied to that ticket's spec, so they share its branch lifecycle
   (visibility-until-merge — intended, not a regression). If `$MROOT/CONTEXT.md` is
   dirty from a pre-worktree brainstorm that still wrote the file, **promote** those
   rows into `$WT_PATH` then restore MROOT (`git -C "$MROOT" checkout -- CONTEXT.md`)
   after the worktree commit — same as `/orchestrate` Step 3b.
3. Merge only confirmed terms; do not invent jargon
4. If `CONTEXT.md` changed, commit it inside `$WT_PATH` on `feat/<TICKET-ID>` —
   coupled with the Step 5 spec commit (same worktree, same branch):
   ```bash
   # Re-derive working root + worktree (fresh shell — SPEC-021 C1)
   _gc=$(git rev-parse --git-common-dir 2>/dev/null) \
     && MROOT=$(cd "$(dirname "$_gc")" && pwd) \
     || MROOT=$(pwd)
   # CDT-141-C3: shared epic path or per-ticket
# lint-ok: C3 — marketplace */ for-loop + -f guarded (SPEC-021 Q2 residual, CDT-82 PDH)
PDH=$( { [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -f "$CLAUDE_PLUGIN_ROOT/skills/plugin-dir.sh" ] && printf '%s\n' "$CLAUDE_PLUGIN_ROOT"; } || { [ -f skills/plugin-dir.sh ] && pwd; } || { for _mp in "$HOME"/.claude/plugins/marketplaces/*/; do [ -f "${_mp}skills/plugin-dir.sh" ] && [ -f "${_mp}agents/pm.md" ] && printf '%s\n' "${_mp%/}" && break; done; } || find ~/.claude/plugins/cache -path '*/dev-team/*/skills/plugin-dir.sh' 2>/dev/null | awk -F/ '{ver=""; for(i=1;i<=NF;i++) if($i=="dev-team"&&i<NF){ver=$(i+1);break}; if(ver=="") next; m=ver; gsub(/-pre\./,"~pre.",m); p=($0 ~ /\/cache\/cold-dark-void\/dev-team\//)?1:0; print m "\t" p "\t" $0}' | sort -t $'\t' -k1,1V -k2,2n -k3,3 | tail -1 | cut -f3 | xargs -r dirname | xargs -r dirname )
EPIC_LIB=$(bash "$PDH/skills/plugin-dir.sh" file skills/epic/epic-lib.sh)
WT_PATH=$(bash "$EPIC_LIB" ensure-ticket-worktree "<TICKET-ID>")
   git -C "$WT_PATH" add CONTEXT.md   # or docs/domain/CONTEXT.md, wherever it lives
   git -C "$WT_PATH" commit -m "context: <TICKET-ID> — crystallized glossary terms"
   ```

If no new terms, skip silently.

---

## Step 8: Print kickoff summary

Print a structured summary the engineer can use as a reference:

```
Kickoff complete for <TICKET-ID>

Worktree:   <WT_PATH>
Branch:     <feat/<TICKET-ID> | feat/epic-<EPIC-ID> when shared>
Spec:       specs/core/SPEC-NNN-<slug>.md [created|updated]  (on worktree branch)
Plan:       .claude/plans/<YYYY-MM-DD>-<TICKET-ID>-<slug>.md  (on worktree branch)
Glossary:   <CONTEXT.md path updated | no new terms>
Tasks:      N created

Task Graph:
  id:<N> Task 1 — <title>     → <ic4|ic5>   [ready to claim]
  id:<N> Task 2 — <title>     → <ic5>        [ready to claim]
  id:<N> Task 3 — <title>     → <ic4>        [blocked by Task 1, Task 2]
  id:<N> Task 4 — QA tests    → qa           [ready after Task 2 interface defined]
Quality check: <ci|local-test|none>  (detected via skills/ci-watch/detect-mode.sh $WT_PATH)

Parallel work ready:
  @ic4: claim Task 1 via TaskUpdate, start immediately
  @ic5: claim Task 2 via TaskUpdate, start immediately — SendMessage interface to @ic4 and @qa early
  @qa:  claim Task 4 via TaskUpdate, start after @ic5 defines the interface

Resume with /orchestrate <TICKET-ID> to implement, or cd into the worktree directly.
Next: /status standup to monitor progress
```

**Notify-on-done (CDT-123):** after printing the summary above (successful kickoff
completion, no early halt), emit `task_complete` (detail =
`kickoff complete: <TICKET-ID>`) via **Passive notifications → Tier B** (fail-open;
§ below). Do not notify when the run halted earlier under autopilot.

The spec, plan, and CONTEXT.md live on `feat/<TICKET-ID>` and are only visible on
that branch until it merges (`/spec check` on master won't see them yet) — this is the
intended visibility-until-merge trade, not a regression.

The worktree is left in place as resumable state: `/kickoff` **never** calls
`worktree-lib.sh release`. Per-ticket trees: lifecycle owned later by
`/orchestrate <TICKET-ID>` or `/wrap-ticket <TICKET-ID>`. Shared epic integration
trees: **not** released on child wrap (CDT-141-C3) — epic seal / end-of-epic owns them.

---

## Step 8b: Friction check (non-blocking)

After printing the kickoff summary, silently check whether the current session
has accumulated enough friction to warrant a retrospective. This check is
entirely non-blocking: if anything fails, print nothing and move on.

```bash
# Locate the dev-team plugin root (PDH). Optional CLAUDE_PLUGIN_ROOT (force path / FR #48230), else cwd dev/worktree, else marketplace clone (slug-free agents/pm.md), else installed cache (rank by /dev-team/<VER>/ segment, not full path; CDT-166). CDT-82: marketplace before same-version cache.
# lint-ok: C3 — marketplace */ for-loop + -f guarded (SPEC-021 Q2 residual, CDT-82 PDH)
PDH=$( { [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -f "$CLAUDE_PLUGIN_ROOT/skills/plugin-dir.sh" ] && printf '%s\n' "$CLAUDE_PLUGIN_ROOT"; } || { [ -f skills/plugin-dir.sh ] && pwd; } || { for _mp in "$HOME"/.claude/plugins/marketplaces/*/; do [ -f "${_mp}skills/plugin-dir.sh" ] && [ -f "${_mp}agents/pm.md" ] && printf '%s\n' "${_mp%/}" && break; done; } || find ~/.claude/plugins/cache -path '*/dev-team/*/skills/plugin-dir.sh' 2>/dev/null | awk -F/ '{ver=""; for(i=1;i<=NF;i++) if($i=="dev-team"&&i<NF){ver=$(i+1);break}; if(ver=="") next; m=ver; gsub(/-pre\./,"~pre.",m); p=($0 ~ /\/cache\/cold-dark-void\/dev-team\//)?1:0; print m "\t" p "\t" $0}' | sort -t $'\t' -k1,1V -k2,2n -k3,3 | tail -1 | cut -f3 | xargs -r dirname | xargs -r dirname )
bash "$PDH/skills/retro-gate/hint.sh" 2>/dev/null || true
```

Rules:
- Do **not** auto-run `/retro`. The single printed line is a suggestion only.
- Do **not** surface any error output from gate.sh or from path resolution.
- If gate.sh is missing, the session JSONL is missing, or the gate returns `passed:false`, print nothing.
- This section must never block or delay the rest of the kickoff output.

---

## Error Handling

- **No git repo**: HARD ERROR — halt. Step 1b's `worktree-lib.sh ensure` requires
  `git -C "$MROOT" worktree add` and will fail without a repo. There is no coherent
  degraded mode that both skips worktree creation and avoids committing to the current
  branch, so do NOT fall back to `pwd`/`$MROOT` — that reintroduces the master-commit
  defect CDT-105 closes. Print `/kickoff requires a git repository for worktree isolation.`
  and stop.
- **PM finds too many ambiguities (>4 open questions), autopilot ON** (`AUTOPILOT_ON`
  from Step 0): skip the pause below. Build the C3 §2 envelope
  `{ workflow:"kickoff", ticket_id:<TICKET-ID>, gate:"scope-confirm", run_id:RUN_ID,
  iteration:ITER, run_start_epoch:RUN_START_EPOCH, autopilot_bump:AUTOPILOT_BUMP,
  max_loc:MAX_LOC, <open-question count/text as the complexity signal> }` and call
  `skills/autopilot/self-answer.md`'s procedure (expected: BC1 → `halt`); on `halt`,
  emit `task_blocked` (detail = the one-line message) via **Passive notifications →
  Tier B** (fail-open; § below), then print `scope-confirm halt: <rationale> — card:
  <card-file-path>` and return control.
- **PM finds too many ambiguities (>4 open questions)**: pause and tell the user to clarify the ticket in Linear before proceeding — do not plan against a vague ticket
- **Tech Lead identifies a breaking schema change, autopilot ON** (`AUTOPILOT_ON` from
  Step 0): skip the pause below. Build the C3 §2 envelope
  `{ workflow:"kickoff", ticket_id:<TICKET-ID>, gate:"scope-confirm", run_id:RUN_ID,
  iteration:ITER, run_start_epoch:RUN_START_EPOCH, autopilot_bump:AUTOPILOT_BUMP,
  max_loc:MAX_LOC, <the breaking-schema flag as the destructive-op signal> }` and call
  `skills/autopilot/self-answer.md`'s procedure (expected: BC3 → `halt`); on `halt`,
  emit `task_blocked` (detail = the one-line message) via **Passive notifications →
  Tier B** (fail-open; § below), then print `scope-confirm halt: <rationale> — card:
  <card-file-path>` and return control.
- **Tech Lead identifies a breaking schema change**: pause and flag to the user; suggest DevOps involvement before creating tasks
- **No specs/ directory**: create `specs/core/` and note it in the summary; this ticket is the first spec
- **Ticket text is too short to plan from**: ask the user to paste the full ticket including ACs

---

## Passive notifications (CDT-123 / CDV-210 Tier B)

Same fail-open webhook sink as `/orchestrate` (`skills/notify/webhook.sh`). Never
block kickoff on notify failure. Unset `AGENT_WEBHOOK_URL` → silent.

At each site above that says **Passive notifications → Tier B**, run (fresh shell):

```bash
# lint-ok: C3 — marketplace */ for-loop + -f guarded (SPEC-021 Q2 residual, CDT-82 PDH)
PDH=$( { [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -f "$CLAUDE_PLUGIN_ROOT/skills/plugin-dir.sh" ] && printf '%s\n' "$CLAUDE_PLUGIN_ROOT"; } || { [ -f skills/plugin-dir.sh ] && pwd; } || { for _mp in "$HOME"/.claude/plugins/marketplaces/*/; do [ -f "${_mp}skills/plugin-dir.sh" ] && [ -f "${_mp}agents/pm.md" ] && printf '%s\n' "${_mp%/}" && break; done; } || find ~/.claude/plugins/cache -path '*/dev-team/*/skills/plugin-dir.sh' 2>/dev/null | awk -F/ '{ver=""; for(i=1;i<=NF;i++) if($i=="dev-team"&&i<NF){ver=$(i+1);break}; if(ver=="") next; m=ver; gsub(/-pre\./,"~pre.",m); p=($0 ~ /\/cache\/cold-dark-void\/dev-team\//)?1:0; print m "\t" p "\t" $0}' | sort -t $'\t' -k1,1V -k2,2n -k3,3 | tail -1 | cut -f3 | xargs -r dirname | xargs -r dirname )
NOTIFY=$(bash "$PDH/skills/plugin-dir.sh" file skills/notify/webhook.sh)
NOTIFY_SOURCE=kickoff NOTIFY_TICKET="<TICKET-ID>" \
  bash "$NOTIFY" <event> "<detail ≤500 chars>"
```

| Event | Kickoff call site |
|-------|-------------------|
| `task_blocked` | Autopilot halt at Step 3 OQ, Step 4b API-verify, >4 OQ, breaking-schema |
| `task_complete` | Step 8 kickoff summary printed successfully |

Tier A (MCP human milestones) is optional; same milestones as table if MCP available.
