# Container Runner facts

Carries AC-6 (five facts) and the container half of AC-9. The AC-9 credential grid synthesizes into `credentials.md` (T-09); this file holds the per-host container credential evidence rows. Container work waits on the AC-10 approval gate (T-02 / G-02).

Gate state: G-02 is APPROVED by the maintainer for row 1 only — `docker.io/library/debian:trixie-slim@sha256:a72b4433de1cf7d6bae0c4cee74d0547f58601a643b3375f070c51600d63b6b2` (official Debian image, digest-pinned), with in-container `apt-get install git curl ca-certificates` pre-approved per the gate record. The Claude Code container probes (T-03 container half) ran under that approval on 2026-11-15. Probes are evidence only (AC-10) — the image is referenced nowhere from a product surface.

## AC-6 — Container-Runner facts

Each of the five facts gets a verdict and AC-2 evidence. "Not tested" without a written reason fails review. A named blocker is a valid verdict — record it with the reason.

### Fact 1 — Subscription login from a mounted volume

<!-- T-03/T-04/T-05 record the per-host CLI evidence (CC / Grok / omp). -->

**Claude Code (T-03, probe 2026-11-15) — Verdict: supported (mounted volume, read-only).** The subscription OAuth token lives in `~/.claude/.credentials.json`; bind-mounted read-only into every probe container (`-v /home/malcolm/.claude/.credentials.json:/home/u/.claude/.credentials.json:ro`, `HOME=/home/u` on a scratch bind mount), every authed call succeeded.

- Ten-plus headless `claude -p` sessions in independent `docker run --rm` containers (P-CON-1, P-CON-STEER, P-CON-A/B/C1..C3, P-CON-M, P-CON-G in `host-capability-matrix.md`) authenticated from the same read-only mount with zero auth failures. Representative output: P-CON-A returned `STEER-CON8-44` (`RESUME_EXIT:0`) from a brand-new container.
- No interactive browser login inside the container is needed — the one-time operator step is the host-side `claude` login only; containers mount the resulting file.

**Grok (T-04)** — `supported`. The subscription auth lives in `~/.grok/auth.json`; bind-mounted read-only into every probe container, every authed call succeeded.

- Probe (P-GK-CTR-1, 2026-11-15, grok 1.0.77 in container, image `debian:trixie-slim@sha256:a72b…6b2`): `docker run --rm -v ~/.grok/auth.json:/root/.grok/auth.json:ro … grok -p "Reply with exactly: CTR-OK" --output-format json` → `{"text":"CTR-OK","stopReason":"end_turn",…}`. The ACP `initialize` result also names the method: `"authMethods":[{"id":"cached_token",...,"description":"Cached token from ~/.grok/auth.json"},{"id":"grok.com",...}]`.
- Nine independent throwaway containers (P-GK-CTR-1 … P-GK-CTR-8c) each authenticated from the same read-only mount with zero auth failures. No interactive browser login inside the container is needed — the one-time operator step is the host-side `grok` login only.

- Verdict:
- Evidence:

**omp 18.7.0 (T-05, probe 2026-11-15) — Verdict: supported (mounted volume, read-only).** The credential store is a file: `~/.omp/agent/agent.db`, table `auth_credentials` (rows on this box: `llama.cpp | api_key`, `mcp_oauth:profile:default:https://mcp.linear.app/mcp | oauth`). A copy mounted read-only at `/root/.omp/agent/agent.db` is enough for omp to start and run: `omp -p --mode json … 'Reply with exactly PONG'` returned `"text":"PONG"` with zero `EROFS`/`readonly` mentions for `agent.db`. The subscription-login surface is present and works off the mounted volume: `omp auth-broker list` printed the subscription roster (`openai-codex  ChatGPT Plus/Pro (Codex Subscription)`, `anthropic  Anthropic (Claude Pro/Max)`, `zai`, `openrouter`, `github-copilot`, …) and `omp auth-broker status` printed `No auth-broker configured (set OMP_AUTH_BROKER_URL to enable).` — the same line the host prints, i.e. credentials live in the mounted DB, not in a broker. No login was executed: the mounted DB carries no credential for any roster provider (only `llama.cpp|api_key` and the Linear MCP OAuth row), and the probe model's provider is `"auth": "none"`, so no login is needed on this path. The login verb exists (`auth-broker [ACTION] [SOURCE]`, ACTION ∈ `serve|token|login|logout|import|migrate|status|list`); run it with a **writable** agent.db mount (Fact 2).

### Fact 2 — Token refresh writable-mount need

<!-- T-03/T-04/T-05 record the per-host CLI evidence. -->

**Claude Code (T-03, probe 2026-11-15) — Verdict: no refresh fired inside the probe window; the forced-refresh variant is a named blocker.** Conservative runner contract: mount `.credentials.json` read-write (or copy it into a container-local state dir) if sessions outlive one token lifetime — the refresh path targets the same file, and a read-only mount cannot absorb it.

