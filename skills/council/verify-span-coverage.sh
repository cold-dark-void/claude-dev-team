#!/usr/bin/env bash
#
# council/verify-span-coverage.sh — CDT-605: the strict CDT-537 span audit, run
# at Phase-5 entry, before the first council-judge part spawns.
#
# It mirrors the four mechanical CDT-537 pre-judge checks in
# skills/council/prompts/judge.md § "Verify evidence" (WP 1-16) — the audit
# never edits them:
#   (a) quote presence      — a claim with a verify command needs a Step-1
#                             quote bundle: a raw_blob line
#                             `<N>: - **<ac_id>.**` anchored on its
#                             source_locator (judge.md, CDT-537).
#   (b) token coverage      — a token of class backtick span, `path:N`,
#                             `Case N` or `AC X` named in that quote needs a
#                             line, in a bundle OTHER than the Step-1 quote,
#                             that holds it.
#   (c) HEAD admissibility  — a bundle whose raw_blob names a sha other than
#                             the audited HEAD is inadmissible for coverage
#                             (the CDT-589 C5 lesson: stale-HEAD bundles were
#                             ruled out of the audit).
#   (d) elision line        — a raw_blob line that is only ..., [...] or …
#                             caps the claim at <=79, so the audit reports it
#                             as uncovered work: the judge caps regardless.
#
# Why it exists: token-coverage gaps surfaced only after a full judge wave
# (CDT-589 C5 needed 3 retrofit waves, the C1 regate 3 more), each because a
# named token in an AC quote lacked bundle coverage — a fact no machine checked
# before the judges were spawned and billed.
#
# Contract:
#   verify-span-coverage.sh --claims <claims.json> --bundles <bundles.json> \
#     [--head <sha>]
#
#   claims.json   JSON array of claim records. The audit reads claim_id, ac_id
#                 and source_locator ("<path>:<N>", worktree-relative) and the
#                 verify field. Only claims with verify != null are audited —
#                 every cap above is a verify-claim cap — and a verify-null
#                 claim is skipped, never failed.
#   bundles.json  JSON array of evidence bundles. The audit reads tool_use_id,
#                 claim_id, file_line and raw_blob. Every raw_blob is extracted
#                 with `jq -r` (NEVER `-c`: JSON escaping turns a span holding
#                 `"` into `\"` and the literal grep then false-negatives the
#                 span — the CDT-589 C5 lesson) into one file per bundle, and
#                 tokens are matched with literal `grep -F`.
#   --head        The audited HEAD sha, 7-40 hex. Default when omitted:
#                 `git rev-parse HEAD` in the current worktree (resolved only
#                 when the audited set is non-empty), which makes the run
#                 worktree-dependent; callers that must be hermetic pin it.
#
# Exit codes:
#   0   every audited claim is covered — one stdout summary line, no stderr.
#   8   uncovered work. One `span-audit: case N: <cause>` stderr line per
#       finding (case 1 quote presence, case 2 token coverage, case 3 HEAD
#       admissibility, case 4 elision line — the m14-ac-split case-contract
#       shape, C1) and a JSON array of uncovered records
#       {claim_id, ac_id, token_class, token} on stdout for per-claim
#       re-collection.
#   64  argv misuse / unparseable or structurally unusable input.
#
# Fail-closed bias: a false negative (an inadmissible covered bundle) costs one
# re-collection; a false pass costs a capped verdict nobody checks.
#
# Bash/awk/jq/sed only (CDT-602 host hard rule — node appears only in the golden
# suite). bash 3.2 / BSD-userland safe (CDT-271): no `declare -A`, no mapfile.
#
# Bite seams: SPAN_CHECK_* below are constants the golden suite flips to 0 to
# prove each cap's fixture fails without its check (AC2). They are NOT env
# variables, flags, or plan fields — no caller can switch a cap off.

set -uo pipefail

SPAN_CHECK_QUOTE=1
SPAN_CHECK_TOKENS=1
SPAN_CHECK_HEAD=1
SPAN_CHECK_ELISION=1

SELF="span-audit"
US=$(printf '\037')  # unit separator: never appears in a claim id, token, or path

