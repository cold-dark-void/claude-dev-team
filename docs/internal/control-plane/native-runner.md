# Native Runner supervision and start mechanism

Carries AC-7 and the native half of AC-9. T-07 owns this file and writes it alone. Native probes are pre-approved on this machine — no re-ask needed. Container operations are out of scope here.

## AC-7 — Supervision and start mechanism

Record both facts, then choose and verify one start mechanism:

- How the Node agent supervises agent processes on this machine.
- How the Node agent starts — systemd user unit or launchd.

This host is Linux/WSL. launchd is not applicable here. The chosen mechanism is the systemd user unit; verify it works and show the unit file and the probe result (`systemctl --user` start/status of a trivial placeholder is acceptable evidence). No service code is committed — the unit file text appears in this doc as evidence only.
(Since SPEC-043 the shipped templates are product code:
`skills/control-plane/units.sh`, written to `%h/.config/systemd/user/` by
`/setup control-plane`. See § "Start mechanism — chosen and verified".)

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
kernel `6.18.58.1-microsoft-standard-WSL2`, host `malcolm-pc`). The install path
is `%h/.local/bin/node-agent` (SPEC-043 M3): every write target is under
`$HOME`, the command never uses sudo, and `/setup control-plane` writes the
chiefd unit, enables it, and verifies it. The node agent is invoked by path per
run; since the T8 replan it has no unit (§ "CDT-644", D1).

The shipped unit template lives in `skills/control-plane/units.sh` (SPEC-043 M5)
and installs to `%h/.config/systemd/user/` (mode `644`). `/setup control-plane`
writes one unit — `dev-team-chiefd.service`, the text below. The
`dev-team-node-agent.service` text after it is the **pre-T8 template**: phase 1
ships no node-agent unit (D1, recorded in § "CDT-644"), and the command removes
that unit file when an earlier install left one behind.

`dev-team-chiefd.service` (the bind stays loopback — SPEC-043 M5 forbids
widening it, so `ExecStart` names `127.0.0.1` explicitly):

```ini
[Unit]
Description=dev-team chiefd — the Chief API and web UI (CDT-650, CDT-652)
Documentation=https://linear.app/cold-dark-void/issue/CDT-626
Wants=network-online.target
After=network-online.target
StartLimitIntervalSec=60
StartLimitBurst=10

[Service]
ExecStart=%h/.local/bin/chiefd --addr 127.0.0.1:8090
Restart=on-failure
RestartSec=2s

[Install]
WantedBy=default.target
```

`dev-team-node-agent.service` (pre-T8 template, **not shipped**: the agent has
no long-lived verb, so this unit exits at once and restart-loops — see the D1
record in § "CDT-644"):

```ini
[Unit]
Description=dev-team node agent (control plane Option C+, CDT-626)
Documentation=https://linear.app/cold-dark-void/issue/CDT-626
Wants=network-online.target
After=network-online.target
StartLimitIntervalSec=60
StartLimitBurst=10

[Service]
ExecStart=%h/.local/bin/node-agent
Restart=on-failure
RestartSec=2s

[Install]
WantedBy=default.target
```

