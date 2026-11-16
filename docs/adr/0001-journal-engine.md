# ADR 0001: The journal engine is SQLite behind a narrow interface

> Origin: CDT-632 T-01 (AC10), control plane phase 0 of control plane Option C+ (CDT-626).
> The maintainer ruled this decision; this file records it, it does not propose it.
> Evidence is dated. The probe record is CDT-627 (`docs/internal/control-plane/`, probes run
> 2026-11-15, shipped as `v2.0.0-pre.1`); the engine deployment facts are vendor-primary
> docs accessed 2026-11-15. House style: the verdict-record shape of
> `docs/adr/SPEC-002-stanza-irreducibility.md` — dated measurements, and
> REJECTED-WITH-MECHANISM verdicts that name the failure mechanism, not the preference.

## Decision register

| Field | Value |
|---|---|
| Decision | The control plane journal runs on **SQLite behind a narrow interface** (files + CLI calls only). The durable-execution engine (Temporal / Restate) is **rejected** — see § Rejected. |
| Status | decided (2026-11-15). Closes the CDT-632 AC10 open question. No superseded record. |
| Date | 2026-11-15 |
| Sources | CDT-627 probe record: `host-capability-matrix.md:22,29-39,165-172,427`, `container-runner.md:97,108`, `native-runner.md:25-27,143-163,189-213`, `credentials.md:57-58`, `index.md` § AC-10 guard. Specs: SPEC-033 AC6/M13 (frozen decision-card schema, card path), SPEC-040 M20/M22 + AC11 (append-only journal, `.gitignore` MUST, intent-then-outcome, re-run skip), SPEC-004 (memory semantics, `schema.sql` DDL home), SPEC-010 (arc version). Live host measurement 2026-11-15: `$MROOT/.claude/memory/memory.db` = 3,743 rows, 11 writer agents, 619 `distillation_log` rows, 15,314,944 B, span 2026-10-08 → 2026-11-15, host `sqlite3` 3.53.4. Vendor: docs.temporal.io/self-hosted-guide/deployment, docs.temporal.io/workers, docs.restate.dev/server/overview.md (all accessed 2026-11-15). |
| Phase effect | Phase 1 (CDT-628) builds the journal on this engine and writes the crash-recovery code this choice puts in its hands (§ Consequences, cost 1). Phase 1 (CDT-626 runner image) carries the `sqlite3` package decision. No new container image, so this ticket files no G-02 image-approval request (OQ-12). Phases 2-4 inherit the boundary: files + CLI calls only. |
| Residual items | The exact journal path, table DDL, and CLI names are phase-1 (CDT-628) work; this ADR fixes the shape, not the names. The phase-1 kill test (SIGKILL mid-run, then forced reboot) is the acceptance gate that falsifies cost 1. Restate is the named re-evaluation candidate if that test fails (§ Rejected, R2 concession). |

## Status

**Decided — 2026-11-15.** The engine is SQLite behind a narrow interface. This record is the
single anti-relitigation record for the journal engine: phase 1 (CDT-628) reads it and never
re-argues it (§ Anti-relitigation clause).

## Context

CDT-626 gives the control plane one job: survive the failure that host CLIs cannot. Today a host
CLI process is a direct child of the invoking shell — when the shell dies, the work dies. The
CDT-627 record quotes the goal verbatim (`native-runner.md:189`): "after a forced reboot, every
in-flight run continues without a human", and records that no supervisor unit tracks host CLI
processes on this machine (probe 2026-11-15: `systemctl --user list-units` returned only
`dbus-broker.service`).

The **journal** is the run-state record the control plane rebuilds from: one row per run, per
lifecycle transition, per queue position, per Steer delivery. It is not the decision-card ledger
and not agent memory. The design comes from control plane Option C+ (CDT-626), and
phase 0 fixes its engine before phase 1 builds on it. Three facts constrain the engine choice:

1. **The journal is written at a human-adjacent rate.** A run is capped at 25 stints / 45 minutes
   of wall clock (SPEC-033 AC3/M9), and cards are written at three gates
   (`scope-confirm | plan-approve | ship-choice`, SPEC-033 M5). The write rate is events per
   minutes, not per second. Concurrency is not the constraint at this scale.
2. **The plugin is a pure markdown/JSON plugin with no build step** (AGENTS.md § Code
   Conventions). Anything that needs compiled application code, a worker, or a service changes
   what this product is.
