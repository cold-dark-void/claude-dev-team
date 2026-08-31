---
name: bug-hunt
description: |
  Unknown-defect discovery pipeline: scoped multi-perspective discover →
  continuous refute/confirm → user-visible report → findings plan +
  proceed-gated bh-quality backlog materialize → severity-band phase handoff
  emit-only (stages 1–4; CDT-138/C3 + CDT-139/C4). Composes SPEC-013 blind +
  investigator; SPEC-009 programmatic write-back (no dual-write fork).
  MUST NOT invoke /orchestrate|/epic or fix product code; no re-S1–S2 invent.
  Entry: /bug-hunt [path] [--severity-floor …] [--proceed]
       | /bug-hunt materialize <path> [--severity-floor …] [--proceed]
       | /bug-hunt handoff <plan-path> [--start-phase <n>]
  Contract: specs/core/SPEC-034-bug-hunt-workflow.md.
---

# bug-hunt — Discover → Refute → Materialize → Handoff (stages 1–4)

Protocol for `/bug-hunt` stages **discover**, **refute/confirm**,
**findings plan + backlog materialize**, and **phase handoff emit-only**.
Thin command host: `commands/bug-hunt.md` (PDH-resolves this skill).

**Governing contract:** `specs/core/SPEC-034-bug-hunt-workflow.md` (DRAFT;
M8 materialize lock; M38–M41 stage-3 — CDT-138; M42–M48 stage-4 — CDT-139).
**Composition home (cite, do not fork):**

| Stage | Compose from | Do not |
|-------|--------------|--------|
| S1 Discover | `skills/council/SKILL.md` § Blind-review path + `commands/council.md` § Blind-review path (SPEC-013) | Nested `/council` user lock; second finder protocol |
| S2 Refute | SPEC-013 investigator pattern — `skills/council/prompts/investigator.md` + existing `skills/council/flavors/*` | Tribunal Phases 3–5 per candidate; new flavors; `engine.sh` whole-hunt finalize |
| S3 Materialize | `skills/backlog/SKILL.md` § **Programmatic write-back** (SPEC-009 dual-write; Linear-first fail-open) | Second dual-write / index / `add.sh` fork; auto-materialize without M8 proceed |
| S4 Handoff | templates `phase-plan.md` + `handoff-phase.md` (field contracts); M9 locks | Invoke `/orchestrate`/`/epic`; spawn fix ICs; edit product code; re-S1–S3 invent |

Neighboring surfaces (when-to-use — SPEC-034 M26):

| Surface | Job vs this skill |
|---------|-------------------|
| `/bug-hunt` (this) | Unknown defects; stages 1–4 (discover → refute → plan+materialize → phase handoff emit-only) |
| `/debug` / `/debug ticket` | Known bug premise → fix (not discovery) |
| `/council --blind` | One-shot blind investigation; no hunt report / floor / refute wave |
| `/backlog` | Interactive backlog; S3 cites programmatic write-back only |
| `/orchestrate` / `/epic` | Downstream fix engines — **print-only** hints from S4; never invoked here |

---

## Arguments

```
# Continuous (S1→S3→S4 same session — OQ5/OQ6):
Usage: /bug-hunt [path] [--severity-floor <critical|warning|nitpick>] [--proceed]

# Resume materialize (fresh session or re-run — OQ5):
Usage: /bug-hunt materialize <report|json|plan-path> [--severity-floor <critical|warning|nitpick>] [--proceed]

# Resume phase handoff (post-S3 plan; CDT-139 OQ6):
Usage: /bug-hunt handoff <plan-path> [--start-phase <n>]
```

| Arg / form | Required | Default | Fail / rule |
|------------|----------|---------|-------------|
| `path` (continuous) | No | project root (`$WTROOT`) | unusable / non-existent path (loud fail; M4) |
| `materialize <path>` | resume entry | — | path = `.json` preferred, `.md` report, or existing `-plan.md`; both findings+report missing → exit **64** (AC1 / M38) |
| `handoff <plan-path>` | resume S4 | — | path must end in `-plan.md` (or resolve sibling plan); missing/unreadable → exit **64** (AC1 / M42) |
| `--severity-floor` | No | continuous: `nitpick`; materialize resume: from artifact then `nitpick` | value ∉ {`critical`,`warning`,`nitpick`} → exit **64** (M3–M4); re-applied at S3b (AC2); **ignored for S4 banding** (OQ; bands use full severity order) |
| `--proceed` | No | off | Satisfies M8 without interactive token; enables S3e after plan (AC4 / OQ2) |
| Typed proceed | No | off | Exact token `proceed` (case-insensitive) on materialize lock prompt (S3d) |
| `--start-phase <n>` | No | off | Satisfies M9 for phase `n` without typed token (OQ5); handoff resume or continuous S4e |
| Typed `start-phase-<n>` | No | off | Case-insensitive exact token on S4e lock prompt (OQ5) |

Canonical continuous form: SPEC-034 M5 + optional `--proceed`. Floor order:
`critical` > `warning` > `nitpick`. S4 continuous after S3g when skill reaches S4a.

**Session bindings:**

| Binding | Meaning | Set |
|---------|---------|-----|
| `BH_PATH` | Absolute path scope (default `$WTROOT`; must exist + be under `$WTROOT` or `$MROOT`) | S0 |
| `BH_FLOOR` | Active severity floor enum (`critical` \| `warning` \| `nitpick`) | S0; re-bound S3a |
| `BH_SLUG` | Short kebab slug for report/plan filename | S0 / S3a |
| `BH_DATE` | UTC `YYYY-MM-DD` used in report/plan name | S0 / S3a |
| `BH_STEM` | `<date>-<slug>` identity for report/json/plan | S0 / S3a |
| `BH_REPORT_DIR` | `$MROOT/.claude/bug-hunt` | S0 |
| `BH_REPORT` | `$BH_REPORT_DIR/<YYYY-MM-DD>-<slug>.md` | S0 / REPORT |
| `BH_FINDINGS` | `$BH_REPORT_DIR/<YYYY-MM-DD>-<slug>.json` (SHOULD; preferred S3 load) | REPORT / S3a |
| `BH_PLAN` | `$BH_REPORT_DIR/<YYYY-MM-DD>-<slug>-plan.md` (OQ1 / M39) | S3c |
| `BH_PROCEED` | `none` \| `flag` \| `token` — M8 record before S3e | S3d |
| `BH_MODE` | `continuous` \| `materialize` \| `handoff` | S0 |
| `BH_TEAMS` / `BH_LENSES` / `BH_MANIFEST` | S1 blind defaults + team/lens manifest | S1 |
| `candidates[]` / `dropped[]` | S1 outputs for S2 / REPORT | S1 |
| `confirmed[]` / `refuted[]` / `confirmed_actionable[]` | S2 disposition outputs | S2 |
| `BH_ACTIONABLE[]` | S3 filter: confirmed ∧ severity ≥ floor (re-applied) | S3b |
| `BH_MAT_A` / `BH_MAT_M` / `BH_MAT_S` / `BH_MAT_F` | materialize counts: actionable / materialized / skipped_linked / failed | S3e–S3g |
| `BH_REFUTE_DEGRADED` / `BH_VERIFICATION_MODE` | S2 degradation flag + `full` \| `self-verified` | S2 |
| `BH_PHASEABLE[]` | S4 rows: plan status `materialized` \| `skipped_linked` + non-empty `backlog_slug` (OQ3) | S4a |
| `BH_PHASES[]` | banded phases `{phase_id, n, band, items[]}` after omit-empty renumber | S4b |
| `BH_PHASE_COUNT` / `BH_ITEM_COUNT` | \|non-empty bands\| / \|phaseable\| | S4b |
| `BH_ROUTE` | `/orchestrate` or `/epic` (AC4 / M45) | S4c |
| `BH_PHASE_PLAN` | `$BH_REPORT_DIR/<stem>-phase-plan.md` | S4d |
| `BH_HANDOFF_N` | map n → `$BH_REPORT_DIR/<stem>-handoff-phase-<n>.md` | S4d |
| `BH_ARM_PHASE` | `none` \| integer n armed via M9 (flag or token) | S4e–S4f |
| `BH_START_PHASE` | CLI `--start-phase` value or unset | S0 / S4e |

---

## Invariants (non-negotiable)

Hard walls — breaking any is a bug (SPEC-034 M8 / M27–M30 / N1–N13 / CDT-138 AC4–AC5 /
CDT-139 AC9–AC12):

- **MUST NOT materialize without proceed** — plan write (S3c) is allowed; backlog create
  (S3e) only after M8 (`--proceed` or typed `proceed`). Auto-materialize without proceed
  MUST NOT occur (AC4; M8; N2).
- **MUST NOT dual-write fork** — materialize cites `skills/backlog/SKILL.md` § Programmatic
  write-back only; MUST NOT reimplement mkdir/printf/index/`add.sh` (AC5; M40).
- **MUST NOT invoke engines / fix** — S4 **emits** phase templates under M9 locks; **MUST NOT
  invoke** `/orchestrate`, `/epic`, spawn fix ICs, or edit product code to "fix"
  (AC9/AC12; M30; N1; N12). Print `invocation_hint` only after arm.
- **MUST NOT re-run S1 discover or S2 refute on resume** — `materialize <path>` and
  `handoff <plan>` load artifacts only (AC12 / OQ5 / N13).
- **MUST NOT invent severity taxonomy or parallel ticket lifecycle** — severity ∈
  {`critical`,`warning`,`nitpick`} only; no second backlog/orchestrator (M13, M19, M29, N5, N9).
- **MUST NOT place a user lock between S1 and S2** — single continuous run (M7, N8).
  Proceed lock at S3d (after plan); phase lock at S4e (start phase 0 + between phases).
- **MUST NOT invent confirmed findings** — evidence-or-silence; fail closed on thin evidence
  (prefer `refuted`).
- **MUST NOT re-enter S1–S3 invent during handoff** — S4 loads C3 plan only (N13).
- **CDV-199 marker** — on unusable investigator/refuter spawn, exact string  
  `self-verified — refuters unavailable`  
  Actor = orchestrator only; never ship on implementer self-validation. Protocol home:  
  `skills/council/SKILL.md` § Spawn-failure degradation (cite; do not restate a second protocol).
- **No version files** — never edit `.claude-plugin/plugin.json`, `marketplace.json`,
  `CHANGELOG.md` version sections, or run `/release`.
- **No commit** — never `git commit` / `git add` / `git checkout` / `git reset` in the hunt
  pipeline.
- **Process artifacts uncommitted** — under `$MROOT/.claude/bug-hunt/` only (M25); root
  `.gitignore` lists `.claude/bug-hunt/`. Backlog items under `.claude/backlog/` also
  process-local (SPEC-009).
- **Output mode: terse** on every Task spawn.
- **Compose, do not fork** — S1/S2 reuse SPEC-013 patterns (M16); S3 reuses SPEC-009
  programmatic write-back; no nested slash-command UX that implies a user lock before S3d.

---

## Pipeline (stage diagram)

Continuous S1→S2→REPORT — **no** inter-stage user lock; S3 after REPORT (continuous)
or via `materialize` resume; S4 after S3g (continuous) or `handoff` resume.
**Locks:** proceed at S3d; phase start at S4e (M9).

```
S0  parse/validate  (continuous | materialize <path> | handoff <plan>)
     │
     ├─ continuous ──────────────────────────────────────────┐
     │                                                       ▼
     │  S1  DISCOVER  ── compose SPEC-013 blind path (defaults)
     │       │             --target = BH_PATH
     │       │             map → candidates[] (status=candidate)
     │       │             phase-done M20
     │       │
     │       ▼  (no user lock)
     │  S2  REFUTE    ── ≥2 SPEC-013 investigators / candidate
     │       │             confirmed_actionable = confirmed ∧ ≥floor
     │       │             phase-done M21
     │       │
     │       ▼
     │  REPORT        ── .claude/bug-hunt/<date>-<slug>.md
     │                   SHOULD: findings.json same stem
     │
     ├─ resume: materialize <path> ── loads artifacts only (no re-S1/S2)
     │
     ▼
S3a LOAD           json preferred → report.md fallback → loud fail both missing (AC1 / M38)
     │
     ▼
S3b FILTER         actionable[] = confirmed ∧ severity≥floor; re-apply floor (AC2)
     │
     ▼
S3c PLAN WRITE     $MROOT/.claude/bug-hunt/<date>-<slug>-plan.md  (AC3 / M39)
     │               linkage columns empty until materialize
     │
     ▼
S3d PROCEED LOCK   if A==0 → skip lock + zero creates (AC10)
     │               else: require --proceed OR typed `proceed` (AC4 / M8 / OQ2)
     │               neither → STOP after plan; print how to resume; 0 backlog creates
     ▼
S3e MATERIALIZE    unlinked actionable[] via backlog Programmatic write-back (AC5–AC7 / M40)
     │               OQ3 skip when plan already has slug + item exists
     │
     ▼
S3f LINK BACK      plan rows: backlog_slug + linear_id (AC8 plan→item)
     │
     ▼
S3g PHASE-DONE     M22 line + counts (AC9); continue S4a continuous (or stop if plan-only)
     │
     ├─ resume: handoff <plan-path> [--start-phase n] ── S4a only (no re-S1–S3 invent)
     │
     ▼
S4a LOAD           findings plan → phaseable[] (OQ3); loud fail unreadable (AC1 / M42)  [T2]
     │
     ▼
S4b BAND           critical→warning→nitpick; omit empty; renumber 0..N (AC2 / M43)      [T2]
     │               phase_count==0 → S4g zero (AC11); no S4e lock
     ▼
S4c ROUTE          phase_count≥2 AND item_count≥2 → /epic else /orchestrate (AC4 / M45)
     │
     ▼
S4d WRITE          <stem>-phase-plan.md + <stem>-handoff-phase-<n>.md (AC3 / M44)
     │               emit-only Write tool; bind BH_PHASE_PLAN + BH_HANDOFF_N (AC9)
     ▼
S4e LOCK           phase n: --start-phase n OR typed start-phase-n (AC5 / M46)
     │               without lock: print how-to; exit 0; templates on disk
     ▼
S4f ARM            print invocation_hint only; MUST NOT spawn (AC9 / OQ10)
     │
     ▼
S4g PHASE-DONE     M23 line + paths + route + counts (AC7 / M48); stop
```

**Not in this skill (later):** `--teams`/`--lenses` flags on `/bug-hunt`, tribunal per
candidate, Workflow driver, auto-running fix engines.

---

## Finding model (schema map)

Statuses (M10): `candidate` | `refuted` | `confirmed`.

Required field shapes (M11 / AC8 — same keys on candidates; S2 fills evidence depth):

| Field | Rule |
|-------|------|
| `locator` | Non-empty stable pointer `path[:line]` or symbol |
| `severity` | `critical` \| `warning` \| `nitpick` only; else drop malformed |
| `description` | What is wrong |
| `evidence` | Why real (tool cites / team IDs / investigator evidence) |
| `status` | S1: `candidate`; S2: `confirmed` \| `refuted` |

### S1 → `candidates[]` map (blind cluster / finding → bug-hunt)

Primary sources: quorum **CLUSTER-NNN** blocks (Tier 1 primary; Tier 2/3 MAY enter
with lower prior). Well-formed single-team FINDING blocks that never joined a
cluster MAY enter as Tier-3-equivalent candidates so refute, not discover,
decides truth. Prefer inclusion of all well-formed ≥floor items.

| Bug-hunt field | Source (blind path) |
|----------------|---------------------|
| `locator` | Files / `file`+`line` → stable `path[:line]` or symbol; **required non-empty** |
| `severity` | cluster/finding Severity; MUST ∈ {`critical`,`warning`,`nitpick`}; else **malformed drop** |
| `description` | Claim / description text (cluster Claim or FINDING Claim) |
| `evidence` | Evidence text + source team IDs / FINDING ids (pre-refute; S2 deepens) |
| `status` | Exactly `candidate` at S1 exit |

Optional session metadata (not AC8-required, useful for T4/T5):

| Field | Meaning |
|-------|---------|
| `id` | Stable id e.g. `CLUSTER-001` or namespaced `U1-FINDING-003` |
| `tier` | `1` \| `2` \| `3` when from quorum; omit if unknown |
| `category` | Blind Category when present |
| `source_findings` | List of namespaced FINDING ids |

**July HIGH/MEDIUM/LOW** (if any appear) → map display-only per M13
(`HIGH`→`critical`, `MEDIUM`→`warning`, `LOW`→`nitpick`); **never** store
HIGH/MEDIUM/LOW as canonical product values.

### `dropped[]` (informational — M15)

Below-floor, out-of-scope, and malformed items go to `dropped[]` only. They
**never** enter `candidates[]` and are never actionable. Shape:

| Field | Rule |
|-------|------|
| `locator` | Best-effort pointer (may be empty only when truly absent) |
| `severity` | Canonical enum when known; else raw string + note |
| `description` | Claim text when known |
| `reason` | `below-floor` \| `out-of-scope` \| `malformed` |
| `detail` | One-line why (e.g. `severity nitpick < floor warning`; missing Files) |

### Floor order and filter (AC9 / M15 / M32)

Order: `critical` > `warning` > `nitpick`.

- **S1:** severity **strictly below** `BH_FLOOR` → `dropped[]` only (`reason=below-floor`); never enter `candidates[]`.
- **S1:** locator path outside `BH_PATH` tree → drop (`reason=out-of-scope`); never candidate.
- **S2:** disposition only `candidates[]` (every one → `confirmed` \| `refuted`).
- **Report actionable:** `status=confirmed` AND `severity ≥ BH_FLOOR` → `confirmed_actionable[]`.
  With S1 floor drop, confirmed set ⊆ ≥floor.

---

## Step S0: Parse / validate

**Contract (SPEC-034 M2–M5 / AC2):**

1. Resolve `$MROOT` / `$WTROOT` (worktree-aware; re-derive in **every** bash fence — SPEC-021 C1).
2. Parse user args → bind session vars below.
3. Defaults: `path` = `$WTROOT`; `--severity-floor` = `nitpick`.
4. Loud fail — print error + Usage; stop; exit **64** (EX_USAGE) — on:
   - floor ∉ {`critical`,`warning`,`nitpick`} (including missing value after flag)
   - path missing / non-existent / unreadable / outside `$WTROOT`∪`$MROOT`
   - unknown flag or extra positional
5. Do **not** `mkdir` `BH_REPORT_DIR` here (REPORT writes); bind path strings only.
6. On success: continuous → S1 (no user lock); materialize resume → **S3a** only;
   handoff resume → **S4a** only.

### Usage (exact — M5 + C3/C4 surface)

```
Usage: /bug-hunt [path] [--severity-floor <critical|warning|nitpick>] [--proceed]
Usage: /bug-hunt materialize <report|json|plan-path> [--severity-floor <critical|warning|nitpick>] [--proceed]
Usage: /bug-hunt handoff <plan-path> [--start-phase <n>]
```

**S0 modes:**

| Mode | Detect | Path |
|------|--------|------|
| continuous | first token ∉ {`materialize`,`handoff`} | S1 → S2 → REPORT → S3 → **S4a** |
| materialize | first token = `materialize` | bind path → **S3a** only (no S1/S2) |
| handoff | first token = `handoff` | bind plan path → **S4a** only (no S1–S3 invent) |

`--proceed` may appear on continuous/materialize; bind `BH_PROCEED=flag` (S3d).
`--start-phase <n>` may appear on continuous/handoff; bind `BH_START_PHASE=n` (S4e).

### 0a. Resolve roots + PDH (fresh-shell safe)

