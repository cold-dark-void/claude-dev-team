#!/usr/bin/env bash
# skills/backlog/sweep-test.sh — SPEC-040 § CDT-582 Phase-1 suite (AC1–AC16).
#
# Two layers of bites:
#   1. Data plane — every sweep.sh verb (T1 helpers, T3 purge evidence) plus
#      defer.sh / close.sh as the sweep's write verbs.
#   2. Composition — sweep_sim runs the skills/backlog/sweep.md steps over a
#      hermetic repo with the real verbs, so AC2, AC10, AC13, AC14, AC15 and
#      AC16 are observed, not just asserted.
#
# Rules only the host can obey (batch listing, print-and-run, attended gates,
# the Linear MCP call) are asserted against the protocol text and marked
# `(protocol-assert)`.
#
# Every case prints `PASS: AC<n>: ...`; the COVERAGE gate refuses a clean run
# when any AC1–AC16 has no passing case.
#
# Hermetic: tests/lib/hermetic.sh roots every fixture under $TMPDIR (git
# ceiling, fake HOME, fixed git identity). Never writes into the real repo.
#
# Exit: 0 all bites pass, 1 any failure.

set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SWEEP="$HERE/sweep.sh"
DEFER="$HERE/defer.sh"
CLOSE="$HERE/close.sh"
TS_SH="$HERE/terminal-status.sh"
SLUG_SH="$HERE/slug.sh"
READERS="$HERE/readers.sh"
SWEEP_MD="$HERE/sweep.md"
SKILL_MD="$HERE/SKILL.md"
SQLQ="$HERE/../lib/sqlq.sh"
GITIGNORE="$HERE/../../.gitignore"

for _f in "$SWEEP" "$DEFER" "$CLOSE" "$TS_SH" "$SLUG_SH" "$READERS" "$SWEEP_MD" "$SKILL_MD" "$GITIGNORE"; do
  [ -f "$_f" ] || { printf 'FAIL: missing %s\n' "$_f"; printf 'VERIFY exit=1\n'; exit 1; }
done

# shellcheck source=../../tests/lib/hermetic.sh
. "$HERE/../../tests/lib/hermetic.sh"
hermetic_init
# Git fixtures must not inherit the harness's own repo context.
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR

WORK="$HERMETIC_ROOT/work"
mkdir -p "$WORK"
LOG="$WORK/cases.log"
: > "$LOG"

FAILS=0
PASSN=0

emit() {
  printf '%s\n' "$1"
  printf '%s\n' "$1" >> "$LOG"
}

check() { # check <ac> <name> <expected> <actual>
  if [ "$3" = "$4" ]; then
    PASSN=$((PASSN + 1))
    emit "PASS: $1: $2"
  else
    emit "FAIL: $1: $2"
    emit "  expected=[$3]"
    emit "  actual=[$4]"
    FAILS=$((FAILS + 1))
  fi
}

check_ge() { # check_ge <ac> <name> <min> <actual>
  if [ "${4:-0}" -ge "$3" ]; then
    PASSN=$((PASSN + 1))
    emit "PASS: $1: $2 (got $4 >= $3)"
  else
    emit "FAIL: $1: $2"
    emit "  expected >=$3, got ${4:-0}"
    FAILS=$((FAILS + 1))
  fi
}

check_lt() { # check_lt <ac> <name> <max> <actual>
  if [ "${4:-999999}" -lt "$3" ]; then
    PASSN=$((PASSN + 1))
    emit "PASS: $1: $2 (got $4 < $3)"
  else
    emit "FAIL: $1: $2"
    emit "  expected <$3, got ${4:-?}"
    FAILS=$((FAILS + 1))
  fi
}

rc_is() { # rc_is <ac> <name> <expected-rc> <cmd...>
  local ac="$1" name="$2" want="$3" out rc
  shift 3
  out=$("$@" 2>&1)
  rc=$?
  if [ "$rc" = "$want" ]; then
    PASSN=$((PASSN + 1))
    emit "PASS: $ac: $name (rc=$rc)"
  else
    emit "FAIL: $ac: $name"
    emit "  expected rc=$want, got rc=$rc: $out"
    FAILS=$((FAILS + 1))
  fi
}

count_in() { # count_in <ac> <name> <want> <file> <fixed-string>
  local n
  n=$(grep -cF "$5" "$4" 2>/dev/null || true)
  check "$1" "$2" "$3" "${n:-0}"
}

count_not() { # count_not <ac> <name> <file> <ERE> — assert zero matches
  local n
  n=$(grep -cE "$4" "$3" 2>/dev/null || true)
  check "$1" "$2" "0" "${n:-0}"
}

md_rule() { # md_rule <ac> <name> <want-count> <fixed-string> — sweep.md text
  count_in "$1" "$2 (protocol-assert)" "$3" "$SWEEP_MD" "$4"
}

one_line() { # collapse newlines/repeats of spaces into one line
  printf '%s' "$1" | tr '\n' ' ' | tr -s ' '
}

item_status() { # item_status <root> <slug>
  local f="$1/.claude/backlog/$2.md"
  [ -f "$f" ] || { printf 'NOFILE\n'; return 0; }
  grep -m1 -E '^\*\*Status\*\*:' "$f" | sed 's/^\*\*Status\*\*:[[:space:]]*//' | awk '{print $1}'
}

affects_of() { # affects_of <file> — one path per line, empty when no section
  local f="$1"
  [ -f "$f" ] || return 0
  awk '/^## Affects/ { a = 1; next }
       a && /^## / { a = 0 }
       a && /^- / { sub(/^- +/, ""); print }' "$f"
}

