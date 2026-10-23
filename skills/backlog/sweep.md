<!-- /backlog sweep — the one operational copy of the sweep protocol (SPEC-002 D1,
     SPEC-040 M2). skills/backlog/SKILL.md points here; skills/backlog/sweep.sh is
     the helper CLI. Do not inline this protocol into SKILL.md. -->

# Subcommand: `sweep [flags]`

A Backlog sweep is a composition layer over `/backlog` and `/orchestrate`
(SPEC-040). It walks every open backlog item once, runs a Purge pre-pass, then
a size-ascending serial walk. It edits no product code and runs no release.

Cite these contracts; this file does not restate them: SPEC-009 (list, close,
backlog root, write lock), SPEC-013 (`--council-tier`), SPEC-016 (serial
worktrees), SPEC-025 (`parentId`, `epic_parent`), SPEC-033 (autopilot,
decision-cards, blocking-condition, nest-host), SPEC-040 (requirement ids
M5–M25).

## Flags

| Flag | Effect | Requirement |
|------|--------|-------------|
| `--ship=<pr\|master\|patch\|minor\|major>` | Compiled to `/orchestrate` autopilot argv; omitted = attended, so the walk runs with no autopilot flag | M17 |
| `--limit <N>` | Bounds code-bearing `/orchestrate` runs only; the Purge pre-pass stays full; `0` = no bound | M18 |
| `--project <X>` | Filters the Linear query only; never filters the local set | M5 |
| `--refresh` | Re-judge every item; ignore the journal | M22 |
| `--skip-decided` | Skip any item with a terminal journal outcome | M22 |
| `--autopilot` | Zero human turns; every would-be ASK becomes DEFER | M23 |

`--refresh` with `--skip-decided` is a usage error: exit 64 before any write.

## Step 0: Resolve the helpers and the shared root

Every fence below runs in a fresh shell. Run this fence first and carry its
bindings (`SWEEP`, `NEST_HOST`, `MROOT`, `SWEEP_DIR`, `TMPD`) through the sweep
session; a later fence that names one carries a `lint-ok: C1` note.

```bash
# Locate the dev-team plugin root (PDH), then the sweep CLI and the nest probe.
# lint-ok: C3 — marketplace */ for-loop + -f guarded (SPEC-021 Q2 residual, CDT-82 PDH)
PDH=$( { [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -f "$CLAUDE_PLUGIN_ROOT/skills/plugin-dir.sh" ] && printf '%s\n' "$CLAUDE_PLUGIN_ROOT"; } || { [ -f skills/plugin-dir.sh ] && [ -f agents/pm.md ] && grep -qF '"name": "dev-team"' .claude-plugin/plugin.json 2>/dev/null && pwd; } || { _pr='${CLAUDE_PLUGIN_ROOT}'; [ "${_pr#\$}" = "$_pr" ] && [ -f "$_pr/skills/plugin-dir.sh" ] && printf '%s\n' "$_pr"; } || { for _mp in "$HOME"/.claude/plugins/marketplaces/*/; do [ -f "${_mp}skills/plugin-dir.sh" ] && [ -f "${_mp}agents/pm.md" ] && grep -qF '"name": "dev-team"' "${_mp}.claude-plugin/plugin.json" 2>/dev/null && printf '%s\n' "${_mp%/}" && break; done; } || find ~/.claude/plugins/cache \( -path '*/dev-team/*/skills/plugin-dir.sh' -o -path '*/dev-team-edge/*/skills/plugin-dir.sh' \) 2>/dev/null | awk -F/ '{ver=""; for(i=1;i<=NF;i++) if(($i=="dev-team"||$i=="dev-team-edge")&&i<NF){ver=$(i+1);break}; if(ver=="") next; m=ver; gsub(/-pre\./,"~pre.",m); p=($0 ~ /\/cache\/cold-dark-void\/dev-team\//)?2:(($0 ~ /\/cache\/cold-dark-void\/dev-team-edge\//)?1:0); print m "\t" p "\t" $0}' | sort -t $'\t' -k1,1V -k2,2n -k3,3 | tail -1 | cut -f3 | xargs -r dirname | xargs -r dirname )
SWEEP=$(bash "$PDH/skills/plugin-dir.sh" file skills/backlog/sweep.sh)
DEFER=$(bash "$PDH/skills/plugin-dir.sh" file skills/backlog/defer.sh)
NEST_HOST=$(bash "$PDH/skills/plugin-dir.sh" file skills/autopilot/nest-host.sh)
_gc=$(git rev-parse --git-common-dir 2>/dev/null) \
  && MROOT=$(cd "$(dirname "$_gc")" && pwd) \
  || MROOT=$(pwd)
SWEEP_DIR="$MROOT/.claude/sweeps"
TMPD=$(mktemp -d "${TMPDIR:-/tmp}/backlog-sweep.XXXXXX")
```

