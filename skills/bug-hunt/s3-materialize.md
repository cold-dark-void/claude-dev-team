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
BH_USAGE='Usage: /bug-hunt [path] [--severity-floor <critical|warning|nitpick>] [--proceed] [--start-phase <n>]
Usage: /bug-hunt materialize <report|json|plan-path> [--severity-floor <critical|warning|nitpick>] [--proceed]'
# lint-ok: C1 — BH_MODE / BH_FLOOR / BH_MAT_PATH / continuous paths from S0|REPORT; orchestrator injects
: "${BH_MODE:?BH_MODE required (continuous|materialize)}"  # lint-ok: C1
: "${BH_FLOOR:?BH_FLOOR required}"  # lint-ok: C1
BH_FLOOR_CLI="$BH_FLOOR"
BH_FLOOR_FROM_CLI="${BH_FLOOR_FROM_CLI:-0}"
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

  case "$BH_MAT_ABS" in
    "$MROOT/.claude/bug-hunt"|"$MROOT/.claude/bug-hunt"/*) ;;
    *)
      echo "error: materialize path outside .claude/bug-hunt/: $BH_MAT_ABS" >&2
      echo "$BH_USAGE" >&2
      exit 64
      ;;
  esac

  case "$BH_MAT_BASE" in
    *-phase-plan.md)
      _bh_sib="${BH_MAT_BASE%-phase-plan.md}"
      _bh_sib_plan="$BH_MAT_DIR/${_bh_sib}-plan.md"
      if [ ! -f "$_bh_sib_plan" ] || [ ! -r "$_bh_sib_plan" ]; then
        echo "error: phase-plan has no sibling findings plan: $_bh_sib_plan" >&2
        echo "$BH_USAGE" >&2
        exit 64
      fi
      BH_STEM="$_bh_sib"
      BH_PLAN="$_bh_sib_plan"
      BH_FINDINGS="$BH_MAT_DIR/${BH_STEM}.json"
      BH_REPORT="$BH_MAT_DIR/${BH_STEM}.md"
      BH_LOAD_KIND="plan"
      ;;
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
printf 'BH_LOAD_KIND=%s\nBH_LOAD_SRC=%s\nBH_FLOOR=%s\nBH_FLOOR_CLI=%s\nBH_FLOOR_FROM_CLI=%s\n' \
  "$BH_LOAD_KIND" "$BH_LOAD_SRC" "$BH_FLOOR" "$BH_FLOOR_CLI" "$BH_FLOOR_FROM_CLI"
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
if BH_FLOOR_FROM_CLI is 1:
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
PDH="${PDH:-<PDH>}"   # session root carried from the stanza fence above — re-run that fence first when not held
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