```bash
_gc=$(git rev-parse --git-common-dir 2>/dev/null) \
  && MROOT=$(cd "$(dirname "$_gc")" && pwd) \
  || MROOT=$(pwd)
WTROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
# Locate the dev-team plugin root (PDH). Optional CLAUDE_PLUGIN_ROOT (force path / FR #48230), else cwd dev/worktree, else marketplace clone (slug-free agents/pm.md), else installed cache (rank by /dev-team/<VER>/ segment, not full path; CDT-166). CDT-82: marketplace before same-version cache.
# lint-ok: C3 — marketplace */ for-loop + -f guarded (SPEC-021 Q2 residual, CDT-82 PDH)
PDH=$( { [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -f "$CLAUDE_PLUGIN_ROOT/skills/plugin-dir.sh" ] && printf '%s\n' "$CLAUDE_PLUGIN_ROOT"; } || { [ -f skills/plugin-dir.sh ] && pwd; } || { for _mp in "$HOME"/.claude/plugins/marketplaces/*/; do [ -f "${_mp}skills/plugin-dir.sh" ] && [ -f "${_mp}agents/pm.md" ] && printf '%s\n' "${_mp%/}" && break; done; } || find ~/.claude/plugins/cache -path '*/dev-team/*/skills/plugin-dir.sh' 2>/dev/null | awk -F/ '{ver=""; for(i=1;i<=NF;i++) if($i=="dev-team"&&i<NF){ver=$(i+1);break}; if(ver=="") next; m=ver; gsub(/-pre\./,"~pre.",m); p=($0 ~ /\/cache\/cold-dark-void\/dev-team\//)?1:0; print m "\t" p "\t" $0}' | sort -t $'\t' -k1,1V -k2,2n -k3,3 | tail -1 | cut -f3 | xargs -r dirname | xargs -r dirname )
BH_SKILL=$(bash "$PDH/skills/plugin-dir.sh" file skills/bug-hunt/SKILL.md)
[ -n "$BH_SKILL" ] && [ -f "$BH_SKILL" ] || {
  echo "error: could not resolve skills/bug-hunt/SKILL.md via plugin-dir.sh" >&2
  exit 1
}
BH_REPORT_DIR="$MROOT/.claude/bug-hunt"
```

Carry `MROOT`, `WTROOT`, `PDH`, `BH_SKILL`, `BH_REPORT_DIR` in the session. Re-run
this fence (or re-bind the same formulas) before any later bash step — fences do
not share shell state.

### 0b. Parse args + validate

Orchestrator feeds the user invocation into the parse loop (`set -- …` from
`$ARGUMENTS`, or equivalent in-session parse with the same rules). Fail code
**64** = usage / invalid input (M4 loud fail).

```bash
# Re-bind roots (fresh shell — SPEC-021 C1)
_gc=$(git rev-parse --git-common-dir 2>/dev/null) \
  && MROOT=$(cd "$(dirname "$_gc")" && pwd) \
  || MROOT=$(pwd)
WTROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
BH_REPORT_DIR="$MROOT/.claude/bug-hunt"

BH_USAGE='Usage: /bug-hunt [path] [--severity-floor <critical|warning|nitpick>] [--proceed]
Usage: /bug-hunt materialize <report|json|plan-path> [--severity-floor <critical|warning|nitpick>] [--proceed]
Usage: /bug-hunt handoff <plan-path> [--start-phase <n>]'

# --- inject user args here, e.g.:
#   set --                          # defaults only
#   set -- skills/bug-hunt
#   set -- skills --severity-floor warning
#   set -- --severity-floor=critical
#   set -- --proceed
#   set -- materialize .claude/bug-hunt/x.json --proceed
#   set -- handoff .claude/bug-hunt/x-plan.md
#   set -- handoff .claude/bug-hunt/x-plan.md --start-phase 0
#   set -- /no/such/path            # → exit 64
#   set -- --severity-floor high     # → exit 64

BH_PATH_ARG=""
BH_FLOOR="nitpick"
BH_MODE="continuous"
BH_PROCEED="none"
BH_MAT_PATH=""
BH_HANDOFF_PATH=""
BH_START_PHASE=""

# Resume entry: first token materialize | handoff
if [ "${1:-}" = "materialize" ]; then
  BH_MODE="materialize"
  shift
  if [ -z "${1:-}" ] || case "${1:-}" in --*) true;; *) false;; esac; then
    echo "error: materialize requires <report|json|plan-path>" >&2
    echo "$BH_USAGE" >&2
    exit 64
  fi
  BH_MAT_PATH="$1"
  shift
elif [ "${1:-}" = "handoff" ]; then
  BH_MODE="handoff"
  shift
  if [ -z "${1:-}" ] || case "${1:-}" in --*) true;; *) false;; esac; then
    echo "error: handoff requires <plan-path>" >&2
    echo "$BH_USAGE" >&2
    exit 64
  fi
  BH_HANDOFF_PATH="$1"
  shift
fi

while [ $# -gt 0 ]; do
  case "$1" in
    --severity-floor)
      if [ -z "${2:-}" ] || case "$2" in --*) true;; *) false;; esac; then
        echo "error: --severity-floor requires one of: critical|warning|nitpick" >&2
        echo "$BH_USAGE" >&2
        exit 64
      fi
      BH_FLOOR="$2"
      shift 2
      ;;
    --severity-floor=*)
      BH_FLOOR="${1#--severity-floor=}"
      shift
      ;;
    --proceed)
      BH_PROCEED="flag"
      shift
      ;;
    --start-phase)
      if [ -z "${2:-}" ] || case "$2" in --*) true;; *) false;; esac; then
        echo "error: --start-phase requires <n> (non-negative integer)" >&2
        echo "$BH_USAGE" >&2
        exit 64
      fi
      BH_START_PHASE="$2"
      shift 2
      ;;
    --start-phase=*)
      BH_START_PHASE="${1#--start-phase=}"
      shift
      ;;
    -h|--help)
      echo "$BH_USAGE"
      exit 0
      ;;
    --)
      shift
      break
      ;;
    -*)
      echo "error: unknown flag: $1" >&2
      echo "$BH_USAGE" >&2
      exit 64
      ;;
    *)
      if [ "$BH_MODE" = "materialize" ] || [ "$BH_MODE" = "handoff" ]; then
        echo "error: unexpected extra argument: $1" >&2
        echo "$BH_USAGE" >&2
        exit 64
      fi
      if [ -n "$BH_PATH_ARG" ]; then
        echo "error: unexpected extra argument: $1" >&2
        echo "$BH_USAGE" >&2
        exit 64
      fi
      BH_PATH_ARG="$1"
      shift
      ;;
  esac
done

# Floor enum (M3–M4) — no silent coercion (both modes)
case "$BH_FLOOR" in
  critical|warning|nitpick) ;;
  *)
    echo "error: invalid --severity-floor '$BH_FLOOR' (want critical|warning|nitpick)" >&2
    echo "$BH_USAGE" >&2
    exit 64
    ;;
esac

# Validate --start-phase when set (non-negative integer)
if [ -n "$BH_START_PHASE" ]; then
  case "$BH_START_PHASE" in
    *[!0-9]*|'')
      echo "error: --start-phase requires non-negative integer (got '$BH_START_PHASE')" >&2
      echo "$BH_USAGE" >&2
      exit 64
      ;;
  esac
fi

if [ "$BH_MODE" = "handoff" ]; then
  # Resume S4: S4a resolves BH_HANDOFF_PATH → BH_PLAN (-plan.md), loud fail 64.
  # MUST NOT re-enter S1–S3 invent (N13).
  printf 'BH_MODE=%s\nBH_HANDOFF_PATH=%s\nBH_START_PHASE=%s\nBH_REPORT_DIR=%s\n' \
    "$BH_MODE" "$BH_HANDOFF_PATH" "${BH_START_PHASE:-}" "$BH_REPORT_DIR"
  # Orchestrator: jump to Step S4a (LOAD).
elif [ "$BH_MODE" = "materialize" ]; then
  # Resume: S3a loads BH_MAT_PATH. MUST NOT enter S1/S2.
  printf 'BH_MODE=%s\nBH_MAT_PATH=%s\nBH_FLOOR=%s\nBH_PROCEED=%s\nBH_START_PHASE=%s\nBH_REPORT_DIR=%s\n' \
    "$BH_MODE" "$BH_MAT_PATH" "$BH_FLOOR" "$BH_PROCEED" "${BH_START_PHASE:-}" "$BH_REPORT_DIR"
  # Orchestrator: jump to Step S3a (LOAD + FILTER).
else
  # Continuous path resolve (M2, M4)
  if [ -z "$BH_PATH_ARG" ]; then
    BH_PATH="$WTROOT"
  else
    case "$BH_PATH_ARG" in
      /*) BH_PATH="$BH_PATH_ARG" ;;
      *)  BH_PATH="$WTROOT/$BH_PATH_ARG" ;;
    esac
  fi

  # Normalize existing paths (no invent via realpath -m)
  if [ -e "$BH_PATH" ]; then
    if [ -d "$BH_PATH" ]; then
      BH_PATH=$(CDPATH= cd -- "$BH_PATH" && pwd) || BH_PATH=""
    else
      _bh_dir=$(CDPATH= cd -- "$(dirname -- "$BH_PATH")" && pwd) || _bh_dir=""
      if [ -n "$_bh_dir" ]; then
        BH_PATH="$_bh_dir/$(basename -- "$BH_PATH")"
      fi
    fi
  fi

  if [ -z "$BH_PATH" ] || [ ! -e "$BH_PATH" ]; then
    echo "error: path does not exist: ${BH_PATH_ARG:-$BH_PATH}" >&2
    echo "$BH_USAGE" >&2
    exit 64
  fi
  if [ ! -r "$BH_PATH" ]; then
    echo "error: path not readable: $BH_PATH" >&2
    echo "$BH_USAGE" >&2
    exit 64
  fi

  # Scope must sit under project / worktree root
  case "$BH_PATH" in
    "$WTROOT"|"$WTROOT"/*|"$MROOT"|"$MROOT"/*) ;;
    *)
      echo "error: path outside project root (WTROOT/MROOT): $BH_PATH" >&2
      echo "$BH_USAGE" >&2
      exit 64
      ;;
  esac

  # Slug + stem for report/plan filenames
  BH_DATE=$(date -u +%Y-%m-%d)
  if [ "$BH_PATH" = "$WTROOT" ] || [ "$BH_PATH" = "$MROOT" ]; then
    BH_SLUG="root"
  else
    BH_SLUG=$(basename -- "$BH_PATH" | tr '[:upper:]' '[:lower:]' \
      | sed -e 's/[^a-z0-9]\{1,\}/-/g' -e 's/^-//' -e 's/-$//' -e 's/-\{2,\}/-/g')
    [ -n "$BH_SLUG" ] || BH_SLUG="scope"
  fi
  BH_STEM="${BH_DATE}-${BH_SLUG}"
  BH_REPORT="$BH_REPORT_DIR/${BH_STEM}.md"
  BH_FINDINGS="$BH_REPORT_DIR/${BH_STEM}.json"
  BH_PLAN="$BH_REPORT_DIR/${BH_STEM}-plan.md"

  printf 'BH_MODE=%s\nBH_PATH=%s\nBH_FLOOR=%s\nBH_SLUG=%s\nBH_DATE=%s\nBH_STEM=%s\nBH_REPORT_DIR=%s\nBH_REPORT=%s\nBH_FINDINGS=%s\nBH_PLAN=%s\nBH_PROCEED=%s\nBH_START_PHASE=%s\n' \
    "$BH_MODE" "$BH_PATH" "$BH_FLOOR" "$BH_SLUG" "$BH_DATE" "$BH_STEM" \
    "$BH_REPORT_DIR" "$BH_REPORT" "$BH_FINDINGS" "$BH_PLAN" "$BH_PROCEED" \
    "${BH_START_PHASE:-}"
fi
```

If the orchestrator parses in prose (not bash), apply the **same** rules and stop
with the Usage line on any failure — silent ignore / silent coercion of invalid
args MUST NOT occur (M4).

### 0c. Fail-path checklist (for operators / T6)

| Input | Expected |
|-------|----------|
| `/bug-hunt` | `BH_MODE=continuous`, `BH_PATH=$WTROOT`, `BH_FLOOR=nitpick`, `BH_SLUG=root` |
| `/bug-hunt skills` | `BH_PATH` → abs under WTROOT; floor `nitpick` |
| `/bug-hunt --severity-floor warning` | path default; floor `warning` |
| `/bug-hunt skills --severity-floor=critical` | both set |
| `/bug-hunt --proceed` | `BH_PROCEED=flag`; continuous path |
| `/bug-hunt materialize .claude/bug-hunt/x.json` | `BH_MODE=materialize`; skip S1/S2 → S3a |
| `/bug-hunt materialize x.json --proceed` | resume + `BH_PROCEED=flag` |
| `/bug-hunt materialize` (no path) | **exit 64** + Usage |
| materialize path missing both json+report | **exit 64** + `error: no findings.json or report.md at <stem>` |
| `/bug-hunt handoff .claude/bug-hunt/x-plan.md` | `BH_MODE=handoff` → S4a |
| `/bug-hunt handoff x-plan.md --start-phase 0` | handoff + `BH_START_PHASE=0` |
| `/bug-hunt handoff` (no path) | **exit 64** + Usage |
| handoff plan missing/unreadable | **exit 64** + `error: findings plan not readable: <path>` (S4a / M42) |
| handoff path not `*-plan.md` (and no sibling) | **exit 64** + `error: handoff path must end in -plan.md: <path>` |
| `/bug-hunt --severity-floor high` | **exit 64** + Usage |
| `/bug-hunt --severity-floor` (no value) | **exit 64** + Usage |
| `/bug-hunt /no/such/path` | **exit 64** + `path does not exist` |
| `/bug-hunt --bogus` | **exit 64** + `unknown flag` |

### 0d. Proceed

| Mode | Session holds | Next step |
|------|---------------|-----------|
| continuous | `BH_PATH`, `BH_FLOOR`, `BH_SLUG`, `BH_DATE`, `BH_STEM`, `BH_REPORT_DIR`, `BH_REPORT`, `BH_FINDINGS`, `BH_PLAN`, `BH_PROCEED`, `BH_START_PHASE` | **S1** (no inter-stage lock); after S3g → **S4a** |
| materialize | `BH_MODE`, `BH_MAT_PATH`, `BH_FLOOR`, `BH_PROCEED`, `BH_REPORT_DIR` | **S3a** only (MUST NOT S1/S2); after S3g → **S4a** |
| handoff | `BH_MODE`, `BH_HANDOFF_PATH`, `BH_START_PHASE`, `BH_REPORT_DIR` | **S4a** only (MUST NOT re-S1–S3 invent) |

---

## Step S1: Discover (compose blind path)

**Contract:** SPEC-034 M16 / M20 / **M33** — compose SPEC-013 blind-review path
with defaults; `--target` = hunt path (`BH_PATH`). **MUST NOT** fork a second
finder protocol.

**Protocol authority (cite; execute steps below with BH_* bindings):**

| Authority | Section |
|-----------|---------|
| `skills/council/SKILL.md` | § Blind-review path (`--blind`, CDT-46-C3) + Lens delta library |
| `commands/council.md` | § Blind-review path (B0–B7 dispatch + substitutions) |
| Prompts | `skills/council/prompts/unconstrained-reviewer.md`, `lens-reviewer.md`, `quorum-analyst.md` |

**Hard compose rules:**

- **MUST NOT** shell nested `/council` / `/council --blind` as a user-facing
  sub-invocation (would imply a lock / second UX). Orchestrate the same Task
  wave **in this skill**.
- **MUST NOT** re-enter tribunal Phases 1–5 on Tier-1 clusters (SEVER Tier-1
  self-recursion — blind path rule).
- **MUST NOT** invent new lens names, flavor files, or reviewer prompts.
- **MUST NOT** pause for user input before S2 (AC4 / M7).
- **MUST** bind file scope to `BH_PATH` only (AC3 / M2 / path-bound).

### 1a. Bind blind-path defaults (MVP)

MVP locks defaults (flag surface `--teams`/`--lenses` on `/bug-hunt` = SHOULD later):

```
BH_TEAMS   = 3                                    # ≡ --teams 3
BH_LENSES  = security,contributor,spec            # ≡ --lenses default
BH_TARGET  = BH_PATH                              # ≡ --target (absolute path from S0)
```

Session manifest (for REPORT / T5):

```
BH_MANIFEST = {
  teams: U1,U2,U3 (unconstrained),
  lenses: L-security, L-contributor, L-spec,
  total_reviewers: 6,                             # BH_TEAMS + |BH_LENSES|
  target: BH_PATH,
  floor: BH_FLOOR
}
```

Resolve each lens's `{{FLAVOR_DELTA}}` from `skills/council/SKILL.md` § Blind-review
path → **Lens delta library** (security / contributor / spec). Do **not** use
tribunal `skills/council/flavors/*` files for discover reviewers.

### 1b. Build path-bound file list

Re-derive roots (fresh-shell safe). Target is always `BH_PATH` (never empty /
full-project unless S0 bound path = project root).

```bash
# Re-bind roots (SPEC-021 C1). BH_PATH is a session binding from S0 — orchestrator
# injects it before this fence (cannot re-parse user args here).
_gc=$(git rev-parse --git-common-dir 2>/dev/null) \
  && MROOT=$(cd "$(dirname "$_gc")" && pwd) \
  || MROOT=$(pwd)
WTROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
# lint-ok: C1 — BH_PATH session binding from S0; orchestrator injects before fence
: "${BH_PATH:?BH_PATH session binding required (from S0)}"
[ -e "$BH_PATH" ] || { echo "error: BH_PATH missing: $BH_PATH" >&2; exit 64; }

# Path-bound file list (AC3). Prefer git-tracked under BH_PATH; fall back to find.
if [ -d "$BH_PATH" ]; then
  FILE_LIST=$(git -C "$MROOT" ls-files -- "$BH_PATH" 2>/dev/null)
  if [ -z "$FILE_LIST" ]; then
    FILE_LIST=$(find "$BH_PATH" -type f \
      ! -path '*/.git/*' ! -path '*/node_modules/*' ! -path '*/dist/*' \
      ! -path '*/vendor/*' 2>/dev/null)
  fi
else
  # Single-file scope
  FILE_LIST="$BH_PATH"
fi

SCOPE_NOTE="Bug-hunt discover — review files under: $BH_PATH only. Do not expand scope outside this path."
PROJECT_ROOT="$MROOT"
```

Print brief discover summary (orchestrator stdout):

```
S1 discover scope: $BH_PATH
Floor: $BH_FLOOR
Teams: $BH_TEAMS unconstrained + lenses [$BH_LENSES]
Total reviewers: $((BH_TEAMS + lens_count))
Files in scope: <count>
```

Empty file list (empty dir / no tracked files): continue with empty `FILE_LIST`;
reviewers may still return 0 findings; candidates may be empty — legal. Still
emit phase-done M20.

### 1c. Parallel reviewer wave (single wave — never sequential)

**CRITICAL:** spawn **all** unconstrained + lens reviewers in **one** parallel
Task wave (same message). `Output mode: terse` on every spawn.

Prefer `subagent_type: "dev-team:finder"` (CDT-230); fallback `dev-team:ic5` →
`general-purpose`. Read-only tools only (same as blind path / investigator
allowlist: Read, Grep, Glob, Bash read-only — no Write/Edit/commit).

**Model map:** resolve the agent actually spawned (`finder`; named fallback
`finder`→`ic5` resolves `ic5`). Same fence for later S1 lens / quorum `finder`
spawns of this agent. Unnamed / `general-purpose` / Explore: omit.

Before spawning @finder:
```bash
# lint-ok: C3 — marketplace */ for-loop + -f guarded (SPEC-021 Q2 residual, CDT-82 PDH)
PDH=$( { [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -f "$CLAUDE_PLUGIN_ROOT/skills/plugin-dir.sh" ] && printf '%s\n' "$CLAUDE_PLUGIN_ROOT"; } || { [ -f skills/plugin-dir.sh ] && pwd; } || { for _mp in "$HOME"/.claude/plugins/marketplaces/*/; do [ -f "${_mp}skills/plugin-dir.sh" ] && [ -f "${_mp}agents/pm.md" ] && printf '%s\n' "${_mp%/}" && break; done; } || find ~/.claude/plugins/cache -path '*/dev-team/*/skills/plugin-dir.sh' 2>/dev/null | awk -F/ '{ver=""; for(i=1;i<=NF;i++) if($i=="dev-team"&&i<NF){ver=$(i+1);break}; if(ver=="") next; m=ver; gsub(/-pre\./,"~pre.",m); p=($0 ~ /\/cache\/cold-dark-void\/dev-team\//)?1:0; print m "\t" p "\t" $0}' | sort -t $'\t' -k1,1V -k2,2n -k3,3 | tail -1 | cut -f3 | xargs -r dirname | xargs -r dirname )
RESOLVE=$(bash "$PDH/skills/plugin-dir.sh" file skills/model-map/resolve-model.sh)
MODEL=$(bash "$RESOLVE" finder)
printf '%s\n' "$MODEL"
EFFORT=$(bash "$RESOLVE" --effort finder)
printf '%s\n' "$EFFORT"
```
Bash stdout = model string; empty → omit model.
Then `resolve-model.sh --effort` (same agent). Non-empty EFFORT → pass as Agent `effort` param; empty → omit (MUST NOT pass `""`).
Surface resolver stderr to the user. Do not swallow.
If MODEL is non-empty: pass it as the Agent model param.
If MODEL is empty: omit model. MUST NOT pass "".
If spawn fails attributed to the model param (invalid/unknown/unsupported model): retry once with model omitted; warn `model-map: host rejected model '<string>' for finder; retrying with Tier default`.
If spawn fails attributed to the `effort` param (invalid/unknown/unsupported effort): retry once omitting effort; warn `model-map: host rejected effort '<token>' for finder; retrying with inherited effort`.
Model host-reject stays independent. Ambiguous failure: do not guess; do not combinatorial-retry both params.
Other spawn failures MUST NOT be retried as a model or effort fallback.