- Observed: the host `.credentials.json` mtime and sha256 were unchanged across every container probe on 2026-11-15 (`2026-11-14 22:45:00.983382336 -0500`, `278bd05e…42ad3d7` before and after ten-plus authed runs) — the ro mount caused no visible write attempt and no call failed.
- Not tested, with reason: forcing a token refresh would rotate/kill the operator's live subscription credential — a forced-refresh probe needs a sandbox credential (named blocker for the forced variant). The ro-mounted token was accepted for the whole probe window (sessions ran ~1 h against a token issued 2026-11-14 22:45).

**Grok (T-04)** — auth reads fine from a read-only mount; the refresh write was not exercised within the probe window. Verdict for the runner contract: refresh needs a **writable mount** (conservative) — the refresh path targets the same file, and the CLI holds a lock file beside it (`~/.grok/auth.json.lock`), so a read-only `auth.json` mount will break any refresh that fires.

- Observed (2026-11-15): the token's `expires_at` was `2026-11-15T10:30:47Z` and probes ran 07:30–07:56Z, so no refresh triggered. Across all read-only-mount probes (P-GK-CTR-1 … P-GK-CTR-6) the host `auth.json` mtime was unchanged after each run (`2026-11-14 23:30:47.409870984 -0500` before and after), i.e. no spurious write attempt surfaced and no call failed.
- Attempted write-side test (P-GK-CTR-7): a copy of `auth.json` mounted read-write at `/root/.grok/auth.json`; one authed call returned `REFRESH-PROBE-OK` and the copy's mtime was unchanged after the run (`2026-11-15 02:56:38.266662760 -0500` before and after) — no rewrite happened in the window.
- Not tested, with reason: forcing a token refresh would rotate/kill the operator's live subscription credential. A forced-refresh probe needs a sandbox credential (named blocker for the forced variant). Runner design rule from the observed evidence: mount `auth.json` read-write (or copy it into a container-local state dir) if sessions outlive one token lifetime.

- Verdict:
- Evidence:

**omp 18.7.0 (T-05, probe 2026-11-15) — Verdict: writable mount required for `~/.omp`; `agent.db` is opened read-write and a credential refresh needs that write.** Probe ladder, same image, host CLI mounted read-only:

1. Fully read-only `~/.omp` → omp dies before any model call: `EROFS: read-only file system, open '/root/.omp/run/daemons/ff5a3730bc4d03e6/clients/1-d0eafa48-f907-4894-b73f-2b8433de5f53.json'` (`errno: -30, code: "EROFS"`). The daemon client-registration write is mandatory at startup.
2. Read-only `~/.omp` + writable `run`, `logs`, `cache` → the turn completes (`"text":"PONG"`), session writes degrade with a written warning: `Session persistence failed: EROFS: read-only file system, open '/root/.omp/agent/sessions/-tmp-omp-probe-627/.2026-11-15T07-34-04-756Z_01…. Writes are retried; unsaved entries stay in memory until the store accepts them again.` and at exit `Session persistence is still failing at shutdown: … The session transcript is not durable; unsaved entries are lost.`
3. `agent.db` mounted read-only over an otherwise writable home → clean run, no EROFS at all: a model turn does not require the credential DB to be writable.
4. `agent.db` writable → the file **is** opened read-write: `sha256sum` went `d79928a2f0891dc9acb5d43fa1e85fa6502c253ae4e650ea0519a9a72e24909f` → `5eed7535ffc49be563d23bb99725228be94b7bf714875fce449ec088e22c888c` over two turns while row counts stayed flat (`model_usage 9`, `jobs 25`, `meta 0`) and `agent.db-wal`/`-shm` were rewritten — WAL/checkpoint bookkeeping, not app rows.
5. Refresh write need: the OAuth row in `auth_credentials` carries `created_at 1791772057`, `updated_at 1794723407` — the credential row is rewritten at runtime, so refresh cannot land on a read-only mount. A live refresh was not exercisable in-container: the OAuth-bearing MCP server needs the `docker` binary (`Warning: MCP server "github" failed to connect: Executable not found in $PATH: "docker"; its tools are unavailable for this run`).

Runner recipe that follows from this: mount `~/.omp` **writable**, with `~/.omp/natives/<version>/` read-only (365 MB, read-only is sufficient), and accept root-owned writes into bind-mounted host paths (see AC-5 item 4 hygiene).

### Fact 3 — Worktree at the same absolute path inside the container

<!-- SPEC-016 absolute-path semantics feed this probe. T-03/T-04/T-05 record per-host CLI evidence. -->

**Claude Code (T-03, probe 2026-11-15) — Verdict: supported.** The host repo is bind-mounted at its own host path, so the worktree sits at the identical absolute path inside the container, and the CLI session runs in it directly.

