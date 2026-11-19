# council/waves-lib.sh — the waves[] slot + partition helper, sourced by
# engine.sh (CDT-594; SPEC-013 § Spawn concurrency cap → waves[]).
#
# ONE partition home for the Task path. The slice rule mirrors chunkedParallel
# in skills/lib/chunked-parallel.js: contiguous slices of the ordered slot
# list, every batch exactly X slots except a partial last, W <= X -> one batch,
# a non-positive or absent cap -> one batch. That bash/JS pair is the plan's
# COPY-ACCEPTED: divergence-expected pair — parity is asserted by
# skills/council/test-parity-fixtures.sh, not shared code. No third partition.
#
# Slots are index tuples and nothing else:
#   {slot, claim_index, claim_id, flavor, agent, model_pin_source}
# `slot` is 0-based inside its wave. `model_pin_source` is a SPEC-042 rule NAME
# (map | tier-default | p2-literal) — this file never resolves a model string
# and never calls resolve-model.sh; skills/council/model-map.md owns the pins.
# No slot ever carries claim text, prompt text, or artifact bytes.
#
# Pure function definitions only; no side effects at source time. bash + jq
# only, bash 3.2 portable (no associative arrays, no mapfile, no `local -n`).
# Deterministic: no clock, no $RANDOM, no sort the plan does not already carry.
#
# THIS FILE IS SOURCED BY engine.sh. The CLI is `engine.sh waves` (subprocess,
# never sourced) — see skills/council/engine-waves.sh.

