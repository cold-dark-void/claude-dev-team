<!-- /epic stage body — load via SKILL.md router; read only the current stage. -->

**Stage anchor (run once per stage; fresh-shell safe):**

```bash
# Locate the dev-team plugin root (PDH). Optional CLAUDE_PLUGIN_ROOT (force path / FR #48230), else cwd only when it is the dev-team plugin itself (CDT-265), else marketplace clone (slug-free agents/pm.md), else installed cache (rank by /dev-team/<VER>/ segment, not full path; CDT-166). CDT-82: marketplace before same-version cache.
# lint-ok: C3 — marketplace */ for-loop + -f guarded (SPEC-021 Q2 residual, CDT-82 PDH)
PDH=$( { [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -f "$CLAUDE_PLUGIN_ROOT/skills/plugin-dir.sh" ] && printf '%s\n' "$CLAUDE_PLUGIN_ROOT"; } || { [ -f skills/plugin-dir.sh ] && [ -f agents/pm.md ] && grep -qF '"name": "dev-team"' .claude-plugin/plugin.json 2>/dev/null && pwd; } || { _pr='${CLAUDE_PLUGIN_ROOT}'; [ "${_pr#\$}" = "$_pr" ] && [ -f "$_pr/skills/plugin-dir.sh" ] && printf '%s\n' "$_pr"; } || { for _mp in "$HOME"/.claude/plugins/marketplaces/*/; do [ -f "${_mp}skills/plugin-dir.sh" ] && [ -f "${_mp}agents/pm.md" ] && printf '%s\n' "${_mp%/}" && break; done; } || find ~/.claude/plugins/cache -path '*/dev-team/*/skills/plugin-dir.sh' 2>/dev/null | awk -F/ '{ver=""; for(i=1;i<=NF;i++) if($i=="dev-team"&&i<NF){ver=$(i+1);break}; if(ver=="") next; m=ver; gsub(/-pre\./,"~pre.",m); p=($0 ~ /\/cache\/cold-dark-void\/dev-team\//)?1:0; print m "\t" p "\t" $0}' | sort -t $'\t' -k1,1V -k2,2n -k3,3 | tail -1 | cut -f3 | xargs -r dirname | xargs -r dirname )
printf 'PDH=%s\n' "$PDH" >&2
```

## Mode A — Decompose

### A.1 Soft prechecks (SHOULD)

- If epic text is vague (< ~50 words): warn and offer `/brainstorm` — do **not** hard-block.
- Soft warn at approval if > ~8 children (probably two epics).

### A.2 Parallel PM + TL spawn (M1, MC-4)

Spawn **both** in parallel with `Output mode: terse`. Do **not** spawn ICs.

Before spawning @pm:
```bash
PDH="${PDH:-<PDH>}"   # session root carried from the stanza fence above — re-run that fence first when not held
RESOLVE=$(bash "$PDH/skills/plugin-dir.sh" file skills/model-map/resolve-model.sh)
MODEL=$(bash "$RESOLVE" pm)
printf '%s\n' "$MODEL"
EFFORT=$(bash "$RESOLVE" --effort pm)
printf '%s\n' "$EFFORT"
```
Bash stdout = model string; empty → omit model.
Then `resolve-model.sh --effort` (same agent). Non-empty EFFORT → pass as Agent `effort` param; empty → omit (MUST NOT pass `""`).
Surface resolver stderr to the user. Do not swallow.
If MODEL is non-empty: pass it as the Agent model param.
If MODEL is empty: omit model. MUST NOT pass "".
If spawn fails attributed to the model param (invalid/unknown/unsupported model): retry once with model omitted; warn `model-map: host rejected model '<string>' for pm; retrying with Tier default`.
If spawn fails attributed to the `effort` param (invalid/unknown/unsupported effort): retry once omitting effort; warn `model-map: host rejected effort '<token>' for pm; retrying with inherited effort`.
Model host-reject stays independent. Ambiguous failure: do not guess; do not combinatorial-retry both params.
Other spawn failures MUST NOT be retried as a model or effort fallback.

