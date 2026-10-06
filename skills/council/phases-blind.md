<!-- /council stage body — load via SKILL.md router; read only the current stage. -->

**Stage anchor (run once per stage; fresh-shell safe):**

```bash
# Locate the dev-team plugin root (PDH). Optional CLAUDE_PLUGIN_ROOT (force path / FR #48230), else cwd only when it is the dev-team plugin itself (CDT-265), else marketplace clone (slug-free agents/pm.md), else installed cache (rank by /dev-team/<VER>/ segment, not full path; CDT-166). CDT-82: marketplace before same-version cache.
# lint-ok: C3 — marketplace */ for-loop + -f guarded (SPEC-021 Q2 residual, CDT-82 PDH)
PDH=$( { [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -f "$CLAUDE_PLUGIN_ROOT/skills/plugin-dir.sh" ] && printf '%s\n' "$CLAUDE_PLUGIN_ROOT"; } || { [ -f skills/plugin-dir.sh ] && [ -f agents/pm.md ] && grep -qF '"name": "dev-team"' .claude-plugin/plugin.json 2>/dev/null && pwd; } || { _pr='${CLAUDE_PLUGIN_ROOT}'; [ "${_pr#\$}" = "$_pr" ] && [ -f "$_pr/skills/plugin-dir.sh" ] && printf '%s\n' "$_pr"; } || { for _mp in "$HOME"/.claude/plugins/marketplaces/*/; do [ -f "${_mp}skills/plugin-dir.sh" ] && [ -f "${_mp}agents/pm.md" ] && printf '%s\n' "${_mp%/}" && break; done; } || find ~/.claude/plugins/cache \( -path '*/dev-team/*/skills/plugin-dir.sh' -o -path '*/dev-team-edge/*/skills/plugin-dir.sh' \) 2>/dev/null | awk -F/ '{ver=""; for(i=1;i<=NF;i++) if(($i=="dev-team"||$i=="dev-team-edge")&&i<NF){ver=$(i+1);break}; if(ver=="") next; m=ver; gsub(/-pre\./,"~pre.",m); p=($0 ~ /\/cache\/cold-dark-void\/dev-team\//)?2:(($0 ~ /\/cache\/cold-dark-void\/dev-team-edge\//)?1:0); print m "\t" p "\t" $0}' | sort -t $'\t' -k1,1V -k2,2n -k3,3 | tail -1 | cut -f3 | xargs -r dirname | xargs -r dirname )
printf 'PDH=%s\n' "$PDH" >&2
```

### Workflow execution path *(CDV-196)*

Optional second transport for Phases 1–5. **Default remains** the Task-spawn
path documented above plus `engine.sh` preflight/finalize. Workflow activates
only on explicit opt-in.

| Opt-in | Behavior |
|--------|----------|
| neither `--workflow` nor `COUNCIL_WORKFLOW=1` | engine.sh + Task path only (byte-for-byte today) |
| `--workflow` **or** `COUNCIL_WORKFLOW=1` | capability probe → Workflow path if available |
| opt-in + probe fail / Workflow unavailable | stderr `council: Workflow unavailable; falling back to engine.sh` → Task path; **not** a degraded report (`verification_mode: full`) |
| opt-in + `council_tier: light` (CDT-126) | stderr `council: council_tier=light unsupported on the Workflow path; falling back to engine.sh` → Task path. `workflow.js` prints that same line and exits 2 if invoked with `light`. The Workflow path is `full`-only. Never a silent upgrade to `full`. |
| `COUNCIL_WORKFLOW_FORCE_FALLBACK=1` | forces probe fail (test harness) |

**Driver:** `skills/council/workflow.js` (schemas in `workflow-schemas.js`).
Capability probe: `skills/council/workflow-probe.sh`.

**Shared finalize (parity):** Workflow path writes handoff JSON under
`council-wf-*` in TMPDIR, then removes that directory on every exit
(including exit 2). It calls existing:

```
engine.sh finalize --plan-file P --evidence-file E --judge-output J
  [--verification-mode full|self-verified]
  [--cross-review-status …] [--cross-review-rankings …] [--cross-review-scores …]
  [--tokens-file PATH]
```

No dual report/index renderers. Downstream (TaskCompleted, `/retro`) cannot
tell which path produced a run.

**No PYREPAIR on Workflow path:** schema-forced `agent()` output only. Schema
violation → step failure → retry-or-self-verify (CDV-199), never silent repair.
The engine.sh Task path keeps `repair_json_file` / `PYREPAIR` for free-form JSON.

**Judge tool-less:** judgment step uses `agentType: 'dev-team:council-judge'`
(plugin-qualified as installed); empty tools from `agents/council-judge.md`.

**Single-source prompts/flavors:** `workflow.js` loads `prompts/*` and
`flavors/*` at runtime and substitutes the same `{{VARS}}` as
`commands/council.md` / each prompt's `## Variables` table. No forked bodies.