effort_of() { # effort_of <file> — S|M|L from the ## Effort section, else empty
  local f="$1" v=""
  [ -f "$f" ] || return 0
  v=$(awk '/^## Effort/ { a = 1; next }
           a && /^## / { a = 0 }
           a { line = $0; gsub(/^[[:space:]]+|[[:space:]]+$/, "", line)
               if (line == "S" || line == "M" || line == "L") { print line; exit } }' "$f")
  printf '%s\n' "$v"
}

# ===========================================================================
# Fixtures
# ===========================================================================

# --- merge-open fixture (not a git repo: the local scan is read-only) ------
LR="$WORK/localroot"
mkdir -p "$LR/.claude/backlog"
printf '%s\n' '# Backlog Index' '' '## Pending' '' \
  '- [Linked item](backlog/linked-item.md) - Linked item [PENDING] linear:CDT-99' \
  '- [Local only](backlog/local-only.md) - Local only [PENDING]' '' '## Completed' '' \
  '- [Done thing](backlog/done-thing.md) - Done thing [COMPLETED]' > "$LR/.claude/backlog.md"
cat > "$LR/.claude/backlog/linked-item.md" <<'EOF'
---
linear_id: CDT-99
---

# Linked item

**Status**: PENDING

## Problem

x

## Goal

y

---

*Added: 2026-07-01*
EOF
cat > "$LR/.claude/backlog/local-only.md" <<'EOF'
# Local only

**Status**: PENDING

## Problem

z

## Goal

w

---

*Added: 2026-06-02*
EOF
cat > "$LR/.claude/backlog/done-thing.md" <<'EOF'
# Done thing

**Status**: COMPLETED

## Problem

q

## Goal

r

---

*Added: 2026-01-01*
*Closed: 2026-02-01*
EOF
cat > "$LR/.claude/backlog/deferred-item.md" <<'EOF'
# Deferred item

**Status**: DEFERRED

## Problem

d

## Goal

e

---

*Added: 2026-03-03*
*Deferred: 2026-04-04 — not now*
EOF
cat > "$LR/.claude/backlog/epic-kid.md" <<'EOF'
---
epic_parent: CDT-46
---

# Epic kid

**Status**: PENDING

## Problem

f

## Goal

g

---

*Added: 2026-05-05*
EOF
cat > "$LR/.claude/backlog/metachar.md" <<'EOF'
# '; echo pwned $(uname) --project

**Status**: PENDING

## Problem

`; drop table backlog -- ` and $(uname)

## Goal

Nothing runs.

---

*Added: 2026-05-06*
EOF
cat > "$WORK/linear.json" <<'EOF'
[
  {"identifier":"CDT-99","title":"Linked item","priority":2,"createdAt":"2026-06-30T08:00:00Z"},
  {"identifier":"CDT-140","title":"Linear only","priority":1,"createdAt":"2026-08-01T08:00:00Z"},
  {"identifier":"CDT-141","title":"Linear epic child","priority":0,"createdAt":"2026-08-02T08:00:00Z","parentId":"CDT-46"}
]
EOF
: > "$WORK/empty-linear.json"
BADLIN="$WORK/bad-linear.json"
printf '%s\n' 'not json at all' > "$BADLIN"

# --- release-tag fixtures (AC12) -------------------------------------------
TAGR="$WORK/tagrepo"
mkdir -p "$TAGR"
git -C "$TAGR" init -q 2>/dev/null
git -C "$TAGR" commit -q --allow-empty -m one
git -C "$TAGR" tag v1.2.3
git -C "$TAGR" commit -q --allow-empty -m two
git -C "$TAGR" tag nightly-9
git -C "$TAGR" tag v1.2.4-rc1
NOTAG="$WORK/notag"
mkdir -p "$NOTAG"
git -C "$NOTAG" init -q 2>/dev/null

# --- evidence-paths-absent fixture (AC3 (a)) -------------------------------
EVR="$WORK/evrepo"
mkdir -p "$EVR/sub dir" "$EVR/src"
git -C "$EVR" init -q 2>/dev/null
printf '%s\n' 'seeded' > "$EVR/gone.md"
printf '%s\n' 'seeded' > "$EVR/sub dir/gone.md"
printf '%s\n' 'seeded' > "$EVR/src/a.c"
printf '%s\n' 'kept' > "$EVR/here.md"
git -C "$EVR" add -A
git -C "$EVR" commit -q -m seed
rm -f "$EVR/gone.md"
rm -rf "$EVR/sub dir"
git -C "$EVR" add -A
git -C "$EVR" commit -q -m purge
printf '%s\n' 'staged only' > "$EVR/staged.md"
git -C "$EVR" add -A
EVH_DATE=$(git -C "$EVR" log -1 --format=%cd --date=short HEAD)
NOTGIT="$WORK/notgit"; mkdir -p "$NOTGIT"

# --- evidence-shipped-after fixtures (AC3 (b)) -----------------------------
SH1="$WORK/shipped1"
mkdir -p "$SH1/specs/core"
cat > "$SH1/CHANGELOG.md" <<'EOF'
# Changelog

### v1.9.0

- Shipped the thing (2026-05-05)

### v1.8.0

- Older thing, undated
EOF
cat > "$SH1/specs/core/SPEC-002-fake.md" <<'EOF'
# SPEC-002: Fake

**Created**: 2026-04-01
EOF
git -C "$SH1" init -q 2>/dev/null
git -C "$SH1" add -A
git -C "$SH1" commit -q -m ship
git -C "$SH1" commit -q --allow-empty -m later
GIT_COMMITTER_DATE='2026-06-01T12:00:00 +0000' git -C "$SH1" tag -a v1.9.0 -m rel
SH2="$WORK/shipped2"
mkdir -p "$SH2/specs/core"
cat > "$SH2/CHANGELOG.md" <<'EOF'
# Changelog

### v0.1.0

- Section date only: 2026-02-02
EOF
cat > "$SH2/specs/core/SPEC-009-fake.md" <<'EOF'
# SPEC-009: Fake

**Created**: 2025-12-25
EOF
git -C "$SH2" init -q 2>/dev/null
git -C "$SH2" add -A
git -C "$SH2" commit -q -m two
EMPTY="$WORK/emptyrepo"
mkdir -p "$EMPTY"
git -C "$EMPTY" init -q 2>/dev/null
git -C "$EMPTY" commit -q --allow-empty -m e

# --- sweep_sim repos (composition bites) -----------------------------------
# write_item <root> <slug> <title> <status> <added> <frontmatter> <affects> <effort>
write_item() {
  local root="$1" slug="$2" title="$3" status="$4" added="$5" fm="$6" aff="$7" eff="$8"
  {
    if [ -n "$fm" ]; then printf -- '---\n%s\n---\n\n' "$fm"; fi
    printf '# %s\n\n**Status**: %s\n\n' "$title" "$status"
    printf '## Problem\n\nBody for %s.\n\n' "$slug"
    if [ -n "$aff" ]; then printf '## Affects\n\n%s\n\n' "$aff"; fi
    if [ -n "$eff" ]; then printf '## Effort\n\n%s\n\n' "$eff"; fi
    printf -- '---\n\n*Added: %s*\n' "$added"
  } > "$root/.claude/backlog/$slug.md"
}

REPOA="$WORK/repoA"
mkdir -p "$REPOA/.claude/backlog" "$REPOA/src" "$REPOA/gone" "$REPOA/specs/core"
cp "$GITIGNORE" "$REPOA/.gitignore"
cat > "$REPOA/CHANGELOG.md" <<'EOF'
# Changelog

### v1.9.0

- Backlog sweep (2026-05-20)

### v1.8.0

- Older thing
EOF
cat > "$REPOA/specs/core/SPEC-900-fake.md" <<'EOF'
# SPEC-900: Fake

**Created**: 2026-06-01
EOF
printf '%s\n' 'int main(void){return 0;}' > "$REPOA/src/keep.c"
printf '%s\n' 'deleted at purge' > "$REPOA/gone/x.sh"
printf '%s\n' 'deleted at purge' > "$REPOA/gone/y.md"
git -C "$REPOA" init -q 2>/dev/null
git -C "$REPOA" add -A
GIT_AUTHOR_DATE='2026-05-20T09:00:00 +0000' GIT_COMMITTER_DATE='2026-05-20T09:00:00 +0000' \
  git -C "$REPOA" commit -q -m seed
rm -rf "$REPOA/gone"
git -C "$REPOA" add -A
# The plugin's release tags are lightweight (`git tag vX.Y.Z`), so the protocol's
# `%(committerdate:iso8601-strict)` baseline resolves from the tagged commit.
GIT_COMMITTER_DATE='2026-06-01T09:00:00 +0000' git -C "$REPOA" commit -q --allow-empty -m release
git -C "$REPOA" tag v1.9.0
cat > "$REPOA/.claude/backlog.md" <<'EOF'
# RepoA - Backlog Index

## Pending

- [Stale absent](backlog/stale-absent.md) - Stale absent [PENDING]
- [Stale present](backlog/stale-present.md) - Stale present [PENDING]
- [Stale shipped](backlog/stale-shipped.md) - Stale shipped [PENDING]
- [Metachar](backlog/metachar-item.md) - Metachar [PENDING]
- [Work S](backlog/work-s.md) - Work S [PENDING]
- [Work M](backlog/work-m.md) - Work M [PENDING]
- [Work L](backlog/work-l.md) - Work L [PENDING]
- [Epic kid](backlog/epic-kid.md) - Epic kid [PENDING]

## Completed

- [Done thing](backlog/done-thing.md) - Done thing [COMPLETED]
EOF
write_item "$REPOA" stale-absent '[STALE] Cited paths are gone' PENDING 2026-01-05 '' \
  '- gone/x.sh
- gone/y.md' 'M'
write_item "$REPOA" stale-present '[STALE] Cited path still exists' PENDING 2026-01-06 '' \
  '- src/keep.c' 'S'
write_item "$REPOA" stale-shipped '[STALE] A later release shipped it' PENDING 2026-01-04 '' '' ''
write_item "$REPOA" metachar-item "'; echo pwned \$(uname) --project" PENDING 2026-01-07 '' \
  "never/\$(touch pwned.marker).md
- '; drop table backlog; --
- \$(uname)" 'L'
write_item "$REPOA" work-s 'Add a flag to list' PENDING 2026-07-01 '' '' 'S'
write_item "$REPOA" work-m 'Refactor the engine protocol' PENDING 2026-07-02 '' '' 'M'
write_item "$REPOA" work-l 'Split the memory subsystem' PENDING 2026-07-03 '' '' 'L'
write_item "$REPOA" epic-kid 'Epic child' PENDING 2026-05-05 'epic_parent: CDT-46' '' 'S'
write_item "$REPOA" done-thing 'Finished work' COMPLETED 2026-01-01 '' '' 'S'

REPOC="$WORK/repoC"
mkdir -p "$REPOC/.claude/backlog" "$REPOC/src" "$REPOC/specs/core"
cp "$GITIGNORE" "$REPOC/.gitignore"
cat > "$REPOC/CHANGELOG.md" <<'EOF'
# Changelog

### v0.1.0

- First thing (2026-02-02)
EOF
cat > "$REPOC/specs/core/SPEC-901-fake.md" <<'EOF'
# SPEC-901: Fake

**Created**: 2026-01-15
EOF
printf '%s\n' 'kept' > "$REPOC/src/keep.c"
git -C "$REPOC" init -q 2>/dev/null
git -C "$REPOC" add -A
GIT_COMMITTER_DATE='2026-03-01T09:00:00 +0000' git -C "$REPOC" commit -q -m seed
git -C "$REPOC" tag v1.0.0
printf '%s\n' '# RepoC - Backlog Index' '' '## Pending' '' \
  '- [Linked item](backlog/linked-item.md) - Linked item [PENDING] linear:CDT-99' '' \
  '## Completed' > "$REPOC/.claude/backlog.md"
write_item "$REPOC" linked-item 'Linked item' PENDING 2026-07-01 'linear_id: CDT-99' '' 'S'
cat > "$WORK/linear-up.json" <<'EOF'
[
  {"identifier":"CDT-99","title":"Linked item","priority":2,"createdAt":"2026-06-30T08:00:00Z"},
  {"identifier":"CDT-140","title":"[STALE] Linear only, no local file","priority":1,"createdAt":"2026-08-01T08:00:00Z"},
  {"identifier":"CDT-141","title":"Linear epic child","priority":0,"createdAt":"2026-08-02T08:00:00Z","parentId":"CDT-46"}
]
EOF

# journal_rec <file> <disposition> <evidence> <args> <tag_baseline> [outcome]
journal_rec() {
  local f="$1" disp="$2" evid="$3" args="$4" tag="$5" oc="${6:-}" ts rec
  ts=$(date -u +%Y-%m-%dT%H:%M)
  rec=$(jq -cn --arg ts "$ts" --arg disposition "$disp" --arg evidence "$(one_line "$evid")" \
    --arg args "$args" --arg tag_baseline "$tag" --arg outcome "$oc" \
    'if $outcome == "" then
       {ts:$ts, disposition:$disposition, evidence:$evidence, args:$args, tag_baseline:$tag_baseline}
     else
       {ts:$ts, disposition:$disposition, evidence:$evidence, args:$args, tag_baseline:$tag_baseline, outcome:$outcome}
     end')
  bash "$SWEEP" journal-append --file "$f" --json "$rec" >/dev/null
}

# decide_size <root> <slug> — sweep.md Step 9 rules 1 and 2 (Effort, then the
# Affects path count). Rule 3 escalation keywords are protocol-asserted.
decide_size() {
  local root="$1" slug="$2" f eff n
  f="$root/.claude/backlog/$slug.md"
  eff=$(effort_of "$f")
  case "$eff" in S|M|L) printf '%s\n' "$eff"; return 0 ;; esac
  n=$(affects_of "$f" | grep -c . || true)
  n=${n:-0}
  if [ "$n" -le 1 ]; then printf 'S\n'; elif [ "$n" -eq 2 ]; then printf 'M\n'; else printf 'L\n'; fi
}

# sweep_sim <root> <linear-json> <limit> <autopilot> <refresh> <events> <batch>
# Emulates skills/backlog/sweep.md Steps 2-10 with the real verbs and the real
# write verbs. stdout is the summary counts JSON. Events are appended in order.
sweep_sim() {
  local root="$1" lin="$2" limit="$3" ap="$4" refresh="$5" ev="$6" batch="$7"
  local d swd tag tag_date row total i slug lid title added epic key jline
  local n_open=0 n_skip=0 n_close=0 n_ask=0 n_defer=0 n_orch=0 n_esc=0
  local disp evid rc aff sz args oc pre p halt
  d=$(mktemp -d "$WORK/sim.XXXXXX") || return 2
  swd="$root/.claude/sweeps"
  : > "$batch"
  # Step 2 — snapshot the tag baseline once.
  tag=$(bash "$SWEEP" last-release-tag --root "$root") || return 2
  tag_date=""
  if [ -n "$tag" ]; then
    tag_date=$(bash "$SWEEP" tag-date --root "$root" --tag "$tag")
  fi
  printf 'BASELINE %s|%s\n' "${tag:-none}" "$tag_date" >> "$ev"
  # Step 3 — open set.
  bash "$SWEEP" merge-open --linear-json "$lin" --local-root "$root" > "$d/open.jsonl" || return 2
  total=$(wc -l < "$d/open.jsonl" | tr -d ' ')
  n_open=$total
  # Steps 4 and 5 — epic children and the journal skip.
  : > "$d/judge.jsonl"
  i=1
  while [ "$i" -le "$total" ]; do
    row=$(sed -n "${i}p" "$d/open.jsonl")
    slug=$(printf '%s' "$row" | jq -r '.slug // ""')
    lid=$(printf '%s' "$row" | jq -r '.linear_id // ""')
    epic=$(printf '%s' "$row" | jq -r '.epic_child | tostring')
    key="$slug"; [ -n "$key" ] || key="$lid"
    if [ "$epic" = "true" ]; then
      n_skip=$((n_skip + 1))
      printf 'SKIP-EPIC %s\n' "$key" >> "$ev"
      i=$((i + 1)); continue
    fi
    jline="$swd/$key.jsonl"
    if [ "$refresh" = "1" ]; then
      if bash "$SWEEP" journal-skip --file "$jline" --tag-date "$tag_date" --refresh >/dev/null 2>&1; then
        n_skip=$((n_skip + 1)); printf 'SKIP-JOURNAL %s\n' "$key" >> "$ev"
        i=$((i + 1)); continue
      fi
    elif bash "$SWEEP" journal-skip --file "$jline" --tag-date "$tag_date" >/dev/null 2>&1; then
      n_skip=$((n_skip + 1)); printf 'SKIP-JOURNAL %s\n' "$key" >> "$ev"
      i=$((i + 1)); continue
    fi
    printf '%s\n' "$row" >> "$d/judge.jsonl"
    i=$((i + 1))
  done
  # Step 6 — Purge pre-pass over the FULL judge set (M8, M18: --limit never
  # shrinks it), then Step 7 batch and Step 8 apply.
  : > "$d/kept.jsonl"
  while IFS= read -r row; do
    slug=$(printf '%s' "$row" | jq -r '.slug // ""')
    lid=$(printf '%s' "$row" | jq -r '.linear_id // ""')
    title=$(printf '%s' "$row" | jq -r '.title // ""')
    added=$(printf '%s' "$row" | jq -r '.added // ""')
    key="$slug"; [ -n "$key" ] || key="$lid"
    jline="$swd/$key.jsonl"
    printf 'PURGE %s\n' "$key" >> "$ev"
    disp=""; evid=""; rc=1
    aff=$(affects_of "$root/.claude/backlog/$slug.md")
    if [ -n "$aff" ]; then
      local -a paths=()
      while IFS= read -r p; do [ -n "$p" ] && paths+=("$p"); done <<< "$aff"
      evid=$(bash "$SWEEP" evidence-paths-absent --root "$root" -- "${paths[@]}" 2>&1); rc=$?
    elif printf '%s' "$title" | grep -qF '[STALE]'; then
      evid=$(bash "$SWEEP" evidence-shipped-after --root "$root" --added "${added:-2020-01-01}" 2>&1); rc=$?
    fi
    if [ -n "$aff" ] || printf '%s' "$title" | grep -qF '[STALE]'; then
      if [ "$rc" -eq 0 ]; then disp="CLOSE"; else disp="ASK"; evid="bar not met: $evid"; fi
    fi
    if [ "$disp" = "CLOSE" ] && [ -z "$slug" ]; then
      disp="ASK"; evid="no local write-through (M11)"
    fi
    printf '%s | %s | %s\n' "$key" "${disp:-KEEP-OPEN}" "$(printf '%s\n' "$evid" | head -n1)" >> "$batch"
    case "$disp" in
      CLOSE)
        args="close.sh $slug --ticket ${lid:-LOCAL}"
        journal_rec "$jline" CLOSE "$evid" "$args" "$tag"
        pre=$(item_status "$root" "$slug")
        printf 'INTENT-STATUS %s|%s\n' "$slug" "$pre" >> "$ev"
        printf 'APPLY-CLOSE %s\n' "$slug" >> "$ev"
        bash "$CLOSE" "$slug" --root "$root" --ticket "${lid:-LOCAL}" >/dev/null 2>&1 \
          || printf 'APPLY-FAIL close %s\n' "$slug" >> "$ev"
        journal_rec "$jline" CLOSE "$evid" "$args" "$tag" closed
        n_close=$((n_close + 1))
        ;;
      ASK)
        if [ "$ap" = "1" ]; then
          evid="missing-evidence: $evid"
          args="defer.sh $slug"; [ -n "$slug" ] || args="journal-only $lid"
          journal_rec "$jline" DEFER "$evid" "$args" "$tag"
          if [ -n "$slug" ]; then
            printf 'APPLY-DEFER %s\n' "$slug" >> "$ev"
            bash "$DEFER" "$slug" --root "$root" --note "$(one_line "$evid")" >/dev/null 2>&1 \
              || printf 'APPLY-FAIL defer %s\n' "$slug" >> "$ev"
          else
            printf 'APPLY-DEFER-JOURNAL %s\n' "$lid" >> "$ev"
          fi
          journal_rec "$jline" DEFER "$evid" "$args" "$tag" deferred
          n_defer=$((n_defer + 1))
        else
          journal_rec "$jline" ASK "$evid" "ask close|run|defer" "$tag"
          n_ask=$((n_ask + 1))
        fi
        ;;
      *)
        sz=$(decide_size "$root" "$slug")
        printf '%s\n' "$row" | jq -c --arg size "$sz" '. + {size:$size}' >> "$d/kept.jsonl"
        ;;
    esac
  done < "$d/judge.jsonl"
  # Steps 9a-9e — the serial walk over what the purge left.
  bash "$SWEEP" walk-sort < "$d/kept.jsonl" > "$d/walk.jsonl" || return 2
  local wtotal widx=1
  wtotal=$(wc -l < "$d/walk.jsonl" | tr -d ' ')
  while [ "$widx" -le "$wtotal" ]; do
    row=$(sed -n "${widx}p" "$d/walk.jsonl")
    slug=$(printf '%s' "$row" | jq -r '.slug // ""')
    lid=$(printf '%s' "$row" | jq -r '.linear_id // ""')
    sz=$(printf '%s' "$row" | jq -r '.size // "M"')
    key="$slug"; [ -n "$key" ] || key="$lid"
    jline="$swd/$key.jsonl"
    if [ "$limit" -gt 0 ] && [ "$n_orch" -ge "$limit" ]; then
      printf 'WALK-BOUND %s\n' "$key" >> "$ev"
      n_skip=$((n_skip + 1))
      widx=$((widx + 1)); continue
    fi
    # Step 9b — the attended sweep passes no --ship, so the line carries no
    # autopilot argv (M17); the autopilot sweep passes the ship intent.
    if [ "$ap" = "1" ]; then
      args=$(bash "$SWEEP" compile-orchestrate-args --size "$sz" --ship master)
    else
      args=$(bash "$SWEEP" compile-orchestrate-args --size "$sz")
    fi
    printf 'ARGS %s|%s\n' "$key" "$args" >> "$ev"
    journal_rec "$jline" ORCHESTRATE "walk: size $sz" "$args" "$tag"
    printf 'ORCH %s\n' "$key" >> "$ev"
    # Step 9e — a child run reports its own named halt condition; the journal
    # outcome enum is closed, so walk-outcome maps it and the name goes in evidence.
    halt=""
    [ "$key" = "work-m" ] && halt="complexity-overflow"
    if [ -n "$halt" ]; then
      oc=$(bash "$SWEEP" walk-outcome --halt "$halt")
      evid="walk: size $sz; halt: $halt"
      n_esc=$((n_esc + 1))
      printf 'HALT %s %s\n' "$key" "$halt" >> "$ev"
    else
      oc=$(bash "$SWEEP" walk-outcome --landed)
      evid="walk: size $sz"
    fi
    journal_rec "$jline" ORCHESTRATE "$evid" "$args" "$tag" "$oc"
    n_orch=$((n_orch + 1))
    widx=$((widx + 1))
  done
  # Step 10 — summary.
  jq -cn --argjson open "$n_open" --argjson CLOSE "$n_close" --argjson ASK "$n_ask" \
    --argjson ORCHESTRATE "$n_orch" --argjson DEFER "$n_defer" --argjson SKIP "$n_skip" \
    --argjson escalations "$n_esc" \
    '{open:$open, CLOSE:$CLOSE, ASK:$ASK, ORCHESTRATE:$ORCHESTRATE, DEFER:$DEFER, SKIP:$SKIP, escalations:$escalations}'
}

