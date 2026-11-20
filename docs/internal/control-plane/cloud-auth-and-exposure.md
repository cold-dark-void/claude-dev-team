# Cloud auth and exposure

Carries AC11 (CDT-632) for the control plane Option C+ (CDT-626). Documentation-only: phase 0 has no cloud VM, so nothing here was probed on cloud compute. Every claim that needs a cloud VM reads `blocked:`. The split is per OQ-11: § Exposure (phase 3) and § Compute in cloud (phase 4).

## Decision register

| Field | Value |
|---|---|
| Decision | Per-host cloud auth: Claude Code 2.1.325 = **both**; Grok 1.0.77 = **both**; omp 18.7.0 = **both**; mini-swe v2.4.6 = **api-key**. The access layer that protects an exposed UI is **Cloudflare Access** (self-hosted public-hostname application, deny-by-default) in front of a **Cloudflare Tunnel** (`cloudflared`); build is phase 3 (CDT-630). Tunnel-token storage: the token is a node-side secret in an owner-only file, read into the node's systemd user unit through `EnvironmentFile=`; it never enters the repo, a ticket, a log line, or a memory row. |
| Status | Accepted for phase 0 — a written decision only. No build, no cloud VM, nothing exposed. |
| Date | 2026-11-15 |
| Sources | Vendor primary URLs in § Cloud auth grid, § Exposure (phase 3), and § Tunnel-token storage — every URL accessed 2026-11-15. In-repo evidence: `credentials.md` (AC-9 grid; gaps at :131-138), `host-capability-matrix.md:13` (Claude Code 2.1.325 version flag), `container-runner.md:30-56` (Fact 2, writable-mount need), `native-runner.md:64` (systemd user unit path). Local probes on 2026-11-15: `claude --version` → `2.1.325 (Claude Code)`, `claude --help` (`--bare` text). |
| Phase effect | Phase 3 (exposure, CDT-630) builds the named access layer and the tunnel-token storage on the node. Phase 4 (compute in cloud, CDT-631) inherits § Cloud auth grid plus the mounted-credential rules in `credentials.md`. No phase-0 product code, no gate change, no default-behavior change. |
| Residual items | § Blocked items (B1–B9) and § credentials.md residual gaps (G1–G4 with the count note). |

## Evidence rules for this file

- Every cell carries a vendor primary URL with an access date of 2026-11-15, or reads literally `blocked: <what is missing>`.
- In-repo probe evidence is cited as `file:line`. It describes this development machine (WSL2, host `malcolm-pc`), not cloud compute. Do not read it as a cloud verdict.
- Cited Claude Code version: **2.1.325** — the probed version (`host-capability-matrix.md:13`, re-confirmed by `claude --version` on 2026-11-15). The plan lock 2.1.322 is drift; `credentials.md` gap 3 records it.
- Secret values are never quoted here — paths, environment-variable names, and key names only.

## Cloud auth grid (AC11)

Verdict set: subscription-login | api-key | both | blocked. "Cloud VM" means a headless Linux VM with no browser and no keychain.

