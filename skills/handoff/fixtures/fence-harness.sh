#!/usr/bin/env bash
# fence-harness.sh — shared stub-plugin-root harness for the folded /handoff
# Step 1 fence (SPEC-018 M19.11; CDT-266/W1-27 T2). Sourced by
# detached-stub-test.sh and light-gates-test.sh. Not a standalone test — has
# no PASS/FAIL of its own.
#
# The Step 1 fence now runs parse -> discover -> resolve-root -> cache-check
# -> prepare end to end (DD1). Testing it means running it against a stub
# plugin root, not sourcing a parse-only prefix. This file is that one shared
# harness; do not copy its logic into an individual test.
#
# Public API (call after ROOT and a private WORK=$(mktemp -d ...) are set):
#   harness_init                        - build $WORK/plug; export
#                                          CLAUDE_PLUGIN_ROOT + HARNESS_WORK
#   harness_extract_fence <cmd.md> <out-file>
#                                        - copy the sole ```bash fence under
#                                          "## Step 1: Parse arguments"
#   harness_run <fence-file> <args> [miner-model]
#                                        - emulate the host's literal
#                                          $ARGUMENTS text substitution (DD2),
#                                          run the result as a fresh `bash`
#                                          process (isolated from the test's
#                                          own shell state)
#                                        - hermetic (SPEC-030 R16): runs under
#                                          TMPDIR=$WORK/tmp (so mktemp output
#                                          is cleaned up with $WORK) and
#                                          `env -u` strips HANDOFF_FULL,
#                                          HANDOFF_LIGHT, HANDOFF_MINER_MODEL,
#                                          HANDOFF_SPINE_TOKENS,
#                                          SKIP_ANNOTATION, LIGHT from the
#                                          child so an operator's exported
#                                          env can't leak into a run; pass
#                                          miner-model to explicitly export
#                                          HANDOFF_MINER_MODEL after the
#                                          strip (simulates an operator's
#                                          pre-set env for precedence tests)
#                                          (a non-empty string only —
#                                          miner-model cannot express
#                                          "set to empty string")
#                                        - sets $HARNESS_RC; writes
#                                          $WORK/run.out and $WORK/run.err
#
# Stub contract (DD3):
#   discover-warm.sh  - prints a fixed SESSION_ID + TRANSCRIPT (an existing,
#                        empty file); records its name in $WORK/calls
#   resolve-root.sh   - prints PROJECT_DIR/MROOT/HANDOFF_DIR under
#                        $WORK/target; records its name in $WORK/calls
#   prepass.sh cache-check  - always exit 10 (cache MISS); records call
#   prepass.sh prepare      - writes a fixed plan.json (mode=direct,
#                        stats.since_leaf_applied=false, stats.est_tokens
#                        =15000, spine=<path>) to --out; records call
#   plan-fields.py    - the REAL implementation (copied, not stubbed)
#   SKILL.md / LIGHT.md - empty files (existence only; direct path never
#                        Reads them)
#
# CLAUDE_PLUGIN_ROOT tier-0 in both the fence's own PDH stanza and the copied
# plugin-dir.sh's resolve() short-circuits to $WORK/plug — no dependence on
# cwd or git-common-dir, so this works from any directory.