3. **The plugin already operates SQLite.** Measured 2026-11-15: 82 files under `skills/`,
   `commands/`, `agents/` reference `sqlite3`; `$MROOT/.claude/memory/memory.db` carries 3,743
   rows written by 11 agents over 2026-10-08 → 2026-11-15 with no recovery tooling; the write
   path is one subprocess with a busy timeout and FKs on
   (`skills/memory-store/memdb.sh:35` — `sqlite3 -bail -cmd ".timeout 5000" -cmd "PRAGMA foreign_keys=ON"`);
   the DDL home is one file (`skills/memory-store/schema.sql`, SPEC-004 version history
   2026-06-15). The CDT-627 probes add the cross-process proof: omp's credential store is a
   SQLite file, and its rows prove "a month of separate omp processes reused the same stored
   credentials" (`credentials.md:58`, span 2026-10-07 → 2026-11-02).

**The kill test** is the criterion that decides it, and it is two tests. (K1) `kill -9` the
runner mid-run, then resume: reproduced on 2026-11-15 as P-CC-A — `kill -9 45688`, then
`claude -p --resume <session-id>`; "The resumed session answered `47` — the fact planted in the
killed session" (`host-capability-matrix.md:29-39`). Note what that proves: durable state in a
file plus a resume path recovers work, and the state was the *host's* file, not a daemon's.
(K2) forced reboot of the node, every in-flight run continues. K2 is unreproduced today; the
node agent does not exist yet and `loginctl show-user 1000 -p Linger` → `Linger=no`
(`native-runner.md:189`).

**The four criteria** are fixed by AC10: durability, kill-test compatibility, ops cost, and new
container image count as an integer. The G-02 gate prices the last one: every candidate image
needs one consolidated maintainer approval with evidence and a digest pin before any probe or
build starts (`index.md` § AC-10 guard). CDT-627 paid that gate for exactly two images
(`host-capability-matrix.md:427`, `node-agent-build-probe.md:22`) — that is the unit of cost.

## Decision

**The journal engine is SQLite, reached through a narrow interface: the control plane talks to the
plugin through files and CLI calls only.** The scored comparison:

| Criterion | Option 1 — SQLite behind a narrow interface | Option 2 — durable-execution engine (Temporal / Restate) |
|---|---|---|
| Durability (3 = strongest) | **3** — commit is fsync'd into a single file the plugin already runs in production: 3,743 rows / 38 days / 11 writers, zero recovery tooling, measured 2026-11-15; cross-process proof at `credentials.md:58`. Temporal's durability is delegated to its store (PostgreSQL in the default compose), so it is equal, not better. | **3** — Restate single-node is the vendor's strongest claim: it "fsyncs committed data to disk before acknowledging network messages, providing the highest level of durability" (docs.restate.dev/server/overview.md, accessed 2026-11-15). Conceded: a tie is the honest score. |
| Kill-test compatibility (3 = strongest) | **2** — K1 is the reproduced pattern: state in a file + a resume path (`host-capability-matrix.md:39`). K2 is not free: the crash window between a journal write and its side effect is ours to close with an intent-then-outcome record (the SPEC-040 AC11 precedent: "intent record is written before the side effect") plus the reconciler-on-start and one-owner-per-run lease CDT-626 already names (`native-runner.md:25-27`). Phase 1 writes and tests that code. | **3** — crash recovery is the product. "Workers are stateless, so any Workflow Execution in a blocked state can be safely removed from a Worker. Later on, it can be resurrected on the same or different Worker when the need arises" (docs.temporal.io/workers, accessed 2026-11-15): the server re-drives the execution with no application recovery code. This criterion is the engine's win, and the decision pays it rather than buys it. |
| Ops cost (3 = cheapest) | **3** — zero services, zero daemons, zero ports, zero backups beyond one file per project. Named cost: the runner image must ship the `sqlite3` **package**. `container-runner.md:108` reproduces `bash: line 1: sqlite3: command not found`, and `host-capability-matrix.md:165-172` (P-CON-M) proves mounting the host binary is not the fix (`libreadline.so.8: cannot open shared object file`). That is a CDT-626 runner-image package decision, already on its list. | **0** — a second stateful service per deployment: install, back up, upgrade, secure. Temporal needs manual schema updates through `temporalio/admin-tools` and sequential server upgrades, and its docs require hosts "not accessible from the public internet, with network configurations that restrict access to trusted internal networks" (deployment page, accessed 2026-11-15). Restate needs a persistent volume, and recommends the Kubernetes operator with a managed provider for production. None of that fits three nodes (WSL2, DGX Spark, Mac). |
| New container images (integer) | **0** | Temporal **3** (default Docker Compose: `temporalio/server` + PostgreSQL + Elasticsearch; **5** counting `temporalio/ui` and `temporalio/admin-tools`, which the same page names). Restate **1**. |

