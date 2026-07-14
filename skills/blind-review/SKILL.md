---
name: blind-review
description: |
  Multi-team blind peer review with automatic quorum analysis. Spawns N
  unconstrained reviewer agents + M lens-differentiated reviewer agents in
  parallel, then clusters their independent findings by semantic similarity
  to produce a confidence-tiered findings report. Optionally forwards
  Tier 1 consensus findings to /council for reverse validation. Use when
  you want adversarial, multi-perspective coverage of an entire codebase,
  a specific directory, or a set of files. Usage: /blind-review or
  /blind-review --teams 3 --lenses security,contributor,spec --target path/
---

# blind-review

End-to-end multi-team blind peer review with quorum analysis. You (the main
Claude) orchestrate agents and collect results — you do NOT write findings
yourself.

## Arguments

- `/blind-review` — review the current project with defaults
- `/blind-review --teams N` — N unconstrained teams (default: 3)
- `/blind-review --lenses L1,L2,...` — lens teams to spawn (default: security,contributor,spec)
- `/blind-review --target <path>` — narrow scope to a path/glob (default: full project)
- `/blind-review --no-council` — skip /council reverse-validation of Tier 1 findings

Available lenses: `security`, `contributor`, `spec`, `architecture`, `logic`

---

## Lens delta library

Inject the matching paragraph as `{{LENS_DELTA}}` in the lens-reviewer prompt.

### security
```
You are reviewing from an attacker's perspective. Your mental model: what
inputs are unvalidated or unescaped? Look for injection risks (SQL, shell,
HTML/XSS, path traversal, template injection), broken authentication or
authorization, insecure deserialization, sensitive data exposure, hardcoded
secrets, race conditions under concurrent access, and places where the system
silently does the wrong thing instead of failing loudly. Trust boundaries
between components matter too. Security is your angle — but you review
EVERYTHING, not just security-adjacent files.
```

### contributor
```
You just cloned this repo and need to understand and use it. Your mental model:
what is missing from documentation? What is inconsistent between similar
commands or components? What would trip up someone new? Are cross-references
between files correct? Are setup instructions complete? Is error output
helpful? Contributor experience is your angle — but you review EVERYTHING.
```

### spec
```
You are checking whether the code honours its stated contracts. "Contracts"
means whatever the project uses to describe intended behaviour: formal spec
files, README guarantees, OpenAPI/JSON Schema definitions, docstrings,
inline comments that say "always", "never", "must", or "guaranteed". Your
mental model: find the gap between what is promised and what is delivered.
Flag missing implementations, contradictions between contract documents, and
code behaviour that is undocumented or contradicts the stated contract.
Contract compliance is your angle — but you review EVERYTHING.
```

### architecture
```
You are evaluating design soundness. Your mental model: are abstractions at
the right level? Are responsibilities correctly separated? Is there tight
coupling that will cause maintenance pain? Are there design patterns that
are applied inconsistently? Architecture is your angle — but you review
EVERYTHING.
```

### logic
```
You are hunting correctness bugs. Your mental model: off-by-ones, wrong
operator precedence, variables used before assignment, dead code paths,
error handling that swallows failures, race conditions, incorrect assumptions
about data types or ranges. Logic correctness is your angle — but you review
EVERYTHING.
```

---

## Step 0: Resolve roots and parse arguments

```bash
_gc=$(git rev-parse --git-common-dir 2>/dev/null) \
  && MROOT=$(cd "$(dirname "$_gc")" && pwd) \
  || MROOT=$(pwd)
WTROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
```

Parse arguments:
- `TEAMS` — integer (default 3)
- `LENSES` — comma-separated list (default "security,contributor,spec")
- `TARGET` — path or glob (default: full project via git ls-files)
- `NO_COUNCIL` — boolean (default false)

---

## Step 1: Build the file list

Build the reviewer file list. Pass it to every reviewer as `{{FILE_LIST}}`.

```bash
_gc=$(git rev-parse --git-common-dir 2>/dev/null) \
  && MROOT=$(cd "$(dirname "$_gc")" && pwd) \
  || MROOT=$(pwd)
if [ -n "$TARGET" ]; then
  # Narrowed scope: files under the target path
  FILE_LIST=$(git ls-files "$MROOT/$TARGET" 2>/dev/null \
    || find "$MROOT/$TARGET" -type f | grep -v '.git/')
else
  # Full project: all tracked files, excluding lockfiles and generated assets
  FILE_LIST=$(git ls-files "$MROOT" 2>/dev/null \
    | grep -vE '\.(lock|min\.js|min\.css|pb\.go|pb\.py|svg)$' \
    | grep -v 'node_modules/' \
    | grep -v 'dist/' \
    | grep -v 'vendor/' )
fi
```

Also set `SCOPE_NOTE`:
```bash
if [ -n "$TARGET" ]; then
  SCOPE_NOTE="Review files under: $TARGET"
else
  SCOPE_NOTE="Review the full project (all tracked files listed below)."
fi
```

Print a brief summary to the user:
```
Scope: <full project | $TARGET>
Teams: $TEAMS unconstrained + N lens ($(echo $LENSES | tr ',' ' '))
Total reviewers: $((TEAMS + N_LENSES))
```

---

## Step 2: Spawn all reviewer teams in parallel

**CRITICAL: Spawn ALL unconstrained AND lens teams in a single parallel wave —
do not wait for any team before spawning the rest.**

### Unconstrained teams

For each team index 1..TEAMS, spawn using `prompts/unconstrained-reviewer.md`
with substitutions:
- `{{TEAM_ID}}` → `U<N>` (e.g. U1, U2, U3)
- `{{FILE_LIST}}` → the file list from Step 1
- `{{PROJECT_ROOT}}` → `$MROOT`
- `{{SCOPE_NOTE}}` → scope note from Step 1

