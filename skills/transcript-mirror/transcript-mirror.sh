#!/usr/bin/env bash
# transcript-mirror.sh — Stop/SessionEnd recorder (SPEC-036 M2–M9).
# Opt-in SubagentStop / --agent writes <sid>/agents/<id>/ (M4a).
# Parent nest-refs: ensure_nest_refs after parent write / nest tick if parent main.md exists.
# Meaning channel → main.md; channel sidecars: thinking/ tool_result/ injection/.
# bash + jq only. Fail-open: always exit 0; never decision:block.
# Manual: transcript-mirror.sh --transcript FILE --sid SID [--agent ID]
set -uo pipefail

ROOT="${TRANSCRIPT_MIRROR_ROOT:-$HOME/.claude/transcript}"
ERRLOG="$ROOT/.errors.log"

log_err() {
  mkdir -p "$ROOT" 2>/dev/null || true
  printf '%s %s\n' "$(date -Is 2>/dev/null || date)" "$*" >> "$ERRLOG" 2>/dev/null || true
}

# Nest dir name from agent_id // agentId only (M4a AC2c). Prints id or empty (reject).
sanitize_agent_id() {
  local raw="${1:-}" out=""
  out=$(printf '%s' "$raw" | tr -c 'A-Za-z0-9._-' '_' | cut -c1-64)
  case "$out" in
    ''|'.'|'..') printf '' ;;
    .*) printf '' ;;
    *..*) printf '' ;;
    */*) printf '' ;;
    *) printf '%s' "$out" ;;
  esac
}

# Identity of one JSONL record: non-null string .uuid, else h:+SHA-256(jq -S -c).
# Always prints one line so ident file rows match source rows.
ident_line() {
  local line="$1" uuid="" hash=""
  if [ -z "$line" ]; then
    printf '\n'
    return 0
  fi
  uuid=$(printf '%s\n' "$line" | jq -r 'if (.uuid | type == "string" and length > 0) then .uuid else empty end' 2>/dev/null) || uuid=""
  if [ -n "$uuid" ]; then
    printf '%s\n' "$uuid"
    return 0
  fi
  hash=$(printf '%s\n' "$line" | jq -S -c . 2>/dev/null | sha256sum | awk '{print $1}') || hash=""
  if [ -n "$hash" ]; then
    printf 'h:%s\n' "$hash"
  else
    printf '\n'
  fi
}

index_idents() {
  local src="$1" dest="$2" line
  : > "$dest"
  while IFS= read -r line || [ -n "$line" ]; do
    ident_line "$line" >> "$dest"
  done < "$src"
}

sha_file() {
  [ -f "$1" ] && sha256sum "$1" | awk '{print $1}'
}

write_cursor() {
  local dest="$1" ident="$2" path="$3" mainf="$4" h=""
  [ -n "$ident" ] || return 0
  h=$(sha_file "$mainf")
  printf '%s\t%s\t%s\n' "$ident" "$path" "$h" > "$dest/cursor.tmp" && mv "$dest/cursor.tmp" "$dest/cursor"
}

# Consecutive @tool_result-only lines → keep first (M8). Blanks do not break a run
# and are dropped while the run is open (match drop_leading_tr on append).
collapse_tr() {
  awk '
    /^> @tool_result\// { if (tr) next; tr=1; print; next }
    /^[ \t]*$/ { if (tr) next; print; next }
    { tr=0; print }
  '
}

drop_leading_tr() {
  awk '
    BEGIN { skip=1 }
    skip && (/^> @tool_result\// || /^[ \t]*$/) { next }
    { skip=0; print }
  '
}

last_nonblank() {
  awk 'NF { l=$0 } END { print l }' "$1" 2>/dev/null
}

JQ_COMMON='
  def pad: ("00000" + tostring)[-6:];
  def textof(c): if (c|type)=="string" then c
    else ([c[]? | select(type=="object" and .type=="text") | .text] | join("\n\n")) end;
  def cleanuser(t): t
    | gsub("(?s)<system-reminder>.*?</system-reminder>"; "")
    | gsub("(?s)<command-(message|name|args)>.*?</command-(message|name|args)>"; "")
    | gsub("</?user_query>"; "")
    | gsub("\n{3,}"; "\n\n") | sub("^\\s+"; "") | sub("\\s+$"; "");
  def injparts(t): [t | scan("(?s)<system-reminder>.*?</system-reminder>|(?s)<command-(?:message|name|args)>.*?</command-(?:message|name|args)>|(?s)<user_query>.*?</user_query>")];
  def blocks(c; k): [c | if type=="array" then .[] | select(type=="object" and .type==k) else empty end];
  def thinktext(th):
    [th[] | if ((.thinking | type)=="string" and (.thinking|length)>0) then .thinking
            else "(signature-only, no plaintext)" end] | join("\n\n");
  def reasontext(m):
    (if (m.summary | type)=="string" and (m.summary|length)>0 then m.summary
     elif (m.summary | type)=="array" then
       ([m.summary[]? | if type=="object" then (.text // .summary_text // "") else tostring end] | join("\n\n"))
     else "" end)
    | if length>0 then . else "(encrypted reasoning, no plaintext)" end;
'

# Emit main.md tick + sidecar TSV into DEST. START is 1-based first source line.
# SKIPJSON is a JSON object of stringified line numbers to skip (parent prefix).
# jq/base64 stderr is discarded; callers log_err one line on failure (M4).
emit_tick() {
  local src="$1" dest="$2" start="$3" skipjson="$4"
  local off=$((start - 1)) slice part
  slice="$dest/.slice.jsonl"
  part="$dest/.main.part"
  tail -n +"$start" "$src" > "$slice" || true

  jq -R -r --argjson off "$off" --argjson skip "$skipjson" "$JQ_COMMON"'
    [., input_line_number] as [$raw, $rel]
    | ($raw | try fromjson catch empty) as $m
    | (($off + $rel) | pad) as $ln
    | (($off + $rel) | tostring) as $lns
    | select($skip[$lns] | not)
    | select($m.type? == "user" or $m.type? == "assistant")
    | ($m.message.content // $m.content // "") as $c
    | if $m.isMeta == true or ($m.type == "user" and $m.synthetic_reason != null) then empty
      elif $m.type == "user" then
        (textof($c)) as $t | (cleanuser($t)) as $clean
        | (blocks($c; "tool_result") | length > 0) as $htr
        | (injparts($t) | length > 0) as $hinj
        | ( (if $htr then "> @tool_result/L\($ln).txt\n" else "" end)
          + (if ($clean|length) > 0 then
               "\n## user\n"
               + (if $hinj then "\n> @injection/L\($ln).txt\n" else "" end)
               + "\n" + $clean + "\n"
             else "" end) )
      else
        (textof($c)) as $t
        | (blocks($c; "thinking") | length > 0) as $hth
        | (((blocks($c; "tool_use") | map(.name))
            + [$m.tool_calls[]? | .function.name // .name // "tool"]) | unique) as $tools
        | if ($t|length) > 0 or $hth or ($tools|length) > 0 then
            "\n## assistant\n"
            + (if $hth then "\n> @thinking/L\($ln).txt\n" else "" end)
            + (if ($t|length) > 0 then "\n" + $t + "\n" else "" end)
            + (if ($tools|length) > 0 then "> @tool_result/L\($ln)-call.txt\n" else "" end)
          else empty end
      end
    | select(length > 0)
  ' "$slice" > "$part.raw" 2>/dev/null || return 1

  collapse_tr < "$part.raw" > "$part"

  jq -R -r --argjson off "$off" --argjson skip "$skipjson" "$JQ_COMMON"'
    [., input_line_number] as [$raw, $rel]
    | ($raw | try fromjson catch empty) as $m
    | (($off + $rel) | pad) as $ln
    | (($off + $rel) | tostring) as $lns
    | select($skip[$lns] | not)
    | select($m.type? == "user" or $m.type? == "assistant"
             or $m.type? == "tool_result" or $m.type? == "reasoning" or $m.type? == "system")
    | ($m.message.content // $m.content // "") as $c
    | if $m.isMeta == true or $m.type == "system"
         or ($m.type == "user" and $m.synthetic_reason != null) then
        "injection/L\($ln).txt\t\(textof($c) | @base64)"
      elif $m.type == "tool_result" then
        "tool_result/L\($ln).txt\t\($c | tostring | @base64)"
      elif $m.type == "reasoning" then
        "thinking/L\($ln).txt\t\(reasontext($m) | @base64)"
      elif $m.type == "user" then
        (textof($c)) as $t
        | ( (blocks($c; "tool_result")) as $tr
            | if ($tr|length) > 0 then "tool_result/L\($ln).txt\t\($tr | tostring | @base64)" else empty end ),
          ( (injparts($t)) as $inj
            | if ($inj|length) > 0 then "injection/L\($ln).txt\t\($inj | join("\n\n") | @base64)" else empty end )
      else
        ( (blocks($c; "thinking")) as $th
          | if ($th|length) > 0 then "thinking/L\($ln).txt\t\(thinktext($th) | @base64)" else empty end ),
        ( ((blocks($c; "tool_use")) + ($m.tool_calls // [])) as $tu
          | if ($tu|length) > 0 then "tool_result/L\($ln)-call.txt\t\($tu | tostring | @base64)" else empty end )
      end
  ' "$slice" 2>/dev/null | while IFS=$'\t' read -r rel b64; do
    [ -n "$rel" ] || continue
    printf '%s' "$b64" | base64 -d > "$dest/$rel" 2>/dev/null || log_err "sidecar write failed: $rel"
  done
  return 0
}

ensure_meta() {
  local dir="$1" tp="$2" parent="$3"
  if [ ! -f "$dir/meta" ]; then
    printf 'source: %s\nstarted_mirror: %s\n' "$tp" "$(date -Is 2>/dev/null || date)" > "$dir/meta"
  fi
  if [ -n "$parent" ] && ! grep -q '^parent:' "$dir/meta" 2>/dev/null; then
    printf 'parent: %s\n' "$parent" >> "$dir/meta"
  fi
}

# Exactly one `> @agents/<id>/main.md` per $parent_dir/agents/<id>/main.md (M4a AC3, M7).
# Spawn-adjacent: after the ## assistant block whose Task/Agent tool_use id /
# input.agent_id matches (post M8 collapse). Else trailing; trailing ids lexical.
ensure_nest_refs() {
  local parent_dir="${1:-}"
  local mainf="$parent_dir/main.md"
  [ -n "$parent_dir" ] && [ -f "$mainf" ] || return 0

  if [ ! -d "$parent_dir/agents" ]; then
    grep -Eq '^> @agents/[^/]+/main\.md$' "$mainf" 2>/dev/null || return 0
  fi

  local nref d id src="" ng_was
  if [ -n "${WORK:-}" ] && [ -d "$WORK" ]; then
    nref="$WORK/nref"
    mkdir -p "$nref" || return 0
  else
    nref=$(mktemp -d "${TMPDIR:-/tmp}/tm-nref.XXXXXX") || return 0
  fi

  ng_was=$(shopt -p nullglob)
  shopt -s nullglob
  : > "$nref/ids"
  for d in "$parent_dir/agents"/*/main.md; do
    [ -f "$d" ] || continue
    id=$(basename "$(dirname "$d")")
    case "$id" in
      ''|'.'|'..') continue ;;
      *) printf '%s\n' "$id" ;;
    esac
  done | LC_ALL=C sort -u > "$nref/ids"
  eval "$ng_was"

  awk '$0 ~ /^> @agents\/[^\/]+\/main\.md$/ { next } { print }' "$mainf" > "$nref/stripped" || {
    [ -n "${WORK:-}" ] && [ "$nref" = "$WORK/nref" ] || rm -rf "$nref"
    return 0
  }

  : > "$nref/spawn"
  if [ -s "$nref/ids" ]; then
    if [ -f "$parent_dir/cursor" ]; then
      IFS=$'\t' read -r _ src _ < "$parent_dir/cursor" || true
    fi
    if [ -z "$src" ] || [ ! -f "$src" ]; then
      src=""
      if [ -f "$parent_dir/meta" ]; then
        src=$(sed -n 's/^source: //p' "$parent_dir/meta" | head -1) || src=""
      fi
    fi
    if [ -n "$src" ] && [ -f "$src" ]; then
      jq -R -r '
        def spawn_ids($m):
          ($m.message.content // $m.content // null) as $c
          | (
              ($c | if type=="array" then
                  .[] | select(type=="object" and .type=="tool_use"
                        and (.name=="Task" or .name=="Agent"))
                  | ((.input.agent_id // empty), (.id // empty))
                else empty end),
              ($m.tool_calls[]?
                | select((.function.name // .name)=="Task"
                      or (.function.name // .name)=="Agent")
                | ((.id // empty),
                   (if ((.function.arguments // .arguments // null)|type)=="object"
                    then ((.function.arguments.agent_id // empty),
                          (.arguments.agent_id // empty))
                    else empty end)))
            );
        [., input_line_number] as [$raw, $ln]
        | ($raw | try fromjson catch empty) as $m
        | spawn_ids($m)
        | select(type=="string" and length>0)
        | "\(.)\t\($ln)"
      ' "$src" 2>/dev/null \
        | awk -F'\t' 'NR==FNR { w[$1]=1; next } w[$1] && !s[$1]++ { print }' "$nref/ids" - \
        > "$nref/spawn" || true
    fi
  fi

  awk -v idsfile="$nref/ids" -v spawnfile="$nref/spawn" '
    function section_end(start, j, se) {
      se = start
      for (j = start; j <= n; j++) {
        if (j > start && lines[j] ~ /^## /) break
        if (lines[j] ~ /[^ \t]/) se = j
      }
      return se
    }
    BEGIN {
      ni = 0; n = 0; last_nb = 0; last_hdr = 0
      while ((getline id < idsfile) > 0) {
        if (id != "") { nids[++ni] = id; isid[id] = 1 }
      }
      close(idsfile)
      while ((getline row < spawnfile) > 0) {
        split(row, a, "\t")
        if (a[1] != "" && isid[a[1]] && !(a[1] in spad)) {
          p = sprintf("%06d", a[2] + 0)
          if (length(p) > 6) p = substr(p, length(p) - 5)
          spad[a[1]] = p
        }
      }
      close(spawnfile)
    }
    {
      n = NR
      lines[NR] = $0
      if (NF) last_nb = NR
      if ($0 ~ /^## (user|assistant)[ \t]*$/) last_hdr = NR
      if ($0 ~ /^> @tool_result\/L[0-9]+-call\.txt$/) {
        p = $0
        sub(/^> @tool_result\/L/, "", p)
        sub(/-call\.txt$/, "", p)
        ref_line[p] = NR
      }
    }
    END {
      if (last_hdr) trail_at = section_end(last_hdr)
      else trail_at = last_nb + 0
      for (i = 1; i <= ni; i++) {
        id = nids[i]
        at = trail_at
        if (id in spad && (spad[id] in ref_line)) at = section_end(ref_line[spad[id]])
        insert[at] = insert[at] id "\n"
      }
      if (0 in insert) {
        nk = split(insert[0], arr, "\n")
        for (k = 1; k <= nk; k++) {
          if (arr[k] != "") print "> @agents/" arr[k] "/main.md"
        }
      }
      for (i = 1; i <= n; i++) {
        print lines[i]
        if (i in insert) {
          nk = split(insert[i], arr, "\n")
          for (k = 1; k <= nk; k++) {
            if (arr[k] != "") print "> @agents/" arr[k] "/main.md"
          }
        }
      }
    }
  ' "$nref/stripped" > "$nref/out" || {
    [ -n "${WORK:-}" ] && [ "$nref" = "$WORK/nref" ] || rm -rf "$nref"
    return 0
  }

  if ! cmp -s "$mainf" "$nref/out"; then
    mv "$nref/out" "$mainf" || true
  fi
  [ -n "${WORK:-}" ] && [ "$nref" = "$WORK/nref" ] || rm -rf "$nref"
  return 0
}

# Nest tick: parent nest-refs only when parent main.md exists (OQ7). Rewrite
# parent cursor hash only if main.md bytes changed (nest rebuild must not
# mutate parent cursor when refs are already present).
parent_nest_refs_after_nest() {
  local pdir="${1:-}"
  [ -n "$pdir" ] && [ -f "$pdir/main.md" ] || return 0
  local before after pid psrc
  before=$(sha_file "$pdir/main.md")
  ensure_nest_refs "$pdir"
  after=$(sha_file "$pdir/main.md")
  if [ -n "$before" ] && [ -n "$after" ] && [ "$before" != "$after" ] && [ -f "$pdir/cursor" ]; then
    IFS=$'\t' read -r pid psrc _ < "$pdir/cursor" || true
    [ -n "$pid" ] && write_cursor "$pdir" "$pid" "$psrc" "$pdir/main.md"
  fi
  return 0
}

# M5a: stdin cwd else $PWD; expand ~ / ~/; prefix $PWD if not absolute.
abs_cwd() {
  local cwd="${1:-}"
  [ -n "$cwd" ] || cwd="$PWD"
  case "$cwd" in
    '~') cwd="${HOME:-/}" ;;
    '~/'*) cwd="${HOME:-/}/${cwd#~/}" ;;
  esac
  case "$cwd" in
    /*) printf '%s\n' "$cwd" ;;
    *) printf '%s/%s\n' "${PWD%/}" "$cwd" ;;
  esac
}

# M5a: jq @uri; ASCII abs paths match quote(abs, safe="").
urlencode_cwd() {
  local abs="$1"
  jq -rn --arg s "$abs" '$s|@uri'
}

# M5a: urlencode file wins; else maxdepth-1 .cwd match; lexical-min among files.
# Strip one trailing LF/CR/CRLF from .cwd. No find. No JSONL parse.
grok_reconstruct_chat_history() {
  local root="$1" abs="$2" sid="$3"
  local enc cand child raw marker ng_was min p
  local -a hits=()

  enc=$(urlencode_cwd "$abs") || return 0
  cand="$root/$enc/$sid/chat_history.jsonl"
  if [ -f "$cand" ]; then
    printf '%s\n' "$cand"
    return 0
  fi
  [ -d "$root" ] || return 0

  ng_was=$(shopt -p nullglob)
  shopt -s nullglob
  for child in "$root"/*/; do
    [ -f "${child}.cwd" ] || continue
    raw=$(cat "${child}.cwd" 2>/dev/null && printf x) || continue
    raw="${raw%x}"
    case "$raw" in
      *$'\r\n') marker="${raw%$'\r\n'}" ;;
      *$'\n') marker="${raw%$'\n'}" ;;
      *$'\r') marker="${raw%$'\r'}" ;;
      *) marker="$raw" ;;
    esac
    [ "$marker" = "$abs" ] || continue
    cand="${child}${sid}/chat_history.jsonl"
    [ -f "$cand" ] || continue
    hits+=("$cand")
  done
  eval "$ng_was"

  [ "${#hits[@]}" -gt 0 ] || return 0
  min="${hits[0]}"
  for p in "${hits[@]}"; do
    if LC_ALL=C [ "$p" \< "$min" ]; then
      min="$p"
    fi
  done
  printf '%s\n' "$min"
}

# Parent-covered identities: parent source records through parent cursor identity.
parent_skip_json() {
  local parent="$1" start="$2" idents="$3" work="$4"
  local pdir="$ROOT/$parent" pident="" psrc="" pl=0
  if [ -z "$parent" ] || [ ! -d "$pdir" ] || [ ! -f "$pdir/cursor" ]; then
    printf '{}'
    return 0
  fi
  IFS=$'\t' read -r pident psrc _ < "$pdir/cursor" || true
  if [ -z "$pident" ]; then
    printf '{}'
    return 0
  fi
  if [ -f "$psrc" ]; then
    index_idents "$psrc" "$work/p.idents"
    pl=$(awk -v id="$pident" '$0==id { n=NR } END { print n+0 }' "$work/p.idents")
    if [ "$pl" -gt 0 ]; then
      head -n "$pl" "$work/p.idents" | grep -v '^$' > "$work/parent.idents" || true
    fi
  else
    printf '%s\n' "$pident" > "$work/parent.idents"
  fi
  if [ ! -s "$work/parent.idents" ]; then
    printf '{}'
    return 0
  fi
  awk -v start="$start" 'NR==FNR { if (NF) s[$0]=1; next }
    FNR>=start && s[$0] { print FNR }' "$work/parent.idents" "$idents" > "$work/skip_lines" || true
  if [ -s "$work/skip_lines" ]; then
    jq -R '{(.):true}' "$work/skip_lines" | jq -s 'add // {}'
  else
    printf '{}'
  fi
}

main() {
  local SID="" TP="" STDIN="" EVENT="" REASON="" AGENT="" AGENT_ID="" CWD="" RECON=0 PARENT="" META_PARENT=""
  local NEST=0 AID="" AID_RAW=""

  if [ "${1:-}" = "--transcript" ]; then
    TP="${2:-}"; shift 2
    [ -n "$TP" ] || return 0
    while [ $# -gt 0 ]; do
      case "$1" in
        --sid)
          SID="${2:-}"
          shift
          [ $# -gt 0 ] && shift
          ;;
        --agent)
          NEST=1
          AID_RAW="${2:-}"
          shift
          [ $# -gt 0 ] && shift
          ;;
        *)
          shift
          ;;
      esac
    done
  else
    if [ -t 0 ]; then
      return 0
    fi
    STDIN=$(cat 2>/dev/null || true)
    [ -n "$STDIN" ] || return 0
    EVENT=$(jq -r '.hook_event_name // .hookEventName // empty' <<<"$STDIN" 2>/dev/null) || EVENT=""
    SID=$(jq -r '.session_id // .sessionId // empty' <<<"$STDIN" 2>/dev/null) || SID=""
    CWD=$(jq -r '.cwd // empty' <<<"$STDIN" 2>/dev/null) || CWD=""
    REASON=$(jq -r '.reason // empty' <<<"$STDIN" 2>/dev/null) || REASON=""
    AGENT=$(jq -r '[.agent_id, .agentId, .agent_type, .agentType]
      | map(select(type == "string" and length > 0)) | .[0] // empty' <<<"$STDIN" 2>/dev/null) || AGENT=""
    AGENT_ID=$(jq -r '[.agent_id, .agentId]
      | map(select(type == "string" and length > 0)) | .[0] // empty' <<<"$STDIN" 2>/dev/null) || AGENT_ID=""
    # Stop/SessionEnd + non-empty agent keys: v1 no-op BEFORE any mkdir (M4 AC1).
    if [ "$EVENT" != "SubagentStop" ]; then
      [ -n "$AGENT" ] && return 0
    fi
    case "$EVENT" in ""|Stop|SessionEnd|SubagentStop) ;; *) return 0 ;; esac
    if [ "$EVENT" = "SubagentStop" ]; then
      NEST=1
      AID_RAW="$AGENT_ID"
      TP=$(jq -r '(.agent_transcript_path // .agentTranscriptPath // empty) as $a
        | if ($a | type == "string" and length > 0) then $a
          else (.transcript_path // .transcriptPath // empty) end' <<<"$STDIN" 2>/dev/null) || TP=""
      # Skip M5a even if TP empty (M4a AC10). SubagentStop ignores reason.
      if [ -z "$TP" ]; then
        log_err "no transcript: sid=$SID tp="
        return 0
      fi
    else
      TP=$(jq -r '.transcript_path // .transcriptPath // empty' <<<"$STDIN" 2>/dev/null) || TP=""
      if [ "$EVENT" != "SessionEnd" ]; then
        case "$REASON" in ""|end_turn|channel_closed|shutdown) ;; *) return 0 ;; esac
      fi
      if [ -z "$TP" ]; then
        SID="${SID:-${GROK_SESSION_ID:-}}"
        [ -n "$SID" ] || return 0
        local base abs
        base="${GROK_SESSIONS_DIR:-$HOME/.grok/sessions}"
        abs=$(abs_cwd "$CWD")
        TP=$(grok_reconstruct_chat_history "$base" "$abs" "$SID") || TP=""
        RECON=1
      fi
    fi
  fi

  case "$TP" in
    *updates.jsonl)
      [ -f "$(dirname "$TP")/chat_history.jsonl" ] && TP="$(dirname "$TP")/chat_history.jsonl" ;;
  esac
  [ -n "$SID" ] || SID=$(basename "${TP%.jsonl}")
  case "$SID" in
    ""|*[!A-Za-z0-9._-]*|*..*) [ "$RECON" -eq 1 ] && return 0; log_err "bad sid=$SID"; return 0 ;;
  esac
  if [ ! -f "$TP" ]; then
    [ "$RECON" -eq 1 ] && return 0
    log_err "no transcript: sid=$SID tp=$TP"
    return 0
  fi

  command -v jq >/dev/null 2>&1 || { log_err "jq missing"; return 0; }

  local DIR
  if [ "$NEST" -eq 1 ]; then
    AID=$(sanitize_agent_id "$AID_RAW")
    if [ -z "$AID" ]; then
      log_err "bad agent_id sid=$SID"
      return 0
    fi
    DIR="$ROOT/$SID/agents/$AID"
    META_PARENT="$SID"
    PARENT=""
  else
    DIR="$ROOT/$SID"
    PARENT=$(jq -r 'select(.forkedFrom.sessionId | type == "string" and length > 0) | .forkedFrom.sessionId' "$TP" 2>/dev/null | head -1) || PARENT=""
    case "$PARENT" in ""|null|NULL) PARENT="" ;; esac
    META_PARENT="$PARENT"
  fi

  mkdir -p "$DIR/thinking" "$DIR/tool_result" "$DIR/injection" || { log_err "mkdir failed: $DIR"; return 0; }
  ensure_meta "$DIR" "$TP" "$META_PARENT"

  local WORK
  WORK=$(mktemp -d "${TMPDIR:-/tmp}/tmirror.XXXXXX") || { log_err "mktemp failed"; return 0; }
  # shellcheck disable=SC2064
  trap "rm -rf '$WORK'" RETURN

  index_idents "$TP" "$WORK/idents"
  local nlines last_ident found=0 need_rebuild=0 cur_id="" cur_src="" cur_hash="" main_hash=""
  nlines=$(wc -l < "$WORK/idents" | tr -d ' ')
  last_ident=$(awk 'NF { x=$0 } END { print x }' "$WORK/idents")
  [ -n "$nlines" ] || nlines=0

  if [ -f "$DIR/cursor" ]; then
    IFS=$'\t' read -r cur_id cur_src cur_hash < "$DIR/cursor" || true
    main_hash=$(sha_file "$DIR/main.md")
    if [ "$cur_src" != "$TP" ] || [ -z "$cur_id" ]; then
      need_rebuild=1
    elif [ -n "$cur_hash" ] && [ "$cur_hash" != "$main_hash" ]; then
      need_rebuild=1
    else
      found=$(awk -v id="$cur_id" '$0==id { n=NR } END { print n+0 }' "$WORK/idents")
      [ "$found" -gt 0 ] || need_rebuild=1
    fi
  elif [ -s "$DIR/main.md" ]; then
    need_rebuild=1
  fi

  if [ "$need_rebuild" -eq 0 ] && [ "$found" -ge "$nlines" ]; then
    return 0
  fi

  local START=1
  [ "$need_rebuild" -eq 0 ] && [ "$found" -gt 0 ] && START=$((found + 1))

  local SKIP
  SKIP=$(parent_skip_json "$PARENT" "$START" "$WORK/idents" "$WORK") || SKIP='{}'
  [ -n "$SKIP" ] || SKIP='{}'

  if [ "$need_rebuild" -eq 1 ]; then
    local NEW="$WORK/out"
    mkdir -p "$NEW/thinking" "$NEW/tool_result" "$NEW/injection" || { log_err "mkdir new failed"; return 0; }
    emit_tick "$TP" "$NEW" 1 "$SKIP" || { log_err "jq failed: sid=$SID"; return 0; }
    printf '# transcript mirror — %s\n' "$SID" > "$NEW/main.md"
    if [ -s "$NEW/.main.part" ]; then
      if ! { cat "$NEW/.main.part" >> "$NEW/main.md"; } 2>/dev/null; then
        log_err "rebuild write failed: sid=$SID"
        return 0
      fi
    fi
    printf 'source: %s\nstarted_mirror: %s\n' "$TP" "$(date -Is 2>/dev/null || date)" > "$NEW/meta"
    [ -n "$META_PARENT" ] && printf 'parent: %s\n' "$META_PARENT" >> "$NEW/meta"
    write_cursor "$NEW" "$last_ident" "$TP" "$NEW/main.md"
    rm -f "$NEW/.slice.jsonl" "$NEW/.main.part" "$NEW/.main.part.raw"
    # Sibling of $DIR — never under $WORK (RETURN trap rm -rf would drop the live sid).
    local BAK="${DIR}.bak.$$"
    local AGENTS_BAK=""
    if [ -d "$DIR/agents" ]; then
      AGENTS_BAK="${DIR}.agents.$$"
      if ! mv "$DIR/agents" "$AGENTS_BAK"; then
        log_err "rebuild agents stash failed: sid=$SID"
        return 0
      fi
    fi
    if ! mv "$DIR" "$BAK"; then
      if [ -n "$AGENTS_BAK" ] && [ -d "$AGENTS_BAK" ]; then
        mv "$AGENTS_BAK" "$DIR/agents" 2>/dev/null || true
      fi
      log_err "rebuild mv old failed: sid=$SID"
      return 0
    fi
    if ! mv "$NEW" "$DIR"; then
      mv "$BAK" "$DIR" 2>/dev/null || true
      if [ -n "$AGENTS_BAK" ] && [ -d "$AGENTS_BAK" ]; then
        mv "$AGENTS_BAK" "$DIR/agents" 2>/dev/null || true
      fi
      log_err "rebuild swap failed: sid=$SID"
      return 0
    fi
    if [ -n "$AGENTS_BAK" ] && [ -d "$AGENTS_BAK" ]; then
      mv "$AGENTS_BAK" "$DIR/agents" 2>/dev/null || log_err "rebuild agents restore failed: sid=$SID"
    fi
    rm -rf "$BAK"
    if [ "$NEST" -eq 0 ]; then
      ensure_nest_refs "$DIR"
      write_cursor "$DIR" "$last_ident" "$TP" "$DIR/main.md"
    else
      parent_nest_refs_after_nest "$ROOT/$SID"
    fi
    return 0
  fi

  emit_tick "$TP" "$DIR" "$START" "$SKIP" || { log_err "jq failed: sid=$SID"; return 0; }
  if [ -s "$DIR/.main.part" ]; then
    local part="$DIR/.main.part"
    if [ -f "$DIR/main.md" ]; then
      case "$(last_nonblank "$DIR/main.md")" in
        '> @tool_result/'*) drop_leading_tr < "$part" > "$part.trimmed" && mv "$part.trimmed" "$part" ;;
      esac
    else
      printf '# transcript mirror — %s\n' "$SID" > "$DIR/main.md"
    fi
    if [ -s "$part" ]; then
      if ! { cat "$part" >> "$DIR/main.md"; } 2>/dev/null; then
        log_err "append failed: sid=$SID"
        return 0
      fi
    fi
  elif [ ! -f "$DIR/main.md" ]; then
    printf '# transcript mirror — %s\n' "$SID" > "$DIR/main.md"
  fi
  rm -f "$DIR/.slice.jsonl" "$DIR/.main.part" "$DIR/.main.part.raw" "$DIR/.main.part.trimmed"
  if [ "$NEST" -eq 0 ]; then
    ensure_nest_refs "$DIR"
  else
    parent_nest_refs_after_nest "$ROOT/$SID"
  fi
  write_cursor "$DIR" "$last_ident" "$TP" "$DIR/main.md"
  return 0
}

main "$@" || log_err "unexpected failure rc=$?"
exit 0
