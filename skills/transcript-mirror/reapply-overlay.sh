#!/usr/bin/env bash
# reapply-overlay.sh — SPEC-036 M15 rebuild apply engine (CDT-214).
# Usage: reapply-overlay.sh <sid-dir>
# bash+awk only. No LLM. Recorder-safe (no host interpreter).
set -u

usage() {
  echo "Usage: reapply-overlay.sh <sid-dir>" >&2
  exit 64
}

[ $# -eq 1 ] || usage
SID_DIR=$1
[ -n "$SID_DIR" ] || usage

MAIN="$SID_DIR/main.md"
if [ ! -f "$MAIN" ]; then
  echo "reapply-overlay: main.md missing: $SID_DIR" >&2
  exit 1
fi

MAP=""
OUT=""
cleanup() {
  rm -f "${MAP:-}" "${OUT:-}"
}
trap cleanup EXIT

MAP=$(mktemp "${TMPDIR:-/tmp}/reapply-overlay.map.XXXXXX") || exit 1

VERBATIM="$SID_DIR/verbatim"
if [ -d "$VERBATIM" ]; then
  while IFS= read -r txt; do
    [ -n "$txt" ] || continue
    [ -f "$txt" ] || continue
    base=${txt##*/}
    base=${base%.txt}
    case "$base" in
      T[0-9][0-9][0-9][0-9][0-9][0-9]) ;;
      *) continue ;;
    esac
    sum="$VERBATIM/${base}.sum"
    [ -f "$sum" ] || continue
    digits=${base#T}
    n=$((10#$digits))
    [ "$n" -gt 0 ] || continue
    printf '%s\t%s\t%s\n' "$n" "$base" "$sum" >>"$MAP"
  done < <(find "$VERBATIM" -maxdepth 1 -type f -name 'T[0-9][0-9][0-9][0-9][0-9][0-9].txt' | LC_ALL=C sort)
fi

if [ ! -s "$MAP" ]; then
  exit 0
fi

OUT=$(mktemp "$SID_DIR/.main.md.XXXXXX") || exit 1

if ! awk -v mapfile="$MAP" '
  BEGIN {
    turn = 0
    nbuf = 0
    while ((getline mline < mapfile) > 0) {
      nf = split(mline, a, "\t")
      if (nf < 3) continue
      n = a[1] + 0
      if (n > 0 && a[2] != "" && a[3] != "") {
        oid[n] = a[2]
        spath[n] = a[3]
      }
    }
    close(mapfile)
  }

  function is_heading(s) {
    return s ~ /^## (user|assistant)[[:space:]]*$/
  }
  function is_ref(s) {
    return s ~ /^>[[:space:]]*@/
  }
  function is_blank(s) {
    return s ~ /^[[:space:]]*$/
  }
  function is_self_vref(s, id) {
    return s ~ ("^>[[:space:]]*@verbatim/" id "\\.txt[[:space:]]*$")
  }
  function is_meaning(s) {
    return !is_ref(s) && !is_blank(s)
  }
  function print_unless_self(s, id) {
    if (!is_self_vref(s, id)) print s
  }

  function emit_copy(    i) {
    for (i = 1; i <= nbuf; i++) print buf[i]
  }

  function emit_overlay(    i, id, first_m, last_m, line, sp) {
    id = oid[turn]
    print buf[1]
    first_m = 0
    last_m = 0
    for (i = 2; i <= nbuf; i++) {
      if (is_meaning(buf[i])) {
        if (!first_m) first_m = i
        last_m = i
      }
    }
    if (first_m) {
      for (i = 2; i < first_m; i++) print_unless_self(buf[i], id)
    }
    sp = spath[turn]
    while ((getline line < sp) > 0) print line
    close(sp)
    print "> @verbatim/" id ".txt"
    if (first_m) {
      for (i = first_m + 1; i <= last_m; i++) {
        if (is_ref(buf[i]) && !is_self_vref(buf[i], id)) print buf[i]
      }
      for (i = last_m + 1; i <= nbuf; i++) print_unless_self(buf[i], id)
    } else {
      for (i = 2; i <= nbuf; i++) print_unless_self(buf[i], id)
    }
  }

  function flush_turn() {
    if (turn == 0) return
    if (turn in oid) emit_overlay()
    else emit_copy()
    nbuf = 0
  }

  is_heading($0) {
    flush_turn()
    turn++
    nbuf = 0
    buf[++nbuf] = $0
    next
  }

  turn == 0 { print; next }

  { buf[++nbuf] = $0 }

  END { flush_turn() }
' "$MAIN" >"$OUT"; then
  echo "reapply-overlay: apply failed: $SID_DIR" >&2
  exit 1
fi

mv -f "$OUT" "$MAIN" || exit 1
OUT=""
exit 0
