#!/usr/bin/env bash
# reconcile-lib.sh — Candidate pair generation for /validate-memory --reconcile
#
# Usage (subprocess only — never source):
#   bash reconcile-lib.sh candidates <MEMDB> [--agent NAME] [--cap N] [--out PATH]
#   bash reconcile-lib.sh resolve-pick <MEMDB> <winner_id> <loser_id> <agent_a> <agent_b> \
#        <claim_a> <claim_b> <confidence> <reason>
#   bash reconcile-lib.sh resolve-both-stale <MEMDB> <id_a> <id_b> <agent_a> <agent_b> \
#        <claim_a> <claim_b> <confidence> <reason>
#   bash reconcile-lib.sh resolve-merge <MEMDB> <winner_id> <loser_id> <agent_a> <agent_b> \
#        <claim_a> <claim_b> <confidence> <merged_content> <reason>
#   bash reconcile-lib.sh resolve-skip <MEMDB> <id_a> <id_b> <agent_a> <agent_b> \
#        <claim_a> <claim_b> <confidence> <reason>
#   bash reconcile-lib.sh resolve-deep-audit <MEMDB> <id_a> <id_b> <agent_a> <agent_b> \
#        <claim_a> <claim_b> <confidence> <reason>
#
# candidates writes JSONL pairs to --out (default stdout). method=keyword|embed.
# Never auto-archives. report-only path must not call resolve-* subcommands.
#
# Governing: SPEC-011 (CDV-195). THIS SCRIPT IS A SUBPROCESS CLI — NEVER SOURCE IT.

set -euo pipefail

BEHAVIORAL='pm|tech-lead|ic5|ic4|devops|qa|ds'
# Soft thresholds (v1 hardcoded — OQ-3)
EMBED_SIM_MIN=0.55
KEYWORD_JACCARD_MIN=0.15
SAMPLE_PER_AGENT=200

usage() {
  cat <<'EOF' >&2
Usage:
  reconcile-lib.sh candidates <MEMDB> [--agent NAME] [--cap N] [--out PATH]
  reconcile-lib.sh resolve-pick|resolve-both-stale|resolve-merge|resolve-skip|resolve-deep-audit ...
EOF
  exit 64
}

sql_escape() {
  printf '%s' "$1" | sed "s/'/''/g"
}

# Ordered pair normalization: smaller id first
pair_key() {
  local a=$1 b=$2
  if [ "$a" -lt "$b" ]; then
    echo "${a}|${b}"
  else
    echo "${b}|${a}"
  fi
}

# Tokenize: lowercase words len>=4
tokenize() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9' '\n' | awk 'length>=4'
}

jaccard() {
  # stdin: two token lists separated by --- on its own line is awkward;
  # take two args as content strings
  local ta tb
  ta=$(tokenize "$1")
  tb=$(tokenize "$2")
  if [ -z "$ta" ] || [ -z "$tb" ]; then
    echo "0"
    return
  fi
  # shellcheck disable=SC2086
  printf '%s\n' $ta | sort -u >"${TMPDIR:-/tmp}/jac_a.$$"
  # shellcheck disable=SC2086
  printf '%s\n' $tb | sort -u >"${TMPDIR:-/tmp}/jac_b.$$"
  local inter union
  inter=$(comm -12 "${TMPDIR:-/tmp}/jac_a.$$" "${TMPDIR:-/tmp}/jac_b.$$" | wc -l | tr -d ' ')
  union=$(sort -u "${TMPDIR:-/tmp}/jac_a.$$" "${TMPDIR:-/tmp}/jac_b.$$" | wc -l | tr -d ' ')
  rm -f "${TMPDIR:-/tmp}/jac_a.$$" "${TMPDIR:-/tmp}/jac_b.$$"
  if [ "${union:-0}" -eq 0 ]; then
    echo "0"
    return
  fi
  # awk for float
  awk -v i="$inter" -v u="$union" 'BEGIN{printf "%.6f", i/u}'
}