**PM prompt template:**

```
Decompose umbrella epic <EPIC-ID> into child tickets.

Epic text:
"""
<EPIC TEXT>
"""

For EACH child produce:
1. short title
2. problem statement (what/why — no technical design)
3. acceptance criteria (testable list)
4. suggested slug (lowercase-hyphen, ~50 chars)

Do NOT invent depends_on, estimates, or agent tags — Tech Lead owns those.
Output mode: terse.
```

Before spawning @tech-lead, use the same resolver as the @pm block above.
Substitute `tech-lead` for `pm` in both `resolve-model.sh` calls and in both
host-reject warnings. Do not copy the fence.

**TL prompt template:**

```
Decompose umbrella epic <EPIC-ID> into child tickets + cross-ticket DAG.

Epic text:
"""
<EPIC TEXT>
"""

For EACH child produce:
1. short title (align with PM if available)
2. size estimate: S | M | L
3. recommended agent: ic4 (extend patterns) | ic5 (novel)
4. depends_on: list of OTHER child local IDs only (form <EPIC-ID>-C<n>)
5. flag file-overlap risks within the same wave (add serializing depends_on)

Do NOT write problem statements or ACs — PM owns those.
Child IDs will be assigned as <EPIC-ID>-C1, C2, … in stable title order.
Output mode: terse.
```

### A.3 Merge algorithm

1. Align children by title (PM list is primary order; TL fills estimate/agent/depends_on).
2. Assign local IDs: `<EPIC-ID>-C1` … `C<n>` (stable order).
3. Every child MUST have all five M1 fields before approval:
   - problem statement, acceptance criteria, estimate, agent, `depends_on`
4. Missing any field → block approval; re-prompt the owning agent for that field only.

### A.4 Cycle gate (M2) — before any write

Build adapter JSON and call **dag-lib** (or epic-lib thin wrapper) literally:

```bash
_gc=$(git rev-parse --git-common-dir 2>/dev/null) \
  && MROOT=$(cd "$(dirname "$_gc")" && pwd) \
  || MROOT=$(pwd)
PDH="${PDH:-<PDH>}"   # session root carried from the stanza fence above — re-run that fence first when not held
EPIC_LIB=$(bash "$PDH/skills/plugin-dir.sh" file skills/epic/epic-lib.sh)
DAG_JSON=$(mktemp "${TMPDIR:-/tmp}/epic-dag.XXXXXX.json")
# Write [{"task_id":"<EPIC-ID>-C1","depends_on":[]}, …] into $DAG_JSON
if ! bash "$EPIC_LIB" check-cycle "$DAG_JSON"; then
  echo "HALT: cycle in proposed DAG — zero writes"
  rm -f "$DAG_JSON"
  # stop; name the back-edge from stderr
fi
rm -f "$DAG_JSON"
```

On cycle: **halt**. Zero backlog / Linear / `state.json` writes.

### A.5 Approval gate (M3)

Present:

1. Per-child summary (five fields + slug)
2. Wave plan: `bash …/epic-lib.sh waves` after a dry-run structure, or format from DAG levels
3. Soft >8-children warning if applicable
4. **SHOULD (M12 / OQ8):** Linear project intent — will create or link a Linear Project named **exactly** the epic title (no `EPIC-ID` prefix). Informational only; not AC-gating.

**Autopilot (CDT-111-C4 — SPEC-033 M3 / M5c):** when `AUTOPILOT_ON=true`
(§Step 0.5), do **not** wait for the user. Make **one atomic** `scope-confirm`
engine call covering scope **and** plan together — `/epic` has no separate
plan-approve gate (M5c); the single A.5 verdict is both. Invoke
`skills/autopilot/self-answer.md` with the C3 §2 envelope: `{ workflow:"epic",
ticket_id:<EPIC-ID>, gate:"scope-confirm", run_id:RUN_ID, iteration:ITER,
run_start_epoch:RUN_START_EPOCH, autopilot_bump:AUTOPILOT_BUMP, max_loc:MAX_LOC, <scope signals:
epic-text sufficiency evidence, destructive-op flags, complexity signals> }`.
Consume `{ decision, blocking_condition, confidence, rationale }` and act per
this map. It is the whole map for `/epic` (the engine returns only `proceed`,
`halt` or `reroute-epic` at `scope-confirm`):