**Unconstrained** — for each index `1..BH_TEAMS` (U1..U3):

```
description: "bug-hunt S1 unconstrained U<N>"
subagent_type: "dev-team:finder"
prompt: contents of skills/council/prompts/unconstrained-reviewer.md
  with substitutions:
    {{TEAM_ID}}      ← U<N>
    {{FILE_LIST}}    ← FILE_LIST from 1b
    {{PROJECT_ROOT}} ← $MROOT
    {{SCOPE_NOTE}}   ← SCOPE_NOTE from 1b
  + trailing line: Output mode: terse
  + trailing line: Return FINDING blocks + SUMMARY as the final message.
```

**Lens** — for each lens in `BH_LENSES` (security, contributor, spec):

```
description: "bug-hunt S1 lens L-<lens>"
subagent_type: "dev-team:finder"
prompt: contents of skills/council/prompts/lens-reviewer.md
  with substitutions:
    {{TEAM_ID}}      ← L-<lens>   (e.g. L-security)
    {{LENS_NAME}}    ← <lens>
    {{FLAVOR_DELTA}} ← lens-delta paragraph from council SKILL Lens delta library
    {{FILE_LIST}}    ← FILE_LIST from 1b
    {{PROJECT_ROOT}} ← $MROOT
    {{SCOPE_NOTE}}   ← SCOPE_NOTE from 1b
  + trailing line: Output mode: terse
  + trailing line: Return FINDING blocks + SUMMARY as the final message.
```

Collect FINDING-NNN blocks + SUMMARY per team. Spawn failure on a reviewer:
record that team as 0 findings; continue (partial fleet). If the wave is
wholly unusable, orchestrator may self-verify with real tools under `BH_PATH`
only; marker exact `self-verified — refuters unavailable` when discover fleet
is degraded (actor = orchestrator; cite council § Spawn-failure degradation —
do not invent findings).

### 1d. Namespace and validate (no repair)

Mirror blind path B3:

1. Prefix every FINDING-NNN with team ID: `U1-FINDING-001`,
   `L-security-FINDING-001`, …
2. **Drop malformed** (missing Category, Severity, Files, Claim, or Evidence) —
   do **not** repair. Count → `dropped[]` with `reason=malformed`.
3. **Out-of-scope drop (AC3):** if every Files path is outside `BH_PATH` tree,
   drop with `reason=out-of-scope`. If mixed, keep only in-scope file pointers
   on the finding; if none remain, drop out-of-scope.

### 1e. Quorum analyst (clustering)

Spawn **one** quorum analyst after the reviewer wave completes. Same S1
`finder` Model map fence as §1c (do not paste full PDH again). Named fallback
`finder`→`ic5` resolves `ic5`. Unnamed / `general-purpose` / Explore: omit.

```
description: "bug-hunt S1 quorum analysis"
subagent_type: "dev-team:finder"
prompt: contents of skills/council/prompts/quorum-analyst.md
  with substitutions:
    {{ALL_FINDINGS}}         ← namespaced FINDING blocks (=== TEAM <id> === headers)
    {{TEAM_MANIFEST}}        ← BH_MANIFEST team IDs + type (unconstrained|lens)
    {{UNCONSTRAINED_TEAMS}}  ← U1,U2,U3
    {{LENS_TEAMS}}           ← L-security,L-contributor,L-spec
    {{TOTAL_TEAMS}}          ← 6
  + trailing line: Output mode: terse
  + trailing line: Return CLUSTER blocks + QUORUM-SUMMARY as the final message.
```

Collect CLUSTER-NNN (Tier 1/2/3) + QUORUM-SUMMARY. Quorum spawn failure:
fall back to mapping well-formed namespaced FINDINGS directly as Tier-3
candidates (still path/floor filtered); note degraded in session for REPORT.

### 1f. Map clusters → `candidates[]` / `dropped[]`

Apply **Finding model** map above. Orchestrator algorithm:

```
candidates = []
dropped    = []   # informational only (M15)

for each CLUSTER (Tier 1, then 2, then 3):
  locator  = first in-scope Files entry → path[:line] or symbol
  severity = normalize(Severity)   # HIGH→critical etc display map; store enum only
  if locator empty OR severity ∉ {critical,warning,nitpick}:
    dropped.append(..., reason=malformed); continue
  if locator outside BH_PATH:
    dropped.append(..., reason=out-of-scope); continue
  if severity_rank(severity) < severity_rank(BH_FLOOR):
    dropped.append(..., reason=below-floor); continue
  candidates.append({
    id, tier, locator, severity,
    description: Claim,
    evidence: Evidence + Teams + source_findings,
    status: "candidate",
    category?
  })

# Optional: well-formed FINDINGS not absorbed into any cluster → same filters,
# status=candidate, tier=3 prior.
```

Severity rank: `critical=3`, `warning=2`, `nitpick=1`. Floor compare is
**≥ floor stays** (e.g. floor=`warning` keeps critical+warning; drops nitpick).

**Invariants of the map:**

- Every `candidates[]` item has `status` exactly `candidate` and all five AC8
  field keys populated (`evidence` may be thin pre-refute — S2 deepens).
- Below-floor never in `candidates[]` (M15 / AC6).
- Out-of-scope never in `candidates[]` (AC3).
- Malformed never repaired into candidates.
- Empty `candidates[]` is legal (zero defects found / all dropped).

Do **not** write the final bug-hunt report here (T5 / REPORT). Optional side
council blind report under `.claude/council/` is **not** required; if composed
steps write one, bug-hunt report remains SoT for C2 Done.

### 1g. Phase-done discover (M20)

When `candidates[]` (possibly empty) is produced for `BH_PATH` and floor
filtering has been applied (with `dropped[]` present when any item was
filtered), print exact phase-done line and continue to S2 **without** user lock:

```
phase-done: discover — candidate set produced (M20)
  path: $BH_PATH
  floor: $BH_FLOOR
  candidates: <N>
  dropped: <M>
  manifest: U1,U2,U3 + L-security,L-contributor,L-spec
```

**MUST NOT** wait for user confirmation. Proceed immediately to **Step S2**.

### Session outputs for S2 / REPORT (T4 / T5)

| Binding | Shape |
|---------|--------|
| `candidates[]` | list of AC8-shaped objects with `status=candidate` |
| `dropped[]` | informational list (`reason` ∈ below-floor\|out-of-scope\|malformed) |
| `BH_MANIFEST` | team/lens/target/floor summary |
| `BH_DISCOVER_DEGRADED` | bool + optional note if reviewer/quorum fleet degraded |

---

## Step S2: Refute / confirm

**Contract:** SPEC-034 **M34** / **M21** / **M32** — disposition every
`candidates[]` item via ≥2 SPEC-013 investigator-pattern agents (distinct
flavors); no leftover `status=candidate`; build `confirmed_actionable[]`.

**Protocol authority (cite; execute steps below):**

| Authority | Section |
|-----------|---------|
| `skills/council/SKILL.md` | § Phase 2 — Parallel Investigation + § Spawn-failure degradation |
| `skills/council/prompts/investigator.md` | Prompt body + `{{VARS}}` + evidence-bundle JSON schema |
| `skills/council/flavors/*` | Existing flavor bodies only (no new flavor files) |

**Hard compose rules:**

- **MUST NOT** run tribunal Phases 3–5 per candidate (too heavy for multi-candidate).
- **MUST NOT** call `engine.sh` preflight/finalize for the whole hunt.
- **MUST NOT** use Workflow path (`workflow.js`) for refute.
- **MUST NOT** add new flavor files under `skills/council/flavors/`.
- **MUST NOT** pause for user input between batches or before REPORT (AC4 / M7).
- **MUST NOT** invent confirmed findings (evidence-or-silence; fail closed).
- **MUST NOT** materialize / fix / handoff during S2 (materialize is S3; handoff is S4).
- **MUST** disposition **every** candidate → `confirmed` \| `refuted` only (AC7 / M34).

### 2a. Empty-candidate fast path

If `candidates[]` is empty after S1:

```
confirmed[] = []
refuted[] = []
confirmed_actionable[] = []
BH_VERIFICATION_MODE = full   # unless S1 already set BH_DISCOVER_DEGRADED
```

Skip investigator spawns. Still emit phase-done M21 (counts all zero) and
continue to REPORT. Zero candidates is legal — not an error.

### 2b. Flavor pair selection (existing files only)

Eligible **investigator-role** flavors (stem = filename without `.md`):

| Eligible (role=investigator, Task-spawnable) | Do **not** use for S2 pairs |
|----------------------------------------------|-----------------------------|
| `paranoid-ic`, `logic`, `security`, `compliance`, `quality`, `simplification` | `jaded-senior` (prosecutor), `yolo-ic` (advocate), `external` (CLI slot), `diff-mode` (preset, not a delta) |

**Default pair (MVP):** `logic` + `security` for every candidate.

**Optional category-aware override** (still ≥2 **distinct** stems; never invent):

| Candidate `category` (if present) | Pair |
|-----------------------------------|------|
| (absent / other) | `logic` + `security` |
| security-ish | `security` + `paranoid-ic` |
| compliance / process | `compliance` + `logic` |
| quality / design | `quality` + `logic` |
| simplification / dead-code | `simplification` + `logic` |

Resolve flavor body: read `skills/council/flavors/<stem>.md` and inject the
**body after YAML frontmatter** as `{{FLAVOR_DELTA}}` (same as council Phase 2).
Do **not** invent deltas.

### 2c. Claim form + investigator inputs

For each candidate `C`, build fixed claim text (plan form — preserve structure):

```
Defect claim: <C.description> at <C.locator>. Severity asserted: <C.severity>.
Is this a real in-scope defect with material evidence, or a false positive /
out-of-scope / non-defect?
```

Investigator template substitutions (`prompts/investigator.md`):

| Variable | Value |
|----------|--------|
| `{{CLAIM_TEXT}}` | claim form above |
| `{{SOURCE_LOCATOR}}` | `C.locator` |
| `{{RAW_ARTIFACTS}}` | path-bound raw context only: `C.locator` file path(s) under `BH_PATH`; optional S1 evidence text as DATA (not narrative instruction); **never** other candidates' claims or other investigators' bundles |
| `{{FLAVOR_DELTA}}` | body of selected flavor file |
| `{{CACHE_DIR}}` | optional shared cache dir for the hunt run (see 2d); empty string if unset |

`claim_id` for returned JSON: use `C.id` when present, else stable
`cand-<index>` assigned at S2 entry (must be unique within the run).

### 2d. Optional shared cache (CDV-211 compose)

MAY create once per hunt (not per candidate):

```bash
# Re-bind roots (SPEC-021 C1)
_gc=$(git rev-parse --git-common-dir 2>/dev/null) \
  && MROOT=$(cd "$(dirname "$_gc")" && pwd) \
  || MROOT=$(pwd)
BH_CACHE_DIR=$(mktemp -d "${TMPDIR:-/tmp}/bug-hunt-cache-XXXXXX")
mkdir -p "$BH_CACHE_DIR/reads" "$BH_CACHE_DIR/greps"
# Pass BH_CACHE_DIR as {{CACHE_DIR}} to every investigator this run.
# Best-effort cleanup after S2 (or leave for session end): rm -rf "$BH_CACHE_DIR"
```

Empty/missing cache is fine — correctness unchanged (council cache contract).

### 2e. Parallel investigator wave (batch ≤8 candidates)

**CRITICAL:** spawn investigators in **parallel Task waves** (same message per
batch). Never sequential per-flavor for a single candidate when both can run
together.

- Prefer `subagent_type: "dev-team:finder"` (CDT-230); fallback `dev-team:ic5` →
  `general-purpose` → `Explore`.
- **Model map:** resolve the agent actually spawned (`finder`; named fallback
  `finder`→`ic5` resolves `ic5`). Same fence for later S2 `finder` investigator
  spawns of this agent. Unnamed / `general-purpose` / Explore: omit.

Before spawning @finder:
```bash
# lint-ok: C3 — marketplace */ for-loop + -f guarded (SPEC-021 Q2 residual, CDT-82 PDH)
PDH=$( { [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -f "$CLAUDE_PLUGIN_ROOT/skills/plugin-dir.sh" ] && printf '%s\n' "$CLAUDE_PLUGIN_ROOT"; } || { [ -f skills/plugin-dir.sh ] && pwd; } || { for _mp in "$HOME"/.claude/plugins/marketplaces/*/; do [ -f "${_mp}skills/plugin-dir.sh" ] && [ -f "${_mp}agents/pm.md" ] && printf '%s\n' "${_mp%/}" && break; done; } || find ~/.claude/plugins/cache -path '*/dev-team/*/skills/plugin-dir.sh' 2>/dev/null | awk -F/ '{ver=""; for(i=1;i<=NF;i++) if($i=="dev-team"&&i<NF){ver=$(i+1);break}; if(ver=="") next; m=ver; gsub(/-pre\./,"~pre.",m); p=($0 ~ /\/cache\/cold-dark-void\/dev-team\//)?1:0; print m "\t" p "\t" $0}' | sort -t $'\t' -k1,1V -k2,2n -k3,3 | tail -1 | cut -f3 | xargs -r dirname | xargs -r dirname )
RESOLVE=$(bash "$PDH/skills/plugin-dir.sh" file skills/model-map/resolve-model.sh)
MODEL=$(bash "$RESOLVE" finder)
printf '%s\n' "$MODEL"
EFFORT=$(bash "$RESOLVE" --effort finder)
printf '%s\n' "$EFFORT"
```
Bash stdout = model string; empty → omit model.
Then `resolve-model.sh --effort` (same agent). Non-empty EFFORT → pass as Agent `effort` param; empty → omit (MUST NOT pass `""`).
Surface resolver stderr to the user. Do not swallow.
If MODEL is non-empty: pass it as the Agent model param.
If MODEL is empty: omit model. MUST NOT pass "".
If spawn fails attributed to the model param (invalid/unknown/unsupported model): retry once with model omitted; warn `model-map: host rejected model '<string>' for finder; retrying with Tier default`.
If spawn fails attributed to the `effort` param (invalid/unknown/unsupported effort): retry once omitting effort; warn `model-map: host rejected effort '<token>' for finder; retrying with inherited effort`.
Model host-reject stays independent. Ambiguous failure: do not guess; do not combinatorial-retry both params.
Other spawn failures MUST NOT be retried as a model or effort fallback.

- Allowlist = council investigator allowlist: Read, Grep, Glob, Bash read-only
  (cache writes under `{{CACHE_DIR}}` only). **No** Write/Edit/commit on project
  tree.
- `Output mode: terse` on every spawn.
- Completion discipline: prompt MUST end with instruction to return the
  investigator JSON as the **final message**. Re-request at most twice on empty
  output before treating as spawn failure.

**Batching (cost control, M34 continuous):**

```
BATCH_CAP = 8   # candidates per wave
for each contiguous batch of ≤ BATCH_CAP candidates from candidates[]:
  spawn 2 investigators per candidate (distinct flavors) in ONE parallel wave
  # wave size = 2 × |batch|  (e.g. 16 Tasks max per wave)
  wait for wave completion
  # no user lock between batches — continue immediately
```

When `|candidates[]| ≤ 8`, a single wave covers all pairs.

**Spawn template** — for each `(candidate C, flavor F)`:

```
description: "bug-hunt S2 refute <claim_id> <flavor>"
subagent_type: "dev-team:finder"
prompt: contents of skills/council/prompts/investigator.md
  with substitutions from §2c + {{FLAVOR_DELTA}} = body of flavors/<F>.md
  + trailing line: Output mode: terse
  + trailing line: Return the single-line evidence-bundle JSON as the final message.
```

**Blindness:** each investigator sees only its claim, locator, raw artifacts,
and flavor delta — **not** other candidates, other bundles, S1 team narrative,
or disposition decisions.

Collect per `(claim_id, flavor)`: parsed JSON
`{claim_id, evidence_bundles[], reason_if_empty}` or unusable/empty.

### 2f. Validate evidence bundles (strike rule)

Mirror council Phase 2 strike (orchestrator-enforced):

Strike a bundle if any of:

1. Missing `tool_use_id`
2. Empty `raw_blob` or clearly paraphrased (no tool-output substance)
3. Missing `file_line` or `reproducible_command`
4. Blindness leak (cites other investigators / prior verdicts / narrative)

After strike, if `evidence_bundles` is empty, treat as empty return with
`reason_if_empty` preserved or set to `no evidence found`.

### 2g. Disposition rules (every candidate)

Orchestrator dispositions from **validated** evidence bundles only — never from
S1 confidence alone.

```
for each candidate C in candidates[]:   # MUST visit every item
  bundles = all non-struck evidence_bundles from both (all) flavors for C
  support = bundles that materially support the defect claim
            (raw tool output shows the claimed defect / violation at locator)
  contradict = bundles that hard-nullify the claim
               (shows code/behavior that falsifies the defect, or out-of-scope,
                or claim not reproducible at locator)

  if |support| >= 1 AND |contradict| == 0:
    status = confirmed
    evidence = merge(C.evidence, support tool cites / file_line / commands)
    # AC8 fields required on confirmed:
    #   locator, severity, description, evidence, status=confirmed
  else if |contradict| >= 1 OR clear false-positive / non-defect / out-of-scope:
    status = refuted
    evidence = merge disposition reason + contradict (or support-empty) cites
  else:
    # both sides thin / empty / unfalsifiable — FAIL CLOSED (do not invent confirmed)
    status = refuted
    evidence = "thin evidence; fail-closed refuted" + reason_if_empty notes

  # NEVER leave status=candidate
```

**Material evidence** means at least one non-struck bundle whose `raw_blob`
substantiates the defect at `locator` (tool-backed). Thin = empty bundles,
`claim not falsifiable`, or only speculative text without tool substance.

**Severity:** keep S1 `severity` on disposition (do not re-rank via investigator
confidence). Severity still ∈ {`critical`,`warning`,`nitpick`} only.

**Out-of-scope at refute:** if investigation shows locator outside `BH_PATH` or
claim is not a defect in scope → `refuted` (not a third status).

### 2h. Spawn failure / degradation (CDV-199)

**Trigger:** any required investigator Task fails or returns unusable output
(rate-limit, refusal, empty after re-requests, malformed JSON that cannot be
parsed).

**Action:**

1. Print exact marker (orchestrator stdout / session):  
   `self-verified — refuters unavailable`
2. Set `BH_REFUTE_DEGRADED=true`, `BH_VERIFICATION_MODE=self-verified`.
3. **Actor = orchestrator only** — self-verify missing roles with real read-only
   tools under `BH_PATH` (same allowlist). **Never** ship on implementer
   self-validation of code under audit.
4. Partial fleet: keep usable investigator returns; self-verify only missing
   (claim, flavor) slots.
5. Apply the **same** disposition rules (§2g) to self-verify bundles.  
   **Never invent confirmed** — if self-verify is also thin → `refuted`.
6. Record degraded banner for REPORT (T5): include the exact marker string.

If **all** investigators for a candidate are unusable **and** orchestrator
self-verify yields no material support → `refuted` (fail closed), still
dispositioned.

Protocol home: `skills/council/SKILL.md` § Spawn-failure degradation — cite;
do not invent a second marker string.

### 2i. Build output sets (AC8 / AC9 / M32)

```
confirmed[] = [ C | C.status == confirmed ]   # full AC8 fields each
refuted[]   = [ C | C.status == refuted ]     # locator + reason in evidence

confirmed_actionable[] = [
  C in confirmed[]
  where severity_rank(C.severity) >= severity_rank(BH_FLOOR)
]
# severity_rank: critical=3, warning=2, nitpick=1  (same as S1)
```

With S1 floor drop, confirmed set ⊆ ≥floor in normal runs; re-apply filter
anyway (M32 / AC9).

**AC8 fields on every `confirmed[]` item (required):**

| Field | Rule |
|-------|------|
| `locator` | non-empty stable pointer |
| `severity` | `critical` \| `warning` \| `nitpick` |
| `description` | what is wrong |
| `evidence` | deepened with investigator tool cites |
| `status` | exactly `confirmed` |