| Host (version) | Verdict | Subscription login on a cloud VM | API key on a cloud VM | Vendor primary source (accessed 2026-11-15) |
|---|---|---|---|---|
| Claude Code 2.1.325 | **both** | Supported by doc, unverified on cloud compute. Browser `/login` needs a browser. The headless path is `claude setup-token` → one-year OAuth token → `CLAUDE_CODE_OAUTH_TOKEN`; mint it on a browser-capable machine, then inject the variable. A mounted `~/.claude/.credentials.json` also authenticates (probed in a container, not on a VM: `credentials.md:85`). | Supported. `ANTHROPIC_API_KEY` (Claude Console key) or `apiKeyHelper` in `--settings` JSON. In `-p` mode the key is always used when present. Bedrock / Agent Platform (Vertex) / Foundry routes need "No browser login". | <https://code.claude.com/docs/en/authentication> (§ Log in, § Credential management, § Authentication precedence, § Generate a long-lived token); <https://code.claude.com/docs/en/headless#start-faster-with-bare-mode>; local `claude --version` / `claude --help`, 2026-11-15 |
| Grok 1.0.77 | **both** | Supported by doc, unverified on cloud compute. `grok login --device-auth` (alias `--device-code`) is the documented flow "For headless environments (SSH sessions, Docker containers, remote VMs) where no browser is available locally": it prints a URL and code, you open them on any device, Grok polls. The cached result lives in `~/.grok/auth.json`, mode `0600`. | Supported. `export XAI_API_KEY="xai-…"` from <https://console.x.ai>. The stored session token outranks the API key, so a node that must run on the key needs `grok logout` (vendor: "Grok uses the API key as a fallback when no session token is active"). | Bundled vendor CLI docs (shipped inside `grok 1.0.77`): `~/.grok/docs/user-guide/02-authentication.md` § Browser Login, § API Key, § Device Code Flow; `~/.grok/docs/user-guide/14-headless-mode.md:689-698` § Authentication for Headless Environments; <https://docs.x.ai/docs/overview> (`XAI_API_KEY` bearer auth). Public web vendor URL for the CLI auth doc: `blocked: a public web vendor page for the Grok CLI auth flow — the docs ship inside the CLI and no public vendor page was verified on 2026-11-15` (B2) |
| omp 18.7.0 | **both** | Supported by doc, unverified on cloud compute. `/login <provider>` runs "Browser, device-code, and hosted-account flows"; vendor: "For a remote terminal, the flow may ask you to paste the final redirect URL or code back as `/login <value>`". Subscription provider IDs are separate from API IDs (`xai-oauth` vs `xai`, `openai-codex` vs `openai`, Claude Pro/Max OAuth on `anthropic`). | Supported. Per-provider environment variables, loaded from the shell or from four `.env` locations: `ANTHROPIC_API_KEY`, `XAI_API_KEY`, `OPENAI_API_KEY`, `LLAMA_CPP_API_KEY` (with `LLAMA_CPP_BASE_URL`), and others. A shared cloud node can point at an auth broker: `OMP_AUTH_BROKER_URL` + `OMP_AUTH_BROKER_TOKEN`; that mode "wins over `auth.broker.url`" and "startup fails rather than falling back to local credentials" when no token resolves. | <https://omp.sh/docs/providers> (routes table, credential precedence, provider matrix; accessed 2026-11-15); <https://omp.sh/docs/env> (provider credential names, `.env` load order, remote auth broker; accessed 2026-11-15) |
| mini-swe v2.4.6 (documentation-only — no probe on any Runner) | **api-key** | `blocked: no vendor-primary statement that mini-swe supports a subscription/plan login — the docs cover API keys and LiteLLM model routing only (docs/advanced/global_configuration.md)` | Supported by doc. Provider keys as environment variables or in the `.env` file in the global config dir (path printed at startup); environment wins over `.env`. Examples from the vendor page: `mini-extra config set ANTHROPIC_API_KEY "sk-…"`, `MSWEA_MODEL_NAME`, `LITELLM_MODEL_REGISTRY_PATH`. | <https://mini-swe-agent.com/latest/advanced/global_configuration/> (fetched 2026-11-15); <https://mini-swe-agent.com/latest/usage/mini/> (carried from `credentials.md:68-70`, T-06, checked 2026-11-15) |

### Claude Code 2.1.325 — notes

- Vendor, § Generate a long-lived token: "For CI pipelines, scripts, or other environments where interactive browser login isn't available, generate a one-year OAuth token with `claude setup-token`." The command "opens the same browser authorization flow as `/login`" and "does not save the token anywhere" — so the mint is an off-node operator step, and the token is the injected secret.
- Vendor, § Authentication precedence: cloud provider variables → `ANTHROPIC_AUTH_TOKEN` → `ANTHROPIC_API_KEY` → `apiKeyHelper` → `CLAUDE_CODE_OAUTH_TOKEN` → profile/federation → subscription OAuth from `/login`. A node that injects `ANTHROPIC_API_KEY` therefore does not use a subscription login that is also present.
- Vendor, § Credential management: on Linux credentials live in `~/.claude/.credentials.json` with mode `0600`; `CLAUDE_CONFIG_DIR` moves the file. That path is what a node mounts (`credentials.md:84`, container half).
- Long unattended runs need renewal headroom: the vendor warns a background or Remote Control session "that outlives the login stops making progress once the credential expires and can't recover until you sign in again".

