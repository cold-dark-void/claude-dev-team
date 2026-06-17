#!/usr/bin/env bash
#
# local-agent/run.sh — offload one mechanical, machine-verifiable task to a
# user-provided local model via the OpenCode CLI, then gate the result on a
# caller-supplied deterministic machine-check. Implements the SPEC-019 PR1
# "scriptable subset" (the leaf primitive the PR2 orchestrator calls).
#
# THIS SCRIPT IS A SUBPROCESS CLI — NEVER SOURCE IT.
#
# Usage:
#   run.sh --worktree <path> --brief <text> --check <shell-expr>
#
#   --worktree <path>   ticket worktree (cwd for the local agent). REQUIRED.
#                       The CALLER resolves this via worktree-lib.sh (SPEC-016);
#                       this script does NOT call worktree-lib.sh itself.
#   --brief <text>      self-contained task brief; the local agent's SOLE
#                       context. REQUIRED. No memory/cortex/DB/credential is
#                       ever appended to the invocation.
#   --check <expr>      deterministic machine-check, run via `bash -c "$CHECK"`
#                       (NOT via the shell builtin that re-parses in-process)
#                       AFTER opencode returns. REQUIRED.
#
# Opt-in:  env LOCAL_AGENT must equal EXACTLY "opencode"; anything else
#          (including unset/empty) ⇒ feature off ⇒ exit 2 (fallback).
#
# Exit codes (exactly three semantic codes; 64 is reserved for bad usage):
#   0  success  — opencode ran AND `bash -c "$CHECK"` passed.
#   1  fail     — opencode ran but the post-check returned non-zero. Any diff
#                 is left in place for the caller to review/discard.
#   2  fallback — flag != "opencode", opencode absent, or liveness probe failed.
#                 The caller MUST treat 2 as "run this task on Claude instead".
#                 A single one-line notice is emitted to stderr.
#  64  usage    — malformed invocation (missing/unknown flag). House style.
#
# Stdout discipline (matching worktree-lib.sh / ci-watch): stdout carries only
# the result payload; ALL diagnostics go to stderr. Stdout is empty on a
# non-zero exit.
#
# Leash (OS filesystem confinement when available; best-effort otherwise):
#   * When `bwrap` (bubblewrap) is present and a pre-flight probe succeeds, the
#     local agent runs inside a bind-mount sandbox: the host root is mounted
#     read-only and the ONLY writable surfaces are the worktree, its git plumbing
#     (--git-dir + --git-common-dir, so commits land), and OpenCode's own XDG
#     state dirs. /dev, /proc, and /tmp are private. This bounds filesystem
#     writes to the worktree + the agent's own state even against an
#     adversarial/misconfigured local model.
#   * Fallback — bwrap absent, LOCAL_AGENT_SANDBOX=0, or probe failure — degrades
#     to the best-effort working-dir leash only (`opencode run --dir <worktree>`),
#     relying on OpenCode's own permission/provider config. A one-line stderr
#     notice marks which path was taken.
#   * NETWORK egress is NOT enforced (no --unshare-net): the sandbox is FS-only.
#     Egress bounding remains OpenCode-config / deferred. Only the opencode call
#     is wrapped; the caller's --check runs UNWRAPPED on the trusted host shell.

set -euo pipefail
# THIS SCRIPT IS A SUBPROCESS CLI — NEVER SOURCE IT.

# ---- Usage ------------------------------------------------------------------
usage() {
  {
    echo "Usage: run.sh --worktree <path> --brief <text> --check <shell-expr>"
    echo ""
    echo "  --worktree <path>  ticket worktree (REQUIRED; caller resolves via worktree-lib.sh)"
    echo "  --brief <text>     self-contained task brief (REQUIRED; sole context)"
    echo "  --check <expr>     machine-check run via 'bash -c' after opencode (REQUIRED)"
    echo ""
    echo "  env LOCAL_AGENT must equal exactly 'opencode' or the wrapper exits 2 (fallback)."
    echo "  exit 0=success  1=check-failed  2=fallback  64=usage"
  } >&2
  exit 64
}

# ---- Argument parsing -------------------------------------------------------
WORKTREE=""
BRIEF=""
CHECK=""
# Track whether each required flag was SET (distinct from "set to empty") so we
# can reject a missing flag without conflating it with an intentionally empty
# value. --check may legitimately be a no-op like ":" but must be present.
HAVE_WORKTREE=0
HAVE_BRIEF=0
HAVE_CHECK=0