# ===========================================================================
# AC1 — open set uses /backlog list semantics; every open item exactly once
# ===========================================================================
MO="$WORK/merged.jsonl"
bash "$SWEEP" merge-open --linear-json "$WORK/linear.json" --local-root "$LR" > "$MO"
check "AC1" "merge-open emits every open item once (3 linear + 5 local, one linked pair)" "7" \
  "$(wc -l < "$MO" | tr -d ' ')"
check "AC1" "a linked pair merges into one row (source both, local slug wins)" "linked-item" \
  "$(jq -r 'select(.linear_id == "CDT-99") | .slug' "$MO")"
check "AC1" "a linked id appears exactly once" "1" \
  "$(jq -r 'select(.linear_id == "CDT-99") | .slug' "$MO" | grep -c . || true)"
check "AC1" "a linked pair carries source=both" "both" \
  "$(jq -r 'select(.linear_id == "CDT-99") | .source' "$MO")"
check "AC1" "a local-only PENDING row is in the open set" "local" \
  "$(jq -r 'select(.slug == "local-only") | .source' "$MO")"
check "AC1" "a local-only PENDING row keeps its added date" "2026-06-02" \
  "$(jq -r 'select(.slug == "local-only") | .added' "$MO")"
check "AC1" "a terminal local row is not in the open set" "0" \
  "$(jq -r 'select(.slug == "done-thing") | .slug' "$MO" | grep -c . || true)"
check "AC1" "DEFERRED is an open status, so it is in the open set" "DEFERRED" \
  "$(jq -r 'select(.slug == "deferred-item") | .status' "$MO")"
check "AC1" "a Linear-only row carries no slug (M11 ASK floor)" "" \
  "$(jq -r 'select(.linear_id == "CDT-140") | .slug' "$MO")"
check "AC1" "a Linear row carries its priority for the walk sort" "1" \
  "$(jq -r 'select(.linear_id == "CDT-140") | .priority' "$MO")"
check "AC1" "open keys are unique by linear_id then slug" "7" \
  "$(jq -r 'if .linear_id == "" then "S:" + .slug else "L:" + .linear_id end' "$MO" \
    | sort -u | wc -l | tr -d ' ')"
check "AC1" "the row schema is complete (11 keys)" "11" \
  "$(jq -r 'keys | length' "$MO" | head -n1)"
check "AC1" "size is empty in the open set (the protocol fills it)" "0" \
  "$(jq -r 'select(.size != "") | .slug' "$MO" | grep -c . || true)"
rc_is "AC1" "merge-open rejects --project (the Linear query is the caller's job, M5)" 64 \
  bash "$SWEEP" merge-open --project x --linear-json "$WORK/linear.json" --local-root "$LR"
check "AC1" "merge-open has no Linear MCP call (the session owns MCP)" "0" \
  "$(grep -cE 'list_issues|mcp__' "$SWEEP" || true)"
rc_is "AC1" "merge-open fails closed on malformed linear-json" 1 \
  bash "$SWEEP" merge-open --linear-json "$BADLIN" --local-root "$LR"
rc_is "AC1" "merge-open fails closed on an unreadable linear-json" 1 \
  bash "$SWEEP" merge-open --linear-json "$WORK/no-such.json" --local-root "$LR"
check "AC1" "the protocol calls list_issues with parentId and priority" "1" \
  "$(grep -cF 'include `parentId` and `priority`' "$SWEEP_MD")"
md_rule "AC1" "the protocol applies --project on the Linear query only" 1 'Apply `--project` on this query only'

# ===========================================================================
# AC9 — --ship compile matrix (data plane first: the walk needs it)
# ===========================================================================
check "AC9" "compile-ship pr prints no autopilot argv" "" "$(bash "$SWEEP" compile-ship --ship=pr)"
check "AC9" "compile-ship master" "--autopilot=master" "$(bash "$SWEEP" compile-ship --ship=master)"
check "AC9" "compile-ship patch" "--autopilot=patch" "$(bash "$SWEEP" compile-ship --ship=patch)"
check "AC9" "compile-ship minor" "--autopilot=minor" "$(bash "$SWEEP" compile-ship --ship=minor)"
check "AC9" "compile-ship major" "--autopilot=major" "$(bash "$SWEEP" compile-ship --ship=major)"
rc_is "AC9" "compile-ship rejects a bad value" 64 bash "$SWEEP" compile-ship --ship=squash
rc_is "AC9" "compile-ship rejects an empty value" 64 bash "$SWEEP" compile-ship --ship=
rc_is "AC9" "compile-ship without --ship is a usage error" 64 bash "$SWEEP" compile-ship
check "AC9" "compile-ship prints no literal --ship for any value" "0" \
  "$(for v in pr master patch minor major; do bash "$SWEEP" compile-ship --ship="$v"; done | grep -c -- '--ship' || true)"
check "AC9" "the sweep flag never reaches the compiled argv" "0" \
  "$(bash "$SWEEP" compile-orchestrate-args --size S --ship master | grep -c -- '--ship' || true)"
check "AC9" "the compiled argv for L/patch is the full line" \
  "--tier=full --council-tier=light --autopilot=patch" \
  "$(bash "$SWEEP" compile-orchestrate-args --size L --council-tier light --ship patch)"
rc_is "AC9" "compile-orchestrate-args rejects a bad size" 64 bash "$SWEEP" compile-orchestrate-args --size XL --ship pr
rc_is "AC9" "compile-orchestrate-args rejects a bad ship" 64 bash "$SWEEP" compile-orchestrate-args --size S --ship squash
rc_is "AC9" "compile-orchestrate-args rejects a bad council tier" 64 \
  bash "$SWEEP" compile-orchestrate-args --size S --ship pr --council-tier huge
md_rule "AC9" "the protocol keeps --ship out of /orchestrate" 1 "MUST NOT pass"
md_rule "AC9" "the protocol states the compiled line has no --ship" 1 "never appears in it and MUST NOT reach"
md_rule "AC9" "the protocol carries the sweep --autopilot ship default" 1 'an unset `--ship` defaults to'

# R2 GAPS-1 — the attended walk compiles with no --ship at all (AC9, M17).
rc_is "AC9" "compile-orchestrate-args with --size only is not a usage error" 0 \
  bash "$SWEEP" compile-orchestrate-args --size S
check "AC9" "no --ship emits the tier with no autopilot argv" "--tier=light" \
  "$(bash "$SWEEP" compile-orchestrate-args --size S)"
check "AC9" "an empty --ship emits the tier with no autopilot argv" "--tier=light" \
  "$(bash "$SWEEP" compile-orchestrate-args --size S --ship "")"
check "AC9" "no --ship for M emits the council tier alone" "--council-tier=light" \
  "$(bash "$SWEEP" compile-orchestrate-args --size M --council-tier light)"
check "AC9" "the attended line carries no autopilot argv" "0" \
  "$(bash "$SWEEP" compile-orchestrate-args --size L | grep -c -- '--autopilot' || true)"
check "AC9" "the attended line for M carries no tier" "" \
  "$(bash "$SWEEP" compile-orchestrate-args --size M)"
rc_is "AC9" "compile-orchestrate-args rejects a bad --ship with no tier loss" 64 \
  bash "$SWEEP" compile-orchestrate-args --size S --ship squash
md_rule "AC9" "the protocol passes --ship only when Step 1 reported one" 1 \
  'pass `--ship` only when Step 1 reported one'

# ===========================================================================
# AC7 — Triage size: S/M/L mapping, cheap signals only, no spawns
# ===========================================================================
check "AC7" "size S maps to --tier=light" "--tier=light --autopilot=master" \
  "$(bash "$SWEEP" compile-orchestrate-args --size S --ship master)"
check "AC7" "size M omits --tier (orchestrate Step 2 stays the authority)" "" \
  "$(bash "$SWEEP" compile-orchestrate-args --size M --ship pr)"
check "AC7" "size L maps to --tier=full" "--tier=full" \
  "$(bash "$SWEEP" compile-orchestrate-args --size L --ship pr)"
check "AC7" "--council-tier is omitted when the user did not set it" "0" \
  "$(bash "$SWEEP" compile-orchestrate-args --size S --ship pr | grep -c -- '--council-tier' || true)"
check "AC7" "--council-tier is forwarded only when the user set it" "1" \
  "$(bash "$SWEEP" compile-orchestrate-args --size S --ship pr --council-tier skip | grep -c -- '--council-tier=skip' || true)"
check "AC7" "sweep.sh has no spawn verb (Agent/Task/TaskCreate)" "0" \
  "$(grep -cE 'Agent\(|Task\(|TaskCreate|SendMessage' "$SWEEP" || true)"
count_not "AC7" "sweep.sh shells out to no agent CLI" "$SWEEP" 'claude( |-)|\bagent\b'
md_rule "AC7" "the protocol forbids spawning an agent to size" 1 "MUST NOT spawn an agent to"
md_rule "AC7" "the protocol reads the Effort value first" 1 "Use the item"
md_rule "AC7" "the protocol counts the Affects paths" 1 'Otherwise count the `## Affects` paths'
md_rule "AC7" "the protocol escalates on architecture words in title or body" 1 "Escalate one step when the title or body names"
md_rule "AC7" "the protocol defaults to M" 1 'Default to `M`'
check "AC7" "the size vocabulary is S/M/L in the CLI contract" "1" \
  "$(grep -cE 'invalid --size .*expected S\|M\|L' "$SWEEP")"
# The simulator's size rule (sweep.md Step 9 rules 1-2) over the real fixtures.
check "AC7" "Effort S wins over the path count" "S" "$(decide_size "$REPOA" work-s)"
check "AC7" "Effort M wins over the path count" "M" "$(decide_size "$REPOA" work-m)"
check "AC7" "no Effort and 0 paths sizes S" "S" "$(decide_size "$REPOC" linked-item)"
check "AC7" "no Effort and 2 paths sizes M" "M" "$(decide_size "$REPOA" stale-absent)"
check "AC7" "no Effort and 3 paths sizes L" "L" "$(decide_size "$REPOA" metachar-item)"

# ===========================================================================
# AC8 — walk order: size ascending, Linear priority, local-only last by added
# ===========================================================================
WS="$WORK/walkin.jsonl"
cat > "$WS" <<'EOF'
{"slug":"l-p1","linear_id":"CDT-1","size":"L","source":"linear","priority":1,"added":"2026-08-01"}
{"slug":"s-p4","linear_id":"CDT-4","size":"S","source":"linear","priority":4,"added":"2026-08-01"}
{"slug":"s-p1","linear_id":"CDT-5","size":"S","source":"linear","priority":1,"added":"2026-08-01"}
{"slug":"s-p0","linear_id":"CDT-6","size":"S","source":"linear","priority":0,"added":"2026-08-01"}
{"slug":"m-local-b","linear_id":"","size":"M","source":"local","priority":0,"added":"2026-06-02"}
{"slug":"m-local-a","linear_id":"","size":"M","source":"local","priority":0,"added":"2026-05-01"}
{"slug":"m-both","linear_id":"CDT-7","size":"M","source":"both","priority":2,"added":"2026-07-01"}
{"slug":"s-p2","linear_id":"CDT-8","size":"S","source":"linear","priority":2,"added":"2026-08-01"}
EOF
WSO="$WORK/walkout.jsonl"
bash "$SWEEP" walk-sort < "$WS" > "$WSO"
check "AC8" "size, then priority, then local-only by added" \
  "s-p1 s-p2 s-p4 s-p0 m-both m-local-a m-local-b l-p1" \
  "$(jq -r '.slug' "$WSO" | tr '\n' ' ' | sed 's/ $//')"
check "AC8" "walk-sort drops nothing" "$(wc -l < "$WS" | tr -d ' ')" "$(wc -l < "$WSO" | tr -d ' ')"
check "AC8" "walk-sort emits JSONL (one object per line)" "8" \
  "$(jq -r '.slug' "$WSO" | grep -c . || true)"
check "AC8" "an absent size sorts as M (8 rows: S bucket first)" "s-p1 s-p2 s-p4 s-p0" \
  "$(head -n4 "$WSO" | jq -r '.slug' | tr '\n' ' ' | sed 's/ $//')"
check "AC8" "an unknown size sorts as M (priority 3 before 4)" "a c b" \
  "$(printf '%s\n' '{"slug":"a","linear_id":"CDT-1","size":"","source":"linear","priority":3,"added":""}' \
      '{"slug":"b","linear_id":"CDT-2","size":"L","source":"linear","priority":1,"added":""}' \
      '{"slug":"c","linear_id":"CDT-3","size":"XL","source":"linear","priority":4,"added":""}' \
    | bash "$SWEEP" walk-sort | jq -r '.slug' | tr '\n' ' ' | sed 's/ $//')"
md_rule "AC8" "the protocol states the client-side order" 1 "then Linear priority 1, 2, 3, 4, 0"
md_rule "AC8" "the walk is strict serial (SPEC-016)" 1 'Run the walk **strict serial**'

# ===========================================================================
# AC10 — epic children SKIP, no triage, no journal, counted in the summary
# ===========================================================================
bash "$SWEEP" is-epic-child --frontmatter "$LR/.claude/backlog/epic-kid.md" >/dev/null
check "AC10" "epic_parent frontmatter is a child (exit 0 = skip)" "0" "$?"
bash "$SWEEP" is-epic-child --frontmatter "$LR/.claude/backlog/local-only.md" >/dev/null
check "AC10" "no epic_parent is not a child (exit 1)" "1" "$?"
bash "$SWEEP" is-epic-child --parent-id CDT-46 >/dev/null
check "AC10" "a non-empty parentId is a child (exit 0 = skip)" "0" "$?"
bash "$SWEEP" is-epic-child --parent-id "" >/dev/null
check "AC10" "an empty parentId is not a child (exit 1)" "1" "$?"
bash "$SWEEP" is-epic-child --frontmatter "$WORK/no-such-file.md" >/dev/null 2>&1
check "AC10" "an unreadable frontmatter file is a machinery error (rc 1), never a skip" "1" "$?"
rc_is "AC10" "is-epic-child with both forms is a usage error" 64 bash "$SWEEP" is-epic-child \
  --frontmatter "$LR/.claude/backlog/epic-kid.md" --parent-id CDT-46
