# Credentials — per host per Runner type

Carries AC-9. T-09 owns this file and writes it alone; it pulls evidence rows from T-03/T-04/T-05 outputs.

**Note:** CDT-632's cloud-auth AC reads this file when it exists.

## Evidence provenance and rules

- Native-Runner rows below are synthesized from the AC-9 native half of `native-runner.md` (per-host evidence rows owned by T-03 / T-04 / T-05). Verdicts, versions, probe dates, and probe sources are carried over unchanged from those rows.
- The Container-Runner rows are synthesized from the AC-9 container half of `container-runner.md` (per-host evidence rows owned by T-03 / T-04 / T-05), probed under the G-02-approved image (row 1). Those rows are cited by file:line.
- Every row carries: verdict (`supported` / `unsupported` / `unverified-after-attempt` per `index.md`), host CLI version, probe date, and source. A bare `unknown` fails review (AC-2). Secret values are never printed here — paths and key NAMES only.
- mini-swe is documentation-only (T-06); its row cites vendor-primary doc URLs, no probe.

## AC-9 — Credential plan grid

One row per host × Runner type:

(a) the auth method in the runner — API key / OAuth token / subscription login;
(b) where the secret lives — env var name, mounted file path, or host keyring;
(c) restart survival — container restart for the container Runner, process restart for the native Runner.

Hosts needing an interactive browser login are flagged with the one-time operator step.

### Claude Code 2.1.325 — native Runner

Version note: the plan locked Claude Code 2.1.322; the installed CLI is `claude 2.1.325 (Claude Code)` (`claude --version`, probed 2026-11-15). Rows record the actual version, consistent with `host-capability-matrix.md`.

| AC-9 fact | Verdict | Evidence (probe 2026-11-15; source: `native-runner.md` § AC-9 native half, T-03 rows) |
|---|---|---|
| (a) auth method in the runner | supported — subscription login via OAuth token | `jq -r 'keys[]?' ~/.claude/.credentials.json` → `claudeAiOauth`, `mcpOAuth`; the `claudeAiOauth` record carries `accessToken`, `expiresAt`, `refreshToken`, `refreshTokenExpiresAt`, `scopes`, `subscriptionType`, `subscriptionTypeSource` (key names only — values not read). No `ANTHROPIC_*` environment variables are set (`env \| grep -o 'ANTHROPIC[A-Z_]*'` → empty), so the CLI is not running on an API key. |
| (b) where the secret lives | supported — file on disk, no env var, no keyring entry | `~/.claude/.credentials.json`, mode `600` (`-rw------- 1 malcolm malcolm 2212 …`). No env-var credential is in play; no host-keyring storage is used. |
| (c) survives a process restart | supported | The credential file persists on disk across processes. Every probe in this ticket (P-CC-A..P-CC-D in `host-capability-matrix.md`) was a fresh `claude` process that authenticated without re-login — including the SIGKILL-and-resume probe P-CC-A. |

Runner-mode caveat carried from T-03: in `--bare` mode the CLI reads Anthropic auth strictly from `ANTHROPIC_API_KEY` or `apiKeyHelper` via `--settings` — the OAuth/keychain paths are never read (`claude --help`, `--bare` description, verified on the installed CLI). A native runner built on `--bare` needs one of those instead of the subscription token file.

Operator one-time step: not needed for the native Runner — subscription login is already established on this machine.

### Grok 1.0.77 — native Runner

`grok --version` → `grok 1.0.77 (50ca579fa996) [stable]`; binary `/home/malcolm/.grok/bin/grok`. Probe date 2026-11-15. Matches the plan lock — no drift. Source: `native-runner.md` § AC-9 native half, T-04 rows.

