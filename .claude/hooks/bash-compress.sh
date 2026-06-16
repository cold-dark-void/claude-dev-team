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

# Wrap the original command inline — no external script call.
# Captures output, preserves exit code, truncates if > 50 lines.
# Use `$( ( $COMMAND ) 2>&1 )` (space after `$(`) so this is unambiguously a
# command substitution containing a subshell — NOT `$(( ... ))` arithmetic
# expansion, which would misparse commands that begin with '(' or contain
# arithmetic-looking text. The later `$((_ccn - 40))` IS real arithmetic.
# NOTE: permissionDecision:"allow" re-grant below applies ONLY to commands the
# hardcoded NOISY test/build allowlist already matched — bounded exposure.
WRAPPED="_ccout=\$( ( $COMMAND ) 2>&1 ); _ccexit=\$?; _ccf=\$(mktemp); printf '%s\n' \"\$_ccout\" > \"\$_ccf\"; _ccn=\$(awk 'END{print NR}' \"\$_ccf\"); if [ \"\$_ccn\" -le 50 ]; then cat \"\$_ccf\"; else head -20 \"\$_ccf\"; printf '\n... %d lines omitted ...\n\n' \"\$((_ccn - 40))\"; tail -20 \"\$_ccf\"; fi; rm -f \"\$_ccf\"; exit \$_ccexit"

jq -n --arg cmd "$WRAPPED" \
  '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow","permissionDecisionReason":"output compression","updatedInput":{"command":$cmd}}}'