rc_is "AC10" "is-epic-child with neither form is a usage error" 64 bash "$SWEEP" is-epic-child
check "AC10" "Linear parentId flags an epic child in the open set" "true" \
  "$(jq -r 'select(.linear_id == "CDT-141") | .epic_child' "$MO")"
check "AC10" "local epic_parent flags an epic child in the open set" "true" \
  "$(jq -r 'select(.slug == "epic-kid") | .epic_child' "$MO")"
check "AC10" "a non-child row is not flagged" "false" \
  "$(jq -r 'select(.slug == "local-only") | .epic_child' "$MO")"
md_rule "AC10" "the protocol drops epic children before triage" 1 'Drop every row whose `epic_child` is true'
md_rule "AC10" "the protocol writes no journal for an epic child" 1 "Run no triage and write no journal record"

# ===========================================================================
# AC12 — tag baseline via is_release_tag; never `git describe`
# ===========================================================================
check "AC12" "last-release-tag skips nightly-9 and v1.2.4-rc1 that git describe picks" \
  "v1.2.3" "$(bash "$SWEEP" last-release-tag --root "$TAGR")"
check "AC12" "git describe picks a tag is_release_tag rejects (control)" "0" \
  "$(git -C "$TAGR" describe --tags 2>/dev/null | grep -cE '^v?[0-9]+\.[0-9]+\.[0-9]+$' || true)"
check "AC12" "an annotated release tag is found" "v1.9.0" \
  "$(bash "$SWEEP" last-release-tag --root "$REPOA")"
check "AC12" "last-release-tag with no release tag prints empty" "" \
  "$(bash "$SWEEP" last-release-tag --root "$NOTAG")"
check "AC12" "last-release-tag on a non-repo prints empty (empty baseline, M21)" "" \
  "$(bash "$SWEEP" last-release-tag --root "$NOTGIT")"
rc_is "AC12" "last-release-tag rejects a missing root" 1 bash "$SWEEP" last-release-tag --root "$WORK/no-such-dir"
check "AC12" "sweep.sh never calls git describe (M21)" "0" \
  "$(grep -cE '^[^#]*git describe' "$SWEEP" || true)"
check "AC12" "sweep.sh reads is_release_tag from the release helper" "1" \
  "$(grep -cF 'is_release_tag' "$SWEEP" | awk '{print ($1>0)?1:0}')"
check "AC12" "the release-tag regex is not inlined in sweep.sh" "0" \
  "$(grep -cF '[0-9]+\.[0-9]+\.[0-9]+' "$SWEEP" || true)"
check "AC12" "the helper path is resolved script-to-script" "1" \
  "$(grep -cF 'SHIP_HIST_SH="$SCRIPT_DIR/../release/check-ship-history.sh"' "$SWEEP")"
md_rule "AC12" "the protocol snapshots the baseline once" 1 "Tags created"
md_rule "AC12" "the protocol pins the baseline for the whole walk" 1 "MUST NOT move it"
# An empty baseline (no release tag, or an annotated tag with no committerdate)
# fails open to re-judging — never a false skip.
MIDJ="$WORK/midwalk.jsonl"
bash "$SWEEP" journal-append --file "$MIDJ" --json \
  '{"ts":"2026-10-10T09:00:00Z","disposition":"CLOSE","evidence":"two cites","args":"close.sh x","tag_baseline":"v1.9.0","outcome":"closed"}' >/dev/null
ANN="$WORK/annotated"
mkdir -p "$ANN"
git -C "$ANN" init -q 2>/dev/null
git -C "$ANN" commit -q --allow-empty -m one
git -C "$ANN" tag -a v2.0.0 -m rel
check "AC12" "last-release-tag finds the annotated release tag" "v2.0.0" \
  "$(bash "$SWEEP" last-release-tag --root "$ANN")"
check "AC12" "an annotated tag carries no committerdate (the probe tag-date replaces)" "" \
  "$(git -C "$ANN" for-each-ref --format='%(committerdate:iso8601-strict)' refs/tags/v2.0.0)"
bash "$SWEEP" journal-skip --file "$MIDJ" --tag-date "" >/dev/null
check "AC12" "an empty baseline re-judges (fail open, never a false skip)" "1" "$?"
check "AC12" "tag-date resolves an annotated tag the committerdate probe cannot" "present" \
  "$([ -n "$(bash "$SWEEP" tag-date --root "$ANN" --tag v2.0.0)" ] && echo present || echo absent)"

# R2 blocker 3 — sweep.sh tag-date is the verb the protocol calls in Step 2.
TD="$WORK/tagdate"
mkdir -p "$TD"
git -C "$TD" init -q 2>/dev/null
GIT_AUTHOR_DATE='2026-03-01T09:00:00 +0000' GIT_COMMITTER_DATE='2026-03-01T09:00:00 +0000' \
  git -C "$TD" commit -q --allow-empty -m light
git -C "$TD" tag v1.1.0
GIT_COMMITTER_DATE='2026-04-02T10:00:00 +0000' git -C "$TD" tag -a v1.2.0 -m ann v1.1.0
GIT_AUTHOR_DATE='2026-05-05T09:00:00 +0000' GIT_COMMITTER_DATE='2026-05-05T09:00:00 +0000' \
  git -C "$TD" commit -q --allow-empty -m later
check "AC12" "tag-date step 1: the annotated tagger date wins" "2026-04-02" \
  "$(bash "$SWEEP" tag-date --root "$TD" --tag v1.2.0 | cut -c1-10)"
check "AC12" "tag-date step 2: a lightweight tag uses the tagged commit date" "2026-03-01" \
  "$(bash "$SWEEP" tag-date --root "$TD" --tag v1.1.0 | cut -c1-10)"
check "AC12" "tag-date stdout is ISO-8601" "iso" \
  "$(bash "$SWEEP" tag-date --root "$TD" --tag v1.2.0 \
    | grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(Z|[+-][0-9]{4})$' \
    && echo iso || echo not-iso)"
check "AC12" "the tag-date baseline drives journal-skip (a post-baseline record skips)" "0" \
  "$(bash "$SWEEP" journal-skip --file "$MIDJ" \
      --tag-date "$(bash "$SWEEP" tag-date --root "$TD" --tag v1.1.0)" >/dev/null; echo $?)"
rc_is "AC12" "tag-date without --tag is a usage error" 64 bash "$SWEEP" tag-date --root "$TD"
rc_is "AC12" "tag-date without --root is a usage error" 64 bash "$SWEEP" tag-date --tag v1.2.0
rc_is "AC12" "tag-date on a tag that does not exist exits 1" 1 \
  bash "$SWEEP" tag-date --root "$TD" --tag v9.9.9
rc_is "AC12" "tag-date on a non-repo exits 1 (fail closed, never an empty baseline)" 1 \
  bash "$SWEEP" tag-date --root "$NOTGIT" --tag v1.0.0
rc_is "AC12" "tag-date rejects a tag that starts with a dash" 64 \
  bash "$SWEEP" tag-date --root "$TD" --tag=-x
check "AC12" "tag-date takes the tag as argv, never as a shell word" "0" \
  "$(grep -cE '^[^#]*eval .*tag' "$SWEEP" || true)"
md_rule "AC12" "the protocol resolves the baseline through the tag-date verb" 1 \
  'bash "$SWEEP" tag-date --root "$MROOT" --tag "$TAG"'
count_not "AC12" "the protocol carries no inline tag-date git probe" "$SWEEP_MD" 'for-each-ref|taggerdate'

# ===========================================================================
# AC11 — append-only journal, keyed, intent then outcome, never committed
# ===========================================================================
JR="$WORK/journal/nested/item.jsonl"
INTENT='{"ts":"2026-10-22T10:00:00Z","disposition":"ORCHESTRATE","evidence":"two cites","args":"/orchestrate --tier=light","tag_baseline":"v1.2.3"}'
DONE='{"ts":"2026-10-22T10:00:00Z","disposition":"ORCHESTRATE","evidence":"two cites","args":"/orchestrate --tier=light","tag_baseline":"v1.2.3","outcome":"shipped"}'
bash "$SWEEP" journal-append --file "$JR" --json "$INTENT" >/dev/null
INTENT_LINE=$(head -n1 "$JR")
bash "$SWEEP" journal-append --file "$JR" --json "$DONE" >/dev/null
check "AC11" "journal-append creates the parent dir and appends two records" "2" "$(wc -l < "$JR" | tr -d ' ')"
check "AC11" "the intent record has no outcome key" "0" "$(head -n1 "$JR" | grep -c outcome)"
check "AC11" "the completed record carries outcome" "shipped" "$(tail -n1 "$JR" | jq -r '.outcome')"
check "AC11" "append is append-only (the intent line is byte-identical)" "$INTENT_LINE" \
  "$(head -n1 "$JR")"
check "AC11" "journal-append echoes the record it wrote" "$(printf '%s' "$INTENT" | jq -c .)" \
  "$(bash "$SWEEP" journal-append --file "$JR" --json "$INTENT" | tail -n1)"
check "AC11" "every line is one JSON object (JSONL)" "$(wc -l < "$JR" | tr -d ' ')" \
  "$(jq -c 'select(type == "object")' "$JR" 2>/dev/null | wc -l | tr -d ' ')"
check "AC11" "the intent record has the five required keys" "5" "$(head -n1 "$JR" | jq -r 'keys | length')"
check "AC11" "the completed record adds outcome (six keys)" "6" "$(sed -n '2p' "$JR" | jq -r 'keys | length')"
rc_is "AC11" "journal-append rejects a bad disposition" 64 bash "$SWEEP" journal-append --file "$JR" \
  --json '{"ts":"2026-10-22T10:00:00Z","disposition":"NOPE","evidence":"","args":"","tag_baseline":""}'
rc_is "AC11" "journal-append rejects a missing key" 64 bash "$SWEEP" journal-append --file "$JR" \
  --json '{"ts":"2026-10-22T10:00:00Z","disposition":"CLOSE"}'
rc_is "AC11" "journal-append rejects a bad outcome" 64 bash "$SWEEP" journal-append --file "$JR" \
  --json '{"ts":"2026-10-22T10:00:00Z","disposition":"CLOSE","evidence":"","args":"","tag_baseline":"","outcome":"pwned"}'
rc_is "AC11" "journal-append rejects malformed JSON" 64 bash "$SWEEP" journal-append --file "$JR" --json '{nope'
rc_is "AC11" "journal-append rejects a non-ISO ts" 64 bash "$SWEEP" journal-append --file "$JR" \
  --json '{"ts":"yesterday","disposition":"CLOSE","evidence":"","args":"","tag_baseline":""}'
BEFORE=$(wc -l < "$JR")
bash "$SWEEP" journal-append --file "$JR" --json '{"ts":"x","disposition":"CLOSE","evidence":"","args":"","tag_baseline":""}' >/dev/null 2>&1
check "AC11" "a rejected record writes nothing" "$BEFORE" "$(wc -l < "$JR")"
# The five terminal outcomes AC11 names.
OCJ="$WORK/outcomes.jsonl"
for oc in closed shipped pr-stopped deferred asked-answered; do
  bash "$SWEEP" journal-append --file "$OCJ" --json \
    "{\"ts\":\"2026-10-22T11:00:00Z\",\"disposition\":\"CLOSE\",\"evidence\":\"e\",\"args\":\"a\",\"tag_baseline\":\"v1.2.3\",\"outcome\":\"$oc\"}" >/dev/null
done
check "AC11" "all five terminal outcomes are accepted" "5" "$(wc -l < "$OCJ" | tr -d ' ')"
check "AC11" "the outcome set matches the spec" \
  "asked-answered closed deferred pr-stopped shipped" \
  "$(jq -r '.outcome' "$OCJ" | sort | tr '\n' ' ' | sed 's/ $//')"
# Linear-only items key by issue id (M20).
KEYJ="$WORK/sweeps"
bash "$SWEEP" journal-append --file "$KEYJ/CDT-140.jsonl" --json "$INTENT" >/dev/null
check "AC11" "a Linear-only journal keys by issue id" "1" "$([ -f "$KEYJ/CDT-140.jsonl" ] && echo 1 || echo 0)"
md_rule "AC11" "the journal lives under the shared sweeps dir" 1 "\$MROOT/.claude/sweeps/"
md_rule "AC11" "the intent record is written before the side effect" 1 "Write the **intent** record before the side effect"
md_rule "AC11" "the journal is never staged or committed" 1 "never staged or committed"

# Journal never staged: a repo that carries the plugin .gitignore.
IGNR="$WORK/ignrepo"; mkdir -p "$IGNR/.claude/sweeps"
cp "$GITIGNORE" "$IGNR/.gitignore"
git -C "$IGNR" init -q 2>/dev/null
git -C "$IGNR" add .gitignore
git -C "$IGNR" commit -q -m seed
bash "$SWEEP" journal-append --file "$IGNR/.claude/sweeps/x.jsonl" --json "$INTENT" >/dev/null
git -C "$IGNR" add -A
check "AC11" "git add -A stages no journal record" "" "$(git -C "$IGNR" diff --cached --name-only)"
check "AC11" ".claude/sweeps/ is gitignored (line 9 of .gitignore)" "1" \
  "$(grep -c '^\.claude/sweeps/$' "$GITIGNORE")"
check "AC11" "git check-ignore resolves the journal path" "1" \
  "$(git -C "$IGNR" -c core.excludesfile=/dev/null check-ignore -q --no-index -- .claude/sweeps/x.jsonl && echo 1 || echo 0)"

# ===========================================================================
# AC13 — journal skip, re-judge, --refresh, --skip-decided
# ===========================================================================
SKIPJ="$WORK/skip.jsonl"
bash "$SWEEP" journal-append --file "$SKIPJ" --json \
  '{"ts":"2026-10-22T10:00:00Z","disposition":"CLOSE","evidence":"two cites","args":"close.sh x","tag_baseline":"v1.2.3"}' >/dev/null
bash "$SWEEP" journal-append --file "$SKIPJ" --json \
  '{"ts":"2026-10-22T10:00:00Z","disposition":"CLOSE","evidence":"two cites","args":"close.sh x","tag_baseline":"v1.2.3","outcome":"closed"}' >/dev/null
