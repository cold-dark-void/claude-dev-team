# Control plane phase 0 — discovery index

Status: complete. Phase 0 discovery is done; the five child files are filled. T-12 ran the release gate on 2026-11-15 — see § "T-12 — Final review gate checklist" at the end of this file.

Status (CDT-632, added 2026-11-15): the phase-0 written decisions are also complete. § "CDT-632 — File map (written decisions)" pins the six deliverable paths. The CDT-627 sections in this file are unchanged.

Status (CDT-643, added 2026-11-16): phase 1 (CDT-628) builds in this directory. § "CDT-643 — Run journal, state machine, CI kill test" pins the C2 deliverable paths and § "CDT-643" carries its canonical AC list. Every phase-0 section above is unchanged.

Status (CDT-644, added 2026-11-17): C4 lands the node agent. § "CDT-644 — Node agent" below pins the C4 deliverable paths and § "CDT-644" (under § Acceptance criteria) carries its canonical AC list. The phase-0, CDT-632, CDT-643, CDT-642, and CDT-646 sections are unchanged except where C4 appends (the C4 sections of `native-runner.md` and `node-agent-build-probe.md`, and the record-ownership table's row 14).

Status (CDT-649, added 2026-11-17): C5 lands the run queue and the SPEC-033 budget amendment. § "CDT-649 — Run queue" below pins the C5 deliverable paths and § "CDT-649" (under § Acceptance criteria) carries its canonical AC list. The phase-0, CDT-632, CDT-643, CDT-642, CDT-644, and CDT-646 sections are unchanged.

Status (CDT-648, added 2026-11-17): C6 lands the host adapter. § "CDT-648 — Host adapter" below pins the C6 deliverable paths and § "CDT-648" (under § Acceptance criteria) carries its canonical AC list. The phase-0, CDT-632, CDT-643, CDT-642, CDT-644, CDT-646, and CDT-649 sections are unchanged except where C6 appends (`credentials.md` § "Gap 2 — resolved", the CONTEXT.md write-back log).

Status (CDT-647, added 2026-11-17): C8 lands the container runner. § "CDT-647 — Container runner" below pins the C8 deliverable paths; the acceptance criteria live in the local store (`.claude/backlog/container-runner-one-container-per-run.md`). The phase-0, CDT-632, CDT-643, CDT-642, CDT-644, CDT-646, CDT-649, and CDT-648 sections are unchanged except where C8 appends (`container-runner.md` § "CDT-647 — the container runner is real", `record-ownership.md` row 14's mechanics).

Status (CDT-650, added 2026-11-18): C9 lands the Chief — the single point of contact that routes work to the existing Surfaces and reports from run state. § "CDT-650 — The Chief" below pins the C9 deliverable paths and § "CDT-650" (under § Acceptance criteria) carries its canonical AC list. The phase-0, CDT-632, CDT-643, CDT-642, CDT-644, CDT-646, CDT-649, CDT-648, and CDT-647 sections are unchanged except where C9 appends (`record-ownership.md` row 15, the phone-channel page record).

Status (CDT-652, added 2026-11-18): C10 lands the web UI — one screen over the one API. § "CDT-652 — The web UI" below pins the C10 deliverable paths and § "CDT-652" (under § Acceptance criteria) carries its canonical AC list. The phase-0 and phase-1 sections above are unchanged: C10 adds no record to `record-ownership.md` (the page is static files embedded in the chiefd binary, not state) and no Surface is copied — every value the UI shows rides the C9 API.

## Scope

This ticket is Phase 0 discovery of the control plane Option C+ (CDT-626). It is docs-only. It probes hosts and Runner types. It records evidence in this directory. It ships no product code.

Hosts in scope: Claude Code 2.1.322, Grok 1.0.77, omp 18.7.0, mini-swe (documentation-only). Out of scope: `opencode`, `codex`, `pi`.

Runner types: native process and container. The three installed hosts are probed on both Runner types. mini-swe is documentation-only; its cells cite vendor-primary docs.

## Cell vocabulary

Every host × Runner × capability cell carries exactly one verdict:

- `supported` — a probe reproduced the behavior, or official primary docs state it for documentation-only hosts.
- `unsupported` — a probe or primary docs show the behavior is absent.
- `unverified-after-attempt` — a probe was attempted and did not produce a verdict. Record the attempted command and its output.

A bare `unknown` cell fails review (AC-2).

## Mandatory evidence fields

Every cell carries all three fields:

1. Host CLI version (for example `claude 2.1.322`).
2. Probe date (ISO-8601, for example `2026-11-15`).
3. Source — exactly one of:
   - a probe command with its output, recorded in the same file;
   - an official doc URL (vendor primary);
   - an upstream issue.

Probe commands and outputs live in the same file as the cell. Do not store evidence on disk elsewhere. Do not write-then-run scripts; record single direct commands with their output.

## AC-10 guard — image approval gate

Verbatim from the plan:

> every candidate container image is presented to the maintainer in ONE consolidated request (T-02), with evidence (source repo, maintenance status, official/verified status, root vs non-root) and a digest pin. NO container probe or build task starts before written approval. Probe images are recorded as evidence only, never referenced from product surfaces.

No container image is pulled without this approval. Probe commands and throwaway probe images are evidence only. Product surfaces never reference them.

## File map

| File | Carries |
|---|---|
| [host-capability-matrix.md](host-capability-matrix.md) | AC-1 (host × Runner matrix), AC-2 (per-cell evidence), AC-3 (Steer hypothesis), AC-4 (resume fallback), AC-5 (workflow checklist) |
| [container-runner.md](container-runner.md) | AC-6 (container-Runner facts), AC-9 container half (container credential rows) |
| [native-runner.md](native-runner.md) | AC-7 (native supervision + start mechanism), AC-9 native half (process-restart survival) |
| [node-agent-build-probe.md](node-agent-build-probe.md) | AC-8 (Node agent Go build probe) |
| [credentials.md](credentials.md) | AC-9 (credential plan synthesis — CDT-632 reads this file) |

## CDT-644 — Node agent

Added by CDT-644 (CDT-628 C4) on 2026-11-17. C4 puts the node agent inside the service directory:
one Go binary per node, the native runner, the fail-closed runner selection. This table pins the C4
deliverable paths. The canonical AC list is § "CDT-644" under § Acceptance criteria. The sections
above are unchanged.

| Deliverable | Path |
|---|---|
| The agent package | `control-plane/agent/` |
| The node-agent binary | `control-plane/cmd/node-agent/` |
| The build entry (three phase-0 targets) | `control-plane/build.sh`; artifacts in `control-plane/dist/` (git-ignored) |
| The runner selection record | `$MROOT/.claude/dev-team/node.json` (record-ownership row 14; git-ignored) |
| The CI kill lane, parameterised by runner type | `.github/workflows/smoke.yml` § `control-plane`; the helper's selection validation in `control-plane/killtest/helper` |
| The supervision + operator-step record | `native-runner.md` § CDT-644 (the two operator steps are pending-operator) |
| The build + image-approval record | `node-agent-build-probe.md` § "The C4 build" |

## CDT-632 — File map (written decisions)

Added by CDT-632 T-07 (AC18) on 2026-11-15. The File map above is the CDT-627 discovery record and
is unchanged. This table pins the six CDT-632 deliverable paths. The canonical AC list for CDT-632
is § "CDT-632" under § Acceptance criteria. Each file carries a decision-register header: Decision,
Status, Date, Sources, Phase effect, Residual items.

| File | Carries | The decision, in one line |
|---|---|---|
| [`docs/adr/0001-journal-engine.md`](../../adr/0001-journal-engine.md) | AC10 | The journal engine is SQLite behind a narrow interface (files + CLI calls only). The durable-execution engine is rejected with its mechanism. |
| [cloud-auth-and-exposure.md](cloud-auth-and-exposure.md) | AC11 | Per-host cloud auth: Claude Code, Grok, and omp are `both`; mini-swe is `api-key`. Cloudflare Access in front of a Cloudflare Tunnel protects an exposed UI (phase 3). |
| [run-budget.md](run-budget.md) | AC12 | Scale the run budget with the two SPEC-033 env caps, chosen per model. Phase 0 adds no flag, store, precedence source, or ceiling. |
| [record-ownership.md](record-ownership.md) | AC13 | Each of the eleven plugin state records has one owner and one conflict rule from a closed set of five. All eleven stay plugin-owned. |
| [memory-api.md](memory-api.md) | AC14 | One memory interface, three operations, two backends: file when no control plane is present, API when one is. No schema fork. |
| [close-out.md](close-out.md) | AC17 | Phase 0 is closed as a written decision set. The file lists every blocked item and what each later phase inherits. |

AC15 is verify-only: the eleven glossary terms live in `CONTEXT.md`, committed at `6f81c22`. AC16 is
absent by design (OQ-1). The reference-only CDT-627 files in the map above are inputs, not CDT-632
deliverables.

## CDT-643 — Run journal, state machine, CI kill test

Added by CDT-643 (CDT-628 C2) on 2026-11-16. C1 (CDT-645) built the service directory; C2 puts run
state inside it. This table pins the C2 deliverable paths. The canonical AC list for CDT-643 is
§ "CDT-643" under § Acceptance criteria. The CDT-627 and CDT-632 sections above are unchanged.

| File | Carries |
|---|---|
| `control-plane/journal/` | AC1–AC3. The append-only journal: one DDL home (`schema.sql`), the replay that is the state, the idempotency key, the card reference, and the narrow interface. |
| `control-plane/run/` | AC4, AC6. The run state machine: the lease plus fencing token, the named halt states with a reason and a retry budget, the heartbeat and watchdog, and the derived stall limit (`budget.go`). |
| `control-plane/reconcile/` | AC5. The reconciler on start: the journal against worktrees, branches, and processes, with each repair journaled. |
| `control-plane/cmd/journalctl/` | AC2. The journal CLI: the two commands (append, read) the plugin calls. The plugin never opens the database itself; the boundary rule is single-homed in [ADR 0001](../../adr/0001-journal-engine.md) § "The narrow-interface boundary" and is cited here, not restated (C1 AC3). |
| `control-plane/killtest/` | AC7. The CI kill test: the service is killed at every lifecycle phase boundary and the run completes exactly once. |
| `$MROOT/.claude/runs/run.db` | AC2, AC8. The journal file. Git-ignored (`.gitignore:39`), never `memory.db`. `journal.Resolve` takes `$DEVTEAM_RUN_DB` outright, else this path, with `$MROOT` from `$DEVTEAM_MROOT` else the parent of `git rev-parse --git-common-dir` (`control-plane/journal/open.go:24`). |
| [record-ownership.md](record-ownership.md) row 12 | AC8. The journal enters the ownership table: owner `control-plane-only`, conflict rule `single-writer-lease`. Rows 1-11 are untouched. |

The Go module is `github.com/cold-dark-void/claude-dev-team/control-plane` (`control-plane/go.mod`).
The service version stays in `control-plane/VERSION` (C1 AC2); C2 does not touch it.

**Wall-clock basis (AC9).** CDT-610 — "BC6 wall-clock budget: exclude user wait, soft-pause ship
step" — is the precondition of any wall-clock tuning. `run-budget.md` § "Open BC6 item" states the
rule in those words: "Do not tune a per-model wall-clock before CDT-610 lands and is measured." No
wall-clock number is tuned in phase 1, and the stall-limit knob reads `blocked: CDT-610`. The stall
limit is derived, not chosen: the model's wall-clock cap divided by its iteration cap, from the
SPEC-033 § AC3 M9 static defaults and § AC9 M9b tier rows
(`control-plane/run/budget.go`, `BudgetRow.StallLimit`). The derivation introduces no new number, so
this file states the rule and carries no numbers. The precedence chain (env > map > tier) stays
owned by `run-budget.md` § Precedence.

## T-12 — Final review gate checklist (qa, 2026-11-15)

Read-only review of the six deliverables against the plan's T-12 contract. No probe was re-run. The plan's T-10 note (items 2, 4, 6, 7) flagged the open review questions; this section answers each one. All evidence is in this section.

Result: **10 / 10 pass.**

### 1. Every matrix cell filled, none bare `unknown` (AC-2) — PASS

```text
$ grep -n '|[[:space:]]*|[[:space:]]*|' host-capability-matrix.md      # empty cells
(no matches; exit 1)

$ grep -niE '\b(unknown|tbd|todo)\b' *.md
index.md:21                  A bare `unknown` cell fails review (AC-2).            <- rule text
host-capability-matrix.md:504  A cell that reads only "unknown" fails review.       <- rule text
host-capability-matrix.md:743  ...the verbatim AC-2 rule quote in § AC-2            <- T-10 scan record
credentials.md:11              A bare `unknown` fails review (AC-2).               <- rule text
credentials.md:133             none is a bare `unknown`                            <- T-09 gap note

$ awk -F'|' '/^\| \(/ {n++} END{print n+0}' host-capability-matrix.md   # capability rows
28                                        # 28 rows x 2 Runner columns = 56 cells

$ awk -F'|' '/^\| \(/ {c=$3; gsub(/^ +/,"",c); split(c,a," "); v=a[1]; gsub(/\*/,"",v); print v}' \
    host-capability-matrix.md | sort | uniq -c          # native column
      2 partial
     19 supported
      5 unsupported
      2 unverified-after-attempt
$ awk -F'|' '/^\| \(/ {c=$4; gsub(/^ +/,"",c); split(c,a," "); v=a[1]; gsub(/\*/,"",v); print v}' \
    host-capability-matrix.md | sort | uniq -c          # container column
      2 partial
     17 supported
      6 unsupported
      3 unverified-after-attempt
```

56 cells, zero empty, zero bare `unknown`. The five `unknown` hits are the rule text and the scan records that quote it.

Adjudication of the T-10 item-6 flag: the 4 `partial` cells are mini-swe (b) and (e) on both Runner types. They are filled, documentation-only cells that name the vendor-primary split (unattended run documented, streaming protocol undocumented) and the AC-5 aggregate, where AC-5's own vocabulary is pass/fail/partial. AC-2's review-failure clause targets a cell that reads only `unknown`; none does. Ruling: accepted deviation, recorded here; the three-value vocabulary governs the probed hosts, where it holds (T-10 item 3).

### 2. AC-4 named path in every host row — PASS

`host-capability-matrix.md` § AC-4 carries one `###` section per host, in matrix host order; each names exactly one of the two paths:

| Host | Named path |
|---|---|
| Claude Code (native Runner) | resume — `claude -p --resume <session-id>`; session-id source: the `system/init` stream-json event, mirrored at `~/.claude/projects/<cwd-slug>/<session-id>.jsonl` |
| Grok 1.0.77 | resume — `--resume <SESSION_ID_OR_TITLE>`; session-id source: the `sessionId` field of `--output-format json` (or the `streaming-json` `end` event) |
| omp 18.7.0 | resume — `-r, --resume=<value>` / `-c, --continue`; session-id source: `~/.omp/agent/sessions/<cwd-slug>/<UTC-timestamp>_<uuid>.jsonl`, indexed in `agent.db` `threads` |
| mini-swe | fallback — step re-run from the last lifecycle checkpoint (control plane Option C+ (CDT-626)) |

```text
$ awk '/^## AC-4/,/^## AC-5/' host-capability-matrix.md | grep -c '^### '
4
```

### 3. AC-5 checklist fully scored; memory and Intercom not required — PASS

```text
$ awk '/^### Checklist scores/,/^## T-10/' host-capability-matrix.md | grep -cE '^\| *[0-9]\. '
24
$ awk '/^### Checklist scores/,/^## T-10/' host-capability-matrix.md | grep -cE '^[0-9]+\. \*\*'
4                                       # omp native scores are numbered items, not a table
                                        # 24 + 4 = 28 item scores (3 hosts x (4 native + 4 container) + 4 mini-swe docs-only)
$ awk '/^### Checklist scores/,/^## T-10/' host-capability-matrix.md | grep -oE '\b(pass|fail|partial)\b' | sort | uniq -c
      2 fail
      3 partial
     23 pass                            # 28 scored items, none blank
$ grep -n 'excluded from the required set' host-capability-matrix.md
646:Score capability (e) against this checklist. ... Memory and Intercom are excluded from the required set.
```

The AC-1 preamble states the same for the matrix columns: "Memory and Intercom are never scored as required" (`host-capability-matrix.md:7`). The `partial` scores are omp container item 3 (no `jq` in the approved image — a runner-image toolchain need, AC-6 Fact 4) and mini-swe items 2 and 4 (docs-only).

### 4. AC-3 six reproduced Steer probes — PASS

Six probe records exist in § AC-3: Claude Code native (P-CC-C, ¶ "Claude Code — native Runner"), Claude Code container (P-CON-STEER, ¶ "Claude Code — container Runner"), Grok native, Grok container (P-GK-CTR-3c), omp native (RPC), omp container (P-OMP-C-C). T-11's adjudication block covers all six:

```text
$ awk '/^#### T-11/,/^## AC-4/' host-capability-matrix.md | grep -c '^| .* — '
6
$ awk '/^#### T-11/,/^## AC-4/' host-capability-matrix.md | grep -oE '^\| (Claude Code|Grok|omp) [^|]*\|'
| Claude Code 2.1.325 — P-CC-C … |
| Grok 1.0.77 — ACP steer … |
| omp 18.7.0 — RPC steer … |
| Claude Code 2.1.325 — container P-CON-STEER … |
| Grok 1.0.77 — container ACP steer, P-GK-CTR-3c … |
| omp 18.7.0 — container RPC steer, P-OMP-C-C … |
```

Verdict recorded: the glossary Steer definition is confirmed by all six; no probe disproved it, so no `CONTEXT.md` amendment (T-11 exception b not triggered). Every `supported` Steer cell points at a reproduced probe; mini-swe's Steer cell is `unsupported` and states the documentation-only limit.

### 5. AC-6 five facts, each with verdict or named blocker — PASS

```text
$ grep -n '^### Fact' container-runner.md
11:### Fact 1 — Subscription login from a mounted volume
30:### Fact 2 — Token refresh writable-mount need
58:### Fact 3 — Worktree at the same absolute path inside the container
89:### Fact 4 — Per-project runner image toolchain needs
110:### Fact 5 — Local model endpoints reachable over the container network
$ awk '/^## AC-6/,/^## AC-9/' container-runner.md | grep -cE '^\*\*(Claude Code|Grok|omp)'
15                                      # 3 hosts x 5 facts, each with a verdict line
```

No "not tested" without a reason. The two named blockers are the forced token-refresh probes (Claude Code and Grok, Fact 2): a forced refresh rotates the operator's live subscription credential, so each carries the conservative writable-mount rule instead. The empty `- Verdict:` / `- Evidence:` template lines under each fact are unused scaffolding from T-01; each fact's verdict sits in the bold host line above them.

### 6. AC-7 mechanism chosen, verified, unsupervised rejected — PASS

`native-runner.md` § AC-7: `**Verdict: systemd user unit — chosen and verified working on this machine.**` (line 55) — unit file text, `daemon-reload` exit 0, `status` showing `Loaded: loaded`, a `start` that reached `active (running)` with a main PID, restart-on-failure with the counter climbing at `RestartSec=2s`, and journald capture; teardown to `inactive (dead)`, unit stays disabled. launchd is recorded as not applicable on this WSL2 host. `### Rejected alternative — unsupervised` (line 196): `**Verdict: rejected.**` with three observed reasons (no restart-on-failure, no dependency ordering, no journald capture) plus the SIGHUP/session-death case. Linger is recorded as a pending machine-config decision for phase 1, not a mechanism gap.

### 7. AC-8 commands, digest, size, start proof, two cross-compiles built-not-run — PASS

```text
$ grep -nE 'Approved image|Pulled digest matches|node-agent-probe-ok|2,342,249|2,342,293|2,413,202|Built-not-run|go version go' node-agent-build-probe.md
22:Approved image (G-02, row 3 only): docker.io/library/golang:1.27-bookworm@sha256:4fa7c968ba93f1635670522dbb01a2c78150443e1385746924566079f36570ea
65:Pulled digest matches the approved pin: sha256:4fa7c968ba93f1635670522dbb01a2c78150443e1385746924566079f36570ea
93:go version go1.27.4 linux/amd64
104:node-agent-probe-ok                    # start proof, run on the host, exit 0
115:2,342,249 bytes (~2.2 MiB)             # amd64 binary size
140:2,342,293 bytes. Built-not-run.        # linux/arm64 (DGX Spark)
161:2,413,202 bytes. Built-not-run.        # darwin/arm64 (Mac)
```

Build commands are single direct `docker run` commands; `file` output confirms each target (`ELF 64-bit LSB executable, ARM aarch64` / `Mach-O 64-bit arm64`). § Cleanup records the scratch dir deleted — no binary, Dockerfile, or build script in the worktree (§ 9 confirms).

### 8. AC-9 full host × Runner grid plus operator steps — PASS

```text
$ grep -cE '^### ' credentials.md
8        # 4 native (Claude Code, Grok, omp, mini-swe both) + 4 container (Claude Code, Grok, omp, mini-swe)
$ awk '/^## One-time operator steps/,/^## Gaps/' credentials.md | grep -c '^| '
9        # header + separator + 8 host x Runner rows
```

Every (a)/(b)/(c) row carries a verdict, version, probe date, and source; secret values are paths and key names only. Interactive-login flags: Grok native (`grok login`), Claude Code container and Grok container (host-side browser login, then mount), omp container (only for subscription providers, `omp auth-broker login <provider>` with a writable `~/.omp`). § "Gaps found…" records the four residual gaps (no second image / non-root user / non-Docker environment; token-refresh write untested by design; omp (c) covers mounted state only; mini-swe unprobed) plus the omp native env-var-name gap and the Claude Code 2.1.325 drift and `--bare` credential split.

### 9. AC-10 guard: docs only, no binaries, no product-surface image reference — PASS

```text
$ git status --short
?? docs/internal/control-plane/

$ git status --short --untracked-files=all
?? docs/internal/control-plane/container-runner.md
?? docs/internal/control-plane/credentials.md
?? docs/internal/control-plane/host-capability-matrix.md
?? docs/internal/control-plane/index.md
?? docs/internal/control-plane/native-runner.md
?? docs/internal/control-plane/node-agent-build-probe.md

$ git diff --stat            # tracked files
(no output)
$ git diff --cached --stat   # staged
(no output)
$ git branch --show-current
feat/CDT-627
$ git log --oneline origin/master..HEAD
(no output — no commits on the branch; the diff is the six untracked .md files)

$ grep -rniE 'a72b4433de1cf7d6bae0c4cee74d0547f58601a643b3375f070c51600d63b6b2|4fa7c968ba93f1635670522dbb01a2c78150443e1385746924566079f36570ea|trixie-slim|golang:1\.27|library/debian|library/golang' \
    --exclude-dir=.git --exclude-dir=docs . | grep -v '^./docs/internal/control-plane/'
./specs/core/SPEC-038-intercom-spool-protocol.md:2038:  `docker.io/library/debian:bookworm-slim` index

$ grep -rniE 'trixie|golang:|sha256:[0-9a-f]{64}|docker\.io' agents commands skills .claude-plugin
skills/intercom/docker-compose.yml:3, skills/intercom/Dockerfile:5, skills/intercom/test.sh:2403,
skills/intercom/SKILL.md:295   # docker.io/library/alpine@sha256:ce64758a… — SPEC-038 sidecar pin
```

Neither probe image (`debian:trixie-slim@sha256:a72b…`, `golang:1.27-bookworm@sha256:4fa7…`) appears anywhere outside `docs/internal/control-plane/`. The two hit groups are pre-existing product content that this ticket does not touch: the SPEC-038 `bookworm-slim` alternative pin (`git log -1` → `c46396a`, v1.28.9) and the SPEC-038 Intercom sidecar's Alpine digest. `git diff` is empty and `git status --porcelain -uno` reports 0 modified files, so both are untouched by CDT-627. No binary, image, Dockerfile, or build script is present in the worktree, and no product surface under `agents/`, `commands/`, `skills/`, `.claude-plugin/` changed.

### 10. docs-drift and skill-lint pass on the worktree — PASS

```text
$ bash skills/docs-drift/check-docs-drift.sh
3 findings, 3 waived
$ echo $?
0

$ bash skills/skill-lint/check-skill-bash.sh
174 findings, 174 waived
$ echo $?
0
```

Both gates exit 0 — unwaived findings = 0 on each. The docs-drift scan covers the README command index, the agent roster, the docs hub links, manifest description sync, skill-path references, skill names, and docs page links; the new directory introduces no new finding.

### Review defects fixed by T-12 (wording only, no evidence edited)

1. `host-capability-matrix.md` § T-10 note, count paragraph: the sentence "The T-11 adjudication block in this file still states that the container halves await G-02 … T-12 extends the adjudication …" was stale — T-11's block was extended. It now states the final state: the block adjudicates all six probes and T-12 verified the six rows.
2. `host-capability-matrix.md` § T-10 note item 7: "Open items for their owners … `container-runner.md` § 'Grok container credentials' is still empty (T-04) … `credentials.md` § 'Container-Runner half — pending: waits on G-02' …" was stale — T-04 filled the Grok container credential rows and T-09 re-synthesized the container grid. Item 7 now records both items as closed.
3. Checked, no change needed: no AC-summary section claims the three container Steer probes wait on G-02. The T-10 count paragraph records six probes (three native, three container) and T-11's note 1 records the G-02 approval and the landed container probes. Scan: `grep -niE 'waits on G-02|pending' *.md` — the only `waits on G-02` hits sit inside the T-10 item-2 history sentence, which its own "Refresh" sentence retires. Every `pending` hit is probe prose (a tool call still running), an accurate phase-1 statement in `native-runner.md` (the node-agent binary awaits its first build; linger awaits a phase-1 operator decision), or this file. No gate marker remains in any cell, row, or summary.

Also updated in this file: the Status line, from "scaffold" to "complete", pointing at this section.

### Release readiness

**Verdict: PASS — ticket ready for release as the first arc pre-release `v2.0.0-pre.1`.** Per the SPEC-010 pre-release arc scheme (CDT-633, `skills/release/SKILL.md` § "Pre-release arc scheme"): the Control plane arc (CDT-626) ships as `2.0.0-pre.N` — `plugin.json` carries `2.0.0-pre.1` (no `v`), the git tag and the `CHANGELOG.md` heading carry `v2.0.0-pre.1`, `stable` stays at the last 1.x final release, and the pass rides `master` (the `dev-team-edge` channel). The docs-only ruling governs the diff content (six `.md` files, no product code); the arc scheme governs the version, so this is **not** a `1.28.x` patch bump off the current `1.28.20`. Pass the version explicitly to `/release 2.0.0-pre.1` — auto-detect and bump keywords never compute a pre version. Residual items for later tickets, none blocking: `loginctl enable-linger` (phase 1, machine change), the omp native env-var-name probe, the forced token-refresh probe (needs a sandbox credential), and the CDT-632 written decisions.

## CDT-649 — Run queue

Added by CDT-649 (CDT-628 C5) on 2026-11-17. C5 puts the run queue inside the service directory:
the slot ledger journals grant, wait, and release through the C2 run machine — reused, never
forked — and the SPEC-033 budget amendment lands with its five inputs resolved. This table pins
the C5 deliverable paths. The canonical AC list is § "CDT-649" under § Acceptance criteria. The
sections above are unchanged.

| Deliverable | Path |
|---|---|
| The queue package (the slot ledger) | `control-plane/queue/` |
| The gated intent seam the queue writes through | `control-plane/run/machine.go` (`run.Machine.IntentWhenKeyed`) |
| The amendment record | `run-budget.md` § Amendment; `specs/core/SPEC-033-autopilot-policy.md` § Version History (the 2026-11-17 row) and the AC9 precedence insert |
| The glossary amendment | `CONTEXT.md` § Terms, the Slot row (AC5) |

CDT-649 follows the same ruling as CDT-642/643/644: no `specs/` entry — the deliverable AC list
below is the spec. No AC carries the `[process]` tag: each asserts file content (AC1–AC6) or diff
content (AC7).

## CDT-648 — Host adapter

Added by CDT-648 (CDT-628 C6) on 2026-11-17. C6 puts the host adapter inside the service directory:

| Deliverable | Path |
|---|---|
| The host adapter (the matrix registry, the four verbs, the refusal path, the B7 proven-name table) | `control-plane/hostadapter/` |
| The launch/environment seam the adapter rides | `control-plane/agent/runner.go` (`Spec.Env`), `control-plane/agent/agent.go` (`StartRequest.Env`) |
| The B7 probe record and the gap-2 resolution | `credentials.md` § "Gap 2 — resolved: the omp provider env-var names (B7)" |
| The glossary write-back (Steer unchanged, six-probe citation) | `CONTEXT.md` § Decisions (the 2026-11-17 CDT-648 row) |

CDT-648 follows the same ruling as CDT-642/643/644/649: no `specs/` entry — the deliverable AC list
below is the spec. No AC carries the `[process]` tag: each asserts file content (AC1–AC6) or diff
content (AC7).

The adapter adds no lifecycle-graph change: resume maps onto the machine's existing `run_resumed`
verb (the node agent's recovery resumes a halted:stalled run and re-spawns the runner as the next
attempt, the CDT-626 adoption policy), steer maps onto the existing `agent.steer` side-effect rows,
and observe reads — no new run state, no new boundary, no new event kind. The registry's proven
test asserts every row the adapter's runs carry is one of the machine's closed kinds
(`TestSteerThroughTheAgentDeliversAtTheBoundary`).

## CDT-647 — Container runner

Added by CDT-647 (CDT-628 C8) on 2026-11-17. C8 puts the container runner inside the service
directory: one container per run over the same `agent.Runner` contract as the native runner, with
the node agent as the only holder of the Docker socket.

| Deliverable | Path |
|---|---|
| The container runner | `control-plane/agent/container.go` — the `container` token of the C4 closed set (`agent.KnownRunners`), native first and default |
| The session image record | `container-runner.md` § "CDT-647 — the container runner is real" — one digest-pinned reference, the G-02 row-1 approval |
| The runner-aware live-process record | `control-plane/agent/agent.go` (`pidRecord` gains the runner type and the container name; the adoption policy and the stop verb reach a container by name, because it outlives its client) |
| The container kill lane | `.github/workflows/smoke.yml` § `control-plane` — the C4 `runner_type` input admits `container`; the lane drives the machine directly and spawns no session container |
| The operator recipe | `container-runner.md` § "Operator recipe — a containers-only node" |

The container runner implements the same contract — start, stop, status, steer — with the same
semantics: steer rides the Docker client's stdin pipe unchanged; stop is `docker stop -t`, the same
TERM-then-KILL contract at the container boundary; and the adoption policy re-spawns a dead run as
the next attempt over the mounted paths, so resume and steer survive container death
(`container-runner.md` Facts 2 and 3, the AC-9 restart rows). The session container never sees the
Docker socket: `agent.guardSessionArgv` refuses every invocation that mounts it, adds a Docker
group, or widens the container beyond the probed posture. Native stays the default: a node whose
selection does not name `container` runs the native runner exactly as C4 built it.

## CDT-650 — The Chief

Added by CDT-650 (CDT-628 C9) on 2026-11-18. C9 puts the single point of contact inside the service
directory: one place to send work and to ask what is happening, over the one API the web UI
consumes.

| Deliverable | Path |
|---|---|
| The Chief (the routes, the reports, the halts, the model seam) | `control-plane/chief/` |
| The one API surface the web UI (C10) consumes | `control-plane/chief/api.go` (`chief.Handler`) — served by `control-plane/cmd/chiefd/` |
| The ticket route's writer — the plugin's own verbs, cited, unchanged | `skills/backlog/ticket.sh` (the C7 CLI over the local backlog store) |
| The model seam — the plugin's own resolver, cited, unchanged | `skills/model-map/resolve-model.sh` (SPEC-037); an empty resolution is the Tier default (`control-plane/run/budget.go`), and no flag exists |
| The phone channel for halts — the plugin's own Intercom CLI, cited, unchanged | `skills/intercom/intercom.sh` (SPEC-038); the page record is `$MROOT/.claude/runs/chief/notified.jsonl` |
| The page record's ownership row | `record-ownership.md` row 15 |

The Chief adds no second copy of any Surface and no new store of run state:

- **Routing (AC1)** names the Surface in the run's `workflow` field — `/debug` for a defect,
  `/brainstorm` for an idea, `/epic` for an epic — writes the ticket record the Surface reads
  through the plugin's own ticket verbs, and starts the run through the C6 host adapter and the
  node agent's four-verb contract. An epic route ends at the child-ticket records; each child gets
  its own run when the operator routes it.
- **Reports (AC2)** fold journal and queue state only: run status is the replayed state
  (`control-plane/journal`), the checks reading is the run's pending effects, repairs, and
  watchdog reading, the queue view is the C5 slot ledger (`control-plane/queue`), and the stand-up
  report composes the three. No report generates prose.
- **Corrections (AC4)** ride the C6 steer path unchanged: the host adapter encodes the host's
  control-message frame and hands it to the node agent's steer verb, which delivers it at the next
  step boundary — never mid-turn (the six probes; `CONTEXT.md` § Steer).
- **Halts (AC5)** are the C2 named halt states: the report carries the reason and the remaining
  retry budget (`control-plane/run/budget.go`), and the watch pages the operator through the
  Intercom (SPEC-038). The page record keeps the page at-least-once across a restart: one intent
  line before the page, one outcome line after, keyed by the halt row's seq.
- **One interface (AC6)**: the HTTP API of `chief.Handler` is the whole surface — there is no CLI
  verb and no second interface. The web UI (C10) consumes the same endpoints.

## CDT-652 — The web UI

Added by CDT-652 (CDT-628 C10) on 2026-11-18. C10 puts the one screen inside the service directory:
chat with the Chief plus a run board over the same API the C9 Chief serves — the per-session terminal
tab is replaced, and no endpoint exists for the UI alone.

| Deliverable | Path |
|---|---|
| The web UI — the static page the chiefd process serves (embedded; no build step) | `control-plane/cmd/chiefd/web/` + `control-plane/cmd/chiefd/web.go` |
| The board's report fields (state, current phase, halt reason, retry budget, queue position, node, runner type) | `control-plane/chief/chief.go` (`RunStatus`), `control-plane/chief/board.go` |
| The lifecycle-graph endpoint the drawing rides | `control-plane/chief/api.go` (`GET /v1/graph`) over `control-plane/lifecycle` |
| The loopback-only bind guard | `control-plane/cmd/chiefd/main.go` (`loopbackOnly`) |
| The per-Surface standalone checks | `control-plane/chief/board_test.go` (`TestSurfacesStillWorkStandaloneInTheTerminal`) |
| The started-steered-closed proof over the UI's endpoints | `control-plane/chief/e2e_test.go` (`TestABoardRunIsStartedSteeredAndClosedFromTheUI`) |

The UI adds no record and no second copy of any Surface: the page is `go:embed` static files (plain
HTML, CSS, and JavaScript — no node/npm build step) served by the same chiefd process on the same
loopback port as the API; the chat is the C9 corrections flow plus the route verbs; the board folds
journal, queue, spool, and graph state; and the bind refuses any non-loopback address (remote access
is CDT-630's phase-3 scope).

## Acceptance criteria

The ticket has no `specs/` entry (maintainer ruling) — the locked prose ACs live in the kickoff plan (`.claude/plans/2026-11-11-CDT-627-control-plane-phase-0-discovery.md`, section "## Acceptance criteria"). This subsection is the canonical AC list in SPEC-033 M14 bullet form — the same ten locked ACs, so the M14 ship-gate split reads them from this committed file. None carries the `[process]` tag: every AC asserts file content (AC-1..AC-9) or diff content (AC-10).

### CDT-627

- **AC1.** Host capability matrix exists. A matrix file under `docs/internal/control-plane/` covers Claude Code (2.1.322), Grok (1.0.77), omp (18.7.0), and mini-swe × both Runner types (native process, container) × capabilities: (a) session resume after process death, (b) headless mode with streaming input and output, (c) Steer delivery at the next step boundary, (d) hooks or another lifecycle-event emission path, (e) workflow compatibility per AC-5, (f) memory, (g) Intercom. Memory and Intercom are optional columns, never scored as required. The three installed hosts are probed empirically on both Runner types; mini-swe is documentation-only and its cells state that. The matrix is complete when every host × Runner × capability cell is filled.
- **AC2.** Evidence rules per cell. Every cell is `supported` / `unsupported` / `unverified-after-attempt` with evidence: host CLI version, probe date, and source — a probe command with its output, an official doc URL, or an upstream issue. A cell that reads only "unknown" fails review. Probe commands and outputs are recorded in the same file, not on disk elsewhere.
- **AC3.** Steer verified as hypothesis, per host per Runner type. Claude Code Steer from the brainstorm record is treated as a hypothesis, not a fact. Steer is verified for every host on both Runner types by a reproduced probe: a message sent to a running headless session, with delivery observed at the next step boundary. A `supported` Steer cell without a reproduced probe fails review. If a probe disproves the glossary Steer definition, the CONTEXT.md Steer term is amended on this branch (exception b) — the amendment is noted in the matrix even though the glossary write-back lives in CDT-632.
- **AC4.** Resume fallback named per host. For every host without resume, the matrix names the fallback: step re-run from the last lifecycle checkpoint (control plane Option C+ (CDT-626)). For every host with resume, the matrix names the exact mechanism the Host adapter would call — CLI flag and session-id source. A host row without one of these two named paths fails review.
- **AC5.** Workflow-compatibility checklist scored. Capability (e) is scored against a checklist written in the matrix file: run a Surface headless; spawn or inline the roles; write decision-cards; use worktrees. Each item gets pass/fail/partial per host per Runner type, with evidence per AC-2. Memory and Intercom are excluded from the required set.
- **AC6.** Container-Runner facts recorded. The container-runner file records, each verified by probe or recorded as a named blocker: subscription login from a mounted volume; token refresh writable-mount need; worktree at the same absolute path inside the container; per-project runner image toolchain needs; local model endpoints reachable over the container network. Each of the five facts has a verdict and evidence; "not tested" without a written reason fails review.
- **AC7.** Native-Runner supervision and start mechanism. The native-runner file records: how the Node agent supervises agent processes on this machine, and how the Node agent starts — systemd user unit or launchd, with one mechanism chosen and verified working on this machine (unit file or plist shown with its probe result). The unsupervised alternative is recorded as rejected with the reason.
- **AC8.** Node agent build probe. A probe builds one trivial Go binary in a container and shows it starts on the development machine; commands, image digest, and binary size are recorded. Cross-compiles for linux/arm64 (DGX Spark) and darwin/arm64 (Mac) are recorded as built but not run. No binary ships, no service code is committed — the write-up in the file is the only artifact. A committed binary or a build recipe presented as product code fails review.
- **AC9.** Credential plan per host per Runner type. For every host on both Runner types: (a) the auth method in the runner (API key / OAuth token / subscription login), (b) where the secret lives (env var name, mounted file path, host keyring), (c) whether it survives a container restart for the container Runner or a process restart for the native Runner. Hosts needing interactive browser login are flagged with the one-time operator step. CDT-632's cloud-auth AC reads this file when it exists.
- **AC10.** No-product-code and image-approval guard. No product code ships in this ticket. No container image is pulled without maintainer approval; to shorten the loop, all candidate images are presented in one consolidated request, each with evidence (source repo, maintenance status, official/verified status, root vs non-root) and a digest pin. Probe commands and throwaway probe images are recorded as evidence only and never referenced from product surfaces.
The same ruling applies to CDT-632: no `specs/` entry — the deliverable AC list itself is the spec, and this subsection is the canonical AC list in SPEC-033 M14 bullet form. AC ids keep the issue's numbering (AC10–AC15, AC17); AC16 is absent by design — it stayed with the CDT-627 ticket split when the original ticket was divided (OQ-1 ruling). None carries the `[process]` tag: every AC asserts file content (AC10–AC18) or diff/gate content (AC19–AC22). The PM-revised AC list is locked; the AC15 glossary write-back is already committed at `6f81c22` and its AC is verify-only.

### CDT-632

- **AC10.** Journal engine ADR exists as a decision, not a recommendation. `docs/adr/0001-journal-engine.md` (numbered filename, OQ-2; house style follows the `docs/adr/SPEC-002-stanza-irreducibility.md` verdict-record shape) records the maintainer-ruled decision: SQLite behind a narrow interface. It must contain Status/Context/Decision/Consequences/Rejected sections; score all four evaluation criteria for both options — durability, kill-test compatibility, ops cost, container image count as an integer per option (SQLite: 0 new images, so no G-02 request in this ticket, OQ-12); record the durable-execution engine (Temporal/Restate) as the rejected option with the reason; define the narrow-interface boundary (the control plane talks to the plugin through files and CLI calls only); state that the journal REFERENCES decision-cards and never changes the frozen schema (SPEC-033 AC6), is git-ignored, and never lands in memory.db; and carry an anti-relitigation clause.
  - Verify: the file has all five sections, both options scored on all four criteria with integer image counts, the rejected option named with its reason, the boundary sentence, and the anti-relitigation clause.
- **AC11.** Cloud auth and exposure, documentation-only, no cloud VM. `docs/internal/control-plane/cloud-auth-and-exposure.md` covers each host (Claude Code, Grok, omp, mini-swe) with subscription-login | api-key | both | blocked, each with a vendor primary URL and access date. Cites the probed Claude Code version 2.1.325. Carries the `--bare` credential split (`--bare` reads only `ANTHROPIC_API_KEY`/`apiKeyHelper`, never the OAuth/keychain token file — `credentials.md:34`, gap 4) and restates the credentials.md residual gaps. Names the access layer protecting an exposed UI in writing (build is phase 3, CDT-630). States tunnel-token storage with a Cloudflare primary-docs citation. Splits into "exposure (phase 3)" and "compute in cloud (phase 4)" sections (OQ-11). Every unverifiable claim is literally `blocked: <what is missing>` — blocked rows are the correct output, never guesses.
  - Verify: four host rows present; every cell cites a vendor primary URL + access date or reads `blocked:`; the `--bare` split and residual gaps are stated; the section split and access-layer naming are present.
- **AC12.** Run-budget proposal, no policy fork. `docs/internal/control-plane/run-budget.md` cites SPEC-033 AC3 as policy owner without restating it; carries a per-model proposal table riding the Model map (SPEC-037); states precedence env > map > tier and that an unknown model falls back to the Tier default row; states the M9b boundary (auto-tune is complexity-derived S/M/L, not model-derived); names the open BC6 item by id — CDT-610 (verified PENDING); and defers the SPEC-033 amendment to phase 1 (CDT-628) with a pointer — phase 0 proposes env-only scaling, and the ceiling amendment is recorded as a phase-1 input (OQ-6).
  - Verify: the table has per-model rows with env > map > tier precedence and the Tier-default fallback; CDT-610 is named; the CDT-628 deferral pointer exists; SPEC-033 AC3 is cited as owner, not restated.
- **AC13.** Record ownership table with a closed conflict-rule set. `docs/internal/control-plane/record-ownership.md` has columns record | exact path | writer | reader | owner (plugin|control plane) | conflict rule ∈ closed set {single-writer-lease, plugin-only, control-plane-only, append-only-merge, derived-rebuild}. Mandatory rows: the 5 from the issue (`.claude/autopilot`, `epics`, `sweeps`, backlog, `.claude/memory/memory.db`) plus the 6 implied (plans, council, model map local layer, release train, transcript mirror, worktree registry) — OQ-7. Must state: memory.db at $MROOT shared across worktrees; decision-cards git-ignored and never in memory.db; the container runner mounts the worktree at the same absolute path. Must not contradict SPEC-033 N-rules.
  - Verify: 11 rows present; every conflict-rule cell is in the closed set; the three invariants appear; no row contradicts SPEC-033 N-rules or SPEC-040.
- **AC14.** Memory API shape as a decision, over SPEC-004 semantics. `docs/internal/control-plane/memory-api.md` defines three operations (store, recall, distill), each with the roster check (`require-agent.sh --memory`). States the two-backend rule as a decision: local file when there is no control plane, API when there is one; every Surface must still work standalone (per-Surface standalone table). Names the "control plane present" detection rule in writing — one config key + one env marker — with phase 0 naming it and phase 2 (CDT-629) implementing it (OQ-8). States the control-plane-down fallback explicitly. Decides the `.md` merge rule (OQ-9): LWW per (agent,type,key) by ts, append-only, conflicts queue surfaced to the Chief. Records cloud residency with the at-rest posture as a phase-4 requirement (OQ-10): encrypted at rest, single-user boundary, no secrets in memory rows. No schema fork — transport over SPEC-004 semantics.
  - Verify: three operations with the roster check; the detection config key + env marker are named; the per-Surface standalone table and the down-fallback are present; the merge rule matches OQ-9 exactly; the phase-4 residency requirement is stated; no new schema is introduced.
- **AC15.** Glossary write-back, verify-only — already committed at `6f81c22`. Verify the eleven terms verbatim (Control plane, Chief, Run, Host adapter, Node, Slot, Steer, Lifecycle graph, Node agent, Runner, Node capability); Steer unchanged with the six-probe citation; the Slot Term keeps the ruling "one slot is one runner" and lists the per-model-endpoint variant as the open question, per the AC letter (OQ-4).
  - Verify: 11/11 term rows present and verbatim in `CONTEXT.md`; the Steer entry cites the six reproduced probes; the Slot entry carries the ruling and the open question; any defect is flagged, not silently rewritten.
- **AC17.** Close-out with an audited external-copy record. `docs/internal/control-plane/close-out.md` ends with the "decisions that unblock" section (phase 1 CDT-628, memory build CDT-629, access-layer CDT-630, remote compute CDT-631) or `none`. Carries the four CDT-627 residual phase-1 inputs: linger, the omp env-var-name probe, the forced token-refresh probe, and the Slot open question. The external copy target is ruled (OQ-3): the Linear project document "Control plane: brainstorm record (2026-11-11)" (https://linear.app/cold-dark-void/document/control-plane-brainstorm-record-2026-11-11-1acc77afc881) — close-out.md records destination + date + link so the external write is auditable from the repo. Lists every blocked item from the decision files.
  - Verify: the unblock section names all four phase tickets or `none`; the four CDT-627 residuals are present; destination + date + link are recorded; every `blocked:` item from AC11 and AC15 appears.
- **AC18.** Deliverable set and index. The six file paths are pinned; File map + Status in `docs/internal/control-plane/index.md` are updated without rewriting CDT-627 provenance; rows are added to the internal-docs table in `docs/README.md` for the index and the ADR; every decision file carries a decision-register header (Decision / Status / Date / Sources / Phase effect / Residual items).
  - Verify: six paths pinned; the CDT-627 section and Status history in this file are untouched; `docs/README.md` gains the two rows; all six files carry the register header.
- **AC19.** Docs-only diff guard. The diff vs origin/master touches only `docs/**`, `CONTEXT.md`, `CHANGELOG.md`, and `.claude-plugin/plugin.json`.
  - Verify: `git diff --name-only origin/master...HEAD` ⊆ the four allowed paths.
- **AC20.** Citation guard. Every mention reads "control plane Option C+ (CDT-626)"; a bare "Option C" never appears (SPEC-038 uses that wording for a different thing).
  - Verify: grep over the diff finds zero bare "Option C" occurrences.
- **AC21.** Gate pass. docs-drift and skill-lint exit 0 on the worktree; all cross-links between the six deliverables, this index, `docs/README.md`, the ADR, and the constraining specs resolve.
  - Verify: `bash skills/docs-drift/check-docs-drift.sh` and `bash skills/skill-lint/check-skill-bash.sh` both exit 0 with zero unwaived findings; every cross-link resolves.
- **AC22.** Release ships `2.0.0-pre.2` via `/release 2.0.0-pre.2` — explicit version; the issue's "docs-only patch release" line is stale (SPEC-010 arc scheme governs the version while the Control plane arc is open).
  - Verify: tag `v2.0.0-pre.2` exists; `plugin.json` carries `2.0.0-pre.2` bare; the CHANGELOG heading matches; `stable` is unchanged.

CDT-645 follows the same ruling: no `specs/` entry — the deliverable AC list below is the spec, and the C1 gate home is the two SPEC amendments it owns (SPEC-030 Discovery/R4 exclusion, SPEC-010 S7 service-path wording, OQ-6). The service directory is `control-plane/` (OQ-1 — the CONTEXT.md Term; the creating ticket owns the name per `record-ownership.md`, which C1 does not edit: the directory name itself is C1's record). C1 scope is docs + gate + tests only (OQ-5): no `go.mod`, no Dockerfile, no Go file, no pulled or built image (OQ-4), no G-02 request. No AC carries the `[process]` tag: each asserts file content (AC1–AC4, AC8) or gate/diff content (AC5–AC7, AC9–AC13).

### CDT-645

- **AC1.** The isolated top-level service directory exists. `control-plane/` holds `VERSION` (`0.1.0`, OQ-3), an `image-reference` placeholder pin file (a written reference only — no pull, no build, no digest request in C1, OQ-4), and a `README.md` naming the service. `.claude-plugin/plugin.json` stays the plugin's only version surface.
  - Verify: the three files exist; `control-plane/VERSION` reads `0.1.0`; `plugin.json` version is unchanged by this AC.
- **AC2.** One version per artifact. The service version lives only in `control-plane/VERSION`; the plugin version lives only in `.claude-plugin/plugin.json`; service tags (when C4+ cuts them) never use the plugin tag shape `vX.Y.Z` (OQ-3).
  - Verify: no service path is referenced from any version gate; `plugin.json` is the sole plugin version.
- **AC3.** The boundary is written down and single-homed. The rule "the control plane talks to the plugin through files and CLI calls only" lives in `docs/adr/0001-journal-engine.md`; `control-plane/README.md` and `AGENTS.md` cite it and never restate a second copy (record-ownership: the ADR owns the boundary record).
  - Verify: both citing files reference ADR 0001; the boundary sentence exists only in the ADR.
- **AC4.** `AGENTS.md` scoping. The "Key directories" block lists `control-plane/` with its role; the "No build step" code-conventions line is scoped to plugin surfaces and names `control-plane/` as the exception, citing ADR 0001 for the boundary.
  - Verify: grep `AGENTS.md` for `control-plane` hits the key-directories block and the scoped no-build-step line.
- **AC5.** Bump-class guard case. `skills/release/test-bump-class.sh` proves a service-directory commit passes the gate on a patch/none bump (a new `control-plane/**` file is not a Surface — `detect-surfaces.sh` never sees one), while the plugin path still fires (new `commands/*.md` + patch → exit 1). `githooks/pre-commit` and the SPEC-002 plugin.json/CHANGELOG pair rule therefore stay silent for a service-only commit: the hook only runs `check-bump-class.sh --cached`, and the pair rule governs version files a service commit never touches.
  - Verify: `bash skills/release/test-bump-class.sh` exits 0 with the service cases green.
- **AC6.** Smoke-discovery carve-out (SPEC-030 Discovery). `tools/smoke/smoke.py` excludes any path with a `control-plane` segment from every no-arg discovery kind, and `tools/smoke/test.sh` proves a planted broken script under `control-plane/` stays out of the gate output.
  - Verify: `bash tools/smoke/test.sh` exits 0 with the control-plane case green.
- **AC7.** Suite-discovery rule (SPEC-030 R4). `tools/run-all-tests.sh` discovery excludes any path with a `control-plane` segment, so un-ignored service build outputs can never be seeded as suites, and `tools/run-all-tests-test.sh` proves it.
  - Verify: `bash tools/run-all-tests-test.sh` exits 0 with the control-plane case green.
- **AC8.** Dirty-tree-clean service outputs. `.gitignore` ignores the `control-plane/` build-output paths (Go and container artifacts), so R9 dirty-tree snapshots and the R37 pool seed never see service build dirt.
  - Verify: `.gitignore` carries the `control-plane/` block; `git status` stays clean with a planted build output.
- **AC9.** Staged-path gate cases (SPEC-010 S7). `skills/release/test.sh` proves `check-staged-paths.sh` passes a service-only release when the service paths ride `--intended`, and still fails a service path that was not declared — the script itself is unchanged (S2/S4 exact-strings contract).
  - Verify: `bash skills/release/test.sh` exits 0 with the service cases green.
- **AC10.** Docs-drift root-anchoring proof. `skills/docs-drift/test.sh` plants service files under `control-plane/` (including a manifest-desc-shaped file pair) and proves no check fires on them, while the plugin-side check still bites.
  - Verify: `bash skills/docs-drift/test.sh` exits 0 with the root-anchoring case green.
- **AC11.** Install surface unchanged. `install.sh` keeps copying only `agents/` and linking `commands/`; `install-test.sh` gains one bite case proving a planted `control-plane/` artifact never lands in the installed tree. The installed plugin stays pure markdown/JSON.
  - Verify: `bash install-test.sh` exits 0 with the control-plane case green.
- **AC12.** CI surface unchanged in C1. No `.github/workflows/` file changes; the existing bump-class CI job keeps passing because service commits add no Surface and the new suites run in the existing all-suites/smoke jobs.
  - Verify: `git diff --name-only` over the ticket touches no `.github/` path; `bash skills/release/test-bump-class.sh` exits 0.
- **AC13.** Ships `2.0.0-pre.3` via `/release 2.0.0-pre.3` — explicit version (SPEC-010 arc scheme; maintainer ruling 2026-11-16). Never patch, minor, major, or `2.0.0`.
  - Verify: tag `v2.0.0-pre.3` exists; `plugin.json` carries `2.0.0-pre.3` bare; the CHANGELOG heading matches.


CDT-643 follows the same ruling: no `specs/` entry — the deliverable AC list below is the spec. C2
is the second child of the CDT-628 epic and builds on the C1 service directory (CDT-645,
`v2.0.0-pre.3`). Its gate home is the CI kill test (AC7) plus the ownership row (AC8). C2 owns the
journal path and DDL, which is the naming rule `record-ownership.md` reserves for the creating
ticket, and it cites the ADR 0001 boundary rather than restating it (C1 AC3 — single-homing). No AC
carries the `[process]` tag: each asserts file content (AC1–AC6, AC8, AC9) or gate/release content
(AC7, AC10).

### CDT-643

- **AC1.** A Run is one durable execution of a workflow for a ticket, and the journal is the record of it. `control-plane/journal/` is append-only: INSERT is the only legal event write, enforced at three layers — no mutation call in the package, the statement guard, and the `events_no_update` / `events_no_delete` triggers (`control-plane/journal/schema.sql`). State is pure replay (`journal.Replay`): nothing stores it and `control-plane/run/` keeps none of its own, so replaying the same journal yields the same state.
  - Verify: from `control-plane/`, `go test ./journal/ ./run/` exits 0, including the replay-determinism case (the same rows replay to an equal state) and the refused-mutation case (UPDATE and DELETE on `events` both abort).
- **AC2.** The journal path and DDL are owned here and stay inside the ADR 0001 boundary. Path: `$MROOT/.claude/runs/run.db` (`journalRelPath`, `control-plane/journal/open.go:24`), git-ignored (`.gitignore:39`). `journal.Resolve` takes `$DEVTEAM_RUN_DB` as an outright override; `$DEVTEAM_MROOT` overrides only the `$MROOT` anchor. DDL: one home, `control-plane/journal/schema.sql`. Engine: SQLite behind a narrow interface; the boundary rule is single-homed in ADR 0001 § "The narrow-interface boundary", cited here and never restated (C1 AC3). The journal REFERENCES decision-cards — card path, `ts`, `run_id`, never a copy of a card field — and never changes the frozen SPEC-033 AC6/M13 schema: `schema_version` stays `1` and the journal adds no card key. `journal.Open` refuses a path that resolves to `memory.db`.
  - Verify: `go test ./journal/` proves the default path, the `memory.db` refusal, the all-null-or-all-set card-reference rule, and that no statement outside the INSERT set mutates `events`; `git check-ignore -q .claude/runs/run.db` exits 0.
- **AC3.** Side effects carry idempotency keys. `events.idempotency_key` and the partial unique index `idx_events_idem` (`control-plane/journal/schema.sql`) hold one key per external effect: push, PR, ticket creation, release. The intent row is appended before the effect runs (SPEC-040 AC11, intent-then-outcome), so a replay that finds the key does not repeat the effect.
  - Verify: `go test ./journal/` proves `AppendIdempotent` on a used key returns that row's seq with `created=false` and writes nothing, and `go test ./run/` proves the machine takes no second effect on the replay path.
- **AC4.** One owner per run through a lease with a fencing token. The `lease` table (`control-plane/journal/schema.sql:95`) is the single-writer record: one row per run, one `owner`, a strictly monotonic `token`, a heartbeat timestamp, and a stall limit. Every mutating `control-plane/run` call presents `(owner, token)` inside one `BEGIN IMMEDIATE` transaction. A token at or below the live one is refused with `journal.ErrStaleToken` and writes nothing; an unexpired lease refuses a second owner with `journal.ErrLeaseHeld`; a takeover raises the token.
  - Verify: `go test ./run/` proves the stale token is refused with `ErrStaleToken` and appends no row, a live lease refuses a second owner, and a takeover raises the token.
- **AC5.** The reconciler runs on start. `control-plane/reconcile/` compares the journal with worktrees, branches, and processes, repairs the difference, and appends one `repair` event per repair — `repair` is a member of the closed event-kind set. A repair never edits a past row. The failure path is the named halt `reconcile_failed`, with a retry budget of 3 passes (`control-plane/run/budget.go`, `RetryBudgets`).
  - Verify: `go test ./reconcile/` seeds one divergence per compare (worktree, branch, process) and asserts one `repair` row for each; a failing pass lands on `halted:reconcile_failed` and spends one retry.
- **AC6.** Heartbeat, watchdog, and named halts. `lease.last_heartbeat_ts` and `lease.stall_limit_s` drive the watchdog, and a run that misses its limit is `stalled`. The stall limit scales with model speed by derivation, not by a new number (AC9). The named halt states are `halted:<reason>` for `stalled`, `lease_lost`, `reconcile_failed`, `budget_exhausted`, and `operator_halt`; each carries its reason and its retry budget (`control-plane/run/budget.go`, `RetryBudgets`), and a spent budget ends the run at `failed`.
  - Verify: `go test ./run/` proves an expired heartbeat yields `halted:stalled`, each resume spends one retry of that reason, and a spent budget yields `failed`.
- **AC7.** The kill test runs in CI. `control-plane/killtest/` kills the service at every lifecycle phase boundary and asserts the run completes exactly once: one `run_completed`, no repeated side effect, and the same replayed state. This is the gate that falsifies ADR 0001 cost 1 (§ Consequences, "Paid — costs this decision accepts", item 1). The ADR names two tests (§ Context, "The kill test"): K1 `kill -9` mid-run then resume, priced here per boundary; K2 forced reboot also needs the node agent and the linger operator step (`native-runner.md`), so it stays the epic-level acceptance line (CDT-628 § Acceptance).
  - Verify: the CI job runs `control-plane/killtest/` and exits 0; the kill list covers every phase boundary the state machine defines; each case ends with exactly one `run_completed` for that run.
- **AC8.** The ownership spec is complete. `docs/internal/control-plane/record-ownership.md` names one owner for each of the eleven plugin records, and the journal enters that table as row 12: owner `control-plane-only`, conflict rule `single-writer-lease`, path `$MROOT/.claude/runs/run.db`. `journal_meta` records the same owner inside the file (`owner`, `engine` keys, `control-plane/journal/schema.sql:113-117`). The row-5 memory-owner re-test is carried here: it re-runs when CDT-629 lands, against the API front, not the store.
  - Verify: the table carries 12 rows; rows 1-11 are byte-identical to the CDT-632 version; row 12's owner cell reads `control-plane-only` and its conflict-rule cell is in the closed set; § "Residual items" keeps the row-5 re-test open.
- **AC9.** CDT-610 is named as the precondition of any wall-clock tuning. CDT-610 — "BC6 wall-clock budget: exclude user wait, soft-pause ship step" — is carried by `run-budget.md` § "Open BC6 item", which states the rule: "Do not tune a per-model wall-clock before CDT-610 lands and is measured." C2 repeats it for phase 1: no wall-clock number is tuned, and the stall-limit knob reads `blocked: CDT-610`. The stall limit is derived, not chosen — the wall-clock cap divided by the iteration cap (`control-plane/run/budget.go`, `BudgetRow.StallLimit`), from the SPEC-033 § AC3 M9 static defaults and § AC9 M9b tier rows. The `DEVTEAM_STALL_LIMIT` override is the top of the precedence chain `run-budget.md` § Precedence owns; it is a watchdog knob, not a SPEC-033 budget cap, so SPEC-033 N12 stays satisfied (no budget-cap flag, no seventh `parse-flags.sh` key, no `AUTOPILOT_*_CAP` write). Docs state the rule and carry no numbers.
  - Verify: `grep -n 'CDT-610' control-plane/run/budget.go` hits the precondition note; `grep -n 'blocked: CDT-610'` hits this file; every wall-clock cell in `RunBudgetMap` equals the SPEC-033 cell it names as `Source`.
- **AC10.** Ships `2.0.0-pre.N` via `/release` — explicit version (SPEC-010 arc scheme). Never patch, minor, major, or `2.0.0`. C2 is an epic child, so the release is the epic fold, where master moves (SPEC-033): N is fixed there, `stable` stays at the last 1.x final release while the arc is open, and the C2 commit itself touches no version pair.
  - Verify: the tag and CHANGELOG heading carry `v2.0.0-pre.N` and `.claude-plugin/plugin.json` carries the bare form; `stable` is unchanged; `git diff --name-only` over C2 lists no `plugin.json` or `CHANGELOG.md` change.


CDT-642 follows the same ruling: no `specs/` entry — the deliverable AC list below is the spec. C3 is
the third child of the CDT-628 epic and builds on the C2 journal and run machine (CDT-643,
`v2.0.0-pre.4`). The graph data is one committed file, `docs/internal/control-plane/lifecycle-graph.json`,
and `control-plane/lifecycle/` is the only reader that validates it; the C3 gate home is that loader (AC1)
plus the boundary-list agreement with the kill test (AC2). C3 owns no gate policy: SPEC-033 keeps it
(AC6). No AC carries the `[process]` tag: each asserts file content (AC1–AC6) or release content (AC7).

### CDT-642

- **AC1.** The lifecycle graph is JSON, and load validates it. `docs/internal/control-plane/lifecycle-graph.json`
  (`graph: control-plane-lifecycle`, `schema_version: 1`) carries four sections. `vertices`: the seven
  `/orchestrate` workflow phases and the nine run states of the C2 machine. `edges`: the transitions between
  vertices, each with the blocking conditions that guard it. `kill_test_boundaries`: the kill set.
  `checkpoints`: the points a run resumes from. `control-plane/lifecycle` is the loader — `Load` (a path),
  `LoadBytes`, `LoadDefault` (`$DEVTEAM_LIFECYCLE_GRAPH`, else the file at or above the working directory).
  Decoding is strict: a syntax error, trailing data, a section of the wrong JSON type, or a key the contract
  does not define fails with `ErrMalformedJSON`. Every failure is a typed `*lifecycle.GraphError` that names
  the cause, the element, its id, and the field. The cause set is closed: the `Err*` vars in
  `control-plane/lifecycle/load.go`.
  - Verify: from `control-plane/`, `go test ./lifecycle/` exits 0; it loads the committed graph, and one case
    per named cause mutates that graph and asserts `errors.Is(err, <cause>)` plus the element, id, and field
    the error names.
- **AC2.** The graph is the single source of the boundary list the kill test iterates and of the checkpoint
  points. `lifecycle.BoundaryList()` returns § `kill_test_boundaries` in lifecycle order and
  `lifecycle.Checkpoints()` returns § `checkpoints`; both return copies. The kill-test sweep iterates
  `BoundaryList()` — the suite keeps no boundary list of its own, and a graph it cannot read fails the run.
  `lifecycle.EdgeGuard(phase, event)` returns the one edge that leaves a phase on a journal event. A pair that
  fans out to more than one target state names no single step: `run_halted` has one edge per halt reason, so
  `EdgeGuard` returns an `*lifecycle.EdgeLookupError` (`ErrAmbiguousEdge`) that names the candidate edges, and
  `lifecycle.Guards(phase, event)` returns the guards of every edge in the pair. Load is silent on such a
  pair — the fan-out is legal graph data. The loader cross-checks the file against the code it describes, so it cannot drift: a run-state
  vertex the machine cannot be in (`ErrUnknownState`), a `halted:<reason>` outside `journal.HaltReasons`
  (`ErrUnknownHaltReason`), a machine state with no vertex (`ErrMissingState`), a terminal flag that
  disagrees with the machine (`ErrBadTerminal`), a non-journal event kind (`ErrUnknownEvent`), and a phase
  ladder with a gap (`ErrBrokenLadder`) each fail load.
  - Verify: `go test ./lifecycle/ ./killtest/` exits 0; `TestGraphBoundaryListIsTheMachineLadder` proves the
    graph list equals the phase set the harness declares in `control-plane/killtest/phases.go` — same ids,
    same order, same journal row and run state per boundary — and the sweep subtests carry the graph ids.
- **AC3.** The phase-event contract exists. `control-plane/spool/` appends NDJSON phase events to
  `$MROOT/.claude/runs/spool/spool.ndjson` — git-ignored, with `$DEVTEAM_SPOOL` as the outright override and
  `$DEVTEAM_MROOT` as the anchor, the `control-plane/journal/open.go` pattern. The record shape is fixed and
  documented in `control-plane/spool/doc.go`: `ts` (the canonical journal timestamp), `run_id`, `phase`,
  `kind` ∈ {`start`, `end`, `gate`, `halt`}, and optional `detail`. The same doc states the trust rule: the
  path and the record arrive as argv, environment, or Go values; `detail` carries untrusted text and is
  marshalled as data, never assembled into a command, a shell string, or SQL; a move of the spool into
  SQLite follows `skills/lib/sqlq.sh` — fixed statement text, every value bound through `?`.
  - Verify: `go test ./spool/` exits 0 with the exact line shape, the closed kind set, the default path, the
    env override, and the untrusted-detail case; `git check-ignore -q .claude/runs/spool/spool.ndjson` exits
    0; `grep -n 'sqlq.sh' control-plane/spool/doc.go` hits the rule.
- **AC4.** Duplicate phase events are idempotent: a replay causes no second transition. `(run_id, phase,
  kind)` is the spool key. `Spool.Append` checks the key first and writes nothing when the spool holds it,
  refusing with the typed `spool.ErrDuplicate`. `Spool.Emit` is the replay path a workflow uses: it stamps
  the clock and folds that error into `created=false` with a nil error, so a replay of a crashed run neither
  fails nor records the event twice. The choice — typed error at `Append`, dedupe at `Emit` — is stated in
  the package doc.
  - Verify: `go test ./spool/` proves a second append of a used key returns `ErrDuplicate`, leaves the file
    byte-identical, names the existing line, and that `Emit` on the same key returns `created=false` with a
    nil error and one record on disk.
- **AC5.** The graph JSON carries the data the UI draws, and this child renders nothing. Every vertex, edge,
  boundary, and checkpoint carries `id`, `label`, `defined_at`, and `source` where the element copies a
  policy cell, plus `order` where order matters, so CDT-652 can draw the graph and the board from this file
  with no second model. The file carries no coordinate, colour, layout, style, or markup field, and
  `control-plane/lifecycle` ships accessors only — `VertexByID`, `Phases`, `RunStates`, `BoundaryList`,
  `Checkpoints`, `EdgeGuard`, `Guards` — and no drawing code.
  - Verify: `go test ./lifecycle/` loads the committed graph and exercises the accessors; `grep -niE
    'color|colour|svg|html|layout|style|css' docs/internal/control-plane/lifecycle-graph.json` finds no
    rendering field.
- **AC6.** SPEC-033 blocking conditions are cited, not restated, and SPEC-033 stays the gate policy. Every
  guard carries `bc` ∈ BC1–BC8, an `outcome` ∈ {`halt`, `reroute`}, and a `citation` of the form
  `specs/core/SPEC-033-autopilot-policy.md:<line>`; the loader refuses every other form (`ErrBadGuard`). A
  guard label names the condition in a phrase; the halt and reroute semantics stay in SPEC-033 M6/M7 and are
  cited, never copied (SPEC-033:229). C3 adds no gate, no gate flag, and no second policy: the three gate
  names are the SPEC-033:117 set, and worktree-per-ticket (SPEC-016) and the release train (SPEC-023) are
  untouched.
  - Verify: `go test ./lifecycle/` refuses a guard whose citation is prose, cites another spec, or names a BC
    outside BC1–BC8, and proves BC4 guards the plan edge only; `grep -c '"citation"'
    docs/internal/control-plane/lifecycle-graph.json` equals the guard count and every citation matches the
    SPEC-033 path form; `git diff --name-only` over C3 touches no `skills/`, `commands/`, `agents/`, or
    `.claude-plugin/` path.
- **AC7.** Ships `2.0.0-pre.N` via `/release` — explicit version (SPEC-010 arc scheme). Never patch, minor,
  major, or `2.0.0`. C3 is an epic child, so the release is the epic fold, where master moves (SPEC-033); N
  is fixed there, `stable` stays at the last 1.x final release while the arc is open, and the C3 commits
  touch no version pair.
  - Verify: the tag and the CHANGELOG heading carry `v2.0.0-pre.N` and `.claude-plugin/plugin.json` carries
    the bare form; `stable` is unchanged; `git diff --name-only` over C3 lists no `plugin.json` or
    `CHANGELOG.md` change.

CDT-644 follows the same ruling: no `specs/` entry — the deliverable AC list below is the spec. C4 is
the fourth child of the CDT-628 epic and builds on the C2 run machine (CDT-643, `v2.0.0-pre.4`) and
the C3 lifecycle graph (CDT-642, `v2.0.0-pre.5`). Its gate home is the CI kill lane (AC8) plus the
ownership row (AC3). No AC carries the `[process]` tag: each asserts file content (AC1–AC4, AC6–AC8)
or gate content (AC9), or is an operator step (AC5, AC10 — recorded pending-operator, never
executed inside the ticket). C4 ships no version pair: the release is the epic fold (the
"Ships `2.0.0-pre.N`" bullet).

### CDT-644

- **AC1.** One Go binary per node; the control plane talks only to the node agent. `control-plane/cmd/node-agent`
  carries the four-verb contract — `start`, `stop`, `status`, `steer` — and every state-changing verb
  writes its journal intent before it acts and its outcome after (the SPEC-040 AC11 intent-then-outcome
  pattern, through `run.Machine.Intent` / `run.Machine.Outcome`). `status` reads; on a running run it
  journals its reading as an intent-then-outcome pair (the one state where a `side_effect` row is
  replayable) and on any other state it is a pure read and says so (`"journaled": false`). No Docker
  dependency exists in the contract, the code, or the build — the G-02 image only compiles and runs
  the Go test suite.
  - Verify: `bash control-plane/build.sh linux-amd64` exits 0 and the binary answers `node-agent
    status-node` with its selection JSON; `go test ./agent/` proves the intent row lands before the
    spawn, the stop, and the steer it names, and closes with its outcome.
- **AC2.** The native runner is the first runner built and the default once selected. `control-plane/agent`
  supervises native runner processes: one host-CLI process on the node's own OS per run slot, spawned
  with its own logins (`credentials.md` § AC-9 native rows — Claude Code 2.1.325, the probed version,
  reads its subscription token file in the CLI's normal mode; the `--bare` split — `--bare` reads only
  `ANTHROPIC_API_KEY`/`apiKeyHelper` and never the OAuth/keychain file — is the caveat
  `credentials.md` carries, and the agent never spawns `--bare`), tracked by PID, steered at step
  boundaries through the control file `.claude/runs/agent/<run-id>.steer`, and stopped with SIGTERM
  then SIGKILL after a grace. The agent reuses the C2 machine, never forks it: one lease per run with
  the monotonic fencing token (owner `node-agent-<pid>`, so a restarted agent is a real takeover that
  raises the token), heartbeats inside the journaled stall limit, and the state as the replay of the
  journal. The CDT-626 reboot contract is the adoption policy: a restarting agent kills the dead
  supervisor's recorded orphan and re-spawns as the next attempt.
  - Verify: `go test ./agent/` — `TestSuperviseTakeoverAfterAgentDeathCompletesOnce` proves the
    takeover raises the token and completes the run exactly once; `TestRecoveryPerformsThePendingSpawn`
    proves a crash between the spawn intent and the spawn is performed once by the recovery;
    `TestNativeRunnerStopIsTermThenKill` proves SIGTERM then SIGKILL after the grace;
    `TestSuperviseSteerThenOperatorStop` proves the steer is delivered and the stop lands
    `halted:operator_halt`.
- **AC3.** Runner selection is a per-node setting, fail-closed. The record is
  `$MROOT/.claude/dev-team/node.json`, key `runner` (record-ownership row 14: `control-plane-only`,
  one reader), overridden by `$DEVTEAM_RUNNER` — the C7 single-reader pattern of
  `skills/backlog/linear-gate.sh`: first hit wins, every unrecognised value resolves to no selection.
  A node with no selection starts no run. The closed runner set is `native` — the first built and the
  default once selected.
  - Verify: `go test ./agent/` proves the resolution table (env, config, junk, invalid JSON, missing
    file) and that a refused start writes no journal row;
    `git check-ignore -q .claude/dev-team/node.json` exits 0.
- **AC4.** The node agent runs under machine supervision, with restart-on-failure and journal capture
  proven on the node. The proof is `native-runner.md` § probe 3 (2026-11-15): systemd spawned the
  unit's command, tracked it by PID, restarted it on failure (`Restart=on-failure`, `RestartSec=2s`,
  counter 6→7 in journald), and captured every attempt — the mechanics are independent of the binary
  at `ExecStart`. C4 updates the unit record with the real binary's contract and leaves the install
  (`/usr/local/bin/node-agent`) and enable as operator work.
  - Verify: `native-runner.md` § probe 3 carries the verbatim `systemctl --user status` and
    `journalctl --user` transcripts, and § "CDT-644 — the node agent is real" names the receipts.
- **AC5.** Operator step B8: `loginctl enable-linger <user>` executed on the node, documented with
  `loginctl show-user -p Linger` before and after as evidence. — **pending-operator**: the exact
  commands and the evidence slots are recorded in `native-runner.md` § "Operator step B8", and the
  step is not executed inside the ticket.
  - Verify: `native-runner.md` § "Operator step B8 — linger (pending-operator)" carries the
    before/after command pair and its evidence slots, marked pending-operator.
- **AC6.** `credentials.md` is read in full, and the agent's credential posture is the CLI's own.
  The native runner relies on the installed host CLIs and their logins — the per-host AC-9 native
  rows (Claude Code 2.1.325, the probed version; Grok 1.0.77; omp 18.7.0), the `--bare` credential
  split (`--bare` reads only `ANTHROPIC_API_KEY`/`apiKeyHelper`, never the OAuth/keychain file), and
  the four residual gaps (§ "Gaps found": the container-half coverage note, the omp env-var names,
  the Claude Code version drift, the bare-mode split). The agent never injects, mounts, or copies a
  credential: the child inherits the agent's environment and reads its own files, and never spawns
  `--bare`.
  - Verify: `control-plane/agent/doc.go` cites `credentials.md` § AC-9 native rows; the C4 section of
    `native-runner.md` names the `--bare` split and the four residual gaps.
- **AC7.** The Go build image approval is recorded once, with evidence and a digest pin. The
  maintainer approved `docker.io/library/golang:1.27-bookworm@sha256:4fa7c968ba93f1635670522dbb01a2c78150443e1385746924566079f36570ea`
  for the build on 2026-11-17 — official Docker Library `golang`, active maintenance, root inside the
  container but build outputs landing on the host-user-owned worktree mount. The phase-0 approval
  covered the probe only; `node-agent-build-probe.md` § "The C4 build" carries the approval row.
  - Verify: `node-agent-build-probe.md` § "The Go build image — approval record" carries the source
    repo, the maintenance status, the root-vs-non-root row, and the digest pin.
- **AC8.** Build artifacts exist for the three phase-0 targets — amd64 native, linux/arm64,
  darwin/arm64. The build entry is `control-plane/build.sh`, inside the G-02-approved Go image,
  digest-pinned, with GOCACHE/GOMODCACHE outside the mount and `CGO_ENABLED=0` static output. The
  artifacts land in `control-plane/dist/` (git-ignored) and ship in no release.
  - Verify: `bash control-plane/build.sh` exits 0; `file control-plane/dist/node-agent-*` names an
    x86-64 ELF (statically linked), an ARM aarch64 ELF, and a Mach-O arm64 binary;
    `git check-ignore -q control-plane/dist/node-agent-linux-amd64` exits 0.
- **AC9.** The CI kill job is parameterised by runner type and passes with the native runner
  selected. The C2 lane (the `control-plane` job in `.github/workflows/smoke.yml`) takes a
  `runner_type` workflow-dispatch input, defaults to native, and reaches the killtest helper as
  `$DEVTEAM_RUNNER` — the node agent's own C7 selection variable. The helper resolves the selection
  through `agent.Load` and refuses an unknown runner fail-closed before any journal row is written;
  the attempt report carries the resolved runner type.
  - Verify: `go test ./killtest/` — `TestUnknownRunnerTypeIsRefusedFailClosed` proves an unknown
    runner refuses with nothing written and `TestNativeRunnerSelectedRunsTheKillTest` proves the
    lane passes with native selected; the workflow passes `-e DEVTEAM_RUNNER="$DEVTEAM_RUNNER"`
    into the G-02 container.
- **AC10.** The reboot acceptance test uses a real Windows reboot of the WSL host, not a service kill:
  every in-flight run continues without a human, with the reboot command and resumed run ids as
  evidence. — **pending-operator**: the protocol (start a run → `wsl.exe --shutdown` or a Windows-side
  `shutdown /r /t 0` → prove the takeover in the journal with no human input) and the evidence slots
  are recorded in `native-runner.md` § "Operator step — reboot acceptance test", and the step is not
  executed inside the ticket. The code-level proof of the same contract is `go test ./agent/`
  (AC2's takeover and recovery tests).
  - Verify: `native-runner.md` § "Operator step — reboot acceptance test (pending-operator)" carries
    the protocol and the evidence slots, marked pending-operator.
- **AC11.** Ships `2.0.0-pre.N`; never patch, minor, major, or `2.0.0` — the release is the epic fold done
  by the orchestrator later, so C4's commits touch no version pair
  (`.claude-plugin/plugin.json` and `CHANGELOG.md` are untouched).
  - Verify: `git diff --name-only ef1c2c4..HEAD` lists no `plugin.json` or `CHANGELOG.md` change.
### CDT-646

- **AC1.** A ticket, an epic, and a child can be created, claimed, and closed from the plane with no network, and the local backlog is the source of truth. `skills/backlog/ticket.sh:116-125` is the verb CLI (`create` → `add.sh`, `claim` → `close.sh claim`, `close` → `close.sh` — one copy of each write path, no second writer); the epic and child fields ride the item frontmatter (`kind`, `epic_parent`, `child_id`, `depends_on`, `estimate`, `agent`). The store is `$MROOT/.claude/backlog.md` plus `$MROOT/.claude/backlog/<slug>.md` (`.gitignore:5,6`), and every verb writes it first (SPEC-009:239).
  - Verify: `bash skills/backlog/ticket-test.sh` exits 0 — create → claim → close of a throwaway ticket with `LINEAR_SYNC` unset and zero Linear MCP calls, the store path printed, and rc `0` ok / `1` verb failure / `64` usage.
- **AC2.** Linear is opt-in per project: off means zero Linear calls; on means local write first, sync second. `skills/backlog/linear-gate.sh:12-16` is the gate CLI (`status`, `enabled`, `set`, `sync`) and the one reader of `linear_sync` (SPEC-009:240, "One reader of the key (MUST)"). Resolution order is `$LINEAR_SYNC` → `<root>/.claude/dev-team/config.json` (`.gitignore:50`) → `off`, and every unrecognised value resolves `off` (`skills/backlog/linear-gate.sh:22-23`). `sync -- CMD` is the ordering seam: off prints one `linear-skip:` line and never runs `CMD`.
  - Verify: `bash skills/backlog/linear-gate-test.sh` exits 0 — the gate resolves `off` on absent, empty, junk, and invalid-JSON config, resolves `on` only through the explicit key, and `sync --` never runs the Linear leg while off.
- **AC3.** The posture text is amended in the two places the agents read. SPEC-009 § Backlog names the store as the source of truth and supersedes the CDT-54 Linear-first rule (SPEC-009:239), with the key and its one reader defined at SPEC-009:300 (§ Linear sync is opt-in). The `AGENTS.md` § What NOT To Do process-tracker bullet (AGENTS.md:301-315) names the plane-owned ticket records — `.claude/backlog.md`, `.claude/backlog/<slug>.md`, the plans, the sweep journal, the `linear_sync` config — names owner **plugin** and the closed-set rule **single-writer-lease**, states Linear is never a writer, and keeps "never stage trackers into delivery commits" verbatim.
  - Verify: `bash skills/backlog/surfaces-gate-test.sh` exits 0 with the posture receipts green — `spec-calls-the-store-the-source-of-truth`, `agents-md-names-the-conflict-rule`, `agents-md-keeps-the-never-stage-rule` — and `bash tools/spec-lint.sh` exits 0.
- **AC4.** Each Surface that reads the backlog keeps working with the gate off: `/kickoff` (Step 1 intake), `/orchestrate` (`skills/orchestrate/steps/01-fetch.md` § Tracker-plane gate, plus ship close-out), `/status` (`commands/status.md` § Tracker plane and its standup backend), `/epic` (`skills/epic/run-start.md` Step 0). Each carries the gate binding and the offline rule in its own text and completes a real ticket operation in a fixture project with no config file.
  - Verify: `bash skills/backlog/surfaces-gate-test.sh` exits 0 — one bound gate receipt per Surface (`kickoff-intake-writes-ticket-offline`, `orchestrate-ship-close-out-verifies-offline`, `status-open-set-reads-store-offline`, `epic-init-writes-state-offline`) plus the shared-key receipts that flip all four off → on.
- **AC5.** The record the plane writes carries one owner and one conflict rule from the closed set in `docs/internal/control-plane/record-ownership.md`. Row 4 — the backlog index and item files, the plane-owned ticket records (docs/internal/control-plane/record-ownership.md:53) — is owner `plugin` with `single-writer-lease`, and Linear is never a writer of it. Row 13 — the project config that carries `linear_sync` (docs/internal/control-plane/record-ownership.md:62) — is `plugin` / `plugin-only` with `skills/backlog/linear-gate.sh` as its single reader. Row 12 (the run journal) stays the table's only `control-plane-only` row: the control plane reaches the store through files and CLI calls only (ADR 0001 § "The narrow-interface boundary").
  - Verify: row 4's owner cell reads `plugin` and its conflict-rule cell reads `single-writer-lease`; row 13's cells read `plugin` and `plugin-only`; `bash skills/backlog/surfaces-gate-test.sh` exits 0 with `ownership-row-4-is-the-local-store` and `ownership-row-4-drops-linear-as-writer` green.
- **AC6.** Ships `2.0.0-pre.N` via `/release` with the explicit version (SPEC-010 arc scheme). Never patch, minor, major, or `2.0.0`. C7 is an epic child, so the release is the epic fold, where master moves (SPEC-033): N is fixed there, `stable` stays at the last 1.x final release while the arc is open, and auto-detect and the bump keywords never compute a pre version.
  - Verify: at ship — the tag and the CHANGELOG heading carry `v2.0.0-pre.N`, `.claude-plugin/plugin.json` carries the bare form, and the heading matches the tag byte-for-byte; `stable` is unchanged; the C7 commit itself lists no `plugin.json` or `CHANGELOG.md` change.

### CDT-649

- **AC1.** Slot ruling implemented and recorded: one slot is one runner — one process or one container — and the queue counts runners. `control-plane/queue/` journals one `slot.grant` per runner through the C2 machine, and the ledger folds those intents into the count the caps read. The term "Slot" is not renamed.
  - Verify: `go test ./queue/` — `TestSlotCountsRunners` proves one grant holds one slot and a release gives it back; `grep -n 'one slot is one runner' CONTEXT.md` hits the amended cell, unrenamed.
- **AC2.** The per-model-endpoint limit is a separate cap the queue reads from the Model map; both caps are enforced independently; overflow waits and shows as waiting. The node cap is the existing concurrency setting; the model cap is the map's top-level `model_slots` object (key: the match key, value: an integer ≥ 1). Either cap alone makes the runner wait, and the pending `slot.wait` intent is the waiting state — `Slots()` is the status-surface read that shows it. Waiting is a queue-level status on a live runner, not a run state, so the lifecycle graph gains no vertex (CDT-642).
  - Verify: `go test ./queue/` — `TestCapsAreIndependent` proves the node cap admits what the model cap refuses and one model's cap never binds another's; `TestOverflowWaitsAndShowsAsWaiting` proves the waiting row reaches the status surface; `git diff --name-only 448e86d..HEAD` lists no `lifecycle-graph.json` change.
- **AC3.** The limit's sources are named: the existing concurrency setting and the Model map. The node cap reads `COUNCIL_CONCURRENCY` first, then the map's top-level `concurrency` key — local > repo > global, the `resolve-concurrency.sh` chain, never forked. The model cap reads `model_slots` from the same three layers. Unset everywhere means unbounded; an invalid stored value fails closed.
  - Verify: `go test ./queue/` — `TestModelCapReadsTheMapLayers` proves the layer precedence, the env layer, and the fail-closed junk cases; `grep -n 'COUNCIL_CONCURRENCY\|model_slots' control-plane/queue/*.go` names both sources.
- **AC4.** The SPEC-033 amendment lands with all five `run-budget.md` § Deferral inputs. `run-budget.md` § Amendment records the landed state, and the dated row in `specs/core/SPEC-033-autopilot-policy.md` § Version History (2026-11-17) carries the ruling; the AC9 precedence chain gains the map layer between env and the static default. The five inputs:
  - (i) the map precedence insert between env and the static default — `env > map > tier`, per cap, independently;
  - (ii) the ceiling amendment scope — N14's two clauses stay in force: a model-keyed row may not exceed the L ceiling (40 / 4500), and there is no `/setup` budget store — the Model map (SPEC-037 M11) is the store;
  - (iii) N12 stays — the engine never writes the env caps; the map layer is read-only;
  - (iv) the per-Run aggregation rule — a model-keyed cap binds per runner, not per Run: a multi-agent Run holds one slot per runner, each counted against the model cap of that runner's resolved model; the Run's own concurrency setting caps the total; no runner waits on another runner's model cap;
  - (v) the match key — the resolved model string itself, tier token or full vendor slug, compared byte-exact, never truncated, never prefix-matched, so a stale slug matches nothing rather than a family (the CDT-603 failure mode, applied to slots); CDT-603 stays open and owns the write-time validation.
  - Verify: the § Verification block at the bottom of `run-budget.md` passes (all seven receipts); `grep -n '2026-11-17' specs/core/SPEC-033-autopilot-policy.md` hits the amendment row; `grep -n 'CDT-649' docs/internal/control-plane/run-budget.md` hits the landed amendment.
- **AC5.** The CONTEXT.md Slot cell is amended to close the open question per the ruling; the other ten terms, Steer included, stay verbatim.
  - Verify: `git diff 448e86d..HEAD -- CONTEXT.md` touches the Slot row and one dated decision line only; the other ten term rows are byte-identical.
- **AC6.** Slot grant, wait, and release are journaled; a kill-and-replay never grants a slot twice. Every verb is an intent-then-outcome pair through `run.Machine.IntentWhenKeyed` inside one fencing-token-checked transaction, and the accounting is the intent-based ledger fold — the transaction reads the state its own intent folded into, so a replay re-derives the grant it recorded and counts one slot, not two. A landed wait stays pending on purpose: its outcome lands granted true from a later grant, granted false and released true from a release.
  - Verify: `go test ./queue/` — `TestKillAndReplayNeverGrantsTwice` proves exactly one grant intent after the replay and one held slot; `TestWaitResolvedByLaterGrant` and `TestReleaseClosesTheWaitGrantedFalse` prove both wait-close sides leave no pending effect.
- **AC7.** Ships `2.0.0-pre.N`; never patch, minor, major, or `2.0.0`. The release is the epic fold done by the orchestrator later; the C5 commits touch no version pair (`.claude-plugin/plugin.json` and `CHANGELOG.md` are untouched).
  - Verify: `git diff --name-only 448e86d..HEAD` lists no `plugin.json` or `CHANGELOG.md` change.

### CDT-648

- **AC1.** The adapter implements start, resume, steer, and observe for Claude Code and Grok, and
  calls the node agent only — never a host CLI directly. `control-plane/hostadapter` realizes every
  host action through the node agent's four-verb contract: start hands the host's launch argv to the
  agent's start verb (the agent spawns one host-CLI process per run slot, tracks the PID, and
  supervises); steer encodes the correction into the host's control-message frame and hands it to
  the agent's steer verb; observe surfaces the agent's status reading plus the session id; stop is
  the agent's stop verb, unchanged. omp rides the same four verbs through its matrix row (AC4).
  No adapter code execs `claude`, `grok`, or `omp`, and no Docker dependency exists anywhere.
  - Verify: `go test ./hostadapter/` — the NodeAgent seam (`TestSteerThroughTheAgentDeliversAtTheBoundary`)
    drives a real run end-to-end through the agent's supervision loop, and the argv/frame assertions
    (`TestResumeFollowsTheNamedPathPerHost`, `TestSteerEncodesTheHostFrame`) hold without any test
    exec'ing a host CLI.
- **AC2.** Resume follows the matrix AC-4 named path per host (a headless invocation — CLI flags
  plus session-id source — distinct from the steerable launch, review B1), and the session id is
  captured at start. Claude Code: `claude -p --resume <session-id>`, the id from the stream-json
  `system/init` event (P-CC-A). Grok: `grok -p --output-format json --resume <SESSION_ID_OR_TITLE>`
  (the `grok agent stdio` transport accepts no resume flags), with `--continue` (newest session in
  the cwd) and `--fork-session` (resume into a new session id) on the same headless route, the id
  from the headless `--output-format json` result's `sessionId` field (P-GK-CTR-2). omp:
  `omp -p --mode json -r <id>` (id prefix, session path, or picker) or `--continue` (one spelling,
  review B2), the id from the `{"type":"session","id":…}` frame (P-OMP-C-A). The capture rides the
  agent's runner output during the start verb; a resume by id without the captured id refuses
  (named `ErrNoSessionID`), a variant a host's matrix row does not name refuses with the cell
  verdict, and a request setting both Continue and Fork refuses (named `ErrResumeAmbiguous`).
  - Verify: `go test ./hostadapter/` — `TestResumeFollowsTheNamedPathPerHost` proves the flag per
    host and the two Grok companions; `TestSessionIDCapturedAtStartPerHost` proves the id source
    per host and that a later frame never overwrites the captured id.
- **AC3.** Steer delivers a correction at the next step boundary and never interrupts a turn. The
  adapter encodes the frame — Claude Code's stream-json user message (P-CC-C), Grok's ACP
  `session/prompt` (P-GK native + P-GK-CTR-3c), omp's RPC `{"type":"steer"}` (P-OMP-C-C) — and the
  node agent's steer verb delivers it at the boundary; the untrusted message travels as JSON data,
  never as a command line. The glossary Steer term is written unchanged (CONTEXT.md § Terms), and
  the dated write-back log gains the CDT-648 entry citing the six reproduced probes.
  - Verify: `go test ./hostadapter/` — `TestSteerThroughTheAgentDeliversAtTheBoundary` proves the
    frame is delivered at the agent's step boundary and the run completes;
    `TestSteerMessageTravelsAsData` proves quotes, backslashes, and newlines survive as data;
    `grep -n '| Steer |' CONTEXT.md` shows the term row verbatim.
- **AC4.** The omp path follows its matrix row (omp 18.7.0), and the matrix is the source for resume
  and steer behaviour per host. The registry (`control-plane/hostadapter/matrix.go`) encodes the
  three adapter routes — resume, headless streaming, steer — as host × capability cells carrying the
  index verdicts with their citations, and every adapter route is gated by its cell first.
  Deviation recorded: the CDT-648 B7 probe ran on the omp build installed on the node on 2026-11-17
  (v18.22.0 — the matrix-locked 18.7.0 binary was replaced and is gone); the matrix's 18.7.0-probed
  rows stand as dated evidence (2026-11-15), the drift is flagged in the matrix's omp section
  ("Version drift flag (2026-11-17, CDT-648 B7)"), and the resume/steer encodings cite those rows
  and their probes. Review B1 rides this AC: the Grok resume invocation is the headless route the
  matrix AC-4 names (`grok -p --output-format json --resume <id>`), not the steerable `grok agent
  stdio` launch, which accepts no resume flags.
  - Verify: `go test ./hostadapter/` — `TestMatrixCellsGateEveryRoute` walks all twelve cells and
    holds each against the matrix verdict and citation; `TestResumeFollowsTheNamedPathPerHost`
    proves the headless resume invocation per host and that no resume argv carries the steerable
    `agent stdio` tokens.
- **AC5.** (B7: the on-box env-var-name probe.) An on-box probe proves which provider env-var name omp reads per provider, the
  adapter injects only a proven name, and an unproven name fails closed. The probe ran headless
  omp against each provider with a dummy, non-routing value in exactly one candidate variable and
  recorded the provider-side auth failure naming the bad key; `credentials.md` § "Gap 2 — resolved"
  carries the method and the verbatim evidence. The adapter's proven-name table (`credentials.go`)
  carries the five proven names plus the negative result (llama.cpp reads no env var — its key
  lives in the auth store), and injection of anything else refuses with
  `ErrCredentialNameUnproven` before any journal row is written. No real secret value is printed
  anywhere; the probe used dummy values only. Deviation recorded: the probe ran on the omp build
  installed on the node on 2026-11-17 (18.22.0 — the matrix-locked 18.7.0 binary was replaced);
  see the deviation note in the B7 record.
  - Verify: `go test ./hostadapter/` — `TestCredentialInjectionIsGatedByProvenNames` proves the
    env entry per proven provider and the fail-closed cases; `TestProvenNameTableMatchesTheB7Probe`
    proves the table carries exactly the B7 result.
- **AC6.** An unsupported combination returns the matrix cell verdict as a refusal, not a silent
  no-op. mini-swe: no resume, no steer — every mini-swe route refuses with the cell verdict and the
  vendor-primary doc citation (`Refusal`, carrying `ErrUnsupportedCapability`), an unknown host
  refuses with `ErrUnknownHost`, and a refused route never reaches the node agent, so no journal
  row is written.
  - Verify: `go test ./hostadapter/` — the unsupported rows of
    `TestMatrixCellsGateEveryRoute` assert the refusal carries the host × capability cell, its
    verdict, and its citation, and that the seam recorded zero calls.
- **AC7.** Ships `2.0.0-pre.N`; never patch, minor, major, or `2.0.0` — the release is the epic fold done
  by the orchestrator later, so C6's commits touch no version pair
  (`.claude-plugin/plugin.json` and `CHANGELOG.md` are untouched).
  - Verify: `git diff --name-only a4baf9b..HEAD` lists no `plugin.json` or `CHANGELOG.md` change.

### CDT-647

- **AC1.** The container runner runs one container per run with the worktree mounted, and the
  native runner stays the default. `control-plane/agent/container.go` realizes the second runner
  type of the C4 closed set (`agent.KnownRunners` gains `container`, native first and default):
  one run is one `docker run --rm -i --init --name devteam-run-<run-id>` invocation with the run's
  worktree bind-mounted at its host path (`container-runner.md` Fact 3), the host CLI mounted
  read-only (Fact 4), and the host's session state mounted read-write so resume and steer survive
  container death over the mounted paths (Fact 2). A node whose selection does not name
  `container` runs the native runner exactly as C4 built it.
  - Verify: `go test ./agent/` — `TestContainerPlanBuildsTheSessionInvocation` proves the one-
    container plan with its mount set; `TestKnownRunnersAreClosedAndNativeFirst` proves the closed
    set order and the default.
- **AC2.** Only the node agent holds the Docker socket; the agent session inside the container
  gets none. `agent.guardSessionArgv` refuses every session invocation that mounts the socket
  (short and long mount forms), adds a Docker group, or widens the container beyond the probed
  posture (`--privileged`, `--pid=host`, `--userns=host`, `--network=host`), and the live test
  observes the socket absent from the session's own container.
  - Verify: `go test ./agent/` — `TestGuardSessionArgvRejectsTheSocketAndTheWidenings` walks the
    refusal table; `TestContainerSessionNeverSeesTheDockerSocketLive` proves the live absence.
- **AC3.** The contract is unchanged (start, stop, status, steer) and the type is chosen by the
  per-node setting from C4. `Container` implements the same `agent.Runner` interface with the
  same semantics — stop is `docker stop -t`, the same TERM-then-KILL contract at the container
  boundary; steer rides the client's stdin pipe unchanged — and the selection stays the C4
  fail-closed surface: the `runner` key of `.claude/dev-team/node.json`, overridden by
  `$DEVTEAM_RUNNER`, unknown token refuses with zero journal rows.
  - Verify: `go test ./agent/` — `TestContainerRunnerStartSteersAndStopsLive` proves the four
    verbs live; `TestResolveRunnerSelection` and `TestUnknownRunnerTypeIsRefusedFailClosed`
    (`go test ./killtest/`) prove the fail-closed selection.
- **AC4.** Resume and steer survive container death over the mounted paths (the matrix container
  cells); the `container-runner.md` Fact 2 writability rule is honoured, and the unprobed
  forced-refresh case (B6) keeps the conservative rule. State written by container 1 is
  container 2's starting state over the rw state mounts; no behavior widens beyond the probe
  facts — the forced token-refresh probe stays a named blocker per `container-runner.md`.
  - Verify: `go test ./agent/` — `TestContainerResumeSurvivesDeathOverTheMountedPathsLive`
    proves the death→resume hand-off over the mounted paths.
- **AC5.** Every image the runner references is named and digest-pinned, and each is presented
  for G-02 approval with evidence before its first pull. The runner references exactly one image
  — the session image — as a digest-pinned constant with an init-time pin check that panics at
  load when the constant stops carrying `@sha256:<64 hex>`; the evidence table and the G-02
  presentation record live in `container-runner.md` § "CDT-647 — the container runner is real".
  No other image is pulled or referenced (the prelude package set is the G-02 row-1 record's
  pre-approved `git curl ca-certificates`).
  - Verify: `go test ./agent/` — `TestSessionImageIsNamedAndDigestPinned` proves the pin shape
    fails closed; the presentation record is read against `container-runner.md`.
- **AC6.** The CI kill job passes with the container runner selected. The C4 `runner_type` input
  admits `container`; the lane drives the machine directly and spawns no session container, and
  an unknown runner type still refuses fail-closed.
  - Verify: `go test ./killtest/` — `TestContainerRunnerSelectedRunsTheKillTest` proves the
    container lane completes exactly once; `TestUnknownRunnerTypeIsRefusedFailClosed` holds the
    refusal.
- **AC7.** A node that keeps the containers-only rule runs phase-1 work there with no plugin
  change. The containers-only posture comes from the host-capability-matrix; the selection
  surface is C4's own (`node.json` runner key / `$DEVTEAM_RUNNER=container`), and the operator
  recipe lives in `container-runner.md` § "Operator recipe — a containers-only node" with the
  README pointing at it — no plugin-side change beyond the runner itself.
  - Verify: `grep -n "Operator recipe" docs/internal/control-plane/container-runner.md` names the
    section; `control-plane/README.md` § "Selecting the container runner" is the pointer, and the
    C4 selection tests above prove no new surface.
- **AC8.** Ships `2.0.0-pre.N`; never patch, minor, major, or `2.0.0` — the release is the epic
  fold done by the orchestrator later, so C8's commits touch no version pair
  (`.claude-plugin/plugin.json` and `CHANGELOG.md` are untouched).
  - Verify: `git diff --name-only d09f629..HEAD` lists no `plugin.json` or `CHANGELOG.md` change.

CDT-650 follows the same ruling: no `specs/` entry — the deliverable AC list below is the spec. C9
is the ninth child of the CDT-628 epic and builds on the C2 run machine and journal (CDT-643), the
C5 queue (CDT-649), the C6 steer path (CDT-648), and the C8 container runner (CDT-647). Its gate
home is the test suite of `control-plane/chief/` plus the one-interface guard (AC6) and the
ownership row (AC5's record). No AC carries the `[process]` tag: each asserts file content
(AC1–AC6) or release content (AC7).

### CDT-650

- **AC1.** The Chief routes work to the existing Surfaces and reimplements none of them. A defect
  routes to `/debug`, an idea to `/brainstorm` and then a ticket, and an epic to child tickets:
  `control-plane/chief` names the Surface in the run's `workflow` field (`commands/debug.md`,
  `skills/brainstorm/SKILL.md`, `commands/epic.md` — real plugin files), writes the ticket record
  the Surface reads through the plugin's own ticket verbs (`skills/backlog/ticket.sh` — the C7 CLI
  over the local backlog store, never a second writer of row 4), and starts the run through the C6
  host adapter and the node agent's four-verb contract. An epic route ends at the child-ticket
  records; no debug, brainstorm, or epic logic is reimplemented in Go.
  - Verify: `go test ./chief/` — `TestRouteDefectNamesTheSurfaceAndStartsTheRun`,
    `TestRouteIdeaAndEpicUseTheTicketVerbs`, and `TestRouteRefusalsAreTyped` prove the three
    routes, the plugin-verb ticket leg, and the typed refusals;
    `TestTicketCLIRunsTheRealVerbs` proves the ticket leg is the plugin's own script writing the
    store at `$MROOT`.
- **AC2.** The Chief reports on request — run status, checks, stand-up — and every answer comes
  from journal and queue state, never prose. Run status is the replayed state
  (`control-plane/journal`); the checks reading is the run's pending effects, repairs, and
  watchdog reading; the queue view is the C5 slot ledger (`control-plane/queue.Slots`); the
  stand-up report composes active and finished runs, halts, and slots. The API serves them at
  `GET /v1/runs`, `GET /v1/runs/{run}`, `GET /v1/checks`, `GET /v1/queue`, and `GET /v1/standup`.
  - Verify: `go test ./chief/` — `TestReportsFoldJournalAndQueueState` proves the three reports
    fold the seeded journal and queue rows; `TestAPIIsTheWholeSurface` and
    `TestAPIQueueAnswersFromTheLedger` prove the API serves them from the same state.
- **AC3.** The model of a routed run is selectable through the Model map
  (`skills/model-map/resolve-model.sh`, SPEC-037); an empty resolution — no layer, an empty value,
  an unnamed agent — is the Tier default (`control-plane/run/budget.go`, `run.TierDefault`); no
  new flag exists. The agent token rides the route request, never a command line, and the
  resolved model and its source ride the route response and the run's own claim row.
  - Verify: `go test ./chief/` — `TestModelMapResolution` proves the map hit, the empty
    resolution, the unnamed agent, and the real-script fallback;
    `TestRouteModelResolvesEmptyToTheTierDefault` proves the route lands on the Tier default.
- **AC4.** A correction sent through the Chief reaches the running session at its next step
  boundary and does not interrupt a turn — the C6 steer path end-to-end: the host adapter encodes
  the host's control-message frame and hands it to the node agent's steer verb, whose delivery is
  the step-boundary mechanic; the message travels as data, never as a command line. A chief
  restarted between the start and the correction derives the host from the run's recorded start
  argv (`agent.start`), so the route survives the restart.
  - Verify: `go test ./chief/` — `TestCorrectionRidesTheSteerPathEndToEnd` proves the live run,
    the delivered frame at the step boundary, and that every journal row the run carries is one of
    the machine's closed kinds; `TestCorrectDerivesHostFromTheStartRecord` proves the
    restart-derivation.
- **AC5.** A named halt is reported with its reason and its remaining retry budget, and reaches
  the operator through the Intercom as the phone channel for halts. The report is the C2 halt row
  (`control-plane/run/budget.go` — reason, retry budget, remaining) served at `GET /v1/halts`; the
  page is one outbox record through the plugin's own intercom CLI (`skills/intercom/intercom.sh`,
  SPEC-038 — never a second channel). The page record `$MROOT/.claude/runs/chief/notified.jsonl`
  carries one intent line before the page and one outcome line after, keyed by the halt row's seq,
  so a restart never pages a halt twice and a crash between the intent and the page re-pages once.
  - Verify: `go test ./chief/` — `TestHaltPageCarriesReasonAndBudget` proves the page names the
    reason and the budget; `TestRestartNeverPagesTwice` and
    `TestCrashBeforeThePageRepPagesOnce` prove the at-least-once record;
    `TestIntercomPageExecsTheSendVerb` proves the page rides the intercom CLI's own send verb.
- **AC6.** The Chief is reachable only over the API the web UI uses; there is no second interface.
  `chief.Handler` (`control-plane/chief/api.go`), served by `control-plane/cmd/chiefd`, is the
  whole surface — the route, the correction, and the reports over one set of endpoints — and no
  CLI verb, no shell entry point, and no second copy of any verb exists. The web UI (C10)
  consumes these endpoints and gains no endpoint of its own.
  - Verify: `go test ./chief/` — `TestAPIIsTheWholeSurface` proves the endpoints serve the route,
    the correction, and the reports; `grep -n 'os.Args\|flag.Arg' control-plane/chief/*.go` hits
    no verb dispatch outside `cmd/chiefd`'s flag parsing.
- **AC7.** Ships `2.0.0-pre.N`; never patch, minor, major, or `2.0.0` — the release is the epic
  fold done by the orchestrator later, so C9's commits touch no version pair
  (`.claude-plugin/plugin.json` and `CHANGELOG.md` are untouched).
  - Verify: `git diff --name-only 76d22ba..HEAD` lists no `plugin.json` or `CHANGELOG.md` change.

CDT-652 follows the same ruling: no `specs/` entry — the deliverable AC list below is the spec. C10 is
the tenth child of the CDT-628 epic and builds on the C3 lifecycle graph and its phase-event spool
(CDT-642), the C5 queue (CDT-649), and the C9 Chief (CDT-650). Its gate home is the test suite of
`control-plane/chief/` and `control-plane/cmd/chiefd/`, the loopback bind guard, and the per-Surface
standalone checks. No AC carries the `[process]` tag: each asserts file content (AC1–AC6) or release
content (AC7).

### CDT-652

- **AC1.** The web UI is one screen over the one API: chat with the Chief plus a run board, both riding
  `chief.Handler`'s endpoints — there is no endpoint for the UI alone. The UI is a small set of static
  files embedded in `control-plane/cmd/chiefd` (`go:embed`; no build step, no external toolchain) and
  served by the same process on the same loopback port as the API; every value it shows and every
  action it takes rides the `/v1` endpoints — the chat is the C9 corrections flow plus the route verbs,
  and the board is runs/queue/checks/halts. The static page is delivery, not data: the API
  surface of `control-plane/chief/api.go` is unchanged except for `GET /v1/graph`, which reports the C3
  lifecycle graph (AC3), and the board fields the run rows gained (AC2) — all of them report
  journal/queue/spool/graph state.
  - Verify: `go test ./cmd/chiefd/` — `TestTheUIRidesTheAPISPort` proves the page and its assets serve
    on the API's port and unknown paths answer through the API; `go test ./chief/` —
    `TestAPIIsTheWholeSurface` proves the endpoints serve the route, the correction, and the reports;
    `grep -n 'mux.Handle' control-plane/cmd/chiefd/web.go` shows only the page and its two assets.
- **AC2.** The board shows, per run: state, current phase, halt reason, retry budget, queue position,
  node, and runner type — every field from state, never prose. State, halt reason, and retry budget
  are the replayed rows (`control-plane/journal`, the C2 halt row); the current phase is the lifecycle
  vertex the run's latest C3 phase event names (`control-plane/spool`, the CDT-642 phase-event
  contract — an empty spool folds to an empty phase, never a guess); the queue position ranks a
  waiting runner among the C5 slot ledger's waiting slots (1-based, ledger order; a held slot queues
  no one); the node is the replayed owner — the node agent that holds the run; the runner type is the
  node's selection through the C4 loader (`agent.Load`, the node config's single reader — empty when
  the node has none).
  - Verify: `go test ./chief/` — `TestBoardCarriesStatePhaseHaltBudgetQueueNodeAndRunner` proves all
    seven fields over the API, including the empty-phase fold and the waiting rank.
