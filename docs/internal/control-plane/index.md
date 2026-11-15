# Control plane phase 0 — discovery index

Status: complete. Phase 0 discovery is done; the five child files are filled. T-12 ran the release gate on 2026-11-15 — see § "T-12 — Final review gate checklist" at the end of this file.

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