resolved_pair_keys() {
  local memdb=$1
  # Prior resolved actions skip re-nagging (D10 / OQ-8)
  sqlite3 -cmd ".timeout 5000" "$memdb" \
    "SELECT memory_id_a || '|' || memory_id_b
     FROM reconcile_log
     WHERE action IN ('pick-survivor','merge','both-stale');" 2>/dev/null \
    | while IFS= read -r row; do
        a=${row%%|*}
        b=${row#*|}
        pair_key "$a" "$b"
      done | sort -u
}

cmd_candidates() {
  local memdb=$1
  shift
  local agent_filter="" cap="" out=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --agent) agent_filter="${2:-}"; shift 2 ;;
      --cap) cap="${2:-}"; shift 2 ;;
      --out) out="${2:-}"; shift 2 ;;
      *) echo "Unknown arg: $1" >&2; usage ;;
    esac
  done

  if [ ! -f "$memdb" ]; then
    echo "Error: database not found at $memdb" >&2
    exit 1
  fi

  if [ -z "$cap" ]; then
    cap=$(sqlite3 -cmd ".timeout 5000" "$memdb" \
      "SELECT value FROM config WHERE key='reconcile_pair_cap';" 2>/dev/null || echo "50")
  fi
  case "$cap" in
    ''|*[!0-9]*) cap=50 ;;
  esac
  if [ "$cap" -lt 1 ]; then cap=1; fi
  if [ "$cap" -gt 500 ]; then cap=500; fi

  local work
  work=$(mktemp -d "${TMPDIR:-/tmp}/reconcile-cand.XXXXXX")
  # shellcheck disable=SC2064
  trap "rm -rf '$work'" RETURN

  local agent_clause=""
  if [ -n "$agent_filter" ]; then
    local esc
    esc=$(sql_escape "$agent_filter")
    # OQ-9: at least one side is that agent (applied after pair gen)
    agent_clause="$esc"
  fi

  # Export active behavioral memories: id|agent|tier|created_at|content
  # Sample: highest tier then newest, max SAMPLE_PER_AGENT per agent
  sqlite3 -cmd ".timeout 5000" -separator $'\t' "$memdb" \
    "SELECT id, agent, tier, created_at, content
     FROM memories
     WHERE archived=FALSE
       AND agent IN ('pm','tech-lead','ic5','ic4','devops','qa','ds')
     ORDER BY agent, tier DESC, created_at DESC;" \
    >"$work/all.tsv" 2>/dev/null || true

  # Per-agent sample
  : >"$work/sampled.tsv"
  local cur_agent="" count=0
  while IFS=$'\t' read -r mid magent mtier mcreated mcontent; do
    [ -z "${mid:-}" ] && continue
    if [ "$magent" != "$cur_agent" ]; then
      cur_agent="$magent"
      count=0
    fi
    if [ "$count" -ge "$SAMPLE_PER_AGENT" ]; then
      continue
    fi
    printf '%s\t%s\t%s\t%s\t%s\n' "$mid" "$magent" "$mtier" "$mcreated" "$mcontent" >>"$work/sampled.tsv"
    count=$((count + 1))
  done <"$work/all.tsv"

  local method="keyword"
  local embed_ok=false
  local dims embed_mode
  dims=$(sqlite3 -cmd ".timeout 5000" "$memdb" \
    "SELECT value FROM config WHERE key='embedding_dimensions';" 2>/dev/null || echo "0")
  embed_mode=$(sqlite3 -cmd ".timeout 5000" "$memdb" \
    "SELECT value FROM config WHERE key='embedding_mode';" 2>/dev/null || echo "fallback")

  # Detect vec0 table existence (no extension load needed for table list if created)
  if [[ "$dims" =~ ^[0-9]+$ ]] && [ "$dims" -gt 0 ] && [ "$embed_mode" != "fallback" ]; then
    local vec_table="vec_memories_${dims}"
    local has_vec
    has_vec=$(sqlite3 -cmd ".timeout 5000" "$memdb" \
      "SELECT 1 FROM sqlite_master WHERE type='table' AND name='$vec_table' LIMIT 1;" 2>/dev/null || true)
    if [ "$has_vec" = "1" ]; then
      # Try embedding KNN path — requires vec0 extension at MROOT/extensions
      local mroot_guess
      mroot_guess=$(dirname "$(dirname "$memdb")")
      local ext_dir="$mroot_guess/.claude/memory/extensions"
      local ext_suffix=so
      [ "$(uname -s)" = "Darwin" ] && ext_suffix=dylib
      if [ -f "$ext_dir/vec0.$ext_suffix" ]; then
        if _embed_candidates "$memdb" "$work" "$vec_table" "$ext_dir/vec0.$ext_suffix" "$agent_clause"; then
          method="embed"
          embed_ok=true
        fi
      fi
    fi
  fi

  if [ "$embed_ok" != "true" ]; then
    _keyword_candidates "$work" "$agent_clause"
    method="keyword"
  fi

  # Load resolved pairs to skip
  resolved_pair_keys "$memdb" >"$work/resolved.txt" || : >"$work/resolved.txt"

  # pairs.raw: score\tid_a\tagent_a\tcontent_a\tid_b\tagent_b\tcontent_b
  # Sort desc by score, dedupe unordered, apply cap
  : >"$work/out.jsonl"
  local seen_file="$work/seen.txt"
  : >"$seen_file"
  local n=0 cap_hit=false total_raw=0

  if [ -f "$work/pairs.raw" ]; then
    total_raw=$(wc -l <"$work/pairs.raw" | tr -d ' ')
    sort -t $'\t' -k1,1nr "$work/pairs.raw" >"$work/pairs.sorted"
    n=0
    while IFS=$'\t' read -r score id_a agent_a content_a id_b agent_b content_b; do
      [ -z "${id_a:-}" ] && continue
      pk=$(pair_key "$id_a" "$id_b")
      if grep -qxF "$pk" "$seen_file" 2>/dev/null; then
        continue
      fi
      if grep -qxF "$pk" "$work/resolved.txt" 2>/dev/null; then
        continue
      fi
      # agent filter: at least one side
      if [ -n "$agent_clause" ]; then
        if [ "$agent_a" != "$agent_filter" ] && [ "$agent_b" != "$agent_filter" ]; then
          continue
        fi
      fi
      # same-agent skip (belt)
      if [ "$agent_a" = "$agent_b" ]; then
        continue
      fi
      if [ "$n" -ge "$cap" ]; then
        echo "CAP_HIT" >"$work/cap_hit"
        break
      fi
      echo "$pk" >>"$seen_file"
      n=$((n + 1))
      # JSON escape via python for safety
      python3 -c '