**CDV-199 degradation:** on unusable `agent()` result, the workflow driver
(orchestrator-equivalent) performs the missing role's work (never grant tools
to a judge persona) and passes `--verification-mode self-verified` to finalize.
Marker string is rendered only by engine finalize — `workflow.js` MUST NOT
retype `self-verified — refuters unavailable`. See § Spawn-failure degradation.

**Args guard (shared with CDV-197):**
`typeof args === 'string' ? JSON.parse(args) : args` — Workflow may deliver
arguments as a JSON-encoded string. Distinct from CDV-197 (`/debug ticket`
promotion); share convention only.

**Token summary (SHOULD, CDV-204):** both paths feed optional per-phase usage
into shared finalize via `--tokens-file` (see Phase 6). Workflow passes
`--tokens-file` only when the caller already has a tokens file. It does not
invent one. Task path is best-effort envelope scrape.
Missing harness fields → omit Tokens block (never invent `0`).

**Phase 3 and `--external` (CDT-275):** workflow does not run them. If the
caller sets `phase3` or `external`, `workflow.js` prints one stderr line
`council: Phase 3 and --external are the Task path (commands/council.md)`
and exits 2 before it writes a handoff. Use `commands/council.md`. Do not
treat a workflow report as having run those options.

**Callers:** `commands/council.md` and `skills/review-and-commit/SKILL.md`
honor the same opt-in + fallback. Diff-mode (`finding[]`) skips Phase 4 on
both paths.

*Traceability:* SPEC-013 Council-on-Workflow execution path (CDV-196).

### Blind-review path (`--blind`, CDT-46-C3)

Absorbs the former `/blind-review` multi-team peer-review engine into
`/council` as a first-class **scope flag**. Distinct execution path: does
**not** run tribunal Phases 1–5, does **not** call `engine.sh`
preflight/finalize, does **not** use Workflow. Clustering + confidence
tiering **is** the council verdict for this path.

**Entry:** `commands/council.md` Step 0.5 routes `--blind` here and skips
Steps 1–6 tribunal. Dispatch surface + substitutions live in
`commands/council.md` § Blind-review path.

**Spawn contract:**
- **N unconstrained** reviewers (`--teams`, default 3); team IDs `U1..UN`;
  prompt `prompts/blind-scribe.md` on `dev-team:council-scribe` (tool-less).
  Bug-hunt still uses `prompts/unconstrained-reviewer.md`.
- **M lens-differentiated** reviewers (`--lenses`, default
  `security,contributor,spec`); team IDs `L-<lens>`; same
  `prompts/blind-scribe.md` with `{{FLAVOR_DELTA}}` = lens-delta paragraph
  (value is **not** a tribunal flavor file — see Lens delta library below).
  Bug-hunt still uses `prompts/lens-reviewer.md`.
- Available lenses: `security`, `contributor`, `spec`, `architecture`, `logic`
- **Single parallel wave** for all N+M reviewers — never sequential fan-out
- File list from `--target <path>` when set, else full project tracked files
  under WTROOT (`skills/council/blind-file-list.sh`; not MROOT). Same
  lockfile/vendor excludes on `--target` and on the full tree. Empty list
  fails loud. An untracked target falls through to `find`.
- After collection: namespace findings with team ID; drop malformed (missing
  Category/Severity/Files/Claim/Evidence — no repair)
- Spawn **one** quorum analyst (`prompts/quorum-analyst.md`) over all
  namespaced findings → semantic clusters with tiers

**Confidence tiers:**
| Tier | Condition |
|------|-----------|
| 1 | Cross-cohort (≥1 unconstrained AND ≥1 lens) AND ≥2 distinct teams |
| 2 | Same-cohort consensus (≥2 teams, not cross-cohort) |
| 3 | Single-team minority |

**SEVER Tier-1 self-recursion (mandatory):** Tier-1 consensus clusters emit
**directly as council findings** in the blind-path report. MUST NOT invoke
`/council`, MUST NOT re-enter the tribunal pipeline, MUST NOT reverse-validate
via a nested council run. The former `--no-council` flag is removed — there
is nothing to skip. Tier 2 and Tier 3 appear in the report without a second
pass.

**Report:** written at the path `engine.sh report-path <slug>` returns,
`.claude/council/<YYYY-MM-DD>-<slug>[-<N>].md` under shared MROOT (git
common dir, not the linked worktree); create parent if absent. Contents: scope/target, team manifest, tiered
clusters (claim, evidence, severity, category, team count, source finding
IDs), quorum summary, per-team summaries, dropped-malformed count.
**Output shape:** findings-shaped for presentation; TaskCompleted MUST treat
blind-path runs as **gate-ignored** — prefer unbound reports (no `task_id` /
no qualifying index row). Reason is unbound / no qualifying row / both-null
conf, **not** "the hook ignores `finding[]`" (tribunal `finding[]` rows with
non-null `max_finding_confidence` are dual-shape pass signals per SPEC-002).
Do not write an index row that satisfies `requires_council`.

