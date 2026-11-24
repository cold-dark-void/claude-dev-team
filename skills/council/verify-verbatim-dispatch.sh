#!/usr/bin/env bash
#
# council/verify-verbatim-dispatch.sh — CDT-602 (D1): dispatch-side verifier.
#
# Re-renders the expected council prompt from template + flavor + vardump and
# byte-compares (cmp) against the rendered file a hand-run is about to spawn
# with. Never writes the rendered file. The re-render replicates the loadPrompt
# pipeline in skills/council/workflow.js exactly (that file is the single
# source of the render semantics; this script mirrors them, the golden suite
# test-verify-verbatim-dispatch.sh pins the mirror against the real code):
#
#   1. extractPromptBody: YAML frontmatter strip, then the first fenced
#      ``` block when present (investigator/judge templates).
#   2. flavorDelta (--flavor, investigator mode): frontmatter strip, cut
#      everything through the `## Delta body` marker line, drop `[//]: #`
#      authoring lines, trim. Injected as vars.FLAVOR_DELTA.
#   3. applySections: a `{{#NAME}}` ... `{{/NAME}}` block (NAME [A-Z_]+,
#      marker lines alone, no nesting) is dropped whole when the var is
#      empty/absent, else only the two marker lines are removed.
#   4. One-pass `{{VAR}}` substitution (VAR [A-Z0-9_]+): a value containing
#      `{{OTHER}}` is never re-expanded; unknown vars stay literal; a null
#      vardump value substitutes "".
#
# Bash/awk/jq only — no python/node (CDT-602 host hard rule; node appears
# only in the golden test, test-verify-prompts.sh M5 precedent).
#
# Supported input domain (the mirror is byte-exact here, documented where the
# JS is looser): LF line endings; plain NAME vardump keys (a `{{NAME}}` key is
# normalized BEFORE both passes, so a section block sees it while JS
# applySections, which reads raw keys, would drop it); scalar vardump values.
#
# Usage:
#   verify-verbatim-dispatch.sh --mode investigator|judge \
#     --template <prompts/X.md> [--flavor <flavors/Y.md>] \
#     --vars <vardump.json> --rendered <rendered-prompt-file>
#
# --vars accepts a JSON object var->value (values: string, number, boolean,
# null) or env-style KEY=value lines (one var per line; the value is the
# rest of the line, so multi-line values require the JSON form). Keys
# written as `{{NAME}}` are normalized to NAME. A --flavor value overrides
# a FLAVOR_DELTA key in the vardump (workflow.js always computes it).
#
# Exit codes:
#   0  byte-identical
#   1  mismatch — stderr names the first differing byte offset with context
#   2  usage / structural error (missing file, unparseable vardump)

set -euo pipefail

usage() {
  cat >&2 <<'USAGE'
Usage: verify-verbatim-dispatch.sh --mode investigator|judge --template P \
        [--flavor P] --vars V --rendered R
Exit: 0 identical | 1 mismatch (first byte offset on stderr) | 2 usage/structural
USAGE
}

mode="" template="" flavor="" varsfile="" rendered=""
while [ $# -gt 0 ]; do
  case "$1" in
    --mode)     [ $# -ge 2 ] || { usage; exit 2; }; mode="$2"; shift 2 ;;
    --template) [ $# -ge 2 ] || { usage; exit 2; }; template="$2"; shift 2 ;;
    --flavor)   [ $# -ge 2 ] || { usage; exit 2; }; flavor="$2"; shift 2 ;;
    --vars)     [ $# -ge 2 ] || { usage; exit 2; }; varsfile="$2"; shift 2 ;;
    --rendered) [ $# -ge 2 ] || { usage; exit 2; }; rendered="$2"; shift 2 ;;
    -h|--help)  usage; exit 2 ;;
    *) echo "verify-verbatim-dispatch.sh: unknown flag: $1" >&2; usage; exit 2 ;;
  esac
done

case "$mode" in
  investigator|judge) ;;
  *) echo "verify-verbatim-dispatch.sh: --mode must be investigator|judge" >&2; usage; exit 2 ;;
esac
if [ -n "$flavor" ] && [ "$mode" = "judge" ]; then
  echo "verify-verbatim-dispatch.sh: --flavor is investigator-mode only" >&2
  exit 2
fi
for f in "$template" "$varsfile" "$rendered"; do
  if [ ! -f "$f" ]; then
    echo "verify-verbatim-dispatch.sh: missing file: $f" >&2
    exit 2
  fi
