#!/usr/bin/env bash
# transcript-mirror POC (CDT-219, Option A) — Stop-hook recorder.
#
# Mirrors the session's meaning channel (user + assistant text) to
#   ${TRANSCRIPT_MIRROR_ROOT:-$HOME/.claude/transcript}/<session-id>/main.md
# routing noise losslessly to channel sidecars (frozen taxonomy):
#   thinking/L<n>.txt  tool_result/L<n>[-call].txt  injection/L<n>.txt
# referenced from main.md as @refs relative to the sid dir.
#
# Contract (fail-open): always exit 0; never block a turn; atomic append;
# line-count cursor advances only after a successful append (POC: line
# cursor; v1 goes uuid). Subagent Stop no-ops. bash + jq only.
#
# Register as a SECOND entry in hooks.Stop[] (coexist with stop-review.sh):
#   { "type": "command",
#     "command": "bash /home/malcolm/vibes/claude-dev-team/tools/transcript-mirror-poc.sh",
#     "timeout": 10 }
#
# Manual/backstop mode (no stdin JSON):
#   transcript-mirror-poc.sh --transcript <file.jsonl> --sid <session-id>

set -uo pipefail

ROOT="${TRANSCRIPT_MIRROR_ROOT:-$HOME/.claude/transcript}"
ERRLOG="$ROOT/.errors.log"

log_err() { mkdir -p "$ROOT" 2>/dev/null; printf '%s %s\n' "$(date -Is)" "$*" >> "$ERRLOG" 2>/dev/null; }

