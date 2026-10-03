<!-- /council stage body — load via SKILL.md router; read only the current stage. -->

**Stage anchor (run once per stage; fresh-shell safe):**

```bash
# Locate the dev-team plugin root (PDH). Optional CLAUDE_PLUGIN_ROOT (force path / FR #48230), else cwd only when it is the dev-team plugin itself (CDT-265), else marketplace clone (slug-free agents/pm.md), else installed cache (rank by /dev-team/<VER>/ segment, not full path; CDT-166). CDT-82: marketplace before same-version cache.
# lint-ok: C3 — marketplace */ for-loop + -f guarded (SPEC-021 Q2 residual, CDT-82 PDH)
PDH=$( { [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -f "$CLAUDE_PLUGIN_ROOT/skills/plugin-dir.sh" ] && printf '%s\n' "$CLAUDE_PLUGIN_ROOT"; } || { [ -f skills/plugin-dir.sh ] && [ -f agents/pm.md ] && grep -qF '"name": "dev-team"' .claude-plugin/plugin.json 2>/dev/null && pwd; } || { _pr='${CLAUDE_PLUGIN_ROOT}'; [ "${_pr#\$}" = "$_pr" ] && [ -f "$_pr/skills/plugin-dir.sh" ] && printf '%s\n' "$_pr"; } || { for _mp in "$HOME"/.claude/plugins/marketplaces/*/; do [ -f "${_mp}skills/plugin-dir.sh" ] && [ -f "${_mp}agents/pm.md" ] && printf '%s\n' "${_mp%/}" && break; done; } || find ~/.claude/plugins/cache -path '*/dev-team/*/skills/plugin-dir.sh' 2>/dev/null | awk -F/ '{ver=""; for(i=1;i<=NF;i++) if($i=="dev-team"&&i<NF){ver=$(i+1);break}; if(ver=="") next; m=ver; gsub(/-pre\./,"~pre.",m); p=($0 ~ /\/cache\/cold-dark-void\/dev-team\//)?1:0; print m "\t" p "\t" $0}' | sort -t $'\t' -k1,1V -k2,2n -k3,3 | tail -1 | cut -f3 | xargs -r dirname | xargs -r dirname )
printf 'PDH=%s\n' "$PDH" >&2
```

### Phase 3 — Domain Specialist (CDV-209)

**Status:** Live for `verdict[]`-shape runs at `council_tier: full`. Skipped in
`finding[]` (diff-mode) and at `council_tier: light` (CDT-126).

**When:** After Phase 2, **before** Phase 2.5. Plan key
`phases.3_domain_specialist`: `deferred: false`, `confidence_threshold: 0.75`,
`max_specialists_per_run: 1`, `classifier_prompt` →
`skills/council/prompts/topic-classifier.md`, `specialist_prompt` →
`skills/council/prompts/investigator.md`. Diff-mode plan sets
`skipped: true` with reason `diff-mode (finding[] flavors cover specialist axes)`;
a `light` `verdict[]` plan sets `skipped: true` with reason `council_tier: light`.

**Classify:** one cheap Task per claim (`topic-classifier.md`, `{{CLAIM_TEXT}}`
only). Output `{topic, confidence, agent}` with
`agent ∈ {devops, ds, qa, pm, null}`.

**Pull rules (orchestrator):**
- MUST pull when `agent != null` and `confidence >= 0.75` (SPEC-013 topic map:
  deploy→devops, metrics→ds, test→qa, product→pm).
- MUST NOT pull on weak signal (below threshold or `topic: none`).
- Cap **1 specialist per run** — highest confidence among eligible claims.
- Specialist is an additional blind investigator: `subagent_type:
  "dev-team:<agent>"`, same evidence-bundle schema as Phase 2, domain lens via
  `{{FLAVOR_DELTA}}`. MUST NOT read prior council reports.

**Downstream:** specialist bundles merge into the Phase 2 set before Phase 2.5
(and Phase 4/5). Empty pull is normal — not an error.

*Traceability:* SPEC-013 Phase 3; `commands/council.md` Phase 3 dispatch.

### Phase 4 — Prosecution & Defense

**Applies to `verdict[]`-shape runs at `council_tier: full`.** Phase 4 is
**skipped** on two independent conditions, and the plan JSON emits
`4_prosecution_defense: {skipped: true, reason: <why>}` in either case:

| Condition | `reason` |
|---|---|
| `finding[]`-shape preset (diff-mode) — specialist findings route directly to the Judge | `finding[]-shape preset` |
| `council_tier: light` (CDT-126) | `council_tier: light` |
| both (a `light` diff-mode run) | `finding[]-shape preset; council_tier: light` |