done
if [ -n "$flavor" ] && [ ! -f "$flavor" ]; then
  echo "verify-verbatim-dispatch.sh: missing file: $flavor" >&2
  exit 2
fi
if ! command -v jq >/dev/null 2>&1; then
  echo "verify-verbatim-dispatch.sh: jq is required but not found in PATH" >&2
  exit 2
fi

TMPD=$(mktemp -d "${TMPDIR:-/tmp}/verify-verbatim.XXXXXX")
trap 'rm -rf "$TMPD"' EXIT

# ---- vardump normalize: JSON object (null -> "") or env-style KEY=value ----
if jq -e . "$varsfile" >/dev/null 2>&1; then
  if ! jq -e 'type == "object"' "$varsfile" >/dev/null 2>&1; then
    echo "verify-verbatim-dispatch.sh: vardump is not a JSON object" >&2
    exit 2
  fi
  if ! jq -e '[.[] | type] | all(. == "string" or . == "number" or . == "boolean" or . == "null")' \
      "$varsfile" >/dev/null 2>&1; then
    echo "verify-verbatim-dispatch.sh: vardump carries a non-scalar value" >&2
    exit 2
  fi
  jq -c 'with_entries(
           .key |= (if (startswith("{{") and endswith("}}")) then .[2:-2] else . end)
         | .value |= (if . == null then "" else . end))' "$varsfile" >"$TMPD/vars.json"
else
  vars_json='{}'
  while IFS= read -r line || [ -n "$line" ]; do
    [ -n "$line" ] || continue
    case "$line" in
      *=*) : ;;
      *) echo "verify-verbatim-dispatch.sh: vardump line is not KEY=value: $line" >&2; exit 2 ;;
    esac
    key="${line%%=*}"
    val="${line#*=}"
    case "$key" in
      *[!A-Z0-9_]* | "")
        echo "verify-verbatim-dispatch.sh: vardump key is not [A-Z0-9_]+: $key" >&2
        exit 2 ;;
    esac
    vars_json=$(printf '%s' "$vars_json" | jq -c --arg k "$key" --arg v "$val" '. + {($k): $v}')
  done <"$varsfile"
  printf '%s\n' "$vars_json" >"$TMPD/vars.json"
fi

