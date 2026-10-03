#!/usr/bin/env bash
# check-template-vars.sh — council prompt template-variable drift-gate (SPEC-013).
#
# Contract enforced (recurrence-prevention for the dead-sub / literal-leak class):
#   Each prompt's own `## Variables` table is authoritative (SPEC-013). For each
#   COVERED prompt, TWO downstream sources MUST name exactly that var set:
#     (A) commands/council.md  — the `with substitutions:` block following the
#         prompt's `prompt:` line (the runtime substitution contract).
#     (B) skills/council/SKILL.md — the prompt's row in the "Documented variables
#         per template" table (the documented contract).
#   Both halves are MUSTs in SPEC-013; both are enforced here.
#
#   For either source, relative to the authoritative prompt table:
#   - A var in the prompt table but not in the source  -> LITERAL LEAK /
#     undocumented var ({{VAR}} reaches the spawned subagent unsubstituted, or
#     SKILL.md fails to document a real var).
#   - A var in the source but not in the prompt table  -> DEAD SUBSTITUTION /
#     documented var with no backing declaration.
#
# Covered prompts: claim-extractor, plan-extractor, investigator, topic-classifier,
# cross-reviewer, phase4-brief, judge, blind-scribe (council --blind reviewers),
# quorum-analyst (--blind path, CDT-46-C3), tier-triage (shared grading
# procedure, commands/council.md §§ 1.5.2–1.5.4; ship-gate numstat, not a
# /council --diff auto-grade).
# unconstrained-reviewer and lens-reviewer stay uncovered here: bug-hunt owns
# those tool-using prompts. Council --blind does not substitute them.
#
# phase4-brief.md is the merged Phase-4 template (AUDIT-P1-4C-1) that replaced
# the former prosecutor.md + advocate.md. It is referenced in council.md TWICE
# (the Prosecutor spawn and the Devil's Advocate spawn) — both substitution
# blocks name the SAME var set with different values. council_subs() therefore
# collects the UNION of {{VARS}} across ALL substitution blocks naming a given
# prompt (see its comment), so a multi-spawn template is validated against every
# block, not just the first.
#
# Exit 0  -> all covered prompts match in BOTH sources.
# Exit 1  -> at least one covered prompt drifted (readable diff printed).
#              DRIFT[<name>]       = council.md substitution drift.
#              SKILL-DRIFT[<name>] = SKILL.md documented-table drift.
# Exit 2  -> structural failure (a covered block or table could not be located).
#
# Pure bash + grep/sed/sort/comm + gen-template-vars.sh (the one ## Variables
# reader). Invoke: bash skills/council/check-template-vars.sh
#
# COUNCIL_TEMPLATE_ROOT / COUNCIL_TEMPLATE_COVERED override the tree (tests).

set -u

# --- Resolve repo root robustly (script may be run from repo root by /release) ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GEN="$SCRIPT_DIR/gen-template-vars.sh"
if [ -n "${COUNCIL_TEMPLATE_ROOT:-}" ]; then
  ROOT="$COUNCIL_TEMPLATE_ROOT"
else
  ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
fi

COUNCIL="$ROOT/commands/council.md"
SKILL="$ROOT/skills/council/SKILL.md"
PROMPT_DIR="$ROOT/skills/council/prompts"

# WP 7-05 split: the documented-variables table lives in schemas.md; grep the
# concatenated skill body so the documented contract is found wherever the
# router or a stage file carries it.
SKILL_BODY=$(mktemp "${TMPDIR:-/tmp}/council-skill-body.XXXXXX")
cat "$ROOT"/skills/council/SKILL.md "$ROOT"/skills/council/model-map.md \
  "$ROOT"/skills/council/invocation-contract.md "$ROOT"/skills/council/phases-0-2.md \
  "$ROOT"/skills/council/phases-blind.md "$ROOT"/skills/council/phases-4-5.md \
  "$ROOT"/skills/council/phases-6-7.md "$ROOT"/skills/council/schemas.md \
  "$ROOT"/skills/council/reference.md > "$SKILL_BODY"

COVERED="${COUNCIL_TEMPLATE_COVERED:-claim-extractor plan-extractor investigator topic-classifier cross-reviewer phase4-brief judge blind-scribe quorum-analyst tier-triage}"
# Prompts workflow.js loadPrompt / extractVars actually fills.
WF_COVERED="claim-extractor plan-extractor investigator cross-reviewer phase4-brief judge"
DEFERRED=""
# Same class as gen-template-vars.sh and engine.sh finalize ([A-Z0-9_]+).
VAR_RE='\{\{[A-Z0-9_]+\}\}'

# Loud, unmissable note ONLY when coverage is partial by design (no-silent-caps).
if [ -n "$DEFERRED" ]; then
  echo "NOTE: council template-var gate DEFERS (does not check): ${DEFERRED}" >&2
fi

