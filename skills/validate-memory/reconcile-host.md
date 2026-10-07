# Reconcile path (`--reconcile`)

Runs only when `RECONCILE=true` after Step 1 of
`skills/validate-memory/host-pipeline.md` (DB check, mutual exclusion, lock
guard). Do not open this file instead of that Step 1. Skips Steps 2–11
(codebase claim pipeline). Contracts and pair-judge prompt live in
`skills/validate-memory/SKILL.md` (Reconcile Candidate Contract, Pair-Judge
Prompt Template). Host library: `skills/validate-memory/reconcile-lib.sh`.

## Step R1: Candidate pair generation (no LLM)

Resolve plugin root for the lib (worktree-aware; sibling of commands/):

```bash
_gc=$(git rev-parse --git-common-dir 2>/dev/null) \
  && MROOT=$(cd "$(dirname "$_gc")" && pwd) \
  || MROOT=$(pwd)
WTROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
MEMDB="$MROOT/.claude/memory/memory.db"
# Plugin root: prefer WTROOT when it contains the skill; else walk from this
# command file's known install layout.
# lint-ok: C3 — marketplace */ for-loop + -f guarded (SPEC-021 Q2 residual, CDT-82 PDH)
PDH=$( { [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -f "$CLAUDE_PLUGIN_ROOT/skills/plugin-dir.sh" ] && printf '%s\n' "$CLAUDE_PLUGIN_ROOT"; } || { [ -f skills/plugin-dir.sh ] && [ -f agents/pm.md ] && grep -qF '"name": "dev-team"' .claude-plugin/plugin.json 2>/dev/null && pwd; } || { _pr='${CLAUDE_PLUGIN_ROOT}'; [ "${_pr#\$}" = "$_pr" ] && [ -f "$_pr/skills/plugin-dir.sh" ] && printf '%s\n' "$_pr"; } || { for _mp in "$HOME"/.claude/plugins/marketplaces/*/; do [ -f "${_mp}skills/plugin-dir.sh" ] && [ -f "${_mp}agents/pm.md" ] && printf '%s\n' "${_mp%/}" && break; done; } || find ~/.claude/plugins/cache \( -path '*/dev-team/*/skills/plugin-dir.sh' -o -path '*/dev-team-edge/*/skills/plugin-dir.sh' \) 2>/dev/null | awk -F/ '{ver=""; for(i=1;i<=NF;i++) if(($i=="dev-team"||$i=="dev-team-edge")&&i<NF){ver=$(i+1);break}; if(ver=="") next; m=ver; gsub(/-pre\./,"~pre.",m); p=($0 ~ /\/cache\/cold-dark-void\/dev-team\//)?2:(($0 ~ /\/cache\/cold-dark-void\/dev-team-edge\//)?1:0); print m "\t" p "\t" $0}' | sort -t $'\t' -k1,1V -k2,2n -k3,3 | tail -1 | cut -f3 | xargs -r dirname | xargs -r dirname )
printf 'PDH=%s\n' "$PDH" >&2
RECONCILE_LIB=$(bash "$PDH/skills/plugin-dir.sh" file skills/validate-memory/reconcile-lib.sh)
if [ -z "$RECONCILE_LIB" ] || [ ! -f "$RECONCILE_LIB" ]; then
  echo "Error: reconcile-lib.sh not found" >&2
  exit 1
fi
PAIRS_FILE=$(mktemp "${TMPDIR:-/tmp}/reconcile-pairs.XXXXXX")
AGENT_ARGS=()
if [ -n "${TARGET_AGENT:-}" ]; then
  AGENT_ARGS=(--agent "$TARGET_AGENT")
fi
# R1a embed KNN (when vec0+embeddings available) else R1b keyword Jaccard.
# Lib enforces: behavioral agents only, cross-agent, sim/Jaccard thresholds,
# resolved-pair skip, sample ≤200/agent, cap from reconcile_pair_cap.
# stderr carries RECONCILE_META; JSONL goes to --out only
META_FILE=$(mktemp "${TMPDIR:-/tmp}/reconcile-meta.XXXXXX")
bash "$RECONCILE_LIB" candidates "$MEMDB" "${AGENT_ARGS[@]}" --out "$PAIRS_FILE" \
  2>"$META_FILE" >/dev/null
META=$(cat "$META_FILE")
rm -f "$META_FILE"
# Parse RECONCILE_META candidates=N cap=K cap_hit=bool method=keyword|embed
CAND_N=$(echo "$META" | sed -n 's/.*candidates=\([0-9]*\).*/\1/p' | tail -1)
CAND_N="${CAND_N:-0}"
CAP_K=$(echo "$META" | sed -n 's/.*cap=\([0-9]*\).*/\1/p' | tail -1)
CAP_HIT=$(echo "$META" | sed -n 's/.*cap_hit=\([^ ]*\).*/\1/p' | tail -1)
METHOD=$(echo "$META" | sed -n 's/.*method=\([^ ]*\).*/\1/p' | tail -1)
```

