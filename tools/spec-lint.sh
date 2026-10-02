#!/usr/bin/env bash
# spec-lint.sh — CDT-273 spec gate (bash + awk only).
#
#   bash tools/spec-lint.sh [--root DIR]
#
# Checks every specs/**/{SPEC,PERF,SAFE,COMPAT,ARCH}-*.md file:
#   1. skills/spec-tooling/check-format.sh (section-scoped)
#   2. specs/TDD.md index Status and Title match the file
#   3. backticked repo paths on **Covers** lines and in ## Covers / ## Test exist
#   4. ## Version History dates are monotonic (newest-first or oldest-first)
#   5. no "SPEC-N line M" citation under skills/, commands/, agents/, specs/, AGENTS.md
#      (fixtures/ and CHANGELOG.md are captured history and are skipped)
#
# A path listed in tools/spec-lint.allow (one repo-relative path per line,
# # comments) is an intentional example and is not a missing-path finding.
# Exit 0 clean, 1 findings, 64 usage.
set -u
ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
if [ "${1:-}" = "--root" ]; then
  ROOT=$2
  shift 2
fi
[ $# -eq 0 ] || { echo "usage: spec-lint.sh [--root DIR]" >&2; exit 64; }
FMT="$ROOT/skills/spec-tooling/check-format.sh"
ALLOW="$ROOT/tools/spec-lint.allow"
FAIL=0
say() { printf '%s\n' "$*" >&2; FAIL=$((FAIL + 1)); }

allowed() {
  local p=$1
  [ -f "$ALLOW" ] || return 1
  grep -qxF "$p" "$ALLOW"
}

# --- 1 and 2 and 3 and 4: each spec file ---
mapfile_specs() {
  find "$ROOT/specs" -type f \( \
    -name 'SPEC-*.md' -o -name 'PERF-*.md' -o -name 'SAFE-*.md' \
    -o -name 'COMPAT-*.md' -o -name 'ARCH-*.md' \) | LC_ALL=C sort
}

index_field() { # index_field <id> <col 3=title 4=status>
  awk -F'|' -v id="$1" -v col="$2" '
    $0 ~ "^\\| " id " \\|" {
      gsub(/^ +| +$/, "", $col)
      print $col
      exit
    }
  ' "$ROOT/specs/TDD.md"
}

while IFS= read -r spec; do
  rel=${spec#"$ROOT/"}
  fmt_err=$(mktemp "${TMPDIR:-/tmp}/spec-lint-fmt.XXXXXX")
  if ! bash "$FMT" "$spec" >/dev/null 2>"$fmt_err"; then
    say "$rel: [format] $(tr '\n' ' ' < "$fmt_err")"
  fi
  rm -f "$fmt_err"
  id=$(sed -n 's/^# \(SPEC\|PERF\|SAFE\|COMPAT\|ARCH\)-[0-9][0-9]*:.*/\1/p' "$spec" | head -1)
  # id line includes the number; the sed above only captured the prefix. Re-read.
  id=$(sed -n 's/^# \(\(SPEC\|PERF\|SAFE\|COMPAT\|ARCH\)-[0-9][0-9]*\):.*/\1/p' "$spec" | head -1)
  [ -n "$id" ] || { say "$rel: [index] no spec id in the H1"; continue; }
  title=$(sed -n "s/^# $id: //p" "$spec" | head -1)
  status=$(sed -n 's/^\*\*Status\*\*:[[:space:]]*//p' "$spec" | head -1)
  status=${status%% *}
  ititle=$(index_field "$id" 3)
  istatus=$(index_field "$id" 4)
  istatus=${istatus%% *}
  if [ -z "$ititle" ]; then
    say "$rel: [index] $id is not a row in specs/TDD.md"
  else
    [ "$title" = "$ititle" ] || say "$rel: [index] title [$title] != TDD [$ititle]"
    [ "$status" = "$istatus" ] || say "$rel: [index] status [$status] != TDD [$istatus]"
  fi

  # Covers line + ## Covers / ## Test bodies: backticked paths
  awk -v root="$ROOT" -v rel="$rel" -v allow="$ALLOW" '
    function okpath(p) {
      # Skip slash-commands, env vars, globs, and placeholders.
      if (p ~ /^[/$]/ || p ~ /[*<> {}]/) return 1
      if (p !~ /^(skills|commands|agents|specs|tools|docs|githooks|tests|\.github|\.claude-plugin)\//) return 1
      sub(/[),.;:]+$/, "", p)
      sub(/\/$/, "", p)
      if (p == "") return 1
      if (allow != "" && system("test -f \"" allow "\" && grep -qxF -- \"" p "\" \"" allow "\"") == 0) return 1
      return system("test -e \"" root "/" p "\"") == 0
    }
    BEGIN { in_sec=0; n=0 }
    /^\*\*Covers\*\*/ { covers=1 }
    /^## (Covers|Test)[[:space:]]*$/ { in_sec=1; next }
    in_sec && /^## / { in_sec=0 }
    {
      use = covers || in_sec
      covers = 0
      if (!use) next
      line=$0
      while (match(line, /`[^`]+`/)) {
        tok=substr(line, RSTART+1, RLENGTH-2)
        line=substr(line, RSTART+RLENGTH)
        if (okpath(tok)) continue
        print rel ":" NR ": [covers] `" tok "` does not exist" > "/dev/stderr"
        n++
      }
    }
    END { exit n ? 1 : 0 }
  ' "$spec" || FAIL=$((FAIL + 1))

  # Version history monotonic
  awk -v rel="$rel" '
    /^## Version History[[:space:]]*$/ { in_sec=1; next }
    in_sec && /^## / { in_sec=0 }
    in_sec && /^\| *[0-9]{4}-[0-9]{2}-[0-9]{2} / {
      d=$0
      sub(/^\| */, "", d)
      sub(/ *\|.*/, "", d)
      dates[++n]=d
    }
    END {
      if (n < 2) exit 0
      # Direction comes from the first pair that is not a tie. Equal neighbors
      # are in order either way.
      dir = 0
      for (i = 2; i <= n; i++) {
        if (dates[i-1] == dates[i]) continue
        if (dir == 0) {
          dir = (dates[i-1] > dates[i]) ? -1 : 1
          continue
        }
        cmp = (dates[i-1] > dates[i]) ? 1 : -1
        if (dir == -1 && cmp < 0) {
          print rel ": [history] " dates[i-1] " then " dates[i] " breaks newest-first order" > "/dev/stderr"
          exit 1
        }
        if (dir == 1 && cmp > 0) {
          print rel ": [history] " dates[i-1] " then " dates[i] " breaks oldest-first order" > "/dev/stderr"
          exit 1
        }
      }
      exit 0
    }
  ' "$spec" || FAIL=$((FAIL + 1))
done < <(mapfile_specs)

# Index rows whose file is missing. Process substitution keeps `say` in
# this shell — a pipeline would drop FAIL and still print "clean".
while IFS= read -r id; do
  [ -n "$id" ] || continue
  if ! find "$ROOT/specs" \( -name "${id}-*.md" -o -name "${id}.md" \) | grep -q .; then
    say "specs/TDD.md: [index] $id has no spec file"
  fi
done < <(awk -F'|' '
  /^\| (SPEC|PERF|SAFE|COMPAT|ARCH)-[0-9]+ / {
    id=$2; gsub(/ /, "", id); print id
  }
' "$ROOT/specs/TDD.md")

# --- 4b. specs/OWNERS: one owner per shipped surface ---
# A tree with no command, agent, or skill surface (the spec-lint fixture)
# has nothing to own. The product tree has surfaces, so a missing map fails.
OWN="$ROOT/specs/OWNERS"
surfaces=$(mktemp "${TMPDIR:-/tmp}/spec-lint-surf.XXXXXX")
find "$ROOT/commands" "$ROOT/agents" -type f -name '*.md' -print 2>/dev/null > "$surfaces" || true
find "$ROOT/skills" -mindepth 2 -maxdepth 2 -type f -name 'SKILL.md' -print 2>/dev/null >> "$surfaces" || true
if [ ! -s "$surfaces" ]; then
  rm -f "$surfaces"
else
  own_err=$(mktemp "${TMPDIR:-/tmp}/spec-lint-own.XXXXXX")
  if [ ! -f "$OWN" ]; then
    printf '%s\n' "file missing" > "$own_err"
  else
  awk -F'\t' '
    /^[[:space:]]*#/ || NF == 0 { next }
    {
      if (NF != 2) { print "bad-line " NR; next }
      if (seen[$1]++) print "duplicate " $1
      if ($2 !~ /^(SPEC-[0-9]+|UNSPECCED)$/) print "bad-owner " $1
    }
  ' "$OWN" > "$own_err"
  while IFS= read -r abs; do
    rel=${abs#"$ROOT/"}
    case "$rel" in
      skills/*/SKILL.md) key=${rel%/SKILL.md} ;;
      *) key=$rel ;;
    esac
    n=$(awk -F'\t' -v k="$key" 'NF==2 && $1==k { c++ } END { print c+0 }' "$OWN")
    if [ "$n" -eq 0 ]; then
      printf 'missing %s\n' "$key" >> "$own_err"
    elif [ "$n" -ne 1 ]; then
      printf 'duplicate %s\n' "$key" >> "$own_err"
    fi
  done < "$surfaces"
  awk -F'\t' 'NF==2 { print $1 }' "$OWN" | while IFS= read -r key; do
    case "$key" in
      commands/*.md) path="$ROOT/$key" ;;
      agents/*.md) path="$ROOT/$key" ;;
      skills/*) path="$ROOT/$key/SKILL.md" ;;
      *) printf 'bad-key %s\n' "$key" >> "$own_err"; continue ;;
    esac
    [ -f "$path" ] || printf 'stale %s\n' "$key" >> "$own_err"
  done
  fi
  if [ -s "$own_err" ]; then
    while IFS= read -r line; do
      say "specs/OWNERS: [owners] $line"
    done < "$own_err"
  fi
  rm -f "$own_err" "$surfaces"
fi

# --- 5. citation ban ---
cite_scan() {
  find "$ROOT/skills" "$ROOT/commands" "$ROOT/agents" "$ROOT/specs" \
    "$ROOT/AGENTS.md" -type f -name '*.md' 2>/dev/null
}
while IFS= read -r f; do
  case "$f" in
    */fixtures/*|*/CHANGELOG.md) continue ;;
  esac
  rel=${f#"$ROOT/"}
  awk -v rel="$rel" '
    { line[NR] = $0 }
    END {
      for (i = 1; i <= NR; i++) {
        cur = line[i]
        nxt = (i < NR) ? line[i + 1] : ""
        hit = 0
        if (cur ~ /SPEC-[0-9]+[[:space:]]+lines?[[:space:]]+[0-9]+/) hit = 1
        if (cur ~ /SPEC-[0-9]+[[:space:]]+[A-Za-z]+[[:space:]]+lines?[[:space:]]+[0-9]+/) hit = 1
        if (cur ~ /SPEC-[0-9]+[[:space:]]*$/ && nxt ~ /^[[:space:]]*lines?[[:space:]]*[0-9]/) hit = 1
        if (cur ~ /SPEC-[0-9]+[[:space:]]+lines?[[:space:]]*$/ && nxt ~ /^[[:space:]]*[0-9]/) hit = 1
        if (!hit) continue
        print rel ":" i ": [citation] use a section anchor, not a line number: " cur > "/dev/stderr"
        n++
      }
      exit n ? 1 : 0
    }
  ' "$f" || FAIL=$((FAIL + 1))
done < <(cite_scan)

if [ "$FAIL" -eq 0 ]; then
  echo "spec-lint: clean"
  exit 0
fi
echo "spec-lint: $FAIL finding(s)" >&2
exit 1
