<!-- /bug-hunt stage body — load via SKILL.md router; read only the current stage. -->

### Stage anchor — resolve PDH (fresh-shell safe)

```bash
# Locate the dev-team plugin root (PDH). Optional CLAUDE_PLUGIN_ROOT (force path / FR #48230), else cwd only when it is the dev-team plugin itself (CDT-265), else marketplace clone (slug-free agents/pm.md), else installed cache (rank by /dev-team/<VER>/ segment, not full path; CDT-166). CDT-82: marketplace before same-version cache.
# lint-ok: C3 — marketplace */ for-loop + -f guarded (SPEC-021 Q2 residual, CDT-82 PDH)
PDH=$( { [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -f "$CLAUDE_PLUGIN_ROOT/skills/plugin-dir.sh" ] && printf '%s\n' "$CLAUDE_PLUGIN_ROOT"; } || { [ -f skills/plugin-dir.sh ] && [ -f agents/pm.md ] && grep -qF '"name": "dev-team"' .claude-plugin/plugin.json 2>/dev/null && pwd; } || { _pr='${CLAUDE_PLUGIN_ROOT}'; [ "${_pr#\$}" = "$_pr" ] && [ -f "$_pr/skills/plugin-dir.sh" ] && printf '%s\n' "$_pr"; } || { for _mp in "$HOME"/.claude/plugins/marketplaces/*/; do [ -f "${_mp}skills/plugin-dir.sh" ] && [ -f "${_mp}agents/pm.md" ] && printf '%s\n' "${_mp%/}" && break; done; } || find ~/.claude/plugins/cache -path '*/dev-team/*/skills/plugin-dir.sh' 2>/dev/null | awk -F/ '{ver=""; for(i=1;i<=NF;i++) if($i=="dev-team"&&i<NF){ver=$(i+1);break}; if(ver=="") next; m=ver; gsub(/-pre\./,"~pre.",m); p=($0 ~ /\/cache\/cold-dark-void\/dev-team\//)?1:0; print m "\t" p "\t" $0}' | sort -t $'\t' -k1,1V -k2,2n -k3,3 | tail -1 | cut -f3 | xargs -r dirname | xargs -r dirname )
printf 'PDH=%s\n' "$PDH" >&2
```

Run this anchor fence first when the carried `PDH` is not held; later fences in
this file carry it as `PDH="${PDH:-<PDH>}"` session state.

## Step S2: Refute / confirm

**Contract:** SPEC-034 **M34** / **M21** / **M32** — disposition every
`candidates[]` item via ≥2 SPEC-013 investigator-pattern agents (distinct
flavors); no leftover `status=candidate`; build `confirmed_actionable[]`.

**Protocol authority (cite; execute steps below):**

| Authority | Section |
|-----------|---------|
| `skills/council/SKILL.md` | § Phase 2 — Parallel Investigation + § Spawn-failure degradation |
| `skills/council/prompts/investigator.md` | Prompt body + `{{VARS}}` + evidence-bundle JSON schema |
| `skills/council/flavors/*` | Existing flavor bodies only (no new flavor files) |

**Hard compose rules:**

- **MUST NOT** run tribunal Phases 3–5 per candidate (too heavy for multi-candidate).
- **MUST NOT** call `engine.sh` preflight/finalize for the whole hunt.
- **MUST NOT** use Workflow path (`workflow.js`) for refute.
- **MUST NOT** add new flavor files under `skills/council/flavors/`.
- **MUST NOT** pause for user input between batches or before REPORT (AC4 / M7).
- **MUST NOT** invent confirmed findings (evidence-or-silence; fail closed).
- **MUST NOT** materialize / fix / handoff during S2 (materialize is S3; handoff is S4).
- **MUST** disposition **every** candidate → `confirmed` \| `refuted` only (AC7 / M34).

### 2a. Empty-candidate fast path

If `candidates[]` is empty after S1:

```
confirmed[] = []
refuted[] = []
confirmed_actionable[] = []
BH_VERIFICATION_MODE = full   # unless S1 already set BH_DISCOVER_DEGRADED
```