- `proceed` → continue to **A.6** exactly as the human **approve** path would.
- `halt` → emit `task_blocked` (detail = the one-line message) via **Passive
  notifications → Tier B** (fail-open; § Passive notifications), then print the
  one-line message `scope-confirm halt: <rationale> — card: <card-path>` and
  **return** with **zero** disk side effects except the audit card, **and zero** Linear project
  create/link attempts — identical no-side-effect semantics to the human
  **decline** path below (AC12 / M3), except that the halt writes that card.
- `reroute-epic` (BC5 complexity overflow) — `/epic` decompose is itself the
  reroute target, so never hand off (a hand-off would re-enter this A.5 gate).
  Count the proposed children (the soft-warn rule of A.1 and the list above):
  **more than 8 children** → print `scope-confirm reroute-epic (soft warn):
  <rationale> — card: <card-path>`, then continue to **A.6**. Otherwise →
  treat as `halt` (the `halt` branch above).
- any other value (an engine contract break) → treat as `halt` (fail closed).

Otherwise (autopilot off) the existing human gate applies **unchanged**:

User may edit/merge/remove children. On **decline**: exit, **zero** disk side effects **and zero** Linear project create/link attempts (AC12 / M3).

On **approve** continue A.6.

### A.6 Persist (only after approve)

Ask once for execution mode if not yet known: `kickoff` | `orchestrate`.