| AC-9 fact | Verdict | Evidence |
|---|---|---|
| (a) auth method in the runner | supported — OAuth token flow against `https://auth.x.ai` via browser login (`grok login`); headless alternative: `XAI_API_KEY` API key from console.x.ai | The credential record in `~/.grok/auth.json` carries `auth_mode`, `refresh_token`, and `expires_at` fields (key names only — values not read). Headless alternative documented by the vendor: `~/.grok/docs/user-guide/02-authentication.md`, `14-headless-mode.md` § Authentication for Headless Environments. |
| (b) where the secret lives | supported — file on disk; env var alternative | `~/.grok/auth.json` (owner-only `0600` per vendor doc); MCP OAuth tokens at `~/.grok/mcp_credentials.json`; env alternative `XAI_API_KEY`. Vendor doc: `02-authentication.md` § Credential storage. |
| (c) survives a process restart | supported | Vendor doc (`02-authentication.md` § Browser Login): "stores credentials in `~/.grok/auth.json` and reuses them across sessions. Grok refreshes access tokens automatically in the background" (proactive refresh ~5 min before expiry, on-401 refresh). Probe: every headless probe on 2026-11-15 ran in a fresh process with no login step, including a resume into a new process (matrix evidence (a)). |

Operator one-time step: **flagged — interactive browser login.** The first login needs an interactive browser session (`grok login`, loopback OAuth; `--oauth` forces it). One-time operator step: run `grok login` once on the node in a browser-capable session; after that, cached credentials in `~/.grok/auth.json` cover native Runner processes. Headless nodes without a browser use `XAI_API_KEY` instead.

### omp 18.7.0 — native Runner

`omp --version` → `omp/18.7.0` at `/usr/sbin/omp`. Probe date 2026-11-15. Matches the plan lock — no drift. Source: `native-runner.md` § AC-9 native half, T-05 rows.

| AC-9 fact | Verdict | Evidence |
|---|---|---|
| (a) auth method in the runner | supported — per-provider API keys for the OpenAI-compatible providers (`spark-tf`, `vault-strata`, `studio-tf`; base URLs only in `~/.omp/providers.json`) | omp also accepts `--api-key=<value>` on the CLI and falls back to provider env vars (help: "API key (defaults to env vars)"). The configured model roles need no subscription login and no interactive browser flow. |
| (b) where the secret lives | supported — file on disk (SQLite store); no plaintext in config files; no desktop keyring | The keyring-style store is `~/.omp/agent/agent.db` (SQLite), table `auth_credentials` — probe `sqlite3 ~/.omp/agent/agent.db 'SELECT COUNT(*) FROM auth_credentials;'` returned `2`. No plaintext keys in `~/.omp/agent/config.yml` or `~/.omp/agent/models.yml` (grepped; no `api_key`/`token`/`secret` keys present). A `secret-tool search service omp` over the host keyring returned nothing — omp does not use the desktop keyring on this box. Env-var fallback is per provider: `<PROVIDER>_API_KEY` per built-in provider (`OPENAI_API_KEY`, `ANTHROPIC_API_KEY`, `XAI_API_KEY`, `GEMINI_API_KEY`, `GROQ_API_KEY`, etc.); the one stored API-key credential is provider `llama.cpp` → `LLAMA_CPP_API_KEY` (with `LLAMA_CPP_BASE_URL` for the endpoint), while the configured `spark-tf` / `vault-strata` / `studio-tf` gateways are `"auth": "none"` and need no env var (probe `strings -a /usr/sbin/omp | grep -oE '[A-Z][A-Z0-9_]{2,}_API_KEY' | sort -u`, 2026-11-15). |
| (c) survives a process restart | supported | The store is file-backed SQLite, not process memory. Evidence: the `auth_credentials` rows carry creation timestamps from 2026-10-07 and `agent.db` `model_usage` shows authenticated model runs spanning 2026-10-07 → 2026-11-02 — a month of separate omp processes reused the same stored credentials without re-login. This probe session (2026-11-15) also ran authenticated from the same store. |

Operator one-time step: none — no interactive browser flow is in play for the configured providers.

### mini-swe — documentation-only (both Runner types)