SKIP_OUT=$(bash "$SWEEP" journal-skip --file "$SKIPJ" --tag-date "2026-10-20T00:00:00Z"); SKIP_RC=$?
check "AC13" "a terminal record at or after the baseline skips" "0" "$SKIP_RC"
check "AC13" "the skip prints why (stem, outcome, ts, baseline)" \
  "skip: journal skip outcome=closed ts=2026-10-22T10:00:00Z baseline=2026-10-20T00:00:00Z" "$SKIP_OUT"
bash "$SWEEP" journal-skip --file "$SKIPJ" --tag-date "2026-10-23T00:00:00Z" >/dev/null
check "AC13" "a terminal record before the baseline re-judges" "1" "$?"
bash "$SWEEP" journal-skip --file "$SKIPJ" --tag-date "" >/dev/null
check "AC13" "an empty tag baseline never skips on the date compare" "1" "$?"
bash "$SWEEP" journal-skip --file "$SKIPJ" --tag-date "2026-10-20T00:00:00Z" --refresh >/dev/null
check "AC13" "--refresh forces a re-judge over a terminal record" "1" "$?"
bash "$SWEEP" journal-skip --file "$SKIPJ" --tag-date "2026-10-23T00:00:00Z" --skip-decided >/dev/null
check "AC13" "--skip-decided skips a terminal outcome the date rule re-judges" "0" "$?"
LINES_BEFORE=$(wc -l < "$SKIPJ" | tr -d ' ')
SHA_BEFORE=$(cksum < "$SKIPJ")
rc_is "AC13" "--refresh with --skip-decided is a usage error" 64 bash "$SWEEP" journal-skip \
  --file "$SKIPJ" --tag-date "2026-10-20T00:00:00Z" --refresh --skip-decided
check "AC13" "the conflicting flags write nothing" "$SHA_BEFORE" "$(cksum < "$SKIPJ")"
check "AC13" "the conflicting flags append no record" "$LINES_BEFORE" "$(wc -l < "$SKIPJ" | tr -d ' ')"
INTENTJ="$WORK/intent.jsonl"
bash "$SWEEP" journal-append --file "$INTENTJ" --json \
  '{"ts":"2026-10-22T10:00:00Z","disposition":"CLOSE","evidence":"","args":"","tag_baseline":"v1.2.3"}' >/dev/null
bash "$SWEEP" journal-skip --file "$INTENTJ" --tag-date "2026-10-20T00:00:00Z" >/dev/null
check "AC13" "an intent record with no outcome re-judges" "1" "$?"
bash "$SWEEP" journal-skip --file "$INTENTJ" --tag-date "2026-10-20T00:00:00Z" --skip-decided >/dev/null
check "AC13" "--skip-decided does not skip an undecided intent" "1" "$?"
bash "$SWEEP" journal-skip --file "$WORK/absent.jsonl" --tag-date "2026-10-20T00:00:00Z" >/dev/null
check "AC13" "no journal file re-judges" "1" "$?"
GARBAGEJ="$WORK/garbage.jsonl"
printf '%s\n' 'not json' > "$GARBAGEJ"
bash "$SWEEP" journal-skip --file "$GARBAGEJ" --tag-date "2026-10-20T00:00:00Z" >/dev/null
check "AC13" "a malformed journal line re-judges (fail open to judging)" "1" "$?"
rc_is "AC13" "journal-skip without --tag-date is a usage error" 64 bash "$SWEEP" journal-skip --file "$SKIPJ"
rc_is "AC13" "journal-skip without --file is a usage error" 64 bash "$SWEEP" journal-skip --tag-date ""
md_rule "AC13" "the protocol prints the reason on a skip" 1 "print the reason line the verb emits"
md_rule "AC13" "an intent record re-judges in the protocol" 1 're-judges that item'

# ===========================================================================
# AC3 — Mechanical evidence bar (a) paths-absent, (b) shipped-after
# ===========================================================================
EVP="$WORK/exec.marker"
# (a) every cited path absent at HEAD -> CLOSE bar met
EVP_OUT=$(bash "$SWEEP" evidence-paths-absent --root "$EVR" -- \
  gone.md 'sub dir/gone.md' 'never/absent.sh' 2>&1); EVP_RC=$?
check "AC3" "(a) all-absent meets the CLOSE bar" "0" "$EVP_RC"
check_ge "AC3" "(a) at least two path cites" 2 "$(printf '%s\n' "$EVP_OUT" | grep -c '^cite ')"
check "AC3" "(a) the missing-count is cited" "missing-count: 3 of 3" \
  "$(printf '%s\n' "$EVP_OUT" | grep -m1 '^missing-count')"
check "AC3" "(a) the HEAD date is cited" "1" \
  "$(printf '%s\n' "$EVP_OUT" | grep -c "HEAD .* $EVH_DATE")"
check "AC3" "(a) the header names the evidence class" "1" \
  "$(printf '%s\n' "$EVP_OUT" | grep -c '^Mechanical evidence (paths-absent)')"
# (a) a present path is not a CLOSE
EVP_OUT=$(bash "$SWEEP" evidence-paths-absent --root "$EVR" -- gone.md here.md 2>&1); EVP_RC=$?
check "AC3" "(a) a present path fails the bar (exit 1, not CLOSE)" "1" "$EVP_RC"
check "AC3" "(a) the present path is named" "1" \
  "$(printf '%s\n' "$EVP_OUT" | grep -c '^cite here.md — present at HEAD')"
rc_is "AC3" "(a) a directory present at HEAD fails the bar" 1 \
  bash "$SWEEP" evidence-paths-absent --root "$EVR" -- src
rc_is "AC3" "(a) a staged (index) path fails the bar" 1 \
  bash "$SWEEP" evidence-paths-absent --root "$EVR" -- staged.md
rc_is "AC3" "(a) a non-repo root fails closed (never a CLOSE)" 1 \
  bash "$SWEEP" evidence-paths-absent --root "$NOTGIT" -- gone.md
rc_is "AC3" "(a) a missing root is a usage error" 64 bash "$SWEEP" evidence-paths-absent -- gone.md
rc_is "AC3" "(a) no paths is a usage error" 64 bash "$SWEEP" evidence-paths-absent --root "$EVR" --
rc_is "AC3" "(a) a path before -- is a usage error" 64 \
  bash "$SWEEP" evidence-paths-absent --root "$EVR" gone.md
rc_is "AC3" "(a) a leading-dash path is a usage error" 64 \
  bash "$SWEEP" evidence-paths-absent --root "$EVR" -- --all
rc_is "AC3" "(a) an absolute path is a usage error" 64 \
  bash "$SWEEP" evidence-paths-absent --root "$EVR" -- /etc/passwd
# (b) shipped after creation -> CLOSE bar met
EVS=$(bash "$SWEEP" evidence-shipped-after --root "$SH1" --added 2026-01-01 2>&1); EVP_RC=$?
check "AC3" "(b) a dated release after Added meets the bar" "0" "$EVP_RC"
check_ge "AC3" "(b) two cites" 2 "$(printf '%s\n' "$EVS" | grep -c '^cite ')"
check "AC3" "(b) the tag date beats the section date" "1" \
  "$(printf '%s\n' "$EVS" | grep -c '^cite 1: CHANGELOG.md:3 v1.9.0 date=2026-06-01')"
check "AC3" "(b) the spec Created date is cited" "1" \
  "$(printf '%s\n' "$EVS" | grep -c '^cite 2: specs/core/SPEC-002-fake.md:3 Created date=2026-04-01')"
check "AC3" "(b) the verdict line names the class" "1" \
  "$(printf '%s\n' "$EVS" | grep -c '^verdict: SHIPPED-AFTER')"
EVS=$(bash "$SWEEP" evidence-shipped-after --root "$SH2" --added 2026-02-01 2>&1); EVP_RC=$?
check "AC3" "(b) a CHANGELOG section date is used when untagged" "0" "$EVP_RC"
check "AC3" "(b) the section date is cited" "1" \
  "$(printf '%s\n' "$EVS" | grep -c '^cite 1: CHANGELOG.md:3 v0.1.0 date=2026-02-02')"
EVS=$(bash "$SWEEP" evidence-shipped-after --root "$SH2" --added 2026-02-02 2>&1); EVP_RC=$?
check "AC3" "(b) an equal date is not strictly after (no CLOSE)" "1" "$EVP_RC"
check "AC3" "(b) the equal-date verdict says so" "1" \
  "$(printf '%s\n' "$EVS" | grep -c 'verdict: NOT SHIPPED-AFTER')"
EVS=$(bash "$SWEEP" evidence-shipped-after --root "$SH2" --added 2026-04-01 2>&1); EVP_RC=$?
check "AC3" "(b) an item newer than every cite fails the bar" "1" "$EVP_RC"
rc_is "AC3" "(b) a future added date fails the bar" 1 \
  bash "$SWEEP" evidence-shipped-after --root "$SH2" --added 2026-12-31
rc_is "AC3" "(b) a bad --added is a usage error" 64 \
  bash "$SWEEP" evidence-shipped-after --root "$SH2" --added 2026-4-1
rc_is "AC3" "(b) a missing --added is a usage error" 64 \
  bash "$SWEEP" evidence-shipped-after --root "$SH2"
rc_is "AC3" "(b) no dated cite fails the bar" 1 \
  bash "$SWEEP" evidence-shipped-after --root "$EMPTY" --added 2020-01-01
# grep symbol-exists is ASK-only: there is no verb for it (MUST NOT).
rc_is "AC3" "evidence-symbol-exists is not a verb (grep symbol-exists is ASK-only)" 64 \
  bash "$SWEEP" evidence-symbol-exists --root "$EVR" -- here.md
check "AC3" "sweep.sh states grep symbol-exists is ASK-only" "1" \
  "$(grep -cE 'grep symbol-exists is ASK-only' "$SWEEP")"
check "AC3" "sweep.sh defines no symbol-exists verb" "0" \
  "$(grep -cE '^[^#]*symbol-exists' "$SWEEP" || true)"
md_rule "AC3" "the protocol keeps a symbol hit at ASK" 1 "no symbol-evidence verb"
md_rule "AC3" "the protocol prints the cites the batch carries" 1 "print the cites you paste into"

# ===========================================================================
# AC4 — a staleness signal below the bar is ASK, never a silent close
# ===========================================================================
ASKJ="$WORK/ask.jsonl"
EVP_OUT=$(bash "$SWEEP" evidence-paths-absent --root "$REPOA" -- src/keep.c 2>&1); EVP_RC=$?
check "AC4" "a present cited path gives a negative verdict" "1" "$EVP_RC"
bash "$SWEEP" journal-append --file "$ASKJ" --json \
  '{"ts":"2026-10-22T12:00:00Z","disposition":"ASK","evidence":"signal: paths present at HEAD; bar not met","args":"ask close|run|defer","tag_baseline":"v1.9.0"}' >/dev/null
check "AC4" "an ASK disposition is journalable" "1" "$(wc -l < "$ASKJ" | tr -d ' ')"
check "AC4" "the ASK record carries no outcome (nothing applied)" "0" "$(grep -c outcome "$ASKJ")"
ST_PRE=$(item_status "$REPOA" stale-present)
check "AC4" "an ASK leaves the item file untouched" "PENDING" "$ST_PRE"
count_not "AC4" "sweep.sh has no item-file writer on any path" \
  "$SWEEP" '^[^#]*(atomic_write|tee |sed -i)'
md_rule "AC4" "a signal below the bar is ASK" 1 "Staleness signal, bar not met"
md_rule "AC4" "the protocol forbids a silent close on inference" 1 "never a silent close"
md_rule "AC4" "autopilot never auto-closes on inference" 1 "Never auto-close on inference"

# ===========================================================================
# Composition — sweep_sim runs the sweep.md steps over the fixture repo
#   A: --autopilot, --limit 1, Linear down (local-only open set)
#   B: same repo again (journal skip path, --skip-decided off)
#   C: --refresh (re-judge everything)
#   D: Linear up, attended, epic child + Linear-only item
#   E: Linear up, --autopilot (ASK -> DEFER conversion)
# ===========================================================================
EV_A="$WORK/ev.A"; BT_A="$WORK/batch.A"
COUNTS_A=$(sweep_sim "$REPOA" "$WORK/empty-linear.json" 1 1 0 "$EV_A" "$BT_A")
EV_B="$WORK/ev.B"; BT_B="$WORK/batch.B"
COUNTS_B=$(sweep_sim "$REPOA" "$WORK/empty-linear.json" 0 1 0 "$EV_B" "$BT_B")
EV_C="$WORK/ev.C"; BT_C="$WORK/batch.C"
COUNTS_C=$(sweep_sim "$REPOA" "$WORK/empty-linear.json" 0 1 1 "$EV_C" "$BT_C")
EV_D="$WORK/ev.D"; BT_D="$WORK/batch.D"
COUNTS_D=$(sweep_sim "$REPOC" "$WORK/linear-up.json" 1 0 0 "$EV_D" "$BT_D")
EV_E="$WORK/ev.E"; BT_E="$WORK/batch.E"
COUNTS_E=$(sweep_sim "$REPOC" "$WORK/linear-up.json" 1 1 0 "$EV_E" "$BT_E")

b() { printf '%s' "$1" | jq -r ".$2"; }

# AC2 — the purge completes before the first /orchestrate
LAST_PURGE=$(grep -n '^PURGE ' "$EV_A" | tail -n1 | cut -d: -f1)
FIRST_ORCH=$(grep -n '^ORCH ' "$EV_A" | head -n1 | cut -d: -f1)
check "AC2" "every purge verdict precedes the first walk run" "yes" \
  "$([ "$FIRST_ORCH" -gt "$LAST_PURGE" ] && echo yes || echo no)"
check "AC2" "no walk run is interleaved inside the purge" "0" \
  "$(awk -v p="$LAST_PURGE" 'NR<=p && /^ORCH /' "$EV_A" | grep -c . || true)"
check "AC2" "the purge judged the full set in one pass" "7" \
  "$(grep -c '^PURGE ' "$EV_A" || true)"
md_rule "AC2" "the protocol judges before any spawn" 1 "Judge every item in that set before any"
md_rule "AC2" "the protocol forbids interleaving" 1 "Do not interleave"

# AC5 — one batch listing of slug | disposition | evidence
check "AC5" "the batch is one listing over the purge verdicts" "7" "$(wc -l < "$BT_A" | tr -d ' ')"
check "AC5" "every batch row is slug | disposition | evidence" "0" \
  "$(grep -cvE '^[^|]+ \| (CLOSE|ASK|KEEP-OPEN) \| ' "$BT_A" || true)"
