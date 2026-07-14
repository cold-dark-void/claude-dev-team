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
# cross-reviewer, phase4-brief, judge.
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
# Pure bash + grep/sed/sort/comm. Invoke: bash skills/council/check-template-vars.sh

set -u

# --- Resolve repo root robustly (script may be run from repo root by /release) ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

COUNCIL="$ROOT/commands/council.md"
SKILL="$ROOT/skills/council/SKILL.md"
PROMPT_DIR="$ROOT/skills/council/prompts"

COVERED="claim-extractor plan-extractor investigator topic-classifier cross-reviewer phase4-brief judge"
DEFERRED=""

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

# Extract the {{VARS}} a prompt DECLARES, from its `## Variables` table only.
# Authoritative rows are table rows of the form: | `{{VAR}}` | ... |
# Restricting to backtick-wrapped table cells avoids false positives from
# prose/examples elsewhere in the section.
prompt_vars() {
  local file="$1"
  sed -n '/^## Variables/,/^## /p' "$file" \
    | grep -E '^\|[[:space:]]*`\{\{[A-Z_]+\}\}`' \
    | grep -oE '\{\{[A-Z_]+\}\}' \
    | sort -u
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
    | grep -oE '\{\{[A-Z_]+\}\}' \
    | sort -u
}

# Extract the {{VARS}} skills/council/SKILL.md DOCUMENTS for a given prompt.
# In the "Documented variables per template" table the row is:
#   | `<name>.md` | `{{VAR}}`, `{{VAR}}`, ... |
# Match the row whose first cell is exactly the backtick-wrapped `<name>.md`,
# then pull the {{VARS}} from that single row.
skill_vars() {
  local name="$1"
  grep -E "^\|[[:space:]]*\`${name}\.md\`[[:space:]]*\|" "$SKILL" \
    | grep -oE '\{\{[A-Z_]+\}\}' \
    | sort -u
}

status=0

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
    status=2
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

  status=1
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
    status=2
    continue
  fi

  declared="$(prompt_vars "$pfile")"
  if [ -z "$declared" ]; then
    echo "FAIL[$name]: no {{VARS}} found in the prompt's ## Variables table ($pfile)" >&2
    status=2
    continue
  fi

  # (A) runtime substitution contract — commands/council.md
  compare_source "$name" "DRIFT"       "$declared" "$(council_subs "$name")"
  # (B) documented contract — skills/council/SKILL.md
  compare_source "$name" "SKILL-DRIFT" "$declared" "$(skill_vars "$name")"
done

if [ "$status" -eq 0 ]; then
  echo "PASS: all covered council prompts (${COVERED}) match in council.md AND SKILL.md."
else
  echo "FAIL: council template-variable contract has drifted (see above)." >&2
fi

exit "$status"
