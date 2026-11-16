# Control plane phase 0 — discovery index

Status: complete. Phase 0 discovery is done; the five child files are filled. T-12 ran the release gate on 2026-11-15 — see § "T-12 — Final review gate checklist" at the end of this file.

Status (CDT-632, added 2026-11-15): the phase-0 written decisions are also complete. § "CDT-632 — File map (written decisions)" pins the six deliverable paths. The CDT-627 sections in this file are unchanged.

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


## Ship gate (CDT-645)

On the Grok nest at depth 1 the M14 ship-gate council defers to the parent walker (SPEC-033 M14(l)): the child run prints `needs-parent-M14 SHA=<head> branch=<branch>` at Step 11 Stage 2 and returns; the parent runs M14 at depth 0, then the Stage 3 end-state `/release 2.0.0-pre.3`.