**Hard fails:** `--teams`/`--lenses`/`--target` without `--blind`; `--blind`
combined with another scope; unknown lens; missing target path; non-positive
`--teams`.

#### Lens delta library

Inject the matching paragraph as `{{FLAVOR_DELTA}}` in `blind-scribe.md`
(council) and in `lens-reviewer.md` (bug-hunt).

**security**
```
You are reviewing from an attacker's perspective. Your mental model: what
inputs are unvalidated or unescaped? Look for injection risks (SQL, shell,
HTML/XSS, path traversal, template injection), broken authentication or
authorization, insecure deserialization, sensitive data exposure, hardcoded
secrets, race conditions under concurrent access, and places where the system
silently does the wrong thing instead of failing loudly. Trust boundaries
between components matter too. Security is your angle — but you review
EVERYTHING, not just security-adjacent files.
```

**contributor**
```
You just cloned this repo and need to understand and use it. Your mental model:
what is missing from documentation? What is inconsistent between similar
commands or components? What would trip up someone new? Are cross-references
between files correct? Are setup instructions complete? Is error output
helpful? Contributor experience is your angle — but you review EVERYTHING.
```

**spec**
```
You are checking whether the code honours its stated contracts. "Contracts"
means whatever the project uses to describe intended behaviour: formal spec
files, README guarantees, OpenAPI/JSON Schema definitions, docstrings,
inline comments that say "always", "never", "must", or "guaranteed". Your
mental model: find the gap between what is promised and what is delivered.
Flag missing implementations, contradictions between contract documents, and
code behaviour that is undocumented or contradicts the stated contract.
Contract compliance is your angle — but you review EVERYTHING.
```

**architecture**
```
You are evaluating design soundness. Your mental model: are abstractions at
the right level? Are responsibilities correctly separated? Is there tight
coupling that will cause maintenance pain? Are there design patterns that
are applied inconsistently? Architecture is your angle — but you review
EVERYTHING.
```

**logic**
```
You are hunting correctness bugs. Your mental model: off-by-ones, wrong
operator precedence, variables used before assignment, dead code paths,
error handling that swallows failures, race conditions, incorrect assumptions
about data types or ranges. Logic correctness is your angle — but you review
EVERYTHING.
```

*Traceability:* SPEC-013 Blind-review path (CDT-46-C3); Test 22.

### Phase 2.5 — Blind Cross-Review

Anonymized peer-ranking of the Phase 2 evidence bundles by the investigators
themselves, aggregated by Borda count into a consensus quality score per
bundle. This phase is implemented in the council pipeline (driven by
`commands/council.md`; its Cross-Review section is rendered into both
`templates/report-verdict.md` and `templates/report-finding.md` — Phase 2.5 is
not shape-gated; the reviewer prompt is `prompts/cross-reviewer.md`).

**Spawn contract:**
- Spawn `subagent_type: "dev-team:council-scribe"` (tool-less; no model-map
  fence). Do not spawn `finder`, `ic4`, or `ic5`.
- For N investigators, spawn N cross-reviewers in parallel.
- Each reviewer sees every bundle **EXCEPT its own** (self-exclusion) — never
  investigator identities, prior narrative, or prior verdicts. (SPEC-013 § Council tiering.)

**Anonymization:** Bundles are stripped of investigator identity and assigned
random labels (`A`, `B`, `C`, …). The `label → bundle` mapping is shuffled
**independently per reviewer** to defeat position bias. (SPEC-013 § Council tiering.)

**Tool allowlist:** Cross-reviewers MUST NOT run any tools — evaluation is over
the submitted bundles only, never raw artifacts. (SPEC-013 § Council tiering.)

**Aggregation (Borda count):** Each reviewer returns a `RANKING: X > Y > Z`
line; an invalid/missing line is an abstain. Rankings are mapped back to bundle
identities and summed into a Borda consensus score per bundle. The ranked list
(stable-sorted, original submission order as tiebreaker) is passed to **Phase 4
and Phase 5 ordered by Borda consensus rank, not submission order.** (SPEC-013 § Council tiering.)

**WEAK_EVIDENCE:** Bundles in the bottom Borda quartile (score ≤ the
25th-percentile threshold) MUST be flagged `WEAK_EVIDENCE` in the report.
(SPEC-013 § Council tiering.)

**Bypass:** Per claim, not per run (`workflow.js` groups bundles by
`claim_id`). When a claim has fewer than 3 bundles — or every reviewer
response for that claim is rejected — Phase 2.5 is SKIPPED for that claim.
Those bundles pass through in original submission order and the bypass
reason is noted in the report. Other claims are unaffected. (SPEC-013 § Council tiering.)

`commands/council.md` stores the per-reviewer rankings and consensus scores for
the `{{CROSS_REVIEW_RANKINGS}}` / `{{CROSS_REVIEW_SCORES}}` report variables
(audit trail; SPEC-013 § Council tiering).

*Traceability:* SPEC-013 § Council tiering. Phase 2.5 is live; Phase 3 specialist
bundles (when pulled) join the set before cross-review.
