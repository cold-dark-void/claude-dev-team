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

## Step REPORT: User-visible artifacts

**Contract:** SPEC-034 **M31** / **M32** / M24–M25 / AC8–AC10 — emit user-visible
report under `.claude/bug-hunt/`; list `confirmed_actionable` only (confirmed ∧
severity ≥ floor); process artifacts uncommitted.

**Consumes (from S0–S2):** `BH_PATH`, `BH_FLOOR`, `BH_SLUG`, `BH_DATE`,
`BH_REPORT_DIR`, `BH_REPORT`, `BH_MANIFEST`, `BH_S2_FLAVORS`,
`candidates[]`, `dropped[]`, `confirmed[]`, `refuted[]`,
`confirmed_actionable[]`, `BH_VERIFICATION_MODE`, `BH_REFUTE_DEGRADED`,
`BH_DISCOVER_DEGRADED`, phase-done M20/M21 text, AC10 zero-actionable line.

| Artifact | Required | Path |
|----------|----------|------|
| User-visible report | MUST | `$BH_REPORT` = `$MROOT/.claude/bug-hunt/<YYYY-MM-DD>-<slug>.md` |
| Machine findings JSON | SHOULD | `$BH_FINDINGS` = `$MROOT/.claude/bug-hunt/<YYYY-MM-DD>-<slug>.json` |
| Council blind side-report | optional | existing `.claude/council/` if composed steps write one; **bug-hunt report is SoT** for C2 Done |

Templates (plugin-shipped, committed):

| File | Role |
|------|------|
| `skills/bug-hunt/templates/report.md` | User-visible body; placeholders `{{COUNTS}}`, `{{CONFIRMED_ACTIONABLE}}`, … |
| `skills/bug-hunt/templates/findings.json` | SHOULD schema example for C3 intermediate (+ optional `materialize` linkage) |
| `skills/bug-hunt/templates/findings-plan.md` | S3c findings plan; placeholders `{{HUNT_STEM}}`, `{{ACTIONABLE_TABLE}}`, … |
| `skills/bug-hunt/templates/phase-plan.md` | S4d phase index; `{{HUNT_STEM}}`, `{{PHASE_INDEX}}`, … |
| `skills/bug-hunt/templates/handoff-phase.md` | S4d per-phase handoff; AC3 fields `phase_id`…`invocation_hint` |

### R0. Ensure report dir + bind paths

```bash
# Re-bind roots (SPEC-021 C1). Session bindings from S0/S2 injected by orchestrator.
_gc=$(git rev-parse --git-common-dir 2>/dev/null) \
  && MROOT=$(cd "$(dirname "$_gc")" && pwd) \
  || MROOT=$(pwd)
# lint-ok: C1 — BH_* session bindings from S0/S2; orchestrator injects before fence
: "${BH_REPORT_DIR:?BH_REPORT_DIR required}"  # lint-ok: C1
: "${BH_REPORT:?BH_REPORT required}"  # lint-ok: C1
: "${BH_DATE:?BH_DATE required}"  # lint-ok: C1
: "${BH_SLUG:?BH_SLUG required}"  # lint-ok: C1
mkdir -p "$BH_REPORT_DIR"
BH_FINDINGS="${BH_FINDINGS:-$BH_REPORT_DIR/${BH_DATE}-${BH_SLUG}.json}"
CREATED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)
printf 'BH_REPORT=%s\nBH_FINDINGS=%s\nCREATED_AT=%s\n' \
  "$BH_REPORT" "$BH_FINDINGS" "$CREATED_AT"
```

Resolve template path via PDH when needed:

```bash
# Re-bind roots + PDH (same formula as S0 §0a — fresh-shell safe)
_gc=$(git rev-parse --git-common-dir 2>/dev/null) \
  && MROOT=$(cd "$(dirname "$_gc")" && pwd) \
  || MROOT=$(pwd)
PDH="${PDH:-<PDH>}"   # session root carried from the stanza fence above — re-run that fence first when not held
BH_TMPL_REPORT=$(bash "$PDH/skills/plugin-dir.sh" file skills/bug-hunt/templates/report.md)
BH_TMPL_JSON=$(bash "$PDH/skills/plugin-dir.sh" file skills/bug-hunt/templates/findings.json)
```

### R1. Build fill values

