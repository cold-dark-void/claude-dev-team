#!/usr/bin/env bash
#
# council/verify-judge-shape.sh — CDT-602 (D2): finalize-side shape self-heal.
#
# Repairs the three CDT-614 judge-output defect classes BEFORE the finalize
# render sees the file, and hands the defects it cannot heal to the engine
# strike channel. Wired into cmd_finalize between normalize_judge_shape and the
# python render block (one call). It reads and writes only the judge file.
#
# Order matters (S1 must precede jq's silent last-wins parse):
#
#   S1 duplicate top-level key (raw text, no jq parse first). The judge quoted
#      the diff of the JSON template inside its evidence blob, so the file
#      carried two "verdicts" keys; jq keeps the last silently. Scan the raw
#      bytes for the key at depth 1 (string- and escape-aware brace walk), and
#      when it occurs 2+ times keep the LAST occurrence's balanced object:
#      rewrite in place, one stderr note. An unbalanced last block fails
#      closed to the existing judge-failure path (exit 7) — never guess.
#
#   S2 evidence_blob suffix rebuild. For each verdict record whose blob is NOT
#      a byte-exact substring of exactly one bundle raw_blob, walk the blob's
#      line-boundary suffixes longest-first; the first suffix that is a
#      substring of EXACTLY one raw_blob replaces the blob (a stray head line
#      above the quoted evidence is the live case). Zero or more-than-one
#      matching bundle → no rewrite, never a concatenation; the existing
#      CDT-574 strike owns that record.
#
#   S3 claim tag re-attach (M14 plan runs only: plan.claims[] non-empty,
#      verdict[] shape only). A record claim that byte-equals a plan claim is
#      clean. Strip an optional leading "[AC-<id>] " tag from the record claim;
#      when the remainder byte-equals exactly one plan claim's own tagged tail,
#      rewrite the record claim to that full plan claim text (the CDT-614
#      hand-patch, mechanized). A record claim that CARRIES a tag and matches
#      no plan tail is unhealable → strike reason. A record claim with NO tag
#      that matches nothing is the pre-existing "Claim unmatched" report path
#      (single-claim resolution, free-text judge claims) — untouched, so every
#      existing finalize golden stays byte-identical (AC5).
#
# Unhealable defects are written to --strikes-file as a JSON array of strike
# reasons in validate_judge wording shape; cmd_finalize merges that array into
# engine_strikes, so they reach the report's Audit Trail unchanged.
#
# Clean input is left byte-for-byte unchanged: S1–S3 are all no-ops on a
# healthy judge file (fixtures/clean-* golden, AC5).
#
# Bash/awk/jq only — no python/node (CDT-602 host hard rule).
#
# Usage:
#   verify-judge-shape.sh --judge-output <file> --evidence-file <file> \
#     --plan-file <file> --output-shape verdict[]|finding[] \
#     [--strikes-file <path>]
#
# --strikes-file defaults to stdout when omitted (the engine always passes one).
# Strikes never change the exit code — validate_judge strikes and the render
# continues, so the report is written with the Audit Trail row.
# Exit codes:
#   0  input usable (clean, healed, and/or strike reasons recorded)
#   2  usage / structural error (missing file, bad --output-shape)
#   7  judge output is not usable JSON (the existing judge-failure exit)

set -euo pipefail

usage() {
  cat >&2 <<'USAGE'
Usage: verify-judge-shape.sh --judge-output P --evidence-file P --plan-file P \
        --output-shape verdict[]|finding[] [--strikes-file P]
Exit: 0 usable (heals noted on stderr) | 2 usage/structural | 7 unusable JSON
USAGE
}