while [ $# -gt 0 ]; do
  case "$1" in
    --worktree)
      [ $# -ge 2 ] || { echo "error: --worktree requires a value" >&2; usage; }
      WORKTREE="$2"; HAVE_WORKTREE=1; shift 2 ;;
    --worktree=*)
      WORKTREE="${1#*=}"; HAVE_WORKTREE=1; shift ;;
    --brief)
      [ $# -ge 2 ] || { echo "error: --brief requires a value" >&2; usage; }
      BRIEF="$2"; HAVE_BRIEF=1; shift 2 ;;
    --brief=*)
      BRIEF="${1#*=}"; HAVE_BRIEF=1; shift ;;
    --check)
      [ $# -ge 2 ] || { echo "error: --check requires a value" >&2; usage; }
      CHECK="$2"; HAVE_CHECK=1; shift 2 ;;
    --check=*)
      CHECK="${1#*=}"; HAVE_CHECK=1; shift ;;
    -h|--help)
      usage ;;
    --)
      shift; break ;;
    -*)
      echo "error: unknown flag: $1" >&2; usage ;;
    *)
      echo "error: unexpected positional argument: $1" >&2; usage ;;
  esac
done

# Any extra args after `--` are not part of the contract.
if [ $# -gt 0 ]; then
  echo "error: unexpected trailing arguments: $*" >&2
  usage
fi

[ "$HAVE_WORKTREE" -eq 1 ] || { echo "error: --worktree is required" >&2; usage; }
[ "$HAVE_BRIEF" -eq 1 ]    || { echo "error: --brief is required" >&2; usage; }
[ "$HAVE_CHECK" -eq 1 ]    || { echo "error: --check is required" >&2; usage; }

if [ -z "$WORKTREE" ]; then
  echo "error: --worktree value is empty" >&2; usage
fi
if [ ! -d "$WORKTREE" ]; then
  echo "error: --worktree is not a directory: $WORKTREE" >&2; usage
fi

# ---- Metrics ----------------------------------------------------------------
# Resolve the repo MROOT (git-common-dir parent) so metrics land under the
# top-level repo even when invoked from inside a worktree. JSONL: one record per
# terminal path. Guarded by `command -v jq`; jq absent ⇒ skip silently.
resolve_mroot() {
  local _gc
  if _gc=$(git rev-parse --git-common-dir 2>/dev/null); then
    MROOT=$(cd "$(dirname "$_gc")" && pwd)
  else
    MROOT=$(pwd)
  fi
}

# emit_metric <outcome> <spent_tokens_json>
#   <outcome>             "success" | "fail" | "fallback"
#   <spent_tokens_json>   a JSON value (number or the literal `null`) — the
#                         MEASURED local OpenCode cost, NOT a Claude cost.
# PR1 record: { ts, outcome, exit_code, saved_est_tokens, spent_tokens }.
#   exit_code        derived from outcome (success->0, fail->1, fallback->2).
#   saved_est_tokens estimate of CLAUDE tokens saved — `null` in PR1
#                    (orchestrator-owned, deferred to PR2). Never "unknown".
# `ticket` and `spent_review_escalation` are PR2 additions, not PR1 keys.
# Best-effort and non-fatal: any failure here MUST NOT change the wrapper's exit code.
emit_metric() {
  local outcome="$1" spent="$2"
  command -v jq >/dev/null 2>&1 || return 0

  local code
  case "$outcome" in
    success)  code=0 ;;
    fail)     code=1 ;;
    fallback) code=2 ;;
    *)        code=0 ;;
  esac

  resolve_mroot
  local dir="$MROOT/.claude/local-agent"
  local file="$dir/metrics.jsonl"
  mkdir -p "$dir" 2>/dev/null || return 0

  local ts; ts=$(date +%s)
  # --argjson for ts/exit_code/spent so they serialize as JSON numbers/null.
  jq -cn \
    --argjson ts "$ts" \
    --arg outcome "$outcome" \
    --argjson exit_code "$code" \
    --argjson spent "$spent" \
    '{ts: $ts, outcome: $outcome, exit_code: $exit_code, saved_est_tokens: null, spent_tokens: $spent}' \
    >> "$file" 2>/dev/null || return 0
}

# ---- Flag gate --------------------------------------------------------------
# Feature is opt-in and OFF by default. Must equal EXACTLY "opencode".
if [ "${LOCAL_AGENT:-}" != "opencode" ]; then
  echo "local-agent: LOCAL_AGENT != 'opencode' — falling back to Claude executor." >&2
  emit_metric "fallback" "null"
  exit 2
fi

# ---- Preflight --------------------------------------------------------------
# (1) opencode present on PATH, (2) fast liveness probe `opencode --version`.
# Either failing ⇒ fallback (exit 2) with one stderr notice.
if ! command -v opencode >/dev/null 2>&1; then
  echo "local-agent: 'opencode' not found on PATH — falling back to Claude executor." >&2
  emit_metric "fallback" "null"
  exit 2
fi
if ! opencode --version >/dev/null 2>&1; then
  echo "local-agent: 'opencode --version' liveness probe failed — falling back to Claude executor." >&2
  emit_metric "fallback" "null"
  exit 2
fi

