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

## Step S1: Discover (compose blind path)

**Contract:** SPEC-034 M16 / M20 / **M33** — compose SPEC-013 blind-review path
with defaults; `--target` = hunt path (`BH_PATH`). **MUST NOT** fork a second
finder protocol.

**Protocol authority (cite; execute steps below with BH_* bindings):**

| Authority | Section |
|-----------|---------|
| `skills/council/SKILL.md` | § Blind-review path (`--blind`, CDT-46-C3) + Lens delta library |
| `commands/council.md` | § Blind-review path (B0–B7 dispatch + substitutions) |
| Prompts | `skills/council/prompts/unconstrained-reviewer.md`, `lens-reviewer.md`, `quorum-analyst.md` |

**Hard compose rules:**

- **MUST NOT** shell nested `/council` / `/council --blind` as a user-facing
  sub-invocation (would imply a lock / second UX). Orchestrate the same Task
  wave **in this skill**.
- **MUST NOT** re-enter tribunal Phases 1–5 on Tier-1 clusters (SEVER Tier-1
  self-recursion — blind path rule).
- **MUST NOT** invent new lens names, flavor files, or reviewer prompts.
- **MUST NOT** pause for user input before S2 (AC4 / M7).
- **MUST** bind file scope to `BH_PATH` only (AC3 / M2 / path-bound).

### 1a. Bind blind-path defaults (MVP)

MVP locks defaults (flag surface `--teams`/`--lenses` on `/bug-hunt` = SHOULD later):

```
BH_TEAMS   = 3                                    # ≡ --teams 3
BH_LENSES  = security,contributor,spec            # ≡ --lenses default
BH_TARGET  = BH_PATH                              # ≡ --target (absolute path from S0)
```

Session manifest (for REPORT / T5):

```
BH_MANIFEST = {
  teams: U1,U2,U3 (unconstrained),
  lenses: L-security, L-contributor, L-spec,
  total_reviewers: 6,                             # BH_TEAMS + |BH_LENSES|
  target: BH_PATH,
  floor: BH_FLOOR
}
```

Resolve each lens's `{{FLAVOR_DELTA}}` from `skills/council/SKILL.md` § Blind-review
path → **Lens delta library** (security / contributor / spec). Do **not** use
tribunal `skills/council/flavors/*` files for discover reviewers.

### 1b. Build path-bound file list

Re-derive roots (fresh-shell safe). Target is always `BH_PATH` (never empty /
full-project unless S0 bound path = project root).

```bash
# Re-bind roots (SPEC-021 C1). BH_PATH is a session binding from S0 — orchestrator
# injects it before this fence (cannot re-parse user args here).
_gc=$(git rev-parse --git-common-dir 2>/dev/null) \
  && MROOT=$(cd "$(dirname "$_gc")" && pwd) \
  || MROOT=$(pwd)
WTROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
# lint-ok: C1 — BH_PATH session binding from S0; orchestrator injects before fence
: "${BH_PATH:?BH_PATH session binding required (from S0)}"
[ -e "$BH_PATH" ] || { echo "error: BH_PATH missing: $BH_PATH" >&2; exit 64; }

# Path-bound file list (AC3). Prefer git-tracked under BH_PATH; fall back to find.
if [ -d "$BH_PATH" ]; then
  FILE_LIST=$(git -C "$WTROOT" ls-files -- "$BH_PATH" 2>/dev/null)
  if [ -z "$FILE_LIST" ]; then
    FILE_LIST=$(find "$BH_PATH" -type f \
      ! -path '*/.git/*' ! -path '*/node_modules/*' ! -path '*/dist/*' \
      ! -path '*/vendor/*' 2>/dev/null)
  fi
else
  # Single-file scope
  FILE_LIST="$BH_PATH"
fi

SCOPE_NOTE="Bug-hunt discover — review files under: $BH_PATH only. Do not expand scope outside this path."
PROJECT_ROOT="$MROOT"
```

Print brief discover summary (orchestrator stdout):

