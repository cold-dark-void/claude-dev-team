<!-- /epic stage body — load via SKILL.md router; read only the current stage. -->

## Step 0: Resolve roots (once per run; later fences carry)

Each fenced bash block is a fresh shell (skill-lint C1). This fence resolves
the roots once, prints `PDH=<root>` to stderr, and every later fence of this
file carries it as `PDH="${PDH:-<PDH>}"` session state — re-run this fence
first when the carried root is not held.

```bash
_gc=$(git rev-parse --git-common-dir 2>/dev/null) \
  && MROOT=$(cd "$(dirname "$_gc")" && pwd) \
  || MROOT=$(pwd)
WTROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
# lint-ok: C3 — marketplace */ for-loop + -f guarded (SPEC-021 Q2 residual, CDT-82 PDH)
PDH=$( { [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -f "$CLAUDE_PLUGIN_ROOT/skills/plugin-dir.sh" ] && printf '%s\n' "$CLAUDE_PLUGIN_ROOT"; } || { [ -f skills/plugin-dir.sh ] && [ -f agents/pm.md ] && grep -qF '"name": "dev-team"' .claude-plugin/plugin.json 2>/dev/null && pwd; } || { _pr='${CLAUDE_PLUGIN_ROOT}'; [ "${_pr#\$}" = "$_pr" ] && [ -f "$_pr/skills/plugin-dir.sh" ] && printf '%s\n' "$_pr"; } || { for _mp in "$HOME"/.claude/plugins/marketplaces/*/; do [ -f "${_mp}skills/plugin-dir.sh" ] && [ -f "${_mp}agents/pm.md" ] && printf '%s\n' "${_mp%/}" && break; done; } || find ~/.claude/plugins/cache -path '*/dev-team/*/skills/plugin-dir.sh' 2>/dev/null | awk -F/ '{ver=""; for(i=1;i<=NF;i++) if($i=="dev-team"&&i<NF){ver=$(i+1);break}; if(ver=="") next; m=ver; gsub(/-pre\./,"~pre.",m); p=($0 ~ /\/cache\/cold-dark-void\/dev-team\//)?1:0; print m "\t" p "\t" $0}' | sort -t $'\t' -k1,1V -k2,2n -k3,3 | tail -1 | cut -f3 | xargs -r dirname | xargs -r dirname )
printf 'PDH=%s\n' "$PDH" >&2
EPIC_LIB=$(bash "$PDH/skills/plugin-dir.sh" file skills/epic/epic-lib.sh)
DAG_LIB=$(bash "$PDH/skills/plugin-dir.sh" file skills/orchestrate/dag-lib.sh)
```

---

## Dispatch

```bash
_gc=$(git rev-parse --git-common-dir 2>/dev/null) \
  && MROOT=$(cd "$(dirname "$_gc")" && pwd) \
  || MROOT=$(pwd)
PDH="${PDH:-<PDH>}"   # session root carried from the stanza fence above — re-run that fence first when not held
EPIC_LIB=$(bash "$PDH/skills/plugin-dir.sh" file skills/epic/epic-lib.sh)
EPIC_ID="<EPIC-ID>"
if bash "$EPIC_LIB" exists "$EPIC_ID"; then
  echo "RESUME"
else
  echo "DECOMPOSE"
fi
```

- `status` → **Status mode**
- `complete` / `block` / `unblock` → thin wrappers over `epic-lib.sh`
- `sync` → **Mode F — Sync** (Linear → local; requires state)
- `--redecompose` → **Redecompose mode** (requires confirm)
- else if `exists` → **Execute / Resume**
- else → **Decompose mode** (needs epic text)

---

## Step 0.4: Worktree / release flags (CDT-141 / SPEC-025 M14)

Locked contract: SPEC-025 M14 CLI table, semantics, illegal combos, done-when
1–7, non-public API. Parse **once** at run start, **before** any
state/Linear/backlog/worktree side effects. Own parser — **not**
`skills/autopilot/parse-flags.sh`.

Substitute the real `/epic` invocation arguments for every `"$@"` in the fences
below. The Bash tool leaves `"$@"` empty. Do not run those fences with an empty
`"$@"`.

```bash
_gc=$(git rev-parse --git-common-dir 2>/dev/null) \
  && MROOT=$(cd "$(dirname "$_gc")" && pwd) \
  || MROOT=$(pwd)
PDH="${PDH:-<PDH>}"   # session root carried from the stanza fence above — re-run that fence first when not held
EPIC_LIB=$(bash "$PDH/skills/plugin-dir.sh" file skills/epic/epic-lib.sh)
EPIC_PARSE=$(bash "$PDH/skills/plugin-dir.sh" file skills/epic/parse-flags.sh)
EPIC_ID="<EPIC-ID>"
# Resume (state exists): honor store / hard-fail conflict (C6). New decompose: pure parse.
if bash "$EPIC_LIB" exists "$EPIC_ID"; then
  EPIC_FLAGS=$(bash "$EPIC_LIB" resolve-resume-flags "$EPIC_ID" -- "$@") \
    || { EPIC_RC=$?; exit "$EPIC_RC"; }   # pass the tool rc through: 64 flag/usage, 1 operational (W3-37)
else
  EPIC_FLAGS=$(bash "$EPIC_PARSE" "$@") || { EPIC_RC=$?; exit "$EPIC_RC"; }
fi
WORKTREE_ENABLED=$(jq -r .worktree_enabled <<<"$EPIC_FLAGS")
RELEASE_BUMP=$(jq -r '.release_bump // "null"' <<<"$EPIC_FLAGS")   # literal null or patch|minor|major
```