If `CAND_N` is 0:

```bash
_gc=$(git rev-parse --git-common-dir 2>/dev/null) \
  && MROOT=$(cd "$(dirname "$_gc")" && pwd) \
  || MROOT=$(pwd)
MEMDB="$MROOT/.claude/memory/memory.db"
CAP_K=$(sqlite3 -cmd ".timeout 5000" "$MEMDB" "SELECT value FROM config WHERE key='reconcile_pair_cap';" 2>/dev/null || echo "50")
CAP_K="${CAP_K:-50}"
echo "TLDR: reconcile: 0 candidates, 0 judged, 0 contradictory, 0 resolved, 0 skipped, cap=${CAP_K}"
# Stop here (exit 0) — zero writes
exit 0
```

Path-containment: N/A (no filesystem paths from untrusted claim text in R1).

## Step R2: LLM pair-judge

Read `skills/validate-memory/SKILL.md` section **Pair-Judge Prompt Template**.

1. Load pairs from `$PAIRS_FILE` (JSONL → JSON array).
2. Batch 10 pairs per call. Keep spawning until every candidate up to `reconcile_pair_cap` is judged. Do not stop after 5 batches. The cap default is 50 and the maximum is 500.
3. For each batch, run `skills/lib/prompt-frame.sh nonce`, then
   `prompt-frame.sh strip` on the JSON array, then substitute `{{DATA_NONCE}}`
   and `{{PAIR_BATCH}}` with that stripped JSON. Spawn a Task subagent
   (`subagent_type: "general-purpose"`, `model: haiku`). Spawn batches in
   parallel. Cheap tier is safe here — a malformed batch degrades to
   `unrelated` conf 0 rather than being trusted blindly.
4. Validate each batch against "Validation rules (command-enforced)".
5. Malformed batch → every pair in that batch becomes `unrelated` conf 0;
   note in DETAIL: `judge malformed → unrelated`.

Collect all judgements into `JUDGEMENTS` (JSON array).

## Step R3: Partition

- `CONTRADICTORY` — verdict `contradictory` (only these enter resolution)
- `NON_ACTION` — `consistent` | `unrelated` (no resolution prompt, no mutation)

Counters: `J` = judged count, `C` = contradictory count.

## Step R4a: `--report-only` or no contradictions

If `REPORT_ONLY=true` OR `C=0`:

```bash
# Session counters from R1–R3 (agent state across steps — not a prior bash block):
# CAND_N, CAP_K, CAP_HIT, J, C, PAIRS_FILE
HIT_SUFFIX=""
[ "${CAP_HIT:-false}" = "true" ] && HIT_SUFFIX=" HIT"  # lint-ok: C1
echo "TLDR: reconcile: ${CAND_N:-0} candidates, ${J:-0} judged, ${C:-0} contradictory, 0 resolved, 0 skipped, cap=${CAP_K:-50}${HIT_SUFFIX}"  # lint-ok: C1
echo ""
echo "DETAIL:"
# For each judgement: ids, agents, verdict, claim quotes, confidence, rationale
# For contradictory under --report-only: still print evidence; action=report
# MUST NOT: UPDATE memories, INSERT reconcile_log, archive anything
rm -f "${PAIRS_FILE:-}"  # lint-ok: C1
# Stop here (exit 0)
exit 0
```