No probe was run; every cell is documentation-only and cites vendor-primary docs (T-06 basis, re-checked 2026-11-15). Version reviewed: mini-swe-agent v2.4.6 (GitHub releases). Sources: <https://mini-swe-agent.com/latest/advanced/global_configuration/> and <https://mini-swe-agent.com/latest/usage/mini/>, checked 2026-11-15.

| AC-9 fact | Verdict | Evidence (documentation-only) |
|---|---|---|
| (a) auth method in the runner | supported — API key via provider environment variables (LiteLLM model layer); no subscription login and no interactive browser flow are documented | Global configuration page: "This guide shows how to configure the `mini` agent's global settings (API keys, default model, etc.)… anything that is set as environment variables or similar"; example key setting: `mini-extra config set ANTHROPIC_API_KEY "sk-..."`. Models route through LiteLLM (`--model-class` default `litellm`), so provider-standard env keys apply. Sources: <https://mini-swe-agent.com/latest/advanced/global_configuration/> + <https://mini-swe-agent.com/latest/usage/mini/>. |
| (b) where the secret lives | supported — environment variables, or the `.env` file in the global config dir (path printed when `mini` starts) | "All global configuration can be either set as environment variables, or in the `.env` file (the exact location is printed when you run `mini`). Environment variables take precedence over variables set in the `.env` file." Managed with `mini-extra config set/unset KEY VALUE`. Source: <https://mini-swe-agent.com/latest/advanced/global_configuration/>. |
| (c) survives a process restart | supported — documentation-only | Keys set in the `.env` file live in the global config directory on disk and are re-read on every run, so they survive a process restart. Keys supplied only as environment variables survive a restart only if the starting environment re-supplies them. Source: <https://mini-swe-agent.com/latest/advanced/global_configuration/> (`.env` file mechanism), checked 2026-11-15. |

Operator one-time step: none documented — keys are provisioned by `mini-extra config setup` / `mini-extra config set` or a plain `export`; no browser login exists in the docs.

## Container-Runner half — AC-9 grid

G-02 is APPROVED by the maintainer for row 1 only — `docker.io/library/debian:trixie-slim@sha256:a72b4433de1cf7d6bae0c4cee74d0547f58601a643b3375f070c51600d63b6b2`, with in-container `apt-get install git curl ca-certificates` pre-approved (`container-runner.md:5`). The Claude Code, Grok, and omp container halves ran under that approval on 2026-11-15, so the container rows below are filled. Each row is synthesized from `container-runner.md` § "AC-9 (container half)" (`container-runner.md:152-188`); the quoted text is verbatim from those rows and the raw probe transcripts are in `host-capability-matrix.md`. The CLI binary comes from the host, bind-mounted read-only (`container-runner.md:93` Claude Code, `container-runner.md:100` Grok), so the in-container version equals the host version recorded in the matching native section; omp runs the host 18.7.0 CLI with its `~/.omp/natives/18.7.0/` tree mounted read-only (`container-runner.md:108`). mini-swe keeps its documentation-only status (T-06). Secret values are never quoted — paths and key NAMES only.

### Claude Code 2.1.325 — container Runner

Version note: image `debian:trixie-slim@sha256:a72b…6b2` (G-02 row 1) with the host binary mounted read-only; `claude --version` → `2.1.325 (Claude Code)` in-container (`container-runner.md:93`). Probe date 2026-11-15. Source: `container-runner.md:160-165` (T-03 container half).