# ---- OS leash (bubblewrap FS confinement) -----------------------------------
# Populate the global SANDBOX=() argv prefix wrapping ONLY the opencode call.
# Empty array ⇒ unwrapped (today's best-effort --dir behavior). Disabled by
# LOCAL_AGENT_SANDBOX=0, by bwrap being absent, or by a failed pre-flight probe;
# each path emits ONE stderr notice. NOT OS-enforced for network (FS-only).
SANDBOX=()
build_sandbox() {
  # Opt-out: default (unset/"1") = on-if-available; "0" = explicitly disabled.
  if [ "${LOCAL_AGENT_SANDBOX:-1}" = "0" ]; then
    echo "local-agent: OS leash disabled (LOCAL_AGENT_SANDBOX=0) — best-effort --dir only." >&2
    return 0
  fi
  if ! command -v bwrap >/dev/null 2>&1; then
    echo "local-agent: bwrap not found — best-effort --dir only." >&2
    return 0
  fi

  # OpenCode XDG state dirs (created on demand by opencode; --bind-try tolerates
  # absence, so we bind unconditionally rather than pre-creating them).
  local cfg="${XDG_CONFIG_HOME:-$HOME/.config}/opencode"
  local data="${XDG_DATA_HOME:-$HOME/.local/share}/opencode"
  local cache="${XDG_CACHE_HOME:-$HOME/.cache}/opencode"
  local state="${XDG_STATE_HOME:-$HOME/.local/state}/opencode"

  # Git plumbing as ABSOLUTE paths so commits inside the worktree succeed even
  # when .git is a gitfile pointing elsewhere (linked worktree) or commondir is
  # outside the worktree. realpath canonicalizes; empty ⇒ skip its bind.
  local gitdir commondir
  gitdir=$(git -C "$WORKTREE" rev-parse --git-dir 2>/dev/null) \
    && gitdir=$(realpath "$gitdir" 2>/dev/null) || gitdir=""
  commondir=$(git -C "$WORKTREE" rev-parse --git-common-dir 2>/dev/null) \
    && commondir=$(realpath "$commondir" 2>/dev/null) || commondir=""

  # Candidate argv: host root read-only; private /dev /proc /tmp; the worktree
  # and the agent's own state/git plumbing read-write. No --unshare-net.
  local cand=(
    bwrap
    --ro-bind / /
    --dev /dev
    --proc /proc
    --tmpfs /tmp
    --bind "$WORKTREE" "$WORKTREE"
    --bind-try "$cfg"   "$cfg"
    --bind-try "$data"  "$data"
    --bind-try "$cache" "$cache"
    --bind-try "$state" "$state"
  )
  [ -n "$gitdir" ]    && cand+=( --bind-try "$gitdir"    "$gitdir" )
  [ -n "$commondir" ] && cand+=( --bind-try "$commondir" "$commondir" )

  # Pre-flight probe: if bwrap can't construct the namespace here (e.g. no
  # user-namespaces, restrictive container), degrade rather than fail — do NOT
  # exit 2 and do NOT burn an opencode retry.
  if ! "${cand[@]}" -- true >/dev/null 2>&1; then
    echo "local-agent: bwrap probe failed — degrading to best-effort --dir." >&2
    return 0
  fi
  SANDBOX=( "${cand[@]}" )
}
build_sandbox

# ---- Invoke the local agent -------------------------------------------------
# `opencode run --dir <worktree> "<brief>"` — brief is the single positional
# argument. Nothing else (no memory DB path, cortex file, or credential) is
# appended: the brief is the local agent's SOLE context (SPEC-019).
#
# When SANDBOX is non-empty the call is bwrap-wrapped (FS confinement above);
# the ${SANDBOX[@]+...} guard keeps an EMPTY array safe under `set -u`.
#
# Run under `set +e` so a non-zero opencode exit does not abort the wrapper via
# `set -e` before we record metrics. Diagnostics from opencode go to stderr;
# any stdout it produces is forwarded to our stderr to keep our own stdout clean
# (the result payload, if any, is the machine-check outcome — not opencode's
# chatter).
set +e
${SANDBOX[@]+"${SANDBOX[@]}"} opencode run --dir "$WORKTREE" "$BRIEF" >&2
OC_RC=$?
set -e

if [ "$OC_RC" -ne 0 ]; then
  # opencode itself errored before any verifiable change. Treat as a failed
  # attempt (machine-check could not meaningfully pass), exit 1.
  echo "local-agent: 'opencode run' exited $OC_RC — treating as machine-check failure." >&2
  emit_metric "fail" "null"
  exit 1
fi

# ---- Machine-check ----------------------------------------------------------
# Run the caller's deterministic check via `bash -c "$CHECK"` in a child shell —
# never the in-process builtin that would re-parse the string in our own scope.
# Exit 0 ⇒ pass ⇒ wrapper exit 0; non-zero ⇒ fail ⇒ wrapper exit 1.
set +e
bash -c "$CHECK" >&2
CHECK_RC=$?
set -e

if [ "$CHECK_RC" -eq 0 ]; then
  emit_metric "success" "null"
  exit 0
fi

echo "local-agent: machine-check failed (exit $CHECK_RC) — diff left in place for caller review." >&2
emit_metric "fail" "null"
exit 1
