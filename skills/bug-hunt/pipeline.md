<!-- /bug-hunt stage body — load via SKILL.md router; read only the current stage. -->

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
