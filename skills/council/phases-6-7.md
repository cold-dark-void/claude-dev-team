<!-- /council stage body — load via SKILL.md router; read only the current stage. -->

**Stage anchor (run once per stage; fresh-shell safe):**

```bash
# Locate the dev-team plugin root (PDH). Optional CLAUDE_PLUGIN_ROOT (force path / FR #48230), else cwd only when it is the dev-team plugin itself (CDT-265), else marketplace clone (slug-free agents/pm.md), else installed cache (rank by /dev-team/<VER>/ segment, not full path; CDT-166). CDT-82: marketplace before same-version cache.
# lint-ok: C3 — marketplace */ for-loop + -f guarded (SPEC-021 Q2 residual, CDT-82 PDH)
PDH=$( { [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -f "$CLAUDE_PLUGIN_ROOT/skills/plugin-dir.sh" ] && printf '%s\n' "$CLAUDE_PLUGIN_ROOT"; } || { [ -f skills/plugin-dir.sh ] && [ -f agents/pm.md ] && grep -qF '"name": "dev-team"' .claude-plugin/plugin.json 2>/dev/null && pwd; } || { _pr='${CLAUDE_PLUGIN_ROOT}'; [ "${_pr#\$}" = "$_pr" ] && [ -f "$_pr/skills/plugin-dir.sh" ] && printf '%s\n' "$_pr"; } || { for _mp in "$HOME"/.claude/plugins/marketplaces/*/; do [ -f "${_mp}skills/plugin-dir.sh" ] && [ -f "${_mp}agents/pm.md" ] && printf '%s\n' "${_mp%/}" && break; done; } || find ~/.claude/plugins/cache -path '*/dev-team/*/skills/plugin-dir.sh' 2>/dev/null | awk -F/ '{ver=""; for(i=1;i<=NF;i++) if($i=="dev-team"&&i<NF){ver=$(i+1);break}; if(ver=="") next; m=ver; gsub(/-pre\./,"~pre.",m); p=($0 ~ /\/cache\/cold-dark-void\/dev-team\//)?1:0; print m "\t" p "\t" $0}' | sort -t $'\t' -k1,1V -k2,2n -k3,3 | tail -1 | cut -f3 | xargs -r dirname | xargs -r dirname )
printf 'PDH=%s\n' "$PDH" >&2
```

### Phase 6 — Report & Persistence

**Canonical report path:**

- Unbound: `.claude/council/<YYYY-MM-DD>-<slug>[-<N>].md`
- Task-bound: `.claude/council/<YYYY-MM-DD>-<slug>--<task_id>[-<N>].md`

(SPEC-013 § Council tiering.)

`<slug>` is a short kebab-case tag derived from the scope (e.g.
`session-last-20`, `diff-staged`, `claim-<first-5-words>`). The engine MUST
create the `.claude/council/` parent directory if absent. The engine MUST
resolve `$MROOT` with the shared-root formula (git common dir, not the
linked worktree; SPEC-013 § Council tiering):

```
_gc=$(git rev-parse --git-common-dir 2>/dev/null) \
  && MROOT=$(cd "$(dirname "$_gc")" && pwd) \
  || MROOT=$(pwd)
```

**Report no-overwrite (WP 1-14; SPEC-013 Phase 6):** the engine MUST NOT
overwrite an existing report or its `.finalize-meta.json` sidecar, in every
scope that resolves its path through `cmd_report_path`. `engine.sh
report-path` and preflight only probe the first free candidate (report AND
sidecar both absent); finalize reserves that candidate again with an
exclusive create before it writes, retries `-2`..`-99` on a collision, and
exits `9` when exhausted. `finalize --report-out PATH` is the one exception:
it keeps writing exactly `PATH` and can overwrite it, because the caller
that passes `--report-out` owns that risk.

