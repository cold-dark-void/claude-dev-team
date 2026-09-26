---
name: handoff
description: Session handoff STM packet (compact seed) — cold /handoff <uuid> reconstructs a past session via spine-mine (State now → Through-line → appendix), prints core + path; warm bare /handoff mines this session, writes a packet file only. Optional slug: positional or --slug. Warm re-capture delta-mines since cached leaf unless --full. Use as /compact @packet after /branch or /fork — not a compact replacement.
argument-hint: "[<session-uuid>] [<slug>] | --slug <slug> | --full | --light | --miner-model | --help"
agent: build
---

# /handoff

Parent stub (M19): parse → discover → prepare → `plan.mode`. Detach is **one-turn lag**; parent stub stays **session tier**. `agent: build` does not detach.

## Step 1: Parse arguments

```bash
UUID=""; SLUG=""; SHOW_USAGE=0; WARM=0; LIGHT=0
MINER_MODEL_FLAG=""; UNKNOWN=""; POSITIONAL=()
: "${HANDOFF_FULL:=0}"; : "${HANDOFF_LIGHT:=0}"
ARGS=$(cat <<'HANDOFF_ARGS'
$ARGUMENTS
HANDOFF_ARGS
)
set -f; set -- $ARGS; set +f
if [ "$#" -eq 0 ]; then WARM=1
else
  while [ "$#" -gt 0 ]; do
    case "$1" in
      -h|--help) SHOW_USAGE=1; shift ;;
      --full) HANDOFF_FULL=1; shift ;;
      --light) HANDOFF_LIGHT=1; LIGHT=1; shift ;;
      --slug)
        [ -n "${2:-}" ] || { echo "error: --slug requires a value" >&2; exit 1; }
        SLUG="$2"; shift 2 ;;
      --slug=*) SLUG="${1#--slug=}"; shift ;;
      --miner-model)
        case "${2:-}" in ""|-*) echo "error: --miner-model requires a value" >&2; exit 1 ;; esac
        MINER_MODEL_FLAG="$2"; shift 2 ;;
      --miner-model=*)
        MINER_MODEL_FLAG="${1#--miner-model=}"
        [ -n "$MINER_MODEL_FLAG" ] || { echo "error: --miner-model requires a value" >&2; exit 1; }
        shift ;;
      --*) UNKNOWN="$1"; SHOW_USAGE=1; shift ;;
      *) POSITIONAL+=("$1"); shift ;;
    esac
  done
  [ "${#POSITIONAL[@]}" -ge 1 ] && UUID="${POSITIONAL[0]}"
  [ "${#POSITIONAL[@]}" -ge 2 ] && [ -z "$SLUG" ] && SLUG="${POSITIONAL[1]}"
  [ -z "$UUID" ] && WARM=1
fi
export HANDOFF_FULL
if [ "$SHOW_USAGE" = "1" ]; then
  [ -n "$UNKNOWN" ] && echo "unknown flag: $UNKNOWN" >&2
  cat <<'USAGE'
  /handoff <session-uuid> [slug]
  /handoff [--slug <slug>]
  /handoff --full [--slug <s>]
  /handoff --light [--slug <s>]
  /handoff --miner-model <fast|balanced|max|alias>
  /handoff --help
USAGE
  exit 0
fi
# M10c: --light is warm-only (AC-2).
if [ "$LIGHT" = "1" ] && [ "$WARM" != "1" ]; then
  echo "error: --light is warm-only (use bare /handoff --light; not with a session uuid)" >&2
  echo "Warm-only — not valid with a session uuid" >&2
  exit 1
fi
[ -n "${MINER_MODEL_FLAG:-}" ] && export HANDOFF_MINER_MODEL="$MINER_MODEL_FLAG"
if [ "$LIGHT" = "1" ]; then
  export HANDOFF_LIGHT=1
  export HANDOFF_MINER_MODEL="${HANDOFF_MINER_MODEL:-haiku}"
  export HANDOFF_SPINE_TOKENS="${HANDOFF_SPINE_TOKENS:-40000}"
  export SKIP_ANNOTATION=1
  export LIGHT=1
else
  export HANDOFF_LIGHT="${HANDOFF_LIGHT:-0}"
  export LIGHT=0
  export SKIP_ANNOTATION="${SKIP_ANNOTATION:-0}"
fi
# lint-ok: C3
PDH=$( { [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -f "$CLAUDE_PLUGIN_ROOT/skills/plugin-dir.sh" ] && printf '%s\n' "$CLAUDE_PLUGIN_ROOT"; } || { [ -f skills/plugin-dir.sh ] && pwd; } || { _pr='${CLAUDE_PLUGIN_ROOT}'; [ -f "$_pr/skills/plugin-dir.sh" ] && printf '%s\n' "$_pr"; } || { for _mp in "$HOME"/.claude/plugins/marketplaces/*/; do [ -f "${_mp}skills/plugin-dir.sh" ] && [ -f "${_mp}agents/pm.md" ] && printf '%s\n' "${_mp%/}" && break; done; } || find ~/.claude/plugins/cache -path '*/dev-team/*/skills/plugin-dir.sh' 2>/dev/null | awk -F/ '{ver=""; for(i=1;i<=NF;i++) if($i=="dev-team"&&i<NF){ver=$(i+1);break}; if(ver=="") next; m=ver; gsub(/-pre\./,"~pre.",m); p=($0 ~ /\/cache\/cold-dark-void\/dev-team\//)?1:0; print m "\t" p "\t" $0}' | sort -t $'\t' -k1,1V -k2,2n -k3,3 | tail -1 | cut -f3 | xargs -r dirname | xargs -r dirname )
P="$PDH/skills/plugin-dir.sh"
PREPASS=$(bash "$P" file skills/handoff/prepass.sh)
DISCOVER=$(bash "$P" file skills/handoff/discover-warm.sh)
RESOLVE=$(bash "$P" file skills/handoff/resolve-root.sh)
SKILL=$(bash "$P" file skills/handoff/SKILL.md)
LIGHT_PROFILE=$(bash "$P" file skills/handoff/LIGHT.md)
PLANFIELDS=$(bash "$P" file skills/handoff/plan-fields.py)
[ -x "$PREPASS" ] || { echo "error: skills/handoff/prepass.sh not found in the installed plugin cache" >&2; exit 1; }
E=$(mktemp)
if [ "$HANDOFF_LIGHT" = "1" ] || [ "$LIGHT" = "1" ]; then SKILL="$LIGHT_PROFILE"; fi
if [ "$WARM" != "1" ]; then
  case "$UUID" in
    [0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]-[0-9a-f][0-9a-f][0-9a-f][0-9a-f]-[0-9a-f][0-9a-f][0-9a-f][0-9a-f]-[0-9a-f][0-9a-f][0-9a-f][0-9a-f]-[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]) ;;
    *) echo "error: session-uuid must be a UUID (e.g. 00000000-0000-4000-8000-000000000004)" >&2; exit 1 ;;
  esac
fi
if [ "$WARM" = "1" ]; then
  set +e; DISC_OUT=$(bash "$DISCOVER" 2>"$E"); DISC_RC=$?; set -e
  [ "$DISC_RC" -eq 0 ] || { cat "$E" >&2; exit 1; }
  SESSION_ID=$(printf '%s\n' "$DISC_OUT" | sed -n '1p')
  TRANSCRIPT=$(printf '%s\n' "$DISC_OUT" | sed -n '2p')
  UUID="$SESSION_ID"
  [ -n "$SESSION_ID" ] && [ -n "$TRANSCRIPT" ] && [ -f "$TRANSCRIPT" ] || { echo "error: warm discovery returned empty path" >&2; exit 1; }
  HANDOFF_MODE="warm"
  PREPARE_EXTRA=(--transcript "$TRANSCRIPT" --allow-in-progress)
else
  HANDOFF_MODE="cold"
  PREPARE_EXTRA=()  # no --transcript, no --allow-in-progress (M9/M14)
fi
set +e
if [ "$HANDOFF_MODE" = "warm" ]; then ROOT_OUT=$(bash "$RESOLVE" --transcript "$TRANSCRIPT" 2>"$E")
else ROOT_OUT=$(bash "$RESOLVE" --uuid "$UUID" 2>"$E"); fi
ROOT_RC=$?; set -e
if [ "$ROOT_RC" -ne 0 ] || [ -z "$ROOT_OUT" ]; then
  cat "$E" >&2
  echo "error: cannot resolve target project root for session $UUID (refuse invoker-cwd write)" >&2
  exit 1
fi
PROJECT_DIR=$(printf '%s\n' "$ROOT_OUT" | sed -n '1p')
MROOT=$(printf '%s\n' "$ROOT_OUT" | sed -n '2p')
HANDOFF_DIR=$(printf '%s\n' "$ROOT_OUT" | sed -n '3p')
export HANDOFF_DIR MROOT PROJECT_DIR
if [ "$HANDOFF_MODE" != "warm" ]; then
  set +e; CACHED=$("$PREPASS" cache-check --uuid "$UUID" 2>"$E"); CACHE_RC=$?; set -e
  [ "$CACHE_RC" -eq 0 ] && { echo "$CACHED"; echo "(served from cache — session unchanged)"; exit 0; }
  [ "$CACHE_RC" -eq 10 ] || { cat "$E" >&2; exit "$CACHE_RC"; }
fi
PRIOR_EVENTS_FILE=""
if [ "$HANDOFF_MODE" = "warm" ] && [ "$HANDOFF_FULL" != "1" ] \
   && [ -n "$HANDOFF_DIR" ] && [ -n "$UUID" ]; then
  _CACHE_FILE="$HANDOFF_DIR/cache/${UUID}.json"
  if [ -f "$_CACHE_FILE" ]; then
    PRIOR_LEAF=$(PRIOR_CACHE="$_CACHE_FILE" python3 - <<'PYDELTA'
import json,os,sys
try:
    data=json.load(open(os.environ["PRIOR_CACHE"],encoding="utf-8"))
except (OSError,ValueError):
    sys.exit(0)
if not isinstance(data,dict): sys.exit(0)
leaf=data.get("leaf_uuid") or ""
if not isinstance(leaf,str) or not leaf.strip(): sys.exit(0)
ev=data.get("events")
if not isinstance(ev,dict) or not ev: sys.exit(0)
# M10c defense (CDT-91): light:true cache → no-prior (primary path never writes this)
if data.get("light") in (True,1,"true","1"): sys.exit(0)
if any(isinstance(v,list) and v for v in ev.values()): print(leaf.strip())
PYDELTA
)
    [ -n "${PRIOR_LEAF:-}" ] && { PREPARE_EXTRA+=(--since-leaf "$PRIOR_LEAF"); PRIOR_EVENTS_FILE="$_CACHE_FILE"; }
  fi
fi
[ "$HANDOFF_FULL" = "1" ] && PRIOR_EVENTS_FILE=""
export PRIOR_EVENTS_FILE
[ -n "$PRIOR_EVENTS_FILE" ] && export FINALIZE_PRIOR_EVENTS="$PRIOR_EVENTS_FILE" || unset FINALIZE_PRIOR_EVENTS 2>/dev/null || true
WORK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/handoff.XXXXXX") \
  || { echo "handoff error: mktemp -d failed for WORK_DIR"; exit 1; }
PLAN_JSON="$WORK_DIR/plan.json"; EVENTS_DIR="$WORK_DIR/events"; mkdir -p "$EVENTS_DIR"
set +e
"$PREPASS" prepare --uuid "$UUID" --out "$PLAN_JSON" "${PREPARE_EXTRA[@]}" >/dev/null 2>"$E"
PREP_RC=$?; set -e
if [ "$PREP_RC" -eq 9 ]; then echo "in-progress (transcript modified < 60 s ago) — too-fresh (M9)"; exit 0; fi
[ "$PREP_RC" -eq 0 ] || { cat "$E" >&2; echo "error: prepare failed" >&2; exit 1; }
FIELDS=$(python3 "$PLANFIELDS" "$PLAN_JSON" "$HANDOFF_DIR/.live-session.json" 2>"$E") \
  || { cat "$E" >&2; echo "error: plan-fields failed" >&2; exit 1; }
MODE=$(printf '%s\n' "$FIELDS" | sed -n '1p')
SLA=$(printf '%s\n' "$FIELDS" | sed -n '2p')
ET=$(printf '%s\n' "$FIELDS" | sed -n '3p')
HOST=$(printf '%s\n' "$FIELDS" | sed -n '4p')
SPINE=$(printf '%s\n' "$FIELDS" | sed -n '5p')
[ "$SLA" = "true" ] || { PRIOR_EVENTS_FILE=""; unset FINALIZE_PRIOR_EVENTS 2>/dev/null || true; }
echo "plan.mode=$MODE"
echo "PLAN_JSON=$PLAN_JSON WORK_DIR=$WORK_DIR SPINE=$SPINE EVENTS_DIR=$EVENTS_DIR SKILL=$SKILL PRIOR_EVENTS_FILE=$PRIOR_EVENTS_FILE"
echo "SESSION_ID=$SESSION_ID TRANSCRIPT=$TRANSCRIPT HOST=$HOST HANDOFF_MODE=$HANDOFF_MODE UUID=$UUID SLUG=$SLUG"
echo "HANDOFF_FULL=$HANDOFF_FULL HANDOFF_LIGHT=$HANDOFF_LIGHT HANDOFF_MINER_MODEL=$HANDOFF_MINER_MODEL HANDOFF_SPINE_TOKENS=$HANDOFF_SPINE_TOKENS SKIP_ANNOTATION=$SKIP_ANNOTATION"
echo "HANDOFF_DIR=$HANDOFF_DIR MROOT=$MROOT PROJECT_DIR=$PROJECT_DIR"
# Miner-tier advisory (CDT-203, print-only). Skip: prepare failed, no plan.json, missing/non-numeric tokens, or cold cache-HIT.
# mode==direct AND est_tokens < 30000 vs chunked
case "$ET" in ''|*[!0-9]*|0) ;; *)
  if [ "$MODE" = "chunked" ] || { [ "$MODE" = "direct" ] && [ "$ET" -ge 30000 ]; }; then echo "keep session tier"
  elif [ "$MODE" = "direct" ] && [ "$ET" -lt 30000 ]; then echo "fast tier is likely sufficient for this mine"; fi ;;
esac
```