usage() {
  cat >&2 <<'USAGE'
usage: span-audit --claims <claims.json> --bundles <bundles.json> [--head <sha>]
       (skills/council/verify-span-coverage.sh is the verifier core; the
       council engine entry point is engine.sh span-audit)
exit: 0 covered | 8 uncovered ("span-audit: case N: <cause>" on stderr,
      the uncovered JSON array on stdout) | 64 usage / unusable input
USAGE
  exit 64
}

fail_struct() {  # fail_struct <cause> — structural input problem, exit 64
  echo "$SELF: $1" >&2
  exit 64
}

claims_file="" bundles_file="" head_arg=""
while [ $# -gt 0 ]; do
  case "$1" in
    --claims)  [ $# -ge 2 ] || usage; claims_file="$2"; shift 2 ;;
    --bundles) [ $# -ge 2 ] || usage; bundles_file="$2"; shift 2 ;;
    --head)    [ $# -ge 2 ] || usage; head_arg="$2"; shift 2 ;;
    -h|--help) usage ;;
    *) echo "$SELF: unknown flag: $1" >&2; usage ;;
  esac
done
[ -n "$claims_file" ] || { echo "$SELF: --claims is required" >&2; usage; }
[ -n "$bundles_file" ] || { echo "$SELF: --bundles is required" >&2; usage; }
for f in "$claims_file" "$bundles_file"; do
  [ -f "$f" ] && [ -r "$f" ] || fail_struct "input file is not readable: $f"
done
command -v jq >/dev/null 2>&1 || fail_struct "jq is required but not found in PATH"
jq -e . "$claims_file" >/dev/null 2>&1 || fail_struct "claims file is not valid JSON: $claims_file"
jq -e . "$bundles_file" >/dev/null 2>&1 || fail_struct "bundles file is not valid JSON: $bundles_file"
[ "$(jq -r 'type' "$claims_file")" = "array" ] || fail_struct "claims file is not a JSON array: $claims_file"
[ "$(jq -r 'type' "$bundles_file")" = "array" ] || fail_struct "bundles file is not a JSON array: $bundles_file"

# ---- Audited HEAD ----------------------------------------------------------
# An explicit --head is validated here (argv contract). The git default is
# resolved only when the audited set is non-empty: a run with nothing to audit
# needs no git worktree at all.
head_sha=""
if [ -n "$head_arg" ]; then
  head_sha=$(printf '%s' "$head_arg" | tr 'A-F' 'a-f')
  case "$head_sha" in
    *[!0-9a-f]*) fail_struct "--head must be hex: $head_arg" ;;
  esac
  [ "${#head_sha}" -ge 7 ] && [ "${#head_sha}" -le 40 ] \
    || fail_struct "--head must be 7-40 hex characters: $head_arg"
fi

TMPD=$(mktemp -d "${TMPDIR:-/tmp}/verify-span-coverage.XXXXXX")
trap 'rm -rf "$TMPD"' EXIT