### Grok 1.0.77 — notes

- Vendor (bundled `02-authentication.md`): tokens in `~/.grok/auth.json` and `~/.grok/mcp_credentials.json` are written `0600`; the doc instructs you not to copy them into shared directories, tickets, or chat, and to keep `$HOME`/`$GROK_HOME` private on multi-user hosts.
- Vendor (bundled `02-authentication.md` § Token Refresh): the refresh contract distinguishes a headless re-mint (`GROK_AUTH_EXPIRED=1`, stdin closed, "Mint silently or exit non-zero — never block") from an interactive sign-in (300-second ceiling). § Environment Variables names `GROK_AUTH_PROVIDER_COMMAND`, `GROK_AUTH_TOKEN_TTL`, `GROK_AUTH_EARLY_INVALIDATION_SECS` (default 300). An external auth-provider binary is the documented cloud route for enterprise SSO.

### omp 18.7.0 — notes

- Vendor (omp.sh/docs/providers § Credential precedence): `--api-key` → `models.yml` `providers.<id>.apiKey` → stored OAuth → `/login`-stored API key → provider environment variable (including `.env` values) → another stored key → custom resolver. "a stored OAuth login normally wins over `ANTHROPIC_API_KEY` in the environment".
- Vendor (same page): "Local credentials normally live in `~/.omp/agent/agent.db`. With an auth broker configured, login, logout, refresh, and credential reads use the remote store instead." This is the vendor-supported answer to keeping host secrets off a cloud node.
- Local evidence matches: `~/.omp/agent/agent.db`, table `auth_credentials` (`credentials.md:57`), and `omp auth-broker status` → "No auth-broker configured (set `OMP_AUTH_BROKER_URL` to enable)" (`credentials.md:108`).

## Claude Code `--bare` credential split (carried: `credentials.md:34`, gap 4)

The split is a runner-mode rule, not a host rule. It binds any Runner that launches `claude --bare`.

- Vendor primary, <https://code.claude.com/docs/en/headless#start-faster-with-bare-mode> (accessed 2026-11-15): "In bare mode, Claude Code never reads OAuth credentials or the system keychain. For the Anthropic API, set `ANTHROPIC_API_KEY` in the environment, with a key created in the Claude Console, or supply an `apiKeyHelper` in the `--settings` JSON. Amazon Bedrock, Google Cloud's Agent Platform, and Microsoft Foundry continue to read their own provider credentials as usual." The same section: "Set `ANTHROPIC_API_KEY` before running it, because bare mode doesn't use your subscription login".
- Local primary probe, 2026-11-15: `claude --version` → `2.1.325 (Claude Code)`; `claude --help` describes `--bare` as "Minimal mode: skip hooks …, LSP, plugin sync, attribution, auto-memory, background prefetches, keychain reads, and CLAUDE.md auto-discovery." The listed skips include keychain reads.
- Consequence for this grid: the Claude Code row reads **both** for a normal Runner, and **api-key** for a `--bare` Runner. A `--bare` node cannot use a mounted `.credentials.json`, a keychain entry, or `CLAUDE_CODE_OAUTH_TOKEN`; it needs `ANTHROPIC_API_KEY`, an `apiKeyHelper` in `--settings`, or a cloud-provider credential.
- Carried caveat from `credentials.md:138` (gap 4): AC-9 does not split rows by CLI mode, so `credentials.md` states the caveat once. This file is the place the cloud-auth AC reads it.