**Chief unit evidence status (T0-recorded, 2026-11-19; unit count amended by
T8).** The chiefd unit has no prior probe on this node — the probes below cover
the node-agent unit only. The template above is SPEC-043 M5's text as shipped;
the CDT-658 T0 spike (`specs/core/SPEC-043-control-plane-setup.md` § "Open
Questions", probe 2026-11-19) probed the node agent, the journal CLI, and the
linger key, and recorded no chiefd unit run. The template is exercised by the
SPEC-043 hermetic suite (`bash skills/control-plane/test.sh`) against a fake
`systemctl` that expands `%h` and execs the unit's `ExecStart` argv in a scratch
`$HOME`, so the shipped target is proven to start clean. Live unit evidence for
the chiefd unit lands with the phase-1 dogfood run below, whose install step is
`/setup control-plane`. No live chiefd unit has run on this node as of this
writing.

**Node-agent unit status (T8, 2026-11-19).** The probes below are the phase-0
record of a node-agent unit that no longer ships. On the CDT-658 T7 real-node
cycle the unit start-loops: `ExecStart=%h/.local/bin/node-agent` runs a binary
whose verbs are `start`, `stop`, `status`, `steer`, and `status-node`, so a bare
exec prints usage and exits `64`, and `Restart=on-failure` re-spawns it every
2 s. The D1 ruling drops the unit from phase 1 — see § "CDT-644".

Probe evidence — each row: verdict + probe date + command + verbatim output.
The probes below are the **phase-0 record (2026-11-15)**: that unit's
`ExecStart` named the then-intended install path, since superseded by
`%h/.local/bin/node-agent` (SPEC-043 M3). The supervision mechanics they record
are unchanged by the path — the unit supervises whatever binary sits at
`ExecStart`.

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
binary did not exist on 2026-11-15, the start attempt exercised the real
supervision mechanics against the real command path — systemd spawned the
`ExecStart` target, saw the exec fail, and restarted it on the configured
schedule. The binary has existed since CDT-644; its install path is
`%h/.local/bin/node-agent`, written by `/setup control-plane` (SPEC-043 M3).

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
(the OS journald CLI, by unit name — not the Control plane journal CLI, which is
`control-plane/dist/journalctl` and stays off `PATH`; SPEC-043 AC11)

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
a machine-config change outside this discovery ticket's footprint. The decision
landed in SPEC-043: `/setup control-plane` carries the linger row, prints the
exact `sudo loginctl enable-linger "$USER"` line, and waits for the operator's
continue/skip answer — the command never executes sudo (SPEC-043 M10/AC10).
Operator step B8 below is the manual form of the same step.

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
  in the per-unit journal (`journalctl --user -u dev-team-node-agent`, the OS
  journald CLI), which is the log source the CDT-626 append-only run journal and
  the Chief's status surface would build on.

The bare process also dies with its terminal/session (SIGHUP class), which the
session-death probes in `host-capability-matrix.md` reproduce — the exact
"reboot kills the work" failure CDT-626 exists to fix.

## CDT-644 — the node agent is real (phase 1, C4)

Everything above is the phase-0 record and is unchanged. C4 (CDT-628 C4,
2026-11-17) lands the code both layers supervise:

- **Layer 1 has receipts now.** `control-plane/agent/` is the node agent: one
  Go binary (`control-plane/cmd/node-agent`) with the four-verb contract —
  `start`, `stop`, `status`, `steer`. It supervises the native runner: one
  process on the node's own OS per run slot (the configured host CLI, with its
  own logins — `credentials.md` § AC-9 native rows), spawned and tracked by
  PID, steered at step boundaries, and stopped with SIGTERM then SIGKILL after
  a grace. It never talks to Docker, and no Docker dependency exists in the
  contract, the code, or the build.
- **The agent reuses the C2 machine.** The lease with its monotonic fencing
  token, the heartbeats inside the journaled stall limit, and the state as the
  replay of the journal are `control-plane/run`, never a fork. The lease owner
  is `node-agent-<pid>`, so a restarted agent is a real takeover that raises
  the token — a zombie of the dead agent writes nothing.
- **The CDT-626 reboot contract, in code.** A restarting agent finds the dead
  supervisor's recorded trail (the pidfile and the closed spawn intent), kills
  the recorded orphan, and re-spawns as the next attempt: an in-flight run
  continues without a human. The AC-level proof — a real Windows reboot of the
  WSL host — stays the operator step below.
- **The systemd unit text above stays evidence-only.** In C4 the install and
  enablement were operator work outside the ticket. SPEC-043 closes that gap:
  `/setup control-plane` writes both binaries to `%h/.local/bin/` and the
  chiefd unit to `%h/.config/systemd/user/`, runs `systemctl --user
  daemon-reload`, and enables it — no root, and no write target outside
  `$HOME` (SPEC-043 M3). The unit template in § "Start mechanism — chosen and
  verified" is what that command writes. The supervision mechanics themselves —
  start, state tracking with a PID, restart-on-failure, dependency-ordered
  unit, journald capture — are the probe-3 evidence above (2026-11-15) and are
  unchanged by C4: the unit supervises whatever binary sits at `ExecStart`.