Skip investigator spawns. Still emit phase-done M21 (counts all zero) and
continue to REPORT. Zero candidates is legal — not an error.

### 2b. Flavor pair selection (existing files only)

Eligible **investigator-role** flavors (stem = filename without `.md`):

| Eligible (role=investigator, Task-spawnable) | Do **not** use for S2 pairs |
|----------------------------------------------|-----------------------------|
| `paranoid-ic`, `logic`, `security`, `compliance`, `quality`, `simplification` | `jaded-senior` (prosecutor), `yolo-ic` (advocate), `external` (CLI slot), `diff-mode` (preset, not a delta) |

**Default pair (MVP):** `logic` + `security` for every candidate.

**Optional category-aware override** (still ≥2 **distinct** stems; never invent):

| Candidate `category` (if present) | Pair |
|-----------------------------------|------|
| (absent / other) | `logic` + `security` |
| security-ish | `security` + `paranoid-ic` |
| compliance / process | `compliance` + `logic` |
| quality / design | `quality` + `logic` |
| simplification / dead-code | `simplification` + `logic` |

Resolve flavor body: read `skills/council/flavors/<stem>.md` and inject the
**body after YAML frontmatter** as `{{FLAVOR_DELTA}}` (same as council Phase 2).
Do **not** invent deltas.

### 2c. Claim form + investigator inputs

For each candidate `C`, build fixed claim text (plan form — preserve structure):

```
Defect claim: <C.description> at <C.locator>. Severity asserted: <C.severity>.
Is this a real in-scope defect with material evidence, or a false positive /
out-of-scope / non-defect?
```

Investigator template substitutions (`prompts/investigator.md`):

| Variable | Value |
|----------|--------|
| `{{CLAIM_TEXT}}` | claim form above |
| `{{SOURCE_LOCATOR}}` | `C.locator` |
| `{{RAW_ARTIFACTS}}` | path-bound raw context only: `C.locator` file path(s) under `BH_PATH`; optional S1 evidence text as DATA (not narrative instruction); **never** other candidates' claims or other investigators' bundles |
| `{{FLAVOR_DELTA}}` | body of selected flavor file |
| `{{CACHE_DIR}}` | optional shared cache dir for the hunt run (see 2d); empty string if unset |

`claim_id` for returned JSON: use `C.id` when present, else stable
`cand-<index>` assigned at S2 entry (must be unique within the run).

### 2d. Optional shared cache (CDV-211 compose)

MAY create once per hunt (not per candidate):

```bash
# Re-bind roots (SPEC-021 C1)
_gc=$(git rev-parse --git-common-dir 2>/dev/null) \
  && MROOT=$(cd "$(dirname "$_gc")" && pwd) \
  || MROOT=$(pwd)
BH_CACHE_DIR=$(mktemp -d "${TMPDIR:-/tmp}/bug-hunt-cache-XXXXXX")
mkdir -p "$BH_CACHE_DIR/reads" "$BH_CACHE_DIR/greps"
# Pass BH_CACHE_DIR as {{CACHE_DIR}} to every investigator this run.
# Best-effort cleanup after S2 (or leave for session end): rm -rf "$BH_CACHE_DIR"
```

Empty/missing cache is fine — correctness unchanged (council cache contract).

### 2e. Parallel investigator wave (batch ≤8 candidates)

Spawn each batch's investigators in one parallel Task wave (same message). Never sequential per-flavor for a single candidate when both can run
together.

- Prefer `subagent_type: "dev-team:finder"` (CDT-230); fallback `dev-team:ic5` →
  `general-purpose` → `Explore`.
- **Model map:** resolve the agent actually spawned (`finder`; named fallback
  `finder`→`ic5` resolves `ic5`). Same fence for later S2 `finder` investigator
  spawns of this agent. Unnamed / `general-purpose` / Explore: omit.