import json,sys
score,id_a,agent_a,content_a,id_b,agent_b,content_b,method=sys.argv[1:9]
# normalize id order for stable output (lo first)
ia,ib=int(id_a),int(id_b)
aa,ab,ca,cb=agent_a,agent_b,content_a,content_b
if ia>ib:
  ia,ib=ib,ia
  aa,ab=ab,aa
  ca,cb=cb,ca
print(json.dumps({
  "id_a":ia,"agent_a":aa,"content_a":ca,
  "id_b":ib,"agent_b":ab,"content_b":cb,
  "score":float(score),"method":method
}, ensure_ascii=False))
' "$score" "$id_a" "$agent_a" "$content_a" "$id_b" "$agent_b" "$content_b" "$method" >>"$work/out.jsonl"
    done <"$work/pairs.sorted"
  fi

  # Count written (subshell n is lost)
  local written
  written=$(wc -l <"$work/out.jsonl" | tr -d ' ')
  if [ -f "$work/cap_hit" ] || [ "${total_raw:-0}" -gt "$cap" ]; then
    # Cap hit if we truncated OR raw candidates exceeded cap before filter
    if [ "$written" -ge "$cap" ]; then
      cap_hit=true
    fi
  fi

  # Emit meta line on stderr for host TLDR
  echo "RECONCILE_META candidates=$written cap=$cap cap_hit=$cap_hit method=$method" >&2

  if [ -n "$out" ]; then
    cp "$work/out.jsonl" "$out"
  else
    cat "$work/out.jsonl"
  fi
}