**Finalize-meta sidecar (WP 1-14; SPEC-013 Phase 6 "Finalize-meta sidecar"):**
finalize writes `<report>.finalize-meta.json` next to the report, at the
same reserved path, and keeps its pre-WP-1-14 keys. It adds
`min_verdict_confidence`, `verdict_counts`, `verification_mode` and
`unstruck_verdicts`. `min_verdict_confidence`, `verdict_counts` and
`unstruck_verdicts` are `null` for `finding[]` runs (`min_verdict_confidence`
is also null when zero verdicts are unstruck); `verification_mode` is always
`full` or `self-verified`. An M14 per-AC-split run also adds `ac_source`,
`ac_claims` and `process_acs`, copied from the plan. Finalize never matches
verdicts to ACs — SPEC-033 M14(b)/(i) owns that mapping, in
`skills/autopilot/ship-gate-verdict.sh`.

**Report frontmatter (YAML):** templates own the FM shape
(`templates/report-verdict.md` / `templates/report-finding.md` carry a single
YAML block with placeholders). Finalize substitutes `{{…}}` in-place and does
**not** prepend a second synthetic frontmatter block (CDV-203).

```yaml
scope: "{{SCOPE}}"
preset: "{{PRESET}}"
output_shape: "verdict[]"   # or "finding[]" hard-coded per template
created_at: "{{TIMESTAMP}}"
verification_mode: "{{VERIFICATION_MODE}}"
council_tier: "{{COUNCIL_TIER}}"
grading_reason: "{{GRADING_REASON}}"
task_id: "{{TASK_ID}}"
```

**Substitution is ONE non-recursive pass** (`re.sub` over
`\{\{[A-Z0-9_]+\}\}`, unknown names → `""`) — never a per-var chain of
`str.replace`. Several substituted values are untrusted (`grading_reason` is
free text from the tier-triage model; the cross-review values come from
subagents), and a sequential chain lets a value substituted early carry a
literal `{{LATER_VAR}}` that a later iteration expands — a template-injection
primitive that put attacker-chosen multi-line content raw inside the YAML
fences. Values bound for a quoted FM scalar are additionally escaped
(`yaml_dq`: backslash, quote, CR/LF).

After substitution (bound):

```yaml
scope: "<claim | session | plan | diff | from-retro>"
preset: "<preset-name>"
output_shape: "<verdict[] | finding[]>"
created_at: "<ISO-8601 UTC>"
verification_mode: "<full | self-verified>"
task_id: "<id>"
```

The `task_id` field MUST be absent when unbound — not null, not empty
string. Finalize **strips** the empty `task_id:` line after substituting an
empty `{{TASK_ID}}` so the key never appears. (SPEC-013 Task Binding.)
`verification_mode` is always present: `full` (default) or `self-verified`
(spawn-failure degradation; see above).

**Optional token frontmatter (CDV-204):** when finalize receives a usable
`--tokens-file`, it injects additive keys (not present in the template when
tokens are unavailable):

```yaml
tokens_total: <int>
tokens_by_phase:
  1_claim_extraction: <int>
  2_parallel_investigation: <int>
  # …
```

When the tokens file is missing, empty, `source: unavailable`, or has no
positive phase/total ints, these keys are **omitted** entirely. Never write
`0` as if it were measured usage. Does **not** alter `index.json` schema.

**Report body (branches on output shape):**

Both shapes MUST include: scope, extracted claims (or candidate findings),
investigator flavors used, evidence bundles (inlined raw blobs), Prosecutor
brief, Devil's Advocate brief, per-claim verdict or per-finding entry with
confidence + raw evidence, a **struck-lines audit trail** section.
(SPEC-013 § Council tiering.)

- `verdict[]` template (`templates/report-verdict.md`): verdict summary
  grouped by taxonomy (VERIFIED / PARTIALLY_VERIFIED / UNVERIFIED /
  CONTRADICTED / FABRICATED counts).
- `finding[]` template (`templates/report-finding.md`): findings summary
  grouped by severity (critical / warning / nitpick counts).

(SPEC-013 § Council tiering.)

**Stdout summary (engine prints this after writing the report):**

```
Council report: <relative path>
Scope: <scope>
Preset: <preset> (<output_shape>)
council_tier=<tier> (<grading_reason>)   # CDT-126; only when tier != full
verification_mode=<full|self-verified>
<verdict counts OR finding counts by severity>
<struck lines count>

Tokens:                         # CDV-204; only when --tokens-file usable
  <phase_key>: <int>
  Total: <int>
```

