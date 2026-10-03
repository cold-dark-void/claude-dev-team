#!/usr/bin/env bash
# transcript-mirror/test-lib.sh — shared transcript-store test helpers
# (CDT-293 [04 E6]). One canonical copy of the store-planting block that was
# copy-pasted (and drifting: two different last_ident implementations) across
# summarize-transcript-test.sh and compact-transcript-test.sh.
#
# Source-only, like tests/lib/*.sh: sourcing has zero side effects. The
# caller MUST have, before the first call:
#   $STORE               — the mirror store root (TRANSCRIPT_MIRROR_ROOT)
#   $CLAUDE_PROJECTS_DIR — exported fake Claude projects dir
#   $ENC_CLAUDE          — cwd-encoded project dir name
#   $REPO                — repo root (mirrorlib import path)
# and must have sourced tests/lib/mtimes.sh (touch_ago) and
# skills/lib/portable.sh (portable_sha256).
# bash 3.2 (no declare -A / mapfile).

age() { touch_ago "$1" 120; }

sha_file() { portable_sha256 "$1"; }

# last_ident — the REAL identity logic (mirrorlib.record_ident), not a
# hand-copied jq/awk clone (CDT-293: tests exercise the command's code).
last_ident() {
  python3 - "$1" "$REPO/skills/transcript-mirror" <<'PY'
import sys
sys.path.insert(0, sys.argv[2])
from mirrorlib import record_ident
ident = ""
with open(sys.argv[1], encoding="utf-8", errors="replace") as f:
    for line in f:
        i = record_ident(line)
        if i:
            ident = i
print(ident)
PY
}

plant_claude_src() {
  local sid="$1" src="$2"
  local dest="$CLAUDE_PROJECTS_DIR/$ENC_CLAUDE"
  mkdir -p "$dest"
  cp "$src" "$dest/${sid}.jsonl"
  age "$dest/${sid}.jsonl"
  printf '%s\n' "$dest/${sid}.jsonl"
}

write_store() {
  local sid="$1" main="$2" srcpath="$3"
  mkdir -p "$STORE/$sid/tool_result" "$STORE/$sid/agents/w" \
    "$STORE/$sid/thinking" "$STORE/$sid/injection"
  cp "$main" "$STORE/$sid/main.md"
  local ident hash
  ident=$(last_ident "$srcpath")
  hash=$(sha_file "$STORE/$sid/main.md")
  printf '%s\t%s\t%s\n' "$ident" "$srcpath" "$hash" >"$STORE/$sid/cursor"
  printf 'source: %s\nstarted_mirror: 2026-01-01T00:00:00+00:00\n' "$srcpath" >"$STORE/$sid/meta"
}

plant_hit() {
  local sid="$1" src="$2" main="$3"
  local located
  located=$(plant_claude_src "$sid" "$src")
  write_store "$sid" "$main" "$located"
  printf '%s\n' "$located"
}