| AC-9 fact | Verdict | Evidence (probe 2026-11-15; verbatim from `container-runner.md:162-164`) |
|---|---|---|
| (a) auth method in the runner | supported — subscription login via the cached OAuth token; no API key, no env var | "subscription login — the OAuth token cached by the host CLI in `~/.claude/.credentials.json` (the `claudeAiOauth` account entry). No API key and no env-var secret were set on any probe run; every authed call used the mounted token file." |
| (b) where the secret lives | supported — mounted file, read-only, at `$HOME/.claude/.credentials.json`; no env var, no host keyring | "mounted file — host `~/.claude/.credentials.json` bind-mounted read-only at its host path inside the container (`-v /home/malcolm/.claude/.credentials.json:/home/u/.claude/.credentials.json:ro`, with `HOME=/home/u` on a scratch bind mount so the CLI finds it at `$HOME/.claude/.credentials.json`). Supporting mounts: `~/.claude` read-write (transcripts under `~/.claude/projects/`, plugin/skill discovery, settings) and `~/.claude.json` (copied into the scratch HOME — project trust state). Values were never printed in any probe output." |
| (c) survives a container restart | supported — observed directly | "P-CON-STEER created a session and wrote its transcript from one container; P-CON-A resumed that same session by id from a brand-new container and the auth worked with zero operator action (`RESUME_EXIT:0`, token `STEER-CON8-44` returned). The credential and session state live on the host volume; a restarted container re-mounts both unchanged. A container started without the mount is unauthenticated." |

Operator one-time step: **flagged — host-side browser login.** "host-side only — run `claude` on the host and complete the OAuth browser login once; containers then mount the resulting `.credentials.json`. No interactive login is needed inside the container itself." (`container-runner.md:165`). Refresh caveat carried from AC-6 fact 2: "Token refresh inside long-lived containers needs a writable mount … mount `.credentials.json` read-write, or copy it into a container-local state dir." (`container-runner.md:165`); the forced-refresh probe variant is a named blocker — it would rotate the operator's live credential (`container-runner.md:34-37`).

### Grok 1.0.77 — container Runner

Version note: `grok 1.0.77` in container (`container-runner.md:22`) on the same approved image — the host binary is `grok 1.0.77 (50ca579fa996) [stable]`, bind-mounted read-only (`container-runner.md:100`). Probe date 2026-11-15. Source: `container-runner.md:171-177` (T-04 container half).

| AC-9 fact | Verdict | Evidence (probe 2026-11-15; verbatim from `container-runner.md:173-175`) |
|---|---|---|
| (a) auth method in the runner | supported — subscription login via the cached token (`cached_token`); the browser method is the alternative | "subscription login — the OAuth/session token cached in `~/.grok/auth.json`. The ACP `initialize` result names it: `\"authMethods\":[{\"id\":\"cached_token\",\"description\":\"Cached token from ~/.grok/auth.json\"},{\"id\":\"grok.com\",\"description\":\"Sign in with Grok\"}]` — `cached_token` is the default (`defaultAuthMethodId\":\"cached_token\"`). The alternative `grok.com` method is the interactive browser login." |
| (b) where the secret lives | supported — mounted file, read-only, at `/root/.grok/auth.json`; no env-var secret | "mounted file — host `~/.grok/auth.json` bind-mounted read-only at `/root/.grok/auth.json` in every probe container. Supporting mounts: `~/.grok/auth.sh` (the `auth_provider_command` for local model providers; prints a stub token — no secret) and `~/.grok/config.toml` (model routing) — both read-only. No env-var secret is required. Values were never printed in any probe output." |
| (c) survives a container restart | supported — observed across 9 containers | "yes — observed across nine independent `docker run --rm` containers (P-GK-CTR-1 … P-GK-CTR-8c, 2026-11-15); each container instance authenticated from the same mounted host file with zero auth failures. The credential state lives on the host volume, so a restarted container re-mounts it unchanged." |

Operator one-time step: **flagged — host-side browser login.** "host-side only — run `grok` and complete the `grok.com` browser login once on the host; containers then mount the resulting `auth.json`. Token refresh within long-lived containers needs a writable mount (AC-6 fact 2): mount `auth.json` read-write, or copy it into a container-local state dir." (`container-runner.md:176`). In-container login is not needed: "no interactive login is needed inside the container itself" (`container-runner.md:177`). The forced-refresh variant is a named blocker (`container-runner.md:39-43`).

### omp 18.7.0 — container Runner

Version note: `omp/18.7.0` in-container on the same approved image (`container-runner.md:108`); probe date 2026-11-15. Source: `container-runner.md:183-188` (T-05 container half).

