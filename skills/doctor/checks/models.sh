# models.sh — sourced by doctor.sh (rv-w3-39 doctor split); pure definitions, no top-level side effects.
check_models_map() {
  local id="models.map" group="config"
  local local_map="$MROOT/.claude/dev-team/models.local.json"
  local repo_map="$MROOT/.claude/dev-team/models.json"
  local global_map="${HOME:-}/.claude/dev-team/models.json"
  local present="" p problems="" m9=""

  for p in "$local_map" "$repo_map" "$global_map"; do
    [ -f "$p" ] || continue
    present="${present}${p}"$'\n'
  done
  if [ -z "$present" ]; then
    record "$id" "$group" "SKIP" "no Model map files" ""
    return 0
  fi
  if ! have_cmd jq; then
    record "$id" "$group" "WARN" \
      "jq absent — cannot validate Model map" \
      "Install jq (system package manager)"
    return 0
  fi

  _mmap_is_mappable() {
    case "$1" in
      pm|tech-lead|ic5|ic4|devops|qa|ds|council-judge|finder|debugger) return 0 ;;
      *) return 1 ;;
    esac
  }

  _mmap_is_effort_token() {
    case "$1" in
      low|medium|high|xhigh|max) return 0 ;;
      *) return 1 ;;
    esac
  }

  _mmap_note_m9() {
    case "$1" in
      qa|council-judge)
        case " $m9 " in
          *" $1 "*) ;;
          *) m9="${m9:+$m9 }$1" ;;
        esac
        ;;
    esac
  }

  _mmap_add_problem() {
    problems="${problems:+$problems; }$1"
  }

  # Scan one Model map field (agents or effort). Mutates problems and m9.
  _mmap_scan_field() {
    local p=$1 field=$2
    local ftype key typ raw trimmed token bad
    if ! jq -e --arg f "$field" 'has($f)' "$p" >/dev/null 2>&1; then
      return 0
    fi
    ftype=$(jq -r --arg f "$field" '.[$f] | type' "$p" 2>/dev/null) || ftype=""
    if [ "$ftype" != "object" ]; then
      _mmap_add_problem "${field} is not an object at ${p}"
      return 0
    fi
    while IFS= read -r key || [ -n "$key" ]; do
      [ -n "$key" ] || continue
      if ! _mmap_is_mappable "$key"; then
        if [ "$field" = "effort" ]; then
          _mmap_add_problem "unknown effort key '${key}' in ${p}"
        else
          _mmap_add_problem "unknown agent key '${key}' in ${p}"
        fi
        continue
      fi
      if [ "$field" = "effort" ]; then
        bad="effort.${key} is not a valid effort token in ${p}"
      else
        bad="agents.${key} is not a non-empty string in ${p}"
      fi
      typ=$(jq -r --arg n "$key" --arg f "$field" '.[$f][$n] | type' "$p" 2>/dev/null) || typ=""
      if [ "$typ" != "string" ]; then
        _mmap_add_problem "$bad"
        continue
      fi
      raw=$(jq -r --arg n "$key" --arg f "$field" '.[$f][$n]' "$p" 2>/dev/null) || raw=""
      trimmed=$(trim_ws "$raw")
      if [ "$field" = "effort" ]; then
        token=$(printf '%s' "$trimmed" | tr '[:upper:]' '[:lower:]')
        if [ -z "$token" ] || ! _mmap_is_effort_token "$token"; then
          _mmap_add_problem "$bad"
          continue
        fi
      elif [ -z "$trimmed" ]; then
        _mmap_add_problem "$bad"
        continue
      fi
      _mmap_note_m9 "$key"
    done < <(jq -r --arg f "$field" '.[$f] | keys[]' "$p" 2>/dev/null || true)
  }

  while IFS= read -r p || [ -n "$p" ]; do
    [ -n "$p" ] || continue
    if ! jq empty "$p" >/dev/null 2>&1; then
      _mmap_add_problem "unparseable JSON at ${p}"
      continue
    fi
    if [ "$(jq -r 'type' "$p" 2>/dev/null || true)" != "object" ]; then
      _mmap_add_problem "unparseable JSON at ${p}"
      continue
    fi
    _mmap_scan_field "$p" "agents"
    _mmap_scan_field "$p" "effort"
  done <<< "$present"

  if [ -n "$problems" ]; then
    record "$id" "$group" "WARN" "$problems" "/setup models"
    return 0
  fi
  if [ -n "$m9" ]; then
    local name m9detail=""
    for name in $m9; do
      m9detail="${m9detail:+$m9detail; }model-map: override for adversarial role '${name}' is allowed and may weaken the gate"
    done
    record "$id" "$group" "WARN" "$m9detail" "/setup models"
    return 0
  fi
  record "$id" "$group" "PASS" "Model map JSON valid" ""
}

