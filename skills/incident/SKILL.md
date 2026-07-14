---
name: incident
description: >
  DevOps-led war-room for production incidents (SPEC-027). Severity triage,
  parallel RO investigation, append-only timeline, propose-only mitigation,
  comms drafts, cold postmortem → backlog. User entry: /incident.
---

# incident

War-room coordination skill. **Not** a single-bug loop — that is `/debug`
(SPEC-014). This skill adds severity, parallel threads, durable artifacts,
comms drafts, and postmortem under time pressure.

Governing spec: `specs/core/SPEC-027-incident-war-room.md`.

## Components

```
skills/incident/
├── SKILL.md           (this file — protocol)
├── workspace.sh       ensure / list / resume-dump / path / meta-*
├── timeline.sh        append / render / validate  (jsonl-canonical)
└── timeline-test.sh   bite-tests
```

## Hard boundaries (M12)

- **MUST NOT** execute any state-changing action (deploy, revert, restart, config
  change, file edit outside `.claude/incidents/<id>/`) without **explicit
  per-action user confirmation**.
- **MUST NOT** call external paging/alerting/monitoring services (no Slack/
  PagerDuty/email send). Comms are local drafts only.
- **MUST NOT** edit or delete existing timeline entries (corrections = new entries).
- **MUST NOT** reimplement `/debug` gates or SPEC-009 backlog formats.
- **MUST NOT** write incident state into `memory.db` or `.claude/handoff/`.
- Timeline writes **only** via `timeline.sh append` — never hand-edit
  `timeline.jsonl` or `timeline.md`.

## Trust boundary

`<description>` and free-text fields from the user are **untrusted**. Slug
generation is owned by `workspace.sh` (lower alnum/hyphen, max 40). Never
interpolate raw DESC into shell without quoting. Never use DESC as a path
component without going through `workspace.sh ensure`.

## Arguments / parser

| Form | Subcommand | Notes |
|------|------------|-------|
| `/incident <description>` | `open` | Default; entire args = description |
| `/incident` | `open` | Prompt for description first |
| `/incident resume <id>` | `resume` | Reconstruct from incident dir only |
| `/incident postmortem <id>` | `postmortem` | Cold assemble `postmortem.md` |
| `/incident list` | `list` | List incident ids |

**Parser rule:** if the first token is exactly `resume`, `postmortem`, or
`list` (case-sensitive), that is the subcommand; remainder is the id (if any).
Otherwise the entire argument string is the open description.

Severity values (exact): `SEV1` | `SEV2` | `SEV3`.

---

## Step 0: Load project context

Resolve roots (re-resolve in **every** bash block — skill-lint C1):

```bash
_gc=$(git rev-parse --git-common-dir 2>/dev/null) \
  && MROOT=$(cd "$(dirname "$_gc")" && pwd) \
  || MROOT=$(pwd)
WTROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
```

Resolve script paths via plugin-dir when available:

```bash
_gc=$(git rev-parse --git-common-dir 2>/dev/null) \
  && MROOT=$(cd "$(dirname "$_gc")" && pwd) \
  || MROOT=$(pwd)
PDH=$( [ -f skills/plugin-dir.sh ] && pwd || find ~/.claude/plugins/cache -path '*/dev-team/*/skills/plugin-dir.sh' 2>/dev/null | sort -V | tail -1 | xargs -r dirname | xargs -r dirname )
if [ -n "${PDH:-}" ] && [ -f "$PDH/skills/plugin-dir.sh" ]; then
  WS=$(bash "$PDH/skills/plugin-dir.sh" file skills/incident/workspace.sh)
  TL=$(bash "$PDH/skills/plugin-dir.sh" file skills/incident/timeline.sh)
else
  WS="$MROOT/skills/incident/workspace.sh"
  TL="$MROOT/skills/incident/timeline.sh"
fi
# Dev checkout / worktree fallback
[ -f "${WS:-}" ] || WS="$(pwd)/skills/incident/workspace.sh"
[ -f "${TL:-}" ] || TL="$(pwd)/skills/incident/timeline.sh"
```