See `skills/review-and-commit/SKILL.md` ("Phase 4 — skipped in diff-mode").
When Phase 4 is skipped there is no brief: Phase 5's Judge inputs and Phase 6's
report sections are Phase-4-conditional (below), and the engine never
synthesizes, stubs, or empty-strings a brief the run did not produce.

**Spawn contract (verdict[]-shape):**
- Spawn exactly **one** Prosecutor (flavor: `jaded-senior`) and exactly
  **one** Devil's Advocate (flavor: `yolo-ic`) per council run, in parallel.
  (SPEC-013 § Council tiering.) Spawn `subagent_type: "dev-team:council-scribe"`
  (`tools: ""`). Do not spawn `ic5`.
- Both roles are **BLIND to the original claims.** They receive **ONLY the
  evidence bundles** — not the original claim list, not the prior narrative,
  not each other's output. Each role reconstructs the set of claims under
  audit from the `claim_id` carried inside each bundle; it is never handed a
  separate claims list. Prosecution and defense operate on evidence alone.
  (SPEC-013 § Council tiering.)

**Output contract:**
- Prosecutor produces a brief: each claim → evidence against → requested
  verdict.
- Advocate produces a brief: each claim → evidence supporting → requested
  verdict.
- Both roles MUST NOT assert a fact unbacked by an investigator
  `tool_use_id`. Any such line MUST be struck by the engine before Phase 5.
  (SPEC-013 § Council tiering.)

The single role-parameterized prompt template `prompts/phase4-brief.md`
encodes these constraints; the engine spawns it twice (as Prosecutor and as
Devil's Advocate).

### Phase 5 — Judgment

**Agent:** `agents/council-judge.md`. Structurally
forbidden from running tools via `tools: ""` in YAML frontmatter. (SPEC-013 § Council tiering.) **Model map:** resolve `council-judge` first (canonical
fence in § Model map). Mapping its model MUST NOT add tools.

**Engine passes to the Judge** (plan key `phases.5_judgment.inputs` is the
authoritative per-run list):
1. Original claims (the list from Phase 1, not narrative summaries) — **always**
2. Evidence bundles (all bundles from Phase 2 + optional Phase 3 specialist) — **always**
3. Prosecutor brief (post-strike) — **only when Phase 4 ran**
4. Devil's Advocate brief (post-strike) — **only when Phase 4 ran**
5. Output shape flag (`verdict[]` or `finding[]`, from the active preset)

Items 3–4 are Phase-4-conditional. When Phase 4 was skipped the plan drops
them from `inputs` and sets `briefs_omitted: true` plus
`briefs_omitted_reason`; the Judge receives claims + bundles only. Passing an
empty, placeholder, or reconstructed brief in their place is forbidden.

**Engine expects from the Judge:**

The verdict / finding / evidence schema below is the operational copy; the
canonical schema is normatively defined in
`specs/core/SPEC-013-adversarial-council-tribunal.md`.

For `verdict[]`-shape runs, a list of records:

```
verdict := {
  claim: string,                                             // original claim text
  verdict: "VERIFIED" | "PARTIALLY_VERIFIED" | "UNVERIFIED"
         | "CONTRADICTED" | "FABRICATED",
  confidence: integer 0..100,
  evidence_blob: string                                      // raw inline blob
}
```

For `finding[]`-shape runs (diff-mode), a list of records:

```
finding := {
  file: string,
  line: integer,
  severity: "critical" | "warning" | "nitpick",
  category: string,                                          // from specialist flavor
  description: string,
  suggestion: string,
  confidence: integer 0..100,
  tool_use_id: string                                        // MANDATORY
}
```

The fixed taxonomies above are enforced by the engine: any verdict with a
value outside the five-term set MUST be rejected and struck; any finding
with a severity outside the three-term set MUST be struck. (SPEC-013 § Council tiering.)

**Strike rule (engine-enforced after Judge returns):**
- Any verdict or finding line missing an inline raw evidence blob MUST be
  struck. (SPEC-013 § Council tiering.)
- Any line whose quoted citation does not appear verbatim in the provided
  raw blob MUST be struck.
- Any line missing a `tool_use_id` (for findings) MUST be struck. (SPEC-013 § Output Shapes.) Absent, `null`, empty, or whitespace-only `tool_use_id` counts as
  missing (after strip). Engine-generated strike reasons APPEND to pre-existing
  `struck_lines` (never replace). Strike-and-continue (exit 0); do not invent
  IDs; do not exit 7 for missing tid.
- Any line making a factual assertion not traceable to any evidence bundle
  MUST be struck.
- Struck lines MUST be preserved in an "audit trail" section of the report,
  never silently dropped. (SPEC-013 § Council tiering; treated as hard AC.)

The Judge reasoning is documented in `agents/council-judge.md` and the
`prompts/judge.md` template. This SKILL only documents what the engine
passes to and expects from the Judge — not how it decides.