- **AC3.** The C3 lifecycle graph is drawn from the graph JSON, with the run's current position marked.
  `GET /v1/graph` serves the committed graph (`docs/internal/control-plane/lifecycle-graph.json`)
  through `control-plane/lifecycle` — the loader validates it once and the API serves the validated
  data, never a second copy. The page draws the vertices and edges from that JSON (layout computed in
  the page from the `order` fields; the file carries no coordinate, colour, or style field), and marks
  the run's current position: the run-state vertex the run's `state` names, outlined, and the run's
  phase vertex (AC2), filled.
  - Verify: `go test ./chief/` — `TestGraphEndpointServesTheLifecycleJSON` proves the endpoint serves
    the committed graph's identity and vertex set; `go test ./cmd/chiefd/` — `TestTheUIRidesTheAPISPort`
    proves the page rides the same port.
- **AC4.** A routine run is started, steered, and closed from the UI with no terminal tab. The proof
  rides the C6 steer E2E seam: the route starts the run, the correction reaches the running session at
  its next step boundary, and the run closes to its terminal state — every step over the HTTP
  endpoints the UI drives, never a Go call into the Chief and never a second path.
  - Verify: `go test ./chief/` — `TestABoardRunIsStartedSteeredAndClosedFromTheUI` proves the
    route → steer → close routine end-to-end over the API.