**AC7:** Even max-confidence `contradictory` never archives on this path.

## Step R4b: Interactive resolution

For each pair in `CONTRADICTORY`, present:

```
CONTRADICTION [id_a=@agent_a vs id_b=@agent_b] conf=N%
  claim_a: "…"
  claim_b: "…"
  rationale: …
Choose: pick-survivor | merge | both-stale | skip | deep-audit
```

Host applies SQL via `reconcile-lib.sh` (never auto-archive without this choice).
All writes use SPEC-004 `PRAGMA busy_timeout=5000` inside the lib.

### pick-survivor

User picks winner id (other becomes loser):

```bash
_gc=$(git rev-parse --git-common-dir 2>/dev/null) \
  && MROOT=$(cd "$(dirname "$_gc")" && pwd) \
  || MROOT=$(pwd)
WTROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
MEMDB="$MROOT/.claude/memory/memory.db"
PDH="${PDH:-$( { [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -f "$CLAUDE_PLUGIN_ROOT/skills/plugin-dir.sh" ] && printf '%s\n' "$CLAUDE_PLUGIN_ROOT"; } || { [ -f skills/plugin-dir.sh ] && [ -f agents/pm.md ] && grep -qF '"name": "dev-team"' .claude-plugin/plugin.json 2>/dev/null && pwd; } || { _pr='${CLAUDE_PLUGIN_ROOT}'; [ "${_pr#\$}" = "$_pr" ] && [ -f "$_pr/skills/plugin-dir.sh" ] && printf '%s\n' "$_pr"; } || { for _mp in "$HOME"/.claude/plugins/marketplaces/*/; do [ -f "${_mp}skills/plugin-dir.sh" ] && [ -f "${_mp}agents/pm.md" ] && printf '%s\n' "${_mp%/}" && break; done; } || find ~/.claude/plugins/cache \( -path '*/dev-team/*/skills/plugin-dir.sh' -o -path '*/dev-team-edge/*/skills/plugin-dir.sh' \) 2>/dev/null | awk -F/ '{ver=""; for(i=1;i<=NF;i++) if(($i=="dev-team"||$i=="dev-team-edge")&&i<NF){ver=$(i+1);break}; if(ver=="") next; m=ver; gsub(/-pre\./,"~pre.",m); p=($0 ~ /\/cache\/cold-dark-void\/dev-team\//)?2:(($0 ~ /\/cache\/cold-dark-void\/dev-team-edge\//)?1:0); print m "\t" p "\t" $0}' | sort -t $'\t' -k1,1V -k2,2n -k3,3 | tail -1 | cut -f3 | xargs -r dirname | xargs -r dirname )}"
RECONCILE_LIB=$(bash "$PDH/skills/plugin-dir.sh" file skills/validate-memory/reconcile-lib.sh)
if [ -z "$RECONCILE_LIB" ] || [ ! -f "$RECONCILE_LIB" ]; then
  echo "Error: reconcile-lib.sh not found" >&2
  exit 1
fi
bash "$RECONCILE_LIB" resolve-pick "$MEMDB" "$WINNER_ID" "$LOSER_ID" \
  "$AGENT_A" "$AGENT_B" "$CLAIM_A" "$CLAIM_B" "$CONF" "$REASON"
# Archives loser with archive_reason='reconciled'; logs pick-survivor
```

### merge

User supplies merged text (or accepts host-proposed merge of both contents).
Host writes SQL (OQ-5 — judge/user supply text only):