check "AC5" "the batch lists the CLOSE verdicts with evidence" "3" \
  "$(grep -c ' | CLOSE | Mechanical evidence' "$BT_A" || true)"
check "AC5" "the batch lists the ASK verdict with what the bar lacked" "1" \
  "$(grep -c 'stale-present | ASK | bar not met' "$BT_A" || true)"
check "AC5" "an answered ASK journals as a terminal disposition" "asked-answered" \
  "$(bash "$SWEEP" journal-append --file "$WORK/askans.jsonl" --json \
      '{"ts":"2026-10-22T13:00:00Z","disposition":"ASK","evidence":"bar not met","args":"answer=defer","tag_baseline":"v1.9.0","outcome":"asked-answered"}' >/dev/null; \
     jq -r '.outcome' "$WORK/askans.jsonl")"
md_rule "AC5" "the protocol prints one batch listing" 1 'Print **one** batch listing'
md_rule "AC5" "the attended gate offers accept-all" 1 "accept-all"
md_rule "AC5" "the attended gate offers per-item removal" 1 "name the items to remove"
md_rule "AC5" "each ASK is answered close / run / defer" 1 "ask close / run / defer"
md_rule "AC5" "each answer becomes a terminal Disposition" 1 "Each answer becomes a terminal"

# AC6 — CLOSE goes through close.sh, and it is idempotent
check "AC6" "a CLOSE invokes the close verb" "1" "$(grep -c '^APPLY-CLOSE stale-absent$' "$EV_A" || true)"
check "AC6" "the closed item is terminal on disk" "COMPLETED" "$(item_status "$REPOA" stale-absent)"
check "AC6" "the closed item leaves the open set" "0" \
  "$(bash "$SWEEP" merge-open --linear-json "$WORK/empty-linear.json" --local-root "$REPOA" \
     | grep -c '"slug":"stale-absent"' || true)"
CLOSE2=$(bash "$CLOSE" stale-absent --root "$REPOA" --ticket CDT-1 2>&1); CLOSE2_RC=$?
check "AC6" "a repeated CLOSE is idempotent (rc 0)" "0" "$CLOSE2_RC"
check "AC6" "the repeated CLOSE reports already closed" "1" \
  "$(printf '%s' "$CLOSE2" | grep -c '^Already closed')"
check "AC6" "the journal records the close intent before the flip" "1" \
  "$(grep -c '^INTENT-STATUS stale-absent|PENDING$' "$EV_A" || true)"
check "AC6" "the journal records the flip after the side effect" "closed" \
  "$(tail -n1 "$REPOA/.claude/sweeps/stale-absent.jsonl" | jq -r '.outcome')"
count_not "AC6" "sweep.sh writes no backlog index" "$SWEEP" '^[^#]*\.claude/backlog\.md'
count_not "AC6" "sweep.sh writes no item file" "$SWEEP" '^[^#]*(atomic_write|>[> ]*"?[^"]*backlog/)'
md_rule "AC6" "the protocol closes through the backlog close verb" 1 "CLOSE\` → \`/backlog close"
md_rule "AC6" "the close verbs are idempotent" 1 "both are idempotent"
md_rule "AC6" "the protocol forbids hand-writing trackers" 1 "Never hand-write"

# AC4 — a signal below the bar becomes ASK in the real flow, never a CLOSE
check "AC4" "the purge closed exactly the items that met the bar" "3" "$(b "$COUNTS_A" CLOSE)"
check "AC4" "the item with a present cited path was not closed" "0" \
  "$(grep -c '^APPLY-CLOSE stale-present$' "$EV_A" || true)"
check "AC4" "that item stayed PENDING through the purge" "yes" \
  "$([ "$(item_status "$REPOA" stale-present)" = "PENDING" ] \
     || [ "$(item_status "$REPOA" stale-present)" = "DEFERRED" ] && echo yes || echo no)"
check "AC4" "the shipped-after item closed on the CHANGELOG/spec cite" "COMPLETED" \
  "$(item_status "$REPOA" stale-shipped)"
check "AC3" "the paths-absent item closed on the absent-path cite" "COMPLETED" \
  "$(item_status "$REPOA" stale-absent)"
check "AC3" "the CLOSE journal carries the Mechanical evidence" "Mechanical evidence" \
  "$(head -n1 "$REPOA/.claude/sweeps/stale-absent.jsonl" | jq -r '.evidence' | cut -c1-19)"

# AC10 — epic children: skipped, counted, no journal record
check "AC10" "the local epic child is counted in SKIP" "1" \
  "$(grep -c '^SKIP-EPIC epic-kid$' "$EV_A" || true)"
check "AC10" "an epic child writes no journal file" "absent" \
  "$([ -e "$REPOA/.claude/sweeps/epic-kid.jsonl" ] && echo present || echo absent)"
check "AC10" "an epic child is not triaged" "0" \
  "$(grep -c '^PURGE epic-kid$' "$EV_A" || true)"
check "AC10" "a Linear parentId child is skipped with no journal" "1" \
  "$(grep -c '^SKIP-EPIC CDT-141$' "$EV_D" || true)"
check "AC10" "the Linear epic child writes no journal file" "absent" \
  "$([ -e "$REPOC/.claude/sweeps/CDT-141.jsonl" ] && echo present || echo absent)"
check "AC10" "the epic child is in the summary SKIP bucket" "1" "$(b "$COUNTS_D" SKIP)"

# AC13 — the journal skip, observed over three consecutive sweeps
check "AC13" "sweep B skips the deferred item on its terminal outcome" "1" \
  "$(grep -c '^SKIP-JOURNAL stale-present$' "$EV_B" || true)"
check "AC13" "sweep B skips the shipped item" "1" "$(grep -c '^SKIP-JOURNAL work-s$' "$EV_B" || true)"
check "AC13" "sweep B re-judges the item with no journal" "1" \
  "$(grep -c '^PURGE work-m$' "$EV_B" || true)"
check "AC13" "--refresh re-judges a deferred item" "1" \
  "$(grep -c '^PURGE stale-present$' "$EV_C" || true)"
check "AC13" "--refresh re-judges a shipped item" "1" \
  "$(grep -c '^PURGE work-s$' "$EV_C" || true)"
check "AC13" "the baseline the sweeps used is the snapshot tag" "yes" \
  "$([ "$(grep -c "^BASELINE v1.9.0|" "$EV_A")" -eq 1 ] \
     && grep -q '^BASELINE v1.9.0|2026-06-01' "$EV_A" && echo yes || echo no)"
check "AC13" "an intent-only record re-judges in the walk (Linear-only item)" "1" \
  "$(grep -c '^PURGE CDT-140$' "$EV_E" || true)"
check "AC13" "the attended sweep left that record as an intent (no outcome)" "0" \
  "$(head -n1 "$REPOC/.claude/sweeps/CDT-140.jsonl" | grep -c outcome || true)"
check "AC13" "the autopilot sweep completed that record" "1" \
  "$(tail -n1 "$REPOC/.claude/sweeps/CDT-140.jsonl" | jq -r '.outcome' | grep -c deferred || true)"
md_rule "AC13" "the protocol skips on a terminal record" 1 "Exit 0 means skip: print the reason line"
md_rule "AC13" "the protocol re-judges an intent record" 1 "re-judges that item"

# AC14 — autopilot: no questions, ASK converts to DEFER, halt does not stop the walk
check "AC14" "autopilot converts the ASK to DEFER" "1" "$(b "$COUNTS_A" DEFER)"
check "AC14" "autopilot leaves no item in the ASK bucket" "0" "$(b "$COUNTS_A" ASK)"
check "AC14" "the DEFER journal carries the missing-evidence reason" "missing-evidence:" \
  "$(head -n1 "$REPOA/.claude/sweeps/stale-present.jsonl" | jq -r '.evidence' | cut -c1-17)"
check "AC14" "the DEFER applied through defer.sh" "1" \
  "$(grep -c '^APPLY-DEFER stale-present$' "$EV_A" || true)"
check "AC14" "defer.sh flipped the item to the open DEFERRED status" "DEFERRED" \
  "$(item_status "$REPOA" stale-present)"
check "AC14" "the deferred item is still in the open set" "1" \
  "$(bash "$SWEEP" merge-open --linear-json "$WORK/empty-linear.json" --local-root "$REPOA" \
     | grep -c '"slug":"stale-present"' || true)"
check "AC14" "attended leaves the ASK in the ASK bucket" "1" "$(b "$COUNTS_D" ASK)"
check "AC14" "a blocking-condition halt is journaled pr-stopped" "1" \
  "$(tail -n1 "$REPOA/.claude/sweeps/work-m.jsonl" | jq -r '.outcome' | grep -c 'pr-stopped' || true)"
check "AC14" "the halt is listed as an escalation" "1" "$(b "$COUNTS_B" escalations)"
check "AC14" "the walk continues after the halt" "2" "$(b "$COUNTS_B" ORCHESTRATE)"
check "AC14" "--limit bounds the walk runs only" "1" "$(b "$COUNTS_A" ORCHESTRATE)"
check "AC14" "--limit does not shrink the purge" "7" "$(grep -c '^PURGE ' "$EV_A" || true)"
check "AC14" "the bounded item is counted, not lost" "3" "$(b "$COUNTS_A" SKIP)"
check "AC14" "with no limit every kept item runs" "3" "$(b "$COUNTS_C" ORCHESTRATE)"
check "AC14" "the walk runs size ascending (S before M before L)" "yes" \
  "$([ "$(grep -n '^ORCH work-s$' "$EV_C" | cut -d: -f1)" -lt \
        "$(grep -n '^ORCH work-m$' "$EV_C" | cut -d: -f1)" ] \
     && [ "$(grep -n '^ORCH work-m$' "$EV_C" | cut -d: -f1)" -lt \
        "$(grep -n '^ORCH work-l$' "$EV_C" | cut -d: -f1)" ] && echo yes || echo no)"
md_rule "AC14" "autopilot asks nothing" 1 "Ask nothing"
md_rule "AC14" "autopilot defers every would-be ASK" 1 "Convert every"
md_rule "AC14" "each spawned run emits its own decision-cards" 2 "decision-cards"
md_rule "AC14" "a halt inside a run does not halt the sweep" 1 "MUST NOT halt the sweep"
md_rule "AC14" "the limit counts orchestrate runs only" 1 "counts these runs only"
md_rule "AC14" "the purge stays full under a limit" 1 "the Purge pre-pass stays full"
md_rule "AC14" "the walk probes the host before spawning" 1 "can-spawn-agents"
md_rule "AC14" "a host that cannot spawns runs print-and-run" 1 "print-and-run this turn"
md_rule "AC14" "the sweep never claims a nested spawn it did not make" 1 "MUST NOT claim a"

# R2 GAPS-2 — a child halt names its own condition; the journal enum is closed.
check "AC14" "walk-outcome maps a landed run to shipped" "shipped" \
  "$(bash "$SWEEP" walk-outcome --landed)"
check "AC14" "walk-outcome maps complexity-overflow to pr-stopped" "pr-stopped" \
  "$(bash "$SWEEP" walk-outcome --halt complexity-overflow)"
rc_is "AC14" "walk-outcome with no flag is a usage error" 64 bash "$SWEEP" walk-outcome
rc_is "AC14" "walk-outcome with both flags is a usage error" 64 \
  bash "$SWEEP" walk-outcome --landed --halt bc5-reroute
rc_is "AC14" "walk-outcome with an empty --halt is a usage error" 64 \
  bash "$SWEEP" walk-outcome --halt ""
rc_is "AC14" "journal-append rejects a child halt name as an outcome (the enum stays closed)" 64 \
  bash "$SWEEP" journal-append --file "$WORK/halt-enum.jsonl" --json \
  '{"ts":"2026-10-23T09:00","disposition":"ORCHESTRATE","evidence":"halt: complexity-overflow","args":"/orchestrate --tier=light","tag_baseline":"v1.9.0","outcome":"complexity-overflow"}'
check "AC14" "the mapped record appends (rc 0)" "0" \
  "$(bash "$SWEEP" journal-append --file "$WORK/halt-enum.jsonl" --json \
      '{"ts":"2026-10-23T09:00","disposition":"ORCHESTRATE","evidence":"halt: complexity-overflow","args":"/orchestrate --tier=light","tag_baseline":"v1.9.0","outcome":"pr-stopped"}' \
      >/dev/null 2>&1; echo $?)"
check "AC14" "the halt event carries the child's named condition" "1" \
  "$(grep -c '^HALT work-m complexity-overflow$' "$EV_B" || true)"
check "AC14" "the halt record keeps the name in evidence" "halt: complexity-overflow" \
  "$(tail -n1 "$REPOA/.claude/sweeps/work-m.jsonl" | jq -r '.evidence' \
     | grep -o 'halt: complexity-overflow' || true)"
check "AC14" "the halt record uses the enum value pr-stopped" "pr-stopped" \
  "$(tail -n1 "$REPOA/.claude/sweeps/work-m.jsonl" | jq -r '.outcome')"
check "AC14" "a completed walk record uses the enum value shipped" "shipped" \
  "$(bash "$SWEEP" walk-outcome --landed)"
# The outcome record is the last write of the run: an unwritable journal cannot
# abort the walk (AC14). journal-append fails closed on a bad path, so the fence
# reports it and the sweep moves on.
check "AC14" "a journal-append to a directory path fails (rc 1)" "1" \
  "$(bash "$SWEEP" journal-append --file "$WORK" --json \
      '{"ts":"2026-10-23T09:00","disposition":"ORCHESTRATE","evidence":"x","args":"y","tag_baseline":"v1.9.0","outcome":"pr-stopped"}' \
      >/dev/null 2>&1; echo $?)"
md_rule "AC14" "the protocol maps any child halt outcome to pr-stopped" 1 \
  "to the enum value \`pr-stopped\` and keep the"
md_rule "AC14" "an outcome record that fails to append does not abort the walk" 1 \
  "MUST NOT abort the walk"
md_rule "AC14" "the intent fence keeps its exit discipline" 1 "an intent record that cannot be written"
# R2 GAPS-1, observed in the composition runs.
check "AC9" "the attended walk compiles with no autopilot argv" "0" \
  "$(grep '^ARGS ' "$EV_D" | grep -c -- '--autopilot' || true)"
check "AC9" "the autopilot walk compiles the master argv" "0" \
  "$(grep '^ARGS ' "$EV_A" | grep -q -- '--autopilot=master'; echo $?)"