## credentials.md residual gaps (restated)

`credentials.md` § "Gaps found between the T-03/T-04/T-05 evidence and the AC-9 contract" (`credentials.md:131-138`) records these. They carry forward into phase 3 and phase 4 unchanged:

- **G1 — container half coverage.** The container grid is filled for Claude Code, Grok, and omp under the G-02-approved digest-pinned image; mini-swe stays documentation-only. Sub-items: (i) no container credential probe for a second image, a non-root container user, or a container class other than Docker; (ii) token refresh is untested for Claude Code and Grok because a forced refresh rotates the operator's live credential — both (b) rows carry the conservative writable-mount rule instead (`container-runner.md:34-37`, `:39-43`); (iii) the omp (c) verdict covers mounted state only — a container with no mount is unauthenticated, and a root container writes root-owned files into bind-mounted host paths; (iv) mini-swe has no probe on either Runner type.
- **G2 — omp native (b): provider env-var names not captured by probe.** The T-05 evidence records the store, the `--api-key` flag, and the help text "defaults to env vars", not the per-provider names. Cloud relevance: an adapter that injects env-var credentials onto a node must not guess names. Status update from primary docs: <https://omp.sh/docs/env> (accessed 2026-11-15) names them — Anthropic resolves `ANTHROPIC_OAUTH_TOKEN` → `ANTHROPIC_API_KEY`, xAI resolves `XAI_OAUTH_TOKEN` → `XAI_API_KEY`, llama.cpp uses `LLAMA_CPP_API_KEY` — and states that "Exact environment-variable names are intentionally centralized" on that page. The doc side is closed; the on-box probe side is not (B7).
- **G3 — Claude Code version drift.** Plan locks 2.1.322, installed 2.1.325; recorded as actual throughout. No credential-relevant difference observed. This file cites 2.1.325 only.
- **G4 — Claude Code bare-mode credential split.** Restated in full in § Claude Code `--bare` credential split.
- **Count note:** `credentials.md` lists **four** numbered gaps (gap 1 carries four sub-items). The spawn brief said "all five"; the file has four. The fifth item the orchestrator most likely means is the CDT-627 residual `loginctl enable-linger` (recorded on the T-12 pass line, `index.md:271`); it is restated here as B8 so nothing is dropped.

## Exposure (phase 3)

Scope per OQ-11: this section is the network exposure of a control-plane UI. Nothing is exposed today; phase 0 builds nothing. Build ticket: CDT-630.

**Named access layer: Cloudflare Access, applied as a self-hosted public-hostname application, in front of a Cloudflare Tunnel.** The layer is named now so phase 3 builds against it.

- Vendor primary, <https://developers.cloudflare.com/cloudflare-one/access-controls/applications/http-apps/self-hosted-public-app/> (accessed 2026-11-15): "You can securely publish internal tools and applications by adding Cloudflare Access as an authentication layer between the end user and your origin server."
- Deny-by-default is the vendor's rule, not ours: "All Access applications are deny by default -- a user must match an Allow policy before they are granted access."
- The order is a hard rule: the vendor notes "We recommend creating an Access application before setting up the tunnel route. If you do not have an Access application in place, the published application will be available to anyone on the Internet." Phase 3 therefore creates the Access application and its Allow policy before it adds the tunnel route.
- Origin-side check is required, not optional: "To secure your origin, you must validate the application token issued by Cloudflare Access. Token validation ensures that any requests which bypass Cloudflare Access (for example, due to a network misconfiguration) are rejected." The vendor's two options are `cloudflared` origin validation (**Protect with Access**, <https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/configure-tunnels/origin-parameters/#access>) or manual origin validation. Phase 3 takes the `cloudflared` option.
- Session and identity settings (IdP choice, session duration, optional independent MFA) are Access application settings, per the same page. Choose the IdP in phase 3.