| AC-9 fact | Verdict | Evidence (probe 2026-11-15; verbatim from `container-runner.md:185-187`) |
|---|---|---|
| (a) auth method in the runner | supported — per-provider credentials plus an optional auth-broker; subscription login exists as a first-class path; the probe model needs no secret (`"auth": "none"`) | "per-provider credentials held by omp itself, plus an optional auth-broker. This box's probe model needs no secret at all: the `spark-tf` and `studio-tf` providers are declared `\"api\": \"openai-completions\"`, `\"auth\": \"none\"` in `~/.omp/agent/models.yml`, so the container authenticates nothing. Subscription login exists as a first-class path — `omp auth-broker [ACTION] [SOURCE]` with ACTION ∈ `serve\|token\|login\|logout\|import\|migrate\|status\|list`". No broker is active in-container: `omp auth-broker status` → `No auth-broker configured (set OMP_AUTH_BROKER_URL to enable).` — identical to the host. |
| (b) where the secret lives | supported — mounted file (`agent.db`, table `auth_credentials`); no env var, no host keyring | "the mounted file `~/.omp/agent/agent.db`, table `auth_credentials` (columns `id, provider, credential_type, data, disabled_cause, identity_key, created_at, updated_at`; rows here `llama.cpp\|api_key`, `mcp_oauth:profile:default:https://mcp.linear.app/mcp\|oauth`). No env var is involved on the gateway path, and no host keyring is used. Probe mount: `-v /tmp/omp-c627-home/.omp/agent/agent.db:/root/.omp/agent/agent.db:ro` (a copy — the live `~/.omp` is never mounted). Provider base URLs are non-secret and live in `~/.omp/providers.json` + `models.yml`." |
| (c) survives a container restart | supported for the mounted state; a container with no mount is unauthenticated | "yes for mounted state, no for container state. Credentials and sessions are host-side files, so a fresh container re-reads them: a brand-new container resumed a session written by an earlier container off the writable mount (`{\"type\":\"session\",\"version\":3,\"id\":\"01a1de23-6268-77dc-9abf-21a6e92d7d0a\",…}` → `\"text\":\"RESUME-OK\"`). A container started **without** the mount begins from an empty `~/.omp` and is unauthenticated. Writes need a writable mount (Fact 2), and a root container writes root-owned files into the bind-mounted host paths." |

Operator one-time step: **flagged — only for subscription providers.** "Run `omp auth-broker login <provider>` once with a **writable** `~/.omp` mount; the OAuth/device flow is the browser step, and its refreshed token must be able to rewrite `auth_credentials` (Fact 2 item 5). The gateway path used by these probes has no operator step." (`container-runner.md:188`). Runner rule from AC-6 fact 2: the whole `~/.omp` tree must be writable — a fully read-only `~/.omp` kills omp before any model call with `EROFS: read-only file system` (`container-runner.md:48-56`).

### mini-swe — container Runner (documentation-only)

No probe was run for mini-swe on either Runner type; the documentation-only status carries over unchanged. The container-environment class (Docker/Podman/Singularity/Apptainer/Bubblewrap) runs the same single-task runs with the same key mechanism (`<https://mini-swe-agent.com/latest/faq/>`, per T-06, re-checked 2026-11-15). The (a)/(b)/(c) cells are the vendor-doc cells in the mini-swe section above: API key via provider environment variables or the `.env` file in the global config dir, with no browser login documented and no probe verdict.

## One-time operator steps (interactive browser logins)

