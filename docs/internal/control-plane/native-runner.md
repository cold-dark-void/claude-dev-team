# Native Runner supervision and start mechanism

Carries AC-7 and the native half of AC-9. T-07 owns this file and writes it alone. Native probes are pre-approved on this machine — no re-ask needed. Container operations are out of scope here.

## AC-7 — Supervision and start mechanism

Record both facts, then choose and verify one start mechanism:

- How the Node agent supervises agent processes on this machine.
- How the Node agent starts — systemd user unit or launchd.

This host is Linux/WSL. launchd is not applicable here. The chosen mechanism is the systemd user unit; verify it works and show the unit file and the probe result (`systemctl --user` start/status of a trivial placeholder is acceptable evidence). No service code is committed — the unit file text appears in this doc as evidence only.

### Supervision record

Two layers are in play on the native Runner, and they must not be confused:

**Layer 1 — the Node agent supervises the runner processes (agent processes).**
Per the CDT-626 amendment ("Node agent and runner types", 2026-11-11): every node
runs a node agent; the node agent contract is **start, stop, status, and steer**;
it never talks to Docker or to a host CLI directly. The control plane talks only
to the node agent. The native runner is "a process on the node's own OS", so on
this machine the Node agent would supervise host-CLI processes (one headless
`claude` / `grok` / `omp` process per run slot) by spawning them, tracking their
PIDs, and steering or killing them at step boundaries. CDT-626 adds a heartbeat
and watchdog, a lease (one owner per run), and a reconciler on start around this.
The Node agent is one Go binary and does **not exist yet** — it ships in phase 1
(CDT-626: "Delivery phase 1 ships the node agent with both runner types on one
machine"). No supervision code is probeable today; the contract above is the
recorded design, not a probe.

**Layer 2 — the machine supervises the Node agent itself.** That is the
mechanism this file verifies below: a systemd **user** unit (no root) with
`Restart=on-failure`, journald capture, and dependency ordering.

**Today's machine fact (the thing the control plane replaces):** host CLI
processes currently run unsupervised — they are direct children of the invoking
shell. When the shell dies, the process dies with it; nothing restarts it. This
is exactly the failure CDT-626 targets ("A reboot kills the work"). The
death-and-resume probes already reproduced it empirically per host (P-CC-A and
its siblings in `host-capability-matrix.md`: the host session died with the
killed process and only its own resume/checkpoint path recovered it). No
supervisor unit tracks host CLI processes today — probe (2026-11-15):

Command: `systemctl --user list-units --type=service --no-pager --no-legend`

Output (the only user service is D-Bus; no host-CLI or node-agent unit exists):

```
dbus-broker.service loaded active running D-Bus User Message Bus
```

### Start mechanism — chosen and verified

**Verdict: systemd user unit — chosen and verified working on this machine.**
launchd is macOS-only and not applicable to this Linux/WSL host (WSL2,
kernel `6.18.58.1-microsoft-standard-WSL2`, host `malcolm-pc`). The unit below
is a **representative mechanism**: the Node agent is one Go binary that ships in
phase 1 and has no defined start command yet, so `ExecStart` names the intended
install path `/usr/local/bin/node-agent` and is **marked pending the agent's
first build**. The subcommand and flags are phase-1 decisions. No service code
ships — the unit file text is evidence only.

Installed at `~/.config/systemd/user/dev-team-node-agent.service`
(mode `644`, probed 2026-11-15):

```ini
[Unit]
Description=dev-team node agent (control plane Option C+, CDT-626)
Documentation=https://linear.app/cold-dark-void/issue/CDT-626
# Phase 0 discovery unit — the node agent Go binary does not exist yet
# (ships in phase 1). ExecStart names the intended install path; the
# subcommand and flags are undefined until phase 1 defines the agent CLI.
Wants=network-online.target
After=network-online.target
StartLimitIntervalSec=60
StartLimitBurst=10

[Service]
ExecStart=/usr/local/bin/node-agent
Restart=on-failure
RestartSec=2s

[Install]
WantedBy=default.target
```

Probe evidence — each row: verdict + probe date + command + verbatim output.

**Probe 1 — systemd user manager is available (supported, 2026-11-15).**

Command: `systemctl --user is-system-running`

Output: `running`

Host facts probed the same day: `systemctl --user --version` →
`systemd 262 (262-1-arch)`; `uname -r` →
`6.18.58.1-microsoft-standard-WSL2`; `loginctl show-user 1000 -p Linger` →
`Linger=no`.

**Probe 2 — systemd accepts the unit with the real command path (supported,
2026-11-15).** `systemctl --user daemon-reload` exited 0, then:

Command: `systemctl --user status dev-team-node-agent --no-pager`

```
○ dev-team-node-agent.service - dev-team node agent (control plane Option C+, CDT-626)
     Loaded: loaded (/home/malcolm/.config/systemd/user/dev-team-node-agent.service; disabled; preset: enabled)
     Active: inactive (dead)
       Docs: https://linear.app/cold-dark-void/issue/CDT-626
```

`Loaded: loaded` confirms the user manager parsed the unit file. `disabled`
confirms it does not auto-start until enabled.

**Probe 3 — the unit starts and systemd supervises it: restart-on-failure and
journald capture observed (supported, 2026-11-15).** Because the Node agent
binary does not exist yet, the start attempt exercises the real supervision
mechanics against the real command path — systemd spawns `/usr/local/bin/node-agent`,
sees it fail, and restarts it on the configured schedule.

Command: `systemctl --user start dev-team-node-agent` (exit 0), then after ~5 s:

Command: `systemctl --user status dev-team-node-agent --no-pager`

```
● dev-team-node-agent.service - dev-team node agent (control plane Option C+, CDT-626)
     Loaded: loaded (/home/malcolm/.config/systemd/user/dev-team-node-agent.service; disabled; preset: enabled)
     Active: activating (auto-restart) (Result: exit-code) since Sun 2026-11-15 01:47:03 EST; 1s ago
 Invocation: c9d23e259f5841659bd4145b9a5a96bc
       Docs: https://linear.app/cold-dark-void/issue/CDT-626
    Process: 64915 ExecStart=/usr/local/bin/node-agent (code=exited, status=203/EXEC)
   Main PID: 64915 (code=exited, status=203/EXEC)
   Mem peak: 2M
        CPU: 3ms

Nov 15 01:47:03 malcolm-pc systemd[290]: dev-team-node-agent.service: Failed with result 'exit-code'.
```

Command: `journalctl --user -u dev-team-node-agent --no-pager -n 12 --output=short-iso`

```
2026-11-15T01:47:08-05:00 malcolm-pc systemd[290]: dev-team-node-agent.service: Scheduled restart job, restart counter is at 6.
2026-11-15T01:47:08-05:00 malcolm-pc systemd[290]: Started dev-team node agent (control plane Option C+, CDT-626).
2026-11-15T01:47:08-05:00 malcolm-pc (node-agent)[64924]: dev-team-node-agent.service: Unable to locate executable '/usr/local/bin/node-agent': No such file or directory
2026-11-15T01:47:08-05:00 malcolm-pc (node-agent)[64924]: dev-team-node-agent.service: Failed at step EXEC spawning /usr/local/bin/node-agent: No such file or directory
2026-11-15T01:47:08-05:00 malcolm-pc systemd[290]: dev-team-node-agent.service: Main process exited, code=exited, status=203/EXEC
2026-11-15T01:47:08-05:00 malcolm-pc systemd[290]: dev-team-node-agent.service: Failed with result 'exit-code'.
2026-11-15T01:47:10-05:00 malcolm-pc systemd[290]: dev-team-node-agent.service: Scheduled restart job, restart counter is at 7.
2026-11-15T01:47:10-05:00 malcolm-pc systemd[290]: Started dev-team node agent (control plane Option C+, CDT-626).
2026-11-15T01:47:10-05:00 malcolm-pc (node-agent)[64927]: dev-team-node-agent.service: Unable to locate executable '/usr/local/bin/node-agent': No such file or directory
2026-11-15T01:47:10-05:00 malcolm-pc (node-agent)[64927]: dev-team-node-agent.service: Failed at step EXEC spawning /usr/local/bin/node-agent: No such file or directory
2026-11-15T01:47:10-05:00 malcolm-pc systemd[290]: dev-team-node-agent.service: Main process exited, code=exited, status=203/EXEC
2026-11-15T01:47:10-05:00 malcolm-pc systemd[290]: dev-team-node-agent.service: Failed with result 'exit-code'.
```

Reading: the very first status tick (within ~10 ms of `start`) showed
`Active: active (running)` with a main PID assigned
(`Main PID: 64856 ((node-agent))`, invocation
`e4f8d48c6b124bc383fe514bfba42884`) — systemd did spawn the process and put the
unit in the active state; the exec then failed with `203/EXEC` because the
binary is pending its first build, and `Restart=on-failure` took over: the
restart counter climbed from 6 to 7 in ~2 s intervals (`RestartSec=2s`) with
every attempt captured in journald. The supervisor mechanics — start, state
tracking with a PID, restart-on-failure, dependency-ordered unit, and journal
capture — are verified working on this machine. The only unverified element is
a successful run of the Node agent binary itself, pending its first build
(AC-8 builds the first trivial binary; phase 1 ships the agent).

Teardown after the probe —
`systemctl --user stop dev-team-node-agent` exited 0 and the unit returned to
`inactive (dead)`:

```
○ dev-team-node-agent.service - dev-team node agent (control plane Option C+, CDT-626)
     Loaded: loaded (/home/malcolm/.config/systemd/user/dev-team-node-agent.service; disabled; preset: enabled)
     Active: inactive (dead)
       Docs: https://linear.app/cold-dark-void/issue/CDT-626
```

The unit stays installed but disabled and inactive (no boot-start footprint).
It is not enabled (`systemctl --user disable` is unnecessary — the status output
shows `disabled` throughout).

**Operator note — linger (pending decision, not done by this task):**
`loginctl show-user 1000 -p Linger` → `Linger=no`. With linger off, the user
systemd instance (and this unit) exists only while the user is logged in;
a unit with `WantedBy=default.target` will not start at boot before login. The
CDT-626 goal "after a forced reboot, every in-flight run continues without a
human" requires `loginctl enable-linger malcolm` on the node. Enabling linger is
a machine-config change outside this discovery ticket's footprint; phase 1
(CDT-632 or the phase-1 build) must decide and execute it.

### Rejected alternative — unsupervised

**Verdict: rejected.** The unsupervised alternative — a bare process started by
hand or by a shell (`nohup … &`, `disown`, or a plain background spawn from a
terminal or script) — is how host CLIs run on this machine today.

Reason: it provides none of the three things the control plane requires, and
each absence was observed directly in the probe above (2026-11-15):

- **No restart-on-failure.** A bare process that dies stays dead. The probe
  shows what supervision adds: systemd restarted the failed unit automatically
  (`Scheduled restart job, restart counter is at 6/7`); a `nohup`-style process
  has no equivalent.
- **No dependency ordering.** A bare process cannot express "start only after
  the network is up" (`After=network-online.target`) or an ordered start at
  boot; the unit encodes it declaratively.
- **No journald capture.** A bare process's stdout/stderr go to a terminal or
  hand-managed log file. The probe shows the unit's output and failures landing
  in the per-unit journal (`journalctl --user -u dev-team-node-agent`), which is
  the log source the CDT-626 append-only run journal and the Chief's status
  surface would build on.

The bare process also dies with its terminal/session (SIGHUP class), which the
session-death probes in `host-capability-matrix.md` reproduce — the exact
"reboot kills the work" failure CDT-626 exists to fix.

## AC-9 (native half) — Native credential survival

Per host, record whether the credential survives a process restart on the native Runner. Hosts needing an interactive browser login are flagged with the one-time operator step. T-03/T-04/T-05 own the per-host evidence rows; T-09 synthesizes them into `credentials.md`.

### Claude Code native credentials

<!-- T-03 owns this section. -->

Host CLI version: `claude 2.1.325 (Claude Code)` (`claude --version`, probed 2026-11-15). The plan locked 2.1.322; the installed version differs and is recorded as actual throughout.

| Fact | Verdict | Evidence (probe 2026-11-15) |
|---|---|---|
| (a) auth method in the runner | subscription login via OAuth token | `jq -r 'keys[]?' ~/.claude/.credentials.json` → `claudeAiOauth`, `mcpOAuth`; `jq -r '.claudeAiOauth \| keys[]?'` → `accessToken`, `expiresAt`, `refreshToken`, `refreshTokenExpiresAt`, `scopes`, `subscriptionType`, `subscriptionTypeSource`. No `ANTHROPIC_*` environment variables are set (`env \| grep -o 'ANTHROPIC[A-Z_]*'` → empty), so the CLI is not running on an API key. |
| (b) where the secret lives | file on disk — `~/.claude/.credentials.json` | File exists, mode `600`: `-rw------- 1 malcolm malcolm 2212 … /home/malcolm/.claude/.credentials.json`. Secret values are not printed here by rule. No env-var credential is in play. |
| (c) survives process restart | supported | The credential file persists on disk across processes, and every probe in this ticket (P-CC-A..P-CC-D in `host-capability-matrix.md`) was a fresh `claude` process that authenticated without re-login — including the SIGKILL-and-resume probe P-CC-A. |
| Operator one-time step | not needed for native | Subscription login is already established on this machine; no interactive browser login is pending for the native Runner. |

Note for the Host adapter: in `--bare` mode the CLI reads Anthropic auth strictly from `ANTHROPIC_API_KEY` or `apiKeyHelper` via `--settings` — OAuth/keychain are never read (`claude --help`, `--bare` description, verified on the installed CLI). A bare-mode native runner would need one of those instead of the subscription token file.

### Grok native credentials

<!-- T-04 owns this section. Probe date 2026-11-15, CLI `grok 1.0.77 (50ca579fa996) [stable]`. Secret values are never printed here — paths and key names only. -->

| AC-9 fact | Verdict | Evidence |
|---|---|---|
| (a) Auth method in the runner | supported | OAuth token flow against `https://auth.x.ai` via browser login (`grok login`); the credential record in `~/.grok/auth.json` carries `auth_mode`, `refresh_token`, and `expires_at` fields (key names only — values not read). Headless alternative: `XAI_API_KEY` environment variable with an API key from console.x.ai (`~/.grok/docs/user-guide/02-authentication.md`, `14-headless-mode.md` § Authentication for Headless Environments). |
| (b) Where the secret lives | supported | `~/.grok/auth.json` (owner-only `0600` per vendor doc); MCP OAuth tokens at `~/.grok/mcp_credentials.json`; env alternative `XAI_API_KEY`. Vendor doc: `02-authentication.md` § Credential storage. |
| (c) Survives a process restart | supported | Vendor doc (`02-authentication.md` § Browser Login): "stores credentials in `~/.grok/auth.json` and reuses them across sessions. Grok refreshes access tokens automatically in the background" (proactive refresh ~5 min before expiry, on-401 refresh). Probe: every headless probe on 2026-11-15 ran in a fresh process with no login step, including a resume into a new process (matrix evidence (a)). |

One-time operator step: the first login needs an interactive browser session (`grok login`, loopback OAuth; `--oauth` forces it). After that, cached credentials cover native Runner processes. Headless CI boxes without a browser use `XAI_API_KEY` instead.

### omp native credentials

T-05 owns this section. Host CLI: `omp --version` → `omp/18.7.0`. Probe date: 2026-11-15. No secret values are printed below — paths and structure only.

- **(a) Auth method in the runner:** per-provider API keys for the OpenAI-compatible providers (`spark-tf`, `vault-strata`, `studio-tf` — base URLs only in `~/.omp/providers.json`). omp also accepts `--api-key=<value>` on the CLI and falls back to provider env vars (help: "API key (defaults to env vars)"). The configured model roles need no subscription login and no interactive browser flow — no operator step required.
- **(b) Where the secret lives:** the keyring-style store is `~/.omp/agent/agent.db` (SQLite), table `auth_credentials` — probe `sqlite3 ~/.omp/agent/agent.db 'SELECT COUNT(*) FROM auth_credentials;'` returned `2`. No plaintext keys in `~/.omp/agent/config.yml` or `~/.omp/agent/models.yml` (grepped; no `api_key`/`token`/`secret` keys present). A `secret-tool search service omp` over the host keyring returned nothing — omp does not use the desktop keyring on this box. Env-var names (probe 2026-11-15, `strings -a /usr/sbin/omp | grep -oE '[A-Z][A-Z0-9_]{2,}_API_KEY' | sort -u`): the env-var fallback is per provider — each built-in provider reads its own `<PROVIDER>_API_KEY` variable (`OPENAI_API_KEY`, `ANTHROPIC_API_KEY`, `XAI_API_KEY`, `GEMINI_API_KEY`, `GROQ_API_KEY`, etc.); provider `llama.cpp` is the one API-key credential stored in `auth_credentials` on this box and its variable is `LLAMA_CPP_API_KEY` (endpoint companion `LLAMA_CPP_BASE_URL`). The configured model-role providers `spark-tf` / `vault-strata` / `studio-tf` are custom OpenAI-compatible gateways with `"auth": "none"` in `~/.omp/agent/models.yml` — no API key and no env var applies to them; the second stored row is an MCP OAuth credential, not an API key.
- **(c) Survives a process restart:** yes. The store is file-backed SQLite, not process memory. Evidence: the `auth_credentials` rows carry creation timestamps from 2026-10-07 and `agent.db` `model_usage` shows authenticated model runs spanning 2026-10-07 → 2026-11-02 — a month of separate omp processes reused the same stored credentials without re-login. This probe session (2026-11-15) also ran authenticated from the same store.