judge="" evidence="" plan="" shape="" strikes_out=""
while [ $# -gt 0 ]; do
  case "$1" in
    --judge-output)  [ $# -ge 2 ] || { usage; exit 2; }; judge="$2"; shift 2 ;;
    --evidence-file) [ $# -ge 2 ] || { usage; exit 2; }; evidence="$2"; shift 2 ;;
    --plan-file)     [ $# -ge 2 ] || { usage; exit 2; }; plan="$2"; shift 2 ;;
    --output-shape)  [ $# -ge 2 ] || { usage; exit 2; }; shape="$2"; shift 2 ;;
    --strikes-file)  [ $# -ge 2 ] || { usage; exit 2; }; strikes_out="$2"; shift 2 ;;
    -h|--help)       usage; exit 2 ;;
    *) echo "verify-judge-shape.sh: unknown flag: $1" >&2; usage; exit 2 ;;
  esac
done

case "$shape" in
  "verdict[]") key="verdicts" ;;
  "finding[]") key="findings" ;;
  *)
    echo "verify-judge-shape.sh: --output-shape must be verdict[]|finding[]" >&2
    usage; exit 2 ;;
esac
for f in "$judge" "$evidence" "$plan"; do
  if [ ! -f "$f" ]; then
    echo "verify-judge-shape.sh: missing file: $f" >&2
    exit 2
  fi
done
if ! command -v jq >/dev/null 2>&1; then
  echo "verify-judge-shape.sh: jq is required but not found in PATH" >&2
  exit 2
fi

TMPD=$(mktemp -d "${TMPDIR:-/tmp}/verify-judge-shape.XXXXXX")
trap 'rm -rf "$TMPD"' EXIT
printf '[]\n' > "$TMPD/strikes.json"

# add_strike <reason> — append one validate_judge-shaped reason.
add_strike() {
  jq -c --arg r "$1" '. + [$r]' "$TMPD/strikes.json" > "$TMPD/strikes.n" \
    && mv -- "$TMPD/strikes.n" "$TMPD/strikes.json"
}

# write_inplace SRC_FILE — replace the judge file with SRC_FILE (tmp beside
# the destination, then rename; same contract as normalize_judge_shape).
write_inplace() {
  local tmp
  tmp=$(mktemp "${judge}.XXXXXX")
  cp -- "$1" "$tmp"
  mv -- "$tmp" "$judge"
}

# ---- S1: duplicate top-level key, kept LAST (raw text) ----------------------
# The scan is string- and escape-aware, so braces inside JSON strings cannot
# open a block. OBJ lines carry the depth-0 object span; KEYE lines carry every
# "<key>" occurrence at depth 1 followed by ':'.
LC_ALL=C awk -v KEY="$key" '
  BEGIN { RS = "\001" }
  {
    s = $0; n = length(s)
    depth = 0; instr = 0; esc = 0; nobj = 0; objstart = 0; kee = 0
    for (p = 1; p <= n; p++) {
      c = substr(s, p, 1)
      if (instr) {
        if (esc) { esc = 0; continue }
        if (c == "\\") { esc = 1; continue }
        if (c != "\"") { continue }
        instr = 0
        if (depth == 1 && substr(s, tokstart, p - tokstart + 1) == "\"" KEY "\"") {
          q = p + 1
          while (q <= n && substr(s, q, 1) ~ /[ \t\r\n]/) q++
          if (substr(s, q, 1) == ":") { kee++; keeobj[kee] = nobj; keepos[kee] = tokstart }
        }
        continue
      }
      if (c == "\"") { instr = 1; tokstart = p; continue }
      if (c == "{") {
        depth++
        if (depth == 1) { nobj++; objstart = p; ostart[nobj] = p; oend[nobj] = 0 }
        continue
      }
      if (c == "}") { if (depth == 1 && objstart) oend[nobj] = p; depth--; continue }
    }
    print "DEPTH " depth " INSTR " instr
    for (k = 1; k <= nobj; k++) print "OBJ " k " " ostart[k] " " oend[k]
    for (k = 1; k <= kee; k++) print "KEYE " keeobj[k] " " keepos[k]
  }' "$judge" > "$TMPD/scan"