# ---- flavor delta (workflow.js loadFlavor -> flavorDelta) -------------------
if [ -n "$flavor" ]; then
  delta=$(LC_ALL=C awk '
    function findlit(s, lit, from,   p) {
      p = index(substr(s, from), lit)
      return p ? from + p - 1 : 0
    }
    function stripfm(s,   p) {
      if (substr(s, 1, 3) == "---") {
        p = 4
        while (p <= length(s)) {
          p = findlit(s, "\n---", p)
          if (!p) return s
          if (p >= 4) {
            s = substr(s, p + 4)
            if (match(s, /^[ \t\r\n]*\n/)) s = substr(s, RSTART + RLENGTH)
            return s
          }
          p = p + 1
        }
      }
      return s
    }
    BEGIN { RS = "\001" }
    {
      s = stripfm($0)
      if (substr(s, 1, 13) == "## Delta body") st = 1
      else { p = findlit(s, "\n## Delta body", 1); st = p ? p + 1 : 0 }
      if (st) { s = substr(s, st); nl = index(s, "\n"); s = nl ? substr(s, nl + 1) : "" }
      n = split(s, L, "\n"); out = ""
      for (k = 1; k <= n; k++)
        if (substr(L[k], 1, 7) != "[//]: #") out = out L[k] (k < n ? "\n" : "")
      gsub(/^[ \t\n\r\f\v]+/, "", out)
      gsub(/[ \t\n\r\f\v]+$/, "", out)
      printf "%s", out
    }' "$flavor")
  jq -c --arg d "$delta" '. + {FLAVOR_DELTA: $d}' "$TMPD/vars.json" >"$TMPD/vars2.json"
  mv -- "$TMPD/vars2.json" "$TMPD/vars.json"
fi

# ---- extractPromptBody: frontmatter strip, then first fenced block ----------
LC_ALL=C awk '
  function findlit(s, lit, from,   p) {
    p = index(substr(s, from), lit)
    return p ? from + p - 1 : 0
  }
  BEGIN { RS = "\001" }
  {
    s = $0
    if (substr(s, 1, 3) == "---") {
      p = 4
      while (p <= length(s)) {
        p = findlit(s, "\n---", p)
        if (!p) { p = 0; break }
        if (p >= 4) break
        p = p + 1
      }
      if (p) {
        s = substr(s, p + 4)
        if (match(s, /^[ \t\r\n]*\n/)) s = substr(s, RSTART + RLENGTH)
      }
    }
    p = findlit(s, "```\n", 1)
    if (p) {
      q = findlit(s, "\n```", p + 4)
      if (q) s = substr(s, p + 4, q - (p + 4))
    }
    printf "%s", s
  }' "$template" >"$TMPD/body"

# ---- applySections (workflow.js section-block semantics) --------------------
names=$(jq -r 'to_entries[] | select((.value | tostring) != "") | .key' "$TMPD/vars.json" | tr '\n' ' ')
LC_ALL=C awk -v NE="$names" '
  BEGIN {
    RS = "\001"
    nn = split(NE, NA, " ")
    for (k = 1; k <= nn; k++) if (NA[k] != "") ne[NA[k]] = 1
  }
  {
    s = $0
    nl = (length(s) > 0 && substr(s, length(s), 1) == "\n") ? 1 : 0
    n = split(s, L, "\n")
    if (nl) n = n - 1
    addnl = 0; m = 0; i = 1
    while (i <= n) {
      line = L[i]
      if (line ~ /^\{\{#[A-Z_]+\}\}$/) {
        name = substr(line, 4, length(line) - 5)
        f = i + 1; found = 0
        while (f <= n) { if (L[f] == "{{/" name "}}") { found = f; break }; f++ }
        # found >= i + 2: JS needs a newline between the open marker and the
        # close, so adjacent markers (found == i + 1) are no match and stay
        # literal.
        if (found && found >= i + 2) {
          if (name in ne) for (k = i + 1; k < found; k++) OUT[++m] = L[k]
          # A block that ends the file with no trailing newline: the keep
          # replacement always ends "\n"; the drop replacement leaves the
          # newline that preceded the open marker (none when m == 0).
          if (found == n && !nl && (m > 0 || (name in ne))) addnl = 1
          i = found + 1
          continue
        }
      }
      OUT[++m] = line; i++
    }
    out = ""
    for (k = 1; k <= m; k++) out = out (k > 1 ? "\n" : "") OUT[k]
    if (nl) out = out "\n"
    if (addnl) out = out "\n"
    printf "%s", out
  }' "$TMPD/body" >"$TMPD/skeleton"

# ---- one-pass {{VAR}} substitution (values never re-expanded) ---------------
# -n is required: --rawfile supplies the input, so jq must not read stdin.
# -j keeps the render free of an added trailing newline.
if ! jq -rjn --rawfile skel "$TMPD/skeleton" --slurpfile V "$TMPD/vars.json" '
  $V[0] as $vars
  | $skel
  | gsub("(?<m>\\{\\{[A-Z0-9_]+\\}\\})";
      .m as $t | ($t[2:-2]) as $k
      | if ($vars | has($k)) then ($vars[$k] | tostring) else $t end)
' >"$TMPD/expected" 2>"$TMPD/jq.err"; then
  echo "verify-verbatim-dispatch.sh: substitution failed: $(cat "$TMPD/jq.err")" >&2
  exit 2
fi

# ---- byte compare -----------------------------------------------------------
if cmp -s "$TMPD/expected" "$rendered"; then
  exit 0
fi

exp_sz=$(wc -c <"$TMPD/expected")
ren_sz=$(wc -c <"$rendered")
# cmp -l columns are "<byte> <octet-expected> <octet-rendered>" — $1 is the
# offset. `|| true` keeps cmp's exit 1 (pipefail) from firing errexit before
# the report below is printed.
off=$(cmp -l "$TMPD/expected" "$rendered" 2>/dev/null | awk 'NR == 1 { print $1 }' || true)
if [ -z "$off" ]; then
  # Identical up to the shorter file — the difference is the size.
  off=$(( (exp_sz < ren_sz ? exp_sz : ren_sz) + 1 ))
fi
line=$(( $(LC_ALL=C head -c $((off - 1)) "$rendered" 2>/dev/null | wc -l) + 1 ))
lo=$(( line > 1 ? line - 1 : 1 ))
hi=$(( line + 1 ))
echo "verify-verbatim-dispatch.sh: MISMATCH at byte $off (rendered line $line); expected $exp_sz bytes, rendered $ren_sz bytes" >&2
echo "--- expected (lines $lo-$hi) ---" >&2
LC_ALL=C sed -n "${lo},${hi}p" "$TMPD/expected" | sed 's/^/  /' >&2
echo "--- rendered (lines $lo-$hi) ---" >&2
LC_ALL=C sed -n "${lo},${hi}p" "$rendered" | sed 's/^/  /' >&2
exit 1
