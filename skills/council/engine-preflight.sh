# council/engine-preflight.sh — cmd_preflight, sourced by engine.sh (L-10).

# ---- preflight --------------------------------------------------------------
# Parse scope flags → validate → resolve preset → emit investigation-plan
# JSON to stdout. No-scope / missing from-retro anchor / bad plan path → exit 2;
# bad preset → exit 4. Exit 3 reserved (no deferred scopes remain after CDV-212).
cmd_preflight() {
  require_jq

  local scope="" scope_arg="" last="" task_id="" preset="" why="false"
  local preset_source="inferred"
  local resolved_claim="" anchor_file=""
  local external="false" external_prefer="auto"
  local council_tier="" grading_reason=""

  while [ $# -gt 0 ]; do
    case "$1" in
      --scope)     need_val "$1" $#; scope="$2"; shift 2 ;;
      --scope-arg) need_val "$1" $#; scope_arg="$2"; shift 2 ;;
      --last)      need_val "$1" $#; last="$2"; shift 2 ;;
      --task-id)   need_val "$1" $#; task_id="$2"; shift 2 ;;
      --preset)    need_val "$1" $#; preset="$2"; preset_source="explicit"; shift 2 ;;
      --why)       why="true"; shift ;;
      # CDT-126: tier resolved by the caller (commands/council.md Step 1.5 —
      # grading, or an externally-supplied DRI/ship-gate tier). The engine
      # never grades; it only consumes the resolved value.
      --tier)           need_val "$1" $#; council_tier="$2"; shift 2 ;;
      --grading-reason) need_val "$1" $#; grading_reason="$2"; shift 2 ;;
      # CDV-207: optional external investigator (codex/gemini). Forms:
      #   --external | --external=codex|gemini | --external codex|gemini
      --external)
        external="true"
        if [ -n "${2:-}" ] && [[ "${2}" != --* ]]; then
          external_prefer="${2}"
          shift 2
        else
          external_prefer="auto"
          shift
        fi
        ;;
      --external=*)
        external="true"
        external_prefer="${1#--external=}"
        [ -n "$external_prefer" ] || external_prefer="auto"
        shift
        ;;
      *)
        echo "engine.sh: unknown preflight flag: $1" >&2
        exit 2
        ;;
    esac
  done

  case "$external_prefer" in
    auto|codex|gemini) ;;
    *)
      echo "engine.sh: invalid --external value: $external_prefer (want codex|gemini)" >&2
      exit 2
      ;;
  esac

  # CDT-126 tier validation. `skip` short-circuits the whole run at the call
  # site and must never reach the engine; anything else is a caller bug, and
  # the caller has already fail-closed to `full` before invoking us (SPEC-013
  # § Council tiering, Fail-closed contract), so coercing here would mask it.
  case "$council_tier" in
    light|full) ;;
    "")
      council_tier="full"
      [ -n "$grading_reason" ] || grading_reason="ungraded: no tier supplied (default full)"
      ;;
    skip)
      echo "engine.sh: --tier skip is resolved by the caller — the run must not reach preflight" >&2
      exit 2
      ;;
    *)
      echo "engine.sh: invalid --tier value: $council_tier (want light|full)" >&2
      exit 2
      ;;
  esac
  if [ -z "$grading_reason" ]; then
    grading_reason="externally supplied tier (no grading_reason given)"
  fi

  # No-scope invocation → usage error (exit 2)
  if [ -z "$scope" ]; then
    echo "engine.sh: scope required (--scope claim|session|diff|plan|from-retro)" >&2
    usage
    exit 2
  fi

  # Plan scope: require a readable file path (missing/unreadable → exit 2)
  if [ "$scope" = "plan" ]; then
    if [ -z "$scope_arg" ]; then
      echo "engine.sh: --plan requires a path (--scope-arg <path>)" >&2
      exit 2
    fi
    if [ ! -f "$scope_arg" ] || [ ! -r "$scope_arg" ]; then
      echo "engine.sh: plan file not found or not readable: $scope_arg" >&2
      exit 2
    fi
  fi

  # from-retro: load $MROOT/.claude/retro/anchors/<id>.json (CDV-212 design a).
  # Missing/unreadable/malformed → exit 2 (not deferred). Claim already isolated
  # → Phase 1 skip; resolved_claim carries fabricated_claim_text for Phase 2.
  if [ "$scope" = "from-retro" ]; then
    if [ -z "$scope_arg" ]; then
      echo "engine.sh: --from-retro requires an anchor-id (--scope-arg <id>)" >&2
      exit 2
    fi
    validate_path_component "anchor-id" "$scope_arg"
    anchor_file="$MROOT/.claude/retro/anchors/${scope_arg}.json"
    if [ ! -f "$anchor_file" ] || [ ! -r "$anchor_file" ]; then
      echo "engine.sh: retro anchor not found: $anchor_file" >&2
      exit 2
    fi
    if ! jq -e . "$anchor_file" >/dev/null 2>&1; then
      echo "engine.sh: retro anchor is not valid JSON: $anchor_file" >&2
      exit 2
    fi
    resolved_claim=$(jq -r '.fabricated_claim_text // empty' "$anchor_file")
    if [ -z "$resolved_claim" ]; then
      echo "engine.sh: retro anchor missing fabricated_claim_text: $anchor_file" >&2
      exit 2
    fi
  fi

  # Resolve task-id via fallback chain
  if [ -z "$task_id" ]; then
    task_id="${CLAUDE_TASK_ID:-}"
  fi

  # Scope is validated even when --preset is explicit. An explicit preset
  # used to skip this case, so `--scope bogus --preset generic` was accepted.
  case "$scope" in
    claim|session|diff|plan|from-retro) ;;
    *)
      echo "engine.sh: unknown scope: $scope" >&2
      exit 2
      ;;
  esac

  # Resolve preset (explicit or inferred from scope)
  if [ -z "$preset" ]; then
    preset_source="inferred"
    case "$scope" in
      diff) preset="diff-mode" ;;
      *)    preset="generic" ;;
    esac
  fi

  # Preset table (COUNCIL-001 hardcoded — see SKILL.md "Presets" section).
  local output_shape feedback_enabled spec_grep confidence_filter flavors
  case "$preset" in
    generic)
      output_shape="verdict[]"; feedback_enabled="true"; spec_grep="false"
      confidence_filter="null"
      flavors='["paranoid-ic","skeptic-ic"]' ;;
    diff-mode)
      output_shape="finding[]"; feedback_enabled="false"; spec_grep="true"
      confidence_filter="80"
      flavors='["logic","security","compliance","quality","simplification"]' ;;
    *)
      echo "engine.sh: unknown preset: $preset — known: generic, diff-mode" >&2
      exit 4 ;;
  esac

  # CDT-126 light flavor subsets (SPEC-013 § Council tiering). `generic` is
  # already exactly the 2 distinct Phase 2 flavors light requires (paranoid-ic
  # + skeptic-ic), so it is unchanged;
  # `diff-mode` keeps the two correctness/safety axes and drops the three
  # polish axes.
  if [ "$council_tier" = "light" ] && [ "$preset" = "diff-mode" ]; then
    flavors='["logic","security"]'
  fi

  local claim_budget=10  # SPEC-013 "per-run claim budget (default: 10 claims)", hardcoded in v1

  # ---- M14 per-AC split (SPEC-033 M14(g); SPEC-013 Phase 1 "M14 per-AC
  # split"; WP 1-14 interface contracts C1/C2). Trigger: scope==claim AND
  # scope_arg starts "Ship-gate audit for <ticket_id>." AND >=1 ac-source=
  # token. Zero ac-source= tokens does NOT split -- the plan stays exactly
  # as it was before WP 1-14 (AC G; the mapper then halts it, SPEC-033
  # M14(g)). Every stderr line below is prefixed "m14-ac-split:" (never
  # "engine.sh:") to match m14-ac-split.sh's own contract (C1) and the
  # SKILL.md exit-8 failure-table row.
  local m14_triggered="false" m14_claims_json="[]" m14_ac_source="" \
        m14_process_acs_json="[]"
  if [ "$scope" = "claim" ] \
     && [[ "$scope_arg" =~ ^Ship-gate\ audit\ for\ ([A-Za-z0-9._-]+)\. ]]; then
    local m14_ticket_id="${BASH_REMATCH[1]}"
    local m14_tokens m14_token_count=0
    m14_tokens="$(printf '%s' "$scope_arg" | grep -oE 'ac-source=[^[:space:]]+' || true)"
    [ -n "$m14_tokens" ] && m14_token_count=$(printf '%s\n' "$m14_tokens" | wc -l | tr -d ' ')
    if [ "$m14_token_count" -ge 1 ]; then
      m14_triggered="true"
      if [ "$m14_token_count" -ge 2 ]; then
        echo "m14-ac-split: case 1: envelope holds $m14_token_count ac-source= tokens (must hold exactly one)" >&2
        exit 8
      fi
      # WP 1-14 review round 2 (B-2): the ceiling check, the split, and the
      # case-9 budget check live in ONE place, m14_check (defined above) --
      # no copy of M14_AC_BUDGET or its arithmetic here.
      m14_ac_source="${m14_tokens#ac-source=}"
      local m14_split_json
      m14_split_json=$(m14_check "$m14_ticket_id" "$m14_ac_source")
      claim_budget="$M14_AC_BUDGET"  # SPEC-033 M14(j) -- overrides the generic 10 above
      m14_process_acs_json=$(printf '%s' "$m14_split_json" | jq -c '[.acs[] | select(.process == true) | .id]')
      # SPEC-013 Phase 1 claim record + exact template (WP 1-14 C2). Index i
      # (0-based) runs over the technical-only array, in document order.
      m14_claims_json=$(printf '%s' "$m14_split_json" | jq -c \
        --arg ticket_id "$m14_ticket_id" --arg path "$m14_ac_source" \
        --argjson default_budget "$INVESTIGATOR_TOOL_BUDGET" \
        --argjson verify_budget "$M14_VERIFY_TOOL_BUDGET" '
        [ .acs[] | select(.process == false) ] as $tech
        | [ range(0; ($tech | length)) as $i
            | ($tech[$i]) as $ac
            | {
                claim_id: ("c" + ($i | tostring)),
                ac_id: $ac.id,
                claim: ("[AC-" + $ac.id + "] For " + $ticket_id +
                        ", the diff from the merge-base of the origin default branch and HEAD to HEAD satisfies acceptance criterion " +
                        $ac.id + " as written at " + $path + ":" + ($ac.line | tostring) +
                        ". Read the criterion at that locator and judge this criterion only."),
                source_locator: ($path + ":" + ($ac.line | tostring)),
                claim_type: "factual",
                verify: ($ac.verify // null),
                tool_budget: (if ($ac.verify // null) == null then $default_budget else $verify_budget end)
              }
          ]
        ')
    fi
  fi

  local slug
  case "$scope" in
    claim)   slug="claim" ;;
    session) slug="session${last:+-last-$last}" ;;
    diff)    slug="diff-staged" ;;
    plan)
      # Slug from plan basename (path-safe for report-path validation)
      local base
      base=$(basename -- "$scope_arg")
      base="${base%.*}"
      # POSIX BRE. Strip a leading-dash run without a GNU-only plus.
      slug=$(printf '%s' "$base" | tr -c 'a-zA-Z0-9._-' '-' | sed 's/--*/-/g;s/^-//;s/-$//')
      [ -z "$slug" ] && slug="plan"
      slug="plan-${slug}"
      ;;
    from-retro)
      slug="from-retro-${scope_arg}"
      ;;
    *)       slug="$scope" ;;
  esac
  local report_path
  report_path=$(cmd_report_path "$slug" --task-id "$task_id")

  # Phase 1 prompt: plan scope uses plan-extractor; others use claim-extractor.
  # skip=true for single pasted claim and from-retro (claim already isolated).
  local phase1_prompt="skills/council/prompts/claim-extractor.md"
  if [ "$scope" = "plan" ]; then
    phase1_prompt="skills/council/prompts/plan-extractor.md"
  fi

  # Build the investigation plan JSON for the orchestrating Claude. This is
  # the contract: the Claude that invoked /council reads this document and
  # uses it to drive Phase 1-5 via Task-tool spawns.
  # When --why: include why_detail (CDV-206) for stdout debug after summary.
  # Do not dump raw prompts. phase3_specialist at preflight is a plan stub;
  # commands/council.md overwrites the printed value after runtime classify (CDV-209).
  # from-retro: resolved_claim is fabricated_claim_text; scope_arg remains anchor-id.
  # Phase 3 skip for finding[] (diff-mode): flavors already cover specialist axes.
  # CDT-126 adds a second, independent skip condition: council_tier == light.
  local phase3_skip_reason="" phase3_why_stub
  if [ "$output_shape" = "finding[]" ]; then
    phase3_skip_reason="diff-mode (finding[] flavors cover specialist axes)"
    phase3_why_stub="skipped (diff-mode)"
  elif [ "$council_tier" = "light" ]; then
    phase3_skip_reason="council_tier: light"
    phase3_why_stub="skipped (council_tier: light)"
  else
    phase3_why_stub="pending (runtime classify)"
  fi

  # CDT-126: Phase 4 is keyed off TWO independent conditions — the
  # pre-existing finding[]-shape skip AND council_tier == light. Phase 5's
  # brief inputs and Phase 6's brief report sections follow the same key
  # (SPEC-013 Phases 4/5/6): when Phase 4 did not run, the Judge receives
  # claims + evidence bundles only and no brief is synthesized or stubbed.
  # Empty reason == Phase 4 runs, matching the Phase 3 block just above.
  local phase4_skip_reason=""
  if [ "$output_shape" = "finding[]" ]; then
    phase4_skip_reason="finding[]-shape preset"
  fi
  if [ "$council_tier" = "light" ]; then
    if [ -n "$phase4_skip_reason" ]; then
      phase4_skip_reason="${phase4_skip_reason}; council_tier: light"
    else
      phase4_skip_reason="council_tier: light"
    fi
  fi

  # CDV-211: per-run investigator tool-call cache under TMPDIR.
  # Layout: $cache_dir/{reads,greps}/<sha256>.txt + manifest.json.
  # Correctness unchanged if empty; finalize best-effort rm -rf.
  local cache_dir run_id
  cache_dir=$(mktemp -d "${TMPDIR:-/tmp}/council-cache-XXXXXXXX") \
    || { echo "engine.sh: failed to create council-cache dir under TMPDIR" >&2; exit 2; }
  run_id=$(basename -- "$cache_dir" | sed 's/^council-cache-//')
  mkdir -p "$cache_dir/reads" "$cache_dir/greps"
  printf '%s\n' '{"version":1,"entries":[]}' > "$cache_dir/manifest.json"
  # Drop council-cache dirs older than 24h. Skip the directory just created.
  _cache_parent=$(dirname -- "$cache_dir")
  find "$_cache_parent" -maxdepth 1 -type d -name 'council-cache-*' -mmin +1440 -print 2>/dev/null \
    | while IFS= read -r _old_cache; do
        [ "$_old_cache" = "$cache_dir" ] && continue
        case "$(basename -- "$_old_cache")" in
          council-cache-*) rm -rf -- "$_old_cache" 2>/dev/null || true ;;
        esac
      done

  # CDV-207: optional external investigator detection (never hard-fail on miss).
  # External is additive — plan.flavors (internal) are never reduced.
  local external_json
  if [ "$external" = "true" ]; then
    local EXT_HELPER="$SCRIPT_DIR/external-reviewer.sh"
    local det_json det_status det_tool det_reason
    if [ -x "$EXT_HELPER" ]; then
      # stderr (skip notices) passes through; only stdout is capture-bound.
      det_json=$(bash "$EXT_HELPER" detect --prefer "$external_prefer") \
        || det_json='{"status":"skipped","tool":null,"reason":"detect failed"}'
    else
      det_json='{"status":"skipped","tool":null,"reason":"external-reviewer.sh not found"}'
      echo "engine.sh: external-reviewer.sh not found — skipping external slot" >&2
    fi
    det_status=$(printf '%s' "$det_json" | jq -r '.status // "skipped"')
    det_tool=$(printf '%s' "$det_json" | jq -r '.tool // empty')
    det_reason=$(printf '%s' "$det_json" | jq -r '.reason // empty')
    # Map detect → plan.external (available|skipped). Never exit non-zero here.
    external_json=$(jq -n \
      --arg prefer "$external_prefer" \
      --arg status "$det_status" \
      --arg tool "$det_tool" \
      --arg reason "$det_reason" \
      '{
        requested: true,
        prefer: $prefer,
        status: (if $status == "available" then "available" else "skipped" end),
        tool: (if $tool == "" then null else $tool end),
        reason: $reason,
        helper: "skills/council/external-reviewer.sh",
        flavor: "skills/council/flavors/external.md"
      }')
  else
    external_json='{"requested":false}'
  fi

  jq -n \
    --arg scope "$scope" \
    --arg scope_arg "$scope_arg" \
    --arg resolved_claim "$resolved_claim" \
    --arg last "$last" \
    --arg task_id "$task_id" \
    --arg preset "$preset" \
    --arg output_shape "$output_shape" \
    --argjson flavors "$flavors" \
    --arg spec_grep "$spec_grep" \
    --arg feedback_enabled "$feedback_enabled" \
    --arg confidence_filter "$confidence_filter" \
    --argjson claim_budget "$claim_budget" \
    --arg why "$why" \
    --arg preset_source "$preset_source" \
    --arg slug "$slug" \
    --arg report_path "$report_path" \
    --arg mroot "$MROOT" \
    --arg phase1_prompt "$phase1_prompt" \
    --arg phase3_why_stub "$phase3_why_stub" \
    --arg council_tier "$council_tier" \
    --arg grading_reason "$grading_reason" \
    --arg phase3_skip_reason "$phase3_skip_reason" \
    --arg phase4_skip_reason "$phase4_skip_reason" \
    --arg cache_dir "$cache_dir" \
    --arg run_id "$run_id" \
    --argjson external "$external_json" \
    --arg m14_triggered "$m14_triggered" \
    --argjson m14_claims "$m14_claims_json" \
    --arg m14_ac_source "$m14_ac_source" \
    --argjson m14_process_acs "$m14_process_acs_json" \
    '{
      scope: $scope,
      scope_arg: $scope_arg,
      resolved_claim: $resolved_claim,
      last: $last,
      task_id: $task_id,
      preset: $preset,
      output_shape: $output_shape,
      council_tier: $council_tier,
      grading_reason: $grading_reason,
      flavors: $flavors,
      external: $external,
      spec_grep: ($spec_grep == "true"),
      feedback_memory_enabled: ($feedback_enabled == "true"),
      confidence_filter_threshold: (if $confidence_filter == "null" then null else ($confidence_filter | tonumber) end),
      claim_budget: $claim_budget,
      why: ($why == "true"),
      slug: $slug,
      report_path: $report_path,
      mroot: $mroot,
      run_id: $run_id,
      cache_dir: $cache_dir,
      phases: {
        "1_claim_extraction": { skip: ($scope == "claim" or $scope == "from-retro"), prompt: $phase1_prompt },
        "2_parallel_investigation": { min_flavors_per_claim: 2, prompt: "skills/council/prompts/investigator.md" },
        # Phase 3 (CDV-209): topic classify → at most one team-agent specialist.
        # Runs before Phase 2.5. Skipped for finding[] (diff-mode) and at
        # council_tier: light (CDT-126).
        "3_domain_specialist": (
          if $phase3_skip_reason != ""
          then { deferred: false, skipped: true, reason: $phase3_skip_reason, confidence_threshold: 0.75, max_specialists_per_run: 1, classifier_prompt: "skills/council/prompts/topic-classifier.md", specialist_prompt: "skills/council/prompts/investigator.md" }
          else { deferred: false, skipped: false, confidence_threshold: 0.75, max_specialists_per_run: 1, classifier_prompt: "skills/council/prompts/topic-classifier.md", specialist_prompt: "skills/council/prompts/investigator.md", agents: ["devops", "ds", "qa", "pm"] }
          end
        ),
        # Phase 4 runs for verdict[]-shape presets at council_tier: full.
        # finding[]-shape (diff-mode) routes specialist findings straight to the
        # judge — there is no prosecutor/advocate step. See review-and-commit/SKILL.md
        # ("Phase 4 — skipped in diff-mode") and commands/council.md Phase 4.
        # council_tier: light skips it too (CDT-126) — a second, independent
        # condition, not a restatement of the shape one.
        "4_prosecution_defense": (
          if $phase4_skip_reason == ""
          then { prosecutor: { prompt: "skills/council/prompts/phase4-brief.md", role: "Prosecutor", evidence_field: "evidence_against", flavor: "jaded-senior" }, advocate: { prompt: "skills/council/prompts/phase4-brief.md", role: "Devil\u0027s Advocate", evidence_field: "evidence_for", flavor: "yolo-ic" } }
          else { skipped: true, reason: $phase4_skip_reason }
          end
        ),
        # Judge inputs: claims + evidence bundles ALWAYS; the two Phase-4 briefs
        # only when Phase 4 ran. A skipped Phase 4 is never papered over with a
        # synthesized, stubbed, or empty-string brief (SPEC-013 Phase 5).
        "5_judgment": (
          { agent: "council-judge", prompt: "skills/council/prompts/judge.md" }
          + (if $phase4_skip_reason == ""
             then { inputs: ["claims", "evidence_bundles", "prosecutor_brief", "advocate_brief"] }
             else { inputs: ["claims", "evidence_bundles"], briefs_omitted: true, briefs_omitted_reason: $phase4_skip_reason }
             end)
        ),
        "6_finalize": { invoke: "engine.sh finalize --plan-file <p> --evidence-file <e> --judge-output <j>" }
      }
    }
    | if $m14_triggered == "true" then
        . + { claims: $m14_claims, ac_source: $m14_ac_source, process_acs: $m14_process_acs }
      else .
      end
    | if $why == "true" then
        . + {
          why_detail: {
            preset: $preset,
            flavors: $flavors,
            council_tier: $council_tier,
            grading_reason: $grading_reason,
            phase3_specialist: $phase3_why_stub,
            claim_budget: $claim_budget,
            preset_source: $preset_source,
            external: $external
          }
        }
      else .
      end'
}