harness_init() {
  : "${WORK:?harness_init requires WORK to be set}"
  : "${ROOT:?harness_init requires ROOT to be set}"
  PLUG="$WORK/plug"
  mkdir -p "$PLUG/skills/handoff" "$WORK/target/.claude/handoff" "$WORK/tmp"
  cp "$ROOT/skills/plugin-dir.sh" "$PLUG/skills/plugin-dir.sh"
  cp "$ROOT/skills/handoff/plan-fields.py" "$PLUG/skills/handoff/plan-fields.py"
  chmod +x "$PLUG/skills/plugin-dir.sh"
  : >"$PLUG/skills/handoff/SKILL.md"
  : >"$PLUG/skills/handoff/LIGHT.md"
  : >"$WORK/calls"
  : >"$WORK/transcript.jsonl"

  cat >"$PLUG/skills/handoff/discover-warm.sh" <<'HARNESS_DISCOVER'
#!/usr/bin/env bash
set -eu
echo discover-warm.sh >> "$HARNESS_WORK/calls"
printf '%s\n' "harness-warm-session-id"
printf '%s\n' "$HARNESS_WORK/transcript.jsonl"
HARNESS_DISCOVER

  cat >"$PLUG/skills/handoff/resolve-root.sh" <<'HARNESS_RESOLVE'
#!/usr/bin/env bash
set -eu
echo resolve-root.sh >> "$HARNESS_WORK/calls"
printf '%s\n' "$HARNESS_WORK/target"
printf '%s\n' "$HARNESS_WORK/target"
printf '%s\n' "$HARNESS_WORK/target/.claude/handoff"
HARNESS_RESOLVE

  cat >"$PLUG/skills/handoff/prepass.sh" <<'HARNESS_PREPASS'
#!/usr/bin/env bash
set -eu
echo "prepass.sh ${1:-}" >> "$HARNESS_WORK/calls"
case "${1:-}" in
  cache-check)
    exit 10 ;;
  prepare)
    shift
    OUT=""
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --out) OUT="$2"; shift 2 ;;
        *) shift ;;
      esac
    done
    [ -n "$OUT" ] || { echo "prepass stub: missing --out" >&2; exit 1; }
    cp "$HARNESS_WORK/plug/fixture-plan.json" "$OUT"
    exit 0 ;;
  *)
    echo "prepass stub: unknown subcommand ${1:-}" >&2
    exit 1 ;;
esac
HARNESS_PREPASS

  chmod +x "$PLUG/skills/handoff/discover-warm.sh" \
           "$PLUG/skills/handoff/resolve-root.sh" \
           "$PLUG/skills/handoff/prepass.sh"

  cat >"$PLUG/fixture-plan.json" <<'HARNESS_PLAN'
{"mode":"direct","stats":{"since_leaf_applied":false,"est_tokens":15000},"spine":"HARNESS_SPINE_PATH"}
HARNESS_PLAN
  : >"$PLUG/stub.spine.txt"
  sed -i "s#HARNESS_SPINE_PATH#$PLUG/stub.spine.txt#" "$PLUG/fixture-plan.json"

  export HARNESS_WORK="$WORK"
  export CLAUDE_PLUGIN_ROOT="$PLUG"
}

# harness_extract_fence <src.md> <out-file> — sole ```bash fence under
# "## Step 1: Parse arguments" (same awk program as light-static-test.sh extract_step1_fence).
harness_extract_fence() {
  local src="$1" out="$2"
  awk '
    /^## Step 1: Parse arguments/ { want=1; next }
    want && /^```bash[[:space:]]*$/ { on=1; next }
    on && /^```[[:space:]]*$/ { exit }
    on { print }
  ' "$src" >"$out"
}

# harness_run <fence-file> <args> [miner-model] — DD2/DD3: emulate the host's
# literal $ARGUMENTS substitution, then run as a fresh bash process (not
# sourced). Hermetic (SPEC-030 R16): TMPDIR is confined to $WORK/tmp and the
# handoff-specific env vars are stripped before the run so nothing leaks into
# the caller's real TMPDIR and no operator-exported var can leak in; pass
# miner-model to re-export HANDOFF_MINER_MODEL after the strip (env-precedence
# tests). Sets $HARNESS_RC; writes $WORK/run.out and $WORK/run.err.
harness_run() {
  local fence_file="$1" args="$2" miner="${3-}" fence
  fence=$(cat "$fence_file")
  fence=${fence//\$ARGUMENTS/$args}
  printf '%s\n' "$fence" >"$WORK/run.sh"
  mkdir -p "$WORK/tmp"
  set +e
  local -a envargs=(-u HANDOFF_FULL -u HANDOFF_LIGHT -u HANDOFF_MINER_MODEL -u HANDOFF_SPINE_TOKENS -u SKIP_ANNOTATION -u LIGHT)
  # NOTE: can only re-export a non-empty miner model; cannot express "set to
  # empty string" via this array (an empty $miner is treated as unset).
  [ -n "$miner" ] && envargs+=(HANDOFF_MINER_MODEL="$miner")
  TMPDIR="$WORK/tmp" env "${envargs[@]}" bash "$WORK/run.sh" >"$WORK/run.out" 2>"$WORK/run.err"
  HARNESS_RC=$?
  set -e
}