```bash
_gc=$(git rev-parse --git-common-dir 2>/dev/null) \
  && MROOT=$(cd "$(dirname "$_gc")" && pwd) \
  || MROOT=$(pwd)
WTROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
MEMDB="$MROOT/.claude/memory/memory.db"
PDH="${PDH:-$( { [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -f "$CLAUDE_PLUGIN_ROOT/skills/plugin-dir.sh" ] && printf '%s\n' "$CLAUDE_PLUGIN_ROOT"; } || { [ -f skills/plugin-dir.sh ] && [ -f agents/pm.md ] && grep -qF '"name": "dev-team"' .claude-plugin/plugin.json 2>/dev/null && pwd; } || { _pr='${CLAUDE_PLUGIN_ROOT}'; [ "${_pr#\$}" = "$_pr" ] && [ -f "$_pr/skills/plugin-dir.sh" ] && printf '%s\n' "$_pr"; } || { for _mp in "$HOME"/.claude/plugins/marketplaces/*/; do [ -f "${_mp}skills/plugin-dir.sh" ] && [ -f "${_mp}agents/pm.md" ] && printf '%s\n' "${_mp%/}" && break; done; } || find ~/.claude/plugins/cache \( -path '*/dev-team/*/skills/plugin-dir.sh' -o -path '*/dev-team-edge/*/skills/plugin-dir.sh' \) 2>/dev/null | awk -F/ '{ver=""; for(i=1;i<=NF;i++) if(($i=="dev-team"||$i=="dev-team-edge")&&i<NF){ver=$(i+1);break}; if(ver=="") next; m=ver; gsub(/-pre\./,"~pre.",m); p=($0 ~ /\/cache\/cold-dark-void\/dev-team\//)?2:(($0 ~ /\/cache\/cold-dark-void\/dev-team-edge\//)?1:0); print m "\t" p "\t" $0}' | sort -t $'\t' -k1,1V -k2,2n -k3,3 | tail -1 | cut -f3 | xargs -r dirname | xargs -r dirname )}"
RECONCILE_LIB=$(bash "$PDH/skills/plugin-dir.sh" file skills/validate-memory/reconcile-lib.sh)
if [ -z "$RECONCILE_LIB" ] || [ ! -f "$RECONCILE_LIB" ]; then
  echo "Error: reconcile-lib.sh not found" >&2
  exit 1
fi
bash "$RECONCILE_LIB" resolve-merge "$MEMDB" "$WINNER_ID" "$LOSER_ID" \
  "$AGENT_A" "$AGENT_B" "$CLAIM_A" "$CLAIM_B" "$CONF" "$MERGED_CONTENT" "$REASON"
# UPDATE winner content (preserve tier/type/distilled_from); tag [reconciled: YYYY-MM-DD];
# archive loser reconciled
```

### both-stale