check "AC9" "the attended walk emits tier-only compiled lines" "0" \
  "$(grep '^ARGS ' "$EV_D" | cut -d'|' -f2 \
     | grep -vE '^$|^--tier=(light|full)$' | wc -l | tr -d ' ')"
check "AC9" "the attended run compiled at least one walk line" "1" \
  "$(grep -c '^ARGS ' "$EV_D" | awk '{print ($1>0)?1:0}')"

# ===========================================================================
# AC15 — the terminal summary: N open, five buckets, escalations, exit 0
# ===========================================================================
check "AC15" "summary prints N open and the buckets" \
  "Sweep summary: 7 open
CLOSE 1
ASK 2
ORCHESTRATE 3
DEFER 0
SKIP 1
escalations 2" \
  "$(bash "$SWEEP" summary --counts '{"open":7,"CLOSE":1,"ASK":2,"ORCHESTRATE":3,"DEFER":0,"SKIP":1,"escalations":2}')"
rc_is "AC15" "summary exits 0 with escalations" 0 bash "$SWEEP" summary \
  --counts '{"open":3,"CLOSE":0,"ASK":0,"ORCHESTRATE":1,"DEFER":2,"SKIP":0,"escalations":1}'
rc_is "AC15" "summary rejects non-object counts" 64 bash "$SWEEP" summary --counts '[1]'
rc_is "AC15" "summary without --counts is a usage error" 64 bash "$SWEEP" summary
check "AC15" "a missing bucket key counts 0" "1" \
  "$(bash "$SWEEP" summary --counts '{"open":2,"CLOSE":2}' | grep -c '^SKIP 0$')"
check "AC15" "all five dispositions are bucketed" "5" \
  "$(bash "$SWEEP" summary --counts '{"open":1}' | grep -cE '^(CLOSE|ASK|ORCHESTRATE|DEFER|SKIP) [0-9]+$')"
# Every composition run: each item lands in exactly one bucket, so the buckets
# sum to N open, and the summary exits 0 with the escalations listed.
for r in A B C D E; do
  cnt_var="COUNTS_$r"
  cnt=$(printf '%s' "${!cnt_var}")
  check "AC15" "run $r: buckets sum to N open ($(b "$cnt" CLOSE)+$(b "$cnt" ASK)+$(b "$cnt" ORCHESTRATE)+$(b "$cnt" DEFER)+$(b "$cnt" SKIP) = $(b "$cnt" open))" \
    "$(b "$cnt" open)" \
    "$(printf '%s' "$cnt" | jq -r '[.CLOSE,.ASK,.ORCHESTRATE,.DEFER,.SKIP] | add')"
  rc_is "AC15" "run $r: the sweep exits 0 on its summary" 0 bash "$SWEEP" summary --counts "$cnt"
done
check "AC15" "run B lists the halt as an escalation in the summary" "escalations 1" \
  "$(bash "$SWEEP" summary --counts "$COUNTS_B" | grep '^escalations')"
check "AC15" "the summary names the OPEN count" "1" \
  "$(bash "$SWEEP" summary --counts "$COUNTS_A" | grep -c '^Sweep summary: 8 open$')"
md_rule "AC15" "every item is counted in exactly one bucket" 1 "Count every item in exactly one bucket"
md_rule "AC15" "the sweep exits 0 with escalations" 1 "Exit 0 with escalations"
md_rule "AC15" "a non-zero exit means machinery failure only" 1 "Non-zero only for machinery failure"

# R2 GAPS-3 — the walk-truncated tail is a SKIP member, never a lost item (M18, M24).
A_TAIL=$(grep -c '^WALK-BOUND ' "$EV_A" || true)
check "AC15" "run A: the bound truncated two kept items" "2" "$A_TAIL"
check "AC15" "run A: SKIP = the epic child + the walk-truncated tail" \
  "$((1 + A_TAIL))" "$(b "$COUNTS_A" SKIP)"
check "AC15" "run A: the bound did not shrink the purge (8 open - 1 epic child)" "7" \
  "$(grep -c '^PURGE ' "$EV_A" || true)"
md_rule "AC15" "the protocol puts the walk-truncated tail in SKIP" 1 \
  "Every item the bound truncates goes in"
md_rule "AC15" "the protocol names the three SKIP kinds" 1 "\`SKIP\` holds three kinds of item"
md_rule "AC15" "the protocol keeps the bucket sum at N open" 1 "five buckets sum to N open"
md_rule "AC15" "the protocol counts the tail, never drops it" 1 "counted, never dropped"

# ===========================================================================
# AC16 — write surface: journal and tracker flips only; no release; no command
# ===========================================================================
check "AC16" "three sweeps leave the tracked tree clean" "" "$(git -C "$REPOA" status --porcelain)"
check "AC16" "no tracked file is modified" "" "$(git -C "$REPOA" diff --stat)"
check "AC16" "the sweep wrote only ignored process state under .claude/" "1" \
  "$(git -C "$REPOA" -c core.excludesfile=/dev/null status --porcelain --ignored 2>/dev/null \
     | grep -c '^!! \.claude/$')"
check "AC16" "nothing outside .claude/ is untracked or ignored" "0" \
  "$(git -C "$REPOA" -c core.excludesfile=/dev/null status --porcelain --ignored -uall 2>/dev/null \
     | grep -v '\.claude/' | grep -c . || true)"
count_not "AC16" "sweep.sh never writes outside its journal and temp files" \
  "$SWEEP" '>[> ]*"\$(ROOT|MROOT|SWEEP_DIR|local_root)"'
count_not "AC16" "sweep.sh never runs the release skill" "$SWEEP" '^[^#]*bash .*release/'
check "AC16" "sweep.sh never sources fold-sweep.sh" "0" \
  "$(grep -cE '^[[:space:]]*(source|\.)[[:space:]]+["'"'"']?[^ ]*fold-sweep' "$SWEEP" || true)"
check "AC16" "sweep.md never sources fold-sweep.sh" "0" \
  "$(grep -cE '^[[:space:]]*(source|\.)[[:space:]]+["'"'"']?[^ ]*fold-sweep' "$SWEEP_MD" || true)"
check "AC16" "sweep.md never names fold-sweep.sh" "0" "$(grep -c 'fold-sweep' "$SWEEP_MD" || true)"
md_rule "AC16" "the protocol forbids sourcing the post-ship sweep" 1 "MUST NOT source the post-ship close-out"
md_rule "AC16" "the protocol lists the two write classes" 1 "A sweep writes only"
md_rule "AC16" "the protocol forbids invoking /release" 1 "MUST NOT invoke"
check "AC16" "commands/backlog.md is absent (skill-only surface)" "absent" \
  "$(test -e "$HERE/../../commands/backlog.md" && echo present || echo absent)"
check "AC16" ".gitignore carries the sweeps line" "1" \
  "$(grep -c '^\.claude/sweeps/$' "$GITIGNORE")"
check_lt "AC16" "SKILL.md stays under the 30720 byte budget" 30720 "$(wc -c < "$SKILL_MD" | tr -d ' ')"
check "AC16" "SKILL.md points at the protocol sidecar" "1" \
  "$(grep -cF 'Read `skills/backlog/sweep.md`' "$SKILL_MD")"
check "AC16" "sweep.sh is a subprocess CLI with a verb dispatcher" "1" "$(grep -cE '^VERB=' "$SWEEP")"
check "AC16" "journal-append is the only record writer" "1" \
  "$(grep -cE '^[[:space:]]*printf .+>> "\$file"' "$SWEEP")"
check "AC16" "every other redirect targets a temp staging file" "2" \
  "$(grep -cE '^[[:space:]]*printf .+>> "\$out"' "$SWEEP")"
count_not "AC16" "sweep.sh opens no tracked-path write" \
  "$SWEEP" '^[^#]*>[> ]*"\$(ROOT|local_root|root)"'

# ===========================================================================
# AC1 — Linear-down fail-open (folded from old AC17)
# ===========================================================================
count_in "AC1" "the fail-open line is exact" 1 "$SWEEP_MD" "Linear unreachable — local backlog only."
md_rule "AC1" "the protocol prints the line exactly once" 1 "exactly one line"
md_rule "AC1" "the protocol forbids a retry loop" 1 "MUST NOT retry-loop (M6)"
md_rule "AC1" "the down case leaves the linear json empty and continues" 1 "empty, and continue"
check "AC1" "the Linear-down input is an empty file the CLI accepts" "5" \
  "$(bash "$SWEEP" merge-open --linear-json /dev/null --local-root "$LR" | wc -l | tr -d ' ')"
check "AC1" "an empty linear-json is the Linear-down input (exit 0)" "0" \
  "$(bash "$SWEEP" merge-open --linear-json "$WORK/empty-linear.json" --local-root "$LR" >/dev/null 2>&1; echo $?)"
check "AC1" "the Linear-down open set is the local set only" "5" \
  "$(bash "$SWEEP" merge-open --linear-json "$WORK/empty-linear.json" --local-root "$LR" \
     | jq -r '.slug' | grep -c . || true)"
check "AC1" "every Linear-down row is source local" "0" \
  "$(bash "$SWEEP" merge-open --linear-json "$WORK/empty-linear.json" --local-root "$LR" \
     | jq -r 'select(.source != "local") | .slug' | grep -c . || true)"
check "AC1" "the Linear-down sweep walked the local set (8 open, all local)" "8" \
  "$(b "$COUNTS_A" open)"
check "AC1" "the Linear-down sweep closed locally (no Linear verb)" "1" \
  "$(grep -c '^APPLY-CLOSE stale-absent$' "$EV_A" || true)"
check "AC1" "a missing linear-json path fails closed (not a silent empty set)" "1" \
  "$(bash "$SWEEP" merge-open --linear-json "$WORK/none.json" --local-root "$LR" >/dev/null 2>&1; echo $?)"
count_not "AC1" "sweep.sh calls no MCP tool" "$SWEEP" '^[^#]*mcp__'
count_not "AC1" "sweep.sh makes no network call" "$SWEEP" '^[^#]*(curl|wget|linear_api)'
# ===========================================================================
# AC3 — untrusted ticket text (folded from old AC18)
# ===========================================================================
check "AC3" "a metachar title survives as data" "'; echo pwned \$(uname) --project" \
  "$(jq -r 'select(.slug == "metachar") | .title' "$MO")"
check "AC3" "no command ran from a metachar title" "absent" \
  "$([ -e "$WORK/exec.marker" ] && echo present || echo absent)"
EVF="$WORK/evmeta.txt"
bash "$SWEEP" evidence-paths-absent --root "$EVR" -- \
  'never/$(touch '"$EVP"').md' "sub dir/'; rm -rf / #" >"$EVF" 2>&1
check "AC3" "metachar paths exit 0 as data" "0" "$?"
check "AC3" "no command ran from a metachar path" "absent" \
  "$([ -e "$EVP" ] && printf ran || printf absent)"
check "AC3" "the metachar path is cited verbatim" "1" \
  "$(grep -c "^cite sub dir/'; rm -rf / # — absent at HEAD" "$EVF")"
SQLJ="$WORK/sql.jsonl"
SQL_EV="'; drop table backlog; -- \$(uname) \`id\` --project x"
bash "$SWEEP" journal-append --file "$SQLJ" --json "$(jq -cn --arg ev "$SQL_EV" \
  '{ts:"2026-10-22T14:00:00Z",disposition:"CLOSE",evidence:$ev,args:"close.sh x",tag_baseline:"v1.9.0"}')" >/dev/null
check "AC3" "an SQL fragment round-trips byte-exact in the journal" "$SQL_EV" \
  "$(jq -r '.evidence' "$SQLJ")"
check "AC3" "the journal stays one parseable record" "1" "$(jq -c . "$SQLJ" | wc -l | tr -d ' ')"
check "AC3" "the local backlog fixture is intact (nothing dropped or removed)" "6" \
  "$(ls -1 "$LR/.claude/backlog" | wc -l | tr -d ' ')"
check "AC3" "the hostile composition item wrote no marker in the repo" "absent" \
  "$([ -e "$REPOA/pwned.marker" ] && echo present || echo absent)"
check "AC3" "the hostile title is unchanged on disk" "1" \
  "$(grep -cF "# '; echo pwned \$(uname) --project" "$REPOA/.claude/backlog/metachar-item.md")"
check "AC3" "the hostile Affects lines are unchanged on disk" "1" \
  "$(grep -cF -- "- '; drop table backlog; --" "$REPOA/.claude/backlog/metachar-item.md")"
check "AC3" "the hostile item reached the batch listing as data" "1" \
  "$(grep -c '^metachar-item | CLOSE |' "$BT_A" || true)"
DEFNOTE="$WORK/noted"
mkdir -p "$DEFNOTE/.claude/backlog"
write_item "$DEFNOTE" noted-item 'Noted item' PENDING 2026-01-01 '' '' ''
bash "$DEFER" noted-item --root "$DEFNOTE" --note "'; echo pwned \$(uname) --project; drop table backlog; --" >/dev/null 2>&1
check "AC3" "defer.sh writes a hostile note verbatim (rc 0)" "0" "$?"
check "AC3" "the hostile note is data in the item file" "1" \
  "$(grep -cF -- "*Deferred: $(date -u +%Y-%m-%d) — '; echo pwned \$(uname) --project; drop table backlog; --*" "$DEFNOTE/.claude/backlog/noted-item.md")"
check "AC3" "no command ran from a hostile note" "absent" \
  "$([ -e "$DEFNOTE/pwned.marker" ] && echo present || echo absent)"
check "AC3" "sweep.sh has exactly one eval (the is_release_tag lift over shipped source)" "1" \
  "$(grep -cE '^[^#]*eval[[:space:]]' "$SWEEP" || true)"
check "AC3" "the eval target is the checked function text, never item text" "1" \
  "$(grep -cE '^[[:space:]]*eval "\$fn"[[:space:]]*$' "$SWEEP")"
check "AC3" "the eval is guarded by a definition check" "1" \
  "$(grep -cE 'unexpected is_release_tag definition' "$SWEEP")"
count_not "AC3" "sweep.sh never uses bash -c or sh -c" "$SWEEP" '^[^#]*(bash|sh) -c'
count_not "AC3" "sweep.sh embeds no ticket text in a command word" "$SWEEP" '\$\{?TITLE|\$\{?BODY|\$\{?AFFECTS'
check "AC3" "sweep.sh runs no SQL (the store is JSONL)" "0" \
  "$(grep -cE '^[^#]*sqlite3' "$SWEEP" || true)"
