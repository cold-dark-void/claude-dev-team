# Close-out — control plane phase 0 written decisions

Carries AC17 (CDT-632) for the control plane Option C+ (CDT-626). This file closes the phase-0
decision set. It decides nothing new: it records what the five decision records decide, what stays
blocked, and what each later phase inherits. The file ends with § Decisions that unblock.

## Decision register

| Field | Value |
|---|---|
| **Decision** | Phase 0 of control plane Option C+ (CDT-626) is closed as a written decision set: the six deliverables in § Deliverable set. Each is a decision record with dated evidence, not a recommendation. The external copy of the record is audited from the repo (§ External copy record). |
| **Status** | Closed for phase 0 (2026-11-15). Docs-only: no product code, no gate change, no default-behavior change. `v2.0.0-pre.2` carries this set on the SPEC-010 arc (AC22, T-09). |
| **Date** | 2026-11-15 |
| **Sources** | The five decision records: [ADR 0001](../../adr/0001-journal-engine.md), [cloud-auth-and-exposure.md](cloud-auth-and-exposure.md), [run-budget.md](run-budget.md), [record-ownership.md](record-ownership.md), [memory-api.md](memory-api.md). The AC15 verify report (T-V, qa): `CONTEXT.md` 11/11 terms verbatim, Steer and Slot checked against the ruling, `CONTEXT.md` byte-identical to `6f81c22`. The four CDT-627 residuals: [index.md](index.md) § "Release readiness" (`index.md:271`). The external-copy ruling: the kickoff plan § OQ-3. Ticket titles and statuses for CDT-628, CDT-629, CDT-630, CDT-631 read from Linear on 2026-11-15 (all four Backlog). |
| **Phase effect** | None of its own. Each later phase inherits the rows of § Decisions that unblock, the four carried inputs of § CDT-627 residual phase-1 inputs, and the items of § Blocked items and § Defects recorded at close-out. |
| **Residual items** | B1–B9 (§ Blocked items); D-P2, D-P3a, D-P3b, D-P3c (§ Defects recorded at close-out); the external copy write itself, performed outside the repo (§ External copy record). |

## Deliverable set (the six AC18 paths)

| # | File | Carries | The decision, in one line |
|---|---|---|---|
| 1 | [`docs/adr/0001-journal-engine.md`](../../adr/0001-journal-engine.md) | AC10 | The journal engine is SQLite behind a narrow interface (files + CLI calls only); the durable-execution engine is rejected with its mechanism. |
| 2 | [`cloud-auth-and-exposure.md`](cloud-auth-and-exposure.md) | AC11 | Per-host cloud auth: Claude Code / Grok / omp = both, mini-swe = api-key; the access layer is Cloudflare Access in front of a Cloudflare Tunnel; the tunnel token is a node-side `0600` secret read through `EnvironmentFile=`. |
| 3 | [`run-budget.md`](run-budget.md) | AC12 | Scale the run budget with the two existing SPEC-033 env caps only, chosen from a per-model proposal table; propose env-only scaling and fork no policy. |
| 4 | [`record-ownership.md`](record-ownership.md) | AC13 | All eleven plugin state records stay plugin-owned, each with one writer and one conflict rule from a closed set of five. |
| 5 | [`memory-api.md`](memory-api.md) | AC14 | Memory has one interface (store, recall, distill) and two backends (file, API); presence is one config key plus one env marker; the merge is LWW per (agent, type, key) by ts; no schema fork. |
| 6 | [`close-out.md`](close-out.md) | AC17 | This file. |

AC15 is verify-only and touches no file here: the eleven glossary terms are committed at `6f81c22`
in `CONTEXT.md`. `docs/internal/control-plane/index.md` pins these six paths and carries the File
map and Status updates (AC18, T-07).

## External copy record (OQ-3)

The ruling: the external copy of the phase-0 record lives in Linear, and the repo proves the copy
happened. This section is that proof.

| Field | Value |
|---|---|
| Destination | Linear project document "Control plane: brainstorm record (2026-11-11)" |
| Link | <https://linear.app/cold-dark-void/document/control-plane-brainstorm-record-2026-11-11-1acc77afc881> |
| Date recorded | 2026-11-15 |
| Copy content | The CDT-632 written decision set: the six paths of § Deliverable set, plus this close-out's blocked list and the decisions-that-unblock rows. |
| Copy performed | Outside the repo, at close-out, 2026-11-15. The write is not part of this diff; this section is the audit record that names destination, date, and link. |
| Source of truth | The repo. The Linear document is the readable mirror. |

