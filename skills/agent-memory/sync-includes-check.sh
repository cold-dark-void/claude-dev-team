#!/usr/bin/env bash
# sync-includes-check.sh — expand and verify managed <!-- include --> regions
# (release gate 4.5). Bash/awk port of the retired python engine (CDT-615);
# the host forbids python3, so this is the single implementation for check and apply.
#
# A managed region looks like:
#
#   <!-- include: <partial-relpath> agent=<X> -->
#   ...region body (generated)...
#   <!-- /include -->
#
# The region body MUST equal the partial expanded for agent <X>:
#   * strip the partial's leading HTML-comment block (everything up to and
#     including the first line that is exactly `-->`),
#   * strip surrounding blank lines,
#   * replace every literal `<AGENT>` with <X>.
#
# Usage: sync-includes-check.sh [check|apply] [--root ROOT] [files...]
#   check  verify managed regions match their partials (default); exit 1 on drift
#   apply  rewrite every managed region from its partial
#
# With no files, scans the repo's agents/, skills/, commands/ and AGENTS.md for
# markdown carrying markers. The partial path in each marker is resolved relative
# to the repo root and MUST stay under it (`../`, `~`, and absolute paths are
# rejected). A missing partial and an open/close pairing mismatch are hard errors:
# apply aborts before writing anything (rv-w3-25).
#
# Exit 0 clean / 1 drift or marker-partial error / 64 usage.
# POSIX awk only, no md5sum (macOS lane, R13). THIS SCRIPT IS A SUBPROCESS CLI —
# NEVER SOURCE IT.
set -u

PROG="sync-includes-check.sh"
USAGE="Usage: $PROG [check|apply] [--root ROOT] [files...]

  check  verify managed include regions match their partials (default); exit 1 on drift
  apply  rewrite every managed region from its partial

With no files, scans the repo's agents/, skills/, commands/ and AGENTS.md for markdown carrying markers.
Exit 64 on an unrecognised mode or bad usage; exit 1 on drift or a marker/partial
error (missing partial, path escape, unclosed region)."

die() { printf '%s: error: %s\n' "$PROG" "$*" >&2; exit 1; }