```
S1 discover scope: $BH_PATH
Floor: $BH_FLOOR
Teams: $BH_TEAMS unconstrained + lenses [$BH_LENSES]
Total reviewers: $((BH_TEAMS + lens_count))
Files in scope: <count>
```

Empty file list (empty dir / no tracked files): continue with empty `FILE_LIST`;
reviewers may still return 0 findings; candidates may be empty — legal. Still
emit phase-done M20.

### 1c. Parallel reviewer wave (single wave — never sequential)

Spawn all unconstrained + lens reviewers in one parallel Task wave (same
message) — reviewers are independent and blind to each other. `Output mode: terse` on every spawn.

Prefer `subagent_type: "dev-team:finder"` (CDT-230); fallback `dev-team:ic5` →
`general-purpose`. Read-only tools only (same as blind path / investigator
allowlist: Read, Grep, Glob, Bash read-only — no Write/Edit/commit).

**Model map:** resolve the agent actually spawned (`finder`; named fallback
`finder`→`ic5` resolves `ic5`). Same fence for later S1 lens / quorum `finder`
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

**Unconstrained** — for each index `1..BH_TEAMS` (U1..U3):

```
description: "bug-hunt S1 unconstrained U<N>"
subagent_type: "dev-team:finder"
prompt: contents of skills/council/prompts/unconstrained-reviewer.md
  with substitutions:
    {{TEAM_ID}}      ← U<N>
    {{FILE_LIST}}    ← FILE_LIST from 1b
    {{PROJECT_ROOT}} ← $MROOT
    {{SCOPE_NOTE}}   ← SCOPE_NOTE from 1b
    {{DATA_NONCE}}   ← skills/lib/prompt-frame.sh nonce; prompt-frame.sh strip FILE_LIST first
  + trailing line: Output mode: terse
  + trailing line: Return FINDING blocks + SUMMARY as the final message.
```

**Lens** — for each lens in `BH_LENSES` (security, contributor, spec):

```
description: "bug-hunt S1 lens L-<lens>"
subagent_type: "dev-team:finder"
prompt: contents of skills/council/prompts/lens-reviewer.md
  with substitutions:
    {{TEAM_ID}}      ← L-<lens>   (e.g. L-security)
    {{LENS_NAME}}    ← <lens>
    {{FLAVOR_DELTA}} ← lens-delta paragraph from council SKILL Lens delta library
    {{FILE_LIST}}    ← FILE_LIST from 1b
    {{PROJECT_ROOT}} ← $MROOT
    {{SCOPE_NOTE}}   ← SCOPE_NOTE from 1b
    {{DATA_NONCE}}   ← skills/lib/prompt-frame.sh nonce; prompt-frame.sh strip FILE_LIST first
  + trailing line: Output mode: terse
  + trailing line: Return FINDING blocks + SUMMARY as the final message.
```

Collect FINDING-NNN blocks + SUMMARY per team. Spawn failure on a reviewer:
record that team as 0 findings; continue (partial fleet). If the wave is
wholly unusable, orchestrator may self-verify with real tools under `BH_PATH`
only; marker exact `self-verified — refuters unavailable` when discover fleet
is degraded (actor = orchestrator; cite council § Spawn-failure degradation —
do not invent findings).

### 1d. Namespace and validate (no repair)

Mirror blind path B3:

1. Prefix every FINDING-NNN with team ID: `U1-FINDING-001`,
   `L-security-FINDING-001`, …
2. **Drop malformed** (missing Category, Severity, Files, Claim, or Evidence) —
   do **not** repair. Count → `dropped[]` with `reason=malformed`.
3. **Out-of-scope drop (AC3):** if every Files path is outside `BH_PATH` tree,
   drop with `reason=out-of-scope`. If mixed, keep only in-scope file pointers
   on the finding; if none remain, drop out-of-scope.

### 1e. Quorum analyst (clustering)

Spawn **one** quorum analyst after the reviewer wave completes. Same S1
`finder` Model map fence as §1c (do not paste full PDH again). Named fallback
`finder`→`ic5` resolves `ic5`. Unnamed / `general-purpose` / Explore: omit.