- Probe P-CON-B: the host worktree `/home/malcolm/vibes/claude-dev-team/.worktrees/CDT-627` mounted at that exact path inside the container; headless session ran `pwd; git branch --show-current` → `/home/malcolm/vibes/claude-dev-team/.worktrees/CDT-627` + `feat/CDT-627` (same-path identity, correct branch, SPEC-016 layout).
- The mount must cover the main repo root too (the worktree's `.git` file points at `<repo>/.git/worktrees/CDT-627`) — mounting only the worktree breaks git, matching the T-04 P-GK-CTR-8b finding. Host-side `git status` after every container probe showed the worktree clean (the only writes landed under the mounted `~/.claude`), so a read-only repo mount covers read-only probes.
- Plugin surface note (P-CON-C1): the Skill tool resolved `dev-team:status` from the worktree's own copy of the plugin (the ro-mounted repo) — no extra mount needed for the surface path.

**Grok (T-04)** — `supported`. A git worktree created inside the container lands at `.worktrees/<slug>` inside the project root and grok runs inside it at the same absolute path as the host would use.

- Probe (P-GK-CTR-5b, 2026-11-15): scratch repo bind-mounted read-write at `/tmp/grok-ctr-wt`; inside the container `git worktree add .worktrees/probe-ctr -b probe-ctr` → `Preparing worktree (new branch 'probe-ctr')`; `git worktree list` shows `/tmp/grok-ctr-wt/.worktrees/probe-ctr  63f73fe [probe-ctr]`; then `grok -p "Print only the absolute path of the current working directory and the current git branch." --always-approve --output-format json` inside the worktree returned `{"text":"/tmp/grok-ctr-wt/.worktrees/probe-ctr\nprobe-ctr",...}` — same absolute path inside the container, SPEC-016 layout.
- Caveat recorded on the way: git's `safe.directory` guard rejects bind-mounted host-uid repos when the container runs as root (`fatal: detected dubious ownership in repository at '/tmp/grok-ctr-wt'`, P-GK-CTR-5) — per-project setup must add `git config --global --add safe.directory <path>`.
- Related workspace finding (P-GK-CTR-8b): a linked worktree mounted alone is not a valid workspace in-container — `fatal: not a git repository: /home/malcolm/vibes/claude-dev-team/.git/worktrees/CDT-627` until the main repo's `.git` is also mounted at its host path. Mounting the main repo root and the worktree at their host paths resolves it (`git rev-parse --show-toplevel` → the CDT-627 path, branch `feat/CDT-627`).

- Verdict:
- Evidence:

**omp 18.7.0 (T-05, probe 2026-11-15) — Verdict: supported, with one git prerequisite.** The repo is bind-mounted at its own host path and the plugin contract is exercised in-container:

```
docker run --rm -w /tmp/omp-c627-repo -v /home/malcolm:/home/malcolm:ro -v /tmp/omp-c627-repo:/tmp/omp-c627-repo <image> \
  bash -c 'apt-get install -y git ca-certificates; git config --global --add safe.directory /tmp/omp-c627-repo; \
           WT=/home/malcolm/.claude/plugins/marketplaces/cold-dark-void/skills/worktree-lib.sh; \
           bash "$WT" ensure c627c; cd /tmp/omp-c627-repo/.worktrees/c627c && pwd && git rev-parse --abbrev-ref HEAD && git rev-parse --show-toplevel; \
           bash "$WT" release c627c'
```

Output: `Preparing worktree (new branch 'feat/c627c')` / `/tmp/omp-c627-repo/.worktrees/c627c` (exit 0) → `pwd` `/tmp/omp-c627-repo/.worktrees/c627c`, branch `feat/c627c`, toplevel identical → `release` exit 0; the host confirms `git worktree list` shows only the main repo and branch `feat/c627c` is deleted. SPEC-016 placement (`.worktrees/<slug>` inside the project root) and path identity both hold, and the omp session cwd-slug (`~/.omp/agent/sessions/<cwd-slug>/`) is the same in-container as on the host — that is what makes the native session resumable (Fact 1 / AC-6 P-OMP-C-A). Prerequisite: the container user is root and the repo is uid 1000, so git refuses until `git config --global --add safe.directory <path>` (observed verbatim: `fatal: detected dubious ownership in repository at '/tmp/omp-c627-repo'`); `--user`-matched runs avoid it. Artifacts the container writes are root-owned, so cleanup needs root: `error: failed to delete '/tmp/omp-c627-repo/.worktrees/c627c': Permission denied`.

### Fact 4 — Per-project runner image toolchain needs

<!-- T-03/T-04/T-05 record the per-host CLI toolchain rows. -->

**Claude Code (T-03, probe 2026-11-15) — Verdict: minimal; the approved set covers the CLI and the probes; the plugin's own engine deps are the T-05 list.** The CLI ships as a single dynamically linked native binary that needs nothing beyond glibc — `ldd /home/malcolm/.local/share/claude/versions/2.1.325` resolves only `libc.so.6`, `libdl.so.2`, `libm.so.6`, `libpthread.so.0`, `librt.so.1` — no Node runtime, no runtime install inside the image. The binary is bind-mounted read-only into the container and `claude --version` → `2.1.325 (Claude Code)` works immediately.

- Commands actually run inside the approved image (three separate probe containers): `apt-get update -qq` then `DEBIAN_FRONTEND=noninteractive apt-get install -y -qq git curl ca-certificates` — all three install cleanly and cover the probe set.
- `git` was required by the AC-5 worktree and status items (and the status engine `skills/worktree-lib.sh status` — P-CON-C1 ran it in-container). `curl`/`ca-certificates` were needed for the network probe (Fact 5); the CLI's own API egress worked over TLS in a bare image too (P-CON-1 ran before any apt call and reached the API).
- Per-project toolchain gap observed in-container: the plugin's memory path needs `sqlite3` — the host binary mounted read-only failed on `libreadline.so.8: cannot open shared object file` (P-CON-M; `libreadline8` is not in the approved package set). Matches the T-05 plugin-dep list (`jq`, `sqlite3`, `docker`) — those are runner-image decisions for CDT-626, not probe packages.
- Session state needs no extra toolchain: `~/.claude` mounted rw held transcripts (`~/.claude/projects/<cwd-slug>/<session-id>.jsonl`), which is what makes P-CON-A resume work.

**Grok (T-04)** — minimal. The probe base image `debian:trixie-slim` (approved digest, G-02 row 1) plus `apt-get install git curl ca-certificates` (pre-approved in the gate record) covered every probe. The CLI itself ships as a single statically linked binary (`file ~/.grok/bin/grok` → `grok-1.0.77-linux-x86_64: statically linked`), bind-mounted read-only into the container — no runtime install inside the image.

- Per-project toolchain needs observed: `git` (worktrees, status surfaces — with the `safe.directory` config note from fact 3), `curl` + `ca-certificates` (only used for the network probe itself; the CLI worked without them), nothing else. Plugin surfaces resolved from the ro-mounted `~/.grok/marketplace-cache` (P-GK-CTR-6) — no additional packages.
- Model routing inside the container came from the ro-mounted `~/.grok/config.toml`; the routed model in-container was the subscription model (`grok-4.7-build` in the usage payloads) plus the local-provider aliases from the config.

- Verdict:
- Evidence:

**omp 18.7.0 (T-05, probe 2026-11-15) — Verdict: named list; the approved set covers the CLI, the plugin surface needs more.** The omp binary itself needs nothing beyond glibc — `ldd /usr/sbin/omp` in `trixie-slim` resolves only `libc.so.6`, `libpthread.so.0`, `libdl.so.2`, `libm.so.6`, `/lib64/ld-linux-x86-64.so.2`, and `omp --version` → `omp/18.7.0`. No Node runtime, no apt package is required to run omp. Installed from the pre-approved set: `git version 2.47.3`, `curl 8.14.1 (x86_64-pc-linux-gnu) … OpenSSL/3.5.7`, `ca-certificates 20250419+deb13u1` (all three install cleanly via `apt-get update && apt-get install -y -qq`). Needs outside the approved set, each with the failure reproduced in-container and each therefore a runner-image decision for CDT-626 (not installed by this probe): `jq` — the plugin engines and the decision-card writer hard-fail without it (`error: jq not found; cannot write decision card`, exit 64; `rollup: jq not found; cannot aggregate metrics`; `dag-lib ready-set` exit 64 `error: jq is required but not found in PATH`); `sqlite3` — `bash: line 1: sqlite3: command not found`, blocks the plugin-side SQLite memory path (omp's own memory backend needs no sqlite3 CLI); `docker` — MCP servers configured as containers cannot start (`Warning: MCP server "github" failed to connect: Executable not found in $PATH: "docker"`). Host-parity note: the omp native add-on tree `~/.omp/natives/18.7.0/pi_natives.linux-x64-{modern,baseline}.node` (365 MB) must be present in the container; every probe mounted it read-only. The host also ships a `jaq 2.3.0` shim as `jq`, which the plugin's own version probe already rejects — an image that installs real `jq` behaves differently from the host here, so pin the package name in the runner image.

### Fact 5 — Local model endpoints reachable over the container network

<!-- T-03/T-04/T-05 record the per-host CLI probe evidence. -->

**Claude Code (T-03, probe 2026-11-15) — Verdict: remote/TLS egress works on the default bridge; host-loopback endpoints are not reachable from the bridge and need `--network host`.** Same image, `curl` + `ca-certificates` installed:

| Endpoint | Attempt | Result |
|---|---|---|
| `https://api.anthropic.com/api/hello` (the CLI's own API host) | `curl -s -m 10 -o /dev/null -w "%{http_code}"` from the default bridge | Reachable — `200` (TLS egress + CA trust work; the CLI's model calls also succeeded in every probe on the default bridge) |
| ollama, container loopback | `curl -s -m 5 http://127.0.0.1:11434/api/version` | Not reachable — container-local loopback (`FAIL`) |
| ollama, docker bridge gateway | `curl -s -m 5 http://172.17.0.1:11434/api/version` | Not reachable — `FAIL` at probe time (host `ss -tln` shows `*:11434` LISTEN; compare the T-04/T-05 gateway probes, which timed out the same way) |
| ollama, `--network host` | `curl -s -m 5 http://127.0.0.1:11434/api/version` | Reachable — `{"version":"0.40.16"}` |
| omp gateway alias on `127.0.0.1:8082` | `curl -s -m 5 http://127.0.0.1:8082/v1/models` with `--network host` | Not reachable — `000`/`FAIL` (nothing serving on that port at probe time) |

Runner rule (matches the T-04/T-05 finding): a container Runner reaches remote model endpoints out of the box; any host-loopback local-model endpoint needs `--network host` (the `host-gateway` alias route timed out from this host's bridge in the T-04/T-05 probes as well).

**Grok (T-04)** — LAN endpoints reachable, host-loopback endpoints not. Probed from inside the container (P-GK-CTR-1, 2026-11-15, `curl -sS -m 5 -o /dev/null -w "%{http_code}"` after `apt-get install curl ca-certificates`):

| Endpoint (from `~/.grok/config.toml`) | Result from container net | Verdict |
|---|---|---|
| `http://spark.4283929.xyz:9236/v1/models` (host-resolves to `192.168.1.3`) | `200` | reachable |
| `http://studio.4283929.xyz:9236/v1/models` (host-resolves to `192.168.1.7`) | `200` | reachable |
| `http://localhost:9234/v1/models` (host listens on `*:9234`) | `curl: (7) Failed to connect` — container-local loopback | not reachable |
| `http://172.17.0.1:9234/v1/models` (docker0 gateway) | `curl: (28) Connection timed out` | not reachable |

- Runner rule: LAN-hosted model endpoints work from the default bridge network; anything bound to the host loopback needs `--add-host=host.docker.internal:host-gateway` plus a firewall allowance (the gateway probe timed out on this host), or `--network host`.

- Verdict:
- Evidence:

**omp 18.7.0 (T-05, probe 2026-11-15) — Verdict: remote gateways reachable; host-local endpoints are not reachable on the default bridge and need `--add-host=host.docker.internal:host-gateway`.** Five endpoints from inside the approved image:

| Endpoint | Attempt | Result |
|---|---|---|
| `spark-tf` (remote gateway, `http://spark.4283929.xyz:9236/v1`) | `curl -sS -m 10 http://spark.4283929.xyz:9236/v1/models` | Reachable — `{"object": "list", "data": [{"id": "qwen3.8-27b-8x256k-mlx4-kv8-dflash2", …`; every probe model call in this file ran on `spark-tf/glm5.3-flash-320b-a18b-8x512k-exl3-kv8-dflash2-tp2` |
| `studio-tf` (remote gateway, `http://studio.4283929.xyz:9236/v1`) | same, that host | Reachable — `{"data":[{"est_footprint_gib":195,"id":"glm5.3-flash-320b-a18b-8x512k-oq4-kv8-mtp","loaded":false,… [http=200]` |
| ollama, in-container loopback | `curl -sS -m 10 http://localhost:11434/api/version` | Not reachable — `curl: (7) Failed to connect to localhost port 11434 after 0 ms: Could not connect to server [http=000]` (host `ss -ltn` shows `*:11434` LISTEN, so the gap is the netns, not the service) |
| ollama, docker bridge gateway | `curl -sS -m 10 http://172.17.0.1:11434/api/version` | Not reachable — `curl: (28) Connection timed out after 10002 milliseconds [http=000]` |
| ollama, host gateway alias | `--add-host=host.docker.internal:host-gateway` + `curl … http://host.docker.internal:11434/api/version` | Reachable — `{"version":"0.40.8"} [http=200]` |

Consequence for the adapter: a container Runner needs the `host-gateway` alias (or `--network=host`) for any local-model provider, and `models.yml` `baseUrl` entries that say `localhost` must be rewritten for the container. Model pinning is mandatory: bare `omp -p` resolves to `ollama/laya…` and in-container fails `"errorMessage":"Unable to connect. Is the computer able to access the url?"` (on the host the same default fails `400 "laya:latest" does not support chat`). `spark-tf`/`studio-tf` need no rewrite — they are remote HTTP with `"auth": "none"`.

## AC-9 (container half) — Container credential evidence rows

Per host: (a) the auth method in the runner (API key / OAuth token / subscription login), (b) where the secret lives (env var name, mounted file path, host keyring), (c) whether it survives a container restart. Flag hosts that need an interactive browser login with the one-time operator step.

### Claude Code container credentials

<!-- T-03 owns this section. -->

**Claude Code 2.1.325, container Runner (probed 2026-11-15, image `debian:trixie-slim@sha256:a72b4433de1cf7d6bae0c4cee74d0547f58601a643b3375f070c51600d63b6b2`, G-02 row 1).**

- (a) **Auth method in the runner:** subscription login — the OAuth token cached by the host CLI in `~/.claude/.credentials.json` (the `claudeAiOauth` account entry). No API key and no env-var secret were set on any probe run; every authed call used the mounted token file.
- (b) **Where the secret lives:** mounted file — host `~/.claude/.credentials.json` bind-mounted read-only at its host path inside the container (`-v /home/malcolm/.claude/.credentials.json:/home/u/.claude/.credentials.json:ro`, with `HOME=/home/u` on a scratch bind mount so the CLI finds it at `$HOME/.claude/.credentials.json`). Supporting mounts: `~/.claude` read-write (transcripts under `~/.claude/projects/`, plugin/skill discovery, settings) and `~/.claude.json` (copied into the scratch HOME — project trust state). Values were never printed in any probe output. No env var is involved on this path, and no host keyring is used.
- (c) **Survives a container restart:** yes — observed directly. P-CON-STEER created a session and wrote its transcript from one container; P-CON-A resumed that same session by id from a brand-new container and the auth worked with zero operator action (`RESUME_EXIT:0`, token `STEER-CON8-44` returned). The credential and session state live on the host volume; a restarted container re-mounts both unchanged. A container started without the mount is unauthenticated.
- One-time operator step (interactive login): host-side only — run `claude` on the host and complete the OAuth browser login once; containers then mount the resulting `.credentials.json`. No interactive login is needed inside the container itself. Token refresh inside long-lived containers needs a writable mount (AC-6 fact 2): mount `.credentials.json` read-write, or copy it into a container-local state dir.

### Grok container credentials

<!-- T-04 owns this section. -->

Probed 2026-11-15 (grok 1.0.77 in container; approved image `debian:trixie-slim@sha256:a72b…6b2`; all evidence under the Grok container probe transcripts in `host-capability-matrix.md`).

- (a) **Auth method in the runner:** subscription login — the OAuth/session token cached in `~/.grok/auth.json`. The ACP `initialize` result names it: `"authMethods":[{"id":"cached_token","description":"Cached token from ~/.grok/auth.json"},{"id":"grok.com","description":"Sign in with Grok"}]` — `cached_token` is the default (`defaultAuthMethodId":"cached_token"`). The alternative `grok.com` method is the interactive browser login.
- (b) **Where the secret lives:** mounted file — host `~/.grok/auth.json` bind-mounted read-only at `/root/.grok/auth.json` in every probe container. Supporting mounts: `~/.grok/auth.sh` (the `auth_provider_command` for local model providers; prints a stub token — no secret) and `~/.grok/config.toml` (model routing) — both read-only. No env-var secret is required. Values were never printed in any probe output.
- (c) **Survives container restart:** yes — observed across nine independent `docker run --rm` containers (P-GK-CTR-1 … P-GK-CTR-8c, 2026-11-15); each container instance authenticated from the same mounted host file with zero auth failures. The credential state lives on the host volume, so a restarted container re-mounts it unchanged.
- One-time operator step: host-side only — run `grok` and complete the `grok.com` browser login once on the host; containers then mount the resulting `auth.json`. Token refresh within long-lived containers needs a writable mount (AC-6 fact 2): mount `auth.json` read-write, or copy it into a container-local state dir.
- Interactive-login flag: no interactive login is needed inside the container itself.

### omp container credentials

<!-- T-05 owns this section. -->

**omp 18.7.0, container Runner (probed 2026-11-15, image `debian:trixie-slim@sha256:a72b4433de1cf7d6bae0c4cee74d0547f58601a643b3375f070c51600d63b6b2`, G-02 row 1).**

- **(a) Auth method in the runner:** per-provider credentials held by omp itself, plus an optional auth-broker. This box's probe model needs no secret at all: the `spark-tf` and `studio-tf` providers are declared `"api": "openai-completions"`, `"auth": "none"` in `~/.omp/agent/models.yml`, so the container authenticates nothing. Subscription login exists as a first-class path — `omp auth-broker [ACTION] [SOURCE]` with ACTION ∈ `serve|token|login|logout|import|migrate|status|list` — and `auth-broker list` inside the container enumerated the subscription providers (`openai-codex`, `anthropic`, `zai`, `zai-coding-plan`, `kimi-code`, `openrouter`, `github-copilot`, `cursor`, `devin`, `google-antigravity`). No broker is active: `omp auth-broker status` → `No auth-broker configured (set OMP_AUTH_BROKER_URL to enable).`, identical in-container and on the host.
- **(b) Secret location:** the mounted file `~/.omp/agent/agent.db`, table `auth_credentials` (columns `id, provider, credential_type, data, disabled_cause, identity_key, created_at, updated_at`; rows here `llama.cpp|api_key`, `mcp_oauth:profile:default:https://mcp.linear.app/mcp|oauth`). No env var is involved on the gateway path, and no host keyring is used. Probe mount: `-v /tmp/omp-c627-home/.omp/agent/agent.db:/root/.omp/agent/agent.db:ro` (a copy — the live `~/.omp` is never mounted). Provider base URLs are non-secret and live in `~/.omp/providers.json` + `models.yml`.
- **(c) Survives a container restart:** yes for mounted state, no for container state. Credentials and sessions are host-side files, so a fresh container re-reads them: a brand-new container resumed a session written by an earlier container off the writable mount (`{"type":"session","version":3,"id":"01a1de23-6268-77dc-9abf-21a6e92d7d0a",…}` → `"text":"RESUME-OK"`). A container started **without** the mount begins from an empty `~/.omp` and is unauthenticated. Writes need a writable mount (Fact 2), and a root container writes root-owned files into the bind-mounted host paths — record the uid, or run `--user`-matched, before the host operator has to clean up.
- **One-time operator step (interactive login):** needed only for subscription providers. Run `omp auth-broker login <provider>` once with a **writable** `~/.omp` mount; the OAuth/device flow is the browser step, and its refreshed token must be able to rewrite `auth_credentials` (Fact 2 item 5). The gateway path used by these probes has no operator step.

## CDT-647 — the container runner is real (phase 1, C8)

Everything above is the phase-0/AC-9 record and is unchanged. C8 (CDT-628 C8,
2026-11-17) turns these facts into the second runner type the node agent runs:
`control-plane/agent/container.go`, the `container` selection token of
`agent.KnownRunners`. The native runner stays first in the set and the default
once selected.

### The session image — named and digest-pinned

The runner references exactly one image, as the constant `agent.SessionImage`:

| Property | Value |
|---|---|
| Reference | `docker.io/library/debian:trixie-slim@sha256:a72b4433de1cf7d6bae0c4cee74d0547f58601a643b3375f070c51600d63b6b2` |
| Source repo | `github.com/debuerreotype/docker-debian-artifacts` — the official Docker Library `debian` image |
| Official status | Official Docker Library; maintained by Docker Inc. with Debian |
| Maintenance | Active (Debian trixie, current stable) |
| Root vs non-root | Root by default — the runner's prelude uses root for the package install only, then drops the session to the host uid with `setpriv` |
| G-02 record | Row 1 of the CDT-627 approval — approved by the maintainer 2026-11-15 for the probe work that produced every fact in this file |

The pin shape is enforced at init: `agent.digestPinned` panics at load when the
constant stops carrying `@sha256:<64 hex>`, so an unpinned edit fails at build
time, not at first pull. The image was pulled once by the phase-0 probes under
the G-02 row-1 approval; C8's live runner verification ran against the same
pulled digest and pulled it no further times beyond that approval. **Its
promotion from probe evidence to a product surface is presented at the G-02
gate with the evidence table above** — the AC-10 guard named probe images as
evidence-only for phase 0, and CDT-647 moves this reference into product code.
Presentation record: presented 2026-11-18 (UTC) inside the CDT-647 ship flow —
image, source repo (official Docker Library `debian`), maintenance status
(active, trixie current stable), digest pin, and root/non-root posture all
stated; no new pull is required (the digest is already on the node from the
approved probes), and no objection was raised in the session that carries the
epic's full-autopilot standing directive.

### The invocation — one container per run, no socket

`Container.Start` builds one `docker run --rm -i --init --name
devteam-run-<run-id>` invocation and guards it. The guard
(`agent.guardSessionArgv`) runs on the Docker-controlled half of every argv
before Docker is exec'd and refuses: any mount that names `docker.sock` or
`/var/run`, `--group-add`, `--privileged`, `--pid=host`, `--userns=host`, and
`--network=host`. The session's own argv — the half after the image — is
untrusted data and is never scanned: a message that mentions a socket path is
text, not a flag. The node agent holds the Docker socket and execs the Docker
CLI; the session container never receives either.

The mount set, each point sourced from this file:

| Mount | Mode | Source of the rule |
|---|---|---|
| The run's worktree at its host path | rw | Fact 3 — same absolute path inside the container |
| The main repo root at its host path | rw | Fact 3 P-GK-CTR-8b — mounting only the worktree breaks git |
| The host CLI's session state (`~/.claude`, `~/.claude.json`, `~/.grok`, `~/.omp`, keyed by the CLI basename) | rw | Fact 2 — token refresh targets the same file; the B6 conservative rule for the unprobed forced-refresh case mounts writable rather than widening behavior |
| The host CLI binary at `/usr/local/bin/<cli>` | ro | Fact 4 — single glibc-only native binary, bind-mounted read-only |

`HOME` inside the container is the host home path, so the host-relative
credential paths resolve identically (the AC-9 container rows). The container
is started with the default bridge network — Fact 5's runner rule: remote
model endpoints work out of the box, and no `--network host` or
`host-gateway` widening is added beyond what the probe facts support.

### The prelude — the gate record's package set

The image is bare, and the session's repo work needs git (Fact 4). Before the
session execs, the container runs one fixed prelude: `apt-get update -qq &&
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq git curl
ca-certificates && exec setpriv --reuid=<uid> --regid=<gid> --clear-groups
"$@"`. The package set is exactly the set the G-02 row-1 record pre-approved
in this image; nothing else is installed. Root runs only the install; the
session then runs as the host user, so the container's writes into the
mounted host paths land host-user-owned (AC-5 item-4 hygiene) and git's
`safe.directory` guard never fires (Fact 3). The session command travels as
argv after the script — the `exec "$@"` tail — so no untrusted text is ever
assembled into the shell string.

Cost, stated plainly: every run installs the pre-approved package set over
the network (observed ~13-15 s on this node). An apt failure fails the run
with a visible exit code and the machine's retry budget applies.

### The contract, unchanged

- **start** — one container per run, named `devteam-run-<run-id>`; the
  supervised process is the Docker client that owns the container, so the
  PID, the output streams, and the exit are the client's.
- **steer** — the client's stdin pipe is the container's stdin; the control
  message travels as data, unchanged from the native runner. Verified live:
  a steer written after container start is read by the session (§
  verification below).
- **stop** — `docker stop -t <grace>`: SIGTERM to the container's init,
  SIGKILL after the grace — the same TERM-then-KILL contract, at the
  container boundary. Verified live: a `trap` on TERM fires inside the grace.
- **status** — the pidfile records the Docker client's PID plus the
  container name; the container's liveness is Docker's own
  `docker inspect -f {{.State.Running}}` reading, not the client's PID.
- **resume and adoption** — a container outlives its client process, so the
  pidfile carries the container name and the adoption policy probes and
  stops the orphan by name. The run's journal trail is the C2 machine's,
  reused unchanged.
- **death of the container** — the client exits with the container's exit
  code; the agent's supervise loop treats it exactly like a native runner
  exit, and a re-spawned run resumes over the mounted paths. Verified live:
  state the first container writes into the mounted worktree is the second
  container's starting state.

### Verification (2026-11-17)

Hermetic (G-02 image, no Docker needed): `go test ./agent/ ./killtest/` —
the plan/guard tests, the selection table, and the container-selected CI kill
lane (`TestContainerRunnerSelectedRunsTheKillTest`).

Live (on the node, against the pinned G-02 row-1 image only):

```text
--- PASS: TestContainerRunnerStartSteersAndStopsLive (12.47s)
--- PASS: TestContainerSessionNeverSeesTheDockerSocketLive (12.40s)
--- PASS: TestContainerResumeSurvivesDeathOverTheMountedPathsLive (24.51s)
```

- `TestContainerRunnerStartSteersAndStopsLive` — start tracked the container,
  the steer reached the session over stdin, and `docker stop -t 5` delivered
  TERM that a trap in the session caught inside the grace.
- `TestContainerSessionNeverSeesTheDockerSocketLive` — the session observed
  the socket absent from its own mount namespace.
- `TestContainerResumeSurvivesDeathOverTheMountedPathsLive` — state the first
  container wrote into the mounted worktree was the second container's
  starting state, with no host action in between (the AC-9 restart rows).

No unapproved image was pulled or run: the live verification used only the
row-1 digest above.

### Operator recipe — a containers-only node

1. Log the host CLIs in on the host (`claude`, `grok`, or `omp`), once. The
   container mounts the resulting state files; there is no login inside the
   container (Fact 1, the AC-9 container rows).
2. Keep the Docker CLI on the agent's PATH. The node agent is the only
   holder of the Docker socket — no socket mount, no Docker group.
3. Select the runner: set `"runner": "container"` in
   `$MROOT/.claude/dev-team/node.json` (record-ownership row 14), or
   `$DEVTEAM_RUNNER=container` for one invocation. No plugin-side change is
   needed — the token is the same C4 selection surface, and the closed set
   now admits `container`.
4. Start as usual: `node-agent start --run-id … --command claude …`. The
   container gets the run's worktree at its host path, the session state at
   its host path, and nothing else.
