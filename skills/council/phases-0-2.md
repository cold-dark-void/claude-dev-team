<!-- /council stage body — load via SKILL.md router; read only the current stage. -->

**Stage anchor (run once per stage; fresh-shell safe):**

```bash
# Locate the dev-team plugin root (PDH). Optional CLAUDE_PLUGIN_ROOT (force path / FR #48230), else cwd only when it is the dev-team plugin itself (CDT-265), else marketplace clone (slug-free agents/pm.md), else installed cache (rank by /dev-team/<VER>/ segment, not full path; CDT-166). CDT-82: marketplace before same-version cache.
# lint-ok: C3 — marketplace */ for-loop + -f guarded (SPEC-021 Q2 residual, CDT-82 PDH)
PDH=$( { [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -f "$CLAUDE_PLUGIN_ROOT/skills/plugin-dir.sh" ] && printf '%s\n' "$CLAUDE_PLUGIN_ROOT"; } || { [ -f skills/plugin-dir.sh ] && [ -f agents/pm.md ] && grep -qF '"name": "dev-team"' .claude-plugin/plugin.json 2>/dev/null && pwd; } || { _pr='${CLAUDE_PLUGIN_ROOT}'; [ "${_pr#\$}" = "$_pr" ] && [ -f "$_pr/skills/plugin-dir.sh" ] && printf '%s\n' "$_pr"; } || { for _mp in "$HOME"/.claude/plugins/marketplaces/*/; do [ -f "${_mp}skills/plugin-dir.sh" ] && [ -f "${_mp}agents/pm.md" ] && printf '%s\n' "${_mp%/}" && break; done; } || find ~/.claude/plugins/cache -path '*/dev-team/*/skills/plugin-dir.sh' 2>/dev/null | awk -F/ '{ver=""; for(i=1;i<=NF;i++) if($i=="dev-team"&&i<NF){ver=$(i+1);break}; if(ver=="") next; m=ver; gsub(/-pre\./,"~pre.",m); p=($0 ~ /\/cache\/cold-dark-void\/dev-team\//)?1:0; print m "\t" p "\t" $0}' | sort -t $'\t' -k1,1V -k2,2n -k3,3 | tail -1 | cut -f3 | xargs -r dirname | xargs -r dirname )
printf 'PDH=%s\n' "$PDH" >&2
```

## Engine Phases

### Phase 0 — Intake

Parse args → resolve scope → resolve task id (fallback chain above) →
resolve preset (explicit or inferred) → validate `--tier` (CDT-126; absent =
`full`) → validate `--plan` path readable → load `--from-retro` anchor JSON
(missing → exit 2) → fail loud on an empty or unknown `--scope`.

User-flag mutual exclusion is not an engine check. `commands/council.md`
Step 0.5 rejects zero or multiple scopes before preflight. The engine takes
one `--scope` value.

The engine never *grades*. `commands/council.md` § 1.5.1 does not auto-grade
any scope, including `--diff`. An externally supplied `--council-tier` passes
through as `engine.sh preflight --tier` (§ 1.5.5). This command does not pass
`--grading-reason`. When that flag is absent, the engine synthesizes
`externally supplied tier (no grading_reason given)`. §§ 1.5.2–1.5.4 are the
shared grading procedure for other callers (the ship gate). This command does
not run them on itself. Phase 0 only records the tier and lets it select the
flavor subset and the Phase 3 / Phase 4 skips.

Diff-mode records `spec_grep: true`. The engine does not run spec-grep and
does not read `specs/**/*.md`. Spec-grep is the orchestrator's job (WP 3-01).
Finalize renders `applicable_specs` from the plan only and does not grep.
When the plan omits it, the report says none matched.

No user code runs in Phase 0. No subagents spawn. This phase is pure
validation + input assembly.

### Phase 1 — Claim Extraction

**When it runs:**
- `--session`, transcript-derived scopes: extraction runs over the transcript
  slice and produces a list of load-bearing claims.
- `--plan <path>`: extraction runs over the markdown plan file via
  `skills/council/prompts/plan-extractor.md`. Locators:
  `<plan-file>:<heading-path>:<line>`. (SPEC-013 § Command Shape & Scope; CDV-208.)