_keyword_candidates() {
  local work=$1
  # agent_clause unused here — filter applied later
  : >"$work/pairs.raw"
  # Load into arrays via file lines
  local -a ids agents contents
  ids=(); agents=(); contents=()
  while IFS=$'\t' read -r mid magent _mtier _mcreated mcontent; do
    [ -z "${mid:-}" ] && continue
    ids+=("$mid")
    agents+=("$magent")
    contents+=("$mcontent")
  done <"$work/sampled.tsv"

  local n=${#ids[@]}
  local i j score
  for ((i=0; i<n; i++)); do
    for ((j=i+1; j<n; j++)); do
      if [ "${agents[i]}" = "${agents[j]}" ]; then
        continue
      fi
      score=$(jaccard "${contents[i]}" "${contents[j]}")
      # compare to KEYWORD_JACCARD_MIN via awk
      if awk -v s="$score" -v m="$KEYWORD_JACCARD_MIN" 'BEGIN{exit !(s+0>=m+0)}'; then
        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
          "$score" "${ids[i]}" "${agents[i]}" "${contents[i]}" \
          "${ids[j]}" "${agents[j]}" "${contents[j]}" >>"$work/pairs.raw"
      fi
    done
  done
}

_embed_candidates() {
  local memdb=$1 work=$2 vec_table=$3 vec_ext=$4
  # agent filter applied later
  : >"$work/pairs.raw"
  # For each memory id, KNN k=5 against other agents
  local mid magent mcontent
  while IFS=$'\t' read -r mid magent _mtier _mcreated mcontent; do
    [ -z "${mid:-}" ] && continue
    local knn
    knn=$(sqlite3 -cmd ".timeout 5000" "$memdb" 2>/dev/null <<EOSQL || true
.load $vec_ext
SELECT e.memory_id, m.agent, m.content, e.distance
FROM ${vec_table} e
JOIN memories m ON m.id = e.memory_id
WHERE e.embedding MATCH (
  SELECT embedding FROM ${vec_table} WHERE memory_id = ${mid}
)
  AND k = 6
  AND m.archived = FALSE
  AND m.agent IN ('pm','tech-lead','ic5','ic4','devops','qa','ds')
  AND m.agent != '$(sql_escape "$magent")'
  AND e.memory_id != ${mid};
EOSQL
)
    [ -z "$knn" ] && continue
    while IFS='|' read -r oid oagent ocontent dist; do
      [ -z "${oid:-}" ] && continue
      # sim = 1 - distance; keep sim >= EMBED_SIM_MIN (distance <= 1-min)
      local sim
      sim=$(awk -v d="$dist" 'BEGIN{printf "%.6f", 1-d}')
      if awk -v s="$sim" -v m="$EMBED_SIM_MIN" 'BEGIN{exit !(s+0>=m+0)}'; then
        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
          "$sim" "$mid" "$magent" "$mcontent" "$oid" "$oagent" "$ocontent" >>"$work/pairs.raw"
      fi
    done <<<"$knn"
  done <"$work/sampled.tsv"
  # Success if we got any pairs OR table was queryable (even empty is ok — fall through empty)
  return 0
}

_log_reconcile() {
  local memdb=$1 id_a=$2 id_b=$3 agent_a=$4 agent_b=$5
  local verdict=$6 claim_a=$7 claim_b=$8 conf=$9 action=${10}
  local winner=${11:-} loser=${12:-} reason=${13:-}
  local ea eb eca ecb er
  ea=$(sql_escape "$agent_a")
  eb=$(sql_escape "$agent_b")
  eca=$(sql_escape "$claim_a")
  ecb=$(sql_escape "$claim_b")
  er=$(sql_escape "$reason")
  local wsql=NULL lsql=NULL
  [ -n "$winner" ] && wsql=$winner
  [ -n "$loser" ] && lsql=$loser
  sqlite3 -cmd ".timeout 5000" "$memdb" "PRAGMA busy_timeout=5000;
    INSERT INTO reconcile_log(
      memory_id_a, memory_id_b, agent_a, agent_b, verdict,
      claim_a, claim_b, confidence, action, winner_id, loser_id, reason
    ) VALUES (
      $id_a, $id_b, '$ea', '$eb', '$verdict',
      '$eca', '$ecb', $conf, '$action', $wsql, $lsql, '$er'
    );"
}

cmd_resolve_pick() {
  local memdb=$1 winner=$2 loser=$3 agent_a=$4 agent_b=$5
  local claim_a=$6 claim_b=$7 conf=$8 reason=$9
  sqlite3 -cmd ".timeout 5000" "$memdb" "PRAGMA busy_timeout=5000;
    UPDATE memories SET archived=TRUE, archive_reason='reconciled'
    WHERE id=$loser;"
  _log_reconcile "$memdb" "$winner" "$loser" "$agent_a" "$agent_b" \
    "contradictory" "$claim_a" "$claim_b" "$conf" "pick-survivor" \
    "$winner" "$loser" "$reason"
}

cmd_resolve_both_stale() {
  local memdb=$1 id_a=$2 id_b=$3 agent_a=$4 agent_b=$5
  local claim_a=$6 claim_b=$7 conf=$8 reason=$9
  sqlite3 -cmd ".timeout 5000" "$memdb" "PRAGMA busy_timeout=5000;
    UPDATE memories SET archived=TRUE, archive_reason='reconciled'
    WHERE id IN ($id_a, $id_b);"
  _log_reconcile "$memdb" "$id_a" "$id_b" "$agent_a" "$agent_b" \
    "contradictory" "$claim_a" "$claim_b" "$conf" "both-stale" \
    "" "" "$reason"
}

cmd_resolve_merge() {
  local memdb=$1 winner=$2 loser=$3 agent_a=$4 agent_b=$5
  local claim_a=$6 claim_b=$7 conf=$8 merged=$9 reason=${10}
  local today esc
  today=$(date -u +%Y-%m-%d)
  # strip existing reconcile tags, append new
  merged=$(printf '%s' "$merged" | sed 's/\[reconciled: [0-9-]*\]//g')
  merged=$(printf '%s\n\n[reconciled: %s]' "$merged" "$today")
  esc=$(sql_escape "$merged")
  sqlite3 -cmd ".timeout 5000" "$memdb" "PRAGMA busy_timeout=5000;
    UPDATE memories SET content='$esc',
      updated_at=strftime('%Y-%m-%dT%H:%M:%SZ','now')
    WHERE id=$winner;
    UPDATE memories SET archived=TRUE, archive_reason='reconciled'
    WHERE id=$loser;"
  _log_reconcile "$memdb" "$winner" "$loser" "$agent_a" "$agent_b" \
    "contradictory" "$claim_a" "$claim_b" "$conf" "merge" \
    "$winner" "$loser" "$reason"
}

cmd_resolve_skip() {
  local memdb=$1 id_a=$2 id_b=$3 agent_a=$4 agent_b=$5
  local claim_a=$6 claim_b=$7 conf=$8 reason=$9
  _log_reconcile "$memdb" "$id_a" "$id_b" "$agent_a" "$agent_b" \
    "contradictory" "$claim_a" "$claim_b" "$conf" "skip" \
    "" "" "$reason"
}

cmd_resolve_deep_audit() {
  local memdb=$1 id_a=$2 id_b=$3 agent_a=$4 agent_b=$5
  local claim_a=$6 claim_b=$7 conf=$8 reason=$9
  _log_reconcile "$memdb" "$id_a" "$id_b" "$agent_a" "$agent_b" \
    "contradictory" "$claim_a" "$claim_b" "$conf" "deep-audit" \
    "" "" "$reason"
  # Print council handoff only — do not spawn tribunal
  printf '/council "%s vs %s"\n' "$claim_a" "$claim_b"
}

# ---- main dispatch ----
[ $# -lt 1 ] && usage
CMD=$1
shift

case "$CMD" in
  candidates)
    [ $# -lt 1 ] && usage
    cmd_candidates "$@"
    ;;
  resolve-pick)
    [ $# -lt 9 ] && usage
    cmd_resolve_pick "$@"
    ;;
  resolve-both-stale)
    [ $# -lt 9 ] && usage
    cmd_resolve_both_stale "$@"
    ;;
  resolve-merge)
    [ $# -lt 10 ] && usage
    cmd_resolve_merge "$@"
    ;;
  resolve-skip)
    [ $# -lt 9 ] && usage
    cmd_resolve_skip "$@"
    ;;
  resolve-deep-audit)
    [ $# -lt 9 ] && usage
    cmd_resolve_deep_audit "$@"
    ;;
  *)
    usage
    ;;
esac