- **AC5.** Every existing Surface still works standalone in a terminal — one check per Surface, after
  this child lands. The check is hermetic per Surface: the defect route still names `commands/debug.md`,
  the idea route still names `skills/brainstorm/SKILL.md`, and the epic route still names
  `commands/epic.md` — each file exists at the checkout and still carries its own Surface frontmatter
  (it is a terminal command/skill on its own), and the Chief's closed route set names those files, so
  the UI added no copy of any Surface and no endpoint of its own.
  - Verify: `go test ./chief/` — `TestSurfacesStillWorkStandaloneInTheTerminal` runs one subtest per
    Surface (defect, idea, epic).
- **AC6.** Loopback only: no exposed port and no access layer — remote access is CDT-630's phase-3
  scope. chiefd binds 127.0.0.1 by default and refuses a non-loopback listen address with a typed
  error (`errNotLoopback`) before anything binds; there is no TLS, tunnel, or access-layer code.
  - Verify: `go test ./cmd/chiefd/` — `TestNonLoopbackBindIsRefused` proves the typed refusal for
    `0.0.0.0`, a bare port, a LAN address, a name that does not resolve to loopback, and a malformed
    address, and accepts `127.0.0.1`, `localhost`, and `[::1]`; `TestRunRefusesANonLoopbackAddr` proves
    the exit.
- **AC7.** Ships `2.0.0-pre.N`; never patch, minor, major, or `2.0.0` — the release is the epic fold
  done by the orchestrator later, so C10's commits touch no version pair
  (`.claude-plugin/plugin.json` and `CHANGELOG.md` are untouched).
  - Verify: `git diff --name-only c85338b..HEAD` lists no `plugin.json` or `CHANGELOG.md` change.

## Ship gate (CDT-645)

On the Grok nest at depth 1 the M14 ship-gate council defers to the parent walker (SPEC-033 M14(l)): the child run prints `needs-parent-M14 SHA=<head> branch=<branch>` at Step 11 Stage 2 and returns; the parent runs M14 at depth 0, then the Stage 3 end-state `/release 2.0.0-pre.3`.