Read `AGENTS.md` if present. Load devops memory only as background context —
**incident state is never stored in memory.db**.

---

## Step 1: Dispatch subcommand

### `list`

```bash
_gc=$(git rev-parse --git-common-dir 2>/dev/null) \
  && MROOT=$(cd "$(dirname "$_gc")" && pwd) \
  || MROOT=$(pwd)
PDH=$( [ -f skills/plugin-dir.sh ] && pwd || find ~/.claude/plugins/cache -path '*/dev-team/*/skills/plugin-dir.sh' 2>/dev/null | sort -V | tail -1 | xargs -r dirname | xargs -r dirname )
WS=$( [ -n "${PDH:-}" ] && [ -f "$PDH/skills/plugin-dir.sh" ] && bash "$PDH/skills/plugin-dir.sh" file skills/incident/workspace.sh || true )
[ -f "${WS:-}" ] || WS="$(pwd)/skills/incident/workspace.sh"
bash "$WS" list
```

Present the id list (or "no incidents"). Stop.

### `resume` → Step R

### `postmortem` → Step P

### `open` → Step O (below)

---

## Step O — Open incident (M1 / M2)

### O.1 Description gate

If description is empty, ask: `What production incident are we responding to?`
and wait. Do **not** create a workspace yet.

### O.2 Severity proposal (GATE — no threads before confirm)

Propose exactly one of `SEV1` | `SEV2` | `SEV3` with:

1. One-paragraph rationale grounded in the description
2. A **quick** blast-radius probe (read-only: recent `git log -5 --oneline`,
   obvious service names in DESC — no deep investigation)

Present:

```
## Severity proposal
- Proposed: SEV2
- Rationale: …
- Quick blast: …

Confirm severity (SEV1|SEV2|SEV3), or override. No investigation threads will
start until you confirm.
```

**GATE:** wait for user confirm/override. **MUST NOT** spawn investigation
threads, write workspace artifacts (except nothing yet), or mutate files
before confirmation.

### O.3 On confirm — create workspace + decision + comms

```bash
_gc=$(git rev-parse --git-common-dir 2>/dev/null) \
  && MROOT=$(cd "$(dirname "$_gc")" && pwd) \
  || MROOT=$(pwd)
PDH=$( [ -f skills/plugin-dir.sh ] && pwd || find ~/.claude/plugins/cache -path '*/dev-team/*/skills/plugin-dir.sh' 2>/dev/null | sort -V | tail -1 | xargs -r dirname | xargs -r dirname )
WS=$( [ -n "${PDH:-}" ] && [ -f "$PDH/skills/plugin-dir.sh" ] && bash "$PDH/skills/plugin-dir.sh" file skills/incident/workspace.sh || true )
TL=$( [ -n "${PDH:-}" ] && [ -f "$PDH/skills/plugin-dir.sh" ] && bash "$PDH/skills/plugin-dir.sh" file skills/incident/timeline.sh || true )
[ -f "${WS:-}" ] || WS="$(pwd)/skills/incident/workspace.sh"
[ -f "${TL:-}" ] || TL="$(pwd)/skills/incident/timeline.sh"

# Session values (set from user confirm — re-bound here for C1)
DESC="<user-confirmed description>"
SEV="SEV1|SEV2|SEV3"   # exact confirmed value
INC_DIR=$(bash "$WS" ensure "$DESC")
INC_ID=$(basename "$INC_DIR")

bash "$TL" append "$INC_ID" --actor user --type decision \
  --summary "Severity confirmed: $SEV" \
  --detail "Description: $DESC" \
  --refs "sev:$SEV"

# Update meta severity + status
python3 - "$INC_DIR/meta.json" "$SEV" <<'PY'
import json, sys
path, sev = sys.argv[1], sys.argv[2]
with open(path, encoding="utf-8") as f:
    m = json.load(f)
m["severity"] = sev
m["status"] = "investigating"
with open(path, "w", encoding="utf-8") as f:
    json.dump(m, f, indent=2, ensure_ascii=False)
    f.write("\n")
PY
```