- If the mirror and the repo disagree, the repo wins. Re-copy from the repo files.
- A ticket that amends a decision recorded here re-copies the changed section and appends one dated
  line to the table above. Do not edit an existing row.
- Never place a secret, token, or credential value in the mirror. It carries paths and variable
  names only (the standing rule in `cloud-auth-and-exposure.md` § Tunnel-token storage and
  `memory-api.md` R3).

## CDT-627 residual phase-1 inputs (four, carried forward)

Source, verbatim from `index.md:271`: "Residual items for later tickets, none blocking:
`loginctl enable-linger` (phase 1, machine change), the omp native env-var-name probe, the forced
token-refresh probe (needs a sandbox credential), and the CDT-632 written decisions." The fourth is
what this ticket closes. The first three carry forward, plus the Slot question the glossary keeps
open.

| # | Input | Status at close-out | Owner |
|---|---|---|---|
| 1 | `loginctl enable-linger` on the node | Not done — a machine change, out of phase-0 scope. Linger is `no` today, so the user manager and its systemd user units die with the login session, and "after a forced reboot, every in-flight run continues without a human" cannot hold. Evidence: `native-runner.md:185-190`. | CDT-628 (operator step, phase 1). Tracked as B8. |
| 2 | omp native env-var-name probe | Doc side closed, on-box side open. <https://omp.sh/docs/env> names the resolution order (`ANTHROPIC_OAUTH_TOKEN` → `ANTHROPIC_API_KEY`, `XAI_OAUTH_TOKEN` → `XAI_API_KEY`, `LLAMA_CPP_API_KEY`); the local store probe does not prove the path on a node. Evidence: `credentials.md` gap 2. | CDT-628 host-adapter work. Tracked as B7. |
| 3 | Forced token-refresh probe (Claude Code, Grok) | Not run by design — a forced refresh rotates the operator's live subscription credential, so both carry the conservative writable-mount rule. Evidence: `container-runner.md:34-37`, `:39-43`. | Needs a sandbox credential first. Tracked as B6; feeds CDT-631. |
| 4 | Slot open question: slot per runner or per model endpoint | Open by ruling (OQ-4). `CONTEXT.md` keeps "one slot is one runner" as the term and names the per-model-endpoint variant as the open question. | CDT-628 decides it with the queue; the term is amended only by a real ruling. |

## Blocked items (AC11, from T-02)

Nine items. Each is the honest output of phase 0, not a failure, and each names what it needs.
Quoted verbatim from `cloud-auth-and-exposure.md` § Blocked items.

| # | Blocked item | Needs | Phase |
|---|---|---|---|
| B1 | `blocked: no cloud VM exists in phase 0 — subscription-login and api-key injection on cloud compute are documented, not measured; a phase-4 node probe is needed.` | A cloud node. Every cloud verdict in the auth grid is doc-only while this stands. | 4 (CDT-631) |
| B2 | `blocked: a public web vendor URL for the Grok CLI auth docs — the docs ship inside the CLI (~/.grok/docs/user-guide/02-authentication.md, 14-headless-mode.md); no public vendor page for the CLI auth flow was verified on 2026-11-15.` | A public vendor web page, verified. The bundled CLI docs are the current primary source. | 3–4 |
| B3 | `blocked: mini-swe subscription-login — no vendor-primary statement that LiteLLM subscription/plan auth (non-API-key) is supported by mini.` | A vendor-primary statement. The row stays api-key. | 4 |
| B4 | `blocked: the on-disk path where "cloudflared service install <TOKEN>" stores the token — not stated in the vendor page; needs a node probe in phase 3.` | A node probe in phase 3. | 3 (CDT-630) |
| B5 | `blocked: the "cloudflared tunnel token --cred-file" flag form — no primary Cloudflare doc verified on 2026-11-15.` | A primary Cloudflare doc. Community answers are not a primary source. | 3 |
| B6 | `blocked: forced token-refresh on a mounted credential for Claude Code and Grok — a forced refresh rotates the operator's live credential; a sandbox credential is needed (carried: container-runner.md:34-37 and :39-43).` | A sandbox credential. | 3–4 |
| B7 | `blocked: on-box proof of which omp provider env-var name each provider reads — the vendor doc names the names; the local store probe does not prove the resolution path (credentials.md gap 2).` | An on-box probe on a node. An adapter must not guess names. | 1 → 4 |
| B8 | `blocked: loginctl enable-linger on the node — a machine change, out of phase-0 scope (CDT-627 residual, index.md:271).` | The operator's machine change in phase 1. | 1 (CDT-628) |
| B9 | `blocked: the Cloudflare Access plan, the identity provider, and the hostname — all need the operator's Cloudflare account, which phase 0 does not have.` | The operator's Cloudflare account, plan choice, IdP, and hostname. | 3 |