Rules (hard-fail exit **64**, zero side effects):
- bare `--worktree` only; `--worktree=*` rejected
- `--release <bump>` (space canonical) or `--release=<bump>`; bump ∈ {patch,minor,major}
- `--release` without `--worktree` → 64; bare/empty/`each`/`end` → 64
- rejected surface: `--bump`, `--land`, `--seal`
- duplicate `--worktree` or `--release` → 64
- flags illegal with first positional `status` | `complete` | `block` | `unblock` | `sync`
- allowed on decompose / execute-resume / `--redecompose` only
- exit codes pass through: **64** = flag / usage / resume-conflict; any other code (for example **1**, a missing state or tool failure) is an operational failure — report it as that, never as a flag error

### Resume flag-vs-state policy (CDT-141-C6) — hard-fail, no silent downgrade

When `state.json` **exists** (execute/resume / re-invoke same epic):

| CLI M14 flags | Policy |
|---------------|--------|
| **Omitted** (`--worktree` / `--release` absent) | **Honor store**: effective modes = `state.worktree_enabled // false` and `state.release_bump // null`. End-of-epic release intent (non-null `release_bump`) is **never** cleared by a bare resume. |
| **Present and match** state | OK — same modes; continue. |
| **Present and conflict** with state | **Exit 64**, zero side effects. No silent enable/disable of worktree, no silent change or clear of `release_bump` (no downgrade of end-release mode). |
| `--autopilot=<patch\|minor\|major>` with null `release_bump` | **Exit 64**, zero side effects (rv-w2-34). Seal-intent is persisted by `init` only; see Step 0.5. |

Defaults path (never used `--worktree`/`--release` at init — keys absent) + flags omitted → `false`/`null`; resume unchanged. Do **not** re-decompose; do **not** require pasting a prior handoff string for tree/branch continuity — B.1 `ensure-integration-worktree` reuses the recorded `epic-<ID>` path/branch from state.

On **new** `init` when `WORKTREE_ENABLED=true`, pass modes into epic-lib so state
records them (omit keys when both default — AC6/AC7):

```bash
# Re-resolve roots + flags (fresh shell — SPEC-021 C1). Modes from Step 0.4 parse result.
_gc=$(git rev-parse --git-common-dir 2>/dev/null) \
  && MROOT=$(cd "$(dirname "$_gc")" && pwd) \
  || MROOT=$(pwd)
PDH="${PDH:-<PDH>}"   # session root carried from the stanza fence above — re-run that fence first when not held
EPIC_LIB=$(bash "$PDH/skills/plugin-dir.sh" file skills/epic/epic-lib.sh)
EPIC_ID="<EPIC-ID>"
TITLE="<epic title>"
MODE="<kickoff|orchestrate>"
WORKTREE_ENABLED="<true|false>"   # from Step 0.4
RELEASE_BUMP="<null|patch|minor|major>"  # from Step 0.4
INIT_EXTRA=()
if [ "$WORKTREE_ENABLED" = true ]; then
  INIT_EXTRA+=(--worktree-enabled true)
  if [ "$RELEASE_BUMP" != "null" ] && [ -n "$RELEASE_BUMP" ]; then
    INIT_EXTRA+=(--release-bump "$RELEASE_BUMP")
  fi
fi
bash "$EPIC_LIB" init "$EPIC_ID" --title "$TITLE" --mode "$MODE" "${INIT_EXTRA[@]}"
```

**C2 integration worktree (when `worktree_enabled`):** after successful `init`
(and on Mode B resume when state has `worktree_enabled=true`), call:

```bash
_gc=$(git rev-parse --git-common-dir 2>/dev/null) \
  && MROOT=$(cd "$(dirname "$_gc")" && pwd) \
  || MROOT=$(pwd)
PDH="${PDH:-<PDH>}"   # session root carried from the stanza fence above — re-run that fence first when not held
EPIC_LIB=$(bash "$PDH/skills/plugin-dir.sh" file skills/epic/epic-lib.sh)
EPIC_ID="<EPIC-ID>"
bash "$EPIC_LIB" ensure-integration-worktree "$EPIC_ID"
```