Write `comms/001-opened.md` (see Step C for template). Then continue to
parallel threads (Step T).

---

## Step T — Parallel read-only investigation (M5)

After severity confirmation, dispatch **in one parallel tool-use block** at
minimum these three threads (names exact for logging):

| Thread | Focus | Tools |
|--------|-------|-------|
| **change-correlation** | Recent deploys/merges/config via `git log` / `git diff`; CI via `gh` if present | read-only git; optional `gh` |
| **symptom-evidence** | Logs, stack traces, error output the user pointed at | Read only |
| **blast-radius** | Affected surfaces/consumers; feeds severity revision | Read only |

Rules:

- Threads **MUST be read-only** — no file mutation outside the incident dir.
- `gh` absent or unauthenticated → skip CI with a one-line note (M11); never error.
- Each thread's findings → `timeline.sh append` as `type=observation` with
  resolvable refs (`commit:…`, `file:path:L#`, `log:path`).
- Commander (devops posture) synthesizes a status update after threads return.

Optional severity revision: if blast-radius changes impact, propose new SEV →
user confirm → `decision` entry + new comms draft (Step C).

```bash
_gc=$(git rev-parse --git-common-dir 2>/dev/null) \
  && MROOT=$(cd "$(dirname "$_gc")" && pwd) \
  || MROOT=$(pwd)
PDH=$( [ -f skills/plugin-dir.sh ] && pwd || find ~/.claude/plugins/cache -path '*/dev-team/*/skills/plugin-dir.sh' 2>/dev/null | sort -V | tail -1 | xargs -r dirname | xargs -r dirname )
TL=$( [ -n "${PDH:-}" ] && [ -f "$PDH/skills/plugin-dir.sh" ] && bash "$PDH/skills/plugin-dir.sh" file skills/incident/timeline.sh || true )
[ -f "${TL:-}" ] || TL="$(pwd)/skills/incident/timeline.sh"
# Re-bind session state in this block (skill-lint C1 — blocks are separate shells)
INC_ID="<active-incident-id>"
SUMMARY="<thread finding summary>"
DETAIL="<optional detail>"
REFS="<comma-separated refs>"
bash "$TL" append "$INC_ID" --actor devops --type observation \
  --summary "$SUMMARY" --detail "$DETAIL" --refs "$REFS"
```

---

## Step M — Mitigation (M7 / M12)

Order proposals **rollback-first**:

1. Revert correlated deploy/commit/config
2. Only then forward-fix (feature flag, scale, patch)

Each proposal MUST name: exact command(s)/change, expected effect, risk.

Store the active proposal in `meta.json` → `pending_proposal`:

```bash
_gc=$(git rev-parse --git-common-dir 2>/dev/null) \
  && MROOT=$(cd "$(dirname "$_gc")" && pwd) \
  || MROOT=$(pwd)
PDH=$( [ -f skills/plugin-dir.sh ] && pwd || find ~/.claude/plugins/cache -path '*/dev-team/*/skills/plugin-dir.sh' 2>/dev/null | sort -V | tail -1 | xargs -r dirname | xargs -r dirname )
WS=$( [ -n "${PDH:-}" ] && [ -f "$PDH/skills/plugin-dir.sh" ] && bash "$PDH/skills/plugin-dir.sh" file skills/incident/workspace.sh || true )
TL=$( [ -n "${PDH:-}" ] && [ -f "$PDH/skills/plugin-dir.sh" ] && bash "$PDH/skills/plugin-dir.sh" file skills/incident/timeline.sh || true )
[ -f "${WS:-}" ] || WS="$(pwd)/skills/incident/workspace.sh"
[ -f "${TL:-}" ] || TL="$(pwd)/skills/incident/timeline.sh"
INC_ID="<active-incident-id>"
PROPOSAL_TITLE="<short proposal title>"
PROPOSAL_DETAIL="<exact commands, expected effect, risk>"
PROPOSAL_JSON='{"title":"…","commands":["…"],"risk":"…"}'
INC_DIR=$(bash "$WS" path "$INC_ID")

bash "$TL" append "$INC_ID" --actor devops --type decision \
  --summary "Mitigation proposed (awaiting confirm): $PROPOSAL_TITLE" \
  --detail "$PROPOSAL_DETAIL"

python3 - "$INC_DIR/meta.json" "$PROPOSAL_JSON" <<'PY'
import json, sys
path, raw = sys.argv[1], sys.argv[2]
with open(path, encoding="utf-8") as f:
    m = json.load(f)
m["pending_proposal"] = json.loads(raw)
m["status"] = "mitigating"
with open(path, "w", encoding="utf-8") as f:
    json.dump(m, f, indent=2, ensure_ascii=False)
    f.write("\n")
PY
```