Before spawning @finder:
```bash
PDH="${PDH:-<PDH>}"   # session root carried from the stanza fence above — re-run that fence first when not held
RESOLVE=$(bash "$PDH/skills/plugin-dir.sh" file skills/model-map/resolve-model.sh)
MODEL=$(bash "$RESOLVE" finder)
printf '%s\n' "$MODEL"
EFFORT=$(bash "$RESOLVE" --effort finder)
printf '%s\n' "$EFFORT"
```
Bash stdout = model string; empty → omit model.
Then `resolve-model.sh --effort` (same agent). Non-empty EFFORT → pass as Agent `effort` param; empty → omit (MUST NOT pass `""`).
Surface resolver stderr to the user. Do not swallow.
If MODEL is non-empty: pass it as the Agent model param.
If MODEL is empty: omit model. MUST NOT pass "".
If spawn fails attributed to the model param (invalid/unknown/unsupported model): retry once with model omitted; warn `model-map: host rejected model '<string>' for finder; retrying with Tier default`.
If spawn fails attributed to the `effort` param (invalid/unknown/unsupported effort): retry once omitting effort; warn `model-map: host rejected effort '<token>' for finder; retrying with inherited effort`.
Model host-reject stays independent. Ambiguous failure: do not guess; do not combinatorial-retry both params.
Other spawn failures MUST NOT be retried as a model or effort fallback.

- Allowlist = council investigator allowlist: Read, Grep, Glob, Bash read-only
  (cache writes under `{{CACHE_DIR}}` only). **No** Write/Edit/commit on project
  tree.
- `Output mode: terse` on every spawn.
- Completion discipline: prompt MUST end with instruction to return the
  investigator JSON as the **final message**. Re-request at most twice on empty
  output before treating as spawn failure.

**Batching (cost control, M34 continuous):**

```
BATCH_CAP = 8   # candidates per wave
for each contiguous batch of ≤ BATCH_CAP candidates from candidates[]:
  spawn 2 investigators per candidate (distinct flavors) in ONE parallel wave
  # wave size = 2 × |batch|  (e.g. 16 Tasks max per wave)
  wait for wave completion
  # no user lock between batches — continue immediately
```

When `|candidates[]| ≤ 8`, a single wave covers all pairs.

**Spawn template** — for each `(candidate C, flavor F)`:

```
description: "bug-hunt S2 refute <claim_id> <flavor>"
subagent_type: "dev-team:finder"
prompt: contents of skills/council/prompts/investigator.md
  with substitutions from §2c + {{FLAVOR_DELTA}} = body of flavors/<F>.md
  + trailing line: Output mode: terse
  + trailing line: Return the single-line evidence-bundle JSON as the final message.
```

**Blindness:** each investigator sees only its claim, locator, raw artifacts,
and flavor delta — **not** other candidates, other bundles, S1 team narrative,
or disposition decisions.

Collect per `(claim_id, flavor)`: parsed JSON
`{claim_id, evidence_bundles[], reason_if_empty}` or unusable/empty.

### 2f. Validate evidence bundles (strike rule)

Mirror council Phase 2 strike (orchestrator-enforced):

Strike a bundle if any of:

1. Missing `reproducible_command`, or a re-run of that command does not match `raw_blob` (`bash skills/bug-hunt/strike-bundle.sh`). The one M14 Verify bundle whose `reproducible_command` is the claim `VERIFY_COMMAND` is exempt from the byte compare (`--exempt-rerun`): its `raw_blob` is the wrapper output, not a bare re-run.
2. Empty `raw_blob` or clearly paraphrased (no tool-output substance)
3. Missing `file_line`
4. Blindness leak (cites other investigators / prior verdicts / narrative)

`tool_use_id` is a stable per-call label the investigator assigns (`read_1`). A missing host id does not strike the bundle and does not set `self-verified — refuters unavailable`. When the investigator spawn succeeded and every kept bundle matches its re-run, `verification_mode` stays `full`.