```
description: "bug-hunt S1 quorum analysis"
subagent_type: "dev-team:finder"
prompt: contents of skills/council/prompts/quorum-analyst.md
  with substitutions:
    {{ALL_FINDINGS}}         ← namespaced FINDING blocks (=== TEAM <id> === headers)
    {{TEAM_MANIFEST}}        ← BH_MANIFEST team IDs + type (unconstrained|lens)
    {{UNCONSTRAINED_TEAMS}}  ← U1,U2,U3
    {{LENS_TEAMS}}           ← L-security,L-contributor,L-spec
    {{TOTAL_TEAMS}}          ← 6
    {{DATA_NONCE}}           ← skills/lib/prompt-frame.sh nonce; prompt-frame.sh strip ALL_FINDINGS first
  + trailing line: Output mode: terse
  + trailing line: Return CLUSTER blocks + QUORUM-SUMMARY as the final message.
```

Collect CLUSTER-NNN (Tier 1/2/3) + QUORUM-SUMMARY. Quorum spawn failure:
fall back to mapping well-formed namespaced FINDINGS directly as Tier-3
candidates (still path/floor filtered); note degraded in session for REPORT.

### 1f. Map clusters → `candidates[]` / `dropped[]`

Apply **Finding model** map above. Orchestrator algorithm:

```
candidates = []
dropped    = []   # informational only (M15)

for each CLUSTER (Tier 1, then 2, then 3):
  locator  = first in-scope Files entry → path[:line] or symbol
  severity = normalize(Severity)   # HIGH→critical etc display map; store enum only
  if locator empty OR severity ∉ {critical,warning,nitpick}:
    dropped.append(..., reason=malformed); continue
  if locator outside BH_PATH:
    dropped.append(..., reason=out-of-scope); continue
  if severity_rank(severity) < severity_rank(BH_FLOOR):
    dropped.append(..., reason=below-floor); continue
  candidates.append({
    id, tier, locator, severity,
    description: Claim,
    evidence: Evidence + Teams + source_findings,
    status: "candidate",
    category?
  })

# Optional: well-formed FINDINGS not absorbed into any cluster → same filters,
# status=candidate, tier=3 prior.
```

Severity rank: `critical=3`, `warning=2`, `nitpick=1`. Floor compare is
**≥ floor stays** (e.g. floor=`warning` keeps critical+warning; drops nitpick).

**Invariants of the map:**

- Every `candidates[]` item has `status` exactly `candidate` and all five AC8
  field keys populated (`evidence` may be thin pre-refute — S2 deepens).
- Below-floor never in `candidates[]` (M15 / AC6).
- Out-of-scope never in `candidates[]` (AC3).
- Malformed never repaired into candidates.
- Empty `candidates[]` is legal (zero defects found / all dropped).

Do **not** write the final bug-hunt report here (T5 / REPORT). Optional side
council blind report under `.claude/council/` is **not** required; if composed
steps write one, bug-hunt report remains SoT for C2 Done.

### 1g. Phase-done discover (M20)

When `candidates[]` (possibly empty) is produced for `BH_PATH` and floor
filtering has been applied (with `dropped[]` present when any item was
filtered), print exact phase-done line and continue to S2 **without** user lock:

```
phase-done: discover — candidate set produced (M20)
  path: $BH_PATH
  floor: $BH_FLOOR
  candidates: <N>
  dropped: <M>
  manifest: U1,U2,U3 + L-security,L-contributor,L-spec
```

**MUST NOT** wait for user confirmation. Proceed immediately to **Step S2**.

### Session outputs for S2 / REPORT (T4 / T5)

| Binding | Shape |
|---------|--------|
| `candidates[]` | list of AC8-shaped objects with `status=candidate` |
| `dropped[]` | informational list (`reason` ∈ below-floor\|out-of-scope\|malformed) |
| `BH_MANIFEST` | team/lens/target/floor summary |
| `BH_DISCOVER_DEGRADED` | bool + optional note if reviewer/quorum fleet degraded |

---