for f in "$COUNCIL" "$SKILL"; do
  if [ ! -f "$f" ]; then
    echo "FAIL: required file not found: $f" >&2
    exit 2
  fi
done

# Declared vars come from gen-template-vars.sh (the ## Variables reader).
prompt_vars() {
  bash "$GEN" vars "$1"
}

# Extract the {{VARS}} commands/council.md SUBSTITUTES for a given prompt.
# A substitution block runs from a `prompt: skills/council/prompts/<name>.md`
# line up to (and not including) the next code-fence line (```).
#
# UNION across ALL such blocks: a prompt may be spawned multiple times (e.g.
# phase4-brief.md as both Prosecutor and Devil's Advocate). Each `prompt:`
# line for <name> re-arms collection (`grab=1`), so the {{VARS}} from every
# matching block are gathered and sort -u'd into one set. Both phase4-brief
# blocks name the identical var set, so the union equals each block's set;
# collecting the union is the robust choice whether the two spawns share one
# fenced block or are split into two.
council_subs() {
  local name="$1"
  awk -v name="$name" '
    # Match a prompt: line for this exact prompt (allow leading whitespace).
    # Re-arms on every matching block -> union across all spawns of <name>.
    $0 ~ ("prompt:[[:space:]]*skills/council/prompts/" name "\\.md") { grab=1; next }
    grab && /^[[:space:]]*```/ { grab=0 }
    grab { print }
  ' "$COUNCIL" \
    | grep -oE "$VAR_RE" \
    | sort -u
}

# Extract the {{VARS}} skills/council/SKILL.md DOCUMENTS for a given prompt.
# In the "Documented variables per template" table the row is:
#   | `<name>.md` | `{{VAR}}`, `{{VAR}}`, ... |
# Match the row whose first cell is exactly the backtick-wrapped `<name>.md`,
# then pull the {{VARS}} from that single row.
skill_vars() {
  local name="$1"
  grep -E "^\|[[:space:]]*\`${name}\.md\`[[:space:]]*\|" "$SKILL_BODY" \
    | grep -oE "$VAR_RE" \
    | sort -u
}

# Keys workflow.js passes to loadPrompt / the plan-vs-claim extractVars arms.
workflow_vars() {
  local name="$1"
  local wf="$ROOT/skills/council/workflow.js"
  [ -f "$wf" ] || return 0
  awk -v name="$name" '
    function take(line) {
      if (match(line, /^[[:space:]]*([A-Z][A-Z0-9_]*)[[:space:]]*:/, m)) print "{{" m[1] "}}"
    }
    function bump(line) {
      depth += gsub(/\{/, "{", line)
      depth -= gsub(/\}/, "}", line)
      if (depth <= 0) { grab=0; depth=0; cur="" }
    }
    BEGIN { grab=0; depth=0; cur=""; arm="" }
    {
      if (grab) {
        if (cur == name) take($0)
        bump($0)
        next
      }
      if (match($0, /loadPrompt\('"'"'([A-Za-z0-9-]+)'"'"'/, m)) {
        cur=m[1]; grab=1; depth=0; bump($0); next
      }
      if ($0 ~ /extractPromptName === .plan-extractor./) { arm="plan-extractor"; next }
      if (arm=="plan-extractor" && $0 ~ /\{/) {
        cur="plan-extractor"; grab=1; depth=0; bump($0); arm="claim-extractor"; next
      }
      if (arm=="claim-extractor" && $0 ~ /\{/) {
        cur="claim-extractor"; grab=1; depth=0; bump($0); arm=""; next
      }
    }
  ' "$wf" | sort -u
}

# {{VARS}} in a report template.
template_vars() {
  grep -oE "$VAR_RE" "$1" | sort -u
}

# Keys of the finalize subs dict in engine.sh (L-10 split: it lives in
# engine-finalize.sh now).
engine_sub_vars() {
  local f
  for f in "$ROOT/skills/council/engine.sh" "$ROOT/skills/council/engine-finalize.sh"; do
    [ -f "$f" ] || continue
    awk '/^subs = \{/,/^\}/' "$f" \
      | grep -oE "$VAR_RE" \
      | sort -u
  done | sort -u
}

status=0

# Keep the worst status. A later drift (1) must not hide an earlier structural miss (2).
raise_status() {
  local n="$1"
  if [ "$n" -gt "$status" ]; then
    status="$n"
  fi
}

# compare_source <name> <label> <declared-set> <source-set>
#   declared = authoritative prompt-table var set
#   source   = the downstream set (council.md subs OR SKILL.md doc row)
# Sets status=1 and prints a labeled diff on any mismatch; prints OK otherwise.
compare_source() {
  local name="$1" label="$2" declared="$3" source="$4"
  local src_desc src_noun
  case "$label" in
    DRIFT)       src_desc="council.md substitutions"; src_noun="substituted in council.md" ;;
    SKILL-DRIFT) src_desc="SKILL.md documented-variables table"; src_noun="documented in SKILL.md" ;;
    *)           src_desc="$label"; src_noun="present in $label" ;;
  esac

  if [ -z "$source" ]; then
    echo "FAIL[$name]: no var set found in $src_desc" >&2
    raise_status 2
    return
  fi

  # leak = declared by prompt but absent from source (literal leak / undocumented)
  # dead = present in source but not declared by prompt (dead sub / phantom doc)
  local leak dead
  leak="$(comm -23 <(printf '%s\n' "$declared") <(printf '%s\n' "$source"))"
  dead="$(comm -13 <(printf '%s\n' "$declared") <(printf '%s\n' "$source"))"

  if [ -z "$leak" ] && [ -z "$dead" ]; then
    echo "OK[$name/$label]: $(printf '%s ' $declared)"
    return
  fi

  raise_status 1
  echo "${label}[$name]: $src_desc does not match the prompt's ## Variables table" >&2
  if [ -n "$leak" ]; then
    while IFS= read -r v; do
      [ -n "$v" ] && echo "  MISSING  $v : declared in $name.md but NOT $src_noun" >&2
    done <<EOF
$leak
EOF
  fi
  if [ -n "$dead" ]; then
    while IFS= read -r v; do
      [ -n "$v" ] && echo "  EXTRA    $v : $src_noun but NOT declared in $name.md" >&2
    done <<EOF
$dead
EOF
  fi
}

for name in $COVERED; do
  pfile="$PROMPT_DIR/$name.md"
  if [ ! -f "$pfile" ]; then
    echo "FAIL[$name]: prompt file not found: $pfile" >&2
    raise_status 2
    continue
  fi

  if ! declared="$(prompt_vars "$pfile")"; then
    echo "FAIL[$name]: generator failed for $pfile" >&2
    raise_status 2
    continue
  fi
  if [ -z "$declared" ]; then
    echo "FAIL[$name]: no {{VARS}} found in the prompt's ## Variables table ($pfile)" >&2
    raise_status 2
    continue
  fi

  # (A) runtime substitution contract — commands/council.md
  compare_source "$name" "DRIFT"       "$declared" "$(council_subs "$name")"
  # (B) documented contract — skills/council/SKILL.md
  compare_source "$name" "SKILL-DRIFT" "$declared" "$(skill_vars "$name")"
done

# workflow.js variable sets. Required on the real tree; optional in a fixture
# that does not ship workflow.js (COUNCIL_TEMPLATE_COVERED is set).
if [ -z "${COUNCIL_TEMPLATE_COVERED:-}" ] || [ -f "$ROOT/skills/council/workflow.js" ]; then
  if [ ! -f "$ROOT/skills/council/workflow.js" ]; then
    echo "FAIL: workflow.js not found: $ROOT/skills/council/workflow.js" >&2
    raise_status 2
  else
    for name in $WF_COVERED; do
      case " $COVERED " in
        *" $name "*) ;;
        *) continue ;;
      esac
      pfile="$PROMPT_DIR/$name.md"
      [ -f "$pfile" ] || continue
      if ! declared="$(prompt_vars "$pfile")"; then
        raise_status 2
        continue
      fi
      compare_source "$name" "WF-DRIFT" "$declared" "$(workflow_vars "$name")"
    done
  fi
fi

# Report templates: every {{VAR}} must be a key of engine.sh's subs dict.
if [ -z "${COUNCIL_TEMPLATE_COVERED:-}" ] || [ -d "$ROOT/skills/council/templates" ]; then
  eng_subs=""
  if [ -f "$ROOT/skills/council/engine.sh" ]; then
    eng_subs="$(engine_sub_vars)"
  fi
  if [ -z "$eng_subs" ]; then
    echo "FAIL: engine.sh subs dict not found" >&2
    raise_status 2
  else
    for tmpl in "$ROOT/skills/council/templates"/report-*.md; do
      [ -f "$tmpl" ] || continue
      tname="$(basename "$tmpl")"
      tvars="$(template_vars "$tmpl")"
      if [ -z "$tvars" ]; then
        echo "FAIL[$tname]: no {{VARS}} in report template" >&2
        raise_status 2
        continue
      fi
      leak="$(comm -23 <(printf '%s\n' "$tvars") <(printf '%s\n' "$eng_subs"))"
      if [ -z "$leak" ]; then
        echo "OK[$tname/REPORT]: $(printf '%s ' $tvars)"
      else
        raise_status 1
        echo "REPORT-DRIFT[$tname]: template var is not in engine.sh subs" >&2
        printf '%s\n' "$leak" | while IFS= read -r v; do
          [ -n "$v" ] && echo "  MISSING  $v : in $tname but NOT in engine.sh subs" >&2
        done
      fi
    done
  fi
fi

if [ "$status" -eq 0 ]; then
  echo "PASS: all covered council prompts (${COVERED}) match in council.md AND SKILL.md."
else
  echo "FAIL: council template-variable contract has drifted (see above)." >&2
fi

exit "$status"