`sweep.sh`, `defer.sh`, and `close.sh` are subprocess CLIs. Never source them.
Every linked worktree reads and writes the one shared store (SPEC-009 § Backlog
root rule).

## Step 1: Parse the flags

```bash template
# <user-flags> is the text the user typed after `sweep`, split on spaces.
set -f
set -- <user-flags>
set +f
# lint-ok: C1 — SWEEP is carried from Step 0 in this sweep session
if ! FLAGS=$(bash "$SWEEP" parse-flags "$@"); then
  printf 'sweep: bad flags — stop (exit 64)\n'
  exit 64
fi
```

`FLAGS` is one JSON object: `ship`, `limit`, `project`, `refresh`,
`skip_decided`, `autopilot`. Under `--autopilot` an unset `--ship` defaults to
`master` (M17). On exit 64, report the usage line and write nothing.

## Step 2: Snapshot the tag baseline

```bash
# lint-ok: C1 — SWEEP and MROOT are carried from Step 0 in this sweep session
TAG=$(bash "$SWEEP" last-release-tag --root "$MROOT")
TAG_DATE=""
if [ -n "$TAG" ]; then
  # sweep.sh tag-date is the source of truth for this resolution.
  TAG_DATE=$(bash "$SWEEP" tag-date --root "$MROOT" --tag "$TAG")
  printf 'baseline: %s %s\n' "$TAG" "$TAG_DATE"
else
  printf 'baseline: no release tag (the Step 5 date skip never fires)\n'
fi
```

`TAG` is the last **release** tag (M21); `last-release-tag` applies
`is_release_tag`, so a non-release tag is never the baseline. Tags created
mid-walk MUST NOT move it: reuse this `TAG` and `TAG_DATE` in every later step.

`TAG_DATE` is the annotated tagger date, else the committer date of the commit
the tag points at (M22) — the two-step resolution `sweep.sh tag-date` implements,
the same one the shipped-after evidence uses. An annotated tag has no
`committerdate` on the tag ref, so asking for that one alone reports an empty
baseline for it. An empty `TAG_DATE` stays fail-open: the Step 5 date skip never
fires and every journaled item is judged again.

## Step 3: Enumerate the open set (M5, M6)

You (the session) own every Linear MCP call; `sweep.sh` is bash-only and never
calls MCP.

1. When the Linear MCP is reachable, call `list_issues` for open issues
   (SPEC-009 list semantics: exclude terminal states). Request `fields` that
   include `parentId` and `priority`. Apply `--project` on this query only.
   Page until exhausted. `list_issues.orderBy` has no priority field, so the
   walk sort is client-side (Step 9, M16).
2. Write the response to `"$TMPD/linear.json"`.
3. When MCP is absent, unauthenticated, times out, or errors per issue: print
   exactly one line `Linear unreachable — local backlog only.`, leave
   `"$TMPD/linear.json"` empty, and continue. MUST NOT retry-loop (M6).