- `--diff` (diff-mode): extraction runs over the diff + applicable-specs
  bundle and produces candidate **findings** (not claims-as-assertions) —
  the finding IS the assertion in diff-mode. (SPEC-013 § Engine Architecture.)
- Single pasted claim (`"<claim>"`) and `--from-retro <anchor-id>`: extraction
  is SKIPPED — the claim is already isolated. For from-retro, claim text is
  `resolved_claim` from the anchor file; locator `retro:<anchor-id>`.
  (SPEC-013 § Output Shapes; CDV-212.)

**Output shape (structured records):**

```
claim := {
  claim: string,
  source_locator: string,   // turn id / file:line / file:heading-path:line / anchor id
  claim_type: "factual" | "causal" | "recommendation" | "behavioral"
}
```

For diff-mode the record shape is parallel but records are candidate
findings with `{file, line, description}` — Phase 5 will finalize severity
and confidence.

**Budget:**
- Default claim budget: **10** per run. Configurable per preset (not
  per-invocation in COUNCIL-001 — hardcoded default until COUNCIL-002).
- When the extraction pass produces more than the budget, claims MUST be
  ranked by load-bearing weight (highest-stakes first) and truncated to the
  budget. The report MUST note the cap and list the un-audited claims.
  (SPEC-013 § Output Shapes.)

**Implementation note:** claim extraction is performed by a Task-tool
subagent. Session/diff use `skills/council/prompts/claim-extractor.md`;
plan scope uses `skills/council/prompts/plan-extractor.md` (path from
`phases.1_claim_extraction.prompt` in the investigation plan). Extractors
are blind — raw transcript/diff/plan text only, never prior narrative or
prior verdicts.

### Phase 2 — Parallel Investigation

**Spawn contract:**
- **Model map:** resolve `finder` first (canonical fence in § Model map). Named
  fallback `finder`→`ic5` resolves `ic5` (same fence for later spawns of that
  agent). Unnamed / `general-purpose` / Explore: omit the fence.
- Spawn investigators via the Task tool with
  **`subagent_type: "dev-team:finder"` preferred** (CDT-230 — `finder` is the
  shared read-only fan-out investigator; named `dev-team:*` agents delivered
  final output more reliably than bare `general-purpose` in dogfood, CDT-133).
  Fallback chain on spawn failure/refusal of the named type:
  `dev-team:ic5` → `general-purpose` → `"Explore"` (code-heavy claims may start
  at Explore). Always inject the investigator prompt template + flavor delta;
  never rely on the agent definition's default persona alone.
- **Minimum 2 investigators per claim with distinct flavor presets** (e.g.
  `paranoid-ic` + one other) to defeat monoculture. (SPEC-013 § Council tiering.)
- One task per claim per flavor — investigators MUST spawn in parallel
  within a single message, subject to Task-tool concurrency limits.
- Investigators MUST NOT receive prior assistant narrative, prior verdicts,
  or prior advocate/prosecutor output. They see raw artifacts only.
  (SPEC-013 § Output Shapes.)
- Completion discipline (all council Task spawns): prompt MUST end with an
  explicit instruction to return the required JSON as the **final message**
  (not only via SendMessage/mailbox). Re-request at most twice on empty output
  before treating as spawn failure (degradation protocol).

**Tool allowlist (read-only):**
`Read`, `Grep`, `Glob`, `Bash` for read commands only, MCP query tools.
No Write, Edit, MultiEdit, no Bash mutating commands. (SPEC-013 § Council tiering.)
This allowlist is injected into the Task prompt by the investigator prompt
template; Task-tool spawns do not have per-invocation tool allowlists,
so enforcement is prompt-level + strike-rule at evidence-bundle validation.

**Evidence bundle schema (required return shape):**

```
evidence_bundle := {
  tool_use_id: string,            // MANDATORY
  raw_blob: string,                // raw tool output, NOT paraphrased
  file_line: string,               // "path/to/file:42" or equivalent locator
  reproducible_command: string     // e.g. "grep -n 'foo' path/to/file"
}
```