Every `blocked:` cell that sits inside `cloud-auth-and-exposure.md` maps to one of these: the Grok
public-URL cell (`:30`) is B2, the mini-swe subscription cell (`:32`) is B3, and the two
tunnel-token cells (`:96`, `:97`) are B4 and B5. The other four decision records carry no
`blocked:` line — each states its open work as Residual items instead, and § Decisions that unblock
names the owner of each.

## Defects recorded at close-out (from T-V, AC15)

T-V was verify-only: it changed no file. These are its findings and their owners.

- **D-P2 (P2) — stale probe-record pointers in `host-capability-matrix.md`.** The T-11 adjudication
  rows point at the wrong line ranges for the native Runner: `:604` cites the Grok native probe at
  `259-278`, which is the Grok **container** transcripts; the true record is `:514-535`. `:605`
  cites the omp native probe at `280-300`; the true record is `:541-561`. The Claude Code row
  carries an extra stale pointer, `probe record :302`; the CC native record is `:58-71`. The three
  container rows (`112-126`, `295-317`, `563-587`) are correct. The verdicts are unaffected — the
  six probes and their readings stand. This is a CDT-627 shipped-doc defect: fixing it is outside
  CDT-632's write scope (the T-V ruling is verify-only). Fix owner: the next CDT-627-touching
  change, or a follow-up ticket. The corrected pointers are above; the fix is a three-cell edit in
  one table.
- **D-P3a (P3) — AC20's verify line needs a self-reference exemption.** The guard greps the diff for
  the bare form of the citation; `index.md` cites the rule text itself, so the rule's own two hits
  match. T-08 records them as sanctioned self-references rather than failing the gate.
- **D-P3b (P3) — `CONTEXT.md:53` comma form.** The Control plane term cites CDT-626 with a comma
  after the plus sign instead of the canonical parenthesized form, because the term sits inside a
  table cell and the parentheses would nest. It passes the bare-form grep and deviates from AC20's
  canonical string. This bullet names the line and does not reproduce the string, so this file adds
  no hit that T-08 must waive. Ruled a sanctioned deviation: the glossary is committed at `6f81c22`
  and AC15 is verify-only.
- **D-P3c (P3) — AC15's cell-level reading.** The AC says the Steer entry cites the six probes; the
  citation sits in the `CONTEXT.md` Decisions bullet (`:82`), not in the Steer term cell (`:59`).
  The content is satisfied and traceable to the T-11 block. A strict cell-level reading is a PM
  ruling, not a rewrite.

## Verification (AC17)

```bash
cd docs/internal/control-plane
grep -c 'CDT-628\|CDT-629\|CDT-630\|CDT-631' close-out.md       # 13 — all four phase tickets
grep -c 'enable-linger\|env-var-name\|token-refresh\|per model endpoint' close-out.md   # 11
grep -n 'linear.app/cold-dark-void/document/control-plane-brainstorm-record-2026-11-11' close-out.md
grep -c '^| B[1-9] | `blocked:' close-out.md                     # 9 — B1–B9 verbatim
for b in B1 B2 B3 B4 B5 B6 B7 B8 B9; do grep -q "^| $b |" close-out.md || echo "missing $b"; done
[ "$(grep '^## ' close-out.md | tail -1)" = '## Decisions that unblock' ] && echo "ends-with-unblock-section"
```

Expected: the four ticket ids present (13 lines mention at least one); the four CDT-627 residuals
present (11 lines match at least one pattern); destination + date + link recorded; nine B-rows,
each quoting its `blocked:` text; no missing id; the unblock section is the last `##` section.