- **D1 (CDT-658 T8, 2026-11-19): the node-agent unit is deferred.** The T7
  real-node cycle proved the unit is not correct as written. `node-agent` has no
  long-lived verb — `control-plane/cmd/node-agent/main.go` answers `start`,
  `stop`, `status`, `steer`, and `status-node`, and a bare exec prints usage and
  exits `64` — so a supervised `ExecStart` exits at once, `Restart=on-failure`
  re-spawns it every `RestartSec`, and the unit sits in a restart loop that
  leaves the user manager `degraded`. A `serve`/daemon verb would fix it, and
  that is a control-plane change: it touches service code and `control-plane/VERSION`
  and belongs to a service-owning ticket, so it is **filed as a follow-up**
  rather than landed on a plugin setup ticket. Phase 1 therefore ships
  `dev-team-chiefd.service` only (SPEC-043 M5); the node agent is invoked by
  path per run, which the isolation probe already proved works, and nothing
  needs it resident. `/setup control-plane` stops, disables, and removes a
  `dev-team-node-agent.service` left by an earlier install. The deferred
  capability is reboot-time re-spawn of the agent, and with it the agent half of
  the reboot acceptance test below (`journalctl --user -u dev-team-node-agent`
  has no unit to read until the daemon verb lands).

- **D2 (CDT-658 T8, 2026-11-19): the probe carries the runner selection.** The
  agent is fail-closed: a node with no runner selection starts no run
  (`agent.ErrNoRunnerSelected`, `control-plane/agent/config.go` `Load`), so a
  fresh node's probe `start` refused and AC1 was unreachable. The contract the
  driver uses is the agent's own documented override channel —
  `DEVTEAM_RUNNER=<resolved> control-plane/dist/node-agent start --run-id
  devteam-setup-probe --command <no-op>` — where `<resolved>` is the selection
  preflight read (`node.json` key `runner`, else `$DEVTEAM_RUNNER`, else
  `native`). The assignment sits on that child process only: it is not a record
  write, so record-ownership row 14 (`node.json`) keeps its single writer in the
  service, and the plugin never exports `$DEVTEAM_RUNNER` (SPEC-043 M11, AC6).

- **The credential contract the runner inherits.** The native runner runs the
  configured host CLI with its own logins and never injects a secret: in
  `--bare` mode the CLI reads auth strictly from `ANTHROPIC_API_KEY` or
  `apiKeyHelper` and never the subscription token file (`credentials.md` §
  AC-9 native rows, the T-03 note). The four residual gaps of `credentials.md`
  § "Gaps found" carry over unchanged into C4: (1) the container grid cells —
  one approved image, no second-image/non-root/other-runtime probe, the token
  refresh write untested (the named blocker), omp containerless unauthenticated;
  (2) omp native env-var names uncaptured; (3) the Claude Code 2.1.322→2.1.325
  version drift recorded as actual; (4) the `--bare` split itself, which AC-9
  does not split rows by CLI mode. C4 changes none of them; the agent neither
  reads nor writes any of these paths itself (AC-9 § AC-9 native rows).
### Operator step B8 — linger (pending-operator)

**Status: pending-operator. Do not execute inside the ticket.** The CDT-626
reboot contract needs the user systemd manager to exist before login.

Commands, in order, with the evidence slot each one fills:

1. `loginctl show-user "$USER" -p Linger` — **before**. Evidence slot: the
   `Linger=no` line (the phase-0 probe recorded `Linger=no` on 2026-11-15;
   re-record at execution).
2. `sudo loginctl enable-linger "$USER"` — the step itself. Evidence slot: the
   command's exit status (`0`).
3. `loginctl show-user "$USER" -p Linger` — **after**. Evidence slot: the
   `Linger=yes` line. Before-and-after together are the evidence pair.