**GATE:** wait for explicit per-action user confirmation.

- **Decline** → append `decision` ("user declined: …"); clear
  `pending_proposal`; execute nothing.
- **Confirm** → user or agent runs the named action; append `action` entry;
  clear `pending_proposal`; write comms draft.

No state-changing commands outside `.claude/incidents/<id>/` without this gate.

---

## Step D — `/debug` delegation (M6)

When a **code-level** root cause is suspected:

- **Delegate** to `/debug` (SPEC-014) as a sub-flow — **never reimplement** its
  loop or relax root-cause-before-edit / failing-test-first / self-calibration.
- Commander MAY choose **mitigation-first**: defer the fix phase until after
  mitigation; the deferred fix becomes a postmortem action item (Step P).
- Capture `/debug` root-cause statement as an `observation` (or link via refs).

---

## Step Q — QA gate before `mitigated` (M4)

An incident **MUST NOT** transition `meta.status` to `mitigated` until a
QA-validation timeline entry exists:

- actor `qa` (or `user` with explicit attestation), type `observation` or
  `action`, summary clearly a validation/smoke result.

```bash
_gc=$(git rev-parse --git-common-dir 2>/dev/null) \
  && MROOT=$(cd "$(dirname "$_gc")" && pwd) \
  || MROOT=$(pwd)
PDH=$( [ -f skills/plugin-dir.sh ] && pwd || find ~/.claude/plugins/cache -path '*/dev-team/*/skills/plugin-dir.sh' 2>/dev/null | sort -V | tail -1 | xargs -r dirname | xargs -r dirname )
WS=$( [ -n "${PDH:-}" ] && [ -f "$PDH/skills/plugin-dir.sh" ] && bash "$PDH/skills/plugin-dir.sh" file skills/incident/workspace.sh || true )
TL=$( [ -n "${PDH:-}" ] && [ -f "$PDH/skills/plugin-dir.sh" ] && bash "$PDH/skills/plugin-dir.sh" file skills/incident/timeline.sh || true )
[ -f "${WS:-}" ] || WS="$(pwd)/skills/incident/workspace.sh"
[ -f "${TL:-}" ] || TL="$(pwd)/skills/incident/timeline.sh"
INC_ID="<active-incident-id>"
INC_DIR=$(bash "$WS" path "$INC_ID")

# After QA-validation entry is on the timeline:
python3 - "$INC_DIR/meta.json" <<'PY'
import json, sys
path = sys.argv[1]
with open(path, encoding="utf-8") as f:
    m = json.load(f)
m["status"] = "mitigated"
m["pending_proposal"] = None
with open(path, "w", encoding="utf-8") as f:
    json.dump(m, f, indent=2, ensure_ascii=False)
    f.write("\n")
PY
```

**SHOULD** (SEV1): offer `/council` (SPEC-013) on the "mitigated" claim before
declaring resolution.