| Placeholder | Value |
|-------------|--------|
| `{{PATH}}` | `BH_PATH` |
| `{{FLOOR}}` | `BH_FLOOR` |
| `{{SLUG}}` | `BH_SLUG` |
| `{{DATE}}` | `BH_DATE` |
| `{{CREATED_AT}}` | ISO-8601 UTC from R0 |
| `{{MANIFEST}}` | `BH_MANIFEST` one-line (teams + lenses + target + floor) |
| `{{S2_FLAVORS}}` | `BH_S2_FLAVORS` (default `logic+security` if unset and candidates empty) |
| `{{VERIFICATION_MODE}}` | `BH_VERIFICATION_MODE` (`full` \| `self-verified`) |
| `{{DEGRADED_BANNER}}` | if `BH_REFUTE_DEGRADED` or mode=`self-verified` or `BH_DISCOVER_DEGRADED`: blockquote `> **self-verified — refuters unavailable**`; else empty |
| `{{COUNTS}}` | multiline list (see below) |
| `{{CONFIRMED_ACTIONABLE}}` | AC8 blocks or `(none)` |
| `{{REFUTED_SUMMARY}}` | bullets or `(none)` |
| `{{DROPPED_SUMMARY}}` | bullets or `(none)` |
| `{{PHASE_DONE_M20}}` | exact S1 §1g phase-done block (session text) |
| `{{PHASE_DONE_M21}}` | exact S2 §2k phase-done block (session text) |
| `{{ZERO_ACTIONABLE_LINE}}` | `0 confirmed-actionable` when A==0; else `confirmed-actionable: <A>` (optional) |
| `{{REPORT_PATH}}` | `BH_REPORT` |
| `{{FINDINGS_JSON_PATH}}` | `BH_FINDINGS` if written; else `not written` |

**`{{COUNTS}}` exact shape (all five keys required):**

```
- candidates: <N>
- confirmed: <C>
- refuted: <R>
- dropped: <D>
- confirmed_actionable: <A>
```

Where `N=|candidates[]|` (pre-disposition count from S1; equals `|confirmed|+|refuted|`),
`C=|confirmed[]|`, `R=|refuted[]|`, `D=|dropped[]|`, `A=|confirmed_actionable[]|`.

**`{{CONFIRMED_ACTIONABLE}}` — full AC8 per item (M32 / AC8):**

```
### <id or index>
- **locator:** <non-empty>
- **severity:** critical|warning|nitpick
- **description:** <what is wrong>
- **evidence:** <investigator-backed>
- **status:** confirmed
```

When `A == 0`: set body to `(none)` and `{{ZERO_ACTIONABLE_LINE}}` to exact
`0 confirmed-actionable` (clean success — not an error; AC10).

**`{{REFUTED_SUMMARY}}`:** one bullet per refuted item:

```
- `<locator>` — <one-line reason from evidence>
```

**`{{DROPPED_SUMMARY}}`:** one bullet per dropped item:

```
- `<locator>` (`<reason>`) — <detail>
```

### R2. Write user-visible report (MUST)

1. Read `templates/report.md` (via `$BH_TMPL_REPORT`).
2. Substitute every `{{…}}` placeholder from R1 (leave no bare `{{` in output).
3. **Write** the filled markdown to `$BH_REPORT` with the **Write tool**.
   - **MUST NOT** use bash heredoc with `!` (zsh history expansion; skill-lint C2).
   - **MUST NOT** `git add` / commit the report (process artifact; M25).

### R3. Write findings JSON (SHOULD — C3 handoff)

1. Prefer schema shape in `templates/findings.json`.
2. Populate live arrays: `confirmed_actionable`, `confirmed`, `refuted`, `dropped`,
   `counts`, `manifest`, `path`, `severity_floor`, `verification_mode`, `phase_done`.
3. Write JSON to `$BH_FINDINGS` with the **Write tool** (same no-heredoc rule).
4. If Write fails or JSON omitted: set `{{FINDINGS_JSON_PATH}}` / session note to
   `not written` — report `.md` alone still satisfies M31 MUST.

### R4. Terminal summary + continue to S3

Print (stdout / user-visible):

```
Report: $BH_REPORT
counts: candidates=<N> confirmed=<C> refuted=<R> dropped=<D> confirmed_actionable=<A>
verification_mode: <full|self-verified>
```

If `A == 0`, also print exact:

```
0 confirmed-actionable
```

If degraded, also print exact:

```
self-verified — refuters unavailable
```

**Stages 1–2 report done.** Continuous path continues immediately to **S3a**
(OQ5). Resume entry already lands at S3a (no re-REPORT). Exit 0 even when A==0
at report time; S3 zero-path may still emit plan + M22 zeros (AC10).

**MUST NOT at REPORT boundary:**

- auto-materialize backlog without S3 plan + M8 proceed (AC4; M8)
- fix / implement / **invoke** `/orchestrate` / `/epic` (AC9/AC12; S4 is emit-only later)
- invent severity taxonomy or ticket lifecycle
- re-enter S1/S2

### R5. Session outputs (post-REPORT)

| Binding | Shape |
|---------|--------|
| `BH_REPORT` | absolute path written (MUST) |
| `BH_FINDINGS` | absolute path if SHOULD JSON written; else unset / `not written` |
| `BH_PLAN` | path string `$BH_REPORT_DIR/${BH_STEM}-plan.md` (bound; written in S3c) |
| `BH_PROCEED` | `none` \| `flag` (from S0; token set in S3d) |
| counts | five keys as in `{{COUNTS}}` |
| `confirmed_actionable[]` | unchanged from S2 (report listed them) |

---