**The command prints this step; it never performs it.** `/setup control-plane`
reads the same key and renders the linger verify row. `Linger=no` prints the
exact `sudo loginctl enable-linger "$USER"` line and waits for the operator's
documented continue/skip answer — the command never executes sudo (SPEC-043
M10/AC10). The row is WARN, never FAIL: the units work until the session ends.
Run the three commands above, then `/setup control-plane --status` — the row
reads PASS.

### Operator step — phase-1 dogfood run (pending-operator, CDT-659)

**Status: pending-operator.** The first real use of the node. Install step:
`/setup control-plane` (SPEC-043) — one command that builds in the approved Go
image, installs both binaries and the chiefd systemd user unit, enables it, and
prints the verify table. The run executes under CDT-659 (Phase 1 — Validation).

1. `/setup control-plane` — evidence slot: the verify table plus its
   `N pass / N warn / N fail / N skip` footer. This is the live unit evidence
   for `dev-team-chiefd.service`, and the `controlplane.node-agent` row is the
   live read of the agent binary (`status-node`, exit 0 — no unit, D1).
2. `/setup control-plane --status` — evidence slot: the same verdict from a
   read-only run (zero writes, SPEC-043 M1).
3. Start one run and read it back: `control-plane/dist/node-agent start
   --run-id <RUN-ID> --ticket <TICKET> --workflow orchestrate`, then
   `control-plane/dist/journalctl read --run-id <RUN-ID> --events` — evidence
   slot: the journaled rows.
4. `/setup control-plane --uninstall`, then `/setup control-plane --status` —
   evidence slot: the journal still reads (SPEC-043 M9), and a re-install
   reaches the same verdict (SPEC-043 M12).

### Operator step — reboot acceptance test (pending-operator, CDT-659)

**Status: pending-operator. Do not execute inside the ticket.** The test uses
a real reboot of the WSL host — not a service kill — because the AC is that
the work survives the machine, not the process. Install step:
`/setup control-plane` (SPEC-043) — it installs, enables, and verifies the
chiefd unit, and its linger row is step B8. The test itself executes under
CDT-659 (Phase 1 — Validation); this ticket records the protocol only.
**Deferred with D1:** phase 1 ships no node-agent unit, so step 3's
`journalctl --user -u dev-team-node-agent` slot has no unit to read — the
reboot re-spawn of the agent needs the daemon-verb follow-up. Record the
journal-CLI slots below and mark the unit slot `deferred (D1)`. Protocol, once
the install is verified and at least one run is in flight:

1. Start a run and record it: `control-plane/dist/node-agent start --run-id
   <RUN-ID> --ticket <TICKET> --workflow orchestrate` — evidence slot: the run
   id and the `run_claimed` / `run_started` rows in the journal
   (`control-plane/dist/journalctl read --run-id <RUN-ID> --events`, the
   Control plane journal CLI — by path, never on `PATH`, SPEC-043 AC11).
2. Reboot the Windows host from inside WSL:
   `wsl.exe --shutdown` issued from Windows, or a Windows-side `shutdown /r
   /t 0`. Evidence slot: the exact command used and its exit status.
3. After the host comes back and the user session is up (linger enabled, step
   B8): prove no human touched the run — evidence slots:
   - `journalctl --user -u dev-team-node-agent --no-pager -n 50` — the agent's
     restart on failure captured by journald (the OS journald CLI, by unit name).
   - `control-plane/dist/journalctl read --run-id <RUN-ID> --state` — the
     resumed run state.
   - The resumed run ids: every in-flight run id from step 1, carried to
     `completed` or `running` again without operator action.
4. The pass rule: every in-flight run from step 1 shows a `lease_acquired`
   (takeover) row and an `agent.start` outcome row with a fresh PID after the
   reboot, and no human input in between.

Until this step executes, the code-level proof of the same contract is
`go test ./agent/` — `TestSuperviseTakeoverAfterAgentDeathCompletesOnce` and
`TestRecoveryPerformsThePendingSpawn` — in the CDT-644 branch.

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
