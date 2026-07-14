#!/usr/bin/env bash
# PreToolUse hook — compresses output of noisy Bash commands inline.
# Inlines the compression logic so no wrapper script is invoked (avoids
# permission re-checks on the rewritten command in CC 2.1.116+).

TMPF="${TMPDIR:-/tmp}/bcompress-$$"
cat > "$TMPF"

TOOL_NAME=$(jq -r '.tool_name // empty' "$TMPF" 2>/dev/null)
[ "$TOOL_NAME" = "Bash" ] || { rm -f "$TMPF"; exit 0; }

COMMAND=$(jq -r '.tool_input.command // empty' "$TMPF" 2>/dev/null)
rm -f "$TMPF"
[ -z "$COMMAND" ] && exit 0

NOISY=false
case "$COMMAND" in
  npm\ test*|npx\ jest*|npx\ vitest*|yarn\ test*|pnpm\ test*) NOISY=true ;;
  pytest*|python\ -m\ pytest*) NOISY=true ;;
  go\ test*) NOISY=true ;;
  cargo\ test*) NOISY=true ;;
  mvn\ test*|gradle\ test*) NOISY=true ;;
  npm\ run\ build*|yarn\ build*|pnpm\ build*) NOISY=true ;;
  cargo\ build*) NOISY=true ;;
  make\ *|make) NOISY=true ;;
  tsc\ *|tsc) NOISY=true ;;
esac

[ "$NOISY" = "false" ] && exit 0

# Wrap via bash -c with the original command as a single %q-quoted argument so
# an inline `#` comment (e.g. `go test ./... # note`) cannot comment out the
# wrapper's closing `)`. printf %q expands at hook time into WRAPPED.
# Use `$( ( ... ) 2>&1 )` (space after `$(`) so this is unambiguously a
# command substitution containing a subshell — NOT `$(( ... ))` arithmetic
# expansion. The later `$((_ccn - 40))` IS real arithmetic.
# NOTE: permissionDecision:"allow" re-grant below applies ONLY to commands the
# hardcoded NOISY test/build allowlist already matched — bounded exposure.
_CMD_Q=$(printf '%q' "$COMMAND")
WRAPPED="_ccout=\$( ( bash -c ${_CMD_Q} ) 2>&1 ); _ccexit=\$?; _ccf=\$(mktemp); printf '%s\n' \"\$_ccout\" > \"\$_ccf\"; _ccn=\$(awk 'END{print NR}' \"\$_ccf\"); if [ \"\$_ccn\" -le 50 ]; then cat \"\$_ccf\"; else head -20 \"\$_ccf\"; printf '\n... %d lines omitted ...\n\n' \"\$((_ccn - 40))\"; tail -20 \"\$_ccf\"; fi; rm -f \"\$_ccf\"; exit \$_ccexit"

jq -n --arg cmd "$WRAPPED" \
  '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow","permissionDecisionReason":"output compression","updatedInput":{"command":$cmd}}}'
