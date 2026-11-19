#!/usr/bin/env bash
# spawn-site-test.sh — CDT-226/CDT-229 static contract for SPEC-037 M15/M14/M16/M12/M29/AC2.
# Greps committed templates/docs only (no network, no LLM).
# Run: bash skills/model-map/spawn-site-test.sh
set -u

HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT=$(CDPATH= cd -- "$HERE/../.." && pwd)

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $*"; }

# M13 ∪ M16 spawn sites (SPEC-037 M15): must mention resolve-model.sh + host-reject.
SITES='
skills/orchestrate/steps/04-kickoff.md
skills/orchestrate/steps/06-design.md
skills/orchestrate/steps/08-execute.md
skills/orchestrate/steps/09-review.md
skills/orchestrate/steps/10-qa.md
skills/post-approve-polish/SKILL.md
skills/ci-watch/SKILL.md
skills/kickoff/SKILL.md
skills/epic/mode-a-decompose.md
skills/debug/SKILL.md
skills/fix-ticket/SKILL.md
skills/council/model-map.md
commands/council.md
skills/bug-hunt/s1-discover.md
skills/bug-hunt/s2-refute.md
'

# M16 negatives: must not mention resolve-model.sh (handoff miner stays unwired).
NEGATIVES='
commands/handoff.md
'

# M12 roster (SPEC-003 § Tier table). Values are YAML tokens: name:model:effort.
ROSTER='
tech-lead:opus:high
council-judge:opus:high
council-scribe:opus:high
debugger:opus:high
ds:opus:medium
pm:opus:medium
ic5:sonnet:xhigh
qa:sonnet:high
finder:sonnet:high
devops:sonnet:medium
ic4:sonnet:medium
project-init:sonnet:low
distiller:haiku:low
advisor:opus:high
'

frontmatter_key() {
  awk -v key="$2" '
    BEGIN { n=0; pat = "^" key ":[[:space:]]*" }
    /^---[[:space:]]*$/ {
      n++
      if (n == 2) exit
      next
    }
    n == 1 && $0 ~ pat {
      sub(pat, "")
      gsub(/[[:space:]]+$/, "")
      gsub(/^["'\'']|["'\'']$/, "")
      print
      exit
    }
  ' "$1"
}

# Strip full-line comments. Docs/comments may mention the map path.
code_lines() {
  grep -vE '^[[:space:]]*(#|$)' "$1"
}

# resolve-model.sh: > / mkdir targeting $MAP or models.local.json (SPEC-037 M10).
resolve_write_hits() {
  code_lines "$1" | grep -E \
    -e '(>|>>|[[:space:]]tee[[:space:]]+)[[:space:]]*("|'\'')?(\$MAP|\$\{MAP\}|[^[:space:]]*models\.local\.json)' \
    -e 'mkdir.*(\$MAP|\$\{MAP\}|models\.local\.json|\.claude/dev-team)' \
    || true
}

# Other production .sh: redirect onto the literal map filename only ($MAP is
# a common unrelated variable). Test harnesses write temp fixtures — skip.
tree_redirect_hits() {
  code_lines "$1" | grep -E \
    '(>|>>|[[:space:]]tee[[:space:]]+)[[:space:]]*[^[:space:]]*models\.local\.json' \
    || true
}

# ---- M15 + M14: every M13 site has resolve-model.sh and host-reject prose ----
for rel in $SITES; do
  f="$ROOT/$rel"
  if [ ! -f "$f" ]; then
    bad "M15 missing $rel"
    continue
  fi
  if grep -qF 'resolve-model.sh' "$f"; then
    ok
  else
    bad "M15 $rel lacks resolve-model.sh"
  fi
  if grep -qF 'retry once' "$f" && grep -qF 'host rejected' "$f"; then
    ok
  else
    bad "M14 $rel lacks host-reject language (retry once / host rejected)"
  fi
  # M29: effort fence + M28 host-reject language
  if grep -qF 'resolve-model.sh --effort' "$f"; then
    ok
  else
    bad "M29 $rel lacks resolve-model.sh --effort"
  fi
  if grep -qF 'host rejected effort' "$f"; then
    ok
  else
    bad "M29 $rel lacks host-reject language (host rejected effort)"
  fi
done

# ---- M16 negatives: handoff miner must not wire the resolver ----
for rel in $NEGATIVES; do
  f="$ROOT/$rel"
  if [ ! -f "$f" ]; then
    bad "M16 missing $rel"
    continue
  fi
  if grep -qF 'resolve-model.sh' "$f"; then
    bad "M16 $rel must not contain resolve-model.sh"
  else
    ok
  fi
done
HANDOFF_DIR="$ROOT/skills/handoff"
if [ ! -d "$HANDOFF_DIR" ]; then
  bad "M16 missing skills/handoff/"
else
  HANDOFF_HITS=$(grep -rlF 'resolve-model.sh' "$HANDOFF_DIR" 2>/dev/null || true)
  if [ -n "$HANDOFF_HITS" ]; then
    bad "M16 skills/handoff/ must not contain resolve-model.sh:"$'\n'"$HANDOFF_HITS"
  else
    ok
  fi
fi