check "AC3" "the mandated SQL helper exists for callers that need it" "present" \
  "$([ -f "$SQLQ" ] && echo present || echo absent)"
md_rule "AC3" "the protocol passes ticket text as argv only" 1 "and slug reach"
md_rule "AC3" "the protocol routes SQL through sqlq.sh" 1 "goes through \`skills/lib/sqlq.sh\`"
md_rule "AC3" "the protocol forbids eval of ticket text" 1 "Never \`eval\` ticket"

# ===========================================================================
# Flag parsing, the defer verb, the Linear-only floor, and the mid-walk tag
# ===========================================================================
# AC9 / AC13 / AC14 — the flag surface the protocol parses first (Step 1).
check "AC9" "parse-flags defaults" \
  '{"ship":"","limit":0,"project":"","refresh":false,"skip_decided":false,"autopilot":false}' \
  "$(bash "$SWEEP" parse-flags)"
check "AC9" "sweep --autopilot defaults --ship to master" "master" \
  "$(bash "$SWEEP" parse-flags --autopilot | jq -r '.ship')"
check "AC9" "an explicit --ship wins over the autopilot default" "pr" \
  "$(bash "$SWEEP" parse-flags --autopilot --ship=pr | jq -r '.ship')"
check "AC9" "parse-flags rejects a bump on --autopilot" 64 \
  "$(bash "$SWEEP" parse-flags --autopilot=patch >/dev/null 2>&1; echo $?)"
check "AC9" "--autopilot=false keeps the attended default" "false" \
  "$(bash "$SWEEP" parse-flags --autopilot=false | jq -r '.autopilot')"
rc_is "AC9" "parse-flags rejects a bad --ship" 64 bash "$SWEEP" parse-flags --ship=squash
rc_is "AC9" "parse-flags rejects an empty --ship" 64 bash "$SWEEP" parse-flags --ship=
rc_is "AC9" "parse-flags rejects a duplicate --ship" 64 bash "$SWEEP" parse-flags --ship=pr --ship=patch
rc_is "AC9" "parse-flags rejects a --ship with no value" 64 bash "$SWEEP" parse-flags --ship
rc_is "AC9" "parse-flags rejects an unknown flag" 64 bash "$SWEEP" parse-flags --bogus
rc_is "AC14" "parse-flags rejects a non-integer --limit" 64 bash "$SWEEP" parse-flags --limit x
rc_is "AC14" "parse-flags rejects a negative --limit" 64 bash "$SWEEP" parse-flags --limit=-1
check "AC14" "parse-flags keeps --limit 0 (no bound)" "0" \
  "$(bash "$SWEEP" parse-flags --limit 0 | jq -r '.limit')"
check "AC14" "parse-flags carries a large --limit" "9" \
  "$(bash "$SWEEP" parse-flags --limit=9 | jq -r '.limit')"
rc_is "AC13" "parse-flags --refresh --skip-decided exits 64" 64 \
  bash "$SWEEP" parse-flags --refresh --skip-decided
check "AC13" "the conflicting flags emit no JSON" "" "$(bash "$SWEEP" parse-flags --refresh --skip-decided 2>/dev/null)"
check "AC13" "the verb reports the conflict on stderr and prints nothing on stdout" "" \
  "$(bash "$SWEEP" journal-skip --file "$SKIPJ" --tag-date "2026-10-20T00:00:00Z" \
      --refresh --skip-decided 2>/dev/null)"
check "AC1" "parse-flags keeps an untrusted --project as data" "'; rm -rf / #" \
  "$(bash "$SWEEP" parse-flags --project "'; rm -rf / #" | jq -r '.project')"
check "AC1" "parse-flags reports the project filter for the Linear query" "acme" \
  "$(bash "$SWEEP" parse-flags --project=acme | jq -r '.project')"

# AC6 — defer.sh is the DEFER verb: open status, idempotent, index untouched.
DFR="$WORK/deferroot"
mkdir -p "$DFR/.claude/backlog"
cat > "$DFR/.claude/backlog.md" <<'EOF'
# Defer - Backlog Index

## Pending

- [Defer me](backlog/defer-me.md) - Defer me [PENDING]

## Completed
EOF
write_item "$DFR" defer-me 'Defer me' PENDING 2026-01-01 '' '' 'S'
DEF1=$(bash "$DEFER" defer-me --root "$DFR" --note "sweep: needs a decision" 2>&1); DEF1_RC=$?
check "AC6" "defer.sh applies the DEFER verb" "0" "$DEF1_RC"
check "AC6" "defer.sh reports the write" "1" "$(printf '%s' "$DEF1" | grep -c '^Deferred: \.claude/backlog/defer-me\.md$')"
check "AC6" "the item now reads DEFERRED" "DEFERRED" "$(item_status "$DFR" defer-me)"
check "AC6" "DEFERRED stays an open status" "1" \
  "$(bash "$TS_SH" is-closed DEFERRED >/dev/null 2>&1; echo $?)"
check "AC6" "the deferred item is still in the open set" "1" \
  "$(bash "$SWEEP" merge-open --linear-json "$WORK/empty-linear.json" --local-root "$DFR" \
     | grep -c '"slug":"defer-me"' || true)"
check "AC6" "the index row is not moved to Completed" "1" \
  "$(grep -c '^- \[Defer me\](backlog/defer-me.md) - Defer me \[PENDING\]' "$DFR/.claude/backlog.md")"
check "AC6" "the deferred item carries the deferral note" "1" \
  "$(grep -cF '*Deferred: ' "$DFR/.claude/backlog/defer-me.md")"
DEF2=$(bash "$DEFER" defer-me --root "$DFR" --note "sweep: needs a decision" 2>&1); DEF2_RC=$?
check "AC6" "a repeated DEFER is idempotent (rc 0)" "0" "$DEF2_RC"
check "AC6" "the repeated DEFER reports already deferred" "1" \
  "$(printf '%s' "$DEF2" | grep -c '^Already deferred')"
check "AC6" "the repeated DEFER adds no second footer" "1" \
  "$(grep -cF '*Deferred: ' "$DFR/.claude/backlog/defer-me.md")"
DEF_SHA=$(cksum < "$DFR/.claude/backlog/defer-me.md")
bash "$DEFER" defer-me --root "$DFR" >/dev/null 2>&1
check "AC6" "a third DEFER leaves the item file byte-identical" "$DEF_SHA" \
  "$(cksum < "$DFR/.claude/backlog/defer-me.md")"
rc_is "AC6" "defer.sh with no slug is a usage error" 64 bash "$DEFER" --root "$DFR"
rc_is "AC6" "defer.sh rejects a path-escaping slug" 1 bash "$DEFER" "../escape" --root "$DFR"
rc_is "AC6" "defer.sh on a missing item exits 1" 1 bash "$DEFER" no-such-item --root "$DFR"
md_rule "AC6" "a DEFER with a slug uses defer.sh" 1 "with a slug → \`defer.sh\`"

# AC5 — the Linear-only floor: ASK, never CLOSE, never defer.sh.
check "AC5" "a Linear-only item is listed as ASK in the batch" "1" \
  "$(grep -c '^CDT-140 | ASK |' "$BT_D" || true)"
check "AC5" "the sweep never invokes the close verb for a Linear-only item" "0" \
  "$(grep -c 'APPLY-CLOSE CDT-140' "$EV_D" "$EV_E" | awk -F: '{s+=$2} END {print s+0}')"
check "AC5" "the sweep never invokes defer.sh for a Linear-only item" "0" \
  "$(grep -c '^APPLY-DEFER CDT-140$' "$EV_E" || true)"
check "AC5" "the Linear-only DEFER is journal-only" "1" \
  "$(grep -c '^APPLY-DEFER-JOURNAL CDT-140$' "$EV_E" || true)"
check "AC5" "no local item file was invented for a Linear-only issue" "absent" \
  "$([ -e "$REPOC/.claude/backlog/CDT-140.md" ] && echo present || echo absent)"
rc_is "AC5" "close.sh cannot close an empty slug (the M11 floor)" 64 bash "$CLOSE" "" --root "$REPOC"
md_rule "AC5" "the protocol floors a Linear-only item at ASK" 1 'is `ASK`, never'
md_rule "AC5" "the protocol journals a Linear-only DEFER by issue id" 1 "keyed by the issue id"

# AC12 — a tag created mid-walk does not move the snapshotted baseline.
SNAP_TAG=$(bash "$SWEEP" last-release-tag --root "$REPOA")
SNAP_DATE=$(git -C "$REPOA" for-each-ref --format='%(committerdate:iso8601-strict)' "refs/tags/$SNAP_TAG")
git -C "$REPOA" commit -q --allow-empty -m mid-walk-release
git -C "$REPOA" tag v1.9.5
check "AC12" "a mid-walk tag moves what a fresh probe reports" "v1.9.5" \
  "$(bash "$SWEEP" last-release-tag --root "$REPOA")"
check "AC12" "the snapshot taken at start is unchanged" "v1.9.0" "$SNAP_TAG"
bash "$SWEEP" journal-skip --file "$MIDJ" --tag-date "$SNAP_DATE" >/dev/null
check "AC12" "the walk keeps using the snapshot: the record still skips" "0" "$?"
bash "$SWEEP" journal-skip --file "$MIDJ" --tag-date "2099-01-01T09:00:00+0000" >/dev/null
check "AC12" "a moved baseline would change the verdict (the snapshot is load-bearing)" "1" "$?"

# AC3 — nothing expanded: no file named after the uname output.
check "AC3" "the shell never expanded the metachar payload" "absent" \
  "$(cd "$REPOA" && ls -A | grep -qiE '^(Linux|Darwin|SunOS|FreeBSD)$' && echo present || echo absent)"
check "AC3" "no injected file landed in the fixture repo" "absent" \
  "$(cd "$REPOA" && ls -A | grep -cE '^(pwned\.marker|Linux|Darwin)$' | awk '{print ($1==0)?"absent":"present"}')"
check "AC3" "the hostile Affects text reached the journal as data (intent + completed)" "2" \
  "$(grep -cF 'drop table backlog' "$REPOA/.claude/sweeps/metachar-item.jsonl" || true)"
check "AC3" "the hostile item closed with no side effects" "COMPLETED" "$(item_status "$REPOA" metachar-item)"

# ===========================================================================
# R2 statics — one copy of each shared helper (SPEC-003 default extract)
# ===========================================================================
count_not "AC3" "sweep.sh defines no local valid_slug" "$SWEEP" '^valid_slug\(\) \{'
count_not "AC3" "sweep.sh defines no local item_status_value" "$SWEEP" '^item_status_value\(\) \{'
count_not "AC3" "sweep.sh defines no local item_title" "$SWEEP" '^item_title\(\) \{'
count_not "AC3" "sweep.sh carries no in-code EXTRACT-DEFERRED waiver" "$SWEEP" 'EXTRACT-DEFERRED'
count_not "AC3" "sweep.md carries no in-code EXTRACT-DEFERRED waiver" "$SWEEP_MD" 'EXTRACT-DEFERRED'
check "AC3" "sweep.sh sources the shared slug helper" "1" \
  "$(grep -cF '. "$SCRIPT_DIR/slug.sh"' "$SWEEP")"
check "AC3" "sweep.sh sources the shared readers" "1" \
  "$(grep -cF '. "$SCRIPT_DIR/readers.sh"' "$SWEEP")"
check "AC3" "close.sh sources the shared slug helper" "1" \
  "$(grep -cF '. "$SCRIPT_DIR/slug.sh"' "$CLOSE")"
check "AC3" "close.sh sources the shared readers" "1" \
  "$(grep -cF '. "$SCRIPT_DIR/readers.sh"' "$CLOSE")"
check "AC3" "defer.sh sources the shared slug helper" "1" \
  "$(grep -cF '. "$SCRIPT_DIR/slug.sh"' "$DEFER")"
check "AC3" "readers.sh carries the two shared readers" "2" \
  "$(grep -cE '^(item_status_value|item_title)\(\) \{' "$READERS")"
check "AC3" "readers.sh adds no third reader" "0" \
  "$(grep -cE '^[a-z_]+\(\) \{' "$READERS" | awk '{print ($1==2)?0:1}')"
check "AC3" "sweep.sh calls the shared readers through them" "2" \
  "$(grep -cE '\$\((item_status_value|item_title) ' "$SWEEP")"
check "AC3" "sweep.sh calls the shared valid_slug" "1" \
  "$(grep -cE '^\s+valid_slug "\$' "$SWEEP")"
rc_is "AC3" "readers.sh refuses to run as a subprocess" 64 bash "$READERS"
check "AC3" "readers.sh prints the source-only notice" "1" \
  "$(bash "$READERS" 2>&1 | grep -cF 'source-only')"
rc_is "AC3" "slug.sh refuses to run as a subprocess" 64 bash "$SLUG_SH"
check "AC3" "tag-date is a dispatched verb" "1" \
  "$(grep -cE '^  tag-date\) cmd_tag_date "\$@" ;;$' "$SWEEP")"
check "AC3" "walk-outcome is a dispatched verb" "1" \
  "$(grep -cE '^  walk-outcome\) cmd_walk_outcome "\$@" ;;$' "$SWEEP")"
check "AC3" "the walk-outcome name appears once in the verb contract" "1" \
  "$(grep -cE '^#   walk-outcome \(M20\)' "$SWEEP")"
check "AC3" "sweep.sh stays under the size budget" "under-64k" \
  "$([ "$(wc -c < "$SWEEP" | tr -d ' ')" -lt 65536 ] && echo under-64k || echo over)"

# ===========================================================================
# Coverage gate: every AC1–AC16 has at least one passing case
# ===========================================================================
for n in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16; do
  if grep -q "^PASS: AC$n:" "$LOG"; then
    printf 'PASS: COVERAGE AC%s has a passing case\n' "$n"
  else
    printf 'FAIL: COVERAGE AC%s has NO passing case\n' "$n"
    FAILS=$((FAILS + 1))
  fi
done

printf 'cases: %s pass, %s fail\n' "$PASSN" "$FAILS" >> "$LOG"
printf 'cases: %s pass, %s fail\n' "$PASSN" "$FAILS"
if [ "$FAILS" -eq 0 ]; then
  printf 'VERIFY exit=0\n'
  exit 0
fi
printf 'VERIFY exit=1\n'
exit 1