Totals on the three scored criteria: Option 1 = 8/9, Option 2 = 6/9. The engine wins the one
criterion that costs code (kill test) and loses the one that costs an operational footprint
(ops cost + images) on every machine in scope. The decision buys the cheaper loss: phase 1 writes
a reconciler; it does not adopt, secure, back up, and upgrade a service on three nodes.

### The narrow-interface boundary

The boundary is a rule, not a layer. **The control plane talks to the plugin through files and CLI
calls only.** Concretely:

- **Files it reads:** the decision-card ledger `$MROOT/.claude/autopilot/<TICKET-ID>.jsonl`
  (SPEC-033 M13), the sweeps journal `$MROOT/.claude/sweeps/<slug>.jsonl` (SPEC-040 M20), the
  journal file, and the host transcripts the matrix names as session-id sources
  (`host-capability-matrix.md:628` — `~/.claude/projects/<cwd-slug>/<session-id>.jsonl`; omp
  `~/.omp/agent/sessions/…`, indexed in `agent.db`). The container Runner mounts the worktree at
  the same absolute path (`container-runner.md` Fact 3), so a path is portable across runner types.
- **CLI calls it makes:** the plugin's own surfaces through a headless host CLI, and two journal
  commands — one append, one read. The ADR fixes the shape; names are phase 1: argv/env inputs
  only, never interpolated code (AGENTS.md untrusted-input rule), NDJSON on stdout, exit 0 on
  success and 64 on usage error, one subprocess per call, busy timeout set on every open (the
  `memdb.sh:35` pattern).
- **What is banned:** the control plane never opens the journal database with its own SQL, never
  imports a plugin library, never shares a process with the plugin, and never requires the plugin
  to call a control-plane daemon. There is no IPC protocol, no socket, no gRPC frontend, and no
  worker. A plugin surface with no control plane present behaves byte-identically — the opt-in
  precedent is SPEC-039 M11 ("Byte-identical off": flag absent and env unset → no behavior
  change).

This boundary is what an engine cannot cross: a durable-execution engine reaches application code
through a worker SDK, so the caller becomes the engine. See § Rejected, R1(a).

### The journal references decision-cards; it never changes them

- The journal **REFERENCES** decision-cards. A journal row carries a card reference — the card
  path plus its `ts` and `run_id` — and never a copy of a card field. The card stays the sole
  record of a gate answer; the journal stays the sole record of run position.
- The journal **MUST NOT change the frozen decision-card schema** (SPEC-033 AC6/M13). `type`
  (const `"autopilot_decision"`) plus `schema_version` is the stable discriminator envelope, and
  `schema_version` stays `1`. The additive-nullable precedent is fixed there: `council_tier`,
  `grading_reason`, `max_loc`, and `advisor` each kept `schema_version` at 1 with absent key ≡
  `null`. The journal adds no key to a card, needs no `schema_version` bump, and MUST NOT be
  cited as a reason to bump one. `skills/autopilot/append-card.sh` and
  `skills/autopilot/read-cards.sh` stay the only card writer and reader.
- The journal is **git-ignored**. It mirrors two standing invariants: `.claude/autopilot/` is not
  committed (SPEC-033 M13; `.gitignore:35`) and `.gitignore` MUST list `.claude/sweeps/`
  (SPEC-040 M20; `.gitignore:9`). Phase 1 adds the journal path to `.gitignore` in the same commit
  that creates the path.
- The journal is **never in `memory.db`** (SPEC-033 M13 states the same prohibition for cards).
  `memory.db` is agent memory under SPEC-004 semantics — tiers, distillation, embeddings — at
  `$MROOT`, shared across worktrees. Run state is not memory: it is not distilled, not embedded,
  and not read by an agent's session-start load. Co-locating them would put run state in every
  `/memory distill` and `/memory recall` surface.

## Consequences

**Gained.**

- 0 new container images. CDT-632 files no G-02 image-approval request (OQ-12), and phase 0 stays
  docs-only: no pull, no build, no service.
- The plugin keeps its shape: no build step, no compiled application code, no daemon. The
  control plane is a Go binary in phase 1 (CDT-626, `node-agent-build-probe.md`); SQLite needs an
  embedded driver in that same binary, not a partner service.
- The engine, the write discipline, and the DDL-home pattern already exist and are load-tested by
  real use (3,743 rows / 38 days), so phase 1 extends a proven pattern rather than adopting a
  foreign one.
- Local-first by construction: every plugin Surface works with no control plane, because the
  journal is a file the plugin owns.

**Paid — costs this decision accepts.**

