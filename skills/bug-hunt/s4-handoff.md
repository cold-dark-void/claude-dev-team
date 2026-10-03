<!-- /bug-hunt stage body — load via SKILL.md router; read only the current stage. -->

### Stage anchor — resolve PDH (fresh-shell safe)

```bash
# Locate the dev-team plugin root (PDH). Optional CLAUDE_PLUGIN_ROOT (force path / FR #48230), else cwd only when it is the dev-team plugin itself (CDT-265), else marketplace clone (slug-free agents/pm.md), else installed cache (rank by /dev-team/<VER>/ segment, not full path; CDT-166). CDT-82: marketplace before same-version cache.
# lint-ok: C3 — marketplace */ for-loop + -f guarded (SPEC-021 Q2 residual, CDT-82 PDH)
PDH=$( { [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -f "$CLAUDE_PLUGIN_ROOT/skills/plugin-dir.sh" ] && printf '%s\n' "$CLAUDE_PLUGIN_ROOT"; } || { [ -f skills/plugin-dir.sh ] && [ -f agents/pm.md ] && grep -qF '"name": "dev-team"' .claude-plugin/plugin.json 2>/dev/null && pwd; } || { _pr='${CLAUDE_PLUGIN_ROOT}'; [ "${_pr#\$}" = "$_pr" ] && [ -f "$_pr/skills/plugin-dir.sh" ] && printf '%s\n' "$_pr"; } || { for _mp in "$HOME"/.claude/plugins/marketplaces/*/; do [ -f "${_mp}skills/plugin-dir.sh" ] && [ -f "${_mp}agents/pm.md" ] && printf '%s\n' "${_mp%/}" && break; done; } || find ~/.claude/plugins/cache -path '*/dev-team/*/skills/plugin-dir.sh' 2>/dev/null | awk -F/ '{ver=""; for(i=1;i<=NF;i++) if($i=="dev-team"&&i<NF){ver=$(i+1);break}; if(ver=="") next; m=ver; gsub(/-pre\./,"~pre.",m); p=($0 ~ /\/cache\/cold-dark-void\/dev-team\//)?1:0; print m "\t" p "\t" $0}' | sort -t $'\t' -k1,1V -k2,2n -k3,3 | tail -1 | cut -f3 | xargs -r dirname | xargs -r dirname )
printf 'PDH=%s\n' "$PDH" >&2
```

Run this anchor fence first when the carried `PDH` is not held; later fences in
this file carry it as `PDH="${PDH:-<PDH>}"` session state.

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
BH_USAGE='Usage: /bug-hunt [path] [--severity-floor <critical|warning|nitpick>] [--proceed] [--start-phase <n>]
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
    *-phase-plan.md)
      _bh_sib="${BH_PLAN_BASE%-phase-plan.md}"
      _bh_sib_plan="$BH_PLAN_DIR/${_bh_sib}-plan.md"
      if [ ! -f "$_bh_sib_plan" ] || [ ! -r "$_bh_sib_plan" ]; then
        echo "error: phase-plan has no sibling findings plan: $_bh_sib_plan" >&2
        echo "$BH_USAGE" >&2
        exit 64
      fi
      BH_STEM="$_bh_sib"
      BH_PLAN="$_bh_sib_plan"
      ;;
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
    *-phase-plan.md)
      _bh_sib="${BH_PLAN_BASE%-phase-plan.md}"
      _bh_sib_plan="$(dirname -- "$BH_PLAN")/${_bh_sib}-plan.md"
      if [ ! -f "$_bh_sib_plan" ] || [ ! -r "$_bh_sib_plan" ]; then
        echo "error: phase-plan has no sibling findings plan: $_bh_sib_plan" >&2
        echo "$BH_USAGE" >&2
        exit 64
      fi
      BH_STEM="$_bh_sib"
      BH_PLAN="$_bh_sib_plan"
      ;;
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
PDH="${PDH:-<PDH>}"   # session root carried from the stanza fence above — re-run that fence first when not held
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

Valid range: `0 ≤ n < BH_PHASE_COUNT`. S0 rejects a non-integer `--start-phase`
(exit **64**). S4e rejects an integer outside that range (exit **64**). A typed
token with a bad `n` is not a lock (print how-to; exit **0**). Never invent a phase.

```bash
# S4e range fence. Orchestrator injects BH_PHASE_COUNT and optional BH_START_PHASE.
BH_START_PHASE="${BH_START_PHASE:-}"
BH_PHASE_COUNT="${BH_PHASE_COUNT:?BH_PHASE_COUNT required}"
case "$BH_PHASE_COUNT" in
  ''|*[!0-9]*)
    echo "error: BH_PHASE_COUNT must be a non-negative integer" >&2
    exit 64
    ;;
esac
if [ -n "$BH_START_PHASE" ]; then
  case "$BH_START_PHASE" in
    *[!0-9]*)
      echo "error: --start-phase requires non-negative integer (got '$BH_START_PHASE')" >&2
      exit 64
      ;;
  esac
  if [ "$BH_START_PHASE" -ge "$BH_PHASE_COUNT" ]; then
    echo "error: --start-phase $BH_START_PHASE out of range (phase_count=$BH_PHASE_COUNT)" >&2
    exit 64
  fi
  printf 'BH_ARM_PHASE=%s\n' "$BH_START_PHASE"
else
  printf 'BH_ARM_PHASE=none\n'
fi
```

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