### Lens teams

For each lens in LENSES, spawn using `prompts/lens-reviewer.md` with
substitutions:
- `{{TEAM_ID}}` → `L-<lens>` (e.g. L-security, L-contributor, L-spec)
- `{{LENS_NAME}}` → the lens name
- `{{LENS_DELTA}}` → the lens paragraph from the library above
- `{{FILE_LIST}}` → the file list from Step 1
- `{{PROJECT_ROOT}}` → `$MROOT`
- `{{SCOPE_NOTE}}` → scope note from Step 1

All reviewer agents: `subagent_type: general-purpose`, `Output mode: terse`.

Collect all results. Each result is a block of FINDING-NNN entries + SUMMARY.

---

## Step 3: Namespace and validate findings

For each reviewer result, prefix every FINDING-NNN with the team ID:
- `U1-FINDING-001`, `U1-FINDING-002`, ...
- `L-security-FINDING-001`, ...

Discard any finding that is missing `Category`, `Severity`, `Files`, `Claim`,
or `Evidence` fields — malformed findings are dropped, not repaired.

---

## Step 4: Spawn quorum analyst

Spawn ONE quorum analyst agent using `prompts/quorum-analyst.md` with
substitutions:
- `{{ALL_FINDINGS}}` → all namespaced FINDING blocks concatenated (one per
  team, separated by a team header line: `=== TEAM U1 ===`)
- `{{TEAM_MANIFEST}}` → list of all team IDs and their type (unconstrained/lens)
- `{{UNCONSTRAINED_TEAMS}}` → comma-separated unconstrained team IDs
- `{{LENS_TEAMS}}` → comma-separated lens team IDs
- `{{TOTAL_TEAMS}}` → total team count

The analyst produces CLUSTER-NNN blocks. Collect the result.

---

## Step 5: (conditional) Council reverse validation

Skip this step if `--no-council` was set OR if there are no Tier 1 clusters.

If Tier 1 clusters exist, invoke `/council` with the Tier 1 cluster claims
as the scope:

```
/council "<Tier 1 findings for reverse validation>

CLAIM-1: <CLUSTER-001 Claim>
CLAIM-2: <CLUSTER-002 Claim>
...
(one claim per Tier 1 cluster, framed as: reverse-validate this consensus
finding — look for evidence it is wrong or overstated)"
```

Collect council verdicts. Annotate each Tier 1 cluster in the final report
with the verdict: VERIFIED / PARTIALLY_VERIFIED / UNVERIFIED / CONTRADICTED / FABRICATED.

---

## Step 6: Write the report

Write the findings report to:
```bash
_gc=$(git rev-parse --git-common-dir 2>/dev/null) \
  && MROOT=$(cd "$(dirname "$_gc")" && pwd) \
  || MROOT=$(pwd)
REPORT_DATE=$(date +%Y-%m-%d)
REPORT_PATH="$MROOT/.claude/reviews/${REPORT_DATE}-blind-review.md"
mkdir -p "$MROOT/.claude/reviews"
```

### Report format

```markdown
# Blind Review — <date>

**Scope:** <full project | target path>
**Teams:** U1..UN (unconstrained), L-security, L-contributor, ... (lens)
**Total reviewers:** N
**Council reverse-validation:** yes | no (--no-council)

---

## Tier 1 — Doubly validated (cross-cohort, ≥2 teams)

### CLUSTER-001 — <Severity> — <Category>
**Count:** N/<total> teams | **Teams:** U1, L-security  
**Claim:** <claim>  
**Evidence:** <evidence>  
**Source findings:** U1-FINDING-003, L-security-FINDING-001  
**Council verdict:** VERIFIED (92) ← if council ran

...

---

## Tier 2 — Same-cohort consensus (≥2 teams, not cross-cohort)

...

---

## Tier 3 — Minority findings (single team)

> Tier 3 findings are not reverse-validated by council. Review manually.

...

---

## Quorum Summary

<QUORUM-SUMMARY from analyst>

---

## Per-team summaries

### U1
<SUMMARY from U1>

### L-security
<SUMMARY from L-security>

...
```

---

## Step 7: Present to user

Print:
```
Blind review complete.

Report: <relative path to report file>

Summary:
  Tier 1 (cross-cohort ≥2 teams): N clusters
  Tier 2 (same-cohort ≥2 teams):  N clusters
  Tier 3 (single team):           N clusters

Top findings:
  [CLUSTER-001] <severity> — <claim> (N/M teams)
  [CLUSTER-002] <severity> — <claim> (N/M teams)
  [CLUSTER-003] <severity> — <claim> (N/M teams)
  (showing top 5 Tier 1+2 only)

Council reverse-validation: <N claims challenged — N VERIFIED, N PARTIALLY_VERIFIED, N UNVERIFIED, N CONTRADICTED, N FABRICATED>
```

---

## Rules

1. **You do NOT write findings.** Your job is to orchestrate, collect, and present.
2. **All reviewer teams spawn in a single parallel wave** — never sequential.
3. **The quorum analyst sees all findings** — it is NOT blind. Do not restrict its input.
4. **Council only runs on Tier 1 clusters** — never on Tier 2 or 3.
5. **Tier 3 findings are included in the report** but not escalated to council.
6. **Dropped findings** (malformed) are noted in the report: "N findings dropped (malformed)."
7. **The report is always written** even if council fails or produces no verdicts.

---

## Error handling

- **No git repo**: warn; skip git ls-files, fall back to `find $MROOT -type f`
- **No findings from a team**: note in report as "Team X: 0 findings"
- **Quorum analyst returns no clusters**: write report with raw per-team summaries only
- **Council unavailable or fails**: write report without council verdicts; note the skip
- **Target path not found**: print error and stop