nkey=$(awk '$1 == "KEYE" { c++ } END { print c + 0 }' "$TMPD/scan")
if [ "$nkey" -ge 2 ]; then
  lastobj=$(awk '$1 == "KEYE" { o = $2 } END { print o }' "$TMPD/scan")
  span=$(awk -v o="$lastobj" '$1 == "OBJ" && $2 == o { print $3 " " $4 }' "$TMPD/scan")
  set -- $span
  start="${1:-0}"; stop="${2:-0}"
  if [ "$start" -lt 1 ] || [ "$stop" -lt "$start" ]; then
    echo "engine.sh: judge output carried $nkey \"$key\" keys and the last block is unbalanced — no heal (CDT-614)" >&2
    exit 7
  fi
  LC_ALL=C awk -v a="$start" -v b="$stop" 'BEGIN { RS = "\001" } { printf "%s", substr($0, a, b - a + 1) }' \
    "$judge" > "$TMPD/s1"
  if ! jq empty "$TMPD/s1" >/dev/null 2>&1; then
    echo "engine.sh: judge output carried $nkey \"$key\" keys and the last block is not parseable JSON — no heal (CDT-614)" >&2
    exit 7
  fi
  write_inplace "$TMPD/s1"
  echo "engine.sh: judge output carried $nkey \"$key\" keys; kept the last (CDT-614)" >&2
fi

if ! jq empty "$judge" >/dev/null 2>&1; then
  echo "engine.sh: judge output is not valid JSON before the shape self-heal (CDT-602)" >&2
  exit 7
fi

# Strikes and heals apply to verdict[] records only.
if [ "$shape" != "verdict[]" ]; then
  if [ -n "$strikes_out" ] && [ "$strikes_out" != "-" ]; then
    cp -- "$TMPD/strikes.json" "$strikes_out"
  else
    cat "$TMPD/strikes.json"
  fi
  exit 0
fi

nitems=$(jq 'if type == "object" and (.verdicts | type) == "array" then (.verdicts | length) else 0 end' "$judge")

# ---- S2: evidence_blob line-boundary suffix rebuild -------------------------
# Bundle raw blobs are exported byte-exactly (jq -j, no added newline) so awk
# compares bytes against bytes. -n makes `.` null, so the expression must read
# the slurped document via $ev[0], never a bare `.`.
bundles_expr='($ev[0] | if type == "array" then . elif type == "object" then (.bundles // .evidence_bundles // []) else [] end)'
nbundles=$(jq -rn --slurpfile ev "$evidence" "$bundles_expr | length")
bi=0
while [ "$bi" -lt "$nbundles" ]; do
  jq -rnj --slurpfile ev "$evidence" --argjson i "$bi" "$bundles_expr | .[\$i].raw_blob | if type == \"string\" then . else \"\" end" \
    > "$TMPD/bundle.$bi"
  bi=$(( bi + 1 ))
done

# s2_scan BLOB_FILE — prints ONE (whole blob matches exactly one bundle),
# HEAL <line> (suffix written to $TMPD/heal), MULTI, or NONE.
s2_scan() {
  local files=("$1") k=0
  while [ "$k" -lt "$nbundles" ]; do files+=("$TMPD/bundle.$k"); k=$(( k + 1 )); done
  LC_ALL=C awk -v OUT="$TMPD/heal" '
    BEGIN { RS = "\001" }
    { files[++nf] = $0 }
    END {
      blob = files[1]
      n = split(blob, L, "\n")
      for (s = 1; s <= n; s++) {
        suf = ""
        for (k = s; k <= n; k++) suf = suf (k > s ? "\n" : "") L[k]
        if (suf == "") continue
        c = 0
        for (k = 2; k <= nf; k++) if (files[k] != "" && index(files[k], suf) > 0) c++
        if (c == 1) {
          if (s == 1) { print "ONE"; exit }
          printf "%s", suf > OUT; close(OUT)
          print "HEAL " s; exit
        }
      }
      print "NONE"
    }' "${files[@]}"
}