1. **Phase 1 owns crash recovery.** The engine's replay is the one thing SQLite does not give.
   Phase 1 (CDT-628) writes the intent-then-outcome record (SPEC-040 AC11 pattern), the
   one-owner-per-run lease, and the reconciler-on-start (`native-runner.md:25-27`), and proves
   them on the kill test K1 + K2. This is the price of the decision, stated so nobody re-discovers
   it as a surprise.
2. **The runner image needs the `sqlite3` package.** Not an image — a package, already named on
   the CDT-626 runner-image list with the in-container failure reproduced (`container-runner.md:97,108`).
   Mounting the host binary fails on `libreadline.so.8` (P-CON-M): install the distro package in
   the image, do not mount.
3. **Single-writer discipline is ours.** SQLite serializes writers with a busy timeout, not a
   queue. The plugin's pattern is one short-lived writer per open
   (`memdb.sh:35`, `.timeout 5000`); phase 1 keeps writes short and never holds a transaction
   across a model call, a spawn, or a network round trip.
4. **Schema evolution is a migration file, not a product.** Mirror `skills/memory-store/schema.sql`
   (SPEC-004, 2026-06-15): one DDL home, numbered migrations beside it, journal rows append-only.

**Not changed.** The decision-card schema, SPEC-033 AC3 run-budget policy, SPEC-004 memory
semantics, the SPEC-040 sweeps journal, and the G-02 image-approval gate all stay as they are.

## Rejected

### R1 — Temporal (durable-execution engine). Verdict: REJECTED-WITH-MECHANISM.

Five independent mechanisms; each one alone is sufficient.

- **(a) It inverts the boundary.** A Temporal Service reaches application code through a worker
  (Go / Java / TypeScript SDK, docs.temporal.io/workers, accessed 2026-11-15), and that worker is
  not optional or host-side sugar: "Worker Processes are external to a Temporal Service. Temporal
  Application developers are responsible for developing Worker Programs and operating Worker
  Processes … the Temporal Service … doesn't execute any of your code (Workflow and Activity
  Definitions) on Temporal Service machines" (same page). So each node needs a long-lived compiled
  worker process, and the plugin — markdown a host CLI reads — would be called from inside it.
  The workflow definition must be executable code the service can replay, so the lifecycle graph
  would live in the engine. That is the exact opposite of "the control plane talks to the plugin
  through files and CLI calls only", and it breaks the no-build-step fact (Context 2). The engine's
  replay requirement makes it worse: workflow code must be deterministic, with every side effect
  behind an activity, so the plugin's LLM gates would need an activity wrapper per call, while the
  answer each gate produces is *already* journaled as a decision-card. Replay adds no durability
  the card ledger does not already carry.
- **(b) It forks the source of truth.** The lifecycle graph, the guarded transitions, and the
  eight blocking conditions live in `skills/` + SPEC-033 and are written to cards
  (SPEC-033 M5/M6/M13). A Temporal workflow re-hosts that same state machine in code. Two owners
  of one graph is the defect SPEC-033 M12 exists to prevent.
- **(c) It costs 3 images and a stateful store.** The default Docker Compose stack is
  `temporalio/server` + PostgreSQL + Elasticsearch, plus `temporalio/admin-tools` for the manual
  schema updates and the UI image (deployment page, accessed 2026-11-15): **3** new images, 5 with
  the UI and admin-tools. Each needs the G-02 consolidated approval with evidence and a digest
  pin (`index.md` § AC-10 guard), and the store needs backups and sequential server upgrades. The
  single-binary `temporal server start-dev` is a development server by vendor label — not a
  production journal.
- **(d) It wants a network posture phase 0 does not have.** Temporal hosts "should run on hosts
  that are not accessible from the public internet, with network configurations that restrict
  access to trusted internal networks only", secured "similarly to a database" (same page). Phase
  3 (CDT-630) is about safely exposing the Chief's UI; adopting Temporal adds a second, harder
  exposure surface to design around, on a WSL2 node, a DGX Spark, and a Mac.
- **(e) Its journal payload is readable at rest by default.** "While data transferred in Event
  Histories is secured by mTLS, by default, it is still readable at rest in the Temporal Service",
  and the fix is a custom Data Converter (docs.temporal.io/workers, accessed 2026-11-15). Run
  state, gate rationales, and ticket ids all land in that history. The plugin's standing rule is
  the opposite posture at a smaller radius: paths and key names only, never secret values
  (CDT-627 AC-9, `credentials.md`), inside `$MROOT`, with the SQLite file in the same git-ignored,
  local-only boundary as the decision-cards (SPEC-033 M13). Matching the at-rest posture inside an
  engine costs a codec layer; the embedded engine needs none.

