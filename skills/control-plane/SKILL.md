---
name: control-plane
description: >
  Internal protocol for /setup control-plane — one command that builds,
  installs, enables, and verifies the phase-1 control plane on a Linux node
  (SPEC-043). Engine is skills/control-plane/setup.sh; this file is its prose
  contract: the three modes, the exit-code contract, the probe flow the T0
  spike ruled, the idempotency rule, the linger answer, the WSL2 operator
  steps. Not a user entry; invoke via /setup control-plane.
user-invocable: false
---

# control-plane — setup protocol (backend for `/setup control-plane`)

> **Entry:** `/setup control-plane` (`commands/setup.md`, SPEC-043 AC14).
> The engine is `skills/control-plane/setup.sh`. This file states the contract
> the engine implements; it runs nothing.
> Spec: `specs/core/SPEC-043-control-plane-setup.md`. Boundary:
> `docs/adr/0001-journal-engine.md` § "The narrow-interface boundary".

## What one run does

`bash skills/control-plane/setup.sh` (bare) runs four phases, each with its own
banner, and stops at the first failure:

| Phase | Owner | Effect |
|-------|-------|--------|
| `preflight` | `preflight.sh` (`cp_preflight`) | Reads the node: platform, systemd user manager, `/etc/wsl.conf`, checkout, docker, the image pin, the runner selection. Writes nothing (SPEC-043 M2, AC9). |
| `build (journal CLI)` | `setup.sh` (`cp_build_journal`) | Builds `control-plane/dist/journalctl` — the verify tool. It is never an install target, so it is built first: a failure leaves nothing installed. |
| `build` | `units.sh` (`cp_build`) | Builds `node-agent` and `chiefd` for the host GOOS/GOARCH inside the approved digest. The chiefd build stamps the identity `GET /v1/version` serves: `-ldflags -X main.version=<control-plane/VERSION> -X main.commit=<short sha>` (`cp_build_stamp`); a checkout with no readable `VERSION` and no git metadata stamps `dev` with no commit and the build still succeeds (SPEC-043 CDT-678 AC1/AC4). Outputs land in `control-plane/dist/` (git-ignored). |
| `install` | `units.sh` (`cp_install`) | Places both binaries at `%h/.local/bin/` (mode 755), writes the chiefd unit to `%h/.config/systemd/user/` (mode 644), removes a `dev-team-node-agent.service` an earlier install left behind and resets failed units when it does, runs `systemctl --user daemon-reload`, then `enable --now` on the chiefd unit. When it wrote the chiefd binary or the unit file it then runs `systemctl --user restart dev-team-chiefd.service` (SPEC-043 CDT-670 AC1). The node agent ships as a CLI with no unit (SPEC-043 M3/M5). |
| `verify` | `setup.sh` (`cp_verify`) | Prints the SPEC-043 M6 table and exits per the code contract below. |

## Modes and exit codes (SPEC-043 M1/M7, AC12)

| Invocation | Result |
|------------|--------|
| `setup.sh` | The four phases above. |
| `setup.sh --status` | The verify table alone. Zero writes: no build, no install, no probe start, and no journal read on a node with no journal file (the journal CLI creates one on open, M1). Read-only preflight only (M2 (a)-(d), (g)). |
| `setup.sh --uninstall` | Stops and disables the chiefd unit, removes the unit file, both binaries, and any stale node-agent unit, runs `daemon-reload` then `reset-failed`, prints the Windows-side steps, exits 0 (M9). |
| `setup.sh --help` | Usage, exit 0. |

| Exit | Meaning |
|------|---------|
| `0` | The table has PASS, WARN, and SKIP rows only. |
| `2` | The table has at least one FAIL row, or a phase failed. |
| `63` | Unsupported node: macOS, no usable systemd user manager, WSL2 with systemd off, or a checkout without `control-plane/go.mod`. Zero side effects. |
| `64` | Usage error, including two modes in one run. |

`--status` on an uninstalled node is WARN-only, never FAIL: the service is
opt-in (SPEC-022 M3 semantics).

## Verify-table rows (SPEC-043 M6)

One row per check, each with a fix-it line on every WARN and FAIL, then the
`N pass / N warn / N fail / N skip` footer. The row renderer is
`skills/lib/record-status.sh` — the same home `/doctor` renders from.