## Decisions that unblock

Each row names the phase-0 decisions that let that ticket start, from the five decision records on
this branch, and the open items that ticket must carry. `none` means nothing in phase 0 blocks it.

| Phase ticket | Decisions that unblock it | Open items it must carry |
|---|---|---|
| **CDT-628** — phase 1 core (run state machine, queue, host adapter, Chief, web UI) | ADR 0001 fixes the journal engine (SQLite) and the boundary (files + CLI calls only, journal REFERENCES decision-cards, frozen SPEC-033 AC6/M13 schema, git-ignored, never in `memory.db`); `record-ownership.md` assigns all eleven plugin records one owner and one closed-set conflict rule and reserves `control-plane-only` for the journal, whose path and DDL CDT-628 owns; `host-capability-matrix.md` AC-3/AC-4 give the host-adapter contract (Steer confirmed by six probes, resume path named per host); `run-budget.md` proposes the env-only scaling shape. | The Slot ruling (per runner vs per model endpoint, OQ-4); the SPEC-033 amendment inputs in `run-budget.md` § Deferral (precedence insert, ceiling amendment, per-Run aggregation rule, slug-stable match key, N12 stays); CDT-610 before any wall-clock tuning; B8 (linger) as an operator step; the row-5 memory owner is re-tested when CDT-629 lands; the journal's phase-1 kill test is the gate that falsifies ADR 0001 cost 1. |
| **CDT-629** — phase 2 scale (self-balancing slots, multiple projects, tracker views; centralized memory build) | `memory-api.md` D1–D6: three operations, each behind `require-agent.sh --memory`; two backends, one interface, one writer per backend; presence = config key `control_plane_url` (`$MROOT/.claude/dev-team/config.json`) + env marker `CONTROL_PLANE_URL`, env wins; plane-down = write the `.md` path (read-only rejected); merge = LWW per (agent, type, key) by ts, append-only, conflicts queue surfaced to the Chief; no schema fork (`schema_version` stays 4, transport fields ride `metadata_json`). | The node-agent CLI path and flag names; the `.gitignore` line for `config.json`; the SPEC-004 amendment for no-trim-while-degraded; the conflicts-queue path plus its writer (it enters `record-ownership.md` then); the Chief's recall scope across projects (one instance per project vs one switchable instance). |
| **CDT-630** — phase 3 remote access (cloudflared tunnel, mobile app, QR linking) | `cloud-auth-and-exposure.md` § Exposure names the access layer: Cloudflare Access as a self-hosted public-hostname application, deny-by-default, in front of a Cloudflare Tunnel, with the Access application and its Allow policy created **before** the tunnel route and `cloudflared` origin validation ("Protect with Access") required; § Tunnel-token storage fixes the node secret as an owner-only `0600` file outside the worktree, read through `EnvironmentFile=%h` in a systemd user unit, never in the repo, a ticket, a log line, a transcript, a decision-card, or a memory row, with the vendor rotation runbook named. | B4 (installer token path), B5 (`--cred-file` form), B9 (plan, IdP, hostname — needs the operator's Cloudflare account); B6 where a credential mount is involved; the IdP, session duration, and MFA choices, which are Access application settings. |
| **CDT-631** — phase 4 remote compute (cloud deployment, other machines as nodes) | `cloud-auth-and-exposure.md` § Compute in cloud fixes what a node inherits: the per-host auth grid (Claude Code both, Grok both, omp both, mini-swe api-key), the one-time operator steps per host, the writability rule from `container-runner.md` Fact 2, and the isolation rule (private `CLAUDE_CONFIG_DIR`, `$HOME`/`$GROK_HOME`, `~/.omp`; prefer the vendor remote-credential option); `memory-api.md` R1–R3 gate the phase (memory encrypted at rest, single-user boundary, no secrets in memory rows), and centralized memory is a precondition of remote nodes. | B1 (no cloud VM: every cloud verdict is doc-only until a node probe), B3 (mini-swe subscription login), B6 (forced token-refresh, needs a sandbox credential), B7 (on-box omp env-var resolution); the cloud provider, region, and account type (the Claude Bedrock / Agent Platform / Foundry route removes the browser-mint step); `claude self-hosted-runner` stays a recorded alternative, not the design. |