**Invariant at S2 exit:**

- No item remains `status=candidate` (scan `candidates[]` — all rewritten or
  copied into confirmed/refuted with terminal status).
- `|confirmed[]| + |refuted[]| == |candidates[]|` (1:1 disposition).
- `confirmed_actionable[] ⊆ confirmed[]`.

### 2j. Session outputs for REPORT (T5)

| Binding | Shape |
|---------|--------|
| `confirmed[]` | AC8-complete confirmed findings |
| `refuted[]` | dispositioned refuted (locator + one-line reason in evidence) |
| `confirmed_actionable[]` | confirmed ∧ severity ≥ `BH_FLOOR` (AC9 / M32) |
| `candidates[]` | same items with terminal status (no `candidate` left) |
| `dropped[]` | unchanged from S1 (informational) |
| `BH_VERIFICATION_MODE` | `full` \| `self-verified` |
| `BH_REFUTE_DEGRADED` | bool; if true, report banner MUST include exact marker |
| `BH_S2_FLAVORS` | pair(s) used (e.g. `logic+security`) for manifest |

### 2k. Phase-done refute (M21)

When every candidate is dispositioned and sets in §2i are built, print exact
phase-done line and continue to REPORT **without** user lock:

```
phase-done: refute — every candidate dispositioned (M21)
  path: $BH_PATH
  floor: $BH_FLOOR
  candidates: <N>
  confirmed: <C>
  refuted: <R>
  confirmed_actionable: <A>
  verification_mode: <full|self-verified>
```

If `BH_REFUTE_DEGRADED` (or whole-wave unusable): also print exact line:

```
self-verified — refuters unavailable
```

### 2l. Zero-actionable terminal language (AC10)

After phase-done, if `|confirmed_actionable[]| == 0`:

```
0 confirmed-actionable
```

This is a **clean success path** (exit 0 at hunt end) — not an error. Still
hand off to REPORT so T5 writes the user-visible report with counts
(`candidates`, `confirmed`, `refuted`, `dropped`, `confirmed_actionable` all
present; actionable list empty).

If `|confirmed_actionable[]| > 0`, print brief count line (optional):

```
confirmed-actionable: <A>
```

**MUST NOT** wait for user confirmation. Proceed immediately to **Step REPORT**.

### 2m. Hand-off contract (REPORT)

S2 **ends** when phase-done M21 is emitted and session bindings in §2j are set.
Proceed immediately to **Step REPORT** (mkdir/write `$BH_REPORT`). After REPORT,
continuous path continues to **S3** (plan + proceed-gated materialize) then **S4**
emit-only. Orchestrator **must not** fix or **invoke** `/orchestrate` / `/epic`
(AC9/AC12; S4 prints hints only).

**Not used in S2:** tribunal Phases 3–5; `engine.sh` whole-hunt finalize;
Workflow path; backlog materialize (S3 only); phase handoff write (S4 only).

---

## Step REPORT: User-visible artifacts

**Contract:** SPEC-034 **M31** / **M32** / M24–M25 / AC8–AC10 — emit user-visible
report under `.claude/bug-hunt/`; list `confirmed_actionable` only (confirmed ∧
severity ≥ floor); process artifacts uncommitted.

**Consumes (from S0–S2):** `BH_PATH`, `BH_FLOOR`, `BH_SLUG`, `BH_DATE`,
`BH_REPORT_DIR`, `BH_REPORT`, `BH_MANIFEST`, `BH_S2_FLAVORS`,
`candidates[]`, `dropped[]`, `confirmed[]`, `refuted[]`,
`confirmed_actionable[]`, `BH_VERIFICATION_MODE`, `BH_REFUTE_DEGRADED`,
`BH_DISCOVER_DEGRADED`, phase-done M20/M21 text, AC10 zero-actionable line.

| Artifact | Required | Path |
|----------|----------|------|
| User-visible report | MUST | `$BH_REPORT` = `$MROOT/.claude/bug-hunt/<YYYY-MM-DD>-<slug>.md` |
| Machine findings JSON | SHOULD | `$BH_FINDINGS` = `$MROOT/.claude/bug-hunt/<YYYY-MM-DD>-<slug>.json` |
| Council blind side-report | optional | existing `.claude/council/` if composed steps write one; **bug-hunt report is SoT** for C2 Done |

Templates (plugin-shipped, committed):

| File | Role |
|------|------|
| `skills/bug-hunt/templates/report.md` | User-visible body; placeholders `{{COUNTS}}`, `{{CONFIRMED_ACTIONABLE}}`, … |
| `skills/bug-hunt/templates/findings.json` | SHOULD schema example for C3 intermediate (+ optional `materialize` linkage) |
| `skills/bug-hunt/templates/findings-plan.md` | S3c findings plan; placeholders `{{HUNT_STEM}}`, `{{ACTIONABLE_TABLE}}`, … |
| `skills/bug-hunt/templates/phase-plan.md` | S4d phase index; `{{HUNT_STEM}}`, `{{PHASE_INDEX}}`, … |
| `skills/bug-hunt/templates/handoff-phase.md` | S4d per-phase handoff; AC3 fields `phase_id`…`invocation_hint` |

### R0. Ensure report dir + bind paths

```bash
# Re-bind roots (SPEC-021 C1). Session bindings from S0/S2 injected by orchestrator.
_gc=$(git rev-parse --git-common-dir 2>/dev/null) \
  && MROOT=$(cd "$(dirname "$_gc")" && pwd) \
  || MROOT=$(pwd)
# lint-ok: C1 — BH_* session bindings from S0/S2; orchestrator injects before fence
: "${BH_REPORT_DIR:?BH_REPORT_DIR required}"  # lint-ok: C1
: "${BH_REPORT:?BH_REPORT required}"  # lint-ok: C1
: "${BH_DATE:?BH_DATE required}"  # lint-ok: C1
: "${BH_SLUG:?BH_SLUG required}"  # lint-ok: C1
mkdir -p "$BH_REPORT_DIR"
BH_FINDINGS="${BH_FINDINGS:-$BH_REPORT_DIR/${BH_DATE}-${BH_SLUG}.json}"
CREATED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)
printf 'BH_REPORT=%s\nBH_FINDINGS=%s\nCREATED_AT=%s\n' \
  "$BH_REPORT" "$BH_FINDINGS" "$CREATED_AT"
```

Resolve template path via PDH when needed:

```bash
# Re-bind roots + PDH (same formula as S0 §0a — fresh-shell safe)
_gc=$(git rev-parse --git-common-dir 2>/dev/null) \
  && MROOT=$(cd "$(dirname "$_gc")" && pwd) \
  || MROOT=$(pwd)
# lint-ok: C3 — marketplace */ for-loop + -f guarded (SPEC-021 Q2 residual, CDT-82 PDH)
PDH=$( { [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -f "$CLAUDE_PLUGIN_ROOT/skills/plugin-dir.sh" ] && printf '%s\n' "$CLAUDE_PLUGIN_ROOT"; } || { [ -f skills/plugin-dir.sh ] && pwd; } || { for _mp in "$HOME"/.claude/plugins/marketplaces/*/; do [ -f "${_mp}skills/plugin-dir.sh" ] && [ -f "${_mp}agents/pm.md" ] && printf '%s\n' "${_mp%/}" && break; done; } || find ~/.claude/plugins/cache -path '*/dev-team/*/skills/plugin-dir.sh' 2>/dev/null | awk -F/ '{ver=""; for(i=1;i<=NF;i++) if($i=="dev-team"&&i<NF){ver=$(i+1);break}; if(ver=="") next; m=ver; gsub(/-pre\./,"~pre.",m); p=($0 ~ /\/cache\/cold-dark-void\/dev-team\//)?1:0; print m "\t" p "\t" $0}' | sort -t $'\t' -k1,1V -k2,2n -k3,3 | tail -1 | cut -f3 | xargs -r dirname | xargs -r dirname )
BH_TMPL_REPORT=$(bash "$PDH/skills/plugin-dir.sh" file skills/bug-hunt/templates/report.md)
BH_TMPL_JSON=$(bash "$PDH/skills/plugin-dir.sh" file skills/bug-hunt/templates/findings.json)
```

### R1. Build fill values

| Placeholder | Value |
|-------------|--------|
| `{{PATH}}` | `BH_PATH` |
| `{{FLOOR}}` | `BH_FLOOR` |
| `{{SLUG}}` | `BH_SLUG` |
| `{{DATE}}` | `BH_DATE` |
| `{{CREATED_AT}}` | ISO-8601 UTC from R0 |
| `{{MANIFEST}}` | `BH_MANIFEST` one-line (teams + lenses + target + floor) |
| `{{S2_FLAVORS}}` | `BH_S2_FLAVORS` (default `logic+security` if unset and candidates empty) |
| `{{VERIFICATION_MODE}}` | `BH_VERIFICATION_MODE` (`full` \| `self-verified`) |
| `{{DEGRADED_BANNER}}` | if `BH_REFUTE_DEGRADED` or mode=`self-verified` or `BH_DISCOVER_DEGRADED`: blockquote `> **self-verified — refuters unavailable**`; else empty |
| `{{COUNTS}}` | multiline list (see below) |
| `{{CONFIRMED_ACTIONABLE}}` | AC8 blocks or `(none)` |
| `{{REFUTED_SUMMARY}}` | bullets or `(none)` |
| `{{DROPPED_SUMMARY}}` | bullets or `(none)` |
| `{{PHASE_DONE_M20}}` | exact S1 §1g phase-done block (session text) |
| `{{PHASE_DONE_M21}}` | exact S2 §2k phase-done block (session text) |
| `{{ZERO_ACTIONABLE_LINE}}` | `0 confirmed-actionable` when A==0; else `confirmed-actionable: <A>` (optional) |
| `{{REPORT_PATH}}` | `BH_REPORT` |
| `{{FINDINGS_JSON_PATH}}` | `BH_FINDINGS` if written; else `not written` |

**`{{COUNTS}}` exact shape (all five keys required):**

```
- candidates: <N>
- confirmed: <C>
- refuted: <R>
- dropped: <D>
- confirmed_actionable: <A>
```

Where `N=|candidates[]|` (pre-disposition count from S1; equals `|confirmed|+|refuted|`),
`C=|confirmed[]|`, `R=|refuted[]|`, `D=|dropped[]|`, `A=|confirmed_actionable[]|`.

**`{{CONFIRMED_ACTIONABLE}}` — full AC8 per item (M32 / AC8):**

```
### <id or index>
- **locator:** <non-empty>
- **severity:** critical|warning|nitpick
- **description:** <what is wrong>
- **evidence:** <investigator-backed>
- **status:** confirmed
```

When `A == 0`: set body to `(none)` and `{{ZERO_ACTIONABLE_LINE}}` to exact
`0 confirmed-actionable` (clean success — not an error; AC10).

**`{{REFUTED_SUMMARY}}`:** one bullet per refuted item:

```
- `<locator>` — <one-line reason from evidence>
```

**`{{DROPPED_SUMMARY}}`:** one bullet per dropped item:

```
- `<locator>` (`<reason>`) — <detail>
```

### R2. Write user-visible report (MUST)

1. Read `templates/report.md` (via `$BH_TMPL_REPORT`).
2. Substitute every `{{…}}` placeholder from R1 (leave no bare `{{` in output).
3. **Write** the filled markdown to `$BH_REPORT` with the **Write tool**.
   - **MUST NOT** use bash heredoc with `!` (zsh history expansion; skill-lint C2).
   - **MUST NOT** `git add` / commit the report (process artifact; M25).

### R3. Write findings JSON (SHOULD — C3 handoff)

1. Prefer schema shape in `templates/findings.json`.
2. Populate live arrays: `confirmed_actionable`, `confirmed`, `refuted`, `dropped`,
   `counts`, `manifest`, `path`, `severity_floor`, `verification_mode`, `phase_done`.
3. Write JSON to `$BH_FINDINGS` with the **Write tool** (same no-heredoc rule).
4. If Write fails or JSON omitted: set `{{FINDINGS_JSON_PATH}}` / session note to
   `not written` — report `.md` alone still satisfies M31 MUST.

### R4. Terminal summary + continue to S3

Print (stdout / user-visible):

```
Report: $BH_REPORT
counts: candidates=<N> confirmed=<C> refuted=<R> dropped=<D> confirmed_actionable=<A>
verification_mode: <full|self-verified>
```

If `A == 0`, also print exact:

```
0 confirmed-actionable
```

If degraded, also print exact:

```
self-verified — refuters unavailable
```

**Stages 1–2 report done.** Continuous path continues immediately to **S3a**
(OQ5). Resume entry already lands at S3a (no re-REPORT). Exit 0 even when A==0
at report time; S3 zero-path may still emit plan + M22 zeros (AC10).

**MUST NOT at REPORT boundary:**

- auto-materialize backlog without S3 plan + M8 proceed (AC4; M8)
- fix / implement / **invoke** `/orchestrate` / `/epic` (AC9/AC12; S4 is emit-only later)
- invent severity taxonomy or ticket lifecycle
- re-enter S1/S2

### R5. Session outputs (post-REPORT)

| Binding | Shape |
|---------|--------|
| `BH_REPORT` | absolute path written (MUST) |
| `BH_FINDINGS` | absolute path if SHOULD JSON written; else unset / `not written` |
| `BH_PLAN` | path string `$BH_REPORT_DIR/${BH_STEM}-plan.md` (bound; written in S3c) |
| `BH_PROCEED` | `none` \| `flag` (from S0; token set in S3d) |
| counts | five keys as in `{{COUNTS}}` |
| `confirmed_actionable[]` | unchanged from S2 (report listed them) |

---

## Step S3: Findings plan + materialize (CDT-138 / C3)

**Contract:** SPEC-034 **M8** / **M14** / **M22** / **M38–M41** (CDT-138) — load
report artifacts → filter actionable → write findings plan → M8 proceed →
materialize bh-quality backlog via SPEC-009 programmatic write-back → link plan
↔ items → phase-done M22 → continuous **S4a** (emit-only). **MUST NOT invoke**
engines / fix / re-S1–S2 invent.

**Compose (cite; do not fork):** `skills/backlog/SKILL.md` § Programmatic write-back.

**Entry:** continuous after REPORT, or resume `materialize <path>` from S0.

### S3a LOAD (AC1 / M38)

**Contract:** Prefer machine `findings.json`; fall back to stages 1–2 `report.md`;
**loud fail** if both missing/unreadable (exit **64**). Resolve stem → bind
`BH_STEM` / `BH_PLAN` / `BH_FINDINGS` / `BH_REPORT` / floor. **MUST NOT** re-run
S1 discover or S2 refute (AC12 / OQ5) — artifacts only.

#### 3a.0 Entry modes

| Mode | Source | Inputs already held |
|------|--------|---------------------|
| continuous | post-REPORT same session | `BH_FINDINGS`, `BH_REPORT`, `BH_STEM`, `BH_DATE`, `BH_SLUG`, `BH_FLOOR`, `BH_PLAN`, `BH_PROCEED` |
| resume | S0 `BH_MODE=materialize` + `BH_MAT_PATH` | `BH_MAT_PATH`, `BH_FLOOR` (CLI default `nitpick` or override), `BH_PROCEED`, `BH_REPORT_DIR` |

Continuous: if session still holds in-memory `confirmed[]` / `confirmed_actionable[]`
from S2 **and** `$BH_FINDINGS` or `$BH_REPORT` is readable, prefer the written
artifact for S3 filter (single SoT); fall back to session arrays only when both
files are unreadable **and** session sets exist (same-session continuous). Resume
**never** uses S1/S2 session memory — files only.

#### 3a.1–3a.3 One fence: resolve stem + prefer json → report → loud fail

Self-contained bash (fresh-shell safe). Orchestrator injects session bindings
before the fence: `BH_MODE`, `BH_FLOOR`, and either continuous paths
(`BH_STEM`/`BH_REPORT`/…) or resume `BH_MAT_PATH`. Optional: `BH_HAS_S2_SETS=1`
(continuous session fallback), `BH_FLOOR_FROM_CLI=1` when `--severity-floor` was
passed (keeps CLI floor over artifact).

Load priority:

| Priority | Condition | Action |
|----------|-----------|--------|
| 1 | `$BH_FINDINGS` readable | Parse JSON → `source_findings` |
| 2 | `$BH_REPORT` readable | Parse report YAML + Confirmed actionable AC8 |
| 3 | continuous + `BH_HAS_S2_SETS` | Session `confirmed[]` / `confirmed_actionable[]` |
| fail | none | exit **64** + Usage |

Exact fail stderr (then Usage; exit **64**):

```
error: no findings.json or report.md at <stem>
  looked for: <BH_FINDINGS>
              <BH_REPORT>
```

```
error: materialize path not readable: <path>
```

```
error: materialize path must end in .json, .md, or -plan.md: <path>
```

```bash
# S3a load fence — re-bind roots (SPEC-021 C1). Session bindings injected by orchestrator.
_gc=$(git rev-parse --git-common-dir 2>/dev/null) \
  && MROOT=$(cd "$(dirname "$_gc")" && pwd) \
  || MROOT=$(pwd)
WTROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
BH_REPORT_DIR="${BH_REPORT_DIR:-$MROOT/.claude/bug-hunt}"
BH_USAGE='Usage: /bug-hunt [path] [--severity-floor <critical|warning|nitpick>] [--proceed]
Usage: /bug-hunt materialize <report|json|plan-path> [--severity-floor <critical|warning|nitpick>] [--proceed]'
# lint-ok: C1 — BH_MODE / BH_FLOOR / BH_MAT_PATH / continuous paths from S0|REPORT; orchestrator injects
: "${BH_MODE:?BH_MODE required (continuous|materialize)}"  # lint-ok: C1
: "${BH_FLOOR:?BH_FLOOR required}"  # lint-ok: C1
BH_FLOOR_CLI="$BH_FLOOR"
BH_MAT_ABS=""
BH_LOAD_KIND=""
BH_LOAD_SRC=""

if [ "$BH_MODE" = "materialize" ]; then
  : "${BH_MAT_PATH:?BH_MAT_PATH required in materialize mode}"  # lint-ok: C1
  case "$BH_MAT_PATH" in
    /*) BH_MAT_ABS="$BH_MAT_PATH" ;;
    *)  BH_MAT_ABS="$MROOT/$BH_MAT_PATH"
        [ -e "$BH_MAT_ABS" ] || BH_MAT_ABS="$WTROOT/$BH_MAT_PATH"
        ;;
  esac
  if [ -e "$BH_MAT_ABS" ]; then
    _bh_d=$(CDPATH= cd -- "$(dirname -- "$BH_MAT_ABS")" && pwd) || _bh_d=""
    [ -n "$_bh_d" ] && BH_MAT_ABS="$_bh_d/$(basename -- "$BH_MAT_ABS")"
  fi
  BH_MAT_BASE=$(basename -- "$BH_MAT_ABS")
  BH_MAT_DIR=$(dirname -- "$BH_MAT_ABS")

  case "$BH_MAT_BASE" in
    *-plan.md)
      BH_STEM="${BH_MAT_BASE%-plan.md}"
      BH_PLAN="$BH_MAT_ABS"
      BH_FINDINGS="$BH_MAT_DIR/${BH_STEM}.json"
      BH_REPORT="$BH_MAT_DIR/${BH_STEM}.md"
      BH_LOAD_KIND="plan"
      ;;
    *.json)
      BH_STEM="${BH_MAT_BASE%.json}"
      BH_FINDINGS="$BH_MAT_ABS"
      BH_REPORT="$BH_MAT_DIR/${BH_STEM}.md"
      BH_PLAN="$BH_MAT_DIR/${BH_STEM}-plan.md"
      BH_LOAD_KIND="json"
      ;;
    *.md)
      BH_STEM="${BH_MAT_BASE%.md}"
      BH_REPORT="$BH_MAT_ABS"
      BH_FINDINGS="$BH_MAT_DIR/${BH_STEM}.json"
      BH_PLAN="$BH_MAT_DIR/${BH_STEM}-plan.md"
      BH_LOAD_KIND="report"
      ;;
    *)
      echo "error: materialize path must end in .json, .md, or -plan.md: $BH_MAT_PATH" >&2
      echo "$BH_USAGE" >&2
      exit 64
      ;;
  esac

  case "$BH_STEM" in
    [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]-*)
      BH_DATE=$(printf '%s\n' "$BH_STEM" | cut -d- -f1-3)
      BH_SLUG="${BH_STEM#"$BH_DATE"-}"
      ;;
    *)
      BH_DATE=""
      BH_SLUG="$BH_STEM"
      ;;
  esac
  BH_REPORT_DIR="$BH_MAT_DIR"
else
  # Continuous: paths already bound in S0 / REPORT (session inject)
  : "${BH_STEM:?BH_STEM required in continuous mode}"  # lint-ok: C1
  : "${BH_REPORT:?BH_REPORT required in continuous mode}"  # lint-ok: C1
  BH_FINDINGS="${BH_FINDINGS:-$BH_REPORT_DIR/${BH_STEM}.json}"  # lint-ok: C1
  BH_PLAN="${BH_PLAN:-$BH_REPORT_DIR/${BH_STEM}-plan.md}"  # lint-ok: C1
  BH_LOAD_KIND="continuous"
fi

# Prefer findings.json → report.md → session (continuous only) → loud fail
if [ -n "${BH_FINDINGS:-}" ] && [ -f "$BH_FINDINGS" ] && [ -r "$BH_FINDINGS" ]; then
  BH_LOAD_SRC="json"
elif [ -n "${BH_REPORT:-}" ] && [ -f "$BH_REPORT" ] && [ -r "$BH_REPORT" ]; then
  BH_LOAD_SRC="report"
elif [ "$BH_MODE" = "continuous" ] && [ -n "${BH_HAS_S2_SETS:-}" ]; then
  # lint-ok: C1 — BH_HAS_S2_SETS optional session flag from S2
  BH_LOAD_SRC="session"
else
  if [ "$BH_MODE" = "materialize" ] && [ ! -e "$BH_MAT_ABS" ]; then
    echo "error: materialize path not readable: ${BH_MAT_ABS:-$BH_MAT_PATH}" >&2
  else
    echo "error: no findings.json or report.md at ${BH_STEM:-unknown}" >&2
    echo "  looked for: ${BH_FINDINGS:-"(unset)"}" >&2
    echo "              ${BH_REPORT:-"(unset)"}" >&2
  fi
  echo "$BH_USAGE" >&2
  exit 64
fi

# Plan-only resume without sibling json/report → same loud fail (primary inputs
# missing). T4 MAY parse actionable rows from an existing plan for OQ3 re-run;
# T2 requires findings or report for first load.
printf 'BH_STEM=%s\nBH_PLAN=%s\nBH_FINDINGS=%s\nBH_REPORT=%s\n' \
  "$BH_STEM" "$BH_PLAN" "$BH_FINDINGS" "$BH_REPORT"
printf 'BH_LOAD_KIND=%s\nBH_LOAD_SRC=%s\nBH_FLOOR=%s\nBH_FLOOR_CLI=%s\n' \
  "$BH_LOAD_KIND" "$BH_LOAD_SRC" "$BH_FLOOR" "$BH_FLOOR_CLI"
```