| Row id | Reads |
|--------|-------|
| `controlplane.units.chiefd` | `systemctl --user is-active` and `is-enabled` on `dev-team-chiefd.service` — the only unit phase 1 ships (M5). |
| `controlplane.chiefd.currency` | The unit's `ExecMainStartTimestamp` against the mtime of the installed `%h/.local/bin/chiefd`. Started at or after the binary write → PASS; started before it → FAIL with `systemctl --user restart dev-team-chiefd.service`; an unreadable timestamp or mtime → WARN, never a spurious FAIL (CDT-670 AC3). The detail also names the `version` and `commit` the running chiefd answers on `GET http://127.0.0.1:8090/v1/version` — the identity stamped into the binary that is running (CDT-678 AC2). A version read that fails, answers no `version` field, or has no HTTP client on `PATH` is named in the detail as unreadable: the verdict stays the start-vs-mtime rule, the row never fails on a read it cannot make. |
| `controlplane.node-agent` | The **installed** `%h/.local/bin/node-agent` answers `status-node` with exit 0 — a binary row: the agent ships no unit, so nothing supervises it (M5/M6). The `control-plane/dist/` build output is not an install: with only that copy present the row is a WARN that names the install path. |
| `controlplane.chiefd.api` | HTTP GET on `http://127.0.0.1:8090/v1/runs`. Loopback only, always. The same API answers `GET /v1/version` with the `version` and `commit` stamped into the running binary (`dev` and an empty commit when the build carried no stamp) — the one source the currency row and the web UI both read (CDT-678 AC1/AC3). |
| `controlplane.probe` | The journal state of run `devteam-setup-probe`. With no journal file the row is a WARN `no journal` and the read is skipped — `journalctl` creates a database it is only asked to read, and `--status` writes nothing (M1). |
| `controlplane.probe.lease` | Present only on the M12 takeover: the lease of a `running` probe is past `last_heartbeat_ts + stall_limit_s`, so the driver ran exactly one takeover `start`. |
| `controlplane.probe.hygiene` | No runner process, no pidfile, no leftover container (AC13). |
| `controlplane.runner` | The resolved runner selection, read-only (AC6). |
| `controlplane.linger` | `loginctl show-user "$USER" -p Linger` (AC10). |
| `controlplane.chiefd.journal` | The `/v1/runs` board names the fixed probe run, so the service serves `$MROOT/.claude/runs/run.db` — the journal the install journaled — and not the `$HOME` store an unstamped unit resolves (M5, CDT-666). |
| `controlplane.chiefd.env` | `systemctl --user show dev-team-chiefd.service -p Environment` carries `DEVTEAM_MROOT` for the checkout and a PATH that resolves the node's host CLI (`node.json` `command`, else the probe command) — the env the unit stamps (M5, CDT-666). |
| `controlplane.wsl2.systemd`, `.autostart`, `.idletimeout` | The three WSL2 rows (AC7). `SKIP` off WSL2. |

## The probe flow (SPEC-043 M11 as ruled by the T0 spike)

The probe proves the agent, the journal, and the spawn path. The binding rules,
from spec § Q1a/Q1b/Q1c:

1. Read the state first:
   `control-plane/dist/journalctl read --run-id devteam-setup-probe --state`.
   Every service CLI is called by its `control-plane/dist/` path. Nothing puts
   `journalctl` or `node-agent` on `PATH` (AC11). With no journal file the read
   is skipped and the row is a WARN `no journal` — the journal CLI creates a
   database when it opens a new one, and `--status` writes nothing (M1).
2. Branch on what the journal answers — never on `node-agent status`, which
   exits 0 for a run id with no rows at all:
   - `terminal: true` → skip `start`; report the recorded outcome (the
     idempotent path, M12).
   - no rows → run `DEVTEAM_RUNNER=<resolved> node-agent start --run-id
     devteam-setup-probe --command <no-op>`. The resolved selection rides that
     one child: a node with no selection sends `native`, because the agent
     starts no run on a node that names no runner. The driver never exports
     `$DEVTEAM_RUNNER` and never writes `node.json` (SPEC-043 M11, AC6).
   - `running`, not terminal → WARN row: "retry after lease expiry ~108 s"
     (last heartbeat + `stall_limit_s`). Never a second `start` while the lease
     is live. Past the expiry the owner is dead, so the driver runs exactly one
     takeover `start` and reports it on `controlplane.probe.lease` (M12, spec §
     Q1a); a lease it cannot date counts as expired, matching
     `run.Lease.Expired`.
3. There is **no** `node-agent stop` in the probe flow, and there must never be
   one. A trivial probe command finishes inside `start`, so `stop` always exits
   1; and a `stop` that does land writes `halted:operator_halt`, which the agent
   never resumes — it poisons the fixed id for every later install (spec § Q1b).
4. After `start` returns 0, check hygiene: the pidfile
   `$MROOT/.claude/runs/agent/devteam-setup-probe.pid` is absent and no runner
   process or container remains (AC13).
5. The probe command's own exit code is not journaled (spec § Q1c, a
   control-plane defect owned by a follow-up ticket). Do not compensate by
   parsing probe output.

## Idempotency (SPEC-043 M12, AC2)

A second immediate run reaches the same verdict: the unit file is written only
when the bytes differ, `is-enabled`/`is-active` state is unchanged, the
rebuild is silent and error-free, and the journal carries no duplicate probe
run — because the driver reads the journal state and skips `start` on a
terminal id. `--status` re-runs the table with zero writes.

### Restart on replace (SPEC-043 CDT-670 AC1/AC2)