```bash
# 2f strike one bundle. Orchestrator injects the four bindings below.
BH_STRIKE="${BH_STRIKE:-skills/bug-hunt/strike-bundle.sh}"
BH_REPRO="${BH_REPRO:?reproducible_command required}"
BH_RAW_FILE="${BH_RAW_FILE:?raw_blob file required}"
BH_FILE_LINE="${BH_FILE_LINE:?file_line required}"
BH_SPAWN_OK="${BH_SPAWN_OK:-1}"
BH_EXEMPT_RERUN="${BH_EXEMPT_RERUN:-0}"
BH_VERIFICATION_MODE=full
if [ "$BH_SPAWN_OK" != 1 ]; then
  BH_VERIFICATION_MODE=self-verified
  printf 'self-verified — refuters unavailable\n'
else
  if [ "$BH_EXEMPT_RERUN" = 1 ]; then
    BH_STRIKE_RC=0
    bash "$BH_STRIKE" --exempt-rerun --command "$BH_REPRO" --raw-file "$BH_RAW_FILE" --file-line "$BH_FILE_LINE" || BH_STRIKE_RC=$?
  else
    BH_STRIKE_RC=0
    bash "$BH_STRIKE" --command "$BH_REPRO" --raw-file "$BH_RAW_FILE" --file-line "$BH_FILE_LINE" || BH_STRIKE_RC=$?
  fi
  if [ "$BH_STRIKE_RC" -ne 0 ]; then
    echo "strike: bundle dropped" >&2
  fi
fi
printf 'verification_mode: %s\n' "$BH_VERIFICATION_MODE"
```

After strike, if `evidence_bundles` is empty, treat as empty return with
`reason_if_empty` preserved or set to `no evidence found`.

### 2g. Disposition rules (every candidate)

Orchestrator dispositions from **validated** evidence bundles only — never from
S1 confidence alone.

```
for each candidate C in candidates[]:   # MUST visit every item
  bundles = all non-struck evidence_bundles from both (all) flavors for C
  support = bundles that materially support the defect claim
            (raw tool output shows the claimed defect / violation at locator)
  contradict = bundles that hard-nullify the claim
               (shows code/behavior that falsifies the defect, or out-of-scope,
                or claim not reproducible at locator)

  if |support| >= 1 AND |contradict| == 0:
    status = confirmed
    evidence = merge(C.evidence, support tool cites / file_line / commands)
    # AC8 fields required on confirmed:
    #   locator, severity, description, evidence, status=confirmed
  else if |contradict| >= 1 OR clear false-positive / non-defect / out-of-scope:
    status = refuted
    evidence = merge disposition reason + contradict (or support-empty) cites
  else:
    # both sides thin / empty / unfalsifiable — FAIL CLOSED (do not invent confirmed)
    status = refuted
    evidence = "thin evidence; fail-closed refuted" + reason_if_empty notes

  # NEVER leave status=candidate
```

**Material evidence** means at least one non-struck bundle whose `raw_blob`
substantiates the defect at `locator` (tool-backed). Thin = empty bundles,
`claim not falsifiable`, or only speculative text without tool substance.

**Severity:** keep S1 `severity` on disposition (do not re-rank via investigator
confidence). Severity still ∈ {`critical`,`warning`,`nitpick`} only.

**Out-of-scope at refute:** if investigation shows locator outside `BH_PATH` or
claim is not a defect in scope → `refuted` (not a third status).

### 2h. Spawn failure / degradation (CDV-199)

**Trigger:** any required investigator Task fails or returns unusable output
(rate-limit, refusal, empty after re-requests, malformed JSON that cannot be
parsed).

**Action:**

1. Print exact marker (orchestrator stdout / session):  
   `self-verified — refuters unavailable`
2. Set `BH_REFUTE_DEGRADED=true`, `BH_VERIFICATION_MODE=self-verified`.
3. **Actor = orchestrator only** — self-verify missing roles with real read-only
   tools under `BH_PATH` (same allowlist). **Never** ship on implementer
   self-validation of code under audit.
4. Partial fleet: keep usable investigator returns; self-verify only missing
   (claim, flavor) slots.
5. Apply the **same** disposition rules (§2g) to self-verify bundles.  
   **Never invent confirmed** — if self-verify is also thin → `refuted`.
6. Record degraded banner for REPORT (T5): include the exact marker string.