On resolution: set `status=resolved`, write final comms, offer postmortem
(Step P). **SHOULD** append one-line devops learnings via memory-store
(SPEC-004) — not incident state.

---

## Step C — Comms drafts (M8)

On each material state change write the next
`.claude/incidents/<id>/comms/NNN-<slug>.md`:

| Trigger | Example slug |
|---------|----------------|
| Severity confirmed | `001-opened` |
| Severity change | `00N-severity-change` |
| Mitigation proposed | `00N-mitigation-proposed` |
| Mitigation executed | `00N-mitigation-executed` |
| Mitigation validated | `00N-mitigation-validated` |
| Resolution | `00N-resolved` |

Sequence: next integer after highest existing `comms/NNN-*.md` (zero-pad 3).

Required fields in every draft:

- Severity
- Current impact
- What is known
- Current status
- Next-update expectation

Cadence defaults (user-overridable):

| SEV | Next-update default |
|-----|---------------------|
| SEV1 | ≈ 30 minutes |
| SEV2 | ≈ 2 hours |
| SEV3 | ≈ daily |

**MUST NOT** transmit drafts on any network. User pastes into their channels.

---

## Step R — Resume (M2)

`/incident resume <id>`:

```bash
_gc=$(git rev-parse --git-common-dir 2>/dev/null) \
  && MROOT=$(cd "$(dirname "$_gc")" && pwd) \
  || MROOT=$(pwd)
PDH=$( [ -f skills/plugin-dir.sh ] && pwd || find ~/.claude/plugins/cache -path '*/dev-team/*/skills/plugin-dir.sh' 2>/dev/null | sort -V | tail -1 | xargs -r dirname | xargs -r dirname )
WS=$( [ -n "${PDH:-}" ] && [ -f "$PDH/skills/plugin-dir.sh" ] && bash "$PDH/skills/plugin-dir.sh" file skills/incident/workspace.sh || true )
[ -f "${WS:-}" ] || WS="$(pwd)/skills/incident/workspace.sh"
INC_ID="<id-from-user-args>"
bash "$WS" resume-dump "$INC_ID"
```

- Reconstruct war-room state **solely from the incident directory** (meta +
  jsonl + comms). No transcript parse, no `memory.db`, no `.claude/handoff/`.
- If dir missing → refuse with clear error.
- Re-enter at: open `pending_proposal` (await confirm/decline), or current
  `status` for next commander action.

---

## Step P — Postmortem + backlog (M9 / M10)

`/incident postmortem <id>` (also offered at resolution):

1. Build `postmortem.md` **only** from `meta.json` + `timeline.jsonl` +
   `comms/` + any existing notes under the incident dir — works cold in a
   fresh session.
2. Required sections:
   - Incident summary (severity, duration, impact)
   - Assembled timeline
   - Root-cause chain
   - 5-whys
   - What-went-well / what-went-poorly
   - Numbered action items (each with suggested owner role)
3. Offer each action item for conversion via SPEC-009 `/backlog add` (cite
   `skills/backlog/SKILL.md` — do not reimplement formats).
4. User-accepted items: create via backlog skill; back-reference slugs next to
   the corresponding AI in `postmortem.md`.

---

## Timeline schema (jsonl canonical)

```json
{
  "id": "e001",
  "ts": "2026-07-14T18:00:00Z",
  "actor": "devops",
  "type": "decision",
  "summary": "Severity confirmed: SEV2",
  "detail": "",
  "refs": ["sev:SEV2"]
}
```

`type` ∈ {`observation`, `action`, `decision`}. `timeline.md` is a full render
from jsonl after every append.

---

## Related

- SPEC-027 (this skill), SPEC-014 `/debug`, SPEC-003 devops/qa roles,
  SPEC-009 backlog, SPEC-013 council (SHOULD on SEV1 mitigated), SPEC-018
  handoff (disjoint namespace), SPEC-004 memory (optional close learnings)
- User entry: `commands/incident.md`