# ---- M12: agents/*.md frontmatter model: + effort: match the Tier table ----
for triple in $ROSTER; do
  name=${triple%%:*}
  rest=${triple#*:}
  want_model=${rest%%:*}
  want_effort=${rest#*:}
  f="$ROOT/agents/${name}.md"
  if [ ! -f "$f" ]; then
    bad "M12 missing agents/${name}.md"
    continue
  fi
  got=$(frontmatter_key "$f" model)
  if [ "$got" = "$want_model" ]; then
    ok
  else
    bad "M12 agents/${name}.md model:'${got}' want '${want_model}'"
  fi
  got=$(frontmatter_key "$f" effort)
  if [ "$got" = "$want_effort" ]; then
    ok
  else
    bad "M29 agents/${name}.md effort:'${got}' want '${want_effort}'"
  fi
done

# ---- M12: finder / debugger tool floor — read-only, never Write or Edit ----
for name in finder debugger; do
  f="$ROOT/agents/${name}.md"
  got=$(frontmatter_key "$f" tools)
  if [ "$got" = "Read, Grep, Glob, Bash, SendMessage" ]; then
    ok
  else
    bad "M12 agents/${name}.md tools:'${got}' want 'Read, Grep, Glob, Bash, SendMessage'"
  fi
  if printf '%s' "$got" | grep -qE '(^|[[:space:],])(Write|Edit)([[:space:],]|$)'; then
    bad "M12 agents/${name}.md must not have Write or Edit"
  else
    ok
  fi
done

# ---- AC2 / M10: resolve-model.sh must not write or mkdir the map ----
RESOLVE="$HERE/resolve-model.sh"
if [ ! -f "$RESOLVE" ]; then
  bad "AC2 missing resolve-model.sh"
else
  hits=$(resolve_write_hits "$RESOLVE")
  if [ -z "$hits" ]; then
    ok
  else
    bad "AC2 resolve-model.sh writes/mkdirs the map:"$'\n'"$hits"
  fi
fi

# Tree-wide: production skills/**/*.sh (not test harnesses) must not redirect
# onto models.local.json except write-model.sh (the local writer). Fixture
# tests write a temp map; skip those.
TREE_BAD=""
while IFS= read -r sh; do
  base=$(basename "$sh")
  case "$base" in
    test.sh|*-test.sh|test-*.sh|write-model.sh) continue ;;
  esac
  hits=$(tree_redirect_hits "$sh")
  [ -z "$hits" ] && continue
  rel=${sh#"$ROOT/"}
  TREE_BAD="${TREE_BAD}${rel}"$'\n'"${hits}"$'\n'
done < <(find "$ROOT/skills" -name '*.sh' -type f | sort)
if [ -z "$TREE_BAD" ]; then
  ok
else
  bad "AC2 skills/**/*.sh redirect onto models.local.json:"$'\n'"$TREE_BAD"
fi

# ---- council-judge tools: "" unchanged ----
CJ="$ROOT/agents/council-judge.md"
if [ -f "$CJ" ] && grep -qE '^tools:[[:space:]]*""[[:space:]]*$' "$CJ"; then
  ok
else
  bad "M12 agents/council-judge.md tools: \"\" must stay empty"
fi

# ---- Kickoff ranges: explorer MUST fence; Step 4b MUST NOT ----
KICKOFF="$ROOT/skills/kickoff/SKILL.md"
heading_range() {
  # Print from first line matching $2 until the next ## heading (exclusive).
  awk -v start="$2" '
    $0 ~ start { p=1; print; next }
    p && /^## / { exit }
    p { print }
  ' "$1"
}
if [ -f "$KICKOFF" ]; then
  EXPL=$(heading_range "$KICKOFF" '### Codebase Explorer')
  if printf '%s\n' "$EXPL" | grep -qF 'resolve-model.sh'; then
    ok
  else
    bad "kickoff Codebase Explorer range must contain resolve-model.sh"
  fi
  if printf '%s\n' "$EXPL" | grep -qF 'resolve-model.sh --effort'; then
    ok
  else
    bad "kickoff Codebase Explorer range must contain resolve-model.sh --effort"
  fi
  if printf '%s\n' "$EXPL" | grep -qF 'host rejected'; then
    ok
  else
    bad "kickoff Codebase Explorer range must contain host-reject language"
  fi
  STEP4B=$(heading_range "$KICKOFF" '^## Step 4b:')
  if printf '%s\n' "$STEP4B" | grep -qF 'resolve-model.sh'; then
    bad "kickoff Step 4b range must not contain resolve-model.sh"
  else
    ok
  fi
else
  bad "kickoff SKILL.md missing for explorer resolve-model.sh"
  bad "kickoff SKILL.md missing for explorer --effort"
  bad "kickoff SKILL.md missing for explorer host-reject"
  bad "kickoff SKILL.md missing for Step 4b omit"
fi

# ---- No source of resolve-model.sh in SITES; last resolve cmd is printf ----
for rel in $SITES; do
  f="$ROOT/$rel"
  [ -f "$f" ] || continue
  src_hits=$(code_lines "$f" | grep -E 'source[[:space:]]+[^#[:space:]].*resolve-model\.sh' || true)
  if [ -n "$src_hits" ]; then
    bad "M5 $rel sources resolve-model.sh (must subprocess):"$'\n'"$src_hits"
  else
    ok
  fi
  printf_miss=$(awk '
    function is_blank_or_comment(s) { return s ~ /^[[:space:]]*(#|$)/ }
    /MODEL=\$\(bash / && /resolve-model\.sh|\$RESOLVE|\$\{RESOLVE\}/ {
      pending=1
      next
    }
    pending {
      if (is_blank_or_comment($0)) next
      if ($0 ~ /^[[:space:]]*printf '\''%s\\n'\'' "\$MODEL"/) { pending=0; next }
      printf "line %d: %s\n", NR, $0
      pending=0
    }
  ' "$f")
  if [ -n "$printf_miss" ]; then
    bad "M13 $rel resolve fence last cmd is not printf '%s\\n' \"\$MODEL\":"$'\n'"$printf_miss"
  else
    ok
  fi
done

# ---- SPEC-042 model-pin fence (CDT-641 T5; AC1/AC4/AC5/AC6/AC8) ------------
#
# Deterministic, LLM-free scan of the SPEC-042 M1 covered set:
#   * Task-path spawn blocks in the six council files
#   * the five skills/council/workflow.js agent() entries
#   * the M14 gate-recipe Phase-4 dispatch prose
# Every covered block carries an explicit model pin per the SPEC-042 M2 grammar.
# An unparseable or unrecognizable covered block is a finding, not a pass
# (fail-closed, M6). Waiver: "# lint-ok: <id>" on the finding line or the line
# above (SPEC-021 grammar). Check ids are SPEC-042 MUST ids (M1/M2/M3/M4/M5/M6/M7/
# M8) — C7 is reserved by SPEC-021 and is not used here.
TIER_SPEC="$ROOT/specs/core/SPEC-003-agent-role-system.md"
MAPPABLE_SH="$HERE/mappable-names.sh"

# Covered Task-path markdown files (SPEC-042 M1 home files + the gate recipe).
COVERED_MD='
commands/council.md
skills/council/model-map.md
skills/council/phases-0-2.md
skills/council/phases-4-5.md
skills/council/phases-blind.md
skills/council/SKILL.md
skills/autopilot/ship-gate-council.md
'
WF_JS='skills/council/workflow.js'

# Mappable role set (SPEC-037 M8): the roles the Model map can resolve (P1).
mappable_list_of() {
  bash "$1" --list 2>/dev/null | tr '\n' ' '
}

# Tier-default model of a roster role (SPEC-003 § Tier table — SoT, AC8).
tier_of() {
  awk -F'|' -v a="$1" '{
    k = $2; gsub(/[ `]/, "", k)
    if (k == a) { v = $3; gsub(/[ `]/, "", v); print v; exit }
  }' "$TIER_SPEC"
}

# Emit "FIND|<id>|<line>|<message>" lines for a findings blob; count them.
# Findings are reported, never swallowed (fail-closed).
report_findings() {
  n=0
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    n=$((n+1))
    bad "$(printf '%s' "$f" | cut -d'|' -f2- | tr '|' ' ')"
  done <<EOF
$1
EOF
  [ "$n" -eq 0 ] && ok
  return 0
}

# Markdown fence scanner: every fenced block that carries a spawn signature
# (`subagent_type:`) is a covered spawn block and must carry a pin per M2.
MD_SCAN_PROG='
BEGIN { n = split(mappable, m, /[[:space:]]+/); for (i = 1; i <= n; i++) if (m[i] != "") MAPPABLE[m[i]] = 1 }
function trim(s) { gsub(/^[[:space:]]+/, "", s); gsub(/[[:space:]]+$/, "", s); return s }
function has_waiver(id, ln,   k, s, rest, w, wn, i) {
  for (k = ln - 1; k <= ln; k++) {
    if (k < 1) continue
    s = line[k]
    if (s !~ /(^|[[:space:]])(#|<!--)[[:space:]]*lint-ok:/) continue
    if (match(s, /lint-ok:.*/) == 0) continue
    rest = substr(s, RSTART + 8)
    wn = split(rest, w, /[^A-Za-z0-9_]+/)
    for (i = 1; i <= wn; i++) if (w[i] == id) return 1
  }
  return 0
}
function role_of(l) {
  if (match(l, /dev-team:[A-Za-z0-9_<>.+-]+/)) return substr(l, RSTART + 9, RLENGTH - 9)
  return ""
}
function pin_value(l,   v) {
  v = l
  sub(/^[[:space:]]*model[[:space:]]*:[[:space:]]*/, "", v)
  sub(/[[:space:]]*#.*$/, "", v)
  gsub(/^["\047]|["\047][[:space:]]*$/, "", v)
  return trim(v)
}
function scan_block(a, b,   i, l, nsp, npin, oos, cls, role, v) {
  nsp = 0; npin = 0; delete sl; delete pl
  for (i = a; i <= b; i++) {
    l = line[i]
    if (l ~ /^[[:space:]]*subagent_type[[:space:]]*:/) { nsp++; sl[nsp] = i }
    if (l ~ /^[[:space:]]*model[[:space:]]*:/) { npin++; pl[npin] = i }
  }
  if (nsp == 0) return
  oos = 1
  for (i = 1; i <= nsp; i++) if (line[sl[i]] ~ /dev-team:/) oos = 0
  if (npin < nsp && !has_waiver("M1", sl[npin + 1]))
    printf "FIND|M1|%d|%s: covered spawn block has %d spawn line(s) and %d model pin(s) — every covered spawn carries an explicit pin (SPEC-042 M1/M2)\n", sl[npin + 1], rel, nsp, npin
  for (i = 1; i <= npin; i++) {
    l = line[pl[i]]; v = pin_value(l)
    role = (i <= nsp) ? role_of(line[sl[i]]) : ""
    if (v == "") {
      if (!has_waiver("M2", pl[i])) printf "FIND|M2|%d|%s: empty model pin — an unrecognizable pin is a finding (SPEC-042 M2)\n", pl[i], rel
      continue
    }
    if (v == "sonnet" || v == "opus" || v == "haiku") cls = "LITERAL"
    else if (v == "<MODEL>" || v == "$MODEL" || v == "${MODEL}") cls = "MAP"
    else {
      if (!has_waiver("M2", pl[i])) printf "FIND|M2|%d|%s: model pin %s is outside the SPEC-042 M2 grammar (sonnet | opus | haiku | <MODEL>)\n", pl[i], rel, v
      continue
    }
    if (oos) { printf "OOS|%d|%s|%s\n", pl[i], (role == "" ? "general-purpose" : role), v; continue }
    if (cls == "MAP") {
      if (l !~ /empty/ || (l !~ /sonnet/ && l !~ /opus/)) {
        if (!has_waiver("M2", pl[i])) printf "FIND|M2|%d|%s: map-resolved pin carries no Tier-alias floor (empty stdout -> alias); an empty map is not omit at council sites (SPEC-042 M2)\n", pl[i], rel
        continue
      }
      if (role != "" && !(role in MAPPABLE) && role !~ /^<[^>]+>$/) {
        if (!has_waiver("M2", pl[i])) printf "FIND|M2|%d|%s: map-resolved pin on role %s, which the Model map cannot resolve (absent from mappable-names.sh --list)\n", pl[i], rel, role
        continue
      }
      printf "COVER|%d|P1|%s\n", pl[i], role
    } else {
      if (v != "sonnet") {
        if (!has_waiver("M2", pl[i])) printf "FIND|M2|%d|%s: literal council-site pin %s is outside the P2 policy value (scribe-class pins the literal sonnet, SPEC-042 M2)\n", pl[i], rel, v
        continue
      }
      if (role != "" && (role in MAPPABLE)) {
        if (!has_waiver("M2", pl[i])) printf "FIND|M2|%d|%s: literal pin on map-resolved role %s — a mappable role uses the P1 fence (SPEC-042 M2)\n", pl[i], rel, role
        continue
      }
      printf "COVER|%d|P2|%s\n", pl[i], role
    }
  }
}
{ line[NR] = $0 }
END {
  infence = 0
  for (i = 1; i <= NR; i++) {
    if (line[i] !~ /^```/) continue
    if (infence) { scan_block(f_start, i - 1); infence = 0 }
    else { infence = 1; f_start = i + 1 }
  }
  if (infence) printf "FIND|M6|%d|%s: unterminated code fence — the covered spawn set is not parseable (fail-closed)\n", NR, rel
}
'

md_pin_scan() {
  awk -v rel="$2" -v mappable="$MAPPABLE_LIST" "$MD_SCAN_PROG" "$1"
}

# Fenced block that carries the locator line (spawn-shape enumeration).
fence_with() {
  awk -v loc="$2" '
    /^```/ {
      if (infence) { if (hit) for (j = 1; j <= n; j++) print bl[j]; infence = 0; n = 0; hit = 0 }
      else { infence = 1; n = 0; hit = 0 }
      next
    }
    infence { bl[++n] = $0; if ($0 ~ loc) hit = 1 }
    END { if (infence && hit) for (j = 1; j <= n; j++) print bl[j] }
  ' "$1"
}

# Section from the locator line to the next heading of the same or a shallower
# level (prose enumeration). A non-heading locator stops at the next "## ".
# Fence-aware: a "# …" comment inside a code fence is not a heading.
section_from() {
  awk -v start="$2" '
    /^```/ { infence = 1 - infence }
    !p && !infence && $0 ~ start {
      p = 1
      if (match($0, /^#+/)) stopre = "^#{1," RLENGTH "} "
      else stopre = "^## "
      print; next
    }
    p && !infence && $0 ~ stopre { exit }
    p { print }
  ' "$1"
}

# P1 prose grammar: a resolver/canonical fence + the Tier-default alias floor.
has_p1_prose() {
  printf '%s\n' "$1" | grep -qE 'resolve-model\.sh|canonical fence' \
    && printf '%s\n' "$1" | grep -qF 'Tier-default alias' \
    && printf '%s\n' "$1" | grep -qE '(^|[^[:alnum:]])(sonnet|opus)([^[:alnum:]]|$)'
}

has_p2_prose() {
  printf '%s\n' "$1" | grep -qF 'model: sonnet'
}

# Knob scope (SPEC-042 M5): COUNCIL_PHASE4_MODEL is read by the Phase-4 dispatch
# sites only. Every naming line sits inside the file's Phase-4 section — the M14
# gate recipe is the only writer, so no other council site may reference it.
knob_scope_findings() {
  kn_tot=$(grep -cF 'COUNCIL_PHASE4_MODEL' "$1")
  kn_in=$(section_from "$1" '^### Phase 4' | grep -cF 'COUNCIL_PHASE4_MODEL')
  [ "$kn_tot" = "$kn_in" ] \
    || printf 'FIND|M5|0|%s: %s of %s COUNCIL_PHASE4_MODEL lines sit outside the Phase-4 section — the knob consumer is scoped to the Phase-4 brief dispatches\n' "$2" "$((kn_tot - kn_in))" "$kn_tot"
}

# Flattened markdown paragraphs (blank-line separated) that carry the M4
# host-reject retry rule. Lines are joined so a wrapped phrase matches as
# written.
host_reject_paragraphs() {
  awk '
    function flush(para,   q) {
      if (para == "") return
      q = para
      gsub(/[[:space:]]+/, " ", q)
      if (q ~ /sibling alias/ && q ~ /retr(y|ies)/) print q
    }
    { if ($0 ~ /^[[:space:]]*$/) { flush(para); para = ""; next } para = para " " $0 }
    END { flush(para) }
  ' "$1"
}

# M4 pin==sibling carve-out: host-reject prose that names the P2 pin must also
# state that a P2 site performs no retry and no warn — its pin value already is
# its sibling alias, so the retry value equals the rejected value.
p2_carveout_findings() {
  case "$1" in
    /*) cf=$1 ;;
    *) cf="$ROOT/$1" ;;
  esac
  if [ ! -f "$cf" ]; then
    printf 'FIND|M4|0|%s: file missing — the M4 carve-out check cannot run (fail-closed)\n' "$2"
    return 0
  fi
  cparas=$(host_reject_paragraphs "$cf")
  if [ -z "$cparas" ]; then
    printf 'FIND|M4|0|%s: no host-reject sibling-alias prose found — the M4 carve-out check cannot run (fail-closed)\n' "$2"
    return 0
  fi
  printf '%s\n' "$cparas" | grep -qE '\(P2\)|P2 pin|P2 site' || return 0
  tr '\n' ' ' < "$cf" | grep -qE 'no retry and( emits)? no warn' \
    || printf 'FIND|M4|0|%s: host-reject prose names the P2 pin with no pin==sibling carve-out — a P2 pin already equals its sibling alias, so it performs no retry and no warn and degrades per the site failure path (SPEC-042 M4)\n' "$2"
}

# One covered-site manifest row: rel|locator|kind|class|label.
# kind: fence (spawn block) | section (prose section).
# class: P1 | P2 | P2KNOB | P1P2 | INV | ROUTER | GATE.
# P2KNOB is a P2 pin that is also the COUNCIL_PHASE4_MODEL consumer (SPEC-042 M5).
manifest_row() {
  rel=$1; loc=$2; kind=$3; cls=$4; label=$5
  case "$1" in
    /*) f=$1 ;;
    *) f="$ROOT/$rel" ;;
  esac
  if [ ! -f "$f" ]; then
    printf 'FIND|M1|0|%s: covered file missing\n' "$rel"
    return 0
  fi
  if [ "$kind" = fence ]; then body=$(fence_with "$f" "$loc"); else body=$(section_from "$f" "$loc"); fi
  # Prose tokens may wrap across lines; flatten so a phrase matches as written.
  # An empty body stays empty: that is the "site not found" finding.
  if [ "$kind" != fence ] && [ -n "$body" ]; then body=$(printf '%s\n' "$body" | tr '\n' ' '); fi
  if [ -z "$body" ]; then
    printf 'FIND|M1|0|%s: covered site "%s" not found — the covered spawn block is unparseable (fail-closed)\n' "$rel" "$label"
    return 0
  fi
  case "$cls" in
    P1)
      if [ "$kind" = fence ]; then
        printf '%s\n' "$body" | grep -qE '^[[:space:]]*model:[[:space:]]*(<MODEL>|\$\{?MODEL\}?)([^[:alnum:]]|$)' \
          || printf 'FIND|M2|0|%s: site "%s" carries no map-resolved pin (SPEC-042 M2 P1)\n' "$rel" "$label"
      else
        has_p1_prose "$body" \
          || printf 'FIND|M2|0|%s: site "%s" carries no P1 pin (resolver/canonical fence + Tier-default alias)\n' "$rel" "$label"
      fi
      ;;
    P2)
      printf '%s\n' "$body" | grep -qE 'model:[[:space:]]*sonnet([^[:alnum:]]|$)' \
        || printf 'FIND|M2|0|%s: site "%s" carries no P2 literal sonnet pin (SPEC-042 M2)\n' "$rel" "$label"
      ;;
    P2KNOB)
      printf '%s\n' "$body" | grep -qE 'model:[[:space:]]*sonnet([^[:alnum:]]|$)' \
        || printf 'FIND|M2|0|%s: site "%s" carries no P2 literal sonnet pin (SPEC-042 M2)\n' "$rel" "$label"
      # The Phase-4 pin is a default, not a constant: the site must consume the
      # COUNCIL_PHASE4_MODEL escalation the gate recipe exports (SPEC-042 M5).
      for tok in 'COUNCIL_PHASE4_MODEL' '{sonnet, opus}' 'only writer' 'stderr warning'; do
        printf '%s\n' "$body" | grep -qF "$tok" \
          || printf 'FIND|M5|0|%s: site "%s" is missing the Phase-4 knob consumer token "%s" (SPEC-042 M5)\n' "$rel" "$label" "$tok"
      done
      ;;
    P1P2)
      has_p1_prose "$body" \
        || printf 'FIND|M2|0|%s: site "%s" carries no P1 pin (resolver/canonical fence + Tier-default alias)\n' "$rel" "$label"
      has_p2_prose "$body" \
        || printf 'FIND|M2|0|%s: site "%s" carries no P2 literal sonnet pin (SPEC-042 M2)\n' "$rel" "$label"
      ;;
    INV)
      for tok in 'Explicit model pin' 'Tier-default alias' 'literal' 'sibling alias' 'sonnet'; do
        printf '%s\n' "$body" | grep -qF "$tok" \
          || printf 'FIND|M2|0|%s: site "%s" is missing the pin invariant token "%s"\n' "$rel" "$label" "$tok"
      done
      ;;
    ROUTER)
      printf '%s\n' "$body" | grep -qF 'Model pins' \
        || printf 'FIND|M2|0|%s: site "%s" is missing the Model pins router row\n' "$rel" "$label"
      printf '%s\n' "$body" | grep -qF 'model-map.md' \
        || printf 'FIND|M2|0|%s: site "%s" does not route to model-map.md\n' "$rel" "$label"
      ;;
    GATE)
      for tok in 'model: sonnet' 'COUNCIL_PHASE4_MODEL' 'closed set'; do
        printf '%s\n' "$body" | grep -qF "$tok" \
          || printf 'FIND|M2|0|%s: site "%s" is missing the gate pin token "%s" (SPEC-042 M5)\n' "$rel" "$label" "$tok"
      done
      printf '%s\n' "$body" | grep -qiF 'prosecutor' \
        || printf 'FIND|M1|0|%s: site "%s" does not name the prosecutor dispatch\n' "$rel" "$label"
      printf '%s\n' "$body" | grep -qF "Devil" \
        || printf 'FIND|M1|0|%s: site "%s" does not name the Devil'\''s Advocate dispatch\n' "$rel" "$label"
      ;;
    *)
      printf 'FIND|M6|0|%s: site "%s" has an unknown class %s (fail-closed)\n' "$rel" "$label" "$cls"
      ;;
  esac
}

# Covered-site manifest (SPEC-042 M1). Every row is one covered spawn block;
# a row that cannot be located is a finding.
MANIFEST='
commands/council.md|Extract claims from session|fence|P2|Phase 1 extractor (session/diff)
commands/council.md|Extract claims from plan|fence|P2|Phase 1 extractor (plan)
commands/council.md|Investigate claim|fence|P1|Phase 2 investigator + fallback chain
commands/council.md|Cross-review evidence bundles|fence|P2|Phase 2.5 cross-reviewer
commands/council.md|Classify claim topic|fence|P2|Phase 3 classifier (scribe-class)
commands/council.md|Domain specialist investigation|fence|P1|Phase 3 specialist
commands/council.md|Prosecute claims against evidence|fence|P2KNOB|Phase 4 prosecutor
commands/council.md|Defend claims with evidence|fence|P2KNOB|Phase 4 Devil'\''s Advocate
commands/council.md|Judge claims from evidence|fence|P1|Phase 5 judge (+ bundle-cap parts)
commands/council.md|Blind review unconstrained|fence|P2|--blind team wave
commands/council.md|Blind review lens|fence|P2|--blind lens wave
commands/council.md|Blind review quorum analysis|fence|P2|--blind quorum analyst
commands/council.md|Council tier triage|fence|GATE-OOS|1.5.3 triage call (non-council)
skills/council/model-map.md|^### Extractor |section|P2|Phase 1 extractor fence
skills/council/model-map.md|^### Investigator |section|P1|Phase 2 investigator fence
skills/council/model-map.md|^### Cross-reviewer |section|P2|Phase 2.5 cross-reviewer fence
skills/council/model-map.md|^### Classifier and specialist |section|P1P2|Phase 3 classifier + specialist
skills/council/model-map.md|^### Prosecutor and Devil|section|P2|Phase 4 briefs fence
skills/council/model-map.md|^### Judge |section|P1|Phase 5 judge fence
skills/council/model-map.md|^### Blind reviewers |section|P2|--blind waves fence
skills/council/phases-0-2.md|^### Phase 1 |section|P2|Phase 1 stage body
skills/council/phases-0-2.md|^### Phase 2 |section|P1|Phase 2 stage body
skills/council/phases-4-5.md|^### Phase 3 |section|P1P2|Phase 3 stage body
skills/council/phases-4-5.md|^### Phase 4 |section|P2KNOB|Phase 4 stage body
skills/council/phases-4-5.md|^### Phase 5 |section|P1|Phase 5 stage body
skills/council/phases-blind.md|^### Blind-review path|section|P2|--blind reviewer + quorum wave
skills/council/phases-blind.md|^### Phase 2.5 |section|P2|--blind cross-review wave
skills/council/SKILL.md|^## Invariants|section|INV|Pin invariant
skills/council/SKILL.md|Model pins .SPEC-037|section|ROUTER|Router row to model-map.md
skills/autopilot/ship-gate-council.md|Phase-4 brief model pin|section|GATE|M14 gate Phase-4 dispatch
'

# workflow.js agent() entries: every safeAgent site is a covered block and must
# carry a model pin whose value is a pin-time expression (M3 grammar).
WF_SCAN_PROG='
function trim(s) { gsub(/^[[:space:]]+/, "", s); gsub(/[[:space:]]+$/, "", s); return s }
/await safeAgent\(/ { site = NR; incall = 1; hasm = 0; hasrole = 0; ph = ""; mv = ""; next }
incall {
  if ($0 ~ /^[[:space:]]*}[[:space:]]*\)[[:space:]]*,?[[:space:]]*$/) {
    total++
    if (!hasm) printf "FIND|M3|%d|workflow.js: covered agent() entry (phase %s) passes no model pin (SPEC-042 M3)\n", site, ph
    else if (mv != "SCRIBE_MODEL_PIN" && mv !~ /^PIN_ALIAS\[/ && mv !~ /^mapModel\(/)
      printf "FIND|M3|%d|workflow.js: model pin %s in phase %s is outside the M3 pin grammar (SCRIBE_MODEL_PIN | PIN_ALIAS[...] | mapModel(...))\n", site, mv, ph
    else printf "COVER|%d|WF|%s\n", site, ph
    if (!hasrole) printf "FIND|M3|%d|workflow.js: covered agent() entry (phase %s) names no agentType — the covered role is unparseable (fail-closed)\n", site, ph
    pinned[ph] = (hasm && mv != "") ? 1 : 0
    seen[ph] = 1
    incall = 0
    next
  }
  if ($0 ~ /^[[:space:]]*model[[:space:]]*:/) {
    hasm = 1; v = $0
    sub(/^[[:space:]]*model[[:space:]]*:[[:space:]]*/, "", v)
    sub(/,[[:space:]]*$/, "", v)
    mv = trim(v)
  }
  if ($0 ~ /^[[:space:]]*agentType[[:space:]]*:/) hasrole = 1
  if ($0 ~ /^[[:space:]]*phase[[:space:]]*:/) {
    v = $0; sub(/^[[:space:]]*phase[[:space:]]*:[[:space:]]*/, "", v)
    gsub(/[,\047[:space:]]/, "", v); ph = v
  }
}
END {
  if (incall) printf "FIND|M6|%d|workflow.js: safeAgent opts block never closes — not parseable (fail-closed)\n", site
  printf "TOTAL|%d\n", total + 0
  split("Extract Investigate Cross-review Phase4 Judge", req, " ")
  for (i = 1; i <= 5; i++) {
    r = req[i]
    if (!(r in seen)) printf "FIND|M3|0|workflow.js: covered agent() entry %s is absent from the workflow (fail-closed)\n", r
    else if (!pinned[r]) printf "FIND|M3|0|workflow.js: covered agent() entry %s is unpinned\n", r
  }
}
'

wf_pin_scan() {
  awk "$WF_SCAN_PROG" "$1"
}

# Code-only copy of a JS file: line and block comments stripped (AC6 reads).
js_code() {
  sed -e 's://.*::' -e 's/^[[:space:]]*\*.*//' "$1"
}

# Workflow-path effort param (AC6 boundary): code only, "best-effort" prose out.
wf_effort_hits() {
  js_code "$1" | grep -nE '\beffort\b' | grep -v 'best-effort' || true
}

# Direct agent() calls outside the safeAgent seam (fail-closed enumeration).
# agent\([^)] keeps prose mentions of "agent()" out of the count.
wf_direct_agent_calls() {
  js_code "$1" | grep -nE '(^|[^A-Za-z0-9_$.])agent\([^)]' | grep -v 'safeAgent(' || true
}

# Pin-time alias tables: the Workflow-path PIN_ALIAS object and the council
# model-map P1 table. Both must equal the SPEC-003 § Tier table (M7).
pin_alias_rows() {
  sed -n '/^export const PIN_ALIAS = {/,/^}/p' "$1" \
    | sed -n "s/^[[:space:]]*'\{0,1\}\([a-z-]*\)'\{0,1\}:[[:space:]]*'\{0,1\}\([a-z]*\)'\{0,1\},.*/\1 \2/p"
}

map_alias_rows() {
  awk '/^[[:space:]]*\|[[:space:]]*P1 role /{ t = 1; next } t && !/^[[:space:]]*\|/ { t = 0 } t { print }' "$1" \
    | awk -F'|' 'NF >= 3 {
        r = $2; a = $3
        gsub(/[ `\t]/, "", r); gsub(/[ `\t]/, "", a)
        if (r != "" && r !~ /^-+$/ && r != "P1 role") print r, a
      }'
}

# Parity of one alias table against the Tier table (AC8 / SPEC-042 M7).
# council-scribe is the M7-exempt policy pin: sonnet, not its Tier row (opus).
alias_parity_findings() {
  rows=$1; label=$2
  while IFS=' ' read -r role alias; do
    [ -n "$role" ] || continue
    want=$(tier_of "$role")
    if [ -z "$want" ]; then
      printf 'FIND|M7|0|%s: role %s has no SPEC-003 § Tier row — unrecognizable alias-table entry\n' "$label" "$role"
      continue
    fi
    if [ "$role" = council-scribe ]; then
      if [ "$alias" != sonnet ] || [ "$want" != opus ]; then
        printf 'FIND|M7|0|%s: scribe policy pin %s (Tier %s) is not the M7-exempt value sonnet\n' "$label" "$alias" "$want"
      fi
      continue
    fi
    [ "$alias" = "$want" ] \
      || printf 'FIND|M7|0|%s: alias %s=%s differs from the SPEC-003 § Tier row (%s)\n' "$label" "$role" "$alias" "$want"
  done <<EOF
$rows
EOF
}

# ---- Covered fenced spawn blocks (M1/M2, fail-closed) ----
MAPPABLE_LIST=$(mappable_list_of "$MAPPABLE_SH")
if [ -z "$MAPPABLE_LIST" ]; then
  bad "M8 mappable-names.sh --list printed nothing — the P1 role set is unresolvable (fail-closed)"
fi
COVERAGE=''
for rel in $COVERED_MD; do
  f="$ROOT/$rel"
  if [ ! -f "$f" ]; then
    bad "M1 covered file missing: $rel"
    continue
  fi
  scan=$(md_pin_scan "$f" "$rel")
  report_findings "$(printf '%s\n' "$scan" | grep '^FIND|' || true)"
  ncover=$(printf '%s\n' "$scan" | grep -c '^COVER|' || true)
  noos=$(printf '%s\n' "$scan" | grep -c '^OOS|' || true)
  COVERAGE="${COVERAGE}COVERAGE $rel: fenced spawn blocks covered=$ncover pinned-out-of-scope=$noos"$'\n'
done

# ---- Covered-site manifest (M1: every covered block enumerated) ----
nman=0
MAN_ROWS=''
man_find=''
while IFS='|' read -r rel loc kind cls label; do
  [ -n "$rel" ] || continue
  case "$rel" in '#'*) continue ;; esac
  nman=$((nman+1))
  if [ "$cls" = GATE-OOS ]; then
    # § 1.5.3 triage spawn: a non-council M13 ∪ M16 site, pinned haiku. It is
    # pinned-out-of-scope, not a covered site (SPEC-042 M4 scope carve-out).
    body=$(fence_with "$ROOT/$rel" "$loc")
    if [ -z "$body" ]; then
      bad "M1 $rel: out-of-scope site $label not found"
    elif printf '%s\n' "$body" | grep -qE '^[[:space:]]*model:[[:space:]]*(sonnet|opus|haiku)([^[:alnum:]]|$)'; then
      ok
    else
      bad "M1 $rel: out-of-scope site $label is unpinned — no site may spawn unpinned"
    fi
    nman=$((nman-1))
    continue
  fi
  MAN_ROWS="$MAN_ROWS$rel"$'\n'
  man_find=$(manifest_row "$rel" "$loc" "$kind" "$cls" "$label")
  report_findings "$man_find"
done <<EOF
$MANIFEST
EOF
COVERAGE="${COVERAGE}${MAN_ROWS}"'COVERAGE manifest: covered sites enumerated='"$nman"$'\n'

# ---- Workflow path: the five agent() entries (M3) ----
WFF="$ROOT/$WF_JS"
if [ ! -f "$WFF" ]; then
  bad "M3 missing $WF_JS"
else
  wscan=$(wf_pin_scan "$WFF")
  report_findings "$(printf '%s\n' "$wscan" | grep '^FIND|' || true)"
  nwf=$(printf '%s\n' "$wscan" | grep -c '^COVER|' || true)
  tot=$(printf '%s\n' "$wscan" | grep '^TOTAL|' | cut -d'|' -f2)
  if [ "$tot" = 5 ]; then
    ok
  else
    bad "M3 $WF_JS: enumerated agent() entries $tot (want 5 — Extract, Investigate, Cross-review, Phase4, Judge)"
  fi
  COVERAGE="${COVERAGE}COVERAGE $WF_JS: agent() entries covered=$nwf enumerated=$tot"$'\n'
  # AC6 boundary: no effort param on the Workflow path (SPEC-037 F1; SPEC-042 M8).
  eff=$(wf_effort_hits "$WFF")
  if [ -z "$eff" ]; then
    ok
  else
    bad "M8 $WF_JS carries an effort param (Workflow path stays --effort-free, SPEC-042 M8):"$'\n'"$eff"
  fi
  # Every agent() call goes through the pinned safeAgent seam: exactly one
  # direct call, the callAgent wrapper that hands opts to the host.
  direct=$(wf_direct_agent_calls "$WFF")
  dcount=$(printf '%s\n' "$direct" | grep -c . || true)
  if [ "$dcount" = 1 ] && printf '%s\n' "$direct" | grep -qF 'agent(prompt, opts)'; then
    ok
  else
    bad "M3 $WF_JS: direct agent() call outside the safeAgent seam (every covered entry is pinned there):"$'\n'"$direct"
  fi
fi

# ---- AC3 / M5: the Phase-4 knob consumer is scoped to the Phase-4 sites ----
for rel in commands/council.md skills/council/phases-4-5.md; do
  report_findings "$(knob_scope_findings "$ROOT/$rel" "$rel")"
done

# ---- AC4: host-reject prose at covered sites names the sibling alias ----
# The SKILL.md host-reject paragraph names both pin classes, so it is in scope
# for the pin==sibling carve-out check too.
for rel in commands/council.md skills/council/model-map.md skills/model-map/SKILL.md; do
  f="$ROOT/$rel"
  if [ ! -f "$f" ]; then
    bad "M4 $rel missing"
    continue
  fi
  if grep -qF 'retrying with sibling alias' "$f"; then
    ok
  else
    bad "M4 $rel lacks the sibling-alias host-reject retry prose (SPEC-042 M4)"
  fi
  if grep -qE 'with model omitted' "$f"; then
    bad "M4 $rel still tells a covered site to retry with model omitted (SPEC-042 M4)"
  else
    ok
  fi
  report_findings "$(p2_carveout_findings "$f" "$rel")"
done

# ---- AC8 / M7: pin-time alias tables equal the SPEC-003 Tier table ----
if [ ! -f "$TIER_SPEC" ]; then
  bad "M7 SPEC-003 Tier table missing — alias parity cannot run (fail-closed)"
else
  pa_find=$(alias_parity_findings "$(pin_alias_rows "$WFF")" "workflow.js PIN_ALIAS")
  ma_find=$(alias_parity_findings "$(map_alias_rows "$ROOT/skills/council/model-map.md")" "council model-map P1 table")
  report_findings "$pa_find"
  report_findings "$ma_find"
  for r in finder council-judge council-scribe; do
    if printf '%s\n' "$(pin_alias_rows "$WFF")" | grep -q "^$r "; then
      ok
    else
      bad "M7 workflow.js PIN_ALIAS has no row for $r — the pin-time alias is missing (fail-closed)"
    fi
  done
  for r in finder ic5 devops qa ds pm council-judge; do
    if printf '%s\n' "$(map_alias_rows "$ROOT/skills/council/model-map.md")" | grep -q "^$r "; then
      ok
    else
      bad "M7 council model-map P1 alias table has no row for $r (SPEC-042 M2 P1 floor)"
    fi
  done
  # M8 boundary: the scribe pin is a policy constant, never an alias-table entry.
  if printf '%s\n' "$(map_alias_rows "$ROOT/skills/council/model-map.md")" | grep -q '^council-scribe '; then
    bad "M8 council model-map P1 alias table carries council-scribe — the scribe pin stays out of the map (CDT-654 owns the join)"
  else
    ok
  fi
fi

# ---- AC6 / M8 boundary: council-scribe stays out of the mappable set ----
if [ ! -f "$MAPPABLE_SH" ]; then
  bad "M8 mappable-names.sh missing"
else
  if printf '%s\n' "$MAPPABLE_LIST" | tr ' ' '\n' | grep -qx 'council-scribe'; then
    bad "M8 mappable-names.sh --list contains council-scribe (SPEC-042 M8; CDT-654 owns the join)"
  else
    ok
  fi
fi
if grep -qF 'council-scribe' "$RESOLVE" 2>/dev/null; then
  bad "M8 resolve-model.sh names council-scribe — the resolver must not learn a non-mappable name"
else
  ok
fi

# ---- M6 self-test: defect fixtures bite, clean fixtures pass ----
BITE_DIR=$(mktemp -d "${TMPDIR:-/tmp}/cdt641-spawn-site.XXXXXX") || BITE_DIR=''
if [ -z "$BITE_DIR" ]; then
  bad "M6 defect fixtures could not be created — the fail-closed lint is unverified"
else
  bite() {
    if printf '%s\n' "$2" | grep -q "^FIND|$1|"; then
      ok
    else
      bad "M6 bite $3: expected a $1 finding, got: [$2]"
    fi
  }
  bite_clean() {
    if printf '%s\n' "$1" | grep -q '^FIND|'; then
      bad "M6 bite $2: the clean fixture produced findings: $1"
    else
      ok
    fi
  }

  # Unpinned covered spawn block.
  printf '%s\n' \
    '### Fixture' '' '```' \
    'description: "Fixture spawn"' \
    'subagent_type: "dev-team:council-scribe"' \
    'prompt: skills/council/prompts/fixture.md' \
    '```' > "$BITE_DIR/unpinned.md"
  bite M1 "$(md_pin_scan "$BITE_DIR/unpinned.md" un)" 'unpinned covered block'

  # Same block, waiver on the line above the spawn line: waived, not printed.
  printf '%s\n' \
    '### Fixture' '' '```' \
    'description: "Fixture spawn"' \
    '# lint-ok: M1 — fixture waiver' \
    'subagent_type: "dev-team:council-scribe"' \
    'prompt: skills/council/prompts/fixture.md' \
    '```' > "$BITE_DIR/waived.md"
  bite_clean "$(md_pin_scan "$BITE_DIR/waived.md" wa)" 'lint-ok waiver'

  # Unrecognizable pin value.
  printf '%s\n' \
    '```' \
    'subagent_type: "dev-team:council-scribe"' \
    'model: gpt-4-turbo' \
    '```' > "$BITE_DIR/badvalue.md"
  bite M2 "$(md_pin_scan "$BITE_DIR/badvalue.md" bv)" 'unrecognizable pin value'

  # Map-resolved pin with no Tier-alias floor (empty map would omit).
  printf '%s\n' \
    '```' \
    'subagent_type: "dev-team:finder"' \
    'model: <MODEL>' \
    '```' > "$BITE_DIR/nofloor.md"
  bite M2 "$(md_pin_scan "$BITE_DIR/nofloor.md" nf)" 'P1 pin without the Tier-alias floor'

  # Literal pin on a mappable role (must use the P1 fence).
  printf '%s\n' \
    '```' \
    'subagent_type: "dev-team:finder"' \
    'model: sonnet' \
    '```' > "$BITE_DIR/literalonmap.md"
  bite M2 "$(md_pin_scan "$BITE_DIR/literalonmap.md" lm)" 'literal pin on a mappable role'

  # Clean fixture: the pinned shapes the covered set uses.
  printf '%s\n' \
    '```' \
    'subagent_type: "dev-team:council-scribe"' \
    'model: sonnet                              # P2 pin (SPEC-042 M2)' \
    '```' \
    '```' \
    'subagent_type: "dev-team:council-judge"' \
    'model: <MODEL>                     # P1 pin: fence stdout; empty -> `opus` (Tier alias)' \
    '```' \
    '```' \
    'subagent_type: "general-purpose"' \
    'model: haiku' \
    '```' > "$BITE_DIR/clean.md"
  cscan=$(md_pin_scan "$BITE_DIR/clean.md" cl)
  bite_clean "$cscan" 'clean pinned shapes'
  if [ "$(printf '%s\n' "$cscan" | grep -c '^COVER|' || true)" = 2 ] \
    && [ "$(printf '%s\n' "$cscan" | grep -c '^OOS|' || true)" = 1 ]; then
    ok
  else
    bad "M6 fixture coverage counters wrong: $cscan"
  fi

  # Workflow site with the model pin removed, and a missing covered entry.
  printf '%s\n' \
    "const out = await safeAgent(prompt, {" \
    "  schema: ClaimsSchema," \
    "  agentType: 'dev-team:council-scribe'," \
    "  phase: 'Extract'," \
    '})' > "$BITE_DIR/wf_unpinned.js"
  bite M3 "$(wf_pin_scan "$BITE_DIR/wf_unpinned.js")" 'unpinned workflow agent() entry'

  # Workflow opts block that never closes: unparseable, not a pass.
  printf '%s\n' \
    "const out = await safeAgent(prompt, {" \
    "  agentType: 'dev-team:council-scribe'," \
    "  model: SCRIBE_MODEL_PIN," > "$BITE_DIR/wf_truncated.js"
  bite M6 "$(wf_pin_scan "$BITE_DIR/wf_truncated.js")" 'unparseable workflow opts block'

  # AC6 boundary: an effort param on the Workflow path.
  { cat "$WFF"; printf '%s\n' "const effortParam = { effort: 'high' }"; } > "$BITE_DIR/wf_effort.js"
  if [ -n "$(wf_effort_hits "$BITE_DIR/wf_effort.js")" ]; then
    ok
  else
    bad "M6 bite AC6: an effort param on the Workflow path did not bite"
  fi

  # AC8 parity: an alias that drifted from the Tier table.
  sed 's/^  finder: .sonnet.,/  finder: opus,/' "$WFF" > "$BITE_DIR/wf_alias.js"
  bite M7 "$(alias_parity_findings "$(pin_alias_rows "$BITE_DIR/wf_alias.js")" fixture-alias)" 'alias drift from the Tier table'
  # Scribe policy pin stays exempt from the Tier equality (M7 exemption).
  bite_clean "$(alias_parity_findings "$(pin_alias_rows "$WFF")" fixture-alias)" 'scribe pin exemption'

  # AC6 / M8 boundary: council-scribe joining the mappable set.
  sed 's/^MAPPABLE="pm/MAPPABLE="council-scribe pm/' "$MAPPABLE_SH" > "$BITE_DIR/mappable.sh"
  if printf '%s\n' "$(mappable_list_of "$BITE_DIR/mappable.sh")" | tr ' ' '\n' | grep -qx 'council-scribe'; then
    ok
  else
    bad "M6 bite M8: council-scribe in the mappable set did not bite"
  fi

  # Covered-site manifest: a prose section whose literal pin was stripped, and a
  # covered site that can no longer be located (renamed) — both must bite.
  sed 's/^`model: sonnet` on both extractor shapes/on both extractor shapes/' \
    "$ROOT/skills/council/model-map.md" > "$BITE_DIR/model-map-nopin.md"
  sbody=$(section_from "$BITE_DIR/model-map-nopin.md" '^### Extractor ')
  if ! has_p2_prose "$sbody"; then
    ok
  else
    bad "M6 bite M2: a scribe section with its literal pin stripped still passed"
  fi
  sed 's/^### Extractor /### Extractor renamed /' \
    "$ROOT/skills/council/model-map.md" > "$BITE_DIR/model-map-renamed.md"
  bite M1 "$(manifest_row "$BITE_DIR/model-map-renamed.md" '^### Extractor$' section P2 'Phase 1 extractor fence')" \
    'covered site that cannot be located'

  # SPEC-042 M5: a Phase-4 block that keeps the sonnet pin but drops the knob
  # consumer clause is a finding — the pin must be a consumable default.
  printf '%s\n' \
    '```' \
    'description: "Prosecute claims against evidence"' \
    'subagent_type: "dev-team:council-scribe"' \
    'model: sonnet                              # P2 pin (SPEC-042 M2)' \
    '```' > "$BITE_DIR/phase4_noknob.md"
  bite M5 "$(manifest_row "$BITE_DIR/phase4_noknob.md" 'Prosecute claims against evidence' fence P2KNOB 'Phase 4 briefs')" \
    'Phase-4 dispatch with no knob consumer clause'
  printf '%s\n' \
    '```' \
    '# if COUNCIL_PHASE4_MODEL is set and in {sonnet, opus}, pass it to both briefs;' \
    '# the gate recipe skills/autopilot/ship-gate-council.md §3b is the only writer;' \
    '# any other value is ignored with one stderr warning and the sonnet default.' \
    'description: "Prosecute claims against evidence"' \
    'subagent_type: "dev-team:council-scribe"' \
    'model: sonnet                              # P2 pin (SPEC-042 M2) default' \
    '```' > "$BITE_DIR/phase4_knob.md"
  bite_clean "$(manifest_row "$BITE_DIR/phase4_knob.md" 'Prosecute claims against evidence' fence P2KNOB 'Phase 4 briefs')" \
    'Phase-4 dispatch with the knob consumer clause'

  # M5 knob scope: a knob reader outside the Phase-4 section bites; the clean
  # tree (Phase-4 dispatch sites only) does not.
  { printf '%s\n' '## Notes' '' 'Read COUNCIL_PHASE4_MODEL at the extractor spawn.'; cat "$ROOT/commands/council.md"; } \
    > "$BITE_DIR/knob_scope.md"
  if [ -n "$(knob_scope_findings "$BITE_DIR/knob_scope.md" fixture-knob)" ]; then
    ok
  else
    bad "M6 bite M5: a knob reference outside the Phase-4 section did not bite"
  fi
  bite_clean "$(knob_scope_findings "$ROOT/commands/council.md" commands/council.md)" 'knob scope on the clean tree'

  # SPEC-042 M4 pin==sibling carve-out: host-reject prose that names the P2 pin
  # must carry the carve-out; P1-only prose stays out of scope; a file with no
  # host-reject prose is a finding, not a pass.
  printf '%s\n' \
    '**Host-reject retry (SPEC-042 M4).** A spawn failure attributed to the' \
    'model param retries **once** with the sibling alias — the Tier default' \
    '(P1) or `sonnet` (P2), chosen at pin time — and warns exactly:' \
    '' \
    '`model-map: host rejected model .<string>. for <agent>; retrying with sibling alias .<alias>.`' \
    > "$BITE_DIR/p2_nocarve.md"
  bite M4 "$(p2_carveout_findings "$BITE_DIR/p2_nocarve.md" fixture-p2)" 'P2 host-reject prose with no carve-out'
  printf '%s\n' '' \
    'A P2 pin already equals its sibling alias, so a P2 site performs no retry' \
    'and no warn on a model-attributed reject — it degrades per the site' \
    '(SPEC-042 M4).' >> "$BITE_DIR/p2_nocarve.md"
  bite_clean "$(p2_carveout_findings "$BITE_DIR/p2_nocarve.md" fixture-p2)" 'P2 host-reject prose with the carve-out'

  printf '%s\n' \
    '**Host-reject retry (SPEC-042 M4).** A map-resolved spawn retries once' \
    'with the Tier-default alias as the sibling alias; warn retrying with' \
    'sibling alias .<alias>.' > "$BITE_DIR/p1_only.md"
  bite_clean "$(p2_carveout_findings "$BITE_DIR/p1_only.md" fixture-p1)" 'P1-only host-reject prose needs no carve-out'

  printf '%s\n' 'No spawn prose here — the covered pin text lives elsewhere.' > "$BITE_DIR/no_prose.md"
  bite M4 "$(p2_carveout_findings "$BITE_DIR/no_prose.md" fixture-noprose)" 'file with no host-reject prose'
  rm -rf "$BITE_DIR"
fi

if [ -n "$COVERAGE" ]; then
  printf '%s\n' "$COVERAGE" | awk '
    /^[[:space:]]*$/ { next }
    /^COVERAGE/ { print; next }
    { if (!($0 in seen)) { seen[$0] = 1; order[++n] = $0 }; cnt[$0]++ }
    END { for (i = 1; i <= n; i++) printf "COVERAGE %s: manifest sites=%d\n", order[i], cnt[order[i]] }
  '
fi

echo "PASS=$PASS FAIL=$FAIL"
if [ "$FAIL" -eq 0 ]; then
  exit 0
fi
exit 1