#### 3a.4 Parse loaded source → confirmed set + artifact floor

**JSON (`templates/findings.json` shape):**

| Field | Use |
|-------|-----|
| `confirmed` | preferred full confirmed set (status may be mixed if present) |
| `confirmed_actionable` | if `confirmed` empty/absent, use this list still **re-filter by floor** (AC2) |
| `severity_floor` | artifact floor default when CLI did not pass `--severity-floor` |
| `slug` / `date` | re-bind `BH_SLUG` / `BH_DATE` when missing |
| `path` | optional `BH_PATH` restore on resume |

Parse algorithm (orchestrator; jq optional):

```
source_findings = []
if BH_LOAD_SRC == json:
  doc = Read(BH_FINDINGS) → parse JSON
  if doc.confirmed is non-empty array:
    source_findings = doc.confirmed
  else if doc.confirmed_actionable is array:
    source_findings = doc.confirmed_actionable   # still re-filter in S3b
  else:
    source_findings = []   # legal zero
  artifact_floor = doc.severity_floor if ∈ {critical,warning,nitpick} else unset
  BH_SLUG = doc.slug or BH_SLUG
  BH_DATE = doc.date or BH_DATE
  BH_PATH = doc.path or BH_PATH  (resume restore; optional)

if BH_LOAD_SRC == report:
  text = Read(BH_REPORT)
  parse YAML frontmatter keys: severity_floor, slug, date, path
  artifact_floor = frontmatter.severity_floor if valid enum
  Under heading "## Confirmed actionable":
    for each ### <id> block with AC8 bullets:
      build {id, locator, severity, description, evidence, status}
      require status == confirmed (or set confirmed when missing but section is actionable)
      drop malformed (missing locator or severity ∉ enum)
  source_findings = those blocks
  # Do NOT parse Refuted / Dropped into source_findings

if BH_LOAD_SRC == session:
  source_findings = confirmed[] if non-empty else confirmed_actionable[]
  artifact_floor = BH_FLOOR (already session)
```

**Report AC8 block shape** (must match REPORT R1 / `templates/report.md`):

```
### <id or index>
- **locator:** <non-empty>
- **severity:** critical|warning|nitpick
- **description:** <text>
- **evidence:** <text>
- **status:** confirmed
```

When section body is exactly `(none)` → `source_findings = []` (zero path legal).

#### 3a.5 Re-bind floor (artifact default; CLI override)

```
if user passed --severity-floor on this invocation:
  BH_FLOOR = CLI value (already validated in S0)
else if artifact_floor is valid enum:
  BH_FLOOR = artifact_floor
else:
  BH_FLOOR = nitpick   # final default (M3)
```

Invalid artifact floor string → ignore (do not exit 64); fall through to
`nitpick` unless CLI set. Invalid **CLI** floor already failed in S0.

Re-bind plan path after stem finalization:

```
BH_PLAN = $BH_REPORT_DIR/${BH_STEM}-plan.md   # unless BH_LOAD_KIND=plan already absolute
```

Session bindings after S3a success:

| Binding | Value |
|---------|--------|
| `BH_STEM` | `<date>-<slug>` |
| `BH_DATE` / `BH_SLUG` | from stem or artifact |
| `BH_FINDINGS` / `BH_REPORT` / `BH_PLAN` | absolute paths (plan may not exist yet) |
| `BH_FLOOR` | re-applied floor for S3b |
| `BH_LOAD_SRC` | `json` \| `report` \| `session` |
| `source_findings[]` | raw list pre-filter (may include below-floor / non-confirmed) |
| `BH_PROCEED` | unchanged from S0 (`none` \| `flag`) |

Print brief load line:

```
S3a load: src=$BH_LOAD_SRC stem=$BH_STEM floor=$BH_FLOOR findings=${#source_findings}
```

**MUST NOT** after S3a: enter S1, enter S2, invent findings, fix, invoke engines.

### S3b FILTER (AC2 / M14 re-apply)

**Contract:** Actionable = `status=confirmed` **and** severity ≥ `BH_FLOOR`.
Re-apply floor even when source was `confirmed_actionable` (AC2 / M32 / M38).
Never materialize `refuted`, `dropped`, or below-floor.

#### 3b.1 Rank table

```
severity_rank:
  critical = 3
  warning  = 2
  nitpick  = 1
  (other / missing) = 0  → drop (malformed; not actionable)
```

Floor compare: keep when `rank(f.severity) >= rank(BH_FLOOR)`.

#### 3b.2 Build `BH_ACTIONABLE[]`

```
BH_ACTIONABLE = []
for f in source_findings:
  # Normalize status: json may omit status on confirmed_actionable entries
  st = f.status if set else "confirmed"   # only when loaded from confirmed* arrays
  if st != "confirmed":
    continue   # refuted / candidate / other — never actionable
  sev = f.severity
  if sev ∉ {critical, warning, nitpick}:
    continue   # malformed drop (do not materialize)
  if severity_rank(sev) < severity_rank(BH_FLOOR):
    continue   # below-floor
  if f.locator is empty:
    continue   # AC8 require non-empty locator
  BH_ACTIONABLE.append({
    id: f.id or "finding-<index>",
    locator: f.locator,
    severity: sev,
    description: f.description or "",
    evidence: f.evidence or "",
    status: "confirmed"
  })

BH_MAT_A = |BH_ACTIONABLE|
BH_MAT_M = 0
BH_MAT_S = 0
BH_MAT_F = 0
```

Aliases (same list): `actionable[]` ≡ `BH_ACTIONABLE[]`.

**Invariant:** `BH_ACTIONABLE[] ⊆ confirmed-status findings` and every item
severity ≥ floor. Empty list is legal.

Print:

```
S3b filter: actionable=$BH_MAT_A floor=$BH_FLOOR
```

#### 3b.3 Zero path (AC10 / M41)

When `BH_MAT_A == 0`:

1. Print exact terminal line:

```
0 confirmed-actionable
```

2. Counts stay zero: `BH_MAT_A=0`, `BH_MAT_M=0`, `BH_MAT_S=0`, `BH_MAT_F=0`.
3. **Continue to S3c** — write empty/minimal findings plan (resume identity; T3).
4. **S3d:** skip proceed lock (no token required when A==0).
5. **S3e:** **zero** backlog creates (MUST NOT call programmatic write-back).
6. **S3g:** clean M22 zero language (full multi-line form; §3g.3):

```
0 confirmed-actionable
phase-done: materialize — 0 creates (M22)
  plan: $BH_PLAN
  proceed: none
  actionable: 0
  materialized: 0
  skipped_linked: 0
  failed: 0
  linear_failopen: 0
```

Short form also accepted when plan write deferred (T3 not yet run in partial
impl) — minimum exact lines:

```
0 confirmed-actionable
phase-done: materialize — 0 creates (M22)
```

7. After S3g → continuous **S4a** (emit-only). MUST NOT fix / invoke engines / re-S1 / re-S2 / invent backlog.

When `BH_MAT_A > 0`: continue S3c → S3d (proceed required) → S3e–S3g (T3/T4).

#### 3b.4 Session outputs for S3c+

| Binding | Shape |
|---------|--------|
| `BH_ACTIONABLE[]` | confirmed ∧ ≥floor; AC8 fields each |
| `BH_MAT_A` | integer count (`\|BH_ACTIONABLE\|`) |
| `BH_MAT_M` / `BH_MAT_S` / `BH_MAT_F` | `0` until S3e (T4) |
| `BH_STEM` / `BH_PLAN` / `BH_FLOOR` / `BH_LOAD_SRC` | from S3a |
| `BH_PROCEED` | from S0 (`none` \| `flag`; token later) |

**MUST NOT** in S3b: create backlog items, write plan (S3c), re-enter S1/S2,
change severity taxonomy.

### S3c PLAN WRITE (AC3 / M39)

**Contract:** Write findings plan at exact path **before** any backlog create
(S3e) and **before** proceed lock (S3d). Plan is a reviewable artifact — allowed
without M8. Use the **Write tool** only (no bash heredoc with `!` — skill-lint C2).

```
$BH_PLAN = $BH_REPORT_DIR/${BH_STEM}-plan.md
         = $MROOT/.claude/bug-hunt/<YYYY-MM-DD>-<slug>-plan.md
```

Template (plugin-shipped): `skills/bug-hunt/templates/findings-plan.md`.

#### 3c.0 Preconditions

| Binding | Required |
|---------|----------|
| `BH_STEM` | from S3a |
| `BH_PLAN` | absolute path string (may not exist yet) |
| `BH_ACTIONABLE[]` / `BH_MAT_A` | from S3b (may be empty) |
| `BH_FLOOR` | re-applied floor |
| `BH_REPORT` / `BH_FINDINGS` | artifact paths (findings may be `not written`) |

**MUST NOT** in S3c: call programmatic write-back, fix/invoke engines, re-S1/S2, require proceed.

#### 3c.1 Resolve template + ensure dir

```bash
# Re-bind roots + PDH (SPEC-021 C1). Session bindings injected by orchestrator.
_gc=$(git rev-parse --git-common-dir 2>/dev/null) \
  && MROOT=$(cd "$(dirname "$_gc")" && pwd) \
  || MROOT=$(pwd)
# lint-ok: C3 — marketplace */ for-loop + -f guarded (SPEC-021 Q2 residual, CDT-82 PDH)
PDH=$( { [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -f "$CLAUDE_PLUGIN_ROOT/skills/plugin-dir.sh" ] && printf '%s\n' "$CLAUDE_PLUGIN_ROOT"; } || { [ -f skills/plugin-dir.sh ] && pwd; } || { for _mp in "$HOME"/.claude/plugins/marketplaces/*/; do [ -f "${_mp}skills/plugin-dir.sh" ] && [ -f "${_mp}agents/pm.md" ] && printf '%s\n' "${_mp%/}" && break; done; } || find ~/.claude/plugins/cache -path '*/dev-team/*/skills/plugin-dir.sh' 2>/dev/null | awk -F/ '{ver=""; for(i=1;i<=NF;i++) if($i=="dev-team"&&i<NF){ver=$(i+1);break}; if(ver=="") next; m=ver; gsub(/-pre\./,"~pre.",m); p=($0 ~ /\/cache\/cold-dark-void\/dev-team\//)?1:0; print m "\t" p "\t" $0}' | sort -t $'\t' -k1,1V -k2,2n -k3,3 | tail -1 | cut -f3 | xargs -r dirname | xargs -r dirname )
# lint-ok: C1 — BH_PLAN / BH_STEM / BH_REPORT_DIR from S3a; orchestrator injects
: "${BH_PLAN:?BH_PLAN required}"  # lint-ok: C1
: "${BH_STEM:?BH_STEM required}"  # lint-ok: C1
BH_REPORT_DIR="${BH_REPORT_DIR:-$(dirname -- "$BH_PLAN")}"  # lint-ok: C1
mkdir -p "$BH_REPORT_DIR"
BH_TMPL_PLAN=$(bash "$PDH/skills/plugin-dir.sh" file skills/bug-hunt/templates/findings-plan.md)
[ -n "$BH_TMPL_PLAN" ] && [ -f "$BH_TMPL_PLAN" ] || {
  echo "error: could not resolve skills/bug-hunt/templates/findings-plan.md" >&2
  exit 1
}
CREATED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)
printf 'BH_PLAN=%s\nBH_TMPL_PLAN=%s\nCREATED_AT=%s\n' \
  "$BH_PLAN" "$BH_TMPL_PLAN" "$CREATED_AT"
```

#### 3c.2 Build fill values

| Placeholder | Value |
|-------------|--------|
| `{{HUNT_STEM}}` | `BH_STEM` (`<date>-<slug>`) |
| `{{REPORT_PATH}}` | `BH_REPORT` absolute (or sibling path from S3a) |
| `{{FINDINGS_JSON_PATH}}` | `BH_FINDINGS` if file exists; else `not written` |
| `{{FLOOR}}` | `BH_FLOOR` |
| `{{CREATED_AT}}` | ISO-8601 UTC from 3c.1 |
| `{{PROCEED}}` | always `pending` on first S3c write (S3d rewrites after lock) |
| `{{ACTIONABLE_TABLE}}` | table rows from §3c.3 |
| `{{COUNT_A}}` | `BH_MAT_A` |
| `{{COUNT_M}}` | `BH_MAT_M` (0 pre-S3e) |
| `{{COUNT_S}}` | `BH_MAT_S` (0 pre-S3e) |
| `{{COUNT_F}}` | `BH_MAT_F` (0 pre-S3e) |
| `{{PHASE_DONE}}` | `(pending S3g)` — S3g overwrites with M22 block |
| `{{EVIDENCE_SECTIONS}}` | optional full evidence (§3c.3); else empty |

#### 3c.3 Actionable table rows (AC8 + linkage columns)

For each item in `BH_ACTIONABLE[]` (order preserved), emit **one** markdown table row:

```
| <id> | <severity> | <locator> | <description> | <evidence> | (pending) | (pending) | planned |
```

| Column | Rule |
|--------|------|
| `finding_id` | `id` (or `finding-<index>`) |
| `severity` | `critical` \| `warning` \| `nitpick` |
| `locator` | non-empty AC8 pointer |
| `description` | what is wrong (escape `\|` in cells) |
| `evidence` | full substance preferred; never invent |
| `backlog_slug` | `(pending)` until S3e/S3f |
| `linear_id` | `(pending)` until S3e/S3f |
| `status` | `planned` pre-proceed (S3f: `materialized` \| `skipped_linked` \| `failed`) |

**Evidence:** if table width forces truncation, put full text in
`{{EVIDENCE_SECTIONS}}` under `## Evidence detail` / `### <finding_id>` —
**never** leave evidence empty when the finding will materialize (AC6).

**Zero actionable (`BH_MAT_A == 0` — AC10):** still write the plan (resume identity).
Set `{{ACTIONABLE_TABLE}}` to a single empty-state line under the table header
(not zero file omission):

```
(none — 0 confirmed-actionable)
```

Counts all zero. `{{PROCEED}}` remains `pending` (S3d skips lock when A==0).

**Re-materialize path:** if `$BH_PLAN` already exists and has non-`(pending)`
linkage for some rows, T4/OQ3 owns skip/link merge — S3c **MAY** overwrite with a
fresh planned table from current `BH_ACTIONABLE[]` **or** preserve existing
linkage rows when loading `-plan.md` resume (prefer preserve when
`BH_LOAD_KIND=plan` and rows already linked; otherwise rewrite from filter).

#### 3c.4 Write plan (MUST)

1. Read `$BH_TMPL_PLAN` (`templates/findings-plan.md`).
2. Substitute every `{{…}}` placeholder (leave no bare `{{` in output).
3. **Write** filled markdown to `$BH_PLAN` with the **Write tool**.
   - **MUST NOT** bash heredoc with `!` (zsh history expansion; skill-lint C2).
   - **MUST NOT** `git add` / commit (process artifact; M25; `.gitignore` → `.claude/bug-hunt/`).
4. Print:

```
S3c plan: $BH_PLAN
  actionable: $BH_MAT_A
  proceed: pending
```

#### 3c.5 Session outputs for S3d+

| Binding | Shape |
|---------|--------|
| `BH_PLAN` | absolute path **written** |
| `BH_ACTIONABLE[]` | unchanged (linkage still pending) |
| `BH_MAT_*` | A set; M/S/F still 0 until S3e |
| plan frontmatter `proceed` | `pending` |

**Next:**

| Condition | Step |
|-----------|------|
| `BH_MAT_A == 0` | S3d skip lock → S3e zero creates → S3g M22 zeros (AC10) |
| `BH_MAT_A > 0` | **S3d** proceed lock (T4) — plan-only success if neither flag nor token |

**MUST NOT** after S3c without S3d success: create backlog items.

### S3d PROCEED LOCK (AC4 / M8 / OQ2 / M41)

**Contract:** Gate **S3e only**. Plan write (S3c) is already done and allowed
without M8. **Zero** backlog creates until this lock succeeds. **MUST NOT**
auto-materialize.

#### 3d.1 Zero-actionable skip (AC10)

When `BH_MAT_A == 0`:

1. Do **not** prompt; do **not** require `--proceed` or typed token.
2. Leave `BH_PROCEED` as-is (typically `none`); plan frontmatter may stay
   `proceed: pending` or be set to `none` — either is fine (no materialize).
3. Skip to **S3e** zero path (no write-back calls) → **S3g** M22 zeros.
4. **MUST NOT** create backlog items.

#### 3d.2 Accept forms (both documented)

| Input | Detect | Effect |
|-------|--------|--------|
| `--proceed` flag | `BH_PROCEED=flag` from S0 | Record proceed; continue S3e |
| Typed token | User reply exact `proceed` (case-insensitive; trim whitespace) | Set `BH_PROCEED=token`; record; continue S3e |
| Neither (A>0) | `BH_PROCEED=none` and no valid token | **STOP** plan-only; **0** backlog creates; exit **0** |

Both forms satisfy M8. Flag skips the interactive prompt when already bound
from the invocation (`/bug-hunt … --proceed` or
`/bug-hunt materialize <path> --proceed`).

#### 3d.3 Interactive prompt (when A>0 and BH_PROCEED=none)

Print exactly (then wait for one user turn):

```
Findings plan written (review before materialize):
  plan: $BH_PLAN
  actionable: $BH_MAT_A

Awaiting proceed: re-run with --proceed or type proceed
```

Accept **only** the token `proceed` (case-insensitive). Any other reply
(including empty, `yes`, `y`, `go`, `continue`) is **not** proceed:

```
Proceed not recorded (got: <reply>). Plan kept; zero backlog creates.
Awaiting proceed: re-run with --proceed or type proceed
  plan: $BH_PLAN
```

Then **exit 0** (plan-only success). **MUST NOT** call programmatic write-back.

#### 3d.4 Record proceed on plan

On success (`flag` or `token`), bind ISO timestamp and rewrite plan frontmatter
`proceed:` via the **Write tool** (re-read plan → substitute → Write; no bash
heredoc with `!`):