**Node-side runtime:** the tunnel daemon runs on the node under the same supervision phase 1 ships — a systemd **user** unit under `~/.config/systemd/user/` (`native-runner.md` § "Start mechanism"). Phase 1 ships the `dev-team-chiefd.service` unit only; the node-agent unit is deferred with D1 (CDT-658 T8, see `native-runner.md` § "CDT-644"). Phase 3 adds the tunnel as a user unit on the same node; it does not put `cloudflared` inside a Runner container, because the credential mounts live on the host (`container-runner.md` Fact 2).

## Tunnel-token storage

Two credential shapes exist; name the one a node uses.

- **Remotely-managed tunnel (the shape phase 3 uses).** Vendor primary, <https://developers.cloudflare.com/tunnel/reference/tunnel-tokens/> (accessed 2026-11-15): "A remotely-managed tunnel only requires a token to run. Anyone with the token can run the tunnel." The token is the `eyJ…` string you copy from **Networking > Tunnels > the tunnel > Add a replica**, or `GET /accounts/{ACCOUNT_ID}/cfd_tunnel/{TUNNEL_ID}/token` with an API token that holds Cloudflare Tunnel Write (or one of the two connector-write permissions). Rotation: **Rotate token**, then reinstall the service on every replica; after rotation "`cloudflared` cannot establish new connections with the old token. Existing connectors remain active until restarted." For a compromised token, delete the connections collection (`DELETE /accounts/{ACCOUNT_ID}/cfd_tunnel/{TUNNEL_ID}/connections`) and reinstall.
- **Locally-managed tunnel (the shape this doc does not use).** Vendor primary, <https://developers.cloudflare.com/tunnel/features/locally-managed-tunnels/tunnel-permissions/> (accessed 2026-11-15): two files. `cert.pem` is issued by `cloudflared tunnel login`, is account-wide, "allows users to create, delete, and manage all tunnels for the account", is valid for at least 10 years, and is revoked by deleting its API token in the dashboard. `<TUNNEL-UUID>.json` is issued by `cloudflared tunnel create <NAME>`, is tunnel-scoped, "only allows the user to run that specific tunnel, and do nothing else", and does not expire. Vendor, <https://developers.cloudflare.com/tunnel/features/locally-managed-tunnels/local-tunnel-terms/> (accessed 2026-11-15): the default `cloudflared` directory on macOS and Unix-like systems is `~/.cloudflared`, `/etc/cloudflared`, then `/usr/local/etc/cloudflared`, in that order.
- **Decided storage rule for the node secret (the AC11 statement).** The token is a node-side secret, not a repo artifact and not a CLI argument:
  1. It lives in one owner-only file on the node, mode `0600`, owned by the node user, outside the repo worktree — so it can never be staged by a Runner process.
  2. The node's systemd user unit reads it: `EnvironmentFile=%h/…` (systemd requires an absolute path and does not expand `$HOME`; use `%h`. Vendor primary, <https://www.freedesktop.org/software/systemd/man/latest/systemd.exec.html#EnvironmentFile=>, accessed 2026-11-15: "The argument passed should be an absolute filename or wildcard expression. If the file does not exist, cannot be read, or contains invalid content, the service will fail to start." Fail-closed on a missing secret is the wanted behavior.)
  3. Rotation is an operator runbook step in phase 3: rotate in the dashboard, rewrite the file, restart the unit, per the vendor rotation procedure above.
  4. Never place the token in a ticket, a log line, a transcript, a decision-card, or a memory row — the last is a standing rule (OQ-10 in `memory-api.md`).
- **Where `cloudflared` itself puts a service-install token:** `blocked: the vendor page shows the "sudo cloudflared service install <TOKEN>" command and the rotation flow, but does not state the on-disk path the installer writes the token to; a phase-3 probe on the node is needed.`
- **Regenerating a credentials JSON from a token (`cloudflared tunnel token --cred-file <path>`):** `blocked: no primary Cloudflare doc verified on 2026-11-15 for this flag form — only community answers describe it.`

## Compute in cloud (phase 4)