### R2 — Restate (durable-execution engine). Verdict: REJECTED-WITH-MECHANISM, with a concession.

- **Concession, recorded rather than hidden.** Restate is the cheapest and the strongest engine
  here: **1** new image, a single binary that "implements all features required to run a single-
  or multi-node cluster", and single-node durability the vendor calls the highest level, because
  it fsyncs before acknowledging (docs.restate.dev/server/overview.md, accessed 2026-11-15). It
  beats the SQLite journal on kill-test compatibility (3 vs 2) and there is no honest score that
  says otherwise.
- **Mechanism 1 — same inversion as R1(a).** Restate services are code behind inbound HTTP; the
  orchestration lives in the engine's journal, not in `skills/`.
- **Mechanism 2 — the deployment shape does not fit.** Single-node durability requires a persistent
  volume, and the vendor recommends the Kubernetes operator on a managed provider
  (EKS/AKS/GKE) for production. The deployment target is three machines the maintainer owns, one
  of them WSL2 with `Linger=no`. A Kubernetes cluster is not a smaller problem than a reconciler.

**Named re-open path (not a re-argument).** If phase 1 fails the kill test K2 on this
architecture — the reconciler + lease + intent-then-outcome pattern cannot deliver "after a forced
reboot, every in-flight run continues without a human" — Restate is the first candidate to
re-evaluate, and the failure is proven by a reproduced K2 record, not by argument. See
§ Anti-relitigation clause.

### R3 — Server RDBMS (PostgreSQL / MariaDB) as the journal store. Verdict: REJECTED-WITH-MECHANISM.

**1** new image, and durability equal to SQLite's at this write rate. Mechanism: it buys nothing
over the embedded engine, because the constraint it solves — writer contention — is not
operative. A run is capped at 25 stints / 45 minutes (SPEC-033 AC3/M9) and writes at three gates
(M5), so writes are minutes apart; the plugin's existing single-file pattern sustains 3,743 rows
across 11 writer agents in 38 days with a 5 s busy timeout and no recorded lock loss (measured
2026-11-15). A server adds a network hop, a port, credentials, and a backup job to fix a
non-problem.

### R4 — Append-only JSONL with no query engine (the decision-card / sweeps precedent, extended). Verdict: REJECTED-WITH-MECHANISM.

Mechanism: the read shapes differ. The SPEC-040 journal works because its read is a point lookup
by slug — a record with a terminal `outcome` at or after the tag baseline is skipped (SPEC-040
M22/AC13), which is one file, one open. The control plane's reads are cross-run set queries: list
every in-flight run on a node, order the queue, join run → ticket → gate, render the Chief's
status surface on each poll. A per-run file forest answers each poll with a scan of every file
plus a parse of every line, and the status poll is the hottest read path in the product. SQLite
answers the same query with an indexed read and keeps the append-only write discipline that
SPEC-033 M13 and SPEC-040 M20 already require.

## Anti-relitigation clause

This file is the single anti-relitigation record for the journal engine. Phase 1 (CDT-628) of
control plane Option C+ (CDT-626), and every later phase, **read it and never re-argue it**.

A future ticket that proposes a different journal engine — a durable-execution engine, a server
RDBMS, JSONL-only, or a second database beside SQLite — MUST do all three of these before it
re-derives any reasoning here:

1. **Read § Rejected** (R1-R4) and the two specs it leans on: SPEC-033 AC6/M13 (frozen card
   schema) and SPEC-040 M20/M22 + AC11 (journal precedent).
2. **Bring new dated evidence, of a kind this record does not contain.** New means: a reproduced
   kill-test failure (K1 or K2) of the SQLite journal plus reconciler on a real node, with the
   command and output; an integer count of new container images with a G-02 approval path; and a
   named owner for the added service's backup, upgrade, and security posture on each node. The
   general claim "a durable-execution engine is more durable" is **not** new evidence — the score
   table above already concedes kill-test 3 vs 2 and Restate's fsync-before-ack, so restating it
   re-argues a settled point.
3. **State what happens to the boundary.** Any proposal that reaches plugin code through a worker,
   a daemon, a socket, or a shared process must say how "files and CLI calls only" survives it, and
   how the plugin stays byte-identical with no control plane present. An answer that keeps a
   control-plane daemon in the loop fails this ADR on its face.

The dated counts here (3,743 rows, 82 files, 2 G-02-approved images, the image integers) are
measurements at their stated dates, re-derivable by the commands cited — not contracts. The
mechanisms, the boundary, the frozen-schema rule, and the verdicts are the standing parts.