```bash
# lint-ok: C1 — TMPD is carried from Step 0 in this sweep session
: > "$TMPD/linear.json"
# Fill "$TMPD/linear.json" from list_issues when MCP is up; leave it empty when down.
# lint-ok: C1 — TMPD, SWEEP and MROOT are carried from Step 0 in this sweep session
bash "$SWEEP" merge-open --linear-json "$TMPD/linear.json" --local-root "$MROOT" \
  > "$TMPD/open.jsonl" || exit 1
```

`merge-open` emits one JSONL object per open item, unique by `linear_id` then
slug, and includes local-only PENDING rows (M5). Object fields: `slug`,
`linear_id`, `title`, `priority`, `added`, `source` (`linear` | `local` |
`both`), `status`, `epic_parent`, `epic_child`, `size`. A row with `source`
`linear` carries an empty `slug` (M11). `size` is empty here; Step 9 fills it.

## Step 4: Skip epic children (M7)

Drop every row whose `epic_child` is true — local `epic_parent` frontmatter or
a non-empty Linear `parentId` (SPEC-025). `merge-open` derives that field; use
the CLI to confirm a row where it is absent:

```bash template
# lint-ok: C1 — SWEEP and MROOT are carried from Step 0 in this sweep session
bash "$SWEEP" is-epic-child --frontmatter "$MROOT/.claude/backlog/<slug>.md"  # exit 0 = skip
bash "$SWEEP" is-epic-child --parent-id "<parentId>"                         # empty id = exit 1
```

Count the drops in the `SKIP` bucket. Run no triage and write no journal record
for them (M7, M22). Write the survivors to `"$TMPD/judge.jsonl"` — the set the
purge and the walk run over.

## Step 5: Re-run skip (M22)

For each row of `"$TMPD/judge.jsonl"`, pick the journal stem: the `slug`, else
the `linear_id` (M20).

```bash template
STEM="<slug>"; [ -n "$STEM" ] || STEM="<linear-id>"
# lint-ok: C1 — SWEEP_DIR is carried from Step 0; TAG_DATE comes from Step 2
JOURNAL="$SWEEP_DIR/$STEM.jsonl"
# Forward --refresh or --skip-decided here when Step 1 reported them.
# lint-ok: C1 — SWEEP is carried from Step 0 in this sweep session
if bash "$SWEEP" journal-skip --file "$JOURNAL" --tag-date "$TAG_DATE"; then
  printf 'SKIP %s (journal outcome at or after the baseline)\n' "$STEM"
else
  printf 'JUDGE %s\n' "$STEM"
fi
```

Exit 0 means skip: print the reason line the verb emits, drop the row from
`"$TMPD/judge.jsonl"`, and put the item in the `SKIP` bucket with no new journal
record. Exit 1 means re-judge: keep the row. An intent record with no `outcome`
re-judges. An empty `TAG_DATE` never skips on the date compare (M21).

Steps 6 to 10 run over `"$TMPD/judge.jsonl"` — the full open set minus the Step 4
and Step 5 skips. `--limit` never shrinks it (M18).

## Step 6: Purge pre-pass (M8–M10)

Judge every item in that set before any `/orchestrate` spawn. Do not interleave
(M8).

Look for a staleness signal: cited `Affects` paths that no longer exist, a fix a
later release already shipped, an `Added` date far behind the baseline, a goal
the codebase already meets. Then test the signal against the Mechanical evidence
bar (M9). The two verbs below carry the bar and print the cites you paste into
the batch:

```bash template
# (a) Cited Affects paths absent at HEAD. Paths are argv, repo-relative, one per word.
# lint-ok: C1 — SWEEP and MROOT are carried from Step 0 in this sweep session
bash "$SWEEP" evidence-paths-absent --root "$MROOT" -- "<path-one>" "<path-two>"
# (b) Shipped after creation. --added is the item *Added:* date.
bash "$SWEEP" evidence-shipped-after --root "$MROOT" --added "<YYYY-MM-DD>"
```