Scope per OQ-11: running a host CLI on cloud compute. Build ticket: CDT-631. This section states the rules phase 4 inherits; it makes no cloud measurement.

- Per-host credential rule: § Cloud auth grid, unchanged. Add one row per host to the node provisioning contract, with the one-time operator step named.
- One-time operator steps (all vendor-documented, all off-node where a browser is needed): Claude Code — run `claude setup-token` on a browser-capable machine, inject `CLAUDE_CODE_OAUTH_TOKEN` on the node. Grok — `grok login --device-auth` on the node, open the printed URL on any device; or set `XAI_API_KEY` and run `grok logout` so the key is not shadowed by a stored token. omp — `/login <provider>` and paste the code back, or set the provider variable, or point at an auth broker. mini-swe — `mini-extra config set` or export the provider key.
- Writability rule carried from phase 0 (`container-runner.md` Fact 2): a credential that refreshes needs a writable location. Mount `.credentials.json` and `auth.json` read-write, or copy them into a node-local state dir; a fully read-only `~/.omp` kills omp before any model call with `EROFS`, and the `auth_credentials` row is rewritten at runtime.
- Isolation rule: cloud compute is a multi-tenant-risk boundary. Keep `CLAUDE_CONFIG_DIR`, `$HOME`/`$GROK_HOME`, and `~/.omp` private to the node user (the Grok doc's own instruction), and prefer the vendor's remote-credential option (omp auth broker; Claude `apiKeyHelper`; Grok external auth provider) over copied token files.
- Memory-residency rule (phase 4, from `memory-api.md` / OQ-10): memory rows on cloud compute are encrypted at rest, stay inside the single-user boundary, and never carry secrets. A token, cookie, key, or `auth.json` copy is not memory content.
- Cloud-provider-native option for Claude Code: Bedrock / Agent Platform (Vertex) / Foundry need "No browser login is needed" (`https://code.claude.com/docs/en/authentication`), so a node in that account avoids the browser-mint step entirely. Choose the account type in phase 4.
- Vendor capability noted, not adopted: `claude self-hosted-runner` "registers this machine or container with a self-hosted environment and hosts Claude Code cloud sessions on your infrastructure" (`https://code.claude.com/docs/en/cli-reference`, requires v2.1.224+). That is Anthropic's own runner for Claude cloud sessions; the control-plane Node agent is a different component. Phase 4 records it as an alternative, not as the design.

## Blocked items

Each line is the honest output of phase 0, not a failure.

- **B1** `blocked: no cloud VM exists in phase 0 — subscription-login and api-key injection on cloud compute are documented, not measured; a phase-4 node probe is needed.`
- **B2** `blocked: a public web vendor URL for the Grok CLI auth docs — the docs ship inside the CLI (~/.grok/docs/user-guide/02-authentication.md, 14-headless-mode.md); no public vendor page for the CLI auth flow was verified on 2026-11-15.`
- **B3** `blocked: mini-swe subscription-login — no vendor-primary statement that LiteLLM subscription/plan auth (non-API-key) is supported by mini.`
- **B4** `blocked: the on-disk path where "cloudflared service install <TOKEN>" stores the token — not stated in the vendor page; needs a node probe in phase 3.`
- **B5** `blocked: the "cloudflared tunnel token --cred-file" flag form — no primary Cloudflare doc verified on 2026-11-15.`
- **B6** `blocked: forced token-refresh on a mounted credential for Claude Code and Grok — a forced refresh rotates the operator's live credential; a sandbox credential is needed (carried: container-runner.md:34-37 and :39-43).`
- **B7** `blocked: on-box proof of which omp provider env-var name each provider reads — the vendor doc names the names; the local store probe does not prove the resolution path (credentials.md gap 2).`
- **B8** `blocked: loginctl enable-linger on the node — a machine change, out of phase-0 scope (CDT-627 residual, index.md:271).`
- **B9** `blocked: the Cloudflare Access plan, the identity provider, and the hostname — all need the operator's Cloudflare account, which phase 0 does not have.`