| Host | Runner | Operator step |
|---|---|---|
| Grok 1.0.77 | native | One-time `grok login` in a browser-capable session (loopback OAuth against `https://auth.x.ai`); cached thereafter in `~/.grok/auth.json`. Browser-less nodes use `XAI_API_KEY`. |
| Claude Code | native | None — subscription login already established on this machine. |
| omp | native | None — provider API keys only; no browser flow. |
| mini-swe | both | None documented — API keys via env vars / `.env` file. |
| Claude Code | container | One-time **host-side** OAuth browser login (`claude` on the host); containers mount the resulting `.credentials.json` read-only. Long-lived containers need that mount read-write for token refresh. Source: `container-runner.md:165`. |
| Grok 1.0.77 | container | One-time **host-side** `grok login` (the `grok.com` browser method); containers mount the resulting `auth.json` read-only. Long-lived containers need that mount read-write for token refresh. Source: `container-runner.md:176`. |
| omp 18.7.0 | container | Needed only for subscription providers: `omp auth-broker login <provider>` once with a **writable** `~/.omp` mount (the OAuth/device flow is the browser step). The gateway path used by the probes (`"auth": "none"`) has no operator step. Source: `container-runner.md:188`. |
| mini-swe | container | None documented — API keys via env vars / `.env` file; documentation-only. |

## Gaps found between the T-03/T-04/T-05 evidence and the AC-9 contract

Recorded here for T-12 review; none is a bare `unknown`, and no row above was invented beyond the cited evidence:

1. **Container half of the grid is filled for Claude Code, Grok, and omp; mini-swe stays documentation-only** — G-02 approved row 1 (one digest-pinned image, `container-runner.md:5`), so the AC-9 container cells no longer wait on the gate. Residual container-side gaps: (i) no container credential probe exists for a second image, a non-root container user, or a container-environment class other than Docker; (ii) the token-refresh write is untested for Claude Code and Grok — a forced refresh would rotate the operator's live credential, so it is a named blocker, and both (b) rows carry the conservative writable-mount rule instead (`container-runner.md:34-37`, `:39-43`); (iii) omp's (c) verdict covers mounted state only — a container started without the mount is unauthenticated, and a root container writes root-owned files into the bind-mounted host paths (`container-runner.md:187`); (iv) mini-swe has no probe on either Runner type.
2. **omp native (b): provider env-var names not captured.** AC-9(b) asks for the secret location including "env var name"; the T-05 evidence records the store (`~/.omp/agent/agent.db`, table `auth_credentials`), the `--api-key` flag, and the help-text statement "defaults to env vars" — but does not name the per-provider env vars themselves. Follow-up probe needed on the omp side before the Host adapter relies on env-var credential injection. — **Resolved 2026-11-17 (CDT-648 B7)**: see § "Gap 2 — resolved: the omp provider env-var names (B7)" below.
3. **Claude Code version drift** — plan locks 2.1.322, installed 2.1.325. Recorded as actual throughout (consistent with `host-capability-matrix.md`); no credential-relevant difference observed, but T-12 should confirm the drift is accepted.
4. **Claude Code bare-mode credential split** — the native runner's `--bare` mode reads only `ANTHROPIC_API_KEY` / `apiKeyHelper` and never the subscription token file (T-03 note). AC-9 does not split rows by CLI mode; this file carries the caveat so CDT-632's cloud-auth AC sees both postures.

## Gap 2 — resolved: the omp provider env-var names (B7)