If **all** investigators for a candidate are unusable **and** orchestrator
self-verify yields no material support → `refuted` (fail closed), still
dispositioned.

Protocol home: `skills/council/SKILL.md` § Spawn-failure degradation — cite;
do not invent a second marker string.

### 2i. Build output sets (AC8 / AC9 / M32)

```
confirmed[] = [ C | C.status == confirmed ]   # full AC8 fields each
refuted[]   = [ C | C.status == refuted ]     # locator + reason in evidence

confirmed_actionable[] = [
  C in confirmed[]
  where severity_rank(C.severity) >= severity_rank(BH_FLOOR)
]
# severity_rank: critical=3, warning=2, nitpick=1  (same as S1)
```

With S1 floor drop, confirmed set ⊆ ≥floor in normal runs; re-apply filter
anyway (M32 / AC9).

**AC8 fields on every `confirmed[]` item (required):**

| Field | Rule |
|-------|------|
| `locator` | non-empty stable pointer |
| `severity` | `critical` \| `warning` \| `nitpick` |
| `description` | what is wrong |
| `evidence` | deepened with investigator tool cites |
| `status` | exactly `confirmed` |

**Invariant at S2 exit:**

- No item remains `status=candidate` (scan `candidates[]` — all rewritten or
  copied into confirmed/refuted with terminal status).
- `|confirmed[]| + |refuted[]| == |candidates[]|` (1:1 disposition).
- `confirmed_actionable[] ⊆ confirmed[]`.

### 2j. Session outputs for REPORT (T5)

| Binding | Shape |
|---------|--------|
| `confirmed[]` | AC8-complete confirmed findings |
| `refuted[]` | dispositioned refuted (locator + one-line reason in evidence) |
| `confirmed_actionable[]` | confirmed ∧ severity ≥ `BH_FLOOR` (AC9 / M32) |
| `candidates[]` | same items with terminal status (no `candidate` left) |
| `dropped[]` | unchanged from S1 (informational) |
| `BH_VERIFICATION_MODE` | `full` \| `self-verified` |
| `BH_REFUTE_DEGRADED` | bool; if true, report banner MUST include exact marker |
| `BH_S2_FLAVORS` | pair(s) used (e.g. `logic+security`) for manifest |

### 2k. Phase-done refute (M21)

When every candidate is dispositioned and sets in §2i are built, print exact
phase-done line and continue to REPORT **without** user lock:

```
phase-done: refute — every candidate dispositioned (M21)
  path: $BH_PATH
  floor: $BH_FLOOR
  candidates: <N>
  confirmed: <C>
  refuted: <R>
  confirmed_actionable: <A>
  verification_mode: <full|self-verified>
```

If `BH_REFUTE_DEGRADED` (or whole-wave unusable): also print exact line:

```
self-verified — refuters unavailable
```

### 2l. Zero-actionable terminal language (AC10)

After phase-done, if `|confirmed_actionable[]| == 0`:

```
0 confirmed-actionable
```

This is a **clean success path** (exit 0 at hunt end) — not an error. Still
hand off to REPORT so T5 writes the user-visible report with counts
(`candidates`, `confirmed`, `refuted`, `dropped`, `confirmed_actionable` all
present; actionable list empty).

If `|confirmed_actionable[]| > 0`, print brief count line (optional):

```
confirmed-actionable: <A>
```

**MUST NOT** wait for user confirmation. Proceed immediately to **Step REPORT**.

### 2m. Hand-off contract (REPORT)

S2 **ends** when phase-done M21 is emitted and session bindings in §2j are set.
Proceed immediately to **Step REPORT** (mkdir/write `$BH_REPORT`). After REPORT,
continuous path continues to **S3** (plan + proceed-gated materialize) then **S4**
emit-only. Orchestrator **must not** fix or **invoke** `/orchestrate` / `/epic`
(AC9/AC12; S4 prints hints only).

**Not used in S2:** tribunal Phases 3–5; `engine.sh` whole-hunt finalize;
Workflow path; backlog materialize (S3 only); phase handoff write (S4 only).

---