```
BH_PROCEED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)
# form = flag | token
proceed: recorded (<form> @ $BH_PROCEED_AT)
```

Also update session:

| Binding | Value |
|---------|--------|
| `BH_PROCEED` | `flag` \| `token` |
| `BH_PROCEED_AT` | ISO-8601 UTC |
| plan YAML `proceed` | `recorded (flag @ …)` or `recorded (token @ …)` |

Print:

```
S3d proceed: recorded ($BH_PROCEED @ $BH_PROCEED_AT)
  plan: $BH_PLAN
```

#### 3d.5 Plan-only stop (neither form; A>0)

When lock fails / neither form:

1. **Zero** backlog creates (do not enter S3e materialize loop).
2. Leave plan rows `status=planned`, linkage `(pending)`.
3. Print:

```
S3d plan-only: materialize deferred
  plan: $BH_PLAN
  actionable: $BH_MAT_A
  backlog_creates: 0
Awaiting proceed: re-run with --proceed or type proceed
```

Resume examples:

```
/bug-hunt materialize $BH_PLAN --proceed
/bug-hunt materialize $BH_FINDINGS --proceed
```

4. **Exit 0.** **MUST NOT** S3e/S3f/S3g materialize path; **MUST NOT** fix /
   invoke engines / re-S1 / re-S2. (No S4 — plan-only never reaches S3g.)

#### 3d.6 Session outputs

| Binding | Shape |
|---------|--------|
| `BH_PROCEED` | `none` (plan-only stop or A==0) \| `flag` \| `token` |
| `BH_PROCEED_AT` | ISO when recorded; unset on plan-only |
| plan `proceed` | `pending` \| `recorded (flag\|token @ ISO)` \| `none` |

**Next:** A==0 or proceed recorded → **S3e**. Plan-only stop → **end** (exit 0).

---

### S3e MATERIALIZE (AC5–AC7 / M40 / OQ3–OQ4)

**Contract:** For each unlinked item in `BH_ACTIONABLE[]`, create a bh-quality
backlog item via **only** `skills/backlog/SKILL.md` § **Programmatic write-back**
— convention **2 Direct write**, **Linear-first** (default MCP mode; fail-open).
**MUST NOT** reimplement dual-write, index format, mkdir/printf/`add.sh`, or a
second backlog SoT (AC5 / M40). **MUST NOT** invoke `/orchestrate` / `/epic` /
fix.

**Authority (cite; do not fork):**

| Authority | Section |
|-----------|---------|
| `skills/backlog/SKILL.md` | § Programmatic write-back (non-interactive callers) |
| Same skill | `add` Steps 1 / 2 / 2a (suffix-only) / 4 / 5 / 6 / 7 |

#### 3e.0 Preconditions

| Binding | Required |
|---------|----------|
| `BH_PROCEED` | `flag` \| `token` (or A==0 zero path — skip loop) |
| `BH_ACTIONABLE[]` / `BH_MAT_A` | from S3b |
| `BH_PLAN` / `BH_STEM` | from S3c |
| `BH_MAT_M` / `BH_MAT_S` / `BH_MAT_F` | counters (start 0; may already hold skip counts on re-entry) |

If `BH_PROCEED` is still `none` **and** `BH_MAT_A > 0`: **MUST NOT** enter this
step (S3d plan-only already stopped). Hard wall.

#### 3e.1 Zero path (A==0)

```
BH_MAT_M = 0
BH_MAT_S = 0
BH_MAT_F = 0
BH_LINEAR_FAILOPEN = 0
```

**MUST NOT** call programmatic write-back. Continue **S3f** (no-op row updates)
→ **S3g**.

#### 3e.2 Idempotent skip (OQ3 / M41)

Before creating, resolve plan linkage for each finding `F` (read plan table
row for `F.id`):

| Plan state | Action | Count |
|------------|--------|-------|
| `backlog_slug` non-empty **and** ≠ `(pending)` **and** item file `$MROOT/.claude/backlog/<slug>.md` exists | **Skip** create; keep existing slug/`linear_id` | `BH_MAT_S++`; status `skipped_linked` |
| `backlog_slug` set but item file **missing** | Treat as unlinked; re-create (suffix if needed); update plan in S3f | create path |
| `backlog_slug` empty / `(pending)` | Create | create path |

Never create a second item for the same `finding_id` when already linked
(slug filled + file exists).

#### 3e.3 Content pre-supply (AC6 — bh-quality; self-contained)

Pass these fields into Programmatic write-back (Step 3 ask **skipped**):

| Field | Value |
|-------|--------|
| **title** | `[bh] <severity>: <short description ≤~60 chars>` |
| **problem** | Inline substance (required): severity + locator + description + **full evidence text**. **Forbidden:** bare `see plan`, bare plan path, or empty evidence. |
| **goal** | `Fix the defect at <locator>; evidence must no longer hold / verification check passes.` |
| **Implementation Notes / Notes** | After substance only: `hunt_stem: <BH_STEM>`; `plan_path: <BH_PLAN>`; `finding_id: <id>`; optional `report_path: <BH_REPORT>` |
| **Affects** | Locator path (file/dir); optional |

Linear description (Step 4) = same inlined problem + goal substance
(CDT-111 / SPEC-009). Local path cross-refs are **supplementary after** substance
— never a replacement.

**Problem body shape (minimum):**

```
Severity: <critical|warning|nitpick>
Locator: <path[:line] or symbol>
Finding: <id>

What is wrong:
<description>

Evidence:
<full evidence text from finding — not truncated to empty>
```

#### 3e.4 Slug algorithm (AC7 / OQ4)

Programmatic write-back owns Steps 2 + 2a (suffix-only). Caller **pre-suggests**
base slug; collision walk is mandatory (never abort):

```
base = "bh-" + kebab(finding_id if stable else first ~6 words of description)
base = lower; strip non-alnum; collapse -; trim -; max ~50 chars
if base empty → base = "bh-finding"
# Dedup (programmatic fixed (a) Suffix):
while item file OR index row exists for base:
  base = base + "-2" / "-3" / …   # append -N
use base as slug
```

`bh-` prefix is **optional-preferred** (stable hunt identity); bare kebab of
id/description is also legal if caller omits prefix — still ≤~50 + suffix walk.

#### 3e.5 Direct write loop (convention 2; Linear-first)

```
BH_MAT_M = 0
BH_MAT_S = 0
BH_MAT_F = 0
BH_LINEAR_FAILOPEN = 0
BH_SLUG_LIST = []   # materialized + skipped slugs for M22

for F in BH_ACTIONABLE[]:   # order preserved
  # --- OQ3 skip ---
  if plan_row(F).backlog_slug is filled AND item_file_exists(slug):
    BH_MAT_S += 1
    F.mat_status = skipped_linked
    F.backlog_slug = plan_row.backlog_slug
    F.linear_id = plan_row.linear_id or ""
    BH_SLUG_LIST.append(F.backlog_slug)
    continue

  # --- pre-supply title / problem / goal / notes (3e.3) ---
  # --- suggest base slug (3e.4); write-back walks -2/-3 ---

  try:
    # Cite only: skills/backlog/SKILL.md § Programmatic write-back
    # convention 2 Direct write; MCP mode = Linear-first (not --local-only)
    result = programmatic_write_back(
      title, problem, goal, notes,
      mcp_mode = linear_first
    )
    # result: slug, linear_id | none, local paths written
    F.backlog_slug = result.slug
    F.linear_id = result.linear_id or ""
    F.mat_status = materialized
    BH_MAT_M += 1
    BH_SLUG_LIST.append(F.backlog_slug)
    if result.linear_failopen:          # MCP down/error this item
      BH_LINEAR_FAILOPEN = 1
      # one-line notice (at most once per hunt unless per-item clarity needed):
      #   Linear unreachable — local backlog only.
  except hard_local_failure:            # cannot write item or index
    F.mat_status = failed
    F.backlog_slug = F.backlog_slug or ""
    F.linear_id = ""
    BH_MAT_F += 1
    # continue remaining findings — partial fail does not abort loop
    continue
```

**Partial failure rules:**

| Failure | Behavior |
|---------|----------|
| Linear MCP down / create error | Fail-open local-only + one-line notice; item still **materialized** (local); `BH_LINEAR_FAILOPEN=1`; continue |
| Local write failure (disk/permissions) | status `failed`; `BH_MAT_F++`; **continue** remaining |
| Single finding fails | Never abort whole loop |

**MUST NOT** nest `/backlog add` as a user-facing slash UX mid-hunt (convention 1
print-and-confirm is **not** used here — convention 2 Direct write only).

#### 3e.6 Item → plan reference (AC8 item→plan)

Each written item MUST carry (in frontmatter and/or Notes — prefer both when
YAML is present):

```yaml
# optional keys alongside linear_id when present:
hunt_stem: <BH_STEM>
plan_path: <BH_PLAN>
finding_id: <F.id>
```

And under `## Notes` (always, even without YAML):

```
hunt_stem: <BH_STEM>
plan_path: <BH_PLAN>
finding_id: <F.id>
```

These are **cross-refs after** problem/goal substance — not a substitute for
evidence (AC6 / CDT-111).

#### 3e.7 Session outputs for S3f

| Binding | Shape |
|---------|--------|
| `BH_ACTIONABLE[]` | each item may hold `backlog_slug`, `linear_id`, `mat_status` |
| `BH_MAT_M` / `BH_MAT_S` / `BH_MAT_F` | integers; `M+S+F == A` when every item resolved |
| `BH_LINEAR_FAILOPEN` | `0` \| `1` |
| `BH_SLUG_LIST` | list of slugs materialized or skipped |

Print brief:

```
S3e materialize: M=$BH_MAT_M S=$BH_MAT_S F=$BH_MAT_F linear_failopen=$BH_LINEAR_FAILOPEN
```

**MUST NOT** after S3e: fix, invoke engines, re-S1/S2, second dual-write path.

---

### S3f LINK BACK (AC8 plan→item)

**Contract:** Update findings plan rows with linkage from S3e; rewrite plan via
**Write tool** only. Items already reference hunt stem + plan path + finding id
(S3e §3e.6); this step is **plan → item** columns.

#### 3f.1 Row update rules

For each `BH_ACTIONABLE[]` item (and matching plan table row by `finding_id`):

| `mat_status` | `backlog_slug` | `linear_id` | `status` |
|--------------|----------------|-------------|---------|
| `materialized` | created slug | Linear id or `(none)` if local-only | `materialized` |
| `skipped_linked` | existing slug | existing or `(none)` | `skipped_linked` |
| `failed` | `(pending)` or partial | `(pending)` | `failed` |
| (A==0 / no rows) | — | — | empty-table note unchanged |

Cell rules:

- Never leave a materialized row with `backlog_slug=(pending)`.
- `linear_id` column: real id (e.g. `CDT-99`) or `(none)` when local-only /
  fail-open; never invent ids.
- Escape `|` in cells as in S3c.

#### 3f.2 Rewrite plan

1. Re-read `$BH_PLAN` (or rebuild from template + current bindings).
2. Set placeholders:
   - `{{PROCEED}}` = plan frontmatter value from S3d (`recorded (…)` or `none` / `pending` on zero path)
   - `{{ACTIONABLE_TABLE}}` = rows with filled linkage (§3f.1)
   - `{{COUNT_A}}` / `{{COUNT_M}}` / `{{COUNT_S}}` / `{{COUNT_F}}` = current counters
   - `{{PHASE_DONE}}` = `(pending S3g)` still — S3g overwrites after print, **or**
     leave for S3g single rewrite (prefer **one** final Write in S3g that includes
     both linkage table **and** M22 block; if so, S3f MAY only mutate session
     row state and defer disk write to S3g)
3. **Preferred:** S3f updates session row state; **S3g** performs the final plan
   Write with counts + phase-done + linkage together (one Write).  
   **Allowed:** S3f Write intermediate plan with linkage + counts, S3g Write
   again with `{{PHASE_DONE}}` filled.
4. **MUST NOT** bash heredoc with `!`. **MUST NOT** `git add` / commit.

Print:

```
S3f link: plan rows updated
  plan: $BH_PLAN
  linked: $((BH_MAT_M + BH_MAT_S))
  failed: $BH_MAT_F
```

#### 3f.3 Session outputs for S3g

| Binding | Shape |
|---------|--------|
| plan rows | slug + linear_id + status per finding |
| `BH_MAT_*` / `BH_LINEAR_FAILOPEN` / `BH_SLUG_LIST` | unchanged from S3e |
| `BH_PROCEED` | from S3d |

---

### S3g PHASE-DONE (M22 / AC9 / AC10)

**Contract:** Print exact phase-done, finalize plan `## Phase-done` + counts,
**stop**. Hunt stages 1–3 Done. Exit **0**.

#### 3g.1 Finalize plan (Write tool)

Update `$BH_PLAN`:

- Counts section = live `BH_MAT_A/M/S/F`
- `{{PHASE_DONE}}` / `## Phase-done` body = exact M22 block below
- Proceed frontmatter already set in S3d (zero path: `none` or `pending`)
- Linkage table final (if deferred from S3f)

#### 3g.2 Full path M22 (A>0 after proceed)

```
phase-done: materialize — findings plan + bh-quality backlog (M22)
  plan: $BH_PLAN
  proceed: <none|flag|token>
  actionable: <A>
  materialized: <M>
  skipped_linked: <S>
  failed: <F>
  linear_failopen: <0|1>
  slugs: <comma-separated BH_SLUG_LIST or (none)>
```

Bindings:

| Line | Source |
|------|--------|
| `plan` | `BH_PLAN` absolute |
| `proceed` | `BH_PROCEED` (`flag` \| `token`; zero path may print `none`) |
| `actionable` | `BH_MAT_A` |
| `materialized` | `BH_MAT_M` |
| `skipped_linked` | `BH_MAT_S` |
| `failed` | `BH_MAT_F` |
| `linear_failopen` | `BH_LINEAR_FAILOPEN` (`0` if never set) |
| `slugs` | `BH_SLUG_LIST` joined by `, ` ; or `(none)` when empty |

`slugs:` is additive observability (M22 counts remain authoritative).

#### 3g.3 Zero path M22 (AC10 / M41 — consistent with S3b §3b.3)

When `BH_MAT_A == 0`:

```
0 confirmed-actionable
phase-done: materialize — 0 creates (M22)
  plan: $BH_PLAN
  proceed: none
  actionable: 0
  materialized: 0
  skipped_linked: 0
  failed: 0
  linear_failopen: 0
```

Short form (minimum exact lines) still accepted:

```
0 confirmed-actionable
phase-done: materialize — 0 creates (M22)
```

Prefer the multi-line form when `$BH_PLAN` was written.

#### 3g.4 Terminal summary

Print M22 block (exact), then:

```
Materialize done.
  plan: $BH_PLAN
  slugs: <list or (none)>
```

If `BH_LINEAR_FAILOPEN=1`, ensure the fail-open notice was emitted at least once:

```
Linear unreachable — local backlog only.
```

#### 3g.5 Continue to S4 (CDT-139)

**Stages 1–3 Done** after M22. Continuous path → **S4a**. Resume:
`/bug-hunt handoff $BH_PLAN [--start-phase <n>]`.

**MUST NOT after S3g:**

- **invoke** `/orchestrate` / `/epic` / spawn fix (S4 emits only; AC9)
- fix / implement / code edits for findings
- re-S1 discover / re-S2 refute / invent findings
- second dual-write path / `add.sh` fork
- further backlog creates without a new user invocation + proceed

#### 3g.6 Session outputs (terminal S3 → S4)

| Binding | Final |
|---------|--------|
| `BH_PLAN` | written; linked; phase-done filled |
| `BH_MAT_A/M/S/F` | final counts |
| `BH_PROCEED` | `none` \| `flag` \| `token` |
| `BH_LINEAR_FAILOPEN` | `0` \| `1` |
| `BH_SLUG_LIST` | slugs created or skipped |
| `BH_STEM` / `BH_START_PHASE` | identity + optional arm for S4 |

---

## Step S4: Phase handoff emit-only (CDT-139 / C4)

**Contract:** SPEC-034 **M42–M48** / M9 / M18 / M23 (CDT-139) — load C3 findings
plan → severity-band phases → write phase-plan + handoff templates → M9 lock →
print `invocation_hint` → M23 phase-done. **Emit-only:** Write artifacts under
`$MROOT/.claude/bug-hunt/`; **MUST NOT invoke** `/orchestrate`, `/epic`, spawn
fix ICs, or edit product code (AC9 / N12 / OQ10).

**Entry:** continuous after S3g (same session: `BH_PLAN` / `BH_STEM`), or resume
`handoff <plan-path> [--start-phase <n>]` from S0.

**Template-first (T3):** field contracts live in
`skills/bug-hunt/templates/phase-plan.md` +
`skills/bug-hunt/templates/handoff-phase.md` — skill cites + fills; no full
template paste here.

**Hard walls (restated):** no re-S1/S2/S3 invent (N13); no dual lifecycle; no
`/debug` path; process uncommitted; no commit/version.

### S4a LOAD (AC1 / M42)

**Contract:** Load C3 findings plan (`…-plan.md`) → parse actionable table →
build `BH_PHASEABLE[]` per OQ3. **Loud fail** exit **64** when plan missing /
unreadable / not a findings plan. **MUST NOT** re-enter S1–S3 invent (N13);
**MUST NOT** invent findings.

#### 4a.0 Entry modes

| Mode | Source | Inputs already held |
|------|--------|---------------------|
| continuous | post-S3g same session | `BH_PLAN` absolute (written), `BH_STEM`, `BH_REPORT_DIR`, optional `BH_START_PHASE` |
| resume | S0 `BH_MODE=handoff` + `BH_HANDOFF_PATH` | `BH_HANDOFF_PATH`, `BH_START_PHASE`, `BH_REPORT_DIR` |

Continuous: prefer on-disk `$BH_PLAN` (single SoT after S3f/S3g). Session row
state alone is **not** enough on resume — handoff always reads the plan file.
`--severity-floor` is **ignored** at S4 (floor already applied at S3; banding
uses full severity order — OQ / M43).

#### 4a.1 Resolve plan path + stem (loud fail)

Self-contained bash (fresh-shell safe). Orchestrator injects `BH_MODE` and
either continuous `BH_PLAN`/`BH_STEM` or resume `BH_HANDOFF_PATH`.

Exact fail stderr (then Usage; exit **64**):

```
error: findings plan not readable: <path>
```

```
error: handoff path must end in -plan.md: <path>
```

```
error: continuous handoff requires BH_PLAN (missing after S3)
```