i=0
while [ "$i" -lt "$nitems" ]; do
  blob=$(jq -r --argjson i "$i" '.verdicts[$i].evidence_blob | if type == "string" then . else "" end' "$judge")
  if [ -n "$blob" ] && [ -n "${blob//[[:space:]]/}" ]; then
    printf '%s' "$blob" > "$TMPD/blob"
    set -- $(s2_scan "$TMPD/blob")
    case "${1:-NONE}" in
      ONE) : ;;
      HEAL)
        tid=$(jq -rn --slurpfile ev "$evidence" --arg h "$(cat "$TMPD/heal")" \
          "$bundles_expr | [.[] | select((.raw_blob | type) == \"string\" and (.raw_blob | index(\$h) != null))] | .[0].tool_use_id // \"?\"")
        jq --argjson i "$i" --rawfile h "$TMPD/heal" '.verdicts[$i].evidence_blob = $h' \
          "$judge" > "$TMPD/j"
        write_inplace "$TMPD/j"
        echo "engine.sh: rebuilt verdict evidence_blob from its line-boundary suffix (bundle $tid) (CDT-614)" >&2
        ;;
      *) : ;;   # NONE / MULTI — the existing CDT-574 strike owns the record
    esac
  fi
  i=$(( i + 1 ))
done

# ---- S3: plan-claim byte-match + [AC-<id>] tag re-attach --------------------
jq -c '[.claims[]? | .claim | select(type == "string")]' "$plan" > "$TMPD/claims.json"
nclaims=$(jq 'length' "$TMPD/claims.json")
if [ "$nclaims" -gt 0 ]; then
  i=0
  while [ "$i" -lt "$nitems" ]; do
    rc=$(jq -r --argjson i "$i" '.verdicts[$i].claim | if type == "string" then . else "" end' "$judge")
    if [ -n "$rc" ] && [ -n "${rc//[[:space:]]/}" ]; then
      verdict=$(jq -rn --slurpfile C "$TMPD/claims.json" --arg c "$rc" '
        $C[0] as $cl
        | if ($cl | index($c)) != null then "OK"
          else
            ($cl | to_entries
              | map(.key as $k | .value as $s
                    | (($s | capture("^(?<p>\\[AC-[^\\]]*\\] )").p) // "") as $p
                    | {i: $k, tail: $s[($p | length):]})) as $tails
            | (($c | capture("^(?<p>\\[AC-[^\\]]*\\] )").p) // "") as $rp
            | ($c[($rp | length):]) as $rt
            | ($tails | map(select(.tail == $rt))) as $m
            | if ($m | length) == 1 then "HEAL \($m[0].i)"
              elif ($rp | length) > 0 then "STRIKE"
              else "LEAVE" end
          end')
      case "$verdict" in
        OK | LEAVE) : ;;
        STRIKE)
          cid=$(jq -r --argjson i "$i" '.verdicts[$i] | (.claim_id // .claim // "?") | tostring' "$judge")
          add_strike "verdict claim text matches no plan claim (claim=$cid)"
          ;;
        HEAL\ *)
          ci=${verdict#HEAL }
          full=$(jq -r --argjson c "$ci" '.[$c]' "$TMPD/claims.json")
          jq --argjson i "$i" --arg c "$full" '.verdicts[$i].claim = $c' "$judge" > "$TMPD/j"
          write_inplace "$TMPD/j"
          echo "engine.sh: re-attached the [AC-<id>] claim tag from the plan (CDT-614)" >&2
          ;;
      esac
    fi
    i=$(( i + 1 ))
  done
fi

# ---- strikes out ------------------------------------------------------------
if [ -n "$strikes_out" ] && [ "$strikes_out" != "-" ]; then
  cp -- "$TMPD/strikes.json" "$strikes_out"
else
  cat "$TMPD/strikes.json"
fi
exit 0