# ---- Audited claims: verify != null ----------------------------------------
# Row shape: claim_id US ac_id US source_locator
if ! jq -r 'to_entries[] | select(.value.verify != null)
            | [ (.value.claim_id // ("c" + (.key | tostring))),
                (.value.ac_id // ""),
                (.value.source_locator // "") ]
            | map(tostring) | join("\u001f")' \
     "$claims_file" > "$TMPD/claims" 2>/dev/null; then
  fail_struct "claims file is not a JSON array of claim objects: $claims_file"
fi

n_claims=0
declare -a C_ID C_AC C_LOC C_PATH C_LINE
while IFS= read -r row; do
  claim_id="${row%%$US*}"
  rest="${row#*$US}"
  ac_id="${rest%%$US*}"
  locator="${rest#*$US}"
  [ -n "$claim_id" ] || claim_id="c$n_claims"
  case "$ac_id" in
    [A-Z] | [A-Z][A-Z0-9] | [A-Z][A-Z0-9][A-Z0-9] | [A-Z][A-Z0-9][A-Z0-9][A-Z0-9]) ;;
    *)
      fail_struct "claim $claim_id has no usable ac_id (expected an AC id like A, B, AC1): '$ac_id'"
      ;;
  esac
  case "$locator" in
    *:*) : ;;
    *) fail_struct "claim $claim_id has no source_locator of the form <path>:<N>: '$locator'" ;;
  esac
  path_part="${locator%:*}"
  line_part="${locator##*:}"
  [ -n "$path_part" ] || fail_struct "claim $claim_id source_locator has an empty path: '$locator'"
  case "$line_part" in
    *[!0-9]* | "") fail_struct "claim $claim_id source_locator line is not a number: '$locator'" ;;
  esac
  case "$path_part" in
    /*) fail_struct "claim $claim_id source_locator path must be relative: '$locator'" ;;
  esac
  case "/$path_part/" in
    */../*) fail_struct "claim $claim_id source_locator path holds a '..' segment: '$locator'" ;;
  esac
  C_ID[$n_claims]="$claim_id"
  C_AC[$n_claims]="$ac_id"
  C_LOC[$n_claims]="$locator"
  C_PATH[$n_claims]="$path_part"
  C_LINE[$n_claims]="$line_part"
  n_claims=$((n_claims + 1))
done < "$TMPD/claims"

# Audited-HEAD default + worktree root, resolved only when something is
# audited (the quote text is read from source_locator in the worktree).
toplevel=""
if [ "$n_claims" -gt 0 ]; then
  [ -n "$head_sha" ] || head_sha=$(git rev-parse HEAD 2>/dev/null) \
    || fail_struct "--head omitted and git rev-parse HEAD failed (not a git worktree?)"
  toplevel=$(git rev-parse --show-toplevel 2>/dev/null) \
    || fail_struct "not inside a git worktree — the quote text is read from source_locator"
fi

# ---- Bundles: one raw_blob file per bundle, extracted with `jq -r` ---------
n_bundles=$(jq 'length' "$bundles_file")
declare -a B_TID B_CID B_FLINE B_BLOB B_OK B_SHA B_ELISION
i=0
while [ "$i" -lt "$n_bundles" ]; do
  blob="$TMPD/b$i"
  # The `-r` here is the C5 contract: never `-c`, which JSON-escapes and
  # false-negatives a span that holds a double quote.
  if ! jq -r --argjson i "$i" '.[$i].raw_blob // ""' "$bundles_file" > "$blob"; then
    fail_struct "bundles file is not valid JSON at index $i"
  fi
  meta=$(jq -r --argjson i "$i" \
    '[ (.[$i].tool_use_id // ""), (.[$i].claim_id // ""), (.[$i].file_line // "") ]
     | map(tostring) | join("\u001f")' "$bundles_file") \
    || fail_struct "bundles file is not valid JSON at index $i"
  tid="${meta%%$US*}"
  rest="${meta#*$US}"
  cid="${rest%%$US*}"
  fline="${rest#*$US}"

  # ---- (c) HEAD admissibility ----------------------------------------------
  ok=1
  bad_sha=""
  if [ "$SPAN_CHECK_HEAD" = 1 ]; then
    LC_ALL=C awk '{
        n = split($0, w, /[^0-9a-f]+/)
        for (k = 1; k <= n; k++) { t = tolower(w[k]); if (length(t) == 40 || length(t) == 7) print t }
      }' "$blob" > "$TMPD/hex.$i"
    while IFS= read -r tok; do
      [ -n "$tok" ] || continue
      pfx=0
      case "$head_sha" in "$tok"*) pfx=1 ;; esac
      case "$tok" in "$head_sha"*) pfx=1 ;; esac
      if [ "$pfx" -eq 0 ]; then ok=0; bad_sha="$tok"; break; fi
    done < "$TMPD/hex.$i"
  fi
  B_TID[$i]="$tid"
  B_CID[$i]="$cid"
  B_FLINE[$i]="$fline"
  B_BLOB[$i]="$blob"
  B_OK[$i]="$ok"
  B_SHA[$i]="$bad_sha"
  elision=$(LC_ALL=C awk '{
              s = $0
              sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s)
              if (s == "..." || s == "[...]" || s == "…") { print s; exit }
            }' "$blob")
  B_ELISION[$i]="$elision"
  i=$((i + 1))
done

# Admissible-bundle count for the summary line (independent of the audited set).
n_admissible=0
i=0
while [ "$i" -lt "$n_bundles" ]; do
  [ "${B_OK[$i]}" = 1 ] && n_admissible=$((n_admissible + 1))
  i=$((i + 1))
done

# ---- Findings accumulator --------------------------------------------------
# Row shape: kind US claim_id US ac_id US token_class US token US detail
: > "$TMPD/findings"
add_finding() {  # add_finding <kind> <claim_id> <ac_id> <class> <token> <detail>
  printf '%s\037%s\037%s\037%s\037%s\037%s\n' "$1" "$2" "$3" "$4" "$5" "$6" >> "$TMPD/findings"
}
ac_for_claim() {  # ac_for_claim <claim_id> — the audited claim's AC id, or ""
  local j
  j=0
  while [ "$j" -lt "$n_claims" ]; do
    if [ "${C_ID[$j]}" = "$1" ]; then printf '%s\n' "${C_AC[$j]}"; return 0; fi
    j=$((j + 1))
  done
  printf '\n'
}

# ---- Cases 3 and 4: bundle-level findings ----------------------------------
i=0
while [ "$i" -lt "$n_bundles" ]; do
  cid="${B_CID[$i]}"
  ac="$(ac_for_claim "$cid")"
  if [ -n "$ac" ]; then
    if [ "$SPAN_CHECK_HEAD" = 1 ] && [ "${B_OK[$i]}" = 0 ]; then
      add_finding bundle "$cid" "$ac" "HEAD" "${B_SHA[$i]}" \
        "bundle ${B_TID[$i]} is inadmissible — its raw_blob names sha ${B_SHA[$i]}, not the audited HEAD $head_sha"
    fi
    if [ "$SPAN_CHECK_ELISION" = 1 ] && [ -n "${B_ELISION[$i]}" ]; then
      add_finding bundle "$cid" "$ac" "elision" "${B_ELISION[$i]}" \
        "bundle ${B_TID[$i]} holds an elision line '${B_ELISION[$i]}' — the judge caps the claim at <=79"
    fi
  fi
  i=$((i + 1))
done

# ---- Cases 1 and 2: per audited claim --------------------------------------
n_tokens=0
j=0
while [ "$j" -lt "$n_claims" ]; do
  claim_id="${C_ID[$j]}"; ac_id="${C_AC[$j]}"; locator="${C_LOC[$j]}"
  spec="${C_PATH[$j]}"; ac_line="${C_LINE[$j]}"

  [ -f "$toplevel/$spec" ] \
    || fail_struct "the quote source at $locator is absent in the worktree: $spec"

  # Step-1 quote text: the fixed recipe awk of investigator.md RECIPE STEP 1.
  LC_ALL=C awk -v n="$ac_line" \
    'NR==n{p=1} p&&NR>n&&!/^  /{exit} p{print NR": "$0}' \
    "$toplevel/$spec" > "$TMPD/quote"
  [ -s "$TMPD/quote" ] \
    || fail_struct "the quote source at $locator has no line $ac_line to quote"

  # The Step-1 quote bundle: this claim's bundle whose raw_blob starts a line
  # at the locator's own line number with `- **<ac_id>.**`, anchored on the
  # bundle's file_line path (investigator.md: file_line is SOURCE_LOCATOR).
  qb=""
  i=0
  while [ "$i" -lt "$n_bundles" ]; do
    if [ "${B_CID[$i]}" = "$claim_id" ]; then
      fline="${B_FLINE[$i]}"
      anchored=1
      case "$fline" in
        *:*) [ "${fline%:*}" = "$spec" ] || anchored=0 ;;
      esac
      if [ "$anchored" = 1 ] \
        && LC_ALL=C awk -v n="$ac_line" -v ac="$ac_id" \
             'index($0, n ": - **" ac ".**") == 1 { found = 1 } END { exit !found }' \
             "${B_BLOB[$i]}"; then
        qb="$i"
        break
      fi
    fi
    i=$((i + 1))
  done

  if [ "$SPAN_CHECK_QUOTE" = 1 ] && [ -z "$qb" ]; then
    add_finding claim "$claim_id" "$ac_id" "quote" "$locator" \
      "has no Step-1 quote bundle anchored on $locator"
  fi

  # Coverage set: admissible bundles other than this claim's Step-1 quote.
  : > "$TMPD/cover"
  i=0
  while [ "$i" -lt "$n_bundles" ]; do
    if [ "$i" != "$qb" ] && [ "${B_OK[$i]}" = 1 ]; then
      printf '\n' >> "$TMPD/cover"
      cat "${B_BLOB[$i]}" >> "$TMPD/cover"
    fi
    i=$((i + 1))
  done

  # Tokens of the quote, one per class, deduped.
  if ! LC_ALL=C awk -v US="$US" '
    function emit(cls, tok,   k) {
      sub(/^[ \t]+/, "", tok); sub(/[ \t]+$/, "", tok)
      if (tok == "") return
      k = cls US tok
      if (k in seen) return
      seen[k] = 1
      print cls US tok
    }
    {
      line = $0
      # (1) backtick spans, paired on the line.
      s = line
      while (1) {
        p = index(s, "`")
        if (p == 0) break
        rest = substr(s, p + 1)
        q = index(rest, "`")
        if (q == 0) break
        emit("backtick", substr(rest, 1, q - 1))
        s = substr(rest, q + 1)
      }
      # (2) the unbackticked text: `path:N`, `Case N`, `AC X`.
      gsub(/`[^`]*`/, " ", line)
      nf = split(line, w, /[ \t]+/)
      for (x = 1; x <= nf; x++) {
        t = w[x]
        if (t == "Case" && x < nf) {
          nx = w[x + 1]; sub(/[.,;:)]+$/, "", nx)
          if (nx ~ /^[0-9]+$/) { emit("Case N", "Case " nx); x++; continue }
        }
        if (t == "AC" && x < nf) {
          nx = w[x + 1]; sub(/[.,;:)]+$/, "", nx)
          if (nx ~ /^[A-Z]$/ || nx ~ /^[A-Z][A-Z0-9][A-Z0-9]?[A-Z0-9]?$/) {
            emit("AC X", "AC " nx); x++; continue
          }
        }
        cpos = 0
        L = length(t)
        for (y = 1; y <= L; y++) if (substr(t, y, 1) == ":") cpos = y
        if (cpos > 1 && cpos < L) {
          p1 = substr(t, 1, cpos - 1)
          p2 = substr(t, cpos + 1)
          sub(/[.,;:)]+$/, "", p2)
          # The path part must hold `/` or `.`: that kills the false positives
          # a bare word:NUMBER would create (host:12, 14:32, v2:1).
          if (p2 ~ /^[0-9]+$/ && p1 ~ /^[A-Za-z0-9._\/-]+$/ \
              && (index(p1, "/") > 0 || index(p1, ".") > 0)) {
            emit("path:N", p1 ":" p2)
          }
        }
      }
    }
  ' "$TMPD/quote" > "$TMPD/tokens"; then
    # Fail closed: a quote whose tokens cannot be extracted must never report
    # "covered" on an empty token set.
    fail_struct "token extraction failed for the quote at $locator"
  fi

  while IFS= read -r trow; do
    [ -n "$trow" ] || continue
    cls="${trow%%$US*}"
    tok="${trow#*$US}"
    n_tokens=$((n_tokens + 1))
    if [ "$SPAN_CHECK_TOKENS" = 1 ] && ! grep -qF -e "$tok" "$TMPD/cover"; then
      add_finding claim "$claim_id" "$ac_id" "$cls" "$tok" \
        "token '$tok' has no admissible non-quote bundle line"
    fi
  done < "$TMPD/tokens"
  j=$((j + 1))
done

# ---- Report ----------------------------------------------------------------
if [ ! -s "$TMPD/findings" ]; then
  printf '%s: covered — %d audited claim(s), %d token(s), %d admissible bundle(s), HEAD %s\n' \
    "$SELF" "$n_claims" "$n_tokens" "$n_admissible" "${head_sha:-n/a}"
  exit 0
fi

LC_ALL=C awk -F '\037' '{
    if ($1 == "claim") {
      if ($4 == "quote") c = 1
      else c = 2
      printf "span-audit: case %d: claim %s (AC %s): %s\n", c, $2, $3, $6
    } else {
      if ($4 == "elision") c = 4
      else c = 3
      printf "span-audit: case %d: %s\n", c, $6
    }
  }' "$TMPD/findings" >&2

jq -Rn '[ inputs | split("\u001f")
          | {claim_id: .[1], ac_id: .[2], token_class: .[3], token: .[4]} ]' \
  "$TMPD/findings"
exit 8