Creates or reuses exactly one worktree at `$MROOT/.worktrees/epic-<EPIC-ID>`
(branch `feat/epic-<EPIC-ID>` via worktree-lib). Records
`integration_slug` / `integration_path` / `integration_branch` on state.
When `worktree_enabled` is false/absent: no-op exit 0. Re-invoke reuses the
same tree (no second integration worktree). Carry `WORKTREE_ENABLED` /
`RELEASE_BUMP` as session-local run state (from resolve-resume-flags on resume).

## Step 0.5: Autopilot enablement (CDT-111-C4)

Resolve autopilot **once** at run start, before any gate. `--autopilot[=<token>]`
on the invocation or `AUTOPILOT=1` in the environment enables it; the flag wins
over the env and is the **only** channel that carries a ship-intent token
(SPEC-033 M2 / C4 FINAL #3). Tokens: `{patch,minor,major}` (release) or `master`
(**land-no-release** token spelling — land target is worktree baseline / origin
default, not necessarily a branch named `master`). A malformed
`--autopilot=<token>` (token ∉ {patch,minor,major,master}, incl. empty
`--autopilot=`) is a hard error (exit 64) — never a silent fall-through to off
(R7). `/epic` never ships a child itself (M11 — no `/release` mid-child), so the
token is not a ship executor here. A release bump ∈ {patch,minor,major} **is**
seal-intent: a new decompose persists `release_bump` and enables the worktree
(BC5 / CDT-196), and the epic ships only via the B.7 seal (M14). `master` is the
land-no-release spelling and sets no `release_bump`. Resolved+carried so the
seed block is identical across `/orchestrate`, `/kickoff`, `/epic`.

```bash
_gc=$(git rev-parse --git-common-dir 2>/dev/null) \
  && MROOT=$(cd "$(dirname "$_gc")" && pwd) \
  || MROOT=$(pwd)
PDH="${PDH:-<PDH>}"   # session root carried from the stanza fence above — re-run that fence first when not held
AP=$(bash "$PDH/skills/plugin-dir.sh" file skills/autopilot/parse-flags.sh)
AP_JSON=$(bash "$AP" "$@") || { echo "$AP_JSON" >&2; exit 64; }   # 64 = malformed --autopilot=<bump>
AUTOPILOT_ON=$(jq -r .enabled <<<"$AP_JSON")
AUTOPILOT_BUMP=$(jq -r '.bump // "null"' <<<"$AP_JSON")
# CDT-223: bind .max_loc from the same parse-flags.sh call (no env, not resume-seeded).
# MUST NOT pass --max-loc on reroute-epic unless caller argv already has it.
MAX_LOC=$(jq -r '.max_loc // "null"' <<<"$AP_JSON")
RUN_START_EPOCH=$(date +%s)
RUN_ID="epic-<EPIC-ID>-$RUN_START_EPOCH"    # S3-derivable per C3 §2
ITER=0                                      # ++ once per stint
```

Every later reference to `AUTOPILOT_ON` / `AUTOPILOT_BUMP` / `RUN_ID` / `ITER` /
`RUN_START_EPOCH` / `MAX_LOC` below means these values, carried forward from this step (fresh
shells do not carry them; the orchestrator holds them as session-local run state). Each
mapped gate — **A.5** (atomic scope+plan) and **B.3** (per child) — consults
`AUTOPILOT_ON` to choose the autopilot branch or the existing human prompt.
**A.6** defaults `MODE=orchestrate` under autopilot. **B.5 completion is NEVER
autopilot-answered (SPEC-033 N8) — it stays a human/lifecycle attestation.**
**N13 isolation (CDT-224):** `/epic` Mode A envelopes omit `tasks` / `projected_loc` / `waves`; engine argc=2; child `/orchestrate` freezes independently.

**BC5 seal-intent (CDT-196):** when `AUTOPILOT_BUMP` ∈ {`patch`,`minor`,`major`}
and Step 0.4 left `RELEASE_BUMP` null **on a new decompose**, set
`RELEASE_BUMP=$AUTOPILOT_BUMP` and `WORKTREE_ENABLED=true` before A.6 `init`;
`init` persists both. Child handoffs then get `EPIC_RELEASE_END` (B.4). MUST NOT
`git merge --ff-only` / merge a child onto master. One `/release <bump>` at B.7
only. `--autopilot=master` does **not** set `release_bump` (land-no-release is
not a version seal).

**On resume (rv-w2-34):** there is no `init`, so seal-intent cannot be
persisted and MUST NOT be set on the session var alone (the session
`RELEASE_BUMP` would diverge from durable `release_bump`, and
`assert-release-allowed` would still allow a mid-epic land). Step 0.4
`resolve-resume-flags` already receives the full argv: a bump token over a null
durable `release_bump` exits **64** with guidance. Stop there — do not catch the
64 and continue. Resume with bare `--autopilot` or `--autopilot=master`, or
start a new epic with `--worktree --release <bump>`. When durable
`release_bump` is set, it wins; the session never overrides it.