```bash
_gc=$(git rev-parse --git-common-dir 2>/dev/null) \
  && MROOT=$(cd "$(dirname "$_gc")" && pwd) \
  || MROOT=$(pwd)
WTROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
MEMDB="$MROOT/.claude/memory/memory.db"
PDH="${PDH:-$( { [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -f "$CLAUDE_PLUGIN_ROOT/skills/plugin-dir.sh" ] && printf '%s\n' "$CLAUDE_PLUGIN_ROOT"; } || { [ -f skills/plugin-dir.sh ] && [ -f agents/pm.md ] && grep -qF '"name": "dev-team"' .claude-plugin/plugin.json 2>/dev/null && pwd; } || { _pr='${CLAUDE_PLUGIN_ROOT}'; [ "${_pr#\$}" = "$_pr" ] && [ -f "$_pr/skills/plugin-dir.sh" ] && printf '%s\n' "$_pr"; } || { for _mp in "$HOME"/.claude/plugins/marketplaces/*/; do [ -f "${_mp}skills/plugin-dir.sh" ] && [ -f "${_mp}agents/pm.md" ] && printf '%s\n' "${_mp%/}" && break; done; } || find ~/.claude/plugins/cache \( -path '*/dev-team/*/skills/plugin-dir.sh' -o -path '*/dev-team-edge/*/skills/plugin-dir.sh' \) 2>/dev/null | awk -F/ '{ver=""; for(i=1;i<=NF;i++) if(($i=="dev-team"||$i=="dev-team-edge")&&i<NF){ver=$(i+1);break}; if(ver=="") next; m=ver; gsub(/-pre\./,"~pre.",m); p=($0 ~ /\/cache\/cold-dark-void\/dev-team\//)?2:(($0 ~ /\/cache\/cold-dark-void\/dev-team-edge\//)?1:0); print m "\t" p "\t" $0}' | sort -t $'\t' -k1,1V -k2,2n -k3,3 | tail -1 | cut -f3 | xargs -r dirname | xargs -r dirname )}"
RECONCILE_LIB=$(bash "$PDH/skills/plugin-dir.sh" file skills/validate-memory/reconcile-lib.sh)
if [ -z "$RECONCILE_LIB" ] || [ ! -f "$RECONCILE_LIB" ]; then
  echo "Error: reconcile-lib.sh not found" >&2
  exit 1
fi
bash "$RECONCILE_LIB" resolve-both-stale "$MEMDB" "$ID_A" "$ID_B" \
  "$AGENT_A" "$AGENT_B" "$CLAIM_A" "$CLAIM_B" "$CONF" "$REASON"
```

### skip

```bash
_gc=$(git rev-parse --git-common-dir 2>/dev/null) \
  && MROOT=$(cd "$(dirname "$_gc")" && pwd) \
  || MROOT=$(pwd)
WTROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
MEMDB="$MROOT/.claude/memory/memory.db"
PDH="${PDH:-$( { [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -f "$CLAUDE_PLUGIN_ROOT/skills/plugin-dir.sh" ] && printf '%s\n' "$CLAUDE_PLUGIN_ROOT"; } || { [ -f skills/plugin-dir.sh ] && [ -f agents/pm.md ] && grep -qF '"name": "dev-team"' .claude-plugin/plugin.json 2>/dev/null && pwd; } || { _pr='${CLAUDE_PLUGIN_ROOT}'; [ "${_pr#\$}" = "$_pr" ] && [ -f "$_pr/skills/plugin-dir.sh" ] && printf '%s\n' "$_pr"; } || { for _mp in "$HOME"/.claude/plugins/marketplaces/*/; do [ -f "${_mp}skills/plugin-dir.sh" ] && [ -f "${_mp}agents/pm.md" ] && printf '%s\n' "${_mp%/}" && break; done; } || find ~/.claude/plugins/cache \( -path '*/dev-team/*/skills/plugin-dir.sh' -o -path '*/dev-team-edge/*/skills/plugin-dir.sh' \) 2>/dev/null | awk -F/ '{ver=""; for(i=1;i<=NF;i++) if(($i=="dev-team"||$i=="dev-team-edge")&&i<NF){ver=$(i+1);break}; if(ver=="") next; m=ver; gsub(/-pre\./,"~pre.",m); p=($0 ~ /\/cache\/cold-dark-void\/dev-team\//)?2:(($0 ~ /\/cache\/cold-dark-void\/dev-team-edge\//)?1:0); print m "\t" p "\t" $0}' | sort -t $'\t' -k1,1V -k2,2n -k3,3 | tail -1 | cut -f3 | xargs -r dirname | xargs -r dirname )}"
RECONCILE_LIB=$(bash "$PDH/skills/plugin-dir.sh" file skills/validate-memory/reconcile-lib.sh)
if [ -z "$RECONCILE_LIB" ] || [ ! -f "$RECONCILE_LIB" ]; then
  echo "Error: reconcile-lib.sh not found" >&2
  exit 1
fi
bash "$RECONCILE_LIB" resolve-skip "$MEMDB" "$ID_A" "$ID_B" \
  "$AGENT_A" "$AGENT_B" "$CLAIM_A" "$CLAIM_B" "$CONF" "$REASON"
# Log only — pair may reappear on a later run (skip is not a resolved action)
```