```bash
# S4a load fence — re-bind roots (SPEC-021 C1). Session bindings injected by orchestrator.
_gc=$(git rev-parse --git-common-dir 2>/dev/null) \
  && MROOT=$(cd "$(dirname "$_gc")" && pwd) \
  || MROOT=$(pwd)
WTROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
BH_REPORT_DIR="${BH_REPORT_DIR:-$MROOT/.claude/bug-hunt}"
BH_USAGE='Usage: /bug-hunt [path] [--severity-floor <critical|warning|nitpick>] [--proceed]
Usage: /bug-hunt materialize <report|json|plan-path> [--severity-floor <critical|warning|nitpick>] [--proceed]
Usage: /bug-hunt handoff <plan-path> [--start-phase <n>]'
# lint-ok: C1 — BH_MODE / BH_PLAN / BH_HANDOFF_PATH from S0|S3g; orchestrator injects
: "${BH_MODE:?BH_MODE required (continuous|materialize|handoff)}"  # lint-ok: C1

BH_PLAN_ABS=""
if [ "$BH_MODE" = "handoff" ]; then
  : "${BH_HANDOFF_PATH:?BH_HANDOFF_PATH required in handoff mode}"  # lint-ok: C1
  case "$BH_HANDOFF_PATH" in
    /*) BH_PLAN_ABS="$BH_HANDOFF_PATH" ;;
    *)  BH_PLAN_ABS="$MROOT/$BH_HANDOFF_PATH"
        [ -e "$BH_PLAN_ABS" ] || BH_PLAN_ABS="$WTROOT/$BH_HANDOFF_PATH"
        [ -e "$BH_PLAN_ABS" ] || BH_PLAN_ABS="$BH_REPORT_DIR/$(basename -- "$BH_HANDOFF_PATH")"
        ;;
  esac
  if [ -e "$BH_PLAN_ABS" ]; then
    _bh_d=$(CDPATH= cd -- "$(dirname -- "$BH_PLAN_ABS")" && pwd) || _bh_d=""
    [ -n "$_bh_d" ] && BH_PLAN_ABS="$_bh_d/$(basename -- "$BH_PLAN_ABS")"
  fi
  BH_PLAN_BASE=$(basename -- "$BH_PLAN_ABS")
  BH_PLAN_DIR=$(dirname -- "$BH_PLAN_ABS")

  case "$BH_PLAN_BASE" in
    *-plan.md)
      BH_STEM="${BH_PLAN_BASE%-plan.md}"
      BH_PLAN="$BH_PLAN_ABS"
      ;;
    *)
      # Sibling resolve: path to report/json stem → <stem>-plan.md
      case "$BH_PLAN_BASE" in
        *.json) _sib_stem="${BH_PLAN_BASE%.json}" ;;
        *.md)   _sib_stem="${BH_PLAN_BASE%.md}" ;;
        *)      _sib_stem="" ;;
      esac
      if [ -n "$_sib_stem" ] && [ -f "$BH_PLAN_DIR/${_sib_stem}-plan.md" ] \
          && [ -r "$BH_PLAN_DIR/${_sib_stem}-plan.md" ]; then
        BH_STEM="$_sib_stem"
        BH_PLAN="$BH_PLAN_DIR/${_sib_stem}-plan.md"
      else
        echo "error: handoff path must end in -plan.md: $BH_HANDOFF_PATH" >&2
        echo "$BH_USAGE" >&2
        exit 64
      fi
      ;;
  esac
  BH_REPORT_DIR="$BH_PLAN_DIR"
else
  # continuous (or materialize→S4 after S3g): BH_PLAN already bound
  if [ -z "${BH_PLAN:-}" ]; then
    echo "error: continuous handoff requires BH_PLAN (missing after S3)" >&2
    echo "$BH_USAGE" >&2
    exit 64
  fi
  case "$BH_PLAN" in
    /*) BH_PLAN_ABS="$BH_PLAN" ;;
    *)  BH_PLAN_ABS="$MROOT/$BH_PLAN"
        [ -e "$BH_PLAN_ABS" ] || BH_PLAN_ABS="$WTROOT/$BH_PLAN"
        ;;
  esac
  if [ -e "$BH_PLAN_ABS" ]; then
    _bh_d=$(CDPATH= cd -- "$(dirname -- "$BH_PLAN_ABS")" && pwd) || _bh_d=""
    [ -n "$_bh_d" ] && BH_PLAN_ABS="$_bh_d/$(basename -- "$BH_PLAN_ABS")"
  fi
  BH_PLAN="$BH_PLAN_ABS"
  BH_PLAN_BASE=$(basename -- "$BH_PLAN")
  case "$BH_PLAN_BASE" in
    *-plan.md) BH_STEM="${BH_STEM:-${BH_PLAN_BASE%-plan.md}}" ;;
    *)
      echo "error: handoff path must end in -plan.md: $BH_PLAN" >&2
      echo "$BH_USAGE" >&2
      exit 64
      ;;
  esac
  BH_REPORT_DIR="${BH_REPORT_DIR:-$(dirname -- "$BH_PLAN")}"
fi

if [ ! -f "$BH_PLAN" ] || [ ! -r "$BH_PLAN" ]; then
  echo "error: findings plan not readable: $BH_PLAN" >&2
  echo "$BH_USAGE" >&2
  exit 64
fi

case "$BH_STEM" in
  [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]-*)
    BH_DATE=$(printf '%s\n' "$BH_STEM" | cut -d- -f1-3)
    BH_SLUG="${BH_STEM#"$BH_DATE"-}"
    ;;
  *)
    BH_DATE="${BH_DATE:-}"
    BH_SLUG="${BH_SLUG:-$BH_STEM}"
    ;;
esac

printf 'BH_STEM=%s\nBH_PLAN=%s\nBH_REPORT_DIR=%s\nBH_DATE=%s\nBH_SLUG=%s\n' \
  "$BH_STEM" "$BH_PLAN" "$BH_REPORT_DIR" "${BH_DATE:-}" "${BH_SLUG:-}"
```

#### 4a.2 Parse actionable table → plan rows

**Read** `$BH_PLAN` (Write-tool artifact; orchestrator Read). Source of truth =
markdown table under `## Actionable` matching `templates/findings-plan.md`:

```
| finding_id | severity | locator | description | evidence | backlog_slug | linear_id | status |
```

Parse algorithm (orchestrator; no invent):

```
plan_rows = []
text = Read(BH_PLAN)
for each markdown table data row under ## Actionable (skip header + separator):
  if row body is empty-state note "(none — 0 confirmed-actionable)" or all-dash:
    continue   # zero plan rows legal
  split cells on unescaped |  → 8 columns (trim whitespace)
  drop malformed (missing finding_id, or severity ∉ {critical,warning,nitpick})
  plan_rows.append({
    finding_id, severity, locator, description, evidence,
    backlog_slug, linear_id, status
  })
# Preserve table order (stable for S4b intra-band).
```

Frontmatter (optional restore): `hunt_stem` → confirm `BH_STEM`; ignore
`severity_floor` for banding (not re-applied).

#### 4a.3 Phaseable filter (OQ3 / M42)

```
BH_PHASEABLE = []
for R in plan_rows:   # table order
  st  = R.status
  slug = R.backlog_slug
  if st ∉ {materialized, skipped_linked}:
    continue   # planned | failed | other — not phaseable
  if slug is empty OR slug == "(pending)" OR slug == "(none)":
    continue   # linked slug required
  BH_PHASEABLE.append({
    finding_id: R.finding_id,
    severity: R.severity,          # critical|warning|nitpick
    locator: R.locator,
    description: R.description or "",
    evidence: R.evidence or "",
    backlog_slug: slug,
    linear_id: R.linear_id if set and ≠ "(pending)" else "",
    status: st                     # materialized | skipped_linked
  })
```

| Include | Exclude |
|---------|---------|
| `status=materialized` + non-empty slug | `planned`, `failed`, unknown status |
| `status=skipped_linked` + non-empty slug | `backlog_slug` empty / `(pending)` / `(none)` |
| | malformed severity / missing `finding_id` |

Empty `BH_PHASEABLE[]` is **legal** (zero path → S4b / AC11) — not exit 64.

Print:

```
S4a load: plan=$BH_PLAN stem=$BH_STEM phaseable=${#BH_PHASEABLE}
```

#### 4a.4 Session outputs for S4b+

| Binding | Value |
|---------|--------|
| `BH_PLAN` | absolute path of readable `-plan.md` |
| `BH_STEM` / `BH_DATE` / `BH_SLUG` | from plan basename / frontmatter |
| `BH_REPORT_DIR` | dirname of plan (usually `$MROOT/.claude/bug-hunt`) |
| `BH_PHASEABLE[]` | OQ3-filtered rows (may be empty) |
| `BH_START_PHASE` | unchanged from S0 (S4e) |
| `plan_rows[]` | optional full parse (debug); phaseable is authoritative |

**MUST NOT** after S4a: enter S1/S2/S3 invent, invent findings, fix, invoke
engines, re-filter by `--severity-floor`.

---

### S4b BAND (AC2 / M43 / OQ1–2)

**Contract:** Group `BH_PHASEABLE[]` into severity bands **only**
`critical` → `warning` → `nitpick`. **Omit empty** bands; renumber contiguous
`0..N` in emission order. `phase_id` = `BH-PHASE-<n>`. Intra-band order =
plan-table order (stable). Floor flag ignored.

#### 4b.1 Banding algorithm

```
ORDER = [critical, warning, nitpick]
BH_PHASES = []
n = 0
for sev in ORDER:
  items = [ R in BH_PHASEABLE where R.severity == sev ]   # preserve relative order
  if items is empty:
    continue   # omit empty band — do NOT allocate a phase_id
  BH_PHASES.append({
    n: n,
    phase_id: "BH-PHASE-" + n,    # BH-PHASE-0, BH-PHASE-1, …
    band: sev,                    # critical | warning | nitpick
    items: items                  # phaseable rows in this band
  })
  n += 1

BH_ITEM_COUNT  = |BH_PHASEABLE|
BH_PHASE_COUNT = |BH_PHASES|      # == n after loop; 0 when no phaseable
```

**Examples (omit-empty renumber):**

| Phaseable severities | Phases emitted |
|----------------------|----------------|
| critical + nitpick (no warning) | `0=critical`, `1=nitpick` (not 0,2) |
| warning only | `0=warning` |
| all three | `0=critical`, `1=warning`, `2=nitpick` |
| none | `BH_PHASES=[]`, `phase_count=0`, `item_count=0` |

Print:

```
S4b band: phase_count=$BH_PHASE_COUNT item_count=$BH_ITEM_COUNT bands=<csv or (none)>
```

(`bands` e.g. `0:critical,1:warning` or `(none)` when zero.)

#### 4b.2 Session outputs for S4c+

| Binding | Shape |
|---------|--------|
| `BH_PHASES[]` | `{n, phase_id, band, items[]}` after omit-empty renumber |
| `BH_PHASE_COUNT` | integer `\|non-empty bands\|` |
| `BH_ITEM_COUNT` | integer `\|BH_PHASEABLE\|` |
| `BH_PHASEABLE[]` | unchanged from S4a |

#### 4b.3 Zero path (AC11 / M48) — `phase_count == 0`

When `BH_PHASE_COUNT == 0` (no phaseable rows / all bands empty):

1. Counts: `BH_PHASE_COUNT=0`, `BH_ITEM_COUNT=0`, `BH_PHASES=[]`.
2. **Skip S4c–S4f** entirely — no route selection required for engines, **no**
   M9 phase lock, **no** arm, **no** `invocation_hint` spawn path.
3. **S4d write:** **minimal** `$BH_REPORT_DIR/<stem>-phase-plan.md` for resume
   identity (AC8) with `phase_count: 0` / empty index; **MUST emit zero**
   `*-handoff-phase-*.md` files.
4. **S4g (T4):** print clean M23 zero and **stop** (exit **0**). Exact form:

```
phase-done: handoff — 0 phases (M23)
hunt_stem: <BH_STEM>
plan_path: <BH_PLAN>
phase_count: 0
item_count: 0
```

5. **MUST NOT:** require `--start-phase` / typed lock; invent phases; invent
   findings; re-enter S1–S3; invoke `/orchestrate`/`/epic`; fix product code.

When `BH_PHASE_COUNT > 0`: continue **S4c** → S4d → S4e → S4f → S4g (T3/T4).

**MUST NOT** in S4b: write handoff files (S4d), arm locks (S4e), invoke engines,
re-order by custom priority, keep empty bands with holes in numbering.

### S4c ROUTE (AC4 / M45 / M18)

**Contract:** Select fix-engine route for this run. Write into phase-plan + every
handoff (`{{ROUTE}}`). Route is **identical** across all phases. **MUST NOT**
invoke the selected engine (emit-only; N12).

#### 4c.1 Rule (exact)

```
# phase_count >= 2 AND item_count >= 2 → /epic; else /orchestrate (AC4 / M45)
if phase_count >= 2 AND item_count >= 2:   # BH_PHASE_COUNT / BH_ITEM_COUNT
  BH_ROUTE = /epic
else:
  BH_ROUTE = /orchestrate   # default (M18 / M45)
```

| phase_count | item_count | BH_ROUTE |
|-------------|------------|----------|
| 0 | 0 | `/orchestrate` (zero-path default for phase-plan frontmatter only) |
| 1 | any ≥1 | `/orchestrate` (single band — batch one ticket/loop) |
| ≥2 | 1 | `/orchestrate` (impossible under omit-empty+one-item; rule still holds) |
| ≥2 | ≥2 | `/epic` |

Single phase with many items → still `/orchestrate`. Multi-band multi-item →
`/epic`.

#### 4c.2 Bind + print

```
# Zero path (phase_count==0): S4b skips here; S4d may bind default without engines.
BH_ROUTE = /epic | /orchestrate   # per 4c.1
```

Print:

```
S4c route: $BH_ROUTE (phase_count=$BH_PHASE_COUNT item_count=$BH_ITEM_COUNT)
```

#### 4c.3 Session outputs for S4d+

| Binding | Shape |
|---------|--------|
| `BH_ROUTE` | `/orchestrate` \| `/epic` |

**Next:** **S4d** WRITE (templates already cite `{{ROUTE}}` = `BH_ROUTE`).

**MUST NOT** in S4c: spawn `/orchestrate` or `/epic`; fix product code; re-band.

### S4d WRITE (AC3 / AC8 / M44 / OQ4 / OQ7)

**Contract:** Emit **all** phase artifacts at once (OQ4). Locks gate **arming**,
not file write. **Write tool** only (no bash heredoc with `!` — skill-lint C2).
**MUST NOT invoke** `/orchestrate` / `/epic` / spawn fix (AC9).

| Artifact | Path formula (OQ7) | Binding |
|----------|--------------------|---------|
| Phase plan | `$BH_REPORT_DIR/<stem>-phase-plan.md` | `BH_PHASE_PLAN` |
| Handoff n | `$BH_REPORT_DIR/<stem>-handoff-phase-<n>.md` | `BH_HANDOFF_N[n]` |

```
$BH_PHASE_PLAN = $MROOT/.claude/bug-hunt/${BH_STEM}-phase-plan.md
$BH_HANDOFF_N[n] = $MROOT/.claude/bug-hunt/${BH_STEM}-handoff-phase-<n>.md
```

Templates (plugin-shipped): `skills/bug-hunt/templates/phase-plan.md`,
`skills/bug-hunt/templates/handoff-phase.md` — field contracts live there;
skill cites + fills (no full template paste).

#### 4d.0 Preconditions

| Binding | Required |
|---------|----------|
| `BH_STEM` / `BH_PLAN` / `BH_REPORT_DIR` | from S4a |
| `BH_PHASES[]` / `BH_PHASE_COUNT` / `BH_ITEM_COUNT` | from S4b |
| `BH_ROUTE` | from S4c (or default `/orchestrate` when phase_count==0) |

When `BH_PHASE_COUNT == 0`: skip S4c is legal (S4b §4b.3); bind
`BH_ROUTE=/orchestrate` for phase-plan frontmatter only.

#### 4d.1 Resolve templates + ensure dir

```bash
# Re-bind roots + PDH (SPEC-021 C1). Session bindings injected by orchestrator.
_gc=$(git rev-parse --git-common-dir 2>/dev/null) \
  && MROOT=$(cd "$(dirname "$_gc")" && pwd) \
  || MROOT=$(pwd)
# lint-ok: C3 — marketplace */ for-loop + -f guarded (SPEC-021 Q2 residual, CDT-82 PDH)
PDH=$( { [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -f "$CLAUDE_PLUGIN_ROOT/skills/plugin-dir.sh" ] && printf '%s\n' "$CLAUDE_PLUGIN_ROOT"; } || { [ -f skills/plugin-dir.sh ] && pwd; } || { for _mp in "$HOME"/.claude/plugins/marketplaces/*/; do [ -f "${_mp}skills/plugin-dir.sh" ] && [ -f "${_mp}agents/pm.md" ] && printf '%s\n' "${_mp%/}" && break; done; } || find ~/.claude/plugins/cache -path '*/dev-team/*/skills/plugin-dir.sh' 2>/dev/null | awk -F/ '{ver=""; for(i=1;i<=NF;i++) if($i=="dev-team"&&i<NF){ver=$(i+1);break}; if(ver=="") next; m=ver; gsub(/-pre\./,"~pre.",m); p=($0 ~ /\/cache\/cold-dark-void\/dev-team\//)?1:0; print m "\t" p "\t" $0}' | sort -t $'\t' -k1,1V -k2,2n -k3,3 | tail -1 | cut -f3 | xargs -r dirname | xargs -r dirname )
# lint-ok: C1 — BH_* session bindings from S4a–S4c; orchestrator injects
: "${BH_STEM:?BH_STEM required}"  # lint-ok: C1
: "${BH_PLAN:?BH_PLAN required}"  # lint-ok: C1
BH_REPORT_DIR="${BH_REPORT_DIR:-$MROOT/.claude/bug-hunt}"  # lint-ok: C1
mkdir -p "$BH_REPORT_DIR"
BH_PHASE_PLAN="$BH_REPORT_DIR/${BH_STEM}-phase-plan.md"
BH_TMPL_PHASE_PLAN=$(bash "$PDH/skills/plugin-dir.sh" file skills/bug-hunt/templates/phase-plan.md)
BH_TMPL_HANDOFF=$(bash "$PDH/skills/plugin-dir.sh" file skills/bug-hunt/templates/handoff-phase.md)
[ -n "$BH_TMPL_PHASE_PLAN" ] && [ -f "$BH_TMPL_PHASE_PLAN" ] || {
  echo "error: could not resolve skills/bug-hunt/templates/phase-plan.md" >&2
  exit 1
}
[ -n "$BH_TMPL_HANDOFF" ] && [ -f "$BH_TMPL_HANDOFF" ] || {
  echo "error: could not resolve skills/bug-hunt/templates/handoff-phase.md" >&2
  exit 1
}
CREATED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)
BH_ROUTE="${BH_ROUTE:-/orchestrate}"  # lint-ok: C1 — S4c or zero-path default
printf 'BH_PHASE_PLAN=%s\nBH_ROUTE=%s\nCREATED_AT=%s\n' \
  "$BH_PHASE_PLAN" "$BH_ROUTE" "$CREATED_AT"
```

#### 4d.2 Zero path write (AC11 / AC8)

When `BH_PHASE_COUNT == 0`:

1. Write **minimal** `$BH_PHASE_PLAN` from `templates/phase-plan.md`:
   - `hunt_stem` / `plan_path` filled (AC8 resume identity)
   - `phase_count: 0`, `item_count: 0`, `route: /orchestrate`
   - `armed_phase: none`
   - `{{PHASE_INDEX}}` = `(none — 0 phaseable)`
2. **MUST emit zero** `*-handoff-phase-*.md` files (`BH_HANDOFF_N` empty map).
3. Print:

```
S4d write: phase_plan=$BH_PHASE_PLAN phases=0 handoffs=0
```

4. Continue **S4g** zero (T4) — skip S4e/S4f.

#### 4d.3 Per-phase handoff fill (AC3 / AC6 / AC8 / OQ8–OQ9)

For each `P` in `BH_PHASES[]` (n = 0..N):

| Placeholder | Value |
|-------------|--------|
| `{{PHASE_ID}}` | `P.phase_id` (`BH-PHASE-<n>`) |
| `{{PHASE_N}}` | `P.n` |
| `{{HUNT_STEM}}` | `BH_STEM` |
| `{{PLAN_PATH}}` | `BH_PLAN` absolute |
| `{{ROUTE}}` | `BH_ROUTE` |
| `{{BAND}}` | `P.band` |
| `{{ITEM_COUNT}}` | `\|P.items\|` |
| `{{GOAL}}` | `Close all phase items (severity=<band>) for hunt <stem>` (OQ8 fixed) |
| `{{CLOSED_COUNT_TARGET}}` | `\|P.items\|` |
| `{{RESIDUAL_CRITICALS}}` | `0` |
| `{{SIGNOFF}}` | `pending` (S4f → `recorded (flag\|token @ ISO)`) |
| `{{LOCK}}` | `AWAIT_USER start-phase-<n>` (S4f → `armed @ ISO`) |
| `{{INVOCATION_HINT}}` | see below |
| `{{CREATED_AT}}` | ISO-8601 UTC from 4d.1 |
| `{{ITEMS}}` | table rows (§4d.3 items) |

**`{{ITEMS}}`** — one row per item in `P.items` (plan-table order):

```
| <backlog_slug> | <linear_id or (none)> | <finding_id> | <severity> | <locator> |
```

**`{{INVOCATION_HINT}}`** (string only — never spawn):

```
if BH_ROUTE == /epic:
  /epic <ISSUE-ID>   # first non-empty linear_id in phase, else first backlog_slug
else:
  /orchestrate <ISSUE-ID>   # same ISSUE-ID guidance
```

Path bind:

```
BH_HANDOFF_N[P.n] = $BH_REPORT_DIR/${BH_STEM}-handoff-phase-${P.n}.md
```

Write filled `templates/handoff-phase.md` → `BH_HANDOFF_N[P.n]` (Write tool).

#### 4d.4 Phase-plan index fill

| Placeholder | Value |
|-------------|--------|
| `{{HUNT_STEM}}` | `BH_STEM` |
| `{{PLAN_PATH}}` | `BH_PLAN` absolute |
| `{{ROUTE}}` | `BH_ROUTE` |
| `{{PHASE_COUNT}}` | `BH_PHASE_COUNT` |
| `{{ITEM_COUNT}}` | `BH_ITEM_COUNT` |
| `{{CREATED_AT}}` | ISO from 4d.1 |
| `{{ARMED_PHASE}}` | `none` at emit (S4f rewrites) |
| `{{PHASE_INDEX}}` | one row per phase (§ below) |