# ---- slot builders ----------------------------------------------------------
# waves_slots_phase2_json <claims-json> <flavors-json> -> JSON slot array.
# Order is claim-major, then plan.flavors order (SPEC-013 waves[] slot order).
# claim_id comes from the claim record and is null when the record carries none
# — the null-claim_id slots are the same group Phase 2.5 and finalize use for
# bundles with no claim_id.
waves_slots_phase2_json() {
  jq -nc --argjson claims "$1" --argjson flavors "$2" '
    ($claims | length) as $nc
    | ($flavors | length) as $nf
    | [ range(0; $nc * $nf) as $s
        | ($s / $nf | floor) as $ci
        | { slot: $s,
            claim_index: $ci,
            claim_id: (if ($claims[$ci] | type) == "object" then ($claims[$ci].claim_id // null) else null end),
            flavor: $flavors[($s % $nf)],
            agent: "finder",
            model_pin_source: "map" } ]'
}

# waves_slots_phase25_json <claims-json> <flavors-json> -> JSON slot array.
# One cross-reviewer per investigator bundle in a claim group of >= 3 bundles;
# a group below 3 contributes none. Every claim group holds exactly
# plan.flavors | length investigator bundles, so the group bar is that length.
# The Phase 3 specialist also counts toward the Phase 2.5 bar, but it is a
# runtime (LLM) pick: the emitter stays mechanical and the Phase 2.5 fence
# handles a group the specialist pushes over the bar.
waves_slots_phase25_json() {
  jq -nc --argjson claims "$1" --argjson flavors "$2" '
    ($claims | length) as $nc
    | ($flavors | length) as $nf
    | if ($nf < 3 or $nc == 0) then [] else
      [ range(0; $nc * $nf) as $s
        | ($s / $nf | floor) as $ci
        | { slot: $s,
            claim_index: $ci,
            claim_id: (if ($claims[$ci] | type) == "object" then ($claims[$ci].claim_id // null) else null end),
            flavor: "cross-review",
            agent: "council-scribe",
            model_pin_source: "p2-literal" } ]
    end'
}

# waves_slots_phase3_json <plan-json> -> one specialist slot, or [] when the
# plan skips Phase 3. agent is null: the Phase 3 classifier names the roster
# agent at runtime (SPEC-013 waves[] / AC4).
waves_slots_phase3_json() {
  jq -c '
    if ((.phases."3_domain_specialist".skipped // false) == false)
    then [{ slot: 0, claim_index: null, claim_id: null,
            flavor: "domain-specialist", agent: null, model_pin_source: "map" }]
    else [] end' <<<"$1"
}

# waves_slots_phase4_json <plan-json> -> the Prosecutor + Advocate pair, or []
# when the plan skips Phase 4. Flavors come from the plan's Phase 4 block, so
# the plan stays the single source of the pair.
waves_slots_phase4_json() {
  jq -c '
    .phases."4_prosecution_defense" as $p4
    | if ($p4 != null and ($p4 | has("prosecutor")) and ($p4 | has("advocate")))
      then [ { slot: 0, claim_index: null, claim_id: null,
               flavor: $p4.prosecutor.flavor, agent: "council-scribe", model_pin_source: "p2-literal" },
             { slot: 1, claim_index: null, claim_id: null,
               flavor: $p4.advocate.flavor,  agent: "council-scribe", model_pin_source: "p2-literal" } ]
      else [] end' <<<"$1"
}

# waves_slots_blind <teams> <lenses-csv> -> N + M reviewer slots.
# Team IDs are U1..UN for the unconstrained cohort and L-<lens> for the lens
# cohort (skills/council/phases-blind.md); the tuple has no label field, so the
# team ID rides `flavor`. Not claim-keyed: claim_index and claim_id are null.
waves_slots_blind() {
  local teams="$1" lenses="$2"
  jq -nc --arg teams "$teams" --arg lenses "$lenses" '
    ($teams | tonumber) as $n
    | ($lenses | split(",")) as $ls
    | [ range(0; $n) as $i
        | { slot: $i, claim_index: null, claim_id: null,
            flavor: ("U" + (($i + 1) | tostring)),
            agent: "council-scribe", model_pin_source: "p2-literal" } ]
      + [ range(0; ($ls | length)) as $j
          | { slot: ($n + $j), claim_index: null, claim_id: null,
              flavor: ("L-" + $ls[$j]),
              agent: "council-scribe", model_pin_source: "p2-literal" } ]'
}

# ---- file-argument wrappers (engine.sh waves --plan-file/--claims-file) -----
waves_slots_phase2() {
  waves_slots_phase2_json "$(jq -c '.' "$2")" "$(jq -c '.flavors // []' "$1")"
}

waves_slots_phase25() {
  waves_slots_phase25_json "$(jq -c '.' "$2")" "$(jq -c '.flavors // []' "$1")"
}

waves_slots_phase3() {
  waves_slots_phase3_json "$(jq -c '.' "$1")"
}

waves_slots_phase4() {
  waves_slots_phase4_json "$(jq -c '.' "$1")"
}

# ---- partition --------------------------------------------------------------
# waves_partition <wave> <cap> <slots-json> -> JSON array of batch objects
# {wave, batch, spawns[]}. `batch` is 1-based and contiguous inside the wave.
# A cap that is not a number >= 1 is unbounded: one batch (chunkedParallel's
# cap === 0 path). An empty slot list emits no wave object — a wave object's
# spawns list is always non-empty.
waves_partition() {
  local wave="$1" cap="$2" slots="$3"
  jq -nc --arg wave "$wave" --argjson cap "$cap" --argjson slots "$slots" '
    (if ($cap | type) == "number" and $cap >= 1 then $cap else 0 end) as $c
    | if ($slots | length) == 0 then []
      elif $c == 0 then [{ wave: $wave, batch: 1, spawns: $slots }]
      else [ range(0; ($slots | length); $c) as $i
             | { wave: $wave, batch: ((($i / $c) | floor) + 1), spawns: $slots[$i:($i + $c)] } ]
      end'
}

# waves_append <a-json> <b-json> -> concatenated JSON array.
waves_append() {
  jq -nc --argjson a "$1" --argjson b "$2" '$a + $b'
}

# waves_why <waves-json> -> [{wave, batches, spawns}] for the --why summary.
waves_why() {
  jq -c '
    group_by(.wave)
    | map({ wave: .[0].wave,
            batches: (length),
            spawns: (map(.spawns | length) | add) })' <<<"$1"
}

# ---- plan merges ------------------------------------------------------------
# waves_merge_plan <plan-json> <waves-json> -> plan JSON with the emitted waves
# merged in and every emitted name dropped from waves_pending.
#  * a wave name the emitter emits replaces any wave object of that name
#    already in the plan (a re-run is idempotent);
#  * plan.waves is ordered by the canonical wave order, which is unique per
#    wave name, so the merge is deterministic;
#  * waves_pending is removed when nothing is left pending — the key is present
#    only while something is (same rule as preflight).
waves_merge_plan() {
  jq -c --argjson waves "$2" '
    def rank: {"phase2":0, "phase2.5":1, "phase3":2, "phase4":3, "blind":4};
    ($waves | map(.wave)) as $emitted
    | if ($waves | length) == 0 then . else
        ((.waves // []) | map(select(.wave as $w | ($emitted | index($w)) == null))) as $kept
        | .waves = (($kept + $waves) | sort_by(rank[.wave]))
      end
    | (if (.waves_pending // []) == [] then .
       else (.waves_pending
             = ([.waves_pending[] | select(. as $n | ($emitted | index($n)) == null)]))
       end)
    | (if (.waves_pending // []) == [] then del(.waves_pending) else . end)' <<<"$1"
}

# waves_preflight_plan <plan-json> <claims-json> -> plan JSON with the LLM-free
# waves merged in, waves_pending naming the Phase-1-dependent waves, and
# why_detail.waves when the plan carries why_detail.
#
# Emission rule (AC1/AC4/AC5): emit every wave whose slot set is knowable
# without an LLM. The claim set is known for an M14 split, a single pasted
# claim, and --from-retro (pass those claims); it is not known for the
# transcript-slice, plan, and diff scopes (pass [] and the two waves are named
# in waves_pending instead). A cap-less plan is returned unchanged — unset
# means no waves key at all.
waves_preflight_plan() {
  local plan="$1" claims="$2"
  local cap flavors waves p2 p25 pending why
  cap=$(jq -r 'if ((.concurrency | type) == "number" and .concurrency >= 1)
               then (.concurrency | tostring) else "" end' <<<"$plan")
  if [ -z "$cap" ]; then
    printf '%s\n' "$plan"
    return 0
  fi
  flavors=$(jq -c '.flavors // []' <<<"$plan")
  waves='[]'
  pending='null'
  if [ "$(jq -r 'length' <<<"$claims")" = "0" ]; then
    pending='["phase2","phase2.5"]'
  else
    p2=$(waves_slots_phase2_json "$claims" "$flavors")
    waves=$(waves_append "$waves" "$(waves_partition phase2 "$cap" "$p2")")
    p25=$(waves_slots_phase25_json "$claims" "$flavors")
    waves=$(waves_append "$waves" "$(waves_partition "phase2.5" "$cap" "$p25")")
  fi
  waves=$(waves_append "$waves" "$(waves_partition phase3 "$cap" "$(waves_slots_phase3_json "$plan")")")
  waves=$(waves_append "$waves" "$(waves_partition phase4 "$cap" "$(waves_slots_phase4_json "$plan")")")
  why=$(waves_why "$waves")
  jq --argjson waves "$waves" --argjson pending "$pending" --argjson why "$why" '
    . + (if ($waves | length) > 0 then {waves: $waves} else {} end)
      + (if $pending == null then {} else {waves_pending: $pending} end)
    | (if (.why == true and ($why | length) > 0 and has("why_detail"))
       then .why_detail.waves = $why
       else . end)' <<<"$plan"
}