(SPEC-013 § Council tiering; CDV-199 adds `verification_mode=`; CDV-204 optional Tokens;
CDT-126 adds `council_tier=` — printed only when the run graded to `light`,
never for `full`, keeping `full`'s stdout byte-identical.)

**Tokens file contract (`--tokens-file`, CDV-204):**

```json
{
  "phases": {
    "1_claim_extraction": 2341,
    "2_parallel_investigation": 47182,
    "4_prosecution": 8210,
    "4_advocate": 7943,
    "5_judge": 12556
  },
  "total": 78232,
  "source": "task_envelope"
}
```

Graceful rules (exit 0 always for token issues — never fail the run):
1. No `--tokens-file` → no Tokens section, no FM token keys
2. `source: "unavailable"` or all null/≤0 → omit section (do not invent `0`)
3. `source: "partial"` or partial phases → print known rows + Total of known;
   header `Tokens (partial):`
4. Task/Workflow envelope fields are **best-effort** — orchestrator fills the
   file; finalize only accepts this simple int map

`commands/council.md` collects usage after Task spawns and passes the file.
`/status metrics` (CDV-187) is a later display-only consumer of this write path.

**`--why` debug (CDV-206; SPEC-013 SHOULD):** When preflight receives
`--why`, the investigation plan sets `why: true` and includes a
`why_detail` object (absent when the flag is off):

```json
{
  "why": true,
  "why_detail": {
    "preset": "generic",
    "flavors": ["paranoid-ic", "skeptic-ic"],
    "phase3_specialist": "pending (runtime classify)",
    "claim_budget": 10,
    "preset_source": "inferred"
  }
}
```

- `preset_source` is `explicit` when `--preset` was passed, else `inferred`.
- `phase3_specialist` preflight stubs: `"pending (runtime classify)"` for
  `verdict[]`, `"skipped (diff-mode)"` for `finding[]`. After Phase 3,
  `commands/council.md` prints the runtime reason instead, e.g.
  `"devops (topic=deploy conf=0.91)"`, `"skipped (no confident match)"`,
  `"skipped (diff-mode)"`, `"skipped (council_tier: light)"`, or
  `"skipped (classifier unusable)"`.
- `commands/council.md` Step 5 prints a short labeled block from these fields
  after the stdout summary (after any Tokens block). No raw prompt dumps. No
  verdict impact.

**M14 per-AC split (WP 1-14; SPEC-013 Phase 1 "M14 per-AC split"; SPEC-033
M14(g)):** when the plan is split into per-AC claims, it carries optional
keys — `claims` (one record per technical AC, `ac_id` + `claim_id: c<i>`),
`ac_source` (the spec path) and `process_acs` (the `[process]` AC ids) — on
top of the fields above. `claim_budget` becomes the SPEC-033 M14(j) value
instead of `10`. This SKILL cites those specs for the split and the
verdict-mapping policy rather than restating them; see `skills/council/
m14-ac-split.sh` and `skills/autopilot/ship-gate-verdict.sh`.

**Index writer (task-bound runs only):**

After the report file is written, the engine MUST append a row to
`.claude/council/index.json` by shelling out to
`skills/council/index-writer.sh`. The engine MUST NOT
open, read, or write `index.json` directly — `index-writer.sh` is the sole
writer and owns the atomic tmp+rename + `flock` semantics. (SPEC-013 § Council tiering.)

Index row schema (produced by `index-writer.sh`):

```json
{
  "report_path": "<absolute or MROOT-relative path>",
  "max_verdict_confidence": <int 0..100 | null>,
  "max_finding_confidence": <int 0..100 | null>,
  "max_verified_confidence": <int 0..100 | null>,
  "worst_verdict": "<taxonomy term | null>",
  "created_at": "<ISO-8601 UTC>",
  "council_tier": "light | full",
  "grading_reason": "<why that tier was selected>"
}
```

`council_tier` / `grading_reason` (CDT-126) come from the plan JSON that
`preflight` emitted; finalize passes them to `index-writer.sh` as argv 5 and 6.
They are orthogonal to `verification_mode` — the tier says which roles the run
*intended* to run, `verification_mode` says whether they actually ran.

Per-shape population rule:
- `verdict[]` runs: `max_verdict_confidence` = `max(confidence)` across all
  unstruck verdicts; `max_finding_confidence = null`.
  `max_verified_confidence` = max confidence over unstruck `VERIFIED` and
  `PARTIALLY_VERIFIED` only (null when none). `worst_verdict` is the worst
  unstruck verdict (`FABRICATED` > `CONTRADICTED` > `UNVERIFIED` >
  `PARTIALLY_VERIFIED` > `VERIFIED`).
- `finding[]` runs: `max_finding_confidence` = `max(confidence)` across all
  unstruck findings; `max_verdict_confidence = null`. `worst_verdict` and
  `max_verified_confidence` are null. (SPEC-013 § Council tiering.)
  Findings below `confidence_filter_threshold` are struck (the reason names
  the threshold). Verdict rows are not filtered by that threshold.

**Index confidence normalization (CDT-181):** engine max pipelines end with
`| floor` so argv is integer text; `index-writer.sh` also floors float argv
defense-in-depth. Stored row conf fields are **int 0..100 or null only** —
never float. (SPEC-013 Index confidence normalization / CDT-181.)

The TaskCompleted hook (SPEC-002) reads this index as its single source of
truth and applies a **dual-shape** pass: non-null `max_verdict_confidence`
**or** null verdict conf + non-null `max_finding_confidence`, with effective
score ≥ `council.taskgate.min_confidence`. A task-bound `finding[]` row
therefore **can** satisfy `requires_council: true` when finding conf clears
the threshold (CDT-122). Product task-gate policy still prefers claim scope
(`/council "<CLAIM>"`); `--diff` is not the orchestrated default. Rows with
both confidences null still fail. Full algorithm is authoritative in
SPEC-002; this SKILL does not re-specify it.

**Hard rule:** The engine MUST NOT fall back to filename scanning of
`.claude/council/*.md` if the index is missing or unreadable. A missing
index row is a hard miss. (SPEC-013 § Council tiering.)

### Phase 7 — Learning Loop (Feedback Memory)

**Status: DEFERRED (CDT-325).** The engine does not run Phase 7. It does not
write `$MROOT/.claude/memory/claude/lessons.md`. `feedback_memory_enabled`
on the plan is reserved and has no effect until Phase 7 is implemented.
The notes below are the deferred contract, not current behavior.

**Deferred scope:** `verdict[]`-shape presets only. `finding[]`-shape presets
(i.e. `diff-mode`) must not trigger feedback memory writes.
(SPEC-013 § Council tiering.)

**Trigger thresholds (configurable via `.claude/settings.json`):**

| Setting key | Default | Trigger |
|---|---|---|
| `council.feedback.fabricated_min` | 70 | Auto-write on `verdict == FABRICATED && confidence >= 70` |
| `council.feedback.unverified_min` | 85 | Auto-write on `verdict == UNVERIFIED && confidence >= 85` |

(SPEC-013 § Council tiering.)

**Feedback memory entry structure (required fields):**

```
- claim: "<verbatim false claim>"
- contradicting_evidence: "<raw blob excerpt + tool_use_id>"
- should_have_run: "<the tool + command that would have caught this>"
- Why: "<one-line explanation of the failure mode>"
- How to apply: "<one-line rule the agent should adopt>"
```

(SPEC-013 § Council tiering.)

**Routing:**
- **Plain-Claude subject** (no team agent authored the claim): append the
  entry to `$MROOT/.claude/memory/claude/lessons.md`. (SPEC-013 § Council tiering.)
- **Team-agent subject** (claim authored by pm / tech-lead / ic5 / ic4 /
  devops / qa / ds): route through `/adjust-agent <agent> --apply` — this
  preserves SPEC-001 conflict detection and SPEC-012 routing convention.
  The engine MUST NOT write directly to `.claude/memory/<agent>/directives.md`.
  (SPEC-013 § Council tiering.)

Detection of "who authored the claim" is done at Phase 1 extraction time
using source locators (turn metadata / agent attribution on the transcript
slice). When authorship is ambiguous, default to plain-Claude routing.

---