| Result | Disposition |
|--------|-------------|
| Exit 0 with two cites, counts, and a date | `CLOSE` candidate |
| Staleness signal, bar not met | `ASK` (M10) — never a silent close |
| No staleness signal | keep open → the walk (Step 9) |
| `grep` says the symbol exists | `ASK` only — there is no symbol-evidence verb; never `CLOSE` on it |

An item with no local file (`source` `linear`, empty `slug`) is `ASK`, never
`CLOSE` — `close.sh` needs a slug (M11).

## Step 7: Batch, answers, and the autopilot conversion (M12, M23)

Print **one** batch listing over all `CLOSE` and `ASK` items, then act:

```
Purge pre-pass (N items)
<slug> | CLOSE | <mechanical evidence: cites, counts, date>
<slug> | ASK    | <signal, and what the evidence lacks>
```

**Attended.** Ask once: accept-all, or name the items to remove from the `CLOSE`
set. For each `ASK`, ask close / run / defer. Each answer becomes a terminal
Disposition before the walk starts (M12). A `CLOSE` the user removes falls back
to `ASK` → close / run / defer.

**`--autopilot`.** Ask nothing (M23). `CLOSE` only at the M9 bar. Convert every
would-be `ASK` to `DEFER`, and put the missing-evidence reason in the journal
record. Never auto-close on inference.

## Step 8: Journal, then apply (M13, M14, M20)

Write the **intent** record before the side effect, then the **completed**
record after it. Same file, same key shape (`ts` is `YYYY-MM-DDThh:mm`, UTC):

```bash template
NOW=$(date -u +%Y-%m-%dT%H:%M)
# Intent record: no "outcome" key.
# lint-ok: C1 — JOURNAL comes from Step 5 and TAG from Step 2 in this sweep session
REC="{\"ts\":\"$NOW\",\"disposition\":\"CLOSE\",\"evidence\":\"<mechanical evidence text>\",\"args\":\"close.sh <slug> --ticket <ID>\",\"tag_baseline\":\"$TAG\"}"
# lint-ok: C1 — SWEEP is carried from Step 0 in this sweep session
bash "$SWEEP" journal-append --file "$JOURNAL" --json "$REC" || exit 1
```

The completed record repeats the same object with `"outcome":"<value>"` added:

| Outcome | When |
|---------|------|
| `closed` | The close verb flipped the item |
| `shipped` | A walk run landed code |
| `pr-stopped` | A walk run stopped at a gate: a blocking-condition halt, or any child halt outcome, whose name the `evidence` string carries |
| `deferred` | A DEFER applied |
| `asked-answered` | An attended ASK answer applied |

A run that stops between the two records leaves an intent record with no
outcome, so Step 5 re-judges that item and the verbs run again. `close.sh` and
`defer.sh` are idempotent (SPEC-009), so the local re-run changes nothing; the
Linear terminal call is best-effort and reports the already-terminal issue.

Apply the dispositions with verbs only (M13). Never hand-write
`.claude/backlog.md` or an item file.

- `CLOSE` → `/backlog close`, per `skills/backlog/SKILL.md` § Subcommand: `close`
  (Linear terminal when MCP is up, then `close.sh`; both are idempotent).
- `DEFER` with a slug → `defer.sh`, which writes `**Status**: DEFERRED` — an
  open status (SPEC-009) — under the shared backlog lock. It does not touch
  Linear, does not prune, and is idempotent:

```bash template
# lint-ok: C1 — DEFER and MROOT are carried from Step 0 in this sweep session
bash "$DEFER" "<slug>" --root "$MROOT" --note "<reason>"
```

- `DEFER` with no slug (Linear-only) → journal only, keyed by the issue id
  (M11). MUST NOT call `defer.sh`.