`--help` / unknown flag → usage, exit 0, before PDH/discover (inline above).

## Step 2: Locate the engine + skill

Engines resolve via `plugin-dir.sh`. `--light` selects `skills/handoff/LIGHT.md`; else `skills/handoff/SKILL.md`. No Read on direct. Fail hard if missing.

## Step 3: Discover, resolve-root, cache, prepare

Folded into Step 1 (M19.11): discover (warm) → resolve-root (CDT-80) → cheap gates (uuid-shape, discover miss, resolve-root fail, too-fresh (M9), cache-HIT) → prepare. No spawn.

## Orchestrator spawn

`mode=direct` + can spawn → **one background agent**. Parent MUST NOT Read `skills/handoff/SKILL.md` or `LIGHT.md`. Parent stays session tier. `HANDOFF_MINER_MODEL`: exact `fast|balanced|max` → host cell; else passthrough as-is; empty omit `model` to **inherit**. Claude: fast→haiku, balanced→sonnet, max inherit (omit). Grok identity (fast→fast). Host reject → fail-soft inherit. Claude `Task` + resolved `model:`. Grok: host-equivalent one background agent (`spawn_subagent`), same prompt.

```
subagent_type: general-purpose
```

```
Read skills/handoff/SKILL.md or skills/handoff/LIGHT.md from disk (absolute $SKILL). Execute remaining pipeline for:
  SESSION_ID=… TRANSCRIPT=… HOST=… HANDOFF_MODE=… SLUG=…
  HANDOFF_FULL=… HANDOFF_LIGHT=… HANDOFF_MINER_MODEL=… (alias as given)
  HANDOFF_SPINE_TOKENS=… SKIP_ANNOTATION=… UUID=…
  HANDOFF_DIR=… MROOT=… PROJECT_DIR=…
  PLAN_JSON=… WORK_DIR=… SPINE=… EVENTS_DIR=… PRIOR_EVENTS_FILE=…
You ARE the merged miner (write through_line.json + state.json; one spine read).
Bare warm: you ARE annotation (inline). Light/cold: skip annotation.
MUST NOT nest Task. MUST NOT re-run discover-warm.sh.
Final report: cold → State now + Through-line + packet path; warm → path only
(+ light nudge if light).
```

TMPDIR Grok JSONL must exist. Parent MUST NOT `rm -rf $WORK_DIR` before completion. Cold MISS: relay M7.

## In-session fallback

If `plan.mode=chunked` or spawn unavailable (host cannot spawn): MUST NOT spawn the detached agent. MUST NOT fail the capture. Parent MAY Read `$SKILL` / `$LIGHT_PROFILE` (`skills/handoff/SKILL.md` or `LIGHT.md`). Execute remaining pipeline in this turn: git capture; parallel N chunk-summarizers (one tool-use block); one miner Task; annotation Task if bare warm; finalize. Do not detach.

Bare-warm chunk + annotation (skip light/cold/`SKIP_ANNOTATION=1`):

```
subagent_type: general-purpose
model: haiku
```