main() {
  local SID="" TP="" STDIN="" EVENT="" REASON="" AGENT="" CWD=""

  # --- input: manual flags or hook stdin (both casings) -------------------
  if [ "${1:-}" = "--transcript" ]; then
    TP="${2:?}"; shift 2
    [ "${1:-}" = "--sid" ] && SID="${2:?}"
  else
    STDIN=$(cat 2>/dev/null || true)
    if [ -n "$STDIN" ]; then
      EVENT=$(jq -r '.hook_event_name // .hookEventName // empty' <<<"$STDIN" 2>/dev/null)
      SID=$(jq -r '.session_id // .sessionId // empty' <<<"$STDIN" 2>/dev/null)
      TP=$(jq -r '.transcript_path // .transcriptPath // empty' <<<"$STDIN" 2>/dev/null)
      CWD=$(jq -r '.cwd // empty' <<<"$STDIN" 2>/dev/null)
      REASON=$(jq -r '.reason // empty' <<<"$STDIN" 2>/dev/null)
      AGENT=$(jq -r '.agent_id // .agentId // .agent_type // .agentType // empty' <<<"$STDIN" 2>/dev/null)
    fi
    # subagent / non-turn guards
    [ "$EVENT" = "SubagentStop" ] && return 0
    [ -n "$AGENT" ] && return 0
    case "$REASON" in ""|end_turn|channel_closed|shutdown) ;; *) return 0 ;; esac
    # Grok: no transcript_path — reconstruct from sessionId + cwd bucket
    if [ -z "$TP" ]; then
      SID="${SID:-${GROK_SESSION_ID:-}}"
      [ -n "$SID" ] || return 0
      local base enc
      base="${GROK_SESSIONS_DIR:-$HOME/.grok/sessions}"
      enc=$(jq -rn --arg s "${CWD:-$PWD}" '$s|@uri')
      TP="$base/$enc/$SID/chat_history.jsonl"   # long-cwd bucket: CDT-218 (cron covers)
    fi
  fi
  # Grok hands transcript_path = updates.jsonl (JSON-RPC envelopes, no .type).
  # The conversation lives in sibling chat_history.jsonl — prefer it.
  case "$TP" in
    *updates.jsonl)
      [ -f "$(dirname "$TP")/chat_history.jsonl" ] && TP="$(dirname "$TP")/chat_history.jsonl" ;;
  esac
  [ -n "$SID" ] || SID=$(basename "${TP%.jsonl}")
  [ -f "$TP" ] || { log_err "no transcript: sid=$SID tp=$TP"; return 0; }

  local DIR="$ROOT/$SID"
  mkdir -p "$DIR/thinking" "$DIR/tool_result" "$DIR/injection" || { log_err "mkdir failed: $DIR"; return 0; }
  [ -f "$DIR/meta" ] || printf 'source: %s\nstarted_mirror: %s\n' "$TP" "$(date -Is)" > "$DIR/meta"

  # Cursor is keyed to the source file: "<count>\t<path>". A different path
  # (e.g. updates.jsonl -> chat_history.jsonl fix, or legacy count-only
  # cursor) resets to 0 so the mirror re-syncs from the right file.
  local CUR=0 TOTAL CUR_SRC=""
  if [ -f "$DIR/.cursor" ]; then
    IFS=$'\t' read -r CUR CUR_SRC < "$DIR/.cursor" || true
  fi
  case "$CUR" in ''|*[!0-9]*) CUR=0 ;; esac
  [ "$CUR_SRC" = "$TP" ] || CUR=0
  TOTAL=$(wc -l < "$TP")
  [ "$TOTAL" -le "$CUR" ] && return 0

  local WORK; WORK=$(mktemp -d "${TMPDIR:-/tmp}/tmirror.XXXXXX") || { log_err "mktemp failed"; return 0; }
  # shellcheck disable=SC2064
  trap "rm -rf '$WORK'" RETURN

  local JQ_COMMON='
    def pad: ("00000" + tostring)[-6:];
    def textof(c): if (c|type)=="string" then c
      else ([c[]? | select(type=="object" and .type=="text") | .text] | join("\n\n")) end;
    def cleanuser(t): t
      | gsub("(?s)<system-reminder>.*?</system-reminder>"; "")
      | gsub("(?s)<command-(message|name|args)>.*?</command-(message|name|args)>"; "")
      | gsub("</?user_query>"; "")
      | gsub("\n{3,}"; "\n\n") | sub("^\\s+"; "") | sub("\\s+$"; "");
    def injparts(t): [t | scan("(?s)<system-reminder>.*?</system-reminder>|(?s)<command-(?:message|name|args)>.*?</command-(?:message|name|args)>")];
    def blocks(c; k): [c | if type=="array" then .[] | select(type=="object" and .type==k) else empty end];
  '

  # --- phase 1: main.md tick content (meaning channel + @refs) ------------
  tail -n +"$((CUR + 1))" "$TP" | jq -R -r --argjson off "$CUR" "$JQ_COMMON"'
    [., input_line_number] as [$raw, $rel]
    | ($raw | try fromjson catch empty) as $m
    | (($off + $rel) | pad) as $ln
    | select($m.type? == "user" or $m.type? == "assistant")
    | ($m.message.content // $m.content // "") as $c
    | if $m.isMeta == true or ($m.type == "user" and $m.synthetic_reason? != null) then empty
      elif $m.type == "user" then
        (textof($c)) as $t | (cleanuser($t)) as $clean
        | (blocks($c; "tool_result") | length > 0) as $htr
        | (injparts($t) | length > 0) as $hinj
        | ( (if $htr then "> @tool_result/L\($ln).txt\n" else "" end)
          + (if ($clean|length) > 0 then
               "\n## user (L\($ln))\n"
               + (if $hinj then "> @injection/L\($ln).txt\n" else "" end)
               + "\n" + $clean + "\n"
             else "" end) )
      else
        (textof($c)) as $t
        | (blocks($c; "thinking") | length > 0) as $hth
        | (((blocks($c; "tool_use") | map(.name))
            + [$m.tool_calls[]? | .function.name // .name // "tool"]) | unique) as $tools
        | ( (if ($t|length) > 0 then
               "\n## assistant (L\($ln))\n"
               + (if $hth then "> @thinking/L\($ln).txt\n" else "" end)
               + "\n" + $t + "\n"
             elif $hth then "> @thinking/L\($ln).txt\n" else "" end)
          + (if ($tools|length) > 0 then "> @tool_result/L\($ln)-call.txt (\($tools|join(",")))\n" else "" end) )
      end
    | select(length > 0)
  ' > "$WORK/main.part" 2>>"$ERRLOG" || { log_err "jq phase1 failed: sid=$SID"; return 0; }

  # --- phase 2: sidecar records "<relpath>\t<base64>" ---------------------
  tail -n +"$((CUR + 1))" "$TP" | jq -R -r --argjson off "$CUR" "$JQ_COMMON"'
    [., input_line_number] as [$raw, $rel]
    | ($raw | try fromjson catch empty) as $m
    | (($off + $rel) | pad) as $ln
    | select($m.type? == "user" or $m.type? == "assistant"
             or $m.type? == "tool_result" or $m.type? == "reasoning" or $m.type? == "system")
    | ($m.message.content // $m.content // "") as $c
    | if $m.isMeta == true or $m.type == "system"
         or ($m.type == "user" and $m.synthetic_reason? != null) then
        "injection/L\($ln).txt\t\(textof($c) | @base64)"
      elif $m.type == "tool_result" then
        "tool_result/L\($ln).txt\t\($c | tostring | @base64)"
      elif $m.type == "reasoning" then
        "thinking/L\($ln).txt\t\((($m.summary // "(encrypted reasoning, no plaintext)") | tostring) | @base64)"
      elif $m.type == "user" then
        (textof($c)) as $t
        | ( (blocks($c; "tool_result")) as $tr
            | if ($tr|length) > 0 then "tool_result/L\($ln).txt\t\($tr | tostring | @base64)" else empty end ),
          ( (injparts($t)) as $inj
            | if ($inj|length) > 0 then "injection/L\($ln).txt\t\($inj | join("\n\n") | @base64)" else empty end )
      else
        ( (blocks($c; "thinking")) as $th
          | if ($th|length) > 0 then
              "thinking/L\($ln).txt\t\([$th[] | .thinking // "(signature-only, no plaintext)"] | join("\n\n") | @base64)"
            else empty end ),
        ( ((blocks($c; "tool_use")) + ($m.tool_calls // [])) as $tu
          | if ($tu|length) > 0 then "tool_result/L\($ln)-call.txt\t\($tu | tostring | @base64)" else empty end )
      end
  ' 2>>"$ERRLOG" | while IFS=$'\t' read -r rel b64; do
    [ -n "$rel" ] || continue
    printf '%s' "$b64" | base64 -d > "$DIR/$rel" 2>>"$ERRLOG" || log_err "sidecar write failed: $rel"
  done

  # --- atomic-ish append, then cursor -------------------------------------
  if [ -s "$WORK/main.part" ]; then
    [ -f "$DIR/main.md" ] || printf '# transcript mirror — %s\n' "$SID" > "$DIR/main.md"
    cat "$WORK/main.part" >> "$DIR/main.md" || { log_err "append failed: sid=$SID"; return 0; }
  fi
  printf '%s\t%s\n' "$TOTAL" "$TP" > "$DIR/.cursor.tmp" && mv "$DIR/.cursor.tmp" "$DIR/.cursor"
  return 0
}

main "$@" || log_err "unexpected failure rc=$?"
exit 0