- Under `--autopilot`, a DEFER from Step 7 carries
  `"evidence":"missing-evidence: <what the bar lacked>"`.

## Step 9: Triage size, then walk (M15, M16, M18, M19)

Size each remaining item from cheap signals only. MUST NOT spawn an agent to
size (M15):

1. Use the item's `Effort` value when it is `S`, `M`, or `L`.
2. Otherwise count the `## Affects` paths: 0–1 paths → `S`; 2 paths → `M`;
   3 or more → `L`.
3. Escalate one step when the title or body names architecture, migration,
   schema, protocol, engine, new subsystem, split, or epic. Drop to `S` when it
   names typo, copy, rename, config, log, or docs and `Affects` is empty.
4. Default to `M`. `/orchestrate` Step 2 stays the size authority (SPEC-009).

Write the sizes into the `size` field of each row of `"$TMPD/judge.jsonl"`,
through `jq --arg` over that file — never by editing backlog files, never with
`eval` (M25). Drop the rows Step 7 closed or deferred: the walk runs over what
is left. Then sort:

```bash
# lint-ok: C1 — SWEEP and TMPD are carried from Step 0 in this sweep session
bash "$SWEEP" walk-sort < "$TMPD/judge.jsonl" > "$TMPD/walk.jsonl" || exit 1
```

Order is size ascending (`S`, `M`, `L`), then Linear priority 1, 2, 3, 4, 0,
then local-only rows last by `added` ascending (M16).

Run the walk **strict serial** (SPEC-016): one `/orchestrate` at a time, never
parallel `git worktree` operations. For each item, in order:

**9a. Respect the bound.** Stop the walk when `--limit` runs are reached;
`--limit` counts these runs only (M18). Every item the bound truncates goes in
the `SKIP` bucket, so the buckets still sum to N open (M24).

**9b. Compile the argv.** Pass `--council-tier` only when the user set it
(SPEC-013), and pass `--ship` only when Step 1 reported one:

```bash template
# lint-ok: C1 — SWEEP is carried from Step 0; SHIP and COUNCIL_TIER come from Step 1
ARGS=$(bash "$SWEEP" compile-orchestrate-args --size "<S|M|L>" --ship "<val>")
# Attended sweep with no --ship: pass no --ship and the line carries no autopilot argv.
ARGS=$(bash "$SWEEP" compile-orchestrate-args --size "<S|M|L>")
```

The compiled line carries `--tier=light` for `S`, no `--tier` for `M`,
`--tier=full` for `L`, then the compiled autopilot argv. The literal `--ship`
never appears in it and MUST NOT reach `/orchestrate` (M17). With no `--ship`,
the verb emits the tier (and `--council-tier` when set) and nothing else: run
`/orchestrate` with no autopilot flag (the attended Step-11 gate).