### deep-audit

```bash
_gc=$(git rev-parse --git-common-dir 2>/dev/null) \
  && MROOT=$(cd "$(dirname "$_gc")" && pwd) \
  || MROOT=$(pwd)
WTROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
MEMDB="$MROOT/.claude/memory/memory.db"
PDH="${PDH:-$( { [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -f "$CLAUDE_PLUGIN_ROOT/skills/plugin-dir.sh" ] && printf '%s\n' "$CLAUDE_PLUGIN_ROOT"; } || { [ -f skills/plugin-dir.sh ] && [ -f agents/pm.md ] && grep -qF '"name": "dev-team"' .claude-plugin/plugin.json 2>/dev/null && pwd; } || { _pr='${CLAUDE_PLUGIN_ROOT}'; [ "${_pr#\$}" = "$_pr" ] && [ -f "$_pr/skills/plugin-dir.sh" ] && printf '%s\n' "$_pr"; } || { for _mp in "$HOME"/.claude/plugins/marketplaces/*/; do [ -f "${_mp}skills/plugin-dir.sh" ] && [ -f "${_mp}agents/pm.md" ] && printf '%s\n' "${_mp%/}" && break; done; } || find ~/.claude/plugins/cache \( -path '*/dev-team/*/skills/plugin-dir.sh' -o -path '*/dev-team-edge/*/skills/plugin-dir.sh' \) 2>/dev/null | awk -F/ '{ver=""; for(i=1;i<=NF;i++) if(($i=="dev-team"||$i=="dev-team-edge")&&i<NF){ver=$(i+1);break}; if(ver=="") next; m=ver; gsub(/-pre\./,"~pre.",m); p=($0 ~ /\/cache\/cold-dark-void\/dev-team\//)?2:(($0 ~ /\/cache\/cold-dark-void\/dev-team-edge\//)?1:0); print m "\t" p "\t" $0}' | sort -t $'\t' -k1,1V -k2,2n -k3,3 | tail -1 | cut -f3 | xargs -r dirname | xargs -r dirname )}"
RECONCILE_LIB=$(bash "$PDH/skills/plugin-dir.sh" file skills/validate-memory/reconcile-lib.sh)
if [ -z "$RECONCILE_LIB" ] || [ ! -f "$RECONCILE_LIB" ]; then
  echo "Error: reconcile-lib.sh not found" >&2
  exit 1
fi
bash "$RECONCILE_LIB" resolve-deep-audit "$MEMDB" "$ID_A" "$ID_B" \
  "$AGENT_A" "$AGENT_B" "$CLAIM_A" "$CLAIM_B" "$CONF" "$REASON"
# Prints: /council "claim_a vs claim_b"
# MUST NOT spawn tribunal phases (SPEC-013 owns that surface)
```

Track `R` (resolved = pick-survivor|merge|both-stale) and `S` (skip + deep-audit).

### Final TLDR

```bash
# Session counters from R1–R4b (agent state): CAND_N CAP_K CAP_HIT J C R S PAIRS_FILE
HIT_SUFFIX=""
[ "${CAP_HIT:-false}" = "true" ] && HIT_SUFFIX=" HIT"  # lint-ok: C1
echo "TLDR: reconcile: ${CAND_N:-0} candidates, ${J:-0} judged, ${C:-0} contradictory, ${R:-0} resolved, ${S:-0} skipped, cap=${CAP_K:-50}${HIT_SUFFIX}"  # lint-ok: C1
echo ""
echo "DETAIL:"
# Per pair: ids, agents, verdict, quotes, action taken
rm -f "${PAIRS_FILE:-}"  # lint-ok: C1
```