# ---- argument parsing (python order: --root strip, then help, then mode) ----
args=()
while [ $# -gt 0 ]; do args+=("$1"); shift; done
root='.'
i=0
ri=-1
while [ $i -lt ${#args[@]} ]; do
  if [ "${args[$i]}" = '--root' ]; then ri=$i; break; fi
  i=$((i + 1))
done
if [ $ri -ge 0 ]; then
  if [ $((ri + 1)) -ge ${#args[@]} ]; then
    printf '%s: --root requires a value\n' "$PROG" >&2
    printf '%s\n' "$USAGE" >&2
    exit 64
  fi
  root="${args[$((ri + 1))]}"
  kept=()
  i=0
  while [ $i -lt ${#args[@]} ]; do
    if [ $i -eq $ri ]; then i=$((i + 2)); continue; fi
    kept+=("${args[$i]}")
    i=$((i + 1))
  done
  args=()
  if [ ${#kept[@]} -gt 0 ]; then args=("${kept[@]}"); fi
fi

if [ ${#args[@]} -gt 0 ] && { [ "${args[0]}" = '-h' ] || [ "${args[0]}" = '--help' ]; }; then
  printf '%s\n' "$USAGE"
  exit 0
fi

mode='check'
if [ ${#args[@]} -gt 0 ]; then mode="${args[0]}"; fi
case $mode in
  check|apply) ;;
  *)
    printf '%s: unrecognised mode: %s\n' "$PROG" "$mode" >&2
    printf '%s\n' "$USAGE" >&2
    exit 64
    ;;
esac

files=()
if [ ${#args[@]} -gt 1 ]; then
  i=1
  while [ $i -lt ${#args[@]} ]; do files+=("${args[$i]}"); i=$((i + 1)); done
fi

root_real=$(CDPATH= cd -- "$root" 2>/dev/null && pwd -P) \
  || { printf '%s: --root is not a directory: %s\n' "$PROG" "$root" >&2; exit 64; }

tmp=$(mktemp -d "${TMPDIR:-/tmp}/syncinc.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

# ---- default file discovery (same set as the retired python default_files) ----
if [ ${#files[@]} -eq 0 ]; then
  {
    ls "$root"/agents/*.md 2>/dev/null
    find "$root/skills" -name '*.md' 2>/dev/null
    find "$root/commands" -name '*.md' 2>/dev/null
    [ -f "$root/AGENTS.md" ] && printf '%s\n' "$root/AGENTS.md"
  } | LC_ALL=C sort -u > "$tmp/scan.list"
  while IFS= read -r f; do
    # Absent candidates (a root with no AGENTS.md) drop out here — python's glob
    # omits them; only files listed explicitly on the command line are hard errors.
    [ -f "$f" ] && grep -q '<!-- include:' "$f" && files+=("$f")
  done < "$tmp/scan.list"
fi

# trimnl: join stdin lines with \n, dropping blank edge lines (python .strip('\n')).
trimnl() {
  awk '{ lines[NR] = $0 }
    END {
      s = 1; e = NR
      while (s <= e && lines[s] == "") s++
      while (e >= s && lines[e] == "") e--
      out = ""
      for (i = s; i <= e; i++) out = out (i == s ? "" : "\n") lines[i]
      printf "%s", out
    }'
}

# expand_partial <partial-file> <agent> <dest>
expand_partial() {
  awk -v ag="$2" '{ lines[NR] = $0 }
    END {
      start = 1
      for (i = 1; i <= NR; i++) {
        l = lines[i]; gsub(/^[[:space:]]+|[[:space:]]+$/, "", l)
        if (l == "-->") { start = i + 1; break }
      }
      s = start; e = NR
      while (s <= e && lines[s] == "") s++
      while (e >= s && lines[e] == "") e--
      out = ""
      for (i = s; i <= e; i++) out = out (i == s ? "" : "\n") lines[i]
      n = 0
      while ((i = index(out, "<AGENT>")) > 0) {
        out = substr(out, 1, i - 1) ag substr(out, i + 7)
        n++
        if (n > 10000) break
      }
      printf "%s", out
    }' "$1" > "$3"
}

# parse_regions <file> <label> <dest>: emit "R\t<open>\t<close>\t<partial>\t<agent>"
# per managed region; exit 2 with an error: line on a marker/pairing fault.
# A line opens a region only when the open marker ends the line, and closes only
# when the line is exactly the close marker (modulo indentation) — prose mentions
# of the markers are ignored.
parse_regions() {
  awk -v file="$2" '
    function err(m) { print m > "/dev/stderr"; bad = 1; exit 2 }
    {
      if ($0 ~ /<!-- include: [^[:space:]]+ agent=[^[:space:]]+ -->$/) {
        if (open) err(sprintf("%s:%d: unclosed region \x27%s\x27 opened at line %d — every \x27<!-- include:\x27 needs its own \x27<!-- /include -->\x27 before the next open", file, NR, opart, oline))
        open = 1; oline = NR; opart = $0; oagent = $0
        sub(/^.*<!-- include: /, "", opart); sub(/ agent=[^ ]* -->$/, "", opart)
        sub(/^.* agent=/, "", oagent); sub(/ -->$/, "", oagent)
        next
      }
      line = $0; gsub(/^[[:space:]]+|[[:space:]]+$/, "", line)
      if (line == "<!-- /include -->") {
        if (!open) err(sprintf("%s:%d: \x27<!-- /include -->\x27 without a matching open marker", file, NR))
        printf "R\t%d\t%d\t%s\t%s\n", oline, NR, opart, oagent
        open = 0; next
      }
    }
    END {
      if (open && !bad) err(sprintf("%s: unclosed region \x27%s\x27 opened at line %d — missing \x27<!-- /include -->\x27", file, opart, oline))
    }
  ' "$1" > "$3" 2>"$tmp/awkerr"
  s=$?
  if [ $s -ne 0 ]; then
    [ -s "$tmp/awkerr" ] && die "$(cat "$tmp/awkerr")"
    die "marker parse error in $2"
  fi
  return 0
}

drift=0
changed=0
nfiles=0
n=0

for f in ${files[@]+"${files[@]}"}; do
  # Explicit files are parsed unconditionally (an orphan close is an error even
  # in a file with no open marker); discovery already filters on the marker.
  [ -f "$f" ] || die "no such file: $f"

  printf '%s\n' "$f" > "$tmp/path.$nfiles"
  parse_regions "$f" "$f" "$tmp/regions.$nfiles"
  nfiles=$((nfiles + 1))

  : > "$tmp/rew.$((nfiles - 1))"
  while IFS=$'\t' read -r tag oline cline part agent; do
    [ "$tag" = R ] || continue
    case $part in
      \~*) die "partial path must stay under the repo root: $part" ;;
      /*) die "absolute partial path is not allowed: $part" ;;
    esac
    case "/$part/" in
      */../*) die "partial path must not contain '..': $part" ;;
    esac
    ppath="$root/$part"
    [ -f "$ppath" ] || die "partial not found: $part (looked for $ppath)"
    # Containment: resolve the leaf symlink chain (readlink — no realpath -e on
    # BSD), then the parent directory, and keep the result under the root.
    pp="$ppath"
    hops=0
    while [ -L "$pp" ] && [ $hops -lt 40 ]; do
      tgt=$(readlink -- "$pp" 2>/dev/null) || break
      case $tgt in
        /*) pp="$tgt" ;;
        *) pp="$(dirname -- "$pp")/$tgt" ;;
      esac
      hops=$((hops + 1))
    done
    pdir=$(CDPATH= cd -- "$(dirname -- "$pp")" 2>/dev/null && pwd -P) \
      || die "partial not found: $part (looked for $ppath)"
    preal="$pdir/$(basename -- "$pp")"
    case $preal in
      "$root_real"|"$root_real"/*) ;;
      *) die "partial resolves outside the repo root: $part" ;;
    esac

    n=$((n + 1))
    expand_partial "$ppath" "$agent" "$tmp/want.$n"
    awk -v s="$oline" -v e="$cline" 'NR > s && NR < e' "$f" | trimnl > "$tmp/have.$n"

    if ! cmp -s "$tmp/have.$n" "$tmp/want.$n"; then
      if [ "$mode" = check ]; then
        drift=$((drift + 1))
        printf 'DRIFT: %s (agent=%s, partial=%s)\n' "$f" "$agent" "$part"
        # BSD diff lacks -L: relabel the header lines with awk (no temp files)
        diff -u "$tmp/have.$n" "$tmp/want.$n" \
          | awk '$0 == "\\ No newline at end of file" { next }
                 NR==1 && $0 ~ /^--- / { print "  --- in-file"; next }
                 NR==2 && $0 ~ /^\+\+\+ / { print "  +++ partial-expanded"; next }
                 { if ($0 ~ /^(-{3}|\+\+\+) /) sub(/\t.*$/, ""); print "  " $0 }'
      else
        changed=$((changed + 1))
        printf '%s\t%s\t%s\t%s\n' "$oline" "$cline" "$tmp/want.$n" '' >> "$tmp/rew.$((nfiles - 1))"
      fi
    fi
  done < "$tmp/regions.$((nfiles - 1))"
done

if [ "$mode" = apply ]; then
  # Every region validated and every rewrite staged above: an abort exits before
  # any write (rv-w3-25). Rewrite each file bottom-up so staged line ranges stay
  # valid, and write only the scanned file.
  i=0
  while [ $i -lt $nfiles ]; do
    if [ -s "$tmp/rew.$i" ]; then
      IFS= read -r rf < "$tmp/path.$i"
      # A file that ends without a newline stays that way: awk's print appends
      # one, so drop the last byte when the scanned file had none.
      lastchar=$(tail -c 1 "$rf")
      cp "$rf" "$tmp/cur"
      m=$(awk 'END { print NR }' "$tmp/rew.$i")
      while [ "$m" -gt 0 ]; do
        rec=$(awk -v n="$m" 'NR == n' "$tmp/rew.$i")
        o=$(printf '%s' "$rec" | cut -f1)
        c=$(printf '%s' "$rec" | cut -f2)
        w=$(printf '%s' "$rec" | cut -f3)
        awk -v s="$o" -v e="$c" -v W="$w" '{
            if (NR <= s) print
            if (NR == s) { while ((getline l < W) > 0) print l; close(W) }
            if (NR >= e) print
          }' "$tmp/cur" > "$tmp/next"
        mv "$tmp/next" "$tmp/cur"
        m=$((m - 1))
      done
      if [ -n "$lastchar" ]; then
        # Rejoin without the trailing newline (BSD head has no negative -c).
        awk 'NR > 1 { printf "\n" } { printf "%s", $0 }' "$tmp/cur" > "$tmp/final"
        cat "$tmp/final" > "$rf"
      else
        cat "$tmp/cur" > "$rf"
      fi
    fi
    i=$((i + 1))
  done
  printf 'apply: rewrote %d region(s).\n' "$changed"
  exit 0
fi

if [ "$drift" -gt 0 ]; then
  printf '\n%d managed include region(s) drifted from their partial.\n' "$drift" >&2
  exit 1
fi
printf 'All managed include regions match their partials.\n'
exit 0