**`{{PHASE_INDEX}}`** — one row per `P` in `BH_PHASES[]`:

```
| <n> | BH-PHASE-<n> | <band> | <|items|> | <stem>-handoff-phase-<n>.md | <route> | AWAIT_USER |
```

Write filled `templates/phase-plan.md` → `$BH_PHASE_PLAN` (Write tool).

#### 4d.5 Write order + print

1. Ensure dir (4d.1).
2. If `phase_count == 0` → minimal phase-plan only (4d.2); stop this step.
3. Else: for each phase write handoff file (4d.3); then write phase-plan (4d.4).
4. Leave no bare `{{` in any output file.
5. **MUST NOT** `git add` / commit (process artifact; M25).
6. Print:

```
S4d write: phase_plan=$BH_PHASE_PLAN phases=$BH_PHASE_COUNT handoffs=$BH_PHASE_COUNT
  route: $BH_ROUTE
  handoffs: <comma-separated basenames or paths>
```

#### 4d.6 Session outputs for S4e+

| Binding | Shape |
|---------|--------|
| `BH_PHASE_PLAN` | absolute path **written** |
| `BH_HANDOFF_N` | map n → absolute handoff path (empty when phase_count==0) |
| `BH_ROUTE` | unchanged from S4c (or zero-path default) |
| `BH_PHASES[]` | unchanged; each may note `handoff_path` |
| pre-arm | all handoffs `lock=AWAIT_USER`; `signoff=pending`; phase-plan `armed_phase=none` |

**Next:** `phase_count > 0` → **S4e** lock (T4). `phase_count == 0` → **S4g** zero (T4).

**MUST NOT** after S4d: invoke engines; fix product code; re-S1–S3 invent;
auto-arm without S4e; delete templates on lock fail.

### S4e LOCK (AC5 / M46 / OQ5 / M9 / M36)

**Contract:** Gate **arming** of phase `n` only — templates already on disk
from S4d (OQ4). Explicit user action to **start phase 0** and **between
phases**. Completing a fix phase MUST NOT auto-start the next (M9 / M36).
**MUST NOT** delete templates on lock miss. **MUST NOT** auto-advance.

#### 4e.0 Zero-path skip (AC11)

When `BH_PHASE_COUNT == 0`: S4b/S4d already routed here past S4e — **do not**
enter this step. No lock; go **S4g** zero.

#### 4e.1 Target phase `n`

| Source | `n` |
|--------|-----|
| `--start-phase <n>` (`BH_START_PHASE` from S0) | that integer |
| Typed token `start-phase-<n>` | parsed integer from token |
| Neither | no arm — emit-only stop (§4e.5) |

Valid range: `0 ≤ n < BH_PHASE_COUNT`. Out-of-range / non-integer already
rejected at S0 for the flag; typed token with bad `n` → treat as not locked
(print how-to; exit 0) — never invent a phase.

Between-phase resume (M9/M36): operator re-enters
`/bug-hunt handoff $BH_PLAN --start-phase <n>` for `n > 0` after completing
prior fix work **outside** this skill. Each arm is independent; no auto chain.

#### 4e.2 Accept forms (both document OQ5)

| Input | Detect | Effect |
|-------|--------|--------|
| `--start-phase <n>` | `BH_START_PHASE=n` from S0 (continuous or handoff) | Record form=`flag`; continue S4f for phase `n` |
| Typed token | User reply exact `start-phase-<n>` (case-insensitive; trim) | Record form=`token`; continue S4f for that `n` |
| Neither | no flag + no valid token | **STOP** emit-only; templates stay; `BH_ARM_PHASE=none`; exit **0** |

Either form satisfies M9. Flag skips the interactive prompt when already bound
from the invocation.

#### 4e.3 Interactive prompt (when no BH_START_PHASE)

Print exactly (then wait for one user turn):

```
Phase handoff templates written (review before arming a phase):
  phase_plan: $BH_PHASE_PLAN
  phase_count: $BH_PHASE_COUNT
  route: $BH_ROUTE
  phase_0_handoff: $BH_HANDOFF_N[0]

Awaiting start-phase: re-run with --start-phase <n> or type start-phase-<n>
  example: /bug-hunt handoff $BH_PLAN --start-phase 0
  example typed: start-phase-0
```

Accept **only** token matching `start-phase-<digits>` (case-insensitive).
Any other reply (empty, `yes`, `go`, `proceed`, bare number) is **not** a lock:

```
Start-phase not recorded (got: <reply>). Templates kept; armed_phase: none.
Awaiting start-phase: re-run with --start-phase <n> or type start-phase-<n>
  phase_plan: $BH_PHASE_PLAN
  plan: $BH_PLAN
```

Then **exit 0**. **MUST NOT** enter S4f; **MUST NOT** spawn engines.

#### 4e.4 Record lock intent (session)

On success (`flag` or `token` for valid `n`):

| Binding | Value |
|---------|--------|
| `BH_ARM_PHASE` | integer `n` (intent; S4f records on disk) |
| `BH_ARM_FORM` | `flag` \| `token` |
| `BH_ARM_AT` | ISO-8601 UTC (`date -u +%Y-%m-%dT%H:%M:%SZ`) |

Print:

```
S4e lock: start-phase-$n recorded ($BH_ARM_FORM @ $BH_ARM_AT)
  handoff: $BH_HANDOFF_N[n]
```

Continue **S4f**.

Optional observability (not a lock form; no auto-advance): if the operator
message mentions `force-next`, log one line `force-next: logged (M9 still
required)` and still require §4e.2 forms.

#### 4e.5 Emit-only stop (neither form)

When lock fails / neither form:

1. Leave all handoffs `lock=AWAIT_USER start-phase-<n>`; `signoff=pending`.
2. Leave phase-plan `armed_phase: none`.
3. **MUST NOT** delete or rewrite templates away.
4. Print:

```
S4e emit-only: phase lock not armed
  phase_plan: $BH_PHASE_PLAN
  plan: $BH_PLAN
  route: $BH_ROUTE
  phase_count: $BH_PHASE_COUNT
  item_count: $BH_ITEM_COUNT
  armed_phase: none
Awaiting start-phase: re-run with --start-phase <n> or type start-phase-<n>
  example: /bug-hunt handoff $BH_PLAN --start-phase 0
```

5. Continue **S4g** with `armed_phase: none` (M23 full path still prints
   resume identity + templates). Exit **0** after S4g.
6. **MUST NOT** S4f; **MUST NOT** invoke `/orchestrate` / `/epic`; **MUST NOT**
   fix / re-S1–S3 invent.

#### 4e.6 Session outputs

| Binding | Shape |
|---------|--------|
| `BH_ARM_PHASE` | `none` (emit-only stop) \| integer `n` (locked) |
| `BH_ARM_FORM` | unset \| `flag` \| `token` |
| `BH_ARM_AT` | unset \| ISO when locked |
| templates on disk | unchanged until S4f |

**Next:** lock success → **S4f**. Emit-only → **S4g** (`armed_phase: none`).

---

### S4f ARM (AC9 / OQ10 / M47 signoff)

**Contract:** On lock success for phase `n` only: rewrite phase-plan + that
phase's handoff to **armed**, then print pasteable `invocation_hint` **string
only**. **MUST NOT** Task/Agent spawn `/orchestrate` or `/epic`. **MUST NOT**
run fix ICs or edit product code (AC9 / N12 / OQ10).

#### 4f.0 Preconditions

| Binding | Required |
|---------|----------|
| `BH_ARM_PHASE` | integer `n` with `0 ≤ n < BH_PHASE_COUNT` |
| `BH_ARM_FORM` | `flag` \| `token` |
| `BH_HANDOFF_N[n]` / `BH_PHASE_PLAN` | written in S4d |
| `BH_ROUTE` | from S4c |

If `BH_ARM_PHASE` is `none` / unset: **MUST NOT** enter (S4e emit-only path).

#### 4f.1 Rewrite handoff phase `n` (Write tool)

Re-read `$BH_HANDOFF_N[n]` (or rebuild from template + session). Set:

| Field | Value |
|-------|--------|
| `lock` | `armed @ $BH_ARM_AT` |
| `signoff` / `exit_metrics.signoff` | `recorded ($BH_ARM_FORM @ $BH_ARM_AT)` |
| `exit_metrics.closed_count_target` | unchanged (`\|items\|`) |
| `exit_metrics.residual_criticals` | unchanged (`0`) |
| `route` / `invocation_hint` | unchanged from S4d emit |
| other identity fields | unchanged |

**Write** with the Write tool only (no bash heredoc with `!`). Other phases
stay `AWAIT_USER` / `pending` (no auto-arm of n+1).

#### 4f.2 Rewrite phase-plan index (Write tool)

Update `$BH_PHASE_PLAN`:

| Field | Value |
|-------|--------|
| frontmatter `armed_phase` | `n` |
| phase `n` arm cell | `armed @ $BH_ARM_AT` |
| other phase arm cells | stay `AWAIT_USER` |

#### 4f.3 Print invocation_hint ONLY (pasteable)

Build / re-read hint from handoff (string only — never execute):

```
if BH_ROUTE == /epic:
  HINT = "/epic <ISSUE-ID>"
else:
  HINT = "/orchestrate <ISSUE-ID>"
# ISSUE-ID guidance: first non-empty linear_id in phase n items,
# else first backlog_slug (operator substitutes real ticket id as needed)
```

Print exactly (user-visible; pasteable):

```
S4f armed: phase $n ($BH_ARM_FORM @ $BH_ARM_AT)
  handoff: $BH_HANDOFF_N[n]
  route: $BH_ROUTE

invocation_hint (paste only — skill MUST NOT invoke):
<HINT>
```

**Hard wall:** printing `<HINT>` is **not** an invocation. Orchestrator **MUST
NOT** call Task/Agent/Bash to run `/orchestrate` or `/epic`. Operator pastes
elsewhere.

#### 4f.4 Session outputs for S4g

| Binding | Shape |
|---------|--------|
| `BH_ARM_PHASE` | `n` (armed) |
| phase-plan / handoff `n` | on-disk armed + signoff recorded |
| exit metrics | closed_count target / residual_criticals=0 / signoff recorded (M47) |

Print brief confirm then **S4g**:

```
S4f arm done: armed_phase=$BH_ARM_PHASE
```

**MUST NOT** after S4f: spawn engines; fix code; arm another phase in the same
run without a new lock; auto-advance.

---

### S4g PHASE-DONE (AC7 / AC11 / M48 / M23)

**Contract:** Print exact M23 phase-done, stop. Exit **0**. Hunt stage 4 Done
(emit-only). Resume identity always present when a plan was loaded.

#### 4g.1 Full path (`BH_PHASE_COUNT > 0`)

Print exact multi-line block (fill paths from session):

```
phase-done: handoff — resume identity + phase templates (M23)
hunt_stem: <BH_STEM>
plan_path: <BH_PLAN>
phase_plan: <BH_PHASE_PLAN>
phase_0_handoff: <BH_HANDOFF_N[0]>
route: </orchestrate|/epic>
phase_count: <BH_PHASE_COUNT>
item_count: <BH_ITEM_COUNT>
armed_phase: <n|none>
```

| Line | Source |
|------|--------|
| `hunt_stem` | `BH_STEM` |
| `plan_path` | `BH_PLAN` absolute |
| `phase_plan` | `BH_PHASE_PLAN` absolute |
| `phase_0_handoff` | `BH_HANDOFF_N[0]` absolute (always exists when phase_count>0) |
| `route` | `BH_ROUTE` |
| `phase_count` / `item_count` | `BH_PHASE_COUNT` / `BH_ITEM_COUNT` |
| `armed_phase` | `BH_ARM_PHASE` (`n` after S4f; `none` after emit-only S4e stop) |

#### 4g.2 Zero path (`BH_PHASE_COUNT == 0` — AC11)

Print exact:

```
phase-done: handoff — 0 phases (M23)
hunt_stem: <BH_STEM>
plan_path: <BH_PLAN>
phase_count: 0
item_count: 0
```

Consistent with S4b §4b.3 / S4d minimal phase-plan. **No** `phase_0_handoff`,
**no** route line required (optional `route: /orchestrate` if already bound),
**no** lock, **no** `armed_phase`. Exit **0**.

#### 4g.3 Terminal summary

After M23 block:

```
Handoff done (emit-only).
  phase_plan: $BH_PHASE_PLAN
  armed_phase: ${BH_ARM_PHASE:-none}
  route: ${BH_ROUTE:-/orchestrate}
```

When armed, remind (string only):

```
Next (operator): paste invocation_hint from handoff; do not expect this skill to spawn engines.
Between phases: /bug-hunt handoff $BH_PLAN --start-phase <n>
```

#### 4g.4 Hard walls at stop (AC9 / AC10 / AC12 / N12 / N13)

**MUST NOT after S4g:**

- **invoke** `/orchestrate` / `/epic` / Task-spawn fix engines
- fix / implement / edit product code for findings
- re-S1 discover / re-S2 refute / re-S3 invent / invent findings
- auto-advance to next phase without a new M9 lock (M36)
- commit / version / `/release`
- delete phase templates

#### 4g.5 Session outputs (terminal S4)

| Binding | Final |
|---------|--------|
| `BH_PHASE_PLAN` / `BH_HANDOFF_N` | written |
| `BH_ROUTE` | `/orchestrate` \| `/epic` |
| `BH_PHASE_COUNT` / `BH_ITEM_COUNT` | final |
| `BH_ARM_PHASE` | `none` \| integer `n` |
| M23 | printed; exit **0** |

**Stage 4 Done.** Operator owns downstream fix runs via printed hint only.

### Deferred (not S4)

| Item | Owner |
|------|-------|
| `--teams` / `--lenses` flags on `/bug-hunt` | later (C5 / MVP flag surface) |
| Auto-running fix engines / post-close verification | out of scope forever for bug-hunt |
| Tribunal per candidate; Workflow driver | later |

---

## Traceability

| Requirement | Where |
|-------------|--------|
| Surface / args / floor / `--proceed` / `materialize` / `handoff` / `--start-phase` | Arguments; S0; SPEC-034 M1–M5 / M8 / M46 |
| Continuous S1→S2 | Pipeline; Invariants; M7, N8 |
| Finding model + AC8 | Finding model; S1 §1f; M10–M13 |
| Floor filter / dropped | Finding model; S1 §1f; M14–M15 |
| Compose SPEC-013 blind (discover) | Overview; **S1**; M16 / **M33** |
| Phase-done M20 discover | S1 §1g |
| Phase-done M21 refute | **S2** §2k; **REPORT** R1 |
| Refute compose ≥2 distinct flavors (M34) | **S2** §2b–2e |
| Disposition confirmed\|refuted; no leftover candidate | **S2** §2g–2i (AC7) |
| AC8 fields on confirmed | **S2** §2i; Finding model; **REPORT** R1 |
| confirmed_actionable = confirmed ∧ ≥floor (M32/AC9) | **S2** §2i; **REPORT** R1–R2 |
| Zero-actionable terminal (AC10) | **S2** §2l; **REPORT** R1 / R4; **S3b/S3g** |
| S3 load json/report (AC1 / M38) | **S3a** (prefer json → report → loud fail 64) |
| S3 filter confirmed ∧ ≥floor (AC2) | **S3b**; `BH_ACTIONABLE[]` |
| Zero actionable (AC10 / M41) | **S3b** §3b.3; **S3g** M22 zeros |
| Findings plan path (AC3 / M39) | **S3c**; `BH_PLAN`; `templates/findings-plan.md` |
| Proceed before materialize (AC4 / M8 / M41) | **S3d**; Invariants |
| Programmatic write-back only (AC5 / M40) | **S3e**; compose table; backlog SKILL |
| bh-quality body + slugs + linkage (AC6–AC8) | **S3e** §3e.3–3e.6; **S3f** |
| Phase-done M22 materialize (AC9) | **S3g** §3g.2–3g.3 |
| Proceed forms flag\|token; plan-only stop (M41) | **S3d** §3d.2–3d.5 |
| Idempotent skip linked (OQ3) | **S3e** §3e.2 |
| Programmatic Direct write Linear-first (M40) | **S3e** §3e.5; backlog § Programmatic write-back |
| Hard walls no invoke engines/fix/re-S1–S3 invent | Invariants; **S3g**; **S4** |
| S4 handoff args `handoff` / `--start-phase` | Arguments; S0; **S4** |
| S4 load C3 plan + phaseable OQ3 (AC1 / M42) | **S4a** (loud fail 64; N13) |
| S4 severity bands omit-empty renumber (AC2 / M43) | **S4b** §4b.1 |
| S4 zero path 0 phases M23 (AC11) | **S4b** §4b.3 → **S4d** minimal → **S4g** §4g.2 |
| S4 phase artifacts write (AC3 / AC8 / M44) | **S4d**; `templates/phase-plan.md` + `handoff-phase.md` |
| S4 route rule M18/M45 (AC4) | **S4c** §4c.1 — `/epic` iff phase_count≥2 ∧ item_count≥2 |
| S4 phase lock M9/M46 (AC5) | **S4e** — `--start-phase n` \| typed `start-phase-n` |
| S4 arm + invocation_hint only (AC9 / OQ10) | **S4f** — MUST NOT spawn engines |
| S4 exit metrics on template (AC6 / M47) | **S4d** emit + **S4f** signoff; `templates/handoff-phase.md` |
| S4 phase-done M23 full + zero (AC7 / M48) | **S4g** §4g.1–4g.2 |
| S4 bindings BH_PHASE* / BH_ROUTE / BH_ARM / BH_HANDOFF_N | Arguments bindings; **S4a–S4g** |
| S4 pipeline S4a–S4g emit-only | Pipeline; **S4** |
| CDV-199 degradation | Invariants; S1 §1c; **S2** §2h; **REPORT** R1 banner; council § Spawn-failure degradation |
| Report path / uncommitted (M31/M25) | **REPORT** R0–R3; `.gitignore` → `.claude/bug-hunt/` |
| SHOULD findings JSON (S3 intermediate) | **REPORT** R3; **S3a**; `templates/findings.json` |

SPEC-034 M31–M34 live (C2). S3 cites **M8** / **M22** / **M38–M41** (CDT-138).
S4 cites **M42–M48** live (CDT-139): load/band/write + route/locks/ARM/M23.

---

## Interaction with other components

| Component | Relationship |
|-----------|--------------|
| `commands/bug-hunt.md` | Thin entry; PDH → this skill; stages 1–4 surface (CDT-139 T5) |
| `skills/council/SKILL.md` | Blind-review path (S1) + investigator + degradation (S2) |
| `commands/council.md` | Blind-review dispatch surface + substitutions (cite for S1) |
| `skills/council/prompts/*` | `unconstrained-reviewer`, `lens-reviewer`, `quorum-analyst`, `investigator` |
| `skills/council/flavors/*` | Existing flavors only for S2 pairs |
| `skills/backlog/SKILL.md` | § Programmatic write-back — **only** dual-write path for S3e (no fork) |
| `skills/bug-hunt/templates/phase-plan.md` | S4d phase index template (T3) |
| `skills/bug-hunt/templates/handoff-phase.md` | S4d per-phase handoff template (T3) |
| `specs/core/SPEC-034-bug-hunt-workflow.md` | Product contract (M8, M38–M41, M42–M48) |
| `specs/core/SPEC-013-adversarial-council-tribunal.md` | Blind + investigator MUSTs |
| `specs/core/SPEC-009-*` (backlog) | Dual-write / index contract composed by backlog skill |
| `.claude/bug-hunt/` | Hunt reports + plans + phase handoffs (uncommitted) |
| `/debug`, `/orchestrate`, `/epic` | Neighbors; **not invoked** by stages 1–4 (S4 print-only hints) |

---

## Implementation fill-in map (epic tasks)

| Task | Fills |
|------|--------|
| — C2/C3 filled — | S0–S3; REPORT; materialize |
| T0 | SPEC-034 M42–M48 additive (∥ T1; DRAFT) |
| T1 | S4 skeleton walls/args/bindings/stubs |
| T2 | S4a LOAD + S4b BAND + zero path |
| T3 | phase-plan + handoff-phase templates + S4d write |
| T4 | S4c route + S4e locks + S4f ARM + S4g M23 (**this**) |
| T5 | `commands/bug-hunt.md` thin host stages 1–4 |
| T6 | `skills/bug-hunt/test.sh` C4 static contracts |
| T7 | docs/commands + README touch |
| T8 | QA AC matrix |