**Validation (strike rule):** The orchestrator runs
`skills/bug-hunt/strike-bundle.sh` on each investigator bundle. Strike the
bundle when `reproducible_command` is missing, `file_line` is missing,
`raw_blob` is empty or paraphrased, or a re-run of `reproducible_command`
does not match `raw_blob`. The one M14 Verify bundle whose
`reproducible_command` equals the claim `VERIFY_COMMAND` is exempt from that
byte compare (`strike-bundle.sh --exempt-rerun`): its `raw_blob` is the
wrapper output, not a bare re-run. `tool_use_id` is a stable per-call label the
investigator assigns (`read_1`). A missing host-emitted id is not a strike
and does not by itself set `verification_mode` to `self-verified`. A kept
bundle whose re-run matches leaves `verification_mode: full` when the spawn
succeeded. `engine.sh` still strikes an empty or whitespace-only
`tool_use_id` when it packages a bundle (CDT-178). Absent, `null`, empty, or
whitespace-only `tool_use_id` counts as missing for that packaging (after
strip). Engine-generated strike reasons APPEND to pre-existing `struck_lines`
(never replace). Strike-and-continue (exit 0); do not invent host ids; do not
exit 7 for a missing host id. The engine MUST NOT accept a bundle that
paraphrases a tool output instead of inlining the raw blob. (SPEC-013 § Council tiering.)

**Intra-run tool-call cache (CDV-211; SPEC-013 SHOULD):** preflight creates
`${TMPDIR:-/tmp}/council-cache-<run_id>/` with `reads/`, `greps/`, and
`manifest.json`, and emits `cache_dir` + `run_id` on the investigation plan.
The orchestrator may pre-seed `reads/` from claim source_locators.
Investigators receive `{{CACHE_DIR}}` as a read-only path. They must not
mkdir, write, or run sha256sum, and must not invent a tool_use_id for
bytes another agent wrote (CDT-275). Finalize best-effort removes the
dir. Empty/missing cache does not change correctness.

**External investigator slot (CDV-207; SPEC-013 SHOULD):** opt-in via
`--external` / `--external=codex|gemini` on `/council` and
`/review-and-commit`. Preflight always emits `external` on the plan:
`{requested:false}` when off; when on, runs
`skills/council/external-reviewer.sh detect` (order: codex → gemini, or
pinned tool) and sets `status: available|skipped`, `tool`, `helper`,
`flavor: skills/council/flavors/external.md`. **Additive only** — never
removes an internal flavor; ≥1 internal investigator always remains.
Missing CLI / invoke failure → one-line stderr skip, continue with
internal investigators; never hard-fail solely for an external miss.
Orchestrator runs `external-reviewer.sh run` once in Phase 2 (or
review-and-commit Phase 1 specialists) and merges the normalized
`evidence_bundle` / `findings[]` (`tool_use_id` form
`external:<tool>:<hash>`). CLI parse isolation lives only in the helper.

### Spawn-failure degradation

**Trigger:** any required Task spawn for Phase 1 (extractor), Phase 2
(investigators), Phase 2.5 (cross-reviewers), Phase 4 (prosecutor/advocate),
Phase 5 (judge), or diff-mode specialists fails or returns unusable output
(rate-limit, refusal, empty/malformed — any unusable spawn).

**Action:** the **orchestrator** (session driving `/council` or
`/review-and-commit`) performs that role's work with real tools. Exception:
do not grant tools to a spawned judge agent — if the judge cannot spawn,
the orchestrator emits judge JSON itself (still tool-backed evidence only).

**Actor rule (AC4):** self-verify is always the orchestrator — never the
implementer of the code under audit. Never ship on implementer self-validation.

**Partial fleet (AC5):** if some spawns succeed and others fail, keep usable
returns; self-verify only the missing roles; still mark the run degraded.

**Finalize:** when any role was self-verified, pass
`--verification-mode self-verified` to `engine.sh finalize`. Default (all
spawns OK) is `full` / omit the flag.

**Marker (exact string):** `self-verified — refuters unavailable` — rendered
in the report Summary banner and `verification_mode` frontmatter when
degraded. Full runs have no banner.

**Exit 5:** still applies when evidence is empty **and** no self-verify path
produced usable bundles. Self-verify that yields ≥1 bundle continues finalize.

*Traceability:* SPEC-013 Spawn-failure degradation (CDV-199). Single protocol
home — `commands/council.md` and `skills/review-and-commit/SKILL.md` cite
this section; do not restate a second protocol.