`cp_publish` writes a target only when its bytes differ and reports the outcome
in `CP_PUBLISH_STATE`: `written` (the bytes changed), `mode` (a chmod only),
`same` (nothing written). When it wrote the chiefd binary or the chiefd unit
file, `cp_install` runs `systemctl --user restart dev-team-chiefd.service` after
the `daemon-reload`/`enable --now` block, so the process in charge is the binary
that was just installed. A mode-only chmod is not a write, so it restarts
nothing. An immediate re-run with identical bytes writes nothing and restarts
nothing, and the unit keeps its main PID (AC2).

The restart is the CDT-660 shutdown path (SPEC-044 M8): the SIGTERM journals no
run event, a live lease is left to expire, and the new process's startup
takeover scan re-supervises the in-flight run. It never writes
`halted:operator_halt`. A failed restart is an install FAIL (exit 2) that prints
the command to run.

`controlplane.chiefd.currency` proves the result on the next table: PASS when
the running process started at or after the installed binary's mtime, with a
detail that names the `version` and `commit` that process serves on
`GET http://127.0.0.1:8090/v1/version` (SPEC-043 CDT-678 AC2). Its
detail names the `version` and `commit` that process serves on
`GET http://127.0.0.1:8090/v1/version`, so the table tells you which build is
running, not only that it is current (CDT-678 AC2).

## Linger: the documented continue/skip answer (SPEC-043 M10, AC10)

When `loginctl show-user "$USER" -p Linger` answers `no`, the row prints the
exact command the operator must run — the driver never executes it:

```
sudo loginctl enable-linger "$USER"
```

Then, on an interactive run, the driver asks once:

- `y` (or `yes`, `continue`) — continue. The table finishes, the linger row
  stays WARN, and the exit code is unaffected (linger is WARN-level: the units
  work until the session ends).
- anything else (`s`, `n`, EOF) — skip. The driver records every remaining row
  as `SKIP` and exits per the table as recorded.
- No terminal (a pipe, a CI run) — the driver does not block: it continues and
  leaves the row WARN. Set `CP_ASSUME_TTY=1` to ask the question on a pipe.

Re-run `--status` after you enable linger: the row reads PASS.

## WSL2 operator steps (SPEC-043 M8, AC7)

Only row (a) is verifiable from inside the distro. Rows (b) and (c) live on the
Windows side, so they stay WARN until you confirm them out of band:

- (a) `/etc/wsl.conf` carries `[boot] systemd=true`.
- (b) Task Scheduler logon task, from an elevated PowerShell:
  `schtasks /Create /TN dev-team-wsl-start /TR "wsl.exe -d <distro> --exec /bin/true" /SC ONLOGON`
- (c) `%UserProfile%\.wslconfig` — add `[general] instanceIdleTimeout=-1` (the
  distro idle timer; `-1` disables auto-shutdown; documented on every supported
  Windows version). On Windows 11 only, `[wsl2] vmIdleTimeout=-1` names the VM
  timer; its `-1` value is vendor-undocumented. Then run `wsl.exe --shutdown`.

Post-reboot proof is CDT-659 scope. This command never attempts it.

## Hard boundaries (SPEC-043 MUST NOT)

- Never `sudo`, `su`, or `pkexec` — directly or through a script. `units.sh`
  funnels every command through `cp_run`, which refuses those tokens, and
  refuses to run in an elevated shell.
- The only container image is the approved digest (SPEC-043 M2(f)); any other
  reference aborts preflight before any pull.
- Never write `.claude/dev-team/node.json`, `$DEVTEAM_RUNNER`, or any record the
  control plane owns.
- Never touch the run journal beyond the probe rows and the probe read.
  `--uninstall` leaves the journal in place and readable.
- Never widen the chiefd bind beyond `127.0.0.1:8090`.
- Never place `node-agent` or `journalctl` on `PATH`, alias them, or rename them.
- Never write a systemd user unit for the node agent (SPEC-043 M5): its verbs
  are `start`, `stop`, `status`, `steer`, `status-node`, so a supervised
  `ExecStart` exits at once and `Restart=on-failure` restart-loops. Both modes
  stop, disable, and remove a `dev-team-node-agent.service` an earlier install
  left behind. The daemon verb that restores supervision is a control-plane
  follow-up ticket.

## Files and tests

| File | Role |
|------|------|
| `skills/control-plane/setup.sh` | The engine: dispatch, probe, verify table. |
| `skills/control-plane/preflight.sh` | SPEC-043 M2 (a)-(g), fail-closed. |
| `skills/control-plane/units.sh` | M3/M4/M5/M9/M12: units, build, install, uninstall. |
| `skills/lib/record-status.sh` | The shared record-and-render pair (also used by `/doctor`). |
| `skills/control-plane/test.sh` | Hermetic end-to-end suite (fakes for docker, systemctl, loginctl, and both service CLIs). |

```bash
bash skills/control-plane/test.sh
bash skills/control-plane/test-preflight.sh
bash skills/control-plane/test-units.sh
bash skills/skill-lint/check-skill-bash.sh skills/control-plane/setup.sh skills/lib/record-status.sh
```