CDT-648 AC5 (the CDT-627 close-out's "omp env-var-name probe" residual, executed as B7). The
question: which env-var NAME does omp actually READ per provider — not which names merely exist in
the binary (the T-05 `strings -a` probe listed candidates only). Probed 2026-11-17.

**Version drift note (recorded as a deviation):** the matrix locks omp 18.7.0; the node's installed
build is now **omp v18.22.0** (`omp --version`; binary `/usr/sbin/omp`, replaced 2026-11-17 01:30 —
`~/.omp/natives/` carries only `18.22.0`). The probe ran on the installed
18.22.0 build; the 18.7.0 binary is gone, so the per-name result could not be cross-checked against
the locked version. The names below are what the on-box omp demonstrably reads today; the Host
adapter's proven-name table carries them, and an unproven name fails closed.

**Method (behavioral, per provider).** Each run is a headless omp against one provider with an
empty, isolated auth store — `HOME=$(mktemp -d)`, so no stored credential from
`~/.omp/agent/agent.db` can stand in and no real secret is in play. Two runs per provider:

- **Control:** no candidate variable set. omp answers locally without touching the network:
  `error: No API key found for <provider>.` — observed verbatim for `openai`, `anthropic`, `xai`,
  `groq`, and `google`.
- **Probe:** exactly one candidate variable set to a dummy, non-routing value
  (`sk-dummy-b7-probe-not-a-secret`). If omp reads that variable, the request reaches the provider
  and the provider answers with an auth failure naming the bad key — which proves the read. If omp
  still answers with the local missing-key error, the variable is not read.

Probe shape (one line per provider, no script file):

```
HOME=$(mktemp -d) NAME_API_KEY=sk-dummy-b7-probe-not-a-secret timeout 60 \
  /usr/sbin/omp -p --max-time 40 --no-session --model <provider>/<model> 'Reply OK'
```

**Results (verbatim evidence; dummy values only — no real secret printed):**

| Provider (omp) | Proven env-var name | Probe observation | Control |
|---|---|---|---|
| `openai` (`openai/gpt-5.2`) | `OPENAI_API_KEY` | `401 Incorrect API key provided: sk-dummy******************cret. You can find your API key at https://platform.openai.com/account/api-keys. (type=invalid_request_error param=invalid_api_key)` — the dummy value reached OpenAI | `error: No API key found for openai.` |
| `anthropic` (`anthropic/claude-sonnet-4-5`) | `ANTHROPIC_API_KEY` | `401 {"type":"error","error":{"type":"authentication_error","message":"invalid x-api-key"},"request_id":"req_…"}` — the dummy value reached Anthropic | `error: No API key found for anthropic.` |
| `xai` (`xai/grok-4`) | `XAI_API_KEY` | `400 Incorrect API key provided. You can obtain an API key from https://console.x.ai. (type=invalid-argument)` — the dummy value reached xAI | `error: No API key found for xai.` |
| `google` (`google/gemini-2.5-pro`) | `GEMINI_API_KEY` | `Google API error (400): API key not valid. Please pass a valid API key.` — the dummy value reached Google; the rival candidate `GOOGLE_API_KEY` set instead answered the local missing-key error, so the name is `GEMINI_API_KEY`, not `GOOGLE_API_KEY` | `error: No API key found for google.` |
| `groq` (`groq/llama-3.3-70b-versatile`) | `GROQ_API_KEY` | `401 Invalid API Key (type=invalid_request_error param=invalid_api_key)` — the dummy value reached Groq | `error: No API key found for groq.` |
| `llama.cpp` | **none — negative result** | With no env var set, omp still reached the local endpoint and failed on the model, not the key (`400 "pplx-decider-flash:4b" does not support chat`); setting `LLAMA_CPP_API_KEY` changed nothing. The resolution path confirms it: the llama.cpp provider reads its key from the auth store (`this.authStorage.keys.source("llama.cpp")` in the bundled source) and the only `LLAMA_CPP_*` env var omp carries is `LLAMA_CPP_BASE_URL`, the endpoint override. The T-05 `LLAMA_CPP_API_KEY` string is the store row's credential naming, not an env read | `400 "pplx-decider-flash:4b" does not support chat` with and without the variable |

**Cross-provider negative control:** `XAI_API_KEY` set with an `anthropic/claude-sonnet-4-5` model →
`error: No API key found for anthropic.` — the map is per provider; one provider's variable never
stands in for another's, and there is no global fallback.

**Adapter rule implemented (CDT-648 AC5):** `control-plane/hostadapter/credentials.go` carries the
proven-name table above. Injection resolves against the table; an unproven name — including
`llama.cpp`, whose credentials live in the store — fails closed with
`ErrCredentialNameUnproven` before any journal row is written. No fallback chain, no guess.
Injection values travel as environment entries for the runner process only: never argv, never a
shell string, never a journal row, never a log line.