**9c. Journal the intent.** An `ORCHESTRATE` record whose `args` field is the
compiled line (Step 8's fence).

**9d. Probe the host, then run (M19).**

```bash template
# lint-ok: C1 — NEST_HOST is carried from Step 0 in this sweep session
if bash "$NEST_HOST" --ticket "<ISSUE-ID>" can-spawn-agents; then
  # lint-ok: C1 — ARGS is carried from Step 9b in this sweep session
  printf 'nested run: /orchestrate <slug-or-title> %s\n' "$ARGS"
else
  # lint-ok: C1 — ARGS is carried from Step 9b in this sweep session
  printf 'print-and-run this turn: /orchestrate <slug-or-title> %s\n' "$ARGS"
fi
```

On true, invoke `/orchestrate` for that item as the host supports. On false,
print the compiled line and run it in the current host turn. MUST NOT claim a
nested agent spawn on that host.

**9e. Journal the outcome.** Write the completed record with one of the Step 8
outcomes. Each spawned run emits its own decision-cards (SPEC-033).

The journal outcome enum is closed (M20): `closed`, `shipped`, `pr-stopped`,
`deferred`, `asked-answered`. A child run that halts names its own blocking
condition (`complexity-overflow`, `bc5-reroute`, …), which is not an enum value,
so map **any** child halt outcome to the enum value `pr-stopped` and keep the
name in the record's `evidence` string. `walk-outcome` prints the enum value for
the run:

```bash template
# lint-ok: C1 — SWEEP is carried from Step 0 in this sweep session
OC=$(bash "$SWEEP" walk-outcome --landed)                # shipped
OC=$(bash "$SWEEP" walk-outcome --halt "<named-condition>")   # pr-stopped
NOW=$(date -u +%Y-%m-%dT%H:%M)
# lint-ok: C1 — JOURNAL comes from Step 5, TAG from Step 2, ARGS from Step 9b
REC="{\"ts\":\"$NOW\",\"disposition\":\"ORCHESTRATE\",\"evidence\":\"halt: <named-condition>\",\"args\":\"$ARGS\",\"tag_baseline\":\"$TAG\",\"outcome\":\"$OC\"}"
# lint-ok: C1 — SWEEP is carried from Step 0 in this sweep session
if ! bash "$SWEEP" journal-append --file "$JOURNAL" --json "$REC"; then
  # lint-ok: C1 — STEM (the journal key) comes from Step 5 in this sweep session
  printf 'ESCALATION %s (the outcome record did not append)\n' "$STEM"
fi
```

A blocking-condition halt inside a run MUST NOT halt the sweep: journal
`pr-stopped` with the named condition in `evidence`, list the item as an
escalation, and continue with the next item (M23). An outcome record that fails
to append is that same kind of escalation: it MUST NOT abort the walk. The intent
record stands, so Step 5 judges the item again on the next sweep. The intent
fence keeps `|| exit 1` — an intent record that cannot be written means the side
effect must not start.

## Step 10: Summary (M24)

Count every item in exactly one bucket, then print:

`SKIP` holds three kinds of item: the Step 4 epic children, the Step 5 journal
skips, and the Step 9a walk-truncated tail (the items past `--limit`, which are
counted, never dropped). With `CLOSE`, `ASK`, `ORCHESTRATE`, and `DEFER`, the
five buckets sum to N open.

```bash
# lint-ok: C1 — SWEEP is carried from Step 0 in this sweep session
bash "$SWEEP" summary --counts \
  '{"open":12,"CLOSE":3,"ASK":1,"ORCHESTRATE":5,"DEFER":2,"SKIP":1,"escalations":1}'
# lint-ok: C1 — TMPD is carried from Step 0 in this sweep session
rm -rf -- "$TMPD"
```

Exit 0 with escalations. Non-zero only for machinery failure: a usage error, an
I/O failure, a lock timeout. List each escalation on its own line under the
bucket counts.

## Write surface (M4)

A sweep writes only:

- `$MROOT/.claude/sweeps/*.jsonl` — append-only, never staged or committed
  (`.gitignore` lists `.claude/sweeps/`).
- Tracker state through `close.sh` and `defer.sh`.

A sweep MUST NOT invoke `/release` or any release-train step. MUST NOT pass
literal `--ship` to `/orchestrate`. MUST NOT source the post-ship close-out
sweep script in this directory (SPEC-040 M3). MUST NOT edit files outside the
two classes above.

## Untrusted ticket text (M25)

Title, body, `Affects`, and slug reach `sweep.sh` as argv or as a JSON file
path. Quote every expansion; pass paths after `--` as one argv word each. Any
SQL goes through `skills/lib/sqlq.sh` with bound parameters. Never `eval` ticket
text, never `bash -c` it, and never build a shell command from it.

## Phase 2 (not implemented)

`MERGE`, `EPIC`, and the BC5 mid-flight reroute are spec text only (SPEC-040
§ Phase 2, M26–M28). Phase 1 maps them to `ASK` attended and `DEFER` under
`--autopilot`.
