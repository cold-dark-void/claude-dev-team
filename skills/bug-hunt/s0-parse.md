<!-- /bug-hunt stage body — load via SKILL.md router; read only the current stage. -->

## Arguments

```
# Continuous (S1→S3→S4 same session — OQ5/OQ6):
Usage: /bug-hunt [path] [--severity-floor <critical|warning|nitpick>] [--proceed] [--start-phase <n>]

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
| `--severity-floor` | No | continuous: `nitpick`; materialize resume: from artifact then `nitpick` | value ∉ {`critical`,`warning`,`nitpick`} → exit **64** (M3–M4); re-applied at S3b (AC2); **ignored for S4 banding**; **handoff rejects the flag** (exit **64**) |
| `--proceed` | No | off | Satisfies M8 without interactive token; enables S3e after plan (AC4 / OQ2); **handoff rejects the flag** (exit **64**) |
| Typed proceed | No | off | Exact token `proceed` (case-insensitive) on materialize lock prompt (S3d) |
| `--start-phase <n>` | No | off | Satisfies M9 for phase `n` (OQ5); continuous or handoff only. Materialize rejects the flag (exit **64**). S0 accepts only a non-negative integer. S4e rejects `n >= BH_PHASE_COUNT` (exit **64**) |
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
Usage: /bug-hunt [path] [--severity-floor <critical|warning|nitpick>] [--proceed] [--start-phase <n>]
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
# Locate the dev-team plugin root (PDH). Optional CLAUDE_PLUGIN_ROOT (force path / FR #48230), else cwd only when it is the dev-team plugin itself (CDT-265), else marketplace clone (slug-free agents/pm.md), else installed cache (rank by /dev-team/<VER>/ segment, not full path; CDT-166). CDT-82: marketplace before same-version cache.
# lint-ok: C3 — marketplace */ for-loop + -f guarded (SPEC-021 Q2 residual, CDT-82 PDH)
PDH=$( { [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -f "$CLAUDE_PLUGIN_ROOT/skills/plugin-dir.sh" ] && printf '%s\n' "$CLAUDE_PLUGIN_ROOT"; } || { [ -f skills/plugin-dir.sh ] && [ -f agents/pm.md ] && grep -qF '"name": "dev-team"' .claude-plugin/plugin.json 2>/dev/null && pwd; } || { _pr='${CLAUDE_PLUGIN_ROOT}'; [ "${_pr#\$}" = "$_pr" ] && [ -f "$_pr/skills/plugin-dir.sh" ] && printf '%s\n' "$_pr"; } || { for _mp in "$HOME"/.claude/plugins/marketplaces/*/; do [ -f "${_mp}skills/plugin-dir.sh" ] && [ -f "${_mp}agents/pm.md" ] && printf '%s\n' "${_mp%/}" && break; done; } || find ~/.claude/plugins/cache \( -path '*/dev-team/*/skills/plugin-dir.sh' -o -path '*/dev-team-edge/*/skills/plugin-dir.sh' \) 2>/dev/null | awk -F/ '{ver=""; for(i=1;i<=NF;i++) if(($i=="dev-team"||$i=="dev-team-edge")&&i<NF){ver=$(i+1);break}; if(ver=="") next; m=ver; gsub(/-pre\./,"~pre.",m); p=($0 ~ /\/cache\/cold-dark-void\/dev-team\//)?2:(($0 ~ /\/cache\/cold-dark-void\/dev-team-edge\//)?1:0); print m "\t" p "\t" $0}' | sort -t $'\t' -k1,1V -k2,2n -k3,3 | tail -1 | cut -f3 | xargs -r dirname | xargs -r dirname )
printf 'PDH=%s\n' "$PDH" >&2
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
BH_REPORT_DIR="${BH_REPORT_DIR:-$MROOT/.claude/bug-hunt}"

BH_USAGE='Usage: /bug-hunt [path] [--severity-floor <critical|warning|nitpick>] [--proceed] [--start-phase <n>]
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
BH_FLOOR_FROM_CLI=0
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
      if [ "$BH_MODE" = "handoff" ]; then
        echo "error: --severity-floor is not valid in handoff mode" >&2
        echo "$BH_USAGE" >&2
        exit 64
      fi
      if [ -z "${2:-}" ] || case "$2" in --*) true;; *) false;; esac; then
        echo "error: --severity-floor requires one of: critical|warning|nitpick" >&2
        echo "$BH_USAGE" >&2
        exit 64
      fi
      BH_FLOOR="$2"
      BH_FLOOR_FROM_CLI=1
      shift 2
      ;;
    --severity-floor=*)
      if [ "$BH_MODE" = "handoff" ]; then
        echo "error: --severity-floor is not valid in handoff mode" >&2
        echo "$BH_USAGE" >&2
        exit 64
      fi
      BH_FLOOR="${1#--severity-floor=}"
      BH_FLOOR_FROM_CLI=1
      shift
      ;;
    --proceed)
      if [ "$BH_MODE" = "handoff" ]; then
        echo "error: --proceed is not valid in handoff mode" >&2
        echo "$BH_USAGE" >&2
        exit 64
      fi
      BH_PROCEED="flag"
      shift
      ;;
    --start-phase)
      if [ "$BH_MODE" = "materialize" ]; then
        echo "error: --start-phase is not valid in materialize mode" >&2
        echo "$BH_USAGE" >&2
        exit 64
      fi
      if [ -z "${2:-}" ] || case "$2" in --*) true;; *) false;; esac; then
        echo "error: --start-phase requires <n> (non-negative integer)" >&2
        echo "$BH_USAGE" >&2
        exit 64
      fi
      BH_START_PHASE="$2"
      shift 2
      ;;
    --start-phase=*)
      if [ "$BH_MODE" = "materialize" ]; then
        echo "error: --start-phase is not valid in materialize mode" >&2
        echo "$BH_USAGE" >&2
        exit 64
      fi
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
  printf 'BH_MODE=%s\nBH_MAT_PATH=%s\nBH_FLOOR=%s\nBH_FLOOR_FROM_CLI=%s\nBH_PROCEED=%s\nBH_REPORT_DIR=%s\n' \
    "$BH_MODE" "$BH_MAT_PATH" "$BH_FLOOR" "$BH_FLOOR_FROM_CLI" "$BH_PROCEED" "$BH_REPORT_DIR"
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
  _bh_stem_base="$BH_STEM"
  _bh_stem_n=2
  BH_REPORT="$BH_REPORT_DIR/${BH_STEM}.md"
  BH_FINDINGS="$BH_REPORT_DIR/${BH_STEM}.json"
  BH_PLAN="$BH_REPORT_DIR/${BH_STEM}-plan.md"
  while [ -e "$BH_REPORT" ] || [ -e "$BH_FINDINGS" ] || [ -e "$BH_PLAN" ]; do
    BH_STEM="${_bh_stem_base}-${_bh_stem_n}"
    BH_REPORT="$BH_REPORT_DIR/${BH_STEM}.md"
    BH_FINDINGS="$BH_REPORT_DIR/${BH_STEM}.json"
    BH_PLAN="$BH_REPORT_DIR/${BH_STEM}-plan.md"
    _bh_stem_n=$((_bh_stem_n + 1))
    if [ "$_bh_stem_n" -gt 99 ]; then
      echo "error: stem collision limit at $BH_REPORT_DIR/$_bh_stem_base" >&2
      echo "$BH_USAGE" >&2
      exit 64
    fi
  done

  printf 'BH_MODE=%s\nBH_PATH=%s\nBH_FLOOR=%s\nBH_FLOOR_FROM_CLI=%s\nBH_SLUG=%s\nBH_DATE=%s\nBH_STEM=%s\nBH_REPORT_DIR=%s\nBH_REPORT=%s\nBH_FINDINGS=%s\nBH_PLAN=%s\nBH_PROCEED=%s\nBH_START_PHASE=%s\n' \
    "$BH_MODE" "$BH_PATH" "$BH_FLOOR" "$BH_FLOOR_FROM_CLI" "$BH_SLUG" "$BH_DATE" "$BH_STEM" \
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
| `/bug-hunt handoff x-plan.md --proceed` | **exit 64** + `--proceed is not valid in handoff mode` |
| `/bug-hunt handoff x-plan.md --severity-floor critical` | **exit 64** + `--severity-floor is not valid in handoff mode` |
| `/bug-hunt materialize x.json --start-phase 0` | **exit 64** + `--start-phase is not valid in materialize mode` |
| materialize path outside `$MROOT/.claude/bug-hunt/` | **exit 64** + `materialize path outside .claude/bug-hunt/` |
| same-day stem already on disk | `BH_STEM` gains `-2`, `-3`, … (no overwrite) |
| `--start-phase` integer `n >= phase_count` | **exit 64** at S4e (`out of range`) |
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