**Autopilot (CDT-111-C4 — SPEC-033 M5d / FINAL #5):** when `AUTOPILOT_ON=true`
(§Step 0.5), **skip the ask** and default `MODE=orchestrate` without prompting.
The ask above applies only when autopilot is off. (A.6 makes no engine call — it
is purely a function of the A.5 verdict.)

```bash
_gc=$(git rev-parse --git-common-dir 2>/dev/null) \
  && MROOT=$(cd "$(dirname "$_gc")" && pwd) \
  || MROOT=$(pwd)
PDH="${PDH:-<PDH>}"   # session root carried from the stanza fence above — re-run that fence first when not held
EPIC_LIB=$(bash "$PDH/skills/plugin-dir.sh" file skills/epic/epic-lib.sh)
EPIC_ID="<EPIC-ID>"
TITLE="<epic title>"
MODE="<kickoff|orchestrate>"
WORKTREE_ENABLED="<true|false>"   # from Step 0.4 session state
RELEASE_BUMP="<null|patch|minor|major>"  # from Step 0.4 session state
INIT_EXTRA=()
if [ "$WORKTREE_ENABLED" = true ]; then
  INIT_EXTRA+=(--worktree-enabled true)
  if [ "$RELEASE_BUMP" != "null" ] && [ -n "$RELEASE_BUMP" ]; then
    INIT_EXTRA+=(--release-bump "$RELEASE_BUMP")
  fi
fi
bash "$EPIC_LIB" init "$EPIC_ID" --title "$TITLE" --mode "$MODE" "${INIT_EXTRA[@]}"
# CDT-141-C2: one integration worktree when worktree_enabled (no-op otherwise)
bash "$EPIC_LIB" ensure-integration-worktree "$EPIC_ID"
# linear_project_id starts null; set after M12 project resolve (below)
# per child (after Linear project + issue when MCP up — prefer --linear-id at add time):
bash "$EPIC_LIB" add-child "$EPIC_ID" \
  --id "${EPIC_ID}-C<n>" --slug "<slug>" --title "<title>" \
  --estimate S|M|L --agent ic4|ic5 \
  --depends-on '<json-array>' \
  --problem "<problem>" --ac '<json-array-of-strings>'
  # optional: --linear-id "<LINEAR-ISSUE-ID>"
```

#### Dual-write persistence (M4 — Linear preferred + local write-through)

When Linear MCP is available, resolve Linear project (M12) and create/link each
Linear issue first, then **always** write local write-through. When MCP is down,
write local only. Process trackers under `.claude/` MUST NOT be committed
(SPEC-025 M4 / SPEC-009).

Per child, write `.claude/backlog/<slug>.md` with YAML frontmatter + body:

```markdown
---
epic_parent: <EPIC-ID>
child_id: <EPIC-ID>-C<n>
depends_on: [<ids>]
estimate: M
agent: ic5
---

# <TITLE>

**Status**: PENDING

## Problem

<problem statement>

## Acceptance Criteria

- <ac1>
- <ac2>

## Goal

Ship child of epic <EPIC-ID>.

## Effort

<S|M|L>

---

*Added: <YYYY-MM-DD>*
```

Index row under `## Pending` in `.claude/backlog.md`:

```markdown
- [<TITLE>](backlog/<slug>.md) - <one-line> [PENDING] epic:<EPIC-ID> <CHILD-ID>
```

Slug formula (SPEC-009 / `/backlog`): lowercase, hyphen-join, strip punctuation, max ~50 chars; on collision append `-2`, `-3`.

Ensure backlog structure exists (`/backlog init` if missing).

#### Linear Project per epic (M12) — before/with child dual-write

Session owns Linear MCP; `epic-lib.sh` never calls MCP (M12.9). After `init`,
before or with child issue dual-write:

1. **MCP down** → print M5 notice (below); skip project; local path only (AC7).
2. **MCP up** — resolve **exactly one** project named the epic `title` **exactly**
   (AC2; no `EPIC-ID` prefix, no fuzzy match):
   - Call `list_projects` with `query` = epic title (substring search is fine as
     a prefilter). **Then filter client-side** to projects whose **name equals
     the epic title exactly** (string equality — not substring/prefix). Ignore
     near-matches (e.g. title + `" v2"`). If the tool paginates (default limit
     often 50), page with the cursor until no more results or an exact match is
     found — do not stop at the first page if zero exact survivors remain.
     Listing and linking need **no team** — never gate this step on team
     resolution (only `save_project` requires a team).
   - **≥1 exact survivor** → **link** the first exact survivor; do **not** create
     (AC3). If **multiple** exact-name survivors → still link the first, and print
     exactly: `Multiple Linear projects named '<title>' — linking first hit`
     (OQ3; this is a multi-hit advisory, **not** a second M5 fail-open string).
   - **Zero exact survivors → create.** First **resolve the Linear team once**
     (OQ2 / M12.3) — the team used for **both** `save_project` and child
     `save_issue` (known team from workspace/session context, or `list_teams`
     when ambiguous). Cache that team id/name and pass it to every subsequent
     `save_project` / `save_issue` in this approve path; resolve it **once**, not
     per child. Then `save_project` with `name` = epic title and
     `team` / `addTeams` = that team. If the team cannot be resolved → fail-open
     (M5 notice); skip **create only**, leave `linear_project_id` null, continue
     local. Never invent a team. The child issue path still fail-opens
     independently if it needs a team later.
   - On **any** project list/create failure → M5 notice; continue local; leave
     `linear_project_id` null (AC6).
3. **On success** — record id (atomic):
   ```bash
   PDH="${PDH:-<PDH>}"   # session root carried from the stanza fence above — re-run that fence first when not held
   EPIC_LIB=$(bash "$PDH/skills/plugin-dir.sh" file skills/epic/epic-lib.sh)
   EPIC_ID="<EPIC-ID>"
   PROJECT_ID="<LINEAR-PROJECT-ID>"
   bash "$EPIC_LIB" set-linear-project "$EPIC_ID" "$PROJECT_ID"
   ```
   `show` / `rollup` surface `linear_project_id` when non-null.

#### Linear preferred (M5) — child issues + project attach

If Linear MCP tools are available (preferred SoT for open work):

##### M4.1 Link-before-create (inventory → adopt | create | halt)

**Before any child `save_issue` create**, inventory existing parented children
(SPEC-025 M4.1). Session-owned MCP only (`epic-lib` never calls Linear).

1. **Inventory:** `list_issues` with `parentId=<EPIC-ID>`, page until exhausted
   (`limit` 50–250 + `cursor`). Request fields at least: `id`, `title`,
   `description`, `status`, `statusType`, `projectId` (identifier/url as available).
   Prefer `includeArchived=false`. **Survivors** = rows whose `statusType` is
   **not** `canceled` (include completed/done; drop canceled).
2. **Inventory failure** (tool error / unusable response) → print the single M5
   notice below; **skip all Linear child creates** for this approve path; continue
   local write-through only. Prefer missing Linear links over silent duplicates.
3. **Zero survivors → create path** (per-child steps below).
4. **≥1 survivor → adopt path — MUST NOT create a second child set:**
   - **Match** each proposed local child to ≤1 survivor, in order:
     1. Description embeds `child_id: <EPIC-ID>-C<n>` or the bare local id
     2. Unique exact match on **normalized title**: lowercase; strip leading
        `[<EPIC-ID>]`, `E<n>:`, `C<n>:`, `<EPIC-ID>-C<n>` (optional trailing
        punctuation/space)
     3. If `|survivors| == |proposed|` and a collision-free case-insensitive
        unique title map exists (normalized short titles), use it
   - **Full unique map:** for each pair, record Linear id as `linear_id`;
     best-effort attach to `linear_project_id` when set and missing; best-effort
     `epic:<EPIC-ID>` label; optional description patch to embed `child_id` if
     absent (fail-open). **Zero** `save_issue` creates. Local backlog + index +
     `add-child … --linear-id` as usual. Print one advisory line:
     `Adopted N existing Linear child(ren) under <EPIC-ID> — no new issues created`
   - **Ambiguous / partial map:** print **exactly**:
     `HALT: Linear already has N child issue(s) under <EPIC-ID> — adopt or confirm force-create; refusing duplicate create`
     Then list survivors (`id` + title) and proposed children. **Zero** Linear
     child creates. Human may: supply adopt map, **explicit** force-create
     override, or abort. **Autopilot:** full unique map → adopt (silent except
     the advisory); ambiguous → emit `task_blocked` (Tier B) and **return** —
     MUST NOT force-create under autopilot.

##### Create path (only when zero inventory survivors, or explicit force-create)

**Per child:**

1. Create issue via `save_issue`: title `[<EPIC-ID>] <child title>`; description
   embeds local `child_id` + problem + ACs. (Parent-edge on **create** remains
   deferred — M12 project + label group children; M4.1 only *reads* parentId.)
2. **Attach to project (M12 / AC4):** when `linear_project_id` is non-null, pass
   `project` = that id on `save_issue`. Attach failure for one child is fail-open
   for **that child only** — keep `linear_project_id`, continue remaining children
   (OQ5); print M5 notice for the failed attach if useful, do not retry-loop.
3. **Label (AC11):** `epic:<EPIC-ID>` if labels API works; else description-only.
   Project does **not** replace labels.
4. Record returned issue id: prefer Linear first then
   `add-child … --linear-id`, **or** pass `--linear-id` at add-child when known.
   Re-`add-child` is wrong if already added; `set-status` alone does not store
   `linear_id`.

Then always local backlog item + index row + `add-child` (with `--linear-id`
when known).

On **any** Linear failure or MCP absence (issue create/link, project
create/link, or child-to-project attach) — **except** M4.1 ambiguous halt,
which is intentional stop: print **exactly** one line

`Linear unavailable — continuing with local write-through only`

and continue. **Never** block, retry-loop, or fail the epic on transport/MCP
errors. Reuse this single M5 string for project failures too (OQ7 / M5) — do not
invent a second fail-open string. M4.1 ambiguous halt uses its own HALT line
above (not the M5 transport string).

**Notify-on-done (CDT-123):** after successful A.6 persist (decompose approved and
written), emit `task_complete` (detail = `epic decompose complete: <EPIC-ID>`) via
**Passive notifications → Tier B** (fail-open; § Passive notifications). Skip if the
run halted at A.5.

Then enter **Execute / Resume**.

---
